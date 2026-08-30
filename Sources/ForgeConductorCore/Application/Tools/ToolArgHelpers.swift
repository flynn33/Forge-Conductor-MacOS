// ToolArgHelpers.swift
// What: Defines common argument decoding and the tool-pack extension contract.
// How: Static helpers provide consistent required/optional coercion, while
// ToolPackHandling lets the router discover names and invoke a module uniformly.
// Why: Shared validation prevents subtly different behavior across connector modules.

import Foundation

public struct ToolCallDeadlineExceeded: Error, LocalizedError, Equatable, Sendable {
    public init() {}

    public var errorDescription: String? {
        "Tool call deadline exceeded"
    }
}

/// Cooperative cancellation and a monotonic deadline propagated from one connector
/// request through the router and its selected tool pack.
public final class ToolCallCancellation: @unchecked Sendable {
    private static let nanosecondsPerSecond = 1_000_000_000.0
    private static let maximumTimeoutSeconds: TimeInterval = 86_400

    private let lock = NSRecursiveLock()
    private var cancelled = false
    private var deadlineUptimeNanoseconds: UInt64?
    private var commitDepth = 0
    private var committedReceipt: Any?

    public init(timeoutSeconds: TimeInterval? = nil) {
        if let timeoutSeconds {
            deadlineUptimeNanoseconds = Self.deadline(after: timeoutSeconds)
        }
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public var isDeadlineExceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let deadlineUptimeNanoseconds else { return false }
        return DispatchTime.now().uptimeNanoseconds >= deadlineUptimeNanoseconds
    }

    /// Remaining monotonic request time. `nil` means the compatibility caller did
    /// not provide a deadline; MCP requests always provide one at admission.
    public var remainingTimeInterval: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let deadlineUptimeNanoseconds else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadlineUptimeNanoseconds > now else { return 0 }
        return TimeInterval(deadlineUptimeNanoseconds - now) / Self.nanosecondsPerSecond
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Serializes the irreversible commit boundary with cancellation revocation.
    /// Once `cancel()` returns, a later caller cannot enter `commit`; if a commit
    /// already owns the fence, cancellation waits only for that bounded commit.
    public func withCommitAuthorization(
        _ commit: () throws -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkCancellationLocked()
        commitDepth += 1
        defer { commitDepth -= 1 }
        try commit()
    }

    public func withCommitAuthorization<Value: Sendable>(
        _ commit: () throws -> Value
    ) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        try checkCancellationLocked()
        commitDepth += 1
        do {
            let value = try commit()
            committedReceipt = value
            commitDepth -= 1
            return value
        } catch {
            commitDepth -= 1
            throw error
        }
    }

    /// Publishes the transaction body's exact result in the same critical section
    /// as a successful raw COMMIT. A cancellation observed after COMMIT can then
    /// reconcile the committed result even if completion delivery is delayed.
    public func withCommitAuthorization<Value>(
        committedResult: Value,
        _ commit: () throws -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkCancellationLocked()
        commitDepth += 1
        defer { commitDepth -= 1 }
        try commit()
        committedReceipt = committedResult
    }

    public func committedResult<Value: Sendable>(as type: Value.Type = Value.self) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return committedReceipt as? Value
    }

    /// Replaces a lower-layer receipt with the caller's exact result after the
    /// authorized commit has completed. This never creates commit authority: a
    /// caller with no prior committed receipt remains cancellable.
    @discardableResult
    public func promoteCommittedResultIfPresent<Value>(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard committedReceipt != nil else { return false }
        committedReceipt = value
        return true
    }

    public var hasClaimedCommit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return commitDepth > 0
    }

    /// Tightens, but never extends, the request deadline. This lets a tool's
    /// optional `deadline_ms` refine the transport-wide bound without creating a
    /// second timer or racing execution against an abandoned task.
    public func tightenDeadline(milliseconds: Int) throws {
        guard milliseconds > 0 else { throw ToolCallDeadlineExceeded() }
        let candidate = Self.deadline(after: TimeInterval(milliseconds) / 1_000)
        lock.lock()
        if let existing = deadlineUptimeNanoseconds {
            deadlineUptimeNanoseconds = min(existing, candidate)
        } else {
            deadlineUptimeNanoseconds = candidate
        }
        lock.unlock()
        try checkCancellation()
    }

    public func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkCancellationLocked()
    }

    private func checkCancellationLocked() throws {
        if cancelled { throw CancellationError() }
        if let deadlineUptimeNanoseconds,
           DispatchTime.now().uptimeNanoseconds >= deadlineUptimeNanoseconds {
            throw ToolCallDeadlineExceeded()
        }
    }

    private static func deadline(after requestedSeconds: TimeInterval) -> UInt64 {
        let finiteSeconds: TimeInterval
        if requestedSeconds == .infinity {
            finiteSeconds = maximumTimeoutSeconds
        } else if requestedSeconds.isFinite {
            finiteSeconds = requestedSeconds
        } else {
            finiteSeconds = 0
        }
        let seconds = min(max(finiteSeconds, 0), maximumTimeoutSeconds)
        let delta = UInt64((seconds * nanosecondsPerSecond).rounded(.up))
        return DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(delta).partialValue
    }
}

/// Shared argument parsing for tool packs (wire JSON → Swift).
public enum ToolArgHelpers {
    public static func string(_ args: [String: Any], _ key: String) -> String? {
        if let s = args[key] as? String { return s }
        if let n = args[key] as? NSNumber { return n.stringValue }
        return nil
    }

    public static func int(_ args: [String: Any], _ key: String) -> Int? {
        if let i = args[key] as? Int { return i }
        if let d = args[key] as? Double { return Int(exactly: d) }
        if let s = args[key] as? String { return Int(s) }
        if let n = args[key] as? NSNumber { return Int(exactly: n.doubleValue) }
        return nil
    }

    public static func bool(_ args: [String: Any], _ key: String) -> Bool? {
        if let b = args[key] as? Bool { return b }
        return nil
    }

    public static func resolvePath(_ raw: String) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}

/// Immutable argument transport for work that crosses an executor boundary.
/// MCP arguments are JSON objects; serializing them before capture prevents a
/// mutable Foundation object graph from being shared with a `@Sendable` closure.
struct SerializedToolArguments: Sendable {
    private let data: Data

    init(_ arguments: [String: Any]) throws {
        data = try JSONSupport.data(from: arguments)
    }

    func decoded() throws -> [String: Any] {
        try JSONSupport.object(from: data)
    }
}

public protocol ToolPackHandling: Sendable {
    /// Tool names this pack owns.
    var toolNames: [String] { get }
    func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult?
}

public extension ToolPackHandling {
    func handle(
        name: String,
        arguments: [String: Any],
        clientID: ClientID,
        app: ForgeApp
    ) throws -> ToolResult? {
        try handle(
            name: name,
            arguments: arguments,
            context: nil,
            clientID: clientID,
            app: app,
            cancellation: nil
        )
    }

    func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp
    ) throws -> ToolResult? {
        try handle(
            name: name,
            arguments: arguments,
            context: context,
            clientID: clientID,
            app: app,
            cancellation: nil
        )
    }
}

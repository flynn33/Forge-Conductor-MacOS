// AuditService.swift
// What: Records bounded tool-execution audit events to durable and live sinks.
// How: It sanitizes arguments/results, writes through SQLiteStore, and emits diagnostic
// correlation records without retaining sensitive file contents or full commands.
// Why: Accountability must not become a second channel for sensitive data leakage.

import Foundation

/// Dual-write audit: SQLite + audit.jsonl
public final class AuditService: @unchecked Sendable {
    static let attemptQueueCapacity = 32
    public static let defaultAttemptTimeoutSeconds: TimeInterval = 2

    private let store: SQLiteStore
    private let paths: AppPaths
    private let lock = NSLock()
    private let attemptQueue = BoundedAsyncWorkQueue(
        label: "forge.audit.attempts",
        capacity: AuditService.attemptQueueCapacity
    )

    public init(store: SQLiteStore, paths: AppPaths) {
        self.store = store
        self.paths = paths
    }

    deinit {
        _ = attemptQueue.shutdown(timeout: 0.25)
    }

    public func append(
        tool: String,
        status: String,
        clientID: String?,
        args: [String: Any]? = nil,
        durationMs: Int? = nil,
        error: String? = nil,
        mutating: Bool = false,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try Self.append(
            AuditAppendRequest(
                tool: tool,
                status: status,
                clientID: clientID,
                args: args,
                durationMs: durationMs,
                error: error,
                mutating: mutating
            ),
            store: store,
            paths: paths,
            mirrorLock: lock,
            cancellation: cancellation
        )
    }

    /// Attempts evidence persistence on an independently bounded serial owner.
    /// Admission is non-blocking so an expired request can return immediately.
    @discardableResult
    public func attemptAppend(
        tool: String,
        status: String,
        clientID: String?,
        args: [String: Any]? = nil,
        durationMs: Int? = nil,
        error: String? = nil,
        mutating: Bool = false,
        timeoutSeconds: TimeInterval = AuditService.defaultAttemptTimeoutSeconds
    ) -> Bool {
        let request = AuditAppendRequest(
            tool: tool,
            status: status,
            clientID: clientID,
            args: args,
            durationMs: durationMs,
            error: error,
            mutating: mutating
        )
        let store = self.store
        let paths = self.paths
        let mirrorLock = lock
        let timeout = Self.boundedAttemptTimeout(timeoutSeconds)
        return attemptQueue.submit {
            let control = ToolCallCancellation(timeoutSeconds: timeout)
            try? Self.append(
                request,
                store: store,
                paths: paths,
                mirrorLock: mirrorLock,
                cancellation: control
            )
        }
    }

    @discardableResult
    public func flushAttempts(timeout: TimeInterval = 2) -> Bool {
        attemptQueue.flush(timeout: timeout)
    }

    /// Stops admission and drains accepted evidence attempts through a fixed bound.
    @discardableResult
    public func shutdownAttempts(timeout: TimeInterval = 2) -> Bool {
        attemptQueue.shutdown(timeout: timeout)
    }

    var droppedAttemptCount: Int { attemptQueue.droppedSubmissions }

    public func recent(limit: Int = 80) throws -> [AuditEvent] {
        try store.auditRecent(limit: limit)
    }

    private static func append(
        _ request: AuditAppendRequest,
        store: SQLiteStore,
        paths: AppPaths,
        mirrorLock: NSLock,
        cancellation: ToolCallCancellation?
    ) throws {
        try cancellation?.checkCancellation()
        let argsForStore: [String: Any]? = request.mutating ? request.args : nil
        let digest: String?
        if let args = request.args {
            let canonical = try JSONSupport.canonicalJSON(args)
            try cancellation?.checkCancellation()
            digest = JSONSupport.sha256Hex(canonical)
        } else {
            digest = nil
        }
        let argsJSON: String?
        if let argsForStore {
            argsJSON = try JSONSupport.string(from: argsForStore)
            try cancellation?.checkCancellation()
        } else {
            argsJSON = nil
        }
        let event = AuditEvent(
            clientID: request.clientID,
            tool: request.tool,
            argsDigest: digest,
            argsJSON: argsJSON,
            status: request.status,
            durationMs: request.durationMs,
            error: request.error
        )
        try store.auditAppend(event, cancellation: cancellation)

        // SQLite is the durable audit authority. Keep the JSONL compatibility
        // mirror bounded, and do not let cancellation observed after the SQLite
        // commit conceal the already-recorded event or the primary tool result.
        do {
            guard mirrorLock.lock(before: Date().addingTimeInterval(0.25)) else {
                return
            }
            defer { mirrorLock.unlock() }
            try paths.ensureLayout()
            var lineObj: [String: Any] = [
                "timestamp": ISO8601.string(from: event.timestamp),
                "tool": request.tool,
                "status": request.status,
                "args_digest": digest as Any,
                "args": argsForStore as Any,
                "duration_ms": request.durationMs as Any,
                "error": request.error as Any,
                "client_id": request.clientID as Any,
            ]
            // strip NSNull-ish
            lineObj = lineObj.compactMapValues { v in
                if v is NSNull { return nil }
                return v
            }
            var data = try JSONSupport.data(from: lineObj)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: paths.auditJSONL.path) {
                FileManager.default.createFile(atPath: paths.auditJSONL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: paths.auditJSONL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // SQLite is authoritative; compatibility mirror failures are repairable
            // and must not turn a committed audit event into an apparent failure.
            return
        }
    }

    private static func boundedAttemptTimeout(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultAttemptTimeoutSeconds }
        return min(10, max(0.05, value))
    }
}

private struct AuditAppendRequest: @unchecked Sendable {
    var tool: String
    var status: String
    var clientID: String?
    var args: [String: Any]?
    var durationMs: Int?
    var error: String?
    var mutating: Bool
}

private extension Dictionary where Key == String, Value == Any {
    func compactMapValues(_ transform: (Any) -> Any?) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in self {
            if let nv = transform(v) { out[k] = nv }
        }
        return out
    }
}

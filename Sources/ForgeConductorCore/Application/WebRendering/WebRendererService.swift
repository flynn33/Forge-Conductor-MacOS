import Foundation

/// The production implementation can only invoke the root-owned fixed current-self mode.
/// Tests replace this typed transport, never a helper path or admission predicate.
protocol WebRenderTransport: Sendable {
    func run(input: Data, profile: WebRenderProtocol.Profile, deadline: UInt64, cancellation: ToolCallCancellation) throws -> OwnedDuplexResult
    func shutdown(deadline: UInt64) -> Bool
}

private struct NativeWebRenderTransport: WebRenderTransport {
    private let runner = ProcessRunner(inheritEnvironment: false)

    func run(input: Data, profile: WebRenderProtocol.Profile, deadline: UInt64, cancellation: ToolCallCancellation) throws -> OwnedDuplexResult {
        try runner.runOwnedCurrentSelf(mode: profile == .v1 ? .webRenderV1 : .webRenderV2, standardInput: input,
                                      deadlineUptimeNanoseconds: deadline, cancellation: cancellation)
    }
    func shutdown(deadline: UInt64) -> Bool {
        runner.shutdownOwnedCurrentSelf(deadlineUptimeNanoseconds: deadline)
    }
}

/// Owns one operation and one opt-in immutable snapshot; no pool or waiter list.
public actor WebRendererService {
    private struct Active {
        let nonce: UUID
        let cancellation: ToolCallCancellation
        let deadline: UInt64
        var unresolved = false
        var recoveryInFlight = false
    }
    private let transport: any WebRenderTransport
    private let queue = DispatchQueue(label: "forge.web-render.execution", qos: .utility)
    private var active: Active?
    private var stopped = false
    static let snapshotLifetimeNanoseconds: UInt64 = 120_000_000_000
    private let snapshotLifetime: UInt64
    private var snapshot: CachedSnapshot?
    private var expiryTask: Task<Void, Never>?

    private struct CachedSnapshot {
        let id: UUID
        let owner: WebRenderSnapshotOwner
        let requestedURL: String
        let finalURL: String
        let title: String
        let titleTruncated: Bool
        let nodesVisited: Int
        let readiness: WebRenderProtocol.Readiness
        let bytes: Data
        let digest: String
        let expires: UInt64
    }

    public init() {
        transport = NativeWebRenderTransport()
        snapshotLifetime = Self.snapshotLifetimeNanoseconds
    }
    init(transport: any WebRenderTransport, snapshotLifetime: UInt64 = snapshotLifetimeNanoseconds) {
        self.transport = transport
        self.snapshotLifetime = min(max(1, snapshotLifetime), Self.snapshotLifetimeNanoseconds)
    }

    deinit { expiryTask?.cancel() }

    static func supports(_ version: OperatingSystemVersion) -> Bool { version.majorVersion >= 27 }
    public static var isSupported: Bool { supports(ProcessInfo.processInfo.operatingSystemVersion) }

    func execute(_ request: WebRenderProtocol.Request,
                 cancellation: ToolCallCancellation,
                 profile: WebRenderProtocol.Profile = .v1) async throws -> WebRenderProtocol.Reply {
        guard !stopped else { throw WebRenderError.stopped }
        guard active == nil else { throw WebRenderError.busy }
        guard Self.isSupported else { throw WebRenderError.unsupportedOS }
        try cancellation.checkCancellation()
        try Task.checkCancellation()
        let now = DispatchTime.now().uptimeNanoseconds
        guard request.deadlineUptimeNanoseconds > now,
              request.deadlineUptimeNanoseconds - now > 2_500_000_000,
              request.deadlineUptimeNanoseconds - now <= 30_000_000_000 else {
            throw WebRenderError.deadline
        }
        let input: Data
        do { input = try WebRenderProtocol.encodeRequest(request, profile: profile) }
        catch { throw WebRenderError.invalidResponse }
        // Install before the first suspension: later calls can only fail busy.
        active = Active(nonce: request.nonce, cancellation: cancellation,
                        deadline: request.deadlineUptimeNanoseconds)
        var dispositionConfirmed = true
        defer {
            if active?.nonce == request.nonce {
                if dispositionConfirmed { active = nil }
                else { active?.unresolved = true }
            }
        }
        let transport = self.transport
        do {
            let raw = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OwnedDuplexResult, Error>) in
                    queue.async {
                        do {
                            continuation.resume(returning: try transport.run(input: input, profile: profile,
                                deadline: request.deadlineUptimeNanoseconds, cancellation: cancellation))
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            } onCancel: { cancellation.cancel() }
            dispositionConfirmed = raw.terminationConfirmed
            guard dispositionConfirmed else { throw WebRenderError.terminationUnconfirmed }
            guard DispatchTime.now().uptimeNanoseconds < request.deadlineUptimeNanoseconds else {
                throw WebRenderError.deadline
            }
            try cancellation.checkCancellation()
            try Task.checkCancellation()
            if raw.cancelled { throw WebRenderError.cancelled }
            if raw.timedOut { throw WebRenderError.deadline }
            switch raw.admission {
            case .admitted: break
            case .notAttempted, .ownedChildExited: throw WebRenderError.transportFailed
            case .roleRejected, .auditTokenUnavailable, .childInvalid, .exactIdentityMismatch:
                throw WebRenderError.identityRejected
            }
            guard raw.exitCode == 0, raw.terminationSignal == nil,
                  !raw.termRequested, !raw.killRequested,
                  raw.stdinClosed, raw.stdinBytesWritten == input.count,
                  !raw.stdout.truncated, !raw.stderr.truncated,
                  raw.stdout.data.count <= profile.maximumReplyBodyBytes + 4,
                  raw.stderr.data.count <= 16_384,
                  case .eof = raw.stdout.end, case .eof = raw.stderr.end else {
                throw WebRenderError.invalidResponse
            }
            do { return try WebRenderProtocol.decodeReplyFrame(raw.stdout.data, matching: request, profile: profile) }
            catch { throw WebRenderError.invalidResponse }
        } catch {
            if error is OwnedNativeTerminationUnconfirmed {
                dispositionConfirmed = false
                throw WebRenderError.terminationUnconfirmed
            }
            if let processError = error as? ProcessRunnerError,
               case .terminationUnconfirmed = processError {
                dispositionConfirmed = false
                throw WebRenderError.terminationUnconfirmed
            }
            if error is CancellationError { throw WebRenderError.cancelled }
            if error is ToolCallDeadlineExceeded { throw WebRenderError.deadline }
            if error is OwnedCurrentSelfAdmissionError { throw WebRenderError.identityRejected }
            if let error = error as? WebRenderError { throw error }
            // Shared transport contract: other throws mean no child or confirmed cleanup.
            throw WebRenderError.transportFailed
        }
    }

    /// Cancellation waits only within the active operation's original deadline.
    /// A timed-out Security call/unconfirmed owner remains busy; no slot is fabricated free.
    public func shutdown() async -> Bool {
        stopped = true
        snapshot = nil
        let expiry = expiryTask
        expiryTask = nil
        expiry?.cancel()
        await expiry?.value
        active?.cancellation.cancel()
        var attemptedRecovery = false
        while let current = active {
            if current.unresolved, !current.recoveryInFlight {
                if attemptedRecovery { return false }
                attemptedRecovery = true
                scheduleRecovery(current)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < current.deadline else { return false }
            do { try await Task.sleep(nanoseconds: min(10_000_000, current.deadline - now)) }
            catch { return false }
        }
        return true
    }

    private func scheduleRecovery(_ current: Active) {
        active?.recoveryInFlight = true
        let transport = self.transport
        queue.async { [weak self] in
            // An expired end allows one immediate recovery poll, never a fresh grace.
            let confirmed = transport.shutdown(deadline: current.deadline)
            Task { await self?.completeRecovery(nonce: current.nonce, confirmed: confirmed) }
        }
    }

    private func completeRecovery(nonce: UUID, confirmed: Bool) {
        guard active?.nonce == nonce, active?.unresolved == true else { return }
        if confirmed { active = nil }
        else { active?.recoveryInFlight = false }
    }


    /// Publish only after the caller has revalidated the resolved authorization.
    /// Failed/overflow/cancelled captures do not replace the previous entry.
    func publishSnapshot(_ reply: WebRenderProtocol.Reply, requestedURL: String,
                         owner: WebRenderSnapshotOwner, cancellation: ToolCallCancellation) throws -> UUID {
        guard !stopped else { throw WebRenderError.stopped }
        try cancellation.checkCancellation()
        guard reply.outcome == .rendered, reply.snapshotExtracted, reply.lockdownEnabled,
              !reply.textTruncated, reply.projectID == owner.projectID,
              reply.projectGeneration == owner.generation,
              reply.text.utf8.count <= WebRenderProtocol.Profile.completeV2.maximumTextBytes,
              requestedURL.utf8.count + reply.finalURL.utf8.count + reply.title.utf8.count <= 32_768 else {
            throw WebRenderError.invalidResponse
        }
        let bytes = Data(reply.text.utf8)
        let digest = JSONSupport.sha256Hex(bytes)
        try cancellation.checkCancellation()
        let id = UUID()
        snapshot = CachedSnapshot(id: id, owner: owner, requestedURL: requestedURL,
            finalURL: reply.finalURL, title: reply.title, titleTruncated: reply.titleTruncated,
            nodesVisited: reply.nodesVisited, readiness: reply.readiness, bytes: bytes, digest: digest,
            expires: DispatchTime.now().uptimeNanoseconds + snapshotLifetime)
        if expiryTask == nil {
            // One sleeper, reused across replacements. It captures no body and
            // wakes at the old deadline before observing any later replacement.
            expiryTask = Task.detached { [weak self] in
                while let delay = await self?.expireOrDelay() {
                    do { try await Task.sleep(nanoseconds: delay) }
                    catch { return }
                }
            }
        }
        return id
    }

    func snapshotPage(id: UUID, digest: String?, owner: WebRenderSnapshotOwner,
                      requestedURL: String, offset: Int, maximumBytes: Int,
                      cancellation: ToolCallCancellation) throws -> WebRenderSnapshotPage {
        guard !stopped else { throw WebRenderError.stopped }
        try cancellation.checkCancellation()
        if let stored = snapshot, DispatchTime.now().uptimeNanoseconds >= stored.expires { snapshot = nil }
        guard let stored = snapshot, stored.id == id, stored.owner == owner,
              stored.requestedURL == requestedURL, digest == nil || digest == stored.digest else {
            throw WebRenderSnapshotError.stale
        }
        guard (0...stored.bytes.count).contains(offset), (1...65_536).contains(maximumBytes),
              offset == stored.bytes.count || stored.bytes[offset] & 0xc0 != 0x80 else {
            throw WebRenderError.invalidArgument("byte_offset")
        }
        var end = min(stored.bytes.count, offset + maximumBytes)
        while end < stored.bytes.count, end > offset, stored.bytes[end] & 0xc0 == 0x80 { end -= 1 }
        guard end > offset || offset == stored.bytes.count else { throw WebRenderError.outputBudget }
        guard let text = String(data: stored.bytes.subdata(in: offset..<end), encoding: .utf8) else {
            throw WebRenderError.invalidResponse
        }
        try cancellation.checkCancellation()
        return WebRenderSnapshotPage(id: stored.id, digest: stored.digest, totalBytes: stored.bytes.count,
            offset: offset, text: text, requestedURL: stored.requestedURL, finalURL: stored.finalURL,
            title: stored.title, titleTruncated: stored.titleTruncated, nodesVisited: stored.nodesVisited,
            readiness: stored.readiness, projectID: owner.projectID, generation: owner.generation)
    }

    private func expireOrDelay() -> UInt64? {
        guard !stopped, let stored = snapshot else { expiryTask = nil; return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < stored.expires else { snapshot = nil; expiryTask = nil; return nil }
        return stored.expires - now
    }

    // Observable bounded state for owner/lifetime tests, not a public tool field.
    var retainedSnapshotBytes: Int { snapshot?.bytes.count ?? 0 }
    var hasSnapshotExpiryOwner: Bool { expiryTask != nil }
    var snapshotExpiryNanoseconds: UInt64? { snapshot?.expires }
}

enum WebRenderSnapshotError: Error { case stale }

struct WebRenderSnapshotOwner: Sendable, Equatable {
    let projectID: UUID
    let generation: UInt64
    let digest: String

    init(_ context: ToolInvocationContext) throws {
        let scope = context.authorizationScope
        guard scope.canonicalRoots.count <= 128, scope.writableRoots.count <= 128,
              scope.allowedTools.count <= 256 else { throw WebRenderError.invalidArgument("snapshot scope") }
        let roots = scope.canonicalRoots.map(\.absoluteString)
        let writable = scope.writableRoots.map(\.absoluteString)
        let tools = scope.allowedTools.sorted()
        let strings = roots + writable + tools + [context.clientID.rawValue, context.providerSessionID ?? ""]
        var total = 0
        for value in strings {
            let count = value.utf8.prefix(8_193).count
            guard count <= 8_192, total <= 8_192 - count else { throw WebRenderError.invalidArgument("snapshot scope") }
            total += count
        }
        // At most 8192 source UTF-8 bytes; worst JSON escaping stays bounded.
        var value: [String: Any] = ["project": context.projectID.description,
            "generation": context.projectGeneration.rawValue, "client": context.clientID.rawValue,
            "run": context.runID?.description ?? "",
            "job": context.runtimeJobID?.uuidString ?? "", "roots": roots, "writable": writable,
            "tools": tools, "network": scope.networkAllowed, "inline": scope.maximumInlineOutputBytes]
        if let provider = context.providerSessionID { value["provider"] = provider }
        else { value["provider"] = NSNull() }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 16_384 else { throw WebRenderError.invalidArgument("snapshot scope") }
        projectID = context.projectID.rawValue
        generation = context.projectGeneration.rawValue
        digest = JSONSupport.sha256Hex(data)
    }
}

struct WebRenderSnapshotPage: Sendable {
    let id: UUID
    let digest: String
    let totalBytes: Int
    let offset: Int
    let text: String
    let requestedURL: String
    let finalURL: String
    let title: String
    let titleTruncated: Bool
    let nodesVisited: Int
    let readiness: WebRenderProtocol.Readiness
    let projectID: UUID
    let generation: UInt64
}

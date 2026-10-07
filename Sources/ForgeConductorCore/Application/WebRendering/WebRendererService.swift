import Foundation

/// The production implementation can only invoke the root-owned fixed current-self mode.
/// Tests replace this typed transport, never a helper path or admission predicate.
protocol WebRenderTransport: Sendable {
    func run(input: Data, deadline: UInt64, cancellation: ToolCallCancellation) throws -> OwnedDuplexResult
    func shutdown(deadline: UInt64) -> Bool
}

private struct NativeWebRenderTransport: WebRenderTransport {
    private let runner = ProcessRunner(inheritEnvironment: false)

    func run(input: Data, deadline: UInt64, cancellation: ToolCallCancellation) throws -> OwnedDuplexResult {
        try runner.runOwnedCurrentSelf(mode: .webRenderV1, standardInput: input,
                                      deadlineUptimeNanoseconds: deadline, cancellation: cancellation)
    }
    func shutdown(deadline: UInt64) -> Bool {
        runner.shutdownOwnedCurrentSelf(deadlineUptimeNanoseconds: deadline)
    }
}

/// Owns one operation without a pool, waiter list, or retained renderer cache.
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

    public init() { transport = NativeWebRenderTransport() }
    init(transport: any WebRenderTransport) { self.transport = transport }

    static func supports(_ version: OperatingSystemVersion) -> Bool { version.majorVersion >= 27 }
    public static var isSupported: Bool { supports(ProcessInfo.processInfo.operatingSystemVersion) }

    func execute(_ request: WebRenderProtocol.Request,
                 cancellation: ToolCallCancellation) async throws -> WebRenderProtocol.Reply {
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
        do { input = try WebRenderProtocol.encodeRequest(request) }
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
                            continuation.resume(returning: try transport.run(input: input,
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
                  raw.stdout.data.count <= WebRenderProtocol.maximumReplyBodyBytes + 4,
                  raw.stderr.data.count <= 16_384,
                  case .eof = raw.stdout.end, case .eof = raw.stderr.end else {
                throw WebRenderError.invalidResponse
            }
            do { return try WebRenderProtocol.decodeReplyFrame(raw.stdout.data, matching: request) }
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

}

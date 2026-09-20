// StjornarvaldProductObservations.swift
// Emits bounded, redacted product observations without delaying development work.

import Foundation

public protocol StjornarvaldObservationRecording: Sendable {
    func record(_ observation: DevelopmentObservation)
}

public struct StjornarvaldObservationEmitterMetrics: Sendable, Equatable {
    public let pendingCount: Int
    public let droppedCount: UInt64
    public let workerActive: Bool
    public let accepting: Bool
}

/// Resolves the current loopback endpoint for every attempt so an applied
/// Manager port change does not strand durable observations until process exit.
public final class StjornarvaldConfiguredObservationTransport: StjornarvaldObservationTransport, @unchecked Sendable {
    private let config: ConfigStore
    private let credentials: any ManagerMutationCredentialProviding

    public init(config: ConfigStore, paths: AppPaths) {
        self.config = config
        credentials = ManagerControlCredentialStore(paths: paths)
    }

    public func submit(
        processID: String,
        bootID: String,
        observations: [DevelopmentObservation]
    ) async throws -> StjornarvaldObservationReceiptBatch {
        let dashboard = config.dashboard
        return try await ManagerDashboardClient(
            host: dashboard.host,
            port: dashboard.port,
            credentials: credentials
        ).submit(processID: processID, bootID: bootID, observations: observations)
    }
}

/// A synchronous, nonthrowing product boundary backed by one asynchronous drain
/// worker. Callers never wait for policy persistence or Manager availability.
public final class StjornarvaldObservationEmitter: StjornarvaldObservationRecording, @unchecked Sendable {
    public static let maximumPendingCount = 256

    private let lock = NSLock()
    private let submitter: any PolicyObservationSubmitting
    private let shutdownSubmitter: @Sendable () async -> Void
    private let diagnostics: @Sendable (String) -> Void
    private var pending: [DevelopmentObservation] = []
    private var worker: Task<Void, Never>?
    private var droppedCount: UInt64 = 0
    private var accepting = true

    public init(
        submitter: any PolicyObservationSubmitting,
        shutdown: @escaping @Sendable () async -> Void = {},
        diagnostics: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.submitter = submitter
        shutdownSubmitter = shutdown
        self.diagnostics = diagnostics
    }

    public func record(_ observation: DevelopmentObservation) {
        var shouldStart = false
        var didDrop = false
        lock.lock()
        if accepting {
            if pending.count < Self.maximumPendingCount {
                pending.append(observation)
                if worker == nil { shouldStart = true }
            } else {
                droppedCount &+= 1
                didDrop = true
            }
            if shouldStart {
                worker = Task(priority: .userInitiated) { [weak self] in
                    await self?.drain()
                }
            }
        }
        lock.unlock()
        if didDrop {
            diagnostics("stjornarvald product observation queue is full; observation dropped")
        }
    }

    public func metrics() -> StjornarvaldObservationEmitterMetrics {
        lock.lock()
        defer { lock.unlock() }
        return StjornarvaldObservationEmitterMetrics(
            pendingCount: pending.count,
            droppedCount: droppedCount,
            workerActive: worker != nil,
            accepting: accepting
        )
    }

    /// Stops admission, drains retained observations, then stops the transport.
    /// The wait is bounded; a non-cooperative dependency cannot stall app shutdown.
    @discardableResult
    public func shutdown(timeoutSeconds: TimeInterval = 3) -> Bool {
        lock.lock()
        accepting = false
        let current = worker
        lock.unlock()

        let semaphore = DispatchSemaphore(value: 0)
        let finish = shutdownSubmitter
        let waiter = Task.detached(priority: .userInitiated) {
            _ = await current?.result
            await finish()
            semaphore.signal()
        }
        let completed = semaphore.wait(timeout: .now() + max(0.05, timeoutSeconds)) == .success
        if !completed {
            current?.cancel()
            waiter.cancel()
            diagnostics("stjornarvald product observation shutdown reached its deadline")
        }
        return completed
    }

    private func drain() async {
        while !Task.isCancelled {
            guard let observation = takeNextOrFinish() else { return }
            await submitter.submit(observation)
        }
        finishWorker()
    }

    private func takeNextOrFinish() -> DevelopmentObservation? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else {
            worker = nil
            return nil
        }
        return pending.removeFirst()
    }

    private func finishWorker() {
        lock.lock()
        worker = nil
        lock.unlock()
    }
}

enum StjornarvaldProductObservationFactory {
    static func managerStarted(observedAt: Date = Date()) -> DevelopmentObservation {
        let id = UUID()
        let digest = JSONSupport.sha256Hex("manager_started")
        return DevelopmentObservation(
            id: id,
            idempotencyKey: "manager-started:\(id.uuidString.lowercased())",
            kind: .sessionStarted,
            observedAt: observedAt,
            subjectIdentity: "manager:stjornarvald",
            summary: "Manager observation delivery became available.",
            evidenceReferences: ["state_sha256:\(digest)"],
            payloadSHA256: digest
        )
    }

    static func ordinaryTool(
        name: String,
        result: ToolResult,
        context: ToolInvocationContext?,
        clientID: ClientID,
        observedAt: Date = Date()
    ) -> DevelopmentObservation {
        let digest = resultDigest(result)
        let id = UUID()
        return DevelopmentObservation(
            id: id,
            idempotencyKey: "ordinary-tool:\(id.uuidString.lowercased())",
            kind: .toolInvocationCompleted,
            observedAt: observedAt,
            scope: scope(context: context, clientID: clientID),
            subjectIdentity: bounded("tool:\(name)", maximumBytes: 1_024),
            summary: bounded(
                "Tool \(name) completed with status \(result.ok ? "ok" : "error").",
                maximumBytes: 4_096
            ),
            evidenceReferences: ["tool:\(bounded(name, maximumBytes: 512))", "result_sha256:\(digest)"],
            payloadSHA256: digest
        )
    }

    static func managedTool(
        call: BrokeredToolCall,
        result: ToolResult,
        context: ToolInvocationContext,
        observedAt: Date = Date()
    ) -> DevelopmentObservation {
        let digest = resultDigest(result)
        let identity = [
            "managed-tool", context.projectID.description,
            String(context.projectGeneration.rawValue), context.runID?.description ?? "",
            context.providerSessionID ?? "", call.providerCallID, call.toolName, digest,
        ].joined(separator: "\u{0}")
        let key = "managed-tool:\(JSONSupport.sha256Hex(identity))"
        return DevelopmentObservation(
            id: deterministicUUID(key),
            idempotencyKey: key,
            kind: .toolInvocationCompleted,
            observedAt: observedAt,
            scope: scope(context: context, clientID: context.clientID),
            subjectIdentity: bounded("tool:\(call.toolName)", maximumBytes: 1_024),
            summary: bounded(
                "Managed tool \(call.toolName) completed with status \(result.ok ? "ok" : "error").",
                maximumBytes: 4_096
            ),
            evidenceReferences: [
                "tool:\(bounded(call.toolName, maximumBytes: 512))",
                "provider_call_sha256:\(JSONSupport.sha256Hex(call.providerCallID))",
                "result_sha256:\(digest)",
            ],
            payloadSHA256: digest
        )
    }

    static func completionClaim(
        run: AutonomousRunRecord,
        requestSHA256: String,
        observedAt: Date = Date()
    ) -> DevelopmentObservation {
        let key = "completion:\(run.runID.description):\(requestSHA256)"
        return DevelopmentObservation(
            id: deterministicUUID(key),
            idempotencyKey: key,
            kind: .completionClaimObserved,
            observedAt: observedAt,
            scope: DevelopmentObservationScope(
                projectID: run.projectID.description,
                projectGeneration: Int(exactly: run.projectGeneration.rawValue),
                runID: run.runID.description,
                sessionID: run.activeSessionID,
                clientID: "autonomy:\(run.runID.description)"
            ),
            subjectIdentity: "run:\(run.runID.description)",
            summary: "Managed run requested deterministic completion validation.",
            evidenceReferences: ["completion_request_sha256:\(requestSHA256)"],
            payloadSHA256: requestSHA256
        )
    }

    private static func scope(
        context: ToolInvocationContext?,
        clientID: ClientID
    ) -> DevelopmentObservationScope {
        DevelopmentObservationScope(
            projectID: context?.projectID.description,
            projectGeneration: context.flatMap { Int(exactly: $0.projectGeneration.rawValue) },
            runID: context?.runID?.description,
            sessionID: context?.providerSessionID,
            clientID: clientID.rawValue
        )
    }

    private static func resultDigest(_ result: ToolResult) -> String {
        let encoded = (try? JSONSupport.canonicalJSON([
            "ok": result.ok,
            "is_error": result.isError,
            "payload": result.payload,
        ])) ?? "result_encoding_unavailable:\(result.ok):\(result.isError)"
        return JSONSupport.sha256Hex(encoded)
    }

    private static func deterministicUUID(_ value: String) -> UUID {
        let digest = String(JSONSupport.sha256Hex(value).prefix(32))
        let formatted = "\(digest.prefix(8))-\(digest.dropFirst(8).prefix(4))-\(digest.dropFirst(12).prefix(4))-\(digest.dropFirst(16).prefix(4))-\(digest.dropFirst(20))"
        return UUID(uuidString: formatted) ?? UUID()
    }

    private static func bounded(_ value: String, maximumBytes: Int) -> String {
        var result = ""
        var count = 0
        for character in value {
            let width = String(character).utf8.count
            if count + width > maximumBytes { break }
            result.append(character)
            count += width
        }
        return result
    }
}

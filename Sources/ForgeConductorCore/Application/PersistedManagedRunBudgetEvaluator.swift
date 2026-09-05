// Production bridge from managed provider/tool observations to the persisted budget actor.

import Foundation

public actor PersistedManagedRunBudgetEvaluator: ManagedRunBudgetEvaluating {
    public static let maximumCachedSessions = 128

    private let repository: ProjectControlPlaneRepository
    private let clock: any Clock
    private let policyOverride: ContextBudgetPolicy?
    private var supervisors: [String: ContextBudgetSupervisor] = [:]
    private var cacheOrder: [String] = []

    public init(
        repository: ProjectControlPlaneRepository,
        clock: any Clock = SystemClock(),
        policyOverride: ContextBudgetPolicy? = nil
    ) {
        self.repository = repository
        self.clock = clock
        self.policyOverride = policyOverride
    }

    public func evaluateBeforeProviderTurn(
        run: AutonomousRunRecord,
        sessionID: String,
        capabilities: ProviderCapabilities,
        serializedInputBytes: Int
    ) async throws -> ContextBudgetAction {
        let supervisor = try await supervisor(
            run: run,
            sessionID: sessionID,
            capabilities: capabilities
        )
        let snapshot = await supervisor.snapshot()
        let measurement: ContextBudgetMeasurement
        if snapshot.state.latestObservation == nil {
            measurement = .serializedEstimate(SerializedContextFootprint(
                messageBytes: serializedInputBytes,
                projectedNextTurnBytes: serializedInputBytes
            ))
        } else {
            measurement = .current
        }
        let receipt = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
            triggerPoint: run.state == .recovering ? .managerRecovery : .beforeProviderTurn,
            providerResponseID: snapshot.state.latestObservation?.providerResponseID,
            measurement: measurement
        ))
        return receipt.observation.action
    }

    public func observeProviderTurn(
        _ turn: ProviderTurn,
        run: AutonomousRunRecord,
        sessionID: String,
        capabilities: ProviderCapabilities
    ) async throws -> ContextBudgetAction {
        let supervisor = try await supervisor(
            run: run,
            sessionID: sessionID,
            capabilities: capabilities
        )
        let measurement: ContextBudgetMeasurement
        if let usage = turn.usage {
            switch usage.source {
            case .providerExact:
                measurement = .providerExact(usedTokens: usage.inputTokens)
            case .tokenizerExact:
                measurement = .tokenizerExact(usedTokens: usage.inputTokens)
            case .serializedEstimate:
                measurement = .serializedEstimate(SerializedContextFootprint(
                    messageBytes: turn.messages.reduce(0) { $0 + $1.utf8.count },
                    projectedNextTurnBytes: turn.messages.reduce(0) { $0 + $1.utf8.count }
                ))
            case .providerOverflow:
                measurement = .providerOverflow(lastKnownUsedTokens: usage.inputTokens)
            }
        } else {
            let bytes = max(1, turn.messages.reduce(0) { $0 + $1.utf8.count })
            let snapshot = await supervisor.snapshot()
            measurement = snapshot.state.latestObservation == nil
                ? .serializedEstimate(SerializedContextFootprint(
                    messageBytes: bytes,
                    projectedNextTurnBytes: bytes
                ))
                : .serializedIncrement(bytes: bytes)
        }
        let receipt = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
            triggerPoint: .afterProviderTurn,
            providerResponseID: turn.responseID,
            measurement: measurement,
            growth: ContextBudgetGrowthSample(
                assistantOutputTokens: turn.usage?.outputTokens,
                projectedNextTurnTokens: turn.usage?.outputTokens
            )
        ))
        return receipt.observation.action
    }

    public func observeToolResult(
        serializedBytes: Int,
        providerResponseID: String,
        run: AutonomousRunRecord,
        sessionID: String,
        capabilities: ProviderCapabilities
    ) async throws -> ContextBudgetAction {
        let supervisor = try await supervisor(
            run: run,
            sessionID: sessionID,
            capabilities: capabilities
        )
        let receipt = try await supervisor.observeToolResult(
            serializedBytes: serializedBytes,
            providerResponseID: providerResponseID
        )
        return receipt.observation.action
    }

    public func observeProviderOverflow(
        run: AutonomousRunRecord,
        sessionID: String,
        capabilities: ProviderCapabilities
    ) async throws -> ContextBudgetAction {
        let supervisor = try await supervisor(
            run: run,
            sessionID: sessionID,
            capabilities: capabilities
        )
        let latest = await supervisor.current()
        let receipt = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
            triggerPoint: .providerOverflow,
            providerResponseID: latest?.providerResponseID,
            measurement: .providerOverflow(lastKnownUsedTokens: latest?.used)
        ))
        return receipt.observation.action
    }

    private func supervisor(
        run: AutonomousRunRecord,
        sessionID: String,
        capabilities: ProviderCapabilities
    ) async throws -> ContextBudgetSupervisor {
        let identity = ContextBudgetIdentity(
            runID: run.runID,
            projectID: run.projectID,
            projectGeneration: run.projectGeneration,
            sessionID: sessionID
        )
        let key = Self.key(identity)
        if let existing = supervisors[key] { return existing }
        let configuration = try Self.configuration(capabilities: capabilities, policyOverride: policyOverride)
        let value: ContextBudgetSupervisor
        do {
            value = try await ContextBudgetSupervisor.open(
                repository: repository,
                identity: identity,
                configuration: configuration,
                clock: clock
            )
        } catch let error as ContextBudgetError where error == .configurationMismatch {
            let restored = try await ContextBudgetSupervisor.restore(
                repository: repository,
                identity: identity,
                clock: clock
            )
            _ = try await restored.reconfigure(configuration)
            value = restored
        }
        remember(value, key: key)
        return value
    }

    private func remember(_ supervisor: ContextBudgetSupervisor, key: String) {
        if supervisors[key] == nil { cacheOrder.append(key) }
        supervisors[key] = supervisor
        while cacheOrder.count > Self.maximumCachedSessions {
            supervisors.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    static func configuration(
        capabilities: ProviderCapabilities,
        policyOverride: ContextBudgetPolicy? = nil
    ) throws -> ContextBudgetConfiguration {
        let capacity = capabilities.contextLength
        let minimumUsable = min(1_024, max(128, capacity / 4))
        let reserves = ContextBudgetReserves(
            outputTokens: min(4_096, max(128, capacity / 16)),
            schemaTokens: min(4_096, max(64, capacity / 32)),
            handoffTokens: min(8_192, max(128, capacity / 16)),
            recoveryTokens: min(4_096, max(64, capacity / 32))
        )
        let resolution = ContextCapacityResolution(
            providerID: capabilities.providerID,
            providerVersionFingerprint: capabilities.capabilityFingerprintSHA256,
            modelKey: capabilities.modelKey,
            activeInstanceID: capabilities.providerInstanceID,
            capacity: capacity,
            maximumContextLength: capabilities.maximumContextLength ?? capacity,
            requiresModelLoad: false
        )
        return try ContextBudgetConfiguration(
            capacity: resolution,
            reserves: reserves,
            policy: policyOverride ?? ContextBudgetPolicy(
                initialProjectedNextTurnTokens: min(1_024, max(128, capacity / 64)),
                minimumUsableTokens: minimumUsable
            )
        ).validated()
    }

    private static func key(_ identity: ContextBudgetIdentity) -> String {
        "\(identity.runID.description):\(identity.projectID.description):\(identity.projectGeneration.rawValue):\(identity.sessionID)"
    }
}

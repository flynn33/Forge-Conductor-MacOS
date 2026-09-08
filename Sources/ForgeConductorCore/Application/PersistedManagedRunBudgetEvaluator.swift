// Production bridge from managed provider/tool observations to the persisted budget actor.

import Foundation

public actor PersistedManagedRunBudgetEvaluator: ManagedRunBudgetEvaluating {
    public static let maximumCachedSessions = 128
    public typealias PolicyResolver = @Sendable (BudgetPolicyScope) throws -> BudgetPolicySelection

    private let repository: ProjectControlPlaneRepository
    private let clock: any Clock
    private let policyOverride: ContextBudgetPolicy?
    private let policyResolver: PolicyResolver?
    private var supervisors: [String: ContextBudgetSupervisor] = [:]
    private var cacheOrder: [String] = []

    public init(
        repository: ProjectControlPlaneRepository,
        clock: any Clock = SystemClock(),
        policyOverride: ContextBudgetPolicy? = nil,
        policyResolver: PolicyResolver? = nil
    ) {
        self.repository = repository
        self.clock = clock
        self.policyOverride = policyOverride
        self.policyResolver = policyResolver
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

    public func evaluateBeforeProviderTurn(
        run: AutonomousRunRecord, sessionID: String, capabilities: ProviderCapabilities,
        accounting: ManagedBudgetInputAccounting
    ) async throws -> ContextBudgetAction {
        guard accounting.inputBytes >= 0, accounting.toolSchemaBytes >= 0 else {
            throw ContextBudgetError.invalidObservation("negative request accounting")
        }
        let supervisor = try await supervisor(run: run, sessionID: sessionID, capabilities: capabilities)
        let snapshot = await supervisor.snapshot()
        let latest = snapshot.state.latestObservation
        let measurement: ContextBudgetMeasurement
        if latest?.accounting?.pendingInputID == accounting.pendingInputID {
            // Repeating a preflight after a crash or a delivery retry does not
            // retain another copy of the same request.
            measurement = .current
        } else {
            let inputBytes = accounting.inputAlreadyRetained && latest != nil ? 0 : accounting.inputBytes
            let schemaBytes = latest?.accounting?.toolSchemaSHA256 == accounting.toolSchemaSHA256
                ? 0 : accounting.toolSchemaBytes
            let added = inputBytes.addingReportingOverflow(schemaBytes)
            guard !added.overflow else { throw ContextBudgetError.arithmeticOverflow }
            if latest == nil {
                measurement = .serializedEstimate(SerializedContextFootprint(messageBytes: inputBytes,
                                                                             toolSchemaBytes: schemaBytes))
            } else if added.partialValue == 0 {
                measurement = .current
            } else {
                measurement = .serializedIncrement(bytes: added.partialValue)
            }
        }
        return try await supervisor.evaluate(ContextBudgetEvaluationRequest(
            triggerPoint: run.state == .recovering ? .managerRecovery : .beforeProviderTurn,
            providerResponseID: latest?.providerResponseID,
            measurement: measurement,
            toolSchemaSHA256: accounting.toolSchemaSHA256,
            pendingInputID: accounting.pendingInputID
        )).observation.action
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
                measurement = .providerExact(usedTokens: try Self.retainedTokensAfterResponse(usage))
            case .tokenizerExact:
                measurement = .tokenizerExact(usedTokens: try Self.retainedTokensAfterResponse(usage))
            case .serializedEstimate:
                let snapshot = await supervisor.snapshot()
                let responseEstimate = try ContextBudgetMath.estimateTokens(
                    serializedBytes: Self.serializedResponseBytes(turn), policy: snapshot.state.configuration.policy)
                let local = (snapshot.state.latestObservation?.used ?? 0).addingReportingOverflow(responseEstimate)
                guard !local.overflow else { throw ContextBudgetError.arithmeticOverflow }
                measurement = .estimatedTokens(
                    usedTokens: max(try Self.retainedTokensAfterResponse(usage), local.partialValue),
                    confidence: usage.confidence
                )
            case .providerOverflow:
                measurement = .providerOverflow(lastKnownUsedTokens: usage.inputTokens)
            }
        } else {
            let bytes = max(1, try Self.serializedResponseBytes(turn))
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
            ),
            rawProviderUsage: turn.usage,
            accountingCut: "retained_input_after_response"
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
        guard let policyGeneration = Int(exactly: run.projectGeneration.rawValue) else {
            throw ContextBudgetError.invalidPolicy
        }
        let selection = try policyResolver?(BudgetPolicyScope(
            kind: .projectOverride, projectID: run.projectID.description,
            projectGeneration: policyGeneration
        ))
        let configuration = try Self.configuration(capabilities: capabilities, policyOverride: policyOverride,
                                                   selection: selection)
        if let existing = supervisors[key] {
            // Re-resolve even a cached session: settings edits and provider/model
            // reconnects become effective at this controlled boundary.
            let snapshot = await existing.snapshot()
            if snapshot.state.configuration != configuration {
                _ = try await existing.reconfigure(configuration)
            }
            return existing
        }
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
        policyOverride: ContextBudgetPolicy? = nil,
        selection: BudgetPolicySelection? = nil
    ) throws -> ContextBudgetConfiguration {
        let loadedCapacity = capabilities.contextLength
        let context = try selection?.policy.validated().context
        let capacity = context?.mode == .manual
            ? min(context!.maxContextTokens, loadedCapacity) : loadedCapacity
        let minimumUsable = min(1_024, max(128, capacity / 4))
        let reserves = ContextBudgetReserves(
            outputTokens: context?.responseReserveTokens ?? min(4_096, max(128, capacity / 16)),
            // Native managed requests include their schemas in retained input.
            // Preserve the legacy reserve only for legacy configurations.
            schemaTokens: selection == nil ? min(4_096, max(64, capacity / 32)) : 0,
            handoffTokens: context?.handoffReserveTokens ?? min(8_192, max(128, capacity / 16)),
            recoveryTokens: context?.recoveryReserveTokens ?? min(4_096, max(64, capacity / 32)),
            futureToolTokens: selection == nil ? 0 : (context?.futureToolReserveTokens ?? min(4_096, max(64, capacity / 32))),
            safetyTokens: context?.safetyReserveTokens ?? 0
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
        // Validate the actual loaded identity before applying any operator clamp;
        // a preference cannot disguise an invalid or absent loaded capacity.
        let loaded = ContextCapacityResolution(
            providerID: capabilities.providerID,
            providerVersionFingerprint: capabilities.capabilityFingerprintSHA256,
            modelKey: capabilities.modelKey,
            activeInstanceID: capabilities.providerInstanceID,
            capacity: loadedCapacity,
            maximumContextLength: capabilities.maximumContextLength ?? loadedCapacity,
            requiresModelLoad: false
        )
        try loaded.validateForExecution(reserves: .init(outputTokens: 0, schemaTokens: 0,
                                                       handoffTokens: 0, recoveryTokens: 0),
                                        minimumUsableTokens: 1)
        return try ContextBudgetConfiguration(
            capacity: resolution,
            reserves: reserves,
            policy: policyOverride ?? ContextBudgetPolicy(
                initialProjectedNextTurnTokens: min(1_024, max(128, capacity / 64)),
                minimumUsableTokens: minimumUsable
            ),
            resolvedPolicy: try selection.map {
                try ResolvedContextBudgetPolicy(selection: $0, verifiedLoadedContextTokens: loadedCapacity,
                                                effectiveContextTokens: capacity, qualificationPolicy: policyOverride).validated()
            }
        ).validated()
    }

    /// Provider input/output are explicitly defined counters at the response
    /// boundary. The endpoint's aggregate total is retained only for diagnosis;
    /// it is not assumed to represent the next request's retained input.
    static func retainedTokensAfterResponse(_ usage: ProviderUsage) throws -> Int {
        let count = usage.inputTokens.addingReportingOverflow(usage.outputTokens)
        guard usage.inputTokens >= 0, usage.outputTokens >= 0, !count.overflow else {
            throw ContextBudgetError.arithmeticOverflow
        }
        return count.partialValue
    }

    private static func serializedResponseBytes(_ turn: ProviderTurn) throws -> Int {
        let messageBytes = turn.messages.map { $0.utf8.count }
        let toolBytes = turn.toolCalls.map { $0.argumentsJSON.count + $0.name.utf8.count + $0.callID.utf8.count }
        let structuredBytes = turn.structuredOutputJSON.map { [$0.count] } ?? []
        return try (messageBytes + toolBytes + structuredBytes).reduce(0) { total, count in
            let sum = total.addingReportingOverflow(count)
            guard !sum.overflow, sum.partialValue <= 64 * 1_024 * 1_024 else {
                throw ContextBudgetError.serializedInputTooLarge
            }
            return sum.partialValue
        }
    }

    private static func key(_ identity: ContextBudgetIdentity) -> String {
        "\(identity.runID.description):\(identity.projectID.description):\(identity.projectGeneration.rawValue):\(identity.sessionID)"
    }
}

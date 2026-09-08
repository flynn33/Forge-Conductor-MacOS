// Production bridge from managed provider/tool observations to the persisted budget actor.

import Foundation

public actor PersistedManagedRunBudgetEvaluator: ManagedRunToolResultBudgetEvaluating {
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
            capabilities: capabilities,
            requiresProviderPreflight: true
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
        let supervisor = try await supervisor(run: run, sessionID: sessionID, capabilities: capabilities,
            providerPreflight: accounting.providerPreflight, requiresProviderPreflight: true)
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
        let request = ContextBudgetEvaluationRequest(
            triggerPoint: .afterProviderTurn,
            providerResponseID: turn.responseID,
            measurement: measurement,
            growth: ContextBudgetGrowthSample(
                assistantOutputTokens: turn.usage?.outputTokens,
                projectedNextTurnTokens: turn.usage?.outputTokens
            ),
            rawProviderUsage: turn.usage,
            accountingCut: "retained_input_after_response"
        )
        if await supervisor.snapshot().state.configuration.resolvedPolicy?.inheritedSourceBudget != nil {
            guard turn.providerID == capabilities.providerID, turn.providerVersion == capabilities.providerVersion,
                  turn.modelKey == capabilities.modelKey, turn.providerInstanceID == capabilities.providerInstanceID else {
                throw ContextBudgetError.configurationMismatch
            }
            return try await supervisor.observeSourceProviderTurn(turn, request: request)
        }
        return try await supervisor.evaluate(request).observation.action
    }

    public func evaluateBeforeToolResult(
        run: AutonomousRunRecord, sessionID: String, capabilities: ProviderCapabilities,
        projection: ManagedToolResultProjection
    ) async throws -> ContextBudgetAction {
        let supervisor = try await supervisor(run: run, sessionID: sessionID, capabilities: capabilities,
            providerPreflight: projection.continuationPreflight, requiresProviderPreflight: true)
        guard let carryover = try await repository.nativeSourceBudgetCarryover(runID: run.runID) else {
            throw ContextBudgetError.invalidPolicy
        }
        let context = try await repository.invocationContext(
            for: ProjectBindingOwner(kind: .providerSession, id: sessionID))
        guard context.runID == run.runID, context.projectID == run.projectID,
              context.projectGeneration == run.projectGeneration else {
            throw ContextBudgetError.configurationMismatch
        }
        // Reserve the complete originally approved result, even when a current
        // output policy is tighter. The completion guard enforces that current
        // policy; a settings race must never become implicit truncation here.
        let fullBound = min(65_536, context.authorizationScope.maximumInlineOutputBytes,
                            carryover.ceilings.tools.maxResultBytes)
        guard projection.maximumToolResultBytes == fullBound else {
            throw ContextBudgetError.invalidObservation("tool projection changed the approved result ceiling")
        }
        return try await supervisor.projectToolResult(projection)
    }

    /// Seed the fresh managed session from its actual canonical bootstrap ACK.
    /// The caller obtains the ACK and retained byte bound under the CP lease;
    /// cumulative source-conversation usage is never accepted as this input.
    public func seedSourceProviderTurn(
        run: AutonomousRunRecord, sessionID: String, capabilities: ProviderCapabilities,
        turn: ProviderTurn, retainedContextSerializedBytes: Int
    ) async throws -> ContextBudgetAction {
        let supervisor = try await supervisor(run: run, sessionID: sessionID, capabilities: capabilities)
        let snapshot = await supervisor.snapshot()
        guard snapshot.state.configuration.resolvedPolicy?.inheritedSourceBudget != nil,
              turn.providerID == capabilities.providerID, turn.providerVersion == capabilities.providerVersion,
              turn.modelKey == capabilities.modelKey, turn.providerInstanceID == capabilities.providerInstanceID,
              retainedContextSerializedBytes > 0 else {
            throw ContextBudgetError.configurationMismatch
        }
        let request = try Self.sourceSeedRequest(turn: turn, retainedContextSerializedBytes: retainedContextSerializedBytes,
                                                policy: snapshot.state.configuration.policy)
        return try await supervisor.observeSourceProviderTurn(turn, request: request,
            seedRetainedContextSerializedBytes: retainedContextSerializedBytes)
    }

    static func sourceSeedRequest(turn: ProviderTurn, retainedContextSerializedBytes: Int,
                                  policy: ContextBudgetPolicy) throws -> ContextBudgetEvaluationRequest {
        guard retainedContextSerializedBytes > 0 else { throw ContextBudgetError.serializedInputTooLarge }
        let estimate = try ContextBudgetMath.estimateTokens(serializedBytes: retainedContextSerializedBytes, policy: policy)
        let measurement: ContextBudgetMeasurement
        if let usage = turn.usage {
            switch usage.source {
            case .providerExact: measurement = .providerExact(usedTokens: try retainedTokensAfterResponse(usage))
            case .tokenizerExact: measurement = .tokenizerExact(usedTokens: try retainedTokensAfterResponse(usage))
            case .serializedEstimate:
                measurement = .estimatedTokens(usedTokens: max(estimate, try retainedTokensAfterResponse(usage)),
                                                confidence: usage.confidence)
            case .providerOverflow: measurement = .providerOverflow(lastKnownUsedTokens: usage.inputTokens)
            }
        } else {
            measurement = .serializedEstimate(.init(messageBytes: retainedContextSerializedBytes))
        }
        return ContextBudgetEvaluationRequest(triggerPoint: .afterProviderTurn, providerResponseID: turn.responseID,
            measurement: measurement,
            growth: .init(assistantOutputTokens: turn.usage?.outputTokens, projectedNextTurnTokens: turn.usage?.outputTokens),
            rawProviderUsage: turn.usage, accountingCut: "retained_input_after_response")
    }

    public func observeToolResultPrefix(
        run: AutonomousRunRecord, sessionID: String, capabilities: ProviderCapabilities,
        prefix: ManagedToolResultPrefix
    ) async throws -> ContextBudgetAction {
        let supervisor = try await supervisor(run: run, sessionID: sessionID, capabilities: capabilities)
        return try await supervisor.observeToolResultPrefix(prefix)
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
        capabilities: ProviderCapabilities,
        providerPreflight: ProviderRequestPreflight? = nil,
        requiresProviderPreflight: Bool = false
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
        // The source receipt is independently revalidated even for a cached
        // supervisor. Cumulative source usage is audit evidence, not retained
        // context in this fresh managed session.
        let carryover = try await repository.nativeSourceBudgetCarryover(runID: run.runID)
        let inheritance = try carryover.map { try InheritedSourceContextBudget(carryover: $0) }
        guard inheritance == nil || inheritance?.runID == run.runID else {
            throw ContextBudgetError.configurationMismatch
        }
        guard inheritance == nil || !requiresProviderPreflight || providerPreflight != nil else {
            throw ContextBudgetError.invalidPolicy
        }
        let configuration = try Self.configuration(capabilities: capabilities, policyOverride: policyOverride,
                                                   selection: selection, inheritance: inheritance,
                                                   providerPreflight: providerPreflight)
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
        selection: BudgetPolicySelection? = nil,
        inheritance: InheritedSourceContextBudget? = nil,
        providerPreflight: ProviderRequestPreflight? = nil
    ) throws -> ContextBudgetConfiguration {
        _ = try inheritance?.validated()
        guard inheritance == nil || selection != nil else { throw ContextBudgetError.invalidPolicy }
        let loadedCapacity = capabilities.contextLength
        let context = try selection?.policy.validated().context
        let selectedCapacity = context?.mode == .manual
            ? min(context!.maxContextTokens, loadedCapacity) : loadedCapacity
        let capacity = min(selectedCapacity, inheritance?.effectiveContextTokens ?? selectedCapacity)
        if let providerPreflight {
            guard providerPreflight.modelKey == capabilities.modelKey else {
                throw ContextBudgetError.configurationMismatch
            }
            guard providerPreflight.limits.maximumOutputTokens <= capacity,
                  providerPreflight.limits.maximumOutputTokens <= (inheritance?.maximumOutputTokens ?? capacity) else {
                throw ContextBudgetError.insufficientUsableCapacity
            }
        }
        let minimumUsable = min(1_024, max(128, capacity / 4))
        let floors = inheritance?.reserves
        let reserves = ContextBudgetReserves(
            outputTokens: max(context?.responseReserveTokens ?? min(4_096, max(128, capacity / 16)),
                              floors?.outputTokens ?? 0, inheritance?.maximumOutputTokens ?? 0,
                              providerPreflight?.limits.maximumOutputTokens ?? 0),
            // Native managed requests include their schemas in retained input.
            // Preserve the legacy reserve only for legacy configurations.
            schemaTokens: max(selection == nil ? min(4_096, max(64, capacity / 32)) : 0,
                              floors?.schemaTokens ?? 0),
            handoffTokens: max(context?.handoffReserveTokens ?? min(8_192, max(128, capacity / 16)),
                               floors?.handoffTokens ?? 0),
            recoveryTokens: max(context?.recoveryReserveTokens ?? min(4_096, max(64, capacity / 32)),
                                floors?.recoveryTokens ?? 0),
            futureToolTokens: max(selection == nil ? 0 : (context?.futureToolReserveTokens ?? min(4_096, max(64, capacity / 32))),
                                  floors?.futureToolTokens ?? 0),
            safetyTokens: max(context?.safetyReserveTokens ?? 0, floors?.safetyTokens ?? 0)
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
                                                effectiveContextTokens: capacity, qualificationPolicy: policyOverride,
                                                inheritedSourceBudget: inheritance).validated()
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

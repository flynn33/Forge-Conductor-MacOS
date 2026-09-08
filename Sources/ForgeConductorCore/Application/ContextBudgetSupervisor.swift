// ContextBudgetSupervisor.swift
// Evaluates and persists run-scoped context pressure before scheduling durable actions.

import Foundation

public enum ContextBudgetMath {
    public static func thresholds(
        configuration: ContextBudgetConfiguration,
        projectedNextTurn: Int
    ) throws -> ContextBudgetThresholds {
        _ = try configuration.validated()
        guard projectedNextTurn >= 0 else {
            throw ContextBudgetError.invalidObservation("projected next turn is negative")
        }
        if let resolved = configuration.resolvedPolicy {
            // Operator ratios are defined on I + R over C. Convert once to the
            // remaining-capacity comparison used by the state machine. Reserves
            // are already in R; adaptive legacy reserves must not be added again.
            let capacity = configuration.capacity.capacity
            return ContextBudgetThresholds(
                checkpoint: capacity - (try fractionTokens(capacity, resolved.effectiveCheckpointRatio)),
                rollover: capacity - (try fractionTokens(capacity, resolved.effectiveRolloverRatio)),
                emergency: capacity - (try fractionTokens(capacity, resolved.effectiveEmergencyRatio)),
                hysteresis: try fractionTokens(capacity, configuration.policy.hysteresisFraction)
            )
        }
        let usable = configuration.usableCapacity
        let policy = configuration.policy
        let checkpointFraction = try fractionTokens(usable, policy.checkpointFraction)
        let rolloverFraction = try fractionTokens(usable, policy.rolloverFraction)
        let emergencyFraction = try fractionTokens(usable, policy.emergencyFraction)
        let hysteresis = try fractionTokens(usable, policy.hysteresisFraction)

        let twoProjected = try multiplied(projectedNextTurn, by: 2)
        let checkpointAdaptive = try added(twoProjected, configuration.reserves.handoffTokens)
        let rolloverAdaptive = try added(
            try added(projectedNextTurn, configuration.reserves.handoffTokens),
            configuration.reserves.recoveryTokens
        )
        let emergencyAdaptive = try added(
            configuration.reserves.handoffTokens,
            configuration.reserves.recoveryTokens
        )

        let emergency = min(usable, max(emergencyFraction, emergencyAdaptive))
        let rollover = min(usable, max(emergency, max(rolloverFraction, rolloverAdaptive)))
        let checkpoint = min(usable, max(rollover, max(checkpointFraction, checkpointAdaptive)))
        return ContextBudgetThresholds(
            checkpoint: checkpoint,
            rollover: rollover,
            emergency: emergency,
            hysteresis: min(usable, hysteresis)
        )
    }

    public static func estimateTokens(
        serializedBytes: Int,
        policy: ContextBudgetPolicy
    ) throws -> Int {
        _ = try policy.validated()
        guard serializedBytes >= 0, serializedBytes <= policy.maximumSerializedBytes else {
            throw ContextBudgetError.serializedInputTooLarge
        }
        let estimate = ceil(
            (Double(serializedBytes) / policy.serializedBytesPerToken)
                * policy.estimateSafetyMultiplier
        )
        guard estimate.isFinite, estimate >= 0, let count = Int(exactly: estimate) else {
            throw ContextBudgetError.arithmeticOverflow
        }
        return count
    }

    private static func fractionTokens(_ total: Int, _ fraction: Double) throws -> Int {
        let value = ceil(Double(total) * fraction)
        guard value.isFinite, value >= 0, let count = Int(exactly: value) else {
            throw ContextBudgetError.arithmeticOverflow
        }
        return count
    }

    private static func added(_ lhs: Int, _ rhs: Int) throws -> Int {
        let value = lhs.addingReportingOverflow(rhs)
        guard !value.overflow else { throw ContextBudgetError.arithmeticOverflow }
        return value.partialValue
    }

    private static func multiplied(_ value: Int, by multiplier: Int) throws -> Int {
        let result = value.multipliedReportingOverflow(by: multiplier)
        guard !result.overflow else { throw ContextBudgetError.arithmeticOverflow }
        return result.partialValue
    }
}

public actor ContextBudgetSupervisor {
    public static let serializedEstimateConfidence = 0.65
    public static let tokenizerExactConfidence = 1.0

    public nonisolated let identity: ContextBudgetIdentity

    private let repository: ProjectControlPlaneRepository
    private let clock: any Clock
    private var state: PersistedContextBudgetState
    private var latestActionRequest: ContextBudgetActionRequest?

    private init(
        repository: ProjectControlPlaneRepository,
        identity: ContextBudgetIdentity,
        state: PersistedContextBudgetState,
        latestActionRequest: ContextBudgetActionRequest?,
        clock: any Clock
    ) {
        self.repository = repository
        self.identity = identity
        self.state = state
        self.latestActionRequest = latestActionRequest
        self.clock = clock
    }

    public static func open(
        repository: ProjectControlPlaneRepository,
        identity: ContextBudgetIdentity,
        configuration: ContextBudgetConfiguration,
        clock: any Clock = SystemClock()
    ) async throws -> ContextBudgetSupervisor {
        let identity = try identity.validated()
        let configuration = try configuration.validated()
        if let persisted = try await repository.contextBudgetState(identity: identity) {
            let persisted = try persisted.validated()
            guard persisted.configuration == configuration else {
                throw ContextBudgetError.configurationMismatch
            }
            let storedRequest = try await repository.contextBudgetActionRequest(identity: identity)
            let actionRequest = try Self.validatedActionRequest(
                for: persisted,
                stored: storedRequest
            )
            return ContextBudgetSupervisor(
                repository: repository,
                identity: identity,
                state: persisted,
                latestActionRequest: actionRequest,
                clock: clock
            )
        }
        let initial = PersistedContextBudgetState(
            identity: identity,
            configuration: configuration,
            updatedAt: ISO8601.string(from: clock.now())
        )
        return ContextBudgetSupervisor(
            repository: repository,
            identity: identity,
            state: initial,
            latestActionRequest: nil,
            clock: clock
        )
    }

    public static func restore(
        repository: ProjectControlPlaneRepository,
        identity: ContextBudgetIdentity,
        clock: any Clock = SystemClock()
    ) async throws -> ContextBudgetSupervisor {
        let identity = try identity.validated()
        guard let persisted = try await repository.contextBudgetState(identity: identity) else {
            throw ContextBudgetError.currentObservationRequired
        }
        let state = try persisted.validated()
        let storedRequest = try await repository.contextBudgetActionRequest(identity: identity)
        let actionRequest = try Self.validatedActionRequest(for: state, stored: storedRequest)
        return ContextBudgetSupervisor(
            repository: repository,
            identity: identity,
            state: state,
            latestActionRequest: actionRequest,
            clock: clock
        )
    }

    public func snapshot() -> ContextBudgetSupervisorSnapshot {
        ContextBudgetSupervisorSnapshot(
            state: state,
            latestActionRequest: latestActionRequest
        )
    }

    public func current() -> ContextBudgetObservation? {
        state.latestObservation
    }

    @discardableResult
    public func evaluate(
        _ request: ContextBudgetEvaluationRequest
    ) async throws -> ContextBudgetCommitReceipt {
        try await evaluate(request, replacingConfiguration: nil)
    }

    @discardableResult
    public func reconfigure(
        _ configuration: ContextBudgetConfiguration,
        observationID: UUID = UUID()
    ) async throws -> ContextBudgetCommitReceipt {
        guard state.latestObservation != nil else {
            throw ContextBudgetError.currentObservationRequired
        }
        return try await evaluate(
            ContextBudgetEvaluationRequest(
                observationID: observationID,
                triggerPoint: .providerConfigurationChanged,
                measurement: .current
            ),
            replacingConfiguration: try configuration.validated()
        )
    }

    @discardableResult
    public func observeToolResult(
        serializedBytes: Int,
        providerResponseID: String,
        observationID: UUID = UUID()
    ) async throws -> ContextBudgetCommitReceipt {
        let tokens = try ContextBudgetMath.estimateTokens(
            serializedBytes: serializedBytes,
            policy: state.configuration.policy
        )
        return try await evaluate(ContextBudgetEvaluationRequest(
            observationID: observationID,
            triggerPoint: .afterToolResult,
            providerResponseID: providerResponseID,
            measurement: .serializedIncrement(bytes: serializedBytes),
            growth: ContextBudgetGrowthSample(
                toolResultTokens: tokens,
                projectedNextTurnTokens: tokens
            )
        ))
    }

    /// Preserve the observed response and its charged outputs when the durable
    /// provider receipt is replayed. A later response begins a new bounded batch.
    func observeSourceProviderTurn(
        _ turn: ProviderTurn, request: ContextBudgetEvaluationRequest,
        seedRetainedContextSerializedBytes: Int? = nil
    ) async throws -> ContextBudgetAction {
        guard state.configuration.resolvedPolicy?.inheritedSourceBudget != nil,
              request.triggerPoint == .afterProviderTurn,
              request.providerResponseID == turn.responseID,
              request.rawProviderUsage == turn.usage,
              turn.toolCalls.allSatisfy({ ManagedToolResultBudgetValidation.identifier($0.callID, maximum: 512) }) else {
            throw ContextBudgetError.invalidObservation("source provider observation is not bound")
        }
        let digest = try ManagedToolResultBudgetValidation.turnSHA256(turn)
        if let retained = state.latestObservation?.accounting?.toolResultAccounting {
            _ = try retained.validated()
            if retained.providerResponseID == turn.responseID {
                guard retained.providerTurnSHA256 == digest,
                      state.latestObservation?.accounting?.rawProviderUsage == turn.usage,
                      seedRetainedContextSerializedBytes == nil
                        || retained.seedRetainedContextSerializedBytes == seedRetainedContextSerializedBytes else {
                    throw ContextBudgetError.invalidObservation("replayed provider response differs")
                }
                return state.action
            }
            guard turn.previousResponseID == retained.providerResponseID else {
                throw ContextBudgetError.invalidObservation("provider response does not extend retained history")
            }
        }
        guard seedRetainedContextSerializedBytes == nil || state.latestObservation == nil else {
            throw ContextBudgetError.invalidObservation("bootstrap budget seed would replace an existing observation")
        }
        let accounting = try ManagedToolResultAccounting(providerResponseID: turn.responseID,
            providerTurnSHA256: digest,
            expectedCallSHA256: turn.toolCalls.map { JSONSupport.sha256Hex(Data($0.callID.utf8)) },
            seedRetainedContextSerializedBytes: seedRetainedContextSerializedBytes)
        return try await evaluate(request, replacingConfiguration: nil,
            replacingToolResultAccounting: accounting, replaceRawProviderUsage: true).observation.action
    }

    /// Check prospective output without retaining speculative bytes, changing
    /// the observed usage, or scheduling a continuity operation.
    func projectToolResult(_ projection: ManagedToolResultProjection) throws -> ContextBudgetAction {
        guard let latest = state.latestObservation,
              let retained = latest.accounting?.toolResultAccounting,
              state.configuration.resolvedPolicy?.inheritedSourceBudget != nil,
              latest.providerResponseID == retained.providerResponseID,
              latest.accounting?.toolSchemaSHA256 == projection.toolSchemaSHA256 else {
            throw ContextBudgetError.invalidObservation("tool projection has no matching observed response")
        }
        try retained.validate(projection.priorPrefix)
        let ordinal = projection.priorPrefix.outputCount
        guard ordinal < retained.expectedCallSHA256.count,
              retained.expectedCallSHA256[ordinal] == JSONSupport.sha256Hex(Data(projection.providerCallID.utf8)) else {
            throw ContextBudgetError.invalidObservation("tool projection call order differs")
        }
        // A completed call is recovered through its original broker receipt.
        // Its actual prefix has already been charged, including later prefixes.
        if ordinal < retained.prefixes.count { return state.action }
        let preflight = projection.continuationPreflight
        guard preflight.modelKey == state.configuration.capacity.modelKey,
              let inputBytes = preflight.serializedInputByteCount else {
            throw ContextBudgetError.configurationMismatch
        }
        let escaped = projection.maximumToolResultBytes.multipliedReportingOverflow(by: CanonicalToolResultOutputBounds.maximumStringExpansion)
        let body = preflight.bodyByteCount.addingReportingOverflow(escaped.partialValue)
        let input = inputBytes.addingReportingOverflow(escaped.partialValue)
        guard !escaped.overflow, !body.overflow, !input.overflow,
              body.partialValue <= preflight.limits.maximumRequestBytes,
              input.partialValue <= ManagedModelProviderContract.maximumContinuationInputBytes else {
            throw ContextBudgetError.serializedInputTooLarge
        }
        let deltaBytes = input.partialValue - projection.priorPrefix.serializedInputByteCount
        let delta = try ContextBudgetMath.estimateTokens(serializedBytes: deltaBytes,
                                                        policy: state.configuration.policy)
        let used = latest.used.addingReportingOverflow(delta)
        guard !used.overflow else { throw ContextBudgetError.arithmeticOverflow }
        if latest.source == .providerOverflow { return .emergency }
        let remaining = state.configuration.capacity.capacity
            - (try state.configuration.reserves.fixedTotal()) - used.partialValue
        let thresholds = try ContextBudgetMath.thresholds(configuration: state.configuration,
            projectedNextTurn: state.ewma.projectedNextTurn(default: state.configuration.policy.initialProjectedNextTurnTokens))
        return Self.applyHysteresis(rawAction: Self.rawAction(remaining: remaining, thresholds: thresholds),
            priorAction: state.action, remaining: remaining, thresholds: thresholds)
    }

    /// Charge only the new bytes of the actual transport input array. Every
    /// retained ordinal is checked on replay, not only the latest ordinal.
    func observeToolResultPrefix(_ prefix: ManagedToolResultPrefix) async throws -> ContextBudgetAction {
        guard let latest = state.latestObservation,
              let retained = latest.accounting?.toolResultAccounting,
              latest.providerResponseID == retained.providerResponseID,
              state.configuration.resolvedPolicy?.inheritedSourceBudget != nil else {
            throw ContextBudgetError.invalidObservation("tool output has no observed source response")
        }
        if prefix.outputCount <= retained.prefixes.count {
            try retained.validate(prefix)
            return state.action
        }
        let updated = try retained.appending(prefix)
        let delta = prefix.serializedInputByteCount - (retained.prefixes.last?.inputBytes ?? 0)
        let tokens = try ContextBudgetMath.estimateTokens(serializedBytes: delta,
                                                         policy: state.configuration.policy)
        return try await evaluate(ContextBudgetEvaluationRequest(triggerPoint: .afterToolResult,
            providerResponseID: prefix.providerResponseID, measurement: .serializedIncrement(bytes: delta),
            growth: .init(toolResultTokens: tokens, projectedNextTurnTokens: tokens)),
            replacingConfiguration: nil, replacingToolResultAccounting: updated).observation.action
    }

    private func evaluate(
        _ request: ContextBudgetEvaluationRequest,
        replacingConfiguration: ContextBudgetConfiguration?,
        replacingToolResultAccounting: ManagedToolResultAccounting? = nil,
        replaceRawProviderUsage: Bool = false
    ) async throws -> ContextBudgetCommitReceipt {
        var proposed = state
        if let replacingConfiguration {
            proposed.configuration = replacingConfiguration
        }
        let configuration = try proposed.configuration.validated()
        guard !request.accountingCut.isEmpty, request.accountingCut.utf8.count <= 128 else {
            throw ContextBudgetError.invalidObservation("invalid accounting cut")
        }
        if proposed.bootstrapState == .awaitingObservation,
           request.triggerPoint != .afterBootstrap {
            throw ContextBudgetError.bootstrapObservationRequired
        }
        if request.triggerPoint == .providerOverflow {
            guard case .providerOverflow = request.measurement else {
                throw ContextBudgetError.invalidObservation(
                    "provider_overflow trigger requires an overflow measurement"
                )
            }
        }
        let responseID = try validatedResponseID(
            request.providerResponseID ?? proposed.latestObservation?.providerResponseID
        )
        let measurement = try resolveMeasurement(request.measurement, state: proposed)
        var effectiveGrowth = request.growth
        if case .serializedEstimate(let footprint) = request.measurement {
            effectiveGrowth = try mergedGrowth(
                explicit: request.growth,
                footprint: footprint,
                policy: configuration.policy
            )
        }
        if let effectiveGrowth {
            let sample = try effectiveGrowth.validated(
                maximum: ContextCapacityResolver.maximumSupportedCapacity
            )
            try proposed.ewma.apply(sample, alpha: configuration.policy.ewmaAlpha)
        }
        let projected = try proposed.ewma.projectedNextTurn(
            default: configuration.policy.initialProjectedNextTurnTokens
        )
        let thresholds = try ContextBudgetMath.thresholds(
            configuration: configuration,
            projectedNextTurn: projected
        )
        let fixed = try configuration.reserves.fixedTotal()
        let usable = configuration.capacity.capacity - fixed
        let remaining = usable - measurement.used

        if proposed.bootstrapState == .awaitingObservation {
            let maximumBootstrapUse = Int(
                floor(Double(usable) * configuration.policy.bootstrapResetUsedFraction)
            )
            guard measurement.source != .providerOverflow,
                  measurement.used <= maximumBootstrapUse else {
                throw ContextBudgetError.bootstrapResetNotSatisfied
            }
            proposed.bootstrapState = .armed
            proposed.action = .normal
            proposed.lastRequestedAction = nil
        }

        let rawAction = measurement.source == .providerOverflow
            ? ContextBudgetAction.emergency
            : Self.rawAction(remaining: remaining, thresholds: thresholds)
        let priorAction = proposed.action
        let action = Self.applyHysteresis(
            rawAction: rawAction,
            priorAction: priorAction,
            remaining: remaining,
            thresholds: thresholds
        )
        let shouldRequest = action != .normal
            && action.severity > (proposed.lastRequestedAction?.severity ?? 0)
        if shouldRequest {
            guard proposed.actionEpoch < UInt64(Int64.max) else {
                throw ContextBudgetError.arithmeticOverflow
            }
            proposed.actionEpoch += 1
            proposed.lastRequestedAction = action
        }
        proposed.action = action
        guard proposed.observationCount < UInt64(Int64.max),
              proposed.revision < UInt64(Int64.max) else {
            throw ContextBudgetError.arithmeticOverflow
        }
        proposed.observationCount += 1
        proposed.revision += 1
        proposed.updatedAt = ISO8601.string(from: clock.now())
        let observation = ContextBudgetObservation(
            observationID: request.observationID,
            identity: identity,
            providerResponseID: responseID,
            capacity: configuration.capacity.capacity,
            used: measurement.used,
            reserves: configuration.reserves,
            remaining: remaining,
            projectedNextTurn: projected,
            source: measurement.source,
            confidence: measurement.confidence,
            estimatorVersion: ContextBudgetPolicy.estimatorVersion,
            action: action,
            triggerPoint: request.triggerPoint,
            thresholds: thresholds,
            actionEpoch: proposed.actionEpoch,
            createdAt: proposed.updatedAt,
            accounting: try ContextBudgetAccounting(
                version: configuration.resolvedPolicy == nil ? "legacy_remaining_v1" : "admitted_total_v2",
                cut: request.accountingCut,
                retainedInputTokens: measurement.countKnown ? measurement.used : nil,
                futureReserveTokens: fixed,
                rawProviderUsage: replaceRawProviderUsage ? request.rawProviderUsage
                    : request.rawProviderUsage ?? proposed.latestObservation?.accounting?.rawProviderUsage,
                resolvedPolicy: configuration.resolvedPolicy,
                toolSchemaSHA256: request.toolSchemaSHA256 ?? proposed.latestObservation?.accounting?.toolSchemaSHA256,
                pendingInputID: request.triggerPoint == .afterProviderTurn ? nil
                    : request.pendingInputID ?? proposed.latestObservation?.accounting?.pendingInputID,
                toolResultAccounting: replacingToolResultAccounting
                    ?? proposed.latestObservation?.accounting?.toolResultAccounting
            )
        )
        proposed.latestObservation = observation
        _ = try proposed.validated()
        let actionRequest = shouldRequest ? try makeActionRequest(for: observation) : nil
        let receipt = try await repository.persistContextBudget(
            ContextBudgetPersistenceCommit(
                observation: observation,
                state: proposed,
                actionRequest: actionRequest
            )
        )
        state = proposed
        if let actionRequest = receipt.actionRequest {
            latestActionRequest = actionRequest
        }
        return receipt
    }

    private func resolveMeasurement(
        _ measurement: ContextBudgetMeasurement,
        state: PersistedContextBudgetState
    ) throws -> ResolvedMeasurement {
        let policy = state.configuration.policy
        switch measurement {
        case .providerExact(let usedTokens):
            return try validatedMeasurement(
                used: usedTokens,
                source: .providerExact,
                confidence: 1
            )
        case .tokenizerExact(let usedTokens):
            return try validatedMeasurement(
                used: usedTokens,
                source: .tokenizerExact,
                confidence: Self.tokenizerExactConfidence
            )
        case .serializedEstimate(let footprint):
            let bytes = try footprint.retainedBytes(maximum: policy.maximumSerializedBytes)
            return try validatedMeasurement(
                used: ContextBudgetMath.estimateTokens(serializedBytes: bytes, policy: policy),
                source: .serializedEstimate,
                confidence: Self.serializedEstimateConfidence
            )
        case .estimatedTokens(let usedTokens, let confidence):
            return try validatedMeasurement(used: usedTokens, source: .serializedEstimate,
                                            confidence: min(confidence, Self.serializedEstimateConfidence))
        case .serializedIncrement(let bytes):
            guard let latest = state.latestObservation else {
                throw ContextBudgetError.currentObservationRequired
            }
            if latest.source == .providerOverflow {
                // New local bytes do not resolve a provider overflow's unknown usage.
                return try validatedMeasurement(used: latest.used, source: .providerOverflow,
                                                confidence: 0, countKnown: false)
            }
            let delta = try ContextBudgetMath.estimateTokens(
                serializedBytes: bytes,
                policy: policy
            )
            let total = latest.used.addingReportingOverflow(delta)
            guard !total.overflow else { throw ContextBudgetError.arithmeticOverflow }
            return try validatedMeasurement(
                used: total.partialValue,
                source: .serializedEstimate,
                confidence: min(latest.confidence, Self.serializedEstimateConfidence)
            )
        case .current:
            guard let latest = state.latestObservation else {
                throw ContextBudgetError.currentObservationRequired
            }
            return try validatedMeasurement(
                used: latest.used,
                source: latest.source,
                confidence: latest.confidence,
                countKnown: latest.source != .providerOverflow
            )
        case .providerOverflow(let lastKnownUsedTokens):
            // An overflow proves admission failed, not that retained input equals
            // the configured capacity. Keep a labeled last-known compatibility
            // value and leave the normalized current count unknown.
            let used = lastKnownUsedTokens ?? state.latestObservation?.used ?? 0
            return try validatedMeasurement(
                used: used,
                source: .providerOverflow,
                confidence: 0,
                countKnown: false
            )
        }
    }

    private func validatedMeasurement(
        used: Int,
        source: ContextBudgetUsageSource,
        confidence: Double,
        countKnown: Bool = true
    ) throws -> ResolvedMeasurement {
        guard used >= 0, used <= Int(Int64.max),
              confidence.isFinite, (0...1).contains(confidence) else {
            throw ContextBudgetError.invalidObservation("usage or confidence is outside bounds")
        }
        return ResolvedMeasurement(used: used, source: source, confidence: confidence, countKnown: countKnown)
    }

    private func mergedGrowth(
        explicit: ContextBudgetGrowthSample?,
        footprint: SerializedContextFootprint,
        policy: ContextBudgetPolicy
    ) throws -> ContextBudgetGrowthSample {
        let userBytes = try checkedSum([
            footprint.systemInstructionBytes,
            footprint.handoffBytes,
            footprint.messageBytes,
        ])
        let user = try ContextBudgetMath.estimateTokens(serializedBytes: userBytes, policy: policy)
        let tools = try ContextBudgetMath.estimateTokens(
            serializedBytes: footprint.toolSchemaBytes,
            policy: policy
        )
        let results = try ContextBudgetMath.estimateTokens(
            serializedBytes: footprint.toolResultBytes,
            policy: policy
        )
        let projected = try ContextBudgetMath.estimateTokens(
            serializedBytes: try footprint.projectedBytes(maximum: policy.maximumSerializedBytes),
            policy: policy
        )
        return ContextBudgetGrowthSample(
            userInputTokens: explicit?.userInputTokens ?? user,
            assistantOutputTokens: explicit?.assistantOutputTokens,
            toolDefinitionTokens: explicit?.toolDefinitionTokens ?? tools,
            toolResultTokens: explicit?.toolResultTokens ?? results,
            projectedNextTurnTokens: explicit?.projectedNextTurnTokens ?? projected
        )
    }

    private func checkedSum(_ values: [Int]) throws -> Int {
        var total = 0
        for value in values {
            guard value >= 0 else {
                throw ContextBudgetError.invalidObservation("serialized byte count is negative")
            }
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { throw ContextBudgetError.arithmeticOverflow }
            total = result.partialValue
            guard total <= state.configuration.policy.maximumSerializedBytes else {
                throw ContextBudgetError.serializedInputTooLarge
            }
        }
        return total
    }

    private func validatedResponseID(_ responseID: String?) throws -> String? {
        guard let responseID else { return nil }
        let normalized = responseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == responseID,
              !responseID.isEmpty,
              responseID.utf8.count <= 2_048 else {
            throw ContextBudgetError.invalidObservation("provider response identifier is invalid")
        }
        return responseID
    }

    private func makeActionRequest(
        for observation: ContextBudgetObservation
    ) throws -> ContextBudgetActionRequestIntent {
        guard observation.action != .normal else {
            throw ContextBudgetError.invalidObservation(
                "normal action cannot enqueue a continuity request"
            )
        }
        let reason = "Automatic \(observation.action.rawValue) at \(observation.triggerPoint.rawValue): remaining=\(observation.remaining), projected_next_turn=\(observation.projectedNextTurn)"
        return ContextBudgetActionRequestIntent(
            requestID: stableID(domain: "context-budget-action-request-v1"),
            continuityOperationID: stableID(domain: "context-budget-operation-v1"),
            identity: identity,
            observationID: observation.observationID,
            requestedAction: observation.action,
            actionEpoch: observation.actionEpoch,
            reason: reason
        )
    }

    private static func rawAction(
        remaining: Int,
        thresholds: ContextBudgetThresholds
    ) -> ContextBudgetAction {
        if remaining <= thresholds.emergency { return .emergency }
        if remaining <= thresholds.rollover { return .rollover }
        if remaining <= thresholds.checkpoint { return .checkpoint }
        return .normal
    }

    private static func applyHysteresis(
        rawAction: ContextBudgetAction,
        priorAction: ContextBudgetAction,
        remaining: Int,
        thresholds: ContextBudgetThresholds
    ) -> ContextBudgetAction {
        guard rawAction.severity < priorAction.severity else { return rawAction }
        let releaseThreshold: Int
        switch priorAction {
        case .normal: return rawAction
        case .checkpoint: releaseThreshold = thresholds.checkpoint
        case .rollover: releaseThreshold = thresholds.rollover
        case .emergency: releaseThreshold = thresholds.emergency
        }
        let release = releaseThreshold.addingReportingOverflow(thresholds.hysteresis)
        if release.overflow { return priorAction }
        return remaining > release.partialValue ? rawAction : priorAction
    }

    private func stableID(domain: String) -> UUID {
        let digest = JSONSupport.sha256Hex(
            "\(domain):\(identity.runID.description):\(identity.projectID.description):\(identity.projectGeneration.rawValue):\(identity.sessionID)"
        )
        let uuid = "\(digest.prefix(8))-\(digest.dropFirst(8).prefix(4))-\(digest.dropFirst(12).prefix(4))-\(digest.dropFirst(16).prefix(4))-\(digest.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuid)!
    }

    private static func validatedActionRequest(
        for state: PersistedContextBudgetState,
        stored: ContextBudgetActionRequest?
    ) throws -> ContextBudgetActionRequest? {
        switch (state.lastRequestedAction, stored) {
        case (nil, nil):
            return nil
        case (let action?, let request?):
            guard request.identity == state.identity,
                  request.requestedAction == action,
                  request.actionEpoch == state.actionEpoch else {
                throw ContextBudgetError.invalidPersistedState
            }
            return try request.validated()
        case (.some, nil), (nil, .some):
            throw ContextBudgetError.invalidPersistedState
        }
    }
}

private struct ResolvedMeasurement {
    let used: Int
    let source: ContextBudgetUsageSource
    let confidence: Double
    let countKnown: Bool
}

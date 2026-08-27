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
        guard estimate.isFinite, estimate >= 0, estimate <= Double(Int.max) else {
            throw ContextBudgetError.arithmeticOverflow
        }
        return Int(estimate)
    }

    private static func fractionTokens(_ total: Int, _ fraction: Double) throws -> Int {
        let value = ceil(Double(total) * fraction)
        guard value.isFinite, value >= 0, value <= Double(Int.max) else {
            throw ContextBudgetError.arithmeticOverflow
        }
        return Int(value)
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

    private func evaluate(
        _ request: ContextBudgetEvaluationRequest,
        replacingConfiguration: ContextBudgetConfiguration?
    ) async throws -> ContextBudgetCommitReceipt {
        var proposed = state
        if let replacingConfiguration {
            proposed.configuration = replacingConfiguration
        }
        let configuration = try proposed.configuration.validated()
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
            createdAt: proposed.updatedAt
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
        case .serializedIncrement(let bytes):
            guard let latest = state.latestObservation else {
                throw ContextBudgetError.currentObservationRequired
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
                confidence: latest.confidence
            )
        case .providerOverflow(let lastKnownUsedTokens):
            let used = max(
                state.configuration.capacity.capacity,
                lastKnownUsedTokens ?? state.latestObservation?.used ?? 0
            )
            return try validatedMeasurement(
                used: used,
                source: .providerOverflow,
                confidence: 1
            )
        }
    }

    private func validatedMeasurement(
        used: Int,
        source: ContextBudgetUsageSource,
        confidence: Double
    ) throws -> ResolvedMeasurement {
        guard used >= 0, used <= Int(Int64.max),
              confidence.isFinite, (0...1).contains(confidence) else {
            throw ContextBudgetError.invalidObservation("usage or confidence is outside bounds")
        }
        return ResolvedMeasurement(used: used, source: source, confidence: confidence)
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
}

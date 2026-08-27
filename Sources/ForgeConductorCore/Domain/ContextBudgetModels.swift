// ContextBudgetModels.swift
// Defines provider-capacity, usage, reserve, estimator, and durable budget contracts.

import Foundation

extension ContextBudgetAction: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = ContextBudgetAction(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported context budget action"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var severity: Int {
        switch self {
        case .normal: 0
        case .checkpoint: 1
        case .rollover: 2
        case .emergency: 3
        }
    }
}

public enum ContextBudgetUsageSource: String, Codable, Sendable, CaseIterable {
    case providerExact = "provider_exact"
    case tokenizerExact = "tokenizer_exact"
    case serializedEstimate = "serialized_estimate"
    case providerOverflow = "provider_overflow"
}

public enum ContextBudgetTriggerPoint: String, Codable, Sendable, CaseIterable {
    case beforeProviderTurn = "before_provider_turn"
    case afterProviderTurn = "after_provider_turn"
    case afterToolResult = "after_tool_result"
    case toolSetChanged = "tool_set_changed"
    case systemInstructionsChanged = "system_instructions_changed"
    case providerConfigurationChanged = "provider_configuration_changed"
    case providerOverflow = "provider_overflow"
    case managerRecovery = "manager_recovery"
    case afterBootstrap = "after_bootstrap"
}

public struct ContextBudgetIdentity: Codable, Sendable, Equatable {
    public let runID: RunID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let sessionID: String

    public init(
        runID: RunID,
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        sessionID: String
    ) {
        self.runID = runID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.sessionID = sessionID
    }

    public func validated() throws -> ContextBudgetIdentity {
        let normalizedSession = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard projectGeneration.rawValue > 0,
              projectGeneration.rawValue <= UInt64(Int64.max),
              normalizedSession == sessionID,
              !sessionID.isEmpty,
              sessionID.utf8.count <= 1_024 else {
            throw ContextBudgetError.invalidIdentity
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case sessionID = "session_id"
    }
}

public struct ProviderLoadedContextInstance: Codable, Sendable, Equatable {
    public let instanceID: String
    public let modelKey: String
    public let contextLength: Int

    public init(instanceID: String, modelKey: String, contextLength: Int) {
        self.instanceID = instanceID
        self.modelKey = modelKey
        self.contextLength = contextLength
    }

    private enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case modelKey = "model_key"
        case contextLength = "context_length"
    }
}

public struct ContextCapacityDiscoveryInput: Codable, Sendable, Equatable {
    public let providerID: String
    public let providerVersionFingerprint: String
    public let modelKey: String
    public let selectedInstanceID: String?
    public let configuredContextLength: Int
    public let maximumContextLength: Int
    public let loadedInstances: [ProviderLoadedContextInstance]
    public let modelLoadPermitted: Bool

    public init(
        providerID: String,
        providerVersionFingerprint: String,
        modelKey: String,
        selectedInstanceID: String? = nil,
        configuredContextLength: Int,
        maximumContextLength: Int,
        loadedInstances: [ProviderLoadedContextInstance],
        modelLoadPermitted: Bool = false
    ) {
        self.providerID = providerID
        self.providerVersionFingerprint = providerVersionFingerprint
        self.modelKey = modelKey
        self.selectedInstanceID = selectedInstanceID
        self.configuredContextLength = configuredContextLength
        self.maximumContextLength = maximumContextLength
        self.loadedInstances = loadedInstances
        self.modelLoadPermitted = modelLoadPermitted
    }

    private enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case providerVersionFingerprint = "provider_version_fingerprint"
        case modelKey = "model_key"
        case selectedInstanceID = "selected_instance_id"
        case configuredContextLength = "configured_context_length"
        case maximumContextLength = "maximum_context_length"
        case loadedInstances = "loaded_instances"
        case modelLoadPermitted = "model_load_permitted"
    }
}

public struct ContextCapacityResolution: Codable, Sendable, Equatable {
    public let providerID: String
    public let providerVersionFingerprint: String
    public let modelKey: String
    public let activeInstanceID: String?
    public let capacity: Int
    public let maximumContextLength: Int
    public let requiresModelLoad: Bool

    public init(
        providerID: String,
        providerVersionFingerprint: String,
        modelKey: String,
        activeInstanceID: String?,
        capacity: Int,
        maximumContextLength: Int,
        requiresModelLoad: Bool
    ) {
        self.providerID = providerID
        self.providerVersionFingerprint = providerVersionFingerprint
        self.modelKey = modelKey
        self.activeInstanceID = activeInstanceID
        self.capacity = capacity
        self.maximumContextLength = maximumContextLength
        self.requiresModelLoad = requiresModelLoad
    }

    public func validateForExecution(
        reserves: ContextBudgetReserves,
        minimumUsableTokens: Int
    ) throws {
        let labels = [providerID, providerVersionFingerprint, modelKey]
        guard labels.allSatisfy({ value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized == value && !value.isEmpty && value.utf8.count <= 1_024
        }),
        activeInstanceID.map({ value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized == value && !value.isEmpty && value.utf8.count <= 1_024
        }) ?? requiresModelLoad,
        maximumContextLength > 0,
        maximumContextLength <= ContextCapacityResolver.maximumSupportedCapacity else {
            throw ContextBudgetError.invalidCapacity("resolved provider identity is invalid")
        }
        guard !requiresModelLoad else { throw ContextBudgetError.modelLoadRequired }
        guard capacity > 0, capacity <= maximumContextLength else {
            throw ContextBudgetError.invalidCapacity("active capacity exceeds the model maximum")
        }
        let fixed = try reserves.fixedTotal()
        guard fixed < capacity, capacity - fixed >= minimumUsableTokens else {
            throw ContextBudgetError.insufficientUsableCapacity
        }
    }

    private enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case providerVersionFingerprint = "provider_version_fingerprint"
        case modelKey = "model_key"
        case activeInstanceID = "active_instance_id"
        case capacity
        case maximumContextLength = "maximum_context_length"
        case requiresModelLoad = "requires_model_load"
    }
}

public enum ContextCapacityResolver {
    public static let maximumSupportedCapacity = 16 * 1_024 * 1_024
    public static let maximumLoadedInstances = 128

    public static func resolve(_ input: ContextCapacityDiscoveryInput) throws -> ContextCapacityResolution {
        try validateLabel(input.providerID, maximumBytes: 256, field: "provider_id")
        try validateLabel(
            input.providerVersionFingerprint,
            maximumBytes: 1_024,
            field: "provider_version_fingerprint"
        )
        try validateLabel(input.modelKey, maximumBytes: 1_024, field: "model_key")
        if let selected = input.selectedInstanceID {
            try validateLabel(selected, maximumBytes: 1_024, field: "selected_instance_id")
        }
        guard input.configuredContextLength > 0,
              input.maximumContextLength > 0,
              input.maximumContextLength <= maximumSupportedCapacity,
              input.configuredContextLength <= input.maximumContextLength,
              input.loadedInstances.count <= maximumLoadedInstances else {
            throw ContextBudgetError.invalidCapacity("configured context capacity is invalid")
        }
        var seenInstances = Set<String>()
        for instance in input.loadedInstances {
            try validateLabel(instance.instanceID, maximumBytes: 1_024, field: "instance_id")
            try validateLabel(instance.modelKey, maximumBytes: 1_024, field: "loaded model_key")
            guard seenInstances.insert(instance.instanceID).inserted,
                  instance.contextLength > 0,
                  instance.contextLength <= input.maximumContextLength else {
                throw ContextBudgetError.invalidCapacity("loaded instance capacity is invalid")
            }
        }

        let matching = input.loadedInstances.filter { $0.modelKey == input.modelKey }
        let selected: ProviderLoadedContextInstance?
        if let selectedInstanceID = input.selectedInstanceID {
            guard let exact = matching.first(where: { $0.instanceID == selectedInstanceID }) else {
                throw ContextBudgetError.selectedInstanceNotLoaded
            }
            selected = exact
        } else if matching.count == 1 {
            selected = matching[0]
        } else if matching.isEmpty {
            selected = nil
        } else {
            throw ContextBudgetError.ambiguousLoadedInstance
        }

        if let selected {
            return ContextCapacityResolution(
                providerID: input.providerID,
                providerVersionFingerprint: input.providerVersionFingerprint,
                modelKey: input.modelKey,
                activeInstanceID: selected.instanceID,
                capacity: selected.contextLength,
                maximumContextLength: input.maximumContextLength,
                requiresModelLoad: false
            )
        }
        guard input.modelLoadPermitted else { throw ContextBudgetError.modelNotLoaded }
        return ContextCapacityResolution(
            providerID: input.providerID,
            providerVersionFingerprint: input.providerVersionFingerprint,
            modelKey: input.modelKey,
            activeInstanceID: nil,
            capacity: input.configuredContextLength,
            maximumContextLength: input.maximumContextLength,
            requiresModelLoad: true
        )
    }

    private static func validateLabel(
        _ value: String,
        maximumBytes: Int,
        field: String
    ) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == value, !value.isEmpty, value.utf8.count <= maximumBytes else {
            throw ContextBudgetError.invalidCapacity("\(field) is invalid")
        }
    }
}

public struct ContextBudgetReserves: Codable, Sendable, Equatable {
    public let outputTokens: Int
    public let schemaTokens: Int
    public let handoffTokens: Int
    public let recoveryTokens: Int

    public init(
        outputTokens: Int,
        schemaTokens: Int,
        handoffTokens: Int,
        recoveryTokens: Int
    ) {
        self.outputTokens = outputTokens
        self.schemaTokens = schemaTokens
        self.handoffTokens = handoffTokens
        self.recoveryTokens = recoveryTokens
    }

    public func fixedTotal() throws -> Int {
        let values = [outputTokens, schemaTokens, handoffTokens, recoveryTokens]
        guard values.allSatisfy({ $0 >= 0 }) else {
            throw ContextBudgetError.invalidReserve
        }
        var total = 0
        for value in values {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { throw ContextBudgetError.arithmeticOverflow }
            total = result.partialValue
        }
        return total
    }

    private enum CodingKeys: String, CodingKey {
        case outputTokens = "output_tokens"
        case schemaTokens = "schema_tokens"
        case handoffTokens = "handoff_tokens"
        case recoveryTokens = "recovery_tokens"
    }
}

public struct ContextBudgetPolicy: Codable, Sendable, Equatable {
    public static let estimatorVersion = "forge-context-estimator-v1"

    public let checkpointFraction: Double
    public let rolloverFraction: Double
    public let emergencyFraction: Double
    public let hysteresisFraction: Double
    public let bootstrapResetUsedFraction: Double
    public let ewmaAlpha: Double
    public let serializedBytesPerToken: Double
    public let estimateSafetyMultiplier: Double
    public let initialProjectedNextTurnTokens: Int
    public let minimumUsableTokens: Int
    public let maximumSerializedBytes: Int

    public init(
        checkpointFraction: Double = 0.25,
        rolloverFraction: Double = 0.15,
        emergencyFraction: Double = 0.05,
        hysteresisFraction: Double = 0.02,
        bootstrapResetUsedFraction: Double = 0.50,
        ewmaAlpha: Double = 0.25,
        serializedBytesPerToken: Double = 3.0,
        estimateSafetyMultiplier: Double = 1.25,
        initialProjectedNextTurnTokens: Int = 1_024,
        minimumUsableTokens: Int = 1_024,
        maximumSerializedBytes: Int = 64 * 1_024 * 1_024
    ) {
        self.checkpointFraction = checkpointFraction
        self.rolloverFraction = rolloverFraction
        self.emergencyFraction = emergencyFraction
        self.hysteresisFraction = hysteresisFraction
        self.bootstrapResetUsedFraction = bootstrapResetUsedFraction
        self.ewmaAlpha = ewmaAlpha
        self.serializedBytesPerToken = serializedBytesPerToken
        self.estimateSafetyMultiplier = estimateSafetyMultiplier
        self.initialProjectedNextTurnTokens = initialProjectedNextTurnTokens
        self.minimumUsableTokens = minimumUsableTokens
        self.maximumSerializedBytes = maximumSerializedBytes
    }

    public func validated() throws -> ContextBudgetPolicy {
        let finite = [
            checkpointFraction, rolloverFraction, emergencyFraction,
            hysteresisFraction, bootstrapResetUsedFraction, ewmaAlpha,
            serializedBytesPerToken, estimateSafetyMultiplier,
        ].allSatisfy(\.isFinite)
        guard finite,
              checkpointFraction > rolloverFraction,
              rolloverFraction > emergencyFraction,
              emergencyFraction > 0,
              checkpointFraction < 1,
              hysteresisFraction >= 0, hysteresisFraction <= 0.25,
              bootstrapResetUsedFraction > 0, bootstrapResetUsedFraction < 1,
              ewmaAlpha > 0, ewmaAlpha <= 1,
              serializedBytesPerToken >= 1, serializedBytesPerToken <= 16,
              estimateSafetyMultiplier >= 1, estimateSafetyMultiplier <= 4,
              initialProjectedNextTurnTokens >= 0,
              minimumUsableTokens > 0,
              maximumSerializedBytes > 0,
              maximumSerializedBytes <= 512 * 1_024 * 1_024 else {
            throw ContextBudgetError.invalidPolicy
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case checkpointFraction = "checkpoint_fraction"
        case rolloverFraction = "rollover_fraction"
        case emergencyFraction = "emergency_fraction"
        case hysteresisFraction = "hysteresis_fraction"
        case bootstrapResetUsedFraction = "bootstrap_reset_used_fraction"
        case ewmaAlpha = "ewma_alpha"
        case serializedBytesPerToken = "serialized_bytes_per_token"
        case estimateSafetyMultiplier = "estimate_safety_multiplier"
        case initialProjectedNextTurnTokens = "initial_projected_next_turn_tokens"
        case minimumUsableTokens = "minimum_usable_tokens"
        case maximumSerializedBytes = "maximum_serialized_bytes"
    }
}

public struct ContextBudgetConfiguration: Codable, Sendable, Equatable {
    public let capacity: ContextCapacityResolution
    public let reserves: ContextBudgetReserves
    public let policy: ContextBudgetPolicy
    public let requiresBootstrapReset: Bool

    public init(
        capacity: ContextCapacityResolution,
        reserves: ContextBudgetReserves,
        policy: ContextBudgetPolicy = .init(),
        requiresBootstrapReset: Bool = false
    ) {
        self.capacity = capacity
        self.reserves = reserves
        self.policy = policy
        self.requiresBootstrapReset = requiresBootstrapReset
    }

    public func validated() throws -> ContextBudgetConfiguration {
        let validPolicy = try policy.validated()
        try capacity.validateForExecution(
            reserves: reserves,
            minimumUsableTokens: validPolicy.minimumUsableTokens
        )
        return self
    }

    public var usableCapacity: Int {
        let fixed = (try? reserves.fixedTotal()) ?? capacity.capacity
        return max(0, capacity.capacity - fixed)
    }

    private enum CodingKeys: String, CodingKey {
        case capacity, reserves, policy
        case requiresBootstrapReset = "requires_bootstrap_reset"
    }
}

public struct SerializedContextFootprint: Codable, Sendable, Equatable {
    public let systemInstructionBytes: Int
    public let handoffBytes: Int
    public let messageBytes: Int
    public let toolSchemaBytes: Int
    public let toolResultBytes: Int
    public let projectedNextTurnBytes: Int

    public init(
        systemInstructionBytes: Int = 0,
        handoffBytes: Int = 0,
        messageBytes: Int = 0,
        toolSchemaBytes: Int = 0,
        toolResultBytes: Int = 0,
        projectedNextTurnBytes: Int = 0
    ) {
        self.systemInstructionBytes = systemInstructionBytes
        self.handoffBytes = handoffBytes
        self.messageBytes = messageBytes
        self.toolSchemaBytes = toolSchemaBytes
        self.toolResultBytes = toolResultBytes
        self.projectedNextTurnBytes = projectedNextTurnBytes
    }

    public func retainedBytes(maximum: Int) throws -> Int {
        try checkedTotal(
            [systemInstructionBytes, handoffBytes, messageBytes, toolSchemaBytes, toolResultBytes],
            maximum: maximum
        )
    }

    public func projectedBytes(maximum: Int) throws -> Int {
        guard projectedNextTurnBytes >= 0, projectedNextTurnBytes <= maximum else {
            throw ContextBudgetError.serializedInputTooLarge
        }
        return projectedNextTurnBytes
    }

    private func checkedTotal(_ values: [Int], maximum: Int) throws -> Int {
        guard values.allSatisfy({ $0 >= 0 }) else {
            throw ContextBudgetError.invalidObservation("serialized byte count is negative")
        }
        var total = 0
        for value in values {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { throw ContextBudgetError.arithmeticOverflow }
            total = result.partialValue
            guard total <= maximum else { throw ContextBudgetError.serializedInputTooLarge }
        }
        return total
    }

    private enum CodingKeys: String, CodingKey {
        case systemInstructionBytes = "system_instruction_bytes"
        case handoffBytes = "handoff_bytes"
        case messageBytes = "message_bytes"
        case toolSchemaBytes = "tool_schema_bytes"
        case toolResultBytes = "tool_result_bytes"
        case projectedNextTurnBytes = "projected_next_turn_bytes"
    }
}

public struct ContextBudgetGrowthSample: Codable, Sendable, Equatable {
    public let userInputTokens: Int?
    public let assistantOutputTokens: Int?
    public let toolDefinitionTokens: Int?
    public let toolResultTokens: Int?
    public let projectedNextTurnTokens: Int?

    public init(
        userInputTokens: Int? = nil,
        assistantOutputTokens: Int? = nil,
        toolDefinitionTokens: Int? = nil,
        toolResultTokens: Int? = nil,
        projectedNextTurnTokens: Int? = nil
    ) {
        self.userInputTokens = userInputTokens
        self.assistantOutputTokens = assistantOutputTokens
        self.toolDefinitionTokens = toolDefinitionTokens
        self.toolResultTokens = toolResultTokens
        self.projectedNextTurnTokens = projectedNextTurnTokens
    }

    public func validated(maximum: Int) throws -> ContextBudgetGrowthSample {
        let values = [
            userInputTokens, assistantOutputTokens, toolDefinitionTokens,
            toolResultTokens, projectedNextTurnTokens,
        ].compactMap { $0 }
        guard values.allSatisfy({ $0 >= 0 && $0 <= maximum }) else {
            throw ContextBudgetError.invalidObservation("growth sample is outside bounds")
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case userInputTokens = "user_input_tokens"
        case assistantOutputTokens = "assistant_output_tokens"
        case toolDefinitionTokens = "tool_definition_tokens"
        case toolResultTokens = "tool_result_tokens"
        case projectedNextTurnTokens = "projected_next_turn_tokens"
    }
}

public enum ContextBudgetMeasurement: Sendable, Equatable {
    case providerExact(usedTokens: Int)
    case tokenizerExact(usedTokens: Int)
    case serializedEstimate(SerializedContextFootprint)
    case serializedIncrement(bytes: Int)
    case current
    case providerOverflow(lastKnownUsedTokens: Int?)
}

public struct ContextBudgetUsageCandidates: Sendable, Equatable {
    public let providerExactUsedTokens: Int?
    public let tokenizerExactUsedTokens: Int?
    public let serializedFootprint: SerializedContextFootprint?
    public let providerOverflow: Bool
    public let lastKnownUsedTokens: Int?

    public init(
        providerExactUsedTokens: Int? = nil,
        tokenizerExactUsedTokens: Int? = nil,
        serializedFootprint: SerializedContextFootprint? = nil,
        providerOverflow: Bool = false,
        lastKnownUsedTokens: Int? = nil
    ) {
        self.providerExactUsedTokens = providerExactUsedTokens
        self.tokenizerExactUsedTokens = tokenizerExactUsedTokens
        self.serializedFootprint = serializedFootprint
        self.providerOverflow = providerOverflow
        self.lastKnownUsedTokens = lastKnownUsedTokens
    }

    public func strongestMeasurement() throws -> ContextBudgetMeasurement {
        if providerOverflow {
            return .providerOverflow(lastKnownUsedTokens: lastKnownUsedTokens)
        }
        if let providerExactUsedTokens {
            return .providerExact(usedTokens: providerExactUsedTokens)
        }
        if let tokenizerExactUsedTokens {
            return .tokenizerExact(usedTokens: tokenizerExactUsedTokens)
        }
        if let serializedFootprint { return .serializedEstimate(serializedFootprint) }
        throw ContextBudgetError.invalidObservation("no usage evidence is available")
    }
}

public struct ContextBudgetEvaluationRequest: Sendable, Equatable {
    public let observationID: UUID
    public let triggerPoint: ContextBudgetTriggerPoint
    public let providerResponseID: String?
    public let measurement: ContextBudgetMeasurement
    public let growth: ContextBudgetGrowthSample?

    public init(
        observationID: UUID = UUID(),
        triggerPoint: ContextBudgetTriggerPoint,
        providerResponseID: String? = nil,
        measurement: ContextBudgetMeasurement,
        growth: ContextBudgetGrowthSample? = nil
    ) {
        self.observationID = observationID
        self.triggerPoint = triggerPoint
        self.providerResponseID = providerResponseID
        self.measurement = measurement
        self.growth = growth
    }

    public static func selectingStrongest(
        observationID: UUID = UUID(),
        triggerPoint: ContextBudgetTriggerPoint,
        providerResponseID: String? = nil,
        candidates: ContextBudgetUsageCandidates,
        growth: ContextBudgetGrowthSample? = nil
    ) throws -> ContextBudgetEvaluationRequest {
        ContextBudgetEvaluationRequest(
            observationID: observationID,
            triggerPoint: triggerPoint,
            providerResponseID: providerResponseID,
            measurement: try candidates.strongestMeasurement(),
            growth: growth
        )
    }
}

public struct ContextBudgetEWMAState: Codable, Sendable, Equatable {
    public var userInputTokens: Double?
    public var assistantOutputTokens: Double?
    public var toolDefinitionTokens: Double?
    public var toolResultTokens: Double?
    public var projectedNextTurnTokens: Double?
    public var sampleCount: UInt64

    public init(
        userInputTokens: Double? = nil,
        assistantOutputTokens: Double? = nil,
        toolDefinitionTokens: Double? = nil,
        toolResultTokens: Double? = nil,
        projectedNextTurnTokens: Double? = nil,
        sampleCount: UInt64 = 0
    ) {
        self.userInputTokens = userInputTokens
        self.assistantOutputTokens = assistantOutputTokens
        self.toolDefinitionTokens = toolDefinitionTokens
        self.toolResultTokens = toolResultTokens
        self.projectedNextTurnTokens = projectedNextTurnTokens
        self.sampleCount = sampleCount
    }

    public mutating func apply(_ sample: ContextBudgetGrowthSample, alpha: Double) throws {
        userInputTokens = update(userInputTokens, sample.userInputTokens, alpha: alpha)
        assistantOutputTokens = update(assistantOutputTokens, sample.assistantOutputTokens, alpha: alpha)
        toolDefinitionTokens = update(toolDefinitionTokens, sample.toolDefinitionTokens, alpha: alpha)
        toolResultTokens = update(toolResultTokens, sample.toolResultTokens, alpha: alpha)
        projectedNextTurnTokens = update(
            projectedNextTurnTokens,
            sample.projectedNextTurnTokens,
            alpha: alpha
        )
        guard sampleCount < UInt64.max else { throw ContextBudgetError.arithmeticOverflow }
        sampleCount += 1
    }

    public func validated() throws -> ContextBudgetEWMAState {
        let values = [
            userInputTokens, assistantOutputTokens, toolDefinitionTokens,
            toolResultTokens, projectedNextTurnTokens,
        ].compactMap { $0 }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              sampleCount <= UInt64(Int64.max) else {
            throw ContextBudgetError.invalidPersistedState
        }
        return self
    }

    public func projectedNextTurn(default defaultValue: Int) throws -> Int {
        let componentProjection = [
            userInputTokens, assistantOutputTokens, toolDefinitionTokens, toolResultTokens,
        ].compactMap { $0 }.reduce(0, +)
        let selected = max(
            Double(defaultValue),
            max(projectedNextTurnTokens ?? 0, componentProjection)
        )
        guard selected.isFinite, selected >= 0, selected <= Double(Int.max) else {
            throw ContextBudgetError.arithmeticOverflow
        }
        return Int(ceil(selected))
    }

    private func update(_ current: Double?, _ sample: Int?, alpha: Double) -> Double? {
        guard let sample else { return current }
        guard let current else { return Double(sample) }
        return (alpha * Double(sample)) + ((1 - alpha) * current)
    }

    private enum CodingKeys: String, CodingKey {
        case userInputTokens = "user_input_tokens"
        case assistantOutputTokens = "assistant_output_tokens"
        case toolDefinitionTokens = "tool_definition_tokens"
        case toolResultTokens = "tool_result_tokens"
        case projectedNextTurnTokens = "projected_next_turn_tokens"
        case sampleCount = "sample_count"
    }
}

public struct ContextBudgetThresholds: Codable, Sendable, Equatable {
    public let checkpoint: Int
    public let rollover: Int
    public let emergency: Int
    public let hysteresis: Int

    public init(checkpoint: Int, rollover: Int, emergency: Int, hysteresis: Int) {
        self.checkpoint = checkpoint
        self.rollover = rollover
        self.emergency = emergency
        self.hysteresis = hysteresis
    }
}

public enum ContextBudgetBootstrapState: String, Codable, Sendable {
    case notRequired = "not_required"
    case awaitingObservation = "awaiting_observation"
    case armed
}

public struct ContextBudgetObservation: Codable, Sendable, Equatable {
    public let observationID: UUID
    public let identity: ContextBudgetIdentity
    public let providerResponseID: String?
    public let capacity: Int
    public let used: Int
    public let reserves: ContextBudgetReserves
    public let remaining: Int
    public let projectedNextTurn: Int
    public let source: ContextBudgetUsageSource
    public let confidence: Double
    public let estimatorVersion: String
    public let action: ContextBudgetAction
    public let triggerPoint: ContextBudgetTriggerPoint
    public let thresholds: ContextBudgetThresholds
    public let actionEpoch: UInt64
    public let createdAt: String

    public var fixedReserve: Int { (try? reserves.fixedTotal()) ?? 0 }

    private enum CodingKeys: String, CodingKey {
        case observationID = "observation_id"
        case identity
        case providerResponseID = "provider_response_id"
        case capacity, used, reserves, remaining
        case projectedNextTurn = "projected_next_turn"
        case source, confidence
        case estimatorVersion = "estimator_version"
        case action
        case triggerPoint = "trigger_point"
        case thresholds
        case actionEpoch = "action_epoch"
        case createdAt = "created_at"
    }
}

public struct PersistedContextBudgetState: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let identity: ContextBudgetIdentity
    public var configuration: ContextBudgetConfiguration
    public var ewma: ContextBudgetEWMAState
    public var latestObservation: ContextBudgetObservation?
    public var action: ContextBudgetAction
    public var lastRequestedAction: ContextBudgetAction?
    public var actionEpoch: UInt64
    public var bootstrapState: ContextBudgetBootstrapState
    public var observationCount: UInt64
    public var revision: UInt64
    public var updatedAt: String

    public init(
        identity: ContextBudgetIdentity,
        configuration: ContextBudgetConfiguration,
        ewma: ContextBudgetEWMAState = .init(),
        latestObservation: ContextBudgetObservation? = nil,
        action: ContextBudgetAction = .normal,
        lastRequestedAction: ContextBudgetAction? = nil,
        actionEpoch: UInt64 = 0,
        bootstrapState: ContextBudgetBootstrapState? = nil,
        observationCount: UInt64 = 0,
        revision: UInt64 = 0,
        updatedAt: String
    ) {
        self.schemaVersion = Self.schemaVersion
        self.identity = identity
        self.configuration = configuration
        self.ewma = ewma
        self.latestObservation = latestObservation
        self.action = action
        self.lastRequestedAction = lastRequestedAction
        self.actionEpoch = actionEpoch
        self.bootstrapState = bootstrapState
            ?? (configuration.requiresBootstrapReset ? .awaitingObservation : .notRequired)
        self.observationCount = observationCount
        self.revision = revision
        self.updatedAt = updatedAt
    }

    public func validated() throws -> PersistedContextBudgetState {
        guard schemaVersion == Self.schemaVersion else {
            throw ContextBudgetError.unsupportedStateVersion(schemaVersion)
        }
        _ = try identity.validated()
        _ = try configuration.validated()
        _ = try ewma.validated()
        guard revision <= UInt64(Int64.max),
              observationCount <= UInt64(Int64.max),
              actionEpoch <= UInt64(Int64.max),
              ewma.sampleCount <= UInt64(Int64.max),
              observationCount == revision,
              actionEpoch <= observationCount,
              (lastRequestedAction == nil) == (actionEpoch == 0),
              lastRequestedAction.map({ $0 != .normal }) ?? true,
              ISO8601.date(from: updatedAt) != nil,
              !(configuration.requiresBootstrapReset && bootstrapState == .notRequired),
              !(!configuration.requiresBootstrapReset && bootstrapState == .awaitingObservation) else {
            throw ContextBudgetError.invalidPersistedState
        }
        if let latestObservation {
            guard latestObservation.identity == identity,
                  latestObservation.action == action,
                  latestObservation.actionEpoch == actionEpoch,
                  latestObservation.capacity == configuration.capacity.capacity,
                  ISO8601.date(from: latestObservation.createdAt) != nil else {
                throw ContextBudgetError.invalidPersistedState
            }
        } else if observationCount != 0 || revision != 0 {
            throw ContextBudgetError.invalidPersistedState
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case identity, configuration, ewma
        case latestObservation = "latest_observation"
        case action
        case lastRequestedAction = "last_requested_action"
        case actionEpoch = "action_epoch"
        case bootstrapState = "bootstrap_state"
        case observationCount = "observation_count"
        case revision
        case updatedAt = "updated_at"
    }
}

public struct ContextBudgetPersistenceCommit: Sendable, Equatable {
    public let observation: ContextBudgetObservation
    public let state: PersistedContextBudgetState
    public let actionRequest: ContextBudgetActionRequestIntent?

    public init(
        observation: ContextBudgetObservation,
        state: PersistedContextBudgetState,
        actionRequest: ContextBudgetActionRequestIntent?
    ) {
        self.observation = observation
        self.state = state
        self.actionRequest = actionRequest
    }
}

public struct ContextBudgetCommitReceipt: Sendable, Equatable {
    public let observation: ContextBudgetObservation
    public let actionRequest: ContextBudgetActionRequest?

    public init(
        observation: ContextBudgetObservation,
        actionRequest: ContextBudgetActionRequest?
    ) {
        self.observation = observation
        self.actionRequest = actionRequest
    }
}

public struct ContextBudgetSupervisorSnapshot: Sendable, Equatable {
    public let state: PersistedContextBudgetState
    public let latestActionRequest: ContextBudgetActionRequest?

    public init(
        state: PersistedContextBudgetState,
        latestActionRequest: ContextBudgetActionRequest?
    ) {
        self.state = state
        self.latestActionRequest = latestActionRequest
    }
}

/// A manager-owned continuity request emitted by the budget supervisor. This is
/// intentionally distinct from `ContinuityCommand`: the latter may be queued only
/// after a project-local Handoff V2 is durable and must carry that handoff's digest.
public struct ContextBudgetActionRequestIntent: Sendable, Equatable {
    public let requestID: UUID
    public let continuityOperationID: UUID
    public let identity: ContextBudgetIdentity
    public let observationID: UUID
    public let requestedAction: ContextBudgetAction
    public let actionEpoch: UInt64
    public let reason: String

    public init(
        requestID: UUID,
        continuityOperationID: UUID,
        identity: ContextBudgetIdentity,
        observationID: UUID,
        requestedAction: ContextBudgetAction,
        actionEpoch: UInt64,
        reason: String
    ) {
        self.requestID = requestID
        self.continuityOperationID = continuityOperationID
        self.identity = identity
        self.observationID = observationID
        self.requestedAction = requestedAction
        self.actionEpoch = actionEpoch
        self.reason = reason
    }
}

public struct ContextBudgetActionRequest: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let continuityOperationID: UUID
    public let identity: ContextBudgetIdentity
    public let observationID: UUID
    public let requestedAction: ContextBudgetAction
    public let fulfilledAction: ContextBudgetAction?
    public let actionEpoch: UInt64
    public let reason: String
    public let revision: UInt64
    public let createdAt: String
    public let updatedAt: String

    public init(
        requestID: UUID,
        continuityOperationID: UUID,
        identity: ContextBudgetIdentity,
        observationID: UUID,
        requestedAction: ContextBudgetAction,
        fulfilledAction: ContextBudgetAction?,
        actionEpoch: UInt64,
        reason: String,
        revision: UInt64,
        createdAt: String,
        updatedAt: String
    ) {
        self.requestID = requestID
        self.continuityOperationID = continuityOperationID
        self.identity = identity
        self.observationID = observationID
        self.requestedAction = requestedAction
        self.fulfilledAction = fulfilledAction
        self.actionEpoch = actionEpoch
        self.reason = reason
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isPending: Bool {
        requestedAction.severity > (fulfilledAction?.severity ?? 0)
    }

    public func validated() throws -> ContextBudgetActionRequest {
        _ = try identity.validated()
        guard requestedAction != .normal,
              fulfilledAction.map({ $0 != .normal }) ?? true,
              (fulfilledAction?.severity ?? 0) <= requestedAction.severity,
              actionEpoch > 0,
              actionEpoch <= UInt64(Int64.max),
              revision > 0,
              revision <= UInt64(Int64.max),
              !reason.isEmpty,
              reason.utf8.count <= 2_048,
              ISO8601.date(from: createdAt) != nil,
              ISO8601.date(from: updatedAt) != nil else {
            throw ContextBudgetError.invalidActionRequest
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case continuityOperationID = "continuity_operation_id"
        case identity
        case observationID = "observation_id"
        case requestedAction = "requested_action"
        case fulfilledAction = "fulfilled_action"
        case actionEpoch = "action_epoch"
        case reason, revision
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public enum ContextBudgetError: Error, LocalizedError, Equatable, Sendable {
    case invalidIdentity
    case invalidCapacity(String)
    case selectedInstanceNotLoaded
    case ambiguousLoadedInstance
    case modelNotLoaded
    case modelLoadRequired
    case insufficientUsableCapacity
    case invalidReserve
    case invalidPolicy
    case invalidObservation(String)
    case serializedInputTooLarge
    case currentObservationRequired
    case bootstrapObservationRequired
    case bootstrapResetNotSatisfied
    case configurationMismatch
    case invalidPersistedState
    case invalidActionRequest
    case actionRequestNotFound(UUID)
    case unsupportedStateVersion(Int)
    case persistenceConflict
    case arithmeticOverflow

    public var code: String {
        switch self {
        case .invalidIdentity: "context_budget_invalid_identity"
        case .invalidCapacity: "context_capacity_invalid"
        case .selectedInstanceNotLoaded: "context_instance_not_loaded"
        case .ambiguousLoadedInstance: "context_instance_ambiguous"
        case .modelNotLoaded: "context_model_not_loaded"
        case .modelLoadRequired: "context_model_load_required"
        case .insufficientUsableCapacity: "context_capacity_insufficient"
        case .invalidReserve: "context_reserve_invalid"
        case .invalidPolicy: "context_policy_invalid"
        case .invalidObservation: "context_observation_invalid"
        case .serializedInputTooLarge: "context_serialized_input_too_large"
        case .currentObservationRequired: "context_observation_required"
        case .bootstrapObservationRequired: "context_bootstrap_observation_required"
        case .bootstrapResetNotSatisfied: "context_bootstrap_reset_not_satisfied"
        case .configurationMismatch: "context_configuration_mismatch"
        case .invalidPersistedState: "context_state_invalid"
        case .invalidActionRequest: "context_action_request_invalid"
        case .actionRequestNotFound: "context_action_request_not_found"
        case .unsupportedStateVersion: "context_state_version_unsupported"
        case .persistenceConflict: "context_state_conflict"
        case .arithmeticOverflow: "context_budget_arithmetic_overflow"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: "Context budget identity is invalid"
        case .invalidCapacity(let reason): "Context capacity is invalid: \(reason)"
        case .selectedInstanceNotLoaded: "The selected loaded model instance is unavailable"
        case .ambiguousLoadedInstance: "More than one loaded instance matches the model"
        case .modelNotLoaded: "The configured model has no loaded instance"
        case .modelLoadRequired: "The model must be loaded before budget supervision starts"
        case .insufficientUsableCapacity: "Fixed reserves leave insufficient usable context"
        case .invalidReserve: "Context reserves must be nonnegative and bounded"
        case .invalidPolicy: "Context budget policy is invalid"
        case .invalidObservation(let reason): "Context observation is invalid: \(reason)"
        case .serializedInputTooLarge: "Serialized context exceeds its bounded estimator input"
        case .currentObservationRequired: "A current usage observation is required"
        case .bootstrapObservationRequired: "A bootstrap usage observation is required first"
        case .bootstrapResetNotSatisfied: "Bootstrap usage exceeds the reset fraction"
        case .configurationMismatch: "Persisted and requested budget configuration differ"
        case .invalidPersistedState: "Persisted context budget state is invalid"
        case .invalidActionRequest: "Context budget action request is invalid"
        case .actionRequestNotFound(let requestID):
            "Context budget action request was not found: \(requestID.uuidString.lowercased())"
        case .unsupportedStateVersion(let version): "Unsupported context budget state version: \(version)"
        case .persistenceConflict: "Context budget state changed before commit"
        case .arithmeticOverflow: "Context budget arithmetic overflowed"
        }
    }
}

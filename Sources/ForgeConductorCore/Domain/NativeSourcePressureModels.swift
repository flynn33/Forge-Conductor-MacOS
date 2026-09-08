import Foundation

// Compact numerical evidence for native source admission and pressure decisions.
// These internal values validate measurements; they never grant execution authority.
// CP owns the opaque NativeSourcePressureClaim, snapshot issuance, leases, and
// the once-issued storage deadline. No model may extend sourceInferenceDeadline.

enum NativeSourceBudgetDecision<Admission: Sendable>: Sendable {
    case admitted(Admission)
    case pressure(NativeSourcePressureDecision)
    case blocked(NativeSourceBudgetFailure)
}

enum NativeSourceBudgetBoundary: String, Codable, Sendable {
    case beforeProviderPost, acceptedProviderResponse, beforeToolOutput
}

enum NativeSourcePressureReason: String, Codable, Sendable {
    case rolloverThreshold, emergencyThreshold, observedContextOverflow
    case projectedInputContext, projectedToolResultContext, accumulatedOutputEnvelope
}

enum NativeSourceBudgetFailureCode: String, Codable, Sendable {
    case invalidMeasurement, arithmeticOverflow, invalidPolicy, invalidPreflight
    case requestIdentityMismatch, providerIdentityMismatch, unsupportedProvider
    case configurationChanged, originalOutputLimitExceeded, reserveFloorsCannotFit
    case intrinsicRequestTooLarge, fullResultCannotFit, resultPolicyExceeded
    case toolQuotaExceeded, exchangeRoundLimit, invalidOutputPrefix, stageNotEvaluable
    case evaluationFailed
}

enum NativeSourcePressureModelError: Error { case invalidMetadata, metadataTooLarge }

private enum NativeSourcePressureValidation {
    static func require(_ condition: Bool) throws {
        guard condition else { throw NativeSourcePressureModelError.invalidMetadata }
    }
    static func hash(_ value: String) throws {
        try require(value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        })
    }
    static func identifier(_ value: String, maximumBytes: Int = 512) throws {
        try require(!value.isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    }
    static func sum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let value = lhs.addingReportingOverflow(rhs)
        try require(lhs >= 0 && rhs >= 0 && !value.overflow)
        return value.partialValue
    }
    static func canonical<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(value)
        guard encoded.count <= 32_768 else { throw NativeSourcePressureModelError.metadataTooLarge }
        let canonical = try ForgeJSONCanonicalizationV1.data(from: JSONSerialization.jsonObject(with: encoded))
        guard canonical.count <= 32_768 else { throw NativeSourcePressureModelError.metadataTooLarge }
        return canonical
    }
    static var emptyPrefixSHA256: String { JSONSupport.sha256Hex(Data("[]".utf8)) }
}

struct NativeSourceAcceptedResultIdentity: Codable, Sendable, Equatable {
    let stageID: UUID
    let providerRequestID: String
    let providerResponseID: String
    let resultSHA256: String
    func validated() throws -> Self {
        try NativeSourcePressureValidation.require(providerRequestID == stageID.uuidString.lowercased())
        try NativeSourcePressureValidation.identifier(providerResponseID, maximumBytes: 1_024)
        try NativeSourcePressureValidation.hash(resultSHA256)
        return self
    }
}

struct NativeSourcePendingCallIdentity: Codable, Sendable, Equatable {
    let ordinal: Int
    let providerCallID: String
    let toolName: String
    let callSHA256: String
    let argumentsSHA256: String
    func validated() throws -> Self {
        try NativeSourcePressureValidation.require((0..<16).contains(ordinal)
            && ["fs_read", "session_checkpoint", "session_handoff"].contains(toolName))
        try NativeSourcePressureValidation.identifier(providerCallID)
        try NativeSourcePressureValidation.hash(callSHA256)
        try NativeSourcePressureValidation.hash(argumentsSHA256)
        return self
    }
}

struct NativeSourceBudgetBinding: Codable, Sendable, Equatable {
    let projectID: ProjectID
    let projectGeneration: ProjectGeneration
    let taskID: UUID
    let capabilityID: UUID
    let capabilityEpoch: Int64
    let conversationID: UUID
    let conversationRevision: Int64
    let stageID: UUID
    let stageOrdinal: Int
    let logicalRequestID: UUID
    let assignmentSHA256: String
    let logicalInputSHA256: String
    let intentSHA256: String
    let sourceInferenceDeadline: String
    let stageState: NativeSourceProviderStageState
    let boundary: NativeSourceBudgetBoundary
    // For prepared continuation this identifies its actual prior response;
    // for accepted/output boundaries it identifies this stage's actual result.
    let observedResult: NativeSourceAcceptedResultIdentity?
    let completedOutputCount: Int
    let completedOutputsSHA256: String
    let pendingCall: NativeSourcePendingCallIdentity?
    let sourceReadCallsBeforeEnrollment: Int
    let admittedProviderCallsBeforeStage: Int
    let admittedCallsInStage: Int
    let sourceMaximumCalls: Int

    func validated() throws -> Self {
        try NativeSourcePressureValidation.require(projectGeneration.rawValue > 0
            && Int(exactly: projectGeneration.rawValue) != nil && capabilityEpoch > 0
            && conversationRevision > 0 && (1...8).contains(stageOrdinal)
            && (0...16).contains(completedOutputCount)
            && (0...64).contains(sourceReadCallsBeforeEnrollment)
            && (0...1_024).contains(admittedProviderCallsBeforeStage)
            && (0...16).contains(admittedCallsInStage)
            && completedOutputCount <= admittedCallsInStage
            && (1...64).contains(sourceMaximumCalls)
            && sourceInferenceDeadline.utf8.count <= 64
            && ISO8601.date(from: sourceInferenceDeadline) != nil)
        for sha in [assignmentSHA256, logicalInputSHA256, intentSHA256, completedOutputsSHA256] {
            try NativeSourcePressureValidation.hash(sha)
        }
        _ = try observedResult?.validated(); _ = try pendingCall?.validated()
        if completedOutputCount == 0 {
            try NativeSourcePressureValidation.require(completedOutputsSHA256 == NativeSourcePressureValidation.emptyPrefixSHA256)
        }
        switch boundary {
        case .beforeProviderPost:
            try NativeSourcePressureValidation.require(stageState == .prepared && pendingCall == nil
                && completedOutputCount == 0 && admittedCallsInStage == 0 && observedResult?.stageID != stageID)
        case .acceptedProviderResponse:
            try NativeSourcePressureValidation.require(stageState == .accepted && pendingCall == nil
                && observedResult?.stageID == stageID)
        case .beforeToolOutput:
            try NativeSourcePressureValidation.require(stageState == .accepted && observedResult?.stageID == stageID
                && pendingCall?.ordinal == completedOutputCount && completedOutputCount < admittedCallsInStage)
        }
        // submitted/outcomeUnknown can never become an evaluable pressure binding.
        return self
    }
}

struct NativeSourceObservedContext: Codable, Sendable, Equatable {
    let retainedInputTokens: Int?
    let retainedSerializedBytes: Int
    let rawProviderUsage: ProviderUsage?
    let source: ContextBudgetUsageSource
    let confidence: Double
    func validated(binding: NativeSourceBudgetBinding, policy: ContextBudgetPolicy) throws -> Self {
        try NativeSourcePressureValidation.require((0...(512 * 1_024 * 1_024)).contains(retainedSerializedBytes)
            && (retainedInputTokens.map { $0 >= 0 } ?? true))
        try NativeSourcePressureValidation.require(confidence.isFinite && (0...1).contains(confidence))
        if let usage = rawProviderUsage {
            _ = try ProviderUsage(capacity: usage.capacity, inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens, totalTokens: usage.totalTokens,
                source: usage.source, confidence: usage.confidence)
            try NativeSourcePressureValidation.require(binding.observedResult != nil)
        }
        switch source {
        case .providerExact, .tokenizerExact:
            guard let usage = rawProviderUsage else { throw NativeSourcePressureModelError.invalidMetadata }
            try NativeSourcePressureValidation.require(source.rawValue == usage.source.rawValue
                && confidence == usage.confidence
                && retainedInputTokens == NativeSourcePressureValidation.sum(usage.inputTokens, usage.outputTokens))
        case .serializedEstimate:
            try NativeSourcePressureValidation.require(rawProviderUsage?.source != .providerExact
                && rawProviderUsage?.source != .tokenizerExact && rawProviderUsage?.source != .providerOverflow)
            let estimate = try ContextBudgetMath.estimateTokens(serializedBytes: retainedSerializedBytes, policy: policy)
            let lower = try rawProviderUsage.map { try NativeSourcePressureValidation.sum($0.inputTokens, $0.outputTokens) } ?? 0
            try NativeSourcePressureValidation.require(retainedInputTokens == max(estimate, lower))
            // The evaluator supplies its actual estimator confidence; CP compares
            // the retained estimator/configuration facts. Domain validation only
            // enforces a finite bounded confidence, not a fabricated provider value.
        case .providerOverflow:
            try NativeSourcePressureValidation.require(rawProviderUsage?.source == .providerOverflow
                && retainedInputTokens == nil && confidence == rawProviderUsage?.confidence)
        }
        return self
    }
}

struct NativeSourceToolOutputRequirement: Codable, Sendable, Equatable {
    // Representation rule is explicit and can only change with serializer evidence.
    static let readExpansionFactor = CanonicalToolResultOutputBounds.maximumStringExpansion
    static let currentReadEncoding = Encoding.canonicalJSONTwofoldV1
    enum Kind: String, Codable, Sendable { case readCeiling, preparedCheckpoint, readyHandoff }
    enum Encoding: String, Codable, Sendable {
        case canonicalJSONTwofoldV1, exactPreparedPayloadV1, noContinuationV1
    }
    let kind: Kind
    let encoding: Encoding
    let maximumFullToolResultBytes: Int
    let additionalEscapedPayloadBytes: Int
    let resultTokenEstimate: Int?
    let preparedPacketSHA256: String?
    let canonicalToolResultSHA256: String?
    let canonicalPayloadSHA256: String?
    static func readCeiling(_ fullResultBytes: Int) throws -> Self {
        guard (1...65_536).contains(fullResultBytes) else { throw NativeSourcePressureModelError.invalidMetadata }
        return try Self(kind: .readCeiling, encoding: currentReadEncoding,
            maximumFullToolResultBytes: fullResultBytes, additionalEscapedPayloadBytes: fullResultBytes * readExpansionFactor,
            resultTokenEstimate: nil, preparedPacketSHA256: nil, canonicalToolResultSHA256: nil,
            canonicalPayloadSHA256: nil).validated()
    }
    func validated() throws -> Self {
        try NativeSourcePressureValidation.require((1...1_048_576).contains(maximumFullToolResultBytes)
            && (0...(6 * 1_048_576)).contains(additionalEscapedPayloadBytes)
            && (resultTokenEstimate.map { $0 >= 0 } ?? true))
        for sha in [preparedPacketSHA256, canonicalToolResultSHA256, canonicalPayloadSHA256].compactMap({ $0 }) {
            try NativeSourcePressureValidation.hash(sha)
        }
        switch kind {
        case .readCeiling:
            try NativeSourcePressureValidation.require(encoding == Self.currentReadEncoding
                && maximumFullToolResultBytes <= 65_536
                && additionalEscapedPayloadBytes == maximumFullToolResultBytes * Self.readExpansionFactor
                && resultTokenEstimate == nil && preparedPacketSHA256 == nil
                && canonicalToolResultSHA256 == nil && canonicalPayloadSHA256 == nil)
        case .preparedCheckpoint:
            try NativeSourcePressureValidation.require(encoding == .exactPreparedPayloadV1
                && additionalEscapedPayloadBytes > 0 && resultTokenEstimate != nil
                && preparedPacketSHA256 != nil && canonicalToolResultSHA256 != nil && canonicalPayloadSHA256 != nil)
        case .readyHandoff:
            try NativeSourcePressureValidation.require(encoding == .noContinuationV1
                && additionalEscapedPayloadBytes == 0 && resultTokenEstimate == nil)
        }
        return self
    }
}

struct NativeSourceProspectiveContext: Codable, Sendable {
    let projectedRetainedInputTokens: Int
    // Actual exact input-only preflight count, including the existing "0" placeholder.
    let serializedInputBytes: Int
    let outputRequirement: NativeSourceToolOutputRequirement?
    let continuationPreflight: NativeSourceStoredPreflight?
    func validated(observation: NativeSourceBudgetObservation.Fields) throws -> Self {
        try NativeSourcePressureValidation.require(projectedRetainedInputTokens >= 0
            && (1...524_288).contains(serializedInputBytes)
            && projectedRetainedInputTokens >= (observation.actual.retainedInputTokens ?? 0))
        _ = try outputRequirement?.validated()
        let source = try observation.preflight.value()
        switch observation.binding.boundary {
        case .beforeProviderPost:
            try NativeSourcePressureValidation.require(outputRequirement == nil && continuationPreflight == nil
                && serializedInputBytes == (source.kind == .root ? source.bodyByteCount : source.serializedInputByteCount))
        case .acceptedProviderResponse:
            throw NativeSourcePressureModelError.invalidMetadata
        case .beforeToolOutput:
            guard let requirement = outputRequirement, requirement.kind != .readyHandoff,
                  let next = try continuationPreflight?.value() else { throw NativeSourcePressureModelError.invalidMetadata }
            try NativeSourcePressureValidation.require(next.kind == .continuation
                && next.modelKey == source.modelKey && next.limits == source.limits
                && next.configurationRevision == source.configurationRevision
                && next.configurationFingerprintSHA256 == source.configurationFingerprintSHA256
                && next.serializedInputByteCount == serializedInputBytes)
            try NativeSourcePressureValidation.require((requirement.kind == .readCeiling && observation.binding.pendingCall?.toolName == "fs_read")
                || (requirement.kind == .preparedCheckpoint && observation.binding.pendingCall?.toolName == "session_checkpoint"))
        }
        // Numeric projection is recomputed by the pure evaluator and CP at commit.
        // It is never written into actual provider usage, history or result counters.
        return self
    }
}

struct NativeSourceBudgetObservation: Codable, Sendable {
    // Fields is a bounded transport value, not a CP-issued snapshot/authority token.
    struct Fields: Codable, Sendable {
        let binding: NativeSourceBudgetBinding
        let preflight: NativeSourceStoredPreflight
        let capabilities: ProviderCapabilities
        let configuration: ContextBudgetConfiguration
        let originalCeilings: NativeSourceBudgetCeilings?
        let effectiveCeilings: NativeSourceBudgetCeilings
        let toolSchemaSHA256: String
        let actual: NativeSourceObservedContext
        let prospective: NativeSourceProspectiveContext?
    }
    let fields: Fields
    init(_ fields: Fields) throws { self.fields = try Self.checked(fields) }
    init(from decoder: Decoder) throws { fields = try Self.checked(Fields(from: decoder)) }
    func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }
    var binding: NativeSourceBudgetBinding { fields.binding }
    var policySelection: BudgetPolicySelection { fields.configuration.resolvedPolicy!.selection }
    var observedTotalTokens: Int? { get throws { try fields.actual.retainedInputTokens.map {
        try NativeSourcePressureValidation.sum($0, fields.effectiveCeilings.reserves.fixedTotal())
    } } }
    var projectedTotalTokens: Int? { get throws { try fields.prospective.map {
        try NativeSourcePressureValidation.sum($0.projectedRetainedInputTokens, fields.effectiveCeilings.reserves.fixedTotal())
    } } }

    private static func checked(_ value: Fields) throws -> Fields {
        _ = try value.binding.validated(); _ = try value.configuration.validated()
        _ = try value.originalCeilings?.validated(); _ = try value.effectiveCeilings.validated()
        try NativeSourcePressureValidation.hash(value.toolSchemaSHA256)
        let p = try value.preflight.value(), c = value.capabilities
        _ = try ProviderCapabilities(providerID: c.providerID, providerVersion: c.providerVersion,
            modelKey: c.modelKey, providerInstanceID: c.providerInstanceID, contextLength: c.contextLength,
            maximumContextLength: c.maximumContextLength, statefulResponses: c.statefulResponses,
            streaming: c.streaming, customTools: c.customTools, mcp: c.mcp, structuredOutput: c.structuredOutput,
            usageReporting: c.usageReporting, idempotencyLookup: c.idempotencyLookup,
            capabilityFingerprintSHA256: c.capabilityFingerprintSHA256)
        try NativeSourcePressureValidation.hash(c.capabilityFingerprintSHA256)
        guard let resolved = value.configuration.resolvedPolicy else { throw NativeSourcePressureModelError.invalidMetadata }
        try NativeSourcePressureValidation.require(resolved.inheritedSourceBudget == nil
            && resolved.verifiedLoadedContextTokens == c.contextLength && c.statefulResponses && c.customTools
            && p.modelKey == c.modelKey && resolved.selection.scope.kind == .projectOverride
            && resolved.selection.scope.projectID == value.binding.projectID.description
            && resolved.selection.scope.projectGeneration == Int(exactly: value.binding.projectGeneration.rawValue))
        let e = value.effectiveCeilings, original = value.originalCeilings
        try NativeSourcePressureValidation.require(e.effectiveContextTokens == min(resolved.effectiveContextTokens,
                original?.effectiveContextTokens ?? Int.max)
            && p.limits.maximumOutputTokens <= (original?.maximumOutputTokens ?? Int.max)
            && e.maximumOutputTokens == p.limits.maximumOutputTokens
            && e.checkpointRatio == min(resolved.effectiveCheckpointRatio, original?.checkpointRatio ?? 1)
            && e.rolloverRatio == min(resolved.effectiveRolloverRatio, original?.rolloverRatio ?? 1)
            && e.emergencyRatio == min(resolved.effectiveEmergencyRatio, original?.emergencyRatio ?? 1))
        let current = value.configuration.reserves, prior = original?.reserves
        try NativeSourcePressureValidation.require(e.reserves == ContextBudgetReserves(
            outputTokens: max(current.outputTokens, prior?.outputTokens ?? 0, p.limits.maximumOutputTokens),
            schemaTokens: max(current.schemaTokens, prior?.schemaTokens ?? 0),
            handoffTokens: max(current.handoffTokens, prior?.handoffTokens ?? 0),
            recoveryTokens: max(current.recoveryTokens, prior?.recoveryTokens ?? 0),
            futureToolTokens: max(current.futureToolTokens, prior?.futureToolTokens ?? 0),
            safetyTokens: max(current.safetyTokens, prior?.safetyTokens ?? 0)))
        let t = resolved.selection.policy.tools, old = original?.tools
        let expectedTools = try BudgetToolPolicy(
            callsPerTurn: min(t.callsPerTurn, old?.callsPerTurn ?? Int.max),
            callsPerSession: min(t.callsPerSession, old?.callsPerSession ?? Int.max),
            callsPerRun: min(t.callsPerRun, old?.callsPerRun ?? Int.max), maxInFlight: min(t.maxInFlight, old?.maxInFlight ?? Int.max),
            maxResultBytes: min(t.maxResultBytes, old?.maxResultBytes ?? Int.max),
            maxRetainedResultTokens: min(t.maxRetainedResultTokens, old?.maxRetainedResultTokens ?? Int.max),
            recoveryCallsPerRollover: min(t.recoveryCallsPerRollover, old?.recoveryCallsPerRollover ?? Int.max)).validated()
        try NativeSourcePressureValidation.require(e.tools == expectedTools)
        _ = try value.actual.validated(binding: value.binding, policy: value.configuration.policy)
        if value.binding.observedResult == nil {
            try NativeSourcePressureValidation.require(value.binding.boundary == .beforeProviderPost
                && p.kind == .root && value.actual.rawProviderUsage == nil && value.actual.retainedSerializedBytes == 0)
        }
        if value.binding.boundary == .acceptedProviderResponse {
            try NativeSourcePressureValidation.require(value.prospective == nil)
        } else {
            guard let prospective = value.prospective else { throw NativeSourcePressureModelError.invalidMetadata }
            _ = try prospective.validated(observation: value)
        }
        _ = try NativeSourcePressureValidation.canonical(value)
        return value
    }
}

struct NativeSourcePressureDecision: Codable, Sendable {
    private struct Fields: Codable { let observation: NativeSourceBudgetObservation; let reason: NativeSourcePressureReason; let action: ContextBudgetAction }
    let observation: NativeSourceBudgetObservation
    let reason: NativeSourcePressureReason
    let action: ContextBudgetAction
    init(observation: NativeSourceBudgetObservation, reason: NativeSourcePressureReason, action: ContextBudgetAction) throws {
        self.observation = observation; self.reason = reason; self.action = action
        _ = try validated()
    }
    init(from decoder: Decoder) throws {
        let value = try Fields(from: decoder)
        try self.init(observation: value.observation, reason: value.reason, action: value.action)
    }
    func encode(to encoder: Encoder) throws { try Fields(observation: observation, reason: reason, action: action).encode(to: encoder) }
    func validated() throws -> Self {
        let e = observation.fields.effectiveCeilings
        try NativeSourcePressureValidation.require(action == .rollover || action == .emergency)
        // A reservation configuration that cannot fit even empty context is blocked.
        try NativeSourcePressureValidation.require(try e.reserves.fixedTotal() < e.effectiveContextTokens)
        let total = try observation.projectedTotalTokens ?? observation.observedTotalTokens
        switch reason {
        case .observedContextOverflow:
            try NativeSourcePressureValidation.require(action == .emergency
                && observation.fields.actual.source == .providerOverflow)
        case .accumulatedOutputEnvelope:
            guard let projection = observation.fields.prospective, let requirement = projection.outputRequirement,
                  let preflight = try projection.continuationPreflight?.value() else { throw NativeSourcePressureModelError.invalidMetadata }
            let projectedBytes = try NativeSourcePressureValidation.sum(preflight.bodyByteCount, requirement.additionalEscapedPayloadBytes)
            try NativeSourcePressureValidation.require(observation.binding.boundary == .beforeToolOutput
                && observation.binding.completedOutputCount > 0
                && projectedBytes > min(524_288, preflight.limits.maximumRequestBytes))
            // CP/evaluator must additionally prove the full requirement can fit the
            // irreducible request envelope; current-prefix presence alone is insufficient.
        case .rolloverThreshold, .emergencyThreshold, .projectedInputContext, .projectedToolResultContext:
            guard let total else { throw NativeSourcePressureModelError.invalidMetadata }
            let emergency = Int(ceil(Double(e.effectiveContextTokens) * e.emergencyRatio))
            let rollover = Int(ceil(Double(e.effectiveContextTokens) * e.rolloverRatio))
            try NativeSourcePressureValidation.require(total >= rollover
                && action == (total >= emergency ? .emergency : .rollover))
            if reason == .projectedInputContext { try NativeSourcePressureValidation.require(observation.binding.boundary == .beforeProviderPost) }
            if reason == .projectedToolResultContext { try NativeSourcePressureValidation.require(observation.binding.boundary == .beforeToolOutput) }
            if reason == .emergencyThreshold { try NativeSourcePressureValidation.require(action == .emergency) }
            if reason == .rolloverThreshold { try NativeSourcePressureValidation.require(action == .rollover) }
        }
        _ = try NativeSourcePressureValidation.canonical(self)
        return self
    }
}

struct NativeSourceBudgetFailure: Codable, Sendable {
    let binding: NativeSourceBudgetBinding
    let code: NativeSourceBudgetFailureCode
    let observation: NativeSourceBudgetObservation?
    func validated() throws -> Self {
        _ = try binding.validated()
        if let observation { try NativeSourcePressureValidation.require(observation.binding == binding) }
        _ = try NativeSourcePressureValidation.canonical(self)
        return self
    }
}

enum NativeSourceBudgetMetadata: Codable, Sendable {
    static let maximumStoredBytes = 32_768
    case pressure(NativeSourcePressureDecision)
    case blocked(NativeSourceBudgetFailure)
    private enum Kind: String, Codable { case pressure, blocked }
    private enum Keys: String, CodingKey { case version, kind, pressure, blocked }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw NativeSourcePressureModelError.invalidMetadata }
        switch try c.decode(Kind.self, forKey: .kind) {
        case .pressure:
            try NativeSourcePressureValidation.require(!c.contains(.blocked))
            self = .pressure(try c.decode(NativeSourcePressureDecision.self, forKey: .pressure).validated())
        case .blocked:
            try NativeSourcePressureValidation.require(!c.contains(.pressure))
            self = .blocked(try c.decode(NativeSourceBudgetFailure.self, forKey: .blocked).validated())
        }
        _ = try canonicalJSON()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(1, forKey: .version)
        switch self {
        case .pressure(let value): try c.encode(Kind.pressure, forKey: .kind); try c.encode(value, forKey: .pressure)
        case .blocked(let value): try c.encode(Kind.blocked, forKey: .kind); try c.encode(value, forKey: .blocked)
        }
    }
    func canonicalJSON() throws -> Data {
        switch self {
        case .pressure(let value): _ = try value.validated()
        case .blocked(let value): _ = try value.validated()
        }
        return try NativeSourcePressureValidation.canonical(self)
    }
    static func storedSnapshot(from data: Data) throws -> Self {
        guard (1...maximumStoredBytes).contains(data.count) else { throw NativeSourcePressureModelError.metadataTooLarge }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        // Reject unknown keys, duplicate/rounded count spellings, and noncanonical
        // layouts before accepting stored metadata. CP also checks its separate SHA.
        try NativeSourcePressureValidation.require(decoded.canonicalJSON() == data)
        return decoded
    }
}

// NON-CODABLE read projection, issued by the existing CP read under the exact
// native source lease. The binding is then rechecked at pressure persistence.
struct NativeSourceAcceptedBudgetContext: Sendable {
    let binding: NativeSourceBudgetBinding
    let accepted: NativeSourceAcceptedProviderTurn
    let retainedContextSerializedBytes: Int
    // CP uses prior bytes + actual retained POST bytes + normalized response bytes,
    // including assistant-only responses. No fabricated tool reference or usage.
}

// Pure evaluator entrypoints consume these measurements without issuing authority:
// providerDecision(prepared:preflight:capabilities:policySelection:binding:)
//   -> NativeSourceBudgetDecision<NativeSourceProviderBudgetApproval>
// acceptedDecision(context:policySelection:)
//   -> NativeSourceBudgetDecision<NativeSourceBudgetObservation>
// outputDecision(call:priorOutputs:emptyOutputPreflight:requirement:capabilities:policySelection:binding:)
//   -> NativeSourceBudgetDecision<NativeSourceProviderOutputBudget>
//
// CP recordNativeSourcePressure(...metadata...) must authenticate before reading
// rows and independently compare exact intent/logical-input/assignment/probe/
// preflight/result/ordered-prefix/call/policy/ceilings. Metadata is not authority.
// Unknown/submitted/provider error paths stay lookup-only outside this API.
// No NativeSourcePressureClaim constructor or storage deadline belongs here.

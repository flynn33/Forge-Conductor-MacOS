import Foundation

/// Pure packet-construction data. These values do not grant storage, task or provider authority.
struct NativeSourcePressurePacketIdentity: Sendable {
    let pressureID: UUID
    let continuityID: String
    let recordedAt: String
    let projectID: ProjectID
    let projectGeneration: ProjectGeneration
    let taskID: UUID
    let conversationID: UUID
    let requestID: UUID
    let stageID: UUID
    let fenceRevision: Int64
    let assignmentSHA256: String
    let logicalInputSHA256: String
    let intentSHA256: String

    var wireObject: [String: Any] {
        ["pressure_id": pressureID.uuidString.lowercased(), "continuity_id": continuityID,
         "recorded_at": recordedAt, "project_id": projectID.description, "project_generation": projectGeneration.rawValue,
         "task_id": taskID.uuidString.lowercased(), "conversation_id": conversationID.uuidString.lowercased(),
         "logical_request_id": requestID.uuidString.lowercased(), "stage_id": stageID.uuidString.lowercased(),
         "fence_revision": fenceRevision, "assignment_sha256": assignmentSHA256,
         "logical_input_sha256": logicalInputSHA256, "intent_sha256": intentSHA256]
    }
}

/// Task-facing measurement facts derived from the complete validated CP metadata.
/// The metadata digest identifies that full decision, not its enclosing CP disposition.
/// Critical work data and remaining ceilings are retained elsewhere in the same packet.
struct NativeSourcePressurePacketDecisionV1: Sendable {
    static let maximumStoredBytes = 4_096
    private struct Projection: Encodable, Sendable {
        let projectedRetainedInputTokens: Int
        let serializedInputBytes: Int
        let maximumFullToolResultBytes: Int?
        let additionalEscapedPayloadBytes: Int?
    }
    private struct Fields: Encodable, Sendable {
        let version: Int
        let metadataSHA256: String
        let bindingIdentitySHA256: String
        let reason: NativeSourcePressureReason
        let action: ContextBudgetAction
        let boundary: NativeSourceBudgetBoundary
        let capabilityID: String
        let capabilityEpoch: Int64
        let stageOrdinal: Int
        let sourceInferenceDeadline: String
        let observedResultStageID: String?
        let completedOutputCount: Int
        let completedOutputsSHA256: String
        let pendingCallOrdinal: Int?
        let actual: NativeSourceObservedContext
        let prospective: Projection?
        enum CodingKeys: String, CodingKey {
            case version, reason, action, boundary, actual, prospective
            case metadataSHA256 = "metadata_sha256", bindingIdentitySHA256 = "binding_identity_sha256"
            case capabilityID = "capability_id", capabilityEpoch = "capability_epoch", stageOrdinal = "stage_ordinal"
            case sourceInferenceDeadline = "source_inference_deadline", observedResultStageID = "observed_result_stage_id"
            case completedOutputCount = "completed_output_count", completedOutputsSHA256 = "completed_outputs_sha256"
            case pendingCallOrdinal = "pending_call_ordinal"
        }
    }
    let canonicalJSON: Data
    private init(_ fields: Fields) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(fields)
        guard encoded.count <= Self.maximumStoredBytes else { throw NativeSourcePressurePacketError.decisionProjectionTooLarge }
        let canonical = try ForgeJSONCanonicalizationV1.data(from: JSONSerialization.jsonObject(with: encoded))
        guard canonical.count <= Self.maximumStoredBytes else { throw NativeSourcePressurePacketError.decisionProjectionTooLarge }
        canonicalJSON = canonical
    }

    static func projecting(metadataJSON: Data, identity: NativeSourcePressurePacketIdentity) throws -> Self {
        guard case .pressure(let decision) = try NativeSourceBudgetMetadata.storedSnapshot(from: metadataJSON) else {
            throw NativeSourcePressurePacketError.invalidSnapshot
        }
        let observation = decision.observation.fields, binding = observation.binding
        let revision = binding.conversationRevision.addingReportingOverflow(1)
        guard !revision.overflow, revision.partialValue == identity.fenceRevision,
              binding.projectID == identity.projectID, binding.projectGeneration == identity.projectGeneration,
              binding.taskID == identity.taskID, binding.conversationID == identity.conversationID,
              binding.stageID == identity.stageID, binding.logicalRequestID == identity.requestID,
              binding.assignmentSHA256 == identity.assignmentSHA256, binding.logicalInputSHA256 == identity.logicalInputSHA256,
              binding.intentSHA256 == identity.intentSHA256 else { throw NativeSourcePressurePacketError.invalidSnapshot }
        return try Self(.init(version: 1, metadataSHA256: JSONSupport.sha256Hex(metadataJSON),
            bindingIdentitySHA256: ForgeJSONCanonicalizationV1.sha256Hex(of: identity.wireObject),
            reason: decision.reason, action: decision.action, boundary: binding.boundary,
            capabilityID: binding.capabilityID.uuidString.lowercased(), capabilityEpoch: binding.capabilityEpoch,
            stageOrdinal: binding.stageOrdinal, sourceInferenceDeadline: binding.sourceInferenceDeadline,
            observedResultStageID: binding.observedResult?.stageID.uuidString.lowercased(),
            completedOutputCount: binding.completedOutputCount, completedOutputsSHA256: binding.completedOutputsSHA256,
            pendingCallOrdinal: binding.pendingCall?.ordinal, actual: observation.actual,
            prospective: observation.prospective.map { .init(projectedRetainedInputTokens: $0.projectedRetainedInputTokens,
                serializedInputBytes: $0.serializedInputBytes, maximumFullToolResultBytes: $0.outputRequirement?.maximumFullToolResultBytes,
                additionalEscapedPayloadBytes: $0.outputRequirement?.additionalEscapedPayloadBytes) }))
    }

    /// Verify exact retained projection bytes against the original complete metadata;
    /// a digest or a packet projection alone never substitutes for that evidence.
    static func storedSnapshot(from data: Data, metadataJSON: Data, identity: NativeSourcePressurePacketIdentity) throws -> Self {
        guard (1...maximumStoredBytes).contains(data.count) else { throw NativeSourcePressurePacketError.decisionProjectionTooLarge }
        let expected = try projecting(metadataJSON: metadataJSON, identity: identity)
        guard data == expected.canonicalJSON else { throw NativeSourcePressurePacketError.invalidSnapshot }
        return expected
    }
}

enum NativeSourcePressureRequestKind: String, Sendable {
    case root, userContinuation = "user_continuation", toolContinuation = "tool_continuation"
}

enum NativeSourcePressureLogicalInput: Sendable {
    case originalUTF8(Data)
    /// Old rows have no separately retained logical input. These are the entire retained
    /// request bytes, explicitly labelled; no delimiter parsing or guessed input backfill.
    case legacyRetainedRequest(kind: NativeSourcePressureRequestKind, utf8: Data)
}

struct NativeSourcePressurePendingRequest: Sendable {
    let kind: NativeSourcePressureRequestKind
    let utf8: Data
    let inputSHA256: String
    /// Historical identity only. A fresh successor must not use it as a provider parent.
    let historicalParentResponseID: String?
}

struct NativeSourcePressureCompletedProgress: Sendable {
    let stageID: UUID
    let providerResponseID: String
    let resultSHA256: String
    /// Complete retained assistant progress, not a generated summary or optional preview.
    let messages: [String]
}

struct NativeSourcePressureCompletedOutput: Sendable {
    let stageID: UUID
    let ordinal: Int
    let providerResponseID: String
    let providerCallID: String
    let toolName: String
    let canonicalArgumentsJSON: Data
    let argumentsSHA256: String
    let canonicalToolResultJSON: Data
    let resultSHA256: String
    let payloadSHA256: String
    let reservationID: UUID
    let sourceReceiptSHA256: String
}

struct NativeSourcePressurePendingCall: Sendable {
    let stageID: UUID
    let ordinal: Int
    let providerResponseID: String
    let providerCallID: String
    let toolName: String
    let canonicalArgumentsJSON: Data
    let argumentsSHA256: String
}

struct NativeSourcePressureRemainingBudget: Sendable {
    let ceilings: NativeSourceBudgetCeilings
    let sourceLimits: NativeTaskSourceLimits
    let priorSourceReadCallsAtEnrollment: Int
    /// Includes admitted suffix calls even when no effect ran. Never refund them at handoff.
    let admittedProviderCalls: Int
    let providerStageCount: Int
    let capabilityCheckCount: Int
}

struct NativeSourcePressurePacketInput: Sendable {
    let identity: NativeSourcePressurePacketIdentity
    let assignment: ContinuityTaskAssignment
    let logicalInput: NativeSourcePressureLogicalInput
    let pendingRequest: NativeSourcePressurePendingRequest?
    let completedProgress: [NativeSourcePressureCompletedProgress]
    let completedOutputs: [NativeSourcePressureCompletedOutput]
    let untouchedCalls: [NativeSourcePressurePendingCall]
    /// Complete factual uncertainty, retained as task data. Unresolved actual effects
    /// separately block construction; a packet is not permission to replay those effects.
    let uncertainties: [String]
    let unresolvedEffects: [String]
    let remainingBudget: NativeSourcePressureRemainingBudget
    /// Canonical bounded native decision metadata, produced by the pure budget evaluator.
    /// The control plane independently validates its binding before issuing any claim.
    let canonicalDecisionJSON: Data
    let optionalPreview: String?
}

enum NativeSourcePressurePacketError: Error, Sendable, Equatable {
    case invalidSnapshot
    case unresolvedEffect
    case assignmentNotUTF8
    case logicalInputNotUTF8
    case criticalPacketTooLarge
    case decisionProjectionTooLarge
    case bootstrapOutputTooLarge
    case commitResponseTooLarge
    case invalidResponsePreflight
    case responsePreflightRejected
}

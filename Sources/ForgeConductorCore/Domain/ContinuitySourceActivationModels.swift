// Exact manager-issued source transfer and observed continuation receipts.

import Foundation

enum ContinuitySourceStartAuthority: Sendable, Equatable {
    case automaticPolicy
    case explicitRequest(permitSHA256: String)
}

enum ContinuitySourceRecoveryPhase: String, Sendable, Equatable {
    case bootstrap, activation
}

enum ContinuitySourceActivationError: Error, LocalizedError, Sendable, Equatable {
    case sourceFenced, taskIdentityUnavailable, unresolvedEffects, proofRequired, continuationEffectRequired, conflict, invalidRequest
    var errorDescription: String? {
        switch self {
        case .sourceFenced: "This exact source task has transferred its mutation authority."
        case .taskIdentityUnavailable: "task_identity_unavailable: the source lacks verified task-scoped mutation dispatch authority."
        case .unresolvedEffects: "Outstanding effects require reconciliation before source transfer."
        case .proofRequired: "Source activation requires matching durable canonical and provider proof."
        case .continuationEffectRequired: "The accepted successor has not yet produced a verified authorized tool effect."
        case .conflict: "Source transfer differs from the durable accepted operation."
        case .invalidRequest: "Source transfer request is outside its supported bounds."
        }
    }
}

struct ContinuityExplicitStartReceipt: Sendable, Equatable {
    let acceptance: ContinuityIngressAcceptanceReceipt
    let permit: ContinuityExplicitStartPermit
}

struct ContinuityExplicitStartPermit: Sendable, Equatable {
    static let maximumStoredBytes = 8 * 1_024
    let requestID: UUID
    let operationID: UUID
    let acceptanceReceiptSHA256: String
    let authorizationSHA256: String
    let taskID: UUID
    let sourceBindingID: UUID
    let assignmentSHA256: String
    let callerBindingID: UUID
    let issuedAt: String
    let canonicalPermitJSON: Data
    let permitSHA256: String

    init(requestID: UUID, acceptance: ContinuityIngressAcceptanceReceipt, callerBindingID: UUID, issuedAt: String) throws {
        try SourceActivationCoding.timestamp(issuedAt)
        let authorization = acceptance.authorization
        let authSHA = JSONSupport.sha256Hex(try authorization.encodedJSON())
        let data = try ForgeJSONCanonicalizationV1.data(from: [
            "schema_version": 1, "kind": "explicit_source_start", "request_id": requestID.uuidString.lowercased(),
            "operation_id": acceptance.operationID.uuidString.lowercased(), "acceptance_receipt_sha256": acceptance.receiptSHA256,
            "authorization_sha256": authSHA, "task_id": authorization.taskID.uuidString.lowercased(),
            "source_binding_id": authorization.sourceBindingID.uuidString.lowercased(), "assignment_sha256": authorization.assignmentSHA256,
            "caller_binding_id": callerBindingID.uuidString.lowercased(), "issued_at": issuedAt,
        ])
        guard data.count <= Self.maximumStoredBytes else { throw ContinuitySourceActivationError.invalidRequest }
        self.requestID = requestID; operationID = acceptance.operationID; acceptanceReceiptSHA256 = acceptance.receiptSHA256
        authorizationSHA256 = authSHA; taskID = authorization.taskID; sourceBindingID = authorization.sourceBindingID
        assignmentSHA256 = authorization.assignmentSHA256; self.callerBindingID = callerBindingID; self.issuedAt = issuedAt
        canonicalPermitJSON = data; permitSHA256 = JSONSupport.sha256Hex(data)
    }

    static func storedSnapshot(from data: Data, acceptance: ContinuityIngressAcceptanceReceipt) throws -> Self {
        let object = try SourceActivationCoding.object(data, maximum: maximumStoredBytes)
        let value = try Self(requestID: SourceActivationCoding.uuid(object, "request_id"), acceptance: acceptance,
            callerBindingID: SourceActivationCoding.uuid(object, "caller_binding_id"), issuedAt: SourceActivationCoding.text(object, "issued_at"))
        guard value.canonicalPermitJSON == data else { throw ContinuitySourceActivationError.proofRequired }
        return value
    }
}

struct ContinuitySourceActivationReceipt: Sendable, Equatable {
    static let maximumStoredBytes = 96 * 1_024
    static let maximumContinuationInputBytes = 64 * 1_024
    let envelope: ContinuitySourceBootstrapEnvelope
    let acknowledgedStateChecksum: String
    let candidateID: UUID
    let predecessorProviderSessionID: String?
    let retrievalProofSHA256: String
    let acknowledgementProofSHA256: String
    let acknowledgementProviderTurnID: UUID
    let acknowledgementProviderResponseID: String
    let continuationTurnID: UUID
    let canonicalContinuationInput: Data
    let continuationInputSHA256: String
    let continuationIdempotencyKey: String
    let acceptedAt: String
    let canonicalReceiptJSON: Data
    let receiptSHA256: String

    var acceptance: ContinuityIngressAcceptanceReceipt { envelope.acceptance }
    var operationID: UUID { envelope.operationID }
    var runID: RunID { envelope.runID }
    var authorization: ContinuityIngressAuthorization { envelope.authorization }

    init(envelope: ContinuitySourceBootstrapEnvelope, acknowledgedStateChecksum: String, candidateID: UUID,
         predecessorProviderSessionID: String?, retrievalProofSHA256: String, acknowledgementProofSHA256: String,
         acknowledgementProviderTurnID: UUID, acknowledgementProviderResponseID: String, continuationTurnID: UUID,
         canonicalContinuationInput: Data, continuationIdempotencyKey: String, acceptedAt: String) throws {
        guard try ContinuitySourceBootstrapEnvelope.storedSnapshot(from: envelope.canonicalEnvelopeJSON) == envelope,
              !canonicalContinuationInput.isEmpty, canonicalContinuationInput.count <= Self.maximumContinuationInputBytes,
              String(data: canonicalContinuationInput, encoding: .utf8) != nil,
              !acknowledgementProviderResponseID.isEmpty, acknowledgementProviderResponseID.utf8.count <= 2_048,
              predecessorProviderSessionID == nil || (predecessorProviderSessionID!.utf8.count <= 1_024 && !predecessorProviderSessionID!.isEmpty),
              !continuationIdempotencyKey.isEmpty, continuationIdempotencyKey.utf8.count <= 1_024 else {
            throw ContinuitySourceActivationError.invalidRequest
        }
        try SourceActivationCoding.timestamp(acceptedAt)
        for sha in [acknowledgedStateChecksum, retrievalProofSHA256, acknowledgementProofSHA256] { try SourceActivationCoding.digest(sha) }
        let inputSHA = JSONSupport.sha256Hex(canonicalContinuationInput)
        let data = try ForgeJSONCanonicalizationV1.data(from: [
            "schema_version": 1, "kind": "source_successor_acceptance", "operation_id": envelope.operationID.uuidString.lowercased(),
            "run_id": envelope.runID.description, "acceptance_receipt_sha256": envelope.acceptance.receiptSHA256,
            "envelope_sha256": envelope.envelopeSHA256, "acknowledged_state_checksum": acknowledgedStateChecksum,
            "candidate_id": candidateID.uuidString.lowercased(), "predecessor_provider_session_id": predecessorProviderSessionID as Any? ?? NSNull(),
            "retrieval_proof_sha256": retrievalProofSHA256, "acknowledgement_proof_sha256": acknowledgementProofSHA256,
            "acknowledgement_provider_turn_id": acknowledgementProviderTurnID.uuidString.lowercased(),
            "acknowledgement_provider_response_id": acknowledgementProviderResponseID,
            "continuation_turn_id": continuationTurnID.uuidString.lowercased(), "continuation_input_base64": canonicalContinuationInput.base64EncodedString(),
            "continuation_input_sha256": inputSHA, "continuation_idempotency_key": continuationIdempotencyKey, "accepted_at": acceptedAt,
        ])
        guard data.count <= Self.maximumStoredBytes else { throw ContinuitySourceActivationError.invalidRequest }
        self.envelope = envelope; self.acknowledgedStateChecksum = acknowledgedStateChecksum; self.candidateID = candidateID
        self.predecessorProviderSessionID = predecessorProviderSessionID; self.retrievalProofSHA256 = retrievalProofSHA256
        self.acknowledgementProofSHA256 = acknowledgementProofSHA256; self.acknowledgementProviderTurnID = acknowledgementProviderTurnID
        self.acknowledgementProviderResponseID = acknowledgementProviderResponseID; self.continuationTurnID = continuationTurnID
        self.canonicalContinuationInput = canonicalContinuationInput; continuationInputSHA256 = inputSHA
        self.continuationIdempotencyKey = continuationIdempotencyKey; self.acceptedAt = acceptedAt
        canonicalReceiptJSON = data; receiptSHA256 = JSONSupport.sha256Hex(data)
    }

    static func storedSnapshot(from data: Data, envelope: ContinuitySourceBootstrapEnvelope) throws -> Self {
        let object = try SourceActivationCoding.object(data, maximum: maximumStoredBytes)
        guard let input = Data(base64Encoded: try SourceActivationCoding.text(object, "continuation_input_base64")) else {
            throw ContinuitySourceActivationError.proofRequired
        }
        let value = try Self(envelope: envelope, acknowledgedStateChecksum: SourceActivationCoding.text(object, "acknowledged_state_checksum"),
            candidateID: SourceActivationCoding.uuid(object, "candidate_id"), predecessorProviderSessionID: object["predecessor_provider_session_id"] as? String,
            retrievalProofSHA256: SourceActivationCoding.text(object, "retrieval_proof_sha256"),
            acknowledgementProofSHA256: SourceActivationCoding.text(object, "acknowledgement_proof_sha256"),
            acknowledgementProviderTurnID: SourceActivationCoding.uuid(object, "acknowledgement_provider_turn_id"),
            acknowledgementProviderResponseID: SourceActivationCoding.text(object, "acknowledgement_provider_response_id"),
            continuationTurnID: SourceActivationCoding.uuid(object, "continuation_turn_id"), canonicalContinuationInput: input,
            continuationIdempotencyKey: SourceActivationCoding.text(object, "continuation_idempotency_key"), acceptedAt: SourceActivationCoding.text(object, "accepted_at"))
        guard value.canonicalReceiptJSON == data else { throw ContinuitySourceActivationError.proofRequired }
        return value
    }
}

struct ContinuitySourceResumptionReceipt: Sendable, Equatable {
    static let maximumStoredBytes = 96 * 1_024
    let activationReceipt: ContinuitySourceActivationReceipt
    let continuationTurnID: UUID
    let providerResponseID: String
    let toolContinuationTurnID: UUID
    let toolContinuationProviderResponseID: String
    let toolOutputsInputSHA256: String
    let toolInvocationID: UUID
    let toolName: String
    let toolResultSHA256: String
    let canonicalToolResultJSON: Data
    let recordedAt: String
    let canonicalReceiptJSON: Data
    let receiptSHA256: String
    var operationID: UUID { activationReceipt.operationID }
    var runID: RunID { activationReceipt.runID }

    init(activationReceipt: ContinuitySourceActivationReceipt, providerResponseID: String,
         toolContinuationTurnID: UUID, toolContinuationProviderResponseID: String, toolOutputsInputSHA256: String,
         toolInvocationID: UUID, toolName: String, canonicalToolResultJSON: Data, recordedAt: String) throws {
        guard !providerResponseID.isEmpty, providerResponseID.utf8.count <= 2_048,
              !toolContinuationProviderResponseID.isEmpty, toolContinuationProviderResponseID.utf8.count <= 2_048,
              !toolName.isEmpty, toolName.utf8.count <= 256, !canonicalToolResultJSON.isEmpty,
              canonicalToolResultJSON.count <= 65_536,
              let result = try JSONSerialization.jsonObject(with: canonicalToolResultJSON) as? [String: Any],
              result["ok"] as? Bool == true, result["is_error"] as? Bool == false else {
            throw ContinuitySourceActivationError.continuationEffectRequired
        }
        try SourceActivationCoding.timestamp(recordedAt)
        try SourceActivationCoding.digest(toolOutputsInputSHA256)
        let resultSHA = JSONSupport.sha256Hex(canonicalToolResultJSON)
        let data = try ForgeJSONCanonicalizationV1.data(from: [
            "schema_version": 1, "kind": "source_continuation_effect", "activation_receipt_sha256": activationReceipt.receiptSHA256,
            "operation_id": activationReceipt.operationID.uuidString.lowercased(), "run_id": activationReceipt.runID.description,
            "continuation_turn_id": activationReceipt.continuationTurnID.uuidString.lowercased(), "provider_response_id": providerResponseID,
            "tool_continuation_turn_id": toolContinuationTurnID.uuidString.lowercased(),
            "tool_continuation_provider_response_id": toolContinuationProviderResponseID, "tool_outputs_input_sha256": toolOutputsInputSHA256,
            "tool_invocation_id": toolInvocationID.uuidString.lowercased(), "tool_name": toolName, "tool_result_sha256": resultSHA,
            "tool_result_base64": canonicalToolResultJSON.base64EncodedString(), "recorded_at": recordedAt,
        ])
        guard data.count <= Self.maximumStoredBytes else { throw ContinuitySourceActivationError.invalidRequest }
        self.activationReceipt = activationReceipt; continuationTurnID = activationReceipt.continuationTurnID
        self.toolContinuationTurnID = toolContinuationTurnID; self.toolContinuationProviderResponseID = toolContinuationProviderResponseID
        self.toolOutputsInputSHA256 = toolOutputsInputSHA256
        self.providerResponseID = providerResponseID; self.toolInvocationID = toolInvocationID; self.toolName = toolName
        toolResultSHA256 = resultSHA; self.canonicalToolResultJSON = canonicalToolResultJSON; self.recordedAt = recordedAt
        canonicalReceiptJSON = data; receiptSHA256 = JSONSupport.sha256Hex(data)
    }

    static func storedSnapshot(from data: Data, activationReceipt: ContinuitySourceActivationReceipt) throws -> Self {
        let object = try SourceActivationCoding.object(data, maximum: maximumStoredBytes)
        guard let result = Data(base64Encoded: try SourceActivationCoding.text(object, "tool_result_base64")) else {
            throw ContinuitySourceActivationError.proofRequired
        }
        let value = try Self(activationReceipt: activationReceipt, providerResponseID: SourceActivationCoding.text(object, "provider_response_id"),
            toolContinuationTurnID: SourceActivationCoding.uuid(object, "tool_continuation_turn_id"),
            toolContinuationProviderResponseID: SourceActivationCoding.text(object, "tool_continuation_provider_response_id"),
            toolOutputsInputSHA256: SourceActivationCoding.text(object, "tool_outputs_input_sha256"),
            toolInvocationID: SourceActivationCoding.uuid(object, "tool_invocation_id"), toolName: SourceActivationCoding.text(object, "tool_name"),
            canonicalToolResultJSON: result, recordedAt: SourceActivationCoding.text(object, "recorded_at"))
        guard value.canonicalReceiptJSON == data else { throw ContinuitySourceActivationError.proofRequired }
        return value
    }
}

private enum SourceActivationCoding {
    static func object(_ data: Data, maximum: Int) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximum, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContinuitySourceActivationError.proofRequired
        }
        return object
    }
    static func text(_ object: [String: Any], _ key: String) throws -> String {
        guard let text = object[key] as? String else { throw ContinuitySourceActivationError.proofRequired }
        return text
    }
    static func uuid(_ object: [String: Any], _ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try text(object, key)) else { throw ContinuitySourceActivationError.proofRequired }
        return value
    }
    static func digest(_ value: String) throws {
        guard value.count == 64, value.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw ContinuitySourceActivationError.proofRequired }
    }
    static func timestamp(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128, ISO8601.date(from: value) != nil else { throw ContinuitySourceActivationError.proofRequired }
    }
}

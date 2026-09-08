// Canonical preparation for an authorized source task without a provider predecessor.

import Foundation

struct ContinuitySourceBootstrapEnvelope: Sendable, Equatable {
    static let schemaVersion = "3.0"
    static let maximumEncodedBytes = 512 * 1_024

    let acceptance: ContinuityIngressAcceptanceReceipt
    let handoffID: UUID
    let bootstrapNonce: UUID
    let canonicalEnvelopeJSON: Data
    let envelopeSHA256: String

    var operationID: UUID { acceptance.operationID }
    var authorization: ContinuityIngressAuthorization { acceptance.authorization }
    var sourceIdentity: ContinuityHandoffIdentity { acceptance.sourceIdentity }
    var runID: RunID { acceptance.runID }

    init(acceptance: ContinuityIngressAcceptanceReceipt, bootstrapNonce: UUID) throws {
        guard try ContinuityIngressAcceptanceReceipt.storedSnapshot(from: acceptance.canonicalReceiptJSON) == acceptance else {
            throw ContinuityIngressError.integrityFailure("acceptance snapshot differs from its identity")
        }
        let digest = JSONSupport.sha256Hex("source-bootstrap-handoff:\(acceptance.operationID.uuidString.lowercased())")
        let value = String(digest.prefix(32))
        let uuid = "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-\(value.dropFirst(20))"
        guard let handoffID = UUID(uuidString: uuid) else {
            throw ContinuityIngressError.integrityFailure("source bootstrap identifier is invalid")
        }
        let data = try ForgeJSONCanonicalizationV1.data(from: [
            "schema_version": Self.schemaVersion,
            "origin": "authorized_source_task",
            "operation_id": acceptance.operationID.uuidString.lowercased(),
            "handoff_id": handoffID.uuidString.lowercased(),
            "bootstrap_nonce": bootstrapNonce.uuidString.lowercased(),
            "acceptance_receipt_sha256": acceptance.receiptSHA256,
            "acceptance": JSONSerialization.jsonObject(with: acceptance.canonicalReceiptJSON),
        ])
        guard data.count <= Self.maximumEncodedBytes else {
            throw ContinuityIngressError.capacityExceeded("source bootstrap envelope bytes")
        }
        self.acceptance = acceptance
        self.handoffID = handoffID
        self.bootstrapNonce = bootstrapNonce
        self.canonicalEnvelopeJSON = data
        self.envelopeSHA256 = JSONSupport.sha256Hex(data)
    }

    static func storedSnapshot(from data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schema_version", "origin", "operation_id", "handoff_id", "bootstrap_nonce",
                  "acceptance_receipt_sha256", "acceptance"],
              object["schema_version"] as? String == schemaVersion,
              object["origin"] as? String == "authorized_source_task",
              let nonce = (object["bootstrap_nonce"] as? String).flatMap(UUID.init(uuidString:)),
              let receipt = object["acceptance"] as? [String: Any] else {
            throw ContinuityIngressError.integrityFailure("malformed source bootstrap envelope")
        }
        let acceptance = try ContinuityIngressAcceptanceReceipt.storedSnapshot(
            from: ForgeJSONCanonicalizationV1.data(from: receipt))
        let value = try Self(acceptance: acceptance, bootstrapNonce: nonce)
        guard value.canonicalEnvelopeJSON == data else {
            throw ContinuityIngressError.integrityFailure("noncanonical source bootstrap envelope")
        }
        return value
    }
}

/// Preparation is not a provisional grant, context retrieval proof or execution approval.
struct ContinuitySourceBootstrapOperation: Sendable, Equatable {
    static let schemaVersion = 3

    let envelope: ContinuitySourceBootstrapEnvelope
    let state: ContinuityState
    let attempt: Int
    let createdAt: String
    let updatedAt: String
    let stateChecksum: String
    let successorSessionID: UUID?
    let successorProviderResponseID: String?
    let retrievalProofSHA256: String?
    let acknowledgementProofSHA256: String?
    let activationReceiptSHA256: String?
    let resumedReceiptSHA256: String?
    let sealedStateChecksum: String?

    /// Source work is resumed only after the control plane observes a completed
    /// authorized continuation effect. Sealing alone does not set this value.
    var isResumed: Bool { resumedReceiptSHA256 != nil }
    var continuationIssued: Bool { isResumed }

    init(envelope: ContinuitySourceBootstrapEnvelope, state: ContinuityState, attempt: Int,
         createdAt: String, updatedAt: String, stateChecksum: String,
         successorSessionID: UUID?, successorProviderResponseID: String?,
         retrievalProofSHA256: String?, acknowledgementProofSHA256: String?,
         activationReceiptSHA256: String? = nil, resumedReceiptSHA256: String? = nil,
         sealedStateChecksum: String? = nil) {
        self.envelope = envelope; self.state = state; self.attempt = attempt
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.stateChecksum = stateChecksum
        self.successorSessionID = successorSessionID; self.successorProviderResponseID = successorProviderResponseID
        self.retrievalProofSHA256 = retrievalProofSHA256; self.acknowledgementProofSHA256 = acknowledgementProofSHA256
        self.activationReceiptSHA256 = activationReceiptSHA256
        self.resumedReceiptSHA256 = resumedReceiptSHA256
        self.sealedStateChecksum = sealedStateChecksum
    }

    var operationID: UUID { envelope.operationID }
    var runID: RunID { envelope.runID }
    var handoffID: UUID { envelope.handoffID }
    var bootstrapNonce: UUID { envelope.bootstrapNonce }

    static func checksum(envelope: ContinuitySourceBootstrapEnvelope, state: ContinuityState,
                         attempt: Int, createdAt: String, updatedAt: String,
                         successorSessionID: UUID? = nil, successorProviderResponseID: String? = nil,
                         retrievalProofSHA256: String? = nil, acknowledgementProofSHA256: String? = nil,
                         activationReceiptSHA256: String? = nil, resumedReceiptSHA256: String? = nil) throws -> String {
        var fields: [String: Any] = [
            "schema_version": schemaVersion,
            "operation_id": envelope.operationID.uuidString.lowercased(),
            "project_id": envelope.authorization.projectID.description,
            "project_generation": envelope.authorization.projectGeneration.rawValue,
            "run_id": envelope.runID.description,
            "handoff_sha256": envelope.envelopeSHA256,
            "acceptance_receipt_sha256": envelope.acceptance.receiptSHA256,
            "state": state.rawValue, "attempt": attempt,
            "created_at": createdAt, "updated_at": updatedAt,
            "successor_session_id": successorSessionID?.uuidString.lowercased() as Any? ?? NSNull(),
            "successor_provider_response_id": successorProviderResponseID as Any? ?? NSNull(),
            "retrieval_proof_sha256": retrievalProofSHA256 as Any? ?? NSNull(),
            "acknowledgement_proof_sha256": acknowledgementProofSHA256 as Any? ?? NSNull(),
        ]
        // The original schema-3 preparation/ACK bytes remain byte-for-byte
        // unchanged. Only proof-bound completion adds this versioned extension.
        if activationReceiptSHA256 != nil || resumedReceiptSHA256 != nil {
            guard state == .predecessorSealed, let activationReceiptSHA256,
                  validSHA256(activationReceiptSHA256),
                  resumedReceiptSHA256 == nil || validSHA256(resumedReceiptSHA256!) else {
                throw ContinuityIngressError.integrityFailure("invalid source completion proof")
            }
            fields["source_completion_schema"] = 1
            fields["activation_receipt_sha256"] = activationReceiptSHA256
            fields["resumed_receipt_sha256"] = resumedReceiptSHA256 as Any? ?? NSNull()
            fields["continuation_issued"] = resumedReceiptSHA256 != nil
        }
        return try ForgeJSONCanonicalizationV1.sha256Hex(of: fields)
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

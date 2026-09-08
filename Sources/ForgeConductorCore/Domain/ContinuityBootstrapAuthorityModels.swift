// Exact source recovery authority and durable successful-read receipts.

import Foundation

struct ContinuityBootstrapGrant: Sendable, Equatable {
    static let maximumStoredBytes = 8 * 1_024
    let grantID: UUID
    let candidateID: UUID
    let envelope: ContinuitySourceBootstrapEnvelope
    let leaseOwnerID: String
    let leaseEpoch: UInt64
    let expiresAt: String
    let maximumOutputBytes: Int
    let createdAt: String
    var sessionID: String { candidateID.uuidString.lowercased() }

    init(grantID: UUID, candidateID: UUID, envelope: ContinuitySourceBootstrapEnvelope,
         lease: RunLease, maximumOutputBytes: Int, createdAt: String) throws {
        guard lease.runID == envelope.runID, lease.epoch > 0, lease.epoch <= UInt64(Int64.max),
              !lease.ownerID.isEmpty, lease.ownerID.utf8.count <= 512,
              !lease.ownerID.contains("\0"), lease.expiresAt.utf8.count <= 128,
              ISO8601.date(from: lease.expiresAt) != nil,
              createdAt.utf8.count <= 128, ISO8601.date(from: createdAt) != nil,
              (1...65_536).contains(maximumOutputBytes),
              maximumOutputBytes <= envelope.authorization.authorizationScope.maximumInlineOutputBytes else {
            throw ContinuityIngressError.invalidRequest("bootstrap grant bounds")
        }
        self.grantID = grantID
        self.candidateID = candidateID
        self.envelope = envelope
        self.leaseOwnerID = lease.ownerID
        self.leaseEpoch = lease.epoch
        self.expiresAt = lease.expiresAt
        self.maximumOutputBytes = maximumOutputBytes
        self.createdAt = createdAt
        guard try storedJSON().count <= Self.maximumStoredBytes else {
            throw ContinuityIngressError.capacityExceeded("bootstrap grant bytes")
        }
    }

    func storedJSON() throws -> Data {
        try ForgeJSONCanonicalizationV1.data(from: [
            "schema_version": 1, "grant_id": grantID.uuidString.lowercased(),
            "candidate_id": candidateID.uuidString.lowercased(), "operation_id": envelope.operationID.uuidString.lowercased(),
            "run_id": envelope.runID.description, "handoff_id": envelope.handoffID.uuidString.lowercased(),
            "handoff_sha256": envelope.envelopeSHA256, "bootstrap_nonce": envelope.bootstrapNonce.uuidString.lowercased(),
            "acceptance_sha256": envelope.acceptance.receiptSHA256,
            "continuity_id": envelope.sourceIdentity.continuityID, "revision": envelope.sourceIdentity.revision,
            "packet_sha256": envelope.sourceIdentity.packetSHA256,
            "lease_owner_id": leaseOwnerID, "lease_epoch": leaseEpoch, "expires_at": expiresAt,
            "maximum_output_bytes": maximumOutputBytes, "created_at": createdAt,
        ])
    }

    static func storedSnapshot(from data: Data, envelope: ContinuitySourceBootstrapEnvelope) throws -> Self {
        guard data.count <= maximumStoredBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let grant = (object["grant_id"] as? String).flatMap(UUID.init(uuidString:)),
              let candidate = (object["candidate_id"] as? String).flatMap(UUID.init(uuidString:)),
              let owner = object["lease_owner_id"] as? String,
              let epoch = object["lease_epoch"] as? UInt64,
              let expires = object["expires_at"] as? String, let created = object["created_at"] as? String,
              let limit = object["maximum_output_bytes"] as? Int else {
            throw ContinuityIngressError.integrityFailure("malformed bootstrap grant")
        }
        let lease = RunLease(runID: envelope.runID, ownerID: owner, epoch: epoch,
            acquiredAt: created, renewedAt: created, expiresAt: expires)
        let value = try Self(grantID: grant, candidateID: candidate, envelope: envelope,
            lease: lease, maximumOutputBytes: limit, createdAt: created)
        guard try value.storedJSON() == data else {
            throw ContinuityIngressError.integrityFailure("noncanonical bootstrap grant")
        }
        return value
    }
}

/// Supplied only by the bounded exact-source resolver. The repository validates
/// the returned packet against its frozen acceptance before recording proof.
struct ContinuityBootstrapReadResult: Sendable, Equatable {
    let canonicalToolResultJSON: Data
    init(canonicalToolResultJSON: Data) throws {
        guard !canonicalToolResultJSON.isEmpty, canonicalToolResultJSON.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: canonicalToolResultJSON) as? [String: Any],
              try ForgeJSONCanonicalizationV1.data(from: object) == canonicalToolResultJSON else {
            throw ContinuityIngressError.invalidRequest("canonical bootstrap tool result")
        }
        self.canonicalToolResultJSON = canonicalToolResultJSON
    }

    func verifiedPayload(source: ContinuityHandoffRevision, maximumBytes: Int) throws -> Data {
        guard canonicalToolResultJSON.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: canonicalToolResultJSON) as? [String: Any],
              Set(object.keys) == ["ok", "is_error", "payload"],
              let payload = object["payload"] as? [String: Any],
              Set(payload.keys) == ["ok", "found", "packet", "continuity_id", "revision", "packet_sha256"],
              let packet = payload["packet"] as? [String: Any],
              try ForgeJSONCanonicalizationV1.data(from: packet) == source.canonicalPacketJSON else {
            throw ContinuityIngressError.integrityFailure("bootstrap read did not return the exact committed packet")
        }
        // Reconstruct the whole expected wire object, so Boolean coercion,
        // aliases, extra fields and a conflicting identity all fail closed.
        let expectedPayload: [String: Any] = ["ok": true, "found": true, "packet": packet,
            "continuity_id": source.identity.continuityID, "revision": source.identity.revision,
            "packet_sha256": source.identity.packetSHA256]
        let expected = try ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false, "payload": expectedPayload])
        guard expected == canonicalToolResultJSON else {
            throw ContinuityIngressError.integrityFailure("bootstrap result identity or success differs")
        }
        return try ForgeJSONCanonicalizationV1.data(from: expectedPayload)
    }
}

struct ContinuityBootstrapRetrievalProof: Sendable, Equatable {
    static let maximumStoredBytes = 96 * 1_024
    let grantID: UUID
    let candidateID: UUID
    let operationID: UUID
    let runID: RunID
    let sourceIdentity: ContinuityHandoffIdentity
    let bootstrapNonce: UUID
    let handoffSHA256: String
    let providerTurnID: UUID
    let providerResponseID: String
    let providerCallID: String
    let toolInvocationID: UUID
    let canonicalToolResultJSON: Data
    let canonicalPayloadJSON: Data
    let toolResultSHA256: String
    let payloadOutputSHA256: String
    let retrievedAt: String
    let canonicalProofJSON: Data
    let proofSHA256: String

    init(grant: ContinuityBootstrapGrant, providerTurnID: UUID, providerResponseID: String,
         providerCallID: String, toolInvocationID: UUID, result: ContinuityBootstrapReadResult,
         retrievedAt: String) throws {
        let payload = try result.verifiedPayload(source: grant.envelope.acceptance.source, maximumBytes: grant.maximumOutputBytes)
        guard [providerResponseID, providerCallID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 && !$0.contains("\0") }),
              retrievedAt.utf8.count <= 128, ISO8601.date(from: retrievedAt) != nil else {
            throw ContinuityIngressError.invalidRequest("bootstrap retrieval correlation")
        }
        grantID = grant.grantID; candidateID = grant.candidateID; operationID = grant.envelope.operationID
        runID = grant.envelope.runID; sourceIdentity = grant.envelope.sourceIdentity
        bootstrapNonce = grant.envelope.bootstrapNonce; handoffSHA256 = grant.envelope.envelopeSHA256
        self.providerTurnID = providerTurnID; self.providerResponseID = providerResponseID
        self.providerCallID = providerCallID; self.toolInvocationID = toolInvocationID
        canonicalToolResultJSON = result.canonicalToolResultJSON; canonicalPayloadJSON = payload
        toolResultSHA256 = JSONSupport.sha256Hex(canonicalToolResultJSON)
        payloadOutputSHA256 = JSONSupport.sha256Hex(payload); self.retrievedAt = retrievedAt
        let data = try ForgeJSONCanonicalizationV1.data(from: [
            "schema_version": 1, "grant_id": grantID.uuidString.lowercased(),
            "candidate_id": candidateID.uuidString.lowercased(), "operation_id": operationID.uuidString.lowercased(),
            "run_id": runID.description, "continuity_id": sourceIdentity.continuityID, "revision": sourceIdentity.revision,
            "packet_sha256": sourceIdentity.packetSHA256, "bootstrap_nonce": bootstrapNonce.uuidString.lowercased(),
            "handoff_sha256": handoffSHA256, "provider_turn_id": providerTurnID.uuidString.lowercased(),
            "provider_response_id": providerResponseID, "provider_call_id": providerCallID,
            "tool_invocation_id": toolInvocationID.uuidString.lowercased(),
            "tool_result_base64": canonicalToolResultJSON.base64EncodedString(),
            "tool_result_sha256": toolResultSHA256, "payload_output_sha256": payloadOutputSHA256, "retrieved_at": retrievedAt,
        ])
        guard data.count <= Self.maximumStoredBytes else { throw ContinuityIngressError.capacityExceeded("retrieval proof bytes") }
        canonicalProofJSON = data; proofSHA256 = JSONSupport.sha256Hex(data)
    }

    static func storedSnapshot(from data: Data, grant: ContinuityBootstrapGrant) throws -> Self {
        guard data.count <= maximumStoredBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let turn = (object["provider_turn_id"] as? String).flatMap(UUID.init(uuidString:)),
              let response = object["provider_response_id"] as? String, let call = object["provider_call_id"] as? String,
              let invocation = (object["tool_invocation_id"] as? String).flatMap(UUID.init(uuidString:)),
              let base64 = object["tool_result_base64"] as? String, let result = Data(base64Encoded: base64),
              let timestamp = object["retrieved_at"] as? String else {
            throw ContinuityIngressError.integrityFailure("malformed bootstrap retrieval proof")
        }
        let proof = try Self(grant: grant, providerTurnID: turn, providerResponseID: response,
            providerCallID: call, toolInvocationID: invocation,
            result: ContinuityBootstrapReadResult(canonicalToolResultJSON: result), retrievedAt: timestamp)
        guard proof.canonicalProofJSON == data else { throw ContinuityIngressError.integrityFailure("noncanonical retrieval proof") }
        return proof
    }
}

// ContinuityIngressAcceptanceModels.swift
// Durable acceptance proves persistence, never permission to execute a successor.

import Foundation

struct ContinuityIngressAcceptanceReceipt: Sendable, Equatable {
    static let maximumBytes = 384 * 1_024
    let operationID: UUID
    let keySHA256: String
    let runID: RunID
    let source: ContinuityHandoffRevision
    let policySelection: BudgetPolicySelection
    let acceptedAt: String
    let canonicalReceiptJSON: Data
    let receiptSHA256: String

    var sourceIdentity: ContinuityHandoffIdentity { source.identity }
    var authorization: ContinuityIngressAuthorization { source.authorization }

    init(source: ContinuityHandoffRevision, operationID: UUID, runID: RunID,
         policySelection: BudgetPolicySelection, acceptedAt: String) throws {
        let identity = try ContinuityIngressOperationIdentity(revision: source)
        guard identity.operationID == operationID, source.resumeReady,
              !source.committedAt.isEmpty, source.committedAt.utf8.count <= 128,
              ISO8601.date(from: source.committedAt) != nil,
              !acceptedAt.isEmpty, acceptedAt.utf8.count <= 128,
              ISO8601.date(from: acceptedAt) != nil else {
            throw ContinuityIngressError.invalidRequest("acceptance_identity")
        }
        try Self.validatePolicy(policySelection, authorization: source.authorization)
        let data = try ForgeJSONCanonicalizationV1.data(from: [
            "schema_version": 1, "operation_id": operationID.uuidString.lowercased(),
            "key_sha256": identity.keySHA256, "run_id": runID.description,
            "continuity_id": source.identity.continuityID, "revision": source.identity.revision,
            "packet_sha256": source.identity.packetSHA256,
            "packet": JSONSerialization.jsonObject(with: source.canonicalPacketJSON),
            "authorization": JSONSerialization.jsonObject(with: source.authorization.encodedJSON()),
            "source_committed_at": source.committedAt, "accepted_at": acceptedAt,
            "policy_selection": JSONSerialization.jsonObject(with: JSONEncoder().encode(policySelection)),
            "admission_state": "awaiting_bootstrap",
        ])
        guard data.count <= Self.maximumBytes else {
            throw ContinuityIngressError.capacityExceeded("acceptance receipt bytes")
        }
        self.operationID = operationID
        self.keySHA256 = identity.keySHA256
        self.runID = runID
        self.source = source
        self.policySelection = policySelection
        self.acceptedAt = acceptedAt
        self.canonicalReceiptJSON = data
        self.receiptSHA256 = JSONSupport.sha256Hex(data)
    }

    static func storedSnapshot(from data: Data) throws -> Self {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schema_version", "operation_id", "key_sha256", "run_id", "continuity_id",
                  "revision", "packet_sha256", "packet", "authorization", "source_committed_at",
                  "accepted_at", "policy_selection", "admission_state"],
              JSONSupport.exactInteger(object["schema_version"]) == 1,
              object["admission_state"] as? String == "awaiting_bootstrap",
              let operation = (object["operation_id"] as? String).flatMap(UUID.init(uuidString:)),
              let run = (object["run_id"] as? String).flatMap(UUID.init(uuidString:)),
              let key = object["key_sha256"] as? String, let id = object["continuity_id"] as? String,
              let revision = JSONSupport.exactInteger(object["revision"]), revision > 0,
              let packetSHA = object["packet_sha256"] as? String,
              let packet = object["packet"] as? [String: Any],
              let authorization = object["authorization"] as? [String: Any],
              let committed = object["source_committed_at"] as? String,
              let accepted = object["accepted_at"] as? String,
              let policy = object["policy_selection"] as? [String: Any] else {
            throw ContinuityIngressError.integrityFailure("malformed acceptance receipt")
        }
        let source = try ContinuityHandoffRevision(
            identity: ContinuityHandoffIdentity(continuityID: id, revision: Int64(revision), packetSHA256: packetSHA),
            authorization: ContinuityIngressAuthorization.storedSnapshot(from: ForgeJSONCanonicalizationV1.data(from: authorization)),
            canonicalPacketJSON: ForgeJSONCanonicalizationV1.data(from: packet), resumeReady: true, committedAt: committed)
        let value = try Self(source: source, operationID: operation, runID: RunID(run),
            policySelection: JSONDecoder().decode(BudgetPolicySelection.self, from: ForgeJSONCanonicalizationV1.data(from: policy)),
            acceptedAt: accepted)
        guard value.keySHA256 == key, value.canonicalReceiptJSON == data else {
            throw ContinuityIngressError.integrityFailure("noncanonical acceptance receipt")
        }
        return value
    }

    static func validatePolicy(_ selection: BudgetPolicySelection, authorization: ContinuityIngressAuthorization) throws {
        _ = try selection.scope.validated()
        _ = try selection.policy.validated()
        guard selection.revision >= 0, selection.revision < Int.max,
              selection.globalRevision > 0, selection.globalRevision < Int.max else {
            throw ContinuityIngressError.invalidRequest("policy_revision")
        }
        switch selection.scope.kind {
        case .globalDefault:
            guard selection.revision == selection.globalRevision, !selection.inherited else {
                throw ContinuityIngressError.invalidRequest("global_policy_selection")
            }
        case .projectOverride:
            guard selection.scope.projectID == authorization.projectID.description,
                  selection.scope.projectGeneration == Int(authorization.projectGeneration.rawValue),
                  selection.revision > 0 || selection.inherited else {
                throw ContinuityIngressError.authorityMismatch
            }
        }
    }
}

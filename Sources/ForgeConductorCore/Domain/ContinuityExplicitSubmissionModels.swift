// Exact-ID submission data. Native correlation supplies authority separately.

import Foundation

struct ContinuityExplicitHandoffRequest: Sendable, Equatable {
    let continuityID: String
    let idempotencyKey: String?
    let reason: String?

    init(arguments: [String: Any]) throws {
        guard Set(arguments.keys).isSubset(of: ["continuity_id", "idempotency_key", "reason"]),
              let continuityID = arguments["continuity_id"] as? String,
              ContinuityIngressLimits.validHandoffID(continuityID) else {
            throw ContinuityIngressError.invalidRequest("continuity_id_or_unknown_field")
        }
        func optionalText(_ key: String, maximum: Int) throws -> String? {
            guard let raw = arguments[key] else { return nil }
            guard let value = raw as? String, !value.isEmpty, value.utf8.count <= maximum,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ContinuityIngressError.invalidRequest(key)
            }
            return value
        }
        self.continuityID = continuityID
        idempotencyKey = try optionalText("idempotency_key", maximum: 256)
        reason = try optionalText("reason", maximum: 512)
    }

    /// A key belongs to one native task and request kind. The repository checks
    /// the requested handoff before returning its previously frozen revision.
    func requestID(taskID: UUID, projectID: ProjectID, generation: ProjectGeneration) throws -> UUID {
        guard let idempotencyKey else { return UUID() }
        let digest = try ForgeJSONCanonicalizationV1.sha256Hex(of: [
            "kind": "explicit_source_handoff", "task_id": taskID.uuidString.lowercased(),
            "project_id": projectID.description, "project_generation": generation.rawValue,
            "idempotency_key": idempotencyKey,
        ])
        let value = String(digest.prefix(32))
        let formatted = "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-\(value.dropFirst(20))"
        guard let identifier = UUID(uuidString: formatted) else {
            throw ContinuityIngressError.integrityFailure("explicit request identity")
        }
        return identifier
    }
}

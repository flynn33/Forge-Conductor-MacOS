// ContinuityIngressModels.swift
// Immutable source handoff revisions and bounded delivery contracts.

import Foundation

public enum ContinuityIngressError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case authorityMismatch
    case invalidated
    case notFound
    case capacityExceeded(String)
    case deliveryConflict
    case integrityFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let field): "Invalid continuity ingress field: \(field)"
        case .authorityMismatch: "Handoff authority does not match its immutable source binding"
        case .invalidated: "Handoff authority was invalidated by project or task maintenance"
        case .notFound: "The exact immutable handoff or delivery was not found"
        case .capacityExceeded(let boundary): "Continuity ingress capacity exceeded: \(boundary)"
        case .deliveryConflict: "Continuity delivery ownership or state changed"
        case .integrityFailure(let reason): "Continuity ingress integrity failure: \(reason)"
        }
    }
}

public enum ContinuityIngressLimits {
    public static let maximumPacketBytes = 256 * 1_024
    public static let maximumAuthorizationBytes = 32 * 1_024
    public static let maximumRevisions = 1_024
    public static let maximumPendingDeliveries = 256
    public static let maximumQueryRows = 32
    public static let maximumAttempts = 8
    public static let maximumInvalidations = 1_024
    public static let maximumLeaseSeconds: TimeInterval = 60
    public static let maximumRetryDelaySeconds: TimeInterval = 3_600

    static func validHandoffID(_ id: String) -> Bool {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return !id.isEmpty && id.utf8.count <= 128 && id != "." && id != ".."
            && id.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

/// Minted only by the native authorization boundary, never decoded from tool
/// arguments. This value is a frozen authorization snapshot, not a substitute
/// for checking current lifecycle, task binding, assignment and policy at admission.
/// `sourceBindingID` identifies the original durable task binding; switching an
/// MCP transport must not substitute a new transport-client binding here.
public struct ContinuityIngressAuthorization: Sendable, Equatable {
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let sourceBindingID: UUID
    public let taskID: UUID
    public let assignmentID: String
    public let assignmentSHA256: String
    public let authorizationScope: ToolAuthorizationScope

    init(
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        sourceBindingID: UUID,
        taskID: UUID,
        assignmentID: String,
        assignmentSHA256: String,
        authorizationScope: ToolAuthorizationScope
    ) throws {
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.sourceBindingID = sourceBindingID
        self.taskID = taskID
        self.assignmentID = assignmentID
        self.assignmentSHA256 = assignmentSHA256
        self.authorizationScope = authorizationScope
        try validate()
    }

    func validate() throws {
        guard projectGeneration.rawValue > 0,
              projectGeneration.rawValue <= UInt64(Int64.max) else {
            throw ContinuityIngressError.invalidRequest("project_generation")
        }
        guard !assignmentID.isEmpty, assignmentID.utf8.count <= 1_024,
              assignmentID == assignmentID.trimmingCharacters(in: .whitespacesAndNewlines),
              !assignmentID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              ContinuityIngressLimits.validSHA256(assignmentSHA256) else {
            throw ContinuityIngressError.invalidRequest("assignment")
        }
        let scope = authorizationScope
        guard !scope.canonicalRoots.isEmpty, scope.canonicalRoots.count <= 32,
              scope.writableRoots.count <= 32, scope.allowedTools.count <= 128,
              (1...ContinuityIngressLimits.maximumPacketBytes).contains(scope.maximumInlineOutputBytes),
              scope.allowedTools.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 128
                    && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }),
              (scope.canonicalRoots + scope.writableRoots).allSatisfy({
                  $0.isFileURL && $0.path.hasPrefix("/") && $0.path != "/"
                    && $0.path.utf8.count <= 4_096 && $0 == $0.standardizedFileURL
              }),
              scope.writableRoots.allSatisfy({ writable in
                  scope.canonicalRoots.contains { readable in
                      writable.path == readable.path || writable.path.hasPrefix(readable.path + "/")
                  }
              }) else {
            throw ContinuityIngressError.invalidRequest("authorization_scope")
        }
        guard try encodedJSON().count <= ContinuityIngressLimits.maximumAuthorizationBytes else {
            throw ContinuityIngressError.capacityExceeded("authorization bytes")
        }
    }

    func encodedJSON() throws -> Data {
        try ForgeJSONCanonicalizationV1.data(from: [
            "project_id": projectID.description,
            "project_generation": projectGeneration.rawValue,
            "source_binding_id": sourceBindingID.uuidString.lowercased(),
            "task_id": taskID.uuidString.lowercased(),
            "assignment_id": assignmentID,
            "assignment_sha256": assignmentSHA256,
            "authorization_scope": [
                "canonical_roots": authorizationScope.canonicalRoots.map(\.path),
                "writable_roots": authorizationScope.writableRoots.map(\.path),
                "allowed_tools": authorizationScope.allowedTools.sorted(),
                "network_allowed": authorizationScope.networkAllowed,
                "maximum_inline_output_bytes": authorizationScope.maximumInlineOutputBytes,
            ],
        ])
    }

    static func storedSnapshot(from data: Data) throws -> Self {
        guard data.count <= ContinuityIngressLimits.maximumAuthorizationBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["project_id", "project_generation", "source_binding_id",
                                  "task_id", "assignment_id", "assignment_sha256", "authorization_scope"],
              let project = (object["project_id"] as? String).flatMap(UUID.init(uuidString:)),
              let generation = JSONSupport.exactInteger(object["project_generation"]), generation > 0,
              let binding = (object["source_binding_id"] as? String).flatMap(UUID.init(uuidString:)),
              let task = (object["task_id"] as? String).flatMap(UUID.init(uuidString:)),
              let assignment = object["assignment_id"] as? String,
              let digest = object["assignment_sha256"] as? String,
              let scope = object["authorization_scope"] as? [String: Any],
              Set(scope.keys) == ["canonical_roots", "writable_roots", "allowed_tools",
                                 "network_allowed", "maximum_inline_output_bytes"],
              let roots = scope["canonical_roots"] as? [String],
              let writable = scope["writable_roots"] as? [String],
              let tools = scope["allowed_tools"] as? [String],
              let network = scope["network_allowed"] as? Bool,
              let maximum = JSONSupport.exactInteger(scope["maximum_inline_output_bytes"]) else {
            throw ContinuityIngressError.integrityFailure("stored authorization is malformed")
        }
        let value = try Self(
            projectID: ProjectID(project), projectGeneration: ProjectGeneration(UInt64(generation)),
            sourceBindingID: binding, taskID: task, assignmentID: assignment,
            assignmentSHA256: digest,
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: roots.map { URL(fileURLWithPath: $0) },
                writableRoots: writable.map { URL(fileURLWithPath: $0) },
                allowedTools: Set(tools), networkAllowed: network,
                maximumInlineOutputBytes: maximum
            )
        )
        guard try value.encodedJSON() == data else {
            throw ContinuityIngressError.integrityFailure("authorization is not canonical")
        }
        return value
    }
}

public struct ContinuityHandoffIdentity: Sendable, Equatable {
    public let continuityID: String
    public let revision: Int64
    public let packetSHA256: String

    public init(continuityID: String, revision: Int64, packetSHA256: String) throws {
        guard ContinuityIngressLimits.validHandoffID(continuityID), revision > 0,
              ContinuityIngressLimits.validSHA256(packetSHA256) else {
            throw ContinuityIngressError.invalidRequest("immutable_handoff_identity")
        }
        self.continuityID = continuityID
        self.revision = revision
        self.packetSHA256 = packetSHA256
    }
}

public struct ContinuityHandoffRevision: Sendable, Equatable {
    public let identity: ContinuityHandoffIdentity
    public let authorization: ContinuityIngressAuthorization
    public let canonicalPacketJSON: Data
    public let resumeReady: Bool
    public let committedAt: String
}

/// Shared source/control-plane identity calculation. Structural validation and a
/// matching digest do not authorize a task; admission still resolves the live
/// server-owned assignment before looking up or returning a duplicate operation.
struct ContinuityIngressOperationIdentity: Sendable, Equatable {
    let operationID: UUID
    let keySHA256: String

    init(revision: ContinuityHandoffRevision) throws {
        try revision.authorization.validate()
        guard revision.resumeReady else {
            throw ContinuityIngressError.invalidRequest("handoff_is_not_resume_ready")
        }
        guard !revision.canonicalPacketJSON.isEmpty,
              revision.canonicalPacketJSON.count <= ContinuityIngressLimits.maximumPacketBytes else {
            throw ContinuityIngressError.capacityExceeded("packet bytes")
        }
        guard JSONSupport.sha256Hex(revision.canonicalPacketJSON) == revision.identity.packetSHA256,
              let object = try JSONSerialization.jsonObject(with: revision.canonicalPacketJSON) as? [String: Any],
              let packet = HandoffPacket.fromDictionary(object),
              packet.id == revision.identity.continuityID, packet.resumeReady,
              try ForgeJSONCanonicalizationV1.data(from: packet.asDictionary()) == revision.canonicalPacketJSON else {
            throw ContinuityIngressError.integrityFailure("immutable handoff content changed")
        }
        let digest = try ForgeJSONCanonicalizationV1.sha256Hex(of: [
            "kind": "resume_ready_handoff_v1",
            "continuity_id": revision.identity.continuityID,
            "revision": revision.identity.revision,
            "packet_sha256": revision.identity.packetSHA256,
            "authorization_sha256": JSONSupport.sha256Hex(try revision.authorization.encodedJSON()),
        ])
        // Preserve the original source operation derivation byte-for-byte. This
        // local identity does not assert remote-provider request idempotency.
        let bytes = Array(digest.utf8.prefix(32))
        let raw = String(decoding: bytes[0..<8], as: UTF8.self) + "-"
            + String(decoding: bytes[8..<12], as: UTF8.self) + "-"
            + String(decoding: bytes[12..<16], as: UTF8.self) + "-"
            + String(decoding: bytes[16..<20], as: UTF8.self) + "-"
            + String(decoding: bytes[20..<32], as: UTF8.self)
        guard let identifier = UUID(uuidString: raw) else {
            throw ContinuityIngressError.integrityFailure("operation identity could not be encoded")
        }
        operationID = identifier
        keySHA256 = digest
    }
}

public enum ContinuityDeliveryState: String, Sendable, CaseIterable {
    case pending, claimed, acknowledged, blocked, invalidated
}

public struct ContinuityHandoffDelivery: Sendable, Equatable {
    public let operationID: UUID
    public let handoff: ContinuityHandoffRevision
    public let explicitlyRequested: Bool
    public let state: ContinuityDeliveryState
    public let attempts: Int
    public let nextAttemptAt: String
    public let leaseOwner: String?
    public let leaseToken: UUID?
    public let leaseExpiresAt: String?
    public let lastErrorCode: String?
    public let acceptanceReceiptSHA256: String?
    public let acknowledgedAt: String?
}

public struct ContinuityHandoffCommit: Sendable, Equatable {
    public let revision: ContinuityHandoffRevision
    public let delivery: ContinuityHandoffDelivery?
}

/// A claim proves local delivery ownership only. The manager must durably accept
/// the same operation and immutable handoff before acknowledging this source row.
public struct ContinuityDeliveryClaim: Sendable, Equatable {
    public let delivery: ContinuityHandoffDelivery
    public let owner: String
    public let token: UUID
}

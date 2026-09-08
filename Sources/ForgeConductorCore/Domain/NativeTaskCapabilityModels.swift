import Foundation

public enum NativeTaskCapabilityError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest(String), unsupportedProfile, credentialRejected, requestConflict, epochConflict
    case capabilityRevoked, capacityExceeded, integrityFailure, operationBusy, resultExpired, sourceFenced, budgetExceeded
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "Invalid native task request"
        case .unsupportedProfile: "Unsupported native task profile"
        case .credentialRejected: "Native task credential was rejected"
        case .requestConflict: "Native request identity conflicts with its retained request"
        case .epochConflict: "Native task credential epoch changed"
        case .capabilityRevoked: "Native task capability is permanently revoked"
        case .capacityExceeded: "Native task bounded storage is full"
        case .integrityFailure: "Native task retained evidence is invalid"
        case .operationBusy: "A native source request is already pending"
        case .resultExpired: "The retained source result has expired"
        case .sourceFenced: "Source work is fenced by an existing handoff"
        case .budgetExceeded: "Native source work exceeds the current budget"
        }
    }
}

public struct NativeTaskSourceLimits: Sendable, Equatable, Codable {
    public let maximumCalls: Int
    public let maximumResultBytes: Int
    public let maximumRequestSeconds: Int
    public init(maximumCalls: Int, maximumResultBytes: Int, maximumRequestSeconds: Int) throws {
        guard (1...64).contains(maximumCalls), (1...65_536).contains(maximumResultBytes),
              (1...60).contains(maximumRequestSeconds) else { throw NativeTaskCapabilityError.invalidRequest("source_limits") }
        self.maximumCalls = maximumCalls; self.maximumResultBytes = maximumResultBytes
        self.maximumRequestSeconds = maximumRequestSeconds
    }
    public var wireObject: [String: Any] { ["maximum_calls": maximumCalls, "maximum_result_bytes": maximumResultBytes,
        "maximum_request_seconds": maximumRequestSeconds] }
    enum CodingKeys: String, CodingKey {
        case maximumCalls = "maximum_calls", maximumResultBytes = "maximum_result_bytes", maximumRequestSeconds = "maximum_request_seconds"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(maximumCalls: c.decode(Int.self, forKey: .maximumCalls),
            maximumResultBytes: c.decode(Int.self, forKey: .maximumResultBytes),
            maximumRequestSeconds: c.decode(Int.self, forKey: .maximumRequestSeconds))
    }
}

public struct NativeTaskCapabilityVerifier: Sendable, Equatable {
    public let capabilityID: UUID
    public let epoch: Int64
    public let sha256: String
    public init(capabilityID: UUID, epoch: Int64, sha256: String) throws {
        guard epoch > 0, ContinuityIngressLimits.validSHA256(sha256) else { throw NativeTaskCapabilityError.invalidRequest("verifier") }
        self.capabilityID = capabilityID; self.epoch = epoch; self.sha256 = sha256
    }
}

/// Secret-bearing values have no Codable, debug description or automatic wire conversion.
public struct NativeTaskCapabilityCredential: Sendable {
    public let capabilityID: UUID
    public let epoch: Int64
    private let secret: Data
    public init(capabilityID: UUID, epoch: Int64, secret: Data) throws {
        guard epoch > 0, secret.count == 32 else { throw NativeTaskCapabilityError.credentialRejected }
        self.capabilityID = capabilityID; self.epoch = epoch; self.secret = secret
    }
    public init(authorizationValue: String) throws {
        guard authorizationValue.utf8.count <= 160 else { throw NativeTaskCapabilityError.credentialRejected }
        let p = authorizationValue.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 4, p[0] == "fc-task-v1", let id = UUID(uuidString: p[1]), id.uuidString.lowercased() == p[1],
              let epoch = Int64(p[2]), epoch > 0, String(epoch) == p[2], ContinuityIngressLimits.validSHA256(p[3]) else {
            throw NativeTaskCapabilityError.credentialRejected
        }
        var bytes = Data(); bytes.reserveCapacity(32)
        for i in stride(from: 0, to: 64, by: 2) {
            let start = p[3].index(p[3].startIndex, offsetBy: i), end = p[3].index(start, offsetBy: 2)
            guard let byte = UInt8(p[3][start..<end], radix: 16) else { throw NativeTaskCapabilityError.credentialRejected }
            bytes.append(byte)
        }
        try self.init(capabilityID: id, epoch: epoch, secret: bytes)
    }
    public var authorizationValue: String {
        "fc-task-v1:\(capabilityID.uuidString.lowercased()):\(epoch):" + secret.map { String(format: "%02x", $0) }.joined()
    }
    public var verifier: NativeTaskCapabilityVerifier {
        var bytes = Data("forge.continuity.task-credential.v1\0\(capabilityID.uuidString.lowercased())\0\(epoch)\0".utf8)
        bytes.append(secret)
        // Construction already checked the epoch and SHA256 always yields the required shape.
        return try! NativeTaskCapabilityVerifier(capabilityID: capabilityID, epoch: epoch, sha256: JSONSupport.sha256Hex(bytes))
    }
}

public struct NativeTaskCapabilityDescriptor: Sendable, Equatable {
    public enum State: String, Sendable { case active, expired, revoked }
    public let taskID: UUID
    public let capabilityID: UUID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let epoch: Int64
    public let state: State
    public let profileID: String
    public let profileVersion: Int
    public let approvalSHA256: String
    public let scopeSHA256: String
    public let originalCallerBindingID: UUID
    public let sourceBindingID: UUID
    public let expiresAt: String
    public let issuedAt: String
    public let revokedAt: String?
    public var wireObject: [String: Any] {
        ["task_id": taskID.uuidString.lowercased(), "capability_id": capabilityID.uuidString.lowercased(),
         "project_id": projectID.description, "project_generation": projectGeneration.rawValue, "epoch": epoch,
         "state": state.rawValue, "profile_id": profileID, "profile_version": profileVersion,
         "approval_sha256": approvalSHA256, "scope_sha256": scopeSHA256,
         "original_caller_binding_id": originalCallerBindingID.uuidString.lowercased(),
         "source_binding_id": sourceBindingID.uuidString.lowercased(), "expires_at": expiresAt,
         "issued_at": issuedAt, "revoked_at": revokedAt as Any? ?? NSNull()]
    }
    public var canonicalJSON: Data { get throws { try ForgeJSONCanonicalizationV1.data(from: wireObject) } }
    public init(arguments o: [String: Any]) throws {
        guard Set(o.keys) == ["task_id","capability_id","project_id","project_generation","epoch","state","profile_id","profile_version",
            "approval_sha256","scope_sha256","original_caller_binding_id","source_binding_id","expires_at","issued_at","revoked_at"],
            let s = o["state"] as? String, let state = State(rawValue: s),
            o["profile_id"] as? String == "forge.native-task-source", JSONSupport.exactInteger(o["profile_version"]) == 1,
            let generation = JSONSupport.exactInteger(o["project_generation"]), generation > 0,
            let epoch = JSONSupport.exactInteger(o["epoch"]), epoch > 0 else { throw NativeTaskCapabilityError.integrityFailure }
        taskID = try NativeTaskValue.uuid(o["task_id"]); capabilityID = try NativeTaskValue.uuid(o["capability_id"])
        projectID = ProjectID(try NativeTaskValue.uuid(o["project_id"])); projectGeneration = .init(UInt64(generation))
        self.epoch = Int64(epoch); self.state = state; profileID = "forge.native-task-source"; profileVersion = 1
        approvalSHA256 = try NativeTaskValue.sha(o["approval_sha256"]); scopeSHA256 = try NativeTaskValue.sha(o["scope_sha256"])
        originalCallerBindingID = try NativeTaskValue.uuid(o["original_caller_binding_id"]); sourceBindingID = try NativeTaskValue.uuid(o["source_binding_id"])
        expiresAt = try NativeTaskValue.date(o["expires_at"]); issuedAt = try NativeTaskValue.date(o["issued_at"])
        revokedAt = o["revoked_at"] is NSNull ? nil : try NativeTaskValue.date(o["revoked_at"])
        guard (state == .revoked) == (revokedAt != nil) else { throw NativeTaskCapabilityError.integrityFailure }
    }
}

public struct NativeTaskCapabilityCommandReceipt: Sendable, Equatable {
    public static let maximumStoredBytes = 8_192
    public let requestID: UUID
    public let action: String
    public let requestSHA256: String
    public let taskID: UUID
    public let capabilityID: UUID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let priorEpoch: Int64?
    public let resultEpoch: Int64
    public let resultState: String
    public let profileID: String
    public let profileVersion: Int
    public let approvalSHA256: String
    public let scopeSHA256: String
    public let documentSHA256: String
    public let verifierSHA256: String?
    public let expiresAt: String?
    public let recordedAt: String
    public let canonicalReceiptJSON: Data
    public let receiptSHA256: String
    public var wireObject: [String: Any] { (try? JSONSerialization.jsonObject(with: canonicalReceiptJSON) as? [String: Any]) ?? [:] }
    init(requestID: UUID, action: String, requestSHA256: String, descriptor: NativeTaskCapabilityDescriptor,
         priorEpoch: Int64?, documentSHA256: String, verifierSHA256: String?, recordedAt: String) throws {
        var o: [String: Any] = ["schema_version": 1, "request_id": requestID.uuidString.lowercased(), "action": action,
            "request_sha256": requestSHA256, "task_id": descriptor.taskID.uuidString.lowercased(),
            "capability_id": descriptor.capabilityID.uuidString.lowercased(), "project_id": descriptor.projectID.description,
            "project_generation": descriptor.projectGeneration.rawValue, "prior_epoch": priorEpoch as Any? ?? NSNull(),
            "result_epoch": descriptor.epoch, "result_state": descriptor.state.rawValue,
            "profile_id": descriptor.profileID, "profile_version": descriptor.profileVersion,
            "approval_sha256": descriptor.approvalSHA256, "scope_sha256": descriptor.scopeSHA256,
            "document_sha256": documentSHA256, "verifier_sha256": verifierSHA256 as Any? ?? NSNull(),
            "expires_at": action == "revoke" ? NSNull() : descriptor.expiresAt as Any, "recorded_at": recordedAt]
        let bytes = try ForgeJSONCanonicalizationV1.data(from: o)
        o["receipt_sha256"] = JSONSupport.sha256Hex(Data("forge.continuity.task-command-receipt.v1\0".utf8) + bytes)
        try self.init(arguments: o)
    }
    public init(arguments o: [String: Any]) throws {
        guard Set(o.keys) == ["schema_version","request_id","action","request_sha256","task_id","capability_id","project_id",
            "project_generation","prior_epoch","result_epoch","result_state","profile_id","profile_version","approval_sha256",
            "scope_sha256","document_sha256","verifier_sha256","expires_at","recorded_at","receipt_sha256"],
            JSONSupport.exactInteger(o["schema_version"]) == 1, let action = o["action"] as? String,
            ["prepare","rotate","revoke"].contains(action), let state = o["result_state"] as? String,
            state == (action == "revoke" ? "revoked" : "active"), let epoch = JSONSupport.exactInteger(o["result_epoch"]), epoch > 0,
            let generation = JSONSupport.exactInteger(o["project_generation"]), generation > 0,
            o["profile_id"] as? String == "forge.native-task-source", JSONSupport.exactInteger(o["profile_version"]) == 1 else {
            throw NativeTaskCapabilityError.integrityFailure
        }
        requestID = try NativeTaskValue.uuid(o["request_id"]); taskID = try NativeTaskValue.uuid(o["task_id"])
        capabilityID = try NativeTaskValue.uuid(o["capability_id"]); projectID = ProjectID(try NativeTaskValue.uuid(o["project_id"]))
        projectGeneration = .init(UInt64(generation)); self.action = action; resultState = state; resultEpoch = Int64(epoch)
        priorEpoch = o["prior_epoch"] is NSNull ? nil : JSONSupport.exactInteger(o["prior_epoch"]).map(Int64.init)
        guard action == "prepare" ? (priorEpoch == nil && resultEpoch == 1)
            : (priorEpoch != nil && priorEpoch! > 0 && priorEpoch! < Int64.max && resultEpoch == priorEpoch! + 1) else {
            throw NativeTaskCapabilityError.integrityFailure
        }
        profileID = "forge.native-task-source"; profileVersion = 1
        requestSHA256 = try NativeTaskValue.sha(o["request_sha256"]); approvalSHA256 = try NativeTaskValue.sha(o["approval_sha256"])
        scopeSHA256 = try NativeTaskValue.sha(o["scope_sha256"]); documentSHA256 = try NativeTaskValue.sha(o["document_sha256"])
        verifierSHA256 = o["verifier_sha256"] is NSNull ? nil : try NativeTaskValue.sha(o["verifier_sha256"])
        expiresAt = o["expires_at"] is NSNull ? nil : try NativeTaskValue.date(o["expires_at"])
        guard (action == "revoke") == (verifierSHA256 == nil && expiresAt == nil),
              action == "revoke" || (verifierSHA256 != nil && expiresAt != nil) else { throw NativeTaskCapabilityError.integrityFailure }
        recordedAt = try NativeTaskValue.date(o["recorded_at"]); receiptSHA256 = try NativeTaskValue.sha(o["receipt_sha256"])
        var unsigned = o; unsigned.removeValue(forKey: "receipt_sha256")
        guard receiptSHA256 == JSONSupport.sha256Hex(Data("forge.continuity.task-command-receipt.v1\0".utf8)
            + (try ForgeJSONCanonicalizationV1.data(from: unsigned))) else { throw NativeTaskCapabilityError.integrityFailure }
        canonicalReceiptJSON = try ForgeJSONCanonicalizationV1.data(from: o)
        guard canonicalReceiptJSON.count <= Self.maximumStoredBytes else { throw NativeTaskCapabilityError.integrityFailure }
    }
}

public struct NativeTaskCapabilityCommandResult: Sendable, Equatable {
    public let receipt: NativeTaskCapabilityCommandReceipt
    public let current: NativeTaskCapabilityDescriptor
    public let replayed: Bool
    public init(receipt: NativeTaskCapabilityCommandReceipt, current: NativeTaskCapabilityDescriptor, replayed: Bool) {
        self.receipt = receipt; self.current = current; self.replayed = replayed
    }
}

struct AuthenticatedContinuityTaskAttachment: Sendable {
    let descriptor: NativeTaskCapabilityDescriptor
    let setup: AuthorizedContinuityTaskSetup
    let sourceLimits: NativeTaskSourceLimits
    var context: ToolInvocationContext { setup.correlation.callerContext }
    var owner: ProjectBindingOwner { setup.correlation.callerOwner }
}

enum NativeTaskValue {
    static func uuid(_ value: Any?) throws -> UUID {
        guard let s = value as? String, s.utf8.count == 36, let id = UUID(uuidString: s), id.uuidString.lowercased() == s else {
            throw NativeTaskCapabilityError.integrityFailure
        }; return id
    }
    static func sha(_ value: Any?) throws -> String {
        guard let s = value as? String, ContinuityIngressLimits.validSHA256(s) else { throw NativeTaskCapabilityError.integrityFailure }; return s
    }
    static func date(_ value: Any?) throws -> String {
        guard let s = value as? String, s.utf8.count == 20, let d = ISO8601DateFormatter().date(from: s), ISO8601.string(from: d) == s else {
            throw NativeTaskCapabilityError.integrityFailure
        }; return s
    }
}

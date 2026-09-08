import Foundation

struct NativeSourceRequestKey: Sendable, Equatable {
    let sessionID: UUID
    let requestIDSHA256: String
    init(sessionID: UUID, requestIDSHA256: String) throws {
        guard ContinuityIngressLimits.validSHA256(requestIDSHA256) else { throw NativeTaskCapabilityError.invalidRequest("request_id") }
        self.sessionID = sessionID; self.requestIDSHA256 = requestIDSHA256
    }
}

struct NativeSourceReadRequest: Sendable, Equatable {
    let key: NativeSourceRequestKey
    let toolName: String
    let canonicalArgumentsJSON: Data
    let argumentsSHA256: String
    let managerInstanceID: UUID
    let requestedDeadlineMilliseconds: Int?
    init(key: NativeSourceRequestKey, toolName: String, canonicalArgumentsJSON: Data, managerInstanceID: UUID) throws {
        guard toolName == "fs_read", !canonicalArgumentsJSON.isEmpty, canonicalArgumentsJSON.count <= 16_384,
              let arguments = try JSONSerialization.jsonObject(with: canonicalArgumentsJSON) as? [String: Any],
              try ForgeJSONCanonicalizationV1.data(from: arguments) == canonicalArgumentsJSON else {
            throw NativeTaskCapabilityError.invalidRequest("source_read")
        }
        self.key = key; self.toolName = toolName; self.canonicalArgumentsJSON = canonicalArgumentsJSON
        argumentsSHA256 = JSONSupport.sha256Hex(canonicalArgumentsJSON); self.managerInstanceID = managerInstanceID
        // Reject malformed deadlines before a durable call debit is reserved.
        requestedDeadlineMilliseconds = try ToolRouter.requestedDeadlineMilliseconds(in: arguments)
    }

    func effectiveDeadlineMilliseconds(limits: NativeTaskSourceLimits) -> Int {
        min(requestedDeadlineMilliseconds ?? 30_000, limits.maximumRequestSeconds * 1_000)
    }
}

/// Issued only after the durable debit transaction. The credential stays inside
/// the manager and is checked again at dispatch, completion and every replay.
struct NativeSourceReadAdmission: Sendable {
    let reservationID: UUID
    let request: NativeSourceReadRequest
    let correlation: VerifiedContinuityTaskCorrelation
    let deadline: String
    let chargedCalls: Int
    var taskID: UUID { correlation.taskID }
}

struct NativeSourceReadReceipt: Sendable, Equatable {
    let reservationID: UUID
    let key: NativeSourceRequestKey
    let taskID: UUID
    let resultSHA256: String
    let canonicalToolResultJSON: Data
    let estimatedResultTokens: Int
    let chargedCalls: Int
    let completedAt: String
}

enum NativeSourceReadAdmissionResult: Sendable {
    case execute(NativeSourceReadAdmission)
    case completed(NativeSourceReadReceipt)
    case inProgress(deadline: String)
}
enum NativeSourceReadUndisclosedOutcome: String, Sendable { case cancelled, failed, withheld }

struct NativeSourceCommitRequest: Sendable, Equatable {
    let key: NativeSourceRequestKey
    let canonicalArgumentsJSON: Data
    let argumentsSHA256: String
    let managerInstanceID: UUID
    let finalize: Bool
    var method: String { finalize ? "session_handoff" : "session_checkpoint" }
    init(key: NativeSourceRequestKey, canonicalArgumentsJSON: Data, managerInstanceID: UUID, finalize: Bool) throws {
        guard !canonicalArgumentsJSON.isEmpty, canonicalArgumentsJSON.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: canonicalArgumentsJSON) as? [String: Any],
              try ForgeJSONCanonicalizationV1.data(from: object) == canonicalArgumentsJSON else {
            throw NativeTaskCapabilityError.invalidRequest("source_commit")
        }
        self.key = key; self.canonicalArgumentsJSON = canonicalArgumentsJSON
        argumentsSHA256 = JSONSupport.sha256Hex(canonicalArgumentsJSON)
        self.managerInstanceID = managerInstanceID; self.finalize = finalize
    }
}

struct NativeSourceCommitAdmission: Sendable {
    let reservationID: UUID
    let request: NativeSourceCommitRequest
    let correlation: VerifiedContinuityTaskCorrelation
    let prepared: PreparedContinuitySourceCommit
    let authorization: ContinuityIngressAuthorization
    let automaticHandoffEnabled: Bool
}
enum NativeSourceCommitAdmissionResult: Sendable {
    case commit(NativeSourceCommitAdmission)
    case completed(ContinuityHandoffCommit)
}

/// Bounded metadata for the existing manager watchdog. It is not authority;
/// reconciliation still verifies the retained intent and current task authority.
struct NativePendingSourceCommitReference: Sendable, Equatable {
    let rowID: Int64
    let reservationID: UUID
    let taskID: UUID
    let capabilityID: UUID
}

enum NativeSourceCommitEvidence {
    static let maximumBytes = 384 * 1_024
    static func encode(_ commit: ContinuityHandoffCommit) throws -> Data {
        let r = commit.revision
        var o: [String: Any] = ["schema_version": 1, "continuity_id": r.identity.continuityID,
            "revision": r.identity.revision, "packet_sha256": r.identity.packetSHA256,
            "packet": try JSONSerialization.jsonObject(with: r.canonicalPacketJSON),
            "authorization": try JSONSerialization.jsonObject(with: r.authorization.encodedJSON()),
            "resume_ready": r.resumeReady, "committed_at": r.committedAt, "delivery": NSNull()]
        if let d = commit.delivery {
            o["delivery"] = ["operation_id": d.operationID.uuidString.lowercased(), "explicitly_requested": d.explicitlyRequested,
                "state": d.state.rawValue, "attempts": d.attempts, "next_attempt_at": d.nextAttemptAt,
                "lease_owner": d.leaseOwner as Any? ?? NSNull(), "lease_token": d.leaseToken?.uuidString.lowercased() as Any? ?? NSNull(),
                "lease_expires_at": d.leaseExpiresAt as Any? ?? NSNull(), "last_error_code": d.lastErrorCode as Any? ?? NSNull(),
                "acceptance_receipt_sha256": d.acceptanceReceiptSHA256 as Any? ?? NSNull(), "acknowledged_at": d.acknowledgedAt as Any? ?? NSNull()]
        }
        let data = try ForgeJSONCanonicalizationV1.data(from: o)
        guard data.count <= maximumBytes else { throw NativeTaskCapabilityError.capacityExceeded }
        return data
    }
    static func decode(_ data: Data, prepared: PreparedContinuitySourceCommit,
                       authorization: ContinuityIngressAuthorization) throws -> ContinuityHandoffCommit {
        guard data.count <= maximumBytes, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(o.keys) == ["schema_version","continuity_id","revision","packet_sha256","packet","authorization","resume_ready","committed_at","delivery"],
              JSONSupport.exactInteger(o["schema_version"]) == 1,
              o["continuity_id"] as? String == prepared.continuityID, o["packet_sha256"] as? String == prepared.packetSHA256,
              let revision = JSONSupport.exactInteger(o["revision"]), revision > 0,
              o["resume_ready"] as? Bool == prepared.finalize,
              let packetObject = o["packet"] as? [String: Any], let authorityObject = o["authorization"] as? [String: Any],
              try ForgeJSONCanonicalizationV1.data(from: packetObject) == prepared.canonicalPacketJSON,
              try ForgeJSONCanonicalizationV1.data(from: authorityObject) == authorization.encodedJSON() else {
            throw NativeTaskCapabilityError.integrityFailure
        }
        let r = ContinuityHandoffRevision(identity: try .init(continuityID: prepared.continuityID, revision: Int64(revision),
            packetSHA256: prepared.packetSHA256), authorization: authorization, canonicalPacketJSON: prepared.canonicalPacketJSON,
            resumeReady: prepared.finalize, committedAt: try NativeTaskValue.date(o["committed_at"]))
        var delivery: ContinuityHandoffDelivery?
        if let d = o["delivery"] as? [String: Any] {
            guard Set(d.keys) == ["operation_id","explicitly_requested","state","attempts","next_attempt_at","lease_owner","lease_token",
                "lease_expires_at","last_error_code","acceptance_receipt_sha256","acknowledged_at"],
                let stateString = d["state"] as? String, let state = ContinuityDeliveryState(rawValue: stateString),
                let explicit = d["explicitly_requested"] as? Bool, let attempts = JSONSupport.exactInteger(d["attempts"]),
                (0...8).contains(attempts) else { throw NativeTaskCapabilityError.integrityFailure }
            let operationID = try NativeTaskValue.uuid(d["operation_id"])
            guard try ContinuityIngressOperationIdentity(revision: r).operationID == operationID else { throw NativeTaskCapabilityError.integrityFailure }
            delivery = .init(operationID: operationID, handoff: r, explicitlyRequested: explicit, state: state, attempts: attempts,
                nextAttemptAt: try NativeTaskValue.date(d["next_attempt_at"]), leaseOwner: d["lease_owner"] as? String,
                leaseToken: d["lease_token"] is NSNull ? nil : try NativeTaskValue.uuid(d["lease_token"]),
                leaseExpiresAt: d["lease_expires_at"] is NSNull ? nil : try NativeTaskValue.date(d["lease_expires_at"]),
                lastErrorCode: d["last_error_code"] as? String,
                acceptanceReceiptSHA256: d["acceptance_receipt_sha256"] is NSNull ? nil : try NativeTaskValue.sha(d["acceptance_receipt_sha256"]),
                acknowledgedAt: d["acknowledged_at"] is NSNull ? nil : try NativeTaskValue.date(d["acknowledged_at"]))
        } else if !(o["delivery"] is NSNull) { throw NativeTaskCapabilityError.integrityFailure }
        let value = ContinuityHandoffCommit(revision: r, delivery: delivery)
        guard try encode(value) == data else { throw NativeTaskCapabilityError.integrityFailure }
        return value
    }
}

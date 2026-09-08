import Foundation

/// Native control authority is supplied separately; none of these persisted
/// identifiers can establish caller identity.
enum ContinuityOperationControlError: Error, LocalizedError, Sendable, Equatable {
    case notFound, conflict, integrityFailure, cancellationRequested, reconciliationRequired, invalidRequest
    var errorDescription: String? {
        switch self {
        case .notFound: "The operation was not found."
        case .conflict: "The operation no longer owns this execution."
        case .integrityFailure: "The operation control proof is invalid."
        case .cancellationRequested: "Cancellation has fenced this exact operation."
        case .reconciliationRequired: "Cancellation remains fenced while an external outcome requires reconciliation."
        case .invalidRequest: "The operation control request exceeds its bounds."
        }
    }
}

enum ContinuityOperationState: String, Sendable, Equatable {
    case accepted, handoffCommitted = "handoff_committed", successorRequested = "successor_requested"
    case successorBootstrapping = "successor_bootstrapping", successorAcknowledged = "successor_acknowledged"
    case predecessorSealed = "predecessor_sealed", resumed, blocked
    case cancelRequested = "cancel_requested", cancelled, invalidated
}

struct ContinuityOperationProgressEvidence: Sendable {
    let source: ContinuityHandoffRevision
    let delivery: ContinuityHandoffDelivery?
    let canonical: ContinuitySourceBootstrapOperation?
}

struct ContinuityOperationTerminalReceipt: Sendable, Equatable {
    enum Outcome: String, Sendable { case resumed, cancelled, invalidated }
    let outcome: Outcome
    let receiptSHA256: String
    let recordedAt: String
}

struct ContinuityOperationStatus: Sendable, Equatable {
    let acceptance: ContinuityIngressAcceptanceReceipt
    let state: ContinuityOperationState
    /// Nil means the source store was unavailable or was not read.
    let deliveryState: ContinuityDeliveryState?
    let recoveryState: RecoveryState
    let reasonCode: String?
    let retryAt: String?
    let terminalReceipt: ContinuityOperationTerminalReceipt?
    enum RecoveryState: String, Sendable { case none, pending, blocked, uncertain }
}

struct ContinuityOperationCancellationRequest: Sendable, Equatable {
    static let maximumStoredBytes = 4 * 1_024
    let acceptance: ContinuityIngressAcceptanceReceipt
    let requestedAt: String
    let canonicalRequestJSON: Data
    let requestSHA256: String
    var operationID: UUID { acceptance.operationID }
    var runID: RunID { acceptance.runID }
    var sourceIdentity: ContinuityHandoffIdentity { acceptance.sourceIdentity }
    var authorization: ContinuityIngressAuthorization { acceptance.authorization }
    var acceptanceReceiptSHA256: String { acceptance.receiptSHA256 }

    init(acceptance: ContinuityIngressAcceptanceReceipt, requestedAt: String) throws {
        try OperationControlCoding.timestamp(requestedAt)
        let data = try ForgeJSONCanonicalizationV1.data(from: [
            "schema_version": 1, "kind": "source_operation_cancellation_request",
            "operation_id": acceptance.operationID.uuidString.lowercased(), "run_id": acceptance.runID.description,
            "acceptance_receipt_sha256": acceptance.receiptSHA256,
            "authorization_sha256": JSONSupport.sha256Hex(try acceptance.authorization.encodedJSON()),
            "continuity_id": acceptance.sourceIdentity.continuityID, "revision": acceptance.sourceIdentity.revision,
            "packet_sha256": acceptance.sourceIdentity.packetSHA256, "requested_at": requestedAt,
        ])
        guard data.count <= Self.maximumStoredBytes else { throw ContinuityOperationControlError.invalidRequest }
        self.acceptance = acceptance; self.requestedAt = requestedAt
        canonicalRequestJSON = data; requestSHA256 = JSONSupport.sha256Hex(data)
    }

    static func storedSnapshot(from data: Data, acceptance: ContinuityIngressAcceptanceReceipt) throws -> Self {
        let object = try OperationControlCoding.object(data, maximum: maximumStoredBytes)
        let result = try Self(acceptance: acceptance, requestedAt: OperationControlCoding.text(object, "requested_at"))
        guard result.canonicalRequestJSON == data else { throw ContinuityOperationControlError.integrityFailure }
        return result
    }
}

enum ContinuityOperationCancellationStore: String, Sendable, Equatable {
    case canonicalSource = "canonical_source", sourceOutbox = "source_outbox"
}

struct ContinuityOperationCancellationMarker: Sendable, Equatable {
    static let maximumStoredBytes = 4 * 1_024
    let operationID: UUID
    let sourceIdentity: ContinuityHandoffIdentity
    let requestSHA256: String
    let store: ContinuityOperationCancellationStore
    let evidenceSHA256: String
    let recordedAt: String
    let canonicalMarkerJSON: Data
    let markerSHA256: String

    init(request: ContinuityOperationCancellationRequest, store: ContinuityOperationCancellationStore,
         evidenceSHA256: String, recordedAt: String) throws {
        try OperationControlCoding.digest(evidenceSHA256); try OperationControlCoding.timestamp(recordedAt)
        guard let recorded = ISO8601.date(from: recordedAt), let requested = ISO8601.date(from: request.requestedAt),
              recorded >= requested else { throw ContinuityOperationControlError.integrityFailure }
        let data = try ForgeJSONCanonicalizationV1.data(from: [
            "schema_version": 1, "kind": "source_operation_cancellation_marker", "store": store.rawValue,
            "operation_id": request.operationID.uuidString.lowercased(), "request_sha256": request.requestSHA256,
            "continuity_id": request.sourceIdentity.continuityID, "revision": request.sourceIdentity.revision,
            "packet_sha256": request.sourceIdentity.packetSHA256, "evidence_sha256": evidenceSHA256, "recorded_at": recordedAt,
        ])
        guard data.count <= Self.maximumStoredBytes else { throw ContinuityOperationControlError.invalidRequest }
        operationID = request.operationID; sourceIdentity = request.sourceIdentity; requestSHA256 = request.requestSHA256
        self.store = store; self.evidenceSHA256 = evidenceSHA256; self.recordedAt = recordedAt
        canonicalMarkerJSON = data; markerSHA256 = JSONSupport.sha256Hex(data)
    }

    static func storedSnapshot(from data: Data, request: ContinuityOperationCancellationRequest) throws -> Self {
        let object = try OperationControlCoding.object(data, maximum: maximumStoredBytes)
        guard let store = ContinuityOperationCancellationStore(rawValue: try OperationControlCoding.text(object, "store")) else {
            throw ContinuityOperationControlError.integrityFailure
        }
        let result = try Self(request: request, store: store, evidenceSHA256: OperationControlCoding.text(object, "evidence_sha256"),
            recordedAt: OperationControlCoding.text(object, "recorded_at"))
        guard result.canonicalMarkerJSON == data else { throw ContinuityOperationControlError.integrityFailure }
        return result
    }
}

struct ContinuityOperationCancellationEvidence: Sendable, Equatable {
    let canonical: ContinuityOperationCancellationMarker
    let source: ContinuityOperationCancellationMarker
}

struct ContinuityOperationCancellationReceipt: Sendable, Equatable {
    static let maximumStoredBytes = 16 * 1_024
    let request: ContinuityOperationCancellationRequest
    let evidence: ContinuityOperationCancellationEvidence
    let recordedAt: String
    let canonicalReceiptJSON: Data
    let receiptSHA256: String
    var operationID: UUID { request.operationID }
    var runID: RunID { request.runID }
    var sourceIdentity: ContinuityHandoffIdentity { request.sourceIdentity }

    init(request: ContinuityOperationCancellationRequest, evidence: ContinuityOperationCancellationEvidence) throws {
        guard evidence.canonical.store == .canonicalSource, evidence.source.store == .sourceOutbox else {
            throw ContinuityOperationControlError.integrityFailure
        }
        for marker in [evidence.canonical, evidence.source] {
            guard try ContinuityOperationCancellationMarker.storedSnapshot(from: marker.canonicalMarkerJSON, request: request) == marker else {
                throw ContinuityOperationControlError.integrityFailure
            }
        }
        let recordedAt = ISO8601.date(from: evidence.canonical.recordedAt)! >= ISO8601.date(from: evidence.source.recordedAt)!
            ? evidence.canonical.recordedAt : evidence.source.recordedAt
        let data = try ForgeJSONCanonicalizationV1.data(from: [
            "schema_version": 1, "kind": "source_operation_cancellation_receipt", "request_sha256": request.requestSHA256,
            "canonical_marker": JSONSerialization.jsonObject(with: evidence.canonical.canonicalMarkerJSON),
            "source_marker": JSONSerialization.jsonObject(with: evidence.source.canonicalMarkerJSON), "recorded_at": recordedAt,
        ])
        guard data.count <= Self.maximumStoredBytes else { throw ContinuityOperationControlError.invalidRequest }
        self.request = request; self.evidence = evidence; self.recordedAt = recordedAt
        canonicalReceiptJSON = data; receiptSHA256 = JSONSupport.sha256Hex(data)
    }

    static func storedSnapshot(from data: Data, request: ContinuityOperationCancellationRequest) throws -> Self {
        let object = try OperationControlCoding.object(data, maximum: maximumStoredBytes)
        guard let canonical = object["canonical_marker"], let source = object["source_marker"] else {
            throw ContinuityOperationControlError.integrityFailure
        }
        let result = try Self(request: request, evidence: .init(
            canonical: .storedSnapshot(from: ForgeJSONCanonicalizationV1.data(from: canonical), request: request),
            source: .storedSnapshot(from: ForgeJSONCanonicalizationV1.data(from: source), request: request)))
        guard result.canonicalReceiptJSON == data else { throw ContinuityOperationControlError.integrityFailure }
        return result
    }
}

struct ContinuityOperationCancellationResult: Sendable, Equatable {
    enum Disposition: String, Sendable { case requested, alreadyRequested = "already_requested", alreadyTerminal = "already_terminal" }
    let disposition: Disposition
    let snapshot: ContinuityOperationStatus
    let request: ContinuityOperationCancellationRequest?
}

enum ContinuityOperationCancellationFailure: String, Sendable, Equatable {
    case providerOutcomeUnknown = "provider_outcome_unknown", storeUnavailable = "store_unavailable", interrupted
    case integrityFailure = "integrity_failure", retryWindowExceeded = "retry_window_exceeded"
}

struct ContinuityOperationCancellationReference: Sendable, Equatable {
    let rowID: Int64
    let operationID: UUID
    let runID: RunID
    let projectID: ProjectID
    let projectGeneration: ProjectGeneration
    let taskID: UUID
    let requestSHA256: String
}
struct ContinuityOperationCancellationPage: Sendable, Equatable {
    let references: [ContinuityOperationCancellationReference]
    let nextRowID: Int64?
}
struct ContinuityOperationCancellationClaim: Sendable, Equatable {
    let reference: ContinuityOperationCancellationReference
    let request: ContinuityOperationCancellationRequest
    var acceptance: ContinuityIngressAcceptanceReceipt { request.acceptance }
}

private enum OperationControlCoding {
    static func timestamp(_ value: String) throws {
        guard value.utf8.count <= 128, !value.contains("\0"), ISO8601.date(from: value) != nil else {
            throw ContinuityOperationControlError.integrityFailure
        }
    }
    static func digest(_ value: String) throws {
        guard value.count == 64, value.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw ContinuityOperationControlError.integrityFailure }
    }
    static func object(_ data: Data, maximum: Int) throws -> [String: Any] {
        guard data.count <= maximum, let text = String(data: data, encoding: .utf8), !text.contains("\0"),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ContinuityOperationControlError.integrityFailure }
        return object
    }
    static func text(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw ContinuityOperationControlError.integrityFailure }
        return value
    }
}

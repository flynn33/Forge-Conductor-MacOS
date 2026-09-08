// Strict CLU wire contracts. Native dispatch supplies task authority separately.

import Foundation
import CoreFoundation

enum ContinuityControlToolName: String, CaseIterable, Sendable {
    case capabilities = "clu_capabilities"
    case startHandoff = "clu_start_handoff"
    case status = "clu_status"
    case cancel = "clu_cancel"

    var description: String {
        switch self {
        case .capabilities: "Read CLU deployment, connection, exact-task readiness and observed qualification limits."
        case .startHandoff: "Submit one exact authorized handoff durably and return its operation handle without starting a provider inline."
        case .status: "Read durable progress or the terminal receipt for one caller-authorized CLU operation."
        case .cancel: "Request cancellation of one caller-authorized CLU operation while preserving committed effects and recovery."
        }
    }

    var inputSchema: [String: Any] {
        let properties: [String: Any]
        let required: [String]
        switch self {
        case .capabilities:
            properties = [:]; required = []
        case .startHandoff:
            properties = [
                "continuity_id": ["type": "string", "minLength": 1, "maxLength": 128,
                    "pattern": "^[A-Za-z0-9_.-]+$", "not": ["enum": [".", ".."]]] as [String: Any],
                "idempotency_key": ["type": "string", "minLength": 1, "maxLength": 256,
                    "description": "At most 256 UTF-8 bytes; no control characters or surrounding whitespace."] as [String: Any],
                "reason": ["type": "string", "minLength": 1, "maxLength": 512,
                    "description": "At most 512 UTF-8 bytes; no control characters or surrounding whitespace."] as [String: Any],
            ]
            required = ["continuity_id"]
        case .status, .cancel:
            properties = ["operation_id": ["type": "string",
                "pattern": "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"]]
            required = ["operation_id"]
        }
        return ["type": "object", "additionalProperties": false,
                "properties": properties, "required": required]
    }
}

enum ContinuityControlToolRequest: Sendable, Equatable {
    case capabilities
    case start(ContinuityExplicitHandoffRequest)
    case status(UUID)
    case cancel(UUID)

    init(name: String, arguments: [String: Any]) throws {
        guard let tool = ContinuityControlToolName(rawValue: name) else {
            throw ContinuityControlToolFailure(.invalidRequest, field: .toolName)
        }
        switch tool {
        case .capabilities:
            guard arguments.isEmpty else { throw ContinuityControlToolFailure(.invalidRequest, field: .arguments) }
            self = .capabilities
        case .startHandoff:
            guard arguments.count <= 3,
                  Set(arguments.keys).isSubset(of: ["continuity_id", "idempotency_key", "reason"]) else {
                throw ContinuityControlToolFailure(.invalidRequest, field: .arguments)
            }
            do { self = .start(try ContinuityExplicitHandoffRequest(arguments: arguments)) }
            catch { throw ContinuityControlToolFailure.mapping(error) }
        case .status, .cancel:
            guard arguments.count == 1, arguments["operation_id"] != nil else {
                throw ContinuityControlToolFailure(.invalidRequest, field: .arguments)
            }
            guard let text = arguments["operation_id"] as? String, text.utf8.count == 36,
                  let operationID = UUID(uuidString: text),
                  operationID.uuidString.lowercased() == text.lowercased() else {
                throw ContinuityControlToolFailure(.invalidRequest, field: .operationID)
            }
            self = tool == .status ? .status(operationID) : .cancel(operationID)
        }
    }
}

struct ContinuityControlToolFailure: Error, Equatable, Sendable {
    enum Code: String, CaseIterable, Sendable {
        case invalidRequest = "invalid_request", taskIdentityUnavailable = "task_identity_unavailable"
        case projectContextRequired = "project_context_required", staleGeneration = "stale_generation"
        case authorityMismatch = "authority_mismatch", revoked, notFound = "not_found", conflict
        case sourceNotReady = "source_not_ready", sourceFenced = "source_fenced"
        case capacityExceeded = "capacity_exceeded", configurationUnavailable = "configuration_unavailable"
        case operationBusy = "operation_busy", integrityFailure = "integrity_failure"
        case cancelled, deadlineExceeded = "deadline_exceeded", internalError = "internal_error"
    }
    enum Field: String, Sendable {
        case arguments, operationID = "operation_id", continuityID = "continuity_id"
        case idempotencyKey = "idempotency_key", reason, toolName = "tool_name", response
    }
    let code: Code
    let field: Field?

    init(_ code: Code, field: Field? = nil) { self.code = code; self.field = field }

    var retryable: Bool { code == .operationBusy || code == .deadlineExceeded }

    var message: String {
        switch code {
        case .invalidRequest: "The CLU request does not match the supported schema."
        case .taskIdentityUnavailable: "This request needs an authenticated native task connection. A shared MCP connection cannot select a task."
        case .projectContextRequired: "Complete native project and task setup before using this operation."
        case .staleGeneration: "The project generation changed. Reattach through native task setup."
        case .authorityMismatch: "The current native caller does not own this task."
        case .revoked: "This task or project authorization is no longer active."
        case .notFound: "The exact authorized handoff or operation is unavailable."
        case .conflict: "The request conflicts with an existing durable operation."
        case .sourceNotReady: "The exact handoff must be committed as resume-ready before submission."
        case .sourceFenced: "This source task has already transferred its mutation authority."
        case .capacityExceeded: "The request exceeds a bounded CLU storage or response limit."
        case .configurationUnavailable: "The required native manager or provider configuration is unavailable."
        case .operationBusy: "The operation is owned by another active request. Retry after that request completes."
        case .integrityFailure: "The operation's durable records require integrity recovery."
        case .cancelled: "The request was cancelled. Previously committed operation effects remain durable."
        case .deadlineExceeded: "The request deadline expired. Previously committed operation effects remain durable."
        case .internalError: "The CLU request could not be completed."
        }
    }

    /// Never expose descriptions, paths, identifiers or provider text from an error.
    static func mapping(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if error is CancellationError { return .init(.cancelled) }
        if error is ToolCallDeadlineExceeded { return .init(.deadlineExceeded) }
        if let failure = error as? ContinuityIngressError {
            switch failure {
            case .invalidRequest(let field):
                if field == "handoff_is_not_resume_ready" { return .init(.sourceNotReady) }
                let safeField: Field?
                switch field {
                case "continuity_id_or_unknown_field": safeField = .continuityID
                case "idempotency_key": safeField = .idempotencyKey
                case "reason": safeField = .reason
                default: safeField = nil
                }
                return .init(.invalidRequest, field: safeField)
            case .authorityMismatch: return .init(.authorityMismatch)
            case .invalidated: return .init(.revoked)
            case .notFound: return .init(.notFound)
            case .capacityExceeded: return .init(.capacityExceeded)
            case .deliveryConflict: return .init(.conflict)
            case .integrityFailure: return .init(.integrityFailure)
            }
        }
        if let failure = error as? ContinuityTaskAuthorizationError {
            switch failure {
            case .taskCorrelationRequired: return .init(.taskIdentityUnavailable)
            case .authorityMismatch: return .init(.authorityMismatch)
            case .revoked: return .init(.revoked)
            case .assignmentConflict: return .init(.conflict)
            case .capacityExceeded: return .init(.capacityExceeded)
            case .invalidAssignment: return .init(.configurationUnavailable)
            case .integrityFailure: return .init(.integrityFailure)
            }
        }
        if let failure = error as? ContinuitySourceActivationError {
            switch failure {
            case .sourceFenced: return .init(.sourceFenced)
            case .taskIdentityUnavailable: return .init(.taskIdentityUnavailable)
            case .unresolvedEffects: return .init(.operationBusy)
            case .proofRequired, .continuationEffectRequired: return .init(.conflict)
            case .conflict: return .init(.conflict)
            case .invalidRequest: return .init(.invalidRequest)
            }
        }
        if let failure = error as? ContinuityOperationControlError {
            switch failure {
            case .notFound: return .init(.notFound)
            case .conflict, .cancellationRequested, .reconciliationRequired: return .init(.conflict)
            case .integrityFailure: return .init(.integrityFailure)
            case .invalidRequest: return .init(.invalidRequest)
            }
        }
        if let failure = error as? ProjectContextError {
            switch failure {
            case .projectContextRequired: return .init(.projectContextRequired)
            case .staleProjectGeneration: return .init(.staleGeneration)
            case .projectNotActive: return .init(.revoked)
            case .projectScopeMismatch, .projectRootNotAuthorized: return .init(.authorityMismatch)
            case .projectNotFound: return .init(.notFound)
            case .databaseBusy, .projectRelinkBusy: return .init(.operationBusy)
            case .storageFull: return .init(.capacityExceeded)
            case .integrityFailure: return .init(.integrityFailure)
            case .repositoryClosed: return .init(.configurationUnavailable)
            default: return .init(.internalError)
            }
        }
        if let failure = error as? AutonomyError {
            switch failure {
            case .runNotFound: return .init(.notFound)
            case .leaseConflict, .leaseExpired, .leaseRequired, .staleLease: return .init(.operationBusy)
            case .runConflict, .transitionConflict, .intentConflict: return .init(.conflict)
            case .resultTooLarge: return .init(.capacityExceeded)
            case .shutdown: return .init(.configurationUnavailable)
            default: return .init(.internalError)
            }
        }
        if error is ContextBudgetError { return .init(.configurationUnavailable) }
        return .init(.internalError)
    }
}

struct ContinuityControlCapabilities: Sendable, Equatable {
    enum ProviderMode: String, Sendable { case nativeLMStudioResponses = "native_lmstudio_responses", externalChat = "external_chat", unavailable }
    enum TaskIdentity: String, Sendable { case verifiedNativeTask = "verified_native_task", unavailable }
    enum Role: String, Sendable { case primary, fallback, clu }
    enum Qualification: String, Sendable { case qualified, unqualified, unsupported, notObserved = "not_observed" }
    struct Qualifications: Sendable, Equatable {
        let nativeAPI: Qualification
        let desktopNewChat: Qualification
        let guiClosedRecovery: Qualification
        let laterRollover: Qualification
    }
    let deployed: Bool?
    let connected: Bool?
    let ready: Bool
    let automaticHandoffEnabled: Bool?
    let exactIDSupport: Bool
    let providerMode: ProviderMode
    let taskIdentity: TaskIdentity
    let role: Role
    let deploymentID: String?
    let buildVersion: String
    let qualification: Qualifications
    let reasons: [String]

    fileprivate func payload() throws -> [String: Any] {
        try ContinuityControlWire.text(buildVersion, maximumBytes: 64)
        if let deploymentID { try ContinuityControlWire.text(deploymentID, maximumBytes: 128) }
        guard reasons.count <= 16, Set(reasons).count == reasons.count else {
            throw ContinuityControlToolFailure(.capacityExceeded, field: .response)
        }
        for reason in reasons { try ContinuityControlWire.reasonCode(reason) }
        guard taskIdentity != .unavailable || (!ready && automaticHandoffEnabled == nil),
              !ready || (deployed == true && connected == true && exactIDSupport && providerMode != .unavailable) else {
            throw ContinuityControlToolFailure(.integrityFailure, field: .response)
        }
        return ["ok": true, "schema_version": 1,
            "deployed": deployed as Any? ?? NSNull(), "connected": connected as Any? ?? NSNull(), "ready": ready,
            "automatic_handoff_enabled": automaticHandoffEnabled as Any? ?? NSNull(), "exact_id_support": exactIDSupport,
            "provider_mode": providerMode.rawValue, "task_identity": taskIdentity.rawValue, "role": role.rawValue,
            "deployment_id": deploymentID as Any? ?? NSNull(), "build_version": buildVersion,
            "qualification": ["native_api": qualification.nativeAPI.rawValue, "desktop_new_chat": qualification.desktopNewChat.rawValue,
                "gui_closed_recovery": qualification.guiClosedRecovery.rawValue, "later_rollover": qualification.laterRollover.rawValue],
            "limits": ["continuity_id_bytes": 128, "idempotency_key_bytes": 256, "reason_bytes": 512,
                "maximum_response_bytes": ContinuityControlWire.maximumResponseBytes], "reasons": reasons]
    }
}

struct ContinuityControlOperationStatus: Sendable, Equatable {
    enum DeliveryState: String, Sendable {
        case pending, claimed, acknowledged, blocked, invalidated, unknown

        init(source: ContinuityDeliveryState?) {
            self = source.flatMap { Self(rawValue: $0.rawValue) } ?? .unknown
        }
    }
    enum State: String, Sendable {
        case accepted, handoffCommitted = "handoff_committed", successorRequested = "successor_requested"
        case successorBootstrapping = "successor_bootstrapping", successorAcknowledged = "successor_acknowledged"
        case predecessorSealed = "predecessor_sealed", resumed, blocked, cancelRequested = "cancel_requested", cancelled, invalidated
    }
    struct Recovery: Sendable, Equatable {
        enum State: String, Sendable { case none, pending, blocked, uncertain }
        let state: State
        let reasonCode: String?
        let retryAt: String?
    }
    struct TerminalReceipt: Sendable, Equatable {
        enum Outcome: String, Sendable { case resumed, cancelled, invalidated }
        let outcome: Outcome
        let receiptSHA256: String
        let recordedAt: String
    }
    let operationID: UUID
    let runID: RunID
    let source: ContinuityHandoffIdentity
    let state: State
    let deliveryState: DeliveryState
    let recovery: Recovery
    let terminalReceipt: TerminalReceipt?

    fileprivate func payload() throws -> [String: Any] {
        if let code = recovery.reasonCode { try ContinuityControlWire.reasonCode(code) }
        if let time = recovery.retryAt { try ContinuityControlWire.timestamp(time) }
        let terminal: Any
        if let receipt = terminalReceipt {
            try ContinuityControlWire.digest(receipt.receiptSHA256)
            try ContinuityControlWire.timestamp(receipt.recordedAt)
            guard state.rawValue == receipt.outcome.rawValue, recovery.state == .none else {
                throw ContinuityControlToolFailure(.integrityFailure, field: .response)
            }
            terminal = ["outcome": receipt.outcome.rawValue, "receipt_sha256": receipt.receiptSHA256,
                        "recorded_at": receipt.recordedAt]
        } else {
            guard state != .resumed && state != .cancelled && state != .invalidated else {
                throw ContinuityControlToolFailure(.integrityFailure, field: .response)
            }
            terminal = NSNull()
        }
        guard recovery.state != .none || (recovery.reasonCode == nil && recovery.retryAt == nil) else {
            throw ContinuityControlToolFailure(.integrityFailure, field: .response)
        }
        return ["operation_id": operationID.uuidString.lowercased(), "run_id": runID.description,
            "source": ContinuityControlWire.source(source), "state": state.rawValue, "delivery_state": deliveryState.rawValue,
            "recovery": ["state": recovery.state.rawValue, "reason_code": recovery.reasonCode as Any? ?? NSNull(),
                "retry_at": recovery.retryAt as Any? ?? NSNull()], "terminal_receipt": terminal]
    }
}

enum ContinuityControlToolResponse: Sendable, Equatable {
    enum CancelDisposition: String, Sendable { case requested, alreadyRequested = "already_requested", alreadyTerminal = "already_terminal" }
    case capabilities(ContinuityControlCapabilities)
    case started(ContinuityExplicitStartReceipt)
    case status(ContinuityControlOperationStatus)
    case cancelled(disposition: CancelDisposition, operation: ContinuityControlOperationStatus)
    case failure(ContinuityControlToolFailure)

    func toolResult() throws -> ToolResult {
        let payload: [String: Any]
        switch self {
        case .capabilities(let capabilities): payload = try capabilities.payload()
        case .started(let receipt):
            try ContinuityControlWire.digest(receipt.acceptance.receiptSHA256)
            guard receipt.permit.operationID == receipt.acceptance.operationID,
                  receipt.permit.acceptanceReceiptSHA256 == receipt.acceptance.receiptSHA256 else {
                throw ContinuityControlToolFailure(.integrityFailure, field: .response)
            }
            payload = ["ok": true, "schema_version": 1, "submission": "accepted",
                "operation_id": receipt.acceptance.operationID.uuidString.lowercased(), "run_id": receipt.acceptance.runID.description,
                "source": ContinuityControlWire.source(receipt.acceptance.sourceIdentity),
                "acceptance_receipt_sha256": receipt.acceptance.receiptSHA256]
        case .status(let operation):
            payload = ["ok": true, "schema_version": 1, "operation": try operation.payload()]
        case .cancelled(let disposition, let operation):
            guard (disposition == .alreadyTerminal && operation.terminalReceipt != nil)
                    || (disposition != .alreadyTerminal && operation.state == .cancelRequested) else {
                throw ContinuityControlToolFailure(.integrityFailure, field: .response)
            }
            payload = ["ok": true, "schema_version": 1, "disposition": disposition.rawValue, "operation": try operation.payload()]
        case .failure(let failure):
            payload = ["ok": false, "schema_version": 1, "code": failure.code.rawValue,
                "field": failure.field?.rawValue as Any? ?? NSNull(), "message": failure.message, "retryable": failure.retryable]
        }
        return try ContinuityControlWire.boundedResult(payload: payload)
    }
}

/// Output checks apply before a payload enters either MCP representation. Integer
/// source revisions stay Int64 throughout; no floating-point canonicalizer is used.
enum ContinuityControlWire {
    static let maximumResponseBytes = 32_768

    static func boundedResult(payload: [String: Any]) throws -> ToolResult {
        guard let flag = payload["ok"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
              JSONSerialization.isValidJSONObject(payload) else {
            throw ContinuityControlToolFailure(.integrityFailure, field: .response)
        }
        let ok = flag.boolValue
        let data = try JSONSupport.data(from: payload)
        guard data.count <= maximumResponseBytes else {
            throw ContinuityControlToolFailure(.capacityExceeded, field: .response)
        }
        // MCP emits both JSON text and structuredContent. Bound that actual result
        // body too, including escaping and framing fields, before returning it.
        let wire: [String: Any] = ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
            "isError": !ok, "structuredContent": payload]
        guard try JSONSupport.data(from: wire).count <= maximumResponseBytes else {
            throw ContinuityControlToolFailure(.capacityExceeded, field: .response)
        }
        return ToolResult(ok: ok, payload: payload, isError: !ok)
    }

    fileprivate static func source(_ source: ContinuityHandoffIdentity) -> [String: Any] {
        ["continuity_id": source.continuityID, "revision": source.revision, "packet_sha256": source.packetSHA256]
    }
    fileprivate static func text(_ text: String, maximumBytes: Int) throws {
        guard !text.isEmpty, text.utf8.count <= maximumBytes,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ContinuityControlToolFailure(.integrityFailure, field: .response)
        }
    }
    fileprivate static func digest(_ text: String) throws {
        guard ContinuityIngressLimits.validSHA256(text) else {
            throw ContinuityControlToolFailure(.integrityFailure, field: .response)
        }
    }
    fileprivate static func reasonCode(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= 96, let first = text.utf8.first, (97...122).contains(first),
              text.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
            throw ContinuityControlToolFailure(.integrityFailure, field: .response)
        }
    }
    fileprivate static func timestamp(_ text: String) throws {
        guard text.utf8.count <= 40, ISO8601.date(from: text) != nil else {
            throw ContinuityControlToolFailure(.integrityFailure, field: .response)
        }
    }
}

import Foundation
import Security

public protocol NativeTaskOperatorTransport: Sendable {
    func submitNativeTaskCommand(action: String, body: Data) async throws -> NativeTaskCapabilityCommandResult
}

public protocol NativeSourceOperatorTransport: Sendable {
    func submitNativeSourceCommand(action: String, body: Data) async throws -> Data
}

/// A native operator input file contains approval, never credentials or model-provided authority.
public struct NativeContinuityTaskPreparationInput: Sendable {
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let approval: NativeContinuityTaskApproval
    public let expiresAt: String

    public init(projectID: ProjectID, projectGeneration: ProjectGeneration,
                approval: NativeContinuityTaskApproval, expiresAt: String) throws {
        guard projectGeneration.rawValue > 0, projectGeneration.rawValue <= UInt64(Int.max) else { throw NativeTaskOperatorError.invalidRequest("project_generation") }
        self.projectID = projectID; self.projectGeneration = projectGeneration; self.approval = approval
        self.expiresAt = try NativeTaskOperatorWire.date(["expires_at": expiresAt], "expires_at")
    }
    public init(data: Data) throws {
        let object = try NativeTaskOperatorWire.object(data, maximumBytes: NativeContinuityTaskPreparationRequest.maximumBodyBytes)
        try NativeTaskOperatorWire.keys(object, required: ["schema_version", "project_id", "project_generation", "profile_id", "profile_version", "approval", "expires_at"])
        try NativeTaskOperatorWire.version(object)
        guard object["profile_id"] as? String == "forge.native-task-source",
              JSONSupport.exactInteger(object["profile_version"]) == 1,
              let approval = object["approval"] as? [String: Any] else { throw NativeTaskOperatorError.invalidRequest("profile") }
        try self.init(projectID: ProjectID(NativeTaskOperatorWire.uuid(object, "project_id")),
            projectGeneration: ProjectGeneration(UInt64(NativeTaskOperatorWire.integer(object, "project_generation", range: 1...Int.max))),
            approval: NativeContinuityTaskApproval(arguments: approval), expiresAt: NativeTaskOperatorWire.date(object, "expires_at"))
    }
}

public struct NativeTaskOperatorPendingCommand: Error, LocalizedError, Sendable {
    public let snapshot: NativeTaskCredentialSnapshot
    public var errorDescription: String? { "Native task command is durably pending; reconcile the exact task before retrying with new inputs" }
}

/// Stages each exact command before any network operation. Reconciliation never reads changed input files.
public actor NativeTaskOperatorClient {
    private let store: NativeTaskCredentialFileStore
    private let transport: any NativeTaskOperatorTransport
    private let endpoint: URL
    private let sourceTransport: (any NativeSourceOperatorTransport)?
    public init(store: NativeTaskCredentialFileStore, transport: any NativeTaskOperatorTransport, endpoint: URL,
                sourceTransport: (any NativeSourceOperatorTransport)? = nil) throws {
        try NativeTaskOperatorEndpoint.validate(endpoint)
        self.store = store; self.transport = transport; self.endpoint = endpoint
        self.sourceTransport = sourceTransport ?? (transport as? any NativeSourceOperatorTransport)
    }

    public func sendSource(_ request: NativeSourceSendRequest) async throws -> NativeSourceOperatorResponse {
        try await sourceCommand(action: "send", body: request.canonicalRequestJSON,
            taskID: request.taskID, requestID: request.requestID)
    }

    public func sourceStatus(_ request: NativeSourceStatusRequest) async throws -> NativeSourceOperatorResponse {
        try await sourceCommand(action: "status", body: request.canonicalRequestJSON,
            taskID: request.taskID, requestID: request.requestID)
    }

    public func cancelSource(_ request: NativeSourceCancelRequest) async throws -> NativeSourceOperatorResponse {
        try await sourceCommand(action: "cancel", body: request.canonicalRequestJSON,
            taskID: request.taskID, requestID: request.requestID)
    }

    private func sourceCommand(action: String, body: Data, taskID: UUID, requestID: UUID) async throws -> NativeSourceOperatorResponse {
        guard let sourceTransport else { throw NativeSourceOperatorError.unavailable }
        try Task.checkCancellation()
        let data = try await sourceTransport.submitNativeSourceCommand(action: action, body: body)
        let result = try NativeSourceOperatorResponse(data: data)
        guard result.taskID == taskID, result.requestID == requestID else { throw NativeSourceOperatorError.invalidResponse }
        return result
    }

    public func prepare(_ input: NativeContinuityTaskPreparationInput) async throws -> NativeTaskCredentialSnapshot {
        try Self.validateNewExpiry(input.expiresAt)
        let taskID = UUID(), capabilityID = UUID()
        let credential = try Self.credential(capabilityID: capabilityID, epoch: 1)
        let request = try NativeContinuityTaskPreparationRequest(requestID: UUID(), taskID: taskID, capabilityID: capabilityID,
            projectID: input.projectID, projectGeneration: input.projectGeneration, approval: input.approval,
            verifierSHA256: credential.verifier.sha256, expiresAt: input.expiresAt)
        let command = NativeTaskOperatorCommand.prepare(request)
        _ = try store.stage(command, candidate: credential, endpoint: endpoint)
        return try await send(command)
    }

    public func rotate(taskID: UUID, expectedEpoch: Int64, expiresAt: String) async throws -> NativeTaskCredentialSnapshot {
        try Self.validateNewExpiry(expiresAt)
        let snapshot = try store.snapshot(taskID: taskID)
        guard let current = snapshot.result?.current, expectedEpoch > 0, expectedEpoch < Int64.max else { throw NativeTaskOperatorError.credentialConflict }
        let credential = try Self.credential(capabilityID: current.capabilityID, epoch: expectedEpoch + 1)
        let request = try NativeContinuityTaskRotationRequest(requestID: UUID(), taskID: taskID, capabilityID: current.capabilityID,
            projectID: current.projectID, projectGeneration: current.projectGeneration, expectedEpoch: expectedEpoch,
            verifierSHA256: credential.verifier.sha256, expiresAt: expiresAt)
        let command = NativeTaskOperatorCommand.rotate(request)
        _ = try store.stage(command, candidate: credential, endpoint: endpoint)
        return try await send(command)
    }

    public func revoke(taskID: UUID, expectedEpoch: Int64, reason: String? = nil) async throws -> NativeTaskCredentialSnapshot {
        guard let current = try store.snapshot(taskID: taskID).result?.current else { throw NativeTaskOperatorError.credentialConflict }
        let request = try NativeContinuityTaskRevocationRequest(requestID: UUID(), taskID: taskID, capabilityID: current.capabilityID,
            projectID: current.projectID, projectGeneration: current.projectGeneration, expectedEpoch: expectedEpoch, reason: reason)
        let command = NativeTaskOperatorCommand.revoke(request)
        _ = try store.stage(command, candidate: nil, endpoint: endpoint)
        return try await send(command)
    }

    public func reconcile(taskID: UUID) async throws -> NativeTaskCredentialSnapshot {
        try await send(store.pending(taskID: taskID, endpoint: endpoint))
    }
    private func send(_ command: NativeTaskOperatorCommand) async throws -> NativeTaskCredentialSnapshot {
        do {
            try Task.checkCancellation()
            let result = try await transport.submitNativeTaskCommand(action: command.action, body: command.data)
            try Task.checkCancellation()
            return try store.complete(command, result: result, endpoint: endpoint)
        } catch {
            // No response/error body or credential is retained in the diagnostic.
            throw NativeTaskOperatorPendingCommand(snapshot: try store.snapshot(taskID: command.taskID))
        }
    }
    private static func credential(capabilityID: UUID, epoch: Int64) throws -> NativeTaskCapabilityCredential {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw NativeTaskOperatorError.invalidCredentialFile }
        return try NativeTaskCapabilityCredential(capabilityID: capabilityID, epoch: epoch, secret: bytes)
    }
    private static func validateNewExpiry(_ value: String) throws {
        let now = Date()
        guard let expiry = ISO8601.date(from: value), expiry > now, expiry.timeIntervalSince(now) <= 7 * 24 * 60 * 60 else {
            throw NativeTaskOperatorError.invalidRequest("expires_at")
        }
    }
}

enum NativeTaskOperatorEndpoint {
    static func validate(_ url: URL) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "http",
              ["127.0.0.1", "::1", "[::1]"].contains(c.host ?? ""), let port = c.port, (1...65535).contains(port),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.path == "/mcp/continuity" else {
            throw NativeTaskOperatorError.invalidRequest("manager_endpoint")
        }
    }
}

enum NativeTaskOperatorCommand: Sendable {
    case prepare(NativeContinuityTaskPreparationRequest), rotate(NativeContinuityTaskRotationRequest), revoke(NativeContinuityTaskRevocationRequest)
    init(action: String, data: Data) throws {
        switch action {
        case "prepare": self = .prepare(try .init(data: data))
        case "rotate": self = .rotate(try .init(data: data))
        case "revoke": self = .revoke(try .init(data: data))
        default: throw NativeTaskOperatorError.invalidRequest("action")
        }
        guard self.data == data else { throw NativeTaskOperatorError.invalidRequest("canonical_request") }
    }
    var action: String { switch self { case .prepare: "prepare"; case .rotate: "rotate"; case .revoke: "revoke" } }
    var data: Data { switch self { case .prepare(let r): r.canonicalRequestJSON; case .rotate(let r): r.canonicalRequestJSON; case .revoke(let r): r.canonicalRequestJSON } }
    var requestID: UUID { switch self { case .prepare(let r): r.requestID; case .rotate(let r): r.requestID; case .revoke(let r): r.requestID } }
    var taskID: UUID { switch self { case .prepare(let r): r.taskID; case .rotate(let r): r.taskID; case .revoke(let r): r.taskID } }
    var capabilityID: UUID { switch self { case .prepare(let r): r.capabilityID; case .rotate(let r): r.capabilityID; case .revoke(let r): r.capabilityID } }
    var projectID: ProjectID { switch self { case .prepare(let r): r.projectID; case .rotate(let r): r.projectID; case .revoke(let r): r.projectID } }
    var projectGeneration: ProjectGeneration { switch self { case .prepare(let r): r.projectGeneration; case .rotate(let r): r.projectGeneration; case .revoke(let r): r.projectGeneration } }
    var requestSHA256: String { switch self { case .prepare(let r): r.requestSHA256; case .rotate(let r): r.requestSHA256; case .revoke(let r): r.requestSHA256 } }
    var verifierSHA256: String? { switch self { case .prepare(let r): r.verifierSHA256; case .rotate(let r): r.verifierSHA256; case .revoke: nil } }
    var expiresAt: String? { switch self { case .prepare(let r): r.expiresAt; case .rotate(let r): r.expiresAt; case .revoke: nil } }
    var expectedEpoch: Int64? { switch self { case .prepare: nil; case .rotate(let r): r.expectedEpoch; case .revoke(let r): r.expectedEpoch } }
    var resultEpoch: Int64 { expectedEpoch.map { $0 + 1 } ?? 1 }
    func validate(_ result: NativeTaskCapabilityCommandResult) throws {
        let receipt = result.receipt, current = result.current
        guard receipt.requestID == requestID, receipt.requestSHA256 == requestSHA256, receipt.action == action,
              receipt.taskID == taskID, receipt.capabilityID == capabilityID, receipt.projectID == projectID,
              receipt.projectGeneration == projectGeneration, receipt.priorEpoch == expectedEpoch,
              receipt.resultEpoch == resultEpoch, receipt.verifierSHA256 == verifierSHA256, receipt.expiresAt == expiresAt,
              current.taskID == taskID, current.capabilityID == capabilityID, current.projectID == projectID,
              current.projectGeneration == projectGeneration, current.epoch >= receipt.resultEpoch,
              current.approvalSHA256 == receipt.approvalSHA256, current.scopeSHA256 == receipt.scopeSHA256,
              current.epoch != receipt.resultEpoch || (current.expiresAt == receipt.expiresAt || action == "revoke"),
              current.epoch != receipt.resultEpoch || (current.state == .revoked) == (action == "revoke") else {
            throw NativeTaskOperatorError.invalidResponse
        }
        if case .prepare(let request) = self {
            guard receipt.documentSHA256 == JSONSupport.sha256Hex(request.approval.assignmentBytes) else { throw NativeTaskOperatorError.invalidResponse }
        }
    }
}

enum NativeTaskOperatorResponse {
    static let maximumBytes = 32_768
    static func data(_ result: NativeTaskCapabilityCommandResult) throws -> Data {
        try NativeTaskOperatorWire.canonical(["schema_version": 1, "ok": true,
            "disposition": result.replayed ? "replayed" : "committed", "receipt": result.receipt.wireObject,
            "current": result.current.wireObject], maximumBytes: maximumBytes)
    }
    static func decode(_ data: Data) throws -> NativeTaskCapabilityCommandResult {
        do {
            let o = try NativeTaskOperatorWire.object(data, maximumBytes: maximumBytes)
            try NativeTaskOperatorWire.keys(o, required: ["schema_version", "ok", "disposition", "receipt", "current"])
            try NativeTaskOperatorWire.version(o)
            guard try NativeTaskOperatorWire.boolean(o, "ok"), let disposition = o["disposition"] as? String,
                  ["committed", "replayed"].contains(disposition), let receipt = o["receipt"] as? [String: Any],
                  let current = o["current"] as? [String: Any] else { throw NativeTaskOperatorError.invalidResponse }
            let result = NativeTaskCapabilityCommandResult(receipt: try .init(arguments: receipt), current: try .init(arguments: current), replayed: disposition == "replayed")
            let retained = result.receipt, live = result.current
            guard retained.taskID == live.taskID, retained.capabilityID == live.capabilityID,
                  retained.projectID == live.projectID, retained.projectGeneration == live.projectGeneration,
                  retained.approvalSHA256 == live.approvalSHA256, retained.scopeSHA256 == live.scopeSHA256,
                  live.epoch >= retained.resultEpoch,
                  live.epoch != retained.resultEpoch || (live.state == .revoked) == (retained.action == "revoke"),
                  live.epoch != retained.resultEpoch || retained.action == "revoke" || live.expiresAt == retained.expiresAt else {
                throw NativeTaskOperatorError.invalidResponse
            }
            return result
        } catch { throw NativeTaskOperatorError.invalidResponse }
    }
}

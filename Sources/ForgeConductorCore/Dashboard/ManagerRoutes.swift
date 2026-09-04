// ManagerRoutes.swift
// What: Handles typed manager status, settings, and lifecycle HTTP endpoints.
// How: It maps validated dashboard requests to ManagerControlling operations and
// returns only structured dictionaries for the transport layer to encode.
// Why: Manager behavior stays reusable without depending on HTTP connection objects.

import Foundation
import Network
import Security
import Darwin

public protocol ManagerMutationCredentialProviding: Sendable {
    func bearerToken() throws -> String
}

public enum ManagerMutationCredentialError: Error, LocalizedError, Sendable {
    case unavailable
    case invalidStorage
    case invalidCredential

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "The manager control credential is unavailable."
        case .invalidStorage:
            "The manager control credential is not protected by the current user."
        case .invalidCredential:
            "The manager control credential is invalid."
        }
    }
}

/// Owns the local manager bearer credential shared by the per-user manager,
/// native app, and CLI. Creation uses a same-directory temporary file plus an
/// atomic hard-link commit so concurrent processes converge on one value.
public final class ManagerControlCredentialStore: ManagerMutationCredentialProviding, @unchecked Sendable {
    public static let tokenByteCount = 32
    public static let tokenCharacterCount = tokenByteCount * 2

    private let credentialURL: URL
    private let lock = NSLock()

    public init(paths: AppPaths = AppPaths()) {
        credentialURL = paths.managerControlCredential
    }

    public func bearerToken() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try loadExisting()
        } catch ManagerMutationCredentialError.unavailable {
            try createAtomically()
            return try loadExisting()
        }
    }

    private func createAtomically() throws {
        let directory = credentialURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var random = [UInt8](repeating: 0, count: Self.tokenByteCount)
        let randomStatus = random.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw ManagerMutationCredentialError.unavailable
        }
        let alphabet = Array("0123456789abcdef".utf8)
        var encoded = [UInt8]()
        encoded.reserveCapacity(Self.tokenCharacterCount)
        for byte in random {
            encoded.append(alphabet[Int(byte >> 4)])
            encoded.append(alphabet[Int(byte & 0x0f)])
        }

        let temporaryURL = directory.appendingPathComponent(
            ".manager-control.\(UUID().uuidString.lowercased()).tmp"
        )
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw ManagerMutationCredentialError.unavailable
        }
        var committed = false
        defer {
            _ = Darwin.close(descriptor)
            if !committed {
                temporaryURL.path.withCString { _ = Darwin.unlink($0) }
            }
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw ManagerMutationCredentialError.unavailable
        }

        try encoded.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw ManagerMutationCredentialError.unavailable
            }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw ManagerMutationCredentialError.unavailable
                }
                offset += result
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ManagerMutationCredentialError.unavailable
        }

        let linkResult = temporaryURL.path.withCString { temporaryPath in
            credentialURL.path.withCString { credentialPath in
                Darwin.link(temporaryPath, credentialPath)
            }
        }
        if linkResult != 0, errno != EEXIST {
            throw ManagerMutationCredentialError.unavailable
        }
        temporaryURL.path.withCString { _ = Darwin.unlink($0) }
        committed = true
    }

    private func loadExisting() throws -> String {
        let descriptor = credentialURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw ManagerMutationCredentialError.unavailable
            }
            throw ManagerMutationCredentialError.invalidStorage
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ManagerMutationCredentialError.invalidStorage
        }
        let permissions = metadata.st_mode & mode_t(0o777)
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              permissions == mode_t(S_IRUSR | S_IWUSR),
              metadata.st_size == off_t(Self.tokenCharacterCount) else {
            throw ManagerMutationCredentialError.invalidStorage
        }

        var bytes = [UInt8](repeating: 0, count: Self.tokenCharacterCount)
        var offset = 0
        while offset < bytes.count {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else {
                throw ManagerMutationCredentialError.invalidCredential
            }
            offset += result
        }
        guard bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ManagerMutationCredentialError.invalidCredential
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Validates a bearer header without data-dependent comparison exits. The
/// fixed upper bound also prevents attacker-controlled header work expansion.
public struct ManagerMutationAuthorizer: Sendable {
    public static let maximumAuthorizationHeaderBytes = 512
    private let credentials: any ManagerMutationCredentialProviding

    public init(credentials: any ManagerMutationCredentialProviding) {
        self.credentials = credentials
    }

    public func authorizes(_ authorizationHeader: String?) -> Bool {
        guard let authorizationHeader,
              authorizationHeader.utf8.count <= Self.maximumAuthorizationHeaderBytes,
              let token = try? credentials.bearerToken() else {
            return false
        }
        let supplied = Array(authorizationHeader.utf8)
        let expected = Array("Bearer \(token)".utf8)
        var difference = supplied.count ^ expected.count
        for index in 0..<Self.maximumAuthorizationHeaderBytes {
            let lhs = index < supplied.count ? supplied[index] : 0
            let rhs = index < expected.count ? expected[index] : 0
            difference |= Int(lhs ^ rhs)
        }
        return difference == 0
    }

    public static func requiresAuthorization(method: String, path: String) -> Bool {
        switch (method.uppercased(), path) {
        case ("GET", "/api/manager/status"),
             ("GET", "/api/manager/settings"),
             ("GET", "/api/manager/operator/snapshot"),
             ("GET", "/api/manager/autonomy/status"),
             ("POST", "/api/manager/projects/status"),
             ("POST", "/api/manager/runs/status"):
            return false
        default:
            return true
        }
    }
}

private struct ManagerRouteTarget {
    let path: String
    let queryItems: [URLQueryItem]
}

private struct ManagerOperatorSnapshotQuery {
    let limit: Int
    let cursor: Int64?
}

private enum ManagerOperatorSnapshotQueryError: Error, LocalizedError {
    case invalidTarget
    case invalidParameter

    var errorDescription: String? {
        switch self {
        case .invalidTarget: "Malformed manager request target"
        case .invalidParameter: "Snapshot accepts one limit from 1 through 100 and one positive cursor"
        }
    }
}

/// Manager control plane routes: start/stop/restart/settings/shutdown.
public final class ManagerRoutes: @unchecked Sendable {
    public static let maximumProjectRegistrationPathBytes = 4_096
    static let maximumProjectRegistrationBodyBytes = 16_384
    public static let maximumProjectRelinkPathBytes = 4_096
    static let maximumProjectRelinkBodyBytes = 16_384
    static let maximumRuntimeJobCancelBodyBytes = 256
    static let maximumProviderProbeBodyBytes = 512
    static let maximumRunControlBodyBytes = 256
    /// Provider I/O is intentionally isolated from `DashboardServer`'s serial
    /// listener queue. The active-connection cap bounds submitted work, while
    /// `ManagerNode` rejects overlapping probes and owns the operation deadline.
    private static let providerProbeQueue = DispatchQueue(
        label: "forge.dashboard.provider-probe",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let manager: ManagerNode
    private let http: HTTPResponder
    private let authorizer: ManagerMutationAuthorizer

    public init(
        manager: ManagerNode,
        http: HTTPResponder,
        credentials: (any ManagerMutationCredentialProviding)? = nil
    ) {
        self.manager = manager
        self.http = http
        self.authorizer = ManagerMutationAuthorizer(
            credentials: credentials ?? ManagerControlCredentialStore(paths: manager.app.paths)
        )
    }

    public func handle(
        method: String,
        path: String,
        headers: [String: String],
        body: Data,
        connection: NWConnection
    ) throws {
        let target: ManagerRouteTarget
        do {
            target = try Self.routeTarget(path)
        } catch {
            http.respondJSON(connection, status: 400, object: [
                "ok": false,
                "code": "invalid_manager_target",
                "message": error.localizedDescription,
            ])
            return
        }
        if ManagerMutationAuthorizer.requiresAuthorization(method: method, path: target.path),
           !authorizer.authorizes(headers["authorization"]) {
            http.respondJSON(connection, status: 401, object: [
                "ok": false,
                "code": "manager_mutation_unauthorized",
                "message": "Manager mutation authorization is required",
            ])
            return
        }
        switch (method, target.path) {
        case ("GET", "/api/manager/provider/configuration"),
             ("PUT", "/api/manager/provider/configuration"),
             ("GET", "/api/manager/provider/models"):
            dispatchProviderConfiguration(method: method, path: target.path, body: body, connection: connection)
        case ("GET", "/api/manager/status"):
            http.respondJSON(connection, status: 200, object: manager.status())
        case ("GET", "/api/manager/settings"):
            http.respondJSON(connection, status: 200, object: manager.settings())
        case ("GET", "/api/manager/operator/snapshot"):
            do {
                let query = try Self.operatorSnapshotQuery(target.queryItems)
                http.respondJSON(
                    connection,
                    status: 200,
                    object: try manager.operatorSnapshotDictionary(
                        limit: query.limit,
                        beforeEventSequence: query.cursor
                    )
                )
            } catch let error as ManagerOperatorSnapshotQueryError {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_snapshot_query",
                    "message": error.localizedDescription,
                ])
            }
        case ("POST", "/api/manager/start"):
            let st = try manager.startService()
            http.respondJSON(connection, status: 200, object: st.asDictionary())
        case ("POST", "/api/manager/stop"):
            let st = try manager.stopService()
            http.respondJSON(connection, status: 200, object: st.asDictionary())
        case ("POST", "/api/manager/restart"):
            let st = try manager.restartService()
            http.respondJSON(connection, status: 200, object: st.asDictionary())
        case ("POST", "/api/manager/shutdown"):
            http.respondJSON(connection, status: 200, object: [
                "ok": true,
                "message": "Manager shutting down",
                "state": "stopping",
            ])
            manager.requestShutdown(delayMs: 350)
        case ("POST", "/api/manager/settings"), ("PUT", "/api/manager/settings"):
            let obj = (try? JSONSupport.object(from: body)) ?? [:]
            let apply = (obj["apply"] as? Bool) ?? true
            let patch = obj["settings"] as? [String: Any] ?? obj
            let result = try manager.updateSettings(patch, apply: apply)
            http.respondJSON(connection, status: 200, object: result)
        case ("POST", "/api/manager/projects/register"):
            guard body.count <= Self.maximumProjectRegistrationBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false,
                    "code": "project_registration_body_too_large",
                    "message": "Project registration accepts one bounded path and optional identity fields",
                ])
                return
            }
            let object = try JSONSupport.object(from: body)
            let allowedKeys = Set(["path", "display_name", "repository_identity"])
            guard Set(object.keys).isSubset(of: allowedKeys),
                  let path = object["path"] as? String,
                  !path.isEmpty,
                  path.utf8.count <= Self.maximumProjectRegistrationPathBytes,
                  (path as NSString).isAbsolutePath,
                  object["display_name"].map({ $0 is String }) ?? true,
                  (object["display_name"] as? String).map({ $0.utf8.count <= 512 }) ?? true,
                  object["repository_identity"].map({ $0 is String }) ?? true,
                  (object["repository_identity"] as? String).map({
                      $0.utf8.count <= 2_048
                  }) ?? true else {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_project_registration",
                    "message": "Project registration requires one bounded absolute path and bounded optional identity fields",
                ])
                return
            }
            do {
                let result = try manager.registerProjectResult(
                    path: path,
                    displayName: object["display_name"] as? String,
                    repositoryIdentity: object["repository_identity"] as? String
                )
                var response = try result.asDictionary()
                if result.registrationState == .committed,
                   let rawProjectID = result.projectID,
                   let projectUUID = UUID(uuidString: rawProjectID) {
                    response.merge(
                        try manager.projectStatus(projectID: ProjectID(projectUUID)),
                        uniquingKeysWith: { typed, _ in typed }
                    )
                }
                http.respondJSON(
                    connection,
                    status: result.registrationState == .committed ? 200 : 202,
                    object: response
                )
            } catch let error as ProjectContextError {
                let busy = error == .databaseBusy
                http.respondJSON(connection, status: busy ? 503 : 409, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                    "retryable": busy,
                    "reconciliation_required": false,
                ])
            } catch let error as ProjectMemoryError {
                let invalid: Bool
                switch error {
                case .invalidRequest, .payloadTooLarge:
                    invalid = true
                default:
                    invalid = false
                }
                let busy = error == .databaseBusy
                http.respondJSON(
                    connection,
                    status: invalid ? 400 : (busy ? 503 : 409),
                    object: [
                        "ok": false,
                        "code": error.code,
                        "message": error.localizedDescription,
                        "retryable": busy,
                        "reconciliation_required": false,
                    ]
                )
            }
        case ("POST", "/api/manager/projects/status"):
            let object = try JSONSupport.object(from: body)
            let result = try manager.projectStatus(projectID: try projectID(object))
            http.respondJSON(connection, status: 200, object: result)
        case ("POST", "/api/manager/projects/relink"):
            guard body.count <= Self.maximumProjectRelinkBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false,
                    "code": "project_relink_body_too_large",
                    "message": "Project relink accepts one bounded project, generation, and path",
                ])
                return
            }
            let object: [String: Any]
            do {
                object = try JSONSupport.object(from: body)
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_project_relink",
                    "message": "Project relink requires a JSON object",
                ])
                return
            }
            guard object.count == 3,
                  Set(object.keys) == ["project_id", "project_generation", "path"],
                  let path = object["path"] as? String,
                  !path.isEmpty,
                  path.utf8.count <= Self.maximumProjectRelinkPathBytes,
                  (path as NSString).isAbsolutePath else {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_project_relink",
                    "message": "Project relink requires exactly one project UUID, generation, and absolute path",
                ])
                return
            }
            do {
                let result = try manager.relinkProject(
                    projectID: try projectID(object),
                    expectedGeneration: try projectGeneration(object),
                    path: path
                )
                var response = try result.asDictionary()
                response.merge(
                    try manager.projectStatus(projectID: try projectID(object)),
                    uniquingKeysWith: { receipt, _ in receipt }
                )
                http.respondJSON(connection, status: 200, object: response)
            } catch let error as ProjectContextError {
                let status: Int
                switch error {
                case .invalidIdentifier, .invalidGeneration:
                    status = 400
                case .projectNotFound:
                    status = 404
                case .databaseBusy:
                    status = 503
                default:
                    status = 409
                }
                http.respondJSON(connection, status: status, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                    "retryable": error == .databaseBusy,
                    "reconciliation_required": error == .databaseBusy,
                ])
            } catch let error as ProjectMemoryError {
                let status: Int
                switch error {
                case .invalidRequest, .payloadTooLarge:
                    status = 400
                case .projectNotFound:
                    status = 404
                case .projectScopeMismatch, .conflict:
                    status = 409
                case .databaseBusy:
                    status = 503
                default:
                    status = 500
                }
                http.respondJSON(connection, status: status, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                    "retryable": error == .databaseBusy,
                    "reconciliation_required": error == .databaseBusy,
                ])
            }
        case ("POST", "/api/manager/projects/bind"):
            let object = try JSONSupport.object(from: body)
            guard let kindName = object["owner_kind"] as? String,
                  let ownerKind = ProjectBindingOwnerKind(rawValue: kindName),
                  let ownerID = object["owner_id"] as? String else {
                throw ProjectContextError.invalidIdentifier("binding owner")
            }
            let runID: RunID?
            if let runIDString = object["run_id"] as? String {
                guard let value = UUID(uuidString: runIDString) else {
                    throw ProjectContextError.invalidIdentifier("run identifier")
                }
                runID = RunID(value)
            } else {
                runID = nil
            }
            let allowedTools = Set((object["allowed_tools"] as? [String]) ?? ["*"])
            do {
                let result = try manager.bindProject(
                    projectID: try projectID(object),
                    expectedGeneration: try projectGeneration(object),
                    owner: ProjectBindingOwner(kind: ownerKind, id: ownerID),
                    runID: runID,
                    allowedTools: allowedTools,
                    networkAllowed: (object["network_allowed"] as? Bool) ?? false,
                    maximumInlineOutputBytes: integer(object["maximum_inline_output_bytes"])
                        ?? ProjectContextService.defaultInlineOutputLimit
                )
                http.respondJSON(connection, status: 200, object: result)
            } catch let error as ProjectContextError {
                guard case .projectRootNotAuthorized = error else { throw error }
                http.respondJSON(connection, status: 403, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                    "retryable": false,
                ])
            }
        case ("POST", "/api/manager/projects/reset-generation"):
            let object = try JSONSupport.object(from: body)
            let requestedProjectID = try projectID(object)
            var result = try manager.resetProjectGeneration(
                projectID: requestedProjectID,
                expectedGeneration: try projectGeneration(object)
            )
            result.merge(
                try manager.projectStatus(projectID: requestedProjectID),
                uniquingKeysWith: { receipt, _ in receipt }
            )
            http.respondJSON(connection, status: 200, object: result)
        case ("POST", "/api/manager/runtime-jobs/cancel"):
            guard body.count <= Self.maximumRuntimeJobCancelBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false,
                    "code": "runtime_job_cancel_body_too_large",
                    "message": "Runtime job cancellation accepts one bounded job identifier",
                ])
                return
            }
            let object: [String: Any]
            do {
                object = try JSONSupport.object(from: body)
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_runtime_job_cancel",
                    "message": "Runtime job cancellation requires a JSON object containing only job_id",
                ])
                return
            }
            guard object.count == 1,
                  Set(object.keys) == ["job_id"],
                  let jobIDValue = object["job_id"] as? String,
                  jobIDValue.utf8.count <= 36,
                  let jobID = UUID(uuidString: jobIDValue) else {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_runtime_job_cancel",
                    "message": "Runtime job cancellation requires exactly one UUID job_id",
                ])
                return
            }
            do {
                http.respondJSON(
                    connection,
                    status: 200,
                    object: try manager.cancelRuntimeJob(jobID: jobID).asDictionary()
                )
            } catch let error as RuntimeJobError {
                let status: Int
                switch error {
                case .jobNotFound:
                    status = 404
                case .invalidRequest, .jobScopeMismatch, .invalidTransition:
                    status = 409
                default:
                    status = 500
                }
                http.respondJSON(connection, status: status, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                ])
            } catch let error as ProjectContextError {
                http.respondJSON(connection, status: 409, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                ])
            }
        case ("POST", "/api/manager/provider/probe"):
            guard body.count <= Self.maximumProviderProbeBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false,
                    "code": "provider_probe_body_too_large",
                    "message": "Provider probing accepts one bounded adapter identifier and mode",
                ])
                return
            }
            let object: [String: Any]
            do {
                object = try JSONSupport.object(from: body)
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_provider_probe",
                    "message": "Provider probing requires a JSON object containing only adapter_id and mode",
                ])
                return
            }
            guard object.count == 2,
                  Set(object.keys) == ["adapter_id", "mode"],
                  let adapterID = object["adapter_id"] as? String,
                  adapterID.utf8.count <= ManagerNode.maximumProviderAdapterIDBytes,
                  let modeValue = object["mode"] as? String,
                  modeValue.utf8.count <= 16,
                  let mode = ManagerProviderProbeMode(rawValue: modeValue) else {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_provider_probe",
                    "message": "Provider probing requires one bounded adapter_id and an exact connection or contract mode",
                ])
                return
            }
            dispatchProviderProbe(
                adapterID: adapterID,
                mode: mode,
                connection: connection
            )
        case ("GET", "/api/manager/autonomy/status"):
            http.respondJSON(
                connection,
                status: 200,
                object: try manager.managedAutonomyStatus()
            )
        case ("POST", "/api/manager/runs/start"):
            let object = try JSONSupport.object(from: body)
            guard let runIDValue = object["run_id"] as? String,
                  let runUUID = UUID(uuidString: runIDValue),
                  let mission = object["mission"] as? String, !mission.isEmpty,
                  let modelKey = object["model_key"] as? String, !modelKey.isEmpty,
                  let allowedToolValues = object["allowed_tools"] as? [String],
                  !allowedToolValues.isEmpty,
                  let completionGates = object["completion_gates"] as? [String],
                  !completionGates.isEmpty else {
                throw AutonomyError.invalidRequest(
                    "run_id, mission, model_key, allowed_tools, and completion_gates are required"
                )
            }
            do {
                let result = try manager.startAutonomousRun(
                    runID: RunID(runUUID),
                    projectID: try projectID(object),
                    expectedGeneration: try projectGeneration(object),
                    assignmentID: object["assignment_id"] as? String,
                    mission: mission,
                    providerID: object["provider_id"] as? String ?? "lmstudio",
                    adapterID: object["adapter_id"] as? String ?? "forge.native-session-host",
                    modelKey: modelKey,
                    allowedTools: Set(allowedToolValues),
                    completionGates: completionGates,
                    networkAllowed: (object["network_allowed"] as? Bool) ?? false,
                    maximumInlineOutputBytes: integer(object["maximum_inline_output_bytes"])
                        ?? ProjectContextService.defaultInlineOutputLimit
                )
                http.respondJSON(connection, status: 202, object: result)
            } catch let error as AutonomyError {
                guard case .invalidToolConfiguration = error else { throw error }
                http.respondJSON(connection, status: 422, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                    "retryable": false,
                ])
            } catch let error as ProjectContextError {
                guard case .projectRootNotAuthorized = error else { throw error }
                http.respondJSON(connection, status: 403, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                    "retryable": false,
                ])
            }
        case ("POST", "/api/manager/runs/status"):
            let object = try JSONSupport.object(from: body)
            http.respondJSON(
                connection,
                status: 200,
                object: try manager.autonomousRunStatus(runID: try runID(object))
            )
        case ("POST", "/api/manager/runs/control"):
            guard body.count <= Self.maximumRunControlBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false,
                    "code": "run_control_body_too_large",
                    "message": "Run control accepts one bounded run identifier and action",
                ])
                return
            }
            let object: [String: Any]
            do {
                object = try JSONSupport.object(from: body)
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_run_control",
                    "message": "Run control requires a JSON object containing only run_id and action",
                ])
                return
            }
            guard object.count == 2,
                  Set(object.keys) == ["run_id", "action"],
                  let runIDValue = object["run_id"] as? String,
                  runIDValue.utf8.count <= 36,
                  let runUUID = UUID(uuidString: runIDValue),
                  let actionValue = object["action"] as? String,
                  actionValue.utf8.count <= 16,
                  let action = ManagedAutonomyControlAction(rawValue: actionValue) else {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_run_control",
                    "message": "Run control requires exactly one UUID run_id and an exact pause, resume, cancel, retry, checkpoint, or rollover action",
                ])
                return
            }
            do {
                http.respondJSON(
                    connection,
                    status: 200,
                    object: try manager.controlAutonomousRun(
                        runID: RunID(runUUID),
                        action: action
                    )
                )
            } catch let error as AutonomyError {
                let status: Int
                switch error {
                case .runNotFound:
                    status = 404
                case .shutdown:
                    status = 503
                default:
                    status = 409
                }
                http.respondJSON(connection, status: status, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                ])
            } catch let error as ContextBudgetError {
                http.respondJSON(connection, status: 409, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                ])
            }
        default:
            http.respond(connection, status: 404, body: "Not Found", contentType: "text/plain")
        }
    }

    private func dispatchProviderConfiguration(method: String, path: String, body: Data, connection: NWConnection) {
        let manager = self.manager
        let http = self.http
        guard body.count <= 16 * 1024 else {
            http.respondJSON(connection, status: 413, object: ["ok": false, "message": "Provider configuration request is oversized"])
            return
        }
        Self.providerProbeQueue.async {
            do {
                let data: Data
                if method == "PUT" {
                    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                          Set(object.keys).isSubset(of: ["expectedRevision", "endpoint", "modelKey", "credentialAction", "token"]),
                          let update = try? JSONDecoder().decode(ProviderConfigurationUpdate.self, from: body) else {
                        throw ProviderConfigurationError.invalidRequest
                    }
                    data = try JSONEncoder().encode(manager.updateProviderConfiguration(update))
                } else if path.hasSuffix("/models") {
                    data = try JSONEncoder().encode(manager.providerModels())
                } else {
                    data = try JSONEncoder().encode(manager.readProviderConfiguration())
                }
                let object = try JSONSupport.object(from: data)
                http.respondJSON(connection, status: 200, object: object)
            } catch let error as ProviderConfigurationError {
                let status: Int
                switch error {
                case .invalidRequest: status = 400
                case .busy, .revisionConflict: status = 409
                case .credentialUnavailable: status = 422
                case .unavailable: status = 503
                case .persistenceFailed: status = 500
                case .authenticationFailed, .offline, .timeout, .modelEndpointUnavailable, .connectionFailed: status = 502
                }
                http.respondJSON(connection, status: status, object: [
                    "ok": false, "code": "provider_configuration_" + error.rawValue,
                    "message": error.localizedDescription,
                ])
            } catch {
                // Provider payloads and arbitrary localized errors are not an
                // approved diagnostic channel for credential material.
                http.respondJSON(connection, status: 502, object: [
                    "ok": false, "code": "provider_configuration_connection_failed",
                    "message": "Cannot retrieve provider models. Check the server, credential, and connection, then retry.",
                ])
            }
        }
    }

    private func dispatchProviderProbe(
        adapterID: String,
        mode: ManagerProviderProbeMode,
        connection: NWConnection
    ) {
        let manager = self.manager
        let http = self.http
        Self.providerProbeQueue.async {
            do {
                http.respondJSON(
                    connection,
                    status: 200,
                    object: try manager.probeProvider(
                        adapterID: adapterID,
                        mode: mode
                    ).asDictionary()
                )
            } catch let error as ManagerProviderProbeError {
                let status: Int
                switch error {
                case .invalidAdapterIdentifier:
                    status = 400
                case .adapterNotRegistered:
                    status = 404
                case .managedProviderUnavailable, .probeInProgress, .storageUnavailable:
                    status = 409
                case .connectionFailed:
                    status = 502
                case .contractUnavailable:
                    status = 422
                }
                http.respondJSON(connection, status: status, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                ])
            } catch {
                http.respondJSON(connection, status: 500, object: [
                    "ok": false,
                    "message": "\(error)",
                ])
            }
        }
    }

    private func projectID(_ object: [String: Any]) throws -> ProjectID {
        guard let value = object["project_id"] as? String,
              let identifier = UUID(uuidString: value) else {
            throw ProjectContextError.invalidIdentifier("project identifier")
        }
        return ProjectID(identifier)
    }

    private func projectGeneration(_ object: [String: Any]) throws -> ProjectGeneration {
        guard let value = integer(object["project_generation"]), value > 0 else {
            throw ProjectContextError.invalidGeneration(0)
        }
        return ProjectGeneration(UInt64(value))
    }

    private func runID(_ object: [String: Any]) throws -> RunID {
        guard let value = object["run_id"] as? String,
              let identifier = UUID(uuidString: value) else {
            throw ProjectContextError.invalidIdentifier("run identifier")
        }
        return RunID(identifier)
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func routeTarget(_ rawTarget: String) throws -> ManagerRouteTarget {
        guard !rawTarget.isEmpty, rawTarget.utf8.count <= 4_096,
              let components = URLComponents(string: rawTarget),
              components.scheme == nil, components.host == nil,
              components.fragment == nil, !components.path.isEmpty else {
            throw ManagerOperatorSnapshotQueryError.invalidTarget
        }
        return ManagerRouteTarget(
            path: components.path,
            queryItems: components.queryItems ?? []
        )
    }

    private static func operatorSnapshotQuery(
        _ items: [URLQueryItem]
    ) throws -> ManagerOperatorSnapshotQuery {
        guard items.allSatisfy({ $0.name == "limit" || $0.name == "cursor" }),
              items.filter({ $0.name == "limit" }).count <= 1,
              items.filter({ $0.name == "cursor" }).count <= 1 else {
            throw ManagerOperatorSnapshotQueryError.invalidParameter
        }
        let limit: Int
        if let item = items.first(where: { $0.name == "limit" }) {
            guard let value = item.value, Self.isDecimal(value, maximumDigits: 3),
                  let parsed = Int(value), (1...100).contains(parsed) else {
                throw ManagerOperatorSnapshotQueryError.invalidParameter
            }
            limit = parsed
        } else {
            limit = 50
        }
        let cursor: Int64?
        if let item = items.first(where: { $0.name == "cursor" }) {
            guard let value = item.value, Self.isDecimal(value, maximumDigits: 19),
                  let parsed = Int64(value), parsed > 0 else {
                throw ManagerOperatorSnapshotQueryError.invalidParameter
            }
            cursor = parsed
        } else {
            cursor = nil
        }
        return ManagerOperatorSnapshotQuery(limit: limit, cursor: cursor)
    }

    private static func isDecimal(_ value: String, maximumDigits: Int) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= maximumDigits
            && bytes.allSatisfy { (48...57).contains($0) }
    }

}

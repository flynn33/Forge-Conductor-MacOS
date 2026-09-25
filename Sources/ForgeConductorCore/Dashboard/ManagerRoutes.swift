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
             ("GET", "/api/manager/stjornarvald/snapshot"),
             ("POST", "/api/manager/stjornarvald/violations"),
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

private struct ManagerOperatorActivityQuery {
    let limit: Int
    let cursor: Int64?
    let runID: String
    let projectID: String
    let projectGeneration: UInt64
}

private struct ManagerStjornarvaldSnapshotQuery {
    let limit: Int
    let cursor: Int64?
    let newestFirst: Bool
    let projectID: String?
    let projectGeneration: UInt64?
}

private struct StjornarvaldObservationSubmitRequest: Decodable {
    let processID: String
    let bootID: String
    let observations: [DevelopmentObservation]

    enum CodingKeys: String, CodingKey {
        case processID = "process_id"
        case bootID = "boot_id"
        case observations
    }
}

private struct StjornarvaldPendingNoticeRequest: Decodable {
    let deliveryID: String
    let projectID: String?
    let projectGeneration: Int?
    let runID: String?
    let sessionID: String?
    let clientID: String?
    let maximumCount: Int
    let maximumBytes: Int

    enum CodingKeys: String, CodingKey {
        case deliveryID = "delivery_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case runID = "run_id"
        case sessionID = "session_id"
        case clientID = "client_id"
        case maximumCount = "maximum_count"
        case maximumBytes = "maximum_bytes"
    }
}

private struct StjornarvaldPresentedNoticeRequest: Decodable {
    let requestID: UUID
    let deliveryIDs: [String]

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case deliveryIDs = "delivery_ids"
    }
}

private struct StjornarvaldScanRequest: Decodable {
    let requestID: UUID
    let projectID: String?
    let projectGeneration: Int?
    let reason: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case reason
    }
}

private struct StjornarvaldViolationPageRequest: Decodable {
    let cursor: Int64
    let limit: Int
    let projectID: String?
    let state: PolicyViolationProjectionState?

    enum CodingKeys: String, CodingKey {
        case cursor, limit, state
        case projectID = "project_id"
    }
}

private struct StjornarvaldExportRequest: Decodable {
    let requestID: UUID
    let format: StjornarvaldExportFormat
    let destination: String?
    let filters: StjornarvaldExportFilters?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case format, destination, filters
    }
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

private enum ManagerStjornarvaldSnapshotQueryError: Error, LocalizedError {
    case invalidParameter
    case cursorWithNewestOrder

    var errorDescription: String? {
        switch self {
        case .invalidParameter:
            "Stjornarvald snapshot accepts one limit from 1 through 100, one positive cursor, and order=newest"
        case .cursorWithNewestOrder:
            "Stjornarvald snapshot cursor cannot be combined with order=newest"
        }
    }
}

private enum ManagerProviderIntegrationRoute {
    case snapshot
    case select
    case operation(operationID: String)
    case cancel(operationID: String)
    case repair(pathProviderID: String)
    case remove(pathProviderID: String)
}

/// Manager control plane routes: start/stop/restart/settings/shutdown.
public final class ManagerRoutes: @unchecked Sendable {
    public static let maximumProjectRegistrationPathBytes = 4_096
    static let maximumProjectRegistrationBodyBytes = 16_384
    public static let maximumProjectRelinkPathBytes = 4_096
    static let maximumProjectRelinkBodyBytes = 16_384
    static let maximumProjectContentClearBodyBytes = 512
    static let maximumInstructionQueueBodyBytes = 16_384
    static let maximumRuntimeJobCancelBodyBytes = 256
    static let maximumProviderProbeBodyBytes = 512
    static let maximumProviderIntegrationBodyBytes = 16_384
    static let maximumRunControlBodyBytes = 256
    static let maximumRunDeletionBodyBytes = 256
    static let maximumToolPermissionBodyBytes = 128 * 1_024
    static let maximumRunAdmissionBodyBytes = 128 * 1_024
    static let maximumStjornarvaldMutationBodyBytes = 16 * 1_024
    static let maximumStjornarvaldObservationBodyBytes = 1_048_576
    /// Provider I/O is intentionally isolated from `DashboardServer`'s serial
    /// listener queue. The active-connection cap bounds submitted work, while
    /// `ManagerNode` rejects overlapping probes and owns the operation deadline.
    // Claim admission before dispatch so connection churn cannot queue retained
    // token-bearing request bodies behind blocked provider or Keychain work.
    private static let providerOperationAdmission = DispatchSemaphore(value: 1)
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
        additionalMutationAuthorization: Bool = false,
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
           !additionalMutationAuthorization,
           !authorizer.authorizes(headers["authorization"]) {
            http.respondJSON(connection, status: 401, object: [
                "ok": false,
                "code": "manager_mutation_unauthorized",
                "message": "Manager mutation authorization is required",
            ])
            return
        }
        if let providerRoute = Self.providerIntegrationRoute(
            method: method,
            path: target.path
        ) {
            dispatchProviderIntegration(
                providerRoute,
                queryItems: target.queryItems,
                body: body,
                connection: connection
            )
            return
        }
        switch (method, target.path) {
        case ("POST", "/api/manager/providers/hooks"):
            dispatchDesktopProviderHook(
                queryItems: target.queryItems,
                body: body,
                connection: connection
            )
        case ("POST", "/api/manager/continuity/tasks/prepare"),
             ("POST", "/api/manager/continuity/tasks/rotate"),
             ("POST", "/api/manager/continuity/tasks/revoke"):
            guard target.queryItems.isEmpty else {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false, "code": "invalid_native_task_request",
                    "message": "Native task commands do not accept query parameters",
                ])
                return
            }
            dispatchNativeTaskCommand(action: String(target.path.split(separator: "/").last ?? ""),
                body: body, connection: connection)
        case ("POST", "/api/manager/continuity/source/send"),
             ("POST", "/api/manager/continuity/source/status"),
             ("POST", "/api/manager/continuity/source/cancel"):
            guard target.queryItems.isEmpty else {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false, "code": "invalid_source_request",
                    "message": "Native source commands do not accept query parameters",
                ])
                return
            }
            dispatchNativeSourceCommand(action: String(target.path.split(separator: "/").last ?? ""),
                body: body, connection: connection)
        case ("GET", "/api/manager/provider/configuration"),
             ("PUT", "/api/manager/provider/configuration"),
             ("GET", "/api/manager/provider/models"),
             ("POST", "/api/manager/provider/prepare"):
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
        case ("GET", "/api/manager/operator/activity"):
            do {
                let query = try Self.operatorActivityQuery(target.queryItems)
                http.respondJSON(
                    connection,
                    status: 200,
                    object: try manager.operatorSnapshotDictionary(
                        limit: query.limit,
                        beforeEventSequence: query.cursor,
                        includeActivity: true,
                        activityRunID: query.runID,
                        activityProjectID: query.projectID,
                        activityProjectGeneration: query.projectGeneration
                    )
                )
            } catch let error as ManagerOperatorSnapshotQueryError {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_activity_query",
                    "message": error.localizedDescription,
                ])
            } catch let error as ProjectContextError {
                http.respondJSON(connection, status: 409, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                ])
            } catch let error as AutonomyError {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                ])
            } catch {
                http.respondJSON(connection, status: 503, object: [
                    "ok": false,
                    "code": "operator_activity_unavailable",
                    "message": error.localizedDescription,
                ])
            }
        case ("GET", "/api/manager/stjornarvald/snapshot"):
            do {
                let query = try Self.stjornarvaldSnapshotQuery(target.queryItems)
                http.respondJSON(
                    connection,
                    status: 200,
                    object: try manager.stjornarvaldSnapshotDictionary(
                        eventCursor: query.cursor ?? 0,
                        limit: query.limit,
                        newestFirst: query.newestFirst,
                        projectID: query.projectID,
                        projectGeneration: query.projectGeneration
                    )
                )
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_stjornarvald_snapshot",
                    "message": error.localizedDescription,
                ])
            }
        case ("POST", "/api/manager/stjornarvald/sources/add"):
            guard body.count <= Self.maximumStjornarvaldMutationBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false, "code": "stjornarvald_request_too_large",
                    "message": "Stjornarvald source request exceeds its byte bound",
                ])
                return
            }
            do {
                let object = try JSONSupport.object(from: body)
                guard Set(object.keys).isSubset(of: ["request_id", "selected_path"]),
                      let request = object["request_id"] as? String,
                      let requestID = UUID(uuidString: request),
                      let path = object["selected_path"] as? String,
                      !path.isEmpty,
                      path.utf8.count <= Self.maximumProjectRegistrationPathBytes,
                      (path as NSString).isAbsolutePath else {
                    throw StjornarvaldPolicySourceError.invalidRequest(
                        "source add requires a request ID and bounded absolute selected path"
                    )
                }
                http.respondJSON(
                    connection,
                    status: 200,
                    object: try manager.stjornarvaldAddSource(
                        selectedPath: path,
                        requestID: requestID
                    )
                )
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false, "code": "invalid_stjornarvald_source_add",
                    "message": error.localizedDescription,
                ])
            }
        case ("POST", "/api/manager/stjornarvald/sources/refresh"),
             ("POST", "/api/manager/stjornarvald/sources/remove"):
            guard body.count <= Self.maximumStjornarvaldMutationBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false, "code": "stjornarvald_request_too_large",
                    "message": "Stjornarvald source request exceeds its byte bound",
                ])
                return
            }
            do {
                let object = try JSONSupport.object(from: body)
                guard Set(object.keys).isSubset(of: ["request_id", "source_id"]),
                      let request = object["request_id"] as? String,
                      let requestID = UUID(uuidString: request),
                      let source = object["source_id"] as? String,
                      let sourceUUID = UUID(uuidString: source) else {
                    throw StjornarvaldPolicySourceError.invalidRequest(
                        "source mutation requires request and source IDs"
                    )
                }
                let sourceID = PolicySourceID(sourceUUID)
                let response = target.path.hasSuffix("/refresh")
                    ? try manager.stjornarvaldRefreshSource(
                        sourceID: sourceID, requestID: requestID
                    )
                    : try manager.stjornarvaldRemoveSource(
                        sourceID: sourceID, requestID: requestID
                    )
                http.respondJSON(connection, status: 200, object: response)
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false, "code": "invalid_stjornarvald_source_mutation",
                    "message": error.localizedDescription,
                ])
            }
        case ("POST", "/api/manager/stjornarvald/scan"):
            guard body.count <= Self.maximumStjornarvaldMutationBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false, "code": "stjornarvald_scan_request_too_large",
                    "message": "Scan request exceeds its byte bound",
                ])
                return
            }
            do {
                let request = try JSONDecoder().decode(StjornarvaldScanRequest.self, from: body)
                http.respondJSON(
                    connection,
                    status: 200,
                    object: try manager.stjornarvaldScheduleScan(
                        requestID: request.requestID,
                        projectID: request.projectID,
                        projectGeneration: request.projectGeneration,
                        reason: request.reason
                    )
                )
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false, "code": "invalid_stjornarvald_scan_request",
                    "message": error.localizedDescription,
                ])
            }
        case ("POST", "/api/manager/stjornarvald/violations"):
            guard body.count <= Self.maximumStjornarvaldMutationBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false, "code": "stjornarvald_violation_request_too_large",
                    "message": "Violation page request exceeds its byte bound",
                ])
                return
            }
            do {
                let request = try JSONDecoder().decode(
                    StjornarvaldViolationPageRequest.self,
                    from: body
                )
                http.respondJSON(
                    connection,
                    status: 200,
                    object: try manager.stjornarvaldViolationPage(
                        cursor: request.cursor,
                        limit: request.limit,
                        projectID: request.projectID,
                        state: request.state
                    )
                )
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false, "code": "invalid_stjornarvald_violation_request",
                    "message": error.localizedDescription,
                ])
            }
        case ("POST", "/api/manager/stjornarvald/export"):
            guard body.count <= Self.maximumStjornarvaldMutationBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false, "code": "stjornarvald_export_request_too_large",
                    "message": "Export request exceeds its byte bound",
                ])
                return
            }
            do {
                let request = try JSONDecoder().decode(StjornarvaldExportRequest.self, from: body)
                http.respondJSON(
                    connection,
                    status: 200,
                    object: try manager.stjornarvaldExportReceipt(
                        requestID: request.requestID,
                        format: request.format,
                        destination: request.destination,
                        filters: request.filters ?? StjornarvaldExportFilters()
                    )
                )
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false, "code": "invalid_stjornarvald_export_request",
                    "message": error.localizedDescription,
                ])
            }
        case ("POST", "/api/manager/stjornarvald/observations/submit"):
            guard body.count <= Self.maximumStjornarvaldObservationBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false, "code": "stjornarvald_observation_body_too_large",
                    "message": "Observation submission exceeds its byte bound",
                ])
                return
            }
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let request = try decoder.decode(
                    StjornarvaldObservationSubmitRequest.self,
                    from: body
                )
                guard !request.processID.isEmpty, request.processID.utf8.count <= 256,
                      !request.bootID.isEmpty, request.bootID.utf8.count <= 256,
                      !request.observations.isEmpty, request.observations.count <= 64 else {
                    throw StjornarvaldObservationError.invalidObservation(
                        "observation batch identity or count is outside bounds"
                    )
                }
                http.respondJSON(
                    connection,
                    status: 200,
                    object: try manager.stjornarvaldSubmitObservations(request.observations)
                )
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false, "code": "invalid_stjornarvald_observation_batch",
                    "message": error.localizedDescription,
                ])
            }
        case ("POST", "/api/manager/stjornarvald/notices/pending"):
            guard body.count <= Self.maximumStjornarvaldMutationBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false, "code": "stjornarvald_notice_request_too_large",
                    "message": "Pending-notice request exceeds its byte bound",
                ])
                return
            }
            do {
                let request = try JSONDecoder().decode(
                    StjornarvaldPendingNoticeRequest.self,
                    from: body
                )
                guard (1...64).contains(request.maximumCount),
                      (512...StjornarvaldPolicyNoticeFormatter.maximumPresentationBytes)
                        .contains(request.maximumBytes),
                      !request.deliveryID.isEmpty,
                      request.deliveryID.utf8.count <= 1_024 else {
                    throw StjornarvaldPolicyNoticeError.invalid(
                        "pending-notice limits are outside bounds"
                    )
                }
                http.respondJSON(
                    connection,
                    status: 200,
                    object: try manager.stjornarvaldPendingNotices(
                        deliveryID: request.deliveryID,
                        projectID: request.projectID,
                        projectGeneration: request.projectGeneration,
                        runID: request.runID,
                        sessionID: request.sessionID,
                        clientID: request.clientID,
                        maximumCount: request.maximumCount,
                        maximumBytes: request.maximumBytes
                    )
                )
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false, "code": "invalid_stjornarvald_notice_request",
                    "message": error.localizedDescription,
                ])
            }
        case ("POST", "/api/manager/stjornarvald/notices/presented"):
            guard body.count <= Self.maximumStjornarvaldMutationBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false, "code": "stjornarvald_notice_receipt_too_large",
                    "message": "Notice receipt exceeds its byte bound",
                ])
                return
            }
            do {
                let request = try JSONDecoder().decode(
                    StjornarvaldPresentedNoticeRequest.self,
                    from: body
                )
                guard !request.deliveryIDs.isEmpty, request.deliveryIDs.count <= 64,
                      Set(request.deliveryIDs).count == request.deliveryIDs.count,
                      request.deliveryIDs.allSatisfy({
                        !$0.isEmpty && $0.utf8.count <= 1_024
                      }) else {
                    throw StjornarvaldPolicyNoticeError.invalid(
                        "notice receipt identities are outside bounds"
                    )
                }
                let response = try manager.stjornarvaldMarkNoticesPresented(
                    requestID: request.requestID,
                    deliveryIDs: request.deliveryIDs
                )
                http.respondJSON(connection, status: 200, object: response)
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false, "code": "invalid_stjornarvald_notice_receipt",
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
            do {
                guard body.count <= 65_536 else {
                    throw ManagerSettingsValidationError(field: "settings", reason: "body_too_large")
                }
                let validatedBody = try BudgetPolicyUpdate.validateSettingsJSON(body)
                guard let obj = (try? JSONSerialization.jsonObject(with: validatedBody)) as? [String: Any] else {
                    throw ManagerSettingsValidationError(field: "settings", reason: "expected_json_object")
                }
                if let settings = obj["settings"], !(settings is [String: Any]) {
                    throw ManagerSettingsValidationError(field: "settings", reason: "expected_object")
                }
                if obj["settings"] != nil {
                    var envelope = obj
                    envelope.removeValue(forKey: "settings")
                    try ManagerSettingsNormalizer.validateLegacyBudgetKeys(envelope)
                }
                let apply = (obj["apply"] as? Bool) ?? true
                let patch = obj["settings"] as? [String: Any] ?? obj
                let result = try manager.updateSettings(patch, apply: apply)
                http.respondJSON(connection, status: 200, object: result)
            } catch let error as ManagerSettingsValidationError {
                http.respondJSON(connection, status: 400, object: error.asDictionary())
            } catch let error as BudgetPolicyConflict {
                http.respondJSON(connection, status: 409, object: [
                    "ok": false, "code": "budget_policy_conflict", "message": error.localizedDescription,
                    "current_policy": try JSONSupport.object(from: JSONEncoder().encode(error.current)),
                ])
            }
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
            let allowedKeys = Set([
                "path", "display_name", "repository_identity", "authorize_project_root",
            ])
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
                  }) ?? true,
                  object["authorize_project_root"].map({ $0 is Bool }) ?? true else {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_project_registration",
                    "message": "Project registration requires one bounded absolute path, bounded optional identity fields, and an optional Boolean project-root authorization",
                ])
                return
            }
            do {
                if object["authorize_project_root"] as? Bool == true {
                    _ = try manager.authorizeProjectRoot(path: path)
                }
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
            } catch let error as ManagerSettingsValidationError {
                http.respondJSON(connection, status: 400, object: error.asDictionary())
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
        case ("POST", "/api/manager/projects/remove"):
            dispatchProjectRemoval(body: body, connection: connection)
        case ("POST", "/api/manager/projects/instruction-packages"),
             ("POST", "/api/manager/projects/instruction-packages/import"),
             ("POST", "/api/manager/projects/instruction-packages/reorder"),
             ("POST", "/api/manager/projects/instruction-packages/remove"),
             ("POST", "/api/manager/projects/instruction-packages/start"),
             ("POST", "/api/manager/projects/instruction-packages/stop"):
            dispatchInstructionQueue(path: target.path, body: body, connection: connection)
        case ("POST", "/api/manager/projects/clear-content"):
            guard target.queryItems.isEmpty,
                  body.count <= Self.maximumProjectContentClearBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false,
                    "code": "project_content_clear_body_too_large",
                    "message": "Project content clearing accepts one bounded operation request",
                ])
                return
            }
            let object: [String: Any]
            do {
                object = try JSONSupport.object(from: body)
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_project_content_clear",
                    "message": "Project content clearing requires a JSON object",
                ])
                return
            }
            guard object.count == 4,
                  Set(object.keys) == [
                    "operation_id", "project_id", "project_generation", "mode",
                  ],
                  let operationValue = object["operation_id"] as? String,
                  operationValue.utf8.count <= 36,
                  let operationID = UUID(uuidString: operationValue),
                  let projectValue = object["project_id"] as? String,
                  projectValue.utf8.count <= 36,
                  let projectUUID = UUID(uuidString: projectValue),
                  let generationValue = integer(object["project_generation"]),
                  generationValue > 0,
                  let modeValue = object["mode"] as? String,
                  modeValue.utf8.count <= 32,
                  let mode = ProjectContentClearMode(rawValue: modeValue) else {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_project_content_clear",
                    "message": "Project content clearing requires exactly one operation UUID, project UUID, generation, and supported mode",
                ])
                return
            }
            do {
                let receipt = try manager.clearProjectContent(
                    ProjectContentClearRequest(
                        operationID: operationID,
                        projectID: ProjectID(projectUUID),
                        expectedGeneration: ProjectGeneration(UInt64(generationValue)),
                        mode: mode
                    )
                )
                http.respondJSON(connection, status: 200, object: receipt.asDictionary())
            } catch let error as ProjectContextError {
                let status: Int
                switch error {
                case .projectNotFound:
                    status = 404
                case .databaseBusy:
                    status = 503
                case .projectTransitionConflict, .projectNotActive, .staleProjectGeneration,
                     .retainedFilesystemRecovery:
                    status = 409
                case .invalidIdentifier, .invalidGeneration:
                    status = 400
                default:
                    status = 500
                }
                http.respondJSON(connection, status: status, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                    "retryable": error == .databaseBusy,
                    "reconciliation_required": status == 409 || error == .databaseBusy,
                ])
            }
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
        case ("POST", "/api/manager/projects/tool-permissions/status"):
            guard body.count <= Self.maximumToolPermissionBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false,
                    "code": "tool_permission_body_too_large",
                    "message": "Tool permission requests must remain bounded",
                ])
                return
            }
            let object = try JSONSupport.object(from: body)
            let snapshot = try manager.projectToolPermissions(
                projectID: try projectID(object),
                expectedGeneration: try projectGeneration(object)
            )
            http.respondJSON(connection, status: 200, object: try snapshot.asDictionary())
        case ("PUT", "/api/manager/projects/tool-permissions"):
            guard body.count <= Self.maximumToolPermissionBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false,
                    "code": "tool_permission_body_too_large",
                    "message": "Tool permission updates must remain bounded",
                ])
                return
            }
            do {
                let request = try JSONDecoder().decode(
                    ManagerToolPermissionUpdate.self,
                    from: body
                )
                let snapshot = try manager.updateProjectToolPermissions(request)
                http.respondJSON(
                    connection,
                    status: 200,
                    object: try snapshot.asDictionary()
                )
            } catch let error as ToolPermissionStoreError {
                let status: Int
                let code: String
                switch error {
                case .staleRevision:
                    status = 409
                    code = "tool_permission_revision_stale"
                case .invalidPersistence:
                    status = 503
                    code = "tool_permission_store_unavailable"
                case .invalidSelection:
                    status = 422
                    code = "tool_permission_selection_invalid"
                }
                http.respondJSON(connection, status: status, object: [
                    "ok": false,
                    "code": code,
                    "message": error.localizedDescription,
                ])
            }
        case ("POST", "/api/manager/runs/instruction-artifacts/import"):
            guard body.count <= Self.maximumInstructionQueueBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false,
                    "code": "run_instruction_import_body_too_large",
                    "message": "Run instruction import accepts bounded identities and a source path",
                ])
                return
            }
            let object: [String: Any]
            do {
                object = try JSONSupport.object(from: body)
            } catch {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_run_instruction_import",
                    "message": "Run instruction import requires one bounded JSON object",
                ])
                return
            }
            let allowedKeys: Set<String> = [
                "run_id", "project_id", "project_generation", "source_path", "package_ids",
            ]
            guard Set(object.keys).isSubset(of: allowedKeys),
                  Set(object.keys).isSuperset(of: [
                    "run_id", "project_id", "project_generation",
                  ]),
                  let runIDValue = object["run_id"] as? String,
                  let runUUID = UUID(uuidString: runIDValue) else {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": "invalid_run_instruction_import",
                    "message": "Run instruction import requires exact run, project, and generation fields plus a source or packages",
                ])
                return
            }
            let sourcePath = try optionalString(
                object,
                key: "source_path",
                maximumBytes: 4_096
            )
            let rawPackageIDs: [String]
            if let value = object["package_ids"] {
                guard let values = value as? [String],
                      values.count <= ProjectInstructionQueueStore.maximumRunArtifactInputs,
                      Set(values.map { $0.lowercased() }).count == values.count,
                      values.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                    throw AutonomyError.invalidRequest(
                        "package_ids must contain unique bounded UUID strings"
                    )
                }
                rawPackageIDs = values
            } else {
                rawPackageIDs = []
            }
            do {
                let artifact = try manager.assembleRunInstructionArtifact(
                    sourcePath: sourcePath,
                    packageIDs: rawPackageIDs.compactMap(UUID.init(uuidString:)),
                    projectID: try projectID(object),
                    expectedGeneration: try projectGeneration(object),
                    runID: RunID(runUUID)
                )
                http.respondJSON(connection, status: 201, object: artifact)
            } catch let error as ProjectInstructionQueueError {
                let status: Int
                switch error {
                case .sourceUnavailable, .packageNotFound:
                    status = 404
                case .invalidRequest, .sourceTypeUnsupported, .sourceContainsLink,
                     .manifestInvalid:
                    status = 422
                case .storageFailure:
                    status = 500
                case .activePackage, .staleRevision, .staleProjectGeneration,
                     .queueAlreadyRunning, .queueNotRunning, .queueBlocked:
                    status = 409
                }
                http.respondJSON(connection, status: status, object: [
                    "ok": false,
                    "code": "run_instruction_import_failed",
                    "message": error.localizedDescription,
                ])
            } catch let error as ProjectContextError {
                let busy = error == .databaseBusy
                http.respondJSON(connection, status: busy ? 503 : 409, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                    "retryable": busy,
                ])
            }
        case ("POST", "/api/manager/runs/prepare"):
            guard body.count <= Self.maximumRunAdmissionBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false,
                    "code": "run_preparation_body_too_large",
                    "message": "Run preparation requires a bounded mission or instruction artifact reference",
                ])
                return
            }
            let object = try JSONSupport.object(from: body)
            guard let mission = object["mission"] as? String, !mission.isEmpty else {
                throw AutonomyError.invalidRequest("mission is required")
            }
            let preparationRunID: RunID?
            if let value = object["run_id"] {
                guard let string = value as? String,
                      string.utf8.count <= 36,
                      let identifier = UUID(uuidString: string) else {
                    throw AutonomyError.invalidRequest(
                        "run_id must be a UUID when supplied"
                    )
                }
                preparationRunID = RunID(identifier)
            } else { preparationRunID = nil }
            let instructionArtifactSHA256 = try optionalSHA256(
                object,
                key: "instruction_artifact_sha256"
            )
            let providerID = try optionalString(object, key: "provider_id", maximumBytes: 256)
            let adapterID = try optionalString(
                object,
                key: "adapter_id",
                maximumBytes: ManagerNode.maximumProviderAdapterIDBytes
            )
            let modelKey = try optionalString(object, key: "model_key", maximumBytes: 1_024)
            let allowedTools = try optionalStringSet(object, key: "allowed_tools")
            let completionGates = try optionalStringArray(object, key: "completion_gates")
            let failurePolicy = try failurePolicy(object)
            let networkAllowed = try optionalBoolean(object, key: "network_allowed") ?? false
            let runProjectID = try projectID(object)
            let runProjectGeneration = try projectGeneration(object)
            let assignmentID = try optionalString(
                object,
                key: "assignment_id",
                maximumBytes: 1_024
            )
            let maximumInlineOutputBytes = integer(object["maximum_inline_output_bytes"])
                ?? ProjectContextService.defaultInlineOutputLimit
            guard Self.providerOperationAdmission.wait(timeout: .now()) == .success else {
                http.respondJSON(connection, status: 409, object: [
                    "ok": false,
                    "code": "provider_readiness_busy",
                    "message": "A provider readiness check is already in progress. Retry after it settles.",
                    "retryable": true,
                ])
                return
            }
            Self.providerProbeQueue.async { [self] in
                defer { Self.providerOperationAdmission.signal() }
                let result = manager.inspectAutonomousRunPreparation(
                    runID: preparationRunID,
                    projectID: runProjectID,
                    expectedGeneration: runProjectGeneration,
                    assignmentID: assignmentID,
                    mission: mission,
                    instructionArtifactSHA256: instructionArtifactSHA256,
                    providerID: providerID,
                    adapterID: adapterID,
                    modelKey: modelKey,
                    allowedTools: allowedTools,
                    completionGates: completionGates,
                    failurePolicy: failurePolicy,
                    networkAllowed: networkAllowed,
                    maximumInlineOutputBytes: maximumInlineOutputBytes
                )
                do {
                    try http.respondJSON(
                        connection,
                        status: 200,
                        object: result.asDictionary()
                    )
                } catch {
                    http.respondJSON(connection, status: 500, object: [
                        "ok": false,
                        "code": "run_preparation_response_failed",
                        "message": "Run preparation completed but its bounded response could not be encoded.",
                    ])
                }
            }
        case ("POST", "/api/manager/runs/start"):
            guard body.count <= Self.maximumRunAdmissionBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false,
                    "code": "run_start_body_too_large",
                    "message": "Run Start requires a bounded mission or instruction artifact reference",
                ])
                return
            }
            let object = try JSONSupport.object(from: body)
            guard let runIDValue = object["run_id"] as? String,
                  let runUUID = UUID(uuidString: runIDValue),
                  let mission = object["mission"] as? String, !mission.isEmpty else {
                throw AutonomyError.invalidRequest(
                    "run_id and mission are required"
                )
            }
            let providerID: String?
            if let value = object["provider_id"] {
                guard let typed = value as? String else {
                    throw AutonomyError.invalidRequest("provider_id must be a string when supplied")
                }
                providerID = typed
            } else { providerID = nil }
            let adapterID: String?
            if let value = object["adapter_id"] {
                guard let typed = value as? String else {
                    throw AutonomyError.invalidRequest("adapter_id must be a string when supplied")
                }
                adapterID = typed
            } else { adapterID = nil }
            let modelKey: String?
            if let value = object["model_key"] {
                guard let typed = value as? String else {
                    throw AutonomyError.invalidRequest("model_key must be a string when supplied")
                }
                modelKey = typed
            } else { modelKey = nil }
            let allowedTools: Set<String>?
            if let value = object["allowed_tools"] {
                guard let typed = value as? [String] else {
                    throw AutonomyError.invalidRequest("allowed_tools must be a string array when supplied")
                }
                allowedTools = Set(typed)
            } else { allowedTools = nil }
            let completionGates: [String]?
            if let value = object["completion_gates"] {
                guard let typed = value as? [String] else {
                    throw AutonomyError.invalidRequest("completion_gates must be a string array when supplied")
                }
                completionGates = typed
            } else { completionGates = nil }
            let failurePolicy = try failurePolicy(object)
            let networkAllowed: Bool
            if let value = object["network_allowed"] {
                guard let typed = value as? Bool else {
                    throw AutonomyError.invalidRequest("network_allowed must be a boolean when supplied")
                }
                networkAllowed = typed
            } else { networkAllowed = false }
            let expectedProviderConfigurationRevision: String?
            if let value = object["expected_provider_configuration_revision"] {
                guard let typed = value as? String,
                      !typed.isEmpty, typed.utf8.count <= 256 else {
                    throw AutonomyError.invalidRequest(
                        "expected_provider_configuration_revision must be a bounded string when supplied"
                    )
                }
                expectedProviderConfigurationRevision = typed
            } else { expectedProviderConfigurationRevision = nil }
            let expectedToolCatalogRevision: String?
            if let value = object["expected_tool_catalog_revision"] {
                guard let typed = value as? String,
                      typed.utf8.count == 64,
                      typed.utf8.allSatisfy({
                          (48...57).contains($0) || (97...102).contains($0)
                      }) else {
                    throw AutonomyError.invalidRequest(
                        "expected_tool_catalog_revision must be a SHA-256 string when supplied"
                    )
                }
                expectedToolCatalogRevision = typed
            } else { expectedToolCatalogRevision = nil }
            let expectedPreparedRunRevision: String?
            if let value = object["expected_prepared_run_revision"] {
                guard let typed = value as? String,
                      typed.utf8.count == 64,
                      typed.utf8.allSatisfy({
                          (48...57).contains($0) || (97...102).contains($0)
                      }) else {
                    throw AutonomyError.invalidRequest(
                        "expected_prepared_run_revision must be a SHA-256 string when supplied"
                    )
                }
                expectedPreparedRunRevision = typed
            } else { expectedPreparedRunRevision = nil }
            let instructionArtifactSHA256 = try optionalSHA256(
                object,
                key: "instruction_artifact_sha256"
            )
            let runProjectID = try projectID(object)
            let runProjectGeneration = try projectGeneration(object)
            let assignmentID = object["assignment_id"] as? String
            let maximumInlineOutputBytes = integer(object["maximum_inline_output_bytes"])
                ?? ProjectContextService.defaultInlineOutputLimit
            guard Self.providerOperationAdmission.wait(timeout: .now()) == .success else {
                http.respondJSON(connection, status: 409, object: [
                    "ok": false,
                    "code": "provider_readiness_busy",
                    "message": "A provider readiness check or run admission is already in progress. Retry after it settles.",
                    "retryable": true,
                ])
                return
            }
            Self.providerProbeQueue.async { [self] in
                defer { Self.providerOperationAdmission.signal() }
                do {
                    let result = try manager.startAutonomousRun(
                        runID: RunID(runUUID),
                        projectID: runProjectID,
                        expectedGeneration: runProjectGeneration,
                        assignmentID: assignmentID,
                        mission: mission,
                        instructionArtifactSHA256: instructionArtifactSHA256,
                        providerID: providerID,
                        adapterID: adapterID,
                        modelKey: modelKey,
                        allowedTools: allowedTools,
                        completionGates: completionGates,
                        failurePolicy: failurePolicy,
                        expectedProviderConfigurationRevision:
                            expectedProviderConfigurationRevision,
                        expectedToolCatalogRevision: expectedToolCatalogRevision,
                        expectedPreparedRunRevision: expectedPreparedRunRevision,
                        networkAllowed: networkAllowed,
                        maximumInlineOutputBytes: maximumInlineOutputBytes
                    )
                    http.respondJSON(connection, status: 202, object: result)
                } catch let error as AutonomyError {
                    let status = if case .invalidToolConfiguration = error { 422 } else { 409 }
                    http.respondJSON(connection, status: status, object: [
                        "ok": false,
                        "code": error.code,
                        "message": error.localizedDescription,
                        "retryable": false,
                    ])
                } catch let error as ManagerRunPreparationError {
                    http.respondJSON(connection, status: 409, object: [
                        "ok": false,
                        "code": "run_preparation_stale",
                        "message": error.localizedDescription,
                        "retryable": true,
                    ])
                } catch let error as ProviderIntegrationError {
                    let failure = Self.providerIntegrationHTTPFailure(error)
                    respondProviderIntegrationFailure(
                        connection,
                        status: failure.status,
                        code: failure.code,
                        message: error.localizedDescription
                    )
                } catch let error as ProjectContextError {
                    let status = if case .projectRootNotAuthorized = error { 403 } else { 409 }
                    http.respondJSON(connection, status: status, object: [
                        "ok": false,
                        "code": error.code,
                        "message": error.localizedDescription,
                        "retryable": false,
                    ])
                } catch {
                    http.respondJSON(connection, status: 500, object: [
                        "ok": false,
                        "code": "run_start_failed",
                        "message": "Run start did not complete.",
                        "retryable": true,
                    ])
                }
            }
        case ("POST", "/api/manager/runs/status"):
            let object = try JSONSupport.object(from: body)
            http.respondJSON(
                connection,
                status: 200,
                object: try manager.autonomousRunStatus(runID: try runID(object))
            )
        case ("POST", "/api/manager/runs/delete"):
            guard body.count <= Self.maximumRunDeletionBodyBytes else {
                http.respondJSON(connection, status: 413, object: [
                    "ok": false,
                    "code": "run_deletion_body_too_large",
                    "message": "Task deletion accepts one bounded run, project, and generation identity",
                ])
                return
            }
            let object: [String: Any]
            do {
                object = try JSONSupport.object(from: body)
                guard object.count == 3,
                      Set(object.keys) == ["run_id", "project_id", "project_generation"] else {
                    throw AutonomyError.invalidRequest(
                        "Task deletion requires exactly run_id, project_id, and project_generation"
                    )
                }
                let receipt = try manager.deleteAutonomousRun(
                    runID: try runID(object),
                    projectID: try projectID(object),
                    expectedGeneration: try projectGeneration(object)
                )
                http.respondJSON(
                    connection,
                    status: 200,
                    object: try JSONSupport.object(from: JSONEncoder().encode(receipt))
                )
            } catch let error as AutonomyError {
                let status = if case .runNotFound = error { 404 } else { 409 }
                http.respondJSON(connection, status: status, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                ])
            } catch let error as ProjectContextError {
                http.respondJSON(connection, status: 400, object: [
                    "ok": false,
                    "code": error.code,
                    "message": error.localizedDescription,
                ])
            }
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

    private func dispatchProviderIntegration(
        _ route: ManagerProviderIntegrationRoute,
        queryItems: [URLQueryItem],
        body: Data,
        connection: NWConnection
    ) {
        guard queryItems.isEmpty else {
            respondProviderIntegrationFailure(
                connection,
                status: 400,
                code: "invalid_provider_integration_request",
                message: "Provider integration endpoints do not accept query parameters."
            )
            return
        }
        guard body.count <= Self.maximumProviderIntegrationBodyBytes else {
            respondProviderIntegrationFailure(
                connection,
                status: 413,
                code: "provider_integration_body_too_large",
                message: "Provider integration requests must remain within the bounded body size."
            )
            return
        }

        let requiresBoundedWorker: Bool
        switch route {
        case .snapshot, .operation:
            requiresBoundedWorker = false
        case .select, .cancel, .repair, .remove:
            requiresBoundedWorker = true
        }
        guard requiresBoundedWorker else {
            performProviderIntegration(route, body: body, connection: connection)
            return
        }
        guard Self.providerOperationAdmission.wait(timeout: .now()) == .success else {
            respondProviderIntegrationFailure(
                connection,
                status: 409,
                code: "provider_operation_busy",
                message: "A provider operation or readiness check is already in progress. Retry after it settles."
            )
            return
        }
        Self.providerProbeQueue.async { [self] in
            defer { Self.providerOperationAdmission.signal() }
            performProviderIntegration(route, body: body, connection: connection)
        }
    }

    private func performProviderIntegration(
        _ route: ManagerProviderIntegrationRoute,
        body: Data,
        connection: NWConnection
    ) {
        do {
            switch route {
            case .snapshot:
                guard body.isEmpty else {
                    throw ProviderIntegrationError.invalidRequest(
                        field: "body",
                        reason: "snapshot_requires_empty_body"
                    )
                }
                try respondProviderIntegration(
                    connection,
                    status: 200,
                    value: manager.providerIntegrations()
                )
            case .select:
                try Self.validateProviderIntegrationObject(
                    body,
                    requiredKeys: ["expected_revision", "idempotency_key"],
                    allowedKeys: ["expected_revision", "provider_id", "idempotency_key"]
                )
                let request = try JSONDecoder().decode(
                    ProviderSelectionRequest.self,
                    from: body
                )
                try respondProviderIntegration(
                    connection,
                    status: 202,
                    value: manager.selectProviderIntegration(request)
                )
            case .operation(let operationID):
                guard body.isEmpty else {
                    throw ProviderIntegrationError.invalidRequest(
                        field: "body",
                        reason: "operation_status_requires_empty_body"
                    )
                }
                try respondProviderIntegration(
                    connection,
                    status: 200,
                    value: manager.providerIntegrationOperation(operationID: operationID)
                )
            case .cancel(let operationID):
                try Self.validateEmptyProviderIntegrationObject(body)
                try respondProviderIntegration(
                    connection,
                    status: 200,
                    value: manager.cancelProviderIntegrationOperation(
                        operationID: operationID
                    )
                )
            case .repair(let pathProviderID):
                let request = try decodeProviderIntegrationMutation(body)
                try Self.validatePathProviderID(
                    pathProviderID,
                    matches: request.providerID
                )
                try respondProviderIntegration(
                    connection,
                    status: 202,
                    value: manager.repairProviderIntegration(request)
                )
            case .remove(let pathProviderID):
                let request = try decodeProviderIntegrationMutation(body)
                try Self.validatePathProviderID(
                    pathProviderID,
                    matches: request.providerID
                )
                try respondProviderIntegration(
                    connection,
                    status: 202,
                    value: manager.removeProviderIntegration(request)
                )
            }
        } catch let error as ProviderIntegrationError {
            let failure = Self.providerIntegrationHTTPFailure(error)
            respondProviderIntegrationFailure(
                connection,
                status: failure.status,
                code: failure.code,
                message: error.localizedDescription
            )
        } catch is DecodingError {
            respondProviderIntegrationFailure(
                connection,
                status: 400,
                code: "invalid_provider_integration_request",
                message: "Provider integration request JSON is invalid."
            )
        } catch {
            respondProviderIntegrationFailure(
                connection,
                status: 500,
                code: "provider_integration_failed",
                message: error.localizedDescription
            )
        }
    }

    private func dispatchDesktopProviderHook(
        queryItems: [URLQueryItem],
        body: Data,
        connection: NWConnection
    ) {
        guard queryItems.isEmpty else {
            http.respondJSON(connection, status: 400, object: [
                "ok": false,
                "code": "invalid_provider_hook_request",
                "message": "Desktop provider hook requests do not accept query parameters.",
            ])
            return
        }
        guard body.count <= DesktopProviderHookContract.maximumEnvelopeBytes else {
            http.respondJSON(connection, status: 413, object: [
                "ok": false,
                "code": "provider_hook_body_too_large",
                "message": "Desktop provider hook input exceeds its bounded envelope size.",
            ])
            return
        }
        do {
            let request = try DesktopProviderHookRequest(envelopeData: body)
            let response = try manager.desktopProviderHookResponse(request)
            http.respondJSON(
                connection,
                status: 200,
                object: response.asDictionary()
            )
        } catch let error as DesktopProviderHookError {
            http.respondJSON(connection, status: 400, object: [
                "ok": false,
                "code": "invalid_provider_hook_request",
                "message": error.localizedDescription,
            ])
        } catch {
            http.respondJSON(connection, status: 503, object: [
                "ok": false,
                "code": "provider_hook_policy_unavailable",
                "message": "Desktop provider orchestration policy is unavailable.",
            ])
        }
    }

    private func decodeProviderIntegrationMutation(
        _ body: Data
    ) throws -> ProviderIntegrationMutationRequest {
        try Self.validateProviderIntegrationObject(
            body,
            requiredKeys: ["expected_revision", "provider_id", "idempotency_key"],
            allowedKeys: ["expected_revision", "provider_id", "idempotency_key"]
        )
        return try JSONDecoder().decode(
            ProviderIntegrationMutationRequest.self,
            from: body
        )
    }

    private func respondProviderIntegration<Value: Encodable>(
        _ connection: NWConnection,
        status: Int,
        value: Value
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        http.respondJSON(
            connection,
            status: status,
            object: try JSONSupport.object(from: encoder.encode(value))
        )
    }

    private func respondProviderIntegrationFailure(
        _ connection: NWConnection,
        status: Int,
        code: String,
        message: String
    ) {
        http.respondJSON(connection, status: status, object: [
            "ok": false,
            "code": code,
            "message": message,
            "retryable": status == 503,
        ])
    }

    static func providerIntegrationHTTPFailure(
        _ error: ProviderIntegrationError
    ) -> (status: Int, code: String) {
        switch error {
        case .invalidRequest:
            (400, "invalid_provider_integration_request")
        case .providerNotSelectable:
            (400, "provider_not_selectable")
        case .revisionConflict:
            (409, "provider_selection_revision_conflict")
        case .idempotencyConflict:
            (409, "provider_idempotency_conflict")
        case .operationBusy:
            (409, "provider_operation_busy")
        case .providerHasNonterminalRuns:
            (409, "provider_has_nonterminal_runs")
        case .providerNotReady:
            (409, "provider_not_ready")
        case .selectedProviderCannotBeRemoved:
            (409, "selected_provider_cannot_be_removed")
        case .operationNotCancellable:
            (409, "provider_operation_not_cancellable")
        case .operationNotFound:
            (404, "provider_operation_not_found")
        case .adapterUnavailable:
            (503, "provider_adapter_unavailable")
        case .invalidAdapterResult:
            (500, "invalid_provider_adapter_result")
        case .ledgerCorrupt:
            (500, "provider_integration_ledger_corrupt")
        case .persistenceFailed:
            (500, "provider_integration_persistence_failed")
        }
    }

    private static func providerIntegrationRoute(
        method: String,
        path: String
    ) -> ManagerProviderIntegrationRoute? {
        switch (method, path) {
        case ("GET", "/api/manager/providers"):
            return .snapshot
        case ("PUT", "/api/manager/providers/selection"):
            return .select
        default:
            break
        }

        let operationPrefix = "/api/manager/provider-operations/"
        if method == "GET", path.hasPrefix(operationPrefix) {
            let operationID = String(path.dropFirst(operationPrefix.count))
            guard !operationID.isEmpty, !operationID.contains("/") else { return nil }
            return .operation(operationID: operationID)
        }
        if method == "POST", path.hasPrefix(operationPrefix), path.hasSuffix("/cancel") {
            let suffix = String(path.dropFirst(operationPrefix.count))
            let operationID = String(suffix.dropLast("/cancel".count))
            guard !operationID.isEmpty, !operationID.contains("/") else { return nil }
            return .cancel(operationID: operationID)
        }

        let providerPrefix = "/api/manager/providers/"
        guard path.hasPrefix(providerPrefix) else { return nil }
        let suffix = String(path.dropFirst(providerPrefix.count))
        if method == "POST", suffix.hasSuffix("/repair") {
            let providerID = String(suffix.dropLast("/repair".count))
            guard !providerID.isEmpty, !providerID.contains("/") else { return nil }
            return .repair(pathProviderID: providerID)
        }
        if method == "DELETE", suffix.hasSuffix("/integration") {
            let providerID = String(suffix.dropLast("/integration".count))
            guard !providerID.isEmpty, !providerID.contains("/") else { return nil }
            return .remove(pathProviderID: providerID)
        }
        return nil
    }

    private static func validateProviderIntegrationObject(
        _ body: Data,
        requiredKeys: Set<String>,
        allowedKeys: Set<String>
    ) throws {
        let object: [String: Any]
        do {
            object = try JSONSupport.object(from: body)
        } catch {
            throw ProviderIntegrationError.invalidRequest(
                field: "body",
                reason: "expected_json_object"
            )
        }
        let keys = Set(object.keys)
        guard keys.isSuperset(of: requiredKeys), keys.isSubset(of: allowedKeys) else {
            throw ProviderIntegrationError.invalidRequest(
                field: "body",
                reason: "unexpected_or_missing_fields"
            )
        }
    }

    private static func validateEmptyProviderIntegrationObject(_ body: Data) throws {
        guard body.isEmpty || ((try? JSONSupport.object(from: body))?.isEmpty == true) else {
            throw ProviderIntegrationError.invalidRequest(
                field: "body",
                reason: "cancellation_requires_empty_object"
            )
        }
    }

    private static func validatePathProviderID(
        _ pathProviderID: String,
        matches bodyProviderID: ProviderIntegrationID
    ) throws {
        guard let parsed = ProviderIntegrationID(rawValue: pathProviderID) else {
            throw ProviderIntegrationError.invalidRequest(
                field: "provider_id",
                reason: "unsupported_path_provider"
            )
        }
        guard parsed == bodyProviderID else {
            throw ProviderIntegrationError.invalidRequest(
                field: "provider_id",
                reason: "path_body_mismatch"
            )
        }
    }

    private func dispatchProjectRemoval(body: Data, connection: NWConnection) {
        guard body.count <= Self.maximumInstructionQueueBodyBytes,
              let object = try? JSONSupport.object(from: body),
              object.count == 2,
              Set(object.keys) == ["project_id", "project_generation"] else {
            http.respondJSON(connection, status: 400, object: [
                "ok": false, "code": "invalid_project_removal",
                "message": "Project removal requires exactly one project UUID and generation.",
            ])
            return
        }
        do {
            http.respondJSON(
                connection,
                status: 200,
                object: try manager.removeProject(
                    projectID: try projectID(object),
                    expectedGeneration: try projectGeneration(object)
                )
            )
        } catch let error as ProjectContextError {
            let status: Int = error == .databaseBusy ? 503 : 409
            http.respondJSON(connection, status: status, object: [
                "ok": false, "code": error.code, "message": error.localizedDescription,
            ])
        } catch {
            http.respondJSON(connection, status: 500, object: [
                "ok": false, "code": "project_removal_failed",
                "message": error.localizedDescription,
            ])
        }
    }

    private func dispatchInstructionQueue(
        path: String,
        body: Data,
        connection: NWConnection
    ) {
        guard body.count <= Self.maximumInstructionQueueBodyBytes,
              let object = try? JSONSupport.object(from: body) else {
            http.respondJSON(connection, status: 400, object: [
                "ok": false, "code": "invalid_instruction_queue_request",
                "message": "Instruction queue commands require one bounded JSON object.",
            ])
            return
        }
        do {
            let selectedProject = try projectID(object)
            let generation = try projectGeneration(object)
            let result: [String: Any]
            switch path {
            case "/api/manager/projects/instruction-packages":
                let acceptedKeys: Set<String> = [
                    "project_id", "project_generation", "cursor", "limit",
                ]
                guard Set(object.keys).isSubset(of: acceptedKeys),
                      Set(object.keys).isSuperset(of: ["project_id", "project_generation"]),
                      object["cursor"] == nil || integer(object["cursor"]) != nil,
                      object["limit"] == nil || integer(object["limit"]) != nil else {
                    throw ProjectInstructionQueueError.invalidRequest(
                        "Queue refresh accepts a project identity and optional cursor and limit."
                    )
                }
                let cursor = integer(object["cursor"]) ?? 0
                let limit = integer(object["limit"]) ?? 128
                result = try manager.instructionQueue(
                    projectID: selectedProject,
                    expectedGeneration: generation,
                    cursor: cursor,
                    limit: limit
                )
            case "/api/manager/projects/instruction-packages/import":
                guard Set(object.keys) == ["project_id", "project_generation", "source_path"],
                      let sourcePath = object["source_path"] as? String else {
                    throw ProjectInstructionQueueError.invalidRequest("Package import requires source_path.")
                }
                result = try manager.importInstructionPackage(
                    sourcePath: sourcePath,
                    projectID: selectedProject,
                    expectedGeneration: generation
                )
            case "/api/manager/projects/instruction-packages/reorder":
                guard Set(object.keys) == ["project_id", "project_generation", "package_ids", "expected_revision"],
                      let rawIDs = object["package_ids"] as? [String],
                      rawIDs.count <= ProjectInstructionQueueStore.maximumPackages,
                      rawIDs.allSatisfy({ UUID(uuidString: $0) != nil }),
                      let revisionValue = integer(object["expected_revision"]), revisionValue >= 0 else {
                    throw ProjectInstructionQueueError.invalidRequest("Package reorder requires every package UUID and the expected queue revision.")
                }
                result = try manager.reorderInstructionPackages(
                    projectID: selectedProject,
                    expectedGeneration: generation,
                    packageIDs: rawIDs.compactMap(UUID.init(uuidString:)),
                    expectedRevision: UInt64(revisionValue)
                )
            case "/api/manager/projects/instruction-packages/remove":
                guard Set(object.keys) == ["project_id", "project_generation", "package_id"],
                      let rawID = object["package_id"] as? String,
                      let packageID = UUID(uuidString: rawID) else {
                    throw ProjectInstructionQueueError.invalidRequest("Package removal requires one package UUID.")
                }
                result = try manager.removeInstructionPackage(
                    projectID: selectedProject,
                    expectedGeneration: generation,
                    packageID: packageID
                )
            case "/api/manager/projects/instruction-packages/start":
                guard Set(object.keys) == ["project_id", "project_generation"] else {
                    throw ProjectInstructionQueueError.invalidRequest("Queue start accepts only project_id and project_generation.")
                }
                result = try manager.startInstructionQueue(
                    projectID: selectedProject,
                    expectedGeneration: generation
                )
            case "/api/manager/projects/instruction-packages/stop":
                guard Set(object.keys) == ["project_id", "project_generation"] else {
                    throw ProjectInstructionQueueError.invalidRequest("Queue stop accepts only project_id and project_generation.")
                }
                result = try manager.stopInstructionQueue(
                    projectID: selectedProject,
                    expectedGeneration: generation
                )
            default:
                throw ProjectInstructionQueueError.invalidRequest("Unknown instruction queue command.")
            }
            http.respondJSON(connection, status: 200, object: result)
        } catch let error as ProjectInstructionQueueError {
            let status: Int
            switch error {
            case .packageNotFound: status = 404
            case .storageFailure: status = 500
            default: status = 409
            }
            http.respondJSON(connection, status: status, object: [
                "ok": false, "code": "instruction_queue_error",
                "message": error.localizedDescription,
            ])
        } catch let error as ProjectContextError {
            http.respondJSON(connection, status: 409, object: [
                "ok": false, "code": error.code, "message": error.localizedDescription,
            ])
        } catch let error as AutonomyError {
            http.respondJSON(connection, status: 409, object: [
                "ok": false, "code": error.code, "message": error.localizedDescription,
            ])
        } catch let error as ProviderConfigurationError {
            http.respondJSON(connection, status: 409, object: [
                "ok": false, "code": "provider_configuration_\(error.rawValue)",
                "message": error.localizedDescription,
            ])
        } catch {
            http.respondJSON(connection, status: 500, object: [
                "ok": false, "code": "instruction_queue_unavailable",
                "message": error.localizedDescription,
            ])
        }
    }

    private func dispatchNativeSourceCommand(action: String, body: Data, connection: NWConnection) {
        let maximum = action == "send" ? NativeSourceSendRequest.maximumBodyBytes : NativeSourceStatusRequest.maximumBodyBytes
        guard !body.isEmpty, body.count <= maximum else {
            http.respondJSON(connection, status: body.isEmpty ? 400 : 413, object: [
                "ok": false, "code": "invalid_source_request",
                "message": "Native source commands require one bounded request object",
            ])
            return
        }
        let http = self.http
        let admitted = manager.dispatchNativeSourceCommand(action: action, body: body) { result in
            switch result {
            case .success(let response):
                let active = response.conversationState == "active"
                    && ["prepared", "submitted"].contains(response.stageState)
                http.respondData(connection, status: active ? 202 : 200,
                    data: response.canonicalJSON, contentType: "application/json; charset=utf-8")
            case .failure(let error):
                let status: Int
                let code: String
                switch error {
                case NativeSourceOperatorError.invalidRequest:
                    status = 400; code = "invalid_source_request"
                case NativeSourceConversationError.notFound:
                    status = 404; code = "native_source_not_found"
                case NativeSourceConversationError.capacityExceeded:
                    status = 503; code = "native_source_busy"
                case NativeSourceConversationError.budgetExceeded:
                    status = 409; code = "native_source_budget_exceeded"
                case NativeSourceConversationError.outcomeUnknown:
                    status = 409; code = "native_source_reconciliation_required"
                case NativeSourceConversationError.sourceFenced, NativeSourceConversationError.ownerManaged:
                    status = 409; code = "native_source_fenced"
                case NativeSourceConversationError.conflict, NativeSourceConversationError.leaseUnavailable:
                    status = 409; code = "native_source_conflict"
                case NativeSourceConversationError.unsupportedProvider:
                    status = 409; code = "native_source_provider_unavailable"
                default:
                    status = 503; code = "native_source_unavailable"
                }
                http.respondJSON(connection, status: status, object: ["ok": false, "code": code,
                    "message": "The source command did not return a receipt; inspect the same task and request before retrying"])
            }
        }
        if !admitted {
            http.respondJSON(connection, status: 503, object: ["ok": false, "code": "native_source_busy",
                "message": "Native source command admission is unavailable"])
        }
    }

    private func dispatchNativeTaskCommand(action: String, body: Data, connection: NWConnection) {
        let maximum = action == "prepare" ? NativeContinuityTaskPreparationRequest.maximumBodyBytes
            : NativeContinuityTaskRotationRequest.maximumBodyBytes
        guard !body.isEmpty, body.count <= maximum else {
            http.respondJSON(connection, status: body.isEmpty ? 400 : 413, object: [
                "ok": false, "code": "invalid_native_task_request",
                "message": "Native task commands require one bounded request object",
            ])
            return
        }
        let http = self.http
        let admitted = manager.dispatchNativeTaskCommand(action: action, body: body) { result in
            switch result {
            case .success(let command):
                http.respondJSON(connection, status: 200, object: [
                    "schema_version": 1, "ok": true,
                    "disposition": command.replayed ? "replayed" : "committed",
                    "receipt": command.receipt.wireObject, "current": command.current.wireObject,
                ])
            case .failure(let error):
                let status: Int
                let code: String
                switch error {
                case is NativeTaskOperatorError:
                    status = 400; code = "invalid_native_task_request"
                case let failure as NativeTaskCapabilityError:
                    switch failure {
                    case .invalidRequest, .unsupportedProfile: status = 400; code = "invalid_native_task_request"
                    case .credentialRejected: status = 403; code = "native_task_credential_rejected"
                    case .requestConflict, .epochConflict, .capabilityRevoked, .sourceFenced:
                        status = 409; code = "native_task_command_conflict"
                    case .capacityExceeded, .operationBusy: status = 503; code = "native_task_command_busy"
                    case .integrityFailure, .resultExpired, .budgetExceeded:
                        status = 409; code = "native_task_command_unavailable"
                    }
                case is ProjectContextError, is ContinuityTaskAuthorizationError:
                    status = 409; code = "native_task_authority_unavailable"
                case is CancellationError:
                    status = 503; code = "native_task_command_interrupted"
                default:
                    status = 503; code = "native_task_command_unavailable"
                }
                // Neither approval text, credentials nor arbitrary storage errors
                // are a diagnostic channel. Exact retries reconcile lost replies.
                http.respondJSON(connection, status: status, object: [
                    "ok": false, "code": code,
                    "message": "The native task command did not return a receipt; reconcile the exact request before retrying",
                ])
            }
        }
        if !admitted {
            http.respondJSON(connection, status: 503, object: [
                "ok": false, "code": "native_task_command_busy",
                "message": "Native task command admission is closed or full",
            ])
        }
    }

    private func dispatchProviderConfiguration(method: String, path: String, body: Data, connection: NWConnection) {
        let manager = self.manager
        let http = self.http
        guard body.count <= 16 * 1024 else {
            http.respondJSON(connection, status: 413, object: ["ok": false, "message": "Provider configuration request is oversized"])
            return
        }
        guard Self.providerOperationAdmission.wait(timeout: .now()) == .success else {
            http.respondJSON(connection, status: 409, object: [
                "ok": false, "code": "provider_configuration_busy",
                "message": "A provider operation is already in progress. Retry after it settles.",
            ])
            return
        }
        Self.providerProbeQueue.async {
            defer { Self.providerOperationAdmission.signal() }
            do {
                let data: Data
                if path.hasSuffix("/prepare") {
                    let resumeWaitingRuns: Bool
                    if body.isEmpty || body == Data("{}".utf8) {
                        resumeWaitingRuns = true
                    } else if let object = try? JSONSupport.object(from: body),
                              Set(object.keys) == ["resume_waiting_runs"],
                              let requested = object["resume_waiting_runs"] as? Bool {
                        resumeWaitingRuns = requested
                    } else {
                        throw ProviderConfigurationError.invalidRequest
                    }
                    data = try JSONEncoder().encode(manager.connectAndCheckProvider(
                        resumeWaitingRuns: resumeWaitingRuns
                    ))
                } else if method == "PUT" {
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
        guard Self.providerOperationAdmission.wait(timeout: .now()) == .success else {
            http.respondJSON(connection, status: 409, object: [
                "ok": false, "code": "provider_probe_in_progress",
                "message": "A provider operation is already in progress. Retry after it settles.",
            ])
            return
        }
        Self.providerProbeQueue.async {
            defer { Self.providerOperationAdmission.signal() }
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

    private func optionalString(
        _ object: [String: Any],
        key: String,
        maximumBytes: Int
    ) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let typed = value as? String, typed.utf8.count <= maximumBytes else {
            throw AutonomyError.invalidRequest(
                "\(key) must be a bounded string when supplied"
            )
        }
        return typed
    }

    private func optionalStringArray(
        _ object: [String: Any],
        key: String
    ) throws -> [String]? {
        guard let value = object[key] else { return nil }
        guard let typed = value as? [String] else {
            throw AutonomyError.invalidRequest("\(key) must be a string array when supplied")
        }
        return typed
    }

    private func optionalSHA256(
        _ object: [String: Any],
        key: String
    ) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let typed = value as? String,
              typed.utf8.count == 64,
              typed.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            throw AutonomyError.invalidRequest(
                "\(key) must be a lowercase SHA-256 string when supplied"
            )
        }
        return typed
    }

    private func optionalStringSet(
        _ object: [String: Any],
        key: String
    ) throws -> Set<String>? {
        try optionalStringArray(object, key: key).map(Set.init)
    }

    private func optionalBoolean(
        _ object: [String: Any],
        key: String
    ) throws -> Bool? {
        guard let value = object[key] else { return nil }
        guard let typed = value as? Bool else {
            throw AutonomyError.invalidRequest("\(key) must be a boolean when supplied")
        }
        return typed
    }

    private func failurePolicy(_ object: [String: Any]) throws -> AutonomousFailurePolicy {
        guard let raw = object["failure_policy"] else { return .default }
        guard let policy = raw as? [String: Any],
              Set(policy.keys).isSubset(of: ["behavior", "maximum_retries", "custom_instructions"]),
              let behaviorValue = policy["behavior"] as? String,
              let behavior = AutonomousFailureBehavior(rawValue: behaviorValue),
              let maximumRetries = integer(policy["maximum_retries"]) else {
            throw AutonomyError.invalidRequest("failure_policy is invalid")
        }
        let instructions: String?
        if let value = policy["custom_instructions"] {
            guard let typed = value as? String else {
                throw AutonomyError.invalidRequest("failure_policy custom_instructions must be a string")
            }
            instructions = typed
        } else {
            instructions = nil
        }
        return try AutonomousFailurePolicy(
            behavior: behavior,
            maximumRetries: maximumRetries,
            customInstructions: instructions
        ).validated()
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

    private static func stjornarvaldSnapshotQuery(
        _ items: [URLQueryItem]
    ) throws -> ManagerStjornarvaldSnapshotQuery {
        guard items.allSatisfy({
            $0.name == "limit" || $0.name == "cursor" || $0.name == "order"
                || $0.name == "project_id" || $0.name == "project_generation"
        }), items.filter({ $0.name == "limit" }).count <= 1,
            items.filter({ $0.name == "cursor" }).count <= 1,
            items.filter({ $0.name == "order" }).count <= 1,
            items.filter({ $0.name == "project_id" }).count <= 1,
            items.filter({ $0.name == "project_generation" }).count <= 1 else {
            throw ManagerStjornarvaldSnapshotQueryError.invalidParameter
        }
        let base: ManagerOperatorSnapshotQuery
        do {
            base = try operatorSnapshotQuery(items.filter {
                $0.name != "order" && $0.name != "project_id"
                    && $0.name != "project_generation"
            })
        } catch {
            throw ManagerStjornarvaldSnapshotQueryError.invalidParameter
        }
        let newestFirst: Bool
        if let order = items.first(where: { $0.name == "order" }) {
            guard order.value == "newest" else {
                throw ManagerStjornarvaldSnapshotQueryError.invalidParameter
            }
            newestFirst = true
        } else {
            newestFirst = false
        }
        guard !(newestFirst && base.cursor != nil) else {
            throw ManagerStjornarvaldSnapshotQueryError.cursorWithNewestOrder
        }
        let projectID = items.first(where: { $0.name == "project_id" })?.value
        let generationValue = items.first(where: { $0.name == "project_generation" })?.value
        let projectGeneration: UInt64?
        if let generationValue {
            guard isDecimal(generationValue, maximumDigits: 19),
                  let parsed = UInt64(generationValue), parsed > 0,
                  parsed <= UInt64(Int64.max) else {
                throw ManagerStjornarvaldSnapshotQueryError.invalidParameter
            }
            projectGeneration = parsed
        } else {
            projectGeneration = nil
        }
        guard (projectID == nil) == (projectGeneration == nil),
              projectID.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true,
              projectID == nil || newestFirst else {
            throw ManagerStjornarvaldSnapshotQueryError.invalidParameter
        }
        return ManagerStjornarvaldSnapshotQuery(
            limit: base.limit,
            cursor: base.cursor,
            newestFirst: newestFirst,
            projectID: projectID,
            projectGeneration: projectGeneration
        )
    }

    private static func operatorActivityQuery(
        _ items: [URLQueryItem]
    ) throws -> ManagerOperatorActivityQuery {
        let identityNames: Set<String> = ["run_id", "project_id", "project_generation"]
        guard items.allSatisfy({
            $0.name == "limit" || $0.name == "cursor" || identityNames.contains($0.name)
        }), identityNames.allSatisfy({ name in items.filter { $0.name == name }.count == 1 }) else {
            throw ManagerOperatorSnapshotQueryError.invalidParameter
        }
        let base = try operatorSnapshotQuery(items.filter { !identityNames.contains($0.name) })
        guard let runValue = items.first(where: { $0.name == "run_id" })?.value,
              let runID = UUID(uuidString: runValue)?.uuidString.lowercased(),
              let projectValue = items.first(where: { $0.name == "project_id" })?.value,
              let projectID = UUID(uuidString: projectValue)?.uuidString.lowercased(),
              let generationValue = items.first(where: {
                  $0.name == "project_generation"
              })?.value,
              isDecimal(generationValue, maximumDigits: 19),
              let projectGeneration = UInt64(generationValue),
              projectGeneration > 0,
              projectGeneration <= UInt64(Int64.max) else {
            throw ManagerOperatorSnapshotQueryError.invalidParameter
        }
        return ManagerOperatorActivityQuery(
            limit: base.limit,
            cursor: base.cursor,
            runID: runID,
            projectID: projectID,
            projectGeneration: projectGeneration
        )
    }

    private static func isDecimal(_ value: String, maximumDigits: Int) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= maximumDigits
            && bytes.allSatisfy { (48...57).contains($0) }
    }

}

// ManagerDashboardClient.swift
// What: Provides a typed loopback client for an already-running persistent manager.
// How: URLSession requests decode status/settings and send JSON mutations to the
// validated local control endpoints with bounded timeouts.
// Why: The GUI can attach to the single manager owner instead of binding another server.

import Foundation

/// Native loopback client used by presentation processes that attach to the
/// one persistent manager instead of attempting to bind a second HTTP server.
public final class ManagerDashboardClient: @unchecked Sendable {
    static let ordinaryRequestTimeoutSeconds: TimeInterval = 2
    static let responseSchedulingAllowanceSeconds: TimeInterval = 1
    static let lifecycleMutationRequestTimeoutSeconds: TimeInterval =
        ManagerNode.lifecycleTransitionWaitTimeoutSeconds
        + ConfigStore.configurationLockTimeoutSeconds
        + ManagerNode.listenerReplacementPauseSeconds
        + DashboardServer.bindTimeoutSeconds
        + responseSchedulingAllowanceSeconds
    static let settingsMutationRequestTimeoutSeconds: TimeInterval =
        ManagerNode.lifecycleTransitionWaitTimeoutSeconds
        + (2 * ConfigStore.configurationLockTimeoutSeconds)
        + ManagerNode.listenerReplacementPauseSeconds
        + (2 * DashboardServer.bindTimeoutSeconds)
        + responseSchedulingAllowanceSeconds

    public enum ClientError: Error, LocalizedError, Sendable {
        case invalidEndpoint
        case invalidResponse
        case invalidRequest(String)
        case rejected(status: Int, message: String)
        case reconciliationRequired(status: Int, code: String, message: String)

        public var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "Manager loopback endpoint is invalid"
            case .invalidResponse: "Manager returned a non-HTTP response"
            case .invalidRequest(let message): message
            case .rejected(let status, let message):
                "Manager request failed with HTTP \(status): \(message)"
            case .reconciliationRequired(let status, let code, let message):
                "Manager request requires an exact retry (HTTP \(status), \(code)): \(message)"
            }
        }
    }

    private let host: String
    private let port: Int
    private let session: URLSession
    private let credentials: any ManagerMutationCredentialProviding

    public init(
        host: String,
        port: Int,
        session: URLSession = .shared,
        credentials: (any ManagerMutationCredentialProviding)? = nil
    ) {
        self.host = host
        self.port = port
        self.session = session
        self.credentials = credentials ?? ManagerControlCredentialStore()
    }

    public func status() async throws -> ManagerStatus {
        try ManagerStatus(dictionary: try await request(method: "GET", path: "/api/manager/status"))
    }

    public func settings() async throws -> ManagerSettings {
        try ManagerSettings(dictionary: try await request(
            method: "GET", path: "/api/manager/settings",
            timeoutInterval: ConfigStore.configurationLockTimeoutSeconds + Self.responseSchedulingAllowanceSeconds
        ))
    }

    public func startService() async throws -> ManagerStatus {
        try ManagerStatus(dictionary: try await request(
            method: "POST",
            path: "/api/manager/start",
            body: [:],
            timeoutInterval: Self.lifecycleMutationRequestTimeoutSeconds
        ))
    }

    public func stopService() async throws -> ManagerStatus {
        try ManagerStatus(dictionary: try await request(method: "POST", path: "/api/manager/stop", body: [:]))
    }

    public func restartService() async throws -> ManagerStatus {
        try ManagerStatus(dictionary: try await request(
            method: "POST",
            path: "/api/manager/restart",
            body: [:],
            timeoutInterval: Self.lifecycleMutationRequestTimeoutSeconds
        ))
    }

    public func updateSettings(_ patch: ManagerSettingsPatch, apply: Bool = true) async throws -> ManagerSettings {
        _ = try patch.budgetPolicyUpdate?.validated()
        let result = try await request(
            method: "POST",
            path: "/api/manager/settings",
            body: ["settings": patch.asConfigPatch(), "apply": apply],
            timeoutInterval: Self.settingsMutationRequestTimeoutSeconds
        )
        return try ManagerSettings(dictionary: result)
    }

    public func budgetPolicy(scope: BudgetPolicyScope) async throws -> BudgetPolicySelection {
        try await settings().resolvedBudgetPolicy(scope: scope)
    }

    /// Registers one exact request with at most one automatic replay when the
    /// first response is lost. The same pre-encoded body and authorization
    /// credential are used for both attempts. A second ambiguous transport
    /// failure returns a typed pending result instead of claiming commit or
    /// starting an unbounded retry loop.
    public func registerProject(
        path: String,
        displayName: String? = nil,
        repositoryIdentity: String? = nil
    ) async throws -> ManagerProjectRegistrationResult {
        guard !path.isEmpty,
              path.utf8.count <= ManagerRoutes.maximumProjectRegistrationPathBytes,
              (path as NSString).isAbsolutePath,
              displayName.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true,
              repositoryIdentity.map({ !$0.isEmpty && $0.utf8.count <= 2_048 }) ?? true else {
            throw ClientError.invalidRequest(
                "Project registration requires one bounded absolute path and bounded optional identity fields"
            )
        }
        var body: [String: Any] = ["path": path]
        if let displayName { body["display_name"] = displayName }
        if let repositoryIdentity { body["repository_identity"] = repositoryIdentity }
        let encodedBody = try JSONSupport.data(from: body)
        let authorizationHeader = "Bearer \(try credentials.bearerToken())"

        for attempt in 0..<2 {
            do {
                let result = try await request(
                    method: "POST",
                    path: "/api/manager/projects/register",
                    body: encodedBody,
                    authorizationHeader: authorizationHeader,
                    timeoutInterval: 18
                )
                do {
                    return try JSONDecoder().decode(
                        ManagerProjectRegistrationResult.self,
                        from: JSONSupport.data(from: result)
                    )
                } catch {
                    throw ClientError.invalidResponse
                }
            } catch {
                guard Self.isAmbiguousTransportFailure(error) else { throw error }
                guard attempt == 0 else {
                    return ManagerProjectRegistrationResult(
                        registrationState: .reconciliationRequired,
                        projectID: nil,
                        displayName: nil,
                        canonicalRoot: nil,
                        projectGeneration: nil,
                        lifecycleState: nil,
                        requestPath: path,
                        requestedDisplayName: displayName,
                        repositoryIdentityAssertion: repositoryIdentity,
                        reconciled: false,
                        code: "project_registration_response_ambiguous",
                        message: "Both bounded attempts lost their response; replay this exact request to reconcile"
                    )
                }
            }
        }
        throw ClientError.invalidResponse
    }

    public func relinkProject(
        projectID: UUID,
        expectedGeneration: UInt64,
        path: String
    ) async throws -> ManagerProjectRelinkResult {
        guard expectedGeneration > 0,
              expectedGeneration < UInt64(Int64.max),
              !path.isEmpty,
              path.utf8.count <= ManagerRoutes.maximumProjectRelinkPathBytes,
              (path as NSString).isAbsolutePath else {
            throw ClientError.invalidRequest(
                "Project relink requires one existing absolute path and a valid generation"
            )
        }
        let body: [String: Any] = [
            "project_id": projectID.uuidString.lowercased(),
            "project_generation": expectedGeneration,
            "path": path,
        ]
        for attempt in 0..<2 {
            do {
                let result = try await request(
                    method: "POST",
                    path: "/api/manager/projects/relink",
                    body: body,
                    timeoutInterval: 18
                )
                return try JSONDecoder().decode(
                    ManagerProjectRelinkResult.self,
                    from: JSONSupport.data(from: result)
                )
            } catch {
                guard attempt == 0, Self.isAmbiguousTransportFailure(error) else {
                    if error is DecodingError { throw ClientError.invalidResponse }
                    throw error
                }
            }
        }
        throw ClientError.invalidResponse
    }

    public func cancelRuntimeJob(jobID: UUID) async throws -> ManagerOperatorRuntimeJob {
        let result = try await request(
            method: "POST",
            path: "/api/manager/runtime-jobs/cancel",
            body: ["job_id": jobID.uuidString.lowercased()],
            timeoutInterval: 18
        )
        do {
            return try JSONDecoder().decode(
                ManagerOperatorRuntimeJob.self,
                from: JSONSupport.data(from: result)
            )
        } catch {
            throw ClientError.invalidResponse
        }
    }

    public func probeProvider(
        adapterID: String = ManagerNode.nativeSessionHostAdapterID,
        mode: ManagerProviderProbeMode
    ) async throws -> ManagerOperatorProvider {
        let result = try await request(
            method: "POST",
            path: "/api/manager/provider/probe",
            body: [
                "adapter_id": adapterID,
                "mode": mode.rawValue,
            ],
            timeoutInterval: 35
        )
        do {
            return try JSONDecoder().decode(
                ManagerOperatorProvider.self,
                from: JSONSupport.data(from: result)
            )
        } catch {
            throw ClientError.invalidResponse
        }
    }

    private func request(
        method: String,
        path: String,
        body: [String: Any]? = nil,
        timeoutInterval: TimeInterval = ManagerDashboardClient.ordinaryRequestTimeoutSeconds
    ) async throws -> [String: Any] {
        try await request(
            method: method,
            path: path,
            body: try body.map { try JSONSupport.data(from: $0) },
            timeoutInterval: timeoutInterval
        )
    }

    private func request(
        method: String,
        path: String,
        body: Data?,
        authorizationHeader: String? = nil,
        timeoutInterval: TimeInterval
    ) async throws -> [String: Any] {
        guard DashboardRequestPolicy.isConfiguredLoopbackHost(host) else {
            throw ClientError.invalidEndpoint
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        guard let url = components.url else { throw ClientError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if ManagerMutationAuthorizer.requiresAuthorization(method: method, path: path) {
            let header: String
            if let authorizationHeader {
                header = authorizationHeader
            } else {
                header = "Bearer \(try credentials.bearerToken())"
            }
            request.setValue(
                header,
                forHTTPHeaderField: "Authorization"
            )
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        let object = (try? JSONSupport.object(from: data)) ?? [:]
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 409, object["code"] as? String == "budget_policy_conflict",
               let current = object["current_policy"] as? [String: Any] {
                throw BudgetPolicyConflict(current: try JSONDecoder().decode(
                    BudgetPolicySelection.self, from: JSONSupport.data(from: current)
                ))
            }
            if http.statusCode == 400, object["code"] as? String == "invalid_settings",
               let field = object["field"] as? String, let reason = object["reason"] as? String {
                throw ManagerSettingsValidationError(
                    field: field, reason: reason,
                    permittedRange: object["permitted_range"] as? String
                )
            }
            let message = (object["message"] as? String)
                ?? String(data: data, encoding: .utf8)
                ?? "unknown"
            if object["retryable"] as? Bool == true,
               object["reconciliation_required"] as? Bool == true,
               let code = object["code"] as? String,
               !code.isEmpty {
                throw ClientError.reconciliationRequired(
                    status: http.statusCode,
                    code: code,
                    message: message
                )
            }
            throw ClientError.rejected(
                status: http.statusCode,
                message: message
            )
        }
        return object
    }

    private static func isAmbiguousTransportFailure(_ error: Error) -> Bool {
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else {
            return false
        }
        let code = URLError.Code(rawValue: value.code)
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .resourceUnavailable,
        ].contains(code)
    }
}

extension ManagerDashboardClient: NativeTaskOperatorTransport {
    /// The operator bearer is read from this client's installation only. Neither redirects nor
    /// response caches may transfer or retain this request, and both attempts use identical bytes.
    public func submitNativeTaskCommand(action: String, body: Data) async throws -> NativeTaskCapabilityCommandResult {
        let command = try NativeTaskOperatorCommand(action: action, data: body)
        var components = URLComponents()
        components.scheme = "http"; components.host = host; components.port = port; components.path = "/mcp/continuity"
        guard let endpoint = components.url else { throw NativeTaskOperatorError.invalidRequest("manager_endpoint") }
        try NativeTaskOperatorEndpoint.validate(endpoint)
        components.path = "/api/manager/continuity/tasks/" + command.action
        guard let url = components.url else { throw NativeTaskOperatorError.invalidRequest("manager_endpoint") }
        let authorization = "Bearer \(try credentials.bearerToken())"
        let configuration = session.configuration
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 18; configuration.timeoutIntervalForResource = 20
        let boundedSession = URLSession(configuration: configuration)
        defer { boundedSession.invalidateAndCancel() }
        let redirectGuard = NativeTaskOperatorRedirectGuard()
        for attempt in 0..<2 {
            do {
                try Task.checkCancellation()
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
                request.httpMethod = "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
                let (bytes, response) = try await boundedSession.bytes(for: request, delegate: redirectGuard)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse, http.url == url else { throw NativeTaskOperatorError.invalidResponse }
                guard response.expectedContentLength <= Int64(NativeTaskOperatorResponse.maximumBytes) else { throw NativeTaskOperatorError.responseTooLarge }
                var data = Data(); data.reserveCapacity(min(NativeTaskOperatorResponse.maximumBytes, 8_192))
                for try await byte in bytes {
                    guard data.count < NativeTaskOperatorResponse.maximumBytes else { throw NativeTaskOperatorError.responseTooLarge }
                    data.append(byte)
                }
                guard http.statusCode == 200 else {
                    // Never reflect server bodies, arbitrary messages, or authorization values into native errors.
                    throw NativeTaskOperatorError.rejected(status: http.statusCode, code: "native_task_command_rejected")
                }
                let result = try NativeTaskOperatorResponse.decode(data)
                try command.validate(result)
                return result
            } catch {
                guard attempt == 0, Self.isAmbiguousTransportFailure(error), !Task.isCancelled else { throw error }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        throw NativeTaskOperatorError.reconciliationRequired
    }

    public func prepareNativeContinuityTask(_ request: NativeContinuityTaskPreparationRequest) async throws -> NativeTaskCapabilityCommandResult {
        try await submitNativeTaskCommand(action: request.action, body: request.canonicalRequestJSON)
    }
    public func rotateNativeContinuityTask(_ request: NativeContinuityTaskRotationRequest) async throws -> NativeTaskCapabilityCommandResult {
        try await submitNativeTaskCommand(action: request.action, body: request.canonicalRequestJSON)
    }
    public func revokeNativeContinuityTask(_ request: NativeContinuityTaskRevocationRequest) async throws -> NativeTaskCapabilityCommandResult {
        try await submitNativeTaskCommand(action: request.action, body: request.canonicalRequestJSON)
    }
}

private final class NativeTaskOperatorRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

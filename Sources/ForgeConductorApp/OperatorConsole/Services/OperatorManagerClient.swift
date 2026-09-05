// OperatorManagerClient.swift
// Typed, bounded loopback transport for native operator state and commands.

import Foundation
import ForgeConductorCore

protocol OperatorManagerClientProtocol: Sendable {
    func snapshot(limit: Int, cursor: String?) async throws -> OperatorSnapshot
    func autonomyStatus() async throws -> OperatorAutonomySummary
    func settings() async throws -> ManagerSettings
    func updateSettings(_ patch: ManagerSettingsPatch) async throws -> ManagerSettings
    func registerProject(
        _ request: OperatorProjectRegistrationRequest
    ) async throws -> OperatorProjectRegistrationOutcome
    func projectStatus(projectID: String) async throws -> OperatorProject
    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt
    func relinkProject(
        projectID: String,
        generation: UInt64,
        path: String
    ) async throws -> OperatorRelinkReceipt
    func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun
    func runStatus(runID: String) async throws -> OperatorRun
    func controlRun(runID: String, action: OperatorRunControlAction) async throws -> OperatorRun
    func cancelRuntimeJob(jobID: String) async throws -> OperatorRuntimeJob
    func providerConfiguration() async throws -> ProviderConfigurationSnapshot
    func updateProviderConfiguration(_ update: ProviderConfigurationUpdate) async throws -> ProviderConfigurationSnapshot
    func providerModels() async throws -> ProviderModelInventory
    func probeProvider(
        adapterID: String,
        mode: OperatorProviderProbeMode
    ) async throws -> OperatorProvider
}

extension OperatorManagerClientProtocol {
    func snapshot(limit: Int) async throws -> OperatorSnapshot {
        try await snapshot(limit: limit, cursor: nil)
    }
}

enum OperatorManagerClientError: Error, LocalizedError, Sendable, Equatable {
    case disabled(String)
    case invalidEndpoint
    case invalidResponse
    case responseTooLarge(maximumBytes: Int)
    case capabilityUnavailable(String)
    case configurationRejected(code: String, message: String)
    case rejected(status: Int, message: String)
    case reconciliationRequired(code: String, message: String)
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .disabled(let reason):
            reason
        case .invalidEndpoint:
            "The configured manager endpoint is not a valid loopback address."
        case .invalidResponse:
            "The manager returned a non-HTTP response."
        case .responseTooLarge(let maximumBytes):
            "The manager response exceeded the bounded \(maximumBytes)-byte UI limit."
        case .capabilityUnavailable(let detail):
            detail
        case .configurationRejected(let code, let message):
            "Run configuration was rejected (\(code)): \(message)"
        case .rejected(let status, let message):
            "Manager request failed with HTTP \(status): \(message)"
        case .reconciliationRequired(let code, let message):
            "Project reconciliation is required (\(code)): \(message)"
        case .invalidPayload(let detail):
            "The manager returned an invalid operator payload: \(detail)"
        }
    }
}

final class OperatorManagerHTTPClient: OperatorManagerClientProtocol, @unchecked Sendable {
    static let maximumResponseBytes = 4 * 1_024 * 1_024

    private let host: String
    private let port: Int
    private let session: URLSession
    private let managerClient: ManagerDashboardClient
    private let credentials: any ManagerMutationCredentialProviding
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        host: String,
        port: Int,
        session: URLSession = .shared,
        credentials: (any ManagerMutationCredentialProviding)? = nil
    ) {
        let resolvedCredentials = credentials ?? ManagerControlCredentialStore()
        self.host = host
        self.port = port
        self.session = session
        self.credentials = resolvedCredentials
        self.managerClient = ManagerDashboardClient(
            host: host,
            port: port,
            session: session,
            credentials: resolvedCredentials
        )
        encoder.outputFormatting = [.sortedKeys]
    }

    func providerConfiguration() async throws -> ProviderConfigurationSnapshot {
        try await request(method: "GET", path: "/api/manager/provider/configuration", timeoutInterval: 25)
    }

    func updateProviderConfiguration(_ update: ProviderConfigurationUpdate) async throws -> ProviderConfigurationSnapshot {
        try await request(method: "PUT", path: "/api/manager/provider/configuration", body: update, timeoutInterval: 25)
    }

    func providerModels() async throws -> ProviderModelInventory {
        try await request(method: "GET", path: "/api/manager/provider/models", timeoutInterval: 25)
    }

    func snapshot(limit: Int = 100, cursor: String? = nil) async throws -> OperatorSnapshot {
        let boundedLimit = min(max(limit, 1), 100)
        var queryItems = [URLQueryItem(name: "limit", value: "\(boundedLimit)")]
        if let cursor {
            guard let value = UInt64(cursor), value > 0 else {
                throw OperatorManagerClientError.invalidPayload("event cursor must be a positive decimal sequence")
            }
            queryItems.append(URLQueryItem(name: "cursor", value: String(value)))
        }
        return try await request(
            method: "GET",
            path: "/api/manager/operator/snapshot",
            queryItems: queryItems,
            unavailableMessage: "Native operator state is unavailable. Update or restart the manager from this build, then retry."
        )
    }

    func autonomyStatus() async throws -> OperatorAutonomySummary {
        try await request(method: "GET", path: "/api/manager/autonomy/status")
    }

    func settings() async throws -> ManagerSettings {
        try await managerClient.settings()
    }

    func updateSettings(_ patch: ManagerSettingsPatch) async throws -> ManagerSettings {
        try await managerClient.updateSettings(patch, apply: true)
    }

    func registerProject(
        _ request: OperatorProjectRegistrationRequest
    ) async throws -> OperatorProjectRegistrationOutcome {
        do {
            let result = try await managerClient.registerProject(
                path: request.path,
                displayName: request.displayName,
                repositoryIdentity: request.repositoryIdentity
            )
            switch result.registrationState {
            case .committed:
                guard let projectID = result.projectID,
                      let projectGeneration = result.projectGeneration,
                      result.lifecycleState == "active" else {
                    throw OperatorManagerClientError.invalidPayload(
                        "committed project registration omitted its active project identity"
                    )
                }
                let project = try await projectStatus(projectID: projectID)
                guard project.projectID.caseInsensitiveCompare(projectID) == .orderedSame,
                      project.projectGeneration == projectGeneration,
                      project.lifecycleState == "active",
                      result.canonicalRoot == nil
                        || project.canonicalRoot == result.canonicalRoot,
                      result.displayName == nil
                        || project.displayName == result.displayName else {
                    throw OperatorManagerClientError.invalidPayload(
                        "committed project registration status did not match its receipt"
                    )
                }
                return .committed(project: project, reconciled: result.reconciled)
            case .reconciliationRequired:
                guard !result.requestPath.isEmpty else {
                    throw OperatorManagerClientError.invalidPayload(
                        "pending project registration omitted its exact request path"
                    )
                }
                return .reconciliationRequired(
                    OperatorPendingProjectRegistration(
                        request: OperatorProjectRegistrationRequest(
                            path: result.requestPath,
                            displayName: result.requestedDisplayName,
                            repositoryIdentity: result.repositoryIdentityAssertion
                        ),
                        projectID: result.projectID,
                        code: result.code ?? "project_registration_reconciliation_required",
                        message: result.message ?? "Registration outcome remains ambiguous"
                    )
                )
            }
        } catch let error as ManagerDashboardClient.ClientError {
            switch error {
            case .invalidEndpoint:
                throw OperatorManagerClientError.invalidEndpoint
            case .invalidResponse:
                throw OperatorManagerClientError.invalidResponse
            case .invalidRequest(let message):
                throw OperatorManagerClientError.invalidPayload(message)
            case .rejected(let status, let message):
                throw OperatorManagerClientError.rejected(status: status, message: message)
            case .reconciliationRequired(_, let code, let message):
                throw OperatorManagerClientError.reconciliationRequired(
                    code: code,
                    message: message
                )
            }
        }
    }

    func projectStatus(projectID: String) async throws -> OperatorProject {
        let project: OperatorProject = try await request(
            method: "POST",
            path: "/api/manager/projects/status",
            body: ProjectIdentityBody(projectID: projectID)
        )
        guard project.projectID.caseInsensitiveCompare(projectID) == .orderedSame else {
            throw OperatorManagerClientError.invalidPayload(
                "project status did not match the requested project identity"
            )
        }
        return project
    }

    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt {
        try await request(
            method: "POST",
            path: "/api/manager/projects/reset-generation",
            body: ProjectGenerationBody(projectID: projectID, projectGeneration: generation)
        )
    }

    func relinkProject(
        projectID: String,
        generation: UInt64,
        path: String
    ) async throws -> OperatorRelinkReceipt {
        guard let identifier = UUID(uuidString: projectID),
              generation > 0,
              generation < UInt64(Int64.max),
              !path.isEmpty,
              path.utf8.count <= ManagerRoutes.maximumProjectRelinkPathBytes,
              (path as NSString).isAbsolutePath else {
            throw OperatorManagerClientError.invalidPayload(
                "project relink requires one project UUID, generation, and absolute path"
            )
        }
        do {
            let receipt = try await managerClient.relinkProject(
                projectID: identifier,
                expectedGeneration: generation,
                path: path
            )
            return OperatorRelinkReceipt(
                projectID: receipt.projectID,
                canonicalRoot: receipt.canonicalRoot,
                priorGeneration: receipt.priorGeneration,
                newGeneration: receipt.newGeneration,
                invalidatedBindingCount: receipt.invalidatedBindingCount,
                completedAt: receipt.completedAt,
                reconciled: receipt.reconciled
            )
        } catch let error as ManagerDashboardClient.ClientError {
            switch error {
            case .invalidEndpoint:
                throw OperatorManagerClientError.invalidEndpoint
            case .invalidResponse:
                throw OperatorManagerClientError.invalidResponse
            case .invalidRequest(let message):
                throw OperatorManagerClientError.invalidPayload(message)
            case .rejected(let status, let message):
                throw OperatorManagerClientError.rejected(status: status, message: message)
            case .reconciliationRequired(_, let code, let message):
                throw OperatorManagerClientError.reconciliationRequired(
                    code: code,
                    message: message
                )
            }
        }
    }

    func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun {
        try await self.request(
            method: "POST",
            path: "/api/manager/runs/start",
            body: request,
            timeoutInterval: 18
        )
    }

    func runStatus(runID: String) async throws -> OperatorRun {
        try await request(
            method: "POST",
            path: "/api/manager/runs/status",
            body: RunIdentityBody(runID: runID)
        )
    }

    func controlRun(runID: String, action: OperatorRunControlAction) async throws -> OperatorRun {
        guard let identifier = UUID(uuidString: runID), runID.utf8.count <= 36 else {
            throw OperatorManagerClientError.invalidPayload("run identifier must be a UUID")
        }
        return try await request(
            method: "POST",
            path: "/api/manager/runs/control",
            body: RunControlBody(
                runID: identifier.uuidString.lowercased(),
                action: action
            ),
            timeoutInterval: 18
        )
    }

    func cancelRuntimeJob(jobID: String) async throws -> OperatorRuntimeJob {
        guard let identifier = UUID(uuidString: jobID), jobID.utf8.count <= 36 else {
            throw OperatorManagerClientError.invalidPayload("runtime job identifier must be a UUID")
        }
        return try await request(
            method: "POST",
            path: "/api/manager/runtime-jobs/cancel",
            body: RuntimeJobIdentityBody(jobID: identifier.uuidString.lowercased()),
            timeoutInterval: 18
        )
    }

    func probeProvider(
        adapterID: String,
        mode: OperatorProviderProbeMode
    ) async throws -> OperatorProvider {
        let bytes = Array(adapterID.utf8)
        guard !bytes.isEmpty,
              bytes.count <= ManagerNode.maximumProviderAdapterIDBytes,
              adapterID == ManagerNode.nativeSessionHostAdapterID else {
            throw OperatorManagerClientError.invalidPayload(
                "provider adapter identifier must name the registered native session host"
            )
        }
        return try await request(
            method: "POST",
            path: "/api/manager/provider/probe",
            body: ProviderProbeBody(adapterID: adapterID, mode: mode),
            timeoutInterval: 35
        )
    }

    private func request<Response: Decodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        unavailableMessage: String? = nil,
        timeoutInterval: TimeInterval = 4
    ) async throws -> Response {
        try await perform(
            method: method,
            path: path,
            queryItems: queryItems,
            body: nil,
            unavailableMessage: unavailableMessage,
            timeoutInterval: timeoutInterval
        )
    }

    private func request<Response: Decodable, Body: Encodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Body,
        unavailableMessage: String? = nil,
        timeoutInterval: TimeInterval = 4
    ) async throws -> Response {
        try await perform(
            method: method,
            path: path,
            queryItems: queryItems,
            body: try encoder.encode(body),
            unavailableMessage: unavailableMessage,
            timeoutInterval: timeoutInterval
        )
    }

    private func perform<Response: Decodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: Data?,
        unavailableMessage: String?,
        timeoutInterval: TimeInterval
    ) async throws -> Response {
        guard DashboardRequestPolicy.isConfiguredLoopbackHost(host) else {
            throw OperatorManagerClientError.invalidEndpoint
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw OperatorManagerClientError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if ManagerMutationAuthorizer.requiresAuthorization(method: method, path: path) {
            request.setValue(
                "Bearer \(try credentials.bearerToken())",
                forHTTPHeaderField: "Authorization"
            )
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OperatorManagerClientError.invalidResponse
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw OperatorManagerClientError.responseTooLarge(maximumBytes: Self.maximumResponseBytes)
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 404, let unavailableMessage {
                throw OperatorManagerClientError.capabilityUnavailable(unavailableMessage)
            }
            if http.statusCode == 422,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["code"] as? String == "autonomy_tool_configuration_invalid",
               object["retryable"] as? Bool == false {
                throw OperatorManagerClientError.configurationRejected(
                    code: "autonomy_tool_configuration_invalid",
                    message: (object["message"] as? String) ?? "Allowed tools are invalid"
                )
            }
            throw OperatorManagerClientError.rejected(
                status: http.statusCode,
                message: Self.errorMessage(from: data)
            )
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw OperatorManagerClientError.invalidPayload(error.localizedDescription)
        }
    }

    private static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(1_024), encoding: .utf8) ?? "unknown"
        }
        return (object["message"] as? String)
            ?? (object["error"] as? String)
            ?? "unknown"
    }
}

final class UnavailableOperatorManagerClient: OperatorManagerClientProtocol, @unchecked Sendable {
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func snapshot(limit: Int, cursor: String?) async throws -> OperatorSnapshot { throw error }
    func autonomyStatus() async throws -> OperatorAutonomySummary { throw error }
    func settings() async throws -> ManagerSettings { throw error }
    func updateSettings(_ patch: ManagerSettingsPatch) async throws -> ManagerSettings { throw error }
    func registerProject(
        _ request: OperatorProjectRegistrationRequest
    ) async throws -> OperatorProjectRegistrationOutcome {
        throw error
    }
    func projectStatus(projectID: String) async throws -> OperatorProject { throw error }
    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt { throw error }
    func relinkProject(
        projectID: String,
        generation: UInt64,
        path: String
    ) async throws -> OperatorRelinkReceipt { throw error }
    func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun { throw error }
    func runStatus(runID: String) async throws -> OperatorRun { throw error }
    func controlRun(runID: String, action: OperatorRunControlAction) async throws -> OperatorRun { throw error }
    func cancelRuntimeJob(jobID: String) async throws -> OperatorRuntimeJob { throw error }
    func providerConfiguration() async throws -> ProviderConfigurationSnapshot { throw error }
    func updateProviderConfiguration(_ update: ProviderConfigurationUpdate) async throws -> ProviderConfigurationSnapshot {
        throw error
    }
    func providerModels() async throws -> ProviderModelInventory { throw error }
    func probeProvider(
        adapterID: String,
        mode: OperatorProviderProbeMode
    ) async throws -> OperatorProvider { throw error }

    private var error: OperatorManagerClientError { .disabled(reason) }
}

/// Keeps feature view models attached to one stable client seam when manager
/// settings change the loopback endpoint. The lock is released before every
/// asynchronous operation.
final class OperatorManagerClientRouter: OperatorManagerClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var client: any OperatorManagerClientProtocol

    init(client: any OperatorManagerClientProtocol) {
        self.client = client
    }

    func replace(with client: any OperatorManagerClientProtocol) {
        lock.lock()
        self.client = client
        lock.unlock()
    }

    func snapshot(limit: Int, cursor: String?) async throws -> OperatorSnapshot {
        try await current.snapshot(limit: limit, cursor: cursor)
    }

    func autonomyStatus() async throws -> OperatorAutonomySummary {
        try await current.autonomyStatus()
    }

    func settings() async throws -> ManagerSettings {
        try await current.settings()
    }

    func updateSettings(_ patch: ManagerSettingsPatch) async throws -> ManagerSettings {
        try await current.updateSettings(patch)
    }

    func registerProject(
        _ request: OperatorProjectRegistrationRequest
    ) async throws -> OperatorProjectRegistrationOutcome {
        try await current.registerProject(request)
    }

    func projectStatus(projectID: String) async throws -> OperatorProject {
        try await current.projectStatus(projectID: projectID)
    }

    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt {
        try await current.resetProject(projectID: projectID, generation: generation)
    }

    func relinkProject(
        projectID: String,
        generation: UInt64,
        path: String
    ) async throws -> OperatorRelinkReceipt {
        try await current.relinkProject(
            projectID: projectID,
            generation: generation,
            path: path
        )
    }

    func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun {
        try await current.startRun(request)
    }

    func runStatus(runID: String) async throws -> OperatorRun {
        try await current.runStatus(runID: runID)
    }

    func controlRun(runID: String, action: OperatorRunControlAction) async throws -> OperatorRun {
        try await current.controlRun(runID: runID, action: action)
    }

    func cancelRuntimeJob(jobID: String) async throws -> OperatorRuntimeJob {
        try await current.cancelRuntimeJob(jobID: jobID)
    }

    func providerConfiguration() async throws -> ProviderConfigurationSnapshot {
        try await current.providerConfiguration()
    }

    func updateProviderConfiguration(_ update: ProviderConfigurationUpdate) async throws -> ProviderConfigurationSnapshot {
        try await current.updateProviderConfiguration(update)
    }

    func providerModels() async throws -> ProviderModelInventory {
        try await current.providerModels()
    }

    func probeProvider(
        adapterID: String,
        mode: OperatorProviderProbeMode
    ) async throws -> OperatorProvider {
        try await current.probeProvider(adapterID: adapterID, mode: mode)
    }

    private var current: any OperatorManagerClientProtocol {
        lock.lock()
        let value = client
        lock.unlock()
        return value
    }
}

private struct ProjectIdentityBody: Encodable {
    let projectID: String
    enum CodingKeys: String, CodingKey { case projectID = "project_id" }
}

private struct ProjectGenerationBody: Encodable {
    let projectID: String
    let projectGeneration: UInt64
    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectGeneration = "project_generation"
    }
}

private struct RunIdentityBody: Encodable {
    let runID: String
    enum CodingKeys: String, CodingKey { case runID = "run_id" }
}

private struct RunControlBody: Encodable {
    let runID: String
    let action: OperatorRunControlAction
    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case action
    }
}

private struct RuntimeJobIdentityBody: Encodable {
    let jobID: String
    enum CodingKeys: String, CodingKey { case jobID = "job_id" }
}

private struct ProviderProbeBody: Encodable {
    let adapterID: String
    let mode: OperatorProviderProbeMode

    enum CodingKeys: String, CodingKey {
        case adapterID = "adapter_id"
        case mode
    }
}

// OperatorManagerClient.swift
// Typed, bounded loopback transport for native operator state and commands.

import Foundation
import ForgeConductorCore

protocol OperatorManagerClientProtocol: Sendable {
    func snapshot(limit: Int, cursor: String?) async throws -> OperatorSnapshot
    func autonomyStatus() async throws -> OperatorAutonomySummary
    func settings() async throws -> ManagerSettings
    func updateSettings(_ patch: ManagerSettingsPatch) async throws -> ManagerSettings
    func registerProject(_ request: OperatorProjectRegistrationRequest) async throws -> OperatorProject
    func projectStatus(projectID: String) async throws -> OperatorProject
    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt
    func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun
    func runStatus(runID: String) async throws -> OperatorRun
    func controlRun(runID: String, action: OperatorRunControlAction) async throws -> OperatorRun
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
    case rejected(status: Int, message: String)
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
        case .rejected(let status, let message):
            "Manager request failed with HTTP \(status): \(message)"
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

    func registerProject(_ request: OperatorProjectRegistrationRequest) async throws -> OperatorProject {
        try await self.request(
            method: "POST",
            path: "/api/manager/projects/register",
            body: request
        )
    }

    func projectStatus(projectID: String) async throws -> OperatorProject {
        try await request(
            method: "POST",
            path: "/api/manager/projects/status",
            body: ProjectIdentityBody(projectID: projectID)
        )
    }

    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt {
        try await request(
            method: "POST",
            path: "/api/manager/projects/reset-generation",
            body: ProjectGenerationBody(projectID: projectID, projectGeneration: generation)
        )
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
        try await request(
            method: "POST",
            path: "/api/manager/runs/control",
            body: RunControlBody(runID: runID, action: action),
            timeoutInterval: 18
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
    func registerProject(_ request: OperatorProjectRegistrationRequest) async throws -> OperatorProject {
        throw error
    }
    func projectStatus(projectID: String) async throws -> OperatorProject { throw error }
    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt { throw error }
    func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun { throw error }
    func runStatus(runID: String) async throws -> OperatorRun { throw error }
    func controlRun(runID: String, action: OperatorRunControlAction) async throws -> OperatorRun { throw error }

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

    func registerProject(_ request: OperatorProjectRegistrationRequest) async throws -> OperatorProject {
        try await current.registerProject(request)
    }

    func projectStatus(projectID: String) async throws -> OperatorProject {
        try await current.projectStatus(projectID: projectID)
    }

    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt {
        try await current.resetProject(projectID: projectID, generation: generation)
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

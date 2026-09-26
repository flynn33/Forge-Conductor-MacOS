// OperatorManagerClient.swift
// Typed, bounded loopback transport for native operator state and commands.

import Foundation
import ForgeConductorCore

protocol OperatorManagerClientProtocol: Sendable {
    func snapshot(limit: Int, cursor: String?) async throws -> OperatorSnapshot
    func activitySnapshot(
        limit: Int,
        runID: String,
        projectID: String,
        projectGeneration: UInt64
    ) async throws -> OperatorSnapshot
    func autonomyStatus() async throws -> OperatorAutonomySummary
    func settings() async throws -> ManagerSettings
    func updateSettings(_ patch: ManagerSettingsPatch) async throws -> ManagerSettings
    func registerProject(
        _ request: OperatorProjectRegistrationRequest
    ) async throws -> OperatorProjectRegistrationOutcome
    func projectStatus(projectID: String) async throws -> OperatorProject
    func removeProject(projectID: String, generation: UInt64) async throws -> OperatorProjectArchiveReceipt
    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt
    func instructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue
    func instructionPackageCatalog(
        projectID: String,
        generation: UInt64,
        contentSHA256: String
    ) async throws -> OperatorInstructionDocumentCatalog
    func importInstructionPackage(
        projectID: String,
        generation: UInt64,
        sourcePath: String
    ) async throws -> OperatorInstructionQueue
    func importRunInstructionArtifact(
        projectID: String,
        generation: UInt64,
        runID: String,
        sourcePath: String
    ) async throws -> ProjectRunInstructionArtifact
    func assembleRunInstructionArtifact(
        projectID: String,
        generation: UInt64,
        runID: String,
        packageIDs: [String],
        sourcePath: String?
    ) async throws -> ProjectRunInstructionArtifact
    func reorderInstructionPackages(
        projectID: String,
        generation: UInt64,
        packageIDs: [String],
        expectedRevision: UInt64
    ) async throws -> OperatorInstructionQueue
    func removeInstructionPackage(
        projectID: String,
        generation: UInt64,
        packageID: String
    ) async throws -> OperatorInstructionQueue
    func startInstructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue
    func stopInstructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue
    func clearProjectContent(
        operationID: UUID,
        projectID: String,
        generation: UInt64,
        mode: OperatorProjectContentClearMode
    ) async throws -> OperatorProjectContentClearReceipt
    func relinkProject(
        projectID: String,
        generation: UInt64,
        path: String
    ) async throws -> OperatorRelinkReceipt
    func projectToolPermissions(
        projectID: String,
        generation: UInt64
    ) async throws -> ManagerToolPermissionSnapshot
    func updateProjectToolPermissions(
        _ update: ManagerToolPermissionUpdate
    ) async throws -> ManagerToolPermissionSnapshot
    func prepareRun(_ request: OperatorRunStartRequest) async throws -> ManagerRunPreparationResult
    func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun
    func runStatus(runID: String) async throws -> OperatorRun
    func controlRun(runID: String, action: OperatorRunControlAction) async throws -> OperatorRun
    func deleteRun(
        runID: String,
        projectID: String,
        generation: UInt64
    ) async throws -> AutonomousRunDeletionReceipt
    func cancelRuntimeJob(jobID: String) async throws -> OperatorRuntimeJob
    func providerConfiguration() async throws -> ProviderConfigurationSnapshot
    func updateProviderConfiguration(_ update: ProviderConfigurationUpdate) async throws -> ProviderConfigurationSnapshot
    func providerModels() async throws -> ProviderModelInventory
    func prepareProvider() async throws -> ManagerProviderPreparationResult
    func prepareProviderWithoutResumingRuns() async throws -> ManagerProviderPreparationResult
    func providerIntegrations() async throws -> ProviderIntegrationsSnapshot
    func updateProviderSelection(
        _ request: ProviderSelectionRequest
    ) async throws -> ProviderIntegrationOperationSnapshot
    func providerOperation(
        operationID: String
    ) async throws -> ProviderIntegrationOperationSnapshot
    func cancelProviderOperation(
        operationID: String
    ) async throws -> ProviderIntegrationOperationSnapshot
    func repairProviderIntegration(
        _ request: ProviderIntegrationMutationRequest
    ) async throws -> ProviderIntegrationOperationSnapshot
    func removeProviderIntegration(
        _ request: ProviderIntegrationMutationRequest
    ) async throws -> ProviderIntegrationOperationSnapshot
    func probeProvider(
        adapterID: String,
        mode: OperatorProviderProbeMode
    ) async throws -> OperatorProvider
}

extension OperatorManagerClientProtocol {
    func activitySnapshot(
        limit: Int,
        runID: String,
        projectID: String,
        projectGeneration: UInt64
    ) async throws -> OperatorSnapshot {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Authenticated managed activity is unavailable from this manager client."
        )
    }

    func deleteRun(
        runID: String,
        projectID: String,
        generation: UInt64
    ) async throws -> AutonomousRunDeletionReceipt {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Task deletion is unavailable from this manager client."
        )
    }

    func prepareProvider() async throws -> ManagerProviderPreparationResult {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Automatic provider preparation is unavailable from this manager client."
        )
    }

    func prepareProviderWithoutResumingRuns() async throws -> ManagerProviderPreparationResult {
        try await prepareProvider()
    }

    func providerIntegrations() async throws -> ProviderIntegrationsSnapshot {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Provider selection is unavailable from this manager client."
        )
    }

    func updateProviderSelection(
        _ request: ProviderSelectionRequest
    ) async throws -> ProviderIntegrationOperationSnapshot {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Provider selection is unavailable from this manager client."
        )
    }

    func providerOperation(
        operationID: String
    ) async throws -> ProviderIntegrationOperationSnapshot {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Provider setup status is unavailable from this manager client."
        )
    }

    func cancelProviderOperation(
        operationID: String
    ) async throws -> ProviderIntegrationOperationSnapshot {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Provider setup cancellation is unavailable from this manager client."
        )
    }

    func repairProviderIntegration(
        _ request: ProviderIntegrationMutationRequest
    ) async throws -> ProviderIntegrationOperationSnapshot {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Provider integration repair is unavailable from this manager client."
        )
    }

    func removeProviderIntegration(
        _ request: ProviderIntegrationMutationRequest
    ) async throws -> ProviderIntegrationOperationSnapshot {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Provider integration removal is unavailable from this manager client."
        )
    }

    func projectToolPermissions(
        projectID: String,
        generation: UInt64
    ) async throws -> ManagerToolPermissionSnapshot {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Project tool permissions are unavailable from this manager client."
        )
    }

    func updateProjectToolPermissions(
        _ update: ManagerToolPermissionUpdate
    ) async throws -> ManagerToolPermissionSnapshot {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Project tool permissions are unavailable from this manager client."
        )
    }

    func prepareRun(_ request: OperatorRunStartRequest) async throws -> ManagerRunPreparationResult {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Project-bound run preparation is unavailable from this manager client."
        )
    }

    func removeProject(projectID: String, generation: UInt64) async throws -> OperatorProjectArchiveReceipt {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Project removal is unavailable from this manager client."
        )
    }

    func instructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Instruction packages are unavailable from this manager client."
        )
    }

    func instructionPackageCatalog(
        projectID: String,
        generation: UInt64,
        contentSHA256: String
    ) async throws -> OperatorInstructionDocumentCatalog {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Instruction document catalogs are unavailable from this manager client."
        )
    }

    func importInstructionPackage(projectID: String, generation: UInt64, sourcePath: String) async throws -> OperatorInstructionQueue {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Instruction package import is unavailable from this manager client."
        )
    }

    func importRunInstructionArtifact(
        projectID: String,
        generation: UInt64,
        runID: String,
        sourcePath: String
    ) async throws -> ProjectRunInstructionArtifact {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Run instruction artifact import is unavailable from this manager client."
        )
    }

    func assembleRunInstructionArtifact(
        projectID: String,
        generation: UInt64,
        runID: String,
        packageIDs: [String],
        sourcePath: String?
    ) async throws -> ProjectRunInstructionArtifact {
        guard packageIDs.isEmpty, let sourcePath else {
            throw OperatorManagerClientError.capabilityUnavailable(
                "Selecting existing instruction packages is unavailable from this manager client."
            )
        }
        return try await importRunInstructionArtifact(
            projectID: projectID,
            generation: generation,
            runID: runID,
            sourcePath: sourcePath
        )
    }

    func reorderInstructionPackages(projectID: String, generation: UInt64, packageIDs: [String], expectedRevision: UInt64) async throws -> OperatorInstructionQueue {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Instruction package ordering is unavailable from this manager client."
        )
    }

    func removeInstructionPackage(projectID: String, generation: UInt64, packageID: String) async throws -> OperatorInstructionQueue {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Instruction package removal is unavailable from this manager client."
        )
    }

    func startInstructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Ordered project execution is unavailable from this manager client."
        )
    }

    func stopInstructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Ordered project execution is unavailable from this manager client."
        )
    }

    func clearProjectContent(
        operationID: UUID,
        projectID: String,
        generation: UInt64,
        mode: OperatorProjectContentClearMode
    ) async throws -> OperatorProjectContentClearReceipt {
        throw OperatorManagerClientError.capabilityUnavailable(
            "Project content clearing is unavailable from this manager client."
        )
    }

    func budgetPolicy(scope: BudgetPolicyScope) async throws -> BudgetPolicySelection {
        try await settings().resolvedBudgetPolicy(scope: scope)
    }

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

    func prepareProvider() async throws -> ManagerProviderPreparationResult {
        try await prepareProvider(resumeWaitingRuns: true)
    }

    func prepareProviderWithoutResumingRuns() async throws -> ManagerProviderPreparationResult {
        try await prepareProvider(resumeWaitingRuns: false)
    }

    private func prepareProvider(
        resumeWaitingRuns: Bool
    ) async throws -> ManagerProviderPreparationResult {
        try await request(
            method: "POST",
            path: "/api/manager/provider/prepare",
            body: ProviderPreparationBody(resumeWaitingRuns: resumeWaitingRuns),
            unavailableMessage: "Automatic provider preparation is unavailable. Update or restart the manager from this build.",
            timeoutInterval: 45
        )
    }

    func providerIntegrations() async throws -> ProviderIntegrationsSnapshot {
        try await request(
            method: "GET",
            path: "/api/manager/providers",
            unavailableMessage: "Provider selection is unavailable. Update or restart the manager from this build.",
            timeoutInterval: 25
        )
    }

    func updateProviderSelection(
        _ selection: ProviderSelectionRequest
    ) async throws -> ProviderIntegrationOperationSnapshot {
        try await request(
            method: "PUT",
            path: "/api/manager/providers/selection",
            body: selection,
            unavailableMessage: "Provider selection is unavailable. Update or restart the manager from this build.",
            timeoutInterval: 45
        )
    }

    func providerOperation(
        operationID: String
    ) async throws -> ProviderIntegrationOperationSnapshot {
        let identifier = try validatedProviderOperationID(operationID)
        return try await request(
            method: "GET",
            path: "/api/manager/provider-operations/\(identifier)",
            unavailableMessage: "Provider setup status is unavailable. Update or restart the manager from this build.",
            timeoutInterval: 12
        )
    }

    func cancelProviderOperation(
        operationID: String
    ) async throws -> ProviderIntegrationOperationSnapshot {
        let identifier = try validatedProviderOperationID(operationID)
        return try await request(
            method: "POST",
            path: "/api/manager/provider-operations/\(identifier)/cancel",
            body: EmptyProviderPreparationBody(),
            unavailableMessage: "Provider setup cancellation is unavailable. Update or restart the manager from this build.",
            timeoutInterval: 18
        )
    }

    func repairProviderIntegration(
        _ mutation: ProviderIntegrationMutationRequest
    ) async throws -> ProviderIntegrationOperationSnapshot {
        try await request(
            method: "POST",
            path: "/api/manager/providers/\(mutation.providerID.rawValue)/repair",
            body: mutation,
            unavailableMessage: "Provider integration repair is unavailable. Update or restart the manager from this build.",
            timeoutInterval: 45
        )
    }

    func removeProviderIntegration(
        _ mutation: ProviderIntegrationMutationRequest
    ) async throws -> ProviderIntegrationOperationSnapshot {
        try await request(
            method: "DELETE",
            path: "/api/manager/providers/\(mutation.providerID.rawValue)/integration",
            body: mutation,
            unavailableMessage: "Provider integration removal is unavailable. Update or restart the manager from this build.",
            timeoutInterval: 45
        )
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

    func activitySnapshot(
        limit: Int = 100,
        runID: String,
        projectID: String,
        projectGeneration: UInt64
    ) async throws -> OperatorSnapshot {
        let boundedLimit = min(max(limit, 1), 100)
        return try await request(
            method: "GET",
            path: "/api/manager/operator/activity",
            queryItems: [
                URLQueryItem(name: "limit", value: "\(boundedLimit)"),
                URLQueryItem(name: "run_id", value: runID),
                URLQueryItem(name: "project_id", value: projectID),
                URLQueryItem(name: "project_generation", value: String(projectGeneration)),
            ],
            unavailableMessage: "Authenticated managed activity is unavailable. Update or restart the manager from this build, then retry."
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
                repositoryIdentity: request.repositoryIdentity,
                authorizeProjectRoot: request.authorizeProjectRoot
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
                            repositoryIdentity: result.repositoryIdentityAssertion,
                            authorizeProjectRoot: request.authorizeProjectRoot
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
            case .responseTooLarge:
                throw OperatorManagerClientError.responseTooLarge(
                    maximumBytes: Self.maximumResponseBytes
                )
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

    func removeProject(
        projectID: String,
        generation: UInt64
    ) async throws -> OperatorProjectArchiveReceipt {
        try validateProjectGeneration(projectID: projectID, generation: generation)
        let receipt: OperatorProjectArchiveReceipt = try await request(
            method: "POST",
            path: "/api/manager/projects/remove",
            body: ProjectGenerationBody(projectID: projectID, projectGeneration: generation),
            timeoutInterval: 12
        )
        guard receipt.projectID.caseInsensitiveCompare(projectID) == .orderedSame,
              receipt.priorGeneration == generation,
              receipt.archivedGeneration == generation + 1,
              receipt.invalidatedBindingCount >= 0 else {
            throw OperatorManagerClientError.invalidPayload(
                "project removal receipt did not match the selected project generation"
            )
        }
        return receipt
    }

    func instructionQueue(
        projectID: String,
        generation: UInt64
    ) async throws -> OperatorInstructionQueue {
        try validateProjectGeneration(projectID: projectID, generation: generation)
        var queue: OperatorInstructionQueue = try await request(
            method: "POST",
            path: "/api/manager/projects/instruction-packages",
            body: ProjectGenerationBody(projectID: projectID, projectGeneration: generation)
        )
        queue = try validated(
            queue,
            projectID: projectID,
            generation: generation,
            expectedCursor: 0
        )
        var packages = queue.packages
        let revision = queue.revision
        let running = queue.running
        let total = queue.totalPackages ?? packages.count
        var cursor = queue.nextCursor
        while let pageCursor = cursor {
            let page: OperatorInstructionQueue = try await request(
                method: "POST",
                path: "/api/manager/projects/instruction-packages",
                body: InstructionQueuePageBody(
                    projectID: projectID,
                    projectGeneration: generation,
                    cursor: pageCursor,
                    limit: 128
                )
            )
            let validatedPage = try validated(
                page,
                projectID: projectID,
                generation: generation,
                expectedCursor: pageCursor
            )
            guard validatedPage.revision == revision,
                  validatedPage.running == running,
                  (validatedPage.totalPackages ?? total) == total else {
                throw OperatorManagerClientError.invalidPayload(
                    "instruction queue changed while its pages were loading"
                )
            }
            packages.append(contentsOf: validatedPage.packages)
            cursor = validatedPage.nextCursor
        }
        guard packages.count == total else {
            throw OperatorManagerClientError.invalidPayload(
                "instruction queue paging did not return its declared package count"
            )
        }
        return OperatorInstructionQueue(
            projectID: queue.projectID,
            projectGeneration: queue.projectGeneration,
            revision: revision,
            running: running,
            totalPackages: total,
            cursor: 0,
            nextCursor: nil,
            packages: packages
        )
    }

    func instructionPackageCatalog(
        projectID: String,
        generation: UInt64,
        contentSHA256: String
    ) async throws -> OperatorInstructionDocumentCatalog {
        try validateProjectGeneration(projectID: projectID, generation: generation)
        guard contentSHA256.count == 64,
              contentSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw OperatorManagerClientError.invalidPayload(
                "instruction catalog requires one SHA-256 package identity"
            )
        }
        var catalog: OperatorInstructionDocumentCatalog = try await request(
            method: "POST",
            path: "/api/manager/projects/instruction-packages/catalog",
            body: InstructionCatalogPageBody(
                projectID: projectID,
                projectGeneration: generation,
                contentSHA256: contentSHA256,
                cursor: 0,
                limit: 128
            )
        )
        try validateCatalog(
            catalog, projectID: projectID, generation: generation,
            contentSHA256: contentSHA256, expectedCursor: 0
        )
        var documents = catalog.documents
        var cursor = catalog.nextCursor
        while let pageCursor = cursor {
            let page: OperatorInstructionDocumentCatalog = try await request(
                method: "POST",
                path: "/api/manager/projects/instruction-packages/catalog",
                body: InstructionCatalogPageBody(
                    projectID: projectID,
                    projectGeneration: generation,
                    contentSHA256: contentSHA256,
                    cursor: pageCursor,
                    limit: 128
                )
            )
            try validateCatalog(
                page, projectID: projectID, generation: generation,
                contentSHA256: contentSHA256, expectedCursor: pageCursor
            )
            guard page.totalDocuments == catalog.totalDocuments else {
                throw OperatorManagerClientError.invalidPayload(
                    "instruction catalog changed while its pages were loading"
                )
            }
            documents.append(contentsOf: page.documents)
            cursor = page.nextCursor
        }
        guard documents.count == catalog.totalDocuments,
              Set(documents.map(\.id)).count == documents.count else {
            throw OperatorManagerClientError.invalidPayload(
                "instruction catalog did not return every unique source file"
            )
        }
        catalog = OperatorInstructionDocumentCatalog(
            projectID: catalog.projectID,
            projectGeneration: catalog.projectGeneration,
            contentSHA256: catalog.contentSHA256,
            totalDocuments: catalog.totalDocuments,
            cursor: 0,
            nextCursor: nil,
            documents: documents
        )
        return catalog
    }

    private func validateCatalog(
        _ catalog: OperatorInstructionDocumentCatalog,
        projectID: String,
        generation: UInt64,
        contentSHA256: String,
        expectedCursor: Int
    ) throws {
        let expectedNext = expectedCursor + catalog.documents.count < catalog.totalDocuments
            ? expectedCursor + catalog.documents.count
            : nil
        guard catalog.projectID.caseInsensitiveCompare(projectID) == .orderedSame,
              catalog.projectGeneration == generation,
              catalog.contentSHA256.caseInsensitiveCompare(contentSHA256) == .orderedSame,
              catalog.cursor == expectedCursor,
              catalog.totalDocuments >= expectedCursor + catalog.documents.count,
              catalog.nextCursor == expectedNext,
              catalog.documents.count <= 128,
              catalog.documents.allSatisfy({
                  !$0.sourcePath.isEmpty && $0.originalSHA256.count == 64
              }) else {
            throw OperatorManagerClientError.invalidPayload(
                "instruction catalog response did not match the selected package"
            )
        }
    }

    func importInstructionPackage(
        projectID: String,
        generation: UInt64,
        sourcePath: String
    ) async throws -> OperatorInstructionQueue {
        try validateProjectGeneration(projectID: projectID, generation: generation)
        guard !sourcePath.isEmpty, sourcePath.utf8.count <= 4_096,
              (sourcePath as NSString).isAbsolutePath else {
            throw OperatorManagerClientError.invalidPayload(
                "instruction package path must be a bounded absolute path"
            )
        }
        let queue: OperatorInstructionQueue = try await request(
            method: "POST",
            path: "/api/manager/projects/instruction-packages/import",
            body: InstructionPackageImportBody(
                projectID: projectID,
                projectGeneration: generation,
                sourcePath: sourcePath
            ),
            timeoutInterval: 12
        )
        return try validated(queue, projectID: projectID, generation: generation)
    }

    func importRunInstructionArtifact(
        projectID: String,
        generation: UInt64,
        runID: String,
        sourcePath: String
    ) async throws -> ProjectRunInstructionArtifact {
        try validateProjectGeneration(projectID: projectID, generation: generation)
        guard UUID(uuidString: runID) != nil else {
            throw OperatorManagerClientError.invalidPayload(
                "run instruction artifact requires a run UUID"
            )
        }
        guard !sourcePath.isEmpty, sourcePath.utf8.count <= 4_096,
              (sourcePath as NSString).isAbsolutePath else {
            throw OperatorManagerClientError.invalidPayload(
                "run instruction artifact path must be a bounded absolute path"
            )
        }
        let artifact: ProjectRunInstructionArtifact = try await request(
            method: "POST",
            path: "/api/manager/runs/instruction-artifacts/import",
            body: RunInstructionArtifactImportBody(
                runID: runID,
                projectID: projectID,
                projectGeneration: generation,
                sourcePath: sourcePath,
                packageIDs: nil
            ),
            timeoutInterval: 20
        )
        guard artifact.runID.description == runID.lowercased(),
              artifact.projectID.description == projectID.lowercased(),
              artifact.projectGeneration.rawValue == generation else {
            throw OperatorManagerClientError.invalidPayload(
                "manager returned an instruction artifact for a different run or project generation"
            )
        }
        return artifact
    }

    func assembleRunInstructionArtifact(
        projectID: String,
        generation: UInt64,
        runID: String,
        packageIDs: [String],
        sourcePath: String?
    ) async throws -> ProjectRunInstructionArtifact {
        try validateProjectGeneration(projectID: projectID, generation: generation)
        guard UUID(uuidString: runID) != nil,
              packageIDs.count <= ProjectInstructionQueueStore.maximumRunArtifactInputs,
              Set(packageIDs.map { $0.lowercased() }).count == packageIDs.count,
              packageIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw OperatorManagerClientError.invalidPayload(
                "run instruction assembly requires a run UUID and unique package UUIDs"
            )
        }
        if let sourcePath {
            guard !sourcePath.isEmpty, sourcePath.utf8.count <= 4_096,
                  (sourcePath as NSString).isAbsolutePath else {
                throw OperatorManagerClientError.invalidPayload(
                    "run instruction artifact path must be a bounded absolute path"
                )
            }
        } else if packageIDs.isEmpty {
            throw OperatorManagerClientError.invalidPayload(
                "run instruction assembly requires a package or imported source"
            )
        }
        let artifact: ProjectRunInstructionArtifact = try await request(
            method: "POST",
            path: "/api/manager/runs/instruction-artifacts/import",
            body: RunInstructionArtifactImportBody(
                runID: runID,
                projectID: projectID,
                projectGeneration: generation,
                sourcePath: sourcePath,
                packageIDs: packageIDs.isEmpty ? nil : packageIDs
            ),
            timeoutInterval: 20
        )
        guard artifact.runID.description == runID.lowercased(),
              artifact.projectID.description == projectID.lowercased(),
              artifact.projectGeneration.rawValue == generation else {
            throw OperatorManagerClientError.invalidPayload(
                "run instruction artifact identity did not match the request"
            )
        }
        return artifact
    }

    func reorderInstructionPackages(
        projectID: String,
        generation: UInt64,
        packageIDs: [String],
        expectedRevision: UInt64
    ) async throws -> OperatorInstructionQueue {
        try validateProjectGeneration(projectID: projectID, generation: generation)
        guard packageIDs.count <= ProjectInstructionQueueStore.maximumPackages,
              Set(packageIDs.map { $0.lowercased() }).count == packageIDs.count,
              packageIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw OperatorManagerClientError.invalidPayload(
                "instruction package order must contain each package UUID once"
            )
        }
        let queue: OperatorInstructionQueue = try await request(
            method: "POST",
            path: "/api/manager/projects/instruction-packages/reorder",
            body: InstructionPackageReorderBody(
                projectID: projectID,
                projectGeneration: generation,
                packageIDs: packageIDs,
                expectedRevision: expectedRevision
            )
        )
        return try validated(queue, projectID: projectID, generation: generation)
    }

    func removeInstructionPackage(
        projectID: String,
        generation: UInt64,
        packageID: String
    ) async throws -> OperatorInstructionQueue {
        try validateProjectGeneration(projectID: projectID, generation: generation)
        guard UUID(uuidString: packageID) != nil else {
            throw OperatorManagerClientError.invalidPayload("instruction package identifier must be a UUID")
        }
        let queue: OperatorInstructionQueue = try await request(
            method: "POST",
            path: "/api/manager/projects/instruction-packages/remove",
            body: InstructionPackageIdentityBody(
                projectID: projectID,
                projectGeneration: generation,
                packageID: packageID
            )
        )
        return try validated(queue, projectID: projectID, generation: generation)
    }

    func startInstructionQueue(
        projectID: String,
        generation: UInt64
    ) async throws -> OperatorInstructionQueue {
        try await instructionQueueCommand(
            "start", projectID: projectID, generation: generation
        )
    }

    func stopInstructionQueue(
        projectID: String,
        generation: UInt64
    ) async throws -> OperatorInstructionQueue {
        try await instructionQueueCommand(
            "stop", projectID: projectID, generation: generation
        )
    }

    private func instructionQueueCommand(
        _ action: String,
        projectID: String,
        generation: UInt64
    ) async throws -> OperatorInstructionQueue {
        try validateProjectGeneration(projectID: projectID, generation: generation)
        let queue: OperatorInstructionQueue = try await request(
            method: "POST",
            path: "/api/manager/projects/instruction-packages/\(action)",
            body: ProjectGenerationBody(projectID: projectID, projectGeneration: generation),
            timeoutInterval: 12
        )
        return try validated(queue, projectID: projectID, generation: generation)
    }

    private func validateProjectGeneration(projectID: String, generation: UInt64) throws {
        guard UUID(uuidString: projectID) != nil,
              generation > 0,
              generation < UInt64(Int64.max) else {
            throw OperatorManagerClientError.invalidPayload(
                "project command requires one valid project identity and generation"
            )
        }
    }

    private func validated(
        _ queue: OperatorInstructionQueue,
        projectID: String,
        generation: UInt64,
        expectedCursor: Int = 0
    ) throws -> OperatorInstructionQueue {
        let cursor = queue.cursor ?? expectedCursor
        let total = queue.totalPackages ?? queue.packages.count
        let expectedNext = cursor + queue.packages.count < total
            ? cursor + queue.packages.count
            : nil
        guard queue.projectID.caseInsensitiveCompare(projectID) == .orderedSame,
              queue.projectGeneration == generation,
              cursor == expectedCursor,
              (0...ProjectInstructionQueueStore.maximumPackages).contains(total),
              total >= cursor + queue.packages.count,
              queue.nextCursor == expectedNext,
              queue.packages.count <= ProjectInstructionQueueStore.maximumPackages,
              queue.packages.enumerated().allSatisfy({ index, package in
                  package.projectID.caseInsensitiveCompare(projectID) == .orderedSame
                      && package.projectGeneration == generation
                      && UUID(uuidString: package.id) != nil
                      && package.position == cursor + index
              }) else {
            throw OperatorManagerClientError.invalidPayload(
                "instruction queue response did not match the selected project and order"
            )
        }
        return queue
    }

    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt {
        guard UUID(uuidString: projectID) != nil,
              generation > 0,
              generation < UInt64(Int64.max) else {
            throw OperatorManagerClientError.invalidPayload(
                "project reset requires one valid project identity and generation"
            )
        }
        let successor = generation.addingReportingOverflow(1)
        guard !successor.overflow else {
            throw OperatorManagerClientError.invalidPayload(
                "project reset generation cannot be advanced"
            )
        }
        let receipt: OperatorResetReceipt = try await request(
            method: "POST",
            path: "/api/manager/projects/reset-generation",
            body: ProjectGenerationBody(projectID: projectID, projectGeneration: generation)
        )
        guard let receiptProjectID = receipt.projectID,
              receiptProjectID.caseInsensitiveCompare(projectID) == .orderedSame,
              receipt.priorGeneration == generation,
              receipt.newGeneration == successor.partialValue,
              receipt.invalidatedBindingCount >= 0 else {
            throw OperatorManagerClientError.invalidPayload(
                "project reset receipt did not match the requested project generation"
            )
        }
        return receipt
    }

    func clearProjectContent(
        operationID: UUID,
        projectID: String,
        generation: UInt64,
        mode: OperatorProjectContentClearMode
    ) async throws -> OperatorProjectContentClearReceipt {
        guard let projectUUID = UUID(uuidString: projectID),
              generation > 0,
              generation < UInt64(Int64.max) else {
            throw OperatorManagerClientError.invalidPayload(
                "project content clearing requires one operation, project, generation, and mode"
            )
        }
        let successor = generation.addingReportingOverflow(1)
        guard !successor.overflow else {
            throw OperatorManagerClientError.invalidPayload(
                "project content clear generation cannot be advanced"
            )
        }
        let receipt: OperatorProjectContentClearReceipt = try await request(
            method: "POST",
            path: "/api/manager/projects/clear-content",
            body: ProjectContentClearBody(
                operationID: operationID,
                projectID: projectUUID,
                projectGeneration: generation,
                mode: mode
            )
        )
        guard UUID(uuidString: receipt.operationID) == operationID,
              receipt.projectID.caseInsensitiveCompare(projectID) == .orderedSame,
              receipt.mode == mode,
              receipt.priorGeneration == generation,
              receipt.newGeneration == successor.partialValue,
              receipt.memoryRecordCount >= 0,
              receipt.continuityRecordCount >= 0,
              receipt.runHistoryCount >= 0,
              receipt.invalidatedBindingCount >= 0 else {
            throw OperatorManagerClientError.invalidPayload(
                "project content clear receipt is inconsistent; reconcile the original operation"
            )
        }
        return receipt
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
            case .responseTooLarge:
                throw OperatorManagerClientError.responseTooLarge(
                    maximumBytes: Self.maximumResponseBytes
                )
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
        return try await self.request(
            method: "POST",
            path: "/api/manager/runs/start",
            body: request,
            timeoutInterval: 18
        )
    }

    func projectToolPermissions(
        projectID: String,
        generation: UInt64
    ) async throws -> ManagerToolPermissionSnapshot {
        try await request(
            method: "POST",
            path: "/api/manager/projects/tool-permissions/status",
            body: ProjectGenerationBody(projectID: projectID, projectGeneration: generation)
        )
    }

    func updateProjectToolPermissions(
        _ update: ManagerToolPermissionUpdate
    ) async throws -> ManagerToolPermissionSnapshot {
        try await request(
            method: "PUT",
            path: "/api/manager/projects/tool-permissions",
            body: update
        )
    }

    func prepareRun(_ request: OperatorRunStartRequest) async throws -> ManagerRunPreparationResult {
        return try await self.request(
            method: "POST",
            path: "/api/manager/runs/prepare",
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

    func deleteRun(
        runID: String,
        projectID: String,
        generation: UInt64
    ) async throws -> AutonomousRunDeletionReceipt {
        guard let runUUID = UUID(uuidString: runID),
              let projectUUID = UUID(uuidString: projectID),
              generation > 0,
              generation < UInt64(Int64.max) else {
            throw OperatorManagerClientError.invalidPayload(
                "Task deletion requires exact run, project, and generation identities"
            )
        }
        let receipt: AutonomousRunDeletionReceipt = try await request(
            method: "POST",
            path: "/api/manager/runs/delete",
            body: RunDeletionBody(
                runID: runUUID.uuidString.lowercased(),
                projectID: projectUUID.uuidString.lowercased(),
                projectGeneration: generation
            ),
            timeoutInterval: 12
        )
        guard receipt.runID == RunID(runUUID),
              receipt.projectID == ProjectID(projectUUID),
              receipt.projectGeneration.rawValue == generation,
              receipt.priorState.isTerminal,
              ISO8601.date(from: receipt.deletedAt) != nil else {
            throw OperatorManagerClientError.invalidPayload(
                "Task deletion receipt did not match the selected task"
            )
        }
        return receipt
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

    private func validatedProviderOperationID(_ value: String) throws -> String {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty,
              bytes.count <= ProviderIntegrationContract.maximumOperationIDBytes,
              bytes.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 45
                      || byte == 46
                      || byte == 95
              }) else {
            throw OperatorManagerClientError.invalidPayload(
                "provider operation identifier contains unsupported path characters"
            )
        }
        return value
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await BoundedURLSessionLoader.data(
                for: request,
                using: session,
                maximumBytes: Self.maximumResponseBytes
            )
        } catch BoundedURLSessionLoaderError.responseTooLarge {
            throw OperatorManagerClientError.responseTooLarge(
                maximumBytes: Self.maximumResponseBytes
            )
        } catch BoundedURLSessionLoaderError.invalidMaximumBytes {
            throw OperatorManagerClientError.invalidPayload(
                "Manager response byte limit is invalid"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw OperatorManagerClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 404, let unavailableMessage {
                throw OperatorManagerClientError.capabilityUnavailable(unavailableMessage)
            }
            if path == "/api/manager/runs/start",
               (http.statusCode == 409 || http.statusCode == 422),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = object["code"] as? String,
               object["retryable"] as? Bool == false {
                throw OperatorManagerClientError.configurationRejected(
                    code: code,
                    message: (object["message"] as? String) ?? "Run configuration was rejected"
                )
            }
            if http.statusCode == 409,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["code"] as? String == "run_preparation_stale" {
                throw OperatorManagerClientError.configurationRejected(
                    code: "run_preparation_stale",
                    message: (object["message"] as? String)
                        ?? "Run preparation changed"
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
    func removeProject(projectID: String, generation: UInt64) async throws -> OperatorProjectArchiveReceipt { throw error }
    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt { throw error }
    func instructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue { throw error }
    func importInstructionPackage(projectID: String, generation: UInt64, sourcePath: String) async throws -> OperatorInstructionQueue { throw error }
    func reorderInstructionPackages(projectID: String, generation: UInt64, packageIDs: [String], expectedRevision: UInt64) async throws -> OperatorInstructionQueue { throw error }
    func removeInstructionPackage(projectID: String, generation: UInt64, packageID: String) async throws -> OperatorInstructionQueue { throw error }
    func startInstructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue { throw error }
    func stopInstructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue { throw error }
    func clearProjectContent(
        operationID: UUID,
        projectID: String,
        generation: UInt64,
        mode: OperatorProjectContentClearMode
    ) async throws -> OperatorProjectContentClearReceipt { throw error }
    func relinkProject(
        projectID: String,
        generation: UInt64,
        path: String
    ) async throws -> OperatorRelinkReceipt { throw error }
    func prepareRun(_ request: OperatorRunStartRequest) async throws -> ManagerRunPreparationResult { throw error }
    func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun { throw error }
    func runStatus(runID: String) async throws -> OperatorRun { throw error }
    func controlRun(runID: String, action: OperatorRunControlAction) async throws -> OperatorRun { throw error }
    func cancelRuntimeJob(jobID: String) async throws -> OperatorRuntimeJob { throw error }
    func providerConfiguration() async throws -> ProviderConfigurationSnapshot { throw error }
    func updateProviderConfiguration(_ update: ProviderConfigurationUpdate) async throws -> ProviderConfigurationSnapshot {
        throw error
    }
    func providerModels() async throws -> ProviderModelInventory { throw error }
    func providerIntegrations() async throws -> ProviderIntegrationsSnapshot { throw error }
    func updateProviderSelection(
        _ request: ProviderSelectionRequest
    ) async throws -> ProviderIntegrationOperationSnapshot { throw error }
    func providerOperation(
        operationID: String
    ) async throws -> ProviderIntegrationOperationSnapshot { throw error }
    func cancelProviderOperation(
        operationID: String
    ) async throws -> ProviderIntegrationOperationSnapshot { throw error }
    func repairProviderIntegration(
        _ request: ProviderIntegrationMutationRequest
    ) async throws -> ProviderIntegrationOperationSnapshot { throw error }
    func removeProviderIntegration(
        _ request: ProviderIntegrationMutationRequest
    ) async throws -> ProviderIntegrationOperationSnapshot { throw error }
    func probeProvider(
        adapterID: String,
        mode: OperatorProviderProbeMode
    ) async throws -> OperatorProvider { throw error }

    private var error: OperatorManagerClientError { .disabled(reason) }
}

extension UnavailableOperatorManagerClient: RuneForgeManagerClientProtocol {
    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot { throw error }

    func addRuneForgeSource(
        path: String,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw error }

    func refreshRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw error }

    func removeRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource { throw error }

    func runeForgeViolations(
        cursor: Int64,
        limit: Int,
        state: PolicyViolationProjectionState?
    ) async throws -> StjornarvaldViolationPage { throw error }

    func scheduleRuneForgeScan(
        requestID: UUID,
        reason: String
    ) async throws -> StjornarvaldScanReceipt { throw error }

    func requestRuneForgeExport(
        format: StjornarvaldExportFormat,
        destination: String,
        filters: StjornarvaldExportFilters,
        requestID: UUID
    ) async throws -> StjornarvaldExportReceipt { throw error }
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

    func activitySnapshot(
        limit: Int,
        runID: String,
        projectID: String,
        projectGeneration: UInt64
    ) async throws -> OperatorSnapshot {
        try await current.activitySnapshot(
            limit: limit,
            runID: runID,
            projectID: projectID,
            projectGeneration: projectGeneration
        )
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

    func removeProject(projectID: String, generation: UInt64) async throws -> OperatorProjectArchiveReceipt {
        try await current.removeProject(projectID: projectID, generation: generation)
    }

    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt {
        try await current.resetProject(projectID: projectID, generation: generation)
    }

    func instructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue {
        try await current.instructionQueue(projectID: projectID, generation: generation)
    }

    func instructionPackageCatalog(
        projectID: String,
        generation: UInt64,
        contentSHA256: String
    ) async throws -> OperatorInstructionDocumentCatalog {
        try await current.instructionPackageCatalog(
            projectID: projectID,
            generation: generation,
            contentSHA256: contentSHA256
        )
    }

    func importInstructionPackage(projectID: String, generation: UInt64, sourcePath: String) async throws -> OperatorInstructionQueue {
        try await current.importInstructionPackage(projectID: projectID, generation: generation, sourcePath: sourcePath)
    }

    func importRunInstructionArtifact(
        projectID: String,
        generation: UInt64,
        runID: String,
        sourcePath: String
    ) async throws -> ProjectRunInstructionArtifact {
        try await current.importRunInstructionArtifact(
            projectID: projectID,
            generation: generation,
            runID: runID,
            sourcePath: sourcePath
        )
    }

    func assembleRunInstructionArtifact(
        projectID: String,
        generation: UInt64,
        runID: String,
        packageIDs: [String],
        sourcePath: String?
    ) async throws -> ProjectRunInstructionArtifact {
        try await current.assembleRunInstructionArtifact(
            projectID: projectID,
            generation: generation,
            runID: runID,
            packageIDs: packageIDs,
            sourcePath: sourcePath
        )
    }

    func reorderInstructionPackages(projectID: String, generation: UInt64, packageIDs: [String], expectedRevision: UInt64) async throws -> OperatorInstructionQueue {
        try await current.reorderInstructionPackages(
            projectID: projectID,
            generation: generation,
            packageIDs: packageIDs,
            expectedRevision: expectedRevision
        )
    }

    func removeInstructionPackage(projectID: String, generation: UInt64, packageID: String) async throws -> OperatorInstructionQueue {
        try await current.removeInstructionPackage(
            projectID: projectID,
            generation: generation,
            packageID: packageID
        )
    }

    func startInstructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue {
        try await current.startInstructionQueue(projectID: projectID, generation: generation)
    }

    func stopInstructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue {
        try await current.stopInstructionQueue(projectID: projectID, generation: generation)
    }

    func clearProjectContent(
        operationID: UUID,
        projectID: String,
        generation: UInt64,
        mode: OperatorProjectContentClearMode
    ) async throws -> OperatorProjectContentClearReceipt {
        try await current.clearProjectContent(
            operationID: operationID,
            projectID: projectID,
            generation: generation,
            mode: mode
        )
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

    func projectToolPermissions(
        projectID: String,
        generation: UInt64
    ) async throws -> ManagerToolPermissionSnapshot {
        try await current.projectToolPermissions(
            projectID: projectID,
            generation: generation
        )
    }

    func updateProjectToolPermissions(
        _ update: ManagerToolPermissionUpdate
    ) async throws -> ManagerToolPermissionSnapshot {
        try await current.updateProjectToolPermissions(update)
    }

    func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun {
        try await current.startRun(request)
    }

    func prepareRun(_ request: OperatorRunStartRequest) async throws -> ManagerRunPreparationResult {
        try await current.prepareRun(request)
    }

    func runStatus(runID: String) async throws -> OperatorRun {
        try await current.runStatus(runID: runID)
    }

    func controlRun(runID: String, action: OperatorRunControlAction) async throws -> OperatorRun {
        try await current.controlRun(runID: runID, action: action)
    }

    func deleteRun(
        runID: String,
        projectID: String,
        generation: UInt64
    ) async throws -> AutonomousRunDeletionReceipt {
        try await current.deleteRun(
            runID: runID,
            projectID: projectID,
            generation: generation
        )
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

    func prepareProvider() async throws -> ManagerProviderPreparationResult {
        try await current.prepareProvider()
    }

    func prepareProviderWithoutResumingRuns() async throws -> ManagerProviderPreparationResult {
        try await current.prepareProviderWithoutResumingRuns()
    }

    func providerIntegrations() async throws -> ProviderIntegrationsSnapshot {
        try await current.providerIntegrations()
    }

    func updateProviderSelection(
        _ request: ProviderSelectionRequest
    ) async throws -> ProviderIntegrationOperationSnapshot {
        try await current.updateProviderSelection(request)
    }

    func providerOperation(
        operationID: String
    ) async throws -> ProviderIntegrationOperationSnapshot {
        try await current.providerOperation(operationID: operationID)
    }

    func cancelProviderOperation(
        operationID: String
    ) async throws -> ProviderIntegrationOperationSnapshot {
        try await current.cancelProviderOperation(operationID: operationID)
    }

    func repairProviderIntegration(
        _ request: ProviderIntegrationMutationRequest
    ) async throws -> ProviderIntegrationOperationSnapshot {
        try await current.repairProviderIntegration(request)
    }

    func removeProviderIntegration(
        _ request: ProviderIntegrationMutationRequest
    ) async throws -> ProviderIntegrationOperationSnapshot {
        try await current.removeProviderIntegration(request)
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

extension OperatorManagerHTTPClient: RuneForgeManagerClientProtocol {
    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot {
        try await managerClient.stjornarvaldSnapshot(limit: 100, newestFirst: true)
    }

    func runeForgeSnapshot(
        projectID: String?,
        projectGeneration: UInt64?
    ) async throws -> StjornarvaldManagerSnapshot {
        try await managerClient.stjornarvaldSnapshot(
            limit: 100,
            newestFirst: true,
            projectID: projectID,
            projectGeneration: projectGeneration
        )
    }

    func addRuneForgeSource(
        path: String,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource {
        try await managerClient.addStjornarvaldSource(
            selectedPath: path,
            requestID: requestID
        )
    }

    func refreshRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource {
        try await managerClient.refreshStjornarvaldSource(
            sourceID: sourceID,
            requestID: requestID
        )
    }

    func removeRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource {
        try await managerClient.removeStjornarvaldSource(
            sourceID: sourceID,
            requestID: requestID
        )
    }

    func runeForgeViolations(
        cursor: Int64,
        limit: Int,
        state: PolicyViolationProjectionState?
    ) async throws -> StjornarvaldViolationPage {
        try await managerClient.stjornarvaldViolations(
            cursor: cursor,
            limit: limit,
            state: state
        )
    }

    func scheduleRuneForgeScan(
        requestID: UUID,
        reason: String
    ) async throws -> StjornarvaldScanReceipt {
        try await managerClient.scheduleStjornarvaldScan(
            requestID: requestID,
            reason: reason
        )
    }

    func requestRuneForgeExport(
        format: StjornarvaldExportFormat,
        destination: String,
        filters: StjornarvaldExportFilters,
        requestID: UUID
    ) async throws -> StjornarvaldExportReceipt {
        try await managerClient.requestStjornarvaldExport(
            format: format,
            destination: destination,
            filters: filters,
            requestID: requestID
        )
    }
}

extension OperatorManagerClientRouter: RuneForgeManagerClientProtocol {
    func runeForgeSnapshot() async throws -> StjornarvaldManagerSnapshot {
        try await runeForgeClient.runeForgeSnapshot()
    }

    func runeForgeSnapshot(
        projectID: String?,
        projectGeneration: UInt64?
    ) async throws -> StjornarvaldManagerSnapshot {
        try await runeForgeClient.runeForgeSnapshot(
            projectID: projectID,
            projectGeneration: projectGeneration
        )
    }

    func addRuneForgeSource(
        path: String,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource {
        try await runeForgeClient.addRuneForgeSource(path: path, requestID: requestID)
    }

    func refreshRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource {
        try await runeForgeClient.refreshRuneForgeSource(
            sourceID: sourceID,
            requestID: requestID
        )
    }

    func removeRuneForgeSource(
        sourceID: PolicySourceID,
        requestID: UUID
    ) async throws -> DevelopmentPolicySource {
        try await runeForgeClient.removeRuneForgeSource(
            sourceID: sourceID,
            requestID: requestID
        )
    }

    func runeForgeViolations(
        cursor: Int64,
        limit: Int,
        state: PolicyViolationProjectionState?
    ) async throws -> StjornarvaldViolationPage {
        try await runeForgeClient.runeForgeViolations(
            cursor: cursor,
            limit: limit,
            state: state
        )
    }

    func scheduleRuneForgeScan(
        requestID: UUID,
        reason: String
    ) async throws -> StjornarvaldScanReceipt {
        try await runeForgeClient.scheduleRuneForgeScan(
            requestID: requestID,
            reason: reason
        )
    }

    func requestRuneForgeExport(
        format: StjornarvaldExportFormat,
        destination: String,
        filters: StjornarvaldExportFilters,
        requestID: UUID
    ) async throws -> StjornarvaldExportReceipt {
        try await runeForgeClient.requestRuneForgeExport(
            format: format,
            destination: destination,
            filters: filters,
            requestID: requestID
        )
    }

    private var runeForgeClient: any RuneForgeManagerClientProtocol {
        get throws {
            guard let value = current as? any RuneForgeManagerClientProtocol else {
                throw OperatorManagerClientError.capabilityUnavailable(
                    "Rune Forge is unavailable from this manager client."
                )
            }
            return value
        }
    }
}

private struct ProjectIdentityBody: Encodable {
    let projectID: String
    enum CodingKeys: String, CodingKey { case projectID = "project_id" }
}

private struct EmptyProviderPreparationBody: Encodable {}

private struct ProviderPreparationBody: Encodable {
    let resumeWaitingRuns: Bool

    enum CodingKeys: String, CodingKey {
        case resumeWaitingRuns = "resume_waiting_runs"
    }
}

private struct ProjectGenerationBody: Encodable {
    let projectID: String
    let projectGeneration: UInt64
    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectGeneration = "project_generation"
    }
}

private struct InstructionQueuePageBody: Encodable {
    let projectID: String
    let projectGeneration: UInt64
    let cursor: Int
    let limit: Int
    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case cursor, limit
    }
}

private struct InstructionCatalogPageBody: Encodable {
    let projectID: String
    let projectGeneration: UInt64
    let contentSHA256: String
    let cursor: Int
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case contentSHA256 = "content_sha256"
        case cursor, limit
    }
}

private struct InstructionPackageImportBody: Encodable {
    let projectID: String
    let projectGeneration: UInt64
    let sourcePath: String
    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case sourcePath = "source_path"
    }
}

private struct RunInstructionArtifactImportBody: Encodable {
    let runID: String
    let projectID: String
    let projectGeneration: UInt64
    let sourcePath: String?
    let packageIDs: [String]?
    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case sourcePath = "source_path"
        case packageIDs = "package_ids"
    }
}

private struct InstructionPackageReorderBody: Encodable {
    let projectID: String
    let projectGeneration: UInt64
    let packageIDs: [String]
    let expectedRevision: UInt64
    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case packageIDs = "package_ids"
        case expectedRevision = "expected_revision"
    }
}

private struct InstructionPackageIdentityBody: Encodable {
    let projectID: String
    let projectGeneration: UInt64
    let packageID: String
    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case packageID = "package_id"
    }
}

private struct ProjectContentClearBody: Encodable {
    let operationID: UUID
    let projectID: UUID
    let projectGeneration: UInt64
    let mode: OperatorProjectContentClearMode

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case mode
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

private struct RunDeletionBody: Encodable {
    let runID: String
    let projectID: String
    let projectGeneration: UInt64

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
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

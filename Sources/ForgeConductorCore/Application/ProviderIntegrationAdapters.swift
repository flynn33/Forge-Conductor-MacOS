// ProviderIntegrationAdapters.swift
// What: Adapts LM Studio deployment and desktop-host plugin installation to provider selection.
// How: Bounded synchronous host operations run off the caller actor and return redacted receipts.
// Why: One provider toggle must provision only Forge-owned artifacts before selection becomes durable.

import Foundation

private final class ProviderIntegrationAdapterOperationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationHandlers: [String: @Sendable () -> Void] = [:]

    func register(
        operationID: String,
        cancellationHandler: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        cancellationHandlers[operationID] = cancellationHandler
        lock.unlock()
    }

    func finish(operationID: String) {
        lock.lock()
        cancellationHandlers.removeValue(forKey: operationID)
        lock.unlock()
    }

    func cancel(operationID: String) {
        lock.lock()
        let cancellationHandler = cancellationHandlers[operationID]
        lock.unlock()
        cancellationHandler?()
    }
}

private func runProviderIntegrationOperation<Value: Sendable>(
    operationID: String,
    priority: TaskPriority,
    registry: ProviderIntegrationAdapterOperationRegistry,
    operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
    try Task.checkCancellation()
    let task = Task.detached(priority: priority) { try operation() }
    registry.register(operationID: operationID) { task.cancel() }
    defer { registry.finish(operationID: operationID) }
    let value = try await task.value
    try Task.checkCancellation()
    return value
}

enum ProviderIntegrationAdapterFactory {
    static func makeCoordinator(app: ForgeApp) throws -> ProviderIntegrationCoordinator {
        let executable = app.lmStudioDeploy.resolveServeBinary(preferred: nil)
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let configuredGrokHome = ProcessInfo.processInfo.environment["GROK_HOME"].flatMap { value in
            value.isEmpty
                ? nil
                : URL(
                    fileURLWithPath: (value as NSString).expandingTildeInPath,
                    isDirectory: true
                )
        }
        let installer = DesktopProviderPluginInstaller(
            roots: DesktopProviderPluginFilesystemRoots(
                forgeOwnedRoot: app.paths.managedProvidersDir
                    .appendingPathComponent("desktop-provider-plugins", isDirectory: true),
                userHome: userHome,
                grokHome: configuredGrokHome,
                forgeHome: app.paths.home
            )
        )

        return try ProviderIntegrationCoordinator(
            paths: app.paths,
            adapters: [
                LMStudioProviderIntegrationAdapter(deployService: app.lmStudioDeploy),
                DesktopHostProviderIntegrationAdapter(
                    providerID: .claudeDesktop,
                    host: .claudeCodeDesktop,
                    installer: installer,
                    forgeExecutable: executable
                ),
                DesktopHostProviderIntegrationAdapter(
                    providerID: .codexDesktop,
                    host: .codexDesktop,
                    installer: installer,
                    forgeExecutable: executable
                ),
                DesktopHostProviderIntegrationAdapter(
                    providerID: .grokBuild,
                    host: .grokBuild,
                    installer: installer,
                    forgeExecutable: executable
                ),
            ]
        )
    }
}

struct LMStudioProviderIntegrationAdapter: ProviderIntegrationAdapting {
    let providerID = ProviderIntegrationID.lmStudio

    private let statusProvider: @Sendable () -> LMStudioMCPPluginInstaller.PluginStatus
    private let deployProvider: @Sendable () throws -> LMStudioMCPPluginInstaller.InstallResult
    private let removeProvider: @Sendable () throws -> Void
    private let now: @Sendable () -> Date
    private let operations = ProviderIntegrationAdapterOperationRegistry()

    init(
        deployService: LMStudioDeployService,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        statusProvider = { deployService.status(preferredBinary: nil) }
        deployProvider = { try deployService.deploy(preferredBinary: nil) }
        removeProvider = { _ = try LMStudioMCPPluginInstaller.uninstall() }
        self.now = now
    }

    init(
        status: @escaping @Sendable () -> LMStudioMCPPluginInstaller.PluginStatus,
        deploy: @escaping @Sendable () throws -> LMStudioMCPPluginInstaller.InstallResult,
        remove: @escaping @Sendable () throws -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        statusProvider = status
        deployProvider = deploy
        removeProvider = remove
        self.now = now
    }

    func inspect(operationID: String) async throws -> ProviderIntegrationInspection {
        let status = try await runProviderIntegrationOperation(
            operationID: operationID,
            priority: .utility,
            registry: operations,
            operation: statusProvider
        )
        guard status.isFullyInstalled,
              let receipt = try receipt(for: status) else {
            return try ProviderIntegrationInspection(
                state: .requiresProvisioning,
                detail: "LM Studio's Forge MCP registrations require deployment."
            )
        }
        return try ProviderIntegrationInspection(
            state: .ready,
            detail: "LM Studio's primary, fallback, and continuity registrations are verified.",
            receipt: receipt
        )
    }

    func provision(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationAdapterResult {
        let result = try await runProviderIntegrationOperation(
            operationID: request.operationID,
            priority: .userInitiated,
            registry: operations,
            operation: deployProvider
        )
        let timestamp = ISO8601.string(from: now())
        let receipt = try ProviderIntegrationReceipt(
            providerID: providerID,
            artifactVersion: result.deploymentID,
            installedAt: timestamp,
            verifiedAt: timestamp,
            metadata: [
                "mcp_registered": "true",
                "mcp_roles": "primary,fallback,continuity",
            ]
        )
        return try ProviderIntegrationAdapterResult(
            state: result.ok ? .ready : .awaitingUserAction,
            detail: result.ok
                ? "LM Studio accepted and verified the Forge MCP deployment."
                : "Forge deployed LM Studio's MCP registrations, but host activation still requires attention.",
            receipt: receipt
        )
    }

    func repair(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationAdapterResult {
        try await provision(request)
    }

    func remove(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationRemovalResult {
        _ = try await runProviderIntegrationOperation(
            operationID: request.operationID,
            priority: .userInitiated,
            registry: operations,
            operation: removeProvider
        )
        return try ProviderIntegrationRemovalResult(
            state: .ready,
            detail: "Forge-owned LM Studio registrations were removed."
        )
    }

    func cancel(operationID: String) async {
        operations.cancel(operationID: operationID)
    }

    private func receipt(
        for status: LMStudioMCPPluginInstaller.PluginStatus
    ) throws -> ProviderIntegrationReceipt? {
        guard let deploymentID = status.deploymentID,
              !deploymentID.isEmpty else { return nil }
        let timestamp = ISO8601.string(from: now())
        return try ProviderIntegrationReceipt(
            providerID: providerID,
            artifactVersion: deploymentID,
            installedAt: timestamp,
            verifiedAt: timestamp,
            metadata: [
                "mcp_registered": status.mcpJSONRegistered ? "true" : "false",
                "mcp_roles": "primary,fallback,continuity",
            ]
        )
    }
}

struct DesktopHostProviderIntegrationAdapter: ProviderIntegrationAdapting {
    let providerID: ProviderIntegrationID

    private let host: DesktopProviderPluginHost
    private let installer: DesktopProviderPluginInstaller
    private let request: DesktopProviderPluginRequest
    private let now: @Sendable () -> Date
    private let operations = ProviderIntegrationAdapterOperationRegistry()

    init(
        providerID: ProviderIntegrationID,
        host: DesktopProviderPluginHost,
        installer: DesktopProviderPluginInstaller,
        forgeExecutable: URL,
        pluginVersion: String = ForgeApp.version,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(host.providerID == providerID.rawValue)
        self.providerID = providerID
        self.host = host
        self.installer = installer
        request = DesktopProviderPluginRequest(
            host: host,
            forgeExecutable: forgeExecutable,
            includeMCP: true,
            pluginVersion: pluginVersion
        )
        self.now = now
    }

    func inspect(operationID: String) async throws -> ProviderIntegrationInspection {
        let status = try await runProviderIntegrationOperation(
            operationID: operationID,
            priority: .utility,
            registry: operations
        ) {
            try installer.status(for: request)
        }
        guard status.isReady,
              let receipt = try integrationReceipt(from: status) else {
            return try ProviderIntegrationInspection(
                state: .requiresProvisioning,
                detail: "The Forge plugin package or host registration requires provisioning."
            )
        }
        return try ProviderIntegrationInspection(
            state: .ready,
            detail: status.detail,
            receipt: receipt
        )
    }

    func provision(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationAdapterResult {
        let status = try await runProviderIntegrationOperation(
            operationID: request.operationID,
            priority: .userInitiated,
            registry: operations
        ) {
            try installer.install(self.request)
        }
        guard let receipt = try integrationReceipt(from: status) else {
            throw ProviderIntegrationError.invalidAdapterResult(
                reason: "desktop_plugin_install_missing_receipt"
            )
        }
        return try ProviderIntegrationAdapterResult(
            state: status.isReady ? .ready : .awaitingUserAction,
            detail: status.detail,
            receipt: receipt
        )
    }

    func repair(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationAdapterResult {
        try await provision(request)
    }

    func remove(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationRemovalResult {
        let status = try await runProviderIntegrationOperation(
            operationID: request.operationID,
            priority: .userInitiated,
            registry: operations
        ) {
            try installer.remove(self.request)
        }
        return try ProviderIntegrationRemovalResult(
            state: status.disposition == .removed ? .ready : .awaitingUserAction,
            detail: status.detail
        )
    }

    func cancel(operationID: String) async {
        operations.cancel(operationID: operationID)
    }

    private func integrationReceipt(
        from status: DesktopProviderPluginStatus
    ) throws -> ProviderIntegrationReceipt? {
        guard let pluginReceipt = status.receipt else { return nil }
        let metadata: [String: String] = [
            "package_sha256": pluginReceipt.packageSHA256,
            "mcp_enabled": pluginReceipt.mcpEnabled ? "true" : "false",
            "host_registration_verified": status.configurationVerified ? "true" : "false",
            "deployment_verified": status.deploymentVerified ? "true" : "false",
            "hook_trust_review_required": status.warnings.contains(.hookTrustReviewRequired)
                ? "true" : "false",
        ]
        return try ProviderIntegrationReceipt(
            providerID: providerID,
            artifactVersion: pluginReceipt.pluginVersion,
            installedAt: pluginReceipt.installedAt,
            verifiedAt: ISO8601.string(from: now()),
            metadata: metadata
        )
    }
}

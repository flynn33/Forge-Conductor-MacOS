// AppModel.swift
// What: The main-actor presentation model shared by every native app module.
// How: It composes Core services, transforms typed telemetry into view state,
// and serializes user actions through observable properties and controllers.
// Why: One presentation owner prevents views from duplicating lifecycle and I/O logic.

import Foundation
import Combine
import AppKit
import ForgeConductorCore
import SwiftUI

struct AppBootstrapSnapshot: Sendable {
    let app: ForgeApp
    let pluginStatus: LMStudioMCPPluginInstaller.PluginStatus?
    let settings: ManagerSettings
}

/// One owner per user-action family. Admission is synchronous and bounded;
/// cancellation is propagated to the worker, and a committed result still wins.
@MainActor
final class AppBackgroundOperation {
    private var task: Task<Void, Never>?
    deinit { task?.cancel() }
    var isRunning: Bool { task != nil }

    @discardableResult
    func start<Value: Sendable>(
        work: @escaping @Sendable () async throws -> Value,
        completion: @escaping @MainActor (Result<Value, Error>) -> Void
    ) -> Bool {
        guard task == nil else { return false }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await work()
        }
        task = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard let self else { return }
            self.task = nil
            completion(result)
        }
        return true
    }

    func cancel() { task?.cancel() }
    func stop() async {
        let pending = task
        pending?.cancel()
        await pending?.value
    }
}

/// Owns one startup worker and its cancellation cleanup. The completion always
/// runs on the main actor after the worker has finished constructing or closing
/// the unpublished application graph.
@MainActor
final class AppBootstrapOperation {
    typealias Factory = @Sendable () throws -> ForgeApp
    typealias PluginStatus = @Sendable (ForgeApp) -> LMStudioMCPPluginInstaller.PluginStatus?
    private let factory: Factory
    private let pluginStatus: PluginStatus
    private var task: Task<Void, Never>?

    init(
        factory: @escaping Factory = { try ForgeApp.bootstrap() },
        pluginStatus: @escaping PluginStatus = { app in
            app.lmStudioDeploy.status(
                preferredBinary: app.lmStudioDeploy.resolveServeBinary(preferred: Bundle.main.executableURL)
            )
        }
    ) {
        self.factory = factory
        self.pluginStatus = pluginStatus
    }

    deinit { task?.cancel() }

    var isRunning: Bool { task != nil }

    @discardableResult
    func start(completion: @escaping @MainActor (Result<AppBootstrapSnapshot, Error>) -> Void) -> Bool {
        guard task == nil else { return false }
        let factory = self.factory
        let pluginStatus = self.pluginStatus
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let app = try factory()
            do {
                try Task.checkCancellation()
                let status = pluginStatus(app)
                let settings = Self.settingsSnapshot(app)
                try Task.checkCancellation()
                return AppBootstrapSnapshot(app: app, pluginStatus: status, settings: settings)
            } catch {
                _ = app.shutdown()
                throw error
            }
        }
        task = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            if Task.isCancelled || self == nil {
                if case .success(let snapshot) = result {
                    _ = await Task.detached { snapshot.app.shutdown() }.value
                }
                self?.task = nil
                if self != nil { completion(.failure(CancellationError())) }
                return
            }
            self?.task = nil
            completion(result)
        }
        return true
    }

    func cancel() { task?.cancel() }

    func stop() async {
        let pending = task
        pending?.cancel()
        await pending?.value
    }

    nonisolated static func settingsSnapshot(_ app: ForgeApp) -> ManagerSettings {
        let config = app.config.model
        let shell = app.config.shellPolicyStatus
        return ManagerSettings(
            dashboardHost: config.dashboard.host, dashboardPort: config.dashboard.port,
            dashboardRefreshSec: config.dashboard.refreshIntervalSec,
            autoRestart: config.manager.autoRestart, watchdogIntervalSec: config.manager.watchdogIntervalSec,
            openBrowserOnStart: config.manager.openBrowserOnStart,
            sessionIdleTTLSec: config.sessions.idleTTLSec,
            shellEnabled: shell.enabled, shellUserDisabled: shell.userDisabled,
            shellPolicyVersion: shell.policyVersion, shellPolicyOrigin: shell.policyOrigin,
            shellMigrationState: shell.migration.state, shellMigrationReceiptValid: shell.migration.receiptValid,
            shellRuntimeCapabilities: shell.runtimes, shellTimeoutSec: config.shell.defaultTimeoutSec,
            logLevel: config.logLevel,
            allowedRoots: ManagerSettingsNormalizer.canonicalAllowedRoots(config.allowedRoots)
        )
    }
}

/// Owns the macOS app's observable state and coordinates every user-facing module.
///
/// Views read immutable projections from this model and send user intent back through
/// its methods. The model keeps process control, persistence, deployment, and telemetry
/// work inside Core services so the SwiftUI layer remains declarative and testable.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var system: SystemMetrics?
    @Published public private(set) var forge: ForgeSnapshot?
    @Published public private(set) var history: [HistoryPoint] = []
    @Published public private(set) var updated: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isBootstrapping = false
    @Published public private(set) var hasLoadedInitialSettings = false
    @Published public private(set) var version: String = ForgeApp.version
    @Published public private(set) var homePath: String = ""
    @Published public private(set) var lastTyped: TelemetrySnapshot?
    @Published public private(set) var managerStatus: ManagerStatus?
    @Published public private(set) var managerMessage: String?
    @Published public private(set) var lmStudioPluginStatus: LMStudioMCPPluginInstaller.PluginStatus?
    @Published public private(set) var lmStudioPluginMessage: String?
    @Published public private(set) var isInstallingPlugin = false
    @Published public private(set) var isExportingDiagnostics = false
    @Published public private(set) var isUpdatingSettings = false
    @Published public private(set) var diagnosticPreview: [DiagnosticEnvelope] = []
    @Published public private(set) var lastExportMessage: String?
    @Published public private(set) var measuredTelemetryHz: Double = 0
    @Published public private(set) var runtimeDiagnosticSnapshot: RuntimeDiagnosticSnapshot?
    @Published public var autoRefresh = true {
        didSet { telemetryBinding.autoRefresh = autoRefresh }
    }
    @Published public var selectedTab: AppTab = .rig
    @Published public var isNavigationVisible = true

    @Published public var setHost: String = "127.0.0.1"
    @Published public var setPort: Int = 7788
    @Published public var setRefresh: Int = 8
    @Published public var setWatchdog: Int = 3
    @Published public var setIdleTTL: Int = 14_400
    @Published public var setShellEnabled: Bool = true
    @Published public var setShellTimeout: Int = 30
    @Published public var setAutoRestart: Bool = true
    @Published public var setAllowedRoots: [String] = []
    @Published public private(set) var allowedRootsMessage: String?
    @Published public private(set) var shellPolicyOrigin: String = "default_enabled"
    @Published public private(set) var shellMigrationState: String = "not_required"
    @Published public private(set) var shellMigrationReceiptValid: Bool = false
    @Published public private(set) var shellRuntimeCapabilities =
        ShellRuntimeCapabilities(zsh: nil, bash: nil, python: nil, powershell: nil)
    @Published public private(set) var secureFilesystemServiceStatus: SecureFilesystemServiceStatus = .notFound
    @Published public private(set) var secureFilesystemOperationalHealth =
        SecureFilesystemOperationalHealth.initial
    @Published public private(set) var secureFilesystemServiceMessage: String?
    @Published public private(set) var secureFilesystemSettingsOperationState =
        SecureFilesystemSettingsOperationState()
    @Published public private(set) var secureFilesystemServiceLifecycleState =
        SecureFilesystemServiceLifecycleState.checking

    public private(set) var app: ForgeApp?
    public private(set) var manager: ManagerNode?
    public private(set) var remoteManager: ManagerDashboardClient?
    public private(set) var deployController: AppDeployController?
    public private(set) var telemetryBinding = AppTelemetryBinding()
    let operatorManagerClient = OperatorManagerClientRouter(
        client: UnavailableOperatorManagerClient(reason: "Manager connection has not been configured yet.")
    )

    private var managerPoll: AnyCancellable?
    private var telemetryBag: AnyCancellable?
    private var managerPollInFlight = false
    private var remoteManagerLastError: String?
    private let bootstrapOperation: AppBootstrapOperation
    private let settingsOperation = AppBackgroundOperation()
    private let pluginStatusOperation = AppBackgroundOperation()
    private var pluginStatusRefreshPending = false
    private let deploymentOperation = AppBackgroundOperation()
    private let diagnosticsExportOperation = AppBackgroundOperation()
    private var preferredServeBinaryURL: URL?
    private let secureFilesystemService = SecureFilesystemServiceController()
    private var secureFilesystemOperationTask: Task<Void, Never>?
    private var secureFilesystemLifecycleObservationGate =
        SecureFilesystemServiceLifecycleObservationGate()

    public enum AppTab: String, CaseIterable, Identifiable, Sendable {
        case rig = "FORGE RIG"
        case mcp = "LM Studio MCP"
        case agents = "Agents"
        case tools = "Tools"
        case feed = "Live Feed"
        case projects = "Projects"
        case autonomy = "Autonomy"
        case continuity = "Continuity"
        case runtimes = "Runtimes"
        case provider = "Provider"
        case evidence = "Events & Evidence"
        case diagnostics = "Diagnostics"
        case manager = "Manager"

        public var id: String { rawValue }

        public var accessibilityID: String {
            switch self {
            case .rig: return "rig"
            case .mcp: return "mcp"
            case .agents: return "agents"
            case .tools: return "tools"
            case .feed: return "feed"
            case .projects: return "projects"
            case .autonomy: return "autonomy"
            case .continuity: return "continuity"
            case .runtimes: return "runtimes"
            case .provider: return "provider"
            case .evidence: return "evidence"
            case .diagnostics: return "diagnostics"
            case .manager: return "manager"
            }
        }
    }

    public convenience init() {
        self.init(bootstrapOperation: AppBootstrapOperation())
    }

    init(bootstrapOperation: AppBootstrapOperation) {
        self.bootstrapOperation = bootstrapOperation
        secureFilesystemService.setLifecycleStateObserver { [weak self] observation in
            self?.applySecureFilesystemLifecycleObservation(observation)
        }
        bootstrap()
        startManagerPoll()
        bindTelemetryMirror()
    }

    public func bootstrap() {
        guard app == nil, !bootstrapOperation.isRunning else { return }
        isBootstrapping = true
        isLoading = true
        lastError = nil
        bootstrapOperation.start { [weak self] result in
            guard let self else { return }
            self.isBootstrapping = false
            switch result {
            case .success(let snapshot):
                self.applyBootstrap(snapshot)
            case .failure(is CancellationError):
                self.isLoading = false
                self.lastError = "Startup cancelled. Retry to start Forge Conductor."
            case .failure(let error):
                self.isLoading = false
                self.lastError = "Bootstrap failed: \(error)"
            }
        }
    }

    public func cancelBootstrap() {
        bootstrapOperation.cancel()
    }

    public func cancelBackgroundOperations() {
        bootstrapOperation.cancel()
        settingsOperation.cancel()
        pluginStatusRefreshPending = false
        pluginStatusOperation.cancel()
        deploymentOperation.cancel()
        diagnosticsExportOperation.cancel()
    }

    func stopBootstrap() async {
        await bootstrapOperation.stop()
    }

    private func applyBootstrap(_ snapshot: AppBootstrapSnapshot) {
        let forgeApp = snapshot.app
        self.app = forgeApp
        self.homePath = forgeApp.paths.home.path
        self.version = ForgeApp.version
        self.deployController = AppDeployController(app: forgeApp)
        telemetryBinding.autoRefresh = autoRefresh
        telemetryBinding.attach(app: forgeApp)
        if CommandLine.arguments.contains("--uitesting") {
            let fixturePort = ProcessInfo.processInfo.environment["FORGE_OPERATOR_UI_TEST_PORT"]
                .flatMap(Int.init)
                .flatMap { (1...65_535).contains($0) ? $0 : nil }
            if let fixturePort {
                let credentials = ManagerControlCredentialStore(paths: forgeApp.paths)
                remoteManager = ManagerDashboardClient(
                    host: "127.0.0.1",
                    port: fixturePort,
                    credentials: credentials
                )
                operatorManagerClient.replace(
                    with: OperatorManagerHTTPClient(
                        host: "127.0.0.1",
                        port: fixturePort,
                        credentials: credentials
                    )
                )
                managerMessage = "Attached to operator UI test fixture"
            } else {
                operatorManagerClient.replace(
                    with: UnavailableOperatorManagerClient(
                        reason: "Manager control is intentionally disabled during UI tests."
                    )
                )
                managerMessage = "Manager disabled during UI tests"
            }
        } else {
            operatorManagerClient.replace(
                with: OperatorManagerHTTPClient(
                    host: forgeApp.config.model.dashboard.host,
                    port: forgeApp.config.model.dashboard.port,
                    credentials: ManagerControlCredentialStore(paths: forgeApp.paths)
                )
            )
            attachToOrStartManager(app: forgeApp)
        }
        apply(settings: snapshot.settings)
        hasLoadedInitialSettings = true
        bootstrapSecureFilesystemService(paths: forgeApp.paths)
        lmStudioPluginStatus = snapshot.pluginStatus
        preferredServeBinaryURL = snapshot.pluginStatus.map { URL(fileURLWithPath: $0.binaryPath) }
        refreshDiagnosticsPreview()
        forgeApp.diagnostics.info("gui_bootstrap", [
            "version": ForgeApp.version,
            "home": forgeApp.paths.home.path,
        ], category: .ui)
        refresh(force: true)
    }

    /// A GUI is a presentation client when the LaunchAgent manager already
    /// owns the dashboard. Only one process is ever allowed to bind the port.
    private func attachToOrStartManager(app forgeApp: ForgeApp) {
        let host = forgeApp.config.model.dashboard.host
        let port = forgeApp.config.model.dashboard.port
        let currentPID = ProcessInfo.processInfo.processIdentifier
        Task { [weak self] in
            let externalPID = await Task.detached {
                var pid = ManagerPIDFile.runningPID(paths: forgeApp.paths)
                if pid == currentPID { pid = nil }
                if pid == nil {
                    switch DashboardPortGuard.inspect(host: host, port: port, selfPID: currentPID) {
                    case .heldByOtherForge(let holder): pid = holder.pid
                    default: break
                    }
                }
                return pid
            }.value

            guard let self else { return }
            if let externalPID {
                manager = nil
                remoteManager = ManagerDashboardClient(
                    host: host,
                    port: port,
                    credentials: ManagerControlCredentialStore(paths: forgeApp.paths)
                )
                managerMessage = "Attached to manager (pid \(externalPID))"
                forgeApp.diagnostics.info("gui_attached_existing_manager", [
                    "manager_pid": "\(externalPID)",
                    "port": "\(port)",
                ], category: .manager)
                refreshRemoteManagerStatus()
                return
            }

            let node = ManagerNode(app: forgeApp)
            do {
                let status = try await Task.detached {
                    do {
                        _ = try node.recoverManagedAutonomy()
                        return try node.startService()
                    } catch {
                        node.shutdownManagedAutonomy()
                        throw error
                    }
                }.value
                manager = node
                remoteManager = nil
                managerStatus = status
                forgeApp.diagnostics.info("gui_dashboard_bound", [
                    "port": "\(status.dashboardPort)",
                    "pid": "\(currentPID)",
                ], category: .manager)
            } catch {
                manager = node
                remoteManager = nil
                managerStatus = node.statusModel()
                lastError = "Dashboard bind failed: \(error.localizedDescription)"
                managerMessage = lastError
                forgeApp.diagnostics.error("gui_dashboard_bind_failed", [
                    "error": "\(error)",
                ], category: .manager)
            }
        }
    }

    /// Mirror complete stream frames into AppModel published fields for views.
    /// Driven by one post-apply event per frame — no snapshot polling timer.
    private func bindTelemetryMirror() {
        telemetryBag?.cancel()
        telemetryBag = telemetryBinding.updates
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncFromTelemetryBinding()
            }
    }

    private func syncFromTelemetryBinding() {
        let b = telemetryBinding
        system = b.system
        forge = b.forge
        history = b.history
        updated = b.updated
        lastTyped = b.lastTyped
        measuredTelemetryHz = b.measuredHz
        runtimeDiagnosticSnapshot = app?.runtimeDiagnosticSnapshot()
        isLoading = isBootstrapping || b.isLoading
        if let e = b.lastError { lastError = e }
    }

    public var preferredServeBinary: URL {
        preferredServeBinaryURL ?? URL(fileURLWithPath: "/usr/bin/false")
    }

    public func refreshLMStudioPluginStatus() {
        guard let app else { return }
        guard !pluginStatusOperation.isRunning else {
            pluginStatusRefreshPending = true
            return
        }
        pluginStatusOperation.start {
            app.lmStudioDeploy.status(
                preferredBinary: app.lmStudioDeploy.resolveServeBinary(preferred: Bundle.main.executableURL)
            )
        } completion: { [weak self] result in
            guard let self else { return }
            if self.pluginStatusRefreshPending {
                self.pluginStatusRefreshPending = false
                self.refreshLMStudioPluginStatus()
                return
            }
            switch result {
            case .success(let status):
                self.lmStudioPluginStatus = status
                self.preferredServeBinaryURL = URL(fileURLWithPath: status.binaryPath)
            case .failure(is CancellationError): break
            case .failure(let error):
                self.lmStudioPluginMessage = "Status unavailable: \(error.localizedDescription)"
            }
        }
    }

    public func deployToLMStudio() {
        guard !isInstallingPlugin, let forgeApp = app else { return }
        isInstallingPlugin = true
        lmStudioPluginMessage = nil
        deploymentOperation.start {
            let binary = forgeApp.lmStudioDeploy.resolveServeBinary(preferred: Bundle.main.executableURL)
            return try forgeApp.lmStudioDeploy.deploy(preferredBinary: binary)
        } completion: { [weak self] result in
            guard let self else { return }
            self.isInstallingPlugin = false
            switch result {
            case .success(let installed):
                self.lmStudioPluginMessage = installed.message
                self.refresh(force: true)
            case .failure(is CancellationError): self.lmStudioPluginMessage = "Deploy cancelled"
            case .failure(let error): self.lmStudioPluginMessage = "Deploy failed: \(error.localizedDescription)"
            }
            self.refreshLMStudioPluginStatus()
            self.refreshDiagnosticsPreview()
        }
    }

    public func installLMStudioPlugin() { deployToLMStudio() }

    private func startManagerPoll() {
        managerPoll?.cancel()
        managerPoll = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                if let manager = self.manager {
                    self.managerStatus = manager.statusModel()
                } else {
                    self.refreshRemoteManagerStatus()
                }
            }
    }

    private func refreshRemoteManagerStatus() {
        guard let client = remoteManager, !managerPollInFlight else { return }
        managerPollInFlight = true
        Task { [weak self] in
            do {
                let status = try await client.status()
                guard let self else { return }
                self.managerStatus = status
                self.managerPollInFlight = false
                if self.remoteManagerLastError != nil {
                    self.managerMessage = "Manager connection restored"
                    self.app?.diagnostics.info("gui_manager_connection_restored", [
                        "port": "\(status.dashboardPort)",
                    ], category: .manager)
                }
                self.remoteManagerLastError = nil
            } catch {
                guard let self else { return }
                self.managerPollInFlight = false
                let detail = error.localizedDescription
                if self.remoteManagerLastError != detail {
                    self.managerMessage = "Manager connection unavailable: \(detail)"
                    self.app?.diagnostics.warn("gui_manager_connection_unavailable", [
                        "error": detail,
                    ], category: .manager)
                }
                self.remoteManagerLastError = detail
            }
        }
    }

    public func refresh(force: Bool) {
        telemetryBinding.autoRefresh = autoRefresh
        telemetryBinding.refresh(force: force)
        syncFromTelemetryBinding()
    }

    // MARK: - Diagnostics

    public func refreshDiagnosticsPreview() {
        diagnosticPreview = app?.diagnostics.recent(limit: 200) ?? []
        runtimeDiagnosticSnapshot = app?.runtimeDiagnosticSnapshot()
    }

    public func exportDiagnostics() {
        guard !isExportingDiagnostics else { return }
        guard app != nil else {
            lastExportMessage = "App not bootstrapped"
            return
        }
        isExportingDiagnostics = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for Forge Conductor diagnostics (.json + .md)"
        panel.directoryURL = app?.paths.exportsDir
        guard panel.runModal() == .OK, let directory = panel.url else {
            isExportingDiagnostics = false
            lastExportMessage = "Export cancelled"
            return
        }
        beginDiagnosticsExport(to: directory, reveal: false)
    }

    public func exportDiagnosticsToDefaultFolder() {
        guard !isExportingDiagnostics, let directory = app?.paths.exportsDir else { return }
        isExportingDiagnostics = true
        beginDiagnosticsExport(to: directory, reveal: true)
    }

    private func beginDiagnosticsExport(to directory: URL, reveal: Bool) {
        guard let diagnostics = app?.diagnostics else {
            isExportingDiagnostics = false
            return
        }
        lastExportMessage = "Exporting diagnostics…"
        diagnosticsExportOperation.start {
            try diagnostics.export(to: directory, basename: nil)
        } completion: { [weak self] result in
            guard let self else { return }
            self.isExportingDiagnostics = false
            switch result {
            case .success(let exported):
                self.lastExportMessage =
                    "Exported \(exported.recordCount) records →\n\(exported.jsonURL.path)\n\(exported.markdownURL.path)"
                if reveal {
                    NSWorkspace.shared.activateFileViewerSelecting([exported.jsonURL, exported.markdownURL])
                }
                self.refreshDiagnosticsPreview()
            case .failure(is CancellationError): self.lastExportMessage = "Export cancelled"
            case .failure(let error):
                self.lastExportMessage = "Export failed: \(error.localizedDescription)"
                diagnostics.error("diagnostics_export_failed", ["error": error.localizedDescription], category: .diagnostics)
            }
        }
    }

    // MARK: - Accessors

    public var sysStrip: SysStripModel {
        if let s = system { return SysStripModel(from: s) }
        return SysStripModel(from: emptySystem())
    }

    public var perCPU: [Double] { system?.cpu.perCPU ?? [] }
    public var diskVolumes: [DiskVolume] { system?.disk ?? [] }
    public var diskIO: DiskIOMetrics {
        system?.diskIO
            ?? DiskIOMetrics(readMBs: 0, writeMBs: 0, totalMBs: 0, readIOPS: 0, writeIOPS: 0, totalIOPS: 0)
    }
    public var hotProcesses: [ProcessMetrics] { system?.processes ?? [] }
    public var historyCPU: [Float] { history.map { Float($0.cpu) } }
    public var historyRAM: [Float] { history.map { Float($0.ram) } }
    public var historyGPU: [Float?] {
        history.map { point in point.gpu.map(Float.init) }
    }
    public var cpuPercent: Double { system?.cpu.percent ?? 0 }
    public var ramPercent: Double { system?.ram.percent ?? 0 }
    public var gpuPercent: Double? { system?.gpu.first?.utilGPU }
    public var hostName: String { system?.host ?? "host" }

    public var mcpServerCards: [MCPServerCard] { forge?.mcpServers ?? [] }
    public var toolCards: [ToolCard] { forge?.mcpTools ?? [] }
    public var agentCards: [AgentCard] { forge?.agents ?? [] }
    public var toolPacks: [ToolPackSummary] { forge?.mcpPacks ?? [] }
    public var liveFeedEvents: [LiveFeedEvent] { forge?.liveFeed ?? [] }
    public var orchestration: OrchestrationStatus? { forge?.orchestration }

    public var serviceActive: Bool { managerStatus?.serviceActive ?? false }
    public var serviceState: String { managerStatus?.state.rawValue ?? "unknown" }
    public var managerRuntimeVersion: String { managerStatus?.version ?? "unavailable" }

    /// Manager bundles may append a build qualifier (for example, "-swift").
    /// Treat that as the same release while still exposing the exact runtime string.
    public var managerVersionIsCurrent: Bool? {
        guard let managerVersion = managerStatus?.version, !managerVersion.isEmpty else {
            return nil
        }
        return managerVersion == version || managerVersion.hasPrefix("\(version)-")
    }

    public var managerVersionNotice: String? {
        guard managerVersionIsCurrent == false else { return nil }
        return "The running manager is \(managerRuntimeVersion), while this app is \(version). Reinstall the login manager from this build before relying on runtime parity."
    }

    public var telemetryModeLabel: String {
        let target = app?.telemetry.realtimeEngine.targetSampleHz ?? RealtimeMetricsEngine.defaultTargetHz
        let meas = measuredTelemetryHz
        if meas > 0.5 {
            return String(format: "Real-time native · %.0f Hz target · %.1f Hz measured", target, meas)
        }
        return String(format: "Real-time native · %.0f Hz continuous", target)
    }

    // MARK: - Manager

    public func managerStart() {
        if let client = remoteManager {
            managerMessage = "Starting service…"
            Task { [weak self] in
                do {
                    let status = try await client.startService()
                    guard let self else { return }
                    self.managerStatus = status
                    self.managerMessage = "Service started"
                    self.app?.diagnostics.info("manager_start", ["via": "loopback"], category: .manager)
                    self.refresh(force: true)
                } catch {
                    self?.recordRemoteManagerFailure(action: "Start", error: error)
                }
            }
            return
        }
        guard let manager else {
            managerMessage = "Manager is unavailable"
            return
        }
        do {
            managerStatus = try manager.startService()
            managerMessage = "Service started"
            app?.diagnostics.info("manager_start", [:], category: .manager)
            refresh(force: true)
        } catch {
            managerMessage = "Start failed: \(error)"
            app?.diagnostics.error("manager_start_failed", ["error": "\(error)"], category: .manager)
        }
    }

    public func managerStop() {
        if let client = remoteManager {
            managerMessage = "Stopping service…"
            Task { [weak self] in
                do {
                    let status = try await client.stopService()
                    guard let self else { return }
                    self.managerStatus = status
                    self.managerMessage = "Service stopped (control plane stays available)"
                    self.app?.diagnostics.info("manager_stop", ["via": "loopback"], category: .manager)
                    self.refresh(force: true)
                } catch {
                    self?.recordRemoteManagerFailure(action: "Stop", error: error)
                }
            }
            return
        }
        guard let manager else {
            managerMessage = "Manager is unavailable"
            return
        }
        do {
            managerStatus = try manager.stopService()
            managerMessage = "Service stopped (control plane stays available)"
            app?.diagnostics.info("manager_stop", [:], category: .manager)
            refresh(force: true)
        } catch {
            managerMessage = "Stop failed: \(error)"
        }
    }

    public func managerRestart() {
        if let client = remoteManager {
            managerMessage = "Restarting service…"
            Task { [weak self] in
                do {
                    let status = try await client.restartService()
                    guard let self else { return }
                    self.managerStatus = status
                    self.managerMessage = "Service restarted"
                    self.app?.diagnostics.info("manager_restart", ["via": "loopback"], category: .manager)
                    self.refresh(force: true)
                } catch {
                    self?.recordRemoteManagerFailure(action: "Restart", error: error)
                }
            }
            return
        }
        guard let manager else {
            managerMessage = "Manager is unavailable"
            return
        }
        do {
            managerStatus = try manager.restartService()
            managerMessage = "Service restarted"
            app?.diagnostics.info("manager_restart", [:], category: .manager)
            refresh(force: true)
        } catch {
            managerMessage = "Restart failed: \(error)"
        }
    }

    private var settingsDraft: ManagerSettingsPatch {
        ManagerSettingsPatch(
            dashboardHost: setHost, dashboardPort: setPort, dashboardRefreshSec: setRefresh,
            autoRestart: setAutoRestart, watchdogIntervalSec: setWatchdog,
            sessionIdleTTLSec: setIdleTTL, shellEnabled: setShellEnabled,
            shellTimeoutSec: setShellTimeout, allowedRoots: setAllowedRoots
        )
    }

    public func loadSettingsFromConfig() {
        guard let app, !settingsOperation.isRunning else { return }
        let client = remoteManager
        let manager = self.manager
        let draft = settingsDraft
        isUpdatingSettings = true
        settingsOperation.start {
            if let client { return try await client.settings() }
            if let manager { return manager.settingsModel() }
            return AppBootstrapOperation.settingsSnapshot(app)
        } completion: { [weak self] result in
            guard let self else { return }
            self.isUpdatingSettings = false
            switch result {
            case .success(let settings):
                // A delayed read cannot overwrite edits made while it was running.
                guard self.settingsDraft == draft else { return }
                self.apply(settings: settings)
            case .failure(is CancellationError): break
            case .failure(let error): self.recordRemoteManagerFailure(action: "Load settings", error: error)
            }
        }
    }

    public func saveSettings() {
        guard hasLoadedInitialSettings else {
            managerMessage = "Settings are unavailable until startup completes."
            return
        }
        guard !settingsOperation.isRunning else {
            managerMessage = "A settings operation is in progress. Retry after it completes."
            return
        }
        guard let appPaths = app?.paths else {
            managerMessage = "Manager credentials are unavailable"
            return
        }
        let client = remoteManager
        let manager = self.manager
        guard client != nil || manager != nil else {
            managerMessage = "Manager is unavailable"
            return
        }
        let patch = settingsDraft
        isUpdatingSettings = true
        managerMessage = "Saving settings…"
        settingsOperation.start {
            if let client {
                let settings = try await client.updateSettings(patch, apply: true)
                return (settings, Optional<ManagerStatus>.none)
            }
            guard let manager else { throw CancellationError() }
            let settings = try manager.updateSettings(patch, apply: true)
            return (settings, Optional(manager.statusModel()))
        } completion: { [weak self] result in
            guard let self else { return }
            self.isUpdatingSettings = false
            switch result {
            case .success(let (settings, status)):
                let draftUnchanged = self.settingsDraft == patch
                if draftUnchanged { self.apply(settings: settings) }
                if client != nil {
                    self.remoteManager = ManagerDashboardClient(
                        host: settings.dashboardHost, port: settings.dashboardPort,
                        credentials: ManagerControlCredentialStore(paths: appPaths)
                    )
                }
                self.operatorManagerClient.replace(
                    with: OperatorManagerHTTPClient(
                        host: settings.dashboardHost, port: settings.dashboardPort,
                        credentials: ManagerControlCredentialStore(paths: appPaths)
                    )
                )
                if let status { self.managerStatus = status }
                self.managerMessage = draftUnchanged ? "Settings saved" : "Settings saved. New edits have not been saved."
                if client != nil { self.refreshRemoteManagerStatus() }
            case .failure(is CancellationError): self.managerMessage = "Settings cancelled"
            case .failure(let error): self.recordRemoteManagerFailure(action: "Settings", error: error)
            }
        }
    }

    public var secureFilesystemServiceStatusLabel: String {
        switch secureFilesystemServiceStatus {
        case .enabled: "Enabled"
        case .requiresApproval: "Approval required"
        case .notRegistered: "Not enabled"
        case .notFound: "Not packaged or invalid"
        }
    }

    public var secureFilesystemOperationalStatusLabel: String {
        switch secureFilesystemOperationalHealth.operationalState {
        case .operational: "Operational"
        case .registeredUnavailable: "Registered, not responding"
        case .requiresApproval: "Waiting for approval"
        case .notRegistered: "Not registered"
        case .notPackaged: "Not packaged or invalid"
        }
    }

    public var secureFilesystemRecoveryDebtLabel: String {
        let health = secureFilesystemOperationalHealth
        guard health.debtStatusAvailable else { return "Unavailable" }
        return "Local \(health.localQuarantineOccupied)/\(health.localQuarantineCapacity) · Protected \(health.privilegedRecoveryRetained)/\(health.privilegedRecoveryCapacity)"
    }

    public var secureFilesystemServiceLifecycleStatusLabel: String {
        secureFilesystemServiceLifecycleState.operatorStatusLabel
    }

    public var secureFilesystemServiceLifecycleRecoveryActionLabel: String {
        secureFilesystemServiceLifecycleState.recoveryActionLabel
    }

    public var secureFilesystemSettingsControlAvailability:
        SecureFilesystemSettingsControlAvailability
    {
        SecureFilesystemSettingsControlAvailability(
            registrationStatus: secureFilesystemServiceStatus,
            operationState: secureFilesystemSettingsOperationState,
            lifecycleState: secureFilesystemServiceLifecycleState
        )
    }

    public var secureFilesystemServiceOperationStatusLabel: String {
        if let operation = secureFilesystemSettingsOperationState.activeOperation {
            return operation.accessibilityLabel
        }
        return secureFilesystemServiceLifecycleState.phase == .settled
            ? "Idle"
            : secureFilesystemServiceLifecycleStatusLabel
    }

    public var isSecureFilesystemServiceOperationActive: Bool {
        secureFilesystemSettingsOperationState.isActive
    }

    public var isUpdatingSecureFilesystemService: Bool {
        secureFilesystemSettingsOperationState.activeOperation == .update
    }

    public var isReconcilingSecureFilesystemRecovery: Bool {
        secureFilesystemSettingsOperationState.activeOperation == .reconcile
    }

    private func bootstrapSecureFilesystemService(paths: AppPaths) {
        guard let generation = beginSecureFilesystemServiceOperation(.bootstrap) else { return }
        guard let observationContext = beginSecureFilesystemLifecycleObservation() else {
            finishSecureFilesystemServiceOperation(.bootstrap, generation: generation)
            return
        }
        let service = secureFilesystemService
        secureFilesystemOperationTask = Task { @MainActor [weak self] in
            let observedState = await service.configureLifecycleFence(paths: paths)
            guard !Task.isCancelled else { return }
            var lifecycleFailure: String?
            if observedState.canRetryResolution {
                do {
                    _ = try await service.recoverInterruptedLifecycle(
                        lifecycleObservationContext: observationContext
                    )
                } catch {
                    lifecycleFailure = error.localizedDescription
                }
            }
            guard !Task.isCancelled else { return }
            let health = await service.operationalHealth(paths: paths, reconcile: false)
            let lifecycleState = await service.lifecycleState()
            guard !Task.isCancelled,
                  let self,
                  ownsSecureFilesystemServiceOperation(.bootstrap, generation: generation)
            else { return }
            applySecureFilesystemOperationalHealth(health)
            applySecureFilesystemLifecycleState(
                lifecycleState,
                context: observationContext
            )
            if let lifecycleFailure,
               lifecycleState.blocksLifecycleMutation {
                secureFilesystemServiceMessage =
                    "Interrupted service lifecycle change remains unresolved: \(lifecycleFailure)"
            } else if let lifecycleFailure {
                secureFilesystemServiceMessage =
                    "Interrupted lifecycle request completed with an error; lifecycle fence cleared: \(lifecycleFailure)"
            } else if observedState.canRetryResolution {
                secureFilesystemServiceMessage =
                    "Interrupted service lifecycle change resolved"
            } else if observedState.phase == .stateInvalid {
                secureFilesystemServiceMessage =
                    "Protected filesystem lifecycle fence is invalid; lifecycle changes remain blocked"
            }
            finishSecureFilesystemServiceOperation(.bootstrap, generation: generation)
        }
    }

    public func refreshSecureFilesystemServiceStatus(reconcile: Bool = false) {
        guard let paths = app?.paths else { return }
        let operation: SecureFilesystemSettingsOperation = reconcile ? .reconcile : .refresh
        guard let generation = beginSecureFilesystemServiceOperation(operation) else { return }
        let service = secureFilesystemService
        secureFilesystemOperationTask = Task { @MainActor [weak self] in
            await Self.waitForSecureFilesystemUITestObservationWindow()
            guard !Task.isCancelled else { return }
            let health = await service.operationalHealth(
                paths: paths,
                reconcile: reconcile
            )
            let lifecycleState = await service.lifecycleState()
            guard !Task.isCancelled,
                  let self,
                  ownsSecureFilesystemServiceOperation(operation, generation: generation)
            else { return }
            applySecureFilesystemOperationalHealth(health)
            secureFilesystemServiceLifecycleState = lifecycleState
            finishSecureFilesystemServiceOperation(operation, generation: generation)
        }
    }

    public func reconcileSecureFilesystemRecovery() {
        refreshSecureFilesystemServiceStatus(reconcile: true)
    }

    public func recoverSecureFilesystemServiceLifecycle() {
        guard let paths = app?.paths,
              secureFilesystemServiceLifecycleState.canRetryResolution,
              let generation = beginSecureFilesystemServiceOperation(.lifecycleRecovery)
        else { return }
        guard let observationContext = beginSecureFilesystemLifecycleObservation() else {
            finishSecureFilesystemServiceOperation(
                .lifecycleRecovery,
                generation: generation
            )
            return
        }
        secureFilesystemServiceMessage =
            "Resuming the interrupted protected filesystem service lifecycle…"
        let service = secureFilesystemService
        secureFilesystemOperationTask = Task { @MainActor [weak self] in
            await Self.waitForSecureFilesystemUITestObservationWindow()
            guard !Task.isCancelled else { return }
            let failure: String?
            do {
                _ = try await service.recoverInterruptedLifecycle(
                    lifecycleObservationContext: observationContext
                )
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            let health = await service.operationalHealth(paths: paths, reconcile: false)
            let lifecycleState = await service.lifecycleState()
            guard !Task.isCancelled,
                  let self,
                  ownsSecureFilesystemServiceOperation(
                      .lifecycleRecovery,
                      generation: generation
                  )
            else { return }
            applySecureFilesystemOperationalHealth(health)
            applySecureFilesystemLifecycleState(
                lifecycleState,
                context: observationContext
            )
            if let failure, lifecycleState.blocksLifecycleMutation {
                secureFilesystemServiceMessage =
                    "Interrupted service lifecycle change remains unresolved: \(failure)"
            } else if let failure {
                secureFilesystemServiceMessage =
                    "Interrupted lifecycle request completed with an error; lifecycle fence cleared: \(failure)"
            } else {
                secureFilesystemServiceMessage = "Interrupted service lifecycle change resolved"
            }
            finishSecureFilesystemServiceOperation(
                .lifecycleRecovery,
                generation: generation
            )
        }
    }

    public func enableSecureFilesystemService() {
        guard let paths = app?.paths,
              let generation = beginSecureFilesystemServiceOperation(.enable)
        else { return }
        guard let observationContext = beginSecureFilesystemLifecycleObservation() else {
            finishSecureFilesystemServiceOperation(.enable, generation: generation)
            return
        }
        secureFilesystemServiceMessage = "Enabling the protected filesystem service…"
        let service = secureFilesystemService
        secureFilesystemOperationTask = Task { @MainActor [weak self] in
            await Self.waitForSecureFilesystemUITestObservationWindow()
            guard !Task.isCancelled else { return }
            let registrationStatus: SecureFilesystemServiceStatus?
            let failure: String?
            do {
                registrationStatus = try await service.register(
                    lifecycleObservationContext: observationContext
                )
                failure = nil
            } catch {
                registrationStatus = nil
                failure = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            let health = await service.operationalHealth(paths: paths, reconcile: false)
            let lifecycleState = await service.lifecycleState()
            guard !Task.isCancelled,
                  let self,
                  ownsSecureFilesystemServiceOperation(.enable, generation: generation)
            else { return }
            applySecureFilesystemOperationalHealth(health)
            applySecureFilesystemLifecycleState(
                lifecycleState,
                context: observationContext
            )
            if let failure {
                secureFilesystemServiceMessage = "Enable failed: \(failure)"
            } else if let registrationStatus {
                switch registrationStatus {
                case .enabled:
                    secureFilesystemServiceMessage = "Protected filesystem service registered; checking runtime health"
                case .requiresApproval:
                    secureFilesystemServiceMessage = "Approve Forge Conductor in System Settings to enable protected filesystem mutations"
                case .notRegistered:
                    secureFilesystemServiceMessage = "Protected filesystem service was not enabled"
                case .notFound:
                    secureFilesystemServiceMessage = "Protected filesystem service registration status is unavailable"
                }
            } else {
                secureFilesystemServiceMessage = "Protected filesystem service registration status is unavailable"
            }
            finishSecureFilesystemServiceOperation(.enable, generation: generation)
        }
    }

    public func disableSecureFilesystemService() {
        guard let paths = app?.paths,
              let generation = beginSecureFilesystemServiceOperation(.disable)
        else { return }
        guard let observationContext = beginSecureFilesystemLifecycleObservation() else {
            finishSecureFilesystemServiceOperation(.disable, generation: generation)
            return
        }
        secureFilesystemServiceMessage = "Disabling the protected filesystem service…"
        let service = secureFilesystemService
        secureFilesystemOperationTask = Task { @MainActor [weak self] in
            await Self.waitForSecureFilesystemUITestObservationWindow()
            guard !Task.isCancelled else { return }
            let failure: String?
            do {
                _ = try await service.unregister(
                    lifecycleObservationContext: observationContext
                )
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            let health = await service.operationalHealth(paths: paths, reconcile: false)
            let lifecycleState = await service.lifecycleState()
            guard !Task.isCancelled,
                  let self,
                  ownsSecureFilesystemServiceOperation(.disable, generation: generation)
            else { return }
            applySecureFilesystemOperationalHealth(health)
            applySecureFilesystemLifecycleState(
                lifecycleState,
                context: observationContext
            )
            secureFilesystemServiceMessage = failure.map { "Disable failed: \($0)" }
                ?? "Protected filesystem service disabled"
            finishSecureFilesystemServiceOperation(.disable, generation: generation)
        }
    }

    public func reinstallSecureFilesystemService() {
        guard let paths = app?.paths,
              let generation = beginSecureFilesystemServiceOperation(.update)
        else { return }
        guard let observationContext = beginSecureFilesystemLifecycleObservation() else {
            finishSecureFilesystemServiceOperation(.update, generation: generation)
            return
        }
        secureFilesystemServiceMessage = "Replacing the protected filesystem service…"
        let service = secureFilesystemService
        secureFilesystemOperationTask = Task { @MainActor [weak self] in
            await Self.waitForSecureFilesystemUITestObservationWindow()
            guard !Task.isCancelled else { return }
            let registrationStatus: SecureFilesystemServiceStatus?
            let failure: String?
            do {
                registrationStatus = try await service.reinstall(
                    lifecycleObservationContext: observationContext
                )
                failure = nil
            } catch {
                registrationStatus = nil
                failure = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            let health = await service.operationalHealth(paths: paths, reconcile: false)
            let lifecycleState = await service.lifecycleState()
            guard !Task.isCancelled,
                  let self,
                  ownsSecureFilesystemServiceOperation(.update, generation: generation)
            else { return }
            applySecureFilesystemOperationalHealth(health)
            applySecureFilesystemLifecycleState(
                lifecycleState,
                context: observationContext
            )
            if let failure {
                secureFilesystemServiceMessage = "Update failed: \(failure)"
            } else if let registrationStatus {
                switch registrationStatus {
                case .enabled:
                    secureFilesystemServiceMessage = "Protected filesystem service replacement registered; checking runtime health"
                case .requiresApproval:
                    secureFilesystemServiceMessage = "Replacement registered; approve Forge Conductor in System Settings"
                case .notRegistered:
                    secureFilesystemServiceMessage = "Protected filesystem service replacement was not registered"
                case .notFound:
                    secureFilesystemServiceMessage = "Protected filesystem service registration status is unavailable"
                }
            } else {
                secureFilesystemServiceMessage = "Protected filesystem service registration status is unavailable"
            }
            finishSecureFilesystemServiceOperation(.update, generation: generation)
        }
    }

    public func openSecureFilesystemApprovalSettings() {
        guard let generation = beginSecureFilesystemServiceOperation(.approval) else { return }
        let service = secureFilesystemService
        secureFilesystemOperationTask = Task { @MainActor [weak self] in
            await Self.waitForSecureFilesystemUITestObservationWindow()
            guard !Task.isCancelled else { return }
            service.openApprovalSettings()
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  ownsSecureFilesystemServiceOperation(.approval, generation: generation)
            else { return }
            finishSecureFilesystemServiceOperation(.approval, generation: generation)
        }
    }

    public func cancelSecureFilesystemServiceOperation() {
        let cancelledTask = secureFilesystemOperationTask
        let cancelledOperation = secureFilesystemSettingsOperationState.activeOperation
        let cancelledObservationContext =
            secureFilesystemLifecycleObservationGate.activeContext
        cancelledTask?.cancel()
        secureFilesystemOperationTask = nil
        var nextState = secureFilesystemSettingsOperationState
        nextState.cancel()
        secureFilesystemSettingsOperationState = nextState
        guard cancelledOperation?.mayAwaitServiceUnregister == true else { return }

        let intent: SecureFilesystemServiceLifecycleIntent?
        switch cancelledOperation {
        case .enable:
            intent = .enable
        case .update:
            intent = .update
        case .disable:
            intent = .disable
        case .bootstrap, .lifecycleRecovery:
            intent = secureFilesystemServiceLifecycleState.intent
        case .approval, .refresh, .reconcile, nil:
            intent = nil
        }
        secureFilesystemServiceLifecycleState = .cancelled(intent: intent)
        let service = secureFilesystemService
        Task { @MainActor [weak self] in
            await cancelledTask?.value
            let durableState = await service.lifecycleState()
            guard let self,
                  !secureFilesystemSettingsOperationState.isActive else { return }
            if let cancelledObservationContext {
                applySecureFilesystemLifecycleState(
                    durableState,
                    context: cancelledObservationContext
                )
            } else {
                secureFilesystemServiceLifecycleState = durableState
            }
        }
    }

    private func beginSecureFilesystemServiceOperation(
        _ operation: SecureFilesystemSettingsOperation
    ) -> UInt64? {
        guard secureFilesystemOperationTask == nil else { return nil }
        var nextState = secureFilesystemSettingsOperationState
        guard let generation = nextState.begin(operation) else { return nil }
        secureFilesystemSettingsOperationState = nextState
        return generation
    }

    private func beginSecureFilesystemLifecycleObservation()
        -> SecureFilesystemServiceLifecycleObservationContext?
    {
        var gate = secureFilesystemLifecycleObservationGate
        guard let context = gate.begin() else { return nil }
        secureFilesystemLifecycleObservationGate = gate
        return context
    }

    private func applySecureFilesystemLifecycleState(
        _ state: SecureFilesystemServiceLifecycleState,
        context: SecureFilesystemServiceLifecycleObservationContext
    ) {
        applySecureFilesystemLifecycleObservation(
            SecureFilesystemServiceLifecycleObservation(
                context: context,
                state: state
            )
        )
    }

    private func applySecureFilesystemLifecycleObservation(
        _ observation: SecureFilesystemServiceLifecycleObservation
    ) {
        var gate = secureFilesystemLifecycleObservationGate
        guard let state = gate.accept(observation) else { return }
        secureFilesystemLifecycleObservationGate = gate
        secureFilesystemServiceLifecycleState = state
    }

    private func ownsSecureFilesystemServiceOperation(
        _ operation: SecureFilesystemSettingsOperation,
        generation: UInt64
    ) -> Bool {
        secureFilesystemSettingsOperationState.owns(operation, generation: generation)
    }

    private func finishSecureFilesystemServiceOperation(
        _ operation: SecureFilesystemSettingsOperation,
        generation: UInt64
    ) {
        var nextState = secureFilesystemSettingsOperationState
        guard nextState.finish(operation, generation: generation) else { return }
        secureFilesystemSettingsOperationState = nextState
        secureFilesystemOperationTask = nil
    }

    /// Gives signed XCUI a bounded observation window without replacing the
    /// production operation. The hook is ignored outside an explicit UI-test launch.
    private static func waitForSecureFilesystemUITestObservationWindow() async {
        let environment = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.contains("--uitesting"),
              let rawDelay = environment["FORGE_FILESYSTEM_SETTINGS_UI_TEST_DELAY_MS"],
              let delayMilliseconds = Int(rawDelay),
              (1...2_000).contains(delayMilliseconds)
        else { return }
        try? await Task.sleep(for: .milliseconds(delayMilliseconds))
    }

    private func applySecureFilesystemOperationalHealth(
        _ health: SecureFilesystemOperationalHealth
    ) {
        secureFilesystemOperationalHealth = health
        secureFilesystemServiceStatus = health.registrationStatus
        if health.releasedDuringReconciliation > 0 {
            secureFilesystemServiceMessage =
                "Released \(health.releasedDuringReconciliation) verified terminal recovery slot(s)"
        }
    }

    /// Presents the native directory picker in production. UI tests may provide an
    /// explicit path so the resulting controls can be exercised without automating a
    /// process-owned system panel.
    public func chooseAllowedRoot() {
        guard hasLoadedInitialSettings else {
            allowedRootsMessage = "Project folder changes are unavailable until startup completes."
            return
        }
        let environment = ProcessInfo.processInfo.environment
        if CommandLine.arguments.contains("--uitesting"),
           let path = environment["FORGE_ALLOWED_ROOT_UI_TEST_SELECTION"] {
            _ = addAllowedRoot(URL(fileURLWithPath: path, isDirectory: true))
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Authorize Folder"
        panel.message = "Choose one project folder Forge Conductor may access."
        guard panel.runModal() == .OK, let selected = panel.url else {
            allowedRootsMessage = "No project folder was added"
            return
        }
        _ = addAllowedRoot(selected)
    }

    /// Stages one canonical project root for the next settings save.
    @discardableResult
    public func addAllowedRoot(_ url: URL) -> Bool {
        guard hasLoadedInitialSettings else {
            allowedRootsMessage = "Project folder changes are unavailable until startup completes."
            return false
        }
        guard url.isFileURL,
              let canonical = ManagerSettingsNormalizer.canonicalAllowedRoot(url.path) else {
            allowedRootsMessage = url.standardizedFileURL.path == "/"
                ? "The filesystem root cannot be authorized"
                : "Choose an existing folder"
            return false
        }
        guard !setAllowedRoots.contains(canonical) else {
            allowedRootsMessage = "That project folder is already authorized"
            return true
        }
        setAllowedRoots = ManagerSettingsNormalizer.canonicalAllowedRoots(
            setAllowedRoots + [canonical]
        )
        allowedRootsMessage = "Project folder staged; choose Save settings to apply it"
        return true
    }

    /// Stages removal of one project root for the next settings save.
    public func removeAllowedRoot(_ path: String) {
        guard hasLoadedInitialSettings else {
            allowedRootsMessage = "Project folder changes are unavailable until startup completes."
            return
        }
        let canonical = URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        setAllowedRoots.removeAll { $0 == canonical }
        allowedRootsMessage = "Project folder removal staged; choose Save settings to apply it"
    }

    private func apply(settings: ManagerSettings) {
        setHost = settings.dashboardHost
        setPort = settings.dashboardPort
        setRefresh = settings.dashboardRefreshSec
        setWatchdog = settings.watchdogIntervalSec
        setIdleTTL = settings.sessionIdleTTLSec
        setShellEnabled = settings.shellEnabled
        setShellTimeout = settings.shellTimeoutSec
        setAutoRestart = settings.autoRestart
        shellPolicyOrigin = settings.shellPolicyOrigin
        shellMigrationState = settings.shellMigrationState
        shellMigrationReceiptValid = settings.shellMigrationReceiptValid
        shellRuntimeCapabilities = settings.shellRuntimeCapabilities
        // The manager (or startup worker) already validated and canonicalized these roots.
        setAllowedRoots = settings.allowedRoots
    }

    private func recordRemoteManagerFailure(action: String, error: Error) {
        let detail = error.localizedDescription
        managerMessage = "\(action) failed: \(detail)"
        app?.diagnostics.error("gui_manager_action_failed", [
            "action": action,
            "error": detail,
        ], category: .manager)
    }

    public func toggleNavigation() {
        isNavigationVisible.toggle()
    }

    public func selectTab(_ tab: AppTab) {
        guard selectedTab != tab else { return }
        selectedTab = tab
        app?.diagnostics.info("ui_navigation_selected", [
            "tab": tab.accessibilityID,
        ], category: .ui)
    }

    public func runDoctor() -> DoctorReport? { try? app?.doctorModel() }
    public func runDoctorDictionary() -> [String: Any]? { try? app?.doctor() }

    public func prunePresence() {
        _ = try? app?.store.presencePrune(maxAgeSec: 60)
        app?.diagnostics.info("presence_pruned", [:], category: .mcp)
        refresh(force: true)
    }

    public func pruneSessions() {
        try? app?.sessions.pruneStale()
        app?.diagnostics.info("sessions_pruned", [:], category: .agent)
        refresh(force: true)
    }

    private func emptySystem() -> SystemMetrics {
        SystemMetrics(
            ts: 0, host: "—", platform: "darwin", arch: "—",
            cpu: CPUMetrics(
                percent: 0, perCPU: [], countLogical: 0, countPhysical: 0,
                freqMHz: nil, freqPerCoreMHz: nil, loadAvg: (0, 0, 0),
                brand: "—", user: 0, system: 0, idle: 100
            ),
            ram: RAMMetrics(
                totalGB: 0, usedGB: 0, availableGB: 0, percent: 0,
                pressurePercent: 0, activeGB: 0, wiredGB: 0, compressedGB: 0
            ),
            disk: [],
            diskIO: DiskIOMetrics(readMBs: 0, writeMBs: 0, totalMBs: 0, readIOPS: 0, writeIOPS: 0, totalIOPS: 0),
            gpu: [],
            processes: [],
            power: .unknown
        )
    }
}

// ForgeApp.swift
// What: Serves as the Core composition root and owner of long-lived services.
// How: Bootstrap constructs paths, storage, configuration, telemetry, catalogs,
// tool packs, authorization, and routing with explicit dependency injection.
// Why: Central composition makes modules replaceable without service-locator globals.

import Foundation

/// Composition root for the Forge-Conductor application.
/// All layers hang off this object; suitable for CLI, MCP stdio, and future Xcode shell.
public final class ForgeApp: @unchecked Sendable {
    public static let version = "0.9.0"
    public static let productName = "Forge-Conductor"

    public let paths: AppPaths
    public let config: ConfigStore
    public let store: SQLiteStore
    public let audit: AuditService
    public let diagnostics: DiagnosticLog
    public let runtimeDiagnostics: RuntimeDiagnostics
    public let catalog: AgentCatalog
    public let sessions: AgentSessionService
    public let continuity: ContextContinuityService
    public let continuityAutomation: ContinuityAutomation
    public let projectMemory: ProjectMemoryService
    public let projectContexts: ProjectContextService
    public let continuityControl: ContinuityControlService
    public let runtimeJobs: RuntimeJobSubsystem
    public let clock: any Clock
    public let lmStudioDeploy: LMStudioDeployService

    /// Self-referential adapters are lazy, non-optional services. Bootstrap
    /// initializes both before publishing the composition root to callers.
    public private(set) lazy var tools: ToolRouter = {
        let authorization = ToolAuthorizationService(
            paths: paths,
            config: config,
            workspace: continuityAutomation
        )
        return ToolRouter(app: self, authorization: authorization)
    }()
    public private(set) lazy var telemetry = TelemetryService(
        paths: paths,
        store: store,
        catalog: catalog,
        toolNames: { [weak self] in self?.tools.toolNames ?? [] },
        runtimeDiagnostics: runtimeDiagnostics
    )

    private init(
        paths: AppPaths,
        config: ConfigStore,
        store: SQLiteStore,
        audit: AuditService,
        diagnostics: DiagnosticLog,
        runtimeDiagnostics: RuntimeDiagnostics,
        catalog: AgentCatalog,
        sessions: AgentSessionService,
        continuity: ContextContinuityService,
        continuityAutomation: ContinuityAutomation,
        projectMemory: ProjectMemoryService,
        projectContexts: ProjectContextService,
        continuityControl: ContinuityControlService,
        runtimeJobs: RuntimeJobSubsystem,
        clock: any Clock,
        lmStudioDeploy: LMStudioDeployService
    ) {
        self.paths = paths
        self.config = config
        self.store = store
        self.audit = audit
        self.diagnostics = diagnostics
        self.runtimeDiagnostics = runtimeDiagnostics
        self.catalog = catalog
        self.sessions = sessions
        self.continuity = continuity
        self.continuityAutomation = continuityAutomation
        self.projectMemory = projectMemory
        self.projectContexts = projectContexts
        self.continuityControl = continuityControl
        self.runtimeJobs = runtimeJobs
        self.clock = clock
        self.lmStudioDeploy = lmStudioDeploy
    }

    /// Bootstrap durable layout, SQLite, and services under the given home (or default).
    public static func bootstrap(home: URL? = nil, clock: any Clock = SystemClock()) throws -> ForgeApp {
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let config = ConfigStore(paths: paths)
        let store = try SQLiteStore(path: paths.storeSQLite, clock: clock)
        let audit = AuditService(store: store, paths: paths)
        // LM Studio primary/fallback pass FORGE_MCP_ROLE; prefer env over config.json.
        let envRole = ProcessInfo.processInfo.environment["FORGE_MCP_ROLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mcpRole = (envRole?.isEmpty == false)
            ? envRole!
            : config.string("mcp", "role", default: "primary")
        let diagnostics = DiagnosticLog(
            paths: paths,
            role: mcpRole
        )
        let shellMigration = config.shellMigrationStatus
        if shellMigration.diagnosticPending {
            diagnostics.info(
                "shell_policy_migration_completed",
                [
                    "migration_id": shellMigration.migrationID ?? "unknown",
                    "source_schema_version": "\(shellMigration.sourceSchemaVersion)",
                    "target_schema_version": "\(shellMigration.targetSchemaVersion)",
                    "receipt_valid": shellMigration.receiptValid ? "true" : "false",
                ],
                category: .bootstrap
            )
            do {
                try config.markShellMigrationDiagnosticEmitted()
            } catch {
                diagnostics.warn(
                    "shell_policy_migration_diagnostic_receipt_update_failed",
                    ["reason": error.localizedDescription],
                    category: .bootstrap
                )
            }
        }
        let runtimeDiagnostics = RuntimeDiagnostics.shared
        let catalog = AgentCatalog(paths: paths)
        let idleTTL = TimeInterval(config.int("sessions", "idle_ttl_sec", default: 14_400))
        let sessions = AgentSessionService(
            store: store,
            catalog: catalog,
            audit: audit,
            diagnostics: diagnostics,
            clock: clock,
            idleTTL: idleTTL
        )
        let continuity = ContextContinuityService(
            paths: paths,
            store: store,
            sessions: sessions,
            diagnostics: diagnostics,
            clock: clock
        )
        let continuityAutomation = ContinuityAutomation(
            store: store,
            sessions: sessions,
            continuity: continuity,
            diagnostics: diagnostics,
            clock: clock
        )
        let projectMemory = ProjectMemoryService(paths: paths, clock: clock)
        let projectContexts = try ProjectContextService(
            databaseURL: paths.controlPlaneSQLite,
            clock: clock
        )
        let continuityControl = ContinuityControlService(
            memory: projectMemory,
            controlPlane: projectContexts.repository
        )
        let runtimeJobs = try RuntimeJobSubsystem(
            controlPlaneRepository: projectContexts.repository,
            databaseURL: paths.controlPlaneSQLite,
            artifactRoot: paths.runtimeArtifactsDir
        )

        let deploy = LMStudioDeployService(paths: paths, diagnostics: diagnostics, store: store)
        let app = ForgeApp(
            paths: paths,
            config: config,
            store: store,
            audit: audit,
            diagnostics: diagnostics,
            runtimeDiagnostics: runtimeDiagnostics,
            catalog: catalog,
            sessions: sessions,
            continuity: continuity,
            continuityAutomation: continuityAutomation,
            projectMemory: projectMemory,
            projectContexts: projectContexts,
            continuityControl: continuityControl,
            runtimeJobs: runtimeJobs,
            clock: clock,
            lmStudioDeploy: deploy
        )
        // Resolve lazy services on the bootstrap thread. No caller can observe
        // a partially wired application graph.
        let toolCount = app.tools.toolNames.count
        _ = app.telemetry
        // Continuous native metrics — skip in ephemeral test homes.
        let isTemp = paths.home.path.contains("/T/") || paths.home.path.contains("forge-test")
            || paths.home.path.contains("forge-native") || paths.home.path.contains("forge-doc")
            || paths.home.path.contains("forge-contract") || paths.home.path.contains("forge-dash")
        if !isTemp {
            app.telemetry.startBackgroundRefresh(intervalSec: 0.5)
        }

        diagnostics.info("app_bootstrap", [
            "version": version,
            "home": paths.home.path,
            "agents": "\(catalog.all().count)",
            "telemetry": "continuous-native",
            "sample_hz_target": "\(Int(RealtimeMetricsEngine.defaultTargetHz))",
            "tools": "\(toolCount)",
        ], category: .bootstrap)
        return app
    }

    /// Close durable resources (SQLite) only after every owned runtime process is reaped.
    @discardableResult
    public func shutdown() -> RuntimeJobShutdownReport {
        telemetry.stopBackgroundRefresh()
        let runtimeStopped = DispatchSemaphore(value: 0)
        let reportBox = RuntimeShutdownReportBox()
        Task.detached { [runtimeJobs] in
            reportBox.store(await runtimeJobs.shutdown())
            runtimeStopped.signal()
        }
        guard runtimeStopped.wait(timeout: .now() + 35) == .success,
              let report = reportBox.load(),
              report.completed else {
            return reportBox.load() ?? RuntimeJobShutdownReport(
                completed: false,
                unresolvedJobIDs: [],
                persistencePendingJobIDs: []
            )
        }
        projectMemory.closeAll()
        projectContexts.close()
        guard audit.shutdownAttempts(timeout: 2) else {
            return RuntimeJobShutdownReport(
                completed: false,
                unresolvedJobIDs: report.unresolvedJobIDs,
                persistencePendingJobIDs: report.persistencePendingJobIDs
            )
        }
        store.close()
        guard diagnostics.shutdown(timeout: 2) else {
            return RuntimeJobShutdownReport(
                completed: false,
                unresolvedJobIDs: report.unresolvedJobIDs,
                persistencePendingJobIDs: report.persistencePendingJobIDs
            )
        }
        return report
    }

    public func runtimeDiagnosticSnapshot() -> RuntimeDiagnosticSnapshot {
        runtimeDiagnostics.snapshot()
    }

    public func statusSnapshotModel() throws -> AppStatusSnapshot {
        let open = try store.sessionList().filter(\.status.isOpen)
        let presence = try store.presenceRecords()
        let auditRows = try audit.recent(limit: 20)
        let cfg = config.model
        return AppStatusSnapshot(
            ok: true,
            version: Self.version,
            product: Self.productName,
            runtime: "swift",
            home: paths.home.path,
            store: paths.storeSQLite.path,
            agents: catalog.all().map(\.id),
            agentCount: catalog.all().count,
            openSessions: open.map(AgentSessionSummary.init(from:)),
            openSessionCount: open.count,
            presence: presence,
            presenceCount: presence.count,
            recentAudit: auditRows.map(AuditEventSummary.init(from:)),
            tools: tools.toolNames,
            telemetry: telemetry.health(),
            shellPolicy: config.shellPolicyStatus,
            dashboardHost: cfg.dashboard.host,
            dashboardPort: cfg.dashboard.port,
            pid: ProcessInfo.processInfo.processIdentifier
        )
    }

    /// HTTP / CLI edge.
    public func statusSnapshot() throws -> [String: Any] {
        var snapshot = try statusSnapshotModel().asDictionary()
        snapshot["runtime_diagnostics"] = runtimeDiagnosticSnapshot().asDictionary()
        return snapshot
    }

    public func doctorModel() throws -> DoctorReport {
        var checks: [DoctorCheck] = []
        var ok = true

        func check(_ name: String, _ pass: Bool, _ detail: String, hard: Bool = true) {
            if hard && !pass { ok = false }
            checks.append(DoctorCheck(name: name, ok: pass, detail: detail, hard: hard))
        }

        check("home_layout", FileManager.default.fileExists(atPath: paths.home.path), paths.home.path)
        check("sqlite_store", FileManager.default.fileExists(atPath: paths.storeSQLite.path), paths.storeSQLite.path)
        do {
            let health = try projectContexts.health()
            check(
                "project_control_plane",
                health.integrityResult == "ok" && health.schemaVersion == ProjectControlPlaneRepository.schemaVersion,
                "schema=\(health.schemaVersion) journal=\(health.journalMode) integrity=\(health.integrityResult)"
            )
        } catch {
            check("project_control_plane", false, error.localizedDescription)
        }
        check("agent_catalog", catalog.all().count >= 5, "\(catalog.all().count) agents loaded")
        do {
            _ = try store.sessionList()
            check("sqlite_query", true, "session list ok")
        } catch {
            check("sqlite_query", false, "\(error)")
        }
        check("git_available", ProcessRunner.which("git") != nil, ProcessRunner.which("git") ?? "missing")

        let shell = config.shellPolicyStatus
        check(
            "shell_policy_schema_v2",
            config.model.configSchemaVersion == AppConfig.currentSchemaVersion
                && shell.policyVersion == AppConfig.currentSchemaVersion,
            "config=\(config.model.configSchemaVersion) policy=\(shell.policyVersion) origin=\(shell.policyOrigin)"
        )
        check(
            "shell_policy_consistent",
            shell.enabled != shell.userDisabled,
            "enabled=\(shell.enabled) user_disabled=\(shell.userDisabled)"
        )
        let migrationValid = shell.migration.state != "failed"
            && (!shell.migration.state.hasPrefix("migrated") || shell.migration.receiptValid)
        check("shell_policy_migration", migrationValid, shell.migration.detail)
        check("shell_runtime_zsh", shell.runtimes.zsh != nil, shell.runtimes.zsh ?? "missing")
        check("shell_runtime_bash", shell.runtimes.bash != nil, shell.runtimes.bash ?? "missing")
        check("shell_runtime_python", shell.runtimes.python != nil, shell.runtimes.python ?? "optional runtime missing", hard: false)
        check("shell_runtime_powershell", shell.runtimes.powershell != nil, shell.runtimes.powershell ?? "optional runtime missing", hard: false)

        let tel = telemetry.health()
        check("telemetry_native", tel.ok, "swift SystemCollector+ForgeCollector")
        check(
            "telemetry_runtime",
            tel.runtime == "swift-native" || tel.runtime == "swift-native-realtime",
            tel.runtime
        )

        var snapshotOK = false
        var snapDetail = "failed"
        do {
            let snap = try telemetry.snapshot(force: true)
            let missing = TelemetryContract.validate(snapshot: snap)
            snapshotOK = missing.isEmpty
            snapDetail = missing.isEmpty ? "native contract ok" : "missing: \(missing.joined(separator: ", "))"
        } catch {
            snapDetail = "\(error)"
        }
        check("telemetry_snapshot", snapshotOK, snapDetail)

        let installer = ManagerInstaller(app: self)
        let binPath = installer.installedBinaryURL.path
        let binInstalled = FileManager.default.isExecutableFile(atPath: binPath)
        check("swift_binary_install", binInstalled, binPath, hard: false)

        let binDir = installer.installedBinaryURL.deletingLastPathComponent()
        let leftovers = LMStudioEnvironment.legacyLaunchersPresent(in: binDir)
        check(
            "no_legacy_forge_serve",
            leftovers.isEmpty,
            leftovers.isEmpty
                ? "no forge-serve wrappers under \(binDir.path)"
                : "remove leftovers: \(leftovers.joined(separator: ", "))"
        )

        let mcpBinary = FileManager.default.isExecutableFile(atPath: installer.appExecutableURL.path)
            ? installer.appExecutableURL
            : installer.installedBinaryURL
        let lm = LMStudioEnvironment.registrationHealth(expectedBinary: mcpBinary)
        check("lm_studio_swift_stdio", lm.ok, lm.detail, hard: false)

        let plug = LMStudioMCPPluginInstaller.status(preferredBinary: mcpBinary)
        check("lm_studio_mcp_plugin", plug.isFullyInstalled, plug.detail, hard: false)

        return DoctorReport(
            ok: ok,
            version: Self.version,
            home: paths.home.path,
            checks: checks,
            telemetry: tel,
            shellPolicy: shell,
            binaryInstalled: binInstalled,
            binaryPath: binPath
        )
    }

    /// HTTP / CLI edge.
    public func doctor() throws -> [String: Any] {
        try doctorModel().asDictionary()
    }
}

private final class RuntimeShutdownReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var report: RuntimeJobShutdownReport?

    func store(_ report: RuntimeJobShutdownReport) {
        lock.lock()
        self.report = report
        lock.unlock()
    }

    func load() -> RuntimeJobShutdownReport? {
        lock.lock()
        defer { lock.unlock() }
        return report
    }
}

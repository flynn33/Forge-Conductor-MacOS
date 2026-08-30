// ManagerNode.swift
// What: Owns the persistent control-plane service state and dashboard listener.
// How: A synchronized runtime starts/stops/restarts one DashboardServer, applies typed
// settings, exposes doctor/status data, and records every lifecycle transition.
// Why: Central ownership prevents port races between the app, CLI, and LaunchAgent.

import Foundation
import ObjectiveC

/// Lifecycle state of the supervised dashboard HTTP service.
public enum ManagerServiceState: String, Sendable, Codable {
    case stopped
    case starting
    case running
    case restarting
    case stopping
    case failed
}

private struct ManagerOperatorPersistenceSnapshot: Sendable {
    let projects: [ProjectControlRecord]
    let bindings: [ProjectID: [ProjectContextBinding]]
    let resetReceipts: [ProjectID: ProjectGenerationResetReceipt]
    let runs: [ManagerOperatorRunReadModel]
    let continuity: [ManagerOperatorContinuityReadModel]
    let runtimeJobs: [RuntimeJobRecord]
    let runtimeCapabilities: RuntimeCapabilities
    let events: [AutonomyEvent]
}

/// Supervisor that keeps the dashboard control surface available.
/// Mutable process state lives in `ManagerRuntime` (SRP).
public final class ManagerNode: ManagerControlling, @unchecked Sendable {
    public typealias ManagedAutonomyFactory = @Sendable (ForgeApp) throws -> ManagedAutonomyRuntime
    private static let presencePruneInterval: TimeInterval = 60
    private static let presenceMaxAge: TimeInterval = 120
    private static let operatorRedactor = ProjectMemoryRedactor()

    public let app: ForgeApp
    private let lock = NSLock()
    private let runtime = ManagerRuntime()
    private let managedAutonomyFactory: ManagedAutonomyFactory
    private let generationResetCheckpoint: @Sendable (ProjectID, ProjectGeneration) throws -> Void
    private var managedAutonomy: ManagedAutonomyRuntime?

    public convenience init(
        app: ForgeApp,
        managedAutonomyFactory: @escaping ManagedAutonomyFactory = {
            try ManagedAutonomyRuntime(app: $0)
        }
    ) {
        self.init(
            app: app,
            managedAutonomyFactory: managedAutonomyFactory,
            generationResetCheckpoint: { _, _ in }
        )
    }

    convenience init(
        app: ForgeApp,
        generationResetCheckpoint: @escaping @Sendable (
            ProjectID,
            ProjectGeneration
        ) throws -> Void
    ) {
        self.init(
            app: app,
            managedAutonomyFactory: { try ManagedAutonomyRuntime(app: $0) },
            generationResetCheckpoint: generationResetCheckpoint
        )
    }

    private init(
        app: ForgeApp,
        managedAutonomyFactory: @escaping ManagedAutonomyFactory,
        generationResetCheckpoint: @escaping @Sendable (
            ProjectID,
            ProjectGeneration
        ) throws -> Void
    ) {
        self.app = app
        self.managedAutonomyFactory = managedAutonomyFactory
        self.generationResetCheckpoint = generationResetCheckpoint
    }

    deinit {
        stopWatchdog()
        stopSignalHandlers()
        tearDownDashboard()
    }

    // MARK: - Public status (typed domain)

    public var isShutdownRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return runtime.shutdownRequested
    }

    public func statusModel() -> ManagerStatus {
        lock.lock()
        defer { lock.unlock() }
        let cfg = app.config.model
        let httpUp = runtime.isHTTPUp
        let uptime: Int? = runtime.startedAt.map { Int(Date().timeIntervalSince($0)) }
        return ManagerStatus(
            ok: true,
            isManager: true,
            state: runtime.state,
            desiredRunning: runtime.desiredRunning,
            httpListening: httpUp,
            serviceActive: runtime.state == .running && httpUp,
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: runtime.startedAt,
            uptimeSec: uptime,
            restartCount: runtime.restartCount,
            lastError: runtime.lastError,
            autoRestart: cfg.manager.autoRestart,
            watchdogIntervalSec: cfg.manager.watchdogIntervalSec,
            openBrowserOnStart: cfg.manager.openBrowserOnStart,
            dashboardHost: cfg.dashboard.host,
            dashboardPort: cfg.dashboard.port,
            dashboardRefreshSec: cfg.dashboard.refreshIntervalSec,
            home: app.paths.home.path,
            version: ForgeApp.version
        )
    }

    public func settingsModel() -> ManagerSettings {
        let cfg = app.config.model
        let shell = app.config.shellPolicyStatus
        return ManagerSettings(
            dashboardHost: cfg.dashboard.host,
            dashboardPort: cfg.dashboard.port,
            dashboardRefreshSec: cfg.dashboard.refreshIntervalSec,
            autoRestart: cfg.manager.autoRestart,
            watchdogIntervalSec: cfg.manager.watchdogIntervalSec,
            openBrowserOnStart: cfg.manager.openBrowserOnStart,
            sessionIdleTTLSec: cfg.sessions.idleTTLSec,
            shellEnabled: shell.enabled,
            shellUserDisabled: shell.userDisabled,
            shellPolicyVersion: shell.policyVersion,
            shellPolicyOrigin: shell.policyOrigin,
            shellMigrationState: shell.migration.state,
            shellMigrationReceiptValid: shell.migration.receiptValid,
            shellRuntimeCapabilities: shell.runtimes,
            shellTimeoutSec: cfg.shell.defaultTimeoutSec,
            logLevel: cfg.logLevel,
            allowedRoots: ManagerSettingsNormalizer.canonicalAllowedRoots(cfg.allowedRoots)
        )
    }

    public func status() -> [String: Any] {
        statusModel().asDictionary().compactNSNull()
    }

    public func settings() -> [String: Any] {
        settingsModel().asDictionary()
    }

    /// Returns a bounded, read-only projection for the native operator console.
    /// The cursor pages only the durable event feed; every other section remains a
    /// current newest-first view so the console never presents stale control state.
    public func operatorSnapshot(
        limit: Int = 50,
        beforeEventSequence: Int64? = nil
    ) throws -> ManagerOperatorSnapshot {
        guard (1...100).contains(limit), beforeEventSequence.map({ $0 > 0 }) ?? true else {
            throw AutonomyError.invalidRequest("operator snapshot query is outside bounds")
        }
        let app = self.app
        let persisted = try Self.waitForAsync(timeoutSeconds: 10) {
            let control = app.projectContexts.repository
            let projects = try await control.operatorProjects(limit: limit)
            let projectIDs = projects.map(\.projectID)
            let bindings = try await control.operatorBindings(projectIDs: projectIDs)
            let resetReceipts = try await control.operatorLatestResetReceipts(projectIDs: projectIDs)
            let runRecords = try await control.operatorAutonomousRuns(limit: limit)
            let runs = try await control.operatorRunReadModels(runs: runRecords)
            let commandRecords = try await control.operatorContinuityCommands(limit: limit)
            let continuity = try await control.operatorContinuityReadModels(commands: commandRecords)
            let runtimeJobs = try await app.runtimeJobs.repository.operatorRecentJobs(limit: limit)
            let runtimeCapabilities = await app.runtimeJobs.service.capabilities()
            let events = try await control.operatorAutonomyEvents(
                limit: limit + 1,
                beforeSequence: beforeEventSequence
            )
            return ManagerOperatorPersistenceSnapshot(
                projects: projects,
                bindings: bindings,
                resetReceipts: resetReceipts,
                runs: runs,
                continuity: continuity,
                runtimeJobs: runtimeJobs,
                runtimeCapabilities: runtimeCapabilities,
                events: events
            )
        }

        let continuityByProject = Dictionary(
            persisted.continuity.map { ($0.command.projectID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let projectRows = persisted.projects.map { project in
            Self.operatorProject(
                project,
                bindings: persisted.bindings[project.projectID] ?? [],
                resetReceipt: persisted.resetReceipts[project.projectID],
                continuity: continuityByProject[project.projectID],
                paths: app.paths
            )
        }
        let runRows = persisted.runs.map(Self.operatorRun)
        let continuityRows = persisted.continuity.map(Self.operatorContinuity)
        let jobRows = persisted.runtimeJobs.map(Self.operatorRuntimeJob)
        let visibleEvents = Array(persisted.events.prefix(limit))
        let nextCursor = persisted.events.count > limit
            ? visibleEvents.last.map { String($0.sequence) }
            : nil
        let shell = app.config.shellPolicyStatus
        return ManagerOperatorSnapshot(
            generatedAt: ISO8601.string(from: app.clock.now()),
            limit: limit,
            projects: projectRows,
            runs: runRows,
            continuityOperations: continuityRows,
            runtimeJobs: jobRows,
            provider: Self.operatorProvider(from: persisted.runs),
            runtime: Self.operatorRuntime(
                persisted.runtimeCapabilities,
                defaultTimeoutSeconds: app.config.model.shell.defaultTimeoutSec,
                shellPolicyMigrationState: shell.migration.state
            ),
            events: visibleEvents.map(Self.operatorEvent),
            nextCursor: nextCursor
        )
    }

    public func operatorSnapshotDictionary(
        limit: Int = 50,
        beforeEventSequence: Int64? = nil
    ) throws -> [String: Any] {
        try operatorSnapshot(
            limit: limit,
            beforeEventSequence: beforeEventSequence
        ).asDictionary()
    }

    public func isServiceActive() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return runtime.isServiceActive
    }

    // MARK: - Lifecycle controls

    @discardableResult
    public func startService() throws -> ManagerStatus {
        pruneStalePresenceIfDue(force: true)

        lock.lock()
        runtime.desiredRunning = true
        runtime.lastError = nil
        if runtime.state == .running, runtime.isHTTPUp {
            lock.unlock()
            return statusModel()
        }
        runtime.state = .starting
        lock.unlock()

        do {
            try bindAndStartDashboard()
            lock.lock()
            runtime.markRunning()
            lock.unlock()
            persistState()
            app.diagnostics.info("manager_service_started", ["url": dashboardURLString()])
            return statusModel()
        } catch {
            lock.lock()
            runtime.markFailed(error)
            lock.unlock()
            persistState()
            app.diagnostics.error("manager_service_start_failed", [
                "error": "\(error)",
            ], category: .manager)
            throw error
        }
    }

    @discardableResult
    public func stopService() throws -> ManagerStatus {
        lock.lock()
        runtime.desiredRunning = false
        runtime.state = .stopping
        runtime.markStopped()
        lock.unlock()
        persistState()
        app.diagnostics.info("manager_service_stopped", [:])
        return statusModel()
    }

    @discardableResult
    public func restartService() throws -> ManagerStatus {
        lock.lock()
        let count = runtime.beginRestart()
        lock.unlock()

        tearDownDashboard()
        Thread.sleep(forTimeInterval: 0.2)
        do {
            try bindAndStartDashboard()
            lock.lock()
            runtime.state = .running
            runtime.startedAt = Date()
            runtime.lastError = nil
            lock.unlock()
            persistState()
            app.diagnostics.info("manager_service_restarted", ["restart_count": "\(count)"])
            return statusModel()
        } catch {
            lock.lock()
            runtime.markFailed(error)
            lock.unlock()
            persistState()
            throw error
        }
    }

    @discardableResult
    public func updateSettings(_ patch: ManagerSettingsPatch, apply: Bool = true) throws -> ManagerSettings {
        _ = try updateSettingsDictionary(patch.asConfigPatch(), apply: apply)
        return settingsModel()
    }

    @discardableResult
    public func updateSettings(_ patch: [String: Any], apply: Bool = true) throws -> [String: Any] {
        try updateSettingsDictionary(patch, apply: apply)
    }

    private func updateSettingsDictionary(_ patch: [String: Any], apply: Bool) throws -> [String: Any] {
        let before = app.config.model.dashboard
        let normalized = ManagerSettingsNormalizer.normalize(patch)
        _ = try app.config.update(normalized, save: true)
        app.config.reload()
        let after = app.config.model.dashboard
        let bindChanged = before.host != after.host || before.port != after.port

        lock.lock()
        let want = runtime.desiredRunning
        lock.unlock()

        if apply && bindChanged && want {
            _ = try restartService()
        } else if apply {
            restartWatchdog()
        }

        app.diagnostics.info("manager_settings_updated", [
            "bind_changed": bindChanged ? "true" : "false",
        ])
        var out = settings()
        out["applied"] = apply
        out["bind_changed"] = bindChanged
        out["status"] = status()
        return out
    }

    public static func normalizeSettingsPatch(_ patch: [String: Any]) -> [String: Any] {
        ManagerSettingsNormalizer.normalize(patch)
    }

    // MARK: - Project context controls

    @discardableResult
    public func registerProject(
        path: String,
        displayName: String? = nil,
        repositoryIdentity: String? = nil
    ) throws -> [String: Any] {
        let initialized = try app.projectMemory.initialize(
            path: path,
            displayName: displayName,
            repositoryIdentity: repositoryIdentity
        )
        guard let projectIDString = initialized["project_id"] as? String else {
            throw ProjectContextError.invalidIdentifier("registered project identifier")
        }
        let descriptor = try app.projectMemory.identities.descriptor(projectID: projectIDString)
        let project = try app.projectContexts.registerProject(
            descriptor: descriptor,
            canonicalRoot: URL(fileURLWithPath: path, isDirectory: true)
        )
        app.diagnostics.info(
            "manager_project_registered",
            [
                "project_id": project.projectID.description,
                "project_generation": "\(project.generation.rawValue)",
            ],
            category: .manager
        )
        return Self.projectDictionary(project)
    }

    public func projectStatus(projectID: ProjectID) throws -> [String: Any] {
        guard let project = try app.projectContexts.project(projectID) else {
            throw ProjectContextError.projectNotFound(projectID)
        }
        return Self.projectDictionary(project)
    }

    @discardableResult
    public func bindProject(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        owner: ProjectBindingOwner,
        runID: RunID? = nil,
        allowedTools: Set<String> = ["*"],
        networkAllowed: Bool = false,
        maximumInlineOutputBytes: Int = ProjectContextService.defaultInlineOutputLimit
    ) throws -> [String: Any] {
        guard let project = try app.projectContexts.project(projectID) else {
            throw ProjectContextError.projectNotFound(projectID)
        }
        let scope = ToolAuthorizationScope(
            canonicalRoots: [project.canonicalRoot],
            allowedTools: allowedTools,
            networkAllowed: networkAllowed,
            maximumInlineOutputBytes: maximumInlineOutputBytes
        )
        let binding = try app.projectContexts.bind(
            owner: owner,
            projectID: projectID,
            generation: expectedGeneration,
            runID: runID,
            authorizationScope: scope
        )
        app.diagnostics.info(
            "manager_project_bound",
            [
                "project_id": projectID.description,
                "project_generation": "\(expectedGeneration.rawValue)",
                "owner_kind": owner.kind.rawValue,
                "owner_id": owner.id,
            ],
            category: .manager
        )
        return Self.bindingDictionary(binding)
    }

    @discardableResult
    public func resetProjectGeneration(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration
    ) throws -> [String: Any] {
        let filesystemRecovery = SecureFilesystemRecoveryLedger(paths: app.paths)
        do {
            return try filesystemRecovery.withRetainedAuthorityFence(
                projectID: projectID,
                generation: expectedGeneration
            ) { assertNoRetainedAuthority in
                _ = try app.projectContexts.beginReset(
                    projectID: projectID,
                    expectedGeneration: expectedGeneration
                )
                do {
                    try generationResetCheckpoint(projectID, expectedGeneration)
                    // Recheck after the control plane enters resetting. Normal
                    // retainers share the ledger fence; a same-UID namespace
                    // replacement remains an explicit qualification race.
                    try assertNoRetainedAuthority()
                    app.projectMemory.closeProject(projectID.description)
                    let receipt = try app.projectContexts.completeReset(
                        projectID: projectID,
                        expectedGeneration: expectedGeneration
                    )
                    app.diagnostics.info(
                        "manager_project_generation_reset",
                        [
                            "project_id": projectID.description,
                            "prior_generation": "\(receipt.priorGeneration.rawValue)",
                            "new_generation": "\(receipt.newGeneration.rawValue)",
                            "invalidated_bindings": "\(receipt.invalidatedBindingCount)",
                        ],
                        category: .manager
                    )
                    return [
                        "ok": true,
                        "project_id": projectID.description,
                        "prior_generation": receipt.priorGeneration.rawValue,
                        "new_generation": receipt.newGeneration.rawValue,
                        "invalidated_binding_count": receipt.invalidatedBindingCount,
                        "completed_at": receipt.completedAt,
                    ]
                } catch {
                    let operationError = error
                    do {
                        try app.projectContexts.cancelReset(
                            projectID: projectID,
                            expectedGeneration: expectedGeneration
                        )
                    } catch {
                        throw ProjectContextError.resetCancellationFailed(projectID)
                    }
                    throw operationError
                }
            }
        } catch SecureFilesystemRecoveryLedgerError.retainedAuthority {
            throw ProjectContextError.retainedFilesystemRecovery(projectID)
        }
    }

    private static func projectDictionary(_ project: ProjectControlRecord) -> [String: Any] {
        [
            "ok": true,
            "project_id": project.projectID.description,
            "display_name": project.displayName,
            "canonical_root": project.canonicalRoot.path,
            "project_generation": project.generation.rawValue,
            "lifecycle_state": project.lifecycleState.rawValue,
            "repository_fingerprint": project.repositoryFingerprint as Any,
            "bookmark_reference": project.bookmarkReference as Any,
            "created_at": project.createdAt,
            "updated_at": project.updatedAt,
        ].compactNSNull()
    }

    private static func bindingDictionary(_ binding: ProjectContextBinding) -> [String: Any] {
        [
            "ok": true,
            "binding_id": binding.bindingID.uuidString.lowercased(),
            "owner_kind": binding.owner.kind.rawValue,
            "owner_id": binding.owner.id,
            "project_id": binding.projectID.description,
            "project_generation": binding.projectGeneration.rawValue,
            "run_id": binding.runID?.description as Any,
            "authorization_roots": binding.authorizationScope.canonicalRoots.map(\.path),
            "allowed_tools": binding.authorizationScope.allowedTools.sorted(),
            "network_allowed": binding.authorizationScope.networkAllowed,
            "maximum_inline_output_bytes": binding.authorizationScope.maximumInlineOutputBytes,
            "active": binding.active,
            "created_at": binding.createdAt,
            "updated_at": binding.updatedAt,
        ].compactNSNull()
    }

    // MARK: - Autonomous run controls

    @discardableResult
    public func startAutonomousRun(
        runID: RunID = RunID(),
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        assignmentID: String? = nil,
        mission: String,
        providerID: String,
        adapterID: String,
        modelKey: String,
        allowedTools: Set<String>,
        completionGates: [String],
        networkAllowed: Bool = false,
        maximumInlineOutputBytes: Int = ProjectContextService.defaultInlineOutputLimit
    ) throws -> [String: Any] {
        lock.lock()
        let autonomy = managedAutonomy
        lock.unlock()
        guard let autonomy else { throw AutonomyError.shutdown }
        guard let project = try app.projectContexts.project(projectID) else {
            throw ProjectContextError.projectNotFound(projectID)
        }
        guard project.generation == expectedGeneration else {
            throw ProjectContextError.staleProjectGeneration(
                expected: expectedGeneration,
                actual: project.generation
            )
        }
        let request = AutonomousRunRequest(
            runID: runID,
            projectID: projectID,
            projectGeneration: expectedGeneration,
            assignmentID: assignmentID,
            mission: mission,
            providerID: providerID,
            adapterID: adapterID,
            modelKey: modelKey,
            specification: AutonomousRunSpecification(
                allowedTools: allowedTools.sorted(),
                completionGates: completionGates
            ),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [project.canonicalRoot],
                allowedTools: allowedTools,
                networkAllowed: networkAllowed,
                maximumInlineOutputBytes: maximumInlineOutputBytes
            )
        )
        let run = try Self.waitForAsync(timeoutSeconds: 15) {
            try await autonomy.createRun(request)
        }
        return try Self.autonomousRunDictionary(run)
    }

    public func autonomousRunStatus(runID: RunID) throws -> [String: Any] {
        lock.lock()
        let autonomy = managedAutonomy
        lock.unlock()
        guard let autonomy else { throw AutonomyError.shutdown }
        let run = try Self.waitForAsync(timeoutSeconds: 10) {
            try await autonomy.run(runID)
        }
        return try Self.autonomousRunDictionary(run)
    }

    @discardableResult
    public func controlAutonomousRun(
        runID: RunID,
        action: ManagedAutonomyControlAction
    ) throws -> [String: Any] {
        lock.lock()
        let autonomy = managedAutonomy
        lock.unlock()
        guard let autonomy else { throw AutonomyError.shutdown }
        let run = try Self.waitForAsync(timeoutSeconds: 15) {
            try await autonomy.controlRun(runID, action: action)
        }
        return try Self.autonomousRunDictionary(run)
    }

    public func managedAutonomyStatus() throws -> [String: Any] {
        lock.lock()
        let autonomy = managedAutonomy
        lock.unlock()
        guard let autonomy else {
            return ["ok": true, "started": false]
        }
        let snapshot = try Self.waitForAsync(timeoutSeconds: 10) {
            await autonomy.snapshot()
        }
        return [
            "ok": true,
            "started": snapshot.started,
            "active_run_ids": snapshot.supervisor.activeRunIDs.map(\.description),
            "deferred_run_ids": snapshot.supervisor.deferredRunIDs.map(\.description),
            "recent_results": snapshot.supervisor.recentResults.map { result in
                [
                    "run_id": result.runID.description,
                    "final_state": result.finalState.rawValue,
                    "steps_executed": result.stepsExecuted,
                    "yielded": result.yielded,
                ] as [String: Any]
            },
        ]
    }

    private static func autonomousRunDictionary(
        _ run: AutonomousRunRecord
    ) throws -> [String: Any] {
        let data = try JSONEncoder().encode(run)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProjectContextError.integrityFailure(
                "autonomous run could not be encoded for the manager transport"
            )
        }
        object["ok"] = true
        object["run_id"] = run.runID.description
        object["project_id"] = run.projectID.description
        object["project_generation"] = run.projectGeneration.rawValue
        object["assignment_id"] = run.assignmentID
        object["mission"] = run.mission
        object["state"] = run.state.rawValue
        object["continuity_mode"] = run.continuityMode.rawValue
        object["provider_id"] = run.providerID
        object["adapter_id"] = run.adapterID
        object["model_key"] = run.modelKey
        object["active_session_id"] = run.activeSessionID
        object["active_operation_id"] = run.activeOperationID?.uuidString.lowercased()
        object["continuation_pending"] = run.continuationPending
        object["work_item"] = run.specification.work.workItem
        object["completion_gates"] = run.specification.completionGates
        object["passed_gates"] = []
        object["last_error_code"] = run.lastErrorCode
        object["last_error_summary"] = run.lastErrorSummary
        object["retry_at"] = run.retryAt
        object["created_at"] = run.createdAt
        object["updated_at"] = run.updatedAt
        return object.compactNSNull()
    }

    private static func operatorProject(
        _ project: ProjectControlRecord,
        bindings: [ProjectContextBinding],
        resetReceipt: ProjectGenerationResetReceipt?,
        continuity: ManagerOperatorContinuityReadModel?,
        paths: AppPaths
    ) -> ManagerOperatorProject {
        let databaseURL = paths.projectsDir
            .appendingPathComponent(project.projectID.description, isDirectory: true)
            .appendingPathComponent("memory.sqlite3")
        let memory: ManagerOperatorMemoryHealth
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size])
                .flatMap { ($0 as? NSNumber)?.uint64Value }
            memory = ManagerOperatorMemoryHealth(
                state: "available_unverified",
                databaseBytes: bytes,
                recordCount: nil,
                lastIntegrityCheck: nil,
                detail: bytes == nil ? "metadata_unavailable" : "integrity_not_checked_by_snapshot"
            )
        } else {
            memory = ManagerOperatorMemoryHealth(
                state: "uninitialized",
                databaseBytes: nil,
                recordCount: nil,
                lastIntegrityCheck: nil,
                detail: nil
            )
        }

        let continuitySession = continuity?.successor ?? continuity?.predecessor
        let continuityState: String
        if let continuity {
            continuityState = continuity.command.state == .completed
                ? "predecessor_sealed"
                : continuity.command.state.rawValue
        } else {
            continuityState = "unavailable"
        }
        let warnings = project.lifecycleState == .quarantined
            ? ["project_quarantined"]
            : []
        return ManagerOperatorProject(
            projectID: project.projectID.description,
            displayName: project.displayName,
            canonicalRoot: project.canonicalRoot.path,
            projectGeneration: project.generation.rawValue,
            lifecycleState: project.lifecycleState.rawValue,
            bindings: bindings.map {
                ManagerOperatorBinding(
                    bindingID: $0.bindingID.uuidString.lowercased(),
                    ownerKind: $0.owner.kind.rawValue,
                    ownerID: operatorIdentifier($0.owner.id, maximumCharacters: 512),
                    runID: $0.runID?.description,
                    active: $0.active
                )
            },
            memory: memory,
            continuity: ManagerOperatorProjectContinuity(
                state: continuityState,
                latestHandoffID: continuitySession?.handoffID?.uuidString.lowercased(),
                latestHandoffSHA256: continuitySession?.handoffSHA256,
                migrationState: nil
            ),
            migrationWarnings: warnings,
            resetReceipt: resetReceipt.map {
                ManagerOperatorResetReceipt(
                    priorGeneration: $0.priorGeneration.rawValue,
                    newGeneration: $0.newGeneration.rawValue,
                    invalidatedBindingCount: $0.invalidatedBindingCount,
                    completedAt: $0.completedAt
                )
            },
            createdAt: project.createdAt,
            updatedAt: project.updatedAt
        )
    }

    private static func operatorRun(
        _ detail: ManagerOperatorRunReadModel
    ) -> ManagerOperatorRun {
        let run = detail.run
        let receipt = run.completionRequestJSON.flatMap {
            try? JSONDecoder().decode(CompletionValidationReceipt.self, from: Data($0.utf8))
        }
        let passedGates = receipt.flatMap { $0.hasValidProof() ? $0 : nil }?
            .results.filter(\.passed).map(\.gate) ?? []
        let providerInstanceID = detail.budgetState
            .flatMap { $0.configuration.capacity.activeInstanceID }
            .map { operatorIdentifier($0, maximumCharacters: 1_024) }
        let predecessorSessionID = detail.activeSession
            .flatMap(\.predecessorSessionID)
            .map { operatorIdentifier($0, maximumCharacters: 1_024) }
        let leaseOwner = detail.lease.map {
            operatorIdentifier($0.ownerID, maximumCharacters: 512)
        }
        return ManagerOperatorRun(
            runID: run.runID.description,
            projectID: run.projectID.description,
            projectGeneration: run.projectGeneration.rawValue,
            assignmentID: run.assignmentID.map { operatorIdentifier($0, maximumCharacters: 512) },
            mission: operatorSummary(run.mission, maximumCharacters: 2_048) ?? "<redacted>",
            state: run.state.rawValue,
            continuityMode: run.continuityMode.rawValue,
            providerID: run.providerID.map { operatorIdentifier($0, maximumCharacters: 512) },
            adapterID: run.adapterID.map { operatorIdentifier($0, maximumCharacters: 512) },
            modelKey: run.modelKey.map { operatorIdentifier($0, maximumCharacters: 1_024) },
            providerInstanceID: providerInstanceID,
            activeSessionID: run.activeSessionID.map { operatorIdentifier($0, maximumCharacters: 1_024) },
            predecessorSessionID: predecessorSessionID,
            activeOperationID: run.activeOperationID?.uuidString.lowercased(),
            continuationPending: run.continuationPending,
            leaseOwner: leaseOwner,
            workItem: operatorSummary(run.specification.work.workItem, maximumCharacters: 1_024),
            lastModelTurnAt: detail.latestProviderTurn?.updatedAt,
            lastToolActivityAt: detail.latestToolInvocation?.updatedAt,
            completionGates: Array(run.specification.completionGates.prefix(128)),
            passedGates: Array(passedGates.prefix(128)),
            lastErrorCode: run.lastErrorCode.map { operatorIdentifier($0, maximumCharacters: 128) },
            lastErrorSummary: operatorSummary(run.lastErrorSummary, maximumCharacters: 512),
            retryAt: run.retryAt,
            createdAt: run.createdAt,
            updatedAt: run.updatedAt
        )
    }

    private static func operatorContinuity(
        _ detail: ManagerOperatorContinuityReadModel
    ) -> ManagerOperatorContinuity {
        let command = detail.command
        let session = detail.successor ?? detail.predecessor
        let continuationIssued = detail.automaticContinuation.map { turn in
            turn.state != .intent && turn.state != .cancelled
        } ?? false
        return ManagerOperatorContinuity(
            operationID: command.operationID.uuidString.lowercased(),
            projectID: command.projectID.description,
            projectGeneration: command.projectGeneration.rawValue,
            runID: command.runID.description,
            mode: detail.run?.continuityMode.rawValue ?? "unavailable",
            state: command.state == .completed ? "predecessor_sealed" : command.state.rawValue,
            controlState: command.state.rawValue,
            handoffID: session?.handoffID?.uuidString.lowercased(),
            handoffSHA256: session?.handoffSHA256,
            predecessorSessionID: detail.predecessor?.sessionID
                ?? detail.successor?.predecessorSessionID,
            successorSessionID: detail.successor?.sessionID,
            successorProviderResponseID: detail.successor?.providerResponseID,
            acknowledgementSHA256: nil,
            attempt: command.attempt,
            continuationIssued: continuationIssued,
            budget: detail.budgetObservation.map(operatorBudget),
            lastError: operatorSummary(command.lastErrorSummary, maximumCharacters: 512),
            retryAt: command.retryAt,
            updatedAt: command.updatedAt
        )
    }

    private static func operatorBudget(
        _ observation: ContextBudgetObservation
    ) -> ManagerOperatorContextBudget {
        let responseReserve = observation.reserves.outputTokens.addingReportingOverflow(
            observation.reserves.schemaTokens
        )
        return ManagerOperatorContextBudget(
            capacityTokens: observation.capacity,
            usedTokens: observation.used,
            responseReserveTokens: responseReserve.overflow ? Int.max : responseReserve.partialValue,
            handoffReserveTokens: observation.reserves.handoffTokens,
            recoveryReserveTokens: observation.reserves.recoveryTokens,
            remainingTokens: observation.remaining,
            source: observation.source.rawValue,
            confidence: String(
                format: "%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                observation.confidence
            ),
            action: observation.action.rawValue,
            checkpointThreshold: observation.thresholds.checkpoint,
            rolloverThreshold: observation.thresholds.rollover
        )
    }

    private static func operatorRuntimeJob(
        _ job: RuntimeJobRecord
    ) -> ManagerOperatorRuntimeJob {
        ManagerOperatorRuntimeJob(
            jobID: job.jobID.uuidString.lowercased(),
            runID: job.runID?.description,
            projectID: job.projectID.description,
            projectGeneration: job.projectGeneration.rawValue,
            runtimeKind: job.runtimeKind.rawValue,
            state: job.state.rawValue,
            canonicalWorkingDirectory: job.canonicalWorkingDirectory.path,
            commandSummary: operatorSummary(job.commandSummary, maximumCharacters: 512) ?? "<redacted>",
            timeoutSeconds: job.timeoutSeconds,
            exitCode: job.exitCode.map(Int.init),
            outputArtifactID: job.outputArtifactID.map {
                operatorIdentifier($0, maximumCharacters: 512)
            },
            outputBytes: job.outputBytes,
            errorSummary: operatorSummary(job.errorSummary, maximumCharacters: 512),
            createdAt: job.createdAt,
            completedAt: job.completedAt
        )
    }

    private static func operatorProvider(
        from runs: [ManagerOperatorRunReadModel]
    ) -> ManagerOperatorProvider {
        guard let detail = runs.first(where: {
            $0.budgetState != nil || $0.activeSession != nil
        }) ?? runs.first else {
            return ManagerOperatorProvider(
                providerID: nil,
                health: "unavailable",
                endpoint: nil,
                loopback: nil,
                tls: nil,
                authenticationEnabled: nil,
                credentialConfigured: nil,
                apiMode: nil,
                modelKey: nil,
                instanceID: nil,
                activeContextLength: nil,
                maximumContextLength: nil,
                toolUseCapable: nil,
                lifecycleManagementEnabled: nil,
                idleTTLSeconds: nil,
                contractFingerprint: nil,
                lastProbeAt: nil,
                lastProbeError: nil
            )
        }
        let capacity = detail.budgetState?.configuration.capacity
        let session = detail.activeSession
        let instanceID = capacity.flatMap(\.activeInstanceID).map {
            operatorIdentifier($0, maximumCharacters: 1_024)
        }
        let contractFingerprint = capacity.map {
            operatorIdentifier($0.providerVersionFingerprint, maximumCharacters: 1_024)
        }
        return ManagerOperatorProvider(
            providerID: (detail.run.providerID ?? session?.providerID).map {
                operatorIdentifier($0, maximumCharacters: 512)
            },
            health: "unavailable",
            endpoint: nil,
            loopback: nil,
            tls: nil,
            authenticationEnabled: nil,
            credentialConfigured: nil,
            apiMode: nil,
            modelKey: (detail.run.modelKey ?? session?.modelKey).map {
                operatorIdentifier($0, maximumCharacters: 1_024)
            },
            instanceID: instanceID,
            activeContextLength: capacity?.capacity ?? session?.contextCapacity,
            maximumContextLength: capacity?.maximumContextLength,
            toolUseCapable: nil,
            lifecycleManagementEnabled: nil,
            idleTTLSeconds: nil,
            contractFingerprint: contractFingerprint,
            lastProbeAt: nil,
            lastProbeError: nil
        )
    }

    private static func operatorRuntime(
        _ capabilities: RuntimeCapabilities,
        defaultTimeoutSeconds: Int,
        shellPolicyMigrationState: String
    ) -> ManagerOperatorRuntime {
        func executable(_ capability: RuntimeExecutableCapability) -> ManagerOperatorRuntimeExecutable {
            ManagerOperatorRuntimeExecutable(
                available: capability.available,
                path: capability.executablePath,
                version: nil
            )
        }
        return ManagerOperatorRuntime(
            direct: executable(capabilities.directProcess),
            zsh: executable(capabilities.zsh),
            bash: executable(capabilities.bash),
            python: executable(capabilities.python),
            powershell: executable(capabilities.powershell),
            maximumConcurrentJobs: capabilities.maximumConcurrentJobs,
            defaultTimeoutSeconds: defaultTimeoutSeconds,
            maximumInlineOutputBytes: capabilities.maximumInlineOutputBytes,
            maximumArtifactBytesPerJob: capabilities.maximumArtifactBytesPerJob,
            networkPolicy: "per_project_authorization_scope",
            shellPolicyMigrationState: shellPolicyMigrationState
        )
    }

    private static func operatorEvent(_ event: AutonomyEvent) -> ManagerOperatorEvent {
        let metadata = (try? JSONSerialization.jsonObject(with: Data(event.metadataJSON.utf8)))
            as? [String: String] ?? [:]
        return ManagerOperatorEvent(
            eventID: event.eventID.uuidString.lowercased(),
            timestamp: event.createdAt,
            kind: event.eventType,
            summary: operatorSummary(event.summary, maximumCharacters: 512) ?? "<redacted>",
            severity: event.severity.rawValue,
            projectID: event.projectID?.description,
            runID: event.runID?.description,
            operationID: operatorUUID(metadata["operation_id"]),
            jobID: operatorUUID(metadata["job_id"]),
            providerRequestID: metadata["provider_request_id"].map {
                operatorIdentifier($0, maximumCharacters: 512)
            },
            artifactID: metadata["artifact_id"].map {
                operatorIdentifier($0, maximumCharacters: 512)
            }
        )
    }

    private static func operatorUUID(_ value: String?) -> String? {
        value.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
    }

    private static func operatorIdentifier(
        _ value: String,
        maximumCharacters: Int
    ) -> String {
        let redacted: String
        do {
            redacted = try operatorRedactor.redact(value) ?? ""
        } catch {
            return "<redacted>"
        }
        return String(redacted.prefix(maximumCharacters))
    }

    private static func operatorSummary(
        _ value: String?,
        maximumCharacters: Int
    ) -> String? {
        guard let value else { return nil }
        let redacted: String
        do {
            redacted = try operatorRedactor.redact(value) ?? ""
        } catch {
            return "<redacted>"
        }
        let flattened = redacted.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(flattened.prefix(maximumCharacters))
    }

    public func requestShutdown(delayMs: Int = 300) {
        lock.lock()
        runtime.requestShutdown()
        lock.unlock()
        app.diagnostics.info("manager_shutdown_requested", [:])
        runtime.queue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            self?.halt()
        }
    }

    // MARK: - Run loop

    public func run(openBrowser: Bool = false) throws {
        if let existing = ManagerPIDFile.runningPID(paths: app.paths),
           existing != ProcessInfo.processInfo.processIdentifier {
            throw NSError(
                domain: "ManagerNode",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Manager already running (pid \(existing)). Use: forge-conductor manager stop"]
            )
        }

        try ManagerPIDFile.write(paths: app.paths)
        defer { ManagerPIDFile.remove(paths: app.paths) }

        app.diagnostics.info("manager_run_start", [
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "home": app.paths.home.path,
        ])

        do {
            _ = try recoverManagedAutonomy()
            try startService()
        } catch {
            shutdownManagedAutonomy()
            throw error
        }

        let shouldOpen = openBrowser || app.config.model.manager.openBrowserOnStart
        if shouldOpen {
            openDashboardBrowser()
        }

        startWatchdog()
        installSignalHandlers()

        fputs("Forge-Conductor manager running — \(dashboardURLString())\n", stderr)
        fputs("  controls: Start / Stop / Restart / Settings on the dashboard\n", stderr)
        fputs("  stop process: forge-conductor manager stop   or dashboard Shutdown\n", stderr)

        runtime.runLock.wait()
    }

    private func halt() {
        stopWatchdog()
        stopSignalHandlers()
        tearDownDashboard()
        shutdownManagedAutonomy()
        let shutdownReport = app.shutdown()
        guard shutdownReport.completed else {
            let unresolved = shutdownReport.unresolvedJobIDs
                .map { $0.uuidString.lowercased() }
                .joined(separator: ",")
            let error = RuntimeJobError.storageFailure(
                "manager shutdown retained runtime process ownership: \(unresolved)"
            )
            lock.lock()
            runtime.markFailed(error)
            lock.unlock()
            persistState()
            ManagerPIDFile.remove(paths: app.paths)
            runtime.runLock.signal()
            fputs("forge-conductor manager shutdown incomplete: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        ManagerPIDFile.remove(paths: app.paths)
        lock.lock()
        runtime.markStopped()
        lock.unlock()
        persistState()
        runtime.runLock.signal()
        exit(0)
    }

    // MARK: - Dashboard binding

    private func bindAndStartDashboard() throws {
        app.config.reload()
        let host = app.config.model.dashboard.host
        let port = UInt16(clamping: app.config.model.dashboard.port)

        lock.lock()
        if let existing = runtime.dashboard, existing.isRunning,
           existing.boundHost == host, existing.boundPort == port {
            existing.manager = self
            lock.unlock()
            return
        }
        lock.unlock()

        tearDownDashboard()

        let server = DashboardServer(app: app, host: host, port: port)
        server.manager = self
        try server.start()

        lock.lock()
        runtime.dashboard = server
        lock.unlock()
    }

    private func tearDownDashboard() {
        lock.lock()
        let server = runtime.dashboard
        runtime.dashboard = nil
        lock.unlock()
        server?.manager = nil
        server?.stop()
    }

    private func dashboardURLString() -> String {
        let d = app.config.model.dashboard
        return "http://\(d.host):\(d.port)/"
    }

    private func openDashboardBrowser() {
        let runner = ProcessRunner()
        let url = dashboardURLString()
        let chrome = "/Applications/Google Chrome.app"
        if FileManager.default.fileExists(atPath: chrome) {
            _ = try? runner.run(
                executable: "/usr/bin/open",
                arguments: ["-a", "Google Chrome", url],
                timeoutSec: 5
            )
        } else {
            _ = try? runner.run(
                executable: "/usr/bin/open",
                arguments: [url],
                timeoutSec: 5
            )
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        stopWatchdog()
        let interval = max(1, app.config.model.manager.watchdogIntervalSec)
        let timer = DispatchSource.makeTimerSource(queue: runtime.queue)
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            self?.watchdogTick()
        }
        timer.resume()
        lock.lock()
        runtime.watchdog = timer
        lock.unlock()
    }

    private func restartWatchdog() {
        startWatchdog()
    }

    private func stopWatchdog() {
        lock.lock()
        runtime.cancelWatchdog()
        lock.unlock()
    }

    private func watchdogTick() {
        lock.lock()
        let want = runtime.desiredRunning
        let auto = app.config.model.manager.autoRestart
        let httpUp = runtime.isHTTPUp
        let shutting = runtime.shutdownRequested
        let current = runtime.state
        lock.unlock()

        if shutting { return }

        pruneStalePresenceIfDue()
        scheduleAutonomyTick()

        if !httpUp && !shutting {
            app.diagnostics.warn("manager_watchdog_http_recover", [
                "desired_running": want ? "true" : "false",
                "state": current.rawValue,
            ])
            do {
                try bindAndStartDashboard()
                lock.lock()
                if want {
                    runtime.markRunning()
                } else if runtime.state != .stopped {
                    runtime.markStopped()
                }
                runtime.restartCount += 1
                lock.unlock()
                persistState()
            } catch {
                lock.lock()
                runtime.markFailed(error)
                lock.unlock()
                persistState()
            }
            return
        }

        if want && auto && current == .failed && httpUp {
            lock.lock()
            runtime.markRunning()
            lock.unlock()
            persistState()
        }

        persistState()
    }

    // MARK: - Managed autonomy

    /// Starts durable recovery before the dashboard accepts autonomous run commands.
    /// This path is invoked only by the persistent manager process, not by GUI/MCP-only
    /// composition roots that happen to expose dashboard controls.
    @discardableResult
    public func recoverManagedAutonomy() throws -> AutonomyStartupReport? {
        lock.lock()
        if managedAutonomy != nil {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let value = try managedAutonomyFactory(app)
        let report = try Self.waitForAsync(timeoutSeconds: 30) {
            try await value.start()
        }
        lock.lock()
        managedAutonomy = value
        lock.unlock()
        app.diagnostics.info(
            "manager_autonomy_recovered",
            [
                "activated_runs": "\(report.activatedRuns.count)",
                "deferred_runs": "\(report.deferredRuns.count)",
                "discovered_runs": "\(report.discoveredRuns)",
                "released_expired_leases": "\(report.releasedExpiredLeases)",
            ],
            category: .manager
        )
        return report
    }

    private func scheduleAutonomyTick() {
        lock.lock()
        guard let autonomy = managedAutonomy,
              !runtime.autonomyTickPending,
              !runtime.shutdownRequested else {
            lock.unlock()
            return
        }
        runtime.autonomyTickPending = true
        lock.unlock()

        Task { [weak self, autonomy] in
            do {
                try await autonomy.tick()
            } catch {
                self?.app.diagnostics.warn(
                    "manager_autonomy_tick_failed",
                    ["error": String(error.localizedDescription.prefix(2_048))],
                    category: .manager
                )
            }
            guard let self else { return }
            self.markAutonomyTickComplete()
        }
    }

    private func markAutonomyTickComplete() {
        lock.lock()
        runtime.autonomyTickPending = false
        lock.unlock()
    }

    public func shutdownManagedAutonomy() {
        lock.lock()
        let autonomy = managedAutonomy
        managedAutonomy = nil
        runtime.autonomyTickPending = false
        lock.unlock()
        guard let autonomy else { return }
        do {
            _ = try Self.waitForAsync(timeoutSeconds: 20) {
                await autonomy.shutdown()
                return true
            }
        } catch {
            app.diagnostics.error(
                "manager_autonomy_shutdown_deadline",
                ["error": error.localizedDescription],
                category: .manager
            )
        }
    }

    private static func waitForAsync<Value: Sendable>(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ManagerAsyncResult<Value>()
        Task.detached {
            do {
                result.store(.success(try await operation()))
            } catch {
                result.store(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + max(0.1, timeoutSeconds)) == .success else {
            throw AutonomyError.invalidRequest("manager async operation exceeded its bounded deadline")
        }
        guard let resolved = result.take() else {
            throw AutonomyError.invalidRequest("manager async operation completed without a result")
        }
        return try resolved.get()
    }

    private func pruneStalePresenceIfDue(force: Bool = false) {
        let now = app.clock.now()
        lock.lock()
        let claimed = force || runtime.claimPresencePrune(
            now: now,
            minimumInterval: Self.presencePruneInterval
        )
        if force {
            runtime.lastPresencePruneAt = now
        }
        lock.unlock()
        guard claimed else { return }

        do {
            let removed = try app.store.presencePrune(maxAgeSec: Self.presenceMaxAge)
            if removed > 0 {
                app.diagnostics.info("manager_presence_pruned", [
                    "removed": "\(removed)",
                    "max_age_sec": "\(Int(Self.presenceMaxAge))",
                ], category: .manager)
            }
        } catch {
            app.diagnostics.warn("manager_presence_prune_failed", [
                "error": error.localizedDescription,
            ], category: .manager)
        }
    }

    private func installSignalHandlers() {
        stopSignalHandlers()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: runtime.queue)
        let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: runtime.queue)
        sigInt.setEventHandler { [weak self] in self?.requestShutdown(delayMs: 50) }
        sigTerm.setEventHandler { [weak self] in self?.requestShutdown(delayMs: 50) }
        sigInt.resume()
        sigTerm.resume()
        lock.lock()
        runtime.signalSources = [sigInt, sigTerm]
        lock.unlock()
    }

    private func stopSignalHandlers() {
        lock.lock()
        runtime.cancelSignalSources()
        lock.unlock()
    }

    private func persistState() {
        let snap = status()
        if let data = try? JSONSupport.data(from: snap) {
            try? data.write(to: app.paths.managerState, options: .atomic)
        }
    }
}

private final class ManagerAsyncResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ value: Result<Value, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func take() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

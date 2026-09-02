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

private struct ManagerOperatorProjectPersistenceSnapshot: Sendable {
    let project: ProjectControlRecord
    let bindings: [ProjectContextBinding]
    let resetReceipt: ProjectGenerationResetReceipt?
    let continuity: ManagerOperatorContinuityReadModel?
}

private enum ManagerLifecycleTransitionError: Error, LocalizedError, Sendable {
    case busy(String)

    var errorDescription: String? {
        switch self {
        case .busy(let operation):
            "Manager lifecycle transition is busy; \(operation) was not started"
        }
    }
}

enum ManagerProjectRelinkCheckpoint: Sendable {
    case targetCaptured
    case identityStaged
    case controlPlaneCommitted
    case aliasPublished
    case controlPlaneActivated
}

enum ManagerProjectRelinkInterruption: Error, Sendable {
    case simulatedProcessExit(ManagerProjectRelinkCheckpoint)
}

enum ManagerProjectRegistrationCheckpoint: Sendable {
    case targetCaptured
    case identityIntentStaged
    case controlPlaneAccepted
    case identityPublished
    case controlPlaneActivated
}

enum ManagerProjectRegistrationInterruption: Error, Sendable {
    case simulatedProcessExit(ManagerProjectRegistrationCheckpoint)
}

private struct ManagerProjectRegistrationReconciliationError: Error, LocalizedError, Sendable {
    let code: String
    let message: String

    var errorDescription: String? {
        "Project registration requires exact reconciliation (\(code)): \(message)"
    }
}

/// Supervisor that keeps the dashboard control surface available.
/// Mutable process state lives in `ManagerRuntime` (SRP).
public final class ManagerNode: ManagerControlling, @unchecked Sendable {
    public typealias ManagedAutonomyFactory = @Sendable (ForgeApp) throws -> ManagedAutonomyRuntime
    public static let nativeSessionHostAdapterID = "forge.native-session-host"
    public static let maximumProviderAdapterIDBytes = 128
    static let lifecycleTransitionWaitTimeoutSeconds: TimeInterval = 1
    static let listenerReplacementPauseSeconds: TimeInterval = 0.2
    static let maximumProviderProbeTimeoutSeconds: TimeInterval = 20
    static let minimumProviderProbeTimeoutSeconds: TimeInterval = 0.05
    private static let presencePruneInterval: TimeInterval = 60
    private static let presenceMaxAge: TimeInterval = 120
    private static let operatorRedactor = ProjectMemoryRedactor()

    public let app: ForgeApp
    private let lock = NSLock()
    /// Serializes listener/config transitions without holding `lock` across
    /// Network.framework callbacks. Acquisition is always deadline-bounded.
    private let lifecycleTransitionLock = NSLock()
    private let runtime = ManagerRuntime()
    private let managedAutonomyFactory: ManagedAutonomyFactory
    private let hostAdapterRegistry: HostAdapterRegistry
    private let providerProbeTimeoutSeconds: TimeInterval
    private let generationResetCheckpoint: @Sendable (ProjectID, ProjectGeneration) throws -> Void
    private let projectRelinkCheckpoint: @Sendable (ManagerProjectRelinkCheckpoint) throws -> Void
    private let projectRegistrationCheckpoint: @Sendable (
        ManagerProjectRegistrationCheckpoint
    ) throws -> Void
    private var activeProviderProbeID: UUID?
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
            hostAdapterRegistry: .shared,
            generationResetCheckpoint: { _, _ in },
            projectRelinkCheckpoint: { _ in },
            projectRegistrationCheckpoint: { _ in }
        )
    }

    public convenience init(
        app: ForgeApp,
        hostAdapterRegistry: HostAdapterRegistry
    ) {
        self.init(
            app: app,
            managedAutonomyFactory: {
                try ManagedAutonomyRuntime(app: $0, registry: hostAdapterRegistry)
            },
            hostAdapterRegistry: hostAdapterRegistry,
            generationResetCheckpoint: { _, _ in },
            projectRelinkCheckpoint: { _ in },
            projectRegistrationCheckpoint: { _ in }
        )
    }

    convenience init(
        app: ForgeApp,
        hostAdapterRegistry: HostAdapterRegistry,
        providerProbeTimeoutSeconds: TimeInterval
    ) {
        self.init(
            app: app,
            managedAutonomyFactory: {
                try ManagedAutonomyRuntime(app: $0, registry: hostAdapterRegistry)
            },
            hostAdapterRegistry: hostAdapterRegistry,
            providerProbeTimeoutSeconds: providerProbeTimeoutSeconds,
            generationResetCheckpoint: { _, _ in },
            projectRelinkCheckpoint: { _ in },
            projectRegistrationCheckpoint: { _ in }
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
            hostAdapterRegistry: .shared,
            generationResetCheckpoint: generationResetCheckpoint,
            projectRelinkCheckpoint: { _ in },
            projectRegistrationCheckpoint: { _ in }
        )
    }

    convenience init(
        app: ForgeApp,
        projectRelinkCheckpoint: @escaping @Sendable (
            ManagerProjectRelinkCheckpoint
        ) throws -> Void
    ) {
        self.init(
            app: app,
            managedAutonomyFactory: { try ManagedAutonomyRuntime(app: $0) },
            hostAdapterRegistry: .shared,
            generationResetCheckpoint: { _, _ in },
            projectRelinkCheckpoint: projectRelinkCheckpoint,
            projectRegistrationCheckpoint: { _ in }
        )
    }

    convenience init(
        app: ForgeApp,
        projectRegistrationCheckpoint: @escaping @Sendable (
            ManagerProjectRegistrationCheckpoint
        ) throws -> Void
    ) {
        self.init(
            app: app,
            managedAutonomyFactory: { try ManagedAutonomyRuntime(app: $0) },
            hostAdapterRegistry: .shared,
            generationResetCheckpoint: { _, _ in },
            projectRelinkCheckpoint: { _ in },
            projectRegistrationCheckpoint: projectRegistrationCheckpoint
        )
    }

    private init(
        app: ForgeApp,
        managedAutonomyFactory: @escaping ManagedAutonomyFactory,
        hostAdapterRegistry: HostAdapterRegistry,
        providerProbeTimeoutSeconds: TimeInterval = ManagerNode.maximumProviderProbeTimeoutSeconds,
        generationResetCheckpoint: @escaping @Sendable (
            ProjectID,
            ProjectGeneration
        ) throws -> Void,
        projectRelinkCheckpoint: @escaping @Sendable (
            ManagerProjectRelinkCheckpoint
        ) throws -> Void,
        projectRegistrationCheckpoint: @escaping @Sendable (
            ManagerProjectRegistrationCheckpoint
        ) throws -> Void
    ) {
        self.app = app
        self.managedAutonomyFactory = managedAutonomyFactory
        self.hostAdapterRegistry = hostAdapterRegistry
        self.providerProbeTimeoutSeconds = min(
            max(providerProbeTimeoutSeconds, Self.minimumProviderProbeTimeoutSeconds),
            Self.maximumProviderProbeTimeoutSeconds
        )
        self.generationResetCheckpoint = generationResetCheckpoint
        self.projectRelinkCheckpoint = projectRelinkCheckpoint
        self.projectRegistrationCheckpoint = projectRegistrationCheckpoint
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
            var evidenceByOperation: [UUID: ManagerOperatorContinuityEvidence] = [:]
            evidenceByOperation.reserveCapacity(commandRecords.count)
            for command in commandRecords {
                do {
                    let memory = try app.projectMemory.repositoryForProject(
                        command.projectID.description
                    )
                    guard let operation = try memory.continuityOperationV2(
                        id: command.operationID.uuidString.lowercased()
                    ), operation.quarantineState == nil else {
                        continue
                    }
                    evidenceByOperation[command.operationID] = try Self.operatorContinuityEvidence(
                        operation
                    )
                } catch ProjectMemoryError.projectNotFound {
                    // Pre-V2 or independently restored control-plane commands did not
                    // necessarily initialize project memory. Preserve their prior
                    // read-only snapshot shape while withholding absent V2 evidence.
                    continue
                }
            }
            let continuity = try await control.operatorContinuityReadModels(
                commands: commandRecords,
                evidenceByOperation: evidenceByOperation
            )
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
        let projectRows = try persisted.projects.map { project in
            Self.operatorProject(
                project,
                bindings: persisted.bindings[project.projectID] ?? [],
                resetReceipt: persisted.resetReceipts[project.projectID],
                continuity: continuityByProject[project.projectID],
                pendingTransition: try operatorProjectTransition(project),
                paths: app.paths
            )
        }
        let projectedProjectIDs = Set(projectRows.map { $0.projectID.lowercased() })
        let pendingProjectRegistrations = try app.projectMemory.identities
            .pendingRegistrations(
                limit: limit,
                excludingProjectIDs: projectedProjectIDs
            )
            .map { pending in
                ManagerOperatorPendingProjectRegistration(
                    projectID: pending.preparation.descriptor.id,
                    state: "reconciliation_required",
                    requestPath: pending.requestedPath,
                    requestedDisplayName: pending.requestedDisplayName,
                    repositoryIdentityAssertion: pending.repositoryIdentityAssertion,
                    operationID: pending.preparation.operationID,
                    createdAt: pending.createdAt
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
        lock.lock()
        let providerProbe = runtime.providerProbeState
        lock.unlock()
        return ManagerOperatorSnapshot(
            generatedAt: ISO8601.string(from: app.clock.now()),
            limit: limit,
            projects: projectRows,
            pendingProjectRegistrations: pendingProjectRegistrations,
            runs: runRows,
            continuityOperations: continuityRows,
            runtimeJobs: jobRows,
            provider: Self.operatorProvider(from: persisted.runs, probe: providerProbe),
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
        try withLifecycleTransition(operation: "start") {
            try startServiceSerialized()
        }
    }

    private func startServiceSerialized() throws -> ManagerStatus {
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
            try bindAndStartDashboard(allowingCompletedResponses: true)
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
        try withLifecycleTransition(operation: "stop") {
            stopServiceSerialized()
        }
    }

    private func stopServiceSerialized() -> ManagerStatus {
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
        try withLifecycleTransition(operation: "restart") {
            try restartServiceSerialized(reloadConfiguration: true)
        }
    }

    private func restartServiceSerialized(reloadConfiguration: Bool) throws -> ManagerStatus {
        lock.lock()
        let count = runtime.beginRestart()
        lock.unlock()

        tearDownDashboard(allowingCompletedResponses: true)
        Thread.sleep(forTimeInterval: Self.listenerReplacementPauseSeconds)
        do {
            try bindAndStartDashboard(reloadConfiguration: reloadConfiguration)
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
        try withLifecycleTransition(operation: "settings") {
            try updateSettingsDictionarySerialized(patch, apply: apply)
        }
    }

    private func updateSettingsDictionarySerialized(
        _ patch: [String: Any],
        apply: Bool
    ) throws -> [String: Any] {
        let before = app.config.model.dashboard
        let normalized = ManagerSettingsNormalizer.normalize(patch)
        _ = try app.config.update(normalized, save: true)
        let after = app.config.model.dashboard
        let bindChanged = before.host != after.host || before.port != after.port

        lock.lock()
        let want = runtime.desiredRunning
        lock.unlock()

        if apply && bindChanged {
            do {
                try rebindDashboardForSettings(desiredRunning: want)
                restartWatchdog()
            } catch {
                let bindFailure = error
                try restoreDashboardAfterFailedSettingsBind(
                    previousDashboard: before,
                    desiredRunning: want,
                    bindFailure: bindFailure
                )
                throw bindFailure
            }
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
        let result = try registerProjectResult(
            path: path,
            displayName: displayName,
            repositoryIdentity: repositoryIdentity
        )
        guard result.registrationState == .committed,
              let projectID = result.projectID,
              let projectUUID = UUID(uuidString: projectID) else {
            throw ManagerProjectRegistrationReconciliationError(
                code: result.code ?? "project_registration_reconciliation_required",
                message: result.message ?? "Registration outcome is not yet confirmed"
            )
        }
        return try projectStatus(projectID: ProjectID(projectUUID))
    }

    /// Runs the manager-owned registration transition and reports an explicit
    /// pending state for failures after control-plane acceptance. Callers must
    /// replay the exact retained request; they must not infer that the project
    /// committed merely because the response was ambiguous.
    public func registerProjectResult(
        path: String,
        displayName: String? = nil,
        repositoryIdentity: String? = nil
    ) throws -> ManagerProjectRegistrationResult {
        guard !path.isEmpty,
              path.utf8.count <= ManagerRoutes.maximumProjectRegistrationPathBytes,
              (path as NSString).isAbsolutePath,
              displayName.map({ $0.utf8.count <= 512 }) ?? true,
              repositoryIdentity.map({ $0.utf8.count <= 2_048 }) ?? true else {
            throw ProjectMemoryError.invalidRequest(
                "project registration request is outside its path or identity bounds"
            )
        }
        let target = try app.projectMemory.identities.discoverTarget(
            path: path,
            repositoryIdentityAssertion: repositoryIdentity
        )
        let preparation = try app.projectContexts.prepareControlledRegistration(
            identities: app.projectMemory.identities,
            target: target,
            requestedProjectID: nil,
            displayName: displayName
        )
        // This checkpoint represents the complete immutable preflight: both the
        // filesystem target and its matching control-plane tuple are captured.
        // Production behavior is unchanged because the default observer is a
        // no-op; tests use the boundary to force exact concurrent contenders.
        try projectRegistrationCheckpoint(.targetCaptured)
        guard let projectUUID = UUID(uuidString: preparation.descriptor.id) else {
            throw ProjectContextError.invalidIdentifier("registered project identifier")
        }
        let recovery = SecureFilesystemRecoveryLedger(paths: app.paths)
        do {
            return try recovery.withRetainedAuthorityFence(
                projectID: ProjectID(projectUUID),
                generation: preparation.expectedControlGeneration ?? .initial
            ) { _ in
                // Stage while holding the same bounded transition fence used
                // for control and alias mutation. Exact concurrent callers are
                // serialized before intent ownership can be transferred or
                // removed, so one caller cannot erase another's recovery state.
                let stagedRegistration = try app.projectMemory.identities
                    .stageRegistrationIntent(
                        preparation,
                        requestedPath: path,
                        requestedDisplayName: displayName,
                        repositoryIdentityAssertion: repositoryIdentity
                    )
                let createdIntent = stagedRegistration.created
                let retainedRegistration = stagedRegistration.pending
                var accepted: ProjectControlRecord?
                do {
                    try projectRegistrationCheckpoint(.identityIntentStaged)
                    let effectivePreparation = try app.projectContexts.prepareControlledRegistration(
                        identities: app.projectMemory.identities,
                        target: target,
                        requestedProjectID: nil,
                        displayName: displayName
                    )
                    guard effectivePreparation.operationID
                            == retainedRegistration.preparation.operationID,
                          effectivePreparation.descriptor.id.caseInsensitiveCompare(
                            retainedRegistration.preparation.descriptor.id
                          ) == .orderedSame else {
                        throw ProjectMemoryError.conflict(
                            "project registration changed while waiting for transition authority"
                        )
                    }
                    let existingControl = try app.projectContexts.project(ProjectID(projectUUID))
                    let alreadyActive = effectivePreparation.expectedControlLifecycleState == .active
                        && effectivePreparation.expectedControlRepositoryIdentity
                            == target.repositoryIdentity
                        && effectivePreparation.descriptor.aliases.contains(
                            target.canonicalRoot.path
                        )
                        && existingControl?.displayName
                            == effectivePreparation.descriptor.displayName
                    try app.projectContexts.validateControlledRegistration(
                        effectivePreparation,
                        identities: app.projectMemory.identities,
                        requestedProjectID: nil,
                        displayName: displayName
                    )
                    let control = try app.projectContexts.registerProject(
                        preparation: effectivePreparation
                    )
                    accepted = control
                    try projectRegistrationCheckpoint(.controlPlaneAccepted)
                    if control.lifecycleState == .maintenance {
                        try app.projectContexts.validateRegistrationPublicationAuthority(
                            preparation: effectivePreparation
                        )
                    }
                    let published = try app.projectMemory.identities.commitRegistration(
                        effectivePreparation
                    )
                    try projectRegistrationCheckpoint(.identityPublished)
                    let activated = try app.projectContexts.finalizeRegistration(
                        preparation: effectivePreparation
                    )
                    guard control.projectID == activated.projectID,
                          control.generation == activated.generation,
                          published.id.caseInsensitiveCompare(
                        activated.projectID.description
                    ) == .orderedSame,
                          published.repositoryIdentity == activated.repositoryFingerprint,
                          published.aliases.contains(activated.canonicalRoot.path) else {
                        throw ProjectMemoryError.integrityFailure(
                            "registered project identity did not match control-plane acceptance"
                        )
                    }
                    let verified = try app.projectContexts.finalizeRegistration(
                        preparation: retainedRegistration.preparation
                    )
                    guard verified == activated else {
                        throw ProjectMemoryError.integrityFailure(
                            "registered project publication authority did not match activation"
                        )
                    }
                    try projectRegistrationCheckpoint(.controlPlaneActivated)
                    do {
                        try app.projectMemory.identities.completeRegistrationIntent(
                            retainedRegistration.preparation
                        )
                    } catch {
                        app.diagnostics.error(
                            "manager_project_registration_intent_cleanup_pending",
                            [
                                "project_id": activated.projectID.description,
                                "operation_id": retainedRegistration.preparation.operationID,
                                "error": error.localizedDescription,
                            ],
                            category: .manager
                        )
                    }
                    app.diagnostics.info(
                        "manager_project_registered",
                        [
                            "project_id": activated.projectID.description,
                            "project_generation": "\(activated.generation.rawValue)",
                            "reconciled": alreadyActive
                                || effectivePreparation.expectedControlLifecycleState == .maintenance
                                ? "true" : "false",
                        ],
                        category: .manager
                    )
                    return ManagerProjectRegistrationResult(
                        registrationState: .committed,
                        projectID: activated.projectID.description,
                        displayName: activated.displayName,
                        canonicalRoot: activated.canonicalRoot.path,
                        projectGeneration: activated.generation.rawValue,
                        lifecycleState: activated.lifecycleState.rawValue,
                        requestPath: path,
                        requestedDisplayName: displayName,
                        repositoryIdentityAssertion: repositoryIdentity,
                        reconciled: alreadyActive
                            || effectivePreparation.expectedControlLifecycleState == .maintenance
                    )
                } catch let interruption as ManagerProjectRegistrationInterruption {
                    // A process termination does not run compensating cleanup.
                    // The durable request remains available to the restarted manager.
                    throw interruption
                } catch {
                    guard let accepted else {
                        if createdIntent {
                            try? app.projectMemory.identities.abortRegistrationIntent(preparation)
                        }
                        throw error
                    }
                    let code = Self.projectRegistrationErrorCode(error)
                    app.diagnostics.error(
                        "manager_project_registration_reconciliation_pending",
                        [
                            "project_id": accepted.projectID.description,
                            "project_generation": "\(accepted.generation.rawValue)",
                            "operation_id": preparation.operationID,
                            "code": code,
                            "error": error.localizedDescription,
                        ],
                        category: .manager
                    )
                    return ManagerProjectRegistrationResult(
                        registrationState: .reconciliationRequired,
                        projectID: accepted.projectID.description,
                        displayName: accepted.displayName,
                        canonicalRoot: accepted.canonicalRoot.path,
                        projectGeneration: accepted.generation.rawValue,
                        lifecycleState: accepted.lifecycleState.rawValue,
                        requestPath: path,
                        requestedDisplayName: displayName,
                        repositoryIdentityAssertion: repositoryIdentity,
                        reconciled: false,
                        code: code,
                        message: error.localizedDescription
                    )
                }
            }
        } catch SecureFilesystemRecoveryLedgerError.retainedAuthority {
            throw ProjectContextError.retainedFilesystemRecovery(
                ProjectID(projectUUID)
            )
        } catch is SecureFilesystemRecoveryLedgerError {
            throw ProjectContextError.databaseBusy
        }
    }

    /// Returns the same bounded project projection used by the operator
    /// snapshot, but resolves one exact project rather than searching the
    /// snapshot's globally limited project and continuity feeds.
    public func operatorProjectStatus(
        projectID: ProjectID
    ) throws -> ManagerOperatorProject {
        let persisted = try operatorProjectPersistence(projectID: projectID)
        return Self.operatorProject(
            persisted.project,
            bindings: persisted.bindings,
            resetReceipt: persisted.resetReceipt,
            continuity: persisted.continuity,
            pendingTransition: try operatorProjectTransition(persisted.project),
            paths: app.paths
        )
    }

    /// Preserves the historical status fields while additively publishing the
    /// complete native operator project contract.
    public func projectStatus(projectID: ProjectID) throws -> [String: Any] {
        let persisted = try operatorProjectPersistence(projectID: projectID)
        let projection = Self.operatorProject(
            persisted.project,
            bindings: persisted.bindings,
            resetReceipt: persisted.resetReceipt,
            continuity: persisted.continuity,
            pendingTransition: try operatorProjectTransition(persisted.project),
            paths: app.paths
        )
        var response = Self.projectDictionary(persisted.project)
        response.merge(
            try projection.asDictionary(),
            uniquingKeysWith: { _, projected in projected }
        )
        return response
    }

    private func operatorProjectPersistence(
        projectID: ProjectID
    ) throws -> ManagerOperatorProjectPersistenceSnapshot {
        let app = self.app
        return try Self.waitForAsync(timeoutSeconds: 10) {
            let control = app.projectContexts.repository
            guard let project = try await control.project(projectID) else {
                throw ProjectContextError.projectNotFound(projectID)
            }
            let bindings = try await control.operatorBindings(projectIDs: [projectID])
            let resetReceipts = try await control.operatorLatestResetReceipts(
                projectIDs: [projectID]
            )
            let command = try await control.operatorLatestContinuityCommand(
                projectID: projectID
            )
            var continuity: ManagerOperatorContinuityReadModel?
            if let command {
                var evidenceByOperation: [UUID: ManagerOperatorContinuityEvidence] = [:]
                do {
                    let memory = try app.projectMemory.repositoryForProject(
                        command.projectID.description
                    )
                    if let operation = try memory.continuityOperationV2(
                        id: command.operationID.uuidString.lowercased()
                    ), operation.quarantineState == nil {
                        evidenceByOperation[command.operationID] = try Self
                            .operatorContinuityEvidence(operation)
                    }
                } catch ProjectMemoryError.projectNotFound {
                    // Preserve the snapshot contract for pre-V2 commands whose
                    // project memory has not been initialized.
                }
                continuity = try await control.operatorContinuityReadModels(
                    commands: [command],
                    evidenceByOperation: evidenceByOperation
                ).first
            }
            return ManagerOperatorProjectPersistenceSnapshot(
                project: project,
                bindings: bindings[projectID] ?? [],
                resetReceipt: resetReceipts[projectID],
                continuity: continuity
            )
        }
    }

    /// Relinks one exact project generation to a user-selected checkout after
    /// independently inferring and matching its Git repository identity. A
    /// durable non-authoritative stage precedes the control-plane compare-and-set;
    /// the project-memory alias is published only after that exact generation
    /// transition commits. An exact retry reconciles either crash boundary.
    @discardableResult
    public func relinkProject(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        path: String
    ) throws -> ManagerProjectRelinkResult {
        guard expectedGeneration.rawValue > 0,
              expectedGeneration.rawValue < UInt64(Int64.max) else {
            throw ProjectContextError.invalidGeneration(expectedGeneration.rawValue)
        }
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              path.utf8.count <= ManagerRoutes.maximumProjectRelinkPathBytes,
              (path as NSString).isAbsolutePath else {
            throw ProjectMemoryError.invalidRequest(
                "project relink path must name one bounded existing directory"
            )
        }
        let target = try app.projectMemory.identities.discoverTarget(path: path)
        try projectRelinkCheckpoint(.targetCaptured)
        let requestedRoot = target.canonicalRoot

        let filesystemRecovery = SecureFilesystemRecoveryLedger(paths: app.paths)
        do {
            return try filesystemRecovery.withRetainedAuthorityFence(
                projectID: projectID,
                generation: expectedGeneration
            ) { assertNoRetainedAuthority in
                try assertNoRetainedAuthority()
                guard try app.projectMemory.identities.pendingRegistration(
                    projectID: projectID.description
                ) == nil else {
                    throw ProjectContextError.projectTransitionConflict(projectID)
                }
                guard let preflight = try app.projectContexts.project(projectID) else {
                    throw ProjectContextError.projectNotFound(projectID)
                }
                guard let repositoryIdentity = preflight.repositoryFingerprint else {
                    throw ProjectContextError.projectRepositoryIdentityMismatch(projectID)
                }
                let isExactRetry = preflight.generation.rawValue
                        == expectedGeneration.rawValue + 1
                    && preflight.canonicalRoot == requestedRoot
                    && (preflight.lifecycleState == .maintenance
                        || preflight.lifecycleState == .active)
                guard preflight.lifecycleState == .active || isExactRetry else {
                    throw ProjectContextError.projectNotActive(preflight.lifecycleState)
                }
                guard preflight.generation == expectedGeneration || isExactRetry else {
                    throw ProjectContextError.staleProjectGeneration(
                        expected: expectedGeneration,
                        actual: preflight.generation
                    )
                }
                let pendingIdentity = try app.projectMemory.identities.pendingRelink(
                    projectID: projectID.description
                )
                var committedTransitionValidated = false
                if let pendingIdentity {
                    let pending = pendingIdentity.preparation
                    let next = pending.expectedGeneration.rawValue.addingReportingOverflow(1)
                    if !next.overflow,
                       preflight.generation.rawValue == next.partialValue,
                       preflight.canonicalRoot == pending.canonicalRoot,
                       (preflight.lifecycleState == .maintenance
                            || preflight.lifecycleState == .active) {
                        if preflight.lifecycleState == .maintenance {
                            try app.projectContexts.validateRelinkPublicationAuthority(
                                projectID: projectID,
                                priorGeneration: pending.expectedGeneration,
                                target: pending.target,
                                transitionOperationID: pending.operationID
                            )
                        } else {
                            _ = try app.projectContexts.finalizeRelink(
                                projectID: projectID,
                                priorGeneration: pending.expectedGeneration,
                                target: pending.target,
                                transitionOperationID: pending.operationID
                            )
                        }
                        committedTransitionValidated = true
                    }
                }
                let recovered = try app.projectMemory.identities.reconcilePendingRelink(
                    projectID: projectID.description,
                    controlPlaneGeneration: preflight.generation,
                    controlPlaneCanonicalRoot: preflight.canonicalRoot,
                    controlPlaneRepositoryIdentity: repositoryIdentity,
                    committedTransitionValidated: committedTransitionValidated
                )
                switch recovered {
                case .none:
                    break
                case .abortedUncommitted(let operationID):
                    app.diagnostics.info(
                        "manager_project_relink_stale_stage_aborted",
                        [
                            "project_id": projectID.description,
                            "control_generation": "\(preflight.generation.rawValue)",
                            "operation_id": operationID,
                        ],
                        category: .manager
                    )
                case .publishedCommittedAlias(let operationID):
                    app.diagnostics.info(
                        "manager_project_relink_stale_stage_reconciled",
                        [
                            "project_id": projectID.description,
                            "control_generation": "\(preflight.generation.rawValue)",
                            "operation_id": operationID,
                        ],
                        category: .manager
                    )
                }
                let prepared: ProjectRelinkIdentityPreparation
                do {
                    prepared = try app.projectMemory.identities.prepareRelink(
                        target: target,
                        projectID: projectID.description,
                        expectedGeneration: expectedGeneration,
                        expectedRepositoryIdentity: repositoryIdentity
                    )
                } catch ProjectMemoryError.projectScopeMismatch {
                    throw ProjectContextError.projectRepositoryIdentityMismatch(projectID)
                } catch ProjectMemoryError.projectNotFound {
                    throw ProjectContextError.projectNotFound(projectID)
                }
                app.diagnostics.info(
                    "manager_project_relink_identity_staged",
                    [
                        "project_id": projectID.description,
                        "expected_generation": "\(expectedGeneration.rawValue)",
                        "operation_id": prepared.operationID,
                        "canonical_root_sha256": JSONSupport.sha256Hex(
                            prepared.canonicalRoot.path
                        ),
                    ],
                    category: .manager
                )

                var controlPlaneCommitted = isExactRetry
                do {
                    try projectRelinkCheckpoint(.identityStaged)
                    // Recheck retained authority and the exact control-plane tuple
                    // while the recovery-ledger fence remains held.
                    try assertNoRetainedAuthority()
                    guard let current = try app.projectContexts.project(projectID) else {
                        throw ProjectContextError.projectNotFound(projectID)
                    }
                    guard current.repositoryFingerprint == prepared.repositoryIdentity else {
                        throw ProjectContextError.projectRepositoryIdentityMismatch(projectID)
                    }

                    if current.generation.rawValue == expectedGeneration.rawValue + 1,
                       current.canonicalRoot == prepared.canonicalRoot,
                       (current.lifecycleState == .maintenance
                            || current.lifecycleState == .active) {
                        controlPlaneCommitted = true
                        if current.lifecycleState == .maintenance {
                            try app.projectContexts.validateRelinkPublicationAuthority(
                                projectID: projectID,
                                priorGeneration: expectedGeneration,
                                target: prepared.target,
                                transitionOperationID: prepared.operationID
                            )
                        }
                        _ = try app.projectMemory.identities.commitRelink(prepared)
                        try projectRelinkCheckpoint(.aliasPublished)
                        let activated = try app.projectContexts.finalizeRelink(
                            projectID: projectID,
                            priorGeneration: expectedGeneration,
                            target: prepared.target,
                            transitionOperationID: prepared.operationID
                        )
                        let verified = try app.projectContexts.finalizeRelink(
                            projectID: projectID,
                            priorGeneration: expectedGeneration,
                            target: prepared.target,
                            transitionOperationID: prepared.operationID
                        )
                        guard verified == activated else {
                            throw ProjectMemoryError.integrityFailure(
                                "project relink publication authority did not match activation"
                            )
                        }
                        try projectRelinkCheckpoint(.controlPlaneActivated)
                        try app.projectMemory.identities.completeRelinkIntent(prepared)
                        app.diagnostics.info(
                            "manager_project_relink_reconciled",
                            [
                                "project_id": projectID.description,
                                "prior_generation": "\(expectedGeneration.rawValue)",
                                "new_generation": "\(activated.generation.rawValue)",
                                "operation_id": prepared.operationID,
                            ],
                            category: .manager
                        )
                        return ManagerProjectRelinkResult(
                            projectID: projectID.description,
                            canonicalRoot: activated.canonicalRoot.path,
                            priorGeneration: expectedGeneration.rawValue,
                            newGeneration: activated.generation.rawValue,
                            invalidatedBindingCount: 0,
                            completedAt: activated.updatedAt,
                            reconciled: true
                        )
                    }
                    guard current.lifecycleState == .active else {
                        throw ProjectContextError.projectNotActive(current.lifecycleState)
                    }
                    guard current.generation == expectedGeneration else {
                        throw ProjectContextError.staleProjectGeneration(
                            expected: expectedGeneration,
                            actual: current.generation
                        )
                    }

                    let receipt = try app.projectContexts.relinkProject(
                        projectID: projectID,
                        expectedGeneration: expectedGeneration,
                        target: prepared.target,
                        transitionOperationID: prepared.operationID
                    )
                    controlPlaneCommitted = true
                    app.diagnostics.info(
                        "manager_project_relink_control_plane_committed_alias_pending",
                        [
                            "project_id": projectID.description,
                            "prior_generation": "\(receipt.priorGeneration.rawValue)",
                            "new_generation": "\(receipt.newGeneration.rawValue)",
                            "operation_id": prepared.operationID,
                        ],
                        category: .manager
                    )
                    try projectRelinkCheckpoint(.controlPlaneCommitted)
                    try app.projectContexts.validateRelinkPublicationAuthority(
                        projectID: projectID,
                        priorGeneration: expectedGeneration,
                        target: prepared.target,
                        transitionOperationID: prepared.operationID
                    )
                    _ = try app.projectMemory.identities.commitRelink(prepared)
                    try projectRelinkCheckpoint(.aliasPublished)
                    let activated = try app.projectContexts.finalizeRelink(
                        projectID: projectID,
                        priorGeneration: expectedGeneration,
                        target: prepared.target,
                        transitionOperationID: prepared.operationID
                    )
                    let verified = try app.projectContexts.finalizeRelink(
                        projectID: projectID,
                        priorGeneration: expectedGeneration,
                        target: prepared.target,
                        transitionOperationID: prepared.operationID
                    )
                    guard verified == activated else {
                        throw ProjectMemoryError.integrityFailure(
                            "project relink publication authority did not match activation"
                        )
                    }
                    try projectRelinkCheckpoint(.controlPlaneActivated)
                    try app.projectMemory.identities.completeRelinkIntent(prepared)
                    app.diagnostics.info(
                        "manager_project_relinked",
                        [
                            "project_id": projectID.description,
                            "prior_generation": "\(receipt.priorGeneration.rawValue)",
                            "new_generation": "\(receipt.newGeneration.rawValue)",
                            "canonical_root_sha256": JSONSupport.sha256Hex(
                                receipt.newCanonicalRoot.path
                            ),
                        ],
                        category: .manager
                    )
                    return ManagerProjectRelinkResult(
                        projectID: projectID.description,
                        canonicalRoot: activated.canonicalRoot.path,
                        priorGeneration: receipt.priorGeneration.rawValue,
                        newGeneration: activated.generation.rawValue,
                        invalidatedBindingCount: receipt.invalidatedBindingCount,
                        completedAt: activated.updatedAt,
                        reconciled: false
                    )
                } catch let interruption as ManagerProjectRelinkInterruption {
                    // Test-only process-death model: product process termination
                    // does not execute cleanup at either durable boundary.
                    throw interruption
                } catch {
                    guard !controlPlaneCommitted else {
                        app.diagnostics.error(
                            "manager_project_relink_alias_publication_pending",
                            [
                                "project_id": projectID.description,
                                "expected_generation": "\(expectedGeneration.rawValue)",
                                "operation_id": prepared.operationID,
                                "error": error.localizedDescription,
                            ],
                            category: .manager
                        )
                        throw error
                    }
                    do {
                        try app.projectMemory.identities.abortRelink(prepared)
                        app.diagnostics.info(
                            "manager_project_relink_stage_cancelled",
                            [
                                "project_id": projectID.description,
                                "expected_generation": "\(expectedGeneration.rawValue)",
                                "operation_id": prepared.operationID,
                            ],
                            category: .manager
                        )
                    } catch {
                        throw ProjectMemoryError.integrityFailure(
                            "project relink was rejected and its staged identity could not be cancelled"
                        )
                    }
                    throw error
                }
            }
        } catch SecureFilesystemRecoveryLedgerError.retainedAuthority {
            throw ProjectContextError.retainedFilesystemRecovery(projectID)
        } catch is SecureFilesystemRecoveryLedgerError {
            throw ProjectContextError.databaseBusy
        }
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
        let authorizedRoot = try authorizedProjectRoot(project.canonicalRoot)
        let scope = ToolAuthorizationScope(
            canonicalRoots: [authorizedRoot],
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
                try assertNoRetainedAuthority()
                guard try app.projectMemory.identities.pendingRegistration(
                    projectID: projectID.description
                ) == nil else {
                    throw ProjectContextError.projectTransitionConflict(projectID)
                }
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

    private static func projectRegistrationErrorCode(_ error: Error) -> String {
        if let error = error as? ProjectContextError { return error.code }
        if let error = error as? ProjectMemoryError { return error.code }
        return "project_registration_outcome_ambiguous"
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

    // MARK: - Runtime job controls

    /// Cancels one durable runtime job using only its manager-owned stored binding.
    /// Project, generation, run, and authorization scope are never accepted from
    /// the operator caller and therefore cannot be substituted at this boundary.
    @discardableResult
    public func cancelRuntimeJob(jobID: UUID) throws -> ManagerOperatorRuntimeJob {
        let service = app.runtimeJobs.service
        let record = try Self.waitForAsync(timeoutSeconds: 15) {
            try await service.cancelStoredJob(jobID: jobID)
        }
        return Self.operatorRuntimeJob(record)
    }

    // MARK: - Managed provider controls

    /// Probes the statically registered native session-host provider. The caller
    /// selects only an exact registered adapter identifier and probe mode; storage,
    /// configuration, credentials, and the provider instance remain manager-owned.
    @discardableResult
    public func probeProvider(
        adapterID: String,
        mode: ManagerProviderProbeMode
    ) throws -> ManagerOperatorProvider {
        try Self.validateProviderAdapterID(adapterID)
        guard let manifest = hostAdapterRegistry.manifests.first(where: {
            $0.identifier == adapterID
        }) else {
            throw ManagerProviderProbeError.adapterNotRegistered
        }

        let startedAt = ISO8601.string(from: app.clock.now())
        let probeID = UUID()
        lock.lock()
        guard !runtime.providerProbeInProgress else {
            lock.unlock()
            throw ManagerProviderProbeError.probeInProgress
        }
        runtime.providerProbeInProgress = true
        activeProviderProbeID = probeID
        runtime.providerProbeState = ManagerProviderProbeState(
            adapterID: adapterID,
            mode: mode,
            health: "probing",
            completedAt: nil,
            capabilities: nil,
            lifecycleManagementEnabled: nil,
            errorSummary: nil
        )
        lock.unlock()

        var timedOutCompletion: ManagerAsyncCompletion?
        do {
            let storage = try providerStorageDirectory(adapterID: adapterID)
            let provider: any ManagedModelProvider
            do {
                guard let resolved = try hostAdapterRegistry.managedProvider(
                    identifier: adapterID,
                    storageDirectory: storage
                ) else {
                    throw ManagerProviderProbeError.managedProviderUnavailable
                }
                provider = resolved
            } catch let error as ManagerProviderProbeError {
                throw error
            } catch {
                throw ManagerProviderProbeError.connectionFailed(
                    Self.safeProviderProbeError(error)
                )
            }

            let capabilities: ProviderCapabilities
            do {
                capabilities = try Self.waitForAsync(timeoutSeconds: providerProbeTimeoutSeconds) {
                    try await provider.probe()
                }
            } catch let error as ManagerAsyncDeadlineError {
                timedOutCompletion = error.completion
                throw ManagerProviderProbeError.connectionFailed(
                    Self.safeProviderProbeError(error)
                )
            } catch {
                throw ManagerProviderProbeError.connectionFailed(
                    Self.safeProviderProbeError(error)
                )
            }
            guard capabilities.providerID == provider.providerID else {
                throw ManagerProviderProbeError.connectionFailed(
                    "the managed provider returned a mismatched provider identity"
                )
            }

            if mode == .contract {
                try Self.validateProviderContract(
                    capabilities: capabilities,
                    manifest: manifest
                )
                let lookupKey = "operator-contract-probe-\(UUID().uuidString.lowercased())"
                do {
                    let unexpected = try Self.waitForAsync(
                        timeoutSeconds: min(10, providerProbeTimeoutSeconds)
                    ) {
                        try await provider.lookup(idempotencyKey: lookupKey)
                    }
                    guard unexpected == nil else {
                        throw ManagerProviderProbeError.contractUnavailable(
                            "idempotency lookup returned an unrelated receipt"
                        )
                    }
                } catch let error as ManagerProviderProbeError {
                    throw error
                } catch let error as ManagerAsyncDeadlineError {
                    timedOutCompletion = error.completion
                    throw ManagerProviderProbeError.contractUnavailable(
                        "idempotency lookup was not operational"
                    )
                } catch {
                    throw ManagerProviderProbeError.contractUnavailable(
                        "idempotency lookup was not operational"
                    )
                }
            }

            let completed = ISO8601.string(from: app.clock.now())
            let state = ManagerProviderProbeState(
                adapterID: adapterID,
                mode: mode,
                health: mode == .contract ? "contract_valid" : "reachable",
                completedAt: completed,
                capabilities: capabilities,
                lifecycleManagementEnabled: manifest.capabilities.create
                    && manifest.capabilities.bootstrap
                    && manifest.capabilities.resume,
                errorSummary: nil
            )
            finishProviderProbe(state, probeID: probeID)
            app.diagnostics.info(
                "manager_provider_probe_succeeded",
                [
                    "adapter_id": adapterID,
                    "mode": mode.rawValue,
                    "started_at": startedAt,
                    "completed_at": completed,
                ],
                category: .manager
            )
            return Self.operatorProvider(from: [], probe: state)
        } catch {
            let probeError: ManagerProviderProbeError
            if let typed = error as? ManagerProviderProbeError {
                probeError = typed
            } else {
                probeError = .connectionFailed(Self.safeProviderProbeError(error))
            }
            let completed = ISO8601.string(from: app.clock.now())
            let state = ManagerProviderProbeState(
                adapterID: adapterID,
                mode: mode,
                health: mode == .contract ? "contract_invalid" : "unreachable",
                completedAt: completed,
                capabilities: nil,
                lifecycleManagementEnabled: nil,
                errorSummary: Self.operatorSummary(
                    probeError.localizedDescription,
                    maximumCharacters: 512
                )
            )
            finishProviderProbe(
                state,
                probeID: probeID,
                releaseAdmission: timedOutCompletion == nil
            )
            if let timedOutCompletion {
                timedOutCompletion.notifyWhenCompleted { [weak self] in
                    self?.releaseProviderProbeAdmission(probeID: probeID)
                }
            }
            app.diagnostics.warn(
                "manager_provider_probe_failed",
                [
                    "adapter_id": adapterID,
                    "mode": mode.rawValue,
                    "code": probeError.code,
                    "started_at": startedAt,
                    "completed_at": completed,
                ],
                category: .manager
            )
            throw probeError
        }
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
        let authorizedRoot = try authorizedProjectRoot(project.canonicalRoot)
        do {
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            _ = try catalog.definitions(allowedToolNames: allowedTools)
        } catch ToolDefinitionCatalogError.unregisteredAllowedTools(let tools) {
            throw AutonomyError.invalidToolConfiguration(tools)
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
                canonicalRoots: [authorizedRoot],
                allowedTools: allowedTools,
                networkAllowed: networkAllowed,
                maximumInlineOutputBytes: maximumInlineOutputBytes
            )
        )
        let run = try Self.waitForAsync(timeoutSeconds: 15) {
            try await autonomy.createRun(request)
        }
        return try autonomousRunDictionary(run)
    }

    private func authorizedProjectRoot(_ projectRoot: URL) throws -> URL {
        guard let authorized = ManagerSettingsNormalizer.authorizedProjectRoot(
            projectRoot,
            allowedRoots: app.config.model.allowedRoots
        ) else {
            throw ProjectContextError.projectRootNotAuthorized(projectRoot)
        }
        return authorized
    }

    public func autonomousRunStatus(runID: RunID) throws -> [String: Any] {
        lock.lock()
        let autonomy = managedAutonomy
        lock.unlock()
        guard let autonomy else { throw AutonomyError.shutdown }
        let run = try Self.waitForAsync(timeoutSeconds: 10) {
            try await autonomy.run(runID)
        }
        return try autonomousRunDictionary(run)
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
        return try autonomousRunDictionary(run)
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

    private func autonomousRunDictionary(
        _ run: AutonomousRunRecord
    ) throws -> [String: Any] {
        let details = try Self.waitForAsync(timeoutSeconds: 10) {
            try await self.app.projectContexts.repository.operatorRunReadModels(runs: [run])
        }
        guard let detail = details.first, details.count == 1 else {
            throw ProjectContextError.integrityFailure(
                "autonomous run projection could not be read for the manager transport"
            )
        }
        let data = try JSONEncoder().encode(run)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProjectContextError.integrityFailure(
                "autonomous run could not be encoded for the manager transport"
            )
        }
        let projectionData = try JSONEncoder().encode(Self.operatorRun(detail))
        guard let projection = try JSONSerialization.jsonObject(
            with: projectionData
        ) as? [String: Any] else {
            throw ProjectContextError.integrityFailure(
                "operator run could not be encoded for the manager transport"
            )
        }
        for (key, value) in projection {
            object[key] = value
        }
        object["ok"] = true
        return object.compactNSNull()
    }

    private static func operatorProject(
        _ project: ProjectControlRecord,
        bindings: [ProjectContextBinding],
        resetReceipt: ProjectGenerationResetReceipt?,
        continuity: ManagerOperatorContinuityReadModel?,
        pendingTransition: ManagerOperatorProjectTransition?,
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
            pendingTransition: pendingTransition,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt
        )
    }

    private func operatorProjectTransition(
        _ project: ProjectControlRecord
    ) throws -> ManagerOperatorProjectTransition? {
        let registration = try app.projectMemory.identities.pendingRegistration(
            projectID: project.projectID.description
        )
        if let registration {
            guard try !app.projectMemory.identities.hasPendingRelink(
                projectID: project.projectID.description
            ) else {
                throw ProjectMemoryError.integrityFailure(
                    "project has concurrent registration and relink intents"
                )
            }
            let preparation = registration.preparation
            guard preparation.descriptor.id.caseInsensitiveCompare(
                project.projectID.description
            ) == .orderedSame,
                  preparation.target.canonicalRoot == project.canonicalRoot else {
                throw ProjectMemoryError.integrityFailure(
                    "project registration intent does not match its control-plane project"
                )
            }
            return ManagerOperatorProjectTransition(
                kind: "registration",
                state: "reconciliation_required",
                requestPath: registration.requestedPath,
                requestedDisplayName: registration.requestedDisplayName,
                repositoryIdentityAssertion: registration.repositoryIdentityAssertion,
                expectedGeneration: preparation.expectedControlGeneration?.rawValue,
                operationID: preparation.operationID,
                createdAt: registration.createdAt
            )
        }
        let relink = try app.projectMemory.identities.pendingRelink(
            projectID: project.projectID.description
        )
        if let relink {
            let preparation = relink.preparation
            let next = preparation.expectedGeneration.rawValue.addingReportingOverflow(1)
            let matchesUncommitted = project.generation == preparation.expectedGeneration
            let matchesCommitted = !next.overflow
                && project.generation.rawValue == next.partialValue
                && project.canonicalRoot == preparation.canonicalRoot
            guard preparation.descriptor.id.caseInsensitiveCompare(
                project.projectID.description
            ) == .orderedSame,
                  matchesUncommitted || matchesCommitted else {
                throw ProjectMemoryError.integrityFailure(
                    "project relink intent does not match its control-plane project"
                )
            }
            return ManagerOperatorProjectTransition(
                kind: "relink",
                state: "reconciliation_required",
                requestPath: preparation.canonicalRoot.path,
                requestedDisplayName: nil,
                repositoryIdentityAssertion: nil,
                expectedGeneration: preparation.expectedGeneration.rawValue,
                operationID: preparation.operationID,
                createdAt: relink.createdAt
            )
        }
        return nil
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
            checkpointID: detail.checkpointID,
            handoffID: session?.handoffID?.uuidString.lowercased() ?? detail.checkpointID,
            handoffSHA256: session?.handoffSHA256,
            predecessorSessionID: detail.predecessor?.sessionID
                ?? detail.successor?.predecessorSessionID,
            successorSessionID: detail.successor?.sessionID,
            successorProviderResponseID: detail.successor?.providerResponseID,
            acknowledgementSHA256: detail.acknowledgementSHA256,
            attempt: command.attempt,
            continuationIssued: continuationIssued,
            budget: detail.budgetObservation.map(operatorBudget),
            lastError: operatorSummary(command.lastErrorSummary, maximumCharacters: 512),
            retryAt: command.retryAt,
            updatedAt: command.updatedAt
        )
    }

    private static func operatorContinuityEvidence(
        _ operation: ContinuityOperationV2
    ) throws -> ManagerOperatorContinuityEvidence {
        guard operation.quarantineState == nil,
              let operationUUID = UUID(uuidString: operation.operationID),
              let projectUUID = UUID(uuidString: operation.projectID),
              let runUUID = UUID(uuidString: operation.runID),
              let checkpointUUID = UUID(uuidString: operation.handoffID),
              operation.projectGeneration > 0,
              operation.projectGeneration <= UInt64(Int64.max),
              operation.state != .active,
              operation.state != .checkpointPreparing else {
            throw ProjectContextError.integrityFailure(
                "persisted continuity checkpoint evidence is invalid"
            )
        }
        let acknowledgement = operation.acknowledgementSHA256
        let hasAcknowledgedState = operation.state == .successorAcknowledged
            || operation.state == .predecessorSealed
        guard hasAcknowledgedState == (acknowledgement != nil) else {
            throw ProjectContextError.integrityFailure(
                "persisted continuity acknowledgement evidence is inconsistent"
            )
        }
        if let acknowledgement {
            let range = acknowledgement.startIndex..<acknowledgement.endIndex
            guard acknowledgement.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ) == range else {
                throw ProjectContextError.integrityFailure(
                    "persisted continuity acknowledgement evidence is invalid"
                )
            }
        }
        return ManagerOperatorContinuityEvidence(
            operationID: operationUUID,
            projectID: ProjectID(projectUUID),
            projectGeneration: ProjectGeneration(operation.projectGeneration),
            runID: RunID(runUUID),
            checkpointID: checkpointUUID.uuidString.lowercased(),
            acknowledgementSHA256: acknowledgement
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
        from runs: [ManagerOperatorRunReadModel],
        probe: ManagerProviderProbeState?
    ) -> ManagerOperatorProvider {
        let probeCapabilities = probe?.capabilities
        guard let detail = runs.first(where: {
            $0.budgetState != nil || $0.activeSession != nil
        }) ?? runs.first else {
            return ManagerOperatorProvider(
                adapterID: probe.map {
                    operatorIdentifier($0.adapterID, maximumCharacters: 128)
                },
                providerID: probeCapabilities.map {
                    operatorIdentifier($0.providerID, maximumCharacters: 512)
                },
                health: probe?.health ?? "unavailable",
                endpoint: nil,
                loopback: nil,
                tls: nil,
                authenticationEnabled: nil,
                credentialConfigured: nil,
                apiMode: probe == nil ? nil : "managed_provider",
                modelKey: probeCapabilities.map {
                    operatorIdentifier($0.modelKey, maximumCharacters: 1_024)
                },
                instanceID: probeCapabilities.map {
                    operatorIdentifier($0.providerInstanceID, maximumCharacters: 1_024)
                },
                activeContextLength: probeCapabilities?.contextLength,
                maximumContextLength: probeCapabilities?.maximumContextLength,
                toolUseCapable: probeCapabilities?.customTools,
                lifecycleManagementEnabled: probe?.lifecycleManagementEnabled,
                idleTTLSeconds: nil,
                contractFingerprint: probeCapabilities.map {
                    operatorIdentifier(
                        $0.capabilityFingerprintSHA256,
                        maximumCharacters: 64
                    )
                },
                lastProbeMode: probe?.mode.rawValue,
                probeResultStorage: probe == nil ? nil : "memory_only",
                lastProbeAt: probe?.completedAt,
                lastProbeError: probe?.errorSummary
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
            adapterID: probe.map {
                operatorIdentifier($0.adapterID, maximumCharacters: 128)
            } ?? detail.run.adapterID.map {
                operatorIdentifier($0, maximumCharacters: 128)
            },
            providerID: probeCapabilities.map {
                operatorIdentifier($0.providerID, maximumCharacters: 512)
            } ?? (detail.run.providerID ?? session?.providerID).map {
                operatorIdentifier($0, maximumCharacters: 512)
            },
            health: probe?.health ?? "unavailable",
            endpoint: nil,
            loopback: nil,
            tls: nil,
            authenticationEnabled: nil,
            credentialConfigured: nil,
            apiMode: probe == nil ? nil : "managed_provider",
            modelKey: probeCapabilities.map {
                operatorIdentifier($0.modelKey, maximumCharacters: 1_024)
            } ?? (detail.run.modelKey ?? session?.modelKey).map {
                operatorIdentifier($0, maximumCharacters: 1_024)
            },
            instanceID: probeCapabilities.map {
                operatorIdentifier($0.providerInstanceID, maximumCharacters: 1_024)
            } ?? instanceID,
            activeContextLength: probeCapabilities?.contextLength
                ?? capacity?.capacity ?? session?.contextCapacity,
            maximumContextLength: probeCapabilities?.maximumContextLength
                ?? capacity?.maximumContextLength,
            toolUseCapable: probeCapabilities?.customTools,
            lifecycleManagementEnabled: probe?.lifecycleManagementEnabled,
            idleTTLSeconds: nil,
            contractFingerprint: probeCapabilities.map {
                operatorIdentifier($0.capabilityFingerprintSHA256, maximumCharacters: 64)
            } ?? contractFingerprint,
            lastProbeMode: probe?.mode.rawValue,
            probeResultStorage: probe == nil ? nil : "memory_only",
            lastProbeAt: probe?.completedAt,
            lastProbeError: probe?.errorSummary
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

    private func finishProviderProbe(
        _ state: ManagerProviderProbeState,
        probeID: UUID,
        releaseAdmission: Bool = true
    ) {
        lock.lock()
        guard activeProviderProbeID == probeID else {
            lock.unlock()
            return
        }
        runtime.providerProbeState = state
        if releaseAdmission {
            runtime.providerProbeInProgress = false
            activeProviderProbeID = nil
        }
        lock.unlock()
    }

    private func releaseProviderProbeAdmission(probeID: UUID) {
        lock.lock()
        if activeProviderProbeID == probeID {
            runtime.providerProbeInProgress = false
            activeProviderProbeID = nil
        }
        lock.unlock()
    }

    private func providerStorageDirectory(adapterID: String) throws -> URL {
        let fileManager = FileManager.default
        let root = app.paths.managedProvidersDir.standardizedFileURL
        let storage = root.appendingPathComponent(adapterID, isDirectory: true)
            .standardizedFileURL
        guard storage.deletingLastPathComponent() == root else {
            throw ManagerProviderProbeError.invalidAdapterIdentifier
        }
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let rootValues = try root.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
                throw ManagerProviderProbeError.storageUnavailable
            }
            if !fileManager.fileExists(atPath: storage.path) {
                try fileManager.createDirectory(
                    at: storage,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let storageValues = try storage.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
            guard storageValues.isDirectory == true, storageValues.isSymbolicLink != true else {
                throw ManagerProviderProbeError.storageUnavailable
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: storage.path
            )
            return storage
        } catch let error as ManagerProviderProbeError {
            throw error
        } catch {
            throw ManagerProviderProbeError.storageUnavailable
        }
    }

    private static func validateProviderAdapterID(_ adapterID: String) throws {
        let bytes = Array(adapterID.utf8)
        guard !bytes.isEmpty,
              bytes.count <= maximumProviderAdapterIDBytes,
              bytes.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 45 || byte == 46 || byte == 95
              }),
              adapterID == nativeSessionHostAdapterID else {
            throw ManagerProviderProbeError.invalidAdapterIdentifier
        }
    }

    private static func validateProviderContract(
        capabilities: ProviderCapabilities,
        manifest: HostPluginManifest
    ) throws {
        guard isSafeProviderIdentity(capabilities.providerID),
              isSafeProviderIdentity(capabilities.providerInstanceID),
              isSafeProviderIdentity(capabilities.modelKey),
              isSafeProviderIdentity(capabilities.providerVersion),
              capabilities.capabilityFingerprintSHA256.count == 64,
              capabilities.capabilityFingerprintSHA256.allSatisfy(\.isHexDigit) else {
            throw ManagerProviderProbeError.contractUnavailable(
                "provider identities or capability fingerprint are invalid"
            )
        }
        var missing: [String] = []
        if !capabilities.statefulResponses { missing.append("stateful responses") }
        if !capabilities.customTools { missing.append("custom tools") }
        if !capabilities.usageReporting || !manifest.capabilities.usageReporting {
            missing.append("usage reporting")
        }
        if !capabilities.idempotencyLookup
            || !manifest.capabilities.idempotency
            || !manifest.capabilities.queryByIdempotencyKey {
            missing.append("idempotency lookup")
        }
        if !manifest.capabilities.create
            || !manifest.capabilities.bootstrap
            || !manifest.capabilities.resume {
            missing.append("stateful lifecycle")
        }
        guard missing.isEmpty else {
            throw ManagerProviderProbeError.contractUnavailable(
                "required capabilities are absent: \(missing.joined(separator: ", "))"
            )
        }
    }

    private static func isSafeProviderIdentity(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= ManagedModelProviderContract.maximumIdentifierBytes
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func safeProviderProbeError(_ error: Error) -> String {
        operatorSummary(error.localizedDescription, maximumCharacters: 512)
            ?? "unknown provider failure"
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

    private func withLifecycleTransition<Value>(
        operation: String,
        _ body: () throws -> Value
    ) throws -> Value {
        let deadline = Date().addingTimeInterval(Self.lifecycleTransitionWaitTimeoutSeconds)
        guard lifecycleTransitionLock.lock(before: deadline) else {
            app.diagnostics.warn("manager_lifecycle_transition_busy", [
                "operation": operation,
                "wait_ms": "\(Int(Self.lifecycleTransitionWaitTimeoutSeconds * 1_000))",
            ], category: .manager)
            throw ManagerLifecycleTransitionError.busy(operation)
        }
        defer { lifecycleTransitionLock.unlock() }
        return try body()
    }

    // MARK: - Dashboard binding

    private func bindAndStartDashboard(
        reloadConfiguration: Bool = true,
        allowingCompletedResponses: Bool = false
    ) throws {
        if reloadConfiguration {
            app.config.reload()
        }
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

        tearDownDashboard(allowingCompletedResponses: allowingCompletedResponses)

        let server = DashboardServer(app: app, host: host, port: port)
        server.manager = self
        try server.start()

        lock.lock()
        runtime.dashboard = server
        lock.unlock()
    }

    private func tearDownDashboard(allowingCompletedResponses: Bool = false) {
        lock.lock()
        let server = runtime.dashboard
        runtime.dashboard = nil
        lock.unlock()
        server?.manager = nil
        if allowingCompletedResponses {
            server?.stopAllowingCompletedResponses()
        } else {
            server?.stop()
        }
    }

    /// Replaces the control-plane listener without changing whether operational
    /// service work is desired. A stopped service must still move its dashboard
    /// endpoint because Settings and Start remain reachable through that listener.
    private func rebindDashboardForSettings(desiredRunning: Bool) throws {
        if desiredRunning {
            _ = try restartServiceSerialized(reloadConfiguration: false)
            return
        }

        lock.lock()
        runtime.state = .restarting
        runtime.restartCount += 1
        let count = runtime.restartCount
        lock.unlock()

        tearDownDashboard(allowingCompletedResponses: true)
        Thread.sleep(forTimeInterval: Self.listenerReplacementPauseSeconds)
        do {
            try bindAndStartDashboard(reloadConfiguration: false)
            lock.lock()
            runtime.desiredRunning = false
            runtime.markStopped()
            lock.unlock()
            persistState()
            app.diagnostics.info("manager_dashboard_rebound", [
                "restart_count": "\(count)",
                "service_desired": "false",
            ], category: .manager)
        } catch {
            lock.lock()
            runtime.desiredRunning = false
            runtime.markFailed(error)
            lock.unlock()
            persistState()
            throw error
        }
    }

    /// A failed replacement bind rolls back only the dashboard endpoint. Every
    /// unrelated setting from the same validated patch remains committed, then
    /// the prior listener is re-established before the original bind error is
    /// returned to the caller.
    private func restoreDashboardAfterFailedSettingsBind(
        previousDashboard: AppConfig.DashboardConfig,
        desiredRunning: Bool,
        bindFailure: Error
    ) throws {
        var retainedSettings = app.config.model
        let failedDashboard = retainedSettings.dashboard
        retainedSettings.dashboard.host = previousDashboard.host
        retainedSettings.dashboard.port = previousDashboard.port

        do {
            try app.config.replace(retainedSettings, save: true)
            try bindAndStartDashboard(reloadConfiguration: false)
            lock.lock()
            runtime.desiredRunning = desiredRunning
            if desiredRunning {
                runtime.markRunning()
            } else {
                runtime.markStopped()
            }
            lock.unlock()
            persistState()
            restartWatchdog()
        } catch {
            let rollbackFailure = error
            let combined = NSError(
                domain: "ForgeConductor.ManagerSettingsBindRollback",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Dashboard bind failed at \(failedDashboard.host):\(failedDashboard.port) "
                        + "and the prior listener could not be restored at "
                        + "\(previousDashboard.host):\(previousDashboard.port): "
                        + rollbackFailure.localizedDescription,
                    NSUnderlyingErrorKey: rollbackFailure,
                ]
            )
            lock.lock()
            runtime.markFailed(combined)
            lock.unlock()
            persistState()
            app.diagnostics.error("manager_settings_bind_rollback_failed", [
                "bind_error": bindFailure.localizedDescription,
                "rollback_error": rollbackFailure.localizedDescription,
                "prior_host": previousDashboard.host,
                "prior_port": "\(previousDashboard.port)",
            ], category: .manager)
            throw combined
        }

        app.diagnostics.error("manager_settings_bind_rolled_back", [
            "bind_error": bindFailure.localizedDescription,
            "failed_host": failedDashboard.host,
            "failed_port": "\(failedDashboard.port)",
            "restored_host": previousDashboard.host,
            "restored_port": "\(previousDashboard.port)",
        ], category: .manager)
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
        let httpUp = runtime.isHTTPUp
        let shutting = runtime.shutdownRequested
        lock.unlock()

        if shutting { return }

        pruneStalePresenceIfDue()
        scheduleAutonomyTick()

        if !httpUp {
            guard lifecycleTransitionLock.try() else {
                return
            }
            defer { lifecycleTransitionLock.unlock() }

            lock.lock()
            let want = runtime.desiredRunning
            let stillHTTPDown = !runtime.isHTTPUp
            let nowShutting = runtime.shutdownRequested
            let current = runtime.state
            lock.unlock()
            guard !nowShutting, stillHTTPDown else { return }

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

        lock.lock()
        let want = runtime.desiredRunning
        let current = runtime.state
        lock.unlock()
        let auto = app.config.model.manager.autoRestart
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
        let completion = ManagerAsyncCompletion()
        let task = Task.detached(priority: .userInitiated) {
            do {
                result.store(.success(try await operation()))
            } catch {
                result.store(.failure(error))
            }
            semaphore.signal()
            completion.markCompleted()
        }
        guard semaphore.wait(timeout: .now() + max(0.1, timeoutSeconds)) == .success else {
            task.cancel()
            throw ManagerAsyncDeadlineError(completion: completion)
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

private struct ManagerAsyncDeadlineError: Error, LocalizedError, Sendable {
    let completion: ManagerAsyncCompletion

    var errorDescription: String? {
        "manager async operation exceeded its bounded deadline"
    }
}

private final class ManagerAsyncCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var callbacks: [@Sendable () -> Void] = []

    func markCompleted() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let pendingCallbacks = callbacks
        callbacks.removeAll(keepingCapacity: false)
        lock.unlock()
        pendingCallbacks.forEach { $0() }
    }

    func notifyWhenCompleted(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        if completed {
            lock.unlock()
            callback()
        } else {
            callbacks.append(callback)
            lock.unlock()
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

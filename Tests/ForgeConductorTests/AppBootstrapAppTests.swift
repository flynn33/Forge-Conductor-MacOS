import XCTest
import SwiftUI
#if SWIFT_PACKAGE
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif
@testable import ForgeConductorCore

private final class BootstrapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var enteredOnMain = false
    private var creations = 0
    private weak var created: ForgeApp?
    let release = DispatchSemaphore(value: 0)

    func started() -> Int {
        lock.withLock {
            starts += 1
            enteredOnMain = enteredOnMain || Thread.isMainThread
            return starts
        }
    }

    func observe(_ app: ForgeApp) { lock.withLock { created = app; creations += 1 } }
    var startCount: Int { lock.withLock { starts } }
    var ranOnMain: Bool { lock.withLock { enteredOnMain } }
    var application: ForgeApp? { lock.withLock { created } }
    var creationCount: Int { lock.withLock { creations } }

    func waitForRelease() throws {
        guard release.wait(timeout: .now() + 10) == .success else {
            throw BootstrapFixtureError.gateDeadline
        }
    }
}

private enum BootstrapFixtureError: Error { case expectedFailure, gateDeadline }

@MainActor
final class OperatorStartupContentAppTests: XCTestCase {
    func testOperatorScreenConstructionWaitsThroughStartupAndFailureUntilReady() {
        var constructions = 0
        for (ready, loading, failure) in [
            (false, true, Optional<String>.none),
            (false, false, Optional("Bootstrap failed")),
            (false, true, Optional<String>.none),
            (true, false, Optional<String>.none),
        ] {
            let gate = OperatorStartupContent(
                isReady: ready, isLoading: loading, errorMessage: failure,
                retry: {}, content: {
                    constructions += 1
                    return Text("Operator screen")
                }
            )
            XCTAssertEqual(constructions, 0, "Constructing the gate must not eagerly construct an operator screen")
            _ = gate.body
            XCTAssertEqual(constructions, ready ? 1 : 0)
        }
    }
}

final class GuidedSetupProgressAppTests: XCTestCase {
    func testLegacyCompletionDoesNotSuppressCurrentGuidedSetupExperience() throws {
        let suiteName = "forge-guided-setup-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: GuidedSetupStorage.legacyCompletionKey)
        XCTAssertTrue(GuidedSetupStorage.shouldPresent(in: defaults))

        defaults.set(true, forKey: GuidedSetupStorage.currentCompletionKey)
        XCTAssertFalse(GuidedSetupStorage.shouldPresent(in: defaults))
    }

    func testExactConfigurationReviewAdvancesRecommendationFromReviewToStart() {
        let unreviewed = readyProgress(
            preparationFingerprint: "preparation-a",
            reviewedPreparationFingerprint: ""
        )
        XCTAssertEqual(unreviewed.preparationState, .needsReview(fingerprint: "preparation-a"))
        XCTAssertEqual(unreviewed.recommendedStep, .configure)

        let reviewed = readyProgress(
            preparationFingerprint: "preparation-a",
            reviewedPreparationFingerprint: "preparation-a"
        )
        XCTAssertEqual(reviewed.preparationState, .reviewed(fingerprint: "preparation-a"))
        XCTAssertEqual(reviewed.recommendedStep, .start)
    }

    func testChangedPrerequisitesInvalidateReviewAndRouteToOwningStep() {
        let changedPackage = readyProgress(
            preparationFingerprint: "preparation-b",
            reviewedPreparationFingerprint: "preparation-a"
        )
        XCTAssertEqual(changedPackage.preparationState, .needsReview(fingerprint: "preparation-b"))
        XCTAssertEqual(changedPackage.recommendedStep, .configure)

        let missingProvider = GuidedSetupProgress(
            managerReady: changedPackage.managerReady,
            providerReady: false,
            projectIsRegistered: changedPackage.projectIsRegistered,
            instructionPackageCount: changedPackage.instructionPackageCount,
            preparationFingerprint: changedPackage.preparationFingerprint,
            reviewedPreparationFingerprint: changedPackage.reviewedPreparationFingerprint,
            activeRunState: changedPackage.activeRunState,
            needsAttention: changedPackage.needsAttention
        )
        XCTAssertEqual(missingProvider.preparationState, .unavailable)
        XCTAssertEqual(missingProvider.recommendedStep, .provider)

        let missingInstructions = GuidedSetupProgress(
            managerReady: true,
            providerReady: true,
            projectIsRegistered: true,
            instructionPackageCount: 0,
            preparationFingerprint: nil,
            reviewedPreparationFingerprint: "preparation-a",
            activeRunState: nil,
            needsAttention: false
        )
        XCTAssertEqual(missingInstructions.recommendedStep, .instructions)
    }

    func testActiveRunAndAttentionAdvanceToMonitorOrRecovery() {
        let running = readyProgress(
            preparationFingerprint: "preparation-a",
            reviewedPreparationFingerprint: "preparation-a",
            activeRunState: "running"
        )
        XCTAssertEqual(running.recommendedStep, .monitor)

        let attention = readyProgress(
            preparationFingerprint: "preparation-a",
            reviewedPreparationFingerprint: "preparation-a",
            activeRunState: "blocked_configuration",
            needsAttention: true
        )
        XCTAssertEqual(attention.recommendedStep, .recover)

        let automaticLegacyRecovery = readyProgress(
            preparationFingerprint: "preparation-a",
            reviewedPreparationFingerprint: "preparation-a",
            activeRunState: "blocked_configuration"
        )
        XCTAssertEqual(automaticLegacyRecovery.recommendedStep, .monitor)
        XCTAssertEqual(
            OperatorRunStatePresentation.displayName("blocked_configuration"),
            "recovering automatically"
        )
    }

    private func readyProgress(
        preparationFingerprint: String,
        reviewedPreparationFingerprint: String,
        activeRunState: String? = nil,
        needsAttention: Bool = false
    ) -> GuidedSetupProgress {
        GuidedSetupProgress(
            managerReady: true,
            providerReady: true,
            projectIsRegistered: true,
            instructionPackageCount: 1,
            preparationFingerprint: preparationFingerprint,
            reviewedPreparationFingerprint: reviewedPreparationFingerprint,
            activeRunState: activeRunState,
            needsAttention: needsAttention
        )
    }
}

@MainActor
final class AppBootstrapAppTests: XCTestCase {
    private func home() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("forge-bootstrap-test-" + UUID().uuidString)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Bootstrap operation did not reach its bounded postcondition")
    }

    func testDelayedStartupLeavesMainActorResponsiveAndCoalescesDuplicateCalls() async throws {
        let directory = home()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BootstrapProbe()
        let operation = AppBootstrapOperation(factory: {
            _ = probe.started()
            guard probe.release.wait(timeout: .now() + 10) == .success else {
                throw BootstrapFixtureError.gateDeadline
            }
            let app = try ForgeApp.bootstrap(home: directory)
            probe.observe(app)
            return app
        }, pluginStatus: { _ in nil })
        var result: Result<AppBootstrapSnapshot, Error>?
        XCTAssertTrue(operation.start { value in
            XCTAssertTrue(Thread.isMainThread)
            result = value
        })
        XCTAssertFalse(operation.start { _ in XCTFail("Duplicate startup completed") })
        try await waitUntil { probe.startCount == 1 }
        // The worker is deliberately parked until this main-actor turn releases it.
        XCTAssertNil(result)
        XCTAssertFalse(probe.ranOnMain)
        XCTAssertTrue(operation.isRunning)
        probe.release.signal()
        try await waitUntil { result != nil }
        let snapshot = try XCTUnwrap(result).get()
        XCTAssertEqual(snapshot.app.paths.home.standardizedFileURL, directory.standardizedFileURL)
        XCTAssertFalse(operation.isRunning)
        let shutdown = await Task.detached { snapshot.app.shutdown() }.value
        XCTAssertTrue(shutdown.completed)
    }

    func testCancellationClosesUnpublishedGraphAndAllowsRetryAfterCompletion() async throws {
        let directory = home()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BootstrapProbe()
        let operation = AppBootstrapOperation(factory: {
            let attempt = probe.started()
            guard probe.release.wait(timeout: .now() + 10) == .success else {
                throw BootstrapFixtureError.gateDeadline
            }
            if attempt > 1 { throw BootstrapFixtureError.expectedFailure }
            let app = try ForgeApp.bootstrap(home: directory)
            probe.observe(app)
            return app
        }, pluginStatus: { _ in XCTFail("Cancelled graph reached status preparation"); return nil })
        var cancellations = 0
        XCTAssertTrue(operation.start { result in
            guard case .failure(is CancellationError) = result else { return XCTFail("Cancelled startup published a graph") }
            cancellations += 1
        })
        try await waitUntil { probe.startCount == 1 }
        operation.cancel()
        XCTAssertFalse(operation.start { _ in XCTFail("Cancelled startup admitted overlapping retry") })
        probe.release.signal()
        await operation.stop()
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(operation.isRunning)
        XCTAssertNil(probe.application, "Unpublished application graph survived cancellation")
        var retried = false
        probe.release.signal()
        XCTAssertTrue(operation.start { result in
            guard case .failure(BootstrapFixtureError.expectedFailure) = result else { return XCTFail("Unexpected retry result") }
            retried = true
        })
        try await waitUntil { retried }
        XCTAssertEqual(probe.startCount, 2)
    }

    func testOwnerReleaseCancelsWorkerWithoutRetainingApplication() async throws {
        let directory = home()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BootstrapProbe()
        var operation: AppBootstrapOperation? = AppBootstrapOperation(factory: {
            _ = probe.started()
            guard probe.release.wait(timeout: .now() + 10) == .success else {
                throw BootstrapFixtureError.gateDeadline
            }
            let app = try ForgeApp.bootstrap(home: directory)
            probe.observe(app)
            return app
        }, pluginStatus: { _ in nil })
        weak let released = operation
        operation?.start { _ in XCTFail("Released owner received completion") }
        try await waitUntil { probe.startCount == 1 }
        operation = nil
        XCTAssertNil(released)
        probe.release.signal()
        // Cancellation cleanup must finish before the disposable directory is removed.
        try await waitUntil { probe.creationCount == 1 && probe.application == nil }
    }

    func testNativeModelFailureAndRetryKeepPublishedStateOnMainActor() async throws {
        let probe = BootstrapProbe()
        let operation = AppBootstrapOperation(factory: {
            _ = probe.started()
            throw BootstrapFixtureError.expectedFailure
        }, pluginStatus: { _ in nil })
        let model = AppModel(bootstrapOperation: operation)
        model.autoRefresh = false
        try await waitUntil { !model.isBootstrapping }
        XCTAssertNil(model.app)
        XCTAssertTrue(model.lastError?.hasPrefix("Bootstrap failed:") == true)
        XCTAssertFalse(model.autoRefresh)
        model.bootstrap()
        try await waitUntil { !model.isBootstrapping }
        XCTAssertEqual(probe.startCount, 2)
        XCTAssertFalse(probe.ranOnMain)
        XCTAssertFalse(model.autoRefresh)
        await model.stopBootstrap()
    }

    func testSettingsMutationsWaitForStartupAndFailureStillAllowsRetry() async throws {
        let directory = home()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BootstrapProbe()
        let operation = AppBootstrapOperation(factory: {
            _ = probe.started()
            try probe.waitForRelease()
            throw BootstrapFixtureError.expectedFailure
        }, pluginStatus: { _ in nil })
        let model = AppModel(bootstrapOperation: operation)
        try await waitUntil { probe.startCount == 1 }
        XCTAssertTrue(model.isBootstrapping)
        XCTAssertFalse(model.hasLoadedInitialSettings)
        XCTAssertFalse(model.addAllowedRoot(directory), "A valid folder must not be staged against unloaded settings")
        model.chooseAllowedRoot() // Must return before presenting the native picker.
        model.removeAllowedRoot(directory.path)
        model.saveSettings()
        XCTAssertTrue(model.setAllowedRoots.isEmpty)
        XCTAssertEqual(model.managerMessage, "Settings are unavailable until startup completes.")
        probe.release.signal()
        try await waitUntil { !model.isBootstrapping }
        XCTAssertFalse(model.hasLoadedInitialSettings)
        XCTAssertTrue(model.lastError?.hasPrefix("Bootstrap failed:") == true)
        model.bootstrap()
        try await waitUntil { probe.startCount == 2 }
        XCTAssertTrue(model.isBootstrapping)
        probe.release.signal()
        await model.stopBootstrap()
        XCTAssertFalse(model.hasLoadedInitialSettings)
    }
}

final class RigOperationalSnapshotAppTests: XCTestCase {
    func testDesktopProviderReadinessDoesNotDependOnLMStudioHealth() throws {
        let operatorSnapshot = try JSONDecoder().decode(
            OperatorSnapshot.self,
            from: Data("""
            {
              "provider":{"health":"unavailable","model_key":"stale/lm-model"},
              "run_preparation":{
                "state":"ready",
                "provider_id":"codex-desktop",
                "adapter_id":"forge.desktop-plugin.codex-desktop",
                "model_key":"host-selected",
                "provider_configuration_revision":"desktop-revision-1",
                "allowed_tools":[],
                "completion_gates":["automatic_completion_evidence"],
                "network_allowed":false,
                "detail":"The selected desktop provider will verify its live Forge integration before this task starts."
              }
            }
            """.utf8)
        )
        let receipt = try ProviderIntegrationReceipt(
            providerID: .codexDesktop,
            artifactVersion: "desktop-deployment-1",
            installedAt: "2026-09-23T12:00:00Z",
            verifiedAt: "2026-09-23T12:00:01Z"
        )
        let integrations = ProviderIntegrationsSnapshot(
            selectionRevision: "desktop-revision-1",
            selectedProviderID: .codexDesktop,
            providers: ProviderIntegrationDescriptor.supported.map {
                ProviderIntegrationProviderSnapshot(
                    descriptor: $0,
                    receipt: $0.id == .codexDesktop ? receipt : nil
                )
            },
            currentOperation: nil,
            recentOperations: []
        )

        let result = RigOperationalSnapshot.compose(
            operatorSnapshot: operatorSnapshot,
            autonomy: nil,
            runeForge: nil,
            providerIntegrations: integrations
        )

        XCTAssertEqual(result.providerHealth, "unavailable")
        XCTAssertEqual(result.providerModel, "stale/lm-model")
        XCTAssertEqual(result.selectedProvider.id, ProviderIntegrationID.codexDesktop.rawValue)
        XCTAssertEqual(result.selectedProvider.displayName, "Codex Desktop")
        XCTAssertEqual(result.selectedProvider.executionMode, .desktopHost)
        XCTAssertEqual(result.selectedProvider.model, "host-selected")
        XCTAssertTrue(result.selectedProvider.isReady)

        let indicator = RigProviderIndicatorState.compose(
            runtime: result,
            lmStudioAlive: false,
            lmStudioCPU: 0
        )
        XCTAssertEqual(indicator.title, "CODEX DESKTOP")
        XCTAssertEqual(indicator.state, "HOST READY")
        XCTAssertEqual(indicator.detail, "Host-managed execution · model selected in host")
        XCTAssertEqual(indicator.tone, .healthy)

        let guidedStatus = GuidedSetupProviderStatus.compose(result.selectedProvider)
        XCTAssertTrue(guidedStatus.isReady)
        XCTAssertEqual(guidedStatus.label, "Ready")
        XCTAssertEqual(
            guidedStatus.detail,
            "Codex Desktop is ready for host-managed execution."
        )

        let staleSelection = RigOperationalSnapshot.compose(
            operatorSnapshot: operatorSnapshot,
            autonomy: nil,
            runeForge: nil,
            providerIntegrations: ProviderIntegrationsSnapshot(
                selectionRevision: "desktop-revision-2",
                selectedProviderID: integrations.selectedProviderID,
                providers: integrations.providers,
                currentOperation: nil,
                recentOperations: []
            )
        )
        XCTAssertFalse(staleSelection.selectedProvider.isReady)
        XCTAssertTrue(staleSelection.selectedProvider.detail.contains("Refresh Provider"))
    }

    func testLMStudioProviderReadinessRetainsLiveAPIAndModelContract() throws {
        let operatorSnapshot = try JSONDecoder().decode(
            OperatorSnapshot.self,
            from: Data("""
            {
              "provider":{"health":"contract_valid","model_key":"fixture/lm-model"},
              "run_preparation":{
                "state":"ready",
                "provider_id":"lmstudio",
                "adapter_id":"forge.native-session-host",
                "model_key":"fixture/lm-model",
                "allowed_tools":[],
                "completion_gates":[],
                "network_allowed":false,
                "detail":"The saved LM Studio provider passed its contract check."
              }
            }
            """.utf8)
        )
        let integrations = ProviderIntegrationsSnapshot(
            selectionRevision: "lm-revision-1",
            selectedProviderID: .lmStudio,
            providers: ProviderIntegrationDescriptor.supported.map {
                ProviderIntegrationProviderSnapshot(descriptor: $0, receipt: nil)
            },
            currentOperation: nil,
            recentOperations: []
        )

        let result = RigOperationalSnapshot.compose(
            operatorSnapshot: operatorSnapshot,
            autonomy: nil,
            runeForge: nil,
            providerIntegrations: integrations
        )

        XCTAssertEqual(result.selectedProvider.executionMode, .managedModel)
        XCTAssertEqual(result.selectedProvider.model, "fixture/lm-model")
        XCTAssertTrue(result.selectedProvider.isReady)
        let indicator = RigProviderIndicatorState.compose(
            runtime: result,
            lmStudioAlive: false,
            lmStudioCPU: 12
        )
        XCTAssertEqual(indicator.title, "LM STUDIO")
        XCTAssertEqual(indicator.state, "HEADLESS")
        XCTAssertEqual(indicator.detail, "fixture/lm-model · Chat separate")
        XCTAssertEqual(indicator.fraction, 0.12, accuracy: 0.0001)
        XCTAssertEqual(
            GuidedSetupProviderStatus.compose(result.selectedProvider).detail,
            "Connected to fixture/lm-model."
        )
    }

    func testUnavailableOrNonselectableProviderCannotAppearReady() throws {
        let operatorSnapshot = try JSONDecoder().decode(
            OperatorSnapshot.self,
            from: Data("""
            {
              "provider":{"health":"contract_valid","model_key":"fixture/lm-model"},
              "run_preparation":{
                "state":"ready",
                "provider_id":"grok-build",
                "adapter_id":"forge.desktop-plugin.grok-build",
                "model_key":"host-selected",
                "allowed_tools":[],
                "completion_gates":[],
                "network_allowed":false,
                "detail":"Fixture reports ready."
              }
            }
            """.utf8)
        )
        let grokDescriptor = ProviderIntegrationDescriptor(
            id: .grokBuild,
            displayName: "Grok Build",
            executionStrategy: .desktopPluginPull,
            selectable: false,
            detail: "Status only."
        )
        let receipt = try ProviderIntegrationReceipt(
            providerID: .grokBuild,
            artifactVersion: "grok-deployment-1",
            installedAt: "2026-09-23T12:00:00Z",
            verifiedAt: "2026-09-23T12:00:01Z"
        )
        let nonselectable = ProviderIntegrationsSnapshot(
            selectionRevision: "grok-revision-1",
            selectedProviderID: .grokBuild,
            providers: [ProviderIntegrationProviderSnapshot(
                descriptor: grokDescriptor,
                receipt: receipt
            )],
            currentOperation: nil,
            recentOperations: []
        )
        let deferred = RigOperationalSnapshot.compose(
            operatorSnapshot: operatorSnapshot,
            autonomy: nil,
            runeForge: nil,
            providerIntegrations: nonselectable
        )
        XCTAssertFalse(deferred.selectedProvider.isReady)
        XCTAssertTrue(deferred.selectedProvider.detail.contains("not available for automated runs"))
        XCTAssertFalse(GuidedSetupProviderStatus.compose(deferred.selectedProvider).isReady)

        let deactivated = RigOperationalSnapshot.compose(
            operatorSnapshot: operatorSnapshot,
            autonomy: nil,
            runeForge: nil,
            providerIntegrations: ProviderIntegrationsSnapshot(
                selectionRevision: "none-revision-1",
                selectedProviderID: nil,
                providers: [],
                currentOperation: nil,
                recentOperations: []
            )
        )
        XCTAssertNil(deactivated.selectedProvider.id)
        XCTAssertFalse(deactivated.selectedProvider.isReady)
        XCTAssertEqual(
            RigProviderIndicatorState.compose(
                runtime: deactivated,
                lmStudioAlive: true,
                lmStudioCPU: 40
            ).state,
            "NOT SELECTED"
        )
    }

    func testComposeProjectsProviderAutonomyContinuityAndRuneForgeEvidence() throws {
        let projectID = UUID()
        let runID = UUID()
        let operatorSnapshot = try JSONDecoder().decode(
            OperatorSnapshot.self,
            from: Data("""
            {
              "provider":{"health":"contract_valid","model_key":"fixture/model"},
              "continuity_readiness":[{
                "project_id":"\(projectID.uuidString)",
                "project_generation":1,
                "run_id":"\(runID.uuidString)",
                "state":"saving_progress",
                "automatic":true,
                "detail":"Saving a durable checkpoint",
                "capacity_tokens":100,
                "used_tokens":70
              }]
            }
            """.utf8)
        )
        let autonomy = try JSONDecoder().decode(
            OperatorAutonomySummary.self,
            from: Data("""
            {"started":true,"active_run_ids":["\(runID.uuidString)"],"deferred_run_ids":[]}
            """.utf8)
        )
        let selected = DevelopmentPolicySource(
            origin: .userSelected,
            displayName: "Selected policy",
            selectedPath: "/tmp/policy",
            interpretationState: .indexed
        )
        let runeForge = StjornarvaldManagerSnapshot(
            schemaVersion: StjornarvaldManagerSnapshot.schemaVersion,
            health: StjornarvaldManagerHealth(
                state: .running,
                policyIdentity: "fixture-policy",
                evaluatorID: "fixture-evaluator",
                startedAt: Date(),
                lastEvaluationAt: Date(),
                lastCommittedCursor: 4,
                processedObservationCount: 7,
                indexedSourceBatchCount: 1,
                consecutiveFailureCount: 0,
                lastError: nil
            ),
            governingPolicy: GoverningPolicyIdentity(
                bindingID: "fixture-policy",
                authority: "fixture",
                repositoryURL: "https://example.invalid/policy",
                version: "1",
                revision: "fixture",
                sourceID: selected.id
            ),
            sources: [selected],
            violationEvents: [],
            nextEventCursor: nil,
            limitations: []
        )

        let result = RigOperationalSnapshot.compose(
            operatorSnapshot: operatorSnapshot,
            autonomy: autonomy,
            runeForge: runeForge
        )
        XCTAssertEqual(result.providerHealth, "contract_valid")
        XCTAssertEqual(result.providerModel, "fixture/model")
        XCTAssertEqual(result.autonomyStarted, true)
        XCTAssertEqual(result.autonomyActiveCount, 1)
        XCTAssertEqual(result.continuityAutomaticCount, 1)
        XCTAssertEqual(result.continuityActiveCount, 1)
        XCTAssertEqual(try XCTUnwrap(result.continuityContextLoad), 0.7, accuracy: 0.0001)
        XCTAssertEqual(result.runeForgeState, .running)
        XCTAssertEqual(result.runeForgeSelectedSourceCount, 1)
        XCTAssertEqual(result.runeForgeIndexedSourceCount, 1)
        XCTAssertEqual(result.runeForgeProcessedObservationCount, 7)
    }

    func testComposeReportsInstructionStepAndPackageProgress() throws {
        let projectID = UUID().uuidString
        let project = try JSONDecoder().decode(OperatorProject.self, from: Data("""
        {
          "project_id":"\(projectID)","display_name":"Fixture Project",
          "canonical_root":"/tmp/fixture","project_generation":1,
          "lifecycle_state":"active","bindings":[],"memory":{"state":"ready"},
          "continuity":{"state":"ready"},"migration_warnings":[]
        }
        """.utf8))
        let queue = try JSONDecoder().decode(OperatorInstructionQueue.self, from: Data("""
        {
          "project_id":"\(projectID)","project_generation":1,"revision":4,
          "running":true,"total_packages":2,"packages":[
            {"id":"\(UUID().uuidString)","project_id":"\(projectID)",
             "project_generation":1,"package_id":"one","version":"1",
             "display_name":"One","mission":"One","source_path":"/tmp/one",
             "content_sha256":"\(String(repeating: "a", count: 64))",
             "allowed_tools":[],"completion_gates":[],"document_count":3,
             "completed_step_count":3,"total_step_count":3,"position":0,
             "state":"completed","created_at":"now","updated_at":"now"},
            {"id":"\(UUID().uuidString)","project_id":"\(projectID)",
             "project_generation":1,"package_id":"two","version":"1",
             "display_name":"Two","mission":"Two","source_path":"/tmp/two",
             "content_sha256":"\(String(repeating: "b", count: 64))",
             "allowed_tools":[],"completion_gates":[],"document_count":4,
             "completed_step_count":2,"total_step_count":4,"position":1,
             "state":"running","created_at":"now","updated_at":"now"}
          ]
        }
        """.utf8))
        let result = RigOperationalSnapshot.compose(
            operatorSnapshot: nil, autonomy: nil, runeForge: nil,
            instructionQueue: queue, progressProject: project
        )
        XCTAssertEqual(result.projectName, "Fixture Project")
        XCTAssertEqual(result.projectCompletedSteps, 5)
        XCTAssertEqual(result.projectTotalSteps, 7)
        XCTAssertEqual(result.projectCompletedPackages, 1)
        XCTAssertEqual(result.projectTotalPackages, 2)
        XCTAssertEqual(result.projectProgressState, "RUNNING")
    }

    func testGuidedSetupPreparationFingerprintTracksExactReviewInputs() throws {
        let projectID = UUID().uuidString
        let packageRecordID = UUID().uuidString
        let project = try JSONDecoder().decode(OperatorProject.self, from: Data("""
        {
          "project_id":"\(projectID)","display_name":"Fixture Project",
          "canonical_root":"/tmp/fixture","project_generation":1,
          "lifecycle_state":"active","bindings":[],"memory":{"state":"ready"},
          "continuity":{"state":"ready"},"migration_warnings":[]
        }
        """.utf8))
        func packages(content: Character) throws -> [OperatorInstructionPackage] {
            let queue = try JSONDecoder().decode(OperatorInstructionQueue.self, from: Data("""
            {
              "project_id":"\(projectID)","project_generation":1,"revision":1,
              "running":false,"packages":[
                {"id":"\(packageRecordID)","project_id":"\(projectID)",
                 "project_generation":1,"package_id":"setup","version":"1",
                 "display_name":"Setup","mission":"Configure","source_path":"/tmp/setup",
                 "content_sha256":"\(String(repeating: content, count: 64))",
                 "allowed_tools":[],"completion_gates":[],"document_count":1,
                 "position":0,"state":"queued","created_at":"now","updated_at":"now"}
              ]
            }
            """.utf8))
            return queue.packages
        }
        let provider = RigProviderProjection(
            id: "lmstudio",
            displayName: "LM Studio",
            executionMode: .managedModel,
            model: "fixture/model",
            readinessState: "contract_valid",
            detail: "Ready",
            isReady: true,
            integrationEvidenceAvailable: true
        )
        let baseline = try XCTUnwrap(RigOperationalSnapshot.guidedSetupPreparationFingerprint(
            selectedProvider: provider,
            providerConfigurationRevision: "provider-1",
            providerSelectionRevision: "selection-1",
            project: project,
            packages: packages(content: "a")
        ))
        XCTAssertEqual(
            baseline,
            RigOperationalSnapshot.guidedSetupPreparationFingerprint(
                selectedProvider: provider,
                providerConfigurationRevision: "provider-1",
                providerSelectionRevision: "selection-1",
                project: project,
                packages: try packages(content: "a")
            )
        )
        XCTAssertNotEqual(
            baseline,
            RigOperationalSnapshot.guidedSetupPreparationFingerprint(
                selectedProvider: provider,
                providerConfigurationRevision: "provider-2",
                providerSelectionRevision: "selection-1",
                project: project,
                packages: try packages(content: "a")
            )
        )
        XCTAssertNotEqual(
            baseline,
            RigOperationalSnapshot.guidedSetupPreparationFingerprint(
                selectedProvider: provider,
                providerConfigurationRevision: "provider-1",
                providerSelectionRevision: "selection-1",
                project: project,
                packages: try packages(content: "b")
            )
        )
    }

    func testComposeBuildsBoundedRollingManagedActivityWithoutDuplicatingRefreshes() throws {
        let projectID = UUID().uuidString
        let runID = UUID().uuidString
        let project = try JSONDecoder().decode(OperatorProject.self, from: Data("""
        {
          "project_id":"\(projectID)","display_name":"Activity Project",
          "canonical_root":"/tmp/activity","project_generation":1,
          "lifecycle_state":"active","bindings":[],"memory":{"state":"ready"},
          "continuity":{"state":"ready"},"migration_warnings":[]
        }
        """.utf8))
        let queue = try JSONDecoder().decode(OperatorInstructionQueue.self, from: Data("""
        {
          "project_id":"\(projectID)","project_generation":1,"revision":4,
          "running":true,"total_packages":1,"packages":[
            {"id":"\(UUID().uuidString)","project_id":"\(projectID)",
             "project_generation":1,"package_id":"monitoring","version":"1",
             "display_name":"Monitoring Package","mission":"Expose run progress",
             "source_path":"/tmp/monitoring","content_sha256":"\(String(repeating: "c", count: 64))",
             "allowed_tools":[],"completion_gates":[],"document_count":5,
             "completed_step_count":2,"total_step_count":5,"position":0,
             "state":"running","run_id":"\(runID)",
             "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
          ]
        }
        """.utf8))
        let firstOperatorSnapshot = try operatorSnapshot(
            projectID: projectID,
            runID: runID,
            assistantMessage: "First managed response\nwith detail",
            turnTimestamp: "2026-01-01T00:00:02Z"
        )
        let runeForge = policySnapshot(
            event: policyEvent(projectID: projectID, occurredAt: Date(timeIntervalSince1970: 1_767_225_603))
        )
        let first = RigOperationalSnapshot.compose(
            operatorSnapshot: firstOperatorSnapshot,
            autonomy: nil,
            runeForge: runeForge,
            instructionQueue: queue,
            progressProject: project
        )

        XCTAssertEqual(first.currentPackageName, "Monitoring Package")
        XCTAssertEqual(first.currentPackagePosition, 1)
        XCTAssertEqual(first.currentPackageCompletedSteps, 2)
        XCTAssertEqual(first.currentStep, 3)
        XCTAssertEqual(first.currentStepTotal, 5)
        XCTAssertEqual(first.currentPhase, "Implementation")
        XCTAssertEqual(first.currentWorkItem, "Add managed activity")
        XCTAssertEqual(first.currentNextAction, "Run verification")
        XCTAssertTrue(first.operatorEvidenceAvailable)
        XCTAssertTrue(first.instructionEvidenceAvailable)
        XCTAssertTrue(first.policyEvidenceAvailable)
        XCTAssertEqual(first.activityFeed.first?.category, .policy)
        XCTAssertEqual(Set(first.activityFeed.map(\.category)), [
            .prompt, .session, .tool, .instruction, .orchestration, .policy,
        ])

        let secondOperatorSnapshot = try operatorSnapshot(
            projectID: projectID,
            runID: runID,
            assistantMessage: "Second managed response",
            turnTimestamp: "2026-01-01T00:00:04Z"
        )
        let second = RigOperationalSnapshot.compose(
            operatorSnapshot: secondOperatorSnapshot,
            autonomy: nil,
            runeForge: runeForge,
            instructionQueue: queue,
            progressProject: project,
            priorActivity: first.activityFeed
        )
        XCTAssertEqual(second.activityFeed.filter { $0.category == .session }.count, 4)
        XCTAssertEqual(second.activityFeed.filter { $0.category == .tool }.count, 2)
        let repeated = RigOperationalSnapshot.compose(
            operatorSnapshot: secondOperatorSnapshot,
            autonomy: nil,
            runeForge: runeForge,
            instructionQueue: queue,
            progressProject: project,
            priorActivity: second.activityFeed
        )
        XCTAssertEqual(repeated.activityFeed, second.activityFeed)

        let oversizedHistory = (0..<150).map { index in
            RigActivityEntry(
                id: "history-\(index)",
                occurredAt: Date(timeIntervalSince1970: TimeInterval(index)),
                category: .orchestration,
                title: "History",
                message: String(repeating: "x", count: 10_000),
                projectID: nil,
                severity: .informational
            )
        }
        let bounded = RigOperationalSnapshot.compose(
            operatorSnapshot: nil,
            autonomy: nil,
            runeForge: nil,
            priorActivity: oversizedHistory
        )
        XCTAssertEqual(bounded.activityFeed.count, RigOperationalSnapshot.maximumActivityEntries)
        XCTAssertEqual(bounded.activityFeed.first?.id, "history-149")
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(bounded.activityFeed.first).message.utf8.count,
            RigOperationalSnapshot.maximumActivityMessageBytes
        )
        XCTAssertFalse(bounded.operatorEvidenceAvailable)
        XCTAssertFalse(bounded.instructionEvidenceAvailable)
        XCTAssertFalse(bounded.policyEvidenceAvailable)
    }

    func testComposeDoesNotCombineDirectRunWithUnrelatedQueuedOrFailedPackage() throws {
        let projectID = UUID().uuidString
        let runID = UUID().uuidString
        let project = try JSONDecoder().decode(OperatorProject.self, from: Data("""
        {
          "project_id":"\(projectID)","display_name":"Association Project",
          "canonical_root":"/tmp/association","project_generation":3,
          "lifecycle_state":"active","bindings":[],"memory":{"state":"ready"},
          "continuity":{"state":"ready"},"migration_warnings":[]
        }
        """.utf8))
        let queue = try JSONDecoder().decode(OperatorInstructionQueue.self, from: Data("""
        {
          "project_id":"\(projectID)","project_generation":3,"revision":8,
          "running":false,"total_packages":3,"packages":[
            {"id":"\(UUID().uuidString)","project_id":"\(projectID)",
             "project_generation":3,"package_id":"failed","version":"1",
             "display_name":"Failed Package","mission":"Failed","source_path":"/tmp/failed",
             "content_sha256":"\(String(repeating: "a", count: 64))",
             "allowed_tools":[],"completion_gates":[],"document_count":2,"position":0,
             "state":"failed","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"},
            {"id":"\(UUID().uuidString)","project_id":"\(projectID)",
             "project_generation":3,"package_id":"cancelled","version":"1",
             "display_name":"Cancelled Package","mission":"Cancelled","source_path":"/tmp/cancelled",
             "content_sha256":"\(String(repeating: "b", count: 64))",
             "allowed_tools":[],"completion_gates":[],"document_count":2,"position":1,
             "state":"cancelled","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"},
            {"id":"\(UUID().uuidString)","project_id":"\(projectID)",
             "project_generation":3,"package_id":"queued","version":"1",
             "display_name":"Queued Package","mission":"Queued","source_path":"/tmp/queued",
             "content_sha256":"\(String(repeating: "c", count: 64))",
             "allowed_tools":[],"completion_gates":[],"document_count":4,"position":2,
             "state":"queued","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
          ]
        }
        """.utf8))
        let snapshot = try JSONDecoder().decode(OperatorSnapshot.self, from: Data("""
        {"runs":[{
          "run_id":"\(runID)","project_id":"\(projectID)","project_generation":3,
          "mission":"Direct managed task","state":"running","continuity_mode":"automatic",
          "current_phase":"Direct phase","work_item":"Direct work",
          "next_action":"Direct next","created_at":"2026-01-01T00:00:00Z"
        }]}
        """.utf8))

        let result = RigOperationalSnapshot.compose(
            operatorSnapshot: snapshot,
            autonomy: nil,
            runeForge: nil,
            instructionQueue: queue,
            progressProject: project
        )

        XCTAssertNil(result.currentPackageName)
        XCTAssertEqual(result.currentWorkItem, "Direct work")
        XCTAssertEqual(result.nextPackageName, "Queued Package")
        XCTAssertEqual(result.nextPackagePosition, 3)
        XCTAssertEqual(result.nextPackageStepTotal, 4)
        XCTAssertFalse(result.activityFeed.contains { $0.category == .instruction })
    }

    func testMonitoredRunPrefersTheExactInstructionPackageRun() throws {
        let projectID = UUID().uuidString
        let newestRunID = UUID().uuidString
        let packageRunID = UUID().uuidString
        let project = try JSONDecoder().decode(OperatorProject.self, from: Data("""
        {
          "project_id":"\(projectID)","display_name":"Selection Project",
          "canonical_root":"/tmp/selection","project_generation":5,
          "lifecycle_state":"active","bindings":[],"memory":{"state":"ready"},
          "continuity":{"state":"ready"},"migration_warnings":[]
        }
        """.utf8))
        let snapshot = try JSONDecoder().decode(OperatorSnapshot.self, from: Data("""
        {"runs":[
          {"run_id":"\(newestRunID)","project_id":"\(projectID)",
           "project_generation":5,"mission":"New direct task","state":"running",
           "continuity_mode":"automatic"},
          {"run_id":"\(packageRunID)","project_id":"\(projectID)",
           "project_generation":5,"mission":"Instruction task","state":"running",
           "continuity_mode":"automatic"}
        ]}
        """.utf8))
        let queue = try JSONDecoder().decode(OperatorInstructionQueue.self, from: Data("""
        {
          "project_id":"\(projectID)","project_generation":5,"revision":1,
          "running":true,"total_packages":1,"packages":[{
            "id":"\(UUID().uuidString)","project_id":"\(projectID)",
            "project_generation":5,"package_id":"selected","version":"1",
            "display_name":"Selected Package","mission":"Follow the package",
            "source_path":"/tmp/selected","content_sha256":"\(String(repeating: "d", count: 64))",
            "allowed_tools":[],"completion_gates":[],"document_count":2,
            "completed_step_count":0,"total_step_count":2,"position":0,
            "state":"running","run_id":"\(packageRunID)",
            "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:01Z"
          }]
        }
        """.utf8))

        XCTAssertEqual(
            RigOperationalSnapshot.monitoredRun(
                operatorSnapshot: snapshot,
                instructionQueue: queue,
                progressProject: project
            )?.runID,
            packageRunID
        )
    }

    func testMonitoredRunIDRetainsPackageRunOutsideRecentSnapshot() throws {
        let projectID = UUID().uuidString
        let recentRunID = UUID().uuidString
        let packageRunID = UUID().uuidString
        let project = try JSONDecoder().decode(OperatorProject.self, from: Data("""
        {
          "project_id":"\(projectID)","display_name":"Deep History Project",
          "canonical_root":"/tmp/deep-history","project_generation":6,
          "lifecycle_state":"active","bindings":[],"memory":{"state":"ready"},
          "continuity":{"state":"ready"},"migration_warnings":[]
        }
        """.utf8))
        let boundedPublicSnapshot = try JSONDecoder().decode(OperatorSnapshot.self, from: Data("""
        {"runs":[{
          "run_id":"\(recentRunID)","project_id":"\(projectID)",
          "project_generation":6,"mission":"New direct task","state":"running",
          "continuity_mode":"automatic"
        }]}
        """.utf8))
        let queue = try JSONDecoder().decode(OperatorInstructionQueue.self, from: Data("""
        {
          "project_id":"\(projectID)","project_generation":6,"revision":2,
          "running":true,"total_packages":1,"packages":[{
            "id":"\(UUID().uuidString)","project_id":"\(projectID)",
            "project_generation":6,"package_id":"historical-run","version":"1",
            "display_name":"Historical Package","mission":"Continue the package",
            "source_path":"/tmp/historical","content_sha256":"\(String(repeating: "e", count: 64))",
            "allowed_tools":[],"completion_gates":[],"document_count":3,
            "completed_step_count":1,"total_step_count":3,"position":0,
            "state":"running","run_id":"\(packageRunID)",
            "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:01Z"
          }]
        }
        """.utf8))

        XCTAssertNil(
            RigOperationalSnapshot.monitoredRun(
                operatorSnapshot: boundedPublicSnapshot,
                instructionQueue: queue,
                progressProject: project
            )
        )
        XCTAssertEqual(
            RigOperationalSnapshot.monitoredRunID(
                operatorSnapshot: boundedPublicSnapshot,
                instructionQueue: queue,
                progressProject: project
            ),
            packageRunID
        )
    }

    func testComposeDropsPriorRunActivityWhenMonitoredRunChangesWithinGeneration() throws {
        let projectID = UUID().uuidString
        let priorRunID = UUID().uuidString
        let activeRunID = UUID().uuidString
        let project = try JSONDecoder().decode(OperatorProject.self, from: Data("""
        {
          "project_id":"\(projectID)","display_name":"Run Isolation Project",
          "canonical_root":"/tmp/run-isolation","project_generation":4,
          "lifecycle_state":"active","bindings":[],"memory":{"state":"ready"},
          "continuity":{"state":"ready"},"migration_warnings":[]
        }
        """.utf8))
        let snapshot = try JSONDecoder().decode(OperatorSnapshot.self, from: Data("""
        {"runs":[{
          "run_id":"\(activeRunID)","project_id":"\(projectID)",
          "project_generation":4,"mission":"Current managed task","state":"running",
          "continuity_mode":"automatic","created_at":"2026-01-01T00:00:04Z"
        }]}
        """.utf8))
        let priorActivity = [
            RigActivityEntry(
                id: "prior-run-assistant",
                occurredAt: Date(timeIntervalSince1970: 3),
                category: .session,
                title: "Prior response",
                message: "Must not cross the run boundary",
                projectID: projectID,
                projectGeneration: 4,
                runID: priorRunID,
                severity: .informational
            ),
            RigActivityEntry(
                id: "prior-run-policy",
                occurredAt: Date(timeIntervalSince1970: 2),
                category: .policy,
                title: "Prior run policy",
                message: "Run-scoped policy must not cross the run boundary",
                projectID: projectID,
                projectGeneration: 4,
                runID: priorRunID,
                severity: .warning
            ),
            RigActivityEntry(
                id: "project-policy",
                occurredAt: Date(timeIntervalSince1970: 1),
                category: .policy,
                title: "Project policy",
                message: "Project-scoped policy remains applicable",
                projectID: projectID,
                projectGeneration: 4,
                severity: .warning
            ),
            RigActivityEntry(
                id: "global-policy",
                occurredAt: Date(timeIntervalSince1970: 0),
                category: .policy,
                title: "Global policy",
                message: "Global policy remains applicable",
                projectID: nil,
                severity: .warning
            ),
        ]

        let result = RigOperationalSnapshot.compose(
            operatorSnapshot: snapshot,
            autonomy: nil,
            runeForge: nil,
            progressProject: project,
            priorActivity: priorActivity
        )

        XCTAssertFalse(result.activityFeed.contains { $0.runID == priorRunID })
        XCTAssertTrue(result.activityFeed.contains { $0.runID == activeRunID })
        XCTAssertTrue(result.activityFeed.contains { $0.id == "project-policy" })
        XCTAssertTrue(result.activityFeed.contains { $0.id == "global-policy" })
    }

    func testComposeDropsRetainedActivityFromPriorProjectGeneration() throws {
        let projectID = UUID().uuidString
        let project = try JSONDecoder().decode(OperatorProject.self, from: Data("""
        {
          "project_id":"\(projectID)","display_name":"Reset Project",
          "canonical_root":"/tmp/reset","project_generation":2,
          "lifecycle_state":"active","bindings":[],"memory":{"state":"ready"},
          "continuity":{"state":"ready"},"migration_warnings":[]
        }
        """.utf8))
        let stale = RigActivityEntry(
            id: "stale-generation",
            occurredAt: Date(),
            category: .policy,
            title: "Old violation",
            message: "Generation one",
            projectID: projectID,
            projectGeneration: 1,
            severity: .warning
        )
        let unproven = RigActivityEntry(
            id: "unproven-generation",
            occurredAt: Date(),
            category: .orchestration,
            title: "Unscoped project event",
            message: "The project is known but its generation is not",
            projectID: projectID,
            projectGeneration: nil,
            severity: .informational
        )
        let publicSnapshot = try JSONDecoder().decode(OperatorSnapshot.self, from: Data("""
        {
          "events":[{
            "sequence":9,"event_id":"prior-generation-public-event",
            "timestamp":"2026-01-01T00:00:01Z","kind":"run_progressed",
            "summary":"Generation is not proven by the public projection","severity":"info",
            "project_id":"\(projectID)"
          }]
        }
        """.utf8))

        let result = RigOperationalSnapshot.compose(
            operatorSnapshot: publicSnapshot,
            autonomy: nil,
            runeForge: nil,
            progressProject: project,
            priorActivity: [stale, unproven]
        )

        XCTAssertTrue(result.activityFeed.isEmpty)
    }

    func testComposeUsesDurableSequenceForSameSecondManagedActivityOrdering() throws {
        let projectID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let project = try JSONDecoder().decode(OperatorProject.self, from: Data("""
        {
          "project_id":"\(projectID)","display_name":"Ordering Project",
          "canonical_root":"/tmp/ordering","project_generation":1,
          "lifecycle_state":"active","bindings":[],"memory":{"state":"ready"},
          "continuity":{"state":"ready"},"migration_warnings":[]
        }
        """.utf8))
        let snapshot = try JSONDecoder().decode(OperatorSnapshot.self, from: Data("""
        {
          "runs":[{
            "run_id":"\(runID)","project_id":"\(projectID)","project_generation":1,
            "mission":"Verify event ordering","state":"running",
            "continuity_mode":"automatic"
          }],
          "events":[
            {"sequence":42,"event_id":"completed","timestamp":"2026-01-01T00:00:01Z",
             "kind":"managed_activity_tool_completed","summary":"completed","severity":"info",
             "project_id":"\(projectID)","project_generation":1,"run_id":"\(runID)"},
            {"sequence":41,"event_id":"executing","timestamp":"2026-01-01T00:00:01Z",
             "kind":"managed_activity_tool_executing","summary":"executing","severity":"info",
             "project_id":"\(projectID)","project_generation":1,"run_id":"\(runID)"}
          ]
        }
        """.utf8))

        let result = RigOperationalSnapshot.compose(
            operatorSnapshot: snapshot,
            autonomy: nil,
            runeForge: nil,
            progressProject: project
        )

        XCTAssertEqual(
            result.activityFeed.filter { $0.id.hasPrefix("operator:") }.map(\.id),
            ["operator:completed", "operator:executing"]
        )
    }

    private func operatorSnapshot(
        projectID: String,
        runID: String,
        assistantMessage: String,
        turnTimestamp: String
    ) throws -> OperatorSnapshot {
        let assistantData = try JSONEncoder().encode(assistantMessage)
        let assistantJSON = try XCTUnwrap(String(data: assistantData, encoding: .utf8))
        return try JSONDecoder().decode(OperatorSnapshot.self, from: Data("""
        {
          "runs":[{
            "run_id":"\(runID)","project_id":"\(projectID)","project_generation":1,
            "mission":"Monitor the run","state":"running","continuity_mode":"automatic",
            "current_phase":"Implementation","work_item":"Add managed activity",
            "next_action":"Run verification","last_assistant_message":\(assistantJSON),
            "last_model_turn_id":"\(UUID().uuidString)",
            "last_model_turn_kind":"normal_continuation","last_model_turn_state":"completed",
            "last_model_turn_at":"\(turnTimestamp)",
            "last_tool_invocation_id":"\(UUID().uuidString)",
            "last_tool_name":"project_memory.search","last_tool_state":"completed",
            "last_tool_summary":"Found matching project context",
            "last_tool_activity_at":"\(turnTimestamp)","updated_at":"\(turnTimestamp)"
          }],
          "events":[{
            "event_id":"event-1","timestamp":"2026-01-01T00:00:01Z",
            "kind":"run_progressed","summary":"Managed run advanced","severity":"info",
            "project_id":"\(projectID)","project_generation":1,"run_id":"\(runID)"
          }]
        }
        """.utf8))
    }

    private func policySnapshot(event: PolicyViolationEvent) -> StjornarvaldManagerSnapshot {
        let sourceID = event.candidate.rule.source.sourceID
        return StjornarvaldManagerSnapshot(
            schemaVersion: StjornarvaldManagerSnapshot.schemaVersion,
            health: StjornarvaldManagerHealth(
                state: .running,
                policyIdentity: "fixture-policy",
                evaluatorID: "fixture-evaluator",
                startedAt: event.occurredAt,
                lastEvaluationAt: event.occurredAt,
                lastCommittedCursor: event.sequence,
                processedObservationCount: 1,
                indexedSourceBatchCount: 1,
                consecutiveFailureCount: 0,
                lastError: nil
            ),
            governingPolicy: GoverningPolicyIdentity(
                bindingID: "fixture-policy",
                authority: "Fixture",
                repositoryURL: "https://example.invalid/policy",
                version: "1",
                revision: "fixture",
                sourceID: sourceID
            ),
            sources: [],
            violationEvents: [event],
            nextEventCursor: nil,
            limitations: []
        )
    }

    private func policyEvent(projectID: String, occurredAt: Date) -> PolicyViolationEvent {
        let sourceID = PolicySourceID()
        let rule = PolicyRule(
            id: PolicyRuleID("fixture-native-rule"),
            source: PolicySourceReference(
                sourceID: sourceID,
                revision: "fixture",
                path: "/tmp/policy.md",
                locator: "line 12"
            ),
            statement: "Keep the shipping runtime native.",
            policyArea: "runtime",
            applicability: "fixture",
            confidence: 1
        )
        return PolicyViolationEvent(
            schemaVersion: "1.0.0",
            sequence: 1,
            id: UUID(),
            type: .opened,
            occurredAt: occurredAt,
            violationID: PolicyViolationID(),
            fingerprint: "fixture-fingerprint",
            candidate: PolicyViolationCandidate(
                rule: rule,
                observationID: UUID(),
                scope: DevelopmentObservationScope(
                    projectID: projectID,
                    projectGeneration: 1
                ),
                subjectIdentity: "fixture-subject",
                summary: "Unapproved runtime observed",
                evidenceReferences: ["Sources/Fixture.swift:12"],
                explanation: "The runtime is outside the approved native stack.",
                confidence: 0.95,
                assumptions: ["The source is a shipping target."],
                alternatives: ["Use the native framework."],
                suggestedCorrection: "Replace the runtime with the native framework."
            ),
            noticeState: "presented",
            priorEventSHA256: nil,
            eventSHA256: String(repeating: "a", count: 64),
            developmentContinues: true
        )
    }
}

@MainActor
final class AutonomyTaskDeletionAppTests: XCTestCase {
    func testDeletionIsAvailableOnlyForTerminalTasks() throws {
        let client = UnavailableOperatorManagerClient(reason: "fixture")
        let viewModel = AutonomyViewModel(client: client)
        XCTAssertTrue(viewModel.canDelete(try run(state: "completed")))
        XCTAssertTrue(viewModel.canDelete(try run(state: "cancelled")))
        XCTAssertTrue(viewModel.canDelete(try run(state: "failed_terminal")))
        XCTAssertFalse(viewModel.canDelete(try run(state: "running")))
        XCTAssertFalse(viewModel.canDelete(try run(state: "paused")))
        XCTAssertFalse(viewModel.canDelete(try run(state: "blocked_configuration")))
    }

    private func run(state: String) throws -> OperatorRun {
        try JSONDecoder().decode(
            OperatorRun.self,
            from: Data("""
            {
              "run_id":"\(UUID().uuidString)",
              "project_id":"\(UUID().uuidString)",
              "project_generation":1,
              "mission":"Deletion fixture",
              "state":"\(state)",
              "continuity_mode":"managedAutonomous"
            }
            """.utf8)
        )
    }
}

@MainActor
final class AppBackgroundOperationAppTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Background action did not reach its bounded postcondition")
    }

    func testCommittedExportWinsCancellationAndDuplicateActionIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-native-export-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BootstrapProbe()
        let operation = AppBackgroundOperation()
        var result: Result<DiagnosticLog.ExportResult, Error>?
        XCTAssertTrue(operation.start {
            _ = probe.started()
            try probe.waitForRelease()
            let paths = AppPaths(home: directory)
            let diagnostics = DiagnosticLog(paths: paths)
            diagnostics.info("native_export_fixture", ["count": "1"], category: .diagnostics)
            return try diagnostics.export(basename: "native-action-export")
        } completion: { value in
            XCTAssertTrue(Thread.isMainThread)
            result = value
        })
        try await waitUntil { probe.startCount == 1 }
        XCTAssertNil(result, "Main actor must remain available while the worker is parked")
        XCTAssertFalse(probe.ranOnMain)
        XCTAssertFalse(operation.start(work: { 2 }, completion: { _ in XCTFail("Duplicate export admitted") }))
        operation.cancel()
        XCTAssertTrue(operation.isRunning, "Cancellation must retain admission until the worker finishes")
        probe.release.signal()
        await operation.stop()
        let exported = try XCTUnwrap(result).get()
        XCTAssertFalse(operation.isRunning)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported.jsonURL)) as? [String: Any])
        XCTAssertEqual(json["record_count"] as? Int, 1)
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(records.first?["event"] as? String, "native_export_fixture")
        XCTAssertTrue(try String(contentsOf: exported.markdownURL, encoding: .utf8).contains("native_export_fixture"))
    }

    func testCooperativeCancellationAndFailureEachAllowRetryAfterCompletion() async throws {
        let probe = BootstrapProbe()
        let operation = AppBackgroundOperation()
        var cancelled = false
        XCTAssertTrue(operation.start {
            _ = probe.started()
            try await Task.sleep(for: .seconds(10))
            return 1
        } completion: { result in
            guard case .failure(is CancellationError) = result else { return XCTFail("Cancellation was lost") }
            cancelled = true
        })
        try await waitUntil { probe.startCount == 1 }
        await operation.stop()
        XCTAssertTrue(cancelled)
        var failed = false
        XCTAssertTrue(operation.start(work: { () throws -> Int in
            throw BootstrapFixtureError.expectedFailure
        }, completion: { result in
            guard case .failure(BootstrapFixtureError.expectedFailure) = result else { return XCTFail("Failure was lost") }
            failed = true
        }))
        try await waitUntil { failed }
        var completed = false
        XCTAssertTrue(operation.start(work: { 3 }, completion: { result in
            XCTAssertEqual(try? result.get(), 3)
            completed = true
        }))
        try await waitUntil { completed }
        XCTAssertFalse(operation.isRunning)
    }

    func testReleasedOwnerCancelsWorkAndDoesNotReceiveCompletion() async throws {
        let probe = BootstrapProbe()
        var operation: AppBackgroundOperation? = AppBackgroundOperation()
        weak let released = operation
        operation?.start {
            _ = probe.started()
            do {
                try await Task.sleep(for: .seconds(10))
                XCTFail("Owner release did not cancel worker")
            } catch is CancellationError {
                _ = probe.started()
            }
            return 1
        } completion: { _ in XCTFail("Released owner received completion") }
        try await waitUntil { probe.startCount == 1 }
        operation = nil
        XCTAssertNil(released)
        try await waitUntil { probe.startCount == 2 }
    }
}

import Foundation
import XCTest
@testable import ForgeConductorCore

final class ManagedAutonomyRuntimeTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-managed-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testDurableRunStartIdentityActivatesOnlyOnFirstExactAcceptance() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(),
            displayName: "Run Identity Fixture",
            canonicalRoot: projectRoot
        )
        let runID = RunID()
        let request = managedRuntimeRunRequest(
            projectID: project.projectID,
            generation: project.generation,
            projectRoot: projectRoot,
            runID: runID
        )

        let first = try await app.projectContexts.repository.reconcileAutonomousRunStart(request)
        XCTAssertEqual(first.run.runID, runID)
        XCTAssertTrue(first.requiresActivation)

        let replay = try await app.projectContexts.repository.reconcileAutonomousRunStart(request)
        XCTAssertEqual(replay.run, first.run)
        XCTAssertFalse(replay.requiresActivation)

        let conflict = managedRuntimeRunRequest(
            projectID: project.projectID,
            generation: project.generation,
            projectRoot: projectRoot,
            runID: runID,
            mission: "A different request must not reuse the accepted run identity"
        )
        do {
            _ = try await app.projectContexts.repository.reconcileAutonomousRunStart(conflict)
            XCTFail("A client run identity must bind to one immutable request")
        } catch let error as AutonomyError {
            XCTAssertEqual(error, .runConflict(runID))
        }
    }

    func testManagerRecoversDurableRunBeforeDashboardAndCompletesThroughProductionComposition() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let projectRoot = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        _ = try app.config.update(["allowed_roots": [projectRoot.path]], save: true)
        let fixtureURL = projectRoot.appendingPathComponent("fixture.txt")
        try Data("durable manager fixture\n".utf8).write(to: fixtureURL, options: .atomic)

        let provider = ManagedRuntimeFixtureProvider(fixturePath: fixtureURL.path)
        let registry = managedRuntimeFixtureRegistry(provider: provider)
        let node = ManagerNode(app: app) { app in
            try ManagedAutonomyRuntime(
                app: app,
                registry: registry,
                managerID: "managed-runtime-recovery",
                maximumConcurrentRuns: 1
            )
        }
        defer {
            node.shutdownManagedAutonomy()
            app.shutdown()
        }

        let registered = try node.registerProject(path: projectRoot.path)
        let projectID = try ProjectID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(registered["project_id"] as? String)
        )))
        let generation = ProjectGeneration(try projectGeneration(registered))
        let run = try await app.projectContexts.repository.createAutonomousRun(
            managedRuntimeRunRequest(
                projectID: projectID,
                generation: generation,
                projectRoot: projectRoot
            )
        )

        XCTAssertFalse(node.isServiceActive())
        let report = try XCTUnwrap(node.recoverManagedAutonomy())
        XCTAssertEqual(report.discoveredRuns, 1)
        XCTAssertEqual(report.activatedRuns, [run.runID])
        XCTAssertFalse(node.isServiceActive())

        let completed = try await waitForRun(node: node, runID: run.runID, state: .completed)
        XCTAssertEqual(completed["state"] as? String, AutonomousRunState.completed.rawValue)
        let snapshot = await provider.snapshot()
        XCTAssertEqual(snapshot.rootCalls, 1)
        XCTAssertEqual(snapshot.continuationCalls, 1)
        XCTAssertEqual(snapshot.previousResponseID, "resp-manager-root")
        XCTAssertTrue(snapshot.receivedToolOutput)
    }

    func testAutonomousRunContinuesWhenDashboardServiceIsStopped() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        try app.config.update([
            "dashboard": ["port": Int.random(in: 29_000...39_000)] as [String: Any],
        ], save: true)
        let projectRoot = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        _ = try app.config.update(["allowed_roots": [projectRoot.path]], save: true)
        let fixtureURL = projectRoot.appendingPathComponent("fixture.txt")
        try Data("dashboard-independent fixture\n".utf8).write(to: fixtureURL, options: .atomic)

        let provider = ManagedRuntimeFixtureProvider(
            fixturePath: fixtureURL.path,
            rootDelay: .milliseconds(200)
        )
        let registry = managedRuntimeFixtureRegistry(provider: provider)
        let node = ManagerNode(app: app) { app in
            try ManagedAutonomyRuntime(
                app: app,
                registry: registry,
                managerID: "managed-runtime-dashboard-independent",
                maximumConcurrentRuns: 1
            )
        }
        defer {
            node.shutdownManagedAutonomy()
            app.shutdown()
        }

        let registered = try node.registerProject(path: projectRoot.path)
        let projectID = try ProjectID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(registered["project_id"] as? String)
        )))
        let generation = ProjectGeneration(try projectGeneration(registered))
        _ = try node.recoverManagedAutonomy()
        _ = try node.startService()
        let started = try node.startAutonomousRun(
            projectID: projectID,
            expectedGeneration: generation,
            mission: "Read the fixture and provide deterministic completion evidence",
            providerID: "fixture-provider",
            adapterID: "fixture-adapter",
            modelKey: "fixture-model",
            allowedTools: ["fs_read"],
            completionGates: ["fixture_read"]
        )
        let runIDValue = (started["run_id"] ?? started["runID"]) as? String
        let runID = try RunID(XCTUnwrap(UUID(
            uuidString: try XCTUnwrap(runIDValue)
        )))

        _ = try node.stopService()
        XCTAssertFalse(node.isServiceActive())
        let completed = try await waitForRun(node: node, runID: runID, state: .completed)
        XCTAssertEqual(completed["state"] as? String, AutonomousRunState.completed.rawValue)
        XCTAssertFalse(node.isServiceActive())
    }

    func testOperatorPauseResumeAndCancelAreDurableManagerControls() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let fixtureURL = projectRoot.appendingPathComponent("fixture.txt")
        try Data("operator control fixture\n".utf8).write(to: fixtureURL, options: .atomic)
        let projectID = ProjectID()
        let registered = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: projectID,
            displayName: "Operator Control Fixture",
            canonicalRoot: projectRoot
        )
        let provider = ManagedRuntimeFixtureProvider(
            fixturePath: fixtureURL.path,
            rootDelay: .milliseconds(150)
        )
        let runtime = try ManagedAutonomyRuntime(
            app: app,
            registry: managedRuntimeFixtureRegistry(provider: provider),
            managerID: "managed-runtime-controls",
            maximumConcurrentRuns: 1
        )
        _ = try await runtime.start()

        let pausedRun = try await runtime.createRun(managedRuntimeRunRequest(
            projectID: registered.projectID,
            generation: registered.generation,
            projectRoot: projectRoot
        ))
        let paused = try await runtime.controlRun(pausedRun.runID, action: .pause)
        XCTAssertEqual(paused.state, AutonomousRunState.paused)
        XCTAssertNotNil(paused.specification.work.metadata["paused_from_state"])
        let resumed = try await runtime.controlRun(pausedRun.runID, action: .resume)
        XCTAssertNotEqual(resumed.state, AutonomousRunState.paused)
        let completed = try await waitForRun(
            repository: app.projectContexts.repository,
            runID: pausedRun.runID,
            state: .completed
        )
        XCTAssertEqual(completed.state, AutonomousRunState.completed)

        let cancelledRun = try await runtime.createRun(managedRuntimeRunRequest(
            projectID: registered.projectID,
            generation: registered.generation,
            projectRoot: projectRoot
        ))
        let cancelRequested = try await runtime.controlRun(cancelledRun.runID, action: .cancel)
        XCTAssertEqual(cancelRequested.state, AutonomousRunState.cancelRequested)
        let cancelled = try await waitForRun(
            repository: app.projectContexts.repository,
            runID: cancelledRun.runID,
            state: .cancelled
        )
        XCTAssertEqual(cancelled.state, AutonomousRunState.cancelled)
        await runtime.shutdown()
    }

    func testOperatorCheckpointUsesExactCurrentObservationAndReactivatesContinuity() async throws {
        try await assertOperatorContinuityControl(
            action: .checkpoint,
            expectedState: .checkpointing,
            expectedBudgetAction: .checkpoint,
            expectedEvent: "autonomous_run_operator_checkpoint_requested"
        )
    }

    func testOperatorRolloverUsesExactCurrentObservationAndReactivatesContinuity() async throws {
        try await assertOperatorContinuityControl(
            action: .rollover,
            expectedState: .rollingOver,
            expectedBudgetAction: .rollover,
            expectedEvent: "autonomous_run_operator_rollover_requested"
        )
    }

    func testOperatorContinuityRejectsAmbiguousPendingProviderIntentWithoutMutation() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let recorder = ManagedRuntimeOperatorContinuityRecorder()
        let runtime = try ManagedAutonomyRuntime(
            app: app,
            managerID: "managed-runtime-operator-rejection",
            maximumConcurrentRuns: 1,
            continuityFactory: { _ in recorder }
        )
        _ = try await runtime.start()
        let fixture = try await makeOperatorReadyRun(app: app, label: "unsafe-pending-intent")
        let lease = try await app.projectContexts.repository.acquireRunLease(
            runID: fixture.run.runID,
            ownerID: "operator-rejection-fixture"
        )
        let intent = RunSideEffectIntent(
            kind: .providerTurn,
            idempotencyKey: "operator-rejection-provider-turn",
            payloadSHA256: JSONSupport.sha256Hex("operator-rejection-provider-turn"),
            summary: "Ambiguous provider turn must be reconciled before operator continuity"
        )
        _ = try await app.projectContexts.repository.persistRunSideEffectIntent(
            runID: fixture.run.runID,
            lease: lease,
            expectedRevision: fixture.run.revision,
            intent: intent
        )
        _ = try await app.projectContexts.repository.releaseRunLease(lease)

        do {
            _ = try await runtime.controlRun(fixture.run.runID, action: .checkpoint)
            XCTFail("Expected an ambiguous provider turn to reject operator continuity")
        } catch let error as AutonomyError {
            guard case .invalidRequest = error else {
                return XCTFail("Unexpected operator-control error: \(error)")
            }
        }

        let unchangedValue = try await app.projectContexts.repository.autonomousRun(
            fixture.run.runID
        )
        let unchanged = try XCTUnwrap(unchangedValue)
        XCTAssertEqual(unchanged.state, .running)
        XCTAssertEqual(unchanged.activeSessionID, fixture.sessionID)
        XCTAssertEqual(unchanged.specification.work.pendingIntent, intent)
        let request = try await app.projectContexts.repository.pendingContextBudgetActionRequest(
            runID: fixture.run.runID
        )
        XCTAssertNil(request)
        let recordedCalls = await recorder.snapshot()
        XCTAssertTrue(recordedCalls.isEmpty)
        await runtime.shutdown()
    }

    func testOperatorContinuityFailsClosedWithoutExactCurrentBudgetObservation() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let recorder = ManagedRuntimeOperatorContinuityRecorder()
        let runtime = try ManagedAutonomyRuntime(
            app: app,
            managerID: "managed-runtime-operator-no-observation",
            maximumConcurrentRuns: 1,
            continuityFactory: { _ in recorder }
        )
        _ = try await runtime.start()
        let fixture = try await makeOperatorRunningRun(app: app, label: "no-observation")

        do {
            _ = try await runtime.controlRun(fixture.run.runID, action: .rollover)
            XCTFail("Expected missing current budget evidence to reject operator rollover")
        } catch let error as ContextBudgetError {
            XCTAssertEqual(error, .currentObservationRequired)
        }

        let unchangedValue = try await app.projectContexts.repository.autonomousRun(
            fixture.run.runID
        )
        let unchanged = try XCTUnwrap(unchangedValue)
        XCTAssertEqual(unchanged.state, .running)
        XCTAssertEqual(unchanged.activeSessionID, fixture.sessionID)
        XCTAssertNil(unchanged.specification.work.metadata["operator_continuity_action"])
        let recordedCalls = await recorder.snapshot()
        XCTAssertTrue(recordedCalls.isEmpty)
        await runtime.shutdown()
    }

    func testManagerRestartMaterializesDurableOperatorCheckpointBeforeContinuityAdvances() async throws {
        let firstApp = try ForgeApp.bootstrap(home: home)
        let blockerRoot = home.appendingPathComponent("restart-blocker", isDirectory: true)
        try FileManager.default.createDirectory(at: blockerRoot, withIntermediateDirectories: true)
        let blockerFile = blockerRoot.appendingPathComponent("fixture.txt")
        try Data("restart blocker\n".utf8).write(to: blockerFile, options: .atomic)
        let blockerProject = try await firstApp.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(),
            displayName: "Restart Blocker",
            canonicalRoot: blockerRoot
        )
        let provider = ManagedRuntimeFixtureProvider(
            fixturePath: blockerFile.path,
            rootDelay: .seconds(30)
        )
        let firstRecorder = ManagedRuntimeOperatorContinuityRecorder()
        let firstRuntime = try ManagedAutonomyRuntime(
            app: firstApp,
            registry: managedRuntimeFixtureRegistry(provider: provider),
            managerID: "managed-runtime-operator-restart-first",
            maximumConcurrentRuns: 1,
            continuityFactory: { _ in firstRecorder }
        )
        _ = try await firstRuntime.start()
        let blocker = try await firstRuntime.createRun(managedRuntimeRunRequest(
            projectID: blockerProject.projectID,
            generation: blockerProject.generation,
            projectRoot: blockerRoot
        ))
        try await waitForActiveRun(runtime: firstRuntime, runID: blocker.runID)

        let target = try await makeOperatorReadyRun(app: firstApp, label: "restart-target")
        let transitioned = try await firstRuntime.controlRun(
            target.run.runID,
            action: .checkpoint
        )
        XCTAssertEqual(transitioned.state, .checkpointing)
        let beforeRestart = try await firstApp.projectContexts.repository
            .pendingContextBudgetActionRequest(runID: target.run.runID)
        XCTAssertNil(beforeRestart, "deferred activation must leave the restart seam unmaterialized")
        let firstSnapshot = await firstRuntime.snapshot()
        XCTAssertTrue(firstSnapshot.supervisor.deferredRunIDs.contains(target.run.runID))

        await firstRuntime.shutdown()
        let stoppedBlockerValue = try await firstApp.projectContexts.repository.autonomousRun(
            blocker.runID
        )
        let stoppedBlocker = try XCTUnwrap(stoppedBlockerValue)
        let blockerLease = try await firstApp.projectContexts.repository.acquireRunLease(
            runID: blocker.runID,
            ownerID: "operator-restart-pause-blocker"
        )
        _ = try await firstApp.projectContexts.repository.transitionAutonomousRun(
            runID: blocker.runID,
            lease: blockerLease,
            transition: AutonomousRunTransition(
                expectedState: stoppedBlocker.state,
                expectedRevision: stoppedBlocker.revision,
                nextState: .paused,
                eventType: "operator_restart_fixture_paused",
                eventSummary: "Pause the restart fixture before manager recovery"
            )
        )
        _ = try await firstApp.projectContexts.repository.releaseRunLease(blockerLease)
        firstApp.shutdown()

        let secondApp = try ForgeApp.bootstrap(home: home)
        defer { secondApp.shutdown() }
        let secondRecorder = ManagedRuntimeOperatorContinuityRecorder()
        let secondRuntime = try ManagedAutonomyRuntime(
            app: secondApp,
            registry: managedRuntimeFixtureRegistry(provider: provider),
            managerID: "managed-runtime-operator-restart-second",
            maximumConcurrentRuns: 1,
            continuityFactory: { _ in secondRecorder }
        )
        let report = try await secondRuntime.start()
        XCTAssertTrue(report.activatedRuns.contains(target.run.runID))
        try await waitForOperatorContinuity(recorder: secondRecorder, count: 1)

        let requestValue = try await secondApp.projectContexts.repository
            .pendingContextBudgetActionRequest(runID: target.run.runID)
        let request = try XCTUnwrap(requestValue)
        XCTAssertEqual(request.requestedAction, .checkpoint)
        XCTAssertEqual(request.identity.runID, target.run.runID)
        XCTAssertEqual(request.identity.projectID, target.run.projectID)
        XCTAssertEqual(request.identity.projectGeneration, target.run.projectGeneration)
        XCTAssertEqual(request.identity.sessionID, target.sessionID)
        XCTAssertEqual(request.actionEpoch, target.observation.actionEpoch + 1)
        let recoveredObservationValue = try await secondApp.projectContexts.repository
            .contextBudgetObservation(observationID: request.observationID)
        let recoveredObservation = try XCTUnwrap(recoveredObservationValue)
        assertOperatorObservation(recoveredObservation, preserves: target.observation)

        await secondRecorder.release()
        _ = try await waitForRun(
            repository: secondApp.projectContexts.repository,
            runID: target.run.runID,
            state: .running
        )
        await secondRuntime.shutdown()
    }

    func testHTTPRunControlRoutePersistsExactActionsAndRejectsUnknownActions() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 29_000...39_000)
        try app.config.update([
            "dashboard": ["port": port] as [String: Any],
        ], save: true)
        let projectRoot = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        _ = try app.config.update(["allowed_roots": [projectRoot.path]], save: true)
        let fixtureURL = projectRoot.appendingPathComponent("fixture.txt")
        try Data("HTTP control fixture\n".utf8).write(to: fixtureURL, options: .atomic)
        let provider = ManagedRuntimeFixtureProvider(
            fixturePath: fixtureURL.path,
            rootDelay: .seconds(2)
        )
        let node = ManagerNode(app: app) { app in
            try ManagedAutonomyRuntime(
                app: app,
                registry: managedRuntimeFixtureRegistry(provider: provider),
                managerID: "managed-runtime-http-controls",
                maximumConcurrentRuns: 1
            )
        }
        defer {
            node.shutdownManagedAutonomy()
            _ = try? node.stopService()
            app.shutdown()
        }

        let registered = try node.registerProject(path: projectRoot.path)
        let projectID = try XCTUnwrap(registered["project_id"] as? String)
        let generation = try projectGeneration(registered)
        _ = try node.recoverManagedAutonomy()
        _ = try node.startService()
        try await Task.sleep(for: .milliseconds(100))
        let bearerToken = try ManagerControlCredentialStore(paths: app.paths).bearerToken()

        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/manager/runs/start"))
        let requestedRunID = UUID().uuidString.lowercased()
        let startRequest: [String: Any] = [
            "run_id": requestedRunID,
            "project_id": projectID,
            "project_generation": generation,
            "mission": "Exercise the exact manager control route",
            "provider_id": "fixture-provider",
            "adapter_id": "fixture-adapter",
            "model_key": "fixture-model",
            "allowed_tools": ["fs_read"],
            "completion_gates": ["fixture_read"],
        ]
        let unauthorizedStart = try postJSON(endpoint, object: startRequest)
        XCTAssertEqual(unauthorizedStart.status, 401)
        XCTAssertEqual(unauthorizedStart.object["code"] as? String, "manager_mutation_unauthorized")

        let invalidRunUUID = UUID()
        var invalidToolRequest = startRequest
        invalidToolRequest["run_id"] = invalidRunUUID.uuidString.lowercased()
        invalidToolRequest["allowed_tools"] = ["project.memory.search"]
        let invalidToolStart = try postJSON(
            endpoint,
            object: invalidToolRequest,
            bearerToken: bearerToken
        )
        XCTAssertEqual(invalidToolStart.status, 422)
        XCTAssertEqual(
            invalidToolStart.object["code"] as? String,
            "autonomy_tool_configuration_invalid"
        )
        XCTAssertEqual(invalidToolStart.object["retryable"] as? Bool, false)
        XCTAssertTrue(
            (invalidToolStart.object["message"] as? String)?.contains("project.memory.search") == true
        )
        let rejectedDurableRun = try await app.projectContexts.repository.autonomousRun(
            RunID(invalidRunUUID)
        )
        XCTAssertNil(
            rejectedDurableRun,
            "An invalid tool policy must be rejected before the run is durably created"
        )

        let started = try postJSON(endpoint, object: startRequest, bearerToken: bearerToken)
        XCTAssertEqual(started.status, 202)
        XCTAssertEqual(started.object["run_id"] as? String, requestedRunID)
        XCTAssertEqual(started.object["mission"] as? String, "Exercise the exact manager control route")
        XCTAssertEqual(started.object["continuity_mode"] as? String, ContinuityMode.managedAutonomous.rawValue)
        XCTAssertEqual(started.object["provider_id"] as? String, "fixture-provider")
        XCTAssertEqual(started.object["model_key"] as? String, "fixture-model")
        let runID = try XCTUnwrap(started.object["run_id"] as? String)

        let controlEndpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/api/manager/runs/control")
        )
        let unauthorizedControl = try postJSON(controlEndpoint, object: [
            "run_id": runID,
            "action": "pause",
        ])
        XCTAssertEqual(unauthorizedControl.status, 401)

        let paused = try postJSON(controlEndpoint, object: [
            "run_id": runID,
            "action": "pause",
        ], bearerToken: bearerToken)
        XCTAssertEqual(paused.status, 200)
        XCTAssertEqual(paused.object["state"] as? String, AutonomousRunState.paused.rawValue)

        let reconciled = try postJSON(endpoint, object: startRequest, bearerToken: bearerToken)
        XCTAssertEqual(reconciled.status, 202)
        XCTAssertEqual(reconciled.object["run_id"] as? String, requestedRunID)
        XCTAssertEqual(reconciled.object["state"] as? String, AutonomousRunState.paused.rawValue)
        let durableRuns = try await app.projectContexts.repository.operatorAutonomousRuns(limit: 10)
        XCTAssertEqual(durableRuns.filter { $0.runID.description == requestedRunID }.count, 1)

        let statusEndpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/api/manager/runs/status")
        )
        let readOnlyStatus = try postJSON(statusEndpoint, object: ["run_id": runID])
        XCTAssertEqual(readOnlyStatus.status, 200)
        XCTAssertEqual(readOnlyStatus.object["run_id"] as? String, requestedRunID)

        let rejected = try postJSON(controlEndpoint, object: [
            "run_id": runID,
            "action": "restart",
        ], bearerToken: bearerToken)
        XCTAssertEqual(rejected.status, 400)
        XCTAssertEqual(rejected.object["code"] as? String, "invalid_run_control")

        let resumed = try postJSON(controlEndpoint, object: [
            "run_id": runID,
            "action": "resume",
        ], bearerToken: bearerToken)
        XCTAssertEqual(resumed.status, 200)
        XCTAssertNotEqual(resumed.object["state"] as? String, AutonomousRunState.paused.rawValue)

        let cancelled = try postJSON(controlEndpoint, object: [
            "run_id": runID,
            "action": "cancel",
        ], bearerToken: bearerToken)
        XCTAssertEqual(cancelled.status, 200)
        XCTAssertEqual(
            cancelled.object["state"] as? String,
            AutonomousRunState.cancelRequested.rawValue
        )
    }

    func testHTTPRunControlRouteInvokesCheckpointAndRolloverWithManagerOwnedEligibility() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 29_000...39_000)
        try app.config.update([
            "dashboard": ["port": port] as [String: Any],
        ], save: true)
        let recorder = ManagedRuntimeOperatorContinuityRecorder()
        let node = ManagerNode(app: app) { app in
            try ManagedAutonomyRuntime(
                app: app,
                managerID: "managed-runtime-http-continuity-controls",
                maximumConcurrentRuns: 2,
                continuityFactory: { _ in recorder }
            )
        }
        defer {
            node.shutdownManagedAutonomy()
            _ = try? node.stopService()
            app.shutdown()
        }

        _ = try node.recoverManagedAutonomy()
        _ = try node.startService()
        try await Task.sleep(for: .milliseconds(100))
        let bearerToken = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        let controlEndpoint = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/api/manager/runs/control")
        )
        let checkpointFixture = try await makeOperatorReadyRun(
            app: app,
            label: "http-checkpoint"
        )
        let rolloverFixture = try await makeOperatorReadyRun(
            app: app,
            label: "http-rollover"
        )
        let missingObservationFixture = try await makeOperatorRunningRun(
            app: app,
            label: "http-no-observation"
        )

        let checkpoint = try postJSON(controlEndpoint, object: [
            "run_id": checkpointFixture.run.runID.description,
            "action": "checkpoint",
        ], bearerToken: bearerToken)
        XCTAssertEqual(checkpoint.status, 200)
        XCTAssertEqual(
            checkpoint.object["run_id"] as? String,
            checkpointFixture.run.runID.description
        )
        XCTAssertEqual(
            checkpoint.object["state"] as? String,
            AutonomousRunState.checkpointing.rawValue
        )

        let rollover = try postJSON(controlEndpoint, object: [
            "run_id": rolloverFixture.run.runID.description,
            "action": "rollover",
        ], bearerToken: bearerToken)
        XCTAssertEqual(rollover.status, 200)
        XCTAssertEqual(
            rollover.object["run_id"] as? String,
            rolloverFixture.run.runID.description
        )
        XCTAssertEqual(
            rollover.object["state"] as? String,
            AutonomousRunState.rollingOver.rawValue
        )

        try await waitForOperatorContinuity(recorder: recorder, count: 2)
        let calls = await recorder.snapshot()
        XCTAssertEqual(
            Set(calls.map(\.runID)),
            Set([checkpointFixture.run.runID, rolloverFixture.run.runID])
        )
        XCTAssertEqual(
            calls.first(where: { $0.runID == checkpointFixture.run.runID })?.state,
            .checkpointing
        )
        XCTAssertEqual(
            calls.first(where: { $0.runID == rolloverFixture.run.runID })?.state,
            .rollingOver
        )

        let checkpointRequestValue = try await app.projectContexts.repository
            .pendingContextBudgetActionRequest(runID: checkpointFixture.run.runID)
        let checkpointRequest = try XCTUnwrap(checkpointRequestValue)
        XCTAssertEqual(checkpointRequest.requestedAction, .checkpoint)
        XCTAssertEqual(checkpointRequest.identity.sessionID, checkpointFixture.sessionID)
        let rolloverRequestValue = try await app.projectContexts.repository
            .pendingContextBudgetActionRequest(runID: rolloverFixture.run.runID)
        let rolloverRequest = try XCTUnwrap(rolloverRequestValue)
        XCTAssertEqual(rolloverRequest.requestedAction, .rollover)
        XCTAssertEqual(rolloverRequest.identity.sessionID, rolloverFixture.sessionID)

        let rejected = try postJSON(controlEndpoint, object: [
            "run_id": missingObservationFixture.run.runID.description,
            "action": "rollover",
        ], bearerToken: bearerToken)
        XCTAssertEqual(rejected.status, 409)
        XCTAssertEqual(rejected.object["code"] as? String, "context_observation_required")
        XCTAssertEqual(
            rejected.object["message"] as? String,
            "A current usage observation is required"
        )
        let unchangedValue = try await app.projectContexts.repository.autonomousRun(
            missingObservationFixture.run.runID
        )
        let unchanged = try XCTUnwrap(unchangedValue)
        XCTAssertEqual(unchanged.state, .running)
        XCTAssertEqual(unchanged.activeSessionID, missingObservationFixture.sessionID)
        let rejectedRequest = try await app.projectContexts.repository
            .pendingContextBudgetActionRequest(runID: missingObservationFixture.run.runID)
        XCTAssertNil(rejectedRequest)

        let invalid = try postJSON(controlEndpoint, object: [
            "run_id": checkpointFixture.run.runID.description,
            "action": "restart",
        ], bearerToken: bearerToken)
        XCTAssertEqual(invalid.status, 400)
        XCTAssertEqual(invalid.object["code"] as? String, "invalid_run_control")
        let validationMessage = try XCTUnwrap(invalid.object["message"] as? String)
        XCTAssertTrue(validationMessage.contains("checkpoint"))
        XCTAssertTrue(validationMessage.contains("rollover"))

        await recorder.release()
    }

    func testRunCancellationReleasesOwnedRuntimeJobBeforeTerminalRunState() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let fixtureURL = projectRoot.appendingPathComponent("fixture.txt")
        try Data("runtime cancellation fixture\n".utf8).write(to: fixtureURL, options: .atomic)
        let projectID = ProjectID()
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: projectID,
            displayName: "Runtime Cancellation Fixture",
            canonicalRoot: projectRoot
        )
        let runtime = try ManagedAutonomyRuntime(
            app: app,
            registry: managedRuntimeFixtureRegistry(
                provider: ManagedRuntimeFixtureProvider(fixturePath: fixtureURL.path)
            ),
            managerID: "managed-runtime-job-cancellation",
            maximumConcurrentRuns: 1
        )
        _ = try await runtime.start()
        let authorizationScope = ToolAuthorizationScope(
            canonicalRoots: [projectRoot],
            allowedTools: ["bash.run", "fs_read"],
            networkAllowed: false,
            maximumInlineOutputBytes: 64 * 1_024
        )
        let run = try await app.projectContexts.repository.createAutonomousRun(
            AutonomousRunRequest(
                projectID: project.projectID,
                projectGeneration: project.generation,
                mission: "Cancel the run-owned runtime fixture",
                providerID: "fixture-provider",
                adapterID: "fixture-adapter",
                modelKey: "fixture-model",
                specification: AutonomousRunSpecification(
                    allowedTools: ["bash.run", "fs_read"],
                    completionGates: ["fixture_read"]
                ),
                authorizationScope: authorizationScope
            )
        )
        let context = ToolInvocationContext(
            projectID: project.projectID,
            projectGeneration: project.generation,
            clientID: ClientID("runtime-cancellation-test"),
            runID: run.runID,
            authorizationScope: authorizationScope
        )
        let jobID = try await app.runtimeJobs.service.submit(RuntimeJobRequest(
            kind: .bash,
            profile: .bashNoProfile,
            context: context,
            script: "sleep 30",
            canonicalWorkingDirectory: projectRoot,
            timeout: .seconds(60),
            replayClass: .reconciled,
            idempotencyKey: "managed-runtime-job-cancellation"
        ))
        for _ in 0..<400 {
            let status = try await app.runtimeJobs.service.status(jobID: jobID, context: context)
            if status.state == .running { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        _ = try await runtime.controlRun(run.runID, action: .cancel)

        let cancelledJob = try await app.runtimeJobs.service.waitForTerminal(
            jobID: jobID,
            context: context,
            maximumWait: .seconds(2)
        )
        XCTAssertEqual(cancelledJob.state, RuntimeJobState.cancelled)
        let cancelledRun = try await waitForRun(
            repository: app.projectContexts.repository,
            runID: run.runID,
            state: .cancelled
        )
        XCTAssertEqual(cancelledRun.state, AutonomousRunState.cancelled)
        await runtime.shutdown()
    }

    func testHTTPRunResponsesMatchOperatorSnapshotProjectionAndPreserveCompletionReceipt() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 29_000...39_000)
        try app.config.update(["dashboard": ["port": port] as [String: Any]], save: true)
        let projectRoot = home.appendingPathComponent("operator-run-contract", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        _ = try app.config.update(["allowed_roots": [projectRoot.path]], save: true)
        let fixtureURL = projectRoot.appendingPathComponent("fixture.txt")
        try Data("operator response contract\n".utf8).write(to: fixtureURL, options: .atomic)
        let provider = ManagedRuntimeFixtureProvider(fixturePath: fixtureURL.path, rootDelay: .seconds(30))
        let node = ManagerNode(app: app) { app in
            try ManagedAutonomyRuntime(
                app: app,
                registry: managedRuntimeFixtureRegistry(provider: provider),
                managerID: "managed-runtime-operator-run-contract",
                maximumConcurrentRuns: 1
            )
        }
        defer {
            node.shutdownManagedAutonomy()
            _ = try? node.stopService()
            app.shutdown()
        }

        let registered = try node.registerProject(path: projectRoot.path)
        let projectIDValue = try XCTUnwrap(registered["project_id"] as? String)
        let projectID = try ProjectID(XCTUnwrap(UUID(uuidString: projectIDValue)))
        let generation = ProjectGeneration(try projectGeneration(registered))
        let runID = RunID()
        let repository = app.projectContexts.repository
        let stagedRun = try await repository.createAutonomousRun(AutonomousRunRequest(
            runID: runID,
            projectID: projectID,
            projectGeneration: generation,
            assignmentID: "operator-contract-assignment",
            mission: "Prove one exact operator run response contract",
            providerID: "fixture-provider",
            adapterID: "fixture-adapter",
            modelKey: "fixture-model",
            specification: AutonomousRunSpecification(
                allowedTools: ["fs_read"],
                completionGates: ["fixture_read"]
            ),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [projectRoot],
                allowedTools: ["fs_read"],
                networkAllowed: false,
                maximumInlineOutputBytes: ProjectContextService.defaultInlineOutputLimit
            )
        ))
        let stagingLease = try await repository.acquireRunLease(
            runID: runID,
            ownerID: "operator-contract-staging"
        )
        _ = try await repository.transitionAutonomousRun(
            runID: runID,
            lease: stagingLease,
            transition: AutonomousRunTransition(
                expectedState: stagedRun.state,
                expectedRevision: stagedRun.revision,
                nextState: .paused,
                eventType: "operator_contract_fixture_paused",
                eventSummary: "Stage exact response fields before manager recovery"
            )
        )
        _ = try await repository.releaseRunLease(stagingLease)
        _ = try node.recoverManagedAutonomy()
        _ = try node.startService()
        try await Task.sleep(for: .milliseconds(100))
        let token = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        let base = "http://127.0.0.1:\(port)"
        let startURL = try XCTUnwrap(URL(string: base + "/api/manager/runs/start"))
        let statusURL = try XCTUnwrap(URL(string: base + "/api/manager/runs/status"))
        let controlURL = try XCTUnwrap(URL(string: base + "/api/manager/runs/control"))
        let snapshotURL = try XCTUnwrap(URL(string: base + "/api/manager/operator/snapshot?limit=100"))
        let startRequest: [String: Any] = [
            "run_id": runID.description,
            "project_id": projectID.description,
            "project_generation": generation.rawValue,
            "assignment_id": "operator-contract-assignment",
            "mission": "Prove one exact operator run response contract",
            "provider_id": "fixture-provider",
            "adapter_id": "fixture-adapter",
            "model_key": "fixture-model",
            "allowed_tools": ["fs_read"],
            "completion_gates": ["fixture_read"],
        ]
        XCTAssertEqual(
            try postJSON(startURL, object: startRequest, bearerToken: token).status,
            202
        )
        let firstPause = try postJSON(
            controlURL,
            object: ["run_id": runID.description, "action": "pause"],
            bearerToken: token
        )
        XCTAssertEqual(firstPause.status, 200)
        XCTAssertEqual(firstPause.object["state"] as? String, AutonomousRunState.paused.rawValue)

        let lease = try await repository.acquireRunLease(
            runID: runID,
            ownerID: "operator-contract-lease-owner"
        )
        let sessionID = "operator-contract-session"
        try await repository.reserveProviderSession(
            ProviderSessionIntent(
                sessionID: sessionID,
                runID: runID,
                projectID: projectID,
                projectGeneration: generation,
                providerID: "fixture-provider",
                adapterID: "fixture-adapter",
                modelKey: "fixture-model",
                providerResponseID: "operator-contract-response",
                predecessorSessionID: "operator-contract-predecessor",
                idempotencyKey: "operator-contract-session",
                contextCapacity: 32_768
            ),
            lease: lease
        )
        let identity = ContextBudgetIdentity(
            runID: runID,
            projectID: projectID,
            projectGeneration: generation,
            sessionID: sessionID
        )
        let budget = try await ContextBudgetSupervisor.open(
            repository: repository,
            identity: identity,
            configuration: try managedRuntimeOperatorBudgetConfiguration()
        )
        _ = try await budget.evaluate(ContextBudgetEvaluationRequest(
            triggerPoint: .afterProviderTurn,
            providerResponseID: "operator-contract-response",
            measurement: .providerExact(usedTokens: 2_048)
        ))
        let turn = ProviderTurnIntent(
            runID: runID,
            sessionID: sessionID,
            projectID: projectID,
            projectGeneration: generation,
            kind: .initialRoot,
            idempotencyKey: "operator-contract-turn",
            inputSHA256: JSONSupport.sha256Hex("operator-contract-input")
        )
        _ = try await repository.persistProviderTurnIntent(turn, lease: lease)
        _ = try await repository.persistToolInvocationIntent(
            ToolInvocationIntent(
                turnID: turn.turnID,
                runID: runID,
                sessionID: sessionID,
                projectID: projectID,
                projectGeneration: generation,
                providerCallID: "operator-contract-tool-call",
                toolName: "fs_read",
                replayClass: .readOnly,
                idempotencyKey: nil,
                argumentsSHA256: JSONSupport.sha256Hex("{}")
            ),
            lease: lease
        )

        let startReplay = try postJSON(startURL, object: startRequest, bearerToken: token)
        let status = try postJSON(statusURL, object: ["run_id": runID.description])
        let control = try postJSON(
            controlURL,
            object: ["run_id": runID.description, "action": "pause"],
            bearerToken: token
        )
        let pausedSnapshot = try HTTPTestHelpers.fetchJSON(snapshotURL)
        let pausedSnapshotRun = try operatorRun(runID: runID, snapshot: pausedSnapshot)
        for response in [startReplay.object, status.object, control.object] {
            XCTAssertEqual(response["ok"] as? Bool, true)
            try assertExactOperatorRunProjection(response, equals: pausedSnapshotRun)
            XCTAssertNotNil(response["revision"], "The established route revision remains additive")
        }
        XCTAssertEqual(status.object["provider_instance_id"] as? String, "fixture-instance")
        XCTAssertEqual(status.object["predecessor_session_id"] as? String, "operator-contract-predecessor")
        XCTAssertEqual(status.object["lease_owner"] as? String, "operator-contract-lease-owner")
        XCTAssertNotNil(status.object["last_model_turn_at"] as? String)
        XCTAssertNotNil(status.object["last_tool_activity_at"] as? String)

        let currentValue = try await repository.autonomousRun(runID)
        var current = try XCTUnwrap(currentValue)
        current = try await repository.transitionAutonomousRun(
            runID: runID,
            lease: lease,
            transition: AutonomousRunTransition(
                expectedState: current.state,
                expectedRevision: current.revision,
                nextState: .validatingCompletion,
                eventType: "operator_contract_completion_requested",
                eventSummary: "Validate the exact operator response receipt"
            )
        )
        let receipt = try CompletionValidationReceipt.make(
            runID: runID,
            expectedRevision: current.revision,
            results: [CompletionGateResult(
                gate: "fixture_read",
                passed: true,
                summary: "The production HTTP contract fixture passed",
                evidenceReferences: ["fixture:operator-run-contract"]
            )],
            validatedAt: ISO8601.string(from: Date())
        )
        _ = try await repository.completeAutonomousRun(runID: runID, lease: lease, receipt: receipt)

        let completedStatus = try postJSON(statusURL, object: ["run_id": runID.description])
        let completedStart = try postJSON(startURL, object: startRequest, bearerToken: token)
        let completedSnapshot = try HTTPTestHelpers.fetchJSON(snapshotURL)
        let completedSnapshotRun = try operatorRun(runID: runID, snapshot: completedSnapshot)
        XCTAssertEqual(completedStatus.object["state"] as? String, AutonomousRunState.completed.rawValue)
        XCTAssertEqual(completedStatus.object["passed_gates"] as? [String], ["fixture_read"])
        try assertExactOperatorRunProjection(completedStatus.object, equals: completedSnapshotRun)
        try assertExactOperatorRunProjection(completedStart.object, equals: completedSnapshotRun)
        XCTAssertEqual(completedStatus.object["lease_owner"] as? String, "operator-contract-lease-owner")
        _ = try await repository.releaseRunLease(lease)
    }

    private func assertOperatorContinuityControl(
        action: ManagedAutonomyControlAction,
        expectedState: AutonomousRunState,
        expectedBudgetAction: ContextBudgetAction,
        expectedEvent: String
    ) async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let recorder = ManagedRuntimeOperatorContinuityRecorder()
        let runtime = try ManagedAutonomyRuntime(
            app: app,
            managerID: "managed-runtime-operator-\(action.rawValue)",
            maximumConcurrentRuns: 1,
            continuityFactory: { _ in recorder }
        )
        _ = try await runtime.start()
        let fixture = try await makeOperatorReadyRun(app: app, label: action.rawValue)

        let controlled = try await runtime.controlRun(fixture.run.runID, action: action)
        XCTAssertEqual(controlled.state, expectedState)
        XCTAssertEqual(controlled.activeSessionID, fixture.sessionID)
        XCTAssertNil(controlled.activeOperationID)
        XCTAssertEqual(
            controlled.specification.work.metadata["operator_continuity_action"],
            expectedBudgetAction.rawValue
        )
        try await waitForOperatorContinuity(recorder: recorder, count: 1)

        let calls = await recorder.snapshot()
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.runID, fixture.run.runID)
        XCTAssertEqual(call.projectID, fixture.run.projectID)
        XCTAssertEqual(call.projectGeneration, fixture.run.projectGeneration)
        XCTAssertEqual(call.sessionID, fixture.sessionID)
        XCTAssertEqual(call.state, expectedState)

        let requestValue = try await app.projectContexts.repository
            .pendingContextBudgetActionRequest(runID: fixture.run.runID)
        let request = try XCTUnwrap(requestValue)
        XCTAssertEqual(request.requestedAction, expectedBudgetAction)
        XCTAssertEqual(request.identity.runID, fixture.run.runID)
        XCTAssertEqual(request.identity.projectID, fixture.run.projectID)
        XCTAssertEqual(request.identity.projectGeneration, fixture.run.projectGeneration)
        XCTAssertEqual(request.identity.sessionID, fixture.sessionID)
        XCTAssertEqual(request.actionEpoch, fixture.observation.actionEpoch + 1)
        XCTAssertEqual(
            request.continuityOperationID.uuidString.lowercased(),
            controlled.specification.work.metadata["operator_continuity_operation_id"]
        )
        let operatorObservationValue = try await app.projectContexts.repository
            .contextBudgetObservation(observationID: request.observationID)
        let operatorObservation = try XCTUnwrap(operatorObservationValue)
        assertOperatorObservation(operatorObservation, preserves: fixture.observation)
        XCTAssertEqual(operatorObservation.action, expectedBudgetAction)
        XCTAssertEqual(operatorObservation.actionEpoch, request.actionEpoch)

        let events = try await app.projectContexts.repository.operatorAutonomyEvents(limit: 101)
        XCTAssertTrue(events.contains {
            $0.runID == fixture.run.runID && $0.eventType == expectedEvent
        })
        let duringExecutionValue = try await app.projectContexts.repository.autonomousRun(
            fixture.run.runID
        )
        let duringExecution = try XCTUnwrap(duringExecutionValue)
        XCTAssertEqual(duringExecution.activeSessionID, fixture.sessionID)
        XCTAssertNil(duringExecution.activeOperationID)

        await recorder.release()
        let resumed = try await waitForRun(
            repository: app.projectContexts.repository,
            runID: fixture.run.runID,
            state: .running
        )
        XCTAssertEqual(resumed.activeSessionID, fixture.sessionID)
        XCTAssertNil(resumed.specification.work.metadata["operator_continuity_action"])
        await runtime.shutdown()
    }

    private func makeOperatorReadyRun(
        app: ForgeApp,
        label: String
    ) async throws -> ManagedRuntimeOperatorReadyFixture {
        let running = try await makeOperatorRunningRun(app: app, label: label)
        let identity = ContextBudgetIdentity(
            runID: running.run.runID,
            projectID: running.run.projectID,
            projectGeneration: running.run.projectGeneration,
            sessionID: running.sessionID
        )
        let budget = try await ContextBudgetSupervisor.open(
            repository: app.projectContexts.repository,
            identity: identity,
            configuration: try managedRuntimeOperatorBudgetConfiguration()
        )
        let receipt = try await budget.evaluate(ContextBudgetEvaluationRequest(
            triggerPoint: .afterProviderTurn,
            providerResponseID: running.providerResponseID,
            measurement: .providerExact(usedTokens: 1_024)
        ))
        XCTAssertEqual(receipt.observation.action, .normal)
        return ManagedRuntimeOperatorReadyFixture(
            run: running.run,
            sessionID: running.sessionID,
            observation: receipt.observation
        )
    }

    private func makeOperatorRunningRun(
        app: ForgeApp,
        label: String
    ) async throws -> ManagedRuntimeOperatorRunningFixture {
        let projectRoot = home.appendingPathComponent(
            "operator-ready-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(),
            displayName: "Operator Ready \(label)",
            canonicalRoot: projectRoot
        )
        var run = try await app.projectContexts.repository.createAutonomousRun(
            managedRuntimeRunRequest(
                projectID: project.projectID,
                generation: project.generation,
                projectRoot: projectRoot,
                mission: "Exercise operator \(label) continuity"
            )
        )
        let lease = try await app.projectContexts.repository.acquireRunLease(
            runID: run.runID,
            ownerID: "operator-ready-\(label)"
        )
        do {
            let sessionID = "operator-session-\(UUID().uuidString.lowercased())"
            let providerResponseID = "operator-response-\(label)"
            try await app.projectContexts.repository.reserveProviderSession(
                ProviderSessionIntent(
                    sessionID: sessionID,
                    runID: run.runID,
                    projectID: run.projectID,
                    projectGeneration: run.projectGeneration,
                    providerID: "fixture-provider",
                    adapterID: "fixture-adapter",
                    modelKey: "fixture-model",
                    providerResponseID: providerResponseID,
                    idempotencyKey: "operator-session-\(run.runID.description)",
                    contextCapacity: 32_768
                ),
                lease: lease
            )
            let reservedRun = try await app.projectContexts.repository.autonomousRun(run.runID)
            run = try XCTUnwrap(reservedRun)
            for state in [
                AutonomousRunState.validating,
                .ready,
                .starting,
                .running,
            ] {
                run = try await app.projectContexts.repository.transitionAutonomousRun(
                    runID: run.runID,
                    lease: lease,
                    transition: AutonomousRunTransition(
                        expectedState: run.state,
                        expectedRevision: run.revision,
                        nextState: state,
                        eventType: "operator_fixture_\(state.rawValue)",
                        eventSummary: "Operator fixture entered \(state.rawValue)"
                    )
                )
            }
            _ = try await app.projectContexts.repository.releaseRunLease(lease)
            return ManagedRuntimeOperatorRunningFixture(
                run: run,
                sessionID: sessionID,
                providerResponseID: providerResponseID
            )
        } catch {
            _ = try? await app.projectContexts.repository.releaseRunLease(lease)
            throw error
        }
    }

    private func managedRuntimeOperatorBudgetConfiguration() throws -> ContextBudgetConfiguration {
        try ContextBudgetConfiguration(
            capacity: ContextCapacityResolution(
                providerID: "fixture-provider",
                providerVersionFingerprint: String(repeating: "b", count: 64),
                modelKey: "fixture-model",
                activeInstanceID: "fixture-instance",
                capacity: 32_768,
                maximumContextLength: 65_536,
                requiresModelLoad: false
            ),
            reserves: ContextBudgetReserves(
                outputTokens: 1_024,
                schemaTokens: 512,
                handoffTokens: 1_024,
                recoveryTokens: 512
            ),
            policy: ContextBudgetPolicy(initialProjectedNextTurnTokens: 512)
        ).validated()
    }

    private func assertOperatorObservation(
        _ actual: ContextBudgetObservation,
        preserves source: ContextBudgetObservation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.identity, source.identity, file: file, line: line)
        XCTAssertEqual(actual.providerResponseID, source.providerResponseID, file: file, line: line)
        XCTAssertEqual(actual.capacity, source.capacity, file: file, line: line)
        XCTAssertEqual(actual.used, source.used, file: file, line: line)
        XCTAssertEqual(actual.reserves, source.reserves, file: file, line: line)
        XCTAssertEqual(actual.remaining, source.remaining, file: file, line: line)
        XCTAssertEqual(actual.projectedNextTurn, source.projectedNextTurn, file: file, line: line)
        XCTAssertEqual(actual.source, source.source, file: file, line: line)
        XCTAssertEqual(actual.confidence, source.confidence, file: file, line: line)
        XCTAssertEqual(actual.estimatorVersion, source.estimatorVersion, file: file, line: line)
        XCTAssertEqual(actual.thresholds, source.thresholds, file: file, line: line)
    }

    private func waitForOperatorContinuity(
        recorder: ManagedRuntimeOperatorContinuityRecorder,
        count: Int,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let calls = await recorder.snapshot()
            if calls.count >= count { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for operator continuity execution")
    }

    private func waitForActiveRun(
        runtime: ManagedAutonomyRuntime,
        runID: RunID,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let snapshot = await runtime.snapshot()
            if snapshot.supervisor.activeRunIDs.contains(runID) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for active managed run")
    }

    private func managedRuntimeRunRequest(
        projectID: ProjectID,
        generation: ProjectGeneration,
        projectRoot: URL,
        runID: RunID = RunID(),
        mission: String = "Read the fixture and provide deterministic completion evidence"
    ) -> AutonomousRunRequest {
        AutonomousRunRequest(
            runID: runID,
            projectID: projectID,
            projectGeneration: generation,
            mission: mission,
            providerID: "fixture-provider",
            adapterID: "fixture-adapter",
            modelKey: "fixture-model",
            specification: AutonomousRunSpecification(
                allowedTools: ["fs_read"],
                completionGates: ["fixture_read"]
            ),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [projectRoot],
                allowedTools: ["fs_read"],
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        )
    }

    private func waitForRun(
        node: ManagerNode,
        runID: RunID,
        state: AutonomousRunState,
        timeout: Duration = .seconds(5)
    ) async throws -> [String: Any] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let value = try node.autonomousRunStatus(runID: runID)
            if value["state"] as? String == state.rawValue { return value }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for autonomous run state \(state.rawValue)")
        return try node.autonomousRunStatus(runID: runID)
    }

    private func waitForRun(
        repository: ProjectControlPlaneRepository,
        runID: RunID,
        state: AutonomousRunState,
        timeout: Duration = .seconds(5)
    ) async throws -> AutonomousRunRecord {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let value = try await repository.autonomousRun(runID), value.state == state {
                return value
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for autonomous run state \(state.rawValue)")
        let finalValue = try await repository.autonomousRun(runID)
        return try XCTUnwrap(finalValue)
    }

    private func projectGeneration(_ object: [String: Any]) throws -> UInt64 {
        if let value = object["project_generation"] as? UInt64 { return value }
        if let value = object["project_generation"] as? Int { return UInt64(value) }
        if let value = object["project_generation"] as? NSNumber { return value.uint64Value }
        return try XCTUnwrap(nil as UInt64?)
    }

    private func operatorRun(
        runID: RunID,
        snapshot: [String: Any]
    ) throws -> [String: Any] {
        let runs = try XCTUnwrap(snapshot["runs"] as? [[String: Any]])
        return try XCTUnwrap(runs.first { $0["run_id"] as? String == runID.description })
    }

    private func assertExactOperatorRunProjection(
        _ response: [String: Any],
        equals snapshot: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let keys: Set<String> = [
            "run_id", "project_id", "project_generation", "assignment_id", "mission", "state",
            "continuity_mode", "provider_id", "adapter_id", "model_key", "provider_instance_id",
            "active_session_id", "predecessor_session_id", "active_operation_id",
            "continuation_pending", "lease_owner", "work_item", "last_model_turn_at",
            "last_tool_activity_at", "completion_gates", "passed_gates", "last_error_code",
            "last_error_summary", "retry_at", "created_at", "updated_at",
        ]
        let responseData = try JSONSerialization.data(
            withJSONObject: response.filter { keys.contains($0.key) },
            options: [.sortedKeys]
        )
        let snapshotData = try JSONSerialization.data(
            withJSONObject: snapshot.filter { keys.contains($0.key) },
            options: [.sortedKeys]
        )
        XCTAssertEqual(responseData, snapshotData, file: file, line: line)
    }

    private func postJSON(
        _ url: URL,
        object: [String: Any],
        bearerToken: String? = nil
    ) throws -> (object: [String: Any], status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try HTTPTestHelpers.fetch(request, timeout: 10)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (decoded, response.statusCode)
    }
}

private struct ManagedRuntimeOperatorReadyFixture {
    let run: AutonomousRunRecord
    let sessionID: String
    let observation: ContextBudgetObservation
}

private struct ManagedRuntimeOperatorRunningFixture {
    let run: AutonomousRunRecord
    let sessionID: String
    let providerResponseID: String
}

private actor ManagedRuntimeOperatorContinuityRecorder: ManagedRunContinuityExecuting {
    struct Call: Sendable {
        let runID: RunID
        let projectID: ProjectID
        let projectGeneration: ProjectGeneration
        let sessionID: String?
        let state: AutonomousRunState
    }

    private var calls: [Call] = []
    private var released = false

    func executeContinuityStep(
        intent: RunSideEffectIntent,
        run: AutonomousRunRecord,
        context: ToolInvocationContext,
        lease: RunLease
    ) async throws -> ProjectRunStepOutcome {
        calls.append(Call(
            runID: run.runID,
            projectID: run.projectID,
            projectGeneration: run.projectGeneration,
            sessionID: run.activeSessionID,
            state: run.state
        ))
        while !released {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        return .continued(run.specification.work)
    }

    func snapshot() -> [Call] { calls }

    func release() { released = true }
}

private func managedRuntimeFixtureRegistry(
    provider: ManagedRuntimeFixtureProvider
) -> HostAdapterRegistry {
    let registry = HostAdapterRegistry()
    registry.register(
        manifest: HostPluginManifest(
            identifier: "fixture-adapter",
            version: "1",
            minimumContractVersion: 2,
            hostType: "fixture",
            capabilities: HostCapabilities(
                create: false,
                bootstrap: false,
                usageReporting: true,
                resume: false,
                idempotency: true,
                queryByIdempotencyKey: true
            ),
            configurationKeys: [],
            privacyRequirements: [],
            migrationVersion: 1
        ),
        managedProviderFactory: { _ in provider },
        factory: { _ in ManagedRuntimeUnavailableAdapter() }
    )
    return registry
}

private actor ManagedRuntimeFixtureProvider: ManagedModelProvider {
    struct Snapshot: Sendable {
        let rootCalls: Int
        let continuationCalls: Int
        let previousResponseID: String?
        let receivedToolOutput: Bool
    }

    nonisolated let providerID = "fixture-provider"
    private let fixturePath: String
    private let rootDelay: Duration?
    private var rootCalls = 0
    private var continuationCalls = 0
    private var previousResponseID: String?
    private var receivedToolOutput = false
    private var receipts: [String: ProviderTurn] = [:]

    init(fixturePath: String, rootDelay: Duration? = nil) {
        self.fixturePath = fixturePath
        self.rootDelay = rootDelay
    }

    func probe() async throws -> ProviderCapabilities {
        try ProviderCapabilities(
            providerID: providerID,
            providerVersion: "fixture-1",
            modelKey: "fixture-model",
            providerInstanceID: "fixture-instance",
            contextLength: 32_768,
            maximumContextLength: 65_536,
            statefulResponses: true,
            streaming: true,
            customTools: true,
            mcp: false,
            structuredOutput: false,
            usageReporting: true,
            idempotencyLookup: true,
            capabilityFingerprintSHA256: String(repeating: "b", count: 64)
        )
    }

    func createRoot(_ request: ProviderRootRequest) async throws -> ProviderTurn {
        if let existing = receipts[request.idempotencyKey] { return existing }
        if let rootDelay { try await Task.sleep(for: rootDelay) }
        rootCalls += 1
        let arguments = try JSONSerialization.data(
            withJSONObject: ["path": fixturePath],
            options: [.sortedKeys]
        )
        let turn = try ProviderTurn(
            requestID: "req-manager-root",
            responseID: "resp-manager-root",
            providerID: providerID,
            providerVersion: "fixture-1",
            modelKey: "fixture-model",
            providerInstanceID: "fixture-instance",
            messages: [],
            toolCalls: [try ProviderToolCall(
                callID: "call-manager-read",
                name: "fs_read",
                argumentsJSON: arguments
            )],
            usage: try ProviderUsage(
                capacity: 32_768,
                inputTokens: 1_000,
                outputTokens: 64,
                source: .providerExact,
                confidence: 1
            ),
            completed: true,
            finishReason: .toolCalls
        )
        receipts[request.idempotencyKey] = turn
        return turn
    }

    func continueSession(_ request: ProviderContinuationRequest) async throws -> ProviderTurn {
        if let existing = receipts[request.idempotencyKey] { return existing }
        continuationCalls += 1
        previousResponseID = request.previousResponseID
        let values = try JSONSerialization.jsonObject(with: request.input) as? [[String: Any]]
        receivedToolOutput = values?.first?["type"] as? String == "function_call_output"
        let output = values?.first?["output"] as? String ?? ""
        let proof = JSONSupport.sha256Hex(output)
        let message = try JSONSupport.canonicalJSON([
            "forge_run_status": "completion_requested",
            "summary": "The fixture read is ready for deterministic validation",
            "gate_evidence": ["fixture_read": proof],
        ])
        let turn = try ProviderTurn(
            requestID: "req-manager-final",
            responseID: "resp-manager-final",
            previousResponseID: request.previousResponseID,
            providerID: providerID,
            providerVersion: "fixture-1",
            modelKey: "fixture-model",
            providerInstanceID: "fixture-instance",
            messages: [message],
            toolCalls: [],
            usage: try ProviderUsage(
                capacity: 32_768,
                inputTokens: 1_200,
                outputTokens: 96,
                source: .providerExact,
                confidence: 1
            ),
            completed: true,
            finishReason: .stop
        )
        receipts[request.idempotencyKey] = turn
        return turn
    }

    func lookup(idempotencyKey: String) async throws -> ProviderTurn? {
        receipts[idempotencyKey]
    }

    func cancel(requestID: String) async {}

    func snapshot() -> Snapshot {
        Snapshot(
            rootCalls: rootCalls,
            continuationCalls: continuationCalls,
            previousResponseID: previousResponseID,
            receivedToolOutput: receivedToolOutput
        )
    }
}

private struct ManagedRuntimeUnavailableAdapter: SessionHostAdapter, Sendable {
    let identifier = "fixture-adapter"
    let version = "1"

    func capabilities() async throws -> HostCapabilities {
        HostCapabilities(
            create: false,
            bootstrap: false,
            usageReporting: false,
            resume: false,
            idempotency: true,
            queryByIdempotencyKey: true
        )
    }

    func createSession(_ request: SessionCreationRequest) async throws -> HostSession {
        throw ContinuityRunError.hostCapabilityUnavailable
    }

    func session(forIdempotencyKey key: String) async throws -> HostSession? { nil }

    func bootstrap(_ session: HostSession, handoff: ContinuityHandoff) async throws {
        throw ContinuityRunError.hostCapabilityUnavailable
    }

    func awaitAcknowledgement(
        session: HostSession,
        handoffID: String,
        timeout: Duration
    ) async throws -> HandoffAcknowledgement {
        throw ContinuityRunError.hostCapabilityUnavailable
    }

    func cancel(operationID: String) async {}
}

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
        let project = try await app.projectContexts.repository.registerProject(
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
        let registered = try await app.projectContexts.repository.registerProject(
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

    func testHTTPRunControlRoutePersistsExactActionsAndRejectsUnknownActions() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = Int.random(in: 29_000...39_000)
        try app.config.update([
            "dashboard": ["port": port] as [String: Any],
        ], save: true)
        let projectRoot = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
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

    func testRunCancellationReleasesOwnedRuntimeJobBeforeTerminalRunState() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let fixtureURL = projectRoot.appendingPathComponent("fixture.txt")
        try Data("runtime cancellation fixture\n".utf8).write(to: fixtureURL, options: .atomic)
        let projectID = ProjectID()
        let project = try await app.projectContexts.repository.registerProject(
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

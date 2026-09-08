import Foundation
import XCTest
@testable import ForgeConductorCore

final class ManagerNativeSourceConversationTests: XCTestCase, @unchecked Sendable {
    func testHeldNativeSendUsesRegisteredProviderAndStopRestartNeverRevivesItsOwner() async throws {
        try await withFixture(mode: .heldProbe) { f in
            let request = try NativeSourceSendRequest(taskID: f.taskID, requestID: UUID(), input: "Inspect the exact approved task")
            let accepted = try await f.command("send", request.canonicalRequestJSON)
            XCTAssertEqual(accepted.disposition, "accepted")
            try await self.eventually { await f.provider.counts().probes == 1 }
            XCTAssertEqual(f.runtime.providerWorkAdmission.activeCount, 1)
            XCTAssertGreaterThan(f.configuration.readCount, 0, "Native configuration read succeeds while its manager operation lease is held")
            XCTAssertThrowsError(try f.manager.readProviderConfiguration()) {
                XCTAssertEqual($0 as? ProviderConfigurationError, .busy)
            }
            XCTAssertThrowsError(try f.manager.updateProviderConfiguration(f.configuration.updateRequest)) {
                XCTAssertEqual($0 as? ProviderConfigurationError, .busy)
            }
            XCTAssertThrowsError(try f.manager.probeProvider(adapterID: ManagerNode.nativeSessionHostAdapterID, mode: .connection)) {
                XCTAssertEqual($0 as? ManagerProviderProbeError, .probeInProgress)
            }
            XCTAssertEqual(f.configuration.updateCount, 0)
            _ = try f.manager.stopService()
            XCTAssertFalse(f.manager.isServiceActive())
            do {
                _ = try await f.command("send", NativeSourceSendRequest(taskID: f.taskID, requestID: UUID(), input: "Stopped source").canonicalRequestJSON)
                XCTFail("Stop returned before closing native source admission")
            } catch { XCTAssertEqual(error as? NativeSourceOperatorError, .unavailable) }
            XCTAssertEqual(f.runtime.providerWorkAdmission.activeCount, 1)
            _ = try f.manager.restartService()
            XCTAssertTrue(f.manager.isServiceActive())
            do {
                _ = try await f.command("send", NativeSourceSendRequest(taskID: f.taskID, requestID: UUID(), input: "Competing exchange").canonicalRequestJSON)
                XCTFail("Restart discarded the cancellation-insensitive source owner")
            } catch { XCTAssertEqual(error as? NativeSourceConversationError, .capacityExceeded) }
            let replay = try await f.command("send", request.canonicalRequestJSON)
            XCTAssertEqual(replay.disposition, "replayed")
            XCTAssertEqual(replay.stageID, accepted.stageID)
            await f.provider.release()
            try await self.eventually { f.runtime.providerWorkAdmission.activeCount == 0 }
            let counts = await f.provider.counts()
            XCTAssertEqual(counts.probes, 1)
            XCTAssertEqual(counts.roots, 0, "Restart must not uncancel a stopped owner after its probe returns")
            let jobs = try await f.app.runtimeJobs.repository.health()
            XCTAssertEqual(jobs.integrity, "ok")
        }
    }

    func testIncompleteManagerShutdownRetainsSourcePermitRuntimeAndStoresUntilActualProbeExit() async throws {
        try await withFixture(mode: .heldProbe) { f in
            let request = try NativeSourceSendRequest(taskID: f.taskID, requestID: UUID(), input: "Retain actual source ownership")
            _ = try await f.command("send", request.canonicalRequestJSON)
            try await self.eventually { await f.provider.counts().probes == 1 }
            XCTAssertEqual(f.runtime.providerWorkAdmission.activeCount, 1)
            XCTAssertFalse(f.manager.shutdownManagedAutonomy())
            XCTAssertFalse(f.runtime.providerWorkAdmission.isOpen)
            XCTAssertEqual(f.runtime.providerWorkAdmission.activeCount, 1)
            XCTAssertFalse(f.manager.shutdownManagedAutonomy(), "A repeated shutdown cannot replace the retained source owner")
            XCTAssertThrowsError(try f.manager.recoverManagedAutonomy())
            XCTAssertEqual(f.runtimeCreations.value, 1)
            let jobs = try await f.app.runtimeJobs.repository.health()
            XCTAssertEqual(jobs.integrity, "ok")
            let prepared = try await f.app.projectContexts.repository.nativeSourceRequest(taskID: f.taskID,
                requestID: request.requestID, credential: f.credential)
            XCTAssertNotNil(prepared, "The control plane remains open during incomplete shutdown")
            await f.provider.release()
            try await self.eventually { f.runtime.providerWorkAdmission.activeCount == 0 }
            XCTAssertTrue(f.manager.shutdownManagedAutonomy())
            XCTAssertEqual(f.runtimeCreations.value, 1)
            XCTAssertTrue(f.manager.shutdownNativeTaskAttachment())
        }
    }

    func testIdleNativeParentKeepsConfigurationIdentityPinnedWithoutAnActiveRun() async throws {
        try await withFixture(mode: .answer) { f in
            let request = try NativeSourceSendRequest(taskID: f.taskID, requestID: UUID(), input: "Answer using the approved assignment")
            _ = try await f.command("send", request.canonicalRequestJSON)
            try await self.eventually { f.runtime.providerWorkAdmission.activeCount == 0 }
            let status = try await f.command("status", NativeSourceStatusRequest(taskID: f.taskID, requestID: request.requestID).canonicalRequestJSON)
            XCTAssertEqual(status.conversationState, "idle")
            XCTAssertEqual(status.stageState, "accepted")
            let runs = try await f.app.projectContexts.repository.nonterminalAutonomousRuns(limit: 1)
            XCTAssertTrue(runs.isEmpty)
            XCTAssertEqual(try f.manager.readProviderConfiguration().revision, "fixture-revision")
            XCTAssertThrowsError(try f.manager.updateProviderConfiguration(f.configuration.updateRequest)) {
                XCTAssertEqual($0 as? ProviderConfigurationError, .busy)
            }
            XCTAssertEqual(f.configuration.updateCount, 0, "An idle durable source parent still owns its provider receipt domain")
        }
    }

    func testLoopbackSourceRoutesAuthenticateBeforeDecodeAndEnforcePerActionBodyBounds() async throws {
        try await withFixture(mode: .answer) { f in
            for action in ["send", "status", "cancel"] {
                let malformed = Data("{invalid-source-body".utf8)
                let unauthorized = try f.http(action, body: malformed, authenticated: false)
                XCTAssertEqual(unauthorized.1.statusCode, 401, action)
                XCTAssertEqual(try JSONSupport.object(from: unauthorized.0)["code"] as? String, "manager_mutation_unauthorized")
                let authorized = try f.http(action, body: malformed, authenticated: true)
                XCTAssertEqual(authorized.1.statusCode, 400, action)
                XCTAssertEqual(try JSONSupport.object(from: authorized.0)["code"] as? String, "invalid_source_request")
                let maximum = action == "send" ? NativeSourceSendRequest.maximumBodyBytes : NativeSourceStatusRequest.maximumBodyBytes
                let oversized = try f.http(action, body: Data(repeating: 32, count: maximum + 1), authenticated: true)
                XCTAssertEqual(oversized.1.statusCode, 413, action)
                XCTAssertEqual(try JSONSupport.object(from: oversized.0)["code"] as? String, "invalid_source_request")
                XCTAssertLessThanOrEqual(oversized.0.count, NativeSourceOperatorResponse.maximumBytes)
            }
            let absent = try await f.app.projectContexts.repository.nativeSourceConversation(taskID: f.taskID, credential: f.credential)
            XCTAssertNil(absent, "Rejected wire requests must not enroll a native conversation")
            XCTAssertEqual(f.runtime.providerWorkAdmission.activeCount, 0)
            let counts = await f.provider.counts()
            XCTAssertEqual(counts.probes, 0); XCTAssertEqual(counts.roots, 0)
        }
    }

    func testRealLoopbackDashboardClientPreservesAcceptedSendStatusCancelAndReplayIdentity() async throws {
        try await withFixture(mode: .heldProbe) { f in
            let client = f.dashboardClient()
            let request = try NativeSourceSendRequest(taskID: f.taskID, requestID: UUID(), input: "One exact loopback source exchange")
            let acceptedData = try await client.submitNativeSourceCommand(action: "send", body: request.canonicalRequestJSON)
            let accepted = try NativeSourceOperatorResponse(data: acceptedData)
            XCTAssertEqual(accepted.disposition, "accepted")
            XCTAssertEqual(accepted.taskID, request.taskID); XCTAssertEqual(accepted.requestID, request.requestID)
            try await self.eventually { await f.provider.counts().probes == 1 }
            let replayHTTP = try f.http("send", body: request.canonicalRequestJSON, authenticated: true)
            XCTAssertEqual(replayHTTP.1.statusCode, 202, "The real route acknowledges the durable exchange while its probe is held")
            let replay = try NativeSourceOperatorResponse(data: replayHTTP.0)
            XCTAssertEqual(replay.disposition, "replayed")
            XCTAssertEqual(replay.stageID, accepted.stageID)
            XCTAssertEqual(replay.conversationID, accepted.conversationID)
            let clientReplay = try NativeSourceOperatorResponse(data: await client.submitNativeSourceCommand(action: "send", body: request.canonicalRequestJSON))
            XCTAssertEqual(clientReplay.stageID, accepted.stageID)
            let statusRequest = try NativeSourceStatusRequest(taskID: f.taskID, requestID: request.requestID)
            let pendingStatus = try NativeSourceOperatorResponse(data: await client.submitNativeSourceCommand(action: "status", body: statusRequest.canonicalRequestJSON))
            XCTAssertEqual(pendingStatus.disposition, "observed")
            XCTAssertEqual(pendingStatus.stageID, accepted.stageID)
            XCTAssertEqual(try f.http("status", body: statusRequest.canonicalRequestJSON, authenticated: true).1.statusCode, 202)
            await f.provider.release()
            try await self.eventually { f.runtime.providerWorkAdmission.activeCount == 0 }
            let complete = try NativeSourceOperatorResponse(data: await client.submitNativeSourceCommand(action: "status", body: statusRequest.canonicalRequestJSON))
            XCTAssertEqual(complete.stageState, "accepted"); XCTAssertEqual(complete.conversationState, "idle")
            let completedReplay = try NativeSourceOperatorResponse(data: await client.submitNativeSourceCommand(action: "send", body: request.canonicalRequestJSON))
            XCTAssertEqual(completedReplay.disposition, "replayed")
            XCTAssertEqual(completedReplay.stageID, accepted.stageID)
            let cancel = try NativeSourceCancelRequest(taskID: f.taskID, requestID: request.requestID,
                cancelRequestID: UUID(), reason: "Close the exact completed exchange")
            let cancelled = try NativeSourceOperatorResponse(data: await client.submitNativeSourceCommand(action: "cancel", body: cancel.canonicalRequestJSON))
            XCTAssertEqual(cancelled.disposition, "cancel_requested")
            XCTAssertEqual(cancelled.taskID, request.taskID); XCTAssertEqual(cancelled.requestID, request.requestID)
            XCTAssertEqual(cancelled.stageID, accepted.stageID)
            let cancelReplay = try f.http("cancel", body: cancel.canonicalRequestJSON, authenticated: true)
            XCTAssertEqual(cancelReplay.1.statusCode, 200)
            XCTAssertEqual(try NativeSourceOperatorResponse(data: cancelReplay.0).stageID, accepted.stageID)
            let counts = await f.provider.counts()
            XCTAssertEqual(counts.probes, 1); XCTAssertEqual(counts.roots, 1); XCTAssertEqual(counts.continuations, 0)
            let runs = try await f.app.projectContexts.repository.nonterminalAutonomousRuns(limit: 1)
            XCTAssertTrue(runs.isEmpty)
        }
    }

    private func eventually(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Bounded manager source observation did not settle")
        throw NativeSourceConversationError.deadlineExceeded
    }
    private func withFixture(mode: SourceOwnerProvider.Mode, _ body: (ManagerSourceFixture) async throws -> Void) async throws {
        let f = try await ManagerSourceFixture.make(mode: mode)
        do { try await body(f); await f.close() }
        catch { await f.close(); throw error }
    }
}

private final class ManagerSourceFixture: @unchecked Sendable {
    let app: ForgeApp
    let manager: ManagerNode
    let runtime: ManagedAutonomyRuntime
    let runtimeCreations: ManagerSourceCount
    let taskID: UUID
    let credential: NativeTaskCapabilityCredential
    let provider: SourceOwnerProvider
    let configuration: ManagerSourceConfiguration
    private init(app: ForgeApp, manager: ManagerNode, runtime: ManagedAutonomyRuntime,
        runtimeCreations: ManagerSourceCount, taskID: UUID, credential: NativeTaskCapabilityCredential,
        provider: SourceOwnerProvider, configuration: ManagerSourceConfiguration) {
        self.app = app; self.manager = manager; self.runtime = runtime; self.runtimeCreations = runtimeCreations
        self.taskID = taskID; self.credential = credential; self.provider = provider; self.configuration = configuration
    }
    static func make(mode: SourceOwnerProvider.Mode) async throws -> ManagerSourceFixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("manager-native-source-\(UUID().uuidString)").resolvingSymlinksInPath()
        let app = try ForgeApp.bootstrap(home: home)
        var manager: ManagerNode?
        do {
            let project = home.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let file = project.appendingPathComponent("source.txt")
            try Data("Actual manager source fixture".utf8).write(to: file)
            let port = Int.random(in: 39_000...48_000)
            try app.config.update(["allowed_roots": [project.path], "dashboard": ["host": "127.0.0.1", "port": port]], save: true)
            let prior = try app.config.budgetPolicySelection(scope: .globalDefault)
            _ = try app.config.updateBudgetPolicy(.init(scope: .globalDefault, expectedRevision: prior.revision,
                expectedGlobalRevision: prior.globalRevision, operation: .set, policy: BudgetPolicy(automaticHandoffEnabled: false)))
            let registry = HostAdapterRegistry(), provider = SourceOwnerProvider(mode: mode, path: file.path)
            let configuration = ManagerSourceConfiguration(), creations = ManagerSourceCount()
            registry.register(manifest: .init(identifier: ManagerNode.nativeSessionHostAdapterID, version: "fixture",
                minimumContractVersion: 2, hostType: "fixture", capabilities: .init(create: false, bootstrap: false,
                    usageReporting: false, resume: false, idempotency: false, queryByIdempotencyKey: false),
                configurationKeys: [], privacyRequirements: [], migrationVersion: 1),
                managedProviderFactory: { _ in provider }, configurationFactory: { _ in configuration },
                factory: { _ in throw NativeSourceConversationError.unsupportedProvider })
            let runtime = try ManagedAutonomyRuntime(app: app, registry: registry, maximumConcurrentRuns: 1)
            let node = ManagerNode(app: app, managedAutonomyFactory: { _ in creations.increment(); return runtime }, hostAdapterRegistry: registry)
            manager = node
            let registration = try node.registerProject(path: project.path)
            let projectID = ProjectID(try XCTUnwrap((registration["project_id"] as? String).flatMap(UUID.init(uuidString:))))
            let approval = try NativeContinuityTaskApproval(assignmentID: "manager-native-source",
                assignmentBytes: Data("Immutable assignment document marker".utf8), mission: "Read the manager-approved project",
                providerID: "lmstudio", adapterID: ManagerNode.nativeSessionHostAdapterID, modelKey: "fixture/native",
                allowedTools: ["fs_read"], completionGates: ["G04"], resourceProfile: .automatic,
                filesystemAccess: "read_only", networkAllowed: false, maximumInlineOutputBytes: 65_536,
                sourceLimits: .init(maximumCalls: 64, maximumResultBytes: 65_536, maximumRequestSeconds: 60))
            let taskID = UUID()
            let credential = try NativeTaskCapabilityCredential(capabilityID: UUID(), epoch: 1, secret: Data(repeating: 52, count: 32))
            let request = try NativeContinuityTaskPreparationRequest(requestID: UUID(), taskID: taskID,
                capabilityID: credential.capabilityID, projectID: projectID, projectGeneration: .initial, approval: approval,
                verifierSHA256: credential.verifier.sha256, expiresAt: ISO8601.string(from: Date().addingTimeInterval(3_600)))
            let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp/continuity")!
            let store = NativeTaskCredentialFileStore(paths: app.paths)
            _ = try store.stage(.prepare(request), candidate: credential, endpoint: endpoint)
            let result = try await node.prepareNativeContinuityTask(request)
            _ = try store.complete(.prepare(request), result: result, endpoint: endpoint)
            XCTAssertNotNil(try node.recoverManagedAutonomy())
            _ = try node.startService()
            return .init(app: app, manager: node, runtime: runtime, runtimeCreations: creations,
                taskID: taskID, credential: credential, provider: provider, configuration: configuration)
        } catch {
            _ = try? manager?.stopService()
            _ = manager?.shutdownNativeTaskAttachment(); _ = manager?.shutdownManagedAutonomy()
            app.shutdown(); try? FileManager.default.removeItem(at: home); throw error
        }
    }
    func dashboardClient() -> ManagerDashboardClient {
        ManagerDashboardClient(host: "127.0.0.1", port: app.config.dashboard.port,
            credentials: ManagerControlCredentialStore(paths: app.paths))
    }
    func http(_ action: String, body: Data, authenticated: Bool) throws -> (Data, HTTPURLResponse) {
        guard ["send", "status", "cancel"].contains(action) else { throw NativeSourceOperatorError.invalidRequest("action") }
        let url = URL(string: "http://127.0.0.1:\(app.config.dashboard.port)/api/manager/continuity/source/" + action)!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            request.setValue("Bearer " + (try ManagerControlCredentialStore(paths: app.paths).bearerToken()), forHTTPHeaderField: "Authorization")
        }
        return try HTTPTestHelpers.fetch(request, timeout: 5)
    }
    func command(_ action: String, _ body: Data) async throws -> NativeSourceOperatorResponse {
        let result = ManagerSourceResponseBox()
        guard manager.dispatchNativeSourceCommand(action: action, body: body, completion: { result.store($0) }) else {
            throw NativeSourceConversationError.capacityExceeded
        }
        for _ in 0..<500 {
            if let value = result.value() { return try value.get() }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NativeSourceConversationError.deadlineExceeded
    }
    func close() async {
        await provider.release()
        for _ in 0..<500 {
            if runtime.providerWorkAdmission.activeCount == 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        _ = try? manager.stopService()
        XCTAssertTrue(manager.shutdownNativeTaskAttachment())
        XCTAssertTrue(manager.shutdownManagedAutonomy())
        XCTAssertTrue(app.shutdown().completed)
        try? FileManager.default.removeItem(at: app.paths.home)
    }
}

private final class ManagerSourceResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<NativeSourceOperatorResponse, Error>?
    func store(_ value: Result<NativeSourceOperatorResponse, Error>) { lock.lock(); result = value; lock.unlock() }
    func value() -> Result<NativeSourceOperatorResponse, Error>? { lock.lock(); defer { lock.unlock() }; return result }
}
private final class ManagerSourceCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
private final class ManagerSourceConfiguration: ProviderConfigurationServicing, @unchecked Sendable {
    private let reads = ManagerSourceCount(), updates = ManagerSourceCount()
    var readCount: Int { reads.value }
    var updateCount: Int { updates.value }
    var updateRequest: ProviderConfigurationUpdate {
        .init(expectedRevision: "fixture-revision", endpoint: "http://127.0.0.1:4321", modelKey: "different/model")
    }
    func read() async throws -> ProviderConfigurationSnapshot {
        reads.increment()
        return .init(revision: "fixture-revision", endpoint: "http://127.0.0.1:1234", modelKey: "fixture/native", credentialConfigured: false, saved: true)
    }
    func update(_ request: ProviderConfigurationUpdate) async throws -> ProviderConfigurationSnapshot {
        updates.increment()
        return .init(revision: "changed", endpoint: request.endpoint, modelKey: request.modelKey, credentialConfigured: false, saved: true)
    }
    func models() async throws -> ProviderModelInventory { .init(revision: "fixture-revision", models: []) }
}

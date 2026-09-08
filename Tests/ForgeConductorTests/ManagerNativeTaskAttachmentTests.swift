import XCTest
@testable import ForgeConductorCore

final class ManagerNativeTaskAttachmentTests: XCTestCase {
    private var home: URL!
    private var projectRoot: URL!
    private var app: ForgeApp!
    private var manager: ManagerNode!
    private var projectID: ProjectID!
    private let providerStarts = NativeManagerCounter()

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("native-task-manager-\(UUID())")
        projectRoot = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        app = try ForgeApp.bootstrap(home: home)
        _ = try app.config.update(["allowed_roots": [projectRoot.path]], save: false)
        let counter = providerStarts
        manager = ManagerNode(app: app, managedAutonomyFactory: { _ in
            counter.increment()
            throw AutonomyError.shutdown
        })
        let registered = try manager.registerProject(path: projectRoot.path)
        projectID = ProjectID(try XCTUnwrap((registered["project_id"] as? String).flatMap(UUID.init(uuidString:))))
    }

    override func tearDownWithError() throws {
        if let manager { XCTAssertTrue(manager.shutdownNativeTaskAttachment()) }
        manager = nil
        app?.shutdown()
        app = nil
        try? FileManager.default.removeItem(at: home)
    }

    private func request() throws -> (NativeContinuityTaskPreparationRequest, NativeTaskCapabilityCredential) {
        let credential = try NativeTaskCapabilityCredential(capabilityID: UUID(), epoch: 1,
            secret: Data(repeating: 0x52, count: 32))
        let approval = try NativeContinuityTaskApproval(assignmentID: "read-approved-fixture",
            assignmentBytes: Data("Read the approved project fixture and report its contents".utf8),
            mission: "Read the approved fixture", providerID: "lmstudio",
            adapterID: ManagerNode.nativeSessionHostAdapterID, modelKey: "fixture-model",
            allowedTools: ["fs_read"], completionGates: ["fixture-reviewed"], resourceProfile: .standard,
            filesystemAccess: "read_only", networkAllowed: false, maximumInlineOutputBytes: 4_096,
            sourceLimits: NativeTaskSourceLimits(maximumCalls: 4, maximumResultBytes: 4_096, maximumRequestSeconds: 10))
        return (try .init(requestID: UUID(), taskID: UUID(), capabilityID: credential.capabilityID,
            projectID: projectID, projectGeneration: .initial, approval: approval,
            verifierSHA256: credential.verifier.sha256,
            expiresAt: ISO8601.string(from: app.clock.now().addingTimeInterval(3_600))), credential)
    }

    func testPrepareRechecksCurrentAuthorizedRootAndCreatesNoRunOrProvider() async throws {
        let (request, credential) = try request()
        _ = try app.config.update(["allowed_roots": []], save: false)
        do {
            _ = try await manager.prepareNativeContinuityTask(request)
            XCTFail("Preparation accepted a project removed from current allowed roots")
        } catch { XCTAssertEqual((error as? ProjectContextError)?.code, "project_root_not_authorized") }
        do {
            _ = try await app.projectContexts.repository.authenticateNativeTaskCapability(credential: credential)
            XCTFail("Rejected preparation issued a credential")
        } catch { XCTAssertEqual(error as? NativeTaskCapabilityError, .credentialRejected) }
        _ = try app.config.update(["allowed_roots": [projectRoot.path]], save: false)
        let prepared = try await manager.prepareNativeContinuityTask(request)
        let replay = try await manager.prepareNativeContinuityTask(request)
        XCTAssertFalse(prepared.replayed)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(prepared.receipt, replay.receipt)
        let attached = try await app.projectContexts.repository.authenticateNativeTaskCapability(credential: credential)
        XCTAssertTrue(attached.context.authorizationScope.writableRoots.isEmpty)
        XCTAssertEqual(attached.context.authorizationScope.allowedTools, ["fs_read"])
        XCTAssertFalse(attached.context.authorizationScope.networkAllowed)
        XCTAssertNil(attached.setup.record.runID)
        let runs = try await app.projectContexts.repository.operatorAutonomousRuns(limit: 10)
        XCTAssertTrue(runs.isEmpty)
        XCTAssertEqual(providerStarts.value, 0)
        XCTAssertFalse(manager.statusModel().serviceActive)
    }

    func testOperatorAdmissionRejectsNinthRequestAndShutdownDrainsBeforeStoreClose() async throws {
        let (request, credential) = try request()
        let entered = expectation(description: "prepare reached its transaction commit")
        let completed = expectation(description: "all admitted operator requests settled")
        completed.expectedFulfillmentCount = 8
        let barrier = NativeManagerCommitBarrier()
        await app.projectContexts.repository.configureOperationObservers(beforeCommit: {
            if barrier.claimFirst() {
                entered.fulfill()
                guard barrier.release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
            }
        })
        let body = request.canonicalRequestJSON
        XCTAssertTrue(manager.dispatchNativeTaskCommand(action: "prepare", body: body) { _ in completed.fulfill() })
        await fulfillment(of: [entered], timeout: 3)
        for _ in 0..<7 {
            XCTAssertTrue(manager.dispatchNativeTaskCommand(action: "prepare", body: body) { _ in completed.fulfill() })
        }
        XCTAssertFalse(manager.dispatchNativeTaskCommand(action: "prepare", body: body) { _ in
            XCTFail("The ninth request entered execution")
        })
        let owner = try XCTUnwrap(manager)
        let drainCompleted = NativeManagerCounter()
        let drain = Task.detached {
            let result = owner.shutdownNativeTaskAttachment()
            drainCompleted.increment()
            return result
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(drainCompleted.value, 0, "Shutdown returned while the admitted transaction still owned work")
        barrier.release.signal()
        let drained = await drain.value
        XCTAssertTrue(drained)
        await fulfillment(of: [completed], timeout: 3)
        await app.projectContexts.repository.configureOperationObservers()
        XCTAssertFalse(manager.dispatchNativeTaskCommand(action: "prepare", body: body) { _ in
            XCTFail("Closed admission reopened")
        })
        do {
            _ = try await app.projectContexts.repository.authenticateNativeTaskCapability(credential: credential)
            XCTFail("A cancelled prepare was committed during shutdown")
        } catch { XCTAssertEqual(error as? NativeTaskCapabilityError, .credentialRejected) }
        XCTAssertEqual(providerStarts.value, 0)
    }

    func testShutdownWaitsForActualSourceRecoveryCommitToReleaseOwnership() async throws {
        let (request, credential) = try request()
        _ = try await manager.prepareNativeContinuityTask(request)
        let repository = app.projectContexts.repository
        let attachment = try await repository.authenticateNativeTaskCapability(credential: credential)
        let source = try XCTUnwrap(app).continuity
        let arguments = try ForgeJSONCanonicalizationV1.data(from: ["goal": "Retained native source intent"])
        let commitRequest = try NativeSourceCommitRequest(key: .init(sessionID: UUID(),
            requestIDSHA256: JSONSupport.sha256Hex(Data("held-recovery-commit".utf8))),
            canonicalArgumentsJSON: arguments, managerInstanceID: UUID(), finalize: true)
        let policy = try app.config.budgetPolicySelection(scope: .init(kind: .projectOverride,
            projectID: projectID.description, projectGeneration: 1))
        let decision = try await repository.prepareContinuitySourceCommit(request: commitRequest,
            correlation: attachment.setup.correlation, context: attachment.context, owner: attachment.owner,
            policySelection: policy, prepare: { authorization in
                try source.prepareAuthorizedSourceCommit(arguments: JSONSupport.object(from: arguments),
                    clientID: attachment.context.clientID, source: .model, finalize: true, authorization: authorization)
            })
        guard case .commit(let admission) = decision else { return XCTFail("Expected a durable pending source intent") }
        XCTAssertNil(try app.store.continuityLatestRevision(continuityID: admission.prepared.continuityID,
            authorization: attachment.setup.record.authorization))
        _ = try app.config.update(["dashboard": ["port": Int.random(in: 29_000...39_000), "host": "127.0.0.1"]])
        _ = try manager.startService()
        XCTAssertTrue(manager.isServiceActive())

        let reachedCommit = expectation(description: "recovery owns its actual receipt commit")
        let barrier = NativeManagerCommitBarrier()
        let commits = NativeManagerCounter()
        await repository.configureOperationObservers(beforeCommit: {
            commits.increment()
            // The first transaction pages pending metadata. The second has
            // already committed the exact packet in source SQLite and now owns
            // the CP receipt transaction with cancellation suppression active.
            if commits.value == 2, barrier.claimFirst() {
                reachedCommit.fulfill()
                guard barrier.release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
            }
        })
        let owner = try XCTUnwrap(manager)
        let recovery = Task.detached { try await owner.reconcileNativeSourceCommitsOnce() }
        await fulfillment(of: [reachedCommit], timeout: 3)
        let drainCompleted = NativeManagerCounter()
        let drain = Task.detached {
            let result = owner.shutdownNativeTaskAttachment()
            drainCompleted.increment()
            return result
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(drainCompleted.value, 0, "Shutdown returned while source recovery still owned a commit")
        barrier.release.signal()
        try await recovery.value
        let drained = await drain.value
        XCTAssertTrue(drained)
        await repository.configureOperationObservers()
        let pending = try await repository.pendingNativeSourceCommits()
        XCTAssertTrue(pending.isEmpty, "The actual committed source receipt must settle before shutdown returns")
        let actual = try XCTUnwrap(app.store.continuityLatestRevision(continuityID: admission.prepared.continuityID,
            authorization: attachment.setup.record.authorization))
        XCTAssertEqual(actual.canonicalPacketJSON, admission.prepared.canonicalPacketJSON)
        XCTAssertEqual(actual.identity.packetSHA256, admission.prepared.packetSHA256)
        XCTAssertEqual(providerStarts.value, 0)
    }
}

private final class NativeManagerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private final class NativeManagerCommitBarrier: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var claimed = false
    func claimFirst() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

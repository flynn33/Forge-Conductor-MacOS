import XCTest
@testable import ForgeConductorCore

final class ContinuityIngressServiceTests: XCTestCase {
    private var home: URL!
    private var app: ForgeApp!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("continuity-service-\(UUID())")
        app = try ForgeApp.bootstrap(home: home)
    }

    override func tearDownWithError() throws {
        app.shutdown()
        app = nil
        try? FileManager.default.removeItem(at: home)
    }

    // Service-boundary fixtures. Live manager authorization is tested separately
    // through the control-plane task guard; packet text never mints this value.
    private func authorization(taskID: UUID = UUID()) throws -> ContinuityIngressAuthorization {
        try ContinuityIngressAuthorization(
            projectID: ProjectID(), projectGeneration: .initial,
            sourceBindingID: UUID(), taskID: taskID, assignmentID: "approved-assignment",
            assignmentSHA256: String(repeating: "a", count: 64),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [home], writableRoots: [], allowedTools: ["fs_read"],
                networkAllowed: false, maximumInlineOutputBytes: 4_096
            )
        )
    }

    func testAuthorizedFinalizeCommitsDeliveryAndRestoresExactFrozenPacket() throws {
        let auth = try authorization()
        let client = ClientID("shared-transport")
        let checkpoint = try app.continuity.commitAuthorizedHandoff(
            arguments: ["goal": "Approved task progress", "narrative": "First checkpoint"],
            clientID: client, source: .model, finalize: false,
            authorization: auth, automaticHandoffEnabled: true
        )
        XCTAssertNil(checkpoint.delivery)
        XCTAssertFalse(checkpoint.revision.resumeReady)
        XCTAssertTrue(try app.store.pendingContinuityHandoffs().isEmpty)

        let handoff = try app.continuity.commitAuthorizedHandoff(
            arguments: ["handoff_id": checkpoint.revision.identity.continuityID, "narrative": "Ready to resume"],
            clientID: client, source: .model, finalize: true,
            authorization: auth, automaticHandoffEnabled: true
        )
        let delivery = try XCTUnwrap(handoff.delivery)
        XCTAssertEqual(delivery.handoff, handoff.revision)
        XCTAssertEqual(try app.store.pendingContinuityHandoffs().map(\.operationID), [delivery.operationID])
        XCTAssertGreaterThan(handoff.revision.identity.revision, checkpoint.revision.identity.revision)

        var mutable = try XCTUnwrap(app.store.handoffGet(id: handoff.revision.identity.continuityID))
        mutable.goal = "Later compatibility edit"
        try app.store.handoffUpsert(mutable)
        let restored = try app.continuity.authorizedHandoff(identity: handoff.revision.identity, authorization: auth)
        XCTAssertEqual(restored.canonicalPacketJSON, handoff.revision.canonicalPacketJSON)
        let packet = try XCTUnwrap(HandoffPacket.fromDictionary(JSONSupport.object(from: restored.canonicalPacketJSON)))
        XCTAssertEqual(packet.goal, "Approved task progress")
        XCTAssertEqual(packet.narrative, "Ready to resume")

        let laterCheckpoint = try app.continuity.commitAuthorizedHandoff(
            arguments: ["handoff_id": handoff.revision.identity.continuityID, "narrative": "Later soft checkpoint"],
            clientID: client, source: .auto, finalize: false,
            authorization: auth, automaticHandoffEnabled: true
        )
        XCTAssertFalse(laterCheckpoint.revision.resumeReady)
        XCTAssertNil(laterCheckpoint.delivery)
        XCTAssertEqual(try app.store.pendingContinuityHandoffs().map(\.operationID), [delivery.operationID])
        XCTAssertEqual(try app.continuity.authorizedHandoff(identity: handoff.revision.identity, authorization: auth), handoff.revision)
    }

    func testAuthorizedUpdateDoesNotReadAnotherTaskSharingTheTransport() throws {
        let original = try authorization()
        let other = try authorization()
        let first = try app.continuity.commitAuthorizedHandoff(
            arguments: ["goal": "Private task A"], clientID: ClientID("same-process"),
            source: .model, finalize: true, authorization: original, automaticHandoffEnabled: true
        )
        XCTAssertThrowsError(try app.continuity.commitAuthorizedHandoff(
            arguments: ["handoff_id": first.revision.identity.continuityID, "goal": "Task B"],
            clientID: ClientID("same-process"), source: .model, finalize: true,
            authorization: other, automaticHandoffEnabled: true
        )) { XCTAssertEqual($0 as? ContinuityIngressError, .authorityMismatch) }
        XCTAssertThrowsError(try app.continuity.authorizedHandoff(identity: first.revision.identity, authorization: other)) {
            XCTAssertEqual($0 as? ContinuityIngressError, .authorityMismatch)
        }
        XCTAssertEqual(try app.store.pendingContinuityHandoffs().count, 1)
        XCTAssertEqual(try app.continuity.authorizedHandoff(identity: first.revision.identity, authorization: original), first.revision)
        XCTAssertEqual(try app.continuity.get(id: first.revision.identity.continuityID)["found"] as? Bool, false)
        XCTAssertEqual(try app.continuity.get()["found"] as? Bool, false)
        XCTAssertEqual(try app.continuity.list()["count"] as? Int, 0)
        XCTAssertThrowsError(try app.continuity.handoff(
            arguments: ["handoff_id": first.revision.identity.continuityID, "goal": "Unbound overwrite"],
            clientID: ClientID("same-process")
        ))
        XCTAssertEqual(try app.continuity.authorizedHandoff(identity: first.revision.identity, authorization: original), first.revision)
    }

    func testProvisionalContextToolReadsFrozenSourceAndRejectsLatestOrConflictingAliases() throws {
        let auth = try authorization()
        let committed = try app.continuity.commitAuthorizedHandoff(
            arguments: ["goal": "Exact source work", "narrative": "Frozen progress"],
            clientID: ClientID("provisional-source"), source: .model, finalize: true,
            authorization: auth, automaticHandoffEnabled: true)
        let identity = committed.revision.identity
        var compatibility = try XCTUnwrap(app.store.handoffGet(id: identity.continuityID))
        compatibility.narrative = "Later mutable compatibility value"
        try app.store.handoffUpsert(compatibility)
        for key in ["handoff_id", "id"] {
            let result = try ContinuityToolPack.provisionalContextGet(
                arguments: [key: identity.continuityID], identity: identity, authorization: auth,
                continuity: app.continuity)
            XCTAssertTrue(result.ok)
            XCTAssertFalse(result.isError)
            XCTAssertEqual(result.payload["found"] as? Bool, true)
            let packet = try XCTUnwrap(result.payload["packet"] as? [String: Any])
            XCTAssertEqual(try ForgeJSONCanonicalizationV1.data(from: packet), committed.revision.canonicalPacketJSON)
            XCTAssertEqual(result.payload["packet_sha256"] as? String, identity.packetSHA256)
            XCTAssertNil(result.payload["workspace_adopted"])
            XCTAssertNil(result.payload["context_budget_cleared"])
        }
        let invalidArguments: [[String: Any]] = [
            [:], ["resume_ready": true], ["handoff_id": "another-task"],
            ["handoff_id": identity.continuityID, "id": "another-task"],
            ["handoff_id": identity.continuityID, "resume_ready": 1],
            ["handoff_id": identity.continuityID, "revision": identity.revision],
            ["id": NSNull()],
        ]
        for arguments in invalidArguments {
            XCTAssertThrowsError(try ContinuityToolPack.provisionalContextGet(
                arguments: arguments, identity: identity, authorization: auth, continuity: app.continuity))
        }
        XCTAssertThrowsError(try ContinuityToolPack.provisionalContextGet(
            arguments: ["id": identity.continuityID], identity: identity,
            authorization: authorization(), continuity: app.continuity))
        XCTAssertEqual(try app.continuity.get(id: identity.continuityID)["found"] as? Bool, false)
        XCTAssertEqual(try app.store.handoffGet(id: identity.continuityID)?.narrative, compatibility.narrative)
    }

    func testProvisionalContextToolRejectsOversizeAndCancelledReadsWithoutTruncation() throws {
        let auth = try authorization()
        let committed = try app.continuity.commitAuthorizedHandoff(
            arguments: ["narrative": String(repeating: "x", count: 16_384)],
            clientID: ClientID("large-provisional-source"), source: .model, finalize: true,
            authorization: auth, automaticHandoffEnabled: true)
        XCTAssertGreaterThan(committed.revision.canonicalPacketJSON.count, auth.authorizationScope.maximumInlineOutputBytes)
        XCTAssertThrowsError(try ContinuityToolPack.provisionalContextGet(
            arguments: ["id": committed.revision.identity.continuityID],
            identity: committed.revision.identity, authorization: auth, continuity: app.continuity)) {
            XCTAssertEqual($0 as? AutonomyError, .resultTooLarge)
        }
        let cancelled = ToolCallCancellation()
        cancelled.cancel()
        XCTAssertThrowsError(try ContinuityToolPack.provisionalContextGet(
            arguments: ["id": committed.revision.identity.continuityID],
            identity: committed.revision.identity, authorization: auth,
            continuity: app.continuity, cancellation: cancelled)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try app.continuity.authorizedHandoff(identity: committed.revision.identity,
            authorization: auth), committed.revision)
    }

    func testAuthorizedPacketDoesNotInheritLegacyClientLatestOrAgentGoal() throws {
        let client = ClientID("shared-process")
        _ = try app.config.update(["allowed_roots": [home.path]])
        let session = try app.tools.call(name: "agent_run_start", arguments: [
            "agent_id": "debug", "goal": "Private legacy goal", "cwd": home.path,
        ], clientID: client)
        XCTAssertTrue(session.ok, "\(session.payload)")
        let legacy = try app.continuity.checkpoint(arguments: [
            "goal": "Private legacy goal", "cwd": home.path, "narrative": "Legacy notes",
        ], clientID: client)
        let scoped = try app.continuity.commitAuthorizedHandoff(
            arguments: ["status": "in_progress"], clientID: client, source: .auto, finalize: false,
            authorization: authorization(), automaticHandoffEnabled: true
        )
        XCTAssertNotEqual(scoped.revision.identity.continuityID, legacy["handoff_id"] as? String)
        let packet = try XCTUnwrap(HandoffPacket.fromDictionary(JSONSupport.object(from: scoped.revision.canonicalPacketJSON)))
        XCTAssertTrue(packet.goal.isEmpty)
        XCTAssertNil(packet.cwd)
        XCTAssertTrue(packet.agents.isEmpty)
        XCTAssertTrue(packet.narrative.isEmpty)
        XCTAssertNil(scoped.delivery)
    }

    func testRuntimeAndBudgetHandoffsRespectDisabledAutomaticDelivery() throws {
        for source in [HandoffSource.auto, .budget] {
            let auth = try authorization()
            let result = try app.continuity.commitAuthorizedHandoff(
                arguments: ["goal": "Runtime checkpoint"], clientID: ClientID("runtime"),
                source: source, finalize: true, authorization: auth, automaticHandoffEnabled: false
            )
            XCTAssertTrue(result.revision.resumeReady)
            XCTAssertNil(result.delivery)
            XCTAssertEqual(try app.continuity.authorizedHandoff(identity: result.revision.identity, authorization: auth), result.revision)
        }
        XCTAssertTrue(try app.store.pendingContinuityHandoffs().isEmpty)
    }

    func testAuthorizedPacketDoesNotPublishSharedLegacyProjectionsAfterRestart() throws {
        let legacy = try app.continuity.handoff(
            arguments: ["goal": "Legacy public checkpoint", "narrative": "Legacy notes"],
            clientID: ClientID("legacy-client")
        )
        let legacyID = try XCTUnwrap(legacy["handoff_id"] as? String)
        let latestURL = app.paths.memoryHandoffsDir.appendingPathComponent("LATEST")
        let currentTaskURL = app.paths.memoryCurrentTask
        let priorLatest = try Data(contentsOf: latestURL)
        let priorCurrentTask = try Data(contentsOf: currentTaskURL)
        let auth = try authorization()
        let scoped = try app.continuity.commitAuthorizedHandoff(
            arguments: ["goal": "Private scoped goal", "narrative": "Private scoped notes"],
            clientID: ClientID("shared-process"), source: .model, finalize: true,
            authorization: auth, automaticHandoffEnabled: true
        )
        let scopedProjection = app.paths.memoryHandoffsDir
            .appendingPathComponent("\(scoped.revision.identity.continuityID).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scopedProjection.path))
        XCTAssertEqual(try Data(contentsOf: latestURL), priorLatest)
        XCTAssertEqual(try Data(contentsOf: currentTaskURL), priorCurrentTask)
        XCTAssertEqual(try app.store.memoryGet(key: "continuity/latest"), legacyID)
        XCTAssertEqual(try app.store.memoryGet(key: "continuity/resume_ready"), legacyID)

        app.shutdown()
        app = try ForgeApp.bootstrap(home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scopedProjection.path))
        XCTAssertEqual(try Data(contentsOf: latestURL), priorLatest)
        XCTAssertEqual(try Data(contentsOf: currentTaskURL), priorCurrentTask)
        XCTAssertEqual(try app.store.memoryGet(key: "continuity/latest"), legacyID)
        XCTAssertEqual(try app.store.memoryGet(key: "continuity/resume_ready"), legacyID)
        XCTAssertEqual(try app.continuity.authorizedHandoff(identity: scoped.revision.identity,
            authorization: auth), scoped.revision)
        XCTAssertEqual(try app.store.pendingContinuityHandoffs().count, 1)
    }

    func testLiveTaskGuardCommitsSourceAndRejectsRevokedTaskBeforeMutation() async throws {
        let repository = app.projectContexts.repository
        let projectID = ProjectID()
        let owner = ProjectBindingOwner(kind: .mcpClient, id: "authorized-origin")
        let scope = ToolAuthorizationScope(canonicalRoots: [home], writableRoots: [],
            allowedTools: ["fs_read"], networkAllowed: false, maximumInlineOutputBytes: 4_096)
        _ = try await repository.registerProjectUnchecked(projectID: projectID,
            displayName: "Authorized source task", canonicalRoot: home)
        let binding = try await repository.bind(owner: owner, projectID: projectID,
            generation: .initial, authorizationScope: scope)
        let context = binding.invocationContext(clientID: ClientID(owner.id))
        let approved = try ContinuityTaskAssignment(assignmentID: "operator-assignment",
            assignmentBytes: Data("Read the approved fixture".utf8), mission: "Read the approved fixture",
            providerID: "lmstudio", adapterID: "lmstudio", modelKey: "fixture-model",
            specification: AutonomousRunSpecification(allowedTools: ["fs_read"], completionGates: ["G04"]),
            authorizationScope: scope)
        let setup = try await repository.authorizeContinuityTask(projectID: projectID,
            expectedGeneration: .initial, approvedAssignment: approved,
            callerContext: context, callerOwner: owner)
        let service = app.continuity
        let committed = try await repository.withAuthorizedContinuityTask(
            taskID: setup.record.authorization.taskID, correlation: setup.correlation,
            context: context, owner: owner
        ) { authorization in
            try service.commitAuthorizedHandoff(arguments: ["goal": "Untrusted progress text"],
                clientID: context.clientID, source: .model, finalize: true,
                authorization: authorization, automaticHandoffEnabled: true)
        }
        let authorized = try await repository.validateContinuityIngressAuthorization(committed.revision.authorization)
        XCTAssertEqual(authorized.assignment.mission, "Read the approved fixture")
        XCTAssertEqual(authorized.assignment.authorizationScope.writableRoots, [])
        XCTAssertEqual(committed.revision.authorization.assignmentSHA256, approved.assignmentSHA256)

        _ = try await repository.revokeContinuityTask(taskID: setup.record.authorization.taskID,
            projectID: projectID, expectedGeneration: .initial)
        do {
            _ = try await repository.withAuthorizedContinuityTask(
                taskID: setup.record.authorization.taskID, correlation: setup.correlation,
                context: context, owner: owner
            ) { authorization in
                try service.commitAuthorizedHandoff(arguments: ["goal": "Must never commit"],
                    clientID: context.clientID, source: .auto, finalize: true,
                    authorization: authorization, automaticHandoffEnabled: true)
            }
            XCTFail("Revoked task must be rejected before a new source commit")
        } catch {
            XCTAssertEqual(error as? ContinuityTaskAuthorizationError, .revoked)
        }
        XCTAssertEqual(try app.store.pendingContinuityHandoffs().count, 1)
        do {
            _ = try await repository.validateContinuityIngressAuthorization(committed.revision.authorization)
            XCTFail("Revoked source snapshot must not admit later provider work")
        } catch {
            XCTAssertEqual(error as? ContinuityTaskAuthorizationError, .revoked)
        }
    }
}

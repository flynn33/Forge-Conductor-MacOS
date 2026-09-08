import XCTest
@testable import ForgeConductorCore

final class NativePreparedSourceCommitTests: XCTestCase {
    private var home: URL!
    private var app: ForgeApp!
    private let client = ClientID("native-source-preparation")

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("native-source-preparation-\(UUID())")
        app = try ForgeApp.bootstrap(home: home)
    }

    override func tearDownWithError() throws {
        app?.shutdown()
        app = nil
        try? FileManager.default.removeItem(at: home)
    }

    // These are source-store component fixtures. Production capability/caller
    // ownership is separately exercised at the CP and actual HTTP boundaries.
    private func authorization() throws -> ContinuityIngressAuthorization {
        try .init(projectID: ProjectID(), projectGeneration: .initial,
            sourceBindingID: UUID(), taskID: UUID(), assignmentID: "approved-source",
            assignmentSHA256: String(repeating: "a", count: 64),
            authorizationScope: .init(canonicalRoots: [home], writableRoots: [],
                allowedTools: ["fs_read"], networkAllowed: false, maximumInlineOutputBytes: 65_536))
    }

    func testPreparationWritesNoSourceAndFrozenPacketReplaysAfterActualStoreReopen() throws {
        let authority = try authorization()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let service = ContextContinuityService(paths: app.paths, store: app.store,
            sessions: app.sessions, diagnostics: app.diagnostics, clock: clock)
        let prepared = try service.prepareAuthorizedSourceCommit(
            arguments: ["goal": "Continue exact approved work", "narrative": "Frozen progress"],
            clientID: client, source: .model, finalize: true, authorization: authority)
        XCTAssertTrue(try app.store.handoffListAll().isEmpty)
        XCTAssertTrue(try app.store.pendingContinuityHandoffs().isEmpty)
        XCTAssertEqual(try prepared.packet().updatedAt, ISO8601.string(from: clock.now()))

        clock.date = clock.date.addingTimeInterval(3_600)
        let committed = try service.commitPreparedAuthorizedSourceCommit(prepared,
            authorization: authority, automaticHandoffEnabled: true)
        XCTAssertEqual(committed.revision.canonicalPacketJSON, prepared.canonicalPacketJSON)
        let firstDelivery = try XCTUnwrap(committed.delivery)
        let frozen = prepared.canonicalPacketJSON
        app.shutdown()
        app = nil
        app = try ForgeApp.bootstrap(home: home)
        let restored = try PreparedContinuitySourceCommit.storedSnapshot(from: frozen)
        let replay = try app.continuity.commitPreparedAuthorizedSourceCommit(restored,
            authorization: authority, automaticHandoffEnabled: true)
        XCTAssertEqual(replay, committed)
        XCTAssertEqual(try app.store.pendingContinuityHandoffs().map(\.operationID), [firstDelivery.operationID])
        XCTAssertEqual(try app.store.handoffListAll().count, 1)
    }

    func testPreparedUpdateDoesNotRebuildFromLaterMutableCheckpoint() throws {
        let authority = try authorization()
        let first = try app.continuity.commitAuthorizedHandoff(arguments: ["goal": "Original"],
            clientID: client, source: .model, finalize: false, authorization: authority,
            automaticHandoffEnabled: false)
        let prepared = try app.continuity.prepareAuthorizedSourceCommit(arguments: [
            "handoff_id": first.revision.identity.continuityID, "narrative": "Exact prepared progress",
        ], clientID: client, source: .model, finalize: true, authorization: authority)
        _ = try app.continuity.commitAuthorizedHandoff(arguments: [
            "handoff_id": first.revision.identity.continuityID, "goal": "Later checkpoint goal",
        ], clientID: client, source: .model, finalize: false, authorization: authority,
            automaticHandoffEnabled: false)
        let final = try app.continuity.commitPreparedAuthorizedSourceCommit(prepared,
            authorization: authority, automaticHandoffEnabled: true)
        XCTAssertEqual(try prepared.packet().goal, "Original")
        XCTAssertEqual(final.revision.canonicalPacketJSON, prepared.canonicalPacketJSON)

        let later = try app.continuity.commitAuthorizedHandoff(arguments: [
            "handoff_id": first.revision.identity.continuityID, "goal": "Later compatibility view",
        ], clientID: client, source: .model, finalize: false, authorization: authority,
            automaticHandoffEnabled: false)
        let replay = try app.continuity.commitPreparedAuthorizedSourceCommit(prepared,
            authorization: authority, automaticHandoffEnabled: true)
        XCTAssertEqual(replay, final)
        XCTAssertEqual(try app.store.continuityLatestRevision(continuityID: prepared.continuityID,
            authorization: authority)?.identity, later.revision.identity)
    }

    func testPreparationRejectsInvalidSnapshotsFieldCapacityAndCancellationBeforeMutation() throws {
        let authority = try authorization()
        XCTAssertThrowsError(try PreparedContinuitySourceCommit.storedSnapshot(from: Data("{}".utf8)))
        let valid = try app.continuity.prepareAuthorizedSourceCommit(arguments: ["goal": "Bounded"],
            clientID: client, source: .model, finalize: false, authorization: authority)
        var object = try JSONSupport.object(from: valid.canonicalPacketJSON)
        object["unchecked_extension"] = "discarded by packet decoder"
        XCTAssertThrowsError(try PreparedContinuitySourceCommit.storedSnapshot(
            from: ForgeJSONCanonicalizationV1.data(from: object)))
        XCTAssertThrowsError(try app.continuity.prepareAuthorizedSourceCommit(arguments: [
            "goal": "Invalid field count", "decisions": Array(repeating: "decision", count: 129),
        ], clientID: client, source: .model, finalize: true, authorization: authority))
        let cancellation = ToolCallCancellation(timeoutSeconds: 10)
        cancellation.cancel()
        XCTAssertThrowsError(try app.continuity.prepareAuthorizedSourceCommit(arguments: ["goal": "Cancelled"],
            clientID: client, source: .model, finalize: true, authorization: authority,
            cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(try app.store.handoffListAll().isEmpty)
        XCTAssertTrue(try app.store.pendingContinuityHandoffs().isEmpty)
    }

    func testWireExpansionIsRejectedBeforeCommitAndAcceptedResponseUsesSharedEncoder() throws {
        let authority = try authorization()
        // Packet bytes fit SQLite, but repeating an escaped seed in both the
        // text and structured MCP response would exceed the HTTP wire bound.
        let largeSeed = String(repeating: "\\", count: 125_000)
        let packet = HandoffPacket(source: .model, resumeReady: true, clientID: client.rawValue,
            goal: "Bounded source", resumeSeed: largeSeed, resumeSeedIsCustom: true)
        let validated = try PreparedContinuitySourceCommit.preparing(packet)
        XCTAssertLessThan(validated.canonicalPacketJSON.count, ContinuityIngressLimits.maximumPacketBytes)
        XCTAssertThrowsError(try app.continuity.requireNativeSourceResponseBudget(validated))
        XCTAssertThrowsError(try app.continuity.commitPreparedAuthorizedSourceCommit(validated,
            authorization: authority, automaticHandoffEnabled: true))
        XCTAssertThrowsError(try app.continuity.prepareAuthorizedSourceCommit(arguments: [
            "goal": "Bounded source", "resume_seed": largeSeed,
        ], clientID: client, source: .model, finalize: true, authorization: authority))
        XCTAssertTrue(try app.store.handoffListAll().isEmpty)
        XCTAssertTrue(try app.store.pendingContinuityHandoffs().isEmpty)

        let accepted = try app.continuity.prepareAuthorizedSourceCommit(arguments: [
            "goal": "Escaped source", "resume_seed": String(repeating: "\"\\\n", count: 100),
        ], clientID: client, source: .model, finalize: true, authorization: authority)
        let result = try app.continuity.commitPreparedAuthorizedSourceCommit(accepted,
            authorization: authority, automaticHandoffEnabled: true)
        let payload = try app.continuity.authorizedCommitPayload(result, finalize: true)
        let wire = try MCPToolResponse.data(id: String(repeating: "\u{0}", count: 256), result: .success(payload))
        XCTAssertLessThanOrEqual(wire.count, 1_048_576)
        let decoded = try JSONSupport.object(from: wire)
        let content = try XCTUnwrap(decoded["result"] as? [String: Any])
        let structured = try XCTUnwrap(content["structuredContent"] as? [String: Any])
        XCTAssertEqual(try JSONSupport.data(from: structured), try JSONSupport.data(from: payload))
        XCTAssertEqual(try app.store.pendingContinuityHandoffs().count, 1)
    }
}

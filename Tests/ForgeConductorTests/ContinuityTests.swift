// ContinuityTests.swift
// Context + agent continuity: checkpoint, handoff, resume, budget loop.

import XCTest
import SQLite3
import Darwin
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class ContinuityTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    private func bindProjectContext(
        _ app: ForgeApp,
        clientID: ClientID,
        root: URL? = nil
    ) throws {
        let canonicalRoot = try XCTUnwrap(root ?? tempHome)
        let initialized = try app.projectMemory.initializeUnchecked(path: canonicalRoot.path)
        let projectID = try XCTUnwrap(initialized["project_id"] as? String)
        let descriptor = try app.projectMemory.identities.descriptor(projectID: projectID)
        _ = try app.projectContexts.registerAndBindMCPClientUnchecked(
            descriptor: descriptor,
            canonicalRoot: canonicalRoot,
            clientID: clientID
        )
    }

    private func configureAllowedProjectRoot(
        _ app: ForgeApp,
        root: URL? = nil
    ) throws {
        _ = try app.config.update(
            ["allowed_roots": [(root ?? tempHome).path]],
            save: false
        )
    }

    func testMemoryLayoutCreatedOnBootstrap() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.memoryDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.memoryHandoffsDir.path))
    }

    func testCheckpointAndContextGetRoundTrip() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("continuity-1")

        let cp = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "goal": "Fix Mirmir upscale crash",
                "status": "investigating",
                "cwd": "/Users/jimdaley/GitHub/Mirmir",
                "project_slug": "mirmir",
                "next_actions": ["Read pipeline", "Reproduce crash"],
                "narrative": "Looking at VTEncoder logs",
                "key_files": ["AVFoundationMediaPipeline.swift"],
            ],
            clientID: client
        )
        XCTAssertTrue(cp.ok, "\(cp.payload)")
        let handoffID = cp.payload["handoff_id"] as? String
        XCTAssertNotNil(handoffID)
        XCTAssertEqual(cp.payload["resume_ready"] as? Bool, false)

        let get = try app.tools.call(name: "context_get", arguments: [:], clientID: client)
        XCTAssertTrue(get.ok)
        XCTAssertEqual(get.payload["found"] as? Bool, true)
        XCTAssertEqual(get.payload["handoff_id"] as? String, handoffID)

        let packet = get.payload["packet"] as? [String: Any]
        let task = packet?["task"] as? [String: Any]
        XCTAssertEqual(task?["goal"] as? String, "Fix Mirmir upscale crash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.memoryCurrentTask.path))
    }

    func testOperatorPacketListAndBatchDeleteUseExactHandoffPacketIDs() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let first = try app.continuity.checkpoint(
            arguments: ["goal": "Disposable checkpoint", "cwd": tempHome.path],
            clientID: ClientID("disposable-checkpoint")
        )
        let second = try app.continuity.handoff(
            arguments: ["goal": "Disposable handoff", "cwd": tempHome.path],
            clientID: ClientID("disposable-handoff")
        )
        let ids = [
            try XCTUnwrap(first["handoff_id"] as? String),
            try XCTUnwrap(second["handoff_id"] as? String),
        ]
        let listed = try app.continuity.operatorPackets()
        XCTAssertEqual(Set(listed.map(\.id)), Set(ids))
        XCTAssertEqual(listed.first(where: { $0.id == ids[0] })?.resumeReady, false)
        XCTAssertEqual(listed.first(where: { $0.id == ids[1] })?.resumeReady, true)

        let deleted = try app.continuity.deleteOperatorPackets(ids: ids)
        XCTAssertEqual(Set(deleted), Set(ids))
        XCTAssertTrue(try app.continuity.operatorPackets().isEmpty)
        XCTAssertNil(try app.store.handoffGet(id: ids[0]))
        XCTAssertNil(try app.store.handoffGet(id: ids[1]))

        let projectID = ProjectID(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        let wire = OperatorContinuityPacketList(
            projectID: projectID,
            packets: [
                OperatorContinuityPacket(
                    packetID: ids[0],
                    projectID: projectID,
                    type: "checkpoint",
                    source: .auto,
                    timestamp: "2026-09-27T12:00:00Z",
                    resumeReady: false
                ),
            ]
        )
        let encoded = try JSONEncoder().encode(wire)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["project_id"] as? String, projectID.description)
        let rows = try XCTUnwrap(object["packets"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["project_id"] as? String, projectID.description)
        XCTAssertEqual(try JSONDecoder().decode(OperatorContinuityPacketList.self, from: encoded), wire)
    }

    func testHandoffMarksResumeReadyAndSnapshotsAgents() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        let client = ClientID("continuity-agents")

        let start = try app.tools.call(
            name: "agent_run_start",
            arguments: [
                "agent_id": "debug",
                "goal": "Trace upscale crash",
                "cwd": tempHome.path,
            ],
            clientID: client
        )
        XCTAssertTrue(start.ok, "\(start.payload)")
        let sessionID = start.payload["session_id"] as? String
        XCTAssertNotNil(sessionID)

        let handoff = try app.tools.call(
            name: "session_handoff",
            arguments: [
                "goal": "Trace upscale crash",
                "status": "blocked_on_context",
                "cwd": tempHome.path,
                "narrative": "Need new chat to continue debugging",
            ],
            clientID: client
        )
        XCTAssertTrue(handoff.ok, "\(handoff.payload)")
        XCTAssertEqual(handoff.payload["resume_ready"] as? Bool, true)
        XCTAssertEqual(handoff.payload["handoff_required"] as? Bool, true)
        let seed = handoff.payload["resume_seed"] as? String ?? ""
        XCTAssertTrue(seed.contains("context_get") || seed.contains("Forge Continuity"))

        let packet = handoff.payload["packet"] as? [String: Any]
        let agents = packet?["agents"] as? [[String: Any]] ?? []
        XCTAssertFalse(agents.isEmpty, "expected open agent snapshot")
        XCTAssertEqual(agents.first?["session_id"] as? String, sessionID)
        XCTAssertEqual(agents.first?["agent_id"] as? String, "debug")

        let status = try app.tools.call(name: "forge_status", arguments: [:], clientID: client)
        let continuity = status.payload["continuity"] as? [String: Any]
        XCTAssertEqual(continuity?["resume_ready"] as? Bool, true)
    }

    func testNewClientCheckpointPreservesAgentsUntilTheyReattach() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        let originalClient = ClientID("checkpoint-agent-original")
        let resumedClient = ClientID("checkpoint-agent-resumed")

        let start = try app.tools.call(
            name: "agent_run_start",
            arguments: [
                "agent_id": "debug",
                "goal": "Preserve this specialist during resume",
                "cwd": tempHome.path,
            ],
            clientID: originalClient
        )
        let sessionID = try XCTUnwrap(start.payload["session_id"] as? String)
        let handoff = try app.tools.call(
            name: "session_handoff",
            arguments: ["goal": "Resume without losing the specialist"],
            clientID: originalClient
        )
        let handoffID = try XCTUnwrap(handoff.payload["handoff_id"] as? String)

        let recovered = try app.tools.call(
            name: "context_get",
            arguments: ["handoff_id": handoffID],
            clientID: resumedClient
        )
        XCTAssertTrue(recovered.ok)

        let checkpoint = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "handoff_id": handoffID,
                "status": "resuming_before_agent_reattach",
            ],
            clientID: resumedClient
        )
        XCTAssertTrue(checkpoint.ok, "\(checkpoint.payload)")
        let packet = try XCTUnwrap(checkpoint.payload["packet"] as? [String: Any])
        let agents = try XCTUnwrap(packet["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.map { $0["session_id"] as? String }, [sessionID])
        XCTAssertEqual(
            try app.store.sessionGet(id: SessionID(sessionID))?.clientID,
            originalClient,
            "checkpointing alone must not transfer agent ownership"
        )
    }

    func testContextListAndGetById() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("list")
        _ = try app.tools.call(
            name: "session_handoff",
            arguments: ["goal": "A", "status": "done"],
            clientID: client
        )
        _ = try app.tools.call(
            name: "session_handoff",
            arguments: ["goal": "B", "status": "done"],
            clientID: ClientID("list-2")
        )
        let list = try app.tools.call(name: "context_list", arguments: ["limit": 5], clientID: client)
        XCTAssertTrue(list.ok)
        let count = list.payload["count"] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(count, 2)
    }

    func testLatestHandoffUsesWriteOrderWhenTimestampsTie() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let app = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { app.shutdown() }

        let first = try app.tools.call(
            name: "session_handoff",
            arguments: ["goal": "First handoff"],
            clientID: ClientID("tie-first")
        )
        let second = try app.tools.call(
            name: "session_handoff",
            arguments: ["goal": "Second handoff"],
            clientID: ClientID("tie-second")
        )

        let latest = try app.tools.call(
            name: "context_get",
            arguments: [:],
            clientID: ClientID("tie-reader")
        )
        XCTAssertNotEqual(first.payload["handoff_id"] as? String, second.payload["handoff_id"] as? String)
        XCTAssertEqual(latest.payload["handoff_id"] as? String, second.payload["handoff_id"] as? String)

        let listed = try app.tools.call(
            name: "context_list",
            arguments: ["limit": 2],
            clientID: ClientID("tie-reader")
        )
        let handoffs = listed.payload["handoffs"] as? [[String: Any]]
        XCTAssertEqual(handoffs?.first?["id"] as? String, second.payload["handoff_id"] as? String)

        let firstID = try XCTUnwrap(first.payload["handoff_id"] as? String)
        let updatedFirst = try app.tools.call(
            name: "session_handoff",
            arguments: ["handoff_id": firstID, "goal": "First handoff, updated"],
            clientID: ClientID("tie-first")
        )
        XCTAssertEqual(updatedFirst.payload["handoff_id"] as? String, firstID)

        let latestAfterUpdate = try app.tools.call(
            name: "context_get",
            arguments: [:],
            clientID: ClientID("tie-reader")
        )
        XCTAssertEqual(latestAfterUpdate.payload["handoff_id"] as? String, firstID)

        let listedAfterUpdate = try app.tools.call(
            name: "context_list",
            arguments: ["limit": 2],
            clientID: ClientID("tie-reader")
        )
        let reordered = listedAfterUpdate.payload["handoffs"] as? [[String: Any]]
        XCTAssertEqual(reordered?.compactMap { $0["id"] as? String }, [firstID, second.payload["handoff_id"] as? String].compactMap { $0 })
    }

    func testCheckpointUpdateRegeneratesDefaultResumeSeed() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("seed-refresh")

        let initial = try app.tools.call(
            name: "session_checkpoint",
            arguments: ["goal": "Old goal", "next_actions": ["Old action"]],
            clientID: client
        )
        let handoffID = try XCTUnwrap(initial.payload["handoff_id"] as? String)

        let updated = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "handoff_id": handoffID,
                "goal": "Current goal",
                "next_actions": ["Current action"],
            ],
            clientID: client
        )
        let seed = try XCTUnwrap(updated.payload["resume_seed"] as? String)
        XCTAssertTrue(seed.contains("Current goal"), seed)
        XCTAssertTrue(seed.contains("Current action"), seed)
        XCTAssertFalse(seed.contains("Old goal"), seed)
        XCTAssertFalse(seed.contains("Old action"), seed)
    }

    func testCheckpointUpdatePreservesExplicitResumeSeed() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("custom-seed")
        let initial = try app.continuity.checkpoint(
            arguments: [
                "goal": "Initial goal",
                "resume_seed": "Use the operator-provided recovery sequence",
            ],
            clientID: client
        )
        let handoffID = try XCTUnwrap(initial["handoff_id"] as? String)

        let updated = try app.continuity.checkpoint(
            arguments: [
                "handoff_id": handoffID,
                "goal": "Updated goal",
            ],
            clientID: client
        )
        XCTAssertEqual(updated["resume_seed"] as? String, "Use the operator-provided recovery sequence")
        let packet = try XCTUnwrap(app.store.handoffGet(id: handoffID))
        XCTAssertTrue(packet.resumeSeedIsCustom)
        XCTAssertEqual(packet.resumeSeed, "Use the operator-provided recovery sequence")
    }

    func testBudgetHandoffPreservesExplicitAndLegacyCustomResumeSeeds() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("budget-custom-seed")
        let customSeed = "Follow the operator recovery sequence exactly"
        let checkpoint = try app.continuity.checkpoint(
            arguments: ["goal": "Preserve custom resume", "resume_seed": customSeed],
            clientID: client
        )
        let handoffID = try XCTUnwrap(checkpoint["handoff_id"] as? String)

        let budget = try app.continuity.budgetAutoCheckpoint(
            clientID: client,
            reason: "custom seed preservation"
        )
        XCTAssertEqual(budget.id, handoffID)
        XCTAssertEqual(budget.resumeSeed, customSeed)
        XCTAssertTrue(budget.resumeSeedIsCustom)

        var legacyCustom = HandoffPacket(
            id: "legacy-custom-seed",
            resumeSeed: "Use the legacy operator sequence"
        ).asDictionary()
        var customResume = try XCTUnwrap(legacyCustom["resume"] as? [String: Any])
        customResume.removeValue(forKey: "custom")
        legacyCustom["resume"] = customResume
        let decodedCustom = try XCTUnwrap(HandoffPacket.fromDictionary(legacyCustom))
        XCTAssertTrue(decodedCustom.resumeSeedIsCustom)

        var generatedPacket = HandoffPacket(id: "legacy-generated-seed", goal: "Legacy generated")
        generatedPacket.resumeSeed = generatedPacket.defaultResumeSeed()
        var legacyGenerated = generatedPacket.asDictionary()
        var generatedResume = try XCTUnwrap(legacyGenerated["resume"] as? [String: Any])
        generatedResume.removeValue(forKey: "custom")
        legacyGenerated["resume"] = generatedResume
        XCTAssertFalse(try XCTUnwrap(HandoffPacket.fromDictionary(legacyGenerated)).resumeSeedIsCustom)
    }

    func testCoherentResumeKeepsCurrentAssignmentAcrossSaveAndRestore() throws {
        // SLICE-03 fixture: one current slice plus one clearly superseded old
        // task, saved and restored through the real tool paths in an isolated
        // store. It does not load the incident packet and does not touch live
        // continuity storage. Reading an identifier back is not proof: every
        // assertion below checks field content (goal, narrative, next action,
        // resume instruction).
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let app = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { app.shutdown() }
        let oldClient = ClientID("coherent-resume-old")
        let currentClient = ClientID("coherent-resume-current")
        let readerClient = ClientID("coherent-resume-reader")

        let oldGoal = "Alpha recovery: repair the legacy daemon"
        let oldNarrative = "Old alpha recovery assignment, replaced by the small-slice sequence."
        let oldNext = "Resume the alpha recovery steps"
        let oldSeed = "Resume the old alpha recovery package from its saved instructions."

        // 1. The clearly superseded old task is finalized first.
        let old = try app.tools.call(
            name: "session_handoff",
            arguments: [
                "goal": oldGoal,
                "status": "superseded",
                "narrative": oldNarrative,
                "next_actions": [oldNext],
                "resume_seed": oldSeed,
            ],
            clientID: oldClient
        )
        XCTAssertTrue(old.ok, "\(old.payload)")
        let oldID = try XCTUnwrap(old.payload["handoff_id"] as? String)

        // 2. The current slice is finalized after the old task, so the current
        // record is the latest resume-ready one by write order.
        let currentGoal = "SLICE-03: Keep the current assignment consistent across a saved resume"
        let midNarrative = "SLICE-03 focused checks are running on branch qwen-slice-03-coherent-resume."
        let midNext = "Run the focused checkpoint/restore test"
        let midSeed = "Resume only SLICE-03. Current stage is testing. Next action: \(midNext); do not start another slice."
        let current = try app.tools.call(
            name: "session_handoff",
            arguments: [
                "goal": currentGoal,
                "status": "testing",
                "narrative": midNarrative,
                "next_actions": [midNext],
                "resume_seed": midSeed,
            ],
            clientID: currentClient
        )
        XCTAssertTrue(current.ok, "\(current.payload)")
        let currentID = try XCTUnwrap(current.payload["handoff_id"] as? String)
        XCTAssertNotEqual(oldID, currentID)

        // 3. New-chat bootstrap restore returns the current slice, not the
        // superseded old assignment.
        let restored = try app.tools.call(
            name: "context_get",
            arguments: ["resume_ready": true],
            clientID: readerClient
        )
        XCTAssertEqual(restored.payload["found"] as? Bool, true)
        XCTAssertEqual(restored.payload["handoff_id"] as? String, currentID)
        let restoredPacket = try XCTUnwrap(restored.payload["packet"] as? [String: Any])
        let restoredTask = try XCTUnwrap(restoredPacket["task"] as? [String: Any])
        XCTAssertEqual(restoredTask["goal"] as? String, currentGoal)
        XCTAssertEqual(restoredTask["next_actions"] as? [String], [midNext])
        XCTAssertEqual(restoredPacket["narrative"] as? String, midNarrative)
        let restoredResume = try XCTUnwrap(restoredPacket["resume"] as? [String: Any])
        XCTAssertEqual(restoredResume["seed"] as? String, midSeed)
        XCTAssertFalse((restoredResume["seed"] as? String ?? "").contains("alpha recovery"))

        // 4. A progress save on the current record moves it to the open-PR
        // pause. The supported mutable checkpoint path takes explicit fields;
        // every supplied field describes the same slice and pause state.
        let pauseStatus = "pr_open_awaiting_owner_review"
        let pauseNarrative = "SLICE-03 PR opened for owner review; implementation preserved."
        let pauseNext = "Wait for the owner's instruction on the open PR; do not start another slice."
        let pauseSeed = "Resume only SLICE-03. Current stage is PR-open. Next action: \(pauseNext)"
        let progress = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "handoff_id": currentID,
                "status": pauseStatus,
                "narrative": pauseNarrative,
                "next_actions": [pauseNext],
                "resume_seed": pauseSeed,
            ],
            clientID: currentClient
        )
        XCTAssertTrue(progress.ok, "\(progress.payload)")
        let storedCurrent = try XCTUnwrap(app.store.handoffGet(id: currentID))
        XCTAssertEqual(storedCurrent.goal, currentGoal)
        XCTAssertEqual(storedCurrent.status, pauseStatus)
        XCTAssertEqual(storedCurrent.narrative, pauseNarrative)
        XCTAssertEqual(storedCurrent.nextActions, [pauseNext])
        XCTAssertEqual(storedCurrent.resumeSeed, pauseSeed)
        XCTAssertTrue(storedCurrent.resumeSeedIsCustom)

        // 5. The progress save stays the latest record, and the open-PR pause
        // survives restoration as a pause. No field tells the successor to
        // start another slice.
        let latest = try app.tools.call(
            name: "context_get",
            arguments: [:],
            clientID: readerClient
        )
        XCTAssertEqual(latest.payload["found"] as? Bool, true)
        XCTAssertEqual(latest.payload["handoff_id"] as? String, currentID)

        let pauseRestored = try app.tools.call(
            name: "context_get",
            arguments: ["resume_ready": true],
            clientID: ClientID("coherent-resume-reader-2")
        )
        XCTAssertEqual(pauseRestored.payload["found"] as? Bool, true)
        XCTAssertEqual(pauseRestored.payload["handoff_id"] as? String, currentID)
        let pausePacket = try XCTUnwrap(pauseRestored.payload["packet"] as? [String: Any])
        let pauseTask = try XCTUnwrap(pausePacket["task"] as? [String: Any])
        XCTAssertEqual(pauseTask["goal"] as? String, currentGoal)
        XCTAssertEqual(pauseTask["status"] as? String, pauseStatus)
        XCTAssertEqual(pauseTask["next_actions"] as? [String], [pauseNext])
        XCTAssertEqual(pausePacket["narrative"] as? String, pauseNarrative)
        let pauseResume = try XCTUnwrap(pausePacket["resume"] as? [String: Any])
        XCTAssertEqual(pauseResume["seed"] as? String, pauseSeed)
        XCTAssertFalse((pauseResume["seed"] as? String ?? "").contains("alpha recovery"))
        XCTAssertFalse((pauseTask["goal"] as? String ?? "").contains("alpha recovery"))
        for action in pauseTask["next_actions"] as? [String] ?? [] {
            XCTAssertTrue(action.contains("do not start another slice"), action)
        }
        XCTAssertTrue(pauseSeed.contains("do not start another slice"), pauseSeed)

        // 6. The superseded old record is immutable: restored exactly as saved,
        // including its custom seed marker. The source did not rewrite it.
        let oldRead = try app.tools.call(
            name: "context_get",
            arguments: ["handoff_id": oldID],
            clientID: readerClient
        )
        XCTAssertEqual(oldRead.payload["found"] as? Bool, true)
        let oldPacket = try XCTUnwrap(oldRead.payload["packet"] as? [String: Any])
        let oldTask = try XCTUnwrap(oldPacket["task"] as? [String: Any])
        XCTAssertEqual(oldTask["goal"] as? String, oldGoal)
        XCTAssertEqual(oldTask["status"] as? String, "superseded")
        XCTAssertEqual(oldTask["next_actions"] as? [String], [oldNext])
        XCTAssertEqual(oldPacket["narrative"] as? String, oldNarrative)
        XCTAssertEqual(try XCTUnwrap(oldPacket["resume"] as? [String: Any])["seed"] as? String, oldSeed)
        let storedOld = try XCTUnwrap(app.store.handoffGet(id: oldID))
        XCTAssertEqual(storedOld.resumeSeed, oldSeed)
        XCTAssertTrue(storedOld.resumeSeedIsCustom)
    }

    func testUnknownExplicitHandoffIDFailsWithoutMutation() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("unknown-handoff")
        let original = try app.tools.call(
            name: "session_checkpoint",
            arguments: ["goal": "Original state"],
            clientID: client
        )
        let originalID = try XCTUnwrap(original.payload["handoff_id"] as? String)

        let rejected = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "handoff_id": "missing-handoff",
                "goal": "Must not overwrite or create state",
            ],
            clientID: client
        )
        XCTAssertFalse(rejected.ok)
        XCTAssertTrue(rejected.isError)

        let packets = try app.store.handoffList(limit: 10)
        XCTAssertEqual(packets.map(\.id), [originalID])
        XCTAssertEqual(packets.first?.goal, "Original state")
    }

    func testPacketDecoderRejectsUnsupportedOrCorruptIdentityMetadata() throws {
        let packet = HandoffPacket(id: "valid-handoff", goal: "Valid")

        var unsupported = packet.asDictionary()
        unsupported["schema_version"] = HandoffPacket.schemaVersion + 1
        XCTAssertNil(HandoffPacket.fromDictionary(unsupported))

        var conflicting = packet.asDictionary()
        var conflictingMeta = try XCTUnwrap(conflicting["meta"] as? [String: Any])
        conflictingMeta["schema_version"] = HandoffPacket.schemaVersion + 1
        conflicting["meta"] = conflictingMeta
        XCTAssertNil(HandoffPacket.fromDictionary(conflicting))

        var unknownSource = packet.asDictionary()
        var sourceMeta = try XCTUnwrap(unknownSource["meta"] as? [String: Any])
        sourceMeta["source"] = "unknown"
        unknownSource["meta"] = sourceMeta
        XCTAssertNil(HandoffPacket.fromDictionary(unknownSource))

        var emptyID = packet.asDictionary()
        var emptyIDMeta = try XCTUnwrap(emptyID["meta"] as? [String: Any])
        emptyIDMeta["id"] = "  "
        emptyID["meta"] = emptyIDMeta
        XCTAssertNil(HandoffPacket.fromDictionary(emptyID))

        var pathEscape = packet.asDictionary()
        var pathEscapeMeta = try XCTUnwrap(pathEscape["meta"] as? [String: Any])
        pathEscapeMeta["id"] = "../escape"
        pathEscape["meta"] = pathEscapeMeta
        XCTAssertNil(HandoffPacket.fromDictionary(pathEscape))

        var malformedAgent = packet.asDictionary()
        malformedAgent["agents"] = [["session_id": "", "agent_id": "debug"]]
        XCTAssertNil(HandoffPacket.fromDictionary(malformedAgent))
    }

    func testPacketDecoderEnforcesJSONScalarAndContainerTypes() throws {
        let packet = HandoffPacket(id: "strict-json-types", resumeReady: true, goal: "Strict")
        func roundTrip(_ object: [String: Any]) -> HandoffPacket? {
            guard let data = try? JSONSupport.data(from: object),
                  let decoded = try? JSONSupport.object(from: data) else { return nil }
            return HandoffPacket.fromDictionary(decoded)
        }
        XCTAssertNotNil(roundTrip(packet.asDictionary()))

        var booleanVersion = packet.asDictionary()
        booleanVersion["schema_version"] = true
        XCTAssertNil(roundTrip(booleanVersion))

        var floatingVersion = packet.asDictionary()
        floatingVersion["schema_version"] = 1.5
        XCTAssertNil(roundTrip(floatingVersion))

        var numericReady = packet.asDictionary()
        var readyMeta = try XCTUnwrap(numericReady["meta"] as? [String: Any])
        readyMeta["resume_ready"] = 1
        numericReady["meta"] = readyMeta
        XCTAssertNil(roundTrip(numericReady))

        var numericCustom = packet.asDictionary()
        var resume = try XCTUnwrap(numericCustom["resume"] as? [String: Any])
        resume["custom"] = 1
        numericCustom["resume"] = resume
        XCTAssertNil(roundTrip(numericCustom))

        var malformedTask = packet.asDictionary()
        malformedTask["task"] = "not-an-object"
        XCTAssertNil(roundTrip(malformedTask))

        var malformedTaskField = packet.asDictionary()
        var task = try XCTUnwrap(malformedTaskField["task"] as? [String: Any])
        task["next_actions"] = [1]
        malformedTaskField["task"] = task
        XCTAssertNil(roundTrip(malformedTaskField))
    }

    func testMissingExplicitContextIDIsDistinguishedFromEmptyStore() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        _ = try app.continuity.handoff(
            arguments: ["goal": "Existing packet"],
            clientID: ClientID("existing-context")
        )

        let missing = try app.continuity.get(id: "missing-context")
        XCTAssertEqual(missing["found"] as? Bool, false)
        let message = missing["message"] as? String ?? ""
        XCTAssertTrue(message.contains("missing-context"), message)
        XCTAssertFalse(message.contains("No handoff packet yet"), message)
    }

    func testContinuityArgumentLimitsCannotOverflowAndSensitiveStateIsRedacted() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let result = try app.tools.call(
            name: "context_list",
            arguments: ["limit": 1e300],
            clientID: ClientID("large-limit")
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.payload["count"] as? Int, 0)

        let secret = "continuity-secret-\(UUID().uuidString)"
        let sanitized = ToolAuditSanitizer.sanitize([
            "narrative": secret,
            "summary": secret,
            "resume_seed": secret,
            "blockers": [secret],
            "next_actions": [secret],
            "decisions": [secret],
            "key_files": [secret],
            "cwd": secret,
            "project_slug": secret,
            "project": secret,
            "chat_label": secret,
            "chat": secret,
            "status": secret,
            "handoff_id": "safe-id",
        ])
        let encoded = try JSONSupport.string(from: sanitized)
        XCTAssertFalse(encoded.contains(secret), encoded)
        XCTAssertEqual(sanitized["handoff_id"] as? String, "safe-id")

        let auditClient = ClientID("redacted-aliases")
        let checkpoint = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "goal": secret,
                "project": secret,
                "chat": secret,
                "status": secret,
            ],
            clientID: auditClient
        )
        XCTAssertTrue(checkpoint.ok)
        let audit = try XCTUnwrap(
            app.audit.recent(limit: 20).first {
                $0.tool == "session_checkpoint" && $0.clientID == auditClient.rawValue
            }
        )
        let persistedArguments = try XCTUnwrap(audit.argsJSON)
        XCTAssertFalse(persistedArguments.contains(secret), persistedArguments)
    }

    func testHandoffFinalizesCallingClientsOpenCheckpoint() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("checkpoint-owner")

        let checkpoint = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "goal": "Preserve checkpoint state",
                "blockers": ["Waiting for evidence"],
                "next_actions": ["Resume investigation"],
                "key_files": ["Sources/Continuity.swift"],
                "decisions": ["Use stdio MCP"],
            ],
            clientID: client
        )
        let checkpointID = try XCTUnwrap(checkpoint.payload["handoff_id"] as? String)

        let handoff = try app.tools.call(
            name: "session_handoff",
            arguments: ["status": "ready_for_new_chat"],
            clientID: client
        )
        XCTAssertEqual(handoff.payload["handoff_id"] as? String, checkpointID)
        XCTAssertEqual(handoff.payload["resume_ready"] as? Bool, true)

        let packet = try XCTUnwrap(handoff.payload["packet"] as? [String: Any])
        let meta = try XCTUnwrap(packet["meta"] as? [String: Any])
        let task = try XCTUnwrap(packet["task"] as? [String: Any])
        let workingSet = try XCTUnwrap(packet["working_set"] as? [String: Any])
        XCTAssertEqual(meta["client_id"] as? String, client.rawValue)
        XCTAssertEqual(task["goal"] as? String, "Preserve checkpoint state")
        XCTAssertEqual(task["blockers"] as? [String], ["Waiting for evidence"])
        XCTAssertEqual(task["next_actions"] as? [String], ["Resume investigation"])
        XCTAssertEqual(workingSet["key_files"] as? [String], ["Sources/Continuity.swift"])
        XCTAssertEqual(workingSet["decisions"] as? [String], ["Use stdio MCP"])
    }

    func testBudgetHandoffPreservesCallingClientsCheckpointState() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("budget-owner")
        try configureAllowedProjectRoot(app)
        try bindProjectContext(app, clientID: client)
        let checkpoint = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "goal": "Keep the real task",
                "narrative": "Evidence collected before the loop",
                "blockers": ["Context pressure"],
                "next_actions": ["Continue the real task"],
                "key_files": ["Sources/RealTask.swift"],
                "decisions": ["Preserve structured state"],
            ],
            clientID: client
        )
        let checkpointID = try XCTUnwrap(checkpoint.payload["handoff_id"] as? String)
        let path = tempHome.appendingPathComponent("budget-state.txt").path
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": "value"],
            clientID: client
        )

        var budgetResult: ToolResult?
        for _ in 0..<4 {
            budgetResult = try app.tools.call(
                name: "fs_read",
                arguments: ["path": path],
                clientID: client
            )
        }
        let result = try XCTUnwrap(budgetResult)
        XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
        XCTAssertEqual(result.payload["handoff_id"] as? String, checkpointID)

        let restored = try app.continuity.get(id: checkpointID)
        let packet = try XCTUnwrap(restored["packet"] as? [String: Any])
        let task = try XCTUnwrap(packet["task"] as? [String: Any])
        let workingSet = try XCTUnwrap(packet["working_set"] as? [String: Any])
        XCTAssertEqual(task["goal"] as? String, "Keep the real task")
        XCTAssertEqual(task["blockers"] as? [String], ["Context pressure"])
        XCTAssertEqual(task["next_actions"] as? [String], ["Continue the real task"])
        XCTAssertEqual(workingSet["key_files"] as? [String], ["Sources/RealTask.swift"])
        XCTAssertEqual(workingSet["decisions"] as? [String], ["Preserve structured state"])
        XCTAssertTrue((packet["narrative"] as? String)?.contains("Evidence collected before the loop") == true)
    }

    func testBudgetHandoffReusesRichResumeReadyPacket() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("budget-ready-owner")
        let handoff = try app.tools.call(
            name: "session_handoff",
            arguments: [
                "goal": "Preserve completed handoff",
                "blockers": ["Needs another chat"],
                "next_actions": ["Resume the task"],
                "key_files": ["Sources/Ready.swift"],
                "decisions": ["Keep this packet authoritative"],
            ],
            clientID: client
        )
        let handoffID = try XCTUnwrap(handoff.payload["handoff_id"] as? String)

        let budget = try app.continuity.budgetAutoCheckpoint(
            clientID: client,
            reason: "test ready packet preservation"
        )
        XCTAssertEqual(budget.id, handoffID)
        XCTAssertEqual(budget.goal, "Preserve completed handoff")
        XCTAssertEqual(budget.blockers, ["Needs another chat"])
        XCTAssertEqual(budget.nextActions, ["Resume the task"])
        XCTAssertEqual(budget.keyFiles, ["Sources/Ready.swift"])
        XCTAssertEqual(budget.decisions, ["Keep this packet authoritative"])
    }

    func testHandoffSnapshotsOnlyCallingClientsOpenAgents() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        let firstClient = ClientID("agent-owner-a")
        let secondClient = ClientID("agent-owner-b")

        let first = try app.tools.call(
            name: "agent_run_start",
            arguments: ["agent_id": "debug", "goal": "First task", "cwd": tempHome.path],
            clientID: firstClient
        )
        let second = try app.tools.call(
            name: "agent_run_start",
            arguments: ["agent_id": "review", "goal": "Second task", "cwd": tempHome.path],
            clientID: secondClient
        )
        let firstID = try XCTUnwrap(first.payload["session_id"] as? String)
        let secondID = try XCTUnwrap(second.payload["session_id"] as? String)

        let handoff = try app.tools.call(
            name: "session_handoff",
            arguments: ["goal": "First task"],
            clientID: firstClient
        )
        let packet = try XCTUnwrap(handoff.payload["packet"] as? [String: Any])
        let agents = try XCTUnwrap(packet["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.map { $0["session_id"] as? String }, [firstID])
        XCTAssertFalse(agents.contains { $0["session_id"] as? String == secondID })
    }

    func testNewClientStatusReattachesOpenAgentSession() throws {
        let originalClient = ClientID("agent-original")
        let resumedClient = ClientID("agent-resumed")

        let sessionID: String
        do {
            let app = try ForgeApp.bootstrap(home: tempHome)
            defer { app.shutdown() }
            try configureAllowedProjectRoot(app)
            let started = try app.tools.call(
                name: "agent_run_start",
                arguments: [
                    "agent_id": "debug",
                    "goal": "Resume this specialist",
                    "cwd": tempHome.path,
                ],
                clientID: originalClient
            )
            sessionID = try XCTUnwrap(started.payload["session_id"] as? String)
        }

        let restarted = try ForgeApp.bootstrap(home: tempHome)
        defer { restarted.shutdown() }
        let status = try restarted.tools.call(
            name: "agent_run_status",
            arguments: ["session_id": sessionID],
            clientID: resumedClient
        )
        XCTAssertEqual(status.payload["reattached"] as? Bool, true)
        let binding = try XCTUnwrap(restarted.sessions.binding(for: resumedClient))
        XCTAssertEqual(binding.sessionID.rawValue, sessionID)
        XCTAssertEqual(binding.goal, "Resume this specialist")
        XCTAssertEqual(binding.cwd, tempHome.path)
        XCTAssertEqual(try restarted.store.sessionGet(id: SessionID(sessionID))?.clientID, resumedClient)

        XCTAssertNil(try restarted.sessions.rehydrate(clientID: originalClient))
        let statusAudit = try XCTUnwrap(
            restarted.audit.recent(limit: 20).first {
                $0.tool == "agent_run_status" && $0.clientID == resumedClient.rawValue
            }
        )
        XCTAssertNotNil(statusAudit.argsJSON, "agent_run_status transfers ownership and must retain sanitized audit args")
    }

    func testConcurrentAgentReattachUsesAtomicOwnershipCompareAndSwap() throws {
        let primary = try ForgeApp.bootstrap(home: tempHome)
        try configureAllowedProjectRoot(primary)
        let originalClient = ClientID("reattach-original")
        let started = try primary.tools.call(
            name: "agent_run_start",
            arguments: ["agent_id": "debug", "goal": "Atomic reattach", "cwd": tempHome.path],
            clientID: originalClient
        )
        let sessionID = SessionID(try XCTUnwrap(started.payload["session_id"] as? String))
        let fallback = try ForgeApp.bootstrap(home: tempHome)
        defer {
            primary.shutdown()
            fallback.shutdown()
        }

        let clients = [ClientID("reattach-a"), ClientID("reattach-b")]
        let stores = [primary.store, fallback.store]
        let bodies = try clients.map { client in
            try JSONSupport.string(from: [
                "session_id": sessionID.rawValue,
                "agent_id": "debug",
                "goal": "Claimed by \(client.rawValue)",
            ])
        }
        let outcomes = LockedFailureMessages()
        DispatchQueue.concurrentPerform(iterations: clients.count) { index in
            do {
                _ = try stores[index].sessionReattach(
                    id: sessionID,
                    expectedClientID: originalClient,
                    clientID: clients[index],
                    bindingBody: bodies[index],
                    agentID: "debug",
                    supersedeSummary: "superseded for atomic test"
                )
                outcomes.append("success:\(clients[index].rawValue)")
            } catch StoreError.conflict {
                outcomes.append("conflict:\(clients[index].rawValue)")
            } catch {
                outcomes.append("unexpected:\(error)")
            }
        }

        let result = outcomes.snapshot
        let winners = result.filter { $0.hasPrefix("success:") }
        XCTAssertEqual(winners.count, 1, result.joined(separator: ", "))
        XCTAssertEqual(result.filter { $0.hasPrefix("conflict:") }.count, 1, result.joined(separator: ", "))
        XCTAssertFalse(result.contains { $0.hasPrefix("unexpected:") }, result.joined(separator: ", "))
        let winner = String(try XCTUnwrap(winners.first).dropFirst("success:".count))
        XCTAssertEqual(try primary.store.sessionGet(id: sessionID)?.clientID?.rawValue, winner)
        XCTAssertNil(try primary.store.memoryGet(key: "agent_active/\(originalClient.rawValue)"))
        for client in clients {
            let note = try primary.store.memoryGet(key: "agent_active/\(client.rawValue)")
            XCTAssertEqual(note != nil, client.rawValue == winner, client.rawValue)
        }
    }

    func testContinuitySurvivesAppRestartWithDurableProjections() throws {
        let client = ClientID("restart-writer")
        let app = try ForgeApp.bootstrap(home: tempHome)
        let handoff = try app.tools.call(
            name: "session_handoff",
            arguments: [
                "goal": "Resume after restart",
                "next_actions": ["Reload durable state"],
                "narrative": "State written before process shutdown",
            ],
            clientID: client
        )
        let handoffID = try XCTUnwrap(handoff.payload["handoff_id"] as? String)
        let packetURL = app.paths.memoryHandoffsDir.appendingPathComponent("\(handoffID).json")
        let latestURL = app.paths.memoryHandoffsDir.appendingPathComponent("LATEST")
        let currentTaskURL = app.paths.memoryCurrentTask
        _ = try app.store.memoryDelete(key: "continuity/latest")
        _ = try app.store.memoryDelete(key: "continuity/resume_ready")
        app.shutdown()

        try FileManager.default.removeItem(at: packetURL)
        try FileManager.default.removeItem(at: latestURL)
        try "stale projection".write(to: currentTaskURL, atomically: true, encoding: .utf8)

        let restarted = try ForgeApp.bootstrap(home: tempHome)
        defer { restarted.shutdown() }
        let server = MCPServer(app: restarted, clientID: ClientID("restart-reader"))
        let response = server.handle([
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": [
                "name": "context_get",
                "arguments": ["handoff_id": handoffID],
            ] as [String: Any],
        ])
        let mcpResult = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertEqual(mcpResult["isError"] as? Bool, false)
        let restored = try XCTUnwrap(mcpResult["structuredContent"] as? [String: Any])

        XCTAssertEqual(restored["found"] as? Bool, true)
        XCTAssertEqual(restored["handoff_id"] as? String, handoffID)
        let packet = restored["packet"] as? [String: Any]
        let task = packet?["task"] as? [String: Any]
        XCTAssertEqual(task?["goal"] as? String, "Resume after restart")

        XCTAssertTrue(FileManager.default.fileExists(atPath: packetURL.path))
        let projectedPacket = try XCTUnwrap(
            JSONSupport.object(from: Data(contentsOf: packetURL))["meta"] as? [String: Any]
        )
        XCTAssertEqual(projectedPacket["id"] as? String, handoffID)
        let latestID = try String(
            contentsOf: latestURL,
            encoding: .utf8
        )
        XCTAssertEqual(latestID, handoffID)
        let currentTask = try String(contentsOf: currentTaskURL, encoding: .utf8)
        XCTAssertTrue(currentTask.contains("Resume after restart"), currentTask)
        XCTAssertEqual(try restarted.store.memoryGet(key: "continuity/latest"), handoffID)
        XCTAssertEqual(try restarted.store.memoryGet(key: "continuity/resume_ready"), handoffID)

        let continued = try restarted.tools.call(
            name: "session_checkpoint",
            arguments: [
                "handoff_id": handoffID,
                "goal": "Continued after restart",
            ],
            clientID: ClientID("restart-reader")
        )
        XCTAssertEqual(continued.payload["handoff_id"] as? String, handoffID)
        XCTAssertEqual(try restarted.store.handoffGet(id: handoffID)?.goal, "Continued after restart")
    }

    func testNewChatRecoversGoalAndAgentThenReattachesOverMCP() throws {
        let originalClient = ClientID("combined-original")
        let handoffID: String
        let sessionID: String
        do {
            let app = try ForgeApp.bootstrap(home: tempHome)
            defer { app.shutdown() }
            try configureAllowedProjectRoot(app)
            let started = try app.tools.call(
                name: "agent_run_start",
                arguments: [
                    "agent_id": "debug",
                    "goal": "Inspect combined continuity",
                    "cwd": tempHome.path,
                ],
                clientID: originalClient
            )
            sessionID = try XCTUnwrap(started.payload["session_id"] as? String)
            let handoff = try app.tools.call(
                name: "session_handoff",
                arguments: ["goal": "Recover the combined task"],
                clientID: originalClient
            )
            handoffID = try XCTUnwrap(handoff.payload["handoff_id"] as? String)
        }

        let restarted = try ForgeApp.bootstrap(home: tempHome)
        defer { restarted.shutdown() }
        let resumedClient = ClientID("combined-new-chat")
        let server = MCPServer(app: restarted, clientID: resumedClient)
        let contextResponse = server.handle([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "context_get",
                "arguments": ["handoff_id": handoffID],
            ] as [String: Any],
        ])
        let contextResult = try XCTUnwrap(contextResponse?["result"] as? [String: Any])
        let context = try XCTUnwrap(contextResult["structuredContent"] as? [String: Any])
        let packet = try XCTUnwrap(context["packet"] as? [String: Any])
        let task = try XCTUnwrap(packet["task"] as? [String: Any])
        let agents = try XCTUnwrap(packet["agents"] as? [[String: Any]])
        XCTAssertEqual(task["goal"] as? String, "Recover the combined task")
        XCTAssertEqual(agents.map { $0["session_id"] as? String }, [sessionID])

        let statusResponse = server.handle([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": "agent_run_status",
                "arguments": ["session_id": sessionID],
            ] as [String: Any],
        ])
        let statusResult = try XCTUnwrap(statusResponse?["result"] as? [String: Any])
        let status = try XCTUnwrap(statusResult["structuredContent"] as? [String: Any])
        XCTAssertEqual(status["reattached"] as? Bool, true)
        XCTAssertEqual(try restarted.store.sessionGet(id: SessionID(sessionID))?.clientID, resumedClient)
    }

    func testStartupRepairsEveryMissingPacketProjection() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        let older = try app.continuity.handoff(
            arguments: ["goal": "Older projection"],
            clientID: ClientID("older-projection")
        )
        let newer = try app.continuity.handoff(
            arguments: ["goal": "Newer projection"],
            clientID: ClientID("newer-projection")
        )
        let olderID = try XCTUnwrap(older["handoff_id"] as? String)
        let newerID = try XCTUnwrap(newer["handoff_id"] as? String)
        let olderURL = app.paths.memoryHandoffsDir.appendingPathComponent("\(olderID).json")
        let latestURL = app.paths.memoryHandoffsDir.appendingPathComponent("LATEST")
        app.shutdown()
        try FileManager.default.removeItem(at: olderURL)

        let restarted = try ForgeApp.bootstrap(home: tempHome)
        defer { restarted.shutdown() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: olderURL.path))
        let olderProjection = try JSONSupport.object(from: Data(contentsOf: olderURL))
        let olderTask = try XCTUnwrap(olderProjection["task"] as? [String: Any])
        XCTAssertEqual(olderTask["goal"] as? String, "Older projection")
        XCTAssertEqual(try String(contentsOf: latestURL, encoding: .utf8), newerID)
    }

    func testProjectionFailureKeepsAuthoritativeWriteAndRepairsOnRestart() throws {
        let client = ClientID("projection-failure")
        let app = try ForgeApp.bootstrap(home: tempHome)
        let initial = try app.continuity.checkpoint(
            arguments: ["goal": "Before projection failure"],
            clientID: client
        )
        let handoffID = try XCTUnwrap(initial["handoff_id"] as? String)
        let packetURL = app.paths.memoryHandoffsDir.appendingPathComponent("\(handoffID).json")
        try FileManager.default.removeItem(at: packetURL)
        try FileManager.default.createDirectory(at: packetURL, withIntermediateDirectories: false)

        let updated = try app.continuity.checkpoint(
            arguments: [
                "handoff_id": handoffID,
                "goal": "Durable despite projection failure",
            ],
            clientID: client
        )
        XCTAssertEqual(updated["ok"] as? Bool, true)
        XCTAssertEqual(updated["projection_ok"] as? Bool, false)
        XCTAssertEqual(updated["projection_repair_pending"] as? Bool, true)
        XCTAssertEqual(try app.store.handoffGet(id: handoffID)?.goal, "Durable despite projection failure")
        app.shutdown()

        try FileManager.default.removeItem(at: packetURL)
        let restarted = try ForgeApp.bootstrap(home: tempHome)
        defer { restarted.shutdown() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: packetURL.path))
        XCTAssertEqual(try restarted.store.handoffGet(id: handoffID)?.goal, "Durable despite projection failure")
        let projection = try JSONSupport.object(from: Data(contentsOf: packetURL))
        let task = try XCTUnwrap(projection["task"] as? [String: Any])
        XCTAssertEqual(task["goal"] as? String, "Durable despite projection failure")
    }

    func testPointerWriteFailureRollsBackHandoffRow() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try withSQLiteFixture(at: app.paths.storeSQLite) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TRIGGER fail_continuity_latest
                BEFORE INSERT ON memory_notes
                WHEN NEW.key = 'continuity/latest'
                BEGIN
                    SELECT RAISE(ABORT, 'forced continuity pointer failure');
                END;
                """
            )
        }

        XCTAssertThrowsError(
            try app.continuity.handoff(
                arguments: ["goal": "Must roll back"],
                clientID: ClientID("pointer-rollback")
            )
        )
        XCTAssertEqual(try app.store.handoffList(limit: 10), [])
        XCTAssertNil(try app.store.memoryGet(key: "continuity/latest"))

        try withSQLiteFixture(at: app.paths.storeSQLite) { database in
            try executeSQLiteFixture(database, sql: "DROP TRIGGER fail_continuity_latest;")
        }
        let recovered = try app.continuity.handoff(
            arguments: ["goal": "Writes after rollback"],
            clientID: ClientID("pointer-rollback")
        )
        XCTAssertEqual(recovered["ok"] as? Bool, true)
        XCTAssertEqual(try app.store.handoffList(limit: 10).count, 1)
    }

    func testSQLiteStorePreCommitGuardRejectsAtomicPathReplacementAndRollsBackMigration() throws {
        let databaseURL = tempHome.appendingPathComponent("store.sqlite")
        let replacementURL = tempHome.appendingPathComponent("store-replacement.sqlite")
        let backupURL = tempHome.appendingPathComponent("store.pre-migration-v2.sqlite3")
        for (url, payload) in [
            (databaseURL, "original migration payload"),
            (replacementURL, "replacement payload"),
        ] {
            try withSQLiteFixture(at: url) { database in
                try executeSQLiteFixture(
                    database,
                    sql: """
                    PRAGMA journal_mode=DELETE;
                    CREATE TABLE schema_version(version INTEGER NOT NULL);
                    INSERT INTO schema_version(version) VALUES(2);
                    CREATE TABLE legacy_payload(value TEXT NOT NULL);
                    INSERT INTO legacy_payload(value) VALUES('\(payload)');
                    """
                )
            }
        }

        var initializationError: Error?
        do {
            _ = try SQLiteStore(
                path: databaseURL,
                beforeMigrationCommitObserver: {
                    try exchangeSQLiteFixturePaths(databaseURL, replacementURL)
                },
                postMigrationCommitObserver: nil
            )
            XCTFail("atomic pathname replacement must prevent migration commit")
        } catch {
            initializationError = error
        }
        XCTAssertTrue(
            initializationError?.localizedDescription.contains(
                "SQLite store migration commit"
            ) == true,
            initializationError?.localizedDescription ?? "missing initialization error"
        )
        XCTAssertTrue(
            initializationError?.localizedDescription.contains("moved or was replaced") == true,
            initializationError?.localizedDescription ?? "missing initialization error"
        )

        try exchangeSQLiteFixturePaths(databaseURL, replacementURL)
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: databaseURL,
                sql: "SELECT version FROM schema_version LIMIT 1;"
            ),
            2
        )
        XCTAssertEqual(
            try sqliteFixtureText(
                at: databaseURL,
                sql: "SELECT value FROM legacy_payload LIMIT 1;"
            ),
            "original migration payload"
        )
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: replacementURL,
                sql: "SELECT version FROM schema_version LIMIT 1;"
            ),
            2
        )
        XCTAssertEqual(
            try sqliteFixtureText(
                at: replacementURL,
                sql: "SELECT value FROM legacy_payload LIMIT 1;"
            ),
            "replacement payload"
        )
        for url in [databaseURL, replacementURL] {
            XCTAssertEqual(
                try sqliteFixtureInt(
                    at: url,
                    sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type='table' AND name='context_handoffs';
                    """
                ),
                0
            )
            XCTAssertEqual(
                try sqliteFixtureInt(
                    at: url,
                    sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type='table' AND name='forge_migration_receipts';
                    """
                ),
                0
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: backupURL,
                sql: "SELECT version FROM schema_version LIMIT 1;"
            ),
            2
        )
        XCTAssertEqual(
            try sqliteFixtureText(
                at: backupURL,
                sql: "SELECT value FROM legacy_payload LIMIT 1;"
            ),
            "original migration payload"
        )
        XCTAssertEqual(try sqliteFixtureText(at: backupURL, sql: "PRAGMA quick_check;"), "ok")

        let activeManifestURL = VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
        let prepared = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(contentsOf: activeManifestURL)
        )
        XCTAssertEqual(prepared.state, .prepared)
        XCTAssertEqual(prepared.storageKind, .sqlite)
        XCTAssertEqual(prepared.sourceVersion, 2)
        XCTAssertEqual(prepared.targetVersion, SQLiteStore.schemaVersion)
        XCTAssertEqual(prepared.backupFilename, backupURL.lastPathComponent)
        XCTAssertEqual(
            prepared.backupSHA256,
            JSONSupport.sha256Hex(try Data(contentsOf: backupURL))
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: VerifiedMigrationBackup.archivedManifestURL(
                    for: backupURL,
                    targetVersion: SQLiteStore.schemaVersion
                ).path
            )
        )
    }

    func testVersionTwoStoreMigratesPopulatedDataReopensAndRerunsIdempotently() throws {
        let databaseURL = tempHome.appendingPathComponent("store.sqlite")
        let timestamp = "2026-01-02T03:04:05Z"
        let legacySessionID = "legacy-v2-session"
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version (version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES (2);
                CREATE TABLE memory_notes (
                    key TEXT PRIMARY KEY,
                    body TEXT NOT NULL,
                    tags_json TEXT NOT NULL DEFAULT '[]',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE agent_sessions (
                    id TEXT PRIMARY KEY,
                    agent_id TEXT NOT NULL,
                    client_id TEXT,
                    status TEXT NOT NULL,
                    summary TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE presence (
                    client_id TEXT PRIMARY KEY,
                    host_kind TEXT,
                    pid INTEGER,
                    cwd TEXT,
                    last_heartbeat TEXT NOT NULL
                );
                CREATE TABLE audit_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp TEXT NOT NULL,
                    client_id TEXT,
                    tool TEXT NOT NULL,
                    args_digest TEXT,
                    args_json TEXT,
                    status TEXT,
                    duration_ms INTEGER,
                    error TEXT
                );
                INSERT INTO memory_notes(key,body,tags_json,created_at,updated_at)
                  VALUES('legacy/key','preserved v2 body','["legacy","migration"]','\(timestamp)','\(timestamp)');
                INSERT INTO agent_sessions(id,agent_id,client_id,status,summary,created_at,updated_at)
                  VALUES('\(legacySessionID)','implement','legacy-v2-client','closed','preserved v2 summary','\(timestamp)','\(timestamp)');
                INSERT INTO presence(client_id,host_kind,pid,cwd,last_heartbeat)
                  VALUES('legacy-v2-client','mcp',4242,'/legacy/project','\(timestamp)');
                INSERT INTO audit_events(timestamp,client_id,tool,args_digest,args_json,status,duration_ms,error)
                  VALUES('\(timestamp)','legacy-v2-client','memory_get','legacy-digest','{}','ok',17,NULL);
                """
            )
        }

        func assertLegacySemantics(in store: SQLiteStore) throws {
            let note = try XCTUnwrap(store.memoryGetNote(key: "legacy/key"))
            XCTAssertEqual(note.body, "preserved v2 body")
            XCTAssertEqual(note.tags, ["legacy", "migration"])
            XCTAssertEqual(note.createdAt, timestamp)
            XCTAssertEqual(note.updatedAt, timestamp)

            let session = try XCTUnwrap(store.sessionGet(id: SessionID(legacySessionID)))
            XCTAssertEqual(session.agentID, "implement")
            XCTAssertEqual(session.clientID, ClientID("legacy-v2-client"))
            XCTAssertEqual(session.status, .closed)
            XCTAssertEqual(session.summary, "preserved v2 summary")

            let presence = try XCTUnwrap(store.presenceRecords().first)
            XCTAssertEqual(presence.clientID, "legacy-v2-client")
            XCTAssertEqual(presence.hostKind, "mcp")
            XCTAssertEqual(presence.pid, 4242)
            XCTAssertEqual(presence.cwd, "/legacy/project")
            XCTAssertEqual(presence.lastHeartbeat, timestamp)

            let audit = try XCTUnwrap(store.auditRecent(limit: 10).first)
            XCTAssertEqual(audit.clientID, "legacy-v2-client")
            XCTAssertEqual(audit.tool, "memory_get")
            XCTAssertEqual(audit.argsDigest, "legacy-digest")
            XCTAssertEqual(audit.argsJSON, "{}")
            XCTAssertEqual(audit.status, "ok")
            XCTAssertEqual(audit.durationMs, 17)
            XCTAssertNil(audit.error)
        }

        let first = try SQLiteStore(path: databaseURL)
        try assertLegacySemantics(in: first)
        XCTAssertEqual(
            try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"),
            SQLiteStore.schemaVersion
        )
        let backupURL = tempHome.appendingPathComponent("store.pre-migration-v2.sqlite3")
        XCTAssertEqual(try sqliteFixtureInt(at: backupURL, sql: "SELECT version FROM schema_version;"), 2)
        XCTAssertEqual(try sqliteFixtureText(at: backupURL, sql: "PRAGMA quick_check;"), "ok")
        XCTAssertEqual(
            try sqliteFixtureText(
                at: backupURL,
                sql: "SELECT body FROM memory_notes WHERE key='legacy/key';"
            ),
            "preserved v2 body"
        )
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o600
        )
        let migrationManifest = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(
                contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
            )
        )
        XCTAssertEqual(migrationManifest.state, .completed)
        XCTAssertEqual(migrationManifest.storageKind, .sqlite)
        XCTAssertEqual(migrationManifest.sourceVersion, 2)
        XCTAssertEqual(migrationManifest.targetVersion, SQLiteStore.schemaVersion)
        XCTAssertEqual(migrationManifest.backupSHA256, JSONSupport.sha256Hex(try Data(contentsOf: backupURL)))
        XCTAssertNotNil(migrationManifest.targetSHA256)
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM forge_migration_receipts WHERE migration_id='\(migrationManifest.migrationID)';"
            ),
            1
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: VerifiedMigrationBackup.archivedManifestURL(
                    for: backupURL,
                    targetVersion: SQLiteStore.schemaVersion
                ).path
            )
        )
        let firstBackupData = try Data(contentsOf: backupURL)

        let migratedPacket = HandoffPacket(
            id: "v2-migration-current-handoff",
            createdAt: timestamp,
            updatedAt: timestamp,
            goal: "Verify current writes after v2 migration"
        )
        try first.handoffUpsert(migratedPacket)
        try first.migrate()
        try assertLegacySemantics(in: first)
        let firstHandoff = try XCTUnwrap(first.handoffGet(id: migratedPacket.id))
        XCTAssertEqual(firstHandoff.id, migratedPacket.id)
        XCTAssertEqual(firstHandoff.goal, migratedPacket.goal)
        XCTAssertEqual(firstHandoff.createdAt, migratedPacket.createdAt)
        first.close()

        let reopened = try SQLiteStore(path: databaseURL)
        try assertLegacySemantics(in: reopened)
        let reopenedHandoff = try XCTUnwrap(reopened.handoffGet(id: migratedPacket.id))
        XCTAssertEqual(reopenedHandoff.id, migratedPacket.id)
        XCTAssertEqual(reopenedHandoff.goal, migratedPacket.goal)
        XCTAssertEqual(reopenedHandoff.createdAt, migratedPacket.createdAt)
        XCTAssertEqual(try reopened.memoryList(limit: 10).map(\.key), ["legacy/key"])
        XCTAssertEqual(try reopened.sessionList().map(\.id.rawValue), [legacySessionID])
        XCTAssertEqual(try reopened.presenceRecords().count, 1)
        XCTAssertEqual(try reopened.auditRecent(limit: 10).count, 1)
        try reopened.migrate()
        try assertLegacySemantics(in: reopened)
        XCTAssertEqual(
            try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"),
            SQLiteStore.schemaVersion
        )
        XCTAssertEqual(try Data(contentsOf: backupURL), firstBackupData)
        reopened.close()

        try firstBackupData.write(to: databaseURL, options: .atomic)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
        let restored = try SQLiteStore(path: databaseURL)
        try assertLegacySemantics(in: restored)
        XCTAssertNil(try restored.handoffGet(id: migratedPacket.id))
        restored.close()
        XCTAssertEqual(
            try JSONDecoder().decode(
                VerifiedMigrationBackupManifest.self,
                from: Data(
                    contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
                )
            ),
            migrationManifest
        )
    }

    func testRestoredChangedSQLiteSourceCreatesBoundedSecondMigrationLineage() throws {
        let databaseURL = tempHome.appendingPathComponent("store.sqlite")
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version(version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES(2);
                CREATE TABLE legacy_payload(id INTEGER PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO legacy_payload(id,value) VALUES(1,'first lineage');
                """
            )
        }

        let first = try SQLiteStore(path: databaseURL)
        first.close()
        let preferredBackupURL = tempHome.appendingPathComponent(
            "store.pre-migration-v2.sqlite3"
        )
        let preferredBackup = try Data(contentsOf: preferredBackupURL)
        let firstManifest = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(
                contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
            )
        )

        try preferredBackup.write(to: databaseURL, options: .atomic)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: "INSERT INTO legacy_payload(id,value) VALUES(2,'second lineage');"
            )
        }

        let second = try SQLiteStore(path: databaseURL)
        second.close()
        let secondBackupURL = tempHome.appendingPathComponent(
            "store.pre-migration-v2.lineage-2.sqlite3"
        )
        XCTAssertEqual(try Data(contentsOf: preferredBackupURL), preferredBackup)
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: secondBackupURL,
                sql: "SELECT COUNT(*) FROM legacy_payload;"
            ),
            2
        )
        let secondManifest = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(
                contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
            )
        )
        XCTAssertEqual(secondManifest.state, .completed)
        XCTAssertEqual(secondManifest.backupFilename, secondBackupURL.lastPathComponent)
        XCTAssertNotEqual(secondManifest.migrationID, firstManifest.migrationID)
        XCTAssertNotEqual(secondManifest.sourceSHA256, firstManifest.sourceSHA256)
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM forge_migration_receipts WHERE migration_id='\(secondManifest.migrationID)';"
            ),
            1
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: VerifiedMigrationBackup.archivedManifestURL(
                    for: secondBackupURL,
                    targetVersion: SQLiteStore.schemaVersion
                ).path
            )
        )
    }

    func testSQLiteMigrationPromotesArchivedCompletionAfterPreparedManifestCrash() throws {
        let databaseURL = tempHome.appendingPathComponent("store.sqlite")
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version(version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES(2);
                CREATE TABLE legacy_payload(id INTEGER PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO legacy_payload(id,value) VALUES(1,'before migration');
                """
            )
        }
        let migrated = try SQLiteStore(path: databaseURL)
        migrated.close()
        let activeURL = VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
        let completed = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(contentsOf: activeURL)
        )
        XCTAssertEqual(completed.state, .completed)
        let backupURL = tempHome.appendingPathComponent("store.pre-migration-v2.sqlite3")
        let archiveURL = VerifiedMigrationBackup.archivedManifestURL(
            for: backupURL,
            targetVersion: SQLiteStore.schemaVersion
        )
        let archivedBytes = try Data(contentsOf: archiveURL)

        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE post_migration_activity(value TEXT NOT NULL);
                INSERT INTO post_migration_activity(value) VALUES('written after commit');
                """
            )
        }
        var preparedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(completed))
                as? [String: Any]
        )
        preparedObject["state"] = VerifiedMigrationManifestState.prepared.rawValue
        preparedObject.removeValue(forKey: "target_sha256")
        preparedObject.removeValue(forKey: "target_bytes")
        preparedObject.removeValue(forKey: "completed_at")
        let preparedData = try JSONSerialization.data(
            withJSONObject: preparedObject,
            options: [.sortedKeys]
        )
        try FileManager.default.removeItem(at: activeURL)
        _ = try VerifiedMigrationBackup.writeFile(
            preparedData,
            to: activeURL,
            maximumBytes: 64 * 1_024
        )

        let recovered = try SQLiteStore(path: databaseURL)
        recovered.close()
        XCTAssertEqual(
            try sqliteFixtureText(
                at: databaseURL,
                sql: "SELECT value FROM post_migration_activity LIMIT 1;"
            ),
            "written after commit"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                VerifiedMigrationBackupManifest.self,
                from: Data(contentsOf: activeURL)
            ),
            completed
        )
        XCTAssertEqual(try Data(contentsOf: archiveURL), archivedBytes)
    }

    func testVersionThreeStoreMigratesWithoutLosingHandoff() throws {
        let databaseURL = tempHome.appendingPathComponent("store.sqlite")
        let legacyPacket = HandoffPacket(
            id: "legacy-v3-handoff",
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
            source: .model,
            resumeReady: true,
            goal: "Recover legacy continuity state",
            nextActions: ["Migrate in place"]
        )
        let legacyJSON = try JSONSupport.string(from: legacyPacket.asDictionary())

        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version (version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES (3);
                CREATE TABLE context_handoffs (
                    id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    source TEXT NOT NULL,
                    resume_ready INTEGER NOT NULL DEFAULT 0,
                    packet_json TEXT NOT NULL
                );
                """
            )

            var statement: OpaquePointer?
            let sql = """
                INSERT INTO context_handoffs(
                    id, created_at, updated_at, source, resume_ready, packet_json
                ) VALUES (?, ?, ?, ?, ?, ?)
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SQLiteFixtureError.failure(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            bindSQLiteFixture(statement, index: 1, value: legacyPacket.id)
            bindSQLiteFixture(statement, index: 2, value: legacyPacket.createdAt)
            bindSQLiteFixture(statement, index: 3, value: legacyPacket.updatedAt)
            bindSQLiteFixture(statement, index: 4, value: legacyPacket.source.rawValue)
            sqlite3_bind_int(statement, 5, 1)
            bindSQLiteFixture(statement, index: 6, value: legacyJSON)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteFixtureError.failure(String(cString: sqlite3_errmsg(database)))
            }
        }

        var app: ForgeApp? = try ForgeApp.bootstrap(home: tempHome)
        defer { app?.shutdown() }
        let activeApp = try XCTUnwrap(app)
        let backupURL = tempHome.appendingPathComponent("store.pre-migration-v3.sqlite3")
        XCTAssertEqual(try sqliteFixtureInt(at: backupURL, sql: "SELECT version FROM schema_version;"), 3)
        XCTAssertEqual(try sqliteFixtureText(at: backupURL, sql: "PRAGMA quick_check;"), "ok")
        XCTAssertEqual(
            try sqliteFixtureText(
                at: backupURL,
                sql: "SELECT packet_json FROM context_handoffs WHERE id='\(legacyPacket.id)';"
            ),
            legacyJSON
        )
        let firstBackupData = try Data(contentsOf: backupURL)
        let restored = try activeApp.continuity.get(id: legacyPacket.id)
        XCTAssertEqual(restored["found"] as? Bool, true)
        let restoredPacket = try XCTUnwrap(restored["packet"] as? [String: Any])
        let restoredTask = try XCTUnwrap(restoredPacket["task"] as? [String: Any])
        XCTAssertEqual(restoredTask["goal"] as? String, "Recover legacy continuity state")

        let current = try activeApp.tools.call(
            name: "session_handoff",
            arguments: ["goal": "State written after migration"],
            clientID: ClientID("migration-writer")
        )
        let currentID = try XCTUnwrap(current.payload["handoff_id"] as? String)
        XCTAssertEqual(try activeApp.store.handoffLatest()?.id, currentID)
        XCTAssertEqual(try activeApp.store.handoffList(limit: 10).map(\.id), [currentID, legacyPacket.id])
        activeApp.shutdown()
        app = nil

        let reopened = try ForgeApp.bootstrap(home: tempHome)
        defer { reopened.shutdown() }
        XCTAssertEqual(try reopened.store.handoffList(limit: 10).map(\.id), [currentID, legacyPacket.id])
        XCTAssertEqual(try reopened.store.handoffGet(id: legacyPacket.id)?.goal, legacyPacket.goal)
        XCTAssertEqual(try reopened.store.handoffGet(id: currentID)?.goal, "State written after migration")
        try reopened.store.migrate()
        XCTAssertEqual(try reopened.store.handoffList(limit: 10).map(\.id), [currentID, legacyPacket.id])
        XCTAssertEqual(
            try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"),
            SQLiteStore.schemaVersion
        )
        XCTAssertEqual(try Data(contentsOf: backupURL), firstBackupData)
    }

    func testConcurrentVersionThreeMigrationIsIdempotent() throws {
        let databaseURL = tempHome.appendingPathComponent("store.sqlite")
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version (version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES (3);
                CREATE TABLE context_handoffs (
                    id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    source TEXT NOT NULL,
                    resume_ready INTEGER NOT NULL DEFAULT 0,
                    packet_json TEXT NOT NULL
                );
                """
            )
        }

        let failures = LockedFailureMessages()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                let store = try SQLiteStore(path: databaseURL)
                store.close()
            } catch {
                failures.append("migration \(index): \(error)")
            }
        }
        XCTAssertEqual(failures.snapshot, [])
        let backupURL = tempHome.appendingPathComponent("store.pre-migration-v3.sqlite3")
        XCTAssertEqual(try sqliteFixtureInt(at: backupURL, sql: "SELECT version FROM schema_version;"), 3)
        XCTAssertEqual(try sqliteFixtureText(at: backupURL, sql: "PRAGMA quick_check;"), "ok")
        let firstBackupData = try Data(contentsOf: backupURL)

        let store = try SQLiteStore(path: databaseURL)
        let packet = HandoffPacket(id: "post-concurrent-migration", goal: "Migration complete")
        try store.handoffUpsert(packet)
        XCTAssertEqual(try store.handoffLatest()?.id, packet.id)
        XCTAssertEqual(try store.memoryGet(key: "continuity/latest"), packet.id)
        store.close()

        let reopened = try SQLiteStore(path: databaseURL)
        defer { reopened.close() }
        try reopened.migrate()
        XCTAssertEqual(try reopened.handoffLatest()?.id, packet.id)
        XCTAssertEqual(try reopened.memoryGet(key: "continuity/latest"), packet.id)
        XCTAssertEqual(try reopened.handoffList(limit: 10).map(\.id), [packet.id])
        XCTAssertEqual(
            try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"),
            SQLiteStore.schemaVersion
        )
        XCTAssertEqual(try Data(contentsOf: backupURL), firstBackupData)
    }

    func testSQLitePreparedMigrationRecoversAfterSIGKILLAndReleasesInterprocessLock() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["FORGE_MIGRATION_TEST_ROLE"] == "prepared-v3-lock-holder" {
            guard let databasePath = environment["FORGE_MIGRATION_TEST_DATABASE"],
                  let readyPath = environment["FORGE_MIGRATION_TEST_READY"] else {
                throw SQLiteFixtureError.failure("migration child paths are missing")
            }
            try runPreparedSQLiteMigrationChild(
                databaseURL: URL(fileURLWithPath: databasePath),
                readyURL: URL(fileURLWithPath: readyPath)
            )
            return
        }

        let databaseURL = tempHome.appendingPathComponent("store.sqlite")
        let backupURL = tempHome.appendingPathComponent("store.pre-migration-v3.sqlite3")
        let readyURL = tempHome.appendingPathComponent("migration-child-ready")
        let legacyPacket = HandoffPacket(
            id: "sigkill-v3-handoff",
            createdAt: "2026-08-27T00:00:00Z",
            updatedAt: "2026-08-27T00:00:00Z",
            source: .model,
            resumeReady: true,
            goal: "Recover a prepared migration after process death",
            nextActions: ["Resume the exact migration"]
        )
        let legacyJSON = try JSONSupport.string(from: legacyPacket.asDictionary())
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version (version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES (3);
                CREATE TABLE context_handoffs (
                    id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    source TEXT NOT NULL,
                    resume_ready INTEGER NOT NULL DEFAULT 0,
                    packet_json TEXT NOT NULL
                );
                INSERT INTO context_handoffs(
                    id,created_at,updated_at,source,resume_ready,packet_json
                ) VALUES(
                    '\(legacyPacket.id)','\(legacyPacket.createdAt)','\(legacyPacket.updatedAt)',
                    '\(legacyPacket.source.rawValue)',1,'\(legacyJSON)'
                );
                """
            )
        }

        let reflectedName = NSStringFromClass(type(of: self))
        let methodName = String(#function.prefix { $0 != "(" })
        let child = try launchMigrationXCTestFixture(
            testIdentifier: "\(reflectedName)/\(methodName)",
            environment: [
                "FORGE_MIGRATION_TEST_ROLE": "prepared-v3-lock-holder",
                "FORGE_MIGRATION_TEST_DATABASE": databaseURL.path,
                "FORGE_MIGRATION_TEST_READY": readyURL.path,
            ]
        )
        defer { child.close() }
        try waitForMigrationMarker(readyURL, child: child, timeout: 5)

        let prepared = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(
                contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
            )
        )
        XCTAssertEqual(prepared.state, .prepared)
        XCTAssertEqual(prepared.storageKind, .sqlite)
        XCTAssertEqual(prepared.sourceVersion, 3)
        XCTAssertEqual(prepared.targetVersion, SQLiteStore.schemaVersion)
        XCTAssertEqual(prepared.backupFilename, backupURL.lastPathComponent)
        XCTAssertEqual(
            prepared.backupSHA256,
            JSONSupport.sha256Hex(try Data(contentsOf: backupURL))
        )
        XCTAssertEqual(try sqliteFixtureInt(at: backupURL, sql: "SELECT version FROM schema_version;"), 3)
        XCTAssertEqual(
            try sqliteFixtureText(
                at: backupURL,
                sql: "SELECT packet_json FROM context_handoffs WHERE id='\(legacyPacket.id)';"
            ),
            legacyJSON
        )
        let backupData = try Data(contentsOf: backupURL)

        XCTAssertThrowsError(
            try VerifiedMigrationBackup.withMigrationLock(
                databaseURL: databaseURL,
                timeoutSeconds: 0.05
            ) {
                XCTFail("a second process entered the migration critical section")
            }
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("interprocess migration lock"),
                "\(error)"
            )
        }

        let termination = try forceKillMigrationXCTestFixture(child, timeout: 5)
        XCTAssertEqual(termination.reason, .uncaughtSignal)
        XCTAssertEqual(termination.status, SIGKILL)
        XCTAssertEqual(
            try VerifiedMigrationBackup.withMigrationLock(
                databaseURL: databaseURL,
                timeoutSeconds: 1
            ) { 42 },
            42
        )

        let recovered = try SQLiteStore(path: databaseURL)
        let recoveredPacket = try XCTUnwrap(recovered.handoffGet(id: legacyPacket.id))
        XCTAssertEqual(recoveredPacket.goal, legacyPacket.goal)
        XCTAssertEqual(recoveredPacket.nextActions, legacyPacket.nextActions)
        recovered.close()

        XCTAssertEqual(
            try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"),
            SQLiteStore.schemaVersion
        )
        XCTAssertEqual(try Data(contentsOf: backupURL), backupData)
        let completed = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(
                contentsOf: VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
            )
        )
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.migrationID, prepared.migrationID)
        XCTAssertEqual(completed.preparedAt, prepared.preparedAt)
        XCTAssertNotNil(completed.targetSHA256)
        XCTAssertNotNil(completed.completedAt)
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM forge_migration_receipts WHERE migration_id='\(completed.migrationID)';"
            ),
            1
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                VerifiedMigrationBackupManifest.self,
                from: Data(
                    contentsOf: VerifiedMigrationBackup.archivedManifestURL(
                        for: backupURL,
                        targetVersion: SQLiteStore.schemaVersion
                    )
                )
            ),
            completed
        )
    }

    func testSQLiteCommittedMigrationRecoversAfterSIGKILLBeforeManifestCompletion() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["FORGE_MIGRATION_TEST_ROLE"] == "committed-v3-lock-holder" {
            guard let databasePath = environment["FORGE_MIGRATION_TEST_DATABASE"],
                  let readyPath = environment["FORGE_MIGRATION_TEST_READY"] else {
                throw SQLiteFixtureError.failure("migration child paths are missing")
            }
            try runCommittedSQLiteMigrationChild(
                databaseURL: URL(fileURLWithPath: databasePath),
                readyURL: URL(fileURLWithPath: readyPath)
            )
            return
        }

        let databaseURL = tempHome.appendingPathComponent("store.sqlite")
        let backupURL = tempHome.appendingPathComponent("store.pre-migration-v3.sqlite3")
        let secondBackupURL = tempHome.appendingPathComponent(
            "store.pre-migration-v3.lineage-2.sqlite3"
        )
        let readyURL = tempHome.appendingPathComponent("migration-commit-ready")
        let archiveURL = VerifiedMigrationBackup.archivedManifestURL(
            for: backupURL,
            targetVersion: SQLiteStore.schemaVersion
        )
        let activeManifestURL = VerifiedMigrationBackup.activeManifestURL(for: databaseURL)
        let legacyPacket = HandoffPacket(
            id: "sigkill-committed-v3-handoff",
            createdAt: "2026-08-27T00:00:00Z",
            updatedAt: "2026-08-27T00:00:00Z",
            source: .model,
            resumeReady: true,
            goal: "Recover a committed migration after process death",
            nextActions: ["Complete the exact migration manifest"]
        )
        let legacyJSON = try JSONSupport.string(from: legacyPacket.asDictionary())
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version (version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES (3);
                CREATE TABLE context_handoffs (
                    id TEXT PRIMARY KEY,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    source TEXT NOT NULL,
                    resume_ready INTEGER NOT NULL DEFAULT 0,
                    packet_json TEXT NOT NULL
                );
                INSERT INTO context_handoffs(
                    id,created_at,updated_at,source,resume_ready,packet_json
                ) VALUES(
                    '\(legacyPacket.id)','\(legacyPacket.createdAt)','\(legacyPacket.updatedAt)',
                    '\(legacyPacket.source.rawValue)',1,'\(legacyJSON)'
                );
                """
            )
        }

        let reflectedName = NSStringFromClass(type(of: self))
        let methodName = String(#function.prefix { $0 != "(" })
        let child = try launchMigrationXCTestFixture(
            testIdentifier: "\(reflectedName)/\(methodName)",
            environment: [
                "FORGE_MIGRATION_TEST_ROLE": "committed-v3-lock-holder",
                "FORGE_MIGRATION_TEST_DATABASE": databaseURL.path,
                "FORGE_MIGRATION_TEST_READY": readyURL.path,
            ]
        )
        defer { child.close() }
        try waitForMigrationMarker(readyURL, child: child, timeout: 5)
        XCTAssertTrue(child.process.isRunning)

        let prepared = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(contentsOf: activeManifestURL)
        )
        XCTAssertEqual(
            String(data: try Data(contentsOf: readyURL), encoding: .utf8),
            prepared.migrationID
        )
        XCTAssertEqual(prepared.state, .prepared)
        XCTAssertEqual(prepared.storageKind, .sqlite)
        XCTAssertEqual(prepared.sourceVersion, 3)
        XCTAssertEqual(prepared.targetVersion, SQLiteStore.schemaVersion)
        XCTAssertEqual(prepared.sourceFilename, databaseURL.lastPathComponent)
        XCTAssertEqual(prepared.backupFilename, backupURL.lastPathComponent)
        XCTAssertNil(prepared.targetSHA256)
        XCTAssertNil(prepared.targetBytes)
        XCTAssertNil(prepared.completedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondBackupURL.path))

        let backupData = try Data(contentsOf: backupURL)
        XCTAssertEqual(prepared.backupSHA256, JSONSupport.sha256Hex(backupData))
        XCTAssertEqual(prepared.backupBytes, UInt64(backupData.count))
        XCTAssertEqual(try sqliteFixtureInt(at: backupURL, sql: "SELECT version FROM schema_version;"), 3)
        XCTAssertEqual(
            try sqliteFixtureText(
                at: backupURL,
                sql: "SELECT packet_json FROM context_handoffs WHERE id='\(legacyPacket.id)';"
            ),
            legacyJSON
        )

        XCTAssertEqual(
            try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"),
            SQLiteStore.schemaVersion
        )
        XCTAssertEqual(try sqliteFixtureText(at: databaseURL, sql: "PRAGMA quick_check;"), "ok")
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM context_handoffs WHERE id='\(legacyPacket.id)';"
            ),
            1
        )
        XCTAssertEqual(
            try sqliteFixtureText(
                at: databaseURL,
                sql: "SELECT packet_json FROM context_handoffs WHERE id='\(legacyPacket.id)';"
            ),
            legacyJSON
        )
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: databaseURL,
                sql: """
                SELECT COUNT(*) FROM forge_migration_receipts
                WHERE migration_id='\(prepared.migrationID)'
                  AND receipt_schema_version=1
                  AND source_filename='\(prepared.sourceFilename)'
                  AND backup_filename='\(prepared.backupFilename)'
                  AND source_version=\(prepared.sourceVersion)
                  AND target_version=\(prepared.targetVersion)
                  AND source_sha256='\(prepared.sourceSHA256)'
                  AND source_bytes=\(prepared.sourceBytes);
                """
            ),
            1
        )
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM forge_migration_receipts;"
            ),
            1
        )
        XCTAssertThrowsError(
            try VerifiedMigrationBackup.withMigrationLock(
                databaseURL: databaseURL,
                timeoutSeconds: 0.05
            ) {
                XCTFail("a second process entered the committed migration boundary")
            }
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("interprocess migration lock"),
                "\(error)"
            )
        }

        let termination = try forceKillMigrationXCTestFixture(child, timeout: 5)
        XCTAssertEqual(termination.reason, .uncaughtSignal)
        XCTAssertEqual(termination.status, SIGKILL)
        XCTAssertEqual(
            try VerifiedMigrationBackup.withMigrationLock(
                databaseURL: databaseURL,
                timeoutSeconds: 1
            ) { 42 },
            42
        )

        let recovered = try SQLiteStore(path: databaseURL)
        let recoveredPacket = try XCTUnwrap(recovered.handoffGet(id: legacyPacket.id))
        XCTAssertEqual(recoveredPacket.id, legacyPacket.id)
        XCTAssertEqual(recoveredPacket.createdAt, legacyPacket.createdAt)
        XCTAssertEqual(recoveredPacket.updatedAt, legacyPacket.updatedAt)
        XCTAssertEqual(recoveredPacket.source, legacyPacket.source)
        XCTAssertEqual(recoveredPacket.resumeReady, legacyPacket.resumeReady)
        XCTAssertEqual(recoveredPacket.goal, legacyPacket.goal)
        XCTAssertEqual(recoveredPacket.nextActions, legacyPacket.nextActions)
        XCTAssertEqual(try recovered.handoffList(limit: 10).map(\.id), [legacyPacket.id])
        recovered.close()

        XCTAssertEqual(
            try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"),
            SQLiteStore.schemaVersion
        )
        XCTAssertEqual(try sqliteFixtureInt(at: databaseURL, sql: "SELECT COUNT(*) FROM schema_version;"), 1)
        XCTAssertEqual(try sqliteFixtureText(at: databaseURL, sql: "PRAGMA quick_check;"), "ok")
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM context_handoffs WHERE id='\(legacyPacket.id)';"
            ),
            1
        )
        XCTAssertEqual(
            try sqliteFixtureText(
                at: databaseURL,
                sql: "SELECT packet_json FROM context_handoffs WHERE id='\(legacyPacket.id)';"
            ),
            legacyJSON
        )
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM forge_migration_receipts;"
            ),
            1
        )
        XCTAssertEqual(try Data(contentsOf: backupURL), backupData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondBackupURL.path))

        let completed = try JSONDecoder().decode(
            VerifiedMigrationBackupManifest.self,
            from: Data(contentsOf: activeManifestURL)
        )
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.migrationID, prepared.migrationID)
        XCTAssertEqual(completed.preparedAt, prepared.preparedAt)
        XCTAssertEqual(completed.sourceSHA256, prepared.sourceSHA256)
        XCTAssertEqual(completed.sourceBytes, prepared.sourceBytes)
        XCTAssertEqual(completed.backupSHA256, prepared.backupSHA256)
        XCTAssertEqual(completed.backupBytes, prepared.backupBytes)
        XCTAssertNotNil(completed.targetSHA256)
        XCTAssertNotNil(completed.targetBytes)
        XCTAssertNotNil(completed.completedAt)
        XCTAssertEqual(
            try JSONDecoder().decode(
                VerifiedMigrationBackupManifest.self,
                from: Data(contentsOf: archiveURL)
            ),
            completed
        )

        let completedManifestData = try Data(contentsOf: activeManifestURL)
        let archivedManifestData = try Data(contentsOf: archiveURL)
        let reopened = try SQLiteStore(path: databaseURL)
        try reopened.migrate()
        XCTAssertEqual(try reopened.handoffList(limit: 10).map(\.id), [legacyPacket.id])
        reopened.close()
        XCTAssertEqual(try Data(contentsOf: activeManifestURL), completedManifestData)
        XCTAssertEqual(try Data(contentsOf: archiveURL), archivedManifestData)
        XCTAssertEqual(try Data(contentsOf: backupURL), backupData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondBackupURL.path))
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM forge_migration_receipts;"
            ),
            1
        )
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM context_handoffs WHERE id='\(legacyPacket.id)';"
            ),
            1
        )
    }

    private func runPreparedSQLiteMigrationChild(
        databaseURL: URL,
        readyURL: URL
    ) throws {
        try VerifiedMigrationBackup.withMigrationLock(
            databaseURL: databaseURL,
            timeoutSeconds: 5
        ) {
            try withSQLiteFixture(at: databaseURL) { database in
                try executeSQLiteFixture(
                    database,
                    sql: """
                    PRAGMA busy_timeout=3000;
                    PRAGMA journal_mode=WAL;
                    PRAGMA foreign_keys=ON;
                    PRAGMA synchronous=FULL;
                    BEGIN IMMEDIATE;
                    """
                )
                let prepared = try VerifiedMigrationBackup
                    .prepareSQLiteMigrationAtWriteBoundary(
                        database: database,
                        sourceURL: databaseURL,
                        backupURL: databaseURL.deletingLastPathComponent()
                            .appendingPathComponent("store.pre-migration-v3.sqlite3"),
                        sourceVersion: 3,
                        targetVersion: SQLiteStore.schemaVersion,
                        versionQuery: "SELECT version FROM schema_version LIMIT 1"
                    )
                guard prepared.state == .prepared else {
                    throw SQLiteFixtureError.failure(
                        "migration child did not persist a prepared manifest"
                    )
                }
                try Data(prepared.migrationID.utf8).write(to: readyURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: readyURL.path
                )

                let deadline = Date().addingTimeInterval(15)
                while Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                throw SQLiteFixtureError.failure(
                    "migration child was not terminated within its bounded wait"
                )
            }
        }
    }

    private func runCommittedSQLiteMigrationChild(
        databaseURL: URL,
        readyURL: URL
    ) throws {
        let store = try SQLiteStore(
            path: databaseURL,
            postMigrationCommitObserver: { manifest in
                guard manifest.state == .prepared,
                      manifest.storageKind == .sqlite,
                      manifest.sourceVersion == 3,
                      manifest.targetVersion == SQLiteStore.schemaVersion else {
                    throw SQLiteFixtureError.failure(
                        "migration child reached the commit boundary with an invalid manifest"
                    )
                }
                try Data(manifest.migrationID.utf8).write(to: readyURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: readyURL.path
                )

                let deadline = Date().addingTimeInterval(15)
                while Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                throw SQLiteFixtureError.failure(
                    "migration child was not terminated at the commit boundary"
                )
            }
        )
        store.close()
        throw SQLiteFixtureError.failure(
            "migration child completed past the commit boundary"
        )
    }

    func testNonemptyUnversionedStoreFailsClosedWithoutMutatingDatabase() throws {
        let databaseURL = tempHome.appendingPathComponent("unversioned-store.sqlite")
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                PRAGMA journal_mode=DELETE;
                CREATE TABLE foreign_records(id INTEGER PRIMARY KEY, payload TEXT NOT NULL);
                INSERT INTO foreign_records(id,payload) VALUES(1,'must remain byte-for-byte intact');
                """
            )
        }
        let originalBytes = try Data(contentsOf: databaseURL)

        XCTAssertThrowsError(try SQLiteStore(path: databaseURL)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("unversioned SQLite database is not empty"),
                "unexpected error: \(error)"
            )
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-journal"))

        let freshURL = tempHome.appendingPathComponent("fresh-store.sqlite")
        let fresh = try SQLiteStore(path: freshURL)
        XCTAssertEqual(
            try sqliteFixtureInt(at: freshURL, sql: "SELECT version FROM schema_version;"),
            SQLiteStore.schemaVersion
        )
        fresh.close()
    }

    func testNonMutatingSQLitePreflightRejectsInterruptedJournalWithoutChangingBytes() throws {
        let databaseURL = tempHome.appendingPathComponent("interrupted-journal.sqlite")
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: "CREATE TABLE foreign_records(id INTEGER PRIMARY KEY, payload TEXT NOT NULL);"
            )
        }
        let journalURL = URL(fileURLWithPath: databaseURL.path + "-journal")
        let journalBytes = Data([0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]
            + Array(repeating: 0x41, count: 512))
        try journalBytes.write(to: journalURL)
        let databaseBytes = try Data(contentsOf: databaseURL)

        XCTAssertThrowsError(
            try VerifiedMigrationBackup.withNonMutatingSQLitePreflight(
                databaseURL: databaseURL
            ) { _ in
                XCTFail("interrupted rollback journal must reject before inspection")
            }
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("rollback journal"))
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), databaseBytes)
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))
    }

    func testNonMutatingSQLitePreflightReadsWALCloneWithoutChangingSourceFamily() throws {
        let databaseURL = tempHome.appendingPathComponent("unversioned-wal.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SQLiteFixtureError.failure("could not open WAL preflight fixture")
        }
        defer { sqlite3_close(database) }
        try executeSQLiteFixture(
            database,
            sql: """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            PRAGMA wal_checkpoint(TRUNCATE);
            CREATE VIEW foreign_view AS SELECT 1 AS value;
            """
        )
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: databaseURL.path + "-shm")
        let databaseBytes = try Data(contentsOf: databaseURL)
        let walBytes = try Data(contentsOf: walURL)
        let shmBytes = try Data(contentsOf: shmURL)
        XCTAssertFalse(walBytes.isEmpty)

        XCTAssertThrowsError(
            try VerifiedMigrationBackup.withNonMutatingSQLitePreflight(
                databaseURL: databaseURL
            ) { candidate in
                let candidate = try XCTUnwrap(candidate)
                let version = try candidate.integer("PRAGMA user_version;") ?? 0
                try candidate.requireEmptySchemaWhenUnversioned(reportedVersion: version)
            }
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("unversioned SQLite database"))
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), databaseBytes)
        XCTAssertEqual(try Data(contentsOf: walURL), walBytes)
        XCTAssertEqual(try Data(contentsOf: shmURL), shmBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-journal"))
    }

    func testVerifiedMigrationBackupCapturesWALAndRejectsTamperedReuse() throws {
        let databaseURL = tempHome.appendingPathComponent("wal-source.sqlite3")
        let backupURL = tempHome.appendingPathComponent("wal-source.pre-migration-v2.sqlite3")
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SQLiteFixtureError.failure("could not open WAL fixture")
        }
        defer { sqlite3_close(database) }
        try executeSQLiteFixture(
            database,
            sql: """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE schema_version(version INTEGER NOT NULL);
            INSERT INTO schema_version(version) VALUES(2);
            CREATE TABLE migration_fixture(id INTEGER PRIMARY KEY,body TEXT NOT NULL);
            PRAGMA wal_checkpoint(TRUNCATE);
            BEGIN IMMEDIATE;
            INSERT INTO migration_fixture(id,body) VALUES(1,'committed only after checkpoint boundary');
            COMMIT;
            """
        )
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        XCTAssertGreaterThan(
            (try FileManager.default.attributesOfItem(atPath: walURL.path)[.size]
                as? NSNumber)?.intValue ?? 0,
            0
        )

        let first = try VerifiedMigrationBackup.snapshotSQLite(
            database: database,
            to: backupURL,
            expectedVersion: 2,
            versionQuery: "SELECT version FROM schema_version LIMIT 1"
        )
        XCTAssertEqual(
            try sqliteFixtureText(
                at: backupURL,
                sql: "SELECT body FROM migration_fixture WHERE id=1;"
            ),
            "committed only after checkpoint boundary"
        )
        XCTAssertEqual(try sqliteFixtureText(at: backupURL, sql: "PRAGMA quick_check;"), "ok")
        let firstData = try Data(contentsOf: backupURL)
        func recoveryArtifacts() throws -> [String] {
            try FileManager.default.contentsOfDirectory(
                at: tempHome,
                includingPropertiesForKeys: nil
            )
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("wal-source.pre-migration-v2") }
            .sorted()
        }
        XCTAssertEqual(try recoveryArtifacts(), [backupURL.lastPathComponent])
        let reused = try VerifiedMigrationBackup.snapshotSQLite(
            database: database,
            to: backupURL,
            expectedVersion: 2,
            versionQuery: "SELECT version FROM schema_version LIMIT 1"
        )
        XCTAssertEqual(reused, first)
        XCTAssertEqual(try Data(contentsOf: backupURL), firstData)
        XCTAssertEqual(try recoveryArtifacts(), [backupURL.lastPathComponent])

        try withSQLiteFixture(at: backupURL) { backupDatabase in
            try executeSQLiteFixture(
                backupDatabase,
                sql: "UPDATE migration_fixture SET body='tampered recovery artifact' WHERE id=1;"
            )
        }
        XCTAssertThrowsError(
            try VerifiedMigrationBackup.snapshotSQLite(
                database: database,
                to: backupURL,
                expectedVersion: 2,
                versionQuery: "SELECT version FROM schema_version LIMIT 1"
            )
        )
        XCTAssertEqual(
            try sqliteFixtureText(
                at: databaseURL,
                sql: "SELECT body FROM migration_fixture WHERE id=1;"
            ),
            "committed only after checkpoint boundary"
        )
        XCTAssertEqual(try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"), 2)
    }

    func testSQLiteMainFileMovedGuardRejectsStablePathnameReplacement() throws {
        let sourceURL = tempHome.appendingPathComponent("guard-source.sqlite3")
        let replacementURL = tempHome.appendingPathComponent("guard-replacement.sqlite3")
        let parkedURL = tempHome.appendingPathComponent("guard-original.sqlite3")
        try withSQLiteFixture(at: sourceURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                PRAGMA journal_mode=DELETE;
                CREATE TABLE identity_marker(value TEXT NOT NULL);
                INSERT INTO identity_marker(value) VALUES('original');
                """
            )
            try withSQLiteFixture(at: replacementURL) { replacement in
                try executeSQLiteFixture(
                    replacement,
                    sql: """
                    PRAGMA journal_mode=DELETE;
                    CREATE TABLE identity_marker(value TEXT NOT NULL);
                    INSERT INTO identity_marker(value) VALUES('replacement');
                    """
                )
            }

            try FileManager.default.moveItem(at: sourceURL, to: parkedURL)
            try FileManager.default.moveItem(at: replacementURL, to: sourceURL)

            XCTAssertThrowsError(
                try VerifiedMigrationBackup.requireSQLiteMainFileUnmoved(
                    database: database,
                    sourceURL: sourceURL,
                    purpose: "stable replacement test"
                )
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("SQLite main file moved or was replaced")
                        && error.localizedDescription.contains("stable replacement test"),
                    error.localizedDescription
                )
            }
        }
    }

    func testSQLiteMainFileMovedGuardRecordsRestoredPathCycleWithoutTrustClaim() throws {
        let sourceURL = tempHome.appendingPathComponent("restored-source.sqlite3")
        let replacementURL = tempHome.appendingPathComponent("restored-replacement.sqlite3")
        let parkedURL = tempHome.appendingPathComponent("restored-original.sqlite3")
        let displacedURL = tempHome.appendingPathComponent("restored-displaced.sqlite3")
        try withSQLiteFixture(at: sourceURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                PRAGMA journal_mode=DELETE;
                CREATE TABLE identity_marker(value TEXT NOT NULL);
                INSERT INTO identity_marker(value) VALUES('original');
                """
            )
            try withSQLiteFixture(at: replacementURL) { replacement in
                try executeSQLiteFixture(
                    replacement,
                    sql: """
                    PRAGMA journal_mode=DELETE;
                    CREATE TABLE identity_marker(value TEXT NOT NULL);
                    INSERT INTO identity_marker(value) VALUES('replacement');
                    """
                )
            }

            try FileManager.default.moveItem(at: sourceURL, to: parkedURL)
            try FileManager.default.moveItem(at: replacementURL, to: sourceURL)
            XCTAssertThrowsError(
                try VerifiedMigrationBackup.requireSQLiteMainFileUnmoved(
                    database: database,
                    sourceURL: sourceURL,
                    purpose: "replacement observation test"
                )
            )
            try FileManager.default.moveItem(at: sourceURL, to: displacedURL)
            try FileManager.default.moveItem(at: parkedURL, to: sourceURL)

            // Record the VFS-specific result without treating either outcome as a
            // portable security guarantee or broadening the same-user trust boundary.
            do {
                try VerifiedMigrationBackup.requireSQLiteMainFileUnmoved(
                    database: database,
                    sourceURL: sourceURL,
                    purpose: "restored pathname observation test"
                )
                print("FORGE_SQLITE_RESTORED_PATH_OBSERVATION=accepted_after_restore")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.contains("moved or was replaced")
                        && error.localizedDescription.contains(
                            "restored pathname observation test"
                    ),
                    error.localizedDescription
                )
                print("FORGE_SQLITE_RESTORED_PATH_OBSERVATION=failed_closed_after_restore")
            }
            XCTAssertEqual(
                try sqliteFixtureText(
                    at: sourceURL,
                    sql: "SELECT value FROM identity_marker LIMIT 1;"
                ),
                "original"
            )
        }
        XCTAssertEqual(
            try sqliteFixtureText(
                at: displacedURL,
                sql: "SELECT value FROM identity_marker LIMIT 1;"
            ),
            "replacement"
        )
    }

    func testPrepareSQLiteMigrationRejectsMovedMainFileBeforeArtifacts() throws {
        let sourceURL = tempHome.appendingPathComponent("prepare-failure.sqlite3")
        let replacementURL = tempHome.appendingPathComponent("prepare-replacement.sqlite3")
        let parkedURL = tempHome.appendingPathComponent("prepare-original.sqlite3")
        let backupURL = tempHome.appendingPathComponent(
            "prepare-failure.pre-migration-v2.sqlite3"
        )
        try withSQLiteFixture(at: sourceURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                PRAGMA journal_mode=DELETE;
                CREATE TABLE schema_version(version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES(2);
                CREATE TABLE identity_marker(value TEXT NOT NULL);
                INSERT INTO identity_marker(value) VALUES('original');
                """
            )
            try withSQLiteFixture(at: replacementURL) { replacement in
                try executeSQLiteFixture(
                    replacement,
                    sql: """
                    PRAGMA journal_mode=DELETE;
                    CREATE TABLE schema_version(version INTEGER NOT NULL);
                    INSERT INTO schema_version(version) VALUES(2);
                    CREATE TABLE identity_marker(value TEXT NOT NULL);
                    INSERT INTO identity_marker(value) VALUES('replacement');
                    """
                )
            }
            try executeSQLiteFixture(database, sql: "BEGIN IMMEDIATE;")
            defer { try? executeSQLiteFixture(database, sql: "ROLLBACK;") }

            try FileManager.default.moveItem(at: sourceURL, to: parkedURL)
            try FileManager.default.moveItem(at: replacementURL, to: sourceURL)

            XCTAssertThrowsError(
                try VerifiedMigrationBackup.prepareSQLiteMigrationAtWriteBoundary(
                    database: database,
                    sourceURL: sourceURL,
                    backupURL: backupURL,
                    sourceVersion: 2,
                    targetVersion: 3,
                    versionQuery: "SELECT version FROM schema_version LIMIT 1"
                )
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("SQLite main file moved or was replaced")
                        && error.localizedDescription.contains("migration backup writer entry"),
                    error.localizedDescription
                )
            }

            try FileManager.default.moveItem(at: sourceURL, to: replacementURL)
            try FileManager.default.moveItem(at: parkedURL, to: sourceURL)
            XCTAssertEqual(
                try sqliteFixtureInt(
                    at: sourceURL,
                    sql: "SELECT version FROM schema_version LIMIT 1;"
                ),
                2
            )
            XCTAssertEqual(
                try sqliteFixtureText(
                    at: sourceURL,
                    sql: "SELECT value FROM identity_marker LIMIT 1;"
                ),
                "original"
            )
            XCTAssertEqual(
                try sqliteFixtureInt(
                    at: replacementURL,
                    sql: "SELECT version FROM schema_version LIMIT 1;"
                ),
                2
            )
            XCTAssertEqual(
                try sqliteFixtureText(
                    at: replacementURL,
                    sql: "SELECT value FROM identity_marker LIMIT 1;"
                ),
                "replacement"
            )
            XCTAssertEqual(
                try sqliteFixtureInt(
                    at: sourceURL,
                    sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type='table' AND name='forge_migration_receipts';
                    """
                ),
                0
            )

            let migrationArtifacts = try FileManager.default.contentsOfDirectory(
                at: tempHome,
                includingPropertiesForKeys: nil
            )
            .map(\.lastPathComponent)
            .filter {
                $0.contains("pre-migration") || $0.contains("migration-manifest")
            }
            XCTAssertEqual(migrationArtifacts, [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: VerifiedMigrationBackup.activeManifestURL(for: sourceURL).path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: VerifiedMigrationBackup.archivedManifestURL(
                        for: backupURL,
                        targetVersion: 3
                    ).path
                )
            )
        }
    }

    func testVerifiedMigrationManifestReconcilesPreparedSQLiteCompletion() throws {
        let sourceURL = tempHome.appendingPathComponent("manifest-source.sqlite3")
        let backupURL = tempHome.appendingPathComponent(
            "manifest-source.pre-migration-v1.sqlite3"
        )
        let source = Data("stable logical source".utf8)
        try source.write(to: sourceURL)
        let backup = try VerifiedMigrationBackup.copyFile(
            from: sourceURL,
            to: backupURL,
            maximumBytes: 4_096
        )

        let prepared = try VerifiedMigrationBackup.prepareMigrationManifest(
            sourceURL: sourceURL,
            backup: backup,
            sourceVersion: 1,
            targetVersion: 2,
            storageKind: .sqlite,
            preparedAt: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(prepared.state, .prepared)
        XCTAssertEqual(prepared.sourceVersion, 1)
        XCTAssertEqual(prepared.targetVersion, 2)
        XCTAssertEqual(prepared.sourceSHA256, backup.sha256)
        XCTAssertEqual(prepared.sourceBytes, backup.bytes)
        XCTAssertNil(prepared.targetSHA256)
        XCTAssertTrue(prepared.rollbackInstructions.contains { $0.contains("-wal") })

        let activeURL = VerifiedMigrationBackup.activeManifestURL(for: sourceURL)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: activeURL.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o600
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                VerifiedMigrationBackupManifest.self,
                from: Data(contentsOf: activeURL)
            ),
            prepared
        )
        XCTAssertEqual(
            try VerifiedMigrationBackup.reconcileMigrationManifest(
                sourceURL: sourceURL,
                observedVersion: 1
            ),
            prepared
        )

        let targetDatabaseURL = tempHome.appendingPathComponent("target-database.sqlite3")
        let targetProofURL = tempHome.appendingPathComponent("ephemeral-target-proof.sqlite3")
        var capturedTarget: VerifiedMigrationBackupMetadata?
        try withSQLiteFixture(at: targetDatabaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version(version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES(2);
                CREATE TABLE target_payload(value TEXT NOT NULL);
                INSERT INTO target_payload(value) VALUES('verified logical target');
                """
            )
            capturedTarget = try VerifiedMigrationBackup.snapshotSQLite(
                database: database,
                to: targetProofURL,
                expectedVersion: 2,
                versionQuery: "SELECT version FROM schema_version LIMIT 1"
            )
        }
        let target = try XCTUnwrap(capturedTarget)
        let completed = try XCTUnwrap(
            VerifiedMigrationBackup.reconcileMigrationManifest(
                sourceURL: sourceURL,
                observedVersion: 2,
                targetMetadata: target,
                completedAt: Date(timeIntervalSince1970: 200)
            )
        )
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.targetSHA256, target.sha256)
        XCTAssertEqual(completed.targetBytes, target.bytes)
        XCTAssertNotNil(completed.completedAt)

        let archiveURL = VerifiedMigrationBackup.archivedManifestURL(
            for: backupURL,
            targetVersion: 2
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                VerifiedMigrationBackupManifest.self,
                from: Data(contentsOf: archiveURL)
            ),
            completed
        )
        let stableManifest = try Data(contentsOf: activeURL)
        XCTAssertEqual(
            try VerifiedMigrationBackup.reconcileMigrationManifest(
                sourceURL: sourceURL,
                observedVersion: 2
            ),
            completed
        )
        XCTAssertEqual(try Data(contentsOf: activeURL), stableManifest)

        let replayPrepared = try VerifiedMigrationBackup.prepareMigrationManifest(
            sourceURL: sourceURL,
            backup: backup,
            sourceVersion: 1,
            targetVersion: 2,
            storageKind: .sqlite,
            preparedAt: Date(timeIntervalSince1970: 300)
        )
        let conflictingDatabaseURL = tempHome.appendingPathComponent(
            "conflicting-target-database.sqlite3"
        )
        let conflictingProofURL = tempHome.appendingPathComponent(
            "conflicting-target-proof.sqlite3"
        )
        var capturedConflictingTarget: VerifiedMigrationBackupMetadata?
        try withSQLiteFixture(at: conflictingDatabaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version(version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES(2);
                CREATE TABLE target_payload(value TEXT NOT NULL);
                INSERT INTO target_payload(value) VALUES('different logical target');
                """
            )
            capturedConflictingTarget = try VerifiedMigrationBackup.snapshotSQLite(
                database: database,
                to: conflictingProofURL,
                expectedVersion: 2,
                versionQuery: "SELECT version FROM schema_version LIMIT 1"
            )
        }
        let conflictingTarget = try XCTUnwrap(capturedConflictingTarget)
        XCTAssertThrowsError(
            try VerifiedMigrationBackup.completeMigrationManifest(
                sourceURL: sourceURL,
                preparedManifest: replayPrepared,
                observedVersion: 2,
                targetMetadata: conflictingTarget,
                completedAt: Date(timeIntervalSince1970: 400)
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("archived migration manifest conflicts"), "\(error)")
        }
        XCTAssertEqual(
            try JSONDecoder().decode(
                VerifiedMigrationBackupManifest.self,
                from: Data(contentsOf: archiveURL)
            ),
            completed
        )
        XCTAssertThrowsError(
            try VerifiedMigrationBackup.reconcileMigrationManifest(
                sourceURL: sourceURL,
                observedVersion: 3
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("observed version 3"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)
        XCTAssertEqual(try Data(contentsOf: backupURL), source)
    }

    func testSQLiteStoreDoesNotRecreateMissingSourceOwnedByManifest() throws {
        let sourceURL = tempHome.appendingPathComponent("missing-manifest-source.sqlite3")
        let backupURL = tempHome.appendingPathComponent(
            "missing-manifest-source.pre-migration-v1.sqlite3"
        )
        try Data("source awaiting migration".utf8).write(to: sourceURL)
        let backup = try VerifiedMigrationBackup.copyFile(
            from: sourceURL,
            to: backupURL,
            maximumBytes: 4_096
        )
        _ = try VerifiedMigrationBackup.prepareMigrationManifest(
            sourceURL: sourceURL,
            backup: backup,
            sourceVersion: 1,
            targetVersion: SQLiteStore.schemaVersion,
            storageKind: .sqlite
        )
        try FileManager.default.removeItem(at: sourceURL)

        XCTAssertThrowsError(try SQLiteStore(path: sourceURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("observed version 0"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: backupURL), Data("source awaiting migration".utf8))
    }

    func testSQLiteStoreRejectsSourceChangedAfterPreparedBackup() throws {
        let databaseURL = tempHome.appendingPathComponent("generation-fence.sqlite3")
        let backupURL = tempHome.appendingPathComponent(
            "generation-fence.pre-migration-v2.sqlite3"
        )
        var backup: VerifiedMigrationBackupMetadata?
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version(version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES(2);
                CREATE TABLE memory_notes(
                  key TEXT PRIMARY KEY,body TEXT NOT NULL,tags_json TEXT NOT NULL,
                  created_at TEXT NOT NULL,updated_at TEXT NOT NULL
                );
                INSERT INTO memory_notes VALUES('generation','before','[]','t','t');
                """
            )
            backup = try VerifiedMigrationBackup.snapshotSQLite(
                database: database,
                to: backupURL,
                expectedVersion: 2,
                versionQuery: "SELECT version FROM schema_version LIMIT 1"
            )
        }
        _ = try VerifiedMigrationBackup.prepareMigrationManifest(
            sourceURL: databaseURL,
            backup: try XCTUnwrap(backup),
            sourceVersion: 2,
            targetVersion: SQLiteStore.schemaVersion,
            storageKind: .sqlite
        )
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: "UPDATE memory_notes SET body='after' WHERE key='generation';"
            )
        }

        XCTAssertThrowsError(try SQLiteStore(path: databaseURL)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "unrelated prepared migration already owns this source"
                ),
                "\(error)"
            )
        }
        XCTAssertEqual(
            try sqliteFixtureText(
                at: databaseURL,
                sql: "SELECT body FROM memory_notes WHERE key='generation';"
            ),
            "after"
        )
        XCTAssertEqual(try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"), 2)
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='forge_migration_receipts';"
            ),
            0
        )
    }

    func testSQLiteStoreRejectsUnrelatedTargetWithoutMigrationReceipt() throws {
        let databaseURL = tempHome.appendingPathComponent("lineage-swap.sqlite3")
        let backupURL = tempHome.appendingPathComponent("lineage-swap.pre-migration-v2.sqlite3")
        var backup: VerifiedMigrationBackupMetadata?
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version(version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES(2);
                """
            )
            backup = try VerifiedMigrationBackup.snapshotSQLite(
                database: database,
                to: backupURL,
                expectedVersion: 2,
                versionQuery: "SELECT version FROM schema_version LIMIT 1"
            )
        }
        _ = try VerifiedMigrationBackup.prepareMigrationManifest(
            sourceURL: databaseURL,
            backup: try XCTUnwrap(backup),
            sourceVersion: 2,
            targetVersion: SQLiteStore.schemaVersion,
            storageKind: .sqlite
        )
        try FileManager.default.removeItem(at: databaseURL)
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version(version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES(\(SQLiteStore.schemaVersion));
                CREATE TABLE unrelated_target(value TEXT NOT NULL);
                INSERT INTO unrelated_target(value) VALUES('must survive rejection');
                """
            )
        }

        XCTAssertThrowsError(try SQLiteStore(path: databaseURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("missing its migration receipt"), "\(error)")
        }
        XCTAssertEqual(
            try sqliteFixtureText(at: databaseURL, sql: "SELECT value FROM unrelated_target LIMIT 1;"),
            "must survive rejection"
        )
        XCTAssertEqual(
            try sqliteFixtureInt(
                at: databaseURL,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='context_handoffs';"
            ),
            0
        )
    }

    func testMigrationArtifactsRejectFIFOsWithoutBlockingAndRecoverStaleTemporaryFile() throws {
        let sourceURL = tempHome.appendingPathComponent("nonblocking-source.json")
        let backupURL = tempHome.appendingPathComponent("nonblocking-backup.json")
        let source = Data(#"{"schema_version":1}"#.utf8)
        try source.write(to: sourceURL)
        let backup = try VerifiedMigrationBackup.copyFile(
            from: sourceURL,
            to: backupURL,
            maximumBytes: 4_096
        )
        _ = try VerifiedMigrationBackup.prepareMigrationManifest(
            sourceURL: sourceURL,
            backup: backup,
            sourceVersion: 1,
            targetVersion: 2,
            storageKind: .sqlite
        )
        let activeURL = VerifiedMigrationBackup.activeManifestURL(for: sourceURL)
        let manifestData = try Data(contentsOf: activeURL)
        try FileManager.default.removeItem(at: activeURL)
        XCTAssertEqual(Darwin.mkfifo(activeURL.path, mode_t(0o600)), 0)
        let manifestStart = Date()
        XCTAssertThrowsError(
            try VerifiedMigrationBackup.reconcileMigrationManifest(
                sourceURL: sourceURL,
                observedVersion: 1
            )
        )
        XCTAssertLessThan(Date().timeIntervalSince(manifestStart), 1)

        try FileManager.default.removeItem(at: activeURL)
        try manifestData.write(to: activeURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeURL.path)
        try FileManager.default.removeItem(at: backupURL)
        XCTAssertEqual(Darwin.mkfifo(backupURL.path, mode_t(0o600)), 0)
        let backupStart = Date()
        XCTAssertThrowsError(
            try VerifiedMigrationBackup.reconcileMigrationManifest(
                sourceURL: sourceURL,
                observedVersion: 1
            )
        )
        XCTAssertLessThan(Date().timeIntervalSince(backupStart), 1)
        try FileManager.default.removeItem(at: backupURL)

        let staleURL = backupURL.deletingLastPathComponent().appendingPathComponent(
            ".\(backupURL.lastPathComponent).migration-tmp"
        )
        try Data("stale interrupted write".utf8).write(to: staleURL)
        let recovered = try VerifiedMigrationBackup.copyFile(
            from: sourceURL,
            to: backupURL,
            maximumBytes: 4_096
        )
        XCTAssertEqual(recovered.sha256, JSONSupport.sha256Hex(source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
    }

    func testVerifiedMigrationManifestRejectsTamperedBackupAndLinkedManifest() throws {
        let sourceURL = tempHome.appendingPathComponent("manifest-tamper-source.json")
        let backupURL = tempHome.appendingPathComponent(
            "manifest-tamper-source.pre-migration-v1.json"
        )
        let source = Data(#"{"schema_version":1}"#.utf8)
        try source.write(to: sourceURL)
        let backup = try VerifiedMigrationBackup.copyFile(
            from: sourceURL,
            to: backupURL,
            maximumBytes: 4_096
        )
        _ = try VerifiedMigrationBackup.prepareMigrationManifest(
            sourceURL: sourceURL,
            backup: backup,
            sourceVersion: 1,
            targetVersion: 2,
            storageKind: .sqlite
        )
        try Data("tampered backup".utf8).write(to: backupURL, options: .atomic)
        XCTAssertThrowsError(
            try VerifiedMigrationBackup.reconcileMigrationManifest(
                sourceURL: sourceURL,
                observedVersion: 1
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("no longer matches"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)

        try FileManager.default.removeItem(at: backupURL)
        _ = try VerifiedMigrationBackup.copyFile(
            from: sourceURL,
            to: backupURL,
            maximumBytes: 4_096
        )
        let activeURL = VerifiedMigrationBackup.activeManifestURL(for: sourceURL)
        try FileManager.default.removeItem(at: activeURL)
        let symlinkTarget = tempHome.appendingPathComponent("manifest-symlink-target.json")
        try Data("{}".utf8).write(to: symlinkTarget)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: symlinkTarget.path
        )
        try FileManager.default.createSymbolicLink(
            at: activeURL,
            withDestinationURL: symlinkTarget
        )
        XCTAssertThrowsError(
            try VerifiedMigrationBackup.reconcileMigrationManifest(
                sourceURL: sourceURL,
                observedVersion: 1
            )
        )
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: symlinkTarget.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o644,
            "a rejected manifest symlink target must not be chmodded"
        )
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)
    }

    func testVerifiedMigrationBackupEnforcesBoundsAndRejectsLinkedArtifacts() throws {
        let sourceURL = tempHome.appendingPathComponent("ledger.json")
        let fileBackupURL = tempHome.appendingPathComponent("ledger.pre-migration-v1.json")
        let source = Data(#"{"schema_version":1,"records":[]}"#.utf8)
        try source.write(to: sourceURL)

        let metadata = try VerifiedMigrationBackup.copyFile(
            from: sourceURL,
            to: fileBackupURL,
            maximumBytes: 4_096
        )
        XCTAssertEqual(metadata.bytes, UInt64(source.count))
        XCTAssertEqual(try Data(contentsOf: fileBackupURL), source)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: fileBackupURL.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o600
        )

        try FileManager.default.removeItem(at: fileBackupURL)
        let symlinkTarget = tempHome.appendingPathComponent("symlink-target.json")
        try source.write(to: symlinkTarget)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: symlinkTarget.path
        )
        try FileManager.default.createSymbolicLink(
            at: fileBackupURL,
            withDestinationURL: symlinkTarget
        )
        XCTAssertThrowsError(
            try VerifiedMigrationBackup.copyFile(
                from: sourceURL,
                to: fileBackupURL,
                maximumBytes: 4_096
            )
        )
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: symlinkTarget.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o644,
            "a rejected symlink target must not be chmodded"
        )

        try FileManager.default.removeItem(at: fileBackupURL)
        try FileManager.default.linkItem(at: symlinkTarget, to: fileBackupURL)
        XCTAssertThrowsError(
            try VerifiedMigrationBackup.copyFile(
                from: sourceURL,
                to: fileBackupURL,
                maximumBytes: 4_096
            )
        )

        let databaseURL = tempHome.appendingPathComponent("bounded-source.sqlite3")
        let sqliteBackupURL = tempHome.appendingPathComponent(
            "bounded-source.pre-migration-v2.sqlite3"
        )
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SQLiteFixtureError.failure("could not open bounded SQLite fixture")
        }
        defer { sqlite3_close(database) }
        try executeSQLiteFixture(
            database,
            sql: """
            CREATE TABLE schema_version(version INTEGER NOT NULL);
            INSERT INTO schema_version(version) VALUES(2);
            CREATE TABLE migration_fixture(id INTEGER PRIMARY KEY, body BLOB NOT NULL);
            INSERT INTO migration_fixture(id,body) VALUES(1,zeroblob(16384));
            """
        )
        let sourcePageSize = try XCTUnwrap(
            sqliteFixtureInt(at: databaseURL, sql: "PRAGMA page_size;")
        )
        XCTAssertThrowsError(
            try VerifiedMigrationBackup.snapshotSQLite(
                database: database,
                to: sqliteBackupURL,
                expectedVersion: 2,
                versionQuery: "SELECT version FROM schema_version LIMIT 1",
                maximumBytes: UInt64(sourcePageSize - 1)
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: sqliteBackupURL.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: tempHome.path).contains {
                $0.hasPrefix(".bounded-source.pre-migration-v2.sqlite3.tmp-")
            }
        )

        XCTAssertThrowsError(
            try VerifiedMigrationBackup.snapshotSQLite(
                database: database,
                to: sqliteBackupURL,
                expectedVersion: 2,
                versionQuery: "SELECT version FROM schema_version LIMIT 1",
                timeoutSeconds: Double.leastNonzeroMagnitude
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("deadline"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sqliteBackupURL.path))
    }

    func testVerifiedMigrationLockIsBoundedAndOwnerOnly() throws {
        let databaseURL = tempHome.appendingPathComponent("migration-lock.sqlite3")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "first migration lock holder finished")
        let failures = LockedFailureMessages()

        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                try VerifiedMigrationBackup.withMigrationLock(
                    databaseURL: databaseURL,
                    timeoutSeconds: 1
                ) {
                    entered.signal()
                    guard release.wait(timeout: .now() + 2) == .success else {
                        throw SQLiteFixtureError.failure("migration lock release timed out")
                    }
                }
            } catch {
                failures.append(String(describing: error))
            }
        }

        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertThrowsError(
            try VerifiedMigrationBackup.withMigrationLock(
                databaseURL: databaseURL,
                timeoutSeconds: 0.02
            ) {
                XCTFail("a second same-process migration entered the critical section")
            }
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("process migration lock"), "\(error)")
        }
        release.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(failures.snapshot, [])

        let lockURL = databaseURL.appendingPathExtension("migration.lock")
        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((attributes[.referenceCount] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(
            try VerifiedMigrationBackup.withMigrationLock(
                databaseURL: databaseURL,
                timeoutSeconds: 1
            ) { 42 },
            42
        )
    }

    func testConcurrentPrimaryAndFallbackWritesKeepProjectionsConsistent() throws {
        let primary = try ForgeApp.bootstrap(home: tempHome)
        let fallback = try ForgeApp.bootstrap(home: tempHome)
        defer {
            primary.shutdown()
            fallback.shutdown()
        }

        let failures = LockedFailureMessages()
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            let app = index.isMultiple(of: 2) ? primary : fallback
            do {
                _ = try app.continuity.handoff(
                    arguments: ["goal": "Concurrent handoff \(index)"],
                    clientID: ClientID("concurrent-\(index)")
                )
            } catch {
                failures.append("write \(index): \(error)")
            }
        }
        XCTAssertEqual(failures.snapshot, [])

        let packets = try primary.store.handoffList(limit: 100)
        XCTAssertEqual(packets.count, 24)
        XCTAssertEqual(Set(packets.map(\.id)).count, 24)
        for packet in packets {
            let projection = primary.paths.memoryHandoffsDir.appendingPathComponent("\(packet.id).json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: projection.path), packet.id)
        }

        let authoritativeLatest = try XCTUnwrap(primary.store.handoffLatest())
        let projectedLatest = try String(
            contentsOf: primary.paths.memoryHandoffsDir.appendingPathComponent("LATEST"),
            encoding: .utf8
        )
        XCTAssertEqual(projectedLatest, authoritativeLatest.id)
        let currentTask = try String(contentsOf: primary.paths.memoryCurrentTask, encoding: .utf8)
        XCTAssertTrue(currentTask.contains(authoritativeLatest.id), currentTask)
        XCTAssertTrue(currentTask.contains(authoritativeLatest.goal), currentTask)
    }

    func testPrimaryAndFallbackMCPProcessesShareContinuitySafely() throws {
        let binary = try XCTUnwrap(
            locateContinuityCLIBinary(),
            "The current test build must provide an adjacent forge-conductor CLI"
        )
        let processHome = tempHome.appendingPathComponent("process-home", isDirectory: true)
        try FileManager.default.createDirectory(at: processHome, withIntermediateDirectories: true)
        let primary = try launchMCPFixture(binary: binary, home: processHome, role: "primary")
        let fallback = try launchMCPFixture(binary: binary, home: processHome, role: "fallback")
        defer { primary.close(); fallback.close() }

        try sendMCPHandoff(primary, id: 2, goal: "Primary process handoff")
        try sendMCPHandoff(fallback, id: 2, goal: "Fallback process handoff")
        let primaryOutput = try waitForMCPFixture(primary, timeout: 10)
        let fallbackOutput = try waitForMCPFixture(fallback, timeout: 10)

        for output in [primaryOutput, fallbackOutput] {
            let response = output.first { ($0["id"] as? Int) == 2 }
            let result = try XCTUnwrap(response?["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, false)
            let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            XCTAssertEqual(structured["ok"] as? Bool, true)
            XCTAssertEqual(structured["projection_ok"] as? Bool, true)
        }

        // Read raw storage without ForgeApp bootstrap so projection repair cannot
        // hide an ordering mismatch produced by the two serve processes.
        let store = try SQLiteStore(path: processHome.appendingPathComponent("store.sqlite"))
        let packets = try store.handoffList(limit: 10)
        let latest = try XCTUnwrap(store.handoffLatest())
        store.close()
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(
            Set(packets.map(\.goal)),
            Set(["Primary process handoff", "Fallback process handoff"])
        )

        let paths = AppPaths(home: processHome)
        let pointer = try String(
            contentsOf: paths.memoryHandoffsDir.appendingPathComponent("LATEST"),
            encoding: .utf8
        )
        XCTAssertEqual(pointer, latest.id)
        let markdown = try String(contentsOf: paths.memoryCurrentTask, encoding: .utf8)
        XCTAssertTrue(markdown.contains(latest.id), markdown)
        XCTAssertTrue(markdown.contains(latest.goal), markdown)
    }

    func testConcurrentUpdatesToSamePacketPreserveDisjointFields() throws {
        let primary = try ForgeApp.bootstrap(home: tempHome)
        let fallback = try ForgeApp.bootstrap(home: tempHome)
        defer {
            primary.shutdown()
            fallback.shutdown()
        }
        let client = ClientID("shared-packet-owner")
        let initial = try primary.continuity.checkpoint(
            arguments: ["goal": "Merge concurrent packet updates"],
            clientID: client
        )
        let handoffID = try XCTUnwrap(initial["handoff_id"] as? String)
        let failures = LockedFailureMessages()

        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                if index == 0 {
                    _ = try primary.continuity.checkpoint(
                        arguments: [
                            "handoff_id": handoffID,
                            "blockers": ["Primary blocker"],
                        ],
                        clientID: client
                    )
                } else {
                    _ = try fallback.continuity.checkpoint(
                        arguments: [
                            "handoff_id": handoffID,
                            "decisions": ["Fallback decision"],
                        ],
                        clientID: client
                    )
                }
            } catch {
                failures.append("update \(index): \(error)")
            }
        }
        XCTAssertEqual(failures.snapshot, [])

        let merged = try XCTUnwrap(primary.store.handoffGet(id: handoffID))
        XCTAssertEqual(merged.goal, "Merge concurrent packet updates")
        XCTAssertEqual(merged.blockers, ["Primary blocker"])
        XCTAssertEqual(merged.decisions, ["Fallback decision"])
    }

    func testNarrativeOnlyCheckpointReplacesCurrentTaskProjection() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        _ = try app.continuity.checkpoint(
            arguments: ["goal": "Old projected goal"],
            clientID: ClientID("old-projection")
        )
        let latest = try app.continuity.checkpoint(
            arguments: ["narrative": "Narrative-only latest state"],
            clientID: ClientID("new-projection")
        )
        let latestID = try XCTUnwrap(latest["handoff_id"] as? String)

        let markdown = try String(contentsOf: app.paths.memoryCurrentTask, encoding: .utf8)
        XCTAssertTrue(markdown.contains(latestID), markdown)
        XCTAssertTrue(markdown.contains("Narrative-only latest state"), markdown)
        XCTAssertFalse(markdown.contains("Old projected goal"), markdown)
    }

    func testContinuityToolsListed() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let names = Set(app.tools.toolNames)
        for need in ["session_checkpoint", "session_handoff", "context_get", "context_list"] {
            XCTAssertTrue(names.contains(need), "missing \(need)")
        }

        let server = MCPServer(app: app, clientID: ClientID("continuity-schema"))
        let response = server.handle([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
        ])
        let result = response?["result"] as? [String: Any]
        let descriptors = result?["tools"] as? [[String: Any]] ?? []
        let byName = Dictionary(uniqueKeysWithValues: descriptors.compactMap { descriptor in
            (descriptor["name"] as? String).map { ($0, descriptor) }
        })
        XCTAssertTrue(MCPServeVerifier.requiredContinuityTools.isSubset(of: Set(byName.keys)))

        let checkpointSchema = byName["session_checkpoint"]?["inputSchema"] as? [String: Any]
        let checkpointProperties = checkpointSchema?["properties"] as? [String: Any]
        XCTAssertNotNil(checkpointProperties?["summary"], "summary alias must be advertised to MCP hosts")
        let contextSchema = byName["context_get"]?["inputSchema"] as? [String: Any]
        let contextProperties = contextSchema?["properties"] as? [String: Any]
        XCTAssertNotNil(contextProperties?["handoff_id"])
        XCTAssertNotNil(contextProperties?["resume_ready"])
    }

    func testBudgetLoopEventuallyRequiresHandoff() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("loop")
        try bindProjectContext(app, clientID: client)
        let path = tempHome.appendingPathComponent("loop.txt").path
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": "x"],
            clientID: client
        )
        // Same read repeatedly — soft budget annotates, hard budget blocks.
        var sawHandoffRequired = false
        var sawHardBlock = false
        for _ in 0..<12 {
            let r = try app.tools.call(
                name: "fs_read",
                arguments: ["path": path],
                clientID: client
            )
            if r.payload["handoff_required"] as? Bool == true {
                sawHandoffRequired = true
            }
            if r.payload["code"] as? String == "identical_call_loop" {
                sawHardBlock = true
                break
            }
        }
        XCTAssertTrue(sawHandoffRequired || sawHardBlock, "expected budget continuity signal")
        let latest = try app.continuity.get(preferResumeReady: true)
        // Soft/hard budget writes resume-ready packet
        if sawHandoffRequired || sawHardBlock {
            XCTAssertEqual(latest["found"] as? Bool, true)
        }
    }

    func testBudgetLoopSignalsExactlyAtSoftAndHardThresholds() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        let client = ClientID("exact-loop-thresholds")
        try bindProjectContext(app, clientID: client)
        let path = tempHome.appendingPathComponent("exact-loop.txt").path
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": "threshold"],
            clientID: client
        )

        var softHandoffID: String?
        for count in 1...9 {
            let result = try app.tools.call(
                name: "fs_read",
                arguments: ["path": path],
                clientID: client
            )
            switch count {
            case 1...3:
                XCTAssertTrue(result.ok, "call \(count)")
                XCTAssertNil(result.payload["handoff_required"], "call \(count)")
            case 4:
                XCTAssertTrue(result.ok)
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                softHandoffID = result.payload["handoff_id"] as? String
                XCTAssertNotNil(softHandoffID)
            case 5...8:
                XCTAssertTrue(result.ok, "call \(count)")
                XCTAssertNil(result.payload["code"], "call \(count)")
            case 9:
                XCTAssertFalse(result.ok)
                XCTAssertTrue(result.isError)
                XCTAssertEqual(result.payload["code"] as? String, "identical_call_loop")
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                XCTAssertEqual(result.payload["handoff_id"] as? String, softHandoffID)
            default:
                XCTFail("unexpected count")
            }
        }
    }

    func testToolGrantDenialLoopSignalsExactlyAtSoftAndHardThresholds() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("denied-exact-loop-thresholds")
        try configureAllowedProjectRoot(app)
        let start = try app.tools.call(
            name: "agent_run_start",
            arguments: [
                "agent_id": "explore",
                "goal": "Exercise a stable tool-grant denial",
                "cwd": tempHome.path,
            ],
            clientID: client
        )
        XCTAssertTrue(start.ok, "\(start.payload)")
        let deniedPath = tempHome.appendingPathComponent("grant-denied-loop.txt")

        var softHandoffID: String?
        for count in 1...9 {
            let result = try app.tools.call(
                name: "fs_write",
                arguments: ["path": deniedPath.path, "content": "must not dispatch"],
                clientID: client
            )

            switch count {
            case 1...3, 5...8:
                XCTAssertFalse(result.ok, "call \(count)")
                XCTAssertTrue(result.isError, "call \(count)")
                XCTAssertEqual(result.payload["code"] as? String, "tool_forbidden")
                XCTAssertNil(result.payload["handoff_required"], "call \(count)")
            case 4:
                XCTAssertFalse(result.ok)
                XCTAssertTrue(result.isError)
                XCTAssertEqual(result.payload["code"] as? String, "tool_forbidden")
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                softHandoffID = result.payload["handoff_id"] as? String
                XCTAssertNotNil(softHandoffID)
                XCTAssertFalse((result.payload["resume_seed"] as? String ?? "").isEmpty)
            case 9:
                XCTAssertFalse(result.ok)
                XCTAssertTrue(result.isError)
                XCTAssertEqual(result.payload["code"] as? String, "identical_call_loop")
                XCTAssertEqual(result.payload["blocked_call_code"] as? String, "tool_forbidden")
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                XCTAssertEqual(result.payload["handoff_id"] as? String, softHandoffID)
                XCTAssertFalse((result.payload["resume_seed"] as? String ?? "").isEmpty)
            default:
                XCTFail("unexpected count")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: deniedPath.path), "call \(count) dispatched")
        }

        let handoffID = try XCTUnwrap(softHandoffID)
        let packet = try XCTUnwrap(app.store.handoffGet(id: handoffID))
        XCTAssertEqual(packet.source, .budget)
        XCTAssertTrue(packet.resumeReady)
        XCTAssertFalse(packet.resumeSeed.isEmpty)
        XCTAssertTrue(packet.narrative.contains("identical_call_loop tool=fs_write count=9"), packet.narrative)
        XCTAssertTrue(packet.narrative.contains("authorization_denial=tool_forbidden"), packet.narrative)

        let audits = try app.audit.recent(limit: 20).filter {
            $0.tool == "fs_write" && $0.clientID == client.rawValue
        }
        XCTAssertEqual(audits.filter { $0.status == "denied" }.count, 8)
        XCTAssertEqual(audits.filter { $0.status == "error" }.count, 1)
    }

    func testAuthorizationDeniedHardBudgetFailsClosedWhenPersistenceFails() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("denied-failed-loop-persistence")
        try configureAllowedProjectRoot(app)
        let start = try app.tools.call(
            name: "agent_run_start",
            arguments: [
                "agent_id": "explore",
                "goal": "Exercise denial persistence failure",
                "cwd": tempHome.path,
            ],
            clientID: client
        )
        XCTAssertTrue(start.ok, "\(start.payload)")
        let deniedPath = tempHome.appendingPathComponent("grant-denied-failed-loop.txt")
        let preexistingHandoffs = try app.store.handoffList(limit: 10)
        try withSQLiteFixture(at: app.paths.storeSQLite) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TRIGGER fail_denied_loop_handoff
                BEFORE INSERT ON context_handoffs
                BEGIN
                    SELECT RAISE(ABORT, 'forced denied loop handoff failure');
                END;
                """
            )
        }

        for count in 1...9 {
            let result = try app.tools.call(
                name: "fs_write",
                arguments: ["path": deniedPath.path, "content": "must not dispatch"],
                clientID: client
            )
            if count < 9 {
                XCTAssertFalse(result.ok, "call \(count)")
                XCTAssertEqual(result.payload["code"] as? String, "tool_forbidden")
                XCTAssertNil(result.payload["handoff_required"], "call \(count)")
            } else {
                XCTAssertFalse(result.ok)
                XCTAssertTrue(result.isError)
                XCTAssertEqual(result.payload["code"] as? String, "continuity_persistence_failed")
                XCTAssertEqual(result.payload["loop_code"] as? String, "identical_call_loop")
                XCTAssertEqual(result.payload["blocked_call_code"] as? String, "tool_forbidden")
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                XCTAssertEqual(result.payload["handoff_persisted"] as? Bool, false)
                XCTAssertNil(result.payload["handoff_id"])
                XCTAssertNil(result.payload["resume_seed"])
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: deniedPath.path), "call \(count) dispatched")
        }

        XCTAssertEqual(
            try app.store.handoffList(limit: 10),
            preexistingHandoffs,
            "failed persistence must not manufacture a resume-ready handoff"
        )
        let audits = try app.audit.recent(limit: 20).filter {
            $0.tool == "fs_write" && $0.clientID == client.rawValue
        }
        XCTAssertEqual(audits.filter { $0.status == "denied" }.count, 8)
        XCTAssertEqual(audits.filter { $0.status == "error" }.count, 1)
    }

    func testDispatchFailuresRetainTheirErrorsAtSoftThreshold() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }

        let unknownClient = ClientID("unknown-tool-soft-threshold")
        var unknownHandoffID: String?
        for count in 1...4 {
            let result = try app.tools.call(
                name: "missing_test_tool",
                arguments: ["probe": "same"],
                clientID: unknownClient
            )
            XCTAssertFalse(result.ok)
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.payload["code"] as? String, "unknown_tool")
            if count < 4 {
                XCTAssertNil(result.payload["handoff_required"], "call \(count)")
            } else {
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                unknownHandoffID = result.payload["handoff_id"] as? String
                XCTAssertNotNil(unknownHandoffID)
            }
        }

        let throwingRouter = ToolRouter(app: app, packs: [ThrowingLoopToolPack()])
        let throwingClient = ClientID("throwing-tool-soft-threshold")
        var throwingHandoffID: String?
        for count in 1...4 {
            let result = try throwingRouter.call(
                name: "throwing_test_tool",
                arguments: ["probe": "same"],
                clientID: throwingClient
            )
            XCTAssertFalse(result.ok)
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.payload["code"] as? String, "tool_exception")
            if count < 4 {
                XCTAssertNil(result.payload["handoff_required"], "call \(count)")
            } else {
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                throwingHandoffID = result.payload["handoff_id"] as? String
                XCTAssertNotNil(throwingHandoffID)
            }
        }

        for handoffID in [unknownHandoffID, throwingHandoffID].compactMap({ $0 }) {
            let packet = try XCTUnwrap(app.store.handoffGet(id: handoffID))
            XCTAssertEqual(packet.source, .budget)
            XCTAssertTrue(packet.resumeReady)
            XCTAssertFalse(packet.resumeSeed.isEmpty)
        }
    }

    func testHardBudgetBlocksWhenContinuityPersistenceFails() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        let client = ClientID("failed-loop-persistence")
        try bindProjectContext(app, clientID: client)
        let path = tempHome.appendingPathComponent("failed-loop.txt").path
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": "threshold"],
            clientID: client
        )
        try withSQLiteFixture(at: app.paths.storeSQLite) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TRIGGER fail_loop_handoff
                BEFORE INSERT ON context_handoffs
                BEGIN
                    SELECT RAISE(ABORT, 'forced loop handoff failure');
                END;
                """
            )
        }

        for count in 1...9 {
            let result = try app.tools.call(
                name: "fs_read",
                arguments: ["path": path],
                clientID: client
            )
            if count < 9 {
                XCTAssertTrue(result.ok, "call \(count)")
                continue
            }

            XCTAssertFalse(result.ok)
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.payload["code"] as? String, "continuity_persistence_failed")
            XCTAssertEqual(result.payload["loop_code"] as? String, "identical_call_loop")
            XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
            XCTAssertEqual(result.payload["handoff_persisted"] as? Bool, false)
            XCTAssertNil(result.payload["handoff_id"])
        }
        XCTAssertEqual(try app.store.handoffList(limit: 10), [])
    }

    func testBudgetFingerprintDistinguishesFractionalArguments() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        let client = ClientID("fractional-loop")
        try bindProjectContext(app, clientID: client)
        let path = tempHome.appendingPathComponent("fractional.txt").path
        _ = try app.tools.call(
            name: "fs_write",
            arguments: ["path": path, "content": "value"],
            clientID: client
        )

        for index in 0..<12 {
            let probe = index.isMultiple(of: 2) ? 1.1 : 1.9
            let result = try app.tools.call(
                name: "fs_read",
                arguments: ["path": path, "probe": probe],
                clientID: client
            )
            XCTAssertTrue(result.ok, "different fractional arguments must not form an identical-call loop")
            XCTAssertNil(result.payload["handoff_required"])
        }

        let latest = try app.continuity.get()
        // Runtime auto-checkpoint may persist progress; it must not look like a loop handoff.
        if latest["found"] as? Bool == true {
            XCTAssertEqual(latest["resume_ready"] as? Bool, false)
        }
    }

    func testAutoCheckpointDoesNotStealModelPacketIdentity() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        let modelClient = ClientID("model-author")
        let created = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "goal": "Keep the model as author",
                "status": "exploration-complete",
                "cwd": tempHome.path,
                "next_actions": ["Await user direction"],
                "narrative": "Exploration finished",
            ],
            clientID: modelClient
        )
        let handoffID = try XCTUnwrap(created.payload["handoff_id"] as? String)

        let smoke = ClientID("diagnostic-smoke")
        try bindProjectContext(app, clientID: smoke)
        for index in 0..<ContinuityAutomation.checkpointEveryTools {
            let result = try app.tools.call(
                name: "fs_write",
                arguments: [
                    "path": tempHome.appendingPathComponent("ident-\(index).txt").path,
                    "content": "n=\(index)",
                ],
                clientID: smoke
            )
            XCTAssertTrue(result.ok, "\(result.payload)")
        }

        let packet = try XCTUnwrap(app.store.handoffGet(id: handoffID))
        XCTAssertEqual(packet.source, .model)
        XCTAssertEqual(packet.clientID, modelClient.rawValue)
        XCTAssertEqual(packet.status, "exploration-complete")
        XCTAssertEqual(packet.nextActions, ["Await user direction"])
        XCTAssertEqual(packet.narrative, "Exploration finished")
        XCTAssertFalse(packet.resumeReady)
    }

    func testRuntimeAutoCheckpointPersistsWithoutModelCall() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        let client = ClientID("auto-checkpoint")
        try bindProjectContext(app, clientID: client)
        for index in 0..<ContinuityAutomation.checkpointEveryTools {
            let path = tempHome.appendingPathComponent("auto-\(index).txt").path
            let result = try app.tools.call(
                name: "fs_write",
                arguments: ["path": path, "content": "n=\(index)"],
                clientID: client
            )
            XCTAssertTrue(result.ok, "\(result.payload)")
        }
        let latest = try app.continuity.get()
        XCTAssertEqual(latest["found"] as? Bool, true)
        let packet = try XCTUnwrap(latest["payload"] as? [String: Any] ?? latest["packet"] as? [String: Any])
        let source = (packet["meta"] as? [String: Any])?["source"] as? String
        XCTAssertEqual(source, HandoffSource.auto.rawValue)
        XCTAssertEqual(latest["resume_ready"] as? Bool, false)
        let persisted = try XCTUnwrap(app.diagnostics.recent(limit: 200).last {
            $0.event == "auto_checkpoint_persist"
        })
        let observed = try XCTUnwrap(app.diagnostics.recent(limit: 200).last {
            $0.event == "auto_checkpoint"
        })
        XCTAssertEqual(persisted.fields["handoff_id"], observed.fields["handoff_id"])
        XCTAssertEqual(persisted.fields["attempt_id"], observed.fields["attempt_id"])
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(persisted.fields["attempt_id"])))
        XCTAssertEqual(persisted.fields["operation"], "checkpoint")
        XCTAssertEqual(persisted.fields["resume_ready"], "false")
        XCTAssertEqual(persisted.fields["save_outcome"], "committed")
        XCTAssertEqual(persisted.fields["successor_request_state"], "not_applicable_checkpoint")
        XCTAssertEqual(observed.fields["successor_request_state"], "not_applicable_checkpoint")
    }

    func testRuntimeContinuityCountsDurableJobToolsAndSeparatesFailedCalls() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("durable-job-progress")
        try bindProjectContext(app, clientID: client)
        let tools = ["process.run", "shell.run", "bash.run", "python.run", "powershell.run",
                     "job.status", "job.read_output", "job.list", "job.cancel",
                     "xcode.discover", "xcode.run", "xcode.result", "xcode.debug", "xcode.simulator"]
        for index in 0..<ContinuityAutomation.checkpointEveryTools {
            let tool = tools[index % tools.count]
            let observation = app.continuityAutomation.observe(
                tool: tool, arguments: ["cwd": tempHome.path], clientID: client,
                succeeded: index.isMultiple(of: 2)
            )
            if index == ContinuityAutomation.checkpointEveryTools - 1 {
                XCTAssertNotNil(observation)
                XCTAssertEqual(observation?.finalize, false)
            } else {
                XCTAssertNil(observation)
            }
        }
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 25)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["failed_tool_count"] as? Int, 25)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["tool_call_count"] as? Int, 50)
    }

    func testRuntimeContinuityProgressSurvivesHelpersAndCombinesDeploymentRoles() throws {
        let primary = try ForgeApp.bootstrap(home: tempHome)
        defer { primary.shutdown() }
        let primaryClient = MCPServer.defaultClientID(
            deploymentID: "durable-continuity-deployment", role: .primary,
            desktopProviderID: nil
        )
        let fallbackClient = MCPServer.defaultClientID(
            deploymentID: "durable-continuity-deployment", role: .fallback,
            desktopProviderID: nil
        )
        XCTAssertEqual(primaryClient, fallbackClient)
        try bindProjectContext(primary, clientID: primaryClient)
        for index in 0..<25 {
            XCTAssertNil(primary.continuityAutomation.observe(
                tool: "fs_read", arguments: ["path": tempHome.appendingPathComponent("read-\(index)").path],
                clientID: primaryClient, succeeded: true
            ))
        }

        let fallback = try ForgeApp.bootstrap(home: tempHome)
        defer { fallback.shutdown() }
        XCTAssertEqual(fallback.continuityAutomation.snapshot(for: fallbackClient)["progress_count"] as? Int, 25)
        var last: ContinuityObservation?
        for index in 25..<50 {
            last = fallback.continuityAutomation.observe(
                tool: "fs_read", arguments: ["path": tempHome.appendingPathComponent("read-\(index)").path],
                clientID: fallbackClient, succeeded: true
            )
        }
        XCTAssertEqual(last?.finalize, false)
        XCTAssertEqual(primary.continuityAutomation.snapshot(for: primaryClient)["progress_count"] as? Int, 50)

        let restarted = try ForgeApp.bootstrap(home: tempHome)
        defer { restarted.shutdown() }
        XCTAssertEqual(restarted.continuityAutomation.snapshot(for: primaryClient)["progress_count"] as? Int, 50)
    }

    func testRuntimeContinuityFirstElapsedCheckpointAndHandoffStartAtFirstProgress() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let app = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { app.shutdown() }
        let client = ClientID("first-elapsed-continuity")
        try bindProjectContext(app, clientID: client)
        XCTAssertNil(app.continuityAutomation.observe(
            tool: "git_status", arguments: ["cwd": tempHome.path], clientID: client,
            succeeded: true
        ))
        clock.date = clock.date.addingTimeInterval(ContinuityAutomation.checkpointIntervalSec)
        let checkpoint = app.continuityAutomation.observe(
            tool: "git_status", arguments: ["cwd": tempHome.path], clientID: client,
            succeeded: true
        )
        XCTAssertEqual(checkpoint?.finalize, false)
        clock.date = Date(timeIntervalSince1970: 1_000 + ContinuityAutomation.handoffIntervalSec)
        let handoff = app.continuityAutomation.observe(
            tool: "git_status", arguments: ["cwd": tempHome.path], clientID: client,
            succeeded: true
        )
        XCTAssertEqual(handoff?.finalize, true)
        XCTAssertTrue(app.continuityAutomation.isBlocked(client))
    }

    func testRuntimeContinuityProgressDoesNotFollowClientIntoAnotherProject() async throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("project-isolated-continuity")
        let firstRoot = tempHome.appendingPathComponent("first-project", isDirectory: true)
        let secondRoot = tempHome.appendingPathComponent("second-project", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        try bindProjectContext(app, clientID: client, root: firstRoot)
        for _ in 0..<49 {
            XCTAssertNil(app.continuityAutomation.observe(
                tool: "fs_read", arguments: ["path": firstRoot.path], clientID: client,
                succeeded: true
            ))
        }
        let first = try app.projectContexts.invocationContext(for: client)
        _ = try await app.projectContexts.repository.archiveProject(projectID: first.projectID, expectedGeneration: first.projectGeneration)
        try bindProjectContext(app, clientID: client, root: secondRoot)
        XCTAssertNil(app.continuityAutomation.observe(
            tool: "fs_read", arguments: ["path": secondRoot.path], clientID: client,
            succeeded: true
        ))
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 1)
        let oldProgress = try app.store.runtimeContinuityProgress(scopeKey: app.continuityAutomation.runtimeScopeKey(first))
        XCTAssertEqual(oldProgress?.progressCount, 49)
        let second = try app.projectContexts.invocationContext(for: client)
        _ = try await app.projectContexts.repository.archiveProject(projectID: second.projectID, expectedGeneration: second.projectGeneration)
        _ = try ManagerNode(app: app).registerProject(path: firstRoot.path)
        try bindProjectContext(app, clientID: client, root: firstRoot)
        let reactivated = try app.projectContexts.invocationContext(for: client)
        XCTAssertEqual(reactivated.projectID, first.projectID)
        XCTAssertGreaterThan(reactivated.projectGeneration.rawValue, first.projectGeneration.rawValue)
        XCTAssertNotEqual(app.continuityAutomation.runtimeScopeKey(reactivated), app.continuityAutomation.runtimeScopeKey(first))
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 0)
        XCTAssertEqual(try app.store.runtimeContinuityProgress(scopeKey: app.continuityAutomation.runtimeScopeKey(first))?.progressCount, 49)
    }

    func testRuntimeContinuityLoopHandoffDoesNotCrossProjectBindingTransition() async throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        let client = MCPServer.defaultClientID(
            deploymentID: "loop-project-transition", role: .primary, desktopProviderID: nil
        )
        let firstRoot = tempHome.appendingPathComponent("loop-first-project", isDirectory: true)
        let secondRoot = tempHome.appendingPathComponent("loop-second-project", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        try bindProjectContext(app, clientID: client, root: firstRoot)
        let firstContext = try app.projectContexts.invocationContext(for: client)
        let firstScope = app.continuityAutomation.runtimeScopeKey(firstContext)
        let savedFirst = try app.tools.call(name: "session_handoff", arguments: [
            "goal": "Preserve the first project's completed handoff",
            "cwd": firstRoot.path,
            "next_actions": ["Continue only the first project's work"],
            "narrative": "First-project history must remain intact",
        ], clientID: client)
        XCTAssertTrue(savedFirst.ok, "\(savedFirst.payload)")
        let firstPacketID = try XCTUnwrap(savedFirst.payload["handoff_id"] as? String)
        let canonicalFirst = try XCTUnwrap(app.store.handoffLegacyGet(id: firstPacketID))
        XCTAssertEqual(try app.store.runtimeContinuityPacketScopeKey(packetID: firstPacketID), firstScope)

        // Archiving is the supported generation-fenced transition: it invalidates
        // the prior binding before this same deployment client selects B.
        _ = try await app.projectContexts.repository.archiveProject(
            projectID: firstContext.projectID, expectedGeneration: firstContext.projectGeneration
        )
        try bindProjectContext(app, clientID: client, root: secondRoot)
        let secondContext = try app.projectContexts.invocationContext(for: client)
        let secondScope = app.continuityAutomation.runtimeScopeKey(secondContext)
        XCTAssertNotEqual(secondContext.projectID, firstContext.projectID)
        XCTAssertNotEqual(secondScope, firstScope)
        let path = secondRoot.appendingPathComponent("loop-owned.txt")
        try "Second-project owned evidence\n".write(to: path, atomically: true, encoding: .utf8)

        var softPacketID: String?
        var hardPacketID: String?
        for count in 1...9 {
            let result = try app.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: client)
            if count <= 8 {
                XCTAssertTrue(result.ok, "call \(count): \(result.payload)")
                XCTAssertFalse(result.isError, "call \(count)")
                if count == 4 {
                    XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                    softPacketID = try XCTUnwrap(result.payload["handoff_id"] as? String)
                    XCTAssertNotEqual(softPacketID, firstPacketID)
                    let packet = try XCTUnwrap(app.store.handoffLegacyGet(id: try XCTUnwrap(softPacketID)))
                    XCTAssertEqual(packet.cwd, secondRoot.path)
                    XCTAssertEqual(try app.store.runtimeContinuityPacketScopeKey(packetID: packet.id), secondScope)
                    XCTAssertEqual(try app.store.handoffLegacyGet(id: firstPacketID), canonicalFirst)
                } else {
                    XCTAssertNil(result.payload["handoff_required"], "call \(count)")
                }
            } else {
                XCTAssertFalse(result.ok)
                XCTAssertTrue(result.isError)
                XCTAssertEqual(result.payload["code"] as? String, "identical_call_loop")
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                hardPacketID = try XCTUnwrap(result.payload["handoff_id"] as? String)
                XCTAssertEqual(hardPacketID, softPacketID)
                XCTAssertNotEqual(hardPacketID, firstPacketID)
                let packet = try XCTUnwrap(app.store.handoffLegacyGet(id: try XCTUnwrap(hardPacketID)))
                XCTAssertEqual(packet.cwd, secondRoot.path)
                XCTAssertEqual(try app.store.runtimeContinuityPacketScopeKey(packetID: packet.id), secondScope)
                XCTAssertEqual(try app.store.handoffLegacyGet(id: firstPacketID), canonicalFirst)
            }
        }
        XCTAssertTrue(app.continuityAutomation.isBlocked(client))
        let packetID = try XCTUnwrap(hardPacketID)
        let resumed = try app.tools.call(name: "get_forge_status", arguments: [
            "resume": true, "handoff_id": packetID,
            "rollover_nonce": ContextContinuityService.interactiveRolloverNonce(handoffID: packetID),
        ], clientID: client)
        XCTAssertTrue(resumed.ok, "\(resumed.payload)")
        XCTAssertEqual(resumed.payload["context_budget_cleared"] as? Bool, true)
        XCTAssertFalse(app.continuityAutomation.isBlocked(client))
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["tool_call_count"] as? Int, 0)
        let continued = try app.tools.call(name: "fs_list", arguments: ["path": secondRoot.path], clientID: client)
        XCTAssertTrue(continued.ok, "\(continued.payload)")
        XCTAssertEqual(try app.store.handoffLegacyGet(id: firstPacketID), canonicalFirst)
        XCTAssertEqual(try app.store.runtimeContinuityPacketScopeKey(packetID: firstPacketID), firstScope)
    }

    func testRuntimeContinuityFailedToolBudgetSavesAndBlocksWithoutInventingSuccess() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("failed-runtime-progress")
        try bindProjectContext(app, clientID: client)
        var checkpoints = 0
        var final: ContinuityObservation?
        for index in 0..<ContinuityAutomation.handoffEveryFailedTools {
            let observed = app.continuityAutomation.observe(
                tool: "shell_exec", arguments: ["cwd": tempHome.path, "command": "failing command \(index)"],
                clientID: client, succeeded: false
            )
            if observed?.finalize == false { checkpoints += 1 }
            if observed?.finalize == true { final = observed }
        }
        XCTAssertEqual(checkpoints, 3)
        XCTAssertEqual(final?.finalize, true)
        let snapshot = app.continuityAutomation.snapshot(for: client)
        XCTAssertEqual(snapshot["progress_count"] as? Int, 0)
        XCTAssertEqual(snapshot["failed_tool_count"] as? Int, 200)
        XCTAssertEqual(snapshot["blocked"] as? Bool, true)
        XCTAssertEqual(snapshot["external_context_usage"] as? String, "unavailable")
        XCTAssertEqual(snapshot["session_identity_source"] as? String, "forge_logical_epoch")
        let restored = try ForgeApp.bootstrap(home: tempHome)
        defer { restored.shutdown() }
        XCTAssertTrue(restored.continuityAutomation.isBlocked(client))
        XCTAssertEqual(restored.continuityAutomation.blockState(client).handoffID, final?.packet.id)
    }

    func testRuntimeContinuityLoopBudgetPointerAndBlockSurviveRestart() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        let client = ClientID("durable-loop-budget")
        try bindProjectContext(app, clientID: client)
        let context = try app.projectContexts.invocationContext(for: client)
        let scope = app.continuityAutomation.runtimeScopeKey(context)
        let path = tempHome.appendingPathComponent("durable-loop-read.txt")
        try "Durable loop evidence".write(to: path, atomically: true, encoding: .utf8)
        var packetID: String?
        for count in 1...9 {
            let result = try app.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: client)
            if count == 4 {
                packetID = try XCTUnwrap(result.payload["handoff_id"] as? String)
                XCTAssertFalse(app.continuityAutomation.isBlocked(client))
            } else if count == 9 {
                XCTAssertEqual(result.payload["code"] as? String, "identical_call_loop")
                XCTAssertEqual(result.payload["handoff_id"] as? String, packetID)
            } else { XCTAssertTrue(result.ok, "\(result.payload)") }
        }
        let exactID = try XCTUnwrap(packetID)
        let progress = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: scope))
        XCTAssertTrue(progress.blocked)
        XCTAssertEqual(progress.latestPacketID, exactID)
        XCTAssertEqual(progress.lastHandoffID, exactID)
        XCTAssertEqual(try app.store.runtimeContinuityPacketScopeKey(packetID: exactID), scope)
        let canonical = try XCTUnwrap(app.store.handoffLegacyGet(id: exactID))
        app.shutdown()
        let restarted = try ForgeApp.bootstrap(home: tempHome)
        defer { restarted.shutdown() }
        XCTAssertTrue(restarted.continuityAutomation.isBlocked(client))
        XCTAssertEqual(try restarted.store.runtimeContinuityProgress(scopeKey: scope)?.epoch, progress.epoch)
        let resumed = try restarted.tools.call(name: "get_forge_status", arguments: [
            "resume": true, "handoff_id": exactID,
            "rollover_nonce": ContextContinuityService.interactiveRolloverNonce(handoffID: exactID),
        ], clientID: client)
        XCTAssertTrue(resumed.ok, "\(resumed.payload)")
        XCTAssertEqual(resumed.payload["context_budget_cleared"] as? Bool, true)
        XCTAssertFalse(restarted.continuityAutomation.isBlocked(client))
        XCTAssertNotEqual(try restarted.store.runtimeContinuityProgress(scopeKey: scope)?.epoch, progress.epoch)
        XCTAssertEqual(try restarted.store.handoffLegacyGet(id: exactID), canonical)
    }

    func testRuntimeContinuityLoopBudgetFailureCancellationAndStaleEpochPreserveAtomicState() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("loop-budget-atomic-state")
        try bindProjectContext(app, clientID: client)
        let context = try app.projectContexts.invocationContext(for: client)
        let scope = app.continuityAutomation.runtimeScopeKey(context)
        let saved = try app.tools.call(name: "session_handoff", arguments: [
            "goal": "Preserve model-authored work", "next_actions": ["Finish the exact task"],
        ], clientID: client)
        let modelID = try XCTUnwrap(saved.payload["handoff_id"] as? String)
        let model = try XCTUnwrap(app.store.handoffLegacyGet(id: modelID))
        XCTAssertTrue(model.resumeReady, "Finalized model history must be cloned, while an open checkpoint keeps its identity")
        let soft = try app.continuityAutomation.budgetAutoCheckpoint(
            clientID: client, reason: "soft budget fixture", cancellation: nil
        )
        let canonicalSoft = try XCTUnwrap(app.store.handoffLegacyGet(id: soft.id))
        XCTAssertNotEqual(soft.id, modelID)
        XCTAssertEqual(soft.goal, model.goal)
        XCTAssertEqual(soft.nextActions, model.nextActions)
        XCTAssertEqual(try app.store.handoffLegacyGet(id: modelID), model)
        let prior = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: scope))
        XCTAssertFalse(prior.blocked)
        XCTAssertEqual(prior.latestPacketID, soft.id)

        let cancelled = ToolCallCancellation(timeoutSeconds: 5)
        cancelled.cancel()
        XCTAssertThrowsError(try app.continuityAutomation.budgetAutoCheckpoint(
            clientID: client, reason: "cancelled hard budget", blockProgress: true, cancellation: cancelled
        )) { XCTAssertTrue($0 is CancellationError) }
        try withSQLiteFixture(at: app.paths.storeSQLite) { database in
            try executeSQLiteFixture(database, sql: """
                CREATE TRIGGER fail_loop_budget_pointer BEFORE UPDATE ON runtime_continuity_progress
                WHEN OLD.scope_key='\(scope)'
                BEGIN SELECT RAISE(ABORT, 'forced loop budget pointer failure'); END;
                """)
        }
        XCTAssertThrowsError(try app.continuityAutomation.budgetAutoCheckpoint(
            clientID: client, reason: "failed hard budget", blockProgress: true, cancellation: nil
        ))
        XCTAssertEqual(try app.store.handoffLegacyGet(id: soft.id), canonicalSoft)
        XCTAssertEqual(try app.store.handoffLegacyGet(id: modelID), model)
        XCTAssertEqual(try app.store.runtimeContinuityProgress(scopeKey: scope)?.latestPacketID, prior.latestPacketID)
        XCTAssertEqual(try app.store.runtimeContinuityProgress(scopeKey: scope)?.epoch, prior.epoch)
        XCTAssertFalse(app.continuityAutomation.isBlocked(client))
        try withSQLiteFixture(at: app.paths.storeSQLite) { database in
            try executeSQLiteFixture(database, sql: "DROP TRIGGER fail_loop_budget_pointer;")
        }
        XCTAssertTrue(try app.continuityAutomation.clearBlockReportingResult(clientID: client, packet: soft, cancellation: nil))
        var stale = soft
        stale.narrative = "A predecessor's in-flight hard save must not overwrite the successor"
        XCTAssertThrowsError(try app.store.handoffUpsertRecordingRuntimeProgress(
            stale, scopeKey: scope, blockProgress: true, expectedEpoch: prior.epoch
        ))
        XCTAssertEqual(try app.store.handoffLegacyGet(id: soft.id), canonicalSoft)
        XCTAssertFalse(app.continuityAutomation.isBlocked(client))
        XCTAssertNotEqual(try app.store.runtimeContinuityProgress(scopeKey: scope)?.epoch, prior.epoch)
    }

    func testRuntimeContinuityConcurrentLoopBudgetSavesShareOneCurrentPacket() throws {
        let first = try ForgeApp.bootstrap(home: tempHome)
        defer { first.shutdown() }
        let client = ClientID("concurrent-loop-budget")
        try bindProjectContext(first, clientID: client)
        let second = try ForgeApp.bootstrap(home: tempHome)
        defer { second.shutdown() }
        let identifiers = LockedFailureMessages()
        let failures = LockedFailureMessages()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                let owner = index == 0 ? first : second
                let packet = try owner.continuityAutomation.budgetAutoCheckpoint(
                    clientID: client, reason: "concurrent soft budget \(index)", cancellation: nil
                )
                identifiers.append(packet.id)
            } catch { failures.append(String(describing: error)) }
        }
        XCTAssertEqual(failures.snapshot, [])
        XCTAssertEqual(identifiers.snapshot.count, 2)
        XCTAssertEqual(Set(identifiers.snapshot).count, 1)
        let exactID = try XCTUnwrap(identifiers.snapshot.first)
        let scope = first.continuityAutomation.runtimeScopeKey(try first.projectContexts.invocationContext(for: client))
        XCTAssertEqual(try first.store.runtimeContinuityProgress(scopeKey: scope)?.latestPacketID, exactID)
        XCTAssertFalse(first.continuityAutomation.isBlocked(client))
        XCTAssertEqual(try first.store.handoffLegacyList(limit: 10).count, 1)
        let hard = try second.continuityAutomation.budgetAutoCheckpoint(
            clientID: client, reason: "concurrent-owner hard budget", blockProgress: true, cancellation: nil
        )
        XCTAssertEqual(hard.id, exactID)
        XCTAssertTrue(first.continuityAutomation.isBlocked(client))
    }

    func testRuntimeContinuityLoopBudgetCapacityFailurePreservesHistoryAndDoesNotInventBlock() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        let client = ClientID("loop-budget-capacity")
        try bindProjectContext(app, clientID: client)
        let scope = app.continuityAutomation.runtimeScopeKey(try app.projectContexts.invocationContext(for: client))
        let historicalScope = JSONSupport.sha256Hex("retained loop-budget historical scope")
        let historical = HandoffPacket(source: .model, resumeReady: true, goal: "Retain exact historical evidence", cwd: tempHome.path)
        try app.store.handoffUpsertRecordingRuntimeProgress(historical, scopeKey: historicalScope)
        let canonical = try XCTUnwrap(app.store.handoffLegacyGet(id: historical.id))
        try withSQLiteFixture(at: app.paths.storeSQLite) { database in
            try executeSQLiteFixture(database, sql: """
                WITH RECURSIVE copies(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM copies WHERE n<9999)
                INSERT INTO context_handoffs(id,created_at,updated_at,source,resume_ready,packet_json,client_id,write_sequence,runtime_scope_key)
                SELECT printf('%08x-0000-4000-8000-000000000000',n),created_at,updated_at,source,resume_ready,
                       replace(packet_json,id,printf('%08x-0000-4000-8000-000000000000',n)),client_id,n+1,runtime_scope_key
                FROM context_handoffs,copies WHERE id='\(historical.id)';
                """)
        }
        let path = tempHome.appendingPathComponent("capacity-loop-read.txt")
        try "Capacity-limited owned evidence".write(to: path, atomically: true, encoding: .utf8)
        for count in 1...9 {
            let result = try app.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: client)
            XCTAssertNil(result.payload["handoff_id"], "call \(count)")
            if count <= 8 {
                XCTAssertTrue(result.ok, "call \(count): \(result.payload)")
                if count >= 4 {
                    let attention = try XCTUnwrap(result.payload["continuity_attention"] as? [String: Any])
                    XCTAssertEqual(attention["code"] as? String, "continuity_capacity_reached")
                    XCTAssertEqual(attention["handoff_persisted"] as? Bool, false)
                }
            } else {
                XCTAssertFalse(result.ok)
                XCTAssertTrue(result.isError)
                XCTAssertEqual(result.payload["code"] as? String, "continuity_persistence_failed")
                XCTAssertEqual(result.payload["loop_code"] as? String, "identical_call_loop")
                XCTAssertEqual(result.payload["handoff_persisted"] as? Bool, false)
            }
            XCTAssertFalse(app.continuityAutomation.isBlocked(client), "call \(count)")
        }
        XCTAssertEqual(try app.store.handoffLegacyGet(id: historical.id), canonical)
        XCTAssertEqual(try app.store.runtimeContinuityPacketScopeKey(packetID: historical.id), historicalScope)
        XCTAssertNil(try app.store.runtimeContinuityProgress(scopeKey: scope)?.latestPacketID)
        XCTAssertEqual(try app.store.runtimeContinuityProgress(scopeKey: scope)?.progressCount, 8)
        XCTAssertEqual(try sqliteFixtureInt(at: app.paths.storeSQLite, sql: "SELECT COUNT(*) FROM context_handoffs WHERE runtime_scope_key IS NOT NULL;"), 10_000)
    }

    func testRuntimeContinuityStatusMetadataViewsMatchConfiguredThreshold() throws {
        for limit in [1, 3, 251, 10_000] {
            let home = tempHome.appendingPathComponent("status-threshold-\(limit)", isDirectory: true)
            let app = try ForgeApp.bootstrap(home: home)
            defer { app.shutdown() }
            let client = ClientID("metadata-threshold-\(limit)")
            try bindProjectContext(app, clientID: client, root: home)
            _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: limit))
            let response = try app.tools.call(name: "get_forge_status", arguments: [:], clientID: client)
            XCTAssertTrue(response.ok, "\(response.payload)")
            let current = try XCTUnwrap(response.payload["auto_continuity"] as? [String: Any])
            let continuity = try XCTUnwrap(response.payload["continuity"] as? [String: Any])
            let legacy = try XCTUnwrap(continuity["auto"] as? [String: Any])
            for snapshot in [current, legacy] {
                XCTAssertEqual(snapshot["handoff_every_tools"] as? Int, limit)
                XCTAssertEqual(snapshot["checkpoint_every_tools"] as? Int, min(50, limit))
            }
        }
    }

    func testRuntimeContinuityGenerationDeploymentAndLogicalEpochRemainIsolated() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let firstClient = MCPServer.defaultClientID(deploymentID: "first-deployment", role: .primary, desktopProviderID: nil)
        let secondClient = MCPServer.defaultClientID(deploymentID: "second-deployment", role: .primary, desktopProviderID: nil)
        try bindProjectContext(app, clientID: firstClient)
        try bindProjectContext(app, clientID: secondClient)
        _ = app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": tempHome.path], clientID: firstClient, succeeded: true)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: firstClient)["progress_count"] as? Int, 1)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: secondClient)["progress_count"] as? Int, 0)
        let originalEpoch = try XCTUnwrap(app.continuityAutomation.snapshot(for: firstClient)["continuity_epoch"] as? String)
        try app.continuityAutomation.clearBlock(clientID: firstClient, cancellation: nil)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: firstClient)["progress_count"] as? Int, 0)
        XCTAssertNotEqual(app.continuityAutomation.snapshot(for: firstClient)["continuity_epoch"] as? String, originalEpoch)

        _ = app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": tempHome.path], clientID: firstClient, succeeded: true)
        let prior = try app.projectContexts.invocationContext(for: firstClient)
        _ = try app.projectContexts.beginReset(projectID: prior.projectID, expectedGeneration: prior.projectGeneration)
        _ = try app.projectContexts.completeReset(projectID: prior.projectID, expectedGeneration: prior.projectGeneration)
        try bindProjectContext(app, clientID: firstClient)
        let current = try app.projectContexts.invocationContext(for: firstClient)
        XCTAssertNotEqual(current.projectGeneration, prior.projectGeneration)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: firstClient)["progress_count"] as? Int, 0)
        let oldProgress = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: app.continuityAutomation.runtimeScopeKey(prior)))
        XCTAssertEqual(oldProgress.progressCount, 1)
    }

    func testRuntimeContinuityExpiredClaimRecoversExactPacketWithoutDuplicate() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let app = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { app.shutdown() }
        let client = ClientID("expired-claim-progress")
        try bindProjectContext(app, clientID: client)
        let context = try app.projectContexts.invocationContext(for: client)
        let key = app.continuityAutomation.runtimeScopeKey(context)
        let packetID = UUID().uuidString.lowercased()
        _ = try app.store.updateRuntimeContinuityProgress(scopeKey: key) { progress in
            progress.progressCount = 50
            progress.startedAt = clock.now()
            progress.pending = RuntimeContinuityProgressClaim(
                scopeKey: key, epoch: progress.epoch, packetID: packetID,
                ownerID: UUID().uuidString, finalize: false, progressCount: 50, failureCount: 0,
                claimedAt: clock.now(), expiresAt: clock.now().addingTimeInterval(30)
            )
        }
        XCTAssertNil(app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": tempHome.path], clientID: client, succeeded: true))
        XCTAssertNil(try app.store.handoffGet(id: packetID))
        clock.date = clock.date.addingTimeInterval(31)
        let recovered = app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": tempHome.path], clientID: client, succeeded: true)
        XCTAssertEqual(recovered?.packet.id, packetID)
        let progress = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: key))
        XCTAssertNil(progress.pending)
        XCTAssertEqual(progress.progressCount, 52)
        XCTAssertEqual(progress.lastCheckpointCount, 50)
        XCTAssertNil(app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": tempHome.path], clientID: client, succeeded: true))
        XCTAssertEqual(try app.store.handoffList(limit: 20).filter { $0.id == packetID }.count, 1)
    }

    func testRuntimeContinuityPacketAndProgressRollBackTogetherAndRecoverAfterReopen() throws {
        let key = JSONSupport.sha256Hex("atomic-runtime-scope")
        let path = tempHome.appendingPathComponent("atomic-progress.sqlite")
        let fault = try SQLiteStore(path: path, postMigrationCommitObserver: nil, beforeMutationCommitObserver: { kind in
            if kind == .handoff { throw StoreError.execFailed("injected handoff interruption") }
        })
        let created = try fault.updateRuntimeContinuityProgress(scopeKey: key) { progress in progress.progressCount = 200 }
        let claim = RuntimeContinuityProgressClaim(
            scopeKey: key, epoch: created.epoch, packetID: UUID().uuidString.lowercased(),
            ownerID: UUID().uuidString, finalize: true, progressCount: 200, failureCount: 0,
            claimedAt: Date(), expiresAt: Date().addingTimeInterval(30)
        )
        _ = try fault.updateRuntimeContinuityProgress(scopeKey: key) { progress in progress.pending = claim }
        let packet = HandoffPacket(id: claim.packetID, source: .auto, resumeReady: true, goal: "Exact retained intent", cwd: tempHome.path)
        XCTAssertThrowsError(try fault.handoffUpsertCompletingRuntimeProgress(packet, claim: claim))
        XCTAssertNil(try fault.handoffGet(id: packet.id))
        let retained = try XCTUnwrap(fault.runtimeContinuityProgress(scopeKey: key))
        XCTAssertFalse(retained.blocked)
        XCTAssertEqual(retained.pending, claim)
        fault.close()

        let recovered = try SQLiteStore(path: path)
        defer { recovered.close() }
        try recovered.handoffUpsertCompletingRuntimeProgress(packet, claim: claim)
        XCTAssertEqual(try recovered.handoffGet(id: packet.id)?.goal, "Exact retained intent")
        let committed = try XCTUnwrap(recovered.runtimeContinuityProgress(scopeKey: key))
        XCTAssertTrue(committed.blocked)
        XCTAssertNil(committed.pending)
        XCTAssertEqual(committed.lastHandoffID, packet.id)
        XCTAssertThrowsError(try recovered.handoffUpsertCompletingRuntimeProgress(packet, claim: claim))
    }

    func testRuntimeContinuityDoesNotMergeAnotherProjectPacketOrClearForIt() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let firstRoot = tempHome.appendingPathComponent("original-packet-project", isDirectory: true)
        let secondRoot = tempHome.appendingPathComponent("runtime-packet-project", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let original = HandoffPacket(goal: "Private original mission", cwd: firstRoot.path, nextActions: ["Private original next action"])
        try app.store.handoffUpsert(original)
        let originalJSON = try sqliteFixtureText(at: app.paths.storeSQLite, sql: "SELECT packet_json FROM context_handoffs WHERE id='\(original.id)';")
        let client = ClientID("other-project-runtime-packet")
        try bindProjectContext(app, clientID: client, root: secondRoot)
        var handoff: ContinuityObservation?
        for _ in 0..<ContinuityAutomation.handoffEveryTools {
            handoff = app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": secondRoot.path], clientID: client, succeeded: true)
        }
        let saved = try XCTUnwrap(handoff?.packet)
        XCTAssertNotEqual(saved.id, original.id)
        XCTAssertEqual(saved.cwd, secondRoot.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertNotEqual(saved.goal, original.goal)
        XCTAssertEqual(try sqliteFixtureText(at: app.paths.storeSQLite, sql: "SELECT packet_json FROM context_handoffs WHERE id='\(original.id)';"), originalJSON)
        let epoch = app.continuityAutomation.snapshot(for: client)["continuity_epoch"] as? String
        try app.continuityAutomation.clearBlock(clientID: client, packet: original, cancellation: nil)
        XCTAssertTrue(app.continuityAutomation.isBlocked(client))
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["continuity_epoch"] as? String, epoch)
        try app.continuityAutomation.clearBlock(clientID: client, packet: saved, cancellation: nil)
        XCTAssertFalse(app.continuityAutomation.isBlocked(client))
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 0)
    }

    func testRuntimeContinuityForeignContextGetDoesNotReportBudgetCleared() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let firstRoot = tempHome.appendingPathComponent("foreign-context", isDirectory: true)
        let selectedRoot = tempHome.appendingPathComponent("selected-context", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        let foreign = HandoffPacket(goal: "Foreign packet", cwd: firstRoot.path)
        try app.store.handoffUpsert(foreign)
        let client = ClientID("foreign-context-budget")
        try bindProjectContext(app, clientID: client, root: selectedRoot)
        var handoff: ContinuityObservation?
        for _ in 0..<ContinuityAutomation.handoffEveryTools {
            handoff = app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": selectedRoot.path], clientID: client, succeeded: true)
        }
        let saved = try XCTUnwrap(handoff?.packet)
        let refused = try app.tools.call(name: "context_get", arguments: ["handoff_id": foreign.id], clientID: client)
        XCTAssertEqual(refused.payload["context_budget_cleared"] as? Bool, false)
        XCTAssertTrue(app.continuityAutomation.isBlocked(client))
        let accepted = try app.tools.call(name: "context_get", arguments: ["handoff_id": saved.id], clientID: client)
        XCTAssertEqual(accepted.payload["context_budget_cleared"] as? Bool, true)
        XCTAssertFalse(app.continuityAutomation.isBlocked(client))
    }

    func testRuntimeContinuityV8MigrationPreservesPacketsMemoryAndVerifiedBackup() throws {
        let path = tempHome.appendingPathComponent("runtime-migration.sqlite")
        let baseline = try SQLiteStore(path: path)
        let packet = HandoffPacket(source: .model, resumeReady: true, goal: "Preserve pre-migration work", cwd: tempHome.path)
        try baseline.handoffUpsert(packet)
        let originalJSON = try sqliteFixtureText(at: path, sql: "SELECT packet_json FROM context_handoffs WHERE id='\(packet.id)';")
        try baseline.memorySet(key: "existing/private", body: "Preserved memory", tags: ["existing"])
        baseline.close()
        // Version 8 has the same legacy tables and no runtime progress table.
        try withSQLiteFixture(at: path) { database in
            try executeSQLiteFixture(database, sql: "DROP TABLE runtime_continuity_progress; DROP INDEX idx_context_handoffs_interactive_pending_scope; DROP INDEX idx_context_handoffs_runtime_scope; ALTER TABLE context_handoffs DROP COLUMN interactive_sealed_sequence; ALTER TABLE context_handoffs DROP COLUMN runtime_scope_key; UPDATE schema_version SET version=8;")
        }
        let migrated = try SQLiteStore(path: path)
        defer { migrated.close() }
        XCTAssertEqual(try sqliteFixtureText(at: path, sql: "SELECT packet_json FROM context_handoffs WHERE id='\(packet.id)';"), originalJSON)
        XCTAssertEqual(try migrated.memoryGet(key: "existing/private"), "Preserved memory")
        XCTAssertNil(try migrated.runtimeContinuityPacketScopeKey(packetID: packet.id))
        XCTAssertEqual(try sqliteFixtureInt(at: path, sql: "SELECT version FROM schema_version;"), 9)
        let state = try migrated.updateRuntimeContinuityProgress(scopeKey: JSONSupport.sha256Hex("new migrated scope")) { $0.progressCount = 1 }
        XCTAssertEqual(state.progressCount, 1)
        let backup = tempHome.appendingPathComponent("runtime-migration.pre-migration-v8.sqlite3")
        XCTAssertEqual(try sqliteFixtureInt(at: backup, sql: "SELECT version FROM schema_version;"), 8)
        XCTAssertEqual(try sqliteFixtureInt(at: backup, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name='runtime_continuity_progress';"), 0)
        XCTAssertEqual(try sqliteFixtureInt(at: backup, sql: "SELECT COUNT(*) FROM pragma_table_info('context_handoffs') WHERE name='runtime_scope_key';"), 0)
        XCTAssertEqual(try sqliteFixtureInt(at: backup, sql: "SELECT COUNT(*) FROM pragma_table_info('context_handoffs') WHERE name='interactive_sealed_sequence';"), 0)
        XCTAssertEqual(try sqliteFixtureInt(at: backup, sql: "SELECT COUNT(*) FROM context_handoffs;"), 1)
        XCTAssertEqual(try sqliteFixtureText(at: backup, sql: "PRAGMA quick_check;"), "ok")
        let manifest = try JSONDecoder().decode(VerifiedMigrationBackupManifest.self, from: Data(contentsOf: VerifiedMigrationBackup.activeManifestURL(for: path)))
        XCTAssertEqual(manifest.state, .completed)
        XCTAssertEqual(manifest.sourceVersion, 8)
        XCTAssertEqual(manifest.targetVersion, 9)
        XCTAssertEqual(manifest.backupSHA256, JSONSupport.sha256Hex(try Data(contentsOf: backup)))
    }

    func testRuntimeContinuityCheckpointAndOldGenerationReadsDoNotResetCurrentBudget() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_000))
        let app = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { app.shutdown() }
        let client = ClientID("read-preserves-runtime-budget")
        try bindProjectContext(app, clientID: client)
        let checkpoint = try app.tools.call(name: "session_checkpoint", arguments: ["goal": "Keep current work"], clientID: client)
        let checkpointID = try XCTUnwrap(checkpoint.payload["handoff_id"] as? String)
        for _ in 0..<25 {
            _ = app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": tempHome.path], clientID: client, succeeded: true)
        }
        let oldEpoch = app.continuityAutomation.snapshot(for: client)["continuity_epoch"] as? String
        let read = try app.tools.call(name: "context_get", arguments: ["handoff_id": checkpointID], clientID: client)
        XCTAssertEqual(read.payload["context_budget_cleared"] as? Bool, false)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 25)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["continuity_epoch"] as? String, oldEpoch)
        let prior = try app.projectContexts.invocationContext(for: client)
        _ = try app.projectContexts.beginReset(projectID: prior.projectID, expectedGeneration: prior.projectGeneration)
        _ = try app.projectContexts.completeReset(projectID: prior.projectID, expectedGeneration: prior.projectGeneration)
        try bindProjectContext(app, clientID: client)
        _ = app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": tempHome.path], clientID: client, succeeded: true)
        let newEpoch = app.continuityAutomation.snapshot(for: client)["continuity_epoch"] as? String
        let oldRead = try app.tools.call(name: "context_get", arguments: ["handoff_id": checkpointID], clientID: client)
        XCTAssertEqual(oldRead.payload["context_budget_cleared"] as? Bool, false)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 1)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["continuity_epoch"] as? String, newEpoch)
        clock.date = clock.date.addingTimeInterval(ContinuityAutomation.checkpointIntervalSec)
        XCTAssertEqual(app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": tempHome.path], clientID: client, succeeded: true)?.finalize, false)
    }

    func testRuntimeContinuityModelTaskSurvivesAutomaticCheckpointHandoffAndResume() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("structured-runtime-task")
        try bindProjectContext(app, clientID: client)
        let task: [String: Any] = ["goal": "Complete the real project", "narrative": "Exact saved evidence",
                                   "next_actions": ["Run the remaining native verification"],
                                   "blockers": ["Preserve this blocker"], "decisions": ["Preserve this decision"],
                                   "key_files": ["Sources/Real.swift"]]
        let checkpoint = try app.tools.call(name: "session_checkpoint", arguments: task, clientID: client)
        XCTAssertTrue(checkpoint.ok, "\(checkpoint.payload)")
        let originalID = try XCTUnwrap(checkpoint.payload["handoff_id"] as? String)
        let context = try app.projectContexts.invocationContext(for: client)
        let key = app.continuityAutomation.runtimeScopeKey(context)
        XCTAssertEqual(try app.store.runtimeContinuityProgress(scopeKey: key)?.latestPacketID, originalID)
        var final: ContinuityObservation?
        for index in 1...200 {
            let saved = app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": tempHome.path], clientID: client, succeeded: true)
            if index.isMultiple(of: 50) {
                let packet = try XCTUnwrap(saved?.packet)
                XCTAssertEqual(packet.goal, task["goal"] as? String)
                XCTAssertEqual(packet.nextActions, task["next_actions"] as? [String])
                XCTAssertEqual(packet.blockers, task["blockers"] as? [String])
                XCTAssertEqual(packet.decisions, task["decisions"] as? [String])
                XCTAssertEqual(packet.keyFiles, task["key_files"] as? [String])
                XCTAssertTrue(packet.narrative.hasPrefix("Exact saved evidence"))
            }
            if saved?.finalize == true { final = saved }
        }
        let handoff = try XCTUnwrap(final?.packet)
        XCTAssertTrue(app.continuityAutomation.isBlocked(client))
        XCTAssertEqual(try app.store.handoffGet(id: originalID)?.narrative, "Exact saved evidence")
        _ = try app.tools.call(name: "context_get", arguments: ["handoff_id": handoff.id], clientID: client)
        XCTAssertEqual(try app.store.runtimeContinuityProgress(scopeKey: key)?.latestPacketID, handoff.id)
        for _ in 0..<50 {
            final = app.continuityAutomation.observe(tool: "job.read_output", arguments: [:], clientID: client, succeeded: true)
        }
        XCTAssertEqual(final?.packet.goal, task["goal"] as? String)
        XCTAssertEqual(final?.packet.nextActions, task["next_actions"] as? [String])
    }

    func testRuntimeContinuityManualHandoffKeepsBudgetAndExactResumeIdentity() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("manual-runtime-handoff")
        try bindProjectContext(app, clientID: client)
        let checkpoint = try app.tools.call(name: "session_checkpoint", arguments: ["goal": "Manual saved project"], clientID: client)
        let packetID = try XCTUnwrap(checkpoint.payload["handoff_id"] as? String)
        for _ in 0..<25 {
            _ = app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": tempHome.path], clientID: client, succeeded: true)
        }
        let handoff = try app.tools.call(name: "session_handoff", arguments: ["handoff_id": packetID], clientID: client)
        XCTAssertEqual(handoff.payload["handoff_id"] as? String, packetID)
        XCTAssertEqual(handoff.payload["handoff_required"] as? Bool, true)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 25)
        XCTAssertFalse(app.continuityAutomation.isBlocked(client))
        XCTAssertEqual(app.continuityAutomation.blockState(client).handoffID, packetID)
        let resumed = try app.tools.call(name: "context_get", arguments: ["handoff_id": packetID], clientID: client)
        XCTAssertEqual(resumed.payload["context_budget_cleared"] as? Bool, true)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 0)
    }

    func testRuntimeContinuityStatusResumeReleasesOnlyExactAcknowledgedHandoff() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("status-runtime-resume")
        try bindProjectContext(app, clientID: client)
        func reachHandoff() throws -> HandoffPacket {
            var observed: ContinuityObservation?
            for _ in 0..<200 {
                observed = app.continuityAutomation.observe(tool: "job.status", arguments: [:], clientID: client, succeeded: true)
            }
            return try XCTUnwrap(observed?.packet)
        }
        let handoff = try reachHandoff()
        let epoch = app.continuityAutomation.snapshot(for: client)["continuity_epoch"] as? String
        let expectedNonce = ContextContinuityService.interactiveRolloverNonce(handoffID: handoff.id)
        let wrong = try app.tools.call(name: "get_forge_status", arguments: ["resume": true, "handoff_id": handoff.id, "rollover_nonce": UUID().uuidString], clientID: client)
        XCTAssertEqual(wrong.payload["context_budget_cleared"] as? Bool, false)
        XCTAssertTrue(app.continuityAutomation.isBlocked(client))
        let malformed = try app.tools.call(name: "get_forge_status", arguments: ["resume": true, "handoff_id": handoff.id, "rollover_nonce": "invalid-nonce"], clientID: client)
        XCTAssertFalse(malformed.ok)
        XCTAssertTrue(app.continuityAutomation.isBlocked(client))
        let acknowledgementPath = app.paths.interactiveResumeAcknowledgementsDir.appendingPathComponent("\(handoff.id).json")
        try FileManager.default.removeItem(at: acknowledgementPath)
        try FileManager.default.createDirectory(at: acknowledgementPath, withIntermediateDirectories: false)
        let failedReceipt = try app.tools.call(name: "get_forge_status", arguments: ["resume": true, "handoff_id": handoff.id, "rollover_nonce": expectedNonce], clientID: client)
        XCTAssertFalse(failedReceipt.ok)
        XCTAssertTrue(app.continuityAutomation.isBlocked(client))
        try FileManager.default.removeItem(at: acknowledgementPath)
        let resumed = try app.tools.call(name: "get_forge_status", arguments: ["resume": true, "handoff_id": handoff.id, "rollover_nonce": expectedNonce], clientID: client)
        XCTAssertTrue(resumed.ok, "\(resumed.payload)")
        XCTAssertEqual(resumed.payload["context_budget_cleared"] as? Bool, true)
        XCTAssertFalse(app.continuityAutomation.isBlocked(client))
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 0)
        XCTAssertNotEqual(app.continuityAutomation.snapshot(for: client)["continuity_epoch"] as? String, epoch)
        let current = try reachHandoff()
        let oldRead = try app.tools.call(name: "get_forge_status", arguments: ["resume": true, "handoff_id": handoff.id], clientID: client)
        XCTAssertEqual(oldRead.payload["context_budget_cleared"] as? Bool, false)
        XCTAssertTrue(app.continuityAutomation.isBlocked(client))
        let manualResume = try app.tools.call(name: "get_forge_status", arguments: ["resume": true, "handoff_id": current.id], clientID: client)
        XCTAssertEqual(manualResume.payload["context_budget_cleared"] as? Bool, true)
        XCTAssertFalse(app.continuityAutomation.isBlocked(client))
    }

    func testRuntimeContinuityForeignDeploymentCannotPublishSuccessorAcknowledgement() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 3), save: false)
        let owner = MCPServer.defaultClientID(
            deploymentID: "gui-handoff-owning-deployment", role: .primary, desktopProviderID: nil
        )
        let foreign = MCPServer.defaultClientID(
            deploymentID: "gui-handoff-foreign-deployment", role: .primary, desktopProviderID: nil
        )
        XCTAssertNotEqual(owner, foreign)
        try bindProjectContext(app, clientID: owner)
        try bindProjectContext(app, clientID: foreign)
        let ownerContext = try app.projectContexts.invocationContext(for: owner)
        let foreignContext = try app.projectContexts.invocationContext(for: foreign)
        XCTAssertEqual(ownerContext.projectID, foreignContext.projectID)
        XCTAssertEqual(ownerContext.projectGeneration, foreignContext.projectGeneration)
        let ownerScope = app.continuityAutomation.runtimeScopeKey(ownerContext)
        XCTAssertNotEqual(ownerScope, app.continuityAutomation.runtimeScopeKey(foreignContext))

        for index in 1...3 {
            let path = tempHome.appendingPathComponent("gui-predecessor-\(index).txt")
            try "Owned predecessor evidence \(index)".write(to: path, atomically: true, encoding: .utf8)
            let result = try app.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: owner)
            XCTAssertTrue(result.ok, "\(result.payload)")
            XCTAssertEqual(app.continuityAutomation.isBlocked(owner), index == 3)
        }
        let handoff = try XCTUnwrap(app.store.handoffLegacyLatest(resumeReadyOnly: true))
        XCTAssertEqual(handoff.clientID, owner.rawValue)
        XCTAssertEqual(try app.store.runtimeContinuityPacketScopeKey(packetID: handoff.id), ownerScope)
        let packetBefore = try XCTUnwrap(app.store.handoffLegacyGet(id: handoff.id))
        let progressBefore = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: ownerScope))
        let progressJSONBefore = try sqliteFixtureText(
            at: app.paths.storeSQLite,
            sql: "SELECT CAST(state_json AS TEXT) FROM runtime_continuity_progress WHERE scope_key='\(ownerScope)';"
        )
        XCTAssertTrue(progressBefore.blocked)
        XCTAssertEqual(progressBefore.progressCount, 3)
        let acknowledgementURL = app.paths.interactiveResumeAcknowledgementsDir
            .appendingPathComponent("\(handoff.id).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: acknowledgementURL.path))
        let arguments: [String: Any] = [
            "resume": true,
            "handoff_id": handoff.id,
            "rollover_nonce": ContextContinuityService.interactiveRolloverNonce(handoffID: handoff.id),
        ]

        let rejected = try app.tools.call(name: "get_forge_status", arguments: arguments, clientID: foreign)
        XCTAssertFalse(rejected.payload["context_budget_cleared"] as? Bool == true)
        XCTAssertNil(
            rejected.payload["interactive_resume_acknowledgement"],
            "another deployment must not publish a receipt accepted by the GUI successor driver"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: acknowledgementURL.path),
            "a matching nonce cannot acknowledge the owning deployment through a foreign client"
        )
        XCTAssertTrue(app.continuityAutomation.isBlocked(owner))
        XCTAssertEqual(try sqliteFixtureText(
            at: app.paths.storeSQLite,
            sql: "SELECT CAST(state_json AS TEXT) FROM runtime_continuity_progress WHERE scope_key='\(ownerScope)';"
        ), progressJSONBefore)
        XCTAssertEqual(try app.store.handoffLegacyGet(id: handoff.id), packetBefore)

        let accepted = try app.tools.call(name: "get_forge_status", arguments: arguments, clientID: owner)
        XCTAssertTrue(accepted.ok, "\(accepted.payload)")
        XCTAssertEqual(accepted.payload["context_budget_cleared"] as? Bool, true)
        let receipt = try XCTUnwrap(accepted.payload["interactive_resume_acknowledgement"] as? [String: Any])
        XCTAssertEqual(receipt["client_id"] as? String, owner.rawValue)
        XCTAssertEqual(receipt["handoff_id"] as? String, handoff.id)
        XCTAssertEqual(receipt["rollover_nonce"] as? String, arguments["rollover_nonce"] as? String)
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: acknowledgementURL)
        ) as? [String: Any])
        XCTAssertEqual(persisted["client_id"] as? String, owner.rawValue)
        XCTAssertFalse(app.continuityAutomation.isBlocked(owner))
        XCTAssertEqual(try app.store.runtimeContinuityProgress(scopeKey: ownerScope)?.progressCount, 0)
        XCTAssertNotEqual(try app.store.runtimeContinuityProgress(scopeKey: ownerScope)?.epoch, progressBefore.epoch)
        XCTAssertEqual(try app.store.handoffLegacyGet(id: handoff.id), packetBefore)
    }

    func testRuntimeContinuityOldGenerationCannotPublishSuccessorAcknowledgement() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 3), save: false)
        let client = MCPServer.defaultClientID(
            deploymentID: "gui-handoff-generation-fence", role: .primary, desktopProviderID: nil
        )
        try bindProjectContext(app, clientID: client)
        let prior = try app.projectContexts.invocationContext(for: client)
        let priorScope = app.continuityAutomation.runtimeScopeKey(prior)
        for index in 1...3 {
            let path = tempHome.appendingPathComponent("prior-generation-\(index).txt")
            try "Prior generation \(index)".write(to: path, atomically: true, encoding: .utf8)
            XCTAssertTrue(try app.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: client).ok)
        }
        let oldPacket = try XCTUnwrap(app.store.handoffLegacyLatest(resumeReadyOnly: true))
        let oldProgressJSON = try sqliteFixtureText(at: app.paths.storeSQLite,
            sql: "SELECT CAST(state_json AS TEXT) FROM runtime_continuity_progress WHERE scope_key='\(priorScope)';")
        _ = try app.projectContexts.beginReset(projectID: prior.projectID, expectedGeneration: prior.projectGeneration)
        _ = try app.projectContexts.completeReset(projectID: prior.projectID, expectedGeneration: prior.projectGeneration)
        try bindProjectContext(app, clientID: client)
        let current = try app.projectContexts.invocationContext(for: client)
        let currentScope = app.continuityAutomation.runtimeScopeKey(current)
        XCTAssertEqual(current.projectID, prior.projectID)
        XCTAssertNotEqual(current.projectGeneration, prior.projectGeneration)
        XCTAssertNotEqual(currentScope, priorScope)
        let currentRead = try app.tools.call(name: "fs_list", arguments: ["path": tempHome.path], clientID: client)
        XCTAssertTrue(currentRead.ok, "\(currentRead.payload)")
        let currentProgressJSON = try sqliteFixtureText(at: app.paths.storeSQLite,
            sql: "SELECT CAST(state_json AS TEXT) FROM runtime_continuity_progress WHERE scope_key='\(currentScope)';")
        let receiptURL = app.paths.interactiveResumeAcknowledgementsDir.appendingPathComponent("\(oldPacket.id).json")
        let rejected = try app.tools.call(name: "get_forge_status", arguments: [
            "resume": true, "handoff_id": oldPacket.id,
            "rollover_nonce": ContextContinuityService.interactiveRolloverNonce(handoffID: oldPacket.id),
        ], clientID: client)
        XCTAssertFalse(rejected.ok)
        XCTAssertTrue(rejected.isError)
        XCTAssertNil(rejected.payload["interactive_resume_acknowledgement"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertEqual(try app.store.handoffLegacyGet(id: oldPacket.id), oldPacket)
        XCTAssertEqual(try sqliteFixtureText(at: app.paths.storeSQLite,
            sql: "SELECT CAST(state_json AS TEXT) FROM runtime_continuity_progress WHERE scope_key='\(priorScope)';"), oldProgressJSON)
        XCTAssertEqual(try sqliteFixtureText(at: app.paths.storeSQLite,
            sql: "SELECT CAST(state_json AS TEXT) FROM runtime_continuity_progress WHERE scope_key='\(currentScope)';"), currentProgressJSON)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["tool_call_count"] as? Int, 1)
    }

    func testRuntimeContinuityAcknowledgementReplayDoesNotResetSuccessorWork() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        let client = ClientID("gui-handoff-replay-owner")
        try bindProjectContext(app, clientID: client)
        let handoff = try app.tools.call(name: "session_handoff", arguments: [
            "goal": "Resume this owned task", "next_actions": ["Read the successor's evidence"],
        ], clientID: client)
        XCTAssertTrue(handoff.ok, "\(handoff.payload)")
        let packetID = try XCTUnwrap(handoff.payload["handoff_id"] as? String)
        let canonical = try XCTUnwrap(app.store.handoffLegacyGet(id: packetID))
        let arguments: [String: Any] = ["resume": true, "handoff_id": packetID,
            "rollover_nonce": ContextContinuityService.interactiveRolloverNonce(handoffID: packetID)]
        let first = try app.tools.call(name: "get_forge_status", arguments: arguments, clientID: client)
        XCTAssertTrue(first.ok, "\(first.payload)")
        XCTAssertEqual(first.payload["context_budget_cleared"] as? Bool, true)
        let continued = try app.tools.call(name: "fs_list", arguments: ["path": tempHome.path], clientID: client)
        XCTAssertTrue(continued.ok, "\(continued.payload)")
        let beforeReplay = app.continuityAutomation.snapshot(for: client)
        XCTAssertEqual(beforeReplay["tool_call_count"] as? Int, 1)
        let replay = try app.tools.call(name: "get_forge_status", arguments: arguments, clientID: client)
        XCTAssertTrue(replay.ok, "\(replay.payload)")
        XCTAssertNotNil(replay.payload["interactive_resume_acknowledgement"])
        XCTAssertEqual(replay.payload["context_budget_cleared"] as? Bool, false)
        let afterReplay = app.continuityAutomation.snapshot(for: client)
        XCTAssertEqual(afterReplay["tool_call_count"] as? Int, 1)
        XCTAssertEqual(afterReplay["continuity_epoch"] as? String, beforeReplay["continuity_epoch"] as? String)
        XCTAssertEqual(try app.store.handoffLegacyGet(id: packetID), canonical)
    }

    func testRuntimeContinuityLegacyAcknowledgementRetainsWrongNonceCompatibility() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("legacy-gui-resume-receipt")
        let packet = HandoffPacket(resumeReady: true, goal: "Legacy imported handoff", cwd: tempHome.path)
        try app.store.handoffUpsert(packet)
        XCTAssertNil(try app.store.runtimeContinuityPacketScopeKey(packetID: packet.id))
        let wrongNonce = UUID().uuidString.lowercased()
        XCTAssertNotEqual(wrongNonce, ContextContinuityService.interactiveRolloverNonce(handoffID: packet.id))
        let result = try app.tools.call(name: "get_forge_status", arguments: [
            "resume": true, "handoff_id": packet.id, "rollover_nonce": wrongNonce,
        ], clientID: client)
        XCTAssertTrue(result.ok, "\(result.payload)")
        XCTAssertEqual(result.payload["context_budget_cleared"] as? Bool, false)
        let receipt = try XCTUnwrap(result.payload["interactive_resume_acknowledgement"] as? [String: Any])
        XCTAssertEqual(receipt["client_id"] as? String, client.rawValue)
        XCTAssertEqual(receipt["rollover_nonce"] as? String, wrongNonce)
        let persisted = try JSONSupport.object(from: Data(contentsOf: app.paths.interactiveResumeAcknowledgementsDir
            .appendingPathComponent("\(packet.id).json")))
        XCTAssertEqual(persisted["rollover_nonce"] as? String, wrongNonce)
        XCTAssertNil(try app.store.runtimeContinuityPacketScopeKey(packetID: packet.id))
    }

    func testRuntimeContinuityCancelledAcknowledgementDoesNotPublishReceipt() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("cancelled-gui-resume-receipt")
        try bindProjectContext(app, clientID: client)
        let handoff = try app.tools.call(name: "session_handoff", arguments: ["goal": "Preserve on cancellation"], clientID: client)
        XCTAssertTrue(handoff.ok, "\(handoff.payload)")
        let packet = try XCTUnwrap(app.store.handoffLegacyGet(id: try XCTUnwrap(handoff.payload["handoff_id"] as? String)))
        let cancelled = ToolCallCancellation(timeoutSeconds: 5)
        cancelled.cancel()
        XCTAssertThrowsError(try app.continuityAutomation.recordInteractiveResumeAcknowledgement(
            packet: packet, rolloverNonce: ContextContinuityService.interactiveRolloverNonce(handoffID: packet.id),
            clientID: client, cancellation: cancelled
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.paths.interactiveResumeAcknowledgementsDir
            .appendingPathComponent("\(packet.id).json").path))
        XCTAssertEqual(try app.store.handoffLegacyGet(id: packet.id), packet)
    }

    func testRuntimeContinuityBoundReadersDoNotExposeAnotherProjectsScopedPacket() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let firstRoot = tempHome.appendingPathComponent("read-isolation-first", isDirectory: true)
        let selectedRoot = tempHome.appendingPathComponent("read-isolation-selected", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        try configureAllowedProjectRoot(app)
        let firstClient = MCPServer.defaultClientID(
            deploymentID: "read-isolation-first-deployment", role: .primary, desktopProviderID: nil
        )
        let selectedClient = MCPServer.defaultClientID(
            deploymentID: "read-isolation-selected-deployment", role: .primary, desktopProviderID: nil
        )
        try bindProjectContext(app, clientID: firstClient, root: firstRoot)
        try bindProjectContext(app, clientID: selectedClient, root: selectedRoot)
        let firstContext = try app.projectContexts.invocationContext(for: firstClient)
        let selectedContext = try app.projectContexts.invocationContext(for: selectedClient)
        XCTAssertNotEqual(firstContext.projectID, selectedContext.projectID)
        let selectedCheckpoint = try app.tools.call(name: "session_checkpoint", arguments: [
            "goal": "Selected project's readable checkpoint", "cwd": selectedRoot.path,
        ], clientID: selectedClient)
        XCTAssertTrue(selectedCheckpoint.ok, "\(selectedCheckpoint.payload)")
        let selectedID = try XCTUnwrap(selectedCheckpoint.payload["handoff_id"] as? String)
        let foreignGoal = "FOREIGN-PROJECT-SCOPED-CONTINUITY-\(UUID().uuidString)"
        let foreignHandoff = try app.tools.call(name: "session_handoff", arguments: [
            "goal": foreignGoal, "cwd": firstRoot.path,
            "narrative": "Confidential first-project task detail", "next_actions": ["Continue only the first project"],
        ], clientID: firstClient)
        XCTAssertTrue(foreignHandoff.ok, "\(foreignHandoff.payload)")
        let foreignID = try XCTUnwrap(foreignHandoff.payload["handoff_id"] as? String)
        let firstCanonical = try XCTUnwrap(app.store.handoffLegacyGet(id: foreignID))
        let selectedCanonical = try XCTUnwrap(app.store.handoffLegacyGet(id: selectedID))
        XCTAssertEqual(try app.store.runtimeContinuityPacketScopeKey(packetID: foreignID),
            app.continuityAutomation.runtimeScopeKey(firstContext))
        XCTAssertEqual(try app.store.runtimeContinuityPacketScopeKey(packetID: selectedID),
            app.continuityAutomation.runtimeScopeKey(selectedContext))
        XCTAssertEqual(try app.store.handoffLegacyLatest()?.id, foreignID, "Fixture requires the foreign packet to be globally newest")
        let ownedPath = selectedRoot.appendingPathComponent("selected-evidence.txt")
        try "Selected project evidence".write(to: ownedPath, atomically: true, encoding: .utf8)
        XCTAssertTrue(try app.tools.call(name: "fs_read", arguments: ["path": ownedPath.path], clientID: selectedClient).ok)
        let before = app.continuityAutomation.snapshot(for: selectedClient)
        XCTAssertEqual(before["tool_call_count"] as? Int, 1)

        let exact = try app.tools.call(name: "context_get", arguments: ["handoff_id": foreignID], clientID: selectedClient)
        XCTAssertFalse(String(decoding: try JSONSupport.data(from: exact.payload), as: UTF8.self).contains(foreignGoal),
            "an exact foreign scoped ID must not disclose another project's packet")
        if exact.ok { XCTAssertEqual(exact.payload["found"] as? Bool, false) }

        let latest = try app.tools.call(name: "context_get", arguments: [:], clientID: selectedClient)
        XCTAssertTrue(latest.ok, "\(latest.payload)")
        XCTAssertEqual(latest.payload["handoff_id"] as? String, selectedID,
            "default context_get must select the bound project's checkpoint")
        XCTAssertFalse(String(decoding: try JSONSupport.data(from: latest.payload), as: UTF8.self).contains(foreignGoal))

        let list = try app.tools.call(name: "context_list", arguments: ["limit": 10], clientID: selectedClient)
        XCTAssertTrue(list.ok, "\(list.payload)")
        let rows = try XCTUnwrap(list.payload["handoffs"] as? [[String: Any]])
        XCTAssertTrue(rows.contains { $0["id"] as? String == selectedID })
        XCTAssertFalse(rows.contains { $0["id"] as? String == foreignID },
            "bound context_list must exclude another project's runtime-scoped packet")
        XCTAssertFalse(String(decoding: try JSONSupport.data(from: list.payload), as: UTF8.self).contains(foreignGoal))

        let exactStatus = try app.tools.call(name: "get_forge_status", arguments: [
            "resume": true, "handoff_id": foreignID,
        ], clientID: selectedClient)
        XCTAssertFalse(String(decoding: try JSONSupport.data(from: exactStatus.payload), as: UTF8.self).contains(foreignGoal),
            "status resume without a nonce must also honor project isolation")
        if exactStatus.ok, let resume = exactStatus.payload["resume"] as? [String: Any] {
            XCTAssertEqual(resume["found"] as? Bool, false)
        }
        let latestStatus = try app.tools.call(name: "get_forge_status", arguments: ["resume": true], clientID: selectedClient)
        XCTAssertTrue(latestStatus.ok, "\(latestStatus.payload)")
        let resumed = try XCTUnwrap(latestStatus.payload["resume"] as? [String: Any])
        XCTAssertEqual(resumed["handoff_id"] as? String, selectedID)
        XCTAssertFalse(String(decoding: try JSONSupport.data(from: resumed), as: UTF8.self).contains(foreignGoal))

        let own = try app.tools.call(name: "context_get", arguments: ["handoff_id": selectedID], clientID: selectedClient)
        XCTAssertTrue(own.ok, "\(own.payload)")
        XCTAssertEqual(own.payload["handoff_id"] as? String, selectedID)
        XCTAssertEqual(own.payload["context_budget_cleared"] as? Bool, false)
        let after = app.continuityAutomation.snapshot(for: selectedClient)
        XCTAssertEqual(after["tool_call_count"] as? Int, 1)
        XCTAssertEqual(after["continuity_epoch"] as? String, before["continuity_epoch"] as? String)
        XCTAssertEqual(try app.store.handoffLegacyGet(id: foreignID), firstCanonical)
        XCTAssertEqual(try app.store.handoffLegacyGet(id: selectedID), selectedCanonical)
    }

    func testRuntimeContinuitySameProjectClientsRetainReadsButCannotAcknowledgeAnotherDeployment() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let owner = ClientID("shared-project-packet-owner")
        let reader = ClientID("shared-project-packet-reader")
        try bindProjectContext(app, clientID: owner)
        try bindProjectContext(app, clientID: reader)
        let saved = try app.tools.call(name: "session_handoff", arguments: ["goal": "Shared project's readable work"], clientID: owner)
        XCTAssertTrue(saved.ok, "\(saved.payload)")
        let id = try XCTUnwrap(saved.payload["handoff_id"] as? String)
        let readings: [[String: Any]] = [["handoff_id": id], [:]]
        for arguments in readings {
            let result = try app.tools.call(name: "context_get", arguments: arguments, clientID: reader)
            XCTAssertTrue(result.ok, "\(result.payload)")
            XCTAssertEqual(result.payload["handoff_id"] as? String, id)
            XCTAssertEqual(result.payload["context_budget_cleared"] as? Bool, false)
        }
        let list = try app.tools.call(name: "context_list", arguments: ["limit": 1], clientID: reader)
        XCTAssertEqual((list.payload["handoffs"] as? [[String: Any]])?.first?["id"] as? String, id)
        let status = try app.tools.call(name: "get_forge_status", arguments: ["resume": true], clientID: reader)
        XCTAssertTrue(status.ok, "\(status.payload)")
        XCTAssertEqual((status.payload["resume"] as? [String: Any])?["handoff_id"] as? String, id)
        XCTAssertEqual((status.payload["continuity"] as? [String: Any])?["resume_id"] as? String, id)
        let nonceAttempt = try app.tools.call(name: "get_forge_status", arguments: [
            "resume": true, "handoff_id": id,
            "rollover_nonce": ContextContinuityService.interactiveRolloverNonce(handoffID: id),
        ], clientID: reader)
        XCTAssertFalse(nonceAttempt.ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.paths.interactiveResumeAcknowledgementsDir.appendingPathComponent("\(id).json").path))
    }

    func testRuntimeContinuityNativeUnboundReadersRetainOnlyLegacyPacketsAndBoundUnknownCWDIsHidden() async throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let owner = ClientID("native-read-bound-owner")
        try bindProjectContext(app, clientID: owner)
        let saved = try app.tools.call(name: "session_handoff", arguments: ["goal": "Owned runtime packet"], clientID: owner)
        XCTAssertTrue(saved.ok, "\(saved.payload)")
        let scopedID = try XCTUnwrap(saved.payload["handoff_id"] as? String)
        let otherRoot = tempHome.appendingPathComponent("ambiguous-reader-project", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let otherOwner = ClientID("native-read-other-project-owner")
        try bindProjectContext(app, clientID: otherOwner, root: otherRoot)
        let other = try app.tools.call(name: "session_handoff", arguments: ["goal": "Other active project's packet"], clientID: otherOwner)
        let otherID = try XCTUnwrap(other.payload["handoff_id"] as? String)
        let legacy = HandoffPacket(goal: "Legacy packet with unknown workspace")
        try app.store.handoffUpsert(legacy)
        let unbound = ClientID("native-reader-without-binding")
        let scopedRead = try app.tools.call(name: "context_get", arguments: ["handoff_id": scopedID], clientID: unbound)
        XCTAssertTrue(scopedRead.ok, "\(scopedRead.payload)")
        XCTAssertEqual(scopedRead.payload["found"] as? Bool, false)
        let legacyRead = try app.tools.call(name: "context_get", arguments: ["handoff_id": legacy.id], clientID: unbound)
        XCTAssertTrue(legacyRead.ok, "\(legacyRead.payload)")
        XCTAssertEqual(legacyRead.payload["handoff_id"] as? String, legacy.id)
        let list = try app.tools.call(name: "context_list", arguments: [:], clientID: unbound)
        XCTAssertEqual((list.payload["handoffs"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [legacy.id])
        let boundUnknown = try app.tools.call(name: "context_get", arguments: ["handoff_id": legacy.id], clientID: owner)
        XCTAssertEqual(boundUnknown.payload["found"] as? Bool, false)
        XCTAssertEqual(boundUnknown.payload["context_budget_cleared"] as? Bool, false)
        // Direct trusted service readers retain their original global API.
        XCTAssertEqual(try app.continuity.get(id: scopedID)["found"] as? Bool, true)
        XCTAssertEqual(try app.continuity.list()["count"] as? Int, 3)
        let otherContext = try app.projectContexts.invocationContext(for: otherOwner)
        _ = try await app.projectContexts.repository.archiveProject(
            projectID: otherContext.projectID, expectedGeneration: otherContext.projectGeneration
        )
        let archived = try app.tools.call(name: "context_get", arguments: ["handoff_id": otherID], clientID: unbound)
        XCTAssertEqual(archived.payload["found"] as? Bool, false)
        let soleCurrent = try app.tools.call(name: "context_get", arguments: ["handoff_id": scopedID], clientID: unbound)
        XCTAssertEqual(soleCurrent.payload["handoff_id"] as? String, scopedID)
        XCTAssertEqual(soleCurrent.payload["context_budget_cleared"] as? Bool, false)
        let soleLegacy = try app.tools.call(name: "context_get", arguments: ["handoff_id": legacy.id], clientID: unbound)
        XCTAssertEqual(soleLegacy.payload["handoff_id"] as? String, legacy.id)
        XCTAssertThrowsError(try app.projectContexts.invocationContext(for: unbound))
    }

    func testRuntimeContinuitySoleActiveReadRecoveryPreservesExplicitAdmissionAndOwnedEpoch() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let root = tempHome.appendingPathComponent("sole-active-reader-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("owned-progress.txt")
        try Data("Owned predecessor progress".utf8).write(to: path)
        try configureAllowedProjectRoot(app, root: root)
        _ = try app.config.update(["sessions": ["continuity_rollover_tool_calls": 1]], save: false)
        let owner = ClientID("sole-active-owned-predecessor")
        let reader = ClientID("sole-active-unbound-recovery")
        try bindProjectContext(app, clientID: owner, root: root)
        let old = try app.tools.call(name: "session_handoff", arguments: ["goal": "Old generation handoff"], clientID: owner)
        let oldID = try XCTUnwrap(old.payload["handoff_id"] as? String)
        let oldContext = try app.projectContexts.invocationContext(for: owner)
        _ = try app.projectContexts.beginReset(projectID: oldContext.projectID, expectedGeneration: oldContext.projectGeneration)
        _ = try app.projectContexts.completeReset(projectID: oldContext.projectID, expectedGeneration: oldContext.projectGeneration)
        try bindProjectContext(app, clientID: owner, root: root)
        let checkpoint = try app.tools.call(name: "session_checkpoint", arguments: ["goal": "Current generation predecessor"], clientID: owner)
        let checkpointID = try XCTUnwrap(checkpoint.payload["handoff_id"] as? String)
        let trigger = try app.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: owner)
        XCTAssertTrue(trigger.ok, "\(trigger.payload)")
        let handoffID = try XCTUnwrap(trigger.payload["auto_handoff_id"] as? String)
        let before = app.continuityAutomation.snapshot(for: owner)
        XCTAssertEqual(before["blocked"] as? Bool, true)
        XCTAssertEqual(before["tool_call_count"] as? Int, 1)
        let stale = try app.tools.call(name: "context_get", arguments: ["handoff_id": oldID], clientID: reader)
        XCTAssertEqual(stale.payload["found"] as? Bool, false)
        let recovered = try app.tools.call(name: "context_get", arguments: [:], clientID: reader)
        XCTAssertTrue(recovered.ok, "\(recovered.payload)")
        XCTAssertEqual(recovered.payload["handoff_id"] as? String, handoffID)
        XCTAssertEqual(recovered.payload["context_budget_cleared"] as? Bool, false)
        let list = try app.tools.call(name: "context_list", arguments: [:], clientID: reader)
        let listedIDs = try XCTUnwrap((list.payload["handoffs"] as? [[String: Any]])?.compactMap { $0["id"] as? String })
        XCTAssertEqual(listedIDs, [handoffID, checkpointID])
        XCTAssertFalse(listedIDs.contains(oldID))
        let currentContext = try app.projectContexts.invocationContext(for: owner)
        let currentScope = app.continuityAutomation.runtimeScopeKey(currentContext)
        for packetID in listedIDs {
            let packet = try XCTUnwrap(app.store.handoffLegacyGet(id: packetID))
            XCTAssertEqual(packet.cwd, currentContext.authorizationScope.canonicalRoots.first?.path)
            XCTAssertEqual(try app.store.runtimeContinuityPacketScopeKey(packetID: packetID), currentScope)
        }
        XCTAssertThrowsError(try app.projectContexts.invocationContext(for: reader)) { error in
            guard case ProjectContextError.projectContextRequired = error else {
                return XCTFail("read-only recovery unexpectedly changed admission: \(error)")
            }
        }
        let shell = try app.tools.call(name: "shell_exec", arguments: ["command": "pwd", "cwd": root.path], clientID: reader)
        XCTAssertFalse(shell.ok)
        XCTAssertEqual(shell.payload["code"] as? String, "project_context_required")
        let acknowledgement = try app.tools.call(name: "get_forge_status", arguments: [
            "resume": true, "handoff_id": handoffID,
            "rollover_nonce": ContextContinuityService.interactiveRolloverNonce(handoffID: handoffID),
        ], clientID: reader)
        XCTAssertFalse(acknowledgement.ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.paths.interactiveResumeAcknowledgementsDir
            .appendingPathComponent("\(handoffID).json").path))
        let after = app.continuityAutomation.snapshot(for: owner)
        XCTAssertEqual(after["blocked"] as? Bool, true)
        XCTAssertEqual(after["tool_call_count"] as? Int, 1)
        XCTAssertEqual(after["continuity_epoch"] as? String, before["continuity_epoch"] as? String)
    }

    func testRuntimeContinuityReaderGenerationFenceAndStatusMetadataIgnoreOldPackets() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("reader-generation-fence")
        try bindProjectContext(app, clientID: client)
        let saved = try app.tools.call(name: "session_handoff", arguments: ["goal": "Previous generation's work"], clientID: client)
        XCTAssertTrue(saved.ok, "\(saved.payload)")
        let oldID = try XCTUnwrap(saved.payload["handoff_id"] as? String)
        let prior = try app.projectContexts.invocationContext(for: client)
        _ = try app.projectContexts.beginReset(projectID: prior.projectID, expectedGeneration: prior.projectGeneration)
        _ = try app.projectContexts.completeReset(projectID: prior.projectID, expectedGeneration: prior.projectGeneration)
        try bindProjectContext(app, clientID: client)
        let noOwnedPacket = try app.tools.call(name: "context_get", arguments: [:], clientID: client)
        XCTAssertEqual(noOwnedPacket.payload["found"] as? Bool, false)
        let oldRead = try app.tools.call(name: "context_get", arguments: ["handoff_id": oldID], clientID: client)
        XCTAssertEqual(oldRead.payload["found"] as? Bool, false)
        let before = try app.tools.call(name: "get_forge_status", arguments: [:], clientID: client)
        let noMetadata = try XCTUnwrap(before.payload["continuity"] as? [String: Any])
        XCTAssertNil(noMetadata["latest_id"] as? String)
        XCTAssertNil(noMetadata["resume_id"] as? String)
        XCTAssertEqual(noMetadata["resume_ready"] as? Bool, false)
        let current = try app.tools.call(name: "session_checkpoint", arguments: ["goal": "Current generation's checkpoint"], clientID: client)
        let currentID = try XCTUnwrap(current.payload["handoff_id"] as? String)
        let list = try app.tools.call(name: "context_list", arguments: [:], clientID: client)
        XCTAssertEqual((list.payload["handoffs"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [currentID])
        let after = try app.tools.call(name: "get_forge_status", arguments: ["resume": true], clientID: client)
        XCTAssertEqual((after.payload["continuity"] as? [String: Any])?["latest_id"] as? String, currentID)
        XCTAssertNil((after.payload["continuity"] as? [String: Any])?["resume_id"] as? String)
        XCTAssertEqual((after.payload["resume"] as? [String: Any])?["handoff_id"] as? String, currentID)
    }

    func testRuntimeContinuityForeignLegacyHistoryCannotCrowdOwnedPacketAndSymlinkReadsRemainAvailable() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let root = tempHome.appendingPathComponent("reader-owned-root", isDirectory: true)
        let foreignRoot = tempHome.appendingPathComponent("reader-foreign-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
        let client = ClientID("reader-legacy-crowding")
        try bindProjectContext(app, clientID: client, root: root)
        let saved = try app.tools.call(name: "session_checkpoint", arguments: ["goal": "Keep this current owned checkpoint"], clientID: client)
        let ownedID = try XCTUnwrap(saved.payload["handoff_id"] as? String)
        for index in 0..<125 {
            try app.store.handoffUpsert(HandoffPacket(resumeReady: true,
                goal: "Foreign legacy work \(index)", cwd: foreignRoot.path))
        }
        let latest = try app.tools.call(name: "context_get", arguments: [:], clientID: client)
        XCTAssertEqual(latest.payload["handoff_id"] as? String, ownedID)
        let list = try app.tools.call(name: "context_list", arguments: ["limit": 1], clientID: client)
        XCTAssertEqual((list.payload["handoffs"] as? [[String: Any]])?.first?["id"] as? String, ownedID)
        let alias = tempHome.appendingPathComponent("reader-owned-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let legacy = HandoffPacket(resumeReady: true, goal: "Readable legacy symlink workspace", cwd: alias.path)
        try app.store.handoffUpsert(legacy)
        let exact = try app.tools.call(name: "context_get", arguments: ["handoff_id": legacy.id], clientID: client)
        XCTAssertEqual(exact.payload["found"] as? Bool, true)
        XCTAssertEqual(exact.payload["handoff_id"] as? String, legacy.id)
        let two = try app.tools.call(name: "context_list", arguments: ["limit": 2], clientID: client)
        XCTAssertEqual((two.payload["handoffs"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [legacy.id, ownedID])
    }

    func testRuntimeContinuitySharedNoncePreservesPluginProtocol() {
        let cases = [
            ("00000000-0000-4000-8000-000000000001", "7688eed4-77b0-34aa-ffbe-1a0559c87a08"),
            ("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", "52032c4b-d13d-8ad6-7b04-8960c71d3e09"),
        ]
        for (packetID, expected) in cases {
            XCTAssertEqual(ContextContinuityService.interactiveRolloverNonce(handoffID: packetID), expected)
            XCTAssertEqual(LMStudioInteractiveSessionTransport.rolloverNonce(operationID: packetID), expected)
        }
    }

    func testRuntimeContinuityModelPointerRollsBackWithPacketAndBoundsCustomSeed() throws {
        let path = tempHome.appendingPathComponent("model-pointer.sqlite")
        let key = JSONSupport.sha256Hex("atomic model scope")
        let fault = try SQLiteStore(path: path, postMigrationCommitObserver: nil, beforeMutationCommitObserver: { kind in
            if kind == .handoff { throw StoreError.execFailed("injected model pointer failure") }
        })
        _ = try fault.updateRuntimeContinuityProgress(scopeKey: key) { $0.progressCount = 25 }
        var packet = HandoffPacket(source: .model, resumeReady: true, goal: "Model pointer", cwd: tempHome.path)
        packet.resumeSeed = String(repeating: "🧪", count: 8_000)
        packet.resumeSeedIsCustom = true
        XCTAssertThrowsError(try fault.handoffUpsertRecordingRuntimeProgress(packet, scopeKey: key))
        XCTAssertNil(try fault.handoffGet(id: packet.id))
        XCTAssertNil(try fault.runtimeContinuityProgress(scopeKey: key)?.latestPacketID)
        XCTAssertEqual(try fault.runtimeContinuityProgress(scopeKey: key)?.progressCount, 25)
        fault.close()
        let recovered = try SQLiteStore(path: path)
        defer { recovered.close() }
        try recovered.handoffUpsertRecordingRuntimeProgress(packet, scopeKey: key)
        XCTAssertEqual(try recovered.handoffGet(id: packet.id)?.resumeSeed, packet.resumeSeed)
        let progress = try XCTUnwrap(recovered.runtimeContinuityProgress(scopeKey: key))
        XCTAssertEqual(progress.latestPacketID, packet.id)
        XCTAssertEqual(progress.lastHandoffID, packet.id)
        XCTAssertEqual(progress.lastResumeSeed?.utf8.count, 16_384)
        XCTAssertEqual(progress.progressCount, 25)
        XCTAssertFalse(progress.blocked)
    }

    func testRuntimeContinuityConcurrentConnectionsDoNotLoseProgress() throws {
        let path = tempHome.appendingPathComponent("concurrent-runtime.sqlite")
        let first = try SQLiteStore(path: path)
        let second = try SQLiteStore(path: path)
        defer { first.close(); second.close() }
        let key = JSONSupport.sha256Hex("shared concurrent runtime scope")
        let failures = LockedFailureMessages()
        DispatchQueue.concurrentPerform(iterations: 160) { index in
            do {
                let store = index.isMultiple(of: 2) ? first : second
                _ = try store.updateRuntimeContinuityProgress(scopeKey: key) { progress in
                    if index.isMultiple(of: 2) { progress.progressCount += 1 }
                    else { progress.failureCount += 1 }
                }
            } catch { failures.append("writer \(index): \(error)") }
        }
        XCTAssertEqual(failures.snapshot, [])
        let one = try XCTUnwrap(first.runtimeContinuityProgress(scopeKey: key))
        let two = try XCTUnwrap(second.runtimeContinuityProgress(scopeKey: key))
        XCTAssertEqual(one.progressCount, 80)
        XCTAssertEqual(one.failureCount, 80)
        XCTAssertEqual(two.progressCount, one.progressCount)
        XCTAssertEqual(two.failureCount, one.failureCount)
        XCTAssertEqual(two.epoch, one.epoch)
    }

    func testRuntimeContinuityStoreBoundsAndCancellationPreserveExistingState() throws {
        let path = tempHome.appendingPathComponent("bounded-runtime.sqlite")
        let store = try SQLiteStore(path: path)
        defer { store.close() }
        let key = JSONSupport.sha256Hex("retained bounded runtime scope")
        _ = try store.updateRuntimeContinuityProgress(scopeKey: key) { $0.progressCount = 7 }
        XCTAssertThrowsError(try store.updateRuntimeContinuityProgress(scopeKey: key) { $0.lastTools = Array(repeating: "fs_read", count: 13) })
        let cancelled = ToolCallCancellation(timeoutSeconds: 5)
        cancelled.cancel()
        XCTAssertThrowsError(try store.updateRuntimeContinuityProgress(scopeKey: key, cancellation: cancelled) { $0.progressCount = 8 })
        XCTAssertEqual(try store.runtimeContinuityProgress(scopeKey: key)?.progressCount, 7)
        try withSQLiteFixture(at: path) { database in
            try executeSQLiteFixture(database, sql: """
                WITH RECURSIVE scopes(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM scopes WHERE n<1023)
                INSERT INTO runtime_continuity_progress(scope_key,state_json,updated_at)
                SELECT printf('%064d',n),state_json,updated_at FROM scopes,runtime_continuity_progress
                WHERE scope_key='\(key)';
                """)
        }
        XCTAssertThrowsError(try store.updateRuntimeContinuityProgress(scopeKey: JSONSupport.sha256Hex("scope beyond capacity")) { $0.progressCount = 1 })
        XCTAssertEqual(try sqliteFixtureInt(at: path, sql: "SELECT COUNT(*) FROM runtime_continuity_progress;"), SQLiteStore.maximumRuntimeContinuityScopes)
        _ = try store.updateRuntimeContinuityProgress(scopeKey: key) { $0.progressCount = 8 }
        XCTAssertEqual(try store.runtimeContinuityProgress(scopeKey: key)?.progressCount, 8)
    }

    func testRuntimeContinuityThresholdSettingsPreserveDefaultsAndRejectInvalidValues() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        XCTAssertEqual(app.config.model.sessions.continuityRolloverToolCalls, 200)
        let legacySessions = try JSONDecoder().decode(AppConfig.SessionsConfig.self,
            from: Data("{\"idle_ttl_sec\":14400}".utf8))
        XCTAssertEqual(legacySessions.continuityRolloverToolCalls, 200)
        var legacyConfig = app.config.values
        legacyConfig["sessions"] = ["idle_ttl_sec": 14_400]
        XCTAssertEqual(AppConfig.fromDictionary(legacyConfig).sessions.continuityRolloverToolCalls, 200)
        XCTAssertEqual(try ManagerSettings(dictionary: legacyConfig).continuityRolloverToolCalls, 200)
        let originalFile = try Data(contentsOf: app.paths.configJSON)
        let invalid: [Any] = [0, 10_001, -1, true, 3.5, "3", Double.infinity, Double.nan]
        for value in invalid {
            let patch: [String: Any] = ["sessions": ["continuity_rollover_tool_calls": value]]
            XCTAssertThrowsError(try app.config.update(patch))
            XCTAssertThrowsError(try ManagerSettingsNormalizer.validated(patch))
            var invalidSettings = app.config.values
            invalidSettings["sessions"] = ["continuity_rollover_tool_calls": value]
            XCTAssertThrowsError(try ManagerSettings(dictionary: invalidSettings))
            XCTAssertEqual(app.config.model.sessions.continuityRolloverToolCalls, 200)
            XCTAssertEqual(try Data(contentsOf: app.paths.configJSON), originalFile)
        }
        for limit in [1, 3, 251, 10_000] {
            _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: limit))
            let fresh = ConfigStore(paths: app.paths)
            XCTAssertEqual(fresh.model.sessions.continuityRolloverToolCalls, limit)
            let settings = try ManagerSettings(dictionary: fresh.values)
            XCTAssertEqual(settings.continuityRolloverToolCalls, limit)
            XCTAssertEqual(try ManagerSettings(dictionary: settings.asDictionary()).continuityRolloverToolCalls, limit)
            let encoded = try JSONEncoder().encode(fresh.model)
            XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: encoded).sessions.continuityRolloverToolCalls, limit)
        }
    }

    func testRuntimeContinuityCustomThresholdsKeepSeparateCountersAndCheckpointCadence() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("custom-continuity-threshold")
        try bindProjectContext(app, clientID: client)
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 3), save: false)
        for succeeded in [true, false] {
            XCTAssertNil(app.continuityAutomation.observe(tool: "job.status", arguments: [:], clientID: client, succeeded: succeeded))
        }
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 1)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["failed_tool_count"] as? Int, 1)
        XCTAssertFalse(app.continuityAutomation.isBlocked(client))
        let thirdMixed = try XCTUnwrap(app.continuityAutomation.observe(tool: "job.status", arguments: [:], clientID: client, succeeded: false))
        XCTAssertTrue(thirdMixed.finalize)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["tool_call_count"] as? Int, 3)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 1)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["failed_tool_count"] as? Int, 2)
        XCTAssertTrue(try app.continuityAutomation.clearBlockReportingResult(clientID: client, packet: thirdMixed.packet, cancellation: nil))
        for _ in 0..<2 {
            XCTAssertNil(app.continuityAutomation.observe(tool: "xcode.result", arguments: [:], clientID: client, succeeded: false))
        }
        let thirdFailure = try XCTUnwrap(app.continuityAutomation.observe(tool: "xcode.result", arguments: [:], clientID: client, succeeded: false))
        XCTAssertTrue(thirdFailure.finalize)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 0)
        XCTAssertTrue(try app.continuityAutomation.clearBlockReportingResult(clientID: client, packet: thirdFailure.packet, cancellation: nil))

        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 251))
        var openCheckpointID: String?
        for index in 1...251 {
            let saved = app.continuityAutomation.observe(tool: "bash.run", arguments: ["cwd": tempHome.path], clientID: client, succeeded: true)
            if index.isMultiple(of: 50) {
                XCTAssertEqual(saved?.finalize, false)
                if let openCheckpointID { XCTAssertEqual(saved?.packet.id, openCheckpointID) }
                else { openCheckpointID = saved?.packet.id }
            } else if index == 251 {
                XCTAssertEqual(saved?.finalize, true)
                XCTAssertEqual(saved?.packet.id, openCheckpointID)
            } else { XCTAssertNil(saved) }
            if index < 251 { XCTAssertFalse(app.continuityAutomation.isBlocked(client)) }
        }
        XCTAssertTrue(app.continuityAutomation.isBlocked(client))
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["checkpoint_every_tools"] as? Int, 50)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["handoff_every_tools"] as? Int, 251)
    }

    func testRuntimeContinuityRunningHelpersRefreshPersistedThresholdWithoutLosingStagedSettings() throws {
        let primary = try ForgeApp.bootstrap(home: tempHome)
        defer { primary.shutdown() }
        let client = MCPServer.defaultClientID(deploymentID: "threshold-live-deployment", role: .primary, desktopProviderID: nil)
        try bindProjectContext(primary, clientID: client)
        let fallback = try ForgeApp.bootstrap(home: tempHome)
        defer { fallback.shutdown() }
        for _ in 0..<2 {
            XCTAssertNil(fallback.continuityAutomation.observe(tool: "process.run", arguments: ["cwd": tempHome.path], clientID: client, succeeded: true))
        }
        _ = try primary.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 3))
        XCTAssertEqual(fallback.config.model.sessions.continuityRolloverToolCalls, 200)
        let final = try XCTUnwrap(fallback.continuityAutomation.observe(tool: "process.run", arguments: ["cwd": tempHome.path], clientID: client, succeeded: true))
        XCTAssertTrue(final.finalize)
        XCTAssertEqual(fallback.config.model.sessions.continuityRolloverToolCalls, 3)
        let restarted = try ForgeApp.bootstrap(home: tempHome)
        defer { restarted.shutdown() }
        XCTAssertEqual(restarted.config.model.sessions.continuityRolloverToolCalls, 3)
        XCTAssertTrue(restarted.continuityAutomation.isBlocked(client))

        _ = try fallback.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 7), save: false)
        _ = try primary.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 5))
        try fallback.config.refreshIfChanged()
        XCTAssertEqual(fallback.config.model.sessions.continuityRolloverToolCalls, 7)
        XCTAssertEqual(ConfigStore(paths: primary.paths).model.sessions.continuityRolloverToolCalls, 5)
    }

    func testRuntimeContinuityAgentStartDefaultsToTrustedProjectRootAndForcesCheckpoint() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("agent-default-root")
        try bindProjectContext(app, clientID: client)
        let started = try app.tools.call(name: "agent_run_start", arguments: ["agent_id": "debug", "goal": "Keep specialist provenance"], clientID: client)
        XCTAssertTrue(started.ok, "\(started.payload)")
        XCTAssertEqual(started.payload["auto_continuity"] as? String, "checkpoint")
        let sessionID = try XCTUnwrap(started.payload["session_id"] as? String)
        let packetID = try XCTUnwrap(started.payload["auto_handoff_id"] as? String)
        let packet = try XCTUnwrap(app.store.handoffGet(id: packetID))
        let agent = try XCTUnwrap(packet.agents.first { $0.sessionID == sessionID })
        XCTAssertEqual(agent.cwd, tempHome.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(agent.goal, "Keep specialist provenance")
        XCTAssertEqual(packet.goal, "Keep specialist provenance")
        let completed = try app.tools.call(name: "agent_run_complete", arguments: ["session_id": sessionID], clientID: client)
        XCTAssertTrue(completed.ok, "\(completed.payload)")
        XCTAssertEqual(completed.payload["auto_continuity"] as? String, "checkpoint")
        XCTAssertEqual(completed.payload["auto_handoff_id"] as? String, packetID)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 2)
    }

    func testRuntimeContinuityPendingJobStatusPollingDoesNotForceIdenticalCallHandoff() async throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("pending-job-status-continuity")
        try bindProjectContext(app, clientID: client)
        try configureAllowedProjectRoot(app)
        _ = try app.config.update(["shell": ["enabled": true]], save: false)
        let context = try app.projectContexts.invocationContext(for: client)
        let submission = try app.tools.call(name: "process.run", arguments: [
            "executable": "/bin/sleep", "arguments": ["20"], "cwd": tempHome.path,
            "timeout_sec": 30, "replay_class": RuntimeReplayClass.readOnly.rawValue,
        ], clientID: client)
        XCTAssertTrue(submission.ok, "\(submission.payload)")
        let jobText = try XCTUnwrap(submission.payload["job_id"] as? String)
        let jobID = try XCTUnwrap(UUID(uuidString: jobText))
        let runningDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var owner = try await app.runtimeJobs.service.status(jobID: jobID, context: context)
        while owner.state != .running, ContinuousClock.now < runningDeadline {
            try await Task.sleep(for: .milliseconds(25))
            owner = try await app.runtimeJobs.service.status(jobID: jobID, context: context)
        }
        XCTAssertEqual(owner.state, .running)
        XCTAssertNotNil(owner.processIdentifier)
        for count in 1...10 {
            let status = try app.tools.call(name: "job.status", arguments: ["job_id": jobText], clientID: client)
            XCTAssertTrue(status.ok, "poll \(count): \(status.payload)")
            XCTAssertEqual(status.payload["state"] as? String, RuntimeJobState.running.rawValue)
            XCTAssertNil(status.payload["handoff_required"], "poll \(count) forced a loop handoff while the owner runs")
            XCTAssertNil(status.payload["auto_handoff_id"])
        }
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["tool_call_count"] as? Int, 11)
        XCTAssertFalse(app.continuityAutomation.isBlocked(client))
        XCTAssertEqual(try sqliteFixtureInt(at: app.paths.storeSQLite, sql: "SELECT COUNT(*) FROM context_handoffs;"), 0)
        let stillRunning = try await app.runtimeJobs.service.status(jobID: jobID, context: context)
        XCTAssertEqual(stillRunning.state, .running)
        try await app.runtimeJobs.service.cancel(jobID: jobID, context: context)
        let cancelled = try await app.runtimeJobs.service.waitForTerminal(jobID: jobID, context: context, maximumWait: .seconds(5))
        XCTAssertEqual(cancelled.state, .cancelled)
    }

    func testRuntimeContinuityPendingUnavailableOutputRetainsErrorLoopProtection() async throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("pending-output-tail-continuity")
        try bindProjectContext(app, clientID: client)
        try configureAllowedProjectRoot(app)
        _ = try app.config.update(["shell": ["enabled": true]], save: false)
        // Start the non-owning reader before the publisher creates a live job;
        // startup recovery must never reclaim the publisher's process.
        try await app.runtimeJobs.start()
        let publisher = try ForgeApp.bootstrap(home: tempHome)
        defer { publisher.shutdown() }
        try configureAllowedProjectRoot(publisher)
        _ = try publisher.config.update(["shell": ["enabled": true]], save: false)
        let context = try app.projectContexts.invocationContext(for: client)
        let submission = try publisher.tools.call(name: "process.run", arguments: [
            "executable": "/bin/sleep", "arguments": ["20"], "cwd": tempHome.path,
            "timeout_sec": 30, "replay_class": RuntimeReplayClass.readOnly.rawValue,
        ], clientID: client)
        XCTAssertTrue(submission.ok, "\(submission.payload)")
        let jobText = try XCTUnwrap(submission.payload["job_id"] as? String)
        let jobID = try XCTUnwrap(UUID(uuidString: jobText))
        let runningDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var owner = try await publisher.runtimeJobs.service.status(jobID: jobID, context: context)
        while owner.state != .running, ContinuousClock.now < runningDeadline {
            try await Task.sleep(for: .milliseconds(25))
            owner = try await publisher.runtimeJobs.service.status(jobID: jobID, context: context)
        }
        XCTAssertEqual(owner.state, .running)
        XCTAssertNotNil(owner.processIdentifier)
        var softID: String?
        for count in 1...10 {
            let output = try app.tools.call(name: "job.read_output", arguments: [
                "job_id": jobText, "stream": "stdout", "offset": 0, "limit": 64,
            ], clientID: client)
            XCTAssertFalse(output.ok, "poll \(count): \(output.payload)")
            XCTAssertTrue(output.isError)
            XCTAssertNil(output.payload["data"])
            if count <= 8 {
                XCTAssertEqual(output.payload["code"] as? String, "runtime_output_unavailable")
                if count == 4 {
                    XCTAssertEqual(output.payload["handoff_required"] as? Bool, true)
                    softID = try XCTUnwrap(output.payload["handoff_id"] as? String)
                } else { XCTAssertNil(output.payload["handoff_required"]) }
            } else {
                XCTAssertEqual(output.payload["code"] as? String, count == 9 ? "identical_call_loop" : "context_budget_exceeded")
                XCTAssertEqual(output.payload["handoff_id"] as? String, softID)
            }
            XCTAssertNil(output.payload["auto_handoff_id"])
        }
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 1)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["failed_tool_count"] as? Int, 8)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["tool_call_count"] as? Int, 9)
        XCTAssertTrue(app.continuityAutomation.isBlocked(client))
        XCTAssertEqual(try sqliteFixtureInt(at: app.paths.storeSQLite, sql: "SELECT COUNT(*) FROM context_handoffs;"), 1)
        let stillRunning = try await publisher.runtimeJobs.service.status(jobID: jobID, context: context)
        XCTAssertEqual(stillRunning.state, .running)
        try await publisher.runtimeJobs.service.cancel(jobID: jobID, context: context)
        let cancelled = try await publisher.runtimeJobs.service.waitForTerminal(jobID: jobID, context: context, maximumWait: .seconds(5))
        XCTAssertEqual(cancelled.state, .cancelled)
    }

    func testRuntimeContinuityPendingPollingHonorsConfiguredThresholdWhileOwnerRuns() async throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        _ = try app.config.update(["shell": ["enabled": true]], save: false)
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 12), save: false)
        for tool in ["job.status"] {
            let client = ClientID("pending-budget-" + tool)
            let (jobID, jobText, context) = try await startContinuitySleepingOwner(app, clientID: client, root: tempHome)
            let arguments: [String: Any] = ["job_id": jobText]
            for _ in 0..<10 {
                let poll = try app.tools.call(name: tool, arguments: arguments, clientID: client)
                XCTAssertTrue(poll.ok, "\(poll.payload)")
                XCTAssertNil(poll.payload["handoff_required"])
            }
            XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["tool_call_count"] as? Int, 11)
            let cancellation = ToolCallCancellation(timeoutSeconds: 5)
            cancellation.cancel()
            XCTAssertThrowsError(try app.tools.call(name: tool, arguments: arguments, clientID: client, cancellation: cancellation)) {
                XCTAssertTrue($0 is CancellationError)
            }
            XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["tool_call_count"] as? Int, 11)
            let triggering = try app.tools.call(name: tool, arguments: arguments, clientID: client)
            XCTAssertTrue(triggering.ok, "\(triggering.payload)")
            XCTAssertEqual(triggering.payload["auto_continuity"] as? String, "handoff")
            let packetID = try XCTUnwrap(triggering.payload["auto_handoff_id"] as? String)
            XCTAssertTrue(try XCTUnwrap(app.store.handoffGet(id: packetID)).resumeReady)
            XCTAssertEqual(try app.store.runtimeContinuityPacketScopeKey(packetID: packetID), app.continuityAutomation.runtimeScopeKey(context))
            XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["tool_call_count"] as? Int, 12)
            XCTAssertTrue(app.continuityAutomation.isBlocked(client))
            let owner = try await app.runtimeJobs.service.status(jobID: jobID, context: context)
            XCTAssertEqual(owner.state, .running)
            try await app.runtimeJobs.service.cancel(jobID: jobID, context: context)
            let cancelled = try await app.runtimeJobs.service.waitForTerminal(jobID: jobID, context: context, maximumWait: .seconds(5))
            XCTAssertEqual(cancelled.state, .cancelled)
        }
    }

    func testRuntimeContinuityUnavailableOutputAttemptsHonorConfiguredThreshold() async throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        _ = try app.config.update(["shell": ["enabled": true]], save: false)
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 3), save: false)
        let client = ClientID("pending-unavailable-output-budget")
        try await app.runtimeJobs.start()
        let publisher = try ForgeApp.bootstrap(home: tempHome)
        defer { publisher.shutdown() }
        try configureAllowedProjectRoot(publisher)
        _ = try publisher.config.update(["shell": ["enabled": true]], save: false)
        let (jobID, jobText, context) = try await startContinuitySleepingOwner(publisher, clientID: client, root: tempHome)
        for count in 1...2 {
            let output = try app.tools.call(name: "job.read_output", arguments: ["job_id": jobText, "stream": "stdout", "offset": 0], clientID: client)
            XCTAssertFalse(output.ok)
            XCTAssertTrue(output.isError)
            XCTAssertEqual(output.payload["code"] as? String, "runtime_output_unavailable")
            if count == 1 { XCTAssertNil(output.payload["auto_handoff_id"]) }
            else {
                XCTAssertEqual(output.payload["auto_continuity"] as? String, "handoff")
                let packetID = try XCTUnwrap(output.payload["auto_handoff_id"] as? String)
                XCTAssertTrue(try XCTUnwrap(app.store.handoffGet(id: packetID)).resumeReady)
            }
        }
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 1)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["failed_tool_count"] as? Int, 2)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["tool_call_count"] as? Int, 3)
        XCTAssertTrue(app.continuityAutomation.isBlocked(client))
        let owner = try await publisher.runtimeJobs.service.status(jobID: jobID, context: context)
        XCTAssertEqual(owner.state, .running)
        try await publisher.runtimeJobs.service.cancel(jobID: jobID, context: context)
        let cancelled = try await publisher.runtimeJobs.service.waitForTerminal(jobID: jobID, context: context, maximumWait: .seconds(5))
        XCTAssertEqual(cancelled.state, .cancelled)
    }

    func testRuntimeContinuityTerminalJobReplayRetainsExactLoopThresholds() async throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        _ = try app.config.update(["shell": ["enabled": true]], save: false)
        for tool in ["job.status", "job.read_output"] {
            let client = ClientID("terminal-replay-" + tool)
            try bindProjectContext(app, clientID: client)
            let context = try app.projectContexts.invocationContext(for: client)
            let submission = try app.tools.call(name: "process.run", arguments: [
                "executable": "/bin/echo", "arguments": ["terminal evidence"], "cwd": tempHome.path,
                "timeout_sec": 5, "replay_class": RuntimeReplayClass.readOnly.rawValue,
            ], clientID: client)
            XCTAssertTrue(submission.ok, "\(submission.payload)")
            let jobText = try XCTUnwrap(submission.payload["job_id"] as? String)
            let jobID = try XCTUnwrap(UUID(uuidString: jobText))
            let terminal = try await app.runtimeJobs.service.waitForTerminal(jobID: jobID, context: context, maximumWait: .seconds(5))
            XCTAssertEqual(terminal.state, .completed)
            var arguments: [String: Any] = ["job_id": jobText]
            if tool == "job.read_output" { arguments.merge(["stream": "stdout", "offset": 0, "limit": 64]) { _, new in new } }
            var softID: String?
            for count in 1...9 {
                let result = try app.tools.call(name: tool, arguments: arguments, clientID: client)
                if count <= 8 {
                    XCTAssertTrue(result.ok, "call \(count): \(result.payload)")
                    if tool == "job.status" { XCTAssertEqual(result.payload["state"] as? String, "completed") }
                    else { XCTAssertEqual(result.payload["data"] as? String, "terminal evidence\n") }
                    if count == 4 {
                        XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                        softID = try XCTUnwrap(result.payload["handoff_id"] as? String)
                    } else { XCTAssertNil(result.payload["handoff_required"]) }
                } else {
                    XCTAssertFalse(result.ok)
                    XCTAssertEqual(result.payload["code"] as? String, "identical_call_loop")
                    XCTAssertEqual(result.payload["handoff_id"] as? String, softID)
                }
            }
            XCTAssertTrue(app.continuityAutomation.isBlocked(client))
        }
    }

    func testRuntimeContinuityForeignAndMalformedJobPollsRetainExactLoopThresholds() async throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        _ = try app.config.update(["shell": ["enabled": true]], save: false)
        let ownerRoot = tempHome.appendingPathComponent("poll-owner", isDirectory: true)
        let foreignRoot = tempHome.appendingPathComponent("poll-foreign", isDirectory: true)
        try FileManager.default.createDirectory(at: ownerRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
        let (jobID, jobText, ownerContext) = try await startContinuitySleepingOwner(app, clientID: ClientID("poll-native-owner"), root: ownerRoot)
        let scenarios: [(String, [String: Any], URL, String)] = [
            ("job.status", ["job_id": jobText], foreignRoot, "runtime_job_scope_mismatch"),
            ("job.read_output", ["job_id": jobText, "offset": 0], foreignRoot, "runtime_job_scope_mismatch"),
            ("job.status", ["job_id": "not-a-uuid"], ownerRoot, "invalid_request"),
            ("job.read_output", ["job_id": jobText, "offset": -1], ownerRoot, "invalid_request"),
        ]
        for (index, scenario) in scenarios.enumerated() {
            let (tool, arguments, root, code) = scenario
            let client = ClientID("rejected-poll-\(index)")
            try bindProjectContext(app, clientID: client, root: root)
            var softID: String?
            for count in 1...9 {
                let result = try app.tools.call(name: tool, arguments: arguments, clientID: client)
                XCTAssertFalse(result.ok)
                XCTAssertTrue(result.isError)
                if count <= 8 {
                    XCTAssertEqual(result.payload["code"] as? String, code, "call \(count): \(result.payload)")
                    if count == 4 {
                        XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                        softID = try XCTUnwrap(result.payload["handoff_id"] as? String)
                    } else { XCTAssertNil(result.payload["handoff_required"]) }
                } else {
                    XCTAssertEqual(result.payload["code"] as? String, "identical_call_loop")
                    XCTAssertEqual(result.payload["handoff_id"] as? String, softID)
                }
            }
        }
        let owner = try await app.runtimeJobs.service.status(jobID: jobID, context: ownerContext)
        XCTAssertEqual(owner.state, .running)
        try await app.runtimeJobs.service.cancel(jobID: jobID, context: ownerContext)
        let cancelled = try await app.runtimeJobs.service.waitForTerminal(jobID: jobID, context: ownerContext, maximumWait: .seconds(5))
        XCTAssertEqual(cancelled.state, .cancelled)
    }

    private func startContinuitySleepingOwner(
        _ app: ForgeApp,
        clientID: ClientID,
        root: URL
    ) async throws -> (UUID, String, ToolInvocationContext) {
        try bindProjectContext(app, clientID: clientID, root: root)
        let context = try app.projectContexts.invocationContext(for: clientID)
        let submission = try app.tools.call(name: "process.run", arguments: [
            "executable": "/bin/sleep", "arguments": ["20"], "cwd": root.path,
            "timeout_sec": 30, "replay_class": RuntimeReplayClass.readOnly.rawValue,
        ], clientID: clientID)
        XCTAssertTrue(submission.ok, "\(submission.payload)")
        let text = try XCTUnwrap(submission.payload["job_id"] as? String)
        let id = try XCTUnwrap(UUID(uuidString: text))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var record = try await app.runtimeJobs.service.status(jobID: id, context: context)
        while record.state != .running, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
            record = try await app.runtimeJobs.service.status(jobID: id, context: context)
        }
        XCTAssertEqual(record.state, .running)
        XCTAssertNotNil(record.processIdentifier)
        return (id, text, context)
    }

    func testRuntimeContinuityManagerOwnedContextsDoNotEnterOrdinaryChatEpochs() async throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("shared-mcp-and-native-client")
        try bindProjectContext(app, clientID: client)
        try configureAllowedProjectRoot(app)
        let mcp = try app.projectContexts.invocationContext(for: client)
        XCTAssertNil(app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": tempHome.path], clientID: client, succeeded: true))
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 1), save: false)
        let nativeTools = ["fs_read", "process.run", "xcode.run", "bash.run"]
        let runScope = ToolAuthorizationScope(canonicalRoots: [tempHome], allowedTools: Set(nativeTools),
            networkAllowed: false, maximumInlineOutputBytes: 65_536)
        let run = try await app.projectContexts.repository.createAutonomousRun(AutonomousRunRequest(
            projectID: mcp.projectID, projectGeneration: mcp.projectGeneration,
            mission: "Keep native lifecycle separate from ordinary chat", providerID: "lmstudio",
            adapterID: "lmstudio-rest", modelKey: "fixture/model",
            specification: AutonomousRunSpecification(allowedTools: nativeTools, completionGates: ["tests"]),
            authorizationScope: runScope))
        let runContext = try app.projectContexts.invocationContext(
            for: ProjectBindingOwner(kind: .autonomousRun, id: run.runID.description), clientID: client)
        let lease = try await app.projectContexts.repository.acquireRunLease(runID: run.runID, ownerID: "continuity-native-fixture")
        let sessionID = "continuity-native-session-" + UUID().uuidString.lowercased()
        try await app.projectContexts.repository.reserveProviderSession(ProviderSessionIntent(
            sessionID: sessionID, runID: run.runID, projectID: run.projectID, projectGeneration: run.projectGeneration,
            providerID: "lmstudio", adapterID: "lmstudio-rest", modelKey: "fixture/model",
            providerResponseID: "continuity-native-root", idempotencyKey: "continuity-native-session-key", contextCapacity: 4_096), lease: lease)
        _ = try await app.projectContexts.repository.releaseRunLease(lease)
        let providerContext = try app.projectContexts.invocationContext(
            for: ProjectBindingOwner(kind: .providerSession, id: sessionID), clientID: client)
        let nativeOnlyClient = ClientID("native-client-without-mcp-binding")
        let nativeOnlyContext = try app.projectContexts.invocationContext(
            for: ProjectBindingOwner(kind: .providerSession, id: sessionID), clientID: nativeOnlyClient)
        let identity = ContextBudgetIdentity(runID: run.runID, projectID: run.projectID,
            projectGeneration: run.projectGeneration, sessionID: sessionID)
        let configuration = ContextBudgetConfiguration(
            capacity: ContextCapacityResolution(providerID: "lmstudio", providerVersionFingerprint: "fixture-v1",
                modelKey: "fixture/model", activeInstanceID: "fixture-instance", capacity: 4_096,
                maximumContextLength: 131_072, requiresModelLoad: false),
            reserves: ContextBudgetReserves(outputTokens: 256, schemaTokens: 128, handoffTokens: 256, recoveryTokens: 128),
            policy: ContextBudgetPolicy(initialProjectedNextTurnTokens: 128))
        let budget = try await ContextBudgetSupervisor.open(repository: app.projectContexts.repository,
            identity: identity, configuration: configuration, clock: app.clock)
        _ = try await budget.evaluate(ContextBudgetEvaluationRequest(triggerPoint: .afterProviderTurn,
            providerResponseID: "continuity-native-root", measurement: .providerExact(usedTokens: 100)))
        let before = try await app.projectContexts.repository.contextBudgetState(identity: identity)
        for index in 0..<200 {
            let context = index.isMultiple(of: 2) ? runContext : providerContext
            XCTAssertNil(app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": tempHome.path],
                clientID: client, succeeded: index.isMultiple(of: 3), trustedContext: context))
            XCTAssertNil(app.continuityAutomation.observe(tool: "fs_read", arguments: ["path": tempHome.path],
                clientID: nativeOnlyClient, succeeded: true, trustedContext: nativeOnlyContext))
        }
        for (index, context) in [runContext, providerContext, nativeOnlyContext].enumerated() {
            let path = tempHome.appendingPathComponent("native-read-\(index).txt")
            try Data("Native result".utf8).write(to: path)
            let result = try app.tools.call(name: "fs_read", arguments: ["path": path.path], context: context)
            XCTAssertTrue(result.ok, "\(result.payload)")
            XCTAssertNil(result.payload["auto_handoff_id"])
        }
        _ = try app.config.update(["shell": ["enabled": false]], save: false)
        for (name, context) in zip(["process.run", "xcode.run", "bash.run"], [runContext, providerContext, nativeOnlyContext]) {
            let denied = try app.tools.call(name: name, arguments: ["cwd": tempHome.path], context: context)
            XCTAssertFalse(denied.ok)
            XCTAssertTrue(denied.isError)
            XCTAssertEqual(denied.payload["code"] as? String, "shell_disabled_by_user")
            XCTAssertNil(denied.payload["auto_handoff_id"])
        }
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 1)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["tool_call_count"] as? Int, 1)
        XCTAssertEqual(app.continuityAutomation.snapshot(for: nativeOnlyClient)["progress_count"] as? Int, 0)
        XCTAssertFalse(app.continuityAutomation.isBlocked(client))
        XCTAssertEqual(try sqliteFixtureInt(at: app.paths.storeSQLite, sql: "SELECT COUNT(*) FROM context_handoffs;"), 0)
        XCTAssertNil(try app.store.runtimeContinuityProgress(scopeKey: app.continuityAutomation.runtimeScopeKey(providerContext)))
        let after = try await app.projectContexts.repository.contextBudgetState(identity: identity)
        XCTAssertEqual(after?.revision, before?.revision)
        XCTAssertEqual(after?.latestObservation?.observationID, before?.latestObservation?.observationID)
        let nativeRollover = try await budget.evaluate(ContextBudgetEvaluationRequest(triggerPoint: .afterProviderTurn,
            providerResponseID: "continuity-native-pressure", measurement: .providerExact(usedTokens: 2_828)))
        XCTAssertEqual(nativeRollover.observation.action, .rollover)
        XCTAssertEqual(nativeRollover.actionRequest?.requestedAction, .rollover)
    }

    func testRuntimeContinuityRouterCountsDeniedEligibleAttemptsAndPreservesPolicyErrors() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("denied-runtime-continuity")
        try bindProjectContext(app, clientID: client)
        try configureAllowedProjectRoot(app)
        _ = try app.config.update(["shell": ["enabled": false]], save: false)
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 3), save: false)
        let names = ["process.run", "xcode.run", "bash.run"]
        for (index, name) in names.enumerated() {
            let result = try app.tools.call(name: name, arguments: ["cwd": tempHome.path], clientID: client)
            XCTAssertFalse(result.ok)
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.payload["code"] as? String, "shell_disabled_by_user")
            XCTAssertEqual(result.payload["retryable"] as? Bool, false)
            XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["tool_call_count"] as? Int, index + 1)
            if index < 2 {
                XCTAssertNil(result.payload["auto_handoff_id"])
                XCTAssertFalse(app.continuityAutomation.isBlocked(client))
            } else {
                let packetID = try XCTUnwrap(result.payload["auto_handoff_id"] as? String)
                let packet = try XCTUnwrap(app.store.handoffGet(id: packetID))
                XCTAssertTrue(packet.resumeReady)
                XCTAssertEqual(packet.clientID, client.rawValue)
                XCTAssertTrue(app.continuityAutomation.isBlocked(client))
            }
        }
        let snapshot = app.continuityAutomation.snapshot(for: client)
        XCTAssertEqual(snapshot["progress_count"] as? Int, 0)
        XCTAssertEqual(snapshot["failed_tool_count"] as? Int, 3)
        let audits = try app.audit.recent(limit: 20).filter { $0.clientID == client.rawValue }
        XCTAssertEqual(Set(audits.map(\.tool)), Set(names))
        XCTAssertEqual(audits.filter { $0.status == "denied" }.count, 3)
    }

    func testRuntimeContinuityRouterCountsDeniedThrownAndFailedResultsTogether() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("mixed-router-failure-continuity")
        try bindProjectContext(app, clientID: client)
        try configureAllowedProjectRoot(app)
        _ = try app.config.update(["shell": ["enabled": false]], save: false)
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 3), save: false)
        let denied = try app.tools.call(name: "process.run", arguments: ["cwd": tempHome.path], clientID: client)
        XCTAssertFalse(denied.ok)
        XCTAssertTrue(denied.isError)
        XCTAssertEqual(denied.payload["code"] as? String, "shell_disabled_by_user")
        XCTAssertNil(denied.payload["auto_handoff_id"])
        let throwingRouter = ToolRouter(app: app, packs: [ThrowingLoopToolPack(toolNames: ["fs_list"])])
        let thrown = try throwingRouter.call(name: "fs_list", arguments: ["path": tempHome.path], clientID: client)
        XCTAssertFalse(thrown.ok)
        XCTAssertTrue(thrown.isError)
        XCTAssertEqual(thrown.payload["code"] as? String, "tool_exception")
        XCTAssertNil(thrown.payload["auto_handoff_id"])
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["tool_call_count"] as? Int, 2)
        let failed = try app.tools.call(name: "fs_read", arguments: [:], clientID: client)
        XCTAssertFalse(failed.ok)
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.payload["code"] as? String, "missing_path")
        let packetID = try XCTUnwrap(failed.payload["auto_handoff_id"] as? String)
        XCTAssertTrue(try XCTUnwrap(app.store.handoffGet(id: packetID)).resumeReady)
        XCTAssertTrue(app.continuityAutomation.isBlocked(client))
        let snapshot = app.continuityAutomation.snapshot(for: client)
        XCTAssertEqual(snapshot["progress_count"] as? Int, 0)
        XCTAssertEqual(snapshot["failed_tool_count"] as? Int, 3)
        XCTAssertEqual(snapshot["tool_call_count"] as? Int, 3)
        let audits = try app.audit.recent(limit: 20).filter { $0.clientID == client.rawValue }
        XCTAssertEqual(audits.filter { $0.status == "denied" }.count, 1)
        XCTAssertEqual(audits.filter { $0.status == "error" }.count, 2)
    }

    func testRuntimeContinuityPacketOwnerIsAtomicImmutableAndSurvivesRestart() throws {
        let path = tempHome.appendingPathComponent("packet-owner.sqlite")
        let store = try SQLiteStore(path: path)
        let firstKey = JSONSupport.sha256Hex("first project generation")
        let secondKey = JSONSupport.sha256Hex("second project generation")
        let legacy = HandoffPacket(source: .model, goal: "Legacy evidence", cwd: tempHome.path)
        try store.handoffUpsert(legacy)
        XCTAssertNil(try store.runtimeContinuityPacketScopeKey(packetID: legacy.id))
        let packet = HandoffPacket(source: .model, goal: "Bound evidence", cwd: tempHome.path)
        try store.handoffUpsertRecordingRuntimeProgress(packet, scopeKey: firstKey)
        let originalJSON = try sqliteFixtureText(at: path, sql: "SELECT packet_json FROM context_handoffs WHERE id='\(packet.id)';")
        var changed = packet
        changed.goal = "Conflicting replacement"
        XCTAssertThrowsError(try store.handoffUpsertRecordingRuntimeProgress(changed, scopeKey: secondKey))
        XCTAssertEqual(try store.runtimeContinuityPacketScopeKey(packetID: packet.id), firstKey)
        XCTAssertEqual(try sqliteFixtureText(at: path, sql: "SELECT packet_json FROM context_handoffs WHERE id='\(packet.id)';"), originalJSON)
        XCTAssertNil(try store.runtimeContinuityProgress(scopeKey: secondKey))
        // Existing legacy packet writes preserve the recorded scope association.
        try store.handoffUpsert(packet)
        XCTAssertEqual(try store.runtimeContinuityPacketScopeKey(packetID: packet.id), firstKey)
        store.close()
        let reopened = try SQLiteStore(path: path)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.runtimeContinuityPacketScopeKey(packetID: packet.id), firstKey)
        XCTAssertNil(try reopened.runtimeContinuityPacketScopeKey(packetID: legacy.id))
        XCTAssertEqual(try reopened.runtimeContinuityProgress(scopeKey: firstKey)?.latestPacketID, packet.id)
    }

    func testRuntimeContinuityDirectScopeSelectionIsBoundedAndNotCrowdedByNewerHistory() throws {
        let path = tempHome.appendingPathComponent("runtime-selection.sqlite")
        let store = try SQLiteStore(path: path)
        defer { store.close() }
        let currentScope = JSONSupport.sha256Hex("current selection scope")
        let historicalScope = JSONSupport.sha256Hex("historical selection scope")
        let current = HandoffPacket(source: .auto, resumeReady: true, goal: "Current exact handoff", cwd: tempHome.path)
        try store.handoffUpsertRecordingRuntimeProgress(current, scopeKey: currentScope)
        let historical = HandoffPacket(source: .auto, resumeReady: true, goal: "Newer fenced history", cwd: tempHome.path)
        try store.handoffUpsertRecordingRuntimeProgress(historical, scopeKey: historicalScope)
        try withSQLiteFixture(at: path) { database in
            try executeSQLiteFixture(database, sql: """
                WITH RECURSIVE packets(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM packets WHERE n<120)
                INSERT INTO context_handoffs(id,created_at,updated_at,source,resume_ready,packet_json,client_id,write_sequence,runtime_scope_key)
                SELECT printf('%08x-0000-4000-8000-000000000000',n),created_at,updated_at,source,resume_ready,
                       replace(packet_json,id,printf('%08x-0000-4000-8000-000000000000',n)),client_id,n+2,runtime_scope_key
                FROM packets,context_handoffs WHERE id='\(historical.id)';
                """)
        }
        XCTAssertFalse(try store.handoffLegacyList(limit: 100).contains { $0.id == current.id })
        var keys = Set((1...1_599).map { JSONSupport.sha256Hex("empty selection scope \($0)") })
        keys.insert(currentScope)
        let selected = try XCTUnwrap(store.handoffRuntimeLatest(scopeKeys: keys))
        XCTAssertEqual(selected.packet.id, current.id)
        XCTAssertEqual(selected.writeSequence, 1)
        XCTAssertNil(try store.handoffRuntimeLatest(scopeKeys: keys, excludingPacketIDs: [current.id]))
        XCTAssertThrowsError(try store.handoffRuntimeLatest(scopeKeys: keys,
            excludingPacketIDs: Set((0..<129).map { "excluded-packet-\($0)" })))
        XCTAssertNil(try store.handoffRuntimeLatest(scopeKeys: []))
        keys.insert(historicalScope)
        XCTAssertThrowsError(try store.handoffRuntimeLatest(scopeKeys: keys))
        XCTAssertThrowsError(try store.handoffRuntimeLatest(scopeKeys: ["invalid-key"]))
        let cancelled = ToolCallCancellation(timeoutSeconds: 5)
        cancelled.cancel()
        XCTAssertThrowsError(try store.handoffRuntimeLatest(scopeKeys: [currentScope], cancellation: cancelled))
        let legacy = HandoffPacket(source: .model, resumeReady: true, goal: "Unscoped compatibility", cwd: tempHome.path)
        try store.handoffUpsert(legacy)
        XCTAssertEqual(try store.handoffLegacyList(limit: 100, unscopedOnly: true).map(\.id), [legacy.id])
        XCTAssertEqual(try store.handoffLegacyList(limit: 100, unscopedOnly: true, excludingPacketIDs: [legacy.id]).count, 0)
        XCTAssertThrowsError(try store.handoffLegacyList(excludingPacketIDs: Set((0..<129).map { "excluded-packet-\($0)" })))
        // A more recent checkpoint does not replace a resume-ready handoff candidate.
        let checkpoint = HandoffPacket(source: .auto, goal: "Open checkpoint", cwd: tempHome.path)
        try store.handoffUpsertRecordingRuntimeProgress(checkpoint, scopeKey: currentScope)
        XCTAssertEqual(try store.handoffRuntimeLatest(scopeKeys: [currentScope])?.packet.id, current.id)
    }

    func testRuntimeContinuityOpenCheckpointsReuseOnePacketAndAcknowledgementStartsNewHistory() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("checkpoint-row-reuse")
        try bindProjectContext(app, clientID: client)
        let model = try app.tools.call(name: "session_checkpoint", arguments: ["goal": "Keep authored history"], clientID: client)
        let modelID = try XCTUnwrap(model.payload["handoff_id"] as? String)
        let modelJSON = try sqliteFixtureText(at: app.paths.storeSQLite, sql: "SELECT packet_json FROM context_handoffs WHERE id='\(modelID)';")
        var final: ContinuityObservation?
        var openID: String?
        for index in 1...200 {
            let saved = app.continuityAutomation.observe(tool: "job.read_output", arguments: [:], clientID: client, succeeded: true)
            if index.isMultiple(of: 50) {
                if let openID { XCTAssertEqual(saved?.packet.id, openID) } else { openID = saved?.packet.id }
                final = saved
            }
        }
        let finalized = try XCTUnwrap(final?.packet)
        XCTAssertTrue(finalized.resumeReady)
        XCTAssertNotEqual(finalized.id, modelID)
        XCTAssertEqual(try sqliteFixtureInt(at: app.paths.storeSQLite, sql: "SELECT COUNT(*) FROM context_handoffs WHERE runtime_scope_key IS NOT NULL;"), 2)
        let finalizedJSON = try sqliteFixtureText(at: app.paths.storeSQLite, sql: "SELECT packet_json FROM context_handoffs WHERE id='\(finalized.id)';")
        let epoch = app.continuityAutomation.snapshot(for: client)["continuity_epoch"] as? String
        let resumed = try app.tools.call(name: "get_forge_status", arguments: ["resume": true, "handoff_id": finalized.id], clientID: client)
        XCTAssertEqual(resumed.payload["context_budget_cleared"] as? Bool, true)
        XCTAssertNotEqual(app.continuityAutomation.snapshot(for: client)["continuity_epoch"] as? String, epoch)
        var next: ContinuityObservation?
        for _ in 0..<50 { next = app.continuityAutomation.observe(tool: "xcode.result", arguments: [:], clientID: client, succeeded: true) }
        XCTAssertNotEqual(next?.packet.id, finalized.id)
        XCTAssertNotEqual(next?.packet.id, modelID)
        XCTAssertEqual(try sqliteFixtureText(at: app.paths.storeSQLite, sql: "SELECT packet_json FROM context_handoffs WHERE id='\(modelID)';"), modelJSON)
        XCTAssertEqual(try sqliteFixtureText(at: app.paths.storeSQLite, sql: "SELECT packet_json FROM context_handoffs WHERE id='\(finalized.id)';"), finalizedJSON)
    }

    func testRuntimeContinuityPacketCapacityReportsAttentionAndRecoversWithoutDeletingHistory() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("packet-capacity-runtime")
        try bindProjectContext(app, clientID: client)
        try configureAllowedProjectRoot(app)
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 3), save: false)
        let file = tempHome.appendingPathComponent("capacity-read.txt")
        try Data("Read succeeded".utf8).write(to: file)
        let historical = HandoffPacket(source: .auto, resumeReady: true, goal: "Retain historical evidence", cwd: tempHome.path)
        let historicalScope = JSONSupport.sha256Hex("historical runtime scope")
        try app.store.handoffUpsertRecordingRuntimeProgress(historical, scopeKey: historicalScope)
        let legacy = HandoffPacket(source: .model, goal: "Retain unscoped evidence", cwd: tempHome.path)
        try app.store.handoffUpsert(legacy)
        let historicalJSON = try sqliteFixtureText(at: app.paths.storeSQLite, sql: "SELECT packet_json FROM context_handoffs WHERE id='\(historical.id)';")
        try withSQLiteFixture(at: app.paths.storeSQLite) { database in
            try executeSQLiteFixture(database, sql: """
                WITH RECURSIVE packets(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM packets WHERE n<9999)
                INSERT INTO context_handoffs(id,created_at,updated_at,source,resume_ready,packet_json,client_id,write_sequence,runtime_scope_key)
                SELECT printf('%08x-0000-4000-8000-000000000000',n),created_at,updated_at,source,resume_ready,
                       replace(packet_json,id,printf('%08x-0000-4000-8000-000000000000',n)),client_id,n,runtime_scope_key
                FROM packets,context_handoffs WHERE id='\(historical.id)';
                """)
        }
        for _ in 0..<2 {
            let result = try app.tools.call(name: "fs_read", arguments: ["path": file.path], clientID: client)
            XCTAssertTrue(result.ok, "\(result.payload)")
            XCTAssertNil(result.payload["continuity_attention"])
        }
        let triggering = try app.tools.call(name: "fs_read", arguments: ["path": file.path], clientID: client)
        XCTAssertTrue(triggering.ok, "The read operation already succeeded: \(triggering.payload)")
        XCTAssertNil(triggering.payload["auto_handoff_id"])
        let attention = try XCTUnwrap(triggering.payload["continuity_attention"] as? [String: Any])
        XCTAssertEqual(attention["code"] as? String, "continuity_capacity_reached")
        XCTAssertEqual(attention["resource"] as? String, "runtime_continuity_packets")
        XCTAssertEqual(attention["limit"] as? Int, 10_000)
        XCTAssertEqual(attention["attention_required"] as? Bool, true)
        XCTAssertEqual(attention["handoff_persisted"] as? Bool, false)
        XCTAssertFalse(app.continuityAutomation.isBlocked(client))
        let context = try app.projectContexts.invocationContext(for: client)
        let key = app.continuityAutomation.runtimeScopeKey(context)
        let pending = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: key)?.pending)
        XCTAssertTrue(pending.finalize)
        XCTAssertNil(try app.store.handoffGet(id: pending.packetID))
        let status = try app.tools.call(name: "get_forge_status", arguments: [:], clientID: client)
        let snapshot = try XCTUnwrap(status.payload["auto_continuity"] as? [String: Any])
        XCTAssertEqual(snapshot["continuity_attention_required"] as? Bool, true)
        XCTAssertEqual((snapshot["continuity_attention"] as? [String: Any])?["code"] as? String, "continuity_capacity_reached")
        let reopened = try SQLiteStore(path: app.paths.storeSQLite)
        XCTAssertEqual(try reopened.runtimeContinuityProgress(scopeKey: key)?.capacityFailure, SQLiteStore.runtimeContinuityPacketCapacityMessage)
        reopened.close()
        // Binding an existing unscoped packet also consumes capacity and cannot evade the limit.
        XCTAssertThrowsError(try app.store.handoffUpsertRecordingRuntimeProgress(legacy, scopeKey: key))
        XCTAssertNil(try app.store.runtimeContinuityPacketScopeKey(packetID: legacy.id))
        XCTAssertEqual(try sqliteFixtureInt(at: app.paths.storeSQLite, sql: "SELECT COUNT(*) FROM context_handoffs WHERE runtime_scope_key IS NOT NULL;"), 10_000)
        XCTAssertEqual(try sqliteFixtureText(at: app.paths.storeSQLite, sql: "SELECT packet_json FROM context_handoffs WHERE id='\(historical.id)';"), historicalJSON)
        // Simulate an operator explicitly choosing one disposable fixture row.
        try withSQLiteFixture(at: app.paths.storeSQLite) { database in
            try executeSQLiteFixture(database, sql: "DELETE FROM context_handoffs WHERE id='00000001-0000-4000-8000-000000000000';")
        }
        let recovered = try app.tools.call(name: "fs_read", arguments: ["path": file.path], clientID: client)
        XCTAssertTrue(recovered.ok, "\(recovered.payload)")
        XCTAssertEqual(recovered.payload["auto_handoff_id"] as? String, pending.packetID)
        XCTAssertEqual(recovered.payload["auto_continuity"] as? String, "handoff")
        XCTAssertNil(recovered.payload["continuity_attention"])
        XCTAssertTrue(app.continuityAutomation.isBlocked(client))
        XCTAssertNil(try app.store.runtimeContinuityProgress(scopeKey: key)?.capacityFailure)
        XCTAssertEqual(try app.store.runtimeContinuityPacketScopeKey(packetID: pending.packetID), key)
        XCTAssertEqual(try sqliteFixtureText(at: app.paths.storeSQLite, sql: "SELECT packet_json FROM context_handoffs WHERE id='\(historical.id)';"), historicalJSON)
    }

    func testRuntimeContinuityScopeCapacityReportsAttentionWithoutInventingProgress() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("scope-capacity-runtime")
        try bindProjectContext(app, clientID: client)
        try configureAllowedProjectRoot(app)
        let file = tempHome.appendingPathComponent("scope-read.txt")
        try Data("Read succeeded".utf8).write(to: file)
        let seed = JSONSupport.sha256Hex("retained capacity seed")
        _ = try app.store.updateRuntimeContinuityProgress(scopeKey: seed) { $0.progressCount = 7 }
        try withSQLiteFixture(at: app.paths.storeSQLite) { database in
            try executeSQLiteFixture(database, sql: """
                WITH RECURSIVE scopes(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM scopes WHERE n<1023)
                INSERT INTO runtime_continuity_progress(scope_key,state_json,updated_at)
                SELECT printf('%064d',n),state_json,updated_at FROM scopes,runtime_continuity_progress WHERE scope_key='\(seed)';
                """)
        }
        let triggering = try app.tools.call(name: "fs_read", arguments: ["path": file.path], clientID: client)
        XCTAssertTrue(triggering.ok, "\(triggering.payload)")
        XCTAssertNil(triggering.payload["auto_handoff_id"])
        let attention = try XCTUnwrap(triggering.payload["continuity_attention"] as? [String: Any])
        XCTAssertEqual(attention["resource"] as? String, "runtime_continuity_scopes")
        XCTAssertEqual(attention["limit"] as? Int, 1_024)
        XCTAssertEqual(attention["code"] as? String, "continuity_capacity_reached")
        let context = try app.projectContexts.invocationContext(for: client)
        XCTAssertNil(try app.store.runtimeContinuityProgress(scopeKey: app.continuityAutomation.runtimeScopeKey(context)))
        let snapshot = app.continuityAutomation.snapshot(for: client)
        XCTAssertEqual(snapshot["progress_count"] as? Int, 0)
        XCTAssertEqual(snapshot["continuity_attention_required"] as? Bool, true)
        XCTAssertEqual((snapshot["continuity_attention"] as? [String: Any])?["resource"] as? String, "runtime_continuity_scopes")
        XCTAssertEqual(try app.store.runtimeContinuityProgress(scopeKey: seed)?.progressCount, 7)
    }

    func testAutoCheckpointFailureRetainsPrecommitStageAndUnavailableHandoffID() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let attemptID = UUID()
        XCTAssertThrowsError(try app.continuity.autoPersist(
            clientID: ClientID("checkpoint-failure"), reason: "capture test", finalize: false,
            inferred: ["handoff_id": "missing-checkpoint-packet"], attemptID: attemptID
        ))
        let record = try XCTUnwrap(app.diagnostics.recent(limit: 100).last {
            $0.event == "auto_persist_failed"
        })
        XCTAssertEqual(record.fields["attempt_id"], attemptID.uuidString)
        XCTAssertEqual(record.fields["operation"], "checkpoint")
        XCTAssertEqual(record.fields["failure_stage"], "packet_build")
        XCTAssertEqual(record.fields["handoff_id"], "unavailable_before_packet_build")
        XCTAssertEqual(record.fields["save_outcome"], "not_confirmed")
        XCTAssertEqual(record.fields["successor_request_state"], "not_requested_by_persistence")
    }

    func testContextGetRequiresExplicitProjectBindingBeforeShell() throws {
        let projectRoot = tempHome.appendingPathComponent("adopt-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app, root: projectRoot)
        _ = try app.config.update(["shell": ["enabled": true]], save: false)
        let original = ClientID("adopt-original")
        try bindProjectContext(app, clientID: original, root: projectRoot)
        _ = try app.tools.call(
            name: "session_checkpoint",
            arguments: [
                "goal": "Build Jamf Technician",
                "cwd": projectRoot.path,
                "project_slug": "jamf-technician",
            ],
            clientID: original
        )

        let resumed = ClientID("adopt-resumed")
        let got = try app.tools.call(name: "context_get", arguments: [:], clientID: resumed)
        XCTAssertTrue(got.ok)
        XCTAssertEqual(got.payload["found"] as? Bool, true)

        let unboundShell = try app.tools.call(
            name: "shell_exec",
            arguments: ["command": "pwd", "cwd": projectRoot.path],
            clientID: resumed
        )
        XCTAssertFalse(unboundShell.ok)
        XCTAssertEqual(unboundShell.payload["code"] as? String, "project_context_required")

        try bindProjectContext(app, clientID: resumed, root: projectRoot)
        let shell = try app.tools.call(
            name: "shell_exec",
            arguments: ["command": "pwd", "cwd": projectRoot.path],
            clientID: resumed
        )
        XCTAssertTrue(shell.ok, "\(shell.payload)")
        XCTAssertEqual(shell.payload["code"] as? String, nil)
    }

    func testRuntimeHandoffBlocksProjectToolsUntilContextGet() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        try configureAllowedProjectRoot(app)
        let client = ClientID("auto-handoff-block")
        try bindProjectContext(app, clientID: client)
        var last: ToolResult?
        for index in 0..<ContinuityAutomation.handoffEveryTools {
            last = try app.tools.call(
                name: "fs_write",
                arguments: [
                    "path": tempHome.appendingPathComponent("handoff-\(index).txt").path,
                    "content": "n=\(index)",
                ],
                clientID: client
            )
            XCTAssertTrue(last?.ok == true, "write \(index) \(last?.payload ?? [:])")
        }
        XCTAssertEqual(last?.payload["handoff_required"] as? Bool, true)
        XCTAssertEqual(last?.payload["auto_continuity"] as? String, "handoff")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.paths.memoryNextChat.path))

        let blocked = try app.tools.call(
            name: "fs_write",
            arguments: [
                "path": tempHome.appendingPathComponent("blocked.txt").path,
                "content": "must not write",
            ],
            clientID: client
        )
        XCTAssertFalse(blocked.ok)
        XCTAssertEqual(blocked.payload["code"] as? String, "context_budget_exceeded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempHome.appendingPathComponent("blocked.txt").path))

        let resumed = ClientID("auto-handoff-resumed")
        let got = try app.tools.call(name: "context_get", arguments: [:], clientID: client)
        XCTAssertEqual(got.payload["context_budget_cleared"] as? Bool, true)
        _ = try app.tools.call(name: "context_get", arguments: [:], clientID: resumed)

        let after = try app.tools.call(
            name: "fs_write",
            arguments: [
                "path": tempHome.appendingPathComponent("after-resume.txt").path,
                "content": "ok",
            ],
            clientID: client
        )
        XCTAssertTrue(after.ok, "\(after.payload)")
    }

    func testBoundReadOnlyPathDoesNotRequireSelectedProjectContainment() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let projects = tempHome.appendingPathComponent("local-projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        try bindProjectContext(app, clientID: ClientID("home-read"))
        let native = try app.tools.call(
            name: "fs_list",
            arguments: ["path": projects.path],
            clientID: ClientID("home-read")
        )
        XCTAssertTrue(native.ok, "\(native.payload)")

        try configureAllowedProjectRoot(app, root: projects)
        try bindProjectContext(
            app,
            clientID: ClientID("configured-read"),
            root: projects
        )
        let allowed = try app.tools.call(
            name: "fs_list",
            arguments: ["path": projects.path],
            clientID: ClientID("configured-read")
        )
        XCTAssertTrue(allowed.ok, "\(allowed.payload)")
    }
}

private func ordinaryRuntimeProgressBytes(_ value: RuntimeContinuityProgress) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

private func ordinaryRuntimeReferenceRecord(
    context: ToolInvocationContext,
    jobID: UUID = UUID(),
    projectID: ProjectID? = nil,
    generation: ProjectGeneration? = nil
) -> RuntimeJobRecord {
    RuntimeJobRecord(jobID: jobID, runID: context.runID,
        projectID: projectID ?? context.projectID,
        projectGeneration: generation ?? context.projectGeneration,
        runtimeKind: .process, executionProfile: .directProcess,
        replayClass: .readOnly, idempotencyKey: nil, state: .queued,
        canonicalWorkingDirectory: context.authorizationScope.canonicalRoots[0],
        commandSummary: "FORGE-ORDINARY-REF-PRIVATE-COMMAND", timeoutSeconds: 5,
        exitCode: nil, outputArtifactID: nil, outputBytes: 0,
        processIdentifier: nil, processGroupIdentifier: nil,
        errorCode: nil, errorSummary: nil, createdAt: "2027-01-15T08:00:00Z",
        startedAt: nil, completedAt: nil, updatedAt: "2027-01-15T08:00:00Z")
}

private final class OrdinaryRuntimePacketResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[String: Any], Error>?
    func set(_ result: Result<[String: Any], Error>) {
        lock.lock(); self.result = result; lock.unlock()
    }
    func take() -> Result<[String: Any], Error>? {
        lock.lock(); defer { lock.unlock() }
        return result
    }
}

extension ContinuityTests {
    private func ordinaryRuntimeReferenceFixture(
        client: ClientID,
        allowedTools: Set<String> = ["*"]
    ) throws -> (app: ForgeApp, context: ToolInvocationContext, key: String) {
        let root = try XCTUnwrap(tempHome)
        let app = try ForgeApp.bootstrap(home: root,
            clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)))
        do {
            let initialized = try app.projectMemory.initializeUnchecked(path: root.path)
            let projectID = try XCTUnwrap(initialized["project_id"] as? String)
            let descriptor = try app.projectMemory.identities.descriptor(projectID: projectID)
            let context = try app.projectContexts.registerAndBindMCPClientUnchecked(
                descriptor: descriptor, canonicalRoot: root, clientID: client,
                allowedTools: allowedTools)
            try configureAllowedProjectRoot(app, root: root)
            _ = try app.config.update(["shell": ["enabled": true]], save: false)
            _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 10_000), save: false)
            return (app, context, app.continuityAutomation.runtimeScopeKey(context))
        } catch {
            app.shutdown()
            throw error
        }
    }

    func testOrdinaryRuntimeAdmissionPreparationAndOneUsePreserveDistinctReusedJobAttempts() throws {
        let fixture = try ordinaryRuntimeReferenceFixture(client: ClientID("ordinary-admission-one-use"))
        let app = fixture.app
        defer { app.shutdown() }
        let first = try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: fixture.context, cancellation: nil))
        let prepared = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key))
        XCTAssertNil(prepared.runtimeJobSubmissions)
        XCTAssertEqual(prepared.progressCount, 0)
        XCTAssertNil(prepared.latestPacketID)
        let record = ordinaryRuntimeReferenceRecord(context: fixture.context)
        try first(record)
        let admitted = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key))
        let beforeReplay = try ordinaryRuntimeProgressBytes(admitted)
        XCTAssertThrowsError(try first(record))
        XCTAssertEqual(try ordinaryRuntimeProgressBytes(XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key))), beforeReplay)
        let second = try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: fixture.context, cancellation: nil))
        try second(record)
        let references = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key)?.runtimeJobSubmissions)
        XCTAssertEqual(references.map(\.jobID), [record.jobID, record.jobID])
        XCTAssertEqual(Set(references.map(\.submissionID)).count, 2)
        XCTAssertEqual(references.map(\.tool), ["process.run", "process.run"])
        XCTAssertEqual(app.continuityAutomation.snapshot(for: fixture.context.clientID)["progress_count"] as? Int, 0)
    }

    func testOrdinaryRuntimeAdmissionRejectsWrongIdentityBlockedEpochAndCancellation() throws {
        let fixture = try ordinaryRuntimeReferenceFixture(client: ClientID("ordinary-admission-fences"))
        let app = fixture.app
        defer { app.shutdown() }
        let callback = try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: fixture.context, cancellation: nil))
        let before = try ordinaryRuntimeProgressBytes(XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key)))
        let wrong = [
            ordinaryRuntimeReferenceRecord(context: fixture.context, projectID: ProjectID(UUID())),
            ordinaryRuntimeReferenceRecord(context: fixture.context,
                generation: ProjectGeneration(fixture.context.projectGeneration.rawValue + 1)),
        ]
        for record in wrong {
            XCTAssertThrowsError(try callback(record))
            XCTAssertEqual(try ordinaryRuntimeProgressBytes(XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key))), before)
        }
        _ = try app.store.updateRuntimeContinuityProgress(scopeKey: fixture.key) { $0.blocked = true }
        let blocked = try ordinaryRuntimeProgressBytes(XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key)))
        XCTAssertThrowsError(try callback(ordinaryRuntimeReferenceRecord(context: fixture.context)))
        XCTAssertThrowsError(try app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: fixture.context, cancellation: nil))
        XCTAssertEqual(try ordinaryRuntimeProgressBytes(XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key))), blocked)
        _ = try app.store.updateRuntimeContinuityProgress(scopeKey: fixture.key) { $0 = RuntimeContinuityProgress() }
        let successor = try ordinaryRuntimeProgressBytes(XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key)))
        XCTAssertThrowsError(try callback(ordinaryRuntimeReferenceRecord(context: fixture.context)))
        XCTAssertEqual(try ordinaryRuntimeProgressBytes(XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key))), successor)
        let cancelled = ToolCallCancellation(timeoutSeconds: 5)
        let pending = try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: fixture.context, cancellation: cancelled))
        cancelled.cancel()
        XCTAssertThrowsError(try pending(ordinaryRuntimeReferenceRecord(context: fixture.context))) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try ordinaryRuntimeProgressBytes(XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key))), successor)
    }

    func testOrdinaryRuntimeAdmissionExcludesManagedAndJobOwnedContextsWithoutCreatingProgress() throws {
        let fixture = try ordinaryRuntimeReferenceFixture(client: ClientID("ordinary-admission-exclusions"))
        let app = fixture.app
        defer { app.shutdown() }
        let original = fixture.context
        let excluded = [
            ToolInvocationContext(projectID: original.projectID, projectGeneration: original.projectGeneration,
                clientID: original.clientID, runID: RunID(UUID()), authorizationScope: original.authorizationScope),
            ToolInvocationContext(projectID: original.projectID, projectGeneration: original.projectGeneration,
                clientID: original.clientID, providerSessionID: "owned-provider-fixture", authorizationScope: original.authorizationScope),
            ToolInvocationContext(projectID: original.projectID, projectGeneration: original.projectGeneration,
                clientID: original.clientID, runtimeJobID: UUID(), authorizationScope: original.authorizationScope),
        ]
        for context in excluded {
            XCTAssertNil(try app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
                tool: "process.run", context: context, cancellation: nil))
            XCTAssertNil(try app.store.runtimeContinuityProgress(scopeKey: app.continuityAutomation.runtimeScopeKey(context)))
        }
        XCTAssertNil(try app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "fs_read", context: original, cancellation: nil))
        XCTAssertNil(try app.store.runtimeContinuityProgress(scopeKey: fixture.key))
    }

    func testOrdinaryRuntimeReferenceWireKeepsLegacyPacketsAndRejectsMalformedExtension() throws {
        let legacy = HandoffPacket(goal: "Legacy authored task", resumeSeed: "Exact legacy seed", resumeSeedIsCustom: true)
        XCTAssertNil(legacy.asDictionary()["runtime_continuation"])
        XCTAssertEqual(HandoffPacket.fromDictionary(legacy.asDictionary()), legacy)
        var progress = RuntimeContinuityProgress()
        progress.progressCount = 7
        var historical = try JSONSupport.object(from: ordinaryRuntimeProgressBytes(progress))
        historical.removeValue(forKey: "runtimeJobSubmissions")
        let decoded = try JSONDecoder().decode(RuntimeContinuityProgress.self, from: JSONSupport.data(from: historical)).validated()
        XCTAssertEqual(decoded.epoch, progress.epoch)
        XCTAssertEqual(decoded.progressCount, 7)
        XCTAssertNil(decoded.runtimeJobSubmissions)
        let reference = RuntimeJobContinuationReference(submissionID: UUID(), jobID: UUID(), tool: "process.run")
        let snapshot = try RuntimeJobContinuationSnapshot(schemaVersion: 1, scopeKey: JSONSupport.sha256Hex("wire"),
            originEpoch: UUID(), submissions: [reference]).validated()
        var native = legacy
        native.runtimeJobContinuation = snapshot
        XCTAssertEqual(HandoffPacket.fromDictionary(native.asDictionary()), native)
        let extensionObject = snapshot.asDictionary()
        var invalid: [[String: Any]] = []
        let invalidVersions: [Any] = [2, true, 1.5, "1"]
        for version in invalidVersions {
            var value = extensionObject; value["schema_version"] = version; invalid.append(value)
        }
        for field in ["scope_key", "origin_epoch"] {
            var value = extensionObject; value[field] = "invalid"; invalid.append(value)
        }
        for field in ["submission_id", "job_id", "tool"] {
            var row = reference.asDictionary(); row[field] = field == "tool" ? "fs_read" : "not-a-uuid"
            var value = extensionObject; value["submissions"] = [row]; invalid.append(value)
        }
        var duplicate = extensionObject; duplicate["submissions"] = [reference.asDictionary(), reference.asDictionary()]
        invalid.append(duplicate)
        var empty = extensionObject; empty["submissions"] = []; invalid.append(empty)
        var tooMany = extensionObject
        tooMany["submissions"] = (0..<33).map { _ in
            RuntimeJobContinuationReference(submissionID: UUID(), jobID: UUID(), tool: "process.run").asDictionary()
        }
        invalid.append(tooMany)
        var oversized = extensionObject
        oversized["padding"] = String(repeating: "x", count: RuntimeJobContinuationSnapshot.maximumBytes + 1)
        XCTAssertGreaterThan(try JSONSupport.data(from: oversized).count, RuntimeJobContinuationSnapshot.maximumBytes)
        invalid.append(oversized)
        for value in invalid {
            var wire = legacy.asDictionary(); wire["runtime_continuation"] = value
            XCTAssertNil(HandoffPacket.fromDictionary(wire), "\(value.keys.sorted())")
        }
        var wrongContainer = legacy.asDictionary(); wrongContainer["runtime_continuation"] = ["invalid"]
        XCTAssertNil(HandoffPacket.fromDictionary(wrongContainer))
    }

    func testOrdinaryRuntimeReferenceMaximumCanonicalBytesPreserveAllThirtyTwoAttempts() throws {
        let jobID = UUID()
        let references = (0..<32).map { _ in RuntimeJobContinuationReference(
            submissionID: UUID(), jobID: jobID, tool: "powershell.run") }
        let snapshot = try RuntimeJobContinuationSnapshot(schemaVersion: 1,
            scopeKey: JSONSupport.sha256Hex("maximum-reference-wire"), originEpoch: UUID(), submissions: references).validated()
        XCTAssertLessThanOrEqual(try JSONSupport.data(from: snapshot.asDictionary()).count, 16_384)
        var packet = HandoffPacket(goal: "Maximum native attempts")
        packet.runtimeJobContinuation = snapshot
        let restored = try XCTUnwrap(HandoffPacket.fromDictionary(packet.asDictionary()))
        XCTAssertEqual(restored.runtimeJobContinuation?.submissions, references)
        XCTAssertEqual(Set(references.map(\.submissionID)).count, 32)
        XCTAssertEqual(Set(references.map(\.jobID)), [jobID])
    }

    func testOrdinaryRuntimeThirtySecondAdmissionPromotesLateClaimWithoutEvictionAndRejectsThirtyThird() throws {
        let client = ClientID("ordinary-capacity-promotion")
        let fixture = try ordinaryRuntimeReferenceFixture(client: client)
        let app = fixture.app
        defer { app.shutdown() }
        let root = try XCTUnwrap(tempHome)
        let evidence = root.appendingPathComponent("ordinary-capacity-evidence.txt")
        try "Owned capacity evidence\n".write(to: evidence, atomically: true, encoding: .utf8)
        let saved = try app.tools.call(name: "session_checkpoint", arguments: [
            "goal": "Keep authored capacity task", "cwd": root.path, "resume_seed": "Exact capacity seed",
        ], clientID: client)
        XCTAssertTrue(saved.ok)
        let callbacks = try (0..<33).map { _ in try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: fixture.context, cancellation: nil)) }
        let records = (0..<33).map { _ in ordinaryRuntimeReferenceRecord(context: fixture.context) }
        for index in 0..<31 { try callbacks[index](records[index]) }
        _ = try app.store.updateRuntimeContinuityProgress(scopeKey: fixture.key) { progress in
            progress.progressCount = 49
            progress.startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        }
        let packetClock = FinalReviewPacketBuildClock(Date(timeIntervalSince1970: 1_800_000_000))
        let service = ContextContinuityService(paths: app.paths, store: app.store,
            sessions: app.sessions, diagnostics: app.diagnostics, clock: packetClock)
        let owner = ContinuityAutomation(store: app.store, sessions: app.sessions, continuity: service,
            diagnostics: app.diagnostics, clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)),
            projectContexts: app.projectContexts, configStore: app.config)
        let box = FinalReviewContinuityObservationBox()
        let finished = DispatchGroup()
        packetClock.arm(); finished.enter()
        DispatchQueue.global(qos: .userInteractive).async(qos: .userInteractive, flags: .enforceQoS) {
            defer { finished.leave() }
            box.set(owner.observe(tool: "fs_read", arguments: ["path": evidence.path], clientID: client, succeeded: true))
        }
        defer {
            packetClock.release.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 6), .success)
        }
        XCTAssertEqual(packetClock.reached.wait(timeout: .now() + 2), .success)
        let initial = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key))
        let claim = try XCTUnwrap(initial.pending)
        XCTAssertFalse(claim.finalize)
        XCTAssertNil(initial.rolloverRequested)
        try callbacks[31](records[31])
        let full = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key))
        XCTAssertEqual(full.runtimeJobSubmissions?.map(\.jobID), Array(records.prefix(32)).map(\.jobID))
        XCTAssertEqual(full.rolloverRequested, true)
        XCTAssertEqual(full.pending, claim)
        let fullBytes = try ordinaryRuntimeProgressBytes(full)
        XCTAssertThrowsError(try callbacks[32](records[32]))
        XCTAssertThrowsError(try app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: fixture.context, cancellation: nil))
        XCTAssertEqual(try ordinaryRuntimeProgressBytes(XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key))), fullBytes)
        packetClock.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 6), .success)
        XCTAssertFalse(packetClock.didTimeOut)
        let observation = try XCTUnwrap(box.snapshot)
        XCTAssertTrue(observation.finalize)
        XCTAssertEqual(observation.packet.id, claim.packetID)
        XCTAssertEqual(observation.packet.runtimeJobContinuation?.submissions, full.runtimeJobSubmissions)
        XCTAssertEqual(observation.packet.resumeSeed, "Exact capacity seed")
        let committed = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key))
        XCTAssertTrue(committed.blocked)
        XCTAssertEqual(committed.runtimeJobSubmissions, full.runtimeJobSubmissions)
        XCTAssertNil(committed.pending)
        XCTAssertEqual(try app.store.handoffLegacyGet(id: observation.packet.id), observation.packet)
    }

    func testOrdinaryRuntimeModelCheckpointReturnsAndProjectsLatestCommittedReferences() throws {
        try assertOrdinaryRuntimePacketMerge(mode: "checkpoint")
    }

    func testOrdinaryRuntimeModelHandoffReturnsAndProjectsLatestCommittedReferences() throws {
        try assertOrdinaryRuntimePacketMerge(mode: "handoff")
    }

    func testOrdinaryRuntimeBudgetReturnsAndProjectsLatestCommittedReferences() throws {
        try assertOrdinaryRuntimePacketMerge(mode: "budget")
    }

    private func assertOrdinaryRuntimePacketMerge(mode: String) throws {
        let client = ClientID("ordinary-merge-\(mode)")
        let fixture = try ordinaryRuntimeReferenceFixture(client: client)
        let app = fixture.app
        defer { app.shutdown() }
        let root = try XCTUnwrap(tempHome)
        let saved = try app.tools.call(name: "session_checkpoint", arguments: [
            "goal": "Original authored task", "cwd": root.path, "resume_seed": "Exact authored seed",
            "next_actions": ["Keep the authored next step"],
        ], clientID: client)
        XCTAssertTrue(saved.ok)
        let first = ordinaryRuntimeReferenceRecord(context: fixture.context)
        let admission = try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: fixture.context, cancellation: nil))
        try admission(first)
        let packetClock = FinalReviewPacketBuildClock(Date(timeIntervalSince1970: 1_800_000_000))
        let service = ContextContinuityService(paths: app.paths, store: app.store,
            sessions: app.sessions, diagnostics: app.diagnostics, clock: packetClock)
        let context = fixture.context
        let key = fixture.key
        let box = OrdinaryRuntimePacketResultBox()
        let finished = DispatchGroup()
        packetClock.arm(); finished.enter()
        DispatchQueue.global(qos: .userInteractive).async(qos: .userInteractive, flags: .enforceQoS) {
            defer { finished.leave() }
            do {
                let payload: [String: Any]
                if mode == "budget" {
                    let packet = try service.budgetRuntimeCheckpoint(clientID: client,
                        reason: "owned merge fixture", context: context, scopeKey: key,
                        blockProgress: false, cancellation: nil)
                    payload = ["packet": packet.asDictionary()]
                } else {
                    payload = try service.persistRuntimeModelPacket(arguments: [
                        "goal": "New authored task", "cwd": root.path,
                    ], clientID: client, context: context, scopeKey: key,
                        finalize: mode == "handoff", cancellation: nil)
                }
                box.set(.success(payload))
            } catch { box.set(.failure(error)) }
        }
        defer {
            packetClock.release.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 6), .success)
        }
        XCTAssertEqual(packetClock.reached.wait(timeout: .now() + 2), .success)
        let second = ordinaryRuntimeReferenceRecord(context: context)
        let late = try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: context, cancellation: nil))
        try late(second)
        packetClock.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 6), .success)
        XCTAssertFalse(packetClock.didTimeOut)
        let payload = try XCTUnwrap(box.take()).get()
        let wire = try XCTUnwrap(payload["packet"] as? [String: Any])
        let packet = try XCTUnwrap(HandoffPacket.fromDictionary(wire))
        XCTAssertEqual(packet.runtimeJobContinuation?.submissions.map(\.jobID), [first.jobID, second.jobID])
        XCTAssertEqual(packet.runtimeJobContinuation?.scopeKey, key)
        XCTAssertEqual(packet.resumeSeed, "Exact authored seed")
        XCTAssertEqual(packet.nextActions, ["Keep the authored next step"])
        XCTAssertEqual(packet.goal, mode == "budget" ? "Original authored task" : "New authored task")
        XCTAssertEqual(try app.store.handoffLegacyGet(id: packet.id), packet)
        let projection = try JSONSupport.object(from: Data(contentsOf:
            app.paths.memoryHandoffsDir.appendingPathComponent("\(packet.id).json")))
        XCTAssertEqual(HandoffPacket.fromDictionary(projection), packet)
    }

    func testOrdinaryRuntimePublicLegacyImportCannotMintNativeOriginAndPreservesSeeds() throws {
        let fixture = try ordinaryRuntimeReferenceFixture(client: ClientID("ordinary-forged-import"))
        let app = fixture.app
        defer { app.shutdown() }
        let fakeID = UUID()
        let fake = RuntimeJobContinuationSnapshot(schemaVersion: 1, scopeKey: fixture.key, originEpoch: UUID(),
            submissions: [RuntimeJobContinuationReference(submissionID: UUID(), jobID: fakeID, tool: "process.run")])
        for custom in [false, true] {
            var imported = HandoffPacket(clientID: fixture.context.clientID.rawValue,
                goal: "Imported authored task", cwd: try XCTUnwrap(tempHome).path,
                resumeSeed: custom ? "Exact imported custom seed" : "", resumeSeedIsCustom: custom)
            imported.runtimeJobContinuation = fake
            if !custom { imported.resumeSeed = imported.defaultResumeSeed() }
            try app.store.handoffUpsert(imported)
            let stored = try XCTUnwrap(app.store.handoffLegacyGet(id: imported.id))
            XCTAssertNil(stored.runtimeJobContinuation)
            XCTAssertNil(try app.store.runtimeContinuityPacketScopeKey(packetID: stored.id))
            XCTAssertEqual(stored.goal, imported.goal)
            XCTAssertEqual(stored.resumeSeedIsCustom, custom)
            XCTAssertEqual(stored.resumeSeed, custom ? "Exact imported custom seed" : stored.defaultResumeSeed())
            let response = try app.tools.call(name: "session_checkpoint", arguments: [
                "handoff_id": stored.id, "goal": "Edited imported task",
                "runtime_continuation": fake.asDictionary(),
            ], clientID: fixture.context.clientID)
            XCTAssertTrue(response.ok)
            let edited = try XCTUnwrap(app.store.handoffLegacyGet(id: stored.id))
            XCTAssertNil(edited.runtimeJobContinuation)
            XCTAssertFalse(try JSONSupport.string(from: edited.asDictionary()).contains(fakeID.uuidString.lowercased()))
            XCTAssertEqual(edited.resumeSeedIsCustom, custom)
            XCTAssertEqual(edited.resumeSeed, custom ? "Exact imported custom seed" : edited.defaultResumeSeed())
        }
    }

    func testOrdinaryRuntimeSealedLegacySameIDEditDoesNotAcquireCurrentNativeReferences() throws {
        let fixture = try ordinaryRuntimeReferenceFixture(client: ClientID("ordinary-sealed-null-origin"))
        let app = fixture.app
        defer { app.shutdown() }
        let legacy = HandoffPacket(resumeReady: true, clientID: fixture.context.clientID.rawValue,
            goal: "Sealed legacy task", cwd: try XCTUnwrap(tempHome).path,
            resumeSeed: "Exact sealed legacy seed", resumeSeedIsCustom: true)
        try app.store.handoffUpsert(legacy)
        let before = try XCTUnwrap(app.store.interactiveContinuityHandoffRecord(packetID: legacy.id))
        XCTAssertNil(before.runtimeScopeKey)
        try app.store.sealInteractiveContinuityHandoff(expected: before)
        let record = ordinaryRuntimeReferenceRecord(context: fixture.context)
        let admission = try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: fixture.context, cancellation: nil))
        try admission(record)
        let saved = try app.tools.call(name: "session_checkpoint", arguments: [
            "handoff_id": legacy.id, "goal": "Allowed same-ID authored edit",
        ], clientID: fixture.context.clientID)
        XCTAssertTrue(saved.ok)
        let edited = try XCTUnwrap(app.store.interactiveContinuityHandoffRecord(packetID: legacy.id))
        XCTAssertTrue(edited.isSealed)
        XCTAssertEqual(edited.sealedSequence, before.writeSequence)
        XCTAssertGreaterThan(edited.writeSequence, before.writeSequence)
        XCTAssertEqual(edited.packet.goal, "Allowed same-ID authored edit")
        XCTAssertEqual(edited.packet.resumeSeed, legacy.resumeSeed)
        XCTAssertNil(edited.packet.runtimeJobContinuation)
        XCTAssertEqual(try app.store.runtimeContinuityProgress(scopeKey: fixture.key)?.runtimeJobSubmissions?.map(\.jobID), [record.jobID])
    }

    func testOrdinaryRuntimeOldSealedPacketCannotClearSuccessorReferencesAndFreshHandoffPreservesThem() throws {
        let fixture = try ordinaryRuntimeReferenceFixture(client: ClientID("ordinary-old-id-reset-fence"))
        let app = fixture.app
        defer { app.shutdown() }
        let first = ordinaryRuntimeReferenceRecord(context: fixture.context)
        let admission = try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: fixture.context, cancellation: nil))
        try admission(first)
        let packetA = try app.continuity.budgetRuntimeCheckpoint(clientID: fixture.context.clientID,
            reason: "owned first epoch", context: fixture.context, scopeKey: fixture.key,
            blockProgress: true, cancellation: nil)
        let sealed = try XCTUnwrap(app.store.interactiveContinuityHandoffRecord(packetID: packetA.id))
        try app.store.sealInteractiveContinuityHandoff(expected: sealed)
        XCTAssertTrue(try app.continuityAutomation.clearBlockReportingResult(
            clientID: fixture.context.clientID, packet: packetA, cancellation: nil))
        let second = ordinaryRuntimeReferenceRecord(context: fixture.context)
        let late = try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: fixture.context, cancellation: nil))
        try late(second)
        let edited = try app.continuity.persistRuntimeModelPacket(arguments: [
            "handoff_id": packetA.id, "goal": "Allowed successor authored edit of old ID",
        ], clientID: fixture.context.clientID, context: fixture.context,
            scopeKey: fixture.key, finalize: true, cancellation: nil)
        let wire = try XCTUnwrap(edited["packet"] as? [String: Any])
        let old = try XCTUnwrap(HandoffPacket.fromDictionary(wire))
        XCTAssertEqual(old.id, packetA.id)
        XCTAssertEqual(old.runtimeJobContinuation, packetA.runtimeJobContinuation)
        XCTAssertEqual(old.goal, "Allowed successor authored edit of old ID")
        let beforeReset = try ordinaryRuntimeProgressBytes(XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key)))
        XCTAssertFalse(try app.continuityAutomation.clearBlockReportingResult(
            clientID: fixture.context.clientID, packet: old, cancellation: nil))
        XCTAssertEqual(try ordinaryRuntimeProgressBytes(XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: fixture.key))), beforeReset)
        let packetB = try app.continuity.budgetRuntimeCheckpoint(clientID: fixture.context.clientID,
            reason: "owned successor epoch", context: fixture.context, scopeKey: fixture.key,
            blockProgress: false, cancellation: nil)
        XCTAssertNotEqual(packetB.id, packetA.id)
        XCTAssertNotEqual(packetB.runtimeJobContinuation?.originEpoch, packetA.runtimeJobContinuation?.originEpoch)
        XCTAssertEqual(packetB.runtimeJobContinuation?.submissions.map(\.jobID), [second.jobID])
        XCTAssertEqual(try app.store.handoffLegacyGet(id: packetA.id), old)
    }

    func testOrdinaryRuntimeOldCheckpointCannotBeReusedByBlockingBudget() throws {
        for sealPrior in [true, false] {
            let fixture = try ordinaryRuntimeReferenceFixture(client: ClientID("ordinary-old-checkpoint-\(sealPrior)"))
            let app = fixture.app
            defer { app.shutdown() }
            let first = ordinaryRuntimeReferenceRecord(context: fixture.context)
            let admission = try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
                tool: "process.run", context: fixture.context, cancellation: nil))
            try admission(first)
            _ = try app.continuity.persistRuntimeModelPacket(arguments: [
                "goal": "Preserved authored task", "resume_seed": "Exact authored successor seed",
            ], clientID: fixture.context.clientID, context: fixture.context,
                scopeKey: fixture.key, finalize: false, cancellation: nil)
            let packetA = try app.continuity.budgetRuntimeCheckpoint(clientID: fixture.context.clientID,
                reason: "first checkpoint epoch", context: fixture.context, scopeKey: fixture.key,
                blockProgress: true, cancellation: nil)
            if sealPrior {
                let prior = try XCTUnwrap(app.store.interactiveContinuityHandoffRecord(packetID: packetA.id))
                try app.store.sealInteractiveContinuityHandoff(expected: prior)
            }
            XCTAssertTrue(try app.continuityAutomation.clearBlockReportingResult(
                clientID: fixture.context.clientID, packet: packetA, cancellation: nil))
            let second = ordinaryRuntimeReferenceRecord(context: fixture.context)
            let successorAdmission = try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
                tool: "process.run", context: fixture.context, cancellation: nil))
            try successorAdmission(second)
            let edited = try app.continuity.persistRuntimeModelPacket(arguments: [
                "handoff_id": packetA.id, "goal": "Edited authored task",
            ], clientID: fixture.context.clientID, context: fixture.context,
                scopeKey: fixture.key, finalize: false, cancellation: nil)
            let wire = try XCTUnwrap(edited["packet"] as? [String: Any])
            let oldCheckpoint = try XCTUnwrap(HandoffPacket.fromDictionary(wire))
            XCTAssertEqual(oldCheckpoint.id, packetA.id)
            XCTAssertFalse(oldCheckpoint.resumeReady)
            XCTAssertEqual(oldCheckpoint.runtimeJobContinuation, packetA.runtimeJobContinuation)
            XCTAssertEqual(oldCheckpoint.resumeSeed, "Exact authored successor seed")
            let oldRecord = try XCTUnwrap(app.store.interactiveContinuityHandoffRecord(packetID: packetA.id))
            XCTAssertEqual(oldRecord.isSealed, sealPrior)
            let packetB = try app.continuity.budgetRuntimeCheckpoint(clientID: fixture.context.clientID,
                reason: "successor checkpoint epoch", context: fixture.context, scopeKey: fixture.key,
                blockProgress: true, cancellation: nil)
            XCTAssertNotEqual(packetB.id, packetA.id)
            XCTAssertNotEqual(packetB.runtimeJobContinuation?.originEpoch, packetA.runtimeJobContinuation?.originEpoch)
            XCTAssertEqual(packetB.runtimeJobContinuation?.submissions.map(\.jobID), [second.jobID])
            XCTAssertEqual(packetB.goal, "Edited authored task")
            XCTAssertEqual(packetB.resumeSeed, "Exact authored successor seed")
            XCTAssertTrue(packetB.resumeSeedIsCustom)
            let retained = try XCTUnwrap(app.store.interactiveContinuityHandoffRecord(packetID: packetA.id))
            XCTAssertEqual(retained.packet, oldRecord.packet)
            XCTAssertEqual(retained.writeSequence, oldRecord.writeSequence)
            XCTAssertEqual(retained.runtimeScopeKey, oldRecord.runtimeScopeKey)
            XCTAssertEqual(retained.sealedSequence, oldRecord.sealedSequence)
            XCTAssertTrue(try app.continuityAutomation.clearBlockReportingResult(
                clientID: fixture.context.clientID, packet: packetB, cancellation: nil))
            XCTAssertFalse(app.continuityAutomation.isBlocked(fixture.context.clientID))
        }
    }

    func testOrdinaryRuntimeStatusSidecarRequiresCurrentJobGrantAndMissingRecordsStayUnresolved() throws {
        let client = ClientID("ordinary-sidecar-missing")
        let fixture = try ordinaryRuntimeReferenceFixture(client: client)
        let app = fixture.app
        defer { app.shutdown() }
        let record = ordinaryRuntimeReferenceRecord(context: fixture.context)
        let admission = try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: fixture.context, cancellation: nil))
        try admission(record)
        let packet = try app.continuity.budgetRuntimeCheckpoint(clientID: client,
            reason: "owned missing CP row", context: fixture.context, scopeKey: fixture.key,
            blockProgress: false, cancellation: nil)
        let canonical = try JSONSupport.data(from: packet.asDictionary())
        let other = ordinaryRuntimeReferenceRecord(context: fixture.context)
        let otherAdmission = try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: fixture.context, cancellation: nil))
        try otherAdmission(other)
        let newest = try app.continuity.persistRuntimeModelPacket(arguments: [
            "goal": "A different newer handoff", "cwd": try XCTUnwrap(tempHome).path,
        ], clientID: client, context: fixture.context, scopeKey: fixture.key, finalize: true, cancellation: nil)
        XCTAssertNotEqual(newest["handoff_id"] as? String, packet.id)
        let resumed = try app.tools.call(name: "get_forge_status", arguments: [
            "resume": true, "handoff_id": packet.id,
        ], clientID: client)
        XCTAssertTrue(resumed.ok)
        let sidecar = try XCTUnwrap(resumed.payload["runtime_continuation_status"] as? [String: Any])
        XCTAssertEqual(sidecar["handoff_id"] as? String, packet.id)
        let entries = try XCTUnwrap(sidecar["submissions"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["job_id"] as? String, record.jobID.uuidString.lowercased())
        XCTAssertEqual(entries[0]["available"] as? Bool, false)
        XCTAssertEqual(entries[0]["state"] as? String, "unresolved")
        XCTAssertEqual(entries[0]["replay_permitted"] as? Bool, false)
        XCTAssertNil(entries[0]["exit_code"])
        XCTAssertNil(entries[0]["eof"])
        XCTAssertEqual(resumed.payload["context_budget_cleared"] as? Bool, false)
        XCTAssertEqual(try app.store.runtimeContinuityProgress(scopeKey: fixture.key)?.runtimeJobSubmissions?.map(\.jobID),
            [record.jobID, other.jobID])
        XCTAssertFalse(try JSONSupport.string(from: sidecar).contains(record.commandSummary))
        XCTAssertEqual(try JSONSupport.data(from: XCTUnwrap(app.store.handoffLegacyGet(id: packet.id)).asDictionary()), canonical)
        let deniedClient = ClientID("ordinary-sidecar-no-status-grant")
        let initialized = try app.projectMemory.initializeUnchecked(path: try XCTUnwrap(tempHome).path)
        let descriptor = try app.projectMemory.identities.descriptor(projectID: XCTUnwrap(initialized["project_id"] as? String))
        let denied = try app.projectContexts.registerAndBindMCPClientUnchecked(descriptor: descriptor,
            canonicalRoot: try XCTUnwrap(tempHome), clientID: deniedClient,
            allowedTools: ["get_forge_status", "process.run", "session_checkpoint"])
        let deniedKey = app.continuityAutomation.runtimeScopeKey(denied)
        let deniedAdmission = try XCTUnwrap(app.continuityAutomation.prepareOrdinaryRuntimeJobAdmission(
            tool: "process.run", context: denied, cancellation: nil))
        try deniedAdmission(ordinaryRuntimeReferenceRecord(context: denied))
        let deniedPacket = try app.continuity.budgetRuntimeCheckpoint(clientID: deniedClient,
            reason: "owned denied status", context: denied, scopeKey: deniedKey,
            blockProgress: false, cancellation: nil)
        let response = try app.tools.call(name: "get_forge_status", arguments: [
            "resume": true, "handoff_id": deniedPacket.id,
        ], clientID: deniedClient)
        XCTAssertTrue(response.ok)
        let unavailable = try XCTUnwrap(response.payload["runtime_continuation_status"] as? [String: Any])
        XCTAssertEqual(unavailable["available"] as? Bool, false)
        XCTAssertEqual(unavailable["reason"] as? String, "current_job_authorization_required")
        XCTAssertNil(unavailable["submissions"])
    }

    func testOrdinaryRuntimeStatusSidecarExistingJobUsesAllowlistWithoutReplayOrPacketMutation() async throws {
        let client = ClientID("ordinary-sidecar-existing")
        let fixture = try ordinaryRuntimeReferenceFixture(client: client)
        let app = fixture.app
        defer { app.shutdown() }
        let marker = "FORGE-ORDINARY-SIDECAR-OUTPUT"
        let submitted = try app.tools.call(name: "process.run", arguments: [
            "executable": "/usr/bin/printf", "arguments": ["%s\n", marker],
            "cwd": try XCTUnwrap(tempHome).path, "timeout_sec": 5,
            "replay_class": RuntimeReplayClass.readOnly.rawValue,
        ], clientID: client)
        XCTAssertTrue(submitted.ok, "\(submitted.payload)")
        let jobID = try XCTUnwrap((submitted.payload["job_id"] as? String).flatMap(UUID.init(uuidString:)))
        let terminal = try await app.runtimeJobs.service.waitForTerminal(
            jobID: jobID, context: fixture.context, maximumWait: .seconds(5))
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertEqual(terminal.exitCode, 0)
        let outputBefore = try await app.runtimeJobs.service.readOutput(
            jobID: jobID, stream: .stdout, offset: 0, limit: 256, context: fixture.context)
        XCTAssertTrue(outputBefore.eof)
        XCTAssertEqual(String(decoding: outputBefore.data, as: UTF8.self), marker + "\n")
        let packet = try app.continuity.budgetRuntimeCheckpoint(clientID: client,
            reason: "owned completed job status", context: fixture.context, scopeKey: fixture.key,
            blockProgress: false, cancellation: nil)
        let before = try JSONSupport.data(from: packet.asDictionary())
        let jobsBefore = try await app.runtimeJobs.service.list(context: fixture.context)
        XCTAssertEqual(jobsBefore.map(\.jobID), [jobID])
        let allowed: Set<String> = ["submission_id", "job_id", "tool", "available", "state", "exit_code", "replay_permitted"]
        for _ in 0..<2 {
            let response = try app.tools.call(name: "get_forge_status", arguments: [
                "resume": true, "handoff_id": packet.id,
            ], clientID: client)
            XCTAssertTrue(response.ok)
            let sidecar = try XCTUnwrap(response.payload["runtime_continuation_status"] as? [String: Any])
            let entries = try XCTUnwrap(sidecar["submissions"] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(Set(entries[0].keys), allowed)
            XCTAssertEqual(entries[0]["job_id"] as? String, jobID.uuidString.lowercased())
            XCTAssertEqual(entries[0]["available"] as? Bool, true)
            XCTAssertEqual(entries[0]["state"] as? String, RuntimeJobState.completed.rawValue)
            XCTAssertEqual(entries[0]["exit_code"] as? Int32, 0)
            XCTAssertEqual(entries[0]["replay_permitted"] as? Bool, false)
            XCTAssertFalse(try JSONSupport.string(from: sidecar).contains(marker))
            XCTAssertEqual(try JSONSupport.data(from: XCTUnwrap(app.store.handoffLegacyGet(id: packet.id)).asDictionary()), before)
        }
        let jobsAfter = try await app.runtimeJobs.service.list(context: fixture.context)
        XCTAssertEqual(jobsAfter, jobsBefore)
        let outputAfter = try await app.runtimeJobs.service.readOutput(
            jobID: jobID, stream: .stdout, offset: 0, limit: 256, context: fixture.context)
        XCTAssertEqual(outputAfter.data, outputBefore.data)
        XCTAssertEqual(outputAfter.sha256, outputBefore.sha256)
        XCTAssertEqual(outputAfter.totalObservedBytes, outputBefore.totalObservedBytes)
    }
}

private enum SQLiteFixtureError: Error {
    case failure(String)
}

private enum ThrowingLoopToolPackError: Error {
    case forced
}

private struct ThrowingLoopToolPack: ToolPackHandling {
    var toolNames = ["throwing_test_tool"]

    func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        guard toolNames.contains(name) else { return nil }
        try cancellation?.checkCancellation()
        throw ThrowingLoopToolPackError.forced
    }
}

private func withSQLiteFixture(
    at url: URL,
    flags: Int32 = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
    _ body: (OpaquePointer) throws -> Void
) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite open error"
        if let database { sqlite3_close(database) }
        throw SQLiteFixtureError.failure(message)
    }
    defer { sqlite3_close(database) }
    try body(database)
}

private func executeSQLiteFixture(_ database: OpaquePointer, sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
        sqlite3_free(errorMessage)
        throw SQLiteFixtureError.failure(message)
    }
}

private func bindSQLiteFixture(_ statement: OpaquePointer, index: Int32, value: String) {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    value.withCString { pointer in
        _ = sqlite3_bind_text(statement, index, pointer, -1, transient)
    }
}

private func sqliteFixtureInt(at url: URL, sql: String) throws -> Int {
    var result: Int?
    try withSQLiteFixture(at: url) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteFixtureError.failure(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteFixtureError.failure(String(cString: sqlite3_errmsg(database)))
        }
        result = Int(sqlite3_column_int64(statement, 0))
    }
    return try XCTUnwrap(result)
}

private func sqliteFixtureText(at url: URL, sql: String) throws -> String? {
    var result: String?
    try withSQLiteFixture(at: url, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteFixtureError.failure(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteFixtureError.failure(String(cString: sqlite3_errmsg(database)))
        }
        result = sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }
    return result
}

private func exchangeSQLiteFixturePaths(_ first: URL, _ second: URL) throws {
    let result = first.path.withCString { firstPath in
        second.path.withCString { secondPath in
            Darwin.renamex_np(firstPath, secondPath, UInt32(RENAME_SWAP))
        }
    }
    guard result == 0 else {
        throw SQLiteFixtureError.failure(
            "could not atomically exchange SQLite fixtures: "
                + String(cString: strerror(errno))
        )
    }
}

private final class LockedFailureMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

// Shared by the native migration and ingress process-termination tests.
final class MigrationXCTestFixture {
    let process: Process
    private let output: Pipe
    private let error: Pipe

    init(process: Process, output: Pipe, error: Pipe) {
        self.process = process
        self.output = output
        self.error = error
    }

    func diagnostics() -> String {
        guard !process.isRunning else { return "migration child is still running" }
        let standardOutput = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let standardError = String(
            data: error.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return "stdout: \(standardOutput)\nstderr: \(standardError)"
    }

    func close() {
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        try? output.fileHandleForReading.close()
        try? error.fileHandleForReading.close()
    }

    deinit { close() }
}

private enum MigrationXCTestFixtureError: Error, LocalizedError {
    case failed(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .failed(let detail): "Migration subprocess failed: \(detail)"
        case .timeout(let detail): "Migration subprocess timed out: \(detail)"
        }
    }
}

func launchMigrationXCTestFixture(
    testIdentifier: String,
    environment additions: [String: String]
) throws -> MigrationXCTestFixture {
    let discovery = try ProcessRunner().run(
        executable: "/usr/bin/xcrun",
        arguments: ["--find", "xctest"],
        timeoutSec: 5,
        maximumOutputBytes: 4_096
    )
    let executablePath = discovery.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard discovery.exitCode == 0,
          !discovery.timedOut,
          !discovery.stdoutTruncated,
          !executablePath.isEmpty,
          FileManager.default.isExecutableFile(atPath: executablePath) else {
        throw MigrationXCTestFixtureError.failed(
            "xctest discovery failed: \(discovery.stderr)"
        )
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = [
        "-XCTest",
        testIdentifier,
        Bundle(for: ContinuityTests.self).bundleURL.path,
    ]
    var environment = ProcessInfo.processInfo.environment
    // A nested xctest must not inherit the parent runner's managed session or
    // configuration; those override the explicit -XCTest selector above.
    for key in ["XCTestSessionIdentifier", "XCTestConfigurationFilePath"] {
        environment.removeValue(forKey: key)
    }
    for (key, value) in additions { environment[key] = value }
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    return MigrationXCTestFixture(process: process, output: output, error: error)
}

func waitForMigrationMarker(
    _ markerURL: URL,
    child: MigrationXCTestFixture,
    timeout: TimeInterval
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: markerURL.path) { return }
        guard child.process.isRunning else {
            throw MigrationXCTestFixtureError.failed(child.diagnostics())
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard FileManager.default.fileExists(atPath: markerURL.path) else {
        throw MigrationXCTestFixtureError.timeout(
            child.process.isRunning ? "ready marker was not written" : child.diagnostics()
        )
    }
}

func forceKillMigrationXCTestFixture(
    _ child: MigrationXCTestFixture,
    timeout: TimeInterval
) throws -> (reason: Process.TerminationReason, status: Int32) {
    guard child.process.isRunning else {
        throw MigrationXCTestFixtureError.failed(
            "child exited before SIGKILL; \(child.diagnostics())"
        )
    }
    guard Darwin.kill(child.process.processIdentifier, SIGKILL) == 0 else {
        throw MigrationXCTestFixtureError.failed(
            "SIGKILL failed with errno \(errno)"
        )
    }
    let deadline = Date().addingTimeInterval(timeout)
    while child.process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard !child.process.isRunning else {
        throw MigrationXCTestFixtureError.timeout(
            "child did not confirm termination after SIGKILL"
        )
    }
    return (child.process.terminationReason, child.process.terminationStatus)
}

private final class MCPProcessFixture {
    var process: Process
    var input: Pipe
    var output: Pipe
    var error: Pipe
    var capturedOutput = Data()

    init(process: Process, input: Pipe, output: Pipe, error: Pipe) {
        self.process = process
        self.input = input
        self.output = output
        self.error = error
    }

    func close() {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? error.fileHandleForReading.close()
    }

    deinit { close() }
}

private enum MCPProcessFixtureError: Error {
    case timeout(String)
    case failed(String)
}

private func locateContinuityCLIBinary() -> URL? {
    let products = Bundle(for: ContinuityTests.self).bundleURL.deletingLastPathComponent()
    let adjacent = products.appendingPathComponent("forge-conductor")
    if FileManager.default.isExecutableFile(atPath: adjacent.path) {
        return adjacent
    }
    return nil
}

private func launchMCPFixture(binary: URL, home: URL, role: String) throws -> MCPProcessFixture {
    let process = Process()
    process.executableURL = binary
    process.arguments = ["serve"]
    var environment = ProcessInfo.processInfo.environment
    environment["FORGE_CONDUCTOR_HOME"] = home.path
    environment["FORGE_MCP_ROLE"] = role
    environment["FORGE_DEPLOYMENT_ID"] = "continuity-process-test"
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    try process.run()
    return MCPProcessFixture(process: process, input: input, output: output, error: error)
}

private func sendMCPHandoff(_ fixture: MCPProcessFixture, id: Int, goal: String) throws {
    let initialize: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-11-25",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "continuity-process-test", "version": "1"],
        ] as [String: Any],
    ]
    let handoff: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": [
            "name": "session_handoff",
            "arguments": ["goal": goal],
        ] as [String: Any],
    ]
    let payload = try JSONSupport.string(from: initialize) + "\n"
        + JSONSupport.string(from: handoff) + "\n"
    fixture.input.fileHandleForWriting.write(Data(payload.utf8))
    try waitForMCPResponseFrames(fixture, minimumCount: 2, timeout: 10)
    try fixture.input.fileHandleForWriting.close()
}

private func waitForMCPResponseFrames(
    _ fixture: MCPProcessFixture,
    minimumCount: Int,
    timeout: TimeInterval
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while fixture.capturedOutput.filter({ $0 == 0x0A }).count < minimumCount {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw MCPProcessFixtureError.timeout("MCP responses did not arrive before disconnect")
        }
        var descriptor = pollfd(
            fd: fixture.output.fileHandleForReading.fileDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        let milliseconds = Int32(max(1, min(remaining * 1_000, Double(Int32.max))))
        let pollResult = Darwin.poll(&descriptor, 1, milliseconds)
        if pollResult < 0, errno == EINTR { continue }
        guard pollResult > 0 else {
            if pollResult == 0 { continue }
            throw MCPProcessFixtureError.failed(
                "MCP response poll failed: \(String(cString: strerror(errno)))"
            )
        }
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        let count = Darwin.read(descriptor.fd, &buffer, buffer.count)
        guard count > 0 else {
            if count < 0, errno == EINTR { continue }
            throw MCPProcessFixtureError.failed(
                count == 0
                    ? "MCP response stream closed before all responses arrived"
                    : "MCP response read failed: \(String(cString: strerror(errno)))"
            )
        }
        fixture.capturedOutput.append(contentsOf: buffer.prefix(count))
    }
}

private func waitForMCPFixture(
    _ fixture: MCPProcessFixture,
    timeout: TimeInterval
) throws -> [[String: Any]] {
    let deadline = Date().addingTimeInterval(timeout)
    while fixture.process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    guard !fixture.process.isRunning else {
        fixture.process.terminate()
        throw MCPProcessFixtureError.timeout("MCP process did not exit after stdin closed")
    }
    var outputData = fixture.capturedOutput
    outputData.append(fixture.output.fileHandleForReading.readDataToEndOfFile())
    let errorData = fixture.error.fileHandleForReading.readDataToEndOfFile()
    guard fixture.process.terminationStatus == 0 else {
        let stderr = String(data: errorData, encoding: .utf8) ?? ""
        throw MCPProcessFixtureError.failed(stderr)
    }
    return try outputData.split(separator: 0x0A, omittingEmptySubsequences: true).map { line in
        try JSONSupport.object(from: Data(line))
    }
}

// This Clock belongs only to ContextContinuityService. Its sole packet-building
// clock read is after the pending claim commit and before the handoff transaction.
// The store and ContinuityAutomation keep their normal FixedClock, so holding
// this gate never holds SQLite's progress transaction or changes expiry time.
private final class FinalReviewPacketBuildClock: ForgeConductorCore.Clock, @unchecked Sendable {
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let date: Date
    private var armed = false
    private var timedOut = false

    init(_ date: Date) { self.date = date }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func now() -> Date {
        lock.lock()
        let shouldPause = armed
        armed = false
        lock.unlock()
        if shouldPause {
            reached.signal()
            if release.wait(timeout: .now() + 5) != .success {
                lock.lock(); timedOut = true; lock.unlock()
            }
        }
        return date
    }
}

private final class FinalReviewContinuityObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuityObservation?
    func set(_ value: ContinuityObservation?) { lock.lock(); self.value = value; lock.unlock() }
    var snapshot: ContinuityObservation? { lock.lock(); defer { lock.unlock() }; return value }
}

extension ContinuityTests {
    func testRuntimeContinuityCrossedRolloverLimitIsServicedWhenPendingCheckpointCompletes() throws {
        try assertFinalReviewPendingCheckpoint(crossThresholdWhilePending: true)
    }

    func testRuntimeContinuityPendingCheckpointBelowRolloverLimitPreservesOpenPacket() throws {
        try assertFinalReviewPendingCheckpoint(crossThresholdWhilePending: false)
    }

    private func assertFinalReviewPendingCheckpoint(crossThresholdWhilePending: Bool) throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let primary = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { primary.shutdown() }
        let client = MCPServer.defaultClientID(deploymentID: "review-pending-checkpoint-deployment",
            role: .primary, desktopProviderID: nil)
        try bindProjectContext(primary, clientID: client)
        _ = try primary.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 251))
        _ = try primary.config.update(["allowed_roots": [tempHome.path]], save: true)
        let fallback = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { fallback.shutdown() }
        let context = try primary.projectContexts.invocationContext(for: client)
        let key = primary.continuityAutomation.runtimeScopeKey(context)
        _ = try primary.store.updateRuntimeContinuityProgress(scopeKey: key) { progress in
            progress.progressCount = 249
            progress.lastCheckpointCount = 200
            progress.startedAt = clock.now()
            progress.lastCheckpointAt = clock.now()
            progress.lastTools = ["fs_read"]
            progress.lastPaths = [tempHome.path]
        }
        let path = tempHome.appendingPathComponent("pending-checkpoint-owned.txt")
        try "Bounded current-project read evidence\n".write(to: path, atomically: true, encoding: .utf8)

        let packetClock = FinalReviewPacketBuildClock(clock.now())
        let gatedContinuity = ContextContinuityService(paths: primary.paths, store: primary.store,
            sessions: primary.sessions, diagnostics: primary.diagnostics, clock: packetClock)
        let owner = ContinuityAutomation(store: primary.store, sessions: primary.sessions,
            continuity: gatedContinuity, diagnostics: primary.diagnostics, clock: clock,
            projectContexts: primary.projectContexts, configStore: primary.config)
        let ownerResult = FinalReviewContinuityObservationBox()
        let finished = DispatchGroup()
        packetClock.arm()
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            ownerResult.set(owner.observe(tool: "fs_read", arguments: ["path": path.path],
                clientID: client, succeeded: true))
        }
        defer {
            packetClock.release.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 6), .success,
                "The owned observer must finish before its app/store are shut down")
        }
        XCTAssertEqual(packetClock.reached.wait(timeout: .now() + 2), .success)
        let held = try XCTUnwrap(fallback.store.runtimeContinuityProgress(scopeKey: key))
        let claim = try XCTUnwrap(held.pending)
        XCTAssertEqual(held.progressCount, 250)
        XCTAssertEqual(claim.progressCount, 250)
        XCTAssertFalse(claim.finalize)
        XCTAssertGreaterThan(claim.expiresAt, clock.now())
        XCTAssertNil(try fallback.store.handoffGet(id: claim.packetID))

        if crossThresholdWhilePending {
            // Real ToolRouter execution against another app/store connection.
            // No fourth call is supplied after the pending owner resumes.
            let result = try fallback.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: client)
            XCTAssertTrue(result.ok, "Keep the successful read outcome: \(result.payload)")
            XCTAssertFalse(result.isError)
            XCTAssertEqual(try fallback.store.runtimeContinuityProgress(scopeKey: key)?.progressCount, 251)
        }
        packetClock.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 6), .success)
        XCTAssertFalse(packetClock.didTimeOut, "Gate expiry is not a successful competing-writer reproduction")
        let observation = try XCTUnwrap(ownerResult.snapshot)
        let after = try XCTUnwrap(fallback.store.runtimeContinuityProgress(scopeKey: key))
        let committed = try XCTUnwrap(fallback.store.handoffGet(id: claim.packetID))
        XCTAssertNil(after.pending)
        XCTAssertEqual(after.progressCount, crossThresholdWhilePending ? 251 : 250)
        XCTAssertEqual(after.latestPacketID, claim.packetID)
        XCTAssertEqual(try fallback.store.runtimeContinuityPacketScopeKey(packetID: committed.id), key)
        XCTAssertEqual(committed.cwd, tempHome.path)
        XCTAssertEqual(try fallback.store.handoffLegacyList(limit: 100).count, 1,
            "Checkpoint-to-handoff promotion must retain one current open packet identity")
        if crossThresholdWhilePending {
            XCTAssertTrue(after.blocked,
                "A successful pending checkpoint completion must service the already-crossed limit without another tool call")
            XCTAssertEqual(after.lastHandoffID, claim.packetID)
            XCTAssertTrue(committed.resumeReady)
            XCTAssertTrue(observation.finalize)
            let resumed = try fallback.tools.call(name: "get_forge_status", arguments: [
                "resume": true, "handoff_id": claim.packetID,
                "rollover_nonce": ContextContinuityService.interactiveRolloverNonce(handoffID: claim.packetID),
            ], clientID: client)
            XCTAssertTrue(resumed.ok)
            XCTAssertEqual(resumed.payload["context_budget_cleared"] as? Bool, true)
            let next = try XCTUnwrap(primary.store.runtimeContinuityProgress(scopeKey: key))
            XCTAssertNotEqual(next.epoch, held.epoch)
            XCTAssertEqual(next.progressCount, 0)
            XCTAssertFalse(next.blocked)
            XCTAssertEqual(try primary.store.handoffGet(id: committed.id), committed)
        } else {
            // Same gate, same checkpoint cadence; no premature rollover below 251.
            XCTAssertFalse(after.blocked)
            XCTAssertFalse(committed.resumeReady)
            XCTAssertFalse(observation.finalize)
            XCTAssertEqual(after.lastCheckpointCount, 250)
            let result = try fallback.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: client)
            XCTAssertTrue(result.ok)
            XCTAssertEqual(result.payload["handoff_id"] as? String, claim.packetID)
            XCTAssertTrue(try primary.store.runtimeContinuityProgress(scopeKey: key)?.blocked == true)
            XCTAssertTrue(try primary.store.handoffGet(id: claim.packetID)?.resumeReady == true)
        }
    }
}

private final class FinalReviewSecondObservationClock: ForgeConductorCore.Clock, @unchecked Sendable {
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let date: Date
    private var count = 0
    private var timedOut = false
    init(_ date: Date) { self.date = date }
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func now() -> Date {
        lock.lock(); count += 1; let shouldPause = count == 2; lock.unlock()
        if shouldPause {
            reached.signal()
            if release.wait(timeout: .now() + 5) != .success {
                lock.lock(); timedOut = true; lock.unlock()
            }
        }
        return date
    }
}

private final class FinalReviewCheckpointFailureOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var count = 0
    func arm() { lock.lock(); enabled = true; lock.unlock() }
    var failureCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func shouldFail() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return false }
        enabled = false
        count += 1
        return true
    }
}

extension ContinuityTests {
    func testRuntimeContinuityExpiredCheckpointAdoptedBySecondPassServicesCrossedLimit() throws {
        try assertFinalReviewExpiredSecondClaim(crossLimit: true)
    }

    func testRuntimeContinuityExpiredCheckpointAdoptedBySecondPassStaysOpenBelowLimit() throws {
        try assertFinalReviewExpiredSecondClaim(crossLimit: false)
    }

    private func assertFinalReviewExpiredSecondClaim(crossLimit: Bool) throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let app = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { app.shutdown() }
        let client = MCPServer.defaultClientID(deploymentID: "expired-second-claim-deployment",
            role: .primary, desktopProviderID: nil)
        try bindProjectContext(app, clientID: client)
        _ = try app.config.update(["allowed_roots": [tempHome.path]])
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 101))
        let competing = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { competing.shutdown() }
        let context = try app.projectContexts.invocationContext(for: client)
        let key = app.continuityAutomation.runtimeScopeKey(context)
        let path = tempHome.appendingPathComponent("expired-second-claim-owned.txt")
        try "Owned current-project evidence\n".write(to: path, atomically: true, encoding: .utf8)
        _ = try app.store.updateRuntimeContinuityProgress(scopeKey: key) { progress in
            progress.progressCount = 49
            progress.startedAt = clock.now()
        }

        // A's injected clock is used only by Automation. Its second now() is
        // the accountProgress:false pass, after checkpoint50 is already committed.
        let secondPassClock = FinalReviewSecondObservationClock(clock.now())
        let ownerA = ContinuityAutomation(store: app.store, sessions: app.sessions,
            continuity: app.continuity, diagnostics: app.diagnostics, clock: secondPassClock,
            projectContexts: app.projectContexts, configStore: app.config)
        let fault = FinalReviewCheckpointFailureOnce()
        let faultStore = try SQLiteStore(path: app.paths.storeSQLite, clock: clock,
            postMigrationCommitObserver: nil, beforeMutationCommitObserver: { kind in
                if kind == .handoff, fault.shouldFail() {
                    throw StoreError.execFailed("injected checkpoint100 commit failure")
                }
            })
        defer { faultStore.close() }
        let packetClock = FinalReviewPacketBuildClock(clock.now())
        let serviceB = ContextContinuityService(paths: app.paths, store: faultStore,
            sessions: app.sessions, diagnostics: app.diagnostics, clock: packetClock)
        let ownerB = ContinuityAutomation(store: faultStore, sessions: app.sessions,
            continuity: serviceB, diagnostics: app.diagnostics, clock: clock,
            projectContexts: app.projectContexts, configStore: app.config)
        let boxA = FinalReviewContinuityObservationBox()
        let boxB = FinalReviewContinuityObservationBox()
        let finishedA = DispatchGroup()
        let finishedB = DispatchGroup()
        defer {
            packetClock.release.signal()
            secondPassClock.release.signal()
            XCTAssertEqual(finishedB.wait(timeout: .now() + 6), .success)
            XCTAssertEqual(finishedA.wait(timeout: .now() + 6), .success)
        }
        finishedA.enter()
        DispatchQueue.global().async {
            defer { finishedA.leave() }
            boxA.set(ownerA.observe(tool: "fs_read", arguments: ["path": path.path], clientID: client, succeeded: true))
        }
        XCTAssertEqual(secondPassClock.reached.wait(timeout: .now() + 2), .success)
        let firstCommit = try XCTUnwrap(competing.store.runtimeContinuityProgress(scopeKey: key))
        XCTAssertEqual(firstCommit.progressCount, 50)
        XCTAssertEqual(firstCommit.lastCheckpointCount, 50)
        XCTAssertNil(firstCommit.pending)
        let packetID = try XCTUnwrap(firstCommit.latestPacketID)
        let packet50 = try XCTUnwrap(competing.store.handoffGet(id: packetID))
        XCTAssertFalse(packet50.resumeReady)

        // Seed the same valid earlier-call baseline used by the existing threshold
        // fixtures; actual pending claims are created only by the observers below.
        _ = try competing.store.updateRuntimeContinuityProgress(scopeKey: key) { progress in
            progress.progressCount = 99
        }
        packetClock.arm()
        fault.arm()
        finishedB.enter()
        DispatchQueue.global().async {
            defer { finishedB.leave() }
            boxB.set(ownerB.observe(tool: "fs_read", arguments: ["path": path.path], clientID: client, succeeded: true))
        }
        XCTAssertEqual(packetClock.reached.wait(timeout: .now() + 2), .success)
        let claimed = try XCTUnwrap(competing.store.runtimeContinuityProgress(scopeKey: key))
        let claim100 = try XCTUnwrap(claimed.pending)
        XCTAssertEqual(claimed.progressCount, 100)
        XCTAssertEqual(claim100.progressCount, 100)
        XCTAssertFalse(claim100.finalize)
        XCTAssertEqual(claim100.packetID, packetID)
        XCTAssertEqual(claim100.epoch, firstCommit.epoch)
        XCTAssertGreaterThan(claim100.expiresAt, clock.now())
        if crossLimit {
            let read = try competing.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: client)
            XCTAssertTrue(read.ok)
            XCTAssertFalse(read.isError)
            XCTAssertEqual(try competing.store.runtimeContinuityProgress(scopeKey: key)?.progressCount, 101)
        }
        packetClock.release.signal()
        XCTAssertEqual(finishedB.wait(timeout: .now() + 6), .success)
        XCTAssertFalse(packetClock.didTimeOut)
        XCTAssertEqual(fault.failureCount, 1)
        XCTAssertNil(boxB.snapshot)
        let failed = try XCTUnwrap(competing.store.runtimeContinuityProgress(scopeKey: key))
        let retryable = try XCTUnwrap(failed.pending)
        XCTAssertEqual(retryable.packetID, claim100.packetID)
        XCTAssertEqual(retryable.ownerID, claim100.ownerID)
        XCTAssertEqual(retryable.epoch, claim100.epoch)
        XCTAssertEqual(retryable.progressCount, 100)
        XCTAssertFalse(retryable.finalize)
        XCTAssertLessThanOrEqual(retryable.expiresAt, clock.now())
        XCTAssertEqual(try competing.store.handoffGet(id: packetID), packet50)

        secondPassClock.release.signal()
        XCTAssertEqual(finishedA.wait(timeout: .now() + 6), .success)
        XCTAssertFalse(secondPassClock.didTimeOut)
        let observation = try XCTUnwrap(boxA.snapshot)
        let after = try XCTUnwrap(competing.store.runtimeContinuityProgress(scopeKey: key))
        let saved = try XCTUnwrap(competing.store.handoffGet(id: packetID))
        XCTAssertNil(after.pending)
        XCTAssertEqual(after.epoch, firstCommit.epoch)
        XCTAssertEqual(after.progressCount, crossLimit ? 101 : 100)
        XCTAssertEqual(after.failureCount, 0, "Checkpoint persistence failure is not an extra model tool attempt")
        XCTAssertEqual(after.latestPacketID, packetID)
        XCTAssertEqual(try competing.store.handoffLegacyList(limit: 100).count, 1)
        if crossLimit {
            XCTAssertTrue(after.blocked, "The bounded second pass must service an already-due handoff even when adopting an expired checkpoint")
            XCTAssertEqual(after.lastHandoffID, packetID)
            XCTAssertTrue(saved.resumeReady)
            XCTAssertTrue(observation.finalize)
            XCTAssertEqual(after.lastHandoffCount, 101)
        } else {
            XCTAssertFalse(after.blocked)
            XCTAssertFalse(saved.resumeReady)
            XCTAssertFalse(observation.finalize)
            XCTAssertEqual(after.lastCheckpointCount, 100)
            let next = try competing.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: client)
            XCTAssertTrue(next.ok)
            XCTAssertEqual(next.payload["handoff_id"] as? String, packetID)
            XCTAssertEqual(try competing.store.runtimeContinuityProgress(scopeKey: key)?.progressCount, 101)
            XCTAssertTrue(try competing.store.runtimeContinuityProgress(scopeKey: key)?.blocked == true)
        }
    }
}

extension ContinuityTests {
    func testRuntimeContinuityLimitCrossedWhileSecondAdoptedCheckpointBuildsCommitsExactHandoff() throws {
        try assertFinalReviewSecondCheckpointBuild(crossLimit: true)
    }

    func testRuntimeContinuitySecondAdoptedCheckpointBelowLimitPreservesOpenPacket() throws {
        try assertFinalReviewSecondCheckpointBuild(crossLimit: false)
    }

    private func assertFinalReviewSecondCheckpointBuild(crossLimit: Bool) throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let app = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { app.shutdown() }
        let client = MCPServer.defaultClientID(deploymentID: "second-checkpoint-build-deployment",
            role: .primary, desktopProviderID: nil)
        try bindProjectContext(app, clientID: client)
        _ = try app.config.update(["allowed_roots": [tempHome.path]])
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 101))
        let competing = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { competing.shutdown() }
        let context = try app.projectContexts.invocationContext(for: client)
        let key = app.continuityAutomation.runtimeScopeKey(context)
        let path = tempHome.appendingPathComponent("second-checkpoint-build-owned.txt")
        try "Owned current-project evidence\n".write(to: path, atomically: true, encoding: .utf8)
        _ = try app.store.updateRuntimeContinuityProgress(scopeKey: key) { progress in
            progress.progressCount = 49
            progress.startedAt = clock.now()
        }

        // A's injected clock is used only by Automation. Its second now() is
        // the accountProgress:false pass, after checkpoint50 is already committed.
        let secondPassClock = FinalReviewSecondObservationClock(clock.now())
        let secondBuildClock = FinalReviewPacketBuildClock(clock.now())
        let serviceA = ContextContinuityService(paths: app.paths, store: app.store,
            sessions: app.sessions, diagnostics: app.diagnostics, clock: secondBuildClock)
        let ownerA = ContinuityAutomation(store: app.store, sessions: app.sessions,
            continuity: serviceA, diagnostics: app.diagnostics, clock: secondPassClock,
            projectContexts: app.projectContexts, configStore: app.config)
        let fault = FinalReviewCheckpointFailureOnce()
        let faultStore = try SQLiteStore(path: app.paths.storeSQLite, clock: clock,
            postMigrationCommitObserver: nil, beforeMutationCommitObserver: { kind in
                if kind == .handoff, fault.shouldFail() {
                    throw StoreError.execFailed("injected checkpoint100 commit failure")
                }
            })
        defer { faultStore.close() }
        let packetClock = FinalReviewPacketBuildClock(clock.now())
        let serviceB = ContextContinuityService(paths: app.paths, store: faultStore,
            sessions: app.sessions, diagnostics: app.diagnostics, clock: packetClock)
        let ownerB = ContinuityAutomation(store: faultStore, sessions: app.sessions,
            continuity: serviceB, diagnostics: app.diagnostics, clock: clock,
            projectContexts: app.projectContexts, configStore: app.config)
        let boxA = FinalReviewContinuityObservationBox()
        let boxB = FinalReviewContinuityObservationBox()
        let finishedA = DispatchGroup()
        let finishedB = DispatchGroup()
        defer {
            packetClock.release.signal()
            secondBuildClock.release.signal()
            secondPassClock.release.signal()
            XCTAssertEqual(finishedB.wait(timeout: .now() + 6), .success)
            XCTAssertEqual(finishedA.wait(timeout: .now() + 6), .success)
        }
        finishedA.enter()
        DispatchQueue.global().async {
            defer { finishedA.leave() }
            boxA.set(ownerA.observe(tool: "fs_read", arguments: ["path": path.path], clientID: client, succeeded: true))
        }
        XCTAssertEqual(secondPassClock.reached.wait(timeout: .now() + 2), .success)
        let firstCommit = try XCTUnwrap(competing.store.runtimeContinuityProgress(scopeKey: key))
        XCTAssertEqual(firstCommit.progressCount, 50)
        XCTAssertEqual(firstCommit.lastCheckpointCount, 50)
        XCTAssertNil(firstCommit.pending)
        let packetID = try XCTUnwrap(firstCommit.latestPacketID)
        let packet50 = try XCTUnwrap(competing.store.handoffGet(id: packetID))
        XCTAssertFalse(packet50.resumeReady)

        // Seed the same valid earlier-call baseline used by the existing threshold
        // fixtures; actual pending claims are created only by the observers below.
        _ = try competing.store.updateRuntimeContinuityProgress(scopeKey: key) { progress in
            progress.progressCount = 99
        }
        packetClock.arm()
        fault.arm()
        finishedB.enter()
        DispatchQueue.global().async {
            defer { finishedB.leave() }
            boxB.set(ownerB.observe(tool: "fs_read", arguments: ["path": path.path], clientID: client, succeeded: true))
        }
        XCTAssertEqual(packetClock.reached.wait(timeout: .now() + 2), .success)
        let claimed = try XCTUnwrap(competing.store.runtimeContinuityProgress(scopeKey: key))
        let claim100 = try XCTUnwrap(claimed.pending)
        XCTAssertEqual(claimed.progressCount, 100)
        XCTAssertEqual(claim100.progressCount, 100)
        XCTAssertFalse(claim100.finalize)
        XCTAssertEqual(claim100.packetID, packetID)
        XCTAssertEqual(claim100.epoch, firstCommit.epoch)
        XCTAssertGreaterThan(claim100.expiresAt, clock.now())
        packetClock.release.signal()
        XCTAssertEqual(finishedB.wait(timeout: .now() + 6), .success)
        XCTAssertFalse(packetClock.didTimeOut)
        XCTAssertEqual(fault.failureCount, 1)
        XCTAssertNil(boxB.snapshot)
        let failed = try XCTUnwrap(competing.store.runtimeContinuityProgress(scopeKey: key))
        let retryable = try XCTUnwrap(failed.pending)
        XCTAssertEqual(retryable.packetID, claim100.packetID)
        XCTAssertEqual(retryable.ownerID, claim100.ownerID)
        XCTAssertEqual(retryable.epoch, claim100.epoch)
        XCTAssertEqual(retryable.progressCount, 100)
        XCTAssertFalse(retryable.finalize)
        XCTAssertLessThanOrEqual(retryable.expiresAt, clock.now())
        XCTAssertEqual(try competing.store.handoffGet(id: packetID), packet50)

        // Let A's bounded follow-up adopt the expired checkpoint while still
        // BELOW the limit. The second packet-build gate is after this claim's
        // SQLite commit and before its packet mutation, so C can use the normal
        // tool router while A builds without holding a database lock.
        secondBuildClock.arm()
        secondPassClock.release.signal()
        XCTAssertEqual(secondBuildClock.reached.wait(timeout: .now() + 2), .success)
        let adopted = try XCTUnwrap(competing.store.runtimeContinuityProgress(scopeKey: key))
        let adoptedClaim = try XCTUnwrap(adopted.pending)
        XCTAssertEqual(adopted.progressCount, 100)
        XCTAssertEqual(adopted.failureCount, 0)
        XCTAssertFalse(adopted.blocked)
        XCTAssertEqual(adopted.lastCheckpointCount, 50)
        XCTAssertEqual(adoptedClaim.scopeKey, key)
        XCTAssertEqual(adoptedClaim.packetID, packetID)
        XCTAssertEqual(adoptedClaim.epoch, firstCommit.epoch)
        XCTAssertNotEqual(adoptedClaim.ownerID, retryable.ownerID)
        XCTAssertEqual(adoptedClaim.progressCount, 100)
        XCTAssertEqual(adoptedClaim.failureCount, 0)
        XCTAssertFalse(adoptedClaim.finalize)
        XCTAssertEqual(adoptedClaim.claimedAt, retryable.claimedAt)
        XCTAssertGreaterThan(adoptedClaim.expiresAt, clock.now())
        XCTAssertEqual(try competing.store.handoffGet(id: packetID), packet50,
            "No adopted packet has committed while the second build gate is held")
        if crossLimit {
            let read = try competing.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: client)
            XCTAssertTrue(read.ok)
            XCTAssertFalse(read.isError)
            XCTAssertNil(read.payload["handoff_id"], "The active second claim still owns packet persistence")
            let crossed = try XCTUnwrap(competing.store.runtimeContinuityProgress(scopeKey: key))
            XCTAssertEqual(crossed.progressCount, 101)
            XCTAssertEqual(crossed.failureCount, 0)
            XCTAssertEqual(crossed.pending, adoptedClaim,
                "The competing actual call must not steal a live claim or rewrite its snapshot")
            XCTAssertFalse(crossed.blocked)
        }
        secondBuildClock.release.signal()
        XCTAssertEqual(finishedA.wait(timeout: .now() + 6), .success)
        XCTAssertFalse(secondBuildClock.didTimeOut)
        XCTAssertFalse(secondPassClock.didTimeOut)
        let observation = try XCTUnwrap(boxA.snapshot)
        let after = try XCTUnwrap(competing.store.runtimeContinuityProgress(scopeKey: key))
        let saved = try XCTUnwrap(competing.store.handoffGet(id: packetID))
        XCTAssertNil(after.pending)
        XCTAssertEqual(after.epoch, firstCommit.epoch)
        XCTAssertEqual(after.progressCount, crossLimit ? 101 : 100)
        XCTAssertEqual(after.failureCount, 0, "Checkpoint persistence failure is not an extra model tool attempt")
        XCTAssertEqual(after.latestPacketID, packetID)
        XCTAssertEqual(try competing.store.runtimeContinuityPacketScopeKey(packetID: packetID), key)
        XCTAssertEqual(saved.cwd, packet50.cwd)
        XCTAssertEqual(saved.clientID, packet50.clientID)
        XCTAssertEqual(try competing.store.handoffLegacyList(limit: 100).count, 1)
        if crossLimit {
            XCTAssertTrue(after.blocked, "The exact second checkpoint commit must service the limit crossed during its build without a 102nd call")
            XCTAssertEqual(after.lastHandoffID, packetID)
            XCTAssertTrue(saved.resumeReady)
            XCTAssertTrue(observation.finalize)
            XCTAssertEqual(after.lastHandoffCount, 101)
        } else {
            XCTAssertFalse(after.blocked)
            XCTAssertFalse(saved.resumeReady)
            XCTAssertFalse(observation.finalize)
            XCTAssertEqual(after.lastCheckpointCount, 100)
            let next = try competing.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: client)
            XCTAssertTrue(next.ok)
            XCTAssertEqual(next.payload["handoff_id"] as? String, packetID)
            XCTAssertEqual(try competing.store.runtimeContinuityProgress(scopeKey: key)?.progressCount, 101)
            XCTAssertTrue(try competing.store.runtimeContinuityProgress(scopeKey: key)?.blocked == true)
        }
    }
}

extension ContinuityTests {
    func testRuntimeContinuityAtomicPromotionPreservesAuthoredTaskAndCustomSeed() throws {
        try assertRuntimeAtomicPromotionPacket(customSeed: true)
    }

    func testRuntimeContinuityAtomicPromotionRegeneratesDefaultSeedAndPublishesActualOutcome() throws {
        try assertRuntimeAtomicPromotionPacket(customSeed: false)
    }

    func testRuntimeContinuityAtomicPromotionProjectionFailureStillReturnsCommittedHandoff() throws {
        try assertRuntimeAtomicPromotionPacket(customSeed: false, projectionFails: true)
    }

    private func assertRuntimeAtomicPromotionPacket(customSeed: Bool, projectionFails: Bool = false) throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let app = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { app.shutdown() }
        let client = ClientID("atomic-packet-owner")
        try bindProjectContext(app, clientID: client)
        _ = try app.config.update(["allowed_roots": [tempHome.path]])
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 51))
        let context = try app.projectContexts.invocationContext(for: client)
        let key = app.continuityAutomation.runtimeScopeKey(context)
        let path = tempHome.appendingPathComponent("atomic-packet-evidence.txt")
        try "Native project evidence\n".write(to: path, atomically: true, encoding: .utf8)
        var arguments: [String: Any] = [
            "goal": "Preserve the authored task", "status": "exploration", "cwd": tempHome.path,
            "project_slug": "Authored project", "next_actions": ["Run the exact native check"],
            "blockers": ["Wait for the owned result"], "key_files": [path.path],
            "decisions": ["Keep native evidence"], "narrative": "Authored narrative",
        ]
        if customSeed { arguments["resume_seed"] = "Authored successor seed" }
        let saved = try app.tools.call(name: "session_checkpoint", arguments: arguments, clientID: client)
        XCTAssertTrue(saved.ok)
        let authoredID = try XCTUnwrap(saved.payload["handoff_id"] as? String)
        let authored = try XCTUnwrap(app.store.handoffLegacyGet(id: authoredID))
        _ = try app.store.updateRuntimeContinuityProgress(scopeKey: key) { progress in
            progress.progressCount = 49
            progress.startedAt = clock.now()
        }
        let packetClock = FinalReviewPacketBuildClock(clock.now())
        let service = ContextContinuityService(paths: app.paths, store: app.store,
            sessions: app.sessions, diagnostics: app.diagnostics, clock: packetClock)
        let owner = ContinuityAutomation(store: app.store, sessions: app.sessions,
            continuity: service, diagnostics: app.diagnostics, clock: clock,
            projectContexts: app.projectContexts, configStore: app.config)
        let box = FinalReviewContinuityObservationBox()
        let finished = DispatchGroup()
        packetClock.arm()
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            box.set(owner.observe(tool: "fs_read", arguments: ["path": path.path], clientID: client, succeeded: true))
        }
        defer {
            packetClock.release.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 6), .success)
        }
        XCTAssertEqual(packetClock.reached.wait(timeout: .now() + 2), .success)
        let held = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: key))
        let claim = try XCTUnwrap(held.pending)
        XCTAssertEqual(claim.progressCount, 50)
        XCTAssertFalse(claim.finalize)
        XCTAssertNil(held.rolloverRequested)
        if projectionFails {
            try FileManager.default.createDirectory(
                at: app.paths.memoryHandoffsDir.appendingPathComponent("\(claim.packetID).json"),
                withIntermediateDirectories: false)
        }
        let read = try app.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: client)
        XCTAssertTrue(read.ok)
        let due = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: key))
        XCTAssertEqual(due.progressCount, 51)
        XCTAssertEqual(due.pending, claim)
        XCTAssertEqual(due.rolloverRequested, true)
        packetClock.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 6), .success)
        XCTAssertFalse(packetClock.didTimeOut)
        let observation = try XCTUnwrap(box.snapshot)
        let packet = observation.packet
        XCTAssertTrue(observation.finalize)
        XCTAssertEqual(observation.reason, "auto_handoff progress=51 failed_tools=0")
        XCTAssertEqual(packet.id, claim.packetID)
        XCTAssertEqual(packet.goal, authored.goal)
        XCTAssertEqual(packet.nextActions, authored.nextActions)
        XCTAssertEqual(packet.blockers, authored.blockers)
        XCTAssertEqual(packet.keyFiles, authored.keyFiles)
        XCTAssertEqual(packet.decisions, authored.decisions)
        XCTAssertEqual(packet.projectSlug, authored.projectSlug)
        XCTAssertEqual(packet.cwd, authored.cwd)
        XCTAssertEqual(packet.status, "handoff_ready")
        XCTAssertTrue(packet.narrative.hasPrefix(authored.narrative))
        XCTAssertTrue(packet.narrative.contains("Runtime continuity: auto_handoff progress=51 failed_tools=0"))
        XCTAssertFalse(packet.narrative.contains("Runtime continuity: auto_checkpoint"))
        XCTAssertEqual(packet.resumeSeedIsCustom, customSeed)
        XCTAssertEqual(packet.resumeSeed, customSeed ? authored.resumeSeed : packet.defaultResumeSeed())
        XCTAssertEqual(try app.store.handoffLegacyGet(id: packet.id), packet)
        XCTAssertEqual(try app.store.handoffLegacyGet(id: authoredID), authored)
        if projectionFails {
            let entry = try XCTUnwrap(app.diagnostics.recent(limit: 100).last {
                $0.event == "continuity_projection_write_failed" && $0.fields["handoff_id"] == packet.id
            })
            XCTAssertNotNil(entry.fields["error"])
        } else {
            let projectionData = try Data(contentsOf: app.paths.memoryHandoffsDir.appendingPathComponent("\(packet.id).json"))
            let projectionObject = try JSONSupport.object(from: projectionData)
            let projected = try XCTUnwrap(HandoffPacket.fromDictionary(projectionObject))
            XCTAssertEqual(projected, packet, "Readable projection must use the actual finalized committed packet")
        }
        for event in ["auto_handoff", "auto_handoff_persist"] {
            let entry = try XCTUnwrap(app.diagnostics.recent(limit: 100).last { $0.event == event && $0.fields["handoff_id"] == packet.id })
            XCTAssertEqual(entry.fields["operation"], "handoff")
            XCTAssertEqual(entry.fields["finalize"], "true")
            XCTAssertEqual(entry.fields["resume_ready"], "true")
            XCTAssertEqual(entry.fields["reason"], observation.reason)
        }
        let committed = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: key))
        XCTAssertTrue(committed.blocked)
        XCTAssertNil(committed.pending)
        XCTAssertNil(committed.rolloverRequested)
        XCTAssertEqual(committed.lastHandoffCount, 51)
        let resumed = try app.tools.call(name: "get_forge_status", arguments: [
            "resume": true, "handoff_id": packet.id,
            "rollover_nonce": ContextContinuityService.interactiveRolloverNonce(handoffID: packet.id),
        ], clientID: client)
        XCTAssertTrue(resumed.ok)
        XCTAssertEqual(resumed.payload["context_budget_cleared"] as? Bool, true)
        let successor = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: key))
        XCTAssertNotEqual(successor.epoch, committed.epoch)
        XCTAssertNil(successor.rolloverRequested)
        XCTAssertEqual(successor.progressCount, 0)
        let next = try app.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: client)
        XCTAssertTrue(next.ok)
        XCTAssertNil(next.payload["handoff_id"])
        XCTAssertFalse(try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: key)).blocked)
    }

    func testRuntimeContinuityAtomicPromotionRollbackRetainsFailedAttemptRequestAcrossReopen() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let app = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { app.shutdown() }
        let client = ClientID("atomic-rollback-owner")
        try bindProjectContext(app, clientID: client)
        _ = try app.config.update(["allowed_roots": [tempHome.path]])
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 51))
        let context = try app.projectContexts.invocationContext(for: client)
        let key = app.continuityAutomation.runtimeScopeKey(context)
        let packetID = UUID().uuidString.lowercased()
        let baseline = try app.store.updateRuntimeContinuityProgress(scopeKey: key) { progress in
            progress.progressCount = 50
            progress.startedAt = clock.now()
            progress.pending = RuntimeContinuityProgressClaim(scopeKey: key, epoch: progress.epoch,
                packetID: packetID, ownerID: UUID().uuidString, finalize: false, progressCount: 50, failureCount: 0,
                claimedAt: clock.now(), expiresAt: clock.now().addingTimeInterval(30))
        }
        let claim = try XCTUnwrap(baseline.pending)
        let failedRead = try app.tools.call(name: "fs_read", arguments: [
            "path": tempHome.appendingPathComponent("missing-owned-file.txt").path,
        ], clientID: client)
        XCTAssertFalse(failedRead.ok)
        let requested = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: key))
        XCTAssertEqual(requested.progressCount, 50)
        XCTAssertEqual(requested.failureCount, 1)
        XCTAssertEqual(requested.pending, claim)
        XCTAssertEqual(requested.rolloverRequested, true)
        let fault = FinalReviewCheckpointFailureOnce()
        let faultStore = try SQLiteStore(path: app.paths.storeSQLite, clock: clock,
            postMigrationCommitObserver: nil, beforeMutationCommitObserver: { kind in
                if kind == .handoff, fault.shouldFail() { throw StoreError.execFailed("injected atomic promotion failure") }
            })
        defer { faultStore.close() }
        let service = ContextContinuityService(paths: app.paths, store: faultStore,
            sessions: app.sessions, diagnostics: app.diagnostics, clock: clock)
        let inferred: [String: Any] = ["goal": "Recover the exact requested task", "cwd": tempHome.path,
            "next_actions": ["Continue the preserved task"]]
        fault.arm()
        XCTAssertThrowsError(try service.autoPersistRuntime(clientID: client, reason: "checkpoint50",
            inferred: inferred, attemptID: UUID(), claim: claim, priorPacketID: nil, cancellation: nil))
        XCTAssertEqual(fault.failureCount, 1)
        XCTAssertNil(try app.store.handoffLegacyGet(id: packetID))
        let retained = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: key))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(retained), try encoder.encode(requested),
            "Packet/progress rollback must retain exact claim, sticky request and accounted attempts")
        faultStore.close()
        clock.date = clock.date.addingTimeInterval(31)
        let reopened = try SQLiteStore(path: app.paths.storeSQLite, clock: clock)
        defer { reopened.close() }
        let recoveredState = try XCTUnwrap(reopened.runtimeContinuityProgress(scopeKey: key))
        XCTAssertEqual(recoveredState.pending, claim)
        XCTAssertEqual(recoveredState.rolloverRequested, true)
        XCTAssertLessThanOrEqual(try XCTUnwrap(recoveredState.pending).expiresAt, clock.now())
        let recovery = ContextContinuityService(paths: app.paths, store: reopened,
            sessions: app.sessions, diagnostics: app.diagnostics, clock: clock)
        let receipt = try recovery.autoPersistRuntime(clientID: client, reason: "checkpoint50",
            inferred: inferred, attemptID: UUID(), claim: claim, priorPacketID: nil, cancellation: nil)
        XCTAssertEqual(receipt.packet.id, packetID)
        XCTAssertTrue(receipt.finalize)
        XCTAssertEqual(receipt.progressCount, 50)
        XCTAssertEqual(receipt.failureCount, 1)
        XCTAssertEqual(receipt.reason, "auto_handoff progress=50 failed_tools=1")
        XCTAssertEqual(receipt.packet.goal, inferred["goal"] as? String)
        XCTAssertEqual(receipt.packet.status, "handoff_ready")
        let after = try XCTUnwrap(reopened.runtimeContinuityProgress(scopeKey: key))
        XCTAssertEqual(after.epoch, baseline.epoch)
        XCTAssertEqual(after.progressCount, 50)
        XCTAssertEqual(after.failureCount, 1)
        XCTAssertEqual(after.lastHandoffFailureCount, 1)
        XCTAssertTrue(after.blocked)
        XCTAssertNil(after.pending)
        XCTAssertNil(after.rolloverRequested)
        XCTAssertEqual(try reopened.handoffLegacyList(limit: 100).filter { $0.id == packetID }.count, 1)
        XCTAssertThrowsError(try reopened.handoffUpsertCompletingRuntimeProgress(
            HandoffPacket(id: packetID, resumeReady: false), claim: claim))
    }

    func testRuntimeContinuityLiveClaimRecordsElapsedRolloverRequestBeforePacketCommit() throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let app = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { app.shutdown() }
        let client = ClientID("atomic-elapsed-owner")
        try bindProjectContext(app, clientID: client)
        _ = try app.config.update(["allowed_roots": [tempHome.path]])
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 10_000))
        let context = try app.projectContexts.invocationContext(for: client)
        let key = app.continuityAutomation.runtimeScopeKey(context)
        let path = tempHome.appendingPathComponent("elapsed-owned-file.txt")
        try "Owned evidence\n".write(to: path, atomically: true, encoding: .utf8)
        let initial = try app.store.updateRuntimeContinuityProgress(scopeKey: key) { progress in
            progress.progressCount = 50
            progress.startedAt = clock.now().addingTimeInterval(-ContinuityAutomation.handoffIntervalSec + 10)
            progress.pending = RuntimeContinuityProgressClaim(scopeKey: key, epoch: progress.epoch,
                packetID: UUID().uuidString.lowercased(), ownerID: UUID().uuidString, finalize: false,
                progressCount: 50, failureCount: 0, claimedAt: clock.now(), expiresAt: clock.now().addingTimeInterval(30))
        }
        let claim = try XCTUnwrap(initial.pending)
        clock.date = clock.date.addingTimeInterval(11)
        let read = try app.tools.call(name: "fs_read", arguments: ["path": path.path], clientID: client)
        XCTAssertTrue(read.ok)
        let requested = try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: key))
        XCTAssertEqual(requested.progressCount, 51)
        XCTAssertEqual(requested.pending, claim)
        XCTAssertGreaterThan(claim.expiresAt, clock.now(), "This elapsed request must coexist with the original live lease")
        XCTAssertEqual(requested.rolloverRequested, true)
        let receipt = try app.continuity.autoPersistRuntime(clientID: client, reason: "checkpoint50",
            inferred: ["goal": "Resume elapsed task", "cwd": tempHome.path, "next_actions": ["Continue"]],
            attemptID: UUID(), claim: claim, priorPacketID: nil, cancellation: nil)
        XCTAssertTrue(receipt.finalize)
        XCTAssertEqual(receipt.packet.id, claim.packetID)
        XCTAssertEqual(receipt.progressCount, 51)
        XCTAssertTrue(try XCTUnwrap(app.store.runtimeContinuityProgress(scopeKey: key)).blocked)
    }

    func testRuntimeContinuityHistoricalProgressJSONWithoutRequestBitRemainsReadable() throws {
        let path = tempHome.appendingPathComponent("historical-runtime-progress.sqlite")
        let key = JSONSupport.sha256Hex("historical-runtime-request-field")
        let store = try SQLiteStore(path: path)
        let initial = try store.updateRuntimeContinuityProgress(scopeKey: key) { progress in progress.progressCount = 7 }
        var object = try JSONSupport.object(from: JSONEncoder().encode(initial))
        object.removeValue(forKey: "rolloverRequested")
        let historicalJSON = try JSONSupport.string(from: object)
        store.close()
        try withSQLiteFixture(at: path) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "UPDATE runtime_continuity_progress SET state_json=? WHERE scope_key=?", -1,
                &statement, nil) == SQLITE_OK, let statement else { throw SQLiteFixtureError.failure("prepare historical state") }
            defer { sqlite3_finalize(statement) }
            bindSQLiteFixture(statement, index: 1, value: historicalJSON)
            bindSQLiteFixture(statement, index: 2, value: key)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteFixtureError.failure("persist historical state") }
        }
        let reopened = try SQLiteStore(path: path)
        defer { reopened.close() }
        let historical = try XCTUnwrap(reopened.runtimeContinuityProgress(scopeKey: key))
        XCTAssertEqual(historical.epoch, initial.epoch)
        XCTAssertEqual(historical.progressCount, 7)
        XCTAssertNil(historical.rolloverRequested)
        XCTAssertNil(historical.pending)
        XCTAssertEqual(try sqliteFixtureInt(at: path, sql: "SELECT version FROM schema_version;"), 9)
    }

    func testRuntimeContinuityAtomicRequestPreservesPreparationAndEpochFences() throws {
        let store = try SQLiteStore(path: tempHome.appendingPathComponent("atomic-request-fences.sqlite"))
        defer { store.close() }
        let key = JSONSupport.sha256Hex("atomic-request-fences")
        let seeded = try store.updateRuntimeContinuityProgress(scopeKey: key) { progress in
            progress.progressCount = 51
            progress.rolloverRequested = true
            progress.pending = RuntimeContinuityProgressClaim(scopeKey: key, epoch: progress.epoch,
                packetID: UUID().uuidString.lowercased(), ownerID: UUID().uuidString,
                finalize: false, progressCount: 50, failureCount: 0,
                claimedAt: Date(), expiresAt: Date().addingTimeInterval(30))
        }
        let claim = try XCTUnwrap(seeded.pending)
        let packet = HandoffPacket(id: claim.packetID, resumeReady: false, goal: "Exact intent", cwd: tempHome.path)
        XCTAssertThrowsError(try store.handoffUpsertCompletingRuntimeProgress(packet, claim: claim),
            "A requested promotion cannot silently commit an unprepared checkpoint")
        XCTAssertThrowsError(try store.handoffUpsertCompletingRuntimeProgress(packet, claim: claim, preparePacket: { value, _, _, _ in
            var changed = value
            changed.id = UUID().uuidString.lowercased()
            changed.resumeReady = true
            return changed
        }), "Packet preparation cannot replace the exact claim identity")
        let foreignEpoch = RuntimeContinuityProgressClaim(scopeKey: key, epoch: UUID().uuidString.lowercased(),
            packetID: claim.packetID, ownerID: claim.ownerID, finalize: false, progressCount: 50, failureCount: 0,
            claimedAt: claim.claimedAt, expiresAt: claim.expiresAt)
        XCTAssertThrowsError(try store.handoffUpsertCompletingRuntimeProgress(packet, claim: foreignEpoch))
        let retained = try XCTUnwrap(store.runtimeContinuityProgress(scopeKey: key))
        XCTAssertEqual(retained.pending, claim)
        XCTAssertEqual(retained.epoch, seeded.epoch)
        XCTAssertEqual(retained.rolloverRequested, true)
        XCTAssertFalse(retained.blocked)
        XCTAssertNil(try store.handoffLegacyGet(id: packet.id))
    }
}

extension ContinuityTests {
    func testRuntimeContinuityStatusReflectsPersistedThresholdBeforeNextEligibleCall() throws {
        let primary = try ForgeApp.bootstrap(home: tempHome)
        defer { primary.shutdown() }
        let client = MCPServer.defaultClientID(
            deploymentID: "status-refresh-owned-deployment",
            role: .primary,
            desktopProviderID: nil
        )
        try bindProjectContext(primary, clientID: client)
        _ = try primary.config.update(["allowed_roots": [tempHome.path]])
        let fallback = try ForgeApp.bootstrap(home: tempHome)
        defer { fallback.shutdown() }
        let file = tempHome.appendingPathComponent("status-refresh-owned-input.txt")
        try Data("Owned metadata refresh fixture\n".utf8).write(to: file)
        let seeded = try fallback.tools.call(
            name: "fs_read", arguments: ["path": file.path], clientID: client
        )
        XCTAssertTrue(seeded.ok, "\(seeded.payload)")
        let context = try fallback.projectContexts.invocationContext(for: client)
        let key = fallback.continuityAutomation.runtimeScopeKey(context)
        let baseline = try XCTUnwrap(fallback.store.runtimeContinuityProgress(scopeKey: key))
        XCTAssertEqual(baseline.progressCount, 1)
        XCTAssertEqual(baseline.failureCount, 0)
        XCTAssertFalse(baseline.blocked)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let baselineBytes = try encoder.encode(baseline)

        func assertPolicy(_ result: ToolResult, limit: Int, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertTrue(result.ok, "\(result.payload)", file: file, line: line)
            let current = try XCTUnwrap(result.payload["auto_continuity"] as? [String: Any], file: file, line: line)
            let continuity = try XCTUnwrap(result.payload["continuity"] as? [String: Any], file: file, line: line)
            let legacy = try XCTUnwrap(continuity["auto"] as? [String: Any], file: file, line: line)
            for policy in [current, legacy] {
                XCTAssertEqual(policy["handoff_every_tools"] as? Int, limit, file: file, line: line)
                XCTAssertEqual(policy["checkpoint_every_tools"] as? Int, min(50, limit), file: file, line: line)
            }
            XCTAssertEqual(current["progress_count"] as? Int, 1, file: file, line: line)
            XCTAssertEqual(current["failed_tool_count"] as? Int, 0, file: file, line: line)
            XCTAssertEqual(current["tool_call_count"] as? Int, 1, file: file, line: line)
            XCTAssertEqual(current["blocked"] as? Bool, false, file: file, line: line)
            XCTAssertEqual(current["continuity_epoch"] as? String, baseline.epoch, file: file, line: line)
            XCTAssertEqual(current["project_id"] as? String, context.projectID.description, file: file, line: line)
            XCTAssertEqual(current["project_generation"] as? UInt64, context.projectGeneration.rawValue, file: file, line: line)
            let after = try XCTUnwrap(fallback.store.runtimeContinuityProgress(scopeKey: key), file: file, line: line)
            XCTAssertEqual(try encoder.encode(after), baselineBytes, file: file, line: line)
        }

        let originalStatus = try fallback.tools.call(name: "forge_status", arguments: [:], clientID: client)
        try assertPolicy(originalStatus, limit: 200)

        _ = try primary.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 3))
        XCTAssertEqual(fallback.config.model.sessions.continuityRolloverToolCalls, 200)
        let savedThree = try Data(contentsOf: primary.paths.configJSON)
        // No eligible tool is called between the durable save and this status query.
        let refreshedStatus = try fallback.tools.call(name: "get_forge_status", arguments: [:], clientID: client)
        try assertPolicy(refreshedStatus, limit: 3)
        XCTAssertEqual(fallback.config.model.sessions.continuityRolloverToolCalls, 3)
        XCTAssertEqual(try Data(contentsOf: primary.paths.configJSON), savedThree)
        XCTAssertEqual(try fallback.continuity.get(id: nil, preferResumeReady: true)["found"] as? Bool, false)

        // A status refresh must reapply an unsaved local patch without persisting it.
        _ = try fallback.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 7), save: false)
        _ = try primary.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 5))
        let savedFive = try Data(contentsOf: primary.paths.configJSON)
        let stagedStatus = try fallback.tools.call(name: "get_forge_status", arguments: [:], clientID: client)
        try assertPolicy(stagedStatus, limit: 7)
        XCTAssertEqual(fallback.config.model.sessions.continuityRolloverToolCalls, 7)
        XCTAssertEqual(ConfigStore(paths: primary.paths).model.sessions.continuityRolloverToolCalls, 5)
        XCTAssertEqual(try Data(contentsOf: primary.paths.configJSON), savedFive)
    }
}

extension ContinuityTests {
    func testRuntimeContinuityStatusKeepsCachedRecoveryReadableWhenStoredBudgetIsMalformed() throws {
        try assertRuntimeContinuityCachedStatusRecovery(malformedBudget: true)
    }

    func testRuntimeContinuityStatusKeepsCachedRecoveryReadableWhenConfigurationFileIsMissing() throws {
        try assertRuntimeContinuityCachedStatusRecovery(malformedBudget: false)
    }

    private func assertRuntimeContinuityCachedStatusRecovery(malformedBudget: Bool) throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID(malformedBudget ? "cached-status-malformed-budget" : "cached-status-missing-file")
        try bindProjectContext(app, clientID: client)
        let context = try app.projectContexts.invocationContext(for: client)
        let key = app.continuityAutomation.runtimeScopeKey(context)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        func assertReadableStatus(_ response: ToolResult, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(response.ok, "\(response.payload)", file: file, line: line)
            XCTAssertFalse(response.isError, file: file, line: line)
            let automation = response.payload["auto_continuity"] as? [String: Any]
            let continuity = response.payload["continuity"] as? [String: Any]
            let legacy = continuity?["auto"] as? [String: Any]
            for policy in [automation, legacy] {
                XCTAssertEqual(policy?["handoff_every_tools"] as? Int, 200, file: file, line: line)
                XCTAssertEqual(policy?["checkpoint_every_tools"] as? Int, 50, file: file, line: line)
            }
            XCTAssertEqual(automation?["progress_count"] as? Int, 0, file: file, line: line)
            XCTAssertEqual(automation?["failed_tool_count"] as? Int, 0, file: file, line: line)
            XCTAssertEqual(automation?["tool_call_count"] as? Int, 0, file: file, line: line)
            XCTAssertEqual(automation?["blocked"] as? Bool, false, file: file, line: line)
            XCTAssertEqual(automation?["project_id"] as? String, context.projectID.description, file: file, line: line)
            XCTAssertEqual(automation?["project_generation"] as? UInt64, context.projectGeneration.rawValue, file: file, line: line)
            let attached = response.payload["project_context"] as? [String: Any]
            XCTAssertEqual(attached?["attached"] as? Bool, true, file: file, line: line)
            XCTAssertEqual(attached?["project_id"] as? String, context.projectID.description, file: file, line: line)
            XCTAssertEqual(attached?["project_generation"] as? UInt64, context.projectGeneration.rawValue, file: file, line: line)
            XCTAssertNotNil(response.payload["development_policy"], file: file, line: line)
        }

        let before = try app.tools.call(name: "forge_status", arguments: [:], clientID: client)
        assertReadableStatus(before)
        XCTAssertNil(before.payload["configuration_refresh"])
        XCTAssertTrue(app.audit.flushAttempts(timeout: 5))
        let cachedModelBytes = try encoder.encode(app.config.model)
        XCTAssertNil(try app.store.runtimeContinuityProgress(scopeKey: key))
        let originalBytes = try Data(contentsOf: app.paths.configJSON)
        var malformedBytes: Data?
        if malformedBudget {
            var object = try JSONSupport.object(from: originalBytes)
            object["budget_policy"] = ["schema_version": 999]
            let damaged = try JSONSupport.data(from: object)
            XCTAssertNotEqual(damaged, originalBytes)
            try damaged.write(to: app.paths.configJSON, options: .atomic)
            malformedBytes = damaged
        } else {
            try FileManager.default.removeItem(at: app.paths.configJSON)
        }

        // Cancellation/deadline controls must stay authoritative even when refresh would fail.
        let cancelled = ToolCallCancellation(timeoutSeconds: 5)
        cancelled.cancel()
        XCTAssertThrowsError(try app.tools.call(
            name: "get_forge_status", arguments: [:], clientID: client, cancellation: cancelled
        )) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let expired = try app.tools.call(
            name: "get_forge_status", arguments: [:], clientID: client,
            cancellation: ToolCallCancellation(timeoutSeconds: 0)
        )
        XCTAssertFalse(expired.ok)
        XCTAssertEqual(expired.payload["code"] as? String, "deadline_exceeded")

        XCTAssertTrue(app.audit.flushAttempts(timeout: 5))
        if !malformedBudget {
            // Reestablish the missing-file boundary after the drained cancellation controls.
            if FileManager.default.fileExists(atPath: app.paths.configJSON.path) {
                try FileManager.default.removeItem(at: app.paths.configJSON)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.paths.configJSON.path))
        }
        // No eligible work or settings mutation occurs after the damage.
        let recovered = try app.tools.call(name: "get_forge_status", arguments: [:], clientID: client)
        XCTAssertTrue(app.audit.flushAttempts(timeout: 5))
        assertReadableStatus(recovered)
        let refresh = try XCTUnwrap(recovered.payload["configuration_refresh"] as? [String: Any])
        XCTAssertEqual(refresh["state"] as? String, "failed")
        XCTAssertEqual(refresh["using_cached_settings"] as? Bool, true)
        let refreshError = try XCTUnwrap(refresh["error"] as? String)
        XCTAssertFalse(refreshError.isEmpty)
        XCTAssertLessThanOrEqual(refreshError.count, 1_024)
        XCTAssertLessThanOrEqual(refreshError.utf8.count, 1_024)
        XCTAssertEqual(try encoder.encode(app.config.model), cachedModelBytes)
        XCTAssertNil(try app.store.runtimeContinuityProgress(scopeKey: key))
        let afterContext = try app.projectContexts.invocationContext(for: client)
        XCTAssertEqual(afterContext.projectID, context.projectID)
        XCTAssertEqual(afterContext.projectGeneration, context.projectGeneration)
        XCTAssertEqual(afterContext.clientID, context.clientID)
        if let malformedBytes {
            XCTAssertEqual(try Data(contentsOf: app.paths.configJSON), malformedBytes)
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.paths.configJSON.path))
        }
    }
}


extension ContinuityTests {
    func testRuntimeContinuityElapsedFastJobRetainsExactJobReferenceAlongsideCompletedAuthoredTask() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let app = try ForgeApp.bootstrap(home: tempHome, clock: clock)
        defer { app.shutdown() }
        let client = ClientID("elapsed-fast-job-continuation")
        try bindProjectContext(app, clientID: client)
        try configureAllowedProjectRoot(app)
        _ = try app.config.update(["shell": ["enabled": true]], save: false)
        _ = try app.config.update(ManagerSettingsPatch(continuityRolloverToolCalls: 10_000), save: false)
        let context = try app.projectContexts.invocationContext(for: client)
        let probe = tempHome.appendingPathComponent("elapsed-continuation-evidence.txt")
        try "Owned continuity evidence\n".write(to: probe, atomically: true, encoding: .utf8)
        let seed = "Preserve the completed authored task and its optional follow-up."
        let saved = try app.tools.call(name: "session_checkpoint", arguments: [
            "goal": "Prior authored task is complete", "status": "completed", "cwd": tempHome.path,
            "next_actions": ["Optional earlier-task follow-up"],
            "narrative": "The prior authored task completed before this diagnostic.",
            "resume_seed": seed,
        ], clientID: client)
        XCTAssertTrue(saved.ok, "\(saved.payload)")
        let authoredID = try XCTUnwrap(saved.payload["handoff_id"] as? String)
        let authored = try XCTUnwrap(app.store.handoffLegacyGet(id: authoredID))
        XCTAssertTrue(authored.resumeSeedIsCustom)
        XCTAssertEqual(authored.resumeSeed, seed)

        let started = try app.tools.call(name: "fs_read", arguments: ["path": probe.path], clientID: client)
        XCTAssertTrue(started.ok, "\(started.payload)")
        XCTAssertEqual(app.continuityAutomation.snapshot(for: client)["progress_count"] as? Int, 1)
        clock.date = clock.date.addingTimeInterval(ContinuityAutomation.handoffIntervalSec + 1)
        let marker = "FORGE-CONTINUATION-FAST-JOB-026"
        let submitted = try app.tools.call(name: "process.run", arguments: [
            "executable": "/usr/bin/printf", "arguments": ["%s\n", marker], "cwd": tempHome.path,
            "timeout_sec": 5, "replay_class": RuntimeReplayClass.readOnly.rawValue,
        ], clientID: client)
        XCTAssertTrue(submitted.ok, "\(submitted.payload)")
        let jobText = try XCTUnwrap(submitted.payload["job_id"] as? String)
        let jobID = try XCTUnwrap(UUID(uuidString: jobText))
        XCTAssertEqual(submitted.payload["auto_continuity"] as? String, "handoff")
        XCTAssertEqual(submitted.payload["handoff_required"] as? Bool, true)
        let handoffID = try XCTUnwrap(submitted.payload["auto_handoff_id"] as? String)
        let packet = try XCTUnwrap(app.store.handoffLegacyGet(id: handoffID))
        XCTAssertTrue(packet.resumeReady)
        XCTAssertEqual(packet.goal, authored.goal)
        XCTAssertEqual(packet.nextActions, authored.nextActions)
        XCTAssertTrue(packet.narrative.hasPrefix(authored.narrative))
        XCTAssertTrue(packet.resumeSeedIsCustom)
        XCTAssertEqual(packet.resumeSeed, seed)
        XCTAssertEqual(try app.store.handoffLegacyGet(id: authoredID), authored)

        let blocked = try app.tools.call(name: "job.status", arguments: ["job_id": jobText], clientID: client)
        XCTAssertFalse(blocked.ok)
        XCTAssertEqual(blocked.payload["code"] as? String, "context_budget_exceeded")
        let terminal = try await app.runtimeJobs.service.waitForTerminal(
            jobID: jobID, context: context, maximumWait: .seconds(5))
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertEqual(terminal.exitCode, 0)
        let output = try await app.runtimeJobs.service.readOutput(
            jobID: jobID, stream: .stdout, offset: 0, limit: 256, context: context)
        XCTAssertEqual(String(decoding: output.data, as: UTF8.self), marker + "\n")
        XCTAssertTrue(output.eof)
        XCTAssertFalse(output.isSnapshot)

        let resumed = try app.tools.call(name: "get_forge_status", arguments: [
            "resume": true, "handoff_id": handoffID,
        ], clientID: client)
        XCTAssertTrue(resumed.ok, "\(resumed.payload)")
        let resume = try XCTUnwrap(resumed.payload["resume"] as? [String: Any])
        let wire = try XCTUnwrap(resume["packet"] as? [String: Any])
        let loaded = try XCTUnwrap(HandoffPacket.fromDictionary(wire))
        XCTAssertEqual(loaded.id, handoffID)
        XCTAssertEqual(loaded.goal, authored.goal)
        XCTAssertEqual(loaded.nextActions, authored.nextActions)
        XCTAssertTrue(loaded.resumeSeedIsCustom)
        XCTAssertEqual(loaded.resumeSeed, seed)
        XCTAssertEqual(try app.store.handoffLegacyGet(id: authoredID), authored)
        let resumeJSON = try JSONSupport.string(from: resume)
        XCTAssertTrue(resumeJSON.contains(jobText),
            "The exact committed job ID must survive alongside the old authored task in the exact-handoff resume response")
    }
}

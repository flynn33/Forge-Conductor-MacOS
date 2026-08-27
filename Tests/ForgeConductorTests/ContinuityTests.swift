// ContinuityTests.swift
// Context + agent continuity: checkpoint, handoff, resume, budget loop.

import XCTest
import SQLite3
import Darwin
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
        let initialized = try app.projectMemory.initialize(path: canonicalRoot.path)
        let projectID = try XCTUnwrap(initialized["project_id"] as? String)
        let descriptor = try app.projectMemory.identities.descriptor(projectID: projectID)
        _ = try app.projectContexts.registerAndBindMCPClient(
            descriptor: descriptor,
            canonicalRoot: canonicalRoot,
            clientID: clientID
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

    func testHandoffMarksResumeReadyAndSnapshotsAgents() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
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
        XCTAssertEqual(prepared.targetVersion, 5)
        XCTAssertEqual(prepared.backupFilename, backupURL.lastPathComponent)
        XCTAssertEqual(
            prepared.backupSHA256,
            JSONSupport.sha256Hex(try Data(contentsOf: backupURL))
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: VerifiedMigrationBackup.archivedManifestURL(
                    for: backupURL,
                    targetVersion: 5
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
        XCTAssertEqual(try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"), 5)
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
        XCTAssertEqual(migrationManifest.targetVersion, 5)
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
                    targetVersion: 5
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
        XCTAssertEqual(try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"), 5)
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
                    targetVersion: 5
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
            targetVersion: 5
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
        XCTAssertEqual(try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"), 5)
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
        XCTAssertEqual(try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"), 5)
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
        XCTAssertEqual(prepared.targetVersion, 5)
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

        XCTAssertEqual(try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"), 5)
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
                        targetVersion: 5
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
            targetVersion: 5
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
        XCTAssertEqual(prepared.targetVersion, 5)
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

        XCTAssertEqual(try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"), 5)
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

        XCTAssertEqual(try sqliteFixtureInt(at: databaseURL, sql: "SELECT version FROM schema_version;"), 5)
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
                        targetVersion: 5,
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
                      manifest.targetVersion == 5 else {
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
        XCTAssertEqual(try sqliteFixtureInt(at: freshURL, sql: "SELECT version FROM schema_version;"), 5)
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
            targetVersion: 5,
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
            targetVersion: 5,
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
            targetVersion: 5,
            storageKind: .sqlite
        )
        try FileManager.default.removeItem(at: databaseURL)
        try withSQLiteFixture(at: databaseURL) { database in
            try executeSQLiteFixture(
                database,
                sql: """
                CREATE TABLE schema_version(version INTEGER NOT NULL);
                INSERT INTO schema_version(version) VALUES(5);
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

    func testAuthorizationDeniedLoopSignalsExactlyAtSoftAndHardThresholds() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let client = ClientID("denied-exact-loop-thresholds")
        try bindProjectContext(app, clientID: client)
        let outside = tempHome.deletingLastPathComponent()
            .appendingPathComponent("forge-denied-loop-\(UUID().uuidString).txt")

        var softHandoffID: String?
        for count in 1...9 {
            let result = try app.tools.call(
                name: "fs_write",
                arguments: ["path": outside.path, "content": "must remain denied"],
                clientID: client
            )

            switch count {
            case 1...3, 5...8:
                XCTAssertFalse(result.ok, "call \(count)")
                XCTAssertTrue(result.isError, "call \(count)")
                XCTAssertEqual(result.payload["code"] as? String, "path_outside_allowed_roots")
                XCTAssertNil(result.payload["handoff_required"], "call \(count)")
            case 4:
                XCTAssertFalse(result.ok)
                XCTAssertTrue(result.isError)
                XCTAssertEqual(result.payload["code"] as? String, "path_outside_allowed_roots")
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                softHandoffID = result.payload["handoff_id"] as? String
                XCTAssertNotNil(softHandoffID)
                XCTAssertFalse((result.payload["resume_seed"] as? String ?? "").isEmpty)
            case 9:
                XCTAssertFalse(result.ok)
                XCTAssertTrue(result.isError)
                XCTAssertEqual(result.payload["code"] as? String, "identical_call_loop")
                XCTAssertEqual(result.payload["blocked_call_code"] as? String, "path_outside_allowed_roots")
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                XCTAssertEqual(result.payload["handoff_id"] as? String, softHandoffID)
                XCTAssertFalse((result.payload["resume_seed"] as? String ?? "").isEmpty)
            default:
                XCTFail("unexpected count")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path), "call \(count) dispatched")
        }

        let handoffID = try XCTUnwrap(softHandoffID)
        let packet = try XCTUnwrap(app.store.handoffGet(id: handoffID))
        XCTAssertEqual(packet.source, .budget)
        XCTAssertTrue(packet.resumeReady)
        XCTAssertFalse(packet.resumeSeed.isEmpty)
        XCTAssertTrue(packet.narrative.contains("identical_call_loop tool=fs_write count=9"), packet.narrative)
        XCTAssertTrue(packet.narrative.contains("authorization_denial=path_outside_allowed_roots"), packet.narrative)

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
        try bindProjectContext(app, clientID: client)
        let outside = tempHome.deletingLastPathComponent()
            .appendingPathComponent("forge-denied-failed-loop-\(UUID().uuidString).txt")
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
                arguments: ["path": outside.path, "content": "must remain denied"],
                clientID: client
            )
            if count < 9 {
                XCTAssertFalse(result.ok, "call \(count)")
                XCTAssertEqual(result.payload["code"] as? String, "path_outside_allowed_roots")
                XCTAssertNil(result.payload["handoff_required"], "call \(count)")
            } else {
                XCTAssertFalse(result.ok)
                XCTAssertTrue(result.isError)
                XCTAssertEqual(result.payload["code"] as? String, "continuity_persistence_failed")
                XCTAssertEqual(result.payload["loop_code"] as? String, "identical_call_loop")
                XCTAssertEqual(result.payload["blocked_call_code"] as? String, "path_outside_allowed_roots")
                XCTAssertEqual(result.payload["handoff_required"] as? Bool, true)
                XCTAssertEqual(result.payload["handoff_persisted"] as? Bool, false)
                XCTAssertNil(result.payload["handoff_id"])
                XCTAssertNil(result.payload["resume_seed"])
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path), "call \(count) dispatched")
        }

        XCTAssertEqual(try app.store.handoffList(limit: 10), [])
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
    }

    func testContextGetRequiresExplicitProjectBindingBeforeShell() throws {
        let projectRoot = tempHome.appendingPathComponent("adopt-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
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

    func testReadOnlyHomePathIsAllowedWithoutAgentSession() throws {
        let app = try ForgeApp.bootstrap(home: tempHome)
        defer { app.shutdown() }
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("LM Studio Projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: projects.path) else {
            throw XCTSkip("LM Studio Projects folder not present on this Mac")
        }
        let result = try app.tools.call(
            name: "fs_list",
            arguments: ["path": projects.path],
            clientID: ClientID("home-read")
        )
        XCTAssertTrue(result.ok, "\(result.payload)")
    }
}

private enum SQLiteFixtureError: Error {
    case failure(String)
}

private enum ThrowingLoopToolPackError: Error {
    case forced
}

private struct ThrowingLoopToolPack: ToolPackHandling {
    let toolNames = ["throwing_test_tool"]

    func handle(
        name: String,
        arguments: [String: Any],
        clientID: ClientID,
        app: ForgeApp
    ) throws -> ToolResult? {
        guard name == "throwing_test_tool" else { return nil }
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

private final class MigrationXCTestFixture {
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

private func launchMigrationXCTestFixture(
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

private func waitForMigrationMarker(
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

private func forceKillMigrationXCTestFixture(
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

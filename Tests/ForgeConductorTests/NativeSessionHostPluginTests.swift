// NativeSessionHostPluginTests.swift
// Verifies the native host contract, autonomous rollover, recovery, bounds, and privacy.

import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

private actor ScriptedNativeTransport: NativeSessionTransport {
    enum Mode: Sendable {
        case normal
        case rateLimit(Int)
        case malformedAcknowledgement
        case oversizedChunk
        case deadline
    }

    private var mode: Mode
    private var createAttempts = 0
    private var createEffects: [String: NativeTransportSession] = [:]
    private var cancelled: Set<String> = []

    init(mode: Mode) { self.mode = mode }

    func createSession(
        request: SessionCreationRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> NativeTransportSession {
        createAttempts += 1
        if case .deadline = mode { throw NativeHostPluginError.deadlineExceeded }
        if case .rateLimit(let failures) = mode, createAttempts <= failures {
            throw NativeHostPluginError.rateLimited(retryNanoseconds: 0)
        }
        if cancelled.contains(request.operationID) { throw NativeHostPluginError.cancelled }
        if let existing = createEffects[request.idempotencyKey] { return existing }
        let created = NativeTransportSession(
            providerSessionID: "provider-\(request.idempotencyKey)", model: "fixture-model"
        )
        createEffects[request.idempotencyKey] = created
        return created
    }

    func bootstrap(_ request: NativeBootstrapRequest) async throws -> NativeBootstrapResponse {
        switch mode {
        case .malformedAcknowledgement:
            return NativeBootstrapResponse(chunks: [Data("not-json".utf8)])
        case .oversizedChunk:
            return NativeBootstrapResponse(
                chunks: [Data(repeating: 0x61, count: ForgeNativeSessionHostAdapter.maximumChunkBytes + 1)]
            )
        case .deadline:
            throw NativeHostPluginError.deadlineExceeded
        default:
            return NativeBootstrapResponse(chunks: [try JSONSupport.data(from: [
                "handoff_id": request.handoffID,
                "successor_session_id": request.successorSessionID,
            ])], inputTokens: 100, outputTokens: 8)
        }
    }

    func cancel(operationID: String, providerSessionID: String?) async {
        cancelled.insert(operationID)
    }

    func stats() -> (attempts: Int, effects: Int, cancellations: Int) {
        (createAttempts, createEffects.count, cancelled.count)
    }
}

final class NativeSessionHostPluginTests: XCTestCase {
    func testManifestRegistryAndCapabilities() async throws {
        let root = temporaryRoot("registry")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        XCTAssertEqual(registry.manifests, [ForgeNativeSessionHostPlugin.manifest])
        let adapter = try registry.adapter(
            identifier: ForgeNativeSessionHostPlugin.identifier,
            storageDirectory: root
        )
        let capabilities = try await adapter.capabilities()
        XCTAssertTrue(capabilities.create)
        XCTAssertTrue(capabilities.bootstrap)
        XCTAssertTrue(capabilities.usageReporting)
        XCTAssertTrue(capabilities.resume)
        XCTAssertTrue(capabilities.idempotency)
        XCTAssertTrue(capabilities.queryByIdempotencyKey)
    }

    func testFullAutonomousRolloverPersistsOnlyCompactIdentifiers() async throws {
        let fixture = try makeProjectFixture("autonomous")
        defer {
            fixture.memory.closeAll()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let pluginDirectory = fixture.home.appendingPathComponent("NativeHost", isDirectory: true)
        let transport = LocalLogicalSessionTransport()
        let adapter = try ForgeNativeSessionHostAdapter(
            storageDirectory: pluginDirectory, transport: transport
        )
        let handoff = try makeHandoff(
            projectID: fixture.projectID,
            operationID: UUID().uuidString.lowercased(),
            mission: "Continue repair with api_key=private-fixture-value" // Example credential fixture.
        )
        let coordinator = ContinuityCoordinator(engine: ContinuityStateEngine(memory: fixture.memory))
        let completed = try await coordinator.requestRollover(
            handoff: handoff, predecessorSessionID: "native-predecessor",
            adapter: adapter, idempotencyKey: "native-autonomous-rollover"
        )
        XCTAssertEqual(completed.state, .predecessorSealed)
        XCTAssertEqual(completed.acknowledgedHandoffID, handoff.handoffID)
        XCTAssertEqual(completed.acknowledgedSessionID, completed.successorSessionID)

        let ledgerURL = pluginDirectory.appendingPathComponent("native-session-ledger.json")
        let ledgerText = try String(contentsOf: ledgerURL, encoding: .utf8)
        XCTAssertFalse(ledgerText.contains("private-fixture-value"))
        XCTAssertFalse(ledgerText.contains(handoff.mission))
        XCTAssertLessThan(ledgerText.utf8.count, 16 * 1024)

        let restarted = try ForgeNativeSessionHostAdapter(
            storageDirectory: pluginDirectory, transport: transport
        )
        let restored = try await restarted.session(forIdempotencyKey: "native-autonomous-rollover")
        XCTAssertEqual(restored?.id, completed.successorSessionID)
        let replay = try await coordinator.requestRollover(
            handoff: handoff, predecessorSessionID: "native-predecessor",
            adapter: restarted, idempotencyKey: "native-autonomous-rollover"
        )
        XCTAssertEqual(replay, completed)
    }

    func testRateLimitRetryIdempotencyAndConcurrentProjects() async throws {
        let root = temporaryRoot("rate-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ScriptedNativeTransport(mode: .rateLimit(2))
        let adapter = try ForgeNativeSessionHostAdapter(storageDirectory: root, transport: transport)
        let firstRequest = SessionCreationRequest(
            operationID: UUID().uuidString.lowercased(), projectID: UUID().uuidString.lowercased(),
            predecessorSessionID: "predecessor-a", idempotencyKey: "project-a"
        )
        let first = try await adapter.createSession(firstRequest)
        let replay = try await adapter.createSession(firstRequest)
        XCTAssertEqual(first, replay)

        let secondRequest = SessionCreationRequest(
            operationID: UUID().uuidString.lowercased(), projectID: UUID().uuidString.lowercased(),
            predecessorSessionID: "predecessor-b", idempotencyKey: "project-b"
        )
        async let left = adapter.createSession(firstRequest)
        async let right = adapter.createSession(secondRequest)
        let concurrent = try await [left, right]
        XCTAssertNotEqual(concurrent[0].id, concurrent[1].id)
        let stats = await transport.stats()
        XCTAssertEqual(stats.attempts, 4)
        XCTAssertEqual(stats.effects, 2)
    }

    func testCancellationDeadlineMalformedAndStreamingBounds() async throws {
        let cases: [(String, ScriptedNativeTransport.Mode)] = [
            ("deadline", .deadline),
            ("malformed", .malformedAcknowledgement),
            ("oversized", .oversizedChunk),
        ]
        for (label, mode) in cases {
            let root = temporaryRoot(label)
            defer { try? FileManager.default.removeItem(at: root) }
            let transport = ScriptedNativeTransport(mode: mode)
            let adapter = try ForgeNativeSessionHostAdapter(storageDirectory: root, transport: transport)
            let operationID = UUID().uuidString.lowercased()
            let request = SessionCreationRequest(
                operationID: operationID, projectID: UUID().uuidString.lowercased(),
                predecessorSessionID: "predecessor", idempotencyKey: label
            )
            if case .deadline = mode {
                do {
                    _ = try await adapter.createSession(request)
                    XCTFail("deadline must fail")
                } catch NativeHostPluginError.deadlineExceeded {}
                continue
            }
            let session = try await adapter.createSession(request)
            let handoff = try makeHandoff(
                projectID: request.projectID, operationID: operationID, mission: "Bound transport response"
            )
            do {
                try await adapter.bootstrap(session, handoff: handoff)
                XCTFail("\(label) response must fail")
            } catch NativeHostPluginError.malformedResponse {}
        }

        let cancelRoot = temporaryRoot("cancel")
        defer { try? FileManager.default.removeItem(at: cancelRoot) }
        let cancelTransport = ScriptedNativeTransport(mode: .normal)
        let cancelledAdapter = try ForgeNativeSessionHostAdapter(
            storageDirectory: cancelRoot, transport: cancelTransport
        )
        let cancelledOperation = UUID().uuidString.lowercased()
        await cancelledAdapter.cancel(operationID: cancelledOperation)
        do {
            _ = try await cancelledAdapter.createSession(SessionCreationRequest(
                operationID: cancelledOperation, projectID: UUID().uuidString.lowercased(),
                predecessorSessionID: "predecessor", idempotencyKey: "cancelled"
            ))
            XCTFail("cancelled operation must not create")
        } catch NativeHostPluginError.cancelled {}
        let cancellationStats = await cancelTransport.stats()
        XCTAssertEqual(cancellationStats.cancellations, 1)
    }

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-native-host-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeProjectFixture(_ label: String) throws -> (
        root: URL, home: URL, projectID: String, memory: ProjectMemoryService
    ) {
        let root = temporaryRoot(label)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let memory = ProjectMemoryService(paths: paths)
        let initialized = try memory.initialize(path: project.path)
        return (root, home, try XCTUnwrap(initialized["project_id"] as? String), memory)
    }

    private func makeHandoff(
        projectID: String, operationID: String, mission: String
    ) throws -> ContinuityHandoff {
        try ContinuityHandoff(
            operationID: operationID,
            project: [
                "project_id": projectID, "display_name": "Native Fixture", "repository_root": "/fixture",
                "branch": "repair/runtime", "commit": "1234567", "dirty_summary": [] as [String],
            ],
            predecessorSession: [
                "session_id": "native-predecessor", "provider_session_id": NSNull(), "model": NSNull(),
            ],
            mission: mission,
            currentWork: [
                "phase_id": "P09", "work_item_id": "P09-03", "summary": "Run native rollover",
                "active_files": [] as [String],
            ],
            nextActions: [[
                "order": 1, "action": "Continue automatically", "command": "",
                "success_condition": "Successor acknowledges the exact handoff",
            ]],
            hostState: [
                "adapter_id": ForgeNativeSessionHostPlugin.identifier,
                "continuity_state": ContinuityState.checkpointPreparing.rawValue,
                "context_budget_source": "provider_exact", "retry": [:] as [String: Any],
            ]
        ).validated()
    }
}

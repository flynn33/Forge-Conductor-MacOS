import Foundation
import XCTest
@testable import ForgeConductorCore

final class StjornarvaldIntegrationQualificationTests: XCTestCase {
    func testEmitterBoundsAdmissionBecomesIdleAndStopsWithinDeadline() async throws {
        let submitter = SuspendedObservationSubmitter()
        let emitter = StjornarvaldObservationEmitter(submitter: submitter)
        let result = ToolResult.success(["value": "bounded"])

        let clock = ContinuousClock()
        let started = clock.now
        for index in 0..<2_000 {
            emitter.record(StjornarvaldProductObservationFactory.ordinaryTool(
                name: "fixture.\(index)",
                result: result,
                context: nil,
                clientID: ClientID("qualification")
            ))
        }
        let elapsed = started.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .seconds(1))
        try await waitUntil { await submitter.hasStarted() }
        let saturated = emitter.metrics()
        XCTAssertLessThanOrEqual(
            saturated.pendingCount,
            StjornarvaldObservationEmitter.maximumPendingCount
        )
        XCTAssertGreaterThan(saturated.droppedCount, 0)
        XCTAssertTrue(saturated.workerActive)

        await submitter.release()
        try await waitUntil {
            let metrics = emitter.metrics()
            return metrics.pendingCount == 0 && !metrics.workerActive
        }
        XCTAssertTrue(emitter.shutdown(timeoutSeconds: 0.5))
        let stopped = emitter.metrics()
        XCTAssertFalse(stopped.accepting)
        XCTAssertFalse(stopped.workerActive)

        let blockedSubmitter = SuspendedObservationSubmitter()
        let blocked = StjornarvaldObservationEmitter(submitter: blockedSubmitter)
        blocked.record(StjornarvaldProductObservationFactory.ordinaryTool(
            name: "fixture.blocked",
            result: result,
            context: nil,
            clientID: ClientID("qualification")
        ))
        try await waitUntil { await blockedSubmitter.hasStarted() }
        let shutdownStart = clock.now
        XCTAssertFalse(blocked.shutdown(timeoutSeconds: 0.05))
        XCTAssertLessThan(shutdownStart.duration(to: clock.now), .seconds(1))
        await blockedSubmitter.release()
        try await waitUntil { !blocked.metrics().workerActive }
    }

    func testToolResultSurvivesManagerFailureAndRestartDeliversRedactedObservationOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stjornarvald-integration-\(UUID().uuidString)", isDirectory: true)
        let appHome = root.appendingPathComponent("home", isDirectory: true)
        let outbox = root.appendingPathComponent("client-outbox", isDirectory: true)
        let app = try ForgeApp.bootstrap(home: appHome)
        defer {
            _ = app.shutdown()
            try? FileManager.default.removeItem(at: root)
        }

        let unavailableClient = StjornarvaldObservationClient(
            transport: AlwaysUnavailableObservationTransport(),
            outboxDirectory: outbox,
            processID: "qualification-process",
            bootID: "boot-a"
        )
        let emitter = StjornarvaldObservationEmitter(
            submitter: unavailableClient,
            shutdown: { await unavailableClient.shutdown() }
        )
        let fixed = QualificationToolPack()
        let baseline = ToolRouter(
            app: app,
            packs: [fixed],
            observationRecorder: NoOpObservationRecorder()
        )
        let observed = ToolRouter(
            app: app,
            packs: [fixed],
            observationRecorder: emitter
        )
        let secret = "qualification-secret-that-must-not-enter-policy-state"
        let baselineResult = try baseline.call(
            name: "forge_status",
            arguments: ["secret": secret],
            clientID: ClientID("baseline-client")
        )
        let start = ContinuousClock().now
        let observedResult = try observed.call(
            name: "forge_status",
            arguments: ["secret": secret],
            clientID: ClientID("observed-client")
        )
        XCTAssertLessThan(start.duration(to: ContinuousClock().now), .seconds(1))
        XCTAssertEqual(try canonicalResult(baselineResult), try canonicalResult(observedResult))

        try await waitUntil { await unavailableClient.pendingCount() == 1 }
        let retainedFiles = try FileManager.default.contentsOfDirectory(
            at: outbox,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(retainedFiles.count, 1)
        let retained = try String(contentsOf: XCTUnwrap(retainedFiles.first), encoding: .utf8)
        XCTAssertFalse(retained.contains(secret))
        XCTAssertFalse(retained.contains(QualificationToolPack.sensitiveResult))
        XCTAssertTrue(emitter.shutdown(timeoutSeconds: 1))

        let available = CapturingObservationTransport()
        let restarted = StjornarvaldObservationClient(
            transport: available,
            outboxDirectory: outbox,
            processID: "qualification-process",
            bootID: "boot-b"
        )
        await restarted.resume()
        try await waitUntil { await restarted.pendingCount() == 0 }
        let delivered = await available.observations()
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.kind, .toolInvocationCompleted)
        XCTAssertEqual(delivered.first?.subjectIdentity, "tool:forge_status")
        XCTAssertFalse(delivered.first?.summary.contains(secret) ?? true)
        XCTAssertFalse(delivered.first?.evidenceReferences.contains(where: {
            $0.contains(secret) || $0.contains(QualificationToolPack.sensitiveResult)
        }) ?? true)
        await restarted.shutdown()
    }

    func testManagedObservationIdentityIsStableAndCarriesNoArgumentsOrResultBody() throws {
        let context = ToolInvocationContext(
            projectID: ProjectID(UUID(uuidString: "10000000-0000-4000-8000-000000000001")!),
            projectGeneration: .initial,
            clientID: ClientID("managed-client"),
            runID: RunID(UUID(uuidString: "20000000-0000-4000-8000-000000000001")!),
            providerSessionID: "session-1",
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [URL(fileURLWithPath: "/tmp/project")],
                allowedTools: ["forge_status"],
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        )
        let secret = "managed-secret"
        let call = BrokeredToolCall(
            providerCallID: "provider-call-1",
            toolName: "forge_status",
            arguments: ["secret": secret]
        )
        let result = ToolResult.success(["body": QualificationToolPack.sensitiveResult])
        let first = StjornarvaldProductObservationFactory.managedTool(
            call: call,
            result: result,
            context: context
        )
        let second = StjornarvaldProductObservationFactory.managedTool(
            call: call,
            result: result,
            context: context
        )
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.idempotencyKey, second.idempotencyKey)
        let encoded = String(data: try JSONEncoder().encode(first), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains(QualificationToolPack.sensitiveResult))
        XCTAssertEqual(first.scope.runID, context.runID?.description)
        XCTAssertEqual(first.scope.sessionID, context.providerSessionID)
    }

    private func canonicalResult(_ result: ToolResult) throws -> String {
        try JSONSupport.canonicalJSON([
            "ok": result.ok,
            "is_error": result.isError,
            "payload": result.payload,
        ])
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await predicate()) {
            guard clock.now < deadline else {
                XCTFail("condition timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor SuspendedObservationSubmitter: PolicyObservationSubmitting {
    private var blocking = true
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func submit(_ observation: DevelopmentObservation) async {
        started = true
        if blocking {
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func hasStarted() -> Bool { started }

    func release() {
        blocking = false
        continuation?.resume()
        continuation = nil
    }
}

private struct AlwaysUnavailableObservationTransport: StjornarvaldObservationTransport {
    func submit(
        processID: String,
        bootID: String,
        observations: [DevelopmentObservation]
    ) async throws -> StjornarvaldObservationReceiptBatch {
        throw URLError(.cannotConnectToHost)
    }
}

private actor CapturingObservationTransport: StjornarvaldObservationTransport {
    private var captured: [DevelopmentObservation] = []

    func submit(
        processID: String,
        bootID: String,
        observations: [DevelopmentObservation]
    ) async throws -> StjornarvaldObservationReceiptBatch {
        captured.append(contentsOf: observations)
        return StjornarvaldObservationReceiptBatch(
            receipts: observations.map {
                StjornarvaldObservationSubmissionReceipt(
                    observationID: $0.id,
                    state: .persisted,
                    sequence: 1
                )
            },
            developmentContinues: true
        )
    }

    func observations() -> [DevelopmentObservation] { captured }
}

private struct NoOpObservationRecorder: StjornarvaldObservationRecording {
    func record(_ observation: DevelopmentObservation) {}
}

private struct QualificationToolPack: ToolPackHandling {
    static let sensitiveResult = "sensitive-result-body"
    let toolNames = ["forge_status"]

    func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        guard name == "forge_status" else { return nil }
        return .success(["status": "unchanged", "body": Self.sensitiveResult])
    }
}

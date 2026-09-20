import Foundation
import XCTest
@testable import ForgeConductorCore

final class StjornarvaldManagerCoordinatorTests: XCTestCase {
    func testCoordinatorProcessesDurableObservationStopsAndResumesAfterRestart() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        var repository: StjornarvaldObservationRepository? =
            try StjornarvaldObservationRepository(paths: fixture.paths)
        _ = try repository!.submit(fixture.observation(key: "coordinator-first"))

        let coordinator = StjornarvaldManagerCoordinator(
            paths: fixture.paths,
            evaluatorID: "manager-primary"
        )
        coordinator.start()
        try await waitUntil { coordinator.health().lastCommittedCursor == 1 }
        XCTAssertEqual(coordinator.health().processedObservationCount, 1)
        coordinator.stop()
        try await waitUntil { coordinator.health().state == .stopped }

        _ = try repository!.submit(fixture.observation(key: "coordinator-second"))
        let restarted = StjornarvaldManagerCoordinator(
            paths: fixture.paths,
            evaluatorID: "manager-restarted"
        )
        restarted.start()
        defer { restarted.stop() }
        try await waitUntil { restarted.health().lastCommittedCursor == 2 }
        XCTAssertEqual(
            restarted.health().processedObservationCount,
            1,
            String(describing: restarted.health())
        )

        var log: StjornarvaldPolicyLogStore? = try StjornarvaldPolicyLogStore(
            databaseURL: fixture.paths.stjornarvaldPolicyLogSQLite,
            jsonlURL: fixture.paths.stjornarvaldPolicyLogJSONL
        )
        XCTAssertEqual(try log!.events(limit: 10).count, 2)
        log = nil
        repository = nil
        await coordinator.shutdown()
        await restarted.shutdown()
    }

    func testTwoCoordinatorsDoNotEvaluateOneObservationTwice() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        var repository: StjornarvaldObservationRepository? =
            try StjornarvaldObservationRepository(paths: fixture.paths)
        _ = try repository!.submit(fixture.observation(key: "one-evaluator"))
        let first = StjornarvaldManagerCoordinator(paths: fixture.paths, evaluatorID: "manager-a")
        let second = StjornarvaldManagerCoordinator(paths: fixture.paths, evaluatorID: "manager-b")
        first.start()
        second.start()
        defer { first.stop(); second.stop() }
        try await waitUntil {
            first.health().lastCommittedCursor == 1 || second.health().lastCommittedCursor == 1
        }
        try await Task.sleep(for: .milliseconds(100))
        var log: StjornarvaldPolicyLogStore? = try StjornarvaldPolicyLogStore(
            databaseURL: fixture.paths.stjornarvaldPolicyLogSQLite,
            jsonlURL: fixture.paths.stjornarvaldPolicyLogJSONL
        )
        XCTAssertEqual(try log!.events(limit: 10).count, 1)
        log = nil
        repository = nil
        XCTAssertEqual(
            first.health().processedObservationCount + second.health().processedObservationCount,
            1
        )
        await first.shutdown()
        await second.shutdown()
    }

    func testInvalidPolicyDatabasePublishesDegradedHealthWithoutThrowing() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.paths.stjornarvaldDir,
            withIntermediateDirectories: true
        )
        try Data("not sqlite".utf8).write(to: fixture.paths.stjornarvaldPolicyLogSQLite)
        let coordinator = StjornarvaldManagerCoordinator(paths: fixture.paths)
        coordinator.start()
        let health = coordinator.health()
        XCTAssertEqual(health.state, .degraded)
        XCTAssertTrue(health.degraded)
        XCTAssertNotNil(health.lastError)
        await coordinator.shutdown()
    }

    func testRunningCoordinatorDoesNotRetainItsOwner() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        weak var releasedCoordinator: StjornarvaldManagerCoordinator?
        do {
            let coordinator = StjornarvaldManagerCoordinator(paths: fixture.paths)
            coordinator.start()
            releasedCoordinator = coordinator
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(releasedCoordinator)
    }

    func testSnapshotAndSourceMutationsAreBoundedAndIdempotent() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let sourceURL = fixture.root.appendingPathComponent("policy.md")
        try Data("# Local policy\nPreserve native behavior.\n".utf8).write(to: sourceURL)
        let coordinator = StjornarvaldManagerCoordinator(paths: fixture.paths)
        let requestID = UUID()
        let first = try await coordinator.addSource(selectedURL: sourceURL, requestID: requestID)
        let replay = try await coordinator.addSource(selectedURL: sourceURL, requestID: requestID)
        XCTAssertEqual(first.id, replay.id)

        let snapshot = try coordinator.snapshot(limit: 1)
        XCTAssertEqual(snapshot.schemaVersion, StjornarvaldManagerSnapshot.schemaVersion)
        XCTAssertEqual(snapshot.sources.map(\.id), [first.id])
        XCTAssertTrue(snapshot.violationEvents.isEmpty)

        let removed = try await coordinator.removeSource(
            sourceID: first.id,
            requestID: UUID()
        )
        XCTAssertFalse(removed.active)
        XCTAssertEqual(removed.interpretationState, .removedByUser)
        XCTAssertThrowsError(try coordinator.snapshot(limit: 0))
        await coordinator.shutdown()
    }

    func testObservationSubmissionProducesBoundedPendingNoticeWithoutControlAuthority() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = StjornarvaldManagerCoordinator(paths: fixture.paths)
        let batch = coordinator.submitObservations([
            fixture.observation(key: "manager-api-observation")
        ])
        XCTAssertTrue(batch.developmentContinues)
        XCTAssertEqual(batch.receipts.count, 1)
        XCTAssertEqual(batch.receipts.first?.state, .persisted)
        coordinator.start()
        defer { coordinator.stop() }
        try await waitUntil { coordinator.health().lastCommittedCursor == 1 }

        let notices = try await coordinator.pendingNotices(
            deliveryID: "coordinator-delivery",
            projectID: "coordinator-project",
            projectGeneration: 1,
            runID: "coordinator-run",
            sessionID: "coordinator-session",
            clientID: nil,
            maximumCount: 8,
            maximumBytes: 16 * 1_024
        )
        XCTAssertEqual(notices.notices.count, 1)
        XCTAssertEqual(notices.deliveryID, "coordinator-delivery")
        XCTAssertFalse(notices.controlsExecution)
        XCTAssertTrue(notices.notices.allSatisfy(\.developmentContinues))

        let page = try coordinator.violationPage(
            cursor: 0,
            limit: 1,
            projectID: "coordinator-project",
            state: .open
        )
        XCTAssertEqual(page.violations.count, 1)
        XCTAssertFalse(page.controlsExecution)
        XCTAssertNil(page.nextCursor)
        XCTAssertTrue(try coordinator.violationPage(
            cursor: 0,
            limit: 1,
            projectID: "another-project",
            state: nil
        ).violations.isEmpty)

        let scanID = UUID()
        let scan = try coordinator.scheduleScan(
            requestID: scanID,
            projectID: "coordinator-project",
            projectGeneration: 1,
            reason: "operator requested refresh"
        )
        let replay = try coordinator.scheduleScan(
            requestID: scanID,
            projectID: "coordinator-project",
            projectGeneration: 1,
            reason: "retry after lost response"
        )
        XCTAssertEqual(scan, replay)
        XCTAssertEqual(scan.state, .scheduled)
        XCTAssertTrue(scan.developmentContinues)

        try await coordinator.markNoticesPresented(deliveryIDs: [notices.deliveryID])
        let empty = try await coordinator.pendingNotices(
            deliveryID: "coordinator-delivery-after-presented",
            projectID: "coordinator-project",
            projectGeneration: 1,
            runID: "coordinator-run",
            sessionID: "coordinator-session",
            clientID: nil,
            maximumCount: 8,
            maximumBytes: 16 * 1_024
        )
        XCTAssertTrue(empty.notices.isEmpty)
        do {
            try await coordinator.markNoticesPresented(deliveryIDs: ["unknown-delivery"])
            XCTFail("unknown delivery receipt should fail")
        } catch let error as StjornarvaldPolicyNoticeError {
            guard case .invalid = error else {
                return XCTFail("unexpected presentation error: \(error)")
            }
        }

        let exportDestination = fixture.root.appendingPathComponent("policy.json")
        let export = try coordinator.exportReceipt(
            requestID: UUID(),
            format: .json,
            destination: exportDestination.path
        )
        XCTAssertEqual(export.state, .completed)
        XCTAssertEqual(export.destination, exportDestination.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportDestination.path))
        XCTAssertFalse(export.controlsExecution)
        await coordinator.shutdown()
    }

    func testManagerAuthorizationClassifiesStjornarvaldReadsAndMutations() {
        XCTAssertFalse(ManagerMutationAuthorizer.requiresAuthorization(
            method: "GET", path: "/api/manager/stjornarvald/snapshot"
        ))
        XCTAssertFalse(ManagerMutationAuthorizer.requiresAuthorization(
            method: "POST", path: "/api/manager/stjornarvald/notices/pending"
        ))
        XCTAssertFalse(ManagerMutationAuthorizer.requiresAuthorization(
            method: "POST", path: "/api/manager/stjornarvald/violations"
        ))
        XCTAssertTrue(ManagerMutationAuthorizer.requiresAuthorization(
            method: "POST", path: "/api/manager/stjornarvald/observations/submit"
        ))
        XCTAssertTrue(ManagerMutationAuthorizer.requiresAuthorization(
            method: "POST", path: "/api/manager/stjornarvald/scan"
        ))
        XCTAssertTrue(ManagerMutationAuthorizer.requiresAuthorization(
            method: "POST", path: "/api/manager/stjornarvald/export"
        ))
        XCTAssertTrue(ManagerMutationAuthorizer.requiresAuthorization(
            method: "POST", path: "/api/manager/stjornarvald/sources/add"
        ))
    }

    func testManagerRoutesEnforceSnapshotBoundsAndMutationCredential() async throws {
        let fixture = try CoordinatorFixture()
        var app: ForgeApp? = try ForgeApp.bootstrap(home: fixture.root)
        var node: ManagerNode?
        defer {
            _ = try? node?.stopService()
            node = nil
            _ = app?.shutdown()
            app = nil
            fixture.cleanup()
        }
        let port = Int.random(in: 40_000...49_000)
        try app!.config.update(
            ["dashboard": ["port": port] as [String: Any]],
            save: true
        )
        let sourceURL = fixture.root.appendingPathComponent("route-policy.md")
        try Data("# Route policy\n".utf8).write(to: sourceURL)
        node = ManagerNode(app: app!)
        _ = try node!.startService()
        try await Task.sleep(for: .milliseconds(150))

        let base = "http://127.0.0.1:\(port)/api/manager/stjornarvald"
        let snapshotURL = try XCTUnwrap(URL(string: base + "/snapshot?limit=1"))
        let (snapshotData, snapshotResponse) = try HTTPTestHelpers.fetch(snapshotURL)
        XCTAssertEqual(snapshotResponse.statusCode, 200)
        XCTAssertEqual(
            try JSONSupport.object(from: snapshotData)["schemaVersion"] as? String,
            StjornarvaldManagerSnapshot.schemaVersion
        )
        XCTAssertEqual(
            try HTTPTestHelpers.fetchStatusCode(
                XCTUnwrap(URL(string: base + "/snapshot?limit=0"))
            ),
            400
        )

        let addURL = try XCTUnwrap(URL(string: base + "/sources/add"))
        var request = URLRequest(url: addURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSupport.data(from: [
            "request_id": UUID().uuidString.lowercased(),
            "selected_path": sourceURL.path,
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        XCTAssertEqual(try HTTPTestHelpers.fetch(request).1.statusCode, 401)

        request.setValue(
            "Bearer \(try ManagerControlCredentialStore(paths: app!.paths).bearerToken())",
            forHTTPHeaderField: "Authorization"
        )
        let (sourceData, sourceResponse) = try HTTPTestHelpers.fetch(request)
        XCTAssertEqual(sourceResponse.statusCode, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(DevelopmentPolicySource.self, from: sourceData).selectedPath,
            sourceURL.path
        )

        request.httpBody = Data(repeating: 0x20, count: 16 * 1_024 + 1)
        XCTAssertEqual(try HTTPTestHelpers.fetch(request).1.statusCode, 413)

        let client = ManagerDashboardClient(
            host: "127.0.0.1",
            port: port,
            credentials: ManagerControlCredentialStore(paths: app!.paths)
        )
        let scanID = UUID()
        let scan = try await client.scheduleStjornarvaldScan(
            requestID: scanID,
            projectID: "coordinator-project",
            projectGeneration: 1,
            reason: "route contract test"
        )
        XCTAssertEqual(scan.requestID, scanID)
        XCTAssertEqual(scan.state, .scheduled)

        let exportDestination = fixture.root.appendingPathComponent("route-policy.json")
        let export = try await client.requestStjornarvaldExport(
            format: .json,
            destination: exportDestination.path
        )
        XCTAssertEqual(export.state, .completed)
        XCTAssertEqual(export.destination, exportDestination.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportDestination.path))
        XCTAssertFalse(export.controlsExecution)

        let observation = fixture.observation(key: "route-observation")
        let submitted = try await client.submitStjornarvaldObservations(
            processID: "route-test",
            bootID: "route-boot",
            observations: [observation]
        )
        XCTAssertEqual(submitted.receipts.first?.observationID, observation.id)
        try await waitUntilAsync {
            guard let page = try? await client.stjornarvaldViolations(
                projectID: "coordinator-project"
            ) else { return false }
            return !page.violations.isEmpty
        }
        let page = try await client.stjornarvaldViolations(
            projectID: "coordinator-project",
            state: .open
        )
        XCTAssertEqual(page.violations.count, 1)
        XCTAssertFalse(page.controlsExecution)

        let deliveryID = "route-delivery"
        let pending = try await client.pendingStjornarvaldNotices(
            deliveryID: deliveryID,
            projectID: "coordinator-project",
            projectGeneration: 1,
            runID: "coordinator-run",
            sessionID: "coordinator-session"
        )
        XCTAssertEqual(pending.deliveryID, deliveryID)
        XCTAssertEqual(pending.notices.count, 1)
        let presented = try await client.markStjornarvaldNoticesPresented(
            deliveryIDs: [deliveryID],
            requestID: UUID()
        )
        XCTAssertEqual(presented.deliveryIDs, [deliveryID])
        XCTAssertEqual(presented.state, .presented)
        XCTAssertFalse(presented.controlsExecution)
        await node!.stjornarvald.shutdown()
    }

    func testObservationClientRetainsOutboxAcrossManagerOutageAndRestart() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let outbox = fixture.root.appendingPathComponent("client-outbox", isDirectory: true)
        let firstObservation = fixture.observation(key: "outage-recovery-first")
        let secondObservation = fixture.observation(key: "outage-recovery-second")
        let unavailable = UnavailableObservationTransport()
        let first = StjornarvaldObservationClient(
            transport: unavailable,
            outboxDirectory: outbox,
            processID: "mcp-process",
            bootID: "boot-a"
        )
        await first.submit(firstObservation)
        await first.submit(secondObservation)
        try await waitUntilAsync { await first.pendingCount() == 2 }
        await first.shutdown()

        let deferred = StjornarvaldObservationClient(
            transport: DeferredObservationTransport(),
            outboxDirectory: outbox,
            processID: "mcp-process",
            bootID: "boot-b"
        )
        await deferred.resume()
        try await Task.sleep(for: .milliseconds(20))
        let deferredPendingCount = await deferred.pendingCount()
        XCTAssertEqual(deferredPendingCount, 2)
        await deferred.shutdown()

        let available = RecordingObservationTransport()
        let restarted = StjornarvaldObservationClient(
            transport: available,
            outboxDirectory: outbox,
            processID: "mcp-process",
            bootID: "boot-c"
        )
        await restarted.resume()
        try await waitUntilAsync { await restarted.pendingCount() == 0 }
        let deliveredObservationIDs = await available.observationIDs()
        XCTAssertEqual(deliveredObservationIDs, [firstObservation.id, secondObservation.id])
        await restarted.shutdown()
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        predicate: @escaping @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else { return XCTFail("condition timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntilAsync(
        timeout: Duration = .seconds(5),
        predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await predicate()) {
            guard clock.now < deadline else { return XCTFail("condition timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct UnavailableObservationTransport: StjornarvaldObservationTransport {
    func submit(
        processID: String,
        bootID: String,
        observations: [DevelopmentObservation]
    ) async throws -> StjornarvaldObservationReceiptBatch {
        throw URLError(.cannotConnectToHost)
    }
}

private struct DeferredObservationTransport: StjornarvaldObservationTransport {
    func submit(
        processID: String,
        bootID: String,
        observations: [DevelopmentObservation]
    ) async throws -> StjornarvaldObservationReceiptBatch {
        StjornarvaldObservationReceiptBatch(
            receipts: observations.map {
                StjornarvaldObservationSubmissionReceipt(
                    observationID: $0.id,
                    state: .deferred,
                    sequence: nil
                )
            },
            developmentContinues: true
        )
    }
}

private actor RecordingObservationTransport: StjornarvaldObservationTransport {
    private var recorded: [UUID] = []

    func submit(
        processID: String,
        bootID: String,
        observations: [DevelopmentObservation]
    ) async throws -> StjornarvaldObservationReceiptBatch {
        recorded.append(contentsOf: observations.map(\.id))
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

    func observationIDs() -> [UUID] { recorded }
}

private final class CoordinatorFixture {
    let root: URL
    let paths: AppPaths

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stj-manager-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(home: root)
        try paths.ensureLayout()
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func observation(key: String) -> DevelopmentObservation {
        DevelopmentObservation(
            idempotencyKey: key,
            kind: .projectConfigurationObserved,
            scope: DevelopmentObservationScope(
                projectID: "coordinator-project",
                projectGeneration: 1,
                runID: "coordinator-run",
                sessionID: "coordinator-session"
            ),
            subjectIdentity: "ForgeConductor",
            summary: "Shipping target membership",
            evidenceReferences: ["target:ForgeConductor"],
            payloadSHA256: JSONSupport.sha256Hex(key),
            details: DevelopmentObservationDetails(
                nativeTarget: NativeTargetObservationEvidence(
                    shippingRuntimePaths: ["Runtime/python-worker.py"],
                    targetMembershipComplete: true
                )
            )
        )
    }
}

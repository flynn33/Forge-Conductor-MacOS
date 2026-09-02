import XCTest
@testable import ForgeConductorCore

final class RuntimeCancelQualificationTests: XCTestCase {
    func testLostCancellationResponseRemainsCancelledAfterFreshManagerRestart() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-test-runtime-cancel-restart-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectRoot = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let jobID: UUID
        do {
            let app = try ForgeApp.bootstrap(home: home)
            _ = try app.config.update(["allowed_roots": [projectRoot.path]], save: false)
            let manager = ManagerNode(app: app)
            let registered = try manager.registerProject(path: projectRoot.path)
            let projectID = try XCTUnwrap(
                (registered["project_id"] as? String).flatMap(UUID.init(uuidString:))
            )
            let generation = try XCTUnwrap(registered["project_generation"] as? UInt64)
            let clientID = ClientID("runtime-cancel-restart-test")
            _ = try manager.bindProject(
                projectID: ProjectID(projectID),
                expectedGeneration: ProjectGeneration(generation),
                owner: ProjectBindingOwner(kind: .mcpClient, id: clientID.rawValue),
                allowedTools: Set(RuntimeJobToolPack.names)
            )
            let context = try app.projectContexts.invocationContext(for: clientID)
            jobID = try await app.runtimeJobs.service.submit(
                RuntimeJobRequest(
                    kind: .bash,
                    profile: .bashNoProfile,
                    context: context,
                    script: "while :; do sleep 1; done",
                    canonicalWorkingDirectory: projectRoot,
                    timeout: .seconds(30),
                    replayClass: .readOnly
                )
            )

            var reachedRunning = false
            for _ in 0..<200 {
                if try await app.runtimeJobs.service.status(
                    jobID: jobID,
                    context: context
                ).state == .running {
                    reachedRunning = true
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(reachedRunning, "The cancellation fixture must reach running state")

            // The manager commits cancellation before returning. Discarding this
            // receipt models a response lost after the durable mutation.
            try manager.cancelRuntimeJob(jobID: jobID)
            let terminal = try await app.runtimeJobs.service.waitForTerminal(
                jobID: jobID,
                context: context,
                maximumWait: .seconds(8)
            )
            XCTAssertEqual(terminal.state, .cancelled)
            XCTAssertTrue(app.shutdown().completed)
        }

        do {
            let app = try ForgeApp.bootstrap(home: home)
            defer { app.shutdown() }
            let manager = ManagerNode(app: app)

            let snapshot = try manager.operatorSnapshot(limit: 10)
            let restored = try XCTUnwrap(
                snapshot.runtimeJobs.first { $0.jobID == jobID.uuidString.lowercased() }
            )
            XCTAssertEqual(restored.state, RuntimeJobState.cancelled.rawValue)

            let repeated = try manager.cancelRuntimeJob(jobID: jobID)
            XCTAssertEqual(repeated.jobID, jobID.uuidString.lowercased())
            XCTAssertEqual(repeated.state, RuntimeJobState.cancelled.rawValue)
            let repeatedAgain = try manager.cancelRuntimeJob(jobID: jobID)
            XCTAssertEqual(repeatedAgain, repeated)

            let durable = try await app.runtimeJobs.repository.job(jobID)
            XCTAssertEqual(durable?.state, .cancelled)
        }
    }
}

import XCTest
#if SWIFT_PACKAGE
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif
@testable import ForgeConductorCore

private final class BootstrapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var enteredOnMain = false
    private var creations = 0
    private weak var created: ForgeApp?
    let release = DispatchSemaphore(value: 0)

    func started() -> Int {
        lock.withLock {
            starts += 1
            enteredOnMain = enteredOnMain || Thread.isMainThread
            return starts
        }
    }

    func observe(_ app: ForgeApp) { lock.withLock { created = app; creations += 1 } }
    var startCount: Int { lock.withLock { starts } }
    var ranOnMain: Bool { lock.withLock { enteredOnMain } }
    var application: ForgeApp? { lock.withLock { created } }
    var creationCount: Int { lock.withLock { creations } }

    func waitForRelease() throws {
        guard release.wait(timeout: .now() + 10) == .success else {
            throw BootstrapFixtureError.gateDeadline
        }
    }
}

private enum BootstrapFixtureError: Error { case expectedFailure, gateDeadline }

@MainActor
final class AppBootstrapAppTests: XCTestCase {
    private func home() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("forge-bootstrap-test-" + UUID().uuidString)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Bootstrap operation did not reach its bounded postcondition")
    }

    func testDelayedStartupLeavesMainActorResponsiveAndCoalescesDuplicateCalls() async throws {
        let directory = home()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BootstrapProbe()
        let operation = AppBootstrapOperation(factory: {
            _ = probe.started()
            guard probe.release.wait(timeout: .now() + 10) == .success else {
                throw BootstrapFixtureError.gateDeadline
            }
            let app = try ForgeApp.bootstrap(home: directory)
            probe.observe(app)
            return app
        }, pluginStatus: { _ in nil })
        var result: Result<AppBootstrapSnapshot, Error>?
        XCTAssertTrue(operation.start { value in
            XCTAssertTrue(Thread.isMainThread)
            result = value
        })
        XCTAssertFalse(operation.start { _ in XCTFail("Duplicate startup completed") })
        try await waitUntil { probe.startCount == 1 }
        // The worker is deliberately parked until this main-actor turn releases it.
        XCTAssertNil(result)
        XCTAssertFalse(probe.ranOnMain)
        XCTAssertTrue(operation.isRunning)
        probe.release.signal()
        try await waitUntil { result != nil }
        let snapshot = try XCTUnwrap(result).get()
        XCTAssertEqual(snapshot.app.paths.home.standardizedFileURL, directory.standardizedFileURL)
        XCTAssertFalse(operation.isRunning)
        let shutdown = await Task.detached { snapshot.app.shutdown() }.value
        XCTAssertTrue(shutdown.completed)
    }

    func testCancellationClosesUnpublishedGraphAndAllowsRetryAfterCompletion() async throws {
        let directory = home()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BootstrapProbe()
        let operation = AppBootstrapOperation(factory: {
            let attempt = probe.started()
            guard probe.release.wait(timeout: .now() + 10) == .success else {
                throw BootstrapFixtureError.gateDeadline
            }
            if attempt > 1 { throw BootstrapFixtureError.expectedFailure }
            let app = try ForgeApp.bootstrap(home: directory)
            probe.observe(app)
            return app
        }, pluginStatus: { _ in XCTFail("Cancelled graph reached status preparation"); return nil })
        var cancellations = 0
        XCTAssertTrue(operation.start { result in
            guard case .failure(is CancellationError) = result else { return XCTFail("Cancelled startup published a graph") }
            cancellations += 1
        })
        try await waitUntil { probe.startCount == 1 }
        operation.cancel()
        XCTAssertFalse(operation.start { _ in XCTFail("Cancelled startup admitted overlapping retry") })
        probe.release.signal()
        await operation.stop()
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(operation.isRunning)
        XCTAssertNil(probe.application, "Unpublished application graph survived cancellation")
        var retried = false
        probe.release.signal()
        XCTAssertTrue(operation.start { result in
            guard case .failure(BootstrapFixtureError.expectedFailure) = result else { return XCTFail("Unexpected retry result") }
            retried = true
        })
        try await waitUntil { retried }
        XCTAssertEqual(probe.startCount, 2)
    }

    func testOwnerReleaseCancelsWorkerWithoutRetainingApplication() async throws {
        let directory = home()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BootstrapProbe()
        var operation: AppBootstrapOperation? = AppBootstrapOperation(factory: {
            _ = probe.started()
            guard probe.release.wait(timeout: .now() + 10) == .success else {
                throw BootstrapFixtureError.gateDeadline
            }
            let app = try ForgeApp.bootstrap(home: directory)
            probe.observe(app)
            return app
        }, pluginStatus: { _ in nil })
        weak let released = operation
        operation?.start { _ in XCTFail("Released owner received completion") }
        try await waitUntil { probe.startCount == 1 }
        operation = nil
        XCTAssertNil(released)
        probe.release.signal()
        // Cancellation cleanup must finish before the disposable directory is removed.
        try await waitUntil { probe.creationCount == 1 && probe.application == nil }
    }

    func testNativeModelFailureAndRetryKeepPublishedStateOnMainActor() async throws {
        let probe = BootstrapProbe()
        let operation = AppBootstrapOperation(factory: {
            _ = probe.started()
            throw BootstrapFixtureError.expectedFailure
        }, pluginStatus: { _ in nil })
        let model = AppModel(bootstrapOperation: operation)
        model.autoRefresh = false
        try await waitUntil { !model.isBootstrapping }
        XCTAssertNil(model.app)
        XCTAssertTrue(model.lastError?.hasPrefix("Bootstrap failed:") == true)
        XCTAssertFalse(model.autoRefresh)
        model.bootstrap()
        try await waitUntil { !model.isBootstrapping }
        XCTAssertEqual(probe.startCount, 2)
        XCTAssertFalse(probe.ranOnMain)
        XCTAssertFalse(model.autoRefresh)
        await model.stopBootstrap()
    }

    func testSettingsMutationsWaitForStartupAndFailureStillAllowsRetry() async throws {
        let directory = home()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BootstrapProbe()
        let operation = AppBootstrapOperation(factory: {
            _ = probe.started()
            try probe.waitForRelease()
            throw BootstrapFixtureError.expectedFailure
        }, pluginStatus: { _ in nil })
        let model = AppModel(bootstrapOperation: operation)
        try await waitUntil { probe.startCount == 1 }
        XCTAssertTrue(model.isBootstrapping)
        XCTAssertFalse(model.hasLoadedInitialSettings)
        XCTAssertFalse(model.addAllowedRoot(directory), "A valid folder must not be staged against unloaded settings")
        model.chooseAllowedRoot() // Must return before presenting the native picker.
        model.removeAllowedRoot(directory.path)
        model.saveSettings()
        XCTAssertTrue(model.setAllowedRoots.isEmpty)
        XCTAssertEqual(model.managerMessage, "Settings are unavailable until startup completes.")
        probe.release.signal()
        try await waitUntil { !model.isBootstrapping }
        XCTAssertFalse(model.hasLoadedInitialSettings)
        XCTAssertTrue(model.lastError?.hasPrefix("Bootstrap failed:") == true)
        model.bootstrap()
        try await waitUntil { probe.startCount == 2 }
        XCTAssertTrue(model.isBootstrapping)
        probe.release.signal()
        await model.stopBootstrap()
        XCTAssertFalse(model.hasLoadedInitialSettings)
    }
}

@MainActor
final class AppBackgroundOperationAppTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Background action did not reach its bounded postcondition")
    }

    func testCommittedExportWinsCancellationAndDuplicateActionIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-native-export-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BootstrapProbe()
        let operation = AppBackgroundOperation()
        var result: Result<DiagnosticLog.ExportResult, Error>?
        XCTAssertTrue(operation.start {
            _ = probe.started()
            try probe.waitForRelease()
            let paths = AppPaths(home: directory)
            let diagnostics = DiagnosticLog(paths: paths)
            diagnostics.info("native_export_fixture", ["count": "1"], category: .diagnostics)
            return try diagnostics.export(basename: "native-action-export")
        } completion: { value in
            XCTAssertTrue(Thread.isMainThread)
            result = value
        })
        try await waitUntil { probe.startCount == 1 }
        XCTAssertNil(result, "Main actor must remain available while the worker is parked")
        XCTAssertFalse(probe.ranOnMain)
        XCTAssertFalse(operation.start(work: { 2 }, completion: { _ in XCTFail("Duplicate export admitted") }))
        operation.cancel()
        XCTAssertTrue(operation.isRunning, "Cancellation must retain admission until the worker finishes")
        probe.release.signal()
        await operation.stop()
        let exported = try XCTUnwrap(result).get()
        XCTAssertFalse(operation.isRunning)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported.jsonURL)) as? [String: Any])
        XCTAssertEqual(json["record_count"] as? Int, 1)
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(records.first?["event"] as? String, "native_export_fixture")
        XCTAssertTrue(try String(contentsOf: exported.markdownURL, encoding: .utf8).contains("native_export_fixture"))
    }

    func testCooperativeCancellationAndFailureEachAllowRetryAfterCompletion() async throws {
        let probe = BootstrapProbe()
        let operation = AppBackgroundOperation()
        var cancelled = false
        XCTAssertTrue(operation.start {
            _ = probe.started()
            try await Task.sleep(for: .seconds(10))
            return 1
        } completion: { result in
            guard case .failure(is CancellationError) = result else { return XCTFail("Cancellation was lost") }
            cancelled = true
        })
        try await waitUntil { probe.startCount == 1 }
        await operation.stop()
        XCTAssertTrue(cancelled)
        var failed = false
        XCTAssertTrue(operation.start(work: { () throws -> Int in
            throw BootstrapFixtureError.expectedFailure
        }, completion: { result in
            guard case .failure(BootstrapFixtureError.expectedFailure) = result else { return XCTFail("Failure was lost") }
            failed = true
        }))
        try await waitUntil { failed }
        var completed = false
        XCTAssertTrue(operation.start(work: { 3 }, completion: { result in
            XCTAssertEqual(try? result.get(), 3)
            completed = true
        }))
        try await waitUntil { completed }
        XCTAssertFalse(operation.isRunning)
    }

    func testReleasedOwnerCancelsWorkAndDoesNotReceiveCompletion() async throws {
        let probe = BootstrapProbe()
        var operation: AppBackgroundOperation? = AppBackgroundOperation()
        weak let released = operation
        operation?.start {
            _ = probe.started()
            do {
                try await Task.sleep(for: .seconds(10))
                XCTFail("Owner release did not cancel worker")
            } catch is CancellationError {
                _ = probe.started()
            }
            return 1
        } completion: { _ in XCTFail("Released owner received completion") }
        try await waitUntil { probe.startCount == 1 }
        operation = nil
        XCTAssertNil(released)
        try await waitUntil { probe.startCount == 2 }
    }
}

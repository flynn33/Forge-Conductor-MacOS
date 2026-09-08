import XCTest
@testable import ForgeConductorCore

final class ManagerProviderOwnershipTests: XCTestCase {
    func testShutdownWaitsForActualProviderSettingsOperation() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("manager-settings-owner-\(UUID())")
        let app = try ForgeApp.bootstrap(home: home)
        let entered = expectation(description: "settings operation admitted")
        let service = ManagerProviderHeldSettings(entered: entered)
        let registry = HostAdapterRegistry()
        registry.register(manifest: HostPluginManifest(identifier: ManagerNode.nativeSessionHostAdapterID,
            version: "fixture", minimumContractVersion: 2, hostType: "fixture",
            capabilities: HostCapabilities(create: false, bootstrap: false, usageReporting: false,
                resume: false, idempotency: false, queryByIdempotencyKey: false),
            configurationKeys: [], privacyRequirements: [], migrationVersion: 1),
            configurationFactory: { _ in service }, factory: { _ in throw AutonomyError.shutdown })
        let manager = ManagerNode(app: app, hostAdapterRegistry: registry)
        defer {
            service.release.signal()
            XCTAssertTrue(manager.shutdownManagedAutonomy())
            XCTAssertTrue(manager.shutdownNativeTaskAttachment())
            app.shutdown()
            try? FileManager.default.removeItem(at: home)
        }
        let settings = Task.detached { try manager.readProviderConfiguration() }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertFalse(manager.shutdownManagedAutonomy(), "An admitted settings request remains an owner without a run")
        XCTAssertThrowsError(try manager.readProviderConfiguration()) {
            XCTAssertEqual($0 as? ProviderConfigurationError, .busy)
        }
        let health = try await app.runtimeJobs.repository.health()
        XCTAssertEqual(health.integrity, "ok")
        service.release.signal()
        _ = try await settings.value
        XCTAssertTrue(manager.shutdownManagedAutonomy())
    }

    func testIncompleteProviderDrainKeepsStoresAndRejectsReplacementRuntime() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("manager-provider-owner-\(UUID())")
        let app = try ForgeApp.bootstrap(home: home)
        let runtime = try ManagedAutonomyRuntime(app: app, maximumConcurrentRuns: 1)
        let creations = ManagerProviderFactoryCount()
        let manager = ManagerNode(app: app, managedAutonomyFactory: { _ in
            creations.increment()
            return runtime
        })
        let permit = try XCTUnwrap(runtime.providerWorkAdmission.tryAcquire(
            owner: .source(taskID: UUID(), requestID: UUID())))
        defer {
            _ = runtime.providerWorkAdmission.release(permit)
            XCTAssertTrue(manager.shutdownManagedAutonomy())
            XCTAssertTrue(manager.shutdownNativeTaskAttachment())
            app.shutdown()
            try? FileManager.default.removeItem(at: home)
        }

        XCTAssertNotNil(try manager.recoverManagedAutonomy())
        XCTAssertFalse(manager.shutdownManagedAutonomy())
        XCTAssertFalse(runtime.providerWorkAdmission.isOpen)
        XCTAssertEqual(runtime.providerWorkAdmission.activeCount, 1)
        XCTAssertFalse(manager.shutdownManagedAutonomy(), "A retry must retain the same unsettled owner")
        XCTAssertThrowsError(try manager.recoverManagedAutonomy())
        XCTAssertEqual(creations.value, 1, "Shutdown must not replace a runtime with outstanding capacity")
        XCTAssertThrowsError(try manager.readProviderConfiguration()) {
            XCTAssertEqual($0 as? ProviderConfigurationError, .busy)
        }
        let runs = try await app.projectContexts.repository.operatorAutonomousRuns(limit: 1)
        XCTAssertTrue(runs.isEmpty)
        let health = try await app.runtimeJobs.repository.health()
        XCTAssertEqual(health.integrity, "ok")

        XCTAssertTrue(runtime.providerWorkAdmission.release(permit))
        XCTAssertTrue(manager.shutdownManagedAutonomy())
        XCTAssertEqual(runtime.providerWorkAdmission.activeCount, 0)
        XCTAssertEqual(creations.value, 1)
    }

    func testShutdownDuringFactoryCreationFencesLateStartupAndRetainsCleanupOwner() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("manager-startup-owner-\(UUID())")
        let app = try ForgeApp.bootstrap(home: home)
        let runtime = try ManagedAutonomyRuntime(app: app, maximumConcurrentRuns: 1)
        let entered = expectation(description: "runtime factory owns startup")
        let release = DispatchSemaphore(value: 0)
        let creations = ManagerProviderFactoryCount()
        let manager = ManagerNode(app: app, managedAutonomyFactory: { _ in
            creations.increment()
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
            return runtime
        })
        defer {
            release.signal()
            XCTAssertTrue(manager.shutdownManagedAutonomy())
            XCTAssertTrue(manager.shutdownNativeTaskAttachment())
            app.shutdown()
            try? FileManager.default.removeItem(at: home)
        }
        let startup = Task.detached { try manager.recoverManagedAutonomy() }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertFalse(manager.shutdownManagedAutonomy(), "A factory in progress is still an owned startup")
        XCTAssertThrowsError(try manager.recoverManagedAutonomy())
        XCTAssertEqual(creations.value, 1)
        let health = try await app.runtimeJobs.repository.health()
        XCTAssertEqual(health.integrity, "ok")
        release.signal()
        do {
            _ = try await startup.value
            XCTFail("A runtime created after shutdown began must not start")
        } catch { XCTAssertEqual((error as? AutonomyError)?.code, AutonomyError.shutdown.code) }
        let snapshot = await runtime.snapshot()
        XCTAssertFalse(snapshot.started)
        XCTAssertTrue(snapshot.supervisor.activeRunIDs.isEmpty)
        XCTAssertTrue(manager.shutdownManagedAutonomy())
        XCTAssertFalse(runtime.providerWorkAdmission.isOpen)
    }
}

private final class ManagerProviderFactoryCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class ManagerProviderHeldSettings: ProviderConfigurationServicing, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let entered: XCTestExpectation
    init(entered: XCTestExpectation) { self.entered = entered }
    private func waitForRelease() -> Bool { release.wait(timeout: .now() + 5) == .success }
    func read() async throws -> ProviderConfigurationSnapshot {
        entered.fulfill()
        guard waitForRelease() else { throw CancellationError() }
        return .init(revision: "fixture", endpoint: "http://127.0.0.1:1234", modelKey: nil,
            credentialConfigured: false, saved: false)
    }
    func update(_ request: ProviderConfigurationUpdate) async throws -> ProviderConfigurationSnapshot {
        throw ProviderConfigurationError.busy
    }
    func models() async throws -> ProviderModelInventory { throw ProviderConfigurationError.busy }
}

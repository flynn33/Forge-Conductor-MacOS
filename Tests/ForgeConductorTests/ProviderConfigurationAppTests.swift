import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif
@testable import ForgeConductorCore

private actor ProviderBusyService: ProviderConfigurationServicing {
    var entered = false
    var updates = 0
    private let snapshot = ProviderConfigurationSnapshot(revision: "0", endpoint: "http://127.0.0.1:1234",
        modelKey: nil, credentialConfigured: false, saved: true)
    func read() -> ProviderConfigurationSnapshot { snapshot }
    func update(_ request: ProviderConfigurationUpdate) -> ProviderConfigurationSnapshot {
        updates += 1
        return snapshot
    }
    func models() async throws -> ProviderModelInventory {
        entered = true
        try await Task.sleep(for: .seconds(1))
        return ProviderModelInventory(revision: "0", models: [])
    }
}

final class ProviderConfigurationAppTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-client-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func request(_ revision: String = "0") -> ProviderConfigurationUpdate {
        ProviderConfigurationUpdate(expectedRevision: revision, endpoint: "http://127.0.0.1:1234",
            modelKey: "fixture/tool-model", credentialAction: .keep)
    }

    func testBusyProviderRouteRejectsCredentialBodiesWithoutDispatchingMutations() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        defer { app.shutdown() }
        let port = Int.random(in: 29000...39000)
        try app.config.update(["dashboard": ["port": port]], save: true)
        let service = ProviderBusyService()
        let registry = HostAdapterRegistry()
        registry.register(manifest: ForgeNativeSessionHostPlugin.manifest,
            configurationFactory: { _ in service }, factory: { _ in throw ContinuityRunError.hostCapabilityUnavailable })
        let manager = ManagerNode(app: app, hostAdapterRegistry: registry)
        _ = try manager.startService()
        defer { _ = try? manager.stopService() }
        let client = OperatorManagerClientRouter(client:
            OperatorManagerHTTPClient(host: "127.0.0.1", port: port,
                credentials: ManagerControlCredentialStore(paths: app.paths)))
        let inventory = Task { try await client.providerModels() }
        for _ in 0..<100 {
            if await service.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await service.entered
        XCTAssertTrue(entered)
        for _ in 0..<8 {
            do {
                _ = try await client.updateProviderConfiguration(ProviderConfigurationUpdate(
                    expectedRevision: "0", endpoint: "http://127.0.0.1:1234", modelKey: nil,
                    credentialAction: .replace, token: UUID().uuidString))
                XCTFail("Busy route accepted a credential mutation")
            } catch let error as OperatorManagerClientError {
                guard case .rejected(status: 409, message: _) = error else { return XCTFail("Wrong admission result") }
            }
        }
        _ = try await inventory.value
        let updates = await service.updates
        XCTAssertEqual(updates, 0)
        _ = try await client.providerConfiguration()
    }

    func testProviderConfigurationRoutesRequireAuthorizationAndClientPersistsCleanSetup() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        defer { app.shutdown() }
        let port = Int.random(in: 29000...39000)
        try app.config.update(["dashboard": ["port": port]], save: true)
        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        let manager = ManagerNode(app: app, hostAdapterRegistry: registry)
        _ = try manager.startService()
        defer { _ = try? manager.stopService() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/manager/provider/configuration"))
        var unauthorized = URLRequest(url: url)
        unauthorized.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: unauthorized)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        let credential = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        unauthorized.httpMethod = "PUT"
        unauthorized.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        unauthorized.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (body, expectedStatus) in [(Data(repeating: 32, count: 16385), 413),
            (Data("{\"unexpected\":true}".utf8), 400)] {
            unauthorized.httpBody = body
            let (_, rejected) = try await URLSession.shared.data(for: unauthorized)
            XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, expectedStatus)
        }
        let transport = OperatorManagerHTTPClient(host: "127.0.0.1", port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths))
        let client = OperatorManagerClientRouter(client:
            UnavailableOperatorManagerClient(reason: "Waiting for the configured manager"))
        client.replace(with: transport)
        let clean = try await client.providerConfiguration()
        XCTAssertFalse(clean.saved)
        let saved = try await client.updateProviderConfiguration(request(clean.revision))
        XCTAssertTrue(saved.saved)
        let reread = try await client.providerConfiguration()
        XCTAssertEqual(reread, saved)
        do { _ = try await client.updateProviderConfiguration(request(clean.revision)); XCTFail("Stale manager update accepted") }
        catch let error as OperatorManagerClientError {
            guard case .rejected(status: 409, message: _) = error else { return XCTFail("Wrong conflict result") }
        }
        // Production registration retrieves persisted settings on a fresh owner.
        let restarted = ManagerNode(app: app, hostAdapterRegistry: registry)
        XCTAssertEqual(try restarted.readProviderConfiguration(), saved)
        client.replace(with: UnavailableOperatorManagerClient(reason: "Manager connection replaced"))
        do { _ = try await client.providerConfiguration(); XCTFail("The router retained the replaced manager") }
        catch let error as OperatorManagerClientError {
            XCTAssertEqual(error, .disabled("Manager connection replaced"))
        }
        client.replace(with: transport)
        let reconnected = try await client.providerConfiguration()
        XCTAssertEqual(reconnected, saved)
    }
}

import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
@testable import ForgeConductorApp
#else
@testable import Forge_Conductor
#endif
@testable import ForgeConductorCore

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
        let client = OperatorManagerHTTPClient(host: "127.0.0.1", port: port,
            credentials: ManagerControlCredentialStore(paths: app.paths))
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
    }
}

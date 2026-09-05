import XCTest
import Security
import LocalAuthentication
#if SWIFT_PACKAGE
@testable import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

private final class ProviderInventoryFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix("provider.fixture") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.path == "/api/v1/models",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json", "X-LM-Studio-Version": "0.3.fixture"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let models: [[String: Any]]
        if url.host == "empty.provider.fixture" { models = [] }
        else {
            models = [["key": "fixture/tool-model", "capabilities": ["trained_for_tool_use": true],
                       "loaded_instances": url.host == "unloaded.provider.fixture" ? [] : [
                           ["id": "fixture/tool-model@32768", "config": ["context_length": 32768]]
                       ]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["models": models])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ProviderCredentialFixture: LMStudioCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var denyInsertion = false
    var denyRemoval = false
    func insert(token: String, reference: String) throws {
        lock.lock(); defer { lock.unlock() }
        if denyInsertion { throw ProviderConfigurationError.credentialUnavailable }
        values[reference] = token
    }
    func remove(reference: String) throws {
        lock.lock(); defer { lock.unlock() }
        if denyRemoval { throw ProviderConfigurationError.credentialUnavailable }
        values.removeValue(forKey: reference)
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    func contains(_ reference: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return values[reference] != nil
    }
}

private final class DisposableKeychainRecorder: LMStudioCredentialStoring, @unchecked Sendable {
    private let store = LMStudioKeychainCredentialStore()
    private let lock = NSLock()
    private var inserted: Set<String> = []
    func insert(token: String, reference: String) throws {
        lock.lock(); inserted.insert(reference); lock.unlock()
        try store.insert(token: token, reference: reference)
    }
    func remove(reference: String) throws { try store.remove(reference: reference) }
    func cleanup() throws {
        lock.lock(); let references = inserted; lock.unlock()
        for reference in references { try store.remove(reference: reference) }
    }
}

final class ProviderConfigurationTests: XCTestCase {
    private var directory: URL!
    private var credentials: ProviderCredentialFixture!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-settings-" + UUID().uuidString)
        credentials = ProviderCredentialFixture()
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func request(_ revision: String = "0", endpoint: String = "http://127.0.0.1:1234",
                         model: String? = "fixture/tool-model", action: ProviderCredentialAction = .keep,
                         token: String? = nil) -> ProviderConfigurationUpdate {
        ProviderConfigurationUpdate(expectedRevision: revision, endpoint: endpoint, modelKey: model,
                                    credentialAction: action, token: token)
    }

    func testNoninteractiveKeychainDenialLockedAndCancellationReturnTypedFailure() throws {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled] {
            let store = LMStudioKeychainCredentialStore(addItem: { query in
                let attributes = query as NSDictionary
                let context = attributes[kSecUseAuthenticationContext] as? LAContext
                XCTAssertTrue(context?.interactionNotAllowed == true)
                return status
            }, deleteItem: { _ in status })
            XCTAssertThrowsError(try store.insert(token: UUID().uuidString, reference: UUID().uuidString)) {
                XCTAssertEqual($0 as? ProviderConfigurationError, .credentialUnavailable)
            }
            XCTAssertThrowsError(try store.remove(reference: UUID().uuidString)) {
                XCTAssertEqual($0 as? ProviderConfigurationError, .credentialUnavailable)
            }
        }
    }

    func testDisposableRealKeychainKeepReplaceClearAndRestart() async throws {
        guard ProcessInfo.processInfo.environment["FORGE_TEST_DISPOSABLE_KEYCHAIN"] == "1" else {
            throw XCTSkip("Set FORGE_TEST_DISPOSABLE_KEYCHAIN=1 to exercise unique disposable Keychain items")
        }
        let store = DisposableKeychainRecorder()
        defer {
            do { try store.cleanup() }
            catch { XCTFail("Disposable provider credential cleanup failed") }
        }
        let service = LMStudioConfigurationService(storageDirectory: directory, credentials: store)
        let originalToken = UUID().uuidString + UUID().uuidString
        let saved = try await service.update(request(action: .replace, token: originalToken))
        let originalConfig = try XCTUnwrap(LMStudioProviderConfiguration.loadIfPresent(in: directory))
        let originalReference = try XCTUnwrap(originalConfig.keychainTokenReference)
        let originalRead = try await LMStudioKeychainAuthorization(reference: originalReference).bearerToken()
        XCTAssertTrue(originalRead == originalToken, "Disposable credential could not be read back")
        let restarted = LMStudioConfigurationService(storageDirectory: directory, credentials: store)
        let kept = try await restarted.update(request(saved.revision))
        XCTAssertTrue(kept.credentialConfigured)
        let keptRead = try await LMStudioKeychainAuthorization(reference: originalReference).bearerToken()
        XCTAssertTrue(keptRead == originalToken, "Keep changed the disposable credential")
        let replacementToken = UUID().uuidString + UUID().uuidString
        let replaced = try await restarted.update(request(kept.revision, action: .replace, token: replacementToken))
        let replacementConfig = try XCTUnwrap(LMStudioProviderConfiguration.loadIfPresent(in: directory))
        let replacementReference = try XCTUnwrap(replacementConfig.keychainTokenReference)
        XCTAssertNotEqual(originalReference, replacementReference)
        let replacementRead = try await LMStudioKeychainAuthorization(reference: replacementReference).bearerToken()
        XCTAssertTrue(replacementRead == replacementToken, "Replacement credential did not survive owner restart")
        do { _ = try await LMStudioKeychainAuthorization(reference: originalReference).bearerToken(); XCTFail("Retired credential remains accessible") }
        catch let error as LMStudioProviderError {
            guard case .invalidConfiguration = error else { return XCTFail("Unexpected retired credential failure") }
        }
        let cleared = try await restarted.update(request(replaced.revision, action: .clear))
        XCTAssertFalse(cleared.credentialConfigured)
        XCTAssertFalse(cleared.credentialCleanupPending)
        do { _ = try await LMStudioKeychainAuthorization(reference: replacementReference).bearerToken(); XCTFail("Cleared credential remains accessible") }
        catch let error as LMStudioProviderError {
            guard case .invalidConfiguration = error else { return XCTFail("Unexpected cleared credential failure") }
        }
    }

    func testCleanSettingsSaveThroughServiceSurvivesOwnerRestartWithOwnerOnlyFile() async throws {
        let service = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials)
        let clean = try await service.read()
        XCTAssertFalse(clean.saved)
        let saved = try await service.update(request())
        XCTAssertTrue(saved.saved)
        XCTAssertNotEqual(saved.revision, "0")
        let restarted = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials)
        let reread = try await restarted.read()
        XCTAssertEqual(reread, saved)
        let path = directory.appendingPathComponent(LMStudioProviderConfiguration.fileName)
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testMalformedOriginsAndTokenActionsRetainLastValidConfiguration() async throws {
        let service = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials)
        let saved = try await service.update(request())
        for endpoint in ["http://remote.invalid", "https://user:password@remote.invalid", "https://remote.invalid?x=1",
                         "https://remote.invalid#fragment", "https://remote.invalid/api/v1", "file:///tmp/test"] {
            do { _ = try await service.update(request(saved.revision, endpoint: endpoint)); XCTFail("Accepted invalid origin") }
            catch { XCTAssertEqual(error as? ProviderConfigurationError, .invalidRequest) }
        }
        for update in [request(saved.revision, token: "transient-fixture-value"),
                       request(saved.revision, action: .replace),
                       request(saved.revision, action: .replace, token: "line\nbreak"),
                       request(saved.revision, model: String(repeating: "m", count: 513))] {
            do { _ = try await service.update(update); XCTFail("Accepted invalid update") }
            catch { XCTAssertEqual(error as? ProviderConfigurationError, .invalidRequest) }
        }
        let reread = try await service.read()
        XCTAssertEqual(reread, saved)
        XCTAssertEqual(credentials.count, 0)
    }

    func testKeepReplaceAndClearCredentialsNeverPersistSecretAndRecoverCleanup() async throws {
        let service = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials)
        let first = try await service.update(request(action: .replace, token: "transient-fixture-value"))
        let initial = try XCTUnwrap(LMStudioProviderConfiguration.loadIfPresent(in: directory))
        let initialReference = try XCTUnwrap(initial.keychainTokenReference)
        XCTAssertTrue(credentials.contains(initialReference))
        let kept = try await service.update(request(first.revision))
        XCTAssertTrue(kept.credentialConfigured)
        XCTAssertTrue(credentials.contains(initialReference))
        credentials.denyRemoval = true
        let replaced = try await service.update(request(kept.revision, action: .replace, token: "replacement-fixture-value"))
        XCTAssertTrue(replaced.credentialCleanupPending)
        XCTAssertEqual(credentials.count, 2)
        do { _ = try await service.update(request(replaced.revision)); XCTFail("Unbounded credential accumulation") }
        catch { XCTAssertEqual(error as? ProviderConfigurationError, .credentialUnavailable) }
        credentials.denyRemoval = false
        let restarted = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials)
        let recovered = try await restarted.read()
        XCTAssertFalse(recovered.credentialCleanupPending)
        XCTAssertEqual(credentials.count, 1)
        XCTAssertFalse(credentials.contains(initialReference))
        let cleared = try await restarted.update(request(recovered.revision, action: .clear))
        XCTAssertFalse(cleared.credentialConfigured)
        XCTAssertEqual(credentials.count, 0)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("fixture-value"), "Credential escaped into persistence")
        }
    }

    func testDeniedKeychainRetainsPriorCredentialAndConfiguration() async throws {
        let service = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials)
        let saved = try await service.update(request(action: .replace, token: "transient-fixture-value"))
        credentials.denyInsertion = true
        do { _ = try await service.update(request(saved.revision, action: .replace, token: "replacement-fixture-value")); XCTFail("Accepted denied Keychain write") }
        catch { XCTAssertEqual(error as? ProviderConfigurationError, .credentialUnavailable) }
        let reread = try await service.read()
        XCTAssertEqual(reread, saved)
        XCTAssertEqual(credentials.count, 1)
    }

    func testInterruptedPersistencePreservesPriorCredentialAndCleansStagedCredential() async throws {
        let service = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials)
        let saved = try await service.update(request(action: .replace, token: "transient-fixture-value"))
        let failing = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials, persist: { data, url in
            if url.lastPathComponent == LMStudioProviderConfiguration.fileName { throw ProviderConfigurationError.persistenceFailed }
            try OwnerOnlyAtomicFile.write(data, to: url)
        })
        do { _ = try await failing.update(request(saved.revision, action: .replace, token: "replacement-fixture-value")); XCTFail("Accepted failed persistence") }
        catch { XCTAssertEqual(error as? ProviderConfigurationError, .persistenceFailed) }
        let reread = try await service.read()
        XCTAssertEqual(reread, saved)
        XCTAssertEqual(credentials.count, 1)
    }

    func testCommittedRenameThenSynchronizationFailureKeepsNewCredential() async throws {
        let service = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials)
        let saved = try await service.update(request(action: .replace, token: "transient-fixture-value"))
        let ambiguous = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials, persist: { data, url in
            try OwnerOnlyAtomicFile.write(data, to: url)
            if url.lastPathComponent == LMStudioProviderConfiguration.fileName { throw ProviderConfigurationError.persistenceFailed }
        })
        do { _ = try await ambiguous.update(request(saved.revision, action: .replace, token: "replacement-fixture-value")); XCTFail("Ambiguous durability reported as saved") }
        catch { XCTAssertEqual(error as? ProviderConfigurationError, .persistenceFailed) }
        XCTAssertEqual(credentials.count, 2)
        let reread = try await service.read()
        XCTAssertNotEqual(reread.revision, saved.revision)
        XCTAssertEqual(credentials.count, 1)
        XCTAssertFalse(reread.credentialCleanupPending)
    }

    func testConcurrentUpdatesHaveOneWinnerAndRejectStaleRevisionAfterRestart() async throws {
        let service = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials)
        let saved = try await service.update(request())
        let update = request(saved.revision)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { (try? await service.update(update)) != nil }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
        let restarted = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials)
        do { _ = try await restarted.update(update); XCTFail("Stale revision accepted") }
        catch { XCTAssertEqual(error as? ProviderConfigurationError, .revisionConflict) }
    }

    func testModelInventoryUsesExistingTransportAndReportsLoadedState() async throws {
        let service = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials, inventory: { config in
            let session = URLSessionConfiguration.ephemeral
            session.protocolClasses = [ProviderInventoryFixture.self]
            return try await LMStudioRESTClient(configuration: config, sessionConfiguration: session).listModels()
        })
        let saved = try await service.update(request(endpoint: "https://loaded.provider.fixture"))
        let inventory = try await service.models()
        XCTAssertEqual(inventory.revision, saved.revision)
        XCTAssertEqual(inventory.models.first?.key, "fixture/tool-model")
        XCTAssertEqual(inventory.models.first?.loaded, true)
        XCTAssertEqual(inventory.models.first?.toolUseCapable, true)
    }

    func testNoModelInvalidModelAndUnloadedModelAreActionableAndDistinct() async throws {
        for (host, model, expected) in [("empty.provider.fixture", nil, "no models are available"),
            ("loaded.provider.fixture", "not-present", "configured model was not found"),
            ("unloaded.provider.fixture", "fixture/tool-model", "configured model is unloaded")] {
            let session = URLSessionConfiguration.ephemeral
            session.protocolClasses = [ProviderInventoryFixture.self]
            let client = try LMStudioRESTClient(configuration: LMStudioProviderConfiguration(
                baseURL: URL(string: "https://" + host)!, modelKey: model), sessionConfiguration: session)
            do { _ = try await client.probe(); XCTFail("Unusable model passed probe") }
            catch { XCTAssertTrue(error.localizedDescription.contains(expected)) }
        }
    }

    func testCancellationReleasesInventoryAdmissionWithoutChangingConfiguration() async throws {
        let entered = expectation(description: "inventory entered")
        let service = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials, inventory: { _ in
            entered.fulfill()
            try await Task.sleep(for: .seconds(5))
            return []
        })
        let saved = try await service.update(request())
        let operation = Task { try await service.models() }
        await fulfillment(of: [entered], timeout: 1)
        do { _ = try await service.update(request(saved.revision)); XCTFail("Overlapped inventory") }
        catch { XCTAssertEqual(error as? ProviderConfigurationError, .busy) }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled inventory succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let reread = try await service.read()
        XCTAssertEqual(reread, saved)
        _ = try await service.update(request(saved.revision))
    }

    func testInventoryAuthenticationOfflineAndTimeoutAreDistinctAndRedacted() async throws {
        let failures: [(LMStudioProviderError, ProviderConfigurationError)] = [
            (.unauthorized, .authenticationFailed), (.forbidden, .authenticationFailed),
            (.providerUnavailable, .offline), (.deadlineExceeded(phase: "transient-fixture-value"), .timeout),
            (.malformedResponse("transient-fixture-value"), .connectionFailed),
            (.endpointNotFound, .modelEndpointUnavailable),
        ]
        let initial = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials)
        _ = try await initial.update(request())
        for (failure, expected) in failures {
            let service = LMStudioConfigurationService(storageDirectory: directory, credentials: credentials,
                                                       inventory: { _ in throw failure })
            do { _ = try await service.models(); XCTFail("Failed inventory succeeded") }
            catch {
                XCTAssertEqual(error as? ProviderConfigurationError, expected)
                XCTAssertFalse(error.localizedDescription.contains("fixture-value"))
            }
        }
    }

    func testNonterminalDurableRunFencesConfigurationWithoutChangingRun() async throws {
        let app = try ForgeApp.bootstrap(home: directory)
        defer { app.shutdown() }
        let registry = HostAdapterRegistry()
        ForgeNativeSessionHostPlugin.register(in: registry)
        let manager = ManagerNode(app: app, hostAdapterRegistry: registry)
        let saved = try manager.updateProviderConfiguration(request())
        let root = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registered = try manager.registerProject(path: root.path, displayName: "Provider Fixture")
        let uuid = try XCTUnwrap((registered["project_id"] as? String).flatMap(UUID.init(uuidString:)))
        let storedProject = try await app.projectContexts.repository.project(ProjectID(uuid))
        let project = try XCTUnwrap(storedProject)
        let run = try await app.projectContexts.repository.createAutonomousRun(AutonomousRunRequest(
            projectID: project.projectID, projectGeneration: project.generation,
            mission: "Preserve active run", providerID: "lmstudio", adapterID: "forge.native-session-host",
            modelKey: "fixture-model", specification: AutonomousRunSpecification(
                allowedTools: ["project_memory.search"], completionGates: ["fixture-gate"]),
            authorizationScope: ToolAuthorizationScope(canonicalRoots: [root], allowedTools: ["project_memory.search"],
                networkAllowed: false, maximumInlineOutputBytes: 1024)))
        XCTAssertThrowsError(try manager.updateProviderConfiguration(request(saved.revision))) { error in
            XCTAssertEqual(error as? ProviderConfigurationError, .busy)
        }
        let retained = try await app.projectContexts.repository.autonomousRun(run.runID)
        XCTAssertEqual(retained?.state, run.state)
        XCTAssertEqual(try manager.readProviderConfiguration(), saved)
    }

}

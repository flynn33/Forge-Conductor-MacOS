// Exercises the ordinary GUI bootstrap, native folder picker, and real manager.
// These tests deliberately do not use the unavailable-manager or panel fixtures.

import Darwin
import Foundation
import XCTest

/// The test runner must have macOS Automation permission and an unlocked session.
/// Run this class serially against the signed application under qualification.
/// Only the real-provider test requires FORGE_SHIPPING_PROVIDER_ENDPOINT and
/// FORGE_SHIPPING_PROVIDER_MODEL in the test runner environment. Use an already
/// loaded, token-free local LM Studio server; this suite never loads a model,
/// installs a service, edits an external host configuration, or supplies a token.
@MainActor
final class ProductionOnboardingUITests: XCTestCase, @unchecked Sendable {
    private var app: XCUIApplication!
    private var fixture: URL!
    private var forgeHome: URL!
    private var projectRoot: URL!
    private var managerPort: UInt16 = 0
    private var session: URLSession!

    nonisolated override func setUpWithError() throws {
        try MainActor.assumeIsolated {
            continueAfterFailure = false
            fixture = FileManager.default.temporaryDirectory
                .appendingPathComponent("forge-production-onboarding-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            forgeHome = fixture.appendingPathComponent("home", isDirectory: true)
            projectRoot = fixture.appendingPathComponent("Project Folder", isDirectory: true)
            for directory in [forgeHome!, projectRoot!] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }

            // A fresh home does not isolate the default dashboard port. Seed only
            // supported manager transport configuration before ordinary bootstrap.
            // Allowed roots and managed provider configuration remain unprovisioned.
            let reservation = try OnboardingPortReservation()
            managerPort = reservation.port
            let transport: [String: Any] = [
                "config_schema_version": 2,
                "dashboard": ["host": "127.0.0.1", "port": Int(managerPort)],
            ]
            let configurationURL = forgeHome.appendingPathComponent("config.json")
            try JSONSerialization.data(withJSONObject: transport, options: [.sortedKeys])
                .write(to: configurationURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: configurationURL.path
            )

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 3
            configuration.timeoutIntervalForResource = 45
            configuration.urlCache = nil
            session = URLSession(configuration: configuration)
            app = XCUIApplication()
            app.launchEnvironment["FORGE_CONDUCTOR_HOME"] = forgeHome.path
            reservation.close()
        }
    }

    nonisolated override func tearDownWithError() throws {
        try MainActor.assumeIsolated {
            if app?.state != .notRunning {
                attachScreenshot("onboarding-final-state")
                app?.terminate()
            }
            session?.invalidateAndCancel()
            session = nil
            guard app == nil || app.state == .notRunning else {
                XCTFail("Application did not terminate; isolated fixture retained at \(fixture.path)")
                return
            }
            app = nil
            if let fixture { try FileManager.default.removeItem(at: fixture) }
            fixture = nil
        }
    }

    func testNativeFolderAuthorizationCancellationAndInvalidRootPreserveSavedSettings() async throws {
        _ = try await launchOrdinaryApplication()
        let baseline: OnboardingManagerSettings = try await read("/api/manager/settings")
        XCTAssertEqual(baseline.allowedRoots, [])
        openManager()
        XCTAssertTrue(element("settings-allowed-roots-empty").waitForExistence(timeout: 5))

        openFolderPicker()
        chooseFolderInNativePanel(projectRoot.path)
        XCTAssertTrue(waitUntil { self.contains(self.element("settings-allowed-root-path-0"), self.projectRoot.path) })
        attachScreenshot("native-folder-staged")
        click(app.buttons["settings-save"])
        let saved = try await waitForSettings(roots: [projectRoot.path])
        attach("authorized-folder-manager-readback", saved)

        openFolderPicker()
        click(app.buttons["Cancel"].firstMatch)
        XCTAssertTrue(waitUntil {
            self.contains(self.element("settings-allowed-roots-message"), "No project folder was added")
        })
        let afterCancellation: OnboardingManagerSettings = try await read("/api/manager/settings")
        XCTAssertEqual(afterCancellation, saved)

        openFolderPicker()
        chooseFolderInNativePanel("/")
        XCTAssertTrue(waitUntil {
            self.contains(self.element("settings-allowed-roots-message"), "The filesystem root cannot be authorized")
        })
        XCTAssertTrue(contains(element("settings-allowed-root-path-0"), projectRoot.path))
        XCTAssertFalse(element("settings-allowed-root-path-1").exists)
        click(app.buttons["settings-save"])
        let afterRejection = try await waitForSettings(roots: [projectRoot.path])
        XCTAssertEqual(afterRejection, saved)
        attachScreenshot("native-filesystem-root-rejected")

        app.terminate()
        _ = try await launchOrdinaryApplication()
        openManager()
        XCTAssertTrue(waitUntil { self.contains(self.element("settings-allowed-root-path-0"), self.projectRoot.path) })
        let persisted: OnboardingManagerSettings = try await read("/api/manager/settings")
        XCTAssertEqual(persisted, saved)
        attach("authorized-folder-after-relaunch", persisted)
    }

    func testNativeProviderSaveOfflineFailureAndInvalidEndpointsSurviveManagerReplacement() async throws {
        // A bound, non-listening socket keeps the offline endpoint deterministic
        // without standing in for a model server or accepting provider requests.
        let offlinePort = try OnboardingPortReservation()
        defer { offlinePort.close() }
        let endpoint = "http://127.0.0.1:\(offlinePort.port)"
        let firstManager = try await launchOrdinaryApplication()
        let initial: OnboardingProviderConfiguration = try await read("/api/manager/provider/configuration")
        XCTAssertFalse(initial.saved)
        XCTAssertFalse(initial.credentialConfigured)
        XCTAssertEqual(initial.revision, "0")

        openProvider()
        let saved = try await saveProvider(endpoint: endpoint, model: "onboarding-offline-model")
        XCTAssertFalse(saved.credentialConfigured)
        XCTAssertFalse(saved.credentialCleanupPending)
        XCTAssertNotEqual(saved.revision, initial.revision)
        XCTAssertTrue(contains(element("provider-probe-notice"), "Test Connection"))

        click(app.buttons["provider-test-connection"])
        XCTAssertTrue(element("operator-unavailable").waitForExistence(timeout: 40))
        XCTAssertFalse(contains(element("provider-probe-notice"), "are reachable"))
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.element("provider-last-probe-error").exists
                && !self.contains(self.element("provider-health"), "reachable")
        })
        let afterOfflineProbe: OnboardingProviderConfiguration = try await read("/api/manager/provider/configuration")
        XCTAssertEqual(afterOfflineProbe, saved)
        attachScreenshot("native-provider-offline-error")

        for invalidEndpoint in [
            "not-an-endpoint", "http://provider.example.invalid", "http://127.0.0.1:1234?unsupported=1",
        ] {
            replace(app.textFields["provider-endpoint"], with: invalidEndpoint)
            click(app.buttons["provider-save"])
            XCTAssertTrue(element("operator-unavailable").waitForExistence(timeout: 10))
            XCTAssertTrue(waitUntil { self.app.buttons["provider-save"].isEnabled })
            let afterInvalidSave: OnboardingProviderConfiguration = try await read("/api/manager/provider/configuration")
            XCTAssertEqual(afterInvalidSave, saved, "Rejected endpoint changed the last valid provider configuration")
        }
        attachScreenshot("native-provider-invalid-endpoint")

        app.terminate()
        let replacement = try await launchOrdinaryApplication()
        XCTAssertNotEqual(replacement.pid, firstManager.pid, "Relaunch must replace the actual GUI-owned manager process")
        let restored: OnboardingProviderConfiguration = try await read("/api/manager/provider/configuration")
        XCTAssertEqual(restored, saved)
        openProvider()
        XCTAssertTrue(waitUntil { (self.app.textFields["provider-endpoint"].value as? String) == endpoint })
        XCTAssertEqual(app.textFields["provider-model-key"].value as? String, saved.modelKey)
        click(app.buttons["provider-test-connection"])
        XCTAssertTrue(element("operator-unavailable").waitForExistence(timeout: 40))
        let afterReplacementProbe: OnboardingProviderConfiguration = try await read("/api/manager/provider/configuration")
        XCTAssertEqual(afterReplacementProbe, saved)
        attach("provider-configuration-after-manager-replacement", restored)
        attach("replacement-manager", replacement)
    }

    func testRealProviderModelDiscoveryAndConnectionFromSavedNativeConfiguration() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["FORGE_SHIPPING_PROVIDER_ENDPOINT"], !endpoint.isEmpty,
              let model = environment["FORGE_SHIPPING_PROVIDER_MODEL"], !model.isEmpty else {
            throw XCTSkip("Requires an owner-selected running local LM Studio server and loaded model via FORGE_SHIPPING_PROVIDER_ENDPOINT and FORGE_SHIPPING_PROVIDER_MODEL; live-provider qualification remains unexecuted.")
        }
        let components = try XCTUnwrap(URLComponents(string: endpoint))
        XCTAssertTrue(["127.0.0.1", "localhost", "::1"].contains(components.host ?? ""))
        XCTAssertTrue(["http", "https"].contains(components.scheme ?? ""))
        XCTAssertNil(components.user)
        XCTAssertNil(components.password)
        XCTAssertNil(components.query)
        XCTAssertNil(components.fragment)

        let originalManager = try await launchOrdinaryApplication()
        openProvider()
        let saved = try await saveProvider(endpoint: endpoint, model: model)
        click(app.buttons["provider-refresh-models"])
        XCTAssertTrue(waitUntil(timeout: 40) { self.app.buttons["provider-refresh-models"].isEnabled })
        XCTAssertFalse(element("operator-unavailable").exists, "The selected real server must return its model inventory")
        XCTAssertTrue(element("provider-model-selection").exists, "Native controls must expose the discovered models")
        let inventory: OnboardingProviderModels = try await read("/api/manager/provider/models", timeout: 40)
        XCTAssertEqual(inventory.revision, saved.revision)
        let loaded = try XCTUnwrap(inventory.models.first { $0.key == model })
        XCTAssertTrue(loaded.loaded, "The owner-selected model must already be loaded; the suite does not load it")
        XCTAssertTrue(loaded.toolUseCapable)
        attach("real-provider-model-discovery", inventory)
        try await assertRealConnection(model: model)
        attachScreenshot("real-provider-native-connection")

        app.terminate()
        let replacement = try await launchOrdinaryApplication()
        XCTAssertNotEqual(replacement.pid, originalManager.pid)
        let persisted: OnboardingProviderConfiguration = try await read("/api/manager/provider/configuration")
        XCTAssertEqual(persisted, saved)
        openProvider()
        XCTAssertTrue(waitUntil { (self.app.textFields["provider-model-key"].value as? String) == model })
        try await assertRealConnection(model: model)
        attach("real-provider-configuration-after-relaunch", persisted)
    }

    private func launchOrdinaryApplication() async throws -> OnboardingManagerStatus {
        XCTAssertFalse(app.launchArguments.contains("--uitesting"))
        app.launch()
        XCTAssertTrue(app.buttons["tab-manager"].waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(20)
        repeat {
            if let status: OnboardingManagerStatus = try? await read("/api/manager/status") {
                XCTAssertEqual(status.home, forgeHome.path, "Refuse attachment to an unrelated manager")
                XCTAssertEqual(status.dashboard.port, Int(managerPort))
                XCTAssertEqual(status.dashboard.host, "127.0.0.1")
                XCTAssertTrue(status.httpListening)
                XCTAssertGreaterThan(status.pid, 0)
                attach("ordinary-bootstrap-manager", status)
                return status
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw OnboardingFailure.managerUnavailable
    }

    private func openManager() { click(app.buttons["tab-manager"]) }

    private func openProvider() {
        click(app.buttons["tab-provider"])
        XCTAssertTrue(app.textFields["provider-endpoint"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { self.app.buttons["provider-save"].isEnabled })
    }

    private func openFolderPicker() {
        click(app.buttons["settings-allowed-root-add"])
        XCTAssertTrue(app.buttons["Authorize Folder"].waitForExistence(timeout: 10), "The production NSOpenPanel must appear")
        XCTAssertTrue(app.buttons["Cancel"].exists)
        attachScreenshot("production-open-panel")
    }

    private func chooseFolderInNativePanel(_ path: String) {
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(path)
        let enteredPath = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", path)).firstMatch
        XCTAssertTrue(enteredPath.waitForExistence(timeout: 5), "Native Go to Folder must contain the selected path")
        app.typeKey(.return, modifierFlags: [])
        click(app.buttons["Authorize Folder"].firstMatch)
        XCTAssertTrue(waitUntil { !self.app.buttons["Authorize Folder"].exists })
    }

    private func saveProvider(endpoint: String, model: String) async throws -> OnboardingProviderConfiguration {
        replace(app.textFields["provider-endpoint"], with: endpoint)
        replace(app.textFields["provider-model-key"], with: model)
        click(app.buttons["provider-save"])
        XCTAssertTrue(waitUntil(timeout: 15) {
            self.contains(self.element("provider-probe-notice"), "Settings saved")
        })
        let saved: OnboardingProviderConfiguration = try await read("/api/manager/provider/configuration")
        XCTAssertTrue(saved.saved)
        XCTAssertEqual(saved.endpoint, endpoint)
        XCTAssertEqual(saved.modelKey, model)
        attach("provider-native-save-readback", saved)
        return saved
    }

    private func assertRealConnection(model: String) async throws {
        click(app.buttons["provider-test-connection"])
        XCTAssertTrue(waitUntil(timeout: 40) {
            self.contains(self.element("provider-probe-notice"), "The configured provider and model are reachable.")
        })
        XCTAssertFalse(element("operator-unavailable").exists)
        let snapshot: OnboardingOperatorSnapshot = try await read("/api/manager/operator/snapshot?limit=1")
        let provider = try XCTUnwrap(snapshot.provider)
        XCTAssertEqual(provider.health, "reachable")
        XCTAssertEqual(provider.modelKey, model)
        XCTAssertEqual(provider.lastProbeMode, "connection")
        XCTAssertNotNil(provider.lastProbeAt)
        XCTAssertNil(provider.lastProbeError)
        attach("real-provider-manager-probe-readback", provider)
    }

    private func waitForSettings(roots: [String]) async throws -> OnboardingManagerSettings {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let settings: OnboardingManagerSettings = try await read("/api/manager/settings")
            if settings.allowedRoots == roots { return settings }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw OnboardingFailure.settingsNotPersisted
    }

    private func read<Value: Decodable & Sendable>(_ route: String, timeout: TimeInterval = 5) async throws -> Value {
        let credentialURL = forgeHome.appendingPathComponent("manager-control.secret")
        let attributes = try FileManager.default.attributesOfItem(atPath: credentialURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue == 64,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw OnboardingFailure.invalidManagerCredential
        }
        let credential = try String(contentsOf: credentialURL, encoding: .utf8)
        guard credential.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw OnboardingFailure.invalidManagerCredential
        }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(managerPort)\(route)"))
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OnboardingFailure.managerResponseRejected(route: route, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard data.count <= 1_048_576 else { throw OnboardingFailure.responseTooLarge }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier] }

    private func contains(_ element: XCUIElement, _ text: String) -> Bool {
        guard element.exists else { return false }
        return element.label.contains(text) || (element.value as? String)?.contains(text) == true
            || element.staticTexts.allElementsBoundByIndex.contains { $0.label.contains(text) }
    }

    private func replace(_ field: XCUIElement, with value: String) {
        click(field)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
        XCTAssertTrue(waitUntil { (field.value as? String) == value })
    }

    private func click(_ target: XCUIElement) {
        XCTAssertTrue(target.waitForExistence(timeout: 8))
        XCTAssertTrue(waitUntil { target.isEnabled })
        let scroll = app.scrollViews.containing(.any, identifier: target.identifier).firstMatch
        if !target.isHittable, scroll.exists {
            for _ in 0..<10 where !target.isHittable { scroll.swipeUp() }
            for _ in 0..<10 where !target.isHittable { scroll.swipeDown() }
        }
        XCTAssertTrue(target.isHittable)
        target.click()
    }

    private func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func attach<Value: Encodable>(_ name: String, _ value: Value) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let attachment = XCTAttachment(data: try encoder.encode(value), uniformTypeIdentifier: "public.json")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch { XCTFail("Could not retain redacted onboarding evidence") }
    }

    private func attachScreenshot(_ name: String) {
        guard let app else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum OnboardingFailure: Error {
    case managerUnavailable, settingsNotPersisted, invalidManagerCredential, responseTooLarge
    case managerResponseRejected(route: String, status: Int)
    case socketOperation
}

private struct OnboardingManagerStatus: Codable, Sendable {
    struct Dashboard: Codable, Sendable { let host: String; let port: Int }
    let home: String
    let pid: Int
    let version: String
    let httpListening: Bool
    let dashboard: Dashboard
    enum CodingKeys: String, CodingKey {
        case home, pid, version, dashboard
        case httpListening = "http_listening"
    }
}

private struct OnboardingManagerSettings: Codable, Sendable, Equatable {
    let allowedRoots: [String]
    enum CodingKeys: String, CodingKey { case allowedRoots = "allowed_roots" }
}

private struct OnboardingProviderConfiguration: Codable, Sendable, Equatable {
    let revision: String
    let endpoint: String
    let modelKey: String?
    let credentialConfigured: Bool
    let saved: Bool
    let credentialCleanupPending: Bool
}

private struct OnboardingProviderModels: Codable, Sendable {
    struct Model: Codable, Sendable { let key: String; let loaded: Bool; let toolUseCapable: Bool }
    let revision: String
    let models: [Model]
}

private struct OnboardingOperatorSnapshot: Decodable, Sendable {
    struct Provider: Codable, Sendable {
        let health: String
        let modelKey: String?
        let lastProbeMode: String?
        let lastProbeAt: String?
        let lastProbeError: String?
        enum CodingKeys: String, CodingKey {
            case health
            case modelKey = "model_key"
            case lastProbeMode = "last_probe_mode"
            case lastProbeAt = "last_probe_at"
            case lastProbeError = "last_probe_error"
        }
    }
    let provider: Provider?
}

/// Reserves a loopback TCP port without listening or handling HTTP requests.
private final class OnboardingPortReservation {
    private var descriptor: Int32
    let port: UInt16

    init() throws {
        let reservedDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard reservedDescriptor >= 0 else { throw OnboardingFailure.socketOperation }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(reservedDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(reservedDescriptor)
            throw OnboardingFailure.socketOperation
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(reservedDescriptor, $0, &length)
            }
        }
        guard inspected == 0 else {
            Darwin.close(reservedDescriptor)
            throw OnboardingFailure.socketOperation
        }
        descriptor = reservedDescriptor
        port = UInt16(bigEndian: address.sin_port)
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { close() }
}

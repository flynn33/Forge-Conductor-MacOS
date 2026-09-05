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
/// The fresh MCP execution case requires an unsandboxed test runner: an inherited
/// runner sandbox prevents the product from applying its own shell sandbox.
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
            if let forgeHome { retainBootstrapDiagnostics("onboarding-final-diagnostics", home: forgeHome) }
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
        try openManager()
        XCTAssertTrue(element("settings-allowed-roots-empty").waitForExistence(timeout: 5))

        try openFolderPicker()
        try chooseFolderInNativePanel(projectRoot.path)
        XCTAssertTrue(waitUntil { self.contains(self.element("settings-allowed-root-path-0"), self.projectRoot.path) })
        attachScreenshot("native-folder-staged")
        try click(app.buttons["settings-save"])
        let saved = try await waitForSettings(roots: [projectRoot.path])
        attach("authorized-folder-manager-readback", saved)

        try openFolderPicker()
        try click(folderPanel.buttons["Cancel"])
        XCTAssertTrue(waitUntil {
            self.contains(self.element("settings-allowed-roots-message"), "No project folder was added")
        })
        let afterCancellation: OnboardingManagerSettings = try await read("/api/manager/settings")
        XCTAssertEqual(afterCancellation, saved)

        try openFolderPicker()
        try chooseFolderInNativePanel("/")
        XCTAssertTrue(waitUntil {
            self.contains(self.element("settings-allowed-roots-message"), "The filesystem root cannot be authorized")
        })
        XCTAssertTrue(contains(element("settings-allowed-root-path-0"), projectRoot.path))
        XCTAssertFalse(element("settings-allowed-root-path-1").exists)
        try click(app.buttons["settings-save"])
        let afterRejection = try await waitForSettings(roots: [projectRoot.path])
        XCTAssertEqual(afterRejection, saved)
        attachScreenshot("native-filesystem-root-rejected")

        app.terminate()
        _ = try await launchOrdinaryApplication()
        try openManager()
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
        try openProvider()
        let initial: OnboardingProviderConfiguration = try await read("/api/manager/provider/configuration")
        XCTAssertFalse(initial.saved)
        XCTAssertFalse(initial.credentialConfigured)
        XCTAssertEqual(initial.revision, "0")
        let saved = try await saveProvider(endpoint: endpoint, model: "onboarding-offline-model")
        XCTAssertFalse(saved.credentialConfigured)
        XCTAssertFalse(saved.credentialCleanupPending)
        XCTAssertNotEqual(saved.revision, initial.revision)
        XCTAssertTrue(contains(element("provider-probe-notice"), "Test Connection"))

        try click(app.buttons["provider-test-connection"])
        XCTAssertTrue(element("operator-unavailable").waitForExistence(timeout: 40))
        XCTAssertFalse(contains(element("provider-probe-notice"), "are reachable"))
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.element("provider-last-probe-error").exists
                && (self.element("provider-health").value as? String) == "unreachable"
        })
        let afterOfflineProbe: OnboardingProviderConfiguration = try await read("/api/manager/provider/configuration")
        XCTAssertEqual(afterOfflineProbe, saved)
        attachScreenshot("native-provider-offline-error")

        for invalidEndpoint in [
            "not-an-endpoint", "http://provider.example.invalid", "http://127.0.0.1:1234?unsupported=1",
        ] {
            try replace(app.textFields["provider-endpoint"], with: invalidEndpoint)
            try click(app.buttons["provider-save"])
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
        try openProvider()
        XCTAssertTrue(waitUntil { (self.app.textFields["provider-endpoint"].value as? String) == endpoint })
        XCTAssertEqual(app.textFields["provider-model-key"].value as? String, saved.modelKey)
        try click(app.buttons["provider-test-connection"])
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
        try openProvider()
        let saved = try await saveProvider(endpoint: endpoint, model: model)
        try click(app.buttons["provider-refresh-models"])
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
        try openProvider()
        XCTAssertTrue(waitUntil { (self.app.textFields["provider-model-key"].value as? String) == model })
        try await assertRealConnection(model: model)
        attach("real-provider-configuration-after-relaunch", persisted)
    }

    func testNativeSettingsShellOptOutAndReenablePersistIntoFreshMCPProcesses() async throws {
        _ = try await launchOrdinaryApplication()
        try openManager()
        try openFolderPicker()
        try chooseFolderInNativePanel(projectRoot.path)
        try click(app.buttons["settings-save"])
        let authorized = try await waitForSettings(roots: [projectRoot.path])
        XCTAssertTrue(authorized.shell.enabled)
        XCTAssertFalse(authorized.shell.userDisabled)

        // Enter the real macOS Settings scene with the main window on FORGE RIG,
        // so its independent form is the only shell-policy control in the UI.
        try click(app.buttons["tab-rig"])
        app.typeKey(",", modifierFlags: .command)
        let shellToggle = element("settings-shell-enabled")
        try makeHittable(shellToggle)
        XCTAssertTrue(waitForToggleState(true, on: shellToggle))
        try click(shellToggle)
        try click(app.buttons["settings-save"])
        let disabled = try await waitForShellSettings(enabled: false)
        XCTAssertEqual(disabled.allowedRoots, [projectRoot.path])
        attach("native-settings-shell-disabled", disabled)
        app.terminate()

        let denied = try await runFreshShellMCP()
        retainMCPTranscript("fresh-mcp-shell-disabled", denied)
        XCTAssertEqual(denied.shell.ok, false)
        XCTAssertEqual(denied.shell.code, "shell_disabled_by_user")

        _ = try await launchOrdinaryApplication()
        let afterRelaunch: OnboardingManagerSettings = try await read("/api/manager/settings")
        XCTAssertEqual(afterRelaunch, disabled)
        app.typeKey(",", modifierFlags: .command)
        let restoredToggle = element("settings-shell-enabled")
        try makeHittable(restoredToggle)
        XCTAssertTrue(waitForToggleState(false, on: restoredToggle))
        try click(restoredToggle)
        try click(app.buttons["settings-save"])
        let enabled = try await waitForShellSettings(enabled: true)
        XCTAssertEqual(enabled.allowedRoots, [projectRoot.path])
        attach("native-settings-shell-reenabled", enabled)
        app.terminate()

        let executed = try await runFreshShellMCP()
        retainMCPTranscript("fresh-mcp-shell-reenabled", executed)
        XCTAssertNotEqual(executed.pid, denied.pid)
        XCTAssertEqual(executed.projectID, denied.projectID)
        XCTAssertTrue(executed.shell.ok,
            "Fresh MCP shell execution failed; inspect the retained wire transcript and ensure the UI runner does not impose an inherited sandbox")
        XCTAssertEqual(executed.shell.exitCode, 0)
        XCTAssertEqual(executed.shell.stdout, "native-shell-restored")
        XCTAssertEqual(executed.shell.stderr, "")
        XCTAssertEqual(executed.shell.cwd, projectRoot.path)
        XCTAssertEqual(executed.shell.timedOut, false)
        XCTAssertEqual(executed.shell.stdoutTruncated, false)
        XCTAssertEqual(executed.shell.stderrTruncated, false)
    }

    private func launchOrdinaryApplication() async throws -> OnboardingManagerStatus {
        XCTAssertFalse(app.launchArguments.contains("--uitesting"))
        app.launch()
        XCTAssertTrue(app.buttons["tab-manager"].waitForExistence(timeout: 15))
        retainBootstrapDiagnostics("ordinary-bootstrap-before-status", home: forgeHome)
        let deadline = Date().addingTimeInterval(20)
        var lastFailure = "No status attempt completed"
        repeat {
            do {
                let status: OnboardingManagerStatus = try await read("/api/manager/status")
                XCTAssertEqual(status.home, forgeHome.path, "Refuse attachment to an unrelated manager")
                XCTAssertEqual(status.dashboard.port, Int(managerPort))
                XCTAssertEqual(status.dashboard.host, "127.0.0.1")
                XCTAssertTrue(status.httpListening)
                XCTAssertGreaterThan(status.pid, 0)
                attach("ordinary-bootstrap-manager", status)
                return status
            } catch {
                lastFailure = String(describing: error)
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        retainBootstrapDiagnostics("ordinary-bootstrap-failure", home: forgeHome, lastFailure: lastFailure)
        throw OnboardingFailure.managerUnavailable
    }

    private func openManager() throws { try click(app.buttons["tab-manager"]) }

    private func openProvider() throws {
        try click(app.buttons["tab-provider"])
        XCTAssertTrue(app.textFields["provider-endpoint"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { self.app.buttons["provider-save"].isEnabled })
    }

    private var folderPanel: XCUIElement { app.dialogs["open-panel"] }

    private func openFolderPicker() throws {
        try click(app.buttons["settings-allowed-root-add"])
        XCTAssertTrue(folderPanel.waitForExistence(timeout: 10), "The production NSOpenPanel must appear")
        XCTAssertTrue(folderPanel.buttons["Authorize Folder"].exists)
        XCTAssertTrue(folderPanel.buttons["Cancel"].exists)
        attachScreenshot("production-open-panel")
    }

    private func chooseFolderInNativePanel(_ path: String) throws {
        app.typeKey("g", modifierFlags: [.command, .shift])
        let goToSheet = folderPanel.sheets["GoToWindow"]
        guard goToSheet.waitForExistence(timeout: 5) else {
            throw OnboardingFailure.controlUnavailable(identifier: "GoToWindow")
        }
        let pathField = goToSheet.textFields["PathTextField"]
        try replace(pathField, with: path)
        pathField.typeKey(.return, modifierFlags: [])
        if !waitUntil(timeout: 5, { !goToSheet.exists }) {
            // AppKit can restore the previous directory into the still-open
            // sheet after submission. Re-enter once only when that stale value
            // is observed; never authorize an unverified remembered directory.
            guard goToSheet.exists, pathField.exists,
                  let observed = pathField.value as? String, observed != path else {
                throw OnboardingFailure.controlUnavailable(identifier: "GoToWindow")
            }
            attachScreenshot("native-go-to-folder-stale-path")
            try replace(pathField, with: path)
            pathField.typeKey(.return, modifierFlags: [])
        }
        guard waitUntil(timeout: 5, { !goToSheet.exists }) else {
            throw OnboardingFailure.controlUnavailable(identifier: "GoToWindow")
        }
        try click(folderPanel.buttons["Authorize Folder"])
        XCTAssertTrue(waitUntil { !self.folderPanel.exists })
    }

    private func saveProvider(endpoint: String, model: String) async throws -> OnboardingProviderConfiguration {
        try replace(app.textFields["provider-endpoint"], with: endpoint)
        try replace(app.textFields["provider-model-key"], with: model)
        try click(app.buttons["provider-save"])
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
        try click(app.buttons["provider-test-connection"])
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

    private func waitForShellSettings(enabled: Bool) async throws -> OnboardingManagerSettings {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let settings: OnboardingManagerSettings = try await read("/api/manager/settings")
            if settings.shell.enabled == enabled, settings.shell.userDisabled == !enabled { return settings }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw OnboardingFailure.settingsNotPersisted
    }

    private func runFreshShellMCP() async throws -> OnboardingShellMCPResult {
        // The signed product and runner are siblings in Xcode's build products.
        // Resolve the native product from this runner, never an installed app.
        var runner = Bundle(for: Self.self).bundleURL
        for _ in 0..<5 where runner.pathExtension != "app" { runner.deleteLastPathComponent() }
        let product = runner.deletingLastPathComponent().appendingPathComponent("Forge Conductor.app")
        let bundle = try XCTUnwrap(Bundle(url: product))
        XCTAssertEqual(bundle.bundleIdentifier, "com.forge-conductor.app")
        let executable = try XCTUnwrap(bundle.executableURL)
        let home = try XCTUnwrap(forgeHome)
        let root = try XCTUnwrap(projectRoot)
        return try await Task.detached(priority: .userInitiated) {
            try OnboardingShellMCPProcess.run(executable: executable, home: home, project: root)
        }.value
    }

    private func retainMCPTranscript(_ name: String, _ result: OnboardingShellMCPResult) {
        attach(name, result)
        let attachment = XCTAttachment(data: result.transcript, uniformTypeIdentifier: "public.json")
        attachment.name = "\(name)-wire-transcript"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func read<Value: Decodable & Sendable>(_ route: String, timeout: TimeInterval = 5) async throws -> Value {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(managerPort)\(route)"))
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // These read-only routes are public in ManagerMutationAuthorizer. A clean
        // GUI has not used an authenticated command yet, so its credential file
        // may not exist. Do not create a test credential or block public status
        // on that lazy production resource.
        let publicRoutes = ["/api/manager/status", "/api/manager/settings", "/api/manager/operator/snapshot"]
        if !publicRoutes.contains(String(route.split(separator: "?", maxSplits: 1)[0])) {
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
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OnboardingFailure.managerResponseRejected(route: route, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard data.count <= 1_048_576 else { throw OnboardingFailure.responseTooLarge }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func retainBootstrapDiagnostics(_ name: String, home: URL, lastFailure: String? = nil) {
        let credentialURL = home.appendingPathComponent("manager-control.secret")
        let attributes = try? FileManager.default.attributesOfItem(atPath: credentialURL.path)
        let report = OnboardingBootstrapDiagnostics(
            home: home.path, port: Int(managerPort), appState: app?.state.rawValue,
            credentialExists: FileManager.default.fileExists(atPath: credentialURL.path),
            credentialBytes: (attributes?[.size] as? NSNumber)?.intValue,
            credentialPermissions: (attributes?[.posixPermissions] as? NSNumber)?.intValue,
            lastReadFailure: lastFailure
        )
        attach(name, report)
        if let app, app.state != .notRunning {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "\(name)-native-controls"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier] }

    private func contains(_ element: XCUIElement, _ text: String) -> Bool {
        guard element.exists else { return false }
        return element.label.contains(text) || (element.value as? String)?.contains(text) == true
            || element.staticTexts.allElementsBoundByIndex.contains { $0.label.contains(text) }
    }

    private func replace(_ field: XCUIElement, with value: String) throws {
        try click(field)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
        XCTAssertTrue(waitUntil { (field.value as? String) == value })
    }

    private func click(_ target: XCUIElement) throws {
        try makeHittable(target)
        target.click()
    }

    private func makeHittable(_ target: XCUIElement) throws {
        guard target.waitForExistence(timeout: 8), waitUntil({ target.isEnabled }) else {
            throw OnboardingFailure.controlUnavailable(identifier: target.identifier)
        }
        // SwiftUI duplicates the root identifier onto both navigation and
        // content scroll views. Select the deepest scroll ancestor containing
        // this exact control instead of scrolling the sidebar's first match.
        let scrolls = app.scrollViews.containing(.any, identifier: target.identifier).allElementsBoundByIndex
        if !target.isHittable, let scroll = scrolls.last {
            for _ in 0..<12 where !target.isHittable {
                let distance = target.frame.midY - scroll.frame.midY
                // Pixel scrolling avoids a high-velocity swipe jumping across
                // the entire section that contains the off-screen control.
                scroll.scroll(byDeltaX: 0, deltaY: -min(360, max(-360, distance)))
            }
        }
        guard target.isHittable else {
            throw OnboardingFailure.controlNotHittable(identifier: target.identifier)
        }
    }

    private func waitForToggleState(_ expected: Bool, on target: XCUIElement) -> Bool {
        waitUntil {
            if let number = target.value as? NSNumber { return number.boolValue == expected }
            guard let raw = target.value as? String else { return false }
            switch raw.lowercased() {
            case "1", "true", "on": return expected
            case "0", "false", "off": return !expected
            default: return false
            }
        }
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
    case controlUnavailable(identifier: String), controlNotHittable(identifier: String)
    case socketOperation
}

private struct OnboardingBootstrapDiagnostics: Codable {
    let home: String
    let port: Int
    let appState: UInt?
    let credentialExists: Bool
    let credentialBytes: Int?
    let credentialPermissions: Int?
    let lastReadFailure: String?
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
    struct Shell: Codable, Sendable, Equatable {
        let enabled: Bool
        let userDisabled: Bool
        enum CodingKeys: String, CodingKey { case enabled; case userDisabled = "user_disabled" }
    }
    let allowedRoots: [String]
    let shell: Shell
    enum CodingKeys: String, CodingKey { case shell; case allowedRoots = "allowed_roots" }
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

private struct OnboardingShellMCPResult: Codable, Sendable {
    struct Shell: Codable, Sendable {
        let ok: Bool
        let code: String?
        let exitCode: Int?
        let stdout: String?
        let stderr: String?
        let cwd: String?
        let timedOut: Bool?
        let stdoutTruncated: Bool?
        let stderrTruncated: Bool?
        enum CodingKeys: String, CodingKey {
            case ok, code, stdout, stderr, cwd
            case exitCode = "exit_code", timedOut = "timed_out"
            case stdoutTruncated = "stdout_truncated", stderrTruncated = "stderr_truncated"
        }
    }
    let pid: Int32
    let serverVersion: String
    let projectID: String
    let shell: Shell
    let transcript: Data
}

/// Runs on an owned worker, with bounded pipes and deadlines. This speaks the
/// actual signed product's public NDJSON MCP protocol in a fresh process.
private final class OnboardingShellMCPProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var pending = Data()
    private var diagnosticBytes = Data()
    private var transcript: [[String: Any]] = []

    static func run(executable: URL, home: URL, project: URL) throws -> OnboardingShellMCPResult {
        let client = OnboardingShellMCPProcess()
        return try client.run(executable: executable, home: home, project: project)
    }

    private func run(executable: URL, home: URL, project: URL) throws -> OnboardingShellMCPResult {
        process.executableURL = executable
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCInjectBundle", "XCInjectBundleInto", "DYLD_INSERT_LIBRARIES"] {
            environment.removeValue(forKey: key)
        }
        environment["FORGE_CONDUCTOR_HOME"] = home.path
        environment["FORGE_MCP_ROLE"] = "primary"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer { stop() }
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        for descriptor in [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw OnboardingMCPFailure("Could not configure bounded MCP pipe reads")
            }
        }

        let initialized = try exchange(id: 1, method: "initialize", params: [
            "protocolVersion": "2024-11-05", "capabilities": [:],
            "clientInfo": ["name": "native-shipping-tests", "version": "1"],
        ])
        guard let result = initialized["result"] as? [String: Any],
              let info = result["serverInfo"] as? [String: Any],
              let version = info["version"] as? String else {
            throw OnboardingMCPFailure("The signed MCP process did not initialize")
        }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized", "params": [:]])
        let binding = try tool(id: 2, name: "project_memory.initialize", arguments: ["project_path": project.path])
        guard binding["ok"] as? Bool == true, let projectID = binding["project_id"] as? String else {
            throw OnboardingMCPFailure("Public MCP project initialization did not authorize the selected folder")
        }
        let payload = try tool(id: 3, name: "shell_exec", arguments: [
            "command": "printf native-shell-restored", "cwd": project.path, "timeout_sec": 5,
        ])
        let shell = try JSONDecoder().decode(OnboardingShellMCPResult.Shell.self,
            from: JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            try drain(errors.fileHandleForReading.fileDescriptor, into: &diagnosticBytes)
            usleep(10_000)
        }
        guard !process.isRunning, process.terminationStatus == 0 else {
            throw OnboardingMCPFailure("The signed MCP process did not shut down cleanly after EOF")
        }
        return OnboardingShellMCPResult(pid: process.processIdentifier, serverVersion: version,
            projectID: projectID, shell: shell,
            transcript: try JSONSerialization.data(withJSONObject: transcript, options: [.sortedKeys, .prettyPrinted]))
    }

    private func tool(id: Int, name: String, arguments: [String: Any]) throws -> [String: Any] {
        let response = try exchange(id: id, method: "tools/call", params: ["name": name, "arguments": arguments])
        guard let result = response["result"] as? [String: Any],
              let structured = result["structuredContent"] as? [String: Any],
              let ok = structured["ok"] as? Bool,
              result["isError"] as? Bool == !ok else {
            throw OnboardingMCPFailure("The signed MCP process returned an invalid tool envelope for \(name)")
        }
        return structured
    }

    private func exchange(id: Int, method: String, params: [String: Any]) throws -> [String: Any] {
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let newline = pending.firstIndex(of: 0x0a) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (response["id"] as? NSNumber)?.intValue == id, response["error"] == nil else {
                    throw OnboardingMCPFailure("The signed MCP process returned an unexpected response to \(method)")
                }
                transcript.append(["response": response])
                return response
            }
            try drain(output.fileHandleForReading.fileDescriptor, into: &pending)
            try drain(errors.fileHandleForReading.fileDescriptor, into: &diagnosticBytes)
            if pending.isEmpty, !process.isRunning {
                throw OnboardingMCPFailure("The signed MCP process exited before \(method) returned")
            }
            usleep(10_000)
        }
        throw OnboardingMCPFailure("The signed MCP process exceeded the bounded response deadline for \(method)")
    }

    private func send(_ request: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        guard data.count <= 4096 else { throw OnboardingMCPFailure("MCP request exceeded its fixture bound") }
        data.append(0x0a)
        transcript.append(["request": request])
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func drain(_ descriptor: Int32, into data: inout Data) throws {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 {
            guard data.count + count <= 65_536 else { throw OnboardingMCPFailure("MCP output exceeded its 64 KiB bound") }
            data.append(contentsOf: bytes.prefix(count))
        } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
            throw OnboardingMCPFailure("The MCP pipe could not be read")
        }
    }

    private func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { usleep(10_000) }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                let killDeadline = Date().addingTimeInterval(3)
                while process.isRunning, Date() < killDeadline { usleep(10_000) }
            }
        }
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }
}

private struct OnboardingMCPFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
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

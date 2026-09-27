// Exercises the ordinary GUI bootstrap, native folder picker, and real manager.
// These tests deliberately do not use the unavailable-manager or panel fixtures.

import Darwin
import AppKit
import Foundation
import ForgeConductorCore
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
    private var guidedSetupDefaultsSuite: String!

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
            guidedSetupDefaultsSuite = "com.forge-conductor.production-onboarding.\(fixture.lastPathComponent)"
            UserDefaults(suiteName: guidedSetupDefaultsSuite)?.set(
                true,
                forKey: "forge.guidedSetup.completed.v2"
            )
            app.launchEnvironment["FORGE_GUIDED_SETUP_DEFAULTS_SUITE"] = guidedSetupDefaultsSuite
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
            if let guidedSetupDefaultsSuite {
                UserDefaults(suiteName: guidedSetupDefaultsSuite)?
                    .removePersistentDomain(forName: guidedSetupDefaultsSuite)
            }
            guidedSetupDefaultsSuite = nil
            if let fixture {
                Self.makeFixtureRemovable(fixture)
                try FileManager.default.removeItem(at: fixture)
            }
            fixture = nil
        }
    }

    private nonisolated static func makeFixtureRemovable(_ root: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ), values.isSymbolicLink != true else { continue }
            try? FileManager.default.setAttributes(
                [.posixPermissions: values.isDirectory == true ? 0o700 : 0o600],
                ofItemAtPath: url.path
            )
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
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

    func testNativeProjectRegistrationUsesSelectedFolderAndSurvivesRelaunch() async throws {
        _ = try await launchOrdinaryApplication()
        try click(app.buttons["tab-projects"])
        XCTAssertTrue(app.buttons["project-register"].waitForExistence(timeout: 10))
        let before: OnboardingProjectSnapshot = try await read("/api/manager/operator/snapshot?limit=1")
        XCTAssertTrue(before.projects.isEmpty)

        try click(app.buttons["project-register"])
        XCTAssertTrue(folderPanel.waitForExistence(timeout: 10), "The production project picker must appear")
        XCTAssertTrue(folderPanel.buttons["Choose Project"].exists)
        try chooseFolderInNativePanel(projectRoot.path, prompt: "Choose Project")
        XCTAssertTrue(app.buttons["project-register-confirm"].waitForExistence(timeout: 10))
        XCTAssertTrue(contains(element("project-register-name"), projectRoot.lastPathComponent))
        try click(app.buttons["project-register-confirm"])

        XCTAssertTrue(waitUntil(timeout: 20) {
            self.app.buttons["project-register"].isEnabled
                && self.app.staticTexts[self.projectRoot.lastPathComponent].exists
        })
        let after: OnboardingProjectSnapshot = try await read("/api/manager/operator/snapshot?limit=1")
        let project = try XCTUnwrap(after.projects.first)
        XCTAssertEqual(after.projects.count, 1)
        XCTAssertEqual(project.canonicalRoot, projectRoot.path)
        XCTAssertEqual(project.lifecycleState, "active")
        XCTAssertGreaterThan(project.projectGeneration, 0)
        let authorized: OnboardingManagerSettings = try await read("/api/manager/settings")
        XCTAssertEqual(authorized.allowedRoots, [projectRoot.path])
        attach("native-project-registration", after)

        app.terminate()
        _ = try await launchOrdinaryApplication()
        try click(app.buttons["tab-projects"])
        XCTAssertTrue(element("project-row-\(project.projectID)").waitForExistence(timeout: 10))
        let restored: OnboardingProjectSnapshot = try await read("/api/manager/operator/snapshot?limit=1")
        XCTAssertEqual(restored.projects, after.projects)
        let restoredAuthorization: OnboardingManagerSettings = try await read(
            "/api/manager/settings"
        )
        XCTAssertEqual(restoredAuthorization.allowedRoots, [projectRoot.path])
    }

    func testDirectProjectPathRegistrationChecksAbsolutePathAndCommits() async throws {
        _ = try await launchOrdinaryApplication()
        try click(app.buttons["tab-projects"])
        try click(app.buttons["project-register-by-path"])
        let path = app.textFields["project-register-path"]
        let confirm = app.buttons["project-register-confirm"]
        XCTAssertTrue(path.waitForExistence(timeout: 10))
        try replace(path, with: "relative/project")
        XCTAssertFalse(confirm.isEnabled)
        try replace(path, with: projectRoot.path)
        XCTAssertTrue(waitUntil { confirm.isEnabled })
        try click(confirm)

        XCTAssertTrue(waitUntil(timeout: 20) {
            self.app.buttons["project-register-by-path"].isEnabled
                && self.app.staticTexts[self.projectRoot.lastPathComponent].exists
        })
        let snapshot: OnboardingProjectSnapshot = try await read("/api/manager/operator/snapshot?limit=1")
        let project = try XCTUnwrap(snapshot.projects.first)
        XCTAssertEqual(snapshot.projects.count, 1)
        XCTAssertEqual(project.canonicalRoot, projectRoot.path)
        XCTAssertEqual(project.lifecycleState, "active")
        let authorized: OnboardingManagerSettings = try await read("/api/manager/settings")
        XCTAssertEqual(authorized.allowedRoots, [projectRoot.path])
        attach("direct-project-path-registration", snapshot)
    }

    func testNativeProjectsImportsMixedInstructionFolderWithoutBlockingReadableWork() async throws {
        let instructionFolder = projectRoot.appendingPathComponent(
            "Instruction Package", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: instructionFolder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("Read work-product.txt and report its exact content.\n".utf8).write(
            to: instructionFolder.appendingPathComponent("01-instructions.md"),
            options: .atomic
        )
        try Data("Plain-text instruction.\n".utf8).write(
            to: instructionFolder.appendingPathComponent("02-notes.txt"),
            options: .atomic
        )
        let pdfView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        pdfView.string = "PDF instruction"
        try pdfView.dataWithPDF(inside: pdfView.bounds).write(
            to: instructionFolder.appendingPathComponent("03-document.pdf"), options: .atomic
        )
        let rich = NSAttributedString(string: "Rich instruction")
        try rich.data(
            from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        ).write(to: instructionFolder.appendingPathComponent("04-rich.docx"), options: .atomic)
        try rich.data(
            from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ).write(to: instructionFolder.appendingPathComponent("05-rich.rtf"), options: .atomic)
        try Data("<html><body>HTML instruction</body></html>".utf8).write(
            to: instructionFolder.appendingPathComponent("06-rich.html"), options: .atomic
        )
        try Data(#"{"instruction":"JSON instruction"}"#.utf8).write(
            to: instructionFolder.appendingPathComponent("07-data.json"), options: .atomic
        )
        try Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!.write(to: instructionFolder.appendingPathComponent("08-image.png"), options: .atomic)
        let nestedSource = fixture.appendingPathComponent("nested-source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedSource, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("Nested instruction".utf8).write(
            to: nestedSource.appendingPathComponent("nested.txt"), options: .atomic
        )
        let archive = instructionFolder.appendingPathComponent("09-nested.zip")
        let zipper = Process()
        zipper.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipper.arguments = ["-c", "-k", "--keepParent", nestedSource.path, archive.path]
        try zipper.run()
        zipper.waitUntilExit()
        XCTAssertEqual(zipper.terminationStatus, 0)
        try Data([0x00, 0xFF, 0x00, 0xFE]).write(
            to: instructionFolder.appendingPathComponent("10-unknown.xyzunknown"),
            options: .atomic
        )

        _ = try await launchOrdinaryApplication()
        try openManager()
        try openFolderPicker()
        try chooseFolderInNativePanel(projectRoot.path)
        try click(app.buttons["settings-save"])
        _ = try await waitForSettings(roots: [projectRoot.path])

        try click(app.buttons["tab-projects"])
        try click(app.buttons["project-register-by-path"])
        try replace(app.textFields["project-register-path"], with: projectRoot.path)
        try click(app.buttons["project-register-confirm"])
        let projects: OnboardingProjectSnapshot = try await read(
            "/api/manager/operator/snapshot?limit=1"
        )
        let project = try XCTUnwrap(projects.projects.first)

        try click(app.buttons["instruction-package-add"])
        XCTAssertTrue(
            folderPanel.waitForExistence(timeout: 10),
            "The production instruction NSOpenPanel must appear"
        )
        XCTAssertTrue(folderPanel.buttons["Add Instructions"].exists)
        try chooseFolderInNativePanel(instructionFolder.path, prompt: "Add Instructions")

        let request = OnboardingProjectGenerationRequest(
            projectID: project.projectID,
            projectGeneration: project.projectGeneration
        )
        let deadline = Date().addingTimeInterval(15)
        var queue: OnboardingInstructionQueue?
        repeat {
            let candidate: OnboardingInstructionQueue = try await post(
                "/api/manager/projects/instruction-packages",
                body: request
            )
            if candidate.packages.count == 1 {
                queue = candidate
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline

        let imported = try XCTUnwrap(queue)
        let package = try XCTUnwrap(imported.packages.first)
        XCTAssertEqual(package.documentCount, 10)
        XCTAssertEqual(package.unresolvedDocumentCount, 2)
        XCTAssertEqual(package.importReady, true)
        XCTAssertEqual(package.state, "queued")
        XCTAssertTrue(
            element("instruction-package-row-\(package.id)").waitForExistence(timeout: 10)
        )
        XCTAssertFalse(
            app.buttons["instruction-queue-toggle"].exists,
            "Importing instructions must not expose the obsolete Managed Run action"
        )
        XCTAssertTrue(app.buttons["instruction-package-remove-\(package.id)"].isEnabled)
        try click(element("instruction-package-catalog-toggle-\(package.id)"))
        let catalog = element("instruction-document-catalog-\(package.id)")
        XCTAssertTrue(catalog.waitForExistence(timeout: 10))
        XCTAssertTrue(contains(catalog, "File catalog · 10 of 10 retained"))
        let documents = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "instruction-document-document-")
        )
        XCTAssertEqual(documents.count, 10)
        XCTAssertGreaterThan(
            documents.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Converted", "Converted")
            ).count,
            0
        )
        XCTAssertGreaterThan(
            documents.matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@ OR label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                    "Retained attachment", "Retained attachment", "Unresolved", "Unresolved"
                )
            ).count,
            0
        )
        attach("native-projects-mixed-folder-readback", imported)
        attachScreenshot("native-projects-mixed-folder")
    }

    func testNativeProjectsReordersAndRemovesInstructionPackagesWithExplicitControls() async throws {
        let firstSource = projectRoot.appendingPathComponent("first-instructions.md")
        let secondSource = projectRoot.appendingPathComponent("second-instructions.md")
        try Data("Complete the first instruction package.\n".utf8).write(
            to: firstSource, options: .atomic
        )
        try Data("Complete the second instruction package.\n".utf8).write(
            to: secondSource, options: .atomic
        )

        _ = try await launchOrdinaryApplication()
        try openManager()
        try openFolderPicker()
        try chooseFolderInNativePanel(projectRoot.path)
        try click(app.buttons["settings-save"])
        _ = try await waitForSettings(roots: [projectRoot.path])

        try click(app.buttons["tab-projects"])
        try click(app.buttons["project-register-by-path"])
        try replace(app.textFields["project-register-path"], with: projectRoot.path)
        try click(app.buttons["project-register-confirm"])
        let projects: OnboardingProjectSnapshot = try await read(
            "/api/manager/operator/snapshot?limit=1"
        )
        let project = try XCTUnwrap(projects.projects.first)
        let generation = OnboardingProjectGenerationRequest(
            projectID: project.projectID,
            projectGeneration: project.projectGeneration
        )
        let firstQueue: OnboardingInstructionQueue = try await post(
            "/api/manager/projects/instruction-packages/import",
            body: OnboardingInstructionImportRequest(
                projectID: project.projectID,
                projectGeneration: project.projectGeneration,
                sourcePath: firstSource.path
            )
        )
        let imported: OnboardingInstructionQueue = try await post(
            "/api/manager/projects/instruction-packages/import",
            body: OnboardingInstructionImportRequest(
                projectID: project.projectID,
                projectGeneration: project.projectGeneration,
                sourcePath: secondSource.path
            )
        )
        let firstID = try XCTUnwrap(firstQueue.packages.first?.id)
        let secondID = try XCTUnwrap(imported.packages.last?.id)
        XCTAssertEqual(imported.packages.map(\.id), [firstID, secondID])

        XCTAssertTrue(
            element("instruction-package-move-down-\(firstID)")
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            element("instruction-package-move-up-\(secondID)")
                .waitForExistence(timeout: 10)
        )
        try click(element("instruction-package-move-down-\(firstID)"))

        let reorderDeadline = Date().addingTimeInterval(10)
        var reorderedIDs: [String] = []
        repeat {
            let queue: OnboardingInstructionQueue = try await post(
                "/api/manager/projects/instruction-packages",
                body: generation
            )
            reorderedIDs = queue.packages.map(\.id)
            if reorderedIDs == [secondID, firstID] { break }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < reorderDeadline
        XCTAssertEqual(reorderedIDs, [secondID, firstID])

        try click(element("instruction-package-remove-\(firstID)"))
        let removalDeadline = Date().addingTimeInterval(10)
        var remainingIDs: [String] = []
        repeat {
            let queue: OnboardingInstructionQueue = try await post(
                "/api/manager/projects/instruction-packages",
                body: generation
            )
            remainingIDs = queue.packages.map(\.id)
            if remainingIDs == [secondID] { break }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < removalDeadline
        XCTAssertEqual(remainingIDs, [secondID])
        attachScreenshot("native-projects-explicit-order-and-remove")
    }

    func testProjectRemovalIsAvailableFromSidebarAndPersists() async throws {
        _ = try await launchOrdinaryApplication()
        try click(app.buttons["tab-projects"])
        try click(app.buttons["project-register-by-path"])
        try replace(app.textFields["project-register-path"], with: projectRoot.path)
        try click(app.buttons["project-register-confirm"])

        XCTAssertTrue(waitUntil(timeout: 20) {
            self.app.buttons["project-remove-sidebar"].isEnabled
        })
        let registered: OnboardingProjectSnapshot = try await read(
            "/api/manager/operator/snapshot?limit=1"
        )
        let project = try XCTUnwrap(registered.projects.first)
        XCTAssertTrue(element("project-row-\(project.projectID)").exists)

        try click(app.buttons["project-remove-sidebar"])
        let alert = app.alerts["Remove project from Forge Conductor?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(contains(alert, project.displayName))
        try click(alert.buttons["Remove Project"])

        XCTAssertTrue(waitUntil(timeout: 20) {
            !self.element("project-row-\(project.projectID)").exists
                && !self.app.buttons["project-remove-sidebar"].isEnabled
        })
        let removed: OnboardingProjectSnapshot = try await read(
            "/api/manager/operator/snapshot?limit=1"
        )
        XCTAssertTrue(removed.projects.isEmpty)

        app.terminate()
        _ = try await launchOrdinaryApplication()
        try click(app.buttons["tab-projects"])
        XCTAssertFalse(element("project-row-\(project.projectID)").exists)
        let restored: OnboardingProjectSnapshot = try await read(
            "/api/manager/operator/snapshot?limit=1"
        )
        XCTAssertTrue(restored.projects.isEmpty)
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
        XCTAssertTrue(contains(element("provider-probe-notice"), "Connect and Check"))

        try click(app.buttons["provider-test-connection"])
        XCTAssertTrue(element("operator-unavailable").waitForExistence(timeout: 40))
        XCTAssertFalse(contains(element("provider-probe-notice"), "are reachable"))
        XCTAssertTrue(app.staticTexts["Start LM Studio, then choose Connect and Check again"]
            .waitForExistence(timeout: 5))
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
        XCTAssertTrue(
            element("provider-model-selection").waitForExistence(timeout: 40),
            "Native controls must expose the discovered models after the asynchronous inventory request completes"
        )
        XCTAssertTrue(waitUntil { self.app.buttons["provider-refresh-models"].isEnabled })
        XCTAssertFalse(element("operator-unavailable").exists, "The selected real server must return its model inventory")
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

    func testNativeAutonomyStartPersistsExactReadOnlyAssignmentAgainstLoadedProvider() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["FORGE_SHIPPING_PROVIDER_ENDPOINT"], !endpoint.isEmpty,
              let model = environment["FORGE_SHIPPING_PROVIDER_MODEL"], !model.isEmpty else {
            throw XCTSkip("Requires the selected running local LM Studio endpoint and loaded model")
        }
        try OwnerOnlyAtomicFile.write(
            Data("required native effect\n".utf8),
            to: projectRoot.appendingPathComponent("work-product.txt")
        )
        _ = try await launchOrdinaryApplication()
        try openManager()
        try openFolderPicker()
        try chooseFolderInNativePanel(projectRoot.path)
        try click(app.buttons["settings-save"])
        _ = try await waitForSettings(roots: [projectRoot.path])

        try click(app.buttons["tab-projects"])
        try click(app.buttons["project-register-by-path"])
        try replace(app.textFields["project-register-path"], with: projectRoot.path)
        try click(app.buttons["project-register-confirm"])
        let projects: OnboardingProjectSnapshot = try await read("/api/manager/operator/snapshot?limit=1")
        let project = try XCTUnwrap(projects.projects.first)
        XCTAssertEqual(project.canonicalRoot, projectRoot.path)

        try openProvider()
        _ = try await saveProvider(endpoint: endpoint, model: model)
        try await assertRealConnection(model: model)

        try click(app.buttons["tab-projects"])
        try click(app.buttons["project-run-details"])
        let start = app.buttons["autonomy-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { start.isEnabled })
        try click(start)
        let mission = "Read work-product.txt once, report its exact content, and request completion. Do not edit files."
        try replace(element("run-start-mission"), with: mission)
        try click(app.buttons["run-start-customize"])
        XCTAssertTrue(element("run-start-model-picker").exists)
        XCTAssertFalse(element("run-start-tool-policy").exists)
        XCTAssertFalse(element("run-start-completion-gates").exists)
        try click(app.buttons["run-start-confirm"])
        XCTAssertTrue(waitUntil(timeout: 20) { !self.app.buttons["run-start-confirm"].exists })

        let snapshot: OnboardingManagedRunSnapshot = try await read("/api/manager/operator/snapshot?limit=5")
        let run = try XCTUnwrap(
            snapshot.runs.first { candidate in
                candidate.projectID == project.projectID
                    && candidate.mission.contains("immutable project-scoped artifact")
            }
        )
        XCTAssertEqual(run.projectID, project.projectID)
        XCTAssertEqual(run.projectGeneration, project.projectGeneration)
        XCTAssertEqual(run.modelKey, model)
        XCTAssertEqual(
            Set(run.completionGates),
            Set([ProjectInstructionQueueStore.builtInCompletionGate]
                + CompletionCheckPreset.defaults.map(\.rawValue))
        )
        let artifactSHA256 = try XCTUnwrap(run.completionPlan?.instructionArtifactSHA256.first)
        XCTAssertEqual(artifactSHA256.count, 64)
        let storedInstructions = forgeHome
            .appendingPathComponent("instruction-packages/Store", isDirectory: true)
            .appendingPathComponent(artifactSHA256, isDirectory: true)
            .appendingPathComponent(".forge/canonical/document-000001.txt")
        XCTAssertEqual(
            try String(contentsOf: storedInstructions, encoding: .utf8),
            mission,
            "The immutable run artifact must retain the exact quick instructions entered by the operator"
        )
        XCTAssertTrue(element("autonomy-run-row-\(run.runID)").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["run-import-native-policy"].exists)
        XCTAssertFalse(element("run-completion-advanced-toggle").exists)
        XCTAssertTrue(
            element("run-completion-requirements-read-only").waitForExistence(timeout: 10),
            "Completion requirements must remain visible without exposing Forge-owned policy configuration"
        )
        attach("native-autonomy-start-readback", snapshot)
        attachScreenshot("native-autonomy-start")

        let completionDeadline = Date().addingTimeInterval(300)
        var observed = run
        while Date() < completionDeadline, observed.state != "completed" {
            if ["failed_terminal", "cancelled"].contains(observed.state ?? "") {
                break
            }
            try await Task.sleep(for: .seconds(1))
            let refreshed: OnboardingManagedRunSnapshot = try await read(
                "/api/manager/operator/snapshot?limit=5"
            )
            observed = try XCTUnwrap(
                refreshed.runs.first { $0.runID == run.runID },
                "The admitted run must remain durable while it executes"
            )
        }
        attach("native-autonomy-completed-readback", observed)
        XCTAssertEqual(
            observed.state,
            "completed",
            "The exact task admitted through the native UI must complete against the loaded LM Studio model. "
                + "last_error_code=\(observed.lastErrorCode ?? "none") "
                + "last_error_summary=\(observed.lastErrorSummary ?? "none") "
                + "next_action=\(observed.nextAction ?? "none")"
        )
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

        // Enter the real macOS Settings scene with the main window on Dashboard,
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
        let advanced = app.buttons["provider-advanced-toggle"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        if !app.textFields["provider-endpoint"].exists {
            try click(advanced)
        }
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

    private func chooseFolderInNativePanel(_ path: String, prompt: String = "Authorize Folder") throws {
        app.typeKey("g", modifierFlags: [.command, .shift])
        let goToSheet = folderPanel.sheets["GoToWindow"]
        guard goToSheet.waitForExistence(timeout: 5) else {
            throw OnboardingFailure.controlUnavailable(identifier: "GoToWindow")
        }
        let pathField = goToSheet.textFields["PathTextField"]
        try enterGoToPath(path, field: pathField)
        app.typeKey(.return, modifierFlags: [])
        if !waitUntil(timeout: 5, { !goToSheet.exists }) {
            // AppKit can restore the previous directory into the still-open
            // sheet after submission. Re-enter once only when that stale value
            // is observed; never authorize an unverified remembered directory.
            guard goToSheet.exists, pathField.exists,
                  let observed = pathField.value as? String, observed != path else {
                throw OnboardingFailure.controlUnavailable(identifier: "GoToWindow")
            }
            attachScreenshot("native-go-to-folder-stale-path")
            try enterGoToPath(path, field: pathField)
            app.typeKey(.return, modifierFlags: [])
        }
        guard waitUntil(timeout: 5, { !goToSheet.exists }) else {
            throw OnboardingFailure.controlUnavailable(identifier: "GoToWindow")
        }
        try click(folderPanel.buttons[prompt])
        XCTAssertTrue(waitUntil { !self.folderPanel.exists })
    }

    private func enterGoToPath(_ path: String, field: XCUIElement) throws {
        if field.isHittable {
            try replace(field, with: path)
        } else {
            guard field.waitForExistence(timeout: 5) else {
                throw OnboardingFailure.controlUnavailable(identifier: "PathTextField")
            }
            attach("native-go-to-keyboard-focus", folderPanel.debugDescription)
            app.typeKey("a", modifierFlags: [.command])
            app.typeText(path)
        }
        guard waitUntil(timeout: 5, { field.value as? String == path }) else {
            throw OnboardingFailure.controlNotHittable(identifier: "PathTextField exact-path readback")
        }
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
        let reachable = waitUntil(timeout: 40) {
            self.contains(
                self.element("provider-probe-notice"),
                "ready for Forge MCP and automatic continuity"
            )
        }
        if !reachable {
            let notice = element("provider-probe-notice")
            let error = element("operator-unavailable")
            let lastProbeError = element("provider-last-probe-error")
            let report = OnboardingProviderProbeFailureDiagnostics(
                notice: notice.exists ? (notice.value as? String ?? notice.label) : nil,
                error: error.exists ? error.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ") : nil,
                lastProbeError: lastProbeError.exists ? (lastProbeError.value as? String ?? lastProbeError.label) : nil,
                operatorUnavailable: element("operator-unavailable").exists,
                providerHealth: element("provider-health").value as? String
            )
            attach("real-provider-probe-failure-controls", report)
            if let snapshot: OnboardingOperatorSnapshot = try? await read("/api/manager/operator/snapshot?limit=1") {
                attach("real-provider-probe-failure-manager-state", snapshot.provider)
            }
            retainBootstrapDiagnostics("real-provider-probe-failure-bootstrap", home: forgeHome)
        }
        XCTAssertTrue(reachable, "Live Provider probe did not reach the loaded model; inspect retained failure controls and manager state")
        XCTAssertFalse(element("operator-unavailable").exists)
        let snapshot: OnboardingOperatorSnapshot = try await read("/api/manager/operator/snapshot?limit=1")
        let provider = try XCTUnwrap(snapshot.provider)
        XCTAssertEqual(provider.health, "contract_valid")
        XCTAssertEqual(provider.modelKey, model)
        XCTAssertEqual(provider.lastProbeMode, "contract")
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

    private func post<Value: Decodable & Sendable, Body: Encodable>(
        _ route: String,
        body: Body,
        timeout: TimeInterval = 8
    ) async throws -> Value {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(managerPort)\(route)"))
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
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw OnboardingFailure.managerResponseRejected(
                route: route,
                status: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
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
        if let scroll = scrolls.last {
            func isFullyVisible() -> Bool {
                target.isHittable
                    && scroll.frame.insetBy(dx: 2, dy: 2).contains(target.frame)
            }
            for _ in 0..<12 where !isFullyVisible() {
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

private struct OnboardingProjectSnapshot: Codable, Sendable, Equatable {
    struct Project: Codable, Sendable, Equatable {
        let projectID: String
        let displayName: String
        let canonicalRoot: String
        let projectGeneration: UInt64
        let lifecycleState: String
        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case displayName = "display_name"
            case canonicalRoot = "canonical_root"
            case projectGeneration = "project_generation"
            case lifecycleState = "lifecycle_state"
        }
    }
    let projects: [Project]
}

private struct OnboardingProjectGenerationRequest: Encodable, Sendable {
    let projectID: String
    let projectGeneration: UInt64

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectGeneration = "project_generation"
    }
}

private struct OnboardingInstructionImportRequest: Encodable, Sendable {
    let projectID: String
    let projectGeneration: UInt64
    let sourcePath: String

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case sourcePath = "source_path"
    }
}

private struct OnboardingInstructionQueue: Codable, Sendable {
    struct Package: Codable, Sendable {
        let id: String
        let documentCount: Int?
        let unresolvedDocumentCount: Int?
        let importReady: Bool?
        let state: String

        enum CodingKeys: String, CodingKey {
            case id, state
            case documentCount = "document_count"
            case unresolvedDocumentCount = "unresolved_document_count"
            case importReady = "import_ready"
        }
    }

    let revision: UInt64
    let running: Bool
    let packages: [Package]
}

private struct OnboardingManagedRunSnapshot: Codable, Sendable {
    struct CompletionPlan: Codable, Sendable {
        let instructionArtifactSHA256: [String]

        enum CodingKeys: String, CodingKey {
            case instructionArtifactSHA256 = "instruction_artifact_sha256"
        }
    }

    struct Run: Codable, Sendable {
        let runID: String
        let projectID: String
        let projectGeneration: UInt64
        let mission: String
        let state: String?
        let modelKey: String?
        let nextAction: String?
        let lastAssistantMessage: String?
        let lastErrorCode: String?
        let lastErrorSummary: String?
        let completionGates: [String]
        let completionPlan: CompletionPlan?
        enum CodingKeys: String, CodingKey {
            case runID = "run_id"
            case projectID = "project_id"
            case projectGeneration = "project_generation"
            case mission
            case state
            case modelKey = "model_key"
            case nextAction = "next_action"
            case lastAssistantMessage = "last_assistant_message"
            case lastErrorCode = "last_error_code"
            case lastErrorSummary = "last_error_summary"
            case completionGates = "completion_gates"
            case completionPlan = "completion_plan"
        }
    }
    let runs: [Run]
}

private struct OnboardingProviderProbeFailureDiagnostics: Encodable, Sendable {
    let notice: String?
    let error: String?
    let lastProbeError: String?
    let operatorUnavailable: Bool
    let providerHealth: String?
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

/// Attaches to an already-running, owner-named Desktop candidate and exercises
/// the real Projects controls against the owner's live loopback Manager and LM
/// Studio provider. The explicit environment gate prevents this destructive
/// acceptance flow from entering ordinary CI.
@MainActor
final class DesktopCandidateLiveProjectsUITests: XCTestCase, @unchecked Sendable {
    private let projectID = "d2610542-b616-7e8f-ee36-ef902d6060e1"
    private let projectGeneration: UInt64 = 5
    private let managerBaseURL = URL(string: "http://127.0.0.1:7788")!
    private var app: XCUIApplication!
    private var candidatePath = ""

    func testLiveContinuityDeletesSelectedProjectDataAndPersistsAcrossRelaunch() async throws {
        let environment = ProcessInfo.processInfo.environment
        let explicitMarker = "/tmp/forge-run-live-continuity-clear"
        guard environment["FORGE_RUN_LIVE_CONTINUITY_CLEAR"] == "1"
                || FileManager.default.fileExists(atPath: explicitMarker) else {
            throw XCTSkip(
                "Requires explicit FORGE_RUN_LIVE_CONTINUITY_CLEAR=1 authorization "
                    + "or the local live-clear marker"
            )
        }
        let requestedPath = environment["FORGE_DESKTOP_CANDIDATE_PATH"]
            ?? "/Users/flynn/Desktop/Forge Conductor 0.15.0 (14)-849b879.app"
        candidatePath = URL(fileURLWithPath: requestedPath).standardizedFileURL.path
        try attachToRunningCandidate()

        let beforeIDs = try await waitForContinuityIDs(minimumCount: 1, timeout: 20)
        print("EVIDENCE continuity_before_ids=\(beforeIDs.joined(separator: ","))")

        try openContinuity()
        let selectedRow = app.staticTexts["continuity-project-row-\(projectID)"]
        XCTAssertTrue(selectedRow.waitForExistence(timeout: 10))
        try makeHittable(selectedRow)
        selectedRow.click()
        try clickControl("continuity-delete-project", expectedLabel: "Delete")
        XCTAssertTrue(app.staticTexts["Delete continuity data?"].waitForExistence(timeout: 5))
        let confirmSelected = app.sheets.buttons["Delete"]
        XCTAssertTrue(confirmSelected.waitForExistence(timeout: 5))
        confirmSelected.click()

        let afterSelectedIDs = try await waitForContinuityIDs(expectedCount: 0, timeout: 30)
        try refreshCurrentView()
        XCTAssertTrue(waitUntil(timeout: 10) { !selectedRow.exists })
        XCTAssertTrue(app.descendants(matching: .any)["continuity-projects-empty"].exists)
        print("EVIDENCE continuity_button=Delete project_id=\(projectID) after_refresh_ids=\(afterSelectedIDs.joined(separator: ","))")

        app.terminate()
        for running in NSWorkspace.shared.runningApplications where
            running.bundleURL?.standardizedFileURL.path == candidatePath {
            _ = running.terminate()
        }
        XCTAssertTrue(waitUntil(timeout: 15) {
            !NSWorkspace.shared.runningApplications.contains(where: {
                $0.bundleURL?.standardizedFileURL.path == self.candidatePath
            })
        })
        try await launchCandidateAtExactPath()
        try attachToRunningCandidate()
        let afterRelaunchIDs = try await waitForContinuityIDs(expectedCount: 0, timeout: 30)
        try openContinuity()
        XCTAssertTrue(app.descendants(matching: .any)["continuity-projects-empty"].waitForExistence(timeout: 10))
        print("EVIDENCE continuity_after_relaunch_ids=\(afterRelaunchIDs) candidate_path=\(candidatePath)")
    }

    func testLiveInstructionReorderDeleteAndProjectMaintenanceControls() async throws {
        let environment = ProcessInfo.processInfo.environment
        let requestedPath = environment["FORGE_DESKTOP_CANDIDATE_PATH"]
            ?? "/Users/flynn/Desktop/Forge Conductor 0.14.7 (13)-74ead97.app"
        candidatePath = URL(fileURLWithPath: requestedPath).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: candidatePath),
              let running = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleURL?.standardizedFileURL.path == candidatePath
              }) else {
            throw XCTSkip("The explicit owner Desktop candidate is not running")
        }
        let requestedPID = running.processIdentifier
        XCTAssertEqual(running.bundleURL?.standardizedFileURL.path, candidatePath)
        XCTAssertFalse(candidatePath.hasPrefix("/Applications/"))

        app = XCUIApplication(url: URL(fileURLWithPath: candidatePath))
        app.activate()
        XCTAssertTrue(app.windows["forge-main-window"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.firstMatch.title, "Forge Conductor")
        print("EVIDENCE candidate_path=\(candidatePath) pid=\(requestedPID) window_title=\(app.windows.firstMatch.title)")

        var queue = try await instructionQueue()
        if queue.packages.contains(where: { $0.state == "running" }) {
            queue = try await postQueue("/api/manager/projects/instruction-packages/stop", body: projectBody())
            print("EVIDENCE cleanup_stop order=\(queue.packageIDs) states=\(queue.packageStates)")
        }
        XCTAssertGreaterThanOrEqual(queue.packages.count, 2)
        let firstID = try XCTUnwrap(queue.packages.first?.id)
        let secondID = try XCTUnwrap(queue.packages.dropFirst().first?.id)
        print("EVIDENCE normal_before_order=\(queue.packageIDs)")

        try openProjects()
        XCTAssertFalse(
            app.buttons["instruction-queue-toggle"].exists,
            "The current Projects workflow must not expose Managed Run controls"
        )
        try clickControl("instruction-package-move-down-\(firstID)")
        var expectedOrder = queue.packageIDs
        expectedOrder.swapAt(0, 1)
        let normalReordered = try await waitForOrder(expectedOrder, timeout: 20)
        print("EVIDENCE normal_reordered_before_refresh=\(normalReordered.packageIDs)")
        try refreshProjects()
        let normalRefreshed = try await waitForOrder(expectedOrder, timeout: 20)
        print("EVIDENCE normal_reordered_after_refresh=\(normalRefreshed.packageIDs)")

        try clickControl("instruction-package-remove-\(secondID)", expectedLabel: "Delete Package")
        let expectedAfterDelete = expectedOrder.filter { $0 != secondID }
        _ = try await waitForOrder(expectedAfterDelete, timeout: 20)
        try refreshProjects()
        let normalRemoved = try await waitForOrder(expectedAfterDelete, timeout: 20)
        XCTAssertFalse(app.buttons["instruction-package-remove-\(secondID)"].exists)
        print("EVIDENCE normal_removed package_id=\(secondID) after_refresh_order=\(normalRemoved.packageIDs)")
        attachScreenshot("desktop-candidate-normal-reorder-remove")

        let sourcePath = try XCTUnwrap(normalRemoved.packages.first?.sourcePath)
        let firstImport = try await postQueue(
            "/api/manager/projects/instruction-packages/import",
            body: projectBody(extra: ["source_path": sourcePath])
        )
        let minimumFirstID = try XCTUnwrap(firstImport.packages.last?.id)
        let secondImport = try await postQueue(
            "/api/manager/projects/instruction-packages/import",
            body: projectBody(extra: ["source_path": sourcePath])
        )
        let minimumSecondID = try XCTUnwrap(secondImport.packages.last?.id)
        XCTAssertNotEqual(minimumFirstID, minimumSecondID)
        try refreshProjects()

        let window = app.windows["forge-main-window"]
        resizeMainWindowToMinimum(window)
        print("EVIDENCE minimum_window width=\(Int(window.frame.width)) height=\(Int(window.frame.height)) order=\(secondImport.packageIDs)")

        let minimumRemove = app.buttons["instruction-package-remove-\(minimumFirstID)"]
        try makeHittable(minimumRemove)
        XCTAssertTrue(minimumRemove.isEnabled)
        XCTAssertEqual(minimumRemove.label, "Delete Package")

        let beforeMinimumReorder = secondImport.packageIDs
        try clickControl("instruction-package-move-down-\(minimumFirstID)")
        var expectedMinimumOrder = beforeMinimumReorder
        let minimumFirstIndex = try XCTUnwrap(expectedMinimumOrder.firstIndex(of: minimumFirstID))
        expectedMinimumOrder.swapAt(minimumFirstIndex, minimumFirstIndex + 1)
        let minimumReordered = try await waitForOrder(expectedMinimumOrder, timeout: 20)
        try refreshProjects()
        let minimumRefreshed = try await waitForOrder(expectedMinimumOrder, timeout: 20)
        print("EVIDENCE minimum_reorder before=\(beforeMinimumReorder) after=\(minimumReordered.packageIDs) after_refresh=\(minimumRefreshed.packageIDs)")

        try clickControl("instruction-package-remove-\(minimumFirstID)")
        let expectedAfterMinimumRemove = expectedMinimumOrder.filter { $0 != minimumFirstID }
        _ = try await waitForOrder(expectedAfterMinimumRemove, timeout: 20)
        try refreshProjects()
        let minimumRemoved = try await waitForOrder(expectedAfterMinimumRemove, timeout: 20)
        XCTAssertFalse(app.buttons["instruction-package-remove-\(minimumFirstID)"].exists)
        print("EVIDENCE minimum_remove package_id=\(minimumFirstID) after_refresh_order=\(minimumRemoved.packageIDs) retained_package=\(minimumSecondID)")
        XCTAssertTrue(app.buttons["project-reset"].exists)
        XCTAssertTrue(app.buttons["project-clear-cache"].exists)
        attachScreenshot("desktop-candidate-minimum-reorder-delete-maintenance")
    }

    private func openProjects() throws {
        let projects = app.buttons["tab-projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 10))
        projects.click()
        XCTAssertTrue(app.descendants(matching: .any)["detail-projects"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["project-instruction-packages"].waitForExistence(timeout: 10))
    }

    private func attachToRunningCandidate() throws {
        guard FileManager.default.fileExists(atPath: candidatePath),
              let running = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleURL?.standardizedFileURL.path == candidatePath
              }) else {
            throw XCTSkip("The explicit owner Desktop candidate is not running")
        }
        XCTAssertFalse(candidatePath.hasPrefix("/Applications/"))
        app = XCUIApplication(bundleIdentifier: "com.forge-conductor.app")
        app.activate()
        XCTAssertTrue(app.windows["forge-main-window"].waitForExistence(timeout: 15))
        print("EVIDENCE candidate_path=\(candidatePath) pid=\(running.processIdentifier)")
    }

    private func launchCandidateAtExactPath() async throws {
        let expectedPath = candidatePath
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: expectedPath),
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application?.bundleURL?.standardizedFileURL.path == expectedPath {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: LiveProjectsEvidenceError.invalidPayload(
                        "exact Desktop candidate relaunch"
                    ))
                }
            }
        }
    }

    private func openContinuity() throws {
        let continuity = app.buttons["tab-continuity"]
        XCTAssertTrue(continuity.waitForExistence(timeout: 15))
        continuity.click()
        XCTAssertTrue(app.descendants(matching: .any)["detail-continuity"].waitForExistence(timeout: 15))
    }

    private func refreshCurrentView() throws {
        let refresh = app.buttons["toolbar-refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        XCTAssertTrue(refresh.isHittable)
        refresh.click()
    }

    private func continuityIDs() async throws -> [String] {
        let snapshot = try await operatorSnapshot()
        let operations = snapshot["continuity_operations"] as? [[String: Any]] ?? []
        return operations.compactMap { $0["operation_id"] as? String }
    }

    private func waitForContinuityIDs(
        minimumCount: Int? = nil,
        expectedCount: Int? = nil,
        excluding excluded: Set<String> = [],
        timeout: TimeInterval
    ) async throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: [String] = []
        var lastError: Error?
        while Date() < deadline {
            do {
                latest = try await continuityIDs()
                let satisfiesMinimum = minimumCount.map { latest.count >= $0 } ?? true
                let satisfiesExpected = expectedCount.map { latest.count == $0 } ?? true
                if satisfiesMinimum,
                   satisfiesExpected,
                   excluded.isDisjoint(with: latest) {
                    return latest
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        if let lastError, latest.isEmpty { throw lastError }
        throw LiveProjectsEvidenceError.invalidPayload(
            "continuity IDs did not reach the expected state; latest=\(latest)"
        )
    }

    private func clickControl(_ identifier: String, expectedLabel: String? = nil) throws {
        let control = app.buttons[identifier]
        XCTAssertTrue(control.waitForExistence(timeout: 15), "Missing control \(identifier)")
        try makeHittable(control)
        XCTAssertTrue(control.isEnabled, "Disabled control \(identifier)")
        if let expectedLabel { XCTAssertTrue(control.label.contains(expectedLabel)) }
        print("EVIDENCE click id=\(identifier) label=\(control.label) hittable=\(control.isHittable) enabled=\(control.isEnabled)")
        control.click()
    }

    private func makeHittable(_ target: XCUIElement) throws {
        guard target.waitForExistence(timeout: 10) else {
            throw LiveProjectsEvidenceError.controlUnavailable(target.identifier)
        }
        let scrolls = app.scrollViews.containing(.any, identifier: target.identifier).allElementsBoundByIndex
        if let scroll = scrolls.last {
            for _ in 0..<16 where !target.isHittable {
                let distance = target.frame.midY - scroll.frame.midY
                scroll.scroll(byDeltaX: 0, deltaY: -min(320, max(-320, distance)))
            }
        }
        guard target.isHittable else {
            throw LiveProjectsEvidenceError.controlNotHittable(target.identifier)
        }
    }

    private func refreshProjects() throws {
        let refresh = app.buttons["toolbar-refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        XCTAssertTrue(refresh.isHittable)
        refresh.click()
    }

    private func resizeMainWindowToMinimum(_ window: XCUIElement) {
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        if window.frame.width > 1_120 || window.frame.height > 840 {
            let handle = window.coordinate(withNormalizedOffset: CGVector(dx: 0.998, dy: 0.998))
            handle.click(
                forDuration: 0.2,
                thenDragTo: handle.withOffset(CGVector(dx: -800, dy: -600))
            )
        }
        XCTAssertTrue(waitUntil(timeout: 5) { window.frame.width <= 1_120 && window.frame.height <= 840 })
        XCTAssertLessThanOrEqual(window.frame.width, 1_120)
        XCTAssertLessThanOrEqual(window.frame.height, 840)
    }

    private func instructionQueue() async throws -> LiveQueue {
        try await postQueue("/api/manager/projects/instruction-packages", body: projectBody())
    }

    private func postQueue(_ path: String, body: [String: Any]) async throws -> LiveQueue {
        let object = try await request(path: path, method: "POST", body: body)
        return try LiveQueue(object)
    }

    private func operatorSnapshot() async throws -> [String: Any] {
        try await request(path: "/api/manager/operator/snapshot?limit=100", method: "GET", body: nil)
    }

    private func request(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: path, relativeTo: managerBaseURL))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if method != "GET" {
            let credentialURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".forge-conductor/manager-control.secret")
            let credential = try await Task.detached(priority: .userInitiated) {
                try String(contentsOf: credentialURL, encoding: .utf8)
            }.value
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:], options: [.sortedKeys])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
        guard status == 200 else {
            throw LiveProjectsEvidenceError.managerRejected(path, status, String(decoding: data, as: UTF8.self))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LiveProjectsEvidenceError.invalidPayload(path)
        }
        return object
    }

    private func projectBody(extra: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "project_id": projectID,
            "project_generation": projectGeneration,
        ]
        for (key, value) in extra { body[key] = value }
        return body
    }

    private func waitForActivePackage(_ packageID: String, timeout: TimeInterval) async throws -> LiveQueue {
        try await waitForQueue(timeout: timeout) { queue in
            queue.running && queue.state(of: packageID) == "running" && queue.runID(of: packageID) != nil
        }
    }

    private func waitForPackage(_ packageID: String, state: String, timeout: TimeInterval) async throws -> LiveQueue {
        try await waitForQueue(timeout: timeout) { $0.state(of: packageID) == state }
    }

    private func waitForOrder(_ packageIDs: [String], timeout: TimeInterval) async throws -> LiveQueue {
        try await waitForQueue(timeout: timeout) { $0.packageIDs == packageIDs }
    }

    private func waitForQueue(
        timeout: TimeInterval,
        predicate: (LiveQueue) -> Bool
    ) async throws -> LiveQueue {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try await instructionQueue()
        while Date() < deadline {
            if predicate(latest) { return latest }
            try await Task.sleep(for: .milliseconds(200))
            latest = try await instructionQueue()
        }
        throw LiveProjectsEvidenceError.queueTimeout(latest.packageStates)
    }

    private func waitForLiveLMStudioRun(_ runID: String, timeout: TimeInterval) async throws -> LiveRun {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let run = try await liveRun(runID),
               run.providerID == "lmstudio",
               run.modelKey == "qwen/qwen3-coder-30b",
               run.activeSessionID != nil,
               !["cancelled", "completed", "failed_terminal"].contains(run.state) {
                return run
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw LiveProjectsEvidenceError.runTimeout(runID, "live LM Studio")
    }

    private func waitForRun(_ runID: String, state: String, timeout: TimeInterval) async throws -> LiveRun {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let run = try await liveRun(runID), run.state == state { return run }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw LiveProjectsEvidenceError.runTimeout(runID, state)
    }

    private func liveRun(_ runID: String) async throws -> LiveRun? {
        let snapshot = try await operatorSnapshot()
        let runs = snapshot["runs"] as? [[String: Any]] ?? []
        return try runs.first(where: { ($0["run_id"] as? String) == runID }).map(LiveRun.init)
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return predicate()
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct LiveQueue {
    struct Package {
        let id: String
        let state: String
        let runID: String?
        let sourcePath: String?
    }

    let running: Bool
    let packages: [Package]

    init(_ object: [String: Any]) throws {
        guard let running = object["running"] as? Bool,
              let rawPackages = object["packages"] as? [[String: Any]] else {
            throw LiveProjectsEvidenceError.invalidPayload("instruction queue")
        }
        self.running = running
        packages = try rawPackages.map { package in
            guard let id = package["id"] as? String,
                  let state = package["state"] as? String else {
                throw LiveProjectsEvidenceError.invalidPayload("instruction package")
            }
            return Package(
                id: id,
                state: state,
                runID: package["run_id"] as? String,
                sourcePath: package["source_path"] as? String
            )
        }
    }

    var packageIDs: [String] { packages.map(\.id) }
    var packageStates: [String] { packages.map { "\($0.id)=\($0.state)" } }
    func state(of packageID: String) -> String? { packages.first { $0.id == packageID }?.state }
    func runID(of packageID: String) -> String? { packages.first { $0.id == packageID }?.runID }
}

private struct LiveRun {
    let runID: String
    let state: String
    let providerID: String
    let modelKey: String
    let activeSessionID: String?

    init(_ object: [String: Any]) throws {
        guard let runID = object["run_id"] as? String,
              let state = object["state"] as? String,
              let providerID = object["provider_id"] as? String,
              let modelKey = object["model_key"] as? String else {
            throw LiveProjectsEvidenceError.invalidPayload("operator run")
        }
        self.runID = runID
        self.state = state
        self.providerID = providerID
        self.modelKey = modelKey
        activeSessionID = object["active_session_id"] as? String
    }
}

private enum LiveProjectsEvidenceError: LocalizedError {
    case controlUnavailable(String)
    case controlNotHittable(String)
    case managerRejected(String, Int, String)
    case invalidPayload(String)
    case queueTimeout([String])
    case runTimeout(String, String)

    var errorDescription: String? {
        switch self {
        case let .controlUnavailable(id): "Control \(id) was unavailable"
        case let .controlNotHittable(id): "Control \(id) was not hittable"
        case let .managerRejected(path, status, body): "Manager rejected \(path) with \(status): \(body)"
        case let .invalidPayload(name): "Invalid live evidence payload: \(name)"
        case let .queueTimeout(states): "Timed out waiting for queue state: \(states)"
        case let .runTimeout(runID, state): "Timed out waiting for run \(runID) to reach \(state)"
        }
    }
}

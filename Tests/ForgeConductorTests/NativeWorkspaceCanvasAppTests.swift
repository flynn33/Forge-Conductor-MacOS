#if !SWIFT_PACKAGE
import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import Forge_Conductor
import ForgeConductorCore

@MainActor
final class NativeWorkspaceCanvasAppTests: XCTestCase, @unchecked Sendable {
    private var window: NSWindow?
    private var scopeFixture: WorkspaceScopeFixture?
    private var draftFixture: NativeWorkspaceDraftFixture?
    private let directEvidence = DirectNativeFixtureEvidenceWriter()
    private var nativeDraftCurrentStage = "not-started"

    nonisolated override func setUp() async throws { try await requireApplicationHost() }
    nonisolated override func tearDown() async throws { await closeFixtures() }

    private func requireApplicationHost() throws {
        continueAfterFailure = false
        guard NSApp != nil, Bundle.main.bundleURL.pathExtension == "app", !NSScreen.screens.isEmpty else {
            throw WorkspaceCanvasFixtureFailure("Run this class in ForgeConductorAppTests with a native display.")
        }
        try directEvidence.configure(testName: name)
    }

    private func closeFixtures() async {
        if let draftFixture {
            nativeDraftStage("teardown.positive-fixture.begin")
            await draftFixture.close()
            nativeDraftStage("teardown.positive-fixture.returned")
        }
        draftFixture = nil
        if let scopeFixture { await scopeFixture.close() }
        scopeFixture = nil
        if let window { window.orderOut(nil); window.contentView = nil; window.close() }
        window = nil
    }

    func testOwnedAppKitAndSwiftUIExportComparisonDiagnostic() async throws {
        continueAfterFailure = true
        for technology in ["AppKit", "SwiftUI"] {
            let measured = try await nativeDraftExportComparison(technology: technology)
            nativeDraftRetainMeasurement(measured.report, name: "native-export-comparison-" + technology)
            XCTAssertTrue(measured.complete, "The separate synthetic export comparison did not complete its bounded snapshot.")
            XCTAssertEqual(measured.matchingButtons, 1,
                           "The separate owned window did not export exactly one identified button.")
        }
    }

    private func nativeDraftExportComparison(technology: String) async throws
        -> (report: [String: Any], complete: Bool, matchingButtons: Int) {
        let identifier = "native-export-comparison-control"
        let title = "Export comparison control"
        let root: NSView
        if technology == "AppKit" {
            let button = NSButton(title: title, target: nil, action: nil)
            button.setAccessibilityIdentifier(identifier)
            root = button
            XCTAssertEqual(button.accessibilityIdentifier(), identifier)
            XCTAssertEqual(button.title, title)
        } else {
            root = NSHostingView(rootView: Button(title) {}.accessibilityIdentifier(identifier))
        }
        let owned = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 320, height: 120),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owned.isReleasedWhenClosed = false
        owned.title = "Synthetic export comparison \(technology) \(UUID().uuidString)"
        owned.contentView = root
        window = owned
        defer {
            owned.orderOut(nil); owned.contentView = nil; owned.close()
            if window === owned { window = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        owned.makeKeyAndOrderFront(nil); owned.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(owned.isKeyWindow && owned.isVisible)
        XCTAssertTrue(owned.contentView === root && root.window === owned)
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 2
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var report: [String: Any] = [
            "classification": "Separate synthetic own-window export diagnostic only; no production workflow qualification",
            "technology": technology, "process_pid": ownPID, "AXIsProcessTrusted": AXIsProcessTrusted(),
            "expected_identifier": identifier, "expected_title": title,
            "owned_window_title": owned.title, "window_visible": owned.isVisible, "window_key": owned.isKeyWindow,
            "exact_owned_root": owned.contentView === root && root.window === owned,
            "root_type": String(String(reflecting: type(of: root)).prefix(256)),
            "native_root_identifier": String(root.accessibilityIdentifier().prefix(256)),
            "native_root_role": root.accessibilityRole()?.rawValue as Any? ?? NSNull(),
            "shared_deadline_seconds": 2, "single_exported_message_timeout_seconds": 0.1,
            "node_limit": 64, "depth_limit": 16, "window_limit": 32,
            "one_initial_settle_milliseconds": 40, "retry_count": 0,
        ]
        var rows: [[String: Any]] = [], matchingButtons = 0, complete = false
        func requireOwner() throws {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  owned.contentView === root, root.window === owned,
                  NSApp.windows.filter({ $0.title == owned.title }).count == 1 else {
                throw WorkspaceCanvasFixtureFailure("The synthetic comparison lost its owned window/root or finite deadline.")
            }
        }
        do {
            try requireOwner()
            let application = AXUIElementCreateApplication(ownPID)
            let windows = try NativeWorkspaceDraftAXQuery.children(application, kAXWindowsAttribute,
                                                                   limit: 32, deadline: deadline)
            let matches = try windows.filter {
                try NativeWorkspaceDraftAXQuery.attribute($0, kAXTitleAttribute, deadline: deadline) as? String == owned.title
            }
            guard matches.count == 1 else {
                throw WorkspaceCanvasFixtureFailure("The synthetic comparison did not find one exact uniquely titled own-process AX window.")
            }
            var pending: [(AXUIElement, [Int])] = [(matches[0], [])]
            var seen: [AXUIElement] = []
            while let (element, path) = pending.popLast() {
                try requireOwner()
                guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
                guard seen.count < 64, path.count <= 16 else {
                    throw WorkspaceCanvasFixtureFailure("The synthetic comparison exceeded its 64-node/16-level bound.")
                }
                seen.append(element)
                var row: [String: Any] = ["visit_index": seen.count - 1, "discovery_path": path]
                var rawIdentifier: String?, rawRole: String?
                for attribute in [kAXIdentifierAttribute, kAXRoleAttribute, kAXTitleAttribute] {
                    try requireOwner()
                    try NativeWorkspaceDraftAXQuery.prepare(element, deadline: deadline)
                    var value: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                    let text = value as? String
                    row[attribute] = [
                        "status": status.rawValue,
                        "cf_type_id": value.map { CFGetTypeID($0) as Any } ?? NSNull(),
                        "string_sample": text.map { String($0.prefix(256)) as Any } ?? NSNull(),
                    ] as [String: Any]
                    if attribute == kAXIdentifierAttribute, status == .success { rawIdentifier = text }
                    if attribute == kAXRoleAttribute, status == .success { rawRole = text }
                    try requireOwner()
                }
                rows.append(row)
                if rawIdentifier == identifier && rawRole == NSAccessibility.Role.button.rawValue { matchingButtons += 1 }
                let children = try NativeWorkspaceDraftAXQuery.children(element, kAXChildrenAttribute,
                    limit: 64 - seen.count - pending.count, deadline: deadline)
                pending.append(contentsOf: children.enumerated().map { ($0.element, path + [$0.offset]) })
            }
            try requireOwner()
            complete = true
        } catch {
            report["snapshot_error_type"] = String(String(reflecting: type(of: error)).prefix(1_024))
            report["snapshot_error_description"] = String(String(describing: error).prefix(4_096))
        }
        report["snapshot_complete"] = complete
        report["matching_button_count"] = matchingButtons
        report["visited_nodes"] = rows
        report["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
        report["within_shared_deadline"] = ProcessInfo.processInfo.systemUptime < deadline
        return (report, complete, matchingButtons)
    }

    func testProductionManagerNativeDraftSurvivesWorkspaceAndSectionTransitions() async throws {
        do {
            continueAfterFailure = true
            nativeDraftStage("manager.fixture.create")
            defer { nativeDraftStage("manager.test.return-from-" + nativeDraftCurrentStage) }
            let fixture = try NativeWorkspaceDraftFixture(page: .manager)
            draftFixture = fixture
            nativeDraftStage("bootstrap.await-success")
            try await exposeNativeDraftFixture(fixture)
            nativeDraftStage("bootstrap.published-success")
            let app = try XCTUnwrap(fixture.model.app)
            let originalConfiguration = try Data(contentsOf: app.paths.configJSON)
            let originalHost = fixture.model.setHost
            let draft = "native-workspace-manager-draft.invalid"
            nativeDraftStage("default.field.lookup")
            let field = try await nativeDraftField(in: fixture.hosting, identifier: "Dashboard host",
                                                   placeholder: "Dashboard host")
            try editNativeDraftField(field, value: draft, in: fixture.window)
            try await waitUntil("The real Manager field did not update its staged AppModel value.") {
                try fixture.model.setHost == draft && field.stringValue == draft
            }
            nativeDraftStage("edit.binding-confirmed.default-to-custom.begin")
            let layout = nativeDraftLayout(viewID: "manager.settings")
            try fixture.preferences.save(layout)
            nativeDraftStage("default-to-custom.preference-saved")
            let document = try await nativeDraftDocument(fixture, panelID: "manager-dashboard-settings")
            let panel = try XCTUnwrap(document.panelHosts["manager-dashboard-settings"])
            let hosting = panel.hostingView
            nativeDraftStage("custom.field.lookup")
            let customField = try await nativeDraftField(in: hosting, identifier: "Dashboard host",
                                                         placeholder: "Dashboard host")
            XCTAssertEqual((try customField.stringValue), draft)
            nativeDraftStage("custom.hide.begin")
            try nativeDraftHide(panel)
            nativeDraftStage("custom.hide.native-action-returned")
            try await waitUntil("The actual native Hide action did not hide Manager settings.") { panel.isHidden }
            XCTAssertFalse(try XCTUnwrap(fixture.preferences.activeLayout(for: "manager.settings")?
                .panels.first { $0.id == "manager-dashboard-settings" }).isVisible)
            try fixture.preferences.setShown(true, for: "manager-dashboard-settings", in: "manager.settings")
            try await waitUntil("Manager settings did not resume from the retained native host.") { !panel.isHidden }
            XCTAssertTrue(panel.hostingView === hosting)
            XCTAssertEqual((try customField.stringValue), draft)
            nativeDraftStage("named-layout.save.begin")
            let named = try fixture.preferences.saveAs(try XCTUnwrap(fixture.preferences.activeLayout(for: "manager.settings")),
                                                       named: "Manager Native Draft")
            try await waitUntil("The named Manager layout did not become active.") {
                fixture.preferences.activeLayout(for: "manager.settings")?.id == named
            }
            let namedFrame = NativeWorkspaceFrame(x: 380, y: 60, width: 860, height: 440)
            try fixture.preferences.setFrame(namedFrame, for: "manager-dashboard-settings", in: "manager.settings")
            try await waitUntil("The named Manager geometry did not reach the actual panel.") { panel.frame == namedFrame.nativeRect }
            try fixture.preferences.activate(layout.id, for: "manager.settings")
            try await waitUntil("The original Manager layout did not reach the actual panel.") {
                panel.frame == layout.panels.first { $0.id == "manager-dashboard-settings" }?.frame.nativeRect
            }
            try fixture.preferences.activate(named, for: "manager.settings")
            try await waitUntil("Named layout changes replaced the Manager binding.") {
                try panel.frame == namedFrame.nativeRect && panel.hostingView === hosting
                    && customField.stringValue == draft && fixture.model.setHost == draft
            }
            nativeDraftStage("manager.restore-default.begin")
            try fixture.preferences.reset("manager.settings")
            try await waitUntil("Default restoration did not dismantle Manager's custom canvas.") {
                self.nativeDraftViews(fixture.hosting).allSatisfy { !($0 is NativeWorkspaceDocumentView) }
            }
            let defaultField = try await nativeDraftField(in: fixture.hosting, identifier: "Dashboard host",
                                                          placeholder: "Dashboard host")
            XCTAssertEqual((try defaultField.stringValue), draft)
            nativeDraftStage("manager.section-transitions.begin")
            for (section, title) in [("shell", "Project Shell"), ("folders", "Authorized Folders"),
                                      ("workbench", "Workbench"), ("settings", "Settings")] {
                nativeDraftStage("manager.section." + section + ".press")
                try await nativeDraftPress("manager-section-" + section, in: fixture)
                try await nativeDraftRequireManagerTitle(title, in: fixture)
            }
            let resumed = try await nativeDraftField(in: fixture.hosting, identifier: "Dashboard host",
                                                     placeholder: "Dashboard host")
            XCTAssertEqual((try resumed.stringValue), draft)
            XCTAssertEqual(fixture.model.setHost, draft)
            XCTAssertNil(fixture.model.manager)
            XCTAssertNil(fixture.model.remoteManager)
            nativeDraftStage("manager.save-refusal.begin")
            try await nativeDraftPress("settings-save", in: fixture)
            XCTAssertEqual(fixture.model.managerMessage, "Manager is unavailable")
            XCTAssertEqual(try Data(contentsOf: app.paths.configJSON), originalConfiguration,
                           "The isolated native presentation must not turn a staged edit into a backend save.")
            nativeDraftStage("manager.reload.begin")
            try await nativeDraftPress("settings-reload", in: fixture)
            try await waitUntil("Explicit native Reload did not restore the actual bootstrap configuration.") {
                try !fixture.model.isUpdatingSettings && fixture.model.setHost == originalHost
                    && resumed.stringValue == originalHost
            }
            XCTAssertEqual(fixture.recorder.creations, 1)
            XCTAssertTrue(fixture.model.app === app)
        } catch {
            let actual = error as NSError
            nativeDraftRetainMeasurement([
                "classification": "Diagnostic only: actual error caught at the test method boundary; the identical error is rethrown and all original assertions remain in order",
                "test_method": "testProductionManagerNativeDraftSurvivesWorkspaceAndSectionTransitions",
                "stage": nativeDraftCurrentStage,
                "error_type": String(String(reflecting: type(of: error)).prefix(1_024)),
                "error_description": String(String(describing: error).prefix(4_096)),
                "NSError_domain": String(actual.domain.prefix(1_024)),
                "NSError_code": actual.code,
                "task_cancelled": Task.isCancelled,
            ], name: "native-draft-test-method-boundary-error")
            throw error
        }
    }

    func testProductionProjectsNativeRepositoryDraftSurvivesWorkspaceWithSinglePageOwner() async throws {
        do {
            continueAfterFailure = true
            nativeDraftStage("projects.fixture.create")
            defer { nativeDraftStage("projects.test.return-from-" + nativeDraftCurrentStage) }
            let fixture = try NativeWorkspaceDraftFixture(page: .projects)
            draftFixture = fixture
            nativeDraftStage("bootstrap.await-success")
            try await exposeNativeDraftFixture(fixture)
            nativeDraftStage("bootstrap.published-success")
            let draft = "https://github.com/fixture/native-workspace-unsaved"
            nativeDraftStage("projects.default-viewport.capture.begin")
            try nativeDraftRecordViewport(fixture, name: "projects-before-default-field")
            nativeDraftStage("projects.default-viewport.capture.returned")
            nativeDraftStage("default.field.lookup")
            let field = try await nativeDraftField(in: fixture.hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location")
            try editNativeDraftField(field, value: draft, in: fixture.window)
            try await waitUntil("The real Projects repository field did not retain the native edit.") { (try field.stringValue) == draft }
            try await nativeDraftRequireProjectIdentity(fixture)
            nativeDraftStage("edit.binding-confirmed.default-to-custom.begin")
            let layout = nativeDraftLayout(viewID: "projects")
            try fixture.preferences.save(layout)
            nativeDraftStage("default-to-custom.preference-saved")
            let document = try await nativeDraftDocument(fixture, panelID: "projects-repository")
            let panel = try XCTUnwrap(document.panelHosts["projects-repository"])
            let hosting = panel.hostingView
            nativeDraftStage("custom.field.lookup")
            let customField = try await nativeDraftField(in: hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location")
            XCTAssertEqual((try customField.stringValue), draft)
            nativeDraftStage("custom.hide.begin")
            try nativeDraftHide(panel)
            nativeDraftStage("custom.hide.native-action-returned")
            try await waitUntil("The actual native Hide action did not hide the repository panel.") { panel.isHidden }
            try fixture.preferences.setShown(true, for: "projects-repository", in: "projects")
            try await waitUntil("The retained repository host did not resume.") { !panel.isHidden }
            XCTAssertTrue(panel.hostingView === hosting)
            XCTAssertEqual((try customField.stringValue), draft)
            nativeDraftStage("named-layout.save.begin")
            let named = try fixture.preferences.saveAs(try XCTUnwrap(fixture.preferences.activeLayout(for: "projects")),
                                                       named: "Projects Native Draft")
            let namedFrame = NativeWorkspaceFrame(x: 360, y: 260, width: 940, height: 320)
            try fixture.preferences.setFrame(namedFrame, for: "projects-repository", in: "projects")
            try await waitUntil("The named repository geometry did not reach the actual panel.") { panel.frame == namedFrame.nativeRect }
            try fixture.preferences.activate(layout.id, for: "projects")
            try await waitUntil("The original repository geometry did not reach the actual panel.") {
                panel.frame == layout.panels.first { $0.id == "projects-repository" }?.frame.nativeRect
            }
            try fixture.preferences.activate(named, for: "projects")
            try await waitUntil("Named layouts lost the unsaved repository binding.") {
                try panel.frame == namedFrame.nativeRect && panel.hostingView === hosting && customField.stringValue == draft
            }
            try fixture.preferences.reset("projects")
            try await waitUntil("Default restoration did not dismantle Projects' custom canvas.") {
                self.nativeDraftViews(fixture.hosting).allSatisfy { !($0 is NativeWorkspaceDocumentView) }
            }
            let restored = try await nativeDraftField(in: fixture.hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location")
            XCTAssertEqual((try restored.stringValue), draft)
            try await nativeDraftRequireProjectIdentity(fixture)
            try fixture.preferences.activate(named, for: "projects")
            let reactivated = try await nativeDraftField(in: fixture.hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location")
            XCTAssertEqual((try reactivated.stringValue), draft)
            try fixture.preferences.reset("projects")
            let finalDefault = try await nativeDraftField(in: fixture.hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location")
            XCTAssertEqual((try finalDefault.stringValue), draft)
            nativeDraftStage("projects.all-transitions-complete.owner-observations")
            let observations = await fixture.client.observations()
            XCTAssertEqual(observations.snapshots, 1,
                           "Layout presentation changes must not recreate/reload the page StateObject.")
            XCTAssertEqual(observations.repositoryWrites, 0)
            XCTAssertEqual(observations.otherMutations, 0)
            XCTAssertEqual(fixture.recorder.creations, 1)
        } catch {
            let actual = error as NSError
            nativeDraftRetainMeasurement([
                "classification": "Diagnostic only: actual error caught at the test method boundary; the identical error is rethrown and all original assertions remain in order",
                "test_method": "testProductionProjectsNativeRepositoryDraftSurvivesWorkspaceWithSinglePageOwner",
                "stage": nativeDraftCurrentStage,
                "error_type": String(String(reflecting: type(of: error)).prefix(1_024)),
                "error_description": String(String(describing: error).prefix(4_096)),
                "NSError_domain": String(actual.domain.prefix(1_024)),
                "NSError_code": actual.code,
                "task_cancelled": Task.isCancelled,
            ], name: "native-draft-test-method-boundary-error")
            throw error
        }
    }

    private func exposeNativeDraftFixture(_ fixture: NativeWorkspaceDraftFixture) async throws {
        try await waitUntil("The real isolated positive bootstrap did not publish settings.", timeout: 10) {
            !fixture.model.isBootstrapping
        }
        guard fixture.model.hasLoadedInitialSettings, let app = fixture.model.app else {
            throw WorkspaceCanvasFixtureFailure("The positive native fixture did not complete real ForgeApp/settings bootstrap.")
        }
        XCTAssertEqual(app.paths.home.standardizedFileURL, fixture.home.standardizedFileURL)
        XCTAssertNil(fixture.model.manager)
        XCTAssertNil(fixture.model.remoteManager)
        NSApp.activate(ignoringOtherApps: true)
        fixture.window.makeKeyAndOrderFront(nil); fixture.window.orderFrontRegardless()
        fixture.hosting.layoutSubtreeIfNeeded()
    }

    private func nativeDraftViews(_ root: NSView) -> [NSView] {
        var pending: [(NSView, Int)] = [(root, 0)]
        var result: [NSView] = []
        while let (view, depth) = pending.popLast() {
            guard result.count < 2_048, depth <= 48,
                  view.subviews.count <= 2_048 - result.count - pending.count - 1 else {
                XCTFail("The production draft fixture exceeded its 2048-view/48-level bound.")
                return []
            }
            result.append(view)
            pending.append(contentsOf: view.subviews.map { ($0, depth + 1) })
        }
        return result
    }

    private func nativeDraftStage(_ stage: String) {
        nativeDraftCurrentStage = stage
    }

    private func nativeDraftRecordViewport(_ fixture: NativeWorkspaceDraftFixture, name: String) throws {
        fixture.hosting.layoutSubtreeIfNeeded()
        let views = nativeDraftViews(fixture.hosting)
        let scrolls = views.compactMap { $0 as? NSScrollView }
        guard scrolls.count <= 64 else {
            throw WorkspaceCanvasFixtureFailure("The actual owned viewport exceeded its scroll-view observation bound.")
        }
        let rows: [[String: Any]] = scrolls.map { scroll in
            let document = scroll.documentView
            return [
                "type": String(describing: type(of: scroll)),
                "frame": NSStringFromRect(scroll.frame), "bounds": NSStringFromRect(scroll.bounds),
                "visible_rect": NSStringFromRect(scroll.visibleRect),
                "clip_bounds": NSStringFromRect(scroll.contentView.bounds),
                "document_frame": document.map { NSStringFromRect($0.frame) } ?? "<no-document>",
                "document_bounds": document.map { NSStringFromRect($0.bounds) } ?? "<no-document>",
                "document_visible_rect": document.map { NSStringFromRect($0.visibleRect) } ?? "<no-document>",
                "document_is_flipped": document?.isFlipped ?? false,
                "hidden_or_hidden_ancestor": scroll.isHiddenOrHasHiddenAncestor,
            ]
        }
        let fields = views.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        guard fields.count <= 64 else {
            throw WorkspaceCanvasFixtureFailure("The actual owned viewport exceeded its editable-field observation bound.")
        }
        let observation: [String: Any] = [
            "classification": "Diagnostic actual native viewport geometry and view cache only; no field-edit or compositor pass",
            "window": NSStringFromRect(fixture.window.frame),
            "content": NSStringFromRect(fixture.hosting.bounds),
            "window_key": fixture.window.isKeyWindow, "window_visible": fixture.window.isVisible,
            "settings_ready": fixture.model.hasLoadedInitialSettings,
            "scroll_views": rows,
            "editable_backing_fields": fields.map { field in [
                "type": String(describing: type(of: field)), "identifier": field.accessibilityIdentifier() ?? "",
                "label": field.accessibilityLabel() ?? "", "placeholder": field.placeholderString ?? "",
                "frame": NSStringFromRect(field.frame), "visible_rect": NSStringFromRect(field.visibleRect),
                "enabled": field.isEnabled, "hidden_or_hidden_ancestor": field.isHiddenOrHasHiddenAncestor,
            ] as [String: Any] },
        ]
        let json = try JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys])
        guard json.count <= 256 * 1_024 else {
            throw WorkspaceCanvasFixtureFailure("The native viewport diagnostic exceeded its JSON byte budget.")
        }
        let size = fixture.hosting.bounds.size
        guard size.width > 0, size.height > 0, size.width <= 1_440, size.height <= 960,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw WorkspaceCanvasFixtureFailure("The actual native viewport diagnostic exceeded its finite image geometry.")
        }
        bitmap.size = size
        fixture.hosting.cacheDisplay(in: fixture.hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        guard png.count <= 16 * 1_024 * 1_024 else {
            throw WorkspaceCanvasFixtureFailure("The actual native viewport cache exceeded its image byte budget.")
        }
        try directEvidence.save(json, name: name + "-viewport", extension: "json")
        try directEvidence.save(png, name: name + "-native-view-cache", extension: "png")
        if !directEvidence.isEnabled {
            let text = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
            text.name = name + "-viewport"; text.lifetime = .keepAlways; add(text)
            let image = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            image.name = name + "-native-view-cache"; image.lifetime = .keepAlways; add(image)
        }
    }

    private func nativeDraftField(in root: NSView, identifier: String, placeholder: String,
                                  expectedLabel: String? = nil) async throws -> NativeWorkspaceDraftField {
        do {
            return try await nativeDraftObserveField(in: root, identifier: identifier,
                placeholder: placeholder, expectedLabel: expectedLabel)
        } catch {
            await nativeDraftRetainLookupFailure(error, lookupKind: "field", root: root,
                identifier: identifier, placeholder: placeholder, expectedLabel: expectedLabel)
            throw error
        }
    }

    private func nativeDraftObserveField(in root: NSView, identifier: String, placeholder: String,
                                        expectedLabel: String?) async throws -> NativeWorkspaceDraftField {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var lastTextFields: [String] = []
        var recordedPostFormalBackingFields = false
        repeat {
            root.layoutSubtreeIfNeeded()
            let backingFields = nativeDraftViews(root).compactMap { $0 as? NSTextField }.filter {
                $0.isEditable && ($0.accessibilityIdentifier() == identifier
                    || $0.accessibilityLabel() == identifier
                    || (expectedLabel != nil && $0.accessibilityLabel() == expectedLabel)
                    || $0.placeholderString == placeholder)
            }
            guard backingFields.count <= 1 else {
                throw WorkspaceCanvasFixtureFailure("Duplicate actual native backing text field in the owned presentation.")
            }
            if let field = backingFields.first, field.isEnabled {
                nativeDraftStage("field.enabled-editable-appkit-backing-found")
                return NativeWorkspaceDraftField(node: try NativeWorkspaceDraftAccessibilityNode(field))
            }
            let nodes = try nativeDraftAccessibilityTree(root, deadline: deadline)
            let fields = nodes.filter { $0.role == .textField }
            if let expectedLabel, !recordedPostFormalBackingFields {
                recordedPostFormalBackingFields = true
                let actualFields = nativeDraftViews(root).compactMap { $0 as? NSTextField }.filter(\.isEditable)
                nativeDraftRetainMeasurement([
                    "classification": "Diagnostic native backing metadata after the original formal traversal, before any exported AX query; no return, edit or fallback",
                    "stage": nativeDraftCurrentStage, "expected_identifier": identifier,
                    "expected_label": expectedLabel, "actual_editable_field_count": actualFields.count,
                    "sample_limit": 64, "sample_truncated": actualFields.count > 64,
                    "actual_fields": actualFields.prefix(64).map { field in [
                        "type": String(String(reflecting: type(of: field)).prefix(256)),
                        "identifier": String((field.accessibilityIdentifier() ?? "").prefix(256)),
                        "label": String((field.accessibilityLabel() ?? "").prefix(256)),
                        "placeholder": String((field.placeholderString ?? "").prefix(256)),
                        "value": String(field.stringValue.prefix(1_024)), "enabled": field.isEnabled,
                        "same_root_window": root.window != nil && field.window === root.window,
                        "actual_root_descendant": field.isDescendant(of: root),
                    ] as [String: Any] },
                ], name: "native-draft-post-formal-backing-fields")
            }
            let matches = fields.filter {
                $0.identifier == identifier || $0.label == identifier
                    || (expectedLabel != nil && $0.label == expectedLabel) || $0.placeholder == placeholder
            }
            guard matches.count <= 1 else {
                throw WorkspaceCanvasFixtureFailure("Duplicate actual native semantic text field in the owned presentation.")
            }
            if let expectedLabel,
               let field = try nativeDraftBackingFieldAfterMetadata(in: root, identifier: identifier,
                   placeholder: placeholder, expectedLabel: expectedLabel) {
                nativeDraftStage("field.real-appkit-control-found-after-formal-traversal")
                return NativeWorkspaceDraftField(node: try NativeWorkspaceDraftAccessibilityNode(field))
            }
            if let node = matches.first, node.enabled == true, node.canSetValue, node.value is String {
                if let expectedLabel {
                    if let field = try nativeDraftBackingFieldAfterMetadata(in: root, identifier: identifier,
                        placeholder: placeholder, expectedLabel: expectedLabel) {
                        nativeDraftStage("field.real-appkit-control-found-after-semantic-metadata")
                        return NativeWorkspaceDraftField(node: try NativeWorkspaceDraftAccessibilityNode(field))
                    }
                } else {
                    nativeDraftStage("field.enabled-editable-semantic-control-found")
                    return NativeWorkspaceDraftField(node: node)
                }
            }
            if let fixture = draftFixture {
                let owner = NativeWorkspaceDraftExportedFieldOwner(fixture: fixture, root: root, identifier: identifier)
                if let (element, context) = try owner.resolve(deadline: deadline) {
                    if let expectedLabel {
                        _ = try NativeWorkspaceDraftAccessibilityNode(exported: element, context: context)
                        if let field = try nativeDraftBackingFieldAfterMetadata(in: root, identifier: identifier,
                            placeholder: placeholder, expectedLabel: expectedLabel) {
                            nativeDraftStage("field.real-appkit-control-found-after-exported-metadata")
                            return NativeWorkspaceDraftField(node: try NativeWorkspaceDraftAccessibilityNode(field))
                        }
                    } else {
                        nativeDraftStage("field.enabled-editable-exported-control-found")
                        return NativeWorkspaceDraftField(node: try NativeWorkspaceDraftAccessibilityNode(exported: element, context: context),
                                                         exportedOwner: owner)
                    }
                }
            }
            lastTextFields = fields.prefix(24).map {
                "id=\($0.identifier ?? "") label=\($0.label ?? "") placeholder=\($0.placeholder ?? "") enabled=\(String(describing: $0.enabled)) setter=\($0.canSetValue) type=\(String(describing: type(of: $0.object)))"
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        nativeDraftRetainMeasurement([
            "classification": "Failure evidence: bounded original native text-field observations; original field failure remains unchanged",
            "stage": nativeDraftCurrentStage,
            "sample_limit": 24, "sample_string_character_limit": 1_024,
            "last_native_text_fields": lastTextFields.prefix(24).map { String($0.prefix(1_024)) },
        ], name: "native-draft-original-field-observations")
        nativeDraftMeasureExportedFieldFailure(root, identifier: identifier, placeholder: placeholder)
        throw WorkspaceCanvasFixtureFailure("The production field did not expose one enabled editable native semantic control.")
    }

    private func nativeDraftRetainLookupFailure(_ error: any Error, lookupKind: String, root: NSView,
        identifier: String, placeholder: String?, expectedLabel: String?,
        lookupProgress: [String: Any]? = nil) async {
        let original = error as NSError
        let started = ProcessInfo.processInfo.systemUptime
        let diagnosticDeadline = started + 0.25
        var rows: [[String: Any]] = []
        var pending: [(NSView, Int)] = [(root, 0)]
        var visited = 0
        var stoppedAtBound = false
        while let (view, depth) = pending.popLast() {
            guard ProcessInfo.processInfo.systemUptime < diagnosticDeadline,
                  visited < 2_048, depth <= 48,
                  view.subviews.count <= 2_048 - visited - pending.count - 1 else {
                stoppedAtBound = true; break
            }
            visited += 1
            if let field = view as? NSTextField, field.isEditable {
                guard rows.count < 64 else { stoppedAtBound = true; break }
                rows.append([
                    "type": String(String(reflecting: type(of: field)).prefix(256)),
                    "identifier": String((field.accessibilityIdentifier() ?? "").prefix(256)),
                    "label": String((field.accessibilityLabel() ?? "").prefix(256)),
                    "placeholder": String((field.placeholderString ?? "").prefix(256)),
                    "value": String(field.stringValue.prefix(1_024)),
                    "frame": NSStringFromRect(field.frame), "bounds": NSStringFromRect(field.bounds),
                    "enabled": field.isEnabled, "editable": field.isEditable,
                    "hidden_or_hidden_ancestor": field.isHiddenOrHasHiddenAncestor,
                    "same_root_window": root.window != nil && field.window === root.window,
                    "actual_root_descendant": field.isDescendant(of: root),
                ])
            }
            pending.append(contentsOf: view.subviews.map { ($0, depth + 1) })
        }
        var report: [String: Any] = [
            "classification": "Diagnostic only: original async lookup error; no edit, retry, or fallback",
            "original_lookup_kind": String(lookupKind.prefix(256)),
            "original_identifier_walk_progress": lookupProgress.map { $0 as Any } ?? NSNull(),
            "original_error_type": String(String(reflecting: type(of: error)).prefix(1_024)),
            "original_error_description": String(String(describing: error).prefix(4_096)),
            "original_NSError_domain": String(original.domain.prefix(256)),
            "original_NSError_code": original.code,
            "original_NSError_localized_description": String(original.localizedDescription.prefix(4_096)),
            "expected_identifier": String(identifier.prefix(256)),
            "expected_placeholder": placeholder.map { String($0.prefix(256)) as Any } ?? NSNull(),
            "expected_label": expectedLabel.map { String($0.prefix(256)) as Any } ?? NSNull(),
            "stage": String(nativeDraftCurrentStage.prefix(256)), "task_cancelled": Task.isCancelled,
            "root_type": String(String(reflecting: type(of: root)).prefix(256)),
            "root_frame": NSStringFromRect(root.frame), "root_bounds": NSStringFromRect(root.bounds),
            "root_hidden_or_hidden_ancestor": root.isHiddenOrHasHiddenAncestor,
            "root_window_title": root.window.map { String($0.title.prefix(256)) as Any } ?? NSNull(),
            "app_active": NSApp.isActive, "native_views_visited": visited,
            "native_view_limit": 2_048, "native_depth_limit": 48, "editable_field_limit": 64,
            "native_measurement_deadline_seconds": 0.25, "native_measurement_stopped_at_bound": stoppedAtBound,
            "native_measurement_elapsed_seconds": ProcessInfo.processInfo.systemUptime - started,
            "actual_editable_backing_fields": rows,
        ]
        if let fixture = draftFixture {
            report["root_window_is_owned"] = root.window === fixture.window
            report["owned_content_is_hosting"] = fixture.window.contentView === fixture.hosting
            report["owned_hosting_window_identity"] = fixture.hosting.window === fixture.window
            report["root_is_hosting_or_descendant"] = root === fixture.hosting || root.isDescendant(of: fixture.hosting)
            report["window_visible"] = fixture.window.isVisible
            report["window_key"] = fixture.window.isKeyWindow
            report["bootstrap_settled"] = !fixture.model.isBootstrapping
            report["settings_ready"] = fixture.model.hasLoadedInitialSettings
            report["bootstrap_creations"] = fixture.recorder.creations
            if let panel = root.superview as? NativeWorkspacePanelHost {
                report["root_parent_panel_id"] = String(panel.panelID.prefix(256))
                report["root_parent_panel_hosting_identity"] = panel.hostingView === root
                report["root_parent_panel_owned_window"] = panel.window === fixture.window
            }
            let observations = await fixture.client.observations()
            report["client_readonly_observations"] = ["snapshots": observations.snapshots,
                "repository_writes": observations.repositoryWrites, "other_mutations": observations.otherMutations]
        }
        nativeDraftRetainMeasurement(report, name: "native-workspace-original-" + lookupKind + "-lookup-error")
    }

    private func nativeDraftBackingFieldAfterMetadata(in root: NSView, identifier: String,
        placeholder: String, expectedLabel: String) throws -> NSTextField? {
        let matches = nativeDraftViews(root).compactMap { $0 as? NSTextField }.filter {
            $0.isEditable && ($0.accessibilityIdentifier() == identifier
                || $0.accessibilityLabel() == identifier || $0.accessibilityLabel() == expectedLabel
                || $0.placeholderString == placeholder)
        }
        guard matches.count <= 1 else {
            throw WorkspaceCanvasFixtureFailure("Duplicate actual native backing field after public control metadata was read.")
        }
        guard let field = matches.first, field.isEnabled, let window = root.window,
              field.window === window, field.isDescendant(of: root) else { return nil }
        return field
    }

    private func nativeDraftRetainMeasurement(_ report: [String: Any], name: String) {
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            guard data.count <= 256 * 1_024 else {
                throw WorkspaceCanvasFixtureFailure("The failure measurement exceeded its 256 KiB JSON bound.")
            }
            do { try directEvidence.save(data, name: name, extension: "json") }
            catch {
                let failure = XCTAttachment(string: String("Measurement file save failed: \(error)".prefix(4_096)))
                failure.name = name + "-file-save-error"; failure.lifetime = .keepAlways; add(failure)
            }
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        } catch {
            let attachment = XCTAttachment(string: String("Failure measurement retention error: \(error)".prefix(4_096)))
            attachment.name = name + "-retention-error"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    private func nativeDraftMeasureExportedFieldFailure(_ root: NSView, identifier: String, placeholder: String) {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 3
        var rows: [[String: Any]] = []
        var visited = 0
        var matches = 0
        var report: [String: Any] = [
            "classification": "Diagnostic only: read-only public own-window AX field identity/enabled/writable-value measurement after original native field lookup failed; no edit or fallback",
            "expected_identifier": identifier, "expected_placeholder": placeholder,
            "stage": nativeDraftCurrentStage, "root_type": String(String(reflecting: type(of: root)).prefix(256)),
            "root_frame": NSStringFromRect(root.frame), "root_bounds": NSStringFromRect(root.bounds),
            "root_hidden_or_hidden_ancestor": root.isHiddenOrHasHiddenAncestor,
            "query_deadline_seconds": 3, "node_limit": 2_048, "depth_limit": 48, "field_limit": 64,
        ]
        do {
            guard let fixture = draftFixture, root.window === fixture.window else {
                throw WorkspaceCanvasFixtureFailure("The failed field lookup root is not in the exact owned fixture window.")
            }
            report["window_title"] = fixture.window.title
            report["window_visible"] = fixture.window.isVisible
            report["window_key"] = fixture.window.isKeyWindow
            report["app_active"] = NSApp.isActive
            report["settings_ready"] = fixture.model.hasLoadedInitialSettings
            guard let context = try NativeWorkspaceDraftExportedAXContext(fixture: fixture, deadline: deadline) else {
                throw WorkspaceCanvasFixtureFailure("The owned fixture window is absent from the actual exported AX window list.")
            }
            var pending: [(AXUIElement, Int)] = [(context.windowElement, 0)]
            var seen: [AXUIElement] = []
            while let (element, depth) = pending.popLast() {
                try context.requireOwner()
                guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
                guard seen.count < 2_048, depth <= 48 else {
                    throw WorkspaceCanvasFixtureFailure("The field measurement exceeded its actual AX node/depth bound.")
                }
                seen.append(element); visited = seen.count
                let role = try NativeWorkspaceDraftAXQuery.attribute(element, kAXRoleAttribute, deadline: deadline) as? String
                let actualID = try NativeWorkspaceDraftAXQuery.attribute(element, kAXIdentifierAttribute, deadline: deadline) as? String
                if role == kAXTextFieldRole || actualID == identifier {
                    guard rows.count < 64 else { throw WorkspaceCanvasFixtureFailure("The actual field sample exceeded 64 nodes.") }
                    try context.requireOwnedAncestor(element)
                    let label = try NativeWorkspaceDraftAXQuery.attribute(element, kAXDescriptionAttribute, deadline: deadline) as? String
                    let actualPlaceholder = try NativeWorkspaceDraftAXQuery.attribute(element, kAXPlaceholderValueAttribute, deadline: deadline) as? String
                    let enabled = try NativeWorkspaceDraftAXQuery.attribute(element, kAXEnabledAttribute, deadline: deadline)
                    let value = try NativeWorkspaceDraftAXQuery.attribute(element, kAXValueAttribute, deadline: deadline)
                    try NativeWorkspaceDraftAXQuery.prepare(element, deadline: deadline)
                    var settable: DarwinBoolean = false
                    let status = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw WorkspaceCanvasFixtureFailure("The actual AX value-settable measurement exceeded its deadline.")
                    }
                    let identityMatches = actualID == identifier || label == identifier || actualPlaceholder == placeholder
                    if identityMatches { matches += 1 }
                    rows.append([
                        "identifier": actualID.map { String($0.prefix(256)) as Any } ?? NSNull(),
                        "role": role.map { $0 as Any } ?? NSNull(),
                        "label": label.map { String($0.prefix(256)) as Any } ?? NSNull(),
                        "placeholder": actualPlaceholder.map { String($0.prefix(256)) as Any } ?? NSNull(),
                        "enabled": (enabled as? Bool).map { $0 as Any } ?? NSNull(),
                        "enabled_actual_type": enabled.map { String(String(reflecting: type(of: $0)).prefix(256)) as Any } ?? NSNull(),
                        "value": (value as? String).map { String($0.prefix(1_024)) as Any } ?? NSNull(),
                        "value_actual_type": value.map { String(String(reflecting: type(of: $0)).prefix(256)) as Any } ?? NSNull(),
                        "identity_matches_expected": identityMatches, "owned_window_parent_verified": true,
                        "AXValue_settable_status": status.rawValue,
                        "AXValue_settable": status == .success ? settable.boolValue as Any : NSNull(),
                    ])
                }
                let children = try NativeWorkspaceDraftAXQuery.children(element, kAXChildrenAttribute,
                    limit: 2_048 - seen.count - pending.count, deadline: deadline)
                pending.append(contentsOf: children.map { ($0, depth + 1) })
            }
        } catch {
            report["diagnostic_error_type"] = String(String(reflecting: type(of: error)).prefix(1_024))
            report["diagnostic_error_description"] = String(String(describing: error).prefix(4_096))
        }
        report["visited_node_count"] = visited
        report["sampled_field_count"] = rows.count
        report["matching_field_count"] = matches
        report["actual_exported_fields"] = rows
        report["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
        nativeDraftRetainMeasurement(report, name: "native-draft-exported-field-failure")
    }

    private func editNativeDraftField(_ control: NativeWorkspaceDraftField, value: String, in window: NSWindow) throws {
        if let field = control.node.object as? NSTextField {
            nativeDraftStage("edit.appkit.focus.begin")
            guard field.isEnabled, field.isEditable, window.makeFirstResponder(field),
                  let editor = field.currentEditor() as? NSTextView else {
                throw WorkspaceCanvasFixtureFailure("The enabled production field did not begin real AppKit editing.")
            }
            nativeDraftStage("edit.appkit.insert.begin")
            editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            nativeDraftStage("edit.appkit.endEditing.begin")
            window.endEditing(for: field)
            nativeDraftStage("edit.appkit.endEditing.returned")
            guard window.makeFirstResponder(nil) else {
                throw WorkspaceCanvasFixtureFailure("The actual edited control refused to commit focus loss.")
            }
            nativeDraftStage("edit.appkit.focus-cleared")
        } else if let exportedOwner = control.exportedOwner {
            nativeDraftRetainMeasurement(exportedOwner.backingMeasurement(), name: "native-draft-own-field-before-AXSet")
            nativeDraftStage("edit.exported-own-window-value-setter.begin")
            try exportedOwner.setValue(value, in: window)
            nativeDraftStage("edit.exported-own-window-value-setter.returned")
            nativeDraftRetainMeasurement(exportedOwner.backingMeasurement(), name: "native-draft-own-field-after-AXSet")
        } else {
            guard control.node.role == .textField, control.node.enabled == true, control.node.canSetValue else {
                throw WorkspaceCanvasFixtureFailure("The actual production field is not enabled for native semantic editing.")
            }
            nativeDraftStage("edit.swiftui-native-semantic-setter.begin")
            try control.node.setValue(value)
            nativeDraftStage("edit.swiftui-native-semantic-setter.returned")
        }
    }

    private func nativeDraftDocument(_ fixture: NativeWorkspaceDraftFixture, panelID: String) async throws -> NativeWorkspaceDocumentView {
        try await waitUntil("The actual production workspace wrapper did not mount its native panel.") {
            fixture.hosting.layoutSubtreeIfNeeded()
            return self.nativeDraftViews(fixture.hosting).compactMap { $0 as? NativeWorkspaceDocumentView }
                .first?.panelHosts[panelID] != nil
        }
        return try XCTUnwrap(nativeDraftViews(fixture.hosting).compactMap { $0 as? NativeWorkspaceDocumentView }.first)
    }

    private func nativeDraftHide(_ panel: NativeWorkspacePanelHost) throws {
        let button = try XCTUnwrap(nativeDraftViews(panel).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "workspace-hide-" + panel.panelID })
        XCTAssertTrue(button.isEnabled)
        button.performClick(nil)
    }

    private func nativeDraftLayout(viewID: String) -> NativeWorkspaceLayout {
        let descriptors = NativeWorkspaceCatalog.panelsByView[viewID] ?? []
        let shown: Set<String> = viewID == "projects"
            ? ["projects-summary", "projects-identity", "projects-repository"]
            : ["manager-navigation", "manager-dashboard-settings"]
        let panels = descriptors.map { descriptor in
            var frame = descriptor.defaultFrame
            if descriptor.id == "projects-summary" { frame = .init(x: 340, y: 20, width: 980, height: 180) }
            if descriptor.id == "projects-repository" { frame = .init(x: 340, y: 220, width: 980, height: 300) }
            if descriptor.id == "projects-identity" { frame = .init(x: 20, y: 20, width: 300, height: 160) }
            if descriptor.id == "manager-dashboard-settings" { frame = .init(x: 340, y: 20, width: 920, height: 420) }
            return NativeWorkspacePanelPlacement(id: descriptor.id, frame: frame, isVisible: shown.contains(descriptor.id))
        }
        return NativeWorkspaceLayout(id: UUID(), viewID: viewID, name: "Custom Native Draft",
                                    canvas: .init(width: 1_460, height: 3_600), panels: panels)
    }

    private func nativeDraftRequireProjectIdentity(_ fixture: NativeWorkspaceDraftFixture) async throws {
        let identity = try await nativeDraftAXElement("project-canonical-root", in: fixture)
        XCTAssertTrue(identity.value as? String == NativeWorkspaceDraftClient.projectRoot
            || identity.title == NativeWorkspaceDraftClient.projectRoot)
        let generation = try await nativeDraftAXElement("project-generation", in: fixture)
        XCTAssertTrue(generation.value as? String == "Generation 4"
            || generation.title == "Generation 4")
    }

    private func nativeDraftRequireManagerTitle(_ title: String, in fixture: NativeWorkspaceDraftFixture) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var lastNodes: [[String: Any]] = []
        var lastNodeCount = 0
        do {
            repeat {
                nativeDraftStage("manager.title.lookup.begin." + title)
                let header = try await nativeDraftAXElement("detail-manager", in: fixture, deadline: deadline)
                nativeDraftStage("manager.title.subtree.begin." + title)
                let nodes = try nativeDraftExportedAXTree(header, deadline: deadline, limit: 128)
                lastNodeCount = nodes.count
                lastNodes = nodes.prefix(32).map { ["identifier": String(($0.identifier ?? "").prefix(256)),
                    "role": String(($0.role?.rawValue ?? "").prefix(128)), "title": String(($0.title ?? "").prefix(512)),
                    "value": String(String(describing: $0.value).prefix(512))] }
                nativeDraftStage("manager.title.subtree.returned." + title)
                if nodes.contains(where: { $0.value as? String == title || $0.title == title }) { return }
                nativeDraftStage("manager.title.sleep.begin." + title)
                try await Task.sleep(for: .milliseconds(20))
                nativeDraftStage("manager.title.sleep.returned." + title)
            } while ProcessInfo.processInfo.systemUptime < deadline
            throw WorkspaceCanvasFixtureFailure("The actual Manager section did not publish its selected heading.")
        } catch {
            let native = error as NSError
            nativeDraftRetainMeasurement([
                "classification": "Diagnostic only: original Manager heading failure and precise observer stage; same error is rethrown",
                "expected_title": title, "stage": nativeDraftCurrentStage,
                "error_type": String(String(reflecting: type(of: error)).prefix(1_024)),
                "error_description": String(String(describing: error).prefix(4_096)),
                "NSError_domain": String(native.domain.prefix(1_024)), "NSError_code": native.code,
                "task_cancelled": Task.isCancelled, "subtree_node_count": lastNodeCount,
                "subtree_sample_limit": 32, "subtree_sample_truncated": lastNodeCount > 32,
                "last_subtree_nodes": lastNodes, "window_visible": fixture.window.isVisible,
                "window_key": fixture.window.isKeyWindow, "app_active": NSApp.isActive,
                "exact_host_owner": fixture.window.contentView === fixture.hosting && fixture.hosting.window === fixture.window,
            ], name: "native-draft-manager-heading-error")
            throw error
        }
    }

    private func nativeDraftPress(_ identifier: String, in fixture: NativeWorkspaceDraftFixture) async throws {
        nativeDraftStage("action." + identifier + ".lookup.begin")
        let element = try await nativeDraftAXElement(identifier, in: fixture)
        nativeDraftStage("action." + identifier + ".lookup.returned")
        nativeDraftStage("action." + identifier + ".public-metadata.begin")
        let metadata = try element.actionForensics()
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        guard data.count <= 16 * 1_024 else {
            throw WorkspaceCanvasFixtureFailure("The actual public action metadata exceeded its byte bound.")
        }
        nativeDraftRetainMeasurement([
            "classification": "Actual public own-window action metadata before the original checked press; outcome remains subject to the unchanged action result and assertions",
            "identifier": identifier, "stage": nativeDraftCurrentStage, "actual_action_metadata": metadata,
        ], name: "native-draft-action-" + identifier)
        nativeDraftStage("action." + identifier + ".public-metadata.returned")
        nativeDraftStage("action." + identifier + ".press.begin")
        try element.press()
        nativeDraftStage("action." + identifier + ".press.returned")
        try await Task.sleep(for: .milliseconds(40))
    }

    private func nativeDraftAXElement(_ identifier: String, in fixture: NativeWorkspaceDraftFixture,
                                      deadline suppliedDeadline: TimeInterval? = nil) async throws -> NativeWorkspaceDraftAccessibilityNode {
        var progress: [String: Any] = [:]
        do {
            return try await nativeDraftObserveAXElement(identifier, in: fixture, deadline: suppliedDeadline,
                progress: &progress)
        } catch {
            await nativeDraftRetainLookupFailure(error, lookupKind: "AX-element", root: fixture.hosting,
                identifier: identifier, placeholder: nil, expectedLabel: nil, lookupProgress: progress)
            throw error
        }
    }

    private func nativeDraftObserveAXElement(_ identifier: String, in fixture: NativeWorkspaceDraftFixture,
                                             deadline suppliedDeadline: TimeInterval?,
                                             progress: inout [String: Any]) async throws -> NativeWorkspaceDraftAccessibilityNode {
        let deadline = suppliedDeadline ?? ProcessInfo.processInfo.systemUptime + 3
        var attempt = 0
        repeat {
            attempt += 1
            progress = ["operation": "scope-construction", "attempt": attempt]
            fixture.hosting.layoutSubtreeIfNeeded()
            if let context = try NativeWorkspaceDraftExportedAXContext(fixture: fixture, deadline: deadline) {
                progress["operation"] = "root-ancestor-validation"
                try context.requireOwnedAncestor(context.windowElement)
                var pending: [(AXUIElement, Int, Int?, Int?, String?, [String], AXUIElement?)] = [
                    (context.windowElement, 0, nil, nil, nil, [], nil),
                ]
                var seen: [AXUIElement] = []
                var match: AXUIElement?
                var matchedProgress: [String: Any]?
                while let (element, depth, parentIndex, childOrdinal, parentIdentifier, namedAncestors, discoveryParent) = pending.popLast() {
                    progress = [
                        "classification": "Previously observed AXChildren discovery path; no fresh AXParent, role or title query",
                        "operation": "owner-validation", "attempt": attempt,
                        "visit_index": seen.count, "depth": depth, "pending_node_count": pending.count,
                        "same_reference_as_owned_window": CFEqual(element, context.windowElement),
                        "requested_match_already_discovered": match != nil,
                        "discovery_parent_visit_index": parentIndex.map { $0 as Any } ?? NSNull(),
                        "discovery_child_ordinal": childOrdinal.map { $0 as Any } ?? NSNull(),
                        "successfully_read_parent_identifier": parentIdentifier.map { $0 as Any } ?? NSNull(),
                        "recent_successfully_read_named_ancestors": namedAncestors,
                        "named_ancestor_limit": 8, "identifier_character_limit": 256,
                    ]
                    try context.requireOwner()
                    guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
                    guard seen.count < 2_048, depth <= 48 else {
                        throw WorkspaceCanvasFixtureFailure("The actual exported identifier traversal exceeded its 2048-node/48-level bound.")
                    }
                    seen.append(element)
                    progress["operation"] = "identifier-read"
                    let rawIdentifier: Any?
                    do {
                        rawIdentifier = try NativeWorkspaceDraftAXQuery.attribute(element, kAXIdentifierAttribute,
                            deadline: deadline)
                    } catch {
                        progress["post_failure_discovery_diagnostic"] = await NativeWorkspaceDraftAXQuery.discoveryFailureDiagnostic(
                            root: context.windowElement, parent: discoveryParent, child: element,
                            childOrdinal: childOrdinal, deadline: deadline)
                        throw error
                    }
                    progress["operation"] = "identifier-type-validation"
                    guard rawIdentifier == nil || (rawIdentifier as? String).map({ $0.utf8.count <= 16 * 1_024 }) == true else {
                        throw WorkspaceCanvasFixtureFailure("The actual exported identifier is not a bounded string.")
                    }
                    let observedIdentifier = (rawIdentifier as? String).map { String($0.prefix(256)) }
                    progress["current_successfully_read_identifier"] = observedIdentifier.map { $0 as Any } ?? NSNull()
                    if rawIdentifier as? String == identifier {
                        guard match == nil else { throw WorkspaceCanvasFixtureFailure("Duplicate actual semantic control identifier.") }
                        match = element
                        matchedProgress = progress
                    }
                    progress["requested_match_already_discovered"] = match != nil
                    progress["operation"] = "children-read"
                    let children = try NativeWorkspaceDraftAXQuery.children(element, kAXChildrenAttribute,
                        limit: 2_048 - seen.count - pending.count, deadline: deadline)
                    var nextAncestors = namedAncestors
                    if let observedIdentifier, !observedIdentifier.isEmpty { nextAncestors.append(observedIdentifier) }
                    nextAncestors = Array(nextAncestors.suffix(8))
                    pending.append(contentsOf: children.enumerated().map {
                        ($0.element, depth + 1, seen.count - 1, $0.offset, observedIdentifier, nextAncestors, element)
                    })
                }
                if let match {
                    progress = matchedProgress ?? [:]
                    progress["complete_identifier_walk_node_count"] = seen.count
                    progress["pending_node_count"] = 0
                    progress["requested_match_already_discovered"] = true
                    progress["operation"] = "target-ancestor-validation"
                    try context.requireOwnedAncestor(match)
                    progress["operation"] = "target-full-snapshot"
                    let node = try NativeWorkspaceDraftAccessibilityNode(exported: match, context: context)
                    progress["operation"] = "target-identifier-validation"
                    guard node.identifier == identifier else {
                        throw WorkspaceCanvasFixtureFailure("The matched exported identifier changed before its full target snapshot.")
                    }
                    return node
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw WorkspaceCanvasFixtureFailure("The actual owned window did not expose the required native semantic identifier.")
    }

    private func nativeDraftExportedAXTree(_ root: NativeWorkspaceDraftAccessibilityNode,
                                           deadline: TimeInterval, limit: Int = 2_048) throws -> [NativeWorkspaceDraftAccessibilityNode] {
        guard let element = root.exportedAX, let context = root.exportedContext,
              context.deadline == deadline, 1...2_048 ~= limit else {
            throw WorkspaceCanvasFixtureFailure("The semantic root is not the current bounded own-window AX observation.")
        }
        try context.requireOwnedAncestor(element)
        var pending: [(AXUIElement, Int)] = [(element, 0)]
        var seen: [AXUIElement] = []
        var nodes: [NativeWorkspaceDraftAccessibilityNode] = []
        while let (element, depth) = pending.popLast() {
            try context.requireOwner()
            guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
            guard nodes.count < limit, depth <= 48 else {
                throw WorkspaceCanvasFixtureFailure("The actual exported AX tree exceeded its 2048-node/48-level bound.")
            }
            seen.append(element)
            nodes.append(try NativeWorkspaceDraftAccessibilityNode(exported: element, context: context))
            let children = try NativeWorkspaceDraftAXQuery.children(element, kAXChildrenAttribute,
                limit: limit - nodes.count - pending.count, deadline: deadline)
            pending.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nodes
    }

    private func nativeDraftAccessibilityTree(_ root: AnyObject, deadline: TimeInterval,
                                               limit: Int = 2_048) throws -> [NativeWorkspaceDraftAccessibilityNode] {
        var pending: [(NativeWorkspaceDraftAccessibilityNode, Int)] = [(try NativeWorkspaceDraftAccessibilityNode(root), 0)]
        var seen = Set<ObjectIdentifier>()
        var nodes: [NativeWorkspaceDraftAccessibilityNode] = []
        while !pending.isEmpty {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw WorkspaceCanvasFixtureFailure("The native semantic observation exceeded its finite deadline.")
            }
            let (node, depth) = pending.removeLast()
            guard seen.insert(ObjectIdentifier(node.object)).inserted else { continue }
            guard nodes.count < limit, depth <= 48 else {
                throw WorkspaceCanvasFixtureFailure("The actual native semantic tree exceeded its node/depth bound.")
            }
            nodes.append(node)
            let children = try node.children()
            guard children.count <= limit - nodes.count - pending.count else {
                throw WorkspaceCanvasFixtureFailure("The actual native semantic child list exceeded its finite bound.")
            }
            for child in children {
                pending.append((try NativeWorkspaceDraftAccessibilityNode(child as AnyObject), depth + 1))
            }
        }
        return nodes
    }

    func testHeaderPointerMoveCommitsOnlyAtMouseUpAndKeepsIdentityDuringReorder() throws {
        let document = mountDocument()
        var commits: [NativeWorkspaceFrame] = []
        var fronts = 0
        var layout = workspaceLayout(name: "Move")
        func apply() {
            document.apply(layout: layout, descriptors: workspaceDescriptors,
                content: { _, _ in AnyView(Text("Panel")) },
                commitFrame: { _, value in commits.append(value) }, hidePanel: { _ in },
                bringToFront: { _ in fronts += 1 })
            document.layoutSubtreeIfNeeded()
        }
        apply()
        let panel = try XCTUnwrap(document.panelHosts["alpha"])
        let hosting = panel.hostingView
        let handle = try gestureHandle("workspace-move-alpha", in: panel)
        let start = NSPoint(x: 110, y: 130)
        handle.mouseDown(with: try pointer(.leftMouseDown, at: start, in: document))
        handle.mouseDragged(with: try pointer(.leftMouseDragged, at: NSPoint(x: 185, y: 170), in: document))
        XCTAssertTrue(panel.isManipulating)
        XCTAssertTrue(commits.isEmpty)
        XCTAssertEqual(fronts, 1)
        layout.panels.reverse()
        apply()
        XCTAssertTrue(panel.isManipulating, "A same-layout stacking update must keep the gesture.")
        XCTAssertTrue(document.panelHosts["alpha"] === panel)
        XCTAssertTrue(panel.hostingView === hosting)
        handle.mouseUp(with: try pointer(.leftMouseUp, at: NSPoint(x: 185, y: 170), in: document))
        XCTAssertEqual(commits, [.init(x: 175, y: 160, width: 400, height: 240)])
        XCTAssertFalse(panel.isManipulating)

        try drag(handle, in: document, from: NSPoint(x: 185, y: 170), to: NSPoint(x: 5_000, y: 5_000))
        XCTAssertEqual(commits.last, .init(x: 800, y: 560, width: 400, height: 240))
        try drag(handle, in: document, from: NSPoint(x: 810, y: 570), to: NSPoint(x: -5_000, y: -5_000))
        XCTAssertEqual(commits.last, .init(x: 0, y: 0, width: 400, height: 240))
        XCTAssertEqual(commits.count, 3)
    }

    func testResizePointerHonorsDescriptorAndRemainingCanvasBounds() throws {
        let document = mountDocument()
        var commits: [NativeWorkspaceFrame] = []
        document.apply(layout: workspaceLayout(name: "Resize"), descriptors: workspaceDescriptors,
            content: { _, _ in AnyView(Text("Panel")) },
            commitFrame: { _, value in commits.append(value) }, hidePanel: { _ in }, bringToFront: { _ in })
        document.layoutSubtreeIfNeeded()
        let panel = try XCTUnwrap(document.panelHosts["alpha"])
        let handle = try gestureHandle("workspace-resize-alpha", in: panel)
        handle.mouseDown(with: try pointer(.leftMouseDown, at: NSPoint(x: 490, y: 350), in: document))
        handle.mouseDragged(with: try pointer(.leftMouseDragged, at: NSPoint(x: -500, y: -500), in: document))
        XCTAssertTrue(commits.isEmpty)
        handle.mouseUp(with: try pointer(.leftMouseUp, at: NSPoint(x: -500, y: -500), in: document))
        XCTAssertEqual(commits.last, .init(x: 100, y: 120, width: 280, height: 160))
        panel.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.hostingView.frame.size, NSSize(width: 278, height: 111))
        XCTAssertEqual(handle.frame.origin, NSPoint(x: 258, y: 142))
        try drag(handle, in: document, from: NSPoint(x: 370, y: 270), to: NSPoint(x: 5_000, y: 5_000))
        XCTAssertEqual(commits.last, .init(x: 100, y: 120, width: 960, height: 640))
        panel.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.hostingView.frame.size, NSSize(width: 958, height: 591))
        XCTAssertEqual(handle.frame.origin, NSPoint(x: 938, y: 622))

        panel.frame = NSRect(x: 880, y: 560, width: 300, height: 180)
        panel.layoutSubtreeIfNeeded()
        try drag(handle, in: document, from: NSPoint(x: 1_170, y: 730), to: NSPoint(x: 5_000, y: 5_000))
        XCTAssertEqual(commits.last, .init(x: 880, y: 560, width: 320, height: 240))
        XCTAssertEqual(commits.count, 3)
    }

    func testKeyboardAlternativesCommitAndEscapeCancelsPointerEdit() throws {
        let document = mountDocument()
        var commits: [NativeWorkspaceFrame] = []
        document.apply(layout: workspaceLayout(name: "Keyboard"), descriptors: workspaceDescriptors,
            content: { _, _ in AnyView(Text("Panel")) },
            commitFrame: { _, value in commits.append(value) }, hidePanel: { _ in }, bringToFront: { _ in })
        document.layoutSubtreeIfNeeded()
        let panel = try XCTUnwrap(document.panelHosts["alpha"])
        let move = try gestureHandle("workspace-move-alpha", in: panel)
        let resize = try gestureHandle("workspace-resize-alpha", in: panel)
        move.keyDown(with: try key(124, flags: [], window: try XCTUnwrap(window)))
        move.keyDown(with: try key(124, flags: [.option], window: try XCTUnwrap(window)))
        resize.keyDown(with: try key(125, flags: [], window: try XCTUnwrap(window)))
        XCTAssertEqual(commits, [.init(x: 110, y: 120, width: 400, height: 240),
                                 .init(x: 110, y: 120, width: 410, height: 240),
                                 .init(x: 110, y: 120, width: 410, height: 250)])
        let original = panel.frame
        move.mouseDown(with: try pointer(.leftMouseDown, at: NSPoint(x: 120, y: 130), in: document))
        move.mouseDragged(with: try pointer(.leftMouseDragged, at: NSPoint(x: 220, y: 230), in: document))
        XCTAssertNotEqual(panel.frame, original)
        XCTAssertTrue(try XCTUnwrap(window).makeFirstResponder(move))
        try XCTUnwrap(window).sendEvent(try key(53, flags: [], window: try XCTUnwrap(window)))
        move.mouseUp(with: try pointer(.leftMouseUp, at: NSPoint(x: 220, y: 230), in: document))
        XCTAssertEqual(panel.frame, original)
        XCTAssertEqual(commits.count, 3)
        XCTAssertFalse(panel.isManipulating)
    }

    func testQueuedPointerEventsMoveAndResizeThroughNativeHitTesting() async throws {
        let fixture = try await mountScope()
        let document = try await mountedDocument(fixture)
        let panel = try XCTUnwrap(document.panelHosts["alpha"])
        defer { panel.cancelGesture() }
        let hosting = panel.hostingView
        let root = try XCTUnwrap(fixture.window.contentView)
        let original = panel.frame
        func startPoint(_ handle: NSView) -> NSPoint {
            handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: document)
        }
        func requireHit(_ handle: NSView, at point: NSPoint) throws {
            fixture.hosting.layoutSubtreeIfNeeded()
            guard fixture.window.isVisible, fixture.window.isKeyWindow,
                  root === fixture.hosting, root.window === fixture.window,
                  handle.window === fixture.window, !handle.isHiddenOrHasHiddenAncestor,
                  root.hitTest(document.convert(point, to: root.superview)) === handle else {
                throw WorkspaceCanvasFixtureFailure("The real owned native window did not hit the literal gesture handle.")
            }
        }
        func post(_ type: NSEvent.EventType, at point: NSPoint) throws {
            let event = try pointer(type, at: point, in: document)
            guard event.windowNumber == fixture.window.windowNumber, event.window === fixture.window else {
                throw WorkspaceCanvasFixtureFailure("The queued pointer event escaped its owned native window.")
            }
            NSApp.postEvent(event, atStart: false)
        }
        let move = try gestureHandle("workspace-move-alpha", in: panel)
        let from = startPoint(move), to = NSPoint(x: from.x + 80, y: from.y + 40)
        try requireHit(move, at: from)
        try post(.leftMouseDown, at: from)
        try await waitUntil("The actual app event queue did not deliver the native move down.") { panel.isManipulating }
        let afterDown = fixture.preferences.collection
        let bytesAfterDown = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
        try post(.leftMouseDragged, at: to)
        let moved = NativeWorkspaceFrame(x: original.minX + 80, y: original.minY + 40,
            width: original.width, height: original.height)
        try await waitUntil("The queued move drag did not reach actual panel geometry.") { panel.frame == moved.nativeRect }
        XCTAssertEqual(fixture.preferences.collection, afterDown)
        XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), bytesAfterDown)
        try post(.leftMouseUp, at: to)
        try await waitUntil("The queued move up did not commit through the native workspace owner.") {
            !panel.isManipulating && fixture.preferences.activeLayout(for: "fixture")?
                .panels.first { $0.id == "alpha" }?.frame == moved
        }
        let resize = try gestureHandle("workspace-resize-alpha", in: panel)
        let resizeFrom = startPoint(resize), resizeTo = NSPoint(x: resizeFrom.x + 60, y: resizeFrom.y + 30)
        try requireHit(resize, at: resizeFrom)
        try post(.leftMouseDown, at: resizeFrom)
        try await waitUntil("The actual app event queue did not deliver native resize down.") { panel.isManipulating }
        let beforeResizeDrag = fixture.preferences.collection
        let resizeBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
        try post(.leftMouseDragged, at: resizeTo)
        let resized = NativeWorkspaceFrame(x: moved.x, y: moved.y,
            width: moved.width + 60, height: moved.height + 30)
        try await waitUntil("The queued resize drag did not reach actual panel geometry.") { panel.frame == resized.nativeRect }
        XCTAssertEqual(fixture.preferences.collection, beforeResizeDrag)
        XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), resizeBytes)
        try post(.leftMouseUp, at: resizeTo)
        try await waitUntil("The queued resize up did not persist the native frame.") {
            !panel.isManipulating && fixture.preferences.activeLayout(for: "fixture")?
                .panels.first { $0.id == "alpha" }?.frame == resized
        }
        XCTAssertTrue(document.panelHosts["alpha"] === panel)
        XCTAssertTrue(panel.hostingView === hosting)
        XCTAssertEqual(panel.frame, resized.nativeRect)
        // Own-window queued native events; this does not inject desktop input.
    }

    func testNativeMoveResizeAndHideRestoreFromFreshOwnerWithoutChangingAnotherView() async throws {
        continueAfterFailure = true
        let started = ProcessInfo.processInfo.systemUptime
        var stage = "not-started"
        var lastWorkStage = "not-started"
        var stages: [[String: Any]] = []
        var stageOverflow = false
        func recordStage(_ value: String) {
            stage = value
            if !value.hasPrefix("fixture-suite.cleanup.") { lastWorkStage = value }
            guard stages.count < 64, value.utf8.count <= 256 else {
                stageOverflow = true
                XCTFail("The round-trip stage measurement exceeded its finite bound.")
                return
            }
            stages.append(["stage": value, "elapsed_s": ProcessInfo.processInfo.systemUptime - started])
        }
        defer {
            nativeDraftRetainMeasurement([
                "classification": "Native round-trip test boundary observations; failure cause remains unqualified",
                "last_stage": stage, "last_work_stage": lastWorkStage,
                "stages": stages, "stage_count": stages.count,
                "stage_overflow": stageOverflow,
            ], name: "workspace-native-roundtrip-stages")
        }
        let registeredViewIDs: Set<String> = ["fixture", "fixture.other"]
        recordStage("original.fixture.create.begin")
        let original = try WorkspaceScopeFixture(registeredViewIDs: registeredViewIDs)
        recordStage("original.fixture.create.returned")
        scopeFixture = original
        defer {
            recordStage("fixture-suite.cleanup.begin")
            original.defaults.removePersistentDomain(forName: original.suite)
            recordStage("fixture-suite.cleanup.returned")
        }
        recordStage("original.expose.begin")
        try await exposeScope(original)
        recordStage("original.expose.returned")
        let document = try await mountedDocument(original)
        recordStage("original.canvas.mounted")
        let alpha = try XCTUnwrap(document.panelHosts["alpha"])
        let beta = try XCTUnwrap(document.panelHosts["beta"])
        let originalAlphaHost = alpha.hostingView
        let secondarySeed = workspaceLayout(name: "A", alternate: true)
        let secondary = NativeWorkspaceLayout(id: secondarySeed.id, viewID: "fixture.other", name: "A",
            canvas: secondarySeed.canvas, panels: secondarySeed.panels)
        recordStage("secondary.save.begin")
        try original.preferences.save(secondary)
        recordStage("secondary.save.returned")
        let independentSelection = original.preferences.activeLayout(for: "fixture.other")
        XCTAssertEqual(independentSelection, secondary)

        recordStage("move.lookup.begin")
        let move = try gestureHandle("workspace-move-alpha", in: alpha)
        recordStage("move.lookup.returned")
        recordStage("move.down.begin")
        move.mouseDown(with: try pointer(.leftMouseDown, at: NSPoint(x: 110, y: 130), in: document))
        recordStage("move.down.returned")
        let afterFront = original.preferences.collection
        let bytesAfterFront = try XCTUnwrap(original.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
        recordStage("move.drag.begin")
        move.mouseDragged(with: try pointer(.leftMouseDragged, at: NSPoint(x: 210, y: 190), in: document))
        recordStage("move.drag.returned")
        XCTAssertEqual(alpha.frame, NSRect(x: 200, y: 180, width: 400, height: 240))
        XCTAssertEqual(original.preferences.collection, afterFront, "Transient native geometry must not persist.")
        XCTAssertEqual(original.defaults.data(forKey: NativeWorkspacePreferences.storageKey), bytesAfterFront)
        recordStage("move.up.begin")
        move.mouseUp(with: try pointer(.leftMouseUp, at: NSPoint(x: 210, y: 190), in: document))
        recordStage("move.up.returned")
        let moved = NativeWorkspaceFrame(x: 200, y: 180, width: 400, height: 240)
        recordStage("move.persistence.await")
        try await waitUntil("Completed native movement did not persist in the mounted workspace owner.") {
            original.preferences.activeLayout(for: "fixture")?.panels.first { $0.id == "alpha" }?.frame == moved
                && alpha.stackingOrder == 1
        }
        recordStage("move.persistence.confirmed")
        let resize = try gestureHandle("workspace-resize-alpha", in: alpha)
        recordStage("resize.drag.begin")
        try drag(resize, in: document, from: NSPoint(x: 590, y: 411), to: NSPoint(x: 670, y: 451))
        recordStage("resize.drag.returned")
        let resized = NativeWorkspaceFrame(x: 200, y: 180, width: 480, height: 280)
        try await waitUntil("Completed native resizing did not reach persisted and mounted geometry.") {
            original.preferences.activeLayout(for: "fixture")?.panels.first { $0.id == "alpha" }?.frame == resized
                && alpha.frame == resized.nativeRect
        }
        recordStage("resize.persistence.confirmed")
        recordStage("hide.begin")
        try nativeDraftHide(beta)
        recordStage("hide.returned")
        try await waitUntil("The real native Hide action did not persist its visibility choice.") {
            beta.isHidden && original.preferences.activeLayout(for: "fixture")?
                .panels.first { $0.id == "beta" }?.isVisible == false
        }
        recordStage("hide.persistence.confirmed")
        XCTAssertTrue(document.panelHosts["alpha"] === alpha)
        XCTAssertTrue(alpha.hostingView === originalAlphaHost)
        XCTAssertEqual(original.preferences.activeLayout(for: "fixture.other"), independentSelection)
        let completed = original.preferences.collection
        let completedBytes = try XCTUnwrap(original.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
        let completedLayout = try XCTUnwrap(original.preferences.activeLayout(for: "fixture"))
        XCTAssertEqual(completedLayout.id, original.layoutA.id)
        XCTAssertEqual(completedLayout.panels.map(\.id), ["beta", "alpha"])

        recordStage("original.close.begin")
        await original.close(preservePreferences: true)
        recordStage("original.close.returned")
        scopeFixture = nil
        try await waitUntil("Closing the first native workspace did not dismantle its canvas.") {
            document.panelHosts.isEmpty && document.subviews.isEmpty && document.superview == nil
        }
        recordStage("original.canvas.dismantled")
        XCTAssertEqual(original.defaults.data(forKey: NativeWorkspacePreferences.storageKey), completedBytes)
        recordStage("reopened.fixture.create.begin")
        let reopened = try WorkspaceScopeFixture(layoutA: original.layoutA, layoutB: original.layoutB,
            registeredViewIDs: registeredViewIDs, restoringSuite: original.suite)
        recordStage("reopened.fixture.create.returned")
        scopeFixture = reopened
        XCTAssertFalse(reopened.preferences === original.preferences)
        XCTAssertFalse(reopened.model === original.model)
        XCTAssertNil(reopened.preferences.restorationError)
        XCTAssertEqual(reopened.preferences.collection, completed)
        XCTAssertEqual(reopened.defaults.data(forKey: NativeWorkspacePreferences.storageKey), completedBytes)
        recordStage("reopened.expose.begin")
        try await exposeScope(reopened)
        recordStage("reopened.expose.returned")
        let restoredDocument = try await mountedDocument(reopened)
        recordStage("reopened.canvas.mounted")
        let restoredAlpha = try XCTUnwrap(restoredDocument.panelHosts["alpha"])
        XCTAssertEqual(restoredAlpha.frame, resized.nativeRect)
        XCTAssertEqual(restoredAlpha.stackingOrder, 1)
        XCTAssertFalse(restoredAlpha.isHidden)
        XCTAssertNil(restoredDocument.panelHosts["beta"], "The saved hidden panel must remain unconstructed on reopen.")
        XCTAssertEqual(reopened.preferences.activeLayout(for: "fixture"), completedLayout)
        XCTAssertEqual(reopened.preferences.activeLayout(for: "fixture.other"), secondary)
        XCTAssertEqual(reopened.preferences.layouts(for: "fixture").first { $0.id == original.layoutB.id }, original.layoutB)
        XCTAssertEqual(reopened.preferences.collection, completed)
        XCTAssertEqual(reopened.defaults.data(forKey: NativeWorkspacePreferences.storageKey), completedBytes)
        recordStage("reopened.final-assertions.returned")
        // Public native input and restored AppKit geometry; no desktop/compositor claim.
    }

    func testMountedWrapperRetainsLocalControlStateAndInjectedOwnersAcrossLayouts() async throws {
        let fixture = try await mountScope()
        let document = try await mountedDocument(fixture)
        let panel = try XCTUnwrap(document.panelHosts["alpha"])
        let hosting = panel.hostingView
        let field = try await editableField(in: hosting)
        guard fixture.window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else {
            throw WorkspaceCanvasFixtureFailure("The real hosted text field did not begin native editing.")
        }
        editor.insertText("remembered input", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        fixture.window.endEditing(for: field)
        _ = fixture.window.makeFirstResponder(nil)
        try await waitUntil("The native edit did not update local SwiftUI state.") {
            self.stateReadback(in: hosting)?.text == "remembered input"
        }
        let localIdentity = try XCTUnwrap(stateReadback(in: hosting)?.identity)
        func requireState() throws {
            XCTAssertTrue(document.panelHosts["alpha"] === panel)
            XCTAssertTrue(panel.hostingView === hosting)
            let readback = try XCTUnwrap(stateReadback(in: hosting))
            XCTAssertEqual(readback.text, "remembered input")
            XCTAssertEqual(readback.identity, localIdentity)
            XCTAssertTrue(readback.model === fixture.model)
            XCTAssertTrue(readback.workbench === fixture.workbench)
            XCTAssertTrue(readback.guidedMode === fixture.guidedMode)
        }
        let moved = NativeWorkspaceFrame(x: 260, y: 260, width: 480, height: 300)
        try fixture.preferences.setFrame(moved, for: "alpha", in: "fixture")
        try await waitUntil("The wrapper did not apply completed geometry.") { panel.frame == moved.nativeRect }
        try fixture.preferences.bringToFront("alpha", in: "fixture")
        try await waitUntil("The wrapper did not apply stacking order.") { panel.stackingOrder == 1 }
        try requireState()
        try fixture.preferences.setShown(false, for: "alpha", in: "fixture")
        try await waitUntil("Hidden visibility did not reach the retained content.") {
            panel.isHiddenOrHasHiddenAncestor && self.stateReadback(in: hosting)?.visible == false
        }
        try requireState()
        try fixture.preferences.setShown(true, for: "alpha", in: "fixture")
        try await waitUntil("The retained panel did not resume visible content.") {
            !panel.isHiddenOrHasHiddenAncestor && self.stateReadback(in: hosting)?.visible == true
        }
        try fixture.preferences.activate(fixture.layoutB.id, for: "fixture")
        let frameB = try XCTUnwrap(fixture.layoutB.panels.first { $0.id == "alpha" }).frame
        try await waitUntil("The named layout was not applied.") { panel.frame == frameB.nativeRect }
        try requireState()
        try fixture.preferences.activate(fixture.layoutA.id, for: "fixture")
        try await waitUntil("The previous named layout was not restored.") { panel.frame == moved.nativeRect }
        try requireState()
        let resumedField = try await editableField(in: hosting)
        guard fixture.window.makeFirstResponder(resumedField), let resumedEditor = resumedField.currentEditor() as? NSTextView else {
            throw WorkspaceCanvasFixtureFailure("The retained field could not resume native editing.")
        }
        resumedEditor.insertText(" resumed", replacementRange: NSRange(location: resumedEditor.string.utf16.count, length: 0))
        fixture.window.endEditing(for: resumedField)
        _ = fixture.window.makeFirstResponder(nil)
        try await waitUntil("Resumed native input did not update retained local state.") {
            self.stateReadback(in: hosting)?.text == "remembered input resumed"
        }
        XCTAssertEqual(stateReadback(in: hosting)?.identity, localIdentity)
    }

    func testNeverShownPanelCreatesNoNativeContentAndFirstShowCreatesOneHost() async throws {
        let document = mountDocument()
        let counts = WorkspaceConstructionCounts()
        var layout = workspaceLayout(name: "Lazy")
        layout.panels[1].isVisible = false
        func apply() {
            document.apply(layout: layout, descriptors: workspaceDescriptors,
                content: { id, _ in AnyView(WorkspaceConstructionProbe(id: id, counts: counts)) },
                commitFrame: { _, _ in }, hidePanel: { _ in }, bringToFront: { _ in })
            document.layoutSubtreeIfNeeded()
        }
        apply()
        try await waitUntil("The visible native probe was not constructed.") { counts.values["alpha"] == 1 }
        XCTAssertNil(document.panelHosts["beta"])
        XCTAssertNil(counts.values["beta"])
        layout.panels.reverse(); apply()
        XCTAssertNil(document.panelHosts["beta"])
        XCTAssertNil(counts.values["beta"])
        let betaIndex = try XCTUnwrap(layout.panels.firstIndex { $0.id == "beta" })
        layout.panels[betaIndex].isVisible = true; apply()
        try await waitUntil("First show did not construct native beta content.") { counts.values["beta"] == 1 }
        let beta = try XCTUnwrap(document.panelHosts["beta"])
        let hosting = beta.hostingView
        layout.panels[betaIndex].isVisible = false; apply()
        XCTAssertTrue(beta.isHidden)
        layout.panels[betaIndex].isVisible = true; apply()
        try await waitUntil("Retained native beta content disappeared.") { !beta.isHidden }
        XCTAssertTrue(document.panelHosts["beta"] === beta)
        XCTAssertTrue(beta.hostingView === hosting)
        XCTAssertEqual(counts.values["beta"], 1)
    }

    func testRemovePanelsReleasesNativeHostsAndSwiftUILocalOwner() async throws {
        let document = mountDocument()
        let references = WorkspaceWeakReferences()
        var layout = workspaceLayout(name: "Release")
        layout.panels = [layout.panels[0]]
        document.apply(layout: layout, descriptors: [workspaceDescriptors[0]],
            content: { _, _ in AnyView(WorkspaceLifetimePanel()) },
            commitFrame: { _, _ in }, hidePanel: { _ in }, bringToFront: { _ in })
        document.layoutSubtreeIfNeeded()
        try await waitUntil("The local SwiftUI owner was not mounted.") {
            self.descendants(document).compactMap { $0 as? WorkspaceLifetimeReadback }.first?.owner != nil
        }
        autoreleasepool {
            references.panel = document.panelHosts["alpha"]
            references.hosting = document.panelHosts["alpha"]?.hostingView
            references.localOwner = descendants(document).compactMap { $0 as? WorkspaceLifetimeReadback }.first?.owner
            XCTAssertNotNil(references.panel)
            XCTAssertNotNil(references.hosting)
            XCTAssertNotNil(references.localOwner)
            window?.endEditing(for: nil)
            _ = window?.makeFirstResponder(nil)
            document.removePanels()
        }
        XCTAssertTrue(document.panelHosts.isEmpty)
        XCTAssertTrue(document.subviews.isEmpty)
        try await waitUntil("Removed panel, hosting view, or local SwiftUI owner remains retained.") {
            references.panel == nil && references.hosting == nil && references.localOwner == nil
        }
    }

    func testDefaultRestorationDismantlesCanvasAndReleasesIsolatedModelOwner() async throws {
        let references = WorkspaceWeakReferences()
        try await resetAndCloseScope(references)
        try await waitUntil("Representable dismantling or fixture teardown retained native content/model.") {
            references.panel == nil && references.hosting == nil && references.model == nil
        }
    }

    private func resetAndCloseScope(_ references: WorkspaceWeakReferences) async throws {
        let fixture = try await mountScope()
        let document = try await mountedDocument(fixture)
        autoreleasepool {
            references.panel = document.panelHosts["alpha"]
            references.hosting = document.panelHosts["alpha"]?.hostingView
            references.model = fixture.model
            XCTAssertNotNil(references.panel)
            XCTAssertNotNil(references.hosting)
            XCTAssertNotNil(references.model)
        }
        try fixture.preferences.reset("fixture")
        try await waitUntil("Default restoration did not invoke production representable dismantling.") {
            document.panelHosts.isEmpty && document.subviews.isEmpty && document.superview == nil
        }
        await fixture.close(); scopeFixture = nil
    }

    func testNamedLayoutApplyCancelsOldMoveAndResizeMouseUp() async throws {
        try await requireStaleGestureProtection(applyBeforeMouseUp: true)
    }

    func testNamedLayoutSelectionRejectsOldMouseUpBeforeSwiftUIApply() async throws {
        try await requireStaleGestureProtection(applyBeforeMouseUp: false)
    }

    func testProductionComputeSurfaceStopsWhenLayoutHidesPanelAndResumesSameSurface() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw WorkspaceCanvasFixtureFailure("The actual Reduce Motion setting prevents this motion-clock qualification.")
        }
        let resources = ComputeChipResources.shared
        guard resources.pipeline() != nil else {
            throw WorkspaceCanvasFixtureFailure(resources.failureReason ?? "The compiled Compute Metal pipeline is unavailable.")
        }
        let diagnostics = ComputeChipDiagnostics()
        defer {
            do {
                let data = try JSONEncoder().encode(diagnostics.snapshot())
                try directEvidence.save(data, name: "workspace-compute-terminal-before-teardown", extension: "json")
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "workspace-compute-terminal-before-teardown"
                attachment.lifetime = .keepAlways
                if !directEvidence.isEnabled { add(attachment) }
            } catch { XCTFail("Could not retain the terminal Compute diagnostic snapshot: \(error)") }
        }
        let state = WorkspaceComputeFixtureState()
        var visible = workspaceLayout(name: "Visible")
        visible.panels[0].frame = .init(x: 20, y: 20, width: 940, height: 640)
        visible.panels[1].isVisible = false
        var hidden = NativeWorkspaceLayout(id: UUID(), viewID: visible.viewID, name: "Hidden",
                                           canvas: visible.canvas, panels: visible.panels)
        hidden.panels[0].isVisible = false
        let fixture = try WorkspaceScopeFixture(layoutA: visible, layoutB: hidden, panelContent: { id, _ in
            if id == "alpha" {
                // Constant true exercises native ancestor visibility, without
                // attributing a caller-paused renderer to native hiding.
                return AnyView(WorkspaceComputeFixturePanel(state: state, resources: resources, diagnostics: diagnostics))
            }
            return AnyView(Text("Unused panel"))
        })
        scopeFixture = fixture
        fixture.stopAdditionalWork = { await state.stop() }
        state.start()
        try await exposeScope(fixture)
        let document = try await mountedDocument(fixture)
        let panel = try XCTUnwrap(document.panelHosts["alpha"])
        let hosting = panel.hostingView
        try await waitUntil("The production Compute surface did not start genuine visible rendering.", timeout: 5) {
            diagnostics.snapshot().completedCommands > 0 && diagnostics.snapshot().animationFrames >= 3
                && diagnostics.snapshot().activeClocks == 1
        }
        let surfaces = descendants(hosting).compactMap { $0 as? ComputeChipMetalView }
        XCTAssertEqual(surfaces.count, 1)
        let surface = try XCTUnwrap(surfaces.first)
        let renderer = try XCTUnwrap(surface.renderer)
        XCTAssertTrue(surface.isRenderingEligible)
        XCTAssertLessThanOrEqual(surface.preferredFramesPerSecond, 30)
        let warmed = diagnostics.snapshot()
        XCTAssertEqual(warmed.activeSurfaces, 1)
        XCTAssertEqual(warmed.failedCommands, 0)
        try fixture.preferences.activate(hidden.id, for: "fixture")
        try await waitUntil("The hidden workspace must stop its real renderer clock and drain commands.", timeout: 5) {
            panel.isHiddenOrHasHiddenAncestor && !surface.isRenderingEligible
                && diagnostics.snapshot().activeClocks == 0 && diagnostics.snapshot().inFlightSlots == 0
        }
        let hiddenBefore = diagnostics.snapshot()
        let updatesBefore = state.updateCount
        try await Task.sleep(for: .milliseconds(750))
        let hiddenAfter = diagnostics.snapshot()
        XCTAssertGreaterThan(state.updateCount, updatesBefore, "Fresh typed input must continue while native rendering is hidden.")
        XCTAssertEqual(hiddenAfter.submissions, hiddenBefore.submissions)
        XCTAssertEqual(hiddenAfter.animationFrames, hiddenBefore.animationFrames)
        XCTAssertEqual(hiddenAfter.ownedBuffers, warmed.ownedBuffers)
        XCTAssertEqual(hiddenAfter.activeSurfaces, 1)
        XCTAssertEqual(hiddenAfter.activeClocks, 0)
        XCTAssertTrue(document.panelHosts["alpha"] === panel)
        XCTAssertTrue(panel.hostingView === hosting)
        XCTAssertTrue(descendants(hosting).compactMap { $0 as? ComputeChipMetalView }.first === surface)
        try fixture.preferences.activate(visible.id, for: "fixture")
        try await waitUntil("Showing the retained panel must resume real Compute rendering.", timeout: 5) {
            surface.isRenderingEligible && diagnostics.snapshot().activeClocks == 1
                && diagnostics.snapshot().completedCommands > hiddenAfter.completedCommands
                && diagnostics.snapshot().animationFrames > hiddenAfter.animationFrames
        }
        XCTAssertTrue(surface.renderer === renderer)
        XCTAssertTrue(descendants(hosting).compactMap { $0 as? ComputeChipMetalView }.first === surface)
        let resumed = diagnostics.snapshot()
        XCTAssertEqual(resumed.activeSurfaces, 1)
        XCTAssertEqual(resumed.failedCommands, 0)
        let data = try JSONEncoder().encode([warmed, hiddenBefore, hiddenAfter, resumed])
        try directEvidence.save(data, name: "workspace-compute-visible-hidden-resumed", extension: "json")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "workspace-compute-visible-hidden-resumed"
        attachment.lifetime = .keepAlways
        if !directEvidence.isEnabled { add(attachment) }
    }

    /// Actual workspace viewport measurement; the fixture never invokes a production visibility callback.
    func testProductionComputeOuterScrollAndShownPanelMoveQuiesceAndResumeFrozenInput() async throws {
        continueAfterFailure = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw WorkspaceCanvasFixtureFailure("Reduce Motion prevents this native motion-clock measurement.")
        }
        let resources = ComputeChipResources.shared
        guard resources.pipeline() != nil else {
            throw WorkspaceCanvasFixtureFailure(resources.failureReason ?? "The compiled Compute pipeline is unavailable.")
        }
        let diagnostics = ComputeChipDiagnostics(), state = WorkspaceComputeFixtureState()
        var layout = workspaceLayout(name: "Frozen-input viewport")
        layout.canvas = .init(width: 1_200, height: 2_200)
        layout.panels[0].frame = .init(x: 20, y: 20, width: 940, height: 640)
        layout.panels[1].isVisible = false
        let spare = NativeWorkspaceLayout(id: UUID(), viewID: layout.viewID, name: "Unselected",
                                         canvas: layout.canvas, panels: layout.panels)
        let fixture = try WorkspaceScopeFixture(layoutA: layout, layoutB: spare, panelContent: { id, _ in
            id == "alpha"
                ? AnyView(WorkspaceComputeFixturePanel(state: state, resources: resources, diagnostics: diagnostics))
                : AnyView(Text("Unused panel"))
        })
        scopeFixture = fixture
        fixture.stopAdditionalWork = { await state.stop() }
        state.start()
        try await exposeScope(fixture)
        let document = try await mountedDocument(fixture)
        let panel = try XCTUnwrap(document.panelHosts["alpha"])
        let hosting = panel.hostingView
        let outer = try XCTUnwrap(document.enclosingScrollView)
        XCTAssertTrue(outer.documentView === document)
        try await waitUntil("The mounted workspace did not start genuine Compute rendering.", timeout: 5) {
            diagnostics.snapshot().animationFrames >= 3 && diagnostics.snapshot().activeClocks == 1
        }
        let surfaces = descendants(hosting).compactMap { $0 as? ComputeChipMetalView }
        XCTAssertEqual(surfaces.count, 1)
        let surface = try XCTUnwrap(surfaces.first), renderer = try XCTUnwrap(surface.renderer)
        let moveHandle = try gestureHandle("workspace-move-alpha", in: panel)
        let originalFrame = panel.frame, originalClipOrigin = outer.contentView.bounds.origin
        var stage = "warm", records: [[String: Any]] = [], clips: [NSClipView] = []
        defer {
            do {
                let summary: [String: Any] = [
                    "classification": "Actual workspace native outer-scroll/header-entry geometry and Compute clock measurement; no desktop gesture, compositor or Metal image claim",
                    "stage": stage, "records": records,
                    "clip_ancestor_types": clips.map { String(String(reflecting: type(of: $0)).prefix(512)) },
                    "clip_ancestor_count": clips.count, "nearest_clip_is_outer": clips.first === outer.contentView,
                    "terminal_panel_frame": NSStringFromRect(panel.frame),
                    "terminal_surface_visible_rect": NSStringFromRect(surface.visibleRect),
                    "terminal_outer_clip_bounds": NSStringFromRect(outer.contentView.bounds),
                    "terminal_rendering_eligible": surface.isRenderingEligible,
                    "terminal_diagnostics": try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostics.snapshot())),
                ]
                let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                guard data.count <= 256 * 1_024 else { throw WorkspaceCanvasFixtureFailure("Compute viewport evidence exceeded 256 KiB.") }
                try directEvidence.save(data, name: "workspace-compute-frozen-viewport", extension: "json")
                if !directEvidence.isEnabled {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                    attachment.name = "workspace-compute-frozen-viewport"; attachment.lifetime = .keepAlways; add(attachment)
                }
            } catch { XCTFail("Could not retain bounded Compute viewport evidence: \(error)") }
        }
        var ancestor: NSView? = surface.superview, ancestorsVisited = 0
        while let current = ancestor {
            guard ancestorsVisited < 64 else { throw WorkspaceCanvasFixtureFailure("Compute native ancestry exceeded 64.") }
            ancestorsVisited += 1
            if let clip = current as? NSClipView { clips.append(clip) }
            ancestor = current.superview
        }
        XCTAssertTrue(clips.contains { $0 === outer.contentView })
        XCTAssertTrue(surface.isRenderingEligible)
        XCTAssertLessThanOrEqual(surface.preferredFramesPerSecond, 30)
        for mode in ["outer-scroll", "shown-panel-move"] {
            stage = mode + ".fresh-input"
            let priorUpdates = state.updateCount
            state.start()
            try await waitUntil("Fresh typed Compute input and the real visible clock did not arrive.", timeout: 2) {
                state.updateCount > priorUpdates && surface.isRenderingEligible && diagnostics.snapshot().activeClocks == 1
            }
            await state.stop()
            let frozen = state.snapshot, frozenUpdates = state.updateCount
            let observed = min(try XCTUnwrap(frozen.cpu.observedAt), try XCTUnwrap(frozen.gpu.observedAt))
            let phaseDeadline = ProcessInfo.processInfo.systemUptime + 2.2
            let requireFrozen: @MainActor () throws -> Void = {
                guard state.snapshot == frozen, state.updateCount == frozenUpdates,
                      ProcessInfo.processInfo.systemUptime < phaseDeadline,
                      frozen.cpu.isFresh(at: Date().timeIntervalSince1970),
                      frozen.gpu.isFresh(at: Date().timeIntervalSince1970),
                      Date().timeIntervalSince1970 - observed < 2.8 else {
                    throw WorkspaceCanvasFixtureFailure("Frozen input changed or crossed its 2.2 s/freshness bound at " + stage)
                }
            }
            try requireFrozen()
            let before = diagnostics.snapshot(), beforeVisible = surface.visibleRect
            stage = mode + ".leave-viewport"
            if mode == "outer-scroll" {
                outer.contentView.scroll(to: NSPoint(x: 0, y: 1_200))
                outer.reflectScrolledClipView(outer.contentView)
            } else {
                try drag(moveHandle, in: document, from: NSPoint(x: 100, y: 36), to: NSPoint(x: 100, y: 1_516))
            }
            stage = mode + ".await-quiescence"
            try await waitUntil("Shown off-viewport Compute did not stop its actual clock and drain slots: " + mode, timeout: 0.55) {
                !surface.isRenderingEligible && diagnostics.snapshot().activeClocks == 0
                    && diagnostics.snapshot().inFlightSlots == 0
            }
            try requireFrozen()
            XCTAssertFalse(panel.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(fixture.preferences.activeLayout(for: "fixture")?.panels.first { $0.id == "alpha" }?.isVisible == true)
            XCTAssertTrue(document.visibleRect.intersection(panel.frame).isEmpty)
            let offBefore = diagnostics.snapshot(), offVisible = surface.visibleRect, offFrame = panel.frame
            stage = mode + ".frozen-dwell"
            try await Task.sleep(for: .milliseconds(250))
            try requireFrozen()
            let offAfter = diagnostics.snapshot()
            XCTAssertEqual(offAfter.submissions, offBefore.submissions)
            XCTAssertEqual(offAfter.animationFrames, offBefore.animationFrames)
            XCTAssertEqual(offAfter.activeClocks, 0)
            XCTAssertEqual(offAfter.ownedBuffers, before.ownedBuffers)
            stage = mode + ".return-viewport"
            if mode == "outer-scroll" {
                outer.contentView.scroll(to: originalClipOrigin)
                outer.reflectScrolledClipView(outer.contentView)
            } else {
                try drag(moveHandle, in: document, from: NSPoint(x: 100, y: 1_516), to: NSPoint(x: 100, y: 36))
            }
            stage = mode + ".await-resume"
            try await waitUntil("Frozen-input Compute did not resume from the native viewport transition: " + mode, timeout: 0.7) {
                surface.isRenderingEligible && diagnostics.snapshot().activeClocks == 1
                    && diagnostics.snapshot().completedCommands > offAfter.completedCommands
            }
            try requireFrozen()
            XCTAssertEqual(panel.frame, originalFrame)
            XCTAssertTrue(document.panelHosts["alpha"] === panel && panel.hostingView === hosting)
            XCTAssertTrue(descendants(hosting).compactMap { $0 as? ComputeChipMetalView }.first === surface)
            XCTAssertTrue(surface.renderer === renderer && outer.documentView === document)
            let resumed = diagnostics.snapshot()
            XCTAssertEqual(resumed.activeSurfaces, 1)
            XCTAssertEqual(resumed.failedCommands, 0)
            records.append([
                "mode": mode, "frozen_update_count": frozenUpdates, "typed_input_unchanged": state.snapshot == frozen,
                "before_surface_visible_rect": NSStringFromRect(beforeVisible),
                "off_surface_visible_rect": NSStringFromRect(offVisible), "off_panel_frame": NSStringFromRect(offFrame),
                "resumed_surface_visible_rect": NSStringFromRect(surface.visibleRect),
                "same_surface_renderer_panel_host": document.panelHosts["alpha"] === panel
                    && panel.hostingView === hosting && surface.renderer === renderer,
                "diagnostics": try JSONSerialization.jsonObject(with: JSONEncoder().encode([before, offBefore, offAfter, resumed])),
            ])
        }
        XCTAssertEqual(records.count, 2)
        stage = "both-frozen-phases-complete"
        await fixture.close(); scopeFixture = nil
    }

    private func requireStaleGestureProtection(applyBeforeMouseUp: Bool) async throws {
        for resizing in [false, true] {
            let fixture = try await mountScope()
            let document = try await mountedDocument(fixture)
            let panel = try XCTUnwrap(document.panelHosts["alpha"])
            let hosting = panel.hostingView
            let handle = try gestureHandle("workspace-\(resizing ? "resize" : "move")-alpha", in: panel)
            let start = resizing ? NSPoint(x: 490, y: 350) : NSPoint(x: 110, y: 130)
            let end = NSPoint(x: start.x + 50, y: start.y + 30)
            let oldHide = try XCTUnwrap(panel.hidePanel)
            let oldFront = try XCTUnwrap(panel.bringToFront)
            handle.mouseDown(with: try pointer(.leftMouseDown, at: start, in: document))
            handle.mouseDragged(with: try pointer(.leftMouseDragged, at: end, in: document))
            XCTAssertTrue(panel.isManipulating)
            XCTAssertNotEqual(panel.frame, fixture.layoutA.panels[0].frame.nativeRect)
            try fixture.preferences.activate(fixture.layoutB.id, for: "fixture")
            let afterActivation = fixture.preferences.collection
            let storedAfterActivation = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            let frameB = fixture.layoutB.panels[0].frame.nativeRect
            if applyBeforeMouseUp {
                try await waitUntil("Layout B must arrive before the stale mouse-up.") {
                    !panel.isManipulating && panel.frame == frameB
                }
            } else {
                // No suspension, root replacement, or copied UUID guard occurs
                // between the actual owner's activation and native callback.
                guard panel.isManipulating else {
                    throw WorkspaceCanvasFixtureFailure("The fixture did not reach the selection-before-apply window.")
                }
                XCTAssertNotEqual(panel.frame, frameB)
            }
            handle.mouseUp(with: try pointer(.leftMouseUp, at: end, in: document))
            oldHide(); oldFront()
            XCTAssertEqual(fixture.preferences.collection, afterActivation)
            XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), storedAfterActivation)
            try await waitUntil("The selected layout did not settle after the stale callback.") {
                !panel.isManipulating && panel.frame == frameB
            }
            XCTAssertTrue(document.panelHosts["alpha"] === panel)
            XCTAssertTrue(panel.hostingView === hosting)
            let currentHandle = try gestureHandle("workspace-move-alpha", in: panel)
            try drag(currentHandle, in: document, from: NSPoint(x: 310, y: 330), to: NSPoint(x: 330, y: 340))
            XCTAssertEqual(fixture.preferences.activeLayout(for: "fixture")?.panels.first { $0.id == "alpha" }?.frame,
                           .init(x: 320, y: 330, width: 420, height: 260))
            XCTAssertEqual(fixture.preferences.layouts(for: "fixture").first { $0.id == fixture.layoutA.id }?
                .panels.first { $0.id == "alpha" }?.frame, fixture.layoutA.panels[0].frame)
            await fixture.close(); scopeFixture = nil
        }
    }

    private func mountDocument() -> NativeWorkspaceDocumentView {
        let document = NativeWorkspaceDocumentView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800))
        window = present(document)
        return document
    }

    private func mountScope() async throws -> WorkspaceScopeFixture {
        let fixture = try WorkspaceScopeFixture()
        scopeFixture = fixture
        try await exposeScope(fixture)
        return fixture
    }

    private func exposeScope(_ fixture: WorkspaceScopeFixture) async throws {
        try await waitUntil("The isolated failure-only model did not finish startup.") { !fixture.model.isBootstrapping }
        XCTAssertNil(fixture.model.app)
        XCTAssertNil(fixture.model.manager)
        XCTAssertNil(fixture.model.remoteManager)
        NSApp.activate(ignoringOtherApps: true)
        fixture.window.makeKeyAndOrderFront(nil); fixture.window.orderFrontRegardless()
        _ = try await mountedDocument(fixture)
    }

    private func mountedDocument(_ fixture: WorkspaceScopeFixture) async throws -> NativeWorkspaceDocumentView {
        try await waitUntil("The actual NativeWorkspaceView did not mount its canvas.") {
            fixture.hosting.layoutSubtreeIfNeeded()
            return self.descendants(fixture.hosting).compactMap { $0 as? NativeWorkspaceDocumentView }.first?
                .panelHosts["alpha"]?.frame == fixture.preferences.activeLayout(for: "fixture")?
                    .panels.first { $0.id == "alpha" }?.frame.nativeRect
        }
        return try XCTUnwrap(descendants(fixture.hosting).compactMap { $0 as? NativeWorkspaceDocumentView }.first)
    }

    private func present(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1_200, height: 860),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Workspace canvas validation \(UUID().uuidString)"
        window.contentView = content
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.orderFrontRegardless()
        return window
    }

    private func descendants(_ root: NSView) -> [NSView] {
        var pending: [(NSView, Int)] = [(root, 0)]
        var result: [NSView] = []
        while let (view, depth) = pending.popLast(), result.count < 512 {
            result.append(view)
            let children = view.subviews
            guard (depth < 32 || children.isEmpty), children.count <= 512 - result.count - pending.count else {
                XCTFail("The scoped native fixture tree exceeded its 512-view/32-level bound.")
                return []
            }
            pending.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return result
    }

    private func gestureHandle(_ identifier: String, in panel: NativeWorkspacePanelHost) throws -> NSView {
        panel.layoutSubtreeIfNeeded()
        return try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier() == identifier })
    }

    private func pointer(_ type: NSEvent.EventType, at point: NSPoint, in document: NSView) throws -> NSEvent {
        let window = try XCTUnwrap(document.window)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: document.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func drag(_ handle: NSView, in document: NSView, from start: NSPoint, to end: NSPoint) throws {
        handle.mouseDown(with: try pointer(.leftMouseDown, at: start, in: document))
        handle.mouseDragged(with: try pointer(.leftMouseDragged, at: end, in: document))
        handle.mouseUp(with: try pointer(.leftMouseUp, at: end, in: document))
    }

    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: code == 53 ? "\u{1b}" : "", charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "", isARepeat: false, keyCode: code))
    }

    private func editableField(in root: NSView) async throws -> NSTextField {
        try await waitUntil("No real editable text field mounted.") {
            self.descendants(root).compactMap { $0 as? NSTextField }.contains { $0.isEditable }
        }
        return try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first { $0.isEditable })
    }

    private func stateReadback(in root: NSView) -> WorkspaceStateReadback? {
        descendants(root).compactMap { $0 as? WorkspaceStateReadback }.first
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 3, _ condition: () throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard try condition() else { throw WorkspaceCanvasFixtureFailure(message) }
    }
}

@MainActor
private final class WorkspaceScopeFixture {
    let suite: String
    let home: URL
    let defaults: UserDefaults
    let preferences: NativeWorkspacePreferences
    let model: AppModel
    let workbench: WorkbenchPreferences
    let guidedMode: GuidedModeCoordinator
    let layoutA: NativeWorkspaceLayout
    let layoutB: NativeWorkspaceLayout
    let hosting: NSHostingView<AnyView>
    let window: NSWindow
    var stopAdditionalWork: (@MainActor () async -> Void)?

    init(layoutA: NativeWorkspaceLayout? = nil, layoutB: NativeWorkspaceLayout? = nil,
         panelContent: ((String, Bool) -> AnyView)? = nil,
         registeredViewIDs: Set<String> = ["fixture"], restoringSuite: String? = nil) throws {
        let preparedA = layoutA ?? workspaceLayout(name: "A")
        let preparedB = layoutB ?? workspaceLayout(name: "B", alternate: true)
        guard registeredViewIDs.contains("fixture"), registeredViewIDs.count <= NativeWorkspaceLimits.maximumViews,
              registeredViewIDs.allSatisfy(NativeWorkspacePanelPlacement.isValidID) else {
            throw WorkspaceCanvasFixtureFailure("The fixture namespace registry is invalid or unbounded.")
        }
        if let restoringSuite {
            let prefix = "forge.workspace.canvas.tests."
            guard restoringSuite.hasPrefix(prefix), UUID(uuidString: String(restoringSuite.dropFirst(prefix.count))) != nil else {
                throw WorkspaceCanvasFixtureFailure("Reopening requires an exact isolated fixture-owned suite.")
            }
        }
        let suiteName = restoringSuite ?? "forge.workspace.canvas.tests.\(UUID().uuidString)"
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent("forge-workspace-canvas-\(UUID().uuidString)")
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let bounds = workspaceDescriptors.reduce(into: [String: NativeWorkspacePanelSizeBounds]()) { result, panel in
            result[panel.id] = .init(minimumWidth: panel.minimumSize.width, minimumHeight: panel.minimumSize.height,
                                     maximumWidth: panel.maximumSize.width, maximumHeight: panel.maximumSize.height)
        }
        let panelIDs = Set(workspaceDescriptors.map(\.id))
        let knownPanels = Dictionary(uniqueKeysWithValues: registeredViewIDs.map { ($0, panelIDs) })
        let registeredBounds = Dictionary(uniqueKeysWithValues: registeredViewIDs.map { ($0, bounds) })
        let preferencesOwner = NativeWorkspacePreferences(knownPanelIDsByView: knownPanels,
            panelSizeBoundsByView: registeredBounds, defaults: localDefaults)
        if restoringSuite == nil {
            do {
                try preferencesOwner.save(preparedA)
                try preferencesOwner.save(preparedB, activate: false)
            } catch {
                localDefaults.removePersistentDomain(forName: suiteName)
                throw error
            }
        } else {
            guard localDefaults.data(forKey: NativeWorkspacePreferences.storageKey) != nil,
                  preferencesOwner.restorationError == nil, preferencesOwner.activeLayout(for: "fixture") != nil else {
                throw WorkspaceCanvasFixtureFailure("The isolated fixture could not restore its original stored selection.")
            }
        }
        let workbenchOwner = WorkbenchPreferences(defaults: localDefaults)
        let guidedModeOwner = GuidedModeCoordinator(defaults: localDefaults)
        let bootstrap = AppBootstrapOperation(factory: { throw CancellationError() }, pluginStatus: { _ in nil })
        let modelOwner = AppModel(bootstrapOperation: bootstrap, diagnosticPaths: AppPaths(home: homeURL))
        modelOwner.autoRefresh = false
        let nativeHost = NSHostingView(rootView: AnyView(NativeWorkspaceView(viewID: "fixture", descriptors: workspaceDescriptors,
            defaultContent: { Text("Original default") },
            panelContent: panelContent ?? { _, _ in AnyView(WorkspaceStatefulPanel()) })
            .environment(\.nativeWorkspacePreferences, preferencesOwner)
            .environmentObject(modelOwner).environmentObject(workbenchOwner).environmentObject(guidedModeOwner)))
        let ownedWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1_240, height: 900),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        ownedWindow.isReleasedWhenClosed = false
        ownedWindow.title = "Mounted workspace validation \(UUID().uuidString)"
        ownedWindow.contentView = nativeHost
        suite = suiteName; home = homeURL; defaults = localDefaults
        preferences = preferencesOwner; model = modelOwner
        workbench = workbenchOwner; guidedMode = guidedModeOwner
        self.layoutA = preparedA; self.layoutB = preparedB
        hosting = nativeHost; window = ownedWindow
    }

    func close(preservePreferences: Bool = false) async {
        if let stopAdditionalWork { await stopAdditionalWork() }
        stopAdditionalWork = nil
        window.endEditing(for: nil); _ = window.makeFirstResponder(nil)
        hosting.rootView = AnyView(EmptyView())
        hosting.layoutSubtreeIfNeeded()
        window.orderOut(nil); window.contentView = nil; window.close()
        await model.stopBootstrap()
        model.telemetryBinding.detach()
        if !preservePreferences { defaults.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: home)
    }
}

@MainActor private let workspaceDescriptors = [
    NativeWorkspacePanelDescriptor(id: "alpha", title: "Alpha", defaultFrame: .init(x: 100, y: 120, width: 400, height: 240),
        minimumSize: CGSize(width: 280, height: 160), maximumSize: CGSize(width: 960, height: 640)),
    NativeWorkspacePanelDescriptor(id: "beta", title: "Beta", defaultFrame: .init(x: 600, y: 40, width: 400, height: 240),
        minimumSize: CGSize(width: 280, height: 160), maximumSize: CGSize(width: 960, height: 640)),
]

@MainActor private func workspaceLayout(name: String, alternate: Bool = false) -> NativeWorkspaceLayout {
    var panels = workspaceDescriptors.map { NativeWorkspacePanelPlacement(id: $0.id, frame: $0.defaultFrame, isVisible: true) }
    if alternate { panels[0].frame = .init(x: 300, y: 320, width: 420, height: 260) }
    return .init(id: UUID(), viewID: "fixture", name: name, canvas: .init(width: 1_200, height: 800), panels: panels)
}

private extension NativeWorkspaceFrame {
    var nativeRect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

@MainActor
private final class WorkspaceComputeFixtureState: ObservableObject {
    @Published private(set) var snapshot: ComputeChipSnapshot
    private(set) var updateCount = 0
    private var freshener: Task<Void, Never>?

    init() { snapshot = Self.sample() }

    func start() {
        guard freshener == nil else { return }
        freshener = Task { [weak self] in
            // A fixture-owned maximum of 120 updates (60 seconds), independent
            // of application telemetry. Teardown cancels and awaits this task.
            for _ in 0..<120 {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                snapshot = Self.sample(); updateCount += 1
            }
        }
    }

    func stop() async {
        let pending = freshener
        freshener = nil; pending?.cancel()
        await pending?.value
    }

    private static func sample() -> ComputeChipSnapshot {
        let now = Date().timeIntervalSince1970
        return ComputeChipSnapshot(
            cpu: .init(name: "Workspace fixture CPU", quality: .measured, observedAt: now,
                       activity: [0.35, 0, 0.2, 0], logicalCount: 4),
            gpu: .init(name: "Workspace fixture GPU", quality: .measured, observedAt: now,
                       activity: Array(repeating: 0.35, count: 16), logicalCount: 0))
    }
}

@MainActor
private struct WorkspaceComputeFixturePanel: View {
    @ObservedObject var state: WorkspaceComputeFixtureState
    let resources: ComputeChipResources
    let diagnostics: ComputeChipDiagnostics
    var body: some View {
        ComputeCoresContentView(snapshot: state.snapshot, autoRefresh: true,
                               resources: resources, diagnostics: diagnostics)
    }
}

@MainActor
private struct WorkspaceStatefulPanel: View {
    @State private var text = "fresh input"
    @State private var identity = UUID()
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workbench: WorkbenchPreferences
    @EnvironmentObject private var guidedMode: GuidedModeCoordinator
    @Environment(\.nativeWorkspacePanelVisible) private var visible
    var body: some View {
        VStack {
            TextField("Retained local input", text: $text)
            WorkspaceStateProbe(text: text, identity: identity, visible: visible,
                                model: model, workbench: workbench, guidedMode: guidedMode).frame(height: 1)
        }.padding(12)
    }
}

@MainActor
private struct WorkspaceStateProbe: NSViewRepresentable {
    let text: String
    let identity: UUID
    let visible: Bool
    let model: AppModel
    let workbench: WorkbenchPreferences
    let guidedMode: GuidedModeCoordinator
    func makeNSView(context: Context) -> WorkspaceStateReadback { WorkspaceStateReadback() }
    func updateNSView(_ view: WorkspaceStateReadback, context: Context) {
        view.text = text; view.identity = identity; view.visible = visible
        view.model = model; view.workbench = workbench; view.guidedMode = guidedMode
    }
}

@MainActor
private final class WorkspaceStateReadback: NSView {
    var text = ""
    var identity: UUID?
    var visible = false
    weak var model: AppModel?
    weak var workbench: WorkbenchPreferences?
    weak var guidedMode: GuidedModeCoordinator?
}

@MainActor
private final class WorkspaceConstructionCounts { var values: [String: Int] = [:] }

@MainActor
private struct WorkspaceConstructionProbe: NSViewRepresentable {
    let id: String
    let counts: WorkspaceConstructionCounts
    func makeNSView(context: Context) -> NSView {
        counts.values[id, default: 0] += 1
        return NSView()
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor
private final class WorkspaceLocalOwner: ObservableObject {}

@MainActor
private struct WorkspaceLifetimePanel: View {
    @StateObject private var owner = WorkspaceLocalOwner()
    var body: some View { WorkspaceLifetimeProbe(owner: owner).frame(width: 100, height: 100) }
}

@MainActor
private struct WorkspaceLifetimeProbe: NSViewRepresentable {
    let owner: WorkspaceLocalOwner
    func makeNSView(context: Context) -> WorkspaceLifetimeReadback { WorkspaceLifetimeReadback() }
    func updateNSView(_ view: WorkspaceLifetimeReadback, context: Context) { view.owner = owner }
}

@MainActor
private final class WorkspaceLifetimeReadback: NSView { weak var owner: WorkspaceLocalOwner? }

@MainActor
private final class WorkspaceWeakReferences {
    weak var panel: NativeWorkspacePanelHost?
    weak var hosting: NSHostingView<AnyView>?
    weak var localOwner: WorkspaceLocalOwner?
    weak var model: AppModel?
}

private struct WorkspaceCanvasFixtureFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
private struct NativeWorkspaceDraftField {
    let node: NativeWorkspaceDraftAccessibilityNode
    let exportedOwner: NativeWorkspaceDraftExportedFieldOwner?
    init(node: NativeWorkspaceDraftAccessibilityNode, exportedOwner: NativeWorkspaceDraftExportedFieldOwner? = nil) {
        self.node = node; self.exportedOwner = exportedOwner
    }
    var stringValue: String {
        get throws {
            if let exportedOwner { return try exportedOwner.readValue() }
            if let field = node.object as? NSTextField { return field.stringValue }
            return node.value as? String ?? "<non-string-native-value>"
        }
    }
}

@MainActor
private final class NativeWorkspaceDraftExportedFieldOwner {
    private weak var fixture: NativeWorkspaceDraftFixture?
    private weak var root: NSView?
    private let identifier: String

    init(fixture: NativeWorkspaceDraftFixture, root: NSView, identifier: String) {
        self.fixture = fixture; self.root = root; self.identifier = identifier
    }

    private func physicalScope() throws -> (NativeWorkspaceDraftFixture, String?) {
        guard let fixture, let root, root.window === fixture.window,
              fixture.window.contentView === fixture.hosting, fixture.hosting.window === fixture.window,
              !identifier.isEmpty, identifier.utf8.count <= 256 else {
            throw WorkspaceCanvasFixtureFailure("The exported field lost its exact native fixture/root ownership.")
        }
        if root === fixture.hosting { return (fixture, nil) }
        guard let panel = root.superview as? NativeWorkspacePanelHost,
              panel.hostingView === root, panel.window === fixture.window else {
            throw WorkspaceCanvasFixtureFailure("The exported field root is not the actual owned native panel host.")
        }
        var cursor: NSView? = panel
        var seen = Set<ObjectIdentifier>()
        for _ in 0..<48 {
            guard let current = cursor, seen.insert(ObjectIdentifier(current)).inserted else { break }
            if current === fixture.hosting { return (fixture, "workspace-panel-" + panel.panelID) }
            cursor = current.superview
        }
        throw WorkspaceCanvasFixtureFailure("The field panel does not reach the exact owned NSHostingView within 48 ancestors.")
    }

    func resolve(deadline: TimeInterval) throws -> (AXUIElement, NativeWorkspaceDraftExportedAXContext)? {
        let (fixture, panelIdentifier) = try physicalScope()
        guard let context = try NativeWorkspaceDraftExportedAXContext(fixture: fixture, deadline: deadline) else { return nil }
        var visited = 0
        let scope: AXUIElement
        if let panelIdentifier {
            guard let panel = try unique(panelIdentifier, under: context.windowElement, context: context, visited: &visited) else { return nil }
            try context.requireOwnedAncestor(panel, requiredIdentifier: panelIdentifier)
            scope = panel
        } else { scope = context.windowElement }
        guard let element = try unique(identifier, under: scope, context: context, visited: &visited) else { return nil }
        try context.requireOwnedAncestor(element, requiredIdentifier: panelIdentifier)
        let role = try NativeWorkspaceDraftAXQuery.attribute(element, kAXRoleAttribute, deadline: deadline) as? String
        let enabled = try NativeWorkspaceDraftAXQuery.attribute(element, kAXEnabledAttribute, deadline: deadline) as? Bool
        guard role == kAXTextFieldRole, enabled == true else {
            throw WorkspaceCanvasFixtureFailure("The exact exported field is not an enabled AXTextField.")
        }
        _ = try value(of: element, deadline: deadline)
        try NativeWorkspaceDraftAXQuery.prepare(element, deadline: deadline)
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard status == .success, settable.boolValue, ProcessInfo.processInfo.systemUptime < deadline else {
            throw WorkspaceCanvasFixtureFailure("The exact exported AXValue is not writable or exceeded its deadline: AXError \(status.rawValue).")
        }
        _ = try physicalScope()
        return (element, context)
    }

    private func unique(_ expected: String, under root: AXUIElement, context: NativeWorkspaceDraftExportedAXContext,
                        visited: inout Int) throws -> AXUIElement? {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var seen: [AXUIElement] = []
        var match: AXUIElement?
        while let (element, depth) = pending.popLast() {
            try context.requireOwner()
            guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
            guard visited < 2_048, depth <= 48 else {
                throw WorkspaceCanvasFixtureFailure("The scoped exported field lookup exceeded its shared 2048-node/48-level bound.")
            }
            seen.append(element); visited += 1
            let rawID = try NativeWorkspaceDraftAXQuery.attribute(element, kAXIdentifierAttribute, deadline: context.deadline)
            guard rawID == nil || (rawID as? String).map({ $0.utf8.count <= 16 * 1_024 }) == true else {
                throw WorkspaceCanvasFixtureFailure("The exported field traversal encountered a non-string or oversized identifier.")
            }
            if rawID as? String == expected {
                guard match == nil else { throw WorkspaceCanvasFixtureFailure("Duplicate exact exported field/panel identifier in its owned scope.") }
                match = element
            }
            let children = try NativeWorkspaceDraftAXQuery.children(element, kAXChildrenAttribute,
                limit: 2_048 - visited - pending.count, deadline: context.deadline)
            pending.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return match
    }

    private func value(of element: AXUIElement, deadline: TimeInterval) throws -> String {
        guard let value = try NativeWorkspaceDraftAXQuery.attribute(element, kAXValueAttribute, deadline: deadline) as? String,
              value.utf8.count <= 16 * 1_024 else {
            throw WorkspaceCanvasFixtureFailure("The exact exported field did not supply a bounded live String AXValue.")
        }
        return value
    }

    func readValue() throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        guard let (element, context) = try resolve(deadline: deadline) else {
            throw WorkspaceCanvasFixtureFailure("The retained field is absent from its current actual owned exported scope.")
        }
        try context.requireOwner()
        return try value(of: element, deadline: deadline)
    }

    func setValue(_ value: String, in window: NSWindow) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let (fixture, _) = try physicalScope()
        guard fixture.window === window, value.utf8.count <= 16 * 1_024,
              let (element, context) = try resolve(deadline: deadline) else {
            throw WorkspaceCanvasFixtureFailure("The exported edit is outside the exact owned window or bounded field scope.")
        }
        try context.requireOwner()
        try NativeWorkspaceDraftAXQuery.prepare(element, deadline: deadline)
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        guard status == .success, ProcessInfo.processInfo.systemUptime < deadline else {
            throw WorkspaceCanvasFixtureFailure("The real exported AXValue setter failed or exceeded its deadline: AXError \(status.rawValue).")
        }
        _ = try self.value(of: element, deadline: deadline)
        _ = try physicalScope()
    }

    func backingMeasurement() -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 3
        var rows: [[String: Any]] = []
        var visited = 0
        var report: [String: Any] = [
            "classification": "Diagnostic only: exact own-field public AX geometry and owned AppKit backing fields/current values; no focus, editor, setter, commit or binding qualification",
            "expected_identifier": identifier, "deadline_seconds": 3,
            "node_limit": 2_048, "depth_limit": 48, "editable_field_limit": 64,
        ]
        do {
            let (fixture, panelIdentifier) = try physicalScope()
            guard let root, let (element, context) = try resolve(deadline: deadline) else {
                throw WorkspaceCanvasFixtureFailure("The diagnostic did not resolve the current exact owned field/root.")
            }
            try context.requireOwnedAncestor(element, requiredIdentifier: panelIdentifier)
            report["panel_identifier"] = panelIdentifier.map { $0 as Any } ?? NSNull()
            report["root_bounds"] = NSStringFromRect(root.bounds)
            report["root_hidden_or_hidden_ancestor"] = root.isHiddenOrHasHiddenAncestor
            report["window_title"] = fixture.window.title
            report["window_key"] = fixture.window.isKeyWindow
            report["window_visible"] = fixture.window.isVisible
            report["app_active"] = NSApp.isActive
            report["window_first_responder_type"] = fixture.window.firstResponder
                .map { String(String(reflecting: type(of: $0)).prefix(256)) as Any } ?? NSNull()
            report["actual_live_AXValue"] = String(try value(of: element, deadline: deadline).prefix(1_024))
            report["actual_AXFocused"] = (try NativeWorkspaceDraftAXQuery.attribute(element, kAXFocusedAttribute, deadline: deadline) as? Bool)
                .map { $0 as Any } ?? NSNull()
            try NativeWorkspaceDraftAXQuery.prepare(element, deadline: deadline)
            var focusedSettable: DarwinBoolean = false
            let focusedStatus = AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &focusedSettable)
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw WorkspaceCanvasFixtureFailure("The focused-settable diagnostic exceeded its deadline.")
            }
            report["AXFocused_settable_status"] = focusedStatus.rawValue
            report["AXFocused_settable"] = focusedStatus == .success ? focusedSettable.boolValue as Any : NSNull()
            guard let position = try NativeWorkspaceDraftAXQuery.attribute(element, kAXPositionAttribute, deadline: deadline),
                  let dimensions = try NativeWorkspaceDraftAXQuery.attribute(element, kAXSizeAttribute, deadline: deadline),
                  CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(),
                  CFGetTypeID(dimensions as CFTypeRef) == AXValueGetTypeID() else {
                throw WorkspaceCanvasFixtureFailure("The exact field diagnostic did not expose AXValue position/size.")
            }
            let positionValue = position as! AXValue, sizeValue = dimensions as! AXValue
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
                  AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &size),
                  point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0,
                  let primary = NSScreen.screens.first, primary.frame.origin == .zero else {
                throw WorkspaceCanvasFixtureFailure("The exact field or primary-screen geometry could not be qualified for the diagnostic.")
            }
            let actualAXFrame = NSRect(origin: point, size: size)
            report["actual_AX_frame_top_left_screen_points"] = NSStringFromRect(actualAXFrame)
            report["primary_screen_frame_bottom_left_points"] = NSStringFromRect(primary.frame)
            var pending: [(NSView, Int)] = [(root, 0)]
            var seen = Set<ObjectIdentifier>()
            while let (view, depth) = pending.popLast() {
                guard ProcessInfo.processInfo.systemUptime < deadline, visited < 2_048, depth <= 48,
                      view.subviews.count <= 2_048 - visited - pending.count - 1 else {
                    throw WorkspaceCanvasFixtureFailure("The backing-field diagnostic exceeded its deadline/node/depth bound.")
                }
                guard seen.insert(ObjectIdentifier(view)).inserted else { continue }
                visited += 1
                if let field = view as? NSTextField, field.isEditable {
                    guard rows.count < 64, field.window === fixture.window else {
                        throw WorkspaceCanvasFixtureFailure("The backing-field diagnostic exceeded its field bound or exact window owner.")
                    }
                    let screen = fixture.window.convertToScreen(field.convert(field.bounds, to: nil))
                    guard screen.origin.x.isFinite, screen.origin.y.isFinite,
                          screen.width.isFinite, screen.height.isFinite, screen.width >= 0, screen.height >= 0 else {
                        throw WorkspaceCanvasFixtureFailure("An actual native backing field returned nonfinite/negative geometry.")
                    }
                    let axRect = NSRect(x: screen.minX, y: primary.frame.maxY - screen.maxY,
                                        width: screen.width, height: screen.height)
                    rows.append([
                        "type": String(String(reflecting: type(of: field)).prefix(256)),
                        "identifier": String((field.accessibilityIdentifier() ?? "").prefix(256)),
                        "label": String((field.accessibilityLabel() ?? "").prefix(256)),
                        "placeholder": String((field.placeholderString ?? "").prefix(256)),
                        "enabled": field.isEnabled, "editable": field.isEditable,
                        "hidden_or_hidden_ancestor": field.isHiddenOrHasHiddenAncestor,
                        "string_value": String(field.stringValue.prefix(1_024)),
                        "current_editor_string": field.currentEditor().map { String($0.string.prefix(1_024)) as Any } ?? NSNull(),
                        "native_bounds": NSStringFromRect(field.bounds),
                        "native_screen_frame_bottom_left_points": NSStringFromRect(screen),
                        "converted_frame_top_left_screen_points": NSStringFromRect(axRect),
                        "exact_frame_match": axRect == actualAXFrame,
                        "delta_x": axRect.origin.x - actualAXFrame.origin.x,
                        "delta_y": axRect.origin.y - actualAXFrame.origin.y,
                        "delta_width": axRect.width - actualAXFrame.width,
                        "delta_height": axRect.height - actualAXFrame.height,
                    ])
                }
                pending.append(contentsOf: view.subviews.map { ($0, depth + 1) })
            }
            _ = try physicalScope()
        } catch {
            report["diagnostic_error_type"] = String(String(reflecting: type(of: error)).prefix(1_024))
            report["diagnostic_error_description"] = String(String(describing: error).prefix(4_096))
        }
        report["actual_editable_backing_fields"] = rows
        report["visited_native_nodes"] = visited
        report["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
        return report
    }
}

@MainActor
private struct NativeWorkspaceDraftAccessibilityNode {
    let object: AnyObject
    private let formal: (any NSAccessibilityProtocol)?
    private let legacy: NSObject?
    private let attributes: Set<NSAccessibility.Attribute>
    let exportedAX: AXUIElement?
    let exportedContext: NativeWorkspaceDraftExportedAXContext?
    private let exportedSnapshot: NativeWorkspaceDraftExportedAXSnapshot?

    init(_ object: AnyObject) throws {
        self.object = object
        exportedAX = nil; exportedContext = nil; exportedSnapshot = nil
        let formalOwner = object as? any NSAccessibilityProtocol
        formal = formalOwner
        if formalOwner != nil {
            legacy = nil; attributes = []
        } else if let native = object as? NSObject {
            let names = native.accessibilityAttributeNames()
            guard names.count <= 128 else {
                throw WorkspaceCanvasFixtureFailure("The public informal accessibility attribute list exceeded its bound.")
            }
            legacy = native; attributes = Set(names)
        } else {
            throw WorkspaceCanvasFixtureFailure("The actual native accessibility object supports neither public bridge: \(String(describing: type(of: object)))")
        }
    }

    init(exported element: AXUIElement, context: NativeWorkspaceDraftExportedAXContext) throws {
        object = element; formal = nil; legacy = nil; attributes = []
        exportedAX = element; exportedContext = context
        exportedSnapshot = try context.snapshot(element)
    }

    private func legacyValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard attributes.contains(attribute) else { return nil }
        return legacy?.accessibilityAttributeValue(attribute)
    }
    var identifier: String? {
        if let exportedSnapshot { return exportedSnapshot.identifier }
        return formal?.accessibilityIdentifier() ?? legacyValue(.identifier) as? String
    }
    var title: String? {
        if let exportedSnapshot { return exportedSnapshot.title }
        return formal?.accessibilityTitle() ?? legacyValue(.title) as? String
    }
    var label: String? {
        if let exportedSnapshot { return exportedSnapshot.label }
        return formal?.accessibilityLabel() ?? legacyValue(.description) as? String
    }
    var placeholder: String? {
        if let exportedSnapshot { return exportedSnapshot.placeholder }
        return formal?.accessibilityPlaceholderValue() ?? legacyValue(.placeholderValue) as? String
    }
    var value: Any? {
        if let exportedSnapshot { return exportedSnapshot.value }
        return formal?.accessibilityValue() ?? legacyValue(.value)
    }
    var enabled: Bool? {
        if let exportedSnapshot { return exportedSnapshot.enabled }
        if let formal { return formal.isAccessibilityEnabled() }
        return legacyValue(.enabled) as? Bool
    }
    var role: NSAccessibility.Role? {
        if let exportedSnapshot { return exportedSnapshot.role }
        if let formal { return formal.accessibilityRole() }
        guard let raw = legacyValue(.role) as? String else { return nil }
        return NSAccessibility.Role(rawValue: raw)
    }
    var canSetValue: Bool {
        if exportedAX != nil { return false }
        if let formal { return formal.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilityValue:")) }
        return attributes.contains(.value) && legacy?.accessibilityIsAttributeSettable(.value) == true
    }
    func setValue(_ value: String) throws {
        guard enabled == true, role == .textField, canSetValue else {
            throw WorkspaceCanvasFixtureFailure("The enabled actual semantic text field does not advertise a writable value.")
        }
        if let formal { formal.setAccessibilityValue(value) }
        else { legacy?.accessibilitySetValue(value, forAttribute: .value) }
    }
    func children() throws -> [Any] {
        let formalChildren = formal?.accessibilityChildren() ?? []
        guard formalChildren.count <= 2_048 else {
            throw WorkspaceCanvasFixtureFailure("The public formal child list exceeded its finite bound.")
        }
        let informalValue: Any?
        if formal != nil, let native = object as? NSObject {
            let names = native.accessibilityAttributeNames()
            guard names.count <= 128 else {
                throw WorkspaceCanvasFixtureFailure("The public informal child attribute names exceeded their finite bound.")
            }
            informalValue = names.contains(.children) ? native.accessibilityAttributeValue(.children) : nil
        } else {
            informalValue = legacyValue(.children)
        }
        var informalChildren: [Any] = []
        if let value = informalValue {
            guard let children = value as? [Any], children.count <= 2_048 else {
                throw WorkspaceCanvasFixtureFailure("The advertised public informal children are not a bounded array.")
            }
            informalChildren = children
        }
        var seen = Set<ObjectIdentifier>()
        var children: [Any] = []
        for child in formalChildren + informalChildren {
            let identity: ObjectIdentifier
            if let actual = child as? any NSAccessibilityProtocol {
                identity = ObjectIdentifier(actual as AnyObject)
            } else if let actual = child as? NSObject {
                identity = ObjectIdentifier(actual)
            } else {
                throw WorkspaceCanvasFixtureFailure("The actual public child supports neither native bridge; boxed identity is refused.")
            }
            guard seen.insert(identity).inserted else { continue }
            guard children.count < 2_048 else {
                throw WorkspaceCanvasFixtureFailure("The union of actual public native child lists exceeded its bound.")
            }
            children.append(child)
        }
        return children
    }
    func actionForensics() throws -> [String: Any] {
        if let exportedAX, let exportedContext { return try exportedContext.actionForensics(exportedAX) }
        let informalObject = object as? NSObject
        let actions = informalObject?.accessibilityActionNames() ?? []
        guard actions.count <= 64 else {
            throw WorkspaceCanvasFixtureFailure("The public informal action metadata exceeded its finite bound.")
        }
        return [
            "object_type": String(describing: type(of: object)),
            "formal_bridge": formal != nil, "informal_bridge": informalObject != nil,
            "identifier": identifier ?? "", "role": role?.rawValue ?? "",
            "enabled": enabled.map { $0 as Any } ?? NSNull(),
            "formal_press_allowed": formal?.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityPerformPress")) ?? false,
            "advertised_informal_actions": actions.map(\.rawValue),
        ]
    }
    func press() throws {
        if let exportedAX, let exportedContext { try exportedContext.press(exportedAX); return }
        guard enabled == true else { throw WorkspaceCanvasFixtureFailure("The actual native action control is not enabled.") }
        if let formal {
            guard formal.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityPerformPress")),
                  formal.accessibilityPerformPress() else {
                throw WorkspaceCanvasFixtureFailure("The enabled production control refused its public native semantic press.")
            }
        } else {
            guard let legacy else { throw WorkspaceCanvasFixtureFailure("The public action bridge is unavailable.") }
            let actions = legacy.accessibilityActionNames()
            guard actions.count <= 64, actions.contains(.press) else {
                throw WorkspaceCanvasFixtureFailure("The native informal control does not advertise the public press action.")
            }
            legacy.accessibilityPerformAction(.press)
        }
    }
}

@MainActor
private enum NativeWorkspaceDraftAXQuery {
    static func prepare(_ element: AXUIElement, deadline: TimeInterval) throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw WorkspaceCanvasFixtureFailure("The public own-window AX observation exceeded its shared three-second deadline.")
        }
        var pid: pid_t = 0
        let pidStatus = AXUIElementGetPid(element, &pid)
        guard pidStatus == .success, pid == ProcessInfo.processInfo.processIdentifier else {
            throw WorkspaceCanvasFixtureFailure("The public AX node is not this process: AXError \(pidStatus.rawValue).")
        }
        let timeoutStatus = AXUIElementSetMessagingTimeout(element, 0.1)
        guard timeoutStatus == .success else {
            throw WorkspaceCanvasFixtureFailure("The public AX messaging timeout failed: AXError \(timeoutStatus.rawValue).")
        }
    }

    static func attribute(_ element: AXUIElement, _ name: String, deadline: TimeInterval) throws -> Any? {
        try prepare(element, deadline: deadline)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard status == .success || status == .attributeUnsupported || status == .noValue else {
            var identity: [String] = []
            for attribute in [kAXIdentifierAttribute, kAXRoleAttribute] {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    identity.append("\(attribute)=not-queried(shared-deadline)"); continue
                }
                var raw: CFTypeRef?
                let identityStatus = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
                let text: String
                if let string = raw as? String { text = String(string.prefix(256)) }
                else if let raw { text = "<" + String(String(reflecting: type(of: raw)).prefix(256)) + ">" }
                else { text = "<nil>" }
                identity.append("\(attribute) status=\(identityStatus.rawValue) value=\(text)")
            }
            throw WorkspaceCanvasFixtureFailure("Public own-window \(name) failed: AXError \(status.rawValue); same-node \(identity.joined(separator: "; ")).")
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw WorkspaceCanvasFixtureFailure("The public AX attribute query exceeded its shared deadline.")
        }
        return status == .success ? value : nil
    }

    @MainActor
    static func discoveryFailureDiagnostic(root: AXUIElement, parent: AXUIElement?, child: AXUIElement,
                                           childOrdinal: Int?, deadline originalDeadline: TimeInterval) async -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        let processTrustedAtDiagnosticStart = AXIsProcessTrusted()
        let deadline = started + 0.25
        let immediateDeadline = started + 0.08
        func metadata(_ element: AXUIElement, attributes: [String], deadline stageDeadline: TimeInterval) -> [String: Any] {
            let type = CFGetTypeID(element)
            var result: [String: Any] = ["cf_type_id": type]
            guard type == AXUIElementGetTypeID(), ProcessInfo.processInfo.systemUptime < stageDeadline else {
                result["not_queried"] = "invalid-AX-type-or-diagnostic-deadline"; return result
            }
            var pid: pid_t = 0
            let pidStatus = AXUIElementGetPid(element, &pid)
            result["pid_status"] = pidStatus.rawValue; result["pid"] = pid
            result["pid_is_own_process"] = pidStatus == .success && pid == ProcessInfo.processInfo.processIdentifier
            guard pidStatus == .success, pid == ProcessInfo.processInfo.processIdentifier else { return result }
            var rows: [String: Any] = [:]
            for attribute in attributes {
                let remaining = min(deadline, stageDeadline) - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { rows[attribute] = ["not_queried": "diagnostic-deadline"]; continue }
                let timeout = AXUIElementSetMessagingTimeout(element, Float(min(0.005, remaining / 2)))
                var row: [String: Any] = ["timeout_status": timeout.rawValue]
                guard timeout == .success, ProcessInfo.processInfo.systemUptime < min(deadline, stageDeadline) else {
                    row["not_queried"] = "timeout-or-diagnostic-deadline"; rows[attribute] = row; continue
                }
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                row["status"] = status.rawValue
                if let value {
                    row["value_cf_type_id"] = CFGetTypeID(value)
                    if let string = value as? String { row["value"] = String(string.prefix(512)) }
                }
                rows[attribute] = row
            }
            result["attributes"] = rows
            return result
        }
        let rootMetadata = metadata(root, attributes: [kAXRoleAttribute, kAXIdentifierAttribute], deadline: immediateDeadline)
        let parentMetadata = parent.map {
            metadata($0, attributes: [kAXRoleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute],
                     deadline: immediateDeadline)
        }
        let childMetadata = metadata(child, attributes: [kAXRoleAttribute, kAXIdentifierAttribute], deadline: immediateDeadline)
        var report = discoveryFailureImmediateDiagnostic(root: root, parent: parent, child: child, deadline: immediateDeadline)
        report["process_trusted_at_diagnostic_start"] = processTrustedAtDiagnosticStart
        report["classification"] = "Bounded post-failure measurement only; one held-parent child re-enumeration after one 20ms yield; original identifier error remains fatal"
        report["immediate_discovery_elapsed_seconds"] = report["elapsed_seconds"]
        report["immediate_deadline_limit_seconds"] = 0.08
        report["immediate_owned_root_metadata"] = rootMetadata
        report["immediate_discovery_parent_metadata"] = parentMetadata.map { $0 as Any } ?? NSNull()
        report["immediate_failed_child_metadata"] = childMetadata
        report["original_deadline_remaining_seconds"] = originalDeadline - started
        report["deadline_limit_seconds"] = 0.25
        report["diagnostic_deadline_independent_of_failed_lookup"] = true
        report["fresh_copy_count_limit"] = 1
        report["recorded_discovery_child_ordinal"] = childOrdinal.map { $0 as Any } ?? NSNull()
        report["ancestor_scope"] = "Owned exported window and previously discovered AXChildren parent only; no new AXParent query or native-owner inference"
        report["yield_request_count"] = 1; report["yield_requested_seconds"] = 0.02
        func finish() -> [String: Any] {
            report["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
            report["within_diagnostic_deadline"] = ProcessInfo.processInfo.systemUptime <= deadline
            return report
        }
        let yieldStarted = ProcessInfo.processInfo.systemUptime
        do { try await Task.sleep(for: .milliseconds(20)); report["yield_completed"] = true }
        catch {
            report["yield_completed"] = false
            report["yield_error_type"] = String(String(reflecting: type(of: error)).prefix(1_024))
            report["yield_elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - yieldStarted
            return finish()
        }
        report["yield_elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - yieldStarted
        report["post_yield_same_held_child_metadata"] = metadata(child,
            attributes: [kAXRoleAttribute, kAXIdentifierAttribute], deadline: deadline)
        guard let parent, let childOrdinal, 0..<2_048 ~= childOrdinal else {
            report["fresh_child_not_queried"] = "missing-parent-or-invalid-recorded-ordinal"; return finish()
        }
        func prepareParent(_ operation: String) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { report[operation + "_not_queried"] = "diagnostic-deadline"; return false }
            var pid: pid_t = 0
            let pidStatus = AXUIElementGetPid(parent, &pid)
            report[operation + "_pid_status"] = pidStatus.rawValue
            report[operation + "_pid"] = pid
            guard pidStatus == .success, pid == ProcessInfo.processInfo.processIdentifier else { return false }
            let remainingAfterIdentity = deadline - ProcessInfo.processInfo.systemUptime
            guard remainingAfterIdentity > 0 else {
                report[operation + "_not_queried"] = "diagnostic-deadline"; return false
            }
            let timeout = AXUIElementSetMessagingTimeout(parent, Float(min(0.01, remainingAfterIdentity / 2)))
            report[operation + "_timeout_status"] = timeout.rawValue
            return timeout == .success && ProcessInfo.processInfo.systemUptime < deadline
        }
        guard prepareParent("post_yield_parent_count") else { return finish() }
        var count = 0
        let countStatus = AXUIElementGetAttributeValueCount(parent, kAXChildrenAttribute as CFString, &count)
        report["post_yield_parent_count_status"] = countStatus.rawValue
        report["post_yield_parent_child_count"] = count
        guard ProcessInfo.processInfo.systemUptime < deadline, countStatus == .success,
              0...2_048 ~= count, childOrdinal < count else {
            report["fresh_child_not_queried"] = "count-status-bound-or-recorded-ordinal-absent"; return finish()
        }
        guard prepareParent("post_yield_parent_copy") else { return finish() }
        var values: CFArray?
        let copyStatus = AXUIElementCopyAttributeValues(parent, kAXChildrenAttribute as CFString, childOrdinal, 1, &values)
        report["post_yield_parent_copy_status"] = copyStatus.rawValue
        guard ProcessInfo.processInfo.systemUptime < deadline, copyStatus == .success, let values,
              CFGetTypeID(values) == CFArrayGetTypeID() else { return finish() }
        let copiedCount = CFArrayGetCount(values)
        report["post_yield_copied_child_count"] = copiedCount
        guard copiedCount == 1, let pointer = CFArrayGetValueAtIndex(values, 0) else { return finish() }
        let raw = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
        report["post_yield_copied_child_cf_type_id"] = CFGetTypeID(raw)
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return finish() }
        let fresh = raw as! AXUIElement
        report["post_yield_fresh_child_CFEqual_held_child"] = CFEqual(fresh, child)
        report["post_yield_fresh_child_metadata"] = metadata(fresh,
            attributes: [kAXRoleAttribute, kAXIdentifierAttribute], deadline: deadline)
        return finish()
    }

    static func discoveryFailureImmediateDiagnostic(root: AXUIElement, parent: AXUIElement?, child: AXUIElement,
                                                    deadline originalDeadline: TimeInterval) -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = min(originalDeadline, started + 0.25)
        var report: [String: Any] = [
            "classification": "One-shot post-failure root/parent measurement; original identifier error remains fatal",
            "separate_deadline_used": false, "deadline_limit_seconds": deadline - started,
            "original_deadline_remaining_seconds": originalDeadline - started, "child_count_limit": 2_048,
            "complete_requested_parent_children_range": false, "non_atomic_count_and_copy": true,
        ]
        func finish() -> [String: Any] {
            report["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
            report["within_diagnostic_deadline"] = ProcessInfo.processInfo.systemUptime <= deadline
            return report
        }
        func identity(_ element: AXUIElement, _ label: String) -> Bool {
            let type = CFGetTypeID(element)
            report[label + "_cf_type_id"] = type
            guard type == AXUIElementGetTypeID(), ProcessInfo.processInfo.systemUptime < deadline else { return false }
            var pid: pid_t = 0
            let status = AXUIElementGetPid(element, &pid)
            report[label + "_pid_status"] = status.rawValue; report[label + "_pid"] = pid
            report[label + "_pid_is_own_process"] = status == .success && pid == ProcessInfo.processInfo.processIdentifier
            return status == .success && pid == ProcessInfo.processInfo.processIdentifier
        }
        func prepare(_ element: AXUIElement, _ operation: String, remainingCalls: Double) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { report[operation + "_not_queried"] = "diagnostic-deadline"; return false }
            let status = AXUIElementSetMessagingTimeout(element, Float(min(0.05, remaining / remainingCalls)))
            report[operation + "_timeout_status"] = status.rawValue
            return status == .success && ProcessInfo.processInfo.systemUptime < deadline
        }
        let rootOwned = identity(root, "root"), childOwned = identity(child, "failed_child")
        let parentOwned = parent.map { identity($0, "discovery_parent") } ?? false
        report["discovery_parent_present"] = parent != nil
        guard rootOwned, childOwned else { return finish() }
        guard prepare(root, "root_role", remainingCalls: 3) else { return finish() }
        var role: CFTypeRef?
        let roleStatus = AXUIElementCopyAttributeValue(root, kAXRoleAttribute as CFString, &role)
        report["root_role_status"] = roleStatus.rawValue
        if let role { report["root_role_cf_type_id"] = CFGetTypeID(role) }
        if let role = role as? String { report["root_role"] = String(role.prefix(256)) }
        guard ProcessInfo.processInfo.systemUptime < deadline, roleStatus == .success, let parent, parentOwned else { return finish() }
        guard prepare(parent, "parent_child_count", remainingCalls: 2) else { return finish() }
        var count = 0
        let countStatus = AXUIElementGetAttributeValueCount(parent, kAXChildrenAttribute as CFString, &count)
        report["parent_child_count_status"] = countStatus.rawValue; report["parent_child_count"] = count
        guard ProcessInfo.processInfo.systemUptime < deadline, countStatus == .success,
              count >= 0, count <= 2_048 else { return finish() }
        guard count > 0 else {
            report["failed_child_present_in_copied_parent_children"] = false
            report["copied_children_are_ax_elements"] = true
            report["complete_requested_parent_children_range"] = true
            return finish()
        }
        guard prepare(parent, "parent_children_copy", remainingCalls: 1) else { return finish() }
        var values: CFArray?
        let copyStatus = AXUIElementCopyAttributeValues(parent, kAXChildrenAttribute as CFString, 0, count, &values)
        report["parent_children_copy_status"] = copyStatus.rawValue
        guard ProcessInfo.processInfo.systemUptime < deadline, copyStatus == .success, let values else { return finish() }
        report["copied_array_cf_type_id"] = CFGetTypeID(values)
        guard CFGetTypeID(values) == CFArrayGetTypeID() else { return finish() }
        let copiedCount = CFArrayGetCount(values)
        report["parent_children_copied_count"] = copiedCount
        guard copiedCount == count else { return finish() }
        var childTypeIDs: [CFTypeID] = [], containsChild = false
        for index in 0..<copiedCount {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return finish() }
            guard let pointer = CFArrayGetValueAtIndex(values, index) else {
                report["null_copied_child_index"] = index; return finish()
            }
            let raw = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
            let type = CFGetTypeID(raw)
            childTypeIDs.append(type)
            guard type == AXUIElementGetTypeID() else {
                report["invalid_copied_child_index"] = index; report["invalid_copied_child_cf_type_id"] = type
                return finish()
            }
            containsChild = containsChild || CFEqual(raw, child)
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return finish() }
        report["complete_requested_parent_children_range"] = true; report["copied_child_cf_type_ids"] = childTypeIDs
        report["copied_children_are_ax_elements"] = true
        report["failed_child_present_in_copied_parent_children"] = containsChild
        return finish()
    }

    static func children(_ element: AXUIElement, _ name: String, limit: Int,
                         deadline: TimeInterval) throws -> [AXUIElement] {
        try prepare(element, deadline: deadline)
        guard limit >= 0, limit <= 2_048 else {
            throw WorkspaceCanvasFixtureFailure("The public AX child query received an invalid finite bound.")
        }
        var count = 0
        let status = AXUIElementGetAttributeValueCount(element, name as CFString, &count)
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw WorkspaceCanvasFixtureFailure("The public AX child count exceeded its shared deadline.")
        }
        if status == .attributeUnsupported || status == .noValue { return [] }
        guard status == .success, count >= 0, count <= limit else {
            throw WorkspaceCanvasFixtureFailure("Public own-window \(name) failed or exceeded its bound: AXError \(status.rawValue), count \(count).")
        }
        guard count > 0 else { return [] }
        try prepare(element, deadline: deadline)
        var values: CFArray?
        let copied = AXUIElementCopyAttributeValues(element, name as CFString, 0, count, &values)
        guard copied == .success, let children = values as? [AXUIElement], children.count == count else {
            throw WorkspaceCanvasFixtureFailure("Public own-window \(name) did not return its actual bounded AX children: AXError \(copied.rawValue).")
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw WorkspaceCanvasFixtureFailure("The public AX child query exceeded its shared deadline.")
        }
        return children
    }

    static func actions(_ element: AXUIElement, deadline: TimeInterval) throws -> [String] {
        try prepare(element, deadline: deadline)
        var names: CFArray?
        let status = AXUIElementCopyActionNames(element, &names)
        guard status == .success, let actions = names as? [String], actions.count <= 64,
              actions.allSatisfy({ $0.utf8.count <= 256 }), ProcessInfo.processInfo.systemUptime < deadline else {
            throw WorkspaceCanvasFixtureFailure("The public AX action names failed or exceeded their bound: AXError \(status.rawValue).")
        }
        return actions
    }
}

@MainActor
private struct NativeWorkspaceDraftExportedAXSnapshot {
    let identifier: String?
    let title: String?
    let label: String?
    let placeholder: String?
    let value: Any?
    let enabled: Bool?
    let role: NSAccessibility.Role?
}

@MainActor
private final class NativeWorkspaceDraftExportedAXContext {
    private weak var owner: NSWindow?
    private weak var hosting: NSView?
    private let title: String
    let deadline: TimeInterval
    let windowElement: AXUIElement

    init?(fixture: NativeWorkspaceDraftFixture, deadline: TimeInterval) throws {
        let ownedTitle = fixture.window.title
        owner = fixture.window; hosting = fixture.hosting
        title = ownedTitle; self.deadline = deadline
        guard !ownedTitle.isEmpty, ownedTitle.utf8.count <= 256,
              fixture.window.contentView === fixture.hosting, fixture.hosting.window === fixture.window,
              NSApp.windows.filter({ $0.title == fixture.window.title }).count == 1 else {
            throw WorkspaceCanvasFixtureFailure("The semantic fixture does not own one exact uniquely titled NSWindow/NSHostingView.")
        }
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windows = try NativeWorkspaceDraftAXQuery.children(application, kAXWindowsAttribute, limit: 32, deadline: deadline)
        let matches = try windows.filter {
            try NativeWorkspaceDraftAXQuery.attribute($0, kAXTitleAttribute, deadline: deadline) as? String == fixture.window.title
        }
        guard matches.count <= 1 else {
            throw WorkspaceCanvasFixtureFailure("The current process exported duplicate AX windows with the exact owned fixture title.")
        }
        guard let element = matches.first else { return nil }
        windowElement = element
    }

    func requireOwner() throws {
        guard ProcessInfo.processInfo.systemUptime < deadline, let owner, let hosting,
              owner.title == title, owner.contentView === hosting, hosting.window === owner,
              NSApp.windows.filter({ $0.title == title }).count == 1 else {
            throw WorkspaceCanvasFixtureFailure("The exported AX observation lost its exact owned host/window or shared deadline.")
        }
    }

    func requireOwnedAncestor(_ element: AXUIElement, requiredIdentifier: String? = nil) throws {
        try requireOwner()
        var cursor = element
        var seen: [AXUIElement] = []
        var foundRequiredScope = requiredIdentifier == nil
        for _ in 0..<48 {
            guard !seen.contains(where: { CFEqual($0, cursor) }) else {
                throw WorkspaceCanvasFixtureFailure("The exported AX parent chain contains a cycle.")
            }
            seen.append(cursor)
            if let requiredIdentifier {
                if try NativeWorkspaceDraftAXQuery.attribute(cursor, kAXIdentifierAttribute, deadline: deadline) as? String == requiredIdentifier {
                    foundRequiredScope = true
                }
            }
            if CFEqual(cursor, windowElement) {
                guard foundRequiredScope else { throw WorkspaceCanvasFixtureFailure("The exported field does not descend from its exact owned native panel marker.") }
                return
            }
            guard let raw = try NativeWorkspaceDraftAXQuery.attribute(cursor, kAXParentAttribute, deadline: deadline),
                  CFGetTypeID(raw as CFTypeRef) == AXUIElementGetTypeID() else {
                throw WorkspaceCanvasFixtureFailure("The exported semantic node does not reach its exact owned AX window.")
            }
            cursor = raw as! AXUIElement
        }
        throw WorkspaceCanvasFixtureFailure("The exported AX parent chain exceeded its 48-node bound.")
    }

    func snapshot(_ element: AXUIElement) throws -> NativeWorkspaceDraftExportedAXSnapshot {
        try requireOwner()
        func string(_ attribute: String) throws -> String? {
            guard let raw = try NativeWorkspaceDraftAXQuery.attribute(element, attribute, deadline: deadline) else { return nil }
            guard let value = raw as? String, value.utf8.count <= 16 * 1_024 else {
                throw WorkspaceCanvasFixtureFailure("The actual AX scalar string is not a bounded string: \(attribute).")
            }
            return value
        }
        let rawValue = try NativeWorkspaceDraftAXQuery.attribute(element, kAXValueAttribute, deadline: deadline)
        if let string = rawValue as? String, string.utf8.count > 16 * 1_024 {
            throw WorkspaceCanvasFixtureFailure("The actual AX value exceeded its scalar byte bound.")
        }
        guard rawValue == nil || rawValue is String || rawValue is NSNumber else {
            throw WorkspaceCanvasFixtureFailure("The actual AX value is not a native scalar.")
        }
        let rawEnabled = try NativeWorkspaceDraftAXQuery.attribute(element, kAXEnabledAttribute, deadline: deadline)
        guard rawEnabled == nil || rawEnabled is Bool else {
            throw WorkspaceCanvasFixtureFailure("The actual AX enabled attribute is not a Boolean.")
        }
        let role = try string(kAXRoleAttribute)
        return NativeWorkspaceDraftExportedAXSnapshot(identifier: try string(kAXIdentifierAttribute),
            title: try string(kAXTitleAttribute), label: try string(kAXDescriptionAttribute),
            placeholder: try string(kAXPlaceholderValueAttribute), value: rawValue,
            enabled: rawEnabled as? Bool, role: role.map { NSAccessibility.Role(rawValue: $0) })
    }

    func actionForensics(_ element: AXUIElement) throws -> [String: Any] {
        try requireOwnedAncestor(element)
        let current = try snapshot(element)
        return ["object_type": "AXUIElement", "formal_bridge": false, "informal_bridge": false,
            "exported_ax_bridge": true, "identifier": current.identifier ?? "", "role": current.role?.rawValue ?? "",
            "enabled": current.enabled.map { $0 as Any } ?? NSNull(),
            "advertised_exported_actions": try NativeWorkspaceDraftAXQuery.actions(element, deadline: deadline)]
    }

    func press(_ element: AXUIElement) throws {
        try requireOwnedAncestor(element)
        let current = try snapshot(element)
        guard current.enabled == true, current.role == .button,
              try NativeWorkspaceDraftAXQuery.actions(element, deadline: deadline).contains(kAXPressAction) else {
            throw WorkspaceCanvasFixtureFailure("The actual exported control is not an enabled button advertising AXPress.")
        }
        try NativeWorkspaceDraftAXQuery.prepare(element, deadline: deadline)
        let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard status == .success, ProcessInfo.processInfo.systemUptime < deadline else {
            throw WorkspaceCanvasFixtureFailure("The actual exported AXPress failed or exceeded its deadline: AXError \(status.rawValue).")
        }
    }
}

@MainActor
private final class NativeWorkspaceDraftFixture {
    enum Page: Equatable { case manager, projects }
    let home: URL
    let suite: String
    let defaults: UserDefaults
    let preferences: NativeWorkspacePreferences
    let model: AppModel
    let workbench: WorkbenchPreferences
    let guidedMode: GuidedModeCoordinator
    let client: NativeWorkspaceDraftClient
    let recorder: NativeWorkspaceDraftBootstrapRecorder
    let hosting: NSHostingView<AnyView>
    let window: NSWindow

    init(page: Page) throws {
        let suiteName = "forge.workspace.positive-draft.tests.\(UUID().uuidString)"
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent("forge-native-workspace-positive-\(UUID().uuidString)")
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let clientOwner = try NativeWorkspaceDraftClient()
        let preferencesOwner = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
            panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: localDefaults)
        let workbenchOwner = WorkbenchPreferences(defaults: localDefaults)
        let guidedOwner = GuidedModeCoordinator(defaults: localDefaults)
        let recorderOwner = NativeWorkspaceDraftBootstrapRecorder()
        let bootstrap = AppBootstrapOperation(factory: {
            let app = try ForgeApp.bootstrap(home: homeURL, startTelemetry: false)
            recorderOwner.recordCreation()
            return app
        }, pluginStatus: { _ in nil })
        let modelOwner = AppModel(bootstrapOperation: bootstrap, bootstrapIntegration: .isolatedPresentation,
                                  diagnosticPaths: AppPaths(home: homeURL))
        modelOwner.autoRefresh = false
        let content: AnyView = page == .manager
            ? AnyView(ManagerSettingsView(initialSection: .settings))
            : AnyView(ProjectsOperatorView(client: clientOwner))
        let host = NSHostingView(rootView: AnyView(content.environmentObject(modelOwner)
            .environmentObject(workbenchOwner).environmentObject(guidedOwner)
            .environment(\.nativeWorkspacePreferences, preferencesOwner).graphiteWorkbench()))
        let ownedWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1_440, height: 960),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        ownedWindow.isReleasedWhenClosed = false
        ownedWindow.title = "Production workspace draft validation \(UUID().uuidString)"
        ownedWindow.contentView = host
        home = homeURL; suite = suiteName; defaults = localDefaults; recorder = recorderOwner
        preferences = preferencesOwner; model = modelOwner; client = clientOwner
        workbench = workbenchOwner; guidedMode = guidedOwner; hosting = host; window = ownedWindow
    }

    func close() async {
        window.endEditing(for: nil); _ = window.makeFirstResponder(nil)
        hosting.rootView = AnyView(EmptyView())
        window.orderOut(nil); window.contentView = nil; window.close()
        model.cancelBackgroundOperations()
        await model.stopBootstrap()
        model.telemetryBinding.detach()
        if let app = model.app {
            let report = await Task.detached { app.shutdown() }.value
            XCTAssertTrue(report.completed, "The isolated real application graph must shut down before its home is removed.")
            if report.completed { try? FileManager.default.removeItem(at: home) }
        } else { try? FileManager.default.removeItem(at: home) }
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class NativeWorkspaceDraftBootstrapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func recordCreation() { lock.lock(); count += 1; lock.unlock() }
    var creations: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private actor NativeWorkspaceDraftClient: OperatorManagerClientProtocol {
    static let projectID = "11111111-1111-4111-8111-111111111111"
    static let projectRoot = "/tmp/native-workspace-fixture-project"
    private let snapshotValue: OperatorSnapshot
    private let queueValue: OperatorInstructionQueue
    private var snapshots = 0
    private var repositoryWrites = 0
    private var otherMutations = 0
    init() throws {
        let project = """
        {"project_id":"11111111-1111-4111-8111-111111111111","display_name":"Native Draft Project","canonical_root":"/tmp/native-workspace-fixture-project","project_generation":4,"lifecycle_state":"active","bindings":[],"memory":{"state":"healthy","database_bytes":0,"record_count":0},"continuity":{"state":"ready","migration_state":"not_required"},"migration_warnings":[],"github_repository_url":null}
        """
        snapshotValue = try JSONDecoder().decode(OperatorSnapshot.self, from: Data("{\"projects\":[\(project)]}".utf8))
        queueValue = try JSONDecoder().decode(OperatorInstructionQueue.self, from: Data("{\"project_id\":\"11111111-1111-4111-8111-111111111111\",\"project_generation\":4,\"revision\":0,\"running\":false,\"packages\":[]}".utf8))
    }
    func observations() -> (snapshots: Int, repositoryWrites: Int, otherMutations: Int) { (snapshots, repositoryWrites, otherMutations) }
    func snapshot(limit: Int, cursor: String?) async throws -> OperatorSnapshot { snapshots += 1; return snapshotValue }
    func instructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue {
        guard projectID == Self.projectID, generation == 4 else { throw unsupported }
        return queueValue
    }
    func updateProjectRepository(projectID: String, generation: UInt64, location: String?) async throws -> OperatorProject { repositoryWrites += 1; throw unsupported }
    func autonomyStatus() async throws -> OperatorAutonomySummary { throw unsupported }
    func settings() async throws -> ManagerSettings { throw unsupported }
    func updateSettings(_ patch: ManagerSettingsPatch) async throws -> ManagerSettings { otherMutations += 1; throw unsupported }
    func registerProject(_ request: OperatorProjectRegistrationRequest) async throws -> OperatorProjectRegistrationOutcome { otherMutations += 1; throw unsupported }
    func projectStatus(projectID: String) async throws -> OperatorProject { guard projectID == Self.projectID else { throw unsupported }; return snapshotValue.projects[0] }
    func resetProject(projectID: String, generation: UInt64) async throws -> OperatorResetReceipt { otherMutations += 1; throw unsupported }
    func relinkProject(projectID: String, generation: UInt64, path: String) async throws -> OperatorRelinkReceipt { otherMutations += 1; throw unsupported }
    func startRun(_ request: OperatorRunStartRequest) async throws -> OperatorRun { otherMutations += 1; throw unsupported }
    func runStatus(runID: String) async throws -> OperatorRun { throw unsupported }
    func controlRun(runID: String, action: OperatorRunControlAction) async throws -> OperatorRun { otherMutations += 1; throw unsupported }
    func cancelRuntimeJob(jobID: String) async throws -> OperatorRuntimeJob { otherMutations += 1; throw unsupported }
    func providerConfiguration() async throws -> ProviderConfigurationSnapshot { throw unsupported }
    func updateProviderConfiguration(_ update: ProviderConfigurationUpdate) async throws -> ProviderConfigurationSnapshot { otherMutations += 1; throw unsupported }
    func providerModels() async throws -> ProviderModelInventory { throw unsupported }
    func probeProvider(adapterID: String, mode: OperatorProviderProbeMode) async throws -> OperatorProvider { throw unsupported }
    private var unsupported: OperatorManagerClientError { .capabilityUnavailable("This native draft fixture supplies read-only project data only.") }
}
#endif

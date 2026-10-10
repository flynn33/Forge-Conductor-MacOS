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

    func testOwnedAppKitAndSwiftUIOrdinaryExportedIdentifierComparisonDiagnostic() async throws {
        for technology in ["AppKit", "SwiftUI"] {
            try await nativeDraftOrdinaryExportedIdentifierComparison(technology: technology)
        }
    }

    private func nativeDraftOrdinaryExportedIdentifierComparison(technology: String) async throws {
        let identifier = "native-ordinary-exported-comparison-control"
        let root: NSView
        if technology == "AppKit" {
            let button = NSButton(title: "Identifier comparison control", target: nil, action: nil)
            button.setAccessibilityIdentifier(identifier)
            root = button
        } else {
            root = NSHostingView(rootView: Button("Identifier comparison control") {}.accessibilityIdentifier(identifier))
        }
        guard window == nil else {
            throw WorkspaceCanvasFixtureFailure("The synthetic comparison already has an owned test window.")
        }
        let owned = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 320, height: 120),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owned.isReleasedWhenClosed = false
        let ownedTitle = "Synthetic ordinary/exported comparison \(technology) \(UUID().uuidString)"
        owned.title = ownedTitle; owned.contentView = root; window = owned
        defer {
            owned.orderOut(nil); owned.contentView = nil; owned.close()
            if window === owned { window = nil }
        }
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 2
        var report: [String: Any] = [
            "classification": "Separate synthetic identifier comparison only; no Forge UI qualification or native/exported object correspondence claim",
            "technology": technology, "process_pid": ProcessInfo.processInfo.processIdentifier,
            "expected_identifier": identifier, "owned_window_title": ownedTitle,
            "read_order": ["one ordinary native tree and Identifier pass", "one complete exported whole-window Identifier walk"],
            "shared_deadline_seconds": 2, "initial_settle_included_in_deadline": true,
            "single_exported_message_timeout_seconds": 0.1, "node_limit_per_tree": 64,
            "ordinary_existing_depth_limit": 48, "exported_depth_limit": 16, "window_limit": 32,
            "one_initial_settle_milliseconds": 40, "retry_count": 0,
            "ordinary_complete": false, "exported_complete": false, "comparison_complete": false,
        ]
        defer {
            report["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
            report["within_shared_deadline"] = ProcessInfo.processInfo.systemUptime < deadline
            nativeDraftRetainMeasurement(report, name: "native-ordinary-exported-comparison-" + technology)
        }
        func requireOwner() throws {
            guard ProcessInfo.processInfo.systemUptime < deadline, owned.title == ownedTitle,
                  owned.contentView === root, root.window === owned, owned.isVisible,
                  NSApp.windows.filter({ $0.title == ownedTitle }).count == 1 else {
                throw WorkspaceCanvasFixtureFailure("The synthetic identifier comparison lost its exact window/root or shared deadline.")
            }
        }
        do {
            report["phase"] = "initial-settle"
            NSApp.activate(ignoringOtherApps: true)
            owned.makeKeyAndOrderFront(nil); owned.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            root.layoutSubtreeIfNeeded()
            try requireOwner()
            guard owned.isKeyWindow else {
                throw WorkspaceCanvasFixtureFailure("The synthetic identifier comparison did not expose its owned key window.")
            }
            report["phase"] = "ordinary-native-tree"
            var ordinaryMatches = 0, appKitMatchIsOwnedRoot = false
            do {
                let nodes = try nativeDraftAccessibilityTree(root, deadline: deadline, limit: 64)
                var rows: [[String: Any]] = []
                for (ordinal, node) in nodes.enumerated() {
                    try requireOwner()
                    let observedIdentifier = node.identifier
                    let matches = observedIdentifier == identifier
                    rows.append(["ordinal": ordinal,
                        "object_type": String(String(reflecting: type(of: node.object)).prefix(128)),
                        "identifier": observedIdentifier.map { String($0.prefix(128)) as Any } ?? NSNull(),
                        "matches_expected_identifier": matches])
                    if matches {
                        ordinaryMatches += 1
                        if node.object === root { appKitMatchIsOwnedRoot = true }
                    }
                }
                try requireOwner()
                report["ordinary_complete"] = true; report["ordinary_nodes"] = rows
                report["ordinary_matching_identifier_count"] = ordinaryMatches
                report["AppKit_ordinary_match_is_owned_NSButton"] = technology == "AppKit" ? appKitMatchIsOwnedRoot as Any : NSNull()
            }
            guard ordinaryMatches <= 1 else {
                throw WorkspaceCanvasFixtureFailure("The synthetic ordinary bridge returned duplicate expected identifiers.")
            }
            report["phase"] = "exported-whole-window-tree"
            guard let context = try NativeWorkspaceDraftExportedAXContext(window: owned, hosting: root, deadline: deadline) else {
                throw WorkspaceCanvasFixtureFailure("The synthetic comparison did not find its exact exported own-process window.")
            }
            var pending: [(AXUIElement, [Int])] = [(context.windowElement, [])]
            var seen: [AXUIElement] = [], rows: [[String: Any]] = [], matches: [AXUIElement] = []
            while let (element, path) = pending.popLast() {
                try requireOwner(); try context.requireOwner()
                guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
                guard seen.count < 64, path.count <= 16 else {
                    throw WorkspaceCanvasFixtureFailure("The synthetic exported tree exceeded its 64-node/16-level bound.")
                }
                seen.append(element)
                let raw = try NativeWorkspaceDraftAXQuery.attribute(element, kAXIdentifierAttribute, deadline: deadline)
                guard raw == nil || raw is String else {
                    throw WorkspaceCanvasFixtureFailure("The synthetic exported Identifier is not a string or absent value.")
                }
                let observedIdentifier = raw as? String
                rows.append(["visit_index": seen.count - 1, "discovery_path": path,
                    "identifier": observedIdentifier.map { String($0.prefix(128)) as Any } ?? NSNull(),
                    "matches_expected_identifier": observedIdentifier == identifier])
                report["exported_nodes"] = rows
                if observedIdentifier == identifier { matches.append(element) }
                let children = try NativeWorkspaceDraftAXQuery.children(element, kAXChildrenAttribute,
                    limit: 64 - seen.count - pending.count, deadline: deadline)
                pending.append(contentsOf: children.enumerated().map { ($0.element, path + [$0.offset]) })
            }
            try requireOwner(); try context.requireOwner()
            report["exported_complete"] = true; report["exported_matching_identifier_count"] = matches.count
            guard matches.count == 1 else {
                throw WorkspaceCanvasFixtureFailure("The synthetic exported tree did not contain exactly one expected identifier.")
            }
            try context.requireOwnedAncestor(matches[0])
            let role = try NativeWorkspaceDraftAXQuery.attribute(matches[0], kAXRoleAttribute, deadline: deadline) as? String
            report["exported_matching_role"] = role.map { $0 as Any } ?? NSNull()
            guard role == NSAccessibility.Role.button.rawValue else {
                throw WorkspaceCanvasFixtureFailure("The synthetic exported identified control is not an AXButton.")
            }
            guard technology != "AppKit" || (ordinaryMatches == 1 && appKitMatchIsOwnedRoot) else {
                throw WorkspaceCanvasFixtureFailure("The AppKit ordinary positive control did not return its exact owned NSButton identifier.")
            }
            try requireOwner(); try context.requireOwner()
            report["phase"] = "completed"; report["comparison_complete"] = true
        } catch {
            report["error_type"] = String(String(reflecting: type(of: error)).prefix(128))
            report["error_description"] = String(String(describing: error).prefix(4_096))
            throw error
        }
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

    func testProductionManagerOwnedEventDraftSurvivesWorkspaceAndSectionTransitions() async throws {
        do {
            continueAfterFailure = true
            let flowDeadline = ProcessInfo.processInfo.systemUptime + 45
            nativeDraftStage("manager.fixture.create")
            defer { nativeDraftStage("manager.test.return-from-" + nativeDraftCurrentStage) }
            let fixture = try NativeWorkspaceDraftFixture(page: .manager)
            draftFixture = fixture
            nativeDraftStage("bootstrap.await-success")
            try await exposeNativeDraftFixture(fixture)
            try nativeOwnedRequireOwner(fixture, deadline: flowDeadline)
            nativeDraftStage("bootstrap.published-success")
            let app = try XCTUnwrap(fixture.model.app)
            let originalConfiguration = try Data(contentsOf: app.paths.configJSON)
            let originalHost = fixture.model.setHost
            let draft = "native-workspace-manager-draft.invalid"
            nativeDraftStage("default.field.lookup")
            let field = try await nativeOwnedField(in: fixture.hosting, identifier: "Dashboard host",
                                                   placeholder: "Dashboard host", fixture: fixture, deadline: flowDeadline)
            try nativeOwnedEditField(field, value: draft, in: fixture.window, fixture: fixture, deadline: flowDeadline)
            try await nativeOwnedWait("The real Manager field did not update its staged AppModel value.", deadline: flowDeadline) {
                try fixture.model.setHost == draft && field.stringValue == draft
            }
            nativeDraftStage("edit.binding-confirmed.default-to-custom.begin")
            let layout = nativeDraftLayout(viewID: "manager.settings")
            try fixture.preferences.save(layout)
            nativeDraftStage("default-to-custom.preference-saved")
            let document = try await nativeOwnedDocument(fixture, panelID: "manager-dashboard-settings", deadline: flowDeadline)
            let panel = try XCTUnwrap(document.panelHosts["manager-dashboard-settings"])
            let hosting = panel.hostingView
            nativeDraftStage("custom.field.lookup")
            let customField = try await nativeOwnedField(in: hosting, identifier: "Dashboard host",
                                                         placeholder: "Dashboard host", fixture: fixture, deadline: flowDeadline)
            XCTAssertEqual((try customField.stringValue), draft)
            nativeDraftStage("custom.hide.begin")
            try await nativeOwnedHide(panel, fixture: fixture, deadline: flowDeadline)
            nativeDraftStage("custom.hide.native-action-returned")
            try await nativeOwnedWait("The actual native Hide action did not hide Manager settings.", deadline: flowDeadline) { panel.isHidden }
            XCTAssertFalse(try XCTUnwrap(fixture.preferences.activeLayout(for: "manager.settings")?
                .panels.first { $0.id == "manager-dashboard-settings" }).isVisible)
            try fixture.preferences.setShown(true, for: "manager-dashboard-settings", in: "manager.settings")
            try await nativeOwnedWait("Manager settings did not resume from the retained native host.", deadline: flowDeadline) { !panel.isHidden }
            XCTAssertTrue(panel.hostingView === hosting)
            XCTAssertEqual((try customField.stringValue), draft)
            nativeDraftStage("named-layout.save.begin")
            let named = try fixture.preferences.saveAs(try XCTUnwrap(fixture.preferences.activeLayout(for: "manager.settings")),
                                                       named: "Manager Native Draft")
            try await nativeOwnedWait("The named Manager layout did not become active.", deadline: flowDeadline) {
                fixture.preferences.activeLayout(for: "manager.settings")?.id == named
            }
            let namedFrame = NativeWorkspaceFrame(x: 380, y: 60, width: 860, height: 440)
            try fixture.preferences.setFrame(namedFrame, for: "manager-dashboard-settings", in: "manager.settings")
            try await nativeOwnedWait("The named Manager geometry did not reach the actual panel.", deadline: flowDeadline) { panel.frame == namedFrame.nativeRect }
            try fixture.preferences.activate(layout.id, for: "manager.settings")
            try await nativeOwnedWait("The original Manager layout did not reach the actual panel.", deadline: flowDeadline) {
                panel.frame == layout.panels.first { $0.id == "manager-dashboard-settings" }?.frame.nativeRect
            }
            try fixture.preferences.activate(named, for: "manager.settings")
            try await nativeOwnedWait("Named layout changes replaced the Manager binding.", deadline: flowDeadline) {
                try panel.frame == namedFrame.nativeRect && panel.hostingView === hosting
                    && customField.stringValue == draft && fixture.model.setHost == draft
            }
            nativeDraftStage("manager.restore-default.begin")
            try fixture.preferences.reset("manager.settings")
            try await nativeOwnedWait("Default restoration did not dismantle Manager's custom canvas.", deadline: flowDeadline) {
                try self.nativeOwnedViews(fixture.hosting, fixture: fixture, deadline: flowDeadline).allSatisfy { !($0 is NativeWorkspaceDocumentView) }
            }
            let defaultField = try await nativeOwnedField(in: fixture.hosting, identifier: "Dashboard host",
                                                          placeholder: "Dashboard host", fixture: fixture, deadline: flowDeadline)
            XCTAssertEqual((try defaultField.stringValue), draft)
            nativeDraftStage("manager.section-transitions.begin")
            for (section, title) in [("shell", "Project Shell"), ("folders", "Authorized Folders"),
                                      ("workbench", "Workbench"), ("settings", "Settings")] {
                nativeDraftStage("manager.section." + section + ".press")
                try await nativeOwnedPress("manager-section-" + section, in: fixture, deadline: flowDeadline)
                try await nativeOwnedRequireManagerTitle(title, in: fixture, deadline: flowDeadline)
            }
            let resumed = try await nativeOwnedField(in: fixture.hosting, identifier: "Dashboard host",
                                                     placeholder: "Dashboard host", fixture: fixture, deadline: flowDeadline)
            XCTAssertEqual((try resumed.stringValue), draft)
            XCTAssertEqual(fixture.model.setHost, draft)
            XCTAssertNil(fixture.model.manager)
            XCTAssertNil(fixture.model.remoteManager)
            nativeDraftStage("manager.save-refusal.begin")
            try await nativeOwnedPress("settings-save", in: fixture, deadline: flowDeadline)
            try await nativeOwnedWait("The queued Save did not reach the actual unavailable-manager result.", deadline: flowDeadline) {
                fixture.model.managerMessage == "Manager is unavailable"
            }
            XCTAssertEqual(fixture.model.managerMessage, "Manager is unavailable")
            XCTAssertEqual(try Data(contentsOf: app.paths.configJSON), originalConfiguration,
                           "The isolated native presentation must not turn a staged edit into a backend save.")
            nativeDraftStage("manager.reload.begin")
            try await nativeOwnedPress("settings-reload", in: fixture, deadline: flowDeadline)
            try await nativeOwnedWait("Explicit native Reload did not restore the actual bootstrap configuration.", deadline: flowDeadline) {
                try !fixture.model.isUpdatingSettings && fixture.model.setHost == originalHost
                    && resumed.stringValue == originalHost
            }
            XCTAssertEqual(fixture.recorder.creations, 1)
            XCTAssertTrue(fixture.model.app === app)
            try nativeOwnedRequireOwner(fixture, deadline: flowDeadline)
            try nativeOwnedRecord(["classification": "Independent real draft route completed execution; actual XCTest assertions determine its outcome, original exported-AX gates stay separate",
                "test_method": "testProductionManagerOwnedEventDraftSurvivesWorkspaceAndSectionTransitions", "stage": nativeDraftCurrentStage,
                "bootstrap_creations": fixture.recorder.creations, "event_route": "NSApp.postEvent owned-window pointer pair; actual AppKit editor",
            ], name: "native-owned-complete-flow-execution")
        } catch {
            let actual = error as NSError
            nativeDraftRetainMeasurement([
                "classification": "Independent real owned-event draft case failure; identical error rethrown, original exported-AX methods unchanged",
                "test_method": "testProductionManagerOwnedEventDraftSurvivesWorkspaceAndSectionTransitions",
                "stage": nativeDraftCurrentStage,
                "error_type": String(String(reflecting: type(of: error)).prefix(1_024)),
                "error_description": String(String(describing: error).prefix(4_096)),
                "NSError_domain": String(actual.domain.prefix(1_024)),
                "NSError_code": actual.code,
                "task_cancelled": Task.isCancelled,
            ], name: "native-owned-complete-flow-boundary-error")
            throw error
        }
    }

    func testProductionProjectsOwnedEventRepositoryDraftSurvivesWorkspaceWithSinglePageOwner() async throws {
        do {
            continueAfterFailure = true
            let flowDeadline = ProcessInfo.processInfo.systemUptime + 45
            nativeDraftStage("projects.fixture.create")
            defer { nativeDraftStage("projects.test.return-from-" + nativeDraftCurrentStage) }
            let fixture = try NativeWorkspaceDraftFixture(page: .projects)
            draftFixture = fixture
            nativeDraftStage("bootstrap.await-success")
            try await exposeNativeDraftFixture(fixture)
            try nativeOwnedRequireOwner(fixture, deadline: flowDeadline)
            nativeDraftStage("bootstrap.published-success")
            let draft = "https://github.com/fixture/native-workspace-unsaved"
            nativeDraftStage("projects.default-viewport.capture.begin")
            try nativeDraftRecordViewport(fixture, name: "projects-before-default-field")
            nativeDraftStage("projects.default-viewport.capture.returned")
            nativeDraftStage("default.field.lookup")
            let field = try await nativeOwnedField(in: fixture.hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location", fixture: fixture, deadline: flowDeadline)
            try nativeOwnedEditField(field, value: draft, in: fixture.window, fixture: fixture, deadline: flowDeadline)
            try await nativeOwnedWait("The real Projects repository field did not retain the native edit.", deadline: flowDeadline) { (try field.stringValue) == draft }
            try await nativeOwnedRequireProjectIdentity(fixture, deadline: flowDeadline)
            nativeDraftStage("edit.binding-confirmed.default-to-custom.begin")
            let layout = nativeDraftLayout(viewID: "projects")
            try fixture.preferences.save(layout)
            nativeDraftStage("default-to-custom.preference-saved")
            let document = try await nativeOwnedDocument(fixture, panelID: "projects-repository", deadline: flowDeadline)
            let panel = try XCTUnwrap(document.panelHosts["projects-repository"])
            let hosting = panel.hostingView
            nativeDraftStage("custom.field.lookup")
            let customField = try await nativeOwnedField(in: hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location", fixture: fixture, deadline: flowDeadline)
            XCTAssertEqual((try customField.stringValue), draft)
            nativeDraftStage("custom.hide.begin")
            try await nativeOwnedHide(panel, fixture: fixture, deadline: flowDeadline)
            nativeDraftStage("custom.hide.native-action-returned")
            try await nativeOwnedWait("The actual native Hide action did not hide the repository panel.", deadline: flowDeadline) { panel.isHidden }
            try fixture.preferences.setShown(true, for: "projects-repository", in: "projects")
            try await nativeOwnedWait("The retained repository host did not resume.", deadline: flowDeadline) { !panel.isHidden }
            XCTAssertTrue(panel.hostingView === hosting)
            XCTAssertEqual((try customField.stringValue), draft)
            nativeDraftStage("named-layout.save.begin")
            let named = try fixture.preferences.saveAs(try XCTUnwrap(fixture.preferences.activeLayout(for: "projects")),
                                                       named: "Projects Native Draft")
            let namedFrame = NativeWorkspaceFrame(x: 360, y: 260, width: 940, height: 320)
            try fixture.preferences.setFrame(namedFrame, for: "projects-repository", in: "projects")
            try await nativeOwnedWait("The named repository geometry did not reach the actual panel.", deadline: flowDeadline) { panel.frame == namedFrame.nativeRect }
            try fixture.preferences.activate(layout.id, for: "projects")
            try await nativeOwnedWait("The original repository geometry did not reach the actual panel.", deadline: flowDeadline) {
                panel.frame == layout.panels.first { $0.id == "projects-repository" }?.frame.nativeRect
            }
            try fixture.preferences.activate(named, for: "projects")
            try await nativeOwnedWait("Named layouts lost the unsaved repository binding.", deadline: flowDeadline) {
                try panel.frame == namedFrame.nativeRect && panel.hostingView === hosting && customField.stringValue == draft
            }
            try fixture.preferences.reset("projects")
            try await nativeOwnedWait("Default restoration did not dismantle Projects' custom canvas.", deadline: flowDeadline) {
                try self.nativeOwnedViews(fixture.hosting, fixture: fixture, deadline: flowDeadline).allSatisfy { !($0 is NativeWorkspaceDocumentView) }
            }
            let restored = try await nativeOwnedField(in: fixture.hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location", fixture: fixture, deadline: flowDeadline)
            XCTAssertEqual((try restored.stringValue), draft)
            try await nativeOwnedRequireProjectIdentity(fixture, deadline: flowDeadline)
            try fixture.preferences.activate(named, for: "projects")
            let reactivated = try await nativeOwnedField(in: fixture.hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location", fixture: fixture, deadline: flowDeadline)
            XCTAssertEqual((try reactivated.stringValue), draft)
            try fixture.preferences.reset("projects")
            let finalDefault = try await nativeOwnedField(in: fixture.hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location", fixture: fixture, deadline: flowDeadline)
            XCTAssertEqual((try finalDefault.stringValue), draft)
            nativeDraftStage("projects.all-transitions-complete.owner-observations")
            let observations = await fixture.client.observations()
            XCTAssertEqual(observations.snapshots, 1,
                           "Layout presentation changes must not recreate/reload the page StateObject.")
            XCTAssertEqual(observations.repositoryWrites, 0)
            XCTAssertEqual(observations.otherMutations, 0)
            XCTAssertEqual(fixture.recorder.creations, 1)
            try nativeOwnedRequireOwner(fixture, deadline: flowDeadline)
            try nativeOwnedRecord(["classification": "Independent real draft route completed execution; actual XCTest assertions determine its outcome, original exported-AX gates stay separate",
                "test_method": "testProductionProjectsOwnedEventRepositoryDraftSurvivesWorkspaceWithSinglePageOwner", "stage": nativeDraftCurrentStage,
                "bootstrap_creations": fixture.recorder.creations, "event_route": "NSApp.postEvent owned-window pointer pair; actual AppKit editor",
            ], name: "native-owned-complete-flow-execution")
        } catch {
            let actual = error as NSError
            nativeDraftRetainMeasurement([
                "classification": "Independent real owned-event draft case failure; identical error rethrown, original exported-AX methods unchanged",
                "test_method": "testProductionProjectsOwnedEventRepositoryDraftSurvivesWorkspaceWithSinglePageOwner",
                "stage": nativeDraftCurrentStage,
                "error_type": String(String(reflecting: type(of: error)).prefix(1_024)),
                "error_description": String(String(describing: error).prefix(4_096)),
                "NSError_domain": String(actual.domain.prefix(1_024)),
                "NSError_code": actual.code,
                "task_cancelled": Task.isCancelled,
            ], name: "native-owned-complete-flow-boundary-error")
            throw error
        }
    }

    private func nativeOwnedRequireOwner(_ fixture: NativeWorkspaceDraftFixture, deadline: TimeInterval,
                                         requireKey: Bool = false) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline,
              fixture.window.contentView === fixture.hosting, fixture.hosting.window === fixture.window,
              NSApp.windows.filter({ $0.title == fixture.window.title }).count == 1,
              !requireKey || (NSApp.isActive && fixture.window.isVisible && fixture.window.isKeyWindow
                  && NSApp.keyWindow === fixture.window) else {
            throw WorkspaceCanvasFixtureFailure("The independent native route lost its exact owned host/window, key window or shared deadline.")
        }
    }

    private func nativeOwnedWait(_ message: String, deadline: TimeInterval, _ condition: () throws -> Bool) async throws {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        while ProcessInfo.processInfo.systemUptime < end {
            try Task.checkCancellation()
            if try condition() {
                guard ProcessInfo.processInfo.systemUptime < end else { throw WorkspaceCanvasFixtureFailure(message) }
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WorkspaceCanvasFixtureFailure(message)
    }

    private func nativeOwnedViews(_ root: NSView, fixture: NativeWorkspaceDraftFixture,
                                  deadline: TimeInterval) throws -> [NSView] {
        try nativeOwnedRequireOwner(fixture, deadline: deadline)
        guard root.window === fixture.window, root === fixture.hosting || root.isDescendant(of: fixture.hosting) else {
            throw WorkspaceCanvasFixtureFailure("The independent native view root is outside its owned production host.")
        }
        var pending: [(NSView, Int)] = [(root, 0)], result: [NSView] = []
        while let (view, depth) = pending.popLast() {
            try nativeOwnedRequireOwner(fixture, deadline: deadline)
            guard result.count < 2_048, depth <= 48,
                  view.subviews.count <= 2_048 - result.count - pending.count - 1 else {
                throw WorkspaceCanvasFixtureFailure("The independent native view walk exceeded its 2048-view/48-level bound.")
            }
            result.append(view); pending.append(contentsOf: view.subviews.map { ($0, depth + 1) })
        }
        return result
    }

    private func nativeOwnedField(in root: NSView, identifier: String, placeholder: String,
                                  expectedLabel: String? = nil, fixture: NativeWorkspaceDraftFixture,
                                  deadline: TimeInterval) async throws -> NativeWorkspaceDraftField {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        var observedNativeMetadata = false
        repeat {
            root.layoutSubtreeIfNeeded()
            let fields = try nativeOwnedViews(root, fixture: fixture, deadline: end).compactMap { $0 as? NSTextField }.filter {
                $0.isEditable && ($0.accessibilityIdentifier() == identifier || $0.accessibilityLabel() == identifier
                    || (expectedLabel != nil && $0.accessibilityLabel() == expectedLabel) || $0.placeholderString == placeholder)
            }
            guard fields.count <= 1 else { throw WorkspaceCanvasFixtureFailure("Duplicate actual AppKit draft field in the independent route.") }
            if let field = fields.first, field.isEnabled, !field.isHiddenOrHasHiddenAncestor {
                try nativeOwnedRequireOwner(fixture, deadline: end)
                return NativeWorkspaceDraftField(node: try NativeWorkspaceDraftAccessibilityNode(field))
            }
            if !observedNativeMetadata {
                // Observe public ordinary metadata once, then still require a real AppKit field/editor.
                _ = try nativeOwnedTree(root, fixture: fixture, deadline: end)
                observedNativeMetadata = true
                continue
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < end
        throw WorkspaceCanvasFixtureFailure("The independent route did not find one enabled actual AppKit draft field: " + identifier)
    }

    private func nativeOwnedEditField(_ control: NativeWorkspaceDraftField, value: String, in window: NSWindow,
                                      fixture: NativeWorkspaceDraftFixture, deadline: TimeInterval) throws {
        try nativeOwnedRequireOwner(fixture, deadline: deadline, requireKey: true)
        guard window === fixture.window, let field = control.node.object as? NSTextField,
              field.window === window, field.isDescendant(of: fixture.hosting), field.isEditable, field.isEnabled,
              window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView,
              window.firstResponder === editor, editor.window === window else {
            throw WorkspaceCanvasFixtureFailure("The independent draft route did not own an actual AppKit field editor.")
        }
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        window.endEditing(for: field)
        guard window.makeFirstResponder(nil) else { throw WorkspaceCanvasFixtureFailure("The actual AppKit edit refused focus-loss commit.") }
        try nativeOwnedRequireOwner(fixture, deadline: deadline)
    }

    private func nativeOwnedDocument(_ fixture: NativeWorkspaceDraftFixture, panelID: String,
                                     deadline: TimeInterval) async throws -> NativeWorkspaceDocumentView {
        try await nativeOwnedWait("The independent route did not mount its real production panel.", deadline: deadline) {
            fixture.hosting.layoutSubtreeIfNeeded()
            return try self.nativeOwnedViews(fixture.hosting, fixture: fixture, deadline: deadline)
                .compactMap { $0 as? NativeWorkspaceDocumentView }.first?.panelHosts[panelID] != nil
        }
        return try XCTUnwrap(nativeOwnedViews(fixture.hosting, fixture: fixture, deadline: deadline)
            .compactMap { $0 as? NativeWorkspaceDocumentView }.first)
    }

    private func nativeOwnedTree(_ root: AnyObject, fixture: NativeWorkspaceDraftFixture, deadline: TimeInterval,
                                 limit: Int = 2_048) throws -> [NativeWorkspaceDraftAccessibilityNode] {
        try nativeOwnedRequireOwner(fixture, deadline: deadline)
        var pending: [(NativeWorkspaceDraftAccessibilityNode, Int)] = [(try NativeWorkspaceDraftAccessibilityNode(root), 0)]
        var seen = Set<ObjectIdentifier>(), nodes: [NativeWorkspaceDraftAccessibilityNode] = []
        while let (node, depth) = pending.popLast() {
            try nativeOwnedRequireOwner(fixture, deadline: deadline)
            guard seen.insert(ObjectIdentifier(node.object)).inserted else { continue }
            guard nodes.count < limit, depth <= 48, node.exportedAX == nil else {
                throw WorkspaceCanvasFixtureFailure("The independent public native tree exceeded its bound or used exported AX.")
            }
            nodes.append(node)
            let children = try node.children() // Public ordinary children only; no navigation-order or contents queries.
            try nativeOwnedRequireOwner(fixture, deadline: deadline)
            guard children.count <= limit - nodes.count - pending.count else {
                throw WorkspaceCanvasFixtureFailure("The independent native child list exceeded its remaining bound.")
            }
            for child in children {
                let object: AnyObject
                if let formal = child as? any NSAccessibilityProtocol { object = formal as AnyObject }
                else if let native = child as? NSObject { object = native }
                else { throw WorkspaceCanvasFixtureFailure("A public native child does not provide an actual native object; boxing refused.") }
                pending.append((try NativeWorkspaceDraftAccessibilityNode(object), depth + 1))
            }
        }
        return nodes
    }

    private func nativeOwnedNode(_ identifier: String, fixture: NativeWorkspaceDraftFixture,
                                 deadline: TimeInterval) async throws -> NativeWorkspaceDraftAccessibilityNode {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        repeat {
            fixture.hosting.layoutSubtreeIfNeeded()
            let nodes = try nativeOwnedTree(fixture.hosting, fixture: fixture, deadline: end)
            var matches: [NativeWorkspaceDraftAccessibilityNode] = []
            for node in nodes {
                try nativeOwnedRequireOwner(fixture, deadline: end)
                if node.identifier == identifier { matches.append(node) }
                try nativeOwnedRequireOwner(fixture, deadline: end)
            }
            guard matches.count <= 1 else { throw WorkspaceCanvasFixtureFailure("Duplicate independent native identifier: " + identifier) }
            if let node = matches.first {
                try nativeOwnedRequireAncestor(node.object, fixture: fixture, deadline: end)
                return node
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < end
        throw WorkspaceCanvasFixtureFailure("The independent route did not expose its displayed native identifier: " + identifier)
    }

    private func nativeOwnedParent(_ object: AnyObject, fixture: NativeWorkspaceDraftFixture,
                                   deadline: TimeInterval) throws -> AnyObject? {
        try nativeOwnedRequireOwner(fixture, deadline: deadline)
        let raw: Any?
        if let formal = object as? any NSAccessibilityProtocol { raw = formal.accessibilityParent() }
        else if let native = object as? NSObject {
            let names = native.accessibilityAttributeNames()
            guard names.count <= 128 else { throw WorkspaceCanvasFixtureFailure("The public parent attribute list exceeded its bound.") }
            raw = names.contains(.parent) ? native.accessibilityAttributeValue(.parent) : nil
        } else { throw WorkspaceCanvasFixtureFailure("The independent parent chain does not provide a public native bridge.") }
        try nativeOwnedRequireOwner(fixture, deadline: deadline)
        guard let raw else { return nil }
        if let formal = raw as? any NSAccessibilityProtocol { return formal as AnyObject }
        if let native = raw as? NSObject { return native }
        throw WorkspaceCanvasFixtureFailure("The public native parent does not provide an actual native object.")
    }

    private func nativeOwnedRequireAncestor(_ object: AnyObject, fixture: NativeWorkspaceDraftFixture,
                                            deadline: TimeInterval, requiredButton: String? = nil) throws {
        var cursor = object, retained: [AnyObject] = []
        var seen = Set<ObjectIdentifier>(), foundButton = requiredButton == nil
        for _ in 0..<48 {
            try nativeOwnedRequireOwner(fixture, deadline: deadline)
            guard seen.insert(ObjectIdentifier(cursor)).inserted else { throw WorkspaceCanvasFixtureFailure("The public native parent chain contains a cycle.") }
            retained.append(cursor)
            let node = try NativeWorkspaceDraftAccessibilityNode(cursor)
            if let requiredButton, node.identifier == requiredButton {
                guard node.role == .button, node.enabled == true else { throw WorkspaceCanvasFixtureFailure("The semantic hit target is not the enabled identified native button.") }
                foundButton = true
            }
            if cursor === fixture.window {
                guard foundButton else { throw WorkspaceCanvasFixtureFailure("The public semantic hit does not reach its identified native button.") }
                return
            }
            if cursor is NSWindow { throw WorkspaceCanvasFixtureFailure("The public native target reaches a different window.") }
            guard let parent = try nativeOwnedParent(cursor, fixture: fixture, deadline: deadline) else {
                throw WorkspaceCanvasFixtureFailure("The public native target does not reach the exact owned window.")
            }
            cursor = parent
        }
        throw WorkspaceCanvasFixtureFailure("The public native parent chain exceeded its 48-object bound.")
    }

    private func nativeOwnedFrame(_ object: AnyObject, fixture: NativeWorkspaceDraftFixture,
                                  deadline: TimeInterval) throws -> NSRect {
        try nativeOwnedRequireOwner(fixture, deadline: deadline)
        let frame: NSRect
        if let formal = object as? any NSAccessibilityProtocol { frame = formal.accessibilityFrame() }
        else if let native = object as? NSObject {
            let names = native.accessibilityAttributeNames()
            guard names.count <= 128, names.contains(.position), names.contains(.size),
                  let position = native.accessibilityAttributeValue(.position) as? NSValue,
                  let size = native.accessibilityAttributeValue(.size) as? NSValue else {
                throw WorkspaceCanvasFixtureFailure("The public native target does not advertise measured screen geometry.")
            }
            frame = NSRect(origin: position.pointValue, size: size.sizeValue)
        } else { throw WorkspaceCanvasFixtureFailure("The native target has no public frame bridge.") }
        try nativeOwnedRequireOwner(fixture, deadline: deadline)
        let viewport = fixture.window.convertToScreen(fixture.hosting.convert(fixture.hosting.visibleRect, to: nil))
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0, !NSIntersectionRect(frame, viewport).isEmpty else {
            throw WorkspaceCanvasFixtureFailure("The native target has no finite displayed screen frame in its owned host.")
        }
        return frame
    }

    private func nativeOwnedQueueClick(at screenPoint: NSPoint, fixture: NativeWorkspaceDraftFixture,
                                       deadline: TimeInterval, identifier: String, exactHit: NSView? = nil) async throws {
        try nativeOwnedRequireOwner(fixture, deadline: deadline, requireKey: true)
        let windowPoint = fixture.window.convertFromScreen(NSRect(origin: screenPoint, size: .zero)).origin
        let local = fixture.hosting.convert(windowPoint, from: nil)
        guard screenPoint.x.isFinite, screenPoint.y.isFinite, fixture.hosting.visibleRect.contains(local),
              let hit = fixture.hosting.hitTest(fixture.hosting.convert(local, to: fixture.hosting.superview)),
              hit.window === fixture.window, !hit.isHiddenOrHasHiddenAncestor,
              hit === fixture.hosting || hit.isDescendant(of: fixture.hosting),
              exactHit == nil || hit === exactHit else {
            throw WorkspaceCanvasFixtureFailure("The measured pointer target did not hit its required app-owned native view.")
        }
        let down = try pointer(.leftMouseDown, at: local, in: fixture.hosting)
        let up = try pointer(.leftMouseUp, at: local, in: fixture.hosting)
        guard down.window === fixture.window, up.window === fixture.window,
              down.windowNumber == fixture.window.windowNumber, up.windowNumber == fixture.window.windowNumber else {
            throw WorkspaceCanvasFixtureFailure("The independent pointer pair escaped its exact owned window.")
        }
        try nativeOwnedRecord(["classification": "Measured real owned-window pointer target before one queued down/up pair; subsequent assertions determine delivery and outcome",
            "identifier": identifier, "stage": nativeDraftCurrentStage, "screen_point": NSStringFromPoint(screenPoint),
            "window_point": NSStringFromPoint(windowPoint), "hosting_point": NSStringFromPoint(local),
            "physical_hit_type": String(String(reflecting: type(of: hit)).prefix(256)),
            "physical_hit_identity": String(describing: ObjectIdentifier(hit)), "exact_literal_hit_required": exactHit != nil,
            "event_window_number": fixture.window.windowNumber, "event_windows_are_exact_owner": true,
            "API": "NSApp.postEvent(_:atStart:false)", "prepared_pointer_event_count": 2,
        ], name: "native-owned-target-" + identifier)
        try nativeOwnedRequireOwner(fixture, deadline: deadline, requireKey: true)
        NSApp.postEvent(down, atStart: false); NSApp.postEvent(up, atStart: false)
        try nativeOwnedRecord(["classification": "One owned-window down/up pair posted; subsequent outcome assertions remain required",
            "identifier": identifier, "actual_posted_event_count": 2, "event_windows_are_exact_owner": true,
        ], name: "native-owned-posted-" + identifier)
        try await Task.sleep(for: .milliseconds(40))
        try nativeOwnedRequireOwner(fixture, deadline: deadline)
    }

    private func nativeOwnedHide(_ panel: NativeWorkspacePanelHost, fixture: NativeWorkspaceDraftFixture,
                                 deadline: TimeInterval) async throws {
        let identifier = "workspace-hide-" + panel.panelID
        let buttons = try nativeOwnedViews(panel, fixture: fixture, deadline: deadline).compactMap { $0 as? NSButton }
            .filter { $0.accessibilityIdentifier() == identifier }
        guard buttons.count == 1, let button = buttons.first, button.isEnabled, !button.isHiddenOrHasHiddenAncestor,
              button.bounds.width > 0, button.bounds.height > 0 else {
            throw WorkspaceCanvasFixtureFailure("The real workspace Hide does not have one enabled literal native button.")
        }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let screen = fixture.window.convertToScreen(NSRect(origin: point, size: .zero)).origin
        try await nativeOwnedQueueClick(at: screen, fixture: fixture, deadline: deadline, identifier: identifier, exactHit: button)
    }

    private func nativeOwnedPress(_ identifier: String, in fixture: NativeWorkspaceDraftFixture,
                                  deadline: TimeInterval) async throws {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        nativeDraftStage("owned-native.action." + identifier + ".lookup")
        let node = try await nativeOwnedNode(identifier, fixture: fixture, deadline: end)
        guard node.role == .button, node.enabled == true else { throw WorkspaceCanvasFixtureFailure("The actual native Manager target is not an enabled identified button.") }
        let frame = try nativeOwnedFrame(node.object, fixture: fixture, deadline: end)
        let point = NSPoint(x: frame.midX, y: frame.midY)
        guard let rawHit = fixture.hosting.accessibilityHitTest(point) else { throw WorkspaceCanvasFixtureFailure("The measured native frame does not have a public semantic hit.") }
        let semanticHit: AnyObject
        if let formal = rawHit as? any NSAccessibilityProtocol { semanticHit = formal as AnyObject }
        else if let native = rawHit as? NSObject { semanticHit = native }
        else { throw WorkspaceCanvasFixtureFailure("The native semantic hit is not an actual public native object.") }
        try nativeOwnedRequireAncestor(semanticHit, fixture: fixture, deadline: end, requiredButton: identifier)
        try nativeOwnedRecord(["classification": "Fresh identified enabled public native Manager button with owned ancestor, measured frame and semantic hit; no action invoked",
            "identifier": identifier, "stage": nativeDraftCurrentStage, "screen_frame": NSStringFromRect(frame),
            "target_type": String(String(reflecting: type(of: node.object)).prefix(256)),
            "semantic_hit_type": String(String(reflecting: type(of: semanticHit)).prefix(256)),
            "semantic_hit_reaches_identified_button_and_exact_window": true,
        ], name: "native-owned-semantic-" + identifier)
        try await nativeOwnedQueueClick(at: point, fixture: fixture, deadline: end, identifier: identifier)
    }

    private func nativeOwnedRequireManagerTitle(_ title: String, in fixture: NativeWorkspaceDraftFixture,
                                               deadline: TimeInterval) async throws {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        repeat {
            nativeDraftStage("owned-native.manager-heading." + title)
            let header = try await nativeOwnedNode("detail-manager", fixture: fixture, deadline: end)
            _ = try nativeOwnedFrame(header.object, fixture: fixture, deadline: end)
            let nodes = try nativeOwnedTree(header.object, fixture: fixture, deadline: end, limit: 128)
            for node in nodes {
                try nativeOwnedRequireOwner(fixture, deadline: end)
                if node.value as? String == title || node.title == title {
                    let displayed = try nativeOwnedFrame(node.object, fixture: fixture, deadline: end)
                    try nativeOwnedRecord(["classification": "Actual displayed Manager heading observed through public ordinary native children",
                        "expected_title": title, "identifier": "detail-manager", "subtree_node_count": nodes.count,
                        "matched_text_screen_frame": NSStringFromRect(displayed),
                    ], name: "native-owned-manager-heading-" + title.replacingOccurrences(of: " ", with: "-"))
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < end
        throw WorkspaceCanvasFixtureFailure("The actual independent Manager route did not display its selected heading: " + title)
    }

    private func nativeOwnedRequireProjectIdentity(_ fixture: NativeWorkspaceDraftFixture,
                                                  deadline: TimeInterval) async throws {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        for (identifier, expected) in [("project-canonical-root", NativeWorkspaceDraftClient.projectRoot),
                                       ("project-generation", "Generation 4")] {
            nativeDraftStage("owned-native.projects-identity." + identifier)
            let node = try await nativeOwnedNode(identifier, fixture: fixture, deadline: end)
            _ = try nativeOwnedFrame(node.object, fixture: fixture, deadline: end)
            guard node.value as? String == expected || node.title == expected else {
                throw WorkspaceCanvasFixtureFailure("The displayed native Projects identity/generation does not match its original expected value.")
            }
            try nativeOwnedRecord(["classification": "Actual displayed Projects identity observed through the public native bridge",
                "identifier": identifier, "expected": expected,
            ], name: "native-owned-projects-identity-" + identifier)
        }
    }

    private func nativeOwnedRecord(_ report: [String: Any], name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        guard data.count <= 64 * 1_024, name.utf8.count <= 256 else { throw WorkspaceCanvasFixtureFailure("The independent native route evidence exceeded its finite bound.") }
        try directEvidence.save(data, name: name, extension: "json")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testProductionManagerExportedIdentityOwnedEventDraftSurvivesWorkspaceAndSectionTransitions() async throws {
        do {
            continueAfterFailure = true
            let flowDeadline = ProcessInfo.processInfo.systemUptime + 45
            nativeDraftStage("manager.fixture.create")
            defer { nativeDraftStage("manager.test.return-from-" + nativeDraftCurrentStage) }
            let fixture = try NativeWorkspaceDraftFixture(page: .manager)
            draftFixture = fixture
            nativeDraftStage("bootstrap.await-success")
            try await exposeNativeDraftFixture(fixture)
            try nativeOwnedRequireOwner(fixture, deadline: flowDeadline)
            nativeDraftStage("bootstrap.published-success")
            let app = try XCTUnwrap(fixture.model.app)
            let originalConfiguration = try Data(contentsOf: app.paths.configJSON)
            let originalHost = fixture.model.setHost
            let draft = "native-workspace-manager-draft.invalid"
            nativeDraftStage("default.field.lookup")
            let field = try await nativeExportObservedField(in: fixture.hosting, identifier: "Dashboard host",
                                                   placeholder: "Dashboard host", fixture: fixture, deadline: flowDeadline)
            try nativeOwnedEditField(field, value: draft, in: fixture.window, fixture: fixture, deadline: flowDeadline)
            try await nativeOwnedWait("The real Manager field did not update its staged AppModel value.", deadline: flowDeadline) {
                try fixture.model.setHost == draft && field.stringValue == draft
            }
            nativeDraftStage("edit.binding-confirmed.default-to-custom.begin")
            let layout = nativeDraftLayout(viewID: "manager.settings")
            try fixture.preferences.save(layout)
            nativeDraftStage("default-to-custom.preference-saved")
            let document = try await nativeOwnedDocument(fixture, panelID: "manager-dashboard-settings", deadline: flowDeadline)
            let panel = try XCTUnwrap(document.panelHosts["manager-dashboard-settings"])
            let hosting = panel.hostingView
            nativeDraftStage("custom.field.lookup")
            let customField = try await nativeExportObservedField(in: hosting, identifier: "Dashboard host",
                                                         placeholder: "Dashboard host", fixture: fixture, deadline: flowDeadline)
            XCTAssertEqual((try customField.stringValue), draft)
            nativeDraftStage("custom.hide.begin")
            try await nativeOwnedHide(panel, fixture: fixture, deadline: flowDeadline)
            nativeDraftStage("custom.hide.native-action-returned")
            try await nativeOwnedWait("The actual native Hide action did not hide Manager settings.", deadline: flowDeadline) { panel.isHidden }
            XCTAssertFalse(try XCTUnwrap(fixture.preferences.activeLayout(for: "manager.settings")?
                .panels.first { $0.id == "manager-dashboard-settings" }).isVisible)
            try fixture.preferences.setShown(true, for: "manager-dashboard-settings", in: "manager.settings")
            try await nativeOwnedWait("Manager settings did not resume from the retained native host.", deadline: flowDeadline) { !panel.isHidden }
            XCTAssertTrue(panel.hostingView === hosting)
            XCTAssertEqual((try customField.stringValue), draft)
            nativeDraftStage("named-layout.save.begin")
            let named = try fixture.preferences.saveAs(try XCTUnwrap(fixture.preferences.activeLayout(for: "manager.settings")),
                                                       named: "Manager Native Draft")
            try await nativeOwnedWait("The named Manager layout did not become active.", deadline: flowDeadline) {
                fixture.preferences.activeLayout(for: "manager.settings")?.id == named
            }
            let namedFrame = NativeWorkspaceFrame(x: 380, y: 60, width: 860, height: 440)
            try fixture.preferences.setFrame(namedFrame, for: "manager-dashboard-settings", in: "manager.settings")
            try await nativeOwnedWait("The named Manager geometry did not reach the actual panel.", deadline: flowDeadline) { panel.frame == namedFrame.nativeRect }
            try fixture.preferences.activate(layout.id, for: "manager.settings")
            try await nativeOwnedWait("The original Manager layout did not reach the actual panel.", deadline: flowDeadline) {
                panel.frame == layout.panels.first { $0.id == "manager-dashboard-settings" }?.frame.nativeRect
            }
            try fixture.preferences.activate(named, for: "manager.settings")
            try await nativeOwnedWait("Named layout changes replaced the Manager binding.", deadline: flowDeadline) {
                try panel.frame == namedFrame.nativeRect && panel.hostingView === hosting
                    && customField.stringValue == draft && fixture.model.setHost == draft
            }
            nativeDraftStage("manager.restore-default.begin")
            try fixture.preferences.reset("manager.settings")
            try await nativeOwnedWait("Default restoration did not dismantle Manager's custom canvas.", deadline: flowDeadline) {
                try self.nativeOwnedViews(fixture.hosting, fixture: fixture, deadline: flowDeadline).allSatisfy { !($0 is NativeWorkspaceDocumentView) }
            }
            let defaultField = try await nativeExportObservedField(in: fixture.hosting, identifier: "Dashboard host",
                                                          placeholder: "Dashboard host", fixture: fixture, deadline: flowDeadline)
            XCTAssertEqual((try defaultField.stringValue), draft)
            nativeDraftStage("manager.section-transitions.begin")
            for (section, title) in [("shell", "Project Shell"), ("folders", "Authorized Folders"),
                                      ("workbench", "Workbench"), ("settings", "Settings")] {
                nativeDraftStage("manager.section." + section + ".press")
                try await nativeExportOwnedPress("manager-section-" + section, in: fixture, deadline: flowDeadline)
                try await nativeExportRequireManagerTitle(title, in: fixture, deadline: flowDeadline)
            }
            let resumed = try await nativeExportObservedField(in: fixture.hosting, identifier: "Dashboard host",
                                                     placeholder: "Dashboard host", fixture: fixture, deadline: flowDeadline)
            XCTAssertEqual((try resumed.stringValue), draft)
            XCTAssertEqual(fixture.model.setHost, draft)
            XCTAssertNil(fixture.model.manager)
            XCTAssertNil(fixture.model.remoteManager)
            nativeDraftStage("manager.save-refusal.begin")
            try await nativeExportOwnedPress("settings-save", in: fixture, deadline: flowDeadline)
            try await nativeOwnedWait("The queued Save did not reach the actual unavailable-manager result.", deadline: flowDeadline) {
                fixture.model.managerMessage == "Manager is unavailable"
            }
            XCTAssertEqual(fixture.model.managerMessage, "Manager is unavailable")
            XCTAssertEqual(try Data(contentsOf: app.paths.configJSON), originalConfiguration,
                           "The isolated native presentation must not turn a staged edit into a backend save.")
            nativeDraftStage("manager.reload.begin")
            try await nativeExportOwnedPress("settings-reload", in: fixture, deadline: flowDeadline)
            try await nativeOwnedWait("Explicit native Reload did not restore the actual bootstrap configuration.", deadline: flowDeadline) {
                try !fixture.model.isUpdatingSettings && fixture.model.setHost == originalHost
                    && resumed.stringValue == originalHost
            }
            XCTAssertEqual(fixture.recorder.creations, 1)
            XCTAssertTrue(fixture.model.app === app)
            try nativeOwnedRequireOwner(fixture, deadline: flowDeadline)
            try nativeOwnedRecord(["classification": "Separate exported-identity/native-event draft route completed execution; actual XCTest assertions determine its outcome; original and ordinary-native gates stay separate",
                "test_method": "testProductionManagerExportedIdentityOwnedEventDraftSurvivesWorkspaceAndSectionTransitions", "stage": nativeDraftCurrentStage,
                "bootstrap_creations": fixture.recorder.creations, "event_route": "Read-only exported identity/frame/hit + NSApp.postEvent owned-window pointer pair; literal AppKit editor",
            ], name: "native-exported-identity-flow-execution")
        } catch {
            let actual = error as NSError
            nativeDraftRetainMeasurement([
                "classification": "Separate exported-identity/native-event draft failure; identical error rethrown; original and ordinary-native cases unchanged",
                "test_method": "testProductionManagerExportedIdentityOwnedEventDraftSurvivesWorkspaceAndSectionTransitions",
                "stage": nativeDraftCurrentStage,
                "error_type": String(String(reflecting: type(of: error)).prefix(1_024)),
                "error_description": String(String(describing: error).prefix(4_096)),
                "NSError_domain": String(actual.domain.prefix(1_024)),
                "NSError_code": actual.code,
                "task_cancelled": Task.isCancelled,
            ], name: "native-exported-identity-flow-boundary-error")
            throw error
        }
    }

    func testProductionProjectsExportedIdentityOwnedEventRepositoryDraftSurvivesWorkspaceWithSinglePageOwner() async throws {
        do {
            continueAfterFailure = true
            let flowDeadline = ProcessInfo.processInfo.systemUptime + 45
            nativeDraftStage("projects.fixture.create")
            defer { nativeDraftStage("projects.test.return-from-" + nativeDraftCurrentStage) }
            let fixture = try NativeWorkspaceDraftFixture(page: .projects)
            draftFixture = fixture
            nativeDraftStage("bootstrap.await-success")
            try await exposeNativeDraftFixture(fixture)
            try nativeOwnedRequireOwner(fixture, deadline: flowDeadline)
            nativeDraftStage("bootstrap.published-success")
            let draft = "https://github.com/fixture/native-workspace-unsaved"
            nativeDraftStage("projects.default-viewport.capture.begin")
            try nativeDraftRecordViewport(fixture, name: "projects-before-default-field")
            nativeDraftStage("projects.default-viewport.capture.returned")
            nativeDraftStage("default.field.lookup")
            let field = try await nativeExportObservedField(in: fixture.hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location", fixture: fixture, deadline: flowDeadline)
            try nativeOwnedEditField(field, value: draft, in: fixture.window, fixture: fixture, deadline: flowDeadline)
            try await nativeOwnedWait("The real Projects repository field did not retain the native edit.", deadline: flowDeadline) { (try field.stringValue) == draft }
            try await nativeExportRequireProjectIdentity(fixture, deadline: flowDeadline)
            nativeDraftStage("edit.binding-confirmed.default-to-custom.begin")
            let layout = nativeDraftLayout(viewID: "projects")
            try fixture.preferences.save(layout)
            nativeDraftStage("default-to-custom.preference-saved")
            let document = try await nativeOwnedDocument(fixture, panelID: "projects-repository", deadline: flowDeadline)
            let panel = try XCTUnwrap(document.panelHosts["projects-repository"])
            let hosting = panel.hostingView
            nativeDraftStage("custom.field.lookup")
            let customField = try await nativeExportObservedField(in: hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location", fixture: fixture, deadline: flowDeadline)
            XCTAssertEqual((try customField.stringValue), draft)
            nativeDraftStage("custom.hide.begin")
            try await nativeOwnedHide(panel, fixture: fixture, deadline: flowDeadline)
            nativeDraftStage("custom.hide.native-action-returned")
            try await nativeOwnedWait("The actual native Hide action did not hide the repository panel.", deadline: flowDeadline) { panel.isHidden }
            try fixture.preferences.setShown(true, for: "projects-repository", in: "projects")
            try await nativeOwnedWait("The retained repository host did not resume.", deadline: flowDeadline) { !panel.isHidden }
            XCTAssertTrue(panel.hostingView === hosting)
            XCTAssertEqual((try customField.stringValue), draft)
            nativeDraftStage("named-layout.save.begin")
            let named = try fixture.preferences.saveAs(try XCTUnwrap(fixture.preferences.activeLayout(for: "projects")),
                                                       named: "Projects Native Draft")
            let namedFrame = NativeWorkspaceFrame(x: 360, y: 260, width: 940, height: 320)
            try fixture.preferences.setFrame(namedFrame, for: "projects-repository", in: "projects")
            try await nativeOwnedWait("The named repository geometry did not reach the actual panel.", deadline: flowDeadline) { panel.frame == namedFrame.nativeRect }
            try fixture.preferences.activate(layout.id, for: "projects")
            try await nativeOwnedWait("The original repository geometry did not reach the actual panel.", deadline: flowDeadline) {
                panel.frame == layout.panels.first { $0.id == "projects-repository" }?.frame.nativeRect
            }
            try fixture.preferences.activate(named, for: "projects")
            try await nativeOwnedWait("Named layouts lost the unsaved repository binding.", deadline: flowDeadline) {
                try panel.frame == namedFrame.nativeRect && panel.hostingView === hosting && customField.stringValue == draft
            }
            try fixture.preferences.reset("projects")
            try await nativeOwnedWait("Default restoration did not dismantle Projects' custom canvas.", deadline: flowDeadline) {
                try self.nativeOwnedViews(fixture.hosting, fixture: fixture, deadline: flowDeadline).allSatisfy { !($0 is NativeWorkspaceDocumentView) }
            }
            let restored = try await nativeExportObservedField(in: fixture.hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location", fixture: fixture, deadline: flowDeadline)
            XCTAssertEqual((try restored.stringValue), draft)
            try await nativeExportRequireProjectIdentity(fixture, deadline: flowDeadline)
            try fixture.preferences.activate(named, for: "projects")
            let reactivated = try await nativeExportObservedField(in: fixture.hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location", fixture: fixture, deadline: flowDeadline)
            XCTAssertEqual((try reactivated.stringValue), draft)
            try fixture.preferences.reset("projects")
            let finalDefault = try await nativeExportObservedField(in: fixture.hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location", fixture: fixture, deadline: flowDeadline)
            XCTAssertEqual((try finalDefault.stringValue), draft)
            nativeDraftStage("projects.all-transitions-complete.owner-observations")
            let observations = await fixture.client.observations()
            XCTAssertEqual(observations.snapshots, 1,
                           "Layout presentation changes must not recreate/reload the page StateObject.")
            XCTAssertEqual(observations.repositoryWrites, 0)
            XCTAssertEqual(observations.otherMutations, 0)
            XCTAssertEqual(fixture.recorder.creations, 1)
            try nativeOwnedRequireOwner(fixture, deadline: flowDeadline)
            try nativeOwnedRecord(["classification": "Separate exported-identity/native-event draft route completed execution; actual XCTest assertions determine its outcome; original and ordinary-native gates stay separate",
                "test_method": "testProductionProjectsExportedIdentityOwnedEventRepositoryDraftSurvivesWorkspaceWithSinglePageOwner", "stage": nativeDraftCurrentStage,
                "bootstrap_creations": fixture.recorder.creations, "event_route": "Read-only exported identity/frame/hit + NSApp.postEvent owned-window pointer pair; literal AppKit editor",
            ], name: "native-exported-identity-flow-execution")
        } catch {
            let actual = error as NSError
            nativeDraftRetainMeasurement([
                "classification": "Separate exported-identity/native-event draft failure; identical error rethrown; original and ordinary-native cases unchanged",
                "test_method": "testProductionProjectsExportedIdentityOwnedEventRepositoryDraftSurvivesWorkspaceWithSinglePageOwner",
                "stage": nativeDraftCurrentStage,
                "error_type": String(String(reflecting: type(of: error)).prefix(1_024)),
                "error_description": String(String(describing: error).prefix(4_096)),
                "NSError_domain": String(actual.domain.prefix(1_024)),
                "NSError_code": actual.code,
                "task_cancelled": Task.isCancelled,
            ], name: "native-exported-identity-flow-boundary-error")
            throw error
        }
    }

    func testProductionProjectsQueuedMoveResizeRetainsRepositoryDraftAndRestoresGeometry() async throws {
        continueAfterFailure = true
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 45
        var stage = "fixture.create", postedEvents = 0
        var report: [String: Any] = [
            "classification": "Real Projects repository panel queued move/resize execution; XCTest assertions determine outcome; other UI gates remain separate",
            "test_method": "testProductionProjectsQueuedMoveResizeRetainsRepositoryDraftAndRestoresGeometry",
            "view_id": "projects", "panel_id": "projects-repository", "independent_view_id": "feed",
            "flow_deadline_seconds": 45, "execution_completed": false,
        ]
        defer {
            report["last_stage"] = stage; report["posted_pointer_events"] = postedEvents
            report["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
            report["within_shared_deadline"] = ProcessInfo.processInfo.systemUptime < deadline
            nativeDraftRetainMeasurement(report, name: "projects-native-repository-move-resize")
        }
        do {
            let fixture = try NativeWorkspaceDraftFixture(page: .projects)
            draftFixture = fixture
            stage = "bootstrap.expose"
            try await exposeNativeDraftFixture(fixture)
            try nativeOwnedRequireOwner(fixture, deadline: deadline, requireKey: true)
            let draft = "https://github.com/fixture/queued-panel-unsaved"
            stage = "default.native-field.edit"
            let field = try await nativeExportObservedField(in: fixture.hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location", fixture: fixture, deadline: deadline)
            try nativeOwnedEditField(field, value: draft, in: fixture.window, fixture: fixture, deadline: deadline)
            try await nativeOwnedWait("The real Projects native edit did not retain its unsaved draft.", deadline: deadline) { try field.stringValue == draft }
            try await nativeExportRequireProjectIdentity(fixture, deadline: deadline)
            stage = "custom-layout.setup"
            let independent = NativeWorkspaceLayout(id: UUID(), viewID: "feed", name: "Independent Feed",
                canvas: .init(width: 1_460, height: 3_600), panels: NativeWorkspaceCatalog.feed.map {
                    NativeWorkspacePanelPlacement(id: $0.id, frame: $0.defaultFrame, isVisible: true)
                })
            try fixture.preferences.save(independent)
            let layout = nativeDraftLayout(viewID: "projects")
            try fixture.preferences.save(layout)
            let setupCollection = fixture.preferences.collection
            let document = try await nativeOwnedDocument(fixture, panelID: "projects-repository", deadline: deadline)
            let panel = try XCTUnwrap(document.panelHosts["projects-repository"])
            defer { panel.cancelGesture() }
            let hosting = panel.hostingView, root = try XCTUnwrap(fixture.window.contentView)
            let customField = try await nativeExportObservedField(in: hosting,
                identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
                expectedLabel: "GitHub repository location", fixture: fixture, deadline: deadline)
            XCTAssertEqual(try customField.stringValue, draft)
            let original = try XCTUnwrap(layout.panels.first { $0.id == "projects-repository" }).frame
            try await nativeOwnedWait("The repository panel did not mount its saved starting geometry.", deadline: deadline) { panel.frame == original.nativeRect }
            report["initial_frame"] = NSStringFromRect(original.nativeRect)
            func handle(_ identifier: String) throws -> NSView {
                try nativeOwnedRequireOwner(fixture, deadline: deadline, requireKey: true)
                panel.layoutSubtreeIfNeeded()
                guard panel.subviews.count <= 64 else { throw WorkspaceCanvasFixtureFailure("The repository native chrome exceeded its 64-child bound.") }
                let matches = panel.subviews.filter { $0.accessibilityIdentifier() == identifier }
                guard matches.count == 1, let target = matches.first, target.superview === panel else {
                    throw WorkspaceCanvasFixtureFailure("The repository panel did not expose exactly one literal native gesture handle.")
                }
                return target
            }
            func startPoint(_ target: NSView) -> NSPoint {
                target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: document)
            }
            func requireHit(_ target: NSView, at point: NSPoint) throws {
                fixture.hosting.layoutSubtreeIfNeeded()
                try nativeOwnedRequireOwner(fixture, deadline: deadline, requireKey: true)
                guard root === fixture.hosting, document.window === fixture.window,
                      document.panelHosts["projects-repository"] === panel, panel.hostingView === hosting,
                      panel.superview === document, !panel.isHiddenOrHasHiddenAncestor,
                      target.window === fixture.window, !target.isHiddenOrHasHiddenAncestor,
                      root.hitTest(document.convert(point, to: root.superview)) === target else {
                    throw WorkspaceCanvasFixtureFailure("The exact owned Projects window did not hit the literal repository gesture handle.")
                }
            }
            func post(_ type: NSEvent.EventType, at point: NSPoint) throws {
                try nativeOwnedRequireOwner(fixture, deadline: deadline, requireKey: true)
                let event = try pointer(type, at: point, in: document)
                guard postedEvents < 6, document.window === fixture.window,
                      document.panelHosts["projects-repository"] === panel, panel.hostingView === hosting,
                      event.window === fixture.window, event.windowNumber == fixture.window.windowNumber else {
                    throw WorkspaceCanvasFixtureFailure("The repository queued pointer event escaped its owned window or six-event bound.")
                }
                NSApp.postEvent(event, atStart: false); postedEvents += 1
            }
            func expectedCollection(_ baseline: NativeWorkspaceCollection, frame: NativeWorkspaceFrame) throws -> NativeWorkspaceCollection {
                var expected = baseline
                let index = try XCTUnwrap(expected.layouts.firstIndex { $0.id == layout.id && $0.viewID == "projects" })
                let placement = try XCTUnwrap(expected.layouts[index].panels.firstIndex { $0.id == "projects-repository" })
                expected.layouts[index].panels[placement].frame = frame
                return expected
            }
            func expectedFront(_ baseline: NativeWorkspaceCollection) throws -> NativeWorkspaceCollection {
                var expected = baseline
                guard expected.activeLayoutIDs["projects"] == layout.id else { throw WorkspaceCanvasFixtureFailure("The repository gesture lost its exact active layout.") }
                let index = try XCTUnwrap(expected.layouts.firstIndex { $0.id == layout.id && $0.viewID == "projects" })
                let placement = try XCTUnwrap(expected.layouts[index].panels.firstIndex { $0.id == "projects-repository" })
                let front = expected.layouts[index].panels.remove(at: placement)
                expected.layouts[index].panels.append(front)
                return expected
            }
            let move = try handle("workspace-move-projects-repository")
            let from = startPoint(move), to = NSPoint(x: from.x + 20, y: from.y + 20)
            try requireHit(move, at: from)
            guard fixture.preferences.collection == setupCollection else { throw WorkspaceCanvasFixtureFailure("Mounting the real repository panel changed its setup collection.") }
            let beforeMoveDown = fixture.preferences.collection
            let expectedMoveDown = try expectedFront(beforeMoveDown)
            stage = "move.mouse-down"
            try post(.leftMouseDown, at: from)
            try await nativeOwnedWait("The native queue did not begin the repository move.", deadline: deadline) {
                try self.nativeOwnedRequireOwner(fixture, deadline: deadline, requireKey: true)
                return panel.isManipulating
            }
            let afterMoveDown = fixture.preferences.collection
            let moveDownBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            guard afterMoveDown == expectedMoveDown,
                  try JSONDecoder().decode(NativeWorkspaceCollection.self, from: moveDownBytes) == expectedMoveDown else {
                throw WorkspaceCanvasFixtureFailure("Repository move down changed more than its exact front order or stored collection.")
            }
            let moved = NativeWorkspaceFrame(x: original.x + 20, y: original.y + 20, width: original.width, height: original.height)
            let expectedMoved = try expectedCollection(afterMoveDown, frame: moved)
            stage = "move.mouse-dragged"
            try post(.leftMouseDragged, at: to)
            try await nativeOwnedWait("The queued repository move did not reach exact transient geometry.", deadline: deadline) { panel.isManipulating && panel.frame == moved.nativeRect }
            XCTAssertEqual(fixture.preferences.collection, afterMoveDown)
            XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), moveDownBytes)
            report["move_drag_uncommitted"] = fixture.preferences.collection == afterMoveDown && fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == moveDownBytes
            stage = "move.mouse-up"
            try post(.leftMouseUp, at: to)
            try await nativeOwnedWait("Repository mouse-up did not commit only its expected frame.", deadline: deadline) { !panel.isManipulating && fixture.preferences.collection == expectedMoved }
            let movedBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            XCTAssertEqual(try JSONDecoder().decode(NativeWorkspaceCollection.self, from: movedBytes), expectedMoved)
            XCTAssertEqual(try customField.stringValue, draft)
            report["moved_frame"] = NSStringFromRect(moved.nativeRect)
            let resize = try handle("workspace-resize-projects-repository")
            let resizeFrom = startPoint(resize), resizeTo = NSPoint(x: resizeFrom.x + 40, y: resizeFrom.y + 30)
            try requireHit(resize, at: resizeFrom)
            let beforeResizeDown = fixture.preferences.collection
            let expectedResizeDown = try expectedFront(beforeResizeDown)
            stage = "resize.mouse-down"
            try post(.leftMouseDown, at: resizeFrom)
            try await nativeOwnedWait("The native queue did not begin repository resize.", deadline: deadline) { panel.isManipulating }
            let afterResizeDown = fixture.preferences.collection
            let resizeDownBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            guard beforeResizeDown == expectedMoved, afterResizeDown == expectedResizeDown,
                  try JSONDecoder().decode(NativeWorkspaceCollection.self, from: resizeDownBytes) == expectedResizeDown else {
                throw WorkspaceCanvasFixtureFailure("Repository resize down changed more than its exact front order or stored collection.")
            }
            let resized = NativeWorkspaceFrame(x: moved.x, y: moved.y, width: moved.width + 40, height: moved.height + 30)
            let expectedResized = try expectedCollection(afterResizeDown, frame: resized)
            stage = "resize.mouse-dragged"
            try post(.leftMouseDragged, at: resizeTo)
            try await nativeOwnedWait("The queued repository resize did not reach exact transient geometry.", deadline: deadline) { panel.isManipulating && panel.frame == resized.nativeRect }
            XCTAssertEqual(fixture.preferences.collection, afterResizeDown)
            XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), resizeDownBytes)
            report["resize_drag_uncommitted"] = fixture.preferences.collection == afterResizeDown && fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == resizeDownBytes
            stage = "resize.mouse-up"
            try post(.leftMouseUp, at: resizeTo)
            try await nativeOwnedWait("Repository resize mouse-up did not commit only its expected frame.", deadline: deadline) { !panel.isManipulating && fixture.preferences.collection == expectedResized }
            stage = "fresh-preferences.restore"
            guard let liveField = customField.node.object as? NSTextField,
                  liveField.window === fixture.window, liveField.isDescendant(of: hosting) else {
                throw WorkspaceCanvasFixtureFailure("The retained repository native field left its exact live panel host.")
            }
            let finalBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            let fresh = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: fixture.defaults)
            XCTAssertNil(fresh.restorationError)
            XCTAssertEqual(fresh.collection, expectedResized)
            XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), finalBytes)
            XCTAssertEqual(fresh.activeLayout(for: "projects")?.panels.first { $0.id == "projects-repository" }?.frame, resized)
            XCTAssertEqual(fresh.layouts(for: "feed"), [independent])
            XCTAssertEqual(fresh.activeLayout(for: "feed"), independent)
            XCTAssertTrue(document.panelHosts["projects-repository"] === panel)
            XCTAssertTrue(panel.hostingView === hosting)
            XCTAssertEqual(panel.frame, resized.nativeRect)
            XCTAssertEqual(try customField.stringValue, draft)
            let observations = await fixture.client.observations()
            XCTAssertEqual(observations.snapshots, 1)
            XCTAssertEqual(observations.repositoryWrites, 0)
            XCTAssertEqual(observations.otherMutations, 0)
            XCTAssertEqual(fixture.recorder.creations, 1)
            try nativeOwnedRequireOwner(fixture, deadline: deadline, requireKey: true)
            XCTAssertEqual(postedEvents, 6)
            report["resized_frame"] = NSStringFromRect(resized.nativeRect)
            report["snapshots"] = observations.snapshots; report["repository_writes"] = observations.repositoryWrites
            report["other_mutations"] = observations.otherMutations; report["bootstrap_creations"] = fixture.recorder.creations
            stage = "complete"; report["execution_completed"] = true
        } catch {
            report["error_type"] = String(String(reflecting: type(of: error)).prefix(256))
            report["error_description"] = String(String(describing: error).prefix(4_096))
            report["task_cancelled"] = Task.isCancelled
            throw error
        }
    }

    func testProductionProjectsResizedRepositoryPanelSaveRejectAndClearUpdatesFeedback() async throws {
        continueAfterFailure = true
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        let fixture = try NativeWorkspaceDraftFixture(page: .projects, repositoryUpdatesEnabled: true)
        draftFixture = fixture
        try await exposeNativeDraftFixture(fixture)
        try nativeOwnedRequireOwner(fixture, deadline: deadline, requireKey: true)
        let layout = NativeWorkspaceLayout(id: UUID(), viewID: "projects", name: "Repository feedback",
            canvas: .init(width: 1_460, height: 3_600), panels: NativeWorkspaceCatalog.projects.map {
                let frame: NativeWorkspaceFrame
                switch $0.id {
                case "projects-status": frame = .init(x: 40, y: 20, width: 980, height: 300)
                case "projects-repository": frame = .init(x: 40, y: 340, width: 980, height: 300)
                default: frame = $0.defaultFrame
                }
                return NativeWorkspacePanelPlacement(id: $0.id, frame: frame,
                    isVisible: $0.id == "projects-status" || $0.id == "projects-repository")
            })
        try fixture.preferences.save(layout)
        let document = try await nativeOwnedDocument(fixture, panelID: "projects-repository", deadline: deadline)
        let panel = try XCTUnwrap(document.panelHosts["projects-repository"])
        let resized = NativeWorkspaceFrame(x: 40, y: 340, width: 640, height: 260)
        try fixture.preferences.setFrame(resized, for: "projects-repository", in: "projects")
        try await nativeOwnedWait("The repository panel did not reach the prepared resized geometry.", deadline: deadline) {
            panel.frame == resized.nativeRect
        }
        let collection = fixture.preferences.collection
        let layoutBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
        let field = try await nativeExportObservedField(in: panel.hostingView,
            identifier: "project-github-repository-location", placeholder: "https://github.com/owner/repository",
            expectedLabel: "GitHub repository location", fixture: fixture, deadline: deadline)
        func status(_ phase: String) async throws -> [NativeWorkspaceDraftAccessibilityNode] {
            let root = try await nativeDraftAXElement("workspace-panel-projects-status", in: fixture,
                deadline: deadline, scope: .applicationContent)
            let nodes = try nativeDraftExportedAXTree(root, deadline: deadline, limit: 64)
            try nativeOwnedRecord([
                "classification": "Complete native status-panel subtree; fixture transport only, not live backend or desktop acceptance",
                "phase": phase, "node_count": nodes.count, "complete": true,
                "nodes": nodes.map { ["identifier": String(($0.identifier ?? "").prefix(256)),
                    "role": $0.role?.rawValue ?? "", "title": String(($0.title ?? "").prefix(512)),
                    "value": ($0.value as? String).map { String($0.prefix(1_024)) as Any } ?? NSNull()] },
            ], name: "projects-repository-feedback-" + phase)
            return nodes
        }
        let canonical = "https://github.com/fixture/native-panel"
        try nativeOwnedEditField(field, value: "git@github.com:fixture/native-panel.git", in: fixture.window,
                                fixture: fixture, deadline: deadline)
        try await nativeExportOwnedPress("project-github-repository-save", in: fixture, deadline: deadline)
        try await nativeOwnedWait("Successful native Save did not publish the canonical repository value.", deadline: deadline) {
            try field.stringValue == canonical
        }
        _ = try await nativeDraftAXElement("operator-notice", in: fixture, deadline: deadline, scope: .applicationContent)
        let saved = try await status("saved")
        XCTAssertEqual(saved.filter { $0.identifier == "operator-notice" }.count, 1)
        XCTAssertFalse(saved.contains { $0.identifier == "operator-unavailable" })
        let savedRequests = await fixture.client.repositoryRequests()
        XCTAssertEqual(savedRequests, [.init(projectID: NativeWorkspaceDraftClient.projectID, generation: 4, location: canonical)])

        try nativeOwnedEditField(field, value: "https://example.invalid/fixture/native-panel", in: fixture.window,
                                fixture: fixture, deadline: deadline)
        try await nativeExportOwnedPress("project-github-repository-save", in: fixture, deadline: deadline)
        _ = try await nativeDraftAXElement("operator-unavailable", in: fixture, deadline: deadline, scope: .applicationContent)
        let rejected = try await status("rejected")
        XCTAssertEqual(rejected.filter { $0.identifier == "operator-unavailable" }.count, 1)
        XCTAssertFalse(rejected.contains { $0.identifier == "operator-notice" },
                       "The rejected native Save must remove the previous Saved success banner.")
        let rejectedRequests = await fixture.client.repositoryRequests()
        XCTAssertEqual(rejectedRequests, savedRequests, "Invalid input must not dispatch another repository write.")
        let linked = try await fixture.client.projectStatus(projectID: NativeWorkspaceDraftClient.projectID)
        XCTAssertEqual(linked.githubRepositoryURL, canonical)

        try await nativeExportOwnedPress("project-github-repository-clear", in: fixture, deadline: deadline)
        try await nativeOwnedWait("Native Clear did not clear the repository editor.", deadline: deadline) { try field.stringValue == "" }
        _ = try await nativeDraftAXElement("operator-notice", in: fixture, deadline: deadline, scope: .applicationContent)
        let cleared = try await status("cleared")
        XCTAssertEqual(cleared.filter { $0.identifier == "operator-notice" }.count, 1)
        XCTAssertFalse(cleared.contains { $0.identifier == "operator-unavailable" })
        let requests = await fixture.client.repositoryRequests()
        XCTAssertEqual(requests, savedRequests + [.init(projectID: NativeWorkspaceDraftClient.projectID, generation: 4, location: nil)])
        let project = try await fixture.client.projectStatus(projectID: NativeWorkspaceDraftClient.projectID)
        XCTAssertNil(project.githubRepositoryURL)
        XCTAssertEqual(project.projectGeneration, 4)
        XCTAssertEqual(fixture.preferences.collection, collection)
        XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), layoutBytes)
        XCTAssertEqual(panel.frame, resized.nativeRect)
        let observations = await fixture.client.observations()
        XCTAssertEqual(observations.snapshots, 1)
        XCTAssertEqual(observations.repositoryWrites, 2)
        XCTAssertEqual(observations.otherMutations, 0)
        XCTAssertEqual(fixture.recorder.creations, 1)
        try nativeOwnedRequireOwner(fixture, deadline: deadline, requireKey: true)
    }

    private func nativeExportObservedField(in root: NSView, identifier: String, placeholder: String,
                                           expectedLabel: String? = nil, fixture: NativeWorkspaceDraftFixture,
                                           deadline: TimeInterval) async throws -> NativeWorkspaceDraftField {
        try nativeOwnedRequireOwner(fixture, deadline: deadline)
        guard deadline - ProcessInfo.processInfo.systemUptime > 3,
              root.window === fixture.window, root === fixture.hosting || root.isDescendant(of: fixture.hosting) else {
            throw WorkspaceCanvasFixtureFailure("The separate field observation lacks its exact root or remaining bounded phase.")
        }
        let observed = try await nativeDraftField(in: root, identifier: identifier,
                                                  placeholder: placeholder, expectedLabel: expectedLabel)
        try nativeOwnedRequireOwner(fixture, deadline: deadline)
        guard observed.exportedOwner == nil, observed.node.exportedAX == nil,
              let field = observed.node.object as? NSTextField, field.isEditable, field.isEnabled,
              !field.isHiddenOrHasHiddenAncestor, field.window === fixture.window, field.isDescendant(of: root),
              field.accessibilityIdentifier() == identifier || field.accessibilityLabel() == identifier
                || (expectedLabel != nil && field.accessibilityLabel() == expectedLabel)
                || field.placeholderString == placeholder else {
            throw WorkspaceCanvasFixtureFailure("The read-only observer did not return a literal identified/labelled exact-owned AppKit field; semantic/exported edits refused.")
        }
        let matching = try nativeOwnedViews(root, fixture: fixture, deadline: deadline).compactMap { $0 as? NSTextField }.filter {
            $0.isEditable && ($0.accessibilityIdentifier() == identifier || $0.accessibilityLabel() == identifier
                || (expectedLabel != nil && $0.accessibilityLabel() == expectedLabel) || $0.placeholderString == placeholder)
        }
        guard matching.count == 1, matching.first === field else {
            throw WorkspaceCanvasFixtureFailure("The literal field match is missing, duplicate or different from the read-only observation.")
        }
        try nativeOwnedRecord(["classification": "Separate original read-only observer returned one literal AppKit field; actual native editor remains required before input",
            "requested_identifier": identifier, "observer_stage": nativeDraftCurrentStage,
            "actual_identifier": String(field.accessibilityIdentifier().prefix(256)),
            "actual_label": String((field.accessibilityLabel() ?? "").prefix(256)),
            "actual_placeholder": String((field.placeholderString ?? "").prefix(256)),
            "actual_field_type": String(String(reflecting: type(of: field)).prefix(256)),
            "actual_field_identity": String(describing: ObjectIdentifier(field)), "exact_root_and_window": true,
            "observation_bridge": "Existing nativeDraftField read-only observation; returned field must be literal native",
        ], name: "native-exported-observation-literal-field")
        return observed
    }

    private func nativeExportFrame(_ element: AXUIElement, context: NativeWorkspaceDraftExportedAXContext,
                                    fixture: NativeWorkspaceDraftFixture, deadline: TimeInterval) throws
        -> (topLeft: NSRect, screen: NSRect) {
        try nativeOwnedRequireOwner(fixture, deadline: deadline)
        try context.requireOwnedAncestor(element)
        guard context.deadline == deadline,
              let position = try NativeWorkspaceDraftAXQuery.attribute(element, kAXPositionAttribute, deadline: deadline),
              let dimensions = try NativeWorkspaceDraftAXQuery.attribute(element, kAXSizeAttribute, deadline: deadline),
              CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(dimensions as CFTypeRef) == AXValueGetTypeID() else {
            throw WorkspaceCanvasFixtureFailure("The separate exported target does not provide bounded AXValue position/size.")
        }
        let positionValue = position as! AXValue, sizeValue = dimensions as! AXValue
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              let primary = NSScreen.screens.first, primary.frame.origin == .zero else {
            throw WorkspaceCanvasFixtureFailure("The exported geometry or existing primary-screen conversion guard failed.")
        }
        let topLeft = NSRect(origin: point, size: size)
        let screen = NSRect(x: point.x, y: primary.frame.maxY - point.y - size.height,
                            width: size.width, height: size.height)
        let viewport = fixture.window.convertToScreen(fixture.hosting.convert(fixture.hosting.visibleRect, to: nil))
        guard screen.minX.isFinite, screen.minY.isFinite, screen.maxX.isFinite, screen.maxY.isFinite,
              !NSIntersectionRect(screen, viewport).isEmpty else {
            throw WorkspaceCanvasFixtureFailure("The exact exported target is outside its displayed native host or has invalid converted geometry.")
        }
        try nativeOwnedRequireOwner(fixture, deadline: deadline)
        return (topLeft, screen)
    }

    private func nativeExportRequireExactHit(_ hit: AXUIElement, target: AXUIElement,
                                             context: NativeWorkspaceDraftExportedAXContext) throws -> Int {
        var cursor = hit, seen: [AXUIElement] = [], foundTarget = false
        for _ in 0..<48 {
            try context.requireOwner()
            try NativeWorkspaceDraftAXQuery.prepare(cursor, deadline: context.deadline)
            guard !seen.contains(where: { CFEqual($0, cursor) }) else {
                throw WorkspaceCanvasFixtureFailure("The exported semantic hit ancestry contains a cycle.")
            }
            seen.append(cursor)
            if CFEqual(cursor, target) { foundTarget = true }
            if CFEqual(cursor, context.windowElement) {
                guard foundTarget else { throw WorkspaceCanvasFixtureFailure("The measured semantic hit does not reach the exact CFEqual identified target.") }
                return seen.count
            }
            guard let parent = try NativeWorkspaceDraftAXQuery.attribute(cursor, kAXParentAttribute, deadline: context.deadline),
                  CFGetTypeID(parent as CFTypeRef) == AXUIElementGetTypeID() else {
                throw WorkspaceCanvasFixtureFailure("The exported semantic hit does not reach its exact owned window.")
            }
            cursor = parent as! AXUIElement
        }
        throw WorkspaceCanvasFixtureFailure("The exported semantic hit ancestry exceeded 48 objects.")
    }

    private func nativeExportOwnedPress(_ identifier: String, in fixture: NativeWorkspaceDraftFixture,
                                        deadline: TimeInterval) async throws {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        try nativeOwnedRequireOwner(fixture, deadline: end, requireKey: true)
        nativeDraftStage("exported-identity.owned-action." + identifier + ".lookup")
        let node = try await nativeDraftAXElement(identifier, in: fixture, deadline: end, scope: .applicationContent)
        guard let element = node.exportedAX, let context = node.exportedContext else {
            throw WorkspaceCanvasFixtureFailure("The separate route did not return a scoped exported identifier.")
        }
        let snapshot = try context.snapshot(element)
        guard snapshot.identifier == identifier, snapshot.role == .button, snapshot.enabled == true else {
            throw WorkspaceCanvasFixtureFailure("The fresh exported identity is not the exact enabled AXButton.")
        }
        let measured = try nativeExportFrame(element, context: context, fixture: fixture, deadline: end)
        let topLeftPoint = NSPoint(x: measured.topLeft.midX, y: measured.topLeft.midY)
        let screenPoint = NSPoint(x: measured.screen.midX, y: measured.screen.midY)
        guard Float(topLeftPoint.x).isFinite, Float(topLeftPoint.y).isFinite else {
            throw WorkspaceCanvasFixtureFailure("The exact exported hit point exceeds the public API coordinate range.")
        }
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        try NativeWorkspaceDraftAXQuery.prepare(application, deadline: end)
        var rawHit: AXUIElement?
        let hitStatus = AXUIElementCopyElementAtPosition(application, Float(topLeftPoint.x), Float(topLeftPoint.y), &rawHit)
        guard hitStatus == .success, let hit = rawHit, CFGetTypeID(hit) == AXUIElementGetTypeID(),
              ProcessInfo.processInfo.systemUptime < end else {
            throw WorkspaceCanvasFixtureFailure("The public own-process semantic hit failed or exceeded its bound: AXError \(hitStatus.rawValue).")
        }
        let ancestors = try nativeExportRequireExactHit(hit, target: element, context: context)
        let refreshed = try context.snapshot(element)
        let currentFrame = try nativeExportFrame(element, context: context, fixture: fixture, deadline: end)
        guard refreshed.identifier == identifier, refreshed.role == .button, refreshed.enabled == true,
              currentFrame.topLeft == measured.topLeft, currentFrame.screen == measured.screen else {
            throw WorkspaceCanvasFixtureFailure("The measured exported target changed before its owned native event.")
        }
        try nativeOwnedRecord(["classification": "Separate exported-identity/native-event route: fresh unique enabled AXButton, exact CFEqual semantic target/window hit, measured frame; no action invoked",
            "identifier": identifier, "stage": nativeDraftCurrentStage,
            "identity_bridge": "Scoped own-process exported AX read-only snapshot",
            "semantic_hit_API": "AXUIElementCopyElementAtPosition own-process application",
            "semantic_hit_status": hitStatus.rawValue, "hit_is_target_CFEqual": CFEqual(hit, element),
            "hit_ancestor_count": ancestors, "hit_reaches_exact_target_and_window": true,
            "frame_top_left_screen": NSStringFromRect(measured.topLeft), "frame_native_screen": NSStringFromRect(measured.screen),
            "frame_unchanged_before_queue": true, "input_bridge": "nativeOwnedQueueClick physical own-host hit + one NSApp.postEvent down/up pair",
        ], name: "native-exported-identity-target-" + identifier)
        try await nativeOwnedQueueClick(at: screenPoint, fixture: fixture, deadline: end, identifier: identifier)
    }

    private func nativeExportRequireManagerTitle(_ title: String, in fixture: NativeWorkspaceDraftFixture,
                                                 deadline: TimeInterval) async throws {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        repeat {
            nativeDraftStage("exported-identity.manager-heading." + title)
            let header = try await nativeDraftAXElement("detail-manager", in: fixture, deadline: end, scope: .applicationContent)
            guard let element = header.exportedAX, let context = header.exportedContext else {
                throw WorkspaceCanvasFixtureFailure("The separate Manager heading has no scoped exported identity.")
            }
            _ = try nativeExportFrame(element, context: context, fixture: fixture, deadline: end)
            let nodes = try nativeDraftExportedAXTree(header, deadline: end, limit: 128)
            if let match = nodes.first(where: { $0.value as? String == title || $0.title == title }) {
                guard let text = match.exportedAX else { throw WorkspaceCanvasFixtureFailure("The matching heading has no exact exported object.") }
                let displayed = try nativeExportFrame(text, context: context, fixture: fixture, deadline: end)
                try nativeOwnedRecord(["classification": "Separate strict displayed Manager title/value check through scoped exported read-only children",
                    "expected_title": title, "subtree_node_count": nodes.count, "matched_text_frame": NSStringFromRect(displayed.screen),
                    "identity_bridge": "Exported detail-manager and bounded complete child snapshots",
                ], name: "native-exported-manager-heading-" + title.replacingOccurrences(of: " ", with: "-"))
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < end
        throw WorkspaceCanvasFixtureFailure("The separate exported-identity route did not display its selected Manager heading.")
    }

    private func nativeExportRequireProjectIdentity(_ fixture: NativeWorkspaceDraftFixture,
                                                    deadline: TimeInterval) async throws {
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        let identity = try await nativeDraftAXElement("project-canonical-root", in: fixture, deadline: end, scope: .applicationContent)
        guard let identityElement = identity.exportedAX, let identityContext = identity.exportedContext else {
            throw WorkspaceCanvasFixtureFailure("The displayed Projects root has no scoped exported identity.")
        }
        _ = try nativeExportFrame(identityElement, context: identityContext, fixture: fixture, deadline: end)
        XCTAssertTrue(identity.value as? String == NativeWorkspaceDraftClient.projectRoot
            || identity.title == NativeWorkspaceDraftClient.projectRoot)
        let generation = try await nativeDraftAXElement("project-generation", in: fixture, deadline: end, scope: .applicationContent)
        guard let generationElement = generation.exportedAX, let generationContext = generation.exportedContext else {
            throw WorkspaceCanvasFixtureFailure("The displayed Projects generation has no scoped exported identity.")
        }
        _ = try nativeExportFrame(generationElement, context: generationContext, fixture: fixture, deadline: end)
        XCTAssertTrue(generation.value as? String == "Generation 4"
            || generation.title == "Generation 4")
        try nativeOwnedRecord(["classification": "Separate strict displayed Projects root/generation assertions through scoped exported read-only identity",
            "expected_root": NativeWorkspaceDraftClient.projectRoot, "expected_generation": "Generation 4",
            "identity_bridge": "Fresh unique exported IDs, exact window ancestry and visible measured frames",
        ], name: "native-exported-projects-displayed-identity")
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

    private enum NativeDraftIdentifierScope: Equatable { case wholeWindow, applicationContent }

    private func nativeDraftAXElement(_ identifier: String, in fixture: NativeWorkspaceDraftFixture,
                                      deadline suppliedDeadline: TimeInterval? = nil,
                                      scope: NativeDraftIdentifierScope = .wholeWindow) async throws -> NativeWorkspaceDraftAccessibilityNode {
        var progress: [String: Any] = [:]
        do {
            return try await nativeDraftObserveAXElement(identifier, in: fixture, deadline: suppliedDeadline,
                scope: scope, progress: &progress)
        } catch {
            await nativeDraftRetainLookupFailure(error, lookupKind: "AX-element", root: fixture.hosting,
                identifier: identifier, placeholder: nil, expectedLabel: nil, lookupProgress: progress)
            throw error
        }
    }

    private func nativeDraftObserveAXElement(_ identifier: String, in fixture: NativeWorkspaceDraftFixture,
                                             deadline suppliedDeadline: TimeInterval?,
                                             scope: NativeDraftIdentifierScope = .wholeWindow,
                                             progress: inout [String: Any]) async throws -> NativeWorkspaceDraftAccessibilityNode {
        try await nativeDraftObserveAXElement(identifier, window: fixture.window, hosting: fixture.hosting,
            deadline: suppliedDeadline, scope: scope, progress: &progress)
    }

    private func nativeDraftObserveAXElement(_ identifier: String, window: NSWindow, hosting: NSView,
                                             deadline suppliedDeadline: TimeInterval?,
                                             scope: NativeDraftIdentifierScope = .wholeWindow,
                                             progress: inout [String: Any]) async throws -> NativeWorkspaceDraftAccessibilityNode {
        let deadline = suppliedDeadline ?? ProcessInfo.processInfo.systemUptime + 3
        var attempt = 0
        repeat {
            attempt += 1
            progress = ["operation": "scope-construction", "attempt": attempt]
            hosting.layoutSubtreeIfNeeded()
            if let context = try NativeWorkspaceDraftExportedAXContext(window: window, hosting: hosting, deadline: deadline) {
                progress["operation"] = "root-ancestor-validation"
                try context.requireOwnedAncestor(context.windowElement)
                var excludedStandardZoom: AXUIElement?, zoomIdentifier: String?, validatedZoomSubrole: String?
                var fullScreenReferenceMatched: Bool?
                var omittedZoomDescendants = false
                if scope == .applicationContent {
                    progress["operation"] = "application-content-standard-zoom-validation"
                    guard let raw = try NativeWorkspaceDraftAXQuery.attribute(context.windowElement, kAXZoomButtonAttribute, deadline: deadline),
                          CFGetTypeID(raw as CFTypeRef) == AXUIElementGetTypeID() else {
                        throw WorkspaceCanvasFixtureFailure("Application-content scope requires the exact owned window's public Zoom reference.")
                    }
                    let zoom = raw as! AXUIElement
                    try NativeWorkspaceDraftAXQuery.prepare(zoom, deadline: deadline)
                    try context.requireOwnedAncestor(zoom)
                    let zoomRole = try NativeWorkspaceDraftAXQuery.attribute(zoom, kAXRoleAttribute, deadline: deadline)
                    progress["standard_zoom_role_string_prefix"] = (zoomRole as? String).map { String($0.prefix(256)) as Any } ?? NSNull()
                    progress["standard_zoom_role_cf_type_id"] = zoomRole.map { CFGetTypeID($0 as CFTypeRef) as Any } ?? NSNull()
                    let zoomSubrole = try NativeWorkspaceDraftAXQuery.attribute(zoom, kAXSubroleAttribute, deadline: deadline)
                    progress["standard_zoom_subrole_string_prefix"] = (zoomSubrole as? String).map { String($0.prefix(256)) as Any } ?? NSNull()
                    progress["standard_zoom_subrole_cf_type_id"] = zoomSubrole.map { CFGetTypeID($0 as CFTypeRef) as Any } ?? NSNull()
                    guard zoomRole as? String == kAXButtonRole, let subrole = zoomSubrole as? String,
                          subrole == kAXZoomButtonSubrole || subrole == kAXFullScreenButtonSubrole else {
                        throw WorkspaceCanvasFixtureFailure("The exact excluded reference is not an owned AXButton with a recognized standard window-control subrole.")
                    }
                    if subrole == kAXFullScreenButtonSubrole {
                        guard let rawFullScreen = try NativeWorkspaceDraftAXQuery.attribute(context.windowElement, kAXFullScreenButtonAttribute, deadline: deadline),
                              CFGetTypeID(rawFullScreen as CFTypeRef) == AXUIElementGetTypeID() else {
                            throw WorkspaceCanvasFixtureFailure("The Full Screen subrole requires the exact owned window's public Full Screen reference.")
                        }
                        let fullScreen = rawFullScreen as! AXUIElement
                        try NativeWorkspaceDraftAXQuery.prepare(fullScreen, deadline: deadline)
                        try context.requireOwnedAncestor(fullScreen)
                        let matchesZoom = CFEqual(fullScreen, zoom)
                        progress["exact_owned_window_full_screen_reference_matches_zoom"] = matchesZoom
                        guard matchesZoom else {
                            throw WorkspaceCanvasFixtureFailure("The owned window's Full Screen reference differs from its exact Zoom reference.")
                        }
                        fullScreenReferenceMatched = matchesZoom
                    }
                    validatedZoomSubrole = subrole
                    let rawID = try NativeWorkspaceDraftAXQuery.attribute(zoom, kAXIdentifierAttribute, deadline: deadline)
                    guard rawID == nil || (rawID as? String).map({ $0.utf8.count <= 16 * 1_024 }) == true,
                          rawID as? String != identifier else {
                        throw WorkspaceCanvasFixtureFailure("The excluded standard Zoom has invalid metadata or matches the requested Forge target.")
                    }
                    zoomIdentifier = rawID as? String; excludedStandardZoom = zoom
                }
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
                    if scope == .applicationContent {
                        progress["identifier_observation_scope"] = "application-content-excluding-validated-standard-zoom-descendants"
                        progress["standard_zoom_reference_validated"] = excludedStandardZoom != nil
                        progress["standard_zoom_descendant_expansion_omitted"] = omittedZoomDescendants
                    }
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
                    if let excludedStandardZoom, CFEqual(element, excludedStandardZoom) {
                        guard rawIdentifier as? String != identifier else {
                            throw WorkspaceCanvasFixtureFailure("Application-content scope cannot return its excluded standard Zoom as a Forge target.")
                        }
                        omittedZoomDescendants = true
                        continue
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
                    if scope == .applicationContent { progress["standard_zoom_descendant_expansion_omitted"] = omittedZoomDescendants }
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
                    if scope == .applicationContent {
                        try nativeOwnedRecord(["classification": "Separate application-content identifier scope; exact validated standard Zoom ID read, only its descendant expansion excluded; remaining scoped walk completed",
                            "requested_identifier": identifier, "scope": "application-content-excluding-validated-standard-zoom-descendants",
                            "standard_zoom_role": kAXButtonRole,
                            "standard_zoom_subrole": validatedZoomSubrole.map { String($0.prefix(256)) as Any } ?? NSNull(),
                            "exact_owned_window_full_screen_reference_matches_zoom": fullScreenReferenceMatched.map { $0 as Any } ?? NSNull(),
                            "standard_zoom_identifier": zoomIdentifier.map { String($0.prefix(256)) as Any } ?? NSNull(),
                            "exact_owned_window_zoom_reference_validated": true,
                            "standard_zoom_descendant_expansion_omitted": omittedZoomDescendants,
                            "complete_scoped_identifier_walk_node_count": seen.count,
                            "original_whole_window_and_ordinary_native_gates": "unchanged; separate outcomes required",
                        ], name: "native-exported-application-content-scope-" + identifier)
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

    private func nativeDraftControlBridgeFailureDiagnostic(_ receipts: [NativeWorkspaceDraftWeakBridgeReceipt]) -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime, end = started + 0.02
        var rows: [[String: Any]] = [], nativeCalls = 0
        func observed(_ value: Any?) -> [String: Any] {
            ["attempted": true, "is_nil": value == nil,
             "raw_type_utf8_prefix": value.map { String(decoding: String(reflecting: type(of: $0)).utf8.prefix(128), as: UTF8.self) as Any } ?? NSNull(),
             "string_utf8_prefix": (value as? String).map { String(decoding: $0.utf8.prefix(128), as: UTF8.self) as Any } ?? NSNull(),
             "array_count": (value as? [Any]).map { $0.count as Any } ?? NSNull()]
        }
        for receipt in receipts.prefix(64) {
            var row: [String: Any] = ["original_node_ordinal": receipt.ordinal,
                "cached_original_identifier_utf8_prefix": receipt.identifierPrefix as Any? ?? NSNull(),
                "object_available": false, "formal_protocol": NSNull(), "informal_nsobject": NSNull(),
                "formal_identifier": ["attempted": false], "formal_children": ["attempted": false],
                "informal_names": ["attempted": false], "informal_identifier": ["attempted": false],
                "informal_children": ["attempted": false], "identifier_advertised": NSNull(), "children_advertised": NSNull()]
            guard let object = receipt.object else { rows.append(row); continue }
            row["object_available"] = true
            let formal = object as? any NSAccessibilityProtocol, informal = object as? NSObject
            row["formal_protocol"] = formal != nil; row["informal_nsobject"] = informal != nil
            if let formal, ProcessInfo.processInfo.systemUptime < end {
                nativeCalls += 1; row["formal_identifier"] = observed(formal.accessibilityIdentifier())
            }
            if let formal, ProcessInfo.processInfo.systemUptime < end {
                nativeCalls += 1; row["formal_children"] = observed(formal.accessibilityChildren())
            }
            if let informal, ProcessInfo.processInfo.systemUptime < end {
                nativeCalls += 1
                let names = informal.accessibilityAttributeNames()
                row["informal_names"] = ["attempted": true, "count": names.count, "within_128_limit": names.count <= 128]
                if names.count <= 128 {
                    let identifierAdvertised = names.contains(.identifier), childrenAdvertised = names.contains(.children)
                    row["identifier_advertised"] = identifierAdvertised; row["children_advertised"] = childrenAdvertised
                    if identifierAdvertised, ProcessInfo.processInfo.systemUptime < end {
                        nativeCalls += 1; row["informal_identifier"] = observed(informal.accessibilityAttributeValue(.identifier))
                    }
                    if childrenAdvertised, ProcessInfo.processInfo.systemUptime < end {
                        nativeCalls += 1; row["informal_children"] = observed(informal.accessibilityAttributeValue(.children))
                    }
                }
            }
            rows.append(row)
        }
        let finished = ProcessInfo.processInfo.systemUptime
        return ["classification": "Later failure-only paired bridge observations on original weak nodes; no traversal, matching or action",
                "node_record_limit": 64, "string_utf8_input_prefix_limit": 128, "informal_name_limit": 128,
                "per_live_node_native_call_limit": 5, "total_native_call_limit": 320, "native_calls": nativeCalls,
                "cooperative_budget_seconds": 0.02, "started_uptime": started, "finished_uptime": finished,
                "elapsed_seconds": finished - started, "budget_expired": finished >= end, "nodes": rows]
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

    func testProductionToolsLayoutMenuDistinguishesReservedSavedNamesAndSelectsExactIdentities() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        let suite = "forge.workspace.menu-label.tests.\(UUID().uuidString)"
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("forge-menu-label-\(UUID().uuidString)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: home) }
        let preferences = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
            panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: defaults)
        let saved = ["Default", "Delete Layout", "Layout: Default"].map { name in
            NativeWorkspaceLayout(id: UUID(), viewID: "tools", name: name,
                canvas: .init(width: max(1_280, NativeWorkspaceCatalog.tools.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                              height: max(900, NativeWorkspaceCatalog.tools.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
                panels: NativeWorkspaceCatalog.tools.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        }
        for (index, layout) in saved.enumerated() { try preferences.save(layout, activate: index == 0) }
        var expected = preferences.collection
        let workbench = WorkbenchPreferences(defaults: defaults), guided = GuidedModeCoordinator(defaults: defaults)
        let model = AppModel(bootstrapOperation: AppBootstrapOperation(factory: { throw CancellationError() }, pluginStatus: { _ in nil }),
            diagnosticPaths: AppPaths(home: home)); model.autoRefresh = false
        let hosting = NSHostingView(rootView: AnyView(ToolsView().environment(\.nativeWorkspacePreferences, preferences)
            .environmentObject(model).environmentObject(workbench).environmentObject(guided).graphiteWorkbench()))
        let owned = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1_240, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        owned.isReleasedWhenClosed = false; owned.title = "Tools saved-name collision \(UUID().uuidString)"; owned.contentView = hosting
        let ownedTitle = owned.title; window = owned
        var stage = "fixture", menus: [[String: Any]] = [], states: [[String: Any]] = [], failure: String?
        defer { nativeDraftRetainMeasurement(["classification": "Actual owned Tools menu label collision regression; stored names unchanged; no ordinary/desktop qualification",
            "stage": stage, "failure": failure.map { $0 as Any } ?? NSNull(), "menus": menus, "states": states, "flow_seconds": 30,
            "menu_limit": 4, "saved_names": saved.map(\.name)], name: "workspace-tools-saved-name-collision") }
        func requireOwner() throws {
            guard ProcessInfo.processInfo.systemUptime < deadline, owned.isVisible, owned.contentView === hosting,
                  hosting.window === owned, !hosting.isHiddenOrHasHiddenAncestor, owned.title == ownedTitle,
                  NSApp.windows.filter({ $0.title == ownedTitle }).count == 1,
                  model.app == nil, model.manager == nil, model.remoteManager == nil else {
                throw WorkspaceCanvasFixtureFailure("The collision regression lost its bounded exact native owners.")
            }
        }
        func stored() throws {
            try requireOwner()
            let bytes = try XCTUnwrap(defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let fresh = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: defaults)
            guard preferences.collection == expected, bytes == (try encoder.encode(expected)),
                  try JSONDecoder().decode(NativeWorkspaceCollection.self, from: bytes) == expected,
                  fresh.restorationError == nil, fresh.collection == expected, preferences.layouts(for: "tools") == saved,
                  states.count < 5 else { throw WorkspaceCanvasFixtureFailure("A menu action changed a saved name/layout or unexpected stored state.") }
            states.append(["stage": stage, "exact_collection_bytes_decode_fresh": true,
                "active_id": preferences.activeLayout(for: "tools").map { $0.id.uuidString as Any } ?? NSNull()])
        }
        func document() throws -> NativeWorkspaceDocumentView? {
            try requireOwner(); let matches = descendants(hosting).compactMap { $0 as? NativeWorkspaceDocumentView }
            guard matches.count <= 1, matches.allSatisfy({ $0.window === owned }) else {
                throw WorkspaceCanvasFixtureFailure("The collision fixture has duplicate or foreign canvases.")
            }; return matches.first
        }
        func choose(_ ordinal: Int) async throws {
            try requireOwner(); guard menus.count < 4 else { throw WorkspaceCanvasFixtureFailure("Collision menu exceeded four opens.") }
            var progress: [String: Any] = [:]
            let opener = try await nativeDraftObserveAXElement("workspace-layout-menu-tools", window: owned, hosting: hosting,
                deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 3), scope: .applicationContent, progress: &progress)
            guard opener.identifier == "workspace-layout-menu-tools", opener.enabled == true,
                  opener.role?.rawValue == kAXMenuButtonRole, let element = opener.exportedAX, let context = opener.exportedContext else {
                throw WorkspaceCanvasFixtureFailure("The collision fixture lacks its exact enabled exported layout-menu opener.")
            }
            let capture = WorkspaceSavedNameMenuCapture(window: owned, hosting: hosting, preferences: preferences,
                expected: expected, names: saved.map(\.name), ordinal: ordinal, deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 3))
            NotificationCenter.default.addObserver(capture, selector: #selector(WorkspaceSavedNameMenuCapture.didBegin(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
            NotificationCenter.default.addObserver(capture, selector: #selector(WorkspaceSavedNameMenuCapture.didEnd(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
            let timer = Timer(timeInterval: 0.02, target: capture, selector: #selector(WorkspaceSavedNameMenuCapture.fire(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .default); RunLoop.main.add(timer, forMode: .eventTracking)
            defer { timer.invalidate(); capture.stop(); menus.append(capture.receipt) }
            capture.armed = true; try requireOwner(); try context.requireOwnedAncestor(element)
            try context.pressToolsMenu(element, requestedIdentifier: "workspace-layout-menu-tools")
            while capture.result == nil {
                guard ProcessInfo.processInfo.systemUptime < capture.deadline else { throw WorkspaceCanvasFixtureFailure("Collision native menu exceeded its original three-second capture deadline.") }
                try await Task.sleep(for: .milliseconds(10))
            }
            if capture.cancellationRequested {
                while capture.endedAt == nil {
                    guard ProcessInfo.processInfo.systemUptime < capture.deadline else { throw WorkspaceCanvasFixtureFailure("The exact collision menu did not end within its original deadline.") }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            try XCTUnwrap(capture.result).get(); try requireOwner()
            guard let endedAt = capture.endedAt, endedAt < capture.deadline else { throw WorkspaceCanvasFixtureFailure("Collision native menu end witness is missing/late.") }
        }
        func close() async {
            owned.endEditing(for: nil); _ = owned.makeFirstResponder(nil); hosting.rootView = AnyView(EmptyView()); hosting.layoutSubtreeIfNeeded()
            owned.orderOut(nil); owned.contentView = nil; owned.close(); window = nil; await model.stopBootstrap(); model.telemetryBinding.detach()
        }
        do {
            try await waitUntil("Isolated collision fixture startup did not settle.", timeout: min(3, deadline - ProcessInfo.processInfo.systemUptime)) { !model.isBootstrapping }
            owned.orderFrontRegardless(); try stored()
            try await waitUntil("Initial saved Tools canvas did not mount.", timeout: 3) { hosting.layoutSubtreeIfNeeded(); return try document()?.panelHosts.count == 3 }
            let oldCanvas = try XCTUnwrap(document())
            stage = "menu-default"; try await choose(0); expected.activeLayoutIDs["tools"] = nil
            try await waitUntil("Actual Default did not dismantle the saved Tools canvas.", timeout: 3) { hosting.layoutSubtreeIfNeeded(); return try document() == nil }
            guard oldCanvas.panelHosts.isEmpty else { throw WorkspaceCanvasFixtureFailure("Default left native panel hosts attached.") }; try stored()
            for index in saved.indices {
                stage = "select-saved-" + saved[index].name; try await choose(index + 1); expected.activeLayoutIDs["tools"] = saved[index].id
                try await waitUntil("Exact saved-name selection did not mount its canvas.", timeout: 3) {
                    hosting.layoutSubtreeIfNeeded(); return try document()?.panelHosts.count == 3 && preferences.activeLayout(for: "tools") == saved[index]
                }
                let canvas = try XCTUnwrap(document())
                guard Set(canvas.panelHosts.keys) == Set(saved[index].panels.map(\.id)),
                      saved[index].panels.allSatisfy({ canvas.panelHosts[$0.id]?.frame == $0.frame.nativeRect && canvas.panelHosts[$0.id]?.isHidden == false }) else {
                    throw WorkspaceCanvasFixtureFailure("Exact saved identity/visible panel geometry was not restored.")
                }; try stored()
            }
            guard menus.count == 4, menus.allSatisfy({ $0["tracking_observers_removed"] as? Bool == true && $0["native_dispatch_returned"] as? Bool == true }) else {
                throw WorkspaceCanvasFixtureFailure("The four exact menu actions/removal witnesses were not retained.")
            }
            stage = "completed"; await close()
        } catch { failure = String(decoding: String(describing: error).utf8.prefix(1_024), as: UTF8.self); await close(); throw error }
    }

    func testProductionToolsExportedApplicationContentDefaultMenuPreservesAndReselectsSavedLayout() async throws {
        let identifierRoute: ToolsSharedControlIdentifierRoute = .exportedApplicationContent
        continueAfterFailure = true
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        let suite = "forge.workspace.default-menu.tests.\(UUID().uuidString)"
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("forge-workspace-default-menu-\(UUID().uuidString)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        let preferences = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
            panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: defaults)
        func seed(_ viewID: String, _ name: String) -> NativeWorkspaceLayout {
            let panels = NativeWorkspaceCatalog.panelsByView[viewID] ?? []
            return .init(id: UUID(), viewID: viewID, name: name,
                canvas: .init(width: max(1_280, panels.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                              height: max(900, panels.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
                panels: panels.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        }
        // Fixture setup only. Every tested layout/visibility change below is a native UI action.
        let marker = seed("tools", "Tools marker \(UUID().uuidString)")
        let independent = seed("diagnostics", "Independent \(UUID().uuidString)")
        try preferences.save(marker, activate: false)
        try preferences.save(independent)
        var expected = preferences.collection
        let workbench = WorkbenchPreferences(defaults: defaults)
        let guidedMode = GuidedModeCoordinator(defaults: defaults)
        let bootstrap = AppBootstrapOperation(factory: { throw CancellationError() }, pluginStatus: { _ in nil })
        let model = AppModel(bootstrapOperation: bootstrap, diagnosticPaths: AppPaths(home: home))
        model.autoRefresh = false
        let hosting = NSHostingView(rootView: AnyView(ToolsView()
            .environment(\.nativeWorkspacePreferences, preferences)
            .environmentObject(model).environmentObject(workbench).environmentObject(guidedMode).graphiteWorkbench()))
        let owned = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1_240, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        owned.isReleasedWhenClosed = false
        let ownedTitle = "Tools Default menu \(UUID().uuidString)"
        owned.title = ownedTitle; owned.contentView = hosting
        window = owned
        var stage = "fixture-created", records: [[String: Any]] = [], menus: [[String: Any]] = []
        var latestControlDiscovery: [String: Any] = [:]
        let menuLifecycle = identifierRoute == .exportedApplicationContent
            ? WorkspaceSharedControlsMenuLifecycleObservation(window: owned, hosting: hosting) : nil
        defer {
            nativeDraftRetainMeasurement(["classification": identifierRoute == .ordinary
                    ? "Separate real Tools shared native controls route; runtime assertions determine qualification, no all-view/desktop claim"
                    : "Separate actual Tools layout-menu Default and saved reselection; exported application-content route, no ordinary/whole-window/desktop qualification",
                "identifier_route": identifierRoute == .ordinary ? "ordinary-native-tree" : "exported-application-content",
                "stage": stage, "view_id": "tools", "flow_deadline_seconds": 45,
                "stage_record_limit": 16, "records": records, "menu_record_limit": 8, "menus": menus,
                "latest_control_discovery": latestControlDiscovery,
                "first_native_menu_lifecycle_observation": menuLifecycle.map { $0.evidence as Any } ?? NSNull(),
                "original_naming_whole_window_and_desktop_gates": "unchanged/open"], name: "workspace-tools-default-layout-menu")
        }
        defer { menuLifecycle?.stop() }
        func close() async {
            owned.endEditing(for: nil); _ = owned.makeFirstResponder(nil)
            hosting.rootView = AnyView(EmptyView()); hosting.layoutSubtreeIfNeeded()
            owned.orderOut(nil); owned.contentView = nil; owned.close(); window = nil
            await model.stopBootstrap(); model.telemetryBinding.detach()
        }
        func requireOwner() throws {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  owned.contentView === hosting, hosting.window === owned, owned.isVisible,
                  !hosting.isHiddenOrHasHiddenAncestor, owned.title == ownedTitle,
                  NSApp.windows.filter({ $0.title == ownedTitle }).count == 1 else {
                throw WorkspaceCanvasFixtureFailure("The shared controls lost their exact finite Tools window/hosting owner.")
            }
        }
        func control(_ identifier: String, menu: Bool = false) async throws -> NativeWorkspaceDraftAccessibilityNode {
            let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
            var progress: [String: Any] = [:]
            defer {
                latestControlDiscovery = progress
                latestControlDiscovery["identifier_route"] = "exported-application-content"
            }
            try requireOwner()
            let node = try await nativeDraftObserveAXElement(identifier, window: owned, hosting: hosting,
                deadline: end, scope: .applicationContent, progress: &progress)
            try requireOwner()
            progress["matched_target_snapshot"] = [
                "classification": "Cached exported target snapshot only; no new native getters or role acceptance",
                "identifier_utf8_prefix": node.identifier.map { String(decoding: $0.utf8.prefix(256), as: UTF8.self) as Any } ?? NSNull(),
                "role_utf8_prefix": node.role.map { String(decoding: $0.rawValue.utf8.prefix(128), as: UTF8.self) as Any } ?? NSNull(),
                "enabled": node.enabled.map { $0 as Any } ?? NSNull(),
                "exported_element_available": node.exportedAX != nil,
                "exported_owner_context_available": node.exportedContext != nil,
            ]
            guard node.exportedAX != nil, node.exportedContext != nil, node.identifier == identifier,
                  node.enabled == true, node.role?.rawValue == (menu ? kAXMenuButtonRole : kAXButtonRole) else {
                throw WorkspaceCanvasFixtureFailure("Shared control is not an enabled exact exported button/menu opener.")
            }
            return node
        }
        func settled(_ message: String, _ condition: () throws -> Bool) async throws {
            let remaining = min(3, deadline - ProcessInfo.processInfo.systemUptime)
            guard remaining > 0 else { throw WorkspaceCanvasFixtureFailure("Shared controls exceeded their 45-second flow admission bound.") }
            try await waitUntil(message, timeout: remaining) { try requireOwner(); hosting.layoutSubtreeIfNeeded(); return try condition() }
        }
        func requireState(_ label: String) throws {
            try requireOwner()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let storedBytes = try XCTUnwrap(defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            let decoded = try JSONDecoder().decode(NativeWorkspaceCollection.self, from: storedBytes)
            XCTAssertEqual(decoded, expected)
            let restored = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: defaults)
            XCTAssertEqual(preferences.collection, expected)
            XCTAssertEqual(defaults.data(forKey: NativeWorkspacePreferences.storageKey), try encoder.encode(expected))
            XCTAssertNil(restored.restorationError); XCTAssertEqual(restored.collection, expected)
            XCTAssertEqual(preferences.activeLayout(for: "diagnostics"), independent)
            guard preferences.collection == expected, restored.collection == expected, decoded == expected,
                  defaults.data(forKey: NativeWorkspacePreferences.storageKey) == (try encoder.encode(expected)),
                  restored.restorationError == nil, records.count < 16 else {
                throw WorkspaceCanvasFixtureFailure("The shared native action changed unexpected persisted state: " + label)
            }
            records.append(["stage": label, "complete_collection_and_bytes_exact": true,
                "fresh_owner_restoration_exact": true, "stored_collection_decode_exact": true, "saved_layout_count": expected.layouts.count])
        }
        func choose(_ command: String, panels: Bool) async throws {
            guard menus.count < 8 else { throw WorkspaceCanvasFixtureFailure("Shared native menu calls exceeded eight attempts.") }
            let opener = try await control(panels ? "workspace-panels-menu-tools" : "workspace-layout-menu-tools", menu: true)
            let titles = panels ? NativeWorkspaceCatalog.tools.map(\.title)
                : ["Default"] + preferences.layouts(for: "tools").map { "Layout: " + $0.name } + ["Save Layout As…", "Rename Layout…", "Delete Layout"]
            var states: [String: NSControl.StateValue] = [:]
            if panels {
                guard let layout = preferences.activeLayout(for: "tools") else { throw WorkspaceCanvasFixtureFailure("Panels requires the actual active Tools layout.") }
                for descriptor in NativeWorkspaceCatalog.tools {
                    states[descriptor.title] = layout.panels.first { $0.id == descriptor.id }?.isVisible == true ? .on : .off
                }
            }
            let capture = WorkspaceSharedControlsMenuCapture(window: owned, hosting: hosting,
                preferences: preferences, expectedCollection: expected, command: command, titles: titles,
                states: states, deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 3))
            if let menuLifecycle { capture.observeLifecycle(menuLifecycle, attemptOrdinal: menus.count + 1) }
            if identifierRoute == .exportedApplicationContent { capture.observeExactTrackingEnd() }
            NotificationCenter.default.addObserver(capture, selector: #selector(WorkspaceSharedControlsMenuCapture.didBegin(_:)),
                name: NSMenu.didBeginTrackingNotification, object: nil)
            let timer = Timer(timeInterval: 0.02, target: capture, selector: #selector(WorkspaceSharedControlsMenuCapture.fire(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .default); RunLoop.main.add(timer, forMode: .eventTracking)
            defer { timer.invalidate(); capture.stop(); menus.append(capture.receipt) }
            capture.armed = true
            if identifierRoute == .exportedApplicationContent {
                guard let element = opener.exportedAX, let context = opener.exportedContext else {
                    throw WorkspaceCanvasFixtureFailure("The exact shared exported opener lost its owner context.")
                }
                try context.requireOwnedAncestor(element)
            }
            guard opener.identifier == (panels ? "workspace-panels-menu-tools" : "workspace-layout-menu-tools"), opener.enabled == true else {
                throw WorkspaceCanvasFixtureFailure("The exact shared native opener changed before activation.")
            }
            if identifierRoute == .exportedApplicationContent {
                guard let element = opener.exportedAX, let context = opener.exportedContext else {
                    throw WorkspaceCanvasFixtureFailure("The exact shared exported opener lost its owner context.")
                }
                menuLifecycle?.noteSecondAction(returned: false, attemptOrdinal: menus.count + 1,
                    captureDeadline: capture.deadline, actionDeadline: context.deadline)
                try context.pressToolsMenu(element, requestedIdentifier: panels ? "workspace-panels-menu-tools" : "workspace-layout-menu-tools")
                menuLifecycle?.noteSecondAction(returned: true, attemptOrdinal: menus.count + 1,
                    captureDeadline: capture.deadline, actionDeadline: context.deadline)
            } else {
                try opener.press()
            }
            while !capture.isFinished {
                guard ProcessInfo.processInfo.systemUptime < capture.deadline else { throw WorkspaceCanvasFixtureFailure("The exact shared native menu did not complete its finite action.") }
                try await Task.sleep(for: .milliseconds(10))
            }
            try XCTUnwrap(capture.result).get(); try requireOwner()
            if identifierRoute == .exportedApplicationContent {
                while capture.exactTrackingEndedAt == nil {
                    guard ProcessInfo.processInfo.systemUptime < capture.deadline else {
                        throw WorkspaceCanvasFixtureFailure("The exact captured shared native menu did not report tracking end within its original deadline.")
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard let endedAt = capture.exactTrackingEndedAt, endedAt < capture.deadline,
                      ProcessInfo.processInfo.systemUptime < capture.deadline else {
                    throw WorkspaceCanvasFixtureFailure("The exact captured shared native menu did not report tracking end within its original deadline.")
                }
            }
        }
        do {
            try await waitUntil("The isolated Tools startup did not settle.") { !model.isBootstrapping }
            XCTAssertNil(model.app); XCTAssertNil(model.manager); XCTAssertNil(model.remoteManager)
            NSApp.activate(ignoringOtherApps: true); owned.makeKeyAndOrderFront(nil); owned.orderFrontRegardless()
            try requireState("default-baseline")
            stage = "customize"
            let customize = try await control("workspace-customize-tools"); try customize.press()
            try await settled("Actual Customize Layout did not select its new Tools layout.") { preferences.activeLayout(for: "tools") != nil }
            let custom = try XCTUnwrap(preferences.activeLayout(for: "tools"))
            XCTAssertNotEqual(custom.id, marker.id); XCTAssertNotEqual(custom.id, independent.id)
            var seeded = seed("tools", "Custom")
            seeded = .init(id: custom.id, viewID: seeded.viewID, name: seeded.name, canvas: seeded.canvas, panels: seeded.panels)
            expected.layouts.append(seeded); expected.activeLayoutIDs["tools"] = custom.id
            try requireState("customize")
            func optionalDocument() throws -> NativeWorkspaceDocumentView? {
                let documents = descendants(hosting).compactMap { $0 as? NativeWorkspaceDocumentView }
                guard documents.count <= 1, documents.allSatisfy({ $0.window === owned }) else {
                    throw WorkspaceCanvasFixtureFailure("Tools has duplicate or foreign native documents.")
                }
                return documents.first
            }
            func document() throws -> NativeWorkspaceDocumentView {
                try XCTUnwrap(optionalDocument(), "Tools has no mounted native document.")
            }
            try await settled("Tools Customize did not mount all three real panels.") {
                try optionalDocument()?.panelHosts.count == 3
            }
            let firstCanvas = try document()
            let savedLayouts = expected.layouts
            stage = "layout-menu-default"
            try await choose("Default", panels: false)
            expected.activeLayoutIDs["tools"] = nil
            try await settled("Actual layout-menu Default did not dismantle Tools custom canvas.") {
                try optionalDocument() == nil && preferences.activeLayout(for: "tools") == nil
            }
            guard firstCanvas.panelHosts.isEmpty, preferences.collection.layouts == savedLayouts,
                  preferences.layouts(for: "tools").contains(where: { $0.id == custom.id && $0 == custom }) else {
                throw WorkspaceCanvasFixtureFailure("Layout-menu Default did not dismantle the old canvas or preserve its saved layouts.")
            }
            try requireState(stage)
            _ = try await control("workspace-customize-tools")
            stage = "select-saved-after-menu-default"
            try await choose("Layout: " + custom.name, panels: false)
            expected.activeLayoutIDs["tools"] = custom.id
            try await settled("Saved menu selection after Default did not restore all three Tools panels.") {
                try optionalDocument()?.panelHosts.count == custom.panels.count
                    && preferences.activeLayout(for: "tools") == custom
            }
            let reselectedCanvas = try document()
            guard reselectedCanvas !== firstCanvas, reselectedCanvas.window === owned,
                  Set(reselectedCanvas.panelHosts.keys) == Set(custom.panels.map(\.id)),
                  reselectedCanvas.panelHosts.values.allSatisfy({ !$0.isHidden && $0.window === owned }),
                  preferences.collection.layouts == savedLayouts else {
                throw WorkspaceCanvasFixtureFailure("Saved menu reselection did not recreate the exact owned visible Tools canvas with unchanged saved layouts.")
            }
            try requireState(stage)
            guard menus.count == 2,
                  menus.map({ $0["actual_command"] as? String }) == ["Default", "Layout: " + custom.name],
                  menus.allSatisfy({ $0["native_dispatch_returned"] as? Bool == true
                    && $0["exact_tracking_end_uptime"] != nil
                    && $0["exact_tracking_end_observer_removed"] as? Bool == true }) else {
                throw WorkspaceCanvasFixtureFailure("Default and saved selection did not retain both exact native commands and end/removal witnesses.")
            }
            stage = "completed"
            await close()
        } catch {
            records.append(["stage": stage, "failure": String(String(describing: error).prefix(1_024))])
            await close(); throw error
        }
    }

    private enum ToolsSharedControlIdentifierRoute: Equatable { case ordinary, exportedApplicationContent }

    func testProductionToolsNativeSharedControlsRecoverPanelsRestoreSelectAndDelete() async throws {
        try await nativeToolsSharedControls(.ordinary)
    }

    func testProductionToolsExportedApplicationContentSharedControlsRecoverPanelsRestoreSelectAndDelete() async throws {
        try await nativeToolsSharedControls(.exportedApplicationContent)
    }

    func testProductionThirteenViewsExportedSharedMenusRecoverPanelsRestoreSelectAndDelete() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        let routes: [(viewID: String, root: @MainActor (AppModel) -> AnyView)] = [
            ("rig", { _ in AnyView(RigDashboardView()) }),
            ("mcp", { _ in AnyView(MCPServersView()) }),
            ("agents", { _ in AnyView(AgentsView()) }),
            ("tools", { _ in AnyView(ToolsView()) }),
            ("feed", { _ in AnyView(LiveFeedView()) }),
            ("projects", { AnyView(ProjectsOperatorView(client: $0.operatorManagerClient)) }),
            ("rune-forge.overview", { AnyView(RuneForgeOperatorView(client: $0.operatorManagerClient)) }),
            ("continuity", { AnyView(ContinuityOperatorView(client: $0.operatorManagerClient)) }),
            ("runtimes", { AnyView(RuntimesOperatorView(client: $0.operatorManagerClient)) }),
            ("provider", { AnyView(ProviderOperatorView(client: $0.operatorManagerClient)) }),
            ("evidence", { AnyView(EvidenceOperatorView(client: $0.operatorManagerClient)) }),
            ("diagnostics", { _ in AnyView(DiagnosticsView()) }),
            ("manager.folders", { _ in AnyView(ManagerSettingsView(initialSection: .folders)) }),
        ]
        let admitted = Set(NativeWorkspaceCatalog.panelsByView.keys.filter {
            !$0.hasPrefix("manager.") && !$0.hasPrefix("rune-forge.")
        } + ["manager.folders", "rune-forge.overview"])
        guard routes.count == 13, Set(routes.map(\.viewID)) == admitted else {
            throw WorkspaceCanvasFixtureFailure("The shared native menu table omitted or duplicated an existing main view.")
        }
        var completed: [String] = [], menus = 0, storedStates = 0
        defer {
            nativeDraftRetainMeasurement([
                "classification": "Actual native shared menus on 13 isolated production roots; validated application-content lookup, no sidebar/desktop/live-backend qualification",
                "completed_view_ids": completed, "expected_view_ids": admitted.sorted(),
                "native_menu_actions": menus, "complete_stored_state_checks": storedStates,
                "aggregate_deadline_seconds": 120, "within_deadline": ProcessInfo.processInfo.systemUptime < deadline,
                "execution_completed": completed.count == 13,
                "manager_namespace": "manager.folders", "rune_namespace": "rune-forge.overview",
            ], name: "workspace-thirteen-view-shared-menu-union")
        }
        for route in routes {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw WorkspaceCanvasFixtureFailure("The thirteen-view shared menu flow exceeded its aggregate deadline.")
            }
            try await nativeToolsSharedControls(.exportedApplicationContent, viewID: route.viewID,
                flowDeadline: deadline, makeRoot: route.root)
            let count = try XCTUnwrap(NativeWorkspaceCatalog.panelsByView[route.viewID]).count
            completed.append(route.viewID); menus += count + 5; storedStates += count + 8
        }
        guard Set(completed) == admitted, completed.count == 13, menus == 145, storedStates == 184,
              ProcessInfo.processInfo.systemUptime < deadline else {
            throw WorkspaceCanvasFixtureFailure("The shared main-view action/state union is incomplete or exceeded its deadline.")
        }
    }

    func testProductionThirteenViewsNativeRenameAndSaveAsPersistNamesAndLayoutIdentity() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        let routes: [(viewID: String, root: @MainActor (AppModel) -> AnyView)] = [
            ("rig", { _ in AnyView(RigDashboardView()) }),
            ("mcp", { _ in AnyView(MCPServersView()) }),
            ("agents", { _ in AnyView(AgentsView()) }),
            ("tools", { _ in AnyView(ToolsView()) }),
            ("feed", { _ in AnyView(LiveFeedView()) }),
            ("projects", { AnyView(ProjectsOperatorView(client: $0.operatorManagerClient)) }),
            ("rune-forge.overview", { AnyView(RuneForgeOperatorView(client: $0.operatorManagerClient)) }),
            ("continuity", { AnyView(ContinuityOperatorView(client: $0.operatorManagerClient)) }),
            ("runtimes", { AnyView(RuntimesOperatorView(client: $0.operatorManagerClient)) }),
            ("provider", { AnyView(ProviderOperatorView(client: $0.operatorManagerClient)) }),
            ("evidence", { AnyView(EvidenceOperatorView(client: $0.operatorManagerClient)) }),
            ("diagnostics", { _ in AnyView(DiagnosticsView()) }),
            ("manager.folders", { _ in AnyView(ManagerSettingsView(initialSection: .folders)) }),
        ]
        let admitted = Set(NativeWorkspaceCatalog.panelsByView.keys.filter {
            !$0.hasPrefix("manager.") && !$0.hasPrefix("rune-forge.")
        } + ["manager.folders", "rune-forge.overview"])
        guard routes.count == 13, Set(routes.map(\.viewID)) == admitted else {
            throw WorkspaceCanvasFixtureFailure("The native naming table omitted or duplicated an existing main view.")
        }
        var completed: [String] = []
        defer {
            nativeDraftRetainMeasurement([
                "classification": "Actual Rename and Save As on 13 isolated production roots; application-content opener and exact attached-sheet Save, no sidebar/desktop/live-backend qualification",
                "completed_view_ids": completed, "expected_view_ids": admitted.sorted(),
                "native_naming_commands": completed.count * 2,
                "aggregate_deadline_seconds": 120,
                "within_deadline": ProcessInfo.processInfo.systemUptime < deadline,
                "execution_completed": completed.count == 13,
            ], name: "workspace-thirteen-view-native-naming-union")
        }
        for route in routes {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw WorkspaceCanvasFixtureFailure("The main-view naming flow exceeded its aggregate deadline.")
            }
            let suite = "forge.workspace.naming.tests.\(UUID().uuidString)"
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("forge-workspace-naming-\(UUID().uuidString)")
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: home) }
            let preferences = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: defaults)
            func seed(_ viewID: String) throws -> NativeWorkspaceLayout {
                let panels = try XCTUnwrap(NativeWorkspaceCatalog.panelsByView[viewID])
                guard !panels.isEmpty, panels.count <= 16, Set(panels.map(\.id)).count == panels.count else {
                    throw WorkspaceCanvasFixtureFailure("Native naming received an empty, duplicated or oversized catalog.")
                }
                return .init(id: UUID(), viewID: viewID, name: "Original-" + viewID + "-" + UUID().uuidString,
                    canvas: .init(width: max(1_280, panels.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                                  height: max(900, panels.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
                    panels: panels.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
            }
            // Isolated initial layout setup only; both naming changes use the actual menus/editor/Save button.
            try preferences.save(seed(route.viewID))
            try preferences.save(seed(route.viewID == "diagnostics" ? "tools" : "diagnostics"))
            let workbench = WorkbenchPreferences(defaults: defaults)
            let guidedMode = GuidedModeCoordinator(defaults: defaults)
            let bootstrap = AppBootstrapOperation(factory: { throw CancellationError() }, pluginStatus: { _ in nil })
            let model = AppModel(bootstrapOperation: bootstrap, diagnosticPaths: AppPaths(home: home))
            model.autoRefresh = false
            let hosting = NSHostingView(rootView: AnyView(route.root(model)
                .environment(\.nativeWorkspacePreferences, preferences)
                .environmentObject(model).environmentObject(workbench).environmentObject(guidedMode).graphiteWorkbench()))
            hosting.sizingOptions = []
            let owned = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1_240, height: 900),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            owned.isReleasedWhenClosed = false
            owned.title = "Forge workspace naming test " + UUID().uuidString
            owned.contentView = hosting; window = owned
            func close() async {
                if let sheet = owned.attachedSheet { owned.endSheet(sheet) }
                owned.endEditing(for: nil); _ = owned.makeFirstResponder(nil)
                hosting.rootView = AnyView(EmptyView()); hosting.layoutSubtreeIfNeeded()
                owned.orderOut(nil); owned.contentView = nil; owned.close(); window = nil
                model.stopRigOperationalMonitoring()
                await model.stopBootstrap(); model.telemetryBinding.detach()
            }
            do {
                NSApp.activate(ignoringOtherApps: true); owned.makeKeyAndOrderFront(nil); owned.orderFrontRegardless()
                try await nativeWorkspaceVerifyNaming(window: owned, hosting: hosting, preferences: preferences,
                    defaults: defaults, viewID: route.viewID, deadline: deadline) { report in
                    self.nativeDraftRetainMeasurement(report, name: "workspace-" + route.viewID + "-native-naming")
                }
                await close()
                completed.append(route.viewID)
            } catch {
                await close(); throw error
            }
        }
        guard completed.count == 13, Set(completed) == admitted,
              ProcessInfo.processInfo.systemUptime < deadline else {
            throw WorkspaceCanvasFixtureFailure("The native naming union is incomplete or exceeded its deadline.")
        }
    }

    private func nativeToolsSharedControls(_ identifierRoute: ToolsSharedControlIdentifierRoute,
        viewID: String = "tools", flowDeadline: TimeInterval? = nil,
        makeRoot: (@MainActor (AppModel) -> AnyView)? = nil) async throws {
        continueAfterFailure = true
        let deadline = min(flowDeadline ?? .infinity, ProcessInfo.processInfo.systemUptime + 45)
        let descriptors = try XCTUnwrap(NativeWorkspaceCatalog.panelsByView[viewID])
        guard !descriptors.isEmpty, descriptors.count <= 16, Set(descriptors.map(\.id)).count == descriptors.count else {
            throw WorkspaceCanvasFixtureFailure("Shared-control catalog is empty, duplicated or exceeds the admitted main-view bound.")
        }
        let primary = try XCTUnwrap(descriptors.first)
        let menuLimit = descriptors.count + 5
        let stateLimit = makeRoot == nil && viewID == "tools" ? 16 : descriptors.count + 8
        let suite = "forge.workspace.controls.tests.\(UUID().uuidString)"
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("forge-workspace-controls-\(UUID().uuidString)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        let preferences = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
            panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: defaults)
        func seed(_ viewID: String, _ name: String) -> NativeWorkspaceLayout {
            let panels = NativeWorkspaceCatalog.panelsByView[viewID] ?? []
            return .init(id: UUID(), viewID: viewID, name: name,
                canvas: .init(width: max(1_280, panels.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0),
                              height: max(900, panels.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)),
                panels: panels.map { .init(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
        }
        // Fixture setup only. Every tested layout/visibility change below is a native UI action.
        let marker = seed(viewID, "Tools marker \(UUID().uuidString)")
        let independent = seed(viewID == "diagnostics" ? "tools" : "diagnostics", "Independent \(UUID().uuidString)")
        try preferences.save(marker, activate: false)
        try preferences.save(independent)
        var expected = preferences.collection
        let workbench = WorkbenchPreferences(defaults: defaults)
        let guidedMode = GuidedModeCoordinator(defaults: defaults)
        let bootstrap = AppBootstrapOperation(factory: { throw CancellationError() }, pluginStatus: { _ in nil })
        let model = AppModel(bootstrapOperation: bootstrap, diagnosticPaths: AppPaths(home: home))
        model.autoRefresh = false
        let hosting = NSHostingView(rootView: AnyView((makeRoot?(model) ?? AnyView(ToolsView()))
            .environment(\.nativeWorkspacePreferences, preferences)
            .environmentObject(model).environmentObject(workbench).environmentObject(guidedMode).graphiteWorkbench()))
        if makeRoot != nil { hosting.sizingOptions = [] }
        let owned = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1_240, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        owned.isReleasedWhenClosed = false
        let ownedTitle = "Tools shared controls \(UUID().uuidString)"
        owned.title = ownedTitle; owned.contentView = hosting
        window = owned
        var stage = "fixture-created", records: [[String: Any]] = [], menus: [[String: Any]] = []
        var latestControlDiscovery: [String: Any] = [:]
        let menuLifecycle = identifierRoute == .exportedApplicationContent
            ? WorkspaceSharedControlsMenuLifecycleObservation(window: owned, hosting: hosting) : nil
        defer {
            nativeDraftRetainMeasurement(["classification": makeRoot != nil
                    ? "Actual shared controls on one isolated production root; validated application-content lookup, original ordinary/whole-window and desktop gates remain separate"
                    : identifierRoute == .ordinary
                    ? "Separate real Tools shared native controls route; runtime assertions determine qualification, no all-view/desktop claim"
                    : "Separate real Tools exported application-content controls route; standard Zoom descendants excluded only after exact validation, original ordinary/whole-window gates unchanged/open; no all-view/desktop claim",
                "identifier_route": identifierRoute == .ordinary ? "ordinary-native-tree" : "exported-application-content",
                "stage": stage, "view_id": viewID, "flow_deadline_seconds": 45,
                "stage_record_limit": stateLimit, "records": records, "menu_record_limit": menuLimit, "menus": menus,
                "latest_control_discovery": latestControlDiscovery,
                "first_native_menu_lifecycle_observation": menuLifecycle.map { $0.evidence as Any } ?? NSNull(),
                "original_naming_whole_window_and_desktop_gates": "unchanged/open"], name: "workspace-" + viewID + "-shared-controls")
        }
        defer { menuLifecycle?.stop() }
        func close() async {
            owned.endEditing(for: nil); _ = owned.makeFirstResponder(nil)
            hosting.rootView = AnyView(EmptyView()); hosting.layoutSubtreeIfNeeded()
            owned.orderOut(nil); owned.contentView = nil; owned.close(); window = nil
            model.stopRigOperationalMonitoring()
            await model.stopBootstrap(); model.telemetryBinding.detach()
        }
        func requireOwner() throws {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  owned.contentView === hosting, hosting.window === owned, owned.isVisible,
                  !hosting.isHiddenOrHasHiddenAncestor, owned.title == ownedTitle,
                  NSApp.windows.filter({ $0.title == ownedTitle }).count == 1 else {
                throw WorkspaceCanvasFixtureFailure("The shared controls lost their exact finite Tools window/hosting owner.")
            }
        }
        func requireAncestor(_ object: AnyObject, before end: TimeInterval) throws {
            var cursor = object, seen = Set<ObjectIdentifier>()
            for _ in 0..<48 {
                try requireOwner()
                guard ProcessInfo.processInfo.systemUptime < end else { throw WorkspaceCanvasFixtureFailure("Shared-control native ancestry exceeded its operation deadline.") }
                guard seen.insert(ObjectIdentifier(cursor)).inserted else { throw WorkspaceCanvasFixtureFailure("Shared-control native ancestry repeated an object.") }
                if cursor === owned { return }
                guard !(cursor is NSWindow) else { throw WorkspaceCanvasFixtureFailure("Shared control belongs to another native window.") }
                let raw: Any?
                if let formal = cursor as? any NSAccessibilityProtocol { raw = formal.accessibilityParent() }
                else if let legacy = cursor as? NSObject {
                    let names = legacy.accessibilityAttributeNames()
                    guard names.count <= 128, names.contains(.parent) else { throw WorkspaceCanvasFixtureFailure("Shared-control native parent is unavailable/unbounded.") }
                    raw = legacy.accessibilityAttributeValue(.parent)
                } else { throw WorkspaceCanvasFixtureFailure("Shared-control native parent bridge is unavailable.") }
                if let formal = raw as? any NSAccessibilityProtocol { cursor = formal as AnyObject }
                else if let native = raw as? NSObject { cursor = native }
                else { throw WorkspaceCanvasFixtureFailure("Shared-control native ancestry does not reach its owned window.") }
            }
            throw WorkspaceCanvasFixtureFailure("Shared-control native ancestry exceeded 48 objects.")
        }
        func control(_ identifier: String, menu: Bool = false) async throws -> NativeWorkspaceDraftAccessibilityNode {
            let end = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
            if identifierRoute == .exportedApplicationContent {
                var progress: [String: Any] = [:]
                defer {
                    latestControlDiscovery = progress
                    latestControlDiscovery["identifier_route"] = "exported-application-content"
                }
                try requireOwner()
                let node = try await nativeDraftObserveAXElement(identifier, window: owned, hosting: hosting,
                    deadline: end, scope: .applicationContent, progress: &progress)
                try requireOwner()
                progress["matched_target_snapshot"] = [
                    "classification": "Cached exported target snapshot only; no new native getters or role acceptance",
                    "identifier_utf8_prefix": node.identifier.map { String(decoding: $0.utf8.prefix(256), as: UTF8.self) as Any } ?? NSNull(),
                    "role_utf8_prefix": node.role.map { String(decoding: $0.rawValue.utf8.prefix(128), as: UTF8.self) as Any } ?? NSNull(),
                    "enabled": node.enabled.map { $0 as Any } ?? NSNull(),
                    "exported_element_available": node.exportedAX != nil,
                    "exported_owner_context_available": node.exportedContext != nil,
                ]
                guard node.exportedAX != nil, node.exportedContext != nil, node.identifier == identifier,
                      node.enabled == true, node.role?.rawValue == (menu ? kAXMenuButtonRole : kAXButtonRole) else {
                    throw WorkspaceCanvasFixtureFailure("Shared control is not an enabled exact exported button/menu opener.")
                }
                return node
            }
            var attempt = 0
            var latestOriginalNodes: [NativeWorkspaceDraftWeakBridgeReceipt] = []
            repeat {
                try requireOwner(); hosting.layoutSubtreeIfNeeded()
                attempt += 1
                latestOriginalNodes.removeAll(keepingCapacity: true)
                latestControlDiscovery = ["classification": "Original native tree and Identifier predicate only; no extra queries or acceptance route",
                    "requested_identifier_utf8_prefix": String(decoding: identifier.utf8.prefix(128), as: UTF8.self),
                    "attempt": attempt, "operation_deadline": end, "phase": "original-tree-start", "node_limit": 512,
                    "node_record_limit": 64, "identifier_utf8_input_prefix_limit": 128, "type_utf8_input_prefix_limit": 128]
                let matches: [NativeWorkspaceDraftAccessibilityNode]
                do {
                    let tree = try nativeDraftAccessibilityTree(hosting, deadline: end, limit: 512)
                    var identified = 0, emptyIdentifiers = 0, ordinal = 0, nodeRows: [[String: Any]] = []
                    matches = tree.filter {
                        let actual = $0.identifier
                        ordinal += 1
                        if actual != nil { identified += 1 }
                        if actual?.isEmpty == true { emptyIdentifiers += 1 }
                        if nodeRows.count < 64 {
                            latestOriginalNodes.append(NativeWorkspaceDraftWeakBridgeReceipt(object: $0.object,
                                ordinal: ordinal, identifier: actual))
                            nodeRows.append(["node_ordinal": ordinal,
                                "object_type_utf8_prefix": String(decoding: String(reflecting: type(of: $0.object)).utf8.prefix(128), as: UTF8.self),
                                "identifier_utf8_prefix": actual.map { String(decoding: $0.utf8.prefix(128), as: UTF8.self) as Any } ?? NSNull()])
                        }
                        return actual == identifier
                    }
                    latestControlDiscovery["phase"] = "original-filter-complete"
                    latestControlDiscovery["returned_tree_nodes"] = tree.count
                    latestControlDiscovery["nil_identifiers"] = tree.count - identified
                    latestControlDiscovery["empty_identifiers"] = emptyIdentifiers
                    latestControlDiscovery["non_empty_identifiers"] = identified - emptyIdentifiers
                    latestControlDiscovery["nodes_first64"] = nodeRows
                    latestControlDiscovery["exact_matches"] = matches.count
                }
                guard matches.count <= 1 else { throw WorkspaceCanvasFixtureFailure("Duplicate shared-control native identifier: " + identifier) }
                if let match = matches.first {
                    try requireAncestor(match.object, before: end)
                    guard match.enabled == true, match.role?.rawValue == kAXButtonRole
                        || (menu && match.role?.rawValue == kAXPopUpButtonRole) else {
                        throw WorkspaceCanvasFixtureFailure("Shared control is not an enabled native button/menu opener.")
                    }
                    return match
                }
                try await Task.sleep(for: .milliseconds(20))
            } while ProcessInfo.processInfo.systemUptime < end
            latestControlDiscovery["post_failure_paired_bridge"] = nativeDraftControlBridgeFailureDiagnostic(latestOriginalNodes)
            throw WorkspaceCanvasFixtureFailure("The owned Tools native bridge did not expose " + identifier)
        }
        func settled(_ message: String, _ condition: () throws -> Bool) async throws {
            let remaining = min(3, deadline - ProcessInfo.processInfo.systemUptime)
            guard remaining > 0 else { throw WorkspaceCanvasFixtureFailure("Shared controls exceeded their 45-second flow admission bound.") }
            try await waitUntil(message, timeout: remaining) { try requireOwner(); hosting.layoutSubtreeIfNeeded(); return try condition() }
        }
        func requireState(_ label: String) throws {
            try requireOwner()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let restored = NativeWorkspacePreferences(knownPanelIDsByView: NativeWorkspaceCatalog.knownPanelIDsByView,
                panelSizeBoundsByView: NativeWorkspaceCatalog.sizeBoundsByView, defaults: defaults)
            XCTAssertEqual(preferences.collection, expected)
            XCTAssertEqual(defaults.data(forKey: NativeWorkspacePreferences.storageKey), try encoder.encode(expected))
            XCTAssertNil(restored.restorationError); XCTAssertEqual(restored.collection, expected)
            XCTAssertEqual(preferences.activeLayout(for: independent.viewID), independent)
            guard preferences.collection == expected, restored.collection == expected,
                  defaults.data(forKey: NativeWorkspacePreferences.storageKey) == (try encoder.encode(expected)),
                  restored.restorationError == nil, records.count < stateLimit else {
                throw WorkspaceCanvasFixtureFailure("The shared native action changed unexpected persisted state: " + label)
            }
            records.append(["stage": label, "complete_collection_and_bytes_exact": true,
                "fresh_owner_restoration_exact": true, "saved_layout_count": expected.layouts.count])
        }
        func choose(_ command: String, panels: Bool) async throws {
            guard menus.count < menuLimit else { throw WorkspaceCanvasFixtureFailure("Shared native menu calls exceeded the admitted catalog flow bound.") }
            let opener = try await control(panels ? "workspace-panels-menu-" + viewID : "workspace-layout-menu-" + viewID, menu: true)
            let titles = panels ? descriptors.map(\.title)
                : ["Default"] + preferences.layouts(for: viewID).map { "Layout: " + $0.name } + ["Save Layout As…", "Rename Layout…", "Delete Layout"]
            var states: [String: NSControl.StateValue] = [:]
            if panels {
                guard let layout = preferences.activeLayout(for: viewID) else { throw WorkspaceCanvasFixtureFailure("Panels requires the actual active Tools layout.") }
                for descriptor in descriptors {
                    states[descriptor.title] = layout.panels.first { $0.id == descriptor.id }?.isVisible == true ? .on : .off
                }
            }
            let capture = WorkspaceSharedControlsMenuCapture(window: owned, hosting: hosting,
                preferences: preferences, expectedCollection: expected, command: command, titles: titles,
                states: states, deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 3))
            if let menuLifecycle { capture.observeLifecycle(menuLifecycle, attemptOrdinal: menus.count + 1) }
            if identifierRoute == .exportedApplicationContent { capture.observeExactTrackingEnd() }
            NotificationCenter.default.addObserver(capture, selector: #selector(WorkspaceSharedControlsMenuCapture.didBegin(_:)),
                name: NSMenu.didBeginTrackingNotification, object: nil)
            let timer = Timer(timeInterval: 0.02, target: capture, selector: #selector(WorkspaceSharedControlsMenuCapture.fire(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .default); RunLoop.main.add(timer, forMode: .eventTracking)
            defer { timer.invalidate(); capture.stop(); menus.append(capture.receipt) }
            capture.armed = true
            if identifierRoute == .exportedApplicationContent {
                guard let element = opener.exportedAX, let context = opener.exportedContext else {
                    throw WorkspaceCanvasFixtureFailure("The exact shared exported opener lost its owner context.")
                }
                try context.requireOwnedAncestor(element)
            } else {
                try requireAncestor(opener.object, before: capture.deadline)
            }
            guard opener.identifier == (panels ? "workspace-panels-menu-" + viewID : "workspace-layout-menu-" + viewID), opener.enabled == true else {
                throw WorkspaceCanvasFixtureFailure("The exact shared native opener changed before activation.")
            }
            if identifierRoute == .exportedApplicationContent {
                guard let element = opener.exportedAX, let context = opener.exportedContext else {
                    throw WorkspaceCanvasFixtureFailure("The exact shared exported opener lost its owner context.")
                }
                menuLifecycle?.noteSecondAction(returned: false, attemptOrdinal: menus.count + 1,
                    captureDeadline: capture.deadline, actionDeadline: context.deadline)
                if viewID == "tools" {
                    try context.pressToolsMenu(element, requestedIdentifier: panels ? "workspace-panels-menu-tools" : "workspace-layout-menu-tools")
                } else {
                    try context.pressWorkspaceMenu(element, viewID: viewID,
                        requestedIdentifier: panels ? "workspace-panels-menu-" + viewID : "workspace-layout-menu-" + viewID)
                }
                menuLifecycle?.noteSecondAction(returned: true, attemptOrdinal: menus.count + 1,
                    captureDeadline: capture.deadline, actionDeadline: context.deadline)
            } else {
                try opener.press()
            }
            while !capture.isFinished {
                guard ProcessInfo.processInfo.systemUptime < capture.deadline else { throw WorkspaceCanvasFixtureFailure("The exact shared native menu did not complete its finite action.") }
                try await Task.sleep(for: .milliseconds(10))
            }
            try XCTUnwrap(capture.result).get(); try requireOwner()
            if identifierRoute == .exportedApplicationContent {
                while capture.exactTrackingEndedAt == nil {
                    guard ProcessInfo.processInfo.systemUptime < capture.deadline else {
                        throw WorkspaceCanvasFixtureFailure("The exact captured shared native menu did not report tracking end within its original deadline.")
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard let endedAt = capture.exactTrackingEndedAt, endedAt < capture.deadline,
                      ProcessInfo.processInfo.systemUptime < capture.deadline else {
                    throw WorkspaceCanvasFixtureFailure("The exact captured shared native menu did not report tracking end within its original deadline.")
                }
            }
        }
        do {
            try await waitUntil("The isolated Tools startup did not settle.") { !model.isBootstrapping }
            XCTAssertNil(model.app); XCTAssertNil(model.manager); XCTAssertNil(model.remoteManager)
            NSApp.activate(ignoringOtherApps: true); owned.makeKeyAndOrderFront(nil); owned.orderFrontRegardless()
            try requireState("default-baseline")
            stage = "customize"
            let customize = try await control("workspace-customize-" + viewID); try customize.press()
            try await settled("Actual Customize Layout did not select its new Tools layout.") { preferences.activeLayout(for: viewID) != nil }
            let custom = try XCTUnwrap(preferences.activeLayout(for: viewID))
            XCTAssertNotEqual(custom.id, marker.id); XCTAssertNotEqual(custom.id, independent.id)
            var seeded = seed(viewID, "Custom")
            seeded = .init(id: custom.id, viewID: seeded.viewID, name: seeded.name, canvas: seeded.canvas, panels: seeded.panels)
            expected.layouts.append(seeded); expected.activeLayoutIDs[viewID] = custom.id
            try requireState("customize")
            func optionalDocument() throws -> NativeWorkspaceDocumentView? {
                let documents = descendants(hosting).compactMap { $0 as? NativeWorkspaceDocumentView }
                guard documents.count <= 1, documents.allSatisfy({ $0.window === owned }) else {
                    throw WorkspaceCanvasFixtureFailure("Tools has duplicate or foreign native documents.")
                }
                return documents.first
            }
            func document() throws -> NativeWorkspaceDocumentView {
                try XCTUnwrap(optionalDocument(), "Tools has no mounted native document.")
            }
            try await settled("Customize did not mount every admitted catalog panel.") {
                try optionalDocument()?.panelHosts.count == descriptors.count
            }
            let canvas = try document(), panel = try XCTUnwrap(canvas.panelHosts[primary.id]), panelHosting = panel.hostingView
            func setExpectedShown(_ id: String, _ visible: Bool) throws {
                let layoutIndex = try XCTUnwrap(expected.layouts.firstIndex { $0.id == custom.id && $0.viewID == viewID })
                let panelIndex = try XCTUnwrap(expected.layouts[layoutIndex].panels.firstIndex { $0.id == id })
                expected.layouts[layoutIndex].panels[panelIndex].isVisible = visible
            }
            for shown in [false, true] {
                stage = shown ? "panels-show" : "panels-hide"
                try await choose(primary.title, panels: true); try setExpectedShown(primary.id, shown)
                try await settled("Actual Panels menu did not apply Tools visibility.") { panel.isHidden == !shown }
                XCTAssertTrue(canvas.panelHosts[primary.id] === panel); XCTAssertTrue(panel.hostingView === panelHosting)
                try requireState(stage)
            }
            for descriptor in descriptors {
                stage = "hide-all-" + descriptor.id
                try await choose(descriptor.title, panels: true); try setExpectedShown(descriptor.id, false)
                try await settled("Actual Panels command did not hide its Tools panel.") { canvas.panelHosts[descriptor.id]?.isHidden == true }
                try requireState(stage)
            }
            XCTAssertTrue(canvas.panelHosts.values.allSatisfy(\.isHidden))
            stage = "recover-all-hidden"
            try await choose(primary.title, panels: true); try setExpectedShown(primary.id, true)
            try await settled("The all-hidden workspace did not recover through its Panels menu.") { !panel.isHidden }
            XCTAssertTrue(canvas.panelHosts[primary.id] === panel); XCTAssertTrue(panel.hostingView === panelHosting)
            try requireState(stage)
            stage = "restore-default"
            let restore = try await control("workspace-restore-default-" + viewID); try restore.press()
            expected.activeLayoutIDs[viewID] = nil
            try await settled("Actual Restore Default did not dismantle Tools custom canvas.") { try optionalDocument() == nil }
            XCTAssertTrue(canvas.panelHosts.isEmpty); try requireState(stage)
            stage = "select-saved"
            try await choose("Layout: " + custom.name, panels: false); expected.activeLayoutIDs[viewID] = custom.id
            try await settled("Actual saved selection did not restore its Tools canvas.") {
                try optionalDocument()?.panelHosts[primary.id]?.isHidden == false
            }
            XCTAssertEqual(try document().panelHosts.count, 1, "Previously hidden panels must stay unconstructed on this new canvas.")
            try requireState(stage)
            stage = "delete-selected"
            try await choose("Delete Layout", panels: false)
            expected.layouts.removeAll { $0.id == custom.id }; expected.activeLayoutIDs[viewID] = nil
            try await settled("Actual Delete Layout did not restore the Tools default composition.") { try optionalDocument() == nil }
            _ = try await control("workspace-customize-" + viewID)
            try requireState(stage)
            XCTAssertEqual(preferences.layouts(for: viewID), [marker])
            guard menus.count == menuLimit, records.count == descriptors.count + 8 else {
                throw WorkspaceCanvasFixtureFailure("The shared native control flow omitted a menu action or stored-state check.")
            }
            stage = "completed"
            await close()
        } catch {
            records.append(["stage": stage, "failure": String(String(describing: error).prefix(1_024))])
            await close(); throw error
        }
    }

    func testCustomizeSkipsUnicodeCaseFoldCollisionAndPreservesSavedLayouts() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        let fixture = try await mountScope()
        let collision = workspaceLayout(name: "Cu\u{017f}tom")
        try fixture.preferences.save(collision, activate: false)
        try fixture.preferences.reset("fixture")
        try await waitUntil("Default must dismantle the fixture canvas before Customize.") {
            fixture.hosting.layoutSubtreeIfNeeded()
            return !self.descendants(fixture.hosting).contains { $0 is NativeWorkspaceDocumentView }
        }
        let baseline = fixture.preferences.collection
        let beforeBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
        var progress: [String: Any] = [:]
        var pressed = false
        defer {
            nativeDraftRetainMeasurement([
                "classification": "Actual Customize button with a valid nonactive Unicode case-fold collision; runtime assertions determine qualification",
                "collision_name": collision.name, "expected_name": "Custom 2", "press_returned": pressed,
                "active_name": (fixture.preferences.activeLayout(for: "fixture")?.name).map { $0 as Any } ?? NSNull(),
                "saved_names": fixture.preferences.layouts(for: "fixture").map(\.name),
                "prior_layouts_unchanged": baseline.layouts.allSatisfy { prior in
                    fixture.preferences.collection.layouts.first { $0.id == prior.id } == prior
                },
                "control_discovery": progress,
            ], name: "workspace-customize-unicode-name-collision")
        }
        let control = try await nativeDraftObserveAXElement("workspace-customize-fixture",
            window: fixture.window, hosting: fixture.hosting,
            deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 3),
            scope: .applicationContent, progress: &progress)
        guard ProcessInfo.processInfo.systemUptime < deadline,
              fixture.window.contentView === fixture.hosting, fixture.hosting.window === fixture.window,
              fixture.window.isVisible, control.identifier == "workspace-customize-fixture",
              control.role == .button, control.enabled == true,
              fixture.preferences.collection == baseline,
              fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == beforeBytes else {
            throw WorkspaceCanvasFixtureFailure("Customize lost its exact owned button or saved-layout baseline.")
        }
        try control.press(); pressed = true
        try await waitUntil("Actual Customize must choose Custom 2 after the Unicode case-fold collision.",
            timeout: min(3, deadline - ProcessInfo.processInfo.systemUptime)) {
            fixture.preferences.activeLayout(for: "fixture")?.name == "Custom 2"
        }
        let created = try XCTUnwrap(fixture.preferences.activeLayout(for: "fixture"))
        XCTAssertFalse(baseline.layouts.contains { $0.id == created.id })
        var expected = baseline
        expected.layouts.append(created); expected.activeLayoutIDs["fixture"] = created.id
        XCTAssertEqual(fixture.preferences.collection, expected)
        let bytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
        XCTAssertEqual(try JSONDecoder().decode(NativeWorkspaceCollection.self, from: bytes), expected)
        let bounds = workspaceDescriptors.reduce(into: [String: NativeWorkspacePanelSizeBounds]()) { result, panel in
            result[panel.id] = .init(minimumWidth: panel.minimumSize.width, minimumHeight: panel.minimumSize.height,
                maximumWidth: panel.maximumSize.width, maximumHeight: panel.maximumSize.height)
        }
        let restored = NativeWorkspacePreferences(knownPanelIDsByView: ["fixture": Set(workspaceDescriptors.map(\.id))],
            panelSizeBoundsByView: ["fixture": bounds], defaults: fixture.defaults)
        XCTAssertNil(restored.restorationError)
        XCTAssertEqual(restored.collection, expected)
        XCTAssertNil(fixture.model.app); XCTAssertNil(fixture.model.manager); XCTAssertNil(fixture.model.remoteManager)
        XCTAssertFalse(fixture.model.hasLoadedInitialSettings)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime, deadline)
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

    func testActualHideReleasesFocusedMoveHandleAndSamePanelResumesKeyboardMovement() async throws {
        continueAfterFailure = true
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var report: [String: Any] = ["classification": "Owned native Hide/focus regression; automatic AppKit focus behavior is measured, not assumed",
            "stage": "mount", "case_deadline_seconds": 20, "hidden_arrow_sent": false, "completed": false]
        defer { nativeDraftRetainMeasurement(report, name: "workspace-hidden-move-handle-focus") }
        let fixture = try await mountScope()
        let document = try await mountedDocument(fixture)
        let panel = try XCTUnwrap(document.panelHosts["alpha"])
        let contentHost = panel.hostingView
        try await waitUntil("The actual panel state probe did not mount.") { self.stateReadback(in: contentHost) != nil }
        let probe = try XCTUnwrap(stateReadback(in: contentHost))
        let localIdentity = try XCTUnwrap(probe.identity), localText = probe.text
        let originalFrame = panel.frame, originalCollection = fixture.preferences.collection
        let bounds = Dictionary(uniqueKeysWithValues: workspaceDescriptors.map {
            ($0.id, NativeWorkspacePanelSizeBounds(minimumWidth: $0.minimumSize.width, minimumHeight: $0.minimumSize.height,
                maximumWidth: $0.maximumSize.width, maximumHeight: $0.maximumSize.height))
        })
        func requireOwner() throws {
            report["owner_requirements"] = [
                "within_deadline": ProcessInfo.processInfo.systemUptime < deadline,
                "window_visible": fixture.window.isVisible, "window_key": fixture.window.isKeyWindow,
                "window_content_is_hosting": fixture.window.contentView === fixture.hosting,
                "hosting_window_is_owned": fixture.hosting.window === fixture.window,
                "document_window_is_owned": document.window === fixture.window,
                "panel_window_is_owned": panel.window === fixture.window,
                "same_panel": document.panelHosts["alpha"] === panel,
                "same_content_host": panel.hostingView === contentHost,
                "same_model": probe.model === fixture.model, "same_workbench": probe.workbench === fixture.workbench,
                "same_guided_mode": probe.guidedMode === fixture.guidedMode,
                "same_local_identity": probe.identity == localIdentity, "same_local_text": probe.text == localText,
                "nil_app": fixture.model.app == nil, "nil_manager": fixture.model.manager == nil,
                "nil_remote_manager": fixture.model.remoteManager == nil,
            ]
            guard ProcessInfo.processInfo.systemUptime < deadline, fixture.window.isVisible, fixture.window.isKeyWindow,
                  fixture.window.contentView === fixture.hosting, fixture.hosting.window === fixture.window,
                  document.window === fixture.window, panel.window === fixture.window,
                  document.panelHosts["alpha"] === panel, panel.hostingView === contentHost,
                  probe.model === fixture.model, probe.workbench === fixture.workbench,
                  probe.guidedMode === fixture.guidedMode, probe.identity == localIdentity, probe.text == localText,
                  fixture.model.app == nil, fixture.model.manager == nil, fixture.model.remoteManager == nil else {
                throw WorkspaceCanvasFixtureFailure("The hidden-focus regression lost its bounded exact fixture/owners.")
            }
        }
        func assertStored(_ expected: NativeWorkspaceCollection) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            XCTAssertEqual(fixture.preferences.collection, expected)
            XCTAssertEqual(bytes, try encoder.encode(expected))
            XCTAssertEqual(try JSONDecoder().decode(NativeWorkspaceCollection.self, from: bytes), expected)
            let fresh = NativeWorkspacePreferences(knownPanelIDsByView: ["fixture": Set(workspaceDescriptors.map(\.id))],
                panelSizeBoundsByView: ["fixture": bounds], defaults: fixture.defaults)
            XCTAssertNil(fresh.restorationError)
            XCTAssertEqual(fresh.collection, expected)
            XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), bytes)
        }
        try requireOwner(); try assertStored(originalCollection)
        let handles = descendants(panel).filter { $0.accessibilityIdentifier() == "workspace-move-alpha" }
        let buttons = descendants(panel).compactMap { $0 as? NSButton }
            .filter { $0.accessibilityIdentifier() == "workspace-hide-alpha" }
        guard handles.count == 1, buttons.count == 1 else {
            throw WorkspaceCanvasFixtureFailure("The exact native move/Hide controls were not unique.")
        }
        let move = try XCTUnwrap(handles.first), hide = try XCTUnwrap(buttons.first)
        guard !panel.isHiddenOrHasHiddenAncestor, !move.isHiddenOrHasHiddenAncestor,
              move.window === fixture.window, hide.window === fixture.window, hide.target === panel,
              hide.isEnabled, !hide.isHiddenOrHasHiddenAncestor,
              move.accessibilityPerformPress(), fixture.window.firstResponder === move else {
            throw WorkspaceCanvasFixtureFailure("The actual visible move handle did not own focus before Hide.")
        }
        report["stage"] = "focused-before-actual-hide"; report["first_responder_is_move_before_hide"] = true
        try requireOwner()
        hide.performClick(nil)
        var expectedHidden = originalCollection
        let layoutIndex = try XCTUnwrap(expectedHidden.layouts.firstIndex { $0.id == fixture.layoutA.id })
        let panelIndex = try XCTUnwrap(expectedHidden.layouts[layoutIndex].panels.firstIndex { $0.id == "alpha" })
        expectedHidden.layouts[layoutIndex].panels[panelIndex].isVisible = false
        try await waitUntil("The actual Hide did not reach the retained native panel.",
                            timeout: min(3, max(0, deadline - ProcessInfo.processInfo.systemUptime))) {
            fixture.hosting.layoutSubtreeIfNeeded()
            return panel.isHiddenOrHasHiddenAncestor && !panel.isManipulating
        }
        try requireOwner(); try assertStored(expectedHidden)
        XCTAssertEqual(panel.frame, originalFrame)
        let focusedView = fixture.window.firstResponder as? NSView
        let hiddenOwnsFocus = focusedView.map { $0 === panel || $0.isDescendant(of: panel) } ?? false
        report["stage"] = "hidden-native-apply"; report["hidden_panel_owns_first_responder"] = hiddenOwnsFocus
        report["first_responder_is_move_after_hide"] = fixture.window.firstResponder === move
        report["frame_before_hidden_arrow"] = NSStringFromRect(panel.frame)
        if hiddenOwnsFocus {
            try requireOwner()
            fixture.window.sendEvent(try key(124, flags: [], window: fixture.window))
            report["hidden_arrow_sent"] = true
            report["frame_after_hidden_arrow"] = NSStringFromRect(panel.frame)
            try requireOwner(); try assertStored(expectedHidden)
            XCTAssertEqual(panel.frame, originalFrame, "An owned-window arrow must not move a hidden panel.")
        }
        XCTAssertFalse(hiddenOwnsFocus, "Actual Hide must release keyboard focus from its hidden panel.")
        report["stage"] = "re-show"
        try fixture.preferences.setShown(true, for: "alpha", in: "fixture")
        try await waitUntil("Re-show did not restore the same native panel at its stored frame.",
                            timeout: min(3, max(0, deadline - ProcessInfo.processInfo.systemUptime))) {
            fixture.hosting.layoutSubtreeIfNeeded()
            return !panel.isHiddenOrHasHiddenAncestor && panel.frame == originalFrame
        }
        try requireOwner(); try assertStored(originalCollection)
        XCTAssertTrue(try gestureHandle("workspace-move-alpha", in: panel) === move)
        guard move.accessibilityPerformPress(), fixture.window.firstResponder === move else {
            throw WorkspaceCanvasFixtureFailure("The same shown native handle could not regain keyboard focus.")
        }
        var expectedMoved = originalCollection
        expectedMoved.layouts[layoutIndex].panels[panelIndex].frame.x += 10
        let movedFrame = expectedMoved.layouts[layoutIndex].panels[panelIndex].frame.nativeRect
        try requireOwner()
        fixture.window.sendEvent(try key(124, flags: [], window: fixture.window))
        try await waitUntil("The shown focused handle did not persist its actual owned-window arrow movement.",
                            timeout: min(3, max(0, deadline - ProcessInfo.processInfo.systemUptime))) {
            panel.frame == movedFrame && fixture.preferences.collection == expectedMoved
        }
        try requireOwner(); try assertStored(expectedMoved)
        report["stage"] = "shown-keyboard-completed"; report["completed"] = true
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

    func testSameLayoutHideAfterApplyRejectsPendingMoveAndResizeMouseUp() async throws {
        try await requireSameLayoutHideGestureProtection(applyBeforeMouseUp: true)
    }

    func testSameLayoutHideBeforeApplyRejectsPendingMoveAndResizeMouseUp() async throws {
        try await requireSameLayoutHideGestureProtection(applyBeforeMouseUp: false)
    }

    private func requireSameLayoutHideGestureProtection(applyBeforeMouseUp: Bool) async throws {
        continueAfterFailure = true
        for resizing in [false, true] {
            let fixture = try await mountScope()
            let document = try await mountedDocument(fixture)
            let panel = try XCTUnwrap(document.panelHosts["alpha"])
            defer { panel.cancelGesture() }
            let hosting = panel.hostingView
            let handle = try gestureHandle("workspace-\(resizing ? "resize" : "move")-alpha", in: panel)
            let original = panel.frame
            let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: document)
            let end = NSPoint(x: start.x + 50, y: start.y + 30)
            var report: [String: Any] = [
                "classification": "Owned native callback reachability reproducer; no desktop or hidden event-delivery claim",
                "apply_before_mouse_up": applyBeforeMouseUp, "resizing": resizing,
                "original_frame": NSStringFromRect(original), "stage": "before-down",
            ]
            defer {
                nativeDraftRetainMeasurement(report, name: "workspace-hide-active-gesture-"
                    + (applyBeforeMouseUp ? "after-apply-" : "before-apply-") + (resizing ? "resize" : "move"))
            }
            guard fixture.window.isVisible, fixture.window.isKeyWindow,
                  fixture.window.contentView === fixture.hosting,
                  fixture.hosting.window === fixture.window, document.window === fixture.window,
                  panel.window === fixture.window, handle.window === fixture.window,
                  !handle.isHiddenOrHasHiddenAncestor else {
                throw WorkspaceCanvasFixtureFailure("The pending gesture escaped its exact visible owned fixture.")
            }
            handle.mouseDown(with: try pointer(.leftMouseDown, at: start, in: document))
            let afterDown = fixture.preferences.collection
            let bytesAfterDown = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            handle.mouseDragged(with: try pointer(.leftMouseDragged, at: end, in: document))
            XCTAssertTrue(panel.isManipulating)
            XCTAssertNotEqual(panel.frame, original)
            XCTAssertEqual(fixture.preferences.collection, afterDown)
            XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), bytesAfterDown)
            report["stage"] = "transient-drag"
            if applyBeforeMouseUp {
                try nativeDraftHide(panel)
                report["hide_route"] = "Actual native NSButton.performClick"
            } else {
                try fixture.preferences.setShown(false, for: "alpha", in: "fixture")
                report["hide_route"] = "Production preferences boundary before native view apply"
            }
            let afterHide = fixture.preferences.collection
            let bytesAfterHide = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            XCTAssertEqual(fixture.preferences.activeLayout(for: "fixture")?.id, fixture.layoutA.id)
            XCTAssertEqual(fixture.preferences.activeLayout(for: "fixture")?.panels.first { $0.id == "alpha" }?.isVisible, false)
            XCTAssertEqual(fixture.preferences.activeLayout(for: "fixture")?.panels.first { $0.id == "alpha" }?.frame.nativeRect, original)
            if applyBeforeMouseUp {
                try await waitUntil("The same-layout Hide did not reach its existing native panel.") { panel.isHidden }
                report["manipulating_after_hide_apply"] = panel.isManipulating
                report["frame_after_hide_apply"] = NSStringFromRect(panel.frame)
                XCTAssertFalse(panel.isManipulating, "Hiding the active panel must cancel its transient gesture.")
                XCTAssertEqual(panel.frame, original)
            } else {
                // No suspension or root replacement between the production Hide write and late callback.
                report["manipulating_before_apply"] = panel.isManipulating
                report["hidden_before_apply"] = panel.isHidden
                guard panel.isManipulating, !panel.isHidden else {
                    throw WorkspaceCanvasFixtureFailure("The fixture did not reach the same-layout hide-before-apply window.")
                }
            }
            report["stage"] = "before-late-up"
            handle.mouseUp(with: try pointer(.leftMouseUp, at: end, in: document))
            report["collection_unchanged_after_late_up"] = fixture.preferences.collection == afterHide
            report["bytes_unchanged_after_late_up"] = fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == bytesAfterHide
            report["frame_after_late_up"] = NSStringFromRect(panel.frame)
            report["manipulating_after_late_up"] = panel.isManipulating
            XCTAssertEqual(fixture.preferences.collection, afterHide, "A late mouse-up must not persist geometry after Hide.")
            XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), bytesAfterHide)
            try await waitUntil("The hidden panel did not settle after its late callback.") { panel.isHidden && !panel.isManipulating }
            XCTAssertTrue(document.panelHosts["alpha"] === panel)
            XCTAssertTrue(panel.hostingView === hosting)
            try fixture.preferences.setShown(true, for: "alpha", in: "fixture")
            let resumed = try XCTUnwrap(fixture.preferences.activeLayout(for: "fixture")?.panels.first { $0.id == "alpha" }?.frame)
            try await waitUntil("Show did not resume the same native host at its current persisted geometry.") {
                !panel.isHidden && panel.frame == resumed.nativeRect
            }
            XCTAssertTrue(document.panelHosts["alpha"] === panel)
            XCTAssertTrue(panel.hostingView === hosting)
            let freshHandle = try gestureHandle("workspace-\(resizing ? "resize" : "move")-alpha", in: panel)
            let freshStart = freshHandle.convert(NSPoint(x: freshHandle.bounds.midX, y: freshHandle.bounds.midY), to: document)
            try drag(freshHandle, in: document, from: freshStart,
                     to: NSPoint(x: freshStart.x + 20, y: freshStart.y + 10))
            let expectedFresh = resizing
                ? NativeWorkspaceFrame(x: resumed.x, y: resumed.y, width: resumed.width + 20, height: resumed.height + 10)
                : NativeWorkspaceFrame(x: resumed.x + 20, y: resumed.y + 10, width: resumed.width, height: resumed.height)
            XCTAssertEqual(fixture.preferences.activeLayout(for: "fixture")?.panels.first { $0.id == "alpha" }?.frame, expectedFresh)
            XCTAssertEqual(panel.frame, expectedFresh.nativeRect)
            XCTAssertFalse(panel.isManipulating)
            report["same_panel_and_content_host_after_show"] = document.panelHosts["alpha"] === panel && panel.hostingView === hosting
            report["stage"] = "fresh-completed-gesture"
            await fixture.close(); scopeFixture = nil
        }
    }

    func testMovePointerArrowAndEscapePreserveSavedGeometryAndHosts() async throws {
        try await requireMixedPointerKeyboardCancellation(resizing: false)
    }

    func testResizePointerArrowAndEscapePreserveSavedGeometryAndHosts() async throws {
        try await requireMixedPointerKeyboardCancellation(resizing: true)
    }

    private func requireMixedPointerKeyboardCancellation(resizing: Bool) async throws {
        continueAfterFailure = true
        let fixture = try await mountScope()
        let document = try await mountedDocument(fixture)
        let panel = try XCTUnwrap(document.panelHosts["alpha"])
        defer { panel.cancelGesture() }
        let hosting = panel.hostingView
        let handle = try gestureHandle("workspace-\(resizing ? "resize" : "move")-alpha", in: panel)
        let original = panel.frame
        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: document)
        let end = NSPoint(x: start.x + 50, y: start.y + 30)
        var report: [String: Any] = [
            "classification": "Owned native pointer callbacks and own-window key dispatch; no desktop or app-queued pointer delivery claim",
            "resizing": resizing, "original_frame": NSStringFromRect(original), "stage": "before-down",
            "saved_baseline": "After actual down's explicit bringToFront, before transient geometry",
        ]
        defer { nativeDraftRetainMeasurement(report, name: "workspace-mixed-pointer-keyboard-" + (resizing ? "resize" : "move")) }
        func requireOwner() throws {
            guard fixture.window.isVisible, fixture.window.isKeyWindow,
                  fixture.window.contentView === fixture.hosting, fixture.hosting.window === fixture.window,
                  document.window === fixture.window, panel.window === fixture.window,
                  handle.window === fixture.window, !handle.isHiddenOrHasHiddenAncestor,
                  document.panelHosts["alpha"] === panel, panel.hostingView === hosting,
                  fixture.preferences.activeLayout(for: "fixture")?.id == fixture.layoutA.id else {
                throw WorkspaceCanvasFixtureFailure("The mixed gesture escaped its exact visible fixture and retained hosts.")
            }
        }
        func sendOwnedKey(_ code: UInt16) throws {
            try requireOwner()
            guard fixture.window.makeFirstResponder(handle), fixture.window.firstResponder === handle else {
                throw WorkspaceCanvasFixtureFailure("The owned gesture handle did not retain native keyboard focus.")
            }
            let event = try key(code, flags: [], window: fixture.window)
            guard event.window === fixture.window, event.windowNumber == fixture.window.windowNumber else {
                throw WorkspaceCanvasFixtureFailure("The mixed key event escaped its exact owned window.")
            }
            fixture.window.sendEvent(event)
        }
        try requireOwner()
        handle.mouseDown(with: try pointer(.leftMouseDown, at: start, in: document))
        let saved = fixture.preferences.collection
        let savedBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
        handle.mouseDragged(with: try pointer(.leftMouseDragged, at: end, in: document))
        guard panel.isManipulating, panel.frame != original else {
            throw WorkspaceCanvasFixtureFailure("The mixed fixture did not reach a pending native pointer edit.")
        }
        XCTAssertEqual(fixture.preferences.collection, saved)
        XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), savedBytes)
        let dragged = panel.frame
        report["stage"] = "before-arrow"
        try sendOwnedKey(124)
        report["frame_after_arrow"] = NSStringFromRect(panel.frame)
        report["manipulating_after_arrow"] = panel.isManipulating
        report["collection_unchanged_after_arrow"] = fixture.preferences.collection == saved
        report["bytes_unchanged_after_arrow"] = fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == savedBytes
        guard panel.isManipulating, panel.frame != dragged else {
            throw WorkspaceCanvasFixtureFailure("The own-window arrow did not reach the still-pending native gesture.")
        }
        XCTAssertEqual(fixture.preferences.collection, saved, "A keyboard nudge inside a pending pointer gesture must remain transient.")
        XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), savedBytes)
        report["stage"] = "before-escape"
        try sendOwnedKey(53)
        handle.mouseUp(with: try pointer(.leftMouseUp, at: end, in: document))
        report["frame_after_escape_and_late_up"] = NSStringFromRect(panel.frame)
        report["manipulating_after_escape_and_late_up"] = panel.isManipulating
        report["collection_unchanged_after_escape"] = fixture.preferences.collection == saved
        report["bytes_unchanged_after_escape"] = fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == savedBytes
        XCTAssertEqual(panel.frame, original)
        XCTAssertFalse(panel.isManipulating)
        XCTAssertEqual(fixture.preferences.collection, saved, "Escape must preserve the full saved state after mixed input.")
        XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), savedBytes)
        XCTAssertTrue(document.panelHosts["alpha"] === panel)
        XCTAssertTrue(panel.hostingView === hosting)
        let beforeFreshKey = panel.frame
        try sendOwnedKey(124)
        let keyed = resizing
            ? NativeWorkspaceFrame(x: beforeFreshKey.minX, y: beforeFreshKey.minY, width: beforeFreshKey.width + 10, height: beforeFreshKey.height)
            : NativeWorkspaceFrame(x: beforeFreshKey.minX + 10, y: beforeFreshKey.minY, width: beforeFreshKey.width, height: beforeFreshKey.height)
        XCTAssertEqual(fixture.preferences.activeLayout(for: "fixture")?.panels.first { $0.id == "alpha" }?.frame, keyed)
        XCTAssertEqual(panel.frame, keyed.nativeRect)
        let freshStart = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: document)
        try drag(handle, in: document, from: freshStart, to: NSPoint(x: freshStart.x + 20, y: freshStart.y + 10))
        let pointed = resizing
            ? NativeWorkspaceFrame(x: keyed.x, y: keyed.y, width: keyed.width + 20, height: keyed.height + 10)
            : NativeWorkspaceFrame(x: keyed.x + 20, y: keyed.y + 10, width: keyed.width, height: keyed.height)
        XCTAssertEqual(fixture.preferences.activeLayout(for: "fixture")?.panels.first { $0.id == "alpha" }?.frame, pointed)
        XCTAssertEqual(panel.frame, pointed.nativeRect)
        XCTAssertFalse(panel.isManipulating)
        XCTAssertTrue(document.panelHosts["alpha"] === panel)
        XCTAssertTrue(panel.hostingView === hosting)
        report["same_hosts_after_fresh_keyboard_and_pointer"] = document.panelHosts["alpha"] === panel && panel.hostingView === hosting
        report["stage"] = "fresh-completed-inputs"
        await fixture.close(); scopeFixture = nil
    }

    func testMoveCompletedPointerAndRepeatedArrowsRetainBothDisplacements() async throws {
        try await requireCompletedMixedPointerKeyboardGesture(resizing: false)
    }

    func testResizeCompletedPointerAndRepeatedArrowsRetainBothDisplacements() async throws {
        try await requireCompletedMixedPointerKeyboardGesture(resizing: true)
    }

    private func requireCompletedMixedPointerKeyboardGesture(resizing: Bool) async throws {
        continueAfterFailure = true
        let fixture = try await mountScope()
        let document = try await mountedDocument(fixture)
        let panel = try XCTUnwrap(document.panelHosts["alpha"])
        defer { panel.cancelGesture() }
        let hosting = panel.hostingView
        let handle = try gestureHandle("workspace-\(resizing ? "resize" : "move")-alpha", in: panel)
        let original = panel.frame
        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: document)
        let first = NSPoint(x: start.x + 50, y: start.y + 30)
        let last = NSPoint(x: start.x + 70, y: start.y + 40)
        func frame(dx: CGFloat, dy: CGFloat) -> NativeWorkspaceFrame {
            resizing
                ? .init(x: original.minX, y: original.minY, width: original.width + dx, height: original.height + dy)
                : .init(x: original.minX + dx, y: original.minY + dy, width: original.width, height: original.height)
        }
        let completed = frame(dx: 90, dy: 50)
        guard completed.x >= 0, completed.y >= 0,
              completed.x + completed.width <= Double(panel.canvasSize.width),
              completed.y + completed.height <= Double(panel.canvasSize.height),
              completed.width >= Double(panel.descriptor.minimumSize.width),
              completed.height >= Double(panel.descriptor.minimumSize.height),
              completed.width <= Double(panel.descriptor.maximumSize.width),
              completed.height <= Double(panel.descriptor.maximumSize.height) else {
            throw WorkspaceCanvasFixtureFailure("The completed mixed fixture lacks unclamped room for both displacements.")
        }
        var report: [String: Any] = [
            "classification": "Owned native pointer callbacks and own-window key dispatch; no desktop or app-queued pointer claim",
            "resizing": resizing, "original_frame": NSStringFromRect(original), "stage": "before-down",
            "pointer_total_delta": [70, 40], "arrow_total_delta": [20, 10],
            "expected_completed_frame": NSStringFromRect(completed.nativeRect), "pending_arrow_dispatch_limit": 3, "total_key_dispatch_limit": 4,
            "saved_baseline": "After actual down's explicit bringToFront, before transient geometry",
        ]
        defer { nativeDraftRetainMeasurement(report, name: "workspace-completed-mixed-" + (resizing ? "resize" : "move")) }
        func requireOwner() throws {
            guard fixture.window.isVisible, fixture.window.isKeyWindow,
                  fixture.window.contentView === fixture.hosting, fixture.hosting.window === fixture.window,
                  document.window === fixture.window, panel.window === fixture.window,
                  handle.window === fixture.window, !handle.isHiddenOrHasHiddenAncestor,
                  document.panelHosts["alpha"] === panel, panel.hostingView === hosting,
                  fixture.preferences.activeLayout(for: "fixture")?.id == fixture.layoutA.id else {
                throw WorkspaceCanvasFixtureFailure("The completed mixed gesture escaped its exact visible fixture and retained hosts.")
            }
        }
        func sendOwnedKey(_ code: UInt16) throws {
            try requireOwner()
            guard fixture.window.makeFirstResponder(handle), fixture.window.firstResponder === handle else {
                throw WorkspaceCanvasFixtureFailure("The completed mixed handle did not retain native keyboard focus.")
            }
            let event = try key(code, flags: [], window: fixture.window)
            guard event.window === fixture.window, event.windowNumber == fixture.window.windowNumber else {
                throw WorkspaceCanvasFixtureFailure("The completed mixed key escaped its exact owned window.")
            }
            fixture.window.sendEvent(event)
        }
        try requireOwner()
        handle.mouseDown(with: try pointer(.leftMouseDown, at: start, in: document))
        let saved = fixture.preferences.collection
        let savedBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
        func expectedCollection(_ value: NativeWorkspaceFrame) throws -> NativeWorkspaceCollection {
            var expected = saved
            let layoutIndex = try XCTUnwrap(expected.layouts.firstIndex { $0.id == fixture.layoutA.id && $0.viewID == "fixture" })
            let panelIndex = try XCTUnwrap(expected.layouts[layoutIndex].panels.firstIndex { $0.id == "alpha" })
            expected.layouts[layoutIndex].panels[panelIndex].frame = value
            return expected
        }
        func assertSaved(_ value: NativeWorkspaceFrame) throws {
            let expected = try expectedCollection(value)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(fixture.preferences.collection, expected)
            XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), try encoder.encode(expected))
        }
        handle.mouseDragged(with: try pointer(.leftMouseDragged, at: first, in: document))
        guard panel.isManipulating, panel.frame != original else {
            throw WorkspaceCanvasFixtureFailure("The completed mixed fixture did not reach a pending pointer gesture.")
        }
        XCTAssertEqual(panel.frame, frame(dx: 50, dy: 30).nativeRect)
        for (index, code) in ([UInt16(124), 124, 125]).enumerated() {
            let before = panel.frame
            try sendOwnedKey(code)
            guard panel.isManipulating, panel.frame != before else {
                throw WorkspaceCanvasFixtureFailure("A repeated arrow did not reach the pending completed mixed gesture.")
            }
            XCTAssertEqual(panel.frame, frame(dx: index == 0 ? 60 : 70, dy: index == 2 ? 40 : 30).nativeRect)
        }
        report["stage"] = "after-repeated-arrows"
        report["frame_after_arrows"] = NSStringFromRect(panel.frame)
        report["collection_unchanged_after_arrows"] = fixture.preferences.collection == saved
        report["bytes_unchanged_after_arrows"] = fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == savedBytes
        XCTAssertEqual(fixture.preferences.collection, saved, "Mixed arrows remain transient until mouse-up.")
        XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), savedBytes)
        try requireOwner()
        handle.mouseDragged(with: try pointer(.leftMouseDragged, at: last, in: document))
        XCTAssertTrue(panel.isManipulating)
        XCTAssertEqual(panel.frame, completed.nativeRect, "A later pointer event must retain accumulated arrow displacement.")
        XCTAssertEqual(fixture.preferences.collection, saved)
        XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), savedBytes)
        report["frame_after_second_drag"] = NSStringFromRect(panel.frame)
        handle.mouseUp(with: try pointer(.leftMouseUp, at: last, in: document))
        XCTAssertFalse(panel.isManipulating)
        XCTAssertEqual(panel.frame, completed.nativeRect, "Mouse-up must preserve pointer and keyboard displacement together.")
        try assertSaved(completed)
        report["stage"] = "completed"
        report["frame_after_mouse_up"] = NSStringFromRect(panel.frame)
        report["completed_collection_exact"] = fixture.preferences.collection == (try expectedCollection(completed))
        try sendOwnedKey(123)
        let freshKeyed = frame(dx: 80, dy: 50)
        XCTAssertEqual(panel.frame, freshKeyed.nativeRect)
        try assertSaved(freshKeyed)
        let freshStart = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: document)
        try drag(handle, in: document, from: freshStart, to: NSPoint(x: freshStart.x + 20, y: freshStart.y + 10))
        let freshPointed = frame(dx: 100, dy: 60)
        XCTAssertEqual(panel.frame, freshPointed.nativeRect)
        try assertSaved(freshPointed)
        XCTAssertFalse(panel.isManipulating)
        XCTAssertTrue(document.panelHosts["alpha"] === panel)
        XCTAssertTrue(panel.hostingView === hosting)
        report["stage"] = "fresh-completed-inputs"
        report["same_hosts"] = document.panelHosts["alpha"] === panel && panel.hostingView === hosting
        await fixture.close(); scopeFixture = nil
    }

    func testPendingMoveOptionResizeSurvivesPointerCompletionAndEscape() async throws {
        try await requireMixedBoundsAndOptionParity(resizing: false, optionMove: true)
    }

    func testPendingMoveClampedArrowUsesActualFrameForLaterPointerCompletion() async throws {
        try await requireMixedBoundsAndOptionParity(resizing: false, optionMove: false)
    }

    func testPendingResizeClampedArrowUsesActualFrameForLaterPointerCompletion() async throws {
        try await requireMixedBoundsAndOptionParity(resizing: true, optionMove: false)
    }

    private func requireMixedBoundsAndOptionParity(resizing: Bool, optionMove: Bool) async throws {
        continueAfterFailure = true
        let fixture = try await mountScope()
        let document = try await mountedDocument(fixture)
        let panel = try XCTUnwrap(document.panelHosts["alpha"])
        defer { panel.cancelGesture() }
        let hosting = panel.hostingView
        let handle = try gestureHandle("workspace-\(resizing ? "resize" : "move")-alpha", in: panel)
        let original = panel.frame
        guard !(resizing && optionMove), original == NSRect(x: 100, y: 120, width: 400, height: 240),
              panel.canvasSize == NSSize(width: 1_200, height: 800),
              panel.descriptor.maximumSize == CGSize(width: 960, height: 640) else {
            throw WorkspaceCanvasFixtureFailure("The mixed bounds fixture differs from its exact recorded canvas/panel geometry.")
        }
        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: document)
        let first = optionMove ? NSPoint(x: start.x + 50, y: start.y + 30)
            : NSPoint(x: start.x + (resizing ? 560 : 700), y: start.y + (resizing ? 400 : 30))
        let last = optionMove ? NSPoint(x: start.x + 70, y: start.y + 40)
            : NSPoint(x: first.x - 20, y: first.y + (resizing ? -10 : 10))
        let firstFrame = optionMove ? NativeWorkspaceFrame(x: 150, y: 150, width: 400, height: 240)
            : resizing ? .init(x: 100, y: 120, width: 960, height: 640) : .init(x: 800, y: 150, width: 400, height: 240)
        let completed = optionMove ? NativeWorkspaceFrame(x: 170, y: 160, width: 410, height: 250)
            : resizing ? .init(x: 100, y: 120, width: 940, height: 630) : .init(x: 780, y: 160, width: 400, height: 240)
        var report: [String: Any] = [
            "classification": "Owned native pointer callbacks and own-window key dispatch; no desktop or queued-pointer claim",
            "resizing": resizing, "option_move": optionMove, "stage": "before-down",
            "original_frame": NSStringFromRect(original), "expected_completed_frame": NSStringFromRect(completed.nativeRect),
            "key_dispatch_limit": optionMove ? 4 : 1, "pointer_callback_limit": optionMove ? 8 : 4,
            "saved_baseline": "After each down's explicit bringToFront, before transient geometry",
        ]
        defer { nativeDraftRetainMeasurement(report, name: "workspace-mixed-" + (optionMove ? "option-move" : resizing ? "clamped-resize" : "clamped-move")) }
        func requireOwner() throws {
            guard fixture.window.isVisible, fixture.window.isKeyWindow,
                  fixture.window.contentView === fixture.hosting, fixture.hosting.window === fixture.window,
                  document.window === fixture.window, panel.window === fixture.window,
                  handle.window === fixture.window, !handle.isHiddenOrHasHiddenAncestor,
                  document.panelHosts["alpha"] === panel, panel.hostingView === hosting,
                  fixture.preferences.activeLayout(for: "fixture")?.id == fixture.layoutA.id else {
                throw WorkspaceCanvasFixtureFailure("The mixed bounds/Option flow escaped its exact visible fixture and hosts.")
            }
        }
        func sendOwnedKey(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
            try requireOwner()
            guard fixture.window.makeFirstResponder(handle), fixture.window.firstResponder === handle else {
                throw WorkspaceCanvasFixtureFailure("The mixed bounds/Option handle did not retain native keyboard focus.")
            }
            let event = try key(code, flags: flags, window: fixture.window)
            guard event.window === fixture.window, event.windowNumber == fixture.window.windowNumber,
                  event.modifierFlags.contains(.option) == flags.contains(.option) else {
                throw WorkspaceCanvasFixtureFailure("The mixed bounds/Option key escaped its exact window or modifier state.")
            }
            fixture.window.sendEvent(event)
        }
        try requireOwner()
        handle.mouseDown(with: try pointer(.leftMouseDown, at: start, in: document))
        let saved = fixture.preferences.collection
        let savedBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
        func requirePendingStorage() {
            XCTAssertTrue(panel.isManipulating)
            XCTAssertEqual(fixture.preferences.collection, saved)
            XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), savedBytes)
        }
        handle.mouseDragged(with: try pointer(.leftMouseDragged, at: first, in: document))
        guard panel.isManipulating, panel.frame != original else {
            throw WorkspaceCanvasFixtureFailure("The mixed bounds/Option fixture did not reach a pending pointer edit.")
        }
        XCTAssertEqual(panel.frame, firstFrame.nativeRect)
        requirePendingStorage()
        report["stage"] = "before-arrow"
        try sendOwnedKey(124, flags: optionMove ? [.option] : [])
        if optionMove {
            XCTAssertEqual(panel.frame, NSRect(x: 150, y: 150, width: 410, height: 240))
            requirePendingStorage()
            try sendOwnedKey(125, flags: [.option])
            XCTAssertEqual(panel.frame, NSRect(x: 150, y: 150, width: 410, height: 250))
        } else {
            XCTAssertEqual(panel.frame, firstFrame.nativeRect, "A right arrow at the bound has zero actual displacement.")
        }
        requirePendingStorage()
        report["frame_after_arrows"] = NSStringFromRect(panel.frame)
        report["collection_unchanged_after_arrows"] = fixture.preferences.collection == saved
        report["bytes_unchanged_after_arrows"] = fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == savedBytes
        try requireOwner()
        handle.mouseDragged(with: try pointer(.leftMouseDragged, at: last, in: document))
        XCTAssertEqual(panel.frame, completed.nativeRect, "Later pointer input must retain Option geometry and actual bounded arrow displacement.")
        requirePendingStorage()
        report["frame_after_later_pointer"] = NSStringFromRect(panel.frame)
        handle.mouseUp(with: try pointer(.leftMouseUp, at: last, in: document))
        XCTAssertFalse(panel.isManipulating)
        XCTAssertEqual(panel.frame, completed.nativeRect)
        var expected = saved
        let layoutIndex = try XCTUnwrap(expected.layouts.firstIndex { $0.id == fixture.layoutA.id && $0.viewID == "fixture" })
        let panelIndex = try XCTUnwrap(expected.layouts[layoutIndex].panels.firstIndex { $0.id == "alpha" })
        expected.layouts[layoutIndex].panels[panelIndex].frame = completed
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(fixture.preferences.collection, expected)
        XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), try encoder.encode(expected))
        report["stage"] = "completed"
        report["frame_after_mouse_up"] = NSStringFromRect(panel.frame)
        report["completed_collection_exact"] = fixture.preferences.collection == expected
        if optionMove {
            let rollback = panel.frame
            let freshStart = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: document)
            let freshEnd = NSPoint(x: freshStart.x + 20, y: freshStart.y + 10)
            handle.mouseDown(with: try pointer(.leftMouseDown, at: freshStart, in: document))
            let cancelSaved = fixture.preferences.collection
            let cancelBytes = try XCTUnwrap(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey))
            handle.mouseDragged(with: try pointer(.leftMouseDragged, at: freshEnd, in: document))
            try sendOwnedKey(124, flags: [.option])
            XCTAssertTrue(panel.isManipulating)
            XCTAssertEqual(panel.frame, NSRect(x: rollback.minX + 20, y: rollback.minY + 10,
                                              width: rollback.width + 10, height: rollback.height))
            XCTAssertEqual(fixture.preferences.collection, cancelSaved)
            XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), cancelBytes)
            try sendOwnedKey(53)
            handle.mouseUp(with: try pointer(.leftMouseUp, at: freshEnd, in: document))
            XCTAssertFalse(panel.isManipulating)
            XCTAssertEqual(panel.frame, rollback, "Escape rolls back Option resizing inside a pointer move.")
            XCTAssertEqual(fixture.preferences.collection, cancelSaved)
            XCTAssertEqual(fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey), cancelBytes)
            report["stage"] = "option-escape-and-late-up"
            report["collection_unchanged_after_option_escape"] = fixture.preferences.collection == cancelSaved
            report["bytes_unchanged_after_option_escape"] = fixture.defaults.data(forKey: NativeWorkspacePreferences.storageKey) == cancelBytes
        }
        XCTAssertTrue(document.panelHosts["alpha"] === panel)
        XCTAssertTrue(panel.hostingView === hosting)
        report["same_hosts"] = document.panelHosts["alpha"] === panel && panel.hostingView === hosting
        await fixture.close(); scopeFixture = nil
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
private final class WorkspaceSharedControlsMenuLifecycleObservation: NSObject {
    enum Stage: String {
        case firstCaptured = "first_menu_captured"
        case firstDispatchReturned = "first_native_dispatch_return"
        case firstCancelReturned = "first_optional_cancel_call_return"
        case firstResultAssigned = "first_result_assignment_return"
        case firstCaptureCleared = "first_capture_reference_clear_return"
        case secondActionBefore = "before_second_opener_action"
        case secondActionAfter = "second_opener_return_after_existing_guards"
        case firstExactEnd = "first_exact_end_notification_receipt"
        case cleanup = "flow_observer_removal_return"
    }
    private weak var window: NSWindow?
    private weak var hosting: NSView?
    private weak var firstMenu: NSMenu?
    private var firstMenuWasCaptured = false, stopped = false
    private var exactEndsFirstTwo = 0
    private var stages: [String: [String: Any]] = [:]
    init(window: NSWindow, hosting: NSView) {
        self.window = window; self.hosting = hosting
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(didEnd(_:)),
            name: NSMenu.didEndTrackingNotification, object: nil)
    }
    var evidence: [String: Any] {
        ["classification": "Weak exact first captured menu and later scalar stages only; no enclosing-loop unwind, release or cause claim",
         "first_write_stage_limit": 9, "exact_end_counter_limit": 2,
         "first_menu_was_captured": firstMenuWasCaptured, "exact_ends_first_two": exactEndsFirstTwo,
         "observer_removed": stopped, "stages": stages]
    }
    func noteCapturedMenu(_ menu: NSMenu, attemptOrdinal: Int) {
        guard !stopped, attemptOrdinal == 1, !firstMenuWasCaptured else { return }
        firstMenuWasCaptured = true; firstMenu = menu
        record(.firstCaptured)
    }
    func noteFirst(_ stage: Stage, attemptOrdinal: Int, resultPresent: Bool) {
        guard !stopped, attemptOrdinal == 1 else { return }
        record(stage, resultPresent: resultPresent)
    }
    func noteSecondAction(returned: Bool, attemptOrdinal: Int, captureDeadline: TimeInterval, actionDeadline: TimeInterval) {
        guard !stopped, attemptOrdinal == 2 else { return }
        record(returned ? .secondActionAfter : .secondActionBefore, nativeState: true,
            captureDeadline: captureDeadline, actionDeadline: actionDeadline)
    }
    @objc private func didEnd(_ notification: Notification) {
        guard !stopped, exactEndsFirstTwo < 2, let held = firstMenu,
              let actual = notification.object as? NSMenu, actual === held else { return }
        exactEndsFirstTwo += 1
        if exactEndsFirstTwo == 1 { record(.firstExactEnd) }
    }
    func stop() {
        guard !stopped else { return }
        NotificationCenter.default.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: nil)
        stopped = true
        record(.cleanup)
        firstMenu = nil
    }
    private func record(_ stage: Stage, resultPresent: Bool? = nil, nativeState: Bool = false,
                        captureDeadline: TimeInterval? = nil, actionDeadline: TimeInterval? = nil) {
        guard stages[stage.rawValue] == nil, stages.count < 9 else { return }
        let observed = ProcessInfo.processInfo.systemUptime
        var row: [String: Any] = ["snapshot_uptime": observed, "first_menu_was_captured": firstMenuWasCaptured,
            "weak_first_menu_present": firstMenu != nil, "exact_ends_first_two_at_stage": exactEndsFirstTwo,
            "result_present": resultPresent.map { $0 as Any } ?? NSNull()]
        if nativeState {
            let readDeadline = observed + 0.02, window = self.window, hosting = self.hosting
            row["classification"] = "Later native scalar snapshot only; mode is correlated state, not original guard evaluation or menu-loop cause"
            row["getter_group_limit"] = 7; row["read_budget_seconds"] = 0.02
            row["window_present"] = window != nil; row["hosting_present"] = hosting != nil
            row["capture_deadline"] = captureDeadline.map { $0 as Any } ?? NSNull()
            row["action_context_deadline"] = actionDeadline.map { $0 as Any } ?? NSNull()
            for key in ["run_loop_mode_utf8_prefix", "window_is_key", "window_is_main", "window_is_visible",
                        "window_content_is_host", "host_window_is_fixture", "host_has_no_hidden_ancestor"] { row[key] = NSNull() }
            var reads = 0
            func read(_ body: () -> Void) {
                guard ProcessInfo.processInfo.systemUptime < readDeadline else { return }
                reads += 1; body()
            }
            read { row["run_loop_mode_utf8_prefix"] = RunLoop.current.currentMode.map { String(decoding: $0.rawValue.utf8.prefix(128), as: UTF8.self) as Any } ?? NSNull() }
            if let window, let hosting {
                read { row["window_is_key"] = window.isKeyWindow }
                read { row["window_is_main"] = window.isMainWindow }
                read { row["window_is_visible"] = window.isVisible }
                read { row["window_content_is_host"] = window.contentView === hosting }
                read { row["host_window_is_fixture"] = hosting.window === window }
                read { row["host_has_no_hidden_ancestor"] = !hosting.isHiddenOrHasHiddenAncestor }
            }
            let finished = ProcessInfo.processInfo.systemUptime
            row["getter_groups_attempted"] = reads; row["snapshot_elapsed_seconds"] = finished - observed
            row["read_budget_expired"] = finished >= readDeadline
        }
        stages[stage.rawValue] = row
    }
}

@MainActor
private final class WorkspaceSavedNameMenuCapture: NSObject {
    private weak var window: NSWindow?; private weak var hosting: NSView?; private weak var preferences: NativeWorkspacePreferences?
    private let expected: NativeWorkspaceCollection, names: [String], ordinal: Int
    let deadline: TimeInterval; var armed = false
    private var menu: NSMenu?, roots = 0, ticks = 0, proven = false, querying = false
    private(set) var cancellationRequested = false, endedAt: TimeInterval?, result: Result<Void, Error>?
    private(set) var receipt: [String: Any] = ["native_dispatch_returned": false, "root_limit": 1, "item_limit": 64, "tick_limit": 160]
    init(window: NSWindow, hosting: NSView, preferences: NativeWorkspacePreferences, expected: NativeWorkspaceCollection,
         names: [String], ordinal: Int, deadline: TimeInterval) {
        self.window = window; self.hosting = hosting; self.preferences = preferences; self.expected = expected
        self.names = names; self.ordinal = ordinal; self.deadline = deadline; super.init()
    }
    @objc func didBegin(_ note: Notification) {
        guard armed, result == nil else { return }; roots += 1; receipt["roots"] = roots
        guard roots == 1, let actual = note.object as? NSMenu else { result = .failure(WorkspaceCanvasFixtureFailure("Collision opener did not produce one exact native menu root.")); return }; menu = actual
    }
    @objc func didEnd(_ note: Notification) {
        guard armed, endedAt == nil, let menu, let actual = note.object as? NSMenu, actual === menu else { return }
        endedAt = ProcessInfo.processInfo.systemUptime; receipt["exact_tracking_end_uptime"] = endedAt
    }
    @objc func fire(_ timer: Timer) {
        guard armed, result == nil else { timer.invalidate(); return }
        guard !querying else { return }; querying = true; defer { querying = false }
        ticks += 1; receipt["ticks"] = ticks
        do {
            guard ProcessInfo.processInfo.systemUptime < deadline, ticks <= 160, let window, let hosting, let preferences,
                  window.isVisible, window.contentView === hosting, hosting.window === window,
                  !hosting.isHiddenOrHasHiddenAncestor, preferences.collection == expected else {
                throw WorkspaceCanvasFixtureFailure("Collision menu lost its finite exact owner/collection.")
            }
            guard let menu else { return }; let items = menu.items, leaves = items.filter { !$0.isSeparatorItem }
            let required = ["Default"] + names.map { "Layout: " + $0 } + ["Save Layout As…", "Rename Layout…", "Delete Layout"]
            guard roots == 1, menu.numberOfItems <= 64, items.count == menu.numberOfItems,
                  items.count == required.count + 1, leaves.count == required.count,
                  items[names.count + 1].isSeparatorItem, items.allSatisfy({ $0.menu === menu && $0.title.utf8.count <= 4_096 }),
                  leaves.enumerated().allSatisfy({ index, item in
                      (1...names.count).contains(index) ? item.title == names[index - 1] || item.title == required[index] : item.title == required[index]
                  }) else { throw WorkspaceCanvasFixtureFailure("Collision menu did not prove source-compatible ordered saved items and literal commands.") }
            proven = true; receipt["source_compatible_ordered_items"] = true; receipt["actual_titles"] = leaves.map(\.title)
            guard leaves.map(\.title) == required, Set(required).count == required.count else {
                throw WorkspaceCanvasFixtureFailure("Saved layout labels must be distinct from commands and use the uniform Layout: prefix.")
            }
            guard ordinal >= 0, ordinal <= names.count, let index = items.firstIndex(where: { $0 === leaves[ordinal] }),
                  leaves[ordinal].title == required[ordinal], leaves[ordinal].isEnabled, !leaves[ordinal].isHidden,
                  leaves[ordinal].action != nil, leaves[ordinal].submenu == nil else { throw WorkspaceCanvasFixtureFailure("The exact distinguishable saved/default command is not enabled.") }
            let fresh = menu.items
            guard fresh.count == items.count, zip(fresh, items).allSatisfy({ $0.0 === $0.1 }),
                  menu.item(at: index) === leaves[ordinal], window.contentView === hosting, hosting.window === window,
                  window.isVisible, preferences.collection == expected, ProcessInfo.processInfo.systemUptime < deadline else {
                throw WorkspaceCanvasFixtureFailure("Collision menu item/owner changed before native dispatch.")
            }
            receipt["actual_command"] = leaves[ordinal].title; receipt["actual_item_index"] = index
            menu.performActionForItem(at: index); receipt["native_dispatch_returned"] = true
            cancel(); guard roots == 1 else { throw WorkspaceCanvasFixtureFailure("Collision menu changed roots during dispatch.") }
            result = .success(()); timer.invalidate()
        } catch {
            receipt["original_error"] = String(decoding: String(describing: error).utf8.prefix(1_024), as: UTF8.self)
            cancel(); result = .failure(error); timer.invalidate()
        }
    }
    private func cancel() {
        guard proven, !cancellationRequested, let menu else { return }; cancellationRequested = true
        receipt["dismissal_API"] = "NSMenu.cancelTrackingWithoutAnimation()"; menu.cancelTrackingWithoutAnimation()
        receipt["cancel_returned"] = true
    }
    func stop() {
        cancel(); armed = false
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: nil)
        receipt["tracking_observers_removed"] = true; menu = nil
    }
}

@MainActor
private final class WorkspaceSharedControlsMenuCapture: NSObject {
    private weak var window: NSWindow?
    private weak var hosting: NSView?
    private weak var preferences: NativeWorkspacePreferences?
    private let expectedCollection: NativeWorkspaceCollection
    private let command: String
    private let titles: [String]
    private let states: [String: NSControl.StateValue]
    let deadline: TimeInterval
    var armed = false
    private var roots = 0, ticks = 0
    private var querying = false, cancellationRequested = false
    private var menu: NSMenu?
    private var provenMenu = false
    private weak var lifecycleObservation: WorkspaceSharedControlsMenuLifecycleObservation?
    private var attemptOrdinal = 0
    private var observesExactTrackingEnd = false
    private(set) var exactTrackingEndedAt: TimeInterval?
    private(set) var result: Result<Void, Error>?
    private(set) var receipt: [String: Any] = ["classification": "One exact armed native opener and captured literal menu; no desktop or enclosing-loop unwind claim",
        "item_limit": 64, "tick_limit": 160, "native_dispatch_requested": false,
        "native_dispatch_returned": false, "cancel_tracking_requested": false]
    var isFinished: Bool { if case .some = result { return true }; return false }
    init(window: NSWindow, hosting: NSView, preferences: NativeWorkspacePreferences,
         expectedCollection: NativeWorkspaceCollection, command: String, titles: [String],
         states: [String: NSControl.StateValue], deadline: TimeInterval) {
        self.window = window; self.hosting = hosting; self.preferences = preferences
        self.expectedCollection = expectedCollection; self.command = command
        self.titles = titles; self.states = states; self.deadline = deadline
        super.init()
    }
    func observeLifecycle(_ observation: WorkspaceSharedControlsMenuLifecycleObservation, attemptOrdinal: Int) {
        lifecycleObservation = observation; self.attemptOrdinal = attemptOrdinal
    }
    func observeExactTrackingEnd() {
        guard !observesExactTrackingEnd else { return }
        observesExactTrackingEnd = true
        NotificationCenter.default.addObserver(self, selector: #selector(didEnd(_:)),
            name: NSMenu.didEndTrackingNotification, object: nil)
    }
    @objc func didEnd(_ notification: Notification) {
        guard armed, observesExactTrackingEnd, exactTrackingEndedAt == nil,
              let menu, let ended = notification.object as? NSMenu, ended === menu else { return }
        let observedAt = ProcessInfo.processInfo.systemUptime
        exactTrackingEndedAt = observedAt
        receipt["exact_tracking_end_uptime"] = observedAt
    }
    @objc func didBegin(_ notification: Notification) {
        guard armed, !isFinished else { return }
        roots += 1
        receipt["captured_roots"] = roots
        guard roots == 1, let captured = notification.object as? NSMenu else {
            result = .failure(WorkspaceCanvasFixtureFailure("The armed shared-control opener did not produce exactly one native menu root.")); return
        }
        menu = captured
        lifecycleObservation?.noteCapturedMenu(captured, attemptOrdinal: attemptOrdinal)
    }
    @objc func fire(_ timer: Timer) {
        guard armed, !isFinished else { timer.invalidate(); return }
        guard !querying else { return }
        querying = true
        defer { querying = false }
        ticks += 1
        receipt["ticks"] = ticks
        do {
            guard ProcessInfo.processInfo.systemUptime < deadline, ticks <= 160,
                  let window, let hosting, let preferences, window.isVisible,
                  window.contentView === hosting, hosting.window === window,
                  !hosting.isHiddenOrHasHiddenAncestor, preferences.collection == expectedCollection else {
                throw WorkspaceCanvasFixtureFailure("Shared native menu lost its finite exact owner or originating collection.")
            }
            guard let menu else { return }
            guard roots == 1, menu.numberOfItems > 0, menu.numberOfItems <= 64 else {
                throw WorkspaceCanvasFixtureFailure("Shared native menu root/items exceeded the bound.")
            }
            let items = menu.items, leaves = items.filter { !$0.isSeparatorItem }
            guard items.count == menu.numberOfItems, leaves.count == titles.count,
                  items.allSatisfy({ $0.menu === menu && $0.title.utf8.count <= 4_096 }),
                  Set(leaves.map(\.title)) == Set(titles), Set(titles).count == titles.count,
                  titles.allSatisfy({ title in leaves.filter { $0.title == title }.count == 1 }),
                  states.allSatisfy({ title, state in leaves.first { $0.title == title }?.state == state }),
                  let index = items.firstIndex(where: { $0.title == command }),
                  items[index].isEnabled, !items[index].isHidden, !items[index].isSeparatorItem,
                  items[index].submenu == nil, items[index].action != nil else {
                throw WorkspaceCanvasFixtureFailure("Shared native menu did not prove its exact literal items, toggle states and enabled requested command.")
            }
            provenMenu = true
            receipt["actual_command"] = command; receipt["actual_command_index"] = index
            receipt["exact_literal_items_and_toggle_states"] = true
            receipt["actual_items"] = leaves.map { ["title": $0.title, "state": $0.state.rawValue, "enabled": $0.isEnabled] as [String: Any] }
            let fresh = menu.items
            guard fresh.count == items.count, zip(fresh, items).allSatisfy({ $0.0 === $0.1 }),
                  menu.item(at: index) === items[index], items[index].menu === menu,
                  items[index].title == command, items[index].isEnabled,
                  !items[index].isHidden, items[index].submenu == nil, items[index].action != nil,
                  states.allSatisfy({ title, state in fresh.first { $0.title == title }?.state == state }),
                  window.contentView === hosting, hosting.window === window, window.isVisible,
                  preferences.collection == expectedCollection, ProcessInfo.processInfo.systemUptime < deadline else {
                throw WorkspaceCanvasFixtureFailure("Shared native command changed before its actual dispatch.")
            }
            receipt["native_dispatch_requested"] = true
            menu.performActionForItem(at: index)
            receipt["native_dispatch_returned"] = true
            lifecycleObservation?.noteFirst(.firstDispatchReturned, attemptOrdinal: attemptOrdinal, resultPresent: isFinished)
            cancelProvenTracking()
            if let callbackResult = result { try callbackResult.get() }
            guard roots == 1, !isFinished else {
                throw WorkspaceCanvasFixtureFailure("Shared native menu violated its one-root contract during dispatch or tracking cancellation.")
            }
            result = .success(()); timer.invalidate()
            lifecycleObservation?.noteFirst(.firstResultAssigned, attemptOrdinal: attemptOrdinal, resultPresent: isFinished)
        } catch {
            cancelProvenTracking()
            if case .none = result { result = .failure(error) }
            lifecycleObservation?.noteFirst(.firstResultAssigned, attemptOrdinal: attemptOrdinal, resultPresent: isFinished)
            if case .failure(let retainedFailure) = result {
                receipt["failure"] = String(String(describing: retainedFailure).prefix(1_024))
            }
            timer.invalidate()
        }
    }
    func stop() {
        armed = false
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        if observesExactTrackingEnd {
            NotificationCenter.default.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: nil)
            observesExactTrackingEnd = false; receipt["exact_tracking_end_observer_removed"] = true
        }
        cancelProvenTracking()
        menu = nil
        lifecycleObservation?.noteFirst(.firstCaptureCleared, attemptOrdinal: attemptOrdinal, resultPresent: isFinished)
    }
    private func cancelProvenTracking() {
        guard provenMenu, !cancellationRequested else { return }
        cancellationRequested = true; receipt["cancel_tracking_requested"] = true
        menu?.cancelTracking()
        lifecycleObservation?.noteFirst(.firstCancelReturned, attemptOrdinal: attemptOrdinal, resultPresent: isFinished)
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
private final class NativeWorkspaceDraftWeakBridgeReceipt {
    weak var object: AnyObject?
    let ordinal: Int
    let identifierPrefix: String?
    init(object: AnyObject, ordinal: Int, identifier: String?) {
        self.object = object; self.ordinal = ordinal
        identifierPrefix = identifier.map { String(decoding: $0.utf8.prefix(128), as: UTF8.self) }
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
        report["ancestor_scope"] = "Owned exported window and discovered AXChildren parent; additional read-only held-parent AXParent/window-control reference comparison, no native-owner inference"
        report["yield_request_count"] = 1; report["yield_requested_seconds"] = 0.02
        func windowControlReferences() -> [String: Any] {
            var measured: [String: Any] = [
                "classification": "Read-only exact exported reference comparison; no native owner inference or recovery",
                "shared_existing_diagnostic_deadline": true, "additional_attribute_copy_limit": 4,
                "held_parent_AXParent_copy_limit": 1, "root_window_control_reference_copy_limit": 3,
            ]
            func reference(_ source: AXUIElement, attribute: String) -> (AXUIElement?, [String: Any]) {
                var row: [String: Any] = ["attribute": attribute, "source_cf_type_id": CFGetTypeID(source)]
                func unknown(_ reason: String) -> (AXUIElement?, [String: Any]) {
                    row["reference_result"] = "unknown"; row["unknown_reason"] = reason; return (nil, row)
                }
                guard CFGetTypeID(source) == AXUIElementGetTypeID(), ProcessInfo.processInfo.systemUptime < deadline else {
                    return unknown("invalid-source-type-or-shared-deadline")
                }
                var sourcePID: pid_t = 0
                let sourceStatus = AXUIElementGetPid(source, &sourcePID)
                row["source_pid_status"] = sourceStatus.rawValue; row["source_pid"] = sourcePID
                guard sourceStatus == .success, sourcePID == ProcessInfo.processInfo.processIdentifier else {
                    return unknown("source-pid-not-verified-own-process")
                }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return unknown("shared-deadline") }
                let timeout = AXUIElementSetMessagingTimeout(source, Float(min(0.005, remaining / 2)))
                row["timeout_status"] = timeout.rawValue
                guard timeout == .success, ProcessInfo.processInfo.systemUptime < deadline else {
                    return unknown("timeout-status-or-shared-deadline")
                }
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(source, attribute as CFString, &value)
                row["copy_status"] = status.rawValue
                if let value { row["value_cf_type_id"] = CFGetTypeID(value) }
                guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID(),
                      ProcessInfo.processInfo.systemUptime < deadline else {
                    return unknown("copy-status-absent-value-type-or-shared-deadline")
                }
                let element = value as! AXUIElement
                var valuePID: pid_t = 0
                let valueStatus = AXUIElementGetPid(element, &valuePID)
                row["value_pid_status"] = valueStatus.rawValue; row["value_pid"] = valuePID
                guard valueStatus == .success, valuePID == ProcessInfo.processInfo.processIdentifier,
                      ProcessInfo.processInfo.systemUptime < deadline else {
                    return unknown("returned-pid-or-shared-deadline-not-verified")
                }
                row["reference_result"] = "observed-own-process-AX-reference"
                return (element, row)
            }
            let container: AXUIElement?
            if let parent {
                let observed = reference(parent, attribute: kAXParentAttribute)
                container = observed.0; measured["held_parent_container"] = observed.1
            } else {
                container = nil
                measured["held_parent_container"] = ["reference_result": "unknown", "unknown_reason": "missing-held-parent"]
            }
            var controls: [String: Any] = [:]
            for attribute in [kAXZoomButtonAttribute, kAXCloseButtonAttribute, kAXMinimizeButtonAttribute] {
                guard let container else {
                    controls[attribute] = ["reference_result": "unknown", "comparison_result": "unknown",
                        "unknown_reason": "held-parent-container-not-verified; root-reference-not-queried"]
                    continue
                }
                var observed = reference(root, attribute: attribute)
                if let control = observed.0, ProcessInfo.processInfo.systemUptime < deadline {
                    let equal = CFEqual(container, control)
                    observed.1["CFEqual_held_parent_container"] = equal
                    observed.1["comparison_result"] = equal ? "observed-reference-match" : "observed-reference-no-match"
                } else {
                    observed.1["comparison_result"] = "unknown"
                    observed.1["comparison_unknown_reason"] = "root-control-reference-or-shared-deadline-not-verified"
                }
                controls[attribute] = observed.1
            }
            measured["exact_lookup_root_window_control_references"] = controls
            return measured
        }
        func finish() -> [String: Any] {
            report["held_parent_window_control_reference_comparison"] = windowControlReferences()
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

    convenience init?(fixture: NativeWorkspaceDraftFixture, deadline: TimeInterval) throws {
        try self.init(window: fixture.window, hosting: fixture.hosting, deadline: deadline)
    }

    init?(window: NSWindow, hosting: NSView, deadline: TimeInterval) throws {
        let ownedTitle = window.title
        owner = window; self.hosting = hosting
        title = ownedTitle; self.deadline = deadline
        guard !ownedTitle.isEmpty, ownedTitle.utf8.count <= 256,
              window.contentView === hosting, hosting.window === window,
              NSApp.windows.filter({ $0.title == window.title }).count == 1 else {
            throw WorkspaceCanvasFixtureFailure("The semantic fixture does not own one exact uniquely titled NSWindow/NSHostingView.")
        }
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windows = try NativeWorkspaceDraftAXQuery.children(application, kAXWindowsAttribute, limit: 32, deadline: deadline)
        let matches = try windows.filter {
            try NativeWorkspaceDraftAXQuery.attribute($0, kAXTitleAttribute, deadline: deadline) as? String == window.title
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

    func pressWorkspaceMenu(_ element: AXUIElement, viewID: String, requestedIdentifier: String) throws {
        guard NativeWorkspaceCatalog.panelsByView[viewID] != nil,
              requestedIdentifier == "workspace-panels-menu-" + viewID
                || requestedIdentifier == "workspace-layout-menu-" + viewID else {
            throw WorkspaceCanvasFixtureFailure("The exported workspace menu is not an exact catalog-bound shared opener.")
        }
        try requireOwnedAncestor(element)
        let current = try snapshot(element)
        guard current.identifier == requestedIdentifier, current.enabled == true,
              current.role?.rawValue == kAXMenuButtonRole,
              try NativeWorkspaceDraftAXQuery.actions(element, deadline: deadline).contains(kAXPressAction) else {
            throw WorkspaceCanvasFixtureFailure("The exact exported workspace menu is not an enabled AXMenuButton advertising AXPress.")
        }
        try NativeWorkspaceDraftAXQuery.prepare(element, deadline: deadline)
        let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard status == .success, ProcessInfo.processInfo.systemUptime < deadline else {
            throw WorkspaceCanvasFixtureFailure("The exact exported workspace menu AXPress failed or exceeded its deadline: AXError \(status.rawValue).")
        }
    }

    func pressToolsMenu(_ element: AXUIElement, requestedIdentifier: String) throws {
        guard requestedIdentifier == "workspace-panels-menu-tools" || requestedIdentifier == "workspace-layout-menu-tools" else {
            throw WorkspaceCanvasFixtureFailure("The exported Tools menu request is not one of its two exact shared opener identifiers.")
        }
        try requireOwnedAncestor(element)
        let current = try snapshot(element)
        guard current.identifier == requestedIdentifier, current.enabled == true,
              current.role?.rawValue == kAXMenuButtonRole,
              try NativeWorkspaceDraftAXQuery.actions(element, deadline: deadline).contains(kAXPressAction) else {
            throw WorkspaceCanvasFixtureFailure("The exact exported Tools menu is not an enabled AXMenuButton advertising AXPress.")
        }
        try NativeWorkspaceDraftAXQuery.prepare(element, deadline: deadline)
        let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard status == .success, ProcessInfo.processInfo.systemUptime < deadline else {
            throw WorkspaceCanvasFixtureFailure("The exact exported Tools menu AXPress failed or exceeded its deadline: AXError \(status.rawValue).")
        }
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

    init(page: Page, repositoryUpdatesEnabled: Bool = false) throws {
        let suiteName = "forge.workspace.positive-draft.tests.\(UUID().uuidString)"
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent("forge-native-workspace-positive-\(UUID().uuidString)")
        let localDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let clientOwner = try NativeWorkspaceDraftClient(repositoryUpdatesEnabled: repositoryUpdatesEnabled)
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
    struct RepositoryCall: Sendable, Equatable {
        let projectID: String
        let generation: UInt64
        let location: String?
    }
    static let projectID = "11111111-1111-4111-8111-111111111111"
    static let projectRoot = "/tmp/native-workspace-fixture-project"
    private var snapshotValue: OperatorSnapshot
    private let projectTemplate: Data
    private let repositoryUpdatesEnabled: Bool
    private var repositoryCalls: [RepositoryCall] = []
    private let queueValue: OperatorInstructionQueue
    private var snapshots = 0
    private var repositoryWrites = 0
    private var otherMutations = 0
    init(repositoryUpdatesEnabled: Bool = false) throws {
        let project = """
        {"project_id":"11111111-1111-4111-8111-111111111111","display_name":"Native Draft Project","canonical_root":"/tmp/native-workspace-fixture-project","project_generation":4,"lifecycle_state":"active","bindings":[],"memory":{"state":"healthy","database_bytes":0,"record_count":0},"continuity":{"state":"ready","migration_state":"not_required"},"migration_warnings":[],"github_repository_url":null}
        """
        projectTemplate = Data(project.utf8)
        self.repositoryUpdatesEnabled = repositoryUpdatesEnabled
        snapshotValue = try JSONDecoder().decode(OperatorSnapshot.self, from: Data("{\"projects\":[\(project)]}".utf8))
        queueValue = try JSONDecoder().decode(OperatorInstructionQueue.self, from: Data("{\"project_id\":\"11111111-1111-4111-8111-111111111111\",\"project_generation\":4,\"revision\":0,\"running\":false,\"packages\":[]}".utf8))
    }
    func observations() -> (snapshots: Int, repositoryWrites: Int, otherMutations: Int) { (snapshots, repositoryWrites, otherMutations) }
    func snapshot(limit: Int, cursor: String?) async throws -> OperatorSnapshot { snapshots += 1; return snapshotValue }
    func instructionQueue(projectID: String, generation: UInt64) async throws -> OperatorInstructionQueue {
        guard projectID == Self.projectID, generation == 4 else { throw unsupported }
        return queueValue
    }
    func repositoryRequests() -> [RepositoryCall] { repositoryCalls }
    func updateProjectRepository(projectID: String, generation: UInt64, location: String?) async throws -> OperatorProject {
        repositoryWrites += 1
        guard repositoryUpdatesEnabled, repositoryCalls.count < 2,
              projectID == Self.projectID, generation == 4,
              var project = try JSONSerialization.jsonObject(with: projectTemplate) as? [String: Any] else {
            throw unsupported
        }
        project["github_repository_url"] = location
        let data = try JSONSerialization.data(withJSONObject: ["projects": [project]], options: [.sortedKeys])
        guard data.count <= 64 * 1_024 else { throw unsupported }
        snapshotValue = try JSONDecoder().decode(OperatorSnapshot.self, from: data)
        repositoryCalls.append(.init(projectID: projectID, generation: generation, location: location))
        return snapshotValue.projects[0]
    }
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

// ForgeConductorUITests.swift
// Launches the signed macOS product and exercises its native navigation and controls.
// Stable accessibility identifiers make the checks independent of display coordinates.

import AppKit
import Darwin
import Metal
import Network
import XCTest

/// Launches the real Forge Conductor macOS app and exercises sidebar navigation.
///
/// Requires a built `Forge Conductor.app` as the test host (configured in the
/// ForgeConductorUITests target). Run via:
/// `xcodebuild -scheme ForgeConductor -destination 'platform=macOS' test`
/// XCTest serializes each test-case instance; lifecycle hooks assert main-actor
/// execution before accessing XCUIAutomation state.
@MainActor
final class ForgeConductorUITests: XCTestCase, @unchecked Sendable {
    var app: XCUIApplication!
    var testHome: URL!
    private var operatorFixture: OperatorManagerUITestFixture?
    private var guidedModeDefaultsSuite: String?
    private var guidedSetupDefaultsSuite: String?
    private var workbenchDefaultsSuite: String?

    nonisolated override func setUpWithError() throws {
        MainActor.assumeIsolated {
            continueAfterFailure = false
            testHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("forge-conductor-ui-\(UUID().uuidString)", isDirectory: true)
            app = XCUIApplication()
            app.launchArguments += ["--uitesting"]
            app.launchEnvironment["FORGE_CONDUCTOR_HOME"] = testHome.path
            app.launchEnvironment["FORGE_SKIP_PS"] = "1"
            guidedModeDefaultsSuite = "com.forge-conductor.guided-ui.\(testHome.lastPathComponent)"
            app.launchEnvironment["FORGE_GUIDED_MODE_DEFAULTS_SUITE"] = guidedModeDefaultsSuite
            guidedSetupDefaultsSuite = "com.forge-conductor.setup-ui.\(testHome.lastPathComponent)"
            app.launchEnvironment["FORGE_GUIDED_SETUP_DEFAULTS_SUITE"] = guidedSetupDefaultsSuite
            workbenchDefaultsSuite = "com.forge-conductor.workbench-ui.\(testHome.lastPathComponent)"
            app.launchEnvironment["FORGE_WORKBENCH_DEFAULTS_SUITE"] = workbenchDefaultsSuite
            app.launch()
        }
    }

    nonisolated override func tearDownWithError() throws {
        MainActor.assumeIsolated {
            app?.terminate()
            app = nil
            operatorFixture?.stop()
            operatorFixture = nil
            if let guidedModeDefaultsSuite {
                UserDefaults(suiteName: guidedModeDefaultsSuite)?
                    .removePersistentDomain(forName: guidedModeDefaultsSuite)
            }
            guidedModeDefaultsSuite = nil
            if let guidedSetupDefaultsSuite {
                UserDefaults(suiteName: guidedSetupDefaultsSuite)?
                    .removePersistentDomain(forName: guidedSetupDefaultsSuite)
            }
            guidedSetupDefaultsSuite = nil
            if let workbenchDefaultsSuite {
                UserDefaults(suiteName: workbenchDefaultsSuite)?
                    .removePersistentDomain(forName: workbenchDefaultsSuite)
            }
            workbenchDefaultsSuite = nil
            if let testHome {
                try? FileManager.default.removeItem(at: testHome)
            }
            testHome = nil
        }
    }

    func testAppLaunchesAndShowsTitle() throws {
        let title = app.staticTexts["app-title"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 8) || app.staticTexts["Forge Conductor"].waitForExistence(timeout: 8),
            "App window should show Forge Conductor branding"
        )
        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertEqual(
            app.windows.count,
            1,
            "Forge Conductor should have exactly one main window after launch"
        )
    }

    func testSidebarTabsNavigate() throws {
        // Prefer accessibility identifiers; fall back to visible labels.
        let tabs: [(id: String, label: String, detail: String)] = [
            ("tab-rig", "Dashboard", "detail-rig"),
            ("tab-mcp", "LM Studio MCP", "detail-mcp"),
            ("tab-agents", "Agents", "detail-agents"),
            ("tab-tools", "Tools", "detail-tools"),
            ("tab-feed", "Live Feed", "detail-feed"),
            ("tab-projects", "Projects", "detail-projects"),
            ("tab-rune-forge", "Rune Forge", "detail-rune-forge"),
            ("tab-continuity", "Continuity", "detail-continuity"),
            ("tab-runtimes", "Runtimes", "detail-runtimes"),
            ("tab-provider", "Provider", "detail-provider"),
            ("tab-evidence", "Events & Evidence", "detail-evidence"),
            ("tab-diagnostics", "Diagnostics", "detail-diagnostics"),
            ("tab-manager", "Manager", "detail-manager"),
        ]

        for tab in tabs {
            let byID = app.buttons[tab.id]
            let byLabel = app.staticTexts[tab.label]
            let cell = app.cells.containing(.staticText, identifier: tab.label).element

            if byID.waitForExistence(timeout: 2) {
                byID.click()
            } else if cell.waitForExistence(timeout: 2) {
                cell.click()
            } else if byLabel.waitForExistence(timeout: 2) {
                byLabel.click()
            } else {
                // Sidebar List may expose as outline rows
                let row = app.outlines.staticTexts[tab.label]
                if row.waitForExistence(timeout: 2) {
                    row.click()
                } else {
                    XCTFail("Could not find tab \(tab.label) / \(tab.id)")
                    continue
                }
            }

            let detail = app.descendants(matching: .any)[tab.detail]
            XCTAssertTrue(
                detail.waitForExistence(timeout: 3),
                "Detail content was blank after selecting \(tab.label)"
            )
        }
    }

    func testRuneForgeAcceptsOpaqueSourceImmediatelyWhileManagerIsUnavailable() throws {
        let sourceDirectory = testHome.appendingPathComponent("policy-fixture", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let source = sourceDirectory.appendingPathComponent("governance.opaque-format")
        try Data([0x00, 0x7f, 0xff]).write(to: source)

        app.terminate()
        app.launchEnvironment["FORGE_RUNE_POLICY_UI_TEST_SELECTION"] = source.path
        app.launch()

        let tab = app.buttons["tab-rune-forge"]
        XCTAssertTrue(tab.waitForExistence(timeout: 8))
        tab.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["rune-forge-view"].waitForExistence(timeout: 5)
        )

        let add = app.buttons["rune-policy-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()

        let sourceRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "rune-policy-source-row-")
        ).firstMatch
        XCTAssertTrue(
            sourceRow.waitForExistence(timeout: 3),
            "Every selected format must appear before manager interpretation completes"
        )
        XCTAssertTrue(sourceRow.label.contains("governance.opaque-format"))
        XCTAssertTrue(
            sourceRow.label.contains("Refresh pending")
                || sourceRow.label.contains("Accepted")
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["operator-unavailable"].waitForExistence(timeout: 3),
            "Cached policy UI must remain usable while the manager is unavailable"
        )
    }

    func testRuneForgePresentsAndCancelsNativePolicyPicker() throws {
        let tab = app.buttons["tab-rune-forge"]
        XCTAssertTrue(tab.waitForExistence(timeout: 8))
        tab.click()

        let add = app.buttons["rune-policy-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()

        let panel = app.dialogs["open-panel"]
        let confirm = panel.buttons["Add Development Policy"]
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 5),
            "Add Development Policy must present the native open panel"
        )
        let cancel = panel.buttons["CancelButton"]
        XCTAssertTrue(cancel.exists)
        cancel.click()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
    }

    func testRuneForgePresentsFourFormatNativeExportPicker() throws {
        let tab = app.buttons["tab-rune-forge"]
        XCTAssertTrue(tab.waitForExistence(timeout: 8))
        tab.click()

        let export = app.menuButtons["rune-policy-export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.click()

        let jsonl = app.menuItems["JSON Lines (.jsonl)"]
        XCTAssertTrue(jsonl.waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["JSON snapshot (.json)"].exists)
        XCTAssertTrue(app.menuItems["Markdown report (.md)"].exists)
        XCTAssertTrue(app.menuItems["CSV table (.csv)"].exists)
        jsonl.click()

        let panel = app.dialogs["save-panel"]
        let confirm = panel.buttons["Export Policy Log"]
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 5),
            "Export Policy Log must present the native save panel"
        )
        let cancel = panel.buttons["CancelButton"]
        XCTAssertTrue(cancel.exists)
        cancel.click()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
    }

    func testRuneForgePolicyFeedRouteShowsBoundedEventSurface() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        let tab = app.buttons["tab-rune-forge"]
        XCTAssertTrue(tab.waitForExistence(timeout: 8))
        tab.click()

        let route = app.descendants(matching: .any)["rune-policy-feed-route"]
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        route.click()
        let feed = app.descendants(matching: .any)["rune-policy-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        let policyEvent = app.descendants(matching: .any)[
            "rune-policy-event-55555555-5555-4555-8555-555555555555"
        ]
        XCTAssertTrue(
            policyEvent.waitForExistence(timeout: 5),
            "Rune Forge must render the populated, newest-first violation event"
        )
        feed.swipeUp()
        let summary = policyEvent.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Summary"))
            .firstMatch
        let scope = policyEvent.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Scope"))
            .firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertTrue(scope.waitForExistence(timeout: 3))
        XCTAssertTrue(
            element(
                summary,
                contains: "Fixture policy violation: documentation evidence is missing."
            ),
            "The populated Summary field must expose its fixture text: \(summary.debugDescription)"
        )
        XCTAssertTrue(
            element(scope, contains: "Project: \(fixture.projectID)"),
            "The verbose policy event must display its exact project scope"
        )
        XCTAssertGreaterThanOrEqual(fixture.policySnapshotRequestCount, 1)
        XCTAssertGreaterThanOrEqual(fixture.policyViolationRequestCount, 1)
        feed.swipeUp()
        let evaluation = app.descendants(matching: .any)["rune-policy-evaluation-fixture-evaluation"]
        XCTAssertTrue(evaluation.waitForExistence(timeout: 5))
        XCTAssertTrue(evaluation.staticTexts["Fixture observation evaluated without a finding."].exists)
    }

    func testRefreshToolbarExists() throws {
        try showWorkbenchControls(["refresh"])
        let refresh = app.buttons["toolbar-refresh"]
        XCTAssertTrue(
            refresh.waitForExistence(timeout: 5),
            "The production Refresh now control must remain accessibility-visible"
        )
        XCTAssertTrue(refresh.isEnabled)
        refresh.click()
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    func testGuidedModeRoutesEveryPrimaryViewToItsOwnGuide() throws {
        try showWorkbenchControls(["guidedMode", "guide"])
        let guidedMode = app.descendants(matching: .any)["toolbar-guided-mode"]
        XCTAssertTrue(guidedMode.waitForExistence(timeout: 8))

        let tabs: [(id: String, title: String)] = [
            ("tab-rig", "Dashboard guide"),
            ("tab-mcp", "LM Studio MCP guide"),
            ("tab-agents", "Agents guide"),
            ("tab-tools", "Tools guide"),
            ("tab-feed", "Live Feed guide"),
            ("tab-projects", "Projects guide"),
            ("tab-rune-forge", "Rune Forge guide"),
            ("tab-continuity", "Continuity guide"),
            ("tab-runtimes", "Runtimes guide"),
            ("tab-provider", "Model connection guide"),
            ("tab-evidence", "Events & Evidence guide"),
            ("tab-diagnostics", "Diagnostics guide"),
            ("tab-manager", "Manager guide"),
        ]
        let guideButton = app.buttons["toolbar-setup-guide"]
        XCTAssertTrue(
            guideButton.waitForExistence(timeout: 8),
            "Contextual help must remain available after first launch"
        )

        for tab in tabs {
            let tabButton = app.buttons[tab.id]
            XCTAssertTrue(tabButton.waitForExistence(timeout: 5), "Missing \(tab.id)")
            tabButton.click()
            guideButton.click()
            XCTAssertTrue(
                app.descendants(matching: .any)["guided-help-sheet"].waitForExistence(timeout: 5),
                "Guide sheet did not open for \(tab.id)"
            )
            XCTAssertTrue(
                app.staticTexts[tab.title].waitForExistence(timeout: 3),
                "Wrong guide routed for \(tab.id)"
            )
            app.buttons["guided-help-close"].click()
            XCTAssertTrue(waitUntil(timeout: 2) {
                !self.app.descendants(matching: .any)["guided-help-sheet"].exists
            })
        }
    }

    func testGuidedModePersistsAndGuideClosesFromKeyboard() throws {
        try showWorkbenchControls(["guidedMode", "guide"])
        var toggle = app.descendants(matching: .any)["toolbar-guided-mode"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        let wasEnabled = guidedModeIsEnabled(toggle)
        if !wasEnabled { toggle.click() }

        XCTAssertTrue(
            app.descendants(matching: .any)["guided-inline-rig"].waitForExistence(timeout: 3)
        )

        app.terminate()
        app.launch()
        toggle = app.descendants(matching: .any)["toolbar-guided-mode"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        XCTAssertTrue(guidedModeIsEnabled(toggle))
        XCTAssertTrue(app.descendants(matching: .any)["guided-inline-rig"].waitForExistence(timeout: 3))

        let help = app.buttons["toolbar-setup-guide"]
        XCTAssertTrue(help.waitForExistence(timeout: 3))
        help.click()
        XCTAssertTrue(app.staticTexts["Dashboard guide"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["What Forge handles automatically"].exists)
        XCTAssertTrue(app.staticTexts["Controls"].exists)
        XCTAssertTrue(app.staticTexts["Status meanings"].exists)
        XCTAssertTrue(app.buttons["guided-help-close"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 3) {
            !self.app.descendants(matching: .any)["guided-help-sheet"].exists
        })

        if !wasEnabled { toggle.click() }
    }

    private func guidedModeIsEnabled(_ element: XCUIElement) -> Bool {
        if let number = element.value as? NSNumber {
            return number.boolValue
        }
        return (element.value as? String) == "1"
    }

    private func showWorkbenchControls(_ controls: [String]) throws {
        app.terminate()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: try XCTUnwrap(workbenchDefaultsSuite)))
        for control in controls {
            defaults.set(true, forKey: "forge.workbench.control.\(control).v1")
        }
        _ = defaults.synchronize()
        app.launch()
    }

    private func openGuideMenuAction(_ title: String) {
        let menu = app.menuBars.menuBarItems["Guide"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let action = app.menuItems[title]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        XCTAssertTrue(action.isEnabled)
        action.click()
    }

    private func openCurrentGuideFromMenu() { openGuideMenuAction("View Guide") }
    private func openGuidedSetupFromMenu() { openGuideMenuAction("Guided Setup") }

    private func openWorkbenchSettings() -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        selectManagerSection("workbench")
        XCTAssertTrue(settings.descendants(matching: .any)["workbench-settings"].waitForExistence(timeout: 5))
        return settings
    }

    private func setGuidedModeFromSettings(_ enabled: Bool) {
        let settings = openWorkbenchSettings()
        let toggle = settings.checkBoxes["settings-guided-mode"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        makeHittable(toggle)
        if guidedModeIsEnabled(toggle) != enabled { toggle.click() }
        XCTAssertTrue(waitForToggleState(enabled, on: toggle, timeout: 3))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 3))
    }

    func testWorkbenchControlsAreHiddenByDefaultAndSettingsPersistOnlyOptedInActions() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let window = app.windows["forge-main-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)
        assertGraphiteGlobalHeader(in: window)
        captureGraphite("default-workbench-without-controls")

        app.buttons["tab-manager"].click()
        selectManagerSection("settings")
        let draftHost = window.textFields["Dashboard host"]
        XCTAssertTrue(draftHost.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("127.0.0.1", on: draftHost))
        draftHost.click()
        draftHost.typeKey("a", modifierFlags: .command)
        draftHost.typeText("127.0.0.2")
        let updatesBefore = fixture.settingsUpdateCount

        let settings = openWorkbenchSettings()
        XCTAssertFalse(settings.buttons["settings-save"].exists,
                       "Local Workbench preferences must not require a Manager save")
        let controls = ["navigation", "autoRefresh", "guidedMode", "guide", "refresh", "guidedSetup"]
        for control in controls {
            let toggle = settings.checkBoxes["settings-control-\(control)"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 3))
            XCTAssertTrue(waitForToggleState(false, on: toggle, timeout: 3))
        }
        makeHittable(settings.checkBoxes["settings-control-guidedSetup"])
        for control in controls {
            let toggle = settings.checkBoxes["settings-control-\(control)"]
            XCTAssertTrue(toggle.isHittable)
            XCTAssertTrue(frameIsContained(toggle.frame, in: settings.frame, tolerance: 2))
        }
        captureGraphite("settings-workbench-defaults")

        let refresh = settings.buttons["settings-refresh"]
        makeHittable(refresh)
        XCTAssertTrue(refresh.isHittable)
        XCTAssertTrue(refresh.isEnabled)
        refresh.click()
        XCTAssertTrue(settings.descendants(matching: .any)["settings-refresh-status"].waitForExistence(timeout: 5))

        let navigation = settings.checkBoxes["settings-navigation-visible"]
        makeHittable(navigation)
        XCTAssertTrue(waitForToggleState(true, on: navigation, timeout: 3))
        navigation.click()
        XCTAssertTrue(waitForToggleState(false, on: navigation, timeout: 3))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 3))
        XCTAssertTrue(window.buttons["tab-manager"].waitForNonExistence(timeout: 3))
        app.menuBars.menuBarItems["Navigation"].click()
        captureGraphite("navigation-menu-after-settings-hide")
        let showNavigation = app.menuItems["Show Navigation"]
        XCTAssertTrue(showNavigation.waitForExistence(timeout: 3))
        showNavigation.click()
        XCTAssertTrue(window.buttons["tab-manager"].waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue("127.0.0.2", on: draftHost),
                      "Entering native Settings must preserve the pre-existing Manager draft")

        setGuidedModeFromSettings(true)
        XCTAssertTrue(window.descendants(matching: .any)["guided-inline-manager"].waitForExistence(timeout: 3))
        openCurrentGuideFromMenu()
        XCTAssertTrue(app.sheets.firstMatch.staticTexts["Manager guide"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 3))
        openGuidedSetupFromMenu()
        XCTAssertTrue(app.descendants(matching: .any)["setup-guide"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 3))

        _ = openWorkbenchSettings()
        let settingsGuide = settings.buttons["settings-show-guide"]
        makeHittable(settingsGuide)
        settingsGuide.click()
        XCTAssertTrue(app.sheets.firstMatch.staticTexts["Manager guide"].waitForExistence(timeout: 5))
        captureGraphite("settings-view-guide-route")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 3))
        _ = openWorkbenchSettings()
        let settingsSetup = settings.buttons["settings-guided-setup"]
        makeHittable(settingsSetup)
        settingsSetup.click()
        XCTAssertTrue(app.descendants(matching: .any)["setup-guide"].waitForExistence(timeout: 5))
        captureGraphite("settings-guided-setup-route")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 3))

        _ = openWorkbenchSettings()
        let autoRefresh = settings.checkBoxes["settings-auto-refresh"]
        makeHittable(autoRefresh)
        XCTAssertTrue(waitForToggleState(true, on: autoRefresh, timeout: 3))
        autoRefresh.click()
        XCTAssertTrue(waitForToggleState(false, on: autoRefresh, timeout: 3))
        app.typeKey("w", modifierFlags: .command)
        app.menuBars.menuBarItems["Telemetry"].click()
        let automatic = app.menuItems["Auto-refresh"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 3))
        automatic.click()
        _ = openWorkbenchSettings()
        XCTAssertTrue(waitForToggleState(true, on: autoRefresh, timeout: 3),
                      "Telemetry menu and native Settings must share the same refresh behavior")

        let guideOnly = settings.checkBoxes["settings-control-guide"]
        makeHittable(guideOnly)
        guideOnly.click()
        XCTAssertTrue(waitForToggleState(true, on: guideOnly, timeout: 3))
        app.typeKey("w", modifierFlags: .command)
        let header = window.descendants(matching: .any)["workbench-global-controls"]
        XCTAssertTrue(header.waitForExistence(timeout: 3))
        XCTAssertTrue(header.buttons["toolbar-setup-guide"].isHittable)
        for identifier in ["toolbar-navigation", "toolbar-auto-refresh", "toolbar-guided-mode", "toolbar-refresh", "dashboard-guided-setup"] {
            XCTAssertFalse(header.descendants(matching: .any)[identifier].exists,
                           "Enabling Guide must not reveal unrelated optional controls")
        }
        XCTAssertTrue(waitForValue("127.0.0.2", on: draftHost))
        XCTAssertEqual(fixture.settingsUpdateCount, updatesBefore)
        captureGraphite("only-guide-control-opted-in")

        _ = openWorkbenchSettings()
        for control in controls where control != "guide" {
            let toggle = settings.checkBoxes["settings-control-\(control)"]
            makeHittable(toggle)
            toggle.click()
            XCTAssertTrue(waitForToggleState(true, on: toggle, timeout: 3))
        }
        captureGraphite("settings-workbench-opted-in-controls")
        app.typeKey("w", modifierFlags: .command)
        assertGraphiteGlobalHeader(in: window, expectsAllControls: true)
        XCTAssertTrue(waitForValue("127.0.0.2", on: draftHost))
        window.buttons["settings-reload"].click()
        XCTAssertTrue(waitForValue("127.0.0.1", on: draftHost),
                      "Explicit Reload must still replace the staged Manager draft")
        XCTAssertEqual(fixture.settingsUpdateCount, updatesBefore)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: try XCTUnwrap(workbenchDefaultsSuite)))
        XCTAssertTrue(waitUntil(timeout: 3) {
            _ = defaults.synchronize()
            return controls.allSatisfy { defaults.bool(forKey: "forge.workbench.control.\($0).v1") }
        })
        app.terminate()
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        assertGraphiteGlobalHeader(in: window, expectsAllControls: true)
        captureGraphite("opted-in-controls-persisted-after-relaunch")
        XCTAssertEqual(fixture.settingsUpdateCount, updatesBefore)
        XCTAssertEqual(fixture.startRequestCount, 0)
        XCTAssertEqual(fixture.controlRequestCount, 0)
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 0)
    }

    func testWorkbenchOptionalControlsCanBeRemovedAndStayHiddenAfterRelaunch() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let window = app.windows["forge-main-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)
        let controls = ["navigation", "autoRefresh", "guidedMode", "guide", "refresh", "guidedSetup"]
        try showWorkbenchControls(controls)
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        assertGraphiteGlobalHeader(in: window, expectsAllControls: true)

        let settings = openWorkbenchSettings()
        for control in controls where control != "guide" {
            let toggle = settings.checkBoxes["settings-control-\(control)"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 3))
            makeHittable(toggle)
            XCTAssertTrue(waitForToggleState(true, on: toggle, timeout: 3))
            toggle.click()
            XCTAssertTrue(waitForToggleState(false, on: toggle, timeout: 3))
        }
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 3))
        let header = window.descendants(matching: .any)["workbench-global-controls"]
        XCTAssertTrue(header.waitForExistence(timeout: 3))
        XCTAssertTrue(header.buttons["toolbar-setup-guide"].isHittable)
        for identifier in ["toolbar-navigation", "toolbar-auto-refresh", "toolbar-guided-mode", "toolbar-refresh", "dashboard-guided-setup", "toolbar-guided-setup"] {
            XCTAssertFalse(header.descendants(matching: .any)[identifier].exists)
        }
        captureGraphite("opt-out-retains-only-guide")

        _ = openWorkbenchSettings()
        let lastControl = settings.checkBoxes["settings-control-guide"]
        makeHittable(lastControl)
        XCTAssertTrue(waitForToggleState(true, on: lastControl, timeout: 3))
        lastControl.click()
        XCTAssertTrue(waitForToggleState(false, on: lastControl, timeout: 3))
        makeHittable(settings.checkBoxes["settings-control-guidedSetup"])
        for control in controls {
            XCTAssertTrue(waitForToggleState(false, on: settings.checkBoxes["settings-control-\(control)"], timeout: 3))
        }
        captureGraphite("settings-workbench-all-controls-opted-out")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 3))
        XCTAssertTrue(header.waitForNonExistence(timeout: 3),
                      "Removing the last optional control must remove the entire control bar")
        assertGraphiteGlobalHeader(in: window)
        captureGraphite("opt-out-removes-last-control-bar")

        let defaults = try XCTUnwrap(UserDefaults(suiteName: try XCTUnwrap(workbenchDefaultsSuite)))
        XCTAssertTrue(waitUntil(timeout: 3) {
            _ = defaults.synchronize()
            return controls.allSatisfy { !defaults.bool(forKey: "forge.workbench.control.\($0).v1") }
        })
        app.terminate()
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        assertGraphiteGlobalHeader(in: window)
        captureGraphite("opt-out-persists-clean-workspace-after-relaunch")
        _ = openWorkbenchSettings()
        for control in controls {
            XCTAssertTrue(waitForToggleState(false, on: settings.checkBoxes["settings-control-\(control)"], timeout: 3))
        }
        XCTAssertEqual(fixture.settingsUpdateCount, 0)
        XCTAssertEqual(fixture.startRequestCount, 0)
        XCTAssertEqual(fixture.controlRequestCount, 0)
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 0)
    }

    func testDashboardToolbarGuidedSetupButtonIsLabeledHittableAndOpensWizard() throws {
        try showWorkbenchControls(["guidedSetup"])
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        let dashboard = app.buttons["tab-rig"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 8))
        dashboard.click()

        let header = app.descendants(matching: .any)["workbench-global-controls"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let guidedSetup = header.buttons["dashboard-guided-setup"]
        XCTAssertTrue(
            guidedSetup.waitForExistence(timeout: 5),
            "Dashboard must expose a clearly labeled Guided Setup button in the view header"
        )
        XCTAssertTrue(guidedSetup.label.contains("Guided Setup"))
        XCTAssertTrue(guidedSetup.isHittable)
        guidedSetup.click()

        let wizard = app.descendants(matching: .any)["setup-guide"]
        XCTAssertTrue(wizard.waitForExistence(timeout: 5))
        let closeByIdentifier = app.buttons["guided-setup-close"]
        let close = closeByIdentifier.exists ? closeByIdentifier : app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.click()
        XCTAssertTrue(waitUntil(timeout: 3) { !wizard.exists })
    }

    func testAppLaunchDoesNotPresentGuidedSetupAutomatically() throws {
        app.terminate()
        let suiteName = try XCTUnwrap(guidedSetupDefaultsSuite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: "forge.setupTutorial.completed.v1")
        defaults.set(false, forKey: "forge.guidedSetup.completed.v2")
        _ = defaults.synchronize()

        app.launch()

        let wizard = app.descendants(matching: .any)["setup-guide"]
        XCTAssertFalse(
            wizard.waitForExistence(timeout: 2),
            "Guided Setup must remain closed until the operator explicitly opens it"
        )
    }

    func testGuidedSetupReviewConfirmationAdvancesToStartAndPersists() throws {
        let fixture = try OperatorManagerUITestFixture(
            initialRunState: "completed",
            initialProviderHealth: "contract_valid"
        )
        relaunch(with: fixture)

        openGuidedSetupFromMenu()

        let reviewStep = app.buttons["guided-setup-step-5"]
        XCTAssertTrue(reviewStep.waitForExistence(timeout: 5))
        makeHittable(reviewStep)
        reviewStep.click()

        let reviewIdentity = app.staticTexts["guided-setup-review-project-identity"]
        XCTAssertTrue(reviewIdentity.waitForExistence(timeout: 5))
        XCTAssertTrue(element(reviewIdentity, contains: "generation 4"))

        let confirmByIdentifier = app.buttons["setup-guide-confirm-review"]
        let confirm = confirmByIdentifier.exists
            ? confirmByIdentifier
            : app.buttons["Confirm Review and Continue"]
        XCTAssertTrue(waitForEnabled(confirm, timeout: 5))
        confirm.click()
        let activeTitle = app.staticTexts["guided-setup-step-title"]
        XCTAssertTrue(
            waitUntil(timeout: 3) { self.element(activeTitle, contains: "Start in LM Studio") }
        )

        let suiteName = try XCTUnwrap(guidedSetupDefaultsSuite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertTrue(waitUntil(timeout: 3) {
            _ = defaults.synchronize()
            return defaults.integer(forKey: "forge.guidedSetup.step.v2") == 5
                && defaults.string(forKey: "forge.guidedSetup.reviewedPreparation.v2")?.count == 64
                && defaults.string(forKey: "forge.guidedSetup.reviewProject.v1")?.isEmpty == false
        }, "The chosen project and exact reviewed preparation must be durably saved")
        let reviewedFingerprint = try XCTUnwrap(
            defaults.string(forKey: "forge.guidedSetup.reviewedPreparation.v2")
        )

        let closeByIdentifier = app.buttons["guided-setup-close"]
        let close = closeByIdentifier.exists ? closeByIdentifier : app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.click()

        openGuidedSetupFromMenu()
        XCTAssertTrue(
            waitUntil(timeout: 3) { self.element(activeTitle, contains: "Start in LM Studio") },
            "The explicitly confirmed preparation and selected step must resume after reopening"
        )
        makeHittable(reviewStep)
        reviewStep.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.element(confirm, contains: "Continue to LM Studio") && confirm.isEnabled
        }, "Reopening the same inputs must retain the exact review")
        XCTAssertEqual(
            defaults.string(forKey: "forge.guidedSetup.reviewedPreparation.v2"),
            reviewedFingerprint
        )
        XCTAssertEqual(fixture.startRequestCount, 0)
        XCTAssertEqual(fixture.controlRequestCount, 0)
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertEqual(fixture.providerProbeAuthorizationCount, 0)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 0,
                       "Reviewing before a chat must not activate a provider, bind a session or start work")
    }

    func testDashboardTitleButtonOpensOrderedGuidedSetupWizard() throws {
        try showWorkbenchControls(["guidedSetup"])
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        let dashboard = app.buttons["tab-rig"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 8))
        dashboard.click()
        XCTAssertTrue(app.staticTexts["detail-rig"].waitForExistence(timeout: 5))

        let guidedSetup = app.buttons["dashboard-guided-setup"]
        XCTAssertTrue(
            guidedSetup.waitForExistence(timeout: 5),
            "Dashboard title area must expose Guided Setup"
        )
        guidedSetup.click()

        let wizard = app.descendants(matching: .any)["setup-guide"]
        XCTAssertTrue(wizard.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Guided Setup"].exists)
        XCTAssertTrue(
            app.staticTexts["Set up Forge, work in LM Studio, and monitor policy and continuity"].exists
        )

        let expectedSteps = [
            "Confirm Forge is ready",
            "Connect the model provider",
            "Register the project",
            "Add and order instructions",
            "Review project inputs",
            "Start in LM Studio",
            "Monitor governance and continuity",
            "Resolve issues and continue",
        ]
        for (offset, title) in expectedSteps.enumerated() {
            let step = app.buttons["guided-setup-step-\(offset + 1)"]
            XCTAssertTrue(step.waitForExistence(timeout: 3), "Missing guided setup step \(offset + 1)")
            makeHittable(step)
            step.click()
            let activeTitle = app.staticTexts["guided-setup-step-title"]
            XCTAssertTrue(
                waitUntil(timeout: 3) { self.element(activeTitle, contains: title) },
                "Guided setup step \(offset + 1) should be \(title)"
            )
        }

        XCTAssertTrue(
            app.buttons["setup-guide-finish"].exists
                || app.buttons["Finish Guided Setup"].exists,
            "The final wizard step must expose Finish Guided Setup:\n\(app.debugDescription)"
        )
        if wizard.exists {
            let closeByIdentifier = app.buttons["guided-setup-close"]
            let close = closeByIdentifier.exists ? closeByIdentifier : app.buttons["Close"]
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            close.click()
        }
        XCTAssertTrue(waitUntil(timeout: 3) { !wizard.exists })
        XCTAssertTrue(app.descendants(matching: .any)["detail-rig"].exists)

        XCTAssertTrue(guidedSetup.waitForExistence(timeout: 3))
        guidedSetup.click()
        XCTAssertTrue(wizard.waitForExistence(timeout: 3))
        XCTAssertTrue(
            element(
                app.staticTexts["guided-setup-step-title"],
                contains: "Resolve issues and continue"
            ),
            "Closing and reopening Guided Setup must resume the saved step"
        )
    }

    func testStartTaskGuidePreservesEnteredInstructions() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        openProjectRuns()
        let start = app.buttons["autonomy-start"]
        XCTAssertTrue(waitForEnabled(start, timeout: 5))
        start.click()

        let mission = app.descendants(matching: .any)["run-start-mission"]
        XCTAssertTrue(
            mission.waitForExistence(timeout: 5),
            "Start Task draft field was not accessibility-visible:\n\(app.debugDescription)"
        )
        mission.click()
        mission.typeText("Preserve this task draft")

        let help = app.buttons["guided-help-autonomyStartTask"]
        XCTAssertTrue(help.waitForExistence(timeout: 3))
        help.click()
        XCTAssertTrue(app.staticTexts["Start Task guide"].waitForExistence(timeout: 3))
        app.buttons["guided-help-close"].click()

        XCTAssertEqual(mission.value as? String, "Preserve this task draft")
        app.buttons["run-start-cancel"].click()
    }

    func testManagerShowsProjectShellPolicyControls() throws {
        let managerTab = app.buttons["tab-manager"]
        XCTAssertTrue(managerTab.waitForExistence(timeout: 8))
        managerTab.click()
        selectManagerSection("shell")

        let shellToggle = app.descendants(matching: .any)["settings-shell-enabled"]
        XCTAssertTrue(
            shellToggle.waitForExistence(timeout: 5),
            "Manager settings must expose the project shell preference"
        )
        XCTAssertTrue(app.descendants(matching: .any)["shell-effective-policy"].exists)
        for runtime in ["zsh", "bash", "python", "powershell"] {
            XCTAssertTrue(
                app.descendants(matching: .any)["runtime-capability-\(runtime)"].exists,
                "Missing runtime capability row for \(runtime)"
            )
        }
    }

    func testManagerShowsProtectedFilesystemServiceControls() throws {
        app.typeKey(",", modifierFlags: .command)
        selectManagerSection("filesystem")

        let status = app.descendants(matching: .any)[
            "settings-filesystem-service-status"
        ]
        XCTAssertTrue(
            status.waitForExistence(timeout: 5),
            "The macOS Settings scene must expose protected filesystem service status"
        )
        let enable = app.buttons["settings-filesystem-service-enable"]
        let reinstall = app.buttons["settings-filesystem-service-reinstall"]
        let disable = app.buttons["settings-filesystem-service-disable"]
        XCTAssertTrue(enable.exists)
        XCTAssertTrue(reinstall.exists)
        XCTAssertTrue(disable.exists)
        XCTAssertTrue(
            enable.isEnabled || reinstall.isEnabled || disable.isEnabled,
            "The packaged service must expose at least one available lifecycle action"
        )
        let validStates = ["Not enabled", "Enabled", "Approval required"]
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                validStates.contains { self.element(status, contains: $0) }
            },
            "The exact packaged app must not report a missing or invalid service package"
        )
        XCTAssertFalse(element(status, contains: "Not packaged in this build"))
        XCTAssertFalse(element(status, contains: "Not packaged or invalid"))
        let displayedState = try XCTUnwrap(
            validStates.first { element(status, contains: $0) }
        )
        if displayedState == "Enabled" {
            XCTAssertTrue(reinstall.isEnabled)
            XCTAssertTrue(disable.isEnabled)
        } else if displayedState == "Approval required" {
            XCTAssertTrue(enable.isEnabled)
            XCTAssertTrue(reinstall.isEnabled)
            XCTAssertTrue(disable.isEnabled)
        } else {
            XCTAssertTrue(enable.isEnabled)
            XCTAssertTrue(reinstall.isEnabled)
            XCTAssertFalse(disable.isEnabled)
        }
        XCTAssertTrue(app.buttons["settings-filesystem-service-approval"].exists)
        XCTAssertTrue(app.buttons["settings-filesystem-service-refresh"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "settings-filesystem-service-operational-health"
            ].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "settings-filesystem-lifecycle-fence-status"
            ].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["settings-filesystem-recovery-debt"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["settings-filesystem-recovery-policy"].exists
        )
        XCTAssertTrue(app.buttons["settings-filesystem-recovery-reconcile"].exists)
        selectManagerSection("folders")
        XCTAssertTrue(app.buttons["settings-allowed-root-add"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["settings-allowed-roots-empty"].exists
        )
    }

    func testProtectedFilesystemRefreshMutuallyExcludesEveryConflictingControl() throws {
        app.terminate()
        app.launchEnvironment["FORGE_FILESYSTEM_SETTINGS_UI_TEST_DELAY_MS"] = "2000"
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        selectManagerSection("filesystem")

        let operationStatus = app.descendants(matching: .any)[
            "settings-filesystem-operation-status"
        ]
        XCTAssertTrue(operationStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitUntil(timeout: 8) { self.element(operationStatus, contains: "Idle") },
            "bootstrap observation must finish before the explicit control exercise"
        )

        let controls = [
            app.buttons["settings-filesystem-service-enable"],
            app.buttons["settings-filesystem-service-reinstall"],
            app.buttons["settings-filesystem-service-disable"],
            app.buttons["settings-filesystem-service-approval"],
            app.buttons["settings-filesystem-service-refresh"],
            app.buttons["settings-filesystem-recovery-reconcile"],
        ]
        for control in controls {
            XCTAssertTrue(control.exists)
        }

        let refresh = controls[4]
        XCTAssertTrue(refresh.isEnabled)
        makeHittable(refresh)
        refresh.click()

        XCTAssertTrue(
            waitUntil(timeout: 3) {
                self.element(operationStatus, contains: "Refreshing")
                    && controls.allSatisfy { !$0.isEnabled }
            },
            "all protected-filesystem controls must disable during Refresh"
        )
        captureGraphite("settings-filesystem-refresh-pending")
        XCTAssertTrue(
            app.descendants(matching: .any)["settings-filesystem-service-status"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "settings-filesystem-service-operational-health"
            ].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["settings-filesystem-recovery-debt"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["settings-filesystem-operation-progress"].exists
        )

        XCTAssertTrue(
            waitUntil(timeout: 8) {
                self.element(operationStatus, contains: "Idle") && refresh.isEnabled
            },
            "Refresh must return the shared operation gate to idle"
        )
        captureGraphite("settings-filesystem-refresh-settled")
    }

    private func element(_ element: XCUIElement, contains text: String) -> Bool {
        if element.label.localizedCaseInsensitiveContains(text) { return true }
        if element.title.localizedCaseInsensitiveContains(text) { return true }
        if (element.value as? String)?.localizedCaseInsensitiveContains(text) == true { return true }
        return element.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch.exists
    }

    func testManagerSettingsControlsAndPersistsProjectShellPolicy() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        app.typeKey(",", modifierFlags: .command)
        selectManagerSection("shell")
        var shellToggle = app.descendants(matching: .any)["settings-shell-enabled"]
        XCTAssertTrue(
            shellToggle.waitForExistence(timeout: 5),
            "The macOS Settings scene must expose the project shell policy"
        )
        XCTAssertTrue(waitForToggleState(true, on: shellToggle))

        shellToggle.click()
        let save = app.buttons["settings-save"]
        makeHittable(save)
        save.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.settingsUpdateCount == 1 && !fixture.shellEnabled
        })

        let reload = app.buttons["settings-reload"]
        makeHittable(reload)
        reload.click()
        shellToggle = app.descendants(matching: .any)["settings-shell-enabled"]
        XCTAssertTrue(waitForToggleState(false, on: shellToggle))

        app.terminate()
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        selectManagerSection("shell")
        shellToggle = app.descendants(matching: .any)["settings-shell-enabled"]
        XCTAssertTrue(
            shellToggle.waitForExistence(timeout: 5),
            "The macOS Settings scene must remain available after relaunch"
        )
        XCTAssertTrue(waitForToggleState(false, on: shellToggle))

        shellToggle.click()
        let relaunchedSave = app.buttons["settings-save"]
        makeHittable(relaunchedSave)
        relaunchedSave.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.settingsUpdateCount == 2 && fixture.shellEnabled
        })
        XCTAssertTrue(waitForToggleState(true, on: shellToggle))
    }

    func testManagerSettingsStagesCanonicalAllowedRootAndRemoval() throws {
        let selectedRoot = testHome
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("selected-project", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        let canonicalRoot = selectedRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        app.terminate()
        app.launchEnvironment["FORGE_ALLOWED_ROOT_UI_TEST_SELECTION"] = selectedRoot.path
        app.launch()

        let manager = app.buttons["tab-manager"]
        XCTAssertTrue(manager.waitForExistence(timeout: 8))
        manager.click()
        let add = app.buttons["settings-allowed-root-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        makeHittable(add)
        add.click()

        let path = app.descendants(matching: .any)["settings-allowed-root-path-0"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        let exposedPathValues = [path.label, path.title, path.value as? String]
            .compactMap { $0 }
        XCTAssertTrue(
            exposedPathValues.contains(canonicalRoot),
            "The canonical authorized-root path must be visible; observed \(path.debugDescription)"
        )

        let remove = app.buttons["settings-allowed-root-remove-0"]
        makeHittable(remove)
        remove.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings-allowed-roots-empty"]
                .waitForExistence(timeout: 5)
        )
    }

    func testManagerSettingsRejectsFilesystemRootSelection() throws {
        app.terminate()
        app.launchEnvironment["FORGE_ALLOWED_ROOT_UI_TEST_SELECTION"] = "/"
        app.launch()

        let manager = app.buttons["tab-manager"]
        XCTAssertTrue(manager.waitForExistence(timeout: 8))
        manager.click()
        let add = app.buttons["settings-allowed-root-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        makeHittable(add)
        add.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["settings-allowed-roots-empty"]
                .waitForExistence(timeout: 5)
        )
        let message = app.descendants(matching: .any)["settings-allowed-roots-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
    }

    func testOperatorSurfacesReportUnavailableManagerHonestly() throws {
        for tabID in ["tab-projects", "tab-continuity", "tab-runtimes", "tab-provider", "tab-evidence"] {
            let tab = app.buttons[tabID]
            XCTAssertTrue(tab.waitForExistence(timeout: 8), "Missing operator tab \(tabID)")
            tab.click()
            XCTAssertTrue(
                app.descendants(matching: .any)["operator-unavailable"].waitForExistence(timeout: 5),
                "\(tabID) must expose the unavailable manager state instead of fabricated data"
            )
        }
    }

    func testUnavailableManagerCannotStartDuplicateRun() throws {
        XCTAssertFalse(
            app.buttons["tab-autonomy"].exists,
            "Project execution must not be presented as a separate top-level workflow"
        )
        let projects = app.buttons["tab-projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 8))
        projects.click()
        XCTAssertTrue(app.descendants(matching: .any)["operator-unavailable"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["autonomy-start"].exists)
    }

    func testRigShowsBoundedOperationalIndicatorCluster() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        resizeMainWindowForWideGrid(window)

        let rig = app.buttons["tab-rig"]
        XCTAssertTrue(rig.waitForExistence(timeout: 8))
        rig.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["rig-operational-indicators"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["rig-managed-activity-feed"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.activityRequestCount > 0 && fixture.scopedPolicySnapshotRequestCount > 0
        })
        let cpu = app.descendants(matching: .any)["rig-cpu-cores-panel"]
        let gpu = app.descendants(matching: .any)["rig-gpu-cores-panel"]
        let compute = app.descendants(matching: .any)["rig-compute-cores-panel"]
        XCTAssertTrue(cpu.exists)
        XCTAssertTrue(gpu.exists)
        XCTAssertTrue(compute.exists)
        XCTAssertTrue(compute.frame.contains(cpu.frame))
        XCTAssertTrue(compute.frame.contains(gpu.frame))
        XCTAssertFalse(cpu.frame.intersects(gpu.frame), "The revised detailed chip panels must not overlap")
        XCTAssertGreaterThan(cpu.frame.height, 250, "The Compute frame now contains a detailed native chip rather than compact bars")
        XCTAssertTrue(compute.staticTexts["compute-cpu-hardware-name"].exists)
        XCTAssertTrue(compute.staticTexts["compute-gpu-hardware-name"].exists)
        XCTAssertTrue(compute.staticTexts["compute-activity-provenance"].exists)

        let rootScroll = try XCTUnwrap(
            largestScrollView(),
            "Dashboard must remain hosted in its primary vertical scroll surface"
        )
        let storage = app.descendants(matching: .any)["rig-storage-panel"]
        let activity = app.descendants(matching: .any)["rig-managed-activity-feed"]
        for _ in 0..<6 where !storage.frame.intersects(window.frame)
            || !activity.frame.intersects(window.frame) {
            rootScroll.swipeUp()
        }
        XCTAssertTrue(
            storage.frame.intersects(window.frame),
            "Storage must be visible in the instrumentation grid"
        )
        XCTAssertTrue(
            activity.frame.intersects(window.frame),
            "Managed Activity must be visible beside Storage"
        )
        XCTAssertEqual(storage.frame.minY, activity.frame.minY, accuracy: 2)
        XCTAssertLessThan(storage.frame.maxX, activity.frame.minX)
        XCTAssertGreaterThan(
            activity.frame.width,
            storage.frame.width * 1.30,
            "Managed Activity must use the width recovered from compact Storage and Orchestration"
        )
        let orchestration = app.descendants(matching: .any)["rig-orchestration-panel"]
        XCTAssertTrue(orchestration.exists)
        XCTAssertEqual(orchestration.frame.width, storage.frame.width, accuracy: 2)
        XCTAssertEqual(orchestration.frame.minX, storage.frame.minX, accuracy: 2)
        XCTAssertGreaterThan(orchestration.frame.minY, storage.frame.maxY)

        XCTAssertTrue(app.staticTexts["CURRENT PACKAGE · No active instruction package"].exists)
        XCTAssertTrue(app.staticTexts["BACKGROUND EXECUTION · RUNNING"].exists)
        XCTAssertTrue(app.staticTexts["PHASE · Implementation"].exists)
        XCTAssertTrue(app.staticTexts["WORK · Render managed activity"].exists)
        XCTAssertTrue(app.staticTexts["NEXT · Verify the live activity feed"].exists)
        XCTAssertTrue(
            app.staticTexts["NEXT PACKAGE · Fixture Instructions · POSITION 1 · 1 STEPS"].exists,
            "An unrelated queued package must be shown as next work, not the current package"
        )
        let assistantActivity = app.descendants(matching: .any)[
            "rig-activity-row-operator:fixture-assistant-event"
        ]
        XCTAssertTrue(assistantActivity.waitForExistence(timeout: 3))
        XCTAssertTrue(
            element(assistantActivity, contains: "Bounded assistant response from LM Studio."),
            "The authenticated activity feed must expose the current managed-session response"
        )
    }

    func testMinimumWindowKeepsEveryPrimaryViewContainedAndAligned() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        resizeMainWindowToMinimum(window)

        try assertEveryPrimaryViewContainedAndAligned(in: window)
    }

    func testProjectsReorderAndDeletePackageRemainHittableAtMinimumWindow() throws {
        let fixture = try OperatorManagerUITestFixture(includeSecondInstructionPackage: true)
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        resizeMainWindowToMinimum(window)

        let projects = app.buttons["tab-projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 5))
        projects.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["project-instruction-packages"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            app.outlines.matching(identifier: "instruction-package-list").count,
            0,
            "Instruction packages must not use a nested List inside the Projects ScrollView"
        )

        XCTAssertFalse(
            app.buttons["instruction-queue-toggle"].exists,
            "Projects must not expose the obsolete Managed Run start/stop action"
        )

        let moveLater = app.buttons[
            "instruction-package-move-down-\(fixture.instructionPackageID)"
        ]
        XCTAssertTrue(moveLater.waitForExistence(timeout: 5))
        makeHittable(moveLater)
        XCTAssertTrue(waitForEnabled(moveLater, timeout: 5))
        moveLater.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.instructionQueueReorderRequestCount == 1
                && fixture.instructionPackageIDs == [
                    fixture.secondInstructionPackageID,
                    fixture.instructionPackageID,
                ]
        })

        let reorderRefreshBaseline = fixture.instructionQueueStatusRequestCount
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.instructionQueueStatusRequestCount > reorderRefreshBaseline
        })
        let moveEarlier = app.buttons[
            "instruction-package-move-up-\(fixture.instructionPackageID)"
        ]
        XCTAssertTrue(moveEarlier.waitForExistence(timeout: 5))
        makeHittable(moveEarlier)
        XCTAssertTrue(moveEarlier.isEnabled)

        let remove = app.buttons[
            "instruction-package-remove-\(fixture.instructionPackageID)"
        ]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        makeHittable(remove)
        XCTAssertTrue(remove.isEnabled)
        XCTAssertEqual(remove.label, "Delete Package")
        remove.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.instructionQueueRemoveRequestCount == 1
                && fixture.instructionPackageIDs == [fixture.secondInstructionPackageID]
        })
        let removeRefreshBaseline = fixture.instructionQueueStatusRequestCount
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.instructionQueueStatusRequestCount > removeRefreshBaseline
        })
        XCTAssertFalse(app.buttons["instruction-package-remove-\(fixture.instructionPackageID)"].exists)
    }

    func testNormalWindowKeepsEveryPrimaryViewContainedAndAligned() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        resizeMainWindowForWideGrid(window)

        try assertEveryPrimaryViewContainedAndAligned(in: window)
    }

    func testGraphiteGuidedHelpAdvancedDisclosureOpensAndCloses() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        app.buttons["tab-projects"].click()
        openCurrentGuideFromMenu()
        let help = app.descendants(matching: .any)["guided-help-sheet"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        let advanced = help.disclosureTriangles["guided-help-advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForToggleState(false, on: advanced, timeout: 3))
        makeHittable(advanced)
        captureGraphite("contextual-help-disclosure-before")
        expandGraphiteDisclosure(advanced)
        captureGraphite("contextual-help-disclosure-after")
        makeHittable(advanced)
        advanced.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 26, dy: 8)).click()
        XCTAssertTrue(waitForToggleState(false, on: advanced, timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(help.waitForNonExistence(timeout: 3))
    }

    func testWorkbenchHeaderKeepsGuidedSetupAtNormalSizeOnRightAndPreservesControls() throws {
        try showWorkbenchControls(["navigation", "autoRefresh", "guidedMode", "guide", "refresh", "guidedSetup"])
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)
        for size in ["normal", "minimum"] {
            if size == "minimum" { resizeMainWindowToMinimum(window) }
            assertGraphiteGlobalHeader(in: window, expectsAllControls: true)
            captureGraphite("global-controls-\(size)")
            let setup = app.buttons["dashboard-guided-setup"]
            setup.click()
            XCTAssertTrue(app.descendants(matching: .any)["setup-guide"].waitForExistence(timeout: 5))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 3))
        }
        XCTAssertEqual(fixture.startRequestCount, 0)
        XCTAssertEqual(fixture.controlRequestCount, 0)
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 0)
    }

    func testComputeCoresPausedNativeProjectionRemainsStableAtBothWindowSizes() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let window = app.windows["forge-main-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)
        app.buttons["tab-rig"].click()
        let initialDetail = try XCTUnwrap(selectedDetailContainer(named: "Dashboard"))
        _ = try requireNativeComputeProjection(in: initialDetail, window: window)
        let settings = openWorkbenchSettings()
        let automatic = settings.checkBoxes["settings-auto-refresh"]
        XCTAssertTrue(waitForToggleState(true, on: automatic, timeout: 3))
        app.typeKey("w", modifierFlags: .command)
        app.menuBars.menuBarItems["Telemetry"].click()
        let automaticMenu = app.menuItems["Auto-refresh"]
        XCTAssertTrue(automaticMenu.waitForExistence(timeout: 3))
        automaticMenu.click()
        _ = openWorkbenchSettings()
        XCTAssertTrue(waitForToggleState(false, on: automatic, timeout: 3),
                      "The native Telemetry command must pause delivered host telemetry and chip motion")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 3))

        for size in ["normal", "minimum"] {
            if size == "minimum" { resizeMainWindowToMinimum(window) }
            app.buttons["tab-rig"].click()
            let detail = try XCTUnwrap(selectedDetailContainer(named: "Dashboard"))
            let projection = try requireNativeComputeProjection(in: detail, window: window)
            let cpuState = projection.compute.staticTexts["compute-cpu-activity-state"]
            let gpuState = projection.compute.staticTexts["compute-gpu-activity-state"]
            let renderer = projection.compute.staticTexts["compute-renderer-status"]
            XCTAssertTrue(waitUntil(timeout: 5) {
                self.computeSemanticText(cpuState) == "Paused" && self.computeSemanticText(gpuState) == "Paused"
                    && self.computeSemanticText(renderer) == "Metal · paused"
            })
            var priorPixels: Data?
            var priorSemantics: [String]?
            for capture in 1...2 {
                // The second frame crosses the normal3s freshness boundary. An intentional
                // pause must retain its source/shading and remain distinct from stale data.
                RunLoop.current.run(until: Date().addingTimeInterval(capture == 1 ? 0.8 : 3.2))
                let semantics = [cpuState, gpuState, renderer,
                                 projection.compute.staticTexts["compute-cpu-hardware-name"],
                                 projection.compute.staticTexts["compute-gpu-hardware-name"],
                                 projection.compute.staticTexts["compute-activity-provenance"]].map(computeSemanticText)
                let screenshot = window.screenshot()
                let name = "compute-paused-native-\(size)-\(capture)"
                retainComputeScreenshot(screenshot, name: name)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
                let readback = try computeSurfacePixelReadback(bitmap: bitmap, window: window.frame,
                                                              surface: projection.surface.frame)
                let receipt = XCTAttachment(string: "window=\(NSStringFromRect(window.frame)); surface=\(NSStringFromRect(projection.surface.frame)); png=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)\n\(readback.receipt)\nsemantics=\(semantics)")
                receipt.name = "\(name)-pixel-readback"
                receipt.lifetime = .keepAlways
                add(receipt)
                if let priorPixels { XCTAssertEqual(readback.pixels, priorPixels, "Every settled paused chip pixel must remain unchanged") }
                if let priorSemantics { XCTAssertEqual(semantics, priorSemantics) }
                priorPixels = readback.pixels
                priorSemantics = semantics
                XCTAssertEqual(semantics[0], "Paused")
                XCTAssertEqual(semantics[1], "Paused")
                XCTAssertEqual(semantics[2], "Metal · paused")
            }
        }
        assertComputeHasNoUnrequestedManagerWrites(fixture)
    }

    func testComputeCoresNativeHostIdentityGeometryAndMetalMotionFrames() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let window = app.windows["forge-main-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)
        let settings = openWorkbenchSettings()
        XCTAssertTrue(waitForToggleState(true, on: settings.checkBoxes["settings-auto-refresh"], timeout: 3))
        app.typeKey("w", modifierFlags: .command)
        app.buttons["tab-rig"].click()
        let detail = try XCTUnwrap(selectedDetailContainer(named: "Dashboard"))
        let projection = try requireNativeComputeProjection(in: detail, window: window)
        let renderer = projection.compute.staticTexts["compute-renderer-status"]
        XCTAssertTrue(waitUntil(timeout: 5) { self.computeSemanticText(renderer) == "Metal · simulated trace flow" })
        captureGraphite("compute-metal-motion-normal-before")
        let started = ProcessInfo.processInfo.systemUptime
        var rows: [[String: Any]] = []
        for index in 1...20 {
            let before = ProcessInfo.processInfo.systemUptime
            let screenshot = window.screenshot()
            let after = ProcessInfo.processInfo.systemUptime
            let name = String(format: "compute-metal-motion-frame-%03d", index)
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            rows.append(["frame": index, "attachment": name, "capture_start_uptime": before,
                         "capture_end_uptime": after, "elapsed_start": before - started,
                         "elapsed_end": after - started, "window": NSStringFromRect(window.frame),
                         "surface": NSStringFromRect(projection.surface.frame)])
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let receipt = XCTAttachment(data: try JSONSerialization.data(withJSONObject: [
            "kind": "actual unmodified native window screenshots; no interpolated frames",
            "auto_refresh": true, "elapsed_seconds": elapsed, "frames": rows,
            "cpu_identity": computeSemanticText(projection.compute.staticTexts["compute-cpu-hardware-name"]),
            "gpu_identity": computeSemanticText(projection.compute.staticTexts["compute-gpu-hardware-name"])
        ], options: [.sortedKeys, .prettyPrinted]), uniformTypeIdentifier: "public.json")
        receipt.name = "compute-metal-motion-frame-times"
        receipt.lifetime = .keepAlways
        add(receipt)
        XCTAssertEqual(rows.count, 20)
        XCTAssertGreaterThanOrEqual(elapsed, 6)
        XCTAssertLessThan(elapsed, 30, "Native motion acquisition must remain bounded")
        XCTAssertEqual(computeSemanticText(renderer), "Metal · simulated trace flow")
        captureGraphite("compute-metal-motion-normal-after")
        resizeMainWindowToMinimum(window)
        _ = try requireNativeComputeProjection(in: detail, window: window)
        captureGraphite("compute-metal-motion-minimum")
        assertComputeHasNoUnrequestedManagerWrites(fixture)
    }

    private func requireNativeComputeProjection(in detail: XCUIElement, window: XCUIElement) throws
        -> (compute: XCUIElement, surface: XCUIElement) {
        let compute = detail.descendants(matching: .any)["rig-compute-cores-panel"]
        XCTAssertTrue(compute.waitForExistence(timeout: 5))
        makeHittable(compute, in: detail)
        XCTAssertTrue(frameIsContained(compute.frame, in: detail.frame, tolerance: 2))
        XCTAssertTrue(frameIsContained(compute.frame, in: window.frame, tolerance: 2))
        let cpu = compute.descendants(matching: .any)["rig-cpu-cores-panel"]
        let gpu = compute.descendants(matching: .any)["rig-gpu-cores-panel"]
        let surface = compute.descendants(matching: .any)["compute-render-surface"]
        for panel in [cpu, gpu, surface] {
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            XCTAssertTrue(frameIsContained(panel.frame, in: compute.frame, tolerance: 2))
            XCTAssertTrue(frameIsContained(panel.frame, in: window.frame, tolerance: 2))
            XCTAssertGreaterThan(panel.frame.width, 0)
            XCTAssertGreaterThan(panel.frame.height, 0)
        }
        XCTAssertFalse(cpu.frame.intersects(gpu.frame), "The independent chip panels must never overlap")
        let cpuName = compute.staticTexts["compute-cpu-hardware-name"]
        let gpuName = compute.staticTexts["compute-gpu-hardware-name"]
        let expectedCPU = observedComputeHostCPUName()
        XCTAssertTrue(waitUntil(timeout: 5) { self.computeSemanticText(cpuName) == expectedCPU })
        let observedGPUDevices = MTLCopyAllDevices().map(\.name)
        XCTAssertTrue(waitUntil(timeout: 5) {
            let name = self.computeSemanticText(gpuName)
            return observedGPUDevices.isEmpty ? name == "GPU identity unavailable" : observedGPUDevices.contains(name)
        })
        XCTAssertTrue(frameIsContained(cpuName.frame, in: cpu.frame, tolerance: 2))
        XCTAssertTrue(frameIsContained(gpuName.frame, in: gpu.frame, tolerance: 2))
        let provenance = compute.staticTexts["compute-activity-provenance"]
        XCTAssertTrue(provenance.exists)
        XCTAssertTrue(computeSemanticText(provenance).contains("GPU regions illustrative"))
        XCTAssertTrue(computeSemanticText(provenance).contains("Trace flow simulated"))
        // Existing gauges elsewhere retain their own measured values. The revised
        // component intentionally has chip regions rather than the old mini-bars.
        for engine in ["device", "render", "tiler"] {
            XCTAssertFalse(compute.descendants(matching: .any)["rig-gpu-engine-\(engine)"].exists)
        }
        return (compute, surface)
    }

    private func observedComputeHostCPUName() -> String {
        func observedString(_ key: String) -> String? {
            var size = 0
            guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 1, size <= 4_096 else { return nil }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return nil }
            return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let name = (observedString("machdep.cpu.brand_string") ?? observedString("hw.model") ?? "CPU")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "CPU identity unavailable" : name
    }

    private func computeSemanticText(_ element: XCUIElement) -> String {
        (element.value as? String) ?? element.label
    }

    private func retainComputeScreenshot(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let semantics = XCTAttachment(string: app.debugDescription)
        semantics.name = "\(name)-accessibility"
        semantics.lifetime = .keepAlways
        add(semantics)
    }

    private func computeSurfacePixelReadback(bitmap: NSBitmapImageRep, window: CGRect, surface: CGRect) throws
        -> (pixels: Data, receipt: String) {
        let scaleX = Double(bitmap.pixelsWide) / Double(window.width)
        let scaleY = Double(bitmap.pixelsHigh) / Double(window.height)
        XCTAssertEqual(scaleX, scaleY, accuracy: 0.02)
        let interior = surface.insetBy(dx: 2, dy: 2)
        let minX = Int((Double(interior.minX - window.minX) * scaleX).rounded(.up))
        let maxX = Int((Double(interior.maxX - window.minX) * scaleX).rounded(.down))
        let minY = Int((Double(interior.minY - window.minY) * scaleY).rounded(.up))
        let maxY = Int((Double(interior.maxY - window.minY) * scaleY).rounded(.down))
        XCTAssertGreaterThan(maxX - minX, 100)
        XCTAssertGreaterThan(maxY - minY, 100)
        XCTAssertGreaterThanOrEqual(minX, 0)
        XCTAssertGreaterThanOrEqual(minY, 0)
        XCTAssertLessThanOrEqual(maxX, bitmap.pixelsWide)
        XCTAssertLessThanOrEqual(maxY, bitmap.pixelsHigh)
        var result = Data()
        result.reserveCapacity((maxX - minX) * (maxY - minY) * 3)
        for y in minY..<maxY {
            for x in minX..<maxX {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                result.append(UInt8((min(max(color.redComponent, 0), 1) * 255).rounded()))
                result.append(UInt8((min(max(color.greenComponent, 0), 1) * 255).rounded()))
                result.append(UInt8((min(max(color.blueComponent, 0), 1) * 255).rounded()))
            }
        }
        return (result, "scale=\(scaleX),\(scaleY); actual_surface_scan_rectangle=(\(minX)..<\(maxX),\(minY)..<\(maxY)); RGB_bytes=\(result.count)")
    }

    private func assertComputeHasNoUnrequestedManagerWrites(_ fixture: OperatorManagerUITestFixture) {
        XCTAssertEqual(fixture.settingsUpdateCount, 0)
        XCTAssertEqual(fixture.startRequestCount, 0)
        XCTAssertEqual(fixture.controlRequestCount, 0)
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 0)
    }

    func testGraphiteToolsColumnsAlignWithNativeRowsAtBothWindowSizes() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let window = app.windows["forge-main-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)
        for size in ["normal", "minimum"] {
            if size == "minimum" { resizeMainWindowToMinimum(window) }
            app.buttons["tab-tools"].click()
            let detail = try XCTUnwrap(selectedDetailContainer(named: "Tools"))
            assertGraphiteGlobalHeader(in: window)
            XCTAssertTrue(detail.textFields["tool-filter"].isHittable)
            let columns = ["name", "state", "health", "activity"]
            let headers = columns.map { detail.staticTexts["tools-column-\($0)"] }
            let values = columns.map { detail.staticTexts["tools-row-\($0)-agent_context"] }
            for element in headers + values {
                XCTAssertTrue(element.waitForExistence(timeout: 5))
                XCTAssertGreaterThan(element.frame.width, 0)
                XCTAssertGreaterThan(element.frame.height, 0)
                XCTAssertTrue(frameIsContained(element.frame, in: detail.frame, tolerance: 2))
                XCTAssertTrue(frameIsContained(element.frame, in: window.frame, tolerance: 2))
            }
            XCTAssertTrue(element(values[0], contains: "agent_context"))
            XCTAssertTrue(element(values[1], contains: "idle"))
            XCTAssertTrue(element(values[2], contains: "READY"))
            let scrollQuery = detail.scrollViews.containing(.staticText, identifier: "tools-row-name-agent_context")
            XCTAssertEqual(scrollQuery.count, 1)
            XCTAssertTrue(frameIsContained(scrollQuery.element.frame, in: detail.frame, tolerance: 2))
            for value in values {
                XCTAssertTrue(frameIsContained(value.frame, in: scrollQuery.element.frame, tolerance: 2))
            }
            let aligned = waitUntil(timeout: 5) {
                abs(headers[0].frame.minX - values[0].frame.minX) <= 2
                    && abs(headers[1].frame.minX - values[1].frame.minX) <= 2
                    && abs(headers[2].frame.minX - values[2].frame.minX) <= 2
                    && abs(headers[3].frame.maxX - values[3].frame.maxX) <= 2
            }
            captureGraphite("tools-column-alignment-\(size)")
            XCTAssertTrue(aligned, "Native column headings must align with the displayed row at \(size) width")
            for index in 0..<3 {
                XCTAssertEqual(headers[index].frame.minX, values[index].frame.minX, accuracy: 2)
            }
            XCTAssertEqual(headers[3].frame.maxX, values[3].frame.maxX, accuracy: 2)
        }
        XCTAssertEqual(fixture.settingsUpdateCount, 0)
        XCTAssertEqual(fixture.startRequestCount, 0)
        XCTAssertEqual(fixture.controlRequestCount, 0)
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 0)
    }

    func testGraphiteNativeSettingsCapturesEverySectionAtMinimumSize() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let mainWindow = app.windows["forge-main-window"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 8))
        assertGraphiteGlobalHeader(in: mainWindow)
        let settings = openWorkbenchSettings()
        let handle = settings.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        handle.click(forDuration: 0.2, thenDragTo: handle.withOffset(CGVector(dx: -800, dy: 0)))
        captureGraphite("settings-minimum-after-drag")
        XCTAssertTrue(waitUntil(timeout: 3) {
            abs(settings.frame.width - 760) <= 3 && abs(settings.frame.height - 592) <= 3
        }, "Native Settings must reach its 760 × 560 content minimum plus the measured 32-point title bar")
        XCTAssertEqual(settings.frame.width, 760, accuracy: 3)
        XCTAssertEqual(settings.frame.height, 592, accuracy: 3)

        let sections = [
            ("workbench", "Workbench"), ("folders", "Authorized Folders"),
            ("service", "Service"), ("runtime", "Runtime"), ("settings", "Settings"),
            ("shell", "Project Shell"), ("filesystem", "Protected Filesystem"),
            ("maintenance", "Maintenance"), ("doctor", "Doctor"),
        ]
        for (identifier, title) in sections {
            selectManagerSection(identifier)
            let heading = settings.groups["detail-manager"].staticTexts.matching(
                NSPredicate(format: "label == %@ OR value == %@", title, title)
            )
            XCTAssertTrue(heading.element.waitForExistence(timeout: 3))
            XCTAssertEqual(heading.count, 1)
            XCTAssertTrue(frameIsContained(heading.element.frame, in: settings.frame, tolerance: 2))
            let body = try XCTUnwrap(settings.scrollViews.allElementsBoundByIndex
                .filter { $0.exists && $0.frame.width > 300 }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            body.scroll(byDeltaX: 0, deltaY: 1_200)
            captureGraphite("settings-minimum-\(identifier)")

            let lowerAnchor: XCUIElement?
            switch identifier {
            case "workbench":
                let navigation = settings.checkBoxes["settings-navigation-visible"]
                XCTAssertTrue(navigation.isHittable)
                lowerAnchor = settings.checkBoxes["settings-control-guidedSetup"]
            case "folders":
                let addFolder = settings.buttons["settings-allowed-root-add"]
                XCTAssertTrue(waitForEnabled(addFolder, timeout: 5))
                XCTAssertTrue(addFolder.isHittable)
                lowerAnchor = nil
            case "service":
                for action in ["Start", "Stop", "Restart"] {
                    XCTAssertTrue(settings.buttons[action].isHittable)
                }
                lowerAnchor = nil
            case "settings":
                XCTAssertTrue(waitForValue("127.0.0.1", on: settings.textFields["Dashboard host"]))
                lowerAnchor = settings.textFields["Session idle TTL (sec)"]
            case "shell":
                XCTAssertTrue(settings.descendants(matching: .any)["settings-shell-enabled"].isHittable)
                lowerAnchor = settings.descendants(matching: .any)["shell-policy-migration-status"]
            case "filesystem":
                XCTAssertTrue(settings.descendants(matching: .any)["settings-filesystem-service-status"].exists)
                lowerAnchor = settings.buttons["settings-filesystem-service-refresh"]
            case "maintenance":
                for action in ["Refresh telemetry now", "Prune stale presence", "Prune idle sessions", "Run doctor"] {
                    XCTAssertTrue(settings.buttons[action].isHittable)
                }
                lowerAnchor = nil
            case "doctor":
                XCTAssertTrue(settings.staticTexts["Health checks"].exists)
                XCTAssertTrue(settings.buttons["Run doctor"].isHittable)
                lowerAnchor = nil
            default:
                XCTAssertTrue(settings.staticTexts["App version"].exists)
                lowerAnchor = nil
            }
            if let lowerAnchor {
                XCTAssertTrue(lowerAnchor.waitForExistence(timeout: 5))
                makeHittable(lowerAnchor, in: settings)
                XCTAssertTrue(frameIsContained(lowerAnchor.frame, in: settings.frame, tolerance: 2))
                captureGraphite("settings-minimum-\(identifier)-lower")
            }
            if ["folders", "settings", "shell"].contains(identifier) {
                for action in ["settings-reload", "settings-save"] {
                    XCTAssertTrue(settings.buttons[action].isHittable)
                    XCTAssertTrue(frameIsContained(settings.buttons[action].frame, in: settings.frame, tolerance: 2))
                }
            }
        }
        XCTAssertEqual(fixture.settingsUpdateCount, 0)
        XCTAssertEqual(fixture.startRequestCount, 0)
        XCTAssertEqual(fixture.controlRequestCount, 0)
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertEqual(fixture.providerPreparationCount, 0)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 0)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 3))
    }

    func testGraphiteWorkbenchCapturesEveryCurrentView() throws {
        let fixture = try OperatorManagerUITestFixture(includeContinuityOperation: true)
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)
        try captureGraphitePrimaryViews(in: window, size: "normal")
        resizeMainWindowToMinimum(window)
        try captureGraphitePrimaryViews(in: window, size: "minimum")
        try resizeMainWindowForGraphiteReference(window)
        app.buttons["tab-manager"].click()
        for section in ["folders", "service", "runtime", "settings", "shell", "filesystem", "maintenance", "doctor", "workbench"] {
            selectManagerSection(section)
            captureGraphite("manager-\(section)")
        }
    }

    func testGraphiteDashboardLowerPanelsRemainVisibleAtBothWindowSizes() throws {
        let fixture = try OperatorManagerUITestFixture(includeContinuityOperation: true)
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)
        XCTAssertEqual(app.launchEnvironment["FORGE_SKIP_PS"], "1")
        let rows: [(name: String, panels: [(identifier: String, heading: String)])] = [
            ("mcp-presence-tools", [
                ("rig-mcp-servers-panel", "MCP SERVERS"),
                ("rig-mcp-tools-panel", "MCP TOOLS"),
            ]),
            ("sub-agents-hot-processes", [
                ("rig-sub-agents-panel", "SUB-AGENTS"),
                ("rig-hot-processes-panel", "HOT PROCESSES"),
            ]),
            ("live-stream", [
                ("rig-live-stream-panel", "LIVE STREAM ▮ TOOLS · AGENTS · DIAGNOSTICS"),
            ]),
        ]

        func captureLowerPanels(size: String) throws {
            app.buttons["tab-rig"].click()
            let detail = try XCTUnwrap(selectedDetailContainer(named: "Dashboard"))
            XCTAssertEqual(detail.elementType, .scrollView)
            assertGraphiteGlobalHeader(in: window)
            for row in rows {
                var panels: [XCUIElement] = []
                var headings: [XCUIElement] = []
                for definition in row.panels {
                    let matches = detail.groups.matching(identifier: definition.identifier)
                    XCTAssertEqual(matches.count, 1)
                    let panel = matches.element
                    XCTAssertTrue(panel.waitForExistence(timeout: 5))
                    let headingMatches = panel.staticTexts.matching(NSPredicate(
                        format: "label == %@ OR value == %@", definition.heading, definition.heading
                    ))
                    XCTAssertEqual(headingMatches.count, 1)
                    let heading = headingMatches.element
                    XCTAssertTrue(heading.exists)
                    panels.append(panel)
                    headings.append(heading)
                }
                makeHittable(try XCTUnwrap(headings.first))
                for _ in 0..<12 {
                    let bounds = panels.reduce(CGRect.null) { $0.union($1.frame) }
                    if frameIsContained(bounds, in: detail.frame, tolerance: 2) { break }
                    let distance = bounds.midY - detail.frame.midY
                    detail.scroll(byDeltaX: 0, deltaY: -min(360, max(-360, distance)))
                }
                captureGraphite("\(size)-dashboard-\(row.name)")
                for (panel, heading) in zip(panels, headings) {
                    XCTAssertGreaterThan(panel.frame.width, 100)
                    XCTAssertGreaterThan(panel.frame.height, 30)
                    XCTAssertTrue(frameIsContained(panel.frame, in: detail.frame, tolerance: 2),
                                  "The complete \(heading.value ?? heading.label) panel must be visible")
                    XCTAssertTrue(heading.isHittable)
                    XCTAssertTrue(frameIsContained(heading.frame, in: panel.frame, tolerance: 2))
                }
                if row.name == "mcp-presence-tools" {
                    let servers = detail.groups["rig-mcp-servers-panel"]
                    let identityFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
                    for expected in ["forge-conductor", "forge-conductor-clu", "forge-conductor-fallback"] {
                        let matches = servers.staticTexts.matching(NSPredicate(
                            format: "label == %@ OR value == %@", expected, expected
                        ))
                        XCTAssertEqual(matches.count, 1, "Each configured MCP server needs a distinct full identity")
                        let identity = matches.element
                        XCTAssertTrue(identity.exists)
                        XCTAssertTrue(identity.isHittable)
                        XCTAssertTrue(frameIsContained(identity.frame, in: servers.frame, tolerance: 2))
                        XCTAssertTrue(frameIsContained(identity.frame, in: detail.frame, tolerance: 2))
                        let requiredBounds = (expected as NSString).boundingRect(
                            with: CGSize(width: identity.frame.width, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                            attributes: [.font: identityFont]
                        )
                        XCTAssertLessThanOrEqual(requiredBounds.height, identity.frame.height + 2,
                                                 "The full \(expected) identity must fit without ellipsis")
                    }
                } else if row.name == "sub-agents-hot-processes" {
                    let processes = detail.groups["rig-hot-processes-panel"]
                    let empty = processes.staticTexts["NO MATCHING PROCESSES"]
                    if empty.exists {
                        XCTAssertTrue(empty.isHittable)
                        XCTAssertTrue(frameIsContained(empty.frame, in: processes.frame, tolerance: 2))
                    } else {
                        // ProcessDiscovery's skip flag does not suppress the separate libproc metrics collector.
                        for label in ["PID", "NAME", "CPU", "RSS"] {
                            let column = processes.staticTexts[label]
                            XCTAssertTrue(column.exists)
                            XCTAssertTrue(frameIsContained(column.frame, in: processes.frame, tolerance: 2))
                        }
                    }
                }
            }
        }

        try captureLowerPanels(size: "normal")
        resizeMainWindowToMinimum(window)
        try captureLowerPanels(size: "minimum")
        XCTAssertEqual(fixture.startRequestCount, 0)
        XCTAssertEqual(fixture.controlRequestCount, 0)
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertEqual(fixture.providerPreparationCount, 0)
        XCTAssertEqual(fixture.providerConfigurationSaveCount, 0)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 0)
    }

    func testGraphiteWorkbenchCapturesSupportingPresentations() throws {
        let fixture = try OperatorManagerUITestFixture(includeContinuityOperation: true)
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)

        app.buttons["tab-provider"].click()
        for provider in ["lmstudio", "claude-desktop", "codex-desktop", "grok-build"] {
            inspectProvider(provider)
            captureGraphite("provider-\(provider)")
        }
        inspectProvider("lmstudio")
        let providerAdvanced = app.buttons["provider-advanced-toggle"]
        makeHittable(providerAdvanced)
        providerAdvanced.click()
        XCTAssertTrue(app.textFields["provider-endpoint"].waitForExistence(timeout: 5))
        captureGraphite("provider-advanced")

        app.buttons["tab-runtimes"].click()
        let runtimeAdvanced = app.buttons["runtime-advanced-toggle"]
        XCTAssertTrue(runtimeAdvanced.waitForExistence(timeout: 5))
        makeHittable(runtimeAdvanced)
        runtimeAdvanced.click()
        let shell = app.descendants(matching: .any)["runtime-shell-enabled"]
        XCTAssertTrue(shell.waitForExistence(timeout: 5))
        makeHittable(shell)
        captureGraphite("runtimes-advanced")
        for (identifier, name) in [
            ("runtime-capabilities-panel", "runtimes-capabilities"),
            ("runtime-execution-limits", "runtimes-execution-limits")
        ] {
            let panel = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(panel.waitForExistence(timeout: 3))
            makeHittable(panel)
            XCTAssertTrue(frameIsContained(panel.frame, in: app.windows.firstMatch.frame, tolerance: 2))
            if identifier == "runtime-capabilities-panel" {
                for runtime in ["direct", "zsh", "bash", "python", "powershell"] {
                    let row = panel.descendants(matching: .any)["runtime-capability-\(runtime)"]
                    XCTAssertTrue(row.exists)
                    XCTAssertTrue(frameIsContained(row.frame, in: panel.frame, tolerance: 2))
                }
            }
            captureGraphite(name)
        }

        app.buttons["tab-rune-forge"].click()
        let feed = app.descendants(matching: .any)["rune-policy-feed-route"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        feed.click()
        XCTAssertTrue(app.descendants(matching: .any)["rune-policy-event-\(fixture.policyEventID)"].waitForExistence(timeout: 5))
        captureGraphite("rune-policy-feed")

        app.buttons["tab-projects"].click()
        let registration = app.buttons["project-register-by-path"]
        XCTAssertTrue(registration.waitForExistence(timeout: 5))
        registration.click()
        let path = app.textFields["project-register-path"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.click()
        path.typeText("relative-path")
        let name = app.textFields["project-register-name"]
        name.click()
        name.typeText("Readable project name")
        let registrationSheet = app.sheets.firstMatch
        for label in ["Project folder (absolute path)", "Display name (optional)"] {
            let persistentLabel = registrationSheet.staticTexts[label]
            XCTAssertTrue(persistentLabel.exists, "Registration field labels must survive text entry")
            XCTAssertTrue(frameIsContained(persistentLabel.frame, in: registrationSheet.frame, tolerance: 2))
        }
        XCTAssertFalse(app.buttons["project-register-confirm"].isEnabled)
        captureGraphite("project-registration-validation")
        let registrationGuide = app.buttons["guided-help-projectRegistration"]
        XCTAssertTrue(registrationGuide.exists)
        registrationGuide.click()
        let nestedGuide = app.descendants(matching: .any)["guided-help-sheet"]
        XCTAssertTrue(nestedGuide.waitForExistence(timeout: 5))
        app.buttons["guided-help-close"].click()
        XCTAssertTrue(nestedGuide.waitForNonExistence(timeout: 3))
        XCTAssertTrue(path.exists, "Closing registration Help must preserve the registration dialog")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(path.waitForNonExistence(timeout: 3))

        openCurrentGuideFromMenu()
        let help = app.descendants(matching: .any)["guided-help-sheet"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        captureGraphite("contextual-help")
        let advancedHelp = app.disclosureTriangles["guided-help-advanced"]
        XCTAssertTrue(advancedHelp.waitForExistence(timeout: 3))
        expandGraphiteDisclosure(advancedHelp)
        captureGraphite("contextual-help-advanced")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(help.waitForNonExistence(timeout: 3))

        app.buttons["tab-rig"].click()
        openGuidedSetupFromMenu()
        let wizard = app.descendants(matching: .any)["setup-guide"]
        XCTAssertTrue(wizard.waitForExistence(timeout: 5))
        for step in 1...8 {
            let stepButton = app.buttons["guided-setup-step-\(step)"]
            XCTAssertTrue(stepButton.waitForExistence(timeout: 3))
            makeHittable(stepButton)
            stepButton.click()
            if [3, 5].contains(step) { try makeGraphiteSetupReviewScopeVisible() }
            captureGraphite("guided-setup-step-\(step)")
            let lowerDestination = [2: "provider", 3: "projects", 5: "projects", 6: "provider", 8: "evidence"][step]
            if let lowerDestination {
                let action = app.buttons["setup-guide-open-\(lowerDestination)"]
                XCTAssertTrue(action.waitForExistence(timeout: 3))
                makeHittable(action)
                XCTAssertTrue(frameIsContained(action.frame, in: app.sheets.firstMatch.frame, tolerance: 2))
                captureGraphite("guided-setup-step-\(step)-lower")
            }
        }
        app.buttons["guided-setup-close"].click()
        XCTAssertTrue(wizard.waitForNonExistence(timeout: 3))

        app.typeKey(",", modifierFlags: .command)
        for section in ["folders", "service", "runtime", "settings", "shell", "filesystem", "maintenance", "doctor"] {
            selectManagerSection(section)
            captureGraphite("settings-\(section)")
        }
        app.typeKey("w", modifierFlags: .command)
    }

    func testGuidedSetupStepTransitionsResetScrollAndPreserveProgress() throws {
        let fixture = try OperatorManagerUITestFixture(
            initialRunState: "completed",
            initialProviderHealth: "contract_valid"
        )
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)
        openGuidedSetupFromMenu()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let steps: [(title: String, purpose: String, destination: String)] = [
            (
                "Confirm Forge is ready",
                "The manager owns projects, provider configuration, automation, continuity, and durable recovery.",
                "manager"
            ),
            (
                "Connect the model provider",
                "Forge needs one reachable, tool-capable model for ordinary LM Studio chats to use its tools.",
                "provider"
            ),
            (
                "Register the project",
                "A registered project gives LM Studio a stable identity and an exact default working folder.",
                "projects"
            ),
            (
                "Add and order instructions",
                "Instruction packages define the work, allowed capabilities, completion requirements, and execution order.",
                "projects"
            ),
            (
                "Review project inputs",
                "Before starting in LM Studio, confirm the provider, project folders, instruction order, and Development Policy priority.",
                "projects"
            ),
            (
                "Start in LM Studio",
                "Project work begins in the LM Studio chat interface, where you interact with the model normally.",
                "provider"
            ),
            (
                "Monitor governance and continuity",
                "Continue working in LM Studio while Forge enforces Development Policy and protects session continuity.",
                "continuity"
            ),
            (
                "Resolve issues and continue",
                "Forge preserves durable state and routes each issue to the view that owns the corrective action.",
                "evidence"
            ),
        ]

        func assertTop(of step: Int, capture: String) throws {
            let expected = steps[step - 1]
            let title = sheet.staticTexts["guided-setup-step-title"]
            XCTAssertTrue(waitUntil(timeout: 5) { self.element(title, contains: expected.title) })
            let scrollViews = sheet.scrollViews.containing(
                .staticText, identifier: "guided-setup-step-title"
            )
            XCTAssertEqual(scrollViews.count, 1)
            let content = scrollViews.element
            XCTAssertTrue(content.exists)
            let indicator = content.staticTexts["STEP \(step) OF 8"]
            XCTAssertTrue(indicator.exists)
            let purpose = content.staticTexts.matching(NSPredicate(
                format: "label == %@ OR value == %@", expected.purpose, expected.purpose
            )).element
            XCTAssertTrue(purpose.exists)
            for heading in [indicator, title, purpose] {
                XCTAssertTrue(heading.isHittable, "New step \(step) must expose its complete introduction")
                XCTAssertTrue(frameIsContained(heading.frame, in: content.frame, tolerance: 2))
            }
            XCTAssertLessThan(title.frame.minY, content.frame.minY + 80,
                              "Changing steps must return the detail viewport to its introduction")
            let footer = sheet.staticTexts[
                "Step \(step) of 8 · Progress is saved when you leave the wizard"
            ]
            XCTAssertTrue(footer.exists)
            XCTAssertTrue(frameIsContained(footer.frame, in: sheet.frame, tolerance: 2))
            XCTAssertGreaterThanOrEqual(footer.frame.minY, content.frame.maxY - 2)
            XCTAssertTrue(sheet.buttons["guided-setup-close"].isHittable)
            captureGraphite(capture)
        }

        for step in 1...8 {
            try assertTop(of: step, capture: "guided-setup-transition-step-\(step)-top")
            let destination = sheet.buttons["setup-guide-open-\(steps[step - 1].destination)"]
            XCTAssertTrue(destination.waitForExistence(timeout: 3))
            makeHittable(destination)
            XCTAssertTrue(destination.isHittable)
            if (2...5).contains(step) {
                let content = sheet.scrollViews.containing(
                    .staticText, identifier: "guided-setup-step-title"
                ).element
                XCTAssertFalse(frameIsContained(
                    sheet.staticTexts["guided-setup-step-title"].frame,
                    in: content.frame, tolerance: 2
                ), "The regression must start from an actually scrolled detail viewport")
            }
            if step < 8 {
                let next = sheet.buttons[step == 5 ? "setup-guide-confirm-review" : "setup-guide-next"]
                XCTAssertTrue(waitForEnabled(next, timeout: 5))
                XCTAssertTrue(next.isHittable)
                next.click()
            }
        }

        sheet.buttons["Back"].click()
        try assertTop(of: 7, capture: "guided-setup-transition-back-top")
        let lower = sheet.buttons["setup-guide-open-continuity"]
        makeHittable(lower)
        sheet.buttons["guided-setup-step-8"].click()
        try assertTop(of: 8, capture: "guided-setup-transition-sidebar-top")
        sheet.buttons["guided-setup-close"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: try XCTUnwrap(guidedSetupDefaultsSuite)))
        XCTAssertEqual(defaults.integer(forKey: "forge.guidedSetup.step.v2"), 7)
        openGuidedSetupFromMenu()
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        try assertTop(of: 8, capture: "guided-setup-transition-reopened-top")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
        XCTAssertEqual(fixture.startRequestCount, 0)
        XCTAssertEqual(fixture.controlRequestCount, 0)
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertTrue(fixture.providerIntegrationMutationRecords.isEmpty)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 0)
    }

    func testGraphiteGuidedSetupProjectReviewScopeCapturesFullIdentity() throws {
        let fixture = try OperatorManagerUITestFixture(
            initialRunState: "completed",
            initialProviderHealth: "contract_valid"
        )
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)
        openGuidedSetupFromMenu()
        for step in [3, 5] {
            let selection = app.buttons["guided-setup-step-\(step)"]
            XCTAssertTrue(selection.waitForExistence(timeout: 3))
            selection.click()
            try makeGraphiteSetupReviewScopeVisible()
            let identity = app.staticTexts["guided-setup-review-project-identity"]
            XCTAssertTrue(element(identity, contains: fixture.projectID))
            XCTAssertTrue(element(identity, contains: "generation 4"))
            captureGraphite("guided-setup-project-review-step-\(step)")
        }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(fixture.startRequestCount, 0)
        XCTAssertEqual(fixture.controlRequestCount, 0)
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertTrue(fixture.providerIntegrationMutationRecords.isEmpty)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 0)
    }

    func testProviderInspectionDoesNotDispatchActivationDeploymentDeletionOrModels() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        app.buttons["tab-provider"].click()
        inspectProvider("lmstudio")
        let endpoint = app.otherElements["provider-readiness-endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.element(endpoint, contains: "http://127.0.0.1:1234")
        })
        let baseline = (
            selection: fixture.providerSelectionRequestCount,
            models: fixture.providerModelRequestCount,
            deletion: fixture.providerIntegrationDeletionRequestCount,
            preparation: fixture.providerPreparationCount,
            mutations: fixture.providerIntegrationMutationRecords.count,
            probes: fixture.providerProbeRecords.count,
            saves: fixture.providerConfigurationSaveCount
        )
        for provider in ["claude-desktop", "codex-desktop", "grok-build", "lmstudio"] {
            inspectProvider(provider)
            let toggle = app.descendants(matching: .any)["provider-toggle-\(provider)"]
            XCTAssertTrue(waitForToggleState(provider == "lmstudio", on: toggle))
        }
        XCTAssertEqual(fixture.providerSelectionRequestCount, baseline.selection)
        XCTAssertEqual(fixture.providerModelRequestCount, baseline.models)
        XCTAssertEqual(fixture.providerIntegrationDeletionRequestCount, baseline.deletion)
        XCTAssertEqual(fixture.providerPreparationCount, baseline.preparation)
        XCTAssertEqual(fixture.providerIntegrationMutationRecords.count, baseline.mutations)
        XCTAssertEqual(fixture.providerProbeRecords.count, baseline.probes)
        XCTAssertEqual(fixture.providerConfigurationSaveCount, baseline.saves)
    }

    func testProviderReadinessShowsConfigurationFallbackAndReportedEndpointWithoutDispatch() throws {
        let configurationEndpoint = "https://provider-fixture.example.invalid"
        let reportedEndpoint = "https://reported-provider.example.invalid"
        for reported in [nil, reportedEndpoint] as [String?] {
            let fixture = try OperatorManagerUITestFixture(
                providerEndpoint: configurationEndpoint,
                providerLinkedNodeID: UUID(uuidString: "78787878-7878-4787-8787-787878787878")!,
                reportedProviderEndpoint: reported
            )
            relaunch(with: fixture)
            app.buttons["tab-provider"].click()
            inspectProvider("lmstudio")
            let endpoint = app.otherElements["provider-readiness-endpoint"]
            XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
            XCTAssertTrue(waitUntil(timeout: 5) {
                self.element(endpoint, contains: reported ?? configurationEndpoint)
            })
            makeHittable(endpoint)
            captureGraphite(reported == nil
                ? "provider-readiness-linked-configuration-fallback"
                : "provider-readiness-reported-endpoint")
            XCTAssertEqual(fixture.providerPreparationCount, 0)
            XCTAssertEqual(fixture.providerConfigurationSaveCount, 0)
            XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
            XCTAssertEqual(fixture.providerModelRequestCount, 0)
            XCTAssertTrue(fixture.providerProbeRecords.isEmpty)
            XCTAssertTrue(fixture.providerIntegrationMutationRecords.isEmpty)
            XCTAssertEqual(fixture.mutationAuthorizationCount, 0)
        }
    }

    func testGraphiteWorkbenchCapturesConditionalDetailsAndCancelledDestructiveActions() throws {
        let fixture = try OperatorManagerUITestFixture(
            includeContinuityOperation: true,
            activeInstructionQueue: true,
            includeSecondInstructionPackage: true,
            includePolicyDetails: true,
            providerEndpoint: "https://provider-fixture.example.invalid",
            providerLinkedNodeID: UUID(uuidString: "78787878-7878-4787-8787-787878787878")!
        )
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)

        app.buttons["tab-projects"].click()
        let currentPackage = app.staticTexts["Current"]
        XCTAssertTrue(currentPackage.waitForExistence(timeout: 5))
        makeHittable(currentPackage)
        XCTAssertFalse(app.buttons["instruction-package-remove-\(fixture.instructionPackageID)"].isEnabled)
        captureGraphite("projects-current-instruction-package")
        captureGraphiteProjectCatalog(fixture: fixture, name: "projects-current-instruction-catalog")

        app.buttons["tab-rune-forge"].click()
        let baselineSource = app.buttons["rune-policy-source-row-66666666-6666-4666-8666-666666666666"]
        XCTAssertTrue(baselineSource.waitForExistence(timeout: 5))
        baselineSource.click()
        let removeSource = app.buttons["rune-policy-source-remove"]
        XCTAssertTrue(removeSource.waitForExistence(timeout: 5))
        XCTAssertFalse(removeSource.isEnabled, "The governing baseline must remain protected")
        captureGraphite("rune-governing-source")
        app.buttons["rune-policy-source-row-67676767-6767-4767-8767-676767676767"].click()
        XCTAssertTrue(app.staticTexts["Opaque instruction source"].waitForExistence(timeout: 5))
        captureGraphite("rune-partially-interpreted-source")
        let violation = app.buttons["rune-violation-row-77777777-7777-4777-8777-777777777777"]
        XCTAssertTrue(violation.waitForExistence(timeout: 5))
        violation.click()
        XCTAssertTrue(app.staticTexts["Violation identity and history"].waitForExistence(timeout: 5))
        captureGraphite("rune-violation-identity")
        let history = app.staticTexts["Occurrence history"]
        makeHittable(history)
        captureGraphite("rune-violation-evidence-and-history")

        app.buttons["tab-runtimes"].click()
        let job = app.descendants(matching: .any)["runtime-job-row-\(fixture.runtimeJobID)"]
        XCTAssertTrue(job.waitForExistence(timeout: 5))
        job.click()
        let technical = app.disclosureTriangles["runtime-job-technical-details"]
        XCTAssertTrue(technical.waitForExistence(timeout: 5))
        makeHittable(technical)
        captureGraphite("runtime-job-technical-disclosure-before")
        expandGraphiteDisclosure(technical)
        XCTAssertTrue(app.staticTexts[fixture.runtimeJobID].waitForExistence(timeout: 3))
        captureGraphite("runtime-job-technical-details")

        app.buttons["tab-evidence"].click()
        let event = app.descendants(matching: .any)["evidence-event-\(fixture.continuityEventID)"]
        XCTAssertTrue(event.waitForExistence(timeout: 5))
        let search = app.textFields["evidence-search"]
        search.click()
        search.typeText("no-matching-graphite-event")
        XCTAssertTrue(app.staticTexts["No Matching Events"].waitForExistence(timeout: 3))
        captureGraphite("evidence-no-match")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(event.waitForExistence(timeout: 3))

        app.buttons["tab-provider"].click()
        inspectProvider("lmstudio")
        let advanced = app.buttons["provider-advanced-toggle"]
        makeHittable(advanced)
        advanced.click()
        let credentials = app.descendants(matching: .any)["provider-credential-action"]
        XCTAssertTrue(credentials.waitForExistence(timeout: 5))
        makeHittable(credentials)
        credentials.click()
        let replace = app.menuItems["Replace credential"]
        XCTAssertTrue(replace.waitForExistence(timeout: 3))
        replace.click()
        let token = app.secureTextFields["provider-token"]
        XCTAssertTrue(token.waitForExistence(timeout: 3))
        makeHittable(token)
        token.click()
        token.typeText("fixture-token-for-visual-qa")
        XCTAssertFalse(app.debugDescription.contains("fixture-token-for-visual-qa"))
        captureGraphite("provider-unsaved-credential-replacement")
        XCTAssertFalse(app.buttons["provider-test-connection"].isEnabled)
        let providerMutationsBefore = fixture.providerIntegrationMutationRecords.count
        let providerSelectionBefore = fixture.providerSelectionRequestCount
        let cardConnect = app.buttons["provider-repair-lmstudio"]
        makeHittable(cardConnect)
        XCTAssertTrue(waitForEnabled(cardConnect, timeout: 3))
        cardConnect.click()
        let unsavedNotice = app.staticTexts["provider-probe-notice"]
        XCTAssertTrue(unsavedNotice.waitForExistence(timeout: 3))
        XCTAssertTrue(element(
            unsavedNotice,
            contains: "Save or discard the LM Studio Advanced changes before reconnecting."
        ))
        makeHittable(unsavedNotice)
        captureGraphite("provider-unsaved-credential-connection-guard")
        XCTAssertEqual(fixture.providerConfigurationSaveCount, 0)
        XCTAssertEqual(fixture.providerPreparationCount, 0)
        XCTAssertEqual(fixture.providerSelectionRequestCount, providerSelectionBefore)
        XCTAssertEqual(fixture.providerIntegrationMutationRecords.count, providerMutationsBefore)

        app.buttons["tab-continuity"].click()
        let packet = app.descendants(matching: .any)["continuity-packet-row-\(fixture.continuityCheckpointID)"]
        XCTAssertTrue(packet.waitForExistence(timeout: 5))
        packet.click()
        let packetsBefore = fixture.continuityPacketIDs
        let mutationsBefore = fixture.mutationAuthorizationCount
        let delete = app.buttons["continuity-delete-packets"]
        XCTAssertTrue(waitForEnabled(delete, timeout: 5))
        delete.click()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmation.staticTexts["Delete selected continuity packets?"].exists)
        captureGraphite("continuity-delete-confirmation")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 3))
        XCTAssertEqual(fixture.continuityPacketIDs, packetsBefore)
        XCTAssertEqual(fixture.mutationAuthorizationCount, mutationsBefore)
        app.buttons["continuity-reset"].click()
        let reset = app.sheets.firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        XCTAssertTrue(reset.staticTexts["Reset continuity history?"].exists)
        captureGraphite("continuity-reset-confirmation")
        reset.buttons["Cancel"].click()
        XCTAssertTrue(reset.waitForNonExistence(timeout: 3))
        XCTAssertTrue(fixture.continuityHistoryClearScopes.isEmpty)
        XCTAssertEqual(fixture.mutationAuthorizationCount, mutationsBefore)

        app.buttons["tab-projects"].click()
        setGuidedModeFromSettings(true)
        XCTAssertTrue(app.descendants(matching: .any)["guided-inline-projects"].waitForExistence(timeout: 3))
        captureGraphite("projects-inline-guidance")
        let instructionHelp = app.buttons["guided-help-instructionQueue"]
        XCTAssertTrue(instructionHelp.waitForExistence(timeout: 5))
        makeHittable(instructionHelp)
        instructionHelp.click()
        XCTAssertTrue(app.descendants(matching: .any)["guided-help-sheet"].waitForExistence(timeout: 3))
        captureGraphite("nested-instruction-help")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["guided-help-sheet"].waitForNonExistence(timeout: 3))

        app.buttons["tab-rune-forge"].click()
        let cachedPartialSource = app.buttons["rune-policy-source-row-67676767-6767-4767-8767-676767676767"]
        XCTAssertTrue(cachedPartialSource.waitForExistence(timeout: 5))
        let overview = app.staticTexts["rune-overview-route"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        makeHittable(overview)
        overview.click()
        fixture.stop()
        let cachedWarning = app.staticTexts[
            "Cached policy information remains available while the Manager reconnects."
        ]
        XCTAssertTrue(cachedWarning.waitForExistence(timeout: 12))
        makeHittable(cachedWarning)
        captureGraphite("rune-cached-manager-unavailable-overview")
        XCTAssertTrue(cachedPartialSource.exists)
        cachedPartialSource.click()
        XCTAssertTrue(app.staticTexts["Opaque instruction source"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Retry"].exists)
        captureGraphite("rune-cached-partially-interpreted-source")
        XCTAssertEqual(fixture.mutationAuthorizationCount, mutationsBefore)
    }

    func testGraphiteInstructionCatalogTransportErrorCanRetryWithoutMutatingQueue() throws {
        let fixture = try OperatorManagerUITestFixture(failFirstInstructionCatalog: true)
        relaunch(with: fixture)
        app.buttons["tab-projects"].click()
        let toggle = app.buttons["instruction-package-catalog-toggle-\(fixture.instructionPackageID)"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        makeHittable(toggle)
        let packageIDs = fixture.instructionPackageIDs
        let generation = fixture.projectGeneration
        let mutationBaseline = fixture.mutationAuthorizationCount
        toggle.click()
        let retry = app.buttons["Retry catalog"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        makeHittable(retry)
        XCTAssertEqual(fixture.instructionCatalogRequestCount, 1)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "fixture catalog transport failure", "fixture catalog transport failure"
        )).element.waitForExistence(timeout: 3))
        captureGraphite("projects-catalog-transport-error")
        retry.click()
        let catalog = app.staticTexts["instruction-document-catalog-\(fixture.instructionPackageID)"]
        XCTAssertTrue(catalog.waitForExistence(timeout: 5))
        makeHittable(catalog)
        XCTAssertTrue(retry.waitForNonExistence(timeout: 3))
        XCTAssertEqual(fixture.instructionCatalogRequestCount, 2)
        XCTAssertTrue(app.descendants(matching: .any)["instruction-document-fixture-instruction-document"].exists)
        XCTAssertEqual(fixture.instructionPackageIDs, packageIDs)
        XCTAssertEqual(fixture.projectGeneration, generation)
        XCTAssertEqual(fixture.mutationAuthorizationCount, mutationBaseline)
        XCTAssertEqual(fixture.instructionQueueRemoveRequestCount, 0)
        XCTAssertEqual(fixture.instructionQueueReorderRequestCount, 0)
        captureGraphite("projects-catalog-retry-recovered")
    }

    func testGraphiteEvidencePaginationRetainsPageAcrossTransportErrorAndRetry() throws {
        let fixture = try OperatorManagerUITestFixture(
            includePagedEvidence: true, failFirstEvidencePage: true
        )
        relaunch(with: fixture)
        app.buttons["tab-evidence"].click()
        let count = app.staticTexts["Showing 100 of 100 bounded events"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let loadOlder = app.buttons["evidence-load-more"]
        XCTAssertTrue(loadOlder.waitForExistence(timeout: 3))
        XCTAssertTrue(loadOlder.isEnabled)
        captureGraphite("evidence-first-page-with-pagination")
        let mutationBaseline = fixture.mutationAuthorizationCount
        loadOlder.click()
        let error = app.descendants(matching: .any)["operator-unavailable"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(element(error, contains: "fixture evidence page transport failure"))
        XCTAssertTrue(count.exists, "A failed older-page request must retain its first page")
        XCTAssertTrue(waitForEnabled(loadOlder, timeout: 3))
        XCTAssertEqual(fixture.evidencePageRequestCount, 1)
        captureGraphite("evidence-older-page-transport-error")
        loadOlder.click()
        XCTAssertTrue(app.staticTexts["Showing 101 of 101 bounded events"].waitForExistence(timeout: 5))
        XCTAssertTrue(error.waitForNonExistence(timeout: 3))
        XCTAssertTrue(loadOlder.waitForNonExistence(timeout: 3))
        XCTAssertEqual(fixture.evidencePageRequestCount, 2)
        XCTAssertEqual(fixture.lastEvidenceCursor, "101")
        XCTAssertEqual(fixture.mutationAuthorizationCount, mutationBaseline)
        captureGraphite("evidence-pagination-retry-recovered")
        let search = app.textFields["evidence-search"]
        search.click()
        search.typeText("Fixture evidence event 100")
        let recoveredEvent = app.descendants(matching: .any)["evidence-event-fixture-evidence-100"]
        XCTAssertTrue(recoveredEvent.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Showing 1 of 101 bounded events"].waitForExistence(timeout: 3))
        captureGraphite("evidence-older-page-filtered-event")
    }

    func testGraphiteWorkbenchCapturesEmptyAndUnavailableStates() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        app.buttons["tab-continuity"].click()
        XCTAssertTrue(app.descendants(matching: .any)["continuity-packets-empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["continuity-delete-packets"].isEnabled)
        captureGraphite("continuity-empty-packets")
        app.buttons["tab-evidence"].click()
        XCTAssertTrue(app.staticTexts["No Events"].waitForExistence(timeout: 5))
        captureGraphite("evidence-empty-page")

        app.terminate()
        operatorFixture?.stop()
        operatorFixture = nil
        app.launchEnvironment.removeValue(forKey: "FORGE_OPERATOR_UI_TEST_PORT")
        app.launch()
        for route in ["projects", "continuity", "runtimes", "provider", "evidence"] {
            let tab = app.buttons["tab-\(route)"]
            XCTAssertTrue(tab.waitForExistence(timeout: 8))
            tab.click()
            XCTAssertTrue(app.descendants(matching: .any)["operator-unavailable"].waitForExistence(timeout: 5))
            captureGraphite("manager-unavailable-\(route)")
        }
    }

    func testGraphiteFilesystemPendingLifecycleFenceIsReadOnly() throws {
        app.terminate()
        try FileManager.default.createDirectory(
            at: testHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fence = testHome.appendingPathComponent(".protected-filesystem-unregister-v1.json")
        let lock = fence.appendingPathExtension("lock")
        let descriptor = lock.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        // The peer lease must outlive every app process. Recovery cannot acquire
        // it, so this record remains unresolved without a ServiceManagement call.
        defer {
            app?.terminate()
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let record: [String: Any] = [
            "schemaVersion": 2,
            "operationID": UUID().uuidString.lowercased(),
            "attemptID": UUID().uuidString.lowercased(),
            "intent": "update",
            "phase": "registration_pending",
            "attemptNumber": 1,
            "leaseDevice": NSNumber(value: UInt64(information.st_dev)),
            "leaseInode": NSNumber(value: UInt64(information.st_ino)),
            "createdAtMilliseconds": 1,
            "updatedAtMilliseconds": 1,
        ]
        let recordBytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try recordBytes.write(to: fence)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fence.path)
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)

        for size in ["normal", "minimum"] {
            if size == "minimum" { resizeMainWindowToMinimum(window) }
            let manager = app.buttons["tab-manager"]
            XCTAssertTrue(manager.waitForExistence(timeout: 5))
            manager.click()
            selectManagerSection("filesystem")
            let lifecycle = app.descendants(matching: .any)["settings-filesystem-lifecycle-fence-status"]
            let pending = "Service stopped; replacement registration is pending"
            XCTAssertTrue(waitUntil(timeout: 8) { self.element(lifecycle, contains: pending) })
            let operation = app.descendants(matching: .any)["settings-filesystem-operation-status"]
            XCTAssertTrue(waitUntil(timeout: 8) { self.element(operation, contains: pending) })
            let warning = app.descendants(matching: .any)["settings-filesystem-lifecycle-fence-warning"]
            XCTAssertTrue(warning.exists)
            let unresolved = app.descendants(matching: .any)["settings-filesystem-service-message"]
            XCTAssertTrue(element(unresolved, contains: "remains unresolved"))
            for identifier in [
                "settings-filesystem-service-enable",
                "settings-filesystem-service-reinstall",
                "settings-filesystem-service-disable",
                "settings-filesystem-service-approval",
                "settings-filesystem-recovery-reconcile",
            ] {
                let control = app.buttons[identifier]
                XCTAssertTrue(control.exists)
                XCTAssertFalse(control.isEnabled, "The unresolved peer lease must fence \(identifier)")
            }
            XCTAssertTrue(app.buttons["settings-filesystem-service-refresh"].isEnabled)
            let recovery = app.buttons["settings-filesystem-lifecycle-recovery"]
            XCTAssertTrue(recovery.exists)
            XCTAssertTrue(recovery.isEnabled)
            XCTAssertEqual(recovery.label, "Register pending replacement")
            makeHittable(recovery)
            captureGraphite("manager-filesystem-pending-fence-\(size)")
            selectManagerSection("folders")
            let attention = app.buttons["manager-filesystem-attention"]
            XCTAssertTrue(attention.waitForExistence(timeout: 5))
            XCTAssertTrue(attention.isEnabled)
            makeHittable(attention)
            captureGraphite("manager-pending-fence-attention-\(size)")
            XCTAssertEqual(try Data(contentsOf: fence), recordBytes)
        }

        app.buttons["tab-tools"].click()
        app.typeKey(",", modifierFlags: .command)
        selectManagerSection("filesystem")
        let settings = managerWindow
        XCTAssertTrue(settings.descendants(matching: .any)["settings-filesystem-lifecycle-fence-warning"].exists)
        let settingsRecovery = settings.buttons["settings-filesystem-lifecycle-recovery"]
        XCTAssertTrue(settingsRecovery.exists)
        XCTAssertTrue(settingsRecovery.isEnabled)
        makeHittable(settingsRecovery)
        captureGraphite("settings-filesystem-pending-fence")
        XCTAssertEqual(try Data(contentsOf: fence), recordBytes, "Read-only native observation must preserve unresolved authority")
        XCTAssertEqual(try Data(contentsOf: lock), Data())
        var finalInformation = stat()
        XCTAssertEqual(Darwin.fstat(descriptor, &finalInformation), 0)
        XCTAssertEqual(finalInformation.st_dev, information.st_dev)
        XCTAssertEqual(finalInformation.st_ino, information.st_ino)
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertEqual(fixture.providerPreparationCount, 0)
        XCTAssertEqual(fixture.providerConfigurationSaveCount, 0)
        XCTAssertTrue(fixture.providerIntegrationMutationRecords.isEmpty)
        XCTAssertTrue(fixture.providerProbeRecords.isEmpty)
    }

    func testGraphiteFilesystemRecoveryDebtAndNativeDoctorReport() throws {
        app.terminate()
        let quarantine = testHome.appendingPathComponent("filesystem-quarantine", isDirectory: true)
        try FileManager.default.createDirectory(
            at: quarantine,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quarantine.path)
        let lock = quarantine.appendingPathComponent(".ledger.lock")
        try Data().write(to: lock)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
        // Read-only health counts fixed occupied slots. Unknown receipt authority
        // remains debt without introducing a real victim path or a service request.
        let receipt = Data("{\"fixture\":\"retained-unresolved-debt\"}".utf8)
        let slots = (0..<32).map { quarantine.appendingPathComponent(String(format: "slot-%02d.json", $0)) }
        for slot in slots {
            try receipt.write(to: slot)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: slot.path)
        }
        let fixtureEntries = try FileManager.default.contentsOfDirectory(atPath: quarantine.path).sorted()
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)

        var registrationState: String?
        var lifecycleControls: [Bool]?
        for size in ["normal", "minimum"] {
            if size == "minimum" { resizeMainWindowToMinimum(window) }
            let manager = app.buttons["tab-manager"]
            XCTAssertTrue(manager.waitForExistence(timeout: 5))
            manager.click()
            selectManagerSection("filesystem")
            let operation = app.descendants(matching: .any)["settings-filesystem-operation-status"]
            XCTAssertTrue(operation.waitForExistence(timeout: 5))
            XCTAssertTrue(waitUntil(timeout: 8) { self.element(operation, contains: "Idle") })
            let status = app.descendants(matching: .any)["settings-filesystem-service-status"]
            XCTAssertTrue(status.exists)
            let controls = [
                app.buttons["settings-filesystem-service-enable"],
                app.buttons["settings-filesystem-service-reinstall"],
                app.buttons["settings-filesystem-service-disable"],
                app.buttons["settings-filesystem-service-approval"],
                app.buttons["settings-filesystem-recovery-reconcile"],
            ]
            XCTAssertTrue(controls.allSatisfy(\.exists))
            let currentRegistration = try XCTUnwrap(
                ["Not enabled", "Enabled", "Approval required", "Not packaged or invalid"]
                    .first { element(status, contains: $0) }
            )
            if registrationState == nil {
                registrationState = currentRegistration
                lifecycleControls = controls.map(\.isEnabled)
            }
            let refresh = app.buttons["settings-filesystem-service-refresh"]
            XCTAssertTrue(waitForEnabled(refresh, timeout: 5))
            makeHittable(refresh)
            refresh.click()
            let debt = app.descendants(matching: .any)["settings-filesystem-recovery-debt"]
            let exhausted = app.descendants(matching: .any)["settings-filesystem-recovery-exhausted"]
            XCTAssertTrue(waitUntil(timeout: 8) {
                self.element(operation, contains: "Idle")
                    && self.element(debt, contains: "Local 32/32")
                    && exhausted.exists
                    && refresh.isEnabled
            }, "The native read-only refresh must expose the full isolated quarantine ledger")
            XCTAssertTrue(element(status, contains: try XCTUnwrap(registrationState)))
            XCTAssertEqual(controls.map(\.isEnabled), lifecycleControls)
            makeHittable(exhausted)
            captureGraphite("manager-filesystem-recovery-debt-\(size)")

            selectManagerSection("doctor")
            let runDoctor = app.buttons["Run doctor"]
            XCTAssertTrue(waitForEnabled(runDoctor, timeout: 5))
            makeHittable(runDoctor)
            runDoctor.click()
            captureGraphite("manager-doctor-report-observed-\(size)")
            let report = app.descendants(matching: .any).matching(
                NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "state=", "state=")
            ).firstMatch
            XCTAssertTrue(report.waitForExistence(timeout: 8), "Doctor must render its actual local native report")
            XCTAssertTrue(element(report, contains: "state=attention"))
            XCTAssertTrue(element(report, contains: "FAIL  swift_binary_install:"))
            XCTAssertTrue(element(report, contains: testHome.path))
            XCTAssertTrue(app.staticTexts["Doctor ISSUES"].exists)
            captureGraphite("manager-doctor-issues-\(size)")
            selectManagerSection("filesystem")
            XCTAssertTrue(waitUntil(timeout: 8) { self.element(operation, contains: "Idle") })
            XCTAssertTrue(
                element(status, contains: try XCTUnwrap(registrationState)),
                "Read-only Doctor must preserve service registration"
            )
            XCTAssertEqual(controls.map(\.isEnabled), lifecycleControls)
        }

        XCTAssertFalse(FileManager.default.isExecutableFile(
            atPath: testHome.appendingPathComponent("bin/forge-conductor").path
        ), "The fixture must not install a helper while reading Doctor")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: quarantine.path).sorted(), fixtureEntries)
        XCTAssertEqual(try Data(contentsOf: lock), Data())
        for slot in slots {
            XCTAssertEqual(try Data(contentsOf: slot), receipt, "Read-only Refresh and Doctor must preserve retained debt")
        }
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertEqual(fixture.providerPreparationCount, 0)
        XCTAssertEqual(fixture.providerConfigurationSaveCount, 0)
        XCTAssertTrue(fixture.providerIntegrationMutationRecords.isEmpty)
        XCTAssertTrue(fixture.providerProbeRecords.isEmpty)
    }

    func testGraphiteWorkbenchUnderNativeAccessibilityPreferences() throws {
        guard ProcessInfo.processInfo.environment["FORGE_GRAPHITE_NATIVE_ACCESSIBILITY_QA"] == "1" else {
            throw XCTSkip("Requires an explicit native accessibility QA run with the desktop preferences configured")
        }
        let workspace = NSWorkspace.shared
        XCTAssertTrue(workspace.accessibilityDisplayShouldReduceMotion)
        XCTAssertTrue(workspace.accessibilityDisplayShouldReduceTransparency)
        XCTAssertTrue(workspace.accessibilityDisplayShouldIncreaseContrast)
        let desktopStyle = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[
            "AppleInterfaceStyle"
        ] as? String ?? "Light"
        XCTAssertNotEqual(desktopStyle.lowercased(), "dark")
        XCTAssertNotEqual(
            ProcessInfo.processInfo.environment["FORGE_GRAPHITE_ACCESSIBILITY_VARIANT"], "1"
        )
        app.launchEnvironment["FORGE_GRAPHITE_ACCESSIBILITY_VARIANT"] = "0"
        XCTAssertNotEqual(app.launchEnvironment["FORGE_GRAPHITE_ACCESSIBILITY_VARIANT"], "1")
        let preferences = XCTAttachment(string: """
        native_reduce_motion=\(workspace.accessibilityDisplayShouldReduceMotion)
        native_reduce_transparency=\(workspace.accessibilityDisplayShouldReduceTransparency)
        native_increase_contrast=\(workspace.accessibilityDisplayShouldIncreaseContrast)
        desktop_style=\(desktopStyle)
        app_graphite_accessibility_variant=\(app.launchEnvironment["FORGE_GRAPHITE_ACCESSIBILITY_VARIANT"] ?? "unset")
        """)
        preferences.name = "graphite-actual-native-accessibility-preferences"
        preferences.lifetime = .keepAlways
        add(preferences)

        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try resizeMainWindowForGraphiteReference(window)
        app.buttons["tab-mcp"].click()
        XCTAssertTrue(app.descendants(matching: .any)["detail-mcp"].waitForExistence(timeout: 5))
        captureGraphite("native-accessibility-mcp-normal")
        resizeMainWindowToMinimum(window)
        captureGraphite("native-accessibility-mcp-minimum")

        app.buttons["tab-manager"].click()
        selectManagerSection("settings")
        let host = app.textFields["Dashboard host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        makeHittable(host)
        host.click()
        captureGraphite("native-accessibility-main-field-focus")
        app.typeKey(.tab, modifierFlags: [])
        captureGraphite("native-accessibility-main-keyboard-next-control")
        app.typeKey(",", modifierFlags: .command)
        selectManagerSection("settings")
        let settingsHost = managerWindow.textFields["Dashboard host"]
        XCTAssertTrue(settingsHost.waitForExistence(timeout: 5))
        settingsHost.click()
        captureGraphite("native-accessibility-settings-field-focus")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows["com_apple_SwiftUI_Settings_window"].waitForNonExistence(timeout: 3))

        app.buttons["tab-projects"].click()
        openCurrentGuideFromMenu()
        let help = app.sheets.firstMatch
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        captureGraphite("native-accessibility-contextual-help")
        let advancedHelp = help.disclosureTriangles["guided-help-advanced"]
        XCTAssertTrue(advancedHelp.waitForExistence(timeout: 3))
        expandGraphiteDisclosure(advancedHelp)
        captureGraphite("native-accessibility-contextual-help-advanced")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(help.waitForNonExistence(timeout: 3))

        app.buttons["tab-provider"].click()
        inspectProvider("lmstudio")
        let advanced = app.buttons["provider-advanced-toggle"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.click()
        let endpoint = app.textFields["provider-endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 3))
        makeHittable(endpoint)
        captureGraphite("native-accessibility-provider-advanced")
        XCTAssertEqual(fixture.settingsUpdateCount, 0)
        XCTAssertEqual(fixture.providerPreparationCount, 0)
        XCTAssertEqual(fixture.providerConfigurationSaveCount, 0)
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertTrue(fixture.providerIntegrationMutationRecords.isEmpty)
        XCTAssertTrue(fixture.providerProbeRecords.isEmpty)
    }

    func testGraphiteWorkbenchCapturesAccessibilityVariantsAndKeyboardFocus() throws {
        let fixture = try OperatorManagerUITestFixture()
        app.launchEnvironment["FORGE_GRAPHITE_ACCESSIBILITY_VARIANT"] = "1"
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        resizeMainWindowToMinimum(window)
        app.buttons["tab-manager"].click()
        selectManagerSection("settings")
        let host = app.textFields["Dashboard host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        makeHittable(host)
        host.click()
        captureGraphite("accessibility-main-field-focus")
        app.typeKey(.tab, modifierFlags: [])
        captureGraphite("accessibility-main-keyboard-next-control")
        app.typeKey(",", modifierFlags: .command)
        selectManagerSection("settings")
        let settingsHost = managerWindow.textFields["Dashboard host"]
        XCTAssertTrue(settingsHost.waitForExistence(timeout: 5))
        settingsHost.click()
        captureGraphite("accessibility-settings-field-focus")
        app.typeKey("w", modifierFlags: .command)
    }

    func testManagerSectionSelectionPreservesStagedSettingsWithoutDispatchingSave() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        app.buttons["tab-manager"].click()
        selectManagerSection("settings")
        let host = app.textFields["Dashboard host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForEnabled(app.buttons["settings-save"], timeout: 5))
        host.click()
        host.typeKey("a", modifierFlags: .command)
        host.typeText("graphite-draft.invalid")
        for section in ["service", "runtime", "shell", "filesystem", "maintenance", "doctor", "folders", "settings"] {
            selectManagerSection(section)
        }
        XCTAssertTrue(waitForValue("graphite-draft.invalid", on: app.textFields["Dashboard host"]))
        XCTAssertEqual(fixture.settingsUpdateCount, 0, "Changing presentation sections must not save a draft")
        let reload = app.buttons["settings-reload"]
        XCTAssertTrue(reload.isEnabled)
        reload.click()
        XCTAssertTrue(waitForValue("127.0.0.1", on: app.textFields["Dashboard host"]))
        XCTAssertEqual(fixture.settingsUpdateCount, 0)
    }

    private func captureGraphitePrimaryViews(in window: XCUIElement, size: String) throws {
        let routes: [(route: String, marker: String, title: String)] = [
            ("rig", "detail-rig", "Dashboard"), ("mcp", "detail-mcp", "LM Studio MCP"),
            ("agents", "detail-agents", "Agents"), ("tools", "detail-tools", "Tools"),
            ("feed", "detail-feed", "Live Feed"), ("projects", "detail-projects", "Projects"),
            ("rune-forge", "detail-rune-forge", "Rune Forge"),
            ("continuity", "detail-continuity", "Continuity"), ("runtimes", "detail-runtimes", "Runtimes"),
            ("provider", "detail-provider", "Provider"), ("evidence", "detail-evidence", "Events & Evidence"),
            ("diagnostics", "detail-diagnostics", "Diagnostics"), ("manager", "detail-manager", "Manager"),
        ]
        for item in routes {
            let route = app.buttons["tab-\(item.route)"]
            XCTAssertTrue(route.waitForExistence(timeout: 5))
            route.click()
            let detail = try XCTUnwrap(selectedDetailContainer(named: item.title))
            let marker = graphitePageHeading(in: detail, identifier: item.marker, title: item.title)
            let contentTop = assertGraphiteGlobalHeader(in: window)
            XCTAssertTrue(frameIsContained(detail.frame, in: window.frame, tolerance: 2))
            XCTAssertTrue(frameIsContained(marker.frame, in: detail.frame, tolerance: 2))
            XCTAssertGreaterThanOrEqual(marker.frame.minY, contentTop - 2)
            if item.route == "rune-forge" || item.route == "runtimes" {
                let identifier = item.route == "rune-forge" ? "rune-detail-heading" : "runtime-task-requirements"
                let firstDetail = app.descendants(matching: .any)[identifier]
                XCTAssertTrue(firstDetail.waitForExistence(timeout: 5))
                let label = item.route == "rune-forge" ? "Development Policy" : "Runtimes for the selected task"
                let firstHeading = firstDetail.staticTexts[label]
                XCTAssertTrue(firstHeading.waitForExistence(timeout: 3))
                XCTAssertTrue(firstHeading.isHittable, "The first split detail heading must remain exposed")
                XCTAssertGreaterThanOrEqual(firstDetail.frame.minY, contentTop - 2)
                XCTAssertTrue(frameIsContained(firstDetail.frame, in: detail.frame, tolerance: 2))
            }
            captureGraphite("\(size)-\(item.route)")
            if item.route == "rig" {
                for (label, identifier, name) in [
                    ("COMPUTE CORES", "rig-compute-cores-panel", "compute-cores"),
                    ("STORAGE", "rig-storage-panel", "storage-iops")
                ] {
                    let heading = app.staticTexts[label]
                    XCTAssertTrue(heading.waitForExistence(timeout: 3))
                    makeHittable(heading)
                    let panel = app.descendants(matching: .any)[identifier]
                    XCTAssertTrue(panel.exists)
                    makeHittable(panel)
                    XCTAssertTrue(heading.isHittable)
                    XCTAssertTrue(frameIsContained(panel.frame, in: detail.frame, tolerance: 2),
                                  "The complete instrumentation panel must be visible in its capture")
                    if name == "storage-iops" {
                        XCTAssertEqual(panel.staticTexts.matching(NSPredicate(
                            format: "label CONTAINS %@ OR value CONTAINS %@", "IOPS", "IOPS"
                        )).count, 3)
                    }
                    captureGraphite("\(size)-dashboard-\(name)")
                }
            } else if item.route == "projects", let fixture = operatorFixture {
                captureGraphiteProjectCatalog(fixture: fixture, name: "\(size)-projects-instruction-catalog")
            }
        }
    }

    private func captureGraphiteProjectCatalog(fixture: OperatorManagerUITestFixture, name: String) {
        let toggle = app.buttons["instruction-package-catalog-toggle-\(fixture.instructionPackageID)"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        makeHittable(toggle)
        toggle.click()
        let catalog = app.staticTexts["instruction-document-catalog-\(fixture.instructionPackageID)"]
        XCTAssertTrue(catalog.waitForExistence(timeout: 5))
        makeHittable(catalog)
        XCTAssertTrue(app.descendants(matching: .any)["instruction-document-fixture-instruction-document"].exists)
        XCTAssertGreaterThan(fixture.instructionCatalogRequestCount, 0)
        captureGraphite(name)
        makeHittable(toggle)
        toggle.click()
        XCTAssertTrue(catalog.waitForNonExistence(timeout: 3))
    }

    private func expandGraphiteDisclosure(_ element: XCUIElement) {
        makeHittable(element)
        element.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 26, dy: 8)).click()
        XCTAssertTrue(waitForToggleState(true, on: element, timeout: 3),
                      "The native disclosure must be expanded before capturing its details")
        makeHittable(element)
    }

    private func captureGraphite(_ name: String) {
        let sheet = app.sheets.firstMatch
        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        let isSettings = name.hasPrefix("settings-") || name.hasPrefix("accessibility-settings-")
            || name.hasPrefix("native-accessibility-settings-")
        let surface = sheet.exists ? sheet
            : isSettings && settingsWindow.exists ? settingsWindow : app.windows.firstMatch
        let screenshot = XCTAttachment(screenshot: surface.screenshot())
        screenshot.name = "graphite-\(name)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let semantics = XCTAttachment(string: app.debugDescription)
        semantics.name = "graphite-\(name)-accessibility"
        semantics.lifetime = .keepAlways
        add(semantics)
        let windows = app.windows.allElementsBoundByIndex.map { window in
            "\(window.label): \(NSStringFromRect(window.frame))"
        }.joined(separator: "\n")
        let geometry = XCTAttachment(string: windows)
        geometry.name = "graphite-\(name)-actual-window-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
    }

    private func resizeMainWindowForGraphiteReference(_ window: XCUIElement) throws {
        app.launchEnvironment["FORGE_GRAPHITE_WINDOW_SIZE"] = "normal"
        app.terminate()
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        let dashboard = app.buttons["tab-rig"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 5))
        dashboard.click()
        let content = app.descendants(matching: .any)["root-split"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertEqual(window.frame.width, 1_440, accuracy: 3)
        XCTAssertEqual(content.frame.height, 900, accuracy: 3)
    }

    @discardableResult
    private func assertGraphiteGlobalHeader(in window: XCUIElement, expectsAllControls: Bool = false) -> CGFloat {
        let content = app.descendants(matching: .any)["root-split"]
        let header = app.descendants(matching: .any)["workbench-global-controls"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertEqual(app.toolbars.count, 0, "Native title-bar action controls must remain absent")
        if !expectsAllControls {
            XCTAssertFalse(header.exists, "The default workspace must have no persistent control bar")
            for identifier in [
                "toolbar-navigation", "toolbar-auto-refresh", "toolbar-guided-mode",
                "toolbar-setup-guide", "toolbar-refresh", "toolbar-guided-setup", "dashboard-guided-setup"
            ] {
                XCTAssertFalse(app.descendants(matching: .any)[identifier].exists,
                               "Optional control must remain absent until enabled in Settings: \(identifier)")
            }
            return content.frame.minY
        }
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(frameIsContained(header.frame, in: content.frame, tolerance: 2))
        XCTAssertEqual(app.toolbars.count, 0, "Action controls must reside in the view header below the native title bar")
        for identifier in [
            "toolbar-navigation", "toolbar-auto-refresh", "toolbar-guided-mode",
            "toolbar-setup-guide", "toolbar-refresh", "dashboard-guided-setup"
        ] {
            let control = header.descendants(matching: .any)[identifier]
            XCTAssertTrue(control.exists, "Missing preserved global control \(identifier)")
            XCTAssertTrue(control.isHittable, "Global control must remain reachable: \(identifier)")
            XCTAssertTrue(frameIsContained(control.frame, in: header.frame, tolerance: 2),
                          "Global control must remain below native title-bar chrome: \(identifier)")
        }
        let setup = header.buttons["dashboard-guided-setup"]
        XCTAssertTrue(header.descendants(matching: .any)["toolbar-guided-setup"].exists)
        XCTAssertTrue(setup.label.contains("Guided Setup"))
        XCTAssertEqual(setup.frame.height, 32, accuracy: 2)
        XCTAssertGreaterThan(setup.frame.minX, header.frame.midX)
        XCTAssertEqual(setup.frame.maxX, header.frame.maxX - 20, accuracy: 2)
        return header.frame.maxY
    }

    private func graphitePageHeading(
        in detail: XCUIElement,
        identifier: String,
        title: String
    ) -> XCUIElement {
        let headingTitle: String
        switch title {
        case "LM Studio MCP": headingTitle = "LM Studio · MCP"
        case "Manager": headingTitle = "Authorized Folders"
        default: headingTitle = title
        }
        let pageHeaderIdentifiers = [
            "detail-mcp", "detail-agents", "detail-tools", "detail-feed",
            "detail-diagnostics", "detail-manager"
        ]
        let headings: XCUIElementQuery
        if pageHeaderIdentifiers.contains(identifier) {
            let pageHeader = detail.groups[identifier]
            XCTAssertTrue(pageHeader.waitForExistence(timeout: 5))
            headings = pageHeader.staticTexts.matching(
                NSPredicate(format: "label == %@ OR value == %@", headingTitle, headingTitle)
            )
        } else {
            let headingIdentifier = identifier == "detail-rune-forge" ? "rune-forge-view" : identifier
            headings = detail.staticTexts.matching(NSPredicate(
                format: "identifier == %@ AND (label == %@ OR value == %@)",
                headingIdentifier, headingTitle, headingTitle
            ))
        }
        let heading = headings.element
        XCTAssertTrue(heading.waitForExistence(timeout: 5), "Missing exact native heading \(headingTitle)")
        XCTAssertEqual(headings.count, 1, "The selected module must own one exact native heading")
        return heading
    }

    private func inspectProvider(_ identifier: String) {
        let row = app.descendants(matching: .any)["provider-inspect-\(identifier)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        makeHittable(row)
        row.click()
        XCTAssertTrue(app.descendants(matching: .any)["provider-card-\(identifier)"].waitForExistence(timeout: 5))
    }

    private func selectManagerSection(_ identifier: String) {
        let owner = managerWindow
        let section = owner.buttons["manager-section-\(identifier)"]
        XCTAssertTrue(section.waitForExistence(timeout: 5))
        makeHittable(section, in: owner)
        section.click()
    }

    private var managerWindow: XCUIElement {
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        return settings.exists ? settings : app.windows["forge-main-window"]
    }

    func testContinuityHeaderAndContentAvoidTitleBarAndUnusedSplitAtMinimumWidth() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        resizeMainWindowToMinimum(window)

        let continuity = app.buttons["tab-continuity"]
        XCTAssertTrue(continuity.waitForExistence(timeout: 5))
        continuity.click()

        let detail = try XCTUnwrap(
            selectedDetailContainer(named: "Continuity"),
            "Missing selected-detail container for Continuity"
        )
        let title = app.staticTexts["detail-continuity"]
        let subtitle = app.staticTexts["continuity-operator-view"]
        let projectList = app.descendants(matching: .any)["continuity-project-list"]
        let packetList = app.descendants(matching: .any)["continuity-packet-list"]
        let copy = app.buttons["continuity-copy-project-id"]
        let delete = app.buttons["continuity-delete-packets"]
        let reset = app.buttons["continuity-reset"]
        let clearCache = app.buttons["continuity-clear-cache"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(subtitle.waitForExistence(timeout: 5))
        XCTAssertTrue(projectList.waitForExistence(timeout: 5))
        XCTAssertTrue(packetList.waitForExistence(timeout: 5))
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        XCTAssertTrue(clearCache.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)["continuity-operation-list"].exists,
            "Continuity must not expose the obsolete operation timeline"
        )

        XCTAssertFalse(
            app.buttons["operator-refresh"].exists,
            "Continuity must not expose a manual refresh operation"
        )

        for element in [title, subtitle, projectList, packetList, copy, delete, reset, clearCache] {
            XCTAssertTrue(
                frameIsContained(element.frame, in: detail.frame, tolerance: 2),
                "\(element.identifier) escaped the Continuity content area"
            )
        }
        XCTAssertGreaterThanOrEqual(copy.frame.minY, subtitle.frame.maxY - 2)
        XCTAssertLessThanOrEqual(
            copy.frame.minY - subtitle.frame.maxY,
            36,
            "Continuity content must follow the header without an unexplained vertical gap"
        )
        XCTAssertGreaterThan(projectList.frame.minY, copy.frame.maxY)
    }

    func testPrimaryContentStartsBelowToolbarAtMinimumWindowSize() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        resizeMainWindowToMinimum(window)

        let contentTop = assertGraphiteGlobalHeader(in: window)
        let projects = app.buttons["tab-projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 5))
        projects.click()
        let detail = try XCTUnwrap(
            selectedDetailContainer(named: "Projects"),
            "Missing selected-detail container for Projects"
        )
        let title = app.staticTexts["detail-projects"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(
            detail.frame.minY,
            contentTop - 2,
            "Project content must begin inside the native content region"
        )
        XCTAssertGreaterThanOrEqual(
            title.frame.minY,
            contentTop - 2,
            "The first readable project heading must remain inside the native content region"
        )
    }

    private func assertEveryPrimaryViewContainedAndAligned(in window: XCUIElement) throws {

        let tabs: [(id: String, detail: String, title: String)] = [
            ("tab-rig", "detail-rig", "Dashboard"),
            ("tab-mcp", "detail-mcp", "LM Studio MCP"),
            ("tab-agents", "detail-agents", "Agents"),
            ("tab-tools", "detail-tools", "Tools"),
            ("tab-feed", "detail-feed", "Live Feed"),
            ("tab-projects", "detail-projects", "Projects"),
            ("tab-rune-forge", "detail-rune-forge", "Rune Forge"),
            ("tab-continuity", "detail-continuity", "Continuity"),
            ("tab-runtimes", "detail-runtimes", "Runtimes"),
            ("tab-provider", "detail-provider", "Provider"),
            ("tab-evidence", "detail-evidence", "Events & Evidence"),
            ("tab-diagnostics", "detail-diagnostics", "Diagnostics"),
            ("tab-manager", "detail-manager", "Manager"),
        ]
        var referenceFrame: CGRect?
        for tab in tabs {
            let button = app.buttons[tab.id]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing \(tab.id)")
            button.click()
            let detail = try XCTUnwrap(
                selectedDetailContainer(named: tab.title),
                "Missing selected-detail container for \(tab.title)"
            )
            let marker = graphitePageHeading(in: detail, identifier: tab.detail, title: tab.title)
            let frame = detail.frame
            let contentTop = assertGraphiteGlobalHeader(in: window)
            XCTAssertGreaterThanOrEqual(frame.minY, contentTop - 2)
            XCTAssertGreaterThanOrEqual(marker.frame.minY, contentTop - 2)
            XCTAssertGreaterThan(frame.width, 600, "\(tab.detail) is unexpectedly narrow")
            XCTAssertGreaterThan(frame.height, 500, "\(tab.detail) is unexpectedly short")
            XCTAssertTrue(
                frameIsContained(frame, in: window.frame, tolerance: 2),
                "\(tab.detail) escaped the minimum window: detail=\(frame), window=\(window.frame)"
            )
            XCTAssertTrue(
                frameIsContained(marker.frame, in: frame, tolerance: 2),
                "\(tab.detail) heading escaped its selected-detail container"
            )
            if let referenceFrame {
                XCTAssertEqual(frame.minX, referenceFrame.minX, accuracy: 2, "\(tab.detail) left edge")
                XCTAssertEqual(frame.maxX, referenceFrame.maxX, accuracy: 2, "\(tab.detail) right edge")
                XCTAssertEqual(frame.minY, referenceFrame.minY, accuracy: 2, "\(tab.detail) top edge")
                XCTAssertEqual(frame.maxY, referenceFrame.maxY, accuracy: 2, "\(tab.detail) bottom edge")
            } else {
                referenceFrame = frame
            }
        }
    }

    private func selectedDetailContainer(named title: String) -> XCUIElement? {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "\(title) content"))
            .allElementsBoundByIndex
            .max { lhs, rhs in
                lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }
    }

    func testTerminalTaskRequiresConfirmationAndCanBeDeleted() throws {
        let fixture = try OperatorManagerUITestFixture(initialRunState: "completed")
        relaunch(with: fixture)

        openProjectRuns()
        let row = app.descendants(matching: .any)["autonomy-run-row-\(fixture.runID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let delete = app.buttons["run-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertTrue(delete.isEnabled)
        delete.click()

        let confirmation = app.alerts["Delete task?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Delete Task"].click()
        XCTAssertTrue(waitUntil(timeout: 5) { !row.exists })
        XCTAssertEqual(fixture.deletionRequestCount, 1)
    }

    func testOperatorStateReconnectsAfterGUIRelaunch() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        openProjectRuns()

        let state = app.descendants(matching: .any)["autonomy-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("running", on: state))

        let pause = app.buttons["run-pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        makeHittable(pause)
        pause.click()
        XCTAssertTrue(waitForValue("paused", on: state), "The UI must reconcile the persisted pause response")
        XCTAssertEqual(fixture.controlRequestCount, 1)

        app.terminate()
        app.launch()

        openProjectRuns()
        let restoredState = app.descendants(matching: .any)["autonomy-state"]
        XCTAssertTrue(
            restoredState.waitForExistence(timeout: 5) && waitForValue("paused", on: restoredState),
            "The relaunched GUI must reload the manager's durable run state"
        )
    }

    func testContinuityShowsProjectIDsAndContinuityPacketRows() throws {
        let fixture = try OperatorManagerUITestFixture(includeContinuityOperation: true)
        relaunch(with: fixture)

        let continuity = app.buttons["tab-continuity"]
        XCTAssertTrue(continuity.waitForExistence(timeout: 8))
        continuity.click()

        let list = app.descendants(matching: .any)["continuity-project-list"]
        let packets = app.descendants(matching: .any)["continuity-packet-list"]
        let row = app.staticTexts["continuity-project-row-\(fixture.projectID)"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(packets.waitForExistence(timeout: 5))
        let checkpoint = app.descendants(matching: .any)[
            "continuity-packet-row-\(fixture.continuityCheckpointID)"
        ]
        XCTAssertTrue(checkpoint.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["continuity-packet-row-\(fixture.continuityHandoffID)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["continuity-copy-project-id"].exists)
        XCTAssertTrue(app.buttons["continuity-delete-packets"].exists)
        XCTAssertTrue(app.buttons["continuity-reset"].exists)
        XCTAssertTrue(app.buttons["continuity-clear-cache"].exists)
        XCTAssertFalse(app.buttons["continuity-delete-package"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["continuity-package-picker"].exists)
        XCTAssertFalse(app.buttons["checkpoint-command"].exists)
        XCTAssertFalse(app.buttons["rollover-command"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["continuity-operation-list"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["continuity-exact-operation-state"].exists)
    }

    func testContinuityProjectIDCanBeCopied() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        let continuity = app.buttons["tab-continuity"]
        XCTAssertTrue(continuity.waitForExistence(timeout: 8))
        continuity.click()
        let copy = app.buttons["continuity-copy-project-id"]
        XCTAssertTrue(waitForEnabled(copy, timeout: 5))
        makeHittable(copy)
        NSPasteboard.general.clearContents()
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), fixture.projectID)
    }

    func testContinuityPacketCanBeDeletedWithConfirmation() throws {
        let fixture = try OperatorManagerUITestFixture(includeContinuityOperation: true)
        relaunch(with: fixture)

        let continuity = app.buttons["tab-continuity"]
        XCTAssertTrue(continuity.waitForExistence(timeout: 8))
        continuity.click()
        let row = app.descendants(matching: .any)["continuity-packet-row-\(fixture.continuityCheckpointID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        let delete = app.buttons["continuity-delete-packets"]
        XCTAssertTrue(waitForEnabled(delete, timeout: 5))
        makeHittable(delete)
        delete.click()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmation.staticTexts["Delete selected continuity packets?"].exists)
        confirmation.buttons["Delete"].click()

        XCTAssertTrue(waitUntil(timeout: 5) { !row.exists })
        XCTAssertEqual(fixture.continuityPacketIDs, [fixture.continuityHandoffID])
        XCTAssertTrue(app.descendants(matching: .any)["operator-notice"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["continuity-packet-row-\(fixture.continuityHandoffID)"].exists)
    }

    func testContinuityNativeMultiplePacketSelectionDeletesExactPacketsAndClearsOnReload() throws {
        let fixture = try OperatorManagerUITestFixture(includeContinuityOperation: true)
        let originalGeneration = fixture.projectGeneration
        let expectedPacketIDs = Set([fixture.continuityCheckpointID, fixture.continuityHandoffID])
        relaunch(with: fixture)
        let continuity = app.buttons["tab-continuity"]
        XCTAssertTrue(continuity.waitForExistence(timeout: 8))
        continuity.click()
        let checkpoint = app.descendants(matching: .any)["continuity-packet-row-\(fixture.continuityCheckpointID)"]
        let handoff = app.descendants(matching: .any)["continuity-packet-row-\(fixture.continuityHandoffID)"]
        let delete = app.buttons["continuity-delete-packets"]
        XCTAssertTrue(checkpoint.waitForExistence(timeout: 5))
        XCTAssertTrue(handoff.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled)
        checkpoint.click()
        XCUIElement.perform(withKeyModifiers: .command) { handoff.click() }
        XCTAssertTrue(waitForEnabled(delete, timeout: 5))
        captureGraphite("continuity-native-two-packets-selected")
        delete.click()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmation.staticTexts["Delete selected continuity packets?"].exists)
        let message = "Delete 2 selected packets? Only those handoff/checkpoint records and their derived projections will be removed."
        XCTAssertTrue(confirmation.staticTexts[message].exists)
        captureGraphite("continuity-native-two-packets-confirmation")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 3))
        XCTAssertEqual(Set(fixture.continuityPacketIDs), expectedPacketIDs)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 0)
        XCTAssertNil(fixture.lastContinuityPacketDeletionBody)

        let readsBeforeReload = fixture.continuityPacketListRequestCount
        app.buttons["tab-tools"].click()
        continuity.click()
        XCTAssertTrue(waitUntil(timeout: 5) { fixture.continuityPacketListRequestCount > readsBeforeReload })
        XCTAssertTrue(checkpoint.waitForExistence(timeout: 5))
        XCTAssertTrue(handoff.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { delete.exists && !delete.isEnabled },
                      "Reloading packets must clear the native multi-selection as well as the model selection")
        captureGraphite("continuity-native-selection-cleared-after-reload")

        checkpoint.click()
        XCUIElement.perform(withKeyModifiers: .command) { handoff.click() }
        XCTAssertTrue(waitForEnabled(delete, timeout: 5))
        delete.click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmation.staticTexts[message].exists)
        confirmation.buttons["Delete"].click()
        XCTAssertTrue(waitUntil(timeout: 5) { !checkpoint.exists && !handoff.exists })
        XCTAssertTrue(app.descendants(matching: .any)["continuity-packets-empty"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { !delete.isEnabled })
        XCTAssertTrue(fixture.continuityPacketIDs.isEmpty)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 1)
        let deletion = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(fixture.lastContinuityPacketDeletionBody)
        ) as? [String: Any])
        XCTAssertEqual(Set(deletion.keys), ["project_id", "packet_ids"])
        XCTAssertEqual(deletion["project_id"] as? String, fixture.projectID)
        let deletedPacketIDs = try XCTUnwrap(deletion["packet_ids"] as? [String])
        XCTAssertEqual(deletedPacketIDs.count, 2)
        XCTAssertEqual(Set(deletedPacketIDs), expectedPacketIDs)

        let readsAfterDeletion = fixture.continuityPacketListRequestCount
        app.buttons["tab-tools"].click()
        continuity.click()
        XCTAssertTrue(waitUntil(timeout: 5) { fixture.continuityPacketListRequestCount > readsAfterDeletion })
        XCTAssertTrue(app.descendants(matching: .any)["continuity-packets-empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(checkpoint.exists)
        XCTAssertFalse(handoff.exists)
        XCTAssertFalse(delete.isEnabled)
        XCTAssertTrue(app.buttons["continuity-copy-project-id"].isEnabled)
        captureGraphite("continuity-native-deleted-packets-remain-empty-after-reload")
        XCTAssertEqual(fixture.projectGeneration, originalGeneration)
        XCTAssertTrue(fixture.continuityHistoryClearScopes.isEmpty)
        XCTAssertEqual(fixture.settingsUpdateCount, 0)
        XCTAssertEqual(fixture.startRequestCount, 0)
        XCTAssertEqual(fixture.controlRequestCount, 0)
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertEqual(fixture.providerConfigurationSaveCount, 0)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 1)
    }

    func testContinuityResetClearsOnlyContinuityHistory() throws {
        let fixture = try OperatorManagerUITestFixture(includeContinuityOperation: true)
        let originalGeneration = fixture.projectGeneration
        let originalPacketIDs = fixture.continuityPacketIDs
        relaunch(with: fixture)

        let continuity = app.buttons["tab-continuity"]
        XCTAssertTrue(continuity.waitForExistence(timeout: 8))
        continuity.click()

        let reset = app.buttons["continuity-reset"]
        XCTAssertTrue(waitForEnabled(reset, timeout: 5))
        makeHittable(reset)
        reset.click()

        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmation.staticTexts["Reset continuity history?"].exists)
        confirmation.buttons["Reset"].click()

        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.continuityHistoryClearScopes == ["project"]
        })
        XCTAssertEqual(fixture.projectGeneration, originalGeneration)
        XCTAssertEqual(fixture.continuityPacketIDs, originalPacketIDs)
    }

    func testContinuityDoesNotExposeInstructionPackageDeletion() throws {
        let fixture = try OperatorManagerUITestFixture(includeContinuityOperation: true)
        relaunch(with: fixture)

        let continuity = app.buttons["tab-continuity"]
        XCTAssertTrue(continuity.waitForExistence(timeout: 8))
        continuity.click()

        XCTAssertTrue(app.descendants(matching: .any)["continuity-packet-list"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["continuity-delete-package"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["continuity-package-picker"].exists)
        XCTAssertEqual(fixture.instructionQueueRemoveRequestCount, 0)
    }

    func testProviderSettingsSaveUsesRedactedManagerStateAndSurvivesViewReopen() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let provider = app.buttons["tab-provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 8))
        provider.click()
        let advanced = app.buttons["provider-advanced-toggle"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        makeHittable(advanced)
        advanced.click()
        let endpoint = app.textFields["provider-endpoint"]
        let model = app.textFields["provider-model-key"]
        let save = app.buttons["provider-save"]
        XCTAssertTrue(waitForEnabled(save, timeout: 5))
        XCTAssertTrue(endpoint.exists)
        XCTAssertTrue(model.exists)
        makeHittable(model)
        model.click()
        model.typeKey("a", modifierFlags: .command)
        model.typeText("fixture/configured-model")
        XCTAssertFalse(app.buttons["provider-test-connection"].isEnabled,
                       "Unsaved model changes must not test the previous saved configuration")
        XCTAssertTrue(app.descendants(matching: .any)["provider-unsaved-changes"].exists)
        makeHittable(save)
        save.click()
        XCTAssertTrue(waitUntil(timeout: 5) { fixture.providerConfigurationSaveCount == 1 })
        XCTAssertEqual(fixture.providerConfiguredModel, "fixture/configured-model")
        XCTAssertTrue(fixture.providerProbeRecords.isEmpty, "Save must not report or fabricate a connection probe")
        let notice = app.descendants(matching: .any)["provider-probe-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(element(notice, contains: "Settings saved"))
        app.buttons["tab-projects"].click()
        provider.click()
        if !app.textFields["provider-model-key"].waitForExistence(timeout: 1) {
            let reopenedAdvanced = app.buttons["provider-advanced-toggle"]
            XCTAssertTrue(reopenedAdvanced.waitForExistence(timeout: 5))
            makeHittable(reopenedAdvanced)
            reopenedAdvanced.click()
        }
        XCTAssertTrue(waitForValue("fixture/configured-model", on: app.textFields["provider-model-key"]))
        XCTAssertTrue(app.buttons["provider-test-connection"].exists)
        XCTAssertTrue(app.buttons["provider-refresh-models"].exists)
    }

    func testLocalLMStudioAdvancedSettingsDoNotExposeCredentialControls() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        let provider = app.buttons["tab-provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 8))
        provider.click()

        let advanced = app.buttons["provider-advanced-toggle"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.click()

        XCTAssertTrue(app.staticTexts["provider-local-no-auth"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["provider-credential-action"].exists)
        XCTAssertFalse(app.secureTextFields["provider-token"].exists)
    }

    func testProviderCardsExposeSingleSelectionAndLMStudioConnectAndCheck() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        let provider = app.buttons["tab-provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 8))
        provider.click()

        let providerIDs = ["lmstudio", "claude-desktop", "codex-desktop", "grok-build"]
        for providerID in providerIDs {
            inspectProvider(providerID)
            XCTAssertTrue(
                app.descendants(matching: .any)["provider-card-\(providerID)"]
                    .waitForExistence(timeout: 5),
                "Inspected provider \(providerID) must retain its full detail controls"
            )
            let toggle = app.descendants(matching: .any)["provider-toggle-\(providerID)"]
            XCTAssertTrue(
                waitForToggleState(providerID == "lmstudio", on: toggle),
                "Inspection must preserve the active LM Studio registry selection"
            )
            if providerID != "grok-build" {
                let connectAndCheck = app.buttons["provider-repair-\(providerID)"]
                XCTAssertTrue(
                    waitForEnabled(connectAndCheck, timeout: 5),
                    "Selectable provider \(providerID) must retain Connect and Check"
                )
                XCTAssertEqual(connectAndCheck.label, "Connect and Check")
            }
        }

        XCTAssertFalse(
            app.buttons["provider-repair-grok-build"].exists,
            "Grok Build must remain visibly nonselectable"
        )
        let grokAvailability = app.descendants(matching: .any)[
            "provider-availability-grok-build"
        ]
        XCTAssertTrue(grokAvailability.exists)
        XCTAssertTrue(element(grokAvailability, contains: "Not selectable"))

        let selectionGuidance = app.staticTexts["provider-selection-guidance"]
        XCTAssertTrue(selectionGuidance.exists)
        XCTAssertTrue(element(selectionGuidance, contains: "Select a row to inspect"))
        XCTAssertTrue(element(selectionGuidance, contains: "Use Activate"))

        inspectProvider("lmstudio")
        let connectAndCheck = app.buttons["provider-repair-lmstudio"]
        XCTAssertTrue(waitForEnabled(connectAndCheck, timeout: 5))
        XCTAssertEqual(connectAndCheck.label, "Connect and Check")
        makeHittable(connectAndCheck)
        connectAndCheck.click()

        let completedConnectAndCheck = waitUntil(timeout: 8) {
            fixture.providerPreparationCount == 2
                && fixture.providerIntegrationMutationRecords.count == 1
        }
        XCTAssertTrue(
            completedConnectAndCheck,
            "Expected two preparations and one repair; observed \(fixture.providerPreparationCount) preparation(s) and \(fixture.providerIntegrationMutationRecords.count) repair(s)"
        )
        XCTAssertEqual(fixture.providerPreparationAuthorizationCount, 2)
        XCTAssertEqual(
            fixture.providerPreparationResumeWaitingRuns,
            [false, false],
            "Connect and Check must keep retained runs quiescent through preparation and integration verification"
        )
        let repair = try XCTUnwrap(fixture.providerIntegrationMutationRecords.first)
        XCTAssertEqual(repair.kind, "repair")
        XCTAssertEqual(repair.providerID, "lmstudio")
        XCTAssertEqual(repair.expectedRevision, "provider-revision-1")
        XCTAssertNotNil(UUID(uuidString: repair.idempotencyKey))
        XCTAssertEqual(repair.idempotencyKey, repair.idempotencyKey.lowercased())
        XCTAssertEqual(fixture.providerIntegrationMutationAuthorizationCount, 1)
        let completionNotice = app.descendants(matching: .any)["provider-probe-notice"]
        XCTAssertTrue(waitUntil(timeout: 5) {
            completionNotice.exists
                && self.element(completionNotice, contains: "integration passed verification")
        })
        for key in [
            "app_path",
            "app_version",
            "package_version",
            "package_sha256",
            "deployment_id",
            "deployment_verified",
            "mcp_enabled",
            "hook_trust_review_required",
            "restart_required",
            "connection",
        ] {
            XCTAssertTrue(
                app.descendants(matching: .any)["provider-receipt-lmstudio-\(key)"]
                    .waitForExistence(timeout: 5),
                "Receipt evidence \(key) should be visible"
            )
        }

        let activeLMStudio = app.descendants(matching: .any)["provider-toggle-lmstudio"]
        XCTAssertTrue(waitForEnabled(activeLMStudio, timeout: 5))
        makeHittable(activeLMStudio)
        activeLMStudio.click()
        XCTAssertTrue(
            waitForToggleState(true, on: activeLMStudio),
            "Turning off the active choice must not leave run admission without a provider"
        )
        XCTAssertEqual(
            fixture.providerIntegrationMutationRecords.count,
            1,
            "Turning off the active provider must not submit another provider mutation"
        )
    }

    func testProviderControlsUseProtectedPreparationWithoutManagerUnavailable() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        let provider = app.buttons["tab-provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 8))
        provider.click()

        let advanced = app.buttons["provider-advanced-toggle"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        makeHittable(advanced)
        advanced.click()

        let testConnection = app.buttons["provider-test-connection"]
        XCTAssertTrue(waitForEnabled(testConnection, timeout: 5))
        makeHittable(testConnection)
        testConnection.click()

        XCTAssertTrue(waitUntil(timeout: 12) {
            fixture.providerPreparationCount == 2
                && fixture.providerIntegrationMutationRecords.count == 1
        })
        XCTAssertEqual(fixture.providerPreparationAuthorizationCount, 2)
        XCTAssertEqual(fixture.providerIntegrationMutationAuthorizationCount, 1)
        XCTAssertTrue(fixture.providerProbeRecords.isEmpty)
        let notice = app.descendants(matching: .any)["provider-probe-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(element(notice, contains: "integration passed verification"))

        let runContractProbe = app.buttons["provider-run-contract-probe"]
        XCTAssertTrue(waitForEnabled(runContractProbe, timeout: 5))
        makeHittable(runContractProbe)
        runContractProbe.click()

        XCTAssertTrue(waitUntil(timeout: 12) {
            fixture.providerPreparationCount == 4
                && fixture.providerIntegrationMutationRecords.count == 2
        })
        XCTAssertEqual(fixture.providerPreparationAuthorizationCount, 4)
        XCTAssertEqual(fixture.providerIntegrationMutationAuthorizationCount, 2)
        XCTAssertEqual(fixture.providerProbeAuthorizationCount, 0)
        XCTAssertTrue(fixture.providerProbeBodies.isEmpty)
        XCTAssertFalse(app.descendants(matching: .any)["operator-unavailable"].exists)
        XCTAssertTrue(element(notice, contains: "integration passed verification"))
    }

    func testGraphiteProviderBusyPreparationPollsAndCancelsExactOperation() throws {
        let fixture = try OperatorManagerUITestFixture(includePendingProviderOperation: true)
        relaunch(with: fixture)
        let provider = app.buttons["tab-provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 8))
        provider.click()

        let progress = app.descendants(matching: .any)["provider-operation-progress"]
        let cancel = app.buttons["provider-operation-cancel"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForEnabled(cancel, timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { fixture.providerOperationPollRequestCount > 0 },
                      "The busy panel must observe the exact durable operation through its real polling path")
        makeHittable(cancel)
        captureGraphite("provider-busy-verifying-configuration")
        let toggle = app.switches["provider-toggle-lmstudio"]
        let repair = app.buttons["provider-repair-lmstudio"]
        XCTAssertTrue(toggle.exists)
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertTrue(repair.exists)
        XCTAssertFalse(repair.isEnabled)
        cancel.click()

        XCTAssertTrue(waitUntil(timeout: 5) { fixture.providerOperationCancellationIDs.count == 1 })
        XCTAssertEqual(fixture.providerOperationCancellationIDs, [fixture.pendingProviderOperationID])
        XCTAssertEqual(fixture.providerOperationCancellationAuthorizationCount, 1)
        let body = try XCTUnwrap(fixture.providerOperationCancellationBodies.first)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertTrue(payload.isEmpty, "Cancellation must keep the protected empty-object command contract")
        XCTAssertTrue(progress.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForEnabled(toggle, timeout: 5))
        XCTAssertTrue(waitForEnabled(repair, timeout: 5))
        let notice = app.staticTexts["provider-probe-notice"]
        XCTAssertTrue(waitUntil(timeout: 5) {
            notice.exists && self.element(notice, contains: "Provider setup was cancelled")
        })
        captureGraphite("provider-busy-cancellation-reconciled")
        XCTAssertEqual(fixture.providerSelectionRequestCount, 0)
        XCTAssertEqual(fixture.providerPreparationCount, 0)
        XCTAssertEqual(fixture.startRequestCount, 0)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 1,
                       "Polling and inspection are read-only; only the requested cancellation may mutate")
    }

    func testRuntimeCancelUsesProtectedTypedRequestAndReconcilesSuccessAndRejection() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        let runtimes = app.buttons["tab-runtimes"]
        XCTAssertTrue(runtimes.waitForExistence(timeout: 8))
        runtimes.click()

        let state = app.descendants(matching: .any)["runtime-job-state"]
        let cancel = app.buttons["runtime-job-cancel"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "The actual Cancel Job control must be visible")
        XCTAssertTrue(element(state, contains: "queued"))
        XCTAssertTrue(cancel.isEnabled, "A queued runtime job must be cancellable")

        fixture.setRuntimeJobState("running")
        let snapshotBaseline = fixture.operatorSnapshotRequestCount
        refreshOperator()
        let runningPublished = waitUntil(timeout: 5) {
            self.element(state, contains: "running") && cancel.isEnabled
        }
        if !runningPublished {
            captureGraphite("runtime-cancel-running-refresh-failure")
            let evidence = XCTAttachment(string: """
                Snapshot requests before Refresh: \(snapshotBaseline)
                Snapshot requests after Refresh: \(fixture.operatorSnapshotRequestCount)
                Latest snapshot runtime state: \(fixture.lastOperatorSnapshotRuntimeState ?? "unavailable")
                Selected job state label: \(state.label)
                Selected job state value: \(String(describing: state.value))
                Cancel Job enabled: \(cancel.isEnabled)
                """
            )
            evidence.name = "runtime-refresh-request-and-publication-evidence"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        XCTAssertGreaterThan(fixture.operatorSnapshotRequestCount, snapshotBaseline)
        XCTAssertEqual(fixture.lastOperatorSnapshotRuntimeState, "running")
        XCTAssertTrue(runningPublished)

        for noncancellableState in [
            "cancelling", "completed", "failed", "timed_out", "cancelled", "quarantined_stale",
        ] {
            fixture.setRuntimeJobState(noncancellableState)
            let snapshotBaseline = fixture.operatorSnapshotRequestCount
            refreshOperator()
            let displayState = noncancellableState.replacingOccurrences(of: "_", with: " ")
            let statePublished = waitUntil(timeout: 5) {
                self.element(state, contains: displayState)
            }
            captureGraphite("runtime-job-state-\(noncancellableState)")
            let evidence = XCTAttachment(string: [
                "Raw requested runtime state: \(noncancellableState)",
                "Expected native state text: \(displayState)",
                "Snapshot requests before Refresh: \(snapshotBaseline)",
                "Snapshot requests after Refresh: \(fixture.operatorSnapshotRequestCount)",
                "Latest snapshot runtime state: \(fixture.lastOperatorSnapshotRuntimeState ?? "unavailable")",
                "Selected job state label: \(state.label)",
                "Selected job state value: \(String(describing: state.value))",
                "Cancel Job enabled: \(cancel.isEnabled)",
            ].joined(separator: "\n"))
            evidence.name = "runtime-\(noncancellableState)-request-and-publication-evidence"
            evidence.lifetime = .keepAlways
            add(evidence)
            XCTAssertGreaterThan(fixture.operatorSnapshotRequestCount, snapshotBaseline)
            XCTAssertEqual(fixture.lastOperatorSnapshotRuntimeState, noncancellableState)
            XCTAssertTrue(statePublished)
            XCTAssertFalse(
                cancel.isEnabled,
                "Cancel Job must be disabled for \(noncancellableState) jobs"
            )
        }

        fixture.setRuntimeJobState("running")
        refreshOperator()
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.element(state, contains: "running") && cancel.isEnabled
        })
        makeHittable(cancel)
        cancel.click()

        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.runtimeCancellationJobIDs == [fixture.runtimeJobID]
        })
        XCTAssertEqual(fixture.runtimeCancellationAuthorizationCount, 1)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 1)
        XCTAssertEqual(
            fixture.runtimeCancellationBodies.map { String(decoding: $0, as: UTF8.self) },
            ["{\"job_id\":\"\(fixture.runtimeJobID)\"}"]
        )
        let notice = app.descendants(matching: .any)["operator-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(element(notice, contains: fixture.runtimeJobID))
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.element(state, contains: "cancelled") && !cancel.isEnabled
        })

        fixture.setRuntimeJobState("queued")
        fixture.rejectNextRuntimeCancellation()
        refreshOperator()
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.element(state, contains: "queued") && cancel.isEnabled
        })
        makeHittable(cancel)
        cancel.click()

        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.runtimeCancellationJobIDs == [fixture.runtimeJobID, fixture.runtimeJobID]
        })
        XCTAssertEqual(fixture.runtimeCancellationAuthorizationCount, 2)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 2)
        let rejection = app.descendants(matching: .any)["operator-unavailable"]
        XCTAssertTrue(rejection.waitForExistence(timeout: 5))
        XCTAssertTrue(element(rejection, contains: "fixture rejected runtime cancellation"))
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.element(state, contains: "queued") && cancel.isEnabled
        })
    }

    func testProjectsRelinkControlUsesExactSelectionAndReconcilesViewModel() throws {
        let selectedRoot = testHome.appendingPathComponent(
            "fixture-project-relinked",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: selectedRoot,
            withIntermediateDirectories: true
        )
        let fixture = try OperatorManagerUITestFixture()
        app.launchEnvironment["FORGE_PROJECT_RELINK_UI_TEST_SELECTION"] = selectedRoot.path
        relaunch(with: fixture)

        let projects = app.buttons["tab-projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 8))
        projects.click()

        let relink = app.buttons["project-relink"]
        XCTAssertTrue(relink.waitForExistence(timeout: 5))
        XCTAssertTrue(relink.isEnabled)
        makeHittable(relink)
        relink.click()

        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.relinkRequestCount == 1
                && fixture.projectGeneration == 5
                && fixture.projectRoot == selectedRoot.standardizedFileURL.path
        })
        XCTAssertEqual(fixture.mutationAuthorizationCount, 1)
        let notice = app.descendants(matching: .any)["operator-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(element(notice, contains: "generation 5"))
        let canonicalRoot = app.descendants(matching: .any)["project-canonical-root"]
        XCTAssertTrue(canonicalRoot.waitForExistence(timeout: 5))
        XCTAssertTrue(element(canonicalRoot, contains: selectedRoot.standardizedFileURL.path))
        XCTAssertTrue(element(app.descendants(matching: .any)["project-generation"], contains: "5"))
    }

    func testProjectsRelinkLostResponseReplaysExactRequestAndShowsReconciledReceipt() throws {
        let selectedRoot = testHome.appendingPathComponent(
            "fixture-project-relinked-lost-response",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: selectedRoot,
            withIntermediateDirectories: true
        )
        let fixture = try OperatorManagerUITestFixture(dropFirstRelinkResponse: true)
        app.launchEnvironment["FORGE_PROJECT_RELINK_UI_TEST_SELECTION"] = selectedRoot.path
        relaunch(with: fixture)

        let projects = app.buttons["tab-projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 8))
        projects.click()
        let relink = app.buttons["project-relink"]
        XCTAssertTrue(relink.waitForExistence(timeout: 5))
        makeHittable(relink)
        relink.click()

        XCTAssertTrue(waitUntil(timeout: 8) {
            fixture.relinkRequestCount == 2
                && fixture.projectGeneration == 5
                && fixture.projectRoot == selectedRoot.standardizedFileURL.path
        })
        XCTAssertEqual(fixture.mutationAuthorizationCount, 2)
        let notice = app.descendants(matching: .any)["operator-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(element(notice, contains: "Reconciled"))
        XCTAssertFalse(app.buttons["project-relink-reconcile"].exists)
    }

    func testProjectsRelinkBothAutomaticResponsesLostOffersManualExactReconciliation() throws {
        let selectedRoot = testHome.appendingPathComponent(
            "fixture-project-relinked-two-lost-responses",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: selectedRoot,
            withIntermediateDirectories: true
        )
        let fixture = try OperatorManagerUITestFixture(dropRelinkResponseCount: 2)
        app.launchEnvironment["FORGE_PROJECT_RELINK_UI_TEST_SELECTION"] = selectedRoot.path
        relaunch(with: fixture)

        let projects = app.buttons["tab-projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 8))
        projects.click()
        let relink = app.buttons["project-relink"]
        XCTAssertTrue(relink.waitForExistence(timeout: 5))
        makeHittable(relink)
        relink.click()

        let reconcile = app.buttons["project-relink-reconcile"]
        XCTAssertTrue(reconcile.waitForExistence(timeout: 8))
        XCTAssertEqual(fixture.relinkRequestCount, 2)
        XCTAssertEqual(fixture.projectGeneration, 5)
        XCTAssertEqual(
            fixture.projectRoot,
            selectedRoot.standardizedFileURL.path
        )
        makeHittable(reconcile)
        captureGraphite("projects-relink-response-loss-pending-reconciliation")
        reconcile.click()

        XCTAssertTrue(waitUntil(timeout: 8) {
            fixture.relinkRequestCount == 3
        })
        XCTAssertEqual(fixture.projectGeneration, 5)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 3)
        let notice = app.descendants(matching: .any)["operator-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(element(notice, contains: "Reconciled"))
        XCTAssertFalse(reconcile.exists)
        captureGraphite("projects-relink-response-loss-reconciled")
    }

    func testProjectsRelinkRejectionOffersExactManualReconciliation() throws {
        let selectedRoot = testHome.appendingPathComponent(
            "fixture-project-relinked-manual-reconcile",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: selectedRoot,
            withIntermediateDirectories: true
        )
        let fixture = try OperatorManagerUITestFixture(rejectFirstRelinkResponse: true)
        app.launchEnvironment["FORGE_PROJECT_RELINK_UI_TEST_SELECTION"] = selectedRoot.path
        relaunch(with: fixture)

        let projects = app.buttons["tab-projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 8))
        projects.click()
        let relink = app.buttons["project-relink"]
        XCTAssertTrue(relink.waitForExistence(timeout: 5))
        makeHittable(relink)
        relink.click()

        let reconcile = app.buttons["project-relink-reconcile"]
        XCTAssertTrue(reconcile.waitForExistence(timeout: 5))
        XCTAssertEqual(fixture.relinkRequestCount, 1)
        XCTAssertEqual(fixture.projectGeneration, 4)
        makeHittable(reconcile)
        captureGraphite("projects-relink-rejection-pending-reconciliation")
        reconcile.click()

        XCTAssertTrue(waitUntil(timeout: 8) {
            fixture.relinkRequestCount == 2
                && fixture.projectGeneration == 5
                && fixture.projectRoot == selectedRoot.standardizedFileURL.path
        })
        XCTAssertEqual(fixture.mutationAuthorizationCount, 2)
        let notice = app.descendants(matching: .any)["operator-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(element(notice, contains: "generation 5"))
        XCTAssertFalse(reconcile.exists)
        captureGraphite("projects-relink-rejection-reconciled")
    }

    func testToolPermissionCatalogSupportsMixedKeyboardAndSavedProjectDefaults() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        openProjectRuns()
        let start = app.buttons["autonomy-start"]
        XCTAssertTrue(waitForEnabled(start, timeout: 5))
        start.click()
        let customize = app.buttons["run-tools-customize"]
        XCTAssertTrue(customize.waitForExistence(timeout: 5))
        customize.click()

        let read = app.checkBoxes["run-tool-fs_read"]
        let fileCategory = app.checkBoxes["run-tools-category-files"]
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        XCTAssertTrue(fileCategory.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForCheckboxState(.off, on: read))

        read.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.selectedToolIDs == ["fs_read"]
                && fixture.toolPermissionUpdateCount == 1
        })
        XCTAssertTrue(waitForCheckboxState(.on, on: read))
        XCTAssertTrue(
            waitForCheckboxState(.mixed, on: fileCategory),
            "One of two file tools should publish mixed state"
        )

        read.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.selectedToolIDs.isEmpty
                && fixture.toolPermissionUpdateCount == 2
        })
        XCTAssertTrue(waitForCheckboxState(.off, on: read))
        XCTAssertTrue(waitForCheckboxState(.off, on: fileCategory))

        let allowAll = app.checkBoxes["run-tools-allow-all"]
        XCTAssertTrue(allowAll.waitForExistence(timeout: 5))
        allowAll.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.toolSelectionMode == "all_eligible"
                && fixture.toolPermissionUpdateCount == 3
        })
        XCTAssertTrue(waitForCheckboxState(.on, on: allowAll))

        let selectNone = app.buttons["run-tools-select-none"]
        XCTAssertTrue(selectNone.waitForExistence(timeout: 5))
        selectNone.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.toolSelectionMode == "explicit"
                && fixture.selectedToolIDs.isEmpty
                && fixture.toolPermissionUpdateCount == 4
        })

        let recommended = app.buttons["run-tools-restore-recommended"]
        recommended.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.toolSelectionMode == "recommended"
                && fixture.toolPermissionUpdateCount == 5
        })
        app.buttons["run-tools-done"].click()
        app.buttons["run-start-cancel"].click()
        app.terminate()
        app.launch()
        openProjectRuns()
        let reopenedStart = app.buttons["autonomy-start"]
        XCTAssertTrue(waitForEnabled(reopenedStart, timeout: 5))
        reopenedStart.click()
        app.buttons["run-tools-customize"].click()
        XCTAssertTrue(app.checkBoxes["run-tool-fs_read"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForCheckboxState(.on, on: app.checkBoxes["run-tool-fs_read"]))
        XCTAssertEqual(fixture.toolSelectionMode, "recommended")
    }

    func testUncertainStartReusesExactClientRunIdentityDuringReconciliation() throws {
        let fixture = try OperatorManagerUITestFixture(failStartResponse: true)
        relaunch(with: fixture)

        openProjectRuns()

        let start = app.buttons["autonomy-start"]
        XCTAssertTrue(waitForEnabled(start, timeout: 5))
        start.click()

        let mission = app.descendants(matching: .any)["run-start-mission"]
        XCTAssertTrue(mission.waitForExistence(timeout: 5))
        mission.click()
        mission.typeText("Continue the fixture mission")

        app.buttons["run-tools-customize"].click()
        let projectMemory = app.checkBoxes["run-tool-project_memory.search"]
        XCTAssertTrue(projectMemory.waitForExistence(timeout: 5))
        projectMemory.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.selectedToolIDs == ["project_memory.search"]
        })
        app.buttons["run-tools-done"].click()

        let confirm = app.buttons["run-start-confirm"]
        XCTAssertTrue(waitForEnabled(confirm, timeout: 3))
        confirm.click()

        let reconcile = app.buttons["run-start-reconcile"]
        XCTAssertTrue(reconcile.waitForExistence(timeout: 5))
        XCTAssertEqual(fixture.startRequestCount, 1)
        XCTAssertFalse(confirm.isEnabled, "An uncertain accepted start must block a second request")

        reconcile.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["autonomy-run-row-\(fixture.acceptedStartRunID)"]
                .waitForExistence(timeout: 5),
            "The reconciled response must expose the exact run accepted before the lost response"
        )
        XCTAssertEqual(fixture.startRequestCount, 2)
        XCTAssertEqual(
            Set(fixture.startRequestRunIDs).count,
            1,
            "Reconciliation must replay only the original client-generated run identity"
        )
        XCTAssertEqual(
            Set(fixture.startRequestBodies).count,
            1,
            "Reconciliation must replay the exact retained request body"
        )
        XCTAssertEqual(
            fixture.mutationAuthorizationCount,
            4,
            "Artifact publication, the typed permission update, and both identical start submissions must be authorized"
        )
        XCTAssertTrue(app.staticTexts["Instruction artifact is registered"].exists)
        XCTAssertFalse(app.buttons["run-import-native-policy"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)["run-completion-advanced-toggle"].exists,
            "Autonomy must not expose Forge-owned completion-policy controls"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["run-completion-requirements-read-only"]
                .waitForExistence(timeout: 5),
            "Run completion requirements must remain visible as a read-only record"
        )
    }

    func testAutonomyBlockedAndProviderWaitingStatesExplainRecoveryWithoutErrorPayloads() throws {
        let blockedFixture = try OperatorManagerUITestFixture(
            initialRunState: "blocked_configuration"
        )
        relaunch(with: blockedFixture)

        openProjectRuns()

        XCTAssertTrue(
            app.descendants(matching: .any)["run-recovery-summary"]
                .waitForExistence(timeout: 5),
            "A blocked run must explain recovery even without an error code or summary"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["run-blocked-automatic-recovery"].exists
        )
        XCTAssertFalse(app.buttons["run-recovery-open-projects"].exists)
        XCTAssertFalse(app.buttons["run-recovery-open-provider"].exists)
        XCTAssertFalse(app.buttons["run-import-native-policy"].exists)

        let providerFixture = try OperatorManagerUITestFixture(
            initialRunState: "waiting_provider"
        )
        relaunch(with: providerFixture)
        openProjectRuns()

        XCTAssertTrue(
            app.descendants(matching: .any)["run-recovery-summary"]
                .waitForExistence(timeout: 5),
            "A provider wait must explain recovery even without an error code or summary"
        )
        XCTAssertTrue(app.buttons["run-failure-open-provider"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["run-provider-connect-and-check-guidance"]
                .exists,
            "Provider recovery must direct the user to Connect and Check"
        )
    }

    func testOrdinaryStartHasNoRawTechnicalEditors() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        openProjectRuns()

        let start = app.buttons["autonomy-start"]
        XCTAssertTrue(waitForEnabled(start, timeout: 5))
        start.click()

        let mission = app.descendants(matching: .any)["run-start-mission"]
        XCTAssertTrue(mission.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["run-start-tool-policy"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["run-start-completion-gates"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["run-start-provider"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["run-start-adapter"].exists)

        let customize = app.buttons["run-start-customize"]
        XCTAssertTrue(customize.waitForExistence(timeout: 5))
        customize.click()
        XCTAssertTrue(app.descendants(matching: .any)["run-start-model-picker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["run-start-task-label"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["run-start-network"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["run-failure-behavior"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["run-retry-limit"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["run-failure-instructions"].exists)

        app.buttons["run-tools-customize"].click()
        XCTAssertTrue(app.checkBoxes["run-tools-allow-all"].waitForExistence(timeout: 5))
        app.buttons["run-tools-done"].click()

        let completionChecks = app.checkBoxes["run-completion-view"]
        XCTAssertTrue(completionChecks.waitForExistence(timeout: 5))
        makeHittable(completionChecks)
        XCTAssertTrue(waitForCheckboxState(.on, on: completionChecks),
                      "Completion options must be visible when setup opens")
        completionChecks.click()
        XCTAssertTrue(waitForCheckboxState(.off, on: completionChecks))
        completionChecks.click()
        XCTAssertTrue(
            waitForCheckboxState(.on, on: completionChecks),
            "Show completion checks must expand from the whole native control"
        )
        let buildableProject = app.checkBoxes[
            "run-completion-check-forge.completion.buildable-project"
        ]
        let completionScroll = app.scrollViews
            .containing(.any, identifier: completionChecks.identifier)
            .allElementsBoundByIndex
            .last ?? app.scrollViews.firstMatch
        for _ in 0..<6 where !buildableProject.exists {
            completionScroll.swipeUp()
        }
        XCTAssertTrue(
            buildableProject.waitForExistence(timeout: 5),
            "Opening Completion checks must expose selectable checkboxes:\n\(app.debugDescription)"
        )
        makeHittable(buildableProject)
        XCTAssertTrue(waitForCheckboxState(.on, on: buildableProject))
        buildableProject.click()
        XCTAssertTrue(
            waitForCheckboxState(.off, on: buildableProject),
            "Completion checks must be selectable, not presentation-only"
        )
        XCTAssertTrue(
            waitUntil(timeout: 3) {
                completionChecks.label.localizedCaseInsensitiveContains("4 selected")
            },
            "Completion summary must update after deselecting a check"
        )
        buildableProject.click()
        XCTAssertTrue(waitForCheckboxState(.on, on: buildableProject))
        XCTAssertTrue(app.staticTexts["Instruction artifact is registered"].exists)
        app.buttons["run-completion-done"].click()
        XCTAssertTrue(
            waitForCheckboxState(.off, on: completionChecks),
            "Done must collapse the inline completion-check editor"
        )
        app.buttons["run-start-cancel"].click()

        XCTAssertEqual(fixture.startRequestCount, 0)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 0)
    }

    func testExistingInstructionPackageEnablesStartWithoutQuickText() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        openProjectRuns()
        let start = app.buttons["autonomy-start"]
        XCTAssertTrue(waitForEnabled(start, timeout: 5))
        start.click()

        let package = app.checkBoxes["run-start-package-\(fixture.instructionPackageID)"]
        XCTAssertTrue(package.waitForExistence(timeout: 5))
        let mission = app.descendants(matching: .any)["run-start-mission"]
        XCTAssertTrue(mission.exists)
        package.click()
        let selectedCount = app.descendants(matching: .any)["run-start-package-selection-count"]
        XCTAssertTrue(selectedCount.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForEnabled(app.buttons["run-start-confirm"], timeout: 3))
        app.buttons["run-start-cancel"].click()

        XCTAssertEqual(fixture.startRequestCount, 0)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 0)
    }

    func testCollapsedNavigationCanBeRestored() throws {
        try showWorkbenchControls(["navigation"])
        let toggle = app.buttons["toolbar-navigation"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "Navigation header control should always remain available")

        toggle.click() // collapse
        XCTAssertTrue(toggle.exists, "Navigation toggle must remain available while navigation is hidden")
        toggle.click() // restore

        let rigByID = app.buttons["tab-rig"]
        let rigByLabel = app.staticTexts["Dashboard"]
        XCTAssertTrue(
            rigByID.waitForExistence(timeout: 3) || rigByLabel.waitForExistence(timeout: 3),
            "Navigation should reappear after using the header control"
        )
    }

    func testHundredGaugeNavigationCyclesQuiesce() throws {
        let rig = app.buttons["tab-rig"]
        let mcp = app.buttons["tab-mcp"]
        XCTAssertTrue(rig.waitForExistence(timeout: 8))
        XCTAssertTrue(mcp.waitForExistence(timeout: 8))

        for cycle in 0..<100 {
            mcp.click()
            XCTAssertTrue(app.descendants(matching: .any)["detail-mcp"].waitForExistence(timeout: 2))
            rig.click()
            XCTAssertTrue(
                app.descendants(matching: .any)["detail-rig"].waitForExistence(timeout: 2),
                "Gauge screen did not return on cycle \(cycle)"
            )
        }
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    private func resizeMainWindowToMinimum(_ window: XCUIElement) {
        let initialFrame = window.frame
        if initialFrame.width <= 1_120, initialFrame.height <= 840 {
            assertGraphiteMinimumContent(in: window)
            return
        }
        let handle = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.998, dy: 0.998)
        )
        handle.click(
            forDuration: 0.2,
            thenDragTo: handle.withOffset(CGVector(dx: -800, dy: -600))
        )
        XCTAssertTrue(
            waitUntil(timeout: 3) {
                window.frame.width <= 1_120
                    && window.frame.height <= 840
            },
            "The resizable main window did not reach its minimum-size boundary"
        )
        XCTAssertLessThanOrEqual(window.frame.width, 1_120)
        XCTAssertLessThanOrEqual(window.frame.height, 840)
        assertGraphiteMinimumContent(in: window)
    }

    private func assertGraphiteMinimumContent(in window: XCUIElement) {
        let content = app.descendants(matching: .any)["root-split"]
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertEqual(window.frame.width, 1_100, accuracy: 3)
        XCTAssertEqual(content.frame.height, 720, accuracy: 3)
    }

    private func resizeMainWindowForWideGrid(_ window: XCUIElement) {
        guard window.frame.width < 1_380 else { return }
        let windowMenu = app.menuBars.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.exists)
        windowMenu.click()
        let zoom = app.menuItems["Zoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 3))
        zoom.click()
        XCTAssertTrue(
            waitUntil(timeout: 3) { window.frame.width >= 1_350 },
            "Dashboard could not enter the normal-width two-column layout"
        )
    }

    private func largestScrollView() -> XCUIElement? {
        app.scrollViews.allElementsBoundByIndex
            .filter { $0.exists }
            .max { lhs, rhs in
                lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }
    }

    private func frameIsContained(
        _ child: CGRect,
        in parent: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        child.minX >= parent.minX - tolerance
            && child.minY >= parent.minY - tolerance
            && child.maxX <= parent.maxX + tolerance
            && child.maxY <= parent.maxY + tolerance
    }

    private func relaunch(with fixture: OperatorManagerUITestFixture) {
        app.terminate()
        operatorFixture?.stop()
        operatorFixture = fixture
        app.launchEnvironment["FORGE_OPERATOR_UI_TEST_PORT"] = String(fixture.port)
        app.launch()
    }

    private func refreshOperator() {
        let refresh = app.buttons["operator-refresh"]
        XCTAssertTrue(waitForEnabled(refresh, timeout: 5))
        makeHittable(refresh)
        refresh.click()
    }

    private func openProjectRuns() {
        let projects = app.buttons["tab-projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 8))
        projects.click()
        let runDetails = app.buttons["project-run-details"]
        XCTAssertTrue(runDetails.waitForExistence(timeout: 5))
        makeHittable(runDetails)
        runDetails.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["detail-autonomy"].waitForExistence(timeout: 5),
            "Project Runs must open from the selected project's instruction controls"
        )
    }

    private func waitForValue(_ value: String, on element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForToggleState(
        _ expected: Bool,
        on element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        waitUntil(timeout: timeout) {
            if let number = element.value as? NSNumber {
                return number.boolValue == expected
            }
            guard let raw = element.value as? String else { return false }
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let observed: Bool?
            switch normalized {
            case "1", "true", "on", "yes": observed = true
            case "0", "false", "off", "no": observed = false
            default: observed = nil
            }
            return observed == expected
        }
    }

    private enum CheckboxState {
        case off
        case mixed
        case on
    }

    private func waitForCheckboxState(
        _ expected: CheckboxState,
        on element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        waitUntil(timeout: timeout) {
            let observed: CheckboxState?
            if let number = element.value as? NSNumber {
                switch number.intValue {
                case 0: observed = .off
                case 1: observed = .on
                case -1, 2: observed = .mixed
                default: observed = nil
                }
            } else if let raw = element.value as? String {
                switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "0", "false", "off", "no": observed = .off
                case "1", "true", "on", "yes": observed = .on
                case "-1", "2", "mixed": observed = .mixed
                default: observed = nil
                }
            } else {
                observed = nil
            }
            return observed == expected
        }
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func makeGraphiteSetupReviewScopeVisible() throws {
        let sheet = app.sheets.firstMatch
        let picker = sheet.popUpButtons["guided-setup-project-selection"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let panel = try XCTUnwrap(sheet.groups
            .containing(.popUpButton, identifier: "guided-setup-project-selection")
            .allElementsBoundByIndex.last)
        let scrollView = try XCTUnwrap(sheet.scrollViews
            .containing(.popUpButton, identifier: "guided-setup-project-selection")
            .allElementsBoundByIndex.last)
        for _ in 0..<12 where !frameIsContained(panel.frame, in: scrollView.frame, tolerance: 2) {
            let distance = panel.frame.midY - scrollView.frame.midY
            scrollView.scroll(byDeltaX: 0, deltaY: -min(360, max(-360, distance)))
        }
        XCTAssertTrue(frameIsContained(panel.frame, in: scrollView.frame, tolerance: 2))
        XCTAssertTrue(frameIsContained(panel.frame, in: sheet.frame, tolerance: 2))
        XCTAssertTrue(panel.staticTexts["Project to review"].exists)
        let identity = panel.staticTexts["guided-setup-review-project-identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        XCTAssertTrue(frameIsContained(identity.frame, in: scrollView.frame, tolerance: 2))
        XCTAssertTrue(picker.isHittable)
        XCTAssertEqual(picker.value as? String, "Fixture Project")
    }

    private func makeHittable(_ element: XCUIElement, in owner: XCUIElement? = nil) {
        let selectorIdentity = !element.identifier.isEmpty ? element.identifier
            : !element.label.isEmpty ? element.label : element.value as? String ?? ""
        let containingScrollViews = (owner ?? app).scrollViews
            .containing(NSPredicate(
                format: "identifier == %@ OR label == %@ OR value == %@",
                selectorIdentity, selectorIdentity, selectorIdentity
            ))
            .allElementsBoundByIndex
        let explicitScrollOwner = owner?.elementType == .scrollView ? owner : nil
        if !selectorIdentity.isEmpty, let scrollView = containingScrollViews.last ?? explicitScrollOwner {
            for _ in 0..<12 where !element.isHittable
                || !frameIsContained(element.frame, in: scrollView.frame, tolerance: 2) {
                let distance = element.frame.midY - scrollView.frame.midY
                scrollView.scroll(byDeltaX: 0, deltaY: -min(360, max(-360, distance)))
            }
        }
        XCTAssertTrue(element.isHittable)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}

private final class OperatorManagerUITestFixture: @unchecked Sendable {
    private static let maximumRequestBytes = 64 * 1_024

    struct ProviderProbeRecord: Equatable {
        let adapterID: String
        let mode: String
    }

    struct ProviderIntegrationMutationRecord: Equatable {
        let kind: String
        let providerID: String
        let expectedRevision: String
        let idempotencyKey: String
    }

    let projectID = "11111111-1111-4111-8111-111111111111"
    let runID = "22222222-2222-4222-8222-222222222222"
    let runtimeJobID = "33333333-3333-4333-8333-333333333333"
    let instructionPackageID = "44444444-4444-4444-8444-444444444444"
    let secondInstructionPackageID = "45454545-4545-4545-8545-454545454545"
    let policyEventID = "55555555-5555-4555-8555-555555555555"
    let continuityOperationID = "99999999-9999-4999-8999-999999999999"
    let continuityEventID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let continuityCheckpointID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let continuityHandoffID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "forge.operator-ui-fixture")
    private let lock = NSLock()
    private let failStartResponse: Bool
    private let failContractProbe: Bool
    private let dropRelinkResponseCount: Int
    private let rejectFirstRelinkResponse: Bool
    private let includeContinuityOperation: Bool
    private let continuityOperationState: String
    private let includePolicyDetails: Bool
    private let includePagedEvidence: Bool
    private var remainingInstructionCatalogFailures: Int
    private var remainingEvidencePageFailures: Int
    private var mutableEvidencePageRequestCount = 0
    private var mutableLastEvidenceCursor: String?
    private let managerVersion: String
    private var mutableRunState: String
    private var mutableDeletedRun = false
    private var mutableDeletionRequestCount = 0
    private var mutableStartRequestCount = 0
    private var mutableControlRequestCount = 0
    private var mutableMutationAuthorizationCount = 0
    private var mutableStartRequestRunIDs: [String] = []
    private var mutableStartRequestBodies: [Data] = []
    private var mutableControlActions: [String] = []
    private var mutableRejectNextContinuityCommand = false
    private var mutableContinuityOperationCleared = false
    private var mutableContinuityHistoryClearScopes: [String] = []
    private var mutableContinuityPacketIDs: [String] = []
    private var mutableContinuityPacketListRequestCount = 0
    private var mutableLastContinuityPacketDeletionBody: Data?
    private var mutableAcceptedStart = false
    private var mutableAcceptedStartRunID: String?
    private var mutableShellEnabled = true
    private var mutableAllowedRoots: [String] = []
    private var mutableSettingsUpdateCount = 0
    private var mutableProjectRoot = "/tmp/forge-operator-fixture"
    private var mutableProjectGeneration: UInt64 = 4
    private var mutableRelinkRequestCount = 0
    private var mutableProviderProbeRecords: [ProviderProbeRecord] = []
    private var mutableProviderProbeBodies: [Data] = []
    private var mutableProviderProbeAuthorizationCount = 0
    private var mutableProviderConfigurationSaveCount = 0
    private var mutableProviderConfigurationRevision = "0"
    private var mutableProviderConfiguredModel = ""
    private var mutableProviderConfiguredEndpoint = "http://127.0.0.1:1234"
    private let providerLinkedNodeID: UUID?
    private let reportedProviderEndpoint: String?
    private var mutableProviderHealth = "healthy"
    private var mutableProviderLastProbeMode: String?
    private var mutableProviderLastProbeError: String?
    private var mutableProviderLastProbeAt: String?
    private var mutableProviderPreparationCount = 0
    private var mutableProviderPreparationAuthorizationCount = 0
    private var mutableProviderPreparationResumeWaitingRuns: [Bool] = []
    private var mutableProviderIntegrationRevision = 1
    private var mutableConfiguredProviderIntegrationIDs: Set<String> = []
    private var mutableProviderIntegrationMutationRecords: [ProviderIntegrationMutationRecord] = []
    private var mutableProviderIntegrationMutationAuthorizationCount = 0
    private var mutableProviderSelectionRequestCount = 0
    private var mutableProviderModelRequestCount = 0
    private var mutableProviderIntegrationDeletionRequestCount = 0
    private let includePendingProviderOperation: Bool
    let pendingProviderOperationID = "67676767-6767-4676-8676-676767676767"
    private var mutablePendingProviderOperationCancelled = false
    private var mutableProviderOperationPollRequestCount = 0
    private var mutableProviderOperationCancellationIDs: [String] = []
    private var mutableProviderOperationCancellationBodies: [Data] = []
    private var mutableProviderOperationCancellationAuthorizationCount = 0
    private var mutableRuntimeJobState = "queued"
    private var mutableOperatorSnapshotRequestCount = 0
    private var mutableLastOperatorSnapshotRuntimeState: String?
    private var mutableRuntimeCancellationJobIDs: [String] = []
    private var mutableRuntimeCancellationBodies: [Data] = []
    private var mutableRuntimeCancellationAuthorizationCount = 0
    private var mutableRejectNextRuntimeCancellation = false
    private var mutableToolPreferenceRevision: UInt64 = 0
    private var mutableToolSelectionMode = "explicit"
    private var mutableSelectedToolIDs: [String] = []
    private var mutableToolPermissionUpdateCount = 0
    private var mutableActivityRequestCount = 0
    private var mutablePolicySnapshotRequestCount = 0
    private var mutableScopedPolicySnapshotRequestCount = 0
    private var mutablePolicyViolationRequestCount = 0
    private var mutableInstructionQueueRevision: UInt64
    private var mutableInstructionQueueRunning: Bool
    private var mutableInstructionPackageIDs: [String]
    private var mutableInstructionPackageStates: [String: String]
    private var mutableInstructionQueueStopRequestCount = 0
    private var mutableInstructionQueueReorderRequestCount = 0
    private var mutableInstructionQueueRemoveRequestCount = 0
    private var mutableInstructionQueueStatusRequestCount = 0
    private var mutableInstructionCatalogRequestCount = 0
    private let supportedProviderIntegrationIDs: Set<String> = [
        "lmstudio",
        "claude-desktop",
        "codex-desktop",
        "grok-build",
    ]
    private(set) var port: UInt16 = 0

    private var providerIntegrationRevision: String {
        "provider-revision-\(mutableProviderIntegrationRevision)"
    }

    var startRequestCount: Int { locked { mutableStartRequestCount } }
    var controlRequestCount: Int { locked { mutableControlRequestCount } }
    var deletionRequestCount: Int { locked { mutableDeletionRequestCount } }
    var mutationAuthorizationCount: Int { locked { mutableMutationAuthorizationCount } }
    var startRequestRunIDs: [String] { locked { mutableStartRequestRunIDs } }
    var startRequestBodies: [Data] { locked { mutableStartRequestBodies } }
    var controlActions: [String] { locked { mutableControlActions } }
    var continuityHistoryClearScopes: [String] {
        locked { mutableContinuityHistoryClearScopes }
    }
    var continuityPacketIDs: [String] { locked { mutableContinuityPacketIDs } }
    var continuityPacketListRequestCount: Int { locked { mutableContinuityPacketListRequestCount } }
    var lastContinuityPacketDeletionBody: Data? { locked { mutableLastContinuityPacketDeletionBody } }
    var acceptedStartRunID: String { locked { mutableAcceptedStartRunID ?? "" } }
    var shellEnabled: Bool { locked { mutableShellEnabled } }
    var allowedRoots: [String] { locked { mutableAllowedRoots } }
    var settingsUpdateCount: Int { locked { mutableSettingsUpdateCount } }
    var projectRoot: String { locked { mutableProjectRoot } }
    var projectGeneration: UInt64 { locked { mutableProjectGeneration } }
    var relinkRequestCount: Int { locked { mutableRelinkRequestCount } }
    var providerConfigurationSaveCount: Int { locked { mutableProviderConfigurationSaveCount } }
    var providerConfiguredModel: String { locked { mutableProviderConfiguredModel } }
    var providerProbeRecords: [ProviderProbeRecord] { locked { mutableProviderProbeRecords } }
    var providerProbeBodies: [Data] { locked { mutableProviderProbeBodies } }
    var providerProbeAuthorizationCount: Int {
        locked { mutableProviderProbeAuthorizationCount }
    }
    var providerPreparationCount: Int {
        locked { mutableProviderPreparationCount }
    }
    var providerPreparationAuthorizationCount: Int {
        locked { mutableProviderPreparationAuthorizationCount }
    }
    var providerPreparationResumeWaitingRuns: [Bool] {
        locked { mutableProviderPreparationResumeWaitingRuns }
    }
    var providerIntegrationMutationRecords: [ProviderIntegrationMutationRecord] {
        locked { mutableProviderIntegrationMutationRecords }
    }
    var providerIntegrationMutationAuthorizationCount: Int {
        locked { mutableProviderIntegrationMutationAuthorizationCount }
    }
    var providerSelectionRequestCount: Int { locked { mutableProviderSelectionRequestCount } }
    var providerModelRequestCount: Int { locked { mutableProviderModelRequestCount } }
    var providerIntegrationDeletionRequestCount: Int {
        locked { mutableProviderIntegrationDeletionRequestCount }
    }
    var providerOperationPollRequestCount: Int { locked { mutableProviderOperationPollRequestCount } }
    var providerOperationCancellationIDs: [String] { locked { mutableProviderOperationCancellationIDs } }
    var providerOperationCancellationBodies: [Data] { locked { mutableProviderOperationCancellationBodies } }
    var providerOperationCancellationAuthorizationCount: Int {
        locked { mutableProviderOperationCancellationAuthorizationCount }
    }
    var runtimeCancellationJobIDs: [String] { locked { mutableRuntimeCancellationJobIDs } }
    var runtimeCancellationBodies: [Data] { locked { mutableRuntimeCancellationBodies } }
    var runtimeCancellationAuthorizationCount: Int {
        locked { mutableRuntimeCancellationAuthorizationCount }
    }
    var selectedToolIDs: [String] { locked { mutableSelectedToolIDs } }
    var toolSelectionMode: String { locked { mutableToolSelectionMode } }
    var toolPermissionUpdateCount: Int { locked { mutableToolPermissionUpdateCount } }
    var activityRequestCount: Int { locked { mutableActivityRequestCount } }
    var policySnapshotRequestCount: Int { locked { mutablePolicySnapshotRequestCount } }
    var scopedPolicySnapshotRequestCount: Int {
        locked { mutableScopedPolicySnapshotRequestCount }
    }
    var policyViolationRequestCount: Int { locked { mutablePolicyViolationRequestCount } }
    var instructionQueueRunning: Bool { locked { mutableInstructionQueueRunning } }
    var instructionPackageIDs: [String] { locked { mutableInstructionPackageIDs } }
    var instructionPackageStates: [String: String] {
        locked { mutableInstructionPackageStates }
    }
    var instructionQueueStopRequestCount: Int {
        locked { mutableInstructionQueueStopRequestCount }
    }
    var instructionQueueReorderRequestCount: Int {
        locked { mutableInstructionQueueReorderRequestCount }
    }
    var instructionQueueRemoveRequestCount: Int {
        locked { mutableInstructionQueueRemoveRequestCount }
    }
    var instructionQueueStatusRequestCount: Int {
        locked { mutableInstructionQueueStatusRequestCount }
    }
    var instructionCatalogRequestCount: Int { locked { mutableInstructionCatalogRequestCount } }
    var evidencePageRequestCount: Int { locked { mutableEvidencePageRequestCount } }
    var lastEvidenceCursor: String? { locked { mutableLastEvidenceCursor } }

    private var providerEndpointMode: [String: Any] {
        guard let providerLinkedNodeID else { return ["mode": "local"] }
        return [
            "mode": "linked",
            "node_id": providerLinkedNodeID.uuidString.lowercased(),
        ]
    }

    init(
        failStartResponse: Bool = false,
        failContractProbe: Bool = false,
        dropFirstRelinkResponse: Bool = false,
        dropRelinkResponseCount: Int = 0,
        rejectFirstRelinkResponse: Bool = false,
        initialRunState: String = "running",
        includeContinuityOperation: Bool = false,
        continuityOperationState: String = "awaiting_durable_acknowledgement",
        activeInstructionQueue: Bool = false,
        includeSecondInstructionPackage: Bool = false,
        failFirstInstructionCatalog: Bool = false,
        includePagedEvidence: Bool = false,
        failFirstEvidencePage: Bool = false,
        includePolicyDetails: Bool = false,
        providerEndpoint: String = "http://127.0.0.1:1234",
        initialProviderHealth: String = "healthy",
        includePendingProviderOperation: Bool = false,
        providerLinkedNodeID: UUID? = nil,
        reportedProviderEndpoint: String? = nil
    ) throws {
        self.failStartResponse = failStartResponse
        self.includePendingProviderOperation = includePendingProviderOperation
        self.providerLinkedNodeID = providerLinkedNodeID
        self.reportedProviderEndpoint = reportedProviderEndpoint
        self.failContractProbe = failContractProbe
        self.dropRelinkResponseCount = max(
            dropRelinkResponseCount,
            dropFirstRelinkResponse ? 1 : 0
        )
        self.rejectFirstRelinkResponse = rejectFirstRelinkResponse
        self.includeContinuityOperation = includeContinuityOperation
        self.continuityOperationState = continuityOperationState
        self.includePolicyDetails = includePolicyDetails
        self.includePagedEvidence = includePagedEvidence
        self.remainingInstructionCatalogFailures = failFirstInstructionCatalog ? 1 : 0
        self.remainingEvidencePageFailures = failFirstEvidencePage ? 1 : 0
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        managerVersion = try String(
            contentsOf: repositoryRoot.appendingPathComponent("VERSION"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        mutableProviderConfiguredEndpoint = providerEndpoint
        mutableProviderHealth = initialProviderHealth
        mutableContinuityPacketIDs = includeContinuityOperation
            ? [
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            ]
            : []
        mutableRunState = initialRunState
        mutableInstructionQueueRevision = 1
        mutableInstructionQueueRunning = activeInstructionQueue
        mutableInstructionPackageIDs = activeInstructionQueue || includeSecondInstructionPackage
            ? [
                "44444444-4444-4444-8444-444444444444",
                "45454545-4545-4545-8545-454545454545",
            ]
            : ["44444444-4444-4444-8444-444444444444"]
        mutableInstructionPackageStates = activeInstructionQueue
            ? [
                "44444444-4444-4444-8444-444444444444": "running",
                "45454545-4545-4545-8545-454545454545": "queued",
            ]
            : Dictionary(
                uniqueKeysWithValues: mutableInstructionPackageIDs.map { ($0, "queued") }
            )
        listener = try NWListener(using: .tcp, on: .any)

        let ready = DispatchSemaphore(value: 0)
        let startup = StartupState()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startup.record(error)
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 3) == .success else {
            listener.cancel()
            throw FixtureError.startup("Timed out binding the operator fixture")
        }
        if let startupError = startup.error {
            listener.cancel()
            throw FixtureError.startup(startupError.localizedDescription)
        }
        guard let boundPort = listener.port else {
            listener.cancel()
            throw FixtureError.startup("The operator fixture did not publish a port")
        }
        port = boundPort.rawValue
    }

    func stop() {
        listener.cancel()
    }

    func completeContinuityCycle() {
        locked {
            mutableRunState = "running"
        }
    }

    func rejectNextContinuityCommand() {
        locked {
            mutableRejectNextContinuityCommand = true
        }
    }

    func setRuntimeJobState(_ state: String) {
        locked {
            mutableRuntimeJobState = state
        }
    }

    var operatorSnapshotRequestCount: Int { locked { mutableOperatorSnapshotRequestCount } }
    var lastOperatorSnapshotRuntimeState: String? { locked { mutableLastOperatorSnapshotRuntimeState } }

    func rejectNextRuntimeCancellation() {
        locked {
            mutableRejectNextRuntimeCancellation = true
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(from: connection, accumulated: Data())
    }

    private func receive(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) { [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var request = accumulated
            if let data { request.append(data) }
            guard request.count <= Self.maximumRequestBytes else {
                respond(status: 413, object: ["message": "fixture request exceeded bound"], to: connection)
                return
            }
            if let parsed = parse(request) {
                route(parsed, connection: connection)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                receive(from: connection, accumulated: request)
            }
        }
    }

    private func parse(_ data: Data) -> (
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        headers: [String: String],
        body: Data
    )? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else {
            return nil
        }
        let headers = String(decoding: data[..<headerRange.lowerBound], as: UTF8.self)
        let headerLines = headers.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first, !requestLine.isEmpty else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var parsedHeaders: [String: String] = [:]
        for line in headerLines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            parsedHeaders[String(pieces[0]).lowercased()] = pieces[1]
                .trimmingCharacters(in: .whitespaces)
        }
        let contentLength = headerLines
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { line in
                line.split(separator: ":", maxSplits: 1)
                    .dropFirst()
                    .first
                    .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
            ?? 0
        let bodyStart = headerRange.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= contentLength else { return nil }
        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
            return nil
        }
        return (
            String(parts[0]),
            components.path,
            components.queryItems ?? [],
            parsedHeaders,
            Data(data[bodyStart..<bodyEnd])
        )
    }

    private func route(
        _ request: (
            method: String,
            path: String,
            queryItems: [URLQueryItem],
            headers: [String: String],
            body: Data
        ),
        connection: NWConnection
    ) {
        locked {
            if request.path == "/api/manager/providers/selection" {
                mutableProviderSelectionRequestCount += 1
            }
            if request.path == "/api/manager/provider/models" {
                mutableProviderModelRequestCount += 1
            }
            if request.method == "DELETE", request.path.hasSuffix("/integration") {
                mutableProviderIntegrationDeletionRequestCount += 1
            }
        }
        switch request.path {
        case "/api/manager/status":
            respond(status: 200, object: managerStatus(), to: connection)
        case "/api/manager/settings":
            if !request.body.isEmpty {
                guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                      let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                      let patch = object["settings"] as? [String: Any],
                      let shell = patch["shell"] as? [String: Any],
                      let enabled = shell["enabled"] as? Bool,
                      let allowedRoots = patch["allowed_roots"] as? [String] else {
                    respond(status: 401, object: ["message": "missing settings authorization or shell policy"], to: connection)
                    return
                }
                locked {
                    mutableShellEnabled = enabled
                    mutableAllowedRoots = allowedRoots
                    mutableSettingsUpdateCount += 1
                }
            }
            respond(status: 200, object: managerSettings(), to: connection)
        case "/api/manager/operator/snapshot":
            var response = snapshot()
            if includePagedEvidence {
                let cursor = request.queryItems.first(where: { $0.name == "cursor" })?.value
                let expected = cursor.map { ["limit": "100", "cursor": $0] } ?? ["limit": "100"]
                guard request.method == "GET",
                      exactQuery(request.queryItems, equals: expected),
                      cursor == nil || cursor == "101" else {
                    respond(status: 400, object: ["message": "invalid bounded evidence page request"], to: connection)
                    return
                }
                if let cursor {
                    let failPage = locked { () -> Bool in
                        mutableEvidencePageRequestCount += 1
                        mutableLastEvidenceCursor = cursor
                        guard remainingEvidencePageFailures > 0 else { return false }
                        remainingEvidencePageFailures -= 1
                        return true
                    }
                    if failPage {
                        respond(status: 503, object: ["message": "fixture evidence page transport failure"], to: connection)
                        return
                    }
                    response["events"] = [pagedEvidenceEvent(sequence: 100)]
                    response["next_cursor"] = NSNull()
                } else {
                    response["events"] = stride(from: 200, through: 101, by: -1)
                        .map { pagedEvidenceEvent(sequence: Int64($0)) }
                    response["next_cursor"] = "101"
                }
            }
            let jobs = response["runtime_jobs"] as? [[String: Any]]
            locked {
                mutableOperatorSnapshotRequestCount += 1
                mutableLastOperatorSnapshotRuntimeState = jobs?.first?["state"] as? String
            }
            respond(status: 200, object: response, to: connection)
        case "/api/manager/continuity/packets":
            guard request.method == "GET",
                  request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  exactQuery(request.queryItems, equals: ["project_id": projectID]) else {
                respond(status: 401, object: ["message": "missing packet list authority"], to: connection)
                return
            }
            let packets: [[String: Any]] = locked {
                mutableContinuityPacketListRequestCount += 1
                return mutableContinuityPacketIDs.enumerated().map { index, id in
                    [
                        "packet_id": id,
                        "project_id": projectID,
                        "type": index == 0 ? "checkpoint" : "handoff",
                        "source": index == 0 ? "auto" : "model",
                        "timestamp": index == 0
                            ? "2026-09-27T11:59:00Z"
                            : "2026-09-27T12:00:00Z",
                        "resume_ready": index != 0,
                    ]
                }
            }
            respond(status: 200, object: ["project_id": projectID, "packets": packets], to: connection)
        case "/api/manager/continuity/packets/delete":
            guard request.method == "POST",
                  request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  object["project_id"] as? String == projectID,
                  let ids = object["packet_ids"] as? [String],
                  !ids.isEmpty else {
                respond(status: 401, object: ["message": "missing exact packet delete authority"], to: connection)
                return
            }
            let deleted = locked { () -> [String] in
                mutableLastContinuityPacketDeletionBody = request.body
                let visible = Set(mutableContinuityPacketIDs)
                let exact = ids.filter(visible.contains)
                mutableContinuityPacketIDs.removeAll { ids.contains($0) }
                mutableMutationAuthorizationCount += 1
                return exact
            }
            guard deleted.count == ids.count else {
                respond(status: 409, object: ["message": "packet selection changed"], to: connection)
                return
            }
            respond(status: 200, object: [
                "project_id": projectID,
                "deleted_packet_ids": deleted,
                "completed_at": "2026-09-27T12:01:00Z",
            ], to: connection)
        case "/api/manager/continuity/history/clear":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body)
                    as? [String: Any],
                  let scope = object["scope"] as? String,
                  scope == "project",
                  object["project_id"] as? String == projectID else {
                respond(
                    status: 401,
                    object: ["message": "missing exact continuity clear authority"],
                    to: connection
                )
                return
            }
            locked {
                mutableContinuityOperationCleared = true
                mutableContinuityHistoryClearScopes.append(scope)
                mutableMutationAuthorizationCount += 1
            }
            respond(status: 200, object: [
                "scope": scope,
                "requested_project_id": projectID,
                "requested_operation_id": NSNull(),
                "cleared_operation_count": 1,
                "cleared_project_count": 1,
                "deleted_record_count": 5,
                "retained_operation_count": 0,
                "completed_at": "2026-09-27T12:00:00Z",
            ], to: connection)
        case "/api/manager/operator/activity":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  exactQuery(
                    request.queryItems,
                    equals: [
                        "limit": "100",
                        "run_id": runID,
                        "project_id": projectID,
                        "project_generation": String(locked { mutableProjectGeneration }),
                    ]
                  ) else {
                respond(
                    status: 401,
                    object: ["message": "missing activity authority or exact scope"],
                    to: connection
                )
                return
            }
            locked { mutableActivityRequestCount += 1 }
            respond(status: 200, object: snapshot(includeActivity: true), to: connection)
        case "/api/manager/stjornarvald/snapshot":
            let generation = String(locked { mutableProjectGeneration })
            let unscoped = exactQuery(
                request.queryItems,
                equals: ["limit": "100", "order": "newest"]
            )
            let scoped = exactQuery(
                request.queryItems,
                equals: [
                    "limit": "100",
                    "order": "newest",
                    "project_id": projectID,
                    "project_generation": generation,
                ]
            )
            guard unscoped || scoped else {
                respond(status: 400, object: ["message": "invalid policy snapshot scope"], to: connection)
                return
            }
            locked {
                mutablePolicySnapshotRequestCount += 1
                if scoped { mutableScopedPolicySnapshotRequestCount += 1 }
            }
            respond(status: 200, object: policySnapshot(), to: connection)
        case "/api/manager/stjornarvald/violations":
            guard let object = try? JSONSerialization.jsonObject(with: request.body)
                as? [String: Any],
                  (object["cursor"] as? NSNumber)?.int64Value == 0,
                  (object["limit"] as? NSNumber)?.intValue == 100 else {
                respond(status: 400, object: ["message": "invalid violation projection request"], to: connection)
                return
            }
            locked { mutablePolicyViolationRequestCount += 1 }
            respond(
                status: 200,
                object: [
                    "violations": includePolicyDetails ? [policyViolation()] : [],
                    "controlsExecution": false,
                ],
                to: connection
            )
        case "/api/manager/autonomy/status":
            let activeRunIDs = locked {
                mutableDeletedRun || ["completed", "cancelled", "failed_terminal"]
                    .contains(mutableRunState) ? [] : [runID]
            }
            respond(
                status: 200,
                object: [
                    "started": true,
                    "active_run_ids": activeRunIDs,
                    "deferred_run_ids": [],
                ],
                to: connection
            )
        case "/api/manager/projects/status":
            respond(status: 200, object: project(), to: connection)
        case "/api/manager/projects/instruction-packages":
            locked { mutableInstructionQueueStatusRequestCount += 1 }
            respond(status: 200, object: instructionQueue(), to: connection)
        case "/api/manager/projects/instruction-packages/catalog":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  object["project_id"] as? String == projectID,
                  (object["project_generation"] as? NSNumber)?.uint64Value == locked({ mutableProjectGeneration }),
                  let contentSHA = object["content_sha256"] as? String,
                  [String(repeating: "c", count: 64), String(repeating: "d", count: 64)].contains(contentSHA),
                  (object["cursor"] as? NSNumber)?.intValue == 0,
                  (object["limit"] as? NSNumber)?.intValue == 128 else {
                respond(status: 400, object: ["message": "invalid instruction catalog scope"], to: connection)
                return
            }
            let failCatalog = locked { () -> Bool in
                mutableInstructionCatalogRequestCount += 1
                guard remainingInstructionCatalogFailures > 0 else { return false }
                remainingInstructionCatalogFailures -= 1
                return true
            }
            if failCatalog {
                respond(status: 503, object: ["message": "fixture catalog transport failure"], to: connection)
                return
            }
            respond(status: 200, object: [
                "project_id": projectID,
                "project_generation": locked { mutableProjectGeneration },
                "content_sha256": contentSHA,
                "total_documents": 1,
                "cursor": 0,
                "next_cursor": NSNull(),
                "documents": [[
                    "id": "fixture-instruction-document",
                    "source_path": "instructions/Fixture Instructions.md",
                    "status": "converted_instruction",
                    "detail": "Preserved source converted to immutable project-scoped instructions.",
                    "converter": "text",
                    "original_bytes": "128",
                    "original_sha256": contentSHA,
                    "canonical_sha256": contentSHA,
                    "canonical_bytes": "128",
                ]],
            ], to: connection)
        case "/api/manager/projects/instruction-packages/stop":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body)
                    as? [String: Any],
                  object["project_id"] as? String == projectID,
                  (object["project_generation"] as? NSNumber)?.uint64Value
                    == locked({ mutableProjectGeneration }) else {
                respond(status: 401, object: ["message": "missing queue-stop authority"], to: connection)
                return
            }
            let stopped = locked { () -> Bool in
                guard mutableInstructionQueueRunning else { return false }
                mutableInstructionQueueRunning = false
                for packageID in mutableInstructionPackageIDs
                    where mutableInstructionPackageStates[packageID] == "running" {
                    mutableInstructionPackageStates[packageID] = "cancelled"
                }
                mutableInstructionQueueRevision += 1
                mutableInstructionQueueStopRequestCount += 1
                mutableMutationAuthorizationCount += 1
                return true
            }
            guard stopped else {
                respond(status: 409, object: ["message": "instruction queue is not running"], to: connection)
                return
            }
            respond(status: 200, object: instructionQueue(), to: connection)
        case "/api/manager/projects/instruction-packages/reorder":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body)
                    as? [String: Any],
                  object["project_id"] as? String == projectID,
                  (object["project_generation"] as? NSNumber)?.uint64Value
                    == locked({ mutableProjectGeneration }),
                  let expectedRevision = (object["expected_revision"] as? NSNumber)?.uint64Value,
                  let packageIDs = object["package_ids"] as? [String] else {
                respond(status: 401, object: ["message": "missing queue-reorder authority"], to: connection)
                return
            }
            let reordered = locked { () -> Bool in
                guard expectedRevision == mutableInstructionQueueRevision,
                      packageIDs.count == mutableInstructionPackageIDs.count,
                      Set(packageIDs) == Set(mutableInstructionPackageIDs) else { return false }
                mutableInstructionPackageIDs = packageIDs
                mutableInstructionQueueRevision += 1
                mutableInstructionQueueReorderRequestCount += 1
                mutableMutationAuthorizationCount += 1
                return true
            }
            guard reordered else {
                respond(status: 409, object: ["message": "stale queue reorder"], to: connection)
                return
            }
            respond(status: 200, object: instructionQueue(), to: connection)
        case "/api/manager/projects/instruction-packages/remove":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body)
                    as? [String: Any],
                  object["project_id"] as? String == projectID,
                  (object["project_generation"] as? NSNumber)?.uint64Value
                    == locked({ mutableProjectGeneration }),
                  let packageID = object["package_id"] as? String else {
                respond(status: 401, object: ["message": "missing queue-remove authority"], to: connection)
                return
            }
            let removed = locked { () -> Bool in
                guard mutableInstructionPackageStates[packageID] != nil,
                      mutableInstructionPackageStates[packageID] != "running" else { return false }
                mutableInstructionPackageIDs.removeAll { $0 == packageID }
                mutableInstructionPackageStates.removeValue(forKey: packageID)
                mutableInstructionQueueRevision += 1
                mutableInstructionQueueRemoveRequestCount += 1
                mutableMutationAuthorizationCount += 1
                return true
            }
            guard removed else {
                respond(status: 409, object: ["message": "active or missing instruction package"], to: connection)
                return
            }
            respond(status: 200, object: instructionQueue(), to: connection)
        case "/api/manager/projects/tool-permissions/status":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true else {
                respond(status: 401, object: ["message": "missing tool permission authorization"], to: connection)
                return
            }
            respond(status: 200, object: toolPermissionSnapshot(), to: connection)
        case "/api/manager/projects/tool-permissions":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  object["project_id"] as? String == projectID,
                  let generation = (object["project_generation"] as? NSNumber)?.uint64Value,
                  generation == locked({ mutableProjectGeneration }),
                  let expected = (object["expected_preference_revision"] as? NSNumber)?.uint64Value,
                  let mode = object["selection_mode"] as? String,
                  ["recommended", "all_eligible", "explicit"].contains(mode),
                  let selected = object["selected_tool_ids"] as? [String] else {
                respond(status: 401, object: ["message": "missing or invalid tool permission update"], to: connection)
                return
            }
            let updated = locked { () -> Bool in
                guard expected == mutableToolPreferenceRevision else { return false }
                mutableToolPreferenceRevision += 1
                mutableToolSelectionMode = mode
                mutableSelectedToolIDs = mode == "explicit" ? selected.sorted() : []
                mutableToolPermissionUpdateCount += 1
                mutableMutationAuthorizationCount += 1
                return true
            }
            guard updated else {
                respond(status: 409, object: ["message": "stale tool permission revision"], to: connection)
                return
            }
            respond(status: 200, object: toolPermissionSnapshot(), to: connection)
        case "/api/manager/projects/relink":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  Set(object.keys) == ["project_id", "project_generation", "path"],
                  object["project_id"] as? String == projectID,
                  let generation = (object["project_generation"] as? NSNumber)?.uint64Value,
                  let path = object["path"] as? String,
                  !path.isEmpty else {
                respond(status: 401, object: ["message": "missing relink authority or identity"], to: connection)
                return
            }
            let canonicalPath = URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL.path
            let outcome = locked { () -> (status: Int, receipt: [String: Any], drop: Bool) in
                mutableRelinkRequestCount += 1
                mutableMutationAuthorizationCount += 1
                if rejectFirstRelinkResponse, mutableRelinkRequestCount == 1 {
                    return (
                        409,
                        ["message": "fixture rejected the first relink request"],
                        false
                    )
                }
                if generation == mutableProjectGeneration {
                    let prior = mutableProjectGeneration
                    mutableProjectGeneration += 1
                    mutableProjectRoot = canonicalPath
                    return (
                        200,
                        [
                            "project_id": projectID,
                            "canonical_root": mutableProjectRoot,
                            "prior_generation": prior,
                            "new_generation": mutableProjectGeneration,
                            "invalidated_binding_count": 0,
                            "completed_at": "2026-08-31T12:00:00Z",
                            "reconciled": false,
                        ],
                        mutableRelinkRequestCount <= dropRelinkResponseCount
                    )
                }
                let prior = generation
                let next = generation.addingReportingOverflow(1)
                if !next.overflow,
                   next.partialValue == mutableProjectGeneration,
                   canonicalPath == mutableProjectRoot {
                    return (
                        200,
                        [
                            "project_id": projectID,
                            "canonical_root": mutableProjectRoot,
                            "prior_generation": prior,
                            "new_generation": mutableProjectGeneration,
                            "invalidated_binding_count": 0,
                            "completed_at": "2026-08-31T12:00:00Z",
                            "reconciled": true,
                        ],
                        mutableRelinkRequestCount <= dropRelinkResponseCount
                    )
                }
                return (409, ["message": "stale project generation"], false)
            }
            if outcome.drop {
                dropResponseAfterPartialBody(to: connection)
            } else {
                respond(status: outcome.status, object: outcome.receipt, to: connection)
            }
        case "/api/manager/providers":
            guard request.method == "GET", request.body.isEmpty else {
                respond(status: 405, object: ["message": "provider registry is read-only"], to: connection)
                return
            }
            respond(status: 200, object: providerIntegrations(), to: connection)
        case "/api/manager/provider-operations/\(pendingProviderOperationID)":
            guard includePendingProviderOperation, request.method == "GET", request.body.isEmpty else {
                respond(status: 404, object: ["message": "provider operation is unavailable"], to: connection)
                return
            }
            locked { mutableProviderOperationPollRequestCount += 1 }
            respond(status: 200, object: pendingProviderOperation(), to: connection)
        case "/api/manager/provider-operations/\(pendingProviderOperationID)/cancel":
            guard includePendingProviderOperation, request.method == "POST",
                  request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  payload.isEmpty else {
                respond(status: 401, object: ["message": "missing provider cancellation authority or exact payload"], to: connection)
                return
            }
            locked {
                mutablePendingProviderOperationCancelled = true
                mutableProviderOperationCancellationIDs.append(pendingProviderOperationID)
                mutableProviderOperationCancellationBodies.append(request.body)
                mutableProviderOperationCancellationAuthorizationCount += 1
                mutableMutationAuthorizationCount += 1
            }
            respond(status: 200, object: pendingProviderOperation(), to: connection)
        case let path where path.hasPrefix("/api/manager/providers/")
            && path.hasSuffix("/repair"):
            let providerID = String(
                path.dropFirst("/api/manager/providers/".count).dropLast("/repair".count)
            )
            guard request.method == "POST",
                  request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  supportedProviderIntegrationIDs.contains(providerID),
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  Set(object.keys) == ["expected_revision", "provider_id", "idempotency_key"],
                  object["provider_id"] as? String == providerID,
                  let expectedRevision = object["expected_revision"] as? String,
                  expectedRevision == locked({ providerIntegrationRevision }),
                  let idempotencyKey = object["idempotency_key"] as? String,
                  let idempotencyUUID = UUID(uuidString: idempotencyKey),
                  idempotencyKey == idempotencyUUID.uuidString.lowercased() else {
                respond(
                    status: 409,
                    object: ["message": "missing provider repair authority or stale selection revision"],
                    to: connection
                )
                return
            }
            let resultingRevision = locked { () -> String in
                mutableProviderIntegrationMutationRecords.append(.init(
                    kind: "repair",
                    providerID: providerID,
                    expectedRevision: expectedRevision,
                    idempotencyKey: idempotencyKey
                ))
                mutableProviderIntegrationMutationAuthorizationCount += 1
                mutableMutationAuthorizationCount += 1
                mutableConfiguredProviderIntegrationIDs.insert(providerID)
                mutableProviderIntegrationRevision += 1
                return providerIntegrationRevision
            }
            respond(
                status: 200,
                object: providerIntegrationOperation(
                    operationID: "66666666-6666-4666-8666-666666666666",
                    kind: "repair",
                    providerID: providerID,
                    expectedRevision: expectedRevision,
                    resultingRevision: resultingRevision,
                    detail: "\(providerID) integration passed verification."
                ),
                to: connection
            )
        case "/api/manager/provider/prepare":
            guard request.method == "POST",
                  request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  Set(object.keys) == ["resume_waiting_runs"],
                  let resumeWaitingRuns = object["resume_waiting_runs"] as? Bool else {
                respond(
                    status: 401,
                    object: ["message": "missing provider preparation authority or invalid payload"],
                    to: connection
                )
                return
            }
            let configuration = locked { () -> [String: Any] in
                mutableProviderPreparationCount += 1
                mutableProviderPreparationAuthorizationCount += 1
                mutableProviderPreparationResumeWaitingRuns.append(resumeWaitingRuns)
                mutableMutationAuthorizationCount += 1
                return [
                    "revision": mutableProviderConfigurationRevision,
                    "endpoint": mutableProviderConfiguredEndpoint,
                    "endpoint_mode": providerEndpointMode,
                    "modelKey": "fixture-model",
                    "credentialConfigured": false,
                    "saved": true,
                    "credentialCleanupPending": false,
                ]
            }
            respond(
                status: 200,
                object: [
                    "schema_version": 1,
                    "state": "ready",
                    "recovery_action": "none",
                    "detail": "LM Studio is reachable and the loaded model passed the managed-provider contract.",
                    "configuration": configuration,
                    "provider": provider(),
                ],
                to: connection
            )
        case "/api/manager/provider/configuration":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true else {
                respond(status: 401, object: ["message": "missing provider configuration authorization"], to: connection)
                return
            }
            if !request.body.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                      Set(object.keys).isSubset(of: ["expectedRevision", "endpoint", "modelKey", "credentialAction"]),
                      object["expectedRevision"] as? String == locked({ mutableProviderConfigurationRevision }),
                      let endpoint = object["endpoint"] as? String,
                      object["credentialAction"] as? String == "keep" else {
                    respond(status: 409, object: ["message": "invalid or stale provider configuration"], to: connection)
                    return
                }
                locked {
                    mutableProviderConfiguredEndpoint = endpoint
                    mutableProviderConfiguredModel = object["modelKey"] as? String ?? ""
                    mutableProviderConfigurationRevision = UUID().uuidString.lowercased()
                    mutableProviderConfigurationSaveCount += 1
                }
            }
            let configuration: [String: Any] = locked {
                ["revision": mutableProviderConfigurationRevision,
                 "endpoint": mutableProviderConfiguredEndpoint,
                 "endpoint_mode": providerEndpointMode,
                 "modelKey": mutableProviderConfiguredModel,
                 "credentialConfigured": false,
                 "saved": mutableProviderConfigurationRevision != "0",
                 "credentialCleanupPending": false]
            }
            respond(status: 200, object: configuration, to: connection)
        case "/api/manager/provider/probe":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  Set(object.keys) == ["adapter_id", "mode"],
                  let adapterID = object["adapter_id"] as? String,
                  adapterID == "forge.native-session-host",
                  let mode = object["mode"] as? String,
                  mode == "connection" || mode == "contract" else {
                respond(
                    status: 401,
                    object: [
                        "code": "invalid_provider_probe",
                        "message": "missing provider probe authority or exact typed payload",
                    ],
                    to: connection
                )
                return
            }
            let rejected = locked { () -> Bool in
                mutableProviderProbeRecords.append(
                    ProviderProbeRecord(adapterID: adapterID, mode: mode)
                )
                mutableProviderProbeBodies.append(request.body)
                mutableProviderProbeAuthorizationCount += 1
                mutableMutationAuthorizationCount += 1
                mutableProviderLastProbeMode = mode
                mutableProviderLastProbeAt = "2026-08-31T12:00:00Z"
                if failContractProbe, mode == "contract" {
                    mutableProviderHealth = "contract_invalid"
                    mutableProviderLastProbeError = "Provider contract probe failed: required capabilities are absent: custom tools"
                    return true
                }
                mutableProviderHealth = mode == "contract" ? "contract_valid" : "reachable"
                mutableProviderLastProbeError = nil
                return false
            }
            if rejected {
                respond(
                    status: 422,
                    object: [
                        "ok": false,
                        "code": "provider_contract_unavailable",
                        "message": "Provider contract probe failed: required capabilities are absent: custom tools",
                    ],
                    to: connection
                )
            } else {
                respond(status: 200, object: provider(), to: connection)
            }
        case "/api/manager/runtime-jobs/cancel":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  Set(object.keys) == ["job_id"],
                  let jobID = object["job_id"] as? String,
                  jobID == runtimeJobID else {
                respond(
                    status: 401,
                    object: [
                        "code": "invalid_runtime_job_cancel",
                        "message": "missing runtime cancellation authority or exact typed job identity",
                    ],
                    to: connection
                )
                return
            }
            let rejected = locked { () -> Bool in
                mutableRuntimeCancellationJobIDs.append(jobID)
                mutableRuntimeCancellationBodies.append(request.body)
                mutableRuntimeCancellationAuthorizationCount += 1
                mutableMutationAuthorizationCount += 1
                if mutableRejectNextRuntimeCancellation {
                    mutableRejectNextRuntimeCancellation = false
                    return true
                }
                mutableRuntimeJobState = "cancelled"
                return false
            }
            if rejected {
                respond(
                    status: 409,
                    object: [
                        "ok": false,
                        "code": "runtime_job_invalid_transition",
                        "message": "fixture rejected runtime cancellation",
                    ],
                    to: connection
                )
            } else {
                respond(status: 200, object: runtimeJob(), to: connection)
            }
        case "/api/manager/runs/control":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  Set(object.keys) == ["run_id", "action"],
                  object["run_id"] as? String == runID,
                  let action = object["action"] as? String,
                  ["pause", "resume", "cancel", "retry", "checkpoint", "rollover"].contains(action) else {
                respond(status: 401, object: ["message": "missing manager authorization"], to: connection)
                return
            }
            let nextState: String
            if action == "pause" {
                nextState = "paused"
            } else if action == "resume" {
                nextState = "running"
            } else if action == "cancel" {
                nextState = "cancel_requested"
            } else if action == "checkpoint" {
                nextState = "checkpointing"
            } else if action == "rollover" {
                nextState = "rolling_over"
            } else {
                nextState = "recovering"
            }
            let rejected = locked { () -> Bool in
                mutableControlActions.append(action)
                mutableControlRequestCount += 1
                mutableMutationAuthorizationCount += 1
                if mutableRejectNextContinuityCommand,
                   action == "checkpoint" || action == "rollover" {
                    mutableRejectNextContinuityCommand = false
                    return true
                }
                mutableRunState = nextState
                return false
            }
            if rejected {
                respond(
                    status: 409,
                    object: [
                        "code": "context_observation_required",
                        "message": "A current usage observation is required",
                    ],
                    to: connection
                )
            } else {
                respond(status: 200, object: run(state: nextState), to: connection)
            }
        case "/api/manager/runs/delete":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  Set(object.keys) == ["run_id", "project_id", "project_generation"],
                  object["run_id"] as? String == runID,
                  object["project_id"] as? String == projectID,
                  (object["project_generation"] as? NSNumber)?.uint64Value
                    == locked({ mutableProjectGeneration }) else {
                respond(status: 401, object: ["message": "missing task deletion authority"], to: connection)
                return
            }
            let priorState = locked { () -> String? in
                guard ["completed", "cancelled", "failed_terminal"].contains(mutableRunState),
                      !mutableDeletedRun else { return nil }
                mutableDeletedRun = true
                mutableDeletionRequestCount += 1
                mutableMutationAuthorizationCount += 1
                return mutableRunState
            }
            guard let priorState else {
                respond(status: 409, object: ["message": "task is not settled"], to: connection)
                return
            }
            respond(
                status: 200,
                object: [
                    "run_id": runID,
                    "project_id": projectID,
                    "project_generation": locked({ mutableProjectGeneration }),
                    "prior_state": priorState,
                    "deleted_at": "2026-09-21T12:00:00Z",
                ],
                to: connection
            )
        case "/api/manager/runs/instruction-artifacts/import":
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                respond(status: 401, object: ["message": "invalid instruction artifact body"], to: connection)
                return
            }
            let packageIDs = (object["package_ids"] as? [String]) ?? []
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let requestedRunID = object["run_id"] as? String,
                  UUID(uuidString: requestedRunID) != nil,
                  object["project_id"] as? String == projectID,
                  let generation = (object["project_generation"] as? NSNumber)?.uint64Value,
                  generation == locked({ mutableProjectGeneration }),
                  packageIDs.allSatisfy({ $0 == instructionPackageID }),
                  object["source_path"] is String || !packageIDs.isEmpty else {
                respond(status: 401, object: ["message": "missing instruction artifact authority or inputs"], to: connection)
                return
            }
            locked { mutableMutationAuthorizationCount += 1 }
            let digest = String(repeating: "c", count: 64)
            respond(
                status: 201,
                object: [
                    "ok": true,
                    "run_id": requestedRunID,
                    "project_id": projectID,
                    "project_generation": generation,
                    "mission": "Follow the fixture instruction artifact. Snapshot: \(digest)",
                    "source_path": "/tmp/forge-operator-fixture-instructions",
                    "content_sha256": digest,
                    "document_count": max(packageIDs.count, 1),
                    "instruction_byte_count": 128,
                    "unresolved_document_count": 0,
                    "created_at": "2026-08-31T12:00:00Z",
                ],
                to: connection
            )
        case "/api/manager/runs/prepare":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  object["project_id"] as? String == projectID,
                  let generation = (object["project_generation"] as? NSNumber)?.uint64Value,
                  generation == locked({ mutableProjectGeneration }),
                  let mission = object["mission"] as? String,
                  !mission.isEmpty else {
                respond(status: 401, object: ["message": "missing preparation authority or task inputs"], to: connection)
                return
            }
            respond(
                status: 200,
                object: preparedRunResult(object: object, generation: generation, mission: mission),
                to: connection
            )
        case "/api/manager/runs/start":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let requestedRunID = object["run_id"] as? String,
                  UUID(uuidString: requestedRunID) != nil else {
                respond(status: 401, object: ["message": "missing manager authorization or run identity"], to: connection)
                return
            }
            locked { mutableMutationAuthorizationCount += 1 }
            let allowedTools = resolvedToolIDs(from: object)
            let knownTools: Set<String> = ["project_memory.search"]
            let invalidTools = allowedTools.subtracting(knownTools).sorted()
            guard !allowedTools.isEmpty, invalidTools.isEmpty else {
                locked {
                    mutableStartRequestCount += 1
                    mutableStartRequestRunIDs.append(requestedRunID)
                    mutableStartRequestBodies.append(request.body)
                }
                respond(
                    status: 422,
                    object: [
                        "ok": false,
                        "code": "autonomy_tool_configuration_invalid",
                        "message": "Allowed tools are not registered in this build: \(invalidTools.joined(separator: ", "))",
                        "retryable": false,
                    ],
                    to: connection
                )
                return
            }
            let disposition = locked { () -> (conflict: Bool, dropResponse: Bool) in
                mutableStartRequestCount += 1
                mutableStartRequestRunIDs.append(requestedRunID)
                mutableStartRequestBodies.append(request.body)
                if let accepted = mutableAcceptedStartRunID, accepted != requestedRunID {
                    return (true, false)
                }
                mutableAcceptedStartRunID = requestedRunID
                mutableAcceptedStart = true
                return (false, failStartResponse && mutableStartRequestCount == 1)
            }
            if disposition.conflict {
                respond(status: 409, object: ["message": "run identity conflict"], to: connection)
            } else if disposition.dropResponse {
                respond(
                    status: 503,
                    object: ["message": "fixture dropped the response after durable acceptance"],
                    to: connection
                )
            } else {
                respond(
                    status: 200,
                    object: run(
                        id: requestedRunID,
                        state: "created",
                        mission: "Continue the fixture mission"
                    ),
                    to: connection
                )
            }
        default:
            respond(status: 404, object: ["message": "fixture route unavailable"], to: connection)
        }
    }

    private func resolvedToolIDs(from object: [String: Any]) -> Set<String> {
        if let requestedTools = object["allowed_tools"] as? [String] {
            return Set(requestedTools)
        }
        return locked {
            switch mutableToolSelectionMode {
            case "all_eligible", "recommended":
                return Set(["project_memory.search"])
            default:
                return Set(mutableSelectedToolIDs)
            }
        }
    }

    private func exactQuery(
        _ items: [URLQueryItem],
        equals expected: [String: String]
    ) -> Bool {
        guard items.count == expected.count else { return false }
        var observed: [String: String] = [:]
        for item in items {
            guard observed[item.name] == nil, let value = item.value else { return false }
            observed[item.name] = value
        }
        return observed == expected
    }

    private func preparedRunResult(
        object: [String: Any],
        generation: UInt64,
        mission: String
    ) -> [String: Any] {
        let sourceSHA = object["instruction_artifact_sha256"] as? String
            ?? String(repeating: "c", count: 64)
        let artifactBacked = object["instruction_artifact_sha256"] != nil
        let descriptor: [String: Any] = [
            "schema_version": 1,
            "revision": String(repeating: "d", count: 64),
            "readiness": "ready",
            "detail": "The exact fixture task inputs are ready.",
            "recovery_action": "none",
            "project_id": projectID,
            "project_generation": generation,
            "source": [
                "kind": artifactBacked ? "instruction_artifact" : "inline_mission",
                "reference": artifactBacked
                    ? "instruction-artifact:fixture" : "inline-mission:\(sourceSHA)",
                "snapshot_sha256": sourceSHA,
            ],
            "documents": [[
                "reference": artifactBacked
                    ? "instruction-snapshot:\(sourceSHA)/.forge/canonical/document-000001.txt"
                    : "inline:mission",
                "byte_count": mission.utf8.count,
                "sha256": sourceSHA,
            ]],
            "provider_id": object["provider_id"] as? String ?? "fixture-provider",
            "adapter_id": object["adapter_id"] as? String ?? "forge.native-session-host",
            "model_key": object["model_key"] as? String ?? "fixture-model",
            "provider_configuration_revision": locked { mutableProviderConfigurationRevision },
            "tool_catalog_revision": String(repeating: "b", count: 64),
            "allowed_tools": resolvedToolIDs(from: object).sorted(),
            "network_allowed": object["network_allowed"] as? Bool ?? false,
            "validation_plan": [
                "mode": "automatic_completion_plan",
                "completion_gates": object["completion_gates"] as? [String] ?? ["tests"],
                "automatic_plan": automaticCompletionPlan(
                    sourceSHA: sourceSHA,
                    generation: generation
                ),
            ],
            "continuity_mode": "managedAutonomous",
            "budget_policy": [
                "scope": [
                    "kind": "project_override",
                    "project_id": projectID,
                    "project_generation": generation,
                ],
                "revision": 0,
                "global_revision": 1,
                "inherited": true,
                "policy": [
                    "schema_version": 1,
                    "context": [
                        "mode": "auto",
                        "max_context_tokens": 32_768,
                        "checkpoint_ratio": 0.75,
                        "rollover_ratio": 0.85,
                        "emergency_ratio": 0.95,
                    ],
                    "tools": [
                        "calls_per_turn": 8,
                        "calls_per_session": 64,
                        "calls_per_run": 512,
                        "max_in_flight": 2,
                        "max_result_bytes": 65_536,
                        "max_retained_result_tokens": 4_096,
                        "recovery_calls_per_rollover": 4,
                    ],
                    "automatic_handoff_enabled": false,
                ],
            ],
            "maximum_inline_output_bytes": 65_536,
        ]
        return [
            "schema_version": 1,
            "project_id": projectID,
            "project_generation": generation,
            "readiness": "ready",
            "detail": "The exact fixture task inputs are ready.",
            "recovery_action": "none",
            "descriptor": descriptor,
        ]
    }

    private func snapshot(includeActivity: Bool = false) -> [String: Any] {
        let state = locked { mutableRunState }
        let acceptedStart = locked { mutableAcceptedStart }
        let acceptedStartRunID = locked { mutableAcceptedStartRunID }
        let deletedRun = locked { mutableDeletedRun }
        var runs = deletedRun ? [] : [run(state: state, includeActivity: includeActivity)]
        if acceptedStart, let acceptedStartRunID {
            runs.insert(
                run(
                    id: acceptedStartRunID,
                    state: "created",
                    mission: "Continue the fixture mission",
                    includeActivity: includeActivity
                ),
                at: 0
            )
        }
        let continuityOperations = includeContinuityOperation
            && !locked({ mutableContinuityOperationCleared })
            ? [continuityOperation()] : []
        let events: [[String: Any]]
        if includeActivity {
            events = managedActivityEvents()
        } else if includeContinuityOperation {
            events = [continuityEvent()]
        } else {
            events = []
        }
        return [
            "projects": [project()],
            "runs": runs,
            "continuity_readiness": [[
                "project_id": projectID,
                "project_generation": 4,
                "run_id": acceptedStartRunID ?? runID,
                "state": "monitoring",
                "automatic": true,
                "detail": "Automatic continuity is monitoring this managed task.",
                "capacity_tokens": 32_768,
                "used_tokens": 9_216,
                "remaining_tokens": 23_552,
                "confidence": 1.0,
                "source": "provider_exact",
                "next_automatic_action": "Forge will save progress before the rollover threshold.",
                "recovery_action": "none",
            ]],
            "continuity_operations": continuityOperations,
            "runtime_jobs": [runtimeJob()],
            "provider": provider(),
            "runtime": runtimePolicy(),
            "events": events,
        ]
    }

    private func continuityOperation() -> [String: Any] {
        [
            "operation_id": continuityOperationID,
            "project_id": projectID,
            "project_generation": 4,
            "run_id": runID,
            "mode": "managed_autonomous",
            "state": continuityOperationState,
            "control_state": "successor_bootstrapping",
            "checkpoint_id": "fixture-checkpoint",
            "handoff_id": "fixture-handoff",
            "handoff_sha256": String(repeating: "d", count: 64),
            "predecessor_session_id": "fixture-active-session",
            "successor_session_id": "fixture-successor-session",
            "successor_provider_response_id": "fixture-successor-response",
            "attempt": 2,
            "continuation_issued": false,
            "budget": [
                "capacity_tokens": 32_768,
                "used_tokens": 26_000,
                "response_reserve_tokens": 1_024,
                "handoff_reserve_tokens": 2_048,
                "recovery_reserve_tokens": 1_024,
                "remaining_tokens": 6_768,
                "source": "provider_exact",
                "confidence": "exact",
                "action": "rollover",
                "checkpoint_threshold": 24_576,
                "rollover_threshold": 27_852,
            ] as [String: Any],
            "updated_at": "2026-08-31T12:00:06Z",
        ]
    }

    private func continuityEvent() -> [String: Any] {
        [
            "event_id": continuityEventID,
            "timestamp": "2026-08-31T12:00:06Z",
            "kind": "continuity_successor_created",
            "summary": "The accepted successor session was created.",
            "severity": "success",
            "project_id": projectID,
            "project_generation": 4,
            "run_id": runID,
            "operation_id": continuityOperationID,
        ]
    }

    private func pagedEvidenceEvent(sequence: Int64) -> [String: Any] {
        [
            "sequence": sequence,
            "event_id": "fixture-evidence-\(sequence)",
            "timestamp": "2026-10-04T12:00:00Z",
            "kind": "fixture_evidence",
            "summary": "Fixture evidence event \(sequence)",
            "severity": "info",
            "project_id": projectID,
            "project_generation": 4,
        ]
    }

    private func managedActivityEvents() -> [[String: Any]] {
        [[
            "event_id": "fixture-assistant-event",
            "timestamp": "2026-08-31T12:00:05Z",
            "kind": "managed_activity_assistant_response",
            "summary": "Bounded assistant response from LM Studio.",
            "severity": "info",
            "project_id": projectID,
            "project_generation": Int(locked { mutableProjectGeneration }),
            "run_id": runID,
        ], [
            "event_id": "fixture-tool-event",
            "timestamp": "2026-08-31T12:00:04Z",
            "kind": "managed_activity_tool_completed",
            "summary": "project_memory.search completed with a bounded result.",
            "severity": "success",
            "project_id": projectID,
            "project_generation": Int(locked { mutableProjectGeneration }),
            "run_id": runID,
        ]]
    }

    private func policySnapshot() -> [String: Any] {
        let sourceID = "66666666-6666-4666-8666-666666666666"
        let violationID = "77777777-7777-4777-8777-777777777777"
        return [
            "schemaVersion": "1.0.0",
            "health": [
                "state": "running",
                "policyIdentity": "raven-forge-development-policy",
                "evaluatorID": "fixture-policy-evaluator",
                "startedAt": 809_956_800.0,
                "lastEvaluationAt": 809_956_805.0,
                "lastCommittedCursor": 1,
                "processedObservationCount": 1,
                "indexedSourceBatchCount": 1,
                "consecutiveFailureCount": 0,
            ],
            "governingPolicy": [
                "bindingID": "fixture-policy-binding",
                "authority": "Raven Forge Development",
                "repositoryURL": "https://example.invalid/raven-forge-policy",
                "version": "1",
                "revision": "fixture-policy-revision",
                "sourceID": ["rawValue": sourceID],
            ],
            "sources": includePolicyDetails ? policySources() : [],
            "violationEvents": [[
                "schemaVersion": "1.0.0",
                "sequence": 1,
                "id": policyEventID,
                "type": "violation_opened",
                "occurredAt": 809_956_805.0,
                "violationID": ["rawValue": violationID],
                "fingerprint": String(repeating: "f", count: 64),
                "candidate": [
                    "rule": [
                        "id": ["rawValue": "RF-FIXTURE-001"],
                        "source": [
                            "sourceID": ["rawValue": sourceID],
                            "revision": "fixture-policy-revision",
                            "path": "docs/DEVELOPMENT-POLICY.md",
                            "locator": "verification",
                        ],
                        "statement": "Document verified changes.",
                        "policyArea": "verification",
                        "applicability": "all product changes",
                        "confidence": 1.0,
                        "assumptions": [],
                        "alternatives": [],
                        "controlsExecution": false,
                    ],
                    "observationID": "88888888-8888-4888-8888-888888888888",
                    "scope": [
                        "projectID": projectID,
                        "projectGeneration": Int(locked { mutableProjectGeneration }),
                        "runID": runID,
                        "sessionID": "fixture-active-session",
                        "clientID": "forge-conductor-ui-test",
                    ],
                    "subjectIdentity": "fixture-change",
                    "summary": "Fixture policy violation: documentation evidence is missing.",
                    "evidenceReferences": ["fixture://policy/evidence/1"],
                    "explanation": "The change has executable evidence but no matching documentation receipt.",
                    "confidence": 0.98,
                    "assumptions": ["The fixture change is user-facing."],
                    "alternatives": ["Defer only with an explicit roadmap record."],
                    "suggestedCorrection": "Update the current documentation before closing the phase.",
                ],
                "noticeState": "pending",
                "eventSHA256": String(repeating: "e", count: 64),
                "developmentContinues": true,
            ]],
            "evaluationActivity": [[
                "id": "fixture-evaluation",
                "summary": "Fixture observation evaluated without a finding.",
                "evaluatedAt": "2026-09-24T11:00:00Z",
                "findingCount": 0,
                "detectorFaultCount": 0,
            ]],
            "limitations": ["Fixture history is intentionally bounded."],
        ]
    }

    private func policySources() -> [[String: Any]] {
        [
            [
                "id": ["rawValue": "66666666-6666-4666-8666-666666666666"],
                "origin": "built_in_raven_forge",
                "displayName": "Raven Forge Development baseline",
                "selectedPath": "docs/DEVELOPMENT-POLICY.md",
                "standardizedPath": "/tmp/forge-operator-fixture/docs/DEVELOPMENT-POLICY.md",
                "rootKind": "regular_file",
                "active": true,
                "interpretationState": "indexed",
                "addedAt": 809_956_800.0,
                "latestObservation": "Fixture governing baseline remains protected from removal.",
            ],
            [
                "id": ["rawValue": "67676767-6767-4767-8767-676767676767"],
                "origin": "user_selected",
                "displayName": "Opaque instruction source",
                "selectedPath": "/tmp/forge-operator-fixture/policy/governance.opaque-format",
                "standardizedPath": "/tmp/forge-operator-fixture/policy/governance.opaque-format",
                "rootKind": "regular_file",
                "active": true,
                "interpretationState": "partially_indexed",
                "addedAt": 809_956_801.0,
                "latestObservation": "Fixture source is active with metadata-only interpretation.",
            ],
        ]
    }

    private func policyViolation() -> [String: Any] {
        [
            "violation": [
                "id": ["rawValue": "77777777-7777-4777-8777-777777777777"],
                "fingerprint": String(repeating: "f", count: 64),
                "ruleID": ["rawValue": "RF-FIXTURE-001"],
                "policyRevision": "fixture-policy-revision",
                "state": "open",
                "firstObservedAt": 809_956_800.0,
                "lastObservedAt": 809_956_805.0,
                "occurrenceCount": 1,
                "latestSummary": "Fixture policy violation: documentation evidence is missing.",
                "latestSuggestedCorrection": "Update the current documentation before closing the phase.",
            ],
            "latestEventSequence": 1,
        ]
    }

    private func runtimeJob() -> [String: Any] {
        let state = locked { mutableRuntimeJobState }
        return [
            "job_id": runtimeJobID,
            "run_id": runID,
            "project_id": projectID,
            "project_generation": 4,
            "runtime_kind": "bash",
            "state": state,
            "canonical_working_directory": "/tmp/forge-operator-fixture",
            "command_summary": "fixture runtime command",
            "timeout_seconds": 30,
            "output_bytes": 0,
            "created_at": "2026-08-31T12:00:00Z",
        ]
    }

    private func providerIntegrations() -> [String: Any] {
        let state = locked {
            (
                providerIntegrationRevision,
                mutableConfiguredProviderIntegrationIDs
            )
        }
        let descriptors: [(id: String, name: String, strategy: String, detail: String)] = [
            (
                "lmstudio",
                "LM Studio",
                "managed_provider_push",
                "Forge sends bounded managed-model turns to LM Studio."
            ),
            (
                "claude-desktop",
                "Claude Code Desktop",
                "desktop_plugin_pull",
                "Claude Code Desktop executes work through a Forge-managed plugin."
            ),
            (
                "codex-desktop",
                "Codex Desktop",
                "desktop_plugin_pull",
                "Codex Desktop executes work through a Forge-managed plugin."
            ),
            (
                "grok-build",
                "Grok Build",
                "desktop_plugin_pull",
                "Grok Build executes work through a Forge-managed plugin."
            ),
        ]
        let providers: [[String: Any]] = descriptors.map { descriptor in
            let configured = state.1.contains(descriptor.id)
            var provider: [String: Any] = [
                "descriptor": [
                    "id": descriptor.id,
                    "display_name": descriptor.name,
                    "execution_strategy": descriptor.strategy,
                    "selectable": descriptor.id != "grok-build",
                    "detail": descriptor.detail,
                ],
                "setup_state": configured ? "configured" : "not_configured",
            ]
            if configured {
                provider["receipt"] = [
                    "provider_id": descriptor.id,
                    "artifact_version": "fixture-1",
                    "installed_at": "2026-09-23T12:00:00Z",
                    "verified_at": "2026-09-23T12:00:00Z",
                    "metadata": [
                        "app_path": "/Applications/LM Studio.app",
                        "app_version": "0.3.31",
                        "package_version": "fixture-1",
                        "package_sha256": String(repeating: "a", count: 64),
                        "deployment_id": "fixture-deployment-1",
                        "deployment_verified": "true",
                        "mcp_enabled": "true",
                        "hook_trust_review_required": "false",
                        "restart_required": "false",
                        "connection": "fixture-verified",
                    ],
                ]
            }
            return provider
        }
        var registry: [String: Any] = [
            "selection_revision": state.0,
            "selected_provider_id": "lmstudio",
            "providers": providers,
            "current_operation": NSNull(),
            "recent_operations": [],
        ]
        if includePendingProviderOperation {
            let operation = pendingProviderOperation()
            if locked({ mutablePendingProviderOperationCancelled }) {
                registry["recent_operations"] = [operation]
            } else {
                registry["current_operation"] = operation
            }
        }
        return registry
    }

    private func pendingProviderOperation() -> [String: Any] {
        let state = locked { (providerIntegrationRevision, mutablePendingProviderOperationCancelled) }
        var operation: [String: Any] = [
            "operation_id": pendingProviderOperationID, "kind": "repair", "provider_id": "lmstudio",
            "phase": state.1 ? "cancelled" : "verifying_configuration",
            "expected_revision": state.0,
            "idempotency_key_sha256": String(repeating: "a", count: 64),
            "intent_sha256": String(repeating: "b", count: 64),
            "detail": state.1 ? "Provider setup was cancelled."
                : "Verifying the registered LM Studio integration before activation.",
            "accepted_at": "2026-10-04T12:00:00Z",
            "updated_at": state.1 ? "2026-10-04T12:00:01Z" : "2026-10-04T12:00:00Z",
        ]
        if state.1 { operation["completed_at"] = "2026-10-04T12:00:01Z" }
        return operation
    }

    private func providerIntegrationOperation(
        operationID: String,
        kind: String,
        providerID: String,
        expectedRevision: String,
        resultingRevision: String,
        detail: String
    ) -> [String: Any] {
        [
            "operation_id": operationID,
            "kind": kind,
            "provider_id": providerID,
            "phase": "active",
            "expected_revision": expectedRevision,
            "resulting_revision": resultingRevision,
            "idempotency_key_sha256": String(repeating: "a", count: 64),
            "intent_sha256": String(repeating: "b", count: 64),
            "detail": detail,
            "accepted_at": "2026-09-23T12:00:00Z",
            "updated_at": "2026-09-23T12:00:01Z",
            "completed_at": "2026-09-23T12:00:01Z",
        ]
    }

    private func provider() -> [String: Any] {
        let state = locked {
            (
                mutableProviderHealth,
                mutableProviderLastProbeMode,
                mutableProviderLastProbeError,
                mutableProviderLastProbeAt
            )
        }
        var value: [String: Any] = [
            "adapter_id": "forge.native-session-host",
            "provider_id": "fixture-provider",
            "health": state.0,
            "model_key": "fixture-model",
            "tool_use_capable": true,
        ]
        if let reportedProviderEndpoint {
            value["endpoint"] = reportedProviderEndpoint
        }
        if let mode = state.1 {
            value["last_probe_mode"] = mode
            value["probe_result_storage"] = "memory_only"
        }
        if let error = state.2 {
            value["last_probe_error"] = error
        }
        if let completedAt = state.3 {
            value["last_probe_at"] = completedAt
        }
        return value
    }

    private func project() -> [String: Any] {
        let state = locked {
            (mutableProjectRoot, mutableProjectGeneration, mutableContinuityOperationCleared)
        }
        var value: [String: Any] = [
            "project_id": projectID,
            "display_name": "Fixture Project",
            "canonical_root": state.0,
            "project_generation": state.1,
            "lifecycle_state": "active",
            "bindings": [],
            "memory": ["state": "healthy", "database_bytes": 4_096, "record_count": 2],
            "migration_warnings": [],
        ]
        if !state.2 {
            value["continuity"] = ["state": "ready", "migration_state": "not_required"]
        } else {
            value["continuity"] = ["state": "unavailable"]
        }
        return value
    }

    private func instructionQueue() -> [String: Any] {
        let state = locked {
            (
                mutableProjectGeneration,
                mutableInstructionQueueRevision,
                mutableInstructionQueueRunning,
                mutableInstructionPackageIDs,
                mutableInstructionPackageStates
            )
        }
        let packages: [[String: Any]] = state.3.enumerated().map { index, packageID in
            let isFirst = packageID == instructionPackageID
            let packageState = state.4[packageID] ?? "queued"
            var package: [String: Any] = [
                "id": packageID,
                "project_id": projectID,
                "project_generation": state.0,
                "package_id": isFirst ? "fixture-package" : "fixture-package-two",
                "version": "1",
                "display_name": isFirst ? "Fixture Instructions" : "Second Fixture Instructions",
                "mission": isFirst
                    ? "Follow the fixture instructions."
                    : "Follow the second fixture instructions.",
                "source_path": isFirst
                    ? "/tmp/removed-fixture-source.md"
                    : "/tmp/second-fixture-source.md",
                "content_sha256": String(repeating: isFirst ? "c" : "d", count: 64),
                "allowed_tools": ["project_memory.search"],
                "completion_gates": ["tests"],
                "document_count": 1,
                "instruction_byte_count": 128,
                "unresolved_document_count": 0,
                "import_ready": true,
                "position": index,
                "state": packageState,
                "created_at": "2026-08-31T12:00:00Z",
                "updated_at": "2026-08-31T12:00:00Z",
            ]
            if isFirst, packageState != "queued" {
                package["run_id"] = runID
            }
            return package
        }
        return [
            "ok": true,
            "project_id": projectID,
            "project_generation": state.0,
            "revision": state.1,
            "running": state.2,
            "packages": packages,
        ]
    }

    private func toolPermissionSnapshot() -> [String: Any] {
        let state = locked {
            (
                mutableProjectGeneration,
                mutableToolPreferenceRevision,
                mutableToolSelectionMode,
                mutableSelectedToolIDs,
                mutableShellEnabled
            )
        }
        let allToolIDs = ["fs_edit", "fs_read", "git_status", "project_memory.search", "search_text", "shell_exec"]
        let availableToolIDs = state.4 ? allToolIDs : allToolIDs.filter { $0 != "shell_exec" }
        let selected: [String]
        switch state.2 {
        case "all_eligible": selected = availableToolIDs
        case "recommended": selected = ["fs_read", "git_status", "project_memory.search", "search_text"]
        default: selected = state.3
        }
        let effective = selected.filter { availableToolIDs.contains($0) }.sorted()
        func entry(
            _ id: String,
            _ name: String,
            _ description: String,
            _ category: String,
            _ categoryName: String,
            highImpact: Bool = false
        ) -> [String: Any] {
            var value: [String: Any] = [
                "id": id,
                "display_name": name,
                "description": description,
                "category": category,
                "category_display_name": categoryName,
                "recommended": ["fs_read", "git_status", "project_memory.search", "search_text"].contains(id),
                "available": id != "shell_exec" || state.4,
                "high_impact": highImpact,
            ]
            if id == "shell_exec", !state.4 {
                value["unavailable_reason"] = "Shell access is disabled in Manager settings."
            }
            return value
        }
        return [
            "schema_version": 1,
            "project_id": projectID,
            "project_generation": state.0,
            "preference_revision": state.1,
            "catalog_revision": String(repeating: "b", count: 64),
            "selection_mode": state.2,
            "selected_tool_ids": selected.sorted(),
            "effective_tool_ids": effective,
            "tools": [
                entry("fs_edit", "Fs Edit", "Edit a UTF-8 text file.", "files", "Files", highImpact: true),
                entry("fs_read", "Fs Read", "Read a UTF-8 text file.", "files", "Files"),
                entry("git_status", "Git Status", "Read repository status.", "source_control", "Source control"),
                entry("project_memory.search", "Project Memory Search", "Search project-scoped memory.", "project_memory", "Project memory"),
                entry("search_text", "Search Text", "Search text recursively.", "search", "Search"),
                entry("shell_exec", "Shell Exec", "Run a bounded shell command.", "commands", "Build and commands", highImpact: true),
            ],
            "updated_at": NSNull(),
        ]
    }

    private func managerStatus() -> [String: Any] {
        [
            "ok": true,
            "manager": true,
            "state": "running",
            "desired_running": true,
            "http_listening": true,
            "service_active": true,
            "pid": 1,
            "restart_count": 0,
            "auto_restart": true,
            "watchdog_interval_sec": 3,
            "open_browser_on_start": false,
            "dashboard": [
                "host": "127.0.0.1",
                "port": Int(port),
                "refresh_interval_sec": 8,
            ] as [String: Any],
            "home": "/tmp/forge-operator-fixture",
            "version": managerVersion,
        ]
    }

    private func managerSettings() -> [String: Any] {
        let settings = locked { (mutableShellEnabled, mutableAllowedRoots) }
        return [
            "ok": true,
            "dashboard": [
                "host": "127.0.0.1",
                "port": Int(port),
                "refresh_interval_sec": 8,
            ] as [String: Any],
            "manager": [
                "auto_restart": true,
                "watchdog_interval_sec": 3,
                "open_browser_on_start": false,
            ] as [String: Any],
            "sessions": ["idle_ttl_sec": 14_400] as [String: Any],
            "shell": [
                "enabled": settings.0,
                "user_disabled": !settings.0,
                "policy_version": 2,
                "policy_origin": settings.0 ? "user_enabled" : "user_disabled",
                "default_timeout_sec": 30,
                "migration": [
                    "state": "not_required",
                    "receipt_valid": false,
                ] as [String: Any],
                "runtimes": [
                    "zsh": ["available": true, "path": "/bin/zsh"],
                    "bash": ["available": true, "path": "/bin/bash"],
                    "python": ["available": false],
                    "powershell": ["available": false],
                ] as [String: Any],
            ] as [String: Any],
            "log_level": "info",
            "allowed_roots": settings.1,
        ]
    }

    private func run(
        id: String? = nil,
        state: String,
        mission: String = "Fixture managed run",
        includeActivity: Bool = false
    ) -> [String: Any] {
        var value: [String: Any] = [
            "run_id": id ?? runID,
            "project_id": projectID,
            "project_generation": 4,
            "mission": mission,
            "state": state,
            "continuity_mode": "managed_autonomous",
            "provider_id": "fixture-provider",
            "adapter_id": "forge.native-session-host",
            "model_key": "fixture-model",
            "active_session_id": "fixture-active-session",
            "continuation_pending": false,
            "completion_gates": ["tests"],
            "completion_plan": automaticCompletionPlan(
                sourceSHA: String(repeating: "c", count: 64),
                generation: 4
            ),
            "passed_gates": [],
            "created_at": "2026-08-31T12:00:00Z",
            "updated_at": "2026-08-31T12:00:05Z",
        ]
        if includeActivity {
            value["current_phase"] = "Implementation"
            value["work_item"] = "Render managed activity"
            value["next_action"] = "Verify the live activity feed"
            value["last_assistant_message"] = "Bounded assistant response from LM Studio."
            value["last_model_turn_id"] = "fixture-model-turn"
            value["last_model_turn_kind"] = "assistant_response"
            value["last_model_turn_state"] = "completed"
            value["last_model_turn_at"] = "2026-08-31T12:00:03Z"
            value["last_tool_invocation_id"] = "fixture-tool-invocation"
            value["last_tool_name"] = "project_memory.search"
            value["last_tool_state"] = "completed"
            value["last_tool_summary"] = "Returned one bounded project-memory result."
            value["last_tool_activity_at"] = "2026-08-31T12:00:04Z"
        }
        return value
    }

    private func automaticCompletionPlan(
        sourceSHA: String,
        generation: UInt64
    ) -> [String: Any] {
        [
            "schema_version": 1,
            "plan_id": "11111111-1111-5111-a111-111111111111",
            "project_id": ["rawValue": projectID],
            "project_generation": ["rawValue": generation],
            "instruction_artifact_sha256": [sourceSHA],
            "obligations": [[
                "id": "artifact-registered",
                "kind": "artifact_registered",
                "title": "Instruction artifact is registered",
                "reason": "The task remains bound to the prepared instruction snapshot.",
                "evidence_requirements": ["prepared_source"],
                "relevant_tool_names": [],
                "human_review_required": false,
            ], [
                "id": "no-unresolved-side-effects",
                "kind": "no_relevant_unresolved_side_effect",
                "title": "No relevant operation remains unresolved",
                "reason": "Completion reconciles in-flight or ambiguous task effects.",
                "evidence_requirements": ["reconciled_side_effects"],
                "relevant_tool_names": [],
                "human_review_required": false,
            ]],
            "source": "automatic",
            "revision": 1,
        ]
    }

    private func runtimePolicy() -> [String: Any] {
        let unavailable: [String: Any] = ["available": false]
        return [
            "direct": ["available": true, "path": "/usr/bin/env"],
            "zsh": ["available": true, "path": "/bin/zsh"],
            "bash": ["available": true, "path": "/bin/bash"],
            "python": unavailable,
            "powershell": unavailable,
            "maximum_concurrent_jobs": 2,
            "default_timeout_seconds": 30,
            "maximum_inline_output_bytes": 65_536,
            "maximum_artifact_bytes_per_job": 1_048_576,
            "network_policy": "denied",
            "shell_policy_migration_state": "not_required",
        ]
    }

    private func dropResponseAfterPartialBody(to connection: NWConnection) {
        let prefix = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1024\r\nConnection: close\r\n\r\n{".utf8
        )
        connection.send(content: prefix, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func respond(status: Int, object: [String: Any], to connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK"
            : status == 401 ? "Unauthorized"
            : status == 404 ? "Not Found"
            : status == 422 ? "Unprocessable Content"
            : "Service Unavailable"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    @discardableResult
    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private enum FixtureError: Error {
        case startup(String)
    }

    private final class StartupState: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: NWError?

        var error: NWError? {
            lock.lock()
            defer { lock.unlock() }
            return storedError
        }

        func record(_ error: NWError) {
            lock.lock()
            storedError = error
            lock.unlock()
        }
    }
}

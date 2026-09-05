// ForgeConductorUITests.swift
// Launches the signed macOS product and exercises its native navigation and controls.
// Stable accessibility identifiers make the checks independent of display coordinates.

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

    nonisolated override func setUpWithError() throws {
        MainActor.assumeIsolated {
            continueAfterFailure = false
            testHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("forge-conductor-ui-\(UUID().uuidString)", isDirectory: true)
            app = XCUIApplication()
            app.launchArguments += ["--uitesting"]
            app.launchEnvironment["FORGE_CONDUCTOR_HOME"] = testHome.path
            app.launchEnvironment["FORGE_SKIP_PS"] = "1"
            app.launch()
        }
    }

    nonisolated override func tearDownWithError() throws {
        MainActor.assumeIsolated {
            app?.terminate()
            app = nil
            operatorFixture?.stop()
            operatorFixture = nil
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
            ("tab-rig", "FORGE RIG", "detail-rig"),
            ("tab-mcp", "LM Studio MCP", "detail-mcp"),
            ("tab-agents", "Agents", "detail-agents"),
            ("tab-tools", "Tools", "detail-tools"),
            ("tab-feed", "Live Feed", "detail-feed"),
            ("tab-projects", "Projects", "detail-projects"),
            ("tab-autonomy", "Autonomy", "detail-autonomy"),
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

    func testRefreshToolbarExists() throws {
        let refresh = app.buttons["toolbar-refresh"]
        XCTAssertTrue(
            refresh.waitForExistence(timeout: 5),
            "The production Refresh now control must remain accessibility-visible"
        )
        XCTAssertTrue(refresh.isEnabled)
        refresh.click()
        XCTAssertTrue(app.windows.firstMatch.exists)
    }

    func testManagerShowsProjectShellPolicyControls() throws {
        let managerTab = app.buttons["tab-manager"]
        XCTAssertTrue(managerTab.waitForExistence(timeout: 8))
        managerTab.click()

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
        XCTAssertTrue(app.buttons["settings-allowed-root-add"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["settings-allowed-roots-empty"].exists
        )
    }

    func testProtectedFilesystemRefreshMutuallyExcludesEveryConflictingControl() throws {
        app.terminate()
        app.launchEnvironment["FORGE_FILESYSTEM_SETTINGS_UI_TEST_DELAY_MS"] = "1200"
        app.launch()
        app.typeKey(",", modifierFlags: .command)

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
    }

    private func element(_ element: XCUIElement, contains text: String) -> Bool {
        if element.label.localizedCaseInsensitiveContains(text) { return true }
        if (element.value as? String)?.localizedCaseInsensitiveContains(text) == true { return true }
        return element.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch.exists
    }

    func testManagerSettingsControlsAndPersistsProjectShellPolicy() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        app.typeKey(",", modifierFlags: .command)
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
        for tabID in ["tab-projects", "tab-autonomy", "tab-continuity", "tab-runtimes", "tab-provider", "tab-evidence"] {
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
        let autonomy = app.buttons["tab-autonomy"]
        XCTAssertTrue(autonomy.waitForExistence(timeout: 8))
        autonomy.click()

        let start = app.buttons["autonomy-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(start.isEnabled, "A run cannot start without a recovered manager, project, and provider")
    }

    func testOperatorStateReconnectsAfterGUIRelaunch() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        let autonomy = app.buttons["tab-autonomy"]
        XCTAssertTrue(autonomy.waitForExistence(timeout: 8))
        autonomy.click()

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

        let relaunchedAutonomy = app.buttons["tab-autonomy"]
        XCTAssertTrue(relaunchedAutonomy.waitForExistence(timeout: 8))
        relaunchedAutonomy.click()
        let restoredState = app.descendants(matching: .any)["autonomy-state"]
        XCTAssertTrue(
            restoredState.waitForExistence(timeout: 5) && waitForValue("paused", on: restoredState),
            "The relaunched GUI must reload the manager's durable run state"
        )
    }

    func testContinuityControlsSendTypedActionsAndSurfaceManagerRejection() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        let continuity = app.buttons["tab-continuity"]
        XCTAssertTrue(continuity.waitForExistence(timeout: 8))
        continuity.click()

        let checkpoint = app.buttons["checkpoint-command"]
        let rollover = app.buttons["rollover-command"]
        XCTAssertTrue(waitForEnabled(checkpoint, timeout: 5))
        XCTAssertTrue(waitForEnabled(rollover, timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["continuity-controls-authority"].exists)
        XCTAssertTrue(
            element(
                app.descendants(matching: .any)["continuity-control-eligibility"],
                contains: "manager will still verify"
            )
        )

        makeHittable(checkpoint)
        checkpoint.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.controlActions == ["checkpoint"]
        })
        XCTAssertEqual(fixture.mutationAuthorizationCount, 1)
        XCTAssertTrue(
            app.descendants(matching: .any)["operator-notice"].waitForExistence(timeout: 5)
        )

        fixture.completeContinuityCycle()
        let refresh = app.buttons["operator-refresh"]
        XCTAssertTrue(waitForEnabled(refresh, timeout: 5))
        refresh.click()
        XCTAssertTrue(waitForEnabled(rollover, timeout: 5))
        makeHittable(rollover)
        rollover.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.controlActions == ["checkpoint", "rollover"]
        })
        XCTAssertEqual(fixture.mutationAuthorizationCount, 2)

        fixture.completeContinuityCycle()
        fixture.rejectNextContinuityCommand()
        XCTAssertTrue(waitForEnabled(refresh, timeout: 5))
        refresh.click()
        XCTAssertTrue(waitForEnabled(checkpoint, timeout: 5))
        makeHittable(checkpoint)
        checkpoint.click()
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.controlActions == ["checkpoint", "rollover", "checkpoint"]
        })
        let commandError = app.descendants(matching: .any)["continuity-command-error"]
        XCTAssertTrue(commandError.waitForExistence(timeout: 5))
        XCTAssertTrue(element(commandError, contains: "current usage observation"))
        XCTAssertEqual(fixture.mutationAuthorizationCount, 3)
    }

    func testProviderSettingsSaveUsesRedactedManagerStateAndSurvivesViewReopen() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)
        let provider = app.buttons["tab-provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 8))
        provider.click()
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
        XCTAssertTrue(waitForValue("fixture/configured-model", on: app.textFields["provider-model-key"]))
        XCTAssertTrue(app.buttons["provider-test-connection"].exists)
        XCTAssertTrue(app.buttons["provider-refresh-models"].exists)
    }

    func testProviderControlsSendExactProtectedRequestsAndSurfaceSuccessAndFailure() throws {
        let fixture = try OperatorManagerUITestFixture(failContractProbe: true)
        relaunch(with: fixture)

        let provider = app.buttons["tab-provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 8))
        provider.click()

        let testConnection = app.buttons["provider-test-connection"]
        XCTAssertTrue(waitForEnabled(testConnection, timeout: 5))
        makeHittable(testConnection)
        testConnection.click()

        let expectedConnection = OperatorManagerUITestFixture.ProviderProbeRecord(
            adapterID: "forge.native-session-host",
            mode: "connection"
        )
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.providerProbeRecords == [expectedConnection]
        })
        XCTAssertEqual(fixture.providerProbeAuthorizationCount, 1)
        XCTAssertEqual(
            fixture.providerProbeBodies.map { String(decoding: $0, as: UTF8.self) },
            ["{\"adapter_id\":\"forge.native-session-host\",\"mode\":\"connection\"}"]
        )
        let notice = app.descendants(matching: .any)["provider-probe-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(element(notice, contains: "configured provider and model are reachable"))

        let runContractProbe = app.buttons["provider-run-contract-probe"]
        XCTAssertTrue(waitForEnabled(runContractProbe, timeout: 5))
        makeHittable(runContractProbe)
        runContractProbe.click()

        let expectedContract = OperatorManagerUITestFixture.ProviderProbeRecord(
            adapterID: "forge.native-session-host",
            mode: "contract"
        )
        XCTAssertTrue(waitUntil(timeout: 5) {
            fixture.providerProbeRecords == [expectedConnection, expectedContract]
        })
        XCTAssertEqual(fixture.providerProbeAuthorizationCount, 2)
        XCTAssertEqual(
            fixture.providerProbeBodies.map { String(decoding: $0, as: UTF8.self) },
            [
                "{\"adapter_id\":\"forge.native-session-host\",\"mode\":\"connection\"}",
                "{\"adapter_id\":\"forge.native-session-host\",\"mode\":\"contract\"}",
            ]
        )

        let structuredFailure = app.descendants(matching: .any)["operator-unavailable"]
        XCTAssertTrue(structuredFailure.waitForExistence(timeout: 5))
        XCTAssertTrue(element(structuredFailure, contains: "HTTP 422"))
        XCTAssertTrue(element(structuredFailure, contains: "Provider contract probe failed"))
        XCTAssertTrue(element(structuredFailure, contains: "custom tools"))
        let lastProbeError = app.descendants(matching: .any)["provider-last-probe-error"]
        XCTAssertTrue(lastProbeError.waitForExistence(timeout: 5))
        XCTAssertTrue(element(lastProbeError, contains: "custom tools"))
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
        refreshOperator()
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.element(state, contains: "running") && cancel.isEnabled
        })

        for noncancellableState in [
            "cancelling", "completed", "failed", "timed_out", "cancelled", "quarantined_stale",
        ] {
            fixture.setRuntimeJobState(noncancellableState)
            refreshOperator()
            XCTAssertTrue(waitUntil(timeout: 5) {
                self.element(state, contains: noncancellableState)
            })
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
    }

    func testUncertainStartReusesExactClientRunIdentityDuringReconciliation() throws {
        let fixture = try OperatorManagerUITestFixture(failStartResponse: true)
        relaunch(with: fixture)

        let autonomy = app.buttons["tab-autonomy"]
        XCTAssertTrue(autonomy.waitForExistence(timeout: 8))
        autonomy.click()

        let start = app.buttons["autonomy-start"]
        XCTAssertTrue(waitForEnabled(start, timeout: 5))
        start.click()

        let mission = app.descendants(matching: .any)["run-start-mission"]
        let tools = app.descendants(matching: .any)["run-start-tool-policy"]
        let gates = app.descendants(matching: .any)["run-start-completion-gates"]
        XCTAssertTrue(mission.waitForExistence(timeout: 5))
        mission.click()
        mission.typeText("Continue the fixture mission")
        tools.click()
        tools.typeText("project_memory.search")
        gates.click()
        gates.typeText("tests")

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
        XCTAssertEqual(fixture.mutationAuthorizationCount, 2)
    }

    func testInvalidAllowedToolIsRejectedWithoutReconciliation() throws {
        let fixture = try OperatorManagerUITestFixture()
        relaunch(with: fixture)

        let autonomy = app.buttons["tab-autonomy"]
        XCTAssertTrue(autonomy.waitForExistence(timeout: 8))
        autonomy.click()

        let start = app.buttons["autonomy-start"]
        XCTAssertTrue(waitForEnabled(start, timeout: 5))
        start.click()

        let mission = app.descendants(matching: .any)["run-start-mission"]
        let tools = app.descendants(matching: .any)["run-start-tool-policy"]
        let gates = app.descendants(matching: .any)["run-start-completion-gates"]
        XCTAssertTrue(mission.waitForExistence(timeout: 5))
        mission.click()
        mission.typeText("Reject an invalid tool policy")
        tools.click()
        tools.typeText("project.memory.search")
        gates.click()
        gates.typeText("tests")

        let confirm = app.buttons["run-start-confirm"]
        XCTAssertTrue(waitForEnabled(confirm, timeout: 3))
        confirm.click()

        let error = app.descendants(matching: .any)["run-start-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(element(error, contains: "autonomy_tool_configuration_invalid"))
        XCTAssertFalse(app.buttons["run-start-reconcile"].exists)
        XCTAssertTrue(waitForEnabled(confirm, timeout: 3))
        XCTAssertEqual(fixture.startRequestCount, 1)
        XCTAssertEqual(fixture.mutationAuthorizationCount, 1)
        XCTAssertTrue(fixture.acceptedStartRunID.isEmpty)
    }

    func testCollapsedNavigationCanBeRestored() throws {
        let toggle = app.buttons["toolbar-navigation"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "Navigation toolbar toggle should always remain available")

        toggle.click() // collapse
        XCTAssertTrue(toggle.exists, "Navigation toggle must remain available while navigation is hidden")
        toggle.click() // restore

        let rigByID = app.buttons["tab-rig"]
        let rigByLabel = app.staticTexts["FORGE RIG"]
        XCTAssertTrue(
            rigByID.waitForExistence(timeout: 3) || rigByLabel.waitForExistence(timeout: 3),
            "Navigation should reappear after using the toolbar toggle"
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

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func makeHittable(_ element: XCUIElement) {
        let containingScrollViews = app.scrollViews
            .containing(.any, identifier: element.identifier)
            .allElementsBoundByIndex
        let scrollView = containingScrollViews.last ?? app.scrollViews.firstMatch
        for _ in 0..<6 where !element.isHittable {
            scrollView.swipeUp()
        }
        for _ in 0..<6 where !element.isHittable {
            scrollView.swipeDown()
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

    let projectID = "11111111-1111-4111-8111-111111111111"
    let runID = "22222222-2222-4222-8222-222222222222"
    let runtimeJobID = "33333333-3333-4333-8333-333333333333"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "forge.operator-ui-fixture")
    private let lock = NSLock()
    private let failStartResponse: Bool
    private let failContractProbe: Bool
    private let dropRelinkResponseCount: Int
    private let rejectFirstRelinkResponse: Bool
    private var mutableRunState = "running"
    private var mutableStartRequestCount = 0
    private var mutableControlRequestCount = 0
    private var mutableMutationAuthorizationCount = 0
    private var mutableStartRequestRunIDs: [String] = []
    private var mutableStartRequestBodies: [Data] = []
    private var mutableControlActions: [String] = []
    private var mutableRejectNextContinuityCommand = false
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
    private var mutableProviderHealth = "healthy"
    private var mutableProviderLastProbeMode: String?
    private var mutableProviderLastProbeError: String?
    private var mutableProviderLastProbeAt: String?
    private var mutableRuntimeJobState = "queued"
    private var mutableRuntimeCancellationJobIDs: [String] = []
    private var mutableRuntimeCancellationBodies: [Data] = []
    private var mutableRuntimeCancellationAuthorizationCount = 0
    private var mutableRejectNextRuntimeCancellation = false
    private(set) var port: UInt16 = 0

    var startRequestCount: Int { locked { mutableStartRequestCount } }
    var controlRequestCount: Int { locked { mutableControlRequestCount } }
    var mutationAuthorizationCount: Int { locked { mutableMutationAuthorizationCount } }
    var startRequestRunIDs: [String] { locked { mutableStartRequestRunIDs } }
    var startRequestBodies: [Data] { locked { mutableStartRequestBodies } }
    var controlActions: [String] { locked { mutableControlActions } }
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
    var runtimeCancellationJobIDs: [String] { locked { mutableRuntimeCancellationJobIDs } }
    var runtimeCancellationBodies: [Data] { locked { mutableRuntimeCancellationBodies } }
    var runtimeCancellationAuthorizationCount: Int {
        locked { mutableRuntimeCancellationAuthorizationCount }
    }

    init(
        failStartResponse: Bool = false,
        failContractProbe: Bool = false,
        dropFirstRelinkResponse: Bool = false,
        dropRelinkResponseCount: Int = 0,
        rejectFirstRelinkResponse: Bool = false
    ) throws {
        self.failStartResponse = failStartResponse
        self.failContractProbe = failContractProbe
        self.dropRelinkResponseCount = max(
            dropRelinkResponseCount,
            dropFirstRelinkResponse ? 1 : 0
        )
        self.rejectFirstRelinkResponse = rejectFirstRelinkResponse
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

    private func parse(_ data: Data) -> (path: String, headers: [String: String], body: Data)? {
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
        let target = parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        return (target, parsedHeaders, Data(data[bodyStart..<bodyEnd]))
    }

    private func route(
        _ request: (path: String, headers: [String: String], body: Data),
        connection: NWConnection
    ) {
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
            respond(status: 200, object: snapshot(), to: connection)
        case "/api/manager/autonomy/status":
            respond(
                status: 200,
                object: [
                    "started": true,
                    "active_run_ids": [runID],
                    "deferred_run_ids": [],
                ],
                to: connection
            )
        case "/api/manager/projects/status":
            respond(status: 200, object: project(), to: connection)
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
        case "/api/manager/runs/start":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let requestedRunID = object["run_id"] as? String,
                  UUID(uuidString: requestedRunID) != nil else {
                respond(status: 401, object: ["message": "missing manager authorization or run identity"], to: connection)
                return
            }
            locked { mutableMutationAuthorizationCount += 1 }
            let allowedTools = Set(object["allowed_tools"] as? [String] ?? [])
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

    private func snapshot() -> [String: Any] {
        let state = locked { mutableRunState }
        let acceptedStart = locked { mutableAcceptedStart }
        let acceptedStartRunID = locked { mutableAcceptedStartRunID }
        var runs = [run(state: state)]
        if acceptedStart, let acceptedStartRunID {
            runs.insert(
                run(
                    id: acceptedStartRunID,
                    state: "created",
                    mission: "Continue the fixture mission"
                ),
                at: 0
            )
        }
        return [
            "projects": [project()],
            "runs": runs,
            "continuity_operations": [],
            "runtime_jobs": [runtimeJob()],
            "provider": provider(),
            "runtime": runtimePolicy(),
            "events": [],
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
        let state = locked { (mutableProjectRoot, mutableProjectGeneration) }
        return [
            "project_id": projectID,
            "display_name": "Fixture Project",
            "canonical_root": state.0,
            "project_generation": state.1,
            "lifecycle_state": "active",
            "bindings": [],
            "memory": ["state": "healthy", "database_bytes": 4_096, "record_count": 2],
            "continuity": ["state": "ready", "migration_state": "not_required"],
            "migration_warnings": [],
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
            "version": "0.9.0",
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
        mission: String = "Fixture managed run"
    ) -> [String: Any] {
        [
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
            "passed_gates": [],
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

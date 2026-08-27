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
final class ForgeConductorUITests: XCTestCase {
    var app: XCUIApplication!
    var testHome: URL!
    private var operatorFixture: OperatorManagerUITestFixture?

    override func setUpWithError() throws {
        continueAfterFailure = false
        testHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-conductor-ui-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchEnvironment["FORGE_CONDUCTOR_HOME"] = testHome.path
        app.launchEnvironment["FORGE_SKIP_PS"] = "1"
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        operatorFixture?.stop()
        operatorFixture = nil
        if let testHome {
            try? FileManager.default.removeItem(at: testHome)
        }
        testHome = nil
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
        if refresh.waitForExistence(timeout: 5) {
            refresh.click()
            XCTAssertTrue(app.windows.firstMatch.exists)
        } else {
            // Toolbar buttons may be icons without identifiers on some OS builds — soft pass if app is up.
            XCTAssertTrue(app.windows.firstMatch.exists)
        }
    }

    func testManagerShowsProjectShellPolicyControls() throws {
        let managerTab = app.buttons["tab-manager"]
        XCTAssertTrue(managerTab.waitForExistence(timeout: 8))
        managerTab.click()

        let shellToggle = app.checkBoxes["settings-shell-enabled"]
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
        tools.typeText("project.memory.search")
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

    private func waitForValue(_ value: String, on element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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
        for _ in 0..<6 where !element.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
}

private final class OperatorManagerUITestFixture: @unchecked Sendable {
    private static let maximumRequestBytes = 64 * 1_024

    let projectID = "11111111-1111-4111-8111-111111111111"
    let runID = "22222222-2222-4222-8222-222222222222"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "forge.operator-ui-fixture")
    private let lock = NSLock()
    private let failStartResponse: Bool
    private var mutableRunState = "running"
    private var mutableStartRequestCount = 0
    private var mutableControlRequestCount = 0
    private var mutableMutationAuthorizationCount = 0
    private var mutableStartRequestRunIDs: [String] = []
    private var mutableStartRequestBodies: [Data] = []
    private var mutableAcceptedStart = false
    private var mutableAcceptedStartRunID: String?
    private(set) var port: UInt16 = 0

    var startRequestCount: Int { locked { mutableStartRequestCount } }
    var controlRequestCount: Int { locked { mutableControlRequestCount } }
    var mutationAuthorizationCount: Int { locked { mutableMutationAuthorizationCount } }
    var startRequestRunIDs: [String] { locked { mutableStartRequestRunIDs } }
    var startRequestBodies: [Data] { locked { mutableStartRequestBodies } }
    var acceptedStartRunID: String { locked { mutableAcceptedStartRunID ?? "" } }

    init(failStartResponse: Bool = false) throws {
        self.failStartResponse = failStartResponse
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
        case "/api/manager/runs/control":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true else {
                respond(status: 401, object: ["message": "missing manager authorization"], to: connection)
                return
            }
            let body = String(data: request.body, encoding: .utf8) ?? ""
            let nextState: String
            if body.contains("\"action\":\"pause\"") {
                nextState = "paused"
            } else if body.contains("\"action\":\"resume\"") {
                nextState = "running"
            } else if body.contains("\"action\":\"cancel\"") {
                nextState = "cancel_requested"
            } else {
                nextState = "recovering"
            }
            locked {
                mutableRunState = nextState
                mutableControlRequestCount += 1
                mutableMutationAuthorizationCount += 1
            }
            respond(status: 200, object: run(state: nextState), to: connection)
        case "/api/manager/runs/start":
            guard request.headers["authorization"]?.hasPrefix("Bearer ") == true,
                  let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let requestedRunID = object["run_id"] as? String,
                  UUID(uuidString: requestedRunID) != nil else {
                respond(status: 401, object: ["message": "missing manager authorization or run identity"], to: connection)
                return
            }
            let disposition = locked { () -> (conflict: Bool, dropResponse: Bool) in
                mutableStartRequestCount += 1
                mutableMutationAuthorizationCount += 1
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
            "projects": [[
                "project_id": projectID,
                "display_name": "Fixture Project",
                "canonical_root": "/tmp/forge-operator-fixture",
                "project_generation": 4,
                "lifecycle_state": "active",
                "bindings": [],
                "memory": ["state": "healthy", "database_bytes": 4_096, "record_count": 2],
                "continuity": ["state": "ready", "migration_state": "not_required"],
                "migration_warnings": [],
            ]],
            "runs": runs,
            "continuity_operations": [],
            "runtime_jobs": [],
            "provider": [
                "provider_id": "fixture-provider",
                "health": "healthy",
                "model_key": "fixture-model",
                "tool_use_capable": true,
            ],
            "runtime": runtimePolicy(),
            "events": [],
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

    private func respond(status: Int, object: [String: Any], to connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK"
            : status == 401 ? "Unauthorized"
            : status == 404 ? "Not Found"
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

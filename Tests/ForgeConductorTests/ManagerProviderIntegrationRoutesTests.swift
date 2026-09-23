// ManagerProviderIntegrationRoutesTests.swift
// Verifies authenticated, bounded HTTP access to the durable provider-selection coordinator.

import XCTest
import Darwin
@testable import ForgeConductorCore

private actor BlockingRouteDesktopProviderAdapter: ProviderIntegrationAdapting {
    nonisolated let providerID = ProviderIntegrationID.codexDesktop
    private var shouldBlock = false
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var inspectionCalls = 0
    private var activeInspections = 0
    private var maximumActiveInspections = 0

    func setBlocked(_ blocked: Bool) {
        shouldBlock = blocked
        if !blocked {
            continuation?.resume()
            continuation = nil
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func state() -> (entered: Bool, calls: Int, maximumActive: Int) {
        (entered, inspectionCalls, maximumActiveInspections)
    }

    func inspect(operationID: String) async throws -> ProviderIntegrationInspection {
        _ = operationID
        inspectionCalls += 1
        activeInspections += 1
        maximumActiveInspections = max(maximumActiveInspections, activeInspections)
        defer { activeInspections -= 1 }
        if shouldBlock {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        return try ProviderIntegrationInspection(
            state: .ready,
            detail: "The route fixture desktop integration is ready.",
            receipt: receipt()
        )
    }

    func provision(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationAdapterResult {
        _ = request
        return try ProviderIntegrationAdapterResult(
            state: .ready,
            detail: "The route fixture desktop integration is ready.",
            receipt: receipt()
        )
    }

    func repair(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationAdapterResult {
        try await provision(request)
    }

    func remove(
        _ request: ProviderIntegrationAdapterRequest
    ) async throws -> ProviderIntegrationRemovalResult {
        _ = request
        return try ProviderIntegrationRemovalResult(
            state: .ready,
            detail: "The route fixture desktop integration was removed."
        )
    }

    func cancel(operationID: String) async { _ = operationID }

    private func receipt() throws -> ProviderIntegrationReceipt {
        try ProviderIntegrationReceipt(
            providerID: providerID,
            artifactVersion: "route-fixture-v1",
            installedAt: "2026-09-23T12:00:00Z",
            verifiedAt: "2026-09-23T12:00:00Z",
            metadata: ["fixture": "route"]
        )
    }
}

final class ManagerProviderIntegrationRoutesTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-provider-routes-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testProviderIntegrationRoutesRequireBearerAndBoundInputs() async throws {
        let fixture = try startManager()
        defer {
            _ = try? fixture.node.stopService()
            fixture.app.shutdown()
        }
        try await Task.sleep(for: .milliseconds(100))

        let unauthorized = try request(
            port: fixture.port,
            path: "/api/manager/providers",
            method: "GET",
            token: nil
        )
        XCTAssertEqual(unauthorized.response.statusCode, 401)
        XCTAssertEqual(unauthorized.object["code"] as? String, "manager_mutation_unauthorized")

        let snapshot = try request(
            port: fixture.port,
            path: "/api/manager/providers",
            method: "GET",
            token: fixture.token
        )
        XCTAssertEqual(snapshot.response.statusCode, 200)
        XCTAssertEqual(snapshot.object["selected_provider_id"] as? String, "lmstudio")
        XCTAssertEqual((snapshot.object["providers"] as? [Any])?.count, 4)

        let query = try request(
            port: fixture.port,
            path: "/api/manager/providers?revision=ignored",
            method: "GET",
            token: fixture.token
        )
        XCTAssertEqual(query.response.statusCode, 400)
        XCTAssertEqual(query.object["code"] as? String, "invalid_provider_integration_request")

        let oversized = try request(
            port: fixture.port,
            path: "/api/manager/providers/selection",
            method: "PUT",
            body: Data(
                repeating: 0x61,
                count: ManagerRoutes.maximumProviderIntegrationBodyBytes + 1
            ),
            token: fixture.token
        )
        XCTAssertEqual(oversized.response.statusCode, 413)
        XCTAssertEqual(oversized.object["code"] as? String, "provider_integration_body_too_large")
    }

    func testProviderIntegrationMutationRoutesEnforceIdentityCASAndOperationLookup() async throws {
        let fixture = try startManager()
        defer {
            _ = try? fixture.node.stopService()
            fixture.app.shutdown()
        }
        try await Task.sleep(for: .milliseconds(100))

        let initialResponse = try request(
            port: fixture.port,
            path: "/api/manager/providers",
            method: "GET",
            token: fixture.token
        )
        XCTAssertEqual(initialResponse.response.statusCode, 200)
        let initial = try JSONDecoder().decode(
            ProviderIntegrationsSnapshot.self,
            from: initialResponse.data
        )
        XCTAssertEqual(initial.selectedProviderID, .lmStudio)

        let mismatchedMutation = try ProviderIntegrationMutationRequest(
            expectedRevision: initial.selectionRevision,
            providerID: .grokBuild,
            idempotencyKey: "route-path-body-mismatch"
        )
        let mismatch = try request(
            port: fixture.port,
            path: "/api/manager/providers/codex-desktop/integration",
            method: "DELETE",
            body: try JSONEncoder().encode(mismatchedMutation),
            token: fixture.token
        )
        XCTAssertEqual(mismatch.response.statusCode, 400)
        XCTAssertEqual(mismatch.object["code"] as? String, "invalid_provider_integration_request")

        let selectedRemoval = try ProviderIntegrationMutationRequest(
            expectedRevision: initial.selectionRevision,
            providerID: .lmStudio,
            idempotencyKey: "route-selected-remove"
        )
        let selectedConflict = try request(
            port: fixture.port,
            path: "/api/manager/providers/lmstudio/integration",
            method: "DELETE",
            body: try JSONEncoder().encode(selectedRemoval),
            token: fixture.token
        )
        XCTAssertEqual(selectedConflict.response.statusCode, 409)
        XCTAssertEqual(
            selectedConflict.object["code"] as? String,
            "selected_provider_cannot_be_removed"
        )

        let staleSelection = try ProviderSelectionRequest(
            expectedRevision: "stale-revision",
            providerID: nil,
            idempotencyKey: "route-stale-selection"
        )
        let stale = try request(
            port: fixture.port,
            path: "/api/manager/providers/selection",
            method: "PUT",
            body: try JSONEncoder().encode(staleSelection),
            token: fixture.token
        )
        XCTAssertEqual(stale.response.statusCode, 409)
        XCTAssertEqual(stale.object["code"] as? String, "provider_selection_revision_conflict")

        let unexpectedField = try JSONSupport.data(from: [
            "expected_revision": initial.selectionRevision,
            "idempotency_key": "route-unexpected-field",
            "unexpected": true,
        ])
        let invalid = try request(
            port: fixture.port,
            path: "/api/manager/providers/selection",
            method: "PUT",
            body: unexpectedField,
            token: fixture.token
        )
        XCTAssertEqual(invalid.response.statusCode, 400)
        XCTAssertEqual(invalid.object["code"] as? String, "invalid_provider_integration_request")

        let deactivation = try ProviderSelectionRequest(
            expectedRevision: initial.selectionRevision,
            providerID: nil,
            idempotencyKey: "route-deactivate-selection"
        )
        let accepted = try request(
            port: fixture.port,
            path: "/api/manager/providers/selection",
            method: "PUT",
            body: try JSONEncoder().encode(deactivation),
            token: fixture.token
        )
        XCTAssertEqual(accepted.response.statusCode, 202)
        let acceptedOperation = try JSONDecoder().decode(
            ProviderIntegrationOperationSnapshot.self,
            from: accepted.data
        )

        let terminal = try await waitForTerminalOperation(
            port: fixture.port,
            token: fixture.token,
            operationID: acceptedOperation.operationID
        )
        XCTAssertEqual(terminal.phase, .completed)

        let terminalCancellation = try request(
            port: fixture.port,
            path: "/api/manager/provider-operations/\(terminal.operationID)/cancel",
            method: "POST",
            body: Data("{}".utf8),
            token: fixture.token
        )
        XCTAssertEqual(terminalCancellation.response.statusCode, 409)
        XCTAssertEqual(
            terminalCancellation.object["code"] as? String,
            "provider_operation_not_cancellable"
        )

        let missing = try request(
            port: fixture.port,
            path: "/api/manager/provider-operations/missing-operation",
            method: "GET",
            token: fixture.token
        )
        XCTAssertEqual(missing.response.statusCode, 404)
        XCTAssertEqual(missing.object["code"] as? String, "provider_operation_not_found")
    }

    func testProviderIntegrationErrorsHaveStableHTTPMappings() {
        let cases: [(ProviderIntegrationError, Int, String)] = [
            (.invalidRequest(field: "provider_id", reason: "fixture"), 400, "invalid_provider_integration_request"),
            (.providerNotSelectable(providerID: .codexDesktop), 400, "provider_not_selectable"),
            (.revisionConflict(expected: "a", actual: "b"), 409, "provider_selection_revision_conflict"),
            (.idempotencyConflict, 409, "provider_idempotency_conflict"),
            (.operationBusy(operationID: "busy"), 409, "provider_operation_busy"),
            (.providerHasNonterminalRuns(providerID: .codexDesktop), 409, "provider_has_nonterminal_runs"),
            (.providerNotReady(providerID: .lmStudio), 409, "provider_not_ready"),
            (.selectedProviderCannotBeRemoved(providerID: .lmStudio), 409, "selected_provider_cannot_be_removed"),
            (.operationNotCancellable(operationID: "done"), 409, "provider_operation_not_cancellable"),
            (.operationNotFound(operationID: "missing"), 404, "provider_operation_not_found"),
            (.adapterUnavailable(providerID: .grokBuild), 503, "provider_adapter_unavailable"),
            (.invalidAdapterResult(reason: "fixture"), 500, "invalid_provider_adapter_result"),
            (.ledgerCorrupt(reason: "fixture"), 500, "provider_integration_ledger_corrupt"),
            (.persistenceFailed(reason: "fixture"), 500, "provider_integration_persistence_failed"),
        ]

        for (error, expectedStatus, expectedCode) in cases {
            let mapping = ManagerRoutes.providerIntegrationHTTPFailure(error)
            XCTAssertEqual(mapping.status, expectedStatus, "Unexpected status for \(error)")
            XCTAssertEqual(mapping.code, expectedCode, "Unexpected code for \(error)")
        }
    }

    func testDesktopProviderHookRouteIsAuthenticatedAndNarrowlyFailClosed() throws {
        let fixture = try startManager()
        defer {
            _ = try? fixture.node.stopService()
            fixture.app.shutdown()
        }

        func envelope(toolName: String) throws -> Data {
            let payload = try JSONSupport.data(from: [
                "hook_event_name": DesktopProviderHookEvent.preToolUse.rawValue,
                "tool_name": toolName,
            ])
            return try DesktopProviderHookRequest(
                providerID: .codexDesktop,
                event: .preToolUse,
                hostPayload: payload
            ).envelopeData()
        }

        let unauthorized = try request(
            port: fixture.port,
            path: "/api/manager/providers/hooks",
            method: "POST",
            body: try envelope(toolName: "mcp__forge-conductor__fs_read"),
            token: nil
        )
        XCTAssertEqual(unauthorized.response.statusCode, 401)

        let unrelated = try request(
            port: fixture.port,
            path: "/api/manager/providers/hooks",
            method: "POST",
            body: try envelope(toolName: "fs_read"),
            token: fixture.token
        )
        XCTAssertEqual(unrelated.response.statusCode, 200)
        XCTAssertTrue(unrelated.object.isEmpty)

        let inactiveForgeTool = try request(
            port: fixture.port,
            path: "/api/manager/providers/hooks",
            method: "POST",
            body: try envelope(toolName: "mcp__forge-conductor__fs_read"),
            token: fixture.token
        )
        XCTAssertEqual(inactiveForgeTool.response.statusCode, 200)
        let output = try XCTUnwrap(
            inactiveForgeTool.object["hookSpecificOutput"] as? [String: Any]
        )
        XCTAssertEqual(output["permissionDecision"] as? String, "deny")
        XCTAssertEqual(
            output["hookEventName"] as? String,
            DesktopProviderHookEvent.preToolUse.rawValue
        )
    }

    func testBlockedDesktopPreparationKeepsListenerResponsiveAndRejectsOverlap() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        let port = try Self.availableLoopbackPort()
        let projectRoot = home.appendingPathComponent("route-readiness-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try app.config.update([
            "allowed_roots": [projectRoot.path],
            "dashboard": ["port": port],
        ], save: true)
        let adapter = BlockingRouteDesktopProviderAdapter()
        let coordinator = try ProviderIntegrationCoordinator(
            paths: app.paths,
            adapters: [adapter],
            defaultSelectedProviderID: nil
        )
        let initial = await coordinator.snapshot()
        let accepted = try await coordinator.select(ProviderSelectionRequest(
            expectedRevision: initial.selectionRevision,
            providerID: .codexDesktop,
            idempotencyKey: "route-blocked-desktop-selection"
        ))
        _ = try await coordinator.waitForOperation(operationID: accepted.operationID)
        let node = ManagerNode(app: app, providerIntegrationCoordinator: coordinator)
        defer {
            _ = try? node.stopService()
            app.shutdown()
        }
        let registered = try node.registerProject(path: projectRoot.path)
        let projectID = try XCTUnwrap(registered["project_id"] as? String)
        let generation = try XCTUnwrap(
            (registered["project_generation"] as? NSNumber)?.uint64Value
        )
        _ = try node.startService()
        let token = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        let body = try JSONSupport.data(from: [
            "project_id": projectID,
            "project_generation": generation,
            "mission": "Exercise one bounded live desktop readiness inspection.",
            "maximum_inline_output_bytes": 64 * 1_024,
        ])
        await adapter.setBlocked(true)

        let firstPreparation = Task {
            try await self.asyncRequest(
                port: port,
                path: "/api/manager/runs/prepare",
                method: "POST",
                body: body,
                token: token
            )
        }
        let enteredDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < enteredDeadline {
            if await adapter.state().entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let entered = await adapter.state()
        guard entered.entered else {
            await adapter.release()
            _ = try? await firstPreparation.value
            return XCTFail("The route fixture inspection never entered its bounded wait")
        }

        let pingStart = ContinuousClock.now
        let ping = try request(
            port: port,
            path: "/ping",
            method: "GET",
            token: token
        )
        XCTAssertEqual(ping.response.statusCode, 200)
        XCTAssertLessThan(pingStart.duration(to: ContinuousClock.now), .seconds(1))

        let overlapStart = ContinuousClock.now
        let overlap = try request(
            port: port,
            path: "/api/manager/runs/prepare",
            method: "POST",
            body: body,
            token: token
        )
        XCTAssertEqual(overlap.response.statusCode, 409)
        XCTAssertEqual(overlap.object["code"] as? String, "provider_readiness_busy")
        XCTAssertLessThan(overlapStart.duration(to: ContinuousClock.now), .seconds(1))
        let overlapState = await adapter.state()
        XCTAssertEqual(overlapState.calls, entered.calls)
        XCTAssertEqual(overlapState.maximumActive, 1)

        await adapter.release()
        let firstResponse = try await firstPreparation.value
        XCTAssertEqual(firstResponse.response.statusCode, 200)
        await adapter.setBlocked(false)
        let retry = try request(
            port: port,
            path: "/api/manager/runs/prepare",
            method: "POST",
            body: body,
            token: token
        )
        XCTAssertEqual(retry.response.statusCode, 200)
    }

    private func startManager() throws -> (
        app: ForgeApp,
        node: ManagerNode,
        port: Int,
        token: String
    ) {
        let app = try ForgeApp.bootstrap(home: home)
        let port = try Self.availableLoopbackPort()
        try app.config.update(["dashboard": ["port": port]], save: true)
        let node = ManagerNode(app: app)
        _ = try node.startService()
        let token = try ManagerControlCredentialStore(paths: app.paths).bearerToken()
        return (app, node, port, token)
    }

    private func request(
        port: Int,
        path: String,
        method: String,
        body: Data = Data(),
        token: String?
    ) throws -> (data: Data, response: HTTPURLResponse, object: [String: Any]) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        if !body.isEmpty {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try HTTPTestHelpers.fetch(request)
        let object = (try? JSONSupport.object(from: data)) ?? [:]
        return (data, response, object)
    }

    private func asyncRequest(
        port: Int,
        path: String,
        method: String,
        body: Data = Data(),
        token: String?
    ) async throws -> (data: Data, response: HTTPURLResponse, object: [String: Any]) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if !body.isEmpty {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let object = (try? JSONSupport.object(from: data)) ?? [:]
        return (data, httpResponse, object)
    }

    private func waitForTerminalOperation(
        port: Int,
        token: String,
        operationID: String
    ) async throws -> ProviderIntegrationOperationSnapshot {
        for _ in 0..<50 {
            let response = try request(
                port: port,
                path: "/api/manager/provider-operations/\(operationID)",
                method: "GET",
                token: token
            )
            XCTAssertEqual(response.response.statusCode, 200)
            let operation = try JSONDecoder().decode(
                ProviderIntegrationOperationSnapshot.self,
                from: response.data
            )
            if operation.isTerminal { return operation }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "ManagerProviderIntegrationRoutesTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Provider operation did not become terminal"]
        )
    }

    private static func availableLoopbackPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(
                domain: "ManagerProviderIntegrationRoutesTests.LoopbackPort",
                code: Int(errno)
            )
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bound == 0 else {
            throw NSError(
                domain: "ManagerProviderIntegrationRoutesTests.LoopbackPort",
                code: Int(errno)
            )
        }

        var selected = sockaddr_in()
        var selectedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &selected) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &selectedLength)
            }
        }
        guard named == 0 else {
            throw NSError(
                domain: "ManagerProviderIntegrationRoutesTests.LoopbackPort",
                code: Int(errno)
            )
        }
        return Int(UInt16(bigEndian: selected.sin_port))
    }
}

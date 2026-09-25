// DesktopProviderHookBridgeTests.swift
// Verifies bounded parsing, mutually exclusive provider policy, loopback transport,
// narrow failure denial, custom-home routing, and redirect rejection.

import XCTest
@testable import ForgeConductorCore

private final class DesktopHookCredentialFixture: ManagerMutationCredentialProviding, @unchecked Sendable {
    let token: String
    init(token: String = "desktop-hook-test-token") { self.token = token }
    func bearerToken() throws -> String { token }
}

private final class DesktopHookURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case body(status: Int, data: Data, declaredLength: Int? = nil)
        case failure
    }

    struct Capture: @unchecked Sendable {
        let url: URL?
        let authorization: String?
        let contentType: String?
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply: Reply = .failure
    nonisolated(unsafe) private static var captures: [Capture] = []

    static func configure(_ reply: Reply) {
        lock.lock()
        self.reply = reply
        captures = []
        lock.unlock()
    }

    static func recorded() -> [Capture] {
        lock.lock(); defer { lock.unlock() }
        return captures
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var requestBody = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0,
                      requestBody.count <= DesktopProviderHookContract.maximumEnvelopeBytes - count else {
                    break
                }
                requestBody.append(buffer, count: count)
            }
        }
        Self.lock.lock()
        Self.captures.append(Capture(
            url: request.url,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: requestBody
        ))
        let reply = Self.reply
        Self.lock.unlock()

        switch reply {
        case .failure:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case .body(let status, let data, let declaredLength):
            var headers = ["Content-Type": "application/json"]
            if let declaredLength { headers["Content-Length"] = String(declaredLength) }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class DesktopProviderHookBridgeTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "desktop-provider-hook-\(UUID().uuidString)",
            isDirectory: true
        )
        try AppPaths(home: home).ensureLayout()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        home = nil
    }

    func testRequestRejectsNonDesktopProviderMismatchedEventAndBounds() throws {
        XCTAssertThrowsError(try DesktopProviderHookRequest(
            providerID: .lmStudio,
            event: .sessionStart,
            hostPayload: Data("{}".utf8)
        ))

        XCTAssertThrowsError(try DesktopProviderHookRequest(
            providerID: .claudeDesktop,
            event: .sessionStart,
            hostPayload: Data(#"{"hook_event_name":"PreToolUse"}"#.utf8)
        )) { error in
            XCTAssertEqual(error as? DesktopProviderHookError, .eventMismatch)
        }

        XCTAssertThrowsError(try DesktopProviderHookRequest(
            providerID: .claudeDesktop,
            event: .sessionStart,
            hostPayload: Data(repeating: 32, count: DesktopProviderHookContract.maximumInputBytes + 1)
        )) { error in
            XCTAssertEqual(error as? DesktopProviderHookError, .inputTooLarge)
        }

        let deep = String(repeating: #"{"v":"#, count: DesktopProviderHookContract.maximumDepth + 2)
            + "{}"
            + String(repeating: "}", count: DesktopProviderHookContract.maximumDepth + 2)
        XCTAssertThrowsError(try DesktopProviderHookRequest(
            providerID: .claudeDesktop,
            event: .sessionStart,
            hostPayload: Data(deep.utf8)
        ))
    }

    func testEnvelopeRoundTripPreservesBoundedHostFields() throws {
        let original = try request(
            provider: .grokBuild,
            event: .preToolUse,
            tool: "mcp__forge__project_memory_search"
        )
        let decoded = try DesktopProviderHookRequest(envelopeData: original.envelopeData())
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.sessionID, "session-1")
        XCTAssertEqual(decoded.workingDirectory, "/tmp/project")
        XCTAssertEqual(decoded.toolName, "mcp__forge__project_memory_search")
    }

    func testGrokCamelCaseHookFieldsRoundTripAndConflictsFailClosed() throws {
        let runID = RunID()
        let completion = """
        {"forge_run_status":"completion_requested","run_id":"\(runID.description)","summary":"Grok finished the assigned work."}
        """
        let payload: [String: Any] = [
            "hookEventName": "Stop",
            "sessionId": "grok-session-1",
            "cwd": "/tmp/grok-project",
            "toolName": "forge-conductor__forge_status",
            "lastAssistantMessage": completion,
        ]
        let original = try DesktopProviderHookRequest(
            providerID: .grokBuild,
            event: .stop,
            hostPayload: try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
        )
        let decoded = try DesktopProviderHookRequest(
            envelopeData: original.envelopeData()
        )

        XCTAssertEqual(decoded.sessionID, "grok-session-1")
        XCTAssertEqual(decoded.workingDirectory, "/tmp/grok-project")
        XCTAssertEqual(decoded.toolName, "forge-conductor__forge_status")
        XCTAssertEqual(decoded.lastAssistantMessage, completion)
        XCTAssertEqual(decoded.completionRequest()?.runID, runID)

        var conflicting = payload
        conflicting["session_id"] = "different-session"
        XCTAssertThrowsError(try DesktopProviderHookRequest(
            providerID: .grokBuild,
            event: .stop,
            hostPayload: try JSONSerialization.data(withJSONObject: conflicting)
        )) { error in
            XCTAssertEqual(error as? DesktopProviderHookError, .invalidEnvelope)
        }

        var conflictingEvent = payload
        conflictingEvent["hook_event_name"] = "PreToolUse"
        XCTAssertThrowsError(try DesktopProviderHookRequest(
            providerID: .grokBuild,
            event: .stop,
            hostPayload: try JSONSerialization.data(withJSONObject: conflictingEvent)
        )) { error in
            XCTAssertEqual(error as? DesktopProviderHookError, .invalidEnvelope)
        }
    }

    func testInactiveProviderDeniesForgeMCPButNotUnrelatedTools() throws {
        let policy = DesktopProviderHookPolicyService()
        let snapshot = providerSnapshot(selected: .codexDesktop)
        let forgeResponse = policy.response(
            snapshot: snapshot,
            request: try request(provider: .claudeDesktop, event: .preToolUse, tool: "forge_status")
        ).asDictionary()
        let forgeOutput = try XCTUnwrap(forgeResponse["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(forgeOutput["permissionDecision"] as? String, "deny")
        XCTAssertEqual(forgeOutput["hookEventName"] as? String, "PreToolUse")

        let unrelated = policy.response(
            snapshot: snapshot,
            request: try request(provider: .claudeDesktop, event: .preToolUse, tool: "Read")
        )
        XCTAssertEqual(unrelated, .empty)
        let genericNameCollision = policy.response(
            snapshot: snapshot,
            request: try request(provider: .claudeDesktop, event: .preToolUse, tool: "fs_read")
        )
        XCTAssertEqual(genericNameCollision, .empty)

        let inactiveGrok = policy.response(
            snapshot: snapshot,
            request: try DesktopProviderHookRequest(
                providerID: .grokBuild,
                event: .preToolUse,
                hostPayload: try JSONSerialization.data(withJSONObject: [
                    "hookEventName": "PreToolUse",
                    "sessionId": "grok-session",
                    "cwd": "/tmp/project",
                    "toolName": "forge-conductor__project_memory_search",
                ])
            )
        ).asDictionary()
        XCTAssertEqual(inactiveGrok["decision"] as? String, "deny")
        XCTAssertNotNil(inactiveGrok["reason"] as? String)
        XCTAssertNil(inactiveGrok["hookSpecificOutput"])
        let nearPrefix = policy.response(
            snapshot: snapshot,
            request: try DesktopProviderHookRequest(
                providerID: .grokBuild,
                event: .preToolUse,
                hostPayload: try JSONSerialization.data(withJSONObject: [
                    "hookEventName": "PreToolUse",
                    "sessionId": "grok-session",
                    "cwd": "/tmp/project",
                    "toolName": "forge-conductorial__project_memory_search",
                ])
            )
        )
        XCTAssertEqual(nearPrefix, .empty)
        XCTAssertTrue(DesktopProviderHookPolicyService.isForgeMCPTool(
            "mcp__forge-conductor__fs_read",
            providerID: .codexDesktop
        ))
        XCTAssertFalse(DesktopProviderHookPolicyService.isForgeMCPTool(
            "mcp__forgery__fs_read",
            providerID: .codexDesktop
        ))
    }

    func testActiveSessionContextDescribesOrchestrationMCPBoundary() throws {
        let response = DesktopProviderHookPolicyService().response(
            snapshot: providerSnapshot(selected: .codexDesktop),
            request: try request(provider: .codexDesktop, event: .sessionStart)
        ).asDictionary()
        let output = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        let context = try XCTUnwrap(output["additionalContext"] as? String)
        XCTAssertTrue(context.contains("orchestration and MCP layer"))
        XCTAssertTrue(context.contains("not a direct model API"))
        XCTAssertEqual(output["hookEventName"] as? String, "SessionStart")
    }

    func testGrokPassiveHooksEmitNoIgnoredAssignmentContext() throws {
        let response = DesktopProviderHookPolicyService().response(
            snapshot: providerSnapshot(selected: .grokBuild),
            request: try DesktopProviderHookRequest(
                providerID: .grokBuild,
                event: .sessionStart,
                hostPayload: try JSONSerialization.data(withJSONObject: [
                    "hookEventName": "SessionStart",
                    "sessionId": "grok-session",
                    "cwd": "/tmp/project",
                ])
            ),
            runDirective: .context("This text cannot be delivered by a passive Grok hook.")
        )

        XCTAssertEqual(response, .empty)
    }

    func testGrokFailureFallbackUsesDocumentedTopLevelDenial() throws {
        let request = try DesktopProviderHookRequest(
            providerID: .grokBuild,
            event: .preToolUse,
            hostPayload: try JSONSerialization.data(withJSONObject: [
                "hookEventName": "PreToolUse",
                "sessionId": "grok-session",
                "cwd": "/tmp/project",
                "toolName": "forge-conductor__project_memory_search",
            ])
        )

        let response = DesktopProviderHookPolicyService.failureFallback(
            for: request
        ).asDictionary()

        XCTAssertEqual(response["decision"] as? String, "deny")
        XCTAssertNotNil(response["reason"] as? String)
        XCTAssertNil(response["hookSpecificOutput"])
    }

    func testClientUsesCustomHomeConfigLoopbackAndBearer() async throws {
        let paths = AppPaths(home: home)
        let config = ConfigStore(paths: paths)
        _ = try config.update([
            "dashboard": ["host": "0.0.0.0", "port": 47_123],
        ])
        let exactResponse = Data(" {\"hookSpecificOutput\":{\"additionalContext\":\"ok\"}}\n".utf8)
        DesktopHookURLProtocol.configure(.body(status: 200, data: exactResponse))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [DesktopHookURLProtocol.self]
        let bridge = DesktopProviderHookBridge(
            paths: paths,
            sessionConfiguration: sessionConfiguration,
            credentials: DesktopHookCredentialFixture()
        )

        let result = await bridge.forward(try request(
            provider: .codexDesktop,
            event: .sessionStart
        ))
        XCTAssertEqual(result, exactResponse)
        let capture = try XCTUnwrap(DesktopHookURLProtocol.recorded().first)
        XCTAssertEqual(capture.url?.scheme, "http")
        XCTAssertEqual(capture.url?.host, "127.0.0.1")
        XCTAssertEqual(capture.url?.port, 47_123)
        XCTAssertEqual(capture.url?.path, "/api/manager/providers/hooks")
        XCTAssertEqual(capture.authorization, "Bearer desktop-hook-test-token")
        XCTAssertEqual(capture.contentType, "application/json")
        let envelope = try DesktopProviderHookRequest(envelopeData: capture.body)
        XCTAssertEqual(envelope.providerID, .codexDesktop)
        XCTAssertEqual(envelope.event, .sessionStart)
    }

    func testManagerFailureDeniesOnlyForgeTool() async throws {
        let paths = AppPaths(home: home)
        DesktopHookURLProtocol.configure(.failure)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [DesktopHookURLProtocol.self]
        let bridge = DesktopProviderHookBridge(
            paths: paths,
            sessionConfiguration: sessionConfiguration,
            credentials: DesktopHookCredentialFixture()
        )

        let forgeResult = await bridge.forward(try request(
            provider: .claudeDesktop,
            event: .preToolUse,
            tool: "mcp__forge_conductor__memory_search"
        ))
        let forgeObject = try JSONSupport.object(from: forgeResult)
        let forgeOutput = try XCTUnwrap(forgeObject["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(forgeOutput["permissionDecision"] as? String, "deny")

        let unrelatedResult = await bridge.forward(try request(
            provider: .claudeDesktop,
            event: .preToolUse,
            tool: "fs_read"
        ))
        XCTAssertEqual(try JSONSupport.object(from: unrelatedResult).count, 0)
    }

    func testRemoteManagerConfigurationIsNeverContacted() async throws {
        let paths = AppPaths(home: home)
        _ = try ConfigStore(paths: paths).update([
            "dashboard": ["host": "192.0.2.40", "port": 47_124],
        ])
        DesktopHookURLProtocol.configure(.body(status: 200, data: Data("{}".utf8)))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [DesktopHookURLProtocol.self]
        let bridge = DesktopProviderHookBridge(
            paths: paths,
            sessionConfiguration: sessionConfiguration,
            credentials: DesktopHookCredentialFixture()
        )
        let result = await bridge.forward(try request(
            provider: .grokBuild,
            event: .preToolUse,
            tool: "Read"
        ))
        XCTAssertEqual(try JSONSupport.object(from: result).count, 0)
        XCTAssertTrue(DesktopHookURLProtocol.recorded().isEmpty)
    }

    func testManagerAutoAllowResponseIsRejectedAndFallsBack() async throws {
        let paths = AppPaths(home: home)
        DesktopHookURLProtocol.configure(.body(
            status: 200,
            data: Data(#"{"hookSpecificOutput":{"permissionDecision":"allow"}}"#.utf8)
        ))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [DesktopHookURLProtocol.self]
        let bridge = DesktopProviderHookBridge(
            paths: paths,
            sessionConfiguration: sessionConfiguration,
            credentials: DesktopHookCredentialFixture()
        )
        let result = await bridge.forward(try request(
            provider: .codexDesktop,
            event: .preToolUse,
            tool: "forge_status"
        ))
        let output = try XCTUnwrap(
            JSONSupport.object(from: result)["hookSpecificOutput"] as? [String: Any]
        )
        XCTAssertEqual(output["permissionDecision"] as? String, "deny")
    }

    func testRedirectGuardRejectsRedirectRequest() throws {
        let originalURL = try XCTUnwrap(URL(string: "http://127.0.0.1:7788/api/manager/providers/hooks"))
        let redirectURL = try XCTUnwrap(URL(string: "http://example.invalid/capture"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: originalURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: originalURL,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectURL.absoluteString]
        ))
        let expectation = expectation(description: "redirect rejected")
        var followedRequest: URLRequest? = URLRequest(url: redirectURL)
        DesktopProviderHookRedirectGuard().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectURL)
        ) { request in
            followedRequest = request
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertNil(followedRequest)
    }

    func testInvocationRequiresBoundedCustomHome() throws {
        let invocation = try DesktopProviderHookInvocation.parse(arguments: [
            "grok-build", "SessionStart", "--home", home.path,
        ])
        XCTAssertEqual(invocation.providerID, .grokBuild)
        XCTAssertEqual(invocation.event, .sessionStart)
        XCTAssertEqual(invocation.home, home.standardizedFileURL)
        XCTAssertThrowsError(try DesktopProviderHookInvocation.parse(arguments: [
            "lmstudio", "SessionStart", "--home", home.path,
        ]))
        XCTAssertThrowsError(try DesktopProviderHookInvocation.parse(arguments: [
            "grok-build", "SessionStart", "--home", "relative/path",
        ]))
    }

    func testDesktopRunLifecycleScopesClaimAdvancesAndCompletesWithNativeGate() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let firstRoot = home.appendingPathComponent("first-project", isDirectory: true)
        let secondRoot = home.appendingPathComponent("second-project", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let firstProject = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "First", canonicalRoot: firstRoot
        )
        let secondProject = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "Second", canonicalRoot: secondRoot
        )
        let validator = try GateValidatorRegistry(validators: [
            CompletionGateValidator(gate: "desktop_fixture") { _ in
                CompletionGateResult(
                    gate: "desktop_fixture",
                    passed: true,
                    summary: "Desktop fixture passed",
                    evidenceReferences: ["fixture:desktop-provider"]
                )
            },
        ])
        let runtime = try ManagedAutonomyRuntime(
            app: app,
            registry: HostAdapterRegistry(),
            maximumConcurrentRuns: 1,
            completionValidator: validator
        )
        _ = try await runtime.start()
        do {
            let first = try await runtime.createRun(desktopRunRequest(
                project: firstProject, root: firstRoot, selectionRevision: "selection-1"
            ))
            let second = try await runtime.createRun(desktopRunRequest(
                project: secondProject, root: secondRoot, selectionRevision: "selection-1"
            ))
            let claimed = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(
                    event: .sessionStart,
                    sessionID: "desktop-session-1",
                    cwd: secondRoot.path
                ),
                selectionRevision: "selection-1"
            )
            guard case .context(let context) = claimed else {
                return XCTFail("Desktop session did not receive its run assignment")
            }
            XCTAssertTrue(context.contains(second.runID.description))
            XCTAssertTrue(context.contains("forge_run_status"))
            let untouchedFirst = try await app.projectContexts.repository.autonomousRun(first.runID)
            XCTAssertEqual(
                untouchedFirst?.state,
                .created,
                "A desktop session must not claim work from another project"
            )
            let runningValue = try await app.projectContexts.repository.autonomousRun(second.runID)
            let running = try XCTUnwrap(runningValue)
            XCTAssertEqual(running.state, .running)
            XCTAssertEqual(running.activeSessionID, "desktop-session-1")

            let fetched = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(
                    event: .userPromptSubmit,
                    sessionID: "desktop-session-1",
                    cwd: secondRoot.path
                ),
                selectionRevision: "selection-1"
            )
            guard case .context(let fetchedContext) = fetched else {
                return XCTFail("Claimed desktop run was not fetched idempotently")
            }
            XCTAssertTrue(fetchedContext.contains(second.runID.description))
            let fetchedRun = try await app.projectContexts.repository.autonomousRun(second.runID)
            XCTAssertEqual(
                fetchedRun?.revision,
                running.revision,
                "Fetching an existing assignment must not manufacture a state transition"
            )

            _ = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(
                    event: .postToolUse,
                    sessionID: "desktop-session-1",
                    cwd: secondRoot.path,
                    tool: "mcp__forge-conductor__fs_read"
                ),
                selectionRevision: "selection-1"
            )
            let advancedValue = try await app.projectContexts.repository.autonomousRun(second.runID)
            let advanced = try XCTUnwrap(advancedValue)
            XCTAssertGreaterThan(advanced.revision, running.revision)
            XCTAssertEqual(
                advanced.specification.work.metadata["desktop_plugin_last_tool"],
                "mcp__forge-conductor__fs_read"
            )
            XCTAssertEqual(
                advanced.specification.work.metadata[
                    DesktopProviderEvidenceMetadata.successfulToolNames
                ],
                #"["fs_read"]"#
            )

            let marker = try JSONSupport.canonicalJSON([
                "forge_run_status": "completion_requested",
                "run_id": second.runID.description,
                "summary": "The desktop fixture is ready for validation",
            ])
            let stop = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(
                    event: .stop,
                    sessionID: "desktop-session-1",
                    cwd: secondRoot.path,
                    lastAssistantMessage: "Finished. \(marker)"
                ),
                selectionRevision: "selection-1"
            )
            guard case .continueRun(let reason) = stop else {
                return XCTFail("Completion validation must keep the host turn active")
            }
            XCTAssertTrue(reason.contains("completion requirements"))
            let completed = try await waitForDesktopRun(
                repository: app.projectContexts.repository,
                runID: second.runID,
                state: .completed
            )
            XCTAssertEqual(completed.state, .completed)
            let stillUntouched = try await app.projectContexts.repository.autonomousRun(first.runID)
            XCTAssertEqual(stillUntouched?.state, .created)
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }

    func testDesktopUnmetRequirementReturnsToRunningInsteadOfBlockedConfiguration() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent(
            "unmet-completion-requirement",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(),
            displayName: "Unmet completion requirement",
            canonicalRoot: projectRoot
        )
        let validator = try GateValidatorRegistry(validators: [
            CompletionGateValidator(gate: "desktop_fixture") { _ in
                CompletionGateResult(
                    gate: "desktop_fixture",
                    passed: false,
                    summary: "More project evidence is required",
                    blocker: .unregisteredValidator
                )
            },
        ])
        let runtime = try ManagedAutonomyRuntime(
            app: app,
            registry: HostAdapterRegistry(),
            maximumConcurrentRuns: 1,
            completionValidator: validator
        )
        _ = try await runtime.start()
        do {
            let run = try await runtime.createRun(desktopRunRequest(
                project: project,
                root: projectRoot,
                selectionRevision: "unmet-requirement-selection"
            ))
            _ = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(
                    event: .sessionStart,
                    sessionID: "unmet-requirement-session",
                    cwd: projectRoot.path
                ),
                selectionRevision: "unmet-requirement-selection"
            )
            let marker = try JSONSupport.canonicalJSON([
                "forge_run_status": "completion_requested",
                "run_id": run.runID.description,
                "summary": "Request completion before the evidence is sufficient",
            ])
            _ = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(
                    event: .stop,
                    sessionID: "unmet-requirement-session",
                    cwd: projectRoot.path,
                    lastAssistantMessage: marker
                ),
                selectionRevision: "unmet-requirement-selection"
            )

            let deadline = ContinuousClock.now + .seconds(5)
            var rejected = false
            while ContinuousClock.now < deadline {
                let events = try await app.projectContexts.repository.autonomyEvents(
                    runID: run.runID
                )
                if events.contains(where: {
                    $0.eventType == "desktop_plugin_completion_rejected"
                }) {
                    rejected = true
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(rejected)
            let retainedValue = try await app.projectContexts.repository.autonomousRun(
                run.runID
            )
            let retained = try XCTUnwrap(retainedValue)
            XCTAssertEqual(retained.state, .running)
            XCTAssertNotEqual(retained.state, .blockedConfiguration)
            XCTAssertEqual(
                retained.lastErrorCode,
                AutonomyError.completionValidationFailed.code
            )
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }

    func testDesktopSessionEndMakesRunRecoverableForANewSession() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent("recovery-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "Recovery", canonicalRoot: projectRoot
        )
        let runtime = try ManagedAutonomyRuntime(
            app: app,
            registry: HostAdapterRegistry(),
            maximumConcurrentRuns: 1
        )
        _ = try await runtime.start()
        do {
            let run = try await runtime.createRun(desktopRunRequest(
                project: project, root: projectRoot, selectionRevision: "selection-2"
            ))
            _ = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(event: .sessionStart, sessionID: "old-session", cwd: projectRoot.path),
                selectionRevision: "selection-2"
            )
            _ = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(event: .sessionEnd, sessionID: "old-session", cwd: projectRoot.path),
                selectionRevision: "selection-2"
            )
            let recoverableValue = try await app.projectContexts.repository.autonomousRun(run.runID)
            let recoverable = try XCTUnwrap(recoverableValue)
            XCTAssertEqual(recoverable.state, .failedRecoverable)
            XCTAssertEqual(
                recoverable.specification.work.metadata["desktop_plugin_session_state"],
                "ended"
            )

            let reclaimed = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(event: .sessionStart, sessionID: "new-session", cwd: projectRoot.path),
                selectionRevision: "selection-2"
            )
            guard case .context(let context) = reclaimed else {
                return XCTFail("New desktop session did not reclaim recoverable work")
            }
            XCTAssertTrue(context.contains(run.runID.description))
            let resumedValue = try await app.projectContexts.repository.autonomousRun(run.runID)
            let resumed = try XCTUnwrap(resumedValue)
            XCTAssertEqual(resumed.state, .running)
            XCTAssertEqual(resumed.activeSessionID, "new-session")
            XCTAssertEqual(
                resumed.specification.work.metadata["desktop_plugin_session_state"],
                "active"
            )
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }

    func testDesktopToolActivityUsesBoundedProjectionAndPreservesLifecycleEvents() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent("bounded-activity-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "Bounded Activity", canonicalRoot: projectRoot
        )
        let runtime = try ManagedAutonomyRuntime(
            app: app,
            registry: HostAdapterRegistry(),
            maximumConcurrentRuns: 1
        )
        _ = try await runtime.start()
        do {
            let run = try await runtime.createRun(desktopRunRequest(
                project: project,
                root: projectRoot,
                selectionRevision: "bounded-activity-selection"
            ))
            _ = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(
                    event: .sessionStart,
                    sessionID: "bounded-activity-session",
                    cwd: projectRoot.path
                ),
                selectionRevision: "bounded-activity-selection"
            )

            let activityLimit = ProjectControlPlaneRepository.maximumManagedToolActivityEventsPerRun
            let eventCycle: [DesktopProviderHookEvent] = [
                .preToolUse,
                .postToolUse,
                .postToolUseFailure,
            ]
            var firstActivitySequence: Int64?
            let activityCount = activityLimit + 9
            for index in 0..<activityCount {
                let event = eventCycle[index % eventCycle.count]
                _ = try await runtime.handleDesktopProviderHook(
                    lifecycleRequest(
                        event: event,
                        sessionID: "bounded-activity-session",
                        cwd: projectRoot.path,
                        tool: "desktop-tool-\(index)"
                    ),
                    selectionRevision: "bounded-activity-selection"
                )
                if index == 0 {
                    firstActivitySequence = try await app.projectContexts.repository.autonomyEvents(
                        runID: run.runID,
                        limit: 16
                    ).first(where: { $0.eventType.hasPrefix("managed_activity_tool_desktop_") })?
                        .sequence
                }
            }

            let events = try await app.projectContexts.repository.autonomyEvents(
                runID: run.runID,
                limit: 1_000
            )
            let activityEvents = events.filter {
                $0.eventType.hasPrefix("managed_activity_tool_desktop_")
            }
            XCTAssertEqual(activityEvents.count, activityLimit)
            XCTAssertFalse(activityEvents.contains { $0.sequence == firstActivitySequence })
            XCTAssertTrue(events.contains { $0.eventType == "desktop_plugin_run_claimed" })
            XCTAssertFalse(events.contains {
                $0.eventType == "desktop_plugin_activity_recorded"
                    || $0.eventType == "desktop_plugin_tool_failed"
            })

            let currentValue = try await app.projectContexts.repository.autonomousRun(run.runID)
            let current = try XCTUnwrap(currentValue)
            let finalEvent = eventCycle[(activityCount - 1) % eventCycle.count]
            XCTAssertEqual(
                current.specification.work.metadata["desktop_plugin_last_event"],
                finalEvent.rawValue
            )
            XCTAssertEqual(
                current.specification.work.metadata["desktop_plugin_last_tool"],
                "desktop-tool-\(activityCount - 1)"
            )
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }

    func testManagerRestartReleasesClaimAndOrdinaryTickPreservesReclaimedSession() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent("restart-recovery-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "Restart Recovery", canonicalRoot: projectRoot
        )
        let firstRuntime = try ManagedAutonomyRuntime(
            app: app,
            registry: HostAdapterRegistry(),
            maximumConcurrentRuns: 1
        )
        _ = try await firstRuntime.start()
        let run = try await firstRuntime.createRun(desktopRunRequest(
            project: project,
            root: projectRoot,
            selectionRevision: "restart-selection"
        ))
        _ = try await firstRuntime.handleDesktopProviderHook(
            lifecycleRequest(
                event: .sessionStart,
                sessionID: "interrupted-session",
                cwd: projectRoot.path
            ),
            selectionRevision: "restart-selection"
        )
        let claimed = try await app.projectContexts.repository.autonomousRun(run.runID)
        XCTAssertEqual(claimed?.state, .running)
        XCTAssertEqual(claimed?.activeSessionID, "interrupted-session")
        await firstRuntime.shutdown()

        let restartedRuntime = try ManagedAutonomyRuntime(
            app: app,
            registry: HostAdapterRegistry(),
            maximumConcurrentRuns: 1
        )
        _ = try await restartedRuntime.start()
        do {
            let recoveredValue = try await app.projectContexts.repository.autonomousRun(run.runID)
            let recovered = try XCTUnwrap(recoveredValue)
            XCTAssertEqual(recovered.state, .failedRecoverable)
            XCTAssertEqual(recovered.lastErrorCode, "desktop_plugin_manager_restarted")
            XCTAssertEqual(
                recovered.specification.work.metadata["desktop_plugin_session_state"],
                "ended"
            )

            let directive = try await restartedRuntime.handleDesktopProviderHook(
                lifecycleRequest(
                    event: .sessionStart,
                    sessionID: "replacement-session",
                    cwd: projectRoot.path
                ),
                selectionRevision: "restart-selection"
            )
            guard case .context(let context) = directive else {
                return XCTFail("Replacement desktop session did not reclaim the interrupted run")
            }
            XCTAssertTrue(context.contains(run.runID.description))
            try await restartedRuntime.tick()
            let retainedValue = try await app.projectContexts.repository.autonomousRun(run.runID)
            let retained = try XCTUnwrap(retainedValue)
            XCTAssertEqual(retained.state, .running)
            XCTAssertEqual(retained.activeSessionID, "replacement-session")
            XCTAssertEqual(
                retained.specification.work.metadata["desktop_plugin_session_state"],
                "active"
            )
        } catch {
            await restartedRuntime.shutdown()
            throw error
        }
        await restartedRuntime.shutdown()
    }

    func testManagerRestartReleasesEveryPersistedDesktopClaimBoundary() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent(
            "restart-claim-boundaries",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(),
            displayName: "Restart Claim Boundaries",
            canonicalRoot: projectRoot
        )
        let firstRuntime = try ManagedAutonomyRuntime(
            app: app,
            registry: HostAdapterRegistry(),
            maximumConcurrentRuns: 1
        )
        _ = try await firstRuntime.start()
        let paths: [(AutonomousRunState, [AutonomousRunState])] = [
            (.validating, [.validating]),
            (.ready, [.validating, .ready]),
            (.starting, [.validating, .ready, .starting]),
            (.recovering, [.validating, .ready, .starting, .running, .recovering]),
            (
                .validatingCompletion,
                [.validating, .ready, .starting, .running, .validatingCompletion]
            ),
        ]
        var runIDs: [AutonomousRunState: RunID] = [:]
        for (target, path) in paths {
            let created = try await app.projectContexts.repository.createAutonomousRun(desktopRunRequest(
                project: project,
                root: projectRoot,
                selectionRevision: "restart-boundary-selection"
            ))
            var current = created
            var work = current.specification.work
            let sessionID = "interrupted-\(target.rawValue)"
            work.metadata["desktop_plugin_session_id"] = sessionID
            work.metadata["desktop_plugin_provider_id"] = ProviderIntegrationID.codexDesktop.rawValue
            work.metadata["desktop_plugin_session_state"] = "active"
            for nextState in path {
                let lease = try await app.projectContexts.repository.acquireRunLease(
                    runID: current.runID,
                    ownerID: "restart-boundary-test:\(UUID().uuidString.lowercased())"
                )
                do {
                    current = try await app.projectContexts.repository.transitionAutonomousRun(
                        runID: current.runID,
                        lease: lease,
                        transition: AutonomousRunTransition(
                            expectedState: current.state,
                            expectedRevision: current.revision,
                            nextState: nextState,
                            eventType: "desktop_claim_boundary_fixture",
                            eventSummary: "Persist a desktop claim boundary fixture",
                            work: work,
                            activeSessionID: sessionID,
                            completionRequestJSON: nextState == .validatingCompletion
                                ? "{\"request\":\"fixture\"}" : nil
                        )
                    )
                    _ = try await app.projectContexts.repository.releaseRunLease(lease)
                } catch {
                    _ = try? await app.projectContexts.repository.releaseRunLease(lease)
                    throw error
                }
            }
            XCTAssertEqual(current.state, target)
            runIDs[target] = current.runID
        }
        await firstRuntime.shutdown()

        let restartedRuntime = try ManagedAutonomyRuntime(
            app: app,
            registry: HostAdapterRegistry(),
            maximumConcurrentRuns: 1
        )
        _ = try await restartedRuntime.start()
        do {
            for (priorState, runID) in runIDs {
                let recoveredValue = try await app.projectContexts.repository.autonomousRun(runID)
                let recovered = try XCTUnwrap(recoveredValue)
                XCTAssertEqual(
                    recovered.state,
                    .failedRecoverable,
                    "restart did not recover \(priorState.rawValue)"
                )
                XCTAssertEqual(
                    recovered.specification.work.metadata["desktop_plugin_session_state"],
                    "ended"
                )
                XCTAssertEqual(recovered.lastErrorCode, "desktop_plugin_manager_restarted")
            }
        } catch {
            await restartedRuntime.shutdown()
            throw error
        }
        await restartedRuntime.shutdown()
    }

    func testDesktopClaimChoosesMostSpecificNestedProject() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let outerRoot = home.appendingPathComponent("outer", isDirectory: true)
        let innerRoot = outerRoot.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: innerRoot, withIntermediateDirectories: true)
        let outer = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "Outer", canonicalRoot: outerRoot
        )
        let inner = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "Inner", canonicalRoot: innerRoot
        )
        let runtime = try ManagedAutonomyRuntime(app: app, registry: HostAdapterRegistry())
        _ = try await runtime.start()
        do {
            let outerRun = try await runtime.createRun(desktopRunRequest(
                project: outer, root: outerRoot, selectionRevision: "nested-selection"
            ))
            let innerRun = try await runtime.createRun(desktopRunRequest(
                project: inner, root: innerRoot, selectionRevision: "nested-selection"
            ))
            let directive = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(event: .sessionStart, sessionID: "nested-session", cwd: innerRoot.path),
                selectionRevision: "nested-selection"
            )
            guard case .context(let context) = directive else {
                return XCTFail("Nested project did not receive an assignment")
            }
            XCTAssertTrue(context.contains(innerRun.runID.description))
            let outerStored = try await app.projectContexts.repository.autonomousRun(outerRun.runID)
            let innerStored = try await app.projectContexts.repository.autonomousRun(innerRun.runID)
            XCTAssertEqual(outerStored?.state, .created)
            XCTAssertEqual(innerStored?.state, .running)
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }

    func testDesktopCompletionExceptionBecomesDurablyRecoverable() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent("completion-error", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "Completion Error", canonicalRoot: projectRoot
        )
        let throwingValidator = try GateValidatorRegistry(validators: [
            CompletionGateValidator(gate: "desktop_fixture") { _ in
                throw AutonomyError.intentConflict
            },
        ])
        let runtime = try ManagedAutonomyRuntime(
            app: app,
            registry: HostAdapterRegistry(),
            completionValidator: throwingValidator
        )
        _ = try await runtime.start()
        do {
            let run = try await runtime.createRun(desktopRunRequest(
                project: project, root: projectRoot, selectionRevision: "error-selection"
            ))
            _ = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(event: .sessionStart, sessionID: "error-session", cwd: projectRoot.path),
                selectionRevision: "error-selection"
            )
            let marker = try JSONSupport.canonicalJSON([
                "forge_run_status": "completion_requested",
                "run_id": run.runID.description,
                "summary": "Exercise recoverable completion failure",
            ])
            _ = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(
                    event: .stop,
                    sessionID: "error-session",
                    cwd: projectRoot.path,
                    lastAssistantMessage: marker
                ),
                selectionRevision: "error-selection"
            )
            let recoverable = try await waitForDesktopRun(
                repository: app.projectContexts.repository,
                runID: run.runID,
                state: .failedRecoverable
            )
            XCTAssertEqual(recoverable.lastErrorCode, "desktop_completion_validation_failed")
            XCTAssertTrue(recoverable.specification.work.nextAction?.contains("Retry") == true)

            let resumed = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(event: .userPromptSubmit, sessionID: "error-session", cwd: projectRoot.path),
                selectionRevision: "error-selection"
            )
            guard case .context = resumed else {
                return XCTFail("The same desktop session could not recover its failed validation")
            }
            let running = try await app.projectContexts.repository.autonomousRun(run.runID)
            XCTAssertEqual(running?.state, .running)
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }

    func testUnclaimedDesktopCancellationSettlesWithoutHookSession() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent("cancel-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "Cancel", canonicalRoot: projectRoot
        )
        let run = try await app.projectContexts.repository.createAutonomousRun(desktopRunRequest(
            project: project, root: projectRoot, selectionRevision: "cancel-selection"
        ))
        let stagingLease = try await app.projectContexts.repository.acquireRunLease(
            runID: run.runID,
            ownerID: "desktop-cancel-restart-fixture"
        )
        _ = try await app.projectContexts.repository.transitionAutonomousRun(
            runID: run.runID,
            lease: stagingLease,
            transition: AutonomousRunTransition(
                expectedState: run.state,
                expectedRevision: run.revision,
                nextState: .cancelRequested,
                eventType: "desktop_cancel_restart_fixture",
                eventSummary: "Simulate a persisted unclaimed cancellation"
            )
        )
        _ = try await app.projectContexts.repository.releaseRunLease(stagingLease)
        let runtime = try ManagedAutonomyRuntime(app: app, registry: HostAdapterRegistry())
        _ = try await runtime.start()
        do {
            let cancelled = try await waitForDesktopRun(
                repository: app.projectContexts.repository,
                runID: run.runID,
                state: .cancelled
            )
            XCTAssertEqual(cancelled.state, .cancelled)
            XCTAssertNil(cancelled.activeSessionID)
            let lease = try await app.projectContexts.repository.runLease(run.runID)
            XCTAssertNil(lease)
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }

    func testDesktopRetryWaitHonorsFutureDeadlineAndClaimsExpiredWork() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent("retry-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "Retry", canonicalRoot: projectRoot
        )
        let expiredRoot = home.appendingPathComponent("expired-retry-project", isDirectory: true)
        try FileManager.default.createDirectory(at: expiredRoot, withIntermediateDirectories: true)
        let expiredProject = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "Expired Retry", canonicalRoot: expiredRoot
        )
        let runtime = try ManagedAutonomyRuntime(app: app, registry: HostAdapterRegistry())
        _ = try await runtime.start()
        do {
            let futureRun = try await runtime.createRun(desktopRunRequest(
                project: project, root: projectRoot, selectionRevision: "retry-selection"
            ))
            _ = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(event: .sessionStart, sessionID: "future-owner", cwd: projectRoot.path),
                selectionRevision: "retry-selection"
            )
            _ = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(event: .sessionEnd, sessionID: "future-owner", cwd: projectRoot.path),
                selectionRevision: "retry-selection"
            )
            try await moveDesktopRunToRetryWait(
                repository: app.projectContexts.repository,
                runID: futureRun.runID,
                retryAt: Date().addingTimeInterval(120)
            )
            let beforeDeadline = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(event: .sessionStart, sessionID: "too-early", cwd: projectRoot.path),
                selectionRevision: "retry-selection"
            )
            XCTAssertEqual(beforeDeadline, .none)
            let stillWaiting = try await app.projectContexts.repository.autonomousRun(futureRun.runID)
            XCTAssertEqual(stillWaiting?.state, .retryWait)

            let expiredRun = try await runtime.createRun(desktopRunRequest(
                project: expiredProject, root: expiredRoot, selectionRevision: "retry-selection"
            ))
            _ = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(event: .sessionStart, sessionID: "expired-owner", cwd: expiredRoot.path),
                selectionRevision: "retry-selection"
            )
            _ = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(event: .sessionEnd, sessionID: "expired-owner", cwd: expiredRoot.path),
                selectionRevision: "retry-selection"
            )
            try await moveDesktopRunToRetryWait(
                repository: app.projectContexts.repository,
                runID: expiredRun.runID,
                retryAt: Date().addingTimeInterval(-1)
            )
            let afterDeadline = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(event: .sessionStart, sessionID: "after-deadline", cwd: expiredRoot.path),
                selectionRevision: "retry-selection"
            )
            guard case .context(let context) = afterDeadline else {
                return XCTFail("Expired retry work was not claimed")
            }
            XCTAssertTrue(context.contains(expiredRun.runID.description))
            let resumed = try await app.projectContexts.repository.autonomousRun(expiredRun.runID)
            XCTAssertEqual(resumed?.state, .running)
            let futureStillWaiting = try await app.projectContexts.repository.autonomousRun(futureRun.runID)
            XCTAssertEqual(futureStillWaiting?.state, .retryWait)
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }

    func testDesktopRunAdmissionSerializesOneNonterminalTaskPerProjectProvider() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent("single-slot-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "Single Slot", canonicalRoot: projectRoot
        )
        let runtime = try ManagedAutonomyRuntime(app: app, registry: HostAdapterRegistry())
        _ = try await runtime.start()
        defer { Task { await runtime.shutdown() } }
        let firstRequest = desktopRunRequest(
            project: project,
            root: projectRoot,
            selectionRevision: "single-slot-selection"
        )
        let secondRequest = AutonomousRunRequest(
            runID: RunID(),
            projectID: firstRequest.projectID,
            projectGeneration: firstRequest.projectGeneration,
            mission: firstRequest.mission,
            providerID: firstRequest.providerID,
            adapterID: firstRequest.adapterID,
            modelKey: firstRequest.modelKey,
            specification: firstRequest.specification,
            authorizationScope: firstRequest.authorizationScope
        )

        let firstTask = Task { try await runtime.createRun(firstRequest) }
        let secondTask = Task { try await runtime.createRun(secondRequest) }
        let results = [await firstTask.result, await secondTask.result]
        let successes = results.compactMap { try? $0.get() }
        let failures = results.compactMap { result -> Error? in
            guard case .failure(let error) = result else { return nil }
            return error
        }

        XCTAssertEqual(successes.count, 1)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].localizedDescription.contains("Only one nonterminal"))
        let winningRequest = successes[0].runID == firstRequest.runID ? firstRequest : secondRequest
        let replay = try await runtime.createRun(winningRequest)
        XCTAssertEqual(replay.runID, successes[0].runID)
    }

    func testDesktopHookRejectsAmbiguousPersistedSameProjectAssignments() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent("ambiguous-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "Ambiguous", canonicalRoot: projectRoot
        )
        let first = desktopRunRequest(
            project: project,
            root: projectRoot,
            selectionRevision: "ambiguous-selection"
        )
        let second = AutonomousRunRequest(
            runID: RunID(),
            projectID: first.projectID,
            projectGeneration: first.projectGeneration,
            mission: first.mission,
            providerID: first.providerID,
            adapterID: first.adapterID,
            modelKey: first.modelKey,
            specification: first.specification,
            authorizationScope: first.authorizationScope
        )
        _ = try await app.projectContexts.repository.createAutonomousRun(first)
        _ = try await app.projectContexts.repository.createAutonomousRun(second)
        let runtime = try ManagedAutonomyRuntime(app: app, registry: HostAdapterRegistry())
        _ = try await runtime.start()
        defer { Task { await runtime.shutdown() } }

        do {
            _ = try await runtime.handleDesktopProviderHook(
                lifecycleRequest(
                    event: .sessionStart,
                    sessionID: "ambiguous-session",
                    cwd: projectRoot.path
                ),
                selectionRevision: "ambiguous-selection"
            )
            XCTFail("Ambiguous persisted desktop assignments must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("multiple autonomous runs"))
        }
        let storedFirst = try await app.projectContexts.repository.autonomousRun(first.runID)
        let storedSecond = try await app.projectContexts.repository.autonomousRun(second.runID)
        XCTAssertEqual(storedFirst?.state, .created)
        XCTAssertEqual(storedSecond?.state, .created)
    }

    func testDesktopInlineAssignmentRejectsBeforeAnyUTF8MissionByteIsTruncated() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent("utf8-assignment-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "UTF-8 Assignment", canonicalRoot: projectRoot
        )
        var maximumPassingMission = ""
        for count in 1...3_000 {
            let candidate = String(repeating: "🧭", count: count)
            let candidateRequest = desktopRunRequest(
                project: project,
                root: projectRoot,
                selectionRevision: "utf8-selection",
                mission: candidate
            )
            do {
                try DesktopProviderRunLifecycleService.validateAssignmentContext(candidateRequest)
                maximumPassingMission = candidate
            } catch {
                break
            }
        }
        XCTAssertFalse(maximumPassingMission.isEmpty)
        let oversizedRequest = desktopRunRequest(
            project: project,
            root: projectRoot,
            selectionRevision: "utf8-selection",
            mission: maximumPassingMission + "🧭"
        )
        XCTAssertThrowsError(
            try DesktopProviderRunLifecycleService.validateAssignmentContext(oversizedRequest)
        )

        let request = desktopRunRequest(
            project: project,
            root: projectRoot,
            selectionRevision: "utf8-selection",
            mission: maximumPassingMission
        )
        let runtime = try ManagedAutonomyRuntime(app: app, registry: HostAdapterRegistry())
        _ = try await runtime.start()
        defer { Task { await runtime.shutdown() } }
        let run = try await runtime.createRun(request)
        let directive = try await runtime.handleDesktopProviderHook(
            lifecycleRequest(event: .sessionStart, sessionID: "utf8-session", cwd: projectRoot.path),
            selectionRevision: "utf8-selection"
        )
        guard case .context(let context) = directive else {
            return XCTFail("The exact in-bound UTF-8 mission was not delivered")
        }
        XCTAssertTrue(context.contains("Mission: \(maximumPassingMission)"))
        XCTAssertLessThanOrEqual(
            context.utf8.count,
            DesktopProviderHookContract.maximumAssignmentContextBytes
        )
        XCTAssertTrue(context.contains(run.runID.description))
    }

    func testDesktopArtifactAssignmentUsesCompleteDigestAndReadDirectiveNotLongManifestGoal() async throws {
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let projectRoot = home.appendingPathComponent("artifact-assignment-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await app.projectContexts.repository.registerProjectUnchecked(
            projectID: ProjectID(), displayName: "Artifact Assignment", canonicalRoot: projectRoot
        )
        let digest = String(repeating: "a", count: 64)
        let longManifestGoal = String(repeating: "long-manifest-goal-🧭", count: 2_000)
        let request = desktopRunRequest(
            project: project,
            root: projectRoot,
            selectionRevision: "artifact-selection",
            mission: longManifestGoal,
            allowedTools: ["instruction_catalog", "instruction_read"],
            additionalMetadata: [
                "source_kind": ManagerPreparedRunSourceKind.instructionArtifact.rawValue,
                "source_snapshot_sha256": digest,
            ]
        )
        try DesktopProviderRunLifecycleService.validateAssignmentContext(request)
        let runtime = try ManagedAutonomyRuntime(app: app, registry: HostAdapterRegistry())
        _ = try await runtime.start()
        defer { Task { await runtime.shutdown() } }
        _ = try await runtime.createRun(request)

        let directive = try await runtime.handleDesktopProviderHook(
            lifecycleRequest(
                event: .sessionStart,
                sessionID: "artifact-session",
                cwd: projectRoot.path
            ),
            selectionRevision: "artifact-selection"
        )
        guard case .context(let context) = directive else {
            return XCTFail("Artifact assignment was not delivered")
        }
        XCTAssertTrue(context.contains(digest))
        XCTAssertTrue(context.contains("instruction_catalog"))
        XCTAssertTrue(context.contains("instruction_read"))
        XCTAssertFalse(context.contains(longManifestGoal))
        XCTAssertLessThanOrEqual(
            context.utf8.count,
            DesktopProviderHookContract.maximumAssignmentContextBytes
        )
    }

    private func request(
        provider: ProviderIntegrationID,
        event: DesktopProviderHookEvent,
        tool: String? = nil
    ) throws -> DesktopProviderHookRequest {
        var payload: [String: Any] = [
            "hook_event_name": event.rawValue,
            "session_id": "session-1",
            "cwd": "/tmp/project",
        ]
        if let tool { payload["tool_name"] = tool }
        return try DesktopProviderHookRequest(
            providerID: provider,
            event: event,
            hostPayload: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        )
    }

    private func lifecycleRequest(
        event: DesktopProviderHookEvent,
        sessionID: String,
        cwd: String,
        tool: String? = nil,
        lastAssistantMessage: String? = nil
    ) throws -> DesktopProviderHookRequest {
        var payload: [String: Any] = [
            "hook_event_name": event.rawValue,
            "session_id": sessionID,
            "cwd": cwd,
        ]
        if let tool { payload["tool_name"] = tool }
        if let lastAssistantMessage { payload["last_assistant_message"] = lastAssistantMessage }
        return try DesktopProviderHookRequest(
            providerID: .codexDesktop,
            event: event,
            hostPayload: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        )
    }

    private func desktopRunRequest(
        project: ProjectControlRecord,
        root: URL,
        selectionRevision: String,
        mission: String = "Complete the desktop-provider lifecycle fixture",
        allowedTools: [String] = ["fs_read"],
        additionalMetadata: [String: String] = [:]
    ) -> AutonomousRunRequest {
        var metadata = additionalMetadata
        metadata["execution_strategy"] = ProviderExecutionStrategy.desktopPluginPull.rawValue
        metadata["provider_selection_revision"] = selectionRevision
        metadata["provider_deployment_id"] = "fixture-desktop-deployment"
        return AutonomousRunRequest(
            projectID: project.projectID,
            projectGeneration: project.generation,
            mission: mission,
            providerID: ProviderIntegrationID.codexDesktop.rawValue,
            adapterID: "forge.desktop-plugin.codex-desktop",
            modelKey: "host-selected",
            specification: AutonomousRunSpecification(
                allowedTools: allowedTools,
                completionGates: ["desktop_fixture"],
                work: AutonomousRunWork(metadata: metadata)
            ),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [root],
                allowedTools: Set(allowedTools),
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        )
    }

    private func waitForDesktopRun(
        repository: ProjectControlPlaneRepository,
        runID: RunID,
        state: AutonomousRunState,
        timeout: Duration = .seconds(5)
    ) async throws -> AutonomousRunRecord {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let run = try await repository.autonomousRun(runID), run.state == state {
                return run
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for desktop run state \(state.rawValue)")
        let final = try await repository.autonomousRun(runID)
        return try XCTUnwrap(final)
    }

    private func moveDesktopRunToRetryWait(
        repository: ProjectControlPlaneRepository,
        runID: RunID,
        retryAt: Date
    ) async throws {
        let runValue = try await repository.autonomousRun(runID)
        let run = try XCTUnwrap(runValue)
        XCTAssertEqual(run.state, .failedRecoverable)
        let lease = try await repository.acquireRunLease(
            runID: runID,
            ownerID: "desktop-retry-test:\(UUID().uuidString.lowercased())"
        )
        do {
            _ = try await repository.transitionAutonomousRun(
                runID: runID,
                lease: lease,
                transition: AutonomousRunTransition(
                    expectedState: run.state,
                    expectedRevision: run.revision,
                    nextState: .retryWait,
                    eventType: "desktop_retry_test_wait",
                    eventSummary: "Place desktop fixture in retry wait",
                    retryAt: ISO8601.string(from: retryAt)
                )
            )
            _ = try await repository.releaseRunLease(lease)
        } catch {
            _ = try? await repository.releaseRunLease(lease)
            throw error
        }
    }

    private func providerSnapshot(
        selected: ProviderIntegrationID?
    ) -> ProviderIntegrationsSnapshot {
        ProviderIntegrationsSnapshot(
            selectionRevision: "revision-1",
            selectedProviderID: selected,
            providers: [],
            currentOperation: nil,
            recentOperations: []
        )
    }
}

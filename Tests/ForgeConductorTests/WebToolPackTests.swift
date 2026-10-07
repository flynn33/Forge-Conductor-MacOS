import XCTest
@testable import ForgeConductorCore

final class WebToolPackTests: XCTestCase {
    func testCatalogRegistersExactWebSchemasAndReplayClasses() throws {
        try withApp { app in
            let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
            let replay = try ProductionToolReplayCatalog.classifier(productionToolNames: app.tools.toolNames)
            for name in WebToolPack.names {
                XCTAssertTrue(app.tools.toolNames.contains(name))
                let definition = try XCTUnwrap(catalog.definition(named: name))
                let schema = try definition.inputSchemaObject()
                XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
                let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
                XCTAssertNotNil(properties["deadline_ms"])
                XCTAssertEqual((properties["maximum_bytes"] as? [String: Any])?["maximum"] as? Int, 65_536)
                XCTAssertEqual(try replay.replayClass(for: name), .readOnly)
                XCTAssertTrue(definition.description.contains("untrusted data"))
                XCTAssertTrue(ProjectInstructionQueueStore.ordinaryDefaultAllowedTools.contains(name))
            }
        }
    }

    func testFetchUsesNativeGETAndReturnsReadableHTMLWithoutScripts() throws {
        try withApp { app in
            let url = fixtureURL()
            let session = session(body: Data("<html><h1>Native &amp; bounded</h1><script>secret()</script><p>Readable &#x1F600; content.</p></html>".utf8))
            defer { session.invalidateAndCancel() }
            let context = context(app: app)
            let result = try XCTUnwrap(WebToolPack(session: session).handle(name: "web.fetch", arguments: ["url": url],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertTrue(result.ok, "\(result.payload)")
            XCTAssertEqual(result.payload["http_status"] as? Int, 200)
            XCTAssertEqual(result.payload["content"] as? String, "Native & bounded\nReadable 😀 content.")
            XCTAssertEqual(result.payload["content_trust"] as? String, "untrusted_external_data")
            XCTAssertEqual(result.payload["javascript_executed"] as? Bool, false)
            XCTAssertEqual(result.payload["has_more"] as? Bool, false)
            XCTAssertEqual(WebResponseProtocol.latestRequest?.httpMethod, "GET")
            XCTAssertNil(WebResponseProtocol.latestRequest?.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testPagingReassemblesUTF8WithinEncodedBudgetAndDetectsChanges() throws {
        try withApp { app in
            let source = String(repeating: "Quoted \"line\" 😀\n", count: 160)
            let session = session(body: Data(source.utf8), contentType: "text/plain")
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session)
            let context = context(app: app, maximum: 2_500)
            let url = fixtureURL()
            var offset = 0
            var digest: String?
            var received = ""
            var requests = 0
            repeat {
                requests += 1
                var arguments: [String: Any] = ["url": url, "byte_offset": offset, "maximum_bytes": 3_000]
                if let digest { arguments["if_content_sha256"] = digest }
                let result = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: arguments, context: context,
                    clientID: context.clientID, app: app, cancellation: nil))
                XCTAssertTrue(result.ok, "\(result.payload)")
                XCTAssertLessThanOrEqual(try MCPToolResponse.data(id: String(repeating: "x", count: 128), result: result).count, 2_500)
                let piece = try XCTUnwrap(result.payload["content"] as? String)
                XCTAssertFalse(piece.isEmpty)
                received += piece
                digest = try XCTUnwrap(result.payload["content_sha256"] as? String)
                guard let next = result.payload["next_byte_offset"] as? Int else { break }
                XCTAssertGreaterThan(next, offset)
                XCTAssertEqual(next, offset + piece.utf8.count)
                offset = next
                XCTAssertLessThan(requests, 30)
            } while requests < 30
            XCTAssertGreaterThan(requests, 1)
            XCTAssertEqual(received, source)
            WebResponseProtocol.configure(body: Data("changed".utf8), contentType: "text/plain")
            let changed = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": url, "if_content_sha256": digest!],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertFalse(changed.ok)
            XCTAssertEqual(changed.payload["code"] as? String, "web_content_changed")
        }
    }

    func testAuthorizationAndArgumentFailuresDoNotStartRequests() throws {
        try withApp { app in
            let session = session(body: Data("not requested".utf8))
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session)
            let denied = context(app: app, network: false)
            let result = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": fixtureURL()], context: denied,
                clientID: denied.clientID, app: app, cancellation: nil))
            XCTAssertEqual(result.payload["code"] as? String, "network_not_authorized")
            let ungranted = context(app: app, tools: ["fs_read"])
            let grantFailure = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": fixtureURL()], context: ungranted,
                clientID: ungranted.clientID, app: app, cancellation: nil))
            XCTAssertEqual(grantFailure.payload["code"] as? String, "tool_not_granted")
            let authorized = context(app: app)
            for url in ["file:///etc/passwd", "https://user:password@example.com", "https://example.com:0", "https://example.com/a b"] {
                let invalid = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": url], context: authorized,
                    clientID: authorized.clientID, app: app, cancellation: nil))
                XCTAssertEqual(invalid.payload["code"] as? String, "web_invalid_argument", url)
            }
            for raw: Any in [true, -1, 31, 1.5, "20"] {
                let invalid = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": fixtureURL(), "timeout_sec": raw],
                    context: authorized, clientID: authorized.clientID, app: app, cancellation: nil))
                XCTAssertEqual(invalid.payload["code"] as? String, "web_invalid_argument")
            }
            for arguments: [String: Any] in [["byte_offset": -1], ["byte_offset": true], ["if_content_sha256": "bad"]] {
                let invalid = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: arguments.merging(["url": fixtureURL()]) { _, new in new },
                    context: authorized, clientID: authorized.clientID, app: app, cancellation: nil))
                XCTAssertEqual(invalid.payload["code"] as? String, "web_invalid_argument")
            }
            XCTAssertNil(WebResponseProtocol.latestRequest)
        }
    }

    func testHTTPFailureOversizeAndBinaryResponseAreExplicitErrors() throws {
        try withApp { app in
            let session = session(body: Data("unavailable".utf8), status: 503)
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session)
            let context = context(app: app)
            let failure = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": fixtureURL()], context: context,
                clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertFalse(failure.ok)
            XCTAssertEqual(failure.payload["code"] as? String, "web_http_error")
            XCTAssertEqual(failure.payload["http_status"] as? Int, 503)
            XCTAssertEqual(failure.payload["retryable"] as? Bool, true)
            WebResponseProtocol.configure(body: Data(repeating: 65, count: WebToolPack.maximumResponseBytes + 1), contentType: "text/plain")
            let oversized = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": fixtureURL()], context: context,
                clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertEqual(oversized.payload["code"] as? String, "web_response_too_large")
            WebResponseProtocol.configure(body: Data([0, 255]), contentType: "image/png")
            let binary = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": fixtureURL()], context: context,
                clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertEqual(binary.payload["code"] as? String, "web_unsupported_content")
        }
    }

    func testSearchDecodesProviderLinksDeduplicatesAndFailsChallenges() throws {
        let page = """
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fdocs&amp;rut=x">Native &amp; Swift</a>
        <a class="result__snippet" href="x">Read <b>bounded</b> results &#128512;.</a>
        <a class="result__a" href="https://example.com/docs">Duplicate</a>
        <a class="result__a" href="https://example.net/">Second</a><a class="result__snippet">More</a>
        """
        let results = try WebToolPack.searchResults(page, limit: 5)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0], ["title": "Native & Swift", "url": "https://example.com/docs", "snippet": "Read bounded results 😀."])
        XCTAssertThrowsError(try WebToolPack.searchResults("<form id=\"challenge-form\">", limit: 5))
        XCTAssertThrowsError(try WebToolPack.searchResults("<html>Unexpected response</html>", limit: 5))
        XCTAssertTrue(try WebToolPack.searchResults("<div class=\"no-results\">No results found</div>", limit: 5).isEmpty)
        try withApp { app in
            let session = session(body: Data(page.utf8))
            defer { session.invalidateAndCancel() }
            let context = context(app: app)
            let result = try XCTUnwrap(WebToolPack(session: session).handle(name: "web.search", arguments: ["query": "Swift & native", "limit": 1],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertTrue(result.ok, "\(result.payload)")
            XCTAssertEqual(result.payload["count"] as? Int, 1)
            XCTAssertEqual(result.payload["provider"] as? String, "duckduckgo_html")
            let request = try XCTUnwrap(WebResponseProtocol.latestRequest)
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "Swift & native")
        }
    }

    func testDeadlineCancelsAStalledNativeRequest() throws {
        try withApp { app in
            let session = session(body: Data(), stall: true)
            defer { session.invalidateAndCancel() }
            let context = context(app: app)
            let start = Date()
            XCTAssertThrowsError(try WebToolPack(session: session).handle(name: "web.fetch", arguments: ["url": fixtureURL()], context: context,
                clientID: context.clientID, app: app, cancellation: ToolCallCancellation(timeoutSeconds: 0.1))) { error in
                XCTAssertTrue(error is ToolCallDeadlineExceeded, "\(error)")
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
            XCTAssertTrue(WebResponseProtocol.wasStopped)
        }
    }

    func testLegacyMCPUpgradePreservesIdentityAndExplicitDeniedScopes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-web-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ProjectControlPlaneRepository(databaseURL: root.appendingPathComponent("control.sqlite3"))
        let project = try await repository.registerProjectUnchecked(projectID: ProjectID(), displayName: "Web Migration", canonicalRoot: root)
        let scope = ToolAuthorizationScope(canonicalRoots: [root], writableRoots: [], allowedTools: ["*"], networkAllowed: false, maximumInlineOutputBytes: 4_096)
        let client = ClientID("legacy-web-client")
        let owner = ProjectBindingOwner(kind: .mcpClient, id: client.rawValue)
        let binding = try await repository.bind(owner: owner, projectID: project.projectID, generation: project.generation, authorizationScope: scope)
        let upgraded = try await repository.ordinaryMCPInvocationContextWithWebAccess(clientID: client)
        XCTAssertTrue(upgraded.authorizationScope.networkAllowed)
        XCTAssertEqual(upgraded.authorizationScope.canonicalRoots, scope.canonicalRoots)
        XCTAssertEqual(upgraded.authorizationScope.writableRoots, [])
        XCTAssertEqual(upgraded.authorizationScope.allowedTools, scope.allowedTools)
        XCTAssertEqual(upgraded.authorizationScope.maximumInlineOutputBytes, 4_096)
        let persisted = try await repository.binding(for: owner)
        XCTAssertEqual(persisted?.bindingID, binding.bindingID)
        let replay = try await repository.ordinaryMCPInvocationContextWithWebAccess(clientID: client)
        XCTAssertEqual(replay, upgraded)
        let restrictedClient = ClientID("restricted-web-client")
        let restrictedScope = ToolAuthorizationScope(canonicalRoots: [root], allowedTools: ["web.fetch"], networkAllowed: false, maximumInlineOutputBytes: 4_096)
        _ = try await repository.bind(owner: .init(kind: .mcpClient, id: restrictedClient.rawValue), projectID: project.projectID,
            generation: project.generation, authorizationScope: restrictedScope)
        let denied = try await repository.ordinaryMCPInvocationContextWithWebAccess(clientID: restrictedClient)
        XCTAssertFalse(denied.authorizationScope.networkAllowed)
        let leasedClient = ClientID("leased-web-client")
        _ = try await repository.bind(owner: .init(kind: .mcpClient, id: leasedClient.rawValue), projectID: project.projectID,
            generation: project.generation, authorizationScope: scope, leaseOwner: "lease-fixture")
        let leased = try await repository.ordinaryMCPInvocationContextWithWebAccess(clientID: leasedClient)
        XCTAssertFalse(leased.authorizationScope.networkAllowed)
        await repository.close()
    }

    private func fixtureURL() -> String { "https://forge-web.fixture/\(UUID().uuidString)" }
    private func context(app: ForgeApp, network: Bool = true, tools: Set<String> = ["*"], maximum: Int = 65_536) -> ToolInvocationContext {
        ToolInvocationContext(projectID: ProjectID(), projectGeneration: .initial, clientID: ClientID("web-fixture"),
            authorizationScope: ToolAuthorizationScope(canonicalRoots: [app.paths.home], allowedTools: tools,
                networkAllowed: network, maximumInlineOutputBytes: maximum))
    }
    private func session(body: Data, contentType: String = "text/html; charset=utf-8", status: Int = 200, stall: Bool = false) -> URLSession {
        WebResponseProtocol.configure(body: body, contentType: contentType, status: status, stall: stall)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebResponseProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func withApp(_ operation: (ForgeApp) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-web-tests-\(UUID().uuidString)", isDirectory: true)
        let app = try ForgeApp.bootstrap(home: root)
        defer { app.shutdown(); try? FileManager.default.removeItem(at: root) }
        try operation(app)
    }
}

private final class WebResponseProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var contentType = "text/plain"
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var stall = false
    nonisolated(unsafe) private static var requestRecord: URLRequest?
    nonisolated(unsafe) private static var stopped = false
    static var latestRequest: URLRequest? { lock.withLock { requestRecord } }
    static var wasStopped: Bool { lock.withLock { stopped } }
    static func configure(body: Data, contentType: String, status: Int = 200, stall: Bool = false) {
        lock.withLock { self.body = body; self.contentType = contentType; self.status = status; self.stall = stall; requestRecord = nil; stopped = false }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.lock.withLock { Self.requestRecord = request; return (Self.body, Self.contentType, Self.status, Self.stall) }
        guard !fixture.3 else { return }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: fixture.2, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": fixture.1]) else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.0)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.withLock { Self.stopped = true } }
}

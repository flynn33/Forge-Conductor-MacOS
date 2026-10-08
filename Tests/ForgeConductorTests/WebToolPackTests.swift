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
                if name == "web.fetch" {
                    let format = try XCTUnwrap(properties["format"] as? [String: Any])
                    XCTAssertEqual(format["enum"] as? [String], ["text", "source", "base64"])
                    XCTAssertEqual(format["default"] as? String, "text")
                }
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
            XCTAssertEqual(result.payload["heading"] as? String, "Native & bounded")
            XCTAssertNil(result.payload["title"])
            XCTAssertEqual(result.payload["has_more"] as? Bool, false)
            XCTAssertEqual(WebResponseProtocol.latestRequest?.httpMethod, "GET")
            XCTAssertNil(WebResponseProtocol.latestRequest?.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testHTMLMetadataDecodesFirstRealHeadingAndPreservesSmallBudgetPaging() throws {
        try withApp { app in
            let heading = String(repeating: "😀", count: 200)
            let html = "<script>let fake='<h1>Script</h1>'</script><!-- <h1>Comment</h1> --><title> Native &amp; Swift &#x1F600; </title><h1>\(heading)</h1><h1>Second</h1><p>Retained body</p>"
            let session = session(body: Data(html.utf8))
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session)
            let context = context(app: app)
            let result = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": fixtureURL()],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertTrue(result.ok, "\(result.payload)")
            XCTAssertEqual(result.payload["title"] as? String, "Native & Swift 😀")
            XCTAssertEqual(result.payload["heading"] as? String, String(repeating: "😀", count: 128))
            XCTAssertEqual(result.payload["heading_truncated"] as? Bool, true)
            XCTAssertTrue((result.payload["content"] as? String)?.contains("Retained body") == true)

            let small = self.context(app: app, maximum: 1_750)
            let page = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": fixtureURL()],
                context: small, clientID: small.clientID, app: app, cancellation: nil))
            XCTAssertTrue(page.ok, "\(page.payload)")
            XCTAssertNil(page.payload["heading"], "Optional metadata must leave room for a readable body page")
            XCTAssertFalse((page.payload["content"] as? String ?? "").isEmpty)
            XCTAssertLessThanOrEqual(try MCPToolResponse.data(id: String(repeating: "x", count: 128), result: page).count, 1_750)
            XCTAssertEqual(page.payload["content_sha256"] as? String, result.payload["content_sha256"] as? String)
            XCTAssertTrue(page.payload["has_more"] as? Bool == true)
        }
    }

    func testHTMLMetadataIgnoresQuotedAttributesRawTextAndLookalikeTagNames() throws {
        try withApp { app in
            let fixtures: [(String, String?)] = [
                ("<div data-copy=\"<h1>Fake</h1>\"><h1>Real</h1></div>", "Real"),
                ("<title>literal <h1>Fake</h1></title><textarea><h1>Fake</h1></textarea><h1>Real</h1>", "Real"),
                ("<h1-custom>Fake</h1-custom><h1:fake>Fake</h1:fake><H1 class='a>b'>Real</H1>", "Real"),
                ("<div data-copy=\"<h1>Fake</h1>", nil),
                ("<script><h1>Fake</h1>", nil),
                ("<script>let value=\"<div attr='</script>'>\";<h1>Real</h1>", "Real"),
                ("<textarea><!-- literal </textarea><h1>Real</h1>", "Real"),
                ("<h1><span data-copy=\"<em>Fake</em>\">Real</span><br> &amp; bounded</h1>", "Real & bounded"),
                ("<div data-copy=\"\u{0301}<h1>Fake</h1>\"><h1>\u{0301}Real</h1></div>", "\u{0301}Real"),
                ("<div data-copy=<h1>Fake</h1>><h1>Real</h1>", "Real"),
                ("1 < 2<h1>Real < 3 &amp; bounded</h1>", "Real < 3 & bounded"),
            ]
            for (html, expected) in fixtures {
                let session = session(body: Data(html.utf8))
                defer { session.invalidateAndCancel() }
                let context = context(app: app)
                let result = try XCTUnwrap(WebToolPack(session: session).handle(name: "web.fetch", arguments: ["url": fixtureURL()],
                    context: context, clientID: context.clientID, app: app, cancellation: nil))
                XCTAssertTrue(result.ok, "\(result.payload)")
                XCTAssertEqual(result.payload["heading"] as? String, expected, html)
                if html.hasPrefix("<title>") {
                    XCTAssertEqual(result.payload["title"] as? String, "literal <h1>Fake</h1>")
                }
            }
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

    func testHTMLMetadataPreservesContinuedTextAndSourcePaging() throws {
        try withApp { app in
            let html = "<title>Page &amp; title</title><h1>First heading 😀</h1><p>" +
                String(repeating: "Quoted \"line\" 😀 &amp; body\n", count: 180) + "</p>"
            let session = session(body: Data(html.utf8))
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session)
            let context = context(app: app, maximum: 4_000)
            for format in ["text", "source"] {
                var offset = 0
                var digest: String?
                var received = ""
                var finished = false
                var requests = 0
                for _ in 0..<30 {
                    requests += 1
                    var arguments: [String: Any] = ["url": fixtureURL(), "format": format, "byte_offset": offset]
                    if let digest { arguments["if_content_sha256"] = digest }
                    let result = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: arguments,
                        context: context, clientID: context.clientID, app: app, cancellation: nil))
                    XCTAssertTrue(result.ok, "\(result.payload)")
                    XCTAssertLessThanOrEqual(try MCPToolResponse.data(id: String(repeating: "x", count: 128), result: result).count, 4_000)
                    XCTAssertEqual(result.payload["title"] as? String, "Page & title")
                    XCTAssertEqual(result.payload["heading"] as? String, "First heading 😀")
                    let piece = try XCTUnwrap(result.payload["content"] as? String)
                    XCTAssertFalse(piece.isEmpty)
                    received += piece
                    let pageDigest = try XCTUnwrap(result.payload["content_sha256"] as? String)
                    if let digest { XCTAssertEqual(pageDigest, digest) }
                    digest = pageDigest
                    guard let next = result.payload["next_byte_offset"] as? Int else {
                        XCTAssertEqual(result.payload["has_more"] as? Bool, false)
                        finished = true
                        break
                    }
                    XCTAssertEqual(result.payload["has_more"] as? Bool, true)
                    XCTAssertEqual(next, offset + piece.utf8.count)
                    XCTAssertGreaterThan(next, offset)
                    offset = next
                }
                XCTAssertTrue(finished, "\(format) paging must finish within the bounded request count")
                XCTAssertGreaterThan(requests, 1)
                XCTAssertEqual(received, format == "source" ? html : WebToolPack.plainText(html))
            }
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

    func testBase64WebPagingPreservesAllBytesAndRejectsChangedContent() throws {
        try withApp { app in
            let bytes = Data((0..<(256 * 149)).map { UInt8($0 % 256) })
            let session = session(body: bytes, contentType: "application/octet-stream")
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session)
            let context = context(app: app, maximum: 4_096)
            let url = fixtureURL()
            let digest = JSONSupport.sha256Hex(bytes)
            var offset = 0
            var reconstructed = Data()
            var finished = false
            var requests = 0
            for _ in 0..<70 {
                requests += 1
                let page = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": url, "format": "base64",
                    "byte_offset": offset, "if_content_sha256": digest, "maximum_bytes": 8_192], context: context,
                    clientID: context.clientID, app: app, cancellation: nil))
                XCTAssertTrue(page.ok, "\(page.payload)")
                XCTAssertLessThanOrEqual(try MCPToolResponse.data(id: String(repeating: "x", count: 128), result: page).count, 4_096)
                XCTAssertEqual(page.payload["format"] as? String, "base64")
                XCTAssertEqual(page.payload["content_encoding"] as? String, "base64")
                XCTAssertEqual(page.payload["content_sha256"] as? String, digest)
                XCTAssertEqual(page.payload["total_content_bytes"] as? Int, bytes.count)
                XCTAssertEqual(page.payload["javascript_executed"] as? Bool, false)
                let piece = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(page.payload["content"] as? String)))
                XCTAssertFalse(piece.isEmpty)
                XCTAssertEqual(page.payload["returned_content_bytes"] as? Int, piece.count)
                reconstructed.append(piece)
                guard let next = page.payload["next_byte_offset"] as? Int else {
                    XCTAssertEqual(page.payload["has_more"] as? Bool, false)
                    finished = true
                    break
                }
                XCTAssertEqual(next, offset + piece.count)
                XCTAssertGreaterThan(next, offset)
                offset = next
            }
            XCTAssertTrue(finished)
            XCTAssertGreaterThan(requests, 1)
            XCTAssertEqual(reconstructed, bytes)
            WebResponseProtocol.configure(body: Data([0, 255, 1]), contentType: "application/octet-stream")
            let changed = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": url, "format": "base64",
                "if_content_sha256": digest], context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertEqual(changed.payload["code"] as? String, "web_content_changed")
        }
    }

    func testBase64WebFormatKeepsRawTextBytesAndArbitraryByteOffsets() throws {
        try withApp { app in
            let bytes = Data("😀\n<title>Raw &amp; unchanged</title>".utf8)
            let session = session(body: bytes)
            defer { session.invalidateAndCancel() }
            let context = context(app: app)
            let page = try XCTUnwrap(WebToolPack(session: session).handle(name: "web.fetch",
                arguments: ["url": fixtureURL(), "format": "base64", "byte_offset": 1], context: context,
                clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertTrue(page.ok, "\(page.payload)")
            XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(page.payload["content"] as? String)), bytes.dropFirst())
            XCTAssertEqual(page.payload["content_sha256"] as? String, JSONSupport.sha256Hex(bytes))
            XCTAssertEqual(page.payload["returned_content_bytes"] as? Int, bytes.count - 1)
            XCTAssertNil(page.payload["title"])
            XCTAssertNil(page.payload["heading"])
        }
    }

    func testBase64WebEmptyResponseEndOffsetAndSmallBudgets() throws {
        try withApp { app in
            let session = session(body: Data(), contentType: "image/png")
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session)
            let context = context(app: app)
            let url = fixtureURL()
            let empty = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": url, "format": "base64"],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertTrue(empty.ok, "\(empty.payload)")
            XCTAssertEqual(empty.payload["content"] as? String, "")
            XCTAssertEqual(empty.payload["returned_content_bytes"] as? Int, 0)
            XCTAssertEqual(empty.payload["has_more"] as? Bool, false)
            WebResponseProtocol.configure(body: Data([0, 255]), contentType: "image/png")
            let end = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": url, "format": "base64", "byte_offset": 2],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertTrue(end.ok)
            XCTAssertEqual(end.payload["content"] as? String, "")
            let invalid = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": url, "format": "base64", "byte_offset": 3],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertEqual(invalid.payload["code"] as? String, "web_invalid_argument")
            let small = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": url, "format": "base64", "maximum_bytes": 128],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertEqual(small.payload["code"] as? String, "web_output_budget_too_small")
        }
    }

    func testBase64WebRetainsReceiveAndHTTPFailureBounds() throws {
        try withApp { app in
            let session = session(body: Data(repeating: 255, count: WebToolPack.maximumResponseBytes + 1), contentType: "image/png")
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session)
            let context = context(app: app)
            let oversized = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": fixtureURL(), "format": "base64"],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertEqual(oversized.payload["code"] as? String, "web_response_too_large")
            WebResponseProtocol.configure(body: Data([0, 255]), contentType: "image/png", status: 503)
            let failure = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": fixtureURL(), "format": "base64"],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertEqual(failure.payload["code"] as? String, "web_http_error")
            XCTAssertNil(failure.payload["content"])
        }
    }

    func testBase64WebBudgetNeverReturnsEmptyContinuation() throws {
        try withApp { app in
            let bytes = Data(repeating: 255, count: 257)
            let session = session(body: bytes, contentType: "application/octet-stream")
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session)
            let url = fixtureURL()
            for budget in [512, 1_100, 1_300, 1_500, 1_600, 1_700, 1_800, 1_900, 2_000, 2_200, 4_096] {
                let context = context(app: app, maximum: budget)
                let page = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": url, "format": "base64"],
                    context: context, clientID: context.clientID, app: app, cancellation: nil))
                if !page.ok {
                    XCTAssertEqual(page.payload["code"] as? String, "web_output_budget_too_small")
                    continue
                }
                XCTAssertLessThanOrEqual(try MCPToolResponse.data(id: String(repeating: "x", count: 128), result: page).count, budget)
                let piece = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(page.payload["content"] as? String)))
                XCTAssertFalse(piece.isEmpty)
                XCTAssertEqual(piece, bytes.prefix(piece.count))
                if page.payload["has_more"] as? Bool == true {
                    XCTAssertEqual(page.payload["next_byte_offset"] as? Int, piece.count)
                }
            }
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

    func testFinalWebFrameCountsActualEscapedIDNoticeAndTerminatingLF() throws {
        try withApp { app in
            let source = String(repeating: "x", count: 512)
            let session = session(body: Data(source.utf8), contentType: "text/plain; charset=utf-8")
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session), context = context(app: app)
            let url = fixtureURL(), id = String(repeating: "id\"\\\n😀", count: 40)
            let notice = "Required notice with \"quotes\", \\ and LF\n"
            var original = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": url, "format": "source"],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertTrue(original.ok)
            original.payload["extra_router_marker"] = "retain this field"
            let budget = try MCPToolResponse.data(id: id, result: original, additiveNotice: notice).count
            XCTAssertLessThanOrEqual(budget, WebToolPack.maximumInlineBytes)
            XCTAssertEqual(try MCPStdioTransport.encode(MCPToolResponse.object(id: id,
                result: original, additiveNotice: notice)).count, budget + 1)
            var produced = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": url, "format": "source",
                "maximum_bytes": budget], context: context, clientID: context.clientID, app: app, cancellation: nil))
            produced.payload["extra_router_marker"] = "retain this field"
            XCTAssertEqual(produced.payload["content"] as? String, source)
            let payload = try webWirePayload(WebToolPack.finalMCPResponse(name: "web.fetch", id: id,
                result: produced, additiveNotice: notice, budget: budget), id: id, notice: notice, budget: budget)
            let piece = try XCTUnwrap(payload["content"] as? String)
            XCTAssertFalse(piece.isEmpty)
            XCTAssertLessThan(piece.utf8.count, source.utf8.count)
            XCTAssertTrue(Data(source.utf8).starts(with: Data(piece.utf8)))
            XCTAssertEqual(payload["content_sha256"] as? String, JSONSupport.sha256Hex(Data(source.utf8)))
            XCTAssertEqual(payload["returned_content_bytes"] as? Int, piece.utf8.count)
            XCTAssertEqual(payload["next_byte_offset"] as? Int, piece.utf8.count)
            XCTAssertEqual(payload["has_more"] as? Bool, true)
            XCTAssertEqual(payload["truncated"] as? Bool, true)
            XCTAssertEqual(payload["extra_router_marker"] as? String, "retain this field")
        }
    }

    func testFinalWebUTF8PagesPreserveWholeDigestAndNonzeroScalarCursor() throws {
        try withApp { app in
            let prefix = "SKIP🌍"
            let source = prefix + String(repeating: "Quoted \"\\\n e\u{0301} 😀 日本語 ", count: 80)
            let bytes = Data(source.utf8), digest = JSONSupport.sha256Hex(Data(source.utf8))
            let session = session(body: bytes, contentType: "text/plain; charset=utf-8")
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session), context = context(app: app, maximum: 3_000)
            let url = fixtureURL(), notice = "Required UTF-8 page notice\n"
            XCTAssertEqual(WebToolPack.responseBudget(arguments: [:], scope: context.authorizationScope), 3_000)
            XCTAssertEqual(WebToolPack.responseBudget(arguments: ["maximum_bytes": 1_024],
                scope: context.authorizationScope), 1_024)
            for format in ["text", "source"] {
                var offset = prefix.utf8.count, reconstructed = Data(), finished = false, pages = 0
                for page in 0..<16 {
                    let arguments: [String: Any] = ["url": url, "format": format, "byte_offset": offset,
                        "if_content_sha256": digest, "maximum_bytes": 4_000]
                    let budget = WebToolPack.responseBudget(arguments: arguments, scope: context.authorizationScope)
                    XCTAssertEqual(budget, 3_000)
                    let produced = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: arguments,
                        context: context, clientID: context.clientID, app: app, cancellation: nil))
                    XCTAssertTrue(produced.ok, "\(produced.payload)")
                    let id = "utf8-\(format)-\(page)-" + String(repeating: "\"\\\n😀", count: 30)
                    let payload = try webWirePayload(WebToolPack.finalMCPResponse(name: "web.fetch", id: id,
                        result: produced, additiveNotice: notice, budget: budget), id: id, notice: notice, budget: budget)
                    let piece = try XCTUnwrap(payload["content"] as? String), count = piece.utf8.count
                    guard count > 0, count <= bytes.count - offset else { return XCTFail("Invalid UTF-8 page extent") }
                    XCTAssertEqual(Data(piece.utf8), bytes.subdata(in: offset..<(offset + count)))
                    XCTAssertEqual(payload["format"] as? String, format)
                    XCTAssertEqual(payload["javascript_executed"] as? Bool, false)
                    XCTAssertEqual(payload["content_trust"] as? String, "untrusted_external_data")
                    XCTAssertEqual(payload["byte_offset"] as? Int, offset)
                    XCTAssertEqual(payload["returned_content_bytes"] as? Int, count)
                    XCTAssertEqual(payload["total_content_bytes"] as? Int, bytes.count)
                    XCTAssertEqual(payload["content_sha256"] as? String, digest)
                    reconstructed.append(Data(piece.utf8)); pages += 1
                    let hasMore = offset + count < bytes.count
                    XCTAssertEqual(payload["has_more"] as? Bool, hasMore)
                    XCTAssertEqual(payload["truncated"] as? Bool, hasMore)
                    if !hasMore { XCTAssertTrue(payload["next_byte_offset"] is NSNull); finished = true; break }
                    let next = try XCTUnwrap(payload["next_byte_offset"] as? Int)
                    XCTAssertEqual(next, offset + count); XCTAssertGreaterThan(next, offset)
                    guard next == offset + count, next > offset else { return XCTFail("Invalid UTF-8 continuation") }
                    offset = next
                }
                XCTAssertTrue(finished); XCTAssertGreaterThan(pages, 1)
                XCTAssertEqual(reconstructed, Data(bytes.dropFirst(prefix.utf8.count)))
            }
        }
    }

    func testFinalWebBase64PagesKeepRawDigestAndArbitraryByteCursor() throws {
        try withApp { app in
            let bytes = Data((0..<2_050).map { UInt8($0 % 256) }), digest = JSONSupport.sha256Hex(bytes)
            let session = session(body: bytes, contentType: "application/octet-stream")
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session), context = context(app: app, maximum: 2_700)
            let url = fixtureURL(), notice = "Required binary page notice\n"
            var offset = 1, reconstructed = Data(), finished = false, pages = 0
            for page in 0..<24 {
                let arguments: [String: Any] = ["url": url, "format": "base64", "byte_offset": offset,
                    "if_content_sha256": digest, "maximum_bytes": 4_000]
                let budget = WebToolPack.responseBudget(arguments: arguments, scope: context.authorizationScope)
                XCTAssertEqual(budget, 2_700)
                let produced = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: arguments,
                    context: context, clientID: context.clientID, app: app, cancellation: nil))
                XCTAssertTrue(produced.ok, "\(produced.payload)")
                let id = "binary-\(page)-" + String(repeating: "\"\\\n😀", count: 30)
                let payload = try webWirePayload(WebToolPack.finalMCPResponse(name: "web.fetch", id: id,
                    result: produced, additiveNotice: notice, budget: budget), id: id, notice: notice, budget: budget)
                let encoded = try XCTUnwrap(payload["content"] as? String)
                let piece = try XCTUnwrap(Data(base64Encoded: encoded)), count = piece.count
                guard count > 0, count <= bytes.count - offset else { return XCTFail("Invalid raw-byte page extent") }
                XCTAssertEqual(encoded, piece.base64EncodedString())
                XCTAssertEqual(piece, bytes.subdata(in: offset..<(offset + count)))
                XCTAssertEqual(payload["content_encoding"] as? String, "base64")
                XCTAssertEqual(payload["format"] as? String, "base64")
                XCTAssertEqual(payload["javascript_executed"] as? Bool, false)
                XCTAssertEqual(payload["content_trust"] as? String, "untrusted_external_data")
                XCTAssertEqual(payload["byte_offset"] as? Int, offset)
                XCTAssertEqual(payload["returned_content_bytes"] as? Int, count)
                XCTAssertEqual(payload["total_content_bytes"] as? Int, bytes.count)
                XCTAssertEqual(payload["content_sha256"] as? String, digest)
                reconstructed.append(piece); pages += 1
                let hasMore = offset + count < bytes.count
                XCTAssertEqual(payload["has_more"] as? Bool, hasMore)
                XCTAssertEqual(payload["truncated"] as? Bool, hasMore)
                if !hasMore { XCTAssertTrue(payload["next_byte_offset"] is NSNull); finished = true; break }
                let next = try XCTUnwrap(payload["next_byte_offset"] as? Int)
                XCTAssertEqual(next, offset + count); XCTAssertGreaterThan(next, offset)
                guard next == offset + count, next > offset else { return XCTFail("Invalid raw-byte continuation") }
                offset = next
            }
            XCTAssertTrue(finished); XCTAssertGreaterThan(pages, 1)
            XCTAssertEqual(reconstructed, Data(bytes.dropFirst()))
        }
    }

    func testFinalWebBase64OneTwoByteTailsAndEmptyEndRemainExact() throws {
        try withApp { app in
            let bytes = Data([0, 255, 128, 7, 8]), session = session(body: Data([0, 255, 128, 7, 8]), contentType: "image/png")
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session), context = context(app: app)
            for offset in [bytes.count - 2, bytes.count - 1, bytes.count] {
                let produced = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": fixtureURL(),
                    "format": "base64", "byte_offset": offset], context: context, clientID: context.clientID, app: app, cancellation: nil))
                XCTAssertTrue(produced.ok)
                let id = "tail-\(offset)", notice = "Required tail notice"
                let payload = try webWirePayload(WebToolPack.finalMCPResponse(name: "web.fetch", id: id,
                    result: produced, additiveNotice: notice, budget: 4_096), id: id, notice: notice, budget: 4_096)
                XCTAssertTrue((payload as NSDictionary).isEqual(to: produced.payload))
                XCTAssertEqual(payload["content"] as? String, Data(bytes.dropFirst(offset)).base64EncodedString())
                XCTAssertEqual(payload["content_sha256"] as? String, JSONSupport.sha256Hex(bytes))
                XCTAssertEqual(payload["returned_content_bytes"] as? Int, bytes.count - offset)
                XCTAssertEqual(payload["has_more"] as? Bool, false); XCTAssertTrue(payload["next_byte_offset"] is NSNull)
            }
            WebResponseProtocol.configure(body: Data(), contentType: "image/png")
            let empty = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: ["url": fixtureURL(), "format": "base64"],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            let payload = try webWirePayload(WebToolPack.finalMCPResponse(name: "web.fetch", id: "empty",
                result: empty, additiveNotice: nil, budget: 4_096), id: "empty", notice: nil, budget: 4_096)
            XCTAssertEqual(payload["content"] as? String, ""); XCTAssertEqual(payload["returned_content_bytes"] as? Int, 0)
            XCTAssertEqual(payload["content_sha256"] as? String, JSONSupport.sha256Hex(Data()))
            XCTAssertEqual(payload["has_more"] as? Bool, false); XCTAssertTrue(payload["next_byte_offset"] is NSNull)
        }
    }

    func testFinalWebOptionalHTMLMetadataCannotDisplacePositiveBodyPage() throws {
        try withApp { app in
            let html = "<title>" + String(repeating: "Title 😀 ", count: 70) + "</title><h1>" +
                String(repeating: "Heading 🌍 ", count: 70) + "</h1><p>" + String(repeating: "body ", count: 200) + "</p>"
            let session = session(body: Data(html.utf8))
            defer { session.invalidateAndCancel() }
            let context = context(app: app)
            let original = try XCTUnwrap(WebToolPack(session: session).handle(name: "web.fetch", arguments: ["url": fixtureURL()],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertTrue(original.ok); XCTAssertNotNil(original.payload["title"]); XCTAssertNotNil(original.payload["heading"])
            let content = try XCTUnwrap(original.payload["content"] as? String)
            let first = try XCTUnwrap(content.unicodeScalars.first.map(String.init))
            var minimum = original.payload
            minimum["content"] = first; minimum["returned_content_bytes"] = first.utf8.count
            minimum["has_more"] = true; minimum["truncated"] = true; minimum["next_byte_offset"] = first.utf8.count
            let id = "metadata-\"\\\n😀", notice = "Required metadata notice"
            let withMetadata = try MCPStdioTransport.encode(MCPToolResponse.object(id: id,
                result: .success(minimum), additiveNotice: notice)).count
            for key in ["title", "heading", "title_truncated", "heading_truncated"] { minimum.removeValue(forKey: key) }
            let budget = try MCPStdioTransport.encode(MCPToolResponse.object(id: id,
                result: .success(minimum), additiveNotice: notice)).count + 32
            XCTAssertGreaterThan(withMetadata, budget)
            let payload = try webWirePayload(WebToolPack.finalMCPResponse(name: "web.fetch", id: id,
                result: original, additiveNotice: notice, budget: budget), id: id, notice: notice, budget: budget)
            for key in ["title", "heading", "title_truncated", "heading_truncated"] { XCTAssertNil(payload[key], key) }
            let piece = try XCTUnwrap(payload["content"] as? String)
            XCTAssertFalse(piece.isEmpty); XCTAssertTrue(Data(content.utf8).starts(with: Data(piece.utf8)))
            XCTAssertEqual(payload["content_sha256"] as? String, original.payload["content_sha256"] as? String)
            XCTAssertEqual(payload["returned_content_bytes"] as? Int, piece.utf8.count)
            XCTAssertEqual(payload["next_byte_offset"] as? Int, piece.utf8.count)
        }
    }

    func testFinalWebExistingErrorsKeepCodesAndHandoffFieldsEvenForImpossibleEnvelope() throws {
        try withApp { app in
            let session = session(body: Data("unavailable".utf8), status: 503)
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session), allowed = context(app: app), denied = context(app: app, network: false)
            let inputs: [(String, [String: Any], ToolInvocationContext)] = [
                ("network_not_authorized", ["url": fixtureURL()], denied),
                ("web_invalid_argument", ["url": "file:///private/unsupported"], allowed),
                ("web_invalid_argument", ["url": fixtureURL(), "maximum_bytes": 1.5], allowed),
                ("web_http_error", ["url": fixtureURL()], allowed),
            ]
            for (code, arguments, context) in inputs {
                var failure = try XCTUnwrap(pack.handle(name: "web.fetch", arguments: arguments,
                    context: context, clientID: context.clientID, app: app, cancellation: nil))
                XCTAssertFalse(failure.ok); XCTAssertEqual(failure.payload["code"] as? String, code)
                failure.payload["handoff_required"] = true; failure.payload["handoff_id"] = "retain-handoff"
                failure.payload["resume_seed"] = "Preserve the authored task."
                failure.payload["continuity_attention"] = ["state": "requires_attention"]
                let id = String(repeating: "impossible-\"\\\n😀", count: 20), notice = "Required notice retained"
                let response = WebToolPack.finalMCPResponse(name: "web.fetch", id: id, result: failure,
                    additiveNotice: notice, budget: 1)
                let payload = try webWirePayload(response, id: id, notice: notice, isError: true)
                XCTAssertTrue((payload as NSDictionary).isEqual(to: failure.payload))
                XCTAssertGreaterThan(try MCPStdioTransport.encode(response).count, 1,
                    "An impossible error envelope must not be advertised as fitting")
            }
        }
    }

    func testFinalWebBudgetRejectionKeepsContinuationGuidanceWithoutAdvancedCursor() throws {
        try withApp { app in
            let session = session(body: Data(String(repeating: "x", count: 4_096).utf8), contentType: "text/plain")
            defer { session.invalidateAndCancel() }
            let context = context(app: app, maximum: 4_096)
            var original = try XCTUnwrap(WebToolPack(session: session).handle(name: "web.fetch",
                arguments: ["url": fixtureURL(), "byte_offset": 1], context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertTrue(original.ok); XCTAssertGreaterThan(try XCTUnwrap(original.payload["next_byte_offset"] as? Int), 1)
            let controls: [String: Any] = ["auto_handoff_id": "retain-id", "handoff_id": "retain-id", "auto_continuity": "handoff",
                "extra_router_marker": "retain this field",
                "handoff_required": true, "resume_seed": "Preserve authored task.",
                "continuity_note": "Resume the saved handoff.", "continuity_attention": ["state": "requires_attention"]]
            original.payload.merge(controls) { _, new in new }
            let id = String(repeating: "\"\\\n😀", count: 100), notice = "Required notice"
            let payload = try webWirePayload(WebToolPack.finalMCPResponse(name: "web.fetch", id: id,
                result: original, additiveNotice: notice, budget: 128), id: id, notice: notice, isError: true)
            XCTAssertEqual(payload["code"] as? String, "web_output_budget_too_small")
            for (key, value) in controls {
                let actual = try XCTUnwrap(payload[key], key)
                XCTAssertTrue((["value": actual] as NSDictionary).isEqual(to: ["value": value]), key)
            }
            XCTAssertNil(payload["next_byte_offset"])
            XCTAssertNil(payload["content"])
            XCTAssertNil(payload["returned_content_bytes"])
            XCTAssertNil(payload["has_more"])
            XCTAssertNotEqual(payload["ok"] as? Bool, true)
        }
    }

    func testFinalWebSearchRetainsWholeOrderedEntriesAndExistingTruncation() throws {
        try withApp { app in
            let session = session(body: Data(webWireSearchHTML().utf8))
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session), context = context(app: app)
            let arguments: [String: Any] = ["query": "native wire results", "limit": 3]
            let original = try XCTUnwrap(pack.handle(name: "web.search", arguments: arguments,
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            let entries = try XCTUnwrap(original.payload["results"] as? [[String: String]])
            XCTAssertTrue(original.ok); XCTAssertEqual(entries.count, 3)
            var one = original.payload
            one["results"] = Array(entries.prefix(1)); one["count"] = 1; one["truncated"] = true
            let id = "search-\"\\\n😀", notice = "Required search notice"
            let budget = try MCPStdioTransport.encode(MCPToolResponse.object(id: id, result: .success(one), additiveNotice: notice)).count
            let payload = try webWirePayload(WebToolPack.finalMCPResponse(name: "web.search", id: id,
                result: original, additiveNotice: notice, budget: budget), id: id, notice: notice, budget: budget)
            XCTAssertEqual(payload["results"] as? [[String: String]], Array(entries.prefix(1)))
            XCTAssertEqual(payload["count"] as? Int, 1); XCTAssertEqual(payload["truncated"] as? Bool, true)
            let small = try MCPToolResponse.data(id: String(repeating: "x", count: 128), result: .success(one)).count + 64
            let limited = try XCTUnwrap(pack.handle(name: "web.search", arguments: arguments.merging(["maximum_bytes": small]) { _, new in new },
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertTrue(limited.ok); XCTAssertEqual(limited.payload["truncated"] as? Bool, true)
            XCTAssertEqual(limited.payload["results"] as? [[String: String]], Array(entries.prefix(1)))
            let retained = try webWirePayload(WebToolPack.finalMCPResponse(name: "web.search", id: id,
                result: limited, additiveNotice: notice, budget: 16_384), id: id, notice: notice, budget: 16_384)
            XCTAssertTrue((retained as NSDictionary).isEqual(to: limited.payload))
        }
    }

    func testFinalWebSearchRejectsBudgetInventedZeroButKeepsGenuineNoResults() throws {
        try withApp { app in
            let session = session(body: Data(webWireSearchHTML().utf8))
            defer { session.invalidateAndCancel() }
            let pack = WebToolPack(session: session), context = context(app: app)
            let original = try XCTUnwrap(pack.handle(name: "web.search", arguments: ["query": "native wire results", "limit": 3],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertTrue(original.ok); XCTAssertEqual(original.payload["count"] as? Int, 3)
            var zero = original.payload
            zero["results"] = [[String: String]](); zero["count"] = 0; zero["truncated"] = true
            let id = "search-zero", notice = "Required search notice"
            let budget = try MCPStdioTransport.encode(MCPToolResponse.object(id: id, result: .success(zero), additiveNotice: notice)).count
            let rejected = try webWirePayload(WebToolPack.finalMCPResponse(name: "web.search", id: id,
                result: original, additiveNotice: notice, budget: budget), id: id, notice: notice, isError: true)
            XCTAssertEqual(rejected["code"] as? String, "web_output_budget_too_small")
            XCTAssertNotEqual(rejected["ok"] as? Bool, true)
            WebResponseProtocol.configure(body: Data("<div class=\"no-results\">No results found</div>".utf8), contentType: "text/html")
            let genuine = try XCTUnwrap(pack.handle(name: "web.search", arguments: ["query": "no fixture results"],
                context: context, clientID: context.clientID, app: app, cancellation: nil))
            XCTAssertTrue(genuine.ok); XCTAssertEqual(genuine.payload["count"] as? Int, 0)
            let payload = try webWirePayload(WebToolPack.finalMCPResponse(name: "web.search", id: id,
                result: genuine, additiveNotice: notice, budget: 4_096), id: id, notice: notice, budget: 4_096)
            XCTAssertTrue((payload as NSDictionary).isEqual(to: genuine.payload))
            XCTAssertEqual(payload["truncated"] as? Bool, false)
        }
    }

    private func webWirePayload(_ response: [String: Any], id: String, notice: String?,
                                budget: Int? = nil, isError: Bool = false) throws -> [String: Any] {
        XCTAssertEqual(response["id"] as? String, id)
        let frame = try MCPStdioTransport.encode(response)
        XCTAssertTrue(frame.last == 0x0A); XCTAssertEqual(frame.filter { $0 == 0x0A }.count, 1)
        if let budget { XCTAssertLessThanOrEqual(frame.count, budget) }
        let envelope = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(envelope["isError"] as? Bool, isError)
        let payload = try XCTUnwrap(envelope["structuredContent"] as? [String: Any])
        XCTAssertEqual(payload["ok"] as? Bool, !isError)
        let blocks = try XCTUnwrap(envelope["content"] as? [[String: Any]])
        let text = try XCTUnwrap(blocks.first?["text"] as? String)
        XCTAssertTrue((try JSONSupport.object(from: Data(text.utf8)) as NSDictionary).isEqual(to: payload))
        XCTAssertEqual(blocks.count, notice == nil ? 1 : 2)
        if let notice { XCTAssertEqual(blocks.last?["text"] as? String, notice) }
        return payload
    }

    private func webWireSearchHTML() -> String {
        """
        <a class="result__a" href="https://first.example/docs">First &quot;😀&quot;</a><div class="result__snippet">\(String(repeating: "First bounded snippet. ", count: 20))</div>
        <a class="result__a" href="https://second.example/docs">Second 日本語</a><div class="result__snippet">\(String(repeating: "Second bounded snippet. ", count: 20))</div>
        <a class="result__a" href="https://third.example/docs">Third café</a><div class="result__snippet">\(String(repeating: "Third bounded snippet. ", count: 20))</div>
        """
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

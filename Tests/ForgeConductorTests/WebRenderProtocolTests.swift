import Foundation
import XCTest
@testable import ForgeConductorCore

final class WebRenderProtocolTests: XCTestCase {
    func testRequestPreservesUInt64AndHashRouterWithoutWireIdentity() throws {
        let request = makeRequest(generation: .max, deadline: .max, url: "https://example.com/app#/projects/one")
        let bytes = try WebRenderProtocol.encodeRequest(request)
        XCTAssertEqual(try WebRenderProtocol.decodeRequestFrame(bytes), request)
        let values = try requestObject(request)
        XCTAssertEqual(values["project_generation"] as? String, String(UInt64.max))
        XCTAssertEqual(values["deadline_uptime_ns"] as? String, String(UInt64.max))
        XCTAssertNil(values["role"])
        XCTAssertNil(values["cdhash"])
        XCTAssertEqual(try WebRenderProtocol.validatedURL(request.url).fragment, "/projects/one")
    }

    func testFrameRejectsIncompleteOversizedAndMultipleFrames() throws {
        let bytes = try WebRenderProtocol.encodeRequest(makeRequest())
        let maximum = WebRenderProtocol.maximumRequestBodyBytes
        for invalid in [Data(), Data([0, 0, 0]), Data([0, 0, 0, 0]),
                        Data(bytes.dropLast()), bytes + Data([0]), bytes + bytes,
                        Data([0, 0, 64, 1]) + Data(repeating: 32, count: maximum + 1)] {
            XCTAssertThrowsError(try WebRenderProtocol.decodeRequestFrame(invalid))
        }
        XCTAssertThrowsError(try WebRenderProtocol.frame(Data(), maximumBodyBytes: maximum))
        XCTAssertThrowsError(try WebRenderProtocol.frame(Data(repeating: 32, count: maximum + 1), maximumBodyBytes: maximum))
    }

    func testCanonicalJSONRejectsDuplicateKeysAlternateWhitespaceAndInvalidUTF8() throws {
        let body = try WebRenderProtocol.body(WebRenderProtocol.encodeRequest(makeRequest()),
                                             maximumBodyBytes: WebRenderProtocol.maximumRequestBodyBytes)
        var duplicate = Data("{\"version\":\"forge.web.render.v1\",".utf8)
        duplicate.append(body.dropFirst())
        for invalid in [duplicate, Data(" ".utf8) + body, Data([0xff, 0xfe])] {
            XCTAssertThrowsError(try WebRenderProtocol.decodeRequestBody(invalid))
        }
    }

    func testRequestRejectsUnknownFieldsNoncanonicalIdentifiersAndWrongTypes() throws {
        let request = makeRequest()
        let edits: [(String, Any)] = [
            ("script", "document.cookie"), ("project_generation", 1), ("project_generation", true),
            ("project_generation", "01"), ("project_generation", "0"),
            ("project_generation", "18446744073709551616"), ("deadline_uptime_ns", "-1"),
            ("deadline_uptime_ns", "0"), ("deadline_uptime_ns", "1e9"),
            ("nonce", request.nonce.uuidString.uppercased()), ("version", "forge.web.render.v2"),
        ]
        for (key, value) in edits {
            var values = try requestObject(request)
            values[key] = value
            XCTAssertThrowsError(try WebRenderProtocol.decodeRequestBody(canonical(values)), key)
        }
        var missing = try requestObject(request)
        missing.removeValue(forKey: "nonce")
        XCTAssertThrowsError(try WebRenderProtocol.decodeRequestBody(canonical(missing)))
    }

    func testReplyMatchesExactOperationProjectAndGeneration() throws {
        let request = makeRequest()
        let reply = makeReply(request)
        let bytes = try WebRenderProtocol.encodeReply(reply, matching: request)
        XCTAssertEqual(try WebRenderProtocol.decodeReplyFrame(bytes, matching: request), reply)
        for (key, value) in [("nonce", UUID().uuidString.lowercased()),
                             ("request_id", UUID().uuidString.lowercased()),
                             ("project_id", UUID().uuidString.lowercased()),
                             ("project_generation", "2")] {
            var values = try replyObject(reply, request: request)
            values[key] = value
            XCTAssertThrowsError(try WebRenderProtocol.decodeReplyBody(canonical(values), matching: request)) { error in
                XCTAssertEqual(error as? WebRenderProtocolError, .mismatchedReply)
            }
        }
        XCTAssertThrowsError(try WebRenderProtocol.decodeReplyFrame(bytes + bytes, matching: request))
    }

    func testReplyRejectsInconsistentOutcomeAndNumericBooleanFields() throws {
        let request = makeRequest()
        let reply = makeReply(request)
        let edits: [(String, Any)] = [
            ("snapshot_extracted", false), ("lockdown_enabled", false), ("readiness", "unavailable"),
            ("final_url", ""), ("text_bytes", true), ("nodes_visited", true),
            ("nodes_visited", 4_097), ("text_bytes", 1), ("lockdown_enabled", 1),
            ("text_truncated", 0), ("outcome", "unknown"), ("store_lifetime", "never_retained"),
            ("extra", "ignored"),
        ]
        for (key, value) in edits {
            var values = try replyObject(reply, request: request)
            values[key] = value
            XCTAssertThrowsError(try WebRenderProtocol.decodeReplyBody(canonical(values), matching: request), key)
        }
        var float = try replyObject(reply, request: request)
        float["nodes_visited"] = 1
        let body = try canonical(float)
        let spelling = try XCTUnwrap(String(data: body, encoding: .utf8))
            .replacingOccurrences(of: "\"nodes_visited\":1", with: "\"nodes_visited\":1.0")
        XCTAssertThrowsError(try WebRenderProtocol.decodeReplyBody(Data(spelling.utf8), matching: request))
    }

    func testFailureBeforeGraphCreationDoesNotFabricateReleaseOrExecution() throws {
        let request = makeRequest()
        let failure = makeReply(request, outcome: .unsupported, text: "", title: "", snapshot: false,
                                lockdown: false, readiness: .unavailable, view: .notCreated, store: .notCreated)
        XCTAssertEqual(try WebRenderProtocol.decodeReplyFrame(WebRenderProtocol.encodeReply(failure, matching: request),
                                                              matching: request), failure)
        var values = try replyObject(failure, request: request)
        values["snapshot_extracted"] = true
        XCTAssertThrowsError(try WebRenderProtocol.decodeReplyBody(canonical(values), matching: request))
        values["snapshot_extracted"] = false
        values["text"] = "not an observed DOM"
        values["text_bytes"] = 19
        XCTAssertThrowsError(try WebRenderProtocol.decodeReplyBody(canonical(values), matching: request))
        let pendingStore = makeReply(request, view: .released, store: .unreleasedAtDeadline)
        XCTAssertEqual(try WebRenderProtocol.decodeReplyFrame(WebRenderProtocol.encodeReply(pendingStore, matching: request),
                                                              matching: request).storeLifetime, .unreleasedAtDeadline)
    }

    func testReplyCapsApplyToEncodedFrameAndUnicodeBytes() throws {
        let request = makeRequest()
        for reply in [makeReply(request, text: String(repeating: "😀", count: 2_049)),
                      makeReply(request, title: String(repeating: "😀", count: 129)),
                      makeReply(request, text: String(repeating: "\u{0001}", count: 8_192))] {
            XCTAssertThrowsError(try WebRenderProtocol.encodeReply(reply, matching: request))
        }
        let bounded = makeReply(request, text: String(repeating: "😀", count: 2_048),
                                title: String(repeating: "😀", count: 128))
        XCTAssertEqual(try WebRenderProtocol.decodeReplyFrame(WebRenderProtocol.encodeReply(bounded, matching: request),
                                                              matching: request), bounded)
        let value = "A😀e\u{0301}終"
        for byteCount in 0...(value.utf8.count + 1) {
            let prefix = WebRenderProtocol.prefixUTF8(value, bytes: byteCount)
            XCTAssertLessThanOrEqual(prefix.utf8.count, byteCount)
            XCTAssertTrue(Data(value.utf8).starts(with: Data(prefix.utf8)))
            XCTAssertEqual(String(data: Data(prefix.utf8), encoding: .utf8), prefix)
        }
    }

    func testURLPolicyAllowsPublicHTTPAndHashRoutingButRejectsCredentialsAndFiles() throws {
        for valid in ["https://example.com/path?q=1#ready", "http://127.0.0.1:8080/fixture", "https://example.com/%20"] {
            XCTAssertNoThrow(try WebRenderProtocol.validatedURL(valid), valid)
        }
        for invalid in ["file:///tmp/page.html", "data:text/html,a", "javascript:alert(1)", "ftp://example.com",
                        "https://name:secret@example.com/", "https://name@example.com/", "https://example.com:0/",
                        "https://example.com:65536/", "https:///", "https://example.com/a b", "https://example.com/\n"] {
            XCTAssertThrowsError(try WebRenderProtocol.validatedURL(invalid), invalid)
        }
    }

    func testAttachmentDispositionChecksOnlyDispositionToken() {
        XCTAssertTrue(WebRenderProtocol.isAttachmentDisposition(" attachment ; filename=report.html"))
        XCTAssertTrue(WebRenderProtocol.isAttachmentDisposition("ATTACHMENT"))
        for header in [nil, "", "inline; filename=attachment.html", "form-data; name=attachment", "attachmentish"] {
            XCTAssertFalse(WebRenderProtocol.isAttachmentDisposition(header))
        }
    }

    func testToolArgumentsRejectCallerScriptActionsAndBooleanBounds() throws {
        let parsed = try WebRenderToolPack.Arguments(["url": "https://example.com/#app"])
        XCTAssertEqual(parsed.timeoutSeconds, 20)
        XCTAssertEqual(parsed.maximumBytes, 16_384)
        XCTAssertEqual(parsed.url.fragment, "app")
        for extra in ["script", "cookies", "headers", "click", "profile", "file", "executable"] {
            XCTAssertThrowsError(try WebRenderToolPack.Arguments(["url": "https://example.com/", extra: "caller controlled"]))
        }
        for key in ["timeout_sec", "maximum_bytes", "deadline_ms"] {
            XCTAssertThrowsError(try WebRenderToolPack.Arguments(["url": "https://example.com/", key: true]))
            XCTAssertThrowsError(try WebRenderToolPack.Arguments(["url": "https://example.com/", key: 0]))
        }
        XCTAssertThrowsError(try WebRenderToolPack.Arguments(["url": "https://example.com/", "timeout_sec": 31]))
        XCTAssertThrowsError(try WebRenderToolPack.Arguments(["url": "https://example.com/", "maximum_bytes": 65_537]))
        XCTAssertThrowsError(try WebRenderToolPack.Arguments(["url": "https://example.com/", "timeout_sec": 1.5]))
        XCTAssertEqual(try WebRenderToolPack.Arguments(["url": "https://example.com/", "deadline_ms": 10]).deadlineMilliseconds, 10)
    }

    private func makeRequest(generation: UInt64 = 1, deadline: UInt64 = 123_456_789,
                             url: String = "https://example.com/") -> WebRenderProtocol.Request {
        WebRenderProtocol.Request(requestID: UUID(uuidString: "a1111111-1111-1111-1111-111111111111")!,
            nonce: UUID(uuidString: "b2222222-2222-2222-2222-222222222222")!,
            projectID: UUID(uuidString: "c3333333-3333-3333-3333-333333333333")!,
            projectGeneration: generation, url: url, deadlineUptimeNanoseconds: deadline)
    }

    private func makeReply(_ request: WebRenderProtocol.Request, outcome: WebRenderProtocol.Outcome = .rendered,
                           text: String = "DOM marker 😀", title: String = "Native title", snapshot: Bool = true,
                           lockdown: Bool = true, readiness: WebRenderProtocol.Readiness = .boundedStability,
                           view: WebRenderProtocol.Lifetime = .released,
                           store: WebRenderProtocol.Lifetime = .released) -> WebRenderProtocol.Reply {
        WebRenderProtocol.Reply(requestID: request.requestID, nonce: request.nonce, projectID: request.projectID,
            projectGeneration: request.projectGeneration, outcome: outcome, finalURL: request.url,
            title: title, text: text, nodesVisited: 2, textTruncated: false, titleTruncated: false,
            readiness: readiness, snapshotExtracted: snapshot, lockdownEnabled: lockdown,
            viewLifetime: view, storeLifetime: store)
    }
    private func canonical(_ values: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    }
    private func requestObject(_ request: WebRenderProtocol.Request) throws -> [String: Any] {
        let body = try WebRenderProtocol.body(WebRenderProtocol.encodeRequest(request),
                                             maximumBodyBytes: WebRenderProtocol.maximumRequestBodyBytes)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
    private func replyObject(_ reply: WebRenderProtocol.Reply, request: WebRenderProtocol.Request) throws -> [String: Any] {
        let body = try WebRenderProtocol.body(WebRenderProtocol.encodeReply(reply, matching: request),
                                             maximumBodyBytes: WebRenderProtocol.maximumReplyBodyBytes)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

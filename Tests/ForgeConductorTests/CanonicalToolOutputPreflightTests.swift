import Foundation
import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

private actor CanonicalOutputAuthorization: LMStudioAuthorizationProviding {
    private var resolutions = 0
    func bearerToken() async throws -> String? { resolutions += 1; return nil }
    var count: Int { resolutions }
}

private final class CanonicalOutputCapture: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let body: Data
    }
    private let lock = NSLock()
    private var requests: [Request] = []
    func record(_ request: Request) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard requests.count < 32, request.body.count <= 524_288 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        requests.append(request)
        return requests.count
    }
    var snapshot: [Request] { lock.lock(); defer { lock.unlock() }; return requests }
}

private final class CanonicalOutputProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var captures: [String: CanonicalOutputCapture] = [:]
    }
    private static let registry = Registry()
    static func register(_ capture: CanonicalOutputCapture, host: String) throws {
        registry.lock.lock(); defer { registry.lock.unlock() }
        guard registry.captures.count < 16, registry.captures[host] == nil else {
            throw URLError(.resourceUnavailable)
        }
        registry.captures[host] = capture
    }
    static func remove(host: String) {
        registry.lock.lock(); defer { registry.lock.unlock() }
        registry.captures.removeValue(forKey: host)
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".canonical-output.invalid") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            guard let url = request.url, let host = url.host else { throw URLError(.badURL) }
            Self.registry.lock.lock()
            let capture = Self.registry.captures[host]
            Self.registry.lock.unlock()
            guard let capture else { throw URLError(.resourceUnavailable) }
            let body = try Self.body(request)
            let ordinal = try capture.record(.init(method: request.httpMethod ?? "", path: url.path, body: body))
            let bytes: Data
            let contentType: String
            if request.httpMethod == "GET", url.path == "/api/v1/models" {
                let model: [String: Any] = [
                    "type": "llm", "publisher": "fixture", "key": "fixture/tool-model",
                    "display_name": "Fixture Tool Model", "architecture": "fixture", "format": "gguf",
                    "quantization": ["name": "Q4_K_M", "bits_per_weight": 4],
                    "size_bytes": 1_073_741_824, "params_string": "1B", "max_context_length": 131_072,
                    "loaded_instances": [["id": "fixture/tool-model@131072",
                        "config": ["context_length": 131_072, "eval_batch_size": 512, "parallel": 1,
                            "flash_attention": true, "offload_kv_cache_to_gpu": true]]],
                    "capabilities": ["vision": false, "trained_for_tool_use": true,
                        "reasoning": ["allowed_options": ["off", "low"], "default": "off"]],
                ]
                bytes = try JSONSerialization.data(withJSONObject: ["models": [model]], options: [.sortedKeys])
                contentType = "application/json"
            } else if request.httpMethod == "POST", url.path == "/v1/responses" {
                let value = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let definitions = value["tools"] as? [[String: Any]] ?? []
                let probe = definitions.contains { $0["name"] as? String == LMStudioRESTClient.capabilityProbeToolName }
                let previous = value["previous_response_id"] as? String
                let output: [[String: Any]] = probe ? [[
                    "id": "item_canonical_probe", "type": "function_call", "status": "completed",
                    "call_id": "call_canonical_probe", "name": LMStudioRESTClient.capabilityProbeToolName,
                    "arguments": #"{"accepted":true,"contract_version":1}"#,
                ]] : []
                let response: [String: Any] = [
                    "id": "resp_canonical_\(ordinal)", "model": value["model"] ?? "fixture/tool-model",
                    "status": "completed", "previous_response_id": previous as Any? ?? NSNull(),
                    "output": output, "usage": ["input_tokens": 24, "output_tokens": 8, "total_tokens": 32],
                ]
                let event: [String: Any] = ["type": "response.completed", "sequence_number": 0, "response": response]
                let json = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
                bytes = Data("event: response.completed\ndata: ".utf8) + json + Data("\n\ndata: [DONE]\n\n".utf8)
                contentType = "text/event-stream"
            } else { throw URLError(.unsupportedURL) }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType, "X-LM-Studio-Version": "0.3.fixture"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        // URLSession's retained request stream is memory-backed; bound both bytes and reads.
        for _ in 0..<129 {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return bytes }
            guard bytes.count + count <= 524_288 else { throw URLError(.dataLengthExceedsMaximum) }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        throw URLError(.dataLengthExceedsMaximum)
    }
}

final class CanonicalToolOutputPreflightTests: XCTestCase {
    // The canonical output rule reserves this entire existing broker ceiling.
    // Literal wire measurements independently verify the twofold production bound.
    private let fullResultCeiling = 65_536

    private enum Mode {
        case native, ordinary
        func encode(_ object: [String: Any]) throws -> Data {
            switch self {
            case .native: return try ForgeJSONCanonicalizationV1.data(from: object)
            case .ordinary: return Data(try JSONSupport.canonicalJSON(object).utf8)
            }
        }
    }
    private struct SerializedResult {
        let label: String
        let full: Data
        let payload: Data
        var output: String { String(decoding: payload, as: UTF8.self) }
    }
    private struct CapturedOutput: Encodable {
        let type = "function_call_output"
        let callID: String
        let output: String
        enum CodingKeys: String, CodingKey { case type, callID = "call_id", output }
    }
    private struct Fixture {
        let configuration: LMStudioProviderConfiguration
        let session: URLSessionConfiguration
        let capture: CanonicalOutputCapture
        let authorization: CanonicalOutputAuthorization
        let provider: LMStudioManagedModelProvider
        func close() { CanonicalOutputProtocol.remove(host: configuration.baseURL.host!) }
        func provider(configuration: LMStudioProviderConfiguration) throws -> LMStudioManagedModelProvider {
            LMStudioManagedModelProvider(transport: try LMStudioManagedSessionTransport(
                configuration: configuration, sessionConfiguration: session, authorization: authorization))
        }
    }

    private func fixture() throws -> Fixture {
        let host = UUID().uuidString.lowercased() + ".canonical-output.invalid"
        let capture = CanonicalOutputCapture()
        try CanonicalOutputProtocol.register(capture, host: host)
        do {
            let session = URLSessionConfiguration.ephemeral
            session.protocolClasses = [CanonicalOutputProtocol.self]
            var configuration = LMStudioProviderConfiguration(baseURL: URL(string: "https://" + host)!,
                modelKey: "fixture/tool-model", connectTimeoutSeconds: 2, firstByteTimeoutSeconds: 4,
                idleTimeoutSeconds: 6, totalTimeoutSeconds: 12, maximumJSONBytes: 8_192,
                maximumRequestBytes: 524_288, maximumSSELineBytes: 8_192,
                maximumSSEEventBytes: 16_384, maximumResponseBytes: 524_288,
                maximumTextBytes: 524_288, maximumToolArgumentBytes: 16_384, maximumOutputTokens: 321)
            configuration.revision = UUID().uuidString.lowercased()
            let authorization = CanonicalOutputAuthorization()
            return Fixture(configuration: configuration, session: session, capture: capture,
                authorization: authorization, provider: LMStudioManagedModelProvider(
                    transport: try LMStudioManagedSessionTransport(configuration: configuration,
                        sessionConfiguration: session, authorization: authorization)))
        } catch {
            CanonicalOutputProtocol.remove(host: host)
            throw error
        }
    }

    private func request(output: String, callID: String = "call_exact/雪",
                         operationID: UUID = UUID()) throws -> ProviderContinuationRequest {
        let tool = try CanonicalToolDefinition(name: "fixture_read", description: "Read /fixture exactly.",
            inputSchema: ["type": "object", "additionalProperties": false,
                "properties": ["path": ["type": "string"]], "required": ["path"]]).providerDefinitionJSON()
        return try ProviderContinuationRequest(operationID: operationID,
            idempotencyKey: operationID.uuidString.lowercased(), modelKey: "fixture/tool-model",
            previousResponseID: "resp_original/雪",
            input: ForgeJSONCanonicalizationV1.data(from: [
                ["type": "function_call_output", "call_id": callID, "output": output],
            ]), tools: [tool])
    }

    private func result(_ payload: [String: Any], mode: Mode, label: String) throws -> SerializedResult {
        let full = try mode.encode(["ok": true, "is_error": false, "payload": payload])
        let bytes = try mode.encode(payload)
        XCTAssertLessThanOrEqual(bytes.count, full.count, label)
        XCTAssertNotNil(full.range(of: bytes), "The output encoding must be the actual nested full-result encoding: \(label)")
        XCTAssertFalse(bytes.contains { $0 < 0x20 }, "Canonical payload text cannot contain raw controls: \(label)")
        return .init(label: label, full: full, payload: bytes)
    }

    private func nearCeiling(mode: Mode, label: String, pattern: String,
                             adversarialKey: String = "content") throws -> SerializedResult {
        var low = 0, high = fullResultCeiling + 1
        while high - low > 1 {
            let middle = low + (high - low) / 2
            let full = try mode.encode(["ok": true, "is_error": false,
                "payload": [adversarialKey: String(repeating: pattern, count: middle)]])
            if full.count <= fullResultCeiling { low = middle } else { high = middle }
        }
        let measured = try result([adversarialKey: String(repeating: pattern, count: low)], mode: mode, label: label)
        let next = try mode.encode(["ok": true, "is_error": false,
            "payload": [adversarialKey: String(repeating: pattern, count: high)]])
        XCTAssertLessThanOrEqual(measured.full.count, fullResultCeiling)
        XCTAssertGreaterThan(measured.full.count, fullResultCeiling - 512)
        XCTAssertGreaterThan(next.count, fullResultCeiling, "Fixture must reach the full approved ceiling")
        return measured
    }

    private func assertCaptured(_ request: ProviderContinuationRequest, preflight: ProviderRequestPreflight,
                                capture: CanonicalOutputCapture, expectedOutput: String) throws {
        let actual = try XCTUnwrap(capture.snapshot.last)
        XCTAssertEqual(actual.method, "POST")
        XCTAssertEqual(actual.path, "/v1/responses")
        XCTAssertEqual(actual.body.count, preflight.bodyByteCount)
        XCTAssertEqual(JSONSupport.sha256Hex(actual.body), preflight.bodySHA256)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: actual.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, request.modelKey)
        XCTAssertEqual(body["previous_response_id"] as? String, request.previousResponseID)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 321)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(Set(input[0].keys), ["type", "call_id", "output"])
        XCTAssertEqual(input[0]["type"] as? String, "function_call_output")
        let originalInput = try XCTUnwrap(JSONSerialization.jsonObject(with: request.input) as? [[String: Any]])
        XCTAssertEqual(input[0]["call_id"] as? String, originalInput[0]["call_id"] as? String)
        let callID = try XCTUnwrap(input[0]["call_id"] as? String)
        let output = try XCTUnwrap(input[0]["output"] as? String)
        XCTAssertEqual(Data(output.utf8), Data(expectedOutput.utf8), "No clipping, Unicode repair, or extra JSON layer")
        XCTAssertEqual(JSONSupport.sha256Hex(output), JSONSupport.sha256Hex(expectedOutput))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encodedInput = try encoder.encode([CapturedOutput(callID: callID, output: output)])
        XCTAssertEqual(preflight.serializedInputByteCount, encodedInput.count)
    }

    private func exerciseCanonicalMode(_ mode: Mode) async throws {
        XCTAssertEqual(ToolInvocationBroker.maximumDurableResultBytes, fullResultCeiling)
        let f = try fixture(); defer { f.close() }
        let controls = String(String.UnicodeScalarView((0...31).compactMap { Unicode.Scalar($0) }))
        let key = "key\"/\\\0\u{2028}\u{2029}😀"
        let cases = try [
            nearCeiling(mode: mode, label: "slash", pattern: "/"),
            nearCeiling(mode: mode, label: "quote", pattern: "\""),
            nearCeiling(mode: mode, label: "backslash", pattern: "\\"),
            nearCeiling(mode: mode, label: "all_controls", pattern: controls),
            nearCeiling(mode: mode, label: "existing_escape_text", pattern: "\\u0000\\u2028\\ud83d\\ude00"),
            nearCeiling(mode: mode, label: "unicode_and_adversarial_key",
                pattern: "\"/\\\n\0\u{0080}\u{00ff}雪\u{2028}\u{2029}😀e\u{0301}\u{fffd}\u{10ffff}", adversarialKey: key),
            result([key: [true, false, NSNull(), -42, 1.125, "\\u0000"],
                "nested": [key: controls]], mode: mode, label: "keys_arrays_types"),
        ]
        let first = try request(output: cases[0].output)
        _ = try await f.provider.preflightContinuation(first)
        XCTAssertEqual(f.capture.snapshot.count, 0)
        let untouchedAuthorization = await f.authorization.count
        XCTAssertEqual(untouchedAuthorization, 0)
        let capabilities = try await f.provider.probe()
        XCTAssertEqual(f.capture.snapshot.count, 2, "Only explicit fixture inventory and contract probe")
        for value in cases {
            let operationID = UUID()
            let pending = try request(output: "0", operationID: operationID)
            let next = try request(output: value.output, operationID: operationID)
            let requestCount = f.capture.snapshot.count
            let authorizationCount = await f.authorization.count
            let placeholder = try await f.provider.preflightContinuation(pending)
            let measured = try await f.provider.preflightContinuation(next)
            XCTAssertEqual(f.capture.snapshot.count, requestCount)
            let afterPreflight = await f.authorization.count
            XCTAssertEqual(afterPreflight, authorizationCount)
            XCTAssertEqual(measured.configurationFingerprintSHA256, placeholder.configurationFingerprintSHA256)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let quotedContents = try encoder.encode(value.output).count - 2
            XCTAssertLessThanOrEqual(quotedContents, 2 * value.payload.count, value.label)
            XCTAssertLessThanOrEqual(quotedContents, 2 * value.full.count, value.label)
            XCTAssertEqual(measured.bodyByteCount - placeholder.bodyByteCount, quotedContents - 1, value.label)
            let actualInputBytes = try XCTUnwrap(measured.serializedInputByteCount)
            let placeholderInputBytes = try XCTUnwrap(placeholder.serializedInputByteCount)
            XCTAssertEqual(actualInputBytes - placeholderInputBytes, quotedContents - 1, value.label)
            XCTAssertLessThanOrEqual(measured.bodyByteCount, placeholder.bodyByteCount + 2 * fullResultCeiling)
            _ = try await f.provider.continueSession(next, observedCapabilities: capabilities)
            XCTAssertEqual(f.capture.snapshot.count, requestCount + 1, "One actual POST and no implicit probe")
            try assertCaptured(next, preflight: measured, capture: f.capture, expectedOutput: value.output)
        }
    }

    func testNativeCanonicalResultBoundMatchesRealPreflightAndDispatchWithoutTruncation() async throws {
        try await exerciseCanonicalMode(.native)
    }

    func testOrdinaryCanonicalResultBoundMatchesRealPreflightAndDispatchWithoutTruncation() async throws {
        try await exerciseCanonicalMode(.ordinary)
    }

    func testNoncanonicalRawControlOutputCannotUseCanonicalTwofoldBound() async throws {
        let f = try fixture(); defer { f.close() }
        let raw = String(repeating: "\0", count: 1_024)
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: Data(raw.utf8)))
        XCTAssertThrowsError(try ProviderContinuationRequest(operationID: UUID(), idempotencyKey: "malformed-input",
            modelKey: "fixture/tool-model", previousResponseID: "resp_parent", input: Data("{not-json".utf8), tools: []))
        let operationID = UUID()
        let pending = try request(output: "0", operationID: operationID)
        let next = try request(output: raw, operationID: operationID)
        let placeholder = try await f.provider.preflightContinuation(pending)
        let measured = try await f.provider.preflightContinuation(next)
        XCTAssertEqual(f.capture.snapshot.count, 0)
        let beforeAuthorization = await f.authorization.count
        XCTAssertEqual(beforeAuthorization, 0)
        XCTAssertEqual(measured.bodyByteCount - placeholder.bodyByteCount, 6 * raw.utf8.count - 1)
        XCTAssertGreaterThan(measured.bodyByteCount - placeholder.bodyByteCount, 2 * raw.utf8.count)
        // Generic function output remains a String. This proves why its raw value
        // cannot acquire a canonical-result reservation solely from its byte count.
        let capabilities = try await f.provider.probe()
        let before = f.capture.snapshot.count
        _ = try await f.provider.continueSession(next, observedCapabilities: capabilities)
        XCTAssertEqual(f.capture.snapshot.count, before + 1)
        try assertCaptured(next, preflight: measured, capture: f.capture, expectedOutput: raw)
    }

    func testExactWireLimitAcceptsWholeCanonicalResultAndOneByteLessRejectsLocally() async throws {
        let f = try fixture(); defer { f.close() }
        let value = try nearCeiling(mode: .native, label: "wire_limit", pattern: "/")
        XCTAssertEqual(value.full.count, fullResultCeiling)
        let next = try request(output: value.output)
        let measured = try await f.provider.preflightContinuation(next)
        var exactConfiguration = f.configuration
        exactConfiguration.maximumRequestBytes = measured.bodyByteCount
        let exact = try f.provider(configuration: exactConfiguration)
        let exactPreflight = try await exact.preflightContinuation(next)
        XCTAssertEqual(exactPreflight.bodySHA256, measured.bodySHA256)
        XCTAssertEqual(exactPreflight.bodyByteCount, exactPreflight.limits.maximumRequestBytes)
        var tooSmallConfiguration = exactConfiguration
        tooSmallConfiguration.maximumRequestBytes -= 1
        let tooSmall = try f.provider(configuration: tooSmallConfiguration)
        do {
            _ = try await tooSmall.preflightContinuation(next)
            XCTFail("Oversized output must be rejected rather than clipped to the configured body limit")
        } catch let error as LMStudioProviderError {
            guard case .limitExceeded = error else { return XCTFail("Unexpected typed limit error: \(error)") }
        }
        XCTAssertEqual(f.capture.snapshot.count, 0)
        let beforeAuthorization = await f.authorization.count
        XCTAssertEqual(beforeAuthorization, 0)
        let capabilities = try await exact.probe()
        let before = f.capture.snapshot.count
        _ = try await exact.continueSession(next, observedCapabilities: capabilities)
        XCTAssertEqual(f.capture.snapshot.count, before + 1)
        try assertCaptured(next, preflight: exactPreflight, capture: f.capture, expectedOutput: value.output)
    }
}

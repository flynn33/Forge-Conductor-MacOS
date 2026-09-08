import Foundation
import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

private actor PreflightAuthorization: LMStudioAuthorizationProviding {
    private var resolutions = 0
    func bearerToken() async throws -> String? {
        resolutions += 1
        return "fixture-provider-token"
    }
    var count: Int { resolutions }
}

private final class PreflightCapabilityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        instant = instant.advanced(by: .seconds(seconds))
    }
}

private final class PreflightCapture: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let requestID: String?
        let body: Data
    }
    private let lock = NSLock()
    private var requests: [Request] = []
    private var replacementModels: Data?
    func replaceModels(_ data: Data) throws {
        guard data.count <= 8_192 else { throw URLError(.dataLengthExceedsMaximum) }
        lock.lock(); defer { lock.unlock() }; replacementModels = data
    }
    var models: Data? { lock.lock(); defer { lock.unlock() }; return replacementModels }
    func record(_ request: Request) throws {
        lock.lock(); defer { lock.unlock() }
        guard requests.count < 16, request.body.count <= 1_048_576 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        requests.append(request)
    }
    var snapshot: [Request] { lock.lock(); defer { lock.unlock() }; return requests }
}

private final class PreflightRecordingProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var captures: [String: PreflightCapture] = [:]
    }
    private static let registry = Registry()
    static func register(_ capture: PreflightCapture, host: String) throws {
        registry.lock.lock(); defer { registry.lock.unlock() }
        guard registry.captures.count < 16, registry.captures[host] == nil else { throw URLError(.resourceUnavailable) }
        registry.captures[host] = capture
    }
    static func remove(host: String) {
        registry.lock.lock(); defer { registry.lock.unlock() }
        registry.captures.removeValue(forKey: host)
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".preflight.fixture") == true
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
            try capture.record(.init(method: request.httpMethod ?? "", path: url.path,
                requestID: request.value(forHTTPHeaderField: "X-Forge-Request-ID"), body: body))
            let data: Data
            let contentType: String
            if request.httpMethod == "GET", url.path == "/api/v1/models" {
                let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .appendingPathComponent("Fixtures/LMStudio/models-loaded.json")
                data = try capture.models ?? Data(contentsOf: fixture)
                contentType = "application/json"
            } else if request.httpMethod == "POST", url.path == "/v1/responses" {
                let value = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let tools = value["tools"] as? [[String: Any]] ?? []
                let probe = tools.contains { $0["name"] as? String == LMStudioRESTClient.capabilityProbeToolName }
                let previous = value["previous_response_id"] as? String
                let output: [[String: Any]] = probe ? [[
                    "id": "item_preflight_probe", "type": "function_call", "status": "completed",
                    "call_id": "call_preflight_probe", "name": LMStudioRESTClient.capabilityProbeToolName,
                    "arguments": #"{"accepted":true,"contract_version":1}"#,
                ]] : []
                let event: [String: Any] = ["type": "response.completed", "sequence_number": 0,
                    "response": ["id": probe ? "resp_preflight_probe" : (previous == nil ? "resp_preflight_root" : "resp_preflight_continuation"),
                        "model": value["model"] ?? "fixture/tool-model", "status": "completed",
                        "previous_response_id": previous as Any? ?? NSNull(), "output": output,
                        "usage": ["input_tokens": 24, "output_tokens": 8, "total_tokens": 32]]]
                let json = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
                data = Data("event: response.completed\ndata: ".utf8) + json + Data("\n\ndata: [DONE]\n\n".utf8)
                contentType = "text/event-stream"
            } else { throw URLError(.unsupportedURL) }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType, "X-LM-Studio-Version": "0.3.fixture"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            guard data.count + count <= 1_048_576 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private actor UnsupportedPreflightTransport: LMStudioManagedTransporting {
    private var effects = 0
    func probe() async throws -> LMStudioProviderCapabilities { effects += 1; throw URLError(.unsupportedURL) }
    func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn { effects += 1; throw URLError(.unsupportedURL) }
    func continueSession(_ request: LMStudioContinuationRequest) async throws -> LMStudioResponseTurn { effects += 1; throw URLError(.unsupportedURL) }
    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? { nil }
    func cancel(operationID: String) async {}
    var effectCount: Int { effects }
}

final class ManagedModelProviderPreflightTests: XCTestCase {
    private struct Fixture {
        let configuration: LMStudioProviderConfiguration
        let session: URLSessionConfiguration
        let capture: PreflightCapture
        let authorization: PreflightAuthorization
        let provider: LMStudioManagedModelProvider
        func close() { PreflightRecordingProtocol.remove(host: configuration.baseURL.host!) }
        func provider(configuration: LMStudioProviderConfiguration) throws -> LMStudioManagedModelProvider {
            LMStudioManagedModelProvider(transport: try LMStudioManagedSessionTransport(
                configuration: configuration, sessionConfiguration: session, authorization: authorization))
        }
    }

    private func fixture() throws -> Fixture {
        let host = UUID().uuidString.lowercased() + ".preflight.fixture"
        let capture = PreflightCapture()
        try PreflightRecordingProtocol.register(capture, host: host)
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [PreflightRecordingProtocol.self]
        var configuration = LMStudioProviderConfiguration(
            baseURL: URL(string: "https://" + host)!, modelKey: "fixture/tool-model",
            keychainTokenReference: "fixture-private-reference", connectTimeoutSeconds: 2,
            firstByteTimeoutSeconds: 4, idleTimeoutSeconds: 6, totalTimeoutSeconds: 12,
            maximumJSONBytes: 8_192, maximumRequestBytes: 16_384, maximumSSELineBytes: 8_192,
            maximumSSEEventBytes: 16_384, maximumResponseBytes: 65_536,
            maximumTextBytes: 32_768, maximumToolArgumentBytes: 16_384, maximumOutputTokens: 321)
        configuration.revision = UUID().uuidString.lowercased()
        let authorization = PreflightAuthorization()
        return Fixture(configuration: configuration, session: session, capture: capture, authorization: authorization,
            provider: LMStudioManagedModelProvider(transport: try LMStudioManagedSessionTransport(
                configuration: configuration, sessionConfiguration: session, authorization: authorization)))
    }

    private func root(input: String = "Read /fixture/quoted\"path\"\nwith unicode 雪 and slash /.",
                      tools: [Data]? = nil) throws -> ProviderRootRequest {
        let tool = try CanonicalToolDefinition(name: "fixture_lookup", description: "Read a path / bounded.",
            inputSchema: ["type": "object", "additionalProperties": false,
                "properties": ["path": ["type": "string"]], "required": ["path"]]).providerDefinitionJSON()
        return try ProviderRootRequest(operationID: UUID(), idempotencyKey: UUID().uuidString,
            modelKey: "fixture/tool-model", input: input, tools: tools ?? [tool])
    }

    private func continuation(previous: String = "resp_preflight_root", callID: String = "call_original/雪",
                              output: String = #"{"path":"/fixture/quoted\"name","content":"雪\nline"}"#) throws -> ProviderContinuationRequest {
        try ProviderContinuationRequest(operationID: UUID(), idempotencyKey: UUID().uuidString,
            modelKey: "fixture/tool-model", previousResponseID: previous,
            input: ForgeJSONCanonicalizationV1.data(from: [["type": "function_call_output", "call_id": callID, "output": output]]),
            tools: root().tools)
    }

    func testLocalPreflightMatchesActualRootAndContinuationBodies() async throws {
        let f = try fixture(); defer { f.close() }
        let request = try root()
        let preflight = try await f.provider.preflightRoot(request)
        XCTAssertEqual(f.capture.snapshot.count, 0)
        let authBefore = await f.authorization.count
        XCTAssertEqual(authBefore, 0)
        XCTAssertEqual(preflight.kind, .root)
        XCTAssertEqual(preflight.modelKey, request.modelKey)
        XCTAssertEqual(preflight.configurationRevision, f.configuration.revision)
        XCTAssertEqual(preflight.limits.maximumOutputTokens, 321)
        XCTAssertEqual(preflight.limits.maximumRequestBytes, 16_384)
        XCTAssertEqual(preflight.limits.maximumResponseBytes, 65_536)
        XCTAssertEqual(preflight.limits.maximumTextBytes, 32_768)
        XCTAssertEqual(preflight.limits.maximumToolArgumentBytes, 16_384)
        XCTAssertEqual(preflight.limits.maximumJSONBytes, 8_192)
        XCTAssertEqual(preflight.limits.maximumSSELineBytes, 8_192)
        XCTAssertEqual(preflight.limits.maximumSSEEventBytes, 16_384)
        XCTAssertEqual(preflight.limits.connectTimeoutSeconds, 2)
        XCTAssertEqual(preflight.limits.firstByteTimeoutSeconds, 4)
        XCTAssertEqual(preflight.limits.idleTimeoutSeconds, 6)
        XCTAssertEqual(preflight.limits.totalTimeoutSeconds, 12)
        let display = String(reflecting: preflight)
        for excluded in [request.input, "fixture-private-reference", "fixture-provider-token", f.configuration.baseURL.absoluteString] {
            XCTAssertFalse(display.contains(excluded))
        }

        let turn = try await f.provider.createRoot(request)
        let actual = try XCTUnwrap(f.capture.snapshot.first { $0.requestID == request.operationID.uuidString.lowercased() })
        XCTAssertEqual(actual.path, "/v1/responses")
        XCTAssertEqual(actual.method, "POST")
        XCTAssertEqual(actual.body.count, preflight.bodyByteCount)
        XCTAssertEqual(JSONSupport.sha256Hex(actual.body), preflight.bodySHA256)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: actual.body) as? [String: Any])
        XCTAssertEqual(body["max_output_tokens"] as? Int, 321)
        XCTAssertNil(body["previous_response_id"])
        let encodedInput = try JSONSerialization.data(withJSONObject: XCTUnwrap(body["input"]), options: [.sortedKeys])
        XCTAssertEqual(preflight.serializedInputByteCount, encodedInput.count)

        let next = try continuation(previous: turn.responseID)
        let countBefore = f.capture.snapshot.count
        let authorizationBefore = await f.authorization.count
        let nextPreflight = try await f.provider.preflightContinuation(next)
        XCTAssertEqual(f.capture.snapshot.count, countBefore)
        let authorizationAfter = await f.authorization.count
        XCTAssertEqual(authorizationAfter, authorizationBefore)
        _ = try await f.provider.continueSession(next)
        let nextActual = try XCTUnwrap(f.capture.snapshot.last)
        XCTAssertEqual(nextActual.body.count, nextPreflight.bodyByteCount)
        XCTAssertEqual(JSONSupport.sha256Hex(nextActual.body), nextPreflight.bodySHA256)
        XCTAssertEqual(nextPreflight.kind, .continuation)
        XCTAssertEqual(nextPreflight.configurationFingerprintSHA256, preflight.configurationFingerprintSHA256)
        let nextBody = try XCTUnwrap(JSONSerialization.jsonObject(with: nextActual.body) as? [String: Any])
        XCTAssertEqual(nextBody["previous_response_id"] as? String, turn.responseID)
        let outputs = try XCTUnwrap(nextBody["input"] as? [[String: Any]])
        XCTAssertEqual(outputs.first?["call_id"] as? String, "call_original/雪")
        let encodedNextInput = try JSONSerialization.data(withJSONObject: outputs, options: [.sortedKeys])
        XCTAssertEqual(nextPreflight.serializedInputByteCount, encodedNextInput.count)
        XCTAssertGreaterThan(encodedNextInput.count, next.input.count,
            "The actual encoder's slash escaping must appear in input accounting")
    }

    func testObservedDispatchUsesOnlyRecordedProbeAndExactRequestBodies() async throws {
        let f = try fixture(); defer { f.close() }
        let capabilities = try await f.provider.probe()
        XCTAssertEqual(f.capture.snapshot.count, 2) // inventory plus the fixed contract request
        let request = try root()
        let preflight = try await f.provider.preflightRoot(request)
        let rootTurn = try await f.provider.createRoot(request, observedCapabilities: capabilities)
        XCTAssertEqual(f.capture.snapshot.count, 3)
        let actualRoot = try XCTUnwrap(f.capture.snapshot.last)
        XCTAssertEqual(JSONSupport.sha256Hex(actualRoot.body), preflight.bodySHA256)
        let next = try continuation(previous: rootTurn.responseID)
        let nextPreflight = try await f.provider.preflightContinuation(next)
        _ = try await f.provider.continueSession(next, observedCapabilities: capabilities)
        XCTAssertEqual(f.capture.snapshot.count, 4)
        XCTAssertEqual(JSONSupport.sha256Hex(try XCTUnwrap(f.capture.snapshot.last).body), nextPreflight.bodySHA256)
        let recorded = try await f.provider.lookupRecorded(idempotencyKey: request.idempotencyKey)
        XCTAssertEqual(recorded?.requestID, request.operationID.uuidString.lowercased())
        XCTAssertEqual(recorded?.responseID, rootTurn.responseID)
        XCTAssertEqual(f.capture.snapshot.count, 4)
    }

    func testExpiredObservationRejectsRootAndContinuationWithoutHiddenProbe() async throws {
        let f = try fixture(); defer { f.close() }
        let clock = PreflightCapabilityClock()
        let client = try LMStudioRESTClient(configuration: f.configuration,
            sessionConfiguration: f.session, authorization: f.authorization, capabilityClock: { clock.now() })
        let provider = LMStudioManagedModelProvider(transport: LMStudioManagedSessionTransport(client: client))
        let capabilities = try await provider.probe()
        XCTAssertEqual(f.capture.snapshot.count, 2)
        clock.advance(seconds: LMStudioRESTClient.capabilityCacheSeconds + 1)
        do {
            _ = try await provider.createRoot(root(), observedCapabilities: capabilities)
            XCTFail("Expired observations must not cause an implicit probe or assignment POST")
        } catch let error as LMStudioProviderError {
            guard case .invalidConfiguration = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            _ = try await provider.continueSession(continuation(), observedCapabilities: capabilities)
            XCTFail("Continuation dispatch must also reject an expired observation")
        } catch let error as LMStudioProviderError {
            guard case .invalidConfiguration = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(f.capture.snapshot.count, 2)
        let authorizationCalls = await f.authorization.count
        XCTAssertEqual(authorizationCalls, 2)
        _ = try await provider.probe() // Only this explicit observation may refresh the contract.
        XCTAssertEqual(f.capture.snapshot.count, 4)
    }

    func testForeignObservationAndReceiptLookupNeverDiscoverCapabilities() async throws {
        let f = try fixture(); defer { f.close() }
        let capabilities = try await f.provider.probe()
        let fresh = try f.provider(configuration: f.configuration)
        do {
            _ = try await fresh.createRoot(root(), observedCapabilities: capabilities)
            XCTFail("A copied capability value cannot replace this owner's explicit observation")
        } catch let error as ManagedModelProviderContractError {
            XCTAssertEqual(error, .invalidValue("capabilities were not observed by this provider"))
        }
        let absent = try await fresh.lookupRecorded(idempotencyKey: "unknown-original-request")
        XCTAssertNil(absent)
        XCTAssertEqual(f.capture.snapshot.count, 2)
        let unsupported = UnsupportedPreflightTransport()
        let unrefined = LMStudioManagedModelProvider(transport: unsupported)
        do {
            _ = try await unrefined.createRoot(root(), observedCapabilities: capabilities)
            XCTFail("Unrefined transports must not silently fall back to implicit probing")
        } catch let error as ManagedModelProviderContractError {
            XCTAssertEqual(error, .unsupportedCapability("observed request dispatch"))
        }
        let effects = await unsupported.effectCount
        XCTAssertEqual(effects, 0)
    }

    func testRecordedLookupPreservesOriginalCapabilitiesAfterLaterProbe() async throws {
        let f = try fixture(); defer { f.close() }
        let clock = PreflightCapabilityClock()
        let client = try LMStudioRESTClient(configuration: f.configuration,
            sessionConfiguration: f.session, authorization: f.authorization, capabilityClock: { clock.now() })
        let provider = LMStudioManagedModelProvider(transport: LMStudioManagedSessionTransport(client: client))
        let original = try await provider.probe()
        let request = try root()
        let turn = try await provider.createRoot(request, observedCapabilities: original)
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LMStudio/models-loaded.json")
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
        let changed = fixture.replacingOccurrences(of: "fixture/tool-model@32768", with: "fixture/tool-model@65536")
            .replacingOccurrences(of: "\"context_length\": 32768", with: "\"context_length\": 65536")
        try f.capture.replaceModels(Data(changed.utf8))
        clock.advance(seconds: LMStudioRESTClient.capabilityCacheSeconds + 1)
        let newer = try await provider.probe()
        XCTAssertNotEqual(newer.providerInstanceID, original.providerInstanceID)
        XCTAssertNotEqual(newer.contextLength, original.contextLength)
        let before = f.capture.snapshot.count
        let recovered = try await provider.lookupRecorded(idempotencyKey: request.idempotencyKey)
        XCTAssertEqual(recovered, turn)
        XCTAssertEqual(recovered?.usage?.capacity, original.contextLength)
        XCTAssertEqual(recovered?.providerInstanceID, original.providerInstanceID)
        XCTAssertEqual(f.capture.snapshot.count, before)
    }

    func testSourceOutputReservationPlaceholderUsesExactSerializedInputCount() async throws {
        let f = try fixture(); defer { f.close() }
        let pending = try continuation(output: "0")
        let preflight = try await f.provider.preflightContinuation(pending)
        let measured = try XCTUnwrap(preflight.serializedInputByteCount)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: pending.input) as? [[String: Any]])
        let actualEncoding = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        XCTAssertEqual(measured, actualEncoding.count)
        XCTAssertGreaterThan(measured, pending.input.count)
        XCTAssertEqual(f.capture.snapshot.count, 0)
    }

    func testConfigurationSnapshotIsImmutableAndFingerprintChangesWithLimits() async throws {
        let f = try fixture(); defer { f.close() }
        let request = try root()
        let before = try await f.provider.preflightRoot(request)
        var changed = f.configuration
        changed.maximumOutputTokens = 322
        let other = try f.provider(configuration: changed)
        let after = try await other.preflightRoot(request)
        XCTAssertNotEqual(after.configurationFingerprintSHA256, before.configurationFingerprintSHA256)
        XCTAssertNotEqual(after.bodySHA256, before.bodySHA256)
        XCTAssertEqual(after.limits.maximumOutputTokens, 322)
        let unchanged = try await f.provider.preflightRoot(request)
        XCTAssertEqual(unchanged, before)
        changed = f.configuration
        changed.keychainTokenReference = "different-private-reference"
        let referenceChanged = try await f.provider(configuration: changed).preflightRoot(request)
        XCTAssertNotEqual(referenceChanged.configurationFingerprintSHA256, before.configurationFingerprintSHA256)
        XCTAssertEqual(referenceChanged.bodySHA256, before.bodySHA256)
        XCTAssertEqual(f.capture.snapshot.count, 0)
        let resolutions = await f.authorization.count
        XCTAssertEqual(resolutions, 0)
    }

    func testExactBodyLimitAndFunctionCallIDBoundaryRejectBeforeNetwork() async throws {
        let f = try fixture(); defer { f.close() }
        let request = try root(input: String(repeating: "\"/雪", count: 600))
        let measured = try await f.provider.preflightRoot(request)
        XCTAssertGreaterThan(measured.bodyByteCount, 1_024)
        var exact = f.configuration
        exact.maximumRequestBytes = measured.bodyByteCount
        let exactResult = try await f.provider(configuration: exact).preflightRoot(request)
        XCTAssertEqual(exactResult.bodySHA256, measured.bodySHA256)
        exact.maximumRequestBytes -= 1
        do {
            _ = try await f.provider(configuration: exact).preflightRoot(request)
            XCTFail("Serialized bytes above the immutable request limit must be rejected")
        } catch let error as LMStudioProviderError {
            guard case .limitExceeded = error else { return XCTFail("Unexpected error: \(error)") }
        }
        _ = try await f.provider.preflightContinuation(continuation(callID: String(repeating: "c", count: 512)))
        do {
            _ = try await f.provider.preflightContinuation(continuation(callID: String(repeating: "c", count: 513)))
            XCTFail("The provider's actual output call-ID bound must be checked before dispatch")
        } catch let error as ManagedModelProviderContractError {
            XCTAssertEqual(error, .invalidValue("function call output is invalid"))
        }
        let client = try LMStudioRESTClient(configuration: f.configuration,
            sessionConfiguration: f.session, authorization: f.authorization)
        _ = try await client.preflightContinuation(LMStudioContinuationRequest(modelKey: "fixture/tool-model",
            previousResponseID: "resp_preflight_root", input: [.functionCallOutput(callID: String(repeating: "c", count: 512), output: "{}")],
            idempotencyKey: "direct-call-boundary"))
        do {
            _ = try await client.preflightContinuation(LMStudioContinuationRequest(modelKey: "fixture/tool-model",
                previousResponseID: "resp_preflight_root",
                input: [.functionCallOutput(callID: " " + String(repeating: "c", count: 512), output: "{}")],
                idempotencyKey: "direct-call-oversize"))
            XCTFail("Whitespace trimming must not hide oversized original call IDs")
        } catch let error as LMStudioProviderError {
            guard case .invalidConfiguration = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(f.capture.snapshot.count, 0)
        let resolutions = await f.authorization.count
        XCTAssertEqual(resolutions, 0)
    }

    func testMalformedFunctionAndWrongModelRejectWithoutProbe() async throws {
        let f = try fixture(); defer { f.close() }
        do {
            _ = try await f.provider.preflightRoot(root(tools: [Data(#"{"type":"mcp","name":"foreign","parameters":{}}"#.utf8)]))
            XCTFail("Only the actual function schema is supported")
        } catch is ManagedModelProviderContractError {}
        do {
            _ = try await f.provider.preflightRoot(ProviderRootRequest(operationID: UUID(), idempotencyKey: "wrong-model",
                modelKey: "different-model", input: "No inventory request", tools: []))
            XCTFail("The request model must match the immutable configured model")
        } catch let error as LMStudioProviderError {
            guard case .invalidConfiguration = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(f.capture.snapshot.count, 0)
        let resolutions = await f.authorization.count
        XCTAssertEqual(resolutions, 0)
    }

    func testUnsupportedInjectedTransportCannotClaimPreflight() async throws {
        let transport = UnsupportedPreflightTransport()
        let provider = LMStudioManagedModelProvider(transport: transport)
        do {
            _ = try await provider.preflightRoot(root())
            XCTFail("Unrefined transports cannot supply guessed execution limits")
        } catch let error as ManagedModelProviderContractError {
            XCTAssertEqual(error, .unsupportedCapability("request preflight"))
        }
        do {
            _ = try await provider.preflightContinuation(continuation())
            XCTFail("Continuation also requires exact transport preflight")
        } catch let error as ManagedModelProviderContractError {
            XCTAssertEqual(error, .unsupportedCapability("request preflight"))
        }
        let effects = await transport.effectCount
        XCTAssertEqual(effects, 0)
    }

    func testExecutionLimitsRejectNonfiniteDeadlinesAndInconsistentBounds() throws {
        func limits(total: Double = 12, responseBytes: Int = 65_536) throws -> ProviderExecutionLimits {
            try ProviderExecutionLimits(maximumOutputTokens: 321, maximumRequestBytes: 16_384,
                maximumResponseBytes: responseBytes, maximumTextBytes: 32_768,
                maximumToolArgumentBytes: 16_384, maximumJSONBytes: 8_192,
                maximumSSELineBytes: 8_192, maximumSSEEventBytes: 16_384,
                connectTimeoutSeconds: 2, firstByteTimeoutSeconds: 4,
                idleTimeoutSeconds: 6, totalTimeoutSeconds: total)
        }
        XCTAssertThrowsError(try limits(total: .nan))
        XCTAssertThrowsError(try limits(total: .infinity))
        XCTAssertThrowsError(try limits(total: 3))
        XCTAssertThrowsError(try limits(responseBytes: 1_024))
        let valid = try limits()
        XCTAssertThrowsError(try ProviderRequestPreflight(kind: .root, modelKey: "fixture/tool-model",
            configurationRevision: "0", configurationFingerprintSHA256: String(repeating: "a", count: 64),
            limits: valid, bodySHA256: String(repeating: "b", count: 64), bodyByteCount: valid.maximumRequestBytes + 1))
        XCTAssertThrowsError(try ProviderRequestPreflight(kind: .root, modelKey: "fixture/tool-model",
            configurationRevision: "0", configurationFingerprintSHA256: "invalid",
            limits: valid, bodySHA256: String(repeating: "b", count: 64), bodyByteCount: 100))
    }
}

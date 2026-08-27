import Foundation
import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class LMStudioContractFixtureTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LMStudioContractFixtureServer.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testLoadedModelFixtureDeclaresToolCapabilityAndContext() async throws {
        let request = URLRequest(url: URL(string: "http://lmstudio.fixture/api/v1/models")!)
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let model = try XCTUnwrap((root["models"] as? [[String: Any]])?.first)
        let capability = try XCTUnwrap(model["capabilities"] as? [String: Any])
        let instance = try XCTUnwrap((model["loaded_instances"] as? [[String: Any]])?.first)
        let config = try XCTUnwrap(instance["config"] as? [String: Any])
        XCTAssertEqual(model["key"] as? String, "fixture/tool-model")
        XCTAssertEqual(capability["trained_for_tool_use"] as? Bool, true)
        XCTAssertEqual(config["context_length"] as? Int, 32_768)
        XCTAssertEqual(model["max_context_length"] as? Int, 131_072)
    }

    func testRootAndContinuationResponsesRemainDistinct() async throws {
        let root = try await postResponse([
            "model": "fixture/tool-model",
            "store": true,
            "stream": true,
            "input": "bounded handoff",
        ])
        XCTAssertTrue(root.contains("resp_lms_fixture_root"))
        XCTAssertTrue(root.contains("forge_continuity_ack"))
        XCTAssertTrue(root.contains("\"previous_response_id\":null"))
        let rootEvents = try events(from: root)
        XCTAssertEqual(rootEvents.first?["type"] as? String, "response.created")
        XCTAssertEqual(rootEvents.last?["type"] as? String, "response.completed")
        let deltas = rootEvents
            .filter { $0["type"] as? String == "response.function_call_arguments.delta" }
            .compactMap { $0["delta"] as? String }
            .joined()
        let done = try XCTUnwrap(rootEvents.first {
            $0["type"] as? String == "response.function_call_arguments.done"
        }?["arguments"] as? String)
        XCTAssertEqual(deltas, done)
        let acknowledgment = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(done.utf8)) as? [String: Any]
        )
        XCTAssertEqual(acknowledgment["schema_version"] as? Int, 2)
        XCTAssertEqual(acknowledgment["bootstrap_nonce"] as? String, "fixture-nonce-0001")

        let continuation = try await postResponse([
            "model": "fixture/tool-model",
            "store": true,
            "stream": true,
            "previous_response_id": "resp_lms_fixture_root",
            "input": [["type": "function_call_output", "call_id": "call_lms_fixture_ack", "output": "{}"]],
        ])
        XCTAssertTrue(continuation.contains("resp_lms_fixture_continuation"))
        XCTAssertTrue(continuation.contains("Continuation accepted."))
        XCTAssertTrue(continuation.contains("\"previous_response_id\":\"resp_lms_fixture_root\""))
    }

    func testErrorFixturesAreTypedAndBounded() async throws {
        for (path, status, code) in [
            ("401", 401, "invalid_api_token"),
            ("403", 403, "permission_denied"),
            ("404", 404, "model_not_found"),
            ("409", 409, "response_conflict"),
            ("429", 429, "rate_limit_exceeded"),
            ("500", 500, "server_error"),
        ] {
            let request = URLRequest(url: URL(string: "http://lmstudio.fixture/fixture/errors/\(path)")!)
            let (data, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
            XCTAssertLessThan(data.count, 1024)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let error = try XCTUnwrap(root["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, code)
        }
    }

    func testManagedTransportProbesCreatesFreshRootAndContinuesExactResponse() async throws {
        let transport = try makeTransport()
        let capabilities = try await transport.probe()
        XCTAssertEqual(capabilities.modelKey, "fixture/tool-model")
        XCTAssertEqual(capabilities.loadedInstanceID, "fixture/tool-model@32768")
        XCTAssertEqual(capabilities.contextLength, 32_768)
        XCTAssertTrue(capabilities.trainedForToolUse)
        XCTAssertEqual(capabilities.providerVersion, "0.3.fixture")
        XCTAssertTrue(capabilities.streamingVerified)
        XCTAssertTrue(capabilities.functionToolContractVerified)
        XCTAssertTrue(capabilities.usageReportingVerified)
        XCTAssertEqual(capabilities.contractProbeResponseID, "resp_lms_contract_probe")
        XCTAssertEqual(capabilities.capabilityFingerprintSHA256.utf8.count, 64)
        XCTAssertTrue(capabilities.capabilityFingerprintSHA256.allSatisfy {
            "0123456789abcdef".contains($0)
        })

        let acknowledgmentTool = LMStudioFunctionTool(
            name: "forge_continuity_ack",
            description: "Acknowledge the exact bounded handoff.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .boolean(false),
                "properties": .object([
                    "schema_version": .object(["const": .integer(2)]),
                    "handoff_id": .object(["type": .string("string")]),
                    "bootstrap_nonce": .object(["type": .string("string")]),
                ]),
                "required": .array([
                    .string("schema_version"), .string("handoff_id"), .string("bootstrap_nonce"),
                ]),
            ])
        )
        let root = try await transport.createRoot(LMStudioRootRequest(
            systemPrompt: "Validate the supplied handoff and acknowledge it.",
            userInput: "bounded handoff fixture",
            tools: [acknowledgmentTool],
            idempotencyKey: "fixture-root"
        ))
        XCTAssertEqual(root.responseID, "resp_lms_fixture_root")
        XCTAssertNil(root.previousResponseID)
        XCTAssertEqual(root.model, "fixture/tool-model")
        XCTAssertEqual(root.status, "completed")
        XCTAssertEqual(root.functionCalls.map(\.name), ["forge_continuity_ack"])
        XCTAssertEqual(root.usage.totalTokens, 544)

        let continuation = try await transport.continueSession(LMStudioContinuationRequest(
            previousResponseID: root.responseID,
            input: [.functionCallOutput(callID: "call_lms_fixture_ack", output: "{}")],
            idempotencyKey: "fixture-continuation"
        ))
        XCTAssertEqual(continuation.responseID, "resp_lms_fixture_continuation")
        XCTAssertEqual(continuation.previousResponseID, root.responseID)
        XCTAssertEqual(continuation.assistantText, "Continuation accepted.")
        XCTAssertEqual(continuation.usage.totalTokens, 136)
    }

    func testIncrementalDecoderBoundsIdentifiersAndRedaction() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LMStudio/responses-root.sse")
        let fixture = try Data(contentsOf: url)
        var decoder = LMStudioSSEDecoder(
            maximumLineBytes: 64 * 1024,
            maximumEventBytes: 256 * 1024,
            maximumTotalBytes: fixture.count + 1
        )
        var frames: [LMStudioSSEFrame] = []
        for byte in fixture {
            frames.append(contentsOf: try decoder.feed(Data([byte])))
        }
        frames.append(contentsOf: try decoder.finish())
        XCTAssertEqual(frames.filter { !$0.isDone }.count, 6)
        XCTAssertTrue(frames.last?.isDone == true)

        var bounded = LMStudioSSEDecoder(
            maximumLineBytes: 8, maximumEventBytes: 32, maximumTotalBytes: 64
        )
        XCTAssertThrowsError(try bounded.feed(Data("data: 123456789".utf8))) { error in
            XCTAssertEqual(error as? LMStudioProviderError, .limitExceeded("SSE line"))
        }
        XCTAssertThrowsError(try LMStudioProviderIdentifier.validate("native-fabricated")) { error in
            XCTAssertEqual(error as? LMStudioProviderError, .syntheticProviderIdentifier)
        }
        XCTAssertThrowsError(try LMStudioProviderIdentifier.validate("forge-logical-session")) { error in
            XCTAssertEqual(error as? LMStudioProviderError, .syntheticProviderIdentifier)
        }
        let secret = "Authorization: Bearer fixture-secret api_key=private-value"
        let redacted = LMStudioRedaction.redact(secret)
        XCTAssertFalse(redacted.contains("fixture-secret"))
        XCTAssertFalse(redacted.contains("private-value"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
        XCTAssertTrue(LMStudioRedaction.containsSecretLikeContent(
            #"{"api_key":"private-json-value"}"#
        ))
        XCTAssertFalse(LMStudioRedaction.containsSecretLikeContent(
            #"{"input_tokens":512,"output_tokens":32}"#
        ))
    }

    func testV2CanonicalDigestMatchesCoreAcrossSlashContainingWireValues() throws {
        let object: [String: Any] = [
            "path": "/fixture/project",
            "nested": ["url": "https://lmstudio.fixture/v1/responses"],
            "integrity": ["content_sha256": "ignored"],
        ]
        let digest = try ContinuityHandoffV2Validation.contentSHA256(
            forJSONObject: object
        )
        var coreContent = object
        coreContent.removeValue(forKey: "integrity")
        XCTAssertEqual(
            digest,
            try ForgeJSONCanonicalizationV1.sha256Hex(of: coreContent)
        )
        XCTAssertEqual(
            digest,
            "80bf60582821b373cdc58a20325864fe53bc9985d79fc1806d0e1e8f26342552"
        )
    }

    func testManagedTransportClassifiesHTTPFailuresAndProviderSignals() async throws {
        let transport = try makeTransport()
        let failures: [(String, LMStudioProviderError)] = [
            ("fixture-error-401", .unauthorized),
            ("fixture-error-403", .forbidden),
            ("fixture-error-404", .endpointNotFound),
            ("fixture-error-409", .conflict),
            ("fixture-error-500", .serverFailure(status: 500)),
            ("fixture-context-overflow", .contextOverflow),
            ("fixture-response-truncated", .responseTruncated),
        ]
        for (marker, expected) in failures {
            do {
                _ = try await transport.createRoot(LMStudioRootRequest(
                    systemPrompt: marker, userInput: "bounded",
                    tools: [], idempotencyKey: marker
                ))
                XCTFail("\(marker) must fail")
            } catch {
                XCTAssertEqual(
                    error as? LMStudioProviderError,
                    expected,
                    "\(marker): \(String(describing: error))"
                )
            }
        }
        XCTAssertEqual(
            LMStudioHTTPErrorClassifier.classify(status: 429, retryAfter: "2"),
            .rateLimited(retryNanoseconds: 2_000_000_000)
        )
        XCTAssertEqual(
            LMStudioHTTPErrorClassifier.classify(
                status: 400,
                body: Data(#"{"error":{"message":"maximum context length exceeded"}}"#.utf8)
            ),
            .contextOverflow
        )
    }

    func testKeychainAuthorizationFeedsBearerHeaderWithoutPersistingReference() async throws {
        let privateReference = "private-fixture-keychain-reference"
        let authorization = try LMStudioKeychainAuthorization(
            reference: privateReference
        ) { reference in
            reference == privateReference ? Data("fixture-token".utf8) : nil
        }
        let authenticated = try makeTransport(authorization: authorization)
        let turn = try await authenticated.createRoot(LMStudioRootRequest(
            systemPrompt: "fixture-require-auth",
            userInput: "bounded",
            tools: [],
            idempotencyKey: "fixture-authenticated-root"
        ))
        XCTAssertEqual(turn.responseID, "resp_lms_fixture_root")
        XCTAssertFalse(String(describing: turn).contains(privateReference))
        XCTAssertFalse(String(describing: turn).contains("fixture-token"))

        let unauthenticated = try makeTransport()
        do {
            _ = try await unauthenticated.createRoot(LMStudioRootRequest(
                systemPrompt: "fixture-require-auth",
                userInput: "bounded",
                tools: [],
                idempotencyKey: "fixture-unauthenticated-root"
            ))
            XCTFail("missing bearer token must fail")
        } catch {
            XCTAssertEqual(error as? LMStudioProviderError, .unauthorized)
            XCTAssertFalse(String(describing: error).contains(privateReference))
            XCTAssertFalse(String(describing: error).contains("fixture-token"))
        }
    }

    func testManagedTransportBoundsMalformedOversizedAndDisconnectedStreams() async throws {
        let transport = try makeTransport(maximumSSELineBytes: 1024)
        for (marker, expected) in [
            ("fixture-malformed-sse", LMStudioProviderError.malformedResponse(
                "SSE data is not a typed JSON event"
            )),
            ("fixture-oversized-sse", LMStudioProviderError.limitExceeded("SSE line")),
            ("fixture-disconnect", LMStudioProviderError.providerUnavailable),
        ] {
            do {
                _ = try await transport.createRoot(LMStudioRootRequest(
                    systemPrompt: marker, userInput: "bounded",
                    tools: [], idempotencyKey: marker
                ))
                XCTFail("\(marker) must fail")
            } catch {
                XCTAssertEqual(
                    error as? LMStudioProviderError,
                    expected,
                    "\(marker): \(String(describing: error))"
                )
            }
        }
    }

    func testManagedTransportEnforcesFirstByteIdleAndTotalDeadlines() async throws {
        let connectTransport = try makeTransport(
            connectTimeoutSeconds: 0.05, firstByteTimeoutSeconds: 0.1,
            idleTimeoutSeconds: 0.1, totalTimeoutSeconds: 0.5
        )
        do {
            _ = try await connectTransport.createRoot(LMStudioRootRequest(
                systemPrompt: "fixture-connect-timeout", userInput: "bounded",
                tools: [], idempotencyKey: "fixture-connect-timeout"
            ))
            XCTFail("connect deadline must fail")
        } catch {
            XCTAssertEqual(error as? LMStudioProviderError, .deadlineExceeded(phase: "connect"))
        }

        let timeoutTransport = try makeTransport(
            firstByteTimeoutSeconds: 0.05, idleTimeoutSeconds: 0.1,
            totalTimeoutSeconds: 0.5
        )
        do {
            _ = try await timeoutTransport.createRoot(LMStudioRootRequest(
                systemPrompt: "fixture-first-byte-timeout", userInput: "bounded",
                tools: [], idempotencyKey: "fixture-first-byte-timeout"
            ))
            XCTFail("first-byte deadline must fail")
        } catch {
            XCTAssertEqual(
                error as? LMStudioProviderError,
                .deadlineExceeded(phase: "first-byte")
            )
        }

        let idleTransport = try makeTransport(
            firstByteTimeoutSeconds: 0.05, idleTimeoutSeconds: 0.05,
            totalTimeoutSeconds: 1
        )
        do {
            _ = try await idleTransport.createRoot(LMStudioRootRequest(
                systemPrompt: "fixture-idle-timeout", userInput: "bounded",
                tools: [], idempotencyKey: "fixture-idle-timeout"
            ))
            XCTFail("idle deadline must fail")
        } catch {
            XCTAssertEqual(error as? LMStudioProviderError, .deadlineExceeded(phase: "idle"))
        }

        let totalTransport = try makeTransport(
            firstByteTimeoutSeconds: 0.01, idleTimeoutSeconds: 0.5,
            totalTimeoutSeconds: 0.05
        )
        do {
            _ = try await totalTransport.createRoot(LMStudioRootRequest(
                systemPrompt: "fixture-total-timeout", userInput: "bounded",
                tools: [], idempotencyKey: "fixture-total-timeout"
            ))
            XCTFail("total deadline must fail")
        } catch {
            XCTAssertEqual(error as? LMStudioProviderError, .deadlineExceeded(phase: "total"))
        }
    }

    private func postResponse(_ object: [String: Any]) async throws -> String {
        var request = URLRequest(url: URL(string: "http://lmstudio.fixture/v1/responses")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func makeTransport(
        connectTimeoutSeconds: Double = 1,
        firstByteTimeoutSeconds: Double = 1,
        idleTimeoutSeconds: Double = 1,
        totalTimeoutSeconds: Double = 2,
        maximumSSELineBytes: Int = 64 * 1024,
        authorization: any LMStudioAuthorizationProviding = LMStudioNoAuthorization()
    ) throws -> LMStudioManagedSessionTransport {
        let configuration = LMStudioProviderConfiguration(
            baseURL: URL(string: "https://lmstudio.fixture")!,
            modelKey: "fixture/tool-model",
            connectTimeoutSeconds: connectTimeoutSeconds,
            firstByteTimeoutSeconds: firstByteTimeoutSeconds,
            idleTimeoutSeconds: idleTimeoutSeconds,
            totalTimeoutSeconds: totalTimeoutSeconds,
            maximumJSONBytes: 1024 * 1024,
            maximumRequestBytes: 512 * 1024,
            maximumSSELineBytes: maximumSSELineBytes,
            maximumSSEEventBytes: 256 * 1024,
            maximumResponseBytes: 2 * 1024 * 1024,
            maximumTextBytes: 512 * 1024,
            maximumToolArgumentBytes: 256 * 1024
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [LMStudioContractFixtureServer.self]
        return try LMStudioManagedSessionTransport(
            configuration: configuration,
            sessionConfiguration: sessionConfiguration,
            authorization: authorization
        )
    }

    private func events(from stream: String) throws -> [[String: Any]] {
        try stream.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("data: ") else { return nil }
            let payload = line.dropFirst(6)
            guard payload != "[DONE]" else { return nil }
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            )
        }
    }
}

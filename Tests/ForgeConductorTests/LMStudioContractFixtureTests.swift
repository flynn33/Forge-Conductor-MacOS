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

    func testOrdinaryRESTPreflightOutputFloorSurvivesNilPreflightConfiguration() async throws {
        let directory = try terminalMetadataDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = try LMStudioManagedModelProvider(storageDirectory: directory, transport: makeTransport())
        let capabilities = try await provider.probe()
        let request = try ProviderRootRequest(operationID: UUID(), idempotencyKey: "ordinary-output-floor",
            modelKey: "fixture/tool-model", input: "bounded ordinary request", tools: [])
        let preflight = try await provider.preflightRoot(request)
        XCTAssertEqual(capabilities.contextLength, 32_768)
        XCTAssertEqual(capabilities.maximumContextLength, 131_072)
        XCTAssertEqual(preflight.limits.maximumOutputTokens, 4_096)
        let selection = try BudgetPolicyState.default.resolve(.globalDefault)
        let before = try PersistedManagedRunBudgetEvaluator.configuration(capabilities: capabilities,
            selection: selection, providerPreflight: preflight)
        let observation = try PersistedManagedRunBudgetEvaluator.configuration(capabilities: capabilities,
            selection: selection, providerPreflight: nil)
        XCTAssertEqual(before.capacity.capacity, 32_768)
        XCTAssertEqual(observation.capacity, before.capacity)
        XCTAssertEqual(before.reserves.outputTokens, 4_096)
        XCTAssertEqual(observation.reserves.outputTokens, 4_096,
            "The immutable REST request output bound remains reserved at ordinary observation hooks")
        XCTAssertEqual(observation.reserves, before.reserves)
    }

    func testOrdinaryRESTOutputFloorSurvivesCachedObservationAndEvaluatorRestart() async throws {
        let root = try terminalMetadataDirectory()
        let repository = try ProjectControlPlaneRepository(databaseURL: root.appendingPathComponent("control-plane.sqlite3"))
        do {
            let provider = try LMStudioManagedModelProvider(storageDirectory: root.appendingPathComponent("provider"),
                transport: makeTransport())
            let capabilities = try await provider.probe()
            let request = try ProviderRootRequest(operationID: UUID(), idempotencyKey: "ordinary-cached-output-floor",
                modelKey: "fixture/tool-model", input: "fixture-terminal-text", tools: [])
            let preflight = try await provider.preflightRoot(request)
            let turn = try await provider.createRoot(request)
            XCTAssertEqual(capabilities.contextLength, 32_768)
            XCTAssertEqual(preflight.limits.maximumOutputTokens, 4_096)
            let projectID = ProjectID()
            let projectRoot = root.appendingPathComponent("project", isDirectory: true)
            _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Ordinary Output Floor",
                canonicalRoot: projectRoot)
            let run = try await repository.createAutonomousRun(AutonomousRunRequest(projectID: projectID,
                projectGeneration: .initial, mission: "Preserve the immutable ordinary REST output floor",
                providerID: capabilities.providerID, modelKey: capabilities.modelKey,
                specification: AutonomousRunSpecification(allowedTools: ["fixture.read"], completionGates: ["tests"]),
                authorizationScope: ToolAuthorizationScope(canonicalRoots: [projectRoot], allowedTools: ["fixture.read"],
                    networkAllowed: false, maximumInlineOutputBytes: 64 * 1_024)))
            let lease = try await repository.acquireRunLease(runID: run.runID, ownerID: "ordinary-floor-manager")
            let sessionID = "ordinary-floor-session-" + UUID().uuidString.lowercased()
            try await repository.reserveProviderSession(ProviderSessionIntent(sessionID: sessionID, runID: run.runID,
                projectID: projectID, projectGeneration: .initial, providerID: capabilities.providerID,
                adapterID: "lmstudio-rest", modelKey: capabilities.modelKey, providerResponseID: turn.responseID,
                idempotencyKey: request.idempotencyKey, contextCapacity: capabilities.contextLength), lease: lease)
            _ = try await repository.releaseRunLease(lease)
            let identity = ContextBudgetIdentity(runID: run.runID, projectID: projectID,
                projectGeneration: .initial, sessionID: sessionID)
            let selection = try BudgetPolicyState.default.resolve(.globalDefault)
            let evaluator = PersistedManagedRunBudgetEvaluator(repository: repository, policyResolver: { _ in selection })
            let accounting = ManagedBudgetInputAccounting(inputBytes: request.input.utf8.count, toolSchemaBytes: 0,
                toolSchemaSHA256: String(repeating: "a", count: 64), pendingInputID: String(repeating: "b", count: 64),
                inputAlreadyRetained: false, providerPreflight: preflight)
            _ = try await evaluator.evaluateBeforeProviderTurn(run: run, sessionID: sessionID,
                capabilities: capabilities, accounting: accounting)
            let beforeValue = try await repository.contextBudgetState(identity: identity)
            let before = try XCTUnwrap(beforeValue)
            XCTAssertEqual(before.configuration.capacity.capacity, 32_768)
            XCTAssertEqual(before.configuration.reserves.outputTokens, 4_096)
            _ = try await evaluator.observeProviderTurn(turn, run: run, sessionID: sessionID, capabilities: capabilities)
            let observedValue = try await repository.contextBudgetState(identity: identity)
            let observed = try XCTUnwrap(observedValue)
            XCTAssertEqual(observed.configuration, before.configuration,
                "The cached supervisor must retain its request reserve at a nil-preflight provider observation")
            XCTAssertEqual(observed.latestObservation?.used, 4_223)
            _ = try await evaluator.observeToolResult(serializedBytes: 120, providerResponseID: turn.responseID,
                run: run, sessionID: sessionID, capabilities: capabilities)
            let toolValue = try await repository.contextBudgetState(identity: identity)
            let tool = try XCTUnwrap(toolValue)
            XCTAssertEqual(tool.configuration, before.configuration)
            XCTAssertEqual(tool.latestObservation?.used, 4_273)
            let restarted = PersistedManagedRunBudgetEvaluator(repository: repository, policyResolver: { _ in selection })
            _ = try await restarted.observeToolResult(serializedBytes: 120, providerResponseID: turn.responseID,
                run: run, sessionID: sessionID, capabilities: capabilities)
            let restoredValue = try await repository.contextBudgetState(identity: identity)
            let restored = try XCTUnwrap(restoredValue)
            XCTAssertEqual(restored.configuration, before.configuration,
                "A fresh evaluator must restore the same reserve before an ordinary nil-preflight hook")
            XCTAssertEqual(restored.latestObservation?.used, 4_323)
            let observation = try XCTUnwrap(restored.latestObservation)
            XCTAssertEqual(observation.reserves.outputTokens, 4_096)
            XCTAssertEqual(observation.accounting?.admittedTotalTokens, observation.used + observation.fixedReserve)
            let pending = try await repository.contextBudgetActionRequest(identity: identity)
            XCTAssertNil(pending)
        } catch {
            await repository.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await repository.close()
        try FileManager.default.removeItem(at: root)
    }

    func testConfigurableOutputLimitKeepsLegacyDefaultAndFiniteProductBounds() throws {
        let configuration = LMStudioProviderConfiguration(baseURL: URL(string: "https://lmstudio.fixture")!, modelKey: "fixture/tool-model")
        XCTAssertEqual(configuration.maximumOutputTokens, 4_096)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        object.removeValue(forKey: "maximum_output_tokens")
        let legacy = try JSONDecoder().decode(LMStudioProviderConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object)).validated()
        XCTAssertEqual(legacy.maximumOutputTokens, 4_096)
        for valid in [1, 4_096, 8_192, 65_536] { XCTAssertNoThrow(try makeTransport(maximumOutputTokens: valid)) }
        for invalid in [0, 65_537] { XCTAssertThrowsError(try makeTransport(maximumOutputTokens: invalid)) }
        for invalid in [true, 1.5, "8192"] as [Any] {
            object["maximum_output_tokens"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(LMStudioProviderConfiguration.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
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

    func testManagedTransportRejectsInexactOverflowedAndMissingUsageCounters() async throws {
        let transport = try makeTransport()
        for name in ["boolean", "boolean-false", "fraction", "string", "overflow", "beyond-int",
                     "exponent-overflow", "negative", "missing-input", "missing-output", "null-input",
                     "small-total", "duplicate-input", "wrong-shape", "empty"] {
            let marker = "fixture-usage-" + name + ":"
            do {
                _ = try await transport.createRoot(LMStudioRootRequest(systemPrompt: marker, userInput: "bounded",
                    tools: [], idempotencyKey: "usage-" + name))
                XCTFail("\(name) must not be accepted as exact provider usage")
            } catch LMStudioProviderError.malformedResponse { }
            catch { XCTFail("\(name) returned unexpected error \(error)") }
        }
    }

    func testManagedTransportNormalizesExactUsageAndKeepsUnreportedUsageUnknown() async throws {
        let transport = try makeTransport()
        for name in ["normal", "integer-exponent", "missing-total", "zero", "absent", "null"] {
            let marker = "fixture-usage-" + name + ":"
            let turn = try await transport.createRoot(LMStudioRootRequest(systemPrompt: marker, userInput: "bounded",
                tools: [], idempotencyKey: "usage-" + name))
            XCTAssertEqual(turn.status, "completed")
            if name == "absent" || name == "null" {
                XCTAssertFalse(turn.usageWasReported, "A missing count must use conservative downstream estimation")
            } else {
                XCTAssertTrue(turn.usageWasReported)
                XCTAssertEqual(turn.usage.inputTokens, name == "zero" ? 0 : 512)
                XCTAssertEqual(turn.usage.outputTokens, name == "zero" ? 0 : 32)
                XCTAssertEqual(turn.usage.totalTokens, name == "zero" ? 0 : 544)
            }
        }
    }

    func testFullOutputTokenSSEFixtureHasCoherentBoundedLifecycle() throws {
        let data = try LMStudioContractFixtureServer.fullOutputTokenSSEFixture()
        let stream = try XCTUnwrap(String(data: data, encoding: .utf8))
        let fixtureEvents = try events(from: stream)
        let dataLines = stream.split(separator: "\n").filter { $0.hasPrefix("data: ") }
        let deltas = fixtureEvents.filter { $0["type"] as? String == "response.output_text.delta" }
        let streamedText = deltas.compactMap { $0["delta"] as? String }.joined()
        let maximumLineBytes = stream.split(separator: "\n").map { $0.utf8.count }.max() ?? 0
        let maximumEventBytes = dataLines.map { $0.dropFirst(6).utf8.count }.max() ?? 0
        if let path = ProcessInfo.processInfo.environment["FORGE_LMSTUDIO_SSE_FIXTURE_EVIDENCE"], !path.isEmpty {
            let evidence: [String: Any] = ["body_bytes": data.count, "body_sha256": JSONSupport.sha256Hex(data),
                "json_events": fixtureEvents.count, "data_events_including_done": dataLines.count,
                "text_delta_events": deltas.count, "maximum_line_bytes": maximumLineBytes,
                "maximum_event_bytes": maximumEventBytes, "text_bytes": streamedText.utf8.count]
            try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
        XCTAssertEqual(deltas.count, 4_096)
        XCTAssertEqual(fixtureEvents.count, 4_103)
        XCTAssertEqual(dataLines.count, 4_104)
        XCTAssertEqual(dataLines.last.map { String($0) }, "data: [DONE]")
        XCTAssertTrue(fixtureEvents.enumerated().allSatisfy {
            $0.element["sequence_number"] as? Int == $0.offset
        })
        let completed = try XCTUnwrap(fixtureEvents.last?["response"] as? [String: Any])
        XCTAssertEqual(completed["status"] as? String, "completed")
        let output = try XCTUnwrap((completed["output"] as? [[String: Any]])?.first)
        let part = try XCTUnwrap((output["content"] as? [[String: Any]])?.first)
        let text = try XCTUnwrap(part["text"] as? String)
        XCTAssertEqual(streamedText, text)
        XCTAssertEqual(text, String(repeating: "x", count: 4_096))
        let usage = try XCTUnwrap(completed["usage"] as? [String: Any])
        XCTAssertEqual(usage["input_tokens"] as? Int, 512)
        XCTAssertEqual(usage["output_tokens"] as? Int, 4_096)
        XCTAssertEqual(usage["total_tokens"] as? Int, 4_608)
        XCTAssertLessThan(data.count, 2 * 1024 * 1024)
        XCTAssertLessThanOrEqual(maximumLineBytes, 64 * 1024)
        XCTAssertLessThanOrEqual(maximumEventBytes, 256 * 1024)
        XCTAssertLessThanOrEqual(text.utf8.count, 512 * 1024)
    }

    func testRESTClientAcceptsFull4096TokenOutputWithLifecycleEvents() async throws {
        let configuration = LMStudioProviderConfiguration(
            baseURL: URL(string: "https://lmstudio.fixture")!, modelKey: "fixture/tool-model",
            connectTimeoutSeconds: 1, firstByteTimeoutSeconds: 1,
            idleTimeoutSeconds: 1, totalTimeoutSeconds: 2,
            maximumJSONBytes: 1024 * 1024, maximumRequestBytes: 512 * 1024,
            maximumSSELineBytes: 64 * 1024, maximumSSEEventBytes: 256 * 1024,
            maximumResponseBytes: 2 * 1024 * 1024, maximumTextBytes: 512 * 1024,
            maximumToolArgumentBytes: 256 * 1024, maximumOutputTokens: 4_096
        )
        let fixtureSession = URLSessionConfiguration.ephemeral
        fixtureSession.protocolClasses = [LMStudioContractFixtureServer.self]
        let client = try LMStudioRESTClient(configuration: configuration, sessionConfiguration: fixtureSession)
        let turn = try await client.createRoot(LMStudioRootRequest(
            systemPrompt: "fixture-full-output-token-sse", userInput: "bounded fixture output",
            tools: [], idempotencyKey: "fixture-full-4096-output"
        ))
        XCTAssertEqual(turn.responseID, "resp_full_output_token_fixture")
        XCTAssertNil(turn.previousResponseID)
        XCTAssertEqual(turn.model, "fixture/tool-model")
        XCTAssertEqual(turn.status, "completed")
        XCTAssertEqual(turn.assistantText, String(repeating: "x", count: 4_096))
        XCTAssertTrue(turn.functionCalls.isEmpty)
        XCTAssertTrue(turn.usageWasReported)
        XCTAssertEqual(turn.usage.inputTokens, 512)
        XCTAssertEqual(turn.usage.outputTokens, 4_096)
        XCTAssertEqual(turn.usage.totalTokens, 4_608)
    }

    func testRESTClientKeepsExact5120EventCapWithZeroOutputLifecycle() async throws {
        for count in [5_120, 5_121] {
            let data = try LMStudioContractFixtureServer.eventCountCapSSEFixture(dataEventCount: count)
            let stream = try XCTUnwrap(String(data: data, encoding: .utf8))
            let fixtureEvents = try events(from: stream)
            let dataLines = stream.split(separator: "\n").filter { $0.hasPrefix("data: ") }
            XCTAssertEqual(dataLines.count, count)
            XCTAssertEqual(fixtureEvents.count, count - 1)
            XCTAssertTrue(fixtureEvents.enumerated().allSatisfy {
                $0.element["sequence_number"] as? Int == $0.offset
            })
            XCTAssertEqual(fixtureEvents.filter { $0["type"] as? String == "response.in_progress" }.count,
                count - 3)
            XCTAssertLessThan(data.count, 2 * 1024 * 1024)
            XCTAssertLessThanOrEqual(stream.split(separator: "\n").map { $0.utf8.count }.max() ?? 0, 64 * 1024)
            XCTAssertLessThanOrEqual(dataLines.map { $0.dropFirst(6).utf8.count }.max() ?? 0, 256 * 1024)
        }
        let configuration = LMStudioProviderConfiguration(
            baseURL: URL(string: "https://lmstudio.fixture")!, modelKey: "fixture/tool-model",
            connectTimeoutSeconds: 1, firstByteTimeoutSeconds: 1,
            idleTimeoutSeconds: 1, totalTimeoutSeconds: 2,
            maximumJSONBytes: 1024 * 1024, maximumRequestBytes: 512 * 1024,
            maximumSSELineBytes: 64 * 1024, maximumSSEEventBytes: 256 * 1024,
            maximumResponseBytes: 2 * 1024 * 1024, maximumTextBytes: 512 * 1024,
            maximumToolArgumentBytes: 256 * 1024, maximumOutputTokens: 4_096
        )
        let fixtureSession = URLSessionConfiguration.ephemeral
        fixtureSession.protocolClasses = [LMStudioContractFixtureServer.self]
        let client = try LMStudioRESTClient(configuration: configuration, sessionConfiguration: fixtureSession)
        let accepted = try await client.createRoot(LMStudioRootRequest(
            systemPrompt: "fixture-event-count-cap-5120", userInput: "bounded fixture metadata",
            tools: [], idempotencyKey: "fixture-exact-5120-events"
        ))
        XCTAssertEqual(accepted.responseID, "resp_event_count_cap_fixture")
        XCTAssertNil(accepted.previousResponseID)
        XCTAssertEqual(accepted.status, "completed")
        XCTAssertEqual(accepted.assistantText, "")
        XCTAssertTrue(accepted.functionCalls.isEmpty)
        XCTAssertTrue(accepted.usageWasReported)
        XCTAssertEqual(accepted.usage.inputTokens, 16)
        XCTAssertEqual(accepted.usage.outputTokens, 0)
        XCTAssertEqual(accepted.usage.totalTokens, 16)
        do {
            _ = try await client.createRoot(LMStudioRootRequest(
                systemPrompt: "fixture-event-count-cap-5121", userInput: "bounded fixture metadata",
                tools: [], idempotencyKey: "fixture-exceeded-5121-events"
            ))
            XCTFail("One event above the REST cap must be rejected despite unchanged byte and output limits")
        } catch {
            XCTAssertEqual(error as? LMStudioProviderError, .limitExceeded("SSE event count"))
        }
    }

    func testManagedTransportSendsConfiguredOutputTokenBound() async throws {
        let transport = try makeTransport(maximumOutputTokens: 321)
        let turn = try await transport.createRoot(LMStudioRootRequest(
            systemPrompt: "fixture-require-output-token-bound",
            userInput: "bounded",
            tools: [],
            idempotencyKey: "fixture-output-token-bound"
        ))
        XCTAssertEqual(turn.responseID, "resp_lms_fixture_root")
    }

    func testManagedTransportSendsExactOneToolCallBounds() async throws {
        let transport = try makeTransport()
        let turn = try await transport.createRoot(LMStudioRootRequest(
            systemPrompt: "fixture-require-exact-one-tool",
            userInput: "bounded",
            tools: [],
            toolChoice: "required",
            parallelToolCalls: false,
            maximumToolCalls: 1,
            temperature: 0,
            idempotencyKey: "fixture-exact-one-tool"
        ))
        XCTAssertEqual(turn.responseID, "resp_lms_fixture_root")
    }

    func testManagedTransportReconcilesSemanticJSONArgumentsButRejectsChangedValues() async throws {
        let transport = try makeTransport()
        let accepted = try await transport.createRoot(LMStudioRootRequest(
            systemPrompt: "fixture-argument-reconciliation-equivalent",
            userInput: "bounded", tools: [], idempotencyKey: "fixture-arguments-equivalent"
        ))
        XCTAssertEqual(accepted.functionCalls.count, 1)
        XCTAssertEqual(
            accepted.functionCalls.first?.arguments,
            #"{"contract_version":1,"accepted":true}"#
        )

        do {
            _ = try await transport.createRoot(LMStudioRootRequest(
                systemPrompt: "fixture-argument-reconciliation-mismatch",
                userInput: "bounded", tools: [], idempotencyKey: "fixture-arguments-mismatch"
            ))
            XCTFail("Semantically changed function arguments must be rejected")
        } catch {
            XCTAssertEqual(
                error as? LMStudioProviderError,
                .malformedResponse("function argument deltas do not match completion")
            )
        }
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

    func testDecoderEnforcesExactPublishedEventCountCapWithinByteBounds() throws {
        let event = Data("data: x\n\n".utf8)
        var decoder = LMStudioSSEDecoder(maximumLineBytes: 64, maximumEventBytes: 64,
            maximumTotalBytes: event.count * (LMStudioSSEDecoder.maximumEvents + 1))
        for _ in 0..<LMStudioSSEDecoder.maximumEvents {
            let frames = try decoder.feed(event)
            XCTAssertEqual(frames.count, 1)
            XCTAssertEqual(frames.first?.data, Data("x".utf8))
        }
        XCTAssertThrowsError(try decoder.feed(event)) { error in
            XCTAssertEqual(error as? LMStudioProviderError, .limitExceeded("SSE event count"))
        }
    }

    func testDecoderKeepsIndependentEventAndTotalByteBounds() throws {
        var exactEvent = LMStudioSSEDecoder(maximumLineBytes: 8, maximumEventBytes: 3,
            maximumTotalBytes: 64)
        XCTAssertEqual(try exactEvent.feed(Data("data: x\ndata: x\n\n".utf8)).first?.data,
            Data("x\nx".utf8))
        var exceededEvent = LMStudioSSEDecoder(maximumLineBytes: 8, maximumEventBytes: 3,
            maximumTotalBytes: 64)
        XCTAssertThrowsError(try exceededEvent.feed(Data("data: xx\ndata: x\n\n".utf8))) { error in
            XCTAssertEqual(error as? LMStudioProviderError, .limitExceeded("SSE event"))
        }
        let event = Data("data: x\n\n".utf8)
        var total = LMStudioSSEDecoder(maximumLineBytes: 64, maximumEventBytes: 64,
            maximumTotalBytes: event.count)
        XCTAssertEqual(try total.feed(event).count, 1)
        XCTAssertThrowsError(try total.feed(Data("\n".utf8))) { error in
            XCTAssertEqual(error as? LMStudioProviderError, .limitExceeded("total streaming response"))
        }
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
        XCTAssertEqual(
            LMStudioProviderSignalClassifier.classify(
                #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}"#
            ),
            .responseTruncated
        )
    }

    func testStructuredProviderSignalsIgnoreConfigurationAndQuotedOutput() throws {
        let unrelatedBodies = [
            #"{"status":"incomplete","max_output_tokens":512,"incomplete_details":{"reason":"content_filter"}}"#,
            #"{"status":"failed","max_output_tokens":512,"error":{"code":"invalid_request","message":"Request rejected"}}"#,
            #"{"status":"failed","error":{"code":"invalid_request","message":"Request rejected"},"output":[{"type":"message","content":[{"type":"output_text","text":"This example discusses context overflow and truncated output."}]}]}"#,
        ]
        for body in unrelatedBodies {
            XCTAssertNil(LMStudioProviderSignalClassifier.classify(body),
                "Configuration and response content are not authoritative failure reasons")
            XCTAssertNil(LMStudioProviderSignalClassifier.classify(Data(body.utf8)))
        }
        XCTAssertEqual(LMStudioProviderSignalClassifier.classify(
            #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","content":[{"type":"output_text","text":"This example discusses context overflow."}]}]}"#
        ), .responseTruncated, "An explicit incomplete reason owns classification")
        XCTAssertEqual(LMStudioProviderSignalClassifier.classify(
            #"{"status":"failed","max_output_tokens":512,"error":{"code":"context_length_exceeded","message":"Context exhausted"}}"#
        ), .contextOverflow)

        // These supported plaintext errors are intentionally not JSON response bodies.
        for signal in ["context_length_exceeded", "context window exceeded",
                       "context limit exceeded", "maximum context length",
                       "context overflow", "too many tokens"] {
            XCTAssertEqual(LMStudioProviderSignalClassifier.classify(signal), .contextOverflow)
            XCTAssertEqual(LMStudioProviderSignalClassifier.classify(Data(signal.utf8)), .contextOverflow)
        }
        for signal in ["response_truncated", "response truncated", "truncation",
                       "truncated", "max_output_tokens"] {
            XCTAssertEqual(LMStudioProviderSignalClassifier.classify(signal), .responseTruncated)
            XCTAssertEqual(LMStudioProviderSignalClassifier.classify(Data(signal.utf8)), .responseTruncated)
        }
    }

    func testHTTPStatusAndRetryDelaySurviveUnrelatedConfigurationAndQuotedContent() throws {
        let cases: [(Int, String, LMStudioProviderError)] = [
            (401, "invalid_api_token", .unauthorized),
            (403, "permission_denied", .forbidden),
            (404, "model_not_found", .endpointNotFound),
            (409, "response_conflict", .conflict),
            (429, "rate_limit_exceeded", .rateLimited(retryNanoseconds: 2_000_000_000)),
            (500, "server_error", .serverFailure(status: 500)),
        ]
        for (status, code, expected) in cases {
            let metadataOnly = try JSONSerialization.data(withJSONObject: [
                "error": ["code": code, "message": "Deterministic fixture error"],
                "request": ["max_output_tokens": 512],
            ] as [String: Any])
            XCTAssertEqual(LMStudioHTTPErrorClassifier.classify(
                status: status, retryAfter: "2", body: metadataOnly), expected)
            let quotedContentOnly = try JSONSerialization.data(withJSONObject: [
                "error": ["code": code, "message": "Deterministic fixture error"],
                "output": [["type": "message", "content": [[
                    "type": "output_text", "text": "Quoted context overflow or truncated output."
                ]]]],
            ] as [String: Any])
            XCTAssertEqual(LMStudioHTTPErrorClassifier.classify(
                status: status, retryAfter: "2", body: quotedContentOnly), expected)
        }
        // Existing supported 400 payload and legacy plaintext behavior stay available.
        XCTAssertEqual(LMStudioHTTPErrorClassifier.classify(status: 400,
            body: Data(#"{"error":{"message":"maximum context length exceeded"}}"#.utf8)), .contextOverflow)
        XCTAssertEqual(LMStudioHTTPErrorClassifier.classify(status: 400,
            body: Data("response truncated".utf8)), .responseTruncated)
    }

    func testManagedSSEClassificationUsesFailureReasonAndStillRejectsIncompleteTurns() async throws {
        let transport = try makeTransport()
        let cases: [(String, LMStudioProviderError)] = [
            ("fixture-signal-incomplete-unknown", .malformedResponse(
                "provider response ended without a completed result")),
            ("fixture-signal-failed-unknown", .malformedResponse(
                "provider response ended without a completed result")),
            ("fixture-signal-completed-event-noncompleted", .malformedResponse(
                "stream ended without a completed response")),
            ("fixture-signal-truncation-reason", .responseTruncated),
            ("fixture-signal-overflow-reason", .contextOverflow),
        ]
        for (marker, expected) in cases {
            do {
                _ = try await transport.createRoot(LMStudioRootRequest(
                    systemPrompt: marker, userInput: "bounded fixture input", tools: [],
                    idempotencyKey: marker
                ))
                XCTFail("An incomplete provider turn must never be accepted")
            } catch {
                XCTAssertEqual(error as? LMStudioProviderError, expected, marker)
            }
            let rejectedReceipt = await transport.receipt(forIdempotencyKey: marker)
            XCTAssertNil(rejectedReceipt, "Classification must not admit a partial receipt")
        }
        let completed = try await transport.createRoot(LMStudioRootRequest(
            systemPrompt: "fixture-signal-completed-benign", userInput: "bounded fixture input",
            tools: [], idempotencyKey: "fixture-signal-completed-benign"
        ))
        XCTAssertEqual(completed.status, "completed")
        XCTAssertEqual(completed.assistantText, "Quoted context overflow or truncated output.")
        XCTAssertTrue(completed.functionCalls.isEmpty)
        let completedReceipt = await transport.receipt(forIdempotencyKey: "fixture-signal-completed-benign")
        XCTAssertEqual(completedReceipt?.responseID, completed.responseID)
    }

    func testProviderSignalStructuredShapesAndPlaintextFallbackBoundaries() {
        let cases: [(String, LMStudioProviderError?)] = [
            (#"{"error":{"type":"context_length_exceeded"}}"#, .contextOverflow),
            (#"{"error":{"code":"response_truncated","message":"Quoted context overflow"}}"#, .responseTruncated),
            (#"{"reason":"context overflow"}"#, nil),
            (#"{"code":"context_length_exceeded"}"#, nil),
            (#"{"type":"response_truncated"}"#, nil),
            (#"{"message":"context overflow"}"#, nil),
            (#"{"incomplete_details":{"reason":false},"error":{"code":["context_length_exceeded"],"message":512}}"#, nil),
            (#""context overflow""#, nil),
            (#"[{"error":{"code":"context_length_exceeded"}}]"#, nil),
            ("null", nil),
            (#"{"error":{"message":"context overflow""#, .contextOverflow),
            ("Maximum CONTEXT length exceeded.", .contextOverflow),
        ]
        for (body, expected) in cases {
            XCTAssertEqual(LMStudioProviderSignalClassifier.classify(body), expected)
            XCTAssertEqual(LMStudioProviderSignalClassifier.classify(Data(body.utf8)), expected)
        }
        XCTAssertNil(LMStudioProviderSignalClassifier.classify(Data()))
        XCTAssertNil(LMStudioProviderSignalClassifier.classify(Data([0xff, 0xfe])))
        let oversizedLegacy = "context overflow" + String(repeating: " ", count: 64 * 1_024)
        XCTAssertNil(LMStudioProviderSignalClassifier.classify(Data(oversizedLegacy.utf8)))
        XCTAssertEqual(LMStudioProviderSignalClassifier.classify(oversizedLegacy), .contextOverflow,
            "The direct String legacy overload remains unchanged outside the bounded Data call path")
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

    func testReasoningOnlyTerminalMetadataKeepsEmptyDerivedStopAndPersistsExactReceipt() async throws {
        let directory = try terminalMetadataDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = try LMStudioManagedModelProvider(storageDirectory: directory, transport: makeTransport())
        let request = try ProviderRootRequest(operationID: UUID(), idempotencyKey: "terminal-reasoning-owned",
            modelKey: "fixture/tool-model", input: "fixture-terminal-reasoning", tools: [])
        let turn = try await provider.createRoot(request)
        XCTAssertTrue(turn.completed)
        XCTAssertEqual(turn.finishReason, .stop, "This remains the existing derived managed signal")
        XCTAssertTrue(turn.messages.isEmpty)
        XCTAssertTrue(turn.toolCalls.isEmpty)
        let ledger = try terminalLedger(directory)
        let record = try XCTUnwrap((ledger["records"] as? [[String: Any]])?.first)
        let metadata = try XCTUnwrap(record["terminal_metadata"] as? [String: Any])
        XCTAssertEqual(record["request_id"] as? String, turn.requestID)
        XCTAssertEqual(metadata["responseID"] as? String, turn.responseID)
        XCTAssertEqual(metadata["status"] as? String, "completed")
        XCTAssertEqual(metadata["outputItemCount"] as? Int, 1)
        XCTAssertEqual(metadata["outputItemTypeCounts"] as? [String: Int], ["reasoning": 1])
        XCTAssertEqual(metadata["reasoningTokens"] as? Int, 4_095)
        XCTAssertEqual(metadata["outputTextBytes"] as? Int, 0)
        XCTAssertEqual(metadata["functionArgumentBytes"] as? Int, 0)
        XCTAssertEqual(metadata["parsedTextBytes"] as? Int, 0)
        XCTAssertEqual(metadata["parsedFunctionCallCount"] as? Int, 0)
        XCTAssertEqual(metadata["streamEOFObserved"] as? Bool, true)
        XCTAssertEqual(metadata["metadataComplete"] as? Bool, true)
        let diagnostic = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        XCTAssertLessThanOrEqual(diagnostic.count, 4_096)
        XCTAssertFalse(String(decoding: diagnostic, as: UTF8.self).contains("fixture-private-reasoning-content"))
        let restarted = try LMStudioManagedModelProvider(storageDirectory: directory, transport: makeTransport())
        let recovered = try await restarted.lookupRecorded(idempotencyKey: request.idempotencyKey)
        XCTAssertEqual(recovered, turn)
    }

    func testTerminalMetadataMeasuresActualTextAndFunctionArgumentBytes() async throws {
        let transport = try makeTransport()
        for kind in ["text", "tool"] {
            let turn = try await transport.createRoot(LMStudioRootRequest(
                systemPrompt: "fixture-terminal-" + kind, userInput: "bounded input", tools: [],
                idempotencyKey: "terminal-metadata-" + kind))
            let metadata = try XCTUnwrap(turn.terminalMetadata)
            XCTAssertEqual(metadata.responseID, turn.responseID)
            XCTAssertEqual(metadata.status, "completed")
            XCTAssertTrue(metadata.streamEOFObserved)
            XCTAssertTrue(metadata.metadataComplete)
            XCTAssertEqual(metadata.outputItemCount, 1)
            XCTAssertNil(metadata.reasoningTokens, "Absent reasoning usage must remain unknown")
            if kind == "text" {
                XCTAssertEqual(turn.assistantText, "Observed café ✓.")
                XCTAssertEqual(metadata.outputItemTypeCounts, ["message": 1])
                XCTAssertEqual(metadata.outputTextBytes, turn.assistantText.utf8.count)
                XCTAssertEqual(metadata.streamedTextBytes, 0, "This fixture exercises completed-message fallback")
                XCTAssertEqual(metadata.parsedTextBytes, turn.assistantText.utf8.count)
                XCTAssertEqual(metadata.functionArgumentBytes, 0)
                XCTAssertTrue(turn.functionCalls.isEmpty)
            } else {
                let call = try XCTUnwrap(turn.functionCalls.first)
                XCTAssertEqual(turn.functionCalls.count, 1)
                XCTAssertEqual(metadata.outputItemTypeCounts, ["function_call": 1])
                XCTAssertEqual(metadata.functionArgumentBytes, call.arguments.utf8.count)
                XCTAssertEqual(metadata.outputTextBytes, 0)
                XCTAssertEqual(metadata.parsedFunctionCallCount, 1)
            }
        }
    }

    func testLegacyReceiptAbsentOrNullTerminalMetadataRemainsUnknownAndReplayable() async throws {
        let directory = try terminalMetadataDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try ProviderRootRequest(operationID: UUID(), idempotencyKey: "terminal-legacy-owned",
            modelKey: "fixture/tool-model", input: "fixture-terminal-reasoning", tools: [])
        let first = try LMStudioManagedModelProvider(storageDirectory: directory, transport: makeTransport())
        let turn = try await first.createRoot(request)
        for explicitNull in [false, true] {
            var ledger = try terminalLedger(directory)
            var records = try XCTUnwrap(ledger["records"] as? [[String: Any]])
            XCTAssertEqual(records.count, 1)
            if explicitNull { records[0]["terminal_metadata"] = NSNull() }
            else { records[0].removeValue(forKey: "terminal_metadata") }
            ledger["records"] = records
            try OwnerOnlyAtomicFile.write(try JSONSerialization.data(withJSONObject: ledger),
                to: directory.appendingPathComponent("managed-provider-receipts.json"))
            let restarted = try LMStudioManagedModelProvider(storageDirectory: directory, transport: makeTransport())
            let replay = try await restarted.lookupRecorded(idempotencyKey: request.idempotencyKey)
            XCTAssertEqual(replay, turn)
            let retained = try XCTUnwrap((terminalLedger(directory)["records"] as? [[String: Any]])?.first)
            XCTAssertTrue(retained["terminal_metadata"] == nil || retained["terminal_metadata"] is NSNull)
        }
    }

    func testTerminalMetadataCannotAcceptIncompleteOrLostTransportEOF() async throws {
        for (kind, expected) in [("incomplete", LMStudioProviderError.responseTruncated),
                                 ("lost-eof", LMStudioProviderError.providerUnavailable)] {
            let directory = try terminalMetadataDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let provider = try LMStudioManagedModelProvider(storageDirectory: directory, transport: makeTransport())
            let request = try ProviderRootRequest(operationID: UUID(), idempotencyKey: "terminal-" + kind,
                modelKey: "fixture/tool-model", input: "fixture-terminal-" + kind, tools: [])
            do {
                _ = try await provider.createRoot(request)
                XCTFail("A terminal frame alone cannot create an accepted receipt without completed transport")
            } catch { XCTAssertEqual(error as? LMStudioProviderError, expected) }
            let record = try XCTUnwrap((terminalLedger(directory)["records"] as? [[String: Any]])?.first)
            XCTAssertEqual(record["status"] as? String, "intent")
            XCTAssertTrue(record["turn"] == nil || record["turn"] is NSNull)
            XCTAssertTrue(record["terminal_metadata"] == nil || record["terminal_metadata"] is NSNull)
        }
    }

    func testTerminalMetadataCannotBeReboundToAnotherResponse() async throws {
        let directory = try terminalMetadataDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = try LMStudioManagedModelProvider(storageDirectory: directory, transport: makeTransport())
        _ = try await provider.createRoot(try ProviderRootRequest(operationID: UUID(),
            idempotencyKey: "terminal-metadata-response-identity", modelKey: "fixture/tool-model",
            input: "fixture-terminal-reasoning", tools: []))
        var ledger = try terminalLedger(directory)
        var records = try XCTUnwrap(ledger["records"] as? [[String: Any]])
        var metadata = try XCTUnwrap(records[0]["terminal_metadata"] as? [String: Any])
        metadata["responseID"] = "resp_another_owned_response"
        records[0]["terminal_metadata"] = metadata; ledger["records"] = records
        try OwnerOnlyAtomicFile.write(try JSONSerialization.data(withJSONObject: ledger),
            to: directory.appendingPathComponent("managed-provider-receipts.json"))
        XCTAssertThrowsError(try LMStudioManagedModelProvider(storageDirectory: directory, transport: makeTransport())) {
            XCTAssertEqual($0 as? LMStudioProviderError,
                .receiptStorage("terminal metadata does not match its bounded accepted response"))
        }
    }

    func testFractionalReasoningMetadataRemainsUnknownWithoutChangingCompletion() async throws {
        let turn = try await makeTransport().createRoot(LMStudioRootRequest(
            systemPrompt: "fixture-terminal-fractional-reasoning", userInput: "bounded input", tools: [],
            idempotencyKey: "terminal-fractional-reasoning"))
        let metadata = try XCTUnwrap(turn.terminalMetadata)
        XCTAssertEqual(turn.status, "completed")
        XCTAssertTrue(turn.assistantText.isEmpty)
        XCTAssertTrue(turn.functionCalls.isEmpty)
        XCTAssertNil(metadata.reasoningTokens, "The original decimal token must not round into a diagnostic integer")
        XCTAssertFalse(metadata.metadataComplete)
        XCTAssertTrue(metadata.streamEOFObserved)
    }

    func testMalformedOptionalTerminalContainersRemainUnknownWithoutChangingCompletion() async throws {
        let transport = try makeTransport()
        for kind in ["malformed-incomplete-string", "malformed-incomplete-array",
                     "malformed-usage-string", "malformed-usage-array", "null-containers"] {
            let turn = try await transport.createRoot(LMStudioRootRequest(
                systemPrompt: "fixture-terminal-" + kind, userInput: "bounded input", tools: [],
                idempotencyKey: "terminal-container-" + kind))
            let metadata = try XCTUnwrap(turn.terminalMetadata)
            XCTAssertEqual(turn.status, "completed")
            XCTAssertEqual(turn.usage.outputTokens, 4_095)
            XCTAssertTrue(turn.assistantText.isEmpty)
            XCTAssertTrue(turn.functionCalls.isEmpty)
            XCTAssertEqual(metadata.responseID, turn.responseID)
            XCTAssertTrue(metadata.streamEOFObserved)
            XCTAssertEqual(metadata.outputItemCount, 1)
            XCTAssertEqual(metadata.outputItemTypeCounts, ["reasoning": 1])
            XCTAssertNil(metadata.incompleteReason)
            XCTAssertNil(metadata.reasoningTokens)
            if kind == "null-containers" {
                XCTAssertTrue(metadata.metadataComplete, "Explicit null optional containers stay absent and unknown")
                XCTAssertEqual(metadata.outputTextBytes, 0)
                XCTAssertEqual(metadata.functionArgumentBytes, 0)
            } else {
                XCTAssertFalse(metadata.metadataComplete, "A present unsupported optional container cannot claim complete metadata")
                XCTAssertNil(metadata.outputTextBytes)
                XCTAssertNil(metadata.functionArgumentBytes)
            }
        }
    }

    private func terminalMetadataDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-terminal-metadata-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func terminalLedger(_ directory: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: OwnerOnlyAtomicFile.read(
            from: directory.appendingPathComponent("managed-provider-receipts.json"), maximumBytes: 64 * 1_024)) as? [String: Any])
    }

    private func makeTransport(
        connectTimeoutSeconds: Double = 1,
        firstByteTimeoutSeconds: Double = 1,
        idleTimeoutSeconds: Double = 1,
        totalTimeoutSeconds: Double = 2,
        maximumSSELineBytes: Int = 64 * 1024,
        maximumOutputTokens: Int = 4_096,
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
            maximumToolArgumentBytes: 256 * 1024,
            maximumOutputTokens: maximumOutputTokens
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

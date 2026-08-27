// ManagedModelProviderBridgeTests.swift
// Verifies provider-factory registration and normalized LM Studio turn conversion.

import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

#if SWIFT_PACKAGE
private actor ScriptedProviderBridgeTransport: LMStudioManagedTransporting {
    enum Mode: Sendable {
        case completed
        case incomplete
    }

    struct Snapshot: Sendable {
        var rootRequest: LMStudioRootRequest?
        var continuationRequest: LMStudioContinuationRequest?
        var cancellations: [String]
    }

    private let mode: Mode
    private var rootRequest: LMStudioRootRequest?
    private var continuationRequest: LMStudioContinuationRequest?
    private var receipts: [String: LMStudioResponseTurn] = [:]
    private var cancellations: [String] = []

    init(mode: Mode = .completed) {
        self.mode = mode
    }

    func probe() async throws -> LMStudioProviderCapabilities {
        LMStudioProviderCapabilities(
            providerVersion: "0.3.fixture",
            modelKey: "fixture/tool-model",
            loadedInstanceID: "fixture/tool-model@32768",
            contextLength: 32_768,
            maximumContextLength: 131_072,
            parallelism: 1,
            flashAttention: true,
            trainedForToolUse: true,
            streamingVerified: true,
            functionToolContractVerified: true,
            usageReportingVerified: true,
            capabilityFingerprintSHA256: String(repeating: "b", count: 64),
            contractProbeResponseID: "resp_provider_probe"
        )
    }

    func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn {
        rootRequest = request
        let turn = LMStudioResponseTurn(
            responseID: "resp_provider_root",
            previousResponseID: nil,
            model: request.modelKey ?? "fixture/tool-model",
            status: mode == .completed ? "completed" : "incomplete",
            assistantText: "Visible assistant response.",
            functionCalls: [LMStudioFunctionCall(
                itemID: "item_provider_tool",
                callID: "call_provider_tool",
                name: "fixture_lookup",
                arguments: #"{"query":"bounded"}"#
            )],
            usage: LMStudioUsage(inputTokens: 120, outputTokens: 18, totalTokens: 138)
        )
        receipts[request.idempotencyKey] = turn
        return turn
    }

    func continueSession(
        _ request: LMStudioContinuationRequest
    ) async throws -> LMStudioResponseTurn {
        continuationRequest = request
        let turn = LMStudioResponseTurn(
            responseID: "resp_provider_continuation",
            previousResponseID: request.previousResponseID,
            model: request.modelKey ?? "fixture/tool-model",
            status: mode == .completed ? "completed" : "incomplete",
            assistantText: "Continuation complete.",
            functionCalls: [],
            usage: LMStudioUsage(inputTokens: 152, outputTokens: 11, totalTokens: 163)
        )
        receipts[request.idempotencyKey] = turn
        return turn
    }

    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? {
        receipts[key]
    }

    func cancel(operationID: String) async {
        cancellations.append(operationID)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            rootRequest: rootRequest,
            continuationRequest: continuationRequest,
            cancellations: cancellations
        )
    }
}

final class ManagedModelProviderBridgeTests: XCTestCase {
    func testPluginRegistrationResolvesDistinctAdapterAndManagedProviderFactories() throws {
        let root = providerBridgeTemporaryRoot("registry")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = HostAdapterRegistry()
        let configuration = LMStudioProviderConfiguration(
            baseURL: URL(string: "https://lmstudio.fixture")!,
            modelKey: "fixture/tool-model"
        )
        ForgeNativeSessionHostPlugin.register(
            in: registry,
            configurationSource: { _ in configuration },
            authorizationSource: { _, _ in LMStudioNoAuthorization() }
        )

        let adapter = try registry.adapter(
            identifier: ForgeNativeSessionHostPlugin.identifier,
            storageDirectory: root
        )
        let resolved = try registry.managedProvider(
            identifier: ForgeNativeSessionHostPlugin.identifier,
            storageDirectory: root
        )
        let provider = try XCTUnwrap(resolved)
        XCTAssertEqual(adapter.identifier, "forge.native-session-host")
        XCTAssertEqual(provider.providerID, "lmstudio")
        XCTAssertNotEqual(adapter.identifier, provider.providerID)
        XCTAssertTrue(adapter is LMStudioManagedSessionHostAdapter)
        XCTAssertTrue(provider is LMStudioManagedModelProvider)

        let legacyRegistry = HostAdapterRegistry()
        legacyRegistry.register(manifest: ForgeNativeSessionHostPlugin.manifest) { _ in
            throw ContinuityRunError.hostCapabilityUnavailable
        }
        let absentProvider = try legacyRegistry.managedProvider(
            identifier: ForgeNativeSessionHostPlugin.identifier,
            storageDirectory: root
        )
        XCTAssertNil(absentProvider)
    }

    func testRootTurnConversionPreservesVisibleOutputToolsUsageAndLookup() async throws {
        let transport = ScriptedProviderBridgeTransport()
        let provider = LMStudioManagedModelProvider(transport: transport)
        let tool = try providerBridgeToolDefinition()
        let operationID = UUID()
        let request = try ProviderRootRequest(
            operationID: operationID,
            idempotencyKey: "provider-root-idempotency",
            modelKey: "fixture/tool-model",
            input: "Perform one bounded fixture lookup.",
            tools: [tool]
        )

        let capabilities = try await provider.probe()
        XCTAssertEqual(capabilities.providerID, "lmstudio")
        XCTAssertEqual(capabilities.providerVersion, "0.3.fixture")
        XCTAssertEqual(capabilities.modelKey, "fixture/tool-model")
        XCTAssertEqual(capabilities.providerInstanceID, "fixture/tool-model@32768")
        XCTAssertEqual(capabilities.contextLength, 32_768)
        XCTAssertTrue(capabilities.statefulResponses)
        XCTAssertTrue(capabilities.streaming)
        XCTAssertTrue(capabilities.customTools)
        XCTAssertFalse(capabilities.mcp)
        XCTAssertFalse(capabilities.structuredOutput)
        XCTAssertTrue(capabilities.usageReporting)
        XCTAssertTrue(capabilities.idempotencyLookup)

        let turn = try await provider.createRoot(request)
        XCTAssertEqual(turn.requestID, operationID.uuidString.lowercased())
        XCTAssertEqual(turn.responseID, "resp_provider_root")
        XCTAssertNil(turn.previousResponseID)
        XCTAssertEqual(turn.providerID, "lmstudio")
        XCTAssertEqual(turn.providerVersion, "0.3.fixture")
        XCTAssertEqual(turn.modelKey, "fixture/tool-model")
        XCTAssertEqual(turn.providerInstanceID, "fixture/tool-model@32768")
        XCTAssertEqual(turn.messages, ["Visible assistant response."])
        XCTAssertTrue(turn.completed)
        XCTAssertEqual(turn.finishReason, .toolCalls)
        XCTAssertNil(turn.structuredOutputJSON)
        XCTAssertNil(turn.rawArtifactID)
        XCTAssertEqual(turn.toolCalls.count, 1)
        XCTAssertEqual(turn.toolCalls[0].itemID, "item_provider_tool")
        XCTAssertEqual(turn.toolCalls[0].callID, "call_provider_tool")
        XCTAssertEqual(turn.toolCalls[0].name, "fixture_lookup")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: turn.toolCalls[0].argumentsJSON) as? [String: String],
            ["query": "bounded"]
        )
        XCTAssertEqual(turn.usage?.capacity, 32_768)
        XCTAssertEqual(turn.usage?.inputTokens, 120)
        XCTAssertEqual(turn.usage?.outputTokens, 18)
        XCTAssertEqual(turn.usage?.totalTokens, 138)
        XCTAssertEqual(turn.usage?.source, .providerExact)
        XCTAssertEqual(turn.usage?.confidence, 1)

        let snapshot = await transport.snapshot()
        let mappedRoot = try XCTUnwrap(snapshot.rootRequest)
        XCTAssertEqual(mappedRoot.operationID, operationID.uuidString.lowercased())
        XCTAssertEqual(mappedRoot.providerRequestID, operationID.uuidString.lowercased())
        XCTAssertEqual(mappedRoot.modelKey, "fixture/tool-model")
        XCTAssertEqual(mappedRoot.systemPrompt, "")
        XCTAssertEqual(mappedRoot.userInput, request.input)
        XCTAssertEqual(mappedRoot.tools.count, 1)
        XCTAssertEqual(mappedRoot.tools[0].name, "fixture_lookup")

        let lookedUp = try await provider.lookup(idempotencyKey: request.idempotencyKey)
        XCTAssertEqual(lookedUp, turn)
        let missing = try await provider.lookup(idempotencyKey: "provider-root-missing")
        XCTAssertNil(missing)

        await provider.cancel(requestID: turn.requestID)
        let cancellationSnapshot = await transport.snapshot()
        XCTAssertEqual(cancellationSnapshot.cancellations, [turn.requestID])
    }

    func testContinuationMapsMessagesAndFunctionOutputsToStatefulResponse() async throws {
        let transport = ScriptedProviderBridgeTransport()
        let provider = LMStudioManagedModelProvider(transport: transport)
        let operationID = UUID()
        let input = try JSONSerialization.data(withJSONObject: [
            [
                "type": "function_call_output",
                "call_id": "call_provider_tool",
                "output": #"{"result":"ready"}"#,
            ],
            [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "Continue visibly."]],
            ],
        ], options: [.sortedKeys])
        let request = try ProviderContinuationRequest(
            operationID: operationID,
            idempotencyKey: "provider-continuation-idempotency",
            modelKey: "fixture/tool-model",
            previousResponseID: "resp_provider_root",
            input: input,
            tools: [try providerBridgeToolDefinition()]
        )

        let turn = try await provider.continueSession(request)
        XCTAssertEqual(turn.requestID, operationID.uuidString.lowercased())
        XCTAssertEqual(turn.responseID, "resp_provider_continuation")
        XCTAssertEqual(turn.previousResponseID, "resp_provider_root")
        XCTAssertEqual(turn.messages, ["Continuation complete."])
        XCTAssertTrue(turn.toolCalls.isEmpty)
        XCTAssertEqual(turn.finishReason, .stop)
        XCTAssertEqual(turn.usage?.source, .providerExact)

        let snapshot = await transport.snapshot()
        let mapped = try XCTUnwrap(snapshot.continuationRequest)
        XCTAssertEqual(mapped.operationID, operationID.uuidString.lowercased())
        XCTAssertEqual(mapped.previousResponseID, "resp_provider_root")
        XCTAssertEqual(mapped.input.count, 2)
        guard case .functionCallOutput(let callID, let output) = mapped.input[0] else {
            return XCTFail("first continuation item must be a function result")
        }
        XCTAssertEqual(callID, "call_provider_tool")
        XCTAssertEqual(output, #"{"result":"ready"}"#)
        guard case .message(let role, let text) = mapped.input[1] else {
            return XCTFail("second continuation item must be a message")
        }
        XCTAssertEqual(role, "user")
        XCTAssertEqual(text, "Continue visibly.")
    }

    func testBridgeRejectsIncompleteTerminalResponseAndUnsupportedStructuredOutput() async throws {
        let incompleteTransport = ScriptedProviderBridgeTransport(mode: .incomplete)
        let incompleteProvider = LMStudioManagedModelProvider(transport: incompleteTransport)
        let incompleteRequest = try ProviderRootRequest(
            operationID: UUID(),
            idempotencyKey: "provider-incomplete",
            modelKey: "fixture/tool-model",
            input: "Return a complete response.",
            tools: []
        )
        do {
            _ = try await incompleteProvider.createRoot(incompleteRequest)
            XCTFail("an incomplete provider response must not cross the bridge")
        } catch {
            XCTAssertEqual(
                error as? ManagedModelProviderContractError,
                .incompleteTerminalResponse
            )
        }

        let provider = LMStudioManagedModelProvider(
            transport: ScriptedProviderBridgeTransport()
        )
        let schema = try JSONSerialization.data(withJSONObject: [
            "type": "object",
            "additionalProperties": false,
        ], options: [.sortedKeys])
        let structuredRequest = try ProviderRootRequest(
            operationID: UUID(),
            idempotencyKey: "provider-structured-output",
            modelKey: "fixture/tool-model",
            input: "Use structured output.",
            tools: [],
            structuredOutputSchema: schema
        )
        do {
            _ = try await provider.createRoot(structuredRequest)
            XCTFail("unsupported structured response format must fail closed")
        } catch {
            guard case .unsupportedCapability = error as? ManagedModelProviderContractError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}

private func providerBridgeToolDefinition() throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "type": "function",
        "name": "fixture_lookup",
        "description": "Look up one fixture value.",
        "strict": true,
        "parameters": [
            "type": "object",
            "additionalProperties": false,
            "properties": ["query": ["type": "string"]],
            "required": ["query"],
        ],
    ], options: [.sortedKeys])
}

private func providerBridgeTemporaryRoot(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "forge-provider-bridge-\(name)-\(UUID().uuidString)",
        isDirectory: true
    )
}
#endif

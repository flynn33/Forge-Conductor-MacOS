// Native adapter protocol tests with an injected manager executor and transport.
// Repository/broker authority and activation are tested by their integration suites.

import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class SourceBootstrapHostAdapterTests: XCTestCase {
    func testExactRetrievalPrecedesAcknowledgementAndRootContainsOnlyCompactIdentity() async throws {
        let fixture = try SourceHostFixture()
        defer { fixture.remove() }
        let trace = SourceHostTrace()
        let transport = SourceHostTransport(trace: trace)
        let executor = SourceHostExecutor(fixture: fixture, trace: trace)
        let adapter = try LMStudioManagedSessionHostAdapterV2(storageDirectory: fixture.providerDirectory, transport: transport)
        let receipt = try await adapter.createSourceAndBootstrap(request: fixture.request, executor: executor)
        let stats = await transport.stats()
        let events = await trace.events
        XCTAssertEqual(events, ["prepare-root", "provider-root", "retrieve", "prepare-ack", "provider-ack", "record-ack"])
        XCTAssertEqual(stats.roots.count, 1)
        XCTAssertEqual(stats.continuations.count, 1)
        let root = try XCTUnwrap(stats.roots.first)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(root.userInput.utf8)) as? [String: Any])
        XCTAssertEqual(envelope["schema_version"] as? String, "3.0")
        XCTAssertEqual(envelope["acknowledgement_contract_version"] as? Int, 2)
        let challenge = try XCTUnwrap(envelope["expected_acknowledgement"] as? [String: Any])
        let expected = try JSONDecoder().decode(BootstrapAcknowledgementV2.self,
            from: ForgeJSONCanonicalizationV1.data(from: challenge))
        XCTAssertEqual(expected, receipt.bootstrap.acknowledgement)
        XCTAssertEqual(root.tools.map(\.name), ["context_get"])
        XCTAssertFalse(root.userInput.contains(fixture.packetGoal))
        XCTAssertFalse(root.userInput.contains("\"packet\":"))
        XCTAssertFalse(root.userInput.contains("predecessor"))
        XCTAssertEqual(receipt.bootstrap.acknowledgement.handoffID, fixture.request.handoffID)
        XCTAssertEqual(receipt.bootstrap.acknowledgement.handoffSHA256, fixture.request.handoffSHA256)
        XCTAssertEqual(receipt.retrieval.sourceIdentity.continuityID, "non-uuid-source-id")
        XCTAssertEqual(receipt.bootstrap.internalSessionID, fixture.request.sessionID)
        XCTAssertEqual(receipt.bootstrap.providerResponseID, "source-ack-response")
        XCTAssertEqual(receipt.bootstrap.usage?.source, "provider_exact")
        XCTAssertEqual(receipt.bootstrap.usage?.used, 780, "Retained input plus output must not be replaced by the aggregate diagnostic counter")
        let continuation = try XCTUnwrap(stats.continuations.first)
        XCTAssertEqual(continuation.previousResponseID, receipt.rootTurn.responseID)
        XCTAssertEqual(continuation.tools.map(\.name), ["forge_continuity_ack"])
        XCTAssertEqual(continuation.input, [.functionCallOutput(callID: "source-context-call",
            output: String(decoding: receipt.retrieval.outputJSON, as: UTF8.self))])
        XCTAssertTrue(String(decoding: receipt.retrieval.outputJSON, as: UTF8.self).contains("https://example.invalid/path"))
        let prepared = await executor.prepared
        XCTAssertEqual(prepared.count, 2)
        XCTAssertEqual(prepared[0].inputSHA256, JSONSupport.sha256Hex(Data(root.userInput.utf8)))
        XCTAssertEqual(prepared[0].operationID, fixture.request.operationID)
        XCTAssertNotEqual(prepared[0].turnID, prepared[1].turnID)
        let costs = await executor.costs
        XCTAssertEqual(costs[0], costs[1])
        XCTAssertGreaterThan(costs[0], fixture.request.continuationInputBytes + root.userInput.utf8.count)
    }

    func testWrongSourceEarlyAckExtraToolAndMissingUsageNeverReachRetrievalOrContinuation() async throws {
        for mode in [SourceHostTransport.Mode.wrongSource, .prematureACK, .extraTool, .missingUsage] {
            let fixture = try SourceHostFixture()
            defer { fixture.remove() }
            let trace = SourceHostTrace()
            let transport = SourceHostTransport(trace: trace, mode: mode)
            let executor = SourceHostExecutor(fixture: fixture, trace: trace)
            let adapter = try LMStudioManagedSessionHostAdapterV2(storageDirectory: fixture.providerDirectory, transport: transport)
            do {
                _ = try await adapter.createSourceAndBootstrap(request: fixture.request, executor: executor)
                XCTFail("Accepted invalid root: \(mode)")
            } catch {}
            let events = await trace.events
            let stats = await transport.stats()
            XCTAssertFalse(events.contains("retrieve"), "\(mode)")
            XCTAssertEqual(stats.continuations.count, 0, "\(mode)")
            XCTAssertFalse(events.contains("record-ack"), "\(mode)")
        }
    }

    func testRetrievalFailureOrDifferentProviderProofPreventsAckDispatch() async throws {
        for mode in [SourceHostExecutor.Mode.failRead, .wrongProviderProof] {
            let fixture = try SourceHostFixture()
            defer { fixture.remove() }
            let trace = SourceHostTrace()
            let transport = SourceHostTransport(trace: trace)
            let executor = SourceHostExecutor(fixture: fixture, trace: trace, mode: mode)
            let adapter = try LMStudioManagedSessionHostAdapterV2(storageDirectory: fixture.providerDirectory, transport: transport)
            do {
                _ = try await adapter.createSourceAndBootstrap(request: fixture.request, executor: executor)
                XCTFail("Accepted failed or mismatched retrieval")
            } catch {}
            let stats = await transport.stats()
            XCTAssertEqual(stats.roots.count, 1)
            XCTAssertEqual(stats.continuations.count, 0)
        }
    }

    func testManagerBudgetRejectionAndOutputByteLimitPreventRootCreation() async throws {
        let fixture = try SourceHostFixture()
        defer { fixture.remove() }
        let trace = SourceHostTrace()
        let transport = SourceHostTransport(trace: trace)
        let executor = SourceHostExecutor(fixture: fixture, trace: trace, mode: .rejectBudget)
        let adapter = try LMStudioManagedSessionHostAdapterV2(storageDirectory: fixture.providerDirectory, transport: transport)
        do {
            _ = try await adapter.createSourceAndBootstrap(request: fixture.request, executor: executor)
            XCTFail("Created root without manager budget admission")
        } catch {}
        let stats = await transport.stats()
        XCTAssertEqual(stats.roots.count, 0)
        XCTAssertEqual(stats.continuations.count, 0)
        XCTAssertThrowsError(try SourceHostFixture(maximumOutputBytes: 64)) { error in
            guard case ContinuityIngressError.capacityExceeded = error else {
                return XCTFail("Unexpected output preflight error: \(error)")
            }
        }
    }

    func testAdapterRestartReplaysBothNativeReceiptsWithoutCreatingAnotherRootOrAck() async throws {
        let fixture = try SourceHostFixture()
        defer { fixture.remove() }
        let trace = SourceHostTrace()
        let firstTransport = SourceHostTransport(trace: trace)
        let first = try LMStudioManagedSessionHostAdapterV2(storageDirectory: fixture.providerDirectory, transport: firstTransport)
        let receipt = try await first.createSourceAndBootstrap(request: fixture.request,
            executor: SourceHostExecutor(fixture: fixture, trace: trace))
        let restartedTransport = SourceHostTransport(trace: SourceHostTrace())
        let restarted = try LMStudioManagedSessionHostAdapterV2(storageDirectory: fixture.providerDirectory, transport: restartedTransport)
        // A new executor returns no completed turns, exercising the on-disk
        // native request ledger rather than an in-memory transport cache.
        let replay = try await restarted.createSourceAndBootstrap(request: fixture.request,
            executor: SourceHostExecutor(fixture: fixture, trace: SourceHostTrace()))
        let stats = await restartedTransport.stats()
        XCTAssertEqual(stats.roots.count, 0)
        XCTAssertEqual(stats.continuations.count, 0)
        XCTAssertEqual(receipt.rootTurn, replay.rootTurn)
        XCTAssertEqual(receipt.acknowledgementTurn, replay.acknowledgementTurn)
        XCTAssertEqual(receipt.retrieval.outputJSON, replay.retrieval.outputJSON)
    }

    func testUnknownRootOutcomeRetainsExistingNativeFenceAcrossRestart() async throws {
        let fixture = try SourceHostFixture()
        defer { fixture.remove() }
        let firstTransport = SourceHostTransport(trace: SourceHostTrace(), mode: .unknownRoot)
        let first = try LMStudioManagedSessionHostAdapterV2(storageDirectory: fixture.providerDirectory, transport: firstTransport)
        do {
            _ = try await first.createSourceAndBootstrap(request: fixture.request,
                executor: SourceHostExecutor(fixture: fixture, trace: SourceHostTrace()))
            XCTFail("Unknown provider outcome succeeded")
        } catch {}
        let restartedTransport = SourceHostTransport(trace: SourceHostTrace())
        let restarted = try LMStudioManagedSessionHostAdapterV2(storageDirectory: fixture.providerDirectory, transport: restartedTransport)
        do {
            _ = try await restarted.createSourceAndBootstrap(request: fixture.request,
                executor: SourceHostExecutor(fixture: fixture, trace: SourceHostTrace()))
            XCTFail("Unknown native intent was resubmitted immediately")
        } catch {}
        let firstStats = await firstTransport.stats()
        let stats = await restartedTransport.stats()
        XCTAssertEqual(firstStats.roots.count, 1)
        XCTAssertEqual(stats.roots.count, 0)
        XCTAssertEqual(stats.continuations.count, 0)
    }

    func testTypedAckWithDifferentNonceIsNeverRecordedAsAccepted() async throws {
        let fixture = try SourceHostFixture()
        defer { fixture.remove() }
        let trace = SourceHostTrace()
        let transport = SourceHostTransport(trace: trace, mode: .wrongAckNonce)
        let adapter = try LMStudioManagedSessionHostAdapterV2(storageDirectory: fixture.providerDirectory, transport: transport)
        do {
            _ = try await adapter.createSourceAndBootstrap(request: fixture.request,
                executor: SourceHostExecutor(fixture: fixture, trace: trace))
            XCTFail("Accepted wrong acknowledgement nonce")
        } catch {}
        let events = await trace.events
        XCTAssertTrue(events.contains("retrieve"))
        XCTAssertTrue(events.contains("provider-ack"))
        XCTAssertFalse(events.contains("record-ack"))
    }

    func testChallengeDoesNotReplaceMissingProviderAcknowledgementFields() async throws {
        let fixture = try SourceHostFixture()
        defer { fixture.remove() }
        let trace = SourceHostTrace()
        let adapter = try LMStudioManagedSessionHostAdapterV2(storageDirectory: fixture.providerDirectory,
            transport: SourceHostTransport(trace: trace, mode: .missingAckFields))
        do {
            _ = try await adapter.createSourceAndBootstrap(request: fixture.request,
                executor: SourceHostExecutor(fixture: fixture, trace: trace))
            XCTFail("Filled missing provider acknowledgment fields from the challenge")
        } catch {}
        let events = await trace.events
        XCTAssertTrue(events.contains("provider-ack"))
        XCTAssertFalse(events.contains("record-ack"))
    }

    func testCorrectedSecondAcknowledgementDoesNotAuthorizeDuplicateCalls() async throws {
        let fixture = try SourceHostFixture()
        defer { fixture.remove() }
        let trace = SourceHostTrace()
        let transport = SourceHostTransport(trace: trace, mode: .duplicateCorrectedAck)
        let adapter = try LMStudioManagedSessionHostAdapterV2(storageDirectory: fixture.providerDirectory, transport: transport)
        do {
            _ = try await adapter.createSourceAndBootstrap(request: fixture.request,
                executor: SourceHostExecutor(fixture: fixture, trace: trace))
            XCTFail("Accepted two acknowledgements after the provider corrected its version")
        } catch {}
        let events = await trace.events
        XCTAssertTrue(events.contains("provider-ack"))
        XCTAssertFalse(events.contains("record-ack"))
    }

    func testExplicitCancellationStopsOwnedRootBeforeRetrieval() async throws {
        let fixture = try SourceHostFixture()
        defer { fixture.remove() }
        let trace = SourceHostTrace()
        let transport = SourceHostTransport(trace: trace, mode: .delayedRoot)
        let adapter = try LMStudioManagedSessionHostAdapterV2(storageDirectory: fixture.providerDirectory, transport: transport)
        let task = Task {
            try await adapter.createSourceAndBootstrap(request: fixture.request,
                executor: SourceHostExecutor(fixture: fixture, trace: trace))
        }
        for _ in 0..<500 {
            if await transport.stats().roots.count == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await transport.stats()
        XCTAssertEqual(started.roots.count, 1)
        await adapter.cancel(operationID: fixture.request.operationID)
        do { _ = try await task.value; XCTFail("Cancelled owner completed bootstrap") } catch {}
        let events = await trace.events
        let cancelled = await transport.cancelledIDs
        XCTAssertFalse(events.contains("retrieve"))
        XCTAssertFalse(events.contains("provider-ack"))
        XCTAssertTrue(cancelled.contains(try XCTUnwrap(started.roots.first?.operationID)))
    }
}

private struct SourceHostFixture: Sendable {
    let directory: URL
    let sourceURL: URL
    let providerDirectory: URL
    let request: SourceBootstrapRequest
    let grant: ContinuityBootstrapGrant
    let packetGoal = "Untrusted progress: https://example.invalid/path"

    init(maximumOutputBytes: Int = 65_536) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let sourceURL = directory.appendingPathComponent("source.sqlite3")
            let scope = ToolAuthorizationScope(canonicalRoots: [directory.standardizedFileURL], writableRoots: [],
                allowedTools: ["context_get"], networkAllowed: false, maximumInlineOutputBytes: maximumOutputBytes)
            let authorization = try ContinuityIngressAuthorization(projectID: ProjectID(), projectGeneration: .initial,
                sourceBindingID: UUID(), taskID: UUID(), assignmentID: "host-protocol-fixture",
                assignmentSHA256: String(repeating: "a", count: 64), authorizationScope: scope)
            let source = try SQLiteStore(path: sourceURL)
            defer { source.close() }
            let committed = try source.handoffCommit(HandoffPacket(id: "non-uuid-source-id",
                createdAt: "2026-09-08T10:00:00Z", updatedAt: "2026-09-08T10:00:00Z", source: .model,
                resumeReady: true, goal: "Untrusted progress: https://example.invalid/path"), authorization: authorization, automaticHandoffEnabled: true)
            let selection = try BudgetPolicyState(globalPolicy: BudgetPolicy(automaticHandoffEnabled: true)).resolve(
                BudgetPolicyScope(kind: .projectOverride, projectID: authorization.projectID.description, projectGeneration: 1))
            let acceptance = try ContinuityIngressAcceptanceReceipt(source: committed.revision,
                operationID: XCTUnwrap(committed.delivery).operationID, runID: RunID(), policySelection: selection,
                acceptedAt: "2026-09-08T10:00:00Z")
            let envelope = try ContinuitySourceBootstrapEnvelope(acceptance: acceptance, bootstrapNonce: UUID())
            let candidate = UUID(), grantID = UUID()
            let request = try SourceBootstrapRequest(envelope: envelope, candidateID: candidate, grantID: grantID,
                modelKey: "fixture/tool-model", idempotencyKey: "source-host:\(acceptance.operationID.uuidString.lowercased())")
            self.directory = directory
            self.sourceURL = sourceURL
            self.providerDirectory = directory.appendingPathComponent("provider")
            self.request = request
            self.grant = try ContinuityBootstrapGrant(grantID: grantID, candidateID: candidate, envelope: envelope,
                lease: RunLease(runID: envelope.runID, ownerID: "host-protocol-fixture", epoch: 1,
                    acquiredAt: "2026-09-08T10:00:00Z", renewedAt: "2026-09-08T10:00:00Z", expiresAt: "2026-09-08T10:10:00Z"),
                maximumOutputBytes: maximumOutputBytes, createdAt: "2026-09-08T10:00:00Z")
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor SourceHostTrace {
    var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

private actor SourceHostExecutor: SourceBootstrapExecuting {
    enum Mode: Sendable { case normal, failRead, wrongProviderProof, rejectBudget }
    let fixture: SourceHostFixture
    let trace: SourceHostTrace
    let mode: Mode
    var prepared: [ProviderTurnIntent] = []
    var costs: [Int] = []

    init(fixture: SourceHostFixture, trace: SourceHostTrace, mode: Mode = .normal) {
        self.fixture = fixture; self.trace = trace; self.mode = mode
    }

    func prepareProviderTurn(intent: ProviderTurnIntent, input: Data, tools: [Data],
        capabilities: ProviderCapabilities, totalBootstrapInputBytes: Int) async throws -> ProviderTurn? {
        try Task.checkCancellation()
        await trace.append(intent.previousResponseID == nil ? "prepare-root" : "prepare-ack")
        XCTAssertEqual(capabilities.contextLength, 32_768)
        XCTAssertEqual(capabilities.modelKey, fixture.request.modelKey)
        XCTAssertEqual(intent.inputSHA256, JSONSupport.sha256Hex(input))
        XCTAssertGreaterThan(totalBootstrapInputBytes, input.count)
        prepared.append(intent); costs.append(totalBootstrapInputBytes)
        if mode == .rejectBudget { throw ContinuityIngressError.capacityExceeded("fixture budget admission") }
        return nil
    }

    func retrieveContext(rootIntent: ProviderTurnIntent, rootTurn: ProviderTurn) async throws -> SourceBootstrapContextResult {
        try Task.checkCancellation()
        await trace.append("retrieve")
        if mode == .failRead { throw ContinuityIngressError.notFound }
        let store = try SQLiteStore(path: fixture.sourceURL)
        defer { store.close() }
        let source = try store.continuityHandoffRevision(identity: fixture.request.sourceIdentity,
            authorization: fixture.request.envelope.authorization)
        let packet = try JSONSerialization.jsonObject(with: source.canonicalPacketJSON)
        let payload: [String: Any] = ["ok": true, "found": true, "packet": packet,
            "continuity_id": source.identity.continuityID, "revision": source.identity.revision,
            "packet_sha256": source.identity.packetSHA256]
        let result = try ContinuityBootstrapReadResult(canonicalToolResultJSON:
            ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false, "payload": payload]))
        let proof = try ContinuityBootstrapRetrievalProof(grant: fixture.grant, providerTurnID: rootIntent.turnID,
            providerResponseID: mode == .wrongProviderProof ? "different-response" : rootTurn.responseID,
            providerCallID: XCTUnwrap(rootTurn.toolCalls.first).callID, toolInvocationID: UUID(), result: result,
            retrievedAt: "2026-09-08T10:00:01Z")
        return try SourceBootstrapContextResult(request: fixture.request, proof: proof)
    }

    func recordAcknowledgement(intent: ProviderTurnIntent, turn: ProviderTurn) async throws {
        try Task.checkCancellation()
        XCTAssertEqual(intent.turnID.uuidString.lowercased(), turn.requestID)
        await trace.append("record-ack")
    }
}

private actor SourceHostTransport: LMStudioManagedTransporting {
    enum Mode: Sendable { case normal, wrongSource, prematureACK, extraTool, missingUsage, unknownRoot, wrongAckNonce, delayedRoot, duplicateCorrectedAck, missingAckFields }
    let trace: SourceHostTrace
    let mode: Mode
    var roots: [LMStudioRootRequest] = []
    var continuations: [LMStudioContinuationRequest] = []
    var cancelledIDs: [String] = []

    init(trace: SourceHostTrace, mode: Mode = .normal) { self.trace = trace; self.mode = mode }

    func probe() async throws -> LMStudioProviderCapabilities {
        LMStudioProviderCapabilities(modelKey: "fixture/tool-model", loadedInstanceID: "fixture/tool-model@32768",
            contextLength: 32_768, maximumContextLength: 131_072, parallelism: 1, flashAttention: true,
            trainedForToolUse: true, streamingVerified: true, functionToolContractVerified: true,
            usageReportingVerified: true, capabilityFingerprintSHA256: String(repeating: "a", count: 64),
            contractProbeResponseID: "source-capability-probe")
    }

    func createRoot(_ request: LMStudioRootRequest) async throws -> LMStudioResponseTurn {
        roots.append(request)
        await trace.append("provider-root")
        if mode == .delayedRoot { try await Task.sleep(nanoseconds: 10_000_000_000) }
        if mode == .unknownRoot { throw LMStudioProviderError.deadlineExceeded(phase: "total") }
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.userInput.utf8)) as? [String: Any])
        let id = try XCTUnwrap(input["continuity_id"] as? String)
        let arguments = try ForgeJSONCanonicalizationV1.data(from: ["handoff_id": mode == .wrongSource ? "wrong-source" : id])
        var calls = [LMStudioFunctionCall(itemID: "source-context-item", callID: "source-context-call",
            name: mode == .prematureACK ? "forge_continuity_ack" : "context_get", arguments: String(decoding: arguments, as: UTF8.self))]
        if mode == .extraTool { calls.append(LMStudioFunctionCall(itemID: "extra-item", callID: "extra-call", name: "fs_read", arguments: "{}")) }
        return LMStudioResponseTurn(responseID: "source-root-response", previousResponseID: nil,
            model: "fixture/tool-model", status: "completed", assistantText: "", functionCalls: calls,
            usage: LMStudioUsage(inputTokens: 300, outputTokens: 30, totalTokens: 330), usageWasReported: mode != .missingUsage)
    }

    func continueSession(_ request: LMStudioContinuationRequest) async throws -> LMStudioResponseTurn {
        continuations.append(request)
        await trace.append("provider-ack")
        let tool = try XCTUnwrap(request.tools.first)
        let encoded = try JSONEncoder().encode(tool)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let parameters = try XCTUnwrap(object["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: [String: Any]])
        var arguments = properties.mapValues { $0["const"]! }
        if mode == .wrongAckNonce { arguments["nonce"] = UUID().uuidString.lowercased() }
        if mode == .missingAckFields { arguments.removeValue(forKey: "nonce"); arguments.removeValue(forKey: "accepted") }
        let data = try ForgeJSONCanonicalizationV1.data(from: arguments)
        var calls = [LMStudioFunctionCall(itemID: "source-ack-item", callID: "source-ack-call", name: tool.name, arguments: String(decoding: data, as: UTF8.self))]
        if mode == .duplicateCorrectedAck {
            arguments["acknowledgement_contract_version"] = 3
            let incorrect = try ForgeJSONCanonicalizationV1.data(from: arguments)
            calls.insert(LMStudioFunctionCall(itemID: "incorrect-ack-item", callID: "incorrect-ack-call", name: tool.name,
                arguments: String(decoding: incorrect, as: UTF8.self)), at: 0)
        }
        return LMStudioResponseTurn(responseID: "source-ack-response", previousResponseID: request.previousResponseID,
            model: "fixture/tool-model", status: "completed", assistantText: "",
            functionCalls: calls,
            usage: LMStudioUsage(inputTokens: 700, outputTokens: 80, totalTokens: 999))
    }

    func receipt(forIdempotencyKey key: String) async -> LMStudioResponseTurn? { nil }
    func cancel(operationID: String) async { cancelledIDs.append(operationID) }
    func stats() -> (roots: [LMStudioRootRequest], continuations: [LMStudioContinuationRequest]) { (roots, continuations) }
}

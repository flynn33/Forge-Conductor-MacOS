import XCTest
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif
@testable import ForgeConductorCore

final class SourceDerivedToolResultBudgetTests: XCTestCase, @unchecked Sendable {
    func testExactAndMissingBootstrapSeedsRetainActualProvenanceAcrossReopen() async throws {
        for missing in [false, true] {
            try await withFixture { fixture in
                let supervisor = try await fixture.open()
                let turn = try self.turn(calls: [], missingUsage: missing)
                let bytes = 24_000
                let request = try PersistedManagedRunBudgetEvaluator.sourceSeedRequest(turn: turn,
                    retainedContextSerializedBytes: bytes, policy: fixture.configuration.policy)
                _ = try await supervisor.observeSourceProviderTurn(turn, request: request,
                    seedRetainedContextSerializedBytes: bytes)
                let before = await supervisor.snapshot()
                XCTAssertEqual(before.state.latestObservation?.used, missing ? 10_000 : 120)
                XCTAssertEqual(before.state.latestObservation?.source, missing ? .serializedEstimate : .providerExact)
                XCTAssertEqual(before.state.latestObservation?.accounting?.rawProviderUsage, turn.usage)
                XCTAssertEqual(before.state.latestObservation?.accounting?.toolResultAccounting?.seedRetainedContextSerializedBytes, bytes)
                let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.databaseURL)
                do {
                    let restored = try await ContextBudgetSupervisor.restore(repository: reopened, identity: fixture.identity)
                    _ = try await restored.observeSourceProviderTurn(turn, request: request,
                        seedRetainedContextSerializedBytes: bytes)
                    let replayed = await restored.snapshot()
                    XCTAssertEqual(replayed, before)
                    await self.assertRejected {
                        _ = try await restored.observeSourceProviderTurn(turn, request: request,
                            seedRetainedContextSerializedBytes: bytes + 1)
                    }
                    await reopened.close()
                } catch { await reopened.close(); throw error }
            }
        }
    }

    func testBootstrapSeedRequiresWholeHistoryBoundAndPreservesUnknownOverflow() throws {
        let missing = try turn(calls: [], missingUsage: true)
        XCTAssertThrowsError(try PersistedManagedRunBudgetEvaluator.sourceSeedRequest(turn: missing,
            retainedContextSerializedBytes: 0, policy: .init()))
        XCTAssertThrowsError(try PersistedManagedRunBudgetEvaluator.sourceSeedRequest(turn: missing,
            retainedContextSerializedBytes: Int.max, policy: .init()))
        let estimated = try turn(calls: [], inputTokens: 15_000, usageSource: .serializedEstimate)
        let estimate = try PersistedManagedRunBudgetEvaluator.sourceSeedRequest(turn: estimated,
            retainedContextSerializedBytes: 24_000, policy: .init())
        XCTAssertEqual(estimate.measurement, .estimatedTokens(usedTokens: 15_020, confidence: 0.6))
        let overflow = try turn(calls: [], usageSource: .providerOverflow)
        let unknown = try PersistedManagedRunBudgetEvaluator.sourceSeedRequest(turn: overflow,
            retainedContextSerializedBytes: 24_000, policy: .init())
        XCTAssertEqual(unknown.measurement, .providerOverflow(lastKnownUsedTokens: 100))
        XCTAssertEqual(unknown.rawProviderUsage, overflow.usage)
    }

    func testProspectiveFullResultDenialDoesNotPersistSpeculativeUsageOrAction() async throws {
        try await withFixture { fixture in
            let supervisor = try await fixture.open()
            let turn = try self.turn(calls: ["call-1"])
            try await self.observe(turn, on: supervisor)
            let before = await supervisor.snapshot()
            let preflight = try await self.preflight([self.output("call-1", "0")])
            let projected = try ManagedToolResultProjection(priorPrefix: self.empty(), providerCallID: "call-1",
                continuationPreflight: preflight, maximumToolResultBytes: 65_536, toolSchemaSHA256: self.schema)
            let action = try await supervisor.projectToolResult(projected)
            XCTAssertEqual(action, .emergency, "The full escaped result cannot fit a 128K context")
            let after = await supervisor.snapshot()
            XCTAssertEqual(after, before)
            let stored = try await fixture.repository.contextBudgetState(identity: fixture.identity)
            XCTAssertEqual(stored, before.state)
            let pending = try await fixture.repository.pendingContextBudgetActionRequests()
            XCTAssertTrue(pending.isEmpty, "A prospective result must not enqueue a canonical rollover")
            XCTAssertEqual(after.state.latestObservation?.used, 120)
            XCTAssertEqual(after.state.latestObservation?.accounting?.rawProviderUsage, turn.usage)
            let smaller = try ManagedToolResultProjection(priorPrefix: self.empty(), providerCallID: "call-1",
                continuationPreflight: preflight, maximumToolResultBytes: 1_024, toolSchemaSHA256: self.schema)
            let admitted = try await supervisor.projectToolResult(smaller)
            XCTAssertEqual(admitted, .normal)
            let unchanged = await supervisor.snapshot()
            XCTAssertEqual(unchanged, before)
        }
    }

    func testActualEscapedPrefixReplayAndSameResponseSurviveRestartWithoutDoubleCharge() async throws {
        try await withFixture { fixture in
            let supervisor = try await fixture.open()
            let turn = try self.turn(calls: ["call-1", "call-2", "call-3"])
            try await self.observe(turn, on: supervisor)
            let firstOutputs = [self.output("call-1", "{\"payload\":\"slash / quote \\\" and 雪\"}")]
            let secondOutputs = firstOutputs + [self.output("call-2", String(repeating: "\n\\\"", count: 120))]
            let thirdOutputs = secondOutputs + [self.output("call-3", "{\"ok\":true}")]
            let first = try await self.prefix(firstOutputs)
            let second = try await self.prefix(secondOutputs)
            let third = try await self.prefix(thirdOutputs)
            _ = try await supervisor.observeToolResultPrefix(first)
            _ = try await supervisor.observeToolResultPrefix(second)
            let before = await supervisor.snapshot()
            let policy = before.state.configuration.policy
            let expectedFirst = try ContextBudgetMath.estimateTokens(serializedBytes: first.serializedInputByteCount, policy: policy)
            let expectedSecond = try ContextBudgetMath.estimateTokens(
                serializedBytes: second.serializedInputByteCount - first.serializedInputByteCount, policy: policy)
            XCTAssertEqual(before.state.latestObservation?.used, 120 + expectedFirst + expectedSecond)
            XCTAssertEqual(before.state.latestObservation?.accounting?.rawProviderUsage?.totalTokens, 9_999)
            XCTAssertEqual(before.state.latestObservation?.accounting?.toolResultAccounting?.prefixes.count, 2)
            _ = try await supervisor.observeToolResultPrefix(first)
            _ = try await supervisor.observeToolResultPrefix(second)
            try await self.observe(turn, on: supervisor)
            let replayed = await supervisor.snapshot()
            XCTAssertEqual(replayed, before, "Replaying the exact provider usage must not erase previously charged prefixes")

            await fixture.repository.close()
            let reopened = try ProjectControlPlaneRepository(databaseURL: fixture.databaseURL)
            do {
                let restored = try await ContextBudgetSupervisor.restore(repository: reopened, identity: fixture.identity)
                try await self.observe(turn, on: restored)
                _ = try await restored.observeToolResultPrefix(first)
                let resumed = await restored.snapshot()
                XCTAssertEqual(resumed, before)
                _ = try await restored.observeToolResultPrefix(third)
                let final = await restored.snapshot()
                let lastDelta = try ContextBudgetMath.estimateTokens(
                    serializedBytes: third.serializedInputByteCount - second.serializedInputByteCount, policy: policy)
                XCTAssertEqual(final.state.latestObservation?.used, 120 + expectedFirst + expectedSecond + lastDelta)
                XCTAssertEqual(final.state.ewma.sampleCount, before.state.ewma.sampleCount + 1)
                XCTAssertEqual(final.state.observationCount, before.state.observationCount + 1)
                XCTAssertEqual(final.state.latestObservation?.accounting?.rawProviderUsage, turn.usage)
                await reopened.close()
            } catch {
                await reopened.close()
                throw error
            }
        }
    }

    func testChangedOrOutOfOrderPrefixAndChangedProviderReceiptFailClosed() async throws {
        try await withFixture { fixture in
            let supervisor = try await fixture.open()
            let turn = try self.turn(calls: ["call-1", "call-2"])
            try await self.observe(turn, on: supervisor)
            let first = try await self.prefix([self.output("call-1", "result")])
            let second = try await self.prefix([self.output("call-1", "result"), self.output("call-2", "result")])
            await self.assertRejected { _ = try await supervisor.observeToolResultPrefix(second) }
            let wrongCall = try ManagedToolResultPrefix(providerResponseID: "response-1", outputCount: 1,
                lastProviderCallID: "call-2", canonicalPrefixSHA256: first.canonicalPrefixSHA256,
                serializedInputByteCount: first.serializedInputByteCount)
            await self.assertRejected { _ = try await supervisor.observeToolResultPrefix(wrongCall) }
            _ = try await supervisor.observeToolResultPrefix(first)
            let changed = try ManagedToolResultPrefix(providerResponseID: "response-1", outputCount: 1,
                lastProviderCallID: "call-1", canonicalPrefixSHA256: String(repeating: "a", count: 64),
                serializedInputByteCount: first.serializedInputByteCount)
            await self.assertRejected { _ = try await supervisor.observeToolResultPrefix(changed) }
            let regressed = try ManagedToolResultPrefix(providerResponseID: "response-1", outputCount: 2,
                lastProviderCallID: "call-2", canonicalPrefixSHA256: second.canonicalPrefixSHA256,
                serializedInputByteCount: first.serializedInputByteCount)
            await self.assertRejected { _ = try await supervisor.observeToolResultPrefix(regressed) }
            let changedTurn = try self.turn(calls: ["call-1", "call-2"], inputTokens: 101)
            await self.assertRejected { try await self.observe(changedTurn, on: supervisor) }
            let wrongParent = try self.turn(responseID: "response-2", previous: "unobserved", calls: [])
            await self.assertRejected { try await self.observe(wrongParent, on: supervisor) }
            let before = await supervisor.snapshot()
            let wrongProjection = try await ManagedToolResultProjection(priorPrefix: first, providerCallID: "other-call",
                continuationPreflight: self.preflight([self.output("call-1", "result"), self.output("other-call", "0")]),
                maximumToolResultBytes: 1_024, toolSchemaSHA256: self.schema)
            await self.assertRejected { _ = try await supervisor.projectToolResult(wrongProjection) }
            let after = await supervisor.snapshot()
            XCTAssertEqual(after, before)
        }
    }

    func testNewResponseClearsPriorPrefixAndDoesNotCopyAbsentRawUsage() async throws {
        try await withFixture { fixture in
            let supervisor = try await fixture.open()
            try await self.observe(self.turn(calls: ["call-1"]), on: supervisor)
            let prefix = try await self.prefix([self.output("call-1", "actual")])
            _ = try await supervisor.observeToolResultPrefix(prefix)
            let prior = await supervisor.snapshot()
            let next = try self.turn(responseID: "response-2", previous: "response-1", calls: ["next-call"], missingUsage: true)
            let request = ContextBudgetEvaluationRequest(triggerPoint: .afterProviderTurn, providerResponseID: next.responseID,
                measurement: .serializedIncrement(bytes: 240), rawProviderUsage: nil,
                accountingCut: "retained_input_after_response")
            _ = try await supervisor.observeSourceProviderTurn(next, request: request)
            let current = await supervisor.snapshot()
            XCTAssertNil(current.state.latestObservation?.accounting?.rawProviderUsage)
            XCTAssertEqual(current.state.latestObservation?.accounting?.toolResultAccounting?.prefixes.count, 0)
            XCTAssertEqual(current.state.latestObservation?.accounting?.toolResultAccounting?.providerResponseID, "response-2")
            XCTAssertEqual(current.state.latestObservation?.used, (prior.state.latestObservation?.used ?? 0) + 100)
            _ = try await supervisor.observeSourceProviderTurn(next, request: request)
            let replayed = await supervisor.snapshot()
            XCTAssertEqual(replayed, current)
            await self.assertRejected { _ = try await supervisor.observeToolResultPrefix(prefix) }
        }
    }

    func testCurrentConfigurationTighteningChangesProjectionWithoutChangingActualInput() async throws {
        try await withFixture(capacity: 262_144) { fixture in
            let supervisor = try await fixture.open()
            try await self.observe(self.turn(calls: ["call-1"]), on: supervisor)
            let projection = try await ManagedToolResultProjection(priorPrefix: self.empty(), providerCallID: "call-1",
                continuationPreflight: self.preflight([self.output("call-1", "0")]),
                maximumToolResultBytes: 65_536, toolSchemaSHA256: self.schema)
            let allowed = try await supervisor.projectToolResult(projection)
            XCTAssertEqual(allowed, .normal)
            let config = try self.configuration(runID: fixture.identity.runID, capacity: 131_072,
                inheritance: fixture.configuration.resolvedPolicy?.inheritedSourceBudget)
            _ = try await supervisor.reconfigure(config)
            let before = await supervisor.snapshot()
            let denied = try await supervisor.projectToolResult(projection)
            XCTAssertEqual(denied, .emergency)
            let after = await supervisor.snapshot()
            XCTAssertEqual(after, before)
            XCTAssertEqual(after.state.latestObservation?.used, 120)
            XCTAssertEqual(after.state.latestObservation?.accounting?.rawProviderUsage?.inputTokens, 100)
        }
    }

    func testWireBoundAndInvalidPrefixBoundsAreRejected() async throws {
        XCTAssertThrowsError(try ManagedToolResultPrefix(providerResponseID: "response-1", outputCount: 0,
            lastProviderCallID: nil, canonicalPrefixSHA256: String(repeating: "a", count: 64), serializedInputByteCount: 0))
        XCTAssertThrowsError(try ManagedToolResultPrefix(providerResponseID: "response-1", outputCount: 1,
            lastProviderCallID: String(repeating: "x", count: 513), canonicalPrefixSHA256: schema, serializedInputByteCount: 1))
        try await withFixture { fixture in
            let supervisor = try await fixture.open()
            try await self.observe(self.turn(calls: ["call-1"]), on: supervisor)
            let preflight = try await self.preflight([self.output("call-1", "0")], maximumRequestBytes: 1_024)
            let projection = try ManagedToolResultProjection(priorPrefix: self.empty(), providerCallID: "call-1",
                continuationPreflight: preflight, maximumToolResultBytes: 1_024, toolSchemaSHA256: self.schema)
            let before = await supervisor.snapshot()
            await self.assertRejected { _ = try await supervisor.projectToolResult(projection) }
            let after = await supervisor.snapshot()
            XCTAssertEqual(after, before)
        }
    }

    func testCompactMaximumBatchAndLegacyNilAccountingDecodeWithinExistingRecordLimit() throws {
        let calls = (0..<ManagedModelProviderContract.maximumToolCallCount).map { "call-\($0)" }
        var accounting = try ManagedToolResultAccounting(providerResponseID: "response-1", providerTurnSHA256: schema,
            expectedCallSHA256: calls.map { JSONSupport.sha256Hex(Data($0.utf8)) })
        for (index, call) in calls.enumerated() {
            accounting = try accounting.appending(.init(providerResponseID: "response-1", outputCount: index + 1,
                lastProviderCallID: call, canonicalPrefixSHA256: JSONSupport.sha256Hex(Data(call.utf8)),
                serializedInputByteCount: (index + 1) * 64))
        }
        let configuration = try configuration(runID: RunID(), capacity: 131_072)
        let normalized = try ContextBudgetAccounting(version: "admitted_total_v2", cut: "retained_input_after_response",
            retainedInputTokens: 5_000, futureReserveTokens: configuration.reserves.fixedTotal(),
            resolvedPolicy: configuration.resolvedPolicy, toolResultAccounting: accounting)
        let data = try JSONEncoder().encode(normalized)
        XCTAssertLessThan(data.count, 48 * 1_024, "Leave room for the rest of the existing 64KiB state envelope")
        XCTAssertEqual(try JSONDecoder().decode(ContextBudgetAccounting.self, from: data).validated(), normalized)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(accounting)) as? [String: Any])
        var stamps = try XCTUnwrap(object["prefixes"] as? [[String: Any]])
        stamps[1]["inputBytes"] = 1
        object["prefixes"] = stamps
        XCTAssertThrowsError(try JSONDecoder().decode(ManagedToolResultAccounting.self,
            from: JSONSerialization.data(withJSONObject: object)))
        let legacy = try ContextBudgetAccounting(version: "legacy_remaining_v1", cut: "retained_input_after_response",
            retainedInputTokens: 100, futureReserveTokens: 64)
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        XCTAssertNil(legacyObject["toolResultAccounting"])
        XCTAssertEqual(try JSONDecoder().decode(ContextBudgetAccounting.self, from: legacyData).validated(), legacy)
    }

    private let schema = JSONSupport.sha256Hex(Data("[]".utf8))
    private func empty() throws -> ManagedToolResultPrefix {
        try .init(providerResponseID: "response-1", outputCount: 0, lastProviderCallID: nil,
            canonicalPrefixSHA256: schema, serializedInputByteCount: 0)
    }
    private func output(_ call: String, _ output: String) -> [String: String] {
        ["type": "function_call_output", "call_id": call, "output": output]
    }
    private func preflight(_ outputs: [[String: String]], maximumRequestBytes: Int = 512 * 1_024) async throws -> ProviderRequestPreflight {
        let provider = LMStudioManagedModelProvider(transport: try LMStudioManagedSessionTransport(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:1")!, modelKey: "fixture/model",
            maximumRequestBytes: maximumRequestBytes, maximumOutputTokens: 64)))
        return try await provider.preflightContinuation(.init(operationID: UUID(), idempotencyKey: UUID().uuidString,
            modelKey: "fixture/model", previousResponseID: "response-1",
            input: JSONSerialization.data(withJSONObject: outputs, options: [.sortedKeys, .withoutEscapingSlashes]), tools: []))
    }
    private func prefix(_ outputs: [[String: String]]) async throws -> ManagedToolResultPrefix {
        let preflight = try await preflight(outputs)
        let canonical = try JSONSerialization.data(withJSONObject: outputs, options: [.sortedKeys, .withoutEscapingSlashes])
        return try .init(providerResponseID: "response-1", outputCount: outputs.count,
            lastProviderCallID: outputs.last?["call_id"], canonicalPrefixSHA256: JSONSupport.sha256Hex(canonical),
            serializedInputByteCount: XCTUnwrap(preflight.serializedInputByteCount))
    }
    private func turn(responseID: String = "response-1", previous: String? = nil, calls: [String],
                      inputTokens: Int = 100, missingUsage: Bool = false,
                      usageSource: ProviderUsageSource = .providerExact) throws -> ProviderTurn {
        try .init(requestID: "request-\(responseID)", responseID: responseID, previousResponseID: previous,
            providerID: "lmstudio", providerVersion: "fixture-1", modelKey: "fixture/model", providerInstanceID: "fixture-instance",
            messages: [], toolCalls: calls.map { try .init(callID: $0, name: "fs_read", argumentsJSON: Data("{}".utf8)) },
            usage: missingUsage ? nil : ProviderUsage(capacity: 131_072, inputTokens: inputTokens, outputTokens: 20,
                totalTokens: max(9_999, inputTokens), source: usageSource,
                confidence: usageSource == .providerExact ? 1 : 0.6), completed: true, finishReason: calls.isEmpty ? .stop : .toolCalls)
    }
    private func observe(_ turn: ProviderTurn, on supervisor: ContextBudgetSupervisor) async throws {
        _ = try await supervisor.observeSourceProviderTurn(turn, request: .init(triggerPoint: .afterProviderTurn,
            providerResponseID: turn.responseID, measurement: .providerExact(usedTokens: (turn.usage?.inputTokens ?? 0) + 20),
            rawProviderUsage: turn.usage, accountingCut: "retained_input_after_response", toolSchemaSHA256: schema))
    }
    private func configuration(runID: RunID, capacity: Int, inheritance: InheritedSourceContextBudget? = nil) throws -> ContextBudgetConfiguration {
        let context = BudgetContextPolicy(mode: .manual, maxContextTokens: capacity, responseReserveTokens: 64,
            futureToolReserveTokens: 0, handoffReserveTokens: 0, recoveryReserveTokens: 0, safetyReserveTokens: 0,
            checkpointRatio: 0.70, rolloverRatio: 0.85, emergencyRatio: 0.95)
        let selection = try BudgetPolicyState(globalPolicy: .init(context: context)).resolve(.globalDefault)
        let inherited = try inheritance ?? InheritedSourceContextBudget(carryover: .init(conversationID: UUID(), taskID: UUID(),
            runID: runID, acceptanceSHA256: String(repeating: "a", count: 64),
            ceilings: .init(effectiveContextTokens: capacity, maximumOutputTokens: 64, tools: .init(),
                reserves: .init(outputTokens: 64, schemaTokens: 0, handoffTokens: 0, recoveryTokens: 0),
                checkpointRatio: 0.70, rolloverRatio: 0.85, emergencyRatio: 0.95),
            priorSourceReadCallsAtEnrollment: 0, providerStageCount: 1, admittedProviderCalls: 1,
            observedInputTokens: 100, observedOutputTokens: 20, exactUsageStageCount: 1,
            journalSHA256: String(repeating: "b", count: 64)))
        let capabilities = try ProviderCapabilities(providerID: "lmstudio", providerVersion: "fixture-1",
            modelKey: "fixture/model", providerInstanceID: "fixture-instance", contextLength: 262_144, maximumContextLength: 262_144,
            statefulResponses: true, streaming: true, customTools: true, mcp: false, structuredOutput: true,
            usageReporting: true, idempotencyLookup: true, capabilityFingerprintSHA256: String(repeating: "a", count: 64))
        return try PersistedManagedRunBudgetEvaluator.configuration(capabilities: capabilities,
            selection: selection, inheritance: inherited)
    }
    private func assertRejected(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Invalid tool accounting was accepted", file: file, line: line) }
        catch { XCTAssertNotNil(error as? ContextBudgetError, file: file, line: line) }
    }
    private func withFixture(capacity: Int = 131_072, _ body: (SourceToolBudgetFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-tool-budget-\(UUID().uuidString)")
        let databaseURL = root.appendingPathComponent("control-plane.sqlite3")
        let repository = try ProjectControlPlaneRepository(databaseURL: databaseURL)
        do {
            let projectID = ProjectID(), projectRoot = root.appendingPathComponent("project")
            _ = try await repository.registerProjectUnchecked(projectID: projectID, displayName: "Source Tool Budget", canonicalRoot: projectRoot)
            let run = try await repository.createAutonomousRun(.init(projectID: projectID, projectGeneration: .initial,
                mission: "Verify durable output accounting", providerID: "lmstudio", modelKey: "fixture/model",
                specification: .init(allowedTools: ["fs_read"], completionGates: ["tests"]),
                authorizationScope: .init(canonicalRoots: [projectRoot], allowedTools: ["fs_read"],
                    networkAllowed: false, maximumInlineOutputBytes: 65_536)))
            let lease = try await repository.acquireRunLease(runID: run.runID, ownerID: "source-tool-budget-fixture")
            let sessionID = UUID().uuidString.lowercased()
            try await repository.reserveProviderSession(.init(sessionID: sessionID, runID: run.runID,
                projectID: projectID, projectGeneration: .initial, providerID: "lmstudio", adapterID: "lmstudio-rest",
                modelKey: "fixture/model", providerResponseID: "root-response", idempotencyKey: UUID().uuidString,
                contextCapacity: capacity), lease: lease)
            _ = try await repository.releaseRunLease(lease)
            let identity = ContextBudgetIdentity(runID: run.runID, projectID: projectID, projectGeneration: .initial, sessionID: sessionID)
            try await body(.init(repository: repository, databaseURL: databaseURL, identity: identity,
                configuration: configuration(runID: run.runID, capacity: capacity)))
            await repository.close()
            try? FileManager.default.removeItem(at: root)
        } catch {
            await repository.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}

private struct SourceToolBudgetFixture {
    let repository: ProjectControlPlaneRepository
    let databaseURL: URL
    let identity: ContextBudgetIdentity
    let configuration: ContextBudgetConfiguration
    func open() async throws -> ContextBudgetSupervisor {
        try await ContextBudgetSupervisor.open(repository: repository, identity: identity, configuration: configuration)
    }
}

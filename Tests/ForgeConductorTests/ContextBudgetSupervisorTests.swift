// ContextBudgetSupervisorTests.swift
// Verifies durable provider-budget observations and manager-owned automatic actions.

import XCTest
@testable import ForgeConductorCore

final class ContextBudgetSupervisorTests: XCTestCase {
    func testCapacityDiscoverySelectsExactLoadedInstanceAndRejectsInvalidConfiguration() throws {
        let input = ContextCapacityDiscoveryInput(
            providerID: "lmstudio",
            providerVersionFingerprint: "0.3.30:responses-v1",
            modelKey: "fixture/model",
            selectedInstanceID: "instance-b",
            configuredContextLength: 8_192,
            maximumContextLength: 16_384,
            loadedInstances: [
                ProviderLoadedContextInstance(
                    instanceID: "instance-a",
                    modelKey: "other/model",
                    contextLength: 4_096
                ),
                ProviderLoadedContextInstance(
                    instanceID: "instance-b",
                    modelKey: "fixture/model",
                    contextLength: 12_288
                ),
            ]
        )
        let resolution = try ContextCapacityResolver.resolve(input)
        XCTAssertEqual(resolution.activeInstanceID, "instance-b")
        XCTAssertEqual(resolution.capacity, 12_288)
        XCTAssertFalse(resolution.requiresModelLoad)

        XCTAssertThrowsError(try ContextCapacityResolver.resolve(ContextCapacityDiscoveryInput(
            providerID: "lmstudio",
            providerVersionFingerprint: "fixture",
            modelKey: "fixture/model",
            configuredContextLength: 32_768,
            maximumContextLength: 16_384,
            loadedInstances: []
        ))) { error in
            XCTAssertEqual((error as? ContextBudgetError)?.code, "context_capacity_invalid")
        }

        XCTAssertThrowsError(try ContextCapacityResolver.resolve(ContextCapacityDiscoveryInput(
            providerID: "lmstudio",
            providerVersionFingerprint: "fixture",
            modelKey: "fixture/model",
            configuredContextLength: 8_192,
            maximumContextLength: 16_384,
            loadedInstances: [
                ProviderLoadedContextInstance(
                    instanceID: "instance-a",
                    modelKey: "fixture/model",
                    contextLength: 8_192
                ),
                ProviderLoadedContextInstance(
                    instanceID: "instance-b",
                    modelKey: "fixture/model",
                    contextLength: 8_192
                ),
            ]
        ))) { error in
            XCTAssertEqual((error as? ContextBudgetError)?.code, "context_instance_ambiguous")
        }

        let loadRequired = try ContextCapacityResolver.resolve(ContextCapacityDiscoveryInput(
            providerID: "lmstudio",
            providerVersionFingerprint: "fixture",
            modelKey: "fixture/model",
            configuredContextLength: 8_192,
            maximumContextLength: 16_384,
            loadedInstances: [],
            modelLoadPermitted: true
        ))
        XCTAssertTrue(loadRequired.requiresModelLoad)
        XCTAssertThrowsError(try ContextBudgetConfiguration(
            capacity: loadRequired,
            reserves: smallReserves,
            policy: smallPolicy
        ).validated()) { error in
            XCTAssertEqual((error as? ContextBudgetError)?.code, "context_model_load_required")
        }
    }

    func testSmallAndLargeAdaptiveThresholdFixturesUseExplicitReserves() throws {
        let small = try ContextBudgetMath.thresholds(
            configuration: configuration(capacity: 4_096),
            projectedNextTurn: 128
        )
        XCTAssertEqual(small.checkpoint, 832)
        XCTAssertEqual(small.rollover, 512)
        XCTAssertEqual(small.emergency, 384)
        XCTAssertEqual(small.hysteresis, 67)

        let largeConfiguration = ContextBudgetConfiguration(
            capacity: capacity(131_072),
            reserves: ContextBudgetReserves(
                outputTokens: 4_096,
                schemaTokens: 2_048,
                handoffTokens: 4_096,
                recoveryTokens: 2_048
            ),
            policy: ContextBudgetPolicy(initialProjectedNextTurnTokens: 2_048)
        )
        let large = try ContextBudgetMath.thresholds(
            configuration: largeConfiguration,
            projectedNextTurn: 2_048
        )
        XCTAssertEqual(large.checkpoint, 29_696)
        XCTAssertEqual(large.rollover, 17_818)
        XCTAssertEqual(large.emergency, 6_144)
        XCTAssertEqual(large.hysteresis, 2_376)
    }

    func testUsageCandidatesSelectStrongestAvailableEvidence() throws {
        let footprint = SerializedContextFootprint(messageBytes: 8_192)
        let provider = try ContextBudgetUsageCandidates(
            providerExactUsedTokens: 900,
            tokenizerExactUsedTokens: 850,
            serializedFootprint: footprint
        ).strongestMeasurement()
        XCTAssertEqual(provider, .providerExact(usedTokens: 900))

        let tokenizer = try ContextBudgetUsageCandidates(
            tokenizerExactUsedTokens: 850,
            serializedFootprint: footprint
        ).strongestMeasurement()
        XCTAssertEqual(tokenizer, .tokenizerExact(usedTokens: 850))

        let estimate = try ContextBudgetUsageCandidates(
            serializedFootprint: footprint
        ).strongestMeasurement()
        XCTAssertEqual(estimate, .serializedEstimate(footprint))

        let overflow = try ContextBudgetUsageCandidates(
            providerExactUsedTokens: 900,
            providerOverflow: true,
            lastKnownUsedTokens: 1_000
        ).strongestMeasurement()
        XCTAssertEqual(overflow, .providerOverflow(lastKnownUsedTokens: 1_000))
    }

    func testExactUsageAutomaticallyQueuesCheckpointRequestWithoutModelToolCallAndRestores() async throws {
        try await withFixture(capacity: 4_096) { fixture in
            let supervisor = try await ContextBudgetSupervisor.open(
                repository: fixture.repository,
                identity: fixture.identity,
                configuration: fixture.configuration,
                clock: fixture.clock
            )
            let normal = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .afterProviderTurn,
                providerResponseID: "resp-1",
                measurement: .providerExact(usedTokens: 100),
                growth: ContextBudgetGrowthSample(
                    userInputTokens: 64,
                    assistantOutputTokens: 32,
                    projectedNextTurnTokens: 128
                )
            ))
            XCTAssertEqual(normal.observation.action, .normal)
            XCTAssertNil(normal.actionRequest)

            let preflight = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .beforeProviderTurn,
                measurement: .current
            ))
            XCTAssertEqual(preflight.observation.action, .normal)

            let checkpoint = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .afterProviderTurn,
                providerResponseID: "resp-2",
                measurement: .providerExact(usedTokens: 2_528)
            ))
            XCTAssertEqual(checkpoint.observation.remaining, 800)
            XCTAssertEqual(checkpoint.observation.action, .checkpoint)
            XCTAssertEqual(checkpoint.actionRequest?.requestedAction, .checkpoint)
            XCTAssertNil(checkpoint.actionRequest?.fulfilledAction)
            let sourceObservation = try await fixture.repository.contextBudgetObservation(
                observationID: try XCTUnwrap(checkpoint.actionRequest?.observationID)
            )
            XCTAssertEqual(sourceObservation, checkpoint.observation)
            let initialRequests = try await fixture.repository
                .pendingContextBudgetActionRequests()
            XCTAssertEqual(initialRequests, [checkpoint.actionRequest].compactMap { $0 })
            let initialCommandCount = try await fixture.repository.readyContinuityCommandCount()
            XCTAssertEqual(initialCommandCount, 0)

            let restored = try await ContextBudgetSupervisor.restore(
                repository: fixture.repository,
                identity: fixture.identity,
                clock: fixture.clock
            )
            let snapshot = await restored.snapshot()
            XCTAssertEqual(snapshot.state.latestObservation, checkpoint.observation)
            XCTAssertEqual(snapshot.state.ewma.sampleCount, 1)
            XCTAssertEqual(
                snapshot.latestActionRequest?.requestID,
                checkpoint.actionRequest?.requestID
            )

            let repeated = try await restored.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .managerRecovery,
                measurement: .current
            ))
            XCTAssertEqual(repeated.observation.action, .checkpoint)
            XCTAssertNil(repeated.actionRequest)
            let restoredRequests = try await fixture.repository
                .pendingContextBudgetActionRequests()
            XCTAssertEqual(restoredRequests.count, 1)
            let restoredCommandCount = try await fixture.repository.readyContinuityCommandCount()
            XCTAssertEqual(restoredCommandCount, 0)
        }
    }

    func testSmallFixtureAutomaticallyQueuesRolloverRequest() async throws {
        try await withFixture(capacity: 4_096) { fixture in
            let supervisor = try await ContextBudgetSupervisor.open(
                repository: fixture.repository,
                identity: fixture.identity,
                configuration: fixture.configuration,
                clock: fixture.clock
            )
            _ = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .afterProviderTurn,
                providerResponseID: "resp-root",
                measurement: .providerExact(usedTokens: 100)
            ))
            let result = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .afterProviderTurn,
                providerResponseID: "resp-rollover",
                measurement: .providerExact(usedTokens: 2_828)
            ))
            XCTAssertEqual(result.observation.remaining, 500)
            XCTAssertEqual(result.observation.action, .rollover)
            XCTAssertEqual(result.actionRequest?.requestedAction, .rollover)
            let stored = try await fixture.repository.contextBudgetActionRequest(
                requestID: try XCTUnwrap(result.actionRequest?.requestID)
            )
            XCTAssertEqual(stored, result.actionRequest)
            let commandCount = try await fixture.repository.readyContinuityCommandCount()
            XCTAssertEqual(commandCount, 0)
        }
    }

    func testProviderOverflowImmediatelyQueuesEmergencyRollover() async throws {
        try await withFixture(capacity: 65_536) { fixture in
            let supervisor = try await ContextBudgetSupervisor.open(
                repository: fixture.repository,
                identity: fixture.identity,
                configuration: fixture.configuration,
                clock: fixture.clock
            )
            _ = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .afterProviderTurn,
                providerResponseID: "resp-before-overflow",
                measurement: .providerExact(usedTokens: 2_000)
            ))
            let emergency = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .providerOverflow,
                providerResponseID: "resp-overflow",
                measurement: .providerOverflow(lastKnownUsedTokens: 64_000)
            ))
            XCTAssertEqual(emergency.observation.source, .providerOverflow)
            XCTAssertEqual(emergency.observation.confidence, 1)
            XCTAssertEqual(emergency.observation.action, .emergency)
            XCTAssertEqual(emergency.actionRequest?.requestedAction, .emergency)
            let commandCount = try await fixture.repository.readyContinuityCommandCount()
            XCTAssertEqual(commandCount, 0)
        }
    }

    func testCheckpointToRolloverEscalatesOneOperationWithoutActiveRunConflict() async throws {
        try await withFixture(capacity: 4_096) { fixture in
            let supervisor = try await ContextBudgetSupervisor.open(
                repository: fixture.repository,
                identity: fixture.identity,
                configuration: fixture.configuration,
                clock: fixture.clock
            )
            _ = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .afterProviderTurn,
                providerResponseID: "resp-normal",
                measurement: .providerExact(usedTokens: 100)
            ))
            let checkpoint = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .afterProviderTurn,
                providerResponseID: "resp-checkpoint",
                measurement: .providerExact(usedTokens: 2_528)
            ))
            let checkpointRequest = try XCTUnwrap(checkpoint.actionRequest)
            XCTAssertEqual(checkpointRequest.requestedAction, .checkpoint)
            XCTAssertEqual(checkpointRequest.revision, 1)

            let lease = try await fixture.repository.acquireRunLease(
                runID: fixture.identity.runID,
                ownerID: "budget-action-worker"
            )
            let fulfilledCheckpoint = try await fixture.repository
                .markContextBudgetActionFulfilled(
                    requestID: checkpointRequest.requestID,
                    expectedRevision: checkpointRequest.revision,
                    fulfilledAction: .checkpoint,
                    lease: lease
                )
            XCTAssertEqual(fulfilledCheckpoint.fulfilledAction, .checkpoint)
            XCTAssertFalse(fulfilledCheckpoint.isPending)

            let rollover = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .beforeProviderTurn,
                providerResponseID: "resp-checkpoint",
                measurement: .providerExact(usedTokens: 2_828)
            ))
            let rolloverRequest = try XCTUnwrap(rollover.actionRequest)
            XCTAssertEqual(rolloverRequest.requestID, checkpointRequest.requestID)
            XCTAssertEqual(
                rolloverRequest.continuityOperationID,
                checkpointRequest.continuityOperationID
            )
            XCTAssertEqual(rolloverRequest.requestedAction, .rollover)
            XCTAssertEqual(rolloverRequest.fulfilledAction, .checkpoint)
            XCTAssertEqual(rolloverRequest.revision, 3)
            XCTAssertTrue(rolloverRequest.isPending)

            let pending = try await fixture.repository.pendingContextBudgetActionRequests()
            XCTAssertEqual(pending, [rolloverRequest])
            let commandCount = try await fixture.repository.readyContinuityCommandCount()
            XCTAssertEqual(commandCount, 0)
            let run = try await fixture.repository.autonomousRun(fixture.identity.runID)
            XCTAssertNil(run?.activeOperationID)
            _ = try await fixture.repository.releaseRunLease(lease)
        }
    }

    func testTokenizerEstimateToolGrowthAndTriggerPointsPersist() async throws {
        try await withFixture(capacity: 65_536) { fixture in
            let supervisor = try await ContextBudgetSupervisor.open(
                repository: fixture.repository,
                identity: fixture.identity,
                configuration: fixture.configuration,
                clock: fixture.clock
            )
            let tokenizer = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .afterProviderTurn,
                providerResponseID: "resp-tokenized",
                measurement: .tokenizerExact(usedTokens: 1_000),
                growth: ContextBudgetGrowthSample(
                    userInputTokens: 100,
                    assistantOutputTokens: 50,
                    projectedNextTurnTokens: 200
                )
            ))
            XCTAssertEqual(tokenizer.observation.source, .tokenizerExact)

            let estimated = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .toolSetChanged,
                providerResponseID: "resp-tokenized",
                measurement: .serializedEstimate(SerializedContextFootprint(
                    systemInstructionBytes: 900,
                    handoffBytes: 300,
                    messageBytes: 6_000,
                    toolSchemaBytes: 1_200,
                    toolResultBytes: 3_000,
                    projectedNextTurnBytes: 600
                )),
                growth: ContextBudgetGrowthSample(
                    userInputTokens: 300,
                    assistantOutputTokens: 150,
                    projectedNextTurnTokens: 400
                )
            ))
            XCTAssertEqual(estimated.observation.source, .serializedEstimate)

            let tool = try await supervisor.observeToolResult(
                serializedBytes: 900,
                providerResponseID: "resp-tokenized"
            )
            XCTAssertEqual(tool.observation.triggerPoint, .afterToolResult)
            XCTAssertEqual(tool.observation.source, .serializedEstimate)
            XCTAssertGreaterThan(tool.observation.used, estimated.observation.used)

            _ = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .systemInstructionsChanged,
                measurement: .serializedIncrement(bytes: 120)
            ))
            _ = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .managerRecovery,
                measurement: .current
            ))
            let observations = try await fixture.repository.contextBudgetObservations(
                identity: fixture.identity
            )
            let triggers = Set(observations.map(\.triggerPoint))
            XCTAssertTrue(triggers.isSuperset(of: [
                .afterProviderTurn, .toolSetChanged, .afterToolResult,
                .systemInstructionsChanged, .managerRecovery,
            ]))
            let snapshot = await supervisor.snapshot()
            XCTAssertEqual(snapshot.state.ewma.sampleCount, 3)
            XCTAssertEqual(
                try XCTUnwrap(snapshot.state.ewma.userInputTokens),
                150,
                accuracy: 0.000_001
            )
            XCTAssertNotNil(snapshot.state.ewma.toolResultTokens)
        }
    }

    func testConfigurationChangeReevaluatesCurrentUsageAndPersistsCapacity() async throws {
        try await withFixture(capacity: 65_536) { fixture in
            let supervisor = try await ContextBudgetSupervisor.open(
                repository: fixture.repository,
                identity: fixture.identity,
                configuration: fixture.configuration,
                clock: fixture.clock
            )
            _ = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .afterProviderTurn,
                providerResponseID: "resp-config",
                measurement: .providerExact(usedTokens: 1_000)
            ))
            let updatedConfiguration = ContextBudgetConfiguration(
                capacity: ContextCapacityResolution(
                    providerID: "lmstudio",
                    providerVersionFingerprint: "fixture-v2",
                    modelKey: "fixture/model",
                    activeInstanceID: "fixture-instance-v2",
                    capacity: 98_304,
                    maximumContextLength: 131_072,
                    requiresModelLoad: false
                ),
                reserves: fixture.configuration.reserves,
                policy: fixture.configuration.policy
            )
            let changed = try await supervisor.reconfigure(updatedConfiguration)
            XCTAssertEqual(changed.observation.triggerPoint, .providerConfigurationChanged)
            XCTAssertEqual(changed.observation.capacity, 98_304)
            let restored = try await ContextBudgetSupervisor.restore(
                repository: fixture.repository,
                identity: fixture.identity,
                clock: fixture.clock
            )
            let snapshot = await restored.snapshot()
            XCTAssertEqual(snapshot.state.configuration, updatedConfiguration)
        }
    }

    func testHysteresisPreventsCheckpointOscillation() async throws {
        try await withFixture(capacity: 4_096) { fixture in
            let supervisor = try await ContextBudgetSupervisor.open(
                repository: fixture.repository,
                identity: fixture.identity,
                configuration: fixture.configuration,
                clock: fixture.clock
            )
            _ = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .afterProviderTurn,
                measurement: .providerExact(usedTokens: 100)
            ))
            let checkpoint = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .afterProviderTurn,
                measurement: .providerExact(usedTokens: 2_528)
            ))
            XCTAssertEqual(checkpoint.observation.action, .checkpoint)

            let insideMargin = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .afterProviderTurn,
                measurement: .providerExact(usedTokens: 2_478)
            ))
            XCTAssertEqual(insideMargin.observation.remaining, 850)
            XCTAssertEqual(insideMargin.observation.action, .checkpoint)

            let beyondMargin = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .afterProviderTurn,
                measurement: .providerExact(usedTokens: 2_378)
            ))
            XCTAssertEqual(beyondMargin.observation.remaining, 950)
            XCTAssertEqual(beyondMargin.observation.action, .normal)
        }
    }

    func testFreshSuccessorRequiresBoundedBootstrapObservationBeforeArming() async throws {
        try await withFixture(capacity: 8_192, requiresBootstrapReset: true) { fixture in
            let supervisor = try await ContextBudgetSupervisor.open(
                repository: fixture.repository,
                identity: fixture.identity,
                configuration: fixture.configuration,
                clock: fixture.clock
            )
            await assertBudgetError(code: "context_bootstrap_observation_required") {
                _ = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                    triggerPoint: .beforeProviderTurn,
                    measurement: .providerExact(usedTokens: 100)
                ))
            }
            let bootstrap = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                triggerPoint: .afterBootstrap,
                providerResponseID: "resp-bootstrap",
                measurement: .providerExact(usedTokens: 500)
            ))
            XCTAssertEqual(bootstrap.observation.action, .normal)
            let snapshot = await supervisor.snapshot()
            XCTAssertEqual(snapshot.state.bootstrapState, .armed)
        }

        try await withFixture(capacity: 8_192, requiresBootstrapReset: true) { fixture in
            let supervisor = try await ContextBudgetSupervisor.open(
                repository: fixture.repository,
                identity: fixture.identity,
                configuration: fixture.configuration,
                clock: fixture.clock
            )
            await assertBudgetError(code: "context_bootstrap_reset_not_satisfied") {
                _ = try await supervisor.evaluate(ContextBudgetEvaluationRequest(
                    triggerPoint: .afterBootstrap,
                    measurement: .providerExact(usedTokens: 5_000)
                ))
            }
            let observationCount = try await fixture.repository.contextBudgetObservationCount(
                identity: fixture.identity
            )
            XCTAssertEqual(observationCount, 0)
        }
    }

    private var smallReserves: ContextBudgetReserves {
        ContextBudgetReserves(
            outputTokens: 256,
            schemaTokens: 128,
            handoffTokens: 256,
            recoveryTokens: 128
        )
    }

    private var smallPolicy: ContextBudgetPolicy {
        ContextBudgetPolicy(initialProjectedNextTurnTokens: 128)
    }

    private func capacity(_ tokens: Int) -> ContextCapacityResolution {
        ContextCapacityResolution(
            providerID: "lmstudio",
            providerVersionFingerprint: "fixture-v1",
            modelKey: "fixture/model",
            activeInstanceID: "fixture-instance",
            capacity: tokens,
            maximumContextLength: max(tokens, 131_072),
            requiresModelLoad: false
        )
    }

    private func configuration(
        capacity tokens: Int,
        requiresBootstrapReset: Bool = false
    ) -> ContextBudgetConfiguration {
        ContextBudgetConfiguration(
            capacity: capacity(tokens),
            reserves: smallReserves,
            policy: smallPolicy,
            requiresBootstrapReset: requiresBootstrapReset
        )
    }

    private func withFixture(
        capacity tokens: Int,
        requiresBootstrapReset: Bool = false,
        _ body: (BudgetFixture) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-context-budget-\(UUID().uuidString)", isDirectory: true)
        let clock = BudgetTestClock(Date(timeIntervalSince1970: 10_000))
        let repository = try ProjectControlPlaneRepository(
            databaseURL: root.appendingPathComponent("control-plane.sqlite3"),
            clock: clock
        )
        do {
            let projectID = ProjectID()
            let projectRoot = root.appendingPathComponent("project", isDirectory: true)
            _ = try await repository.registerProjectUnchecked(
                projectID: projectID,
                displayName: "Context Budget Fixture",
                canonicalRoot: projectRoot
            )
            let run = try await repository.createAutonomousRun(AutonomousRunRequest(
                projectID: projectID,
                projectGeneration: .initial,
                mission: "Exercise deterministic context budget policy",
                providerID: "lmstudio",
                modelKey: "fixture/model",
                specification: AutonomousRunSpecification(
                    allowedTools: ["fixture.read"],
                    completionGates: ["tests"]
                ),
                authorizationScope: ToolAuthorizationScope(
                    canonicalRoots: [projectRoot],
                    allowedTools: ["fixture.read"],
                    networkAllowed: false,
                    maximumInlineOutputBytes: 64 * 1_024
                )
            ))
            let lease = try await repository.acquireRunLease(
                runID: run.runID,
                ownerID: "budget-manager"
            )
            let sessionID = "fixture-session-\(UUID().uuidString.lowercased())"
            try await repository.reserveProviderSession(
                ProviderSessionIntent(
                    sessionID: sessionID,
                    runID: run.runID,
                    projectID: projectID,
                    projectGeneration: .initial,
                    providerID: "lmstudio",
                    adapterID: "lmstudio-rest",
                    modelKey: "fixture/model",
                    providerResponseID: "resp-root-\(UUID().uuidString.lowercased())",
                    idempotencyKey: "fixture-session-key-\(UUID().uuidString.lowercased())",
                    contextCapacity: tokens
                ),
                lease: lease
            )
            _ = try await repository.releaseRunLease(lease)
            let identity = ContextBudgetIdentity(
                runID: run.runID,
                projectID: projectID,
                projectGeneration: .initial,
                sessionID: sessionID
            )
            try await body(BudgetFixture(
                repository: repository,
                identity: identity,
                configuration: configuration(
                    capacity: tokens,
                    requiresBootstrapReset: requiresBootstrapReset
                ),
                clock: clock
            ))
        } catch {
            await repository.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await repository.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func assertBudgetError(
        code: String,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected context budget error \(code)", file: file, line: line)
        } catch let error as ContextBudgetError {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private struct BudgetFixture {
    let repository: ProjectControlPlaneRepository
    let identity: ContextBudgetIdentity
    let configuration: ContextBudgetConfiguration
    let clock: BudgetTestClock
}

private final class BudgetTestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

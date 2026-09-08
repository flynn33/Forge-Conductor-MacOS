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
            XCTAssertEqual(emergency.observation.confidence, 0)
            XCTAssertEqual(emergency.observation.used, 64_000)
            XCTAssertNil(emergency.observation.accounting?.retainedInputTokens)
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

    func testTypedPolicyUsesLoadedCeilingAndOneAdmittedTotalEquation() throws {
        let policy = BudgetPolicy(context: BudgetContextPolicy(
            mode: .manual, maxContextTokens: 16_384, responseReserveTokens: 512,
            futureToolReserveTokens: 256, handoffReserveTokens: 256,
            recoveryReserveTokens: 128, safetyReserveTokens: 128,
            checkpointRatio: 0.70, rolloverRatio: 0.82, emergencyRatio: 0.94))
        let selection = try BudgetPolicyState(globalRevision: 7, globalPolicy: policy).resolve(.globalDefault)
        let configuration = try PersistedManagedRunBudgetEvaluator.configuration(
            capabilities: runtimeCapabilities(8_192), selection: selection)
        XCTAssertEqual(configuration.capacity.capacity, 8_192)
        XCTAssertEqual(configuration.resolvedPolicy?.requestedContextTokens, 16_384)
        XCTAssertEqual(configuration.resolvedPolicy?.verifiedLoadedContextTokens, 8_192)
        XCTAssertEqual(configuration.resolvedPolicy?.isClamped, true)
        XCTAssertEqual(configuration.reserves.schemaTokens, 0, "Serialized schemas belong to I")
        XCTAssertEqual(try configuration.reserves.fixedTotal(), 1_280)
        let thresholds = try ContextBudgetMath.thresholds(configuration: configuration, projectedNextTurn: 4_096)
        XCTAssertEqual(thresholds.checkpoint, 2_457)
        XCTAssertEqual(thresholds.rollover, 1_474)
        XCTAssertEqual(thresholds.emergency, 491)
        XCTAssertEqual(thresholds, try ContextBudgetMath.thresholds(configuration: configuration, projectedNextTurn: 0),
                       "Typed admitted-total ratios must not add already reserved capacity through EWMA")

        let increased = try PersistedManagedRunBudgetEvaluator.configuration(
            capabilities: runtimeCapabilities(32_768), selection: selection)
        XCTAssertEqual(increased.capacity.capacity, 16_384)
        XCTAssertEqual(increased.resolvedPolicy?.isClamped, false)
        XCTAssertEqual(increased.resolvedPolicy?.selection, selection)
        let impossible = BudgetPolicy(context: BudgetContextPolicy(mode: .manual, maxContextTokens: 16_384,
            responseReserveTokens: 8_000, handoffReserveTokens: 1_000))
        XCTAssertThrowsError(try PersistedManagedRunBudgetEvaluator.configuration(capabilities: runtimeCapabilities(8_192),
            selection: BudgetPolicyState(globalPolicy: impossible).resolve(.globalDefault)))
    }

    func testProviderUsageAggregationRejectsOverflowBeforeIntegerAdditionCanTrap() throws {
        for pair in [(Int.max, 1), (Int.min, -1), (Int.max, Int.max)] {
            XCTAssertThrowsError(try ProviderUsage(capacity: 8_192, inputTokens: pair.0,
                outputTokens: pair.1, source: .providerExact, confidence: 1)) { error in
                guard case ManagedModelProviderContractError.invalidValue = error else {
                    return XCTFail("Expected typed provider usage error, got \(error)")
                }
            }
        }
        let valid = try ProviderUsage(capacity: 8_192, inputTokens: 1_000, outputTokens: 200,
                                      source: .providerExact, confidence: 1)
        XCTAssertEqual(valid.totalTokens, 1_200)
    }

    func testUnknownOrInvalidLoadedCapacityCannotBecomeAnExactOperatorLimit() throws {
        let selection = try BudgetPolicyState(globalPolicy: BudgetPolicy(context:
            BudgetContextPolicy(mode: .manual, maxContextTokens: 8_192))).resolve(.globalDefault)
        let valid = try runtimeCapabilities(16_384)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["contextLength"] = 0
        let unknown = try JSONDecoder().decode(ProviderCapabilities.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try PersistedManagedRunBudgetEvaluator.configuration(capabilities: unknown, selection: selection))
        object["contextLength"] = 262_144
        let invalid = try JSONDecoder().decode(ProviderCapabilities.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try PersistedManagedRunBudgetEvaluator.configuration(capabilities: invalid, selection: selection),
                             "The manual clamp must not hide invalid provider capacity")
    }

    func testLegacyRemainingFractionsNormalizeWithoutRaisingOperatorThresholds() throws {
        let selection = try BudgetPolicyState.default.resolve(.globalDefault)
        let earlier = ContextBudgetPolicy(checkpointFraction: 0.96, rolloverFraction: 0.90, emergencyFraction: 0.05)
        let configuration = try PersistedManagedRunBudgetEvaluator.configuration(capabilities: runtimeCapabilities(32_768),
            policyOverride: earlier, selection: selection)
        let resolved = try XCTUnwrap(configuration.resolvedPolicy)
        XCTAssertEqual(resolved.effectiveCheckpointRatio, 0.04, accuracy: 0.000_001)
        XCTAssertEqual(resolved.effectiveRolloverRatio, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(resolved.effectiveEmergencyRatio, 0.95, accuracy: 0.000_001)
        XCTAssertEqual(resolved.selection.policy, selection.policy, "Requested values are preserved")
    }

    func testUnknownOverflowPersistsDecisionWithoutInventingInputTokens() async throws {
        try await withFixture(capacity: 8_192) { fixture in
            let supervisor = try await ContextBudgetSupervisor.open(repository: fixture.repository,
                identity: fixture.identity, configuration: fixture.configuration)
            let receipt = try await supervisor.evaluate(ContextBudgetEvaluationRequest(triggerPoint: .providerOverflow,
                measurement: .providerOverflow(lastKnownUsedTokens: nil)))
            XCTAssertEqual(receipt.observation.action, .emergency)
            XCTAssertEqual(receipt.observation.used, 0, "Compatibility fallback is not a fabricated capacity count")
            XCTAssertEqual(receipt.observation.confidence, 0)
            XCTAssertNil(receipt.observation.accounting?.retainedInputTokens)
            XCTAssertNil(receipt.observation.accounting?.admittedTotalTokens)
            let restored = try await ContextBudgetSupervisor.restore(repository: fixture.repository, identity: fixture.identity)
            let next = try await restored.observeToolResult(serializedBytes: 120, providerResponseID: "overflow-response")
            XCTAssertEqual(next.observation.source, .providerOverflow)
            XCTAssertNil(next.observation.accounting?.retainedInputTokens)
            XCTAssertEqual(next.observation.action, .emergency)
        }
    }

    func testPolicyResolutionChangesCachedSessionAndSurvivesEvaluatorRestart() async throws {
        try await withFixture(capacity: 16_384) { fixture in
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("forge-runtime-policy-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: home) }
            let store = ConfigStore(paths: AppPaths(home: home))
            let evaluator = PersistedManagedRunBudgetEvaluator(repository: fixture.repository,
                policyResolver: { try store.budgetPolicySelection(scope: $0) })
            let runValue = try await fixture.repository.autonomousRun(fixture.identity.runID)
            let run = try XCTUnwrap(runValue)
            let capabilities = try runtimeCapabilities(16_384)
            _ = try await evaluator.evaluateBeforeProviderTurn(run: run, sessionID: fixture.identity.sessionID,
                capabilities: capabilities, serializedInputBytes: 10_000)
            let beforeValue = try await fixture.repository.contextBudgetState(identity: fixture.identity)
            let before = try XCTUnwrap(beforeValue)
            XCTAssertEqual(before.configuration.resolvedPolicy?.selection.globalRevision, 1)
            let scope = BudgetPolicyScope(kind: .projectOverride, projectID: fixture.identity.projectID.description,
                                          projectGeneration: Int(exactly: fixture.identity.projectGeneration.rawValue))
            _ = try store.updateBudgetPolicy(BudgetPolicyUpdate(scope: scope, expectedRevision: 0,
                expectedGlobalRevision: 1, operation: .set,
                policy: BudgetPolicy(context: BudgetContextPolicy(mode: .manual, maxContextTokens: 4_096))))
            let action = try await evaluator.evaluateBeforeProviderTurn(run: run, sessionID: fixture.identity.sessionID,
                capabilities: capabilities, serializedInputBytes: 10_000)
            XCTAssertEqual(action, .emergency, "Tightening below consumed input pauses at this boundary")
            let afterValue = try await fixture.repository.contextBudgetState(identity: fixture.identity)
            let after = try XCTUnwrap(afterValue)
            XCTAssertEqual(after.latestObservation?.used, before.latestObservation?.used)
            XCTAssertEqual(after.configuration.capacity.capacity, 4_096)
            XCTAssertEqual(after.configuration.resolvedPolicy?.selection.revision, 1)
            XCTAssertEqual(after.configuration.resolvedPolicy?.selection.policySource, "project_override")
            let restartedStore = ConfigStore(paths: AppPaths(home: home))
            let restarted = PersistedManagedRunBudgetEvaluator(repository: fixture.repository,
                policyResolver: { try restartedStore.budgetPolicySelection(scope: $0) })
            _ = try await restarted.evaluateBeforeProviderTurn(run: run, sessionID: fixture.identity.sessionID,
                capabilities: runtimeCapabilities(2_048), serializedInputBytes: 10_000)
            let reconnectedValue = try await fixture.repository.contextBudgetState(identity: fixture.identity)
            let reconnected = try XCTUnwrap(reconnectedValue)
            XCTAssertEqual(reconnected.configuration.capacity.capacity, 2_048)
            XCTAssertEqual(reconnected.configuration.resolvedPolicy?.requestedContextTokens, 4_096)
            XCTAssertEqual(reconnected.configuration.resolvedPolicy?.selection.revision, 1)
        }
    }

    func testProviderAndLocalAccountingAvoidsHistorySchemaAndToolDeliveryDoubleCounting() async throws {
        try await withFixture(capacity: 65_536) { fixture in
            let selection = try BudgetPolicyState.default.resolve(.globalDefault)
            let evaluator = PersistedManagedRunBudgetEvaluator(repository: fixture.repository, policyResolver: { _ in selection })
            let runValue = try await fixture.repository.autonomousRun(fixture.identity.runID)
            let run = try XCTUnwrap(runValue)
            let capabilities = try runtimeCapabilities(65_536)
            let schema = String(repeating: "a", count: 64)
            let first = ManagedBudgetInputAccounting(inputBytes: 600, toolSchemaBytes: 300,
                toolSchemaSHA256: schema, pendingInputID: String(repeating: "b", count: 64), inputAlreadyRetained: false)
            _ = try await evaluator.evaluateBeforeProviderTurn(run: run, sessionID: fixture.identity.sessionID,
                capabilities: capabilities, accounting: first)
            let firstStateValue = try await fixture.repository.contextBudgetState(identity: fixture.identity)
            let firstState = try XCTUnwrap(firstStateValue)
            XCTAssertEqual(firstState.latestObservation?.used, 375)
            _ = try await evaluator.evaluateBeforeProviderTurn(run: run, sessionID: fixture.identity.sessionID,
                capabilities: capabilities, accounting: first)
            let retriedValue = try await fixture.repository.contextBudgetState(identity: fixture.identity)
            let retried = try XCTUnwrap(retriedValue)
            XCTAssertEqual(retried.latestObservation?.used, 375)
            let usage = try ProviderUsage(capacity: 65_536, inputTokens: 500, outputTokens: 200,
                totalTokens: 900, source: .providerExact, confidence: 1)
            let turn = try ProviderTurn(requestID: "account-request", responseID: "account-response", providerID: "lmstudio",
                providerVersion: "fixture", modelKey: "fixture/model", messages: ["response"], toolCalls: [],
                usage: usage, completed: true, finishReason: .stop)
            _ = try await evaluator.observeProviderTurn(turn, run: run, sessionID: fixture.identity.sessionID, capabilities: capabilities)
            let providerValue = try await fixture.repository.contextBudgetState(identity: fixture.identity)
            let provider = try XCTUnwrap(providerValue)
            XCTAssertEqual(provider.latestObservation?.used, 700, "Use explicit retained input/output, not aggregate total or local history")
            XCTAssertEqual(provider.latestObservation?.accounting?.rawProviderUsage?.totalTokens, 900)
            _ = try await evaluator.observeToolResult(serializedBytes: 240, providerResponseID: "account-response", run: run,
                sessionID: fixture.identity.sessionID, capabilities: capabilities)
            let toolValue = try await fixture.repository.contextBudgetState(identity: fixture.identity)
            let tool = try XCTUnwrap(toolValue)
            XCTAssertEqual(tool.latestObservation?.used, 800)
            let delivery = ManagedBudgetInputAccounting(inputBytes: 240, toolSchemaBytes: 300,
                toolSchemaSHA256: schema, pendingInputID: String(repeating: "c", count: 64), inputAlreadyRetained: true)
            _ = try await evaluator.evaluateBeforeProviderTurn(run: run, sessionID: fixture.identity.sessionID,
                capabilities: capabilities, accounting: delivery)
            let deliveredValue = try await fixture.repository.contextBudgetState(identity: fixture.identity)
            let delivered = try XCTUnwrap(deliveredValue)
            XCTAssertEqual(delivered.latestObservation?.used, 800)
            let observation = try XCTUnwrap(delivered.latestObservation)
            XCTAssertEqual(observation.accounting?.admittedTotalTokens, observation.used + observation.fixedReserve)
            XCTAssertEqual(observation.reserves.schemaTokens, 0)
            let history = try await fixture.repository.contextBudgetObservations(identity: fixture.identity)
            XCTAssertEqual(history.first(where: { $0.observationID == observation.observationID }), observation)
        }
    }

    private func runtimeCapabilities(_ tokens: Int) throws -> ProviderCapabilities {
        try ProviderCapabilities(providerID: "lmstudio", providerVersion: "fixture", modelKey: "fixture/model",
            providerInstanceID: "fixture-instance", contextLength: tokens, maximumContextLength: 131_072,
            statefulResponses: true, streaming: true, customTools: true, mcp: false,
            structuredOutput: true, usageReporting: true, idempotencyLookup: true,
            capabilityFingerprintSHA256: String(repeating: "a", count: 64))
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

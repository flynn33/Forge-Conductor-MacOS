import Foundation
import SQLite3
import XCTest
@testable import ForgeConductorCore

final class StjornarvaldObservationEvaluatorTests: XCTestCase {
    func testObservationSubmissionIsIdempotentBoundedAndDurableAcrossRestart() throws {
        let fixture = try EvaluationFixture()
        var repository: StjornarvaldObservationRepository? = try fixture.makeObservationRepository()
        let observation = fixture.observation(idempotencyKey: "observation-1", paths: ["App.swift"])

        let first = try repository!.submit(observation)
        XCTAssertEqual(try repository!.submit(observation), first)
        XCTAssertThrowsError(try repository!.submit(fixture.observation(
            id: observation.id,
            idempotencyKey: observation.idempotencyKey,
            paths: ["worker.py"]
        ))) { error in
            XCTAssertEqual(
                error as? StjornarvaldObservationError,
                .conflict("idempotency key already names different observation content")
            )
        }
        repository = nil

        repository = try fixture.makeObservationRepository()
        let pending = try repository!.pending(after: 0)
        XCTAssertEqual(pending.map(\.observation), [observation])
        XCTAssertEqual(pending.first?.sequence, first.sequence)

        let oversized = fixture.observation(
            idempotencyKey: "oversized",
            paths: [String(repeating: "x", count: 4_097)]
        )
        XCTAssertThrowsError(try repository!.submit(oversized))
    }

    func testObservationAndEvaluationHistoryAreAppendOnly() throws {
        let fixture = try EvaluationFixture()
        let repository = try fixture.makeObservationRepository()
        let observation = fixture.observation(idempotencyKey: "append-only", paths: ["App.swift"])
        let receipt = try repository.submit(observation)
        let identity = fixture.identity("append-only")
        _ = try repository.claimLease(identity: identity, duration: 30)
        _ = try repository.completeEvaluation(
            observationSequence: receipt.sequence,
            observationID: observation.id,
            identity: identity,
            findingCount: 0,
            detectorFaults: []
        )

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(fixture.database.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close(handle) }
        var message: UnsafeMutablePointer<CChar>?
        XCTAssertNotEqual(
            sqlite3_exec(handle, "UPDATE stj_observations SET received_at='changed';", nil, nil, &message),
            SQLITE_OK
        )
        XCTAssertTrue(message.map { String(cString: $0).contains("append-only") } ?? false)
        sqlite3_free(message)
        message = nil
        XCTAssertNotEqual(
            sqlite3_exec(handle, "DELETE FROM stj_observation_evaluations;", nil, nil, &message),
            SQLITE_OK
        )
        XCTAssertTrue(message.map { String(cString: $0).contains("append-only") } ?? false)
        sqlite3_free(message)
    }

    func testLeaseContentionExpiryAndCursorRecoverySelectOneEvaluator() throws {
        let fixture = try EvaluationFixture()
        let repository = try fixture.makeObservationRepository()
        let observation = fixture.observation(idempotencyKey: "lease-observation", paths: ["App.swift"])
        let receipt = try repository.submit(observation)
        let first = fixture.identity("first")
        let second = fixture.identity("second")
        let reincarnatedFirst = StjornarvaldEvaluatorIdentity(
            evaluatorID: first.evaluatorID,
            processID: first.processID + 1,
            bootID: "later-boot"
        )
        let start = Date(timeIntervalSince1970: 2_000_000_000)

        guard case .acquired(let firstLease) = try repository.claimLease(
            identity: first, duration: 1, now: start
        ) else { return XCTFail("first evaluator did not acquire lease") }
        XCTAssertEqual(firstLease.observationCursor, 0)
        guard case .contended(let reincarnationContention) = try repository.claimLease(
            identity: reincarnatedFirst, duration: 1, now: start.addingTimeInterval(0.25)
        ) else { return XCTFail("a reused evaluator ID bypassed the live process/boot lease") }
        XCTAssertEqual(reincarnationContention.owner, first)
        guard case .contended(let contended) = try repository.claimLease(
            identity: second, duration: 1, now: start.addingTimeInterval(0.5)
        ) else { return XCTFail("second evaluator did not observe contention") }
        XCTAssertEqual(contended.owner, first)
        guard case .acquired(let recovered) = try repository.claimLease(
            identity: second, duration: 2, now: start.addingTimeInterval(1.1)
        ) else { return XCTFail("expired lease was not recovered") }
        XCTAssertEqual(recovered.owner, second)
        XCTAssertThrowsError(try repository.renewLease(
            identity: first, duration: 2, now: start.addingTimeInterval(1.15)
        ))
        XCTAssertThrowsError(try repository.renewLease(
            identity: reincarnatedFirst, duration: 2, now: start.addingTimeInterval(1.15)
        ))

        _ = try repository.completeEvaluation(
            observationSequence: receipt.sequence,
            observationID: observation.id,
            identity: second,
            findingCount: 0,
            detectorFaults: [],
            now: start.addingTimeInterval(1.2)
        )
        guard case .acquired(let restarted) = try repository.claimLease(
            identity: first, duration: 2, now: start.addingTimeInterval(3.2)
        ) else { return XCTFail("restart did not recover expired lease") }
        XCTAssertEqual(restarted.observationCursor, receipt.sequence)
        XCTAssertEqual(try repository.evaluationReceipts().count, 1)
    }

    func testMissingPinnedRuleIndexLeavesObservationPending() async throws {
        let fixture = try EvaluationFixture()
        let observations = try fixture.makeObservationRepository()
        let rules = try fixture.makeRules()
        let log = try fixture.makeLog()
        let observation = fixture.observation(idempotencyKey: "rules-missing", paths: ["worker.py"])
        _ = try observations.submit(observation)
        let evaluator = StjornarvaldPolicyEvaluator(
            observationRepository: observations,
            ruleRepository: rules,
            detectorRegistry: StjornarvaldDetectorRegistry(
                detectors: [RavenNativeStackObservationDetector()]
            ),
            lifecycleService: StjornarvaldViolationLifecycleService(store: log),
            identity: fixture.identity("missing-rules")
        )

        do {
            _ = try await evaluator.runOnce()
            XCTFail("evaluation unexpectedly consumed an observation without the pinned rules")
        } catch let error as StjornarvaldObservationError {
            guard case .unavailable = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(try observations.pending(after: 0).map(\.observation.id), [observation.id])
        XCTAssertTrue(try observations.evaluationReceipts().isEmpty)
        XCTAssertTrue(try log.events().isEmpty)
    }

    func testEvaluatorIsolatesDetectorFaultAndProcessesObservationExactlyOnce() async throws {
        let fixture = try EvaluationFixture()
        let components = try fixture.makeEvaluator(detectors: [
            ThrowingObservationDetector(), RavenNativeStackObservationDetector(),
        ])
        let observation = fixture.observation(idempotencyKey: "fault-isolation", paths: ["worker.py"])
        _ = try components.observations.submit(observation)

        let first = try await components.evaluator.runOnce()
        XCTAssertEqual(first.processedObservationIDs, [observation.id])
        XCTAssertEqual(first.findingCount, 1)
        XCTAssertEqual(first.detectorFaultCount, 1)
        XCTAssertFalse(first.controlsExecution)
        XCTAssertEqual(try components.observations.detectorFaults().first?.detectorID, "throwing-fixture")
        XCTAssertEqual(try components.log.events().map(\.type), [.opened])

        let second = try await components.evaluator.runOnce()
        XCTAssertTrue(second.processedObservationIDs.isEmpty)
        XCTAssertEqual(try components.log.events().count, 1)
        XCTAssertEqual(try components.observations.evaluationReceipts().count, 1)
    }

    func testRepeatCorrectionAndReopenRemainOneStableViolation() async throws {
        let fixture = try EvaluationFixture()
        let components = try fixture.makeEvaluator(detectors: [RavenNativeStackObservationDetector()])
        let observations = [
            fixture.observation(idempotencyKey: "lifecycle-1", paths: ["worker.py"]),
            fixture.observation(idempotencyKey: "lifecycle-2", paths: ["moved/worker.py"]),
            fixture.observation(idempotencyKey: "lifecycle-3", paths: ["App.swift"]),
            fixture.observation(idempotencyKey: "lifecycle-4", paths: ["worker.py"]),
        ]
        for observation in observations { _ = try components.observations.submit(observation) }

        let report = try await components.evaluator.runOnce(maximumObservations: 8)
        XCTAssertEqual(report.processedObservationIDs, observations.map(\.id))
        XCTAssertEqual(report.findingCount, 4)
        let events = try components.log.events(limit: 10)
        XCTAssertEqual(events.map(\.type), [.opened, .repeated, .corrected, .reopened])
        XCTAssertEqual(Set(events.map(\.violationID)).count, 1)
        XCTAssertEqual(events.last?.candidate.rule.source.revision,
                       RavenForgeDevelopmentPolicyAdapter.identity.revision)
        XCTAssertTrue(events.allSatisfy(\.developmentContinues))
    }

    func testConditionIdentitySeparatesConditionsWithoutDestabilizingRepeats() throws {
        let fixture = try EvaluationFixture()
        let log = try fixture.makeLog()
        let rule = try XCTUnwrap(RavenForgeDevelopmentPolicyAdapter().rules().first)
        let first = fixture.candidate(
            rule: rule, observationID: UUID(), conditionIdentity: "runtime-a", summary: "First location"
        )
        let moved = fixture.candidate(
            rule: rule, observationID: UUID(), conditionIdentity: "runtime-a", summary: "Moved location"
        )
        let distinct = fixture.candidate(
            rule: rule, observationID: UUID(), conditionIdentity: "runtime-b", summary: "Distinct condition"
        )

        let opened = try log.record(first)
        let repeated = try log.record(moved)
        let other = try log.record(distinct)
        XCTAssertEqual(opened.id, repeated.id)
        XCTAssertEqual(repeated.occurrenceCount, 2)
        XCTAssertNotEqual(opened.id, other.id)
    }

    func testReplayAfterViolationCommitDoesNotDuplicateEvent() async throws {
        let fixture = try EvaluationFixture()
        let components = try fixture.makeEvaluator(detectors: [RavenNativeStackObservationDetector()])
        let observation = fixture.observation(idempotencyKey: "replay", paths: ["worker.py"])
        _ = try components.observations.submit(observation)
        let rules = try components.rules.rules()
        let findings = try await RavenNativeStackObservationDetector()
            .evaluate(observation: observation, rules: rules)
        let finding = try XCTUnwrap(findings.first)
        _ = try components.log.record(
            finding.candidate,
            eventID: StjornarvaldViolationLifecycleService.eventID(for: finding),
            occurredAt: observation.observedAt
        )

        let report = try await components.evaluator.runOnce()
        XCTAssertEqual(report.processedObservationIDs, [observation.id])
        XCTAssertEqual(try components.log.events().count, 1)
        XCTAssertEqual(try components.observations.evaluationReceipts().count, 1)
    }

    func testObservationOutboxReconcilesAfterRepositoryRecovery() throws {
        let fixture = try EvaluationFixture()
        let blocker = fixture.root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let database = blocker.appendingPathComponent("policy.sqlite3")
        let outbox = fixture.root.appendingPathComponent("observation-outbox", isDirectory: true)
        let observation = fixture.observation(idempotencyKey: "outbox", paths: ["App.swift"])
        var service: StjornarvaldObservationService? = StjornarvaldObservationService(
            databaseURL: database, outboxURL: outbox
        )
        XCTAssertEqual(
            service!.submitWithDisposition(observation),
            .deferred(observationID: observation.id)
        )
        let outboxFiles = try FileManager.default.contentsOfDirectory(
            at: outbox, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(outboxFiles.count, 1)
        XCTAssertEqual(try fixture.permissions(of: outbox), 0o700)
        XCTAssertEqual(try fixture.permissions(of: outboxFiles[0]), 0o600)
        service = nil

        try FileManager.default.removeItem(at: blocker)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        service = StjornarvaldObservationService(databaseURL: database, outboxURL: outbox)
        let recovered = try StjornarvaldObservationRepository(databaseURL: database)
        XCTAssertEqual(try recovered.pending(after: 0).map(\.observation), [observation])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outbox.path).isEmpty)
        XCTAssertEqual(service?.emergencyCount, 0)
    }

    func testObservationServiceRejectsMalformedAndConflictingInputWithoutOutboxing() throws {
        let fixture = try EvaluationFixture()
        let outbox = fixture.root.appendingPathComponent("service-outbox", isDirectory: true)
        let service = StjornarvaldObservationService(
            databaseURL: fixture.database, outboxURL: outbox
        )
        let accepted = fixture.observation(idempotencyKey: "service-accepted", paths: ["App.swift"])
        guard case .persisted = service.submitWithDisposition(accepted) else {
            return XCTFail("valid observation was not persisted")
        }
        let conflicting = fixture.observation(
            id: accepted.id,
            idempotencyKey: accepted.idempotencyKey,
            paths: ["worker.py"]
        )
        XCTAssertEqual(
            service.submitWithDisposition(conflicting),
            .rejected(observationID: conflicting.id)
        )
        let malformed = fixture.observation(
            idempotencyKey: "service-malformed",
            paths: [String(repeating: "x", count: 4_097)]
        )
        XCTAssertEqual(
            service.submitWithDisposition(malformed),
            .rejected(observationID: malformed.id)
        )
        let repository = try fixture.makeObservationRepository()
        XCTAssertEqual(try repository.pending(after: 0).map(\.observation), [accepted])
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.path))
    }

    func testObservationRepositoryCoexistsWithAllEarlierPolicyStores() throws {
        let fixture = try EvaluationFixture()
        let observations = try fixture.makeObservationRepository()
        _ = try observations.submit(fixture.observation(idempotencyKey: "coexist", paths: ["App.swift"]))
        _ = try fixture.makeLog()
        let rules = try fixture.makeRules()
        _ = try rules.installRavenBaseline()
        _ = try StjornarvaldPolicySourceCatalog(
            databaseURL: fixture.database,
            sourceStoreDirectory: fixture.root.appendingPathComponent("source-store", isDirectory: true)
        )
        XCTAssertEqual(try observations.pending(after: 0).count, 1)
    }
}

private struct ThrowingObservationDetector: PolicyObservationDetecting {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "fixture detector failed" }
    }

    let detectorID = "throwing-fixture"

    func evaluate(
        observation: DevelopmentObservation,
        rules: [PolicyRule]
    ) async throws -> [PolicyDetectorFinding] {
        throw Failure()
    }
}

private final class EvaluationFixture {
    struct Components {
        let observations: StjornarvaldObservationRepository
        let rules: StjornarvaldPolicyRuleRepository
        let log: StjornarvaldPolicyLogStore
        let evaluator: StjornarvaldPolicyEvaluator
    }

    let root: URL
    let database: URL
    let jsonl: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stjornarvald-evaluator-tests-\(UUID().uuidString)", isDirectory: true)
        database = root.appendingPathComponent("policy.sqlite3")
        jsonl = root.appendingPathComponent("policy.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func identity(_ suffix: String) -> StjornarvaldEvaluatorIdentity {
        StjornarvaldEvaluatorIdentity(
            evaluatorID: "fixture-\(suffix)", processID: 101, bootID: "fixture-boot"
        )
    }

    func observation(
        id: UUID = UUID(),
        idempotencyKey: String,
        paths: [String],
        complete: Bool = true
    ) -> DevelopmentObservation {
        DevelopmentObservation(
            id: id,
            idempotencyKey: idempotencyKey,
            kind: .projectConfigurationObserved,
            observedAt: Date(timeIntervalSince1970: 1_900_000_000),
            scope: DevelopmentObservationScope(projectID: "project-a", projectGeneration: 3),
            subjectIdentity: "ForgeConductor",
            summary: "Production target membership snapshot",
            evidenceReferences: ["target:ForgeConductor"],
            payloadSHA256: String(repeating: "a", count: 64),
            details: DevelopmentObservationDetails(nativeTarget: NativeTargetObservationEvidence(
                shippingRuntimePaths: paths, targetMembershipComplete: complete
            ))
        )
    }

    func candidate(
        rule: PolicyRule,
        observationID: UUID,
        conditionIdentity: String,
        summary: String
    ) -> PolicyViolationCandidate {
        PolicyViolationCandidate(
            rule: rule,
            observationID: observationID,
            scope: DevelopmentObservationScope(projectID: "project-a", projectGeneration: 3),
            subjectIdentity: "ForgeConductor",
            summary: summary,
            evidenceReferences: ["target:ForgeConductor"],
            explanation: summary,
            confidence: 0.99,
            suggestedCorrection: "Remove the runtime.",
            conditionIdentity: conditionIdentity
        )
    }

    func makeObservationRepository() throws -> StjornarvaldObservationRepository {
        try StjornarvaldObservationRepository(databaseURL: database)
    }

    func makeRules() throws -> StjornarvaldPolicyRuleRepository {
        try StjornarvaldPolicyRuleRepository(databaseURL: database)
    }

    func makeLog() throws -> StjornarvaldPolicyLogStore {
        try StjornarvaldPolicyLogStore(databaseURL: database, jsonlURL: jsonl)
    }

    func makeEvaluator(detectors: [any PolicyObservationDetecting]) throws -> Components {
        let observations = try makeObservationRepository()
        let rules = try makeRules()
        _ = try rules.installRavenBaseline()
        let log = try makeLog()
        let evaluator = StjornarvaldPolicyEvaluator(
            observationRepository: observations,
            ruleRepository: rules,
            detectorRegistry: StjornarvaldDetectorRegistry(detectors: detectors),
            lifecycleService: StjornarvaldViolationLifecycleService(store: log),
            identity: identity("manager")
        )
        return Components(observations: observations, rules: rules, log: log, evaluator: evaluator)
    }

    func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

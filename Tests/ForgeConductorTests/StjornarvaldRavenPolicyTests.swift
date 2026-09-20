import Foundation
import SQLite3
import XCTest
@testable import ForgeConductorCore

final class StjornarvaldRavenPolicyTests: XCTestCase {
    func testPinnedIdentityAndEveryInitialRuleRetainExactSourceProvenance() throws {
        let identity = RavenForgeDevelopmentPolicyAdapter.identity
        let rules = RavenForgeDevelopmentPolicyAdapter().rules()

        XCTAssertEqual(identity.version, "0.6.2")
        XCTAssertEqual(identity.revision, "ed0028a46bac9c5b92876a6ad6589ca421fd9499")
        XCTAssertEqual(identity.repositoryURL, "https://github.com/flynn33/raven-forge-development")
        XCTAssertEqual(rules.count, 15)
        XCTAssertEqual(Set(rules.map(\.id)).count, rules.count)
        XCTAssertEqual(Set(rules.map(\.policyArea)).count, 13)
        for rule in rules {
            XCTAssertEqual(rule.source.sourceID, identity.sourceID, rule.id.rawValue)
            XCTAssertEqual(rule.source.revision, identity.revision, rule.id.rawValue)
            XCTAssertTrue(rule.source.path.hasSuffix(".md"), rule.id.rawValue)
            XCTAssertTrue(rule.source.locator.hasPrefix("#"), rule.id.rawValue)
            XCTAssertNotNil(rule.details, rule.id.rawValue)
            XCTAssertFalse(rule.controlsExecution, rule.id.rawValue)
        }
    }

    func testRuleProjectionPersistsAndUtilityFailureCannotSuspendRules() throws {
        let fixture = try RavenFixture()
        var repository: StjornarvaldPolicyRuleRepository? = try fixture.makeRepository()
        let receipt = try repository!.installRavenBaseline(utility: ThrowingParityUtility())

        XCTAssertEqual(receipt.projectedRuleCount, 15)
        XCTAssertEqual(receipt.utilityObservation.state, .failed)
        XCTAssertEqual(try repository!.rules(limit: 100).count, 15)
        repository = nil

        repository = try fixture.makeRepository()
        XCTAssertEqual(try repository!.activeIdentity(), RavenForgeDevelopmentPolicyAdapter.identity)
        XCTAssertEqual(try repository!.rules(limit: 100).count, 15)
        XCTAssertEqual(try repository!.utilityObservations().first?.state, .failed)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(fixture.database.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close(handle) }
        var message: UnsafeMutablePointer<CChar>?
        XCTAssertNotEqual(
            sqlite3_exec(handle, "DELETE FROM stj_rule_projection_events;", nil, nil, &message),
            SQLITE_OK
        )
        XCTAssertTrue(message.map { String(cString: $0).contains("append-only") } ?? false)
        sqlite3_free(message)
    }

    func testRuleCatalogParityAndSuccessfulUtilityObservation() throws {
        let expectedSourceLocations: [String: String] = [
            "RFD-NATIVE-001": "policy/Development_Principles.md#native-compiled-production-software",
            "RFD-OOP-001": "policy/Development_Principles.md#strict-object-oriented-responsibility",
            "RFD-MOD-001": "policy/Development_Principles.md#modularity-and-reuse",
            "RFD-REPO-001": "policy/System_Interpretation_and_Use.md#1-the-repository-is-an-authority-container-not-a-dependency-unit",
            "RFD-REAL-001": "policy/System_Interpretation_and_Use.md#4-demonstrate-understanding-through-system-realization-contracts",
            "RFD-SOURCE-001": "policy/System_Interpretation_and_Use.md#2-establish-the-actual-source-and-authority",
            "RFD-CONTRACT-001": "policy/Development_Principles.md#explicit-contracts",
            "RFD-TRUTH-001": "policy/Development_Principles.md#evidence-and-truthful-status",
            "RFD-FAIL-001": "policy/Development_Principles.md#security-privacy-and-failure-behavior",
            "RFD-TEST-001": "policy/Testing_Methodology.md#agent-testing-boundary",
            "RFD-INTEGRITY-001": "method/Repository_Project_Version_Integrity.md#native-project-integrity",
            "RFD-VERSION-001": "method/Repository_Project_Version_Integrity.md#version-integrity",
            "RFD-ATTR-001": "policy/Development_Principles.md#no-tool-attribution",
            "RFD-WORKFLOW-001": "method/Development_Workflow.md#enter-or-resume-the-session",
            "RFD-DELIVERY-001": "method/Development_Workflow.md#10-review-delivery-and-hand-off",
        ]
        let rules = RavenForgeDevelopmentPolicyAdapter().rules()
        XCTAssertEqual(Set(rules.map { $0.id.rawValue }), Set(expectedSourceLocations.keys))
        for rule in rules {
            XCTAssertEqual(
                rule.source.path + rule.source.locator,
                expectedSourceLocations[rule.id.rawValue],
                rule.id.rawValue
            )
        }

        let fixture = try RavenFixture()
        let repository = try fixture.makeRepository()
        let receipt = try repository.installRavenBaseline(utility: PassingParityUtility())
        XCTAssertEqual(receipt.utilityObservation.state, .passed)
        XCTAssertEqual(receipt.utilityObservation.utilityID, "raven-parity-fixture")
        XCTAssertEqual(try repository.rules().count, expectedSourceLocations.count)
    }

    func testRuleRepositoryCoexistsWithCatalogAndViolationLogInEitherOpenOrder() throws {
        let ruleFirst = try RavenFixture()
        let firstRules = try ruleFirst.makeRepository()
        _ = try firstRules.installRavenBaseline()
        _ = try ruleFirst.makeCatalog()
        _ = try ruleFirst.makeLog()

        let logFirst = try RavenFixture()
        _ = try logFirst.makeLog()
        _ = try logFirst.makeCatalog()
        let lastRules = try logFirst.makeRepository()
        _ = try lastRules.installRavenBaseline()
        XCTAssertEqual(try lastRules.rules().count, 15)
    }

    func testPrecedenceSelectsOwnerDirectionAndRecordsMaterialTieAsAmbiguous() throws {
        let adapter = RavenForgeDevelopmentPolicyAdapter()
        let rules = adapter.rules()
        let rule = try XCTUnwrap(rules.first)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let ordinary = PolicyInterpretationCandidate(
            rule: rule,
            interpretation: "General source interpretation",
            assumptions: ["General applicability"],
            priority: PolicyInterpretationPriority(
                sourceSpecificity: 50, revisionObservedAt: date, purposeAlignment: 90,
                workingBehaviorPreservation: 90
            )
        )
        let owner = PolicyInterpretationCandidate(
            rule: rule,
            interpretation: "Current owner interpretation",
            priority: PolicyInterpretationPriority(
                currentOwnerDirection: true, sourceSpecificity: 10,
                revisionObservedAt: date.addingTimeInterval(-100), purposeAlignment: 50,
                workingBehaviorPreservation: 50
            )
        )
        let selected = try XCTUnwrap(adapter.resolve([ordinary, owner]))
        XCTAssertEqual(selected.selected.interpretation, owner.interpretation)
        XCTAssertFalse(selected.isAmbiguous)

        let tied = PolicyInterpretationCandidate(
            rule: rules[1],
            interpretation: "Equally plausible alternative",
            assumptions: ["Project scope is unresolved"],
            priority: ordinary.priority
        )
        let ambiguous = try XCTUnwrap(adapter.resolve([ordinary, tied]))
        XCTAssertTrue(ambiguous.isAmbiguous)
        XCTAssertEqual(ambiguous.alternativeInterpretations.count, 1)
        XCTAssertTrue(ambiguous.assumptions.contains("Project scope is unresolved"))
        XCTAssertLessThanOrEqual(ambiguous.confidence, 0.5)
    }

    func testPrecedenceFollowsEveryPublishedPriorityLevel() throws {
        let adapter = RavenForgeDevelopmentPolicyAdapter()
        let rule = try XCTUnwrap(adapter.rules().first)
        let current = Date(timeIntervalSince1970: 1_800_000_000)

        func selected(
            preferred: PolicyInterpretationPriority,
            fallback: PolicyInterpretationPriority
        ) throws -> String {
            let candidates = [
                PolicyInterpretationCandidate(
                    rule: rule, interpretation: "fallback", priority: fallback
                ),
                PolicyInterpretationCandidate(
                    rule: rule, interpretation: "preferred", priority: preferred
                ),
            ]
            return try XCTUnwrap(adapter.resolve(candidates)).selected.interpretation
        }

        XCTAssertEqual(try selected(
            preferred: PolicyInterpretationPriority(currentOwnerDirection: true, revisionObservedAt: current),
            fallback: PolicyInterpretationPriority(currentProjectDecision: true, sourceSpecificity: 100,
                                                   revisionObservedAt: current.addingTimeInterval(1))
        ), "preferred")
        XCTAssertEqual(try selected(
            preferred: PolicyInterpretationPriority(currentProjectDecision: true, revisionObservedAt: current),
            fallback: PolicyInterpretationPriority(sourceSpecificity: 100,
                                                   revisionObservedAt: current.addingTimeInterval(1))
        ), "preferred")
        XCTAssertEqual(try selected(
            preferred: PolicyInterpretationPriority(sourceSpecificity: 51, revisionObservedAt: current),
            fallback: PolicyInterpretationPriority(sourceSpecificity: 50,
                                                   revisionObservedAt: current.addingTimeInterval(1))
        ), "preferred")
        XCTAssertEqual(try selected(
            preferred: PolicyInterpretationPriority(activeNormativeMaterial: true, revisionObservedAt: current),
            fallback: PolicyInterpretationPriority(activeNormativeMaterial: false,
                                                   revisionObservedAt: current.addingTimeInterval(1))
        ), "preferred")
        XCTAssertEqual(try selected(
            preferred: PolicyInterpretationPriority(revisionObservedAt: current),
            fallback: PolicyInterpretationPriority(revisionObservedAt: current.addingTimeInterval(-1),
                                                   purposeAlignment: 100)
        ), "preferred")
        XCTAssertEqual(try selected(
            preferred: PolicyInterpretationPriority(revisionObservedAt: current, purposeAlignment: 51),
            fallback: PolicyInterpretationPriority(revisionObservedAt: current, purposeAlignment: 50,
                                                   workingBehaviorPreservation: 100)
        ), "preferred")
        XCTAssertEqual(try selected(
            preferred: PolicyInterpretationPriority(revisionObservedAt: current,
                                                    workingBehaviorPreservation: 51),
            fallback: PolicyInterpretationPriority(revisionObservedAt: current,
                                                   workingBehaviorPreservation: 50)
        ), "preferred")
    }

    func testNativeStackDetectorProducesAlignedViolationAmbiguousAndCorrectionAssessments() throws {
        let rule = try XCTUnwrap(
            RavenForgeDevelopmentPolicyAdapter().rules().first { $0.id.rawValue == "RFD-NATIVE-001" }
        )
        let detector = RavenNativeStackDetector()
        let alignedEvidence = RavenNativeStackEvidence(
            subjectIdentity: "ForgeConductor", shippingRuntimePaths: ["Sources/App.swift"],
            evidenceReferences: ["target:ForgeConductor"], targetMembershipComplete: true
        )
        let aligned = detector.evaluate(alignedEvidence, rule: rule)
        XCTAssertEqual(aligned.state, .aligned)
        XCTAssertFalse(aligned.controlsExecution)

        let violation = detector.evaluate(
            RavenNativeStackEvidence(
                subjectIdentity: "ForgeConductor", shippingRuntimePaths: ["Runtime/worker.py"],
                evidenceReferences: ["target:ForgeConductor"], targetMembershipComplete: true
            ),
            rule: rule
        )
        XCTAssertEqual(violation.state, .violation)
        XCTAssertEqual(violation.rule.source.revision, RavenForgeDevelopmentPolicyAdapter.identity.revision)
        XCTAssertNotNil(violation.suggestedCorrection)

        let ambiguous = detector.evaluate(
            RavenNativeStackEvidence(
                subjectIdentity: "ForgeConductor", shippingRuntimePaths: ["Runtime/worker.py"],
                evidenceReferences: ["partial-project-snapshot"], targetMembershipComplete: false
            ),
            rule: rule
        )
        XCTAssertEqual(ambiguous.state, .ambiguous)
        XCTAssertFalse(ambiguous.assumptions.isEmpty)
        XCTAssertFalse(ambiguous.alternatives.isEmpty)

        let corrected = detector.evaluate(alignedEvidence, rule: rule, priorViolationOpen: true)
        XCTAssertEqual(corrected.state, .corrected)
        XCTAssertFalse(corrected.controlsExecution)
    }

    func testLegacyRulePayloadWithoutDetailsRemainsDecodable() throws {
        let rule = try XCTUnwrap(RavenForgeDevelopmentPolicyAdapter().rules().first)
        let encoded = try JSONEncoder().encode(rule)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "details")
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(PolicyRule.self, from: legacy)
        XCTAssertEqual(decoded.id, rule.id)
        XCTAssertNil(decoded.details)
        XCTAssertFalse(decoded.controlsExecution)
    }
}

private struct ThrowingParityUtility: RavenPolicyParityChecking {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "fixture utility unavailable" }
    }

    func verify(
        identity: GoverningPolicyIdentity,
        rules: [PolicyRule]
    ) throws -> RavenPolicyUtilityReport {
        throw Failure()
    }
}

private struct PassingParityUtility: RavenPolicyParityChecking {
    func verify(
        identity: GoverningPolicyIdentity,
        rules: [PolicyRule]
    ) throws -> RavenPolicyUtilityReport {
        XCTAssertEqual(identity.revision, RavenForgeDevelopmentPolicyAdapter.identity.revision)
        XCTAssertEqual(rules.count, 15)
        return RavenPolicyUtilityReport(
            utilityID: "raven-parity-fixture",
            summary: "Pinned identity and native rule catalog agree."
        )
    }
}

private final class RavenFixture {
    let root: URL
    let database: URL
    let store: URL
    let jsonl: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stjornarvald-raven-tests-\(UUID().uuidString)", isDirectory: true)
        database = root.appendingPathComponent("policy.sqlite3")
        store = root.appendingPathComponent("source-store", isDirectory: true)
        jsonl = root.appendingPathComponent("policy.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeRepository() throws -> StjornarvaldPolicyRuleRepository {
        try StjornarvaldPolicyRuleRepository(databaseURL: database)
    }

    func makeCatalog() throws -> StjornarvaldPolicySourceCatalog {
        try StjornarvaldPolicySourceCatalog(databaseURL: database, sourceStoreDirectory: store)
    }

    func makeLog() throws -> StjornarvaldPolicyLogStore {
        try StjornarvaldPolicyLogStore(databaseURL: database, jsonlURL: jsonl)
    }
}

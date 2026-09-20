// RavenForgeDevelopmentPolicyAdapter.swift
// What: Projects the pinned Raven Forge Development policy into native, source-linked rules.
// How: Immutable binding metadata and explicit Swift seeds retain exact revision/path/locator provenance.
// Why: The governing repository remains external while its applicable rules become queryable product data.

import Foundation

public struct RavenPolicyUtilityReport: Sendable, Equatable {
    public let utilityID: String
    public let summary: String

    public init(utilityID: String, summary: String) {
        self.utilityID = utilityID
        self.summary = summary
    }
}

public protocol RavenPolicyParityChecking: Sendable {
    func verify(
        identity: GoverningPolicyIdentity,
        rules: [PolicyRule]
    ) throws -> RavenPolicyUtilityReport
}

public enum RavenPolicyUtilityState: String, Codable, Sendable {
    case unavailable, passed, failed
}

public struct RavenPolicyUtilityObservation: Codable, Sendable, Equatable {
    public let state: RavenPolicyUtilityState
    public let utilityID: String?
    public let summary: String

    public init(state: RavenPolicyUtilityState, utilityID: String?, summary: String) {
        self.state = state
        self.utilityID = utilityID
        self.summary = summary
    }
}

public struct PolicyInterpretationPriority: Sendable, Equatable {
    public let currentOwnerDirection: Bool
    public let currentProjectDecision: Bool
    public let sourceSpecificity: Int
    public let activeNormativeMaterial: Bool
    public let revisionObservedAt: Date
    public let purposeAlignment: Int
    public let workingBehaviorPreservation: Int

    public init(
        currentOwnerDirection: Bool = false,
        currentProjectDecision: Bool = false,
        sourceSpecificity: Int = 0,
        activeNormativeMaterial: Bool = true,
        revisionObservedAt: Date,
        purposeAlignment: Int = 0,
        workingBehaviorPreservation: Int = 0
    ) {
        self.currentOwnerDirection = currentOwnerDirection
        self.currentProjectDecision = currentProjectDecision
        self.sourceSpecificity = min(max(sourceSpecificity, 0), 100)
        self.activeNormativeMaterial = activeNormativeMaterial
        self.revisionObservedAt = revisionObservedAt
        self.purposeAlignment = min(max(purposeAlignment, 0), 100)
        self.workingBehaviorPreservation = min(max(workingBehaviorPreservation, 0), 100)
    }
}

public struct PolicyInterpretationCandidate: Sendable, Equatable {
    public let rule: PolicyRule
    public let interpretation: String
    public let assumptions: [String]
    public let priority: PolicyInterpretationPriority

    public init(
        rule: PolicyRule,
        interpretation: String,
        assumptions: [String] = [],
        priority: PolicyInterpretationPriority
    ) {
        self.rule = rule
        self.interpretation = interpretation
        self.assumptions = assumptions
        self.priority = priority
    }
}

public struct PolicyInterpretationResolution: Sendable, Equatable {
    public let selected: PolicyInterpretationCandidate
    public let alternativeInterpretations: [String]
    public let assumptions: [String]
    public let confidence: Double
    public let isAmbiguous: Bool
}

public enum PolicyRuleAssessmentState: String, Codable, Sendable {
    case aligned, violation, ambiguous, corrected
}

public struct PolicyRuleAssessment: Codable, Sendable, Equatable {
    public let rule: PolicyRule
    public let state: PolicyRuleAssessmentState
    public let subjectIdentity: String
    public let summary: String
    public let evidenceReferences: [String]
    public let assumptions: [String]
    public let alternatives: [String]
    public let suggestedCorrection: String?
    public let confidence: Double
    public let controlsExecution: Bool

    public init(
        rule: PolicyRule,
        state: PolicyRuleAssessmentState,
        subjectIdentity: String,
        summary: String,
        evidenceReferences: [String],
        assumptions: [String] = [],
        alternatives: [String] = [],
        suggestedCorrection: String? = nil,
        confidence: Double
    ) {
        self.rule = rule
        self.state = state
        self.subjectIdentity = subjectIdentity
        self.summary = summary
        self.evidenceReferences = Array(evidenceReferences.prefix(64))
        self.assumptions = Array(assumptions.prefix(32))
        self.alternatives = Array(alternatives.prefix(32))
        self.suggestedCorrection = suggestedCorrection
        self.confidence = min(max(confidence, 0), 1)
        self.controlsExecution = false
    }
}

public struct RavenNativeStackEvidence: Sendable, Equatable {
    public let subjectIdentity: String
    public let shippingRuntimePaths: [String]
    public let evidenceReferences: [String]
    public let targetMembershipComplete: Bool

    public init(
        subjectIdentity: String,
        shippingRuntimePaths: [String],
        evidenceReferences: [String],
        targetMembershipComplete: Bool
    ) {
        self.subjectIdentity = subjectIdentity
        self.shippingRuntimePaths = Array(shippingRuntimePaths.prefix(10_000))
        self.evidenceReferences = Array(evidenceReferences.prefix(64))
        self.targetMembershipComplete = targetMembershipComplete
    }
}

public struct RavenNativeStackDetector: Sendable {
    public static let detectorID = "raven-native-stack-v1"
    private static let interpretedRuntimeExtensions: Set<String> = [
        "bash", "js", "mjs", "pl", "py", "rb", "sh", "zsh",
    ]

    public init() {}

    public func evaluate(
        _ evidence: RavenNativeStackEvidence,
        rule: PolicyRule,
        priorViolationOpen: Bool = false
    ) -> PolicyRuleAssessment {
        guard evidence.targetMembershipComplete else {
            return PolicyRuleAssessment(
                rule: rule,
                state: .ambiguous,
                subjectIdentity: evidence.subjectIdentity,
                summary: "Production target membership is incomplete; native-stack alignment is unresolved.",
                evidenceReferences: evidence.evidenceReferences,
                assumptions: ["The supplied target-membership snapshot is partial."],
                alternatives: [
                    "The listed script is support-only and absent from the shipped runtime.",
                    "The production target includes interpreted runtime behavior not present in this snapshot.",
                ],
                suggestedCorrection: "Capture the complete production target and shipped-resource membership.",
                confidence: 0.45
            )
        }
        let interpreted = evidence.shippingRuntimePaths.filter {
            Self.interpretedRuntimeExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
        }
        if !interpreted.isEmpty {
            return PolicyRuleAssessment(
                rule: rule,
                state: .violation,
                subjectIdentity: evidence.subjectIdentity,
                summary: "The shipped production runtime includes interpreted application source.",
                evidenceReferences: evidence.evidenceReferences + interpreted.prefix(16),
                suggestedCorrection: rule.details?.suggestedCorrection,
                confidence: 0.99
            )
        }
        return PolicyRuleAssessment(
            rule: rule,
            state: priorViolationOpen ? .corrected : .aligned,
            subjectIdentity: evidence.subjectIdentity,
            summary: priorViolationOpen
                ? "The current complete target snapshot no longer includes interpreted application source."
                : "The complete production target snapshot contains no interpreted application source.",
            evidenceReferences: evidence.evidenceReferences,
            confidence: 0.98
        )
    }
}

public struct RavenForgeDevelopmentPolicyAdapter: Sendable {
    public static let identity = GoverningPolicyIdentity(
        bindingID: "rune-forge-stjornarvald-raven-development-0.6.2",
        authority: "governing_policy",
        repositoryURL: "https://github.com/flynn33/raven-forge-development",
        version: "0.6.2",
        revision: "ed0028a46bac9c5b92876a6ad6589ca421fd9499",
        sourceID: PolicySourceID(UUID(uuidString: "90f159a4-a066-5dc8-8a18-ea3cb3910fd7")!)
    )
    public static let maximumResolutionCandidates = 64

    public init() {}

    public func rules() -> [PolicyRule] {
        [
            rule("RFD-NATIVE-001", "Native compiled Apple stack", "policy/Development_Principles.md",
                 "#native-compiled-production-software", "native_platform",
                 "Production Apple code uses Swift and native frameworks; scripts support tests, analysis, and automation rather than shipped application architecture.",
                 "Move shipping behavior to Swift and native frameworks or remove the interpreted runtime from the product target.",
                 ["product source and target membership", "runtime dependencies"], [RavenNativeStackDetector.detectorID]),
            rule("RFD-OOP-001", "Cohesive object responsibility", "policy/Development_Principles.md",
                 "#strict-object-oriented-responsibility", "architecture",
                 "Behavior belongs in cohesive objects with narrow interfaces, explicit collaborators, and owned lifecycle, state, persistence, and side effects.",
                 "Split responsibilities behind narrow protocols and constructor-injected services.",
                 ["mixed-responsibility types", "hidden service lookup"]),
            rule("RFD-MOD-001", "Module ownership and boundaries", "policy/Development_Principles.md",
                 "#modularity-and-reuse", "architecture",
                 "Modules own their implementation, state, persistence, lifecycle, and diagnostics; consumers use public contracts.",
                 "Restore a public boundary and move state and behavior to its owner.",
                 ["private store access", "peer internals", "shared tunnel"]),
            rule("RFD-REPO-001", "Repository is not a dependency unit", "policy/System_Interpretation_and_Use.md",
                 "#1-the-repository-is-an-authority-container-not-a-dependency-unit", "dependency",
                 "Classify repository roles and consume only exact selected runtime products; governance, specifications, examples, tools, and tests are not broad dependencies.",
                 "Remove broad acquisition and implement a product-owned realization or use an exact public product.",
                 ["repository copy", "submodule", "vendor directory", "broad linkage"]),
            rule("RFD-REAL-001", "Product-owned realization", "policy/System_Interpretation_and_Use.md",
                 "#4-demonstrate-understanding-through-system-realization-contracts", "realization",
                 "Selected systems become product-owned modules, services, composition, resources, guardrails, and documentation.",
                 "Implement the responsibility in application-owned files and prove the runtime path.",
                 ["renamed example", "unused dependency", "copied interface"]),
            rule("RFD-SOURCE-001", "Source revision and role clarity", "policy/System_Interpretation_and_Use.md",
                 "#2-establish-the-actual-source-and-authority", "source_authority",
                 "Authority sources retain repository, immutable revision, applicability, role classification, inspection scope, and visible gaps.",
                 "Record exact identity, role, coverage, and gaps.",
                 ["moving branch only", "role conflation", "snippet presented as full reading"]),
            rule("RFD-CONTRACT-001", "Consequential interfaces are explicit", "policy/Development_Principles.md",
                 "#explicit-contracts", "contracts",
                 "Consequential interfaces describe inputs, outputs, errors, cancellation, lifecycle, concurrency, compatibility, side effects, and verification.",
                 "Define a typed contract and test normal, failure, cancellation, and recovery behavior.",
                 ["untyped core boundary", "implicit transition or error"]),
            rule("RFD-TRUTH-001", "Truthful status and evidence", "policy/Development_Principles.md",
                 "#evidence-and-truthful-status", "evidence",
                 "Specified, realized, implemented, verified, accepted, and released are distinct states; reports identify exactly what their evidence establishes.",
                 "Correct the status and attach exact evidence.",
                 ["completion claim without tests", "simulation reported as hardware", "plan reported as implementation"]),
            rule("RFD-FAIL-001", "Failure behavior is designed", "policy/Development_Principles.md",
                 "#security-privacy-and-failure-behavior", "failure_behavior",
                 "Trust, destructive action, logging, cancellation, recovery, and partial failure have explicit design and enforcement.",
                 "Add explicit ownership, bounded retry, diagnostics, and failure-path tests.",
                 ["swallowed error", "non-recoverable partial state", "unbounded retry"]),
            rule("RFD-TEST-001", "Host-local testing boundary", "policy/Testing_Methodology.md",
                 "#agent-testing-boundary", "testing",
                 "Complete host-local and simulated verification without making additional physical hardware an implementation prerequisite.",
                 "Finish available checks and record any owner-operated physical follow-up precisely.",
                 ["work stopped for an extra device", "simulation reported as a physical pass"]),
            rule("RFD-INTEGRITY-001", "Native project integrity", "method/Repository_Project_Version_Integrity.md",
                 "#native-project-integrity", "integrity",
                 "Source, native project membership, resources, entitlements, dependencies, and build entry points form one deliverable.",
                 "Add missing membership and verify the actual product route.",
                 ["source absent from target", "resource absent", "package and Xcode divergence"]),
            rule("RFD-VERSION-001", "Version and documentation integrity", "method/Repository_Project_Version_Integrity.md",
                 "#version-integrity", "integrity",
                 "Product, build, schema, policy identities, and documentation agree with delivered behavior.",
                 "Reconcile versions and documentation, then regenerate provenance.",
                 ["version mismatch", "behavior without documentation", "stale artifact identity"]),
            rule("RFD-ATTR-001", "No model or tool attribution", "policy/Development_Principles.md",
                 "#no-tool-attribution", "attribution",
                 "Models and tools do not receive authorship, branding, or approval credit.",
                 "Remove automated-tool attribution while preserving human, historical, and legally required attribution.",
                 ["automated authorship label", "tool co-author trailer", "tool approval claim"]),
            rule("RFD-WORKFLOW-001", "Current task ownership", "method/Development_Workflow.md",
                 "#enter-or-resume-the-session", "workflow",
                 "The current assignment and durable record govern; historical state, examples, and unrelated handoffs do not replace them.",
                 "Return to the current assignment, verified checkout, and recorded scope.",
                 ["historical handoff displaces current task", "invented path", "unapproved scope expansion"],
                 interpretationKind: .workflow),
            rule("RFD-DELIVERY-001", "Coherent delivery and handoff", "method/Development_Workflow.md",
                 "#10-review-delivery-and-hand-off", "delivery",
                 "Review implementation, dependencies, governance, evidence, and repository state together and preserve the current handoff.",
                 "Complete the product slice, update records, and state limitations precisely.",
                 ["plan-only closeout", "review state reported as integration", "missing handoff"],
                 interpretationKind: .workflow),
        ]
    }

    public func resolve(
        _ candidates: [PolicyInterpretationCandidate]
    ) -> PolicyInterpretationResolution? {
        let bounded = Array(candidates.prefix(Self.maximumResolutionCandidates))
        guard !bounded.isEmpty else { return nil }
        let ordered = bounded.sorted { lhs, rhs in
            let comparison = compare(lhs.priority, rhs.priority)
            if comparison != 0 { return comparison > 0 }
            if lhs.rule.id.rawValue != rhs.rule.id.rawValue {
                return lhs.rule.id.rawValue < rhs.rule.id.rawValue
            }
            return lhs.interpretation < rhs.interpretation
        }
        let selected = ordered[0]
        let tied = ordered.dropFirst().filter { compare($0.priority, selected.priority) == 0 }
        let alternatives = tied.map(\.interpretation)
        let assumptions = Array((selected.assumptions + tied.flatMap(\.assumptions)).prefix(32))
        return PolicyInterpretationResolution(
            selected: selected,
            alternativeInterpretations: alternatives,
            assumptions: assumptions,
            confidence: alternatives.isEmpty ? selected.rule.confidence : min(selected.rule.confidence, 0.5),
            isAmbiguous: !alternatives.isEmpty
        )
    }

    private func rule(
        _ id: String,
        _ title: String,
        _ path: String,
        _ locator: String,
        _ area: String,
        _ statement: String,
        _ correction: String,
        _ evidence: [String],
        _ detectors: [String] = [],
        interpretationKind: PolicyRuleInterpretationKind = .explicitRule
    ) -> PolicyRule {
        PolicyRule(
            id: PolicyRuleID(id),
            source: PolicySourceReference(
                sourceID: Self.identity.sourceID,
                revision: Self.identity.revision,
                path: path,
                locator: locator
            ),
            statement: statement,
            policyArea: area,
            applicability: "Apply when observed development activity concerns this policy area.",
            confidence: 0.98,
            details: PolicyRuleDetails(
                title: title,
                interpretationKind: interpretationKind,
                interpretationNotes: [
                    "Native projection paraphrase; the pinned source remains authority.",
                ],
                evidencePatterns: evidence,
                suggestedCorrection: correction,
                detectorIDs: detectors,
                limitations: ["Evaluation depends on bounded observed evidence and may require ambiguity disclosure."]
            )
        )
    }

    private func compare(
        _ lhs: PolicyInterpretationPriority,
        _ rhs: PolicyInterpretationPriority
    ) -> Int {
        let pairs: [(Int, Int)] = [
            (lhs.currentOwnerDirection ? 1 : 0, rhs.currentOwnerDirection ? 1 : 0),
            (lhs.currentProjectDecision ? 1 : 0, rhs.currentProjectDecision ? 1 : 0),
            (lhs.sourceSpecificity, rhs.sourceSpecificity),
            (lhs.activeNormativeMaterial ? 1 : 0, rhs.activeNormativeMaterial ? 1 : 0),
        ]
        for (left, right) in pairs where left != right { return left > right ? 1 : -1 }
        if lhs.revisionObservedAt != rhs.revisionObservedAt {
            return lhs.revisionObservedAt > rhs.revisionObservedAt ? 1 : -1
        }
        if lhs.purposeAlignment != rhs.purposeAlignment {
            return lhs.purposeAlignment > rhs.purposeAlignment ? 1 : -1
        }
        if lhs.workingBehaviorPreservation != rhs.workingBehaviorPreservation {
            return lhs.workingBehaviorPreservation > rhs.workingBehaviorPreservation ? 1 : -1
        }
        return 0
    }
}

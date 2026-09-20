// StjornarvaldPolicyEvaluator.swift
// What: Evaluates durable observations through bounded independent detectors and records lifecycle events.
// How: One lease-owning actor advances a committed observation cursor after idempotent violation writes.
// Why: Policy findings must recover across restart while remaining an additive side channel.

import Foundation

public struct StjornarvaldDetectorRegistryResult: Sendable, Equatable {
    public let findings: [PolicyDetectorFinding]
    public let faults: [StjornarvaldDetectorFault]
}

public struct StjornarvaldEvaluationRunReport: Sendable, Equatable {
    public let leaseContended: Bool
    public let processedObservationIDs: [UUID]
    public let findingCount: Int
    public let detectorFaultCount: Int
    public let lastCommittedCursor: Int64
    public let controlsExecution: Bool

    public init(
        leaseContended: Bool,
        processedObservationIDs: [UUID],
        findingCount: Int,
        detectorFaultCount: Int,
        lastCommittedCursor: Int64
    ) {
        self.leaseContended = leaseContended
        self.processedObservationIDs = processedObservationIDs
        self.findingCount = findingCount
        self.detectorFaultCount = detectorFaultCount
        self.lastCommittedCursor = lastCommittedCursor
        self.controlsExecution = false
    }
}

public enum StjornarvaldLifecycleApplication: Sendable, Equatable {
    case recorded(PolicyViolation)
    case noPriorViolationToCorrect
    case alreadyCorrected(PolicyViolation)
}

public struct StjornarvaldDetectorRegistry: Sendable {
    public static let maximumDetectors = 64
    public static let maximumFindingsPerDetector = 64
    public static let maximumFindingsPerObservation = 256

    private let detectors: [any PolicyObservationDetecting]

    public init(detectors: [any PolicyObservationDetecting]) {
        self.detectors = Array(detectors.prefix(Self.maximumDetectors))
    }

    public func evaluate(
        observation: DevelopmentObservation,
        rules: [PolicyRule]
    ) async -> StjornarvaldDetectorRegistryResult {
        var findings: [PolicyDetectorFinding] = []
        var faults: [StjornarvaldDetectorFault] = []
        var deduplicationKeys: Set<String> = []

        for detector in detectors {
            if findings.count == Self.maximumFindingsPerObservation { break }
            do {
                let evaluated = try await detector.evaluate(observation: observation, rules: rules)
                for finding in evaluated.prefix(Self.maximumFindingsPerDetector) {
                    guard finding.detectorID == detector.detectorID else {
                        faults.append(StjornarvaldDetectorFault(
                            detectorID: detector.detectorID,
                            summary: "Detector returned a finding under a different detector identity."
                        ))
                        continue
                    }
                    let key = Self.findingKey(finding)
                    if deduplicationKeys.insert(key).inserted { findings.append(finding) }
                    if findings.count == Self.maximumFindingsPerObservation { break }
                }
            } catch {
                faults.append(StjornarvaldDetectorFault(
                    detectorID: detector.detectorID,
                    summary: Self.bounded(error.localizedDescription, bytes: 4_096)
                ))
            }
        }
        return StjornarvaldDetectorRegistryResult(
            findings: findings,
            faults: Array(faults.prefix(Self.maximumDetectors))
        )
    }

    private static func findingKey(_ finding: PolicyDetectorFinding) -> String {
        JSONSupport.sha256Hex([
            finding.detectorID,
            finding.disposition.rawValue,
            finding.candidate.rule.id.rawValue,
            finding.candidate.rule.source.revision,
            finding.candidate.scope.projectID ?? "",
            String(finding.candidate.scope.projectGeneration ?? -1),
            finding.candidate.subjectIdentity,
            finding.candidate.conditionIdentity ?? "",
        ].joined(separator: "\u{0}"))
    }

    private static func bounded(_ value: String, bytes maximum: Int) -> String {
        var result = ""
        var count = 0
        for character in value {
            let width = String(character).utf8.count
            if count + width > maximum { break }
            result.append(character)
            count += width
        }
        return result
    }
}

public struct RavenNativeStackObservationDetector: PolicyObservationDetecting {
    public let detectorID = RavenNativeStackDetector.detectorID

    public init() {}

    public func evaluate(
        observation: DevelopmentObservation,
        rules: [PolicyRule]
    ) async throws -> [PolicyDetectorFinding] {
        guard let nativeTarget = observation.details?.nativeTarget,
              let rule = rules.first(where: { $0.id.rawValue == "RFD-NATIVE-001" }) else {
            return []
        }
        let assessment = RavenNativeStackDetector().evaluate(
            RavenNativeStackEvidence(
                subjectIdentity: observation.subjectIdentity,
                shippingRuntimePaths: nativeTarget.shippingRuntimePaths,
                evidenceReferences: observation.evidenceReferences,
                targetMembershipComplete: nativeTarget.targetMembershipComplete
            ),
            rule: rule
        )
        let disposition: PolicyDetectorFindingDisposition = switch assessment.state {
        case .violation, .ambiguous: .violation
        case .aligned, .corrected: .correction
        }
        let candidate = PolicyViolationCandidate(
            rule: rule,
            observationID: observation.id,
            scope: observation.scope,
            subjectIdentity: observation.subjectIdentity,
            summary: assessment.summary,
            evidenceReferences: assessment.evidenceReferences,
            explanation: assessment.summary,
            confidence: assessment.confidence,
            assumptions: assessment.assumptions,
            alternatives: assessment.alternatives,
            suggestedCorrection: assessment.suggestedCorrection ??
                rule.details?.suggestedCorrection ?? "Review the source-linked policy rule.",
            conditionIdentity: "interpreted_shipping_runtime"
        )
        return [PolicyDetectorFinding(
            detectorID: detectorID, disposition: disposition, candidate: candidate
        )]
    }
}

public final class StjornarvaldViolationLifecycleService: @unchecked Sendable {
    private let store: StjornarvaldPolicyLogStore

    public init(store: StjornarvaldPolicyLogStore) {
        self.store = store
    }

    public func apply(
        _ finding: PolicyDetectorFinding,
        occurredAt: Date
    ) throws -> StjornarvaldLifecycleApplication {
        let eventID = Self.eventID(for: finding)
        switch finding.disposition {
        case .violation:
            return .recorded(try store.record(
                finding.candidate, eventID: eventID, occurredAt: occurredAt
            ))
        case .correction:
            guard let current = try store.violation(matching: finding.candidate) else {
                return .noPriorViolationToCorrect
            }
            if current.state == .corrected { return .alreadyCorrected(current) }
            return .recorded(try store.recordCorrection(
                violationID: current.id,
                candidate: finding.candidate,
                eventID: eventID,
                occurredAt: occurredAt
            ))
        }
    }

    static func eventID(for finding: PolicyDetectorFinding) -> UUID {
        let value = [
            finding.candidate.observationID.uuidString.lowercased(),
            finding.detectorID,
            finding.disposition.rawValue,
            finding.candidate.rule.id.rawValue,
            finding.candidate.subjectIdentity,
            finding.candidate.conditionIdentity ?? "",
        ].joined(separator: "\u{0}")
        var characters = Array(JSONSupport.sha256Hex(value).prefix(32))
        characters[12] = "5"
        characters[16] = "8"
        let raw = String(characters)
        return UUID(uuidString:
            "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-" +
                "\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20))"
        )!
    }
}

public actor StjornarvaldPolicyEvaluator {
    public static let maximumObservationsPerRun = 64

    private let observationRepository: StjornarvaldObservationRepository
    private let ruleRepository: StjornarvaldPolicyRuleRepository
    private let detectorRegistry: StjornarvaldDetectorRegistry
    private let lifecycleService: StjornarvaldViolationLifecycleService
    private let identity: StjornarvaldEvaluatorIdentity
    private let leaseDuration: TimeInterval
    private let clock: @Sendable () -> Date

    public init(
        observationRepository: StjornarvaldObservationRepository,
        ruleRepository: StjornarvaldPolicyRuleRepository,
        detectorRegistry: StjornarvaldDetectorRegistry,
        lifecycleService: StjornarvaldViolationLifecycleService,
        identity: StjornarvaldEvaluatorIdentity,
        leaseDuration: TimeInterval = 30,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.observationRepository = observationRepository
        self.ruleRepository = ruleRepository
        self.detectorRegistry = detectorRegistry
        self.lifecycleService = lifecycleService
        self.identity = identity
        self.leaseDuration = min(max(leaseDuration, 1), 300)
        self.clock = clock
    }

    public func runOnce(
        maximumObservations: Int = 32
    ) async throws -> StjornarvaldEvaluationRunReport {
        let claim = try observationRepository.claimLease(
            identity: identity, duration: leaseDuration, now: clock()
        )
        let lease: StjornarvaldEvaluatorLease
        switch claim {
        case .contended(let current):
            return StjornarvaldEvaluationRunReport(
                leaseContended: true, processedObservationIDs: [], findingCount: 0,
                detectorFaultCount: 0, lastCommittedCursor: current.observationCursor
            )
        case .acquired(let acquired):
            lease = acquired
        }

        guard try ruleRepository.activeIdentity() == RavenForgeDevelopmentPolicyAdapter.identity else {
            throw StjornarvaldObservationError.unavailable(
                "the pinned Raven policy identity is not installed"
            )
        }
        let rules = try ruleRepository.rules(limit: StjornarvaldPolicyRuleRepository.maximumQueryRules)
        guard !rules.isEmpty else {
            throw StjornarvaldObservationError.unavailable("the pinned Raven rule index is empty")
        }
        let observations = try observationRepository.pending(
            after: lease.observationCursor,
            limit: min(max(maximumObservations, 1), Self.maximumObservationsPerRun)
        )
        var processed: [UUID] = []
        var findingCount = 0
        var faultCount = 0
        var cursor = lease.observationCursor

        for sequenced in observations {
            _ = try observationRepository.renewLease(
                identity: identity, duration: leaseDuration, now: clock()
            )
            let evaluation = await detectorRegistry.evaluate(
                observation: sequenced.observation, rules: rules
            )
            for finding in evaluation.findings {
                _ = try lifecycleService.apply(finding, occurredAt: sequenced.observation.observedAt)
            }
            let receipt = try observationRepository.completeEvaluation(
                observationSequence: sequenced.sequence,
                observationID: sequenced.observation.id,
                identity: identity,
                findingCount: evaluation.findings.count,
                detectorFaults: evaluation.faults,
                now: clock()
            )
            processed.append(sequenced.observation.id)
            findingCount += receipt.findingCount
            faultCount += receipt.detectorFaultCount
            cursor = receipt.observationSequence
        }
        return StjornarvaldEvaluationRunReport(
            leaseContended: false,
            processedObservationIDs: processed,
            findingCount: findingCount,
            detectorFaultCount: faultCount,
            lastCommittedCursor: cursor
        )
    }
}

// StjornarvaldPolicyNotices.swift
// What: Formats bounded additive policy context and notice presentation.
// How: Pure renderers preserve stable ordering and enforce aggregate UTF-8 limits.
// Why: Coding agents need actionable policy evidence without changing execution authority.

import Foundation

public enum StjornarvaldPolicyNoticeFormatter {
    public static let maximumNoticeCount = 8
    public static let maximumPresentationBytes = 16 * 1_024

    public static func managedContext(
        _ snapshot: PolicyContextSnapshot,
        maximumBytes: Int = maximumPresentationBytes
    ) -> String? {
        guard !snapshot.pendingNotices.isEmpty else { return nil }
        var lines = [
            "STJORNARVALD POLICY CONTEXT",
            "Policy: \(bounded(snapshot.policyIdentity, bytes: 512))",
        ]
        if !snapshot.applicableRuleSummaries.isEmpty {
            lines.append("Applicable guidance:")
            for summary in snapshot.applicableRuleSummaries.prefix(maximumNoticeCount) {
                lines.append("- \(bounded(summary, bytes: 1_024))")
            }
        }
        lines.append("")
        lines.append("OPEN POLICY VIOLATIONS")
        lines.append(contentsOf: noticeLines(snapshot.pendingNotices))
        let footer = "These notices are recorded. Continue the assigned work.\n" +
            "Stjornarvald has not changed tools, run state, or completion authority."
        return bodyAndFooter(
            body: lines.joined(separator: "\n"), footer: footer,
            maximumBytes: boundedMaximum(maximumBytes)
        )
    }

    public static func interactivePresentation(
        notices: [CodingAgentPolicyNotice],
        maximumBytes: Int = maximumPresentationBytes
    ) -> String? {
        guard !notices.isEmpty else { return nil }
        var lines = ["STJORNARVALD POLICY NOTICE"]
        lines.append(contentsOf: noticeLines(notices))
        let footer = "Policy log: recorded by Rune Forge manager or pending local reconciliation.\n" +
            "Development continues; this notice did not change the tool result."
        return bodyAndFooter(
            body: lines.joined(separator: "\n"), footer: footer,
            maximumBytes: boundedMaximum(maximumBytes)
        )
    }

    private static func noticeLines(_ notices: [CodingAgentPolicyNotice]) -> [String] {
        notices.prefix(maximumNoticeCount).map { notice in
            let source = "\(notice.ruleReference.revision) / \(redacted(notice.ruleReference.path)) / " +
                notice.ruleReference.locator
            return "- \(notice.violationID): \(bounded(notice.summary, bytes: 1_024)). " +
                "Rule source: \(bounded(source, bytes: 1_024)). Suggested correction: " +
                "\(bounded(notice.suggestedCorrection, bytes: 1_024)). " +
                "Confidence: \(String(format: "%.2f", notice.confidence))."
        }
    }

    private static func boundedMaximum(_ value: Int) -> Int {
        min(max(value, 512), maximumPresentationBytes)
    }

    private static func bodyAndFooter(
        body: String,
        footer: String,
        maximumBytes: Int
    ) -> String {
        let boundedFooter = bounded(footer, bytes: maximumBytes)
        let separatorBytes = boundedFooter.isEmpty ? 0 : 1
        let bodyLimit = max(0, maximumBytes - boundedFooter.utf8.count - separatorBytes)
        let boundedBody = bounded(body, bytes: bodyLimit)
        if boundedBody.isEmpty { return boundedFooter }
        if boundedFooter.isEmpty { return boundedBody }
        return boundedBody + "\n" + boundedFooter
    }

    static func bounded(_ value: String, bytes maximum: Int) -> String {
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

    private static func redacted(_ value: String) -> String {
        (try? ProjectMemoryRedactor().redact(value)) ?? "<redacted>"
    }
}

public struct NoPolicyContextProvider: PolicyContextProviding, Sendable {
    public init() {}

    public func context(
        projectID: String,
        projectGeneration: Int,
        runID: String,
        sessionID: String?,
        deliveryID: String,
        maximumCount: Int,
        maximumBytes: Int
    ) async -> PolicyContextSnapshot {
        PolicyContextSnapshot(
            policyIdentity: RavenForgeDevelopmentPolicyAdapter.identity.bindingID,
            applicableRuleSummaries: [], pendingNotices: [], limitations: ["policy context unavailable"]
        )
    }

    public func presented(deliveryID: String) async {}
    public func deferred(deliveryID: String) async {}
}

public struct NoInteractivePolicyNoticeProvider: InteractivePolicyNoticeProviding, Sendable {
    public init() {}
    public func presentation(
        deliveryID: String,
        projectID: String?,
        projectGeneration: Int?,
        clientID: String,
        maximumCount: Int,
        maximumBytes: Int
    )
        -> PolicyNoticePresentation? { nil }
    public func didPresent(_ presentation: PolicyNoticePresentation) {}
}

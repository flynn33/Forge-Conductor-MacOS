// ManagerSettingsNormalizer.swift
// What: Validates and canonicalizes incoming manager configuration patches.
// How: It clamps numeric ranges, normalizes host/boolean values, and emits a typed patch.
// Why: Every settings entry path must enforce the same safe operating limits.

import Foundation

/// Pure settings-patch normalization (no process state).
public enum ManagerSettingsNormalizer {
    /// The public mutation boundary rejects malformed values before normalizing
    /// or writing any part of the patch. The legacy pure adapter remains below.
    public static func validated(_ patch: [String: Any]) throws -> [String: Any] {
        if let raw = patch["budget_update"] {
            guard patch.count == 1, let object = raw as? [String: Any] else {
                throw ManagerSettingsValidationError(field: "budget_update", reason: "policy_update_must_be_a_separate_transaction")
            }
            return ["budget_update": try BudgetPolicyUpdate.decode(dictionary: object).asDictionary()]
        }
        try validateLegacyBudgetKeys(patch)
        let fields: [(String, String, ClosedRange<Int>)] = [
            ("dashboard", "port", 1...65_535),
            ("dashboard", "refresh_interval_sec", 2...300),
            ("manager", "watchdog_interval_sec", 1...60),
            ("sessions", "idle_ttl_sec", 60...Int.max),
            ("shell", "default_timeout_sec", 1...600),
        ]
        for (section, key, range) in fields {
            guard let rawSection = patch[section] else { continue }
            guard let values = rawSection as? [String: Any] else {
                throw ManagerSettingsValidationError(field: section, reason: "expected_object")
            }
            guard let raw = values[key] else { continue }
            guard let value = intValue(raw), range.contains(value) else {
                throw ManagerSettingsValidationError(
                    field: section + "." + key,
                    reason: "expected_finite_integer_in_range",
                    permittedRange: "\(range.lowerBound)...\(range.upperBound)"
                )
            }
        }
        return normalize(patch)
    }

    /// Validate legacy config patches without normalizing or removing any of
    /// their unrelated fields. Revision-bearing budget updates use the typed
    /// CAS path and must be intercepted before calling this helper.
    public static func validateLegacyBudgetKeys(_ patch: [String: Any]) throws {
        var inspectedValues = 0
        try rejectUnknownBudgetKeys(patch, path: [], inspectedValues: &inspectedValues)
    }

    private static func rejectUnknownBudgetKeys(_ value: Any, path: [String], inspectedValues: inout Int) throws {
        inspectedValues += 1
        guard path.count <= 64, inspectedValues <= 131_072 else {
            throw ManagerSettingsValidationError(field: "settings", reason: "json_structure_too_large")
        }
        if let object = value as? [String: Any] {
            for (key, child) in object {
                guard key.utf8.count <= 1_024 else {
                    throw ManagerSettingsValidationError(field: "settings", reason: "json_field_name_too_long")
                }
                let childPath = path + [key]
                if key.lowercased().contains("budget") {
                    throw ManagerSettingsValidationError(field: childPath.joined(separator: "."), reason: "unknown_budget_field")
                }
                try rejectUnknownBudgetKeys(child, path: childPath, inspectedValues: &inspectedValues)
            }
        } else if let values = value as? [Any] {
            for (index, child) in values.enumerated() {
                try rejectUnknownBudgetKeys(child, path: path + [String(index)], inspectedValues: &inspectedValues)
            }
        }
    }

    public static func normalize(_ patch: [String: Any]) -> [String: Any] {
        var normalized: [String: Any] = [:]
        if let dash = patch["dashboard"] as? [String: Any] {
            var d: [String: Any] = [:]
            if let host = dash["host"] as? String {
                let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
                if DashboardRequestPolicy.isConfiguredLoopbackHost(trimmed) {
                    d["host"] = trimmed
                }
            }
            if let port = intValue(dash["port"]), (1...65_535).contains(port) {
                d["port"] = port
            }
            // Dashboard HTML refresh only — host telemetry is continuous via RealtimeMetricsEngine.
            if let refresh = intValue(dash["refresh_interval_sec"]) {
                d["refresh_interval_sec"] = min(max(refresh, 2), 300)
            }
            if !d.isEmpty { normalized["dashboard"] = d }
        }
        if let mgr = patch["manager"] as? [String: Any] {
            var m: [String: Any] = [:]
            if let v = mgr["auto_restart"] as? Bool { m["auto_restart"] = v }
            if let v = mgr["open_browser_on_start"] as? Bool { m["open_browser_on_start"] = v }
            if let v = intValue(mgr["watchdog_interval_sec"]) {
                m["watchdog_interval_sec"] = min(max(v, 1), 60)
            }
            if !m.isEmpty { normalized["manager"] = m }
        }
        if let sessions = patch["sessions"] as? [String: Any] {
            var s: [String: Any] = [:]
            if let ttl = intValue(sessions["idle_ttl_sec"]), ttl >= 60 {
                s["idle_ttl_sec"] = ttl
            }
            if !s.isEmpty { normalized["sessions"] = s }
        }
        if let shell = patch["shell"] as? [String: Any] {
            var s: [String: Any] = [:]
            if let enabled = shell["enabled"] as? Bool {
                s["enabled"] = enabled
            }
            if let t = intValue(shell["default_timeout_sec"]) {
                s["default_timeout_sec"] = min(max(t, 1), 600)
            }
            if !s.isEmpty { normalized["shell"] = s }
        }
        if let level = patch["log_level"] as? String {
            normalized["log_level"] = level
        }
        if let roots = patch["allowed_roots"] as? [String] {
            normalized["allowed_roots"] = canonicalAllowedRoots(roots)
        }
        return normalized
    }

    /// Returns an existing, absolute directory path suitable for project-root authority.
    /// Filesystem root is never a valid configured project root.
    public static func canonicalAllowedRoot(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard expanded.hasPrefix("/") else { return nil }

        let canonical = URL(fileURLWithPath: expanded, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard canonical.path != "/" else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: canonical.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return canonical.path
    }

    /// Canonicalizes, de-duplicates, and sorts configured roots for stable persistence and UI.
    public static func canonicalAllowedRoots(_ roots: [String]) -> [String] {
        Array(Set(roots.compactMap(canonicalAllowedRoot))).sorted()
    }

    /// Returns the exact canonical project root only when it is equal to or
    /// contained by a root explicitly authorized in Settings. A project root
    /// narrows configured authority; registration metadata never expands it.
    static func authorizedProjectRoot(
        _ projectRoot: URL,
        allowedRoots: [String]
    ) -> URL? {
        guard let canonicalProjectPath = canonicalAllowedRoot(projectRoot.path) else {
            return nil
        }
        let canonicalProjectRoot = URL(
            fileURLWithPath: canonicalProjectPath,
            isDirectory: true
        ).standardizedFileURL
        let configuredRoots = canonicalAllowedRoots(allowedRoots).map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
        guard configuredRoots.contains(where: {
            contains(canonicalProjectRoot, root: $0)
        }) else {
            return nil
        }
        return canonicalProjectRoot
    }

    private static func contains(_ candidate: URL, root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    public static func intValue(_ any: Any?) -> Int? {
        JSONSupport.exactInteger(any, allowString: true)
    }
}

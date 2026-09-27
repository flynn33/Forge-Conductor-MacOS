import Foundation

enum GuidedControlAnchor {
    static let knownIdentifiers: Set<String> = [
        "continuity-copy-project-id",
        "continuity-delete-packets",
        "continuity-packet-list",
        "continuity-project-list",
        "context-gauge",
        "project-clear-content",
        "project-clear-mode",
        "project-clear-reconcile",
        "project-register",
        "project-relink",
        "project-relink-reconcile",
        "project-remove",
        "project-reset",
        "project-reset-receipt",
        "provider-local-no-auth",
        "provider-run-contract-probe",
        "provider-test-connection",
        "run-cancel",
        "run-pause",
        "run-preparation-recovery",
        "run-resume",
        "run-retry",
        "run-start-confirm",
        "run-start-project",
        "run-tools-allow-all",
        "run-tools-restore-recommended",
        "run-tools-search",
        "run-tools-select-none",
        "runtime-job-cancel",
        "runtime-shell-enabled",
        "toolbar-auto-refresh",
        "toolbar-refresh",
    ]

    static func isKnown(_ identifier: String) -> Bool {
        knownIdentifiers.contains(identifier)
    }
}

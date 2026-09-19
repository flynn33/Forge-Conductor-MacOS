import Foundation

enum GuidedControlAnchor {
    static let knownIdentifiers: Set<String> = [
        "autonomy-start",
        "checkpoint-command",
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
        "provider-credential-action",
        "provider-run-contract-probe",
        "provider-test-connection",
        "provider-token",
        "rollover-command",
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

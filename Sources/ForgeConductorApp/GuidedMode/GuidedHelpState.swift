import Foundation

struct GuidedHelpState: Equatable, Sendable {
    let status: String
    let detail: String
    let recommendedAction: String?

    static func overview(for context: GuidedHelpContext) -> Self {
        switch context {
        case .autonomy, .autonomyStartTask, .autonomyToolSelection,
             .autonomyCompletionChecks:
            Self(
                status: "Manager-owned task preparation",
                detail: "Choose a project and instructions. Forge resolves the technical preparation.",
                recommendedAction: "Open Start Task to review readiness."
            )
        case .continuity, .continuitySaveProgress, .continuityFreshSession:
            Self(
                status: "Automatic continuity",
                detail: "Managed tasks are protected without manual identifiers or handoff setup.",
                recommendedAction: "Open a running task to inspect its current protection state."
            )
        case .provider, .providerCredential:
            Self(
                status: "Model connection",
                detail: "Normal task preparation reuses and checks the saved provider automatically.",
                recommendedAction: "Use Provider only when preparation requests a connection action."
            )
        case .runtimes, .runtimeJob:
            Self(
                status: "Task runtime support",
                detail: "Only runtimes required by the selected task should block its work.",
                recommendedAction: "Inspect a runtime when the current task reports it as required."
            )
        default:
            Self(
                status: "Guided Mode",
                detail: "This guide explains the current view without changing its state.",
                recommendedAction: nil
            )
        }
    }
}

@MainActor
extension AutonomyViewModel {
    var guidedHelpState: GuidedHelpState {
        if isLoading {
            return .init(
                status: "Checking task readiness",
                detail: "Forge is loading registered projects, the provider state, and managed runs.",
                recommendedAction: nil
            )
        }
        if projects.isEmpty {
            return .init(
                status: "A project is required",
                detail: "No registered project is available for a managed task.",
                recommendedAction: "Register or relink the project in Projects."
            )
        }
        if provider?.health != "reachable" && provider?.health != "contract_valid" {
            return .init(
                status: "Provider action is required",
                detail: "The saved model provider is not currently ready for a managed task.",
                recommendedAction: "Open Provider and test the saved connection."
            )
        }
        return .init(
            status: runs.isEmpty ? "Ready for a task" : "Managed tasks available",
            detail: runs.isEmpty
                ? "Forge has the project and provider prerequisites needed to prepare a task."
                : "Forge is tracking \(runs.count) managed task\(runs.count == 1 ? "" : "s").",
            recommendedAction: runs.isEmpty ? "Choose Start Task and provide instructions." : nil
        )
    }
}

@MainActor
extension ContinuityViewModel {
    var guidedHelpState: GuidedHelpState {
        if isLoading {
            return .init(
                status: "Checking continuity",
                detail: "Forge is loading durable checkpoint and successor-session state.",
                recommendedAction: nil
            )
        }
        if operations.isEmpty {
            return .init(
                status: "No continuity action is needed",
                detail: "There is no active or recent rollover operation. Managed tasks are still monitored automatically.",
                recommendedAction: nil
            )
        }
        let state = selectedOperation?.state.replacingOccurrences(of: "_", with: " ") ?? "available"
        return .init(
            status: "Continuity operation \(state)",
            detail: "Forge has \(operations.count) durable continuity operation\(operations.count == 1 ? "" : "s") to inspect.",
            recommendedAction: "Review the selected operation and its acknowledgment state."
        )
    }
}

@MainActor
extension ProviderViewModel {
    var guidedHelpState: GuidedHelpState {
        if isBusy {
            return .init(
                status: "Checking the provider",
                detail: "Forge is reconciling saved settings, available models, or connection health.",
                recommendedAction: nil
            )
        }
        if hasUnsavedChanges {
            return .init(
                status: "Provider changes are not saved",
                detail: "The endpoint, model, or credential action differs from the saved configuration.",
                recommendedAction: "Save the settings, then test the connection."
            )
        }
        if provider?.health == "reachable" || provider?.health == "contract_valid" {
            return .init(
                status: "Provider is ready",
                detail: "The saved provider and selected model are available to managed task preparation.",
                recommendedAction: nil
            )
        }
        return .init(
            status: configuration?.saved == true ? "Connection needs verification" : "Provider setup is required",
            detail: configuration?.saved == true
                ? "Settings are saved, but a usable connection has not been confirmed."
                : "No complete provider configuration is saved.",
            recommendedAction: configuration?.saved == true
                ? "Choose Test Connection."
                : "Enter the LM Studio endpoint and model, then save."
        )
    }
}

@MainActor
extension RuntimesViewModel {
    var guidedHelpState: GuidedHelpState {
        if isLoading {
            return .init(
                status: "Checking runtime support",
                detail: "Forge is loading shell policy, executable capabilities, and durable jobs.",
                recommendedAction: nil
            )
        }
        if let selectedJob {
            return .init(
                status: "Runtime job \(selectedJob.state.replacingOccurrences(of: "_", with: " "))",
                detail: "The selected \(selectedJob.runtimeKind) job is retained with bounded output and exit evidence.",
                recommendedAction: canCancelSelectedJob ? "Cancel only if the current task no longer needs this job." : nil
            )
        }
        return .init(
            status: jobs.isEmpty ? "No runtime jobs" : "Runtime jobs available",
            detail: jobs.isEmpty
                ? "No active or recent native runtime work requires attention."
                : "Select a job to inspect its state and bounded output.",
            recommendedAction: nil
        )
    }
}

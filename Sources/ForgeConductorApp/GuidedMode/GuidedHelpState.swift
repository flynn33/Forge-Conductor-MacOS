import Foundation

struct GuidedHelpState: Equatable, Sendable {
    let status: String
    let detail: String
    let recommendedAction: String?

    static func overview(for context: GuidedHelpContext) -> Self {
        switch context {
        case .continuity, .continuitySaveProgress, .continuityFreshSession:
            Self(
                status: "Automatic continuity",
                detail: "LM Studio sessions are protected automatically; the Continuity view manages only project-scoped data and maintenance.",
                recommendedAction: "Use Continuity to copy or delete a project ID, reset it, delete one of its instruction packages, or clear disposable cache."
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
                detail: "Forge is loading registered projects and provider state.",
                recommendedAction: nil
            )
        }
        if projects.isEmpty {
            return .init(
                status: "A project is required",
                detail: "No registered project is available to the LM Studio model.",
                recommendedAction: "Register or relink the project in Projects."
            )
        }
        if usesDesktopProviderPreparation, runPreparation?.state != "ready" {
            return .init(
                status: "Desktop provider action is required",
                detail: runPreparation?.detail
                    ?? "The selected desktop provider integration is not ready.",
                recommendedAction: "Open Provider and choose Repair Integration for the selected desktop provider."
            )
        }
        if !usesDesktopProviderPreparation,
           provider?.health != "reachable" && provider?.health != "contract_valid" {
            return .init(
                status: "Provider action is required",
                detail: "The saved model provider is not currently ready for LM Studio tool use.",
                recommendedAction: "Open Provider and choose Connect and Check for LM Studio."
            )
        }
        return .init(
            status: "Ready for LM Studio",
            detail: "Forge has the project and provider prerequisites needed for an ordinary LM Studio chat.",
            recommendedAction: "Open LM Studio and call get_forge_status."
        )
    }
}

@MainActor
extension ContinuityViewModel {
    var guidedHelpState: GuidedHelpState {
        if isLoading {
            return .init(
                status: "Checking continuity",
                detail: "Forge is loading project identities with saved continuity data.",
                recommendedAction: nil
            )
        }
        if projectIDs.isEmpty {
            return .init(
                status: "No continuity projects",
                detail: "Continuity runs automatically; project identities appear after data is saved.",
                recommendedAction: nil
            )
        }
        return .init(
            status: "Continuity projects",
            detail: "Forge has continuity data for \(projectIDs.count) project\(projectIDs.count == 1 ? "" : "s").",
            recommendedAction: "Select a project ID to copy it or delete its continuity data."
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
        let selectedID = selectedProviderID
        let selectedDescriptor = selectedID.flatMap { identifier in
            providerDescriptors.first(where: { $0.id == identifier })
        }
        let selectedIntegration = selectedID.flatMap { integration(for: $0) }
        let selectedOperation = currentProviderOperation.flatMap { operation in
            operation.providerID == selectedID ? operation : nil
        }
        if selectedDescriptor?.executionStrategy == .desktopPluginPull {
            if selectedDescriptor?.selectable != true {
                return .init(
                    status: "Desktop provider is not supported",
                    detail: selectedDescriptor?.detail
                        ?? "This desktop provider cannot currently receive a complete Forge assignment.",
                    recommendedAction: selectedIntegration?.receipt == nil
                        ? "Choose a supported execution provider."
                        : "Deactivate it and remove the legacy integration, then choose a supported provider."
                )
            }
            if let selectedOperation,
               (selectedOperation.phase == .awaitingUserAction
                || selectedOperation.phase == .failedRecoverable) {
                return .init(
                    status: "Desktop provider action is required",
                    detail: selectedOperation.detail
                        ?? "The selected desktop provider integration needs attention.",
                    recommendedAction: "Complete the named host action, then choose Repair Integration."
                )
            }
            if selectedIntegration?.receipt != nil, selectedOperation?.isTerminal != false {
                return .init(
                    status: "Desktop provider is ready",
                    detail: "The selected Forge-owned desktop integration has a verified deployment receipt. Live activation is checked again when a task starts.",
                    recommendedAction: nil
                )
            }
            return .init(
                status: "Desktop provider setup is required",
                detail: "The selected desktop provider does not yet have a verified Forge integration.",
                recommendedAction: "Choose Repair Integration for the selected desktop provider."
            )
        }
        if selectedID == nil {
            return .init(
                status: "An execution provider is required",
                detail: "No provider is selected for Forge MCP and continuity.",
                recommendedAction: "Activate LM Studio or a supported desktop provider."
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
                detail: "The saved provider and selected model are available to Forge MCP and continuity.",
                recommendedAction: nil
            )
        }
        return .init(
            status: configuration?.saved == true ? "Connection needs verification" : "Provider setup is required",
            detail: configuration?.saved == true
                ? "Settings are saved, but a usable connection has not been confirmed."
                : "No complete provider configuration is saved.",
            recommendedAction: configuration?.saved == true
                ? "Choose Connect and Check."
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

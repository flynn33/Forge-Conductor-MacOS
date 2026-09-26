// ContentView.swift
// What: Composes the persistent sidebar, active feature module, and global toolbar.
// How: A single AppTab switch selects one detail view while shared controls mutate
// AppModel; visible heading anchors make each rendered module automation-accessible.
// Why: Central composition keeps navigation ownership separate from feature views.

import Foundation
import SwiftUI

enum GuidedSetupStorage {
    static let legacyCompletionKey = "forge.setupTutorial.completed.v1"
    static let currentCompletionKey = "forge.guidedSetup.completed.v2"
    static let selectedStepKey = "forge.guidedSetup.step.v2"
    static let reviewedPreparationKey = "forge.guidedSetup.reviewedPreparation.v2"

    static func defaults() -> UserDefaults {
        guard let suiteName = ProcessInfo.processInfo.environment[
            "FORGE_GUIDED_SETUP_DEFAULTS_SUITE"
        ], !suiteName.isEmpty else {
            return .standard
        }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func shouldPresent(in defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: currentCompletionKey)
    }
}

struct GuidedSetupProgress: Equatable {
    enum Step: Int, Equatable {
        case manager
        case provider
        case project
        case instructions
        case configure
        case start
        case monitor
        case recover
    }

    enum PreparationState: Equatable {
        case unavailable
        case needsReview(fingerprint: String)
        case reviewed(fingerprint: String)
    }

    let managerReady: Bool
    let providerReady: Bool
    let projectIsRegistered: Bool
    let instructionPackageCount: Int
    let preparationFingerprint: String?
    let reviewedPreparationFingerprint: String
    let activeRunState: String?
    let needsAttention: Bool

    static func compose(
        managerReady: Bool,
        snapshot: RigOperationalSnapshot,
        reviewedPreparationFingerprint: String
    ) -> Self {
        Self(
            managerReady: managerReady,
            providerReady: GuidedSetupProviderStatus.compose(snapshot.selectedProvider).isReady,
            projectIsRegistered: snapshot.projectName != nil,
            instructionPackageCount: snapshot.projectTotalPackages,
            preparationFingerprint: snapshot.guidedSetupPreparationFingerprint,
            reviewedPreparationFingerprint: reviewedPreparationFingerprint,
            activeRunState: snapshot.activeRunState,
            needsAttention: snapshot.continuityBlockedCount > 0
                || snapshot.projectProgressState == "ATTENTION"
                || ["failed_recoverable", "failed_terminal"]
                    .contains(snapshot.activeRunState)
        )
    }

    var preparationState: PreparationState {
        guard managerReady,
              providerReady,
              projectIsRegistered,
              instructionPackageCount > 0,
              let preparationFingerprint else {
            return .unavailable
        }
        return reviewedPreparationFingerprint == preparationFingerprint
            ? .reviewed(fingerprint: preparationFingerprint)
            : .needsReview(fingerprint: preparationFingerprint)
    }

    var recommendedStep: Step {
        if !managerReady { return .manager }
        if !providerReady { return .provider }
        if !projectIsRegistered { return .project }
        if instructionPackageCount == 0 { return .instructions }
        if needsAttention { return .recover }
        if activeRunState != nil { return .monitor }
        if case .reviewed = preparationState { return .start }
        return .configure
    }
}

/// Provides the app's top-level split layout, toolbar, and feature-module routing.
///
/// `ContentView` is intentionally a composition boundary: feature views own their
/// presentation while `AppModel.AppTab` supplies the single navigation state.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(
        GuidedSetupStorage.currentCompletionKey,
        store: GuidedSetupStorage.defaults()
    ) private var guidedSetupCompleted = false
    @AppStorage(
        GuidedSetupStorage.selectedStepKey,
        store: GuidedSetupStorage.defaults()
    ) private var guidedSetupStep = 0
    @AppStorage(
        GuidedSetupStorage.reviewedPreparationKey,
        store: GuidedSetupStorage.defaults()
    ) private var reviewedPreparationFingerprint = ""
    @StateObject private var guidedMode = GuidedModeCoordinator()
    @State private var showingGuidedSetup = false

    private var rootPresentedGuide: Binding<GuidedHelpContext?> {
        Binding<GuidedHelpContext?>(
            get: {
                guard !guidedMode.hasNestedContext else { return nil }
                return guidedMode.presentedContext
            },
            set: { value in
                if value == nil { guidedMode.dismiss() }
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if model.isNavigationVisible {
                AppSidebarView(
                    selectedTab: model.selectedTab,
                    version: model.version,
                    lastError: model.lastError,
                    onSelect: model.selectTab
                )
                // Telemetry updates publish several unrelated AppModel fields per
                // frame. Keep the persistent navigation controls stable unless one
                // of their own visible inputs changes so an in-flight click cannot
                // be invalidated by a gauge refresh.
                .equatable()
                .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
            }

            // A dedicated container gives every selected module a stable
            // accessibility element. Applying an identifier directly to a
            // complex SwiftUI child is unreliable on macOS because the child
            // may flatten into its descendants and disappear from the AX tree.
            VStack(spacing: 0) {
                if guidedMode.isEnabled,
                   let entry = guidedMode.catalog?.entry(for: guidedMode.currentContext) {
                    GuidedInlineHelp(
                        entry: entry,
                        state: guidedMode.state(for: entry.context),
                        openGuide: { guidedMode.present() }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                ZStack {
                    selectedDetail
                }
            }
            .id(model.selectedTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(model.selectedTab.displayName) content")
            .accessibilityIdentifier("detail-\(model.selectedTab.accessibilityID)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.16), value: model.isNavigationVisible)
        .accessibilityIdentifier("root-split")
        .onAppear {
            guidedMode.select(model.selectedTab.guidedHelpContext)
            let arguments = CommandLine.arguments
            let allowAutomaticPresentation = !arguments.contains("--uitesting")
                || arguments.contains("--uitesting-show-guided-setup")
            if !guidedSetupCompleted, allowAutomaticPresentation {
                showingGuidedSetup = true
            }
        }
        .onChange(of: model.selectedTab) { _, tab in
            guidedMode.select(tab.guidedHelpContext)
        }
        .environmentObject(guidedMode)
        .sheet(isPresented: $showingGuidedSetup) {
            GuidedSetupWizardView(
                selectedStep: $guidedSetupStep,
                reviewedPreparationFingerprint: $reviewedPreparationFingerprint,
                managerReady: model.serviceActive,
                snapshot: model.rigOperationalSnapshot,
                onOpen: { tab in
                    model.selectTab(tab)
                    showingGuidedSetup = false
                },
                onComplete: {
                    guidedSetupCompleted = true
                    showingGuidedSetup = false
                }
            )
        }
        .sheet(item: rootPresentedGuide) { context in
            if let guidedCatalog = guidedMode.catalog {
                GuidedHelpSheet(
                    coordinator: guidedMode,
                    catalog: guidedCatalog,
                    context: context
                )
            } else {
                ContentUnavailableView(
                    "Guide unavailable",
                    systemImage: "questionmark.circle",
                    description: Text(guidedMode.catalogError ?? "The bundled guide could not be loaded.")
                )
                .padding(24)
                .frame(width: 520, height: 320)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation { model.toggleNavigation() }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("Show or hide navigation")
                .accessibilityIdentifier("toolbar-navigation")
            }
            ToolbarItem(placement: .primaryAction) {
                Group {
                    if model.selectedTab == .rig {
                        Button {
                            showingGuidedSetup = true
                        } label: {
                            Label(
                                "Guided Setup",
                                systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                            )
                            .labelStyle(.titleAndIcon)
                        }
                        .controlSize(.regular)
                        .help("Set up, start, monitor, and recover an automated project run")
                        .accessibilityIdentifier("toolbar-guided-setup")
                    }
                }
            }
            // Separate items (no HStack) so macOS applies native toolbar control scale.
            ToolbarItem(placement: .primaryAction) {
                Group {
                    if model.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityIdentifier("toolbar-loading")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Group {
                    if let updated = model.updated {
                        Text(updated, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .accessibilityIdentifier("toolbar-updated")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $model.autoRefresh) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Auto-refresh")
                .accessibilityIdentifier("toolbar-auto-refresh")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $guidedMode.isEnabled) {
                    Image(systemName: "sparkles.rectangle.stack")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show or hide contextual Guided Mode")
                .accessibilityLabel("Guided Mode")
                .accessibilityIdentifier("toolbar-guided-mode")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guidedMode.present()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .controlSize(.small)
                .help("Open the guide for the current view")
                .accessibilityIdentifier("toolbar-setup-guide")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refresh(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Refresh now")
                .accessibilityIdentifier("toolbar-refresh")
            }
        }
    }

    @ViewBuilder
    private var selectedDetail: some View {
        switch model.selectedTab {
        case .rig:
            RigDashboardView(onOpenGuidedSetup: {
                showingGuidedSetup = true
            })
        case .mcp:
            MCPServersView()
        case .agents:
            AgentsView()
        case .tools:
            ToolsView()
        case .feed:
            LiveFeedView()
        case .projects:
            operatorContent {
                ProjectsOperatorView(
                    client: model.operatorManagerClient,
                    onOpenProvider: { model.selectTab(.provider) }
                )
            }
        case .runeForge:
            operatorContent { RuneForgeOperatorView(client: model.operatorManagerClient) }
        case .autonomy:
            operatorContent {
                ProjectsOperatorView(
                    client: model.operatorManagerClient,
                    onOpenProvider: { model.selectTab(.provider) }
                )
            }
        case .continuity:
            operatorContent {
                ContinuityOperatorView(
                    client: model.operatorManagerClient,
                    onOpenAutonomy: { model.selectTab(.projects) },
                    onOpenProvider: { model.selectTab(.provider) }
                )
            }
        case .runtimes:
            operatorContent { RuntimesOperatorView(client: model.operatorManagerClient) }
        case .provider:
            operatorContent { ProviderOperatorView(client: model.operatorManagerClient) }
        case .evidence:
            operatorContent { EvidenceOperatorView(client: model.operatorManagerClient) }
        case .diagnostics:
            DiagnosticsView()
        case .manager:
            ManagerSettingsView()
        }
    }

    private func operatorContent<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        OperatorStartupContent(
            isReady: model.hasLoadedInitialSettings,
            isLoading: model.isBootstrapping,
            errorMessage: model.lastError,
            retry: model.bootstrap,
            content: content
        )
    }
}

struct GuidedSetupProviderStatus: Equatable {
    let isReady: Bool
    let label: String
    let detail: String

    static func compose(_ provider: RigProviderProjection) -> Self {
        guard provider.isReady else {
            return Self(
                isReady: false,
                label: "Next",
                detail: provider.id == nil
                    ? "Select and connect a model provider."
                    : provider.detail
            )
        }
        if provider.executionMode == .desktopHost {
            return Self(
                isReady: true,
                label: "Ready",
                detail: "\(provider.displayName) is ready for host-managed execution."
            )
        }
        return Self(
            isReady: true,
            label: "Ready",
            detail: provider.model.map { "Connected to \($0)." }
                ?? "The configured provider is reachable."
        )
    }
}

private struct GuidedSetupWizardView: View {
    private enum Kind {
        case manager
        case provider
        case project
        case instructions
        case configure
        case start
        case monitor
        case recover
    }

    private struct Step {
        let kind: Kind
        let title: String
        let symbol: String
        let purpose: String
        let readyWhen: String
        let actions: [String]
        let recovery: [String]
        let destinations: [(tab: AppModel.AppTab, label: String)]
    }

    private let steps: [Step] = [
        Step(
            kind: .manager,
            title: "Confirm Forge is ready",
            symbol: "gearshape.2",
            purpose: "The manager owns projects, provider configuration, automation, continuity, and durable recovery.",
            readyWhen: "Manager reports Running. It normally starts with Forge Conductor; manual lifecycle controls are only for recovery.",
            actions: [
                "Check the live status shown below.",
                "If Manager is stopped, open Manager and choose Start.",
            ],
            recovery: [
                "Use Restart only when the Manager view reports a concrete service error.",
                "Doctor is diagnostic evidence; it is not required before every run.",
            ],
            destinations: [(.manager, "Open Manager")]
        ),
        Step(
            kind: .provider,
            title: "Connect the model provider",
            symbol: "network",
            purpose: "Forge needs one reachable, tool-capable model before it can prepare autonomous work.",
            readyWhen: "Provider shows Ready. LM Studio names its validated model; desktop hosts show an active Forge integration and host-managed execution.",
            actions: [
                "For LM Studio, install/load a tool-capable model, then choose Connect and Check once.",
                "Forge discovers the local server, starts it when possible, selects a loaded compatible model, and validates the contract.",
                "For Claude Code Desktop or Codex Desktop, select the provider and let Forge install and verify its host integration.",
                "Grok Build remains visible for status, but it is not start-ready until its host exposes supported automatic task ingress.",
            ],
            recovery: [
                "If connection fails, keep LM Studio open with a model loaded and run Connect and Check again.",
                "For a desktop host, follow the exact activation or repair action shown on its Provider card.",
                "The Provider view shows the exact next action; no port guessing should be necessary for local LM Studio.",
            ],
            destinations: [(.provider, "Open Provider")]
        ),
        Step(
            kind: .project,
            title: "Register the project",
            symbol: "folder.badge.gearshape",
            purpose: "A registered project gives the run a stable identity and an exact authorized working folder.",
            readyWhen: "Projects shows the repository as Active with its current generation.",
            actions: [
                "Open Projects and choose Register Project.",
                "Select the repository itself. Registration authorizes that exact folder; adding its parent in Manager is not a normal prerequisite.",
                "Wait for the durable registration result before importing instructions.",
            ],
            recovery: [
                "If the folder moved, use Relink in Projects instead of registering a duplicate.",
                "If registration reports an identity conflict, follow the exact Projects recovery message.",
            ],
            destinations: [(.projects, "Open Projects")]
        ),
        Step(
            kind: .instructions,
            title: "Add and order instructions",
            symbol: "text.badge.plus",
            purpose: "Instruction packages define the work, allowed capabilities, completion requirements, and execution order.",
            readyWhen: "The selected project has at least one package containing readable instruction text.",
            actions: [
                "In Projects, choose Add Instructions and select a file, folder, ZIP, or .forgepackage.",
                "Review the package name, document count, capabilities, and package-defined completion requirements.",
                "Arrange multiple packages in the order they must run.",
            ],
            recovery: [
                "Unsupported sources are retained as attachments and do not block readable instructions. If a package has no readable instruction text, add a supported document.",
                "Completion requirements come from the instruction package, remain read-only in Forge, and are evaluated automatically.",
            ],
            destinations: [(.projects, "Open Instruction Packages")]
        ),
        Step(
            kind: .configure,
            title: "Review ordered work behavior",
            symbol: "slider.horizontal.3",
            purpose: "Before launch, confirm the model, tools, automatic completion evidence, retry behavior, and continuity defaults.",
            readyWhen: "Provider, project, and instructions are ready and the intended failure behavior is understood.",
            actions: [
                "For ordered packages, the package supplies its capabilities and completion requirements.",
                "Review the visible package order and each package's per-file catalog in Projects.",
                "Use Run Details only to inspect or control historical and current runs. Continuity remains automatic.",
            ],
            recovery: [
                "Forge repairs provider readiness automatically when possible. A preparation card appears only when a project, permission, or source choice requires your input.",
                "If a package requirement is incorrect, correct the instruction package; Forge configuration does not create or override package requirements.",
            ],
            destinations: [(.projects, "Open Projects")]
        ),
        Step(
            kind: .start,
            title: "Start the automated run",
            symbol: "play.circle.fill",
            purpose: "Choose the launch path that matches the instruction source; both paths create manager-owned durable runs.",
            readyWhen: "Projects shows ordered work running, or Project Runs shows the accepted managed task.",
            actions: [
                "For an ordered queue, open Projects and choose Start Ordered Work. Forge runs one package at a time in the displayed order.",
                "A package advances only after its current run satisfies completion checks; failure stops advancement for review.",
            ],
            recovery: [
                "If Start remains disabled, the same screen identifies the missing project, instructions, or provider readiness.",
                "If a start response is interrupted, use Reconcile with Manager; do not create a second task.",
            ],
            destinations: [
                (.projects, "Open Package Queue"),
                (.projects, "Open Project Runs"),
            ]
        ),
        Step(
            kind: .monitor,
            title: "Monitor the run",
            symbol: "gauge.with.dots.needle.67percent",
            purpose: "Use Dashboard for live progress and activity, then open the owning view when more detail or control is needed.",
            readyWhen: "Dashboard shows the current package, step, phase, work item, next action, model/tool activity, and policy events.",
            actions: [
                "Dashboard: overall health, current package and step, Managed Activity, orchestration, and resource load.",
                "Projects → Run Details: exact run state, completion checks, pause/resume/retry, and failure detail.",
                "Continuity: saved progress, context protection, rollover, and successor status.",
                "Rune Forge: policy observations and violation feed. Events & Evidence: durable audit detail.",
            ],
            recovery: [
                "A stale or unavailable Dashboard source is not a zero value; refresh and open the owning view.",
                "Use the latest named failure, policy violation, or next action—not an older activity row—as recovery authority.",
            ],
            destinations: [
                (.projects, "Open Run Details"),
                (.runeForge, "Open Policy Feed"),
            ]
        ),
        Step(
            kind: .recover,
            title: "Resolve issues and continue",
            symbol: "cross.case",
            purpose: "Forge preserves durable state and routes each issue to the view that owns the corrective action.",
            readyWhen: "No active run or continuity item reports an issue requiring operator action.",
            actions: [
                "Provider issue: open Provider and choose Connect and Check. Forge resumes the exact retained run automatically after the contract check passes.",
                "Automatic completion issue: Forge returns the run to work and re-evaluates it when more evidence is available.",
                "Package completion issue: correct the named evidence or the instruction package. Forge re-evaluates the retained run automatically.",
                "Continuity issue: read the exact detail and use its Open Provider or Open Project Runs action.",
                "Policy violation: inspect Rune Forge and Events & Evidence, correct the named policy condition, then retry when allowed.",
            ],
            recovery: [
                "Do not delete or duplicate an unsettled run to clear a warning. Retry or reconcile the existing durable identity.",
                "If the same issue remains, export Diagnostics and preserve the displayed run/event identifiers.",
            ],
            destinations: [
                (.projects, "Open Project Runs"),
                (.evidence, "Open Events & Evidence"),
            ]
        ),
    ]

    @Binding var selectedStep: Int
    @Binding var reviewedPreparationFingerprint: String
    let managerReady: Bool
    let snapshot: RigOperationalSnapshot
    let onOpen: (AppModel.AppTab) -> Void
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let index = min(max(selectedStep, 0), steps.count - 1)
        let step = steps[index]
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Guided Setup")
                        .font(.title2.bold())
                    Text("Set up, start, monitor, and recover an automated project run")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Next required step") {
                    selectedStep = progress.recommendedStep.rawValue
                }
                .disabled(progress.recommendedStep.rawValue == index)
                .accessibilityIdentifier("guided-setup-next-required")
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("guided-setup-close")
            }
            .padding(20)

            Divider()

            HSplitView {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { offset, item in
                            stepButton(item, index: offset)
                        }
                    }
                    .padding(12)
                }
                .frame(minWidth: 230, idealWidth: 250, maxWidth: 280)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        stepHeader(step, index: index)
                        statusCard(for: step)
                        guideSection("Ready when", symbol: "checkmark.seal", items: [step.readyWhen])
                        guideSection("What to do", symbol: "list.number", items: step.actions, numbered: true)
                        guideSection("If it needs attention", symbol: "wrench.and.screwdriver", items: step.recovery)
                        HStack(spacing: 10) {
                            ForEach(Array(step.destinations.enumerated()), id: \.offset) { _, destination in
                                Button(destination.label) {
                                    onOpen(destination.tab)
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier(
                                    "setup-guide-open-\(destination.tab.accessibilityID)"
                                )
                            }
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: 500, maxWidth: .infinity)
            }

            Divider()
            HStack {
                Text("Step \(index + 1) of \(steps.count) · Progress is saved when you leave the wizard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Back") { selectedStep = max(0, index - 1) }
                    .disabled(index == 0)
                if step.kind == .configure {
                    Button(
                        configurationReviewIsCurrent
                            ? "Continue to Start"
                            : "Confirm Review and Continue"
                    ) {
                        confirmConfigurationReview()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(progress.preparationFingerprint == nil)
                    .accessibilityIdentifier("setup-guide-confirm-review")
                } else if index == steps.count - 1 {
                    Button("Finish Guided Setup", action: onComplete)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("setup-guide-finish")
                } else {
                    Button("Next") { selectedStep = min(steps.count - 1, index + 1) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("setup-guide-next")
                }
            }
            .padding(16)
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 600, idealHeight: 680)
        .accessibilityIdentifier("setup-guide")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Guided Setup wizard")
        .onAppear {
            selectedStep = min(max(selectedStep, 0), steps.count - 1)
        }
    }

    private var progress: GuidedSetupProgress {
        .compose(
            managerReady: managerReady,
            snapshot: snapshot,
            reviewedPreparationFingerprint: reviewedPreparationFingerprint
        )
    }

    private var providerReady: Bool {
        progress.providerReady
    }

    private var needsAttention: Bool {
        progress.needsAttention
    }

    private var configurationReviewIsCurrent: Bool {
        if case .reviewed = progress.preparationState { return true }
        return false
    }

    private func confirmConfigurationReview() {
        guard let fingerprint = progress.preparationFingerprint else { return }
        reviewedPreparationFingerprint = fingerprint
        selectedStep = GuidedSetupProgress.Step.start.rawValue
    }

    private func stepButton(_ step: Step, index: Int) -> some View {
        let status = readiness(for: step)
        return Button {
            selectedStep = index
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(selectedStep == index ? Color.accentColor : Color.secondary.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Text("\(index + 1)")
                        .font(.caption.bold())
                        .foregroundStyle(selectedStep == index ? .white : .primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    Text(status.label)
                        .font(.caption2)
                        .foregroundStyle(status.color)
                }
                Spacer(minLength: 4)
                Image(systemName: status.symbol)
                    .foregroundStyle(status.color)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedStep == index ? Color.accentColor.opacity(0.12) : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("guided-setup-step-\(index + 1)")
    }

    private func stepHeader(_ step: Step, index: Int) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: step.symbol)
                .font(.system(size: 32))
                .foregroundStyle(.tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text("STEP \(index + 1) OF \(steps.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(step.title)
                    .font(.title2.bold())
                    .accessibilityIdentifier("guided-setup-step-title")
                Text(step.purpose)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusCard(for step: Step) -> some View {
        let status = readiness(for: step)
        return GroupBox("Current status") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.label).font(.headline)
                    Text(status.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("guided-setup-status")
    }

    private func guideSection(
        _ title: String,
        symbol: String,
        items: [String],
        numbered: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .top, spacing: 9) {
                    if numbered {
                        Text("\(offset + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.accentColor))
                    } else {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .padding(.top, 7)
                    }
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func readiness(for step: Step) -> (
        label: String,
        detail: String,
        symbol: String,
        color: Color
    ) {
        switch step.kind {
        case .manager:
            return managerReady
                ? ("Ready", "Manager is running.", "checkmark.circle.fill", .green)
                : ("Action required", "Manager is not running.", "exclamationmark.triangle.fill", .orange)
        case .provider:
            let providerStatus = GuidedSetupProviderStatus.compose(snapshot.selectedProvider)
            if providerStatus.isReady {
                return (
                    providerStatus.label,
                    providerStatus.detail,
                    "checkmark.circle.fill",
                    .green
                )
            }
            return (
                providerStatus.label,
                providerStatus.detail,
                "arrow.right.circle.fill",
                .accentColor
            )
        case .project:
            if let project = snapshot.projectName {
                return ("Ready", "\(project) is the current registered project.", "checkmark.circle.fill", .green)
            }
            return ("Next", "Register the repository you want Forge to operate on.", "arrow.right.circle.fill", .accentColor)
        case .instructions:
            if snapshot.projectTotalPackages > 0 {
                return ("Ready", "\(snapshot.projectTotalPackages) instruction package(s) are available.", "checkmark.circle.fill", .green)
            }
            return snapshot.projectName == nil
                ? ("Waiting", "Register a project first.", "clock", .secondary)
                : ("Next", "Add at least one instruction package.", "arrow.right.circle.fill", .accentColor)
        case .configure:
            let ready = managerReady && providerReady
                && snapshot.projectName != nil && snapshot.projectTotalPackages > 0
            if ready, configurationReviewIsCurrent {
                return (
                    "Review complete",
                    "This exact project, provider, and instruction package setup is ready to start.",
                    "checkmark.circle.fill",
                    .green
                )
            }
            return ready
                ? ("Ready to review", "The setup prerequisites are present.", "checkmark.circle.fill", .green)
                : ("Waiting", "Complete the earlier setup steps first.", "clock", .secondary)
        case .start:
            if let state = snapshot.activeRunState {
                return (
                    "Started",
                    "The current managed task reports "
                        + OperatorRunStatePresentation.displayName(state) + ".",
                    "play.circle.fill",
                    .green
                )
            }
            if snapshot.projectTotalPackages > 0 && providerReady {
                return ("Ready to start", "Choose ordered or direct launch.", "play.circle", .accentColor)
            }
            return ("Waiting", "Provider, project, and instructions must be ready.", "clock", .secondary)
        case .monitor:
            if let state = snapshot.activeRunState {
                return (needsAttention ? "Action required" : "Monitoring",
                        "The current task reports "
                            + OperatorRunStatePresentation.displayName(state) + ".",
                        needsAttention ? "exclamationmark.triangle.fill" : "waveform.path.ecg",
                        needsAttention ? .orange : .green)
            }
            return ("Ready", "Dashboard will populate when a managed task starts.", "gauge.with.dots.needle.67percent", .secondary)
        case .recover:
            if needsAttention {
                return ("Action required", "A run, package, or continuity item needs attention.", "exclamationmark.triangle.fill", .orange)
            }
            return ("No current issue", "Forge has not reported an active blocking condition.", "checkmark.circle.fill", .green)
        }
    }
}

/// Do not construct an operator screen (and its one-shot load task) until the
/// startup snapshot has configured the shared manager client router.
@MainActor
struct OperatorStartupContent<Content: View>: View {
    let isReady: Bool
    let isLoading: Bool
    let errorMessage: String?
    let retry: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isReady {
            content()
        } else {
            VStack(spacing: 12) {
                if isLoading {
                    ProgressView("Starting Forge Conductor…")
                } else {
                    Text(errorMessage ?? "Startup has not completed.")
                        .foregroundStyle(.secondary)
                    Button("Retry startup", action: retry)
                        .accessibilityIdentifier("operator-retry-startup")
                }
            }
            .padding(20)
            .accessibilityIdentifier("operator-startup")
        }
    }
}

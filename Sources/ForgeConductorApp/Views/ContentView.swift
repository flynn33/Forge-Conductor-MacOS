// ContentView.swift
// What: Composes the persistent sidebar, active feature module, and optional view controls.
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
    static let reviewProjectKey = "forge.guidedSetup.reviewProject.v1"

    static func defaults() -> UserDefaults {
        guard let suiteName = ProcessInfo.processInfo.environment[
            "FORGE_GUIDED_SETUP_DEFAULTS_SUITE"
        ], !suiteName.isEmpty else {
            return .standard
        }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func shouldPresentAutomatically(in defaults: UserDefaults) -> Bool {
        // Guided Setup is an explicit operator tool, not a launch-time modal.
        // Retain completion metadata so reopening the wizard can resume the
        // saved step, but never use an absent or migrated flag to cover the app.
        _ = defaults
        return false
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

/// Provides the app's top-level split layout, optional controls, and feature-module routing.
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
    @EnvironmentObject private var guidedMode: GuidedModeCoordinator
    @EnvironmentObject private var workbench: WorkbenchPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                if !workbench.enabledControls.isEmpty { globalControls }
                selectedModule
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GraphitePalette.canvas)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation((reduceMotion || GraphiteAccessibilityFixture.enabled) ? nil : .easeInOut(duration: 0.16), value: model.isNavigationVisible)
        .graphiteWorkbench()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("root-split")
        .onAppear {
            guidedMode.select(model.selectedTab.guidedHelpContext)
            if GuidedSetupStorage.shouldPresentAutomatically(
                in: GuidedSetupStorage.defaults()
            ) {
                workbench.isGuidedSetupPresented = true
            }
        }
        .onChange(of: model.selectedTab) { _, tab in
            guidedMode.select(tab.guidedHelpContext)
        }
        .environmentObject(guidedMode)
        .sheet(isPresented: $workbench.isGuidedSetupPresented) {
            GuidedSetupWizardView(
                selectedStep: $guidedSetupStep,
                reviewedPreparationFingerprint: $reviewedPreparationFingerprint,
                managerReady: model.serviceActive,
                snapshot: model.rigOperationalSnapshot,
                client: model.operatorManagerClient,
                onOpen: { tab in
                    model.selectTab(tab)
                    workbench.isGuidedSetupPresented = false
                },
                onComplete: {
                    guidedSetupCompleted = true
                    workbench.isGuidedSetupPresented = false
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
    }

    private var selectedModule: some View {
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
            .background(GraphitePalette.canvas)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(model.selectedTab.displayName) content")
            .accessibilityIdentifier("detail-\(model.selectedTab.accessibilityID)")
    }

    private var globalControls: some View {
        HStack(spacing: 8) {
            if model.isLoading {
                ProgressView().controlSize(.small)
                    .accessibilityIdentifier("toolbar-loading")
            } else if let updated = model.updated {
                Text(updated, style: .time)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(GraphitePalette.textMuted)
                    .accessibilityIdentifier("toolbar-updated")
            }
            Spacer(minLength: 8)
            if workbench.shows(.navigation) {
                Button {
                    withAnimation((reduceMotion || GraphiteAccessibilityFixture.enabled) ? nil : .easeInOut(duration: 0.16)) { model.toggleNavigation() }
                } label: {
                    Label("Navigation", systemImage: "sidebar.leading")
                }
                .help("Show or hide navigation")
                .accessibilityIdentifier("toolbar-navigation")
            }
            if workbench.shows(.autoRefresh) {
                Toggle(isOn: $model.autoRefresh) {
                    Label("Auto-refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .toggleStyle(.button)
                .help("Auto-refresh")
                .accessibilityIdentifier("toolbar-auto-refresh")
            }
            if workbench.shows(.guidedMode) {
                Toggle(isOn: $guidedMode.isEnabled) {
                    Label("Guided Mode", systemImage: "sparkles.rectangle.stack")
                }
                .toggleStyle(.button)
                .help("Show or hide contextual Guided Mode")
                .accessibilityLabel("Guided Mode")
                .accessibilityIdentifier("toolbar-guided-mode")
            }
            if workbench.shows(.guide) {
                Button {
                    guidedMode.present()
                } label: {
                    Label("Guide", systemImage: "questionmark.circle")
                }
                .help("Open the guide for the current view")
                .accessibilityIdentifier("toolbar-setup-guide")
            }
            if workbench.shows(.refresh) {
                Button {
                    model.refresh(force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh now")
                .accessibilityIdentifier("toolbar-refresh")
            }
            if workbench.shows(.guidedSetup) {
                HStack(spacing: 0) {
                    Button {
                        workbench.isGuidedSetupPresented = true
                    } label: {
                        Label("Guided Setup", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .help("Review project setup, monitor progress, and recover work")
                    .accessibilityIdentifier("dashboard-guided-setup")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("toolbar-guided-setup")
            }
        }
        .controlSize(.regular)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(GraphitePalette.panelBottom)
        .overlay(alignment: .bottom) { Rectangle().fill(GraphitePalette.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workbench-global-controls")
    }

    @ViewBuilder
    private var selectedDetail: some View {
        switch model.selectedTab {
        case .rig:
            RigDashboardView()
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
                ContinuityOperatorView(client: model.operatorManagerClient)
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
            purpose: "Forge needs one reachable, tool-capable model for ordinary LM Studio chats to use its tools.",
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
            purpose: "A registered project gives LM Studio a stable identity and an exact default working folder.",
            readyWhen: "Projects shows the repository as Active with its current generation.",
            actions: [
                "Open Projects and choose “Add Project Folders…”.",
                "Select the repository itself. Registration records that exact project identity and default working folder; it does not confine native filesystem access.",
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
            title: "Review project inputs",
            symbol: "slider.horizontal.3",
            purpose: "Before starting in LM Studio, confirm the provider, project folders, instruction order, and Development Policy priority.",
            readyWhen: "Provider, project, and instructions are ready and the intended failure behavior is understood.",
            actions: [
                "Review the visible package order and each package's per-file catalog in Projects.",
                "Review the Development Policy source order in Rune Forge. The top source has highest priority.",
                "Continuity remains automatic; its view manages project-ID copy, history reset, selected-packet deletion, and disposable-cache clearing.",
            ],
            recovery: [
                "Use Provider → Connect and Check when LM Studio readiness requires attention.",
                "If a package requirement is incorrect, correct the instruction package; Forge configuration does not create or override package requirements.",
            ],
            destinations: [(.projects, "Open Projects")]
        ),
        Step(
            kind: .start,
            title: "Start in LM Studio",
            symbol: "play.circle.fill",
            purpose: "Project work begins in the LM Studio chat interface, where you interact with the model normally.",
            readyWhen: "LM Studio has a loaded tool-capable model and the Forge MCP integration is available.",
            actions: [
                "Open a chat in LM Studio and ask the model to call get_forge_status.",
                "Give the model the task. It can query the selected project, instruction, policy, and continuity locations through Forge.",
            ],
            recovery: [
                "If get_forge_status is unavailable, verify the LM Studio MCP registration and use Provider → Connect and Check.",
                "If more than one project is registered, pass the intended project_id returned by get_forge_status.",
            ],
            destinations: [
                (.projects, "Open Project Inputs"),
                (.provider, "Open Provider"),
            ]
        ),
        Step(
            kind: .monitor,
            title: "Monitor governance and continuity",
            symbol: "gauge.with.dots.needle.67percent",
            purpose: "Continue working in LM Studio while Forge enforces Development Policy and protects session continuity.",
            readyWhen: "Rune Forge reports policy observations and Forge accepts continuity handoffs from the active model chat.",
            actions: [
                "Rune Forge: ordered Development Policy sources, CLU policy observations, violations, and per-project log export.",
                "Continuity: copy project IDs or delete continuity data; rollover itself is automatic.",
                "Events & Evidence: durable audit detail.",
            ],
            recovery: [
                "A stale or unavailable Dashboard source is not a zero value; refresh and open the owning view.",
                "Use the latest named failure, policy violation, or next action—not an older activity row—as recovery authority.",
            ],
            destinations: [
                (.runeForge, "Open Policy Feed"),
                (.continuity, "Open Project IDs"),
            ]
        ),
        Step(
            kind: .recover,
            title: "Resolve issues and continue",
            symbol: "cross.case",
            purpose: "Forge preserves durable state and routes each issue to the view that owns the corrective action.",
            readyWhen: "Provider, policy enforcement, and continuity report no issue requiring operator action.",
            actions: [
                "Provider issue: keep LM Studio open with a model loaded, then choose Connect and Check.",
                "Instruction issue: correct or replace the named package in Projects, then ask the model to query Forge again.",
                "Continuity issue: preserve the handoff ID and inspect Provider plus Events & Evidence.",
                "Policy violation: CLU tells the model which policy was violated and supplies the applicable policy; inspect the per-project log in Rune Forge.",
            ],
            recovery: [
                "Do not delete continuity data while a handoff is being resumed.",
                "If the same issue remains, export Diagnostics and preserve the displayed project, handoff, and event identifiers.",
            ],
            destinations: [
                (.provider, "Open Provider"),
                (.evidence, "Open Events & Evidence"),
            ]
        ),
    ]

    @Binding var selectedStep: Int
    @Binding var reviewedPreparationFingerprint: String
    let managerReady: Bool
    private let baseSnapshot: RigOperationalSnapshot
    let onOpen: (AppModel.AppTab) -> Void
    let onComplete: () -> Void
    @StateObject private var reviewModel: GuidedSetupReviewViewModel
    @State private var reviewReloadToken = UUID()
    @AppStorage(GuidedSetupStorage.reviewProjectKey, store: GuidedSetupStorage.defaults())
    private var savedReviewProjectID = ""
    @Environment(\.dismiss) private var dismiss

    init(
        selectedStep: Binding<Int>,
        reviewedPreparationFingerprint: Binding<String>,
        managerReady: Bool,
        snapshot: RigOperationalSnapshot,
        client: any OperatorManagerClientProtocol,
        onOpen: @escaping (AppModel.AppTab) -> Void,
        onComplete: @escaping () -> Void
    ) {
        _selectedStep = selectedStep
        _reviewedPreparationFingerprint = reviewedPreparationFingerprint
        self.managerReady = managerReady
        baseSnapshot = snapshot
        self.onOpen = onOpen
        self.onComplete = onComplete
        _reviewModel = StateObject(wrappedValue: GuidedSetupReviewViewModel(client: client))
    }

    private var snapshot: RigOperationalSnapshot { reviewModel.snapshot(base: baseSnapshot) }

    var body: some View {
        let index = min(max(selectedStep, 0), steps.count - 1)
        let step = steps[index]
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Guided Setup")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Set up Forge, work in LM Studio, and monitor policy and continuity")
                        .foregroundStyle(GraphitePalette.textSecondary)
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
                        if [.project, .instructions, .configure].contains(step.kind) {
                            projectReviewScope
                        }
                        statusCard(for: step)
                        guideSection("Ready when", symbol: "checkmark.seal", items: [step.readyWhen])
                        guideSection("What to do", symbol: "list.number", items: step.actions, numbered: true)
                        guideSection("If it needs attention", symbol: "wrench.and.screwdriver", items: step.recovery)
                        HStack(spacing: 10) {
                            ForEach(Array(step.destinations.enumerated()), id: \.offset) { _, destination in
                                Button(destination.label) {
                                    onOpen(destination.tab)
                                }
                                .buttonStyle(GraphiteButtonStyle(kind: .primary))
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
                .id(index)
            }

            Divider()
            HStack {
                Text("Step \(index + 1) of \(steps.count) · Progress is saved when you leave the wizard")
                    .font(.system(size: 12))
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Back") { selectedStep = max(0, index - 1) }
                    .disabled(index == 0)
                if step.kind == .configure {
                    Button(
                        configurationReviewIsCurrent
                            ? "Continue to LM Studio"
                            : "Confirm Review and Continue"
                    ) {
                        confirmConfigurationReview()
                    }
                    .buttonStyle(GraphiteButtonStyle(kind: .primary))
                    .disabled(progress.preparationState == .unavailable)
                    .accessibilityIdentifier("setup-guide-confirm-review")
                } else if index == steps.count - 1 {
                    Button("Finish Guided Setup", action: onComplete)
                        .buttonStyle(GraphiteButtonStyle(kind: .primary))
                        .accessibilityIdentifier("setup-guide-finish")
                } else {
                    Button("Next") { selectedStep = min(steps.count - 1, index + 1) }
                        .buttonStyle(GraphiteButtonStyle(kind: .primary))
                        .accessibilityIdentifier("setup-guide-next")
                }
            }
            .padding(16)
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 600, idealHeight: 680)
        .graphiteWorkbench()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-guide")
        .accessibilityLabel("Guided Setup wizard")
        .onAppear {
            selectedStep = min(max(selectedStep, 0), steps.count - 1)
        }
        .task(id: reviewReloadToken) {
            let previousSelection = reviewModel.selectedProjectID
            await reviewModel.loadProjects(
                preferredProjectID: savedReviewProjectID.isEmpty ? nil : savedReviewProjectID
            )
            guard !Task.isCancelled else { return }
            if previousSelection == reviewModel.selectedProjectID {
                await reviewModel.loadSelection()
            }
        }
        .task(id: reviewModel.selectedProjectID) {
            await reviewModel.loadSelection()
        }
        .onChange(of: reviewModel.selectedProjectID) { _, projectID in
            if let projectID { savedReviewProjectID = projectID }
        }
    }

    private var projectReviewScope: some View {
        GraphitePanel(title: "Project to review") {
            HStack(alignment: .center, spacing: 10) {
                Picker("Registered project", selection: $reviewModel.selectedProjectID) {
                    Text("Choose a project").tag(Optional<String>.none)
                    ForEach(reviewModel.projects) { project in
                        Text(project.displayName).tag(Optional(project.projectID))
                    }
                }
                .pickerStyle(.menu)
                .buttonStyle(.bordered)
                .disabled(reviewModel.isLoadingProjects)
                .accessibilityIdentifier("guided-setup-project-selection")
                Button("Refresh", systemImage: "arrow.clockwise") {
                    reviewReloadToken = UUID()
                }
                .disabled(reviewModel.isLoading)
                .accessibilityIdentifier("guided-setup-review-refresh")
                if reviewModel.isLoading { ProgressView().controlSize(.small) }
            }
            if let project = reviewModel.selectedProject {
                Text(project.canonicalRoot)
                    .font(.system(size: 12)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(project.projectID) · generation \(project.projectGeneration)")
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("guided-setup-review-project-identity")
            }
            if let error = reviewModel.errorMessage {
                Text(error).foregroundStyle(GraphitePalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("guided-setup-review-error")
            } else if reviewModel.projects.isEmpty, !reviewModel.isLoading {
                Text("Register a project in Projects, then refresh this review.")
                    .foregroundStyle(GraphitePalette.textSecondary)
            }
            Text("Reviewing inputs does not activate a project or start a model session.")
                .font(.system(size: 13)).foregroundStyle(GraphitePalette.textSecondary)
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
        guard progress.preparationState != .unavailable,
              let fingerprint = progress.preparationFingerprint else { return }
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
                        .fill(selectedStep == index ? GraphitePalette.selectionTop : GraphitePalette.panelRaised)
                        .frame(width: 28, height: 28)
                    Text("\(index + 1)")
                        .font(.caption.bold())
                        .foregroundStyle(GraphitePalette.textPrimary)
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
                    .fill(LinearGradient(colors: selectedStep == index ? [GraphitePalette.selectionTop, GraphitePalette.selectionBottom] : [.clear, .clear], startPoint: .top, endPoint: .bottom))
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("guided-setup-step-\(index + 1)")
    }

    private func stepHeader(_ step: Step, index: Int) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: step.symbol)
                .font(.system(size: 32))
                .foregroundStyle(GraphitePalette.info)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text("STEP \(index + 1) OF \(steps.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GraphitePalette.textSecondary)
                Text(step.title)
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityIdentifier("guided-setup-step-title")
                Text(step.purpose)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                        .foregroundStyle(GraphitePalette.textSecondary)
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
            Label(title, systemImage: symbol).font(.system(size: 15, weight: .semibold))
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .top, spacing: 9) {
                    if numbered {
                        Text("\(offset + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(GraphitePalette.textPrimary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(GraphitePalette.selectionTop))
                    } else {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .padding(.top, 7)
                    }
                    Text(item).font(.system(size: 14)).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
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
                ? ("Ready", "Manager is running.", "checkmark.circle.fill", GraphitePalette.success)
                : ("Action required", "Manager is not running.", "exclamationmark.triangle.fill", GraphitePalette.warning)
        case .provider:
            let providerStatus = GuidedSetupProviderStatus.compose(snapshot.selectedProvider)
            if providerStatus.isReady {
                return (
                    providerStatus.label,
                    providerStatus.detail,
                    "checkmark.circle.fill",
                    GraphitePalette.success
                )
            }
            return (
                providerStatus.label,
                providerStatus.detail,
                "arrow.right.circle.fill",
                GraphitePalette.info
            )
        case .project:
            if let project = snapshot.projectName {
                return ("Ready", "\(project) is the current registered project.", "checkmark.circle.fill", GraphitePalette.success)
            }
            return ("Next", "Register the repository you want Forge to operate on.", "arrow.right.circle.fill", GraphitePalette.info)
        case .instructions:
            if snapshot.projectTotalPackages > 0 {
                return ("Ready", "\(snapshot.projectTotalPackages) instruction package(s) are available.", "checkmark.circle.fill", GraphitePalette.success)
            }
            return snapshot.projectName == nil
                ? ("Waiting", "Register a project first.", "clock", GraphitePalette.unavailable)
                : ("Next", "Add at least one instruction package.", "arrow.right.circle.fill", GraphitePalette.info)
        case .configure:
            let ready = managerReady && providerReady
                && snapshot.projectName != nil && snapshot.projectTotalPackages > 0
            if ready, configurationReviewIsCurrent {
                return (
                    "Review complete",
                    "This exact project, provider, and instruction package setup is ready to start.",
                    "checkmark.circle.fill",
                    GraphitePalette.success
                )
            }
            return ready
                ? ("Ready to review", "The setup prerequisites are present.", "checkmark.circle.fill", GraphitePalette.success)
                : ("Waiting", "Complete the earlier setup steps first.", "clock", GraphitePalette.unavailable)
        case .start:
            if snapshot.projectTotalPackages > 0 && providerReady {
                return (
                    "Ready in LM Studio",
                    "Open a normal LM Studio chat and call get_forge_status.",
                    "play.circle",
                    GraphitePalette.success
                )
            }
            return ("Waiting", "Provider, project, and instructions must be ready.", "clock", GraphitePalette.unavailable)
        case .monitor:
            return (
                needsAttention ? "Action required" : "Automatic",
                "CLU governance and continuity operate while you work in LM Studio.",
                needsAttention ? "exclamationmark.triangle.fill" : "waveform.path.ecg",
                needsAttention ? GraphitePalette.warning : GraphitePalette.success
            )
        case .recover:
            if needsAttention {
                return ("Action required", "A provider, package, policy, or continuity item needs attention.", "exclamationmark.triangle.fill", GraphitePalette.warning)
            }
            return ("No current issue", "Forge has not reported an active blocking condition.", "checkmark.circle.fill", GraphitePalette.success)
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
                        .foregroundStyle(GraphitePalette.textSecondary)
                    Button("Retry startup", action: retry)
                        .accessibilityIdentifier("operator-retry-startup")
                }
            }
            .padding(20)
            .accessibilityIdentifier("operator-startup")
        }
    }
}

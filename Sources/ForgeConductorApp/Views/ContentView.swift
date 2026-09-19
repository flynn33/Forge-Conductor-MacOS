// ContentView.swift
// What: Composes the persistent sidebar, active feature module, and global toolbar.
// How: A single AppTab switch selects one detail view while shared controls mutate
// AppModel; visible heading anchors make each rendered module automation-accessible.
// Why: Central composition keeps navigation ownership separate from feature views.

import SwiftUI

/// Provides the app's top-level split layout, toolbar, and feature-module routing.
///
/// `ContentView` is intentionally a composition boundary: feature views own their
/// presentation while `AppModel.AppTab` supplies the single navigation state.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("forge.setupTutorial.completed.v1") private var setupTutorialCompleted = false
    @State private var showingSetupTutorial = false

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
            ZStack {
                selectedDetail
            }
            .id(model.selectedTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail-\(model.selectedTab.accessibilityID)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.16), value: model.isNavigationVisible)
        .accessibilityIdentifier("root-split")
        .onAppear {
            if !setupTutorialCompleted,
               !CommandLine.arguments.contains("--uitesting") {
                showingSetupTutorial = true
            }
        }
        .sheet(isPresented: $showingSetupTutorial) {
            SetupTutorialView(
                onOpen: { tab in
                    model.selectTab(tab)
                    showingSetupTutorial = false
                },
                onComplete: {
                    setupTutorialCompleted = true
                    showingSetupTutorial = false
                }
            )
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
                Button {
                    showingSetupTutorial = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .controlSize(.small)
                .help("Open setup guide")
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
            operatorContent { ProjectsOperatorView(client: model.operatorManagerClient) }
        case .autonomy:
            operatorContent {
                AutonomyOperatorView(
                    client: model.operatorManagerClient,
                    onOpenProjects: { model.selectTab(.projects) },
                    onOpenProvider: { model.selectTab(.provider) }
                )
            }
        case .continuity:
            operatorContent { ContinuityOperatorView(client: model.operatorManagerClient) }
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

private struct SetupTutorialView: View {
    private struct Step {
        let title: String
        let symbol: String
        let summary: String
        let details: [String]
        let destination: AppModel.AppTab?
        let destinationLabel: String?
    }

    private let steps: [Step] = [
        Step(
            title: "Start LM Studio",
            symbol: "server.rack",
            summary: "Forge Conductor uses LM Studio as its local model provider.",
            details: [
                "In LM Studio, download and load a model that supports tool use.",
                "Open LM Studio's Developer screen and start the local server.",
                "The common local endpoint is http://127.0.0.1:1234.",
            ],
            destination: nil,
            destinationLabel: nil
        ),
        Step(
            title: "Configure Provider",
            symbol: "network",
            summary: "Provider tells Forge which LM Studio server and loaded model to use.",
            details: [
                "Open Provider and enter the LM Studio endpoint.",
                "Load Models, choose the model you loaded in LM Studio, then save.",
                "Run the connection and contract checks. Both should pass before autonomy starts.",
            ],
            destination: .provider,
            destinationLabel: "Open Provider"
        ),
        Step(
            title: "Authorize and Register",
            symbol: "folder.badge.gearshape",
            summary: "Forge limits model tools to project folders you explicitly authorize.",
            details: [
                "In Manager, add the parent folder that contains your repositories to Allowed Roots and apply the setting.",
                "Start the manager if it is stopped.",
                "In Projects, choose Register Project and select the local repository folder.",
            ],
            destination: .manager,
            destinationLabel: "Open Manager"
        ),
        Step(
            title: "Add Instruction Packages",
            symbol: "list.number",
            summary: "Instruction packages are durable, ordered work assignments linked to one registered repository.",
            details: [
                "In Projects, select the repository and choose Add Instructions.",
                "You can select one Markdown/text file, a folder of instruction documents, or a .forgepackage manifest.",
                "Forge copies accepted content into protected storage. Drag package rows up or down to set execution order.",
            ],
            destination: .projects,
            destinationLabel: "Open Projects"
        ),
        Step(
            title: "Run in Order",
            symbol: "play.circle",
            summary: "Ordered autonomy runs one package at a time for the selected project.",
            details: [
                "Choose Start Ordered Autonomy in the project's Instruction Packages section.",
                "Forge starts the first queued package with the saved provider and repository scope.",
                "The next package starts only after the prior run completes its required gate. A failure or block stops advancement for review.",
            ],
            destination: .projects,
            destinationLabel: "Open Package Queue"
        ),
    ]

    let onOpen: (AppModel.AppTab) -> Void
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        let step = steps[index]
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: step.symbol)
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Forge Conductor Setup")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(step.title)
                        .font(.title2.bold())
                    Text(step.summary)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(step.details.enumerated()), id: \.offset) { offset, detail in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(offset + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.accentColor))
                        Text(detail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let destination = step.destination,
               let label = step.destinationLabel {
                Button(label) { onOpen(destination) }
                    .accessibilityIdentifier("setup-guide-open-\(destination.accessibilityID)")
            }

            Spacer(minLength: 0)

            HStack {
                Text("Step \(index + 1) of \(steps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                Button("Back") { index -= 1 }
                    .disabled(index == 0)
                if index == steps.count - 1 {
                    Button("Finish Setup Guide", action: onComplete)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("setup-guide-finish")
                } else {
                    Button("Next") { index += 1 }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("setup-guide-next")
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 470)
        .accessibilityIdentifier("setup-guide")
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

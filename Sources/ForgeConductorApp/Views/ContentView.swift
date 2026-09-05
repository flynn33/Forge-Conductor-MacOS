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
            operatorContent { AutonomyOperatorView(client: model.operatorManagerClient) }
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

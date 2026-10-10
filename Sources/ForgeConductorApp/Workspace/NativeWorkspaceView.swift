import SwiftUI

private struct NativeWorkspacePreferencesKey: EnvironmentKey {
    static let defaultValue: NativeWorkspacePreferences? = nil
}

private struct NativeWorkspacePanelVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var nativeWorkspacePreferences: NativeWorkspacePreferences? {
        get { self[NativeWorkspacePreferencesKey.self] }
        set { self[NativeWorkspacePreferencesKey.self] = newValue }
    }
    var nativeWorkspacePanelVisible: Bool {
        get { self[NativeWorkspacePanelVisibilityKey.self] }
        set { self[NativeWorkspacePanelVisibilityKey.self] = newValue }
    }
}

/// Each feature keeps its existing state owner and supplies its own panels.
/// With no saved selection, the original feature composition remains available.
struct NativeWorkspaceView<DefaultContent: View>: View {
    @Environment(\.nativeWorkspacePreferences) private var preferences
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workbench: WorkbenchPreferences
    @EnvironmentObject private var guidedMode: GuidedModeCoordinator
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.graphiteAccessibilityCapabilities) private var capabilities
    let viewID: String
    let descriptors: [NativeWorkspacePanelDescriptor]
    @ViewBuilder let defaultContent: () -> DefaultContent
    let panelContent: (String, Bool) -> AnyView
    var activityChanged: ((Bool) -> Void)? = nil

    var body: some View {
        if let preferences {
            NativeWorkspaceScope(preferences: preferences, viewID: viewID,
                                 descriptors: descriptors, defaultContent: defaultContent,
                                 panelContent: hostedPanel, activityChanged: activityChanged)
        } else {
            defaultContent().onAppear { activityChanged?(true) }
        }
    }

    private func hostedPanel(_ id: String, _ visible: Bool) -> AnyView {
        AnyView(NativeWorkspaceHostedPanel(scrolls: descriptors.first { $0.id == id }?.scrollsContent ?? true,
                                           content: panelContent(id, visible))
            .environmentObject(model)
            .environmentObject(workbench)
            .environmentObject(guidedMode)
            .environment(\.nativeWorkspacePreferences, preferences)
            .environment(\.nativeWorkspacePanelVisible, visible)
            .environment(\.graphiteAccessibilityCapabilities,
                         GraphiteAccessibilityCapabilities(
                            increaseContrast: capabilities.increaseContrast || contrast == .increased,
                            reduceTransparency: capabilities.reduceTransparency || reduceTransparency))
            .graphiteWorkbench())
    }
}

private struct NativeWorkspaceHostedPanel: View {
    let scrolls: Bool
    let content: AnyView
    var body: some View {
        if scrolls {
            ScrollView { content.frame(maxWidth: .infinity, alignment: .topLeading) }
        } else {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct NativeWorkspaceScope<DefaultContent: View>: View {
    @ObservedObject var preferences: NativeWorkspacePreferences
    let viewID: String
    let descriptors: [NativeWorkspacePanelDescriptor]
    @ViewBuilder let defaultContent: () -> DefaultContent
    let panelContent: (String, Bool) -> AnyView
    let activityChanged: ((Bool) -> Void)?
    @State private var errorMessage: String?
    @State private var proposedName = ""
    @State private var namingAction: NamingAction?

    private enum NamingKind {
        case saveAs, rename
    }
    private struct NamingAction: Identifiable {
        let id = UUID()
        let kind: NamingKind
        let viewID: String
        let layoutID: UUID?
    }
    private var active: NativeWorkspaceLayout? { preferences.activeLayout(for: viewID) }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if let layout = active {
                NativeWorkspaceCanvasView(layout: layout, descriptors: descriptors, content: panelContent,
                    commitFrame: { id, frame in
                        guard active?.panels.first(where: { $0.id == id })?.isVisible == true else { return }
                        perform(for: layout.id) { try preferences.setFrame(frame, for: id, in: viewID) }
                    },
                    hidePanel: { id in perform(for: layout.id) { try preferences.setShown(false, for: id, in: viewID) } },
                    bringToFront: { id in perform(for: layout.id) { try preferences.bringToFront(id, in: viewID) } })
            } else {
                defaultContent()
            }
        }
        .onChange(of: active?.panels.contains(where: \.isVisible) ?? true, initial: true) { _, visible in
            activityChanged?(visible)
        }
        .sheet(item: $namingAction) { action in
            VStack(alignment: .leading, spacing: 16) {
                Text(action.kind == .rename ? "Rename Layout" : "Save Layout As")
                    .font(.headline)
                TextField("Layout name", text: $proposedName)
                    .accessibilityIdentifier("workspace-layout-name")
                    .onSubmit { finishNaming(action) }
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Cancel") { namingAction = nil; errorMessage = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { finishNaming(action) }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("workspace-save-layout")
                }
            }
            .padding(24).frame(width: 420)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Default") { perform { try preferences.reset(viewID) } }
                ForEach(preferences.layouts(for: viewID)) { layout in
                    Button(layout.name) { perform { try preferences.activate(layout.id, for: viewID) } }
                }
                Divider()
                Button("Save Layout As…") { beginNaming(.saveAs) }
                Button("Rename Layout…") { beginNaming(.rename) }.disabled(active == nil)
                Button("Delete Layout") {
                    if let layout = active { perform { try preferences.delete(layout.id, for: viewID) } }
                }.disabled(active == nil)
            } label: {
                Label(active?.name ?? "Default Layout", systemImage: "rectangle.3.group")
            }
            .accessibilityIdentifier("workspace-layout-menu-" + viewID)

            if active == nil {
                Button("Customize Layout") {
                    perform { try preferences.save(seed(named: unusedName())) }
                }
                .accessibilityIdentifier("workspace-customize-" + viewID)
            } else {
                Menu("Panels") {
                    ForEach(descriptors) { descriptor in
                        Toggle(descriptor.title, isOn: Binding(
                            get: { active?.panels.first(where: { $0.id == descriptor.id })?.isVisible ?? false },
                            set: { shown in perform { try preferences.setShown(shown, for: descriptor.id, in: viewID) } }))
                        .accessibilityIdentifier("workspace-toggle-" + descriptor.id)
                    }
                }
                .accessibilityIdentifier("workspace-panels-menu-" + viewID)
                Button("Restore Default") { perform { try preferences.reset(viewID) } }
                    .accessibilityIdentifier("workspace-restore-default-" + viewID)
            }
            Spacer(minLength: 0)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.secondary) }
            else if preferences.restorationError != nil {
                Text("A saved layout could not be restored. Choose Default to reset layout settings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("workspace-restoration-error")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(GraphitePalette.panelBottom)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-controls-" + viewID)
    }

    private func seed(named name: String) -> NativeWorkspaceLayout {
        let width = max(1_280, descriptors.map { $0.defaultFrame.x + $0.defaultFrame.width + 20 }.max() ?? 0)
        let height = max(900, descriptors.map { $0.defaultFrame.y + $0.defaultFrame.height + 20 }.max() ?? 0)
        return NativeWorkspaceLayout(id: UUID(), viewID: viewID, name: name,
            canvas: NativeWorkspaceCanvas(width: width, height: height),
            panels: descriptors.map { NativeWorkspacePanelPlacement(id: $0.id, frame: $0.defaultFrame, isVisible: true) })
    }

    private func unusedName() -> String {
        let names = Set(preferences.layouts(for: viewID).map { $0.name.lowercased() })
        for index in 1...NativeWorkspaceLimits.maximumSavedLayouts + 1 {
            let name = index == 1 ? "Custom" : "Custom \(index)"
            if !names.contains(name.lowercased()) { return name }
        }
        return "Custom"
    }

    private func beginNaming(_ kind: NamingKind) {
        let layout = active
        guard kind != .rename || layout != nil else { return }
        proposedName = kind == .rename ? layout?.name ?? "" : unusedName()
        errorMessage = nil
        namingAction = NamingAction(kind: kind, viewID: viewID, layoutID: layout?.id)
    }

    private func finishNaming(_ action: NamingAction) {
        guard namingAction?.id == action.id else { return }
        guard action.viewID == viewID, action.layoutID == active?.id else {
            namingAction = nil
            errorMessage = "The layout changed. Open the layout menu and try again."
            return
        }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if action.kind == .rename, let layout = active {
                try preferences.rename(layout.id, to: name, for: viewID)
            } else {
                try preferences.saveAs(active ?? seed(named: name), named: name)
            }
            namingAction = nil; errorMessage = nil
        } catch { showError(error) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); errorMessage = nil } catch { showError(error) }
    }

    private func perform(for expectedLayoutID: UUID, _ action: () throws -> Void) {
        guard active?.id == expectedLayoutID else { return }
        perform(action)
    }

    private func showError(_ error: Error) {
        switch error as? NativeWorkspaceValidationError {
        case .invalidName: errorMessage = "Enter a shorter name using printable characters."
        case .duplicateName: errorMessage = "A layout with that name already exists in this view."
        case .tooManyLayouts: errorMessage = "Up to 32 layouts can be saved. Delete a saved layout to add another."
        default: errorMessage = "The layout settings are invalid. Restore the default layout and try again."
        }
    }
}

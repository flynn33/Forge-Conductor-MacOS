import Combine
import Foundation

// App-owned local presentation preferences. This does not
// modify manager configuration, project state, or the existing control keys.
@MainActor
final class NativeWorkspacePreferences: ObservableObject {
    static let storageKey = "forge.workbench.workspaces.v1"
    static let defaultsSuiteEnvironmentKey = "FORGE_WORKBENCH_DEFAULTS_SUITE"

    @Published private(set) var collection = NativeWorkspaceCollection()
    @Published private(set) var restorationError: NativeWorkspaceValidationError?
    private let defaults: UserDefaults
    private let knownPanelIDsByView: [String: Set<String>]
    private let panelSizeBoundsByView: [String: [String: NativeWorkspacePanelSizeBounds]]

    func activeLayout(for viewID: String) -> NativeWorkspaceLayout? {
        guard let id = collection.activeLayoutIDs[viewID] else { return nil }
        return collection.layouts.first { $0.id == id }
    }

    func layouts(for viewID: String) -> [NativeWorkspaceLayout] {
        collection.layouts.filter { $0.viewID == viewID }
    }

    init(knownPanelIDsByView: [String: Set<String>],
         panelSizeBoundsByView: [String: [String: NativeWorkspacePanelSizeBounds]] = [:],
         defaults: UserDefaults? = nil) {
        self.knownPanelIDsByView = knownPanelIDsByView
        self.panelSizeBoundsByView = panelSizeBoundsByView
        self.defaults = defaults ?? Self.applicationDefaults()
        do {
            try NativeWorkspacePanelSizeBounds.validateRegistry(panelSizeBoundsByView, knownPanelIDsByView: knownPanelIDsByView)
        } catch let error as NativeWorkspaceValidationError {
            restorationError = error
            return
        } catch {
            restorationError = .invalidGeometry
            return
        }
        guard let stored = self.defaults.object(forKey: Self.storageKey) else { return }
        guard let data = stored as? Data else {
            restorationError = .invalidStoredData
            return
        }
        guard data.count <= NativeWorkspaceLimits.maximumStoredBytes else {
            restorationError = .oversizedStorage
            return
        }
        do {
            let restored = try JSONDecoder().decode(NativeWorkspaceCollection.self, from: data)
            try restored.validate(knownPanelIDsByView: knownPanelIDsByView, panelSizeBoundsByView: panelSizeBoundsByView)
            collection = restored
        } catch let error as NativeWorkspaceValidationError {
            restorationError = error
        } catch {
            restorationError = .invalidStoredData
        }
        // Invalid/future data is retained until an explicit successful edit;
        // constructing an app owner must never rewrite or discard it.
    }

    private static func applicationDefaults() -> UserDefaults {
        if let suite = ProcessInfo.processInfo.environment[defaultsSuiteEnvironmentKey],
           !suite.isEmpty, let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        return .standard
    }

    func save(_ layout: NativeWorkspaceLayout, activate: Bool = true) throws {
        var candidate = collection
        if let index = candidate.layouts.firstIndex(where: { $0.id == layout.id }) {
            guard candidate.layouts[index].viewID == layout.viewID else {
                throw NativeWorkspaceValidationError.layoutViewMismatch
            }
            candidate.layouts[index] = layout
        } else {
            candidate.layouts.append(layout)
        }
        if activate { candidate.activeLayoutIDs[layout.viewID] = layout.id }
        try commit(candidate)
    }

    @discardableResult
    func saveAs(_ layout: NativeWorkspaceLayout, named name: String) throws -> UUID {
        let copy = NativeWorkspaceLayout(id: UUID(), viewID: layout.viewID, name: name,
                                         canvas: layout.canvas, panels: layout.panels)
        try save(copy)
        return copy.id
    }

    func rename(_ id: UUID, to name: String, for viewID: String) throws {
        guard var layout = collection.layouts.first(where: { $0.id == id && $0.viewID == viewID }) else {
            throw NativeWorkspaceValidationError.missingLayout
        }
        layout.name = name
        try save(layout, activate: false)
    }

    func activate(_ id: UUID?, for viewID: String) throws {
        guard knownPanelIDsByView[viewID] != nil else { throw NativeWorkspaceValidationError.unknownViewID }
        var candidate = collection
        candidate.activeLayoutIDs[viewID] = id
        try commit(candidate)
    }

    func reset(_ viewID: String) throws { try activate(nil, for: viewID) }

    func delete(_ id: UUID, for viewID: String) throws {
        var candidate = collection
        guard let index = candidate.layouts.firstIndex(where: { $0.id == id && $0.viewID == viewID }) else {
            throw NativeWorkspaceValidationError.missingLayout
        }
        candidate.layouts.remove(at: index)
        if candidate.activeLayoutIDs[viewID] == id { candidate.activeLayoutIDs[viewID] = nil }
        try commit(candidate)
    }

    func setFrame(_ frame: NativeWorkspaceFrame, for panelID: String, in viewID: String) throws {
        try updateActivePanel(panelID, in: viewID) { $0.frame = frame }
    }

    func setShown(_ visible: Bool, for panelID: String, in viewID: String) throws {
        try updateActivePanel(panelID, in: viewID) { $0.isVisible = visible }
    }

    func bringToFront(_ panelID: String, in viewID: String) throws {
        guard var layout = activeLayout(for: viewID) else { throw NativeWorkspaceValidationError.missingActiveLayout }
        guard let index = layout.panels.firstIndex(where: { $0.id == panelID }) else {
            throw NativeWorkspaceValidationError.missingPanel
        }
        let panel = layout.panels.remove(at: index)
        layout.panels.append(panel)
        try save(layout)
    }

    private func updateActivePanel(_ id: String, in viewID: String,
                                   _ update: (inout NativeWorkspacePanelPlacement) -> Void) throws {
        guard var layout = activeLayout(for: viewID) else { throw NativeWorkspaceValidationError.missingActiveLayout }
        guard let index = layout.panels.firstIndex(where: { $0.id == id }) else {
            throw NativeWorkspaceValidationError.missingPanel
        }
        update(&layout.panels[index])
        try save(layout)
    }

    private func commit(_ candidate: NativeWorkspaceCollection) throws {
        try candidate.validate(knownPanelIDsByView: knownPanelIDsByView, panelSizeBoundsByView: panelSizeBoundsByView)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(candidate)
        guard data.count <= NativeWorkspaceLimits.maximumStoredBytes else {
            throw NativeWorkspaceValidationError.oversizedStorage
        }
        // Commit only completed gestures/explicit actions. The native canvas
        // owns transient drag state; it must not persist every pointer event.
        defaults.set(data, forKey: Self.storageKey)
        collection = candidate
        restorationError = nil
    }
}

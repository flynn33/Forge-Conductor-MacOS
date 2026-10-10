import Foundation

// Point geometry and stable panel identity, independent of the native host.
enum NativeWorkspaceLimits {
    static let schemaVersion = 1
    static let maximumPanels = 64
    static let maximumSavedLayouts = 32
    static let maximumViews = 32
    static let maximumNameBytes = 96
    static let maximumPanelIDBytes = 64
    static let maximumStoredBytes = 512 * 1_024
    static let minimumDimension = 64.0
    static let maximumDimension = 32_768.0
    static let maximumPanelDimension = 2_400.0
}

enum NativeWorkspaceValidationError: Error, Equatable {
    case unsupportedSchema, tooManyLayouts, tooManyPanels
    case invalidName, duplicateName, duplicateLayoutID, duplicatePanelID
    case invalidPanelID, unknownPanelID, unknownViewID, layoutViewMismatch, invalidGeometry
    case missingActiveLayout, missingLayout, missingPanel
    case oversizedStorage, invalidStoredData
}

struct NativeWorkspaceCanvas: Codable, Equatable, Sendable {
    var width: Double
    var height: Double

    func validate() throws {
        guard [width, height].allSatisfy({ $0.isFinite && $0 >= NativeWorkspaceLimits.minimumDimension
            && $0 <= NativeWorkspaceLimits.maximumDimension }) else {
            throw NativeWorkspaceValidationError.invalidGeometry
        }
    }
}

struct NativeWorkspaceFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    private func validateDimensions() throws {
        guard [x, y, width, height].allSatisfy({ $0.isFinite && $0 <= NativeWorkspaceLimits.maximumDimension }),
              x >= 0, y >= 0,
              width >= NativeWorkspaceLimits.minimumDimension,
              height >= NativeWorkspaceLimits.minimumDimension,
              width <= NativeWorkspaceLimits.maximumPanelDimension,
              height <= NativeWorkspaceLimits.maximumPanelDimension else {
            throw NativeWorkspaceValidationError.invalidGeometry
        }
    }

    func validate(in canvas: NativeWorkspaceCanvas) throws {
        try canvas.validate()
        try validateDimensions()
        guard x + width <= canvas.width, y + height <= canvas.height else {
            throw NativeWorkspaceValidationError.invalidGeometry
        }
    }

}

struct NativeWorkspacePanelPlacement: Codable, Equatable, Identifiable, Sendable {
    // Registry identity, never a title, array position, frame or runtime record ID.
    let id: String
    var frame: NativeWorkspaceFrame
    var isVisible: Bool

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= NativeWorkspaceLimits.maximumPanelIDBytes
            && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
    }
}

// Immutable app registry metadata, not part of a user's serialized layout.
struct NativeWorkspacePanelSizeBounds: Equatable, Sendable {
    var minimumWidth = NativeWorkspaceLimits.minimumDimension
    var minimumHeight = NativeWorkspaceLimits.minimumDimension
    var maximumWidth = NativeWorkspaceLimits.maximumPanelDimension
    var maximumHeight = NativeWorkspaceLimits.maximumPanelDimension

    func validate() throws {
        guard [minimumWidth, minimumHeight, maximumWidth, maximumHeight].allSatisfy({ $0.isFinite }),
              minimumWidth >= NativeWorkspaceLimits.minimumDimension,
              minimumHeight >= NativeWorkspaceLimits.minimumDimension,
              maximumWidth <= NativeWorkspaceLimits.maximumPanelDimension,
              maximumHeight <= NativeWorkspaceLimits.maximumPanelDimension,
              minimumWidth <= maximumWidth, minimumHeight <= maximumHeight else {
            throw NativeWorkspaceValidationError.invalidGeometry
        }
    }

    func validate(_ frame: NativeWorkspaceFrame) throws {
        try validate()
        guard frame.width >= minimumWidth, frame.height >= minimumHeight,
              frame.width <= maximumWidth, frame.height <= maximumHeight else {
            throw NativeWorkspaceValidationError.invalidGeometry
        }
    }

    static func validateRegistry(_ boundsByView: [String: [String: Self]],
                                 knownPanelIDsByView: [String: Set<String>]) throws {
        guard boundsByView.count <= NativeWorkspaceLimits.maximumViews else {
            throw NativeWorkspaceValidationError.unknownViewID
        }
        for (viewID, boundsByPanel) in boundsByView {
            guard let knownIDs = knownPanelIDsByView[viewID] else {
                throw NativeWorkspaceValidationError.unknownViewID
            }
            guard boundsByPanel.count <= NativeWorkspaceLimits.maximumPanels else {
                throw NativeWorkspaceValidationError.tooManyPanels
            }
            for (panelID, bounds) in boundsByPanel {
                guard knownIDs.contains(panelID) else { throw NativeWorkspaceValidationError.unknownPanelID }
                try bounds.validate()
            }
        }
    }
}

struct NativeWorkspaceLayout: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let viewID: String
    var name: String
    var canvas: NativeWorkspaceCanvas
    // Array order is back-to-front order; moving a panel never changes its ID.
    var panels: [NativeWorkspacePanelPlacement]

    func validate(knownPanelIDsByView: [String: Set<String>],
                  panelSizeBoundsByView: [String: [String: NativeWorkspacePanelSizeBounds]] = [:]) throws {
        guard NativeWorkspacePanelPlacement.isValidID(viewID),
              let knownPanelIDs = knownPanelIDsByView[viewID] else {
            throw NativeWorkspaceValidationError.unknownViewID
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name == trimmed,
              name.utf8.count <= NativeWorkspaceLimits.maximumNameBytes,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NativeWorkspaceValidationError.invalidName
        }
        try canvas.validate()
        guard panels.count <= NativeWorkspaceLimits.maximumPanels else {
            throw NativeWorkspaceValidationError.tooManyPanels
        }
        var seen = Set<String>()
        for panel in panels {
            guard NativeWorkspacePanelPlacement.isValidID(panel.id) else {
                throw NativeWorkspaceValidationError.invalidPanelID
            }
            guard knownPanelIDs.contains(panel.id) else {
                throw NativeWorkspaceValidationError.unknownPanelID
            }
            guard seen.insert(panel.id).inserted else {
                throw NativeWorkspaceValidationError.duplicatePanelID
            }
            try panel.frame.validate(in: canvas)
            let bounds = panelSizeBoundsByView[viewID]?[panel.id] ?? NativeWorkspacePanelSizeBounds()
            try bounds.validate(panel.frame)
        }
        guard seen == knownPanelIDs else {
            throw NativeWorkspaceValidationError.missingPanel
        }
    }
}

struct NativeWorkspaceCollection: Codable, Equatable, Sendable {
    var schemaVersion = NativeWorkspaceLimits.schemaVersion
    var layouts: [NativeWorkspaceLayout] = []
    // A missing view key selects that view's existing default presentation.
    var activeLayoutIDs: [String: UUID] = [:]

    func validate(knownPanelIDsByView: [String: Set<String>],
                  panelSizeBoundsByView: [String: [String: NativeWorkspacePanelSizeBounds]] = [:]) throws {
        guard schemaVersion == NativeWorkspaceLimits.schemaVersion else {
            throw NativeWorkspaceValidationError.unsupportedSchema
        }
        guard layouts.count <= NativeWorkspaceLimits.maximumSavedLayouts else {
            throw NativeWorkspaceValidationError.tooManyLayouts
        }
        guard activeLayoutIDs.count <= NativeWorkspaceLimits.maximumViews else {
            throw NativeWorkspaceValidationError.unknownViewID
        }
        try NativeWorkspacePanelSizeBounds.validateRegistry(panelSizeBoundsByView, knownPanelIDsByView: knownPanelIDsByView)
        var ids = Set<UUID>()
        var namesByView: [String: Set<String>] = [:]
        for layout in layouts {
            try layout.validate(knownPanelIDsByView: knownPanelIDsByView, panelSizeBoundsByView: panelSizeBoundsByView)
            guard ids.insert(layout.id).inserted else {
                throw NativeWorkspaceValidationError.duplicateLayoutID
            }
            let name = layout.name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard namesByView[layout.viewID, default: []].insert(name).inserted else {
                throw NativeWorkspaceValidationError.duplicateName
            }
        }
        for (viewID, activeLayoutID) in activeLayoutIDs {
            guard knownPanelIDsByView[viewID] != nil else {
                throw NativeWorkspaceValidationError.unknownViewID
            }
            guard let layout = layouts.first(where: { $0.id == activeLayoutID }) else {
                throw NativeWorkspaceValidationError.missingActiveLayout
            }
            guard layout.viewID == viewID else {
                throw NativeWorkspaceValidationError.layoutViewMismatch
            }
        }
    }
}

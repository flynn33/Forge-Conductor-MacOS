import Foundation

struct GuidedHelpEntry: Codable, Equatable, Identifiable, Sendable {
    let context: GuidedHelpContext
    let title: String
    let purpose: String
    let forgeHandlesAutomatically: [String]
    let controls: [String]
    let statusMeanings: [String]
    let normalWorkflow: [String]
    let troubleshooting: [String]
    let advancedDetails: [String]
    let relatedContexts: [GuidedHelpContext]
    let controlAnchors: [String]

    var id: GuidedHelpContext { context }

    enum CodingKeys: String, CodingKey {
        case context = "id"
        case title, purpose, controls, troubleshooting
        case forgeHandlesAutomatically = "forge_handles_automatically"
        case statusMeanings = "status_meanings"
        case normalWorkflow = "normal_workflow"
        case advancedDetails = "advanced_details"
        case relatedContexts = "related_contexts"
        case controlAnchors = "control_anchors"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        context = try values.decode(GuidedHelpContext.self, forKey: .context)
        title = try values.decode(String.self, forKey: .title)
        purpose = try values.decode(String.self, forKey: .purpose)
        forgeHandlesAutomatically = try values.decode([String].self, forKey: .forgeHandlesAutomatically)
        controls = try values.decode([String].self, forKey: .controls)
        statusMeanings = try values.decode([String].self, forKey: .statusMeanings)
        normalWorkflow = try values.decode([String].self, forKey: .normalWorkflow)
        troubleshooting = try values.decode([String].self, forKey: .troubleshooting)
        advancedDetails = try values.decode([String].self, forKey: .advancedDetails)
        relatedContexts = try values.decodeIfPresent(
            [GuidedHelpContext].self,
            forKey: .relatedContexts
        ) ?? []
        controlAnchors = try values.decodeIfPresent([String].self, forKey: .controlAnchors) ?? []
    }
}

enum GuidedHelpCatalogError: Error, LocalizedError, Equatable {
    case resourceMissing
    case unsupportedSchema(String)
    case duplicateContext(GuidedHelpContext)
    case missingContexts([GuidedHelpContext])
    case incompleteContext(GuidedHelpContext, String)
    case unknownControlAnchor(GuidedHelpContext, String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing:
            "The bundled Guided Mode catalog is missing."
        case .unsupportedSchema(let schema):
            "The Guided Mode catalog schema \(schema) is unsupported."
        case .duplicateContext(let context):
            "The Guided Mode catalog contains duplicate \(context.rawValue) entries."
        case .missingContexts(let contexts):
            "The Guided Mode catalog is missing: \(contexts.map(\.rawValue).joined(separator: ", "))."
        case .incompleteContext(let context, let field):
            "The \(context.rawValue) guide has no \(field)."
        case .unknownControlAnchor(let context, let anchor):
            "The \(context.rawValue) guide references unknown control anchor \(anchor)."
        }
    }
}

struct GuidedHelpCatalog: Codable, Equatable, Sendable {
    let schemaVersion: String
    let entries: [GuidedHelpEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case entries = "contexts"
    }

    static func bundled() throws -> Self {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(
            forResource: "GuidedHelpCatalog",
            withExtension: "json"
        ) else {
            throw GuidedHelpCatalogError.resourceMissing
        }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try catalog.validate()
        return catalog
    }

    func entry(for context: GuidedHelpContext) -> GuidedHelpEntry? {
        entries.first { $0.context == context }
    }

    func validate() throws {
        guard schemaVersion == "1.0.0" else {
            throw GuidedHelpCatalogError.unsupportedSchema(schemaVersion)
        }
        var seen = Set<GuidedHelpContext>()
        for entry in entries {
            guard seen.insert(entry.context).inserted else {
                throw GuidedHelpCatalogError.duplicateContext(entry.context)
            }
            let required: [(String, Bool)] = [
                ("title", !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                ("purpose", !entry.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                ("automatic behavior", !entry.forgeHandlesAutomatically.isEmpty),
                ("controls", !entry.controls.isEmpty),
                ("status meanings", !entry.statusMeanings.isEmpty),
                ("normal workflow", !entry.normalWorkflow.isEmpty),
                ("troubleshooting", !entry.troubleshooting.isEmpty),
                ("advanced details", !entry.advancedDetails.isEmpty),
            ]
            if let missing = required.first(where: { !$0.1 }) {
                throw GuidedHelpCatalogError.incompleteContext(entry.context, missing.0)
            }
            if let unknown = entry.controlAnchors.first(where: { !GuidedControlAnchor.isKnown($0) }) {
                throw GuidedHelpCatalogError.unknownControlAnchor(entry.context, unknown)
            }
        }
        let missing = Set(GuidedHelpContext.allCases).subtracting(seen).sorted {
            $0.rawValue < $1.rawValue
        }
        guard missing.isEmpty else { throw GuidedHelpCatalogError.missingContexts(missing) }
    }
}

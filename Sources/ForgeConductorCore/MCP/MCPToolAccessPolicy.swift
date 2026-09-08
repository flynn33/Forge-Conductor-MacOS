// The same role policy governs discovery, direct dispatch and deployment smoke.

import Foundation

enum MCPToolAccessPolicy {
    static let continuityTools = Set(ContinuityControlToolName.allCases.map(\.rawValue))

    static func permits(_ name: String, role: LMStudioConnectorRole) -> Bool {
        role != .clu || continuityTools.contains(name)
    }

    static func toolNames(_ names: [String], role: LMStudioConnectorRole) -> [String] {
        names.filter { permits($0, role: role) }
    }
}

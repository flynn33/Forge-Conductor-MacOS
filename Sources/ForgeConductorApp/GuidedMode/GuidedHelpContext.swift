import Foundation

enum GuidedHelpContext: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case rig
    case mcp
    case agents
    case tools
    case liveFeed
    case projects
    case projectRegistration
    case instructionImport
    case instructionQueue
    case projectRelink
    case projectReset
    case projectContentClear
    case runeForge
    case autonomy
    case autonomyStartTask
    case autonomyToolSelection
    case autonomyCompletionChecks
    case continuity
    case continuitySaveProgress
    case continuityFreshSession
    case runtimes
    case runtimeJob
    case provider
    case providerCredential
    case evidence
    case diagnostics
    case manager

    var id: String { rawValue }
}

extension AppModel.AppTab {
    var guidedHelpContext: GuidedHelpContext {
        switch self {
        case .rig: .rig
        case .mcp: .mcp
        case .agents: .agents
        case .tools: .tools
        case .feed: .liveFeed
        case .projects: .projects
        case .runeForge: .runeForge
        case .autonomy: .autonomy
        case .continuity: .continuity
        case .runtimes: .runtimes
        case .provider: .provider
        case .evidence: .evidence
        case .diagnostics: .diagnostics
        case .manager: .manager
        }
    }
}

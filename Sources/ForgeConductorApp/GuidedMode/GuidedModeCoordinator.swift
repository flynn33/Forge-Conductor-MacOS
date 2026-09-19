import Combine
import Foundation

@MainActor
final class GuidedModeCoordinator: ObservableObject {
    struct ContextToken: Hashable, Sendable {
        fileprivate let id: UUID
    }

    static let enabledPreferenceKey = "forge.guidedMode.enabled.v1"

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledPreferenceKey) }
    }
    @Published private(set) var selectedContext: GuidedHelpContext = .rig
    @Published private(set) var presentedContext: GuidedHelpContext?
    @Published private(set) var states: [GuidedHelpContext: GuidedHelpState] = [:]

    let catalog: GuidedHelpCatalog?
    let catalogError: String?

    private let defaults: UserDefaults
    private var nestedContexts: [(ContextToken, GuidedHelpContext)] = []

    init(defaults: UserDefaults? = nil) {
        let resolvedDefaults = defaults ?? Self.defaultDefaults()
        self.defaults = resolvedDefaults
        isEnabled = resolvedDefaults.bool(forKey: Self.enabledPreferenceKey)
        do {
            catalog = try GuidedHelpCatalog.bundled()
            catalogError = nil
        } catch {
            catalog = nil
            catalogError = error.localizedDescription
        }
    }

    private static func defaultDefaults() -> UserDefaults {
        guard
            let suiteName = ProcessInfo.processInfo.environment["FORGE_GUIDED_MODE_DEFAULTS_SUITE"],
            let defaults = UserDefaults(suiteName: suiteName)
        else {
            return .standard
        }
        return defaults
    }

    var currentContext: GuidedHelpContext {
        nestedContexts.last?.1 ?? selectedContext
    }

    var hasNestedContext: Bool { !nestedContexts.isEmpty }

    func select(_ context: GuidedHelpContext) {
        selectedContext = context
    }

    @discardableResult
    func push(_ context: GuidedHelpContext) -> ContextToken {
        let token = ContextToken(id: UUID())
        nestedContexts.append((token, context))
        objectWillChange.send()
        return token
    }

    func pop(_ token: ContextToken) {
        nestedContexts.removeAll { $0.0 == token }
        objectWillChange.send()
    }

    func present(_ context: GuidedHelpContext? = nil) {
        presentedContext = context ?? currentContext
    }

    func dismiss() {
        presentedContext = nil
    }

    func updateState(_ state: GuidedHelpState, for context: GuidedHelpContext) {
        guard states[context] != state else { return }
        states[context] = state
    }

    func state(for context: GuidedHelpContext) -> GuidedHelpState {
        states[context] ?? .overview(for: context)
    }
}

import SwiftUI

struct GuidedInlineHelp: View {
    let entry: GuidedHelpEntry
    let state: GuidedHelpState
    let openGuide: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.purpose)
                    .font(.callout.weight(.medium))
                Text(state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let action = state.recommendedAction {
                    Text(action)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button("Open Guide", action: openGuide)
                .accessibilityIdentifier("guided-inline-open")
        }
        .padding(12)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guided-inline-\(entry.context.rawValue)")
    }
}

struct GuidedHelpButton: View {
    @EnvironmentObject private var coordinator: GuidedModeCoordinator
    let context: GuidedHelpContext?

    init(context: GuidedHelpContext? = nil) {
        self.context = context
    }

    var body: some View {
        Button {
            coordinator.present(context)
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.borderless)
        .help("Open contextual guide")
        .accessibilityLabel("Open contextual guide")
        .accessibilityIdentifier("guided-help-\((context ?? coordinator.currentContext).rawValue)")
    }
}

private struct GuidedHelpContextModifier: ViewModifier {
    @EnvironmentObject private var coordinator: GuidedModeCoordinator
    let context: GuidedHelpContext
    @State private var token: GuidedModeCoordinator.ContextToken?

    private var presentedContext: Binding<GuidedHelpContext?> {
        Binding<GuidedHelpContext?>(
            get: {
                guard coordinator.currentContext == context else { return nil }
                return coordinator.presentedContext
            },
            set: { value in
                if value == nil { coordinator.dismiss() }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard token == nil else { return }
                token = coordinator.push(context)
            }
            .onDisappear {
                guard let token else { return }
                coordinator.pop(token)
                self.token = nil
            }
            .sheet(item: presentedContext) { presentedContext in
                if let catalog = coordinator.catalog {
                    GuidedHelpSheet(
                        coordinator: coordinator,
                        catalog: catalog,
                        context: presentedContext
                    )
                } else {
                    ContentUnavailableView(
                        "Guide unavailable",
                        systemImage: "questionmark.circle",
                        description: Text(coordinator.catalogError ?? "The bundled guide could not be loaded.")
                    )
                    .padding(24)
                    .frame(width: 520, height: 320)
                }
            }
    }
}

private struct GuidedHelpStateModifier: ViewModifier {
    @EnvironmentObject private var coordinator: GuidedModeCoordinator
    let context: GuidedHelpContext
    let state: GuidedHelpState

    func body(content: Content) -> some View {
        content
            .onAppear { coordinator.updateState(state, for: context) }
            .onChange(of: state) { _, value in
                coordinator.updateState(value, for: context)
            }
    }
}

extension View {
    func guidedHelpContext(_ context: GuidedHelpContext) -> some View {
        modifier(GuidedHelpContextModifier(context: context))
    }

    func guidedHelpState(_ state: GuidedHelpState, for context: GuidedHelpContext) -> some View {
        modifier(GuidedHelpStateModifier(context: context, state: state))
    }
}

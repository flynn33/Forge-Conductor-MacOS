import SwiftUI

struct GuidedInlineHelp: View {
    let entry: GuidedHelpEntry
    let state: GuidedHelpState
    let openGuide: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(GraphitePalette.info)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.purpose)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(state.detail)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(GraphitePalette.textSecondary)
                if let action = state.recommendedAction {
                    Text(action)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(GraphitePalette.textSecondary)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 12)
            Button("Open Guide", action: openGuide)
                .buttonStyle(GraphiteButtonStyle(kind: .secondary))
                .accessibilityIdentifier("guided-inline-open")
        }
        .padding(12)
        .background(GraphitePalette.panelRaised, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(GraphitePalette.info.opacity(0.4), lineWidth: 1)
        }
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
                .frame(minWidth: 24, minHeight: 24)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(GraphitePalette.info)
        .help("Open contextual guide")
        .accessibilityLabel("Open contextual guide")
        .accessibilityIdentifier("guided-help-\((context ?? coordinator.currentContext).rawValue)")
    }
}

private struct GuidedHelpContextModifier: ViewModifier {
    @EnvironmentObject private var coordinator: GuidedModeCoordinator
    let context: GuidedHelpContext
    let ownerToken: Binding<GuidedModeCoordinator.ContextToken?>
    @State private var token: GuidedModeCoordinator.ContextToken?

    private var presentedContext: Binding<GuidedHelpContext?> {
        Binding<GuidedHelpContext?>(
            get: {
                guard coordinator.currentContext == context else { return nil }
                return coordinator.presentedContext
            },
            set: { value in
                if value == nil, let token, ownerToken.wrappedValue == token {
                    coordinator.dismiss()
                }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard token == nil else { return }
                token = coordinator.push(context)
                ownerToken.wrappedValue = token
            }
            .onDisappear {
                guard let token else { return }
                coordinator.pop(token)
                if ownerToken.wrappedValue == token { ownerToken.wrappedValue = nil }
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
                    .background(GraphitePalette.canvas)
                    .foregroundStyle(GraphitePalette.textPrimary)
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
    func guidedHelpContext(
        _ context: GuidedHelpContext,
        ownerToken: Binding<GuidedModeCoordinator.ContextToken?>
    ) -> some View {
        modifier(GuidedHelpContextModifier(context: context, ownerToken: ownerToken))
    }

    func guidedHelpState(_ state: GuidedHelpState, for context: GuidedHelpContext) -> some View {
        modifier(GuidedHelpStateModifier(context: context, state: state))
    }
}

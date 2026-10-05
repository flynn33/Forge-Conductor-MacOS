import SwiftUI

struct GuidedHelpSheet: View {
    @ObservedObject var coordinator: GuidedModeCoordinator
    let catalog: GuidedHelpCatalog
    @State private var context: GuidedHelpContext
    @State private var showingAdvanced = false

    init(
        coordinator: GuidedModeCoordinator,
        catalog: GuidedHelpCatalog,
        context: GuidedHelpContext
    ) {
        self.coordinator = coordinator
        self.catalog = catalog
        _context = State(initialValue: context)
    }

    var body: some View {
        Group {
            if let entry = catalog.entry(for: context) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Guided Mode")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(GraphitePalette.textSecondary)
                                Text(entry.title)
                                    .font(.system(size: 24, weight: .bold))
                                    .accessibilityAddTraits(.isHeader)
                                Text(entry.purpose)
                                    .font(.system(size: 13))
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .foregroundStyle(GraphitePalette.textSecondary)
                            }
                            Spacer()
                            Button("Close") { coordinator.dismiss() }
                                .buttonStyle(GraphiteButtonStyle(kind: .secondary))
                                .keyboardShortcut(.cancelAction)
                                .accessibilityIdentifier("guided-help-close")
                        }

                        stateCard(for: entry.context)
                        guideSection(
                            "What Forge handles automatically",
                            symbol: "gearshape.2",
                            items: entry.forgeHandlesAutomatically
                        )
                        guideSection("Controls", symbol: "switch.2", items: entry.controls)
                        guideSection("Status meanings", symbol: "circle.dashed", items: entry.statusMeanings)
                        guideSection("Normal workflow", symbol: "list.number", items: entry.normalWorkflow)
                        guideSection("Troubleshooting", symbol: "wrench.and.screwdriver", items: entry.troubleshooting)

                        GraphitePanel {
                            DisclosureGroup("Advanced details", isExpanded: $showingAdvanced) {
                                guideItems(entry.advancedDetails)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                            }
                            .accessibilityIdentifier("guided-help-advanced")
                        }

                        if !entry.relatedContexts.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Related guides").font(.system(size: 15, weight: .semibold))
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading, spacing: 8) {
                                    ForEach(entry.relatedContexts) { related in
                                        if let relatedEntry = catalog.entry(for: related) {
                                            Button(relatedEntry.title) {
                                                context = related
                                                showingAdvanced = false
                                            }
                                            .buttonStyle(GraphiteButtonStyle(kind: .secondary))
                                            .accessibilityIdentifier("guided-help-related-\(related.rawValue)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            } else {
                ContentUnavailableView(
                    "Guide unavailable",
                    systemImage: "questionmark.circle",
                    description: Text("The bundled guide does not contain this context.")
                )
                .overlay(alignment: .topTrailing) {
                    Button("Close") { coordinator.dismiss() }
                        .buttonStyle(GraphiteButtonStyle(kind: .secondary))
                        .padding()
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 680)
        .background(GraphitePalette.canvas)
        .foregroundStyle(GraphitePalette.textPrimary)
        .tint(GraphitePalette.info)
        .multilineTextAlignment(.leading)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("guided-help-sheet")
    }

    private func stateCard(for context: GuidedHelpContext) -> some View {
        let state = coordinator.state(for: context)
        return GraphitePanel(title: "Current guidance") {
            VStack(alignment: .leading, spacing: 6) {
                Text(state.status).font(.system(size: 13, weight: .semibold))
                Text(state.detail)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(GraphitePalette.textSecondary)
                if let action = state.recommendedAction {
                    Text(action)
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func guideSection(_ title: String, symbol: String, items: [String]) -> some View {
        GraphitePanel {
            Label(title, systemImage: symbol).font(.system(size: 15, weight: .semibold))
            guideItems(items)
        }
    }

    private func guideItems(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .padding(.top, 7)
                    Text(item)
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

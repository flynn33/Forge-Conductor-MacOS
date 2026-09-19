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
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Guided Mode")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(entry.title)
                                    .font(.title2.bold())
                                    .accessibilityAddTraits(.isHeader)
                                Text(entry.purpose)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Close") { coordinator.dismiss() }
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

                        DisclosureGroup("Advanced details", isExpanded: $showingAdvanced) {
                            guideItems(entry.advancedDetails)
                                .padding(.top, 8)
                        }

                        if !entry.relatedContexts.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Related guides").font(.headline)
                                HStack {
                                    ForEach(entry.relatedContexts) { related in
                                        if let relatedEntry = catalog.entry(for: related) {
                                            Button(relatedEntry.title) {
                                                context = related
                                                showingAdvanced = false
                                            }
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
                        .padding()
                }
            }
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 680)
        .accessibilityIdentifier("guided-help-sheet")
    }

    private func stateCard(for context: GuidedHelpContext) -> some View {
        let state = coordinator.state(for: context)
        return GroupBox("Current guidance") {
            VStack(alignment: .leading, spacing: 6) {
                Text(state.status).font(.headline)
                Text(state.detail).foregroundStyle(.secondary)
                if let action = state.recommendedAction {
                    Text(action).font(.callout.weight(.medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func guideSection(_ title: String, symbol: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            guideItems(items)
        }
    }

    private func guideItems(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .padding(.top, 7)
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

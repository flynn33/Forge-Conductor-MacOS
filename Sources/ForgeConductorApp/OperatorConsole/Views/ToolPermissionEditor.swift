// ToolPermissionEditor.swift
// Reusable registered-catalog permission controls for managed task preparation.

import AppKit
import SwiftUI

struct ToolPermissionEditor: View {
    @ObservedObject var viewModel: AutonomyViewModel

    var body: some View {
        GroupBox {
            if let permissions = viewModel.toolPermissions {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 12) {
                        NativeTriStateCheckbox(
                            title: "Allow all tools",
                            identifier: "run-tools-allow-all",
                            state: viewModel.allToolSelectionState,
                            enabled: !viewModel.toolPermissionUpdateInFlight
                        ) {
                            viewModel.setAllTools(
                                selected: viewModel.allToolSelectionState != .checked
                            )
                        }
                        .frame(minWidth: 180, alignment: .leading)
                        Spacer()
                        Button("Select none") { viewModel.setAllTools(selected: false) }
                            .disabled(viewModel.toolPermissionUpdateInFlight)
                            .accessibilityIdentifier("run-tools-select-none")
                        Button("Restore recommended") {
                            viewModel.restoreRecommendedTools()
                        }
                        .disabled(viewModel.toolPermissionUpdateInFlight)
                        .accessibilityIdentifier("run-tools-restore-recommended")
                    }
                    TextField("Search capabilities", text: $viewModel.toolSearch)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("run-tools-search")
                    Text("\(permissions.effectiveCount) granted · \(permissions.availableCount) available · saved for this project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("run-tools-selection-count")

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.visibleToolCategories, id: \.self) { category in
                                VStack(alignment: .leading, spacing: 6) {
                                    NativeTriStateCheckbox(
                                        title: category.displayName,
                                        identifier: "run-tools-category-\(category.rawValue)",
                                        state: viewModel.categorySelectionState(category),
                                        enabled: !viewModel.toolPermissionUpdateInFlight
                                    ) {
                                        viewModel.setCategory(
                                            category,
                                            selected: viewModel.categorySelectionState(category) != .checked
                                        )
                                    }
                                    .frame(minWidth: 240, alignment: .leading)

                                    ForEach(viewModel.filteredToolEntries.filter {
                                        $0.category == category
                                    }) { tool in
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                NativeTriStateCheckbox(
                                                    title: tool.displayName,
                                                    identifier: "run-tool-\(tool.id)",
                                                    state: viewModel.isToolSelected(tool.id)
                                                        ? .checked
                                                        : .unchecked,
                                                    enabled: !viewModel.toolPermissionUpdateInFlight
                                                        && (tool.available
                                                            || permissions.selectedToolIDs.contains(tool.id))
                                                ) {
                                                    viewModel.setTool(
                                                        tool.id,
                                                        selected: !viewModel.isToolSelected(tool.id)
                                                    )
                                                }
                                                .frame(minWidth: 180, alignment: .leading)
                                                if tool.highImpact {
                                                    Text("Higher impact")
                                                        .font(.caption2)
                                                        .foregroundStyle(.orange)
                                                }
                                            }
                                            Text(tool.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(tool.id)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.tertiary)
                                            if let reason = tool.unavailableReason {
                                                Text(reason)
                                                    .font(.caption2)
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                        .padding(.leading, 20)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading the registered capability catalog for this project…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("run-tools-loading")
            }
        } label: {
            HStack {
                Text("Task capabilities")
                Spacer()
                GuidedHelpButton(context: .autonomyToolSelection)
            }
        }
    }
}

private struct NativeTriStateCheckbox: NSViewRepresentable {
    let title: String
    let identifier: String
    let state: ToolCheckboxState
    let enabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> NativeCheckboxButton {
        NativeCheckboxButton(
            title: title,
            identifier: identifier,
            activation: action
        )
    }

    func updateNSView(_ button: NativeCheckboxButton, context: Context) {
        button.activation = action
        button.title = title
        button.setAccessibilityIdentifier(identifier)
        if !enabled, button.window?.firstResponder === button {
            button.restoreKeyboardFocusWhenEnabled = true
        }
        button.isEnabled = enabled
        if enabled, button.restoreKeyboardFocusWhenEnabled {
            button.restoreKeyboardFocusWhenEnabled = false
            DispatchQueue.main.async { [weak button] in
                guard let button, button.isEnabled else { return }
                button.window?.makeFirstResponder(button)
            }
        }
        switch state {
        case .unchecked: button.state = .off
        case .mixed: button.state = .mixed
        case .checked: button.state = .on
        }
    }
}

private final class NativeCheckboxButton: NSButton {
    var activation: () -> Void
    var restoreKeyboardFocusWhenEnabled = false

    init(title: String, identifier: String, activation: @escaping () -> Void) {
        self.activation = activation
        super.init(frame: .zero)
        self.title = title
        setButtonType(.switch)
        allowsMixedState = true
        setAccessibilityIdentifier(identifier)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        activation()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 49 else {
            super.keyDown(with: event)
            return
        }
        state = state == .on ? .off : .on
        activation()
    }
}

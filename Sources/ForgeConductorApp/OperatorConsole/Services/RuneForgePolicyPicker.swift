// RuneForgePolicyPicker.swift
// Configures the unrestricted native file-or-folder policy source picker.

import AppKit
import Foundation

@MainActor
enum RuneForgePolicyPicker {
    static let testSelectionEnvironmentKey = "FORGE_RUNE_POLICY_UI_TEST_SELECTION"

    static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.prompt = "Add Development Policy"
        panel.message = "Choose any file or folder containing development policy, governance, or guidance."
        return panel
    }

    static func select(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if arguments.contains("--uitesting"),
           let path = environment[testSelectionEnvironmentKey],
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let panel = makePanel()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

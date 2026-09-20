// RuneForgePolicyPicker.swift
// Configures the unrestricted native file-or-folder policy source picker.

import AppKit
import Foundation
import ForgeConductorCore
import UniformTypeIdentifiers

@MainActor
enum RuneForgePolicyPicker {
    static let testSelectionEnvironmentKey = "FORGE_RUNE_POLICY_UI_TEST_SELECTION"
    static let testExportEnvironmentKey = "FORGE_RUNE_POLICY_UI_TEST_EXPORT"

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

    static func makeExportPanel(format: StjornarvaldExportFormat) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        panel.prompt = "Export Policy Log"
        panel.message = "Choose where to save the bounded Stjornarvald policy history."
        panel.nameFieldStringValue = "stjornarvald-policy-log.\(fileExtension(format))"
        panel.allowedContentTypes = [contentType(format)]
        return panel
    }

    static func selectExportDestination(
        format: StjornarvaldExportFormat,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if arguments.contains("--uitesting"),
           let path = environment[testExportEnvironmentKey],
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let panel = makeExportPanel(format: format)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func fileExtension(_ format: StjornarvaldExportFormat) -> String {
        switch format {
        case .jsonl: "jsonl"
        case .json: "json"
        case .markdown: "md"
        case .csv: "csv"
        }
    }

    private static func contentType(_ format: StjornarvaldExportFormat) -> UTType {
        switch format {
        case .jsonl: UTType(filenameExtension: "jsonl") ?? .json
        case .json: .json
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .csv: .commaSeparatedText
        }
    }
}

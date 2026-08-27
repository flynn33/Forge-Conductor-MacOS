// OperatorConsoleComponents.swift
// Reusable native status, error, and detail components for operator surfaces.

import SwiftUI

struct OperatorHeader: View {
    let title: String
    let subtitle: String
    let isLoading: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            }
            Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
                .disabled(isLoading)
                .accessibilityIdentifier("operator-refresh")
        }
    }
}

struct OperatorErrorBanner: View {
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Manager state unavailable").font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let retry {
                    Button("Retry", action: retry)
                        .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("operator-unavailable")
    }
}

struct OperatorNoticeBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("operator-notice")
    }
}

struct OperatorStateBadge: View {
    let state: String

    var body: some View {
        Text(state.replacingOccurrences(of: "_", with: " "))
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
            .accessibilityLabel("State")
            .accessibilityValue(state)
    }

    private var foreground: Color {
        switch state {
        case "completed", "active", "running", "healthy", "ready", "sealed": .green
        case "failed_terminal", "cancelled", "failed", "quarantined_stale": .red
        case "waiting_provider", "waiting_resource", "retry_wait", "paused", "blocked_configuration": .orange
        default: .secondary
        }
    }

    private var background: Color { foreground.opacity(0.14) }
}

struct OperatorIdentifier: View {
    let value: String?
    let unavailable: String

    init(_ value: String?, unavailable: String = "Unavailable") {
        self.value = value
        self.unavailable = unavailable
    }

    var body: some View {
        Text(value ?? unavailable)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(value == nil ? .secondary : .primary)
            .lineLimit(2)
            .textSelection(.enabled)
    }
}

enum OperatorFormat {
    static func bytes(_ count: UInt64?) -> String {
        guard let count else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    static func yesNo(_ value: Bool?) -> String {
        guard let value else { return "Unavailable" }
        return value ? "Yes" : "No"
    }

    static func integer(_ value: Int?) -> String {
        value.map(String.init) ?? "Unavailable"
    }
}

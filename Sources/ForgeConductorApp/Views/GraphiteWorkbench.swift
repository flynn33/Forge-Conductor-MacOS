import AppKit
import Combine
import Foundation
import SwiftUI
import Metal

/// A single presentation owner shared by the main window, Settings and menus.
/// These local preferences never write the manager's staged configuration.
@MainActor
final class WorkbenchPreferences: ObservableObject {
    enum Control: String, CaseIterable, Hashable {
        case navigation, autoRefresh, guidedMode, guide, refresh, guidedSetup

        var title: String {
            switch self {
            case .navigation: return "Navigation"
            case .autoRefresh: return "Auto-refresh"
            case .guidedMode: return "Guided Mode"
            case .guide: return "Guide"
            case .refresh: return "Refresh"
            case .guidedSetup: return "Guided Setup"
            }
        }

        var preferenceKey: String { "forge.workbench.control.\(rawValue).v1" }
    }

    @Published private(set) var enabledControls: Set<Control>
    @Published var isGuidedSetupPresented = false
    var activateMainWindow: () -> Void = {}
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        let resolvedDefaults = defaults ?? Self.defaultDefaults()
        self.defaults = resolvedDefaults
        enabledControls = Set(Control.allCases.filter {
            resolvedDefaults.bool(forKey: $0.preferenceKey)
        })
    }

    private static func defaultDefaults() -> UserDefaults {
        if let suite = ProcessInfo.processInfo.environment["FORGE_WORKBENCH_DEFAULTS_SUITE"],
           !suite.isEmpty, let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        return .standard
    }

    func shows(_ control: Control) -> Bool { enabledControls.contains(control) }

    func setShown(_ shown: Bool, for control: Control) {
        guard shows(control) != shown else { return }
        if shown { enabledControls.insert(control) }
        else { enabledControls.remove(control) }
        defaults.set(shown, forKey: control.preferenceKey)
    }

    func presentGuidedSetup() {
        activateMainWindow()
        isGuidedSetupPresented = true
    }
}

struct WorkbenchSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: WorkbenchPreferences
    @EnvironmentObject private var guidedMode: GuidedModeCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GraphitePanel(title: "Navigation and updates") {
                Toggle("Show navigation", isOn: $model.isNavigationVisible)
                    .accessibilityIdentifier("settings-navigation-visible")
                Toggle("Auto-refresh telemetry", isOn: $model.autoRefresh)
                    .accessibilityIdentifier("settings-auto-refresh")
                Button("Refresh Now", systemImage: "arrow.clockwise") {
                    model.refresh(force: true)
                }
                .accessibilityIdentifier("settings-refresh")
                Text("Refresh manually with Command-R. Show or hide navigation with Control-Command-S.")
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isLoading {
                    Label("Refreshing…", systemImage: "arrow.clockwise")
                        .accessibilityIdentifier("settings-refresh-status")
                } else if let updated = model.updated {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Last updated")
                        Text(updated, style: .time).monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .accessibilityIdentifier("settings-refresh-status")
                }
            }
            GraphitePanel(title: "Guidance") {
                Toggle("Show contextual Guided Mode", isOn: $guidedMode.isEnabled)
                    .accessibilityIdentifier("settings-guided-mode")
                Text("Contextual guidance appears within the selected view. The guide and setup review are also available from the Guide menu.")
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Open Guide") {
                        preferences.activateMainWindow()
                        guidedMode.present()
                    }
                    .accessibilityIdentifier("settings-show-guide")
                    Button("Guided Setup") { preferences.presentGuidedSetup() }
                        .accessibilityIdentifier("settings-guided-setup")
                }
            }
            GraphitePanel(title: "Optional view controls") {
                Text("The workspace opens without a control bar. Enable only the shortcuts you want above the current view.")
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(WorkbenchPreferences.Control.allCases, id: \.self) { control in
                    Toggle(control.title, isOn: Binding(
                        get: { preferences.shows(control) },
                        set: { preferences.setShown($0, for: control) }
                    ))
                    .accessibilityIdentifier("settings-control-\(control.rawValue)")
                }
            }
        }
        .toggleStyle(.checkbox)
        .labeledContentStyle(.automatic)
        .font(.system(size: 13))
        .frame(maxWidth: 720, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workbench-settings")
    }
}

/// Compiled sRGB presentation values shared by SwiftUI, AppKit and Metal.
enum GraphitePalette {
    static let window = color(0x101820)
    static let canvas = color(0x101820)
    static let sidebar = color(0x15212B)
    static let panelTop = color(0x1D2D39)
    static let panelBottom = color(0x17232C)
    static let computePanelTop = color(0x030916)
    static let computePanelBottom = color(0x02060D)
    static let panelRaised = color(0x1D2D39)
    static let field = color(0x13202A)
    static let fieldFocused = color(0x243747)
    static let hover = color(0x243747)
    static let separator = color(0x3A5060)
    static let panelBorder = color(0x3A5060)
    static let controlBorder = color(0x6A8596)
    static let textPrimary = color(0xE8F0F7)
    static let textSecondary = color(0xB0C2D0)
    static let textMuted = color(0xA6B3BF)
    static let textDisabled = color(0x748996)
    static let unavailable = color(0xA6B3BF)
    static let selectionTop = color(0x275A87)
    static let selectionBottom = color(0x214D7C)
    static let selectionRail = color(0x62C5FF)
    static let primaryFill = color(0x31D4AA)
    static let primaryHovered = color(0x59E2BF)
    static let primaryPressed = color(0x25B98E)
    static let primaryInk = color(0x08231C)
    static let focus = color(0x62C5FF)
    static let success = color(0x45D6A8)
    static let warning = color(0xF2C45F)
    static let failure = color(0xFF7B82)
    static let info = color(0x72C6FF)
    static let destructiveSurface = color(0x34232A)
    static let destructiveBorder = color(0xD8757F)
    static let chartCPU = color(0x37DCC0)
    static let chartRAM = color(0x4CB4F4)
    static let chartGPU = color(0xA275FF)
    static let chartDisk = color(0xF2C45F)
    static let chartGrid = color(0x40525E)

    static let metalCPU = rgba(0x37DCC0)
    static let metalRAM = rgba(0x4CB4F4)
    static let metalGPU = rgba(0xA275FF)
    static let metalWarning = rgba(0xF2C45F)
    static let metalSuccess = rgba(0x45D6A8)
    static let metalFailure = rgba(0xFF7B82)
    static let metalTrack = rgba(0x3A5060)
    static let metalTrackTop = rgba(0x3A5060)
    static let metalTrackBottom = rgba(0x1D2D39)

    static func color(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
              green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }

    static func rgba(_ rgb: UInt32, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float((rgb >> 16) & 255) / 255, Float((rgb >> 8) & 255) / 255,
              Float(rgb & 255) / 255, alpha)
    }

    /// New sRGB-target chip pipelines receive linear-light inputs exactly once.
    static func linearRGBA(_ rgb: UInt32, alpha: Float = 1) -> SIMD4<Float> {
        let encoded = rgba(rgb, alpha: alpha)
        func linear(_ value: Float) -> Float {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return SIMD4(linear(encoded.x), linear(encoded.y), linear(encoded.z), alpha)
    }

    static let metalClear = MTLClearColor(red: 16.0 / 255, green: 24.0 / 255, blue: 32.0 / 255, alpha: 1)
}

/// Scoped renderer capabilities; normal application views inherit the actual OS settings.
struct GraphiteAccessibilityCapabilities: Equatable, Sendable {
    var increaseContrast = false
    var reduceTransparency = false
}

private struct GraphiteAccessibilityCapabilitiesKey: EnvironmentKey {
    static let defaultValue = GraphiteAccessibilityCapabilities()
}

extension EnvironmentValues {
    var graphiteAccessibilityCapabilities: GraphiteAccessibilityCapabilities {
        get { self[GraphiteAccessibilityCapabilitiesKey.self] }
        set { self[GraphiteAccessibilityCapabilitiesKey.self] = newValue }
    }
}

struct GraphitePanelSurface: View {
    var topColor: Color = GraphitePalette.panelTop
    var bottomColor: Color = GraphitePalette.panelBottom
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.graphiteAccessibilityCapabilities) private var capabilities

    var body: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(LinearGradient(colors: [topColor, bottomColor],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.015), .black.opacity(0.24)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .padding(1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke((contrast == .increased || capabilities.increaseContrast || GraphiteAccessibilityFixture.enabled) ? GraphitePalette.controlBorder : GraphitePalette.panelBorder,
                            lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
    }
}

struct GraphitePanel<Content: View>: View {
    let title: String?
    let surface: GraphitePanelSurface
    @ViewBuilder var content: Content

    init(title: String? = nil, surface: GraphitePanelSurface = GraphitePanelSurface(), @ViewBuilder content: () -> Content) {
        self.title = title
        self.surface = surface
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.system(size: 15, weight: .semibold)) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(surface)
        .accessibilityElement(children: .contain)
    }
}

struct GraphiteGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GraphitePalette.textPrimary)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(GraphitePanelSurface())
        .accessibilityElement(children: .contain)
    }
}

struct GraphitePageHeader: View {
    let title: String
    var subtitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 24, weight: .semibold))
                .foregroundStyle(GraphitePalette.textPrimary)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 13))
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct GraphiteButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.graphiteAccessibilityCapabilities) private var capabilities
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let destructive = kind == .destructive || configuration.role == .destructive
        let primary = kind == .primary && !destructive
        let fill = destructive ? GraphitePalette.destructiveSurface
            : primary ? (configuration.isPressed ? GraphitePalette.primaryPressed : isHovered ? GraphitePalette.primaryHovered : GraphitePalette.primaryFill)
            : GraphitePalette.panelRaised
        let ink = destructive ? GraphitePalette.failure : primary ? GraphitePalette.primaryInk : GraphitePalette.textPrimary
        return configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ink.opacity(isEnabled ? 1 : 0.65))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(fill.opacity(isEnabled ? 1 : 0.45))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(GraphitePalette.hover.opacity(isEnabled && isHovered && !primary && !configuration.isPressed ? 0.40 : 0))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(destructive ? GraphitePalette.destructiveBorder : primary ? GraphitePalette.primaryFill : GraphitePalette.controlBorder,
                                    lineWidth: (contrast == .increased || capabilities.increaseContrast || GraphiteAccessibilityFixture.enabled) ? 1.5 : 1)
                    }
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 8).stroke(GraphitePalette.focus, lineWidth: 2).padding(-3)
                }
            }
            .opacity(configuration.isPressed && !primary ? 0.8 : 1)
            .onHover { isHovered = $0 }
            .animation((reduceMotion || GraphiteAccessibilityFixture.enabled) ? nil : .easeOut(duration: 0.1), value: isHovered)
    }
}

@MainActor
struct GraphiteFieldStyle: @preconcurrency TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        GraphiteFieldDecoration(content: configuration)
    }
}

private struct GraphiteFieldDecoration<Content: View>: View {
    let content: Content
    @FocusState private var focused: Bool

    var body: some View {
        content.textFieldStyle(.plain)
            .focused($focused)
            .font(.system(size: 13))
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(focused ? GraphitePalette.fieldFocused : GraphitePalette.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(GraphitePalette.controlBorder, lineWidth: 1))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: 8).stroke(GraphitePalette.focus, lineWidth: 2).padding(-3)
                }
            }
    }
}

struct GraphiteWorkbenchTreatment: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .foregroundStyle(GraphitePalette.textPrimary)
            .tint(GraphitePalette.info)
            .buttonStyle(GraphiteButtonStyle())
            .textFieldStyle(GraphiteFieldStyle())
            .groupBoxStyle(GraphiteGroupBoxStyle())
            .scrollContentBackground(.hidden)
            .background(GraphitePalette.canvas)
            .preferredColorScheme(.dark)
    }
}

extension View {
    func graphiteWorkbench() -> some View { modifier(GraphiteWorkbenchTreatment()) }
}

/// The fixture affects only explicitly launched UI tests, never desktop preferences.
enum GraphiteAccessibilityFixture {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--uitesting")
        && ProcessInfo.processInfo.environment["FORGE_GRAPHITE_ACCESSIBILITY_VARIANT"] == "1"
}

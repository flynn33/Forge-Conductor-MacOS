// ForgeConductorApp.swift
// What: Defines the process and scene entry points for the native macOS product.
// How: Command-line modes are routed before SwiftUI starts; GUI mode then
// creates scenes, injects AppModel, and activates a regular foreground app.
// Why: One binary can safely serve GUI, manager, and MCP roles without parallel bootstraps.

import SwiftUI
import AppKit
import Combine
import ForgeConductorCore
#if SWIFT_PACKAGE
import ForgeNativeSessionHostPlugin
#endif

/// Process entry: the app binary already receives argv from LaunchAgent and must
/// also accept `serve` from LM Studio. Route non-GUI modes before SwiftUI starts.
@main
enum ForgeConductorMain {
    static func main() {
        ForgeNativeSessionHostPlugin.register()
        // LaunchAgent:  …/Forge Conductor manager run --home …
        // LM Studio:    …/Forge Conductor serve   (+ FORGE_MCP_ROLE)
        // Double-click: no subcommand → GUI
        ForgeProcessEntry.runNonGUIIfNeeded()
        ForgeConductorGUIApp.main()
    }
}

struct ForgeConductorGUIApp: App {
    @NSApplicationDelegateAdaptor(ForgeApplicationDelegate.self) private var appDelegate
    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        Settings {
            ManagerSettingsView(initialSection: .workbench)
                .environmentObject(model)
                .environmentObject(appDelegate.workbench)
                .environmentObject(appDelegate.guidedMode)
                .frame(minWidth: 760, idealWidth: 900, minHeight: 560, idealHeight: 700)
                .graphiteWorkbench()
                .background(ForgeSettingsWindowSizing().allowsHitTesting(false).accessibilityHidden(true))
        }
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .commands {
            ForgeWorkbenchCommands(model: model, workbench: appDelegate.workbench, guidedMode: appDelegate.guidedMode)
        }
    }
}

private struct ForgeSettingsWindowSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> SizingView { SizingView() }
    func updateNSView(_ view: SizingView, context: Context) { view.configureWindow() }

    final class SizingView: NSView {
        private var keyObservation: NSObjectProtocol?
        private var pendingConfiguration: DispatchWorkItem?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyObservation { NotificationCenter.default.removeObserver(keyObservation) }
            keyObservation = nil
            pendingConfiguration?.cancel()
            pendingConfiguration = nil
            if let window {
                keyObservation = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleConfiguration() }
                }
            }
            configureWindow()
            scheduleConfiguration()
        }

        isolated deinit {
            pendingConfiguration?.cancel()
            if let keyObservation { NotificationCenter.default.removeObserver(keyObservation) }
        }

        private func scheduleConfiguration() {
            guard pendingConfiguration == nil, let window else { return }
            let work = DispatchWorkItem { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.pendingConfiguration = nil
                self.configureWindow()
            }
            pendingConfiguration = work
            DispatchQueue.main.async(execute: work)
        }

        func configureWindow() {
            guard let window, !window.styleMask.contains(.resizable) else { return }
            // Preserve the native Settings scene and its content constraints.
            window.styleMask.insert(.resizable)
        }
    }
}

/// Commands subscribe to the same owners as Settings and the main window.
/// App-delegate ownership alone does not provide a dynamic command binding.
@MainActor
private struct ForgeWorkbenchCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var workbench: WorkbenchPreferences
    @ObservedObject var guidedMode: GuidedModeCoordinator

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Navigation") {
            Button(model.isNavigationVisible ? "Hide Navigation" : "Show Navigation") {
                model.toggleNavigation()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
        CommandMenu("Operator") {
            Button("Projects") { model.selectTab(.projects) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Button("Continuity") { model.selectTab(.continuity) }
                .keyboardShortcut("3", modifiers: [.command, .shift])
            Button("Runtimes") { model.selectTab(.runtimes) }
                .keyboardShortcut("4", modifiers: [.command, .shift])
            Button("Provider") { model.selectTab(.provider) }
                .keyboardShortcut("5", modifiers: [.command, .shift])
            Button("Events & Evidence") { model.selectTab(.evidence) }
                .keyboardShortcut("6", modifiers: [.command, .shift])
        }
        CommandMenu("Telemetry") {
            Button("Refresh Now") { model.refresh(force: true) }
                .keyboardShortcut("r", modifiers: [.command])
            Toggle(
                "Auto-refresh",
                isOn: Binding(
                    get: { model.autoRefresh },
                    set: { model.autoRefresh = $0 }
                )
            )
        }
        CommandMenu("Guide") {
            Button("View Guide") {
                workbench.activateMainWindow()
                guidedMode.present()
            }
            Button("Guided Setup") { workbench.presentGuidedSetup() }
            Toggle("Guided Mode", isOn: Binding(
                get: { guidedMode.isEnabled },
                set: { guidedMode.isEnabled = $0 }
            ))
        }
    }
}

@MainActor
final class ForgeApplicationDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model = AppModel()
    let workbench = WorkbenchPreferences()
    let guidedMode = GuidedModeCoordinator()

    private var modelObservation: AnyCancellable?
    private var workbenchObservation: AnyCancellable?
    private var guidedModeObservation: AnyCancellable?
    private var mainWindowController: ForgeMainWindowController?

    override init() {
        super.init()
        modelObservation = model.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        workbenchObservation = workbench.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        guidedModeObservation = guidedMode.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        workbench.activateMainWindow = { [weak self] in self?.presentMainWindow() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        presentMainWindow()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        presentMainWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.cancelBackgroundOperations()
        model.cancelSecureFilesystemServiceOperation()
    }

    private func presentMainWindow() {
        if let controller = mainWindowController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = ForgeMainWindowController(model: model, workbench: workbench, guidedMode: guidedMode)
        mainWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class ForgeMainWindowController: NSWindowController {
    init(model: AppModel, workbench: WorkbenchPreferences, guidedMode: GuidedModeCoordinator) {
        let content = ContentView()
            .environmentObject(model)
            .environmentObject(workbench)
            .environmentObject(guidedMode)
            .frame(minWidth: 1100, minHeight: 720)
        let hostingController = NSHostingController(rootView: content)
        let testing = ProcessInfo.processInfo.arguments.contains("--uitesting")
        let minimumFixture = testing
            && ProcessInfo.processInfo.environment["FORGE_GRAPHITE_WINDOW_SIZE"] == "minimum"
        let contentSize = minimumFixture ? NSSize(width: 1100, height: 720) : NSSize(width: 1440, height: 900)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Forge Conductor"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(GraphitePalette.window)
        // Native chrome contains only the title. Optional shortcuts are opt-in
        // content controls; every action also remains available in Settings/menus.
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.identifier = NSUserInterfaceItemIdentifier("forge-main-window")
        window.tabbingMode = .disallowed
        window.contentViewController = hostingController
        // The hosting controller can adopt its fitting minimum when installed.
        // Apply the intended content size after ownership has been established.
        window.setContentSize(contentSize)
        if testing { window.isRestorable = false }
        // The SwiftUI minimum applies to content, not the outer frame including
        // title bar. Keep AppKit's resize boundary consistent.
        window.contentMinSize = NSSize(width: 1100, height: 720)
        window.isReleasedWhenClosed = false
        window.center()
        if testing, let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.midX - window.frame.width / 2,
                y: visible.midY - window.frame.height / 2
            ))
        }
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

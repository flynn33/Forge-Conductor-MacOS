// ForgeProcessEntry.swift
// What: Routes a shared executable into GUI, MCP-server, or manager process modes.
// How: It parses argv before UI startup, resolves the configured home, and transfers
// control to the corresponding Core service with one well-defined exit path.
// Why: A unified binary remains safe only when mutually exclusive roles are explicit.

import Foundation
import Darwin

/// Shared process entry for the **app binary** and any host that spawns it with argv.
///
/// Evidence already in-tree:
/// - LaunchAgent ProgramArguments: `Forge Conductor.app/.../Forge Conductor manager run --home …`
///   (`ManagerInstaller.installLoginAgent`)
/// - LM Studio mcp.json / mcpBridge should spawn: `…/Forge Conductor serve` (stdio MCP)
///
/// Until this router runs, the SwiftUI `@main` ignored argv and never spoke MCP.
public enum ForgeProcessEntry {
    public enum ServeArgumentError: Error, LocalizedError, Equatable {
        case duplicateDesktopProvider
        case missingDesktopProvider
        case unsupportedDesktopProvider(String)

        public var errorDescription: String? {
            switch self {
            case .duplicateDesktopProvider:
                "--desktop-provider may be specified only once"
            case .missingDesktopProvider:
                "--desktop-provider requires claude-desktop or codex-desktop"
            case .unsupportedDesktopProvider(let value):
                "unsupported desktop provider: \(value)"
            }
        }
    }

    public enum Mode: Equatable {
        case gui
        case serve
        case providerHook
        case managerRun(openBrowser: Bool)
        case managerOther // start/stop/restart/status — delegated if needed
    }

    public static func parseMode(arguments: [String] = CommandLine.arguments) -> Mode {
        let args = Array(arguments.dropFirst())
        guard let head = args.first else { return .gui }
        switch head {
        case "serve", "mcp-serve", "mcp":
            // `mcp` alone or `mcp serve` → stdio MCP
            return .serve
        case "provider-hook":
            // Argument validation happens in the bounded hook command. Classify
            // even malformed invocations as headless so they can never start UI.
            return .providerHook
        case "manager":
            let sub = args.dropFirst().first ?? "run"
            if sub == "run" || sub.hasPrefix("-") {
                let open = args.contains("--open")
                return .managerRun(openBrowser: open)
            }
            // Other manager subcommands still run headless via Core (no full CLI surface).
            return .managerOther
        default:
            return .gui
        }
    }

    public static func homeOverride(from arguments: [String] = CommandLine.arguments) -> URL? {
        let args = Array(arguments.dropFirst())
        if let idx = args.firstIndex(of: "--home"), args.index(after: idx) < args.endIndex {
            let raw = args[args.index(after: idx)] as NSString
            return URL(fileURLWithPath: raw.expandingTildeInPath, isDirectory: true)
        }
        return nil
    }

    /// Returns the immutable package role selected by a generated desktop MCP
    /// command. Environment variables cannot opt an ordinary `serve` process
    /// into this authority-bearing role.
    public static func desktopProviderID(
        inServeArguments arguments: [String]
    ) throws -> ProviderIntegrationID? {
        let indices = arguments.indices.filter { arguments[$0] == "--desktop-provider" }
        guard indices.count <= 1 else { throw ServeArgumentError.duplicateDesktopProvider }
        guard let index = indices.first else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex,
              !arguments[valueIndex].hasPrefix("-") else {
            throw ServeArgumentError.missingDesktopProvider
        }
        let value = arguments[valueIndex]
        guard let providerID = ProviderIntegrationID(rawValue: value),
              DesktopProviderMCPAttachmentRequest.isSelectableDesktopProvider(providerID) else {
            throw ServeArgumentError.unsupportedDesktopProvider(value)
        }
        return providerID
    }

    /// Run stdio MCP until stdin closes. Does not return on success (process exits 0).
    public static func runServe(
        home: URL? = nil,
        arguments: [String] = CommandLine.arguments
    ) -> Never {
        do {
            let desktopProviderID = try desktopProviderID(inServeArguments: arguments)
            let app = try ForgeApp.bootstrap(
                home: home ?? homeOverride(from: arguments)
            )
            // MCP owns stdout. Normal lifecycle diagnostics are persisted by
            // DiagnosticLog; keep stderr quiet unless startup actually fails.
            let server = if let desktopProviderID {
                MCPServer(
                    app: app,
                    role: .primary,
                    desktopProviderID: desktopProviderID
                )
            } else {
                MCPServer(app: app)
            }
            do {
                try server.run()
            } catch {
                _ = app.shutdown()
                throw error
            }
            let shutdownReport = app.shutdown()
            guard shutdownReport.completed else {
                fputs("forge-conductor serve shutdown incomplete\n", stderr)
                exit(1)
            }
            exit(0)
        } catch {
            fputs("forge-conductor serve error: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Foreground manager (LaunchAgent path). Blocks until stop.
    public static func runManager(home: URL? = nil, openBrowser: Bool = false) -> Never {
        do {
            let app = try ForgeApp.bootstrap(home: home ?? homeOverride())
            let node = ManagerNode(app: app)
            try node.run(openBrowser: openBrowser)
            exit(0)
        } catch {
            fputs("forge-conductor manager error: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Run one authenticated desktop-provider hook without bootstrapping `ForgeApp`.
    public static func runProviderHook(
        arguments: [String] = CommandLine.arguments
    ) -> Never {
        do {
            try DesktopProviderHookCommand.run(arguments: Array(arguments.dropFirst(2)))
            exit(0)
        } catch {
            // Hook stdout is a protocol channel. Keep diagnostics generic and
            // never include payloads, credentials, or configured filesystem paths.
            fputs("forge-conductor provider-hook failed\n", stderr)
            exit(2)
        }
    }

    /// Handle non-GUI modes. Returns only when mode is `.gui` (caller should start SwiftUI).
    public static func runNonGUIIfNeeded(arguments: [String] = CommandLine.arguments) {
        switch parseMode(arguments: arguments) {
        case .gui:
            return
        case .serve:
            runServe(home: homeOverride(from: arguments), arguments: arguments)
        case .providerHook:
            runProviderHook(arguments: arguments)
        case .managerRun(let open):
            runManager(home: homeOverride(from: arguments), openBrowser: open)
        case .managerOther:
            // Minimal support: only `run` is required for LaunchAgent. Other subcommands
            // remain on the CLI target (`forge-conductor manager …`).
            fputs("forge-conductor: use CLI for manager subcommands other than run, or launch without args for GUI\n", stderr)
            exit(2)
        }
    }
}

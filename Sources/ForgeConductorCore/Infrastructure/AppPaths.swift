// AppPaths.swift
// What: Defines every on-disk location owned by a Forge installation.
// How: A single home URL derives configuration, database, logs, exports, runtime,
// agents, and binary paths and creates the required directory layout.
// Why: Central ownership prevents modules from inventing incompatible filesystem paths.

import Foundation

/// On-disk layout under FORGE_CONDUCTOR_HOME (default ~/.forge-conductor).
public final class AppPaths: @unchecked Sendable {
    public let home: URL

    public init(home: URL? = nil) {
        if let home {
            self.home = home.standardizedFileURL
        } else if let env = ProcessInfo.processInfo.environment["FORGE_CONDUCTOR_HOME"], !env.isEmpty {
            self.home = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            self.home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".forge-conductor", isDirectory: true)
        }
    }

    public var storeSQLite: URL { home.appendingPathComponent("store.sqlite") }
    public var controlPlaneSQLite: URL { home.appendingPathComponent("control-plane.sqlite3") }
    public var auditJSONL: URL { home.appendingPathComponent("audit.jsonl") }
    public var configJSON: URL { home.appendingPathComponent("config.json") }
    public var configMigrationsDir: URL { home.appendingPathComponent("config-migrations", isDirectory: true) }
    public var configMigrationLock: URL { configMigrationsDir.appendingPathComponent(".schema-v2.lock") }
    public var shellPolicyMigrationReceipt: URL {
        configMigrationsDir.appendingPathComponent("shell-policy-v2.json")
    }
    public var agentsDir: URL { home.appendingPathComponent("agents", isDirectory: true) }
    public var cacheDir: URL { home.appendingPathComponent("cache", isDirectory: true) }
    public var logsDir: URL { home.appendingPathComponent("logs", isDirectory: true) }
    public var agentDiagnostics: URL { logsDir.appendingPathComponent("agent-diagnostics.jsonl") }
    public var toolDiagnostics: URL { logsDir.appendingPathComponent("tool-diagnostics.jsonl") }
    public var failoverDiagnostics: URL { logsDir.appendingPathComponent("failover-diagnostics.jsonl") }
    /// Master append-only diagnostic stream (JSONL).
    public var masterDiagnostics: URL { logsDir.appendingPathComponent(DiagnosticLog.masterLogName) }
    /// Operator exports (.json / .md).
    public var exportsDir: URL { home.appendingPathComponent("exports", isDirectory: true) }
    public var dashboardDir: URL { home.appendingPathComponent("dashboard", isDirectory: true) }
    public var managerPid: URL { home.appendingPathComponent("manager.pid") }
    public var managerLog: URL { logsDir.appendingPathComponent("manager.log") }
    public var managerState: URL { home.appendingPathComponent("manager-state.json") }
    /// Per-user bearer credential for loopback manager mutations. The credential
    /// store creates this file atomically with owner-only permissions and never
    /// includes its contents in configuration, status, diagnostics, or exports.
    public var managerControlCredential: URL {
        home.appendingPathComponent("manager-control.secret")
    }

    /// Durable project memory (markdown) for cross-chat continuity.
    public var memoryDir: URL { home.appendingPathComponent("memory", isDirectory: true) }
    public var memoryHandoffsDir: URL { memoryDir.appendingPathComponent("handoffs", isDirectory: true) }
    public var memoryContinuityLock: URL { memoryDir.appendingPathComponent(".continuity.lock") }
    public var memoryCurrentTask: URL { memoryDir.appendingPathComponent("current-task.md") }
    public var memoryNextChat: URL { memoryDir.appendingPathComponent("NEXT-CHAT.md") }
    public var memoryIndex: URL { memoryDir.appendingPathComponent("INDEX.md") }

    /// Isolated durable databases for project-scoped MCP memory.
    public var projectsDir: URL { home.appendingPathComponent("Projects", isDirectory: true) }
    public var projectRegistry: URL { projectsDir.appendingPathComponent("registry.json") }
    public var runtimeArtifactsDir: URL {
        home.appendingPathComponent("runtime-artifacts", isDirectory: true)
    }
    /// Durable configuration and idempotency ledgers for statically registered
    /// manager-owned model providers. Each adapter receives its own child directory.
    public var managedProvidersDir: URL {
        home.appendingPathComponent("managed-providers", isDirectory: true)
    }

    @discardableResult
    public func ensureLayout() throws -> URL {
        let fm = FileManager.default
        for dir in [
            home, agentsDir, cacheDir, logsDir, dashboardDir, exportsDir,
            memoryDir, memoryHandoffsDir, projectsDir, runtimeArtifactsDir,
            managedProvidersDir, configMigrationsDir,
            cacheDir.appendingPathComponent("browser", isDirectory: true),
        ] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: configJSON.path) {
            let cfg: [String: Any] = [
                "config_schema_version": AppConfig.currentSchemaVersion,
                "log_level": "info",
                "allowed_roots": [] as [String],
                "shell": [
                    "enabled": true,
                    "user_disabled": false,
                    "policy_version": AppConfig.currentSchemaVersion,
                    "policy_origin": "default_enabled",
                    "default_timeout_sec": 30,
                ] as [String: Any],
                "dashboard": [
                    "host": "127.0.0.1",
                    "port": 7788,
                    "refresh_interval_sec": 8,
                ] as [String: Any],
                "manager": [
                    "auto_restart": true,
                    "watchdog_interval_sec": 3,
                    "open_browser_on_start": false,
                ] as [String: Any],
                "mcp": ["role": "primary"],
                "sessions": ["idle_ttl_sec": 14_400],
            ]
            try JSONSupport.data(from: cfg).write(to: configJSON, options: .atomic)
        }
        return home
    }
}

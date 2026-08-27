// AppConfig.swift
// What: Defines the durable, typed configuration contract for every module.
// How: Codable nested values provide defaults, dictionary migration, patch merging,
// and validation without exposing persistence details to consumers.
// Why: One domain model prevents CLI, GUI, and manager settings from drifting.

import Foundation

/// Fully typed application configuration (Codable domain model).
/// Dictionaries exist only when merging legacy JSON patches at the store edge.
public struct AppConfig: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 2

    public var configSchemaVersion: Int
    public var configMigrationID: String?
    public var logLevel: String
    public var allowedRoots: [String]
    public var shell: ShellConfig
    public var dashboard: DashboardConfig
    public var manager: ManagerConfigSection
    public var mcp: MCPConfig
    public var sessions: SessionsConfig
    public var coordinator: CoordinatorConfig

    public struct ShellConfig: Sendable, Equatable, Codable {
        public var enabled: Bool
        public var userDisabled: Bool
        public var policyVersion: Int
        public var policyOrigin: String
        public var defaultTimeoutSec: Int

        public init(
            enabled: Bool = true,
            userDisabled: Bool = false,
            policyVersion: Int = AppConfig.currentSchemaVersion,
            policyOrigin: String = "default_enabled",
            defaultTimeoutSec: Int = 30
        ) {
            self.enabled = enabled
            self.userDisabled = userDisabled
            self.policyVersion = policyVersion
            self.policyOrigin = policyOrigin
            self.defaultTimeoutSec = defaultTimeoutSec
        }

        enum CodingKeys: String, CodingKey {
            case enabled
            case userDisabled = "user_disabled"
            case policyVersion = "policy_version"
            case policyOrigin = "policy_origin"
            case defaultTimeoutSec = "default_timeout_sec"
        }
    }

    public struct DashboardConfig: Sendable, Equatable, Codable {
        public var host: String
        public var port: Int
        public var refreshIntervalSec: Int
        public init(host: String = "127.0.0.1", port: Int = 7788, refreshIntervalSec: Int = 8) {
            self.host = host
            self.port = port
            self.refreshIntervalSec = refreshIntervalSec
        }

        enum CodingKeys: String, CodingKey {
            case host, port
            case refreshIntervalSec = "refresh_interval_sec"
        }
    }

    public struct ManagerConfigSection: Sendable, Equatable, Codable {
        public var autoRestart: Bool
        public var watchdogIntervalSec: Int
        public var openBrowserOnStart: Bool
        public init(autoRestart: Bool = true, watchdogIntervalSec: Int = 3, openBrowserOnStart: Bool = false) {
            self.autoRestart = autoRestart
            self.watchdogIntervalSec = watchdogIntervalSec
            self.openBrowserOnStart = openBrowserOnStart
        }

        enum CodingKeys: String, CodingKey {
            case autoRestart = "auto_restart"
            case watchdogIntervalSec = "watchdog_interval_sec"
            case openBrowserOnStart = "open_browser_on_start"
        }
    }

    public struct MCPConfig: Sendable, Equatable, Codable {
        public var role: String
        public init(role: String = "primary") { self.role = role }
    }

    public struct SessionsConfig: Sendable, Equatable, Codable {
        public var idleTTLSec: Int
        public init(idleTTLSec: Int = 14_400) { self.idleTTLSec = idleTTLSec }
        enum CodingKeys: String, CodingKey { case idleTTLSec = "idle_ttl_sec" }
    }

    public struct CoordinatorConfig: Sendable, Equatable, Codable {
        public var enabled: Bool
        public var leaseTTLSec: Int
        public var presenceTTLSec: Int
        public init(enabled: Bool = true, leaseTTLSec: Int = 60, presenceTTLSec: Int = 30) {
            self.enabled = enabled
            self.leaseTTLSec = leaseTTLSec
            self.presenceTTLSec = presenceTTLSec
        }

        enum CodingKeys: String, CodingKey {
            case enabled
            case leaseTTLSec = "lease_ttl_sec"
            case presenceTTLSec = "presence_ttl_sec"
        }
    }

    public static let `default` = AppConfig(
        configSchemaVersion: currentSchemaVersion,
        configMigrationID: nil,
        logLevel: "info",
        allowedRoots: [],
        shell: ShellConfig(),
        dashboard: DashboardConfig(),
        manager: ManagerConfigSection(),
        mcp: MCPConfig(),
        sessions: SessionsConfig(),
        coordinator: CoordinatorConfig()
    )

    public init(
        configSchemaVersion: Int = AppConfig.currentSchemaVersion,
        configMigrationID: String? = nil,
        logLevel: String = "info",
        allowedRoots: [String] = [],
        shell: ShellConfig = ShellConfig(),
        dashboard: DashboardConfig = DashboardConfig(),
        manager: ManagerConfigSection = ManagerConfigSection(),
        mcp: MCPConfig = MCPConfig(),
        sessions: SessionsConfig = SessionsConfig(),
        coordinator: CoordinatorConfig = CoordinatorConfig()
    ) {
        self.configSchemaVersion = configSchemaVersion
        self.configMigrationID = configMigrationID
        self.logLevel = logLevel
        self.allowedRoots = allowedRoots
        self.shell = shell
        self.dashboard = dashboard
        self.manager = manager
        self.mcp = mcp
        self.sessions = sessions
        self.coordinator = coordinator
    }

    enum CodingKeys: String, CodingKey {
        case configSchemaVersion = "config_schema_version"
        case configMigrationID = "config_migration_id"
        case logLevel = "log_level"
        case allowedRoots = "allowed_roots"
        case shell, dashboard, manager, mcp, sessions, coordinator
    }

    /// Dictionary form for atomic JSON write / deep-merge edge.
    public func asDictionary() -> [String: Any] {
        var dictionary: [String: Any] = [
            "config_schema_version": configSchemaVersion,
            "log_level": logLevel,
            "allowed_roots": allowedRoots,
            "shell": [
                "enabled": shell.enabled,
                "user_disabled": shell.userDisabled,
                "policy_version": shell.policyVersion,
                "policy_origin": shell.policyOrigin,
                "default_timeout_sec": shell.defaultTimeoutSec,
            ] as [String: Any],
            "dashboard": [
                "host": dashboard.host,
                "port": dashboard.port,
                "refresh_interval_sec": dashboard.refreshIntervalSec,
            ] as [String: Any],
            "manager": [
                "auto_restart": manager.autoRestart,
                "watchdog_interval_sec": manager.watchdogIntervalSec,
                "open_browser_on_start": manager.openBrowserOnStart,
            ] as [String: Any],
            "mcp": ["role": mcp.role] as [String: Any],
            "sessions": ["idle_ttl_sec": sessions.idleTTLSec] as [String: Any],
            "coordinator": [
                "enabled": coordinator.enabled,
                "lease_ttl_sec": coordinator.leaseTTLSec,
                "presence_ttl_sec": coordinator.presenceTTLSec,
            ] as [String: Any],
        ]
        if let configMigrationID {
            dictionary["config_migration_id"] = configMigrationID
        }
        return dictionary
    }

    public static func fromDictionary(_ dict: [String: Any]) -> AppConfig {
        var base = AppConfig.default
        if let v = integer(dict["config_schema_version"]) { base.configSchemaVersion = v }
        if let v = dict["config_migration_id"] as? String { base.configMigrationID = v }
        if let v = dict["log_level"] as? String { base.logLevel = v }
        if let v = dict["allowed_roots"] as? [String] { base.allowedRoots = v }
        if let shell = dict["shell"] as? [String: Any] {
            if let enabled = shell["enabled"] as? Bool { base.shell.enabled = enabled }
            if let disabled = shell["user_disabled"] as? Bool { base.shell.userDisabled = disabled }
            if let version = integer(shell["policy_version"]) { base.shell.policyVersion = version }
            if let origin = shell["policy_origin"] as? String { base.shell.policyOrigin = origin }
            if let t = shell["default_timeout_sec"] as? Int { base.shell.defaultTimeoutSec = t }
            else if let t = shell["default_timeout_sec"] as? Double { base.shell.defaultTimeoutSec = Int(t) }
        }
        if let dash = dict["dashboard"] as? [String: Any] {
            if let h = dash["host"] as? String { base.dashboard.host = h }
            if let p = dash["port"] as? Int { base.dashboard.port = p }
            else if let p = dash["port"] as? Double { base.dashboard.port = Int(p) }
            if let r = dash["refresh_interval_sec"] as? Int { base.dashboard.refreshIntervalSec = r }
            else if let r = dash["refresh_interval_sec"] as? Double { base.dashboard.refreshIntervalSec = Int(r) }
        }
        if let mgr = dict["manager"] as? [String: Any] {
            if let v = mgr["auto_restart"] as? Bool { base.manager.autoRestart = v }
            if let v = mgr["watchdog_interval_sec"] as? Int { base.manager.watchdogIntervalSec = v }
            else if let v = mgr["watchdog_interval_sec"] as? Double { base.manager.watchdogIntervalSec = Int(v) }
            if let v = mgr["open_browser_on_start"] as? Bool { base.manager.openBrowserOnStart = v }
        }
        if let mcp = dict["mcp"] as? [String: Any], let role = mcp["role"] as? String {
            base.mcp.role = role
        }
        if let sessions = dict["sessions"] as? [String: Any] {
            if let t = sessions["idle_ttl_sec"] as? Int { base.sessions.idleTTLSec = t }
            else if let t = sessions["idle_ttl_sec"] as? Double { base.sessions.idleTTLSec = Int(t) }
        }
        if let c = dict["coordinator"] as? [String: Any] {
            if let v = c["enabled"] as? Bool { base.coordinator.enabled = v }
            if let v = c["lease_ttl_sec"] as? Int { base.coordinator.leaseTTLSec = v }
            if let v = c["presence_ttl_sec"] as? Int { base.coordinator.presenceTTLSec = v }
        }
        return base
    }

    /// Apply a nested dictionary patch (legacy / HTTP) onto this model.
    public func applying(patch: [String: Any]) -> AppConfig {
        var merged = deepMerge(asDictionary(), patch)
        if let requestedShell = patch["shell"] as? [String: Any],
           let enabled = requestedShell["enabled"] as? Bool {
            var shell = merged["shell"] as? [String: Any] ?? [:]
            shell["enabled"] = enabled
            shell["user_disabled"] = !enabled
            shell["policy_version"] = Self.currentSchemaVersion
            shell["policy_origin"] = enabled ? "user_enabled" : "user_disabled"
            merged["shell"] = shell
            merged["config_schema_version"] = Self.currentSchemaVersion
        }
        return AppConfig.fromDictionary(merged)
    }

    public func applying(settings: ManagerSettingsPatch) -> AppConfig {
        applying(patch: settings.asConfigPatch())
    }

    private func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let bv = base[k] as? [String: Any], let ov = v as? [String: Any] {
                out[k] = deepMerge(bv, ov)
            } else {
                out[k] = v
            }
        }
        return out
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

/// Installed executable paths reported independently from the shell preference.
public struct ShellRuntimeCapabilities: Sendable, Equatable {
    public var zsh: String?
    public var bash: String?
    public var python: String?
    public var powershell: String?

    public init(zsh: String?, bash: String?, python: String?, powershell: String?) {
        self.zsh = zsh
        self.bash = bash
        self.python = python
        self.powershell = powershell
    }

    public static func detect() -> ShellRuntimeCapabilities {
        ShellRuntimeCapabilities(
            zsh: executable(named: "zsh", preferredPath: "/bin/zsh"),
            bash: executable(named: "bash", preferredPath: "/bin/bash"),
            python: executable(named: "python3"),
            powershell: executable(named: "pwsh")
        )
    }

    public func asDictionary() -> [String: Any] {
        [
            "zsh": capability(zsh),
            "bash": capability(bash),
            "python": capability(python),
            "powershell": capability(powershell),
        ]
    }

    private static func executable(named name: String, preferredPath: String? = nil) -> String? {
        if let preferredPath,
           FileManager.default.isExecutableFile(atPath: preferredPath) {
            return preferredPath
        }
        return ProcessRunner.which(name)
    }

    private func capability(_ path: String?) -> [String: Any] {
        [
            "available": path != nil,
            "path": path as Any,
        ].compactNSNull()
    }
}

/// Durable result of inspecting or applying the shell-policy migration.
public struct ShellPolicyMigrationStatus: Sendable, Equatable {
    public var state: String
    public var sourceSchemaVersion: Int
    public var targetSchemaVersion: Int
    public var receiptValid: Bool
    public var migrationID: String?
    public var diagnosticPending: Bool
    public var detail: String

    public init(
        state: String,
        sourceSchemaVersion: Int,
        targetSchemaVersion: Int = AppConfig.currentSchemaVersion,
        receiptValid: Bool,
        migrationID: String? = nil,
        diagnosticPending: Bool = false,
        detail: String
    ) {
        self.state = state
        self.sourceSchemaVersion = sourceSchemaVersion
        self.targetSchemaVersion = targetSchemaVersion
        self.receiptValid = receiptValid
        self.migrationID = migrationID
        self.diagnosticPending = diagnosticPending
        self.detail = detail
    }

    public static let notChecked = ShellPolicyMigrationStatus(
        state: "not_checked",
        sourceSchemaVersion: AppConfig.currentSchemaVersion,
        receiptValid: false,
        detail: "Configuration has not been loaded"
    )

    public func asDictionary() -> [String: Any] {
        [
            "state": state,
            "source_schema_version": sourceSchemaVersion,
            "target_schema_version": targetSchemaVersion,
            "receipt_valid": receiptValid,
            "migration_id": migrationID as Any,
            "diagnostic_pending": diagnosticPending,
            "detail": detail,
        ].compactNSNull()
    }
}

/// Effective shell policy used by status, doctor, manager, and native settings.
public struct ShellPolicyStatus: Sendable, Equatable {
    public var enabled: Bool
    public var userDisabled: Bool
    public var policyVersion: Int
    public var policyOrigin: String
    public var defaultTimeoutSec: Int
    public var migration: ShellPolicyMigrationStatus
    public var runtimes: ShellRuntimeCapabilities

    public func asDictionary() -> [String: Any] {
        [
            "enabled": enabled,
            "user_disabled": userDisabled,
            "policy_version": policyVersion,
            "policy_origin": policyOrigin,
            "default_timeout_sec": defaultTimeoutSec,
            "migration": migration.asDictionary(),
            "runtimes": runtimes.asDictionary(),
        ]
    }
}

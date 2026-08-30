// ManagerModels.swift
// What: Defines manager status, editable settings, patches, and telemetry health.
// How: Value types validate dictionary input and emit stable wire representations used
// by the manager client, routes, CLI, and SwiftUI settings module.
// Why: A shared contract prevents control-plane request/response drift.

import Foundation

/// Typed manager runtime status (no dictionary in domain path).
public struct ManagerStatus: Sendable, Equatable {
    public var ok: Bool
    public var isManager: Bool
    public var state: ManagerServiceState
    public var desiredRunning: Bool
    public var httpListening: Bool
    public var serviceActive: Bool
    public var pid: Int32
    public var startedAt: Date?
    public var uptimeSec: Int?
    public var restartCount: Int
    public var lastError: String?
    public var autoRestart: Bool
    public var watchdogIntervalSec: Int
    public var openBrowserOnStart: Bool
    public var dashboardHost: String
    public var dashboardPort: Int
    public var dashboardRefreshSec: Int
    public var home: String
    public var version: String

    public init(
        ok: Bool,
        isManager: Bool,
        state: ManagerServiceState,
        desiredRunning: Bool,
        httpListening: Bool,
        serviceActive: Bool,
        pid: Int32,
        startedAt: Date?,
        uptimeSec: Int?,
        restartCount: Int,
        lastError: String?,
        autoRestart: Bool,
        watchdogIntervalSec: Int,
        openBrowserOnStart: Bool,
        dashboardHost: String,
        dashboardPort: Int,
        dashboardRefreshSec: Int,
        home: String,
        version: String
    ) {
        self.ok = ok
        self.isManager = isManager
        self.state = state
        self.desiredRunning = desiredRunning
        self.httpListening = httpListening
        self.serviceActive = serviceActive
        self.pid = pid
        self.startedAt = startedAt
        self.uptimeSec = uptimeSec
        self.restartCount = restartCount
        self.lastError = lastError
        self.autoRestart = autoRestart
        self.watchdogIntervalSec = watchdogIntervalSec
        self.openBrowserOnStart = openBrowserOnStart
        self.dashboardHost = dashboardHost
        self.dashboardPort = dashboardPort
        self.dashboardRefreshSec = dashboardRefreshSec
        self.home = home
        self.version = version
    }

    /// Decodes the stable HTTP boundary without coupling the domain model to
    /// URLSession or Codable's key-shape conventions.
    public init(dictionary: [String: Any]) throws {
        guard let stateName = dictionary["state"] as? String,
              let state = ManagerServiceState(rawValue: stateName),
              let dashboard = dictionary["dashboard"] as? [String: Any],
              let port = ManagerJSONValue.int(dashboard["port"]) else {
            throw ManagerModelError.invalidStatus
        }
        self.init(
            ok: ManagerJSONValue.bool(dictionary["ok"]) ?? false,
            isManager: ManagerJSONValue.bool(dictionary["manager"]) ?? false,
            state: state,
            desiredRunning: ManagerJSONValue.bool(dictionary["desired_running"]) ?? false,
            httpListening: ManagerJSONValue.bool(dictionary["http_listening"]) ?? false,
            serviceActive: ManagerJSONValue.bool(dictionary["service_active"]) ?? false,
            pid: Int32(clamping: ManagerJSONValue.int(dictionary["pid"]) ?? 0),
            startedAt: (dictionary["started_at"] as? String).flatMap(ISO8601.date(from:)),
            uptimeSec: ManagerJSONValue.int(dictionary["uptime_sec"]),
            restartCount: ManagerJSONValue.int(dictionary["restart_count"]) ?? 0,
            lastError: dictionary["last_error"] as? String,
            autoRestart: ManagerJSONValue.bool(dictionary["auto_restart"]) ?? true,
            watchdogIntervalSec: ManagerJSONValue.int(dictionary["watchdog_interval_sec"]) ?? 3,
            openBrowserOnStart: ManagerJSONValue.bool(dictionary["open_browser_on_start"]) ?? false,
            dashboardHost: (dashboard["host"] as? String) ?? "127.0.0.1",
            dashboardPort: port,
            dashboardRefreshSec: ManagerJSONValue.int(dashboard["refresh_interval_sec"]) ?? 8,
            home: (dictionary["home"] as? String) ?? "",
            version: (dictionary["version"] as? String) ?? ""
        )
    }

    public var dashboardURL: String {
        "http://\(dashboardHost):\(dashboardPort)/"
    }

    /// Serialization boundary only (HTTP / legacy UI).
    public func asDictionary() -> [String: Any] {
        [
            "ok": ok,
            "manager": isManager,
            "state": state.rawValue,
            "desired_running": desiredRunning,
            "http_listening": httpListening,
            "service_active": serviceActive,
            "pid": Int(pid),
            "started_at": startedAt.map { ISO8601.string(from: $0) } as Any,
            "uptime_sec": uptimeSec as Any,
            "restart_count": restartCount,
            "last_error": lastError as Any,
            "auto_restart": autoRestart,
            "watchdog_interval_sec": watchdogIntervalSec,
            "open_browser_on_start": openBrowserOnStart,
            "dashboard": [
                "host": dashboardHost,
                "port": dashboardPort,
                "url": dashboardURL,
                "refresh_interval_sec": dashboardRefreshSec,
            ] as [String: Any],
            "home": home,
            "version": version,
        ]
    }
}

public struct ManagerSettings: Sendable, Equatable {
    public var dashboardHost: String
    public var dashboardPort: Int
    public var dashboardRefreshSec: Int
    public var autoRestart: Bool
    public var watchdogIntervalSec: Int
    public var openBrowserOnStart: Bool
    public var sessionIdleTTLSec: Int
    public var shellEnabled: Bool
    public var shellUserDisabled: Bool
    public var shellPolicyVersion: Int
    public var shellPolicyOrigin: String
    public var shellMigrationState: String
    public var shellMigrationReceiptValid: Bool
    public var shellRuntimeCapabilities: ShellRuntimeCapabilities
    public var shellTimeoutSec: Int
    public var logLevel: String
    public var allowedRoots: [String]

    public init(
        dashboardHost: String,
        dashboardPort: Int,
        dashboardRefreshSec: Int,
        autoRestart: Bool,
        watchdogIntervalSec: Int,
        openBrowserOnStart: Bool,
        sessionIdleTTLSec: Int,
        shellEnabled: Bool,
        shellUserDisabled: Bool,
        shellPolicyVersion: Int,
        shellPolicyOrigin: String,
        shellMigrationState: String,
        shellMigrationReceiptValid: Bool,
        shellRuntimeCapabilities: ShellRuntimeCapabilities,
        shellTimeoutSec: Int,
        logLevel: String,
        allowedRoots: [String] = []
    ) {
        self.dashboardHost = dashboardHost
        self.dashboardPort = dashboardPort
        self.dashboardRefreshSec = dashboardRefreshSec
        self.autoRestart = autoRestart
        self.watchdogIntervalSec = watchdogIntervalSec
        self.openBrowserOnStart = openBrowserOnStart
        self.sessionIdleTTLSec = sessionIdleTTLSec
        self.shellEnabled = shellEnabled
        self.shellUserDisabled = shellUserDisabled
        self.shellPolicyVersion = shellPolicyVersion
        self.shellPolicyOrigin = shellPolicyOrigin
        self.shellMigrationState = shellMigrationState
        self.shellMigrationReceiptValid = shellMigrationReceiptValid
        self.shellRuntimeCapabilities = shellRuntimeCapabilities
        self.shellTimeoutSec = shellTimeoutSec
        self.logLevel = logLevel
        self.allowedRoots = allowedRoots
    }

    public init(dictionary: [String: Any]) throws {
        guard let dashboard = dictionary["dashboard"] as? [String: Any],
              let manager = dictionary["manager"] as? [String: Any],
              let port = ManagerJSONValue.int(dashboard["port"]) else {
            throw ManagerModelError.invalidSettings
        }
        let sessions = dictionary["sessions"] as? [String: Any] ?? [:]
        let shell = dictionary["shell"] as? [String: Any] ?? [:]
        let migration = shell["migration"] as? [String: Any] ?? [:]
        let runtimes = shell["runtimes"] as? [String: Any] ?? [:]
        self.init(
            dashboardHost: (dashboard["host"] as? String) ?? "127.0.0.1",
            dashboardPort: port,
            dashboardRefreshSec: ManagerJSONValue.int(dashboard["refresh_interval_sec"]) ?? 8,
            autoRestart: ManagerJSONValue.bool(manager["auto_restart"]) ?? true,
            watchdogIntervalSec: ManagerJSONValue.int(manager["watchdog_interval_sec"]) ?? 3,
            openBrowserOnStart: ManagerJSONValue.bool(manager["open_browser_on_start"]) ?? false,
            sessionIdleTTLSec: ManagerJSONValue.int(sessions["idle_ttl_sec"]) ?? 14_400,
            shellEnabled: ManagerJSONValue.bool(shell["enabled"]) ?? false,
            shellUserDisabled: ManagerJSONValue.bool(shell["user_disabled"]) ?? false,
            shellPolicyVersion: ManagerJSONValue.int(shell["policy_version"])
                ?? 1,
            shellPolicyOrigin: (shell["policy_origin"] as? String) ?? "legacy_unknown",
            shellMigrationState: (migration["state"] as? String) ?? "unknown",
            shellMigrationReceiptValid: ManagerJSONValue.bool(migration["receipt_valid"]) ?? false,
            shellRuntimeCapabilities: ShellRuntimeCapabilities(
                zsh: Self.runtimePath(runtimes["zsh"]),
                bash: Self.runtimePath(runtimes["bash"]),
                python: Self.runtimePath(runtimes["python"]),
                powershell: Self.runtimePath(runtimes["powershell"])
            ),
            shellTimeoutSec: ManagerJSONValue.int(shell["default_timeout_sec"]) ?? 30,
            logLevel: (dictionary["log_level"] as? String) ?? "info",
            allowedRoots: dictionary["allowed_roots"] as? [String] ?? []
        )
    }

    public func asDictionary() -> [String: Any] {
        [
            "ok": true,
            "dashboard": [
                "host": dashboardHost,
                "port": dashboardPort,
                "refresh_interval_sec": dashboardRefreshSec,
            ] as [String: Any],
            "manager": [
                "auto_restart": autoRestart,
                "watchdog_interval_sec": watchdogIntervalSec,
                "open_browser_on_start": openBrowserOnStart,
            ] as [String: Any],
            "sessions": [
                "idle_ttl_sec": sessionIdleTTLSec,
            ] as [String: Any],
            "shell": [
                "enabled": shellEnabled,
                "user_disabled": shellUserDisabled,
                "policy_version": shellPolicyVersion,
                "policy_origin": shellPolicyOrigin,
                "default_timeout_sec": shellTimeoutSec,
                "migration": [
                    "state": shellMigrationState,
                    "receipt_valid": shellMigrationReceiptValid,
                ] as [String: Any],
                "runtimes": shellRuntimeCapabilities.asDictionary(),
            ] as [String: Any],
            "log_level": logLevel,
            "allowed_roots": allowedRoots,
        ]
    }

    private static func runtimePath(_ value: Any?) -> String? {
        guard let capability = value as? [String: Any],
              ManagerJSONValue.bool(capability["available"]) == true else { return nil }
        return capability["path"] as? String
    }
}

public enum ManagerModelError: Error, LocalizedError, Sendable {
    case invalidStatus
    case invalidSettings
    case invalidOperatorSnapshot

    public var errorDescription: String? {
        switch self {
        case .invalidStatus: "Manager returned an invalid status payload"
        case .invalidSettings: "Manager returned an invalid settings payload"
        case .invalidOperatorSnapshot: "Manager could not encode the operator snapshot"
        }
    }
}

private enum ManagerJSONValue {
    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }
}

/// Strongly typed settings patch (application → manager).
public struct ManagerSettingsPatch: Sendable, Equatable {
    public var dashboardHost: String?
    public var dashboardPort: Int?
    public var dashboardRefreshSec: Int?
    public var autoRestart: Bool?
    public var watchdogIntervalSec: Int?
    public var openBrowserOnStart: Bool?
    public var sessionIdleTTLSec: Int?
    public var shellEnabled: Bool?
    public var shellTimeoutSec: Int?
    public var logLevel: String?
    public var allowedRoots: [String]?

    public init(
        dashboardHost: String? = nil,
        dashboardPort: Int? = nil,
        dashboardRefreshSec: Int? = nil,
        autoRestart: Bool? = nil,
        watchdogIntervalSec: Int? = nil,
        openBrowserOnStart: Bool? = nil,
        sessionIdleTTLSec: Int? = nil,
        shellEnabled: Bool? = nil,
        shellTimeoutSec: Int? = nil,
        logLevel: String? = nil,
        allowedRoots: [String]? = nil
    ) {
        self.dashboardHost = dashboardHost
        self.dashboardPort = dashboardPort
        self.dashboardRefreshSec = dashboardRefreshSec
        self.autoRestart = autoRestart
        self.watchdogIntervalSec = watchdogIntervalSec
        self.openBrowserOnStart = openBrowserOnStart
        self.sessionIdleTTLSec = sessionIdleTTLSec
        self.shellEnabled = shellEnabled
        self.shellTimeoutSec = shellTimeoutSec
        self.logLevel = logLevel
        self.allowedRoots = allowedRoots
    }

    /// Edge adapter: config store still merges nested dict patches.
    public func asConfigPatch() -> [String: Any] {
        var dash: [String: Any] = [:]
        if let dashboardHost { dash["host"] = dashboardHost }
        if let dashboardPort { dash["port"] = dashboardPort }
        if let dashboardRefreshSec { dash["refresh_interval_sec"] = dashboardRefreshSec }
        var mgr: [String: Any] = [:]
        if let autoRestart { mgr["auto_restart"] = autoRestart }
        if let watchdogIntervalSec { mgr["watchdog_interval_sec"] = watchdogIntervalSec }
        if let openBrowserOnStart { mgr["open_browser_on_start"] = openBrowserOnStart }
        var sessions: [String: Any] = [:]
        if let sessionIdleTTLSec { sessions["idle_ttl_sec"] = sessionIdleTTLSec }
        var shell: [String: Any] = [:]
        if let shellEnabled { shell["enabled"] = shellEnabled }
        if let shellTimeoutSec { shell["default_timeout_sec"] = shellTimeoutSec }
        var patch: [String: Any] = [:]
        if !dash.isEmpty { patch["dashboard"] = dash }
        if !mgr.isEmpty { patch["manager"] = mgr }
        if !sessions.isEmpty { patch["sessions"] = sessions }
        if !shell.isEmpty { patch["shell"] = shell }
        if let logLevel { patch["log_level"] = logLevel }
        if let allowedRoots { patch["allowed_roots"] = allowedRoots }
        return patch
    }
}

public struct TelemetryHealthReport: Sendable, Equatable {
    public var ok: Bool
    public var service: String
    public var runtime: String
    public var interferesWithMCP: Bool
    public var mode: String
    public var collectors: String
    public var ui: String
    public var nodeRequired: Bool

    public func asDictionary() -> [String: Any] {
        [
            "ok": ok,
            "service": service,
            "runtime": runtime,
            "interferes_with_mcp": interferesWithMCP,
            "mode": mode,
            "auth": false,
            "collectors": collectors,
            "ui": ui,
            "export_present": false,
            "static_present": false,
            "node_available": false,
            "node_required": nodeRequired,
        ]
    }
}

// MARK: - Native operator snapshot

/// Bounded, read-only projection consumed by the native operator views.
/// Every nested value is intentionally smaller than its underlying durable record:
/// request bodies, tool arguments, provider output, and runtime output are not part of
/// this contract.
public struct ManagerOperatorSnapshot: Encodable, Sendable, Equatable {
    public let generatedAt: String
    public let limit: Int
    public let projects: [ManagerOperatorProject]
    public let runs: [ManagerOperatorRun]
    public let continuityOperations: [ManagerOperatorContinuity]
    public let runtimeJobs: [ManagerOperatorRuntimeJob]
    public let provider: ManagerOperatorProvider
    public let runtime: ManagerOperatorRuntime
    public let events: [ManagerOperatorEvent]
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case limit, projects, runs
        case continuityOperations = "continuity_operations"
        case runtimeJobs = "runtime_jobs"
        case provider, runtime, events
        case nextCursor = "next_cursor"
    }

    public func asDictionary() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManagerModelError.invalidOperatorSnapshot
        }
        return object
    }
}

public struct ManagerOperatorProject: Encodable, Sendable, Equatable {
    public let projectID: String
    public let displayName: String
    public let canonicalRoot: String
    public let projectGeneration: UInt64
    public let lifecycleState: String
    public let bindings: [ManagerOperatorBinding]
    public let memory: ManagerOperatorMemoryHealth
    public let continuity: ManagerOperatorProjectContinuity
    public let migrationWarnings: [String]
    public let resetReceipt: ManagerOperatorResetReceipt?
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case displayName = "display_name"
        case canonicalRoot = "canonical_root"
        case projectGeneration = "project_generation"
        case lifecycleState = "lifecycle_state"
        case bindings, memory, continuity
        case migrationWarnings = "migration_warnings"
        case resetReceipt = "reset_receipt"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct ManagerOperatorBinding: Encodable, Sendable, Equatable {
    public let bindingID: String
    public let ownerKind: String
    public let ownerID: String
    public let runID: String?
    public let active: Bool

    enum CodingKeys: String, CodingKey {
        case bindingID = "binding_id"
        case ownerKind = "owner_kind"
        case ownerID = "owner_id"
        case runID = "run_id"
        case active
    }
}

public struct ManagerOperatorMemoryHealth: Encodable, Sendable, Equatable {
    public let state: String
    public let databaseBytes: UInt64?
    public let recordCount: Int?
    public let lastIntegrityCheck: String?
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case state, detail
        case databaseBytes = "database_bytes"
        case recordCount = "record_count"
        case lastIntegrityCheck = "last_integrity_check"
    }
}

public struct ManagerOperatorProjectContinuity: Encodable, Sendable, Equatable {
    public let state: String
    public let latestHandoffID: String?
    public let latestHandoffSHA256: String?
    public let migrationState: String?

    enum CodingKeys: String, CodingKey {
        case state
        case latestHandoffID = "latest_handoff_id"
        case latestHandoffSHA256 = "latest_handoff_sha256"
        case migrationState = "migration_state"
    }
}

public struct ManagerOperatorResetReceipt: Encodable, Sendable, Equatable {
    public let priorGeneration: UInt64
    public let newGeneration: UInt64
    public let invalidatedBindingCount: Int
    public let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case priorGeneration = "prior_generation"
        case newGeneration = "new_generation"
        case invalidatedBindingCount = "invalidated_binding_count"
        case completedAt = "completed_at"
    }
}

/// Persistence-only details used while building a run projection. This is deliberately
/// separate from the wire DTO so repository code never manufactures presentation state.
public struct ManagerOperatorRunReadModel: Sendable, Equatable {
    public let run: AutonomousRunRecord
    public let lease: RunLease?
    public let activeSession: ProviderSessionRecord?
    public let latestProviderTurn: ProviderTurnRecord?
    public let latestToolInvocation: ToolInvocationRecord?
    public let budgetState: PersistedContextBudgetState?
}

public struct ManagerOperatorRun: Encodable, Sendable, Equatable {
    public let runID: String
    public let projectID: String
    public let projectGeneration: UInt64
    public let assignmentID: String?
    public let mission: String
    public let state: String
    public let continuityMode: String
    public let providerID: String?
    public let adapterID: String?
    public let modelKey: String?
    public let providerInstanceID: String?
    public let activeSessionID: String?
    public let predecessorSessionID: String?
    public let activeOperationID: String?
    public let continuationPending: Bool
    public let leaseOwner: String?
    public let workItem: String?
    public let lastModelTurnAt: String?
    public let lastToolActivityAt: String?
    public let completionGates: [String]
    public let passedGates: [String]
    public let lastErrorCode: String?
    public let lastErrorSummary: String?
    public let retryAt: String?
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case assignmentID = "assignment_id"
        case mission, state
        case continuityMode = "continuity_mode"
        case providerID = "provider_id"
        case adapterID = "adapter_id"
        case modelKey = "model_key"
        case providerInstanceID = "provider_instance_id"
        case activeSessionID = "active_session_id"
        case predecessorSessionID = "predecessor_session_id"
        case activeOperationID = "active_operation_id"
        case continuationPending = "continuation_pending"
        case leaseOwner = "lease_owner"
        case workItem = "work_item"
        case lastModelTurnAt = "last_model_turn_at"
        case lastToolActivityAt = "last_tool_activity_at"
        case completionGates = "completion_gates"
        case passedGates = "passed_gates"
        case lastErrorCode = "last_error_code"
        case lastErrorSummary = "last_error_summary"
        case retryAt = "retry_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct ManagerOperatorContextBudget: Encodable, Sendable, Equatable {
    public let capacityTokens: Int
    public let usedTokens: Int
    public let responseReserveTokens: Int
    public let handoffReserveTokens: Int
    public let recoveryReserveTokens: Int
    public let remainingTokens: Int
    public let source: String
    public let confidence: String
    public let action: String
    public let checkpointThreshold: Int
    public let rolloverThreshold: Int

    enum CodingKeys: String, CodingKey {
        case capacityTokens = "capacity_tokens"
        case usedTokens = "used_tokens"
        case responseReserveTokens = "response_reserve_tokens"
        case handoffReserveTokens = "handoff_reserve_tokens"
        case recoveryReserveTokens = "recovery_reserve_tokens"
        case remainingTokens = "remaining_tokens"
        case source, confidence, action
        case checkpointThreshold = "checkpoint_threshold"
        case rolloverThreshold = "rollover_threshold"
    }
}

public struct ManagerOperatorContinuityReadModel: Sendable, Equatable {
    public let command: ContinuityCommand
    public let run: AutonomousRunRecord?
    public let predecessor: ProviderSessionRecord?
    public let successor: ProviderSessionRecord?
    public let automaticContinuation: ProviderTurnRecord?
    public let budgetObservation: ContextBudgetObservation?
}

public struct ManagerOperatorContinuity: Encodable, Sendable, Equatable {
    public let operationID: String
    public let projectID: String
    public let projectGeneration: UInt64
    public let runID: String
    public let mode: String
    public let state: String
    public let controlState: String
    public let handoffID: String?
    public let handoffSHA256: String?
    public let predecessorSessionID: String?
    public let successorSessionID: String?
    public let successorProviderResponseID: String?
    public let acknowledgementSHA256: String?
    public let attempt: Int
    public let continuationIssued: Bool
    public let budget: ManagerOperatorContextBudget?
    public let lastError: String?
    public let retryAt: String?
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case runID = "run_id"
        case mode, state
        case controlState = "control_state"
        case handoffID = "handoff_id"
        case handoffSHA256 = "handoff_sha256"
        case predecessorSessionID = "predecessor_session_id"
        case successorSessionID = "successor_session_id"
        case successorProviderResponseID = "successor_provider_response_id"
        case acknowledgementSHA256 = "acknowledgement_sha256"
        case attempt
        case continuationIssued = "continuation_issued"
        case budget
        case lastError = "last_error"
        case retryAt = "retry_at"
        case updatedAt = "updated_at"
    }
}

public struct ManagerOperatorRuntimeJob: Encodable, Sendable, Equatable {
    public let jobID: String
    public let runID: String?
    public let projectID: String
    public let projectGeneration: UInt64
    public let runtimeKind: String
    public let state: String
    public let canonicalWorkingDirectory: String
    public let commandSummary: String
    public let timeoutSeconds: Int
    public let exitCode: Int?
    public let outputArtifactID: String?
    public let outputBytes: UInt64
    public let errorSummary: String?
    public let createdAt: String
    public let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case runID = "run_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case runtimeKind = "runtime_kind"
        case state
        case canonicalWorkingDirectory = "canonical_working_directory"
        case commandSummary = "command_summary"
        case timeoutSeconds = "timeout_seconds"
        case exitCode = "exit_code"
        case outputArtifactID = "output_artifact_id"
        case outputBytes = "output_bytes"
        case errorSummary = "error_summary"
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }
}

public struct ManagerOperatorProvider: Encodable, Sendable, Equatable {
    public let providerID: String?
    public let health: String
    public let endpoint: String?
    public let loopback: Bool?
    public let tls: Bool?
    public let authenticationEnabled: Bool?
    public let credentialConfigured: Bool?
    public let apiMode: String?
    public let modelKey: String?
    public let instanceID: String?
    public let activeContextLength: Int?
    public let maximumContextLength: Int?
    public let toolUseCapable: Bool?
    public let lifecycleManagementEnabled: Bool?
    public let idleTTLSeconds: Int?
    public let contractFingerprint: String?
    public let lastProbeAt: String?
    public let lastProbeError: String?

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case health, endpoint, loopback, tls
        case authenticationEnabled = "authentication_enabled"
        case credentialConfigured = "credential_configured"
        case apiMode = "api_mode"
        case modelKey = "model_key"
        case instanceID = "instance_id"
        case activeContextLength = "active_context_length"
        case maximumContextLength = "maximum_context_length"
        case toolUseCapable = "tool_use_capable"
        case lifecycleManagementEnabled = "lifecycle_management_enabled"
        case idleTTLSeconds = "idle_ttl_seconds"
        case contractFingerprint = "contract_fingerprint"
        case lastProbeAt = "last_probe_at"
        case lastProbeError = "last_probe_error"
    }
}

public struct ManagerOperatorRuntimeExecutable: Encodable, Sendable, Equatable {
    public let available: Bool
    public let path: String?
    public let version: String?
}

public struct ManagerOperatorRuntime: Encodable, Sendable, Equatable {
    public let direct: ManagerOperatorRuntimeExecutable
    public let zsh: ManagerOperatorRuntimeExecutable
    public let bash: ManagerOperatorRuntimeExecutable
    public let python: ManagerOperatorRuntimeExecutable
    public let powershell: ManagerOperatorRuntimeExecutable
    public let maximumConcurrentJobs: Int
    public let defaultTimeoutSeconds: Int
    public let maximumInlineOutputBytes: Int
    public let maximumArtifactBytesPerJob: Int
    public let networkPolicy: String
    public let shellPolicyMigrationState: String

    enum CodingKeys: String, CodingKey {
        case direct, zsh, bash, python, powershell
        case maximumConcurrentJobs = "maximum_concurrent_jobs"
        case defaultTimeoutSeconds = "default_timeout_seconds"
        case maximumInlineOutputBytes = "maximum_inline_output_bytes"
        case maximumArtifactBytesPerJob = "maximum_artifact_bytes_per_job"
        case networkPolicy = "network_policy"
        case shellPolicyMigrationState = "shell_policy_migration_state"
    }
}

public struct ManagerOperatorEvent: Encodable, Sendable, Equatable {
    public let eventID: String
    public let timestamp: String
    public let kind: String
    public let summary: String
    public let severity: String
    public let projectID: String?
    public let runID: String?
    public let operationID: String?
    public let jobID: String?
    public let providerRequestID: String?
    public let artifactID: String?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case timestamp, kind, summary, severity
        case projectID = "project_id"
        case runID = "run_id"
        case operationID = "operation_id"
        case jobID = "job_id"
        case providerRequestID = "provider_request_id"
        case artifactID = "artifact_id"
    }
}

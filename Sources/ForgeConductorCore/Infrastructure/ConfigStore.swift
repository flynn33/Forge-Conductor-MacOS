// ConfigStore.swift
// What: Persists AppConfig and exposes synchronized typed configuration access.
// How: A lock guards the in-memory model while atomic JSON writes, reload, and patch
// operations validate changes before replacing the durable file.
// Why: Readers need one consistent configuration owner across concurrent services.

import Foundation
import Darwin

/// Persistence for `AppConfig`. Domain consumers use `model`; dict update remains for HTTP edge patches.
public final class ConfigStore: ConfigurationProviding, @unchecked Sendable {
    private static let migrationLockTimeout: TimeInterval = 5
    private static let processMigrationLock = NSLock()

    private var _model: AppConfig
    private var _shellMigrationStatus: ShellPolicyMigrationStatus = .notChecked
    private let paths: AppPaths
    private let lock = NSLock()

    /// Thread-safe snapshot of the typed configuration.
    public var model: AppConfig {
        lock.lock(); defer { lock.unlock() }
        return _model
    }

    /// Legacy dictionary view (edge / deep inspection). Prefer `model`.
    public var values: [String: Any] {
        model.asDictionary()
    }

    public var shellMigrationStatus: ShellPolicyMigrationStatus {
        lock.lock(); defer { lock.unlock() }
        return _shellMigrationStatus
    }

    public var shellPolicyStatus: ShellPolicyStatus {
        let config = model.shell
        return ShellPolicyStatus(
            enabled: config.enabled,
            userDisabled: config.userDisabled,
            policyVersion: config.policyVersion,
            policyOrigin: config.policyOrigin,
            defaultTimeoutSec: config.defaultTimeoutSec,
            migration: shellMigrationStatus,
            runtimes: .detect()
        )
    }

    public init(paths: AppPaths) {
        self.paths = paths
        self._model = .default
        reload()
    }

    public static var defaults: [String: Any] { AppConfig.default.asDictionary() }

    public func reload() {
        let loaded: (AppConfig, ShellPolicyMigrationStatus)
        do {
            loaded = try loadAndMigrateIfNeeded()
        } catch {
            var fallback = AppConfig.default
            var sourceVersion = AppConfig.currentSchemaVersion
            if let data = try? Data(contentsOf: paths.configJSON),
               let object = try? JSONSupport.object(from: data) {
                sourceVersion = Self.integer(object["config_schema_version"]) ?? 1
                fallback = AppConfig.fromDictionary(deepMerge(AppConfig.default.asDictionary(), object))
            }
            loaded = (
                fallback,
                ShellPolicyMigrationStatus(
                    state: "failed",
                    sourceSchemaVersion: sourceVersion,
                    receiptValid: false,
                    detail: error.localizedDescription
                )
            )
        }
        lock.lock()
        defer { lock.unlock() }
        _model = loaded.0
        _shellMigrationStatus = loaded.1
    }

    /// Marks the already-emitted migration diagnostic in the verified receipt.
    /// Logging remains owned by `ForgeApp`; this store only persists the receipt state.
    public func markShellMigrationDiagnosticEmitted() throws {
        try Self.withConfigFileLock(paths: paths) {
            guard FileManager.default.fileExists(atPath: paths.shellPolicyMigrationReceipt.path) else {
                return
            }
            let configData = try Data(contentsOf: paths.configJSON)
            let configObject = try JSONSupport.object(from: configData)
            let config = AppConfig.fromDictionary(
                Self.deepMergeStatic(AppConfig.default.asDictionary(), configObject)
            )
            _ = try Self.statusForCurrentConfig(
                configData: configData,
                config: config,
                paths: paths
            )
            var receipt = try JSONSupport.object(
                from: Data(contentsOf: paths.shellPolicyMigrationReceipt)
            )
            guard receipt["status"] as? String == "completed",
                  receipt["migration_id"] as? String == config.configMigrationID else {
                throw ConfigMigrationError.invalidReceipt
            }
            receipt["diagnostic_emitted"] = true
            receipt["diagnostic_emitted_at"] = ISO8601.string(from: Date())
            try Self.writeDurably(
                try JSONSupport.data(from: receipt),
                to: paths.shellPolicyMigrationReceipt
            )
        }
        lock.lock()
        _shellMigrationStatus.diagnosticPending = false
        lock.unlock()
    }

    /// Persist full config atomically.
    public func save() throws {
        let snapshot = model
        try Self.validateForPersistence(snapshot)
        let dict = snapshot.asDictionary()
        try paths.ensureLayout()
        let data = try JSONSupport.data(from: dict)
        try Self.withConfigFileLock(paths: paths) {
            if snapshot.configMigrationID != nil,
               FileManager.default.fileExists(atPath: paths.configJSON.path) {
                let currentData = try Data(contentsOf: paths.configJSON)
                let currentObject = try JSONSupport.object(from: currentData)
                let currentConfig = AppConfig.fromDictionary(
                    Self.deepMergeStatic(AppConfig.default.asDictionary(), currentObject)
                )
                _ = try Self.statusForCurrentConfig(
                    configData: currentData,
                    config: currentConfig,
                    paths: paths
                )
            }
            try Self.writeDurably(data, to: paths.configJSON)
            guard try Data(contentsOf: paths.configJSON) == data else {
                throw ConfigMigrationError.targetVerificationFailed
            }
            if let migrationID = snapshot.configMigrationID {
                try Self.updateReceiptLineage(
                    migrationID: migrationID,
                    currentConfigData: data,
                    paths: paths
                )
            }
        }
    }

    /// Deep-merge dictionary patch (HTTP / legacy) into live model.
    @discardableResult
    public func update(_ patch: [String: Any], save: Bool = true) throws -> [String: Any] {
        lock.lock()
        _model = _model.applying(patch: patch)
        let out = _model.asDictionary()
        lock.unlock()
        if save { try self.save() }
        return out
    }

    /// Typed settings patch path.
    @discardableResult
    public func update(_ patch: ManagerSettingsPatch, save: Bool = true) throws -> AppConfig {
        lock.lock()
        _model = _model.applying(settings: patch)
        let out = _model
        lock.unlock()
        if save { try self.save() }
        return out
    }

    /// Replace entire typed model.
    public func replace(_ config: AppConfig, save: Bool = true) throws {
        lock.lock()
        _model = config
        lock.unlock()
        if save { try self.save() }
    }

    public func int(_ keys: String..., default def: Int) -> Int {
        let dict = model.asDictionary()
        if let i = nested(keys, in: dict) as? Int { return i }
        if let d = nested(keys, in: dict) as? Double { return Int(d) }
        return def
    }

    public func string(_ keys: String..., default def: String) -> String {
        nested(keys, in: model.asDictionary()) as? String ?? def
    }

    public func bool(_ keys: String..., default def: Bool) -> Bool {
        nested(keys, in: model.asDictionary()) as? Bool ?? def
    }

    public func dictionary(_ keys: String...) -> [String: Any] {
        nested(keys, in: model.asDictionary()) as? [String: Any] ?? [:]
    }

    public var dashboard: AppConfig.DashboardConfig { model.dashboard }
    public var managerSection: AppConfig.ManagerConfigSection { model.manager }

    private func nested(_ path: [String], in values: [String: Any]) -> Any? {
        var cur: Any? = values
        for p in path {
            guard let d = cur as? [String: Any] else { return nil }
            cur = d[p]
        }
        return cur
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

    private func loadAndMigrateIfNeeded() throws -> (AppConfig, ShellPolicyMigrationStatus) {
        guard FileManager.default.fileExists(atPath: paths.configJSON.path) else {
            return (
                .default,
                ShellPolicyMigrationStatus(
                    state: "not_required",
                    sourceSchemaVersion: AppConfig.currentSchemaVersion,
                    receiptValid: false,
                    detail: "Fresh schema-v2 defaults are active"
                )
            )
        }

        return try Self.withConfigFileLock(paths: paths) {
            let sourceData = try Data(contentsOf: paths.configJSON)
            let source = try JSONSupport.object(from: sourceData)
            let sourceVersion = Self.integer(source["config_schema_version"]) ?? 1
            if sourceVersion > AppConfig.currentSchemaVersion {
                throw ConfigMigrationError.unsupportedSchemaVersion(sourceVersion)
            }
            if sourceVersion == AppConfig.currentSchemaVersion {
                let merged = deepMerge(AppConfig.default.asDictionary(), source)
                let config = AppConfig.fromDictionary(merged)
                let status = try Self.statusForCurrentConfig(
                    configData: sourceData,
                    config: config,
                    paths: paths
                )
                return (config, status)
            }

            let migrated = try Self.migrateLegacyConfig(
                sourceData: sourceData,
                source: source,
                sourceVersion: sourceVersion,
                paths: paths
            )
            return (migrated.config, migrated.status)
        }
    }

    private static func migrateLegacyConfig(
        sourceData: Data,
        source: [String: Any],
        sourceVersion: Int,
        paths: AppPaths
    ) throws -> (config: AppConfig, status: ShellPolicyMigrationStatus) {
        let sourceSHA = JSONSupport.sha256Hex(sourceData)
        let timestamp = ISO8601.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupName = "config.pre-v\(AppConfig.currentSchemaVersion).\(timestamp).\(sourceSHA.prefix(12)).json"
        let backupURL = paths.configMigrationsDir.appendingPathComponent(backupName)

        try writeDurably(sourceData, to: backupURL)
        let backupData = try Data(contentsOf: backupURL)
        let backupSHA = JSONSupport.sha256Hex(backupData)
        guard backupData == sourceData, backupSHA == sourceSHA else {
            throw ConfigMigrationError.backupVerificationFailed
        }

        let migrationID = UUID().uuidString.lowercased()
        var target = source
        target["config_schema_version"] = AppConfig.currentSchemaVersion
        target["config_migration_id"] = migrationID
        var shell = target["shell"] as? [String: Any] ?? [:]
        shell["enabled"] = true
        shell["user_disabled"] = false
        shell["policy_version"] = AppConfig.currentSchemaVersion
        shell["policy_origin"] = "legacy_disabled_default_migrated"
        if integer(shell["default_timeout_sec"]) == nil {
            shell["default_timeout_sec"] = 30
        }
        target["shell"] = shell

        let targetData = try JSONSupport.data(from: target)
        let targetSHA = JSONSupport.sha256Hex(targetData)
        let targetName = "config.schema-v\(AppConfig.currentSchemaVersion).\(migrationID).json"
        let targetURL = paths.configMigrationsDir.appendingPathComponent(targetName)
        try writeDurably(targetData, to: targetURL)
        guard JSONSupport.sha256Hex(try Data(contentsOf: targetURL)) == targetSHA else {
            throw ConfigMigrationError.targetVerificationFailed
        }
        let startedAt = ISO8601.string(from: Date())
        var receipt = migrationReceipt(
            migrationID: migrationID,
            status: "prepared",
            sourceVersion: sourceVersion,
            sourceSHA: sourceSHA,
            backupName: backupName,
            backupSHA: backupSHA,
            targetName: targetName,
            targetSHA: targetSHA,
            startedAt: startedAt,
            completedAt: nil
        )
        try writeDurably(try JSONSupport.data(from: receipt), to: paths.shellPolicyMigrationReceipt)
        try writeDurably(targetData, to: paths.configJSON)

        let persistedData = try Data(contentsOf: paths.configJSON)
        let persisted = try JSONSupport.object(from: persistedData)
        guard JSONSupport.sha256Hex(persistedData) == targetSHA,
              integer(persisted["config_schema_version"]) == AppConfig.currentSchemaVersion,
              persisted["config_migration_id"] as? String == migrationID,
              let persistedShell = persisted["shell"] as? [String: Any],
              persistedShell["enabled"] as? Bool == true,
              persistedShell["user_disabled"] as? Bool == false,
              integer(persistedShell["policy_version"]) == AppConfig.currentSchemaVersion,
              persistedShell["policy_origin"] as? String == "legacy_disabled_default_migrated" else {
            throw ConfigMigrationError.targetVerificationFailed
        }

        receipt["status"] = "completed"
        receipt["completed_at"] = ISO8601.string(from: Date())
        receipt["integrity_check"] = "source_backup_and_target_verified"
        receipt["current_config_sha256"] = targetSHA
        receipt["current_config_state"] = "original_migrated_target"
        try writeDurably(try JSONSupport.data(from: receipt), to: paths.shellPolicyMigrationReceipt)

        return (
            AppConfig.fromDictionary(deepMergeStatic(AppConfig.default.asDictionary(), persisted)),
            ShellPolicyMigrationStatus(
                state: "migrated",
                sourceSchemaVersion: sourceVersion,
                receiptValid: true,
                migrationID: migrationID,
                diagnosticPending: true,
                detail: "Legacy implicit shell policy migrated to schema v2"
            )
        )
    }

    private static func statusForCurrentConfig(
        configData: Data,
        config: AppConfig,
        paths: AppPaths
    ) throws -> ShellPolicyMigrationStatus {
        guard FileManager.default.fileExists(atPath: paths.shellPolicyMigrationReceipt.path) else {
            if config.configMigrationID != nil
                || config.shell.policyOrigin == "legacy_disabled_default_migrated" {
                throw ConfigMigrationError.missingReceipt
            }
            return ShellPolicyMigrationStatus(
                state: "not_required",
                sourceSchemaVersion: config.configSchemaVersion,
                receiptValid: false,
                detail: "Configuration was created with schema v2"
            )
        }

        let currentSHA = JSONSupport.sha256Hex(configData)
        let receiptData = try Data(contentsOf: paths.shellPolicyMigrationReceipt)
        var receipt = try JSONSupport.object(from: receiptData)
        guard let backupName = receipt["backup_filename"] as? String,
              backupName == URL(fileURLWithPath: backupName).lastPathComponent,
              let targetName = receipt["target_filename"] as? String,
              targetName == URL(fileURLWithPath: targetName).lastPathComponent,
              let migrationID = receipt["migration_id"] as? String,
              config.configMigrationID == migrationID,
              let sourceSHA = receipt["source_sha256"] as? String,
              let backupSHA = receipt["backup_sha256"] as? String,
              let targetSHA = receipt["target_sha256"] as? String else {
            throw ConfigMigrationError.invalidReceipt
        }
        let backupURL = paths.configMigrationsDir.appendingPathComponent(backupName)
        let backupData = try Data(contentsOf: backupURL)
        let targetURL = paths.configMigrationsDir.appendingPathComponent(targetName)
        let originalTargetData = try Data(contentsOf: targetURL)
        guard JSONSupport.sha256Hex(backupData) == backupSHA,
              backupSHA == sourceSHA,
              JSONSupport.sha256Hex(originalTargetData) == targetSHA else {
            throw ConfigMigrationError.invalidReceipt
        }

        if receipt["status"] as? String == "prepared" {
            guard currentSHA == targetSHA else {
                throw ConfigMigrationError.invalidReceipt
            }
            receipt["status"] = "completed"
            receipt["completed_at"] = ISO8601.string(from: Date())
            receipt["integrity_check"] = "reconciled_after_interruption"
            try writeDurably(try JSONSupport.data(from: receipt), to: paths.shellPolicyMigrationReceipt)
        }
        guard receipt["status"] as? String == "completed" else {
            throw ConfigMigrationError.invalidReceipt
        }

        guard config.configSchemaVersion == AppConfig.currentSchemaVersion,
              config.shell.policyVersion == AppConfig.currentSchemaVersion,
              config.shell.enabled != config.shell.userDisabled else {
            throw ConfigMigrationError.invalidReceipt
        }

        let modifiedAfterMigration = currentSHA != targetSHA
        let pendingDiagnostic = !(receipt["diagnostic_emitted"] as? Bool ?? false)

        return ShellPolicyMigrationStatus(
            state: modifiedAfterMigration ? "migrated_modified" : "migrated",
            sourceSchemaVersion: integer(receipt["source_schema_version"]) ?? 1,
            receiptValid: true,
            migrationID: migrationID,
            diagnosticPending: pendingDiagnostic,
            detail: modifiedAfterMigration
                ? "Schema-v2 migration lineage and original artifacts verified after settings changes"
                : "Schema-v2 shell migration receipt verified"
        )
    }

    private static func migrationReceipt(
        migrationID: String,
        status: String,
        sourceVersion: Int,
        sourceSHA: String,
        backupName: String,
        backupSHA: String,
        targetName: String,
        targetSHA: String,
        startedAt: String,
        completedAt: String?
    ) -> [String: Any] {
        [
            "receipt_schema_version": 1,
            "migration_id": migrationID,
            "status": status,
            "source_filename": "config.json",
            "source_schema_version": sourceVersion,
            "source_sha256": sourceSHA,
            "backup_filename": backupName,
            "backup_sha256": backupSHA,
            "target_schema_version": AppConfig.currentSchemaVersion,
            "target_filename": targetName,
            "target_sha256": targetSHA,
            "policy_origin": "legacy_disabled_default_migrated",
            "started_at": startedAt,
            "completed_at": completedAt as Any,
            "diagnostic_emitted": false,
            "rollback": "replace config.json with the verified backup file",
        ].compactNSNull()
    }

    private static func updateReceiptLineage(
        migrationID: String,
        currentConfigData: Data,
        paths: AppPaths
    ) throws {
        var receipt = try JSONSupport.object(
            from: Data(contentsOf: paths.shellPolicyMigrationReceipt)
        )
        guard receipt["status"] as? String == "completed",
              receipt["migration_id"] as? String == migrationID,
              let targetSHA = receipt["target_sha256"] as? String else {
            throw ConfigMigrationError.invalidReceipt
        }
        let currentSHA = JSONSupport.sha256Hex(currentConfigData)
        receipt["current_config_sha256"] = currentSHA
        receipt["current_config_state"] = currentSHA == targetSHA
            ? "original_migrated_target"
            : "schema_v2_modified"
        receipt["current_config_updated_at"] = ISO8601.string(from: Date())
        try writeDurably(try JSONSupport.data(from: receipt), to: paths.shellPolicyMigrationReceipt)
    }

    private static func validateForPersistence(_ config: AppConfig) throws {
        guard config.configSchemaVersion == AppConfig.currentSchemaVersion,
              config.shell.policyVersion == AppConfig.currentSchemaVersion,
              config.shell.enabled != config.shell.userDisabled,
              !config.shell.policyOrigin.isEmpty,
              config.shell.defaultTimeoutSec > 0 else {
            throw ConfigMigrationError.invalidPolicy
        }
    }

    private static func withConfigFileLock<T>(paths: AppPaths, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: paths.configMigrationsDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let processDeadline = Date().addingTimeInterval(migrationLockTimeout)
        guard processMigrationLock.lock(before: processDeadline) else {
            throw ConfigMigrationError.lockTimeout
        }
        defer { processMigrationLock.unlock() }

        let descriptor = paths.configMigrationLock.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else {
            throw ConfigMigrationError.lockOpenFailed(errno)
        }
        defer { _ = Darwin.close(descriptor) }

        let deadline = Date().addingTimeInterval(migrationLockTimeout)
        while Darwin.lockf(descriptor, F_TLOCK, 0) != 0 {
            let code = errno
            guard code == EACCES || code == EAGAIN else {
                throw ConfigMigrationError.lockFailed(code)
            }
            guard Date() < deadline else {
                throw ConfigMigrationError.lockTimeout
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }

    private static func writeDurably(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ConfigMigrationError.atomicWriteFailed(errno)
        }
        var renamed = false
        defer {
            if !renamed { try? fileManager.removeItem(at: temporary) }
        }

        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

        let result = temporary.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard result == 0 else {
            throw ConfigMigrationError.atomicWriteFailed(errno)
        }
        renamed = true

        let directoryDescriptor = destination.deletingLastPathComponent().path.withCString {
            Darwin.open($0, O_RDONLY)
        }
        if directoryDescriptor >= 0 {
            _ = Darwin.fsync(directoryDescriptor)
            _ = Darwin.close(directoryDescriptor)
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func deepMergeStatic(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var output = base
        for (key, value) in over {
            if let baseValue = base[key] as? [String: Any],
               let newValue = value as? [String: Any] {
                output[key] = deepMergeStatic(baseValue, newValue)
            } else {
                output[key] = value
            }
        }
        return output
    }
}

private enum ConfigMigrationError: Error, LocalizedError {
    case lockTimeout
    case lockOpenFailed(Int32)
    case lockFailed(Int32)
    case backupVerificationFailed
    case targetVerificationFailed
    case missingReceipt
    case invalidReceipt
    case invalidPolicy
    case unsupportedSchemaVersion(Int)
    case atomicWriteFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .lockTimeout:
            "Timed out waiting for the configuration migration lock"
        case .lockOpenFailed(let code):
            "Could not open the configuration migration lock: \(String(cString: strerror(code)))"
        case .lockFailed(let code):
            "Could not acquire the configuration migration lock: \(String(cString: strerror(code)))"
        case .backupVerificationFailed:
            "Configuration backup verification failed"
        case .targetVerificationFailed:
            "Migrated configuration verification failed"
        case .missingReceipt:
            "Migrated shell policy is missing its receipt"
        case .invalidReceipt:
            "Shell policy migration receipt verification failed"
        case .invalidPolicy:
            "Shell policy configuration is inconsistent or outside supported bounds"
        case .unsupportedSchemaVersion(let version):
            "Configuration schema version \(version) is newer than this application supports"
        case .atomicWriteFailed(let code):
            "Atomic configuration write failed: \(String(cString: strerror(code)))"
        }
    }
}

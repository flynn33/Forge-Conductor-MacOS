// ConfigStore.swift
// What: Persists AppConfig and exposes synchronized typed configuration access.
// How: A lock guards the in-memory model while atomic JSON writes, reload, and patch
// operations validate changes before replacing the durable file.
// Why: Readers need one consistent configuration owner across concurrent services.

import Foundation
import Darwin

/// Persistence for `AppConfig`. Domain consumers use `model`; dict update remains for HTTP edge patches.
public final class ConfigStore: ConfigurationProviding, @unchecked Sendable {
    static let configurationLockTimeoutSeconds: TimeInterval = 5
    private static let processMigrationLock = NSLock()

    private var _model: AppConfig
    private var _shellMigrationStatus: ShellPolicyMigrationStatus = .notChecked
    private var _budgetPolicyError: ManagerSettingsValidationError?
    private let paths: AppPaths
    private let lock = NSLock()
    private let mutationLock = NSLock()
    // Guarded by mutationLock. Save flushes only explicitly requested fields.
    private var pendingPatch: [String: Any] = [:]

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

    public var budgetPolicyError: ManagerSettingsValidationError? {
        lock.lock(); defer { lock.unlock() }
        return _budgetPolicyError
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
        do {
            try withConfigurationMutation { _ in
                reloadSerialized()
                pendingPatch = [:]
            }
        } catch {
            lock.lock()
            _model.budgetPolicy = nil
            _budgetPolicyError = ManagerSettingsValidationError(field: "budget_policy", reason: "configuration_unavailable")
            lock.unlock()
        }
    }

    private func reloadSerialized() {
        let loaded: (AppConfig, ShellPolicyMigrationStatus)
        var budgetError: ManagerSettingsValidationError?
        var priorMigrationStatus: ShellPolicyMigrationStatus?
        do {
            let migrated = try loadAndMigrateIfNeeded()
            priorMigrationStatus = migrated.1
            loaded = (try loadBudgetConfiguration(), migrated.1)
        } catch {
            budgetError = (error as? ManagerSettingsValidationError)
                ?? ManagerSettingsValidationError(field: "budget_policy", reason: "configuration_unavailable")
            try? Self.withConfigFileLock(paths: paths) {
                let data = try Self.readConfigurationBytes(paths: paths)
                try Self.retainBudgetBackup(data, paths: paths)
            }
            var fallback = AppConfig.default
            var sourceVersion = AppConfig.currentSchemaVersion
            if let data = try? Self.readConfigurationBytes(paths: paths),
               let object = try? JSONSupport.object(from: data) {
                sourceVersion = Self.integer(object["config_schema_version"]) ?? 1
                fallback = AppConfig.fromDictionary(deepMerge(AppConfig.default.asDictionary(), object))
            }
            fallback.budgetPolicy = nil
            loaded = (
                fallback,
                priorMigrationStatus ?? ShellPolicyMigrationStatus(
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
        _budgetPolicyError = budgetError
    }

    /// Marks the already-emitted migration diagnostic in the verified receipt.
    /// Logging remains owned by `ForgeApp`; this store only persists the receipt state.
    public func markShellMigrationDiagnosticEmitted() throws {
        try Self.withConfigFileLock(paths: paths) {
            guard FileManager.default.fileExists(atPath: paths.shellPolicyMigrationReceipt.path) else {
                return
            }
            let configData = try Self.readConfigurationBytes(paths: paths)
            let configObject = try JSONSupport.object(from: BudgetPolicyState.validateConfigurationJSON(configData))
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

    /// Flush staged settings against the authoritative file under one transaction.
    public func save() throws {
        try withConfigurationMutation { deadline in
            _ = try persistPatch([:], deadline: deadline)
        }
    }

    /// Apply only the requested fields to the latest durable configuration.
    @discardableResult
    public func update(_ patch: [String: Any], save: Bool = true) throws -> [String: Any] {
        try rejectDirectPolicyReplacement(patch)
        if let raw = patch["budget_update"] {
            guard patch.count == 1, let request = raw as? [String: Any] else {
                throw ManagerSettingsValidationError(field: "budget_update", reason: "separate_policy_transaction_required")
            }
            guard save else {
                throw ManagerSettingsValidationError(field: "budget_update", reason: "durable_policy_update_required")
            }
            _ = try updateBudgetPolicy(BudgetPolicyUpdate.decode(dictionary: request))
            return values
        }
        try ManagerSettingsNormalizer.validateLegacyBudgetKeys(patch)
        return try withConfigurationMutation { deadline in
            if save { return try persistPatch(patch, deadline: deadline).asDictionary() }
            let proposed = model.applying(patch: patch)
            try Self.validateForPersistence(proposed)
            pendingPatch = Self.deepMergeStatic(pendingPatch, patch)
            publish(proposed)
            return proposed.asDictionary()
        }
    }

    /// Typed settings use the same durable patch/CAS paths as dictionary callers.
    @discardableResult
    public func update(_ patch: ManagerSettingsPatch, save: Bool = true) throws -> AppConfig {
        _ = try patch.budgetPolicyUpdate?.validated()
        _ = try update(patch.asConfigPatch(), save: save)
        return model
    }

    /// Replace explicitly changed settings; policy revisions still require CAS.
    public func replace(_ config: AppConfig, save: Bool = true) throws {
        try withConfigurationMutation { deadline in
            let current = model
            guard config.budgetPolicy == current.budgetPolicy else {
                throw ManagerSettingsValidationError(field: "budget_policy", reason: "revision_checked_policy_update_required")
            }
            try Self.validateForPersistence(config)
            var patch = Self.changedFields(from: current.asDictionary(), to: config.asDictionary())
            patch.removeValue(forKey: "budget_policy")
            if save {
                _ = try persistPatch(patch, deadline: deadline)
            } else {
                pendingPatch = Self.deepMergeStatic(pendingPatch, patch)
                publish(config)
            }
        }
    }

    private func persistPatch(_ patch: [String: Any], deadline: Date) throws -> AppConfig {
        let requested = Self.deepMergeStatic(pendingPatch, patch)
        return try Self.withConfigFileLock(paths: paths, deadline: deadline) {
            let source = try Self.readConfiguration(paths: paths)
            let currentPolicy = try Self.decodeBudgetPolicy(source.object)
            let current = AppConfig.fromDictionary(source.object)
            _ = try Self.statusForCurrentConfig(configData: source.data, config: current, paths: paths)
            var config = current.applying(patch: requested)
            config.budgetPolicy = currentPolicy
            try Self.validateForPersistence(config)
            // Preserve unknown persisted keys and requested legacy extension keys.
            // Re-encode known fields to retain derived shell opt-out metadata.
            let object = Self.deepMergeStatic(Self.deepMergeStatic(source.object, requested), config.asDictionary())
            try Self.commitConfiguration(object, config: config, paths: paths)
            pendingPatch = [:]
            publish(config)
            return config
        }
    }

    private func publish(_ config: AppConfig) {
        lock.lock()
        _model = config
        _budgetPolicyError = nil
        lock.unlock()
    }

    private func withConfigurationMutation<Value>(_ body: (Date) throws -> Value) throws -> Value {
        let deadline = Date().addingTimeInterval(Self.configurationLockTimeoutSeconds)
        guard mutationLock.lock(before: deadline) else { throw ConfigMigrationError.lockTimeout }
        defer { mutationLock.unlock() }
        return try body(deadline)
    }

    private func rejectDirectPolicyReplacement(_ patch: [String: Any]) throws {
        guard patch["budget_policy"] == nil else {
            throw ManagerSettingsValidationError(field: "budget_policy", reason: "revision_checked_policy_update_required")
        }
    }

    private static func changedFields(from before: [String: Any], to after: [String: Any]) -> [String: Any] {
        var changed: [String: Any] = [:]
        for (key, value) in after {
            if let old = before[key] as? [String: Any], let new = value as? [String: Any] {
                let nested = changedFields(from: old, to: new)
                if !nested.isEmpty { changed[key] = nested }
            } else if let old = before[key], NSDictionary(dictionary: ["value": old]).isEqual(to: ["value": value]) {
                continue
            } else {
                changed[key] = value
            }
        }
        return changed
    }

    public func int(_ keys: String..., default def: Int) -> Int {
        let dict = model.asDictionary()
        return JSONSupport.exactInteger(nested(keys, in: dict)) ?? def
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

    /// Read the authoritative revision under the same interprocess lock used by
    /// updates. A stale in-memory ConfigStore is never policy authority.
    public func budgetPolicySnapshot() throws -> BudgetPolicyState {
        try Self.withConfigFileLock(paths: paths) {
            let source = try Self.readConfiguration(paths: paths)
            let state = try Self.decodeBudgetPolicy(source.object)
            let config = AppConfig.fromDictionary(source.object)
            try Self.validateForPersistence(config)
            _ = try Self.statusForCurrentConfig(configData: source.data, config: config, paths: paths)
            lock.lock()
            _model.budgetPolicy = state
            _budgetPolicyError = nil
            lock.unlock()
            return state
        }
    }

    public func budgetPolicySelection(scope: BudgetPolicyScope) throws -> BudgetPolicySelection {
        try budgetPolicySnapshot().resolve(scope)
    }

    @discardableResult
    public func updateBudgetPolicy(_ request: BudgetPolicyUpdate) throws -> BudgetPolicySelection {
        _ = try request.validated()
        return try withConfigurationMutation { deadline in
            try updateBudgetPolicySerialized(request, deadline: deadline)
        }
    }

    private func updateBudgetPolicySerialized(_ request: BudgetPolicyUpdate, deadline: Date) throws -> BudgetPolicySelection {
        try Self.withConfigFileLock(paths: paths, deadline: deadline) {
            try Task.checkCancellation()
            let source = try Self.readConfiguration(paths: paths)
            let current = try Self.decodeBudgetPolicy(source.object)
            let selection = try current.resolve(request.scope)
            guard request.expectedRevision == selection.revision,
                  request.expectedGlobalRevision == current.globalRevision else {
                throw BudgetPolicyConflict(current: selection)
            }
            guard selection.revision < Int.max - 1 else {
                throw ManagerSettingsValidationError(field: "revision", reason: "revision_exhausted")
            }
            let next: BudgetPolicyState
            if request.scope.kind == .globalDefault {
                next = BudgetPolicyState(globalRevision: current.globalRevision + 1,
                                         globalPolicy: request.policy ?? .default,
                                         projectOverrides: current.projectOverrides)
            } else {
                var projects = current.projectOverrides
                guard projects[request.scope.key] != nil || projects.count < BudgetPolicyState.maximumProjectOverrides else {
                    throw ManagerSettingsValidationError(field: "scope", reason: "project_policy_capacity_reached")
                }
                // Reset at project scope returns to the current global default.
                // Retaining the revision prevents reset/delete/recreate ABA.
                projects[request.scope.key] = BudgetProjectPolicy(scope: request.scope, revision: selection.revision + 1, policy: request.policy)
                next = BudgetPolicyState(globalRevision: current.globalRevision, globalPolicy: current.globalPolicy, projectOverrides: projects)
            }
            _ = try next.validated()
            var object = source.object
            object["budget_policy"] = try Self.policyObject(next)
            let config = AppConfig.fromDictionary(object)
            try Self.validateForPersistence(config)
            _ = try Self.statusForCurrentConfig(configData: source.data, config: AppConfig.fromDictionary(source.object), paths: paths)
            try Task.checkCancellation()
            try Self.commitConfiguration(object, config: config, paths: paths)
            // A durable policy change must not discard a staged legacy edit.
            publish(config.applying(patch: pendingPatch))
            return try next.resolve(request.scope)
        }
    }

    private func loadBudgetConfiguration() throws -> AppConfig {
        try paths.ensureLayout()
        return try Self.withConfigFileLock(paths: paths) {
            let source = try Self.readConfiguration(paths: paths)
            let policy: BudgetPolicyState
            do { policy = try Self.decodeBudgetPolicy(source.object) }
            catch {
                try Self.retainBudgetBackup(source.data, paths: paths)
                throw error
            }
            var object = source.object
            if object["budget_policy"] == nil {
                try Self.retainBudgetBackup(source.data, paths: paths)
                object["budget_policy"] = try Self.policyObject(policy)
                let config = AppConfig.fromDictionary(object)
                try Self.commitConfiguration(object, config: config, paths: paths)
            }
            return AppConfig.fromDictionary(object)
        }
    }

    private static func decodeBudgetPolicy(_ object: [String: Any]) throws -> BudgetPolicyState {
        guard let raw = object["budget_policy"] else { return .default }
        do {
            let data = try JSONSerialization.data(withJSONObject: raw)
            return try BudgetPolicyState.decode(data: data).validated()
        } catch let error as ManagerSettingsValidationError { throw error }
        catch { throw ManagerSettingsValidationError(field: "budget_policy", reason: "malformed_stored_policy") }
    }

    private static func policyObject(_ state: BudgetPolicyState) throws -> [String: Any] {
        try JSONSupport.object(from: JSONEncoder().encode(state.validated()))
    }

    private static func readConfigurationBytes(paths: AppPaths) throws -> Data {
        try readBoundedConfigurationFile(paths.configJSON)
    }

    private static func readBoundedConfigurationFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let maximum = 2 * 1_048_576
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else {
            throw ManagerSettingsValidationError(field: "config", reason: "configuration_too_large")
        }
        return data
    }

    private static func readConfiguration(paths: AppPaths) throws -> (data: Data, object: [String: Any]) {
        let data = try readConfigurationBytes(paths: paths)
        let validated = try BudgetPolicyState.validateConfigurationJSON(data)
        guard let object = (try? JSONSerialization.jsonObject(with: validated)) as? [String: Any] else {
            throw ManagerSettingsValidationError(field: "config", reason: "expected_json_object")
        }
        return (data, object)
    }

    private static func retainBudgetBackup(_ data: Data, paths: AppPaths) throws {
        let name = "config.pre-budget-v1." + JSONSupport.sha256Hex(data) + ".json"
        let target = paths.configMigrationsDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            guard try readBoundedConfigurationFile(target) == data else { throw ConfigMigrationError.backupVerificationFailed }
            return
        }
        guard let entries = FileManager.default.enumerator(at: paths.configMigrationsDir,
            includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) else {
            throw ManagerSettingsValidationError(field: "config", reason: "budget_backup_directory_unavailable")
        }
        var scanned = 0
        var backups = 0
        while let entry = entries.nextObject() as? URL {
            scanned += 1
            if entry.lastPathComponent.hasPrefix("config.pre-budget-v1.") { backups += 1 }
            guard scanned <= 1_024, backups < 32 else {
                throw ManagerSettingsValidationError(field: "config", reason: "budget_backup_capacity_reached")
            }
        }
        try writeDurably(data, to: target)
        guard try readBoundedConfigurationFile(target) == data else { throw ConfigMigrationError.backupVerificationFailed }
    }

    private static func commitConfiguration(_ object: [String: Any], config: AppConfig, paths: AppPaths) throws {
        try validateForPersistence(config)
        let data = try JSONSupport.data(from: object)
        guard data.count <= 2 * 1_048_576 else {
            throw ManagerSettingsValidationError(field: "config", reason: "configuration_too_large")
        }
        try writeDurably(data, to: paths.configJSON)
        guard try readConfigurationBytes(paths: paths) == data else { throw ConfigMigrationError.targetVerificationFailed }
        if let migrationID = config.configMigrationID {
            try updateReceiptLineage(migrationID: migrationID, currentConfigData: data, paths: paths)
        }
    }

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
            let loaded = try Self.readConfiguration(paths: paths)
            let sourceData = loaded.data
            let source = loaded.object
            _ = try Self.decodeBudgetPolicy(source)
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
        // The released schema-v1 writer persisted only `enabled`, whose false
        // value represented both the shipped default and any user choice. It
        // therefore supplied no provenance that could distinguish an opt-out.
        // Honor provenance fields only when a forward/backported writer supplied
        // them explicitly; ordinary v1 disabled state migrates to enabled.
        let recognizedOptOutMetadata = shell["user_disabled"] as? Bool == true
            || shell["policy_origin"] as? String == "user_disabled"
        let migratedPolicyOrigin = recognizedOptOutMetadata
            ? "user_disabled"
            : "legacy_disabled_default_migrated"
        shell["enabled"] = !recognizedOptOutMetadata
        shell["user_disabled"] = recognizedOptOutMetadata
        shell["policy_version"] = AppConfig.currentSchemaVersion
        shell["policy_origin"] = migratedPolicyOrigin
        if integer(shell["default_timeout_sec"]) == nil {
            shell["default_timeout_sec"] = 30
        }
        target["shell"] = shell
        if target["budget_policy"] == nil {
            target["budget_policy"] = try policyObject(.default)
        }

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
            policyOrigin: migratedPolicyOrigin,
            startedAt: startedAt,
            completedAt: nil
        )
        try writeDurably(try JSONSupport.data(from: receipt), to: paths.shellPolicyMigrationReceipt)
        try writeDurably(targetData, to: paths.configJSON)

        let persistedData = try Self.readConfigurationBytes(paths: paths)
        let persisted = try JSONSupport.object(from: persistedData)
        guard JSONSupport.sha256Hex(persistedData) == targetSHA,
              integer(persisted["config_schema_version"]) == AppConfig.currentSchemaVersion,
              persisted["config_migration_id"] as? String == migrationID,
              let persistedShell = persisted["shell"] as? [String: Any],
              persistedShell["enabled"] as? Bool == !recognizedOptOutMetadata,
              persistedShell["user_disabled"] as? Bool == recognizedOptOutMetadata,
              integer(persistedShell["policy_version"]) == AppConfig.currentSchemaVersion,
              persistedShell["policy_origin"] as? String == migratedPolicyOrigin else {
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
                detail: recognizedOptOutMetadata
                    ? "Explicit shell opt-out provenance preserved in schema v2"
                    : "Legacy implicit shell policy migrated to schema v2"
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
        policyOrigin: String,
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
            "policy_origin": policyOrigin,
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
        guard let policy = config.budgetPolicy else {
            throw ManagerSettingsValidationError(field: "budget_policy", reason: "configuration_unavailable")
        }
        _ = try policy.validated()
        guard config.configSchemaVersion == AppConfig.currentSchemaVersion,
              config.shell.policyVersion == AppConfig.currentSchemaVersion,
              config.shell.enabled != config.shell.userDisabled,
              !config.shell.policyOrigin.isEmpty,
              config.shell.defaultTimeoutSec > 0 else {
            throw ConfigMigrationError.invalidPolicy
        }
    }

    private static func withConfigFileLock<T>(paths: AppPaths, deadline requestedDeadline: Date? = nil, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: paths.configMigrationsDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let deadline = requestedDeadline ?? Date().addingTimeInterval(configurationLockTimeoutSeconds)
        guard processMigrationLock.lock(before: deadline) else {
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
        JSONSupport.exactInteger(value)
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

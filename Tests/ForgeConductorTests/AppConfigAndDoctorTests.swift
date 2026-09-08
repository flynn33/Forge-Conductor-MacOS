// AppConfigAndDoctorTests.swift
// Verifies configuration round trips, settings patches, health reports, and doctor output.
// These tests protect the typed operator-facing contracts shared by CLI and native app.

import XCTest
@testable import ForgeConductorCore

final class AppConfigAndDoctorTests: XCTestCase {
    func testConcurrentLegacyEditorsPreserveNewOptOutAndStagedFields() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("settings-patches-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        let first = ConfigStore(paths: paths)
        let second = ConfigStore(paths: paths)
        _ = try second.update(ManagerSettingsPatch(shellEnabled: false))
        _ = try first.update(["log_level": "debug"])
        var restarted = ConfigStore(paths: paths)
        XCTAssertFalse(restarted.model.shell.enabled, "An unrelated stale editor must preserve the explicit opt-out")
        XCTAssertTrue(restarted.model.shell.userDisabled)
        XCTAssertEqual(restarted.model.logLevel, "debug")

        _ = try first.update(["dashboard": ["port": 8123]], save: false)
        let policy = try first.updateBudgetPolicy(.init(scope: .globalDefault, expectedRevision: 1,
            expectedGlobalRevision: 1, operation: .set, policy: .init(automaticHandoffEnabled: true)))
        XCTAssertEqual(first.model.dashboard.port, 8123, "Policy save must retain the staged legacy patch")
        XCTAssertNotEqual(ConfigStore(paths: paths).model.dashboard.port, 8123, "Staged settings are not prematurely persisted")
        _ = try second.update(["manager": ["auto_restart": false]])
        try first.save()
        restarted = ConfigStore(paths: paths)
        XCTAssertEqual(restarted.model.dashboard.port, 8123)
        XCTAssertFalse(restarted.model.manager.autoRestart)
        XCTAssertFalse(restarted.model.shell.enabled)
        XCTAssertEqual(try restarted.budgetPolicySelection(scope: .globalDefault), policy)
    }

    func testConfigStorePolicyUpdatesUseCASAndRejectSuccessfulNoOps() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("settings-policy-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        let store = ConfigStore(paths: paths)
        let update = BudgetPolicyUpdate(scope: .globalDefault, expectedRevision: 1,
            expectedGlobalRevision: 1, operation: .set, policy: .init(automaticHandoffEnabled: true))
        let patch = ManagerSettingsPatch(budgetPolicyUpdate: update)
        XCTAssertThrowsError(try store.update(patch, save: false))
        XCTAssertThrowsError(try store.update(ManagerSettingsPatch(logLevel: "debug", budgetPolicyUpdate: update)))
        let saved = try store.update(patch)
        XCTAssertEqual(saved.budgetPolicy?.globalRevision, 2)
        XCTAssertEqual(saved.budgetPolicy?.globalPolicy.automaticHandoffEnabled, true)
        let bytes = try Data(contentsOf: paths.configJSON)
        XCTAssertThrowsError(try store.update(patch)) { XCTAssertTrue($0 is BudgetPolicyConflict) }
        let reset = BudgetPolicyUpdate(scope: .globalDefault, expectedRevision: 2, expectedGlobalRevision: 2, operation: .reset)
        _ = try store.update(["budget_update": reset.asDictionary()])
        XCTAssertEqual(store.model.budgetPolicy?.globalRevision, 3)
        XCTAssertEqual(store.model.budgetPolicy?.globalPolicy.automaticHandoffEnabled, false)
        XCTAssertNotEqual(try Data(contentsOf: paths.configJSON), bytes)
        let current = store.model
        let currentBytes = try Data(contentsOf: paths.configJSON)
        XCTAssertThrowsError(try store.update(["shell": ["default_timeout_sec": 0], "log_level": "trace"]))
        XCTAssertEqual(store.model, current, "A rejected save must not change live settings")
        XCTAssertEqual(try Data(contentsOf: paths.configJSON), currentBytes)
    }

    func testBudgetPolicyConcurrentEditorsConflictAndRestartPreservesInheritance() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("budget-cas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        let first = ConfigStore(paths: paths)
        let second = ConfigStore(paths: paths)
        let requests = [BudgetPolicy(automaticHandoffEnabled: true), BudgetPolicy(context: .init(mode: .manual, maxContextTokens: 8_192))]
        let results = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for (store, policy) in zip([first, second], requests) {
                group.addTask {
                    do {
                        _ = try store.updateBudgetPolicy(.init(scope: .globalDefault, expectedRevision: 1, expectedGlobalRevision: 1, operation: .set, policy: policy))
                        return "saved"
                    } catch is BudgetPolicyConflict { return "conflict" }
                    catch { return "unexpected: \(error)" }
                }
            }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.sorted(), ["conflict", "saved"])
        let global = try second.budgetPolicySelection(scope: .globalDefault)
        XCTAssertEqual(global.revision, 2)
        let scope = BudgetPolicyScope(kind: .projectOverride, projectID: UUID().uuidString.lowercased(), projectGeneration: 1)
        let project = try first.updateBudgetPolicy(.init(scope: scope, expectedRevision: 0, expectedGlobalRevision: 2, operation: .set, policy: .init(tools: .init(callsPerSession: 32))))
        XCTAssertFalse(project.inherited)
        let restarted = ConfigStore(paths: paths)
        XCTAssertEqual(try restarted.budgetPolicySelection(scope: scope), project)
        let reset = try restarted.updateBudgetPolicy(.init(scope: scope, expectedRevision: 1, expectedGlobalRevision: 2, operation: .reset))
        XCTAssertTrue(reset.inherited)
        XCTAssertEqual(reset.revision, 2)
        XCTAssertEqual(reset.policy, global.policy)
        XCTAssertThrowsError(try first.updateBudgetPolicy(.init(scope: scope, expectedRevision: 0, expectedGlobalRevision: 2, operation: .set, policy: .default)))
        XCTAssertEqual(try ConfigStore(paths: paths).budgetPolicySelection(scope: scope), reset)
    }

    func testBudgetPolicyMigrationPreservesExplicitOptOutAndUnrelatedKeys() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("budget-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        var object = AppConfig.default.asDictionary()
        object.removeValue(forKey: "budget_policy")
        object["custom_setting"] = ["preserve": true]
        var shell = try XCTUnwrap(object["shell"] as? [String: Any])
        shell["enabled"] = false; shell["user_disabled"] = true; shell["policy_origin"] = "user_disabled"
        object["shell"] = shell
        let original = try JSONSupport.data(from: object)
        try original.write(to: paths.configJSON, options: .atomic)
        let staleEditor = ConfigStore(paths: paths)
        let freshEditor = ConfigStore(paths: paths)
        XCTAssertFalse(staleEditor.model.shell.enabled)
        XCTAssertTrue(staleEditor.model.shell.userDisabled)
        let saved = try freshEditor.updateBudgetPolicy(.init(scope: .globalDefault, expectedRevision: 1, expectedGlobalRevision: 1, operation: .set, policy: .init(automaticHandoffEnabled: true)))
        _ = try staleEditor.update(["log_level": "debug"])
        let restarted = ConfigStore(paths: paths)
        XCTAssertEqual(try restarted.budgetPolicySelection(scope: .globalDefault), saved)
        XCTAssertFalse(restarted.model.shell.enabled)
        XCTAssertEqual(restarted.model.logLevel, "debug")
        let persisted = try JSONSupport.object(from: Data(contentsOf: paths.configJSON))
        XCTAssertEqual((persisted["custom_setting"] as? [String: Any])?["preserve"] as? Bool, true)
        let backup = paths.configMigrationsDir.appendingPathComponent("config.pre-budget-v1." + JSONSupport.sha256Hex(original) + ".json")
        let backupData = try Data(contentsOf: backup)
        XCTAssertEqual(backupData, original)
        let persistedData = try Data(contentsOf: paths.configJSON)
        try retainBudgetEffects(caseID: "T03-05", effects: [
            "original_config_base64": original.base64EncodedString(), "original_config_sha256": JSONSupport.sha256Hex(original),
            "backup_base64": backupData.base64EncodedString(), "backup_sha256": JSONSupport.sha256Hex(backupData),
            "persisted_config_base64": persistedData.base64EncodedString(), "persisted_config_sha256": JSONSupport.sha256Hex(persistedData),
            "shell_enabled": restarted.model.shell.enabled, "shell_user_disabled": restarted.model.shell.userDisabled,
            "unrelated_setting": (persisted["custom_setting"] as? [String: Any]) ?? [:],
            "saved_policy": try JSONSupport.object(from: JSONEncoder().encode(saved)),
            "reloaded_policy": try JSONSupport.object(from: JSONEncoder().encode(restarted.budgetPolicySelection(scope: .globalDefault))),
        ])
    }

    func testMalformedStoredBudgetRemainsRecoverableWithoutSilentDefaults() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("budget-invalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        var object = AppConfig.default.asDictionary()
        object["log_level"] = "debug"
        object["budget_policy"] = ["schema_version": 999]
        let original = try JSONSupport.data(from: object)
        try original.write(to: paths.configJSON, options: .atomic)
        let store = ConfigStore(paths: paths)
        XCTAssertNotNil(store.budgetPolicyError)
        XCTAssertNil(store.model.budgetPolicy)
        XCTAssertEqual(store.model.logLevel, "debug")
        XCTAssertThrowsError(try store.budgetPolicySelection(scope: .globalDefault))
        XCTAssertEqual(try Data(contentsOf: paths.configJSON), original)
        let backup = paths.configMigrationsDir.appendingPathComponent("config.pre-budget-v1." + JSONSupport.sha256Hex(original) + ".json")
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testStoredPolicyRejectsFractionsBeforeFoundationRounding() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("budget-raw-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let raw = try JSONSupport.string(from: AppConfig.default.asDictionary())
            .replacingOccurrences(of: "\"calls_per_turn\":8", with: "\"calls_per_turn\":8.0000000000000000000000000000000000000001")
        let original = Data(raw.utf8)
        try original.write(to: paths.configJSON, options: .atomic)
        let store = ConfigStore(paths: paths)
        XCTAssertNil(store.model.budgetPolicy)
        XCTAssertEqual(store.budgetPolicyError?.reason, "expected_exact_integer")
        XCTAssertThrowsError(try store.budgetPolicySnapshot())
        XCTAssertThrowsError(try store.update(["log_level": "debug"]))
        XCTAssertEqual(try Data(contentsOf: paths.configJSON), original)
        let backup = paths.configMigrationsDir.appendingPathComponent("config.pre-budget-v1." + JSONSupport.sha256Hex(original) + ".json")
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testBudgetPolicyDecodingPreservesExactCountsAndRejectsUnknownFields() throws {
        let data = try JSONEncoder().encode(BudgetPolicy.default)
        XCTAssertEqual(try JSONDecoder().decode(BudgetPolicy.self, from: data), .default)
        var object = try JSONSupport.object(from: data)
        for invalid in ["true", "1.00000000000000001", "1e100", "9223372036854775808"] {
            let text = String(data: data, encoding: .utf8)!
            let malformed = text.replacingOccurrences(of: "\"calls_per_turn\":8", with: "\"calls_per_turn\":\(invalid)")
            XCTAssertNotEqual(malformed, text)
            XCTAssertThrowsError(try JSONDecoder().decode(BudgetPolicy.self, from: Data(malformed.utf8)), invalid)
        }
        var context = try XCTUnwrap(object["context"] as? [String: Any])
        context["unrecognized_budget"] = 1
        object["context"] = context
        XCTAssertThrowsError(try JSONDecoder().decode(BudgetPolicy.self, from: JSONSupport.data(from: object))) { error in
            XCTAssertEqual((error as? ManagerSettingsValidationError)?.field, "context.unrecognized_budget")
        }
        XCTAssertThrowsError(try BudgetPolicy(schemaVersion: 2).validated())
    }

    func testBudgetPolicyRelationshipsAndScopeAreValidated() throws {
        XCTAssertThrowsError(try BudgetContextPolicy(mode: .manual, maxContextTokens: 512, responseReserveTokens: 512).validated())
        XCTAssertThrowsError(try BudgetContextPolicy(checkpointRatio: 0.9, rolloverRatio: 0.8).validated())
        XCTAssertThrowsError(try BudgetContextPolicy(emergencyRatio: .infinity).validated())
        XCTAssertThrowsError(try BudgetToolPolicy(callsPerSession: 4).validated())
        XCTAssertThrowsError(try BudgetToolPolicy(maxInFlight: 9).validated())
        XCTAssertThrowsError(try BudgetPolicyScope(kind: .projectOverride).validated())
        let scope = BudgetPolicyScope(kind: .projectOverride, projectID: UUID().uuidString.lowercased(), projectGeneration: 1)
        let selection = try BudgetPolicyState.default.resolve(scope)
        XCTAssertTrue(selection.inherited)
        XCTAssertEqual(selection.revision, 0)
        XCTAssertEqual(selection.globalRevision, 1)
        XCTAssertEqual(selection.policySource, "global_default")
        XCTAssertFalse(selection.policy.automaticHandoffEnabled)
    }

    func testSettingsIntegerDecoderRejectsTrapsAndFoundationCoercion() {
        let invalid: [Any] = [
            Double.infinity, -Double.infinity, Double.nan, Double.greatestFiniteMagnitude,
            Double(Int.max), 1.5, true, false, NSNumber(value: true), UInt64.max,
            NSDecimalNumber(string: "1.00000000000000001"), NSDecimalNumber.notANumber,
            "1.5", "9223372036854775808", NSNull(),
        ]
        for value in invalid {
            XCTAssertNil(ManagerSettingsNormalizer.intValue(value), "Unexpected coercion: \(value)")
            XCTAssertNil(JSONSupport.exactInteger(value), "Unexpected JSON integer: \(value)")
            let config = AppConfig.fromDictionary([
                "shell": ["default_timeout_sec": value], "dashboard": ["port": value],
                "manager": ["watchdog_interval_sec": value], "sessions": ["idle_ttl_sec": value],
            ])
            XCTAssertEqual(config.shell.defaultTimeoutSec, AppConfig.default.shell.defaultTimeoutSec)
            XCTAssertEqual(config.dashboard.port, AppConfig.default.dashboard.port)
            XCTAssertEqual(config.manager.watchdogIntervalSec, AppConfig.default.manager.watchdogIntervalSec)
            XCTAssertEqual(config.sessions.idleTTLSec, AppConfig.default.sessions.idleTTLSec)
        }
        for (value, expected) in [(Int.max as Any, Int.max), (Int.min as Any, Int.min),
                                  (42.0 as Any, 42), ("42" as Any, 42),
                                  (NSDecimalNumber(string: "9007199254740993") as Any, 9_007_199_254_740_993)] {
            XCTAssertEqual(ManagerSettingsNormalizer.intValue(value), expected)
        }
        XCTAssertNil(JSONSupport.exactInteger("42"))
    }

    func testAppConfigRoundTripDictionary() {
        var cfg = AppConfig.default
        cfg.dashboard.port = 8899
        cfg.manager.autoRestart = false
        cfg.logLevel = "debug"
        let restored = AppConfig.fromDictionary(cfg.asDictionary())
        XCTAssertEqual(restored.dashboard.port, 8899)
        XCTAssertEqual(restored.manager.autoRestart, false)
        XCTAssertEqual(restored.logLevel, "debug")
        XCTAssertEqual(restored.configSchemaVersion, AppConfig.currentSchemaVersion)
        XCTAssertTrue(restored.shell.enabled)
        XCTAssertFalse(restored.shell.userDisabled)
    }

    func testAppConfigApplySettingsPatch() {
        let allowedRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let cfg = AppConfig.default.applying(settings: ManagerSettingsPatch(
            dashboardPort: 9001,
            watchdogIntervalSec: 7,
            shellEnabled: false,
            allowedRoots: [allowedRoot]
        ))
        XCTAssertEqual(cfg.dashboard.port, 9001)
        XCTAssertEqual(cfg.manager.watchdogIntervalSec, 7)
        XCTAssertFalse(cfg.shell.enabled)
        XCTAssertTrue(cfg.shell.userDisabled)
        XCTAssertEqual(cfg.shell.policyOrigin, "user_disabled")
        XCTAssertEqual(cfg.allowedRoots, [allowedRoot])
    }

    func testFreshConfigUsesSchemaV2DefaultEnabledShellPolicy() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-fresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)

        try paths.ensureLayout()
        let object = try JSONSupport.object(from: Data(contentsOf: paths.configJSON))
        let shell = try XCTUnwrap(object["shell"] as? [String: Any])

        XCTAssertEqual(object["config_schema_version"] as? Int, AppConfig.currentSchemaVersion)
        XCTAssertEqual(shell["enabled"] as? Bool, true)
        XCTAssertEqual(shell["user_disabled"] as? Bool, false)
        XCTAssertEqual(shell["policy_version"] as? Int, AppConfig.currentSchemaVersion)
        XCTAssertEqual(shell["policy_origin"] as? String, "default_enabled")
        XCTAssertEqual(ConfigStore(paths: paths).shellMigrationStatus.state, "not_required")
    }

    func testLegacyShellMigrationBackupReceiptAndExplicitDisableRemainValid() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = AppPaths(home: home)
        let legacy: [String: Any] = [
            "log_level": "debug",
            "allowed_roots": [home.path],
            "shell": [
                "enabled": false,
                "default_timeout_sec": 41,
            ] as [String: Any],
            "dashboard": [
                "host": "127.0.0.1",
                "port": 7788,
                "refresh_interval_sec": 8,
            ] as [String: Any],
        ]
        let legacyData = try JSONSupport.data(from: legacy)
        try legacyData.write(to: paths.configJSON, options: .atomic)

        let store = ConfigStore(paths: paths)
        XCTAssertEqual(store.model.configSchemaVersion, AppConfig.currentSchemaVersion)
        XCTAssertTrue(store.model.shell.enabled)
        XCTAssertFalse(store.model.shell.userDisabled)
        XCTAssertEqual(store.model.shell.policyOrigin, "legacy_disabled_default_migrated")
        XCTAssertEqual(store.model.shell.defaultTimeoutSec, 41)
        XCTAssertEqual(store.shellMigrationStatus.state, "migrated")
        XCTAssertTrue(store.shellMigrationStatus.receiptValid)
        XCTAssertTrue(store.shellMigrationStatus.diagnosticPending)

        let receiptData = try Data(contentsOf: paths.shellPolicyMigrationReceipt)
        let receipt = try JSONSupport.object(from: receiptData)
        XCTAssertEqual(receipt["status"] as? String, "completed")
        XCTAssertEqual(receipt["diagnostic_emitted"] as? Bool, false)
        let backupName = try XCTUnwrap(receipt["backup_filename"] as? String)
        XCTAssertTrue(backupName.hasPrefix("config.pre-v2."))
        let backupURL = paths.configMigrationsDir.appendingPathComponent(backupName)
        XCTAssertEqual(try Data(contentsOf: backupURL), legacyData)
        XCTAssertEqual(
            receipt["backup_sha256"] as? String,
            JSONSupport.sha256Hex(legacyData)
        )
        let targetName = try XCTUnwrap(receipt["target_filename"] as? String)
        let originalTarget = try Data(
            contentsOf: paths.configMigrationsDir.appendingPathComponent(targetName)
        )
        XCTAssertEqual(receipt["target_sha256"] as? String, JSONSupport.sha256Hex(originalTarget))
        let initialMigrationID = try XCTUnwrap(store.model.configMigrationID)

        let initialArtifacts = try FileManager.default.contentsOfDirectory(
            at: paths.configMigrationsDir,
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasPrefix(".") }
        _ = ConfigStore(paths: paths)
        let reloadedArtifacts = try FileManager.default.contentsOfDirectory(
            at: paths.configMigrationsDir,
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasPrefix(".") }
        XCTAssertEqual(reloadedArtifacts.count, initialArtifacts.count, "migration must not repeat")

        _ = try store.update(ManagerSettingsPatch(shellEnabled: false), save: true)
        store.reload()
        XCTAssertFalse(store.model.shell.enabled)
        XCTAssertTrue(store.model.shell.userDisabled)
        XCTAssertEqual(store.model.shell.policyOrigin, "user_disabled")
        XCTAssertEqual(store.model.configMigrationID, initialMigrationID)
        XCTAssertEqual(store.shellMigrationStatus.state, "migrated_modified")
        XCTAssertTrue(store.shellMigrationStatus.receiptValid)

        let modifiedConfig = try Data(contentsOf: paths.configJSON)
        XCTAssertNotEqual(JSONSupport.sha256Hex(modifiedConfig), receipt["target_sha256"] as? String)
        XCTAssertEqual(
            receipt["target_sha256"] as? String,
            JSONSupport.sha256Hex(try Data(contentsOf: paths.configMigrationsDir.appendingPathComponent(targetName)))
        )
        let modifiedReceipt = try JSONSupport.object(
            from: Data(contentsOf: paths.shellPolicyMigrationReceipt)
        )
        XCTAssertEqual(
            modifiedReceipt["current_config_sha256"] as? String,
            JSONSupport.sha256Hex(modifiedConfig)
        )
        XCTAssertEqual(modifiedReceipt["current_config_state"] as? String, "schema_v2_modified")

        let app = try ForgeApp.bootstrap(home: home)
        XCTAssertTrue(app.diagnostics.flush(timeout: 2))
        app.shutdown()
        let emittedReceipt = try JSONSupport.object(
            from: Data(contentsOf: paths.shellPolicyMigrationReceipt)
        )
        XCTAssertEqual(emittedReceipt["diagnostic_emitted"] as? Bool, true)
        let diagnosticText = try String(contentsOf: paths.masterDiagnostics, encoding: .utf8)
        XCTAssertTrue(diagnosticText.contains("shell_policy_migration_completed"))
    }

    func testCurrentSchemaShellPolicyPreservesExplicitUserOptOut() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-explicit-opt-out-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = AppPaths(home: home)
        let current: [String: Any] = [
            "config_schema_version": AppConfig.currentSchemaVersion,
            "allowed_roots": [home.path],
            "shell": [
                "enabled": false,
                "user_disabled": true,
                "policy_origin": "user_disabled",
                "default_timeout_sec": 45,
            ] as [String: Any],
        ]
        try JSONSupport.data(from: current).write(to: paths.configJSON, options: .atomic)

        let store = ConfigStore(paths: paths)

        XCTAssertFalse(store.model.shell.enabled)
        XCTAssertTrue(store.model.shell.userDisabled)
        XCTAssertEqual(store.model.shell.policyOrigin, "user_disabled")
        XCTAssertEqual(store.model.shell.policyVersion, AppConfig.currentSchemaVersion)
        XCTAssertEqual(store.model.shell.defaultTimeoutSec, 45)
        XCTAssertEqual(store.shellMigrationStatus.state, "not_required")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.shellPolicyMigrationReceipt.path
        ))

        let reloaded = ConfigStore(paths: paths)
        XCTAssertFalse(reloaded.model.shell.enabled)
        XCTAssertTrue(reloaded.model.shell.userDisabled)
        XCTAssertEqual(reloaded.model.shell.policyOrigin, "user_disabled")
        XCTAssertEqual(reloaded.shellMigrationStatus.state, "not_required")
    }

    func testConcurrentLegacyConfigLoadsPerformOneMigration() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-concurrent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = AppPaths(home: home)
        try JSONSupport.data(from: [
            "shell": ["enabled": false, "default_timeout_sec": 30] as [String: Any],
        ]).write(to: paths.configJSON, options: .atomic)

        let results = ConfigMigrationResultBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "config-migration-test", attributes: .concurrent)
        for _ in 0..<8 {
            group.enter()
            queue.async {
                let store = ConfigStore(paths: paths)
                results.append(
                    migrationID: store.model.configMigrationID,
                    state: store.shellMigrationStatus.state,
                    shellEnabled: store.model.shell.enabled
                )
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

        let snapshot = results.snapshot()
        XCTAssertEqual(snapshot.count, 8)
        XCTAssertTrue(snapshot.allSatisfy(\.shellEnabled))
        XCTAssertTrue(snapshot.allSatisfy { $0.state.hasPrefix("migrated") })
        XCTAssertEqual(Set(snapshot.compactMap(\.migrationID)).count, 1)
        let artifacts = try FileManager.default.contentsOfDirectory(
            at: paths.configMigrationsDir,
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasPrefix(".") }
        XCTAssertEqual(artifacts.count, 3, "one backup, target snapshot, and receipt are expected")
    }

    func testConfigStoreTypedModel() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let store = ConfigStore(paths: paths)
        _ = try store.update(["dashboard": ["port": 8123] as [String: Any]], save: true)
        store.reload()
        XCTAssertEqual(store.model.dashboard.port, 8123)
        _ = try store.update(
            ManagerSettingsPatch(
                dashboardHost: "127.0.0.1",
                autoRestart: false,
                shellEnabled: false
            ),
            save: true
        )
        XCTAssertEqual(store.model.manager.autoRestart, false)
        XCTAssertFalse(store.model.shell.enabled)
        XCTAssertTrue(store.model.shell.userDisabled)
    }

    func testDoctorModelTyped() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("docm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let report = try app.doctorModel()
        XCTAssertTrue(report.ok)
        XCTAssertFalse(report.checks.isEmpty)
        XCTAssertEqual(report.telemetry.runtime, TelemetryService.runtimeIdentifier)
        XCTAssertTrue(report.shellPolicy.enabled)
        XCTAssertEqual(report.shellPolicy.policyVersion, AppConfig.currentSchemaVersion)
        let edge = try app.doctor()
        XCTAssertEqual(edge["ok"] as? Bool, true)
        let shell = edge["shell"] as? [String: Any]
        XCTAssertEqual(shell?["enabled"] as? Bool, true)
        XCTAssertNotNil(shell?["runtimes"] as? [String: Any])
    }

    func testStatusSnapshotModel() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("stat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        let snap = try app.statusSnapshotModel()
        XCTAssertTrue(snap.ok)
        XCTAssertEqual(snap.runtime, "swift")
        XCTAssertGreaterThanOrEqual(snap.agentCount, 10)
        XCTAssertFalse(snap.tools.isEmpty)
        XCTAssertTrue(snap.shellPolicy.enabled)
        let edge = try app.statusSnapshot()
        XCTAssertEqual((edge["shell"] as? [String: Any])?["enabled"] as? Bool, true)
    }

    func testCPUFrequencyNonNilOnThisMac() {
        let cpu = CPUCollector().collect()
        // Effective / sysctl frequency path must always produce a value on macOS.
        XCTAssertNotNil(cpu.freqMHz, "freq_mhz should not be nil")
        XCTAssertGreaterThan(cpu.freqMHz ?? 0, 400)
        XCTAssertEqual(cpu.freqPerCoreMHz?.count, cpu.countLogical)
    }

    func testCPUFrequencyEstimatorClusterEffective() {
        let util = Array(repeating: 80.0, count: 8) + Array(repeating: 10.0, count: 4)
        let est = CPUFrequencyEstimator.estimate(
            brand: "Apple M4 Pro",
            model: "Mac16,8",
            perCoreUtilization: util
        )
        XCTAssertEqual(est.source, "cluster-util-effective")
        XCTAssertGreaterThan(est.averageMHz, 1000)
        XCTAssertEqual(est.perCoreMHz.count, 12)
        // Busy cores should report higher effective MHz than idle-ish ones.
        XCTAssertGreaterThan(est.perCoreMHz[0], est.perCoreMHz[10])
    }

    func testManagerRuntimeIsolation() {
        let rt = ManagerRuntime()
        XCTAssertEqual(rt.state, .stopped)
        rt.markRunning()
        XCTAssertEqual(rt.state, .running)
        XCTAssertNotNil(rt.startedAt)
        let n = rt.beginRestart()
        XCTAssertEqual(n, 1)
        XCTAssertEqual(rt.state, .restarting)
    }
}

private final class ConfigMigrationResultBox: @unchecked Sendable {
    struct Result {
        var migrationID: String?
        var state: String
        var shellEnabled: Bool
    }

    private let lock = NSLock()
    private var values: [Result] = []

    func append(migrationID: String?, state: String, shellEnabled: Bool) {
        lock.lock()
        values.append(Result(migrationID: migrationID, state: state, shellEnabled: shellEnabled))
        lock.unlock()
    }

    func snapshot() -> [Result] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

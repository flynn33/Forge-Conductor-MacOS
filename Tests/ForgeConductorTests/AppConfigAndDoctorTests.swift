// AppConfigAndDoctorTests.swift
// Verifies configuration round trips, settings patches, health reports, and doctor output.
// These tests protect the typed operator-facing contracts shared by CLI and native app.

import XCTest
@testable import ForgeConductorCore

final class AppConfigAndDoctorTests: XCTestCase {
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
        let cfg = AppConfig.default.applying(settings: ManagerSettingsPatch(
            dashboardPort: 9001,
            watchdogIntervalSec: 7,
            shellEnabled: false
        ))
        XCTAssertEqual(cfg.dashboard.port, 9001)
        XCTAssertEqual(cfg.manager.watchdogIntervalSec, 7)
        XCTAssertFalse(cfg.shell.enabled)
        XCTAssertTrue(cfg.shell.userDisabled)
        XCTAssertEqual(cfg.shell.policyOrigin, "user_disabled")
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

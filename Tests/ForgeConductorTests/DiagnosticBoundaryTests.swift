// DiagnosticBoundaryTests.swift
// Verifies bounded diagnostic response-path work and explicit persistence drains.

import XCTest
@testable import ForgeConductorCore

final class DiagnosticBoundaryTests: XCTestCase {
    func testBootstrapSharesPreparedDiagnosticOwnerAndPreservesConfiguredRole() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-diagnostic-owner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        _ = try ConfigStore(paths: paths).update(["mcp": ["role": "fallback"]])
        let diagnostics = DiagnosticLog(paths: paths, role: "startup")
        defer { _ = diagnostics.shutdown(timeout: 2) }
        diagnostics.info("gui_bootstrap_started", category: .bootstrap)
        let app = try ForgeApp.bootstrap(home: home, diagnostics: diagnostics)
        defer { app.shutdown() }
        XCTAssertTrue(app.diagnostics === diagnostics, "Startup and runtime must have one diagnostic persistence owner")
        XCTAssertEqual(diagnostics.recent().first?.role, "startup")
        diagnostics.info("shared_owner_runtime_event", category: .diagnostics)
        XCTAssertEqual(diagnostics.recent(limit: 1).first?.role, "fallback")
        let exported = try app.diagnostics.export(to: paths.exportsDir)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported.jsonURL)) as? [String: Any])
        let records = try XCTUnwrap(payload["records"] as? [[String: Any]])
        XCTAssertEqual(records.filter { $0["event"] as? String == "gui_bootstrap_started" }.count, 1)
        XCTAssertEqual(records.filter { $0["event"] as? String == "shared_owner_runtime_event" }.count, 1)

        XCTAssertTrue(app.shutdown().completed)
        diagnostics.warn("caller_owned_after_graph_shutdown", category: .bootstrap)
        XCTAssertTrue(diagnostics.flush(timeout: 2))
        let afterShutdown = try diagnostics.export(to: paths.exportsDir, basename: "after-graph-shutdown")
        XCTAssertTrue(try String(contentsOf: afterShutdown.jsonURL, encoding: .utf8).contains("caller_owned_after_graph_shutdown"))
        XCTAssertTrue(try String(contentsOf: paths.masterDiagnostics, encoding: .utf8).contains("caller_owned_after_graph_shutdown"))
    }

    func testBootstrapSharesDiagnosticOwnerWhenPersistenceCreatesTheIdenticalHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-diagnostic-created-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        let paths = AppPaths(home: home)
        let diagnostics = DiagnosticLog(paths: paths)
        defer { _ = diagnostics.shutdown(timeout: 2) }
        func operand(_ url: URL) -> String {
            "absolute=\(String(url.absoluteString.prefix(512))), path=\(String(url.path.prefix(512))), hasDirectoryPath=\(url.hasDirectoryPath), isFileURL=\(url.isFileURL)"
        }
        let inputBefore = operand(home)
        let diagnosticBefore = operand(diagnostics.homeURL.standardizedFileURL)
        diagnostics.info("shared_owner_created_before_bootstrap", category: .bootstrap)
        XCTAssertTrue(diagnostics.flush(timeout: 2), "The owned diagnostic directory-creation barrier must drain")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configJSON.path),
                       "Diagnostic persistence must not create application configuration")

        let freshPaths = AppPaths(home: home)
        let diagnosticOperand = diagnostics.homeURL.standardizedFileURL
        let bootstrapOperand = freshPaths.home.standardizedFileURL
        let operands = "inputBefore={\(inputBefore)}; diagnosticBefore={\(diagnosticBefore)}; diagnosticAfter={\(operand(diagnosticOperand))}; bootstrapAfter={\(operand(bootstrapOperand))}; URL_equal=\(diagnosticOperand == bootstrapOperand); path_equal=\(diagnosticOperand.path == bootstrapOperand.path)"
        let app: ForgeApp
        do {
            app = try ForgeApp.bootstrap(home: home, diagnostics: diagnostics)
        } catch {
            let native = error as NSError
            XCTFail("The identical explicit home must accept its prepared diagnostic owner after persistence creates the directory. Received failure(type=\(String(reflecting: type(of: error))), domain=\(native.domain), code=\(native.code), error=\(String(String(describing: error).prefix(512)))); \(operands)")
            return
        }
        defer { app.shutdown() }
        XCTAssertTrue(app.diagnostics === diagnostics, operands)
        XCTAssertEqual(app.paths.home.path, freshPaths.home.path, operands)
    }

    func testBootstrapSharesDiagnosticOwnerAcrossDirectoryHintsForTheSameHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-diagnostic-directory-hint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let fileHint = URL(fileURLWithPath: home.path, isDirectory: false)
        let directoryHint = URL(fileURLWithPath: home.path, isDirectory: true)
        XCTAssertEqual(fileHint.standardizedFileURL.path, directoryHint.standardizedFileURL.path)
        XCTAssertNotEqual(fileHint.standardizedFileURL, directoryHint.standardizedFileURL)
        XCTAssertEqual(fileHint.standardizedFileURL.appendingPathComponent("", isDirectory: true),
                       directoryHint.standardizedFileURL.appendingPathComponent("", isDirectory: true))
        for (attempt, homes) in [(fileHint, directoryHint), (directoryHint, fileHint)].enumerated() {
            let (diagnosticHome, bootstrapHome) = homes
            let diagnostics = DiagnosticLog(paths: AppPaths(home: diagnosticHome))
            defer { _ = diagnostics.shutdown(timeout: 2) }
            let app: ForgeApp
            do {
                app = try ForgeApp.bootstrap(home: bootstrapHome, diagnostics: diagnostics)
            } catch {
                XCTFail("Same-home directory hint attempt \(attempt) failed: \(error)")
                return
            }
            XCTAssertTrue(app.diagnostics === diagnostics)
            XCTAssertEqual(app.paths.home.path, home.path)
            XCTAssertTrue(app.shutdown().completed)
        }
    }

    func testBootstrapPreservesFileURLAuthorityIsolationAcrossDirectoryHints() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-diagnostic-authority-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        var components = try XCTUnwrap(URLComponents(url: home, resolvingAgainstBaseURL: true))
        components.host = "forge-diagnostic-other-host.invalid"
        let otherAuthority = try XCTUnwrap(components.url)
        XCTAssertEqual(home.standardizedFileURL.path, otherAuthority.standardizedFileURL.path)
        let standardizedAuthority = otherAuthority.standardizedFileURL
        let normalized = standardizedAuthority.appendingPathComponent("", isDirectory: true)
        XCTAssertEqual(normalized.host, standardizedAuthority.host)
        XCTAssertEqual(normalized.absoluteString,
                       standardizedAuthority.absoluteString.hasSuffix("/")
                       ? standardizedAuthority.absoluteString : standardizedAuthority.absoluteString + "/")
        XCTAssertNotEqual(home.standardizedFileURL.appendingPathComponent("", isDirectory: true), normalized)
        let diagnostics = DiagnosticLog(paths: AppPaths(home: home))
        defer { _ = diagnostics.shutdown(timeout: 2) }
        XCTAssertThrowsError(try ForgeApp.bootstrap(home: otherAuthority, diagnostics: diagnostics)) { error in
            XCTAssertEqual(error as? ForgeBootstrapError, .diagnosticHomeMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    func testBootstrapRejectsDiagnosticOwnerFromAnotherHomeBeforeCreatingLayout() throws {
        let first = FileManager.default.temporaryDirectory.appendingPathComponent("forge-diagnostic-first-\(UUID().uuidString)")
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("forge-diagnostic-second-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let diagnostics = DiagnosticLog(paths: AppPaths(home: first))
        defer { _ = diagnostics.shutdown(timeout: 2) }
        XCTAssertThrowsError(try ForgeApp.bootstrap(home: second, diagnostics: diagnostics)) { error in
            guard case ForgeBootstrapError.diagnosticHomeMismatch = error else {
                return XCTFail("Unexpected home isolation error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testDiagnosticsPersistAndExportWhenUnrelatedApplicationLayoutCannotBeCreated() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-diagnostic-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AppPaths(home: home)
        try Data("not a directory".utf8).write(to: home.appendingPathComponent("agents"))
        XCTAssertThrowsError(try paths.ensureLayout())

        let log = DiagnosticLog(paths: paths, role: "gui")
        defer { _ = log.shutdown(timeout: 2) }
        log.error("gui_bootstrap_failed", ["error": "application layout unavailable"], category: .bootstrap)
        XCTAssertTrue(log.flush(timeout: 2))
        XCTAssertTrue(try String(contentsOf: paths.masterDiagnostics, encoding: .utf8).contains("gui_bootstrap_failed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configJSON.path),
                       "Diagnostic persistence must not depend on or create application configuration")
        let exported = try log.export(to: home.appendingPathComponent("chosen-export"), allowPartialHistory: true)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: exported.jsonURL)) as? [String: Any])
        XCTAssertEqual(payload["persisted_history_available"] as? Bool, true)
        XCTAssertEqual(payload["history_scope"] as? String, "current_master_log_latest_50000_lines_plus_live_ring")
        XCTAssertEqual(exported.recordCount, 1)
        XCTAssertTrue(try String(contentsOf: exported.markdownURL, encoding: .utf8).contains("gui_bootstrap_failed"))
    }

    func testContendedPersistenceDoesNotHoldResponsePathAndRingRemainsBounded() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-diagnostic-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = AppPaths(home: home)
        try paths.ensureLayout()
        let blocker = OneShotDiagnosticPersistenceBlocker()
        defer { blocker.release.signal() }
        let log = DiagnosticLog(
            paths: paths,
            ringLimit: 5,
            maximumLogBytes: 4_096,
            retainedArchives: 1,
            persistenceQueueCapacity: 2,
            beforePersistence: { blocker.blockOnce() }
        )

        log.info("blocked_writer", category: .diagnostics)
        XCTAssertEqual(blocker.started.wait(timeout: .now() + 2), .success)

        let startedAt = Date()
        log.warn("response_boundary", category: .mcp)
        for index in 0..<20 {
            log.info("saturated_\(index)", category: .diagnostics)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertGreaterThan(log.droppedPersistenceCount, 0)

        let recent = log.recent(limit: .max)
        XCTAssertEqual(recent.count, 5)
        XCTAssertEqual(recent.last?.event, "saturated_19")

        let shutdownStartedAt = Date()
        XCTAssertFalse(log.shutdown(timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(shutdownStartedAt), 0.5)
        XCTAssertThrowsError(try log.loadPersisted()) { error in
            XCTAssertEqual(error as? DiagnosticExportError, .persistenceBusy)
        }

        blocker.release.signal()
        XCTAssertTrue(log.flush(timeout: 2))
        let persisted = try String(contentsOf: paths.masterDiagnostics, encoding: .utf8)
        XCTAssertTrue(persisted.contains("blocked_writer"))
        XCTAssertTrue(persisted.contains("response_boundary"))
    }

    func testApplicationShutdownDrainsAuditBeforeSQLiteAndDiagnosticsLast() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-evidence-shutdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = try ForgeApp.bootstrap(home: home)
        app.diagnostics.info("shutdown_diagnostic", category: .diagnostics)
        XCTAssertTrue(app.audit.attemptAppend(
            tool: "shutdown_audit",
            status: "cancelled",
            clientID: "shutdown-client",
            args: ["operation": "shutdown"],
            durationMs: 1,
            error: "request_cancelled",
            mutating: true
        ))

        XCTAssertTrue(app.shutdown().completed)
        let diagnosticText = try String(contentsOf: app.paths.masterDiagnostics, encoding: .utf8)
        let auditText = try String(contentsOf: app.paths.auditJSONL, encoding: .utf8)
        XCTAssertTrue(diagnosticText.contains("shutdown_diagnostic"))
        XCTAssertTrue(auditText.contains("shutdown_audit"))

        XCTAssertTrue(app.shutdown().completed, "shutdown must remain idempotent")
    }
}

private final class OneShotDiagnosticPersistenceBlocker: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var waiting = true

    func blockOnce() {
        lock.lock()
        let shouldWait = waiting
        waiting = false
        lock.unlock()
        guard shouldWait else { return }
        started.signal()
        _ = release.wait(timeout: .now() + 5)
    }
}

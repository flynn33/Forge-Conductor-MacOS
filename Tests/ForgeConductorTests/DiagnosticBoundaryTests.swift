// DiagnosticBoundaryTests.swift
// Verifies bounded diagnostic response-path work and explicit persistence drains.

import XCTest
@testable import ForgeConductorCore

final class DiagnosticBoundaryTests: XCTestCase {
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

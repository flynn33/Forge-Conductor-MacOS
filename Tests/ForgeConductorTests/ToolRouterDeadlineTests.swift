// ToolRouterDeadlineTests.swift
// Verifies shared deadline admission and committed-result truthfulness.

import XCTest
import SQLite3
@testable import ForgeConductorCore

final class ToolRouterDeadlineTests: XCTestCase {
    func testCancellationTokenSafelyBoundsNonfiniteTimeouts() {
        let positiveInfinity = ToolCallCancellation(timeoutSeconds: .infinity)
        XCTAssertGreaterThan(positiveInfinity.remainingTimeInterval ?? 0, 86_000)
        XCTAssertLessThanOrEqual(positiveInfinity.remainingTimeInterval ?? .infinity, 86_400)

        for invalid in [TimeInterval.nan, -.infinity] {
            let cancellation = ToolCallCancellation(timeoutSeconds: invalid)
            XCTAssertThrowsError(try cancellation.checkCancellation()) { error in
                XCTAssertTrue(error is ToolCallDeadlineExceeded, "unexpected error: \(error)")
            }
        }
    }

    func testExpiredDeadlineStopsBeforePackDispatch() throws {
        try withApp("expired") { app in
            let pack = RecordingDeadlineToolPack(mode: .recordInvocation)
            let router = ToolRouter(app: app, packs: [pack])
            let cancellation = ToolCallCancellation(timeoutSeconds: 0)

            let result = try router.call(
                name: "deadline_test",
                arguments: [:],
                clientID: ClientID("deadline-before-dispatch"),
                cancellation: cancellation
            )

            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.payload["code"] as? String, "deadline_exceeded")
            XCTAssertEqual(pack.invocationCount, 0)
        }
    }

    func testAlreadyCancelledRequestStillRecordsBoundedAuditEvidence() throws {
        try withApp("cancelled-before-admission") { app in
            let pack = RecordingDeadlineToolPack(mode: .recordInvocation)
            let router = ToolRouter(app: app, packs: [pack])
            let cancellation = ToolCallCancellation(timeoutSeconds: 5)
            cancellation.cancel()

            XCTAssertThrowsError(try router.call(
                name: "deadline_test",
                arguments: [:],
                clientID: ClientID("cancelled-before-admission"),
                cancellation: cancellation
            )) { error in
                XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
            }

            XCTAssertEqual(pack.invocationCount, 0)
            XCTAssertTrue(app.audit.flushAttempts(timeout: 2))
            let audit = try XCTUnwrap(try app.audit.recent(limit: 20).first(where: {
                $0.tool == "deadline_test"
                    && $0.clientID == "cancelled-before-admission"
            }))
            XCTAssertEqual(audit.status, "cancelled")
        }
    }

    func testCompletedHandlerResultRemainsAuthoritativeAfterLateCancellation() throws {
        try withApp("committed") { app in
            let pack = RecordingDeadlineToolPack(mode: .commitThenCancel)
            let router = ToolRouter(app: app, packs: [pack])
            let cancellation = ToolCallCancellation(timeoutSeconds: 5)

            let result = try router.call(
                name: "deadline_test",
                arguments: [:],
                clientID: ClientID("deadline-committed-result"),
                cancellation: cancellation
            )

            XCTAssertTrue(result.ok)
            XCTAssertEqual(result.payload["committed"] as? Bool, true)
            XCTAssertEqual(pack.invocationCount, 1)
            XCTAssertTrue(cancellation.isCancelled)
        }
    }

    func testExpiredDeadlineReturnIsNotDelayedByContendedAuditDatabase() throws {
        try withApp("contended-audit") { app in
            var locker: OpaquePointer?
            XCTAssertEqual(sqlite3_open(app.store.path.path, &locker), SQLITE_OK)
            let opened = try XCTUnwrap(locker)
            var transactionOpen = false
            defer {
                if transactionOpen {
                    sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil)
                }
                sqlite3_close(opened)
            }
            XCTAssertEqual(sqlite3_exec(opened, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
            transactionOpen = true

            let pack = RecordingDeadlineToolPack(mode: .recordInvocation)
            let router = ToolRouter(app: app, packs: [pack])
            let cancellation = ToolCallCancellation(timeoutSeconds: 0)
            let startedAt = Date()

            let result = try router.call(
                name: "deadline_test",
                arguments: [:],
                clientID: ClientID("deadline-contended-audit"),
                cancellation: cancellation
            )

            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.payload["code"] as? String, "deadline_exceeded")
            XCTAssertEqual(pack.invocationCount, 0)

            XCTAssertEqual(sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
            transactionOpen = false
            XCTAssertTrue(app.audit.flushAttempts(timeout: 3))
            let audit = try XCTUnwrap(try app.audit.recent(limit: 20).first(where: {
                $0.tool == "deadline_test"
                    && $0.clientID == "deadline-contended-audit"
            }))
            XCTAssertEqual(audit.status, "deadline_exceeded")
        }
    }

    func testCompletedResultIsNotDelayedBeyondAuditContentionBound() throws {
        try withApp("bounded-audit") { app in
            var locker: OpaquePointer?
            XCTAssertEqual(sqlite3_open(app.store.path.path, &locker), SQLITE_OK)
            let opened = try XCTUnwrap(locker)
            defer {
                sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil)
                sqlite3_close(opened)
            }
            XCTAssertEqual(sqlite3_exec(opened, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)

            let pack = RecordingDeadlineToolPack(mode: .recordInvocation)
            let router = ToolRouter(app: app, packs: [pack])
            let cancellation = ToolCallCancellation(timeoutSeconds: 5)
            let startedAt = Date()

            let result = try router.call(
                name: "deadline_test",
                arguments: [:],
                clientID: ClientID("deadline-bounded-audit"),
                cancellation: cancellation
            )

            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
            XCTAssertTrue(result.ok)
            XCTAssertEqual(pack.invocationCount, 1)
        }
    }

    func testCancelledReturnIsNotDelayedAndUsesIndependentAuditControl() throws {
        try withApp("cancelled-audit") { app in
            var locker: OpaquePointer?
            XCTAssertEqual(sqlite3_open(app.store.path.path, &locker), SQLITE_OK)
            let opened = try XCTUnwrap(locker)
            var transactionOpen = false
            defer {
                if transactionOpen {
                    sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil)
                }
                sqlite3_close(opened)
            }
            XCTAssertEqual(sqlite3_exec(opened, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
            transactionOpen = true

            let pack = RecordingDeadlineToolPack(mode: .cancelThenThrow)
            let router = ToolRouter(app: app, packs: [pack])
            let cancellation = ToolCallCancellation(timeoutSeconds: 5)
            let startedAt = Date()

            XCTAssertThrowsError(try router.call(
                name: "deadline_test",
                arguments: [:],
                clientID: ClientID("cancelled-contended-audit"),
                cancellation: cancellation
            )) { error in
                XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
            }

            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
            XCTAssertEqual(pack.invocationCount, 1)
            XCTAssertTrue(cancellation.isCancelled)

            XCTAssertEqual(sqlite3_exec(opened, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
            transactionOpen = false
            XCTAssertTrue(app.audit.flushAttempts(timeout: 3))
            let audit = try XCTUnwrap(try app.audit.recent(limit: 20).first(where: {
                $0.tool == "deadline_test"
                    && $0.clientID == "cancelled-contended-audit"
            }))
            XCTAssertEqual(audit.status, "cancelled")
        }
    }

    func testBootstrapAttachmentFailureDoesNotConcealPrimarySuccess() throws {
        try withApp("bootstrap-reconciliation") { app in
            let projectRoot = app.paths.home.appendingPathComponent("bootstrap-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let router = ToolRouter(app: app)

            let result = try router.call(
                name: "project_memory.initialize",
                arguments: ["project_path": projectRoot.path],
                clientID: ClientID(" bootstrap-reconciliation")
            )

            XCTAssertTrue(result.ok, "\(result.payload)")
            XCTAssertEqual(result.payload["primary_committed"] as? Bool, true)
            XCTAssertEqual(result.payload["project_context_attachment"] as? String, "pending")
            XCTAssertEqual(
                result.payload["project_context_error"] as? String,
                "project_context_attachment_failed"
            )
            XCTAssertEqual(result.payload["reconciled"] as? Bool, false)
            XCTAssertEqual(result.payload["reconciliation_required"] as? Bool, true)
            let committedProjectID = try XCTUnwrap(result.payload["project_id"] as? String)

            let retry = try router.call(
                name: "project_memory.initialize",
                arguments: [
                    "project_path": projectRoot.path,
                    "project_id": committedProjectID,
                ],
                clientID: ClientID("bootstrap-reconciliation-retry")
            )
            XCTAssertTrue(retry.ok, "\(retry.payload)")
            XCTAssertEqual(retry.payload["project_id"] as? String, committedProjectID)
            XCTAssertEqual(retry.payload["project_context_attached"] as? Bool, true)
        }
    }

    func testIdentityCommitBeforeRepositoryOpenReportsPendingAndExactRetryActivates() throws {
        try withApp("bootstrap-repository-open") { app in
            let projectRoot = app.paths.home.appendingPathComponent("repository-open-project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let target = try app.projectMemory.identities.discoverTarget(path: projectRoot.path)
            let preparation = try app.projectContexts.prepareControlledRegistration(
                identities: app.projectMemory.identities,
                target: target,
                requestedProjectID: nil,
                displayName: nil
            )
            let projectDirectory = app.paths.projectsDir
                .appendingPathComponent(preparation.descriptor.id, isDirectory: true)
            try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
            let blockedDatabase = projectDirectory.appendingPathComponent("memory.sqlite3", isDirectory: true)
            try FileManager.default.createDirectory(at: blockedDatabase, withIntermediateDirectories: true)

            let router = ToolRouter(app: app)
            let first = try router.call(
                name: "project_memory.initialize",
                arguments: ["project_path": projectRoot.path],
                clientID: ClientID("bootstrap-repository-open")
            )

            XCTAssertTrue(first.ok, "\(first.payload)")
            XCTAssertEqual(first.payload["primary_committed"] as? Bool, true)
            XCTAssertEqual(first.payload["primary_commit_phase"] as? String, "identity_published")
            XCTAssertEqual(first.payload["project_memory_initialization"] as? String, "pending")
            XCTAssertEqual(first.payload["project_context_attachment"] as? String, "pending")
            XCTAssertEqual(first.payload["reconciled"] as? Bool, false)
            XCTAssertEqual(first.payload["reconciliation_required"] as? Bool, true)
            XCTAssertEqual(
                first.payload["project_context_error"] as? String,
                "project_memory_initialization_failed"
            )
            XCTAssertEqual(first.payload["project_id"] as? String, preparation.descriptor.id)

            let descriptor = try app.projectMemory.identities.descriptor(
                projectID: preparation.descriptor.id
            )
            XCTAssertTrue(descriptor.aliases.contains(projectRoot.path))
            let projectID = ProjectID(try XCTUnwrap(UUID(uuidString: preparation.descriptor.id)))
            let controlRecord = try XCTUnwrap(app.projectContexts.project(projectID))
            XCTAssertEqual(controlRecord.lifecycleState, .maintenance)
            XCTAssertThrowsError(
                try app.projectContexts.invocationContext(
                    for: ClientID("bootstrap-repository-open")
                )
            )

            try FileManager.default.removeItem(at: blockedDatabase)
            let retry = try router.call(
                name: "project_memory.initialize",
                arguments: [
                    "project_path": projectRoot.path,
                    "project_id": preparation.descriptor.id,
                ],
                clientID: ClientID("bootstrap-repository-open")
            )
            XCTAssertTrue(retry.ok, "\(retry.payload)")
            XCTAssertEqual(retry.payload["project_id"] as? String, preparation.descriptor.id)
            XCTAssertEqual(retry.payload["migration_status"] as? String, "current")
            XCTAssertEqual(retry.payload["project_context_attached"] as? Bool, true)
            XCTAssertEqual(try app.projectContexts.project(projectID)?.lifecycleState, .active)
        }
    }

    private func withApp(
        _ label: String,
        operation: (ForgeApp) throws -> Void
    ) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-router-deadline-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: home)
        _ = try app.config.update(
            ["allowed_roots": [FileManager.default.temporaryDirectory.path]],
            save: false
        )
        defer {
            app.shutdown()
            try? FileManager.default.removeItem(at: home)
        }
        try operation(app)
    }
}

private final class RecordingDeadlineToolPack: ToolPackHandling, @unchecked Sendable {
    enum Mode {
        case recordInvocation
        case commitThenCancel
        case cancelThenThrow
    }

    let toolNames = ["deadline_test"]

    private let mode: Mode
    private let lock = NSLock()
    private var count = 0

    init(mode: Mode) {
        self.mode = mode
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func handle(
        name: String,
        arguments: [String: Any],
        context: ToolInvocationContext?,
        clientID: ClientID,
        app: ForgeApp,
        cancellation: ToolCallCancellation?
    ) throws -> ToolResult? {
        guard name == "deadline_test" else { return nil }
        try cancellation?.checkCancellation()
        lock.lock()
        count += 1
        lock.unlock()
        if case .commitThenCancel = mode {
            cancellation?.cancel()
        } else if case .cancelThenThrow = mode {
            cancellation?.cancel()
            throw CancellationError()
        }
        return ToolResult(
            ok: true,
            payload: ["ok": true, "committed": true],
            isError: false
        )
    }
}

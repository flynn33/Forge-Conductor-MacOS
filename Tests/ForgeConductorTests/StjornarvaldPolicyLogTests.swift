import Foundation
import SQLite3
import XCTest
@testable import ForgeConductorCore

final class StjornarvaldPolicyLogTests: XCTestCase {
    func testCorrectionAndReopenPreserveAppendOnlyHistoryAndStableIdentity() throws {
        let fixture = try Fixture()
        let store = try fixture.makeStore()
        let candidate = fixture.candidate()

        let opened = try store.record(
            candidate,
            eventID: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let repeated = try store.record(
            candidate,
            eventID: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_002)
        )
        let corrected = try store.recordCorrection(
            violationID: opened.id,
            candidate: candidate,
            eventID: UUID(uuidString: "10000000-0000-4000-8000-000000000003")!,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_003)
        )
        let reopenID = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
        let reopened = try store.record(
            candidate,
            eventID: reopenID,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_004)
        )
        let idempotent = try store.record(
            candidate,
            eventID: reopenID,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_004)
        )
        XCTAssertThrowsError(
            try store.record(
                fixture.candidate(summary: "Conflicting content for the same event identity."),
                eventID: reopenID,
                occurredAt: Date(timeIntervalSince1970: 1_700_000_004)
            )
        )

        XCTAssertEqual(Set([opened.id, repeated.id, corrected.id, reopened.id]).count, 1)
        XCTAssertEqual(opened.state, .open)
        XCTAssertEqual(repeated.state, .repeated)
        XCTAssertEqual(repeated.occurrenceCount, 2)
        XCTAssertEqual(corrected.state, .corrected)
        XCTAssertEqual(corrected.occurrenceCount, 2)
        XCTAssertEqual(reopened.state, .reopened)
        XCTAssertEqual(reopened.occurrenceCount, 3)
        XCTAssertEqual(idempotent, reopened)

        let events = try store.events(limit: 10)
        XCTAssertEqual(events.map(\.type), [.opened, .repeated, .corrected, .reopened])
        XCTAssertEqual(events.count, 4)
        XCTAssertTrue(events.allSatisfy(\.developmentContinues))
        XCTAssertNil(events.first?.priorEventSHA256)
        XCTAssertEqual(events.dropFirst().map(\.priorEventSHA256), events.dropLast().map(\.eventSHA256))
    }

    func testSQLiteRejectsEventUpdateAndDelete() throws {
        let fixture = try Fixture()
        let store = try fixture.makeStore()
        _ = try store.record(fixture.candidate())

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(fixture.database.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        defer { sqlite3_close(handle) }

        var message: UnsafeMutablePointer<CChar>?
        XCTAssertNotEqual(
            sqlite3_exec(handle, "UPDATE stj_violation_events SET notice_state='changed';", nil, nil, &message),
            SQLITE_OK
        )
        XCTAssertTrue(message.map { String(cString: $0).contains("append-only") } ?? false)
        sqlite3_free(message)
        message = nil
        XCTAssertNotEqual(
            sqlite3_exec(handle, "DELETE FROM stj_violation_events;", nil, nil, &message),
            SQLITE_OK
        )
        XCTAssertTrue(message.map { String(cString: $0).contains("append-only") } ?? false)
        sqlite3_free(message)
        XCTAssertEqual(try store.events().count, 1)
    }

    func testReopenRepairsMirrorWithoutDuplicateEventIDs() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(at: fixture.jsonl, withIntermediateDirectories: true)
        var store: StjornarvaldPolicyLogStore? = try fixture.makeStore()
        let firstID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let secondID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        _ = try store?.record(fixture.candidate(), eventID: firstID)
        _ = try store?.record(fixture.candidate(), eventID: secondID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.jsonl.path))
        store = nil

        try FileManager.default.removeItem(at: fixture.jsonl)
        store = try fixture.makeStore()
        let lines = try String(contentsOf: fixture.jsonl, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let eventIDs = try lines.map { line -> String in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
            return try XCTUnwrap(object["event_id"] as? String)
        }
        XCTAssertEqual(Set(eventIDs), Set([firstID.uuidString.lowercased(), secondID.uuidString.lowercased()]))

        store = nil
        store = try fixture.makeStore()
        let reopenedLines = try String(contentsOf: fixture.jsonl, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(reopenedLines.count, 2)
    }

    func testOwnerOnlyLayoutDatabaseMirrorAndOutboxPermissions() throws {
        let fixture = try Fixture()
        let paths = AppPaths(home: fixture.root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureLayout()
        let store = try StjornarvaldPolicyLogStore(
            databaseURL: paths.stjornarvaldPolicyLogSQLite,
            jsonlURL: paths.stjornarvaldPolicyLogJSONL
        )
        _ = try store.record(fixture.candidate())

        XCTAssertEqual(try mode(paths.stjornarvaldDir), 0o700)
        XCTAssertEqual(try mode(paths.stjornarvaldOutboxDir), 0o700)
        XCTAssertEqual(try mode(paths.stjornarvaldPolicyLogSQLite), 0o600)
        XCTAssertEqual(try mode(paths.stjornarvaldPolicyLogJSONL), 0o600)
    }

    func testModelFacingFilesystemToolsCannotAccessPolicyState() throws {
        let fixture = try Fixture()
        let paths = AppPaths(home: fixture.root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureLayout()
        let config = ConfigStore(paths: paths)
        _ = try config.update(["allowed_roots": [fixture.root.path]], save: false)
        let authorization = ToolAuthorizationService(paths: paths, config: config)
        let context = ToolInvocationContext(
            projectID: ProjectID(),
            projectGeneration: .initial,
            clientID: ClientID("stjornarvald-protection-test"),
            authorizationScope: ToolAuthorizationScope(
                canonicalRoots: [fixture.root],
                writableRoots: [fixture.root],
                allowedTools: ["*"],
                networkAllowed: false,
                maximumInlineOutputBytes: 64 * 1_024
            )
        )
        let cases: [(String, [String: Any])] = [
            ("fs_read", ["path": paths.stjornarvaldPolicyLogJSONL.path]),
            ("fs_write", ["path": paths.stjornarvaldPolicyLogJSONL.path, "content": "forged"]),
            ("fs_delete", ["path": paths.home.path]),
            ("search_text", ["path": paths.stjornarvaldDir.path, "pattern": "violation"]),
        ]

        for (tool, arguments) in cases {
            let decision = authorization.authorize(
                tool: tool,
                arguments: arguments,
                context: context,
                clientID: context.clientID,
                binding: nil
            )
            guard case let .denied(code, _) = decision else {
                XCTFail("protected policy path was authorized for \(tool)")
                continue
            }
            XCTAssertEqual(code, "manager_policy_path_protected")
        }
    }

    func testFailForwardServiceUsesOutboxAndReconcilesIdempotently() throws {
        let fixture = try Fixture()
        let blocker = fixture.root.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blocker)
        let eventID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
        let diagnostics = DiagnosticRecorder()

        var service: StjornarvaldPolicyLogService? = StjornarvaldPolicyLogService(
            databaseURL: blocker.appendingPathComponent("policy.sqlite3"),
            jsonlURL: blocker.appendingPathComponent("policy.jsonl"),
            outboxURL: fixture.outbox,
            diagnostics: { message in diagnostics.append(message) }
        )
        XCTAssertEqual(
            service?.record(fixture.candidate(), eventID: eventID, occurredAt: Date(timeIntervalSince1970: 2)),
            .deferred(eventID: eventID)
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.outbox.path).count, 1)
        let outboxFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.outbox,
                includingPropertiesForKeys: nil
            ).first
        )
        XCTAssertEqual(try mode(outboxFile), 0o600)
        XCTAssertFalse(diagnostics.messages.isEmpty)
        XCTAssertFalse(StjornarvaldNonInterferenceContract.controlsToolAuthorization)
        XCTAssertFalse(StjornarvaldNonInterferenceContract.controlsRunAdmission)
        XCTAssertFalse(StjornarvaldNonInterferenceContract.controlsCompletion)
        service = nil

        service = StjornarvaldPolicyLogService(
            databaseURL: fixture.database,
            jsonlURL: fixture.jsonl,
            outboxURL: fixture.outbox
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.outbox.path).count, 0)
        let observer = try fixture.makeStore()
        XCTAssertEqual(try observer.events().map(\.id), [eventID])
    }

    func testFailForwardServiceBoundsEmergencyMemoryWhenAllDiskPathsFail() throws {
        let fixture = try Fixture()
        let blocker = fixture.root.appendingPathComponent("blocked")
        try Data("block".utf8).write(to: blocker)
        let service = StjornarvaldPolicyLogService(
            databaseURL: blocker.appendingPathComponent("policy.sqlite3"),
            jsonlURL: blocker.appendingPathComponent("policy.jsonl"),
            outboxURL: blocker.appendingPathComponent("outbox")
        )

        for index in 0..<40 {
            let suffix = String(format: "%012d", index)
            let eventID = try XCTUnwrap(UUID(uuidString: "60000000-0000-4000-8000-\(suffix)"))
            XCTAssertEqual(
                service.record(fixture.candidate(), eventID: eventID, occurredAt: Date()),
                .deferred(eventID: eventID)
            )
        }
        XCTAssertEqual(service.emergencyCount, 32)
    }

    func testUnsupportedSchemaFailsWithoutMutatingVersion() throws {
        let fixture = try Fixture()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database.path, &database), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                "CREATE TABLE stj_schema_meta(schema_version INTEGER NOT NULL,created_at TEXT NOT NULL,migrated_at TEXT NOT NULL);" +
                "INSERT INTO stj_schema_meta VALUES(99,'before','before');",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(handle)

        XCTAssertThrowsError(try fixture.makeStore())
        database = nil
        XCTAssertEqual(sqlite3_open_v2(fixture.database.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let readHandle = try XCTUnwrap(database)
        defer { sqlite3_close(readHandle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(readHandle, "SELECT schema_version FROM stj_schema_meta;", -1, &statement, nil), SQLITE_OK)
        let readStatement = try XCTUnwrap(statement)
        XCTAssertEqual(sqlite3_step(readStatement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(readStatement, 0), 99)
        sqlite3_finalize(readStatement)
        statement = nil
        XCTAssertEqual(
            sqlite3_prepare_v2(
                readHandle,
                "SELECT COUNT(*) FROM sqlite_master WHERE name='stj_violations';",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        let tableStatement = try XCTUnwrap(statement)
        defer { sqlite3_finalize(tableStatement) }
        XCTAssertEqual(sqlite3_step(tableStatement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(tableStatement, 0), 0)
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}

private final class DiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ message: String) {
        lock.lock()
        storage.append(message)
        lock.unlock()
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class Fixture {
    let root: URL
    let database: URL
    let jsonl: URL
    let outbox: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stjornarvald-tests-\(UUID().uuidString)", isDirectory: true)
        database = root.appendingPathComponent("policy-log.sqlite3")
        jsonl = root.appendingPathComponent("policy-violations.jsonl")
        outbox = root.appendingPathComponent("outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeStore() throws -> StjornarvaldPolicyLogStore {
        try StjornarvaldPolicyLogStore(databaseURL: database, jsonlURL: jsonl)
    }

    func candidate(summary: String = "Observed a disallowed runtime dependency.") -> PolicyViolationCandidate {
        PolicyViolationCandidate(
            rule: PolicyRule(
                id: PolicyRuleID("RFD-NATIVE-001"),
                source: PolicySourceReference(
                    sourceID: PolicySourceID(UUID(uuidString: "40000000-0000-4000-8000-000000000001")!),
                    revision: "ed0028a46bac9c5b92876a6ad6589ca421fd9499",
                    path: "Core/Native_Platform_Policy.md",
                    locator: "native-first"
                ),
                statement: "Use the native platform stack.",
                policyArea: "architecture",
                applicability: "macOS application",
                confidence: 0.99
            ),
            observationID: UUID(uuidString: "50000000-0000-4000-8000-000000000001")!,
            scope: DevelopmentObservationScope(
                projectID: "project-1",
                projectGeneration: 7,
                runID: "run-1",
                sessionID: "session-1",
                clientID: "client-1"
            ),
            subjectIdentity: "Sources/Feature.swift",
            summary: summary,
            evidenceReferences: ["tree:abc123"],
            explanation: "The dependency conflicts with the selected policy rule.",
            confidence: 0.95,
            suggestedCorrection: "Replace it with an Apple-native framework."
        )
    }
}

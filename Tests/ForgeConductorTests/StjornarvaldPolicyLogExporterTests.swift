import CryptoKit
import Foundation
import XCTest
@testable import ForgeConductorCore

final class StjornarvaldPolicyLogExporterTests: XCTestCase {
    func testAllFormatsCarryIdentityChronologyIntegrityAndRoundTrip() throws {
        let fixture = try makeFixture()
        let first = fixture.candidate(subject: "Sources/A.swift", summary: "First policy finding")
        let second = fixture.candidate(subject: "Sources/B.swift", summary: "Second policy finding")
        _ = try fixture.log.record(first, occurredAt: fixture.date(1))
        _ = try fixture.log.record(first, occurredAt: fixture.date(2))
        _ = try fixture.log.record(second, occurredAt: fixture.date(3))

        for format in StjornarvaldExportFormat.allCases {
            let requestID = UUID()
            let destination = fixture.destination(format.rawValue)
            let receipt = try fixture.exporter.export(
                requestID: requestID,
                format: format,
                destination: destination,
                now: fixture.date(10)
            )
            XCTAssertEqual(receipt.state, .completed)
            XCTAssertEqual(receipt.eventCount, 3)
            XCTAssertEqual(receipt.destination, destination.path)
            XCTAssertEqual(receipt.sha256, try fixture.sha256(destination))
            XCTAssertEqual(try fixture.mode(destination), 0o600)

            switch format {
            case .json:
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
                )
                XCTAssertEqual(object["schema_version"] as? String, "1.0.0")
                XCTAssertEqual(object["export_id"] as? String, requestID.uuidString)
                XCTAssertEqual((object["integrity"] as? [String: Any])?["event_count"] as? Int, 3)
                let events = try XCTUnwrap(object["events"] as? [[String: Any]])
                XCTAssertEqual(events.compactMap { $0["sequence"] as? Int }, [1, 2, 3])
                XCTAssertNotNil(object["policy_sources"])
                XCTAssertNotNil(object["limitations"])
            case .jsonl:
                let records = try String(contentsOf: destination, encoding: .utf8)
                    .split(separator: "\n")
                    .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
                XCTAssertEqual(records.first?["record_type"] as? String, "export")
                XCTAssertEqual(records.filter { $0["record_type"] as? String == "event" }.count, 3)
            case .markdown:
                let report = try String(contentsOf: destination, encoding: .utf8)
                XCTAssertTrue(report.contains("# Stjornarvald policy application report"))
                XCTAssertTrue(report.contains("Event count: 3"))
                XCTAssertTrue(report.contains("First policy finding"))
                XCTAssertTrue(report.contains("## Limitations"))
            case .csv:
                let lines = try String(contentsOf: destination, encoding: .utf8)
                    .split(whereSeparator: \.isNewline)
                XCTAssertEqual(lines.count, 5)
                XCTAssertTrue(lines[0].contains("\"event_sequence\""))
                XCTAssertTrue(lines[1].contains("\"export\""))
                XCTAssertEqual(lines.dropFirst(2).filter { $0.contains("\"event\"") }.count, 3)
            }
        }
        XCTAssertEqual(try fixture.log.events(limit: 10).count, 3)
    }

    func testCombinedFiltersSelectExactEventAndRecordLimits() throws {
        let fixture = try makeFixture()
        let selected = fixture.candidate(subject: "Sources/Selected.swift", summary: "Selected", confidence: 0.97)
        let other = fixture.candidate(
            subject: "Sources/Other.swift",
            summary: "Other",
            scope: DevelopmentObservationScope(
                projectID: "project-2",
                projectGeneration: 8,
                runID: "run-2",
                sessionID: "session-2",
                clientID: "client-2"
            ),
            confidence: 0.70
        )
        let projection = try fixture.log.record(selected, occurredAt: fixture.date(1))
        _ = try fixture.log.record(other, occurredAt: fixture.date(2))
        _ = try fixture.log.recordCorrection(
            violationID: projection.id,
            candidate: selected,
            occurredAt: fixture.date(3)
        )
        let filters = StjornarvaldExportFilters(
            projectID: "project-1",
            projectGeneration: 7,
            runID: "run-1",
            sessionID: "session-1",
            clientID: "client-1",
            startDate: fixture.date(3),
            endDate: fixture.date(3),
            ruleID: "RFD-NATIVE-001",
            state: .corrected,
            sourceID: fixture.sourceID,
            eventTypes: [.corrected],
            noticeState: "not_required",
            minimumConfidence: 0.9,
            maximumEvents: 10
        )
        let destination = fixture.destination("filtered.json")
        let receipt = try fixture.exporter.export(
            requestID: UUID(),
            format: .json,
            destination: destination,
            filters: filters
        )
        XCTAssertEqual(receipt.eventCount, 1)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
        )
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["type"] as? String, "violation_corrected")
        XCTAssertEqual((object["filters"] as? [String: Any])?["project_id"] as? String, "project-1")

        let defaults = try JSONDecoder().decode(
            StjornarvaldExportFilters.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(defaults.maximumEvents, StjornarvaldExportFilters.defaultMaximumEvents)
        XCTAssertThrowsError(try fixture.exporter.export(
            requestID: UUID(),
            format: .json,
            destination: fixture.destination("invalid.json"),
            filters: StjornarvaldExportFilters(startDate: fixture.date(4), endDate: fixture.date(3))
        ))
    }

    func testBoundedStressExportRecordsTruncationAndStreamsValidJSON() throws {
        let fixture = try makeFixture()
        let candidate = fixture.candidate(subject: "Sources/Stress.swift", summary: "Bounded stress")
        for index in 0..<1_025 {
            _ = try fixture.log.record(
                candidate,
                eventID: UUID(),
                occurredAt: fixture.date(index)
            )
        }
        let destination = fixture.destination("stress.json")
        let receipt = try fixture.exporter.export(
            requestID: UUID(),
            format: .json,
            destination: destination,
            filters: StjornarvaldExportFilters(maximumEvents: 1_000)
        )
        XCTAssertEqual(receipt.eventCount, 1_000)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
        )
        XCTAssertEqual((object["events"] as? [Any])?.count, 1_000)
        let limitations = try XCTUnwrap(object["limitations"] as? [String])
        XCTAssertTrue(limitations.contains { $0.contains("maximum_events=1000") })
        XCTAssertEqual(try fixture.log.events(after: 1_000, limit: 100).count, 25)
    }

    func testCancellationFailureAtomicReplacementAndDurableReplayLeaveLogIntact() throws {
        let fixture = try makeFixture()
        _ = try fixture.log.record(fixture.candidate(subject: "Sources/A.swift", summary: "Atomic"))
        let destination = fixture.destination("atomic.json")
        try Data("previous".utf8).write(to: destination)
        let cancelledID = UUID()
        XCTAssertThrowsError(try fixture.exporter.export(
            requestID: cancelledID,
            format: .json,
            destination: destination,
            shouldCancel: { true }
        )) { error in
            XCTAssertEqual(error as? StjornarvaldPolicyLogExportError, .cancelled)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "previous")

        let lateCancellation = ExportCancellationCounter(cancelAt: 7)
        XCTAssertThrowsError(try fixture.exporter.export(
            requestID: UUID(),
            format: .json,
            destination: destination,
            shouldCancel: { lateCancellation.shouldCancel() }
        )) { error in
            XCTAssertEqual(error as? StjornarvaldPolicyLogExportError, .cancelled)
        }
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "previous",
            "cancellation immediately before atomic rename must preserve the destination"
        )

        let missingParent = fixture.root.appendingPathComponent("missing/export.json")
        XCTAssertThrowsError(try fixture.exporter.export(
            requestID: UUID(),
            format: .json,
            destination: missingParent
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingParent.path))
        XCTAssertEqual(try fixture.log.events(limit: 10).count, 1)

        let requestID = UUID()
        let receipt = try fixture.exporter.export(
            requestID: requestID,
            format: .json,
            destination: destination,
            now: fixture.date(20)
        )
        XCTAssertNotEqual(try String(contentsOf: destination, encoding: .utf8), "previous")
        let replayExporter = StjornarvaldPolicyLogExporter(
            logStore: fixture.log,
            sourceCatalog: fixture.catalog,
            paths: fixture.paths
        )
        XCTAssertEqual(
            try replayExporter.export(
                requestID: requestID,
                format: .json,
                destination: destination,
                now: fixture.date(99)
            ),
            receipt
        )
        XCTAssertThrowsError(try replayExporter.export(
            requestID: requestID,
            format: .csv,
            destination: destination
        ))
        let temporaryFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .filter { $0.contains("forge-export") }
        XCTAssertTrue(temporaryFiles.isEmpty)
        XCTAssertEqual(try fixture.log.events(limit: 10).count, 1)
    }

    private func makeFixture() throws -> ExportFixture {
        let fixture = try ExportFixture()
        let root = fixture.root
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return fixture
    }
}

private final class ExportCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAt: Int
    private var count = 0

    init(cancelAt: Int) { self.cancelAt = cancelAt }

    func shouldCancel() -> Bool {
        lock.lock()
        count += 1
        let result = count >= cancelAt
        lock.unlock()
        return result
    }
}

private final class ExportFixture {
    let root: URL
    let paths: AppPaths
    let log: StjornarvaldPolicyLogStore
    let catalog: StjornarvaldPolicySourceCatalog
    let exporter: StjornarvaldPolicyLogExporter
    let sourceID = PolicySourceID(UUID(uuidString: "40000000-0000-4000-8000-000000000001")!)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stjornarvald-export-tests-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(home: root.appendingPathComponent("home", isDirectory: true))
        try paths.ensureLayout()
        log = try StjornarvaldPolicyLogStore(
            databaseURL: paths.stjornarvaldPolicyLogSQLite,
            jsonlURL: paths.stjornarvaldPolicyLogJSONL
        )
        catalog = try StjornarvaldPolicySourceCatalog(paths: paths)
        exporter = StjornarvaldPolicyLogExporter(logStore: log, sourceCatalog: catalog, paths: paths)
    }

    func date(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + Double(offset))
    }

    func destination(_ name: String) -> URL { root.appendingPathComponent(name) }

    func candidate(
        subject: String,
        summary: String,
        scope: DevelopmentObservationScope = DevelopmentObservationScope(
            projectID: "project-1",
            projectGeneration: 7,
            runID: "run-1",
            sessionID: "session-1",
            clientID: "client-1"
        ),
        confidence: Double = 0.95
    ) -> PolicyViolationCandidate {
        PolicyViolationCandidate(
            rule: PolicyRule(
                id: PolicyRuleID("RFD-NATIVE-001"),
                source: PolicySourceReference(
                    sourceID: sourceID,
                    revision: "ed0028a46bac9c5b92876a6ad6589ca421fd9499",
                    path: "Core/Native_Platform_Policy.md",
                    locator: "native-first"
                ),
                statement: "Use the native platform stack.",
                policyArea: "architecture",
                applicability: "macOS application",
                confidence: 0.99
            ),
            observationID: UUID(),
            scope: scope,
            subjectIdentity: subject,
            summary: summary,
            evidenceReferences: ["tree:abc123"],
            explanation: "The observation conflicts with the selected rule.",
            confidence: confidence,
            assumptions: ["The path is part of the shipping target."],
            alternatives: ["Use an Apple-native framework."],
            suggestedCorrection: "Replace the dependency."
        )
    }

    func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

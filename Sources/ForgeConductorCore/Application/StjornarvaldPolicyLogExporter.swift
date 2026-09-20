// StjornarvaldPolicyLogExporter.swift
// Streams bounded, filtered policy history into atomic user-owned exports.

import CryptoKit
import Darwin
import Foundation

public enum StjornarvaldPolicyLogExportError: Error, LocalizedError, Equatable {
    case invalidRequest(String)
    case unavailable(String)
    case cancelled
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail): "Invalid policy export request: \(detail)"
        case .unavailable(let detail): "Policy export is unavailable: \(detail)"
        case .cancelled: "Policy export was cancelled; the policy log is unchanged."
        case .writeFailed(let detail): "Policy export failed: \(detail)"
        }
    }
}

public final class StjornarvaldPolicyLogExporter: @unchecked Sendable {
    public static let pageSize = 256
    public static let maximumSources = 10_000

    private struct EventRange: Codable, Equatable {
        let firstSequence: Int64
        let lastSequence: Int64
    }

    private struct Integrity: Codable, Equatable {
        let eventCount: Int
        let lastEventSHA256: String?
        let outboxPending: Bool
    }

    private struct PolicySourceSummary: Codable, Equatable {
        let sourceID: String
        let origin: String
        let displayName: String
        let path: String?
        let revision: String?
        let active: Bool
        let interpretationState: String
        let repositoryURL: String?
    }

    private struct Header: Codable, Equatable {
        let schemaVersion: String
        let exportID: UUID
        let createdAt: Date
        let format: StjornarvaldExportFormat
        let policySources: [PolicySourceSummary]
        let filters: StjornarvaldExportFilters
        let eventRange: EventRange
        let integrity: Integrity
        let limitations: [String]
    }

    private struct JSONLHeader: Encodable {
        let recordType = "export"
        let export: Header
    }

    private struct JSONLSource: Encodable {
        let recordType = "policy_source"
        let policySource: PolicySourceSummary
    }

    private struct JSONLViolation: Encodable {
        let recordType = "violation"
        let violation: PolicyViolation
    }

    private struct JSONLEvent: Encodable {
        let recordType = "event"
        let event: PolicyViolationEvent
    }

    private struct Snapshot {
        let upperSequence: Int64
        let allowedViolationIDs: Set<PolicyViolationID>?
        let header: Header
        let violations: [PolicyViolation]
    }

    private struct StoredReceipt: Codable, Equatable {
        let format: StjornarvaldExportFormat
        let destination: String
        let filters: StjornarvaldExportFilters
        let receipt: StjornarvaldExportReceipt
    }

    private final class DigestingWriter {
        private var descriptor: Int32
        private var hasher = SHA256()
        private(set) var byteCount: Int64 = 0

        init(url: URL) throws {
            descriptor = Darwin.open(
                url.path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        deinit {
            if descriptor >= 0 { Darwin.close(descriptor) }
        }

        func write(_ data: Data) throws {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    guard count > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    offset += count
                }
            }
            hasher.update(data: data)
            byteCount += Int64(data.count)
        }

        func write(_ text: String) throws {
            guard let data = text.data(using: .utf8) else {
                throw StjornarvaldPolicyLogExportError.writeFailed("UTF-8 encoding failed")
            }
            try write(data)
        }

        func finish() throws -> String {
            guard descriptor >= 0 else {
                throw StjornarvaldPolicyLogExportError.writeFailed("writer is already closed")
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard Darwin.close(descriptor) == 0 else {
                descriptor = -1
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            descriptor = -1
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private let logStore: StjornarvaldPolicyLogStore
    private let sourceCatalog: StjornarvaldPolicySourceCatalog
    private let paths: AppPaths
    private let fileManager: FileManager
    private let exportLock = NSLock()
    private let lock = NSLock()
    private var receipts: [UUID: StoredReceipt] = [:]
    private var receiptOrder: [UUID] = []

    public init(
        logStore: StjornarvaldPolicyLogStore,
        sourceCatalog: StjornarvaldPolicySourceCatalog,
        paths: AppPaths,
        fileManager: FileManager = .default
    ) {
        self.logStore = logStore
        self.sourceCatalog = sourceCatalog
        self.paths = paths
        self.fileManager = fileManager
    }

    public func export(
        requestID: UUID,
        format: StjornarvaldExportFormat,
        destination requestedDestination: URL?,
        filters: StjornarvaldExportFilters = StjornarvaldExportFilters(),
        now: Date = Date(),
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> StjornarvaldExportReceipt {
        exportLock.lock()
        defer { exportLock.unlock() }
        try Self.validate(filters: filters)
        let destination = try resolvedDestination(
            requestedDestination,
            requestID: requestID,
            format: format
        )
        if let existing = try existingReceipt(requestID: requestID) {
            try validateReplay(
                existing,
                format: format,
                destination: destination,
                filters: filters
            )
            return existing.receipt
        }
        try checkCancellation(shouldCancel)
        let snapshot = try makeSnapshot(
            requestID: requestID,
            format: format,
            filters: filters,
            now: now,
            shouldCancel: shouldCancel
        )
        let staging = paths.stjornarvaldStagingDir.appendingPathComponent(
            ".policy-export-\(requestID.uuidString.lowercased()).tmp"
        )
        try? fileManager.removeItem(at: staging)
        defer { try? fileManager.removeItem(at: staging) }

        do {
            let writer = try DigestingWriter(url: staging)
            try write(
                format: format,
                snapshot: snapshot,
                filters: filters,
                writer: writer,
                shouldCancel: shouldCancel
            )
            let digest = try writer.finish()
            try installAtomically(
                staging: staging,
                destination: destination,
                shouldCancel: shouldCancel
            )
            let receipt = StjornarvaldExportReceipt(
                requestID: requestID,
                format: format,
                state: .completed,
                destination: destination.path,
                message: "Exported \(snapshot.header.integrity.eventCount) policy events.",
                createdAt: now,
                eventCount: snapshot.header.integrity.eventCount,
                byteCount: writer.byteCount,
                sha256: digest,
                controlsExecution: false
            )
            let stored = StoredReceipt(
                format: format,
                destination: destination.path,
                filters: filters,
                receipt: receipt
            )
            try persist(stored, requestID: requestID)
            retain(stored, requestID: requestID)
            return receipt
        } catch is CancellationError {
            throw StjornarvaldPolicyLogExportError.cancelled
        } catch let error as StjornarvaldPolicyLogExportError {
            throw error
        } catch {
            throw StjornarvaldPolicyLogExportError.writeFailed(error.localizedDescription)
        }
    }

    private func makeSnapshot(
        requestID: UUID,
        format: StjornarvaldExportFormat,
        filters: StjornarvaldExportFilters,
        now: Date,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> Snapshot {
        let upperSequence = try logStore.latestEventSequence()
        let allowedViolationIDs = try stateFilteredViolationIDs(filters.state)
        var cursor: Int64 = 0
        var count = 0
        var firstSequence: Int64 = 0
        var lastSequence: Int64 = 0
        var lastDigest: String?
        var violationIDs = Set<PolicyViolationID>()
        var truncated = false

        scan: while cursor < upperSequence {
            try checkCancellation(shouldCancel)
            let page = try logStore.events(after: cursor, limit: Self.pageSize)
            guard !page.isEmpty else { break }
            for event in page {
                if event.sequence > upperSequence { break scan }
                cursor = event.sequence
                guard matches(
                    event,
                    filters: filters,
                    allowedViolationIDs: allowedViolationIDs
                ) else { continue }
                if count == filters.maximumEvents {
                    truncated = true
                    break scan
                }
                if count == 0 { firstSequence = event.sequence }
                count += 1
                lastSequence = event.sequence
                lastDigest = event.eventSHA256
                violationIDs.insert(event.violationID)
            }
            if page.count < Self.pageSize { break }
        }

        var violations: [PolicyViolation] = []
        violations.reserveCapacity(violationIDs.count)
        for id in violationIDs {
            try checkCancellation(shouldCancel)
            if let violation = try logStore.violation(id: id) { violations.append(violation) }
        }
        violations.sort {
            if $0.firstObservedAt == $1.firstObservedAt {
                return $0.id.description < $1.id.description
            }
            return $0.firstObservedAt < $1.firstObservedAt
        }

        var sourceLimitations: [String] = []
        var sources = try sourceCatalog.sources(limit: Self.maximumSources)
        if let sourceID = filters.sourceID { sources = sources.filter { $0.id == sourceID } }
        if sources.count == Self.maximumSources {
            sourceLimitations.append("Policy source metadata reached the 10,000-source export bound.")
        }
        var sourceSummaries = sources.map(Self.sourceSummary)
        let governing = RavenForgeDevelopmentPolicyAdapter.identity
        if !sourceSummaries.contains(where: { $0.sourceID == governing.sourceID.description }) {
            sourceSummaries.insert(PolicySourceSummary(
                sourceID: governing.sourceID.description,
                origin: PolicySourceOrigin.builtInRavenForge.rawValue,
                displayName: governing.authority,
                path: nil,
                revision: governing.revision,
                active: true,
                interpretationState: PolicySourceInterpretationState.indexed.rawValue,
                repositoryURL: governing.repositoryURL
            ), at: 0)
        }

        var limitations = [
            "The export is a bounded snapshot through event sequence \(upperSequence).",
            "Presented notice state proves transport, not model comprehension or correction.",
            "The digest chain detects truncation or reordering; it is not external authorship proof.",
        ]
        limitations.append(contentsOf: sourceLimitations)
        if truncated {
            limitations.append(
                "Matching history exceeded maximum_events=\(filters.maximumEvents); later matching events are omitted."
            )
        }
        let header = Header(
            schemaVersion: "1.0.0",
            exportID: requestID,
            createdAt: now,
            format: format,
            policySources: sourceSummaries,
            filters: filters,
            eventRange: EventRange(
                firstSequence: firstSequence,
                lastSequence: lastSequence
            ),
            integrity: Integrity(
                eventCount: count,
                lastEventSHA256: lastDigest,
                outboxPending: outboxHasEntries()
            ),
            limitations: limitations
        )
        return Snapshot(
            upperSequence: upperSequence,
            allowedViolationIDs: allowedViolationIDs,
            header: header,
            violations: violations
        )
    }

    private func stateFilteredViolationIDs(
        _ state: PolicyViolationProjectionState?
    ) throws -> Set<PolicyViolationID>? {
        guard let state else { return nil }
        var result = Set<PolicyViolationID>()
        var cursor: Int64 = 0
        while true {
            let page = try logStore.violations(
                afterEventSequence: cursor,
                state: state,
                limit: 1_000
            )
            guard !page.isEmpty else { break }
            for entry in page {
                guard result.count < StjornarvaldExportFilters.absoluteMaximumEvents else {
                    throw StjornarvaldPolicyLogExportError.invalidRequest(
                        "state filter exceeds the 100,000-violation bound"
                    )
                }
                result.insert(entry.violation.id)
                cursor = entry.latestEventSequence
            }
            if page.count < 1_000 { break }
        }
        return result
    }

    private func write(
        format: StjornarvaldExportFormat,
        snapshot: Snapshot,
        filters: StjornarvaldExportFilters,
        writer: DigestingWriter,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        switch format {
        case .json:
            try writeJSON(snapshot, filters: filters, writer: writer, shouldCancel: shouldCancel)
        case .jsonl:
            try writeJSONL(snapshot, filters: filters, writer: writer, shouldCancel: shouldCancel)
        case .markdown:
            try writeMarkdown(snapshot, filters: filters, writer: writer, shouldCancel: shouldCancel)
        case .csv:
            try writeCSV(snapshot, filters: filters, writer: writer, shouldCancel: shouldCancel)
        }
    }

    private func writeJSON(
        _ snapshot: Snapshot,
        filters: StjornarvaldExportFilters,
        writer: DigestingWriter,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        let header = snapshot.header
        try writer.write("{")
        try writeJSONProperty("schema_version", value: header.schemaVersion, writer: writer)
        try writer.write(",")
        try writeJSONProperty("export_id", value: header.exportID, writer: writer)
        try writer.write(",")
        try writeJSONProperty("created_at", value: header.createdAt, writer: writer)
        try writer.write(",")
        try writeJSONProperty("format", value: header.format, writer: writer)
        try writer.write(",")
        try writeJSONProperty("policy_sources", value: header.policySources, writer: writer)
        try writer.write(",")
        try writeJSONProperty("filters", value: header.filters, writer: writer)
        try writer.write(",")
        try writeJSONProperty("event_range", value: header.eventRange, writer: writer)
        try writer.write(",")
        try writeJSONProperty("integrity", value: header.integrity, writer: writer)
        try writer.write(",")
        try writeJSONProperty("violations", value: snapshot.violations, writer: writer)
        try writer.write(",\"events\":[")
        var first = true
        try forEachMatchingEvent(snapshot: snapshot, filters: filters, shouldCancel: shouldCancel) { event in
            if !first { try writer.write(",") }
            first = false
            try writer.write(try Self.encode(event))
        }
        try writer.write("],")
        try writeJSONProperty("limitations", value: header.limitations, writer: writer)
        try writer.write("}\n")
    }

    private func writeJSONL(
        _ snapshot: Snapshot,
        filters: StjornarvaldExportFilters,
        writer: DigestingWriter,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        try writeLine(JSONLHeader(export: snapshot.header), writer: writer)
        for source in snapshot.header.policySources {
            try writeLine(JSONLSource(policySource: source), writer: writer)
        }
        for violation in snapshot.violations {
            try writeLine(JSONLViolation(violation: violation), writer: writer)
        }
        try forEachMatchingEvent(snapshot: snapshot, filters: filters, shouldCancel: shouldCancel) { event in
            try writeLine(JSONLEvent(event: event), writer: writer)
        }
    }

    private func writeMarkdown(
        _ snapshot: Snapshot,
        filters: StjornarvaldExportFilters,
        writer: DigestingWriter,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        let header = snapshot.header
        try writer.write("# Stjornarvald policy application report\n\n")
        try writer.write("## Export identity\n\n")
        try writer.write("- Export ID: `\(header.exportID.uuidString.lowercased())`\n")
        try writer.write("- Created: \(Self.iso8601String(header.createdAt))\n")
        try writer.write("- Format: \(header.format.rawValue)\n")
        try writer.write("- Event range: \(header.eventRange.firstSequence)…\(header.eventRange.lastSequence)\n")
        try writer.write("- Event count: \(header.integrity.eventCount)\n")
        try writer.write("- Last event SHA-256: \(header.integrity.lastEventSHA256 ?? "none")\n")
        try writer.write("- Pending outbox: \(header.integrity.outboxPending ? "yes" : "no")\n")
        try writer.write("- Filters: `\(Self.singleLineJSON(header.filters))`\n\n")
        try writer.write("## Policy sources and revisions\n\n")
        for source in header.policySources {
            try writer.write("- **\(Self.markdown(source.displayName))** — `\(source.sourceID)`; revision `\(source.revision ?? "pending")`; \(source.interpretationState)\n")
        }
        try writer.write("\n## Violations\n\n")
        if snapshot.violations.isEmpty { try writer.write("No matching violations.\n") }
        for violation in snapshot.violations {
            try writer.write("### \(Self.markdown(violation.latestSummary))\n\n")
            try writer.write("- ID: `\(violation.id.description)`\n")
            try writer.write("- Rule: `\(violation.ruleID.description)` at `\(violation.policyRevision)`\n")
            try writer.write("- State: \(violation.state.rawValue)\n")
            try writer.write("- Occurrences: \(violation.occurrenceCount)\n")
            try writer.write("- Suggested correction: \(Self.markdown(violation.latestSuggestedCorrection))\n\n")
        }
        try writer.write("## Chronological occurrence history\n\n")
        try forEachMatchingEvent(snapshot: snapshot, filters: filters, shouldCancel: shouldCancel) { event in
            try writer.write("- \(Self.iso8601String(event.occurredAt)) — **\(event.type.rawValue)** — `\(event.violationID.description)` — \(Self.markdown(event.candidate.summary)) — delivery `\(Self.markdown(event.noticeState))`\n")
        }
        try writer.write("\n## Limitations\n\n")
        for limitation in header.limitations {
            try writer.write("- \(Self.markdown(limitation))\n")
        }
    }

    private func writeCSV(
        _ snapshot: Snapshot,
        filters: StjornarvaldExportFilters,
        writer: DigestingWriter,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        let header = snapshot.header
        let columns = [
            "record_type", "schema_version", "export_id", "created_at", "format",
            "filters_json", "first_sequence", "last_sequence", "event_count",
            "last_event_sha256", "outbox_pending", "violation_id", "event_sequence",
            "event_type", "occurred_at", "project_id", "project_generation", "run_id",
            "session_id", "client_id", "rule_id", "policy_revision", "source_id",
            "source_path", "source_locator", "projection_state", "summary",
            "explanation", "confidence", "suggested_correction", "notice_state",
            "evidence_references_json", "assumptions_json", "alternatives_json",
            "limitations_json",
        ]
        try writer.write(columns.map(Self.csv).joined(separator: ",") + "\r\n")
        let metadata = [
            "export", header.schemaVersion, header.exportID.uuidString.lowercased(),
            Self.iso8601String(header.createdAt), header.format.rawValue,
            Self.singleLineJSON(header.filters), "\(header.eventRange.firstSequence)",
            "\(header.eventRange.lastSequence)", "\(header.integrity.eventCount)",
            header.integrity.lastEventSHA256 ?? "", header.integrity.outboxPending ? "true" : "false",
        ] + Array(repeating: "", count: 23) + [Self.singleLineJSON(header.limitations)]
        try writer.write(metadata.map(Self.csv).joined(separator: ",") + "\r\n")
        let states = Dictionary(uniqueKeysWithValues: snapshot.violations.map { ($0.id, $0.state.rawValue) })
        try forEachMatchingEvent(snapshot: snapshot, filters: filters, shouldCancel: shouldCancel) { event in
            let scope = event.candidate.scope
            let row = ["event"] + Array(repeating: "", count: 10) + [
                event.violationID.description, "\(event.sequence)", event.type.rawValue,
                Self.iso8601String(event.occurredAt), scope.projectID ?? "",
                scope.projectGeneration.map(String.init) ?? "", scope.runID ?? "",
                scope.sessionID ?? "", scope.clientID ?? "", event.candidate.rule.id.description,
                event.candidate.rule.source.revision,
                event.candidate.rule.source.sourceID.description,
                event.candidate.rule.source.path, event.candidate.rule.source.locator,
                states[event.violationID] ?? "", event.candidate.summary,
                event.candidate.explanation, String(event.candidate.confidence),
                event.candidate.suggestedCorrection, event.noticeState,
                Self.singleLineJSON(event.candidate.evidenceReferences),
                Self.singleLineJSON(event.candidate.assumptions),
                Self.singleLineJSON(event.candidate.alternatives), "",
            ]
            try writer.write(row.map(Self.csv).joined(separator: ",") + "\r\n")
        }
    }

    private func forEachMatchingEvent(
        snapshot: Snapshot,
        filters: StjornarvaldExportFilters,
        shouldCancel: @escaping @Sendable () -> Bool,
        body: (PolicyViolationEvent) throws -> Void
    ) throws {
        var cursor: Int64 = 0
        var count = 0
        scan: while cursor < snapshot.upperSequence && count < filters.maximumEvents {
            try checkCancellation(shouldCancel)
            let page = try logStore.events(after: cursor, limit: Self.pageSize)
            guard !page.isEmpty else { break }
            for event in page {
                if event.sequence > snapshot.upperSequence { break scan }
                cursor = event.sequence
                guard matches(
                    event,
                    filters: filters,
                    allowedViolationIDs: snapshot.allowedViolationIDs
                ) else { continue }
                try body(event)
                count += 1
                if count == filters.maximumEvents { break scan }
            }
            if page.count < Self.pageSize { break }
        }
    }

    private func matches(
        _ event: PolicyViolationEvent,
        filters: StjornarvaldExportFilters,
        allowedViolationIDs: Set<PolicyViolationID>?
    ) -> Bool {
        let scope = event.candidate.scope
        if let allowedViolationIDs, !allowedViolationIDs.contains(event.violationID) { return false }
        if let value = filters.projectID, scope.projectID != value { return false }
        if let value = filters.projectGeneration, scope.projectGeneration != value { return false }
        if let value = filters.runID, scope.runID != value { return false }
        if let value = filters.sessionID, scope.sessionID != value { return false }
        if let value = filters.clientID, scope.clientID != value { return false }
        if let value = filters.startDate, event.occurredAt < value { return false }
        if let value = filters.endDate, event.occurredAt > value { return false }
        if let value = filters.ruleID, event.candidate.rule.id.description != value { return false }
        if let value = filters.sourceID, event.candidate.rule.source.sourceID != value { return false }
        if let values = filters.eventTypes, !values.contains(event.type) { return false }
        if let value = filters.noticeState, event.noticeState != value { return false }
        if let value = filters.minimumConfidence, event.candidate.confidence < value { return false }
        return true
    }

    private func installAtomically(
        staging: URL,
        destination: URL,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw StjornarvaldPolicyLogExportError.invalidRequest(
                "destination parent does not exist"
            )
        }
        let localStaging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).forge-export-\(UUID().uuidString.lowercased()).tmp"
        )
        defer { try? fileManager.removeItem(at: localStaging) }
        let source = Darwin.open(staging.path, O_RDONLY | O_NOFOLLOW)
        guard source >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(source) }
        let target = Darwin.open(
            localStaging.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard target >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var targetOpen = true
        defer { if targetOpen { Darwin.close(target) } }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try checkCancellation(shouldCancel)
            let readCount = Darwin.read(source, &buffer, buffer.count)
            guard readCount >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if readCount == 0 { break }
            var offset = 0
            while offset < readCount {
                let writeCount = buffer.withUnsafeBytes { rawBuffer in
                    Darwin.write(target, rawBuffer.baseAddress!.advanced(by: offset), readCount - offset)
                }
                guard writeCount > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += writeCount
            }
        }
        guard Darwin.fsync(target) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.close(target) == 0 else {
            targetOpen = false
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        targetOpen = false
        try checkCancellation(shouldCancel)
        guard Darwin.rename(localStaging.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let directory = Darwin.open(parent.path, O_RDONLY)
        if directory >= 0 {
            _ = Darwin.fsync(directory)
            Darwin.close(directory)
        }
    }

    private func resolvedDestination(
        _ requested: URL?,
        requestID: UUID,
        format: StjornarvaldExportFormat
    ) throws -> URL {
        let destination = (requested ?? paths.stjornarvaldExportsDir.appendingPathComponent(
            "stjornarvald-\(requestID.uuidString.lowercased()).\(Self.fileExtension(format))"
        )).standardizedFileURL
        guard destination.isFileURL,
              destination.path.utf8.count <= 4_096,
              (destination.path as NSString).isAbsolutePath,
              !destination.lastPathComponent.isEmpty else {
            throw StjornarvaldPolicyLogExportError.invalidRequest(
                "destination must be a bounded absolute file path"
            )
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw StjornarvaldPolicyLogExportError.invalidRequest(
                "destination must not be a directory"
            )
        }
        return destination
    }

    private func outboxHasEntries() -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: paths.stjornarvaldOutboxDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return true }
        var inspected = 0
        for case let url as URL in enumerator {
            inspected += 1
            if inspected > 10_000 { return true }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return true
            }
        }
        return false
    }

    private func existingReceipt(requestID: UUID) throws -> StoredReceipt? {
        lock.lock()
        let cached = receipts[requestID]
        lock.unlock()
        if let cached { return cached }

        let url = receiptURL(requestID: requestID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let stored = try JSONDecoder().decode(StoredReceipt.self, from: Data(contentsOf: url))
            retain(stored, requestID: requestID)
            return stored
        } catch {
            throw StjornarvaldPolicyLogExportError.writeFailed(
                "stored receipt for request_id is unreadable"
            )
        }
    }

    private func retain(_ stored: StoredReceipt, requestID: UUID) {
        lock.lock()
        receipts[requestID] = stored
        receiptOrder.append(requestID)
        if receiptOrder.count > 256 {
            let expired = receiptOrder.removeFirst()
            receipts.removeValue(forKey: expired)
        }
        lock.unlock()
    }

    private func validateReplay(
        _ existing: StoredReceipt,
        format: StjornarvaldExportFormat,
        destination: URL,
        filters: StjornarvaldExportFilters
    ) throws {
        guard existing.format == format,
              existing.destination == destination.path,
              existing.filters == filters else {
            throw StjornarvaldPolicyLogExportError.invalidRequest(
                "request_id was already used for a different export"
            )
        }
    }

    private func receiptURL(requestID: UUID) -> URL {
        paths.stjornarvaldExportsDir.appendingPathComponent(
            ".receipt-\(requestID.uuidString.lowercased()).json"
        )
    }

    private func persist(_ stored: StoredReceipt, requestID: UUID) throws {
        let url = receiptURL(requestID: requestID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(stored).write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw StjornarvaldPolicyLogExportError.writeFailed(
                "could not persist export receipt: \(error.localizedDescription)"
            )
        }
    }

    private func writeJSONProperty<T: Encodable>(
        _ name: String,
        value: T,
        writer: DigestingWriter
    ) throws {
        try writer.write(try Self.encode(name))
        try writer.write(":")
        try writer.write(try Self.encode(value))
    }

    private func writeLine<T: Encodable>(_ value: T, writer: DigestingWriter) throws {
        try writer.write(try Self.encode(value))
        try writer.write("\n")
    }

    private func checkCancellation(_ shouldCancel: () -> Bool) throws {
        if shouldCancel() { throw StjornarvaldPolicyLogExportError.cancelled }
    }

    private static func validate(filters: StjornarvaldExportFilters) throws {
        let strings = [
            filters.projectID, filters.runID, filters.sessionID, filters.clientID,
            filters.ruleID, filters.noticeState,
        ]
        guard strings.allSatisfy({ $0.map { !$0.isEmpty && $0.utf8.count <= 1_024 } ?? true }),
              filters.projectGeneration.map({ $0 > 0 }) ?? true,
              filters.minimumConfidence.map({ (0...1).contains($0) }) ?? true,
              (1...StjornarvaldExportFilters.absoluteMaximumEvents).contains(filters.maximumEvents),
              filters.startDate.map({ start in filters.endDate.map { start <= $0 } ?? true }) ?? true,
              filters.eventTypes.map({ !$0.isEmpty && $0.count <= PolicyViolationEventType.allCases.count }) ?? true else {
            throw StjornarvaldPolicyLogExportError.invalidRequest(
                "filters or limits are outside supported bounds"
            )
        }
    }

    private static func sourceSummary(_ source: DevelopmentPolicySource) -> PolicySourceSummary {
        PolicySourceSummary(
            sourceID: source.id.description,
            origin: source.origin.rawValue,
            displayName: source.displayName,
            path: source.selectedPath,
            revision: source.latestRevisionID?.description,
            active: source.active,
            interpretationState: source.interpretationState.rawValue,
            repositoryURL: nil
        )
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private static func singleLineJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? encode(value), let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }

    private static func csv(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func markdown(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private static func fileExtension(_ format: StjornarvaldExportFormat) -> String {
        switch format {
        case .jsonl: "jsonl"
        case .json: "json"
        case .markdown: "md"
        case .csv: "csv"
        }
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

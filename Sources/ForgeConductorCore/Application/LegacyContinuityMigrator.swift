// LegacyContinuityMigrator.swift
// Inventories global handoffs and imports only records with exact project evidence.

import Foundation
import Darwin

public final class LegacyContinuityMigrator: @unchecked Sendable {
    public static let maximumCandidateCount = 128

    private let repository: ProjectMemoryRepository
    private let redactor = ProjectMemoryRedactor()

    public init(repository: ProjectMemoryRepository) {
        self.repository = repository
    }

    public func migrate(
        candidateFiles: [URL],
        expectedProjectGeneration: UInt64,
        boundRunID: String?
    ) throws -> LegacyContinuityMigrationReceipt {
        try migrateCandidates(candidateFiles: candidateFiles,
            expectedProjectGeneration: expectedProjectGeneration, boundRunID: boundRunID,
            reader: nil)
    }

    /// Registration holds the project transition fence. Inventory only the
    /// application's legacy directory, without following links or global pointers.
    /// An oversized inventory fails before any migration commit; it is never
    /// reported as a complete migration of an arbitrary prefix.
    func migrateDirectory(
        _ directory: URL,
        expectedProjectGeneration: UInt64
    ) throws -> LegacyContinuityMigrationReceipt? {
        let root = directory.standardizedFileURL
        guard root.resolvingSymlinksInPath() == root else {
            throw ProjectMemoryError.migrationFailed("legacy continuity directory is linked")
        }
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw ProjectMemoryError.migrationFailed("legacy continuity directory could not be opened")
        }
        guard let stream = fdopendir(descriptor) else {
            _ = Darwin.close(descriptor)
            throw ProjectMemoryError.migrationFailed("legacy continuity directory could not be inventoried")
        }
        defer { closedir(stream) }
        var candidates: [URL] = []
        var visited = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else {
                    throw ProjectMemoryError.migrationFailed("legacy continuity inventory was interrupted")
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            visited += 1
            // Permit the JSON/Markdown/pointer companions without allowing an
            // unbounded scan of unrelated directory entries.
            guard visited <= Self.maximumCandidateCount * 4 else {
                throw ProjectMemoryError.migrationFailed("legacy continuity inventory exceeds the bounded registration scan")
            }
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { continue }
            candidates.append(root.appendingPathComponent(name))
            guard candidates.count <= Self.maximumCandidateCount else {
                throw ProjectMemoryError.migrationFailed("legacy continuity candidate count exceeds the registration limit")
            }
        }
        guard !candidates.isEmpty else { return nil }
        return try migrateCandidates(candidateFiles: candidates,
            expectedProjectGeneration: expectedProjectGeneration, boundRunID: nil) { candidate in
                let file = Darwin.openat(descriptor, candidate.lastPathComponent,
                    O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard file >= 0 else {
                    throw ProjectMemoryError.migrationFailed("legacy candidate could not be opened without following links")
                }
                defer { _ = Darwin.close(file) }
                var metadata = stat()
                guard fstat(file, &metadata) == 0,
                      metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_nlink == 1, metadata.st_uid == geteuid() else {
                    throw ProjectMemoryError.migrationFailed("legacy candidate is not an owned regular file without hard links")
                }
                let maximum = ContinuityHandoffV2.maximumEncodedBytes
                guard metadata.st_size > 0, metadata.st_size <= maximum else {
                    throw ProjectMemoryError.payloadTooLarge("legacy continuity file is empty or oversized")
                }
                let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
                // Read from the descriptor relative to the pinned directory;
                // replacing a pathname cannot redirect this read elsewhere.
                return try handle.read(upToCount: maximum + 1) ?? Data()
            }
    }

    private func migrateCandidates(
        candidateFiles: [URL],
        expectedProjectGeneration: UInt64,
        boundRunID: String?,
        reader: ((URL) throws -> Data)?
    ) throws -> LegacyContinuityMigrationReceipt {
        guard expectedProjectGeneration > 0, expectedProjectGeneration <= UInt64(Int64.max) else {
            throw ProjectMemoryError.invalidRequest("expected project generation is invalid")
        }
        if let boundRunID, UUID(uuidString: boundRunID) == nil {
            throw ProjectMemoryError.invalidRequest("bound run identifier must be a UUID")
        }
        let startedAt = ISO8601.string(from: Date())
        let candidates = Array(
            Dictionary(grouping: candidateFiles.map(\.standardizedFileURL), by: \.path)
                .keys.sorted().prefix(Self.maximumCandidateCount)
                .map { URL(fileURLWithPath: $0) }
        )
        var candidateIdentities: [LegacyContinuityCandidateIdentity] = []
        var actions: [LegacyContinuityMigrationAction] = []
        candidateIdentities.reserveCapacity(candidates.count)
        actions.reserveCapacity(candidates.count)

        for candidate in candidates {
            var candidateIdentity = LegacyContinuityCandidateIdentity(
                pathSHA256: JSONSupport.sha256Hex(candidate.path),
                contentState: "unreadable_or_invalid",
                sourceSHA256: nil
            )
            let action: LegacyContinuityMigrationAction
            do {
                action = try classify(
                    candidate,
                    expectedProjectGeneration: expectedProjectGeneration,
                    boundRunID: boundRunID,
                    identity: &candidateIdentity,
                    reader: reader
                )
            } catch {
                let envelope: [String: Any] = [
                    "schema_version": "legacy-quarantine-1",
                    "source_name": candidate.lastPathComponent,
                    "reason": String(error.localizedDescription.prefix(1_024)),
                ]
                action = .quarantine(
                    try LegacyContinuityQuarantineWrite(
                        payload: envelope,
                        sourcePath: candidate.path,
                        reason: "legacy candidate could not be validated",
                        receiptSourceSHA256: nil
                    )
                )
            }
            candidateIdentities.append(candidateIdentity)
            actions.append(action)
        }

        let batch = try LegacyContinuityMigrationBatch(
            startedAt: startedAt,
            submittedCandidateCount: candidateFiles.count,
            expectedProjectGeneration: expectedProjectGeneration,
            boundRunID: boundRunID,
            identities: candidateIdentities,
            actions: actions
        )
        return try repository.continuityApplyLegacyMigration(batch)
    }

    private func classify(
        _ candidate: URL,
        expectedProjectGeneration: UInt64,
        boundRunID: String?,
        identity: inout LegacyContinuityCandidateIdentity,
        reader: ((URL) throws -> Data)?
    ) throws -> LegacyContinuityMigrationAction {
        if reader == nil {
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                identity.contentState = "not_regular"
                return .skip
            }
            guard let fileSize = values.fileSize,
                  fileSize > 0,
                  fileSize <= ContinuityHandoffV2.maximumEncodedBytes else {
                identity.contentState = "empty_or_oversized"
                throw ProjectMemoryError.payloadTooLarge(
                    "legacy continuity file is empty or oversized"
                )
            }
        }
        let data = try reader?(candidate) ?? boundedCandidateData(candidate)
        guard !data.isEmpty, data.count <= ContinuityHandoffV2.maximumEncodedBytes else {
            identity.contentState = "empty_or_oversized"
            throw ProjectMemoryError.payloadTooLarge(
                "legacy continuity file is empty or oversized"
            )
        }
        let sourceSHA256 = JSONSupport.sha256Hex(data)
        identity.contentState = "read"
        identity.sourceSHA256 = sourceSHA256
        let object = try JSONSupport.object(from: data)
        let sanitized: [String: Any]
        do {
            sanitized = try sanitize(object)
        } catch {
            return .quarantine(
                try LegacyContinuityQuarantineWrite(
                    payload: [
                        "schema_version": "legacy-quarantine-1",
                        "source_sha256": sourceSHA256,
                        "reason": "sensitive content could not be safely retained",
                    ],
                    sourcePath: candidate.path,
                    reason: "sensitive legacy payload",
                    receiptSourceSHA256: sourceSHA256
                )
            )
        }
        guard try JSONSupport.canonicalJSON(sanitized) == JSONSupport.canonicalJSON(object) else {
            return .quarantine(
                try LegacyContinuityQuarantineWrite(
                    payload: sanitized,
                    sourcePath: candidate.path,
                    reason: "legacy payload required redaction",
                    receiptSourceSHA256: sourceSHA256
                )
            )
        }

        if let handoff = ContinuityHandoffV2.fromDictionary(object) {
            guard handoff.projectID == repository.projectID,
                  handoff.projectGeneration == expectedProjectGeneration,
                  let boundRunID,
                  handoff.runID == boundRunID else {
                return .quarantine(
                    try LegacyContinuityQuarantineWrite(
                        payload: object,
                        sourcePath: candidate.path,
                        reason: "V2 legacy location lacks an exact current project/run binding",
                        receiptSourceSHA256: sourceSHA256
                    )
                )
            }
            return .importReadOnly(
                try LegacyContinuityImportWrite(
                    payload: handoff.asDictionary(),
                    handoffID: handoff.handoffID,
                    operationID: handoff.operationID,
                    schemaVersion: ContinuityHandoffV2.schemaVersion,
                    contentSHA256: handoff.contentSHA256,
                    createdAt: handoff.createdAt,
                    projectGeneration: expectedProjectGeneration,
                    runID: boundRunID,
                    predecessorProviderResponseID: handoff.predecessorSession[
                        "provider_response_id"
                    ] as? String,
                    bootstrapNonce: handoff.bootstrapNonce,
                    sourceRecordID: candidate.lastPathComponent,
                    sourcePath: candidate.path,
                    receiptSourceSHA256: sourceSHA256
                )
            )
        }

        if let handoff = ContinuityHandoff.fromDictionary(object),
           handoff.project["project_id"] as? String == repository.projectID,
           handoff.redactionComplete,
           handoff.contentSHA256 == handoff.calculatedSHA256() {
            return .importReadOnly(
                try LegacyContinuityImportWrite(
                    payload: handoff.asDictionary(),
                    handoffID: handoff.handoffID,
                    operationID: handoff.operationID,
                    schemaVersion: ContinuityHandoff.schemaVersion,
                    contentSHA256: handoff.contentSHA256,
                    createdAt: handoff.createdAt,
                    projectGeneration: nil,
                    runID: nil,
                    predecessorProviderResponseID: nil,
                    bootstrapNonce: nil,
                    sourceRecordID: candidate.lastPathComponent,
                    sourcePath: candidate.path,
                    receiptSourceSHA256: sourceSHA256
                )
            )
        }

        return .quarantine(
            try LegacyContinuityQuarantineWrite(
                payload: object,
                sourcePath: candidate.path,
                reason: "legacy project identity or integrity is ambiguous",
                receiptSourceSHA256: sourceSHA256
            )
        )
    }

    private func boundedCandidateData(_ candidate: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: candidate)
        defer { try? handle.close() }
        let maximum = ContinuityHandoffV2.maximumEncodedBytes
        var result = Data()
        result.reserveCapacity(min(maximum + 1, 16 * 1_024))
        while result.count <= maximum {
            let remaining = maximum + 1 - result.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                break
            }
            result.append(chunk)
        }
        return result
    }

    private func sanitize(_ object: [String: Any]) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in object {
            result[key] = try sanitize(value)
        }
        return result
    }

    private func sanitize(_ value: Any) throws -> Any {
        if let string = value as? String {
            return try redactor.redact(string) ?? string
        }
        if let dictionary = value as? [String: Any] {
            return try sanitize(dictionary)
        }
        if let array = value as? [Any] {
            return try array.map(sanitize)
        }
        return value
    }
}

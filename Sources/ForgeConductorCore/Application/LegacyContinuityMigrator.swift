// LegacyContinuityMigrator.swift
// Inventories global handoffs and imports only records with exact project evidence.

import Foundation

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
        var imported = 0
        var skipped = max(0, candidateFiles.count - candidates.count)
        var quarantined = 0
        var importedHashes: [String] = []
        var quarantineHashes: [String] = []

        for candidate in candidates {
            do {
                let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else {
                    skipped += 1
                    continue
                }
                guard let fileSize = values.fileSize,
                      fileSize > 0,
                      fileSize <= ContinuityHandoffV2.maximumEncodedBytes else {
                    throw ProjectMemoryError.payloadTooLarge("legacy continuity file is empty or oversized")
                }
                let data = try Data(contentsOf: candidate, options: [.mappedIfSafe])
                let sourceSHA256 = JSONSupport.sha256Hex(data)
                let object = try JSONSupport.object(from: data)
                let sanitized: [String: Any]
                do {
                    sanitized = try sanitize(object)
                } catch {
                    let envelope: [String: Any] = [
                        "schema_version": "legacy-quarantine-1",
                        "source_sha256": sourceSHA256,
                        "reason": "sensitive content could not be safely retained",
                    ]
                    _ = try repository.continuityQuarantineLegacy(
                        payload: envelope,
                        sourcePath: candidate.path,
                        reason: "sensitive legacy payload"
                    )
                    quarantined += 1
                    quarantineHashes.append(sourceSHA256)
                    continue
                }
                guard try JSONSupport.canonicalJSON(sanitized) == JSONSupport.canonicalJSON(object) else {
                    _ = try repository.continuityQuarantineLegacy(
                        payload: sanitized,
                        sourcePath: candidate.path,
                        reason: "legacy payload required redaction"
                    )
                    quarantined += 1
                    quarantineHashes.append(sourceSHA256)
                    continue
                }

                if let handoff = ContinuityHandoffV2.fromDictionary(object) {
                    guard handoff.projectID == repository.projectID,
                          handoff.projectGeneration == expectedProjectGeneration,
                          let boundRunID,
                          handoff.runID == boundRunID else {
                        _ = try repository.continuityQuarantineLegacy(
                            payload: object,
                            sourcePath: candidate.path,
                            reason: "V2 legacy location lacks an exact current project/run binding"
                        )
                        quarantined += 1
                        quarantineHashes.append(sourceSHA256)
                        continue
                    }
                    let didImport = try repository.continuityImportLegacyReadOnly(
                        payload: handoff.asDictionary(),
                        handoffID: handoff.handoffID,
                        operationID: handoff.operationID,
                        schemaVersion: ContinuityHandoffV2.schemaVersion,
                        contentSHA256: handoff.contentSHA256,
                        createdAt: handoff.createdAt,
                        projectGeneration: expectedProjectGeneration,
                        runID: boundRunID,
                        predecessorProviderResponseID: handoff.predecessorSession["provider_response_id"] as? String,
                        bootstrapNonce: handoff.bootstrapNonce,
                        sourceRecordID: candidate.lastPathComponent
                    )
                    if didImport { imported += 1; importedHashes.append(sourceSHA256) }
                    else { skipped += 1 }
                    continue
                }

                if let handoff = ContinuityHandoff.fromDictionary(object),
                   handoff.project["project_id"] as? String == repository.projectID,
                   handoff.redactionComplete,
                   handoff.contentSHA256 == handoff.calculatedSHA256() {
                    let didImport = try repository.continuityImportLegacyReadOnly(
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
                        sourceRecordID: candidate.lastPathComponent
                    )
                    if didImport { imported += 1; importedHashes.append(sourceSHA256) }
                    else { skipped += 1 }
                    continue
                }

                _ = try repository.continuityQuarantineLegacy(
                    payload: object,
                    sourcePath: candidate.path,
                    reason: "legacy project identity or integrity is ambiguous"
                )
                quarantined += 1
                quarantineHashes.append(sourceSHA256)
            } catch {
                let envelope: [String: Any] = [
                    "schema_version": "legacy-quarantine-1",
                    "source_name": candidate.lastPathComponent,
                    "reason": String(error.localizedDescription.prefix(1_024)),
                ]
                _ = try repository.continuityQuarantineLegacy(
                    payload: envelope,
                    sourcePath: candidate.path,
                    reason: "legacy candidate could not be validated"
                )
                quarantined += 1
            }
        }

        return try repository.continuityRecordLegacyMigration(
            importedCount: imported,
            skippedCount: skipped,
            quarantinedCount: quarantined,
            startedAt: startedAt,
            details: [
                "candidate_count": candidates.count,
                "imported_source_sha256": Array(importedHashes.prefix(Self.maximumCandidateCount)),
                "quarantined_source_sha256": Array(quarantineHashes.prefix(Self.maximumCandidateCount)),
                "global_latest_used_as_authority": false,
            ]
        )
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

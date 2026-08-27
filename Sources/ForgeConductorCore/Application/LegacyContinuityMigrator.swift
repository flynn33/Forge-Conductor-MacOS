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
                    identity: &candidateIdentity
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
        identity: inout LegacyContinuityCandidateIdentity
    ) throws -> LegacyContinuityMigrationAction {
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
        let data = try boundedCandidateData(candidate)
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

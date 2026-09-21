// ProjectInstructionQueue.swift
// Durable project-scoped instruction package ingestion, ordering, and run linkage.

import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(Vision)
import Vision
#endif

public enum ProjectInstructionPackageState: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case completed
    case blocked
    case failed
    case cancelled

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

public struct ProjectInstructionPackage: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let packageID: String
    public let version: String
    public let displayName: String
    public let mission: String
    public let sourcePath: String
    public let contentSHA256: String
    public let allowedTools: [String]
    public let completionGates: [String]
    public let documentCount: Int?
    public let instructionByteCount: Int?
    public let unresolvedDocumentCount: Int?
    public var position: Int
    public var state: ProjectInstructionPackageState
    public var runID: RunID?
    public var lastError: String?
    public let createdAt: String
    public var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case packageID = "package_id"
        case version
        case displayName = "display_name"
        case mission
        case sourcePath = "source_path"
        case contentSHA256 = "content_sha256"
        case allowedTools = "allowed_tools"
        case completionGates = "completion_gates"
        case documentCount = "document_count"
        case instructionByteCount = "instruction_byte_count"
        case unresolvedDocumentCount = "unresolved_document_count"
        case position, state
        case runID = "run_id"
        case lastError = "last_error"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    fileprivate var importReadyMetadataAvailable: Bool {
        guard let documentCount, let instructionByteCount,
              let unresolvedDocumentCount else { return false }
        return (1...ProjectInstructionQueueStore.maximumSourceFiles).contains(documentCount)
            && (0...ProjectInstructionQueueStore.maximumAggregateBytes).contains(instructionByteCount)
            && (0...documentCount).contains(unresolvedDocumentCount)
    }

    public func asDictionary(
        completedStepCount: Int? = nil,
        totalStepCount: Int? = nil
    ) -> [String: Any] {
        [
            "id": id.uuidString.lowercased(),
            "project_id": projectID.description,
            "project_generation": projectGeneration.rawValue,
            "package_id": packageID,
            "version": version,
            "display_name": displayName,
            "mission": mission,
            "source_path": sourcePath,
            "content_sha256": contentSHA256,
            "allowed_tools": allowedTools,
            "completion_gates": completionGates,
            "document_count": documentCount as Any,
            "instruction_byte_count": instructionByteCount as Any,
            "unresolved_document_count": unresolvedDocumentCount as Any,
            "import_ready": unresolvedDocumentCount.map { $0 == 0 } as Any,
            "completed_step_count": completedStepCount as Any,
            "total_step_count": totalStepCount ?? documentCount as Any,
            "position": position,
            "state": state.rawValue,
            "run_id": runID?.description as Any,
            "last_error": lastError as Any,
            "created_at": createdAt,
            "updated_at": updatedAt,
        ].compactNSNull()
    }
}

public struct ProjectInstructionQueueSnapshot: Codable, Sendable, Equatable {
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let revision: UInt64
    public let running: Bool
    public let totalPackages: Int
    public let cursor: Int
    public let nextCursor: Int?
    public let packages: [ProjectInstructionPackage]

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case revision, running
        case totalPackages = "total_packages"
        case cursor
        case nextCursor = "next_cursor"
        case packages
    }

    public func asDictionary() -> [String: Any] {
        [
            "ok": true,
            "project_id": projectID.description,
            "project_generation": projectGeneration.rawValue,
            "revision": revision,
            "running": running,
            "total_packages": totalPackages,
            "cursor": cursor,
            "next_cursor": nextCursor as Any,
            "packages": packages.map { $0.asDictionary() },
        ].compactNSNull()
    }
}

public struct ProjectRunInstructionArtifact: Codable, Sendable, Equatable {
    public let runID: RunID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let mission: String
    public let sourcePath: String
    public let contentSHA256: String
    public let documentCount: Int
    public let instructionByteCount: Int
    public let unresolvedDocumentCount: Int
    public let createdAt: String

    public init(
        runID: RunID,
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        mission: String,
        sourcePath: String,
        contentSHA256: String,
        documentCount: Int,
        instructionByteCount: Int,
        unresolvedDocumentCount: Int,
        createdAt: String
    ) {
        self.runID = runID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.mission = mission
        self.sourcePath = sourcePath
        self.contentSHA256 = contentSHA256
        self.documentCount = documentCount
        self.instructionByteCount = instructionByteCount
        self.unresolvedDocumentCount = unresolvedDocumentCount
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case mission
        case sourcePath = "source_path"
        case contentSHA256 = "content_sha256"
        case documentCount = "document_count"
        case instructionByteCount = "instruction_byte_count"
        case unresolvedDocumentCount = "unresolved_document_count"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let runValue = try values.decode(String.self, forKey: .runID)
        let projectValue = try values.decode(String.self, forKey: .projectID)
        guard let runUUID = UUID(uuidString: runValue),
              let projectUUID = UUID(uuidString: projectValue) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Run instruction artifact identities must be UUID strings."
                )
            )
        }
        runID = RunID(runUUID)
        projectID = ProjectID(projectUUID)
        projectGeneration = ProjectGeneration(
            try values.decode(UInt64.self, forKey: .projectGeneration)
        )
        mission = try values.decode(String.self, forKey: .mission)
        sourcePath = try values.decode(String.self, forKey: .sourcePath)
        contentSHA256 = try values.decode(String.self, forKey: .contentSHA256)
        documentCount = try values.decode(Int.self, forKey: .documentCount)
        instructionByteCount = try values.decode(Int.self, forKey: .instructionByteCount)
        unresolvedDocumentCount = try values.decode(Int.self, forKey: .unresolvedDocumentCount)
        createdAt = try values.decode(String.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(runID.description, forKey: .runID)
        try values.encode(projectID.description, forKey: .projectID)
        try values.encode(projectGeneration.rawValue, forKey: .projectGeneration)
        try values.encode(mission, forKey: .mission)
        try values.encode(sourcePath, forKey: .sourcePath)
        try values.encode(contentSHA256, forKey: .contentSHA256)
        try values.encode(documentCount, forKey: .documentCount)
        try values.encode(instructionByteCount, forKey: .instructionByteCount)
        try values.encode(unresolvedDocumentCount, forKey: .unresolvedDocumentCount)
        try values.encode(createdAt, forKey: .createdAt)
    }

    public func asDictionary() -> [String: Any] {
        [
            "ok": true,
            "run_id": runID.description,
            "project_id": projectID.description,
            "project_generation": projectGeneration.rawValue,
            "mission": mission,
            "source_path": sourcePath,
            "content_sha256": contentSHA256,
            "document_count": documentCount,
            "instruction_byte_count": instructionByteCount,
            "unresolved_document_count": unresolvedDocumentCount,
            "import_ready": unresolvedDocumentCount == 0,
            "created_at": createdAt,
        ]
    }
}

public struct InstructionDeliveryByteRange: Codable, Sendable, Equatable {
    public let lowerBound: Int
    public let upperBound: Int

    public init(lowerBound: Int, upperBound: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    enum CodingKeys: String, CodingKey {
        case lowerBound = "lower_bound"
        case upperBound = "upper_bound"
    }

    fileprivate func asDictionary() -> [String: Any] {
        ["lower_bound": lowerBound, "upper_bound": upperBound]
    }
}

public struct InstructionDocumentDeliveryProgress: Codable, Sendable, Equatable {
    public let documentID: String
    public let canonicalSHA256: String
    public let totalBytes: Int
    public let deliveredRanges: [InstructionDeliveryByteRange]
    public let nextByteOffset: Int?

    enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case canonicalSHA256 = "canonical_sha256"
        case totalBytes = "total_bytes"
        case deliveredRanges = "delivered_ranges"
        case nextByteOffset = "next_byte_offset"
    }

    fileprivate func asDictionary() -> [String: Any] {
        [
            "document_id": documentID,
            "canonical_sha256": canonicalSHA256,
            "total_bytes": totalBytes,
            "delivered_ranges": deliveredRanges.map { $0.asDictionary() },
            "next_byte_offset": nextByteOffset as Any,
        ].compactNSNull()
    }
}

public struct InstructionArtifactDeliveryProgress: Codable, Sendable, Equatable {
    public let artifactSHA256: String
    public let totalDocuments: Int?
    public let catalogDeliveredRanges: [InstructionDeliveryByteRange]
    public let nextCatalogCursor: Int?
    public let completedDocumentBitmap: Data
    public let documents: [InstructionDocumentDeliveryProgress]

    enum CodingKeys: String, CodingKey {
        case artifactSHA256 = "artifact_sha256"
        case totalDocuments = "total_documents"
        case catalogDeliveredRanges = "catalog_delivered_ranges"
        case nextCatalogCursor = "next_catalog_cursor"
        case completedDocumentBitmap = "completed_document_bitmap"
        case documents
    }

    fileprivate func asDictionary() -> [String: Any] {
        [
            "artifact_sha256": artifactSHA256,
            "total_documents": totalDocuments as Any,
            "catalog_delivered_ranges": catalogDeliveredRanges.map { $0.asDictionary() },
            "next_catalog_cursor": nextCatalogCursor as Any,
            "completed_document_bitmap": completedDocumentBitmap.base64EncodedString(),
            "documents": documents.map { $0.asDictionary() },
        ].compactNSNull()
    }
}

/// A bounded aggregate derived only from accepted, integrity-checked tool
/// results. It is copied into a managed handoff; the durable invocation journal
/// remains the sole delivery authority.
public struct InstructionDeliveryProgress: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public static let maximumEvidenceRecords = 65_536
    public static let maximumRangesPerItem = 32
    public static let maximumPartialDocuments = 64

    public let schemaVersion: Int
    public let runID: RunID
    public let projectID: ProjectID
    public let projectGeneration: ProjectGeneration
    public let artifacts: [InstructionArtifactDeliveryProgress]
    public let acknowledgedRequirements: [String]
    public let evidenceRecordCount: Int

    public init(
        runID: RunID,
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        artifactSHA256: [String]
    ) throws {
        guard artifactSHA256.count <= ProjectInstructionQueueStore.maximumRunArtifactInputs,
              Set(artifactSHA256).count == artifactSHA256.count,
              artifactSHA256.allSatisfy(Self.isSHA256) else {
            throw ProjectInstructionQueueError.invalidRequest(
                "Instruction delivery artifact identities are invalid or oversized."
            )
        }
        schemaVersion = Self.schemaVersion
        self.runID = runID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        artifacts = artifactSHA256.sorted().map {
            InstructionArtifactDeliveryProgress(
                artifactSHA256: $0,
                totalDocuments: nil,
                catalogDeliveredRanges: [],
                nextCatalogCursor: 0,
                completedDocumentBitmap: Data(),
                documents: []
            )
        }
        acknowledgedRequirements = []
        evidenceRecordCount = 0
    }

    private init(
        runID: RunID,
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        artifacts: [InstructionArtifactDeliveryProgress],
        acknowledgedRequirements: [String],
        evidenceRecordCount: Int
    ) {
        schemaVersion = Self.schemaVersion
        self.runID = runID
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.artifacts = artifacts
        self.acknowledgedRequirements = acknowledgedRequirements
        self.evidenceRecordCount = evidenceRecordCount
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case artifacts
        case acknowledgedRequirements = "acknowledged_requirements"
        case evidenceRecordCount = "evidence_record_count"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard decodedSchemaVersion == Self.schemaVersion,
              let runUUID = UUID(uuidString: try values.decode(String.self, forKey: .runID)),
              let projectUUID = UUID(uuidString: try values.decode(String.self, forKey: .projectID)) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Instruction delivery identity is invalid.")
            )
        }
        schemaVersion = decodedSchemaVersion
        runID = RunID(runUUID)
        projectID = ProjectID(projectUUID)
        projectGeneration = ProjectGeneration(
            try values.decode(UInt64.self, forKey: .projectGeneration)
        )
        artifacts = try values.decode([InstructionArtifactDeliveryProgress].self, forKey: .artifacts)
        acknowledgedRequirements = try values.decode(
            [String].self,
            forKey: .acknowledgedRequirements
        )
        evidenceRecordCount = try values.decode(Int.self, forKey: .evidenceRecordCount)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.schemaVersion, forKey: .schemaVersion)
        try values.encode(runID.description, forKey: .runID)
        try values.encode(projectID.description, forKey: .projectID)
        try values.encode(projectGeneration.rawValue, forKey: .projectGeneration)
        try values.encode(artifacts, forKey: .artifacts)
        try values.encode(acknowledgedRequirements, forKey: .acknowledgedRequirements)
        try values.encode(evidenceRecordCount, forKey: .evidenceRecordCount)
    }

    public func validated() throws -> InstructionDeliveryProgress {
        try validate()
        return self
    }

    public func asDictionary() -> [String: Any] {
        [
            "schema_version": Self.schemaVersion,
            "run_id": runID.description,
            "project_id": projectID.description,
            "project_generation": projectGeneration.rawValue,
            "artifacts": artifacts.map { $0.asDictionary() },
            "acknowledged_requirements": acknowledgedRequirements,
            "evidence_record_count": evidenceRecordCount,
        ]
    }

    mutating func record(_ invocation: ToolInvocationRecord) throws {
        guard invocation.runID == runID,
              invocation.projectID == projectID,
              invocation.projectGeneration == projectGeneration else {
            throw ProjectInstructionQueueError.invalidRequest(
                "Instruction delivery evidence belongs to another run."
            )
        }
        guard invocation.state == .completed,
              invocation.toolName == "instruction_catalog"
                || invocation.toolName == "instruction_read" else { return }
        guard evidenceRecordCount < Self.maximumEvidenceRecords else {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction delivery evidence exceeds its bounded history"
            )
        }
        guard let summary = invocation.resultSummary,
              let resultSHA256 = invocation.resultSHA256,
              JSONSupport.sha256Hex(Data(summary.utf8)) == resultSHA256,
              let result = try JSONSerialization.jsonObject(
                with: Data(summary.utf8)
              ) as? [String: Any],
              let ok = result["ok"] as? Bool,
              let isError = result["is_error"] as? Bool,
              let payload = result["payload"] as? [String: Any] else {
            throw ProjectInstructionQueueError.storageFailure(
                "accepted instruction delivery evidence has no valid durable result"
            )
        }
        guard ok, !isError else { return }
        let artifactSHA256 = payload["snapshot_sha256"] as? String
            ?? (invocation.toolName == "instruction_read" && artifacts.count == 1
                ? artifacts[0].artifactSHA256 : nil)
        guard
              let artifactSHA256,
              let artifactIndex = artifacts.firstIndex(where: {
                $0.artifactSHA256 == artifactSHA256
              }) else {
            throw ProjectInstructionQueueError.storageFailure(
                "accepted instruction delivery evidence is invalid or outside the run artifact set"
            )
        }
        var updatedArtifacts = artifacts
        var artifact = updatedArtifacts[artifactIndex]
        if invocation.toolName == "instruction_catalog" {
            artifact = try Self.recordCatalog(payload, in: artifact)
        } else {
            artifact = try Self.recordDocument(payload, in: artifact)
        }
        updatedArtifacts[artifactIndex] = artifact
        self = InstructionDeliveryProgress(
            runID: runID,
            projectID: projectID,
            projectGeneration: projectGeneration,
            artifacts: updatedArtifacts,
            acknowledgedRequirements: acknowledgedRequirements,
            evidenceRecordCount: evidenceRecordCount + 1
        )
    }

    private func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              projectGeneration.rawValue > 0,
              artifacts.count <= ProjectInstructionQueueStore.maximumRunArtifactInputs,
              Set(artifacts.map(\.artifactSHA256)).count == artifacts.count,
              artifacts.allSatisfy({ Self.isSHA256($0.artifactSHA256) }),
              acknowledgedRequirements.count <= ContinuityHandoffV2.maximumListItems,
              acknowledgedRequirements.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 }),
              (0...Self.maximumEvidenceRecords).contains(evidenceRecordCount) else {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction delivery progress is invalid or oversized"
            )
        }
        for artifact in artifacts {
            guard artifact.totalDocuments.map({
                (0...ProjectInstructionQueueStore.maximumSourceFiles).contains($0)
            }) ?? true,
            artifact.catalogDeliveredRanges.count <= Self.maximumRangesPerItem,
            artifact.completedDocumentBitmap.count
                <= (ProjectInstructionQueueStore.maximumSourceFiles + 7) / 8,
            artifact.documents.count <= Self.maximumPartialDocuments,
            Set(artifact.documents.map(\.documentID)).count == artifact.documents.count else {
                throw ProjectInstructionQueueError.storageFailure(
                    "instruction artifact delivery progress is invalid or oversized"
                )
            }
            try Self.validateRanges(
                artifact.catalogDeliveredRanges,
                upperLimit: artifact.totalDocuments
            )
            try Self.validateCompletedDocumentBitmap(
                artifact.completedDocumentBitmap,
                totalDocuments: artifact.totalDocuments
            )
            for document in artifact.documents {
                guard !document.documentID.isEmpty,
                      document.documentID.utf8.count <= 512,
                      Self.isSHA256(document.canonicalSHA256),
                      (0...ProjectInstructionQueueStore.maximumSourceFileBytes)
                        .contains(document.totalBytes),
                      document.deliveredRanges.count <= Self.maximumRangesPerItem else {
                    throw ProjectInstructionQueueError.storageFailure(
                        "instruction document delivery progress is invalid or oversized"
                    )
                }
                try Self.validateRanges(
                    document.deliveredRanges,
                    upperLimit: document.totalBytes
                )
            }
        }
    }

    private static func recordCatalog(
        _ payload: [String: Any],
        in artifact: InstructionArtifactDeliveryProgress
    ) throws -> InstructionArtifactDeliveryProgress {
        guard let total = integer(payload["total_documents"]),
              let cursor = integer(payload["cursor"]),
              let documents = payload["documents"] as? [[String: Any]],
              (0...ProjectInstructionQueueStore.maximumSourceFiles).contains(total),
              cursor >= 0,
              cursor <= total,
              documents.count <= 128,
              cursor <= total - documents.count else {
            throw ProjectInstructionQueueError.storageFailure(
                "accepted instruction catalog evidence is invalid"
            )
        }
        if let priorTotal = artifact.totalDocuments, priorTotal != total {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction catalog size changed for an immutable artifact"
            )
        }
        let ranges = if documents.isEmpty {
            artifact.catalogDeliveredRanges
        } else {
            try merged(
                artifact.catalogDeliveredRanges,
                adding: InstructionDeliveryByteRange(
                    lowerBound: cursor,
                    upperBound: cursor + documents.count
                ),
                upperLimit: total
            )
        }
        return InstructionArtifactDeliveryProgress(
            artifactSHA256: artifact.artifactSHA256,
            totalDocuments: total,
            catalogDeliveredRanges: ranges,
            nextCatalogCursor: firstGap(in: ranges, upperLimit: total),
            completedDocumentBitmap: artifact.completedDocumentBitmap,
            documents: artifact.documents
        )
    }

    private static func recordDocument(
        _ payload: [String: Any],
        in artifact: InstructionArtifactDeliveryProgress
    ) throws -> InstructionArtifactDeliveryProgress {
        guard let documentID = payload["document_id"] as? String,
              let sha256 = payload["sha256"] as? String,
              let offset = integer(payload["byte_offset"]),
              let total = integer(payload["total_bytes"]),
              let content = payload["content"] as? String,
              !documentID.isEmpty,
              documentID.utf8.count <= 512,
              isSHA256(sha256),
              (0...ProjectInstructionQueueStore.maximumSourceFileBytes).contains(total),
              offset >= 0,
              offset <= total,
              content.utf8.count <= total - offset else {
            throw ProjectInstructionQueueError.storageFailure(
                "accepted instruction document evidence is invalid"
            )
        }
        let upperBound = offset + content.utf8.count
        var documents = artifact.documents
        var completedDocumentBitmap = artifact.completedDocumentBitmap
        let ordinal = try documentOrdinal(documentID)
        if let ordinal, isDocumentComplete(ordinal, bitmap: completedDocumentBitmap) {
            return artifact
        }
        let existing = documents.firstIndex { $0.documentID == documentID }
        let ranges: [InstructionDeliveryByteRange]
        if let existing {
            let prior = documents[existing]
            guard prior.canonicalSHA256 == sha256, prior.totalBytes == total else {
                throw ProjectInstructionQueueError.storageFailure(
                    "instruction document identity changed for an immutable artifact"
                )
            }
            ranges = if upperBound == offset {
                prior.deliveredRanges
            } else {
                try merged(
                    prior.deliveredRanges,
                    adding: InstructionDeliveryByteRange(
                        lowerBound: offset,
                        upperBound: upperBound
                    ),
                    upperLimit: total
                )
            }
        } else {
            guard documents.count < Self.maximumPartialDocuments else {
                throw ProjectInstructionQueueError.storageFailure(
                    "instruction delivery document coverage is oversized"
                )
            }
            ranges = if upperBound == offset {
                []
            } else {
                try merged(
                    [],
                    adding: InstructionDeliveryByteRange(
                        lowerBound: offset,
                        upperBound: upperBound
                    ),
                    upperLimit: total
                )
            }
        }
        let nextByteOffset = firstGap(in: ranges, upperLimit: total)
        if nextByteOffset == nil, let ordinal {
            completedDocumentBitmap = try settingDocumentComplete(
                ordinal,
                bitmap: completedDocumentBitmap
            )
            documents.removeAll { $0.documentID == documentID }
        } else {
            let progress = InstructionDocumentDeliveryProgress(
                documentID: documentID,
                canonicalSHA256: sha256,
                totalBytes: total,
                deliveredRanges: ranges,
                nextByteOffset: nextByteOffset
            )
            if let existing {
                documents[existing] = progress
            } else {
                documents.append(progress)
            }
        }
        return InstructionArtifactDeliveryProgress(
            artifactSHA256: artifact.artifactSHA256,
            totalDocuments: artifact.totalDocuments,
            catalogDeliveredRanges: artifact.catalogDeliveredRanges,
            nextCatalogCursor: artifact.nextCatalogCursor,
            completedDocumentBitmap: completedDocumentBitmap,
            documents: documents.sorted { $0.documentID < $1.documentID }
        )
    }

    private static func documentOrdinal(_ documentID: String) throws -> Int? {
        let prefix = "document-"
        guard documentID.hasPrefix(prefix) else { return nil }
        let suffix = documentID.dropFirst(prefix.count)
        guard suffix.count == 6,
              suffix.allSatisfy({ $0.isNumber }),
              let oneBased = Int(suffix),
              (1...ProjectInstructionQueueStore.maximumSourceFiles).contains(oneBased) else {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction document identifier is invalid"
            )
        }
        return oneBased - 1
    }

    private static func isDocumentComplete(_ ordinal: Int, bitmap: Data) -> Bool {
        let byteIndex = ordinal / 8
        guard byteIndex < bitmap.count else { return false }
        return bitmap[byteIndex] & UInt8(1 << (ordinal % 8)) != 0
    }

    private static func settingDocumentComplete(
        _ ordinal: Int,
        bitmap: Data
    ) throws -> Data {
        let maximumBytes = (ProjectInstructionQueueStore.maximumSourceFiles + 7) / 8
        let byteIndex = ordinal / 8
        guard byteIndex < maximumBytes else {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction document coverage is oversized"
            )
        }
        var updated = bitmap
        if updated.count <= byteIndex {
            updated.append(contentsOf: repeatElement(0, count: byteIndex + 1 - updated.count))
        }
        updated[byteIndex] |= UInt8(1 << (ordinal % 8))
        return updated
    }

    private static func validateCompletedDocumentBitmap(
        _ bitmap: Data,
        totalDocuments: Int?
    ) throws {
        let upperLimit = totalDocuments ?? ProjectInstructionQueueStore.maximumSourceFiles
        guard bitmap.count <= (upperLimit + 7) / 8 else {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction completed-document coverage is invalid"
            )
        }
        if upperLimit % 8 != 0, let last = bitmap.last {
            let validMask = UInt8((1 << (upperLimit % 8)) - 1)
            guard last & ~validMask == 0 else {
                throw ProjectInstructionQueueError.storageFailure(
                    "instruction completed-document coverage exceeds the catalog"
                )
            }
        }
    }

    private static func merged(
        _ existing: [InstructionDeliveryByteRange],
        adding added: InstructionDeliveryByteRange,
        upperLimit: Int
    ) throws -> [InstructionDeliveryByteRange] {
        guard added.lowerBound >= 0,
              added.lowerBound <= added.upperBound,
              added.upperBound <= upperLimit else {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction delivery range is invalid"
            )
        }
        var result: [InstructionDeliveryByteRange] = []
        for range in (existing + [added]).sorted(by: {
            $0.lowerBound == $1.lowerBound
                ? $0.upperBound < $1.upperBound : $0.lowerBound < $1.lowerBound
        }) {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                result[result.count - 1] = InstructionDeliveryByteRange(
                    lowerBound: last.lowerBound,
                    upperBound: max(last.upperBound, range.upperBound)
                )
            } else {
                result.append(range)
            }
        }
        guard result.count <= Self.maximumRangesPerItem else {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction delivery range coverage is oversized"
            )
        }
        return result
    }

    private static func validateRanges(
        _ ranges: [InstructionDeliveryByteRange],
        upperLimit: Int?
    ) throws {
        var priorUpper = -1
        for range in ranges {
            guard range.lowerBound >= 0,
                  range.lowerBound < range.upperBound,
                  range.lowerBound > priorUpper,
                  upperLimit.map({ range.upperBound <= $0 }) ?? true else {
                throw ProjectInstructionQueueError.storageFailure(
                    "instruction delivery range coverage is invalid"
                )
            }
            priorUpper = range.upperBound
        }
    }

    private static func firstGap(
        in ranges: [InstructionDeliveryByteRange],
        upperLimit: Int
    ) -> Int? {
        var cursor = 0
        for range in ranges {
            guard range.lowerBound <= cursor else { break }
            cursor = max(cursor, range.upperBound)
        }
        return cursor < upperLimit ? cursor : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public enum ProjectInstructionQueueError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(String)
    case sourceUnavailable
    case sourceTypeUnsupported
    case sourceContainsLink
    case manifestInvalid(String)
    case packageNotFound(UUID)
    case activePackage(UUID)
    case staleRevision(expected: UInt64, actual: UInt64)
    case staleProjectGeneration
    case queueAlreadyRunning
    case queueNotRunning
    case queueBlocked(String)
    case storageFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail): detail
        case .sourceUnavailable: "The selected instruction package is unavailable."
        case .sourceTypeUnsupported:
            "Select a Markdown or text file, a JSON .forgepackage manifest, or a folder containing instruction documents."
        case .sourceContainsLink: "Instruction packages cannot contain symbolic links."
        case .manifestInvalid(let detail): "The instruction package manifest is invalid: \(detail)"
        case .packageNotFound: "The instruction package no longer exists in this project queue."
        case .activePackage: "A running instruction package cannot be reordered or removed."
        case .staleRevision(let expected, let actual):
            "The instruction queue changed (expected revision \(expected), current revision \(actual)). Refresh and retry."
        case .staleProjectGeneration: "The instruction queue belongs to a different project generation."
        case .queueAlreadyRunning: "The instruction queue is already running."
        case .queueNotRunning: "The instruction queue is not running."
        case .queueBlocked(let detail): detail
        case .storageFailure(let detail): "Instruction package storage failed: \(detail)"
        }
    }
}

/// File-backed queue ownership is intentionally separate from the control-plane database.
/// The lock bounds all mutations, and every accepted source becomes a content-addressed,
/// owner-only snapshot before the queue record is published atomically.
public final class ProjectInstructionQueueStore: @unchecked Sendable {
    public static let schemaVersion = 3
    private static let catalogSchemaVersion = 2
    public static let builtInCompletionGate = "forge.package.tool-success"
    public static let maximumPackages = 4_096
    public static let maximumRunArtifacts = 4_096
    public static let maximumRunArtifactInputs = 64
    public static let maximumSourceFiles = 4_096
    public static let maximumSourceFileBytes = 128 * 1_048_576
    public static let maximumAggregateBytes = 512 * 1_048_576
    /// Bounds only the compact run bootstrap carried in queue/run metadata.
    /// Authoritative instruction content is artifact-backed and is governed by
    /// the source-file and aggregate import budgets instead.
    public static let maximumBootstrapSummaryBytes = 32_768
    public static let maximumQueueStateBytes = 64 * 1_048_576
    public static let maximumDeliveryBytes = 64 * 1_024

    private struct PersistedState: Codable {
        var schemaVersion: Int
        var revision: UInt64
        var runningProjects: [String]
        var packages: [ProjectInstructionPackage]
        var runArtifacts: [ProjectRunInstructionArtifact]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case revision
            case runningProjects = "running_projects"
            case packages
            case runArtifacts = "run_artifacts"
        }

        init(
            schemaVersion: Int,
            revision: UInt64,
            runningProjects: [String],
            packages: [ProjectInstructionPackage],
            runArtifacts: [ProjectRunInstructionArtifact]
        ) {
            self.schemaVersion = schemaVersion
            self.revision = revision
            self.runningProjects = runningProjects
            self.packages = packages
            self.runArtifacts = runArtifacts
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            revision = try values.decode(UInt64.self, forKey: .revision)
            runningProjects = try values.decode([String].self, forKey: .runningProjects)
            packages = try values.decode([ProjectInstructionPackage].self, forKey: .packages)
            runArtifacts = try values.decodeIfPresent(
                [ProjectRunInstructionArtifact].self,
                forKey: .runArtifacts
            ) ?? []
        }

        static let empty = PersistedState(
            schemaVersion: ProjectInstructionQueueStore.schemaVersion,
            revision: 0,
            runningProjects: [],
            packages: [],
            runArtifacts: []
        )
    }

    private struct PackageManifest: Decodable {
        struct Gate: Decodable {
            let gateID: String
            enum CodingKeys: String, CodingKey { case gateID = "gate_id" }
        }

        let schemaVersion: Int
        let packageID: String
        let version: String
        let mission: String
        let projectID: String?
        let entryDocuments: [String]
        let requestedCapabilities: [String]
        let completionGateStrings: [String]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case packageID = "package_id"
            case version, mission
            case projectID = "project_id"
            case entryDocuments = "entry_documents"
            case requestedCapabilities = "requested_capabilities"
            case completionGates = "completion_gates"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            packageID = try values.decode(String.self, forKey: .packageID)
            version = try values.decode(String.self, forKey: .version)
            mission = try values.decode(String.self, forKey: .mission)
            projectID = try values.decodeIfPresent(String.self, forKey: .projectID)
            entryDocuments = try values.decode([String].self, forKey: .entryDocuments)
            requestedCapabilities = try values.decode([String].self, forKey: .requestedCapabilities)
            if let gates = try? values.decode([String].self, forKey: .completionGates) {
                completionGateStrings = gates
            } else {
                completionGateStrings = try values.decode([Gate].self, forKey: .completionGates).map(\.gateID)
            }
        }
    }

    private struct IngestedPackage {
        let packageID: String
        let version: String
        let displayName: String
        let mission: String
        let sourcePath: String
        let digest: String
        let allowedTools: [String]
        let completionGates: [String]
        let documents: [IngestedDocument]
        let instructionByteCount: Int
        let unresolvedDocumentCount: Int
    }

    private struct IngestedDocument {
        let path: String
        let original: Data
        let canonicalText: String?
        let encoding: String?
        let converter: String
        let status: InstructionDocumentStatus
        let detail: String
    }

    public enum InstructionDocumentStatus: String, Codable, Sendable {
        case convertedInstruction = "converted_instruction"
        case retainedAttachment = "retained_attachment"
        case unrepresentedVisualStructural = "unrepresented_visual_structural"
        case unresolvedConversion = "unresolved_conversion"
    }

    private struct StoredDocument: Codable {
        let id: String
        let sourcePath: String
        let originalReference: String
        let originalByteCount: Int
        let originalSHA256: String
        let canonicalReference: String?
        let canonicalByteCount: Int?
        let canonicalSHA256: String?
        let encoding: String?
        let converter: String
        let status: InstructionDocumentStatus
        let detail: String

        enum CodingKeys: String, CodingKey {
            case id
            case sourcePath = "source_path"
            case originalReference = "original_reference"
            case originalByteCount = "original_byte_count"
            case originalSHA256 = "original_sha256"
            case canonicalReference = "canonical_reference"
            case canonicalByteCount = "canonical_byte_count"
            case canonicalSHA256 = "canonical_sha256"
            case encoding, converter, status, detail
        }
    }

    private struct StoredCatalog: Codable {
        let schemaVersion: Int
        let contentSHA256: String
        let documents: [StoredDocument]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case contentSHA256 = "content_sha256"
            case documents
        }
    }

    public struct InstructionCatalogPage: Sendable, Equatable {
        public let contentSHA256: String
        public let totalDocuments: Int
        public let cursor: Int
        public let nextCursor: Int?
        public let documents: [[String: String]]
    }

    public struct InstructionDocumentPage: Sendable, Equatable {
        public let documentID: String
        public let sourcePath: String
        public let content: String
        public let byteOffset: Int
        public let nextByteOffset: Int?
        public let totalBytes: Int
        public let sha256: String
    }
    public static let ordinaryDefaultAllowedTools = [
        "fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "fs_move",
        "search_text", "instruction_catalog", "instruction_read", "shell_exec",
        "git_status", "git_diff", "git_log", "git_add", "git_commit",
        "project_memory.remember", "project_memory.search", "project_memory.get",
        "project_memory.update", "project_memory.list_recent", "project_memory.status",
    ]

    private let paths: AppPaths
    private let clock: any Clock
    private let lock = NSLock()
    private var state: PersistedState

    public init(paths: AppPaths, clock: any Clock = SystemClock()) throws {
        self.paths = paths
        self.clock = clock
        try paths.ensureLayout()
        Self.cleanupAbandonedStages(paths.instructionPackageStoreDir)
        if FileManager.default.fileExists(atPath: paths.instructionPackageQueue.path) {
            let data = try OwnerOnlyAtomicFile.read(
                from: paths.instructionPackageQueue,
                maximumBytes: Self.maximumQueueStateBytes
            )
            var decoded = try JSONDecoder().decode(PersistedState.self, from: data)
            guard (1...Self.schemaVersion).contains(decoded.schemaVersion),
                  decoded.packages.count <= Self.maximumPackages,
                  decoded.runArtifacts.count <= Self.maximumRunArtifacts,
                  Set(decoded.runArtifacts.map(\.runID)).count == decoded.runArtifacts.count,
                  decoded.runArtifacts.allSatisfy(Self.validRunArtifact) else {
                throw ProjectInstructionQueueError.storageFailure("unsupported or oversized queue state")
            }
            if decoded.schemaVersion < Self.schemaVersion {
                decoded.schemaVersion = Self.schemaVersion
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                try OwnerOnlyAtomicFile.write(try encoder.encode(decoded), to: paths.instructionPackageQueue)
            }
            state = decoded
        } else {
            state = .empty
        }
    }

    @discardableResult
    public func importRunArtifact(
        sourceURL: URL,
        projectID: ProjectID,
        generation: ProjectGeneration,
        runID: RunID
    ) throws -> ProjectRunInstructionArtifact {
        try assembleRunArtifact(
            sourceURL: sourceURL,
            packageIDs: [],
            projectID: projectID,
            generation: generation,
            runID: runID
        )
    }

    /// Binds an ordered selection of already-published project packages and an
    /// optional newly imported source to one immutable, run-scoped artifact.
    /// A single existing package retains its exact content hash. Multiple
    /// inputs produce a deterministic composite snapshot whose document order
    /// follows `packageIDs`, with the new source (when present) appended last.
    @discardableResult
    public func assembleRunArtifact(
        sourceURL: URL?,
        packageIDs: [UUID],
        projectID: ProjectID,
        generation: ProjectGeneration,
        runID: RunID
    ) throws -> ProjectRunInstructionArtifact {
        guard (!packageIDs.isEmpty || sourceURL != nil),
              packageIDs.count <= Self.maximumRunArtifactInputs,
              Set(packageIDs).count == packageIDs.count else {
            throw ProjectInstructionQueueError.invalidRequest(
                "Choose one through \(Self.maximumRunArtifactInputs) unique instruction inputs."
            )
        }
        let imported = try sourceURL.map {
            try Self.ingest(sourceURL: $0, projectID: projectID)
        }
        lock.lock(); defer { lock.unlock() }
        let packageByID: [UUID: ProjectInstructionPackage] = Dictionary(
            uniqueKeysWithValues: state.packages.compactMap { package in
            guard package.projectID == projectID,
                  package.projectGeneration == generation else { return nil }
            return (package.id, package)
        })
        let packages = try packageIDs.map { packageID in
            guard let package = packageByID[packageID] else {
                throw ProjectInstructionQueueError.packageNotFound(packageID)
            }
            guard package.unresolvedDocumentCount == 0,
                  package.importReadyMetadataAvailable else {
                throw ProjectInstructionQueueError.invalidRequest(
                    "Re-import \(package.displayName) after resolving its unsupported documents before using it in a task."
                )
            }
            return package
        }

        let ingested: IngestedPackage?
        let mission: String
        let sourcePath: String
        let contentSHA256: String
        let documentCount: Int
        let instructionByteCount: Int
        let unresolvedDocumentCount: Int
        if packages.count == 1, imported == nil, let package = packages.first {
            ingested = nil
            mission = package.mission
            sourcePath = package.sourcePath
            contentSHA256 = package.contentSHA256
            documentCount = package.documentCount ?? 0
            instructionByteCount = package.instructionByteCount ?? 0
            unresolvedDocumentCount = package.unresolvedDocumentCount ?? 0
        } else if packages.isEmpty, let imported {
            ingested = imported
            mission = imported.mission
            sourcePath = imported.sourcePath
            contentSHA256 = imported.digest
            documentCount = imported.documents.count
            instructionByteCount = imported.instructionByteCount
            unresolvedDocumentCount = imported.unresolvedDocumentCount
        } else {
            let composite = try compositeRunPackage(
                packages: packages,
                imported: imported,
                projectID: projectID
            )
            ingested = composite
            mission = composite.mission
            sourcePath = paths.instructionPackageStoreDir
                .appendingPathComponent(composite.digest, isDirectory: true).path
            contentSHA256 = composite.digest
            documentCount = composite.documents.count
            instructionByteCount = composite.instructionByteCount
            unresolvedDocumentCount = composite.unresolvedDocumentCount
        }

        let snapshotURL = paths.instructionPackageStoreDir.appendingPathComponent(
            contentSHA256, isDirectory: true
        )
        let published = try ingested.map {
            try Self.publish($0, storeRoot: paths.instructionPackageStoreDir)
        } ?? false
        if let existingIndex = state.runArtifacts.firstIndex(where: { $0.runID == runID }) {
            let existing = state.runArtifacts[existingIndex]
            guard existing.projectID == projectID,
                  existing.contentSHA256 == contentSHA256 else {
                if published, !isDigestReferencedUnlocked(contentSHA256) {
                    try? FileManager.default.removeItem(at: snapshotURL)
                }
                throw ProjectInstructionQueueError.invalidRequest(
                    "The run identifier is already bound to a different instruction artifact."
                )
            }
            if existing.projectGeneration != generation {
                let rebound = ProjectRunInstructionArtifact(
                    runID: runID,
                    projectID: projectID,
                    projectGeneration: generation,
                    mission: mission,
                    sourcePath: sourcePath,
                    contentSHA256: contentSHA256,
                    documentCount: documentCount,
                    instructionByteCount: instructionByteCount,
                    unresolvedDocumentCount: unresolvedDocumentCount,
                    createdAt: existing.createdAt
                )
                let prior = state
                state.runArtifacts[existingIndex] = rebound
                try commitUnlocked(restoring: prior)
                return rebound
            }
            return existing
        }
        guard state.runArtifacts.count < Self.maximumRunArtifacts else {
            if published, !isDigestReferencedUnlocked(contentSHA256) {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
            throw ProjectInstructionQueueError.invalidRequest(
                "Direct run instruction storage is limited to \(Self.maximumRunArtifacts) artifacts."
            )
        }
        let record = ProjectRunInstructionArtifact(
            runID: runID,
            projectID: projectID,
            projectGeneration: generation,
            mission: mission,
            sourcePath: sourcePath,
            contentSHA256: contentSHA256,
            documentCount: documentCount,
            instructionByteCount: instructionByteCount,
            unresolvedDocumentCount: unresolvedDocumentCount,
            createdAt: ISO8601.string(from: clock.now())
        )
        let prior = state
        state.runArtifacts.append(record)
        do {
            try commitUnlocked(restoring: prior)
        } catch {
            if published, !isDigestReferencedUnlocked(contentSHA256) {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
            throw error
        }
        return record
    }

    public func runArtifact(
        contentSHA256: String,
        projectID: ProjectID,
        generation: ProjectGeneration,
        runID: RunID
    ) throws -> ProjectRunInstructionArtifact {
        lock.lock(); defer { lock.unlock() }
        try validateDigestReferenceUnlocked(contentSHA256)
        guard let artifact = state.runArtifacts.first(where: {
            $0.contentSHA256 == contentSHA256
                && $0.projectID == projectID
                && $0.projectGeneration == generation
                && $0.runID == runID
        }) else {
            throw ProjectInstructionQueueError.invalidRequest(
                "Instruction artifact access is not authorized for this project, generation, or run."
            )
        }
        return artifact
    }

    public func snapshot(
        projectID: ProjectID,
        generation: ProjectGeneration
    ) throws -> ProjectInstructionQueueSnapshot {
        lock.lock(); defer { lock.unlock() }
        return try snapshotUnlocked(projectID: projectID, generation: generation)
    }

    public func snapshotPage(
        projectID: ProjectID,
        generation: ProjectGeneration,
        cursor: Int,
        limit: Int
    ) throws -> ProjectInstructionQueueSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard cursor >= 0, (1...128).contains(limit) else {
            throw ProjectInstructionQueueError.invalidRequest(
                "Instruction queue cursor or page size is outside its supported range."
            )
        }
        let ordered = state.packages
            .filter {
                $0.projectID == projectID && $0.projectGeneration == generation
            }
            .sorted(by: Self.packageOrder)
        guard cursor <= ordered.count else {
            throw ProjectInstructionQueueError.invalidRequest(
                "Instruction queue cursor is past the end."
            )
        }
        let end = min(ordered.count, cursor + limit)
        return ProjectInstructionQueueSnapshot(
            projectID: projectID,
            projectGeneration: generation,
            revision: state.revision,
            running: state.runningProjects.contains(projectID.description),
            totalPackages: ordered.count,
            cursor: cursor,
            nextCursor: end < ordered.count ? end : nil,
            packages: Array(ordered[cursor..<end])
        )
    }

    @discardableResult
    public func importPackage(
        sourceURL: URL,
        projectID: ProjectID,
        generation: ProjectGeneration
    ) throws -> ProjectInstructionQueueSnapshot {
        // Conversion and hashing intentionally happen outside the queue mutation lock.
        // Only atomic publication and metadata linkage serialize queue writers.
        let ingested = try Self.ingest(sourceURL: sourceURL, projectID: projectID)
        let snapshotURL = paths.instructionPackageStoreDir.appendingPathComponent(
            ingested.digest, isDirectory: true
        )
        let published = try Self.publish(ingested, storeRoot: paths.instructionPackageStoreDir)
        lock.lock(); defer { lock.unlock() }
        guard state.packages.count < Self.maximumPackages else {
            if published, !isDigestReferencedUnlocked(ingested.digest) {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
            throw ProjectInstructionQueueError.invalidRequest("The instruction queue is limited to \(Self.maximumPackages) packages.")
        }
        let existing = state.packages.filter {
            $0.projectID == projectID && $0.projectGeneration == generation
        }
        let timestamp = ISO8601.string(from: clock.now())
        let prior = state
        let record = ProjectInstructionPackage(
            id: UUID(), projectID: projectID, projectGeneration: generation,
            packageID: ingested.packageID, version: ingested.version,
            displayName: ingested.displayName, mission: ingested.mission,
            sourcePath: ingested.sourcePath, contentSHA256: ingested.digest,
            allowedTools: ingested.allowedTools, completionGates: ingested.completionGates,
            documentCount: ingested.documents.count,
            instructionByteCount: ingested.instructionByteCount,
            unresolvedDocumentCount: ingested.unresolvedDocumentCount,
            position: existing.count, state: .queued, runID: nil, lastError: nil,
            createdAt: timestamp, updatedAt: timestamp
        )
        state.packages.append(record)
        do {
            try commitUnlocked(restoring: prior)
        } catch {
            if published, !isDigestReferencedUnlocked(ingested.digest) {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
            throw error
        }
        return try snapshotUnlocked(projectID: projectID, generation: generation)
    }

    public func documentReferences(
        contentSHA256: String
    ) throws -> [ManagerPreparedRunDocumentReference] {
        lock.lock(); defer { lock.unlock() }
        try validateDigestReferenceUnlocked(contentSHA256)
        let root = paths.instructionPackageStoreDir
            .appendingPathComponent(contentSHA256, isDirectory: true)
            .standardizedFileURL
        if let catalog = try Self.storedCatalog(root: root) {
            return catalog.documents.compactMap { document in
                guard let canonicalReference = document.canonicalReference,
                      let byteCount = document.canonicalByteCount,
                      let sha256 = document.canonicalSHA256 else { return nil }
                return ManagerPreparedRunDocumentReference(
                    reference: "instruction-snapshot:\(contentSHA256)/\(canonicalReference)",
                    byteCount: byteCount,
                    sha256: sha256
                )
            }
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction snapshot cannot be enumerated"
            )
        }
        var references: [ManagerPreparedRunDocumentReference] = []
        var aggregateBytes = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let rootComponents = root.pathComponents
            let fileComponents = file.standardizedFileURL.pathComponents
            guard fileComponents.starts(with: rootComponents) else {
                throw ProjectInstructionQueueError.storageFailure(
                    "instruction snapshot escaped its content-addressed root"
                )
            }
            let relative = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
            guard relative != "accepted.json", !relative.isEmpty else { continue }
            let byteCount = values.fileSize ?? 0
            guard byteCount >= 0,
                  byteCount <= Self.maximumSourceFileBytes,
                  aggregateBytes <= Self.maximumAggregateBytes - byteCount else {
                throw ProjectInstructionQueueError.storageFailure(
                    "instruction snapshot exceeds its bounded document limits"
                )
            }
            let data = try OwnerOnlyAtomicFile.read(
                from: file,
                maximumBytes: Self.maximumSourceFileBytes
            )
            aggregateBytes += data.count
            references.append(ManagerPreparedRunDocumentReference(
                reference: "instruction-snapshot:\(contentSHA256)/\(relative)",
                byteCount: data.count,
                sha256: JSONSupport.sha256Hex(data)
            ))
        }
        guard !references.isEmpty, references.count <= Self.maximumSourceFiles else {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction snapshot has no bounded instruction documents"
            )
        }
        return references.sorted { $0.reference < $1.reference }
    }

    public func catalogPage(
        contentSHA256: String,
        projectID: ProjectID,
        generation: ProjectGeneration,
        runID: RunID?,
        cursor: Int,
        limit: Int
    ) throws -> InstructionCatalogPage {
        lock.lock(); defer { lock.unlock() }
        try validatePackageAccessUnlocked(
            contentSHA256: contentSHA256,
            projectID: projectID,
            generation: generation,
            runID: runID
        )
        guard cursor >= 0, (1...128).contains(limit) else {
            throw ProjectInstructionQueueError.invalidRequest(
                "Instruction catalog cursor or page size is outside its supported range."
            )
        }
        let root = paths.instructionPackageStoreDir.appendingPathComponent(
            contentSHA256, isDirectory: true
        )
        guard let catalog = try Self.storedCatalog(root: root) else {
            throw ProjectInstructionQueueError.storageFailure(
                "This legacy snapshot has no document catalog; re-import it to enable scoped delivery."
            )
        }
        guard cursor <= catalog.documents.count else {
            throw ProjectInstructionQueueError.invalidRequest("Instruction catalog cursor is past the end.")
        }
        let end = min(catalog.documents.count, cursor + limit)
        let documents = catalog.documents[cursor..<end].map { document in
            [
                "id": document.id,
                "source_path": document.sourcePath,
                "status": document.status.rawValue,
                "detail": document.detail,
                "original_sha256": document.originalSHA256,
                "canonical_sha256": document.canonicalSHA256 ?? "",
                "canonical_bytes": document.canonicalByteCount.map(String.init) ?? "0",
            ]
        }
        return InstructionCatalogPage(
            contentSHA256: contentSHA256,
            totalDocuments: catalog.documents.count,
            cursor: cursor,
            nextCursor: end < catalog.documents.count ? end : nil,
            documents: documents
        )
    }

    public func readDocument(
        contentSHA256: String,
        documentID: String,
        projectID: ProjectID,
        generation: ProjectGeneration,
        runID: RunID?,
        byteOffset: Int,
        maximumBytes: Int
    ) throws -> InstructionDocumentPage {
        lock.lock(); defer { lock.unlock() }
        try validatePackageAccessUnlocked(
            contentSHA256: contentSHA256,
            projectID: projectID,
            generation: generation,
            runID: runID
        )
        guard byteOffset >= 0, (1...Self.maximumDeliveryBytes).contains(maximumBytes) else {
            throw ProjectInstructionQueueError.invalidRequest(
                "Instruction delivery offset or byte budget is outside its supported range."
            )
        }
        let root = paths.instructionPackageStoreDir.appendingPathComponent(
            contentSHA256, isDirectory: true
        ).standardizedFileURL
        guard let catalog = try Self.storedCatalog(root: root),
              let document = catalog.documents.first(where: { $0.id == documentID }),
              let reference = document.canonicalReference,
              let expectedSHA256 = document.canonicalSHA256 else {
            throw ProjectInstructionQueueError.invalidRequest(
                "The requested document has no converted instruction text."
            )
        }
        let url = root.appendingPathComponent(reference).standardizedFileURL
        guard try Self.relativePath(url, root: root) == reference else {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction document escaped its content-addressed root"
            )
        }
        let data = try OwnerOnlyAtomicFile.read(
            from: url, maximumBytes: Self.maximumSourceFileBytes
        )
        guard JSONSupport.sha256Hex(data) == expectedSHA256, byteOffset <= data.count,
              String(data: data.prefix(byteOffset), encoding: .utf8) != nil else {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction document integrity or UTF-8 cursor validation failed"
            )
        }
        var end = min(data.count, byteOffset + maximumBytes)
        while end > byteOffset,
              String(data: data[byteOffset..<end], encoding: .utf8) == nil {
            end -= 1
        }
        guard end > byteOffset || byteOffset == data.count,
              let content = String(data: data[byteOffset..<end], encoding: .utf8) else {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction delivery could not preserve a UTF-8 scalar boundary"
            )
        }
        return InstructionDocumentPage(
            documentID: document.id,
            sourcePath: document.sourcePath,
            content: content,
            byteOffset: byteOffset,
            nextByteOffset: end < data.count ? end : nil,
            totalBytes: data.count,
            sha256: expectedSHA256
        )
    }

    @discardableResult
    public func reorder(
        projectID: ProjectID,
        generation: ProjectGeneration,
        packageIDs: [UUID],
        expectedRevision: UInt64
    ) throws -> ProjectInstructionQueueSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard state.revision == expectedRevision else {
            throw ProjectInstructionQueueError.staleRevision(expected: expectedRevision, actual: state.revision)
        }
        let indices = state.packages.indices.filter {
            state.packages[$0].projectID == projectID
                && state.packages[$0].projectGeneration == generation
        }
        let current = indices.map { state.packages[$0] }
        guard packageIDs.count == current.count,
              Set(packageIDs).count == packageIDs.count,
              Set(packageIDs) == Set(current.map(\.id)) else {
            throw ProjectInstructionQueueError.invalidRequest("Reordering must include every package exactly once.")
        }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let timestamp = ISO8601.string(from: clock.now())
        let prior = state
        for (position, packageID) in packageIDs.enumerated() {
            guard var package = byID[packageID] else { throw ProjectInstructionQueueError.packageNotFound(packageID) }
            if package.state == .running { throw ProjectInstructionQueueError.activePackage(packageID) }
            package.position = position
            package.updatedAt = timestamp
            state.packages[indices[position]] = package
        }
        try commitUnlocked(restoring: prior)
        return try snapshotUnlocked(projectID: projectID, generation: generation)
    }

    @discardableResult
    public func remove(
        projectID: ProjectID,
        generation: ProjectGeneration,
        packageID: UUID
    ) throws -> ProjectInstructionQueueSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard let index = state.packages.firstIndex(where: {
            $0.id == packageID && $0.projectID == projectID
        }) else { throw ProjectInstructionQueueError.packageNotFound(packageID) }
        guard state.packages[index].projectGeneration == generation else {
            throw ProjectInstructionQueueError.staleProjectGeneration
        }
        guard state.packages[index].state != .running else {
            throw ProjectInstructionQueueError.activePackage(packageID)
        }
        let prior = state
        let removedDigest = state.packages[index].contentSHA256
        state.packages.remove(at: index)
        normalizePositionsUnlocked(projectID: projectID, generation: generation)
        try commitUnlocked(restoring: prior)
        removeSnapshotIfUnreferencedUnlocked(removedDigest)
        return try snapshotUnlocked(projectID: projectID, generation: generation)
    }

    @discardableResult
    public func start(
        projectID: ProjectID,
        generation: ProjectGeneration
    ) throws -> ProjectInstructionQueueSnapshot {
        lock.lock(); defer { lock.unlock() }
        let key = projectID.description
        guard !state.runningProjects.contains(key) else {
            throw ProjectInstructionQueueError.queueAlreadyRunning
        }
        let packages = state.packages.filter {
            $0.projectID == projectID && $0.projectGeneration == generation
        }
        guard !packages.isEmpty else {
            throw ProjectInstructionQueueError.queueBlocked(
                "Add at least one instruction package before starting autonomy."
            )
        }
        guard packages.contains(where: { $0.state == .queued }) else {
            throw ProjectInstructionQueueError.queueBlocked("No queued instruction packages remain.")
        }
        if let next = packages.filter({ $0.state == .queued }).sorted(by: Self.packageOrder).first,
           let unresolved = next.unresolvedDocumentCount, unresolved > 0 {
            throw ProjectInstructionQueueError.queueBlocked(
                "Resolve or remove the \(unresolved) unconverted instruction document(s) in \(next.displayName) before starting this queue."
            )
        }
        let prior = state
        let timestamp = ISO8601.string(from: clock.now())
        for index in state.packages.indices where state.packages[index].projectID == projectID
            && state.packages[index].projectGeneration != generation
            && !state.packages[index].state.isTerminal {
            state.packages[index].state = .cancelled
            state.packages[index].lastError = "Superseded by project generation \(generation.rawValue)"
            state.packages[index].updatedAt = timestamp
        }
        state.runningProjects.append(key)
        try commitUnlocked(restoring: prior)
        return try snapshotUnlocked(projectID: projectID, generation: generation)
    }

    @discardableResult
    public func stop(
        projectID: ProjectID,
        generation: ProjectGeneration
    ) throws -> ProjectInstructionQueueSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard state.packages.contains(where: {
            $0.projectID == projectID && $0.projectGeneration == generation
        }) else { throw ProjectInstructionQueueError.queueNotRunning }
        let key = projectID.description
        guard state.runningProjects.contains(key) else {
            throw ProjectInstructionQueueError.queueNotRunning
        }
        let prior = state
        state.runningProjects.removeAll { $0 == key }
        try commitUnlocked(restoring: prior)
        return try snapshotUnlocked(projectID: projectID, generation: generation)
    }

    public func nextRunnable() -> ProjectInstructionPackage? {
        lock.lock(); defer { lock.unlock() }
        for rawProjectID in state.runningProjects.sorted() {
            guard let projectUUID = UUID(uuidString: rawProjectID),
                  !state.packages.contains(where: {
                      $0.projectID == ProjectID(projectUUID) && $0.state == .running
                  }) else { continue }
            if let package = state.packages
                .filter({ $0.projectID == ProjectID(projectUUID) && $0.state == .queued })
                .sorted(by: Self.packageOrder)
                .first, package.unresolvedDocumentCount ?? 0 == 0 {
                return package
            }
        }
        return nil
    }

    public func runningPackages() -> [ProjectInstructionPackage] {
        lock.lock(); defer { lock.unlock() }
        return state.packages
            .filter { $0.state == .running && $0.runID != nil }
            .sorted { lhs, rhs in
                if lhs.projectID != rhs.projectID {
                    return lhs.projectID.description < rhs.projectID.description
                }
                return Self.packageOrder(lhs, rhs)
            }
    }

    @discardableResult
    public func markStarted(packageID: UUID, runID: RunID) throws -> ProjectInstructionPackage {
        lock.lock(); defer { lock.unlock() }
        guard let index = state.packages.firstIndex(where: { $0.id == packageID }) else {
            throw ProjectInstructionQueueError.packageNotFound(packageID)
        }
        guard state.runningProjects.contains(state.packages[index].projectID.description),
              state.packages[index].state == .queued,
              state.packages[index].unresolvedDocumentCount ?? 0 == 0 else {
            throw ProjectInstructionQueueError.activePackage(packageID)
        }
        let prior = state
        state.packages[index].state = .running
        state.packages[index].runID = runID
        state.packages[index].lastError = nil
        state.packages[index].updatedAt = ISO8601.string(from: clock.now())
        try commitUnlocked(restoring: prior)
        return state.packages[index]
    }

    @discardableResult
    public func reconcile(
        packageID: UUID,
        runID: RunID,
        runState: AutonomousRunState,
        error: String? = nil
    ) throws -> ProjectInstructionPackage {
        lock.lock(); defer { lock.unlock() }
        guard let index = state.packages.firstIndex(where: { $0.id == packageID }) else {
            throw ProjectInstructionQueueError.packageNotFound(packageID)
        }
        guard state.packages[index].state == .running,
              state.packages[index].runID == runID else {
            throw ProjectInstructionQueueError.activePackage(packageID)
        }
        let prior = state
        let projectKey = state.packages[index].projectID.description
        switch runState {
        case .completed:
            state.packages[index].state = .completed
        case .cancelled:
            state.packages[index].state = .cancelled
            state.runningProjects.removeAll { $0 == projectKey }
        case .failedTerminal:
            state.packages[index].state = .failed
            state.runningProjects.removeAll { $0 == projectKey }
        case .blockedConfiguration, .paused:
            state.packages[index].state = .blocked
            state.runningProjects.removeAll { $0 == projectKey }
        default:
            return state.packages[index]
        }
        state.packages[index].lastError = error
        state.packages[index].updatedAt = ISO8601.string(from: clock.now())
        if state.packages[index].state == .completed {
            let projectID = state.packages[index].projectID
            let generation = state.packages[index].projectGeneration
            let hasMore = state.packages.contains {
                $0.projectID == projectID
                    && $0.projectGeneration == generation
                    && $0.state == .queued
            }
            if !hasMore { state.runningProjects.removeAll { $0 == projectID.description } }
        }
        try commitUnlocked(restoring: prior)
        return state.packages[index]
    }

    @discardableResult
    public func fenceProject(
        projectID: ProjectID,
        generation: ProjectGeneration,
        reason: String
    ) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let prior = state
        let timestamp = ISO8601.string(from: clock.now())
        var count = 0
        for index in state.packages.indices where state.packages[index].projectID == projectID
            && state.packages[index].projectGeneration == generation
            && !state.packages[index].state.isTerminal {
            state.packages[index].state = .cancelled
            state.packages[index].lastError = String(reason.prefix(2_048))
            state.packages[index].updatedAt = timestamp
            count += 1
        }
        let wasRunning = state.runningProjects.contains(projectID.description)
        state.runningProjects.removeAll { $0 == projectID.description }
        if count > 0 || wasRunning { try commitUnlocked(restoring: prior) }
        return count
    }

    @discardableResult
    public func removeProject(projectID: ProjectID) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let prior = state
        let removedDigests = Set(
            state.packages.filter { $0.projectID == projectID }.map(\.contentSHA256)
                + state.runArtifacts.filter { $0.projectID == projectID }.map(\.contentSHA256)
        )
        let originalCount = state.packages.count
        let originalArtifactCount = state.runArtifacts.count
        state.packages.removeAll { $0.projectID == projectID }
        state.runArtifacts.removeAll { $0.projectID == projectID }
        state.runningProjects.removeAll { $0 == projectID.description }
        let removed = originalCount - state.packages.count
        let removedArtifacts = originalArtifactCount - state.runArtifacts.count
        if removed > 0 || removedArtifacts > 0
            || prior.runningProjects.contains(projectID.description) {
            try commitUnlocked(restoring: prior)
            for digest in removedDigests { removeSnapshotIfUnreferencedUnlocked(digest) }
        }
        return removed + removedArtifacts
    }

    private func snapshotUnlocked(
        projectID: ProjectID,
        generation: ProjectGeneration
    ) throws -> ProjectInstructionQueueSnapshot {
        let packages = state.packages
            .filter {
                $0.projectID == projectID && $0.projectGeneration == generation
            }
            .sorted(by: Self.packageOrder)
        return ProjectInstructionQueueSnapshot(
            projectID: projectID,
            projectGeneration: generation,
            revision: state.revision,
            running: state.runningProjects.contains(projectID.description),
            totalPackages: packages.count,
            cursor: 0,
            nextCursor: nil,
            packages: packages
        )
    }

    private func normalizePositionsUnlocked(
        projectID: ProjectID,
        generation: ProjectGeneration
    ) {
        let ordered = state.packages.indices
            .filter {
                state.packages[$0].projectID == projectID
                    && state.packages[$0].projectGeneration == generation
            }
            .sorted { Self.packageOrder(state.packages[$0], state.packages[$1]) }
        for (position, index) in ordered.enumerated() { state.packages[index].position = position }
    }

    private func validateDigestReferenceUnlocked(_ contentSHA256: String) throws {
        guard contentSHA256.utf8.count == 64,
              contentSHA256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              isDigestReferencedUnlocked(contentSHA256) else {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction snapshot identity is invalid or unreferenced"
            )
        }
    }

    private func validatePackageAccessUnlocked(
        contentSHA256: String,
        projectID: ProjectID,
        generation: ProjectGeneration,
        runID: RunID?
    ) throws {
        try validateDigestReferenceUnlocked(contentSHA256)
        let packageAccess = state.packages.contains(where: {
            $0.contentSHA256 == contentSHA256
                && $0.projectID == projectID
                && $0.projectGeneration == generation
                && (runID == nil || $0.runID == runID)
        })
        let runArtifactAccess = runID.map { requestedRunID in
            state.runArtifacts.contains(where: {
                $0.contentSHA256 == contentSHA256
                    && $0.projectID == projectID
                    && $0.projectGeneration == generation
                    && $0.runID == requestedRunID
            })
        } ?? false
        guard packageAccess || runArtifactAccess else {
            throw ProjectInstructionQueueError.invalidRequest(
                "Instruction snapshot access is not authorized for this project, generation, or run."
            )
        }
    }

    private func isDigestReferencedUnlocked(_ digest: String) -> Bool {
        state.packages.contains(where: { $0.contentSHA256 == digest })
            || state.runArtifacts.contains(where: { $0.contentSHA256 == digest })
    }

    private static func validRunArtifact(_ artifact: ProjectRunInstructionArtifact) -> Bool {
        artifact.contentSHA256.utf8.count == 64
            && artifact.contentSHA256.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            })
            && !artifact.mission.isEmpty
            && artifact.mission == artifact.mission.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            && artifact.mission.utf8.count <= maximumBootstrapSummaryBytes
            && !artifact.sourcePath.isEmpty
            && artifact.sourcePath.utf8.count <= 4_096
            && (artifact.sourcePath as NSString).isAbsolutePath
            && (1...maximumSourceFiles).contains(artifact.documentCount)
            && artifact.instructionByteCount >= 0
            && artifact.instructionByteCount <= maximumAggregateBytes
            && (0...artifact.documentCount).contains(artifact.unresolvedDocumentCount)
            && artifact.createdAt.utf8.count <= 64
    }

    private func compositeRunPackage(
        packages: [ProjectInstructionPackage],
        imported: IngestedPackage?,
        projectID: ProjectID
    ) throws -> IngestedPackage {
        var documents: [IngestedDocument] = []
        var labels: [String] = []
        for (index, package) in packages.enumerated() {
            labels.append(package.displayName)
            let prefix = String(format: "%03d-%@", index + 1, Self.slug(package.displayName))
            let stored = try storedDocuments(
                contentSHA256: package.contentSHA256,
                pathPrefix: prefix
            )
            guard documents.count <= Self.maximumSourceFiles - stored.count else {
                throw ProjectInstructionQueueError.invalidRequest(
                    "The selected packages contain more than \(Self.maximumSourceFiles) documents."
                )
            }
            documents.append(contentsOf: stored)
        }
        if let imported {
            labels.append(imported.displayName)
            let prefix = String(
                format: "%03d-%@",
                packages.count + 1,
                Self.slug(imported.displayName)
            )
            guard documents.count <= Self.maximumSourceFiles - imported.documents.count else {
                throw ProjectInstructionQueueError.invalidRequest(
                    "The selected instructions contain more than \(Self.maximumSourceFiles) documents."
                )
            }
            documents.append(contentsOf: imported.documents.map { document in
                IngestedDocument(
                    path: "\(prefix)/\(document.path)",
                    original: document.original,
                    canonicalText: document.canonicalText,
                    encoding: document.encoding,
                    converter: document.converter,
                    status: document.status,
                    detail: document.detail
                )
            })
        }
        let orderedSummary = labels.enumerated().map { index, label in
            "\(index + 1). \(label)"
        }.joined(separator: "\n")
        let goal = try Self.boundedBootstrapGoal(
            "Follow these selected instruction artifacts in order:\n\(orderedSummary)"
        )
        return try Self.makePackage(
            packageID: "run-instructions",
            version: "1",
            displayName: "Task Instructions",
            sourcePath: paths.instructionPackageStoreDir.path,
            bootstrapGoal: goal,
            allowedTools: Self.ordinaryDefaultAllowedTools,
            completionGates: [Self.builtInCompletionGate],
            documents: documents
        )
    }

    private func storedDocuments(
        contentSHA256: String,
        pathPrefix: String
    ) throws -> [IngestedDocument] {
        let root = paths.instructionPackageStoreDir
            .appendingPathComponent(contentSHA256, isDirectory: true)
            .standardizedFileURL
        guard let catalog = try Self.storedCatalog(root: root),
              catalog.contentSHA256 == contentSHA256 else {
            throw ProjectInstructionQueueError.storageFailure(
                "This legacy instruction snapshot must be re-imported before it can be selected for a task."
            )
        }
        return try catalog.documents.map { document in
            let originalURL = root.appendingPathComponent(document.originalReference)
                .standardizedFileURL
            guard try Self.relativePath(originalURL, root: root) == document.originalReference else {
                throw ProjectInstructionQueueError.storageFailure(
                    "instruction snapshot source escaped its content-addressed root"
                )
            }
            let original = try OwnerOnlyAtomicFile.read(
                from: originalURL,
                maximumBytes: Self.maximumSourceFileBytes
            )
            guard original.count == document.originalByteCount,
                  JSONSupport.sha256Hex(original) == document.originalSHA256 else {
                throw ProjectInstructionQueueError.storageFailure(
                    "instruction snapshot source integrity verification failed"
                )
            }
            let canonicalText: String?
            if let reference = document.canonicalReference,
               let byteCount = document.canonicalByteCount,
               let sha256 = document.canonicalSHA256 {
                let canonicalURL = root.appendingPathComponent(reference).standardizedFileURL
                guard try Self.relativePath(canonicalURL, root: root) == reference else {
                    throw ProjectInstructionQueueError.storageFailure(
                        "canonical instruction escaped its content-addressed root"
                    )
                }
                let data = try OwnerOnlyAtomicFile.read(
                    from: canonicalURL,
                    maximumBytes: Self.maximumSourceFileBytes
                )
                guard data.count == byteCount,
                      JSONSupport.sha256Hex(data) == sha256,
                      let text = String(data: data, encoding: .utf8) else {
                    throw ProjectInstructionQueueError.storageFailure(
                        "canonical instruction integrity verification failed"
                    )
                }
                canonicalText = text
            } else {
                canonicalText = nil
            }
            return IngestedDocument(
                path: "\(pathPrefix)/\(document.sourcePath)",
                original: original,
                canonicalText: canonicalText,
                encoding: document.encoding,
                converter: document.converter,
                status: document.status,
                detail: document.detail
            )
        }
    }

    private func removeSnapshotIfUnreferencedUnlocked(_ digest: String) {
        guard !isDigestReferencedUnlocked(digest) else { return }
        try? FileManager.default.removeItem(
            at: paths.instructionPackageStoreDir.appendingPathComponent(digest, isDirectory: true)
        )
    }

    private func commitUnlocked(restoring prior: PersistedState) throws {
        guard state.revision < UInt64.max else {
            state = prior
            throw ProjectInstructionQueueError.storageFailure("queue revision is exhausted")
        }
        state.revision += 1
        state.runningProjects = Array(Set(state.runningProjects)).sorted()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try OwnerOnlyAtomicFile.write(
                try encoder.encode(state),
                to: paths.instructionPackageQueue
            )
        } catch {
            state = prior
            throw ProjectInstructionQueueError.storageFailure(error.localizedDescription)
        }
    }

    private static func packageOrder(
        _ lhs: ProjectInstructionPackage,
        _ rhs: ProjectInstructionPackage
    ) -> Bool {
        lhs.position == rhs.position ? lhs.id.uuidString < rhs.id.uuidString : lhs.position < rhs.position
    }

    private static func ingest(
        sourceURL: URL,
        projectID: ProjectID
    ) throws -> IngestedPackage {
        let source = sourceURL.standardizedFileURL
        guard source.isFileURL, source.path.utf8.count <= 4_096 else {
            throw ProjectInstructionQueueError.invalidRequest("Instruction package path is invalid or too long.")
        }
        let values: URLResourceValues
        do {
            values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw ProjectInstructionQueueError.sourceUnavailable
        }
        guard values.isSymbolicLink != true else { throw ProjectInstructionQueueError.sourceContainsLink }
        let package: IngestedPackage
        if values.isRegularFile == true {
            let sourceData = try readRegularFile(source)
            if source.pathExtension.lowercased() != "docx",
               SafeZIPArchive.isZIP(sourceData, path: source.path) {
                package = try archivePackage(source, data: sourceData)
            } else if source.pathExtension.lowercased() == "forgepackage"
                || (source.lastPathComponent == "forge-package.json"
                    && (try? compatibleManifest(at: source)) == true) {
                package = try manifestPackage(manifestURL: source, root: source.deletingLastPathComponent(), projectID: projectID)
            } else {
                let name = source.deletingPathExtension().lastPathComponent
                package = try makePackage(
                    packageID: slug(name), version: "1", displayName: name,
                    sourcePath: source.path,
                    bootstrapGoal: "Follow the imported instructions in \(source.lastPathComponent).",
                    allowedTools: ordinaryDefaultAllowedTools,
                    completionGates: [builtInCompletionGate],
                    documents: [try ingestDocument(path: source.lastPathComponent, data: sourceData)]
                )
            }
        } else if values.isDirectory == true {
            let manifestURLs = ["forge-package.json", "package.forgepackage"].map {
                source.appendingPathComponent($0)
            }
            if let manifest = manifestURLs.first(where: {
                guard FileManager.default.fileExists(atPath: $0.path) else { return false }
                return $0.pathExtension.lowercased() == "forgepackage"
                    || (try? compatibleManifest(at: $0)) == true
            }) {
                package = try manifestPackage(manifestURL: manifest, root: source, projectID: projectID)
            } else {
                package = try directoryPackage(source)
            }
        } else {
            throw ProjectInstructionQueueError.sourceTypeUnsupported
        }
        return package
    }

    private static func directoryPackage(_ root: URL) throws -> IngestedPackage {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { throw ProjectInstructionQueueError.sourceUnavailable }
        var documents: [IngestedDocument] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw ProjectInstructionQueueError.sourceContainsLink }
            guard values.isRegularFile == true else { continue }
            guard documents.count < maximumSourceFiles else {
                throw ProjectInstructionQueueError.invalidRequest(
                    "Instruction package exceeds the \(maximumSourceFiles)-file import resource budget. Split the import without rewriting individual instructions."
                )
            }
            let relative = try relativePath(url, root: root)
            documents.append(try ingestDocument(path: relative, url: url))
        }
        documents.sort { $0.path < $1.path }
        guard !documents.isEmpty else { throw ProjectInstructionQueueError.sourceTypeUnsupported }
        return try makePackage(
            packageID: slug(root.lastPathComponent), version: "1",
            displayName: root.lastPathComponent, sourcePath: root.path,
            bootstrapGoal: "Follow the imported instructions in \(root.lastPathComponent).",
            allowedTools: ordinaryDefaultAllowedTools, completionGates: [builtInCompletionGate],
            documents: documents
        )
    }

    private static func archivePackage(_ archive: URL, data: Data) throws -> IngestedPackage {
        let entries: [SafeZIPArchive.Entry]
        do { entries = try SafeZIPArchive.inspect(data) }
        catch { throw ProjectInstructionQueueError.invalidRequest(error.localizedDescription) }
        let extraction = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forge-instruction-archive-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: extraction) }
        do { try SafeZIPArchive.extract(data, to: extraction, expected: entries) }
        catch { throw ProjectInstructionQueueError.invalidRequest(error.localizedDescription) }
        var documents: [IngestedDocument] = [IngestedDocument(
            path: archive.lastPathComponent,
            original: data,
            canonicalText: nil,
            encoding: nil,
            converter: "native-zip-inventory-v1",
            status: .retainedAttachment,
            detail: "Original ZIP container retained; inventoried entries are stored separately and are never executed during import."
        )]
        for entry in entries where !entry.isDirectory {
            let url = extraction.appendingPathComponent(entry.path).standardizedFileURL
            guard try relativePath(url, root: extraction) == entry.path else {
                throw ProjectInstructionQueueError.invalidRequest(
                    "The extracted ZIP inventory escaped its staging directory."
                )
            }
            documents.append(try ingestDocument(path: "archive/\(entry.path)", url: url))
        }
        return try makePackage(
            packageID: slug(archive.deletingPathExtension().lastPathComponent),
            version: "1",
            displayName: archive.deletingPathExtension().lastPathComponent,
            sourcePath: archive.path,
            bootstrapGoal: "Follow the imported instructions in \(archive.lastPathComponent).",
            allowedTools: ordinaryDefaultAllowedTools,
            completionGates: [builtInCompletionGate],
            documents: documents
        )
    }

    private static func compatibleManifest(at url: URL) throws -> Bool {
        let data = try readRegularFile(url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["schema_version"] is NSNumber
            && object["package_id"] is String
            && object["entry_documents"] is [Any]
            && object["requested_capabilities"] is [Any]
            && object["completion_gates"] is [Any]
    }

    private static func manifestPackage(
        manifestURL: URL,
        root: URL,
        projectID: ProjectID
    ) throws -> IngestedPackage {
        let data = try readRegularFile(manifestURL)
        let manifest: PackageManifest
        do { manifest = try JSONDecoder().decode(PackageManifest.self, from: data) }
        catch { throw ProjectInstructionQueueError.manifestInvalid(error.localizedDescription) }
        guard manifest.schemaVersion == 1,
              validIdentifier(manifest.packageID, maximum: 128),
              validLabel(manifest.version, maximum: 64),
              manifest.entryDocuments.count > 0,
              manifest.entryDocuments.count <= maximumSourceFiles,
              Set(manifest.entryDocuments).count == manifest.entryDocuments.count,
              !manifest.requestedCapabilities.isEmpty,
              manifest.requestedCapabilities.count <= 256,
              Set(manifest.requestedCapabilities).count == manifest.requestedCapabilities.count,
              !manifest.completionGateStrings.isEmpty,
              manifest.completionGateStrings.count <= 128,
              Set(manifest.completionGateStrings).count == manifest.completionGateStrings.count,
              manifest.requestedCapabilities.allSatisfy({ validIdentifier($0, maximum: 128) || $0 == "*" }),
              manifest.completionGateStrings.allSatisfy({ validLabel($0, maximum: 512) }) else {
            throw ProjectInstructionQueueError.manifestInvalid("required fields are missing, duplicated, or outside their bounds")
        }
        if let binding = manifest.projectID,
           binding.caseInsensitiveCompare(projectID.description) != .orderedSame {
            throw ProjectInstructionQueueError.manifestInvalid("project_id does not match the selected project")
        }
        var documents: [IngestedDocument] = [try ingestDocument(
            path: manifestURL.lastPathComponent,
            data: data
        )]
        for entry in manifest.entryDocuments {
            guard validRelativePath(entry) else {
                throw ProjectInstructionQueueError.manifestInvalid("entry document path is invalid")
            }
            let url = root.appendingPathComponent(entry).standardizedFileURL
            guard try relativePath(url, root: root) == entry else {
                throw ProjectInstructionQueueError.manifestInvalid("entry document escapes the package root")
            }
            documents.append(try ingestDocument(path: entry, url: url))
        }
        return try makePackage(
            packageID: manifest.packageID, version: manifest.version,
            displayName: manifest.packageID, sourcePath: root.path,
            bootstrapGoal: try boundedBootstrapGoal(manifest.mission),
            allowedTools: Array(Set(manifest.requestedCapabilities)
                .union(["instruction_catalog", "instruction_read"])).sorted(),
            completionGates: manifest.completionGateStrings, documents: documents
        )
    }

    private static func makePackage(
        packageID: String,
        version: String,
        displayName: String,
        sourcePath: String,
        bootstrapGoal: String,
        allowedTools: [String],
        completionGates: [String],
        documents: [IngestedDocument]
    ) throws -> IngestedPackage {
        let total = documents.reduce(0) { partial, document in
            partial > maximumAggregateBytes - document.original.count
                ? maximumAggregateBytes + 1 : partial + document.original.count
        }
        guard total <= maximumAggregateBytes else {
            throw ProjectInstructionQueueError.invalidRequest(
                "Instruction package exceeds the \(maximumAggregateBytes)-byte import resource budget. Free storage or split the import without rewriting its instructions."
            )
        }
        let instructionBytes = documents.reduce(0) {
            $0 + ($1.canonicalText.map { Data($0.utf8).count } ?? 0)
        }
        let unresolved = documents.filter {
            $0.status == .unresolvedConversion
                || $0.status == .unrepresentedVisualStructural
        }.count
        if instructionBytes == 0, unresolved == 0 {
            throw ProjectInstructionQueueError.invalidRequest(
                "No non-whitespace instructions were found in the selected source."
            )
        }
        let manifest: [[String: Any]] = documents.sorted(by: { $0.path < $1.path }).map {
            [
                "path": $0.path,
                "bytes": $0.original.count,
                "sha256": JSONSupport.sha256Hex($0.original),
                "canonical_sha256": $0.canonicalText.map { JSONSupport.sha256Hex(Data($0.utf8)) } as Any,
                "status": $0.status.rawValue,
            ].compactNSNull()
        }
        let identity: [String: Any] = [
            "package_id": packageID, "version": version, "bootstrap_goal": bootstrapGoal,
            "allowed_tools": allowedTools, "completion_gates": completionGates,
            "documents": manifest,
        ]
        let digest = JSONSupport.sha256Hex(
            try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys, .withoutEscapingSlashes])
        )
        let mission = try boundedBootstrapSummary(
            """
            \(bootstrapGoal)

            The complete authoritative instructions are stored in an immutable project-scoped artifact. Before modifying the project, call instruction_catalog and inspect every converted instruction document with instruction_read, including late global constraints and acceptance criteria. Do not treat retained unresolved content as understood. Snapshot: \(digest)
            """
        )
        return IngestedPackage(
            packageID: packageID, version: version, displayName: displayName,
            mission: mission, sourcePath: sourcePath, digest: digest,
            allowedTools: allowedTools, completionGates: completionGates, documents: documents,
            instructionByteCount: instructionBytes,
            unresolvedDocumentCount: unresolved
        )
    }

    @discardableResult
    private static func publish(_ package: IngestedPackage, storeRoot: URL) throws -> Bool {
        let final = storeRoot.appendingPathComponent(package.digest, isDirectory: true)
        if FileManager.default.fileExists(atPath: final.path) { return false }
        let staging = storeRoot.appendingPathComponent(".\(UUID().uuidString.lowercased())", isDirectory: true)
        var finalCreated = false
        do {
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            var storedDocuments: [StoredDocument] = []
            for (index, document) in package.documents.enumerated() {
                let originalReference = "originals/\(document.path)"
                let target = staging.appendingPathComponent(originalReference)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try document.original.write(to: target, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
                let documentID = String(format: "document-%06d", index + 1)
                var canonicalReference: String?
                var canonicalBytes: Int?
                var canonicalSHA256: String?
                if let text = document.canonicalText {
                    let data = Data(text.utf8)
                    let relative = ".forge/canonical/\(documentID).txt"
                    let canonicalURL = staging.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(
                        at: canonicalURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    try data.write(to: canonicalURL, options: [.atomic])
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o400], ofItemAtPath: canonicalURL.path
                    )
                    canonicalReference = relative
                    canonicalBytes = data.count
                    canonicalSHA256 = JSONSupport.sha256Hex(data)
                }
                storedDocuments.append(StoredDocument(
                    id: documentID,
                    sourcePath: document.path,
                    originalReference: originalReference,
                    originalByteCount: document.original.count,
                    originalSHA256: JSONSupport.sha256Hex(document.original),
                    canonicalReference: canonicalReference,
                    canonicalByteCount: canonicalBytes,
                    canonicalSHA256: canonicalSHA256,
                    encoding: document.encoding,
                    converter: document.converter,
                    status: document.status,
                    detail: document.detail
                ))
            }
            let catalog = StoredCatalog(
                schemaVersion: Self.catalogSchemaVersion,
                contentSHA256: package.digest,
                documents: storedDocuments
            )
            let catalogURL = staging.appendingPathComponent(".forge/catalog.json")
            try FileManager.default.createDirectory(
                at: catalogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(catalog).write(to: catalogURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o400], ofItemAtPath: catalogURL.path
            )
            let receipt: [String: Any] = [
                "schema_version": Self.catalogSchemaVersion, "content_sha256": package.digest,
                "package_id": package.packageID, "version": package.version,
                "document_count": package.documents.count,
                "instruction_byte_count": package.instructionByteCount,
                "unresolved_document_count": package.unresolvedDocumentCount,
            ]
            let receiptURL = staging.appendingPathComponent("accepted.json")
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                .write(to: receiptURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: receiptURL.path)
            try FileManager.default.moveItem(at: staging, to: final)
            finalCreated = true
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: final.path)
            return true
        } catch CocoaError.fileWriteFileExists {
            try? FileManager.default.removeItem(at: staging)
            return false
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if finalCreated { try? FileManager.default.removeItem(at: final) }
            throw ProjectInstructionQueueError.storageFailure(error.localizedDescription)
        }
    }

    private static func readRegularFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw ProjectInstructionQueueError.sourceContainsLink }
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size >= 0,
              size <= maximumSourceFileBytes else {
            throw ProjectInstructionQueueError.invalidRequest(
                "The selected file exceeds the \(maximumSourceFileBytes)-byte import resource budget."
            )
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == size else { throw ProjectInstructionQueueError.sourceUnavailable }
        return data
    }

    private static func storedCatalog(root: URL) throws -> StoredCatalog? {
        let url = root.appendingPathComponent(".forge/catalog.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try OwnerOnlyAtomicFile.read(from: url, maximumBytes: 32 * 1_048_576)
        let catalog = try JSONDecoder().decode(StoredCatalog.self, from: data)
        guard catalog.schemaVersion == Self.catalogSchemaVersion,
              catalog.documents.count <= Self.maximumSourceFiles else {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction document catalog is unsupported or oversized"
            )
        }
        return catalog
    }

    private static func cleanupAbandonedStages(_ root: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".") {
            let identifier = String(entry.lastPathComponent.dropFirst())
            guard UUID(uuidString: identifier) != nil,
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func boundedBootstrapSummary(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumBootstrapSummaryBytes else {
            throw ProjectInstructionQueueError.storageFailure(
                "The generated task bootstrap summary exceeds its \(maximumBootstrapSummaryBytes)-byte metadata budget. The authoritative instruction artifact was not truncated."
            )
        }
        return trimmed
    }

    private static func boundedBootstrapGoal(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectInstructionQueueError.invalidRequest(
                "No non-whitespace instructions were found in the selected source."
            )
        }
        let limit = 8 * 1_024
        guard trimmed.utf8.count <= limit else {
            return "Follow the imported manifest and its ordered entry documents."
        }
        return trimmed
    }

    private static func ingestDocument(path: String, url: URL) throws -> IngestedDocument {
        try ingestDocument(path: path, data: readRegularFile(url))
    }

    private static func ingestDocument(path: String, data: Data) throws -> IngestedDocument {
        if path.lowercased().hasSuffix(".zip"), SafeZIPArchive.isZIP(data, path: path) {
            return IngestedDocument(
                path: path, original: data, canonicalText: nil, encoding: nil,
                converter: "nested-zip-retention-v1", status: .unresolvedConversion,
                detail: "Nested ZIP archives are retained but not recursively expanded. Import this archive separately for bounded inspection."
            )
        }
        if let rich = try decodedRichDocument(path: path, data: data) {
            let normalized = normalizeText(rich.text)
            guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return IngestedDocument(
                    path: path, original: data, canonicalText: nil, encoding: nil,
                    converter: rich.converter, status: rich.emptyStatus,
                    detail: rich.emptyDetail
                )
            }
            return IngestedDocument(
                path: path, original: data, canonicalText: normalized, encoding: nil,
                converter: rich.converter, status: .convertedInstruction,
                detail: rich.detail
            )
        }
        if let decoded = decodedDocument(data) {
            let normalized = normalizeText(decoded.text)
            if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return IngestedDocument(
                    path: path, original: data, canonicalText: nil,
                    encoding: decoded.encoding, converter: "forge-native-text-v1",
                    status: .retainedAttachment,
                    detail: "The source contains no non-whitespace instructions."
                )
            }
            return IngestedDocument(
                path: path, original: data, canonicalText: normalized,
                encoding: decoded.encoding, converter: "forge-native-text-v1",
                status: .convertedInstruction,
                detail: "Decoded as \(decoded.encoding) and normalized to UTF-8."
            )
        }
        if isVisualDocument(path: path, data: data) {
            if let recognized = recognizedImageText(data),
               !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return IngestedDocument(
                    path: path,
                    original: data,
                    canonicalText: normalizeText(recognized),
                    encoding: nil,
                    converter: "vision-ocr-v1",
                    status: .convertedInstruction,
                    detail: "Recovered instruction text with the native Vision OCR adapter; the original visual source remains source-linked."
                )
            }
            return IngestedDocument(
                path: path, original: data, canonicalText: nil, encoding: nil,
                converter: "forge-visual-inventory-v1",
                status: .unrepresentedVisualStructural,
                detail: "The visual source was retained, but no instruction text could be represented. OCR or visual review is required before this package is ready."
            )
        }
        return IngestedDocument(
            path: path, original: data, canonicalText: nil, encoding: nil,
            converter: "forge-native-text-v1",
            status: .unresolvedConversion,
            detail: "The original bytes were retained, but no supported text decoder could interpret this content."
        )
    }

    private static func normalizeText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func decodedRichDocument(
        path: String,
        data: Data
    ) throws -> (
        text: String,
        converter: String,
        detail: String,
        emptyStatus: InstructionDocumentStatus,
        emptyDetail: String
    )? {
        #if canImport(PDFKit)
        if data.starts(with: Data("%PDF-".utf8)) {
            guard let document = PDFDocument(data: data) else {
                return (
                    "", "pdfkit-text-v1", "", .unresolvedConversion,
                    "The PDF is malformed and PDFKit could not open it; original bytes were retained."
                )
            }
            guard !document.isEncrypted else {
                return (
                    "", "pdfkit-text-v1", "", .unresolvedConversion,
                    "The PDF is encrypted and cannot be converted without its password; original bytes were retained."
                )
            }
            let text = (0..<document.pageCount).compactMap { index in
                document.page(at: index)?.string.map { "[PDF page \(index + 1)]\n\($0)" }
            }
                .joined(separator: "\n\n")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let recognized = recognizedPDFText(document) {
                return (
                    recognized,
                    "vision-pdf-ocr-v1",
                    "Recovered page-mapped text with the native Vision OCR adapter; the original PDF remains source-linked.",
                    .unrepresentedVisualStructural,
                    "PDF OCR produced no usable instruction text. The original PDF was retained for visual review."
                )
            }
            return (
                text, "pdfkit-text-v1", "Extracted page-mapped text with PDFKit; the original PDF remains source-linked.",
                .unrepresentedVisualStructural,
                "PDFKit found no extractable text. The original PDF was retained for OCR or visual review."
            )
        }
        #endif
        #if canImport(AppKit)
        let lower = path.lowercased()
        let prefix = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type: NSAttributedString.DocumentType?
        let converter: String
        if lower.hasSuffix(".rtf") || prefix.hasPrefix("{\\rtf") {
            type = .rtf
            converter = "appkit-rtf-v1"
        } else if lower.hasSuffix(".html") || lower.hasSuffix(".htm")
                    || prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html") {
            type = .html
            converter = "appkit-html-v1"
        } else if lower.hasSuffix(".docx") {
            type = .officeOpenXML
            converter = "appkit-docx-v1"
        } else {
            return nil
        }
        do {
            let attributed = try NSAttributedString(
                data: data,
                options: [.documentType: type as Any],
                documentAttributes: nil
            )
            return (
                attributed.string, converter,
                "Converted with the native AppKit \(type?.rawValue ?? "document") adapter; original bytes remain source-linked.",
                .unrepresentedVisualStructural,
                "The native document adapter produced no usable text; original bytes were retained."
            )
        } catch {
            return (
                "", converter, "",
                .unresolvedConversion,
                "The native document adapter could not convert this file: \(String(error.localizedDescription.prefix(512))). Original bytes were retained."
            )
        }
        #else
        return nil
        #endif
    }

    private static func decodedDocument(_ data: Data) -> (text: String, encoding: String)? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let value = String(data: data.dropFirst(3), encoding: .utf8) {
            return (value, "utf-8-bom")
        }
        if data.starts(with: [0xFF, 0xFE]),
           let value = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return (value, "utf-16le-bom")
        }
        if data.starts(with: [0xFE, 0xFF]),
           let value = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return (value, "utf-16be-bom")
        }
        guard !data.contains(0), let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (value, "utf-8")
    }

    private static func isVisualDocument(path: String, data: Data) -> Bool {
        let lower = path.lowercased()
        if [".png", ".jpg", ".jpeg", ".gif", ".heic", ".heif", ".tif", ".tiff", ".bmp"]
            .contains(where: lower.hasSuffix) {
            return true
        }
        return data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || data.starts(with: [0xFF, 0xD8, 0xFF])
            || data.starts(with: Data("GIF8".utf8))
            || data.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
    }

    private static func recognizedImageText(_ data: Data) -> String? {
        #if canImport(ImageIO) && canImport(Vision)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2_048,
                ] as CFDictionary
              ) else { return nil }
        return recognizedText(in: image)
        #else
        return nil
        #endif
    }

    #if canImport(PDFKit) && canImport(AppKit) && canImport(Vision)
    private static func recognizedPDFText(_ document: PDFDocument) -> String? {
        guard document.pageCount > 0, document.pageCount <= 128 else { return nil }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { return nil }
            let image = page.thumbnail(
                of: NSSize(width: 2_048, height: 2_048),
                for: .mediaBox
            )
            var rect = NSRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                  let text = recognizedText(in: cgImage),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            pages.append("[PDF page \(index + 1) OCR]\n\(text)")
        }
        return pages.joined(separator: "\n\n")
    }

    private static func recognizedText(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
    #elseif canImport(Vision)
    private static func recognizedText(in image: CGImage) -> String? { nil }
    #endif

    private static func relativePath(_ url: URL, root: URL) throws -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else {
            throw ProjectInstructionQueueError.manifestInvalid("entry document escapes the package root")
        }
        return String(path.dropFirst(base.count + 1))
    }

    private static func validRelativePath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.hasPrefix("/")
            && !value.split(separator: "/").contains("..")
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
            }
    }

    private static func validLabel(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((result.isEmpty ? "instructions" : result).prefix(128))
    }
}

// ProjectInstructionQueue.swift
// Durable project-scoped instruction package ingestion, ordering, and run linkage.

import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(PDFKit)
import PDFKit
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

    public func asDictionary() -> [String: Any] {
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
    public let packages: [ProjectInstructionPackage]

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case projectGeneration = "project_generation"
        case revision, running, packages
    }

    public func asDictionary() -> [String: Any] {
        [
            "ok": true,
            "project_id": projectID.description,
            "project_generation": projectGeneration.rawValue,
            "revision": revision,
            "running": running,
            "packages": packages.map { $0.asDictionary() },
        ]
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
    public static let schemaVersion = 2
    public static let builtInCompletionGate = "forge.package.tool-success"
    public static let maximumPackages = 4_096
    public static let maximumSourceFiles = 4_096
    public static let maximumSourceFileBytes = 128 * 1_048_576
    public static let maximumAggregateBytes = 512 * 1_048_576
    public static let maximumMissionBytes = 32_768
    public static let maximumQueueStateBytes = 64 * 1_048_576
    public static let maximumDeliveryBytes = 64 * 1_024

    private struct PersistedState: Codable {
        var schemaVersion: Int
        var revision: UInt64
        var runningProjects: [String]
        var packages: [ProjectInstructionPackage]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case revision
            case runningProjects = "running_projects"
            case packages
        }

        static let empty = PersistedState(
            schemaVersion: ProjectInstructionQueueStore.schemaVersion,
            revision: 0,
            runningProjects: [],
            packages: []
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
                  decoded.packages.count <= Self.maximumPackages else {
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

    public func snapshot(
        projectID: ProjectID,
        generation: ProjectGeneration
    ) throws -> ProjectInstructionQueueSnapshot {
        lock.lock(); defer { lock.unlock() }
        return try snapshotUnlocked(projectID: projectID, generation: generation)
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
            if published, !state.packages.contains(where: { $0.contentSHA256 == ingested.digest }) {
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
            if published, !state.packages.contains(where: { $0.contentSHA256 == ingested.digest }) {
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
        )
        let originalCount = state.packages.count
        state.packages.removeAll { $0.projectID == projectID }
        state.runningProjects.removeAll { $0 == projectID.description }
        let removed = originalCount - state.packages.count
        if removed > 0 || prior.runningProjects.contains(projectID.description) {
            try commitUnlocked(restoring: prior)
            for digest in removedDigests { removeSnapshotIfUnreferencedUnlocked(digest) }
        }
        return removed
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
              state.packages.contains(where: { $0.contentSHA256 == contentSHA256 }) else {
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
        guard state.packages.contains(where: {
            $0.contentSHA256 == contentSHA256
                && $0.projectID == projectID
                && $0.projectGeneration == generation
                && (runID == nil || $0.runID == runID)
        }) else {
            throw ProjectInstructionQueueError.invalidRequest(
                "Instruction snapshot access is not authorized for this project, generation, or run."
            )
        }
    }

    private func removeSnapshotIfUnreferencedUnlocked(_ digest: String) {
        guard !state.packages.contains(where: { $0.contentSHA256 == digest }) else { return }
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
        let unresolved = documents.filter { $0.status == .unresolvedConversion }.count
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
        let mission = try boundedMission(
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
                schemaVersion: Self.schemaVersion,
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
                "schema_version": Self.schemaVersion, "content_sha256": package.digest,
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
        guard catalog.schemaVersion == Self.schemaVersion,
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

    private static func boundedMission(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumMissionBytes else {
            throw ProjectInstructionQueueError.invalidRequest("Package instructions must contain 1 through \(maximumMissionBytes) UTF-8 bytes.")
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
                    converter: rich.converter, status: .unresolvedConversion,
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
    ) throws -> (text: String, converter: String, detail: String, emptyDetail: String)? {
        #if canImport(PDFKit)
        if data.starts(with: Data("%PDF-".utf8)) {
            guard let document = PDFDocument(data: data), !document.isEncrypted else {
                return (
                    "", "pdfkit-text-v1", "", "The PDF is encrypted or malformed; original bytes were retained."
                )
            }
            let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
            return (
                text, "pdfkit-text-v1", "Extracted page text with PDFKit; the original PDF remains source-linked.",
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
                "The native document adapter produced no usable text; original bytes were retained."
            )
        } catch {
            return (
                "", converter, "",
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

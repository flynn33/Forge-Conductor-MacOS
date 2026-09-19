// ProjectInstructionQueue.swift
// Durable project-scoped instruction package ingestion, ordering, and run linkage.

import Foundation

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
    public static let schemaVersion = 1
    public static let builtInCompletionGate = "forge.package.tool-success"
    public static let maximumPackages = 256
    public static let maximumStoredSnapshots = 512
    public static let maximumSourceFiles = 64
    public static let maximumSourceFileBytes = 1_048_576
    public static let maximumAggregateBytes = 8 * 1_048_576
    public static let maximumMissionBytes = 32_768

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
        let documents: [(path: String, data: Data)]
    }

    private static let plainDocumentExtensions: Set<String> = ["md", "markdown", "txt"]
    public static let ordinaryDefaultAllowedTools = [
        "fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "fs_move",
        "search_text", "shell_exec", "git_status", "git_diff", "git_log", "git_add", "git_commit",
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
        if FileManager.default.fileExists(atPath: paths.instructionPackageQueue.path) {
            let data = try OwnerOnlyAtomicFile.read(
                from: paths.instructionPackageQueue,
                maximumBytes: 4 * 1_048_576
            )
            let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
            guard decoded.schemaVersion == Self.schemaVersion,
                  decoded.packages.count <= Self.maximumPackages else {
                throw ProjectInstructionQueueError.storageFailure("unsupported or oversized queue state")
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
        lock.lock(); defer { lock.unlock() }
        guard state.packages.count < Self.maximumPackages else {
            throw ProjectInstructionQueueError.invalidRequest("The instruction queue is limited to \(Self.maximumPackages) packages.")
        }
        let ingested = try Self.ingest(sourceURL: sourceURL, projectID: projectID)
        let snapshotURL = paths.instructionPackageStoreDir
            .appendingPathComponent(ingested.digest, isDirectory: true)
        if !FileManager.default.fileExists(atPath: snapshotURL.path),
           try Self.storedSnapshotCount(paths.instructionPackageStoreDir)
                >= Self.maximumStoredSnapshots {
            throw ProjectInstructionQueueError.storageFailure(
                "instruction snapshot storage reached its bounded capacity"
            )
        }
        let existing = state.packages.filter {
            $0.projectID == projectID && $0.projectGeneration == generation
        }
        let timestamp = ISO8601.string(from: clock.now())
        let prior = state
        let published = try Self.publish(
            ingested,
            storeRoot: paths.instructionPackageStoreDir
        )
        let record = ProjectInstructionPackage(
            id: UUID(), projectID: projectID, projectGeneration: generation,
            packageID: ingested.packageID, version: ingested.version,
            displayName: ingested.displayName, mission: ingested.mission,
            sourcePath: ingested.sourcePath, contentSHA256: ingested.digest,
            allowedTools: ingested.allowedTools, completionGates: ingested.completionGates,
            position: existing.count, state: .queued, runID: nil, lastError: nil,
            createdAt: timestamp, updatedAt: timestamp
        )
        state.packages.append(record)
        do {
            try commitUnlocked(restoring: prior)
        } catch {
            if published { try? FileManager.default.removeItem(at: snapshotURL) }
            throw error
        }
        return try snapshotUnlocked(projectID: projectID, generation: generation)
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
                .first {
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
              state.packages[index].state == .queued else {
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
            if plainDocumentExtensions.contains(source.pathExtension.lowercased()) {
                let data = try readRegularFile(source)
                let mission = try boundedMission(try decodedDocument(data))
                let name = source.deletingPathExtension().lastPathComponent
                package = try makePackage(
                    packageID: slug(name), version: "1", displayName: name,
                    mission: mission, sourcePath: source.path,
                    allowedTools: ordinaryDefaultAllowedTools,
                    completionGates: [builtInCompletionGate],
                    documents: [(source.lastPathComponent, data)]
                )
            } else if source.pathExtension.lowercased() == "forgepackage"
                        || source.lastPathComponent == "forge-package.json" {
                package = try manifestPackage(manifestURL: source, root: source.deletingLastPathComponent(), projectID: projectID)
            } else {
                throw ProjectInstructionQueueError.sourceTypeUnsupported
            }
        } else if values.isDirectory == true {
            let manifestURLs = ["forge-package.json", "package.forgepackage"].map {
                source.appendingPathComponent($0)
            }
            if let manifest = manifestURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
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
            options: [.skipsHiddenFiles]
        ) else { throw ProjectInstructionQueueError.sourceUnavailable }
        var documents: [(String, Data)] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw ProjectInstructionQueueError.sourceContainsLink }
            guard values.isRegularFile == true,
                  plainDocumentExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard documents.count < maximumSourceFiles else {
                throw ProjectInstructionQueueError.invalidRequest("Instruction package contains too many documents.")
            }
            let relative = try relativePath(url, root: root)
            documents.append((relative, try readRegularFile(url)))
        }
        documents.sort { $0.0 < $1.0 }
        guard !documents.isEmpty else { throw ProjectInstructionQueueError.sourceTypeUnsupported }
        var missionParts: [String] = []
        missionParts.reserveCapacity(documents.count)
        for (path, data) in documents {
            missionParts.append("# \(path)\n\n\(try decodedDocument(data))")
        }
        let mission = try boundedMission(missionParts.joined(separator: "\n\n"))
        return try makePackage(
            packageID: slug(root.lastPathComponent), version: "1",
            displayName: root.lastPathComponent, mission: mission, sourcePath: root.path,
            allowedTools: ordinaryDefaultAllowedTools, completionGates: [builtInCompletionGate],
            documents: documents
        )
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
        var documents: [(String, Data)] = [(manifestURL.lastPathComponent, data)]
        var mission = manifest.mission
        for entry in manifest.entryDocuments {
            guard validRelativePath(entry) else {
                throw ProjectInstructionQueueError.manifestInvalid("entry document path is invalid")
            }
            let url = root.appendingPathComponent(entry).standardizedFileURL
            guard try relativePath(url, root: root) == entry else {
                throw ProjectInstructionQueueError.manifestInvalid("entry document escapes the package root")
            }
            let content = try readRegularFile(url)
            documents.append((entry, content))
            mission += "\n\n# \(entry)\n\n\(try decodedDocument(content))"
        }
        return try makePackage(
            packageID: manifest.packageID, version: manifest.version,
            displayName: manifest.packageID, mission: try boundedMission(mission),
            sourcePath: root.path, allowedTools: manifest.requestedCapabilities,
            completionGates: manifest.completionGateStrings, documents: documents
        )
    }

    private static func makePackage(
        packageID: String,
        version: String,
        displayName: String,
        mission: String,
        sourcePath: String,
        allowedTools: [String],
        completionGates: [String],
        documents: [(String, Data)]
    ) throws -> IngestedPackage {
        let total = documents.reduce(0) { $0 + $1.1.count }
        guard total <= maximumAggregateBytes else {
            throw ProjectInstructionQueueError.invalidRequest("Instruction package exceeds the \(maximumAggregateBytes)-byte limit.")
        }
        let manifest: [[String: Any]] = documents.sorted(by: { $0.0 < $1.0 }).map {
            ["path": $0.0, "bytes": $0.1.count, "sha256": JSONSupport.sha256Hex($0.1)]
        }
        let identity: [String: Any] = [
            "package_id": packageID, "version": version, "mission": mission,
            "allowed_tools": allowedTools, "completion_gates": completionGates,
            "documents": manifest,
        ]
        let digest = JSONSupport.sha256Hex(
            try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys, .withoutEscapingSlashes])
        )
        return IngestedPackage(
            packageID: packageID, version: version, displayName: displayName,
            mission: mission, sourcePath: sourcePath, digest: digest,
            allowedTools: allowedTools, completionGates: completionGates, documents: documents
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
            for (relative, data) in package.documents {
                let target = staging.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try data.write(to: target, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
            }
            let receipt: [String: Any] = [
                "schema_version": 1, "content_sha256": package.digest,
                "package_id": package.packageID, "version": package.version,
                "document_count": package.documents.count,
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

    private static func storedSnapshotCount(_ root: URL) throws -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { throw ProjectInstructionQueueError.storageFailure("instruction snapshot storage is unavailable") }
        var count = 0
        while enumerator.nextObject() != nil {
            count += 1
            if count > maximumStoredSnapshots { break }
        }
        return count
    }

    private static func readRegularFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw ProjectInstructionQueueError.sourceContainsLink }
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size >= 0,
              size <= maximumSourceFileBytes else {
            throw ProjectInstructionQueueError.invalidRequest("Instruction documents must be regular files no larger than \(maximumSourceFileBytes) bytes.")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == size else { throw ProjectInstructionQueueError.sourceUnavailable }
        return data
    }

    private static func boundedMission(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumMissionBytes else {
            throw ProjectInstructionQueueError.invalidRequest("Package instructions must contain 1 through \(maximumMissionBytes) UTF-8 bytes.")
        }
        return trimmed
    }

    private static func decodedDocument(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw ProjectInstructionQueueError.invalidRequest(
                "Instruction documents must contain valid UTF-8 text."
            )
        }
        return value
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

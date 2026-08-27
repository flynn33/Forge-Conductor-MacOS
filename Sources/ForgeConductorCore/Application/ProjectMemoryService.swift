// ProjectMemoryService.swift
// What: Resolves durable project identity and applies memory validation, redaction, and budgets.
// How: A bounded repository cache opens isolated project databases under application support.
// Why: MCP callers need one policy boundary that cannot cross project stores by path confusion.

import Foundation
import Darwin

private struct ProjectRegistryFile: Codable {
    var schemaVersion: Int
    var projects: [ProjectRegistryEntry]
}

private struct ProjectRegistryEntry: Codable {
    var id: String
    var displayName: String
    var repositoryIdentity: String?
    var aliases: [String]
    var createdAt: String
    var updatedAt: String
}

private struct ProjectIdentityUpdateIntent: Codable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var projectID: String
    var intendedMetadata: Data
    var intendedRegistry: Data
    var previousMetadata: Data?
    var previousMetadataPermissions: UInt16?
    var metadataDirectoryExisted: Bool
}

enum ProjectIdentityPersistenceInterruption: Error {
    case afterMetadataWrite
}

private enum ProjectMemoryFileReadError: Error {
    case unreadable
    case tooLarge
}

private enum ProjectMemoryFileReader {
    static func read(
        _ url: URL,
        maximumBytes: Int,
        cancellation: ToolCallCancellation?
    ) throws -> Data {
        try cancellation?.checkCancellation()
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw ProjectMemoryFileReadError.unreadable }
        defer { _ = Darwin.close(descriptor) }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            throw ProjectMemoryFileReadError.unreadable
        }
        guard information.st_size >= 0,
              information.st_size <= maximumBytes else {
            throw ProjectMemoryFileReadError.tooLarge
        }

        var data = Data()
        data.reserveCapacity(min(Int(information.st_size), maximumBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count <= maximumBytes {
            try cancellation?.checkCancellation()
            let remaining = maximumBytes + 1 - data.count
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw ProjectMemoryFileReadError.unreadable
        }
        guard data.count <= maximumBytes else {
            throw ProjectMemoryFileReadError.tooLarge
        }
        try cancellation?.checkCancellation()
        return data
    }
}

public final class ProjectIdentityResolver: @unchecked Sendable {
    private static let maximumRegistryBytes = 4 * 1_024 * 1_024
    private static let maximumGitConfigBytes = 1 * 1_024 * 1_024
    private struct MetadataSnapshot {
        let directory: URL
        let metadataURL: URL
        let directoryExisted: Bool
        let data: Data?
        let permissions: mode_t?
    }

    private let paths: AppPaths
    private let lock = NSLock()
    private let clock: any Clock
    private let afterMetadataWriteObserver: (@Sendable () throws -> Void)?
    private let didRegistryCommitObserver: (@Sendable () -> Void)?

    private var updateIntentURL: URL {
        paths.projectsDir.appendingPathComponent(".identity-update.json")
    }

    public convenience init(paths: AppPaths, clock: any Clock = SystemClock()) {
        self.init(
            paths: paths,
            clock: clock,
            afterMetadataWriteObserver: nil,
            didRegistryCommitObserver: nil
        )
    }

    init(
        paths: AppPaths,
        clock: any Clock,
        afterMetadataWriteObserver: (@Sendable () throws -> Void)?,
        didRegistryCommitObserver: (@Sendable () -> Void)?
    ) {
        self.paths = paths
        self.clock = clock
        self.afterMetadataWriteObserver = afterMetadataWriteObserver
        self.didRegistryCommitObserver = didRegistryCommitObserver
    }

    public func initialize(
        path rawPath: String,
        projectID requestedID: String?,
        displayName: String?,
        repositoryIdentity suppliedRepositoryIdentity: String?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectMemoryDescriptor {
        try cancellation?.checkCancellation()
        let canonical = try canonicalDirectory(rawPath, cancellation: cancellation)
        let repositoryIdentity = try normalized(suppliedRepositoryIdentity)
            ?? inferredRepositoryIdentity(canonical, cancellation: cancellation)
        return try withRegistryLock(cancellation: cancellation) {
            try recoverPendingIdentityUpdate(cancellation: cancellation)
            var registry = try loadRegistry(cancellation: cancellation)
            try cancellation?.checkCancellation()
            let now = ISO8601.string(from: clock.now())
            let requested = normalized(requestedID)
            if let requested, UUID(uuidString: requested) == nil {
                throw ProjectMemoryError.invalidRequest("project_id must be a UUID")
            }

            var index: Int?
            if let requested {
                index = registry.projects.firstIndex { $0.id.caseInsensitiveCompare(requested) == .orderedSame }
                guard index != nil else { throw ProjectMemoryError.projectNotFound(requested) }
            } else if let repositoryIdentity {
                index = registry.projects.firstIndex { $0.repositoryIdentity == repositoryIdentity }
            }
            if index == nil {
                index = registry.projects.firstIndex { $0.aliases.contains(canonical.path) }
            }

            if let index {
                var entry = registry.projects[index]
                if let repositoryIdentity, let existing = entry.repositoryIdentity,
                   existing != repositoryIdentity {
                    throw ProjectMemoryError.projectScopeMismatch
                }
                if !entry.aliases.contains(canonical.path) { entry.aliases.append(canonical.path) }
                entry.aliases = Array(entry.aliases.suffix(32))
                if entry.repositoryIdentity == nil { entry.repositoryIdentity = repositoryIdentity }
                if let name = normalized(displayName) { entry.displayName = name }
                entry.updatedAt = now
                registry.projects[index] = entry
                try cancellation?.checkCancellation()
                try persistIdentityUpdate(
                    entry: entry,
                    registry: registry,
                    cancellation: cancellation
                )
                return descriptor(entry)
            }

            let id = UUID().uuidString.lowercased()
            let entry = ProjectRegistryEntry(
                id: id,
                displayName: normalized(displayName) ?? canonical.lastPathComponent,
                repositoryIdentity: repositoryIdentity,
                aliases: [canonical.path],
                createdAt: now,
                updatedAt: now
            )
            registry.projects.append(entry)
            try cancellation?.checkCancellation()
            try persistIdentityUpdate(
                entry: entry,
                registry: registry,
                cancellation: cancellation
            )
            return descriptor(entry)
        }
    }

    public func descriptor(
        projectID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectMemoryDescriptor {
        try withRegistryLock(cancellation: cancellation) {
            try recoverPendingIdentityUpdate(cancellation: cancellation)
            try cancellation?.checkCancellation()
            let registry = try loadRegistry(cancellation: cancellation)
            guard let entry = registry.projects.first(where: { $0.id == projectID }) else {
                throw ProjectMemoryError.projectNotFound(projectID)
            }
            return descriptor(entry)
        }
    }

    public func projectDirectory(
        projectID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> URL {
        _ = try descriptor(projectID: projectID, cancellation: cancellation)
        try cancellation?.checkCancellation()
        let directory = paths.projectsDir.appendingPathComponent(projectID, isDirectory: true).standardizedFileURL
        guard directory.deletingLastPathComponent() == paths.projectsDir.standardizedFileURL else {
            throw ProjectMemoryError.projectScopeMismatch
        }
        return directory
    }

    private func canonicalDirectory(
        _ rawPath: String,
        cancellation: ToolCallCancellation?
    ) throws -> URL {
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectMemoryError.invalidRequest("project_path is required")
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectMemoryError.invalidRequest("project_path must name an existing directory")
        }
        try cancellation?.checkCancellation()
        return url
    }

    private func inferredRepositoryIdentity(
        _ project: URL,
        cancellation: ToolCallCancellation?
    ) throws -> String? {
        let config = project.appendingPathComponent(".git/config")
        let data: Data
        do {
            data = try ProjectMemoryFileReader.read(
                config,
                maximumBytes: Self.maximumGitConfigBytes,
                cancellation: cancellation
            )
        } catch ProjectMemoryFileReadError.unreadable {
            return nil
        } catch ProjectMemoryFileReadError.tooLarge {
            throw ProjectMemoryError.payloadTooLarge("Git configuration exceeds 1 MiB")
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var remotes: [String] = []
        for line in text.split(separator: "\n") {
            try cancellation?.checkCancellation()
            let normalized = line.trimmingCharacters(in: .whitespaces)
            if normalized.hasPrefix("url =") { remotes.append(normalized) }
        }
        remotes.sort()
        guard !remotes.isEmpty else { return nil }
        return "git:" + JSONSupport.sha256Hex(remotes.joined(separator: "\n"))
    }

    private func loadRegistry(
        cancellation: ToolCallCancellation?
    ) throws -> ProjectRegistryFile {
        guard FileManager.default.fileExists(atPath: paths.projectRegistry.path) else {
            return ProjectRegistryFile(schemaVersion: 1, projects: [])
        }
        let data: Data
        do {
            data = try ProjectMemoryFileReader.read(
                paths.projectRegistry,
                maximumBytes: Self.maximumRegistryBytes,
                cancellation: cancellation
            )
        } catch ProjectMemoryFileReadError.tooLarge {
            throw ProjectMemoryError.payloadTooLarge("project registry exceeds 4 MiB")
        } catch ProjectMemoryFileReadError.unreadable {
            throw ProjectMemoryError.invalidRequest("project registry is not a readable regular file")
        }
        let registry = try JSONDecoder().decode(ProjectRegistryFile.self, from: data)
        guard registry.schemaVersion == 1 else {
            throw ProjectMemoryError.unsupportedVersion(registry.schemaVersion)
        }
        return registry
    }

    private func persistIdentityUpdate(
        entry: ProjectRegistryEntry,
        registry: ProjectRegistryFile,
        cancellation: ToolCallCancellation?
    ) throws {
        let snapshot = try metadataSnapshot(for: entry, cancellation: cancellation)
        let intendedMetadata = try JSONEncoder.sorted.encode(entry)
        let intendedRegistry = try JSONEncoder.sorted.encode(registry)
        guard intendedRegistry.count <= Self.maximumRegistryBytes else {
            throw ProjectMemoryError.payloadTooLarge("project registry exceeds 4 MiB")
        }
        let intent = ProjectIdentityUpdateIntent(
            schemaVersion: ProjectIdentityUpdateIntent.schemaVersion,
            projectID: entry.id,
            intendedMetadata: intendedMetadata,
            intendedRegistry: intendedRegistry,
            previousMetadata: snapshot.data,
            previousMetadataPermissions: snapshot.permissions.map { UInt16($0) },
            metadataDirectoryExisted: snapshot.directoryExisted
        )
        try cancellation?.checkCancellation()
        try OwnerOnlyAtomicFile.write(
            try JSONEncoder.sorted.encode(intent),
            to: updateIntentURL
        )
        do {
            try writeMetadataData(
                intendedMetadata,
                projectID: entry.id,
                cancellation: cancellation
            )
            try afterMetadataWriteObserver?()
            try cancellation?.checkCancellation()
            try OwnerOnlyAtomicFile.write(intendedRegistry, to: paths.projectRegistry)
        } catch is ProjectIdentityPersistenceInterruption {
            // Test-only interruption modeling leaves the durable intent in place so
            // the next resolver exercises the same recovery path as process death.
            throw ProjectIdentityPersistenceInterruption.afterMetadataWrite
        } catch {
            if registryDataMatches(intendedRegistry) {
                // rename(2) may have installed the registry even when the
                // following directory synchronization could not be confirmed.
                // The canonical bytes decide the result; never roll metadata
                // back behind an already visible registry commit.
                try OwnerOnlyAtomicFile.synchronizeDirectory(paths.projectsDir)
                didRegistryCommitObserver?()
                try OwnerOnlyAtomicFile.removeIfExists(at: updateIntentURL)
                return
            }
            do {
                try restoreMetadata(snapshot)
                try OwnerOnlyAtomicFile.removeIfExists(at: updateIntentURL)
            } catch let rollbackError {
                throw ProjectMemoryError.integrityFailure(
                    "project identity update failed and metadata rollback failed: \(rollbackError.localizedDescription)"
                )
            }
            throw error
        }
        // No cancellation check is allowed after the registry is durable. A
        // caller must observe the descriptor for the identity that now exists.
        didRegistryCommitObserver?()
        // A stale committed intent is harmless and is reconciled on the next
        // locked access. Cleanup failure must not hide the committed descriptor.
        try? OwnerOnlyAtomicFile.removeIfExists(at: updateIntentURL)
    }

    private func registryDataMatches(_ expected: Data) -> Bool {
        guard FileManager.default.fileExists(atPath: paths.projectRegistry.path) else {
            return false
        }
        return (try? OwnerOnlyAtomicFile.read(
            from: paths.projectRegistry,
            maximumBytes: Self.maximumRegistryBytes
        )) == expected
    }

    private func recoverPendingIdentityUpdate(
        cancellation: ToolCallCancellation?
    ) throws {
        guard FileManager.default.fileExists(atPath: updateIntentURL.path) else { return }
        try cancellation?.checkCancellation()
        let data: Data
        do {
            data = try OwnerOnlyAtomicFile.read(
                from: updateIntentURL,
                maximumBytes: Self.maximumRegistryBytes * 3
            )
        } catch {
            throw ProjectMemoryError.integrityFailure(
                "project identity update intent cannot be read"
            )
        }
        let intent: ProjectIdentityUpdateIntent
        do {
            intent = try JSONDecoder().decode(ProjectIdentityUpdateIntent.self, from: data)
        } catch {
            throw ProjectMemoryError.integrityFailure(
                "project identity update intent is invalid"
            )
        }
        guard intent.schemaVersion == ProjectIdentityUpdateIntent.schemaVersion,
              UUID(uuidString: intent.projectID) != nil,
              intent.intendedRegistry.count <= Self.maximumRegistryBytes,
              intent.intendedMetadata.count <= Self.maximumRegistryBytes else {
            throw ProjectMemoryError.integrityFailure(
                "project identity update intent is outside its bounds"
            )
        }

        let registryCommitted: Bool
        if FileManager.default.fileExists(atPath: paths.projectRegistry.path) {
            do {
                registryCommitted = try OwnerOnlyAtomicFile.read(
                    from: paths.projectRegistry,
                    maximumBytes: Self.maximumRegistryBytes
                ) == intent.intendedRegistry
            } catch {
                throw ProjectMemoryError.integrityFailure(
                    "project registry cannot be reconciled with its update intent"
                )
            }
        } else {
            registryCommitted = false
        }

        let directory = paths.projectsDir.appendingPathComponent(
            intent.projectID,
            isDirectory: true
        )
        let metadataURL = directory.appendingPathComponent("project.json")
        if registryCommitted {
            try writeMetadataData(
                intent.intendedMetadata,
                projectID: intent.projectID,
                cancellation: nil
            )
        } else if let previousMetadata = intent.previousMetadata {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try OwnerOnlyAtomicFile.write(previousMetadata, to: metadataURL)
            if let permissions = intent.previousMetadataPermissions {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: permissions)],
                    ofItemAtPath: metadataURL.path
                )
            }
        } else {
            try OwnerOnlyAtomicFile.removeIfExists(at: metadataURL)
            if !intent.metadataDirectoryExisted,
               FileManager.default.fileExists(atPath: directory.path),
               try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
                try FileManager.default.removeItem(at: directory)
                try OwnerOnlyAtomicFile.synchronizeDirectory(paths.projectsDir)
            }
        }
        try OwnerOnlyAtomicFile.removeIfExists(at: updateIntentURL)
    }

    private func writeMetadataData(
        _ data: Data,
        projectID: String,
        cancellation: ToolCallCancellation?
    ) throws {
        try cancellation?.checkCancellation()
        guard UUID(uuidString: projectID) != nil else {
            throw ProjectMemoryError.invalidRequest("project_id must be a UUID")
        }
        let directory = paths.projectsDir.appendingPathComponent(projectID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try cancellation?.checkCancellation()
        try OwnerOnlyAtomicFile.write(data, to: directory.appendingPathComponent("project.json"))
    }

    private func metadataSnapshot(
        for entry: ProjectRegistryEntry,
        cancellation: ToolCallCancellation?
    ) throws -> MetadataSnapshot {
        try cancellation?.checkCancellation()
        let directory = paths.projectsDir.appendingPathComponent(entry.id, isDirectory: true)
        let metadataURL = directory.appendingPathComponent("project.json")

        var directoryInformation = stat()
        let directoryResult = directory.path.withCString {
            Darwin.lstat($0, &directoryInformation)
        }
        let directoryExisted: Bool
        if directoryResult == 0 {
            guard directoryInformation.st_mode & S_IFMT == S_IFDIR else {
                throw ProjectMemoryError.integrityFailure(
                    "project identity directory is not a directory"
                )
            }
            directoryExisted = true
        } else {
            guard errno == ENOENT else {
                throw ProjectMemoryError.integrityFailure(
                    "project identity directory cannot be inspected"
                )
            }
            directoryExisted = false
        }

        var metadataInformation = stat()
        let metadataResult = metadataURL.path.withCString {
            Darwin.lstat($0, &metadataInformation)
        }
        if metadataResult == 0 {
            guard metadataInformation.st_mode & S_IFMT == S_IFREG else {
                throw ProjectMemoryError.integrityFailure(
                    "project identity metadata is not a regular file"
                )
            }
            let data: Data
            do {
                data = try ProjectMemoryFileReader.read(
                    metadataURL,
                    maximumBytes: Self.maximumRegistryBytes,
                    cancellation: cancellation
                )
            } catch ProjectMemoryFileReadError.unreadable {
                throw ProjectMemoryError.integrityFailure(
                    "project identity metadata cannot be snapshotted"
                )
            } catch ProjectMemoryFileReadError.tooLarge {
                throw ProjectMemoryError.integrityFailure(
                    "project identity metadata cannot be snapshotted"
                )
            }
            return MetadataSnapshot(
                directory: directory,
                metadataURL: metadataURL,
                directoryExisted: directoryExisted,
                data: data,
                permissions: metadataInformation.st_mode & 0o777
            )
        }
        guard errno == ENOENT else {
            throw ProjectMemoryError.integrityFailure(
                "project identity metadata cannot be inspected"
            )
        }
        return MetadataSnapshot(
            directory: directory,
            metadataURL: metadataURL,
            directoryExisted: directoryExisted,
            data: nil,
            permissions: nil
        )
    }

    private func restoreMetadata(_ snapshot: MetadataSnapshot) throws {
        let fileManager = FileManager.default
        if let data = snapshot.data {
            try fileManager.createDirectory(
                at: snapshot.directory,
                withIntermediateDirectories: true
            )
            try OwnerOnlyAtomicFile.write(data, to: snapshot.metadataURL)
            if let permissions = snapshot.permissions {
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: permissions)],
                    ofItemAtPath: snapshot.metadataURL.path
                )
            }
            return
        }

        var information = stat()
        let metadataResult = snapshot.metadataURL.path.withCString {
            Darwin.lstat($0, &information)
        }
        if metadataResult == 0 {
            guard information.st_mode & S_IFMT == S_IFREG else {
                throw ProjectMemoryError.integrityFailure(
                    "new project identity metadata changed type before rollback"
                )
            }
            try OwnerOnlyAtomicFile.removeIfExists(at: snapshot.metadataURL)
        } else if errno != ENOENT {
            throw ProjectMemoryError.integrityFailure(
                "new project identity metadata cannot be inspected for rollback"
            )
        }

        if !snapshot.directoryExisted,
           fileManager.fileExists(atPath: snapshot.directory.path),
           try fileManager.contentsOfDirectory(atPath: snapshot.directory.path).isEmpty {
            try fileManager.removeItem(at: snapshot.directory)
            try OwnerOnlyAtomicFile.synchronizeDirectory(paths.projectsDir)
        }
    }

    private func withRegistryLock<T>(
        cancellation: ToolCallCancellation?,
        _ body: () throws -> T
    ) throws -> T {
        while !lock.lock(before: Date().addingTimeInterval(0.01)) {
            try cancellation?.checkCancellation()
        }
        defer { lock.unlock() }
        try cancellation?.checkCancellation()
        let lockURL = paths.projectsDir.appendingPathComponent(".registry.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ProjectMemoryError.databaseBusy }
        defer { Darwin.close(descriptor) }
        let busyLimit = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw ProjectMemoryError.databaseBusy
            }
            try cancellation?.checkCancellation()
            guard DispatchTime.now().uptimeNanoseconds < busyLimit else {
                throw ProjectMemoryError.databaseBusy
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { flock(descriptor, LOCK_UN) }
        try cancellation?.checkCancellation()
        return try body()
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func descriptor(_ entry: ProjectRegistryEntry) -> ProjectMemoryDescriptor {
        ProjectMemoryDescriptor(
            id: entry.id, displayName: entry.displayName,
            repositoryIdentity: entry.repositoryIdentity, aliases: entry.aliases
        )
    }
}

public struct ProjectMemoryRedactor: Sendable {
    private static let patterns: [String] = [
        #"(?i)authorization:\s*(bearer|basic)\s+[A-Za-z0-9._~+\-/=]+"#,
        #"\bsk-[A-Za-z0-9_-]{16,}\b"#,
        #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#,
        #"\bAKIA[A-Z0-9]{16}\b"#,
        #"(?i)\b(api[_-]?key|access[_-]?token|secret|password)\s*[:=]\s*[^\s,;]+"#,
    ]

    public init() {}

    public func redact(_ value: String?) throws -> String? {
        guard var output = value else { return nil }
        if output.contains("-----BEGIN PRIVATE KEY-----") || output.contains("-----BEGIN OPENSSH PRIVATE KEY-----") { // Redaction patterns.
            throw ProjectMemoryError.redactionRejected("private key material is not accepted")
        }
        for pattern in Self.patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: "<redacted>")
        }
        return output
    }
}

public final class ProjectMemoryService: @unchecked Sendable {
    public static let capabilityVersion = 1
    private static let maximumImportArtifactBytes = 40 * 1_024 * 1_024
    public let limits: ProjectMemoryLimits
    public let identities: ProjectIdentityResolver
    private let paths: AppPaths
    private let clock: any Clock
    private let beforeContinuityProjectionWriteObserver: (@Sendable (String, String, String) -> Void)?
    private let beforeExportCommitObserver: (@Sendable () -> Void)?
    private let didMutationCommitObserver: (@Sendable () -> Void)?
    private let redactor = ProjectMemoryRedactor()
    private let lock = NSLock()
    private var repositories: [String: ProjectMemoryRepository] = [:]
    private var repositoryOrder: [String] = []

    public convenience init(
        paths: AppPaths,
        clock: any Clock = SystemClock(),
        limits: ProjectMemoryLimits = .current
    ) {
        self.init(
            paths: paths,
            clock: clock,
            limits: limits,
            afterIdentityMetadataWriteObserver: nil,
            didIdentityRegistryCommitObserver: nil,
            beforeContinuityProjectionWriteObserver: nil,
            beforeExportCommitObserver: nil,
            didMutationCommitObserver: nil
        )
    }

    init(
        paths: AppPaths,
        clock: any Clock,
        limits: ProjectMemoryLimits,
        afterIdentityMetadataWriteObserver: (@Sendable () throws -> Void)?,
        didIdentityRegistryCommitObserver: (@Sendable () -> Void)?,
        beforeContinuityProjectionWriteObserver: (@Sendable (String, String, String) -> Void)? = nil,
        beforeExportCommitObserver: (@Sendable () -> Void)? = nil,
        didMutationCommitObserver: (@Sendable () -> Void)? = nil
    ) {
        self.paths = paths
        self.clock = clock
        self.limits = limits
        self.beforeContinuityProjectionWriteObserver = beforeContinuityProjectionWriteObserver
        self.beforeExportCommitObserver = beforeExportCommitObserver
        self.didMutationCommitObserver = didMutationCommitObserver
        self.identities = ProjectIdentityResolver(
            paths: paths,
            clock: clock,
            afterMetadataWriteObserver: afterIdentityMetadataWriteObserver,
            didRegistryCommitObserver: didIdentityRegistryCommitObserver
        )
    }

    deinit { closeAll() }

    public func closeAll() {
        lock.lock()
        let values = Array(repositories.values)
        repositories.removeAll()
        repositoryOrder.removeAll()
        lock.unlock()
        values.forEach { $0.close() }
    }

    public func closeProject(_ projectID: String) {
        lock.lock()
        let repository = repositories.removeValue(forKey: projectID)
        repositoryOrder.removeAll { $0 == projectID }
        lock.unlock()
        repository?.close()
    }

    public func initialize(
        path: String,
        projectID: String? = nil,
        displayName: String? = nil,
        repositoryIdentity: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        let descriptor = try identities.initialize(
            path: path, projectID: projectID, displayName: displayName,
            repositoryIdentity: repositoryIdentity, cancellation: cancellation
        )
        // Identity metadata and the registry are now durable. Opening the
        // project database must not turn a late transport cancellation into a
        // false report that initialization had no effect.
        let projectDirectory = paths.projectsDir
            .appendingPathComponent(descriptor.id, isDirectory: true)
            .standardizedFileURL
        guard projectDirectory.deletingLastPathComponent()
                == paths.projectsDir.standardizedFileURL else {
            throw ProjectMemoryError.projectScopeMismatch
        }
        let repository = try self.repository(
            projectID: descriptor.id,
            directory: projectDirectory,
            cancellation: nil
        )
        return [
            "ok": true,
            "project_id": descriptor.id,
            "schema_version": ProjectMemoryRepository.schemaVersion,
            "capability_version": Self.capabilityVersion,
            "capabilities": ["lexical_search", "transactions", "redaction", "exports", repository.supportsFTS5 ? "fts5" : "bounded_sql_fallback"],
            "limits": limits.asDictionary(),
            "migration_status": "current",
            "project": descriptor.asDictionary(),
        ]
    }

    public func remember(
        projectID: String,
        write: ProjectMemoryWrite,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        let validated = try validate(write)
        try cancellation?.checkCancellation()
        let (record, disposition) = try repository(
            projectID: projectID,
            cancellation: cancellation
        ).remember(
            validated,
            cancellation: cancellation,
            commitReceipt: { [self] committed in
                ToolResult.success(writeResult(
                    committed.0,
                    disposition: committed.1
                ))
            }
        )
        return writeResult(record, disposition: disposition)
    }

    public func rememberBatch(
        projectID: String,
        writes: [ProjectMemoryWrite],
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        guard !writes.isEmpty, writes.count <= limits.maximumBatchCount else {
            throw ProjectMemoryError.payloadTooLarge("batch count exceeds \(limits.maximumBatchCount)")
        }
        var validated: [ProjectMemoryWrite] = []
        validated.reserveCapacity(writes.count)
        for write in writes {
            try cancellation?.checkCancellation()
            validated.append(try validate(write))
        }
        let encodedBytes = validated.reduce(0) { total, item in
            total + item.title.utf8.count + item.summary.utf8.count + (item.body?.utf8.count ?? 0)
        }
        guard encodedBytes <= limits.maximumBatchBytes else {
            throw ProjectMemoryError.payloadTooLarge("batch bytes exceed \(limits.maximumBatchBytes)")
        }
        try cancellation?.checkCancellation()
        let resultPayload: ([(ProjectMemoryRecord, String)]) -> [String: Any] = { results in
            [
                "ok": true,
                "project_id": projectID,
                "count": results.count,
                "results": results.map { self.writeResult($0.0, disposition: $0.1) },
                "schema_version": ProjectMemoryRepository.schemaVersion,
                "capability_version": Self.capabilityVersion,
            ]
        }
        let results = try repository(
            projectID: projectID,
            cancellation: cancellation
        ).rememberBatch(
            validated,
            cancellation: cancellation,
            commitReceipt: { ToolResult.success(resultPayload($0)) }
        )
        return resultPayload(results)
    }

    public func get(
        projectID: String,
        ids: [String],
        includeBody: Bool,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        guard !ids.isEmpty, ids.count <= limits.maximumPageCount else {
            throw ProjectMemoryError.invalidRequest("ids must contain 1...\(limits.maximumPageCount) values")
        }
        let records = try repository(projectID: projectID, cancellation: cancellation).get(
            ids: ids,
            includeBody: includeBody,
            maximumCount: limits.maximumPageCount,
            cancellation: cancellation
        )
        return envelope(projectID: projectID, records: records.map { $0.asDictionary(includeBody: includeBody) })
    }

    public func update(
        projectID: String,
        id: String,
        expectedVersion: Int,
        title: String?, summary: String?, body: String?, tags: [String]?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        if let title { try requireBytes(title, maximum: limits.maximumTitleBytes, field: "title") }
        if let summary { try requireBytes(summary, maximum: limits.maximumSummaryBytes, field: "summary") }
        if let body { try requireBytes(body, maximum: limits.maximumBodyBytes, field: "body") }
        let redactedTitle = try redactor.redact(title)
        let redactedSummary = try redactor.redact(summary)
        let redactedBody = try redactor.redact(body)
        let normalizedTags = try tags.map(normalizeTags)
        try cancellation?.checkCancellation()
        let resultPayload: (ProjectMemoryRecord) -> [String: Any] = { record in
            [
                "ok": true,
                "record": record.asDictionary(includeBody: true),
                "schema_version": ProjectMemoryRepository.schemaVersion,
            ]
        }
        let record = try repository(projectID: projectID, cancellation: cancellation).update(
            id: id,
            expectedVersion: expectedVersion,
            title: redactedTitle,
            summary: redactedSummary,
            body: redactedBody,
            tags: normalizedTags,
            cancellation: cancellation,
            commitReceipt: { ToolResult.success(resultPayload($0)) }
        )
        return resultPayload(record)
    }

    public func forget(
        projectID: String,
        id: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        let resultPayload: (Bool) -> [String: Any] = { deleted in
            [
                "ok": true,
                "project_id": projectID,
                "record_id": id,
                "disposition": deleted ? "tombstoned" : "not_found",
            ]
        }
        let deleted = try repository(projectID: projectID, cancellation: cancellation).forget(
            id: id,
            cancellation: cancellation,
            commitReceipt: { ToolResult.success(resultPayload($0)) }
        )
        return resultPayload(deleted)
    }

    public func link(
        projectID: String,
        sourceID: String,
        targetID: String,
        relation: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        let normalizedRelation = relation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRelation.isEmpty, normalizedRelation.utf8.count <= 128 else {
            throw ProjectMemoryError.invalidRequest("relation must contain 1...128 bytes")
        }
        let resultPayload: (Bool) -> [String: Any] = { inserted in
            [
                "ok": true,
                "project_id": projectID,
                "disposition": inserted ? "inserted" : "deduplicated",
            ]
        }
        let inserted = try repository(projectID: projectID, cancellation: cancellation).link(
            sourceID: sourceID,
            targetID: targetID,
            relation: normalizedRelation,
            cancellation: cancellation,
            commitReceipt: { ToolResult.success(resultPayload($0)) }
        )
        return resultPayload(inserted)
    }

    public func listRecent(
        projectID: String, kinds: [String], sessionID: String?, limit: Int, cursor: String?, includeBody: Bool,
        maximumResponseBytes: Int,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        let page = min(max(limit, 1), limits.maximumPageCount)
        let offset = try decodeCursor(cursor)
        let records = try repository(projectID: projectID, cancellation: cancellation).recent(
            kinds: kinds,
            sessionID: sessionID,
            limit: page + 1,
            offset: offset,
            cancellation: cancellation
        )
        return boundedPage(projectID: projectID, records: records.map { $0.asDictionary(includeBody: includeBody) }, offset: offset, requestedPage: page, maximumBytes: maximumResponseBytes)
    }

    public func search(
        projectID: String, query: String, kinds: [String], tags: [String], sessionID: String?,
        limit: Int, cursor: String?, includeBody: Bool, maximumResponseBytes: Int,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ProjectMemoryError.invalidRequest("query is required") }
        try requireBytes(normalized, maximum: limits.maximumQueryBytes, field: "query")
        let page = min(max(limit, 1), limits.maximumPageCount)
        let offset = try decodeCursor(cursor)
        let matches = try repository(projectID: projectID, cancellation: cancellation).search(
            query: normalized, kinds: kinds, tags: try normalizeTags(tags), sessionID: sessionID,
            limit: page + 1, offset: offset, cancellation: cancellation
        )
        let records = matches.map { $0.0.asDictionary(includeBody: includeBody, score: $0.1) }
        var output = boundedPage(projectID: projectID, records: records, offset: offset, requestedPage: page, maximumBytes: maximumResponseBytes)
        output["query"] = normalized
        output["ranking"] = ["exact_id", "exact_title", "lexical_title", "summary", "body", "importance", "confidence"]
        return output
    }

    public func status(
        projectID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        var status = try repository(projectID: projectID, cancellation: cancellation).status(
            cancellation: cancellation
        )
        status["ok"] = true
        status["capability_version"] = Self.capabilityVersion
        status["limits"] = limits.asDictionary()
        status["cache"] = ["open_repositories": openRepositoryCount, "maximum": limits.maximumOpenProjects]
        return status
    }

    public func export(
        projectID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        let repository = try repository(projectID: projectID, cancellation: cancellation)
        let records = try repository.exportRecords(cancellation: cancellation)
        let recordsData = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        try cancellation?.checkCancellation()
        guard recordsData.count <= 32 * 1024 * 1024 else {
            throw ProjectMemoryError.payloadTooLarge("export exceeds 32 MiB artifact limit")
        }
        let checksum = JSONSupport.sha256Hex(String(data: recordsData, encoding: .utf8) ?? "")
        let payload: [String: Any] = [
            "schema_version": ProjectMemoryRepository.schemaVersion,
            "project_id": projectID,
            "created_at": ISO8601.string(from: clock.now()),
            "checksum": checksum,
            "records": records,
        ]
        let exports = repository.directory.appendingPathComponent("exports", isDirectory: true)
        try cancellation?.checkCancellation()
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let artifact = exports.appendingPathComponent("memory-export-\(UUID().uuidString.lowercased()).json")
        let result: [String: Any] = [
            "ok": true,
            "project_id": projectID,
            "artifact": artifact.path,
            "checksum": checksum,
            "record_count": records.count,
        ]
        let artifactData = try JSONSupport.data(from: payload)
        try cancellation?.checkCancellation()
        beforeExportCommitObserver?()
        let publish = {
            try artifactData.write(to: artifact, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: artifact.path
            )
        }
        if let cancellation {
            try cancellation.withCommitAuthorization(
                committedResult: ToolResult.success(result),
                publish
            )
        } else {
            try publish()
        }
        return result
    }

    public func importRecords(
        projectID: String,
        artifactPath: String,
        preview: Bool,
        mergePolicy: String?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        let repository = try repository(projectID: projectID, cancellation: cancellation)
        let artifact = URL(fileURLWithPath: artifactPath).resolvingSymlinksInPath().standardizedFileURL
        let exports = repository.directory.appendingPathComponent("exports", isDirectory: true).standardizedFileURL
        guard artifact.pathComponents.starts(with: exports.pathComponents) else {
            throw ProjectMemoryError.projectScopeMismatch
        }
        try cancellation?.checkCancellation()
        let artifactData: Data
        do {
            artifactData = try ProjectMemoryFileReader.read(
                artifact,
                maximumBytes: Self.maximumImportArtifactBytes,
                cancellation: cancellation
            )
        } catch ProjectMemoryFileReadError.tooLarge {
            throw ProjectMemoryError.payloadTooLarge("import artifact exceeds 40 MiB")
        } catch ProjectMemoryFileReadError.unreadable {
            throw ProjectMemoryError.invalidRequest("import artifact is not a readable regular file")
        }
        let payload = try JSONSupport.object(from: artifactData)
        try cancellation?.checkCancellation()
        guard payload["schema_version"] as? Int == ProjectMemoryRepository.schemaVersion,
              let sourceProject = payload["project_id"] as? String,
              let records = payload["records"] as? [[String: Any]],
              let expectedChecksum = payload["checksum"] as? String else {
            throw ProjectMemoryError.invalidRequest("invalid export artifact")
        }
        let recordsData = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        try cancellation?.checkCancellation()
        let actualChecksum = JSONSupport.sha256Hex(String(data: recordsData, encoding: .utf8) ?? "")
        guard actualChecksum == expectedChecksum else { throw ProjectMemoryError.integrityFailure("export checksum mismatch") }
        guard records.count <= limits.maximumBatchCount else {
            throw ProjectMemoryError.payloadTooLarge("import exceeds \(limits.maximumBatchCount) records")
        }
        if sourceProject != projectID, mergePolicy != "merge" {
            throw ProjectMemoryError.projectScopeMismatch
        }
        var writes: [ProjectMemoryWrite] = []
        writes.reserveCapacity(min(records.count, limits.maximumBatchCount))
        for record in records.prefix(limits.maximumBatchCount) {
            try cancellation?.checkCancellation()
            writes.append(try writeFromExport(record))
        }
        if preview {
            try cancellation?.checkCancellation()
            return ["ok": true, "preview": true, "project_id": projectID, "record_count": records.count, "importable_count": writes.count, "checksum": actualChecksum]
        }
        return try rememberBatch(projectID: projectID, writes: writes, cancellation: cancellation)
    }

    public var openRepositoryCount: Int {
        lock.lock(); defer { lock.unlock() }
        return repositories.count
    }

    /// Shared durable adapter for continuity and maintenance components. The
    /// service still enforces project identity and its bounded repository cache.
    public func repositoryForProject(
        _ projectID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectMemoryRepository {
        try repository(projectID: projectID, cancellation: cancellation)
    }

    private func repository(
        projectID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectMemoryRepository {
        let directory = try identities.projectDirectory(
            projectID: projectID,
            cancellation: cancellation
        )
        return try repository(
            projectID: projectID,
            directory: directory,
            cancellation: cancellation
        )
    }

    private func repository(
        projectID: String,
        directory: URL,
        cancellation: ToolCallCancellation?
    ) throws -> ProjectMemoryRepository {
        try cancellation?.checkCancellation()
        try acquireRepositoryLock(cancellation: cancellation)
        if let existing = repositories[projectID] {
            repositoryOrder.removeAll { $0 == projectID }
            repositoryOrder.append(projectID)
            lock.unlock()
            return existing
        }
        lock.unlock()
        let created = try ProjectMemoryRepository(
            projectID: projectID,
            directory: directory,
            clock: clock,
            cancellation: cancellation,
            busyRetryObserver: nil,
            didMutationCommitObserver: didMutationCommitObserver,
            beforeMigrationCommitObserver: nil,
            rowStepObserver: nil,
            beforeContinuityProjectionWriteObserver: beforeContinuityProjectionWriteObserver
        )
        // Repository creation may have committed a schema migration. From that
        // point onward, finish publishing the opened repository without turning a
        // late cancellation into a false failure for an already committed store.
        lock.lock()
        if let raced = repositories[projectID] {
            lock.unlock(); created.close(); return raced
        }
        repositories[projectID] = created
        repositoryOrder.append(projectID)
        var evicted: ProjectMemoryRepository?
        if repositoryOrder.count > limits.maximumOpenProjects {
            let oldest = repositoryOrder.removeFirst()
            evicted = repositories.removeValue(forKey: oldest)
        }
        lock.unlock()
        evicted?.close()
        return created
    }

    private func acquireRepositoryLock(cancellation: ToolCallCancellation?) throws {
        while !lock.lock(before: Date().addingTimeInterval(0.01)) {
            try cancellation?.checkCancellation()
        }
        do {
            try cancellation?.checkCancellation()
        } catch {
            lock.unlock()
            throw error
        }
    }

    private func validate(_ write: ProjectMemoryWrite) throws -> ProjectMemoryWrite {
        let kind = write.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kind.isEmpty, kind.utf8.count <= 64,
              kind.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0) }) else {
            throw ProjectMemoryError.invalidRequest("kind must contain 1...64 identifier bytes")
        }
        let title = write.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = write.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !summary.isEmpty else { throw ProjectMemoryError.invalidRequest("title and summary are required") }
        try requireBytes(title, maximum: limits.maximumTitleBytes, field: "title")
        try requireBytes(summary, maximum: limits.maximumSummaryBytes, field: "summary")
        if let body = write.body { try requireBytes(body, maximum: limits.maximumBodyBytes, field: "body") }
        if let reference = write.sourceReference { try requireBytes(reference, maximum: limits.maximumSourceReferenceBytes, field: "source_reference") }
        guard (0...1).contains(write.importance), (0...1).contains(write.confidence) else {
            throw ProjectMemoryError.invalidRequest("importance and confidence must be within 0...1")
        }
        let tags = try normalizeTags(write.tags)
        return ProjectMemoryWrite(
            kind: kind, title: try redactor.redact(title) ?? title,
            summary: try redactor.redact(summary) ?? summary, body: try redactor.redact(write.body),
            tags: tags, importance: write.importance, confidence: write.confidence,
            sourceKind: write.sourceKind, sourceReference: try redactor.redact(write.sourceReference),
            sessionID: write.sessionID, expiresAt: write.expiresAt,
            relatedIDs: Array(write.relatedIDs.prefix(32)), idempotencyKey: write.idempotencyKey
        )
    }

    private func normalizeTags(_ tags: [String]) throws -> [String] {
        guard tags.count <= limits.maximumTagCount else { throw ProjectMemoryError.payloadTooLarge("too many tags") }
        var output: [String] = []
        for raw in tags {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !tag.isEmpty else { continue }
            try requireBytes(tag, maximum: limits.maximumTagBytes, field: "tag")
            if !output.contains(tag) { output.append(tag) }
        }
        return output.sorted()
    }

    private func requireBytes(_ value: String, maximum: Int, field: String) throws {
        guard value.utf8.count <= maximum else {
            throw ProjectMemoryError.payloadTooLarge("\(field) exceeds \(maximum) bytes")
        }
    }

    private func writeResult(_ record: ProjectMemoryRecord, disposition: String) -> [String: Any] {
        [
            "ok": true, "project_id": record.projectID, "record_id": record.id,
            "record_version": record.version, "disposition": disposition,
            "content_hash": record.contentHash, "schema_version": ProjectMemoryRepository.schemaVersion,
            "capability_version": Self.capabilityVersion,
        ]
    }

    private func envelope(projectID: String, records: [[String: Any]]) -> [String: Any] {
        ["ok": true, "project_id": projectID, "count": records.count, "records": records,
         "schema_version": ProjectMemoryRepository.schemaVersion, "capability_version": Self.capabilityVersion]
    }

    private func boundedPage(
        projectID: String, records: [[String: Any]], offset: Int, requestedPage: Int, maximumBytes: Int
    ) -> [String: Any] {
        let byteLimit = min(max(maximumBytes, 1024), limits.maximumResponseBytes)
        var accepted: [[String: Any]] = []
        var used = 256
        var truncated = records.count > requestedPage
        for record in records.prefix(requestedPage) {
            let size = (try? JSONSerialization.data(withJSONObject: record).count) ?? byteLimit
            if used + size > byteLimit { truncated = true; break }
            accepted.append(record); used += size
        }
        let nextOffset = offset + accepted.count
        return [
            "ok": true, "project_id": projectID, "count": accepted.count, "records": accepted,
            "next_cursor": truncated && !accepted.isEmpty ? encodeCursor(nextOffset) : NSNull(),
            "truncated": truncated, "encoded_bytes": used, "maximum_response_bytes": byteLimit,
            "schema_version": ProjectMemoryRepository.schemaVersion, "capability_version": Self.capabilityVersion,
        ]
    }

    private func encodeCursor(_ offset: Int) -> String { Data("v1:\(offset)".utf8).base64EncodedString() }

    private func decodeCursor(_ cursor: String?) throws -> Int {
        guard let cursor, !cursor.isEmpty else { return 0 }
        guard let data = Data(base64Encoded: cursor), let text = String(data: data, encoding: .utf8),
              text.hasPrefix("v1:"), let value = Int(text.dropFirst(3)), value >= 0 else {
            throw ProjectMemoryError.invalidRequest("invalid cursor")
        }
        return value
    }

    private func writeFromExport(_ object: [String: Any]) throws -> ProjectMemoryWrite {
        guard let kind = object["kind"] as? String, let title = object["title"] as? String,
              let summary = object["summary"] as? String else {
            throw ProjectMemoryError.invalidRequest("export record is missing required fields")
        }
        return ProjectMemoryWrite(
            kind: kind, title: title, summary: summary, body: object["body"] as? String,
            tags: object["tags"] as? [String] ?? [], importance: object["importance"] as? Double ?? 0.5,
            confidence: object["confidence"] as? Double ?? 1,
            sourceKind: object["source_kind"] as? String ?? "imported_artifact",
            sourceReference: object["source_reference"] as? String,
            sessionID: object["session_id"] as? String, expiresAt: object["expires_at"] as? String,
            idempotencyKey: "import:\(object["content_hash"] as? String ?? UUID().uuidString)"
        )
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

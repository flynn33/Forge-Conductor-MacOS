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

/// A registration intent retains the exact native manager request before the
/// first control row exists and while that row is fenced in maintenance. It is
/// non-authoritative and bounded to one file for the deterministic identifier.
private struct ProjectRegistrationIdentityIntent: Codable, Equatable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var operationID: String
    var projectID: String
    var requestedPath: String
    var requestedDisplayName: String?
    var repositoryIdentityAssertion: String?
    var resolvedDisplayName: String
    var canonicalRoot: String
    var repositoryIdentity: String?
    var directoryDevice: UInt64
    var directoryInode: UInt64
    var expectedControlGeneration: UInt64?
    var expectedControlLifecycleState: String?
    var expectedControlRepositoryIdentity: String?
    var createdAt: String
}

/// A relink intent is deliberately not part of the published project identity.
/// It bridges the project-memory and control-plane commits without granting the
/// candidate path alias authority before the generation compare-and-set wins.
private struct ProjectRelinkIdentityIntent: Codable, Equatable {
    static let schemaVersion = 2

    var schemaVersion: Int
    var operationID: String
    var projectID: String
    var expectedGeneration: UInt64
    var canonicalRoot: String
    var repositoryIdentity: String
    var directoryDevice: UInt64
    var directoryInode: UInt64
    var createdAt: String
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

final class ProjectIdentityResolver: @unchecked Sendable {
    private static let maximumRegistryBytes = 4 * 1_024 * 1_024
    private static let maximumGitConfigBytes = 1 * 1_024 * 1_024
    private static let maximumGitPointerBytes = 16 * 1_024
    private static let maximumGitControlPathBytes = 4_096
    private static let maximumRegistrationIntentBytes = 32 * 1_024
    private static let maximumRegistrationIntentDirectoryScanCount = 4_096
    private static let maximumRegistrationIntentProjectionCount = 100
    private static let maximumRelinkIntentBytes = 32 * 1_024
    private static let maximumRelinkPathBytes = 4_096
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
    private let beforeRelinkIntentRemovalObserver: (@Sendable () throws -> Void)?

    private var updateIntentURL: URL {
        paths.projectsDir.appendingPathComponent(".identity-update.json")
    }

    convenience init(paths: AppPaths, clock: any Clock = SystemClock()) {
        self.init(
            paths: paths,
            clock: clock,
            afterMetadataWriteObserver: nil,
            didRegistryCommitObserver: nil,
            beforeRelinkIntentRemovalObserver: nil
        )
    }

    init(
        paths: AppPaths,
        clock: any Clock,
        afterMetadataWriteObserver: (@Sendable () throws -> Void)?,
        didRegistryCommitObserver: (@Sendable () -> Void)?,
        beforeRelinkIntentRemovalObserver: (@Sendable () throws -> Void)? = nil
    ) {
        self.paths = paths
        self.clock = clock
        self.afterMetadataWriteObserver = afterMetadataWriteObserver
        self.didRegistryCommitObserver = didRegistryCommitObserver
        self.beforeRelinkIntentRemovalObserver = beforeRelinkIntentRemovalObserver
    }

    func initialize(
        path rawPath: String,
        projectID requestedID: String?,
        displayName: String?,
        repositoryIdentity suppliedRepositoryIdentity: String?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectMemoryDescriptor {
        let target = try discoverTarget(
            path: rawPath,
            repositoryIdentityAssertion: suppliedRepositoryIdentity,
            cancellation: cancellation
        )
        let preparation = try prepareRegistration(
            target: target,
            requestedProjectID: requestedID,
            displayName: displayName,
            allowUnregisteredRequestedID: false,
            cancellation: cancellation
        )
        return try commitRegistration(preparation, cancellation: cancellation)
    }

    func descriptor(
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

    /// Resolves caller-controlled path text once and independently derives its
    /// repository identity. The compatibility field is an assertion only.
    func discoverTarget(
        path rawPath: String,
        repositoryIdentityAssertion: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectIdentityTarget {
        try cancellation?.checkCancellation()
        let canonical = try canonicalDirectory(rawPath, cancellation: cancellation)
        let capturedIdentity = try directoryIdentity(canonical)
        let inferred = try inferredRepositoryIdentity(
            canonical,
            cancellation: cancellation
        )
        if let asserted = normalized(repositoryIdentityAssertion), asserted != inferred {
            throw ProjectMemoryError.projectScopeMismatch
        }
        try cancellation?.checkCancellation()
        guard try directoryIdentity(canonical) == capturedIdentity else {
            throw ProjectMemoryError.conflict(
                "project directory identity changed during discovery"
            )
        }
        return ProjectIdentityTarget(
            canonicalRoot: canonical,
            repositoryIdentity: inferred,
            directoryIdentity: capturedIdentity
        )
    }

    /// Builds a deterministic, read-only registration candidate. No registry
    /// alias or per-project metadata is written until `commitRegistration`.
    func prepareRegistration(
        target: ProjectIdentityTarget,
        requestedProjectID: String?,
        displayName: String?,
        allowUnregisteredRequestedID: Bool,
        expectedControlGeneration: ProjectGeneration? = nil,
        expectedControlLifecycleState: ProjectLifecycleState? = nil,
        expectedControlRepositoryIdentity: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectRegistrationIdentityPreparation {
        try validateTarget(target)
        return try withRegistryLock(cancellation: cancellation) {
            try recoverPendingIdentityUpdate(cancellation: cancellation)
            let registry = try loadRegistry(cancellation: cancellation)
            try cancellation?.checkCancellation()
            let requested = normalized(requestedProjectID)
            if let requested, UUID(uuidString: requested) == nil {
                throw ProjectMemoryError.invalidRequest("project_id must be a UUID")
            }

            let repositoryIndex = target.repositoryIdentity.flatMap { identity in
                registry.projects.firstIndex { $0.repositoryIdentity == identity }
            }
            let aliasIndex = registry.projects.firstIndex {
                $0.aliases.contains(target.canonicalRoot.path)
            }
            let requestedIndex = requested.flatMap { value in
                registry.projects.firstIndex {
                    $0.id.caseInsensitiveCompare(value) == .orderedSame
                }
            }
            if let requested, requestedIndex == nil, !allowUnregisteredRequestedID {
                throw ProjectMemoryError.projectNotFound(requested)
            }
            if let requestedIndex, let repositoryIndex, requestedIndex != repositoryIndex {
                throw ProjectMemoryError.projectScopeMismatch
            }
            if let requestedIndex, let aliasIndex, requestedIndex != aliasIndex {
                throw ProjectMemoryError.projectScopeMismatch
            }
            if let repositoryIndex, let aliasIndex, repositoryIndex != aliasIndex {
                throw ProjectMemoryError.projectScopeMismatch
            }

            let selectedIndex = requestedIndex ?? repositoryIndex ?? aliasIndex
            let selectedID = requested?.lowercased()
                ?? selectedIndex.map { registry.projects[$0].id }
                ?? Self.registrationProjectID(target: target)
            let existing = selectedIndex.map { registry.projects[$0] }
            if let existingIdentity = existing?.repositoryIdentity,
               existingIdentity != target.repositoryIdentity {
                throw ProjectMemoryError.projectScopeMismatch
            }
            if let selectedIndex,
               registry.projects.enumerated().contains(where: { candidate in
                   candidate.offset != selectedIndex
                       && candidate.element.aliases.contains(target.canonicalRoot.path)
               }) {
                throw ProjectMemoryError.projectScopeMismatch
            }
            if selectedIndex == nil,
               registry.projects.contains(where: {
                   $0.id.caseInsensitiveCompare(selectedID) == .orderedSame
                       || $0.aliases.contains(target.canonicalRoot.path)
                       || (target.repositoryIdentity != nil
                           && $0.repositoryIdentity == target.repositoryIdentity)
               }) {
                throw ProjectMemoryError.conflict(
                    "project registration identity changed during discovery"
                )
            }

            let descriptor = ProjectMemoryDescriptor(
                id: selectedID,
                displayName: normalized(displayName)
                    ?? existing?.displayName
                    ?? target.canonicalRoot.lastPathComponent,
                repositoryIdentity: target.repositoryIdentity,
                aliases: existing?.aliases ?? []
            )
            return ProjectRegistrationIdentityPreparation(
                operationID: Self.registrationOperationID(
                    descriptor: descriptor,
                    target: target,
                    expectedControlGeneration: expectedControlGeneration,
                    expectedControlLifecycleState: expectedControlLifecycleState,
                    expectedControlRepositoryIdentity: expectedControlRepositoryIdentity
                ),
                descriptor: descriptor,
                target: target,
                expectedControlGeneration: expectedControlGeneration,
                expectedControlLifecycleState: expectedControlLifecycleState,
                expectedControlRepositoryIdentity: expectedControlRepositoryIdentity
            )
        }
    }

    /// Retains one exact native-manager request before the control-plane stage.
    /// Repeating the identical request is a no-op; any different request for
    /// the same deterministic project identifier fails closed.
    func stageRegistrationIntent(
        _ preparation: ProjectRegistrationIdentityPreparation,
        requestedPath: String,
        requestedDisplayName: String?,
        repositoryIdentityAssertion: String?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> StagedProjectRegistrationIdentity {
        try validateTarget(preparation.target)
        guard !requestedPath.isEmpty,
              requestedPath.utf8.count <= Self.maximumRelinkPathBytes,
              (requestedPath as NSString).isAbsolutePath,
              requestedDisplayName.map({ $0.utf8.count <= 512 }) ?? true,
              repositoryIdentityAssertion.map({ $0.utf8.count <= 2_048 }) ?? true,
              repositoryIdentityAssertion.map({
                  normalized($0) == preparation.target.repositoryIdentity
              }) ?? true else {
            throw ProjectMemoryError.invalidRequest(
                "project registration intent is outside its request bounds"
            )
        }
        let intended = ProjectRegistrationIdentityIntent(
            schemaVersion: ProjectRegistrationIdentityIntent.schemaVersion,
            operationID: preparation.operationID,
            projectID: preparation.descriptor.id.lowercased(),
            requestedPath: requestedPath,
            requestedDisplayName: requestedDisplayName,
            repositoryIdentityAssertion: repositoryIdentityAssertion,
            resolvedDisplayName: preparation.descriptor.displayName,
            canonicalRoot: preparation.target.canonicalRoot.path,
            repositoryIdentity: preparation.target.repositoryIdentity,
            directoryDevice: preparation.target.directoryIdentity.device,
            directoryInode: preparation.target.directoryIdentity.inode,
            expectedControlGeneration: preparation.expectedControlGeneration?.rawValue,
            expectedControlLifecycleState: preparation.expectedControlLifecycleState?.rawValue,
            expectedControlRepositoryIdentity: preparation.expectedControlRepositoryIdentity,
            createdAt: ISO8601.string(from: clock.now())
        )
        return try withRegistryLock(cancellation: cancellation) {
            if let existing = try loadRegistrationIntentIfPresent(
                projectID: preparation.descriptor.id,
                cancellation: cancellation
            ) {
                guard Self.sameRegistration(existing, intended, ignoringCreatedAt: true) else {
                    throw ProjectMemoryError.conflict(
                        "another project registration request is pending"
                    )
                }
                let pending = try pendingRegistration(
                    intent: existing,
                    projectID: preparation.descriptor.id
                )
                return StagedProjectRegistrationIdentity(
                    pending: pending,
                    created: false
                )
            }
            try cancellation?.checkCancellation()
            try OwnerOnlyAtomicFile.write(
                try JSONEncoder.sorted.encode(intended),
                to: registrationIntentURL(projectID: preparation.descriptor.id)
            )
            let pending = try pendingRegistration(
                intent: intended,
                projectID: preparation.descriptor.id
            )
            return StagedProjectRegistrationIdentity(
                pending: pending,
                created: true
            )
        }
    }

    func pendingRegistration(
        projectID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> PendingProjectRegistrationIdentity? {
        try withRegistryLock(cancellation: cancellation) {
            guard let intent = try loadRegistrationIntentIfPresent(
                projectID: projectID,
                cancellation: cancellation
            ) else {
                return nil
            }
            return try pendingRegistration(intent: intent, projectID: projectID)
        }
    }

    /// Returns a bounded, non-authoritative recovery projection for registration
    /// intents that may not yet have a control-plane row. Directory enumeration is
    /// lazy and capped so a same-UID writer cannot turn an operator refresh into an
    /// unbounded scan. Each returned intent still passes the exact per-file schema,
    /// operation-authority, owner-only, size, and identity validation used by replay.
    func pendingRegistrations(
        limit: Int,
        excludingProjectIDs: Set<String> = [],
        cancellation: ToolCallCancellation? = nil
    ) throws -> [PendingProjectRegistrationIdentity] {
        guard (1...Self.maximumRegistrationIntentProjectionCount).contains(limit) else {
            throw ProjectMemoryError.invalidRequest(
                "project registration projection limit must be between 1 and 100"
            )
        }
        return try withRegistryLock(cancellation: cancellation) {
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: paths.projectsDir,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw ProjectMemoryError.integrityFailure(
                    "project registration intents cannot be enumerated"
                )
            }

            var scanned = 0
            var projectIDs = Set<String>()
            while let value = enumerator.nextObject() {
                try cancellation?.checkCancellation()
                scanned += 1
                guard scanned <= Self.maximumRegistrationIntentDirectoryScanCount else {
                    throw ProjectMemoryError.payloadTooLarge(
                        "project registration intent directory exceeds its scan bound"
                    )
                }
                guard let candidate = value as? URL,
                      candidate.deletingLastPathComponent().standardizedFileURL
                        == paths.projectsDir.standardizedFileURL else {
                    throw ProjectMemoryError.integrityFailure(
                        "project registration intent enumeration escaped its project root"
                    )
                }
                let projectID = candidate.lastPathComponent.lowercased()
                if UUID(uuidString: projectID) != nil {
                    projectIDs.insert(projectID)
                }
            }
            if enumerationError != nil {
                throw ProjectMemoryError.integrityFailure(
                    "project registration intents cannot be enumerated"
                )
            }

            var pending: [PendingProjectRegistrationIdentity] = []
            pending.reserveCapacity(min(limit, projectIDs.count))
            for projectID in projectIDs.sorted() {
                try cancellation?.checkCancellation()
                guard pending.count < limit else { break }
                guard !excludingProjectIDs.contains(projectID) else { continue }
                guard let intent = try loadRegistrationIntentIfPresent(
                    projectID: projectID,
                    cancellation: cancellation
                ) else {
                    continue
                }
                pending.append(try pendingRegistration(
                    intent: intent,
                    projectID: projectID
                ))
            }
            return pending
        }
    }

    private func pendingRegistration(
        intent: ProjectRegistrationIdentityIntent,
        projectID: String
    ) throws -> PendingProjectRegistrationIdentity {
        guard intent.projectID.caseInsensitiveCompare(projectID) == .orderedSame else {
            throw ProjectMemoryError.integrityFailure(
                "project registration intent changed project identity"
            )
        }
        let lifecycle = intent.expectedControlLifecycleState.flatMap(
            ProjectLifecycleState.init(rawValue:)
        )
        let target = ProjectIdentityTarget(
            canonicalRoot: URL(
                fileURLWithPath: intent.canonicalRoot,
                isDirectory: true
            ).standardizedFileURL,
            repositoryIdentity: intent.repositoryIdentity,
            directoryIdentity: ProjectDirectoryIdentity(
                device: intent.directoryDevice,
                inode: intent.directoryInode
            )
        )
        let preparation = ProjectRegistrationIdentityPreparation(
            operationID: intent.operationID,
            descriptor: ProjectMemoryDescriptor(
                id: intent.projectID,
                displayName: intent.resolvedDisplayName,
                repositoryIdentity: intent.repositoryIdentity,
                aliases: lifecycle == .active ? [intent.canonicalRoot] : []
            ),
            target: target,
            expectedControlGeneration: intent.expectedControlGeneration.map(
                { ProjectGeneration($0) }
            ),
            expectedControlLifecycleState: lifecycle,
            expectedControlRepositoryIdentity: intent.expectedControlRepositoryIdentity
        )
        return PendingProjectRegistrationIdentity(
            preparation: preparation,
            requestedPath: intent.requestedPath,
            requestedDisplayName: intent.requestedDisplayName,
            repositoryIdentityAssertion: intent.repositoryIdentityAssertion,
            createdAt: intent.createdAt
        )
    }

    func completeRegistrationIntent(
        _ preparation: ProjectRegistrationIdentityPreparation,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try removeRegistrationIntent(
            preparation,
            cancellation: cancellation
        )
    }

    func abortRegistrationIntent(
        _ preparation: ProjectRegistrationIdentityPreparation,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try removeRegistrationIntent(
            preparation,
            cancellation: cancellation
        )
    }

    /// Publishes the exact registration target after the control plane accepted
    /// the same project identifier, root, and independently inferred identity.
    func commitRegistration(
        _ preparation: ProjectRegistrationIdentityPreparation,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectMemoryDescriptor {
        try validateTarget(preparation.target)
        guard preparation.operationID == Self.registrationOperationID(
            descriptor: preparation.descriptor,
            target: preparation.target,
            expectedControlGeneration: preparation.expectedControlGeneration,
            expectedControlLifecycleState: preparation.expectedControlLifecycleState,
            expectedControlRepositoryIdentity: preparation.expectedControlRepositoryIdentity
        ) else {
            throw ProjectMemoryError.integrityFailure(
                "project registration preparation is invalid"
            )
        }
        return try withRegistryLock(cancellation: cancellation) {
            try recoverPendingIdentityUpdate(cancellation: cancellation)
            var registry = try loadRegistry(cancellation: cancellation)
            try cancellation?.checkCancellation()
            let id = preparation.descriptor.id
            let identity = preparation.target.repositoryIdentity
            let root = preparation.target.canonicalRoot.path
            let existingIndex = registry.projects.firstIndex {
                $0.id.caseInsensitiveCompare(id) == .orderedSame
            }
            guard !registry.projects.enumerated().contains(where: { candidate in
                candidate.offset != (existingIndex ?? -1)
                    && candidate.element.aliases.contains(root)
            }) else {
                throw ProjectMemoryError.projectScopeMismatch
            }
            if let identity {
                guard !registry.projects.enumerated().contains(where: { candidate in
                    candidate.offset != (existingIndex ?? -1)
                        && candidate.element.repositoryIdentity == identity
                }) else {
                    throw ProjectMemoryError.projectScopeMismatch
                }
            }

            let now = ISO8601.string(from: clock.now())
            let entry: ProjectRegistryEntry
            if let existingIndex {
                var updated = registry.projects[existingIndex]
                if let existingIdentity = updated.repositoryIdentity,
                   existingIdentity != identity {
                    throw ProjectMemoryError.projectScopeMismatch
                }
                if !updated.aliases.contains(root) { updated.aliases.append(root) }
                updated.aliases = Array(updated.aliases.suffix(32))
                if updated.repositoryIdentity == nil { updated.repositoryIdentity = identity }
                updated.displayName = preparation.descriptor.displayName
                updated.updatedAt = now
                registry.projects[existingIndex] = updated
                entry = updated
            } else {
                let inserted = ProjectRegistryEntry(
                    id: id,
                    displayName: preparation.descriptor.displayName,
                    repositoryIdentity: identity,
                    aliases: [root],
                    createdAt: now,
                    updatedAt: now
                )
                registry.projects.append(inserted)
                entry = inserted
            }
            try persistIdentityUpdate(
                entry: entry,
                registry: registry,
                cancellation: cancellation
            )
            return descriptor(entry)
        }
    }

    /// Proves a relink target from its own Git configuration and records a
    /// bounded, non-authoritative intent. The candidate path is not published as
    /// an alias until `commitRelink` is called after the control-plane
    /// generation/root compare-and-set succeeds.
    func prepareRelink(
        path rawPath: String,
        projectID: String,
        expectedGeneration: ProjectGeneration,
        expectedRepositoryIdentity: String?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectRelinkIdentityPreparation {
        let target = try discoverTarget(
            path: rawPath,
            cancellation: cancellation
        )
        return try prepareRelink(
            target: target,
            projectID: projectID,
            expectedGeneration: expectedGeneration,
            expectedRepositoryIdentity: expectedRepositoryIdentity,
            cancellation: cancellation
        )
    }

    func prepareRelink(
        target: ProjectIdentityTarget,
        projectID: String,
        expectedGeneration: ProjectGeneration,
        expectedRepositoryIdentity: String?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectRelinkIdentityPreparation {
        try cancellation?.checkCancellation()
        guard projectID.utf8.count <= 36, UUID(uuidString: projectID) != nil else {
            throw ProjectMemoryError.invalidRequest("project_id must be a UUID")
        }
        guard expectedGeneration.rawValue > 0,
              expectedGeneration.rawValue < UInt64(Int64.max) else {
            throw ProjectMemoryError.invalidRequest("project generation is outside bounds")
        }
        try validateTarget(target)
        let canonical = target.canonicalRoot
        guard let inferredIdentity = target.repositoryIdentity,
              let expectedIdentity = normalized(expectedRepositoryIdentity),
           inferredIdentity == expectedIdentity else {
            throw ProjectMemoryError.projectScopeMismatch
        }

        return try withRegistryLock(cancellation: cancellation) {
            try recoverPendingIdentityUpdate(cancellation: cancellation)
            let registry = try loadRegistry(cancellation: cancellation)
            try cancellation?.checkCancellation()
            guard let index = registry.projects.firstIndex(where: {
                $0.id.caseInsensitiveCompare(projectID) == .orderedSame
            }) else {
                throw ProjectMemoryError.projectNotFound(projectID)
            }
            guard registry.projects[index].repositoryIdentity == inferredIdentity else {
                throw ProjectMemoryError.projectScopeMismatch
            }
            guard !registry.projects.enumerated().contains(where: { candidate in
                candidate.offset != index && candidate.element.aliases.contains(canonical.path)
            }) else {
                throw ProjectMemoryError.projectScopeMismatch
            }

            let entry = registry.projects[index]
            let operationID = Self.relinkOperationID(
                projectID: projectID,
                expectedGeneration: expectedGeneration,
                canonicalRoot: canonical.path,
                repositoryIdentity: inferredIdentity
            )
            let preparation = ProjectRelinkIdentityPreparation(
                operationID: operationID,
                expectedGeneration: expectedGeneration,
                descriptor: descriptor(entry),
                target: target
            )

            // A fully published exact retry needs no new staged record. The
            // manager still rechecks the control-plane generation/root tuple.
            if entry.aliases.contains(canonical.path) {
                return preparation
            }

            let intended = ProjectRelinkIdentityIntent(
                schemaVersion: ProjectRelinkIdentityIntent.schemaVersion,
                operationID: operationID,
                projectID: projectID.lowercased(),
                expectedGeneration: expectedGeneration.rawValue,
                canonicalRoot: canonical.path,
                repositoryIdentity: inferredIdentity,
                directoryDevice: target.directoryIdentity.device,
                directoryInode: target.directoryIdentity.inode,
                createdAt: ISO8601.string(from: clock.now())
            )
            let intentURL = relinkIntentURL(projectID: projectID)
            if let existing = try loadRelinkIntentIfPresent(
                projectID: projectID,
                cancellation: cancellation
            ) {
                guard Self.sameRelink(existing, intended) else {
                    throw ProjectMemoryError.conflict(
                        "another project relink intent is pending"
                    )
                }
                return preparation
            }
            try cancellation?.checkCancellation()
            try OwnerOnlyAtomicFile.write(try JSONEncoder.sorted.encode(intended), to: intentURL)
            return preparation
        }
    }

    /// Publishes exactly the staged alias after the caller has committed the
    /// matching control-plane root and generation. Replays are idempotent.
    func commitRelink(
        _ preparation: ProjectRelinkIdentityPreparation,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectMemoryDescriptor {
        try validateTarget(preparation.target)
        return try withRegistryLock(cancellation: cancellation) {
            try recoverPendingIdentityUpdate(cancellation: cancellation)
            var registry = try loadRegistry(cancellation: cancellation)
            try cancellation?.checkCancellation()
            guard let index = registry.projects.firstIndex(where: {
                $0.id.caseInsensitiveCompare(preparation.descriptor.id) == .orderedSame
            }) else {
                throw ProjectMemoryError.projectNotFound(preparation.descriptor.id)
            }
            guard registry.projects[index].repositoryIdentity == preparation.repositoryIdentity,
                  preparation.operationID == Self.relinkOperationID(
                    projectID: preparation.descriptor.id,
                    expectedGeneration: preparation.expectedGeneration,
                    canonicalRoot: preparation.canonicalRoot.path,
                    repositoryIdentity: preparation.repositoryIdentity
                  ),
                  !registry.projects.enumerated().contains(where: { candidate in
                    candidate.offset != index
                        && candidate.element.aliases.contains(preparation.canonicalRoot.path)
                  }) else {
                throw ProjectMemoryError.projectScopeMismatch
            }

            if let intent = try loadRelinkIntentIfPresent(
                projectID: preparation.descriptor.id,
                cancellation: cancellation
            ) {
                guard Self.matches(preparation, intent: intent) else {
                    throw ProjectMemoryError.conflict(
                        "project relink intent does not match the committed control-plane tuple"
                    )
                }
            } else if !registry.projects[index].aliases.contains(preparation.canonicalRoot.path) {
                throw ProjectMemoryError.conflict("project relink intent is missing")
            }

            var entry = registry.projects[index]
            if !entry.aliases.contains(preparation.canonicalRoot.path) {
                entry.aliases.append(preparation.canonicalRoot.path)
                entry.aliases = Array(entry.aliases.suffix(32))
                entry.updatedAt = ISO8601.string(from: clock.now())
                registry.projects[index] = entry
                try persistIdentityUpdate(
                    entry: entry,
                    registry: registry,
                    cancellation: cancellation
                )
            }
            return descriptor(entry)
        }
    }

    /// Removes an exact relink intent only after the manager has verified the
    /// active control tuple and its published transition authority. Alias
    /// publication alone is not sufficient to discard restart recovery state.
    func completeRelinkIntent(
        _ preparation: ProjectRelinkIdentityPreparation,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try withRegistryLock(cancellation: cancellation) {
            guard let intent = try loadRelinkIntentIfPresent(
                projectID: preparation.descriptor.id,
                cancellation: cancellation
            ) else { return }
            guard Self.matches(preparation, intent: intent) else {
                throw ProjectMemoryError.conflict(
                    "project relink intent changed before completion"
                )
            }
            let registry = try loadRegistry(cancellation: cancellation)
            guard let entry = registry.projects.first(where: {
                $0.id.caseInsensitiveCompare(preparation.descriptor.id) == .orderedSame
            }),
                entry.repositoryIdentity == preparation.repositoryIdentity,
                entry.aliases.contains(preparation.canonicalRoot.path) else {
                throw ProjectMemoryError.conflict(
                    "project relink alias was not published before completion"
                )
            }
            try removeRelinkIntent(projectID: preparation.descriptor.id)
        }
    }

    /// Cancels only an exact uncommitted stage. It never removes a published
    /// alias and never guesses which of two conflicting intents is authoritative.
    func abortRelink(
        _ preparation: ProjectRelinkIdentityPreparation,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try withRegistryLock(cancellation: cancellation) {
            guard let intent = try loadRelinkIntentIfPresent(
                projectID: preparation.descriptor.id,
                cancellation: cancellation
            ) else { return }
            guard Self.matches(preparation, intent: intent) else {
                throw ProjectMemoryError.conflict(
                    "project relink intent changed before cancellation"
                )
            }
            try removeRelinkIntent(projectID: preparation.descriptor.id)
        }
    }

    func hasPendingRelink(
        projectID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> Bool {
        try withRegistryLock(cancellation: cancellation) {
            try loadRelinkIntentIfPresent(
                projectID: projectID,
                cancellation: cancellation
            ) != nil
        }
    }

    func pendingRelink(
        projectID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> PendingProjectRelinkIdentity? {
        try withRegistryLock(cancellation: cancellation) {
            try recoverPendingIdentityUpdate(cancellation: cancellation)
            let registry = try loadRegistry(cancellation: cancellation)
            guard let entry = registry.projects.first(where: {
                $0.id.caseInsensitiveCompare(projectID) == .orderedSame
            }) else {
                throw ProjectMemoryError.projectNotFound(projectID)
            }
            guard let intent = try loadRelinkIntentIfPresent(
                projectID: projectID,
                cancellation: cancellation
            ) else {
                return nil
            }
            let preparation = ProjectRelinkIdentityPreparation(
                operationID: intent.operationID,
                expectedGeneration: ProjectGeneration(intent.expectedGeneration),
                descriptor: descriptor(entry),
                target: ProjectIdentityTarget(
                    canonicalRoot: URL(
                        fileURLWithPath: intent.canonicalRoot,
                        isDirectory: true
                    ).standardizedFileURL,
                    repositoryIdentity: intent.repositoryIdentity,
                    directoryIdentity: ProjectDirectoryIdentity(
                        device: intent.directoryDevice,
                        inode: intent.directoryInode
                    )
                )
            )
            guard Self.matches(preparation, intent: intent),
                  entry.repositoryIdentity == intent.repositoryIdentity else {
                throw ProjectMemoryError.integrityFailure(
                    "project relink intent no longer matches project identity"
                )
            }
            return PendingProjectRelinkIdentity(
                preparation: preparation,
                createdAt: intent.createdAt
            )
        }
    }

    /// Resolves a durable stage against the authoritative control-plane tuple.
    /// An uncommitted stage is safe to remove; a committed tuple publishes its
    /// alias but retains the intent until the manager verifies final activation.
    /// Every other relationship is retained for explicit diagnosis.
    func reconcilePendingRelink(
        projectID: String,
        controlPlaneGeneration: ProjectGeneration,
        controlPlaneCanonicalRoot: URL,
        controlPlaneRepositoryIdentity: String?,
        committedTransitionValidated: Bool = false,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectRelinkIdentityRecovery {
        guard let pending = try pendingRelink(
            projectID: projectID,
            cancellation: cancellation
        ) else {
            return .none
        }
        let preparation = pending.preparation
        guard preparation.repositoryIdentity == controlPlaneRepositoryIdentity else {
            throw ProjectMemoryError.conflict(
                "project relink intent does not match control-plane repository identity"
            )
        }
        let controlRoot = controlPlaneCanonicalRoot.standardizedFileURL
        if controlPlaneGeneration == preparation.expectedGeneration,
           controlRoot != preparation.canonicalRoot {
            try abortRelink(preparation, cancellation: cancellation)
            return .abortedUncommitted(operationID: preparation.operationID)
        }
        let next = preparation.expectedGeneration.rawValue.addingReportingOverflow(1)
        if !next.overflow,
           controlPlaneGeneration.rawValue == next.partialValue,
           controlRoot == preparation.canonicalRoot {
            guard committedTransitionValidated else {
                throw ProjectMemoryError.conflict(
                    "project relink publication authority was not validated"
                )
            }
            _ = try commitRelink(preparation, cancellation: cancellation)
            return .publishedCommittedAlias(operationID: preparation.operationID)
        }
        throw ProjectMemoryError.conflict(
            "project relink intent cannot be reconciled with the control-plane tuple"
        )
    }

    private func removeRelinkIntent(projectID: String) throws {
        try beforeRelinkIntentRemovalObserver?()
        try OwnerOnlyAtomicFile.removeIfExists(
            at: relinkIntentURL(projectID: projectID)
        )
    }

    private func removeRegistrationIntent(
        _ preparation: ProjectRegistrationIdentityPreparation,
        cancellation: ToolCallCancellation?
    ) throws {
        try withRegistryLock(cancellation: cancellation) {
            guard let intent = try loadRegistrationIntentIfPresent(
                projectID: preparation.descriptor.id,
                cancellation: cancellation
            ) else {
                return
            }
            guard intent.operationID == preparation.operationID else {
                throw ProjectMemoryError.conflict(
                    "project registration intent changed before cleanup"
                )
            }
            let url = registrationIntentURL(projectID: preparation.descriptor.id)
            try OwnerOnlyAtomicFile.removeIfExists(at: url)
            let directory = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: directory.path),
               try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
                try FileManager.default.removeItem(at: directory)
                try OwnerOnlyAtomicFile.synchronizeDirectory(paths.projectsDir)
            }
        }
    }

    private func registrationIntentURL(projectID: String) -> URL {
        paths.projectsDir
            .appendingPathComponent(projectID.lowercased(), isDirectory: true)
            .appendingPathComponent(".registration-intent.json")
    }

    private func loadRegistrationIntentIfPresent(
        projectID: String,
        cancellation: ToolCallCancellation?
    ) throws -> ProjectRegistrationIdentityIntent? {
        guard projectID.utf8.count <= 36, UUID(uuidString: projectID) != nil else {
            throw ProjectMemoryError.invalidRequest("project_id must be a UUID")
        }
        let url = registrationIntentURL(projectID: projectID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try cancellation?.checkCancellation()
        let data: Data
        do {
            data = try OwnerOnlyAtomicFile.read(
                from: url,
                maximumBytes: Self.maximumRegistrationIntentBytes
            )
        } catch {
            throw ProjectMemoryError.integrityFailure(
                "project registration intent cannot be read"
            )
        }
        let intent: ProjectRegistrationIdentityIntent
        do {
            intent = try JSONDecoder().decode(ProjectRegistrationIdentityIntent.self, from: data)
        } catch {
            throw ProjectMemoryError.integrityFailure(
                "project registration intent is invalid"
            )
        }
        let canonical = URL(fileURLWithPath: intent.canonicalRoot, isDirectory: true)
            .standardizedFileURL
        let lifecycle = intent.expectedControlLifecycleState.flatMap(
            ProjectLifecycleState.init(rawValue:)
        )
        guard intent.schemaVersion == ProjectRegistrationIdentityIntent.schemaVersion,
              intent.projectID.caseInsensitiveCompare(projectID) == .orderedSame,
              intent.operationID.utf8.count == 64,
              intent.requestedPath.utf8.count <= Self.maximumRelinkPathBytes,
              (intent.requestedPath as NSString).isAbsolutePath,
              intent.requestedDisplayName.map({ $0.utf8.count <= 512 }) ?? true,
              intent.repositoryIdentityAssertion.map({ $0.utf8.count <= 2_048 }) ?? true,
              !intent.resolvedDisplayName.isEmpty,
              intent.resolvedDisplayName.utf8.count <= 512,
              intent.canonicalRoot.utf8.count <= Self.maximumRelinkPathBytes,
              (intent.canonicalRoot as NSString).isAbsolutePath,
              canonical.path == intent.canonicalRoot,
              intent.repositoryIdentity.map({ $0.utf8.count <= 2_048 }) ?? true,
              intent.repositoryIdentityAssertion.map({
                  normalized($0) == intent.repositoryIdentity
              }) ?? true,
              intent.directoryDevice > 0,
              intent.directoryInode > 0,
              intent.expectedControlGeneration.map({
                  $0 > 0 && $0 < UInt64(Int64.max)
              }) ?? true,
              intent.expectedControlLifecycleState == nil || lifecycle != nil,
              ISO8601.date(from: intent.createdAt) != nil else {
            throw ProjectMemoryError.integrityFailure(
                "project registration intent is outside its identity or size bounds"
            )
        }
        let descriptor = ProjectMemoryDescriptor(
            id: intent.projectID,
            displayName: intent.resolvedDisplayName,
            repositoryIdentity: intent.repositoryIdentity,
            aliases: lifecycle == .active ? [intent.canonicalRoot] : []
        )
        let target = ProjectIdentityTarget(
            canonicalRoot: canonical,
            repositoryIdentity: intent.repositoryIdentity,
            directoryIdentity: ProjectDirectoryIdentity(
                device: intent.directoryDevice,
                inode: intent.directoryInode
            )
        )
        guard intent.operationID == Self.registrationOperationID(
            descriptor: descriptor,
            target: target,
            expectedControlGeneration: intent.expectedControlGeneration.map(
                { ProjectGeneration($0) }
            ),
            expectedControlLifecycleState: lifecycle,
            expectedControlRepositoryIdentity: intent.expectedControlRepositoryIdentity
        ) else {
            throw ProjectMemoryError.integrityFailure(
                "project registration intent does not match its operation authority"
            )
        }
        return intent
    }

    private func relinkIntentURL(projectID: String) -> URL {
        paths.projectsDir
            .appendingPathComponent(projectID.lowercased(), isDirectory: true)
            .appendingPathComponent(".relink-intent.json")
    }

    private func loadRelinkIntentIfPresent(
        projectID: String,
        cancellation: ToolCallCancellation?
    ) throws -> ProjectRelinkIdentityIntent? {
        guard projectID.utf8.count <= 36, UUID(uuidString: projectID) != nil else {
            throw ProjectMemoryError.invalidRequest("project_id must be a UUID")
        }
        let url = relinkIntentURL(projectID: projectID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try cancellation?.checkCancellation()
        let data: Data
        do {
            data = try OwnerOnlyAtomicFile.read(
                from: url,
                maximumBytes: Self.maximumRelinkIntentBytes
            )
        } catch {
            throw ProjectMemoryError.integrityFailure(
                "project relink intent cannot be read"
            )
        }
        let intent: ProjectRelinkIdentityIntent
        do {
            intent = try JSONDecoder().decode(ProjectRelinkIdentityIntent.self, from: data)
        } catch {
            throw ProjectMemoryError.integrityFailure(
                "project relink intent is invalid"
            )
        }
        let canonical = URL(fileURLWithPath: intent.canonicalRoot, isDirectory: true)
            .standardizedFileURL
        guard intent.schemaVersion == ProjectRelinkIdentityIntent.schemaVersion,
              intent.projectID.caseInsensitiveCompare(projectID) == .orderedSame,
              intent.expectedGeneration > 0,
              intent.expectedGeneration < UInt64(Int64.max),
              intent.canonicalRoot.utf8.count <= Self.maximumRelinkPathBytes,
              (intent.canonicalRoot as NSString).isAbsolutePath,
              canonical.path == intent.canonicalRoot,
              !intent.repositoryIdentity.isEmpty,
              intent.repositoryIdentity.utf8.count <= 2_048,
              intent.directoryDevice > 0,
              intent.directoryInode > 0,
              intent.operationID == Self.relinkOperationID(
                projectID: intent.projectID,
                expectedGeneration: ProjectGeneration(intent.expectedGeneration),
                canonicalRoot: intent.canonicalRoot,
                repositoryIdentity: intent.repositoryIdentity
              ) else {
            throw ProjectMemoryError.integrityFailure(
                "project relink intent is outside its identity or size bounds"
            )
        }
        return intent
    }

    private static func relinkOperationID(
        projectID: String,
        expectedGeneration: ProjectGeneration,
        canonicalRoot: String,
        repositoryIdentity: String
    ) -> String {
        return JSONSupport.sha256Hex(
            [
                "project-relink-v1",
                projectID.lowercased(),
                String(expectedGeneration.rawValue),
                canonicalRoot,
                repositoryIdentity,
            ].joined(separator: "\u{0}")
        )
    }

    private static func registrationProjectID(
        target: ProjectIdentityTarget
    ) -> String {
        let authority = target.repositoryIdentity.map { "repository:\($0)" }
            ?? "path:\(target.canonicalRoot.path)"
        let hash = JSONSupport.sha256Hex(
            ["project-registration-v1", authority].joined(separator: "\u{0}")
        )
        let start = hash.startIndex
        func part(_ lower: Int, _ upper: Int) -> Substring {
            hash[hash.index(start, offsetBy: lower)..<hash.index(start, offsetBy: upper)]
        }
        return "\(part(0, 8))-\(part(8, 12))-\(part(12, 16))-\(part(16, 20))-\(part(20, 32))"
    }

    private static func registrationOperationID(
        descriptor: ProjectMemoryDescriptor,
        target: ProjectIdentityTarget,
        expectedControlGeneration: ProjectGeneration?,
        expectedControlLifecycleState: ProjectLifecycleState?,
        expectedControlRepositoryIdentity: String?
    ) -> String {
        let controlAuthority: String
        if expectedControlGeneration == nil,
           expectedControlLifecycleState == nil {
            controlAuthority = "publication:1"
        } else if let expectedControlGeneration,
                  expectedControlLifecycleState == .maintenance
                    || expectedControlLifecycleState == .active {
            // The publication operation remains stable across both durable
            // lifecycle boundaries: maintenance before identity publication and
            // active after finalization. Display name, path, repository identity,
            // and directory identity still distinguish a later registration.
            controlAuthority = "publication:\(expectedControlGeneration.rawValue)"
        } else {
            controlAuthority = [
                expectedControlGeneration.map { String($0.rawValue) } ?? "absent",
                expectedControlLifecycleState?.rawValue ?? "absent",
                expectedControlRepositoryIdentity ?? "none",
            ].joined(separator: ":")
        }
        return JSONSupport.sha256Hex(
            [
                "project-registration-operation-v1",
                descriptor.id.lowercased(),
                descriptor.displayName,
                target.canonicalRoot.path,
                target.repositoryIdentity ?? "",
                String(target.directoryIdentity.device),
                String(target.directoryIdentity.inode),
                controlAuthority,
            ].joined(separator: "\u{0}")
        )
    }

    private static func matches(
        _ preparation: ProjectRelinkIdentityPreparation,
        intent: ProjectRelinkIdentityIntent
    ) -> Bool {
        intent.schemaVersion == ProjectRelinkIdentityIntent.schemaVersion
            && intent.operationID == preparation.operationID
            && intent.projectID.caseInsensitiveCompare(preparation.descriptor.id) == .orderedSame
            && intent.expectedGeneration == preparation.expectedGeneration.rawValue
            && intent.canonicalRoot == preparation.canonicalRoot.path
            && intent.repositoryIdentity == preparation.repositoryIdentity
            && intent.directoryDevice == preparation.target.directoryIdentity.device
            && intent.directoryInode == preparation.target.directoryIdentity.inode
    }

    private static func sameRelink(
        _ lhs: ProjectRelinkIdentityIntent,
        _ rhs: ProjectRelinkIdentityIntent
    ) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.operationID == rhs.operationID
            && lhs.projectID.caseInsensitiveCompare(rhs.projectID) == .orderedSame
            && lhs.expectedGeneration == rhs.expectedGeneration
            && lhs.canonicalRoot == rhs.canonicalRoot
            && lhs.repositoryIdentity == rhs.repositoryIdentity
            && lhs.directoryDevice == rhs.directoryDevice
            && lhs.directoryInode == rhs.directoryInode
    }

    private static func sameRegistration(
        _ lhs: ProjectRegistrationIdentityIntent,
        _ rhs: ProjectRegistrationIdentityIntent,
        ignoringCreatedAt: Bool
    ) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.operationID == rhs.operationID
            && lhs.projectID.caseInsensitiveCompare(rhs.projectID) == .orderedSame
            && lhs.requestedPath == rhs.requestedPath
            && lhs.requestedDisplayName == rhs.requestedDisplayName
            && lhs.repositoryIdentityAssertion == rhs.repositoryIdentityAssertion
            && lhs.resolvedDisplayName == rhs.resolvedDisplayName
            && lhs.canonicalRoot == rhs.canonicalRoot
            && lhs.repositoryIdentity == rhs.repositoryIdentity
            && lhs.directoryDevice == rhs.directoryDevice
            && lhs.directoryInode == rhs.directoryInode
            && (ignoringCreatedAt || lhs.createdAt == rhs.createdAt)
    }

    func projectDirectory(
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

    private func directoryIdentity(_ url: URL) throws -> ProjectDirectoryIdentity {
        var information = stat()
        guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0,
              information.st_mode & S_IFMT == S_IFDIR else {
            throw ProjectMemoryError.invalidRequest(
                "project_path must remain the discovered directory"
            )
        }
        return ProjectDirectoryIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
    }

    private func validateTarget(_ target: ProjectIdentityTarget) throws {
        guard target.canonicalRoot.isFileURL,
              target.canonicalRoot.path.hasPrefix("/"),
              target.canonicalRoot.path.utf8.count <= Self.maximumRelinkPathBytes,
              target.canonicalRoot.standardizedFileURL == target.canonicalRoot,
              try directoryIdentity(target.canonicalRoot) == target.directoryIdentity else {
            throw ProjectMemoryError.conflict(
                "project directory identity changed after discovery"
            )
        }
    }

    private func inferredRepositoryIdentity(
        _ project: URL,
        cancellation: ToolCallCancellation?
    ) throws -> String? {
        guard let config = try gitConfigurationURL(
            project,
            cancellation: cancellation
        ), let data = try readOptionalGitControlFile(
            config,
            maximumBytes: Self.maximumGitConfigBytes,
            label: "Git configuration",
            cancellation: cancellation
        ) else { return nil }
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

    /// Resolves both ordinary repositories (`.git` directory) and Git's
    /// descriptor-file form used by linked worktrees and submodules. Runtime
    /// code reads the control files directly instead of spawning Git.
    private func gitConfigurationURL(
        _ project: URL,
        cancellation: ToolCallCancellation?
    ) throws -> URL? {
        try cancellation?.checkCancellation()
        let marker = project.appendingPathComponent(".git", isDirectory: false)
        var markerInformation = stat()
        let markerResult = marker.path.withCString {
            Darwin.lstat($0, &markerInformation)
        }
        if markerResult != 0 {
            if errno == ENOENT { return nil }
            throw ProjectMemoryError.invalidRequest("Git control marker is unreadable")
        }
        switch markerInformation.st_mode & S_IFMT {
        case S_IFDIR:
            return marker.appendingPathComponent("config", isDirectory: false)
        case S_IFREG:
            guard let pointerData = try readOptionalGitControlFile(
                marker,
                maximumBytes: Self.maximumGitPointerBytes,
                label: "Git worktree pointer",
                cancellation: cancellation
            ), let pointer = String(data: pointerData, encoding: .utf8) else {
                throw ProjectMemoryError.invalidRequest("Git worktree pointer is malformed")
            }
            let gitDirectory = try resolveGitControlDirectory(
                pointerValue(pointer, prefix: "gitdir:"),
                relativeTo: project,
                label: "Git worktree directory"
            )
            let commonDirectoryFile = gitDirectory.appendingPathComponent(
                "commondir",
                isDirectory: false
            )
            if let commonData = try readOptionalGitControlFile(
                commonDirectoryFile,
                maximumBytes: Self.maximumGitPointerBytes,
                label: "Git common-directory pointer",
                cancellation: cancellation
            ) {
                guard let commonPointer = String(data: commonData, encoding: .utf8) else {
                    throw ProjectMemoryError.invalidRequest(
                        "Git common-directory pointer is malformed"
                    )
                }
                let commonDirectory = try resolveGitControlDirectory(
                    singleControlPath(commonPointer, label: "Git common-directory pointer"),
                    relativeTo: gitDirectory,
                    label: "Git common directory"
                )
                return commonDirectory.appendingPathComponent("config", isDirectory: false)
            }
            return gitDirectory.appendingPathComponent("config", isDirectory: false)
        default:
            throw ProjectMemoryError.invalidRequest(
                "Git control marker must be a directory or regular descriptor file"
            )
        }
    }

    private func pointerValue(_ value: String, prefix: String) throws -> String {
        let line = try singleControlPath(value, label: "Git worktree pointer")
        guard line.hasPrefix(prefix) else {
            throw ProjectMemoryError.invalidRequest("Git worktree pointer is malformed")
        }
        let suffix = line.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespaces)
        guard !suffix.isEmpty else {
            throw ProjectMemoryError.invalidRequest("Git worktree pointer is malformed")
        }
        return suffix
    }

    private func singleControlPath(_ value: String, label: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= Self.maximumGitControlPathBytes,
              !trimmed.contains("\n"),
              !trimmed.contains("\r"),
              !trimmed.contains("\0") else {
            throw ProjectMemoryError.invalidRequest("\(label) is malformed")
        }
        return trimmed
    }

    private func resolveGitControlDirectory(
        _ rawPath: String,
        relativeTo base: URL,
        label: String
    ) throws -> URL {
        let path = try singleControlPath(rawPath, label: label)
        let candidate: URL
        if (path as NSString).isAbsolutePath {
            candidate = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            candidate = base.appendingPathComponent(path, isDirectory: true)
        }
        let resolved = candidate.standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix("/"),
              resolved.path.utf8.count <= Self.maximumGitControlPathBytes else {
            throw ProjectMemoryError.invalidRequest("\(label) is outside path bounds")
        }
        var information = stat()
        guard resolved.path.withCString({ Darwin.lstat($0, &information) }) == 0,
              information.st_mode & S_IFMT == S_IFDIR else {
            throw ProjectMemoryError.invalidRequest("\(label) is not a directory")
        }
        return resolved
    }

    private func readOptionalGitControlFile(
        _ url: URL,
        maximumBytes: Int,
        label: String,
        cancellation: ToolCallCancellation?
    ) throws -> Data? {
        var information = stat()
        let result = url.path.withCString { Darwin.lstat($0, &information) }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw ProjectMemoryError.invalidRequest("\(label) is unreadable")
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw ProjectMemoryError.invalidRequest("\(label) is not a regular file")
        }
        do {
            return try ProjectMemoryFileReader.read(
                url,
                maximumBytes: maximumBytes,
                cancellation: cancellation
            )
        } catch ProjectMemoryFileReadError.unreadable {
            throw ProjectMemoryError.invalidRequest("\(label) is unreadable")
        } catch ProjectMemoryFileReadError.tooLarge {
            throw ProjectMemoryError.payloadTooLarge(
                "\(label) exceeds \(maximumBytes) bytes"
            )
        }
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
    let identities: ProjectIdentityResolver
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

    /// Source-compatible facade for callers that previously initialized the
    /// project-memory registry without control-plane acceptance. That ordering
    /// can publish an alias for a rejected registration, so the public facade
    /// now fails closed and performs no mutation.
    @available(*, deprecated, message: "Use ManagerNode or ToolRouter project registration")
    public func initialize(
        path: String,
        projectID: String? = nil,
        displayName: String? = nil,
        repositoryIdentity: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        _ = path
        _ = projectID
        _ = displayName
        _ = repositoryIdentity
        try cancellation?.checkCancellation()
        throw ProjectContextError.projectTransitionCoordinatorRequired
    }

    func initializeUnchecked(
        path: String,
        projectID: String? = nil,
        displayName: String? = nil,
        repositoryIdentity: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> [String: Any] {
        try cancellation?.checkCancellation()
        let target = try identities.discoverTarget(
            path: path,
            repositoryIdentityAssertion: repositoryIdentity,
            cancellation: cancellation
        )
        let preparation = try identities.prepareRegistration(
            target: target,
            requestedProjectID: projectID,
            displayName: displayName,
            allowUnregisteredRequestedID: false,
            cancellation: cancellation
        )
        return try commitInitialization(preparation, cancellation: cancellation)
    }

    func commitInitialization(
        _ preparation: ProjectRegistrationIdentityPreparation,
        cancellation: ToolCallCancellation? = nil,
        onIdentityCommitted: ((ProjectMemoryDescriptor) -> Void)? = nil
    ) throws -> [String: Any] {
        let descriptor = try identities.commitRegistration(
            preparation,
            cancellation: cancellation
        )
        onIdentityCommitted?(descriptor)
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

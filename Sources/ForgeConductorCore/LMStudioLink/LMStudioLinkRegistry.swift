// LMStudioLinkRegistry.swift
// What: Persists bounded, nonsecret paired-node metadata.
// How: A process-local actor and cross-process advisory lock serialize CAS updates to an owner-only atomic file.
// Why: Pairing state must survive restart without allowing stale UI writes or bearer material on disk.

import Darwin
import Foundation

public struct LMStudioLinkRegistrySnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let revision: String
    public let activeNodeID: LMStudioLinkNodeID?
    public let nodes: [LMStudioLinkNodeSnapshot]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        revision: String = "0",
        activeNodeID: LMStudioLinkNodeID? = nil,
        nodes: [LMStudioLinkNodeSnapshot] = []
    ) throws {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.activeNodeID = activeNodeID
        self.nodes = nodes
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw LMStudioLinkRegistryError.unsupportedSchemaVersion(schemaVersion)
        }
        guard revision == "0" || UUID(uuidString: revision) != nil else {
            throw LMStudioLinkRegistryError.corrupt(reason: "invalid_revision")
        }
        guard nodes.count <= LMStudioLinkLimits.maximumRetainedNodes else {
            throw LMStudioLinkRegistryError.nodeLimitExceeded
        }
        guard Set(nodes.map(\.id)).count == nodes.count else {
            throw LMStudioLinkRegistryError.corrupt(reason: "duplicate_node")
        }
        try nodes.forEach { try $0.validate() }
        if let activeNodeID {
            guard nodes.contains(where: { $0.id == activeNodeID && $0.state == .active }) else {
                throw LMStudioLinkRegistryError.corrupt(reason: "active_node_missing_or_inactive")
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case revision
        case activeNodeID = "active_node_id"
        case nodes
    }
}

public enum LMStudioLinkRegistryError: Error, LocalizedError, Sendable, Equatable {
    case revisionConflict(expected: String, actual: String)
    case nodeLimitExceeded
    case nodeNotFound
    case nodeRevoked
    case unsupportedSchemaVersion(Int)
    case unsafeStorage
    case corrupt(reason: String)
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .revisionConflict: "The paired-node registry changed; refresh and retry."
        case .nodeLimitExceeded: "The paired-node registry has reached its 16-node limit."
        case .nodeNotFound: "The paired LM Studio node was not found."
        case .nodeRevoked: "A revoked LM Studio node cannot be selected."
        case .unsupportedSchemaVersion: "The paired-node registry version is unsupported."
        case .unsafeStorage: "The paired-node registry has unsafe ownership, permissions, or file type."
        case .corrupt: "The paired-node registry is invalid."
        case .persistenceFailed: "The paired-node registry could not be committed safely."
        }
    }
}

public actor LMStudioLinkRegistry {
    public static let fileName = "lmstudio-link-nodes.json"

    private let directory: URL
    private let registryURL: URL
    private let lockURL: URL

    public init(storageDirectory: URL) {
        directory = storageDirectory
        registryURL = storageDirectory.appendingPathComponent(Self.fileName, isDirectory: false)
        lockURL = storageDirectory.appendingPathComponent("lmstudio-link-nodes.lock", isDirectory: false)
    }

    public func read() throws -> LMStudioLinkRegistrySnapshot {
        try withLock { try loadUnlocked() }
    }

    @discardableResult
    public func upsert(
        _ node: LMStudioLinkNodeSnapshot,
        expectedRevision: String
    ) throws -> LMStudioLinkRegistrySnapshot {
        try node.validate()
        return try mutate(expectedRevision: expectedRevision) { snapshot in
            var nodes = snapshot.nodes
            if let index = nodes.firstIndex(where: { $0.id == node.id }) {
                nodes[index] = node
            } else {
                guard nodes.count < LMStudioLinkLimits.maximumRetainedNodes else {
                    throw LMStudioLinkRegistryError.nodeLimitExceeded
                }
                nodes.append(node)
            }
            nodes.sort { $0.id.description < $1.id.description }
            let activeNodeID = snapshot.activeNodeID == node.id && node.state != .active
                ? nil
                : snapshot.activeNodeID
            return try LMStudioLinkRegistrySnapshot(
                revision: UUID().uuidString.lowercased(),
                activeNodeID: activeNodeID,
                nodes: nodes
            )
        }
    }

    @discardableResult
    public func select(
        _ nodeID: LMStudioLinkNodeID?,
        expectedRevision: String
    ) throws -> LMStudioLinkRegistrySnapshot {
        try mutate(expectedRevision: expectedRevision) { snapshot in
            if let nodeID {
                guard let node = snapshot.nodes.first(where: { $0.id == nodeID }) else {
                    throw LMStudioLinkRegistryError.nodeNotFound
                }
                guard node.state == .active else { throw LMStudioLinkRegistryError.nodeRevoked }
            }
            return try LMStudioLinkRegistrySnapshot(
                revision: UUID().uuidString.lowercased(),
                activeNodeID: nodeID,
                nodes: snapshot.nodes
            )
        }
    }

    @discardableResult
    public func remove(
        _ nodeID: LMStudioLinkNodeID,
        expectedRevision: String
    ) throws -> LMStudioLinkRegistrySnapshot {
        try mutate(expectedRevision: expectedRevision) { snapshot in
            guard snapshot.nodes.contains(where: { $0.id == nodeID }) else {
                throw LMStudioLinkRegistryError.nodeNotFound
            }
            return try LMStudioLinkRegistrySnapshot(
                revision: UUID().uuidString.lowercased(),
                activeNodeID: snapshot.activeNodeID == nodeID ? nil : snapshot.activeNodeID,
                nodes: snapshot.nodes.filter { $0.id != nodeID }
            )
        }
    }

    private func mutate(
        expectedRevision: String,
        transform: (LMStudioLinkRegistrySnapshot) throws -> LMStudioLinkRegistrySnapshot
    ) throws -> LMStudioLinkRegistrySnapshot {
        try withLock {
            let current = try loadUnlocked()
            guard current.revision == expectedRevision else {
                throw LMStudioLinkRegistryError.revisionConflict(
                    expected: expectedRevision,
                    actual: current.revision
                )
            }
            let updated = try transform(current)
            try persistUnlocked(updated)
            return updated
        }
    }

    private func loadUnlocked() throws -> LMStudioLinkRegistrySnapshot {
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            return try LMStudioLinkRegistrySnapshot()
        }
        try validateOwnerOnlyRegularFile(registryURL, expectedMode: 0o600)
        do {
            let data = try OwnerOnlyAtomicFile.read(
                from: registryURL,
                maximumBytes: LMStudioLinkLimits.maximumRegistryBytes
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(LMStudioLinkRegistrySnapshot.self, from: data)
            try snapshot.validate()
            return snapshot
        } catch let error as LMStudioLinkRegistryError {
            throw error
        } catch {
            throw LMStudioLinkRegistryError.corrupt(reason: "decode_failed")
        }
    }

    private func persistUnlocked(_ snapshot: LMStudioLinkRegistrySnapshot) throws {
        do {
            try snapshot.validate()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(snapshot)
            guard data.count <= LMStudioLinkLimits.maximumRegistryBytes else {
                throw LMStudioLinkRegistryError.corrupt(reason: "registry_exceeds_bound")
            }
            try OwnerOnlyAtomicFile.write(data, to: registryURL)
            try validateOwnerOnlyRegularFile(registryURL, expectedMode: 0o600)
        } catch let error as LMStudioLinkRegistryError {
            throw error
        } catch {
            throw LMStudioLinkRegistryError.persistenceFailed
        }
    }

    private func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
        do {
            try ensureOwnerOnlyDirectory()
        } catch let error as LMStudioLinkRegistryError {
            throw error
        } catch {
            throw LMStudioLinkRegistryError.unsafeStorage
        }
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        }
        guard descriptor >= 0 else { throw LMStudioLinkRegistryError.unsafeStorage }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == 0o600 else {
            throw LMStudioLinkRegistryError.unsafeStorage
        }
        let deadline = Date().addingTimeInterval(2)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else {
                throw LMStudioLinkRegistryError.persistenceFailed
            }
            Darwin.usleep(10_000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func ensureOwnerOnlyDirectory() throws {
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard isDirectory.boolValue || FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue else {
            throw LMStudioLinkRegistryError.unsafeStorage
        }
        var metadata = stat()
        guard directory.path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else {
            throw LMStudioLinkRegistryError.unsafeStorage
        }
        if metadata.st_mode & 0o077 != 0 {
            guard directory.path.withCString({ Darwin.chmod($0, 0o700) }) == 0 else {
                throw LMStudioLinkRegistryError.unsafeStorage
            }
        }
    }

    private func validateOwnerOnlyRegularFile(_ url: URL, expectedMode: mode_t) throws {
        var metadata = stat()
        guard url.path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == expectedMode else {
            throw LMStudioLinkRegistryError.unsafeStorage
        }
    }
}

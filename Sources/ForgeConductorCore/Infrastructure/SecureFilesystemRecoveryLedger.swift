// SecureFilesystemRecoveryLedger.swift
// What: Retains bounded caller-side authority needed to recover privileged deletes.
// How: Owner-only fixed slots are committed before XPC submission and removed only after ack.
// Why: A lost reply or process restart must not make a protected transaction unreachable.

import Darwin
import Foundation
import ForgeFilesystemProtocol

struct SecureFilesystemRecoveryRootIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let group: UInt32
    let linkCount: UInt64

    init(_ identity: ForgeFilesystemIdentity) {
        device = identity.device
        inode = identity.inode
        mode = identity.mode
        owner = identity.owner
        group = identity.group
        linkCount = identity.linkCount
    }

    var protocolIdentity: ForgeFilesystemIdentity {
        ForgeFilesystemIdentity(
            device: device,
            inode: inode,
            mode: mode,
            owner: owner,
            group: group,
            linkCount: linkCount
        )
    }

    func matchesRoot(_ information: stat) -> Bool {
        device == UInt64(information.st_dev)
            && inode == UInt64(information.st_ino)
            && mode == UInt32(information.st_mode)
            && owner == UInt32(information.st_uid)
            && group == UInt32(information.st_gid)
            && information.st_mode & S_IFMT == S_IFDIR
    }
}

struct SecureFilesystemRecoveryRecord: Codable, Equatable, Sendable {
    static let currentSchema = 1

    let schemaVersion: Int
    let createdAtMilliseconds: Int64
    let requestID: String
    let transactionID: String
    let projectID: String
    let projectGeneration: UInt64
    let requesterUID: UInt32
    // Audit provenance only. Recovery authority deliberately survives a new MCP
    // client process and is fenced by UID, project generation, root, and transaction.
    let originatingClientID: String
    let rootPath: String
    let rootID: String
    let rootIdentity: SecureFilesystemRecoveryRootIdentity

    init(
        request: ForgeFilesystemMutationRequest,
        originatingClientID: ClientID,
        rootPath: String,
        requesterUID: uid_t = geteuid(),
        createdAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) {
        schemaVersion = Self.currentSchema
        self.createdAtMilliseconds = createdAtMilliseconds
        requestID = request.requestID.lowercased()
        transactionID = request.transactionID.lowercased()
        projectID = request.projectID.lowercased()
        projectGeneration = request.projectGeneration
        self.requesterUID = UInt32(requesterUID)
        self.originatingClientID = String(originatingClientID.rawValue.prefix(256))
        self.rootPath = rootPath
        rootID = request.rootID
        rootIdentity = SecureFilesystemRecoveryRootIdentity(request.rootIdentity)
    }

    var isStructurallyValid: Bool {
        schemaVersion == Self.currentSchema
            && createdAtMilliseconds > 0
            && UUID(uuidString: requestID) != nil
            && UUID(uuidString: transactionID) != nil
            && UUID(uuidString: projectID) != nil
            && projectGeneration > 0
            && projectGeneration <= UInt64(Int64.max)
            && ForgeFilesystemRequesterPolicy.isValidRequesterUID(requesterUID)
            && !originatingClientID.isEmpty
            && originatingClientID.utf8.count <= 256
            && rootPath.hasPrefix("/")
            && !rootPath.contains("\0")
            && rootPath.utf8.count < Int(PATH_MAX)
            && !rootID.isEmpty
            && rootID.utf8.count <= 128
            && rootIdentity.mode & UInt32(S_IFMT) == UInt32(S_IFDIR)
    }

    func hasSameAuthority(as other: SecureFilesystemRecoveryRecord) -> Bool {
        requestID.caseInsensitiveCompare(other.requestID) == .orderedSame
            && transactionID.caseInsensitiveCompare(other.transactionID) == .orderedSame
            && projectID.caseInsensitiveCompare(other.projectID) == .orderedSame
            && projectGeneration == other.projectGeneration
            && requesterUID == other.requesterUID
            && rootPath == other.rootPath
            && rootID == other.rootID
            && rootIdentity == other.rootIdentity
    }
}

enum SecureFilesystemRecoveryLedgerError: Error, LocalizedError, Sendable, Equatable {
    case invalidRecord
    case capacityExhausted
    case conflictingTransaction
    case retainedAuthority
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidRecord:
            "The protected filesystem recovery record is invalid"
        case .capacityExhausted:
            "The bounded protected filesystem recovery ledger is full"
        case .conflictingTransaction:
            "The protected filesystem transaction identifier conflicts with retained authority"
        case .retainedAuthority:
            "Protected filesystem recovery authority is still retained"
        case .unavailable:
            "The protected filesystem recovery ledger is unavailable"
        }
    }
}

final class SecureFilesystemRecoveryLedger: @unchecked Sendable {
    static let maximumRecords = 32
    private static let maximumRecordBytes = 8 * 1_024
    private static let lockTimeoutSeconds: TimeInterval = 2
    private static let processLock = NSLock()

    private let root: URL
    private let lockURL: URL

    init(paths: AppPaths) {
        root = paths.home.appendingPathComponent(
            "privileged-filesystem-recovery",
            isDirectory: true
        )
        lockURL = root.appendingPathComponent(".ledger.lock")
    }

    init(root: URL) {
        self.root = root.standardizedFileURL
        lockURL = self.root.appendingPathComponent(".ledger.lock")
    }

    func retain(
        _ record: SecureFilesystemRecoveryRecord,
        validatingCurrentAuthority: () throws -> Void = {}
    ) throws {
        guard record.isStructurallyValid else {
            throw SecureFilesystemRecoveryLedgerError.invalidRecord
        }
        try withLedgerLock {
            // Generation reset holds this same lock through its durable advance.
            // Revalidation here ensures a caller that was valid before reset but
            // waited for the lock cannot publish stale authority afterward.
            try validatingCurrentAuthority()
            var firstVacantSlot: Int?
            for slot in 0..<Self.maximumRecords {
                guard let existing = try readSlot(slot) else {
                    if firstVacantSlot == nil { firstVacantSlot = slot }
                    continue
                }
                guard existing.isStructurallyValid else {
                    throw SecureFilesystemRecoveryLedgerError.unavailable
                }
                guard existing.transactionID.caseInsensitiveCompare(
                    record.transactionID
                ) != .orderedSame else {
                    guard existing.hasSameAuthority(as: record) else {
                        throw SecureFilesystemRecoveryLedgerError.conflictingTransaction
                    }
                    return
                }
            }
            guard let slot = firstVacantSlot else {
                throw SecureFilesystemRecoveryLedgerError.capacityExhausted
            }
            let data = try JSONEncoder().encode(record)
            guard data.count <= Self.maximumRecordBytes else {
                throw SecureFilesystemRecoveryLedgerError.invalidRecord
            }
            try OwnerOnlyAtomicFile.write(data, to: slotURL(slot))
        }
    }

    func record(transactionID: String) throws -> SecureFilesystemRecoveryRecord? {
        guard UUID(uuidString: transactionID) != nil else {
            throw SecureFilesystemRecoveryLedgerError.invalidRecord
        }
        return try withLedgerLock {
            for slot in 0..<Self.maximumRecords {
                guard let record = try readSlot(slot) else { continue }
                guard record.isStructurallyValid else {
                    throw SecureFilesystemRecoveryLedgerError.unavailable
                }
                if record.transactionID.caseInsensitiveCompare(transactionID) == .orderedSame {
                    return record
                }
            }
            return nil
        }
    }

    @discardableResult
    func remove(transactionID: String) throws -> Bool {
        guard UUID(uuidString: transactionID) != nil else {
            throw SecureFilesystemRecoveryLedgerError.invalidRecord
        }
        return try withLedgerLock {
            for slot in 0..<Self.maximumRecords {
                guard let record = try readSlot(slot) else { continue }
                guard record.isStructurallyValid else {
                    throw SecureFilesystemRecoveryLedgerError.unavailable
                }
                if record.transactionID.caseInsensitiveCompare(transactionID) == .orderedSame {
                    try OwnerOnlyAtomicFile.removeIfExists(at: slotURL(slot))
                    return true
                }
            }
            return false
        }
    }

    func retainedCount() throws -> Int {
        try withLedgerLock {
            var count = 0
            for slot in 0..<Self.maximumRecords {
                guard let record = try readSlot(slot) else { continue }
                guard record.isStructurallyValid else {
                    throw SecureFilesystemRecoveryLedgerError.unavailable
                }
                count += 1
            }
            return count
        }
    }

    func hasRetainedAuthority(
        projectID: ProjectID,
        generation: ProjectGeneration
    ) throws -> Bool {
        return try withLedgerLock {
            try hasRetainedAuthorityUnlocked(
                projectID: projectID,
                generation: generation
            )
        }
    }

    func withRetainedAuthorityFence<Value>(
        projectID: ProjectID,
        generation: ProjectGeneration,
        _ operation: (_ assertNoRetainedAuthority: () throws -> Void) throws -> Value
    ) throws -> Value {
        try withLedgerLock {
            let assertNoRetainedAuthority = {
                guard try !self.hasRetainedAuthorityUnlocked(
                    projectID: projectID,
                    generation: generation
                ) else {
                    throw SecureFilesystemRecoveryLedgerError.retainedAuthority
                }
            }
            try assertNoRetainedAuthority()
            return try operation(assertNoRetainedAuthority)
        }
    }

    private func hasRetainedAuthorityUnlocked(
        projectID: ProjectID,
        generation: ProjectGeneration
    ) throws -> Bool {
        let expectedProjectID = projectID.description
        let expectedGeneration = generation.rawValue
        for slot in 0..<Self.maximumRecords {
            guard let record = try readSlot(slot) else { continue }
            guard record.isStructurallyValid else {
                throw SecureFilesystemRecoveryLedgerError.unavailable
            }
            if record.projectID.caseInsensitiveCompare(expectedProjectID) == .orderedSame,
               record.projectGeneration == expectedGeneration {
                return true
            }
        }
        return false
    }

    private func readSlot(_ slot: Int) throws -> SecureFilesystemRecoveryRecord? {
        let url = slotURL(slot)
        var information = stat()
        guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
            if errno == ENOENT { return nil }
            throw SecureFilesystemRecoveryLedgerError.unavailable
        }
        guard information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0,
              information.st_nlink == 1 else {
            throw SecureFilesystemRecoveryLedgerError.unavailable
        }
        do {
            let data = try OwnerOnlyAtomicFile.read(
                from: url,
                maximumBytes: Self.maximumRecordBytes
            )
            return try JSONDecoder().decode(SecureFilesystemRecoveryRecord.self, from: data)
        } catch {
            throw SecureFilesystemRecoveryLedgerError.unavailable
        }
    }

    private func slotURL(_ slot: Int) -> URL {
        root.appendingPathComponent(String(format: "slot-%02d.json", slot))
    }

    private func withLedgerLock<Value>(_ body: () throws -> Value) throws -> Value {
        let deadline = Date().addingTimeInterval(Self.lockTimeoutSeconds)
        guard Self.processLock.lock(before: deadline) else {
            throw SecureFilesystemRecoveryLedgerError.unavailable
        }
        defer { Self.processLock.unlock() }

        try ensurePrivateRoot()
        let descriptor = lockURL.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw SecureFilesystemRecoveryLedgerError.unavailable
        }
        defer { _ = Darwin.close(descriptor) }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0,
              information.st_nlink == 1 else {
            throw SecureFilesystemRecoveryLedgerError.unavailable
        }

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR,
                  Date() < deadline else {
                throw SecureFilesystemRecoveryLedgerError.unavailable
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func ensurePrivateRoot() throws {
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SecureFilesystemRecoveryLedgerError.unavailable
        }
        var information = stat()
        guard root.path.withCString({ Darwin.lstat($0, &information) }) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == geteuid(),
              root.path.withCString({ Darwin.chmod($0, mode_t(S_IRWXU)) }) == 0 else {
            throw SecureFilesystemRecoveryLedgerError.unavailable
        }
    }
}

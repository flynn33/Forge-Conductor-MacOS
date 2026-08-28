// FilesystemQuarantineLedger.swift
// What: Bounds and records in-flight filesystem quarantine transitions.
// How: A fixed-capacity owner-only receipt ledger is committed before a leaf is renamed.
// Why: Interrupted delete and move operations must not accumulate untracked quarantine entries.

import Darwin
import Foundation

struct FilesystemQuarantineIdentity: Sendable, Equatable {
    let device: Int64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let group: UInt32

    init(_ information: stat) {
        device = Int64(information.st_dev)
        inode = UInt64(information.st_ino)
        mode = UInt32(information.st_mode)
        owner = UInt32(information.st_uid)
        group = UInt32(information.st_gid)
    }

    init(device: Int64, inode: UInt64, mode: UInt32, owner: UInt32, group: UInt32) {
        self.device = device
        self.inode = inode
        self.mode = mode
        self.owner = owner
        self.group = group
    }

    func matches(_ information: stat) -> Bool {
        device == Int64(information.st_dev)
            && inode == UInt64(information.st_ino)
            && mode == UInt32(information.st_mode)
            && owner == UInt32(information.st_uid)
            && group == UInt32(information.st_gid)
    }
}

struct FilesystemQuarantineReservation: Sendable, Equatable {
    let identifier: String
    let slot: Int
    let receiptURL: URL
    let originalURL: URL
    let quarantineURL: URL
    let parentIdentity: FilesystemQuarantineIdentity
    let leafIdentity: FilesystemQuarantineIdentity
    let operation: String
    let processInstanceID: String

    var quarantineName: String { quarantineURL.lastPathComponent }
}

enum FilesystemQuarantineLedgerError: Error, LocalizedError, Sendable {
    case capacityExhausted([String])
    case transitionRetained(String)
    case receiptRetained(String, String)
    case invalidPath
    case lockTimeout
    case lockFailure(Int32)
    case invalidLedgerDirectory

    var recoveryPaths: [String] {
        switch self {
        case .capacityExhausted(let paths): return paths
        case .transitionRetained(let path): return [path]
        case .receiptRetained(let path, _): return [path]
        default: return []
        }
    }

    var errorDescription: String? {
        switch self {
        case .capacityExhausted:
            return "The filesystem quarantine ledger is full and requires recovery"
        case .transitionRetained(let path):
            return "The initial filesystem quarantine transition requires recovery at \(path)"
        case .receiptRetained(let path, let reason):
            return "The filesystem quarantine receipt requires recovery at \(path): \(reason)"
        case .invalidPath:
            return "The filesystem quarantine ledger received an invalid path"
        case .lockTimeout:
            return "Timed out acquiring the filesystem quarantine ledger lock"
        case .lockFailure(let code):
            return "Could not lock the filesystem quarantine ledger (errno \(code))"
        case .invalidLedgerDirectory:
            return "The filesystem quarantine ledger path is not a private directory"
        }
    }
}

final class FilesystemQuarantineLedger: @unchecked Sendable {
    static let maximumReservations = 32
    private static let maximumReceiptBytes = 8 * 1_024
    private static let lockTimeoutSeconds: TimeInterval = 2
    private static let processLock = NSLock()
    private static let processInstanceID = UUID().uuidString.lowercased()

    private let root: URL
    private let lockURL: URL
    private let instanceID: String
    private let receiptRemover: (URL) throws -> Void

    init(paths: AppPaths) {
        root = paths.home.appendingPathComponent("filesystem-quarantine", isDirectory: true)
        lockURL = root.appendingPathComponent(".ledger.lock")
        instanceID = Self.processInstanceID
        receiptRemover = { try OwnerOnlyAtomicFile.removeIfExists(at: $0) }
    }

    init(
        root: URL,
        processInstanceID: String = FilesystemQuarantineLedger.processInstanceID,
        receiptRemover: @escaping (URL) throws -> Void = {
            try OwnerOnlyAtomicFile.removeIfExists(at: $0)
        }
    ) {
        self.root = root.standardizedFileURL
        lockURL = self.root.appendingPathComponent(".ledger.lock")
        instanceID = processInstanceID
        self.receiptRemover = receiptRemover
    }

    func reserveAndQuarantine(
        parent: URL,
        originalName: String,
        parentIdentity: FilesystemQuarantineIdentity,
        leafIdentity: FilesystemQuarantineIdentity,
        operation: String,
        transition: (FilesystemQuarantineReservation) throws -> Void
    ) throws -> FilesystemQuarantineReservation {
        guard !originalName.isEmpty,
              originalName != ".",
              originalName != "..",
              !originalName.contains("/") else {
            throw FilesystemQuarantineLedgerError.invalidPath
        }
        let standardizedParent = parent.standardizedFileURL
        return try withLedgerLock {
            let occupied = try reconcileLocked()
            for slot in 0..<Self.maximumReservations where occupied[slot] == nil {
                let identifier = UUID().uuidString.lowercased()
                let receiptURL = slotURL(slot)
                let originalURL = standardizedParent.appendingPathComponent(originalName)
                let quarantineURL = standardizedParent.appendingPathComponent(
                    String(format: ".forge-quarantine-v1-%02d", slot)
                )
                let reservation = FilesystemQuarantineReservation(
                    identifier: identifier,
                    slot: slot,
                    receiptURL: receiptURL,
                    originalURL: originalURL,
                    quarantineURL: quarantineURL,
                    parentIdentity: parentIdentity,
                    leafIdentity: leafIdentity,
                    operation: operation,
                    processInstanceID: instanceID
                )
                try createReceipt(
                    try JSONSupport.data(from: receiptObject(reservation)),
                    at: receiptURL
                )
                do {
                    try transition(reservation)
                } catch {
                    let parentMatches = Self.pathIdentityResult(at: standardizedParent)
                        .matches(parentIdentity)
                    let originalMatches = Self.pathIdentityResult(at: originalURL)
                        .matches(leafIdentity)
                    if parentMatches, originalMatches {
                        do {
                            try Self.synchronizeDirectory(
                                standardizedParent,
                                matching: parentIdentity
                            )
                            guard case .absent = removeReceipt(receiptURL) else {
                                throw FilesystemQuarantineLedgerError.receiptRetained(
                                    receiptURL.path,
                                    "the receipt could not be verified absent"
                                )
                            }
                        } catch {
                            throw FilesystemQuarantineLedgerError.receiptRetained(
                                receiptURL.path,
                                error.localizedDescription
                            )
                        }
                    } else if Self.pathExistsWithoutFollowing(quarantineURL) {
                        throw FilesystemQuarantineLedgerError.transitionRetained(
                            quarantineURL.path
                        )
                    } else {
                        throw FilesystemQuarantineLedgerError.receiptRetained(
                            receiptURL.path,
                            "the failed transition could not be verified as namespace-neutral"
                        )
                    }
                    throw error
                }
                return reservation
            }
            throw FilesystemQuarantineLedgerError.capacityExhausted(
                occupied.compactMap { $0?.recoveryPath }
            )
        }
    }

    func performTerminal<Value>(
        _ reservation: FilesystemQuarantineReservation,
        expectedLeafIdentity: FilesystemQuarantineIdentity? = nil,
        parentIdentityVerifier: (() -> Bool)? = nil,
        leafIdentityVerifier: (() -> Bool)? = nil,
        transition: () throws -> (value: Value, durabilityConfirmed: Bool)
    ) throws -> (value: Value, durabilityConfirmed: Bool) {
        try withLedgerLock {
            guard let current = try readReceipt(at: reservation.receiptURL),
                  let recorded = current.reservation,
                  recorded.identifier == reservation.identifier else {
                throw FilesystemQuarantineLedgerError.invalidPath
            }
            let parentMatches = parentIdentityVerifier?()
                ?? Self.pathIdentityResult(
                    at: recorded.originalURL.deletingLastPathComponent()
                ).matches(recorded.parentIdentity)
            let leafMatches = leafIdentityVerifier?()
                ?? Self.pathIdentityResult(at: recorded.quarantineURL)
                    .matches(expectedLeafIdentity ?? recorded.leafIdentity)
            guard parentMatches, leafMatches else {
                throw FilesystemQuarantineLedgerError.invalidPath
            }
            let outcome = try transition()
            if outcome.durabilityConfirmed {
                switch removeReceipt(reservation.receiptURL) {
                case .absent:
                    break
                case .retained:
                    // The terminal namespace change is complete, but a receipt
                    // still exists or its live absence cannot be established.
                    // Keep the slot occupied and report the combined transition
                    // as durability-unconfirmed.
                    return (outcome.value, false)
                }
            }
            return outcome
        }
    }

    func releaseRestoredReservation(_ reservation: FilesystemQuarantineReservation) throws {
        try withLedgerLock {
            guard let current = try readReceipt(at: reservation.receiptURL),
                  let recorded = current.reservation,
                  recorded.identifier == reservation.identifier,
                  Self.pathIdentityResult(
                    at: recorded.originalURL.deletingLastPathComponent()
                  ).matches(recorded.parentIdentity),
                  !Self.pathExistsWithoutFollowing(recorded.quarantineURL),
                  Self.pathIdentityResult(at: recorded.originalURL)
                    .matches(recorded.leafIdentity) else {
                return
            }
            try Self.synchronizeDirectory(
                recorded.originalURL.deletingLastPathComponent(),
                matching: recorded.parentIdentity
            )
            guard case .absent = removeReceipt(reservation.receiptURL) else {
                throw FilesystemQuarantineLedgerError.receiptRetained(
                    reservation.receiptURL.path,
                    "the restored reservation receipt could not be verified absent"
                )
            }
        }
    }

    @discardableResult
    func reconcile() throws -> [String] {
        try withLedgerLock {
            try reconcileLocked().compactMap { $0?.recoveryPath }
        }
    }

    private struct OccupiedSlot {
        let recoveryPath: String
    }

    private struct ReceiptRead {
        let reservation: FilesystemQuarantineReservation?
        let recoveryPath: String
    }

    private func reconcileLocked() throws -> [OccupiedSlot?] {
        var occupied = Array<OccupiedSlot?>(repeating: nil, count: Self.maximumReservations)
        for slot in 0..<Self.maximumReservations {
            let receiptURL = slotURL(slot)
            guard Self.pathExistsWithoutFollowing(receiptURL) else { continue }
            guard let receipt = try readReceipt(at: receiptURL),
                  let reservation = receipt.reservation else {
                occupied[slot] = OccupiedSlot(recoveryPath: receiptURL.path)
                continue
            }
            let parent = reservation.originalURL.deletingLastPathComponent()
            guard Self.pathIdentityResult(at: parent).matches(reservation.parentIdentity) else {
                occupied[slot] = OccupiedSlot(recoveryPath: receiptURL.path)
                continue
            }
            if Self.pathExistsWithoutFollowing(reservation.quarantineURL) {
                occupied[slot] = OccupiedSlot(recoveryPath: reservation.quarantineURL.path)
            } else {
                let originalIdentity = Self.pathIdentityResult(at: reservation.originalURL)
                if originalIdentity.matches(reservation.leafIdentity) {
                    // The initial rename did not commit, or a rollback restored the
                    // exact recorded leaf. Sync the same pinned identity before
                    // erasing the durable recovery record.
                    do {
                        try Self.synchronizeDirectory(parent, matching: reservation.parentIdentity)
                        guard case .absent = removeReceipt(receiptURL) else {
                            throw FilesystemQuarantineLedgerError.receiptRetained(
                                receiptURL.path,
                                "the reconciled receipt could not be verified absent"
                            )
                        }
                    } catch {
                        occupied[slot] = OccupiedSlot(recoveryPath: receiptURL.path)
                    }
                } else {
                    // Absence, a different identity, and every lstat error remain
                    // occupied. The immutable receipt has no terminal phase or
                    // destination identity, so restart alone is not proof that a
                    // terminal mutation completed safely.
                    occupied[slot] = OccupiedSlot(recoveryPath: receiptURL.path)
                }
            }
        }
        return occupied
    }

    private func readReceipt(at receiptURL: URL) throws -> ReceiptRead? {
        guard Self.pathExistsWithoutFollowing(receiptURL) else { return nil }
        let data: Data
        do {
            data = try OwnerOnlyAtomicFile.read(
                from: receiptURL,
                maximumBytes: Self.maximumReceiptBytes
            )
        } catch {
            return ReceiptRead(reservation: nil, recoveryPath: receiptURL.path)
        }
        guard let object = try? JSONSupport.object(from: data),
              (object["schema_version"] as? NSNumber)?.intValue == 1,
              let identifier = object["reservation_id"] as? String,
              let slotNumber = object["slot"] as? NSNumber,
              let originalPath = object["original_path"] as? String,
              let quarantinePath = object["quarantine_path"] as? String,
              let operation = object["operation"] as? String,
              let processInstanceID = object["process_instance_id"] as? String,
              let parentObject = object["parent_identity"] as? [String: Any],
              let leafObject = object["leaf_identity"] as? [String: Any],
              let parentIdentity = Self.identity(from: parentObject),
              let leafIdentity = Self.identity(from: leafObject) else {
            return ReceiptRead(reservation: nil, recoveryPath: receiptURL.path)
        }
        let slot = slotNumber.intValue
        let originalURL = URL(fileURLWithPath: originalPath).standardizedFileURL
        let quarantineURL = URL(fileURLWithPath: quarantinePath).standardizedFileURL
        guard slot >= 0,
              slot < Self.maximumReservations,
              !identifier.isEmpty,
              !processInstanceID.isEmpty,
              receiptURL == slotURL(slot),
              originalURL.path.hasPrefix("/"),
              quarantineURL.deletingLastPathComponent() == originalURL.deletingLastPathComponent(),
              quarantineURL.lastPathComponent == String(
                  format: ".forge-quarantine-v1-%02d",
                  slot
              ) else {
            return ReceiptRead(reservation: nil, recoveryPath: receiptURL.path)
        }
        return ReceiptRead(
            reservation: FilesystemQuarantineReservation(
                identifier: identifier,
                slot: slot,
                receiptURL: receiptURL,
                originalURL: originalURL,
                quarantineURL: quarantineURL,
                parentIdentity: parentIdentity,
                leafIdentity: leafIdentity,
                operation: operation,
                processInstanceID: processInstanceID
            ),
            recoveryPath: quarantineURL.path
        )
    }

    private func receiptObject(_ reservation: FilesystemQuarantineReservation) -> [String: Any] {
        [
            "schema_version": 1,
            "reservation_id": reservation.identifier,
            "slot": reservation.slot,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "original_path": reservation.originalURL.path,
            "quarantine_path": reservation.quarantineURL.path,
            "operation": reservation.operation,
            "process_instance_id": reservation.processInstanceID,
            "parent_identity": Self.identityObject(reservation.parentIdentity),
            "leaf_identity": Self.identityObject(reservation.leafIdentity),
        ]
    }

    private func slotURL(_ slot: Int) -> URL {
        root.appendingPathComponent(String(format: "slot-%02d.json", slot))
    }

    private func createReceipt(_ data: Data, at destination: URL) throws {
        let descriptor = destination.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == EEXIST {
                throw FilesystemQuarantineLedgerError.receiptRetained(
                    destination.path,
                    "a receipt already occupies this fixed slot"
                )
            }
            throw FilesystemQuarantineLedgerError.lockFailure(code)
        }
        // A partial fixed-slot receipt remains occupied and is therefore counted
        // against the global bound until an operator recovers it.
        defer { _ = Darwin.close(descriptor) }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count > 0 {
                        offset += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        throw FilesystemQuarantineLedgerError.lockFailure(errno)
                    }
                }
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw FilesystemQuarantineLedgerError.lockFailure(errno)
            }
            try Self.synchronizeDirectory(root)
        } catch {
            throw FilesystemQuarantineLedgerError.receiptRetained(
                destination.path,
                error.localizedDescription
            )
        }
    }

    private enum ReceiptRemovalResult {
        case absent
        case retained(String)
    }

    private func removeReceipt(_ receiptURL: URL) -> ReceiptRemovalResult {
        let removalError: Error?
        do {
            try receiptRemover(receiptURL)
            removalError = nil
        } catch {
            removalError = error
        }
        switch Self.pathIdentityResult(at: receiptURL) {
        case .absent:
            // An unlink followed by a failed parent fsync has no actionable live
            // recovery path. The terminal namespace durability remains the value
            // returned by the transition; a stale receipt may conservatively
            // reappear and occupy its bounded slot after a crash.
            return .absent
        case .present:
            return .retained(
                removalError?.localizedDescription ?? "the receipt still exists"
            )
        case .failed(let code):
            return .retained(
                removalError?.localizedDescription
                    ?? "receipt absence could not be verified (errno \(code))"
            )
        }
    }

    private static func identityObject(_ identity: FilesystemQuarantineIdentity) -> [String: Any] {
        [
            "device": identity.device,
            "inode": identity.inode,
            "mode": identity.mode,
            "owner": identity.owner,
            "group": identity.group,
        ]
    }

    private static func identity(from object: [String: Any]) -> FilesystemQuarantineIdentity? {
        guard let device = (object["device"] as? NSNumber)?.int64Value,
              let inode = (object["inode"] as? NSNumber)?.uint64Value,
              let mode = (object["mode"] as? NSNumber)?.uint32Value,
              let owner = (object["owner"] as? NSNumber)?.uint32Value,
              let group = (object["group"] as? NSNumber)?.uint32Value else {
            return nil
        }
        return FilesystemQuarantineIdentity(
            device: device,
            inode: inode,
            mode: mode,
            owner: owner,
            group: group
        )
    }

    private func withLedgerLock<Value>(_ body: () throws -> Value) throws -> Value {
        let deadline = Date().addingTimeInterval(Self.lockTimeoutSeconds)
        guard Self.processLock.lock(before: deadline) else {
            throw FilesystemQuarantineLedgerError.lockTimeout
        }
        defer { Self.processLock.unlock() }

        try ensureLedgerDirectory()
        let descriptor = lockURL.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw FilesystemQuarantineLedgerError.lockFailure(errno)
        }
        defer { _ = Darwin.close(descriptor) }

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                throw FilesystemQuarantineLedgerError.lockFailure(code)
            }
            guard Date() < deadline else {
                throw FilesystemQuarantineLedgerError.lockTimeout
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func ensureLedgerDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw FilesystemQuarantineLedgerError.invalidLedgerDirectory
        }
        var information = stat()
        guard root.path.withCString({ Darwin.lstat($0, &information) }) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == geteuid(),
              root.path.withCString({ Darwin.chmod($0, mode_t(S_IRWXU)) }) == 0 else {
            throw FilesystemQuarantineLedgerError.invalidLedgerDirectory
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw FilesystemQuarantineLedgerError.lockFailure(errno)
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw FilesystemQuarantineLedgerError.lockFailure(errno)
        }
    }

    private static func synchronizeDirectory(
        _ directory: URL,
        matching expectedIdentity: FilesystemQuarantineIdentity
    ) throws {
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw FilesystemQuarantineLedgerError.lockFailure(errno)
        }
        defer { _ = Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              expectedIdentity.matches(information) else {
            throw FilesystemQuarantineLedgerError.invalidPath
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw FilesystemQuarantineLedgerError.lockFailure(errno)
        }
    }

    private enum PathIdentityResult {
        case present(stat)
        case absent
        case failed(Int32)

        func matches(_ expected: FilesystemQuarantineIdentity) -> Bool {
            guard case .present(let information) = self else { return false }
            return expected.matches(information)
        }
    }

    private static func pathIdentityResult(at url: URL) -> PathIdentityResult {
        var information = stat()
        guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
            let code = errno
            return code == ENOENT ? .absent : .failed(code)
        }
        return .present(information)
    }

    private static func pathExistsWithoutFollowing(_ url: URL) -> Bool {
        var information = stat()
        if url.path.withCString({ Darwin.lstat($0, &information) }) == 0 { return true }
        return errno != ENOENT
    }
}

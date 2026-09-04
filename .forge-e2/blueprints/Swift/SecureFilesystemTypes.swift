import Darwin
import Foundation

public struct FilesystemRootID: Hashable, Codable, Sendable {
    public let rawValue: String
}

public enum FilesystemAccessMode: String, Codable, Sendable {
    case read
    case mutate
}

public struct FilesystemObjectIdentity: Equatable, Codable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let mode: UInt32
    public let owner: UInt32
    public let group: UInt32
    public let linkCount: UInt64
    public let size: Int64
}

/// Immutable reference-counted ownership. The raw descriptor is never exposed for
/// independent closing; a retained closure borrow keeps it alive across the syscall.
public final class OwnedFileDescriptor: @unchecked Sendable {
    private let rawValue: Int32

    public init(taking rawValue: Int32) {
        precondition(rawValue >= 0)
        self.rawValue = rawValue
    }

    public func withBorrowedDescriptor<T>(
        _ body: (Int32) throws -> T
    ) rethrows -> T {
        try withExtendedLifetime(self) {
            try body(rawValue)
        }
    }

    deinit {
        _ = Darwin.close(rawValue)
    }
}

/// Retains a balanced security-scoped access lease where required.
public final class SecurityScopeLease: @unchecked Sendable {
    private let url: URL
    private let active: Bool

    public init(url: URL) {
        self.url = url
        active = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if active { url.stopAccessingSecurityScopedResource() }
    }
}

public struct AuthorizedRootHandle: Sendable {
    public let rootID: FilesystemRootID
    public let projectID: ProjectID
    public let generation: ProjectGeneration
    public let identity: FilesystemObjectIdentity
    public let access: FilesystemAccessMode
    public let descriptor: OwnedFileDescriptor
    public let securityScope: SecurityScopeLease?
    public let displayURL: URL
}

public struct AuthorizedFilesystemPath: Sendable {
    public let root: AuthorizedRootHandle
    public let relativeComponents: [String]
    public let displayURL: URL
    public let mode: FilesystemAccessMode
}

public enum FilesystemTransactionState: String, Codable, Sendable {
    case prepared
    case sourceCaptured
    case sourceVerified
    case destinationStaged
    case destinationPublished
    case sourceDisposed
    case committed
    case cancelled
    case restorePending
    case cleanupPending
    case quarantined
    case failedRecoverable
    case failedTerminal
}

public enum FilesystemConflictDisposition: String, Codable, Sendable {
    case restored
    case quarantined
}

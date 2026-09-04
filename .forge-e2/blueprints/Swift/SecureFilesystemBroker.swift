import Foundation

public actor SecureFilesystemBroker {
    private let repository: FilesystemTransactionRepository
    private let policy: ResourcePolicy

    public init(
        repository: FilesystemTransactionRepository,
        policy: ResourcePolicy
    ) {
        self.repository = repository
        self.policy = policy
    }

    /// Delete semantics:
    /// - no version: delete the entry present at atomic capture time;
    /// - version: capture, verify, then dispose or restore/quarantine.
    public func delete(
        path: AuthorizedFilesystemPath,
        expectedVersion: String?,
        cancellation: ToolCallCancellation?
    ) async throws -> FilesystemMutationReceipt {
        // Production implementation follows docs/04 and docs/06.
        fatalError("Implementation required by E2-05")
    }

    public func move(
        source: AuthorizedFilesystemPath,
        destination: AuthorizedFilesystemPath,
        expectedVersion: String?,
        cancellation: ToolCallCancellation?
    ) async throws -> FilesystemMutationReceipt {
        fatalError("Implementation required by E2-06 and E2-07")
    }

    public func write(
        path: AuthorizedFilesystemPath,
        bytes: Data,
        mode: WriteMode,
        expectedVersion: String?,
        cancellation: ToolCallCancellation?
    ) async throws -> FilesystemMutationReceipt {
        fatalError("Implementation required by E2-04")
    }
}

public protocol FilesystemTransactionRepository: Sendable {
    func create(_ transaction: FilesystemTransactionRecord) async throws
    func transition(
        id: String,
        from expected: FilesystemTransactionState,
        to next: FilesystemTransactionState,
        receipt: Data?
    ) async throws
}

public enum WriteMode: Sendable {
    case createOnly
    case replaceCurrent
}

public struct FilesystemMutationReceipt: Codable, Sendable {
    public let transactionID: String
    public let status: String
    public let committed: Bool
    public let durabilityConfirmed: Bool
    public let quarantineID: String?
}

public struct FilesystemTransactionRecord: Codable, Sendable {
    public let transactionID: String
    public let projectID: String
    public let projectGeneration: Int
    public let operation: String
    public let state: FilesystemTransactionState
}

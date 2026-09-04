import Foundation

/// Blueprint only. Integrate with project-generation fencing, the control-plane
/// repository, and the CForgeSecureFS descriptor wrappers before production use.
actor AtomicNamespaceTransactionCoordinator {
    enum Contract: String, Sendable, Codable {
        case currentEntry
        case exactVersion
    }

    enum Phase: String, Sendable, Codable {
        case prepared
        case sourceCaptured
        case sourceVerified
        case destinationStaged
        case destinationPublished
        case sourceDisposed
        case restorePending
        case cleanupPending
        case quarantined
        case committed
        case cancelled
        case failedRecoverable
        case failedTerminal
    }

    struct Intent: Sendable, Codable {
        let transactionID: UUID
        let projectID: UUID
        let projectGeneration: Int64
        let operation: String
        let contract: Contract
        let sourceRootID: UUID
        let sourceComponents: [String]
        let destinationRootID: UUID?
        let destinationComponents: [String]?
        let expectedVersionToken: String?
    }

    protocol Repository: Sendable {
        func insertPrepared(_ intent: Intent) async throws
        func recordPhase(
            transactionID: UUID,
            phase: Phase,
            receipt: Data?
        ) async throws
        func loadRecoverable(limit: Int) async throws -> [Intent]
    }

    protocol NativeFilesystem: Sendable {
        func captureCurrentEntry(_ intent: Intent) async throws -> CaptureReceipt
        func inspectCapture(_ receipt: CaptureReceipt) async throws -> VersionReceipt
        func restoreCaptureExclusively(_ receipt: CaptureReceipt) async throws -> RestoreReceipt
        func disposeCapture(_ receipt: CaptureReceipt) async throws -> DisposalReceipt
        func recoverNamespace(_ intent: Intent) async throws -> NamespaceObservation
    }

    struct CaptureReceipt: Sendable, Codable {
        let transactionID: UUID
        let transactionDirectoryIdentity: String
        let capturedIdentity: String
        let sourceParentIdentity: String
        let capturedLeaf: String
    }

    struct VersionReceipt: Sendable, Codable {
        let token: String
        let manifestDigest: String
    }

    struct RestoreReceipt: Sendable, Codable {
        let restored: Bool
        let sourceOccupied: Bool
    }

    struct DisposalReceipt: Sendable, Codable {
        let entriesRemoved: Int
        let durabilityConfirmed: Bool
    }

    struct NamespaceObservation: Sendable, Codable {
        let sourcePresent: Bool
        let capturePresent: Bool
        let destinationPresent: Bool
        let observedIdentities: [String: String]
    }

    private let repository: Repository
    private let native: NativeFilesystem

    init(repository: Repository, native: NativeFilesystem) {
        self.repository = repository
        self.native = native
    }

    func delete(_ intent: Intent) async throws -> DisposalReceipt {
        precondition(intent.operation == "delete")
        try await repository.insertPrepared(intent)

        let capture = try await native.captureCurrentEntry(intent)
        try await repository.recordPhase(
            transactionID: intent.transactionID,
            phase: .sourceCaptured,
            receipt: try JSONEncoder().encode(capture)
        )

        if intent.contract == .exactVersion {
            guard let expected = intent.expectedVersionToken else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            let actual = try await native.inspectCapture(capture)
            guard actual.token == expected else {
                try await repository.recordPhase(
                    transactionID: intent.transactionID,
                    phase: .restorePending,
                    receipt: try JSONEncoder().encode(actual)
                )
                let restored = try await native.restoreCaptureExclusively(capture)
                let terminal: Phase = restored.restored ? .cancelled : .quarantined
                try await repository.recordPhase(
                    transactionID: intent.transactionID,
                    phase: terminal,
                    receipt: try JSONEncoder().encode(restored)
                )
                throw FilesystemConflict.versionMismatch(restored: restored.restored)
            }
        }

        try await repository.recordPhase(
            transactionID: intent.transactionID,
            phase: .sourceVerified,
            receipt: nil
        )
        let disposal = try await native.disposeCapture(capture)
        try await repository.recordPhase(
            transactionID: intent.transactionID,
            phase: .sourceDisposed,
            receipt: try JSONEncoder().encode(disposal)
        )
        try await repository.recordPhase(
            transactionID: intent.transactionID,
            phase: .committed,
            receipt: try JSONEncoder().encode(disposal)
        )
        return disposal
    }

    func recover(limit: Int = 32) async {
        // Never infer a missing effect from the ledger alone. Inspect namespace
        // state first, then write a reconciliation receipt before continuing.
        guard let intents = try? await repository.loadRecoverable(limit: limit) else {
            return
        }
        for intent in intents {
            _ = try? await native.recoverNamespace(intent)
        }
    }
}

enum FilesystemConflict: Error, Sendable {
    case versionMismatch(restored: Bool)
}

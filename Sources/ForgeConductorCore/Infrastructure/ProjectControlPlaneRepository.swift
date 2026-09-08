// ProjectControlPlaneRepository.swift
// Owns durable project bindings and generation fences on one serialized SQLite connection.

import Foundation
import Darwin
import SQLite3

// Opaque values are issued only in this repository file. Identifiers remain locators,
// and every operation independently checks durable caller/lease/project authority.
struct NativeSourceConversationLease: Sendable {
    let conversationID: UUID, taskID: UUID, capabilityID: UUID
    let capabilityEpoch: Int64
    let managerInstanceID: UUID
    let leaseEpoch: Int64
    let expiresAt: String
    fileprivate init(conversationID: UUID, taskID: UUID, capabilityID: UUID, capabilityEpoch: Int64,
                     managerInstanceID: UUID, leaseEpoch: Int64, expiresAt: String) {
        self.conversationID = conversationID; self.taskID = taskID; self.capabilityID = capabilityID
        self.capabilityEpoch = capabilityEpoch; self.managerInstanceID = managerInstanceID
        self.leaseEpoch = leaseEpoch; self.expiresAt = expiresAt
    }
}
struct NativeSourceProviderCallReference: Sendable {
    let conversationID: UUID, stageID: UUID
    let ordinal: Int
    fileprivate let checksum: String
    fileprivate init(conversationID: UUID, stageID: UUID, ordinal: Int, checksum: String) {
        self.conversationID = conversationID; self.stageID = stageID; self.ordinal = ordinal; self.checksum = checksum
    }
}
struct NativeSourceProviderDispatchClaim: Sendable {
    let conversationID: UUID, stageID: UUID
    fileprivate let nonce: UUID, owner: UUID
    fileprivate let epoch: Int64
    fileprivate let intentSHA: String
}
struct NativeSourceCapabilityCheckClaim: Sendable {
    let checkID: UUID, conversationID: UUID, stageID: UUID
    fileprivate let nonce: UUID, owner: UUID
    fileprivate let epoch: Int64
}

/// Storage-only authority over the existing conversation lease. This cannot be
/// passed to provider or tool APIs, and every use rechecks the retained fence.
struct NativeSourcePressureClaim: Sendable {
    let conversationID: UUID, taskID: UUID, capabilityID: UUID, stageID: UUID
    let capabilityEpoch: Int64, leaseEpoch: Int64, fenceRevision: Int64
    let managerInstanceID: UUID
    let expiresAt: String, storageDeadline: String, dispositionSHA256: String
    fileprivate init(conversationID: UUID, taskID: UUID, capabilityID: UUID, stageID: UUID,
        capabilityEpoch: Int64, leaseEpoch: Int64, fenceRevision: Int64, managerInstanceID: UUID,
        expiresAt: String, storageDeadline: String, dispositionSHA256: String) {
        self.conversationID = conversationID; self.taskID = taskID; self.capabilityID = capabilityID
        self.stageID = stageID; self.capabilityEpoch = capabilityEpoch; self.leaseEpoch = leaseEpoch
        self.fenceRevision = fenceRevision; self.managerInstanceID = managerInstanceID
        self.expiresAt = expiresAt; self.storageDeadline = storageDeadline; self.dispositionSHA256 = dispositionSHA256
    }
}
struct NativeSourcePressureRecoveryReference: Sendable {
    let conversationID: UUID, stageID: UUID, taskID: UUID, capabilityID: UUID, reservationID: UUID
}
struct NativeSourcePressureReceiptClaim: Sendable {
    fileprivate let reference: NativeSourcePressureRecoveryReference
    fileprivate let managerID: UUID
    fileprivate let leaseEpoch: Int64
    fileprivate let expiresAt: String
    fileprivate let dispositionSHA256: String
    fileprivate let packetSHA256: String
}

struct NativeSourcePressureCommitAdmission: Sendable {
    let reservationID: UUID
    let prepared: PreparedContinuitySourceCommit
    let authorization: ContinuityIngressAuthorization
    let automaticHandoffEnabled: Bool
    fileprivate let dispositionSHA256: String
}
enum NativeSourcePressureCommitAdmissionResult: Sendable {
    case commit(NativeSourcePressureCommitAdmission)
    case completed(ContinuityHandoffCommit)
}
struct NativeSourcePressureCommitAttempt: Sendable {
    fileprivate let admission: NativeSourcePressureCommitAdmission
    fileprivate let number: Int64
    fileprivate let managerID: UUID
    fileprivate let leaseEpoch: Int64
    fileprivate let automatic: Bool
}
enum NativeSourcePressureAttemptResult: Sendable {
    case commit(NativeSourcePressureCommitAttempt)
    case completed(ContinuityHandoffCommit)
}

enum NativeSourceBudgetDispositionResult: Sendable {
    case pressure(NativeSourcePressureClaim)
    case blocked(NativeSourceStoredBudgetDisposition)
}

enum ProjectRegistrationControlExpectation: Sendable, Equatable {
    case unchecked
    case absent
    case existing(ProjectGeneration)
}

enum ProjectControlPublicationDisposition: Sendable, Equatable {
    case active
    case awaitingIdentityPublication

    var lifecycleState: ProjectLifecycleState {
        switch self {
        case .active: .active
        case .awaitingIdentityPublication: .maintenance
        }
    }
}

private enum ProjectTransitionAuthorityKind: String {
    case registration
    case relink
}

private enum ProjectTransitionAuthorityState: String {
    case staged
    case published
}

private struct ProjectTransitionAuthorityIdentity: Equatable {
    let projectID: String
    let kind: ProjectTransitionAuthorityKind
    let operationID: String
    let priorGeneration: UInt64
    let newGeneration: UInt64
    let targetRootSHA256: String
    let repositoryIdentitySHA256: String
    let directoryDevice: String
    let directoryInode: String
    let authoritySHA256: String
}

private struct ProjectTransitionAuthorityRecord {
    let sequence: Int64
    let identity: ProjectTransitionAuthorityIdentity
    let state: ProjectTransitionAuthorityState
    let createdAt: String
    let publishedAt: String?
}

public actor ProjectControlPlaneRepository {
    public static let schemaVersion = 2
    public static let maximumQuarantineEventsPerProject = 128
    public static let maximumContextBudgetObservationsPerSession = 2_048
    private static let maximumContextBudgetObservationBytes = 64 * 1_024
    public static let maximumContextBudgetActionRequestsPerRead = 256
    public static let maximumPublishedProjectTransitionAuthoritiesPerProject = 16
    static let maximumContinuityTaskAuthorizations = 1_024
    static let maximumActiveContinuityTasksPerProject = 128
    static let maximumContinuityIngressAcceptances = 1_024

    public let databaseURL: URL

    private let clock: any Clock
    private var connection: ControlPlaneSQLiteConnection?
    // Ephemeral manager authority is deliberately not decoded from workspace JSON
    // or persisted as a bearer credential. Restart requires fresh validation.
    // This separates model tools from the manager, not a hostile unrestricted UID.
    private struct CompletionApproval {
        let run: AutonomousRunRecord
        let ownerID: String
        let leaseEpoch: UInt64
        let proofSHA256: String
        let expiresAt: Date
    }
    private var completionApprovals: [RunID: CompletionApproval] = [:]
    private var openRegistration: SQLiteOpenRegistration?
    private var busyRetryObserver: (@Sendable () -> Void)?
    private var beforeCommitObserver: (@Sendable () throws -> Void)?
    private var didCommitObserver: (@Sendable () -> Void)?
    private var beforeCommitSynchronousObserver: (@Sendable (Int) -> Void)?

    public init(
        databaseURL: URL,
        clock: any Clock = SystemClock(),
        busyTimeoutMilliseconds: Int = 5_000
    ) throws {
        guard (1...30_000).contains(busyTimeoutMilliseconds) else {
            throw ProjectContextError.databaseFailure("busy timeout must be between 1 and 30000 milliseconds")
        }
        self.databaseURL = databaseURL.standardizedFileURL
        self.clock = clock
        let standardizedDatabaseURL = databaseURL.standardizedFileURL
        do {
            let initialized = try VerifiedMigrationBackup.withMigrationLock(
                databaseURL: standardizedDatabaseURL,
                timeoutSeconds: 60
            ) {
                try VerifiedMigrationBackup.withNonMutatingSQLitePreflight(
                    databaseURL: standardizedDatabaseURL
                ) { candidate in
                    guard let candidate else { return }
                    let userVersion = try candidate.integer("PRAGMA user_version;") ?? 0
                    let hasVersionTable = try candidate.integer(
                        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='control_schema_version'"
                    ) == 1
                    let rowCount = hasVersionTable
                        ? try candidate.integer("SELECT COUNT(*) FROM control_schema_version") ?? 0
                        : 0
                    let storedVersion = hasVersionTable
                        ? try candidate.integer(
                            "SELECT version FROM control_schema_version WHERE singleton=1"
                        ) ?? 0
                        : 0
                    let priorVersion = max(userVersion, storedVersion)
                    if priorVersion == 0, !hasVersionTable {
                        try candidate.requireEmptySchemaWhenUnversioned(reportedVersion: 0)
                        return
                    }
                    guard userVersion == Self.schemaVersion,
                          hasVersionTable,
                          rowCount == 1,
                          storedVersion == Self.schemaVersion else {
                        throw ProjectContextError.unsupportedSchemaVersion(priorVersion)
                    }
                    let journal = try candidate.integer("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='native_source_provider_turns'") ?? 0
                    if journal != 0 {
                        let pressure = try candidate.integer("SELECT COUNT(*) FROM pragma_table_xinfo('native_source_provider_turns') WHERE name IN('pressure_decision_json','pressure_decision_sha256','pressure_reservation_id')") ?? 0
                        guard (pressure == 0 || pressure == 3),
                              try NativeSourcePressureSchema.validate(hasColumns: pressure == 3,
                                integer: { try candidate.integer($0) }, text: { try candidate.text($0) }) else {
                            throw ProjectContextError.integrityFailure("unsupported native source pressure journal extension")
                        }
                    }
                    _ = try VerifiedMigrationBackup.reconcileMigrationManifest(
                        sourceURL: standardizedDatabaseURL,
                        observedVersion: try candidate.integer(ControlPlaneSQLiteConnection.ingressSchemaCapabilityVersionQuery) ?? 0,
                        scope: .continuityIngress)
                }
                let connection = try ControlPlaneSQLiteConnection(
                    databaseURL: standardizedDatabaseURL,
                    busyTimeoutMilliseconds: busyTimeoutMilliseconds,
                    migrationTimestamp: ISO8601.string(from: clock.now())
                )
                do {
                    let registration = try VerifiedMigrationBackup.registerOpenDatabase(
                        at: standardizedDatabaseURL
                    )
                    return (connection, registration)
                } catch {
                    connection.close()
                    throw error
                }
            }
            self.connection = initialized.0
            self.openRegistration = initialized.1
        } catch let error as ProjectContextError {
            throw error
        } catch {
            throw ProjectContextError.integrityFailure(error.localizedDescription)
        }
    }

    deinit {
        connection?.close()
        VerifiedMigrationBackup.unregisterOpenDatabase(openRegistration)
    }

    func configureOperationObservers(
        busyRetry: (@Sendable () -> Void)? = nil,
        beforeCommit: (@Sendable () throws -> Void)? = nil,
        didCommit: (@Sendable () -> Void)? = nil,
        beforeCommitSynchronous: (@Sendable (Int) -> Void)? = nil
    ) {
        busyRetryObserver = busyRetry
        beforeCommitObserver = beforeCommit
        didCommitObserver = didCommit
        beforeCommitSynchronousObserver = beforeCommitSynchronous
    }

    public func close() {
        completionApprovals.removeAll()
        connection?.close()
        connection = nil
        VerifiedMigrationBackup.unregisterOpenDatabase(openRegistration)
        openRegistration = nil
    }

    @discardableResult
    @available(*, deprecated, message: "Use ManagerNode or ToolRouter project registration")
    public func registerProject(
        projectID: ProjectID,
        displayName: String,
        canonicalRoot: URL,
        repositoryFingerprint: String? = nil,
        bookmarkReference: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord {
        _ = projectID
        _ = displayName
        _ = canonicalRoot
        _ = repositoryFingerprint
        _ = bookmarkReference
        try cancellation?.checkCancellation()
        throw ProjectContextError.projectTransitionCoordinatorRequired
    }

    @discardableResult
    func registerProjectUnchecked(
        projectID: ProjectID,
        displayName: String,
        canonicalRoot: URL,
        repositoryFingerprint: String? = nil,
        bookmarkReference: String? = nil,
        controlExpectation: ProjectRegistrationControlExpectation = .unchecked,
        targetDirectoryIdentity: ProjectDirectoryIdentity? = nil,
        disposition: ProjectControlPublicationDisposition = .active,
        transitionOperationID: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord {
        try cancellation?.checkCancellation()
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 512 else {
            throw ProjectContextError.invalidIdentifier("project display name")
        }
        let root = try Self.canonicalRoot(canonicalRoot)
        let fingerprint = try Self.boundedOptional(repositoryFingerprint, maximumBytes: 2_048, field: "repository fingerprint")
        let bookmark = try Self.boundedOptional(bookmarkReference, maximumBytes: 16 * 1_024, field: "bookmark reference")
        let operationID = try Self.validatedTransitionOperationID(
            transitionOperationID,
            required: disposition == .awaitingIdentityPublication
        )
        let transitionGeneration: ProjectGeneration
        if case .existing(let expectedGeneration) = controlExpectation {
            transitionGeneration = expectedGeneration
        } else {
            transitionGeneration = .initial
        }
        let transitionMetadata: [String: String]?
        let transitionAuthority: ProjectTransitionAuthorityIdentity?
        if disposition == .awaitingIdentityPublication {
            guard let operationID, let targetDirectoryIdentity else {
                throw ProjectContextError.invalidIdentifier(
                    "registration transition authority"
                )
            }
            transitionMetadata = Self.projectTransitionMetadata(
                operationID: operationID,
                priorGeneration: transitionGeneration,
                newGeneration: transitionGeneration,
                root: root,
                repositoryFingerprint: fingerprint,
                directoryIdentity: targetDirectoryIdentity
            )
            transitionAuthority = Self.projectTransitionAuthorityIdentity(
                kind: .registration,
                projectID: projectID,
                operationID: operationID,
                priorGeneration: transitionGeneration,
                newGeneration: transitionGeneration,
                root: root,
                repositoryFingerprint: fingerprint,
                directoryIdentity: targetDirectoryIdentity
            )
        } else {
            transitionMetadata = nil
            transitionAuthority = nil
        }
        let timestamp = ISO8601.string(from: clock.now())
        try cancellation?.checkCancellation()

        return try controlledTransaction(
            cancellation: cancellation,
            beforeCommitValidation: {
                if let targetDirectoryIdentity {
                    try Self.validateDirectoryIdentity(
                        root,
                        expected: targetDirectoryIdentity,
                        failure: .projectRegistrationTargetChanged(projectID)
                    )
                }
            }
        ) { connection in
            if let targetDirectoryIdentity {
                try Self.validateDirectoryIdentity(
                    root,
                    expected: targetDirectoryIdentity,
                    failure: .projectRegistrationTargetChanged(projectID)
                )
            }
            if let current = try projectUnlocked(projectID, connection: connection) {
                switch controlExpectation {
                case .unchecked:
                    break
                case .absent:
                    throw ProjectContextError.projectScopeMismatch
                case .existing(let expected):
                    guard current.generation == expected else {
                        throw ProjectContextError.staleProjectGeneration(
                            expected: expected,
                            actual: current.generation
                        )
                    }
                }
                guard current.canonicalRoot.path == root.path else {
                    throw ProjectContextError.projectRelinkRequired(projectID)
                }
                if let rootOwner = try projectAtRootUnlocked(root, connection: connection),
                   rootOwner.projectID != projectID {
                    throw ProjectContextError.projectRootAlreadyRegistered(root.path)
                }
                let priorLifecycle = current.lifecycleState
                switch (priorLifecycle, disposition) {
                case (.active, .active):
                    break
                case (.active, .awaitingIdentityPublication):
                    guard case .existing(let expectedGeneration) = controlExpectation,
                          expectedGeneration == current.generation,
                          current.repositoryFingerprint == nil,
                          fingerprint != nil,
                          transitionMetadata != nil,
                          transitionAuthority != nil else {
                        throw ProjectContextError.projectTransitionConflict(projectID)
                    }
                case (.maintenance, .awaitingIdentityPublication):
                    guard let transitionAuthority else {
                        throw ProjectContextError.projectTransitionConflict(projectID)
                    }
                    try requireTransitionAuthorityUnlocked(
                        projectID: projectID,
                        identity: transitionAuthority,
                        state: .staged,
                        connection: connection
                    )
                case (.maintenance, .active):
                    throw ProjectContextError.projectTransitionConflict(projectID)
                default:
                    throw ProjectContextError.projectNotActive(priorLifecycle)
                }
                let changed = try connection.execute(
                    """
                    UPDATE control_projects SET
                        display_name=?,lifecycle_state=?,repository_fingerprint=?,bookmark_reference=?,updated_at=?
                    WHERE project_id=? AND canonical_root=? AND generation=? AND lifecycle_state=?
                    """,
                    bindings: [
                        .text(name), .text(disposition.lifecycleState.rawValue),
                        .optionalText(fingerprint), .optionalText(bookmark),
                        .text(timestamp), .text(projectID.description), .text(root.path),
                        .int64(try Self.sqliteGeneration(current.generation)),
                        .text(priorLifecycle.rawValue),
                    ]
                )
                guard changed == 1 else {
                    throw ProjectContextError.projectTransitionConflict(projectID)
                }
                if priorLifecycle == .active,
                   disposition == .awaitingIdentityPublication,
                   let transitionMetadata,
                   let transitionAuthority {
                    try stageTransitionAuthorityUnlocked(
                        transitionAuthority,
                        timestamp: timestamp,
                        connection: connection
                    )
                    try appendEventUnlocked(
                        projectID: projectID,
                        eventType: "project_registration_staged",
                        severity: "info",
                        summary: "Project registration is fenced pending identity publication",
                        metadata: transitionMetadata,
                        connection: connection
                    )
                }
                guard let refreshed = try projectUnlocked(projectID, connection: connection) else {
                    throw ProjectContextError.integrityFailure("updated project could not be read back")
                }
                return refreshed
            }
            if case .existing = controlExpectation {
                throw ProjectContextError.projectNotFound(projectID)
            }
            if try projectAtRootUnlocked(root, connection: connection) != nil {
                throw ProjectContextError.projectRootAlreadyRegistered(root.path)
            }
            try connection.execute(
                """
                INSERT INTO control_projects(
                    project_id,display_name,canonical_root,generation,lifecycle_state,
                    repository_fingerprint,bookmark_reference,created_at,updated_at
                ) VALUES(?,?,?,1,?,?,?,?,?)
                """,
                bindings: [
                    .text(projectID.description), .text(name), .text(root.path),
                    .text(disposition.lifecycleState.rawValue),
                    .optionalText(fingerprint), .optionalText(bookmark),
                    .text(timestamp), .text(timestamp),
                ]
            )
            guard let inserted = try projectUnlocked(projectID, connection: connection) else {
                throw ProjectContextError.integrityFailure("registered project could not be read back")
            }
            if disposition == .awaitingIdentityPublication,
               let transitionMetadata,
               let transitionAuthority {
                try stageTransitionAuthorityUnlocked(
                    transitionAuthority,
                    timestamp: timestamp,
                    connection: connection
                )
                try appendEventUnlocked(
                    projectID: projectID,
                    eventType: "project_registration_staged",
                    severity: "info",
                    summary: "Project registration is fenced pending identity publication",
                    metadata: transitionMetadata,
                    connection: connection
                )
            }
            return inserted
        }
    }

    /// Makes one exact registration usable only after the caller has durably
    /// published the independently discovered identity and canonical alias.
    func finalizeRegistration(
        projectID: ProjectID,
        generation: ProjectGeneration,
        target: ProjectIdentityTarget,
        transitionOperationID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord {
        try cancellation?.checkCancellation()
        try Self.validate(generation)
        let root = try Self.canonicalRoot(target.canonicalRoot)
        let fingerprint = try Self.boundedOptional(
            target.repositoryIdentity,
            maximumBytes: 2_048,
            field: "repository fingerprint"
        )
        guard let operationID = try Self.validatedTransitionOperationID(
            transitionOperationID,
            required: true
        ) else {
            throw ProjectContextError.invalidIdentifier("registration transition authority")
        }
        let transitionMetadata = Self.projectTransitionMetadata(
            operationID: operationID,
            priorGeneration: generation,
            newGeneration: generation,
            root: root,
            repositoryFingerprint: fingerprint,
            directoryIdentity: target.directoryIdentity
        )
        let transitionAuthority = Self.projectTransitionAuthorityIdentity(
            kind: .registration,
            projectID: projectID,
            operationID: operationID,
            priorGeneration: generation,
            newGeneration: generation,
            root: root,
            repositoryFingerprint: fingerprint,
            directoryIdentity: target.directoryIdentity
        )
        let timestamp = ISO8601.string(from: clock.now())
        return try controlledTransaction(
            cancellation: cancellation,
            beforeCommitValidation: {
                try Self.validateDirectoryIdentity(
                    root,
                    expected: target.directoryIdentity,
                    failure: .projectRegistrationTargetChanged(projectID)
                )
            }
        ) { connection in
            try Self.validateDirectoryIdentity(
                root,
                expected: target.directoryIdentity,
                failure: .projectRegistrationTargetChanged(projectID)
            )
            guard let current = try projectUnlocked(projectID, connection: connection) else {
                throw ProjectContextError.projectNotFound(projectID)
            }
            guard current.generation == generation else {
                throw ProjectContextError.staleProjectGeneration(
                    expected: generation,
                    actual: current.generation
                )
            }
            guard current.canonicalRoot == root,
                  current.repositoryFingerprint == fingerprint else {
                throw ProjectContextError.projectScopeMismatch
            }
            if current.lifecycleState == .active {
                try requireTransitionAuthorityUnlocked(
                    projectID: projectID,
                    identity: transitionAuthority,
                    state: .published,
                    connection: connection
                )
                return current
            }
            guard current.lifecycleState == .maintenance,
                  current.generation == generation else {
                throw ProjectContextError.projectNotActive(current.lifecycleState)
            }
            try requireTransitionAuthorityUnlocked(
                projectID: projectID,
                identity: transitionAuthority,
                state: .staged,
                connection: connection
            )
            let changed = try connection.execute(
                """
                UPDATE control_projects SET lifecycle_state='active',updated_at=?
                WHERE project_id=? AND canonical_root=? AND generation=?
                  AND lifecycle_state='maintenance'
                """,
                bindings: [
                    .text(timestamp), .text(projectID.description), .text(root.path),
                    .int64(try Self.sqliteGeneration(generation)),
                ]
            )
            guard changed == 1 else {
                throw ProjectContextError.databaseFailure(
                    "project registration activation compare-and-set failed"
                )
            }
            try publishTransitionAuthorityUnlocked(
                projectID: projectID,
                identity: transitionAuthority,
                timestamp: timestamp,
                connection: connection
            )
            try appendEventUnlocked(
                projectID: projectID,
                eventType: "project_registration_published",
                severity: "info",
                summary: "Project registration identity publication completed",
                metadata: transitionMetadata,
                connection: connection
            )
            guard let activated = try projectUnlocked(projectID, connection: connection) else {
                throw ProjectContextError.integrityFailure(
                    "activated registered project could not be read back"
                )
            }
            return activated
        }
    }

    /// Proves the exact unsettled control-plane authority before the identity
    /// registry publishes a registration alias. Finalization repeats this
    /// proof; the separate check prevents reconciliation from publishing first.
    func validateRegistrationPublicationAuthority(
        projectID: ProjectID,
        generation: ProjectGeneration,
        target: ProjectIdentityTarget,
        transitionOperationID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try cancellation?.checkCancellation()
        try Self.validate(generation)
        let root = try Self.canonicalRoot(target.canonicalRoot)
        let fingerprint = try Self.boundedOptional(
            target.repositoryIdentity,
            maximumBytes: 2_048,
            field: "repository fingerprint"
        )
        guard let operationID = try Self.validatedTransitionOperationID(
            transitionOperationID,
            required: true
        ) else {
            throw ProjectContextError.invalidIdentifier("registration transition authority")
        }
        let authority = Self.projectTransitionAuthorityIdentity(
            kind: .registration,
            projectID: projectID,
            operationID: operationID,
            priorGeneration: generation,
            newGeneration: generation,
            root: root,
            repositoryFingerprint: fingerprint,
            directoryIdentity: target.directoryIdentity
        )
        try controlledOperation(cancellation: cancellation) { connection in
            try Self.validateDirectoryIdentity(
                root,
                expected: target.directoryIdentity,
                failure: .projectRegistrationTargetChanged(projectID)
            )
            guard let current = try projectUnlocked(projectID, connection: connection) else {
                throw ProjectContextError.projectNotFound(projectID)
            }
            guard current.generation == generation,
                  current.lifecycleState == .maintenance,
                  current.canonicalRoot == root,
                  current.repositoryFingerprint == fingerprint else {
                throw ProjectContextError.projectTransitionConflict(projectID)
            }
            try requireTransitionAuthorityUnlocked(
                projectID: projectID,
                identity: authority,
                state: .staged,
                connection: connection
            )
        }
    }

    public func project(
        _ projectID: ProjectID,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord? {
        try controlledOperation(cancellation: cancellation) { connection in
            try projectUnlocked(projectID, connection: connection)
        }
    }

    /// Holds the existing database writer fence while a bounded synchronous
    /// operation applies settings for this exact active generation. The operation
    /// must not call back into this repository or suspend; its own durable commit
    /// is the authoritative result if a later database commit fails.
    public func withActiveProjectGeneration<Value: Sendable>(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        operation: @Sendable () throws -> Value
    ) throws -> Value {
        try Self.validate(expectedGeneration)
        try Task.checkCancellation()
        let connection = try requiredConnection()
        return try connection.transaction {
            _ = try requiredActiveProjectUnlocked(
                projectID,
                generation: expectedGeneration,
                connection: connection
            )
            try Task.checkCancellation()
            return try operation()
        }
    }

    func project(
        atCanonicalRoot canonicalRoot: URL,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord? {
        let root = try Self.canonicalRoot(canonicalRoot)
        return try controlledOperation(cancellation: cancellation) { connection in
            try projectAtRootUnlocked(root, connection: connection)
        }
    }

    func project(
        repositoryFingerprint: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord? {
        guard let fingerprint = try Self.boundedOptional(
            repositoryFingerprint,
            maximumBytes: 2_048,
            field: "repository fingerprint"
        ) else {
            return nil
        }
        return try controlledOperation(cancellation: cancellation) { connection in
            let matches = try connection.all(
                """
                SELECT project_id,display_name,canonical_root,generation,lifecycle_state,
                       repository_fingerprint,bookmark_reference,created_at,updated_at
                FROM control_projects
                WHERE repository_fingerprint=? AND lifecycle_state!='archived'
                ORDER BY project_id LIMIT 2
                """,
                bindings: [.text(fingerprint)],
                map: Self.decodeProject
            )
            guard matches.count <= 1 else {
                throw ProjectContextError.integrityFailure(
                    "repository identity is assigned to multiple active projects"
                )
            }
            return matches.first
        }
    }

    /// Atomically changes the canonical root only for a quiescent project. The
    /// generation advance is the authority fence: all prior contexts remain
    /// stale even though relinking is refused while any live binding or run is
    /// present. Identity verification is supplied by the project identity
    /// registry and rechecked here against the stored repository fingerprint.
    @discardableResult
    @available(*, deprecated, message: "Use ManagerNode.relinkProject(projectID:expectedGeneration:path:)")
    public func relinkProject(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        newCanonicalRoot: URL,
        repositoryFingerprint: String?,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectRelinkReceipt {
        _ = projectID
        _ = expectedGeneration
        _ = newCanonicalRoot
        _ = repositoryFingerprint
        try cancellation?.checkCancellation()
        throw ProjectContextError.projectTransitionCoordinatorRequired
    }

    /// Internal control-plane primitive. Production call sites must provide a
    /// manager-owned, independently discovered target before reaching this API.
    @discardableResult
    func relinkProjectUnchecked(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        newCanonicalRoot: URL,
        repositoryFingerprint: String?,
        targetDirectoryIdentity: ProjectDirectoryIdentity? = nil,
        disposition: ProjectControlPublicationDisposition = .active,
        transitionOperationID: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectRelinkReceipt {
        try cancellation?.checkCancellation()
        try Self.validate(expectedGeneration)
        guard expectedGeneration.rawValue < UInt64(Int64.max) else {
            throw ProjectContextError.invalidGeneration(expectedGeneration.rawValue)
        }
        let root = try Self.canonicalRoot(newCanonicalRoot)
        let fingerprint = try Self.boundedOptional(
            repositoryFingerprint,
            maximumBytes: 2_048,
            field: "repository fingerprint"
        )
        let operationID = try Self.validatedTransitionOperationID(
            transitionOperationID,
            required: disposition == .awaitingIdentityPublication
        )
        if disposition == .awaitingIdentityPublication,
           targetDirectoryIdentity == nil {
            throw ProjectContextError.invalidIdentifier("relink transition authority")
        }
        let next = ProjectGeneration(expectedGeneration.rawValue + 1)
        let transitionMetadata: [String: String]?
        let transitionAuthority: ProjectTransitionAuthorityIdentity?
        if disposition == .awaitingIdentityPublication {
            guard let operationID, let targetDirectoryIdentity else {
                throw ProjectContextError.invalidIdentifier("relink transition authority")
            }
            transitionMetadata = Self.projectTransitionMetadata(
                operationID: operationID,
                priorGeneration: expectedGeneration,
                newGeneration: next,
                root: root,
                repositoryFingerprint: fingerprint,
                directoryIdentity: targetDirectoryIdentity
            )
            transitionAuthority = Self.projectTransitionAuthorityIdentity(
                kind: .relink,
                projectID: projectID,
                operationID: operationID,
                priorGeneration: expectedGeneration,
                newGeneration: next,
                root: root,
                repositoryFingerprint: fingerprint,
                directoryIdentity: targetDirectoryIdentity
            )
        } else {
            transitionMetadata = nil
            transitionAuthority = nil
        }
        let timestamp = ISO8601.string(from: clock.now())
        return try controlledTransaction(
            cancellation: cancellation,
            beforeCommitValidation: {
                if let targetDirectoryIdentity {
                    try Self.validateDirectoryIdentity(
                        root,
                        expected: targetDirectoryIdentity,
                        failure: .projectRelinkTargetChanged(projectID)
                    )
                }
            }
        ) { connection in
            if let targetDirectoryIdentity {
                try Self.validateDirectoryIdentity(
                    root,
                    expected: targetDirectoryIdentity,
                    failure: .projectRelinkTargetChanged(projectID)
                )
            }
            guard let current = try projectUnlocked(projectID, connection: connection) else {
                throw ProjectContextError.projectNotFound(projectID)
            }
            guard current.generation == expectedGeneration else {
                throw ProjectContextError.staleProjectGeneration(
                    expected: expectedGeneration,
                    actual: current.generation
                )
            }
            guard current.lifecycleState == .active else {
                throw ProjectContextError.projectNotActive(current.lifecycleState)
            }
            guard current.canonicalRoot.path != root.path else {
                throw ProjectContextError.invalidIdentifier(
                    "relink target matches the current canonical root"
                )
            }
            if let owner = try projectAtRootUnlocked(root, connection: connection),
               owner.projectID != projectID {
                throw ProjectContextError.projectRootAlreadyRegistered(root.path)
            }
            guard let existing = current.repositoryFingerprint,
                  let fingerprint,
                  existing == fingerprint else {
                throw ProjectContextError.projectRepositoryIdentityMismatch(projectID)
            }

            let activeBindings = try connection.scalarInt(
                "SELECT COUNT(*) FROM project_bindings WHERE project_id=? AND active=1",
                bindings: [.text(projectID.description)]
            )
            let activeRuns = try connection.scalarInt(
                """
                SELECT COUNT(*) FROM autonomous_runs
                WHERE project_id=? AND project_generation=?
                  AND state NOT IN ('completed','cancelled','failed_terminal')
                """,
                bindings: [
                    .text(projectID.description),
                    .int64(try Self.sqliteGeneration(expectedGeneration)),
                ]
            )
            guard activeBindings == 0, activeRuns == 0 else {
                throw ProjectContextError.projectRelinkBusy(projectID)
            }

            let changed = try connection.execute(
                """
                UPDATE control_projects
                SET canonical_root=?,generation=?,lifecycle_state=?,repository_fingerprint=?,updated_at=?
                WHERE project_id=? AND canonical_root=? AND generation=?
                  AND lifecycle_state='active'
                """,
                bindings: [
                    .text(root.path),
                    .int64(try Self.sqliteGeneration(next)),
                    .text(disposition.lifecycleState.rawValue),
                    .text(fingerprint),
                    .text(timestamp),
                    .text(projectID.description),
                    .text(current.canonicalRoot.path),
                    .int64(try Self.sqliteGeneration(expectedGeneration)),
                ]
            )
            guard changed == 1 else {
                throw ProjectContextError.databaseFailure(
                    "project relink compare-and-set failed"
                )
            }
            if let transitionAuthority {
                try stageTransitionAuthorityUnlocked(
                    transitionAuthority,
                    timestamp: timestamp,
                    connection: connection
                )
            }
            try appendEventUnlocked(
                projectID: projectID,
                eventType: disposition == .active
                    ? "project_relinked"
                    : "project_relink_staged",
                severity: "info",
                summary: disposition == .active
                    ? "Project canonical root changed with a generation fence"
                    : "Project relink generation is fenced pending identity publication",
                metadata: transitionMetadata ?? [
                    "prior_generation": String(expectedGeneration.rawValue),
                    "new_generation": String(next.rawValue),
                    "prior_root_sha256": JSONSupport.sha256Hex(current.canonicalRoot.path),
                    "new_root_sha256": JSONSupport.sha256Hex(root.path),
                ],
                connection: connection
            )
            return ProjectRelinkReceipt(
                projectID: projectID,
                priorCanonicalRoot: current.canonicalRoot,
                newCanonicalRoot: root,
                priorGeneration: expectedGeneration,
                newGeneration: next,
                invalidatedBindingCount: 0,
                completedAt: timestamp
            )
        }
    }

    /// Activates only an exact relink tuple after the project-memory alias has
    /// been durably published. While the row is in `maintenance`, every normal
    /// binding and execution path remains fail-closed through
    /// `requiredActiveProjectUnlocked`.
    func finalizeRelink(
        projectID: ProjectID,
        priorGeneration: ProjectGeneration,
        target: ProjectIdentityTarget,
        transitionOperationID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord {
        try cancellation?.checkCancellation()
        try Self.validate(priorGeneration)
        guard priorGeneration.rawValue < UInt64(Int64.max) else {
            throw ProjectContextError.invalidGeneration(priorGeneration.rawValue)
        }
        let next = ProjectGeneration(priorGeneration.rawValue + 1)
        let root = try Self.canonicalRoot(target.canonicalRoot)
        guard let fingerprint = try Self.boundedOptional(
            target.repositoryIdentity,
            maximumBytes: 2_048,
            field: "repository fingerprint"
        ) else {
            throw ProjectContextError.projectRepositoryIdentityMismatch(projectID)
        }
        guard let operationID = try Self.validatedTransitionOperationID(
            transitionOperationID,
            required: true
        ) else {
            throw ProjectContextError.invalidIdentifier("relink transition authority")
        }
        let transitionMetadata = Self.projectTransitionMetadata(
            operationID: operationID,
            priorGeneration: priorGeneration,
            newGeneration: next,
            root: root,
            repositoryFingerprint: fingerprint,
            directoryIdentity: target.directoryIdentity
        )
        let transitionAuthority = Self.projectTransitionAuthorityIdentity(
            kind: .relink,
            projectID: projectID,
            operationID: operationID,
            priorGeneration: priorGeneration,
            newGeneration: next,
            root: root,
            repositoryFingerprint: fingerprint,
            directoryIdentity: target.directoryIdentity
        )
        let timestamp = ISO8601.string(from: clock.now())

        return try controlledTransaction(
            cancellation: cancellation,
            beforeCommitValidation: {
                try Self.validateDirectoryIdentity(
                    root,
                    expected: target.directoryIdentity,
                    failure: .projectRelinkTargetChanged(projectID)
                )
            }
        ) { connection in
            try Self.validateDirectoryIdentity(
                root,
                expected: target.directoryIdentity,
                failure: .projectRelinkTargetChanged(projectID)
            )
            guard let current = try projectUnlocked(projectID, connection: connection) else {
                throw ProjectContextError.projectNotFound(projectID)
            }
            guard current.generation == next else {
                throw ProjectContextError.staleProjectGeneration(
                    expected: next,
                    actual: current.generation
                )
            }
            guard current.canonicalRoot == root,
                  current.repositoryFingerprint == fingerprint else {
                throw ProjectContextError.projectScopeMismatch
            }
            if current.lifecycleState == .active {
                try requireTransitionAuthorityUnlocked(
                    projectID: projectID,
                    identity: transitionAuthority,
                    state: .published,
                    connection: connection
                )
                return current
            }
            guard current.lifecycleState == .maintenance else {
                throw ProjectContextError.projectNotActive(current.lifecycleState)
            }
            try requireTransitionAuthorityUnlocked(
                projectID: projectID,
                identity: transitionAuthority,
                state: .staged,
                connection: connection
            )
            let changed = try connection.execute(
                """
                UPDATE control_projects
                SET lifecycle_state='active',updated_at=?
                WHERE project_id=? AND canonical_root=? AND generation=?
                  AND lifecycle_state='maintenance' AND repository_fingerprint=?
                """,
                bindings: [
                    .text(timestamp),
                    .text(projectID.description),
                    .text(root.path),
                    .int64(try Self.sqliteGeneration(next)),
                    .text(fingerprint),
                ]
            )
            guard changed == 1 else {
                throw ProjectContextError.databaseFailure(
                    "project relink activation compare-and-set failed"
                )
            }
            try publishTransitionAuthorityUnlocked(
                projectID: projectID,
                identity: transitionAuthority,
                timestamp: timestamp,
                connection: connection
            )
            try appendEventUnlocked(
                projectID: projectID,
                eventType: "project_relinked",
                severity: "info",
                summary: "Project relink identity publication completed",
                metadata: transitionMetadata,
                connection: connection
            )
            guard let activated = try projectUnlocked(projectID, connection: connection) else {
                throw ProjectContextError.integrityFailure(
                    "activated relink project could not be read back"
                )
            }
            return activated
        }
    }

    /// Proves the exact staged relink authority before the project-memory alias
    /// is published. Finalization performs the same proof again.
    func validateRelinkPublicationAuthority(
        projectID: ProjectID,
        priorGeneration: ProjectGeneration,
        target: ProjectIdentityTarget,
        transitionOperationID: String,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try cancellation?.checkCancellation()
        try Self.validate(priorGeneration)
        guard priorGeneration.rawValue < UInt64(Int64.max) else {
            throw ProjectContextError.invalidGeneration(priorGeneration.rawValue)
        }
        let next = ProjectGeneration(priorGeneration.rawValue + 1)
        let root = try Self.canonicalRoot(target.canonicalRoot)
        guard let fingerprint = try Self.boundedOptional(
            target.repositoryIdentity,
            maximumBytes: 2_048,
            field: "repository fingerprint"
        ) else {
            throw ProjectContextError.projectRepositoryIdentityMismatch(projectID)
        }
        guard let operationID = try Self.validatedTransitionOperationID(
            transitionOperationID,
            required: true
        ) else {
            throw ProjectContextError.invalidIdentifier("relink transition authority")
        }
        let authority = Self.projectTransitionAuthorityIdentity(
            kind: .relink,
            projectID: projectID,
            operationID: operationID,
            priorGeneration: priorGeneration,
            newGeneration: next,
            root: root,
            repositoryFingerprint: fingerprint,
            directoryIdentity: target.directoryIdentity
        )
        try controlledOperation(cancellation: cancellation) { connection in
            try Self.validateDirectoryIdentity(
                root,
                expected: target.directoryIdentity,
                failure: .projectRelinkTargetChanged(projectID)
            )
            guard let current = try projectUnlocked(projectID, connection: connection) else {
                throw ProjectContextError.projectNotFound(projectID)
            }
            guard current.generation == next,
                  current.lifecycleState == .maintenance,
                  current.canonicalRoot == root,
                  current.repositoryFingerprint == fingerprint else {
                throw ProjectContextError.projectTransitionConflict(projectID)
            }
            try requireTransitionAuthorityUnlocked(
                projectID: projectID,
                identity: authority,
                state: .staged,
                connection: connection
            )
        }
    }

    /// Newest-first project rows for the read-only native operator surface.
    public func operatorProjects(limit: Int) throws -> [ProjectControlRecord] {
        guard (1...100).contains(limit) else {
            throw AutonomyError.invalidRequest("operator project limit must be between 1 and 100")
        }
        return try requiredConnection().all(
            """
            SELECT project_id,display_name,canonical_root,generation,lifecycle_state,
                   repository_fingerprint,bookmark_reference,created_at,updated_at
            FROM control_projects ORDER BY updated_at DESC,project_id DESC LIMIT ?
            """,
            bindings: [.int64(Int64(limit))],
            map: Self.decodeProject
        )
    }

    /// Active bindings are bounded per selected project so one busy project cannot crowd
    /// every other project out of the operator snapshot.
    public func operatorBindings(
        projectIDs: [ProjectID],
        limitPerProject: Int = 16
    ) throws -> [ProjectID: [ProjectContextBinding]] {
        guard projectIDs.count <= 100, (1...32).contains(limitPerProject) else {
            throw AutonomyError.invalidRequest("operator binding query is outside bounds")
        }
        let connection = try requiredConnection()
        var result: [ProjectID: [ProjectContextBinding]] = [:]
        result.reserveCapacity(projectIDs.count)
        for projectID in projectIDs {
            result[projectID] = try connection.all(
                """
                SELECT binding_id,owner_kind,owner_id,project_id,project_generation,run_id,
                       authorization_scope_json,lease_owner,lease_expires_at,active,created_at,updated_at
                FROM project_bindings
                WHERE project_id=? AND active=1
                ORDER BY updated_at DESC,binding_id DESC LIMIT ?
                """,
                bindings: [.text(projectID.description), .int64(Int64(limitPerProject))],
                map: Self.decodeBinding
            )
        }
        return result
    }

    public func operatorLatestResetReceipts(
        projectIDs: [ProjectID]
    ) throws -> [ProjectID: ProjectGenerationResetReceipt] {
        guard projectIDs.count <= 100 else {
            throw AutonomyError.invalidRequest("operator reset receipt query is outside bounds")
        }
        let connection = try requiredConnection()
        var result: [ProjectID: ProjectGenerationResetReceipt] = [:]
        for projectID in projectIDs {
            let receipt = try connection.first(
                """
                SELECT metadata_json,created_at FROM autonomy_events
                WHERE project_id=? AND event_type='project_generation_reset'
                ORDER BY sequence DESC LIMIT 1
                """,
                bindings: [.text(projectID.description)]
            ) { row -> ProjectGenerationResetReceipt in
                guard let metadataJSON = row.text(0),
                      let completedAt = row.text(1),
                      let data = metadataJSON.data(using: .utf8),
                      let metadata = try JSONSerialization.jsonObject(with: data) as? [String: String],
                      let priorText = metadata["prior_generation"],
                      let prior = UInt64(priorText), prior > 0,
                      let nextText = metadata["new_generation"],
                      let next = UInt64(nextText), next > prior,
                      let invalidatedText = metadata["invalidated_bindings"],
                      let invalidated = Int(invalidatedText), invalidated >= 0 else {
                    throw ProjectContextError.integrityFailure(
                        "invalid project generation reset receipt"
                    )
                }
                return ProjectGenerationResetReceipt(
                    projectID: projectID,
                    priorGeneration: ProjectGeneration(prior),
                    newGeneration: ProjectGeneration(next),
                    invalidatedBindingCount: invalidated,
                    completedAt: completedAt
                )
            }
            if let receipt { result[projectID] = receipt }
        }
        return result
    }

    // MARK: - Native task capabilities

    func prepareNativeContinuityTask(request: NativeContinuityTaskPreparationRequest,
        approvedAssignment: ContinuityTaskAssignment, cancellation: ToolCallCancellation? = nil
    ) throws -> NativeTaskCapabilityCommandResult {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let project = try requiredActiveProjectUnlocked(request.projectID, generation: request.projectGeneration, connection: connection)
            let a = request.approval, scope = approvedAssignment.authorizationScope
            guard request.profileID == "forge.native-task-source", request.profileVersion == 1,
                  scope.canonicalRoots == [project.canonicalRoot], scope.writableRoots.isEmpty,
                  !scope.networkAllowed, scope.allowedTools == ["fs_read"],
                  scope.maximumInlineOutputBytes == a.maximumInlineOutputBytes,
                  approvedAssignment.assignmentID == a.assignmentID, approvedAssignment.assignmentBytes == a.assignmentBytes,
                  approvedAssignment.mission == a.mission, approvedAssignment.providerID == a.providerID,
                  approvedAssignment.adapterID == a.adapterID, approvedAssignment.modelKey == a.modelKey,
                  approvedAssignment.specification.allowedTools == a.allowedTools.sorted(),
                  approvedAssignment.specification.completionGates == a.completionGates,
                  approvedAssignment.specification.resourceProfile == a.resourceProfile,
                  approvedAssignment.specification.work == AutonomousRunWork() else { throw NativeTaskCapabilityError.unsupportedProfile }
            if let stored = try nativeCapabilityUnlocked(request.capabilityID, connection: connection) {
                let (task, _) = try validateNativeCapabilityOwnerUnlocked(stored, taskID: request.taskID,
                    projectID: request.projectID, generation: request.projectGeneration, connection: connection)
                guard task.assignment == approvedAssignment, stored.limits == a.sourceLimits else { throw NativeTaskCapabilityError.requestConflict }
                guard let replay = try nativeCommandReplayUnlocked(requestID: request.requestID, requestSHA256: request.requestSHA256,
                    capability: stored, connection: connection) else { throw NativeTaskCapabilityError.requestConflict }
                return replay
            }
            guard try connection.scalarInt("SELECT COUNT(*) FROM native_task_capabilities") < 1_024,
                  try connection.scalarInt("SELECT COUNT(*) FROM native_task_commands") < 4_096 else { throw NativeTaskCapabilityError.capacityExceeded }
            guard try connection.scalarInt("SELECT COUNT(*) FROM native_task_commands WHERE request_id=?", bindings: [.text(request.requestID.uuidString.lowercased())]) == 0,
                  try connection.scalarInt("SELECT COUNT(*) FROM continuity_task_authorizations WHERE task_id=?", bindings: [.text(request.taskID.uuidString.lowercased())]) == 0 else {
                throw NativeTaskCapabilityError.requestConflict
            }
            try validateNativeExpiry(request.expiresAt)
            let timestamp = ISO8601.string(from: clock.now()), callerID = UUID()
            let owner = ProjectBindingOwner(kind: .mcpClient, id: "native-task:" + UUID().uuidString.lowercased())
            try connection.execute("""
                INSERT INTO project_bindings(binding_id,owner_kind,owner_id,project_id,project_generation,
                    run_id,authorization_scope_json,active,created_at,updated_at) VALUES(?,'mcp_client',?,?,?,NULL,?,1,?,?)
                """, bindings: [.text(callerID.uuidString.lowercased()), .text(owner.id), .text(request.projectID.description),
                    .int64(try Self.sqliteGeneration(request.projectGeneration)), .text(try Self.scopeJSON(scope)), .text(timestamp), .text(timestamp)])
            let context = ToolInvocationContext(projectID: request.projectID, projectGeneration: request.projectGeneration,
                clientID: ClientID(owner.id), authorizationScope: scope)
            let setup = try authorizeContinuityTaskUnlocked(taskID: request.taskID, projectID: request.projectID,
                expectedGeneration: request.projectGeneration, approvedAssignment: approvedAssignment,
                callerContext: context, callerOwner: owner, connection: connection)
            let scopeSHA = JSONSupport.sha256Hex(Data(try Self.scopeJSON(scope).utf8))
            try connection.execute("""
                INSERT INTO native_task_capabilities(capability_id,task_id,project_id,project_generation,epoch,state,verifier_sha256,
                    caller_binding_id,source_binding_id,approval_sha256,scope_sha256,authorization_sha256,document_sha256,
                    source_limits_json,expires_at,issued_at,revoked_at) VALUES(?,?,?,?,1,'active',?,?,?,?,?,?,?,?,?,?,NULL)
                """, bindings: [.text(request.capabilityID.uuidString.lowercased()), .text(request.taskID.uuidString.lowercased()),
                    .text(request.projectID.description), .int64(try Self.sqliteGeneration(request.projectGeneration)), .text(request.verifierSHA256),
                    .text(callerID.uuidString.lowercased()), .text(setup.record.authorization.sourceBindingID.uuidString.lowercased()),
                    .text(approvedAssignment.assignmentSHA256), .text(scopeSHA), .text(setup.correlation.authorizationSHA256),
                    .text(approvedAssignment.documentSHA256), .text(String(decoding: try ForgeJSONCanonicalizationV1.data(from: a.sourceLimits.wireObject), as: UTF8.self)),
                    .text(request.expiresAt), .text(timestamp)])
            guard let current = try nativeCapabilityUnlocked(request.capabilityID, connection: connection) else { throw NativeTaskCapabilityError.integrityFailure }
            let receipt = try NativeTaskCapabilityCommandReceipt(requestID: request.requestID, action: request.action,
                requestSHA256: request.requestSHA256, descriptor: current.descriptor(now: clock.now()), priorEpoch: nil,
                documentSHA256: current.documentSHA256, verifierSHA256: current.verifierSHA256, recordedAt: timestamp)
            try storeNativeCommandUnlocked(receipt, connection: connection)
            return .init(receipt: receipt, current: try current.descriptor(now: clock.now()), replayed: false)
        }
    }

    func rotateNativeContinuityTask(request: NativeContinuityTaskRotationRequest,
        cancellation: ToolCallCancellation? = nil) throws -> NativeTaskCapabilityCommandResult {
        try mutateNativeCapability(requestID: request.requestID, action: request.action, requestSHA256: request.requestSHA256,
            taskID: request.taskID, capabilityID: request.capabilityID, projectID: request.projectID,
            generation: request.projectGeneration, expectedEpoch: request.expectedEpoch,
            verifierSHA256: request.verifierSHA256, expiresAt: request.expiresAt, cancellation: cancellation)
    }

    func revokeNativeContinuityTask(request: NativeContinuityTaskRevocationRequest,
        cancellation: ToolCallCancellation? = nil) throws -> NativeTaskCapabilityCommandResult {
        try mutateNativeCapability(requestID: request.requestID, action: request.action, requestSHA256: request.requestSHA256,
            taskID: request.taskID, capabilityID: request.capabilityID, projectID: request.projectID,
            generation: request.projectGeneration, expectedEpoch: request.expectedEpoch,
            verifierSHA256: nil, expiresAt: nil, cancellation: cancellation)
    }

    private func mutateNativeCapability(requestID: UUID, action: String, requestSHA256: String, taskID: UUID,
        capabilityID: UUID, projectID: ProjectID, generation: ProjectGeneration, expectedEpoch: Int64,
        verifierSHA256: String?, expiresAt: String?, cancellation: ToolCallCancellation?) throws -> NativeTaskCapabilityCommandResult {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            guard let stored = try nativeCapabilityUnlocked(capabilityID, connection: connection) else { throw NativeTaskCapabilityError.credentialRejected }
            _ = try validateNativeCapabilityOwnerUnlocked(stored, taskID: taskID, projectID: projectID, generation: generation, connection: connection)
            if let replay = try nativeCommandReplayUnlocked(requestID: requestID, requestSHA256: requestSHA256,
                capability: stored, connection: connection) { return replay }
            guard stored.state == "active" else { throw NativeTaskCapabilityError.capabilityRevoked }
            guard stored.epoch == expectedEpoch, expectedEpoch < Int64.max else { throw NativeTaskCapabilityError.epochConflict }
            try requireNativeCommandCapacityUnlocked(capabilityID, connection: connection)
            if let expiresAt { try validateNativeExpiry(expiresAt) }
            let timestamp = ISO8601.string(from: clock.now())
            try connection.execute("""
                UPDATE native_task_capabilities SET epoch=epoch+1,state=?,verifier_sha256=?,expires_at=?,issued_at=?,revoked_at=?
                WHERE capability_id=? AND epoch=? AND state='active'
                """, bindings: [.text(action == "revoke" ? "revoked" : "active"), .optionalText(verifierSHA256),
                    .text(expiresAt ?? stored.expiresAt), .text(timestamp), .optionalText(action == "revoke" ? timestamp : nil),
                    .text(capabilityID.uuidString.lowercased()), .int64(expectedEpoch)])
            guard let current = try nativeCapabilityUnlocked(capabilityID, connection: connection) else { throw NativeTaskCapabilityError.integrityFailure }
            let receipt = try NativeTaskCapabilityCommandReceipt(requestID: requestID, action: action, requestSHA256: requestSHA256,
                descriptor: current.descriptor(now: clock.now()), priorEpoch: expectedEpoch,
                documentSHA256: current.documentSHA256, verifierSHA256: current.verifierSHA256, recordedAt: timestamp)
            try storeNativeCommandUnlocked(receipt, connection: connection)
            return .init(receipt: receipt, current: try current.descriptor(now: clock.now()), replayed: false)
        }
    }

    func authenticateNativeTaskCapability(credential: NativeTaskCapabilityCredential,
        cancellation: ToolCallCancellation? = nil) throws -> AuthenticatedContinuityTaskAttachment {
        try controlledTransaction(cancellation: cancellation) { connection in
            try authenticateNativeTaskCapabilityUnlocked(credential, connection: connection)
        }
    }

    private struct StoredNativeCapability {
        let capabilityID: UUID, taskID: UUID, projectID: ProjectID, generation: ProjectGeneration
        let epoch: Int64, state: String, verifierSHA256: String?
        let callerBindingID: UUID, sourceBindingID: UUID
        let approvalSHA256: String, scopeSHA256: String, authorizationSHA256: String, documentSHA256: String
        let limits: NativeTaskSourceLimits, expiresAt: String, issuedAt: String, revokedAt: String?
        func descriptor(now: Date) throws -> NativeTaskCapabilityDescriptor {
            try .init(arguments: ["task_id": taskID.uuidString.lowercased(), "capability_id": capabilityID.uuidString.lowercased(),
                "project_id": projectID.description, "project_generation": generation.rawValue, "epoch": epoch,
                "state": state == "revoked" ? "revoked" : (expiresAt <= ISO8601.string(from: now) ? "expired" : "active"),
                "profile_id": "forge.native-task-source", "profile_version": 1, "approval_sha256": approvalSHA256,
                "scope_sha256": scopeSHA256, "original_caller_binding_id": callerBindingID.uuidString.lowercased(),
                "source_binding_id": sourceBindingID.uuidString.lowercased(), "expires_at": expiresAt, "issued_at": issuedAt,
                "revoked_at": revokedAt as Any? ?? NSNull()])
        }
    }

    private func nativeCapabilityUnlocked(_ id: UUID, connection: ControlPlaneSQLiteConnection) throws -> StoredNativeCapability? {
        try connection.first("""
            SELECT capability_id,task_id,project_id,project_generation,epoch,state,verifier_sha256,caller_binding_id,source_binding_id,
                approval_sha256,scope_sha256,authorization_sha256,document_sha256,source_limits_json,expires_at,issued_at,revoked_at
            FROM native_task_capabilities WHERE capability_id=?
            """, bindings: [.text(id.uuidString.lowercased())]) { row in
                guard row.int64(3) > 0, row.int64(4) > 0,
                      let state = try row.strictText(5, maximumBytes: 16), ["active","revoked"].contains(state),
                      let limitsJSON = try row.strictText(13, maximumBytes: 512) else { throw NativeTaskCapabilityError.integrityFailure }
                let limits = try JSONDecoder().decode(NativeTaskSourceLimits.self, from: Data(limitsJSON.utf8))
                guard try ForgeJSONCanonicalizationV1.data(from: limits.wireObject) == Data(limitsJSON.utf8) else { throw NativeTaskCapabilityError.integrityFailure }
                let verifier = try row.strictText(6, maximumBytes: 64), revoked = try row.strictText(16, maximumBytes: 20)
                guard (state == "active") == (verifier != nil), (state == "revoked") == (revoked != nil) else { throw NativeTaskCapabilityError.integrityFailure }
                if let verifier { _ = try NativeTaskValue.sha(verifier) }; if let revoked { _ = try NativeTaskValue.date(revoked) }
                return .init(capabilityID: try NativeTaskValue.uuid(row.strictText(0, maximumBytes: 36)),
                    taskID: try NativeTaskValue.uuid(row.strictText(1, maximumBytes: 36)),
                    projectID: ProjectID(try NativeTaskValue.uuid(row.strictText(2, maximumBytes: 36))), generation: .init(UInt64(row.int64(3))),
                    epoch: row.int64(4), state: state, verifierSHA256: verifier,
                    callerBindingID: try NativeTaskValue.uuid(row.strictText(7, maximumBytes: 36)),
                    sourceBindingID: try NativeTaskValue.uuid(row.strictText(8, maximumBytes: 36)),
                    approvalSHA256: try NativeTaskValue.sha(row.strictText(9, maximumBytes: 64)),
                    scopeSHA256: try NativeTaskValue.sha(row.strictText(10, maximumBytes: 64)),
                    authorizationSHA256: try NativeTaskValue.sha(row.strictText(11, maximumBytes: 64)),
                    documentSHA256: try NativeTaskValue.sha(row.strictText(12, maximumBytes: 64)), limits: limits,
                    expiresAt: try NativeTaskValue.date(row.strictText(14, maximumBytes: 20)),
                    issuedAt: try NativeTaskValue.date(row.strictText(15, maximumBytes: 20)), revokedAt: revoked)
            }
    }

    private func authenticateNativeTaskCapabilityUnlocked(_ credential: NativeTaskCapabilityCredential,
        connection: ControlPlaneSQLiteConnection) throws -> AuthenticatedContinuityTaskAttachment {
        // Authenticate only bounded verifier metadata before decoding any task or capability body.
        let metadata = try connection.first("SELECT epoch,state,verifier_sha256 FROM native_task_capabilities WHERE capability_id=?",
            bindings: [.text(credential.capabilityID.uuidString.lowercased())]) {
                ($0.int64(0), try? $0.strictText(1, maximumBytes: 16), try? $0.strictText(2, maximumBytes: 64))
            }
        let expected = Array((metadata?.2 ?? String(repeating: "0", count: 64)).utf8)
        let actual = Array(credential.verifier.sha256.utf8)
        var difference: UInt8 = 0
        for index in 0..<64 { difference |= actual[index] ^ (index < expected.count ? expected[index] : 0) }
        guard difference == 0, expected.count == 64, metadata?.0 == credential.epoch, metadata?.1 == "active",
              let stored = try nativeCapabilityUnlocked(credential.capabilityID, connection: connection),
              stored.expiresAt > ISO8601.string(from: clock.now()) else { throw NativeTaskCapabilityError.credentialRejected }
        let (task, caller) = try validateNativeCapabilityOwnerUnlocked(stored, taskID: stored.taskID,
            projectID: stored.projectID, generation: stored.generation, connection: connection)
        let context = caller.invocationContext(clientID: ClientID(caller.owner.id))
        let correlation = try VerifiedContinuityTaskCorrelation.nativeCapabilityResult(record: task, caller: caller,
            context: context, credential: credential)
        return .init(descriptor: try stored.descriptor(now: clock.now()), setup: .init(record: task, correlation: correlation), sourceLimits: stored.limits)
    }

    private func validateNativeCapabilityOwnerUnlocked(_ c: StoredNativeCapability, taskID: UUID, projectID: ProjectID,
        generation: ProjectGeneration, connection: ControlPlaneSQLiteConnection) throws -> (ContinuityTaskAuthorizationRecord, ProjectContextBinding) {
        guard c.taskID == taskID, c.projectID == projectID, c.generation == generation else { throw NativeTaskCapabilityError.credentialRejected }
        _ = try requiredActiveProjectUnlocked(projectID, generation: generation, connection: connection)
        guard let origin = try connection.first("""
            SELECT caller_binding_id,owner_kind,owner_id,scope_sha256,invalidated
            FROM continuity_source_dispatch_origins WHERE task_id=?
            """, bindings: [.text(taskID.uuidString.lowercased())], map: {
                (try $0.strictText(0, maximumBytes: 36), try $0.strictText(1, maximumBytes: 32),
                 try $0.strictText(2, maximumBytes: 512), try $0.strictText(3, maximumBytes: 64), $0.int64(4))
            }), origin.0 == c.callerBindingID.uuidString.lowercased(), origin.1 == "mcp_client", origin.3 == c.scopeSHA256,
            origin.4 == 0, let ownerID = origin.2,
            let caller = try bindingUnlocked(owner: .init(kind: .mcpClient, id: ownerID), includeInactive: false, connection: connection),
            caller.bindingID == c.callerBindingID, caller.projectID == projectID, caller.projectGeneration == generation, caller.runID == nil,
            JSONSupport.sha256Hex(Data(try Self.scopeJSON(caller.authorizationScope).utf8)) == c.scopeSHA256,
            caller.authorizationScope.allowedTools == ["fs_read"], caller.authorizationScope.writableRoots.isEmpty,
            !caller.authorizationScope.networkAllowed,
            try connection.scalarInt("""
                SELECT COUNT(*) FROM continuity_task_authorizations WHERE task_id=? AND project_id=? AND project_generation=?
                    AND source_binding_id=? AND assignment_sha256=? AND authorization_sha256=?
                """, bindings: [.text(taskID.uuidString.lowercased()), .text(projectID.description), .int64(try Self.sqliteGeneration(generation)),
                    .text(c.sourceBindingID.uuidString.lowercased()), .text(c.approvalSHA256), .text(c.authorizationSHA256)]) == 1 else {
            throw NativeTaskCapabilityError.credentialRejected
        }
        guard let task = try continuityTaskUnlocked(taskID, connection: connection) else { throw NativeTaskCapabilityError.credentialRejected }
        let current = try validatedContinuityTaskUnlocked(task.authorization, allowTerminalRun: true, connection: connection)
        guard current.assignment.documentSHA256 == c.documentSHA256, current.authorization.authorizationScope == caller.authorizationScope else {
            throw NativeTaskCapabilityError.integrityFailure
        }
        return (current, caller)
    }

    private func requireNativeCorrelationUnlocked(_ correlation: VerifiedContinuityTaskCorrelation,
        connection: ControlPlaneSQLiteConnection) throws {
        guard let credential = correlation.nativeCredential else { return }
        let live = try authenticateNativeTaskCapabilityUnlocked(credential, connection: connection).setup.correlation
        guard live.taskID == correlation.taskID, live.callerBindingID == correlation.callerBindingID,
              live.callerOwner == correlation.callerOwner, live.callerContext == correlation.callerContext,
              live.sourceBindingID == correlation.sourceBindingID, live.authorizationSHA256 == correlation.authorizationSHA256 else {
            throw NativeTaskCapabilityError.credentialRejected
        }
    }

    private func validateNativeExpiry(_ expiry: String) throws {
        _ = try NativeTaskValue.date(expiry)
        guard let date = ISO8601DateFormatter().date(from: expiry), date > clock.now(), date.timeIntervalSince(clock.now()) <= 604_800 else {
            throw NativeTaskCapabilityError.invalidRequest("expires_at")
        }
    }

    private func requireNativeCommandCapacityUnlocked(_ id: UUID, connection: ControlPlaneSQLiteConnection) throws {
        guard try connection.scalarInt("SELECT COUNT(*) FROM native_task_commands") < 4_096,
              try connection.scalarInt("SELECT COUNT(*) FROM native_task_commands WHERE capability_id=?", bindings: [.text(id.uuidString.lowercased())]) < 64 else {
            throw NativeTaskCapabilityError.capacityExceeded
        }
    }
    private func storeNativeCommandUnlocked(_ receipt: NativeTaskCapabilityCommandReceipt, connection: ControlPlaneSQLiteConnection) throws {
        try requireNativeCommandCapacityUnlocked(receipt.capabilityID, connection: connection)
        try connection.execute("INSERT INTO native_task_commands(request_id,capability_id,request_sha256,receipt_json,receipt_sha256) VALUES(?,?,?,?,?)",
            bindings: [.text(receipt.requestID.uuidString.lowercased()), .text(receipt.capabilityID.uuidString.lowercased()),
                .text(receipt.requestSHA256), .text(String(decoding: receipt.canonicalReceiptJSON, as: UTF8.self)), .text(receipt.receiptSHA256)])
    }
    private func nativeCommandReplayUnlocked(requestID: UUID, requestSHA256: String, capability: StoredNativeCapability,
        connection: ControlPlaneSQLiteConnection) throws -> NativeTaskCapabilityCommandResult? {
        guard let metadata = try connection.first("SELECT capability_id,request_sha256 FROM native_task_commands WHERE request_id=?",
            bindings: [.text(requestID.uuidString.lowercased())], map: { (try $0.strictText(0, maximumBytes: 36), try $0.strictText(1, maximumBytes: 64)) }) else { return nil }
        guard metadata.0 == capability.capabilityID.uuidString.lowercased(), metadata.1 == requestSHA256 else { throw NativeTaskCapabilityError.requestConflict }
        guard let receipt = try connection.first("SELECT receipt_json,receipt_sha256 FROM native_task_commands WHERE request_id=?",
            bindings: [.text(requestID.uuidString.lowercased())], map: { row -> NativeTaskCapabilityCommandReceipt in
                guard let json = try row.strictText(0, maximumBytes: NativeTaskCapabilityCommandReceipt.maximumStoredBytes),
                      let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw NativeTaskCapabilityError.integrityFailure }
                let receipt = try NativeTaskCapabilityCommandReceipt(arguments: object)
                guard receipt.canonicalReceiptJSON == Data(json.utf8), receipt.receiptSHA256 == (try row.strictText(1, maximumBytes: 64)),
                      receipt.requestID == requestID, receipt.requestSHA256 == requestSHA256, receipt.capabilityID == capability.capabilityID,
                      receipt.taskID == capability.taskID, receipt.approvalSHA256 == capability.approvalSHA256,
                      receipt.scopeSHA256 == capability.scopeSHA256 else { throw NativeTaskCapabilityError.integrityFailure }
                return receipt
            }) else { throw NativeTaskCapabilityError.integrityFailure }
        return .init(receipt: receipt, current: try capability.descriptor(now: clock.now()), replayed: true)
    }

    // MARK: - Native source conversation ownership

    private struct NativeSourceConversationRow {
        let rowID: Int64
        let body: NativeSourceStoredConversation
        let state: NativeSourceConversationState
        let revision: Int64
        let active: UUID?
        let parent: String?
        let cancelled: Bool
        let owner: UUID?
        let leaseEpoch: Int64
        let capabilityEpoch: Int64?
        let leaseExpires: String?
        let configurationSHA: String?
        let ceilings: NativeSourceBudgetCeilings?
        let updatedAt: String
    }
    private struct NativeSourceStageRow {
        let rowID: Int64
        let body: NativeSourceStoredIntent
        let digest: String
        let state: NativeSourceProviderStageState
        let post: NativeSourceStoredPost?
        let accepted: ProviderTurn?
        let dispatchNonce: UUID?
        let dispatchOwner: UUID?
        let dispatchEpoch: Int64?
        let blocked: String?
        let budgetDisposition: NativeSourceStoredBudgetDisposition?
        let pressureReservationID: UUID?
    }
    private static func nativeSourceText(_ row: ControlPlaneSQLiteRow, _ index: Int32, _ maximum: Int) throws -> String {
        guard let value = try row.strictText(index, maximumBytes: maximum) else { throw NativeSourceConversationError.integrityFailure }
        return value
    }
    private func nativeConversationUnlocked(_ id: UUID, attachment: AuthenticatedContinuityTaskAttachment,
        connection: ControlPlaneSQLiteConnection) throws -> NativeSourceConversationRow {
        try decodeNativeConversationUnlocked(id, expected: attachment.descriptor,
            assignmentSHA256: attachment.setup.record.assignment.assignmentSHA256,
            authorizationSHA256: attachment.setup.correlation.authorizationSHA256, connection: connection)
    }
    // Structural decoding only; callers establish live execution or historical
    // receipt authority separately. A descriptor never grants work by itself.
    private func decodeNativeConversationUnlocked(_ id: UUID, expected: NativeTaskCapabilityDescriptor,
        assignmentSHA256: String, authorizationSHA256: String,
        connection: ControlPlaneSQLiteConnection) throws -> NativeSourceConversationRow {
        guard let row = try connection.first("""
            SELECT rowid,task_id,capability_id,project_id,project_generation,body_json,body_sha256,state,revision,
                active_stage_id,parent_response_id,cancelled,lease_owner,lease_epoch,lease_capability_epoch,lease_expires_at,
                configuration_sha256,ceilings_json,ceilings_sha256,updated_at
            FROM native_source_conversations WHERE conversation_id=?
            """, bindings: [.text(id.uuidString.lowercased())], map: { r -> NativeSourceConversationRow in
                // Foreign ownership metadata is checked before any immutable body is decoded.
                guard (try? r.strictText(1, maximumBytes: 36)) == expected.taskID.uuidString.lowercased(),
                      (try? r.strictText(2, maximumBytes: 36)) == expected.capabilityID.uuidString.lowercased(),
                      (try? r.strictText(3, maximumBytes: 36)) == expected.projectID.description,
                      r.int64(4) == Int64(expected.projectGeneration.rawValue) else { throw NativeSourceConversationError.notFound }
                let body = try NativeSourceJournalCoding.decode(NativeSourceStoredConversation.self,
                    Self.nativeSourceText(r, 5, 65_536), sha: Self.nativeSourceText(r, 6, 64), maximum: 65_536)
                guard body.conversationID == id, body.taskID == expected.taskID, body.capabilityID == expected.capabilityID,
                      body.projectID == expected.projectID, body.projectGeneration == expected.projectGeneration,
                      body.assignmentSHA == assignmentSHA256,
                      body.sourceBindingID == expected.sourceBindingID, body.callerBindingID == expected.originalCallerBindingID,
                      body.authorizationSHA == authorizationSHA256,
                      body.scopeSHA == expected.scopeSHA256,
                      let state = NativeSourceConversationState(rawValue: try Self.nativeSourceText(r, 7, 32)),
                      r.int64(8) > 0, r.int64(13) >= 0 else { throw NativeSourceConversationError.integrityFailure }
                _ = try body.initialPolicy.policy.validated()
                let ceilings: NativeSourceBudgetCeilings?
                if let json = try r.strictText(17, maximumBytes: 8_192) {
                    ceilings = try NativeSourceJournalCoding.decode(NativeSourceBudgetCeilings.self, json,
                        sha: Self.nativeSourceText(r, 18, 64), maximum: 8_192).validated()
                } else { ceilings = nil }
                return .init(rowID: r.int64(0), body: body, state: state, revision: r.int64(8),
                    active: try r.strictText(9, maximumBytes: 36).map { try NativeTaskValue.uuid($0) },
                    parent: try r.strictText(10, maximumBytes: 1_024), cancelled: r.int64(11) == 1,
                    owner: try r.strictText(12, maximumBytes: 36).map { try NativeTaskValue.uuid($0) }, leaseEpoch: r.int64(13),
                    capabilityEpoch: r.isNull(14) ? nil : r.int64(14),
                    leaseExpires: try r.strictText(15, maximumBytes: 20), configurationSHA: try r.strictText(16, maximumBytes: 64),
                    ceilings: ceilings, updatedAt: try NativeTaskValue.date(r.strictText(19, maximumBytes: 20)))
            }) else { throw NativeSourceConversationError.notFound }
        return row
    }
    private func nativeConversationDescriptor(_ row: NativeSourceConversationRow,
        connection: ControlPlaneSQLiteConnection) throws -> NativeSourceConversationDescriptor {
        .init(conversationID: row.body.conversationID, taskID: row.body.taskID, capabilityID: row.body.capabilityID,
            projectID: row.body.projectID, projectGeneration: row.body.projectGeneration, assignmentSHA256: row.body.assignmentSHA,
            providerID: row.body.providerID, adapterID: row.body.adapterID, modelKey: row.body.modelKey,
            state: row.state, revision: row.revision, activeStageID: row.active, parentResponseID: row.parent,
            cancelled: row.cancelled, stageCount: try connection.scalarInt("SELECT COUNT(*) FROM native_source_provider_turns WHERE conversation_id=?",
                bindings: [.text(row.body.conversationID.uuidString.lowercased())]), createdAt: row.body.createdAt, updatedAt: row.updatedAt)
    }
    private func nativeStageUnlocked(_ id: UUID, conversation: NativeSourceConversationRow,
        connection: ControlPlaneSQLiteConnection) throws -> NativeSourceStageRow {
        guard let value = try connection.first("""
            SELECT rowid,conversation_id,task_id,intent_json,intent_sha256,state,post_json,post_sha256,result_json,result_sha256,
                dispatch_nonce,dispatch_owner,dispatch_epoch,blocked_code,
                pressure_decision_json,pressure_decision_sha256,pressure_reservation_id
            FROM native_source_provider_turns WHERE stage_id=?
            """, bindings: [.text(id.uuidString.lowercased())], map: { r -> NativeSourceStageRow in
                guard (try? r.strictText(1, maximumBytes: 36)) == conversation.body.conversationID.uuidString.lowercased(),
                      (try? r.strictText(2, maximumBytes: 36)) == conversation.body.taskID.uuidString.lowercased() else {
                    throw NativeSourceConversationError.notFound
                }
                let digest = try Self.nativeSourceText(r, 4, 64)
                let body = try NativeSourceJournalCoding.decode(NativeSourceStoredIntent.self,
                    Self.nativeSourceText(r, 3, NativeSourceJournalCoding.maximumIntentBytes), sha: digest,
                    maximum: NativeSourceJournalCoding.maximumIntentBytes)
                guard body.stageID == id, body.conversationID == conversation.body.conversationID,
                      body.taskID == conversation.body.taskID, body.capabilityID == conversation.body.capabilityID,
                      body.assignmentSHA == conversation.body.assignmentSHA,
                      body.providerID == conversation.body.providerID, body.modelKey == conversation.body.modelKey,
                      let state = NativeSourceProviderStageState(rawValue: try Self.nativeSourceText(r, 5, 32)) else {
                    throw NativeSourceConversationError.integrityFailure
                }
                _ = try body.request()
                let post: NativeSourceStoredPost?
                if let json = try r.strictText(6, maximumBytes: 32_768) {
                    post = try NativeSourceJournalCoding.decode(NativeSourceStoredPost.self, json,
                        sha: Self.nativeSourceText(r, 7, 64), maximum: 32_768)
                    _ = try post?.preflight.value(); _ = try post?.ceilings.validated()
                    _ = try post?.accounting.validated()
                } else { post = nil }
                let accepted: ProviderTurn?
                if let json = try r.strictText(8, maximumBytes: NativeSourceJournalCoding.maximumTurnBytes) {
                    accepted = try NativeSourceJournalCoding.turn(NativeSourceJournalCoding.decode(ProviderTurn.self, json,
                        sha: Self.nativeSourceText(r, 9, 64), maximum: NativeSourceJournalCoding.maximumTurnBytes))
                } else { accepted = nil }
                guard (state == .accepted) == (accepted != nil), state == .prepared || state == .cancelledBeforeDispatch || post != nil else {
                    throw NativeSourceConversationError.integrityFailure
                }
                let disposition: NativeSourceStoredBudgetDisposition?
                if let json = try r.strictText(14, maximumBytes: NativeSourceBudgetMetadata.maximumStoredBytes) {
                    disposition = try NativeSourceJournalCoding.decode(NativeSourceStoredBudgetDisposition.self, json,
                        sha: Self.nativeSourceText(r, 15, 64), maximum: NativeSourceBudgetMetadata.maximumStoredBytes).validated()
                    guard let binding = disposition?.binding, binding.stageID == id,
                          binding.conversationID == conversation.body.conversationID,
                          binding.projectID == conversation.body.projectID,
                          binding.projectGeneration == conversation.body.projectGeneration,
                          binding.taskID == body.taskID, binding.capabilityID == body.capabilityID,
                          binding.capabilityEpoch == body.epoch, binding.logicalRequestID == body.requestID,
                          binding.intentSHA256 == digest, binding.logicalInputSHA256 == body.logicalInputSHA,
                          binding.assignmentSHA256 == body.assignmentSHA,
                          binding.sourceInferenceDeadline == body.deadline,
                          disposition!.fenceRevision <= conversation.revision,
                          conversation.state == .stopped || conversation.state == .sourceFenced,
                          conversation.active == id,
                          (try r.strictText(13, maximumBytes: 64)) != nil else { throw NativeSourceConversationError.integrityFailure }
                    if let reservation = try r.strictText(16, maximumBytes: 36) {
                        guard case .pressure = disposition!.metadata,
                              try connection.scalarInt("""
                                SELECT COUNT(*) FROM native_source_requests WHERE reservation_id=? AND task_id=? AND capability_id=?
                                    AND epoch=? AND method='session_handoff'
                                """, bindings: [.text(reservation),.text(body.taskID.uuidString.lowercased()),
                                    .text(body.capabilityID.uuidString.lowercased()),.int64(body.epoch)]) == 1,
                              try connection.scalarInt("SELECT COUNT(*) FROM native_source_provider_calls WHERE reservation_id=?",
                                bindings: [.text(reservation)]) == 0 else { throw NativeSourceConversationError.integrityFailure }
                    }
                } else {
                    guard r.isNull(15), r.isNull(16) else { throw NativeSourceConversationError.integrityFailure }
                    disposition = nil
                }
                return .init(rowID: r.int64(0), body: body, digest: digest, state: state, post: post, accepted: accepted,
                    dispatchNonce: try r.strictText(10, maximumBytes: 36).map { try NativeTaskValue.uuid($0) },
                    dispatchOwner: try r.strictText(11, maximumBytes: 36).map { try NativeTaskValue.uuid($0) },
                    dispatchEpoch: r.isNull(12) ? nil : r.int64(12), blocked: try r.strictText(13, maximumBytes: 64),
                    budgetDisposition: disposition,
                    pressureReservationID: try r.strictText(16, maximumBytes: 36).map { try NativeTaskValue.uuid($0) })
            }) else { throw NativeSourceConversationError.notFound }
        return value
    }
    private func nativeLeaseUnlocked(_ lease: NativeSourceConversationLease, credential: NativeTaskCapabilityCredential,
        allowFenced: Bool = false, connection: ControlPlaneSQLiteConnection) throws -> (AuthenticatedContinuityTaskAttachment, NativeSourceConversationRow) {
        let attachment = try authenticateNativeTaskCapabilityUnlocked(credential, connection: connection)
        guard attachment.descriptor.taskID == lease.taskID, credential.capabilityID == lease.capabilityID,
              credential.epoch == lease.capabilityEpoch else { throw NativeSourceConversationError.notFound }
        let row = try nativeConversationUnlocked(lease.conversationID, attachment: attachment, connection: connection)
        guard row.owner == lease.managerInstanceID, row.leaseEpoch == lease.leaseEpoch,
              row.capabilityEpoch == credential.epoch, let expiry = row.leaseExpires,
              expiry >= lease.expiresAt, expiry > ISO8601.string(from: clock.now()),
              lease.expiresAt > ISO8601.string(from: clock.now()) else { throw NativeSourceConversationError.leaseUnavailable }
        guard !row.cancelled else { throw NativeSourceConversationError.cancelled }
        if !allowFenced {
            guard row.state != .sourceFenced else { throw NativeSourceConversationError.sourceFenced }
            if row.state == .stopped, let active = row.active,
               let disposition = try nativeStageUnlocked(active, conversation: row, connection: connection).budgetDisposition {
                switch disposition.metadata {
                case .pressure: throw NativeSourceConversationError.sourceFenced
                case .blocked: throw NativeSourceConversationError.conflict
                }
            }
        }
        return (attachment, row)
    }
    private static func nativeRetainedProviderResponseBytes(_ turn: ProviderTurn) throws -> Int {
        // Retain the original strings as JSON strings, including transport escaping.
        // Data's base64 Codable form alone can undercount function argument strings.
        let projection: [String: Any] = ["response_id":turn.responseID,"messages":turn.messages,
            "tool_calls":turn.toolCalls.map { ["call_id":$0.callID,"name":$0.name,"arguments":String(decoding: $0.argumentsJSON, as: UTF8.self)] }]
        let projected = try JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys]).count
        return max(projected, try JSONEncoder().encode(turn).count)
    }
    private func nativePrepared(_ stage: NativeSourceStageRow, conversation: NativeSourceConversationRow,
        connection: ControlPlaneSQLiteConnection) throws -> NativeSourcePreparedTurn {
        let prior = try connection.all("""
            SELECT post_json,post_sha256,result_json,result_sha256 FROM native_source_provider_turns
            WHERE conversation_id=? AND rowid<? ORDER BY rowid LIMIT 65
            """, bindings: [.text(conversation.body.conversationID.uuidString.lowercased()), .int64(stage.rowID)]) { row -> Int in
                guard let json = try row.strictText(0, maximumBytes: 32_768) else { throw NativeSourceConversationError.integrityFailure }
                let post = try NativeSourceJournalCoding.decode(NativeSourceStoredPost.self, json,
                    sha: Self.nativeSourceText(row, 1, 64), maximum: 32_768)
                let preflight = try post.preflight.value()
                var bytes = preflight.bodyByteCount
                if let result = try row.strictText(2, maximumBytes: 4_194_304) {
                    let turn = try NativeSourceJournalCoding.turn(NativeSourceJournalCoding.decode(ProviderTurn.self, result,
                        sha: Self.nativeSourceText(row, 3, 64), maximum: 4_194_304))
                    bytes = try Self.nativeSourceCheckedAdd(bytes, Self.nativeRetainedProviderResponseBytes(turn))
                }
                return bytes
            }
        guard prior.count <= 64 else { throw NativeSourceConversationError.integrityFailure }
        let priorBytes = try prior.reduce(0, Self.nativeSourceCheckedAdd)
        let observed = try connection.first("""
            SELECT preflight_json,preflight_sha256,capabilities_json,capabilities_sha256 FROM native_source_capability_checks
            WHERE stage_id=? AND state='completed' ORDER BY rowid DESC LIMIT 1
            """, bindings: [.text(stage.body.stageID.uuidString.lowercased())]) { row in
                let preflight = try NativeSourceJournalCoding.decode(NativeSourceStoredPreflight.self,
                    Self.nativeSourceText(row, 0, 8_192), sha: Self.nativeSourceText(row, 1, 64), maximum: 8_192).value()
                let caps = try NativeSourceJournalCoding.decode(ProviderCapabilities.self,
                    Self.nativeSourceText(row, 2, 8_192), sha: Self.nativeSourceText(row, 3, 64), maximum: 8_192)
                return (preflight, caps)
            }
        return .init(conversationID: stage.body.conversationID, taskID: stage.body.taskID, stageID: stage.body.stageID,
            requestID: stage.body.requestID, ordinal: stage.body.ordinal, state: stage.state,
            request: try stage.body.request(), intentSHA256: stage.digest, deadline: stage.body.deadline,
            priorUsage: stage.body.priorUsage, priorContextSerializedBytes: priorBytes, frozenCeilings: conversation.ceilings,
            retainedPreflight: try stage.post?.preflight.value() ?? observed?.0,
            retainedCapabilities: stage.post?.capabilities ?? observed?.1)
    }

    func enrollNativeSourceConversation(requestID: UUID, taskID: UUID, credential: NativeTaskCapabilityCredential,
        policySelection: BudgetPolicySelection, cancellation: ToolCallCancellation? = nil) throws -> NativeSourceConversationDescriptor {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let attachment = try authenticateNativeTaskCapabilityUnlocked(credential, connection: connection)
            guard attachment.descriptor.taskID == taskID else { throw NativeSourceConversationError.notFound }
            if let id = try connection.first("SELECT conversation_id FROM native_source_conversations WHERE task_id=?",
                bindings: [.text(taskID.uuidString.lowercased())], map: { try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36)) }) {
                return try nativeConversationDescriptor(nativeConversationUnlocked(id, attachment: attachment, connection: connection), connection: connection)
            }
            let task = attachment.setup.record
            try requireSourceMutationAdmissionUnlocked(task.authorization, connection: connection)
            try ContinuityIngressAcceptanceReceipt.validatePolicy(policySelection, authorization: task.authorization)
            guard task.runID == nil,
                  try connection.scalarInt("SELECT COUNT(*) FROM native_source_conversations") < 1_024,
                  try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE task_id=? AND state IN ('admitted','executing','pending')",
                    bindings: [.text(taskID.uuidString.lowercased())]) == 0 else { throw NativeSourceConversationError.conflict }
            let id = UUID(), timestamp = ISO8601.string(from: clock.now())
            let body = NativeSourceStoredConversation(conversationID: id, taskID: taskID, capabilityID: credential.capabilityID,
                requestID: requestID, projectID: task.authorization.projectID, projectGeneration: task.authorization.projectGeneration,
                callerBindingID: attachment.descriptor.originalCallerBindingID, sourceBindingID: task.authorization.sourceBindingID,
                assignmentSHA: task.assignment.assignmentSHA256, authorizationSHA: attachment.setup.correlation.authorizationSHA256,
                scopeSHA: attachment.descriptor.scopeSHA256, providerID: task.assignment.providerID, adapterID: task.assignment.adapterID,
                modelKey: task.assignment.modelKey, initialPolicy: policySelection,
                priorSourceReadCallsAtEnrollment: try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE task_id=? AND method='fs_read'", bindings: [.text(taskID.uuidString.lowercased())]),
                sourceLimits: attachment.sourceLimits, createdAt: timestamp)
            let bytes = try NativeSourceJournalCoding.encode(body, maximum: 65_536)
            try connection.execute("""
                INSERT INTO native_source_conversations(conversation_id,task_id,capability_id,project_id,project_generation,
                    body_json,body_sha256,state,revision,cancelled,lease_epoch,created_at,updated_at)
                VALUES(?,?,?,?,?,?,?,'idle',1,0,0,?,?)
                """, bindings: [.text(id.uuidString.lowercased()), .text(taskID.uuidString.lowercased()),
                    .text(credential.capabilityID.uuidString.lowercased()), .text(task.authorization.projectID.description),
                    .int64(try Self.sqliteGeneration(task.authorization.projectGeneration)), .text(String(decoding: bytes, as: UTF8.self)),
                    .text(JSONSupport.sha256Hex(bytes)), .text(timestamp), .text(timestamp)])
            return try nativeConversationDescriptor(nativeConversationUnlocked(id, attachment: attachment, connection: connection), connection: connection)
        }
    }
    func nativeSourceConversationStatus(conversationID: UUID, credential: NativeTaskCapabilityCredential,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceConversationDescriptor {
        try controlledTransaction(cancellation: cancellation) { connection in
            let a = try authenticateNativeTaskCapabilityUnlocked(credential, connection: connection)
            return try nativeConversationDescriptor(nativeConversationUnlocked(conversationID, attachment: a, connection: connection), connection: connection)
        }
    }
    func nativeSourceConversation(taskID: UUID, credential: NativeTaskCapabilityCredential,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceConversationDescriptor? {
        try controlledTransaction(cancellation: cancellation) { connection in
            let a = try authenticateNativeTaskCapabilityUnlocked(credential, connection: connection)
            guard a.descriptor.taskID == taskID else { throw NativeSourceConversationError.notFound }
            guard let id = try connection.first("SELECT conversation_id FROM native_source_conversations WHERE task_id=?",
                bindings: [.text(taskID.uuidString.lowercased())], map: { try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36)) }) else { return nil }
            return try nativeConversationDescriptor(nativeConversationUnlocked(id, attachment: a, connection: connection), connection: connection)
        }
    }
    func acquireNativeSourceConversationLease(conversationID: UUID, credential: NativeTaskCapabilityCredential,
        managerInstanceID: UUID, cancellation: ToolCallCancellation? = nil) throws -> NativeSourceConversationLease {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let a = try authenticateNativeTaskCapabilityUnlocked(credential, connection: connection)
            let row = try nativeConversationUnlocked(conversationID, attachment: a, connection: connection)
            guard !row.cancelled else { throw NativeSourceConversationError.cancelled }
            if row.state == .stopped, let active = row.active,
               try nativeStageUnlocked(active, conversation: row, connection: connection).budgetDisposition != nil {
                throw NativeSourceConversationError.sourceFenced
            }
            let now = ISO8601.string(from: clock.now())
            guard row.owner == nil || (row.leaseExpires ?? "") <= now else { throw NativeSourceConversationError.leaseUnavailable }
            guard row.leaseEpoch < Int64.max else { throw NativeSourceConversationError.capacityExceeded }
            try connection.execute("UPDATE native_source_capability_checks SET state='unknown',completed_at=? WHERE conversation_id=? AND state='attempted'",
                bindings: [.text(now),.text(conversationID.uuidString.lowercased())])
            try connection.execute("UPDATE native_source_provider_turns SET state='outcome_unknown',updated_at=? WHERE conversation_id=? AND state='submitted'",
                bindings: [.text(now),.text(conversationID.uuidString.lowercased())])

            let expiry = min(a.descriptor.expiresAt, ISO8601.string(from: clock.now().addingTimeInterval(30)))
            try connection.execute("""
                UPDATE native_source_conversations SET lease_owner=?,lease_epoch=lease_epoch+1,lease_capability_epoch=?,lease_expires_at=?
                WHERE conversation_id=?
                """, bindings: [.text(managerInstanceID.uuidString.lowercased()), .int64(credential.epoch), .text(expiry), .text(conversationID.uuidString.lowercased())])
            return .init(conversationID: conversationID, taskID: a.descriptor.taskID, capabilityID: credential.capabilityID,
                capabilityEpoch: credential.epoch, managerInstanceID: managerInstanceID, leaseEpoch: row.leaseEpoch + 1, expiresAt: expiry)
        }
    }
    func renewNativeSourceConversationLease(lease: NativeSourceConversationLease, credential: NativeTaskCapabilityCredential,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceConversationLease {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let (a, row) = try nativeLeaseUnlocked(lease, credential: credential, connection: connection)
            var expiry = min(a.descriptor.expiresAt, ISO8601.string(from: clock.now().addingTimeInterval(30)))
            if let active = row.active {
                let stage = try nativeStageUnlocked(active, conversation: row, connection: connection)
                if stage.state == .prepared || stage.state == .submitted { expiry = min(expiry, stage.body.deadline) }
            }
            guard expiry > ISO8601.string(from: clock.now()) else { throw NativeSourceConversationError.deadlineExceeded }
            try connection.execute("UPDATE native_source_conversations SET lease_expires_at=? WHERE conversation_id=?",
                bindings: [.text(expiry), .text(lease.conversationID.uuidString.lowercased())])
            return .init(conversationID: lease.conversationID, taskID: lease.taskID, capabilityID: lease.capabilityID,
                capabilityEpoch: lease.capabilityEpoch, managerInstanceID: lease.managerInstanceID, leaseEpoch: lease.leaseEpoch, expiresAt: expiry)
        }
    }
    func releaseNativeSourceConversationLease(lease: NativeSourceConversationLease) throws {
        _ = try controlledTransaction(cancellation: nil, fullDurability: true) { connection in
            try connection.execute("""
                UPDATE native_source_conversations SET lease_owner=NULL,lease_capability_epoch=NULL,lease_expires_at=NULL
                WHERE conversation_id=? AND task_id=? AND lease_owner=? AND lease_epoch=?
                  AND NOT EXISTS (SELECT 1 FROM native_source_provider_turns t
                    WHERE t.stage_id=native_source_conversations.active_stage_id
                      AND t.pressure_decision_json IS NOT NULL)
                """, bindings: [.text(lease.conversationID.uuidString.lowercased()), .text(lease.taskID.uuidString.lowercased()),
                    .text(lease.managerInstanceID.uuidString.lowercased()), .int64(lease.leaseEpoch)])
        }
    }
    func validateNativeSourceConversationLease(lease: NativeSourceConversationLease, credential: NativeTaskCapabilityCredential,
        cancellation: ToolCallCancellation? = nil) throws -> AuthenticatedContinuityTaskAttachment {
        try controlledTransaction(cancellation: cancellation) { connection in
            try nativeLeaseUnlocked(lease, credential: credential, connection: connection).0
        }
    }

    private func nativeInsertStage(_ body: NativeSourceStoredIntent, connection: ControlPlaneSQLiteConnection) throws {
        let cid = body.conversationID.uuidString.lowercased(), rid = body.requestID.uuidString.lowercased()
        guard try connection.scalarInt("SELECT COUNT(*) FROM native_source_provider_turns") < 4_096,
              try connection.scalarInt("SELECT COUNT(*) FROM native_source_provider_turns WHERE conversation_id=?", bindings: [.text(cid)]) < 64,
              try connection.scalarInt("SELECT (SELECT COUNT(*) FROM native_source_provider_turns WHERE conversation_id=? AND request_id=?)+(SELECT COUNT(*) FROM native_source_capability_checks WHERE conversation_id=? AND request_id=?)",
                bindings: [.text(cid),.text(rid),.text(cid),.text(rid)]) < 8 else { throw NativeSourceConversationError.capacityExceeded }
        let json = try NativeSourceJournalCoding.encode(body, maximum: NativeSourceJournalCoding.maximumIntentBytes)
        let usage = "COALESCE(SUM(length(CAST(intent_json AS BLOB))+COALESCE(length(CAST(result_json AS BLOB)),0)+reserved_bytes),0)"
        guard try connection.scalarInt("SELECT " + usage + " FROM native_source_provider_turns") <= 134_217_728 - NativeSourceJournalCoding.reservationBytes - json.count,
              try connection.scalarInt("SELECT " + usage + " FROM native_source_provider_turns WHERE conversation_id=?", bindings: [.text(cid)]) <= 33_554_432 - NativeSourceJournalCoding.reservationBytes - json.count else {
            throw NativeSourceConversationError.capacityExceeded
        }
        let now = ISO8601.string(from: clock.now())
        try connection.execute("""
            INSERT INTO native_source_provider_turns(stage_id,conversation_id,task_id,request_id,ordinal,intent_json,intent_sha256,
                state,reserved_bytes,created_at,updated_at) VALUES(?,?,?,?,?,?,?,'prepared',?,?,?)
            """, bindings: [.text(body.stageID.uuidString.lowercased()),.text(cid),.text(body.taskID.uuidString.lowercased()),.text(rid),
                .int64(Int64(body.ordinal)),.text(String(decoding: json, as: UTF8.self)),.text(JSONSupport.sha256Hex(json)),
                .int64(Int64(NativeSourceJournalCoding.reservationBytes)),.text(now),.text(now)])
        try connection.execute("UPDATE native_source_conversations SET active_stage_id=?,state='active',revision=revision+1,updated_at=? WHERE conversation_id=?",
            bindings: [.text(body.stageID.uuidString.lowercased()),.text(now),.text(cid)])
    }
    func prepareNativeSourceProviderTurn(request: NativeSourceTurnPreparationRequest, credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, tools: [Data], cancellation: ToolCallCancellation? = nil) throws -> NativeSourcePreparedTurn {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let (a, c) = try nativeLeaseUnlocked(lease, credential: credential, allowFenced: true, connection: connection)
            guard request.conversationID == c.body.conversationID, !request.userInput.isEmpty, request.userInput.utf8.count <= 16_384 else {
                throw NativeSourceConversationError.conflict
            }
            let cid = c.body.conversationID.uuidString.lowercased(), requestID = request.requestID.uuidString.lowercased()
            if let firstID = try connection.first("SELECT stage_id FROM native_source_provider_turns WHERE conversation_id=? AND request_id=? ORDER BY ordinal LIMIT 1",
                bindings: [.text(cid),.text(requestID)], map: { try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36)) }) {
                let first = try nativeStageUnlocked(firstID, conversation: c, connection: connection)
                guard first.body.logicalInputSHA == JSONSupport.sha256Hex(Data(request.userInput.utf8)), first.body.tools == tools,
                      let lastID = try connection.first("SELECT stage_id FROM native_source_provider_turns WHERE conversation_id=? AND request_id=? ORDER BY ordinal DESC LIMIT 1",
                        bindings: [.text(cid),.text(requestID)], map: { try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36)) }) else { throw NativeSourceConversationError.conflict }
                return try nativePrepared(nativeStageUnlocked(lastID, conversation: c, connection: connection), conversation: c, connection: connection)
            }
            try requireSourceMutationAdmissionUnlocked(a.setup.record.authorization, connection: connection)
            guard c.state == .idle, c.active == nil else { throw c.state == .sourceFenced ? NativeSourceConversationError.sourceFenced : .conflict }
            let names: Set<String> = ["fs_read","session_checkpoint","session_handoff"]
            let expected = try ToolDefinitionCatalog.production(toolNames: names.sorted()).providerToolDefinitions(allowedToolNames: names)
            guard tools == expected else { throw NativeSourceConversationError.invalidRequest("source_catalog") }
            let kind = c.parent == nil ? "root" : "user_continuation"
            let assignment = a.setup.record.assignment
            let input: Data
            if c.parent == nil {
                let document = String(data: assignment.assignmentBytes, encoding: .utf8) ?? "[Exact document bytes are retained in assignment_base64 below.]"
                let approval = String(decoding: try assignment.storedJSON(), as: UTF8.self)
                input = Data((assignment.mission + "\n\nApproved assignment:\n" + document + "\n\nImmutable approval:\n" + approval + "\n\nUser request:\n" + request.userInput).utf8)
            } else { input = try ForgeJSONCanonicalizationV1.data(from: [["role":"user","content":request.userInput]]) }
            var priorUsage: ProviderUsage?
            if let previous = try connection.first("SELECT stage_id FROM native_source_provider_turns WHERE conversation_id=? AND state='accepted' ORDER BY rowid DESC LIMIT 1",
                bindings: [.text(cid)], map: { try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36)) }) {
                priorUsage = try nativeStageUnlocked(previous, conversation: c, connection: connection).accepted?.usage
            }
            guard input.count <= 524_288 else { throw NativeSourceConversationError.capacityExceeded }
            let stageID = UUID()
            let body = NativeSourceStoredIntent(conversationID: c.body.conversationID, taskID: c.body.taskID, capabilityID: credential.capabilityID,
                stageID: stageID, requestID: request.requestID, epoch: credential.epoch, ordinal: 1,
                assignmentSHA: c.body.assignmentSHA, providerID: c.body.providerID, modelKey: c.body.modelKey, kind: kind,
                parentResponseID: c.parent, input: input, tools: tools,
                deadline: min(a.descriptor.expiresAt, ISO8601.string(from: clock.now().addingTimeInterval(300))),
                priorUsage: priorUsage, logicalInputSHA: JSONSupport.sha256Hex(Data(request.userInput.utf8)),
                logicalInputVersion: 1, logicalInput: request.userInput)
            _ = try body.request()
            try nativeInsertStage(body, connection: connection)
            return try nativePrepared(nativeStageUnlocked(stageID, conversation: c, connection: connection), conversation: c, connection: connection)
        }
    }
    private func nativeBudgetAcceptedTurn(_ stage: NativeSourceStageRow, conversation: NativeSourceConversationRow) throws -> ProviderTurn {
        guard stage.state == .accepted, stage.blocked == nil, let turn = stage.accepted, let post = stage.post,
              turn.completed, turn.requestID == stage.body.stageID.uuidString.lowercased(),
              turn.previousResponseID == stage.body.parentResponseID,
              turn.providerID == conversation.body.providerID, turn.modelKey == conversation.body.modelKey,
              turn.providerID == post.capabilities.providerID, turn.modelKey == post.capabilities.modelKey,
              turn.providerVersion == post.capabilities.providerVersion,
              turn.providerInstanceID == post.capabilities.providerInstanceID else { throw NativeSourceConversationError.integrityFailure }
        try nativeVerifyPreflight(post.preflight.value(), stage: stage, conversation: conversation)
        return turn
    }

    private func nativeBudgetBindingUnlocked(stage: NativeSourceStageRow, conversation c: NativeSourceConversationRow,
        boundary: NativeSourceBudgetBoundary, pendingCallOrdinal: Int?, connection: ControlPlaneSQLiteConnection) throws -> NativeSourceBudgetBinding {
        let isLatest = try connection.scalarInt("SELECT COUNT(*) FROM native_source_provider_turns WHERE conversation_id=? AND rowid>?",
            bindings: [.text(c.body.conversationID.uuidString.lowercased()),.int64(stage.rowID)]) == 0
        guard stage.blocked == nil, stage.budgetDisposition == nil, isLatest else { throw NativeSourceConversationError.conflict }
        var result: NativeSourceAcceptedResultIdentity?, pending: NativeSourcePendingCallIdentity?
        var completed = 0
        var outputs = Data("[]".utf8)
        if boundary == .beforeProviderPost {
            guard stage.state == .prepared, c.state == .active, c.active == stage.body.stageID,
                  pendingCallOrdinal == nil else { throw NativeSourceConversationError.conflict }
            if let parent = stage.body.parentResponseID {
                guard let priorID = try connection.first("SELECT stage_id FROM native_source_provider_turns WHERE conversation_id=? AND rowid<? ORDER BY rowid DESC LIMIT 1",
                    bindings: [.text(c.body.conversationID.uuidString.lowercased()),.int64(stage.rowID)],
                    map: { try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36)) }) else { throw NativeSourceConversationError.integrityFailure }
                let prior = try nativeStageUnlocked(priorID, conversation: c, connection: connection)
                let turn = try nativeBudgetAcceptedTurn(prior, conversation: c)
                guard turn.responseID == parent, stage.body.priorUsage == turn.usage else { throw NativeSourceConversationError.integrityFailure }
                result = .init(stageID: priorID, providerRequestID: turn.requestID, providerResponseID: turn.responseID,
                    resultSHA256: JSONSupport.sha256Hex(try NativeSourceJournalCoding.encode(turn, maximum: NativeSourceJournalCoding.maximumTurnBytes)))
            } else {
                guard stage.body.kind == "root", stage.body.priorUsage == nil else { throw NativeSourceConversationError.integrityFailure }
            }
        } else {
            guard stage.state == .accepted else { throw NativeSourceConversationError.conflict }
            let turn = try nativeBudgetAcceptedTurn(stage, conversation: c)
            let idleAssistant = c.state == .idle && c.active == nil && turn.toolCalls.isEmpty && c.parent == turn.responseID
            guard (c.state == .active && c.active == stage.body.stageID) || idleAssistant else { throw NativeSourceConversationError.conflict }
            result = .init(stageID: stage.body.stageID, providerRequestID: turn.requestID, providerResponseID: turn.responseID,
                resultSHA256: JSONSupport.sha256Hex(try NativeSourceJournalCoding.encode(turn, maximum: NativeSourceJournalCoding.maximumTurnBytes)))
            let calls = try connection.all("SELECT ordinal,call_json,call_sha256,arguments_json,arguments_sha256,reservation_id,output_json FROM native_source_provider_calls WHERE stage_id=? ORDER BY ordinal LIMIT 17",
                bindings: [.text(stage.body.stageID.uuidString.lowercased())]) { row in
                    (Int(row.int64(0)), try Self.nativeSourceText(row, 1, 8_192), try Self.nativeSourceText(row, 2, 64),
                     try Self.nativeSourceText(row, 3, 262_144), try Self.nativeSourceText(row, 4, 64),
                     !row.isNull(5), !row.isNull(6))
                }
            guard calls.count == turn.toolCalls.count, calls.count <= 16 else { throw NativeSourceConversationError.integrityFailure }
            var reachedPending = false
            for (index, call) in calls.enumerated() {
                let bytes = try nativeCallBytes(stage: stage, turn: turn, ordinal: index)
                let arguments = try ForgeJSONCanonicalizationV1.data(from: JSONSerialization.jsonObject(with: turn.toolCalls[index].argumentsJSON))
                guard call.0 == index, Data(call.1.utf8) == bytes, call.2 == JSONSupport.sha256Hex(bytes),
                      Data(call.3.utf8) == arguments, call.4 == JSONSupport.sha256Hex(arguments) else { throw NativeSourceConversationError.integrityFailure }
                if call.6 {
                    guard !reachedPending else { throw NativeSourceConversationError.integrityFailure }
                    completed += 1
                } else {
                    reachedPending = true
                    // A reserved effect without a completed receipt is not a safe
                    // pressure boundary, including an unknown outcome after restart.
                    guard !call.5 else { throw NativeSourceConversationError.conflict }
                }
                if pendingCallOrdinal == index {
                    pending = .init(ordinal: index, providerCallID: turn.toolCalls[index].callID,
                        toolName: turn.toolCalls[index].name, callSHA256: call.2, argumentsSHA256: call.4)
                }
            }
            outputs = try nativePriorOutputs(stage: stage, conversation: c, before: completed, connection: connection)
            if boundary == .beforeToolOutput {
                guard let pendingCallOrdinal, pendingCallOrdinal == completed, pending != nil,
                      completed < calls.count else { throw NativeSourceConversationError.conflict }
            } else {
                guard boundary == .acceptedProviderResponse, pendingCallOrdinal == nil else { throw NativeSourceConversationError.conflict }
            }
        }
        let priorCalls = try connection.scalarInt("SELECT COUNT(*) FROM native_source_provider_calls AS calls JOIN native_source_provider_turns AS stages ON stages.stage_id=calls.stage_id WHERE stages.conversation_id=? AND stages.rowid<?",
            bindings: [.text(c.body.conversationID.uuidString.lowercased()),.int64(stage.rowID)])
        let stageCalls = try connection.scalarInt("SELECT COUNT(*) FROM native_source_provider_calls WHERE stage_id=?",
            bindings: [.text(stage.body.stageID.uuidString.lowercased())])
        return try NativeSourceBudgetBinding(projectID: c.body.projectID, projectGeneration: c.body.projectGeneration,
            taskID: c.body.taskID, capabilityID: c.body.capabilityID, capabilityEpoch: stage.body.epoch,
            conversationID: c.body.conversationID, conversationRevision: c.revision,
            stageID: stage.body.stageID, stageOrdinal: stage.body.ordinal, logicalRequestID: stage.body.requestID,
            assignmentSHA256: stage.body.assignmentSHA, logicalInputSHA256: stage.body.logicalInputSHA,
            intentSHA256: stage.digest, sourceInferenceDeadline: stage.body.deadline, stageState: stage.state,
            boundary: boundary, observedResult: result, completedOutputCount: completed,
            completedOutputsSHA256: JSONSupport.sha256Hex(outputs), pendingCall: pending,
            sourceReadCallsBeforeEnrollment: c.body.priorSourceReadCallsAtEnrollment,
            admittedProviderCallsBeforeStage: priorCalls, admittedCallsInStage: stageCalls,
            sourceMaximumCalls: c.body.sourceLimits.maximumCalls).validated()
    }

    private func nativeBudgetMetadata<Admission: Sendable>(
        _ decision: NativeSourceBudgetDecision<Admission>
    ) throws -> NativeSourceBudgetMetadata {
        switch decision {
        case .admitted: throw NativeSourceConversationError.conflict
        case .pressure(let pressure): return .pressure(pressure)
        case .blocked(let failure): return .blocked(failure)
        }
    }

    /// The full numerical decision is recomputed from CP-retained observations.
    /// This transaction fences inference but never submits a provider request or
    /// creates a ready source packet. Storage receives its own once-fixed deadline.
    func recordNativeSourceBudgetDisposition(metadata: NativeSourceBudgetMetadata,
        credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        policySelection: BudgetPolicySelection, cancellation: ToolCallCancellation? = nil
    ) throws -> NativeSourceBudgetDispositionResult {
        let binding: NativeSourceBudgetBinding
        switch metadata {
        case .pressure(let value): binding = value.observation.binding
        case .blocked(let value): binding = value.binding
        }
        return try controlledTransaction(cancellation: cancellation, fullDurability: true, beforeCommitValidation: {
            let connection = try self.requiredConnection()
            let (a, c) = try self.nativeLeaseUnlocked(lease, credential: credential, allowFenced: true, connection: connection)
            try self.requireSourceMutationAdmissionUnlocked(a.setup.record.authorization, connection: connection)
            let stage = try self.nativeStageUnlocked(binding.stageID, conversation: c, connection: connection)
            if binding.boundary == .beforeProviderPost {
                guard stage.body.deadline > ISO8601.string(from: self.clock.now()) else {
                    throw NativeSourceConversationError.deadlineExceeded
                }
            }
        }) { connection in
            let (attachment, conversation) = try nativeLeaseUnlocked(lease, credential: credential,
                allowFenced: true, connection: connection)
            try requireSourceMutationAdmissionUnlocked(attachment.setup.record.authorization, connection: connection)
            try ContinuityIngressAcceptanceReceipt.validatePolicy(policySelection, authorization: attachment.setup.record.authorization)
            let stage = try nativeStageUnlocked(binding.stageID, conversation: conversation, connection: connection)
            guard binding.conversationID == conversation.body.conversationID,
                  binding.taskID == attachment.descriptor.taskID,
                  binding.capabilityID == credential.capabilityID, binding.capabilityEpoch == credential.epoch else {
                throw NativeSourceConversationError.conflict
            }
            let supplied = try metadata.canonicalJSON()
            if let retained = stage.budgetDisposition {
                guard try retained.metadata.canonicalJSON() == supplied else { throw NativeSourceConversationError.conflict }
                switch retained.metadata {
                case .blocked: return .blocked(retained)
                case .pressure: return .pressure(try nativePressureClaimUnlocked(conversation: conversation,
                    stage: stage, attachment: attachment))
                }
            }
            let actualBinding = try nativeBudgetBindingUnlocked(stage: stage, conversation: conversation,
                boundary: binding.boundary, pendingCallOrdinal: binding.pendingCall?.ordinal, connection: connection)
            guard actualBinding == binding,
                  try connection.scalarInt("SELECT COUNT(*) FROM native_source_capability_checks WHERE conversation_id=? AND state='attempted'",
                    bindings: [.text(binding.conversationID.uuidString.lowercased())]) == 0,
                  try connection.scalarInt("SELECT COUNT(*) FROM native_source_provider_turns WHERE conversation_id=? AND state IN('submitted','outcome_unknown')",
                    bindings: [.text(binding.conversationID.uuidString.lowercased())]) == 0 else {
                throw NativeSourceConversationError.conflict
            }
            let recomputed: NativeSourceBudgetMetadata
            switch binding.boundary {
            case .beforeProviderPost:
                guard stage.body.deadline > ISO8601.string(from: clock.now()) else { throw NativeSourceConversationError.deadlineExceeded }
                let prepared = try nativePrepared(stage, conversation: conversation, connection: connection)
                guard let preflight = prepared.retainedPreflight, let capabilities = prepared.retainedCapabilities else {
                    throw NativeSourceConversationError.unsupportedProvider
                }
                try nativeVerifyPreflight(preflight, stage: stage, conversation: conversation)
                recomputed = try nativeBudgetMetadata(NativeSourceBudgetEvaluator.providerDecision(prepared: prepared,
                    preflight: preflight, capabilities: capabilities, policySelection: policySelection, binding: actualBinding))
            case .acceptedProviderResponse:
                let accepted = try nativeAcceptedUnlocked(stage, conversation: conversation, connection: connection)
                guard let post = stage.post else { throw NativeSourceConversationError.integrityFailure }
                let bytes = try Self.nativeSourceCheckedAdd(accepted.prepared.priorContextSerializedBytes,
                    Self.nativeSourceCheckedAdd(post.preflight.bytes, Self.nativeRetainedProviderResponseBytes(accepted.turn)))
                recomputed = try nativeBudgetMetadata(NativeSourceBudgetEvaluator.acceptedDecision(
                    context: .init(binding: actualBinding, accepted: accepted, retainedContextSerializedBytes: bytes),
                    policySelection: policySelection))
            case .beforeToolOutput:
                // Output admission needs the exact continuation-envelope proof;
                // no caller-supplied projection may substitute for that future seam.
                throw NativeSourceConversationError.invalidRequest("pressure_output_boundary_not_connected")
            }
            guard try recomputed.canonicalJSON() == supplied else { throw NativeSourceConversationError.conflict }
            let timestamp = ISO8601.string(from: clock.now())
            let storageDeadline: String?
            let pressureObservation: NativeSourceBudgetObservation?
            switch recomputed {
            case .pressure(let value):
                storageDeadline = min(attachment.descriptor.expiresAt, ISO8601.string(from: clock.now().addingTimeInterval(300)))
                pressureObservation = value.observation
            case .blocked: storageDeadline = nil; pressureObservation = nil
            }
            let nextRevision = conversation.revision.addingReportingOverflow(1)
            guard !nextRevision.overflow else { throw NativeSourceConversationError.capacityExceeded }
            let stored = try NativeSourceStoredBudgetDisposition(version: 1, metadata: recomputed,
                fenceRevision: nextRevision.partialValue, recordedAt: timestamp, storageDeadline: storageDeadline).validated()
            let bytes = try NativeSourceJournalCoding.encode(stored, maximum: NativeSourceBudgetMetadata.maximumStoredBytes)
            let frozen = try pressureObservation.map { try NativeSourceJournalCoding.encode($0.fields.effectiveCeilings, maximum: 8_192) }
            guard try connection.execute("""
                UPDATE native_source_conversations SET state='stopped',active_stage_id=?,revision=revision+1,updated_at=?,
                    configuration_sha256=COALESCE(configuration_sha256,?),ceilings_json=COALESCE(ceilings_json,?),
                    ceilings_sha256=COALESCE(ceilings_sha256,?) WHERE conversation_id=? AND revision=? AND cancelled=0
                """, bindings: [.text(binding.stageID.uuidString.lowercased()),.text(timestamp),
                    .optionalText(pressureObservation?.fields.preflight.configurationSHA),
                    .optionalText(frozen.map { String(decoding: $0, as: UTF8.self) }),.optionalText(frozen.map(JSONSupport.sha256Hex)),
                    .text(binding.conversationID.uuidString.lowercased()),.int64(binding.conversationRevision)]) == 1 else {
                throw NativeSourceConversationError.conflict
            }
            guard try connection.execute("""
                UPDATE native_source_provider_turns SET pressure_decision_json=?,pressure_decision_sha256=?,blocked_code=?,updated_at=?
                WHERE stage_id=? AND pressure_decision_json IS NULL AND blocked_code IS NULL
                """, bindings: [.text(String(decoding: bytes, as: UTF8.self)),.text(JSONSupport.sha256Hex(bytes)),
                    .text(storageDeadline == nil ? "budget_blocked" : "pressure_pending"),.text(timestamp),
                    .text(binding.stageID.uuidString.lowercased())]) == 1 else { throw NativeSourceConversationError.conflict }
            switch recomputed {
            case .blocked: return .blocked(stored)
            case .pressure:
                let fenced = try nativeConversationUnlocked(binding.conversationID, attachment: attachment, connection: connection)
                return .pressure(try nativePressureClaimUnlocked(conversation: fenced,
                    stage: nativeStageUnlocked(binding.stageID, conversation: fenced, connection: connection), attachment: attachment))
            }
        }
    }

    private func nativePressureClaimUnlocked(conversation: NativeSourceConversationRow,
        stage: NativeSourceStageRow, attachment: AuthenticatedContinuityTaskAttachment
    ) throws -> NativeSourcePressureClaim {
        let now = ISO8601.string(from: clock.now())
        guard !conversation.cancelled else { throw NativeSourceConversationError.cancelled }
        guard (conversation.state == .stopped || (conversation.state == .sourceFenced && stage.blocked == "pressure_committed")), conversation.active == stage.body.stageID,
              ["pressure_pending", "pressure_prepared", "pressure_committed"].contains(stage.blocked ?? ""), let stored = stage.budgetDisposition,
              case .pressure = stored.metadata, stored.binding.stageState == stage.state,
              (stored.fenceRevision == conversation.revision || (stage.blocked == "pressure_committed" && stored.fenceRevision < Int64.max && stored.fenceRevision + 1 == conversation.revision)), let deadline = stored.storageDeadline else {
            throw NativeSourceConversationError.conflict
        }
        guard deadline > now else { throw NativeSourceConversationError.deadlineExceeded }
        guard let owner = conversation.owner, let expiry = conversation.leaseExpires,
              expiry > now, conversation.capabilityEpoch == attachment.descriptor.epoch else {
            throw NativeSourceConversationError.leaseUnavailable
        }
        return .init(conversationID: conversation.body.conversationID, taskID: conversation.body.taskID,
            capabilityID: conversation.body.capabilityID, stageID: stage.body.stageID,
            capabilityEpoch: attachment.descriptor.epoch, leaseEpoch: conversation.leaseEpoch,
            fenceRevision: stored.fenceRevision, managerInstanceID: owner, expiresAt: min(expiry, deadline),
            storageDeadline: deadline, dispositionSHA256: JSONSupport.sha256Hex(
                try NativeSourceJournalCoding.encode(stored, maximum: NativeSourceBudgetMetadata.maximumStoredBytes)))
    }

    private func nativePressureStateUnlocked(claim: NativeSourcePressureClaim,
        credential: NativeTaskCapabilityCredential, connection: ControlPlaneSQLiteConnection
    ) throws -> (AuthenticatedContinuityTaskAttachment, NativeSourceConversationRow, NativeSourceStageRow) {
        let attachment = try authenticateNativeTaskCapabilityUnlocked(credential, connection: connection)
        guard attachment.descriptor.taskID == claim.taskID, credential.capabilityID == claim.capabilityID,
              credential.epoch == claim.capabilityEpoch else { throw NativeSourceConversationError.notFound }
        let conversation = try nativeConversationUnlocked(claim.conversationID, attachment: attachment, connection: connection)
        let stage = try nativeStageUnlocked(claim.stageID, conversation: conversation, connection: connection)
        let current = try nativePressureClaimUnlocked(conversation: conversation, stage: stage, attachment: attachment)
        guard current.managerInstanceID == claim.managerInstanceID, current.leaseEpoch == claim.leaseEpoch,
              current.fenceRevision == claim.fenceRevision, current.dispositionSHA256 == claim.dispositionSHA256,
              current.storageDeadline == claim.storageDeadline, current.expiresAt >= claim.expiresAt,
              claim.expiresAt > ISO8601.string(from: clock.now()) else { throw NativeSourceConversationError.leaseUnavailable }
        try nativePressureMutationAdmissionUnlocked(attachment.setup.record.authorization, stage: stage, connection: connection)
        return (attachment, conversation, stage)
    }

    func nativeSourcePressureDisposition(claim: NativeSourcePressureClaim, credential: NativeTaskCapabilityCredential,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceStoredBudgetDisposition {
        try controlledTransaction(cancellation: cancellation) { connection in
            let (_, _, stage) = try nativePressureStateUnlocked(claim: claim, credential: credential, connection: connection)
            guard let disposition = stage.budgetDisposition else { throw NativeSourceConversationError.integrityFailure }
            return disposition
        }
    }

    func acquireNativeSourcePressureClaim(conversationID: UUID, stageID: UUID,
        credential: NativeTaskCapabilityCredential, managerInstanceID: UUID,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourcePressureClaim {
        try controlledTransaction(cancellation: cancellation, fullDurability: true, beforeCommitValidation: {
            let connection = try self.requiredConnection()
            let a = try self.authenticateNativeTaskCapabilityUnlocked(credential, connection: connection)
            let c = try self.nativeConversationUnlocked(conversationID, attachment: a, connection: connection)
            let stage = try self.nativeStageUnlocked(stageID, conversation: c, connection: connection)
            let claim = try self.nativePressureClaimUnlocked(conversation: c, stage: stage, attachment: a)
            guard claim.managerInstanceID == managerInstanceID else { throw NativeSourceConversationError.leaseUnavailable }
            try self.nativePressureMutationAdmissionUnlocked(a.setup.record.authorization, stage: stage, connection: connection)
        }) { connection in
            let a = try authenticateNativeTaskCapabilityUnlocked(credential, connection: connection)
            let c = try nativeConversationUnlocked(conversationID, attachment: a, connection: connection)
            let stage = try nativeStageUnlocked(stageID, conversation: c, connection: connection)
            try nativePressureMutationAdmissionUnlocked(a.setup.record.authorization, stage: stage, connection: connection)
            let now = ISO8601.string(from: clock.now())
            guard !c.cancelled else { throw NativeSourceConversationError.cancelled }
            guard (c.state == .stopped || (c.state == .sourceFenced && stage.blocked == "pressure_committed")), c.active == stageID, ["pressure_pending", "pressure_prepared", "pressure_committed"].contains(stage.blocked ?? ""),
                  let stored = stage.budgetDisposition, case .pressure = stored.metadata,
                  let deadline = stored.storageDeadline else { throw NativeSourceConversationError.conflict }
            guard deadline > now else { throw NativeSourceConversationError.deadlineExceeded }
            guard c.owner == nil || (c.leaseExpires ?? "") <= now else { throw NativeSourceConversationError.leaseUnavailable }
            guard c.leaseEpoch < Int64.max else { throw NativeSourceConversationError.capacityExceeded }
            let expiry = min(deadline, a.descriptor.expiresAt, ISO8601.string(from: clock.now().addingTimeInterval(30)))
            try connection.execute("""
                UPDATE native_source_conversations SET lease_owner=?,lease_epoch=lease_epoch+1,lease_capability_epoch=?,lease_expires_at=?
                WHERE conversation_id=?
                """, bindings: [.text(managerInstanceID.uuidString.lowercased()),.int64(credential.epoch),.text(expiry),
                    .text(conversationID.uuidString.lowercased())])
            return try nativePressureClaimUnlocked(conversation: nativeConversationUnlocked(conversationID,
                attachment: a, connection: connection), stage: stage, attachment: a)
        }
    }

    func renewNativeSourcePressureClaim(claim: NativeSourcePressureClaim, credential: NativeTaskCapabilityCredential,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourcePressureClaim {
        try controlledTransaction(cancellation: cancellation, fullDurability: true, beforeCommitValidation: {
            _ = try self.nativePressureStateUnlocked(claim: claim, credential: credential, connection: self.requiredConnection())
        }) { connection in
            let (a, c, stage) = try nativePressureStateUnlocked(claim: claim, credential: credential, connection: connection)
            let expiry = min(claim.storageDeadline, a.descriptor.expiresAt, ISO8601.string(from: clock.now().addingTimeInterval(30)))
            try connection.execute("UPDATE native_source_conversations SET lease_expires_at=? WHERE conversation_id=?",
                bindings: [.text(expiry),.text(c.body.conversationID.uuidString.lowercased())])
            return try nativePressureClaimUnlocked(conversation: nativeConversationUnlocked(c.body.conversationID,
                attachment: a, connection: connection), stage: stage, attachment: a)
        }
    }

    func releaseNativeSourcePressureClaim(_ claim: NativeSourcePressureClaim) throws -> Bool {
        try controlledTransaction(cancellation: nil, fullDurability: true) { connection in
            try connection.execute("""
                UPDATE native_source_conversations SET lease_owner=NULL,lease_capability_epoch=NULL,lease_expires_at=NULL
                WHERE conversation_id=? AND task_id=? AND capability_id=? AND lease_owner=? AND lease_epoch=? AND lease_capability_epoch=?
                """, bindings: [.text(claim.conversationID.uuidString.lowercased()),.text(claim.taskID.uuidString.lowercased()),
                    .text(claim.capabilityID.uuidString.lowercased()),.text(claim.managerInstanceID.uuidString.lowercased()),
                    .int64(claim.leaseEpoch),.int64(claim.capabilityEpoch)]) == 1
        }
    }

    private func nativePressureMutationAdmissionUnlocked(_ authorization: ContinuityIngressAuthorization,
        stage: NativeSourceStageRow, connection: ControlPlaneSQLiteConnection) throws {
        guard let reservationID = stage.pressureReservationID else {
            return try requireSourceMutationAdmissionUnlocked(authorization, connection: connection)
        }
        guard try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE task_id=? AND method='session_handoff' AND reservation_id!=?",
            bindings: [.text(authorization.taskID.uuidString.lowercased()),.text(reservationID.uuidString.lowercased())]) == 0 else {
            throw NativeTaskCapabilityError.sourceFenced
        }
        // A source outbox may already have been accepted after a lost CP receipt.
        // Only that same immutable packet may cross its own quiescing fence.
        if let operation = try connection.first("SELECT operation_id FROM continuity_source_task_fences WHERE source_binding_id=? OR task_id=?",
            bindings: [.text(authorization.sourceBindingID.uuidString.lowercased()),.text(authorization.taskID.uuidString.lowercased())],
            map: { try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36)) }) {
            guard let receipt = try acceptanceForOperationUnlocked(operation, connection: connection),
                  receipt.authorization == authorization,
                  let packet = try connection.first("SELECT prepared_packet_json FROM native_source_requests WHERE reservation_id=? AND task_id=? AND capability_id=?",
                    bindings: [.text(reservationID.uuidString.lowercased()),.text(stage.body.taskID.uuidString.lowercased()),
                        .text(stage.body.capabilityID.uuidString.lowercased())], map: { try Self.nativeSourceText($0, 0, 262_144) }),
                  receipt.source.canonicalPacketJSON == Data(packet.utf8) else { throw NativeTaskCapabilityError.sourceFenced }
            try requireContinuityOperationNotCancelledUnlocked(operation, connection: connection)
        }
    }

    private struct NativePressureSourceIdentity {
        let pressureID: UUID, reservationID: UUID
        let continuityID: String
        let key: NativeSourceRequestKey
        let arguments: Data
    }
    private func nativePressureSourceIdentity(_ claim: NativeSourcePressureClaim,
        stored: NativeSourceStoredBudgetDisposition) throws -> NativePressureSourceIdentity {
        try nativePressureSourceIdentity(taskID: claim.taskID, capabilityID: claim.capabilityID,
            conversationID: claim.conversationID, stageID: claim.stageID,
            dispositionSHA256: claim.dispositionSHA256, stored: stored)
    }
    private func nativePressureSourceIdentity(taskID: UUID, capabilityID: UUID, conversationID: UUID,
        stageID: UUID, dispositionSHA256: String, stored: NativeSourceStoredBudgetDisposition) throws -> NativePressureSourceIdentity {
        func digest(_ object: [String: Any]) throws -> String { try ForgeJSONCanonicalizationV1.sha256Hex(of: object) }
        func uuid(_ sha: String) throws -> UUID {
            let h = Array(sha.prefix(32))
            return try NativeTaskValue.uuid(String(h[0..<8]) + "-" + String(h[8..<12]) + "-" + String(h[12..<16])
                + "-" + String(h[16..<20]) + "-" + String(h[20..<32]))
        }
        let pressure = try digest(["kind":"forge.native-source-pressure.identity.v1", "task_id":taskID.uuidString.lowercased(),
            "conversation_id":conversationID.uuidString.lowercased(), "stage_id":stageID.uuidString.lowercased(),
            "disposition_sha256":dispositionSHA256])
        let pressureID = try uuid(pressure)
        let source = try uuid(digest(["kind":"forge.native-source-pressure.source.v1", "pressure_sha256":pressure])).uuidString.lowercased()
        let namespace = try digest(["kind":"forge.native-source-pressure.namespace.v1", "capability_id":capabilityID.uuidString.lowercased(),
            "conversation_id":conversationID.uuidString.lowercased()])
        let request = try digest(["kind":"forge.native-source-pressure.request.v1", "pressure_sha256":pressure,
            "disposition_sha256":dispositionSHA256])
        let reservation = try uuid(digest(["kind":"forge.native-source-pressure.reservation.v1", "namespace_sha256":namespace,
            "request_sha256":request]))
        return try .init(pressureID: pressureID, reservationID: reservation, continuityID: source,
            key: .init(sessionID: uuid(namespace), requestIDSHA256: request),
            arguments: ForgeJSONCanonicalizationV1.data(from: ["producer":"manager_budget_v1",
                "pressure_id":pressureID.uuidString.lowercased(), "continuity_id":source,
                "disposition_sha256":dispositionSHA256, "metadata_sha256":JSONSupport.sha256Hex(stored.metadata.canonicalJSON())]))
    }

    private func nativePressureSnapshotUnlocked(claim: NativeSourcePressureClaim,
        attachment: AuthenticatedContinuityTaskAttachment, conversation: NativeSourceConversationRow,
        stage: NativeSourceStageRow, connection: ControlPlaneSQLiteConnection) throws -> NativeSourcePressurePacketInput {
        guard let stored = stage.budgetDisposition, case .pressure(let decision) = stored.metadata,
              let kind = NativeSourcePressureRequestKind(rawValue: stage.body.kind) else { throw NativeSourceConversationError.integrityFailure }
        let identity = try nativePressureSourceIdentity(claim, stored: stored)
        let stageIDs = try connection.all("SELECT stage_id FROM native_source_provider_turns WHERE conversation_id=? ORDER BY rowid LIMIT 65",
            bindings: [.text(claim.conversationID.uuidString.lowercased())]) { try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36)) }
        guard stageIDs.count <= 64, stageIDs.last == claim.stageID else { throw NativeSourceConversationError.conflict }
        var progress: [NativeSourcePressureCompletedProgress] = []
        var outputs: [NativeSourcePressureCompletedOutput] = []
        var untouched: [NativeSourcePressurePendingCall] = []
        var admittedCalls = 0
        for id in stageIDs {
            let item = try nativeStageUnlocked(id, conversation: conversation, connection: connection)
            guard item.state == .accepted || (id == claim.stageID && item.state == .prepared) else {
                throw NativeSourceConversationError.conflict
            }
            guard let turn = item.accepted else { continue }
            let resultSHA = JSONSupport.sha256Hex(try NativeSourceJournalCoding.encode(turn, maximum: NativeSourceJournalCoding.maximumTurnBytes))
            progress.append(.init(stageID: id, providerResponseID: turn.responseID, resultSHA256: resultSHA, messages: turn.messages))
            let calls = try connection.all("SELECT ordinal,call_json,call_sha256,arguments_json,arguments_sha256,reservation_id,output_json FROM native_source_provider_calls WHERE stage_id=? ORDER BY ordinal LIMIT 17",
                bindings: [.text(id.uuidString.lowercased())]) { row in
                    (Int(row.int64(0)), try Self.nativeSourceText(row, 1, 8_192), try Self.nativeSourceText(row, 2, 64),
                     try Self.nativeSourceText(row, 3, 262_144), try Self.nativeSourceText(row, 4, 64), !row.isNull(5), !row.isNull(6))
                }
            guard calls.count == turn.toolCalls.count, calls.count <= 16 else { throw NativeSourceConversationError.integrityFailure }
            admittedCalls = try Self.nativeSourceCheckedAdd(admittedCalls, calls.count)
            for (ordinal, call) in calls.enumerated() {
                let actual = turn.toolCalls[ordinal]
                let bytes = try nativeCallBytes(stage: item, turn: turn, ordinal: ordinal)
                let args = try ForgeJSONCanonicalizationV1.data(from: JSONSerialization.jsonObject(with: actual.argumentsJSON))
                guard call.0 == ordinal, Data(call.1.utf8) == bytes, call.2 == JSONSupport.sha256Hex(bytes),
                      Data(call.3.utf8) == args, call.4 == JSONSupport.sha256Hex(args) else { throw NativeSourceConversationError.integrityFailure }
                if call.6 {
                    guard untouched.isEmpty,
                          let output = try nativeOutputUnlocked(reference: .init(conversationID: claim.conversationID,
                            stageID: id, ordinal: ordinal, checksum: call.2), stage: item, conversation: conversation, connection: connection),
                          !output.readyHandoffCommitted else { throw NativeSourceConversationError.conflict }
                    let receiptSHA = try connection.first("SELECT result_sha256 FROM native_source_requests WHERE reservation_id=?",
                        bindings: [.text(output.reservationID.uuidString.lowercased())]) { try Self.nativeSourceText($0, 0, 64) }
                    guard let receiptSHA else { throw NativeSourceConversationError.integrityFailure }
                    outputs.append(.init(stageID: id, ordinal: ordinal, providerResponseID: turn.responseID,
                        providerCallID: actual.callID, toolName: actual.name, canonicalArgumentsJSON: args, argumentsSHA256: call.4,
                        canonicalToolResultJSON: output.canonicalToolResultJSON, resultSHA256: output.resultSHA256,
                        payloadSHA256: output.payloadSHA256, reservationID: output.reservationID, sourceReceiptSHA256: receiptSHA))
                } else {
                    guard id == claim.stageID, !call.5 else { throw NativeSourceConversationError.conflict }
                    untouched.append(.init(stageID: id, ordinal: ordinal, providerResponseID: turn.responseID,
                        providerCallID: actual.callID, toolName: actual.name, canonicalArgumentsJSON: args, argumentsSHA256: call.4))
                }
            }
        }
        let binding = stored.binding
        guard admittedCalls == binding.admittedProviderCallsBeforeStage + binding.admittedCallsInStage else {
            throw NativeSourceConversationError.integrityFailure
        }
        let checks = try connection.scalarInt("SELECT COUNT(*) FROM native_source_capability_checks WHERE conversation_id=?",
            bindings: [.text(claim.conversationID.uuidString.lowercased())])
        return .init(identity: .init(pressureID: identity.pressureID, continuityID: identity.continuityID,
            recordedAt: stored.recordedAt, projectID: binding.projectID, projectGeneration: binding.projectGeneration,
            taskID: claim.taskID, conversationID: claim.conversationID, requestID: binding.logicalRequestID,
            stageID: claim.stageID, fenceRevision: claim.fenceRevision, assignmentSHA256: binding.assignmentSHA256,
            logicalInputSHA256: binding.logicalInputSHA256, intentSHA256: binding.intentSHA256),
            assignment: attachment.setup.record.assignment,
            logicalInput: stage.body.logicalInput.map { .originalUTF8(Data($0.utf8)) }
                ?? .legacyRetainedRequest(kind: kind, utf8: stage.body.input),
            pendingRequest: stage.state == .prepared ? .init(kind: kind, utf8: stage.body.input,
                inputSHA256: JSONSupport.sha256Hex(stage.body.input), historicalParentResponseID: stage.body.parentResponseID) : nil,
            completedProgress: progress, completedOutputs: outputs, untouchedCalls: untouched, uncertainties: [], unresolvedEffects: [],
            remainingBudget: .init(ceilings: decision.observation.fields.effectiveCeilings, sourceLimits: conversation.body.sourceLimits,
                priorSourceReadCallsAtEnrollment: conversation.body.priorSourceReadCallsAtEnrollment,
                admittedProviderCalls: admittedCalls, providerStageCount: stageIDs.count, capabilityCheckCount: checks),
            canonicalDecisionJSON: try stored.metadata.canonicalJSON(), optionalPreview: nil)
    }

    func prepareNativeSourceBudgetHandoff(claim: NativeSourcePressureClaim, credential: NativeTaskCapabilityCredential,
        policySelection: BudgetPolicySelection, responsePreflight: NativeSourcePressurePacketBuilder.ResponsePreflight,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourcePressureCommitAdmissionResult {
        try controlledTransaction(cancellation: cancellation, fullDurability: true, beforeCommitValidation: {
            _ = try self.nativePressureStateUnlocked(claim: claim, credential: credential, connection: self.requiredConnection())
        }) { connection in
            let (a, c, stage) = try nativePressureStateUnlocked(claim: claim, credential: credential, connection: connection)
            try ContinuityIngressAcceptanceReceipt.validatePolicy(policySelection, authorization: a.setup.record.authorization)
            guard let stored = stage.budgetDisposition, case .pressure = stored.metadata else { throw NativeSourceConversationError.integrityFailure }
            let identity = try nativePressureSourceIdentity(claim, stored: stored)
            if let row = try nativeSourceRowUnlocked(key: identity.key, connection: connection) {
                guard row.id == identity.reservationID, stage.pressureReservationID == row.id,
                      row.taskID == claim.taskID, row.capabilityID == claim.capabilityID, row.epoch == claim.capabilityEpoch,
                      row.argumentsSHA == JSONSupport.sha256Hex(identity.arguments), row.chargedCalls == 0,
                      row.method == "session_handoff", row.deadline == claim.storageDeadline else { throw NativeSourceConversationError.integrityFailure }
                let (prepared, automatic) = try nativePreparedCommitUnlocked(row, authorization: a.setup.record.authorization, connection: connection)
                guard prepared.continuityID == identity.continuityID else { throw NativeSourceConversationError.integrityFailure }
                if row.state == "completed" { return .completed(try nativeCommitResultUnlocked(row, prepared: prepared,
                    authorization: a.setup.record.authorization, connection: connection)) }
                guard row.state == "pending" else { throw NativeSourceConversationError.conflict }
                return .commit(.init(reservationID: row.id, prepared: prepared, authorization: a.setup.record.authorization,
                    automaticHandoffEnabled: automatic, dispositionSHA256: claim.dispositionSHA256))
            }
            guard stage.pressureReservationID == nil, stage.blocked == "pressure_pending" else { throw NativeSourceConversationError.integrityFailure }
            try nativeSourceCapacityUnlocked(taskID: claim.taskID, connection: connection)
            guard try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE task_id=? AND state='pending'",
                bindings: [.text(claim.taskID.uuidString.lowercased())]) == 0 else { throw NativeTaskCapabilityError.operationBusy }
            guard try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE method!='fs_read'") < 1_024,
                  try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE task_id=? AND method!='fs_read'",
                    bindings: [.text(claim.taskID.uuidString.lowercased())]) < 64 else { throw NativeTaskCapabilityError.capacityExceeded }
            let snapshot = try nativePressureSnapshotUnlocked(claim: claim, attachment: a, conversation: c, stage: stage, connection: connection)
            let prepared = try NativeSourcePressurePacketBuilder.build(snapshot, responsePreflight: responsePreflight)
            guard try connection.scalarInt("SELECT COALESCE(SUM(length(CAST(prepared_packet_json AS BLOB))),0) FROM native_source_requests")
                    <= 67_108_864 - prepared.canonicalPacketJSON.count,
                  try connection.scalarInt("SELECT COALESCE(SUM(length(CAST(prepared_packet_json AS BLOB))),0) FROM native_source_requests WHERE task_id=?",
                    bindings: [.text(claim.taskID.uuidString.lowercased())]) <= 4_194_304 - prepared.canonicalPacketJSON.count else {
                throw NativeTaskCapabilityError.capacityExceeded
            }
            try insertNativeSourceRequestUnlocked(id: identity.reservationID, key: identity.key, method: "session_handoff",
                argumentsSHA: JSONSupport.sha256Hex(identity.arguments), managerID: claim.managerInstanceID, attachment: a,
                policy: policySelection, deadline: claim.storageDeadline, chargedCalls: 0, prepared: prepared, connection: connection)
            guard try connection.execute("UPDATE native_source_provider_turns SET pressure_reservation_id=?,blocked_code='pressure_prepared',updated_at=? WHERE stage_id=? AND pressure_reservation_id IS NULL",
                bindings: [.text(identity.reservationID.uuidString.lowercased()),.text(ISO8601.string(from: clock.now())),
                    .text(claim.stageID.uuidString.lowercased())]) == 1 else { throw NativeSourceConversationError.conflict }
            return .commit(.init(reservationID: identity.reservationID, prepared: prepared, authorization: a.setup.record.authorization,
                automaticHandoffEnabled: policySelection.policy.automaticHandoffEnabled, dispositionSHA256: claim.dispositionSHA256))
        }
    }

    private func nativePressureAdmissionUnlocked(_ admission: NativeSourcePressureCommitAdmission,
        claim: NativeSourcePressureClaim, credential: NativeTaskCapabilityCredential,
        connection: ControlPlaneSQLiteConnection) throws -> (NativeSourceRow, Bool) {
        let (a, _, stage) = try nativePressureStateUnlocked(claim: claim, credential: credential, connection: connection)
        guard admission.dispositionSHA256 == claim.dispositionSHA256, admission.authorization == a.setup.record.authorization,
              stage.pressureReservationID == admission.reservationID, let stored = stage.budgetDisposition else {
            throw NativeSourceConversationError.conflict
        }
        let identity = try nativePressureSourceIdentity(claim, stored: stored)
        guard let row = try nativeSourceRowUnlocked(key: identity.key, connection: connection), row.id == admission.reservationID,
              row.id == identity.reservationID, row.taskID == claim.taskID, row.capabilityID == claim.capabilityID,
              row.epoch == claim.capabilityEpoch, row.chargedCalls == 0, row.deadline == claim.storageDeadline,
              row.method == "session_handoff", row.argumentsSHA == JSONSupport.sha256Hex(identity.arguments) else {
            throw NativeSourceConversationError.integrityFailure
        }
        let (prepared, automatic) = try nativePreparedCommitUnlocked(row, authorization: admission.authorization, connection: connection)
        guard prepared == admission.prepared else { throw NativeSourceConversationError.integrityFailure }
        // A recorded true-to-false delivery downgrade does not change prepared bytes.
        guard !automatic || admission.automaticHandoffEnabled else { throw NativeSourceConversationError.integrityFailure }
        return (row, automatic)
    }

    private func nativePressurePacketBounds(_ prepared: PreparedContinuitySourceCommit,
        authorization: ContinuityIngressAuthorization, policy: BudgetPolicySelection) throws {
        try ContinuityIngressAcceptanceReceipt.validatePolicy(policy, authorization: authorization)
        let payload: [String: Any] = ["ok":true,"found":true,"packet":try JSONSerialization.jsonObject(with: prepared.canonicalPacketJSON),
            "continuity_id":prepared.continuityID,"revision":Int64.max,"packet_sha256":prepared.packetSHA256]
        let bytes = try ForgeJSONCanonicalizationV1.data(from: ["ok":true,"is_error":false,"payload":payload])
        let tokens = try ContextBudgetMath.estimateTokens(serializedBytes: bytes.count, policy: ContextBudgetPolicy())
        guard bytes.count <= min(65_536, authorization.authorizationScope.maximumInlineOutputBytes, policy.policy.tools.maxResultBytes),
              tokens <= policy.policy.tools.maxRetainedResultTokens else { throw NativeSourceConversationError.budgetExceeded }
    }

    private func finishNativePressureCommitUnlocked(_ actual: ContinuityHandoffCommit,
        admission: NativeSourcePressureCommitAdmission, automatic: Bool, claim: NativeSourcePressureClaim,
        connection: ControlPlaneSQLiteConnection) throws -> ContinuityHandoffCommit {
        let bytes = try NativeSourceCommitEvidence.encode(actual)
        _ = try NativeSourceCommitEvidence.decode(bytes, prepared: admission.prepared, authorization: admission.authorization)
        guard !automatic || actual.delivery != nil else { throw NativeSourceConversationError.integrityFailure }
        // The external store has committed. Preserve its actual receipt even if the
        // request is cancelled or its lease expires while the source write finishes.
        connection.finishRequestCancellationWindow()
        guard try connection.execute("UPDATE native_source_requests SET state='completed',result_json=?,result_sha256=?,completed_at=?,retry_at=NULL,error_code=NULL WHERE reservation_id=? AND state='pending'",
            bindings: [.text(String(decoding: bytes, as: UTF8.self)),.text(JSONSupport.sha256Hex(bytes)),
                .text(ISO8601.string(from: clock.now())),.text(admission.reservationID.uuidString.lowercased())]) == 1 else {
            throw NativeSourceConversationError.conflict
        }
        guard try connection.execute("UPDATE native_source_provider_turns SET blocked_code='pressure_committed',updated_at=? WHERE stage_id=? AND pressure_reservation_id=?",
            bindings: [.text(ISO8601.string(from: clock.now())),.text(claim.stageID.uuidString.lowercased()),
                .text(admission.reservationID.uuidString.lowercased())]) == 1 else { throw NativeSourceConversationError.conflict }
        guard try connection.execute("UPDATE native_source_conversations SET state='source_fenced',revision=revision+1,updated_at=? WHERE conversation_id=? AND active_stage_id=? AND state='stopped' AND revision=? AND revision<?",
            bindings: [.text(ISO8601.string(from: clock.now())),.text(claim.conversationID.uuidString.lowercased()),
                .text(claim.stageID.uuidString.lowercased()),.int64(claim.fenceRevision),.int64(Int64.max)]) == 1 else {
            throw NativeSourceConversationError.conflict
        }
        return actual
    }

    func beginNativeSourcePressureCommitAttempt(admission: NativeSourcePressureCommitAdmission,
        claim: NativeSourcePressureClaim, credential: NativeTaskCapabilityCredential, policySelection: BudgetPolicySelection,
        readExisting: @Sendable (PreparedContinuitySourceCommit, ContinuityIngressAuthorization) throws -> ContinuityHandoffCommit?,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourcePressureAttemptResult {
        try controlledTransaction(cancellation: cancellation, fullDurability: true, beforeCommitValidation: {
            _ = try self.nativePressureStateUnlocked(claim: claim, credential: credential, connection: self.requiredConnection())
        }) { connection in
            let (row, automatic) = try nativePressureAdmissionUnlocked(admission, claim: claim, credential: credential, connection: connection)
            if row.state == "completed" { return .completed(try nativeCommitResultUnlocked(row, prepared: admission.prepared,
                authorization: admission.authorization, connection: connection)) }
            guard row.state == "pending" else { throw NativeSourceConversationError.conflict }
            if let actual = try readExisting(admission.prepared, admission.authorization) {
                return .completed(try finishNativePressureCommitUnlocked(actual, admission: admission, automatic: automatic,
                    claim: claim, connection: connection))
            }
            try nativePressurePacketBounds(admission.prepared, authorization: admission.authorization, policy: policySelection)
            let attempts = try connection.scalarInt("SELECT recovery_attempts FROM native_source_requests WHERE reservation_id=?",
                bindings: [.text(row.id.uuidString.lowercased())])
            guard attempts < 8 else { throw NativeSourceConversationError.capacityExceeded }
            let delivery = automatic && policySelection.policy.automaticHandoffEnabled
            if automatic && !delivery {
                let policy = try ForgeJSONCanonicalizationV1.data(from: JSONSerialization.jsonObject(with: JSONEncoder().encode(policySelection)))
                try connection.execute("UPDATE native_source_requests SET automatic_enabled=0,policy_json=? WHERE reservation_id=?",
                    bindings: [.text(String(decoding: policy, as: UTF8.self)),.text(row.id.uuidString.lowercased())])
            }
            try connection.execute("UPDATE native_source_requests SET recovery_attempts=recovery_attempts+1,error_code='pressure_attempt_prepared' WHERE reservation_id=?",
                bindings: [.text(row.id.uuidString.lowercased())])
            return .commit(.init(admission: admission, number: Int64(attempts + 1), managerID: claim.managerInstanceID,
                leaseEpoch: claim.leaseEpoch, automatic: delivery))
        }
    }

    func commitNativeSourceBudgetHandoff(attempt: NativeSourcePressureCommitAttempt, claim: NativeSourcePressureClaim,
        credential: NativeTaskCapabilityCredential, policySelection: BudgetPolicySelection,
        readExisting: @Sendable (PreparedContinuitySourceCommit, ContinuityIngressAuthorization) throws -> ContinuityHandoffCommit?,
        commit: @Sendable (PreparedContinuitySourceCommit, ContinuityIngressAuthorization, Bool) throws -> ContinuityHandoffCommit,
        cancellation: ToolCallCancellation? = nil) throws -> ContinuityHandoffCommit {
        let mayWrite = try controlledTransaction(cancellation: cancellation, fullDurability: true, beforeCommitValidation: {
            _ = try self.nativePressureStateUnlocked(claim: claim, credential: credential, connection: self.requiredConnection())
        }) { connection in
            guard attempt.managerID == claim.managerInstanceID, attempt.leaseEpoch == claim.leaseEpoch else {
                throw NativeSourceConversationError.leaseUnavailable
            }
            let (row, automatic) = try nativePressureAdmissionUnlocked(attempt.admission, claim: claim,
                credential: credential, connection: connection)
            if row.state == "completed" { return false }
            guard row.state == "pending", automatic == attempt.automatic,
                  try connection.scalarInt("SELECT recovery_attempts FROM native_source_requests WHERE reservation_id=?",
                    bindings: [.text(row.id.uuidString.lowercased())]) == Int(attempt.number) else { throw NativeSourceConversationError.conflict }
            // Consume the attempt durably before any possible source effect. A
            // restarted or repeated call can read a receipt but needs a new
            // bounded attempt before it may invoke the writer again.
            return try connection.execute("UPDATE native_source_requests SET error_code='pressure_attempt_started' WHERE reservation_id=? AND error_code='pressure_attempt_prepared'",
                bindings: [.text(row.id.uuidString.lowercased())]) == 1
        }
        return         try controlledTransaction(cancellation: cancellation, checkCancellationBeforeCommit: false, fullDurability: true) { connection in
            guard attempt.managerID == claim.managerInstanceID, attempt.leaseEpoch == claim.leaseEpoch else {
                throw NativeSourceConversationError.leaseUnavailable
            }
            let admission = attempt.admission
            let (row, automatic) = try nativePressureAdmissionUnlocked(admission, claim: claim, credential: credential, connection: connection)
            if row.state == "completed" { return try nativeCommitResultUnlocked(row, prepared: admission.prepared,
                authorization: admission.authorization, connection: connection) }
            guard row.state == "pending", automatic == attempt.automatic,
                  try connection.scalarInt("SELECT recovery_attempts FROM native_source_requests WHERE reservation_id=?",
                    bindings: [.text(row.id.uuidString.lowercased())]) == Int(attempt.number) else { throw NativeSourceConversationError.conflict }
            if let actual = try readExisting(admission.prepared, admission.authorization) {
                return try finishNativePressureCommitUnlocked(actual, admission: admission, automatic: automatic,
                    claim: claim, connection: connection)
            }
            guard mayWrite else { throw NativeSourceConversationError.conflict }
            try nativePressurePacketBounds(admission.prepared, authorization: admission.authorization, policy: policySelection)
            // A newly tightened opt-out requires a new durable attempt; never
            // rewrite delivery policy after a possibly committed source revision.
            guard !automatic || policySelection.policy.automaticHandoffEnabled else { throw NativeSourceConversationError.conflict }
            _ = try nativePressureStateUnlocked(claim: claim, credential: credential, connection: connection)
            guard claim.fenceRevision < Int64.max,
                  try connection.scalarInt("SELECT COUNT(*) FROM continuity_source_task_fences WHERE task_id=?",
                    bindings: [.text(claim.taskID.uuidString.lowercased())]) == 0 else { throw NativeSourceConversationError.sourceFenced }
            try cancellation?.checkCancellation()
            let actual = try commit(admission.prepared, admission.authorization, automatic)
            return try finishNativePressureCommitUnlocked(actual, admission: admission, automatic: automatic,
                claim: claim, connection: connection)
        }
    }

    private struct NativePressureReceiptState {
        let conversation: NativeSourceConversationRow
        let stage: NativeSourceStageRow
        let row: NativeSourceRow
        let prepared: PreparedContinuitySourceCommit
        let authorization: ContinuityIngressAuthorization
        let automatic: Bool
        let dispositionSHA256: String
        let executionEnded: Bool
    }

    private func nativePressureReceiptStateUnlocked(_ reference: NativeSourcePressureRecoveryReference,
        connection: ControlPlaneSQLiteConnection) throws -> NativePressureReceiptState {
        // Prove the retained metadata tuple and original dispatch lineage before
        // decoding the assignment, conversation, or prepared source packet.
        guard let capability = try nativeCapabilityUnlocked(reference.capabilityID, connection: connection),
              capability.taskID == reference.taskID,
              try connection.scalarInt("""
                SELECT COUNT(*) FROM native_source_provider_turns t
                JOIN native_source_conversations c ON c.conversation_id=t.conversation_id
                JOIN native_source_requests r ON r.reservation_id=t.pressure_reservation_id
                JOIN continuity_task_authorizations a ON a.task_id=c.task_id
                WHERE c.conversation_id=? AND t.stage_id=? AND c.task_id=? AND c.capability_id=?
                    AND c.active_stage_id=t.stage_id AND t.pressure_reservation_id=?
                    AND t.task_id=c.task_id AND r.task_id=c.task_id AND r.capability_id=c.capability_id
                    AND r.method='session_handoff' AND r.charged_calls=0
                    AND c.project_id=? AND c.project_generation=? AND a.project_id=c.project_id
                    AND a.project_generation=c.project_generation AND a.source_binding_id=?
                    AND a.assignment_sha256=? AND a.authorization_sha256=?
                """, bindings: [.text(reference.conversationID.uuidString.lowercased()),.text(reference.stageID.uuidString.lowercased()),
                    .text(reference.taskID.uuidString.lowercased()),.text(reference.capabilityID.uuidString.lowercased()),
                    .text(reference.reservationID.uuidString.lowercased()),.text(capability.projectID.description),
                    .int64(Int64(capability.generation.rawValue)),.text(capability.sourceBindingID.uuidString.lowercased()),
                    .text(capability.approvalSHA256),.text(capability.authorizationSHA256)]) == 1,
              let originInvalidated = try connection.first("""
                SELECT o.invalidated FROM continuity_source_dispatch_origins o
                JOIN project_bindings b ON b.binding_id=o.caller_binding_id
                WHERE o.task_id=? AND o.caller_binding_id=? AND o.owner_kind='mcp_client' AND o.scope_sha256=?
                    AND b.owner_kind=o.owner_kind AND b.owner_id=o.owner_id
                """, bindings: [.text(reference.taskID.uuidString.lowercased()),.text(capability.callerBindingID.uuidString.lowercased()),
                    .text(capability.scopeSHA256)], map: { $0.int64(0) }),
              let task = try continuityTaskUnlocked(reference.taskID, connection: connection),
              task.assignment.documentSHA256 == capability.documentSHA256 else { throw NativeSourceConversationError.notFound }
        let c = try decodeNativeConversationUnlocked(reference.conversationID, expected: capability.descriptor(now: clock.now()),
            assignmentSHA256: capability.approvalSHA256, authorizationSHA256: capability.authorizationSHA256, connection: connection)
        let stage = try nativeStageUnlocked(reference.stageID, conversation: c, connection: connection)
        guard c.active == reference.stageID, [.stopped, .sourceFenced].contains(c.state),
              let stored = stage.budgetDisposition, case .pressure = stored.metadata,
              stage.pressureReservationID == reference.reservationID, stage.body.epoch <= capability.epoch else {
            throw NativeSourceConversationError.integrityFailure
        }
        let dispositionSHA = JSONSupport.sha256Hex(try NativeSourceJournalCoding.encode(stored, maximum: NativeSourceBudgetMetadata.maximumStoredBytes))
        let identity = try nativePressureSourceIdentity(taskID: reference.taskID, capabilityID: reference.capabilityID,
            conversationID: reference.conversationID, stageID: reference.stageID, dispositionSHA256: dispositionSHA, stored: stored)
        guard identity.reservationID == reference.reservationID,
              let row = try nativeSourceRowUnlocked(key: identity.key, connection: connection), row.id == reference.reservationID,
              row.epoch == stage.body.epoch, row.argumentsSHA == JSONSupport.sha256Hex(identity.arguments),
              row.deadline == stored.storageDeadline, ["pending", "completed"].contains(row.state) else {
            throw NativeSourceConversationError.integrityFailure
        }
        let (prepared, automatic) = try nativePreparedCommitUnlocked(row, authorization: task.authorization, connection: connection)
        guard prepared.continuityID == identity.continuityID else { throw NativeSourceConversationError.integrityFailure }
        let now = ISO8601.string(from: clock.now())
        return .init(conversation: c, stage: stage, row: row, prepared: prepared, authorization: task.authorization,
            automatic: automatic, dispositionSHA256: dispositionSHA,
            executionEnded: c.cancelled || task.state == .revoked || originInvalidated != 0 || capability.state == "revoked"
                || capability.epoch != row.epoch || capability.expiresAt <= now || row.deadline <= now)
    }

    func pendingNativeSourcePressureReceipts(limit: Int = 16,
        cancellation: ToolCallCancellation? = nil) throws -> [NativeSourcePressureRecoveryReference] {
        guard (1...32).contains(limit) else { throw NativeSourceConversationError.invalidRequest("limit") }
        return try controlledTransaction(cancellation: cancellation) { connection in
            let now = ISO8601.string(from: clock.now())
            return try connection.all("""
                SELECT c.conversation_id,t.stage_id,c.task_id,c.capability_id,r.reservation_id
                FROM native_source_provider_turns t JOIN native_source_conversations c ON c.conversation_id=t.conversation_id
                JOIN native_source_requests r ON r.reservation_id=t.pressure_reservation_id
                JOIN native_task_capabilities k ON k.capability_id=c.capability_id
                JOIN continuity_task_authorizations a ON a.task_id=c.task_id
                JOIN continuity_source_dispatch_origins o ON o.task_id=c.task_id
                WHERE r.state='pending' AND r.quarantined=0 AND c.active_stage_id=t.stage_id
                    AND (c.lease_owner IS NULL OR c.lease_expires_at<=?)
                    AND (r.deadline<=? OR k.expires_at<=? OR k.state='revoked' OR k.epoch!=r.epoch
                         OR c.cancelled=1 OR a.state='revoked' OR o.invalidated=1)
                ORDER BY t.rowid LIMIT ?
                """, bindings: [.text(now),.text(now),.text(now),.int64(Int64(limit))]) {
                    .init(conversationID: try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36)),
                        stageID: try NativeTaskValue.uuid($0.strictText(1, maximumBytes: 36)),
                        taskID: try NativeTaskValue.uuid($0.strictText(2, maximumBytes: 36)),
                        capabilityID: try NativeTaskValue.uuid($0.strictText(3, maximumBytes: 36)),
                        reservationID: try NativeTaskValue.uuid($0.strictText(4, maximumBytes: 36)))
                }
        }
    }

    private func validateNativePressureReceiptClaimUnlocked(_ claim: NativeSourcePressureReceiptClaim,
        connection: ControlPlaneSQLiteConnection) throws -> NativePressureReceiptState {
        let state = try nativePressureReceiptStateUnlocked(claim.reference, connection: connection)
        let c = state.conversation, now = ISO8601.string(from: clock.now())
        guard c.owner == claim.managerID, c.leaseEpoch == claim.leaseEpoch, c.leaseExpires == claim.expiresAt,
              claim.expiresAt > now, state.dispositionSHA256 == claim.dispositionSHA256,
              state.prepared.packetSHA256 == claim.packetSHA256 else { throw NativeSourceConversationError.leaseUnavailable }
        return state
    }

    func acquireNativeSourcePressureReceiptClaim(reference: NativeSourcePressureRecoveryReference,
        managerInstanceID: UUID, cancellation: ToolCallCancellation? = nil) throws -> NativeSourcePressureReceiptClaim {
        let expiresAt = ISO8601.string(from: clock.now().addingTimeInterval(30))
        return try controlledTransaction(cancellation: cancellation, fullDurability: true, beforeCommitValidation: {
            let state = try self.nativePressureReceiptStateUnlocked(reference, connection: self.requiredConnection())
            guard state.conversation.owner == managerInstanceID, state.conversation.leaseExpires == expiresAt,
                  expiresAt > ISO8601.string(from: self.clock.now()) else { throw NativeSourceConversationError.leaseUnavailable }
        }) { connection in
            let state = try nativePressureReceiptStateUnlocked(reference, connection: connection)
            let c = state.conversation, now = ISO8601.string(from: clock.now())
            guard state.executionEnded || state.row.state == "completed" else { throw NativeSourceConversationError.conflict }
            guard c.owner == nil || (c.leaseExpires ?? "") <= now else { throw NativeSourceConversationError.leaseUnavailable }
            guard c.leaseEpoch < Int64.max else { throw NativeSourceConversationError.capacityExceeded }
            guard try state.row.state == "completed" || (connection.scalarInt("SELECT quarantined FROM native_source_requests WHERE reservation_id=?",
                bindings: [.text(reference.reservationID.uuidString.lowercased())])) == 0 else { throw NativeSourceConversationError.conflict }
            try connection.execute("UPDATE native_source_conversations SET lease_owner=?,lease_epoch=lease_epoch+1,lease_capability_epoch=NULL,lease_expires_at=? WHERE conversation_id=?",
                bindings: [.text(managerInstanceID.uuidString.lowercased()),.text(expiresAt),.text(reference.conversationID.uuidString.lowercased())])
            return .init(reference: reference, managerID: managerInstanceID, leaseEpoch: c.leaseEpoch + 1,
                expiresAt: expiresAt, dispositionSHA256: state.dispositionSHA256, packetSHA256: state.prepared.packetSHA256)
        }
    }

    func reconcileNativeSourcePressureReceipt(claim: NativeSourcePressureReceiptClaim,
        readExisting: @Sendable (PreparedContinuitySourceCommit, ContinuityIngressAuthorization) throws -> ContinuityHandoffCommit?,
        cancellation: ToolCallCancellation? = nil) throws -> ContinuityHandoffCommit? {
        try controlledTransaction(cancellation: cancellation, fullDurability: true, beforeCommitValidation: {
            _ = try self.validateNativePressureReceiptClaimUnlocked(claim, connection: self.requiredConnection())
        }) { connection in
            let state = try validateNativePressureReceiptClaimUnlocked(claim, connection: connection)
            if state.row.state == "completed" { return try nativeCommitResultUnlocked(state.row, prepared: state.prepared,
                authorization: state.authorization, connection: connection) }
            guard let actual = try readExisting(state.prepared, state.authorization) else {
                try connection.execute("UPDATE native_source_requests SET quarantined=1,error_code='pressure_receipt_absent' WHERE reservation_id=? AND state='pending'",
                    bindings: [.text(state.row.id.uuidString.lowercased())])
                return nil
            }
            let bytes = try NativeSourceCommitEvidence.encode(actual)
            _ = try NativeSourceCommitEvidence.decode(bytes, prepared: state.prepared, authorization: state.authorization)
            guard !state.automatic || actual.delivery != nil else { throw NativeSourceConversationError.integrityFailure }
            guard try connection.execute("UPDATE native_source_requests SET state='completed',result_json=?,result_sha256=?,completed_at=?,retry_at=NULL,error_code=NULL WHERE reservation_id=? AND state='pending'",
                bindings: [.text(String(decoding: bytes, as: UTF8.self)),.text(JSONSupport.sha256Hex(bytes)),
                    .text(ISO8601.string(from: clock.now())),.text(state.row.id.uuidString.lowercased())]) == 1 else {
                throw NativeSourceConversationError.conflict
            }
            // Audit persistence cannot clear cancellation, restore a capability,
            // extend the original storage window, or reactivate the conversation.
            try connection.execute("UPDATE native_source_provider_turns SET blocked_code='pressure_receipt_recorded',updated_at=? WHERE stage_id=? AND pressure_reservation_id=?",
                bindings: [.text(ISO8601.string(from: clock.now())),.text(claim.reference.stageID.uuidString.lowercased()),
                    .text(state.row.id.uuidString.lowercased())])
            return actual
        }
    }

    func releaseNativeSourcePressureReceiptClaim(_ claim: NativeSourcePressureReceiptClaim) throws -> Bool {
        try controlledTransaction(cancellation: nil, fullDurability: true) { connection in
            try connection.execute("UPDATE native_source_conversations SET lease_owner=NULL,lease_expires_at=NULL WHERE conversation_id=? AND lease_owner=? AND lease_epoch=? AND lease_capability_epoch IS NULL",
                bindings: [.text(claim.reference.conversationID.uuidString.lowercased()),.text(claim.managerID.uuidString.lowercased()),
                    .int64(claim.leaseEpoch)]) == 1
        }
    }

    func nativeSourceBudgetBinding(stageID: UUID, boundary: NativeSourceBudgetBoundary,
        pendingCallOrdinal: Int? = nil, credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceBudgetBinding {
        try controlledTransaction(cancellation: cancellation) { connection in
            let (attachment, conversation) = try nativeLeaseUnlocked(lease, credential: credential, connection: connection)
            try requireSourceMutationAdmissionUnlocked(attachment.setup.record.authorization, connection: connection)
            let stage = try nativeStageUnlocked(stageID, conversation: conversation, connection: connection)
            guard stage.body.epoch == credential.epoch else { throw NativeSourceConversationError.conflict }
            return try nativeBudgetBindingUnlocked(stage: stage, conversation: conversation, boundary: boundary,
                pendingCallOrdinal: pendingCallOrdinal, connection: connection)
        }
    }

    func nativeSourceAcceptedBudgetContext(stageID: UUID, credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, cancellation: ToolCallCancellation? = nil) throws -> NativeSourceAcceptedBudgetContext {
        try controlledTransaction(cancellation: cancellation) { connection in
            let (attachment, conversation) = try nativeLeaseUnlocked(lease, credential: credential, connection: connection)
            try requireSourceMutationAdmissionUnlocked(attachment.setup.record.authorization, connection: connection)
            let stage = try nativeStageUnlocked(stageID, conversation: conversation, connection: connection)
            guard stage.body.epoch == credential.epoch else { throw NativeSourceConversationError.conflict }
            let binding = try nativeBudgetBindingUnlocked(stage: stage, conversation: conversation,
                boundary: .acceptedProviderResponse, pendingCallOrdinal: nil, connection: connection)
            let accepted = try nativeAcceptedUnlocked(stage, conversation: conversation, connection: connection)
            guard let post = stage.post else { throw NativeSourceConversationError.integrityFailure }
            let bytes = try Self.nativeSourceCheckedAdd(accepted.prepared.priorContextSerializedBytes,
                Self.nativeSourceCheckedAdd(post.preflight.bytes, Self.nativeRetainedProviderResponseBytes(accepted.turn)))
            return .init(binding: binding, accepted: accepted, retainedContextSerializedBytes: bytes)
        }
    }

    func nativeSourcePreparedTurn(stageID: UUID, credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourcePreparedTurn {
        try controlledTransaction(cancellation: cancellation) { connection in
            let (_, c) = try nativeLeaseUnlocked(lease, credential: credential, allowFenced: true, connection: connection)
            return try nativePrepared(nativeStageUnlocked(stageID, conversation: c, connection: connection), conversation: c, connection: connection)
        }
    }
    func nativeSourceRequest(taskID: UUID, requestID: UUID, expectedUserInput: String? = nil, credential: NativeTaskCapabilityCredential,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourcePreparedTurn? {
        try controlledTransaction(cancellation: cancellation) { connection in
            let a = try authenticateNativeTaskCapabilityUnlocked(credential, connection: connection)
            guard a.descriptor.taskID == taskID else { throw NativeSourceConversationError.notFound }
            guard let ids = try connection.first("SELECT conversation_id,stage_id FROM native_source_provider_turns WHERE task_id=? AND request_id=? ORDER BY ordinal DESC LIMIT 1",
                bindings: [.text(taskID.uuidString.lowercased()),.text(requestID.uuidString.lowercased())], map: {
                    (try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36)), try NativeTaskValue.uuid($0.strictText(1, maximumBytes: 36)))
                }) else { return nil }
            let c = try nativeConversationUnlocked(ids.0, attachment: a, connection: connection)
            let stage = try nativeStageUnlocked(ids.1, conversation: c, connection: connection)
            if let expectedUserInput {
                guard expectedUserInput.utf8.count <= 16_384, stage.body.logicalInputSHA == JSONSupport.sha256Hex(Data(expectedUserInput.utf8)) else { throw NativeSourceConversationError.conflict }
            }
            return try nativePrepared(stage, conversation: c, connection: connection)
        }
    }
    private func nativeVerifyPreflight(_ p: ProviderRequestPreflight, stage: NativeSourceStageRow,
        conversation: NativeSourceConversationRow) throws {
        let kind: ProviderRequestPreflight.Kind = stage.body.kind == "root" ? .root : .continuation
        guard p.kind == kind, p.modelKey == stage.body.modelKey,
              p.limits.maximumRequestBytes <= 524_288, p.limits.maximumResponseBytes <= 2_097_152,
              p.bodyByteCount <= p.limits.maximumRequestBytes,
              conversation.configurationSHA.map({ $0 == p.configurationFingerprintSHA256 }) ?? true else {
            throw NativeSourceConversationError.conflict
        }
    }
    func reserveNativeSourceCapabilityCheck(prepared: NativeSourcePreparedTurn, preflight: ProviderRequestPreflight,
        credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceCapabilityCheckClaim {
        try controlledTransaction(cancellation: cancellation, fullDurability: true, beforeCommitValidation: {
            let connection = try self.requiredConnection()
            let (attachment, conversation) = try self.nativeLeaseUnlocked(lease, credential: credential, connection: connection)
            try self.requireSourceMutationAdmissionUnlocked(attachment.setup.record.authorization, connection: connection)
            let stage = try self.nativeStageUnlocked(prepared.stageID, conversation: conversation, connection: connection)
            guard conversation.state == .active, conversation.active == stage.body.stageID,
                  stage.state == .prepared, stage.blocked == nil, stage.digest == prepared.intentSHA256,
                  stage.body.epoch == credential.epoch, stage.body.deadline > ISO8601.string(from: self.clock.now()) else {
                throw NativeSourceConversationError.conflict
            }
        }) { connection in
            let (a, c) = try nativeLeaseUnlocked(lease, credential: credential, connection: connection)
            try requireSourceMutationAdmissionUnlocked(a.setup.record.authorization, connection: connection)
            let stage = try nativeStageUnlocked(prepared.stageID, conversation: c, connection: connection)
            guard stage.digest == prepared.intentSHA256, stage.state == .prepared, stage.body.epoch == credential.epoch,
                  stage.body.deadline > ISO8601.string(from: clock.now()), c.active == stage.body.stageID else { throw NativeSourceConversationError.conflict }
            try nativeVerifyPreflight(preflight, stage: stage, conversation: c)
            let cid = c.body.conversationID.uuidString.lowercased(), rid = stage.body.requestID.uuidString.lowercased()
            guard try connection.scalarInt("SELECT COUNT(*) FROM native_source_capability_checks WHERE conversation_id=? AND state='attempted'", bindings: [.text(cid)]) == 0,
                  try connection.scalarInt("SELECT COUNT(*) FROM native_source_capability_checks WHERE conversation_id=?", bindings: [.text(cid)]) < 64,
                  try connection.scalarInt("SELECT COUNT(*) FROM native_source_capability_checks WHERE conversation_id=? AND request_id=?", bindings: [.text(cid),.text(rid)]) < 3,
                  try connection.scalarInt("SELECT (SELECT COUNT(*) FROM native_source_capability_checks WHERE conversation_id=? AND request_id=?)+(SELECT COUNT(*) FROM native_source_provider_turns WHERE conversation_id=? AND request_id=?)",
                    bindings: [.text(cid),.text(rid),.text(cid),.text(rid)]) < 8 else { throw NativeSourceConversationError.capacityExceeded }
            let id = UUID(), nonce = UUID(), bytes = try NativeSourceJournalCoding.encode(NativeSourceStoredPreflight(preflight), maximum: 8_192)
            try connection.execute("""
                INSERT INTO native_source_capability_checks(check_id,conversation_id,stage_id,request_id,state,nonce,lease_owner,lease_epoch,
                    preflight_json,preflight_sha256,attempted_at) VALUES(?,?,?,?,'attempted',?,?,?,?,?,?)
                """, bindings: [.text(id.uuidString.lowercased()),.text(cid),.text(stage.body.stageID.uuidString.lowercased()),.text(rid),
                    .text(nonce.uuidString.lowercased()),.text(lease.managerInstanceID.uuidString.lowercased()),.int64(lease.leaseEpoch),
                    .text(String(decoding: bytes, as: UTF8.self)),.text(JSONSupport.sha256Hex(bytes)),.text(ISO8601.string(from: clock.now()))])
            return .init(checkID: id, conversationID: c.body.conversationID, stageID: stage.body.stageID, nonce: nonce,
                owner: lease.managerInstanceID, epoch: lease.leaseEpoch)
        }
    }
    func finishNativeSourceCapabilityCheck(claim: NativeSourceCapabilityCheckClaim, capabilities: ProviderCapabilities?,
        outcome: NativeSourceCapabilityCheckOutcome, credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, cancellation: ToolCallCancellation? = nil) throws {
        if case .unknown = outcome {
            _ = try controlledTransaction(cancellation: nil, fullDurability: true) { connection in
                try connection.execute("""
                    UPDATE native_source_capability_checks SET state='unknown',completed_at=?
                    WHERE check_id=? AND conversation_id=? AND stage_id=? AND nonce=? AND lease_owner=? AND lease_epoch=? AND state='attempted'
                    """, bindings: [.text(ISO8601.string(from: clock.now())),.text(claim.checkID.uuidString.lowercased()),
                        .text(claim.conversationID.uuidString.lowercased()),.text(claim.stageID.uuidString.lowercased()),
                        .text(claim.nonce.uuidString.lowercased()),.text(claim.owner.uuidString.lowercased()),.int64(claim.epoch)])
            }
            return
        }
        _ = try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let (_, c) = try nativeLeaseUnlocked(lease, credential: credential, connection: connection)
            guard claim.conversationID == c.body.conversationID, claim.owner == lease.managerInstanceID, claim.epoch == lease.leaseEpoch else {
                throw NativeSourceConversationError.conflict
            }
            let stage = try nativeStageUnlocked(claim.stageID, conversation: c, connection: connection)
            let bytes: Data?
            switch outcome {
            case .completed:
                guard let capabilities, capabilities.providerID == c.body.providerID, capabilities.modelKey == c.body.modelKey,
                      capabilities.contextLength > 0, capabilities.customTools, capabilities.statefulResponses else {
                    throw NativeSourceConversationError.unsupportedProvider
                }
                bytes = try NativeSourceJournalCoding.encode(capabilities, maximum: 8_192)
            case .unknown: bytes = nil
            }
            guard stage.state == .prepared else { throw NativeSourceConversationError.conflict }
            return try connection.execute("""
                UPDATE native_source_capability_checks SET state=?,capabilities_json=?,capabilities_sha256=?,completed_at=?
                WHERE check_id=? AND nonce=? AND lease_owner=? AND lease_epoch=? AND state='attempted'
                """, bindings: [.text(bytes == nil ? "unknown" : "completed"), .optionalText(bytes.map { String(decoding: $0, as: UTF8.self) }),
                    .optionalText(bytes.map { JSONSupport.sha256Hex($0) }),.text(ISO8601.string(from: clock.now())),
                    .text(claim.checkID.uuidString.lowercased()),.text(claim.nonce.uuidString.lowercased()),
                    .text(claim.owner.uuidString.lowercased()),.int64(claim.epoch)])
        }
    }

    private func nativeAcceptedUnlocked(_ stage: NativeSourceStageRow, conversation: NativeSourceConversationRow,
        connection: ControlPlaneSQLiteConnection) throws -> NativeSourceAcceptedProviderTurn {
        guard let turn = stage.accepted, stage.state == .accepted else { throw NativeSourceConversationError.conflict }
        guard stage.blocked == nil else { throw NativeSourceConversationError.budgetExceeded }
        let calls = try connection.all("SELECT ordinal,call_sha256 FROM native_source_provider_calls WHERE stage_id=? ORDER BY ordinal",
            bindings: [.text(stage.body.stageID.uuidString.lowercased())]) { row in
                NativeSourceProviderCallReference(conversationID: conversation.body.conversationID, stageID: stage.body.stageID,
                    ordinal: Int(row.int64(0)), checksum: try Self.nativeSourceText(row, 1, 64))
            }
        guard calls.count == turn.toolCalls.count, calls.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }) else {
            throw NativeSourceConversationError.integrityFailure
        }
        return .init(prepared: try nativePrepared(stage, conversation: conversation, connection: connection), turn: turn, calls: calls)
    }
    func nativeSourceRequestResult(taskID: UUID, requestID: UUID, credential: NativeTaskCapabilityCredential,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceAcceptedProviderTurn? {
        try controlledTransaction(cancellation: cancellation) { connection in
            let attachment = try authenticateNativeTaskCapabilityUnlocked(credential, connection: connection)
            guard attachment.descriptor.taskID == taskID else { throw NativeSourceConversationError.notFound }
            guard let ids = try connection.first("""
                SELECT conversation_id,stage_id FROM native_source_provider_turns WHERE task_id=? AND request_id=? ORDER BY rowid DESC LIMIT 1
                """, bindings: [.text(taskID.uuidString.lowercased()),.text(requestID.uuidString.lowercased())], map: {
                    (try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36)),try NativeTaskValue.uuid($0.strictText(1, maximumBytes: 36)))
                }) else { return nil }
            let c = try nativeConversationUnlocked(ids.0, attachment: attachment, connection: connection)
            let stage = try nativeStageUnlocked(ids.1, conversation: c, connection: connection)
            guard stage.state == .accepted else { return nil }
            if stage.blocked != nil, let turn = stage.accepted {
                return .init(prepared: try nativePrepared(stage, conversation: c, connection: connection), turn: turn, calls: [])
            }
            return try nativeAcceptedUnlocked(stage, conversation: c, connection: connection)
        }
    }
    func nativeSourceAcceptedProviderTurn(stageID: UUID, credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, cancellation: ToolCallCancellation? = nil) throws -> NativeSourceAcceptedProviderTurn? {
        try controlledTransaction(cancellation: cancellation) { connection in
            let (_, c) = try nativeLeaseUnlocked(lease, credential: credential, allowFenced: true, connection: connection)
            let stage = try nativeStageUnlocked(stageID, conversation: c, connection: connection)
            guard stage.state == .accepted else { return nil }
            return try nativeAcceptedUnlocked(stage, conversation: c, connection: connection)
        }
    }
    private func nativeTighteningCeilings(_ fresh: NativeSourceBudgetCeilings, prior: NativeSourceBudgetCeilings?) throws {
        _ = try fresh.validated()
        guard let prior else { return }
        guard fresh.effectiveContextTokens <= prior.effectiveContextTokens, fresh.maximumOutputTokens <= prior.maximumOutputTokens,
              fresh.checkpointRatio <= prior.checkpointRatio, fresh.rolloverRatio <= prior.rolloverRatio,
              fresh.emergencyRatio <= prior.emergencyRatio,
              fresh.tools.callsPerTurn <= prior.tools.callsPerTurn, fresh.tools.callsPerSession <= prior.tools.callsPerSession,
              fresh.tools.callsPerRun <= prior.tools.callsPerRun, fresh.tools.maxInFlight <= prior.tools.maxInFlight,
              fresh.tools.maxResultBytes <= prior.tools.maxResultBytes,
              fresh.tools.maxRetainedResultTokens <= prior.tools.maxRetainedResultTokens,
              fresh.tools.recoveryCallsPerRollover <= prior.tools.recoveryCallsPerRollover,
              fresh.reserves.outputTokens >= prior.reserves.outputTokens, fresh.reserves.schemaTokens >= prior.reserves.schemaTokens,
              fresh.reserves.handoffTokens >= prior.reserves.handoffTokens, fresh.reserves.recoveryTokens >= prior.reserves.recoveryTokens,
              fresh.reserves.futureToolTokens >= prior.reserves.futureToolTokens, fresh.reserves.safetyTokens >= prior.reserves.safetyTokens else {
            throw NativeSourceConversationError.budgetExceeded
        }
    }
    func beginNativeSourceProviderPost(prepared: NativeSourcePreparedTurn, preflight: ProviderRequestPreflight,
        capabilities: ProviderCapabilities, budget: NativeSourceProviderBudgetApproval, credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, cancellation: ToolCallCancellation? = nil) throws -> NativeSourceProviderPostAdmission {
        let nonce = UUID()
        return try controlledTransaction(cancellation: cancellation, fullDurability: true, beforeCommitValidation: {
            let connection = try self.requiredConnection()
            let (attachment, conversation) = try self.nativeLeaseUnlocked(lease, credential: credential, allowFenced: true, connection: connection)
            let stage = try self.nativeStageUnlocked(prepared.stageID, conversation: conversation, connection: connection)
            guard stage.dispatchNonce == nonce else { return }
            try self.requireSourceMutationAdmissionUnlocked(attachment.setup.record.authorization, connection: connection)
            guard conversation.state == .active, conversation.active == stage.body.stageID,
                  stage.state == .submitted, stage.blocked == nil, stage.digest == prepared.intentSHA256,
                  stage.dispatchOwner == lease.managerInstanceID, stage.dispatchEpoch == lease.leaseEpoch,
                  stage.body.epoch == credential.epoch, stage.body.deadline > ISO8601.string(from: self.clock.now()) else {
                throw NativeSourceConversationError.conflict
            }
        }) { connection in
            let (attachment, c) = try nativeLeaseUnlocked(lease, credential: credential, allowFenced: true, connection: connection)
            let stage = try nativeStageUnlocked(prepared.stageID, conversation: c, connection: connection)
            guard stage.digest == prepared.intentSHA256 else { throw NativeSourceConversationError.conflict }
            if stage.state == .accepted { return .accepted(try nativeAcceptedUnlocked(stage, conversation: c, connection: connection)) }
            if stage.state == .submitted { return .inProgress }
            if stage.state == .outcomeUnknown { return .outcomeUnknown }
            guard c.state == .active, c.active == stage.body.stageID, stage.state == .prepared, stage.blocked == nil,
                  stage.body.epoch == credential.epoch, stage.body.deadline > ISO8601.string(from: clock.now()) else {
                throw NativeSourceConversationError.conflict
            }
            try requireSourceMutationAdmissionUnlocked(attachment.setup.record.authorization, connection: connection)
            try ContinuityIngressAcceptanceReceipt.validatePolicy(budget.policySelection, authorization: attachment.setup.record.authorization)
            try nativeVerifyPreflight(preflight, stage: stage, conversation: c)
            guard budget.limits == preflight.limits, budget.action == .normal || budget.action == .checkpoint,
                  capabilities.providerID == c.body.providerID, capabilities.modelKey == c.body.modelKey,
                  capabilities.customTools, capabilities.statefulResponses,
                  capabilities.contextLength >= budget.effectiveContextTokens else { throw NativeSourceConversationError.budgetExceeded }
            // A local serialization receipt cannot substitute for an actual bounded capability observation.
            let observed = try nativePrepared(stage, conversation: c, connection: connection)
            guard observed.retainedCapabilities == capabilities,
                  observed.retainedPreflight?.configurationFingerprintSHA256 == preflight.configurationFingerprintSHA256 else {
                throw NativeSourceConversationError.unsupportedProvider
            }
            try nativeTighteningCeilings(budget.ceilings, prior: c.ceilings)
            let post = NativeSourceStoredPost(preflight: .init(preflight), capabilities: capabilities, policy: budget.policySelection,
                retainedInputTokens: budget.retainedInputTokens, futureReserveTokens: budget.futureReserveTokens,
                ceilings: budget.ceilings, accounting: budget.accounting, source: budget.source, confidence: budget.confidence, action: budget.action)
            let bytes = try NativeSourceJournalCoding.encode(post, maximum: 32_768)
            let ceilings = try NativeSourceJournalCoding.encode(budget.ceilings, maximum: 8_192)
            let timestamp = ISO8601.string(from: clock.now())
            guard try connection.execute("""
                UPDATE native_source_provider_turns SET state='submitted',post_json=?,post_sha256=?,dispatch_nonce=?,dispatch_owner=?,dispatch_epoch=?,updated_at=?
                WHERE stage_id=? AND state='prepared' AND blocked_code IS NULL
                """, bindings: [.text(String(decoding: bytes, as: UTF8.self)),.text(JSONSupport.sha256Hex(bytes)),
                    .text(nonce.uuidString.lowercased()),.text(lease.managerInstanceID.uuidString.lowercased()),.int64(lease.leaseEpoch),
                    .text(timestamp),.text(stage.body.stageID.uuidString.lowercased())]) == 1 else { throw NativeSourceConversationError.conflict }
            try connection.execute("""
                UPDATE native_source_conversations SET configuration_sha256=?,ceilings_json=?,ceilings_sha256=?,revision=revision+1,updated_at=? WHERE conversation_id=?
                """, bindings: [.text(preflight.configurationFingerprintSHA256),.text(String(decoding: ceilings, as: UTF8.self)),
                    .text(JSONSupport.sha256Hex(ceilings)),.text(timestamp),.text(c.body.conversationID.uuidString.lowercased())])
            let claim = NativeSourceProviderDispatchClaim(conversationID: c.body.conversationID, stageID: stage.body.stageID, nonce: nonce,
                owner: lease.managerInstanceID, epoch: lease.leaseEpoch, intentSHA: stage.digest)
            return .dispatch(claim)
        }
    }
    private func nativeCallBytes(stage: NativeSourceStageRow, turn: ProviderTurn, ordinal: Int) throws -> Data {
        let call = turn.toolCalls[ordinal]
        guard !call.callID.isEmpty, call.callID.utf8.count <= 512,
              !call.callID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ["fs_read","session_checkpoint","session_handoff"].contains(call.name),
              call.argumentsJSON.count <= (call.name == "fs_read" ? 16_384 : 262_144),
              let arguments = try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any] else {
            throw NativeSourceConversationError.invalidRequest("provider tool call")
        }
        let canonical = try ForgeJSONCanonicalizationV1.data(from: arguments)
        return try ForgeJSONCanonicalizationV1.data(from: ["conversation_id":stage.body.conversationID.uuidString.lowercased(),
            "stage_id":stage.body.stageID.uuidString.lowercased(),"ordinal":ordinal,"response_id":turn.responseID,
            "call_id":call.callID,"tool":call.name,"arguments_sha256":JSONSupport.sha256Hex(canonical)])
    }
    private func nativeAcceptTurnUnlocked(stage: NativeSourceStageRow, conversation c: NativeSourceConversationRow,
        turn supplied: ProviderTurn, connection: ControlPlaneSQLiteConnection) throws -> NativeSourceAcceptedProviderTurn? {
        let turn = try NativeSourceJournalCoding.turn(supplied)
        if let prior = stage.accepted {
            guard prior == turn else { throw NativeSourceConversationError.conflict }
            return try nativeAcceptedUnlocked(stage, conversation: c, connection: connection)
        }
        guard [.submitted,.outcomeUnknown].contains(stage.state), let post = stage.post,
              turn.requestID == stage.body.stageID.uuidString.lowercased(), turn.previousResponseID == stage.body.parentResponseID,
              turn.providerID == c.body.providerID, turn.modelKey == c.body.modelKey,
              turn.providerVersion == post.capabilities.providerVersion,
              turn.providerInstanceID == post.capabilities.providerInstanceID, turn.completed else {
            throw NativeSourceConversationError.conflict
        }
        let bytes = try NativeSourceJournalCoding.encode(turn, maximum: NativeSourceJournalCoding.maximumTurnBytes)
        var invalid = false
        var maps: [Data] = []
        let count = turn.toolCalls.count
        let ceilings = post.ceilings.tools
        let priorCalls = c.body.priorSourceReadCallsAtEnrollment + (try connection.scalarInt("SELECT COUNT(*) FROM native_source_provider_calls WHERE conversation_id=?",
            bindings: [.text(c.body.conversationID.uuidString.lowercased())]))
        if count > min(16, ceilings.callsPerTurn) || priorCalls > min(ceilings.callsPerRun, ceilings.callsPerSession, c.body.sourceLimits.maximumCalls) - count
            || Set(turn.toolCalls.map(\.callID)).count != count { invalid = true }
        if !invalid {
            do { maps = try turn.toolCalls.indices.map { try nativeCallBytes(stage: stage, turn: turn, ordinal: $0) } }
            catch { invalid = true }
        }
        let timestamp = ISO8601.string(from: clock.now())
        try connection.execute("""
            UPDATE native_source_provider_turns SET state='accepted',result_json=?,result_sha256=?,blocked_code=?,reserved_bytes=?,updated_at=? WHERE stage_id=?
            """, bindings: [.text(String(decoding: bytes, as: UTF8.self)),.text(JSONSupport.sha256Hex(bytes)),
                .optionalText(invalid ? "invalid_provider_calls" : nil),.int64(count == 0 || invalid ? 0 : 2_097_152),.text(timestamp),.text(stage.body.stageID.uuidString.lowercased())])
        if !invalid {
            for (ordinal, map) in maps.enumerated() {
                let call = turn.toolCalls[ordinal]
                let args = try ForgeJSONCanonicalizationV1.data(from: JSONSerialization.jsonObject(with: call.argumentsJSON))
                try connection.execute("""
                    INSERT INTO native_source_provider_calls(conversation_id,stage_id,ordinal,call_json,call_sha256,arguments_json,arguments_sha256)
                    VALUES(?,?,?,?,?,?,?)
                    """, bindings: [.text(c.body.conversationID.uuidString.lowercased()),.text(stage.body.stageID.uuidString.lowercased()),
                        .int64(Int64(ordinal)),.text(String(decoding: map, as: UTF8.self)),.text(JSONSupport.sha256Hex(map)),
                        .text(String(decoding: args, as: UTF8.self)),.text(JSONSupport.sha256Hex(args))])
            }
        }
        try connection.execute("""
            UPDATE native_source_conversations SET state=?,active_stage_id=?,parent_response_id=?,revision=revision+1,updated_at=? WHERE conversation_id=?
            """, bindings: [.text(invalid ? "stopped" : (count == 0 ? "idle" : "active")),
                .optionalText(count == 0 ? nil : stage.body.stageID.uuidString.lowercased()),.text(turn.responseID),.text(timestamp),
                .text(c.body.conversationID.uuidString.lowercased())])
        guard !invalid else { return nil } // The known provider result remains durable even when its batch is rejected.
        let updated = try nativeStageUnlocked(stage.body.stageID, conversation: c, connection: connection)
        return try nativeAcceptedUnlocked(updated, conversation: c, connection: connection)
    }
    func acceptNativeSourceProviderTurn(claim: NativeSourceProviderDispatchClaim, turn: ProviderTurn,
        credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceAcceptedProviderTurn {
        let result = try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let (_, c) = try nativeLeaseUnlocked(lease, credential: credential, connection: connection)
            let stage = try nativeStageUnlocked(claim.stageID, conversation: c, connection: connection)
            guard claim.conversationID == c.body.conversationID, claim.nonce == stage.dispatchNonce,
                  claim.owner == stage.dispatchOwner, claim.epoch == stage.dispatchEpoch, claim.intentSHA == stage.digest,
                  claim.owner == lease.managerInstanceID, claim.epoch == lease.leaseEpoch else { throw NativeSourceConversationError.conflict }
            return try nativeAcceptTurnUnlocked(stage: stage, conversation: c, turn: turn, connection: connection)
        }
        guard let result else { throw NativeSourceConversationError.invalidRequest("provider tool batch") }
        return result
    }
    func recoverNativeSourceAcceptedProviderTurn(stageID: UUID, recoveredTurn: ProviderTurn,
        credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceAcceptedProviderTurn {
        let result = try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let (_, c) = try nativeLeaseUnlocked(lease, credential: credential, connection: connection)
            let stage = try nativeStageUnlocked(stageID, conversation: c, connection: connection)
            return try nativeAcceptTurnUnlocked(stage: stage, conversation: c, turn: recoveredTurn, connection: connection)
        }
        guard let result else { throw NativeSourceConversationError.invalidRequest("provider tool batch") }
        return result
    }
    func recordNativeSourceProviderOutcome(claim: NativeSourceProviderDispatchClaim, outcome: NativeSourceProviderOutcome,
        cancellation: ToolCallCancellation? = nil) throws {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            // Factual late cleanup has no payload disclosure and never grants another POST.
            guard case .unknown = outcome else { throw NativeSourceConversationError.conflict }
            let changed = try connection.execute("""
                UPDATE native_source_provider_turns SET state='outcome_unknown',updated_at=?
                WHERE stage_id=? AND conversation_id=? AND dispatch_nonce=? AND dispatch_owner=? AND dispatch_epoch=? AND intent_sha256=? AND state='submitted'
                """, bindings: [.text(ISO8601.string(from: clock.now())),.text(claim.stageID.uuidString.lowercased()),
                    .text(claim.conversationID.uuidString.lowercased()),.text(claim.nonce.uuidString.lowercased()),
                    .text(claim.owner.uuidString.lowercased()),.int64(claim.epoch),.text(claim.intentSHA)])
            if changed == 1 {
                try connection.execute("UPDATE native_source_conversations SET state='reconciliation_required',revision=revision+1 WHERE conversation_id=? AND active_stage_id=?",
                    bindings: [.text(claim.conversationID.uuidString.lowercased()),.text(claim.stageID.uuidString.lowercased())])
            }
        }
    }
    func stopNativeSourcePreparedTurn(stageID: UUID, reasonCode: String, credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, cancellation: ToolCallCancellation? = nil) throws {
        guard !reasonCode.isEmpty, reasonCode.utf8.count <= 64,
              reasonCode.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
            throw NativeSourceConversationError.invalidRequest("reason code")
        }
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let (_, c) = try nativeLeaseUnlocked(lease, credential: credential, connection: connection)
            let stage = try nativeStageUnlocked(stageID, conversation: c, connection: connection)
            guard stage.state == .prepared || stage.state == .cancelledBeforeDispatch else { throw NativeSourceConversationError.conflict }
            try connection.execute("UPDATE native_source_provider_turns SET state='cancelled_before_dispatch',blocked_code=?,reserved_bytes=0,updated_at=? WHERE stage_id=? AND state='prepared'",
                bindings: [.text(reasonCode),.text(ISO8601.string(from: clock.now())),.text(stageID.uuidString.lowercased())])
            try connection.execute("UPDATE native_source_conversations SET state='stopped',revision=revision+1 WHERE conversation_id=? AND active_stage_id=?",
                bindings: [.text(c.body.conversationID.uuidString.lowercased()),.text(stageID.uuidString.lowercased())])
        }
    }

    private func nativeCallKey(conversation: NativeSourceConversationRow, turn: ProviderTurn, ordinal: Int) throws -> NativeSourceRequestKey {
        let domain = "forge.continuity.responses-source.v1\0" + conversation.body.capabilityID.uuidString.lowercased() + "\0" + conversation.body.conversationID.uuidString.lowercased()
        let hex = String(JSONSupport.sha256Hex(Data(domain.utf8)).prefix(32))
        let chars = Array(hex)
        let uuid = String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-" + String(chars[12..<16]) + "-" + String(chars[16..<20]) + "-" + String(chars[20..<32])
        let identity = try ForgeJSONCanonicalizationV1.data(from: ["kind":"responses_function_call_v1",
            "conversation_id":conversation.body.conversationID.uuidString.lowercased(),"response_id":turn.responseID,"call_id":turn.toolCalls[ordinal].callID])
        return try .init(sessionID: NativeTaskValue.uuid(uuid), requestIDSHA256: JSONSupport.sha256Hex(identity))
    }
    private func nativeOutputUnlocked(reference: NativeSourceProviderCallReference, stage: NativeSourceStageRow,
        conversation: NativeSourceConversationRow, connection: ControlPlaneSQLiteConnection) throws -> NativeSourceProviderCallOutput? {
        guard let turn = stage.accepted, turn.toolCalls.indices.contains(reference.ordinal) else { throw NativeSourceConversationError.conflict }
        return try connection.first("""
            SELECT reservation_id,output_json,output_sha256,payload_sha256,ready_handoff,completed_at,source_receipt_sha256
            FROM native_source_provider_calls WHERE stage_id=? AND ordinal=? AND output_json IS NOT NULL
            """, bindings: [.text(reference.stageID.uuidString.lowercased()),.int64(Int64(reference.ordinal))]) { r in
                let id = try NativeTaskValue.uuid(r.strictText(0, maximumBytes: 36))
                let bytes = Data(try Self.nativeSourceText(r, 1, 1_048_576).utf8)
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      Set(object.keys) == ["ok","is_error","payload"], let payload = object["payload"] as? [String: Any],
                      let ok = object["ok"] as? Bool, let error = object["is_error"] as? Bool, ok != error,
                      try ForgeJSONCanonicalizationV1.data(from: object) == bytes,
                      JSONSupport.sha256Hex(bytes) == (try r.strictText(2, maximumBytes: 64)) else { throw NativeSourceConversationError.integrityFailure }
                let payloadBytes = try ForgeJSONCanonicalizationV1.data(from: payload)
                guard JSONSupport.sha256Hex(payloadBytes) == (try r.strictText(3, maximumBytes: 64)),
                      let row = try nativeSourceRowUnlocked(key: nativeCallKey(conversation: conversation, turn: turn, ordinal: reference.ordinal), connection: connection),
                      row.id == id, row.state == "completed", row.taskID == conversation.body.taskID,
                      let receiptSHA = try connection.first("SELECT result_sha256 FROM native_source_requests WHERE reservation_id=?",
                        bindings: [.text(id.uuidString.lowercased())], map: { try $0.strictText(0, maximumBytes: 64) }),
                      receiptSHA == (try r.strictText(6, maximumBytes: 64)) else { throw NativeSourceConversationError.integrityFailure }
                let ready = r.int64(4) == 1
                guard !ready || turn.toolCalls[reference.ordinal].name == "session_handoff" else { throw NativeSourceConversationError.integrityFailure }
                return .init(reference: reference, responseID: turn.responseID, callID: turn.toolCalls[reference.ordinal].callID,
                    reservationID: id, canonicalToolResultJSON: bytes, canonicalPayloadJSON: payloadBytes,
                    resultSHA256: JSONSupport.sha256Hex(bytes), payloadSHA256: JSONSupport.sha256Hex(payloadBytes),
                    readyHandoffCommitted: ready, recordedAt: try NativeTaskValue.date(r.strictText(5, maximumBytes: 20)))
            }
    }
    private func nativePriorOutputs(stage: NativeSourceStageRow, conversation: NativeSourceConversationRow,
        before ordinal: Int, connection: ControlPlaneSQLiteConnection) throws -> Data {
        var outputs: [[String: Any]] = []
        for index in 0..<ordinal {
            guard let digest = try connection.first("SELECT call_sha256 FROM native_source_provider_calls WHERE stage_id=? AND ordinal=?",
                bindings: [.text(stage.body.stageID.uuidString.lowercased()),.int64(Int64(index))], map: { try $0.strictText(0, maximumBytes: 64) }) ?? nil,
                  let output = try nativeOutputUnlocked(reference: .init(conversationID: conversation.body.conversationID,
                    stageID: stage.body.stageID, ordinal: index, checksum: digest), stage: stage, conversation: conversation, connection: connection),
                  !output.readyHandoffCommitted else { throw NativeSourceConversationError.conflict }
            outputs.append(["type":"function_call_output","call_id":output.callID,"output":String(decoding: output.canonicalPayloadJSON, as: UTF8.self)])
        }
        return try ForgeJSONCanonicalizationV1.data(from: outputs)
    }
    private func nativeResolveCallUnlocked(reference: NativeSourceProviderCallReference, credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, connection: ControlPlaneSQLiteConnection) throws -> ResolvedNativeSourceProviderCall {
        let (attachment, c) = try nativeLeaseUnlocked(lease, credential: credential, allowFenced: true, connection: connection)
        guard c.body.conversationID == reference.conversationID else { throw NativeSourceConversationError.notFound }
        let stage = try nativeStageUnlocked(reference.stageID, conversation: c, connection: connection)
        guard let turn = stage.accepted, stage.blocked == nil, turn.toolCalls.indices.contains(reference.ordinal),
              reference.ordinal < 16, stage.post != nil else { throw NativeSourceConversationError.conflict }
        let map = try nativeCallBytes(stage: stage, turn: turn, ordinal: reference.ordinal)
        guard JSONSupport.sha256Hex(map) == reference.checksum,
              let stored = try connection.first("SELECT call_json,call_sha256,arguments_json,arguments_sha256 FROM native_source_provider_calls WHERE stage_id=? AND ordinal=?",
                bindings: [.text(reference.stageID.uuidString.lowercased()),.int64(Int64(reference.ordinal))], map: { r in
                    (try Self.nativeSourceText(r, 0, 8_192),try Self.nativeSourceText(r, 1, 64),
                     try Self.nativeSourceText(r, 2, 262_144),try Self.nativeSourceText(r, 3, 64))
                }), Data(stored.0.utf8) == map, stored.1 == reference.checksum else { throw NativeSourceConversationError.integrityFailure }
        let args = try ForgeJSONCanonicalizationV1.data(from: JSONSerialization.jsonObject(with: turn.toolCalls[reference.ordinal].argumentsJSON))
        guard args == Data(stored.2.utf8), JSONSupport.sha256Hex(args) == stored.3 else { throw NativeSourceConversationError.integrityFailure }
        let output = try nativeOutputUnlocked(reference: reference, stage: stage, conversation: c, connection: connection)
        if output == nil {
            guard c.state == .active, c.active == reference.stageID, stage.body.deadline > ISO8601.string(from: clock.now()),
                  stage.body.epoch == credential.epoch else { throw NativeSourceConversationError.sourceFenced }
        } else if c.state == .sourceFenced {
            guard output?.readyHandoffCommitted == true else { throw NativeSourceConversationError.sourceFenced }
        }
        let prior = try nativePriorOutputs(stage: stage, conversation: c, before: reference.ordinal, connection: connection)
        let prepared = try nativePrepared(stage, conversation: c, connection: connection)
        let responseBytes = try Self.nativeRetainedProviderResponseBytes(turn)
        guard let actualPost = stage.post else { throw NativeSourceConversationError.integrityFailure }
        let contextBytes = try Self.nativeSourceCheckedAdd(prepared.priorContextSerializedBytes,
            Self.nativeSourceCheckedAdd(actualPost.preflight.bytes, responseBytes))
        return .init(reference: reference, providerOperationID: stage.body.stageID, responseID: turn.responseID,
            callID: turn.toolCalls[reference.ordinal].callID, toolName: turn.toolCalls[reference.ordinal].name,
            canonicalArgumentsJSON: args, key: try nativeCallKey(conversation: c, turn: turn, ordinal: reference.ordinal),
            priorOutputsSHA256: JSONSupport.sha256Hex(prior), prepared: prepared, attachment: attachment,
            acceptedUsage: turn.usage, retainedContextSerializedBytes: contextBytes)
    }
    func resolveNativeSourceProviderCall(reference: NativeSourceProviderCallReference, credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, cancellation: ToolCallCancellation? = nil) throws -> ResolvedNativeSourceProviderCall {
        try controlledTransaction(cancellation: cancellation) { connection in
            try nativeResolveCallUnlocked(reference: reference, credential: credential, lease: lease, connection: connection)
        }
    }
    private func nativeCallPolicy(_ call: ResolvedNativeSourceProviderCall, policy: BudgetPolicySelection,
        connection: ControlPlaneSQLiteConnection) throws {
        try ContinuityIngressAcceptanceReceipt.validatePolicy(policy, authorization: call.attachment.setup.record.authorization)
        guard let frozen = call.prepared.frozenCeilings else { throw NativeSourceConversationError.integrityFailure }
        let conversation = try nativeConversationUnlocked(call.reference.conversationID,
            attachment: call.attachment, connection: connection)
        let priorReads = conversation.body.priorSourceReadCallsAtEnrollment
        guard (0...conversation.body.sourceLimits.maximumCalls).contains(priorReads) else {
            throw NativeSourceConversationError.integrityFailure
        }
        let stageCount = try connection.scalarInt("SELECT COUNT(*) FROM native_source_provider_calls WHERE stage_id=?",
            bindings: [.text(call.reference.stageID.uuidString.lowercased())])
        let providerCalls = try connection.scalarInt("SELECT COUNT(*) FROM native_source_provider_calls WHERE conversation_id=?",
            bindings: [.text(call.reference.conversationID.uuidString.lowercased())])
        // Later provider reads already belong to providerCalls; only the immutable enrollment baseline is additive.
        let total = try Self.nativeSourceCheckedAdd(priorReads, providerCalls)
        guard stageCount <= min(policy.policy.tools.callsPerTurn, frozen.tools.callsPerTurn),
              total <= min(policy.policy.tools.callsPerRun,policy.policy.tools.callsPerSession,frozen.tools.callsPerRun,
                frozen.tools.callsPerSession,conversation.body.sourceLimits.maximumCalls) else {
            throw NativeSourceConversationError.budgetExceeded
        }
    }
    private func nativeOutputBounds(_ bytes: Data, call: ResolvedNativeSourceProviderCall,
        policy: BudgetPolicySelection, budget: NativeSourceProviderOutputBudget?, ready: Bool) throws -> Data {
        guard let frozen = call.prepared.frozenCeilings,
              bytes.count <= (ready ? 1_048_576 : min(1_048_576,policy.policy.tools.maxResultBytes,frozen.tools.maxResultBytes,
                call.attachment.setup.record.authorization.authorizationScope.maximumInlineOutputBytes)),
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["ok","is_error","payload"], let payload = object["payload"] as? [String: Any],
              let ok = object["ok"] as? Bool, let error = object["is_error"] as? Bool, ok != error,
              try ForgeJSONCanonicalizationV1.data(from: object) == bytes else { throw NativeSourceConversationError.budgetExceeded }
        let tokens = try ContextBudgetMath.estimateTokens(serializedBytes: bytes.count, policy: ContextBudgetPolicy())
        guard ready || tokens <= min(policy.policy.tools.maxRetainedResultTokens,frozen.tools.maxRetainedResultTokens) else { throw NativeSourceConversationError.budgetExceeded }
        let data = try ForgeJSONCanonicalizationV1.data(from: payload)
        if !ready, let budget {
            guard bytes.count <= budget.maximumCanonicalToolResultBytes, tokens <= budget.maximumResultTokens,
                  try JSONEncoder().encode(String(decoding: data, as: UTF8.self)).count - 2 <= budget.maximumEscapedPayloadBytes else {
                throw NativeSourceConversationError.budgetExceeded
            }
        }
        return data
    }
    func nativeSourceProviderCallOutput(reference: NativeSourceProviderCallReference, credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, policySelection: BudgetPolicySelection,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceProviderCallOutput? {
        try controlledTransaction(cancellation: cancellation) { connection in
            let call = try nativeResolveCallUnlocked(reference: reference, credential: credential, lease: lease, connection: connection)
            try nativeCallPolicy(call, policy: policySelection, connection: connection)
            let (_, c) = try nativeLeaseUnlocked(lease, credential: credential, allowFenced: true, connection: connection)
            let stage = try nativeStageUnlocked(reference.stageID, conversation: c, connection: connection)
            let output = try nativeOutputUnlocked(reference: reference, stage: stage, conversation: c, connection: connection)
            if let output { _ = try nativeOutputBounds(output.canonicalToolResultJSON, call: call, policy: policySelection, budget: nil, ready: output.readyHandoffCommitted) }
            return output
        }
    }
    func prepareNativeSourceToolContinuation(acceptedStageID: UUID, credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, cancellation: ToolCallCancellation? = nil) throws -> NativeSourcePreparedTurn {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let (attachment,c) = try nativeLeaseUnlocked(lease, credential: credential, connection: connection)
            let prior = try nativeStageUnlocked(acceptedStageID, conversation: c, connection: connection)
            guard let turn = prior.accepted, !turn.toolCalls.isEmpty, prior.blocked == nil else { throw NativeSourceConversationError.conflict }
            if let id = try connection.first("SELECT stage_id FROM native_source_provider_turns WHERE conversation_id=? AND request_id=? AND ordinal=?",
                bindings: [.text(c.body.conversationID.uuidString.lowercased()),.text(prior.body.requestID.uuidString.lowercased()),.int64(Int64(prior.body.ordinal + 1))],
                map: { try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36)) }) {
                return try nativePrepared(nativeStageUnlocked(id, conversation: c, connection: connection), conversation: c, connection: connection)
            }
            try requireSourceMutationAdmissionUnlocked(attachment.setup.record.authorization, connection: connection)
            guard c.active == prior.body.stageID, c.state == .active, prior.body.epoch == credential.epoch,
                  prior.body.deadline > ISO8601.string(from: clock.now()), prior.body.ordinal < 8 else { throw NativeSourceConversationError.conflict }
            let outputs = try nativePriorOutputs(stage: prior, conversation: c, before: turn.toolCalls.count, connection: connection)
            guard outputs.count <= 524_288 else { throw NativeSourceConversationError.capacityExceeded }
            let body = NativeSourceStoredIntent(conversationID: c.body.conversationID, taskID: c.body.taskID,
                capabilityID: c.body.capabilityID, stageID: UUID(), requestID: prior.body.requestID, epoch: credential.epoch,
                ordinal: prior.body.ordinal + 1, assignmentSHA: c.body.assignmentSHA, providerID: c.body.providerID,
                modelKey: c.body.modelKey, kind: "tool_continuation", parentResponseID: turn.responseID, input: outputs,
                tools: prior.body.tools, deadline: prior.body.deadline, priorUsage: turn.usage, logicalInputSHA: prior.body.logicalInputSHA,
                logicalInputVersion: prior.body.logicalInputVersion, logicalInput: prior.body.logicalInput)
            try nativeInsertStage(body, connection: connection)
            return try nativePrepared(nativeStageUnlocked(body.stageID, conversation: c, connection: connection), conversation: c, connection: connection)
        }
    }

    private struct NativeSourceExecutionScope: Sendable {
        let reference: NativeSourceProviderCallReference
        let credential: NativeTaskCapabilityCredential
        let lease: NativeSourceConversationLease
        let budget: NativeSourceProviderOutputBudget
        let policy: BudgetPolicySelection
        var validatePreparedOutput: (@Sendable (PreparedContinuitySourceCommit) throws -> Void)? = nil
        var encodeResult: (@Sendable (ContinuityHandoffCommit) throws -> Data)? = nil
    }
    private func nativeScopeAdmission(_ scope: NativeSourceExecutionScope?, key: NativeSourceRequestKey,
        method: String, argumentsSHA: String, managerID: UUID, connection: ControlPlaneSQLiteConnection) throws {
        guard let scope else { return }
        let call = try nativeResolveCallUnlocked(reference: scope.reference, credential: scope.credential, lease: scope.lease, connection: connection)
        guard key == call.key, method == call.toolName, argumentsSHA == JSONSupport.sha256Hex(call.canonicalArgumentsJSON),
              managerID == scope.lease.managerInstanceID, scope.budget.conversationID == call.reference.conversationID,
              scope.budget.stageID == call.reference.stageID, scope.budget.callOrdinal == call.reference.ordinal,
              scope.budget.priorOutputsSHA256 == call.priorOutputsSHA256,
              scope.budget.configurationFingerprintSHA256 == call.prepared.retainedPreflight?.configurationFingerprintSHA256 else {
            throw NativeSourceConversationError.conflict
        }
        try nativeCallPolicy(call, policy: scope.policy, connection: connection)
        if method == "fs_read" {
            guard let ceilings = call.prepared.frozenCeilings else { throw NativeSourceConversationError.integrityFailure }
            let limit = min(call.attachment.sourceLimits.maximumResultBytes, scope.policy.policy.tools.maxResultBytes,
                ceilings.tools.maxResultBytes,call.attachment.setup.record.authorization.authorizationScope.maximumInlineOutputBytes)
            guard scope.budget.maximumCanonicalToolResultBytes >= limit, scope.budget.maximumEscapedPayloadBytes >= CanonicalToolResultOutputBounds.maximumStringExpansion * limit else {
                throw NativeSourceConversationError.budgetExceeded
            }
        }
    }
    private func nativeScopeReservation(_ scope: NativeSourceExecutionScope?, reservationID: UUID,
        connection: ControlPlaneSQLiteConnection) throws {
        guard let scope else { return }
        guard try connection.execute("""
            UPDATE native_source_provider_calls SET reservation_id=? WHERE stage_id=? AND ordinal=? AND (reservation_id IS NULL OR reservation_id=?)
            """, bindings: [.text(reservationID.uuidString.lowercased()),.text(scope.reference.stageID.uuidString.lowercased()),
                .int64(Int64(scope.reference.ordinal)),.text(reservationID.uuidString.lowercased())]) == 1 else { throw NativeSourceConversationError.conflict }
    }
    private func nativeScopeComplete(_ scope: NativeSourceExecutionScope?, reservationID: UUID, bytes: Data,
        ready: Bool, connection: ControlPlaneSQLiteConnection) throws {
        guard let scope else { return }
        let call = try nativeResolveCallUnlocked(reference: scope.reference, credential: scope.credential, lease: scope.lease, connection: connection)
        try nativeCallPolicy(call, policy: scope.policy, connection: connection)
        let payload = try nativeOutputBounds(bytes, call: call, policy: scope.policy, budget: scope.budget, ready: ready)
        guard let sourceSHA = try connection.first("SELECT result_sha256 FROM native_source_requests WHERE reservation_id=? AND state='completed'",
            bindings: [.text(reservationID.uuidString.lowercased())], map: { try $0.strictText(0, maximumBytes: 64) }) ?? nil else {
            throw NativeSourceConversationError.integrityFailure
        }
        let existing = try connection.first("SELECT output_sha256 FROM native_source_provider_calls WHERE stage_id=? AND ordinal=?",
            bindings: [.text(scope.reference.stageID.uuidString.lowercased()),.int64(Int64(scope.reference.ordinal))],
            map: { try $0.strictText(0, maximumBytes: 64) }) ?? nil
        if let existing { guard existing == JSONSupport.sha256Hex(bytes) else { throw NativeSourceConversationError.conflict }; return }
        let retained = try connection.scalarInt("SELECT COALESCE(SUM(length(CAST(output_json AS BLOB))),0) FROM native_source_provider_calls WHERE stage_id=?",
            bindings: [.text(scope.reference.stageID.uuidString.lowercased())])
        guard retained <= 2_097_152 - bytes.count else { throw NativeSourceConversationError.capacityExceeded }
        try nativeScopeReservation(scope, reservationID: reservationID, connection: connection)
        guard try connection.execute("""
            UPDATE native_source_provider_calls SET output_json=?,output_sha256=?,payload_sha256=?,source_receipt_sha256=?,ready_handoff=?,completed_at=?
            WHERE stage_id=? AND ordinal=? AND reservation_id=? AND output_json IS NULL
            """, bindings: [.text(String(decoding: bytes, as: UTF8.self)),.text(JSONSupport.sha256Hex(bytes)),.text(JSONSupport.sha256Hex(payload)),
                .text(sourceSHA),.int64(ready ? 1 : 0),.text(ISO8601.string(from: clock.now())),
                .text(scope.reference.stageID.uuidString.lowercased()),.int64(Int64(scope.reference.ordinal)),.text(reservationID.uuidString.lowercased())]) == 1 else {
            throw NativeSourceConversationError.conflict
        }
        try connection.execute("UPDATE native_source_provider_turns SET reserved_bytes=MAX(0,reserved_bytes-?) WHERE stage_id=?",
            bindings: [.int64(Int64(bytes.count)),.text(scope.reference.stageID.uuidString.lowercased())])
        if ready {
            try connection.execute("UPDATE native_source_conversations SET state='source_fenced',revision=revision+1,updated_at=? WHERE conversation_id=? AND active_stage_id=?",
                bindings: [.text(ISO8601.string(from: clock.now())),.text(scope.reference.conversationID.uuidString.lowercased()),.text(scope.reference.stageID.uuidString.lowercased())])
        }
    }
    func admitContinuitySourceRead(request: NativeSourceReadRequest, correlation: VerifiedContinuityTaskCorrelation,
        context: ToolInvocationContext, owner: ProjectBindingOwner, policySelection: BudgetPolicySelection,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceReadAdmissionResult {
        try admitContinuitySourceReadScoped(request: request, correlation: correlation, context: context, owner: owner,
            policySelection: policySelection, nativeScope: nil, cancellation: cancellation)
    }
    func admitContinuitySourceRead(request: NativeSourceReadRequest, correlation: VerifiedContinuityTaskCorrelation,
        context: ToolInvocationContext, owner: ProjectBindingOwner, policySelection: BudgetPolicySelection,
        reference: NativeSourceProviderCallReference, credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        outputBudget: NativeSourceProviderOutputBudget, cancellation: ToolCallCancellation? = nil) throws -> NativeSourceReadAdmissionResult {
        try admitContinuitySourceReadScoped(request: request, correlation: correlation, context: context, owner: owner,
            policySelection: policySelection, nativeScope: .init(reference: reference, credential: credential, lease: lease, budget: outputBudget, policy: policySelection), cancellation: cancellation)
    }
    func beginContinuitySourceRead(admission: NativeSourceReadAdmission, policySelection: BudgetPolicySelection,
        cancellation: ToolCallCancellation? = nil) throws {
        try beginContinuitySourceReadScoped(admission: admission, policySelection: policySelection, nativeScope: nil, cancellation: cancellation)
    }
    func beginContinuitySourceRead(admission: NativeSourceReadAdmission, policySelection: BudgetPolicySelection,
        reference: NativeSourceProviderCallReference, credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        outputBudget: NativeSourceProviderOutputBudget, cancellation: ToolCallCancellation? = nil) throws {
        try beginContinuitySourceReadScoped(admission: admission, policySelection: policySelection,
            nativeScope: .init(reference: reference, credential: credential, lease: lease, budget: outputBudget, policy: policySelection), cancellation: cancellation)
    }
    func completeContinuitySourceRead(admission: NativeSourceReadAdmission, canonicalToolResultJSON: Data,
        policySelection: BudgetPolicySelection, cancellation: ToolCallCancellation? = nil) throws -> NativeSourceReadReceipt {
        try completeContinuitySourceReadScoped(admission: admission, canonicalToolResultJSON: canonicalToolResultJSON,
            policySelection: policySelection, nativeScope: nil, cancellation: cancellation)
    }
    func completeContinuitySourceRead(admission: NativeSourceReadAdmission, canonicalToolResultJSON: Data,
        policySelection: BudgetPolicySelection, reference: NativeSourceProviderCallReference, credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, outputBudget: NativeSourceProviderOutputBudget,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceReadReceipt {
        try completeContinuitySourceReadScoped(admission: admission, canonicalToolResultJSON: canonicalToolResultJSON,
            policySelection: policySelection, nativeScope: .init(reference: reference, credential: credential, lease: lease, budget: outputBudget, policy: policySelection), cancellation: cancellation)
    }
    func prepareContinuitySourceCommit(request: NativeSourceCommitRequest, correlation: VerifiedContinuityTaskCorrelation,
        context: ToolInvocationContext, owner: ProjectBindingOwner, policySelection: BudgetPolicySelection,
        prepare: @Sendable (ContinuityIngressAuthorization) throws -> PreparedContinuitySourceCommit,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceCommitAdmissionResult {
        try prepareContinuitySourceCommitScoped(request: request, correlation: correlation, context: context, owner: owner,
            policySelection: policySelection, prepare: prepare, nativeScope: nil, cancellation: cancellation)
    }
    func prepareContinuitySourceCommit(request: NativeSourceCommitRequest, correlation: VerifiedContinuityTaskCorrelation,
        context: ToolInvocationContext, owner: ProjectBindingOwner, policySelection: BudgetPolicySelection,
        prepare: @Sendable (ContinuityIngressAuthorization) throws -> PreparedContinuitySourceCommit,
        reference: NativeSourceProviderCallReference, credential: NativeTaskCapabilityCredential, lease: NativeSourceConversationLease,
        outputBudget: NativeSourceProviderOutputBudget, validatePreparedOutput: @escaping @Sendable (PreparedContinuitySourceCommit) throws -> Void,
        encodeResult: @escaping @Sendable (ContinuityHandoffCommit) throws -> Data,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceCommitAdmissionResult {
        try prepareContinuitySourceCommitScoped(request: request, correlation: correlation, context: context, owner: owner,
            policySelection: policySelection, prepare: prepare,
            nativeScope: .init(reference: reference, credential: credential, lease: lease, budget: outputBudget, policy: policySelection,
                validatePreparedOutput: validatePreparedOutput, encodeResult: encodeResult), cancellation: cancellation)
    }
    func commitContinuitySourceRequest(admission: NativeSourceCommitAdmission,
        commit: @Sendable (PreparedContinuitySourceCommit, ContinuityIngressAuthorization, Bool) throws -> ContinuityHandoffCommit,
        cancellation: ToolCallCancellation? = nil) throws -> ContinuityHandoffCommit {
        try commitContinuitySourceRequestScoped(admission: admission, commit: commit, nativeScope: nil, cancellation: cancellation)
    }
    func commitContinuitySourceRequest(admission: NativeSourceCommitAdmission,
        commit: @Sendable (PreparedContinuitySourceCommit, ContinuityIngressAuthorization, Bool) throws -> ContinuityHandoffCommit,
        policySelection: BudgetPolicySelection, reference: NativeSourceProviderCallReference, credential: NativeTaskCapabilityCredential,
        lease: NativeSourceConversationLease, outputBudget: NativeSourceProviderOutputBudget,
        encodeResult: @escaping @Sendable (ContinuityHandoffCommit) throws -> Data,
        cancellation: ToolCallCancellation? = nil) throws -> ContinuityHandoffCommit {
        try commitContinuitySourceRequestScoped(admission: admission, commit: commit,
            nativeScope: .init(reference: reference, credential: credential, lease: lease, budget: outputBudget, policy: policySelection,
                encodeResult: encodeResult), cancellation: cancellation)
    }

    func requestNativeSourceConversationCancellation(conversationID: UUID, requestID: UUID, cancelRequestID: UUID,
        reason: String? = nil, credential: NativeTaskCapabilityCredential,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceConversationCancellationReceipt {
        guard (reason?.utf8.count ?? 0) <= 256 else { throw NativeSourceConversationError.invalidRequest("reason") }
        let reasonSHA = JSONSupport.sha256Hex(Data((reason ?? "").utf8))
        return try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let attachment = try authenticateNativeTaskCapabilityUnlocked(credential, connection: connection)
            let c = try nativeConversationUnlocked(conversationID, attachment: attachment, connection: connection)
            guard let id = try connection.first("SELECT stage_id FROM native_source_provider_turns WHERE conversation_id=? AND request_id=? ORDER BY ordinal DESC LIMIT 1",
                bindings: [.text(conversationID.uuidString.lowercased()),.text(requestID.uuidString.lowercased())], map: {
                    try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36))
                }) else { throw NativeSourceConversationError.notFound }
            let stage = try nativeStageUnlocked(id, conversation: c, connection: connection)
            let prior = try connection.first("SELECT cancel_request_id,cancel_reason_sha256,cancelled_at FROM native_source_provider_turns WHERE stage_id=?",
                bindings: [.text(id.uuidString.lowercased())], map: {
                    (try $0.strictText(0, maximumBytes: 36),try $0.strictText(1, maximumBytes: 64),try $0.strictText(2, maximumBytes: 20))
                })
            let firstID = try prior?.0.map { try NativeTaskValue.uuid($0) }
            if firstID == cancelRequestID, prior?.1 != reasonSHA { throw NativeSourceConversationError.conflict }
            let timestamp = try prior?.2.map { try NativeTaskValue.date($0) } ?? ISO8601.string(from: clock.now())
            let pressureExact = c.active == id && c.state == .stopped && stage.budgetDisposition != nil
            let activeExact = (c.active == id && c.state != .sourceFenced && c.state != .stopped) || pressureExact
            if firstID == nil {
                try connection.execute("UPDATE native_source_provider_turns SET cancel_request_id=?,cancel_reason_sha256=?,cancelled_at=? WHERE stage_id=? AND cancel_request_id IS NULL",
                    bindings: [.text(cancelRequestID.uuidString.lowercased()),.text(reasonSHA),.text(timestamp),.text(id.uuidString.lowercased())])
                if activeExact {
                    try connection.execute("""
                        UPDATE native_source_conversations SET cancelled=1,state='stopped',cancel_request_id=?,cancelled_request_id=?,cancel_reason_sha256=?,cancelled_at=?,revision=revision+1,updated_at=?
                        WHERE conversation_id=? AND active_stage_id=?
                        """, bindings: [.text(cancelRequestID.uuidString.lowercased()),.text(requestID.uuidString.lowercased()),.text(reasonSHA),
                            .text(timestamp),.text(timestamp),.text(conversationID.uuidString.lowercased()),.text(id.uuidString.lowercased())])
                    if pressureExact {
                        try connection.execute("UPDATE native_source_provider_turns SET blocked_code='pressure_cancelled',updated_at=? WHERE stage_id=?",
                            bindings: [.text(timestamp),.text(id.uuidString.lowercased())])
                    } else {
                        try connection.execute("UPDATE native_source_provider_turns SET state='cancelled_before_dispatch',reserved_bytes=0,blocked_code='cancelled',updated_at=? WHERE stage_id=? AND state='prepared'",
                            bindings: [.text(timestamp),.text(id.uuidString.lowercased())])
                    }
                }
            }
            return .init(conversationID: conversationID, taskID: c.body.taskID, requestID: requestID,
                cancelRequestID: firstID ?? cancelRequestID, alreadyRequested: firstID != nil,
                pendingProviderOperationID: activeExact && [.submitted,.outcomeUnknown].contains(stage.state) ? id : nil,
                recordedAt: timestamp)
        }
    }
    func pendingNativeSourceTurns(afterRowID: Int64? = nil, limit: Int = 4,
        cancellation: ToolCallCancellation? = nil) throws -> NativeSourceRecoveryPage {
        guard (afterRowID ?? 0) >= 0, (1...32).contains(limit) else { throw NativeSourceConversationError.invalidRequest("cursor") }
        return try controlledTransaction(cancellation: cancellation) { connection in
            let now = ISO8601.string(from: clock.now())
            let rows = try connection.all("""
                SELECT t.rowid,t.conversation_id,t.task_id,t.request_id,t.stage_id FROM native_source_provider_turns t
                JOIN native_source_conversations c ON c.conversation_id=t.conversation_id
                JOIN native_task_capabilities n ON n.capability_id=c.capability_id
                WHERE t.rowid>? AND t.quarantined=0 AND t.blocked_code IS NULL AND c.active_stage_id=t.stage_id AND c.cancelled=0
                    AND c.state IN('active','reconciliation_required') AND t.state IN('prepared','submitted','accepted','outcome_unknown')
                    AND (c.lease_owner IS NULL OR c.lease_expires_at<=?) AND n.state='active' AND n.expires_at>?
                ORDER BY t.rowid LIMIT ?
                """, bindings: [.int64(afterRowID ?? 0),.text(now),.text(now),.int64(Int64(limit))]) { row -> (Int64,NativeSourceRecoveryReference?) in
                    let value = try? NativeSourceRecoveryReference(rowID: row.int64(0),
                        conversationID: NativeTaskValue.uuid(row.strictText(1, maximumBytes: 36)),
                        taskID: NativeTaskValue.uuid(row.strictText(2, maximumBytes: 36)),
                        requestID: NativeTaskValue.uuid(row.strictText(3, maximumBytes: 36)),
                        stageID: NativeTaskValue.uuid(row.strictText(4, maximumBytes: 36)))
                    return (row.int64(0),value)
                }
            for (id,value) in rows where value == nil {
                try connection.execute("UPDATE native_source_provider_turns SET quarantined=1,blocked_code='invalid_metadata' WHERE rowid=?", bindings: [.int64(id)])
            }
            return .init(references: rows.compactMap(\.1), nextRowID: rows.count == limit ? rows.last?.0 : nil)
        }
    }

    func hasNativeSourceProviderConfigurationBinding(cancellation: ToolCallCancellation? = nil) throws -> Bool {
        try controlledTransaction(cancellation: cancellation) { connection in
            try connection.scalarInt("""
                SELECT EXISTS(SELECT 1 FROM native_source_conversations WHERE cancelled=0 AND state IN('idle','active','reconciliation_required'))
                    OR EXISTS(SELECT 1 FROM native_source_provider_turns WHERE state IN('submitted','outcome_unknown'))
                    OR EXISTS(SELECT 1 FROM native_source_capability_checks WHERE state='attempted')
                """) != 0
        }
    }
    private func nativeProviderCarryoverUnlocked(receipt: ContinuityIngressAcceptanceReceipt,
        conversationID: UUID, connection: ControlPlaneSQLiteConnection) throws -> NativeSourceBudgetCarryover {
        let task = try validatedContinuityTaskUnlocked(receipt.authorization, allowTerminalRun: true, connection: connection)
        guard let value = try connection.first("""
            SELECT task_id,body_json,body_sha256,ceilings_json,ceilings_sha256,state FROM native_source_conversations WHERE conversation_id=?
            """, bindings: [.text(conversationID.uuidString.lowercased())], map: { r in
                guard (try? r.strictText(0, maximumBytes: 36)) == receipt.authorization.taskID.uuidString.lowercased() else { throw NativeSourceConversationError.notFound }
                let body = try NativeSourceJournalCoding.decode(NativeSourceStoredConversation.self, Self.nativeSourceText(r, 1, 65_536),
                    sha: Self.nativeSourceText(r, 2, 64), maximum: 65_536)
                let ceilings = try NativeSourceJournalCoding.decode(NativeSourceBudgetCeilings.self, Self.nativeSourceText(r, 3, 8_192),
                    sha: Self.nativeSourceText(r, 4, 64), maximum: 8_192).validated()
                guard body.taskID == receipt.authorization.taskID, body.projectID == receipt.authorization.projectID,
                      body.projectGeneration == receipt.authorization.projectGeneration, body.sourceBindingID == receipt.authorization.sourceBindingID,
                      body.assignmentSHA == task.assignment.assignmentSHA256, body.authorizationSHA == JSONSupport.sha256Hex(try receipt.authorization.encodedJSON()),
                      (try r.strictText(5, maximumBytes: 32)) == "source_fenced" else { throw NativeSourceConversationError.integrityFailure }
                return (body,ceilings)
            }) else { throw NativeSourceConversationError.integrityFailure }
        let cid = conversationID.uuidString.lowercased()
        guard try connection.scalarInt("SELECT COUNT(*) FROM native_source_provider_turns WHERE conversation_id=? AND state!='accepted'", bindings: [.text(cid)]) == 0,
              try connection.scalarInt("SELECT COUNT(*) FROM native_source_capability_checks WHERE conversation_id=? AND state='attempted'", bindings: [.text(cid)]) == 0,
              let committed = try connection.first("""
                SELECT r.prepared_packet_json,r.packet_sha256,r.authorization_json FROM native_source_provider_calls c
                JOIN native_source_requests r ON r.reservation_id=c.reservation_id
                WHERE c.conversation_id=? AND c.ready_handoff=1 AND c.output_json IS NOT NULL AND r.state='completed'
                """, bindings: [.text(cid)], map: { r in
                    (try Self.nativeSourceText(r, 0, 262_144),try Self.nativeSourceText(r, 1, 64),try Self.nativeSourceText(r, 2, 32_768))
                }), Data(committed.0.utf8) == receipt.source.canonicalPacketJSON,
              committed.1 == receipt.source.identity.packetSHA256,
              Data(committed.2.utf8) == (try receipt.authorization.encodedJSON()) else { throw NativeSourceConversationError.integrityFailure }
        let stages = try connection.all("SELECT intent_json,intent_sha256,result_json,result_sha256,post_json,post_sha256 FROM native_source_provider_turns WHERE conversation_id=? ORDER BY rowid",
            bindings: [.text(cid)]) { r in
                let intent = try NativeSourceJournalCoding.decode(NativeSourceStoredIntent.self, Self.nativeSourceText(r, 0, 1_048_576),
                    sha: Self.nativeSourceText(r, 1, 64), maximum: 1_048_576)
                let turn = try NativeSourceJournalCoding.turn(NativeSourceJournalCoding.decode(ProviderTurn.self, Self.nativeSourceText(r, 2, 4_194_304),
                    sha: Self.nativeSourceText(r, 3, 64), maximum: 4_194_304))
                let post = try NativeSourceJournalCoding.decode(NativeSourceStoredPost.self, Self.nativeSourceText(r, 4, 32_768),
                    sha: Self.nativeSourceText(r, 5, 64), maximum: 32_768)
                guard intent.conversationID == conversationID, intent.taskID == task.authorization.taskID,
                      intent.assignmentSHA == value.0.assignmentSHA, turn.requestID == intent.stageID.uuidString.lowercased(),
                      turn.modelKey == value.0.modelKey, turn.providerID == value.0.providerID,
                      turn.previousResponseID == intent.parentResponseID else { throw NativeSourceConversationError.integrityFailure }
                _ = try post.preflight.value(); _ = try post.accounting.validated()
                return (turn,try Self.nativeSourceText(r, 1, 64),try Self.nativeSourceText(r, 3, 64),try Self.nativeSourceText(r, 5, 64))
            }
        guard !stages.isEmpty, stages.count <= 64 else { throw NativeSourceConversationError.integrityFailure }
        var input = 0, output = 0, exact = 0
        var hashes: [[String: Any]] = []
        for (turn,intentSHA,resultSHA,postSHA) in stages {
            if let usage = turn.usage {
                input = try Self.nativeSourceCheckedAdd(input, usage.inputTokens)
                output = try Self.nativeSourceCheckedAdd(output, usage.outputTokens)
                if usage.source == .providerExact || usage.source == .tokenizerExact { exact += 1 }
            }
            hashes.append(["intent":intentSHA,"result":resultSHA,"post":postSHA])
        }
        let calls = try connection.all("SELECT call_sha256,output_sha256,source_receipt_sha256 FROM native_source_provider_calls WHERE conversation_id=? ORDER BY stage_id,ordinal",
            bindings: [.text(cid)]) { r -> [String: Any] in
                ["call":try Self.nativeSourceText(r, 0, 64),"output":try r.strictText(1, maximumBytes: 64) ?? "", "source":try r.strictText(2, maximumBytes: 64) ?? ""]
            }
        let digest = JSONSupport.sha256Hex(try ForgeJSONCanonicalizationV1.data(from: ["stages":hashes,"calls":calls]))
        return .init(conversationID: conversationID, taskID: task.authorization.taskID, runID: receipt.runID,
            acceptanceSHA256: receipt.receiptSHA256, ceilings: value.1, priorSourceReadCallsAtEnrollment: value.0.priorSourceReadCallsAtEnrollment, providerStageCount: stages.count,
            admittedProviderCalls: calls.count, observedInputTokens: input, observedOutputTokens: output, exactUsageStageCount: exact, journalSHA256: digest)
    }
    private static func nativeSourceCheckedAdd(_ a: Int, _ b: Int) throws -> Int {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow, result.partialValue >= 0 else { throw NativeSourceConversationError.integrityFailure }
        return result.partialValue
    }
    private func bindNativeSourceProviderOffsetUnlocked(receipt: ContinuityIngressAcceptanceReceipt,
        connection: ControlPlaneSQLiteConnection) throws {
        guard let cid = try connection.first("SELECT conversation_id FROM native_source_conversations WHERE task_id=?",
            bindings: [.text(receipt.authorization.taskID.uuidString.lowercased())], map: { try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36)) }) else { return }
        let expected = try nativeProviderCarryoverUnlocked(receipt: receipt, conversationID: cid, connection: connection)
        let bytes = try NativeSourceJournalCoding.encode(expected, maximum: 32_768)
        if let existing = try connection.first("SELECT receipt_json,receipt_sha256 FROM native_source_provider_run_offsets WHERE run_id=?",
            bindings: [.text(receipt.runID.description)], map: { (try Self.nativeSourceText($0, 0, 32_768),try Self.nativeSourceText($0, 1, 64)) }) {
            guard bytes == Data(existing.0.utf8), JSONSupport.sha256Hex(bytes) == existing.1 else { throw NativeSourceConversationError.integrityFailure }; return
        }
        try connection.execute("INSERT INTO native_source_provider_run_offsets(run_id,conversation_id,task_id,operation_id,receipt_json,receipt_sha256) VALUES(?,?,?,?,?,?)",
            bindings: [.text(receipt.runID.description),.text(cid.uuidString.lowercased()),.text(receipt.authorization.taskID.uuidString.lowercased()),
                .text(receipt.operationID.uuidString.lowercased()),.text(String(decoding: bytes, as: UTF8.self)),.text(JSONSupport.sha256Hex(bytes))])
    }
    func nativeSourceBudgetCarryover(runID: RunID, cancellation: ToolCallCancellation? = nil) throws -> NativeSourceBudgetCarryover? {
        try controlledTransaction(cancellation: cancellation) { connection in
            try nativeSourceBudgetCarryoverUnlocked(runID: runID, connection: connection)
        }
    }
    private func nativeSourceBudgetCarryoverUnlocked(runID: RunID,
        connection: ControlPlaneSQLiteConnection) throws -> NativeSourceBudgetCarryover? {
            guard let row = try connection.first("SELECT conversation_id,operation_id,receipt_json,receipt_sha256 FROM native_source_provider_run_offsets WHERE run_id=?",
                bindings: [.text(runID.description)], map: { r in
                    (try NativeTaskValue.uuid(r.strictText(0, maximumBytes: 36)),try NativeTaskValue.uuid(r.strictText(1, maximumBytes: 36)),
                     try Self.nativeSourceText(r, 2, 32_768),try Self.nativeSourceText(r, 3, 64))
                }) else {
                guard try connection.scalarInt("SELECT COUNT(*) FROM continuity_task_authorizations t JOIN native_source_conversations c ON c.task_id=t.task_id WHERE t.run_id=?",
                    bindings: [.text(runID.description)]) == 0 else { throw NativeSourceConversationError.integrityFailure }
                return nil
            }
            guard let receipt = try acceptanceForOperationUnlocked(row.1, connection: connection), receipt.runID == runID else { throw NativeSourceConversationError.integrityFailure }
            let actual = try nativeProviderCarryoverUnlocked(receipt: receipt, conversationID: row.0, connection: connection)
            let stored = try NativeSourceJournalCoding.decode(NativeSourceBudgetCarryover.self, row.2, sha: row.3, maximum: 32_768)
            guard actual == stored else { throw NativeSourceConversationError.integrityFailure }
            return actual
    }

    // MARK: - Bounded native source requests

    private func admitContinuitySourceReadScoped(request: NativeSourceReadRequest, correlation: VerifiedContinuityTaskCorrelation,
        context: ToolInvocationContext, owner: ProjectBindingOwner, policySelection: BudgetPolicySelection,
        nativeScope: NativeSourceExecutionScope?, cancellation: ToolCallCancellation? = nil) throws -> NativeSourceReadAdmissionResult {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let attachment = try nativeSourceAttachmentUnlocked(correlation, context: context, owner: owner, nativeScope: nativeScope, connection: connection)
            try nativeScopeAdmission(nativeScope, key: request.key, method: request.toolName, argumentsSHA: request.argumentsSHA256,
                managerID: request.managerInstanceID, connection: connection)
            let authorization = attachment.setup.record.authorization
            try requireSourceMutationAdmissionUnlocked(authorization, connection: connection)
            try ContinuityIngressAcceptanceReceipt.validatePolicy(policySelection, authorization: authorization)
            let currentTime = ISO8601.string(from: clock.now())
            if let row = try nativeSourceRowUnlocked(key: request.key, connection: connection) {
                try validateNativeSourceRow(row, attachment: attachment, method: request.toolName, argumentSHA: request.argumentsSHA256)
                if row.state == "completed" {
                    return .completed(try nativeReadReceiptUnlocked(row, limits: attachment.sourceLimits,
                        authorization: authorization, policy: policySelection, connection: connection))
                }
                guard row.deadline > currentTime else { throw NativeTaskCapabilityError.resultExpired }
                // Only insertion issues an execution owner. A manager may have
                // multiple live HTTP sessions sharing this durable request key.
                guard ["admitted","executing"].contains(row.state) else { throw NativeTaskCapabilityError.resultExpired }
                return .inProgress(deadline: row.deadline)
            }
            try nativeSourceCapacityUnlocked(taskID: correlation.taskID, connection: connection)
            try expireNativeReadPayloadsUnlocked(connection: connection)
            let charged = try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE task_id=? AND method='fs_read'",
                bindings: [.text(correlation.taskID.uuidString.lowercased())])
            let policy = policySelection.policy.tools
            guard charged < min(attachment.sourceLimits.maximumCalls, policy.callsPerRun, policy.callsPerSession),
                  try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE method='fs_read' AND state IN ('admitted','executing') AND deadline>?",
                    bindings: [.text(currentTime)]) < 8,
                  try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE task_id=? AND method='fs_read' AND state IN ('admitted','executing') AND deadline>?",
                    bindings: [.text(correlation.taskID.uuidString.lowercased()), .text(currentTime)]) < min(2, policy.maxInFlight) else {
                throw NativeTaskCapabilityError.budgetExceeded
            }
            let expires = try NativeTaskValue.date(attachment.descriptor.expiresAt)
            let milliseconds = request.effectiveDeadlineMilliseconds(limits: attachment.sourceLimits)
            try cancellation?.tightenDeadline(milliseconds: milliseconds)
            let duration = min(TimeInterval(milliseconds) / 1_000, cancellation?.remainingTimeInterval ?? .infinity)
            let deadline = min(expires, ISO8601.string(from: clock.now().addingTimeInterval(duration)))
            guard deadline > currentTime else { throw ToolCallDeadlineExceeded() }
            let id = UUID()
            try insertNativeSourceRequestUnlocked(id: id, key: request.key, method: request.toolName, argumentsSHA: request.argumentsSHA256,
                managerID: request.managerInstanceID, attachment: attachment, policy: policySelection, deadline: deadline,
                chargedCalls: charged + 1, prepared: nil, connection: connection)
            try nativeScopeReservation(nativeScope, reservationID: id, connection: connection)
            return .execute(.init(reservationID: id, request: request, correlation: correlation, deadline: deadline, chargedCalls: charged + 1))
        }
    }

    private func beginContinuitySourceReadScoped(admission: NativeSourceReadAdmission, policySelection: BudgetPolicySelection,
        nativeScope: NativeSourceExecutionScope?, cancellation: ToolCallCancellation? = nil) throws {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let attachment = try nativeSourceAttachmentUnlocked(admission.correlation, context: admission.correlation.callerContext,
                owner: admission.correlation.callerOwner, nativeScope: nativeScope, connection: connection)
            try nativeScopeAdmission(nativeScope, key: admission.request.key, method: "fs_read", argumentsSHA: admission.request.argumentsSHA256,
                managerID: admission.request.managerInstanceID, connection: connection)
            try requireSourceMutationAdmissionUnlocked(attachment.setup.record.authorization, connection: connection)
            try ContinuityIngressAcceptanceReceipt.validatePolicy(policySelection, authorization: attachment.setup.record.authorization)
            let row = try requireNativeReadAdmissionUnlocked(admission, attachment: attachment, connection: connection)
            let timestamp = ISO8601.string(from: clock.now())
            guard row.state == "admitted", row.deadline > timestamp,
                  row.chargedCalls <= min(attachment.sourceLimits.maximumCalls, policySelection.policy.tools.callsPerRun,
                    policySelection.policy.tools.callsPerSession) else { throw NativeTaskCapabilityError.budgetExceeded }
            // A lowered policy gates the next dispatch without revoking an
            // already executing read. Unstarted reservations are not executions;
            // expired crash records remain charged but cannot consume a live slot.
            guard try connection.scalarInt("""
                SELECT COUNT(*) FROM native_source_requests
                WHERE method='fs_read' AND state='executing' AND deadline>?
                """, bindings: [.text(timestamp)]) < 8,
                try connection.scalarInt("""
                SELECT COUNT(*) FROM native_source_requests
                WHERE task_id=? AND method='fs_read' AND state='executing' AND deadline>?
                """, bindings: [.text(row.taskID.uuidString.lowercased()), .text(timestamp)])
                    < min(2, policySelection.policy.tools.maxInFlight) else {
                throw NativeTaskCapabilityError.budgetExceeded
            }
            guard try connection.execute("UPDATE native_source_requests SET state='executing' WHERE reservation_id=? AND state='admitted'",
                bindings: [.text(row.id.uuidString.lowercased())]) == 1 else { throw NativeTaskCapabilityError.operationBusy }
        }
    }

    private func completeContinuitySourceReadScoped(admission: NativeSourceReadAdmission, canonicalToolResultJSON: Data,
        policySelection: BudgetPolicySelection, nativeScope: NativeSourceExecutionScope?, cancellation: ToolCallCancellation? = nil) throws -> NativeSourceReadReceipt {
        // Bound input before parsing or entering the durable transaction.
        guard !canonicalToolResultJSON.isEmpty, canonicalToolResultJSON.count <= 65_536 else { throw NativeTaskCapabilityError.budgetExceeded }
        return try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let attachment = try nativeSourceAttachmentUnlocked(admission.correlation, context: admission.correlation.callerContext,
                owner: admission.correlation.callerOwner, nativeScope: nativeScope, connection: connection)
            try nativeScopeAdmission(nativeScope, key: admission.request.key, method: "fs_read", argumentsSHA: admission.request.argumentsSHA256,
                managerID: admission.request.managerInstanceID, connection: connection)
            try requireSourceMutationAdmissionUnlocked(attachment.setup.record.authorization, connection: connection)
            let row = try requireNativeReadAdmissionUnlocked(admission, attachment: attachment, connection: connection)
            let tokens = try nativeReadResultBounds(canonicalToolResultJSON, limits: attachment.sourceLimits,
                authorization: attachment.setup.record.authorization, policy: policySelection)
            if row.state == "completed" {
                let retained = try nativeReadReceiptUnlocked(row, limits: attachment.sourceLimits,
                    authorization: attachment.setup.record.authorization, policy: policySelection, connection: connection)
                guard retained.canonicalToolResultJSON == canonicalToolResultJSON else { throw NativeTaskCapabilityError.requestConflict }
                return retained
            }
            guard row.state == "executing", row.deadline > ISO8601.string(from: clock.now()) else { throw NativeTaskCapabilityError.resultExpired }
            try expireNativeReadPayloadsUnlocked(connection: connection)
            let bytes = canonicalToolResultJSON.count
            guard try connection.scalarInt("SELECT COALESCE(SUM(length(CAST(result_json AS BLOB))),0) FROM native_source_requests WHERE method='fs_read'") <= 67_108_864 - bytes,
                  try connection.scalarInt("SELECT COALESCE(SUM(length(CAST(result_json AS BLOB))),0) FROM native_source_requests WHERE method='fs_read' AND task_id=?",
                    bindings: [.text(row.taskID.uuidString.lowercased())]) <= 4_194_304 - bytes else { throw NativeTaskCapabilityError.capacityExceeded }
            let timestamp = ISO8601.string(from: clock.now()), digest = JSONSupport.sha256Hex(canonicalToolResultJSON)
            try connection.execute("""
                UPDATE native_source_requests SET state='completed',result_json=?,result_sha256=?,result_tokens=?,completed_at=?,result_expires_at=?
                WHERE reservation_id=? AND state='executing'
                """, bindings: [.text(String(decoding: canonicalToolResultJSON, as: UTF8.self)), .text(digest), .int64(Int64(tokens)), .text(timestamp),
                    .text(ISO8601.string(from: clock.now().addingTimeInterval(3_600))), .text(row.id.uuidString.lowercased())])
            try nativeScopeComplete(nativeScope, reservationID: row.id, bytes: canonicalToolResultJSON, ready: false, connection: connection)
            return .init(reservationID: row.id, key: admission.request.key, taskID: row.taskID, resultSHA256: digest,
                canonicalToolResultJSON: canonicalToolResultJSON, estimatedResultTokens: tokens, chargedCalls: row.chargedCalls, completedAt: timestamp)
        }
    }

    /// Only the opaque existing reservation may be withheld after authority loss.
    /// This cleanup stores no result and never refunds its durable debit.
    func finishContinuitySourceReadWithoutDisclosure(admission: NativeSourceReadAdmission,
        outcome: NativeSourceReadUndisclosedOutcome, cancellation: ToolCallCancellation? = nil) throws {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            guard let row = try nativeSourceRowUnlocked(key: admission.request.key, connection: connection),
                  row.id == admission.reservationID, row.taskID == admission.taskID,
                  row.managerID == admission.request.managerInstanceID, row.argumentsSHA == admission.request.argumentsSHA256,
                  row.epoch == admission.correlation.nativeCredential?.epoch,
                  row.capabilityID == admission.correlation.nativeCredential?.capabilityID else { throw NativeTaskCapabilityError.requestConflict }
            try connection.execute("UPDATE native_source_requests SET state=? WHERE reservation_id=? AND state IN ('admitted','executing')",
                bindings: [.text(outcome.rawValue), .text(row.id.uuidString.lowercased())])
        }
    }

    private func prepareContinuitySourceCommitScoped(request: NativeSourceCommitRequest, correlation: VerifiedContinuityTaskCorrelation,
        context: ToolInvocationContext, owner: ProjectBindingOwner, policySelection: BudgetPolicySelection,
        prepare: @Sendable (ContinuityIngressAuthorization) throws -> PreparedContinuitySourceCommit,
        nativeScope: NativeSourceExecutionScope?, cancellation: ToolCallCancellation? = nil) throws -> NativeSourceCommitAdmissionResult {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let attachment = try nativeSourceAttachmentUnlocked(correlation, context: context, owner: owner, nativeScope: nativeScope, connection: connection)
            try nativeScopeAdmission(nativeScope, key: request.key, method: request.method, argumentsSHA: request.argumentsSHA256,
                managerID: request.managerInstanceID, connection: connection)
            if let nativeScope {
                guard let arguments = try JSONSerialization.jsonObject(with: request.canonicalArgumentsJSON) as? [String: Any] else { throw NativeSourceConversationError.invalidRequest("arguments") }
                let milliseconds = min(try ToolRouter.requestedDeadlineMilliseconds(in: arguments) ?? 30_000, attachment.sourceLimits.maximumRequestSeconds * 1_000)
                try cancellation?.tightenDeadline(milliseconds: milliseconds)
                guard nativeScope.lease.expiresAt > ISO8601.string(from: clock.now()) else { throw NativeSourceConversationError.leaseUnavailable }
            }
            let authorization = attachment.setup.record.authorization
            try ContinuityIngressAcceptanceReceipt.validatePolicy(policySelection, authorization: authorization)
            if let row = try nativeSourceRowUnlocked(key: request.key, connection: connection) {
                try validateNativeSourceRow(row, attachment: attachment, method: request.method, argumentSHA: request.argumentsSHA256)
                let (packet, automatic) = try nativePreparedCommitUnlocked(row, authorization: authorization, connection: connection)
                if row.state == "completed" { return .completed(try nativeCommitResultUnlocked(row, prepared: packet, authorization: authorization, connection: connection)) }
                guard row.state == "pending" else { throw NativeTaskCapabilityError.requestConflict }
                return .commit(.init(reservationID: row.id, request: request, correlation: correlation, prepared: packet,
                    authorization: authorization, automaticHandoffEnabled: automatic))
            }
            try requireSourceMutationAdmissionUnlocked(authorization, connection: connection)
            try nativeSourceCapacityUnlocked(taskID: correlation.taskID, connection: connection)
            guard try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE task_id=? AND state='pending'",
                bindings: [.text(correlation.taskID.uuidString.lowercased())]) == 0 else { throw NativeTaskCapabilityError.operationBusy }
            guard try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE method!='fs_read'") < 1_024,
                  try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE task_id=? AND method!='fs_read'",
                    bindings: [.text(correlation.taskID.uuidString.lowercased())]) < 64 else { throw NativeTaskCapabilityError.capacityExceeded }
            let prepared = try prepare(authorization)
            guard prepared.finalize == request.finalize else { throw NativeTaskCapabilityError.requestConflict }
            if !prepared.finalize { try nativeScope?.validatePreparedOutput?(prepared) }
            _ = try PreparedContinuitySourceCommit.storedSnapshot(from: prepared.canonicalPacketJSON)
            guard try connection.scalarInt("SELECT COALESCE(SUM(length(CAST(prepared_packet_json AS BLOB))),0) FROM native_source_requests")
                    <= 67_108_864 - prepared.canonicalPacketJSON.count,
                  try connection.scalarInt("SELECT COALESCE(SUM(length(CAST(prepared_packet_json AS BLOB))),0) FROM native_source_requests WHERE task_id=?",
                    bindings: [.text(correlation.taskID.uuidString.lowercased())]) <= 4_194_304 - prepared.canonicalPacketJSON.count else {
                throw NativeTaskCapabilityError.capacityExceeded
            }
            try cancellation?.checkCancellation()
            try requireNativeCorrelationUnlocked(correlation, connection: connection)
            let id = UUID()
            try insertNativeSourceRequestUnlocked(id: id, key: request.key, method: request.method, argumentsSHA: request.argumentsSHA256,
                managerID: request.managerInstanceID, attachment: attachment, policy: policySelection,
                deadline: attachment.descriptor.expiresAt, chargedCalls: 0, prepared: prepared, connection: connection)
            try nativeScopeReservation(nativeScope, reservationID: id, connection: connection)
            return .commit(.init(reservationID: id, request: request, correlation: correlation, prepared: prepared,
                authorization: authorization, automaticHandoffEnabled: policySelection.policy.automaticHandoffEnabled))
        }
    }

    private func commitContinuitySourceRequestScoped(admission: NativeSourceCommitAdmission,
        commit: @Sendable (PreparedContinuitySourceCommit, ContinuityIngressAuthorization, Bool) throws -> ContinuityHandoffCommit,
        nativeScope: NativeSourceExecutionScope?, cancellation: ToolCallCancellation? = nil) throws -> ContinuityHandoffCommit {
        try controlledTransaction(cancellation: cancellation, checkCancellationBeforeCommit: false, fullDurability: true) { connection in
            let attachment = try nativeSourceAttachmentUnlocked(admission.correlation, context: admission.correlation.callerContext,
                owner: admission.correlation.callerOwner, nativeScope: nativeScope, connection: connection)
            try nativeScopeAdmission(nativeScope, key: admission.request.key, method: admission.request.method,
                argumentsSHA: admission.request.argumentsSHA256, managerID: admission.request.managerInstanceID, connection: connection)
            guard let row = try nativeSourceRowUnlocked(key: admission.request.key, connection: connection), row.id == admission.reservationID else {
                throw NativeTaskCapabilityError.requestConflict
            }
            try validateNativeSourceRow(row, attachment: attachment, method: admission.request.method, argumentSHA: admission.request.argumentsSHA256)
            let authorization = attachment.setup.record.authorization
            let (prepared, automatic) = try nativePreparedCommitUnlocked(row, authorization: authorization, connection: connection)
            guard admission.authorization == authorization, admission.prepared == prepared, admission.automaticHandoffEnabled == automatic else {
                throw NativeTaskCapabilityError.requestConflict
            }
            if row.state == "completed" { return try nativeCommitResultUnlocked(row, prepared: prepared, authorization: authorization, connection: connection) }
            guard row.state == "pending" else { throw NativeTaskCapabilityError.requestConflict }
            // Only this frozen request may pass its own quiescing intent. A
            // separately accepted source must match these exact immutable bytes.
            if let fenceOperation = try connection.first("SELECT operation_id FROM continuity_source_task_fences WHERE task_id=?",
                bindings: [.text(row.taskID.uuidString.lowercased())], map: { try $0.strictText(0, maximumBytes: 36) }) ?? nil {
                guard let id = UUID(uuidString: fenceOperation), let receipt = try acceptanceForOperationUnlocked(id, connection: connection),
                      receipt.authorization == authorization, receipt.source.canonicalPacketJSON == prepared.canonicalPacketJSON else {
                    throw NativeTaskCapabilityError.sourceFenced
                }
                try requireContinuityOperationNotCancelledUnlocked(id, connection: connection)
            }
            try cancellation?.checkCancellation()
            let actual = try commit(prepared, authorization, automatic)
            guard actual.revision.authorization == authorization, actual.revision.canonicalPacketJSON == prepared.canonicalPacketJSON,
                  actual.revision.identity.packetSHA256 == prepared.packetSHA256, actual.revision.resumeReady == prepared.finalize else {
                throw NativeTaskCapabilityError.integrityFailure
            }
            let bytes = try NativeSourceCommitEvidence.encode(actual)
            _ = try NativeSourceCommitEvidence.decode(bytes, prepared: prepared, authorization: authorization)
            // The source store has committed. Finish the CP receipt despite a
            // late transport cancellation; failed CP COMMIT retains exact intent.
            connection.finishRequestCancellationWindow()
            try connection.execute("""
                UPDATE native_source_requests SET state='completed',result_json=?,result_sha256=?,completed_at=?
                WHERE reservation_id=? AND state='pending'
                """, bindings: [.text(String(decoding: bytes, as: UTF8.self)), .text(JSONSupport.sha256Hex(bytes)),
                    .text(ISO8601.string(from: clock.now())), .text(row.id.uuidString.lowercased())])
            if let nativeScope, let encode = nativeScope.encodeResult {
                try nativeScopeComplete(nativeScope, reservationID: row.id, bytes: encode(actual), ready: prepared.finalize, connection: connection)
            }
            return actual
        }
    }

    func pendingNativeSourceCommits(afterRowID: Int64? = nil, limit: Int = 16,
        cancellation: ToolCallCancellation? = nil) throws -> [NativePendingSourceCommitReference] {
        guard (1...32).contains(limit), (afterRowID ?? 0) >= 0 else { throw NativeTaskCapabilityError.invalidRequest("cursor") }
        return try controlledTransaction(cancellation: cancellation) { connection in
            let rows = try connection.all("""
                SELECT rowid,reservation_id,task_id,capability_id FROM native_source_requests WHERE rowid>? AND state='pending'
                    AND NOT EXISTS(SELECT 1 FROM native_source_provider_calls c WHERE c.reservation_id=native_source_requests.reservation_id)
                AND NOT EXISTS(SELECT 1 FROM native_source_provider_turns t WHERE t.pressure_reservation_id=native_source_requests.reservation_id)
                    AND recovery_attempts<8 AND quarantined=0 AND deadline>? AND (retry_at IS NULL OR retry_at<=?) ORDER BY rowid LIMIT ?
                """, bindings: [.int64(afterRowID ?? 0), .text(ISO8601.string(from: clock.now())),
                    .text(ISO8601.string(from: clock.now())), .int64(Int64(limit))]) { row -> (Int64, NativePendingSourceCommitReference?) in
                    let reference = try? NativePendingSourceCommitReference(rowID: row.int64(0),
                        reservationID: NativeTaskValue.uuid(row.strictText(1, maximumBytes: 36)),
                        taskID: NativeTaskValue.uuid(row.strictText(2, maximumBytes: 36)),
                        capabilityID: NativeTaskValue.uuid(row.strictText(3, maximumBytes: 36)))
                    return (row.int64(0), reference)
                }
            for (id, reference) in rows where reference == nil {
                try connection.execute("UPDATE native_source_requests SET quarantined=1,error_code='invalid_metadata' WHERE rowid=?", bindings: [.int64(id)])
            }
            return rows.compactMap(\.1)
        }
    }

    func reconcileNativeSourceCommit(reference: NativePendingSourceCommitReference,
        commit: @Sendable (PreparedContinuitySourceCommit, ContinuityIngressAuthorization, Bool) throws -> ContinuityHandoffCommit,
        cancellation: ToolCallCancellation? = nil) throws -> ContinuityHandoffCommit? {
        try controlledTransaction(cancellation: cancellation, checkCancellationBeforeCommit: false, fullDurability: true) { connection in
            guard let key = try nativePendingCommitKeyUnlocked(reference, connection: connection),
                  let row = try nativeSourceRowUnlocked(key: key, connection: connection) else { return nil }
            guard row.state == "pending", row.id == reference.reservationID, row.taskID == reference.taskID,
                  row.capabilityID == reference.capabilityID, row.deadline > ISO8601.string(from: clock.now()),
                  let capability = try nativeCapabilityUnlocked(row.capabilityID, connection: connection),
                  capability.epoch == row.epoch, capability.state == "active", capability.expiresAt > ISO8601.string(from: clock.now()) else {
                throw NativeTaskCapabilityError.credentialRejected
            }
            let (task, _) = try validateNativeCapabilityOwnerUnlocked(capability, taskID: row.taskID, projectID: capability.projectID,
                generation: capability.generation, connection: connection)
            let (prepared, automatic) = try nativePreparedCommitUnlocked(row, authorization: task.authorization, connection: connection)
            if let idText = try connection.first("SELECT operation_id FROM continuity_source_task_fences WHERE task_id=?",
                bindings: [.text(row.taskID.uuidString.lowercased())], map: { try $0.strictText(0, maximumBytes: 36) }) ?? nil {
                guard let operationID = UUID(uuidString: idText), let receipt = try acceptanceForOperationUnlocked(operationID, connection: connection),
                      receipt.authorization == task.authorization, receipt.source.canonicalPacketJSON == prepared.canonicalPacketJSON else {
                    throw NativeTaskCapabilityError.sourceFenced
                }
                try requireContinuityOperationNotCancelledUnlocked(operationID, connection: connection)
            }
            try cancellation?.checkCancellation()
            let actual = try commit(prepared, task.authorization, automatic)
            guard actual.revision.authorization == task.authorization, actual.revision.canonicalPacketJSON == prepared.canonicalPacketJSON,
                  actual.revision.identity.packetSHA256 == prepared.packetSHA256, actual.revision.resumeReady == prepared.finalize else {
                throw NativeTaskCapabilityError.integrityFailure
            }
            let data = try NativeSourceCommitEvidence.encode(actual)
            _ = try NativeSourceCommitEvidence.decode(data, prepared: prepared, authorization: task.authorization)
            connection.finishRequestCancellationWindow()
            try connection.execute("""
                UPDATE native_source_requests SET state='completed',result_json=?,result_sha256=?,completed_at=?,retry_at=NULL,error_code=NULL
                WHERE reservation_id=? AND state='pending'
                """, bindings: [.text(String(decoding: data, as: UTF8.self)), .text(JSONSupport.sha256Hex(data)),
                    .text(ISO8601.string(from: clock.now())), .text(row.id.uuidString.lowercased())])
            return actual
        }
    }

    func deferNativeSourceCommit(reference: NativePendingSourceCommitReference, cancellation: ToolCallCancellation? = nil) throws {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            guard try nativePendingCommitKeyUnlocked(reference, connection: connection) != nil,
                  let attempts = try connection.first("SELECT recovery_attempts FROM native_source_requests WHERE reservation_id=? AND state='pending'",
                    bindings: [.text(reference.reservationID.uuidString.lowercased())], map: { $0.int64(0) }), (0..<8).contains(attempts) else { return }
            let next = attempts + 1, delay = min(300, 5 * (1 << Int(attempts)))
            try connection.execute("""
                UPDATE native_source_requests SET recovery_attempts=?,retry_at=?,error_code='reconciliation_required',quarantined=?
                WHERE reservation_id=? AND state='pending' AND recovery_attempts=?
                """, bindings: [.int64(next), .text(ISO8601.string(from: clock.now().addingTimeInterval(TimeInterval(delay)))),
                    .int64(next == 8 ? 1 : 0), .text(reference.reservationID.uuidString.lowercased()), .int64(attempts)])
        }
    }

    private func nativePendingCommitKeyUnlocked(_ reference: NativePendingSourceCommitReference,
        connection: ControlPlaneSQLiteConnection) throws -> NativeSourceRequestKey? {
        try connection.first("""
            SELECT session_id,request_id_sha256 FROM native_source_requests
            WHERE rowid=? AND reservation_id=? AND task_id=? AND capability_id=? AND method IN ('session_checkpoint','session_handoff')
                AND state='pending' AND quarantined=0 AND recovery_attempts<8 AND (retry_at IS NULL OR retry_at<=?)
                AND NOT EXISTS(SELECT 1 FROM native_source_provider_calls c WHERE c.reservation_id=native_source_requests.reservation_id)
                AND NOT EXISTS(SELECT 1 FROM native_source_provider_turns t WHERE t.pressure_reservation_id=native_source_requests.reservation_id)
            """, bindings: [.int64(reference.rowID), .text(reference.reservationID.uuidString.lowercased()),
                .text(reference.taskID.uuidString.lowercased()), .text(reference.capabilityID.uuidString.lowercased()),
                .text(ISO8601.string(from: clock.now()))]) { row in
                try .init(sessionID: NativeTaskValue.uuid(row.strictText(0, maximumBytes: 36)),
                    requestIDSHA256: NativeTaskValue.sha(row.strictText(1, maximumBytes: 64)))
            }
    }

    private func bindNativeSourceOffsetUnlocked(receipt: ContinuityIngressAcceptanceReceipt,
        connection: ControlPlaneSQLiteConnection) throws {
        try bindNativeSourceProviderOffsetUnlocked(receipt: receipt, connection: connection)
        let taskID = receipt.authorization.taskID.uuidString.lowercased()
        guard try connection.scalarInt("SELECT COUNT(*) FROM native_task_capabilities WHERE task_id=?", bindings: [.text(taskID)]) == 1 else { return }
        let charged = try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE task_id=? AND method='fs_read'", bindings: [.text(taskID)])
        if let prior = try nativeRunSourceOffsetUnlocked(receipt.runID, allowMissing: true, includeProviderCalls: false, connection: connection) {
            guard prior == charged else { throw NativeTaskCapabilityError.integrityFailure }; return
        }
        try connection.execute("""
            INSERT INTO native_source_run_offsets(task_id,run_id,source_binding_id,operation_id,receipt_sha256,charged_calls,recorded_at)
            VALUES(?,?,?,?,?,?,?)
            """, bindings: [.text(taskID), .text(receipt.runID.description), .text(receipt.authorization.sourceBindingID.uuidString.lowercased()),
                .text(receipt.operationID.uuidString.lowercased()), .text(receipt.receiptSHA256), .int64(Int64(charged)), .text(receipt.acceptedAt)])
    }

    private func nativeRunSourceOffsetUnlocked(_ runID: RunID, allowMissing: Bool = false, includeProviderCalls: Bool = true, connection: ControlPlaneSQLiteConnection) throws -> Int? {
        guard let offset = try connection.first("SELECT task_id,source_binding_id,operation_id,receipt_sha256,charged_calls FROM native_source_run_offsets WHERE run_id=?",
            bindings: [.text(runID.description)], map: {
                (try $0.strictText(0, maximumBytes: 36), try $0.strictText(1, maximumBytes: 36),
                 try $0.strictText(2, maximumBytes: 36), try $0.strictText(3, maximumBytes: 64), $0.int64(4))
            }) else {
            guard try allowMissing || (connection.scalarInt("""
                SELECT COUNT(*) FROM continuity_task_authorizations t JOIN native_task_capabilities c ON c.task_id=t.task_id
                WHERE t.run_id=?
                """, bindings: [.text(runID.description)])) == 0 else { throw NativeTaskCapabilityError.integrityFailure }
            return nil
        }
        guard let task = offset.0, let operation = offset.2.flatMap(UUID.init(uuidString:)), (0...64).contains(offset.4),
              let receipt = try acceptanceForOperationUnlocked(operation, connection: connection), receipt.runID == runID,
              receipt.authorization.taskID.uuidString.lowercased() == task,
              receipt.authorization.sourceBindingID.uuidString.lowercased() == offset.1, receipt.receiptSHA256 == offset.3,
              try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE task_id=? AND method='fs_read'", bindings: [.text(task)]) == Int(offset.4) else {
            throw NativeTaskCapabilityError.integrityFailure
        }
        if includeProviderCalls, let inherited = try nativeSourceBudgetCarryoverUnlocked(runID: runID, connection: connection) {
            return try Self.nativeSourceCheckedAdd(inherited.priorSourceReadCallsAtEnrollment, inherited.admittedProviderCalls)
        }
        return Int(offset.4)
    }

    private func nativeInheritedToolPolicy(_ current: BudgetToolPolicy, runID: RunID,
        connection: ControlPlaneSQLiteConnection) throws -> BudgetToolPolicy {
        guard let inherited = try nativeSourceBudgetCarryoverUnlocked(runID: runID, connection: connection) else { return current }
        let frozen = inherited.ceilings.tools
        return try BudgetToolPolicy(callsPerTurn: min(current.callsPerTurn,frozen.callsPerTurn),
            callsPerSession: min(current.callsPerSession,frozen.callsPerSession), callsPerRun: min(current.callsPerRun,frozen.callsPerRun),
            maxInFlight: min(current.maxInFlight,frozen.maxInFlight), maxResultBytes: min(current.maxResultBytes,frozen.maxResultBytes),
            maxRetainedResultTokens: min(current.maxRetainedResultTokens,frozen.maxRetainedResultTokens),
            recoveryCallsPerRollover: min(current.recoveryCallsPerRollover,frozen.recoveryCallsPerRollover)).validated()
    }

    private func requireNativeManagedToolQuotaUnlocked(intent: ToolInvocationIntent, offset: Int, policy: BudgetToolPolicy,
        alreadyReserved: Bool = false,
        connection: ControlPlaneSQLiteConnection) throws {
        let policy = try nativeInheritedToolPolicy(policy, runID: intent.runID, connection: connection)
        let checks: [(String, [ControlPlaneSQLiteBinding], Int)] = [
            ("SELECT COUNT(*) FROM tool_invocations WHERE run_id=?", [.text(intent.runID.description)], max(0, policy.callsPerRun - offset)),
            ("SELECT COUNT(*) FROM tool_invocations WHERE session_id=?", [.text(intent.sessionID)], policy.callsPerSession),
            ("SELECT COUNT(*) FROM tool_invocations WHERE turn_id=?", [.text(intent.turnID.uuidString.lowercased())], policy.callsPerTurn),
            ("SELECT COUNT(*) FROM tool_invocations WHERE run_id=? AND state IN ('intent','executing','ambiguous')", [.text(intent.runID.description)], policy.maxInFlight),
        ]
        for (sql, bindings, maximum) in checks {
            let count = try connection.scalarInt(sql, bindings: bindings)
            guard alreadyReserved ? count <= maximum : count < maximum else { throw NativeTaskCapabilityError.budgetExceeded }
        }
    }

    private static func nativeRetainedToolIntent(_ invocation: ToolInvocationRecord) -> ToolInvocationIntent {
        .init(invocationID: invocation.invocationID, turnID: invocation.turnID, runID: invocation.runID,
            sessionID: invocation.sessionID, projectID: invocation.projectID, projectGeneration: invocation.projectGeneration,
            providerCallID: invocation.providerCallID, toolName: invocation.toolName, replayClass: invocation.replayClass,
            idempotencyKey: invocation.idempotencyKey, argumentsSHA256: invocation.argumentsSHA256,
            reconciliationDescriptor: invocation.reconciliationDescriptor)
    }

    private func nativeManagedResultBounds(_ data: Data, policy: BudgetToolPolicy, runID: RunID, connection: ControlPlaneSQLiteConnection) throws {
        let policy = try nativeInheritedToolPolicy(policy, runID: runID, connection: connection)
        guard !data.isEmpty, data.count <= min(65_536, policy.maxResultBytes),
              try ContextBudgetMath.estimateTokens(serializedBytes: data.count, policy: ContextBudgetPolicy()) <= policy.maxRetainedResultTokens else {
            throw NativeTaskCapabilityError.budgetExceeded
        }
    }

    private struct NativeSourceRow {
        let id: UUID, taskID: UUID, capabilityID: UUID, epoch: Int64, key: NativeSourceRequestKey
        let method: String, argumentsSHA: String, managerID: UUID, state: String, deadline: String, chargedCalls: Int
    }
    private func nativeSourceRowUnlocked(key: NativeSourceRequestKey, connection: ControlPlaneSQLiteConnection) throws -> NativeSourceRow? {
        try connection.first("""
            SELECT reservation_id,task_id,capability_id,epoch,method,arguments_sha256,manager_instance_id,state,deadline,charged_calls
            FROM native_source_requests WHERE session_id=? AND request_id_sha256=?
            """, bindings: [.text(key.sessionID.uuidString.lowercased()), .text(key.requestIDSHA256)]) { row in
                guard row.int64(3) > 0, let method = try row.strictText(4, maximumBytes: 32),
                      let state = try row.strictText(7, maximumBytes: 32), (0...64).contains(row.int64(9)) else { throw NativeTaskCapabilityError.integrityFailure }
                return .init(id: try NativeTaskValue.uuid(row.strictText(0, maximumBytes: 36)), taskID: try NativeTaskValue.uuid(row.strictText(1, maximumBytes: 36)),
                    capabilityID: try NativeTaskValue.uuid(row.strictText(2, maximumBytes: 36)), epoch: row.int64(3), key: key, method: method,
                    argumentsSHA: try NativeTaskValue.sha(row.strictText(5, maximumBytes: 64)), managerID: try NativeTaskValue.uuid(row.strictText(6, maximumBytes: 36)),
                    state: state, deadline: try NativeTaskValue.date(row.strictText(8, maximumBytes: 20)), chargedCalls: Int(row.int64(9)))
            }
    }
    private func validateNativeSourceRow(_ row: NativeSourceRow, attachment: AuthenticatedContinuityTaskAttachment,
        method: String, argumentSHA: String) throws {
        guard row.taskID == attachment.descriptor.taskID, row.capabilityID == attachment.descriptor.capabilityID,
              row.epoch == attachment.descriptor.epoch, row.method == method, row.argumentsSHA == argumentSHA else {
            throw NativeTaskCapabilityError.requestConflict
        }
    }
    private func nativeSourceAttachmentUnlocked(_ correlation: VerifiedContinuityTaskCorrelation,
        context: ToolInvocationContext, owner: ProjectBindingOwner, nativeScope: NativeSourceExecutionScope? = nil, connection: ControlPlaneSQLiteConnection) throws -> AuthenticatedContinuityTaskAttachment {
        guard let credential = correlation.nativeCredential, correlation.callerContext == context, correlation.callerOwner == owner else {
            throw NativeTaskCapabilityError.credentialRejected
        }
        let attachment = try authenticateNativeTaskCapabilityUnlocked(credential, connection: connection)
        let live = attachment.setup.correlation
        guard live.taskID == correlation.taskID, live.callerBindingID == correlation.callerBindingID,
              live.authorizationSHA256 == correlation.authorizationSHA256, live.sourceBindingID == correlation.sourceBindingID,
              attachment.context == context, attachment.owner == owner else { throw NativeTaskCapabilityError.credentialRejected }
        if let nativeScope {
            let call = try nativeResolveCallUnlocked(reference: nativeScope.reference, credential: nativeScope.credential, lease: nativeScope.lease, connection: connection)
            guard call.attachment.descriptor == attachment.descriptor else { throw NativeSourceConversationError.notFound }
        } else if try connection.scalarInt("SELECT COUNT(*) FROM native_source_conversations WHERE task_id=?", bindings: [.text(live.taskID.uuidString.lowercased())]) != 0 {
            throw NativeSourceConversationError.ownerManaged
        }
        return attachment
    }
    private func nativeSourceCapacityUnlocked(taskID: UUID, connection: ControlPlaneSQLiteConnection) throws {
        guard try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests") < 16_384,
              try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE task_id=?", bindings: [.text(taskID.uuidString.lowercased())]) < 512 else {
            throw NativeTaskCapabilityError.capacityExceeded
        }
    }
    private func insertNativeSourceRequestUnlocked(id: UUID, key: NativeSourceRequestKey, method: String, argumentsSHA: String,
        managerID: UUID, attachment: AuthenticatedContinuityTaskAttachment, policy: BudgetPolicySelection,
        deadline: String, chargedCalls: Int, prepared: PreparedContinuitySourceCommit?, connection: ControlPlaneSQLiteConnection) throws {
        let policyData = try ForgeJSONCanonicalizationV1.data(from: JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)))
        try connection.execute("""
            INSERT INTO native_source_requests(reservation_id,task_id,capability_id,epoch,session_id,request_id_sha256,method,arguments_sha256,
                manager_instance_id,state,admitted_at,deadline,charged_calls,policy_json,prepared_packet_json,packet_sha256,authorization_json,automatic_enabled)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, bindings: [.text(id.uuidString.lowercased()), .text(attachment.descriptor.taskID.uuidString.lowercased()),
                .text(attachment.descriptor.capabilityID.uuidString.lowercased()), .int64(attachment.descriptor.epoch),
                .text(key.sessionID.uuidString.lowercased()), .text(key.requestIDSHA256), .text(method), .text(argumentsSHA), .text(managerID.uuidString.lowercased()),
                .text(prepared == nil ? "admitted" : "pending"), .text(ISO8601.string(from: clock.now())), .text(deadline), .int64(Int64(chargedCalls)),
                .text(String(decoding: policyData, as: UTF8.self)), .optionalText(prepared.map { String(decoding: $0.canonicalPacketJSON, as: UTF8.self) }),
                .optionalText(prepared?.packetSHA256), .optionalText(try prepared.map { _ in String(decoding: try attachment.setup.record.authorization.encodedJSON(), as: UTF8.self) }),
                prepared == nil ? .optionalInt64(nil) : .int64(policy.policy.automaticHandoffEnabled ? 1 : 0)])
    }
    private func requireNativeReadAdmissionUnlocked(_ admission: NativeSourceReadAdmission, attachment: AuthenticatedContinuityTaskAttachment,
        connection: ControlPlaneSQLiteConnection) throws -> NativeSourceRow {
        guard let row = try nativeSourceRowUnlocked(key: admission.request.key, connection: connection),
              row.id == admission.reservationID, row.managerID == admission.request.managerInstanceID,
              row.deadline == admission.deadline, row.chargedCalls == admission.chargedCalls else { throw NativeTaskCapabilityError.requestConflict }
        try validateNativeSourceRow(row, attachment: attachment, method: "fs_read", argumentSHA: admission.request.argumentsSHA256)
        return row
    }
    private func nativeReadResultBounds(_ bytes: Data, limits: NativeTaskSourceLimits,
        authorization: ContinuityIngressAuthorization, policy: BudgetPolicySelection) throws -> Int {
        try ContinuityIngressAcceptanceReceipt.validatePolicy(policy, authorization: authorization)
        guard bytes.count <= min(65_536, limits.maximumResultBytes, authorization.authorizationScope.maximumInlineOutputBytes, policy.policy.tools.maxResultBytes),
              let o = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(o.keys) == ["ok","is_error","payload"],
              let ok = o["ok"] as? Bool, let error = o["is_error"] as? Bool, ok != error,
              o["payload"] is [String: Any], try ForgeJSONCanonicalizationV1.data(from: o) == bytes else { throw NativeTaskCapabilityError.budgetExceeded }
        let tokens = try ContextBudgetMath.estimateTokens(serializedBytes: bytes.count, policy: ContextBudgetPolicy())
        guard tokens <= policy.policy.tools.maxRetainedResultTokens else { throw NativeTaskCapabilityError.budgetExceeded }
        return tokens
    }
    private func nativeReadReceiptUnlocked(_ row: NativeSourceRow, limits: NativeTaskSourceLimits,
        authorization: ContinuityIngressAuthorization, policy: BudgetPolicySelection, connection: ControlPlaneSQLiteConnection) throws -> NativeSourceReadReceipt {
        guard let receipt = try connection.first("SELECT result_json,result_sha256,result_tokens,completed_at,result_expires_at FROM native_source_requests WHERE reservation_id=?",
            bindings: [.text(row.id.uuidString.lowercased())], map: { r -> NativeSourceReadReceipt in
                guard let expiry = try r.strictText(4, maximumBytes: 20), expiry > ISO8601.string(from: clock.now()),
                      let json = try r.strictText(0, maximumBytes: 65_536) else { throw NativeTaskCapabilityError.resultExpired }
                let data = Data(json.utf8), tokens = try nativeReadResultBounds(Data(json.utf8), limits: limits, authorization: authorization, policy: policy)
                guard JSONSupport.sha256Hex(data) == (try r.strictText(1, maximumBytes: 64)), Int64(tokens) == r.int64(2) else { throw NativeTaskCapabilityError.integrityFailure }
                return .init(reservationID: row.id, key: row.key, taskID: row.taskID, resultSHA256: JSONSupport.sha256Hex(data), canonicalToolResultJSON: data,
                    estimatedResultTokens: tokens, chargedCalls: row.chargedCalls, completedAt: try NativeTaskValue.date(r.strictText(3, maximumBytes: 20)))
            }) else { throw NativeTaskCapabilityError.integrityFailure }
        return receipt
    }
    private func expireNativeReadPayloadsUnlocked(connection: ControlPlaneSQLiteConnection) throws {
        try connection.execute("""
            UPDATE native_source_requests SET result_json=NULL WHERE rowid IN
                (SELECT rowid FROM native_source_requests WHERE method='fs_read' AND result_json IS NOT NULL AND result_expires_at<=? LIMIT 32)
            """, bindings: [.text(ISO8601.string(from: clock.now()))])
    }
    private func nativePreparedCommitUnlocked(_ row: NativeSourceRow, authorization: ContinuityIngressAuthorization,
        connection: ControlPlaneSQLiteConnection) throws -> (PreparedContinuitySourceCommit, Bool) {
        guard let value = try connection.first("SELECT prepared_packet_json,packet_sha256,authorization_json,automatic_enabled,policy_json FROM native_source_requests WHERE reservation_id=?",
            bindings: [.text(row.id.uuidString.lowercased())], map: { r -> (PreparedContinuitySourceCommit, Bool) in
                guard let json = try r.strictText(0, maximumBytes: 262_144),
                      let authority = try r.strictText(2, maximumBytes: 32_768), Data(authority.utf8) == (try authorization.encodedJSON()),
                      let policyJSON = try r.strictText(4, maximumBytes: 32_768), (0...1).contains(r.int64(3)) else { throw NativeTaskCapabilityError.integrityFailure }
                let policy = try JSONDecoder().decode(BudgetPolicySelection.self, from: Data(policyJSON.utf8))
                try ContinuityIngressAcceptanceReceipt.validatePolicy(policy, authorization: authorization)
                guard policy.policy.automaticHandoffEnabled == (r.int64(3) == 1) else { throw NativeTaskCapabilityError.integrityFailure }
                let packet = try PreparedContinuitySourceCommit.storedSnapshot(from: Data(json.utf8))
                guard packet.packetSHA256 == (try r.strictText(1, maximumBytes: 64)), packet.finalize == (row.method == "session_handoff") else { throw NativeTaskCapabilityError.integrityFailure }
                return (packet, r.int64(3) == 1)
            }) else { throw NativeTaskCapabilityError.integrityFailure }
        return value
    }
    private func nativeCommitResultUnlocked(_ row: NativeSourceRow, prepared: PreparedContinuitySourceCommit,
        authorization: ContinuityIngressAuthorization, connection: ControlPlaneSQLiteConnection) throws -> ContinuityHandoffCommit {
        guard let result = try connection.first("SELECT result_json,result_sha256 FROM native_source_requests WHERE reservation_id=?",
            bindings: [.text(row.id.uuidString.lowercased())], map: { r -> ContinuityHandoffCommit in
                guard let json = try r.strictText(0, maximumBytes: NativeSourceCommitEvidence.maximumBytes),
                      JSONSupport.sha256Hex(Data(json.utf8)) == (try r.strictText(1, maximumBytes: 64)) else { throw NativeTaskCapabilityError.integrityFailure }
                return try NativeSourceCommitEvidence.decode(Data(json.utf8), prepared: prepared, authorization: authorization)
            }) else { throw NativeTaskCapabilityError.integrityFailure }
        return result
    }

    // MARK: - Native-approved continuity task authority

    /// Native authenticated setup only. A model's goal, assignment identifier,
    /// handoff contents or MCP client identity must never call this issuer.
    /// The caller correlation returned here stays in the verified native owner
    /// or adapter context; it is not serialized into MCP tool arguments.
    func authorizeContinuityTask(
        taskID: UUID = UUID(), projectID: ProjectID, expectedGeneration: ProjectGeneration,
        approvedAssignment: ContinuityTaskAssignment,
        callerContext: ToolInvocationContext, callerOwner: ProjectBindingOwner,
        cancellation: ToolCallCancellation? = nil
    ) throws -> AuthorizedContinuityTaskSetup {
        try controlledTransaction(cancellation: cancellation) { connection in
            try authorizeContinuityTaskUnlocked(taskID: taskID, projectID: projectID, expectedGeneration: expectedGeneration,
                approvedAssignment: approvedAssignment, callerContext: callerContext, callerOwner: callerOwner, connection: connection)
        }
    }

    private func authorizeContinuityTaskUnlocked(taskID: UUID, projectID: ProjectID, expectedGeneration: ProjectGeneration,
        approvedAssignment: ContinuityTaskAssignment, callerContext: ToolInvocationContext, callerOwner: ProjectBindingOwner,
        connection: ControlPlaneSQLiteConnection) throws -> AuthorizedContinuityTaskSetup {
        let assignmentData = try approvedAssignment.storedJSON()
        let timestamp = ISO8601.string(from: clock.now())
            let project = try requiredActiveProjectUnlocked(projectID, generation: expectedGeneration, connection: connection)
            let caller = try validatedContinuityCallerUnlocked(context: callerContext, owner: callerOwner, connection: connection)
            guard caller.projectID == projectID, caller.projectGeneration == expectedGeneration,
                  caller.runID == nil else {
                throw ContinuityTaskAuthorizationError.authorityMismatch
            }
            try Self.requireContinuityScope(approvedAssignment.authorizationScope,
                within: caller.authorizationScope, projectRoot: project.canonicalRoot)
            if let existing = try continuityTaskUnlocked(taskID, connection: connection) {
                try requireSourceMutationAdmissionUnlocked(existing.authorization, connection: connection)
                guard existing.state == .active else { throw ContinuityTaskAuthorizationError.revoked }
                guard existing.authorization.projectID == projectID,
                      existing.authorization.projectGeneration == expectedGeneration,
                      existing.assignment == approvedAssignment else {
                    throw ContinuityTaskAuthorizationError.assignmentConflict
                }
                let current = try validatedContinuityTaskUnlocked(existing.authorization, connection: connection)
                try retainSourceDispatchOriginUnlocked(taskID: taskID, caller: caller, timestamp: timestamp, existingTask: true, connection: connection)
                return AuthorizedContinuityTaskSetup(record: current,
                    correlation: try .nativeSetupResult(record: current, caller: caller, context: callerContext))
            }
            guard try connection.scalarInt("SELECT COUNT(*) FROM continuity_task_authorizations") < Self.maximumContinuityTaskAuthorizations,
                  try connection.scalarInt("SELECT COUNT(*) FROM continuity_task_authorizations WHERE project_id=? AND state='active'",
                    bindings: [.text(projectID.description)]) < Self.maximumActiveContinuityTasksPerProject else {
                throw ContinuityTaskAuthorizationError.capacityExceeded
            }
            let sourceOwner = ProjectBindingOwner(kind: .agentSession, id: taskID.uuidString.lowercased())
            guard try bindingUnlocked(owner: sourceOwner, includeInactive: true, connection: connection) == nil else {
                throw ContinuityTaskAuthorizationError.assignmentConflict
            }
            let sourceBindingID = UUID()
            let authority = try ContinuityIngressAuthorization(projectID: projectID, projectGeneration: expectedGeneration,
                sourceBindingID: sourceBindingID, taskID: taskID, assignmentID: approvedAssignment.assignmentID,
                assignmentSHA256: approvedAssignment.assignmentSHA256, authorizationScope: approvedAssignment.authorizationScope)
            let authorityData = try authority.encodedJSON()
            try connection.execute(
                """
                INSERT INTO project_bindings(binding_id,owner_kind,owner_id,project_id,project_generation,
                    run_id,authorization_scope_json,active,created_at,updated_at)
                VALUES(?,'agent_session',?,?,?,NULL,?,1,?,?)
                """,
                bindings: [.text(sourceBindingID.uuidString.lowercased()), .text(sourceOwner.id), .text(projectID.description),
                    .int64(try Self.sqliteGeneration(expectedGeneration)), .text(try Self.scopeJSON(approvedAssignment.authorizationScope)),
                    .text(timestamp), .text(timestamp)])
            try connection.execute(
                """
                INSERT INTO continuity_task_authorizations(task_id,project_id,project_generation,source_binding_id,
                    assignment_id,assignment_sha256,assignment_json,assignment_snapshot_sha256,
                    authorization_json,authorization_sha256,state,revision,run_id,created_at,revoked_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,'active',1,NULL,?,NULL)
                """,
                bindings: [.text(taskID.uuidString.lowercased()), .text(projectID.description),
                    .int64(try Self.sqliteGeneration(expectedGeneration)), .text(sourceBindingID.uuidString.lowercased()),
                    .text(approvedAssignment.assignmentID), .text(approvedAssignment.assignmentSHA256),
                    .text(String(decoding: assignmentData, as: UTF8.self)), .text(JSONSupport.sha256Hex(assignmentData)),
                    .text(String(decoding: authorityData, as: UTF8.self)), .text(JSONSupport.sha256Hex(authorityData)), .text(timestamp)])
            try appendAutonomyEventUnlocked(runID: nil, projectID: projectID,
                eventType: "continuity_task_authorized", severity: .info, summary: "Native task assignment was durably authorized",
                metadata: ["task_id": taskID.uuidString.lowercased(), "source_binding_id": sourceBindingID.uuidString.lowercased(),
                           "assignment_sha256": approvedAssignment.assignmentSHA256], connection: connection)
            let record = try validatedContinuityTaskUnlocked(authority, connection: connection)
            try retainSourceDispatchOriginUnlocked(taskID: taskID, caller: caller, timestamp: timestamp, connection: connection)
            return AuthorizedContinuityTaskSetup(record: record,
                correlation: try .nativeSetupResult(record: record, caller: caller, context: callerContext))
    }

    /// Reattaches an explicitly selected native task after process restart.
    /// Caller identity comes from the authenticated native attachment, never
    /// model arguments or a search for a latest/only task on a shared transport.
    /// This is a read and correlation issuance only: source mutation fences,
    /// approvals, assignments, bindings, runs and operation receipts stay intact.
    func reattachContinuityTask(
        taskID: UUID, projectID: ProjectID, expectedGeneration: ProjectGeneration,
        callerContext: ToolInvocationContext, callerOwner: ProjectBindingOwner,
        cancellation: ToolCallCancellation? = nil
    ) throws -> AuthorizedContinuityTaskSetup {
        try controlledTransaction(cancellation: cancellation) { connection in
            let project = try requiredActiveProjectUnlocked(projectID, generation: expectedGeneration, connection: connection)
            let caller = try validatedContinuityCallerUnlocked(context: callerContext, owner: callerOwner, connection: connection)
            guard caller.projectID == projectID, caller.projectGeneration == expectedGeneration, caller.runID == nil,
                  try connection.scalarInt("""
                    SELECT COUNT(*) FROM continuity_task_authorizations WHERE task_id=? AND project_id=? AND project_generation=?
                    """, bindings: [.text(taskID.uuidString.lowercased()), .text(projectID.description),
                        .int64(try Self.sqliteGeneration(expectedGeneration))]) == 1 else {
                throw ContinuityTaskAuthorizationError.authorityMismatch
            }
            // Authenticate the immutable original caller before reading any
            // assignment/source/run snapshot, including same-project tasks.
            // existingTask forbids inserting or repairing a missing origin.
            try retainSourceDispatchOriginUnlocked(taskID: taskID, caller: caller, timestamp: "", existingTask: true, connection: connection)
            guard let stored = try continuityTaskUnlocked(taskID, connection: connection) else {
                throw ContinuityTaskAuthorizationError.authorityMismatch
            }
            let record = try validatedContinuityTaskUnlocked(stored.authorization, allowTerminalRun: true, connection: connection)
            guard record.authorization.projectID == projectID, record.authorization.projectGeneration == expectedGeneration else {
                throw ContinuityTaskAuthorizationError.authorityMismatch
            }
            try Self.requireContinuityScope(record.authorization.authorizationScope,
                within: caller.authorizationScope, projectRoot: project.canonicalRoot)
            return AuthorizedContinuityTaskSetup(record: record,
                correlation: try .nativeSetupResult(record: record, caller: caller, context: callerContext))
        }
    }

    /// Holds the existing writer fence across a bounded source-store transaction.
    /// The closure must not suspend or call this repository. Its source commit,
    /// including the outbox row, remains authoritative if later delivery fails.
    func withAuthorizedContinuityTask<Value: Sendable>(
        taskID: UUID, correlation: VerifiedContinuityTaskCorrelation?,
        context: ToolInvocationContext, owner: ProjectBindingOwner,
        cancellation: ToolCallCancellation? = nil,
        mutation: @Sendable (ContinuityIngressAuthorization) throws -> Value
    ) throws -> Value {
        guard let correlation else { throw ContinuityTaskAuthorizationError.taskCorrelationRequired }
        return try controlledTransaction(cancellation: cancellation, checkCancellationBeforeCommit: false) { connection in
            guard correlation.taskID == taskID, correlation.callerOwner == owner,
                  correlation.callerContext == context else {
                throw ContinuityTaskAuthorizationError.authorityMismatch
            }
            try requireNativeCorrelationUnlocked(correlation, connection: connection)
            let caller = try validatedContinuityCallerUnlocked(context: context, owner: owner, connection: connection)
            guard let stored = try continuityTaskUnlocked(taskID, connection: connection) else {
                throw ContinuityTaskAuthorizationError.authorityMismatch
            }
            let record = try validatedContinuityTaskUnlocked(stored.authorization, connection: connection)
            let authority = record.authorization
            try requireSourceMutationAdmissionUnlocked(authority, connection: connection)
            guard correlation.callerBindingID == caller.bindingID,
                  correlation.sourceBindingID == authority.sourceBindingID,
                  correlation.projectID == authority.projectID, correlation.projectGeneration == authority.projectGeneration,
                  caller.projectID == authority.projectID, caller.projectGeneration == authority.projectGeneration,
                  JSONSupport.sha256Hex(try authority.encodedJSON()) == correlation.authorizationSHA256,
                  context.runID == nil || record.runID == context.runID else {
                throw ContinuityTaskAuthorizationError.authorityMismatch
            }
            let project = try requiredActiveProjectUnlocked(authority.projectID, generation: authority.projectGeneration, connection: connection)
            try Self.requireContinuityScope(authority.authorizationScope, within: caller.authorizationScope, projectRoot: project.canonicalRoot)
            try cancellation?.checkCancellation()
            let value = try mutation(authority)
            cancellation?.promoteCommittedResultIfPresent(value)
            connection.finishRequestCancellationWindow()
            return value
        }
    }

    /// Delivery and provider admission independently revalidate the frozen source
    /// snapshot before looking up a duplicate operation or revealing its state.
    func validateContinuityIngressAuthorization(
        _ authorization: ContinuityIngressAuthorization,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityTaskAuthorizationRecord {
        try controlledTransaction(cancellation: cancellation) { connection in
            try validatedContinuityTaskUnlocked(authorization, connection: connection)
        }
    }

    /// Native correlation and its immutable original caller are checked before
    /// the requested operation's metadata or payload is materialized.
    func validateContinuityOperationControlAuthority(taskID: UUID, correlation: VerifiedContinuityTaskCorrelation?,
        context: ToolInvocationContext, owner: ProjectBindingOwner, cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityTaskAuthorizationRecord {
        try controlledTransaction(cancellation: cancellation) { connection in
            try continuityControlOwnerUnlocked(taskID: taskID, correlation: correlation, context: context, owner: owner, connection: connection)
        }
    }

    func continuityOperationStatus(operationID: UUID, taskID: UUID,
        correlation: VerifiedContinuityTaskCorrelation?, context: ToolInvocationContext, owner: ProjectBindingOwner,
        cancellation: ToolCallCancellation? = nil,
        readProgress: @Sendable (ContinuityIngressAcceptanceReceipt) throws -> ContinuityOperationProgressEvidence? = { _ in nil }
    ) throws -> ContinuityOperationStatus {
        try controlledTransaction(cancellation: cancellation) { connection in
            let task = try continuityControlOwnerUnlocked(taskID: taskID, correlation: correlation,
                context: context, owner: owner, connection: connection)
            let acceptance = try ownedContinuityOperationUnlocked(operationID, task: task, connection: connection)
            let progress = try continuityCancellationUnlocked(acceptance, connection: connection) == nil ? readProgress(acceptance) : nil
            return try continuityOperationStatusUnlocked(acceptance, progress: progress, connection: connection)
        }
    }

    /// The FULL request commit precedes all asynchronous cancellation cleanup.
    /// It changes neither the current run state nor any later operation.
    func requestContinuityOperationCancellation(operationID: UUID, taskID: UUID,
        correlation: VerifiedContinuityTaskCorrelation?, context: ToolInvocationContext, owner: ProjectBindingOwner,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityOperationCancellationResult {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let task = try continuityControlOwnerUnlocked(taskID: taskID, correlation: correlation,
                context: context, owner: owner, connection: connection)
            let acceptance = try ownedContinuityOperationUnlocked(operationID, task: task, connection: connection)
            let current = try continuityOperationStatusUnlocked(acceptance, progress: nil, connection: connection)
            if current.terminalReceipt != nil { return .init(disposition: .alreadyTerminal, snapshot: current, request: nil) }
            if let existing = try continuityCancellationUnlocked(acceptance, connection: connection) {
                return .init(disposition: .alreadyRequested, snapshot: current, request: existing.request)
            }
            guard let run = try autonomousRunUnlocked(acceptance.runID, connection: connection), run.activeOperationID == operationID else {
                throw ContinuityOperationControlError.conflict
            }
            guard try connection.scalarInt("SELECT COUNT(*) FROM continuity_operation_cancellations") < Self.maximumContinuityIngressAcceptances else {
                throw ContinuityOperationControlError.invalidRequest
            }
            let request = try ContinuityOperationCancellationRequest(acceptance: acceptance, requestedAt: ISO8601.string(from: clock.now()))
            try connection.execute("""
                INSERT INTO continuity_operation_cancellations(operation_id,run_id,task_id,project_id,project_generation,
                    acceptance_receipt_sha256,request_json,request_sha256,requested_at)
                VALUES(?,?,?,?,?,?,?,?,?)
                """, bindings: [.text(operationID.uuidString.lowercased()), .text(acceptance.runID.description),
                    .text(taskID.uuidString.lowercased()), .text(acceptance.authorization.projectID.description),
                    .int64(try Self.sqliteGeneration(acceptance.authorization.projectGeneration)), .text(acceptance.receiptSHA256),
                    .text(String(decoding: request.canonicalRequestJSON, as: UTF8.self)), .text(request.requestSHA256), .text(request.requestedAt)])
            return .init(disposition: .requested,
                snapshot: try continuityOperationStatusUnlocked(acceptance, progress: nil, connection: connection), request: request)
        }
    }

    /// Only bounded identifiers are scanned. Malformed rows advance the cursor
    /// and are diagnosed individually; they never disclose another source.
    func pendingContinuityOperationCancellations(afterRowID: Int64? = nil, limit: Int = 32,
        cancellation: ToolCallCancellation? = nil) throws -> ContinuityOperationCancellationPage {
        guard (1...64).contains(limit), afterRowID == nil || afterRowID! >= 0 else { throw ContinuityOperationControlError.invalidRequest }
        return try controlledTransaction(cancellation: cancellation) { connection in
            let rows = try connection.all(Self.continuityCancellationMetadataQuery + " WHERE rowid>? AND receipt_json IS NULL AND quarantined=0 AND (retry_at IS NULL OR retry_at<=?) ORDER BY rowid LIMIT ?",
                bindings: [.int64(afterRowID ?? 0), .text(ISO8601.string(from: clock.now())), .int64(Int64(limit))]) { row in
                    (row.int64(0), Result { try Self.decodeContinuityCancellationReference(row) })
                }
            var references: [ContinuityOperationCancellationReference] = []
            for (rowID, result) in rows {
                try cancellation?.checkCancellation()
                switch result {
                case .success(let reference):
                    let now = clock.now(), timestamp = ISO8601.string(from: clock.now())
                    guard let limits = try connection.first("SELECT attempts,requested_at FROM continuity_operation_cancellations WHERE rowid=?",
                        bindings: [.int64(rowID)], map: { ($0.int64(0), try $0.strictText(1, maximumBytes: 128)) }),
                          (0...8).contains(limits.0), let requested = limits.1.flatMap(ISO8601.date(from:)) else {
                        try connection.execute("UPDATE continuity_operation_cancellations SET quarantined=1,error_code='integrity_failure' WHERE rowid=?", bindings: [.int64(rowID)])
                        continue
                    }
                    let leased = try connection.scalarInt("SELECT COUNT(*) FROM run_leases WHERE run_id=? AND expires_at>?",
                        bindings: [.text(reference.runID.description), .text(timestamp)]) > 0
                    if !leased && (limits.0 >= 8 || now >= requested.addingTimeInterval(86_400)) {
                        try connection.execute("UPDATE continuity_operation_cancellations SET quarantined=1,error_code='retry_window_exceeded',retry_at=NULL WHERE rowid=?", bindings: [.int64(rowID)])
                    } else {
                        // A live owner must still discover its own cancellation
                        // so it can quiesce before acquiring the cleanup lease.
                        // Metadata grants no execution or lease authority.
                        references.append(reference)
                    }
                case .failure:
                    try connection.execute("UPDATE continuity_operation_cancellations SET quarantined=1,error_code='integrity_failure' WHERE rowid=?", bindings: [.int64(rowID)])
                }
            }
            return .init(references: references, nextRowID: rows.count == limit ? rows.last?.0 : nil)
        }
    }

    func validateContinuityOperationCancellation(reference: ContinuityOperationCancellationReference,
        cancellation: ToolCallCancellation? = nil) throws -> Bool {
        try controlledTransaction(cancellation: cancellation) { connection in
            _ = try continuityCancellationMetadataAuthorityUnlocked(reference, connection: connection)
            return try connection.scalarInt("SELECT COUNT(*) FROM continuity_operation_cancellations WHERE operation_id=? AND receipt_json IS NULL AND quarantined=0 AND (retry_at IS NULL OR retry_at<=?)",
                bindings: [.text(reference.operationID.uuidString.lowercased()), .text(ISO8601.string(from: clock.now()))]) == 1
        }
    }

    /// This lease can clean up the exact durable request even if an ordinary
    /// operator cancellation already made the run terminal. It grants no work.
    func acquireContinuityOperationCancellationLease(reference: ContinuityOperationCancellationReference,
        ownerID: String, policy: RunLeasePolicy = .init(), cancellation: ToolCallCancellation? = nil) throws -> RunLease {
        try Self.validateLeaseOwner(ownerID); try Self.validate(policy)
        return try controlledTransaction(cancellation: cancellation) { connection in
            _ = try continuityCancellationMetadataAuthorityUnlocked(reference, connection: connection)
            let now = clock.now(), timestamp = ISO8601.string(from: clock.now())
            let expires = ISO8601.string(from: now.addingTimeInterval(policy.duration))
            guard try connection.scalarInt("SELECT COUNT(*) FROM continuity_operation_cancellations WHERE operation_id=? AND receipt_json IS NULL AND quarantined=0 AND (retry_at IS NULL OR retry_at<=?)",
                bindings: [.text(reference.operationID.uuidString.lowercased()), .text(timestamp)]) == 1 else { throw ContinuityOperationControlError.conflict }
            if let existing = try runLeaseUnlocked(reference.runID, connection: connection) {
                if (existing.expirationDate ?? .distantPast) > now {
                    guard existing.ownerID == ownerID else { throw AutonomyError.leaseConflict(ownerID: existing.ownerID, epoch: existing.epoch) }
                    return existing
                }
                guard existing.epoch < UInt64(Int64.max),
                      try connection.execute("UPDATE run_leases SET lease_owner=?,lease_epoch=?,acquired_at=?,renewed_at=?,expires_at=? WHERE run_id=? AND lease_epoch=? AND expires_at<=?",
                        bindings: [.text(ownerID), .int64(Int64(existing.epoch + 1)), .text(timestamp), .text(timestamp), .text(expires),
                            .text(reference.runID.description), .int64(Int64(existing.epoch)), .text(timestamp)]) == 1 else { throw AutonomyError.staleLease }
            } else {
                try connection.execute("INSERT INTO run_leases(run_id,lease_owner,lease_epoch,acquired_at,renewed_at,expires_at) VALUES(?,?,1,?,?,?)",
                    bindings: [.text(reference.runID.description), .text(ownerID), .text(timestamp), .text(timestamp), .text(expires)])
            }
            guard let lease = try runLeaseUnlocked(reference.runID, connection: connection) else { throw AutonomyError.staleLease }
            return lease
        }
    }

    func claimContinuityOperationCancellation(reference: ContinuityOperationCancellationReference, lease: RunLease,
        cancellation: ToolCallCancellation? = nil) throws -> ContinuityOperationCancellationClaim {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let claim = try continuityCancellationClaimUnlocked(reference, lease: lease, connection: connection)
            guard let stored = try continuityCancellationUnlocked(claim.acceptance, connection: connection) else { throw ContinuityOperationControlError.notFound }
            if stored.receipt != nil { return claim }
            let now = clock.now(), timestamp = ISO8601.string(from: clock.now())
            guard !stored.blocked, (stored.retryAt.flatMap(ISO8601.date(from:)) ?? .distantPast) <= now,
                  let requested = ISO8601.date(from: claim.request.requestedAt), now < requested.addingTimeInterval(86_400) else {
                throw ContinuityOperationControlError.conflict
            }
            let sameClaim = try connection.scalarInt("SELECT COUNT(*) FROM continuity_operation_cancellations WHERE operation_id=? AND claim_owner=? AND claim_epoch=?",
                bindings: [.text(reference.operationID.uuidString.lowercased()), .text(lease.ownerID), .int64(Int64(lease.epoch))]) == 1
            if !sameClaim {
                guard try connection.execute("UPDATE continuity_operation_cancellations SET attempts=attempts+1,claim_owner=?,claim_epoch=?,retry_at=? WHERE operation_id=? AND attempts<8 AND receipt_json IS NULL",
                    bindings: [.text(lease.ownerID), .int64(Int64(lease.epoch)), .text(timestamp), .text(reference.operationID.uuidString.lowercased())]) == 1 else {
                    throw ContinuityOperationControlError.conflict
                }
            }
            return claim
        }
    }

    func recordContinuityOperationCancellationFailure(reference: ContinuityOperationCancellationReference, lease: RunLease,
        failure: ContinuityOperationCancellationFailure, retryAfter: TimeInterval? = nil,
        cancellation: ToolCallCancellation? = nil) throws {
        guard retryAfter == nil || (retryAfter!.isFinite && (0...3_600).contains(retryAfter!)) else { throw ContinuityOperationControlError.invalidRequest }
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let claim = try continuityCancellationClaimUnlocked(reference, lease: lease, connection: connection)
            guard try continuityCancellationUnlocked(claim.acceptance, connection: connection)?.receipt == nil else { return }
            try deferContinuityCancellationUnlocked(claim, lease: lease, failure: failure, retryAfter: retryAfter, connection: connection)
        }
    }

    private func deferContinuityCancellationUnlocked(_ claim: ContinuityOperationCancellationClaim, lease: RunLease,
        failure: ContinuityOperationCancellationFailure, retryAfter: TimeInterval?, connection: ControlPlaneSQLiteConnection) throws {
        guard let row = try connection.first("SELECT attempts,claim_owner,claim_epoch FROM continuity_operation_cancellations WHERE operation_id=?",
            bindings: [.text(claim.reference.operationID.uuidString.lowercased())], map: { ($0.int64(0), try $0.strictText(1, maximumBytes: 512), $0.int64(2)) }),
              row.1 == lease.ownerID, row.2 > 0, UInt64(row.2) == lease.epoch else { throw ContinuityOperationControlError.conflict }
        let now = clock.now()
        guard let requested = ISO8601.date(from: claim.request.requestedAt) else { throw ContinuityOperationControlError.integrityFailure }
        let delay = max(failure == .providerOutcomeUnknown || failure == .interrupted ? 660 : 0,
            retryAfter ?? min(300, 5 * pow(2, Double(max(0, row.0 - 1)))))
        let retry = now.addingTimeInterval(delay)
        let blocked = row.0 >= 8 || retry > requested.addingTimeInterval(86_400) || failure == .integrityFailure
        try connection.execute("""
            UPDATE continuity_operation_cancellations SET error_code=?,retry_at=?,quarantined=?,claim_owner=NULL,claim_epoch=NULL
            WHERE operation_id=? AND request_sha256=? AND receipt_json IS NULL
            """, bindings: [.text(failure.rawValue), .optionalText(blocked ? nil : ISO8601.string(from: retry)), .int64(blocked ? 1 : 0),
                .text(claim.reference.operationID.uuidString.lowercased()), .text(claim.request.requestSHA256)])
    }

    private func continuityCancellationHasUnknownEffectsUnlocked(_ claim: ContinuityOperationCancellationClaim,
        connection: ControlPlaneSQLiteConnection) throws -> Bool {
        // An intent can have an unknown external outcome after process loss.
        // Cancellation never manufactures a terminal response for these rows.
        let run = ControlPlaneSQLiteBinding.text(claim.acceptance.runID.description)
        return try connection.scalarInt("SELECT COUNT(*) FROM provider_turns WHERE run_id=? AND state IN ('intent','submitted','streaming','ambiguous','retry_wait')", bindings: [run]) > 0
            || connection.scalarInt("SELECT COUNT(*) FROM tool_invocations WHERE run_id=? AND state IN ('intent','executing','ambiguous')", bindings: [run]) > 0
            || connection.scalarInt("SELECT COUNT(*) FROM execution_jobs WHERE run_id=? AND state IN ('queued','running','cancelling')", bindings: [run]) > 0
    }

    func completeContinuityOperationCancellation(claim: ContinuityOperationCancellationClaim, lease: RunLease,
        cancellation: ToolCallCancellation? = nil,
        writeCanonical: @Sendable (ContinuityOperationCancellationRequest, ContinuityIngressAcceptanceReceipt) throws -> ContinuityOperationCancellationEvidence
    ) throws -> ContinuityOperationCancellationReceipt {
        let outcome: Result<ContinuityOperationCancellationReceipt, Error> = try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            guard try continuityCancellationClaimUnlocked(claim.reference, lease: lease, connection: connection) == claim,
                  let stored = try continuityCancellationUnlocked(claim.acceptance, connection: connection) else { throw ContinuityOperationControlError.conflict }
            if let receipt = stored.receipt { return .success(receipt) }
            guard try connection.scalarInt("SELECT COUNT(*) FROM continuity_operation_cancellations WHERE operation_id=? AND claim_owner=? AND claim_epoch=?",
                bindings: [.text(claim.reference.operationID.uuidString.lowercased()), .text(lease.ownerID), .int64(Int64(lease.epoch))]) == 1 else {
                throw ContinuityOperationControlError.conflict
            }
            let evidence = try writeCanonical(claim.request, claim.acceptance)
            let receipt = try ContinuityOperationCancellationReceipt(request: claim.request, evidence: evidence)
            guard try continuityCancellationClaimUnlocked(claim.reference, lease: lease, connection: connection) == claim else {
                throw ContinuityOperationControlError.conflict
            }
            if try continuityCancellationHasUnknownEffectsUnlocked(claim, connection: connection) {
                try deferContinuityCancellationUnlocked(claim, lease: lease, failure: .providerOutcomeUnknown, retryAfter: 660, connection: connection)
                return .failure(ContinuityOperationControlError.reconciliationRequired)
            }
            try connection.execute("""
                UPDATE continuity_operation_cancellations SET receipt_json=?,receipt_sha256=?,completed_at=?
                WHERE operation_id=? AND request_sha256=? AND receipt_json IS NULL
                """, bindings: [.text(String(decoding: receipt.canonicalReceiptJSON, as: UTF8.self)), .text(receipt.receiptSHA256),
                    .text(receipt.recordedAt), .text(claim.reference.operationID.uuidString.lowercased()), .text(claim.request.requestSHA256)])
            let timestamp = ISO8601.string(from: clock.now())
            guard try connection.execute("UPDATE autonomous_runs SET state='cancelled',revision=revision+1,updated_at=? WHERE run_id=? AND active_operation_id=?",
                bindings: [.text(timestamp), .text(claim.acceptance.runID.description), .text(claim.acceptance.operationID.uuidString.lowercased())]) == 1 else {
                throw ContinuityOperationControlError.conflict
            }
            try connection.execute("UPDATE continuity_ingress_holds SET state='cancelled',updated_at=? WHERE operation_id=? AND run_id=?",
                bindings: [.text(timestamp), .text(claim.acceptance.operationID.uuidString.lowercased()), .text(claim.acceptance.runID.description)])
            try connection.execute("UPDATE project_bindings SET active=0,updated_at=? WHERE owner_kind='provider_session' AND owner_id IN (SELECT session_id FROM provider_sessions WHERE run_id=? AND operation_id=?)",
                bindings: [.text(timestamp), .text(claim.acceptance.runID.description), .text(claim.acceptance.operationID.uuidString.lowercased())])
            return .success(receipt)
        }
        return try outcome.get()
    }

    func submitExplicitContinuityIngress(taskID: UUID, correlation: VerifiedContinuityTaskCorrelation?,
        context: ToolInvocationContext, owner: ProjectBindingOwner, requestID: UUID, continuityID: String,
        policySelection: BudgetPolicySelection, cancellation: ToolCallCancellation? = nil,
        readSource: @Sendable (ContinuityIngressAuthorization) throws -> ContinuityHandoffRevision
    ) throws -> ContinuityExplicitStartReceipt {
        guard !continuityID.isEmpty, continuityID.utf8.count <= 256, !continuityID.contains("\0"),
              let correlation else { throw ContinuityTaskAuthorizationError.taskCorrelationRequired }
        return try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            guard correlation.taskID == taskID, correlation.callerOwner == owner, correlation.callerContext == context else {
                throw ContinuityTaskAuthorizationError.authorityMismatch
            }
            try requireNativeCorrelationUnlocked(correlation, connection: connection)
            let caller = try validatedContinuityCallerUnlocked(context: context, owner: owner, connection: connection)
            guard let stored = try continuityTaskUnlocked(taskID, connection: connection) else {
                throw ContinuityTaskAuthorizationError.authorityMismatch
            }
            let task = try validatedContinuityTaskUnlocked(stored.authorization, connection: connection)
            let authorization = task.authorization
            guard correlation.callerBindingID == caller.bindingID, correlation.sourceBindingID == authorization.sourceBindingID,
                  correlation.projectID == authorization.projectID, correlation.projectGeneration == authorization.projectGeneration,
                  caller.projectID == authorization.projectID, caller.projectGeneration == authorization.projectGeneration,
                  correlation.authorizationSHA256 == JSONSupport.sha256Hex(try authorization.encodedJSON()),
                  context.runID == nil || context.runID == task.runID else { throw ContinuityTaskAuthorizationError.authorityMismatch }
            try ContinuityIngressAcceptanceReceipt.validatePolicy(policySelection, authorization: authorization)
            try retainSourceDispatchOriginUnlocked(taskID: taskID, caller: caller, timestamp: ISO8601.string(from: clock.now()), existingTask: true, connection: connection)
            try requireSourceDispatchIdentityUnlocked(authorization, connection: connection)
            if let replay = try connection.first("""
                SELECT task_id,continuity_id,operation_id,receipt_sha256 FROM continuity_explicit_start_requests WHERE request_id=?
                """, bindings: [.text(requestID.uuidString.lowercased())], map: { row in
                    (try row.strictText(0, maximumBytes: 36), try row.strictText(1, maximumBytes: 256),
                     try row.strictText(2, maximumBytes: 36), try row.strictText(3, maximumBytes: 64))
                }) {
                guard replay.0 == taskID.uuidString.lowercased(), replay.1 == continuityID,
                      let id = replay.2.flatMap(UUID.init(uuidString:)),
                      let acceptance = try acceptanceForOperationUnlocked(id, connection: connection),
                      acceptance.authorization == authorization, acceptance.receiptSHA256 == replay.3,
                      let permit = try explicitStartPermitUnlocked(acceptance: acceptance, connection: connection) else {
                    throw ContinuitySourceActivationError.conflict
                }
                try requireContinuityOperationNotCancelledUnlocked(acceptance.operationID, connection: connection)
                return .init(acceptance: acceptance, permit: permit)
            }
            guard try connection.scalarInt("SELECT COUNT(*) FROM continuity_explicit_start_requests") < 4_096 else {
                throw ContinuityIngressError.capacityExceeded("explicit request mappings")
            }
            if let journal = try connection.first("SELECT conversation_id,state FROM native_source_conversations WHERE task_id=?",
                bindings: [.text(taskID.uuidString.lowercased())], map: { (try $0.strictText(0, maximumBytes: 36),try $0.strictText(1, maximumBytes: 32)) }) {
                guard let cid = journal.0, journal.1 == "source_fenced",
                      try connection.scalarInt("""
                        SELECT COUNT(*) FROM native_source_provider_calls c JOIN native_source_requests r ON r.reservation_id=c.reservation_id
                        WHERE c.conversation_id=? AND c.ready_handoff=1 AND c.output_json IS NOT NULL AND r.state='completed'
                            AND json_extract(r.prepared_packet_json,'$.meta.id')=?
                        """, bindings: [.text(cid),.text(continuityID)]) == 1 else { throw NativeSourceConversationError.ownerManaged }
            }
            let source = try readSource(authorization)
            guard source.authorization == authorization, source.identity.continuityID == continuityID else {
                throw ContinuityIngressError.authorityMismatch
            }
            try cancellation?.checkCancellation()
            _ = try validatedContinuityTaskUnlocked(authorization, connection: connection)
            let identity = try ContinuityIngressOperationIdentity(revision: source)
            let acceptance = try acceptContinuityIngressUnlocked(source: source, operationID: identity.operationID,
                policySelection: policySelection, connection: connection)
            let permit: ContinuityExplicitStartPermit
            if let existing = try explicitStartPermitUnlocked(acceptance: acceptance, connection: connection) { permit = existing }
            else {
                guard try connection.scalarInt("SELECT COUNT(*) FROM continuity_explicit_start_permits") < 1_024 else {
                    throw ContinuityIngressError.capacityExceeded("explicit operation permits")
                }
                permit = try .init(requestID: requestID, acceptance: acceptance, callerBindingID: caller.bindingID,
                    issuedAt: ISO8601.string(from: clock.now()))
                try connection.execute("""
                    INSERT INTO continuity_explicit_start_permits(operation_id,receipt_sha256,permit_json,permit_sha256) VALUES(?,?,?,?)
                    """, bindings: [.text(acceptance.operationID.uuidString.lowercased()), .text(acceptance.receiptSHA256),
                        .text(String(decoding: permit.canonicalPermitJSON, as: UTF8.self)), .text(permit.permitSHA256)])
            }
            try connection.execute("""
                INSERT INTO continuity_explicit_start_requests(request_id,task_id,continuity_id,operation_id,receipt_sha256) VALUES(?,?,?,?,?)
                """, bindings: [.text(requestID.uuidString.lowercased()), .text(taskID.uuidString.lowercased()), .text(continuityID),
                    .text(acceptance.operationID.uuidString.lowercased()), .text(acceptance.receiptSHA256)])
            return .init(acceptance: acceptance, permit: permit)
        }
    }

    func validateContinuitySourceStartAuthority(acceptance: ContinuityIngressAcceptanceReceipt,
        lease: RunLease? = nil, policySelection: BudgetPolicySelection, cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuitySourceStartAuthority {
        try controlledTransaction(cancellation: cancellation) { connection in
            try validateSourceStartAuthorityUnlocked(acceptance: acceptance, lease: lease,
                policySelection: policySelection, connection: connection)
        }
    }

    /// Accepts an immutable source revision without starting provider work. The
    /// task/run link, canonical receipt and execution hold share one commit.
    /// Every acceptance originates at this FULL durability boundary; redelivery
    /// returns that same durable receipt before the source may acknowledge it.
    /// Policy is observed provenance; bootstrap must obtain current policy again.
    func acceptContinuityIngress(
        source: ContinuityHandoffRevision, operationID: UUID,
        policySelection: BudgetPolicySelection, cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityIngressAcceptanceReceipt {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            try acceptContinuityIngressUnlocked(source: source, operationID: operationID,
                policySelection: policySelection, connection: connection)
        }
    }

    private func acceptContinuityIngressUnlocked(source: ContinuityHandoffRevision, operationID: UUID,
        policySelection: BudgetPolicySelection, connection: ControlPlaneSQLiteConnection) throws -> ContinuityIngressAcceptanceReceipt {
        // Live authority precedes duplicate lookup or disclosure.
        let task = try validatedContinuityTaskUnlocked(source.authorization, connection: connection)
        let identity = try ContinuityIngressOperationIdentity(revision: source)
        guard source.resumeReady, identity.operationID == operationID else {
            throw ContinuityIngressError.invalidRequest("operation_identity")
        }
        try requireContinuityOperationNotCancelledUnlocked(operationID, connection: connection)
        try ContinuityIngressAcceptanceReceipt.validatePolicy(policySelection, authorization: source.authorization)
        if let existing = try continuityIngressAcceptanceUnlocked(operationID: operationID,
            keySHA256: identity.keySHA256, connection: connection) {
            guard existing.operationID == operationID, existing.keySHA256 == identity.keySHA256,
                  existing.source == source, task.runID == existing.runID else {
                throw ContinuityIngressError.deliveryConflict
            }
            try validateContinuityIngressHoldUnlocked(receipt: existing, connection: connection)
            return existing
        }
        guard try connection.scalarInt("SELECT COUNT(*) FROM continuity_ingress_acceptances")
                < Self.maximumContinuityIngressAcceptances else {
            throw ContinuityIngressError.capacityExceeded("manager acceptance rows")
        }
        let timestamp = ISO8601.string(from: clock.now())
        let runID: RunID
        if let existingRunID = task.runID {
            try requireNoActiveContinuityIngressHoldUnlocked(existingRunID, connection: connection)
            guard let run = try autonomousRunUnlocked(existingRunID, connection: connection),
                  !run.state.isTerminal, run.state != .cancelRequested,
                  run.activeOperationID == nil else {
                throw ContinuityIngressError.deliveryConflict
            }
            // Preserve advanced work, remaining run-wide budget ledgers and
            // actual predecessor identity. Holding adds no synthetic usage.
            let changed = try connection.execute(
                "UPDATE autonomous_runs SET state='awaiting_bootstrap',active_operation_id=?,revision=revision+1,updated_at=? WHERE run_id=? AND revision=?",
                bindings: [.text(operationID.uuidString.lowercased()), .text(timestamp),
                    .text(existingRunID.description), .int64(Int64(run.revision))])
            guard changed == 1 else { throw AutonomyError.transitionConflict }
            runID = existingRunID
        } else {
            let assignment = task.assignment
            // AutonomousRunRequest explicitly derives adapter_id metadata;
            // the immutable approved assignment remains separately retained.
            let request = AutonomousRunRequest(projectID: source.authorization.projectID,
                projectGeneration: source.authorization.projectGeneration,
                assignmentID: assignment.assignmentID, mission: assignment.mission,
                providerID: assignment.providerID, adapterID: assignment.adapterID, modelKey: assignment.modelKey,
                specification: assignment.specification, authorizationScope: assignment.authorizationScope)
            try validateAutonomousRunRequest(request)
            _ = try insertAutonomousRunUnlocked(request, state: .awaitingBootstrap,
                operationID: operationID, timestamp: timestamp, connection: connection)
            runID = request.runID
            let linked = try connection.execute(
                "UPDATE continuity_task_authorizations SET run_id=?,revision=revision+1 WHERE task_id=? AND state='active' AND revision=? AND run_id IS NULL",
                bindings: [.text(runID.description), .text(source.authorization.taskID.uuidString.lowercased()),
                    .int64(task.revision)])
            guard linked == 1 else { throw ContinuityIngressError.deliveryConflict }
            let bound = try connection.execute(
                "UPDATE project_bindings SET run_id=?,updated_at=? WHERE binding_id=? AND active=1 AND run_id IS NULL",
                bindings: [.text(runID.description), .text(timestamp),
                    .text(source.authorization.sourceBindingID.uuidString.lowercased())])
            guard bound == 1 else { throw ContinuityIngressError.authorityMismatch }
        }
        let receipt = try ContinuityIngressAcceptanceReceipt(source: source, operationID: operationID,
            runID: runID, policySelection: policySelection, acceptedAt: timestamp)
        try connection.execute(
            """
            INSERT INTO continuity_ingress_acceptances(operation_id,key_sha256,run_id,task_id,project_id,
                project_generation,receipt_json,receipt_sha256,accepted_at) VALUES(?,?,?,?,?,?,?,?,?)
            """,
            bindings: [.text(operationID.uuidString.lowercased()), .text(identity.keySHA256), .text(runID.description),
                .text(source.authorization.taskID.uuidString.lowercased()), .text(source.authorization.projectID.description),
                .int64(try Self.sqliteGeneration(source.authorization.projectGeneration)),
                .text(String(decoding: receipt.canonicalReceiptJSON, as: UTF8.self)), .text(receipt.receiptSHA256), .text(timestamp)])
        try connection.execute(
            "INSERT INTO continuity_ingress_holds(run_id,operation_id,state,created_at,updated_at) VALUES(?,?,'awaiting_bootstrap',?,?)",
            bindings: [.text(runID.description), .text(operationID.uuidString.lowercased()), .text(timestamp), .text(timestamp)])
        try bindNativeSourceOffsetUnlocked(receipt: receipt, connection: connection)
        try installSourceTransferFenceUnlocked(receipt: receipt, timestamp: timestamp, connection: connection)
        try appendAutonomyEventUnlocked(runID: runID, projectID: source.authorization.projectID,
            eventType: "continuity_ingress_accepted", severity: .info,
            summary: "Committed handoff accepted with a durable bootstrap hold",
            metadata: ["operation_id": operationID.uuidString.lowercased(), "receipt_sha256": receipt.receiptSHA256,
                "assignment_sha256": source.authorization.assignmentSHA256], connection: connection)
        return receipt
    }

    func withContinuityIngressAcceptance<Value: Sendable>(acceptance: ContinuityIngressAcceptanceReceipt,
        lease: RunLease, cancellation: ToolCallCancellation? = nil,
        operation: @Sendable () throws -> Value) throws -> Value {
        try controlledTransaction(cancellation: cancellation) { connection in
            try validateBootstrapReceiptUnlocked(acceptance, lease: lease, connection: connection)
            let result = try operation()
            try cancellation?.checkCancellation()
            try validateBootstrapReceiptUnlocked(acceptance, lease: lease, connection: connection)
            return result
        }
    }

    func withContinuityBootstrapAuthority<Value: Sendable>(grant: ContinuityBootstrapGrant,
        lease: RunLease, cancellation: ToolCallCancellation? = nil,
        operation: @Sendable () throws -> Value) throws -> Value {
        try controlledTransaction(cancellation: cancellation) { connection in
            try validateBootstrapGrantUnlocked(grant, lease: lease, connection: connection)
            let result = try operation()
            try cancellation?.checkCancellation()
            try validateBootstrapGrantUnlocked(grant, lease: lease, connection: connection)
            return result
        }
    }

    /// Native manager setup only. Renewal preserves the same candidate and all
    /// retained provider intents; an expired lease never implies a new root.
    func issueContinuityBootstrapGrant(envelope: ContinuitySourceBootstrapEnvelope, candidateID: UUID,
                                       lease: RunLease, cancellation: ToolCallCancellation? = nil) throws -> ContinuityBootstrapGrant {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            try validateBootstrapAcceptanceUnlocked(envelope, lease: lease, connection: connection)
            try requireBootstrapRecoveryScopeUnlocked(envelope, connection: connection)
            let limit = min(65_536, envelope.authorization.authorizationScope.maximumInlineOutputBytes)
            let packet = try JSONSerialization.jsonObject(with: envelope.acceptance.source.canonicalPacketJSON)
            let result = try ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false, "payload": [
                "ok": true, "found": true, "packet": packet, "continuity_id": envelope.sourceIdentity.continuityID,
                "revision": envelope.sourceIdentity.revision, "packet_sha256": envelope.sourceIdentity.packetSHA256]])
            guard result.count <= limit else {
                throw ContinuityIngressError.capacityExceeded("exact bootstrap result")
            }
            let previous = try bootstrapGrantUnlocked(candidateID: candidateID, envelope: envelope, connection: connection)
            if previous == nil {
                guard try connection.scalarInt("SELECT COUNT(*) FROM continuity_bootstrap_grants") < 1_024,
                      try connection.scalarInt("SELECT COUNT(*) FROM continuity_bootstrap_grants WHERE operation_id=?",
                        bindings: [.text(envelope.operationID.uuidString.lowercased())]) < 8 else {
                    throw ContinuityIngressError.capacityExceeded("bootstrap candidates")
                }
            }
            let grant = try ContinuityBootstrapGrant(grantID: previous?.grantID ?? UUID(), candidateID: candidateID,
                envelope: envelope, lease: lease, maximumOutputBytes: limit,
                createdAt: previous?.createdAt ?? ISO8601.string(from: clock.now()))
            let data = try grant.storedJSON()
            if let previous {
                let changed = try connection.execute("""
                    UPDATE continuity_bootstrap_grants SET grant_json=?,grant_sha256=?
                    WHERE grant_id=? AND grant_sha256=?
                    """, bindings: [.text(String(decoding: data, as: UTF8.self)), .text(JSONSupport.sha256Hex(data)),
                        .text(grant.grantID.uuidString.lowercased()), .text(JSONSupport.sha256Hex(try previous.storedJSON()))])
                guard changed == 1 else { throw ContinuityIngressError.deliveryConflict }
            } else {
                try connection.execute("""
                    INSERT INTO continuity_bootstrap_grants(grant_id,candidate_id,operation_id,run_id,grant_json,grant_sha256)
                    VALUES(?,?,?,?,?,?)
                    """, bindings: [.text(grant.grantID.uuidString.lowercased()), .text(grant.sessionID),
                        .text(envelope.operationID.uuidString.lowercased()), .text(envelope.runID.description),
                        .text(String(decoding: data, as: UTF8.self)), .text(JSONSupport.sha256Hex(data))])
            }
            return grant
        }
    }

    /// The manager's normalized transport result is retained only after its
    /// write-ahead turn has completed with these exact provider response IDs.
    func recordContinuityBootstrapProviderResult(grant: ContinuityBootstrapGrant, turnID: UUID,
                                                 result: ProviderTurn, lease: RunLease) throws {
        try controlledTransaction(cancellation: nil, fullDurability: true) { connection in
            try validateBootstrapGrantUnlocked(grant, lease: lease, connection: connection)
            guard let turn = try providerTurnUnlocked(turnID, connection: connection),
                  turn.state == .completed, turn.intent.kind == .bootstrap,
                  turn.intent.sessionID == grant.sessionID, turn.intent.operationID == grant.envelope.operationID,
                  turn.providerRequestID == result.requestID, turn.providerResponseID == result.responseID,
                  turn.intent.previousResponseID == result.previousResponseID,
                  result.completed, result.finishReason == .toolCalls, result.toolCalls.count == 1,
                  result.messages.count <= 128, result.messages.allSatisfy({ $0.utf8.count <= 65_536 }),
                  result.messages.reduce(0, { $0 + $1.utf8.count }) <= 65_536,
                  result.structuredOutputJSON.map({ $0.count <= 16_384 }) ?? true,
                  result.toolCalls[0].argumentsJSON.count <= 8_192,
                  [result.requestID, result.responseID, result.providerID, result.providerVersion, result.modelKey,
                   result.providerInstanceID ?? "", result.rawArtifactID ?? ""].allSatisfy({ $0.utf8.count <= 1_024 }) else {
                throw ContinuityIngressError.authorityMismatch
            }
            let task = try validatedContinuityTaskUnlocked(grant.envelope.authorization, connection: connection)
            guard result.providerID == task.assignment.providerID, result.modelKey == task.assignment.modelKey else {
                throw ContinuityIngressError.authorityMismatch
            }
            let call = result.toolCalls[0]
            if turn.intent.previousResponseID == nil {
                try validateExactBootstrapCall(call, source: grant.envelope.sourceIdentity)
            } else {
                guard call.name == "forge_continuity_ack",
                      let proof = try bootstrapRetrievalProofUnlocked(grant: grant, connection: connection),
                      result.previousResponseID == proof.providerResponseID else {
                    throw ContinuityIngressError.authorityMismatch
                }
            }
            let encoded = try JSONEncoder().encode(result)
            guard encoded.count <= 131_072 else { throw ContinuityIngressError.capacityExceeded("bootstrap provider result") }
            let data = try ForgeJSONCanonicalizationV1.data(from: JSONSerialization.jsonObject(with: encoded))
            if let existing = try bootstrapProviderResultUnlocked(grant: grant, turnID: turnID, connection: connection) {
                guard existing == result else { throw ContinuityIngressError.deliveryConflict }
                return
            }
            guard try connection.scalarInt("SELECT COUNT(*) FROM continuity_bootstrap_provider_results WHERE grant_id=?",
                bindings: [.text(grant.grantID.uuidString.lowercased())]) < 2 else {
                throw ContinuityIngressError.capacityExceeded("bootstrap root and acknowledgment results")
            }
            try connection.execute("""
                INSERT INTO continuity_bootstrap_provider_results(turn_id,grant_id,result_json,result_sha256)
                VALUES(?,?,?,?)
                """, bindings: [.text(turnID.uuidString.lowercased()), .text(grant.grantID.uuidString.lowercased()),
                    .text(String(decoding: data, as: UTF8.self)), .text(JSONSupport.sha256Hex(data))])
            if result.previousResponseID == nil {
                let changed = try connection.execute("""
                    UPDATE provider_sessions SET provider_response_id=?,updated_at=?
                    WHERE session_id=? AND status='candidate' AND accepted=0
                        AND (provider_response_id IS NULL OR provider_response_id=?)
                    """, bindings: [.text(result.responseID), .text(ISO8601.string(from: clock.now())),
                        .text(grant.sessionID), .text(result.responseID)])
                guard changed == 1 else { throw ContinuityIngressError.authorityMismatch }
            }
        }
    }

    /// Reads the known restoration cost before the native root can be sent.
    /// It neither invents a provider call identity nor reserves a tool effect.
    func preflightContinuityBootstrapRetrieval(grant: ContinuityBootstrapGrant, rootTurnID: UUID,
        lease: RunLease, policy: BudgetPolicySelection, cancellation: ToolCallCancellation? = nil) throws {
        try controlledTransaction(cancellation: cancellation) { connection in
            try validateBootstrapGrantUnlocked(grant, lease: lease, connection: connection)
            try ContinuityIngressAcceptanceReceipt.validatePolicy(policy, authorization: grant.envelope.authorization)
            guard let root = try providerTurnUnlocked(rootTurnID, connection: connection),
                  root.intent.kind == .bootstrap, root.intent.previousResponseID == nil,
                  root.intent.runID == grant.envelope.runID, root.intent.sessionID == grant.sessionID,
                  root.intent.operationID == grant.envelope.operationID,
                  root.intent.projectID == grant.envelope.authorization.projectID,
                  root.intent.projectGeneration == grant.envelope.authorization.projectGeneration,
                  ![ProviderTurnState.failed, .cancelled].contains(root.state) else {
                throw ContinuityIngressError.authorityMismatch
            }
            try requireBootstrapResultLimitsUnlocked(grant: grant, policy: policy.policy.tools, connection: connection)
            if let proof = try bootstrapRetrievalProofUnlocked(grant: grant, connection: connection) {
                guard proof.providerTurnID == rootTurnID,
                      let invocation = try toolInvocationUnlocked(proof.toolInvocationID, connection: connection),
                      invocation.state == .completed, invocation.turnID == rootTurnID,
                      invocation.runID == grant.envelope.runID, invocation.sessionID == grant.sessionID,
                      invocation.projectID == grant.envelope.authorization.projectID,
                      invocation.projectGeneration == grant.envelope.authorization.projectGeneration,
                      invocation.toolName == "context_get", invocation.replayClass == .readOnly,
                      invocation.providerCallID == proof.providerCallID,
                      invocation.resultSHA256 == proof.toolResultSHA256,
                      invocation.resultSummary == String(data: proof.canonicalToolResultJSON, encoding: .utf8),
                      let result = try bootstrapProviderResultUnlocked(grant: grant, turnID: rootTurnID, connection: connection),
                      result.previousResponseID == nil, result.responseID == proof.providerResponseID,
                      result.toolCalls.count == 1, let call = result.toolCalls.first,
                      call.callID == invocation.providerCallID,
                      try bootstrapCallSHA256(call) == invocation.argumentsSHA256 else {
                    throw ContinuityIngressError.integrityFailure("bootstrap preflight proof differs from completed invocation")
                }
                try validateExactBootstrapCall(call, source: grant.envelope.sourceIdentity)
                return
            }
            if let result = try bootstrapProviderResultUnlocked(grant: grant, turnID: rootTurnID, connection: connection),
               result.previousResponseID == nil, result.toolCalls.count == 1, let call = result.toolCalls.first {
                try validateExactBootstrapCall(call, source: grant.envelope.sourceIdentity)
                if let invocation = try toolInvocationByProviderCallUnlocked(sessionID: grant.sessionID,
                    providerCallID: call.callID, connection: connection) {
                    guard invocation.turnID == rootTurnID, invocation.runID == grant.envelope.runID,
                          invocation.projectID == grant.envelope.authorization.projectID,
                          invocation.projectGeneration == grant.envelope.authorization.projectGeneration,
                          invocation.toolName == "context_get", invocation.replayClass == .readOnly,
                          invocation.idempotencyKey == nil, invocation.reconciliationDescriptor == nil,
                          try bootstrapCallSHA256(call) == invocation.argumentsSHA256,
                          [ToolInvocationState.intent, .executing, .ambiguous, .failed].contains(invocation.state) else {
                        throw ContinuityIngressError.integrityFailure("bootstrap preflight reservation differs from actual root call")
                    }
                    // The real provider call already owns this reservation.
                    // Retrying its read consumes no second logical tool call.
                    if let offset = try nativeRunSourceOffsetUnlocked(grant.envelope.runID, connection: connection) {
                        try requireNativeManagedToolQuotaUnlocked(intent: Self.nativeRetainedToolIntent(invocation), offset: offset,
                            policy: policy.policy.tools, alreadyReserved: true, connection: connection)
                    }
                    return
                }
            }
            try requireBootstrapToolQuotaUnlocked(runID: grant.envelope.runID, sessionID: grant.sessionID,
                turnID: rootTurnID, operationID: grant.envelope.operationID,
                policy: policy.policy.tools, connection: connection)
        }
    }

    /// Chooses the real acknowledged candidate while execution remains held.
    func acceptContinuitySourceSuccessor(acceptance: ContinuityIngressAcceptanceReceipt, lease: RunLease,
        policySelection: BudgetPolicySelection, continuationInput: Data, cancellation: ToolCallCancellation? = nil,
        readCanonical: @Sendable () throws -> ContinuitySourceBootstrapOperation) throws -> ContinuitySourceActivationReceipt {
        guard continuationInput.count <= ContinuitySourceActivationReceipt.maximumContinuationInputBytes,
              continuationInput == (try ManagedContinuityWorker.automaticContinuationInput()) else {
            throw ContinuitySourceActivationError.invalidRequest
        }
        return try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            _ = try validateSourceStartAuthorityUnlocked(acceptance: acceptance, lease: lease,
                policySelection: policySelection, connection: connection)
            let operation = try readCanonical()
            guard operation.envelope.acceptance == acceptance else { throw ContinuitySourceActivationError.conflict }
            if let stored = try sourceActivationUnlocked(operationID: acceptance.operationID, connection: connection) {
                try validateSourceActivationUnlocked(stored.receipt, lease: lease, connection: connection)
                guard stored.receipt.canonicalContinuationInput == continuationInput,
                      operation.envelope == stored.receipt.envelope,
                      (operation.state == .successorAcknowledged && operation.stateChecksum == stored.receipt.acknowledgedStateChecksum)
                        || (operation.state == .predecessorSealed && operation.activationReceiptSHA256 == stored.receipt.receiptSHA256) else {
                    throw ContinuitySourceActivationError.conflict
                }
                return stored.receipt
            }
            try validateBootstrapReceiptUnlocked(acceptance, lease: lease, connection: connection)
            let proof = try validatedSourceAcknowledgementUnlocked(operation, acceptance: acceptance, connection: connection)
            guard let run = try autonomousRunUnlocked(acceptance.runID, connection: connection), run.state == .awaitingBootstrap,
                  try connection.scalarInt("SELECT COUNT(*) FROM continuity_source_activations") < Self.maximumContinuityIngressAcceptances else {
                throw ContinuitySourceActivationError.conflict
            }
            try requireSourceEffectsReconciledUnlocked(runID: run.runID, operationID: acceptance.operationID, connection: connection)
            let timestamp = ISO8601.string(from: clock.now()), candidateID = proof.grant.sessionID
            let predecessorID = run.activeSessionID
            if let predecessorID {
                guard let predecessor = try providerSessionRecordUnlocked(predecessorID, connection: connection),
                      predecessor.runID == run.runID, predecessor.projectID == run.projectID,
                      predecessor.projectGeneration == run.projectGeneration,
                      [.fencing, .fenced].contains(predecessor.status), !predecessor.accepted else {
                    throw ContinuitySourceActivationError.conflict
                }
                try connection.execute("UPDATE provider_sessions SET status='fenced',accepted=0,updated_at=? WHERE session_id=?",
                    bindings: [.text(timestamp), .text(predecessorID)])
            }
            guard try providerSessionForAcceptedOperationUnlocked(acceptance.operationID, connection: connection) == nil else {
                throw ContinuitySourceActivationError.conflict
            }
            let duplicates = try connection.all("SELECT session_id FROM provider_sessions WHERE operation_id=? AND status='candidate' AND session_id<>? LIMIT 129",
                bindings: [.text(acceptance.operationID.uuidString.lowercased()), .text(candidateID)],
                map: { try $0.strictText(0, maximumBytes: 1_024) })
            guard duplicates.count <= 128 else { throw ContinuitySourceActivationError.unresolvedEffects }
            for duplicate in duplicates {
                guard let duplicate else { throw ContinuitySourceActivationError.proofRequired }
                try quarantineProviderSessionUnlocked(duplicate, timestamp: timestamp, connection: connection)
            }
            guard try connection.execute("""
                UPDATE provider_sessions SET status='active',accepted=1,provider_response_id=?,updated_at=?
                WHERE session_id=? AND operation_id=? AND status='candidate' AND accepted=0
                """, bindings: [.text(proof.ack.responseID), .text(timestamp), .text(candidateID),
                    .text(acceptance.operationID.uuidString.lowercased())]) == 1 else { throw ContinuitySourceActivationError.conflict }
            try activateProviderBindingIdentityUnlocked(sessionID: candidateID, run: run, timestamp: timestamp, connection: connection)
            guard try connection.execute("""
                UPDATE autonomous_runs SET active_session_id=?,continuation_pending=1,revision=revision+1,updated_at=?
                WHERE run_id=? AND active_operation_id=? AND state='awaiting_bootstrap' AND active_session_id IS ?
                """, bindings: [.text(candidateID), .text(timestamp), .text(run.runID.description),
                    .text(acceptance.operationID.uuidString.lowercased()), .optionalText(predecessorID)]) == 1,
                  let winner = try providerSessionRecordUnlocked(candidateID, connection: connection) else {
                throw ContinuitySourceActivationError.conflict
            }
            let key = "source-continuation:\(acceptance.operationID.uuidString.lowercased())"
            let continuation = try automaticContinuationIntentUnlocked(operationID: acceptance.operationID,
                runID: run.runID, projectID: run.projectID, projectGeneration: run.projectGeneration,
                handoffID: operation.handoffID, handoffSHA256: operation.envelope.envelopeSHA256,
                bootstrapNonceSHA256: JSONSupport.sha256Hex(Data(operation.bootstrapNonce.uuidString.lowercased().utf8)),
                idempotencyKey: key, inputSHA256: JSONSupport.sha256Hex(continuationInput), winner: winner,
                previousResponseID: proof.ack.responseID, timestamp: timestamp, connection: connection)
            let receipt = try ContinuitySourceActivationReceipt(envelope: operation.envelope,
                acknowledgedStateChecksum: operation.stateChecksum, candidateID: proof.grant.candidateID,
                predecessorProviderSessionID: predecessorID, retrievalProofSHA256: proof.retrieval.proofSHA256,
                acknowledgementProofSHA256: operation.acknowledgementProofSHA256!, acknowledgementProviderTurnID: proof.ackTurnID,
                acknowledgementProviderResponseID: proof.ack.responseID, continuationTurnID: continuation.intent.turnID,
                canonicalContinuationInput: continuationInput, continuationIdempotencyKey: key, acceptedAt: timestamp)
            try connection.execute("""
                INSERT INTO continuity_source_activations(operation_id,run_id,project_id,project_generation,task_id,candidate_id,
                    envelope_json,envelope_sha256,receipt_json,receipt_sha256) VALUES(?,?,?,?,?,?,?,?,?,?)
                """, bindings: [.text(receipt.operationID.uuidString.lowercased()), .text(receipt.runID.description),
                    .text(receipt.authorization.projectID.description), .int64(Int64(receipt.authorization.projectGeneration.rawValue)),
                    .text(receipt.authorization.taskID.uuidString.lowercased()), .text(candidateID),
                    .text(String(decoding: receipt.envelope.canonicalEnvelopeJSON, as: UTF8.self)), .text(receipt.envelope.envelopeSHA256),
                    .text(String(decoding: receipt.canonicalReceiptJSON, as: UTF8.self)), .text(receipt.receiptSHA256)])
            guard try connection.execute("""
                UPDATE continuity_source_task_fences SET state='accepted',activation_receipt_sha256=?
                WHERE source_binding_id=? AND task_id=? AND operation_id=? AND receipt_sha256=? AND state='quiescing'
                """, bindings: [.text(receipt.receiptSHA256), .text(receipt.authorization.sourceBindingID.uuidString.lowercased()),
                    .text(receipt.authorization.taskID.uuidString.lowercased()), .text(receipt.operationID.uuidString.lowercased()),
                    .text(acceptance.receiptSHA256)]) == 1 else { throw ContinuitySourceActivationError.conflict }
            return receipt
        }
    }

    /// The matching hold is released only after the guarded canonical seal returns.
    func completeContinuitySourceActivation(receipt: ContinuitySourceActivationReceipt, lease: RunLease,
        policySelection: BudgetPolicySelection, cancellation: ToolCallCancellation? = nil,
        writeCanonical: @Sendable (ContinuitySourceActivationReceipt) throws -> ContinuitySourceBootstrapOperation
    ) throws -> AutonomousRunRecord {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            _ = try validateSourceStartAuthorityUnlocked(acceptance: receipt.acceptance, lease: lease,
                policySelection: policySelection, connection: connection)
            try validateSourceActivationUnlocked(receipt, lease: lease, connection: connection)
            let operation = try writeCanonical(receipt)
            guard operation.envelope == receipt.envelope, operation.state == .predecessorSealed,
                  operation.activationReceiptSHA256 == receipt.receiptSHA256, let sealed = operation.sealedStateChecksum,
                  sealed.count == 64, sealed.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw ContinuitySourceActivationError.proofRequired
            }
            try validateSourceActivationUnlocked(receipt, lease: lease, connection: connection)
            guard let run = try autonomousRunUnlocked(receipt.runID, connection: connection) else { throw AutonomyError.staleLease }
            if let retained = try sourceActivationUnlocked(operationID: receipt.operationID, connection: connection)?.sealedChecksum {
                guard retained == sealed, run.state != .awaitingBootstrap else { throw ContinuitySourceActivationError.conflict }
                return run
            }
            var specification = run.specification
            specification.work.metadata["provider_adapter_id"] = try validatedContinuityTaskUnlocked(receipt.authorization, connection: connection).assignment.adapterID
            specification.work.metadata["provider_session_id"] = receipt.candidateID.uuidString.lowercased()
            specification.work.metadata["provider_response_id"] = receipt.acknowledgementProviderResponseID
            specification.work.metadata["continuity_operation_id"] = receipt.operationID.uuidString.lowercased()
            specification.work.metadata["automatic_continuation_turn_id"] = receipt.continuationTurnID.uuidString.lowercased()
            try connection.execute("UPDATE continuity_source_activations SET sealed_checksum=? WHERE operation_id=? AND sealed_checksum IS NULL",
                bindings: [.text(sealed), .text(receipt.operationID.uuidString.lowercased())])
            guard try connection.execute("UPDATE continuity_ingress_holds SET state='activated',updated_at=? WHERE operation_id=? AND run_id=? AND state='awaiting_bootstrap'",
                bindings: [.text(ISO8601.string(from: clock.now())), .text(receipt.operationID.uuidString.lowercased()), .text(receipt.runID.description)]) == 1 else {
                throw ContinuitySourceActivationError.conflict
            }
            if let predecessor = receipt.predecessorProviderSessionID {
                guard try connection.execute("UPDATE provider_sessions SET status='sealed',accepted=0,updated_at=? WHERE session_id=? AND status='fenced'",
                    bindings: [.text(ISO8601.string(from: clock.now())), .text(predecessor)]) == 1 else { throw ContinuitySourceActivationError.conflict }
            }
            guard try connection.execute("""
                UPDATE autonomous_runs SET state='running',current_work_json=?,revision=revision+1,updated_at=?
                WHERE run_id=? AND active_operation_id=? AND active_session_id=? AND state='awaiting_bootstrap'
                """, bindings: [.text(try Self.specificationJSON(specification)), .text(ISO8601.string(from: clock.now())),
                    .text(receipt.runID.description), .text(receipt.operationID.uuidString.lowercased()),
                    .text(receipt.candidateID.uuidString.lowercased())]) == 1,
                  let updated = try autonomousRunUnlocked(receipt.runID, connection: connection) else { throw ContinuitySourceActivationError.conflict }
            return updated
        }
    }

    func sourceActivationReceipt(runID: RunID, operationID: UUID, lease: RunLease) throws -> ContinuitySourceActivationReceipt? {
        try controlledTransaction(cancellation: nil) { connection in
            guard runID == lease.runID, let run = try autonomousRunUnlocked(runID, connection: connection) else { throw AutonomyError.staleLease }
            try verifyRunLeaseUnlocked(lease, timestamp: ISO8601.string(from: clock.now()), connection: connection)
            _ = try requiredActiveProjectUnlocked(run.projectID, generation: run.projectGeneration, connection: connection)
            guard let metadata = try connection.first("SELECT run_id,project_id,project_generation FROM continuity_source_activations WHERE operation_id=?",
                bindings: [.text(operationID.uuidString.lowercased())], map: {
                    (try $0.strictText(0, maximumBytes: 36), try $0.strictText(1, maximumBytes: 36), $0.int64(2))
                }) else { return nil }
            guard metadata.0 == runID.description, metadata.1 == run.projectID.description,
                  metadata.2 > 0, UInt64(metadata.2) == run.projectGeneration.rawValue else {
                throw ContinuitySourceActivationError.conflict
            }
            guard let stored = try sourceActivationUnlocked(operationID: operationID, connection: connection) else { return nil }
            guard stored.receipt.runID == runID else { throw ContinuitySourceActivationError.conflict }
            try validateSourceActivationUnlocked(stored.receipt, lease: lease, connection: connection)
            return stored.receipt
        }
    }

    /// Reads the fresh successor's actual bootstrap context after canonical sealing.
    /// The accepted candidate and run lease authorize this observation; the historical
    /// bootstrap grant only binds retained evidence and is never renewed or reactivated.
    func sourceDerivedBootstrapAcknowledgement(runID: RunID, sessionID: String,
        previousResponseID: String, lease: RunLease, cancellation: ToolCallCancellation? = nil
    ) throws -> SourceDerivedBootstrapAcknowledgement? {
        try controlledTransaction(cancellation: cancellation) { connection in
            guard runID == lease.runID else { throw AutonomyError.staleLease }
            try verifyRunLeaseUnlocked(lease, timestamp: ISO8601.string(from: clock.now()), connection: connection)
            guard let run = try autonomousRunUnlocked(runID, connection: connection) else { throw AutonomyError.staleLease }
            _ = try requiredActiveProjectUnlocked(run.projectID, generation: run.projectGeneration, connection: connection)
            // Check ownership metadata before decoding a potentially foreign receipt.
            guard let metadata = try connection.first("""
                SELECT operation_id,run_id,project_id,project_generation FROM continuity_source_activations WHERE candidate_id=?
                """, bindings: [.text(sessionID)], map: {
                    (try $0.strictText(0, maximumBytes: 36), try $0.strictText(1, maximumBytes: 36),
                     try $0.strictText(2, maximumBytes: 36), $0.int64(3))
                }) else { return nil }
            guard metadata.1 == runID.description, metadata.2 == run.projectID.description,
                  metadata.3 > 0, UInt64(metadata.3) == run.projectGeneration.rawValue,
                  run.activeSessionID == sessionID,
                  let operationID = metadata.0.flatMap(UUID.init(uuidString:)) else {
                throw ContinuitySourceActivationError.conflict
            }
            guard let stored = try sourceActivationUnlocked(operationID: operationID, connection: connection),
                  stored.sealedChecksum != nil,
                  stored.receipt.candidateID.uuidString.lowercased() == sessionID,
                  stored.receipt.acknowledgementProviderResponseID == previousResponseID,
                  run.specification.work.metadata["provider_response_id"] == previousResponseID else {
                throw ContinuitySourceActivationError.proofRequired
            }
            let receipt = stored.receipt
            try validateSourceActivationUnlocked(receipt, lease: lease, connection: connection)
            guard let grant = try bootstrapGrantUnlocked(candidateID: receipt.candidateID, envelope: receipt.envelope, connection: connection),
                  let proof = try bootstrapRetrievalProofUnlocked(grant: grant, connection: connection),
                  proof.proofSHA256 == receipt.retrievalProofSHA256,
                  let invocation = try toolInvocationUnlocked(proof.toolInvocationID, connection: connection),
                  invocation.state == .completed, invocation.turnID == proof.providerTurnID,
                  invocation.runID == runID, invocation.sessionID == sessionID,
                  invocation.providerCallID == proof.providerCallID, invocation.toolName == "context_get", invocation.replayClass == .readOnly,
                  invocation.resultSHA256 == proof.toolResultSHA256,
                  invocation.resultSummary == String(data: proof.canonicalToolResultJSON, encoding: .utf8),
                  let root = try bootstrapProviderResultUnlocked(grant: grant, turnID: proof.providerTurnID, connection: connection),
                  root.previousResponseID == nil, root.responseID == proof.providerResponseID,
                  let rootCall = root.toolCalls.first, rootCall.callID == proof.providerCallID,
                  try bootstrapCallSHA256(rootCall) == invocation.argumentsSHA256,
                  let ack = try bootstrapProviderResultUnlocked(grant: grant, turnID: receipt.acknowledgementProviderTurnID, connection: connection),
                  ack.responseID == previousResponseID, ack.previousResponseID == root.responseID,
                  let ackCall = ack.toolCalls.first, ackCall.name == "forge_continuity_ack",
                  try bootstrapCallSHA256(ackCall) == receipt.acknowledgementProofSHA256 else {
                throw ContinuitySourceActivationError.proofRequired
            }
            try validateExactBootstrapCall(rootCall, source: receipt.acceptance.sourceIdentity)
            let acknowledgement = try JSONDecoder().decode(BootstrapAcknowledgementV2.self, from: ackCall.argumentsJSON)
            guard acknowledgement.accepted, acknowledgement.projectID == run.projectID,
                  acknowledgement.projectGeneration == run.projectGeneration,
                  acknowledgement.runID == runID, acknowledgement.operationID == operationID,
                  acknowledgement.handoffID == receipt.envelope.handoffID,
                  acknowledgement.handoffSHA256 == receipt.envelope.envelopeSHA256,
                  acknowledgement.nonce == receipt.envelope.bootstrapNonce.uuidString.lowercased(),
                  let rootRecord = try providerTurnUnlocked(proof.providerTurnID, connection: connection),
                  let ackRecord = try providerTurnUnlocked(receipt.acknowledgementProviderTurnID, connection: connection),
                  let rootReceipt = try sourceDerivedPreflightUnlocked(rootRecord, connection: connection),
                  let ackReceipt = try sourceDerivedPreflightUnlocked(ackRecord, connection: connection) else {
                throw ContinuitySourceActivationError.proofRequired
            }
            for (record, result, preflight) in [(rootRecord, root, rootReceipt), (ackRecord, ack, ackReceipt)] {
                guard record.intent.runID == runID, record.intent.sessionID == sessionID,
                      record.intent.operationID == operationID, record.intent.projectID == run.projectID,
                      record.intent.projectGeneration == run.projectGeneration, record.intent.kind == .bootstrap,
                      preflight.capabilities.providerID == result.providerID,
                      preflight.capabilities.modelKey == result.modelKey,
                      preflight.capabilities.providerVersion == result.providerVersion,
                      preflight.capabilities.providerInstanceID == result.providerInstanceID else {
                    throw ContinuitySourceActivationError.proofRequired
                }
                try validateSourceDerivedPreflightUnlocked(preflight.preflight, capabilities: preflight.capabilities,
                    intent: preflight.intent, carryover: nil, connection: connection)
                _ = try NativeSourceJournalCoding.turn(result)
            }
            let bytes = try [rootReceipt.preflight.bodyByteCount, ackReceipt.preflight.bodyByteCount,
                Self.nativeRetainedProviderResponseBytes(root), Self.nativeRetainedProviderResponseBytes(ack)]
                .reduce(0, Self.nativeSourceCheckedAdd)
            return .init(turn: ack, preflight: ackReceipt.preflight, capabilities: ackReceipt.capabilities,
                retainedContextSerializedBytes: bytes, acknowledgementProviderTurnID: receipt.acknowledgementProviderTurnID,
                activationReceiptSHA256: receipt.receiptSHA256)
        }
    }

    /// Reconciles real ordinary work and provider consumption; absence is deferred.
    func completeContinuitySourceResumption(activationReceipt: ContinuitySourceActivationReceipt, lease: RunLease,
        policySelection: BudgetPolicySelection, cancellation: ToolCallCancellation? = nil,
        writeCanonical: @Sendable (ContinuitySourceResumptionReceipt) throws -> ContinuitySourceBootstrapOperation
    ) throws -> ContinuitySourceResumptionReceipt? {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            try validateSourceActivationUnlocked(activationReceipt, lease: lease, connection: connection)
            try ContinuityIngressAcceptanceReceipt.validatePolicy(policySelection, authorization: activationReceipt.authorization)
            guard let stored = try sourceActivationUnlocked(operationID: activationReceipt.operationID, connection: connection),
                  let sealed = stored.sealedChecksum else { return nil }
            let receipt: ContinuitySourceResumptionReceipt
            if let existing = stored.resumption { receipt = existing }
            else {
                guard let observed = try sourceResumptionEvidenceUnlocked(activationReceipt, connection: connection) else { return nil }
                receipt = observed
            }
            let operation = try writeCanonical(receipt)
            guard operation.envelope == activationReceipt.envelope, operation.state == .predecessorSealed,
                  operation.activationReceiptSHA256 == activationReceipt.receiptSHA256,
                  operation.sealedStateChecksum == sealed, operation.isResumed,
                  operation.resumedReceiptSHA256 == receipt.receiptSHA256 else { throw ContinuitySourceActivationError.proofRequired }
            try validateSourceActivationUnlocked(activationReceipt, lease: lease, connection: connection)
            if stored.resumption == nil {
                try connection.execute("UPDATE continuity_source_activations SET resumption_json=?,resumption_sha256=? WHERE operation_id=? AND resumption_json IS NULL",
                    bindings: [.text(String(decoding: receipt.canonicalReceiptJSON, as: UTF8.self)), .text(receipt.receiptSHA256),
                        .text(receipt.operationID.uuidString.lowercased())])
                guard try connection.execute("UPDATE autonomous_runs SET active_operation_id=NULL,revision=revision+1,updated_at=? WHERE run_id=? AND active_operation_id=? AND active_session_id=?",
                    bindings: [.text(ISO8601.string(from: clock.now())), .text(receipt.runID.description),
                        .text(receipt.operationID.uuidString.lowercased()), .text(activationReceipt.candidateID.uuidString.lowercased())]) == 1 else {
                    throw ContinuitySourceActivationError.conflict
                }
            }
            return receipt
        }
    }

    /// Scans only bounded scheduling metadata. Receipt and source bytes are read
    /// by the separate leased claim after the live task binding is validated.
    func pendingContinuityBootstrapRecoveries(afterRowID: Int64? = nil, limit: Int = 32,
        cancellation: ToolCallCancellation? = nil) throws -> ContinuityBootstrapRecoveryPage {
        guard (1...ContinuityBootstrapRecoveryLimits.maximumPageSize).contains(limit),
              afterRowID == nil || afterRowID! >= 0 else { throw ContinuityBootstrapRecoveryError.invalidRequest }
        return try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let rows = try connection.all(Self.recoveryMetadataQuery + "\n" + """
                WHERE h.rowid>? AND h.state='awaiting_bootstrap'
                  AND h.recovery_quarantined=0
                  AND NOT EXISTS(SELECT 1 FROM continuity_operation_cancellations c WHERE c.operation_id=h.operation_id)
                ORDER BY h.rowid LIMIT ?
                """, bindings: [.int64(afterRowID ?? 0), .int64(Int64(limit))]) { row in
                    (row.int64(0), Result { try Self.decodeRecoveryMetadata(row) })
                }
            var references: [ContinuityBootstrapRecoveryReference] = []
            var diagnostics: [ContinuityBootstrapRecoveryDiagnostic] = []
            for (rowID, result) in rows {
                try cancellation?.checkCancellation()
                switch result {
                case .success(let row):
                    if try recoveryIsDueUnlocked(row, connection: connection),
                       try connection.scalarInt("SELECT COUNT(*) FROM run_leases WHERE run_id=? AND expires_at>?",
                         bindings: [.text(row.reference.runID.description), .text(ISO8601.string(from: clock.now()))]) == 0 {
                        references.append(row.reference)
                    }
                case .failure:
                    try quarantineRecoveryUnlocked(rowID: rowID, connection: connection)
                    diagnostics.append(.init(rowID: rowID, failure: .integrityFailure))
                }
            }
            return .init(references: references, diagnostics: diagnostics,
                         nextRowID: rows.count == limit ? rows.last?.0 : nil)
        }
    }

    /// This metadata admission cannot disclose a handoff or consume an attempt.
    func validateContinuityBootstrapRecovery(reference: ContinuityBootstrapRecoveryReference,
        policy: BudgetPolicySelection, cancellation: ToolCallCancellation? = nil) throws -> Bool {
        try controlledTransaction(cancellation: cancellation) { connection in
            let row = try requiredRecoveryMetadataUnlocked(reference, connection: connection)
            let task = try validateRecoveryTaskUnlocked(row, connection: connection)
            try ContinuityIngressAcceptanceReceipt.validatePolicy(policy, authorization: task.authorization)
            try requireSourceDispatchIdentityUnlocked(task.authorization, connection: connection)
            guard try policy.policy.automaticHandoffEnabled || hasExplicitStartMetadataUnlocked(reference: reference, task: task, connection: connection) else { return false }
            return try recoveryIsDueUnlocked(row, connection: connection)
        }
    }

    func claimContinuityBootstrapRecovery(reference: ContinuityBootstrapRecoveryReference,
        lease: RunLease, policy: BudgetPolicySelection, cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityBootstrapRecoveryClaim {
        let result: Result<ContinuityBootstrapRecoveryClaim, ContinuityBootstrapRecoveryError> = try controlledTransaction(
            cancellation: cancellation, fullDurability: true) { connection in
                let row = try requiredRecoveryMetadataUnlocked(reference, connection: connection)
                let task = try validateRecoveryTaskUnlocked(row, connection: connection)
                guard lease.runID == reference.runID else { throw ContinuityBootstrapRecoveryError.claimConflict }
                try verifyRunLeaseUnlocked(lease, timestamp: ISO8601.string(from: clock.now()), connection: connection)
                try ContinuityIngressAcceptanceReceipt.validatePolicy(policy, authorization: task.authorization)
                try requireSourceDispatchIdentityUnlocked(task.authorization, connection: connection)
                guard try policy.policy.automaticHandoffEnabled || hasExplicitStartMetadataUnlocked(reference: reference, task: task, connection: connection) else { throw ContinuityBootstrapRecoveryError.policyDeferred }
                try requireRecoveryDueUnlocked(row)
                if row.claimID != nil && row.leaseOwner == lease.ownerID && row.leaseEpoch == lease.epoch {
                    throw ContinuityBootstrapRecoveryError.claimConflict
                }
                let acceptance: ContinuityIngressAcceptanceReceipt
                do {
                    guard let value = try continuityIngressAcceptanceUnlocked(operationID: reference.operationID,
                        keySHA256: row.keySHA256, connection: connection) else {
                        throw ContinuityIngressError.integrityFailure("recovery acceptance missing")
                    }
                    try validateBootstrapReceiptUnlocked(value, lease: lease, connection: connection)
                    guard value.receiptSHA256 == reference.receiptSHA256 else {
                        throw ContinuityIngressError.integrityFailure("recovery receipt differs from metadata")
                    }
                    _ = try validateSourceStartAuthorityUnlocked(acceptance: value, lease: lease, policySelection: policy, connection: connection)
                    acceptance = value
                } catch {
                    guard Self.isRecoveryIntegrityError(error) else { throw error }
                    try quarantineRecoveryUnlocked(rowID: reference.rowID, connection: connection)
                    return .failure(.quarantined)
                }
                let now = clock.now(), claimID = UUID(), attempt = row.attempts + 1
                let timestamp = ISO8601.string(from: now)
                let deadline = row.deadline ?? ISO8601.string(from: now.addingTimeInterval(ContinuityBootstrapRecoveryLimits.retryWindow))
                // An owner dying after dispatch cannot immediately spend another
                // attempt inside the native provider's unknown-outcome fence.
                let abandonedRetry = ISO8601.string(from: now.addingTimeInterval(660))
                let prefix = reference.phase == .bootstrap ? "recovery" : "finalization"
                try connection.execute("""
                    UPDATE continuity_ingress_holds SET \(prefix)_attempts=?,\(prefix)_started_at=COALESCE(\(prefix)_started_at,?),
                      \(prefix)_deadline=?,\(prefix)_retry_at=?,recovery_claim_id=?,recovery_lease_owner=?,
                      recovery_lease_epoch=?,recovery_claim_phase=?,recovery_error_code=NULL,updated_at=? WHERE rowid=?
                    """, bindings: [.int64(Int64(attempt)), .text(timestamp), .text(deadline), .text(abandonedRetry),
                        .text(claimID.uuidString.lowercased()), .text(lease.ownerID), .int64(Int64(lease.epoch)),
                        .text(reference.phase.rawValue), .text(timestamp), .int64(reference.rowID)])
                return .success(.init(reference: reference, acceptance: acceptance, claimID: claimID,
                                      attempt: attempt, retryDeadline: deadline))
            }
        return try result.get()
    }

    func finishContinuityBootstrapRecovery(claim: ContinuityBootstrapRecoveryClaim, lease: RunLease,
        outcome: ContinuityBootstrapRecoveryOutcome, cancellation: ToolCallCancellation? = nil) throws {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            let row = try validateRecoveryClaimUnlocked(claim, lease: lease, connection: connection)
            let now = clock.now(), timestamp = ISO8601.string(from: now)
            var attempts = row.attempts
            var errorCode: ContinuityBootstrapRecoveryFailure?
            var retry: String?
            var quarantined = false
            switch outcome {
            case .deferredPolicy:
                attempts -= 1
                retry = ISO8601.string(from: now.addingTimeInterval(30))
            case .cancelled:
                errorCode = .interrupted
                retry = ISO8601.string(from: now.addingTimeInterval(660))
            case .failed(let failure, let requested):
                if let requested, !requested.isFinite || requested < 0 {
                    throw ContinuityBootstrapRecoveryError.invalidRequest
                }
                let backoff = min(ContinuityBootstrapRecoveryLimits.maximumRetryDelay,
                    ContinuityBootstrapRecoveryLimits.initialRetryDelay * pow(2, Double(max(0, attempts - 1))))
                let delay = max(backoff, requested ?? 0)
                errorCode = failure
                quarantined = failure == .integrityFailure
                if delay > ContinuityBootstrapRecoveryLimits.maximumRequestedRetryDelay
                    || now.addingTimeInterval(delay) >= (ISO8601.date(from: claim.retryDeadline) ?? .distantPast) {
                    errorCode = .retryWindowExceeded
                    attempts = ContinuityBootstrapRecoveryLimits.maximumAttempts
                } else { retry = ISO8601.string(from: now.addingTimeInterval(delay)) }
            }
            if outcome != .deferredPolicy,
               let retry, (ISO8601.date(from: retry) ?? .distantFuture) >= (ISO8601.date(from: claim.retryDeadline) ?? .distantPast) {
                attempts = ContinuityBootstrapRecoveryLimits.maximumAttempts
                errorCode = .retryWindowExceeded
            }
            let prefix = claim.reference.phase == .bootstrap ? "recovery" : "finalization"
            try connection.execute("""
                UPDATE continuity_ingress_holds SET \(prefix)_attempts=?,\(prefix)_retry_at=?,recovery_error_code=?,
                  \(prefix)_started_at=?,\(prefix)_deadline=?,recovery_quarantined=?,recovery_claim_id=NULL,recovery_lease_owner=NULL,recovery_lease_epoch=NULL,recovery_claim_phase=NULL,updated_at=?
                WHERE rowid=? AND recovery_claim_id=?
                """, bindings: [.int64(Int64(attempts)), .optionalText(retry), .optionalText(errorCode?.rawValue),
                    .optionalText(attempts == 0 ? nil : row.startedAt), .optionalText(attempts == 0 ? nil : row.deadline),
                    .int64(quarantined ? 1 : 0), .text(timestamp), .int64(claim.reference.rowID),
                    .text(claim.claimID.uuidString.lowercased())])
        }
    }

    /// Suppresses scheduling only after the actual canonical ACK and both durable
    /// provider turns plus the successful exact-source retrieval agree.
    func markContinuityBootstrapAcknowledged(claim: ContinuityBootstrapRecoveryClaim, lease: RunLease,
        cancellation: ToolCallCancellation? = nil,
        readCanonical: @Sendable () throws -> ContinuitySourceBootstrapOperation) throws {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            guard claim.reference.phase == .bootstrap else { throw ContinuityBootstrapRecoveryError.claimConflict }
            try validateBootstrapReceiptUnlocked(claim.acceptance, lease: lease, connection: connection)
            let previous = try connection.first("SELECT recovery_ack_sha256 FROM continuity_ingress_holds WHERE operation_id=? AND run_id=? AND state='awaiting_bootstrap'",
                bindings: [.text(claim.reference.operationID.uuidString.lowercased()), .text(claim.reference.runID.description)],
                map: { try $0.strictText(0, maximumBytes: 64) }) ?? nil
            if previous == nil { _ = try validateRecoveryClaimUnlocked(claim, lease: lease, connection: connection) }
            let operation = try readCanonical()
            try validateRecoveryAcknowledgementUnlocked(operation, claim: claim, connection: connection)
            try validateBootstrapReceiptUnlocked(claim.acceptance, lease: lease, connection: connection)
            if let previous {
                guard previous == operation.stateChecksum else { throw ContinuityBootstrapRecoveryError.claimConflict }
                return
            }
            let changed = try connection.execute("""
                UPDATE continuity_ingress_holds SET recovery_ack_sha256=?,recovery_error_code=NULL,recovery_retry_at=NULL,
                  recovery_claim_id=NULL,recovery_lease_owner=NULL,recovery_lease_epoch=NULL,recovery_claim_phase=NULL,updated_at=?
                WHERE rowid=? AND recovery_claim_id=? AND recovery_ack_sha256 IS NULL
                """, bindings: [.text(operation.stateChecksum), .text(ISO8601.string(from: clock.now())),
                    .int64(claim.reference.rowID), .text(claim.claimID.uuidString.lowercased())])
            guard changed == 1 else { throw ContinuityBootstrapRecoveryError.claimConflict }
        }
    }

    func continuityBootstrapProviderResult(grant: ContinuityBootstrapGrant, turnID: UUID,
                                           lease: RunLease) throws -> ProviderTurn? {
        try controlledTransaction(cancellation: nil) { connection in
            try validateBootstrapGrantUnlocked(grant, lease: lease, connection: connection)
            return try bootstrapProviderResultUnlocked(grant: grant, turnID: turnID, connection: connection)
        }
    }

    /// Executes the actual immutable-source read while live task/generation and
    /// lease authority are guarded. No caller-supplied digest can skip this read.
    func executeContinuityBootstrapRetrieval(grant: ContinuityBootstrapGrant, invocationID: UUID,
        lease: RunLease, cancellation: ToolCallCancellation? = nil,
        resolver: @Sendable (ContinuityHandoffRevision) throws -> ContinuityBootstrapReadResult
    ) throws -> ContinuityBootstrapRetrievalProof {
        try controlledTransaction(cancellation: cancellation, fullDurability: true) { connection in
            try validateBootstrapGrantUnlocked(grant, lease: lease, connection: connection)
            guard let invocation = try toolInvocationUnlocked(invocationID, connection: connection),
                  invocation.sessionID == grant.sessionID, invocation.runID == grant.envelope.runID,
                  invocation.toolName == "context_get", invocation.replayClass == .readOnly,
                  let result = try bootstrapProviderResultUnlocked(grant: grant, turnID: invocation.turnID, connection: connection),
                  result.previousResponseID == nil, result.toolCalls.count == 1 else {
                throw ContinuityIngressError.authorityMismatch
            }
            if let inherited = try nativeSourceBudgetCarryoverUnlocked(runID: grant.envelope.runID, connection: connection) {
                try requireBootstrapResultLimitsUnlocked(grant: grant, policy: inherited.ceilings.tools, connection: connection)
                let offset = try Self.nativeSourceCheckedAdd(inherited.priorSourceReadCallsAtEnrollment, inherited.admittedProviderCalls)
                try requireNativeManagedToolQuotaUnlocked(intent: Self.nativeRetainedToolIntent(invocation), offset: offset,
                    policy: inherited.ceilings.tools, alreadyReserved: true, connection: connection)
            }
            let call = result.toolCalls[0]
            try validateExactBootstrapCall(call, source: grant.envelope.sourceIdentity)
            guard call.callID == invocation.providerCallID,
                  try bootstrapCallSHA256(call) == invocation.argumentsSHA256 else {
                throw ContinuityIngressError.authorityMismatch
            }
            if let proof = try bootstrapRetrievalProofUnlocked(grant: grant, connection: connection) {
                guard invocation.state == .completed, proof.toolInvocationID == invocationID,
                      proof.providerTurnID == invocation.turnID, proof.providerResponseID == result.responseID,
                      proof.providerCallID == call.callID, invocation.resultSHA256 == proof.toolResultSHA256,
                      invocation.resultSummary == String(data: proof.canonicalToolResultJSON, encoding: .utf8) else {
                    throw ContinuityIngressError.integrityFailure("retrieval proof differs from completed invocation")
                }
                return proof
            }
            guard invocation.state == .executing else { throw ContinuityIngressError.deliveryConflict }
            let read = try resolver(grant.envelope.acceptance.source)
            try cancellation?.checkCancellation()
            try validateBootstrapGrantUnlocked(grant, lease: lease, connection: connection)
            let proof = try ContinuityBootstrapRetrievalProof(grant: grant, providerTurnID: invocation.turnID,
                providerResponseID: result.responseID, providerCallID: call.callID, toolInvocationID: invocationID,
                result: read, retrievedAt: ISO8601.string(from: clock.now()))
            let changed = try connection.execute("""
                UPDATE tool_invocations SET state='completed',result_sha256=?,result_summary=?,updated_at=?
                WHERE invocation_id=? AND state='executing'
                """, bindings: [.text(proof.toolResultSHA256), .text(String(decoding: proof.canonicalToolResultJSON, as: UTF8.self)),
                    .text(proof.retrievedAt), .text(invocationID.uuidString.lowercased())])
            guard changed == 1 else { throw ContinuityIngressError.deliveryConflict }
            try connection.execute("""
                INSERT INTO continuity_bootstrap_retrieval_proofs(grant_id,invocation_id,proof_json,proof_sha256)
                VALUES(?,?,?,?)
                """, bindings: [.text(grant.grantID.uuidString.lowercased()), .text(invocationID.uuidString.lowercased()),
                    .text(String(decoding: proof.canonicalProofJSON, as: UTF8.self)), .text(proof.proofSHA256)])
            return proof
        }
    }

    @discardableResult
    func revokeContinuityTask(taskID: UUID, projectID: ProjectID, expectedGeneration: ProjectGeneration,
                              cancellation: ToolCallCancellation? = nil) throws -> ContinuityTaskAuthorizationRecord {
        let timestamp = ISO8601.string(from: clock.now())
        return try controlledTransaction(cancellation: cancellation) { connection in
            guard let record = try continuityTaskUnlocked(taskID, connection: connection),
                  record.authorization.projectID == projectID,
                  record.authorization.projectGeneration == expectedGeneration else {
                throw ContinuityTaskAuthorizationError.authorityMismatch
            }
            if record.state == .revoked { return record }
            try revokeContinuityTasksUnlocked(projectID: projectID, generation: expectedGeneration,
                taskID: taskID, timestamp: timestamp, connection: connection)
            guard let revoked = try continuityTaskUnlocked(taskID, connection: connection) else {
                throw ContinuityTaskAuthorizationError.integrityFailure("revoked task disappeared")
            }
            return revoked
        }
    }

    @discardableResult
    public func bind(
        owner: ProjectBindingOwner,
        projectID: ProjectID,
        generation: ProjectGeneration,
        runID: RunID? = nil,
        authorizationScope: ToolAuthorizationScope,
        leaseOwner: String? = nil,
        leaseExpiresAt: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectContextBinding {
        try cancellation?.checkCancellation()
        try Self.validate(owner)
        try Self.validate(generation)
        try Self.validate(authorizationScope)
        let scopeJSON = try Self.scopeJSON(authorizationScope)
        let boundedLeaseOwner = try Self.boundedOptional(leaseOwner, maximumBytes: 512, field: "lease owner")
        let boundedLeaseExpiry = try Self.boundedOptional(leaseExpiresAt, maximumBytes: 128, field: "lease expiry")
        let timestamp = ISO8601.string(from: clock.now())
        try cancellation?.checkCancellation()

        return try controlledTransaction(cancellation: cancellation) { connection in
            let project = try requiredActiveProjectUnlocked(
                projectID,
                generation: generation,
                connection: connection
            )
            _ = project

            if let existing = try bindingUnlocked(owner: owner, includeInactive: true, connection: connection) {
                if existing.active {
                    guard existing.projectID == projectID,
                          existing.projectGeneration == generation,
                          existing.runID == runID,
                          existing.authorizationScope == authorizationScope else {
                        throw ProjectContextError.ownerAlreadyBound(owner)
                    }
                    return existing
                }
                try connection.execute(
                    """
                    UPDATE project_bindings SET
                        project_id=?,project_generation=?,run_id=?,authorization_scope_json=?,
                        lease_owner=?,lease_expires_at=?,active=1,updated_at=?
                    WHERE owner_kind=? AND owner_id=? AND active=0
                    """,
                    bindings: [
                        .text(projectID.description), .int64(try Self.sqliteGeneration(generation)),
                        .optionalText(runID?.description), .text(scopeJSON),
                        .optionalText(boundedLeaseOwner), .optionalText(boundedLeaseExpiry),
                        .text(timestamp), .text(owner.kind.rawValue), .text(owner.id),
                    ]
                )
            } else {
                try connection.execute(
                    """
                    INSERT INTO project_bindings(
                        binding_id,owner_kind,owner_id,project_id,project_generation,run_id,
                        authorization_scope_json,lease_owner,lease_expires_at,active,created_at,updated_at
                    ) VALUES(?,?,?,?,?,?,?,?,?,1,?,?)
                    """,
                    bindings: [
                        .text(UUID().uuidString.lowercased()), .text(owner.kind.rawValue), .text(owner.id),
                        .text(projectID.description), .int64(try Self.sqliteGeneration(generation)),
                        .optionalText(runID?.description), .text(scopeJSON),
                        .optionalText(boundedLeaseOwner), .optionalText(boundedLeaseExpiry),
                        .text(timestamp), .text(timestamp),
                    ]
                )
            }
            guard let binding = try bindingUnlocked(owner: owner, includeInactive: false, connection: connection) else {
                throw ProjectContextError.integrityFailure("project binding could not be read back")
            }
            return binding
        }
    }

    public func binding(
        for owner: ProjectBindingOwner,
        includeInactive: Bool = false,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectContextBinding? {
        try Self.validate(owner)
        return try controlledOperation(cancellation: cancellation) { connection in
            try bindingUnlocked(
                owner: owner,
                includeInactive: includeInactive,
                connection: connection
            )
        }
    }

    public func invocationContext(
        for owner: ProjectBindingOwner,
        clientID: ClientID? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ToolInvocationContext {
        try cancellation?.checkCancellation()
        try Self.validate(owner)
        return try controlledOperation(cancellation: cancellation) { connection in
            guard let binding = try bindingUnlocked(
                owner: owner,
                includeInactive: false,
                connection: connection
            ) else {
                throw ProjectContextError.projectContextRequired(owner)
            }
            _ = try requiredActiveProjectUnlocked(
                binding.projectID,
                generation: binding.projectGeneration,
                connection: connection
            )
            try requireActiveProviderSessionUnlocked(
                owner: owner,
                binding: binding,
                connection: connection
            )
            return binding.invocationContext(clientID: clientID ?? ClientID(owner.id))
        }
    }

    public func validate(
        _ context: ToolInvocationContext,
        for owner: ProjectBindingOwner,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try cancellation?.checkCancellation()
        try Self.validate(owner)
        try Self.validate(context.projectGeneration)
        try Self.validate(context.authorizationScope)
        try controlledOperation(cancellation: cancellation) { connection in
            _ = try requiredActiveProjectUnlocked(
                context.projectID,
                generation: context.projectGeneration,
                connection: connection
            )
            guard let binding = try bindingUnlocked(
                owner: owner,
                includeInactive: false,
                connection: connection
            ) else {
                throw ProjectContextError.projectContextRequired(owner)
            }
            guard binding.projectID == context.projectID,
                  binding.projectGeneration == context.projectGeneration,
                  binding.runID == context.runID,
                  binding.authorizationScope == context.authorizationScope,
                  Self.owner(owner, matches: context) else {
                throw ProjectContextError.projectScopeMismatch
            }
            try requireActiveProviderSessionUnlocked(
                owner: owner,
                binding: binding,
                connection: connection
            )
        }
    }

    /// Runs a short synchronous result mutation only while the durable project generation
    /// and owner binding are still current. Actor isolation serializes this check and mutation
    /// against generation resets. Callers must keep the closure bounded and nonblocking.
    public func commitIfCurrent<Value: Sendable>(
        context: ToolInvocationContext,
        owner: ProjectBindingOwner,
        resultKind: String,
        resultSHA256: String? = nil,
        cancellation: ToolCallCancellation? = nil,
        mutation: @Sendable () throws -> Value
    ) throws -> Value {
        try cancellation?.checkCancellation()
        try Self.validate(owner)
        try Self.validate(context.projectGeneration)
        try Self.validate(context.authorizationScope)
        do {
            return try controlledTransaction(
                cancellation: cancellation,
                checkCancellationBeforeCommit: false
            ) { connection in
                guard let project = try projectUnlocked(context.projectID, connection: connection) else {
                    throw ProjectContextError.projectNotFound(context.projectID)
                }
                guard project.generation == context.projectGeneration else {
                    throw DelayedResultFenceError.staleGeneration(project.generation)
                }
                guard project.lifecycleState == .active else {
                    throw ProjectContextError.projectNotActive(project.lifecycleState)
                }
                guard let binding = try bindingUnlocked(owner: owner, includeInactive: false, connection: connection) else {
                    throw ProjectContextError.projectContextRequired(owner)
                }
                guard binding.projectID == context.projectID,
                      binding.projectGeneration == context.projectGeneration,
                      binding.runID == context.runID,
                      binding.authorizationScope == context.authorizationScope,
                      Self.owner(owner, matches: context) else {
                    throw ProjectContextError.projectScopeMismatch
                }
                try requireActiveProviderSessionUnlocked(
                    owner: owner,
                    binding: binding,
                    connection: connection
                )
                // The external repository shares this request's commit authority. It
                // may ignore polling while doing bounded preparation, but it must claim
                // the authority only around its irreversible commit so cancellation can
                // revoke a mutator that has not reached that boundary.
                try cancellation?.checkCancellation()
                let value = try mutation()
                // Database/file repositories publish a lower-layer receipt at their
                // actual commit boundary. Promote it immediately to this bridge's
                // exact result before any later control-plane completion observer can
                // delay result delivery.
                cancellation?.promoteCommittedResultIfPresent(value)
                // The external mutation has returned its authoritative outcome. Do not
                // let a later cancellation conceal it while this read-only guard
                // transaction is closed.
                connection.finishRequestCancellationWindow()
                return value
            }
        } catch DelayedResultFenceError.staleGeneration(let actualGeneration) {
            _ = try quarantineStaleResult(
                context: context,
                resultKind: resultKind,
                resultSHA256: resultSHA256,
                cancellation: cancellation
            )
            throw ProjectContextError.staleProjectGeneration(
                expected: context.projectGeneration,
                actual: actualGeneration
            )
        }
    }

    @discardableResult
    public func beginReset(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectControlRecord {
        try cancellation?.checkCancellation()
        try Self.validate(expectedGeneration)
        let timestamp = ISO8601.string(from: clock.now())
        return try controlledTransaction(cancellation: cancellation) { connection in
            _ = try requiredActiveProjectUnlocked(
                projectID,
                generation: expectedGeneration,
                connection: connection
            )
            let changed = try connection.execute(
                """
                UPDATE control_projects SET lifecycle_state='resetting',updated_at=?
                WHERE project_id=? AND generation=? AND lifecycle_state='active'
                """,
                bindings: [
                    .text(timestamp), .text(projectID.description),
                    .int64(try Self.sqliteGeneration(expectedGeneration)),
                ]
            )
            guard changed == 1,
                  let project = try projectUnlocked(projectID, connection: connection) else {
                throw ProjectContextError.databaseFailure("project reset compare-and-set failed")
            }
            try revokeContinuityTasksUnlocked(projectID: projectID, generation: expectedGeneration,
                taskID: nil, timestamp: timestamp, connection: connection)
            return project
        }
    }

    @discardableResult
    public func completeReset(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ProjectGenerationResetReceipt {
        try cancellation?.checkCancellation()
        try Self.validate(expectedGeneration)
        guard expectedGeneration.rawValue < UInt64(Int64.max) else {
            throw ProjectContextError.invalidGeneration(expectedGeneration.rawValue)
        }
        let timestamp = ISO8601.string(from: clock.now())
        return try controlledTransaction(cancellation: cancellation) { connection in
            guard let current = try projectUnlocked(projectID, connection: connection) else {
                throw ProjectContextError.projectNotFound(projectID)
            }
            guard current.generation == expectedGeneration else {
                throw ProjectContextError.staleProjectGeneration(
                    expected: expectedGeneration,
                    actual: current.generation
                )
            }
            guard current.lifecycleState == .resetting else {
                throw ProjectContextError.resetNotPrepared(projectID)
            }
            let invalidated = try connection.execute(
                """
                UPDATE project_bindings SET active=0,lease_owner=NULL,lease_expires_at=NULL,updated_at=?
                WHERE project_id=? AND project_generation=? AND active=1
                """,
                bindings: [
                    .text(timestamp), .text(projectID.description),
                    .int64(try Self.sqliteGeneration(expectedGeneration)),
                ]
            )
            let next = ProjectGeneration(expectedGeneration.rawValue + 1)
            let changed = try connection.execute(
                """
                UPDATE control_projects SET generation=?,lifecycle_state='active',updated_at=?
                WHERE project_id=? AND generation=? AND lifecycle_state='resetting'
                """,
                bindings: [
                    .int64(try Self.sqliteGeneration(next)), .text(timestamp),
                    .text(projectID.description), .int64(try Self.sqliteGeneration(expectedGeneration)),
                ]
            )
            guard changed == 1 else {
                throw ProjectContextError.databaseFailure("project generation compare-and-set failed")
            }
            try appendEventUnlocked(
                projectID: projectID,
                eventType: "project_generation_reset",
                severity: "info",
                summary: "Project generation advanced after reset",
                metadata: [
                    "prior_generation": String(expectedGeneration.rawValue),
                    "new_generation": String(next.rawValue),
                    "invalidated_bindings": String(invalidated),
                ],
                connection: connection
            )
            return ProjectGenerationResetReceipt(
                projectID: projectID,
                priorGeneration: expectedGeneration,
                newGeneration: next,
                invalidatedBindingCount: invalidated,
                completedAt: timestamp
            )
        }
    }

    public func cancelReset(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try cancellation?.checkCancellation()
        try Self.validate(expectedGeneration)
        try controlledTransaction(cancellation: cancellation) { connection in
            let changed = try connection.execute(
                """
                UPDATE control_projects SET lifecycle_state='active',updated_at=?
                WHERE project_id=? AND generation=? AND lifecycle_state='resetting'
                """,
                bindings: [
                    .text(ISO8601.string(from: clock.now())), .text(projectID.description),
                    .int64(try Self.sqliteGeneration(expectedGeneration)),
                ]
            )
            guard changed == 1 else {
                guard let project = try projectUnlocked(projectID, connection: connection) else {
                    throw ProjectContextError.projectNotFound(projectID)
                }
                guard project.generation == expectedGeneration else {
                    throw ProjectContextError.staleProjectGeneration(
                        expected: expectedGeneration,
                        actual: project.generation
                    )
                }
                throw ProjectContextError.resetNotPrepared(projectID)
            }
        }
    }

    // MARK: - Persisted context budget

    public func contextBudgetState(
        identity: ContextBudgetIdentity
    ) throws -> PersistedContextBudgetState? {
        _ = try identity.validated()
        return try contextBudgetStateUnlocked(
            identity: identity,
            connection: requiredConnection()
        )
    }

    public func latestContextBudgetObservation(
        identity: ContextBudgetIdentity
    ) throws -> ContextBudgetObservation? {
        _ = try identity.validated()
        return try requiredConnection().first(
            Self.contextBudgetObservationSelect
                + " WHERE o.run_id=? AND o.session_id=? ORDER BY o.rowid DESC LIMIT 1",
            bindings: [.text(identity.runID.description), .text(identity.sessionID)],
            map: Self.decodeContextBudgetObservation
        )
    }

    public func contextBudgetObservation(
        observationID: UUID
    ) throws -> ContextBudgetObservation? {
        try requiredConnection().first(
            Self.contextBudgetObservationSelect
                + " WHERE o.observation_id=? LIMIT 1",
            bindings: [.text(observationID.uuidString.lowercased())],
            map: Self.decodeContextBudgetObservation
        )
    }

    public func contextBudgetObservations(
        identity: ContextBudgetIdentity,
        limit: Int = 256
    ) throws -> [ContextBudgetObservation] {
        _ = try identity.validated()
        guard (1...Self.maximumContextBudgetObservationsPerSession).contains(limit) else {
            throw ContextBudgetError.invalidObservation("observation query limit is outside bounds")
        }
        return try requiredConnection().all(
            Self.contextBudgetObservationSelect
                + " WHERE o.run_id=? AND o.session_id=? ORDER BY o.rowid DESC LIMIT ?",
            bindings: [
                .text(identity.runID.description), .text(identity.sessionID), .int64(Int64(limit)),
            ],
            map: Self.decodeContextBudgetObservation
        )
    }

    public func contextBudgetObservationCount(
        identity: ContextBudgetIdentity
    ) throws -> Int {
        _ = try identity.validated()
        return try requiredConnection().scalarInt(
            "SELECT COUNT(*) FROM context_budget_observations WHERE run_id=? AND session_id=?",
            bindings: [.text(identity.runID.description), .text(identity.sessionID)]
        )
    }

    public func contextBudgetActionRequest(
        identity: ContextBudgetIdentity
    ) throws -> ContextBudgetActionRequest? {
        _ = try identity.validated()
        return try contextBudgetActionRequestUnlocked(
            identity: identity,
            connection: requiredConnection()
        )
    }

    public func contextBudgetActionRequest(
        requestID: UUID
    ) throws -> ContextBudgetActionRequest? {
        try contextBudgetActionRequestUnlocked(
            requestID: requestID,
            connection: requiredConnection()
        )
    }

    public func contextBudgetActionRequest(
        runID: RunID,
        continuityOperationID: UUID
    ) throws -> ContextBudgetActionRequest? {
        try requiredConnection().first(
            Self.contextBudgetActionRequestSelect
                + " WHERE run_id=? AND continuity_operation_id=? LIMIT 1",
            bindings: [
                .text(runID.description),
                .text(continuityOperationID.uuidString.lowercased()),
            ],
            map: Self.decodeContextBudgetActionRequest
        )
    }

    public func pendingContextBudgetActionRequest(
        runID: RunID
    ) throws -> ContextBudgetActionRequest? {
        try requiredConnection().first(
            Self.contextBudgetActionRequestSelect
                + """
                 WHERE run_id=? AND (
                    fulfilled_action IS NULL
                    OR (requested_action='rollover' AND fulfilled_action='checkpoint')
                    OR (requested_action='emergency' AND fulfilled_action IN ('checkpoint','rollover'))
                 )
                 ORDER BY CASE requested_action
                    WHEN 'emergency' THEN 3 WHEN 'rollover' THEN 2 ELSE 1 END DESC,
                    updated_at,request_id LIMIT 1
                """,
            bindings: [.text(runID.description)],
            map: Self.decodeContextBudgetActionRequest
        )
    }

    /// Returns manager work whose requested severity has not yet been durably fulfilled.
    /// Consumers must reuse `continuityOperationID` when they create or resume Handoff V2.
    public func pendingContextBudgetActionRequests(
        limit: Int = 64
    ) throws -> [ContextBudgetActionRequest] {
        guard (1...Self.maximumContextBudgetActionRequestsPerRead).contains(limit) else {
            throw ContextBudgetError.invalidActionRequest
        }
        return try requiredConnection().all(
            Self.contextBudgetActionRequestSelect
                + """
                 WHERE fulfilled_action IS NULL
                    OR (requested_action='rollover' AND fulfilled_action='checkpoint')
                    OR (requested_action='emergency' AND fulfilled_action IN ('checkpoint','rollover'))
                 ORDER BY CASE requested_action
                    WHEN 'emergency' THEN 3 WHEN 'rollover' THEN 2 ELSE 1 END DESC,
                    updated_at,request_id LIMIT ?
                """,
            bindings: [.int64(Int64(limit))],
            map: Self.decodeContextBudgetActionRequest
        )
    }

    /// Records only a continuity stage that is already durable. A revision fence makes a
    /// checkpoint completion lose cleanly if the budget escalated to rollover meanwhile.
    @discardableResult
    public func markContextBudgetActionFulfilled(
        requestID: UUID,
        expectedRevision: UInt64,
        fulfilledAction: ContextBudgetAction,
        lease: RunLease
    ) throws -> ContextBudgetActionRequest {
        guard fulfilledAction != .normal,
              expectedRevision > 0,
              expectedRevision < UInt64(Int64.max) else {
            throw ContextBudgetError.invalidActionRequest
        }
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
            guard let current = try contextBudgetActionRequestUnlocked(
                requestID: requestID,
                connection: connection
            ) else {
                throw ContextBudgetError.actionRequestNotFound(requestID)
            }
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            guard lease.runID == current.identity.runID,
                  current.revision == expectedRevision,
                  fulfilledAction.severity <= current.requestedAction.severity,
                  fulfilledAction.severity >= (current.fulfilledAction?.severity ?? 0) else {
                throw ContextBudgetError.persistenceConflict
            }
            if current.fulfilledAction == fulfilledAction { return current }
            let changed = try connection.execute(
                """
                UPDATE context_budget_action_requests
                SET fulfilled_action=?,revision=revision+1,updated_at=?
                WHERE request_id=? AND revision=?
                """,
                bindings: [
                    .text(fulfilledAction.rawValue), .text(timestamp),
                    .text(requestID.uuidString.lowercased()),
                    .int64(Int64(expectedRevision)),
                ]
            )
            guard changed == 1 else { throw ContextBudgetError.persistenceConflict }
            try appendAutonomyEventUnlocked(
                runID: current.identity.runID,
                projectID: current.identity.projectID,
                eventType: "context_budget_action_fulfilled",
                severity: .info,
                summary: "A durable context budget action stage was fulfilled",
                metadata: [
                    "action": fulfilledAction.rawValue,
                    "request_id": requestID.uuidString.lowercased(),
                ],
                connection: connection
            )
            guard let updated = try contextBudgetActionRequestUnlocked(
                requestID: requestID,
                connection: connection
            ) else {
                throw ProjectContextError.integrityFailure(
                    "context budget action request disappeared after fulfillment"
                )
            }
            return updated
        }
    }

    /// Commits the observation, adaptive estimator state, and any resulting manager
    /// action request together. The final continuity command is deliberately deferred
    /// until the project-local V2 handoff is durable.
    @discardableResult
    public func persistContextBudget(
        _ commit: ContextBudgetPersistenceCommit
    ) throws -> ContextBudgetCommitReceipt {
        try validateContextBudgetCommit(commit)
        let connection = try requiredConnection()
        let stateData = try Self.sortedJSONEncoder.encode(commit.state)
        let observationData = try Self.sortedJSONEncoder.encode(commit.observation)
        guard stateData.count <= 64 * 1_024,
              observationData.count <= Self.maximumContextBudgetObservationBytes,
              let stateJSON = String(data: stateData, encoding: .utf8),
              let observationJSON = String(data: observationData, encoding: .utf8) else {
            throw ContextBudgetError.invalidPersistedState
        }
        return try connection.transaction {
            let identity = commit.observation.identity
            _ = try requiredActiveProjectUnlocked(
                identity.projectID,
                generation: identity.projectGeneration,
                connection: connection
            )
            guard let run = try autonomousRunUnlocked(identity.runID, connection: connection) else {
                throw AutonomyError.runNotFound(identity.runID)
            }
            guard run.projectID == identity.projectID,
                  run.projectGeneration == identity.projectGeneration else {
                throw ProjectContextError.projectScopeMismatch
            }
            guard let session = try providerSessionIdentityUnlocked(
                identity.sessionID,
                connection: connection
            ) else {
                throw AutonomyError.providerSessionNotFound(identity.sessionID)
            }
            guard session.runID == identity.runID,
                  session.projectID == identity.projectID,
                  session.projectGeneration == identity.projectGeneration else {
                throw ProjectContextError.projectScopeMismatch
            }
            guard try connection.scalarInt(
                "SELECT COUNT(*) FROM context_budget_observations WHERE observation_id=?",
                bindings: [.text(commit.observation.observationID.uuidString.lowercased())]
            ) == 0 else {
                throw ContextBudgetError.persistenceConflict
            }

            let previous = try contextBudgetStateUnlocked(
                identity: identity,
                connection: connection
            )
            if let previous {
                guard previous.revision < UInt64(Int64.max),
                      commit.state.revision == previous.revision + 1 else {
                    throw ContextBudgetError.persistenceConflict
                }
            } else {
                guard commit.state.revision == 1 else {
                    throw ContextBudgetError.persistenceConflict
                }
            }

            let observation = commit.observation
            try connection.execute(
                """
                INSERT INTO context_budget_observations(
                    observation_id,run_id,session_id,provider_response_id,capacity,used,
                    output_reserve,schema_reserve,handoff_reserve,recovery_reserve,remaining,
                    projected_next_turn,source,confidence,estimator_version,action,created_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                bindings: [
                    .text(observation.observationID.uuidString.lowercased()),
                    .text(identity.runID.description), .text(identity.sessionID),
                    .optionalText(observation.providerResponseID), .int64(Int64(observation.capacity)),
                    .int64(Int64(observation.used)), .int64(Int64(observation.reserves.outputTokens)),
                    .int64(Int64(observation.reserves.schemaTokens)),
                    .int64(Int64(observation.reserves.handoffTokens)),
                    .int64(Int64(observation.reserves.recoveryTokens)),
                    .int64(Int64(observation.remaining)),
                    .int64(Int64(observation.projectedNextTurn)), .text(observation.source.rawValue),
                    .text(String(observation.confidence)), .text(observation.estimatorVersion),
                    .text(observation.action.rawValue), .text(observation.createdAt),
                ]
            )
            try connection.execute(
                """
                INSERT INTO context_budget_observation_details(
                    observation_id,project_id,project_generation,trigger_point,
                    checkpoint_threshold,rollover_threshold,emergency_floor,hysteresis,
                    action_epoch,created_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?)
                """,
                bindings: [
                    .text(observation.observationID.uuidString.lowercased()),
                    .text(identity.projectID.description),
                    .int64(try Self.sqliteGeneration(identity.projectGeneration)),
                    .text(observation.triggerPoint.rawValue),
                    .int64(Int64(observation.thresholds.checkpoint)),
                    .int64(Int64(observation.thresholds.rollover)),
                    .int64(Int64(observation.thresholds.emergency)),
                    .int64(Int64(observation.thresholds.hysteresis)),
                    .int64(Int64(observation.actionEpoch)), .text(observation.createdAt),
                ]
            )

            try connection.execute(
                """
                INSERT INTO context_budget_observation_metadata(observation_id,observation_json)
                VALUES(?,?)
                """,
                bindings: [
                    .text(observation.observationID.uuidString.lowercased()),
                    .text(observationJSON),
                ]
            )

            let stateChanged: Int
            if let previous {
                stateChanged = try connection.execute(
                    """
                    UPDATE context_budget_supervisor_state SET state_json=?,latest_observation_id=?,
                        revision=?,updated_at=? WHERE run_id=? AND session_id=? AND revision=?
                    """,
                    bindings: [
                        .text(stateJSON),
                        .text(observation.observationID.uuidString.lowercased()),
                        .int64(Int64(commit.state.revision)), .text(commit.state.updatedAt),
                        .text(identity.runID.description), .text(identity.sessionID),
                        .int64(Int64(previous.revision)),
                    ]
                )
            } else {
                stateChanged = try connection.execute(
                    """
                    INSERT INTO context_budget_supervisor_state(
                        run_id,session_id,project_id,project_generation,state_json,
                        latest_observation_id,revision,updated_at
                    ) VALUES(?,?,?,?,?,?,?,?)
                    """,
                    bindings: [
                        .text(identity.runID.description), .text(identity.sessionID),
                        .text(identity.projectID.description),
                        .int64(try Self.sqliteGeneration(identity.projectGeneration)),
                        .text(stateJSON),
                        .text(observation.observationID.uuidString.lowercased()),
                        .int64(Int64(commit.state.revision)), .text(commit.state.updatedAt),
                    ]
                )
            }
            guard stateChanged == 1 else { throw ContextBudgetError.persistenceConflict }

            try connection.execute(
                """
                UPDATE provider_sessions SET context_capacity=?,updated_at=?
                WHERE session_id=? AND run_id=? AND project_id=? AND project_generation=?
                """,
                bindings: [
                    .int64(Int64(observation.capacity)), .text(observation.createdAt),
                    .text(identity.sessionID), .text(identity.runID.description),
                    .text(identity.projectID.description),
                    .int64(try Self.sqliteGeneration(identity.projectGeneration)),
                ]
            )

            let actionRequest = try commit.actionRequest.map {
                try upsertContextBudgetActionRequestUnlocked(
                    $0,
                    timestamp: observation.createdAt,
                    connection: connection
                )
            }
            if let resolved = commit.state.configuration.resolvedPolicy,
               previous?.configuration.resolvedPolicy != resolved {
                try appendAutonomyEventUnlocked(
                    runID: identity.runID,
                    projectID: identity.projectID,
                    eventType: "budget_policy_effective",
                    severity: .info,
                    summary: "The saved budget policy became effective at a controlled boundary",
                    metadata: [
                        "observation_id": observation.observationID.uuidString.lowercased(),
                        "observation_revision": String(commit.state.revision),
                        "session_id": identity.sessionID,
                        "project_generation": String(identity.projectGeneration.rawValue),
                        "scope": resolved.selection.scope.kind.rawValue,
                        "revision": String(resolved.selection.revision),
                        "global_revision": String(resolved.selection.globalRevision),
                        "policy_source": resolved.selection.policySource,
                        "requested_context_tokens": String(resolved.requestedContextTokens),
                        "effective_context_tokens": String(resolved.effectiveContextTokens),
                        "verified_loaded_context_tokens": String(resolved.verifiedLoadedContextTokens),
                        "threshold_contract": resolved.thresholdContract,
                        "trigger_point": observation.triggerPoint.rawValue,
                    ],
                    connection: connection
                )
            }
            try appendAutonomyEventUnlocked(
                runID: identity.runID,
                projectID: identity.projectID,
                eventType: "context_budget_observed",
                severity: observation.action == .normal ? .debug : .warning,
                summary: "Context budget observation was durably evaluated",
                metadata: [
                    "action": observation.action.rawValue,
                    "action_request_id": actionRequest?.requestID.uuidString.lowercased() ?? "",
                    "observation_id": observation.observationID.uuidString.lowercased(),
                    "source": observation.source.rawValue,
                    "trigger_point": observation.triggerPoint.rawValue,
                ],
                connection: connection
            )
            try connection.execute(
                """
                DELETE FROM context_budget_observations
                WHERE observation_id IN (
                    SELECT o.observation_id FROM context_budget_observations o
                    LEFT JOIN context_budget_action_requests r
                      ON r.run_id=o.run_id AND r.session_id=o.session_id
                     AND r.observation_id=o.observation_id
                    WHERE o.run_id=? AND o.session_id=?
                    ORDER BY CASE WHEN r.request_id IS NULL THEN 1 ELSE 0 END,
                             o.rowid DESC
                    LIMIT -1 OFFSET ?
                )
                """,
                bindings: [
                    .text(identity.runID.description), .text(identity.sessionID),
                    .int64(Int64(Self.maximumContextBudgetObservationsPerSession)),
                ]
            )
            return ContextBudgetCommitReceipt(
                observation: observation,
                actionRequest: actionRequest
            )
        }
    }

    // MARK: - Durable continuity commands

    /// Creates the minimum durable run identity required before a continuity command
    /// can be queued. Repeating the same reservation is idempotent; conflicting identity
    /// is rejected rather than silently moving a run between projects or generations.
    public func reserveContinuityRun(
        runID: RunID,
        projectID: ProjectID,
        projectGeneration: ProjectGeneration,
        assignmentID: String? = nil,
        mission: String,
        mode: ContinuityMode,
        cancellation: ToolCallCancellation? = nil
    ) throws {
        try cancellation?.checkCancellation()
        try Self.validate(projectGeneration)
        let normalizedMission = mission.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMission.isEmpty, normalizedMission.utf8.count <= 16 * 1_024 else {
            throw ContinuityCommandQueueError.invalidCommand("mission must contain 1 through 16384 bytes")
        }
        let boundedAssignment = try Self.boundedOptional(
            assignmentID,
            maximumBytes: 1_024,
            field: "assignment identifier"
        )
        let timestamp = ISO8601.string(from: clock.now())
        try cancellation?.checkCancellation()
        try controlledTransaction(cancellation: cancellation) { connection in
            _ = try requiredActiveProjectUnlocked(
                projectID,
                generation: projectGeneration,
                connection: connection
            )
            if let existing = try continuityRunIdentityUnlocked(runID, connection: connection) {
                guard existing.projectID == projectID,
                      existing.projectGeneration == projectGeneration,
                      existing.mode == mode,
                      existing.assignmentID == boundedAssignment,
                      existing.mission == normalizedMission else {
                    throw ContinuityCommandQueueError.invalidCommand(
                        "run identifier is already reserved with different identity"
                    )
                }
                return
            }
            try connection.execute(
                """
                INSERT INTO autonomous_runs(
                    run_id,project_id,project_generation,assignment_id,mission,state,
                    continuity_mode,current_work_json,created_at,updated_at
                ) VALUES(?,?,?,?,?,'created',?,'{}',?,?)
                """,
                bindings: [
                    .text(runID.description), .text(projectID.description),
                    .int64(try Self.sqliteGeneration(projectGeneration)),
                    .optionalText(boundedAssignment), .text(normalizedMission),
                    .text(mode.rawValue), .text(timestamp), .text(timestamp),
                ]
            )
        }
    }

    /// Persists command intent before the manager performs continuity work. Operation ID
    /// and idempotency key both reconcile to one immutable command identity.
    @discardableResult
    public func enqueueContinuityCommand(
        _ request: ContinuityCommandRequest,
        cancellation: ToolCallCancellation? = nil
    ) throws -> ContinuityCommand {
        try cancellation?.checkCancellation()
        try validateContinuityCommandRequest(request)
        let timestamp = ISO8601.string(from: clock.now())
        try cancellation?.checkCancellation()
        return try controlledTransaction(cancellation: cancellation) { connection in
            try enqueueContinuityCommandUnlocked(
                request,
                timestamp: timestamp,
                connection: connection
            )
        }
    }

    public func continuityCommand(operationID: UUID) throws -> ContinuityCommand? {
        try continuityCommandByOperationUnlocked(
            operationID: operationID,
            connection: requiredConnection()
        )
    }

    public func continuityCommand(commandID: UUID) throws -> ContinuityCommand? {
        try continuityCommandUnlocked(
            commandID: commandID,
            connection: requiredConnection()
        )
    }

    /// Newest-first continuity commands for the read-only native operator surface.
    public func operatorContinuityCommands(limit: Int) throws -> [ContinuityCommand] {
        guard (1...100).contains(limit) else {
            throw AutonomyError.invalidRequest("operator continuity limit must be between 1 and 100")
        }
        return try requiredConnection().all(
            Self.continuityCommandSelect
                + " ORDER BY updated_at DESC,command_id DESC LIMIT ?",
            bindings: [.int64(Int64(limit))],
            map: Self.decodeContinuityCommand
        )
    }

    /// Resolves the newest continuity command for one exact project without
    /// depending on the globally limited operator feed. The single-row bound
    /// prevents a busy project or another project's newer commands from
    /// truncating the project status projection.
    public func operatorLatestContinuityCommand(
        projectID: ProjectID
    ) throws -> ContinuityCommand? {
        try requiredConnection().first(
            Self.continuityCommandSelect
                + " WHERE project_id=? ORDER BY updated_at DESC,command_id DESC LIMIT 1",
            bindings: [.text(projectID.description)],
            map: Self.decodeContinuityCommand
        )
    }

    /// Resolves only bounded, durable detail rows needed by the operator projection.
    /// No provider calls, memory reads, or process work occurs here.
    public func operatorContinuityReadModels(
        commands: [ContinuityCommand]
    ) throws -> [ManagerOperatorContinuityReadModel] {
        try operatorContinuityReadModels(commands: commands, evidenceByOperation: [:])
    }

    func operatorContinuityReadModels(
        commands: [ContinuityCommand],
        evidenceByOperation: [UUID: ManagerOperatorContinuityEvidence]
    ) throws -> [ManagerOperatorContinuityReadModel] {
        guard commands.count <= 100 else {
            throw AutonomyError.invalidRequest("operator continuity detail query is outside bounds")
        }
        let requestedOperationIDs = Set(commands.map(\.operationID))
        guard evidenceByOperation.count <= commands.count,
              Set(evidenceByOperation.keys).isSubset(of: requestedOperationIDs) else {
            throw AutonomyError.invalidRequest("operator continuity evidence is outside bounds")
        }
        let connection = try requiredConnection()
        return try commands.map { command in
            let evidence = evidenceByOperation[command.operationID]
            if let evidence {
                guard evidence.operationID == command.operationID,
                      evidence.projectID == command.projectID,
                      evidence.projectGeneration == command.projectGeneration,
                      evidence.runID == command.runID,
                      UUID(uuidString: evidence.checkpointID) != nil else {
                    throw ProjectContextError.integrityFailure(
                        "operator continuity evidence does not match its command"
                    )
                }
                if let acknowledgementSHA256 = evidence.acknowledgementSHA256 {
                    try Self.validateSHA256(
                        acknowledgementSHA256,
                        field: "continuity acknowledgement SHA-256"
                    )
                }
            }
            let run = try autonomousRunUnlocked(command.runID, connection: connection)
            let successor = try connection.first(
                Self.providerSessionSelect
                    + """
                     WHERE operation_id=? AND (accepted=1 OR predecessor_session_id IS NOT NULL)
                     ORDER BY accepted DESC,CASE status WHEN 'active' THEN 1 ELSE 0 END DESC,
                              updated_at DESC,session_id DESC LIMIT 1
                    """,
                bindings: [.text(command.operationID.uuidString.lowercased())],
                map: Self.decodeProviderSession
            )
            let predecessor = try successor?.predecessorSessionID.flatMap {
                try providerSessionRecordUnlocked($0, connection: connection)
            } ?? run?.activeSessionID.flatMap {
                try providerSessionRecordUnlocked($0, connection: connection)
            }
            let actionRequest = try connection.first(
                Self.contextBudgetActionRequestSelect
                    + " WHERE run_id=? AND continuity_operation_id=? LIMIT 1",
                bindings: [
                    .text(command.runID.description),
                    .text(command.operationID.uuidString.lowercased()),
                ],
                map: Self.decodeContextBudgetActionRequest
            )
            let observation = try actionRequest.flatMap { request in
                try connection.first(
                    Self.contextBudgetObservationSelect
                        + " WHERE o.observation_id=? LIMIT 1",
                    bindings: [.text(request.observationID.uuidString.lowercased())],
                    map: Self.decodeContextBudgetObservation
                )
            }
            return ManagerOperatorContinuityReadModel(
                command: command,
                run: run,
                predecessor: predecessor,
                successor: successor,
                automaticContinuation: try providerTurnForOperationUnlocked(
                    operationID: command.operationID,
                    kind: .automaticContinuation,
                    connection: connection
                ),
                budgetObservation: observation,
                checkpointID: evidence?.checkpointID,
                acknowledgementSHA256: evidence?.acknowledgementSHA256
            )
        }
    }

    /// Claims the oldest ready command with one compare-and-set update. A retry command
    /// is not ready until its durable retry timestamp has passed.
    public func claimNextContinuityCommand() throws -> ContinuityCommand? {
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction { () -> ContinuityCommand? in
            guard let candidate = try connection.first(
                """
                SELECT command_id FROM continuity_commands
                WHERE state='queued' OR (state='retry_wait' AND (retry_at IS NULL OR retry_at<=?))
                ORDER BY created_at,command_id LIMIT 1
                """,
                bindings: [.text(timestamp)],
                map: { $0.text(0) ?? "" }
            ),
            let commandID = UUID(uuidString: candidate) else {
                return nil
            }
            let changed = try connection.execute(
                """
                UPDATE continuity_commands SET state='claimed',attempt=attempt+1,
                    retry_at=NULL,last_error_code=NULL,last_error_summary=NULL,updated_at=?
                WHERE command_id=?
                  AND (state='queued' OR (state='retry_wait' AND (retry_at IS NULL OR retry_at<=?)))
                """,
                bindings: [
                    .text(timestamp), .text(commandID.uuidString.lowercased()), .text(timestamp),
                ]
            )
            guard changed == 1 else { throw ContinuityCommandQueueError.claimConflict }
            guard let claimed = try continuityCommandUnlocked(commandID: commandID, connection: connection) else {
                throw ProjectContextError.integrityFailure("claimed continuity command could not be read back")
            }
            return claimed
        }
    }

    /// Claims only the command owned by the leased run and exact continuity operation.
    /// A claimed/running record is returned unchanged so a new manager process holding a
    /// newer run lease can reconcile an interrupted side effect without claiming other work.
    public func claimContinuityCommand(
        runID: RunID,
        operationID: UUID,
        lease: RunLease
    ) throws -> ContinuityCommand? {
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction { () -> ContinuityCommand? in
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            guard lease.runID == runID else { throw AutonomyError.staleLease }
            guard let command = try continuityCommandByOperationUnlocked(
                operationID: operationID,
                connection: connection
            ) else { return nil }
            guard command.runID == runID else {
                throw ContinuityCommandQueueError.invalidCommand(
                    "operation is not owned by the leased run"
                )
            }
            switch command.state {
            case .claimed, .running:
                return command
            case .queued, .retryWait:
                if command.state == .retryWait,
                   let retryAt = command.retryAt,
                   retryAt > timestamp {
                    return nil
                }
                let changed = try connection.execute(
                    """
                    UPDATE continuity_commands SET state='claimed',attempt=attempt+1,
                        retry_at=NULL,last_error_code=NULL,last_error_summary=NULL,updated_at=?
                    WHERE command_id=? AND run_id=? AND operation_id=?
                      AND (state='queued' OR (state='retry_wait' AND (retry_at IS NULL OR retry_at<=?)))
                    """,
                    bindings: [
                        .text(timestamp), .text(command.commandID.uuidString.lowercased()),
                        .text(runID.description), .text(operationID.uuidString.lowercased()),
                        .text(timestamp),
                    ]
                )
                guard changed == 1 else { throw ContinuityCommandQueueError.claimConflict }
                return try continuityCommandUnlocked(
                    commandID: command.commandID,
                    connection: connection
                )
            case .completed, .failed, .cancelled:
                return command
            }
        }
    }

    @discardableResult
    public func transitionContinuityCommand(
        commandID: UUID,
        expected: ContinuityCommandState,
        to next: ContinuityCommandState,
        retryAt: String? = nil,
        errorCode: String? = nil,
        errorSummary: String? = nil
    ) throws -> ContinuityCommand {
        guard Self.validCommandTransitions[expected]?.contains(next) == true else {
            throw ContinuityCommandQueueError.invalidTransition(expected, next)
        }
        if next == .retryWait, retryAt == nil {
            throw ContinuityCommandQueueError.invalidCommand("retry_wait requires retry_at")
        }
        let boundedCode = try Self.boundedOptional(errorCode, maximumBytes: 256, field: "continuity error code")
        let boundedSummary = try Self.boundedOptional(
            errorSummary,
            maximumBytes: 2_048,
            field: "continuity error summary"
        )
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
            guard try continuityCommandUnlocked(commandID: commandID, connection: connection) != nil else {
                throw ContinuityCommandQueueError.commandNotFound(commandID)
            }
            let changed = try connection.execute(
                """
                UPDATE continuity_commands SET state=?,retry_at=?,last_error_code=?,
                    last_error_summary=?,updated_at=? WHERE command_id=? AND state=?
                """,
                bindings: [
                    .text(next.rawValue), .optionalText(retryAt), .optionalText(boundedCode),
                    .optionalText(boundedSummary), .text(timestamp),
                    .text(commandID.uuidString.lowercased()), .text(expected.rawValue),
                ]
            )
            guard changed == 1 else { throw ContinuityCommandQueueError.claimConflict }
            guard let updated = try continuityCommandUnlocked(commandID: commandID, connection: connection) else {
                throw ProjectContextError.integrityFailure("updated continuity command could not be read back")
            }
            return updated
        }
    }

    /// Makes manager interruption explicit and replayable. Claimed commands have no
    /// side effect yet and return to queued; running commands enter bounded retry/recovery.
    @discardableResult
    public func recoverInterruptedContinuityCommands() throws -> Int {
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
            let claimed = try connection.execute(
                """
                UPDATE continuity_commands SET state='queued',updated_at=? WHERE state='claimed'
                """,
                bindings: [.text(timestamp)]
            )
            let running = try connection.execute(
                """
                UPDATE continuity_commands SET state='retry_wait',retry_at=?,
                    last_error_code='manager_interrupted',
                    last_error_summary='Manager stopped while command was running; reconcile before replay',
                    updated_at=? WHERE state='running'
                """,
                bindings: [.text(timestamp), .text(timestamp)]
            )
            return claimed + running
        }
    }

    public func readyContinuityCommandCount() throws -> Int {
        let timestamp = ISO8601.string(from: clock.now())
        return try requiredConnection().scalarInt(
            """
            SELECT COUNT(*) FROM continuity_commands
            WHERE state='queued' OR (state='retry_wait' AND (retry_at IS NULL OR retry_at<=?))
            """,
            bindings: [.text(timestamp)]
        )
    }

    // MARK: - Autonomous runs and leases

    /// Creates the durable run and its exact project binding. An earlier continuity-only
    /// reservation may be upgraded while it remains in `created`; all other identity
    /// conflicts fail closed.
    @discardableResult
    public func createAutonomousRun(_ request: AutonomousRunRequest) throws -> AutonomousRunRecord {
        try reconcileAutonomousRunStart(request).run
    }

    /// Atomically creates a run or returns the one already stored for the same
    /// immutable request identity. `requiresActivation` is true only for the
    /// transaction that first materializes the complete run, so a transport
    /// retry cannot restart work merely by reconciling a late response.
    public func reconcileAutonomousRunStart(
        _ request: AutonomousRunRequest
    ) throws -> (run: AutonomousRunRecord, requiresActivation: Bool) {
        try validateAutonomousRunRequest(request)
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        let specificationJSON = try Self.specificationJSON(request.specification)
        return try connection.transaction {
            _ = try requiredActiveProjectUnlocked(
                request.projectID,
                generation: request.projectGeneration,
                connection: connection
            )

            if let existing = try autonomousRunUnlocked(request.runID, connection: connection) {
                try requireNoContinuityIngressHoldUnlocked(request.runID, connection: connection)
                let identityMatches = existing.projectID == request.projectID
                    && existing.projectGeneration == request.projectGeneration
                    && existing.assignmentID == request.assignmentID
                    && existing.mission == request.mission
                    && existing.continuityMode == request.continuityMode
                guard identityMatches else { throw AutonomyError.runConflict(request.runID) }

                if existing.providerID == nil, existing.modelKey == nil,
                   existing.state == .created,
                   existing.specification.allowedTools.isEmpty,
                   existing.specification.completionGates.isEmpty {
                    let changed = try connection.execute(
                        """
                        UPDATE autonomous_runs SET provider_id=?,model_key=?,current_work_json=?,updated_at=?
                        WHERE run_id=? AND state='created' AND provider_id IS NULL AND model_key IS NULL
                        """,
                        bindings: [
                            .text(request.providerID), .text(request.modelKey), .text(specificationJSON),
                            .text(timestamp), .text(request.runID.description),
                        ]
                    )
                    guard changed == 1 else { throw AutonomyError.transitionConflict }
                    try upsertAutonomousRunBindingUnlocked(
                        request,
                        timestamp: timestamp,
                        connection: connection
                    )
                    guard let refreshed = try autonomousRunUnlocked(request.runID, connection: connection) else {
                        throw ProjectContextError.integrityFailure("autonomous run could not be read after reservation upgrade")
                    }
                    return (refreshed, true)
                } else {
                    guard existing.providerID == request.providerID,
                          existing.modelKey == request.modelKey,
                          existing.adapterID == request.adapterID,
                          existing.specification.allowedTools == request.specification.allowedTools,
                          existing.specification.completionGates == request.specification.completionGates,
                          existing.specification.resourceProfile == request.specification.resourceProfile,
                          let binding = try bindingUnlocked(
                              owner: ProjectBindingOwner(
                                  kind: .autonomousRun,
                                  id: request.runID.description
                              ),
                              includeInactive: true,
                              connection: connection
                          ),
                          binding.projectID == request.projectID,
                          binding.projectGeneration == request.projectGeneration,
                          binding.runID == request.runID,
                          binding.authorizationScope == request.authorizationScope else {
                        throw AutonomyError.runConflict(request.runID)
                    }
                    return (existing, false)
                }
            }

            let inserted = try insertAutonomousRunUnlocked(request, state: .created,
                operationID: nil, timestamp: timestamp, connection: connection)
            return (inserted, true)
        }
    }

    public func autonomousRun(_ runID: RunID) throws -> AutonomousRunRecord? {
        try autonomousRunUnlocked(runID, connection: requiredConnection())
    }

    public func operatorAutonomousRuns(limit: Int) throws -> [AutonomousRunRecord] {
        guard (1...100).contains(limit) else {
            throw AutonomyError.invalidRequest("operator run limit must be between 1 and 100")
        }
        return try requiredConnection().all(
            Self.autonomousRunSelect + " ORDER BY updated_at DESC,run_id DESC LIMIT ?",
            bindings: [.int64(Int64(limit))],
            map: Self.decodeAutonomousRun
        )
    }

    public func operatorRunReadModels(
        runs: [AutonomousRunRecord]
    ) throws -> [ManagerOperatorRunReadModel] {
        guard runs.count <= 100 else {
            throw AutonomyError.invalidRequest("operator run detail query is outside bounds")
        }
        let connection = try requiredConnection()
        return try runs.map { run in
            let session = try run.activeSessionID.flatMap {
                try providerSessionRecordUnlocked($0, connection: connection)
            }
            let latestTurn = try connection.first(
                Self.providerTurnSelect
                    + " WHERE run_id=? ORDER BY updated_at DESC,turn_id DESC LIMIT 1",
                bindings: [.text(run.runID.description)],
                map: Self.decodeProviderTurn
            )
            let latestTool = try connection.first(
                Self.toolInvocationSelect
                    + " WHERE run_id=? ORDER BY updated_at DESC,invocation_id DESC LIMIT 1",
                bindings: [.text(run.runID.description)],
                map: Self.decodeToolInvocation
            )
            let budgetState = try session.flatMap { session in
                try contextBudgetStateUnlocked(
                    identity: ContextBudgetIdentity(
                        runID: run.runID,
                        projectID: run.projectID,
                        projectGeneration: run.projectGeneration,
                        sessionID: session.sessionID
                    ),
                    connection: connection
                )
            }
            return ManagerOperatorRunReadModel(
                run: run,
                lease: try runLeaseUnlocked(run.runID, connection: connection),
                activeSession: session,
                latestProviderTurn: latestTurn,
                latestToolInvocation: latestTool,
                budgetState: budgetState
            )
        }
    }

    public func nonterminalAutonomousRuns(limit: Int = 256) throws -> [AutonomousRunRecord] {
        guard (1...1_024).contains(limit) else {
            throw AutonomyError.invalidRequest("run recovery limit must be between 1 and 1024")
        }
        return try requiredConnection().all(
            Self.autonomousRunSelect
                + " WHERE state NOT IN ('completed','cancelled','failed_terminal') AND NOT EXISTS(SELECT 1 FROM continuity_operation_cancellations c WHERE c.operation_id=autonomous_runs.active_operation_id) ORDER BY updated_at,run_id LIMIT ?",
            bindings: [.int64(Int64(limit))],
            map: Self.decodeAutonomousRun
        )
    }

    public func validateAutonomousRunGeneration(_ runID: RunID) throws -> AutonomousRunRecord {
        let connection = try requiredConnection()
        guard let run = try autonomousRunUnlocked(runID, connection: connection) else {
            throw AutonomyError.runNotFound(runID)
        }
        _ = try requiredActiveProjectUnlocked(
            run.projectID,
            generation: run.projectGeneration,
            connection: connection
        )
        return run
    }

    /// Application dispatch checks the durable hold, not a cached state snapshot.
    /// Cancellation uses its dedicated state transition and remains available.
    public func validateAutonomousRunExecutionAdmission(_ runID: RunID) throws -> AutonomousRunRecord {
        try controlledTransaction(cancellation: nil) { connection in
            guard let run = try autonomousRunUnlocked(runID, connection: connection) else {
                throw AutonomyError.runNotFound(runID)
            }
            _ = try requiredActiveProjectUnlocked(run.projectID, generation: run.projectGeneration, connection: connection)
            try requireNoContinuityIngressHoldUnlocked(runID, connection: connection)
            guard run.state != .awaitingBootstrap else { throw AutonomyError.bootstrapRequired(runID) }
            guard !run.state.isTerminal, run.state != .cancelRequested else {
                throw AutonomyError.invalidRequest("a stopping or terminal run cannot dispatch work")
            }
            return run
        }
    }

    @discardableResult
    public func acquireRunLease(
        runID: RunID,
        ownerID: String,
        policy: RunLeasePolicy = .init()
    ) throws -> RunLease {
        try Self.validateLeaseOwner(ownerID)
        try Self.validate(policy)
        let connection = try requiredConnection()
        let now = clock.now()
        let timestamp = ISO8601.string(from: now)
        let expiresAt = ISO8601.string(from: now.addingTimeInterval(policy.duration))
        return try connection.transaction {
            guard let run = try autonomousRunUnlocked(runID, connection: connection) else {
                throw AutonomyError.runNotFound(runID)
            }
            guard !run.state.isTerminal else {
                throw AutonomyError.invalidRequest("terminal runs cannot be leased")
            }
            _ = try requiredActiveProjectUnlocked(
                run.projectID,
                generation: run.projectGeneration,
                connection: connection
            )

            if let existing = try runLeaseUnlocked(runID, connection: connection) {
                let unexpired = existing.expirationDate.map { $0 > now } ?? false
                if unexpired {
                    guard existing.ownerID == ownerID else {
                        throw AutonomyError.leaseConflict(ownerID: existing.ownerID, epoch: existing.epoch)
                    }
                    return existing
                }
                guard existing.epoch < UInt64(Int64.max) else {
                    throw AutonomyError.invalidRequest("run lease epoch is exhausted")
                }
                let nextEpoch = existing.epoch + 1
                let changed = try connection.execute(
                    """
                    UPDATE run_leases SET lease_owner=?,lease_epoch=?,acquired_at=?,renewed_at=?,expires_at=?
                    WHERE run_id=? AND lease_epoch=? AND expires_at<=?
                    """,
                    bindings: [
                        .text(ownerID), .int64(Int64(nextEpoch)), .text(timestamp),
                        .text(timestamp), .text(expiresAt), .text(runID.description),
                        .int64(Int64(existing.epoch)), .text(timestamp),
                    ]
                )
                guard changed == 1 else { throw AutonomyError.transitionConflict }
            } else {
                try connection.execute(
                    """
                    INSERT INTO run_leases(run_id,lease_owner,lease_epoch,acquired_at,renewed_at,expires_at)
                    VALUES(?,?,1,?,?,?)
                    """,
                    bindings: [
                        .text(runID.description), .text(ownerID), .text(timestamp),
                        .text(timestamp), .text(expiresAt),
                    ]
                )
            }
            guard let lease = try runLeaseUnlocked(runID, connection: connection) else {
                throw ProjectContextError.integrityFailure("run lease could not be read after acquisition")
            }
            try appendAutonomyEventUnlocked(
                runID: runID,
                projectID: run.projectID,
                eventType: "run_lease_acquired",
                severity: .debug,
                summary: "Run lease was acquired",
                metadata: ["lease_epoch": String(lease.epoch), "lease_owner": ownerID],
                connection: connection
            )
            return lease
        }
    }

    @discardableResult
    public func renewRunLease(
        _ lease: RunLease,
        policy: RunLeasePolicy = .init()
    ) throws -> RunLease {
        try Self.validate(policy)
        let connection = try requiredConnection()
        let now = clock.now()
        let timestamp = ISO8601.string(from: now)
        return try connection.transaction {
            let current = try requiredRunLeaseUnlocked(lease.runID, connection: connection)
            guard current.ownerID == lease.ownerID, current.epoch == lease.epoch else {
                throw AutonomyError.staleLease
            }
            guard let expiration = current.expirationDate, expiration > now else {
                throw AutonomyError.leaseExpired
            }
            guard let acquired = ISO8601.date(from: current.acquiredAt) else {
                throw ProjectContextError.integrityFailure("run lease acquired_at is invalid")
            }
            let maximumExpiration = acquired.addingTimeInterval(policy.maximumDuration)
            let proposed = now.addingTimeInterval(policy.duration)
            let nextExpiration = min(proposed, maximumExpiration)
            guard nextExpiration > now else { throw AutonomyError.leaseExpired }
            let nextExpirationString = ISO8601.string(from: nextExpiration)
            let changed = try connection.execute(
                """
                UPDATE run_leases SET renewed_at=?,expires_at=?
                WHERE run_id=? AND lease_owner=? AND lease_epoch=? AND expires_at>?
                """,
                bindings: [
                    .text(timestamp), .text(nextExpirationString), .text(lease.runID.description),
                    .text(lease.ownerID), .int64(Int64(lease.epoch)), .text(timestamp),
                ]
            )
            guard changed == 1,
                  let renewed = try runLeaseUnlocked(lease.runID, connection: connection) else {
                throw AutonomyError.staleLease
            }
            return renewed
        }
    }

    @discardableResult
    public func releaseRunLease(_ lease: RunLease) throws -> Bool {
        let connection = try requiredConnection()
        return try connection.transaction {
            try connection.execute(
                "DELETE FROM run_leases WHERE run_id=? AND lease_owner=? AND lease_epoch=?",
                bindings: [
                    .text(lease.runID.description), .text(lease.ownerID), .int64(Int64(lease.epoch)),
                ]
            ) == 1
        }
    }

    public func runLease(_ runID: RunID) throws -> RunLease? {
        try runLeaseUnlocked(runID, connection: requiredConnection())
    }

    @discardableResult
    public func releaseExpiredRunLeases() throws -> Int {
        let timestamp = ISO8601.string(from: clock.now())
        return try requiredConnection().execute(
            "DELETE FROM run_leases WHERE expires_at<=?",
            bindings: [.text(timestamp)]
        )
    }

    @discardableResult
    public func transitionAutonomousRun(
        runID: RunID,
        lease: RunLease,
        transition: AutonomousRunTransition
    ) throws -> AutonomousRunRecord {
        guard lease.runID == runID else { throw AutonomyError.staleLease }
        guard transition.nextState != .completed else {
            throw AutonomyError.completionValidationRequired
        }
        guard Self.validRunTransitions[transition.expectedState]?.contains(transition.nextState) == true else {
            throw AutonomyError.invalidTransition(transition.expectedState, transition.nextState)
        }
        try Self.validateTransition(transition)
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            guard let current = try autonomousRunUnlocked(runID, connection: connection) else {
                throw AutonomyError.runNotFound(runID)
            }
            guard current.state == transition.expectedState,
                  current.revision == transition.expectedRevision else {
                throw AutonomyError.transitionConflict
            }
            if let active = current.activeOperationID,
               try connection.scalarInt("SELECT COUNT(*) FROM continuity_operation_cancellations WHERE operation_id=?", bindings: [.text(active.uuidString.lowercased())]) > 0,
               (transition.activeOperationID != nil && transition.activeOperationID != active
                || transition.activeSessionID != nil && transition.activeSessionID != current.activeSessionID) {
                throw ContinuityOperationControlError.cancellationRequested
            }
            if transition.activeOperationID != nil || transition.activeSessionID != nil {
                let sources = try connection.all("""
                    SELECT operation_id,candidate_id FROM continuity_source_activations
                    WHERE run_id=? AND (resumption_json IS NULL OR resumption_sha256 IS NULL) LIMIT 2
                    """, bindings: [.text(runID.description)], map: {
                        (try $0.strictText(0, maximumBytes: 36), try $0.strictText(1, maximumBytes: 36))
                    })
                guard sources.count <= 1 else { throw ContinuitySourceActivationError.conflict }
                if let source = sources.first {
                    guard let operation = source.0, let candidate = source.1,
                          UUID(uuidString: operation)?.uuidString.lowercased() == operation,
                          UUID(uuidString: candidate)?.uuidString.lowercased() == candidate,
                          transition.activeOperationID == nil || transition.activeOperationID?.uuidString.lowercased() == operation,
                          transition.activeSessionID == nil || transition.activeSessionID == candidate else {
                        throw ContinuitySourceActivationError.conflict
                    }
                }
            }
            if transition.nextState == .cancelRequested || transition.nextState == .cancelled {
                try connection.execute(
                    "UPDATE continuity_ingress_holds SET state='cancelled',updated_at=? WHERE run_id=? AND state='awaiting_bootstrap'",
                    bindings: [.text(timestamp), .text(runID.description)])
            } else {
                try requireNoContinuityIngressHoldUnlocked(runID, connection: connection)
            }
            _ = try requiredActiveProjectUnlocked(
                current.projectID,
                generation: current.projectGeneration,
                connection: connection
            )
            var specification = current.specification
            if let work = transition.work { specification.work = work }
            let workJSON = try Self.specificationJSON(specification)
            let changed = try connection.execute(
                """
                UPDATE autonomous_runs SET state=?,current_work_json=?,
                    active_session_id=COALESCE(?,active_session_id),
                    active_operation_id=COALESCE(?,active_operation_id),
                    completion_request_json=COALESCE(?,completion_request_json),
                    last_error_code=?,last_error_summary=?,retry_at=?,
                    revision=revision+1,updated_at=?
                WHERE run_id=? AND state=? AND revision=?
                """,
                bindings: [
                    .text(transition.nextState.rawValue), .text(workJSON),
                    .optionalText(transition.activeSessionID),
                    .optionalText(transition.activeOperationID?.uuidString.lowercased()),
                    .optionalText(transition.completionRequestJSON),
                    .optionalText(transition.errorCode), .optionalText(transition.errorSummary),
                    .optionalText(transition.retryAt), .text(timestamp), .text(runID.description),
                    .text(transition.expectedState.rawValue), .int64(Int64(transition.expectedRevision)),
                ]
            )
            guard changed == 1 else { throw AutonomyError.transitionConflict }
            try appendAutonomyEventUnlocked(
                runID: runID,
                projectID: current.projectID,
                eventType: transition.eventType,
                severity: transition.errorCode == nil ? .info : .warning,
                summary: transition.eventSummary,
                metadata: [
                    "from_state": transition.expectedState.rawValue,
                    "to_state": transition.nextState.rawValue,
                    "revision": String(transition.expectedRevision + 1),
                ],
                connection: connection
            )
            guard let updated = try autonomousRunUnlocked(runID, connection: connection) else {
                throw ProjectContextError.integrityFailure("transitioned run could not be read back")
            }
            return updated
        }
    }

    /// Persists a next side-effect identity without changing the run state. This is the
    /// coordinator's commit boundary immediately before provider, tool, or process work.
    @discardableResult
    public func persistRunSideEffectIntent(
        runID: RunID,
        lease: RunLease,
        expectedRevision: UInt64,
        intent: RunSideEffectIntent
    ) throws -> AutonomousRunRecord {
        try Self.validate(intent)
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            try requireNoContinuityIngressHoldUnlocked(runID, connection: connection)
            guard let current = try autonomousRunUnlocked(runID, connection: connection) else {
                throw AutonomyError.runNotFound(runID)
            }
            guard current.revision == expectedRevision, !current.state.isTerminal else {
                throw AutonomyError.transitionConflict
            }
            var specification = current.specification
            specification.work.pendingIntent = intent
            let changed = try connection.execute(
                """
                UPDATE autonomous_runs SET current_work_json=?,revision=revision+1,updated_at=?
                WHERE run_id=? AND revision=? AND state NOT IN ('completed','cancelled','failed_terminal')
                """,
                bindings: [
                    .text(try Self.specificationJSON(specification)), .text(timestamp),
                    .text(runID.description), .int64(Int64(expectedRevision)),
                ]
            )
            guard changed == 1 else { throw AutonomyError.transitionConflict }
            try appendAutonomyEventUnlocked(
                runID: runID,
                projectID: current.projectID,
                eventType: "run_side_effect_intent_persisted",
                severity: .debug,
                summary: intent.summary,
                metadata: [
                    "intent_id": intent.intentID.uuidString.lowercased(),
                    "intent_kind": intent.kind.rawValue,
                    "payload_sha256": intent.payloadSHA256,
                ],
                connection: connection
            )
            guard let updated = try autonomousRunUnlocked(runID, connection: connection) else {
                throw ProjectContextError.integrityFailure("run intent could not be read back")
            }
            return updated
        }
    }

    /// Called only by the native coordinator after its installed validator returns.
    /// No public tool or decoded request may issue this process-local authority.
    func recordTrustedCompletionValidation(
        _ receipt: CompletionValidationReceipt,
        for run: AutonomousRunRecord,
        lease: RunLease
    ) throws {
        let now = clock.now()
        completionApprovals = completionApprovals.filter { $0.value.expiresAt > now }
        guard lease.runID == run.runID, receipt.runID == run.runID,
              receipt.expectedRevision == run.revision, receipt.passed,
              try Self.validCompletionReceipt(receipt),
              run.state == .validatingCompletion,
              !run.specification.completionGates.isEmpty,
              Set(run.specification.completionGates).count == run.specification.completionGates.count,
              receipt.results.count == run.specification.completionGates.count,
              Set(receipt.results.map(\.gate)) == Set(run.specification.completionGates),
              try receipt.results.allSatisfy({ result in
                  guard result.passed, result.blocker == nil else { return false }
                  return try result.invocation?.matches(run) == true
              }),
              let expiresAt = lease.expirationDate, expiresAt > now,
              completionApprovals[run.runID] != nil || completionApprovals.count < 256 else {
            throw AutonomyError.completionValidationFailed
        }
        let connection = try requiredConnection()
        try verifyRunLeaseUnlocked(lease, timestamp: ISO8601.string(from: now), connection: connection)
        try requireNoContinuityIngressHoldUnlocked(run.runID, connection: connection)
        guard try autonomousRunUnlocked(run.runID, connection: connection) == run,
              let project = try projectUnlocked(run.projectID, connection: connection),
              project.generation == run.projectGeneration,
              project.lifecycleState == .active else {
            throw AutonomyError.transitionConflict
        }
        completionApprovals[run.runID] = CompletionApproval(
            run: run, ownerID: lease.ownerID, leaseEpoch: lease.epoch,
            proofSHA256: receipt.proofSHA256, expiresAt: expiresAt
        )
    }

    @discardableResult
    public func completeAutonomousRun(
        runID: RunID,
        lease: RunLease,
        receipt: CompletionValidationReceipt
    ) throws -> AutonomousRunRecord {
        guard lease.runID == runID, receipt.runID == runID, receipt.passed,
              try Self.validCompletionReceipt(receipt),
              let approval = completionApprovals.removeValue(forKey: runID),
              approval.expiresAt > clock.now(),
              approval.ownerID == lease.ownerID, approval.leaseEpoch == lease.epoch,
              approval.proofSHA256 == receipt.proofSHA256 else {
            throw AutonomyError.completionValidationFailed
        }
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            try requireNoContinuityIngressHoldUnlocked(runID, connection: connection)
            guard let current = try autonomousRunUnlocked(runID, connection: connection) else {
                throw AutonomyError.runNotFound(runID)
            }
            guard current.state == .validatingCompletion,
                  current.revision == receipt.expectedRevision,
                  current == approval.run,
                  let project = try projectUnlocked(current.projectID, connection: connection),
                  project.generation == current.projectGeneration,
                  project.lifecycleState == .active else {
                throw AutonomyError.transitionConflict
            }
            let requiredGates = current.specification.completionGates
            let receivedGates = receipt.results.map(\.gate)
            guard !requiredGates.isEmpty,
                  Set(requiredGates).count == requiredGates.count,
                  receivedGates.count == requiredGates.count,
                  Set(receivedGates) == Set(requiredGates) else {
                throw AutonomyError.completionValidationFailed
            }
            let receiptData = try Self.sortedJSONEncoder.encode(receipt)
            let changed = try connection.execute(
                """
                UPDATE autonomous_runs SET state='completed',completion_request_json=?,
                    last_error_code=NULL,last_error_summary=NULL,retry_at=NULL,
                    revision=revision+1,updated_at=?
                WHERE run_id=? AND state='validating_completion' AND revision=?
                """,
                bindings: [
                    .text(String(decoding: receiptData, as: UTF8.self)), .text(timestamp),
                    .text(runID.description), .int64(Int64(receipt.expectedRevision)),
                ]
            )
            guard changed == 1 else { throw AutonomyError.transitionConflict }
            try appendAutonomyEventUnlocked(
                runID: runID,
                projectID: current.projectID,
                eventType: "autonomous_run_completed",
                severity: .info,
                summary: "All deterministic completion gates passed",
                metadata: [
                    "gate_count": String(receipt.results.count),
                    "proof_sha256": receipt.proofSHA256,
                ],
                connection: connection
            )
            guard let completed = try autonomousRunUnlocked(runID, connection: connection) else {
                throw ProjectContextError.integrityFailure("completed run could not be read back")
            }
            return completed
        }
    }

    public func autonomyEvents(runID: RunID, limit: Int = 256) throws -> [AutonomyEvent] {
        guard (1...1_000).contains(limit) else {
            throw AutonomyError.invalidRequest("event limit must be between 1 and 1000")
        }
        return try requiredConnection().all(
            """
            SELECT sequence,event_id,run_id,project_id,event_type,severity,summary,
                   metadata_json,previous_event_sha256,event_sha256,created_at
            FROM autonomy_events WHERE run_id=? ORDER BY sequence DESC LIMIT ?
            """,
            bindings: [.text(runID.description), .int64(Int64(limit))],
            map: Self.decodeAutonomyEvent
        )
    }

    /// Global, cursor-bounded event feed for the operator snapshot. The cursor is the
    /// exclusive durable sequence returned by the prior page.
    public func operatorAutonomyEvents(
        limit: Int,
        beforeSequence: Int64? = nil
    ) throws -> [AutonomyEvent] {
        guard (1...101).contains(limit), beforeSequence.map({ $0 > 0 }) ?? true else {
            throw AutonomyError.invalidRequest("operator event query is outside bounds")
        }
        var sql = """
        SELECT sequence,event_id,run_id,project_id,event_type,severity,summary,
               metadata_json,previous_event_sha256,event_sha256,created_at
        FROM autonomy_events
        """
        var bindings: [ControlPlaneSQLiteBinding] = []
        if let beforeSequence {
            sql += " WHERE sequence<?"
            bindings.append(.int64(beforeSequence))
        }
        sql += " ORDER BY sequence DESC LIMIT ?"
        bindings.append(.int64(Int64(limit)))
        return try requiredConnection().all(
            sql,
            bindings: bindings,
            map: Self.decodeAutonomyEvent
        )
    }

    // MARK: - Provider and tool side-effect intents

    /// Reserves a provider session identity while the run lease and project generation
    /// are current. Accepted active sessions also receive the run's exact tool binding.
    public func reserveProviderSession(
        _ intent: ProviderSessionIntent,
        lease: RunLease
    ) throws {
        try reserveProviderSessionScoped(intent, lease: lease, bootstrapGrant: nil)
    }

    func reserveProviderSession(
        _ intent: ProviderSessionIntent,
        lease: RunLease,
        bootstrapGrant: ContinuityBootstrapGrant
    ) throws {
        try reserveProviderSessionScoped(intent, lease: lease, bootstrapGrant: bootstrapGrant)
    }

    private func reserveProviderSessionScoped(
        _ intent: ProviderSessionIntent,
        lease: RunLease,
        bootstrapGrant: ContinuityBootstrapGrant?
    ) throws {
        if bootstrapGrant == nil { try Self.validate(intent) }
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        try connection.transaction(fullDurability: bootstrapGrant != nil) {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            if let bootstrapGrant {
                try validateBootstrapSessionIntentUnlocked(intent, grant: bootstrapGrant, lease: lease, connection: connection)
            } else {
                try requireNoContinuityIngressHoldUnlocked(intent.runID, connection: connection)
            }
            guard let run = try autonomousRunUnlocked(intent.runID, connection: connection) else {
                throw AutonomyError.runNotFound(intent.runID)
            }
            guard run.projectID == intent.projectID,
                  run.projectGeneration == intent.projectGeneration else {
                throw ProjectContextError.projectScopeMismatch
            }
            _ = try requiredActiveProjectUnlocked(
                intent.projectID,
                generation: intent.projectGeneration,
                connection: connection
            )
            if let existing = try providerSessionIdentityUnlocked(intent.sessionID, connection: connection) {
                let expected = ProviderSessionIdentity(intent,
                    providerResponseID: bootstrapGrant == nil ? nil : existing.providerResponseID)
                guard existing == expected else { throw AutonomyError.intentConflict }
                if let bootstrapGrant, let response = existing.providerResponseID {
                    guard let rootID = try connection.scalarText("""
                        SELECT turn_id FROM provider_turns WHERE session_id=? AND request_kind='bootstrap'
                            AND previous_response_id IS NULL LIMIT 1
                        """, bindings: [.text(intent.sessionID)]).flatMap(UUID.init(uuidString:)),
                          try bootstrapProviderResultUnlocked(grant: bootstrapGrant, turnID: rootID,
                            connection: connection)?.responseID == response else {
                        throw ContinuityIngressError.integrityFailure("candidate response has no retained bootstrap turn")
                    }
                }
                return
            }
            try connection.execute(
                """
                INSERT INTO provider_sessions(
                    session_id,run_id,project_id,project_generation,provider_id,adapter_id,model_key,
                    provider_response_id,predecessor_session_id,handoff_id,operation_id,idempotency_key,
                    bootstrap_nonce_hash,handoff_sha256,status,accepted,context_capacity,created_at,updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                bindings: [
                    .text(intent.sessionID), .text(intent.runID.description),
                    .text(intent.projectID.description),
                    .int64(try Self.sqliteGeneration(intent.projectGeneration)),
                    .text(intent.providerID), .text(intent.adapterID), .text(intent.modelKey),
                    .optionalText(intent.providerResponseID), .optionalText(intent.predecessorSessionID),
                    .optionalText(intent.handoffID?.uuidString.lowercased()),
                    .optionalText(intent.operationID?.uuidString.lowercased()),
                    .text(intent.idempotencyKey), .optionalText(intent.bootstrapNonceSHA256),
                    .optionalText(intent.handoffSHA256), .text(intent.status.rawValue),
                    .int64(intent.accepted ? 1 : 0),
                    .optionalInt64(intent.contextCapacity.map(Int64.init)),
                    .text(timestamp), .text(timestamp),
                ]
            )
            if intent.status == .active, intent.accepted {
                guard let runBinding = try bindingUnlocked(
                    owner: ProjectBindingOwner(kind: .autonomousRun, id: intent.runID.description),
                    includeInactive: false,
                    connection: connection
                ) else {
                    throw AutonomyError.invalidRequest("autonomous run binding is missing")
                }
                let providerOwner = ProjectBindingOwner(kind: .providerSession, id: intent.sessionID)
                if let existing = try bindingUnlocked(
                    owner: providerOwner,
                    includeInactive: true,
                    connection: connection
                ) {
                    guard !existing.active
                            || (existing.projectID == intent.projectID
                                && existing.projectGeneration == intent.projectGeneration
                                && existing.runID == intent.runID) else {
                        throw ProjectContextError.ownerAlreadyBound(providerOwner)
                    }
                    try connection.execute(
                        """
                        UPDATE project_bindings SET project_id=?,project_generation=?,run_id=?,
                            authorization_scope_json=?,active=1,updated_at=?
                        WHERE owner_kind='provider_session' AND owner_id=?
                        """,
                        bindings: [
                            .text(intent.projectID.description),
                            .int64(try Self.sqliteGeneration(intent.projectGeneration)),
                            .text(intent.runID.description),
                            .text(try Self.scopeJSON(runBinding.authorizationScope)),
                            .text(timestamp), .text(intent.sessionID),
                        ]
                    )
                } else {
                    try connection.execute(
                        """
                        INSERT INTO project_bindings(
                            binding_id,owner_kind,owner_id,project_id,project_generation,run_id,
                            authorization_scope_json,active,created_at,updated_at
                        ) VALUES(?,'provider_session',?,?,?,?,?,1,?,?)
                        """,
                        bindings: [
                            .text(UUID().uuidString.lowercased()), .text(intent.sessionID),
                            .text(intent.projectID.description),
                            .int64(try Self.sqliteGeneration(intent.projectGeneration)),
                            .text(intent.runID.description),
                            .text(try Self.scopeJSON(runBinding.authorizationScope)),
                            .text(timestamp), .text(timestamp),
                        ]
                    )
                }
                try connection.execute(
                    """
                    UPDATE autonomous_runs SET active_session_id=?,revision=revision+1,updated_at=?
                    WHERE run_id=? AND project_id=? AND project_generation=?
                    """,
                    bindings: [
                        .text(intent.sessionID), .text(timestamp), .text(intent.runID.description),
                        .text(intent.projectID.description),
                        .int64(try Self.sqliteGeneration(intent.projectGeneration)),
                    ]
                )
            }
            try appendAutonomyEventUnlocked(
                runID: intent.runID,
                projectID: intent.projectID,
                eventType: "provider_session_reserved",
                severity: .info,
                summary: "Provider session identity was durably reserved",
                metadata: [
                    "accepted": intent.accepted ? "true" : "false",
                    "session_id": intent.sessionID,
                    "status": intent.status.rawValue,
                ],
                connection: connection
            )
        }
    }

    public func providerSession(_ sessionID: String) throws -> ProviderSessionRecord? {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 1_024 else {
            throw AutonomyError.invalidRequest("provider session identifier is invalid")
        }
        return try providerSessionRecordUnlocked(
            sessionID,
            connection: requiredConnection()
        )
    }

    public func providerSessions(
        operationID: UUID,
        limit: Int = 32
    ) throws -> [ProviderSessionRecord] {
        guard (1...128).contains(limit) else {
            throw AutonomyError.invalidRequest("provider session query limit is outside bounds")
        }
        return try requiredConnection().all(
            Self.providerSessionSelect
                + " WHERE operation_id=? ORDER BY created_at,session_id LIMIT ?",
            bindings: [
                .text(operationID.uuidString.lowercased()), .int64(Int64(limit)),
            ],
            map: Self.decodeProviderSession
        )
    }

    /// Removes the predecessor's provider authority before any successor-creation side
    /// effect. The run/operation lease makes a replay idempotent after manager restart.
    @discardableResult
    public func fenceProviderSessionForContinuity(
        runID: RunID,
        operationID: UUID,
        predecessorSessionID: String,
        lease: RunLease
    ) throws -> ProviderSessionRecord {
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            guard lease.runID == runID,
                  let run = try autonomousRunUnlocked(runID, connection: connection),
                  run.activeOperationID == operationID else {
                throw AutonomyError.staleLease
            }
            guard let predecessor = try providerSessionRecordUnlocked(
                predecessorSessionID,
                connection: connection
            ) else {
                throw AutonomyError.providerSessionNotFound(predecessorSessionID)
            }
            guard predecessor.runID == runID,
                  predecessor.projectID == run.projectID,
                  predecessor.projectGeneration == run.projectGeneration,
                  run.activeSessionID == predecessorSessionID else {
                throw ProjectContextError.projectScopeMismatch
            }
            switch predecessor.status {
            case .active:
                guard predecessor.accepted else {
                    throw AutonomyError.invalidRequest("active predecessor was not accepted")
                }
                let changed = try connection.execute(
                    """
                    UPDATE provider_sessions SET status='fencing',accepted=0,updated_at=?
                    WHERE session_id=? AND run_id=? AND status='active' AND accepted=1
                    """,
                    bindings: [
                        .text(timestamp), .text(predecessorSessionID), .text(runID.description),
                    ]
                )
                guard changed == 1 else { throw AutonomyError.transitionConflict }
                try connection.execute(
                    """
                    UPDATE project_bindings SET active=0,updated_at=?
                    WHERE owner_kind='provider_session' AND owner_id=? AND active=1
                    """,
                    bindings: [.text(timestamp), .text(predecessorSessionID)]
                )
                try appendAutonomyEventUnlocked(
                    runID: runID,
                    projectID: run.projectID,
                    eventType: "continuity_predecessor_fencing",
                    severity: .info,
                    summary: "Predecessor provider authority was fenced before successor creation",
                    metadata: [
                        "operation_id": operationID.uuidString.lowercased(),
                        "session_id": predecessorSessionID,
                    ],
                    connection: connection
                )
            case .fencing, .fenced, .sealed:
                break
            default:
                throw AutonomyError.invalidRequest(
                    "provider session cannot be used as a continuity predecessor"
                )
            }
            guard let updated = try providerSessionRecordUnlocked(
                predecessorSessionID,
                connection: connection
            ) else {
                throw ProjectContextError.integrityFailure("fenced predecessor is unreadable")
            }
            return updated
        }
    }

    /// Atomically chooses one V2 receipt candidate, quarantines every duplicate,
    /// fences the predecessor, switches the run/binding, and inserts the sole automatic
    /// continuation intent. The project-local operation must already be acknowledged.
    @discardableResult
    public func acceptContinuitySuccessor(
        _ acceptance: ContinuitySuccessorAcceptance,
        lease: RunLease
    ) throws -> ContinuitySuccessorAcceptanceReceipt {
        try Self.validate(acceptance)
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            guard lease.runID == acceptance.runID,
                  let run = try autonomousRunUnlocked(acceptance.runID, connection: connection),
                  run.projectID == acceptance.projectID,
                  run.projectGeneration == acceptance.projectGeneration,
                  run.activeOperationID == acceptance.operationID else {
                throw AutonomyError.staleLease
            }
            guard let candidate = try providerSessionRecordUnlocked(
                acceptance.candidateSessionID,
                connection: connection
            ) else {
                throw AutonomyError.providerSessionNotFound(acceptance.candidateSessionID)
            }
            guard candidate.runID == acceptance.runID,
                  candidate.projectID == acceptance.projectID,
                  candidate.projectGeneration == acceptance.projectGeneration,
                  candidate.predecessorSessionID == acceptance.predecessorSessionID,
                  candidate.operationID == acceptance.operationID,
                  candidate.handoffID == acceptance.handoffID,
                  candidate.handoffSHA256 == acceptance.handoffSHA256,
                  candidate.bootstrapNonceSHA256 == acceptance.bootstrapNonceSHA256 else {
                throw AutonomyError.intentConflict
            }

            let existingWinner = try providerSessionForAcceptedOperationUnlocked(
                acceptance.operationID,
                connection: connection
            )
            let winnerID: String
            var quarantined = [String]()
            if let existingWinner {
                winnerID = existingWinner.sessionID
                if existingWinner.sessionID != candidate.sessionID,
                   candidate.status == .candidate {
                    try quarantineProviderSessionUnlocked(
                        candidate.sessionID,
                        timestamp: timestamp,
                        connection: connection
                    )
                    quarantined.append(candidate.sessionID)
                }
            } else {
                guard candidate.status == .candidate, !candidate.accepted,
                      let predecessor = try providerSessionRecordUnlocked(
                        acceptance.predecessorSessionID,
                        connection: connection
                      ),
                      predecessor.runID == acceptance.runID,
                      [.fencing, .fenced].contains(predecessor.status) else {
                    throw AutonomyError.transitionConflict
                }
                let duplicates = try connection.all(
                    """
                    SELECT session_id FROM provider_sessions
                    WHERE operation_id=? AND status='candidate' AND session_id<>?
                    ORDER BY created_at,session_id
                    """,
                    bindings: [
                        .text(acceptance.operationID.uuidString.lowercased()),
                        .text(candidate.sessionID),
                    ],
                    map: { $0.text(0) ?? "" }
                ).filter { !$0.isEmpty }
                for duplicate in duplicates {
                    try quarantineProviderSessionUnlocked(
                        duplicate,
                        timestamp: timestamp,
                        connection: connection
                    )
                }
                quarantined.append(contentsOf: duplicates)

                try connection.execute(
                    """
                    UPDATE provider_sessions SET status='fenced',accepted=0,updated_at=?
                    WHERE session_id=? AND run_id=? AND status IN ('fencing','fenced')
                    """,
                    bindings: [
                        .text(timestamp), .text(acceptance.predecessorSessionID),
                        .text(acceptance.runID.description),
                    ]
                )
                let activated = try connection.execute(
                    """
                    UPDATE provider_sessions SET status='active',accepted=1,updated_at=?
                    WHERE session_id=? AND operation_id=? AND status='candidate' AND accepted=0
                    """,
                    bindings: [
                        .text(timestamp), .text(candidate.sessionID),
                        .text(acceptance.operationID.uuidString.lowercased()),
                    ]
                )
                guard activated == 1 else { throw AutonomyError.transitionConflict }
                try activateProviderBindingUnlocked(
                    sessionID: candidate.sessionID,
                    run: run,
                    timestamp: timestamp,
                    connection: connection
                )
                let switched = try connection.execute(
                    """
                    UPDATE autonomous_runs SET active_session_id=?,continuation_pending=1,
                        revision=revision+1,updated_at=?
                    WHERE run_id=? AND project_id=? AND project_generation=?
                      AND active_operation_id=? AND active_session_id=?
                    """,
                    bindings: [
                        .text(candidate.sessionID), .text(timestamp),
                        .text(acceptance.runID.description), .text(acceptance.projectID.description),
                        .int64(try Self.sqliteGeneration(acceptance.projectGeneration)),
                        .text(acceptance.operationID.uuidString.lowercased()),
                        .text(acceptance.predecessorSessionID),
                    ]
                )
                guard switched == 1 else { throw AutonomyError.transitionConflict }
                winnerID = candidate.sessionID
            }

            guard let winner = try providerSessionRecordUnlocked(
                winnerID,
                connection: connection
            ), winner.status == .active, winner.accepted,
            let responseID = winner.providerResponseID else {
                throw ProjectContextError.integrityFailure("accepted successor is unreadable")
            }
            let continuation = try automaticContinuationIntentUnlocked(
                acceptance: acceptance,
                winner: winner,
                previousResponseID: responseID,
                timestamp: timestamp,
                connection: connection
            )
            try appendAutonomyEventUnlocked(
                runID: acceptance.runID,
                projectID: acceptance.projectID,
                eventType: "continuity_successor_accepted",
                severity: .info,
                summary: "One successor was accepted and automatic continuation was committed",
                metadata: [
                    "operation_id": acceptance.operationID.uuidString.lowercased(),
                    "session_id": winner.sessionID,
                    "turn_id": continuation.intent.turnID.uuidString.lowercased(),
                ],
                connection: connection
            )
            return ContinuitySuccessorAcceptanceReceipt(
                winner: winner,
                automaticContinuation: continuation,
                quarantinedSessionIDs: quarantined
            )
        }
    }

    /// Finalizes the control-plane half only after project-memory V2 has durably sealed
    /// the predecessor. Clearing active_operation_id permits the next independent rollover.
    @discardableResult
    public func completeContinuitySuccessor(
        runID: RunID,
        operationID: UUID,
        predecessorSessionID: String,
        successorSessionID: String,
        commandID: UUID,
        lease: RunLease
    ) throws -> ContinuityCommand {
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            guard lease.runID == runID,
                  let run = try autonomousRunUnlocked(runID, connection: connection),
                  run.activeOperationID == operationID,
                  run.activeSessionID == successorSessionID,
                  let successor = try providerSessionRecordUnlocked(successorSessionID, connection: connection),
                  successor.operationID == operationID,
                  successor.status == .active,
                  successor.accepted else {
                throw AutonomyError.transitionConflict
            }
            try connection.execute(
                """
                UPDATE provider_sessions SET status='sealed',accepted=0,updated_at=?
                WHERE session_id=? AND run_id=? AND status IN ('fencing','fenced','sealed')
                """,
                bindings: [
                    .text(timestamp), .text(predecessorSessionID), .text(runID.description),
                ]
            )
            try connection.execute(
                """
                UPDATE project_bindings SET active=0,updated_at=?
                WHERE owner_kind='provider_session' AND owner_id=?
                """,
                bindings: [.text(timestamp), .text(predecessorSessionID)]
            )
            guard let command = try continuityCommandUnlocked(
                commandID: commandID,
                connection: connection
            ), command.operationID == operationID, command.runID == runID else {
                throw ContinuityCommandQueueError.commandNotFound(commandID)
            }
            if command.state == .claimed {
                let running = try connection.execute(
                    "UPDATE continuity_commands SET state='running',updated_at=? WHERE command_id=? AND state='claimed'",
                    bindings: [.text(timestamp), .text(commandID.uuidString.lowercased())]
                )
                guard running == 1 else { throw ContinuityCommandQueueError.claimConflict }
            }
            if command.state != .completed {
                let completed = try connection.execute(
                    "UPDATE continuity_commands SET state='completed',updated_at=? WHERE command_id=? AND state='running'",
                    bindings: [.text(timestamp), .text(commandID.uuidString.lowercased())]
                )
                guard completed == 1 else { throw ContinuityCommandQueueError.claimConflict }
            }
            try connection.execute(
                """
                UPDATE autonomous_runs SET active_operation_id=NULL,revision=revision+1,updated_at=?
                WHERE run_id=? AND active_operation_id=? AND active_session_id=?
                """,
                bindings: [
                    .text(timestamp), .text(runID.description),
                    .text(operationID.uuidString.lowercased()), .text(successorSessionID),
                ]
            )
            guard let completed = try continuityCommandUnlocked(
                commandID: commandID,
                connection: connection
            ) else {
                throw ProjectContextError.integrityFailure("completed continuity command is unreadable")
            }
            return completed
        }
    }

    public func automaticContinuation(
        operationID: UUID
    ) throws -> ProviderTurnRecord? {
        try providerTurnForOperationUnlocked(
            operationID: operationID,
            kind: .automaticContinuation,
            connection: requiredConnection()
        )
    }

    public func pendingAutomaticContinuation(
        runID: RunID
    ) throws -> ProviderTurnRecord? {
        try requiredConnection().first(
            Self.providerTurnSelect
                + """
                 WHERE run_id=? AND request_kind='automatic_continuation'
                   AND state IN ('intent','submitted','streaming','ambiguous','retry_wait')
                 ORDER BY created_at,turn_id LIMIT 1
                """,
            bindings: [.text(runID.description)],
            map: Self.decodeProviderTurn
        )
    }

    @discardableResult
    public func persistProviderTurnIntent(
        _ intent: ProviderTurnIntent,
        lease: RunLease
    ) throws -> ProviderTurnRecord {
        return try persistProviderTurnIntentScoped(intent, lease: lease, bootstrapGrant: nil)
    }

    func persistProviderTurnIntent(
        _ intent: ProviderTurnIntent,
        lease: RunLease,
        bootstrapGrant: ContinuityBootstrapGrant
    ) throws -> ProviderTurnRecord {
        return try persistProviderTurnIntentScoped(intent, lease: lease, bootstrapGrant: bootstrapGrant)
    }

    private func persistProviderTurnIntentScoped(
        _ intent: ProviderTurnIntent,
        lease: RunLease,
        bootstrapGrant: ContinuityBootstrapGrant?
    ) throws -> ProviderTurnRecord {
        try Self.validate(intent)
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction(fullDurability: bootstrapGrant != nil) {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            if let bootstrapGrant {
                try validateBootstrapTurnIntentUnlocked(intent, grant: bootstrapGrant, lease: lease, connection: connection)
            } else {
                try requireNoContinuityIngressHoldUnlocked(intent.runID, connection: connection)
            }
            guard let run = try autonomousRunUnlocked(intent.runID, connection: connection) else {
                throw AutonomyError.runNotFound(intent.runID)
            }
            guard run.projectID == intent.projectID,
                  run.projectGeneration == intent.projectGeneration else {
                throw ProjectContextError.projectScopeMismatch
            }
            guard let session = try providerSessionIdentityUnlocked(intent.sessionID, connection: connection) else {
                throw AutonomyError.providerSessionNotFound(intent.sessionID)
            }
            guard session.runID == intent.runID,
                  session.projectID == intent.projectID,
                  session.projectGeneration == intent.projectGeneration else {
                throw ProjectContextError.projectScopeMismatch
            }
            let isAcceptedActive = session.status == .active && session.accepted
            let isCandidateBootstrap = session.status == .candidate
                && !session.accepted && intent.kind == .bootstrap
            guard isAcceptedActive || isCandidateBootstrap else {
                throw AutonomyError.invalidRequest(
                    "provider session is not authorized for this turn kind"
                )
            }
            if let existing = try providerTurnBySessionKeyUnlocked(
                sessionID: intent.sessionID,
                idempotencyKey: intent.idempotencyKey,
                connection: connection
            ) {
                guard Self.providerTurn(existing, matches: intent) else {
                    throw AutonomyError.intentConflict
                }
                return existing
            }
            try connection.execute(
                """
                INSERT INTO provider_turns(
                    turn_id,run_id,session_id,operation_id,project_id,project_generation,
                    request_kind,idempotency_key,previous_response_id,input_sha256,tool_schema_sha256,
                    state,attempt,created_at,updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,'intent',0,?,?)
                """,
                bindings: [
                    .text(intent.turnID.uuidString.lowercased()), .text(intent.runID.description),
                    .text(intent.sessionID), .optionalText(intent.operationID?.uuidString.lowercased()),
                    .text(intent.projectID.description),
                    .int64(try Self.sqliteGeneration(intent.projectGeneration)),
                    .text(intent.kind.rawValue), .text(intent.idempotencyKey),
                    .optionalText(intent.previousResponseID), .text(intent.inputSHA256),
                    .optionalText(intent.toolSchemaSHA256), .text(timestamp), .text(timestamp),
                ]
            )
            try appendAutonomyEventUnlocked(
                runID: intent.runID,
                projectID: intent.projectID,
                eventType: "provider_turn_intent_persisted",
                severity: .debug,
                summary: "Provider turn intent was committed before dispatch",
                metadata: [
                    "request_kind": intent.kind.rawValue,
                    "turn_id": intent.turnID.uuidString.lowercased(),
                ],
                connection: connection
            )
            guard let inserted = try providerTurnUnlocked(intent.turnID, connection: connection) else {
                throw ProjectContextError.integrityFailure("provider turn intent could not be read back")
            }
            return inserted
        }
    }

    /// Freezes the actual native request observation and the first submission in
    /// one FULL transaction. An existing submission is always lookup-only.
    func beginSourceDerivedProviderTurn(intent: ProviderTurnIntent, preflight: ProviderRequestPreflight,
        capabilities: ProviderCapabilities, lease: RunLease, bootstrapGrant: ContinuityBootstrapGrant? = nil,
        cancellation: ToolCallCancellation? = nil) throws -> SourceDerivedProviderTurnAdmission {
        try Self.validate(intent)
        return try controlledTransaction(cancellation: cancellation, fullDurability: true, beforeCommitValidation: {
            _ = try self.sourceDerivedTurnAuthorityUnlocked(turnID: intent.turnID, lease: lease,
                bootstrapGrant: bootstrapGrant, connection: self.requiredConnection())
        }) { connection in
            let (current, carryover) = try sourceDerivedTurnAuthorityUnlocked(turnID: intent.turnID,
                lease: lease, bootstrapGrant: bootstrapGrant, connection: connection)
            guard Self.providerTurn(current, matches: intent) else { throw AutonomyError.intentConflict }
            try validateSourceDerivedPreflightUnlocked(preflight, capabilities: capabilities, intent: intent,
                carryover: carryover, connection: connection)
            if let retained = try sourceDerivedPreflightUnlocked(current, connection: connection) {
                guard retained.intent == intent, retained.preflight == preflight, retained.capabilities == capabilities else {
                    throw AutonomyError.intentConflict
                }
                guard current.state != .intent else { throw NativeSourceConversationError.integrityFailure }
                return current.state == .completed ? .completed(current) : .lookupOnly(current)
            }
            guard current.state == .intent, current.attempt == 0 else {
                // Older submitted rows have no attestation. Neither an expired
                // cache nor a missing receipt grants permission to repeat POST.
                return current.state == .completed ? .completed(current) : .lookupOnly(current)
            }
            let timestamp = ISO8601.string(from: clock.now())
            let stored = SourceDerivedProviderTurnStoredPreflight(version: 1, intent: current.intent,
                preflight: .init(preflight), capabilities: capabilities, submissionID: UUID(),
                leaseOwner: lease.ownerID, leaseEpoch: lease.epoch, recordedAt: timestamp)
            let bytes = try NativeSourceJournalCoding.encode(stored, maximum: SourceDerivedProviderTurnStoredPreflight.maximumBytes)
            let sha = JSONSupport.sha256Hex(bytes)
            _ = try stored.validatedReceipt(sha256: sha)
            let changed = try connection.execute("""
                UPDATE provider_turns SET source_preflight_json=?,source_preflight_sha256=?,state='submitted',
                    attempt=attempt+1,retry_at=NULL,last_error_code=NULL,last_error_summary=NULL,updated_at=?
                WHERE turn_id=? AND state='intent' AND attempt=0 AND source_preflight_json IS NULL AND source_preflight_sha256 IS NULL
                """, bindings: [.text(String(decoding: bytes, as: UTF8.self)),.text(sha),.text(timestamp),
                    .text(intent.turnID.uuidString.lowercased())])
            guard changed == 1 else { throw AutonomyError.transitionConflict }
            _ = try sourceDerivedTurnAuthorityUnlocked(turnID: intent.turnID, lease: lease,
                bootstrapGrant: bootstrapGrant, connection: connection)
            return .dispatch
        }
    }

    /// Restores the original observation before a recovery caller considers a
    /// provider probe. The caller still has to resolve its recorded result.
    func sourceDerivedProviderTurnPreflight(turnID: UUID, lease: RunLease,
        bootstrapGrant: ContinuityBootstrapGrant? = nil, cancellation: ToolCallCancellation? = nil
    ) throws -> SourceDerivedProviderTurnPreflightReceipt? {
        try controlledTransaction(cancellation: cancellation) { connection in
            let (current, _) = try sourceDerivedTurnAuthorityUnlocked(turnID: turnID, lease: lease,
                bootstrapGrant: bootstrapGrant, connection: connection)
            return try sourceDerivedPreflightUnlocked(current, connection: connection)
        }
    }

    private func sourceDerivedTurnAuthorityUnlocked(turnID: UUID, lease: RunLease,
        bootstrapGrant: ContinuityBootstrapGrant?, connection: ControlPlaneSQLiteConnection
    ) throws -> (ProviderTurnRecord, NativeSourceBudgetCarryover?) {
        try verifyRunLeaseUnlocked(lease, timestamp: ISO8601.string(from: clock.now()), connection: connection)
        guard let metadata = try connection.first("SELECT run_id,project_id,project_generation FROM provider_turns WHERE turn_id=?",
            bindings: [.text(turnID.uuidString.lowercased())], map: {
                (try $0.strictText(0, maximumBytes: 36),try $0.strictText(1, maximumBytes: 36),$0.int64(2))
            }) else { throw AutonomyError.providerTurnNotFound(turnID) }
        guard metadata.0 == lease.runID.description else { throw AutonomyError.staleLease }
        guard let run = try autonomousRunUnlocked(lease.runID, connection: connection),
              metadata.1 == run.projectID.description, metadata.2 == (try Self.sqliteGeneration(run.projectGeneration)) else {
            throw ProjectContextError.projectScopeMismatch
        }
        _ = try requiredActiveProjectUnlocked(run.projectID, generation: run.projectGeneration, connection: connection)
        guard let current = try providerTurnUnlocked(turnID, connection: connection) else { throw AutonomyError.providerTurnNotFound(turnID) }
        let intent = Self.sourceDerivedIntent(current.intent)
        if let bootstrapGrant {
            try validateBootstrapTurnIntentUnlocked(intent, grant: bootstrapGrant, lease: lease, connection: connection)
        } else {
            try requireNoContinuityIngressHoldUnlocked(run.runID, connection: connection)
            guard let session = try providerSessionIdentityUnlocked(intent.sessionID, connection: connection),
                  session.runID == run.runID, session.projectID == run.projectID, session.projectGeneration == run.projectGeneration,
                  session.status == .active, session.accepted, run.activeSessionID == intent.sessionID else {
                throw AutonomyError.intentConflict
            }
        }
        let carryover = try nativeSourceBudgetCarryoverUnlocked(runID: run.runID, connection: connection)
        guard bootstrapGrant != nil || carryover != nil else { throw NativeSourceConversationError.unsupportedProvider }
        return (current, carryover)
    }

    private func validateSourceDerivedPreflightUnlocked(_ preflight: ProviderRequestPreflight,
        capabilities: ProviderCapabilities, intent: ProviderTurnIntent, carryover: NativeSourceBudgetCarryover?,
        connection: ControlPlaneSQLiteConnection) throws {
        guard let session = try providerSessionIdentityUnlocked(intent.sessionID, connection: connection),
              session.providerID == capabilities.providerID, session.modelKey == capabilities.modelKey,
              preflight.modelKey == capabilities.modelKey,
              preflight.kind == (intent.previousResponseID == nil ? .root : .continuation),
              capabilities.statefulResponses, capabilities.customTools else { throw AutonomyError.intentConflict }
        if let carryover {
            guard preflight.limits.maximumOutputTokens <= carryover.ceilings.maximumOutputTokens,
                  preflight.limits.maximumOutputTokens < min(capabilities.contextLength, carryover.ceilings.effectiveContextTokens) else {
                throw NativeSourceConversationError.budgetExceeded
            }
        }
        // The immutable wrappers revalidate all serialized limits, counts and
        // observed capability bounds, including values restored from disk.
        _ = try NativeSourceStoredPreflight(preflight).value()
    }

    private func sourceDerivedPreflightUnlocked(_ current: ProviderTurnRecord,
        connection: ControlPlaneSQLiteConnection) throws -> SourceDerivedProviderTurnPreflightReceipt? {
        guard let values = try connection.first("SELECT source_preflight_json,source_preflight_sha256 FROM provider_turns WHERE turn_id=?",
            bindings: [.text(current.intent.turnID.uuidString.lowercased())], map: {
                (try $0.strictText(0, maximumBytes: SourceDerivedProviderTurnStoredPreflight.maximumBytes),try $0.strictText(1, maximumBytes: 64))
            }) else { throw AutonomyError.providerTurnNotFound(current.intent.turnID) }
        guard values.0 != nil || values.1 != nil else { return nil }
        guard let json = values.0, let sha = values.1, current.state != .intent, current.attempt == 1 else {
            throw NativeSourceConversationError.integrityFailure
        }
        let stored = try NativeSourceJournalCoding.decode(SourceDerivedProviderTurnStoredPreflight.self,
            json, sha: sha, maximum: SourceDerivedProviderTurnStoredPreflight.maximumBytes)
        let receipt = try stored.validatedReceipt(sha256: sha)
        guard Self.providerTurn(current, matches: receipt.intent) else { throw NativeSourceConversationError.integrityFailure }
        return receipt
    }

    private static func sourceDerivedIntent(_ value: ProviderTurnIntentRecord) -> ProviderTurnIntent {
        .init(turnID: value.turnID, runID: value.runID, sessionID: value.sessionID, operationID: value.operationID,
            projectID: value.projectID, projectGeneration: value.projectGeneration, kind: value.kind,
            idempotencyKey: value.idempotencyKey, previousResponseID: value.previousResponseID,
            inputSHA256: value.inputSHA256, toolSchemaSHA256: value.toolSchemaSHA256)
    }

    @discardableResult
    public func transitionProviderTurn(
        turnID: UUID,
        expected: ProviderTurnState,
        to next: ProviderTurnState,
        lease: RunLease,
        providerRequestID: String? = nil,
        providerResponseID: String? = nil,
        usageJSON: String? = nil,
        retryAt: String? = nil,
        errorCode: String? = nil,
        errorSummary: String? = nil
    ) throws -> ProviderTurnRecord {
        return try transitionProviderTurnScoped(turnID: turnID, expected: expected, to: next, lease: lease, providerRequestID: providerRequestID, providerResponseID: providerResponseID, usageJSON: usageJSON, retryAt: retryAt, errorCode: errorCode, errorSummary: errorSummary, bootstrapGrant: nil)
    }

    func transitionProviderTurn(
        turnID: UUID,
        expected: ProviderTurnState,
        to next: ProviderTurnState,
        lease: RunLease,
        providerRequestID: String? = nil,
        providerResponseID: String? = nil,
        usageJSON: String? = nil,
        retryAt: String? = nil,
        errorCode: String? = nil,
        errorSummary: String? = nil,
        bootstrapGrant: ContinuityBootstrapGrant
    ) throws -> ProviderTurnRecord {
        return try transitionProviderTurnScoped(turnID: turnID, expected: expected, to: next, lease: lease, providerRequestID: providerRequestID, providerResponseID: providerResponseID, usageJSON: usageJSON, retryAt: retryAt, errorCode: errorCode, errorSummary: errorSummary, bootstrapGrant: bootstrapGrant)
    }

    private func transitionProviderTurnScoped(
        turnID: UUID,
        expected: ProviderTurnState,
        to next: ProviderTurnState,
        lease: RunLease,
        providerRequestID: String? = nil,
        providerResponseID: String? = nil,
        usageJSON: String? = nil,
        retryAt: String? = nil,
        errorCode: String? = nil,
        errorSummary: String? = nil,
        bootstrapGrant: ContinuityBootstrapGrant?
    ) throws -> ProviderTurnRecord {
        guard Self.validProviderTurnTransitions[expected]?.contains(next) == true else {
            throw AutonomyError.invalidRequest("invalid provider turn transition \(expected.rawValue) -> \(next.rawValue)")
        }
        let boundedUsage = try Self.boundedOptional(usageJSON, maximumBytes: 64 * 1_024, field: "provider usage JSON")
        let boundedError = try Self.boundedOptional(errorSummary, maximumBytes: 2_048, field: "provider turn error")
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction(fullDurability: bootstrapGrant != nil) {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            guard let current = try providerTurnUnlocked(turnID, connection: connection) else {
                throw AutonomyError.providerTurnNotFound(turnID)
            }
            guard current.intent.runID == lease.runID else { throw AutonomyError.staleLease }
            if next == .submitted {
                let hasReceipt = try connection.scalarInt("SELECT COUNT(*) FROM provider_turns WHERE turn_id=? AND source_preflight_json IS NOT NULL",
                    bindings: [.text(turnID.uuidString.lowercased())]) != 0
                let carryover = try nativeSourceBudgetCarryoverUnlocked(runID: current.intent.runID, connection: connection)
                if hasReceipt || carryover != nil {
                    throw AutonomyError.invalidRequest("source-derived provider dispatch requires retained request preflight")
                }
            }
            if let bootstrapGrant {
                try validateBootstrapGrantUnlocked(bootstrapGrant, lease: lease, connection: connection)
                try validateBootstrapTurnIntentUnlocked(ProviderTurnIntent(turnID: current.intent.turnID,
                    runID: current.intent.runID, sessionID: current.intent.sessionID, operationID: current.intent.operationID,
                    projectID: current.intent.projectID, projectGeneration: current.intent.projectGeneration,
                    kind: current.intent.kind, idempotencyKey: current.intent.idempotencyKey,
                    previousResponseID: current.intent.previousResponseID, inputSHA256: current.intent.inputSHA256,
                    toolSchemaSHA256: current.intent.toolSchemaSHA256), grant: bootstrapGrant, lease: lease, connection: connection)
            }
            if bootstrapGrant == nil && (next == .submitted || next == .streaming) {
                try requireNoContinuityIngressHoldUnlocked(current.intent.runID, connection: connection)
            }
            let changed = try connection.execute(
                """
                UPDATE provider_turns SET state=?,provider_request_id=COALESCE(?,provider_request_id),
                    provider_response_id=COALESCE(?,provider_response_id),usage_json=COALESCE(?,usage_json),
                    attempt=attempt+?,retry_at=?,last_error_code=?,last_error_summary=?,updated_at=?
                WHERE turn_id=? AND state=?
                """,
                bindings: [
                    .text(next.rawValue), .optionalText(providerRequestID), .optionalText(providerResponseID),
                    .optionalText(boundedUsage), .int64(next == .submitted ? 1 : 0),
                    .optionalText(retryAt), .optionalText(errorCode), .optionalText(boundedError),
                    .text(timestamp), .text(turnID.uuidString.lowercased()), .text(expected.rawValue),
                ]
            )
            guard changed == 1 else { throw AutonomyError.transitionConflict }
            if current.intent.kind == .automaticContinuation, next == .completed {
                guard let session = try providerSessionIdentityUnlocked(
                    current.intent.sessionID,
                    connection: connection
                ), session.status == .active, session.accepted else {
                    throw AutonomyError.invalidRequest(
                        "automatic continuation completed for a non-active successor"
                    )
                }
                let cleared = try connection.execute(
                    """
                    UPDATE autonomous_runs SET continuation_pending=0,
                        revision=revision+1,updated_at=?
                    WHERE run_id=? AND active_session_id=? AND continuation_pending=1
                    """,
                    bindings: [
                        .text(timestamp), .text(current.intent.runID.description),
                        .text(current.intent.sessionID),
                    ]
                )
                guard cleared == 1 else { throw AutonomyError.transitionConflict }
            }
            guard let updated = try providerTurnUnlocked(turnID, connection: connection) else {
                throw ProjectContextError.integrityFailure("provider turn could not be read after transition")
            }
            return updated
        }
    }

    public func providerTurn(_ turnID: UUID) throws -> ProviderTurnRecord? {
        try providerTurnUnlocked(turnID, connection: requiredConnection())
    }

    @discardableResult
    public func persistToolInvocationIntent(
        _ intent: ToolInvocationIntent,
        lease: RunLease
    ) throws -> ToolInvocationRecord {
        return try persistToolInvocationIntentScoped(intent, lease: lease, bootstrapGrant: nil, bootstrapPolicy: nil, sourcePolicy: nil)
    }

    func persistToolInvocationIntent(
        _ intent: ToolInvocationIntent,
        lease: RunLease,
        bootstrapGrant: ContinuityBootstrapGrant,
        bootstrapPolicy: BudgetPolicySelection
    ) throws -> ToolInvocationRecord {
        return try persistToolInvocationIntentScoped(intent, lease: lease, bootstrapGrant: bootstrapGrant, bootstrapPolicy: bootstrapPolicy, sourcePolicy: nil)
    }

    func persistToolInvocationIntent(_ intent: ToolInvocationIntent, lease: RunLease,
        sourcePolicy: BudgetPolicySelection, cancellation: ToolCallCancellation? = nil) throws -> ToolInvocationRecord {
        try cancellation?.checkCancellation()
        return try persistToolInvocationIntentScoped(intent, lease: lease, bootstrapGrant: nil, bootstrapPolicy: nil, sourcePolicy: sourcePolicy)
    }

    private func persistToolInvocationIntentScoped(
        _ intent: ToolInvocationIntent,
        lease: RunLease,
        bootstrapGrant: ContinuityBootstrapGrant?,
        bootstrapPolicy: BudgetPolicySelection?,
        sourcePolicy: BudgetPolicySelection?
    ) throws -> ToolInvocationRecord {
        try Self.validate(intent)
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction(fullDurability: bootstrapGrant != nil) {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            if let bootstrapGrant {
                try validateBootstrapToolIntentUnlocked(intent, grant: bootstrapGrant, lease: lease, connection: connection)
                guard let bootstrapPolicy else { throw ContinuityIngressError.invalidRequest("current bootstrap tool policy") }
                try ContinuityIngressAcceptanceReceipt.validatePolicy(bootstrapPolicy, authorization: bootstrapGrant.envelope.authorization)
                // Policy output limits apply even when the invocation already
                // exists after a crash or has a completed replayable result.
                try requireBootstrapResultLimitsUnlocked(grant: bootstrapGrant, policy: bootstrapPolicy.policy.tools, connection: connection)
            } else {
                try requireNoContinuityIngressHoldUnlocked(intent.runID, connection: connection)
            }
            guard intent.runID == lease.runID else { throw AutonomyError.staleLease }
            guard let turn = try providerTurnUnlocked(intent.turnID, connection: connection) else {
                throw AutonomyError.providerTurnNotFound(intent.turnID)
            }
            guard turn.intent.runID == intent.runID,
                  turn.intent.sessionID == intent.sessionID,
                  turn.intent.projectID == intent.projectID,
                  turn.intent.projectGeneration == intent.projectGeneration else {
                throw ProjectContextError.projectScopeMismatch
            }
            guard let session = try providerSessionIdentityUnlocked(
                intent.sessionID,
                connection: connection
            ), (session.status == .active && session.accepted)
                    || (bootstrapGrant != nil && session.status == .candidate && !session.accepted) else {
                throw AutonomyError.invalidRequest(
                    "only the accepted active provider session may invoke project tools"
                )
            }
            _ = try requiredActiveProjectUnlocked(
                intent.projectID,
                generation: intent.projectGeneration,
                connection: connection
            )
            let sourceOffset = try nativeRunSourceOffsetUnlocked(intent.runID, connection: connection)
            if sourceOffset != nil, bootstrapGrant == nil {
                guard let sourcePolicy else { throw NativeTaskCapabilityError.budgetExceeded }
                _ = try sourcePolicy.policy.validated(); _ = try sourcePolicy.scope.validated()
                guard sourcePolicy.scope.kind == .globalDefault || (sourcePolicy.scope.projectID == intent.projectID.description
                    && sourcePolicy.scope.projectGeneration == Int(intent.projectGeneration.rawValue)) else { throw NativeTaskCapabilityError.budgetExceeded }
            }
            if let existing = try toolInvocationByProviderCallUnlocked(
                sessionID: intent.sessionID,
                providerCallID: intent.providerCallID,
                connection: connection
            ) {
                guard Self.toolInvocation(existing, matches: intent) else {
                    throw AutonomyError.intentConflict
                }
                if let offset = sourceOffset, let currentPolicy = bootstrapPolicy ?? sourcePolicy {
                    if existing.state == .completed {
                        guard let json = existing.resultSummary, JSONSupport.sha256Hex(json) == existing.resultSHA256 else {
                            throw NativeTaskCapabilityError.integrityFailure
                        }
                        try nativeManagedResultBounds(Data(json.utf8), policy: currentPolicy.policy.tools, runID: intent.runID, connection: connection)
                    } else if [.intent, .executing, .ambiguous, .failed].contains(existing.state) {
                        // The retained row already consumes one call. Fresh
                        // policy must still cover it and all source debits.
                        try requireNativeManagedToolQuotaUnlocked(intent: intent, offset: offset,
                            policy: currentPolicy.policy.tools, alreadyReserved: true, connection: connection)
                    }
                }
                return existing
            }
            if let bootstrapGrant, let bootstrapPolicy {
                try requireBootstrapToolQuotaUnlocked(runID: intent.runID, sessionID: intent.sessionID,
                    turnID: intent.turnID, operationID: bootstrapGrant.envelope.operationID,
                    policy: bootstrapPolicy.policy.tools, connection: connection)
            }
            if let offset = sourceOffset, bootstrapGrant == nil, let sourcePolicy {
                try requireNativeManagedToolQuotaUnlocked(intent: intent, offset: offset, policy: sourcePolicy.policy.tools, connection: connection)
            }
            try connection.execute(
                """
                INSERT INTO tool_invocations(
                    invocation_id,turn_id,run_id,session_id,project_id,project_generation,
                    provider_call_id,tool_name,replay_class,idempotency_key,arguments_sha256,
                    arguments_artifact_id,state,created_at,updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,'intent',?,?)
                """,
                bindings: [
                    .text(intent.invocationID.uuidString.lowercased()),
                    .text(intent.turnID.uuidString.lowercased()), .text(intent.runID.description),
                    .text(intent.sessionID), .text(intent.projectID.description),
                    .int64(try Self.sqliteGeneration(intent.projectGeneration)),
                    .text(intent.providerCallID), .text(intent.toolName),
                    .text(intent.replayClass.rawValue), .optionalText(intent.idempotencyKey),
                    .text(intent.argumentsSHA256),
                    .optionalText(intent.reconciliationDescriptor),
                    .text(timestamp), .text(timestamp),
                ]
            )
            try appendAutonomyEventUnlocked(
                runID: intent.runID,
                projectID: intent.projectID,
                eventType: "tool_invocation_intent_persisted",
                severity: .debug,
                summary: "Tool invocation intent was committed before dispatch",
                metadata: [
                    "invocation_id": intent.invocationID.uuidString.lowercased(),
                    "replay_class": intent.replayClass.rawValue,
                    "tool_name": intent.toolName,
                ],
                connection: connection
            )
            guard let inserted = try toolInvocationUnlocked(intent.invocationID, connection: connection) else {
                throw ProjectContextError.integrityFailure("tool invocation intent could not be read back")
            }
            return inserted
        }
    }

    @discardableResult
    public func transitionToolInvocation(
        invocationID: UUID,
        expected: ToolInvocationState,
        to next: ToolInvocationState,
        lease: RunLease,
        resultSHA256: String? = nil,
        resultSummary: String? = nil,
        errorCode: String? = nil,
        errorSummary: String? = nil
    ) throws -> ToolInvocationRecord {
        return try transitionToolInvocationScoped(invocationID: invocationID, expected: expected, to: next, lease: lease, resultSHA256: resultSHA256, resultSummary: resultSummary, errorCode: errorCode, errorSummary: errorSummary, bootstrapGrant: nil, sourcePolicy: nil)
    }

    func transitionToolInvocation(
        invocationID: UUID,
        expected: ToolInvocationState,
        to next: ToolInvocationState,
        lease: RunLease,
        resultSHA256: String? = nil,
        resultSummary: String? = nil,
        errorCode: String? = nil,
        errorSummary: String? = nil,
        bootstrapGrant: ContinuityBootstrapGrant
    ) throws -> ToolInvocationRecord {
        return try transitionToolInvocationScoped(invocationID: invocationID, expected: expected, to: next, lease: lease, resultSHA256: resultSHA256, resultSummary: resultSummary, errorCode: errorCode, errorSummary: errorSummary, bootstrapGrant: bootstrapGrant, sourcePolicy: nil)
    }

    func transitionToolInvocation(invocationID: UUID, expected: ToolInvocationState, to next: ToolInvocationState,
        lease: RunLease, resultSHA256: String? = nil, resultSummary: String? = nil, errorCode: String? = nil,
        errorSummary: String? = nil, sourcePolicy: BudgetPolicySelection) throws -> ToolInvocationRecord {
        try transitionToolInvocationScoped(invocationID: invocationID, expected: expected, to: next, lease: lease,
            resultSHA256: resultSHA256, resultSummary: resultSummary, errorCode: errorCode, errorSummary: errorSummary,
            bootstrapGrant: nil, sourcePolicy: sourcePolicy)
    }

    private func transitionToolInvocationScoped(
        invocationID: UUID,
        expected: ToolInvocationState,
        to next: ToolInvocationState,
        lease: RunLease,
        resultSHA256: String? = nil,
        resultSummary: String? = nil,
        errorCode: String? = nil,
        errorSummary: String? = nil,
        bootstrapGrant: ContinuityBootstrapGrant?,
        sourcePolicy: BudgetPolicySelection?
    ) throws -> ToolInvocationRecord {
        guard Self.validToolInvocationTransitions[expected]?.contains(next) == true else {
            throw AutonomyError.invalidRequest("invalid tool invocation transition \(expected.rawValue) -> \(next.rawValue)")
        }
        if let resultSHA256 { try Self.validateSHA256(resultSHA256, field: "tool result SHA-256") }
        let boundedResult = try Self.boundedOptional(resultSummary, maximumBytes: 64 * 1_024, field: "tool result summary")
        let boundedError = try Self.boundedOptional(errorSummary, maximumBytes: 2_048, field: "tool error summary")
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction(fullDurability: bootstrapGrant != nil) {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            guard let current = try toolInvocationUnlocked(invocationID, connection: connection) else {
                throw AutonomyError.toolInvocationNotFound(invocationID)
            }
            guard current.runID == lease.runID else { throw AutonomyError.staleLease }
            if let bootstrapGrant {
                try validateBootstrapGrantUnlocked(bootstrapGrant, lease: lease, connection: connection)
                guard next != .completed else {
                    throw ContinuityIngressError.invalidRequest("bootstrap completion requires the guarded exact-source read")
                }
                try validateBootstrapToolIntentUnlocked(ToolInvocationIntent(invocationID: current.invocationID,
                    turnID: current.turnID, runID: current.runID, sessionID: current.sessionID,
                    projectID: current.projectID, projectGeneration: current.projectGeneration,
                    providerCallID: current.providerCallID, toolName: current.toolName, replayClass: current.replayClass,
                    idempotencyKey: current.idempotencyKey, argumentsSHA256: current.argumentsSHA256,
                    reconciliationDescriptor: current.reconciliationDescriptor), grant: bootstrapGrant, lease: lease, connection: connection)
            }
            if bootstrapGrant == nil && next == .executing {
                try requireNoContinuityIngressHoldUnlocked(current.runID, connection: connection)
            }
            _ = try requiredActiveProjectUnlocked(
                current.projectID,
                generation: current.projectGeneration,
                connection: connection
            )
            if bootstrapGrant == nil, [.executing, .completed].contains(next),
               let offset = try nativeRunSourceOffsetUnlocked(current.runID, connection: connection) {
                guard let sourcePolicy else { throw NativeTaskCapabilityError.budgetExceeded }
                _ = try sourcePolicy.policy.validated(); _ = try sourcePolicy.scope.validated()
                guard sourcePolicy.scope.kind == .globalDefault || (sourcePolicy.scope.projectID == current.projectID.description
                    && sourcePolicy.scope.projectGeneration == Int(current.projectGeneration.rawValue)) else {
                    throw NativeTaskCapabilityError.budgetExceeded
                }
                try requireNoContinuityIngressHoldUnlocked(current.runID, connection: connection)
                try requireNativeManagedToolQuotaUnlocked(intent: Self.nativeRetainedToolIntent(current), offset: offset,
                    policy: sourcePolicy.policy.tools, alreadyReserved: true, connection: connection)
                if next == .completed {
                    guard let boundedResult, let resultSHA256, JSONSupport.sha256Hex(boundedResult) == resultSHA256 else {
                        throw NativeTaskCapabilityError.integrityFailure
                    }
                    try nativeManagedResultBounds(Data(boundedResult.utf8), policy: sourcePolicy.policy.tools, runID: current.runID, connection: connection)
                }
            }
            let changed = try connection.execute(
                """
                UPDATE tool_invocations SET state=?,result_sha256=COALESCE(?,result_sha256),
                    result_summary=COALESCE(?,result_summary),last_error_code=?,last_error_summary=?,updated_at=?
                WHERE invocation_id=? AND state=?
                """,
                bindings: [
                    .text(next.rawValue), .optionalText(resultSHA256), .optionalText(boundedResult),
                    .optionalText(errorCode), .optionalText(boundedError), .text(timestamp),
                    .text(invocationID.uuidString.lowercased()), .text(expected.rawValue),
                ]
            )
            guard changed == 1 else { throw AutonomyError.transitionConflict }
            guard let updated = try toolInvocationUnlocked(invocationID, connection: connection) else {
                throw ProjectContextError.integrityFailure("tool invocation could not be read after transition")
            }
            return updated
        }
    }

    public func toolInvocation(
        sessionID: String,
        providerCallID: String
    ) throws -> ToolInvocationRecord? {
        try toolInvocationByProviderCallUnlocked(
            sessionID: sessionID,
            providerCallID: providerCallID,
            connection: requiredConnection()
        )
    }

    /// Reads one exact durable invocation identity without exposing an unbounded
    /// run-wide tool history query.
    public func toolInvocation(_ invocationID: UUID) throws -> ToolInvocationRecord? {
        try toolInvocationUnlocked(invocationID, connection: requiredConnection())
    }

    public func unresolvedToolInvocations(
        runID: RunID,
        limit: Int = 256
    ) throws -> [ToolInvocationRecord] {
        guard (1...1_024).contains(limit) else {
            throw AutonomyError.invalidRequest("tool recovery limit must be between 1 and 1024")
        }
        return try requiredConnection().all(
            Self.toolInvocationSelect
                + " WHERE run_id=? AND state IN ('intent','executing','ambiguous') ORDER BY created_at LIMIT ?",
            bindings: [.text(runID.description), .int64(Int64(limit))],
            map: Self.decodeToolInvocation
        )
    }

    @discardableResult
    public func quarantineStaleResult(
        context: ToolInvocationContext,
        resultKind: String,
        resultSHA256: String? = nil,
        cancellation: ToolCallCancellation? = nil
    ) throws -> String {
        try cancellation?.checkCancellation()
        try Self.validate(context.projectGeneration)
        let kind = resultKind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty, kind.utf8.count <= 128 else {
            throw ProjectContextError.invalidIdentifier("stale result kind")
        }
        if let resultSHA256 {
            let fullRange = resultSHA256.startIndex..<resultSHA256.endIndex
            guard resultSHA256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) == fullRange else {
                throw ProjectContextError.invalidIdentifier("result SHA-256")
            }
        }
        try cancellation?.checkCancellation()
        return try controlledTransaction(cancellation: cancellation) { connection in
            guard let project = try projectUnlocked(context.projectID, connection: connection) else {
                throw ProjectContextError.projectNotFound(context.projectID)
            }
            guard project.generation != context.projectGeneration else {
                throw ProjectContextError.projectScopeMismatch
            }
            let eventID = UUID().uuidString.lowercased()
            try connection.execute(
                """
                INSERT INTO stale_result_quarantine_events(
                    event_id,project_id,stale_generation,current_generation,run_id,
                    result_kind,result_sha256,created_at
                ) VALUES(?,?,?,?,?,?,?,?)
                """,
                bindings: [
                    .text(eventID), .text(context.projectID.description),
                    .int64(try Self.sqliteGeneration(context.projectGeneration)),
                    .int64(try Self.sqliteGeneration(project.generation)),
                    .optionalText(context.runID?.description), .text(kind),
                    .optionalText(resultSHA256?.lowercased()),
                    .text(ISO8601.string(from: clock.now())),
                ]
            )
            try connection.execute(
                """
                DELETE FROM stale_result_quarantine_events
                WHERE project_id=?
                  AND sequence NOT IN (
                    SELECT sequence FROM stale_result_quarantine_events
                    WHERE project_id=?
                    ORDER BY sequence DESC LIMIT ?
                  )
                """,
                bindings: [
                    .text(context.projectID.description), .text(context.projectID.description),
                    .int64(Int64(Self.maximumQuarantineEventsPerProject)),
                ]
            )
            return eventID
        }
    }

    public func quarantineEventCount(projectID: ProjectID) throws -> Int {
        let connection = try requiredConnection()
        return try connection.scalarInt(
            "SELECT COUNT(*) FROM stale_result_quarantine_events WHERE project_id=?",
            bindings: [.text(projectID.description)]
        )
    }

    public func migrationReceiptCount() throws -> Int {
        try requiredConnection().scalarInt(
            "SELECT COUNT(*) FROM migration_receipts WHERE migration_name='control-plane-schema' AND target_version='2'"
        )
    }

    public func health(
        cancellation: ToolCallCancellation? = nil
    ) throws -> ControlPlaneDatabaseHealth {
        try controlledOperation(cancellation: cancellation) { connection in
            let integrity = try connection.scalarText("PRAGMA integrity_check;") ?? "missing"
            guard integrity == "ok" else {
                throw ProjectContextError.integrityFailure(integrity)
            }
            return ControlPlaneDatabaseHealth(
                schemaVersion: try connection.scalarInt(
                    "SELECT version FROM control_schema_version WHERE singleton=1"
                ),
                journalMode: (try connection.scalarText("PRAGMA journal_mode;")) ?? "unknown",
                foreignKeysEnabled: try connection.scalarInt("PRAGMA foreign_keys;") == 1,
                busyTimeoutMilliseconds: try connection.scalarInt("PRAGMA busy_timeout;"),
                integrityResult: integrity
            )
        }
    }

    private func requiredConnection() throws -> ControlPlaneSQLiteConnection {
        guard let connection else { throw ProjectContextError.repositoryClosed }
        return connection
    }

    private func controlledOperation<T>(
        cancellation: ToolCallCancellation?,
        _ body: (ControlPlaneSQLiteConnection) throws -> T
    ) throws -> T {
        let connection = try requiredConnection()
        return try connection.withRequestControl(
            cancellation: cancellation,
            busyRetryObserver: busyRetryObserver,
            beforeCommitObserver: beforeCommitObserver,
            didCommitObserver: didCommitObserver
        ) {
            try body(connection)
        }
    }

    private func controlledTransaction<T>(
        cancellation: ToolCallCancellation?,
        checkCancellationBeforeCommit: Bool = true,
        fullDurability: Bool = false,
        beforeCommitValidation: (() throws -> Void)? = nil,
        _ body: (ControlPlaneSQLiteConnection) throws -> T
    ) throws -> T {
        let connection = try requiredConnection()
        let synchronousObserver = beforeCommitSynchronousObserver
        return try connection.transaction(
            cancellation: cancellation,
            busyRetryObserver: busyRetryObserver,
            beforeCommitObserver: beforeCommitObserver,
            didCommitObserver: didCommitObserver,
            checkCancellationBeforeCommit: checkCancellationBeforeCommit,
            fullDurability: fullDurability,
            beforeCommitValidation: {
                if let synchronousObserver { synchronousObserver(try connection.scalarInt("PRAGMA synchronous;")) }
                try beforeCommitValidation?()
            }
        ) {
            try body(connection)
        }
    }

    private func continuityControlOwnerUnlocked(taskID: UUID, correlation: VerifiedContinuityTaskCorrelation?,
        context: ToolInvocationContext, owner: ProjectBindingOwner, connection: ControlPlaneSQLiteConnection
    ) throws -> ContinuityTaskAuthorizationRecord {
        guard let correlation else { throw ContinuityTaskAuthorizationError.taskCorrelationRequired }
        guard correlation.taskID == taskID, correlation.callerContext == context, correlation.callerOwner == owner else {
            throw ContinuityTaskAuthorizationError.authorityMismatch
        }
        try requireNativeCorrelationUnlocked(correlation, connection: connection)
        let caller = try validatedContinuityCallerUnlocked(context: context, owner: owner, connection: connection)
        guard let retained = try continuityTaskUnlocked(taskID, connection: connection) else { throw ContinuityTaskAuthorizationError.authorityMismatch }
        let task = try validatedContinuityTaskUnlocked(retained.authorization, allowTerminalRun: true, connection: connection)
        guard correlation.callerBindingID == caller.bindingID, correlation.sourceBindingID == task.authorization.sourceBindingID,
              correlation.projectID == task.authorization.projectID, correlation.projectGeneration == task.authorization.projectGeneration,
              caller.projectID == task.authorization.projectID, caller.projectGeneration == task.authorization.projectGeneration,
              correlation.authorizationSHA256 == JSONSupport.sha256Hex(try task.authorization.encodedJSON()),
              context.runID == nil || context.runID == task.runID else { throw ContinuityTaskAuthorizationError.authorityMismatch }
        // existingTask makes this a pure read; unknown historical origins cannot be backfilled.
        try retainSourceDispatchOriginUnlocked(taskID: taskID, caller: caller, timestamp: "", existingTask: true, connection: connection)
        return task
    }

    private func ownedContinuityOperationUnlocked(_ operationID: UUID, task: ContinuityTaskAuthorizationRecord,
        connection: ControlPlaneSQLiteConnection) throws -> ContinuityIngressAcceptanceReceipt {
        // Filtering in SQL makes missing and foreign operations indistinguishable,
        // including a foreign operation whose receipt body is corrupt.
        guard try connection.scalarInt("""
            SELECT COUNT(*) FROM continuity_ingress_acceptances
            WHERE operation_id=? AND task_id=? AND project_id=? AND project_generation=? AND run_id=?
            """, bindings: [.text(operationID.uuidString.lowercased()), .text(task.authorization.taskID.uuidString.lowercased()),
                .text(task.authorization.projectID.description), .int64(try Self.sqliteGeneration(task.authorization.projectGeneration)),
                .optionalText(task.runID?.description)]) == 1 else { throw ContinuityOperationControlError.notFound }
        guard let acceptance = try acceptanceForOperationUnlocked(operationID, connection: connection),
              acceptance.authorization == task.authorization, acceptance.runID == task.runID else { throw ContinuityOperationControlError.integrityFailure }
        return acceptance
    }

    private struct StoredContinuityCancellation {
        let request: ContinuityOperationCancellationRequest
        let receipt: ContinuityOperationCancellationReceipt?
        let reason: String?
        let retryAt: String?
        let blocked: Bool
    }

    private func continuityCancellationUnlocked(_ acceptance: ContinuityIngressAcceptanceReceipt,
        connection: ControlPlaneSQLiteConnection) throws -> StoredContinuityCancellation? {
        try connection.first("""
            SELECT run_id,task_id,project_id,project_generation,acceptance_receipt_sha256,
                request_json,request_sha256,requested_at,receipt_json,receipt_sha256,completed_at,error_code,retry_at,quarantined
            FROM continuity_operation_cancellations WHERE operation_id=?
            """, bindings: [.text(acceptance.operationID.uuidString.lowercased())]) { row in
                guard try row.strictText(0, maximumBytes: 36) == acceptance.runID.description,
                      try row.strictText(1, maximumBytes: 36) == acceptance.authorization.taskID.uuidString.lowercased(),
                      try row.strictText(2, maximumBytes: 36) == acceptance.authorization.projectID.description,
                      row.int64(3) > 0, UInt64(row.int64(3)) == acceptance.authorization.projectGeneration.rawValue,
                      try row.strictText(4, maximumBytes: 64) == acceptance.receiptSHA256,
                      let json = try row.strictText(5, maximumBytes: ContinuityOperationCancellationRequest.maximumStoredBytes),
                      JSONSupport.sha256Hex(Data(json.utf8)) == (try row.strictText(6, maximumBytes: 64)) else {
                    throw ContinuityOperationControlError.integrityFailure
                }
                let request = try ContinuityOperationCancellationRequest.storedSnapshot(from: Data(json.utf8), acceptance: acceptance)
                guard request.requestedAt == (try row.strictText(7, maximumBytes: 128)) else { throw ContinuityOperationControlError.integrityFailure }
                let receiptJSON = try row.strictText(8, maximumBytes: ContinuityOperationCancellationReceipt.maximumStoredBytes)
                let receiptSHA = try row.strictText(9, maximumBytes: 64), completed = try row.strictText(10, maximumBytes: 128)
                guard (receiptJSON == nil) == (receiptSHA == nil), (receiptJSON == nil) == (completed == nil) else {
                    throw ContinuityOperationControlError.integrityFailure
                }
                let receipt: ContinuityOperationCancellationReceipt?
                if let receiptJSON {
                    guard JSONSupport.sha256Hex(Data(receiptJSON.utf8)) == receiptSHA else { throw ContinuityOperationControlError.integrityFailure }
                    receipt = try .storedSnapshot(from: Data(receiptJSON.utf8), request: request)
                    guard receipt?.recordedAt == completed else { throw ContinuityOperationControlError.integrityFailure }
                } else { receipt = nil }
                let reason = try row.strictText(11, maximumBytes: 64), retryAt = try row.strictText(12, maximumBytes: 128)
                guard reason == nil || ContinuityOperationCancellationFailure(rawValue: reason!) != nil,
                      retryAt == nil || ISO8601.date(from: retryAt!) != nil, (0...1).contains(row.int64(13)) else {
                    throw ContinuityOperationControlError.integrityFailure
                }
                return .init(request: request, receipt: receipt, reason: reason, retryAt: retryAt, blocked: row.int64(13) != 0)
            }
    }

    private func continuityOperationStatusUnlocked(_ acceptance: ContinuityIngressAcceptanceReceipt,
        progress: ContinuityOperationProgressEvidence?, connection: ControlPlaneSQLiteConnection) throws -> ContinuityOperationStatus {
        if let progress {
            guard progress.source == acceptance.source else { throw ContinuityOperationControlError.integrityFailure }
            if let delivery = progress.delivery {
                guard delivery.operationID == acceptance.operationID, delivery.handoff == acceptance.source,
                      delivery.acceptanceReceiptSHA256 == nil || delivery.acceptanceReceiptSHA256 == acceptance.receiptSHA256 else {
                    throw ContinuityOperationControlError.integrityFailure
                }
            }
        }
        let cancelled = try continuityCancellationUnlocked(acceptance, connection: connection)
        if let receipt = cancelled?.receipt {
            return .init(acceptance: acceptance, state: .cancelled, deliveryState: progress?.delivery?.state, recoveryState: .none,
                reasonCode: nil, retryAt: nil, terminalReceipt: .init(outcome: .cancelled, receiptSHA256: receipt.receiptSHA256, recordedAt: receipt.recordedAt))
        }
        if let cancelled {
            return .init(acceptance: acceptance, state: .cancelRequested, deliveryState: progress?.delivery?.state,
                recoveryState: cancelled.blocked ? .blocked : (cancelled.reason == "provider_outcome_unknown" ? .uncertain : .pending),
                reasonCode: cancelled.reason, retryAt: cancelled.retryAt, terminalReceipt: nil)
        }
        let activation = try sourceActivationUnlocked(operationID: acceptance.operationID, allowTerminalRun: true, connection: connection)
        if let resumed = activation?.resumption {
            guard let activation, try sourceResumptionEvidenceUnlocked(activation.receipt, connection: connection) == resumed else {
                throw ContinuityOperationControlError.integrityFailure
            }
            return .init(acceptance: acceptance, state: .resumed, deliveryState: progress?.delivery?.state, recoveryState: .none,
                reasonCode: nil, retryAt: nil, terminalReceipt: .init(outcome: .resumed, receiptSHA256: resumed.receiptSHA256, recordedAt: resumed.recordedAt))
        }
        var state: ContinuityOperationState = activation?.sealedChecksum == nil ? .accepted : .predecessorSealed
        if let canonical = progress?.canonical {
            guard canonical.envelope.acceptance == acceptance,
                  try ContinuitySourceBootstrapOperation.checksum(envelope: canonical.envelope, state: canonical.state,
                    attempt: canonical.attempt, createdAt: canonical.createdAt, updatedAt: canonical.updatedAt,
                    successorSessionID: canonical.successorSessionID, successorProviderResponseID: canonical.successorProviderResponseID,
                    retrievalProofSHA256: canonical.retrievalProofSHA256, acknowledgementProofSHA256: canonical.acknowledgementProofSHA256,
                    activationReceiptSHA256: canonical.activationReceiptSHA256, resumedReceiptSHA256: canonical.resumedReceiptSHA256) == canonical.stateChecksum else {
                throw ContinuityOperationControlError.integrityFailure
            }
            switch canonical.state {
            case .checkpointPersisted: state = .handoffCommitted
            case .successorRequested, .successorCreated: state = .successorRequested
            case .successorBootstrapping: state = .successorBootstrapping
            case .successorAcknowledged:
                if let activation {
                    guard canonical.stateChecksum == activation.receipt.acknowledgedStateChecksum else { throw ContinuityOperationControlError.integrityFailure }
                } else { _ = try validatedSourceAcknowledgementUnlocked(canonical, acceptance: acceptance, connection: connection) }
                state = .successorAcknowledged
            case .predecessorSealed:
                guard let activation, canonical.activationReceiptSHA256 == activation.receipt.receiptSHA256,
                      canonical.sealedStateChecksum == activation.sealedChecksum else { throw ContinuityOperationControlError.integrityFailure }
                state = .predecessorSealed
            default: throw ContinuityOperationControlError.integrityFailure
            }
        }
        let recovery = try connection.first("SELECT recovery_error_code,recovery_retry_at,finalization_retry_at,recovery_quarantined FROM continuity_ingress_holds WHERE operation_id=?",
            bindings: [.text(acceptance.operationID.uuidString.lowercased())]) {
                (try $0.strictText(0, maximumBytes: 64), try $0.strictText(1, maximumBytes: 128), try $0.strictText(2, maximumBytes: 128), $0.int64(3))
            }
        return .init(acceptance: acceptance, state: recovery?.3 == 1 ? .blocked : state, deliveryState: progress?.delivery?.state,
            recoveryState: recovery?.3 == 1 ? .blocked : (progress == nil ? .uncertain : .pending),
            reasonCode: recovery?.0, retryAt: recovery?.2 ?? recovery?.1, terminalReceipt: nil)
    }

    private static let continuityCancellationMetadataQuery = """
        SELECT rowid,operation_id,run_id,project_id,project_generation,task_id,request_sha256 FROM continuity_operation_cancellations
        """
    private static func decodeContinuityCancellationReference(_ row: ControlPlaneSQLiteRow) throws -> ContinuityOperationCancellationReference {
        guard row.int64(0) > 0, let operation = try row.strictText(1, maximumBytes: 36).flatMap(UUID.init(uuidString:)),
              let run = try row.strictText(2, maximumBytes: 36).flatMap(UUID.init(uuidString:)),
              let project = try row.strictText(3, maximumBytes: 36).flatMap(UUID.init(uuidString:)), row.int64(4) > 0,
              let task = try row.strictText(5, maximumBytes: 36).flatMap(UUID.init(uuidString:)),
              let sha = try row.strictText(6, maximumBytes: 64), sha.count == 64,
              sha.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw ContinuityOperationControlError.integrityFailure }
        return .init(rowID: row.int64(0), operationID: operation, runID: RunID(run), projectID: ProjectID(project),
            projectGeneration: ProjectGeneration(UInt64(row.int64(4))), taskID: task, requestSHA256: sha)
    }

    private func continuityCancellationMetadataAuthorityUnlocked(_ reference: ContinuityOperationCancellationReference,
        connection: ControlPlaneSQLiteConnection) throws -> ContinuityTaskAuthorizationRecord {
        guard let actual = try connection.first(Self.continuityCancellationMetadataQuery + " WHERE rowid=? AND operation_id=?",
            bindings: [.int64(reference.rowID), .text(reference.operationID.uuidString.lowercased())], map: Self.decodeContinuityCancellationReference),
              actual == reference else { throw ContinuityOperationControlError.notFound }
        _ = try requiredActiveProjectUnlocked(reference.projectID, generation: reference.projectGeneration, connection: connection)
        guard let retained = try continuityTaskUnlocked(reference.taskID, connection: connection) else { throw ContinuityOperationControlError.notFound }
        let task = try validatedContinuityTaskUnlocked(retained.authorization, allowTerminalRun: true, connection: connection)
        guard task.authorization.projectID == reference.projectID, task.authorization.projectGeneration == reference.projectGeneration,
              task.runID == reference.runID else { throw ContinuityOperationControlError.notFound }
        guard let run = try autonomousRunUnlocked(reference.runID, connection: connection), run.activeOperationID == reference.operationID else {
            throw ContinuityOperationControlError.conflict
        }
        return task
    }

    private func continuityCancellationClaimUnlocked(_ reference: ContinuityOperationCancellationReference, lease: RunLease,
        connection: ControlPlaneSQLiteConnection) throws -> ContinuityOperationCancellationClaim {
        let task = try continuityCancellationMetadataAuthorityUnlocked(reference, connection: connection)
        guard lease.runID == reference.runID else { throw AutonomyError.staleLease }
        try verifyRunLeaseUnlocked(lease, timestamp: ISO8601.string(from: clock.now()), connection: connection)
        let acceptance = try ownedContinuityOperationUnlocked(reference.operationID, task: task, connection: connection)
        guard let cancellation = try continuityCancellationUnlocked(acceptance, connection: connection),
              cancellation.request.requestSHA256 == reference.requestSHA256 else { throw ContinuityOperationControlError.integrityFailure }
        return .init(reference: reference, request: cancellation.request)
    }

    private func requireContinuityOperationNotCancelledUnlocked(_ operationID: UUID, connection: ControlPlaneSQLiteConnection) throws {
        guard try connection.scalarInt("SELECT COUNT(*) FROM continuity_operation_cancellations WHERE operation_id=?",
            bindings: [.text(operationID.uuidString.lowercased())]) == 0 else { throw ContinuityOperationControlError.cancellationRequested }
    }

    private func validatedContinuityCallerUnlocked(
        context: ToolInvocationContext, owner: ProjectBindingOwner,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ProjectContextBinding {
        try Self.validate(owner)
        try Self.validate(context.projectGeneration)
        try Self.validate(context.authorizationScope)
        guard [.mcpClient, .providerSession, .runtimeJob].contains(owner.kind) else {
            throw ContinuityTaskAuthorizationError.taskCorrelationRequired
        }
        _ = try requiredActiveProjectUnlocked(context.projectID, generation: context.projectGeneration, connection: connection)
        guard let binding = try bindingUnlocked(owner: owner, includeInactive: false, connection: connection),
              binding.projectID == context.projectID, binding.projectGeneration == context.projectGeneration,
              binding.runID == context.runID, binding.authorizationScope == context.authorizationScope,
              Self.owner(owner, matches: context) else {
            throw ContinuityTaskAuthorizationError.authorityMismatch
        }
        try requireActiveProviderSessionUnlocked(owner: owner, binding: binding, connection: connection)
        return binding
    }

    private static func requireContinuityScope(_ requested: ToolAuthorizationScope,
                                               within granted: ToolAuthorizationScope, projectRoot: URL) throws {
        try validate(requested)
        try validate(granted)
        guard requested.canonicalRoots.allSatisfy({ root in
            contains(root, root: projectRoot) && granted.canonicalRoots.contains { contains(root, root: $0) }
        }), requested.writableRoots.allSatisfy({ root in
            granted.writableRoots.contains { contains(root, root: $0) }
        }), (!requested.networkAllowed || granted.networkAllowed),
        requested.maximumInlineOutputBytes <= granted.maximumInlineOutputBytes,
        granted.allowedTools.contains("*") || requested.allowedTools.isSubset(of: granted.allowedTools) else {
            throw ContinuityTaskAuthorizationError.authorityMismatch
        }
    }

    private func continuityTaskUnlocked(_ taskID: UUID, connection: ControlPlaneSQLiteConnection) throws -> ContinuityTaskAuthorizationRecord? {
        try connection.first(
            """
            SELECT task_id,project_id,project_generation,source_binding_id,assignment_id,assignment_sha256,
                   assignment_json,assignment_snapshot_sha256,authorization_json,authorization_sha256,
                   state,revision,run_id,created_at,revoked_at
            FROM continuity_task_authorizations WHERE task_id=? LIMIT 1
            """,
            bindings: [.text(taskID.uuidString.lowercased())], map: Self.decodeContinuityTask)
    }

    private struct StoredSourceActivation {
        let receipt: ContinuitySourceActivationReceipt
        let sealedChecksum: String?
        let resumption: ContinuitySourceResumptionReceipt?
    }

    private func sourceActivationUnlocked(operationID: UUID, allowTerminalRun: Bool = false, connection: ControlPlaneSQLiteConnection) throws -> StoredSourceActivation? {
        // Authenticate metadata before materializing any immutable source payload.
        guard let metadata = try connection.first("SELECT task_id,run_id,project_id,project_generation FROM continuity_source_activations WHERE operation_id=?",
            bindings: [.text(operationID.uuidString.lowercased())], map: {
                (try $0.strictText(0, maximumBytes: 36), try $0.strictText(1, maximumBytes: 36),
                 try $0.strictText(2, maximumBytes: 36), $0.int64(3))
            }) else { return nil }
        guard let taskID = metadata.0.flatMap(UUID.init(uuidString:)), let task = try continuityTaskUnlocked(taskID, connection: connection),
              task.runID?.description == metadata.1, task.authorization.projectID.description == metadata.2,
              metadata.3 > 0, task.authorization.projectGeneration.rawValue == UInt64(metadata.3) else {
            throw ContinuitySourceActivationError.proofRequired
        }
        _ = try validatedContinuityTaskUnlocked(task.authorization, allowTerminalRun: allowTerminalRun, connection: connection)
        return try connection.first("""
            SELECT envelope_json,envelope_sha256,receipt_json,receipt_sha256,sealed_checksum,resumption_json,resumption_sha256,candidate_id
            FROM continuity_source_activations WHERE operation_id=?
            """, bindings: [.text(operationID.uuidString.lowercased())]) { row in
                guard let envelopeJSON = try row.strictText(0, maximumBytes: 524_288),
                      let envelopeSHA = try row.strictText(1, maximumBytes: 64),
                      let receiptJSON = try row.strictText(2, maximumBytes: ContinuitySourceActivationReceipt.maximumStoredBytes),
                      let receiptSHA = try row.strictText(3, maximumBytes: 64),
                      JSONSupport.sha256Hex(Data(envelopeJSON.utf8)) == envelopeSHA,
                      JSONSupport.sha256Hex(Data(receiptJSON.utf8)) == receiptSHA else { throw ContinuitySourceActivationError.proofRequired }
                let envelope = try ContinuitySourceBootstrapEnvelope.storedSnapshot(from: Data(envelopeJSON.utf8))
                let receipt = try ContinuitySourceActivationReceipt.storedSnapshot(from: Data(receiptJSON.utf8), envelope: envelope)
                guard receipt.operationID == operationID, receipt.authorization == task.authorization, receipt.runID == task.runID,
                      receipt.candidateID.uuidString.lowercased() == (try row.strictText(7, maximumBytes: 36)) else {
                    throw ContinuitySourceActivationError.proofRequired
                }
                let sealed = try row.strictText(4, maximumBytes: 64)
                if let sealed, sealed.count != 64 || !sealed.allSatisfy({ "0123456789abcdef".contains($0) }) {
                    throw ContinuitySourceActivationError.proofRequired
                }
                let resumedJSON = try row.strictText(5, maximumBytes: ContinuitySourceResumptionReceipt.maximumStoredBytes)
                let resumedSHA = try row.strictText(6, maximumBytes: 64)
                guard (resumedJSON == nil) == (resumedSHA == nil) else { throw ContinuitySourceActivationError.proofRequired }
                let resumption: ContinuitySourceResumptionReceipt?
                if let resumedJSON {
                    guard sealed != nil, JSONSupport.sha256Hex(Data(resumedJSON.utf8)) == resumedSHA else { throw ContinuitySourceActivationError.proofRequired }
                    resumption = try .storedSnapshot(from: Data(resumedJSON.utf8), activationReceipt: receipt)
                } else { resumption = nil }
                return .init(receipt: receipt, sealedChecksum: sealed, resumption: resumption)
            }
    }

    private func validateSourceActivationUnlocked(_ receipt: ContinuitySourceActivationReceipt, lease: RunLease,
        connection: ControlPlaneSQLiteConnection) throws {
        try requireContinuityOperationNotCancelledUnlocked(receipt.operationID, connection: connection)
        guard lease.runID == receipt.runID else { throw AutonomyError.staleLease }
        try verifyRunLeaseUnlocked(lease, timestamp: ISO8601.string(from: clock.now()), connection: connection)
        guard let stored = try sourceActivationUnlocked(operationID: receipt.operationID, connection: connection), stored.receipt == receipt,
              try acceptanceForOperationUnlocked(receipt.operationID, connection: connection) == receipt.acceptance,
              let run = try autonomousRunUnlocked(receipt.runID, connection: connection), !run.state.isTerminal, run.state != .cancelRequested,
              run.projectID == receipt.authorization.projectID, run.projectGeneration == receipt.authorization.projectGeneration,
              run.activeSessionID == receipt.candidateID.uuidString.lowercased(),
              (run.activeOperationID == receipt.operationID || (run.activeOperationID == nil && stored.resumption != nil)),
              let candidate = try providerSessionRecordUnlocked(receipt.candidateID.uuidString.lowercased(), connection: connection),
              candidate.accepted, candidate.status == .active, candidate.runID == receipt.runID,
              candidate.operationID == receipt.operationID, candidate.handoffID == receipt.envelope.handoffID,
              candidate.handoffSHA256 == receipt.envelope.envelopeSHA256,
              candidate.providerResponseID == receipt.acknowledgementProviderResponseID,
              candidate.bootstrapNonceSHA256 == JSONSupport.sha256Hex(Data(receipt.envelope.bootstrapNonce.uuidString.lowercased().utf8)),
              try connection.scalarInt("""
                SELECT COUNT(*) FROM continuity_source_task_fences WHERE source_binding_id=? AND task_id=? AND operation_id=?
                  AND receipt_sha256=? AND state='accepted' AND activation_receipt_sha256=?
                """, bindings: [.text(receipt.authorization.sourceBindingID.uuidString.lowercased()),
                    .text(receipt.authorization.taskID.uuidString.lowercased()), .text(receipt.operationID.uuidString.lowercased()),
                    .text(receipt.acceptance.receiptSHA256), .text(receipt.receiptSHA256)]) == 1,
              let turn = try providerTurnUnlocked(receipt.continuationTurnID, connection: connection),
              turn.intent.runID == receipt.runID, turn.intent.operationID == receipt.operationID,
              turn.intent.sessionID == receipt.candidateID.uuidString.lowercased(), turn.intent.kind == .automaticContinuation,
              turn.intent.previousResponseID == receipt.acknowledgementProviderResponseID,
              turn.intent.inputSHA256 == receipt.continuationInputSHA256,
              turn.intent.idempotencyKey == receipt.continuationIdempotencyKey else { throw ContinuitySourceActivationError.proofRequired }
        let expectedHold = stored.sealedChecksum == nil ? "awaiting_bootstrap" : "activated"
        guard try connection.scalarInt("SELECT COUNT(*) FROM continuity_ingress_holds WHERE operation_id=? AND run_id=? AND state=?",
            bindings: [.text(receipt.operationID.uuidString.lowercased()), .text(receipt.runID.description), .text(expectedHold)]) == 1 else {
            throw ContinuitySourceActivationError.proofRequired
        }
        if let resumed = stored.resumption {
            guard try sourceResumptionEvidenceUnlocked(receipt, connection: connection) == resumed else { throw ContinuitySourceActivationError.proofRequired }
        }
    }

    private func requireSourceEffectsReconciledUnlocked(runID: RunID, operationID: UUID,
        connection: ControlPlaneSQLiteConnection) throws {
        guard try connection.scalarInt("SELECT COUNT(*) FROM tool_invocations WHERE run_id=? AND state IN ('intent','executing','ambiguous')",
                bindings: [.text(runID.description)]) == 0,
              try connection.scalarInt("SELECT COUNT(*) FROM execution_jobs WHERE run_id=? AND state IN ('queued','running','cancelling')",
                bindings: [.text(runID.description)]) == 0,
              try connection.scalarInt("SELECT COUNT(*) FROM provider_turns WHERE run_id=? AND state IN ('intent','submitted','streaming','ambiguous','retry_wait') AND (operation_id IS NULL OR operation_id<>?)",
                bindings: [.text(runID.description), .text(operationID.uuidString.lowercased())]) == 0 else {
            throw ContinuitySourceActivationError.unresolvedEffects
        }
    }

    private func sourceResumptionEvidenceUnlocked(_ activation: ContinuitySourceActivationReceipt,
        connection: ControlPlaneSQLiteConnection) throws -> ContinuitySourceResumptionReceipt? {
        guard let automatic = try providerTurnUnlocked(activation.continuationTurnID, connection: connection), automatic.state == .completed,
              let responseID = automatic.providerResponseID, !responseID.isEmpty,
              automatic.providerRequestID?.isEmpty == false else { return nil }
        guard automatic.intent.kind == .automaticContinuation, automatic.intent.operationID == activation.operationID,
              automatic.intent.runID == activation.runID, automatic.intent.sessionID == activation.candidateID.uuidString.lowercased(),
              automatic.intent.projectID == activation.authorization.projectID,
              automatic.intent.projectGeneration == activation.authorization.projectGeneration,
              automatic.intent.inputSHA256 == activation.continuationInputSHA256,
              automatic.intent.previousResponseID == activation.acknowledgementProviderResponseID else { throw ContinuitySourceActivationError.proofRequired }
        let invocations = try connection.all(Self.toolInvocationSelect + " WHERE turn_id=? ORDER BY rowid LIMIT 257",
            bindings: [.text(activation.continuationTurnID.uuidString.lowercased())]) { row in
                // Bound every legacy text column before its ordinary decoder can allocate it.
                for index in Int32(0)...Int32(18) where index != 5 { _ = try row.strictText(index, maximumBytes: index == 14 ? 65_536 : 4_096) }
                return try Self.decodeToolInvocation(row)
            }
        guard invocations.count <= 256 else { throw ContinuitySourceActivationError.proofRequired }
        guard !invocations.isEmpty, invocations.allSatisfy({ $0.state == .completed }) else { return nil }
        var outputs: [[String: Any]] = [], retainedBytes = 0
        var successful: (ToolInvocationRecord, Data)?
        for invocation in invocations {
            guard invocation.runID == activation.runID, invocation.sessionID == automatic.intent.sessionID,
                  invocation.projectID == activation.authorization.projectID,
                  invocation.projectGeneration == activation.authorization.projectGeneration,
                  activation.authorization.authorizationScope.allowedTools.contains(invocation.toolName),
                  let summary = invocation.resultSummary, let resultSHA = invocation.resultSHA256,
                  JSONSupport.sha256Hex(Data(summary.utf8)) == resultSHA,
                  let result = try JSONSerialization.jsonObject(with: Data(summary.utf8)) as? [String: Any],
                  let payload = result["payload"] as? [String: Any], result["ok"] is Bool, result["is_error"] is Bool else {
                throw ContinuitySourceActivationError.proofRequired
            }
            retainedBytes += summary.utf8.count
            guard retainedBytes <= 262_144 else { throw ContinuitySourceActivationError.proofRequired }
            let output = try JSONSupport.canonicalJSON(payload)
            outputs.append(["type": "function_call_output", "call_id": invocation.providerCallID, "output": output])
            if successful == nil, !["context_get", "forge_continuity_ack"].contains(invocation.toolName),
               result["ok"] as? Bool == true, result["is_error"] as? Bool == false {
                successful = (invocation, Data(summary.utf8))
            }
        }
        guard let successful else { return nil }
        let inputSHA = JSONSupport.sha256Hex(try ForgeJSONCanonicalizationV1.data(from: outputs))
        let followingIDs = try connection.all("""
            SELECT turn_id FROM provider_turns WHERE run_id=? AND operation_id=? AND session_id=? AND request_kind='tool_continuation'
              AND previous_response_id=? AND state='completed' AND input_sha256=? ORDER BY rowid LIMIT 2
            """, bindings: [.text(activation.runID.description), .text(activation.operationID.uuidString.lowercased()),
                .text(automatic.intent.sessionID), .text(responseID), .text(inputSHA)], map: { try $0.strictText(0, maximumBytes: 36) })
        guard !followingIDs.isEmpty else { return nil }
        guard followingIDs.count == 1, let id = followingIDs[0].flatMap(UUID.init(uuidString:)),
              let following = try providerTurnUnlocked(id, connection: connection),
              following.intent.projectID == activation.authorization.projectID,
              following.intent.projectGeneration == activation.authorization.projectGeneration,
              let followingResponseID = following.providerResponseID, !followingResponseID.isEmpty,
              following.providerRequestID?.isEmpty == false else { throw ContinuitySourceActivationError.proofRequired }
        return try ContinuitySourceResumptionReceipt(activationReceipt: activation, providerResponseID: responseID,
            toolContinuationTurnID: id, toolContinuationProviderResponseID: followingResponseID, toolOutputsInputSHA256: inputSHA,
            toolInvocationID: successful.0.invocationID, toolName: successful.0.toolName,
            canonicalToolResultJSON: successful.1, recordedAt: following.updatedAt)
    }

    private struct RecoveryMetadata {
        let reference: ContinuityBootstrapRecoveryReference
        let keySHA256: String
        let attempts: Int
        let startedAt: String?
        let deadline: String?
        let retryAt: String?
        let claimID: UUID?
        let leaseOwner: String?
        let leaseEpoch: UInt64?
        let error: ContinuityBootstrapRecoveryFailure?
        let quarantined: Bool
        let acknowledgedSHA256: String?
        let holdState: String
        let claimPhase: ContinuitySourceRecoveryPhase?
    }

    private static let recoveryMetadataQuery = """
        SELECT h.rowid,h.operation_id,h.run_id,a.project_id,a.project_generation,a.task_id,a.receipt_sha256,a.key_sha256,
          CASE WHEN h.recovery_ack_sha256 IS NULL THEN h.recovery_attempts ELSE h.finalization_attempts END,
          CASE WHEN h.recovery_ack_sha256 IS NULL THEN h.recovery_started_at ELSE h.finalization_started_at END,
          CASE WHEN h.recovery_ack_sha256 IS NULL THEN h.recovery_deadline ELSE h.finalization_deadline END,
          CASE WHEN h.recovery_ack_sha256 IS NULL THEN h.recovery_retry_at ELSE h.finalization_retry_at END,h.recovery_claim_id,
          h.recovery_lease_owner,h.recovery_lease_epoch,h.recovery_error_code,h.recovery_quarantined,h.recovery_ack_sha256,h.state,h.recovery_claim_phase
        FROM continuity_ingress_holds h LEFT JOIN continuity_ingress_acceptances a
          ON a.operation_id=h.operation_id AND a.run_id=h.run_id
        """

    private static func decodeRecoveryMetadata(_ row: ControlPlaneSQLiteRow) throws -> RecoveryMetadata {
        func uuid(_ index: Int32) throws -> UUID {
            guard let text = try row.strictText(index, maximumBytes: 36), let uuid = UUID(uuidString: text),
                  uuid.uuidString.lowercased() == text else { throw ContinuityBootstrapRecoveryError.quarantined }
            return uuid
        }
        func digest(_ index: Int32, required: Bool = true) throws -> String? {
            let text = try row.strictText(index, maximumBytes: 64)
            guard let text else {
                if required { throw ContinuityBootstrapRecoveryError.quarantined }
                return nil
            }
            guard text.count == 64, text.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw ContinuityBootstrapRecoveryError.quarantined
            }
            return text
        }
        func date(_ index: Int32) throws -> String? {
            let text = try row.strictText(index, maximumBytes: 128)
            if let text, ISO8601.date(from: text) == nil { throw ContinuityBootstrapRecoveryError.quarantined }
            return text
        }
        guard row.int64(0) > 0, sqlite3_column_type(row.statement, 4) == SQLITE_INTEGER, row.int64(4) > 0,
              sqlite3_column_type(row.statement, 8) == SQLITE_INTEGER,
              (0...Int64(ContinuityBootstrapRecoveryLimits.maximumAttempts)).contains(row.int64(8)),
              sqlite3_column_type(row.statement, 16) == SQLITE_INTEGER, [0,1].contains(row.int64(16)),
              let holdState = try row.strictText(18, maximumBytes: 32),
              ["awaiting_bootstrap", "cancelled", "activated"].contains(holdState) else {
            throw ContinuityBootstrapRecoveryError.quarantined
        }
        let reference = ContinuityBootstrapRecoveryReference(rowID: row.int64(0), operationID: try uuid(1),
            runID: RunID(try uuid(2)), projectID: ProjectID(try uuid(3)), projectGeneration: ProjectGeneration(UInt64(row.int64(4))),
            taskID: try uuid(5), receiptSHA256: try digest(6)!, phase: row.isNull(17) ? .bootstrap : .activation)
        let started = try date(9), deadline = try date(10), retry = try date(11)
        let claim: UUID? = row.isNull(12) ? nil : try uuid(12)
        let owner = try row.strictText(13, maximumBytes: 512)
        let epoch: UInt64? = row.isNull(14) ? nil : UInt64(max(0, row.int64(14)))
        let rawError = try row.strictText(15, maximumBytes: 64)
        let error = rawError.flatMap(ContinuityBootstrapRecoveryFailure.init(rawValue:))
        let rawPhase = try row.strictText(19, maximumBytes: 32)
        let phase = rawPhase.flatMap(ContinuitySourceRecoveryPhase.init(rawValue:))
        guard (started == nil) == (deadline == nil), row.int64(8) == 0 || started != nil,
              started == nil || ISO8601.string(from: ISO8601.date(from: started!)!.addingTimeInterval(ContinuityBootstrapRecoveryLimits.retryWindow)) == deadline,
              claim == nil ? (owner == nil && epoch == nil) : (owner?.isEmpty == false && (epoch ?? 0) > 0),
              rawError == nil || error != nil,
              claim == nil ? rawPhase == nil : phase == reference.phase,
              epoch == nil || sqlite3_column_type(row.statement, 14) == SQLITE_INTEGER else {
            throw ContinuityBootstrapRecoveryError.quarantined
        }
        return .init(reference: reference, keySHA256: try digest(7)!, attempts: Int(row.int64(8)), startedAt: started,
            deadline: deadline, retryAt: retry, claimID: claim, leaseOwner: owner, leaseEpoch: epoch, error: error,
            quarantined: row.int64(16) == 1, acknowledgedSHA256: try digest(17, required: false), holdState: holdState, claimPhase: phase)
    }

    private func requiredRecoveryMetadataUnlocked(_ reference: ContinuityBootstrapRecoveryReference,
        connection: ControlPlaneSQLiteConnection) throws -> RecoveryMetadata {
        guard reference.rowID > 0, let row = try connection.first(Self.recoveryMetadataQuery + " WHERE h.rowid=?",
            bindings: [.int64(reference.rowID)], map: Self.decodeRecoveryMetadata), row.reference == reference else {
            throw ContinuityBootstrapRecoveryError.claimConflict
        }
        return row
    }

    private func requireRecoveryDueUnlocked(_ row: RecoveryMetadata) throws {
        guard !row.quarantined else { throw ContinuityBootstrapRecoveryError.quarantined }
        guard row.holdState == "awaiting_bootstrap" else { throw ContinuityBootstrapRecoveryError.claimConflict }
        guard row.attempts < ContinuityBootstrapRecoveryLimits.maximumAttempts,
              row.deadline == nil || (ISO8601.date(from: row.deadline!) ?? .distantPast) > clock.now() else {
            throw ContinuityBootstrapRecoveryError.exhausted
        }
        guard row.retryAt == nil || (ISO8601.date(from: row.retryAt!) ?? .distantFuture) <= clock.now() else {
            throw ContinuityBootstrapRecoveryError.notDue
        }
    }

    private func recoveryIsDueUnlocked(_ row: RecoveryMetadata, connection: ControlPlaneSQLiteConnection) throws -> Bool {
        do { try requireRecoveryDueUnlocked(row) } catch is ContinuityBootstrapRecoveryError { return false }
        return try connection.scalarInt("""
            SELECT COUNT(*) FROM autonomous_runs r JOIN control_projects p ON p.project_id=r.project_id
              JOIN continuity_task_authorizations t ON t.task_id=? AND t.run_id=r.run_id
            WHERE r.run_id=? AND r.state='awaiting_bootstrap' AND r.active_operation_id=?
              AND r.project_id=? AND r.project_generation=? AND p.generation=r.project_generation
              AND p.lifecycle_state='active' AND t.state='active' AND t.project_id=r.project_id
              AND t.project_generation=r.project_generation
            """, bindings: [.text(row.reference.taskID.uuidString.lowercased()), .text(row.reference.runID.description),
                .text(row.reference.operationID.uuidString.lowercased()), .text(row.reference.projectID.description),
                .int64(Int64(row.reference.projectGeneration.rawValue))]) == 1
    }

    private func validateRecoveryTaskUnlocked(_ row: RecoveryMetadata,
        connection: ControlPlaneSQLiteConnection) throws -> ContinuityTaskAuthorizationRecord {
        guard row.holdState == "awaiting_bootstrap", let task = try continuityTaskUnlocked(row.reference.taskID, connection: connection),
              task.runID == row.reference.runID, task.authorization.projectID == row.reference.projectID,
              task.authorization.projectGeneration == row.reference.projectGeneration,
              let run = try autonomousRunUnlocked(row.reference.runID, connection: connection),
              run.state == .awaitingBootstrap, run.activeOperationID == row.reference.operationID else {
            throw ContinuityBootstrapRecoveryError.claimConflict
        }
        return try validatedContinuityTaskUnlocked(task.authorization, connection: connection)
    }

    private func validateRecoveryClaimUnlocked(_ claim: ContinuityBootstrapRecoveryClaim, lease: RunLease,
        connection: ControlPlaneSQLiteConnection, allowAcknowledged: Bool = false) throws -> RecoveryMetadata {
        let row = try requiredRecoveryMetadataUnlocked(claim.reference, connection: connection)
        _ = try validateRecoveryTaskUnlocked(row, connection: connection)
        guard !row.quarantined, allowAcknowledged || row.reference.phase == claim.reference.phase,
              row.claimPhase == claim.reference.phase,
              row.claimID == claim.claimID, row.leaseOwner == lease.ownerID, row.leaseEpoch == lease.epoch,
              row.attempts == claim.attempt, row.deadline == claim.retryDeadline,
              claim.acceptance.receiptSHA256 == claim.reference.receiptSHA256,
              claim.acceptance.operationID == claim.reference.operationID else {
            throw ContinuityBootstrapRecoveryError.claimConflict
        }
        try validateBootstrapReceiptUnlocked(claim.acceptance, lease: lease, connection: connection)
        return row
    }

    private func quarantineRecoveryUnlocked(rowID: Int64, connection: ControlPlaneSQLiteConnection) throws {
        try connection.execute("""
            UPDATE continuity_ingress_holds SET recovery_quarantined=1,recovery_error_code='integrity_failure',updated_at=?
            WHERE rowid=? AND state='awaiting_bootstrap'
            """, bindings: [.text(ISO8601.string(from: clock.now())), .int64(rowID)])
    }

    private static func isRecoveryIntegrityError(_ error: Error) -> Bool {
        if let value = error as? ContinuityIngressError, case .integrityFailure = value { return true }
        if let value = error as? ProjectContextError, case .integrityFailure = value { return true }
        if error is DecodingError { return true }
        return false
    }

    private struct SourceAcknowledgementEvidence {
        let grant: ContinuityBootstrapGrant
        let retrieval: ContinuityBootstrapRetrievalProof
        let ackTurnID: UUID
        let ack: ProviderTurn
    }

    private func validateRecoveryAcknowledgementUnlocked(_ operation: ContinuitySourceBootstrapOperation,
        claim: ContinuityBootstrapRecoveryClaim, connection: ControlPlaneSQLiteConnection) throws {
        _ = try validatedSourceAcknowledgementUnlocked(operation, acceptance: claim.acceptance, connection: connection)
    }

    private func validatedSourceAcknowledgementUnlocked(_ operation: ContinuitySourceBootstrapOperation,
        acceptance: ContinuityIngressAcceptanceReceipt, connection: ControlPlaneSQLiteConnection) throws -> SourceAcknowledgementEvidence {
        guard operation.envelope.acceptance == acceptance, operation.state == .successorAcknowledged,
              operation.createdAt.utf8.count <= 128, operation.updatedAt.utf8.count <= 128,
              ISO8601.date(from: operation.createdAt) != nil, ISO8601.date(from: operation.updatedAt) != nil,
              let candidateID = operation.successorSessionID, let responseID = operation.successorProviderResponseID,
              let retrievalSHA = operation.retrievalProofSHA256, let ackSHA = operation.acknowledgementProofSHA256,
              try ContinuitySourceBootstrapOperation.checksum(envelope: operation.envelope, state: operation.state,
                attempt: operation.attempt, createdAt: operation.createdAt, updatedAt: operation.updatedAt,
                successorSessionID: candidateID, successorProviderResponseID: responseID,
                retrievalProofSHA256: retrievalSHA, acknowledgementProofSHA256: ackSHA) == operation.stateChecksum,
              let grant = try bootstrapGrantUnlocked(candidateID: candidateID, envelope: operation.envelope, connection: connection),
              let candidate = try providerSessionIdentityUnlocked(grant.sessionID, connection: connection),
              candidate.status == .candidate, !candidate.accepted, candidate.runID == acceptance.runID,
              candidate.projectID == acceptance.authorization.projectID, candidate.projectGeneration == acceptance.authorization.projectGeneration,
              candidate.operationID == acceptance.operationID, candidate.handoffSHA256 == operation.envelope.envelopeSHA256,
              let proof = try bootstrapRetrievalProofUnlocked(grant: grant, connection: connection), proof.proofSHA256 == retrievalSHA,
              let invocation = try toolInvocationUnlocked(proof.toolInvocationID, connection: connection),
              invocation.state == .completed, invocation.turnID == proof.providerTurnID,
              invocation.runID == acceptance.runID, invocation.sessionID == grant.sessionID,
              invocation.providerCallID == proof.providerCallID, invocation.toolName == "context_get", invocation.replayClass == .readOnly,
              invocation.resultSHA256 == proof.toolResultSHA256,
              invocation.resultSummary == String(data: proof.canonicalToolResultJSON, encoding: .utf8),
              let root = try bootstrapProviderResultUnlocked(grant: grant, turnID: proof.providerTurnID, connection: connection),
              root.previousResponseID == nil, root.responseID == proof.providerResponseID,
              let rootCall = root.toolCalls.first, rootCall.callID == proof.providerCallID,
              try bootstrapCallSHA256(rootCall) == invocation.argumentsSHA256 else {
            throw ContinuityIngressError.integrityFailure("canonical acknowledgment lacks matching durable source recovery proof")
        }
        try validateExactBootstrapCall(rootCall, source: acceptance.sourceIdentity)
        let ids = try connection.all("""
            SELECT t.turn_id FROM provider_turns t JOIN continuity_bootstrap_provider_results b ON b.turn_id=t.turn_id
            WHERE b.grant_id=? AND t.previous_response_id=? AND t.state='completed' LIMIT 3
            """, bindings: [.text(grant.grantID.uuidString.lowercased()), .text(root.responseID)]) { row in
                try row.strictText(0, maximumBytes: 36).flatMap(UUID.init(uuidString:))
            }
        guard ids.count == 1, let id = ids.first ?? nil,
              let ack = try bootstrapProviderResultUnlocked(grant: grant, turnID: id, connection: connection),
              ack.responseID == responseID, ack.previousResponseID == root.responseID,
              let call = ack.toolCalls.first, call.name == "forge_continuity_ack",
              try bootstrapCallSHA256(call) == ackSHA else {
            throw ContinuityIngressError.integrityFailure("canonical acknowledgment lacks matching provider response")
        }
        let acknowledgement = try JSONDecoder().decode(BootstrapAcknowledgementV2.self, from: call.argumentsJSON)
        guard acknowledgement.accepted, acknowledgement.projectID == acceptance.authorization.projectID,
              acknowledgement.projectGeneration == acceptance.authorization.projectGeneration,
              acknowledgement.runID == acceptance.runID, acknowledgement.operationID == acceptance.operationID,
              acknowledgement.handoffID == operation.handoffID, acknowledgement.handoffSHA256 == operation.envelope.envelopeSHA256,
              acknowledgement.nonce == operation.bootstrapNonce.uuidString.lowercased() else {
            throw ContinuityIngressError.authorityMismatch
        }
        return .init(grant: grant, retrieval: proof, ackTurnID: id, ack: ack)
    }

    private static func hasReadOnlySourceDispatch(_ scope: ToolAuthorizationScope) -> Bool {
        scope.writableRoots.isEmpty && !scope.networkAllowed && !scope.allowedTools.isEmpty
            && scope.allowedTools.allSatisfy { $0 == "context_get" || ProductionToolReplayCatalog.classification(for: $0) == .readOnly }
    }

    /// Only native authenticated setup may retain the actual original caller.
    /// A narrower approved assignment cannot stand in for the caller's scope.
    private func retainSourceDispatchOriginUnlocked(taskID: UUID, caller: ProjectContextBinding,
        timestamp: String, existingTask: Bool = false, connection: ControlPlaneSQLiteConnection) throws {
        let scopeSHA = JSONSupport.sha256Hex(Data(try Self.scopeJSON(caller.authorizationScope).utf8))
        if let existing = try connection.first("SELECT caller_binding_id,owner_kind,owner_id,scope_sha256,invalidated FROM continuity_source_dispatch_origins WHERE task_id=?",
            bindings: [.text(taskID.uuidString.lowercased())], map: {
                (try $0.strictText(0, maximumBytes: 36), try $0.strictText(1, maximumBytes: 64),
                 try $0.strictText(2, maximumBytes: 512), try $0.strictText(3, maximumBytes: 64), $0.int64(4))
            }) {
            guard existing.0 == caller.bindingID.uuidString.lowercased(), existing.1 == caller.owner.kind.rawValue,
                  existing.2 == caller.owner.id, existing.3 == scopeSHA, existing.4 == 0 else { throw ContinuitySourceActivationError.taskIdentityUnavailable }
            return
        }
        guard !existingTask else { throw ContinuitySourceActivationError.taskIdentityUnavailable }
        guard try connection.scalarInt("SELECT COUNT(*) FROM continuity_source_dispatch_origins") < Self.maximumContinuityTaskAuthorizations else {
            throw ContinuityTaskAuthorizationError.capacityExceeded
        }
        try connection.execute("INSERT INTO continuity_source_dispatch_origins(task_id,caller_binding_id,owner_kind,owner_id,scope_sha256,issued_at) VALUES(?,?,?,?,?,?)",
            bindings: [.text(taskID.uuidString.lowercased()), .text(caller.bindingID.uuidString.lowercased()),
                .text(caller.owner.kind.rawValue), .text(caller.owner.id), .text(scopeSHA), .text(timestamp)])
    }

    private func requireSourceDispatchIdentityUnlocked(_ authorization: ContinuityIngressAuthorization,
        connection: ControlPlaneSQLiteConnection) throws {
        guard Self.hasReadOnlySourceDispatch(authorization.authorizationScope),
              let origin = try connection.first("SELECT caller_binding_id,owner_kind,owner_id,scope_sha256,invalidated FROM continuity_source_dispatch_origins WHERE task_id=?",
                bindings: [.text(authorization.taskID.uuidString.lowercased())], map: {
                    (try $0.strictText(0, maximumBytes: 36), try $0.strictText(1, maximumBytes: 64),
                     try $0.strictText(2, maximumBytes: 512), try $0.strictText(3, maximumBytes: 64), $0.int64(4))
                }), let kindText = origin.1, let kind = ProjectBindingOwnerKind(rawValue: kindText), let ownerID = origin.2,
              let caller = try bindingUnlocked(owner: .init(kind: kind, id: ownerID), includeInactive: false, connection: connection),
              origin.4 == 0, caller.bindingID.uuidString.lowercased() == origin.0, caller.projectID == authorization.projectID,
              caller.projectGeneration == authorization.projectGeneration, caller.runID == nil,
              Self.hasReadOnlySourceDispatch(caller.authorizationScope),
              JSONSupport.sha256Hex(Data(try Self.scopeJSON(caller.authorizationScope).utf8)) == origin.3 else {
            throw ContinuitySourceActivationError.taskIdentityUnavailable
        }
    }

    private func requireSourceMutationAdmissionUnlocked(_ authorization: ContinuityIngressAuthorization,
        connection: ControlPlaneSQLiteConnection) throws {
        guard try connection.scalarInt("SELECT COUNT(*) FROM native_source_requests WHERE task_id=? AND method='session_handoff'",
            bindings: [.text(authorization.taskID.uuidString.lowercased())]) == 0 else { throw NativeTaskCapabilityError.sourceFenced }
        guard try connection.scalarInt("SELECT COUNT(*) FROM continuity_source_task_fences WHERE source_binding_id=? OR task_id=?",
            bindings: [.text(authorization.sourceBindingID.uuidString.lowercased()), .text(authorization.taskID.uuidString.lowercased())]) == 0 else {
            throw ContinuitySourceActivationError.sourceFenced
        }
    }

    private func installSourceTransferFenceUnlocked(receipt: ContinuityIngressAcceptanceReceipt, timestamp: String,
        connection: ControlPlaneSQLiteConnection) throws {
        let auth = receipt.authorization
        if let existing = try connection.first("SELECT operation_id,receipt_sha256 FROM continuity_source_task_fences WHERE source_binding_id=? OR task_id=?",
            bindings: [.text(auth.sourceBindingID.uuidString.lowercased()), .text(auth.taskID.uuidString.lowercased())],
            map: { (try $0.strictText(0, maximumBytes: 36), try $0.strictText(1, maximumBytes: 64)) }) {
            guard existing.0 == receipt.operationID.uuidString.lowercased(), existing.1 == receipt.receiptSHA256 else {
                throw ContinuitySourceActivationError.sourceFenced
            }
            return
        }
        try connection.execute("""
            INSERT INTO continuity_source_task_fences(source_binding_id,task_id,project_id,project_generation,run_id,
              operation_id,receipt_sha256,state,created_at) VALUES(?,?,?,?,?,?,?,'quiescing',?)
            """, bindings: [.text(auth.sourceBindingID.uuidString.lowercased()), .text(auth.taskID.uuidString.lowercased()),
                .text(auth.projectID.description), .int64(Int64(auth.projectGeneration.rawValue)), .text(receipt.runID.description),
                .text(receipt.operationID.uuidString.lowercased()), .text(receipt.receiptSHA256), .text(timestamp)])
        // A real provider predecessor is independently fenced before any root.
        if let run = try autonomousRunUnlocked(receipt.runID, connection: connection), let predecessorID = run.activeSessionID {
            guard let predecessor = try providerSessionRecordUnlocked(predecessorID, connection: connection),
                  predecessor.runID == run.runID, predecessor.projectID == run.projectID,
                  predecessor.projectGeneration == run.projectGeneration,
                  (predecessor.status == .active && predecessor.accepted) || [.fencing,.fenced].contains(predecessor.status) else {
                throw ContinuitySourceActivationError.conflict
            }
            try connection.execute("UPDATE provider_sessions SET status='fencing',accepted=0,updated_at=? WHERE session_id=?",
                bindings: [.text(timestamp), .text(predecessorID)])
            try connection.execute("UPDATE project_bindings SET active=0,updated_at=? WHERE owner_kind='provider_session' AND owner_id=?",
                bindings: [.text(timestamp), .text(predecessorID)])
        }
    }

    private func acceptanceForOperationUnlocked(_ operationID: UUID,
        connection: ControlPlaneSQLiteConnection) throws -> ContinuityIngressAcceptanceReceipt? {
        guard let key = try connection.first("SELECT key_sha256 FROM continuity_ingress_acceptances WHERE operation_id=?",
            bindings: [.text(operationID.uuidString.lowercased())], map: { try $0.strictText(0, maximumBytes: 64) }) ?? nil else { return nil }
        return try continuityIngressAcceptanceUnlocked(operationID: operationID, keySHA256: key, connection: connection)
    }

    private func explicitStartPermitUnlocked(acceptance: ContinuityIngressAcceptanceReceipt,
        connection: ControlPlaneSQLiteConnection) throws -> ContinuityExplicitStartPermit? {
        try connection.first("SELECT receipt_sha256,permit_json,permit_sha256 FROM continuity_explicit_start_permits WHERE operation_id=?",
            bindings: [.text(acceptance.operationID.uuidString.lowercased())]) { row in
                guard try row.strictText(0, maximumBytes: 64) == acceptance.receiptSHA256,
                      let json = try row.strictText(1, maximumBytes: ContinuityExplicitStartPermit.maximumStoredBytes),
                      let sha = try row.strictText(2, maximumBytes: 64), JSONSupport.sha256Hex(Data(json.utf8)) == sha else {
                    throw ContinuitySourceActivationError.proofRequired
                }
                return try ContinuityExplicitStartPermit.storedSnapshot(from: Data(json.utf8), acceptance: acceptance)
            }
    }

    private func hasExplicitStartMetadataUnlocked(reference: ContinuityBootstrapRecoveryReference,
        task: ContinuityTaskAuthorizationRecord, connection: ControlPlaneSQLiteConnection) throws -> Bool {
        guard let row = try connection.first("SELECT receipt_sha256,permit_json,permit_sha256 FROM continuity_explicit_start_permits WHERE operation_id=?",
            bindings: [.text(reference.operationID.uuidString.lowercased())], map: {
                (try $0.strictText(0, maximumBytes: 64), try $0.strictText(1, maximumBytes: ContinuityExplicitStartPermit.maximumStoredBytes),
                 try $0.strictText(2, maximumBytes: 64))
            }) else { return false }
        guard row.0 == reference.receiptSHA256, let json = row.1, JSONSupport.sha256Hex(Data(json.utf8)) == row.2,
              let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              try ForgeJSONCanonicalizationV1.data(from: object) == Data(json.utf8),
              object["kind"] as? String == "explicit_source_start", object["schema_version"] as? Int == 1,
              object["operation_id"] as? String == reference.operationID.uuidString.lowercased(),
              object["acceptance_receipt_sha256"] as? String == reference.receiptSHA256,
              object["authorization_sha256"] as? String == JSONSupport.sha256Hex(try task.authorization.encodedJSON()),
              object["task_id"] as? String == reference.taskID.uuidString.lowercased(),
              object["source_binding_id"] as? String == task.authorization.sourceBindingID.uuidString.lowercased(),
              object["assignment_sha256"] as? String == task.authorization.assignmentSHA256 else {
            throw ContinuitySourceActivationError.proofRequired
        }
        return true
    }

    private func validateSourceStartAuthorityUnlocked(acceptance: ContinuityIngressAcceptanceReceipt,
        lease: RunLease?, policySelection: BudgetPolicySelection, connection: ControlPlaneSQLiteConnection) throws -> ContinuitySourceStartAuthority {
        try requireContinuityOperationNotCancelledUnlocked(acceptance.operationID, connection: connection)
        let task = try validatedContinuityTaskUnlocked(acceptance.authorization, connection: connection)
        guard task.runID == acceptance.runID,
              try acceptanceForOperationUnlocked(acceptance.operationID, connection: connection) == acceptance,
              let run = try autonomousRunUnlocked(acceptance.runID, connection: connection),
              run.activeOperationID == acceptance.operationID, !run.state.isTerminal, run.state != .cancelRequested else {
            throw ContinuityIngressError.authorityMismatch
        }
        if let lease {
            guard lease.runID == acceptance.runID else { throw AutonomyError.staleLease }
            try verifyRunLeaseUnlocked(lease, timestamp: ISO8601.string(from: clock.now()), connection: connection)
        }
        try ContinuityIngressAcceptanceReceipt.validatePolicy(policySelection, authorization: task.authorization)
        try requireSourceDispatchIdentityUnlocked(task.authorization, connection: connection)
        if policySelection.policy.automaticHandoffEnabled { return .automaticPolicy }
        guard let permit = try explicitStartPermitUnlocked(acceptance: acceptance, connection: connection) else {
            throw ContinuityBootstrapRecoveryError.policyDeferred
        }
        return .explicitRequest(permitSHA256: permit.permitSHA256)
    }

    private func continuityIngressAcceptanceUnlocked(operationID: UUID, keySHA256: String,
                                                      connection: ControlPlaneSQLiteConnection) throws -> ContinuityIngressAcceptanceReceipt? {
        try connection.first(
            """
            SELECT operation_id,key_sha256,run_id,task_id,project_id,project_generation,receipt_json,receipt_sha256,accepted_at
            FROM continuity_ingress_acceptances WHERE operation_id=? OR key_sha256=? LIMIT 1
            """,
            bindings: [.text(operationID.uuidString.lowercased()), .text(keySHA256)]) { row in
                guard let operation = try row.strictText(0, maximumBytes: 36),
                      let key = try row.strictText(1, maximumBytes: 64),
                      let run = try row.strictText(2, maximumBytes: 36),
                      let task = try row.strictText(3, maximumBytes: 36),
                      let project = try row.strictText(4, maximumBytes: 36), row.int64(5) > 0,
                      let json = try row.strictText(6, maximumBytes: ContinuityIngressAcceptanceReceipt.maximumBytes),
                      let sha = try row.strictText(7, maximumBytes: 64),
                      let accepted = try row.strictText(8, maximumBytes: 128) else {
                    throw ContinuityIngressError.integrityFailure("malformed acceptance row")
                }
                let data = Data(json.utf8)
                guard JSONSupport.sha256Hex(data) == sha else {
                    throw ContinuityIngressError.integrityFailure("acceptance digest mismatch")
                }
                let receipt = try ContinuityIngressAcceptanceReceipt.storedSnapshot(from: data)
                guard receipt.operationID.uuidString.lowercased() == operation, receipt.keySHA256 == key,
                      receipt.runID.description == run, receipt.authorization.taskID.uuidString.lowercased() == task,
                      receipt.authorization.projectID.description == project,
                      receipt.authorization.projectGeneration.rawValue == UInt64(row.int64(5)), receipt.acceptedAt == accepted else {
                    throw ContinuityIngressError.integrityFailure("acceptance identity columns differ from snapshot")
                }
                return receipt
            }
    }

    private func validateBootstrapReceiptUnlocked(_ receipt: ContinuityIngressAcceptanceReceipt, lease: RunLease,
                                                   connection: ControlPlaneSQLiteConnection) throws {
        guard try ContinuityIngressAcceptanceReceipt.storedSnapshot(from: receipt.canonicalReceiptJSON) == receipt,
              lease.runID == receipt.runID else { throw ContinuityIngressError.authorityMismatch }
        try requireContinuityOperationNotCancelledUnlocked(receipt.operationID, connection: connection)
        let task = try validatedContinuityTaskUnlocked(receipt.authorization, connection: connection)
        try requireSourceDispatchIdentityUnlocked(task.authorization, connection: connection)
        try verifyRunLeaseUnlocked(lease, timestamp: ISO8601.string(from: clock.now()), connection: connection)
        guard task.runID == receipt.runID,
              try continuityIngressAcceptanceUnlocked(operationID: receipt.operationID,
                keySHA256: receipt.keySHA256, connection: connection) == receipt,
              let run = try autonomousRunUnlocked(receipt.runID, connection: connection),
              run.state == .awaitingBootstrap, run.activeOperationID == receipt.operationID,
              run.projectID == receipt.authorization.projectID,
              run.projectGeneration == receipt.authorization.projectGeneration,
              try connection.scalarText("SELECT state FROM continuity_ingress_holds WHERE operation_id=? AND run_id=?",
                bindings: [.text(receipt.operationID.uuidString.lowercased()), .text(receipt.runID.description)]) == "awaiting_bootstrap" else {
            throw ContinuityIngressError.authorityMismatch
        }
    }

    private func validateBootstrapAcceptanceUnlocked(_ envelope: ContinuitySourceBootstrapEnvelope, lease: RunLease,
                                                      connection: ControlPlaneSQLiteConnection) throws {
        guard try ContinuitySourceBootstrapEnvelope.storedSnapshot(from: envelope.canonicalEnvelopeJSON) == envelope else {
            throw ContinuityIngressError.authorityMismatch
        }
        try validateBootstrapReceiptUnlocked(envelope.acceptance, lease: lease, connection: connection)
    }

    private func validateBootstrapGrantUnlocked(_ grant: ContinuityBootstrapGrant, lease: RunLease,
                                                 connection: ControlPlaneSQLiteConnection) throws {
        try validateBootstrapAcceptanceUnlocked(grant.envelope, lease: lease, connection: connection)
        try requireBootstrapRecoveryScopeUnlocked(grant.envelope, connection: connection)
        guard try bootstrapGrantUnlocked(candidateID: grant.candidateID, envelope: grant.envelope, connection: connection) == grant,
              grant.leaseOwnerID == lease.ownerID, grant.leaseEpoch == lease.epoch,
              (ISO8601.date(from: grant.expiresAt) ?? .distantPast) > clock.now() else {
            throw ContinuityIngressError.authorityMismatch
        }
        if let candidate = try providerSessionIdentityUnlocked(grant.sessionID, connection: connection) {
            let task = try validatedContinuityTaskUnlocked(grant.envelope.authorization, connection: connection)
            guard candidate.status == .candidate, !candidate.accepted, candidate.runID == grant.envelope.runID,
                  candidate.projectID == grant.envelope.authorization.projectID,
                  candidate.projectGeneration == grant.envelope.authorization.projectGeneration,
                  candidate.operationID == grant.envelope.operationID, candidate.handoffID == grant.envelope.handoffID,
                  candidate.handoffSHA256 == grant.envelope.envelopeSHA256,
                  candidate.bootstrapNonceSHA256 == JSONSupport.sha256Hex(grant.envelope.bootstrapNonce.uuidString.lowercased()),
                  candidate.predecessorSessionID == nil, candidate.providerID == task.assignment.providerID,
                  candidate.adapterID == task.assignment.adapterID, candidate.modelKey == task.assignment.modelKey else {
                throw ContinuityIngressError.authorityMismatch
            }
        }
    }

    /// The native source profile grants one manager-owned exact handoff read as
    /// part of recovery. Its approved work scope stays fs_read-only; ordinary
    /// context_get and reads of another source never receive this authority.
    private func requireBootstrapRecoveryScopeUnlocked(_ envelope: ContinuitySourceBootstrapEnvelope,
        connection: ControlPlaneSQLiteConnection) throws {
        if envelope.authorization.authorizationScope.allowedTools.contains("context_get") { return }
        guard let id = try connection.first("SELECT capability_id FROM native_task_capabilities WHERE task_id=?",
            bindings: [.text(envelope.authorization.taskID.uuidString.lowercased())], map: {
                try NativeTaskValue.uuid($0.strictText(0, maximumBytes: 36))
            }), let capability = try nativeCapabilityUnlocked(id, connection: connection) else {
            throw ContinuityIngressError.authorityMismatch
        }
        let (task, _) = try validateNativeCapabilityOwnerUnlocked(capability, taskID: envelope.authorization.taskID,
            projectID: envelope.authorization.projectID, generation: envelope.authorization.projectGeneration,
            connection: connection)
        guard task.authorization == envelope.authorization, task.runID == envelope.runID,
              task.assignment.specification.allowedTools == ["fs_read"],
              try nativeRunSourceOffsetUnlocked(envelope.runID, connection: connection) != nil else {
            throw ContinuityIngressError.authorityMismatch
        }
    }

    private func bootstrapGrantUnlocked(candidateID: UUID, envelope: ContinuitySourceBootstrapEnvelope,
                                         connection: ControlPlaneSQLiteConnection) throws -> ContinuityBootstrapGrant? {
        try connection.first("SELECT grant_id,operation_id,run_id,grant_json,grant_sha256 FROM continuity_bootstrap_grants WHERE candidate_id=?",
            bindings: [.text(candidateID.uuidString.lowercased())]) { row in
                guard let grantID = try row.strictText(0, maximumBytes: 36),
                      let operation = try row.strictText(1, maximumBytes: 36), let run = try row.strictText(2, maximumBytes: 36),
                      let json = try row.strictText(3, maximumBytes: ContinuityBootstrapGrant.maximumStoredBytes),
                      let sha = try row.strictText(4, maximumBytes: 64),
                      operation == envelope.operationID.uuidString.lowercased(), run == envelope.runID.description,
                      JSONSupport.sha256Hex(Data(json.utf8)) == sha else {
                    throw ContinuityIngressError.integrityFailure("malformed bootstrap grant row")
                }
                let value = try ContinuityBootstrapGrant.storedSnapshot(from: Data(json.utf8), envelope: envelope)
                guard value.grantID.uuidString.lowercased() == grantID, value.candidateID == candidateID else {
                    throw ContinuityIngressError.integrityFailure("bootstrap grant columns differ")
                }
                return value
            }
    }

    private func validateBootstrapSessionIntentUnlocked(_ intent: ProviderSessionIntent, grant: ContinuityBootstrapGrant,
                                                         lease: RunLease, connection: ControlPlaneSQLiteConnection) throws {
        try validateBootstrapGrantUnlocked(grant, lease: lease, connection: connection)
        let task = try validatedContinuityTaskUnlocked(grant.envelope.authorization, connection: connection)
        guard intent.sessionID == grant.sessionID, intent.runID == grant.envelope.runID,
              intent.projectID == grant.envelope.authorization.projectID,
              intent.projectGeneration == grant.envelope.authorization.projectGeneration,
              intent.providerID == task.assignment.providerID, intent.adapterID == task.assignment.adapterID,
              intent.modelKey == task.assignment.modelKey, intent.operationID == grant.envelope.operationID,
              intent.handoffID == grant.envelope.handoffID, intent.handoffSHA256 == grant.envelope.envelopeSHA256,
              intent.bootstrapNonceSHA256 == JSONSupport.sha256Hex(grant.envelope.bootstrapNonce.uuidString.lowercased()),
              intent.predecessorSessionID == nil, intent.providerResponseID == nil,
              intent.status == .candidate, !intent.accepted,
              !intent.idempotencyKey.isEmpty, intent.idempotencyKey.utf8.count <= 1_024, !intent.idempotencyKey.contains("\0"),
              intent.contextCapacity.map({ $0 > 0 && $0 <= 10_000_000 }) ?? true else {
            throw ContinuityIngressError.authorityMismatch
        }
    }

    private func validateBootstrapTurnIntentUnlocked(_ intent: ProviderTurnIntent, grant: ContinuityBootstrapGrant,
                                                      lease: RunLease, connection: ControlPlaneSQLiteConnection) throws {
        try validateBootstrapGrantUnlocked(grant, lease: lease, connection: connection)
        guard intent.runID == grant.envelope.runID, intent.sessionID == grant.sessionID,
              intent.operationID == grant.envelope.operationID, intent.kind == .bootstrap,
              intent.projectID == grant.envelope.authorization.projectID,
              intent.projectGeneration == grant.envelope.authorization.projectGeneration,
              intent.toolSchemaSHA256 != nil,
              let session = try providerSessionIdentityUnlocked(grant.sessionID, connection: connection),
              session.status == .candidate, !session.accepted else { throw ContinuityIngressError.authorityMismatch }
        if let previous = intent.previousResponseID {
            guard let proof = try bootstrapRetrievalProofUnlocked(grant: grant, connection: connection),
                  previous == proof.providerResponseID else { throw ContinuityIngressError.authorityMismatch }
        }
        // The same stage is recovered by its persisted identity; another key is
        // not permission to create an additional root or acknowledgment request.
        let other = try connection.scalarInt("""
            SELECT COUNT(*) FROM provider_turns WHERE session_id=? AND request_kind='bootstrap'
                AND (previous_response_id IS NULL)=? AND turn_id<>?
            """, bindings: [.text(grant.sessionID), .int64(intent.previousResponseID == nil ? 1 : 0),
                .text(intent.turnID.uuidString.lowercased())])
        guard other == 0 else { throw ContinuityIngressError.deliveryConflict }
    }

    private func bootstrapCallSHA256(_ call: ProviderToolCall) throws -> String {
        try ForgeJSONCanonicalizationV1.sha256Hex(of: JSONSerialization.jsonObject(with: call.argumentsJSON))
    }

    private func validateExactBootstrapCall(_ call: ProviderToolCall, source: ContinuityHandoffIdentity) throws {
        guard call.name == "context_get", call.argumentsJSON.count <= 4_096,
              let args = try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any],
              !args.isEmpty, Set(args.keys).isSubset(of: ["id", "handoff_id"]),
              args.values.allSatisfy({ ($0 as? String) == source.continuityID }) else {
            throw ContinuityIngressError.authorityMismatch
        }
    }

    private func validateBootstrapToolIntentUnlocked(_ intent: ToolInvocationIntent, grant: ContinuityBootstrapGrant,
                                                      lease: RunLease, connection: ControlPlaneSQLiteConnection) throws {
        try validateBootstrapGrantUnlocked(grant, lease: lease, connection: connection)
        guard intent.runID == grant.envelope.runID, intent.sessionID == grant.sessionID,
              intent.projectID == grant.envelope.authorization.projectID,
              intent.projectGeneration == grant.envelope.authorization.projectGeneration,
              intent.toolName == "context_get", intent.replayClass == .readOnly,
              intent.idempotencyKey == nil, intent.reconciliationDescriptor == nil,
              let result = try bootstrapProviderResultUnlocked(grant: grant, turnID: intent.turnID, connection: connection),
              result.previousResponseID == nil, result.toolCalls.count == 1 else {
            throw ContinuityIngressError.authorityMismatch
        }
        let call = result.toolCalls[0]
        try validateExactBootstrapCall(call, source: grant.envelope.sourceIdentity)
        guard call.callID == intent.providerCallID, try bootstrapCallSHA256(call) == intent.argumentsSHA256 else {
            throw ContinuityIngressError.authorityMismatch
        }
    }

    private func requireBootstrapResultLimitsUnlocked(grant: ContinuityBootstrapGrant,
                                                       policy: BudgetToolPolicy, connection: ControlPlaneSQLiteConnection) throws {
        let policy = try nativeInheritedToolPolicy(policy, runID: grant.envelope.runID, connection: connection)
        let source = grant.envelope.acceptance.source
        let expectedResult = try ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false, "payload": [
            "ok": true, "found": true, "packet": JSONSerialization.jsonObject(with: source.canonicalPacketJSON),
            "continuity_id": source.identity.continuityID, "revision": source.identity.revision,
            "packet_sha256": source.identity.packetSHA256]])
        guard expectedResult.count <= policy.maxResultBytes else {
            throw ContinuityIngressError.capacityExceeded("current bootstrap result-byte budget")
        }
        // The stored full wire includes the exact provider payload plus its
        // success wrapper. Estimating it conservatively bounds both retained
        // forms without truncating or substituting the frozen source packet.
        let retainedTokens = try ContextBudgetMath.estimateTokens(serializedBytes: expectedResult.count,
            policy: ContextBudgetPolicy())
        guard retainedTokens <= policy.maxRetainedResultTokens else {
            throw ContinuityIngressError.capacityExceeded("current bootstrap retained-result token budget")
        }
    }

    private func requireBootstrapToolQuotaUnlocked(runID: RunID, sessionID: String, turnID: UUID,
        operationID: UUID, policy: BudgetToolPolicy, connection: ControlPlaneSQLiteConnection) throws {
        let policy = try nativeInheritedToolPolicy(policy, runID: runID, connection: connection)
        let run = runID.description
        let sourceOffset = try nativeRunSourceOffsetUnlocked(runID, connection: connection) ?? 0
        let checks: [(String, [ControlPlaneSQLiteBinding], Int)] = [
            ("SELECT COUNT(*) FROM tool_invocations WHERE run_id=?", [.text(run)], max(0, policy.callsPerRun - sourceOffset)),
            ("SELECT COUNT(*) FROM tool_invocations WHERE session_id=?", [.text(sessionID)], policy.callsPerSession),
            ("SELECT COUNT(*) FROM tool_invocations WHERE turn_id=?", [.text(turnID.uuidString.lowercased())], policy.callsPerTurn),
            ("SELECT COUNT(*) FROM tool_invocations WHERE run_id=? AND state IN ('intent','executing','ambiguous')",
                [.text(run)], policy.maxInFlight),
            ("""
             SELECT COUNT(*) FROM tool_invocations i JOIN provider_turns t ON t.turn_id=i.turn_id
             WHERE i.run_id=? AND t.operation_id=? AND t.request_kind='bootstrap'
             """, [.text(run), .text(operationID.uuidString.lowercased())], policy.recoveryCallsPerRollover),
        ]
        for (query, values, maximum) in checks {
            guard try connection.scalarInt(query, bindings: values) < maximum else {
                throw ContinuityIngressError.capacityExceeded("current bootstrap tool budget")
            }
        }
    }

    private func bootstrapProviderResultUnlocked(grant: ContinuityBootstrapGrant, turnID: UUID,
                                                 connection: ControlPlaneSQLiteConnection) throws -> ProviderTurn? {
        try connection.first("SELECT result_json,result_sha256 FROM continuity_bootstrap_provider_results WHERE grant_id=? AND turn_id=?",
            bindings: [.text(grant.grantID.uuidString.lowercased()), .text(turnID.uuidString.lowercased())]) { row in
                guard let json = try row.strictText(0, maximumBytes: 131_072), let sha = try row.strictText(1, maximumBytes: 64),
                      JSONSupport.sha256Hex(Data(json.utf8)) == sha else {
                    throw ContinuityIngressError.integrityFailure("malformed bootstrap provider result")
                }
                let data = Data(json.utf8)
                let result = try JSONDecoder().decode(ProviderTurn.self, from: data)
                guard try ForgeJSONCanonicalizationV1.data(from: JSONSerialization.jsonObject(with: JSONEncoder().encode(result))) == data,
                      let turn = try providerTurnUnlocked(turnID, connection: connection), turn.state == .completed,
                      turn.intent.sessionID == grant.sessionID, turn.intent.operationID == grant.envelope.operationID,
                      turn.providerRequestID == result.requestID, turn.providerResponseID == result.responseID,
                      turn.intent.previousResponseID == result.previousResponseID,
                      result.completed, result.finishReason == .toolCalls, result.toolCalls.count == 1 else {
                    throw ContinuityIngressError.integrityFailure("provider result differs from durable turn")
                }
                let task = try validatedContinuityTaskUnlocked(grant.envelope.authorization, connection: connection)
                guard result.providerID == task.assignment.providerID, result.modelKey == task.assignment.modelKey else {
                    throw ContinuityIngressError.authorityMismatch
                }
                return result
            }
    }

    private func bootstrapRetrievalProofUnlocked(grant: ContinuityBootstrapGrant,
                                                 connection: ControlPlaneSQLiteConnection) throws -> ContinuityBootstrapRetrievalProof? {
        try connection.first("SELECT invocation_id,proof_json,proof_sha256 FROM continuity_bootstrap_retrieval_proofs WHERE grant_id=?",
            bindings: [.text(grant.grantID.uuidString.lowercased())]) { row in
                guard let invocation = try row.strictText(0, maximumBytes: 36),
                      let json = try row.strictText(1, maximumBytes: ContinuityBootstrapRetrievalProof.maximumStoredBytes),
                      let sha = try row.strictText(2, maximumBytes: 64), JSONSupport.sha256Hex(Data(json.utf8)) == sha else {
                    throw ContinuityIngressError.integrityFailure("malformed bootstrap retrieval proof row")
                }
                let proof = try ContinuityBootstrapRetrievalProof.storedSnapshot(from: Data(json.utf8), grant: grant)
                guard proof.toolInvocationID.uuidString.lowercased() == invocation else {
                    throw ContinuityIngressError.integrityFailure("bootstrap proof invocation columns differ")
                }
                return proof
            }
    }

    private func validateContinuityIngressHoldUnlocked(receipt: ContinuityIngressAcceptanceReceipt,
                                                        connection: ControlPlaneSQLiteConnection) throws {
        guard let hold = try connection.first(
            "SELECT run_id,state FROM continuity_ingress_holds WHERE operation_id=? LIMIT 1",
            bindings: [.text(receipt.operationID.uuidString.lowercased())], map: { row in
                (try row.strictText(0, maximumBytes: 36), try row.strictText(1, maximumBytes: 32))
            }), hold.0 == receipt.runID.description,
              ["awaiting_bootstrap", "cancelled", "activated"].contains(hold.1 ?? "") else {
            throw ContinuityIngressError.integrityFailure("acceptance bootstrap hold is missing or changed")
        }
    }

    private func requireNoActiveContinuityIngressHoldUnlocked(_ runID: RunID,
                                                               connection: ControlPlaneSQLiteConnection) throws {
        if let operation = try autonomousRunUnlocked(runID, connection: connection)?.activeOperationID {
            try requireContinuityOperationNotCancelledUnlocked(operation, connection: connection)
        }
        guard try connection.scalarInt("""
            SELECT COUNT(*) FROM continuity_ingress_acceptances a
            LEFT JOIN continuity_ingress_holds h ON h.operation_id=a.operation_id AND h.run_id=a.run_id
            WHERE a.run_id=? AND (h.operation_id IS NULL OR h.state NOT IN ('awaiting_bootstrap','cancelled','activated'))
            """, bindings: [.text(runID.description)]) == 0 else {
            throw ContinuityIngressError.integrityFailure("accepted run lost its bootstrap history")
        }
        if try connection.scalarInt("SELECT COUNT(*) FROM continuity_ingress_holds WHERE run_id=? AND state IN ('awaiting_bootstrap','cancelled')",
            bindings: [.text(runID.description)]) > 0 {
            throw AutonomyError.bootstrapRequired(runID)
        }
    }

    private func requireNoContinuityIngressHoldUnlocked(_ runID: RunID,
                                                         connection: ControlPlaneSQLiteConnection) throws {
        try requireNoActiveContinuityIngressHoldUnlocked(runID, connection: connection)
        let operations = try connection.all("SELECT operation_id,state FROM continuity_ingress_holds WHERE run_id=? LIMIT 1025",
            bindings: [.text(runID.description)], map: { (try $0.strictText(0, maximumBytes: 36), try $0.strictText(1, maximumBytes: 32)) })
        guard operations.count <= Self.maximumContinuityIngressAcceptances else { throw AutonomyError.bootstrapRequired(runID) }
        for operation in operations {
            guard operation.1 == "activated", let id = operation.0.flatMap(UUID.init(uuidString:)),
                  let stored = try sourceActivationUnlocked(operationID: id, connection: connection),
                  stored.receipt.runID == runID, stored.sealedChecksum != nil,
                  try connection.scalarInt("SELECT COUNT(*) FROM continuity_source_task_fences WHERE operation_id=? AND activation_receipt_sha256=? AND state='accepted'",
                    bindings: [.text(id.uuidString.lowercased()), .text(stored.receipt.receiptSHA256)]) == 1 else {
                throw AutonomyError.bootstrapRequired(runID)
            }
        }
    }

    private func insertAutonomousRunUnlocked(_ request: AutonomousRunRequest, state: AutonomousRunState,
                                             operationID: UUID?, timestamp: String,
                                             connection: ControlPlaneSQLiteConnection) throws -> AutonomousRunRecord {
        guard state == .created || state == .awaitingBootstrap else { throw AutonomyError.invalidRequest("initial run state") }
        try connection.execute(
            """
            INSERT INTO autonomous_runs(run_id,project_id,project_generation,assignment_id,mission,state,
                continuity_mode,provider_id,model_key,current_work_json,active_operation_id,revision,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,0,?,?)
            """,
            bindings: [.text(request.runID.description), .text(request.projectID.description),
                .int64(try Self.sqliteGeneration(request.projectGeneration)), .optionalText(request.assignmentID), .text(request.mission),
                .text(state.rawValue), .text(request.continuityMode.rawValue), .text(request.providerID), .text(request.modelKey),
                .text(try Self.specificationJSON(request.specification)), .optionalText(operationID?.uuidString.lowercased()),
                .text(timestamp), .text(timestamp)])
        try upsertAutonomousRunBindingUnlocked(request, timestamp: timestamp, connection: connection)
        try appendAutonomyEventUnlocked(runID: request.runID, projectID: request.projectID,
            eventType: "autonomous_run_created", severity: .info, summary: "Autonomous run was durably created",
            metadata: ["continuity_mode": request.continuityMode.rawValue,
                "project_generation": String(request.projectGeneration.rawValue), "initial_state": state.rawValue], connection: connection)
        guard let run = try autonomousRunUnlocked(request.runID, connection: connection) else {
            throw ProjectContextError.integrityFailure("autonomous run could not be read after insertion")
        }
        return run
    }

    private static func decodeContinuityTask(_ row: ControlPlaneSQLiteRow) throws -> ContinuityTaskAuthorizationRecord {
        let revokedAt = try row.strictText(14, maximumBytes: 128)
        guard let taskID = try row.strictText(0, maximumBytes: 36).flatMap(UUID.init(uuidString:)),
              let projectID = try row.strictText(1, maximumBytes: 36).flatMap(UUID.init(uuidString:)), row.int64(2) > 0,
              let sourceBindingID = try row.strictText(3, maximumBytes: 36).flatMap(UUID.init(uuidString:)),
              let assignmentID = try row.strictText(4, maximumBytes: 1_024),
              let assignmentSHA = try row.strictText(5, maximumBytes: 64),
              let assignmentJSON = try row.strictText(6, maximumBytes: ContinuityTaskAssignment.maximumStoredBytes),
              let assignmentSnapshotSHA = try row.strictText(7, maximumBytes: 64),
              let authorizationJSON = try row.strictText(8, maximumBytes: ContinuityIngressLimits.maximumAuthorizationBytes),
              let authorizationSHA = try row.strictText(9, maximumBytes: 64),
              let state = try row.strictText(10, maximumBytes: 7).flatMap(ContinuityTaskAuthorizationState.init(rawValue:)),
              (1..<Int64.max).contains(row.int64(11)), let created = try row.strictText(13, maximumBytes: 128),
              (state == .active ? revokedAt == nil : revokedAt != nil) else {
            throw ContinuityTaskAuthorizationError.integrityFailure("malformed task row")
        }
        let assignmentData = Data(assignmentJSON.utf8)
        let authorizationData = Data(authorizationJSON.utf8)
        guard JSONSupport.sha256Hex(assignmentData) == assignmentSnapshotSHA,
              JSONSupport.sha256Hex(authorizationData) == authorizationSHA else {
            throw ContinuityTaskAuthorizationError.integrityFailure("task snapshot digest mismatch")
        }
        let assignment = try ContinuityTaskAssignment.storedSnapshot(from: assignmentData)
        let authority = try ContinuityIngressAuthorization.storedSnapshot(from: authorizationData)
        guard authority.taskID == taskID, authority.projectID.rawValue == projectID,
              authority.projectGeneration.rawValue == UInt64(row.int64(2)), authority.sourceBindingID == sourceBindingID,
              authority.assignmentID == assignmentID, authority.assignmentSHA256 == assignmentSHA,
              assignment.assignmentID == assignmentID, assignment.assignmentSHA256 == assignmentSHA,
              authority.authorizationScope == assignment.authorizationScope else {
            throw ContinuityTaskAuthorizationError.integrityFailure("task identity columns differ from the approved snapshots")
        }
        let runID: RunID?
        if let text = try row.strictText(12, maximumBytes: 36) {
            guard let uuid = UUID(uuidString: text) else {
                throw ContinuityTaskAuthorizationError.integrityFailure("invalid task run identifier")
            }
            runID = RunID(uuid)
        } else { runID = nil }
        return ContinuityTaskAuthorizationRecord(authorization: authority, assignment: assignment, state: state,
            revision: row.int64(11), runID: runID, createdAt: created, revokedAt: revokedAt)
    }

    private func validatedContinuityTaskUnlocked(_ authorization: ContinuityIngressAuthorization, allowTerminalRun: Bool = false,
                                                 connection: ControlPlaneSQLiteConnection) throws -> ContinuityTaskAuthorizationRecord {
        try authorization.validate()
        guard let record = try continuityTaskUnlocked(authorization.taskID, connection: connection) else {
            throw ContinuityTaskAuthorizationError.authorityMismatch
        }
        guard record.state == .active else { throw ContinuityTaskAuthorizationError.revoked }
        guard record.authorization == authorization else { throw ContinuityTaskAuthorizationError.authorityMismatch }
        _ = try requiredActiveProjectUnlocked(authorization.projectID, generation: authorization.projectGeneration, connection: connection)
        let sourceOwner = ProjectBindingOwner(kind: .agentSession, id: authorization.taskID.uuidString.lowercased())
        guard let source = try bindingUnlocked(owner: sourceOwner, includeInactive: false, connection: connection),
              source.bindingID == authorization.sourceBindingID,
              source.projectID == authorization.projectID, source.projectGeneration == authorization.projectGeneration,
              source.runID == record.runID,
              source.authorizationScope == authorization.authorizationScope else {
            throw ContinuityTaskAuthorizationError.authorityMismatch
        }
        if let runID = record.runID {
            guard let run = try autonomousRunUnlocked(runID, connection: connection),
                  run.projectID == authorization.projectID, run.projectGeneration == authorization.projectGeneration,
                  run.assignmentID == record.assignment.assignmentID, run.mission == record.assignment.mission,
                  run.providerID == record.assignment.providerID, run.modelKey == record.assignment.modelKey,
                  run.adapterID == record.assignment.adapterID,
                  run.specification.allowedTools == record.assignment.specification.allowedTools,
                  run.specification.completionGates == record.assignment.specification.completionGates,
                  run.specification.resourceProfile == record.assignment.specification.resourceProfile,
                  (allowTerminalRun || !run.state.isTerminal),
                  let binding = try bindingUnlocked(owner: .init(kind: .autonomousRun, id: runID.description), includeInactive: false, connection: connection),
                  binding.authorizationScope == authorization.authorizationScope else {
                throw ContinuityTaskAuthorizationError.authorityMismatch
            }
        }
        return record
    }

    private func revokeContinuityTasksUnlocked(projectID: ProjectID, generation: ProjectGeneration, taskID: UUID?,
                                               timestamp: String, connection: ControlPlaneSQLiteConnection) throws {
        let suffix = taskID == nil ? "" : " AND task_id=?"
        var bindings: [ControlPlaneSQLiteBinding] = [.text(projectID.description), .int64(try Self.sqliteGeneration(generation))]
        if let taskID { bindings.append(.text(taskID.uuidString.lowercased())) }
        try connection.execute(
            """
            UPDATE project_bindings SET active=0,lease_owner=NULL,lease_expires_at=NULL,updated_at=?
            WHERE owner_kind='agent_session' AND binding_id IN (
                SELECT source_binding_id FROM continuity_task_authorizations
                WHERE project_id=? AND project_generation=? AND state='active'
            """ + suffix + ")", bindings: [.text(timestamp)] + bindings)
        let count = try connection.execute(
            "UPDATE continuity_task_authorizations SET state='revoked',revision=revision+1,revoked_at=? WHERE project_id=? AND project_generation=? AND state='active'" + suffix,
            bindings: [.text(timestamp)] + bindings)
        if count > 0 {
            try appendAutonomyEventUnlocked(runID: nil, projectID: projectID, eventType: "continuity_task_revoked",
                severity: .info, summary: "Task authority was permanently revoked",
                metadata: ["task_id": taskID?.uuidString.lowercased() ?? "all_current_generation",
                           "project_generation": String(generation.rawValue), "revoked_count": String(count)], connection: connection)
        }
    }

    private func requiredActiveProjectUnlocked(
        _ projectID: ProjectID,
        generation: ProjectGeneration,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ProjectControlRecord {
        guard let project = try projectUnlocked(projectID, connection: connection) else {
            throw ProjectContextError.projectNotFound(projectID)
        }
        guard project.generation == generation else {
            throw ProjectContextError.staleProjectGeneration(expected: generation, actual: project.generation)
        }
        guard project.lifecycleState == .active else {
            throw ProjectContextError.projectNotActive(project.lifecycleState)
        }
        return project
    }

    private func projectUnlocked(
        _ projectID: ProjectID,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ProjectControlRecord? {
        try connection.first(
            """
            SELECT project_id,display_name,canonical_root,generation,lifecycle_state,
                   repository_fingerprint,bookmark_reference,created_at,updated_at
            FROM control_projects WHERE project_id=? LIMIT 1
            """,
            bindings: [.text(projectID.description)]
        ) { row in
            try Self.decodeProject(row)
        }
    }

    private func projectAtRootUnlocked(
        _ root: URL,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ProjectControlRecord? {
        try connection.first(
            """
            SELECT project_id,display_name,canonical_root,generation,lifecycle_state,
                   repository_fingerprint,bookmark_reference,created_at,updated_at
            FROM control_projects WHERE canonical_root=? AND lifecycle_state!='archived' LIMIT 1
            """,
            bindings: [.text(root.path)]
        ) { row in
            try Self.decodeProject(row)
        }
    }

    private func bindingUnlocked(
        owner: ProjectBindingOwner,
        includeInactive: Bool,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ProjectContextBinding? {
        let activeClause = includeInactive ? "" : " AND active=1"
        return try connection.first(
            """
            SELECT binding_id,owner_kind,owner_id,project_id,project_generation,run_id,
                   authorization_scope_json,lease_owner,lease_expires_at,active,created_at,updated_at
            FROM project_bindings WHERE owner_kind=? AND owner_id=?\(activeClause) LIMIT 1
            """,
            bindings: [.text(owner.kind.rawValue), .text(owner.id)]
        ) { row in
            try Self.decodeBinding(row)
        }
    }

    private struct ContinuityRunIdentity {
        let projectID: ProjectID
        let projectGeneration: ProjectGeneration
        let assignmentID: String?
        let mission: String
        let mode: ContinuityMode
    }

    private func continuityRunIdentityUnlocked(
        _ runID: RunID,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ContinuityRunIdentity? {
        try connection.first(
            """
            SELECT project_id,project_generation,assignment_id,mission,continuity_mode
            FROM autonomous_runs WHERE run_id=? LIMIT 1
            """,
            bindings: [.text(runID.description)]
        ) { row in
            guard let projectString = row.text(0),
                  let projectUUID = UUID(uuidString: projectString),
                  row.int64(1) > 0,
                  let mission = row.text(3),
                  let modeString = row.text(4),
                  let mode = ContinuityMode(rawValue: modeString) else {
                throw ProjectContextError.integrityFailure("invalid autonomous run identity")
            }
            return ContinuityRunIdentity(
                projectID: ProjectID(projectUUID),
                projectGeneration: ProjectGeneration(UInt64(row.int64(1))),
                assignmentID: row.text(2),
                mission: mission,
                mode: mode
            )
        }
    }

    private static let contextBudgetActionRequestSelect = """
    SELECT request_id,continuity_operation_id,run_id,session_id,project_id,
           project_generation,observation_id,requested_action,fulfilled_action,
           action_epoch,reason,revision,created_at,updated_at
    FROM context_budget_action_requests
    """

    private func contextBudgetActionRequestUnlocked(
        identity: ContextBudgetIdentity,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ContextBudgetActionRequest? {
        try connection.first(
            Self.contextBudgetActionRequestSelect
                + " WHERE run_id=? AND session_id=? LIMIT 1",
            bindings: [.text(identity.runID.description), .text(identity.sessionID)],
            map: Self.decodeContextBudgetActionRequest
        )
    }

    private func contextBudgetActionRequestUnlocked(
        requestID: UUID,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ContextBudgetActionRequest? {
        try connection.first(
            Self.contextBudgetActionRequestSelect + " WHERE request_id=? LIMIT 1",
            bindings: [.text(requestID.uuidString.lowercased())],
            map: Self.decodeContextBudgetActionRequest
        )
    }

    private static func decodeContextBudgetActionRequest(
        _ row: ControlPlaneSQLiteRow
    ) throws -> ContextBudgetActionRequest {
        let fulfilledRaw = row.text(8)
        guard let requestString = row.text(0), let requestID = UUID(uuidString: requestString),
              let operationString = row.text(1),
              let operationID = UUID(uuidString: operationString),
              let runString = row.text(2), let runID = UUID(uuidString: runString),
              let sessionID = row.text(3),
              let projectString = row.text(4), let projectID = UUID(uuidString: projectString),
              row.int64(5) > 0,
              let observationString = row.text(6),
              let observationID = UUID(uuidString: observationString),
              let requestedRaw = row.text(7),
              let requestedAction = ContextBudgetAction(rawValue: requestedRaw),
              requestedAction != .normal,
              fulfilledRaw == nil || ContextBudgetAction(rawValue: fulfilledRaw!) != nil,
              row.int64(9) > 0,
              let reason = row.text(10), row.int64(11) > 0,
              let createdAt = row.text(12), let updatedAt = row.text(13) else {
            throw ProjectContextError.integrityFailure(
                "invalid context budget action request row"
            )
        }
        return try ContextBudgetActionRequest(
            requestID: requestID,
            continuityOperationID: operationID,
            identity: ContextBudgetIdentity(
                runID: RunID(runID),
                projectID: ProjectID(projectID),
                projectGeneration: ProjectGeneration(UInt64(row.int64(5))),
                sessionID: sessionID
            ),
            observationID: observationID,
            requestedAction: requestedAction,
            fulfilledAction: fulfilledRaw.flatMap(ContextBudgetAction.init(rawValue:)),
            actionEpoch: UInt64(row.int64(9)),
            reason: reason,
            revision: UInt64(row.int64(11)),
            createdAt: createdAt,
            updatedAt: updatedAt
        ).validated()
    }

    private func upsertContextBudgetActionRequestUnlocked(
        _ intent: ContextBudgetActionRequestIntent,
        timestamp: String,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ContextBudgetActionRequest {
        try validateContextBudgetActionRequestIntent(intent)
        let matches = try connection.all(
            Self.contextBudgetActionRequestSelect
                + " WHERE request_id=? OR continuity_operation_id=? OR (run_id=? AND session_id=?)",
            bindings: [
                .text(intent.requestID.uuidString.lowercased()),
                .text(intent.continuityOperationID.uuidString.lowercased()),
                .text(intent.identity.runID.description), .text(intent.identity.sessionID),
            ],
            map: Self.decodeContextBudgetActionRequest
        )
        guard matches.count <= 1 else {
            throw ProjectContextError.integrityFailure(
                "context budget action identity resolves to multiple rows"
            )
        }
        if let existing = matches.first {
            guard existing.requestID == intent.requestID,
                  existing.continuityOperationID == intent.continuityOperationID,
                  existing.identity == intent.identity,
                  intent.requestedAction.severity > existing.requestedAction.severity,
                  intent.actionEpoch > existing.actionEpoch,
                  existing.revision < UInt64(Int64.max) else {
                throw ContextBudgetError.invalidActionRequest
            }
            let changed = try connection.execute(
                """
                UPDATE context_budget_action_requests
                SET observation_id=?,requested_action=?,action_epoch=?,reason=?,
                    revision=revision+1,updated_at=?
                WHERE request_id=? AND revision=?
                """,
                bindings: [
                    .text(intent.observationID.uuidString.lowercased()),
                    .text(intent.requestedAction.rawValue),
                    .int64(Int64(intent.actionEpoch)), .text(intent.reason), .text(timestamp),
                    .text(intent.requestID.uuidString.lowercased()),
                    .int64(Int64(existing.revision)),
                ]
            )
            guard changed == 1 else { throw ContextBudgetError.persistenceConflict }
        } else {
            try connection.execute(
                """
                INSERT INTO context_budget_action_requests(
                    request_id,continuity_operation_id,run_id,session_id,project_id,
                    project_generation,observation_id,requested_action,fulfilled_action,
                    action_epoch,reason,revision,created_at,updated_at
                ) VALUES(?,?,?,?,?,?,?,?,NULL,?,?,1,?,?)
                """,
                bindings: [
                    .text(intent.requestID.uuidString.lowercased()),
                    .text(intent.continuityOperationID.uuidString.lowercased()),
                    .text(intent.identity.runID.description), .text(intent.identity.sessionID),
                    .text(intent.identity.projectID.description),
                    .int64(try Self.sqliteGeneration(intent.identity.projectGeneration)),
                    .text(intent.observationID.uuidString.lowercased()),
                    .text(intent.requestedAction.rawValue),
                    .int64(Int64(intent.actionEpoch)), .text(intent.reason),
                    .text(timestamp), .text(timestamp),
                ]
            )
        }
        guard let result = try contextBudgetActionRequestUnlocked(
            requestID: intent.requestID,
            connection: connection
        ) else {
            throw ProjectContextError.integrityFailure(
                "context budget action request could not be read after enqueue"
            )
        }
        return result
    }

    private func validateContextBudgetActionRequestIntent(
        _ intent: ContextBudgetActionRequestIntent
    ) throws {
        _ = try intent.identity.validated()
        let normalizedReason = intent.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard intent.requestedAction != .normal,
              intent.actionEpoch > 0,
              intent.actionEpoch <= UInt64(Int64.max),
              normalizedReason == intent.reason,
              !intent.reason.isEmpty,
              intent.reason.utf8.count <= 2_048 else {
            throw ContextBudgetError.invalidActionRequest
        }
    }

    private static let contextBudgetObservationSelect = """
    SELECT o.observation_id,o.run_id,o.session_id,o.provider_response_id,o.capacity,o.used,
           o.output_reserve,o.schema_reserve,o.handoff_reserve,o.recovery_reserve,o.remaining,
           o.projected_next_turn,o.source,o.confidence,o.estimator_version,o.action,o.created_at,
           d.project_id,d.project_generation,d.trigger_point,d.checkpoint_threshold,
           d.rollover_threshold,d.emergency_floor,d.hysteresis,d.action_epoch,
           m.observation_id,
           CASE WHEN length(CAST(m.observation_json AS BLOB)) <= 65536
                THEN m.observation_json ELSE NULL END
    FROM context_budget_observations o
    INNER JOIN context_budget_observation_details d ON d.observation_id=o.observation_id
    LEFT JOIN context_budget_observation_metadata m ON m.observation_id=o.observation_id
    """

    private func contextBudgetStateUnlocked(
        identity: ContextBudgetIdentity,
        connection: ControlPlaneSQLiteConnection
    ) throws -> PersistedContextBudgetState? {
        try connection.first(
            """
            SELECT project_id,project_generation,
                   CASE WHEN length(CAST(state_json AS BLOB)) <= 65536 THEN state_json ELSE NULL END,
                   revision,latest_observation_id
            FROM context_budget_supervisor_state WHERE run_id=? AND session_id=? LIMIT 1
            """,
            bindings: [.text(identity.runID.description), .text(identity.sessionID)]
        ) { row in
            guard let projectString = row.text(0), let projectUUID = UUID(uuidString: projectString),
                  row.int64(1) > 0, let stateJSON = row.text(2), row.int64(3) >= 0 else {
                throw ProjectContextError.integrityFailure("invalid context budget state row")
            }
            guard ProjectID(projectUUID) == identity.projectID,
                  ProjectGeneration(UInt64(row.int64(1))) == identity.projectGeneration else {
                throw ProjectContextError.projectScopeMismatch
            }
            let state: PersistedContextBudgetState
            do {
                state = try JSONDecoder().decode(
                    PersistedContextBudgetState.self,
                    from: Data(stateJSON.utf8)
                )
                _ = try state.validated()
            } catch {
                throw ProjectContextError.integrityFailure("invalid persisted context budget state")
            }
            guard state.identity == identity,
                  state.revision == UInt64(row.int64(3)),
                  state.latestObservation?.observationID.uuidString.lowercased() == row.text(4) else {
                throw ProjectContextError.integrityFailure("context budget state identity is inconsistent")
            }
            if let observation = state.latestObservation {
                do {
                    try Self.validateContextBudgetObservation(observation)
                    guard observation.reserves == state.configuration.reserves,
                          observation.accounting?.resolvedPolicy == state.configuration.resolvedPolicy,
                          observation.createdAt == state.updatedAt else {
                        throw ContextBudgetError.invalidPersistedState
                    }
                } catch {
                    throw ProjectContextError.integrityFailure("persisted budget observation disagrees with its state")
                }
            }
            return state
        }
    }

    private static func decodeContextBudgetObservation(
        _ row: ControlPlaneSQLiteRow
    ) throws -> ContextBudgetObservation {
        guard let observationString = row.text(0),
              let observationID = UUID(uuidString: observationString),
              let runString = row.text(1), let runUUID = UUID(uuidString: runString),
              let sessionID = row.text(2),
              row.int64(4) > 0, row.int64(5) >= 0,
              row.int64(6) >= 0, row.int64(7) >= 0,
              row.int64(8) >= 0, row.int64(9) >= 0,
              row.int64(11) >= 0,
              let sourceString = row.text(12),
              let source = ContextBudgetUsageSource(rawValue: sourceString),
              let confidenceString = row.text(13), let confidence = Double(confidenceString),
              confidence.isFinite, (0...1).contains(confidence),
              let estimatorVersion = row.text(14),
              let actionString = row.text(15), let action = ContextBudgetAction(rawValue: actionString),
              let createdAt = row.text(16),
              let projectString = row.text(17), let projectUUID = UUID(uuidString: projectString),
              row.int64(18) > 0,
              let triggerString = row.text(19),
              let trigger = ContextBudgetTriggerPoint(rawValue: triggerString),
              row.int64(20) >= 0, row.int64(21) >= 0,
              row.int64(22) >= 0, row.int64(23) >= 0, row.int64(24) >= 0 else {
            throw ProjectContextError.integrityFailure("invalid context budget observation row")
        }
        let legacy = ContextBudgetObservation(
            observationID: observationID,
            identity: ContextBudgetIdentity(
                runID: RunID(runUUID),
                projectID: ProjectID(projectUUID),
                projectGeneration: ProjectGeneration(UInt64(row.int64(18))),
                sessionID: sessionID
            ),
            providerResponseID: row.text(3),
            capacity: Int(row.int64(4)),
            used: Int(row.int64(5)),
            reserves: ContextBudgetReserves(
                outputTokens: Int(row.int64(6)),
                schemaTokens: Int(row.int64(7)),
                handoffTokens: Int(row.int64(8)),
                recoveryTokens: Int(row.int64(9))
            ),
            remaining: Int(row.int64(10)),
            projectedNextTurn: Int(row.int64(11)),
            source: source,
            confidence: confidence,
            estimatorVersion: estimatorVersion,
            action: action,
            triggerPoint: trigger,
            thresholds: ContextBudgetThresholds(
                checkpoint: Int(row.int64(20)),
                rollover: Int(row.int64(21)),
                emergency: Int(row.int64(22)),
                hysteresis: Int(row.int64(23))
            ),
            actionEpoch: UInt64(row.int64(24)),
            createdAt: createdAt
        )
        guard row.text(25) != nil else {
            try validateContextBudgetObservation(legacy)
            return legacy
        }
        guard let observationJSON = row.text(26),
              observationJSON.utf8.count <= maximumContextBudgetObservationBytes else {
            throw ProjectContextError.integrityFailure("context budget metadata exceeds its bound")
        }
        let observation: ContextBudgetObservation
        do {
            observation = try JSONDecoder().decode(
                ContextBudgetObservation.self,
                from: Data(observationJSON.utf8)
            )
        } catch {
            throw ProjectContextError.integrityFailure("invalid context budget observation metadata")
        }
        // The fixed columns remain readable by older releases. Never accept a
        // newer metadata record that changes their identity or measured values.
        guard observation.observationID == legacy.observationID,
              observation.identity == legacy.identity,
              observation.providerResponseID == legacy.providerResponseID,
              observation.capacity == legacy.capacity,
              observation.used == legacy.used,
              observation.reserves.outputTokens == legacy.reserves.outputTokens,
              observation.reserves.schemaTokens == legacy.reserves.schemaTokens,
              observation.reserves.handoffTokens == legacy.reserves.handoffTokens,
              observation.reserves.recoveryTokens == legacy.reserves.recoveryTokens,
              observation.remaining == legacy.remaining,
              observation.projectedNextTurn == legacy.projectedNextTurn,
              observation.source == legacy.source,
              observation.confidence == legacy.confidence,
              observation.estimatorVersion == legacy.estimatorVersion,
              observation.action == legacy.action,
              observation.triggerPoint == legacy.triggerPoint,
              observation.thresholds == legacy.thresholds,
              observation.actionEpoch == legacy.actionEpoch,
              observation.createdAt == legacy.createdAt else {
            throw ProjectContextError.integrityFailure("context budget metadata disagrees with stored columns")
        }
        try validateContextBudgetObservation(observation)
        return observation
    }

    private static func validateContextBudgetObservation(_ observation: ContextBudgetObservation) throws {
        _ = try observation.identity.validated()
        let fixed = try observation.reserves.fixedTotal()
        guard observation.projectedNextTurn >= 0,
              observation.confidence.isFinite,
              (0...1).contains(observation.confidence),
              observation.estimatorVersion == ContextBudgetPolicy.estimatorVersion,
              observation.actionEpoch <= UInt64(Int64.max),
              ISO8601.date(from: observation.createdAt) != nil,
              observation.capacity > 0,
              observation.capacity <= ContextCapacityResolver.maximumSupportedCapacity,
              fixed < observation.capacity,
              observation.used >= 0,
              observation.remaining == observation.capacity - fixed - observation.used,
              observation.thresholds.checkpoint >= observation.thresholds.rollover,
              observation.thresholds.rollover >= observation.thresholds.emergency,
              observation.thresholds.emergency >= 0,
              observation.thresholds.hysteresis >= 0 else {
            throw ContextBudgetError.invalidObservation("derived budget values are inconsistent")
        }
        if let accounting = observation.accounting {
            _ = try accounting.validated()
            if let scope = accounting.resolvedPolicy?.selection.scope, scope.kind == .projectOverride {
                guard scope.projectID == observation.identity.projectID.description,
                      scope.projectGeneration == Int(observation.identity.projectGeneration.rawValue) else {
                    throw ContextBudgetError.invalidObservation("effective policy belongs to another project generation")
                }
            }
            guard accounting.futureReserveTokens == fixed,
                  accounting.resolvedPolicy.map({ $0.effectiveContextTokens == observation.capacity }) ?? true,
                  accounting.retainedInputTokens.map({ $0 == observation.used })
                    ?? (observation.source == .providerOverflow && observation.confidence == 0 && observation.action == .emergency) else {
                throw ContextBudgetError.invalidObservation("normalized accounting disagrees with observation")
            }
        }
    }

    private func validateContextBudgetCommit(
        _ commit: ContextBudgetPersistenceCommit
    ) throws {
        let observation = commit.observation
        _ = try observation.identity.validated()
        _ = try commit.state.validated()
        guard commit.state.identity == observation.identity,
              commit.state.latestObservation == observation,
              commit.state.action == observation.action,
              commit.state.actionEpoch == observation.actionEpoch,
              commit.state.configuration.capacity.capacity == observation.capacity,
              commit.state.configuration.reserves == observation.reserves,
              observation.capacity > 0,
              observation.used >= 0,
              observation.projectedNextTurn >= 0,
              observation.confidence.isFinite,
              (0...1).contains(observation.confidence),
              observation.estimatorVersion == ContextBudgetPolicy.estimatorVersion,
              ISO8601.date(from: observation.createdAt) != nil,
              observation.createdAt == commit.state.updatedAt else {
            throw ContextBudgetError.invalidPersistedState
        }
        try Self.validateContextBudgetObservation(observation)
        guard observation.accounting?.resolvedPolicy == commit.state.configuration.resolvedPolicy else {
            throw ContextBudgetError.invalidObservation("effective policy does not match committed configuration")
        }
        if let actionRequest = commit.actionRequest {
            try validateContextBudgetActionRequestIntent(actionRequest)
            guard actionRequest.identity == observation.identity,
                  actionRequest.observationID == observation.observationID,
                  actionRequest.requestedAction == observation.action,
                  actionRequest.actionEpoch == observation.actionEpoch,
                  commit.state.lastRequestedAction == actionRequest.requestedAction else {
                throw ContextBudgetError.invalidObservation(
                    "manager action request does not match observation"
                )
            }
        } else if commit.state.lastRequestedAction == nil {
            guard observation.action == .normal, observation.actionEpoch == 0 else {
                throw ContextBudgetError.invalidPersistedState
            }
        }
    }

    private func enqueueContinuityCommandUnlocked(
        _ request: ContinuityCommandRequest,
        timestamp: String,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ContinuityCommand {
        try validateContinuityCommandRequest(request)
        try requireNoContinuityIngressHoldUnlocked(request.runID, connection: connection)
        _ = try requiredActiveProjectUnlocked(
            request.projectID,
            generation: request.projectGeneration,
            connection: connection
        )
        guard let run = try continuityRunIdentityUnlocked(request.runID, connection: connection) else {
            throw ContinuityCommandQueueError.runNotFound(request.runID)
        }
        guard run.projectID == request.projectID,
              run.projectGeneration == request.projectGeneration else {
            throw ProjectContextError.projectScopeMismatch
        }
        if let existing = try continuityCommandByOperationOrKeyUnlocked(
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            connection: connection
        ) {
            guard existing.operationID == request.operationID,
                  existing.runID == request.runID,
                  existing.projectID == request.projectID,
                  existing.projectGeneration == request.projectGeneration,
                  existing.type == request.type,
                  existing.requestedBy == request.requestedBy,
                  existing.reason == request.reason,
                  existing.idempotencyKey == request.idempotencyKey,
                  existing.payloadSHA256 == request.payloadSHA256 else {
                throw ContinuityCommandQueueError.invalidCommand(
                    "operation or idempotency key is already bound to a different command"
                )
            }
            return existing
        }
        let commandID = UUID()
        try connection.execute(
            """
            INSERT INTO continuity_commands(
                command_id,operation_id,run_id,project_id,project_generation,command_type,
                requested_by,reason,state,idempotency_key,payload_sha256,attempt,
                created_at,updated_at
            ) VALUES(?,?,?,?,?,?,?,?, 'queued',?,?,0,?,?)
            """,
            bindings: [
                .text(commandID.uuidString.lowercased()),
                .text(request.operationID.uuidString.lowercased()),
                .text(request.runID.description), .text(request.projectID.description),
                .int64(try Self.sqliteGeneration(request.projectGeneration)),
                .text(request.type.rawValue), .text(request.requestedBy),
                .text(request.reason), .text(request.idempotencyKey),
                .text(request.payloadSHA256), .text(timestamp), .text(timestamp),
            ]
        )
        let runState: String
        switch request.type {
        case .checkpoint: runState = "checkpointing"
        case .rollover, .emergencyRollover: runState = "rolling_over"
        case .recover: runState = "recovering"
        }
        let changed = try connection.execute(
            """
            UPDATE autonomous_runs SET active_operation_id=?,state=?,revision=revision+1,updated_at=?
            WHERE run_id=? AND project_id=? AND project_generation=?
              AND state NOT IN ('completed','cancelled','failed_terminal')
              AND (active_operation_id IS NULL OR active_operation_id=?)
            """,
            bindings: [
                .text(request.operationID.uuidString.lowercased()), .text(runState),
                .text(timestamp), .text(request.runID.description),
                .text(request.projectID.description),
                .int64(try Self.sqliteGeneration(request.projectGeneration)),
                .text(request.operationID.uuidString.lowercased()),
            ]
        )
        guard changed == 1 else {
            throw ContinuityCommandQueueError.invalidCommand(
                "run is terminal or already owns a different continuity operation"
            )
        }
        guard let command = try continuityCommandUnlocked(
            commandID: commandID,
            connection: connection
        ) else {
            throw ProjectContextError.integrityFailure("queued continuity command could not be read back")
        }
        return command
    }

    private static let continuityCommandSelect = """
    SELECT command_id,operation_id,run_id,project_id,project_generation,command_type,
           requested_by,reason,state,idempotency_key,payload_sha256,attempt,retry_at,
           last_error_code,last_error_summary,created_at,updated_at
    FROM continuity_commands
    """

    private func continuityCommandUnlocked(
        commandID: UUID,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ContinuityCommand? {
        try connection.first(
            Self.continuityCommandSelect + " WHERE command_id=? LIMIT 1",
            bindings: [.text(commandID.uuidString.lowercased())],
            map: Self.decodeContinuityCommand
        )
    }

    private func continuityCommandByOperationUnlocked(
        operationID: UUID,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ContinuityCommand? {
        try connection.first(
            Self.continuityCommandSelect + " WHERE operation_id=? LIMIT 1",
            bindings: [.text(operationID.uuidString.lowercased())],
            map: Self.decodeContinuityCommand
        )
    }

    private func continuityCommandByOperationOrKeyUnlocked(
        operationID: UUID,
        idempotencyKey: String,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ContinuityCommand? {
        try connection.first(
            Self.continuityCommandSelect + " WHERE operation_id=? OR idempotency_key=? ORDER BY created_at LIMIT 1",
            bindings: [
                .text(operationID.uuidString.lowercased()), .text(idempotencyKey),
            ],
            map: Self.decodeContinuityCommand
        )
    }

    private static func decodeContinuityCommand(
        _ row: ControlPlaneSQLiteRow
    ) throws -> ContinuityCommand {
        guard let commandString = row.text(0), let commandID = UUID(uuidString: commandString),
              let operationString = row.text(1), let operationID = UUID(uuidString: operationString),
              let runString = row.text(2), let runUUID = UUID(uuidString: runString),
              let projectString = row.text(3), let projectUUID = UUID(uuidString: projectString),
              row.int64(4) > 0,
              let typeString = row.text(5), let type = ContinuityCommandType(rawValue: typeString),
              let requestedBy = row.text(6), let reason = row.text(7),
              let stateString = row.text(8), let state = ContinuityCommandState(rawValue: stateString),
              let idempotencyKey = row.text(9), let payloadSHA256 = row.text(10),
              row.int64(11) >= 0,
              let createdAt = row.text(15), let updatedAt = row.text(16) else {
            throw ProjectContextError.integrityFailure("invalid continuity command row")
        }
        return ContinuityCommand(
            commandID: commandID,
            operationID: operationID,
            runID: RunID(runUUID),
            projectID: ProjectID(projectUUID),
            projectGeneration: ProjectGeneration(UInt64(row.int64(4))),
            type: type,
            requestedBy: requestedBy,
            reason: reason,
            state: state,
            idempotencyKey: idempotencyKey,
            payloadSHA256: payloadSHA256,
            attempt: Int(row.int64(11)),
            retryAt: row.text(12),
            lastErrorCode: row.text(13),
            lastErrorSummary: row.text(14),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func validateContinuityCommandRequest(
        _ request: ContinuityCommandRequest
    ) throws {
        try Self.validate(request.projectGeneration)
        let requestedBy = request.requestedBy.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = request.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let idempotencyKey = request.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestedBy == request.requestedBy,
              !requestedBy.isEmpty, requestedBy.utf8.count <= 512 else {
            throw ContinuityCommandQueueError.invalidCommand("requested_by is invalid")
        }
        guard reason == request.reason, !reason.isEmpty, reason.utf8.count <= 2_048 else {
            throw ContinuityCommandQueueError.invalidCommand("reason is invalid")
        }
        guard idempotencyKey == request.idempotencyKey,
              !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 1_024 else {
            throw ContinuityCommandQueueError.invalidCommand("idempotency key is invalid")
        }
        let hashRange = request.payloadSHA256.startIndex..<request.payloadSHA256.endIndex
        guard request.payloadSHA256.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) == hashRange else {
            throw ContinuityCommandQueueError.invalidCommand("payload_sha256 must be lowercase hexadecimal")
        }
    }

    private static let validCommandTransitions: [ContinuityCommandState: Set<ContinuityCommandState>] = [
        .queued: [.claimed, .cancelled],
        .retryWait: [.claimed, .cancelled],
        .claimed: [.running, .queued, .cancelled],
        .running: [.completed, .retryWait, .failed, .cancelled],
        .completed: [],
        .failed: [],
        .cancelled: [],
    ]

    private static let autonomousRunSelect = """
    SELECT run_id,project_id,project_generation,assignment_id,mission,state,continuity_mode,
           provider_id,model_key,active_session_id,active_operation_id,current_work_json,
           completion_request_json,last_error_code,last_error_summary,retry_at,
           continuation_pending,revision,created_at,updated_at
    FROM autonomous_runs
    """

    private static let providerSessionSelect = """
    SELECT session_id,run_id,project_id,project_generation,provider_id,adapter_id,model_key,
           provider_response_id,predecessor_session_id,handoff_id,operation_id,idempotency_key,
           bootstrap_nonce_hash,handoff_sha256,status,accepted,context_capacity,created_at,updated_at
    FROM provider_sessions
    """

    private static let providerTurnSelect = """
    SELECT turn_id,run_id,session_id,operation_id,project_id,project_generation,
           request_kind,idempotency_key,previous_response_id,input_sha256,tool_schema_sha256,
           state,provider_request_id,provider_response_id,usage_json,attempt,retry_at,
           last_error_code,last_error_summary,created_at,updated_at
    FROM provider_turns
    """

    private static let toolInvocationSelect = """
    SELECT invocation_id,turn_id,run_id,session_id,project_id,project_generation,
           provider_call_id,tool_name,replay_class,idempotency_key,arguments_sha256,
           arguments_artifact_id,state,result_sha256,result_summary,last_error_code,
           last_error_summary,created_at,updated_at
    FROM tool_invocations
    """

    private static let validRunTransitions: [AutonomousRunState: Set<AutonomousRunState>] = [
        .awaitingBootstrap: [.cancelRequested],
        .created: [.validating, .paused, .cancelRequested, .failedTerminal],
        .validating: [.ready, .paused, .blockedConfiguration, .failedRecoverable,
                      .cancelRequested, .failedTerminal],
        .ready: [.starting, .paused, .cancelRequested, .failedTerminal],
        .starting: [.running, .waitingProvider, .waitingResource, .retryWait, .paused,
                    .blockedConfiguration, .failedRecoverable, .cancelRequested, .failedTerminal],
        .running: [.running, .checkpointing, .rollingOver, .recovering, .validatingCompletion,
                   .waitingProvider, .waitingResource, .retryWait, .paused,
                   .blockedConfiguration, .failedRecoverable, .cancelRequested,
                   .failedTerminal],
        .checkpointing: [.running, .rollingOver, .recovering, .waitingProvider,
                         .retryWait, .paused, .blockedConfiguration, .failedRecoverable,
                         .cancelRequested, .failedTerminal],
        .rollingOver: [.running, .recovering, .waitingProvider, .waitingResource,
                       .retryWait, .paused, .blockedConfiguration, .failedRecoverable,
                       .cancelRequested, .failedTerminal],
        .recovering: [.running, .ready, .waitingProvider, .waitingResource, .retryWait,
                      .paused, .blockedConfiguration, .failedRecoverable,
                      .cancelRequested, .failedTerminal],
        .validatingCompletion: [.running, .paused, .blockedConfiguration, .failedRecoverable,
                                .cancelRequested, .failedTerminal],
        .waitingProvider: [.recovering, .starting, .running, .retryWait,
                           .paused, .blockedConfiguration, .cancelRequested, .failedTerminal],
        .waitingResource: [.recovering, .starting, .running, .retryWait,
                           .paused, .cancelRequested, .failedTerminal],
        .retryWait: [.recovering, .starting, .running, .waitingProvider,
                     .waitingResource, .paused, .cancelRequested, .failedTerminal],
        .paused: [.validating, .ready, .recovering, .validatingCompletion,
                  .cancelRequested, .failedTerminal],
        .blockedConfiguration: [.validating, .recovering, .paused,
                                .cancelRequested, .failedTerminal],
        .failedRecoverable: [.recovering, .retryWait, .paused,
                             .cancelRequested, .failedTerminal],
        .cancelRequested: [.cancelled, .failedTerminal],
        .completed: [],
        .cancelled: [],
        .failedTerminal: [],
    ]

    private static let validProviderTurnTransitions: [ProviderTurnState: Set<ProviderTurnState>] = [
        .intent: [.submitted, .cancelled],
        .submitted: [.streaming, .completed, .ambiguous, .retryWait, .failed, .cancelled],
        .streaming: [.completed, .ambiguous, .retryWait, .failed, .cancelled],
        .ambiguous: [.submitted, .completed, .retryWait, .failed, .cancelled],
        .retryWait: [.submitted, .failed, .cancelled],
        .completed: [],
        .failed: [],
        .cancelled: [],
    ]

    private static let validToolInvocationTransitions: [ToolInvocationState: Set<ToolInvocationState>] = [
        // A reconciler may prove that a durable subsystem completed the effect
        // after the intent commit but before this broker recorded execution.
        .intent: [.executing, .completed, .cancelled, .quarantinedStale],
        .executing: [.completed, .ambiguous, .failed, .cancelled, .quarantinedStale],
        .ambiguous: [.executing, .completed, .failed, .cancelled, .quarantinedStale],
        .failed: [.executing, .cancelled],
        .completed: [],
        .cancelled: [],
        .quarantinedStale: [],
    ]

    private func autonomousRunUnlocked(
        _ runID: RunID,
        connection: ControlPlaneSQLiteConnection
    ) throws -> AutonomousRunRecord? {
        try connection.first(
            Self.autonomousRunSelect + " WHERE run_id=? LIMIT 1",
            bindings: [.text(runID.description)],
            map: Self.decodeAutonomousRun
        )
    }

    private static func decodeAutonomousRun(_ row: ControlPlaneSQLiteRow) throws -> AutonomousRunRecord {
        guard let runString = row.text(0), let runUUID = UUID(uuidString: runString),
              let projectString = row.text(1), let projectUUID = UUID(uuidString: projectString),
              row.int64(2) > 0, let mission = row.text(4),
              let stateString = row.text(5), let state = AutonomousRunState(rawValue: stateString),
              let modeString = row.text(6), let mode = ContinuityMode(rawValue: modeString),
              let specificationJSON = row.text(11), row.int64(17) >= 0,
              let createdAt = row.text(18), let updatedAt = row.text(19) else {
            throw ProjectContextError.integrityFailure("invalid autonomous run row")
        }
        let specification: AutonomousRunSpecification
        if specificationJSON == "{}" {
            specification = AutonomousRunSpecification(allowedTools: [], completionGates: [])
        } else {
            do {
                specification = try JSONDecoder().decode(
                    AutonomousRunSpecification.self,
                    from: Data(specificationJSON.utf8)
                )
            } catch {
                throw ProjectContextError.integrityFailure("invalid autonomous run specification")
            }
        }
        let operationID: UUID?
        if let value = row.text(10) {
            guard let parsed = UUID(uuidString: value) else {
                throw ProjectContextError.integrityFailure("invalid active continuity operation identifier")
            }
            operationID = parsed
        } else {
            operationID = nil
        }
        return AutonomousRunRecord(
            runID: RunID(runUUID),
            projectID: ProjectID(projectUUID),
            projectGeneration: ProjectGeneration(UInt64(row.int64(2))),
            assignmentID: row.text(3),
            mission: mission,
            state: state,
            continuityMode: mode,
            providerID: row.text(7),
            modelKey: row.text(8),
            activeSessionID: row.text(9),
            activeOperationID: operationID,
            specification: specification,
            completionRequestJSON: row.text(12),
            lastErrorCode: row.text(13),
            lastErrorSummary: row.text(14),
            retryAt: row.text(15),
            continuationPending: row.int64(16) == 1,
            revision: UInt64(row.int64(17)),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func runLeaseUnlocked(
        _ runID: RunID,
        connection: ControlPlaneSQLiteConnection
    ) throws -> RunLease? {
        try connection.first(
            """
            SELECT run_id,lease_owner,lease_epoch,acquired_at,renewed_at,expires_at
            FROM run_leases WHERE run_id=? LIMIT 1
            """,
            bindings: [.text(runID.description)],
            map: Self.decodeRunLease
        )
    }

    private func requiredRunLeaseUnlocked(
        _ runID: RunID,
        connection: ControlPlaneSQLiteConnection
    ) throws -> RunLease {
        guard let lease = try runLeaseUnlocked(runID, connection: connection) else {
            throw AutonomyError.leaseRequired
        }
        return lease
    }

    private func verifyRunLeaseUnlocked(
        _ lease: RunLease,
        timestamp: String,
        connection: ControlPlaneSQLiteConnection
    ) throws {
        let current = try requiredRunLeaseUnlocked(lease.runID, connection: connection)
        guard current.ownerID == lease.ownerID, current.epoch == lease.epoch else {
            throw AutonomyError.staleLease
        }
        guard current.expiresAt > timestamp,
              current.expirationDate.map({ $0 > (ISO8601.date(from: timestamp) ?? .distantFuture) }) == true else {
            throw AutonomyError.leaseExpired
        }
    }

    private static func decodeRunLease(_ row: ControlPlaneSQLiteRow) throws -> RunLease {
        guard let runString = row.text(0), let runUUID = UUID(uuidString: runString),
              let owner = row.text(1), row.int64(2) > 0,
              let acquiredAt = row.text(3), let renewedAt = row.text(4), let expiresAt = row.text(5),
              ISO8601.date(from: acquiredAt) != nil, ISO8601.date(from: renewedAt) != nil,
              ISO8601.date(from: expiresAt) != nil else {
            throw ProjectContextError.integrityFailure("invalid run lease row")
        }
        return RunLease(
            runID: RunID(runUUID),
            ownerID: owner,
            epoch: UInt64(row.int64(2)),
            acquiredAt: acquiredAt,
            renewedAt: renewedAt,
            expiresAt: expiresAt
        )
    }

    private struct ProviderSessionIdentity: Equatable {
        let sessionID: String
        let runID: RunID
        let projectID: ProjectID
        let projectGeneration: ProjectGeneration
        let providerID: String
        let adapterID: String
        let modelKey: String
        let providerResponseID: String?
        let predecessorSessionID: String?
        let handoffID: UUID?
        let operationID: UUID?
        let idempotencyKey: String
        let bootstrapNonceSHA256: String?
        let handoffSHA256: String?
        let status: ProviderSessionStatus
        let accepted: Bool
        let contextCapacity: Int?

        init(_ intent: ProviderSessionIntent, providerResponseID: String? = nil) {
            sessionID = intent.sessionID
            runID = intent.runID
            projectID = intent.projectID
            projectGeneration = intent.projectGeneration
            providerID = intent.providerID
            adapterID = intent.adapterID
            modelKey = intent.modelKey
            self.providerResponseID = providerResponseID ?? intent.providerResponseID
            predecessorSessionID = intent.predecessorSessionID
            handoffID = intent.handoffID
            operationID = intent.operationID
            idempotencyKey = intent.idempotencyKey
            bootstrapNonceSHA256 = intent.bootstrapNonceSHA256
            handoffSHA256 = intent.handoffSHA256
            status = intent.status
            accepted = intent.accepted
            contextCapacity = intent.contextCapacity
        }

        init(
            sessionID: String,
            runID: RunID,
            projectID: ProjectID,
            projectGeneration: ProjectGeneration,
            providerID: String,
            adapterID: String,
            modelKey: String,
            providerResponseID: String?,
            predecessorSessionID: String?,
            handoffID: UUID?,
            operationID: UUID?,
            idempotencyKey: String,
            bootstrapNonceSHA256: String?,
            handoffSHA256: String?,
            status: ProviderSessionStatus,
            accepted: Bool,
            contextCapacity: Int?
        ) {
            self.sessionID = sessionID
            self.runID = runID
            self.projectID = projectID
            self.projectGeneration = projectGeneration
            self.providerID = providerID
            self.adapterID = adapterID
            self.modelKey = modelKey
            self.providerResponseID = providerResponseID
            self.predecessorSessionID = predecessorSessionID
            self.handoffID = handoffID
            self.operationID = operationID
            self.idempotencyKey = idempotencyKey
            self.bootstrapNonceSHA256 = bootstrapNonceSHA256
            self.handoffSHA256 = handoffSHA256
            self.status = status
            self.accepted = accepted
            self.contextCapacity = contextCapacity
        }
    }

    private func providerSessionIdentityUnlocked(
        _ sessionID: String,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ProviderSessionIdentity? {
        try connection.first(
            """
            SELECT session_id,run_id,project_id,project_generation,provider_id,adapter_id,model_key,
                   provider_response_id,predecessor_session_id,handoff_id,operation_id,idempotency_key,
                   bootstrap_nonce_hash,handoff_sha256,status,accepted,context_capacity
            FROM provider_sessions WHERE session_id=? LIMIT 1
            """,
            bindings: [.text(sessionID)]
        ) { row in
            guard let storedSessionID = row.text(0),
                  let runString = row.text(1), let runUUID = UUID(uuidString: runString),
                  let projectString = row.text(2), let projectUUID = UUID(uuidString: projectString),
                  row.int64(3) > 0, let providerID = row.text(4), let adapterID = row.text(5),
                  let modelKey = row.text(6), let idempotencyKey = row.text(11),
                  let statusString = row.text(14), let status = ProviderSessionStatus(rawValue: statusString) else {
                throw ProjectContextError.integrityFailure("invalid provider session row")
            }
            let handoffID: UUID?
            if let value = row.text(9) {
                guard let parsed = UUID(uuidString: value) else {
                    throw ProjectContextError.integrityFailure("invalid provider handoff identifier")
                }
                handoffID = parsed
            } else { handoffID = nil }
            let operationID: UUID?
            if let value = row.text(10) {
                guard let parsed = UUID(uuidString: value) else {
                    throw ProjectContextError.integrityFailure("invalid provider operation identifier")
                }
                operationID = parsed
            } else { operationID = nil }
            return ProviderSessionIdentity(
                sessionID: storedSessionID,
                runID: RunID(runUUID),
                projectID: ProjectID(projectUUID),
                projectGeneration: ProjectGeneration(UInt64(row.int64(3))),
                providerID: providerID,
                adapterID: adapterID,
                modelKey: modelKey,
                providerResponseID: row.text(7),
                predecessorSessionID: row.text(8),
                handoffID: handoffID,
                operationID: operationID,
                idempotencyKey: idempotencyKey,
                bootstrapNonceSHA256: row.text(12),
                handoffSHA256: row.text(13),
                status: status,
                accepted: row.int64(15) == 1,
                contextCapacity: row.isNull(16) ? nil : Int(row.int64(16))
            )
        }
    }

    private func providerSessionRecordUnlocked(
        _ sessionID: String,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ProviderSessionRecord? {
        try connection.first(
            Self.providerSessionSelect + " WHERE session_id=? LIMIT 1",
            bindings: [.text(sessionID)],
            map: Self.decodeProviderSession
        )
    }

    private func providerSessionForAcceptedOperationUnlocked(
        _ operationID: UUID,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ProviderSessionRecord? {
        try connection.first(
            Self.providerSessionSelect
                + " WHERE operation_id=? AND accepted=1 AND status='active' LIMIT 1",
            bindings: [.text(operationID.uuidString.lowercased())],
            map: Self.decodeProviderSession
        )
    }

    private static func decodeProviderSession(
        _ row: ControlPlaneSQLiteRow
    ) throws -> ProviderSessionRecord {
        guard let sessionID = row.text(0),
              let runString = row.text(1), let runUUID = UUID(uuidString: runString),
              let projectString = row.text(2), let projectUUID = UUID(uuidString: projectString),
              row.int64(3) > 0,
              let providerID = row.text(4), let adapterID = row.text(5),
              let modelKey = row.text(6), let idempotencyKey = row.text(11),
              let statusRaw = row.text(14), let status = ProviderSessionStatus(rawValue: statusRaw),
              let createdAt = row.text(17), let updatedAt = row.text(18),
              ISO8601.date(from: createdAt) != nil, ISO8601.date(from: updatedAt) != nil else {
            throw ProjectContextError.integrityFailure("invalid provider session row")
        }
        let handoffID = try row.text(9).map { value -> UUID in
            guard let parsed = UUID(uuidString: value) else {
                throw ProjectContextError.integrityFailure("invalid provider handoff identifier")
            }
            return parsed
        }
        let operationID = try row.text(10).map { value -> UUID in
            guard let parsed = UUID(uuidString: value) else {
                throw ProjectContextError.integrityFailure("invalid provider operation identifier")
            }
            return parsed
        }
        return ProviderSessionRecord(
            sessionID: sessionID,
            runID: RunID(runUUID),
            projectID: ProjectID(projectUUID),
            projectGeneration: ProjectGeneration(UInt64(row.int64(3))),
            providerID: providerID,
            adapterID: adapterID,
            modelKey: modelKey,
            providerResponseID: row.text(7),
            predecessorSessionID: row.text(8),
            handoffID: handoffID,
            operationID: operationID,
            idempotencyKey: idempotencyKey,
            bootstrapNonceSHA256: row.text(12),
            handoffSHA256: row.text(13),
            status: status,
            accepted: row.int64(15) == 1,
            contextCapacity: row.isNull(16) ? nil : Int(row.int64(16)),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func quarantineProviderSessionUnlocked(
        _ sessionID: String,
        timestamp: String,
        connection: ControlPlaneSQLiteConnection
    ) throws {
        try connection.execute(
            """
            UPDATE provider_sessions SET status='quarantined_duplicate',accepted=0,updated_at=?
            WHERE session_id=? AND status='candidate' AND accepted=0
            """,
            bindings: [.text(timestamp), .text(sessionID)]
        )
        try connection.execute(
            """
            UPDATE project_bindings SET active=0,updated_at=?
            WHERE owner_kind='provider_session' AND owner_id=?
            """,
            bindings: [.text(timestamp), .text(sessionID)]
        )
    }

    private func activateProviderBindingUnlocked(
        sessionID: String,
        run: AutonomousRunRecord,
        timestamp: String,
        connection: ControlPlaneSQLiteConnection
    ) throws {
        try requireNoContinuityIngressHoldUnlocked(run.runID, connection: connection)
        try activateProviderBindingIdentityUnlocked(sessionID: sessionID, run: run, timestamp: timestamp, connection: connection)
    }

    private func activateProviderBindingIdentityUnlocked(sessionID: String, run: AutonomousRunRecord,
        timestamp: String, connection: ControlPlaneSQLiteConnection) throws {
        guard let runBinding = try bindingUnlocked(
            owner: ProjectBindingOwner(kind: .autonomousRun, id: run.runID.description),
            includeInactive: false,
            connection: connection
        ) else {
            throw AutonomyError.invalidRequest("autonomous run binding is missing")
        }
        let owner = ProjectBindingOwner(kind: .providerSession, id: sessionID)
        if let existing = try bindingUnlocked(owner: owner, includeInactive: true, connection: connection) {
            guard existing.projectID == run.projectID,
                  existing.projectGeneration == run.projectGeneration,
                  existing.runID == run.runID else {
                throw ProjectContextError.ownerAlreadyBound(owner)
            }
            try connection.execute(
                """
                UPDATE project_bindings SET authorization_scope_json=?,active=1,updated_at=?
                WHERE owner_kind='provider_session' AND owner_id=?
                """,
                bindings: [
                    .text(try Self.scopeJSON(runBinding.authorizationScope)),
                    .text(timestamp), .text(sessionID),
                ]
            )
        } else {
            try connection.execute(
                """
                INSERT INTO project_bindings(
                    binding_id,owner_kind,owner_id,project_id,project_generation,run_id,
                    authorization_scope_json,active,created_at,updated_at
                ) VALUES(?,'provider_session',?,?,?,?,?,1,?,?)
                """,
                bindings: [
                    .text(UUID().uuidString.lowercased()), .text(sessionID),
                    .text(run.projectID.description),
                    .int64(try Self.sqliteGeneration(run.projectGeneration)),
                    .text(run.runID.description),
                    .text(try Self.scopeJSON(runBinding.authorizationScope)),
                    .text(timestamp), .text(timestamp),
                ]
            )
        }
    }

    private func automaticContinuationIntentUnlocked(
        acceptance: ContinuitySuccessorAcceptance,
        winner: ProviderSessionRecord,
        previousResponseID: String,
        timestamp: String,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ProviderTurnRecord {
        try automaticContinuationIntentUnlocked(operationID: acceptance.operationID, runID: acceptance.runID,
            projectID: acceptance.projectID, projectGeneration: acceptance.projectGeneration,
            handoffID: acceptance.handoffID, handoffSHA256: acceptance.handoffSHA256,
            bootstrapNonceSHA256: acceptance.bootstrapNonceSHA256, idempotencyKey: acceptance.automaticContinuationIdempotencyKey,
            inputSHA256: acceptance.automaticContinuationInputSHA256, winner: winner, previousResponseID: previousResponseID,
            timestamp: timestamp, connection: connection)
    }

    private func automaticContinuationIntentUnlocked(operationID: UUID, runID: RunID, projectID: ProjectID,
        projectGeneration: ProjectGeneration, handoffID: UUID, handoffSHA256: String, bootstrapNonceSHA256: String,
        idempotencyKey: String, inputSHA256: String, winner: ProviderSessionRecord, previousResponseID: String,
        timestamp: String, connection: ControlPlaneSQLiteConnection) throws -> ProviderTurnRecord {
        guard winner.operationID == operationID,
              winner.handoffID == handoffID,
              winner.handoffSHA256 == handoffSHA256,
              winner.bootstrapNonceSHA256 == bootstrapNonceSHA256 else {
            throw AutonomyError.intentConflict
        }
        if let existing = try providerTurnForOperationUnlocked(
            operationID: operationID,
            kind: .automaticContinuation,
            connection: connection
        ) {
            guard existing.intent.runID == runID,
                  existing.intent.sessionID == winner.sessionID,
                  existing.intent.projectID == projectID,
                  existing.intent.projectGeneration == projectGeneration,
                  existing.intent.idempotencyKey == idempotencyKey,
                  existing.intent.previousResponseID == previousResponseID,
                  existing.intent.inputSHA256 == inputSHA256 else {
                throw AutonomyError.intentConflict
            }
            return existing
        }
        let turnID = UUID()
        try connection.execute(
            """
            INSERT INTO provider_turns(
                turn_id,run_id,session_id,operation_id,project_id,project_generation,
                request_kind,idempotency_key,previous_response_id,input_sha256,
                state,attempt,created_at,updated_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,'intent',0,?,?)
            """,
            bindings: [
                .text(turnID.uuidString.lowercased()), .text(runID.description),
                .text(winner.sessionID), .text(operationID.uuidString.lowercased()),
                .text(projectID.description),
                .int64(try Self.sqliteGeneration(projectGeneration)),
                .text(ProviderTurnKind.automaticContinuation.rawValue),
                .text(idempotencyKey),
                .text(previousResponseID),
                .text(inputSHA256),
                .text(timestamp), .text(timestamp),
            ]
        )
        guard let inserted = try providerTurnUnlocked(turnID, connection: connection) else {
            throw ProjectContextError.integrityFailure(
                "automatic continuation intent could not be read back"
            )
        }
        return inserted
    }

    /// Provider bindings alone are insufficient authority: rollover fencing deliberately
    /// deactivates the predecessor before the successor is accepted. Enforce the durable
    /// session winner and the run's active pointer at every context acquisition/check.
    private func requireActiveProviderSessionUnlocked(
        owner: ProjectBindingOwner,
        binding: ProjectContextBinding,
        connection: ControlPlaneSQLiteConnection
    ) throws {
        guard owner.kind == .providerSession else { return }
        guard let session = try providerSessionIdentityUnlocked(owner.id, connection: connection),
              session.status == .active,
              session.accepted,
              session.projectID == binding.projectID,
              session.projectGeneration == binding.projectGeneration,
              session.runID == binding.runID,
              let run = try autonomousRunUnlocked(session.runID, connection: connection),
              run.activeSessionID == session.sessionID else {
            throw ProjectContextError.projectContextRequired(owner)
        }
        try requireNoContinuityIngressHoldUnlocked(session.runID, connection: connection)
    }

    private func providerTurnUnlocked(
        _ turnID: UUID,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ProviderTurnRecord? {
        try connection.first(
            Self.providerTurnSelect + " WHERE turn_id=? LIMIT 1",
            bindings: [.text(turnID.uuidString.lowercased())],
            map: Self.decodeProviderTurn
        )
    }

    private func providerTurnBySessionKeyUnlocked(
        sessionID: String,
        idempotencyKey: String,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ProviderTurnRecord? {
        try connection.first(
            Self.providerTurnSelect + " WHERE session_id=? AND idempotency_key=? LIMIT 1",
            bindings: [.text(sessionID), .text(idempotencyKey)],
            map: Self.decodeProviderTurn
        )
    }

    private func providerTurnForOperationUnlocked(
        operationID: UUID,
        kind: ProviderTurnKind,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ProviderTurnRecord? {
        try connection.first(
            Self.providerTurnSelect
                + " WHERE operation_id=? AND request_kind=? ORDER BY created_at LIMIT 1",
            bindings: [
                .text(operationID.uuidString.lowercased()), .text(kind.rawValue),
            ],
            map: Self.decodeProviderTurn
        )
    }

    private static func decodeProviderTurn(_ row: ControlPlaneSQLiteRow) throws -> ProviderTurnRecord {
        guard let turnString = row.text(0), let turnID = UUID(uuidString: turnString),
              let runString = row.text(1), let runUUID = UUID(uuidString: runString),
              let sessionID = row.text(2),
              let projectString = row.text(4), let projectUUID = UUID(uuidString: projectString),
              row.int64(5) > 0, let kindString = row.text(6), let kind = ProviderTurnKind(rawValue: kindString),
              let key = row.text(7), let inputSHA = row.text(9),
              let stateString = row.text(11), let state = ProviderTurnState(rawValue: stateString),
              row.int64(15) >= 0, let createdAt = row.text(19), let updatedAt = row.text(20) else {
            throw ProjectContextError.integrityFailure("invalid provider turn row")
        }
        let operationID = try row.text(3).map {
            guard let value = UUID(uuidString: $0) else {
                throw ProjectContextError.integrityFailure("invalid provider turn operation identifier")
            }
            return value
        }
        let storedIntent = ProviderTurnIntentRecord(
            turnID: turnID,
            runID: RunID(runUUID),
            sessionID: sessionID,
            operationID: operationID,
            projectID: ProjectID(projectUUID),
            projectGeneration: ProjectGeneration(UInt64(row.int64(5))),
            kind: kind,
            idempotencyKey: key,
            previousResponseID: row.text(8),
            inputSHA256: inputSHA,
            toolSchemaSHA256: row.text(10)
        )
        return ProviderTurnRecord(
            intent: storedIntent,
            state: state,
            providerRequestID: row.text(12),
            providerResponseID: row.text(13),
            usageJSON: row.text(14),
            attempt: Int(row.int64(15)),
            retryAt: row.text(16),
            lastErrorCode: row.text(17),
            lastErrorSummary: row.text(18),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func providerTurn(_ stored: ProviderTurnRecord, matches intent: ProviderTurnIntent) -> Bool {
        let value = stored.intent
        return value.turnID == intent.turnID && value.runID == intent.runID
            && value.sessionID == intent.sessionID && value.operationID == intent.operationID
            && value.projectID == intent.projectID && value.projectGeneration == intent.projectGeneration
            && value.kind == intent.kind && value.idempotencyKey == intent.idempotencyKey
            && value.previousResponseID == intent.previousResponseID
            && value.inputSHA256 == intent.inputSHA256 && value.toolSchemaSHA256 == intent.toolSchemaSHA256
    }

    private func toolInvocationUnlocked(
        _ invocationID: UUID,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ToolInvocationRecord? {
        try connection.first(
            Self.toolInvocationSelect + " WHERE invocation_id=? LIMIT 1",
            bindings: [.text(invocationID.uuidString.lowercased())],
            map: Self.decodeToolInvocation
        )
    }

    private func toolInvocationByProviderCallUnlocked(
        sessionID: String,
        providerCallID: String,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ToolInvocationRecord? {
        try connection.first(
            Self.toolInvocationSelect + " WHERE session_id=? AND provider_call_id=? LIMIT 1",
            bindings: [.text(sessionID), .text(providerCallID)],
            map: Self.decodeToolInvocation
        )
    }

    private static func decodeToolInvocation(_ row: ControlPlaneSQLiteRow) throws -> ToolInvocationRecord {
        guard let invocationString = row.text(0), let invocationID = UUID(uuidString: invocationString),
              let turnString = row.text(1), let turnID = UUID(uuidString: turnString),
              let runString = row.text(2), let runUUID = UUID(uuidString: runString),
              let sessionID = row.text(3),
              let projectString = row.text(4), let projectUUID = UUID(uuidString: projectString),
              row.int64(5) > 0, let providerCallID = row.text(6), let toolName = row.text(7),
              let replayString = row.text(8), let replayClass = ToolReplayClass(rawValue: replayString),
              let argumentsSHA = row.text(10),
              let stateString = row.text(12), let state = ToolInvocationState(rawValue: stateString),
              let createdAt = row.text(17), let updatedAt = row.text(18) else {
            throw ProjectContextError.integrityFailure("invalid tool invocation row")
        }
        return ToolInvocationRecord(
            invocationID: invocationID,
            turnID: turnID,
            runID: RunID(runUUID),
            sessionID: sessionID,
            projectID: ProjectID(projectUUID),
            projectGeneration: ProjectGeneration(UInt64(row.int64(5))),
            providerCallID: providerCallID,
            toolName: toolName,
            replayClass: replayClass,
            idempotencyKey: row.text(9),
            argumentsSHA256: argumentsSHA,
            reconciliationDescriptor: row.text(11),
            state: state,
            resultSHA256: row.text(13),
            resultSummary: row.text(14),
            lastErrorCode: row.text(15),
            lastErrorSummary: row.text(16),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func toolInvocation(_ stored: ToolInvocationRecord, matches intent: ToolInvocationIntent) -> Bool {
        stored.invocationID == intent.invocationID && stored.turnID == intent.turnID
            && stored.runID == intent.runID && stored.sessionID == intent.sessionID
            && stored.projectID == intent.projectID
            && stored.projectGeneration == intent.projectGeneration
            && stored.providerCallID == intent.providerCallID && stored.toolName == intent.toolName
            && stored.replayClass == intent.replayClass && stored.idempotencyKey == intent.idempotencyKey
            && stored.argumentsSHA256 == intent.argumentsSHA256
            && stored.reconciliationDescriptor == intent.reconciliationDescriptor
    }

    private func upsertAutonomousRunBindingUnlocked(
        _ request: AutonomousRunRequest,
        timestamp: String,
        connection: ControlPlaneSQLiteConnection
    ) throws {
        let owner = ProjectBindingOwner(kind: .autonomousRun, id: request.runID.description)
        if let existing = try bindingUnlocked(owner: owner, includeInactive: true, connection: connection) {
            guard !existing.active
                    || (existing.projectID == request.projectID
                        && existing.projectGeneration == request.projectGeneration
                        && existing.runID == request.runID
                        && existing.authorizationScope == request.authorizationScope) else {
                throw ProjectContextError.ownerAlreadyBound(owner)
            }
            try connection.execute(
                """
                UPDATE project_bindings SET project_id=?,project_generation=?,run_id=?,
                    authorization_scope_json=?,active=1,updated_at=?
                WHERE owner_kind='autonomous_run' AND owner_id=?
                """,
                bindings: [
                    .text(request.projectID.description),
                    .int64(try Self.sqliteGeneration(request.projectGeneration)),
                    .text(request.runID.description),
                    .text(try Self.scopeJSON(request.authorizationScope)),
                    .text(timestamp), .text(request.runID.description),
                ]
            )
        } else {
            try connection.execute(
                """
                INSERT INTO project_bindings(
                    binding_id,owner_kind,owner_id,project_id,project_generation,run_id,
                    authorization_scope_json,active,created_at,updated_at
                ) VALUES(?,'autonomous_run',?,?,?,?,?,1,?,?)
                """,
                bindings: [
                    .text(UUID().uuidString.lowercased()), .text(request.runID.description),
                    .text(request.projectID.description),
                    .int64(try Self.sqliteGeneration(request.projectGeneration)),
                    .text(request.runID.description),
                    .text(try Self.scopeJSON(request.authorizationScope)),
                    .text(timestamp), .text(timestamp),
                ]
            )
        }
    }

    private func appendAutonomyEventUnlocked(
        runID: RunID?,
        projectID: ProjectID?,
        eventType: String,
        severity: AutonomyEventSeverity,
        summary: String,
        metadata: [String: String],
        connection: ControlPlaneSQLiteConnection
    ) throws {
        guard !eventType.isEmpty, eventType.utf8.count <= 256,
              !summary.isEmpty, summary.utf8.count <= 2_048 else {
            throw AutonomyError.invalidRequest("autonomy event is outside its size bound")
        }
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        guard metadataData.count <= 8 * 1_024,
              let metadataJSON = String(data: metadataData, encoding: .utf8) else {
            throw AutonomyError.invalidRequest("autonomy event metadata exceeds 8192 bytes")
        }
        let eventID = UUID().uuidString.lowercased()
        let timestamp = ISO8601.string(from: clock.now())
        let previous = try connection.scalarText(
            "SELECT event_sha256 FROM autonomy_events ORDER BY sequence DESC LIMIT 1"
        )
        let hash = JSONSupport.sha256Hex(
            [eventID, runID?.description ?? "", projectID?.description ?? "", eventType,
             severity.rawValue, summary, metadataJSON, previous ?? "", timestamp].joined(separator: "|")
        )
        try connection.execute(
            """
            INSERT INTO autonomy_events(
                event_id,run_id,project_id,event_type,severity,summary,metadata_json,
                previous_event_sha256,event_sha256,created_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?)
            """,
            bindings: [
                .text(eventID), .optionalText(runID?.description), .optionalText(projectID?.description),
                .text(eventType), .text(severity.rawValue), .text(summary), .text(metadataJSON),
                .optionalText(previous), .text(hash), .text(timestamp),
            ]
        )
    }

    private static func decodeAutonomyEvent(_ row: ControlPlaneSQLiteRow) throws -> AutonomyEvent {
        guard let eventString = row.text(1), let eventID = UUID(uuidString: eventString),
              let type = row.text(4), let severityString = row.text(5),
              let severity = AutonomyEventSeverity(rawValue: severityString),
              let summary = row.text(6), let metadata = row.text(7),
              let hash = row.text(9), let createdAt = row.text(10) else {
            throw ProjectContextError.integrityFailure("invalid autonomy event row")
        }
        let runID = try row.text(2).map {
            guard let value = UUID(uuidString: $0) else {
                throw ProjectContextError.integrityFailure("invalid event run identifier")
            }
            return RunID(value)
        }
        let projectID = try row.text(3).map {
            guard let value = UUID(uuidString: $0) else {
                throw ProjectContextError.integrityFailure("invalid event project identifier")
            }
            return ProjectID(value)
        }
        return AutonomyEvent(
            sequence: row.int64(0), eventID: eventID, runID: runID, projectID: projectID,
            eventType: type, severity: severity, summary: summary, metadataJSON: metadata,
            previousEventSHA256: row.text(8), eventSHA256: hash, createdAt: createdAt
        )
    }

    private func validateAutonomousRunRequest(_ request: AutonomousRunRequest) throws {
        try Self.validate(request.projectGeneration)
        try Self.validate(request.authorizationScope)
        guard request.mission == request.mission.trimmingCharacters(in: .whitespacesAndNewlines),
              !request.mission.isEmpty, request.mission.utf8.count <= 65_536 else {
            throw AutonomyError.invalidRequest("mission must contain 1 through 65536 trimmed bytes")
        }
        _ = try Self.boundedOptional(request.assignmentID, maximumBytes: 1_024, field: "assignment identifier")
        guard !request.providerID.isEmpty, request.providerID.utf8.count <= 256,
              !request.modelKey.isEmpty, request.modelKey.utf8.count <= 1_024 else {
            throw AutonomyError.invalidRequest("provider and model identifiers are required")
        }
        guard (1...256).contains(request.specification.allowedTools.count),
              Set(request.specification.allowedTools).count == request.specification.allowedTools.count,
              (1...256).contains(request.specification.completionGates.count) else {
            throw AutonomyError.invalidRequest("allowed tools and completion gates must contain 1 through 256 entries")
        }
        for tool in request.specification.allowedTools where tool.isEmpty || tool.utf8.count > 256 {
            throw AutonomyError.invalidRequest("allowed tool identifier is invalid")
        }
        for gate in request.specification.completionGates where gate.isEmpty || gate.utf8.count > 512 {
            throw AutonomyError.invalidRequest("completion gate identifier is invalid")
        }
        guard request.specification.work.evidenceReferences.count <= 256,
              request.specification.work.metadata.count <= 256 else {
            throw AutonomyError.invalidRequest("run work metadata exceeds its bound")
        }
        let encoded = try Self.specificationJSON(request.specification)
        guard encoded.utf8.count <= 128 * 1_024 else {
            throw AutonomyError.invalidRequest("run specification exceeds 131072 bytes")
        }
    }

    private static func validate(_ policy: RunLeasePolicy) throws {
        guard policy.duration >= 1, policy.duration <= 120,
              policy.renewalInterval >= 0.25, policy.renewalInterval < policy.duration,
              policy.maximumDuration >= policy.duration, policy.maximumDuration <= 3_600 else {
            throw AutonomyError.invalidRequest("run lease policy is outside bounded limits")
        }
    }

    private static func validateLeaseOwner(_ ownerID: String) throws {
        guard ownerID == ownerID.trimmingCharacters(in: .whitespacesAndNewlines),
              !ownerID.isEmpty, ownerID.utf8.count <= 512 else {
            throw AutonomyError.invalidRequest("lease owner identifier is invalid")
        }
    }

    private static func validateTransition(_ transition: AutonomousRunTransition) throws {
        guard !transition.eventType.isEmpty, transition.eventType.utf8.count <= 256,
              !transition.eventSummary.isEmpty, transition.eventSummary.utf8.count <= 2_048 else {
            throw AutonomyError.invalidRequest("run transition event is invalid")
        }
        if transition.nextState == .retryWait || transition.nextState == .waitingProvider
            || transition.nextState == .waitingResource {
            guard let retryAt = transition.retryAt, ISO8601.date(from: retryAt) != nil else {
                throw AutonomyError.invalidRequest("waiting transition requires retry_at")
            }
        }
        _ = try boundedOptional(transition.errorCode, maximumBytes: 256, field: "run error code")
        _ = try boundedOptional(transition.errorSummary, maximumBytes: 2_048, field: "run error summary")
    }

    private static func validate(_ intent: RunSideEffectIntent) throws {
        guard !intent.idempotencyKey.isEmpty, intent.idempotencyKey.utf8.count <= 1_024,
              !intent.summary.isEmpty, intent.summary.utf8.count <= 2_048 else {
            throw AutonomyError.invalidRequest("run side-effect intent is invalid")
        }
        try validateSHA256(intent.payloadSHA256, field: "side-effect payload SHA-256")
    }

    private static func validate(_ intent: ProviderSessionIntent) throws {
        try validate(intent.projectGeneration)
        for (name, value, maximum) in [
            ("session", intent.sessionID, 1_024), ("provider", intent.providerID, 256),
            ("adapter", intent.adapterID, 256), ("model", intent.modelKey, 1_024),
            ("idempotency", intent.idempotencyKey, 1_024),
        ] where value.isEmpty || value.utf8.count > maximum {
            throw AutonomyError.invalidRequest("\(name) identifier is invalid")
        }
        if let capacity = intent.contextCapacity, capacity <= 0 {
            throw AutonomyError.invalidRequest("context capacity must be positive")
        }
        if let hash = intent.bootstrapNonceSHA256 {
            try validateSHA256(hash, field: "bootstrap nonce SHA-256")
        }
        if let hash = intent.handoffSHA256 {
            try validateSHA256(hash, field: "handoff SHA-256")
        }
        let hasReceiptProvenance = intent.handoffID != nil
            && intent.operationID != nil
            && intent.predecessorSessionID != nil
            && intent.providerResponseID != nil
            && intent.bootstrapNonceSHA256 != nil
            && intent.handoffSHA256 != nil
        if intent.status == .candidate && (!hasReceiptProvenance || intent.accepted) {
            throw AutonomyError.invalidRequest(
                "a successor candidate requires complete unaccepted V2 receipt provenance"
            )
        }
        if intent.accepted && intent.status != .active {
            throw AutonomyError.invalidRequest("only an active provider session can be accepted")
        }
    }

    private static func validate(_ acceptance: ContinuitySuccessorAcceptance) throws {
        try validate(acceptance.projectGeneration)
        for (name, value, maximum) in [
            ("predecessor session", acceptance.predecessorSessionID, 1_024),
            ("candidate session", acceptance.candidateSessionID, 1_024),
            ("automatic continuation idempotency", acceptance.automaticContinuationIdempotencyKey, 1_024),
        ] where value.isEmpty || value.utf8.count > maximum {
            throw AutonomyError.invalidRequest("\(name) is invalid")
        }
        guard acceptance.predecessorSessionID != acceptance.candidateSessionID else {
            throw AutonomyError.invalidRequest("continuity successor must be a fresh session")
        }
        try validateSHA256(acceptance.handoffSHA256, field: "handoff SHA-256")
        try validateSHA256(acceptance.bootstrapNonceSHA256, field: "bootstrap nonce SHA-256")
        try validateSHA256(
            acceptance.automaticContinuationInputSHA256,
            field: "automatic continuation input SHA-256"
        )
    }

    private static func validate(_ intent: ProviderTurnIntent) throws {
        try validate(intent.projectGeneration)
        guard !intent.sessionID.isEmpty, intent.sessionID.utf8.count <= 1_024,
              !intent.idempotencyKey.isEmpty, intent.idempotencyKey.utf8.count <= 1_024 else {
            throw AutonomyError.invalidRequest("provider turn identity is invalid")
        }
        try validateSHA256(intent.inputSHA256, field: "provider input SHA-256")
        if let toolHash = intent.toolSchemaSHA256 {
            try validateSHA256(toolHash, field: "provider tool schema SHA-256")
        }
    }

    private static func validate(_ intent: ToolInvocationIntent) throws {
        try validate(intent.projectGeneration)
        guard !intent.sessionID.isEmpty, intent.sessionID.utf8.count <= 1_024,
              !intent.providerCallID.isEmpty, intent.providerCallID.utf8.count <= 1_024,
              !intent.toolName.isEmpty, intent.toolName.utf8.count <= 256 else {
            throw AutonomyError.invalidRequest("tool invocation identity is invalid")
        }
        if intent.replayClass == .idempotent,
           intent.idempotencyKey?.isEmpty != false {
            throw AutonomyError.invalidRequest("idempotent tool invocation requires an idempotency key")
        }
        if let key = intent.idempotencyKey, key.utf8.count > 1_024 {
            throw AutonomyError.invalidRequest("tool idempotency key exceeds 1024 bytes")
        }
        if let descriptor = intent.reconciliationDescriptor,
           descriptor.utf8.count > 8_192 {
            throw AutonomyError.invalidRequest(
                "tool reconciliation descriptor exceeds 8192 bytes"
            )
        }
        try validateSHA256(intent.argumentsSHA256, field: "tool arguments SHA-256")
    }

    private static func validateSHA256(_ value: String, field: String) throws {
        let range = value.startIndex..<value.endIndex
        guard value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == range else {
            throw AutonomyError.invalidRequest("\(field) must be lowercase hexadecimal")
        }
    }

    private static func specificationJSON(_ specification: AutonomousRunSpecification) throws -> String {
        String(decoding: try sortedJSONEncoder.encode(specification), as: UTF8.self)
    }

    private static var sortedJSONEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func validCompletionReceipt(_ receipt: CompletionValidationReceipt) throws -> Bool {
        guard ISO8601.date(from: receipt.validatedAt) != nil else { return false }
        guard try sortedJSONEncoder.encode(receipt).count <= 4 * 1_048_576 else { return false }
        try validateSHA256(receipt.proofSHA256, field: "completion proof SHA-256")
        return receipt.hasValidProof()
    }

    @discardableResult
    private func appendEventUnlocked(
        projectID: ProjectID,
        eventType: String,
        severity: String,
        summary: String,
        metadata: [String: String],
        connection: ControlPlaneSQLiteConnection
    ) throws -> String {
        let eventID = UUID().uuidString.lowercased()
        let timestamp = ISO8601.string(from: clock.now())
        let metadataJSON = try Self.canonicalEventMetadata(metadata)
        let previous = try connection.scalarText(
            "SELECT event_sha256 FROM autonomy_events ORDER BY sequence DESC LIMIT 1"
        )
        let hash = JSONSupport.sha256Hex(
            [eventID, projectID.description, eventType, severity, summary, metadataJSON, previous ?? "", timestamp]
                .joined(separator: "|")
        )
        try connection.execute(
            """
            INSERT INTO autonomy_events(
                event_id,project_id,event_type,severity,summary,metadata_json,
                previous_event_sha256,event_sha256,created_at
            ) VALUES(?,?,?,?,?,?,?,?,?)
            """,
            bindings: [
                .text(eventID), .text(projectID.description), .text(eventType), .text(severity),
                .text(summary), .text(metadataJSON), .optionalText(previous), .text(hash), .text(timestamp),
            ]
        )
        return eventID
    }

    private func stageTransitionAuthorityUnlocked(
        _ identity: ProjectTransitionAuthorityIdentity,
        timestamp: String,
        connection: ControlPlaneSQLiteConnection
    ) throws {
        guard let projectUUID = UUID(uuidString: identity.projectID) else {
            throw ProjectContextError.integrityFailure(
                "project transition authority has an invalid project identifier"
            )
        }
        let projectID = ProjectID(projectUUID)
        if let existing = try transitionAuthorityRecordUnlocked(
            projectID: projectID,
            kind: identity.kind,
            operationID: identity.operationID,
            connection: connection
        ) {
            guard existing.identity == identity, existing.state == .staged else {
                throw ProjectContextError.projectTransitionConflict(projectID)
            }
            return
        }
        let stagedOperation = try connection.scalarText(
            """
            SELECT operation_id FROM project_transition_authority
            WHERE project_id=? AND state='staged' LIMIT 1
            """,
            bindings: [.text(projectID.description)]
        )
        guard stagedOperation == nil else {
            throw ProjectContextError.projectTransitionConflict(projectID)
        }
        try connection.execute(
            """
            INSERT INTO project_transition_authority(
                project_id,transition_kind,operation_id,prior_generation,new_generation,
                target_root_sha256,repository_identity_sha256,directory_device,directory_inode,
                state,authority_sha256,created_at,published_at
            ) VALUES(?,?,?,?,?,?,?,?,?,'staged',?,?,NULL)
            """,
            bindings: [
                .text(identity.projectID), .text(identity.kind.rawValue),
                .text(identity.operationID), .int64(Int64(identity.priorGeneration)),
                .int64(Int64(identity.newGeneration)), .text(identity.targetRootSHA256),
                .text(identity.repositoryIdentitySHA256), .text(identity.directoryDevice),
                .text(identity.directoryInode), .text(identity.authoritySHA256), .text(timestamp),
            ]
        )
    }

    @discardableResult
    private func requireTransitionAuthorityUnlocked(
        projectID: ProjectID,
        identity: ProjectTransitionAuthorityIdentity,
        state: ProjectTransitionAuthorityState,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ProjectTransitionAuthorityRecord {
        guard identity.projectID == projectID.description,
              let record = try transitionAuthorityRecordUnlocked(
                projectID: projectID,
                kind: identity.kind,
                operationID: identity.operationID,
                connection: connection
              ),
              record.identity == identity,
              record.state == state else {
            throw ProjectContextError.projectTransitionConflict(projectID)
        }
        return record
    }

    private func publishTransitionAuthorityUnlocked(
        projectID: ProjectID,
        identity: ProjectTransitionAuthorityIdentity,
        timestamp: String,
        connection: ControlPlaneSQLiteConnection
    ) throws {
        let staged = try requireTransitionAuthorityUnlocked(
            projectID: projectID,
            identity: identity,
            state: .staged,
            connection: connection
        )
        let changed = try connection.execute(
            """
            UPDATE project_transition_authority
            SET state='published',published_at=?
            WHERE sequence=? AND project_id=? AND transition_kind=? AND operation_id=?
              AND state='staged' AND authority_sha256=?
            """,
            bindings: [
                .text(timestamp), .int64(staged.sequence), .text(projectID.description),
                .text(identity.kind.rawValue), .text(identity.operationID),
                .text(identity.authoritySHA256),
            ]
        )
        guard changed == 1 else {
            throw ProjectContextError.projectTransitionConflict(projectID)
        }
        try connection.execute(
            """
            DELETE FROM project_transition_authority
            WHERE project_id=? AND state='published' AND sequence NOT IN (
                SELECT sequence FROM project_transition_authority
                WHERE project_id=? AND state='published'
                ORDER BY sequence DESC LIMIT ?
            )
            """,
            bindings: [
                .text(projectID.description), .text(projectID.description),
                .int64(Int64(Self.maximumPublishedProjectTransitionAuthoritiesPerProject)),
            ]
        )
    }

    private func transitionAuthorityRecordUnlocked(
        projectID: ProjectID,
        kind: ProjectTransitionAuthorityKind,
        operationID: String,
        connection: ControlPlaneSQLiteConnection
    ) throws -> ProjectTransitionAuthorityRecord? {
        let records = try connection.all(
            """
            SELECT sequence,project_id,transition_kind,operation_id,prior_generation,
                   new_generation,target_root_sha256,repository_identity_sha256,
                   directory_device,directory_inode,state,authority_sha256,created_at,published_at
            FROM project_transition_authority
            WHERE project_id=? AND transition_kind=? AND operation_id=? LIMIT 2
            """,
            bindings: [
                .text(projectID.description), .text(kind.rawValue), .text(operationID),
            ],
            map: { row in
                try Self.decodeTransitionAuthority(row, expectedProjectID: projectID)
            }
        )
        guard records.count <= 1 else {
            throw ProjectContextError.projectTransitionConflict(projectID)
        }
        return records.first
    }

    private static func decodeTransitionAuthority(
        _ row: ControlPlaneSQLiteRow,
        expectedProjectID: ProjectID
    ) throws -> ProjectTransitionAuthorityRecord {
        let sequence = row.int64(0)
        let priorGeneration = row.int64(4)
        let newGeneration = row.int64(5)
        guard sequence > 0,
              let projectID = row.text(1), projectID == expectedProjectID.description,
              let kindValue = row.text(2),
              let kind = ProjectTransitionAuthorityKind(rawValue: kindValue),
              let operationID = row.text(3), isLowercaseSHA256(operationID),
              priorGeneration > 0, newGeneration >= priorGeneration,
              let rootSHA256 = row.text(6), isLowercaseSHA256(rootSHA256),
              let repositorySHA256 = row.text(7), isLowercaseSHA256(repositorySHA256),
              let directoryDevice = row.text(8),
              let device = UInt64(directoryDevice), device > 0,
              directoryDevice == String(device),
              let directoryInode = row.text(9),
              let inode = UInt64(directoryInode), inode > 0,
              directoryInode == String(inode),
              let stateValue = row.text(10),
              let state = ProjectTransitionAuthorityState(rawValue: stateValue),
              let storedAuthoritySHA256 = row.text(11),
              isLowercaseSHA256(storedAuthoritySHA256),
              let createdAt = row.text(12), ISO8601.date(from: createdAt) != nil else {
            throw ProjectContextError.projectTransitionConflict(expectedProjectID)
        }
        let publishedAt = row.text(13)
        guard (state == .staged && publishedAt == nil)
                || (state == .published
                    && publishedAt.flatMap(ISO8601.date(from:)) != nil) else {
            throw ProjectContextError.projectTransitionConflict(expectedProjectID)
        }
        let identity = projectTransitionAuthorityIdentity(
            kind: kind,
            projectID: expectedProjectID,
            operationID: operationID,
            priorGeneration: ProjectGeneration(UInt64(priorGeneration)),
            newGeneration: ProjectGeneration(UInt64(newGeneration)),
            targetRootSHA256: rootSHA256,
            repositoryIdentitySHA256: repositorySHA256,
            directoryIdentity: ProjectDirectoryIdentity(device: device, inode: inode)
        )
        guard identity.authoritySHA256 == storedAuthoritySHA256 else {
            throw ProjectContextError.projectTransitionConflict(expectedProjectID)
        }
        return ProjectTransitionAuthorityRecord(
            sequence: sequence,
            identity: identity,
            state: state,
            createdAt: createdAt,
            publishedAt: publishedAt
        )
    }

    private static func projectTransitionAuthorityIdentity(
        kind: ProjectTransitionAuthorityKind,
        projectID: ProjectID,
        operationID: String,
        priorGeneration: ProjectGeneration,
        newGeneration: ProjectGeneration,
        root: URL,
        repositoryFingerprint: String?,
        directoryIdentity: ProjectDirectoryIdentity
    ) -> ProjectTransitionAuthorityIdentity {
        projectTransitionAuthorityIdentity(
            kind: kind,
            projectID: projectID,
            operationID: operationID,
            priorGeneration: priorGeneration,
            newGeneration: newGeneration,
            targetRootSHA256: JSONSupport.sha256Hex(root.path),
            repositoryIdentitySHA256: JSONSupport.sha256Hex(repositoryFingerprint ?? ""),
            directoryIdentity: directoryIdentity
        )
    }

    private static func projectTransitionAuthorityIdentity(
        kind: ProjectTransitionAuthorityKind,
        projectID: ProjectID,
        operationID: String,
        priorGeneration: ProjectGeneration,
        newGeneration: ProjectGeneration,
        targetRootSHA256: String,
        repositoryIdentitySHA256: String,
        directoryIdentity: ProjectDirectoryIdentity
    ) -> ProjectTransitionAuthorityIdentity {
        let immutableFields = [
            "project-transition-authority-v1",
            projectID.description,
            kind.rawValue,
            operationID,
            String(priorGeneration.rawValue),
            String(newGeneration.rawValue),
            targetRootSHA256,
            repositoryIdentitySHA256,
            String(directoryIdentity.device),
            String(directoryIdentity.inode),
        ]
        return ProjectTransitionAuthorityIdentity(
            projectID: projectID.description,
            kind: kind,
            operationID: operationID,
            priorGeneration: priorGeneration.rawValue,
            newGeneration: newGeneration.rawValue,
            targetRootSHA256: targetRootSHA256,
            repositoryIdentitySHA256: repositoryIdentitySHA256,
            directoryDevice: String(directoryIdentity.device),
            directoryInode: String(directoryIdentity.inode),
            authoritySHA256: JSONSupport.sha256Hex(immutableFields.joined(separator: "\u{0}"))
        )
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        let range = value.startIndex..<value.endIndex
        return value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == range
    }

    private static func canonicalEventMetadata(
        _ metadata: [String: String]
    ) throws -> String {
        let metadataData = try JSONSerialization.data(
            withJSONObject: metadata.sorted { $0.key < $1.key }.reduce(
                into: [String: String]()
            ) { result, element in
                result[element.key] = element.value
            },
            options: [.sortedKeys]
        )
        guard metadataData.count <= 2_048,
              let metadataJSON = String(data: metadataData, encoding: .utf8) else {
            throw ProjectContextError.databaseFailure(
                "event metadata exceeds the bounded payload"
            )
        }
        return metadataJSON
    }

    private static func decodeProject(_ row: ControlPlaneSQLiteRow) throws -> ProjectControlRecord {
        guard let projectIDString = row.text(0),
              let projectUUID = UUID(uuidString: projectIDString),
              let displayName = row.text(1),
              let root = row.text(2),
              let lifecycleString = row.text(4),
              let lifecycle = ProjectLifecycleState(rawValue: lifecycleString),
              let createdAt = row.text(7),
              let updatedAt = row.text(8) else {
            throw ProjectContextError.integrityFailure("invalid project row")
        }
        let generationValue = row.int64(3)
        guard generationValue > 0 else {
            throw ProjectContextError.integrityFailure("invalid stored project generation")
        }
        return ProjectControlRecord(
            projectID: ProjectID(projectUUID),
            displayName: displayName,
            canonicalRoot: URL(fileURLWithPath: root).standardizedFileURL,
            generation: ProjectGeneration(UInt64(generationValue)),
            lifecycleState: lifecycle,
            repositoryFingerprint: row.text(5),
            bookmarkReference: row.text(6),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func decodeBinding(_ row: ControlPlaneSQLiteRow) throws -> ProjectContextBinding {
        guard let bindingString = row.text(0),
              let bindingID = UUID(uuidString: bindingString),
              let ownerKindString = row.text(1),
              let ownerKind = ProjectBindingOwnerKind(rawValue: ownerKindString),
              let ownerID = row.text(2),
              let projectString = row.text(3),
              let projectUUID = UUID(uuidString: projectString),
              let scopeString = row.text(6),
              let createdAt = row.text(10),
              let updatedAt = row.text(11) else {
            throw ProjectContextError.integrityFailure("invalid project binding row")
        }
        let scope = try scope(from: scopeString)
        let generationValue = row.int64(4)
        guard generationValue > 0 else {
            throw ProjectContextError.integrityFailure("invalid stored binding generation")
        }
        let runID: RunID?
        if let runString = row.text(5) {
            guard let runUUID = UUID(uuidString: runString) else {
                throw ProjectContextError.integrityFailure("invalid stored run identifier")
            }
            runID = RunID(runUUID)
        } else {
            runID = nil
        }
        return ProjectContextBinding(
            bindingID: bindingID,
            owner: ProjectBindingOwner(kind: ownerKind, id: ownerID),
            projectID: ProjectID(projectUUID),
            projectGeneration: ProjectGeneration(UInt64(generationValue)),
            runID: runID,
            authorizationScope: scope,
            leaseOwner: row.text(7),
            leaseExpiresAt: row.text(8),
            active: row.int64(9) == 1,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func canonicalRoot(_ root: URL) throws -> URL {
        let value = root.standardizedFileURL
        guard value.isFileURL, value.path.hasPrefix("/"), value.path.utf8.count <= 4_096 else {
            throw ProjectContextError.invalidIdentifier("canonical project root")
        }
        return value
    }

    private static func validatedTransitionOperationID(
        _ value: String?,
        required: Bool
    ) throws -> String? {
        guard let value else {
            if required {
                throw ProjectContextError.invalidIdentifier(
                    "project transition operation identifier"
                )
            }
            return nil
        }
        let range = value.startIndex..<value.endIndex
        guard value.range(of: "^[0-9a-f]{64}$", options: .regularExpression)
                == range else {
            throw ProjectContextError.invalidIdentifier(
                "project transition operation identifier"
            )
        }
        return value
    }

    private static func projectTransitionMetadata(
        operationID: String,
        priorGeneration: ProjectGeneration,
        newGeneration: ProjectGeneration,
        root: URL,
        repositoryFingerprint: String?,
        directoryIdentity: ProjectDirectoryIdentity
    ) -> [String: String] {
        [
            "operation_id": operationID,
            "prior_generation": String(priorGeneration.rawValue),
            "new_generation": String(newGeneration.rawValue),
            "target_root_sha256": JSONSupport.sha256Hex(root.path),
            "repository_identity_sha256": JSONSupport.sha256Hex(
                repositoryFingerprint ?? ""
            ),
            "directory_device": String(directoryIdentity.device),
            "directory_inode": String(directoryIdentity.inode),
        ]
    }

    private static func validateDirectoryIdentity(
        _ root: URL,
        expected: ProjectDirectoryIdentity,
        failure: ProjectContextError
    ) throws {
        var information = stat()
        let matches = root.path.withCString { path in
            Darwin.lstat(path, &information) == 0
                && information.st_mode & S_IFMT == S_IFDIR
                && UInt64(information.st_dev) == expected.device
                && UInt64(information.st_ino) == expected.inode
        }
        guard matches else {
            throw failure
        }
    }

    private static func validate(_ owner: ProjectBindingOwner) throws {
        let id = owner.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id == owner.id, id.utf8.count <= 1_024 else {
            throw ProjectContextError.invalidIdentifier("binding owner")
        }
    }

    private static func validate(_ generation: ProjectGeneration) throws {
        guard generation.rawValue > 0, generation.rawValue <= UInt64(Int64.max) else {
            throw ProjectContextError.invalidGeneration(generation.rawValue)
        }
    }

    private static func validate(_ scope: ToolAuthorizationScope) throws {
        guard !scope.canonicalRoots.isEmpty, scope.canonicalRoots.count <= 32 else {
            throw ProjectContextError.invalidAuthorizationScope("canonical roots must contain 1 through 32 entries")
        }
        guard scope.writableRoots.count <= 32 else {
            throw ProjectContextError.invalidAuthorizationScope(
                "writable roots must contain no more than 32 entries"
            )
        }
        guard scope.allowedTools.count <= 256 else {
            throw ProjectContextError.invalidAuthorizationScope("too many allowed tools")
        }
        guard (1...16 * 1_024 * 1_024).contains(scope.maximumInlineOutputBytes) else {
            throw ProjectContextError.invalidAuthorizationScope("inline output limit is outside the supported range")
        }
        let readRoots = try scope.canonicalRoots.map(canonicalRoot)
        for root in scope.writableRoots {
            let writable = try canonicalRoot(root)
            guard readRoots.contains(where: { contains(writable, root: $0) }) else {
                throw ProjectContextError.invalidAuthorizationScope(
                    "each writable root must be contained by a canonical read root"
                )
            }
        }
        for tool in scope.allowedTools {
            guard !tool.isEmpty, tool.utf8.count <= 256 else {
                throw ProjectContextError.invalidAuthorizationScope("invalid tool name")
            }
        }
    }

    private static func owner(
        _ owner: ProjectBindingOwner,
        matches context: ToolInvocationContext
    ) -> Bool {
        switch owner.kind {
        case .mcpClient:
            context.clientID.rawValue == owner.id
        case .providerSession:
            context.providerSessionID == owner.id
        case .runtimeJob:
            context.runtimeJobID?.uuidString.lowercased() == owner.id.lowercased()
        case .agentSession, .autonomousRun, .guiSelection:
            true
        }
    }

    private static func sqliteGeneration(_ generation: ProjectGeneration) throws -> Int64 {
        try validate(generation)
        return Int64(generation.rawValue)
    }

    private static func boundedOptional(
        _ value: String?,
        maximumBytes: Int,
        field: String
    ) throws -> String? {
        guard let value else { return nil }
        guard value.utf8.count <= maximumBytes else {
            throw ProjectContextError.invalidIdentifier(field)
        }
        return value
    }

    private struct StoredAuthorizationScope: Codable {
        let canonicalRoots: [String]
        let writableRoots: [String]?
        let allowedTools: [String]
        let networkAllowed: Bool
        let maximumInlineOutputBytes: Int
    }

    private static func scopeJSON(_ scope: ToolAuthorizationScope) throws -> String {
        let stored = StoredAuthorizationScope(
            canonicalRoots: scope.canonicalRoots.map(\.path).sorted(),
            writableRoots: scope.writableRoots.map(\.path).sorted(),
            allowedTools: scope.allowedTools.sorted(),
            networkAllowed: scope.networkAllowed,
            maximumInlineOutputBytes: scope.maximumInlineOutputBytes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(stored), as: UTF8.self)
    }

    private static func scope(from json: String) throws -> ToolAuthorizationScope {
        let stored: StoredAuthorizationScope
        do {
            stored = try JSONDecoder().decode(StoredAuthorizationScope.self, from: Data(json.utf8))
        } catch {
            throw ProjectContextError.integrityFailure("invalid stored authorization scope")
        }
        let scope = ToolAuthorizationScope(
            canonicalRoots: stored.canonicalRoots.map { URL(fileURLWithPath: $0) },
            writableRoots: (stored.writableRoots ?? stored.canonicalRoots).map {
                URL(fileURLWithPath: $0)
            },
            allowedTools: Set(stored.allowedTools),
            networkAllowed: stored.networkAllowed,
            maximumInlineOutputBytes: stored.maximumInlineOutputBytes
        )
        try validate(scope)
        return scope
    }

    private static func contains(_ child: URL, root: URL) -> Bool {
        let childPath = child.path
        let rootPath = root.path
        return childPath == rootPath
            || childPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

private enum ControlPlaneSQLiteBinding {
    case text(String)
    case optionalText(String?)
    case int64(Int64)
    case optionalInt64(Int64?)
}

private enum DelayedResultFenceError: Error {
    case staleGeneration(ProjectGeneration)
}

private struct ControlPlaneSQLiteRow {
    fileprivate let statement: OpaquePointer

    func text(_ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    /// Preserves the entire stored byte sequence for canonical snapshot checks.
    /// A C-string conversion would silently discard an embedded NUL and suffix.
    func strictText(_ index: Int32, maximumBytes: Int) throws -> String? {
        let type = sqlite3_column_type(statement, index)
        if type == SQLITE_NULL { return nil }
        guard type == SQLITE_TEXT else {
            throw ProjectContextError.integrityFailure("invalid SQLite text type at column \(index)")
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count >= 0, count <= maximumBytes,
              let pointer = sqlite3_column_text(statement, index) else {
            throw ProjectContextError.integrityFailure("invalid SQLite text length at column \(index)")
        }
        let bytes = UnsafeBufferPointer(start: pointer, count: count)
        guard !bytes.contains(0), let value = String(bytes: bytes, encoding: .utf8) else {
            throw ProjectContextError.integrityFailure("invalid SQLite text bytes at column \(index)")
        }
        return value
    }

    func int64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }
}

private final class ControlPlaneSQLiteOperationControl {
    private static let busyPollSeconds: TimeInterval = 0.01

    let cancellation: ToolCallCancellation?
    private let busyRetryObserver: (@Sendable () -> Void)?
    private let beforeCommitObserver: (@Sendable () throws -> Void)?
    private let didCommitObserver: (@Sendable () -> Void)?
    private let busyDeadlineUptimeNanoseconds: UInt64
    private var reportedBusy = false
    private var acceptsCancellation = true
    private(set) var committed = false

    init(
        cancellation: ToolCallCancellation?,
        busyTimeoutMilliseconds: Int,
        busyRetryObserver: (@Sendable () -> Void)?,
        beforeCommitObserver: (@Sendable () throws -> Void)?,
        didCommitObserver: (@Sendable () -> Void)?
    ) {
        self.cancellation = cancellation
        self.busyRetryObserver = busyRetryObserver
        self.beforeCommitObserver = beforeCommitObserver
        self.didCommitObserver = didCommitObserver
        let milliseconds = UInt64(max(1, busyTimeoutMilliseconds))
        let delta = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        let boundedDelta = delta.overflow ? UInt64.max : delta.partialValue
        let deadline = DispatchTime.now().uptimeNanoseconds
            .addingReportingOverflow(boundedDelta)
        busyDeadlineUptimeNanoseconds = deadline.overflow ? UInt64.max : deadline.partialValue
    }

    func checkCancellation() throws {
        guard acceptsCancellation else { return }
        try cancellation?.checkCancellation()
    }

    func prepareToCommit() throws {
        try beforeCommitObserver?()
        try checkCancellation()
    }

    func performCommit(_ commit: () throws -> Void) throws {
        try beforeCommitObserver?()
        if let cancellation {
            try cancellation.withCommitAuthorization(commit)
        } else {
            try commit()
        }
        recordCommit()
    }

    func performCommit<Value>(
        committedResult: Value,
        _ commit: () throws -> Void
    ) throws {
        try beforeCommitObserver?()
        if let cancellation {
            try cancellation.withCommitAuthorization(
                committedResult: committedResult,
                commit
            )
        } else {
            try commit()
        }
        recordCommit()
    }

    /// Observation still applies when an already committed external effect
    /// requires finishing its receipt despite late request cancellation.
    func performCommitWithoutCancellation(_ commit: () throws -> Void) throws {
        try beforeCommitObserver?()
        try commit()
        recordCommit()
    }

    func recordCommit() {
        committed = true
        didCommitObserver?()
    }

    func shouldInterrupt() -> Bool {
        acceptsCancellation
            && (cancellation?.isCancelled == true || cancellation?.isDeadlineExceeded == true)
    }

    func finishCancellationWindow() {
        acceptsCancellation = false
    }

    func withCancellationSuppressed<T>(_ body: () throws -> T) rethrows -> T {
        let prior = acceptsCancellation
        acceptsCancellation = false
        defer { acceptsCancellation = prior }
        return try body()
    }

    func waitForBusyRetry() -> Int32 {
        if !reportedBusy {
            reportedBusy = true
            busyRetryObserver?()
        }
        guard !shouldInterrupt() else { return 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < busyDeadlineUptimeNanoseconds else { return 0 }
        let fallbackRemaining = TimeInterval(busyDeadlineUptimeNanoseconds - now) / 1_000_000_000
        let requestRemaining = acceptsCancellation
            ? cancellation?.remainingTimeInterval ?? fallbackRemaining
            : fallbackRemaining
        let delay = min(Self.busyPollSeconds, fallbackRemaining, requestRemaining)
        guard delay > 0 else { return 0 }
        Thread.sleep(forTimeInterval: delay)
        return shouldInterrupt() || DispatchTime.now().uptimeNanoseconds >= busyDeadlineUptimeNanoseconds
            ? 0
            : 1
    }
}

private func controlPlaneSQLiteBusyHandler(
    _ context: UnsafeMutableRawPointer?,
    _ priorAttempts: Int32
) -> Int32 {
    guard let context else { return 0 }
    return Unmanaged<ControlPlaneSQLiteOperationControl>.fromOpaque(context)
        .takeUnretainedValue()
        .waitForBusyRetry()
}

private func controlPlaneSQLiteProgressHandler(_ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    return Unmanaged<ControlPlaneSQLiteOperationControl>.fromOpaque(context)
        .takeUnretainedValue()
        .shouldInterrupt() ? 1 : 0
}

/// This connection is confined to `ProjectControlPlaneRepository`'s actor.
/// Its synchronous transaction closures never suspend or escape that actor.
private final class ControlPlaneSQLiteConnection: @unchecked Sendable {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    // Independent capability lineage: public control schema remains v2, while
    // older decoders reject the new state instead of treating held work as ready.
    static let ingressSchemaCapabilityVersionQuery = """
    SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='autonomous_runs') THEN 0
        WHEN (SELECT instr(sql,'''awaiting_bootstrap''') FROM sqlite_master WHERE type='table' AND name='autonomous_runs')=0 THEN 1
        WHEN EXISTS(SELECT 1 FROM pragma_table_xinfo('native_source_provider_turns')
            WHERE name IN ('pressure_decision_json','pressure_decision_sha256','pressure_reservation_id')) THEN 9
        WHEN EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='native_source_conversations') THEN 8
        WHEN EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='native_task_capabilities') THEN 7
        WHEN EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='continuity_operation_cancellations') THEN 6
        WHEN EXISTS(SELECT 1 FROM pragma_table_info('continuity_ingress_holds') WHERE name='finalization_attempts') THEN 5
        WHEN EXISTS(SELECT 1 FROM pragma_table_info('continuity_ingress_holds') WHERE name='recovery_attempts') THEN 4
        WHEN EXISTS(SELECT 1 FROM pragma_table_info('continuity_ingress_holds') WHERE name='operation_id' AND pk=1) THEN 3
        ELSE 2 END
    """

    private var database: OpaquePointer?
    private let busyTimeoutMilliseconds: Int
    private var activeControl: ControlPlaneSQLiteOperationControl?
    private var transactionDepth = 0

    init(
        databaseURL: URL,
        busyTimeoutMilliseconds: Int,
        migrationTimestamp: String
    ) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite open error"
            if let handle { sqlite3_close_v2(handle) }
            throw ProjectContextError.databaseFailure(message)
        }
        database = handle
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        do {
            guard sqlite3_busy_timeout(handle, Int32(busyTimeoutMilliseconds)) == SQLITE_OK else {
                throw ProjectContextError.databaseFailure("could not configure SQLite busy timeout")
            }
            let priorVersion = try validatedPriorVersion()
            try migrate(timestamp: migrationTimestamp, priorVersion: priorVersion, databaseURL: databaseURL)
            try executeStatic("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path
            )
            let integrity = try scalarText("PRAGMA integrity_check;") ?? "missing"
            guard integrity == "ok" else {
                throw ProjectContextError.integrityFailure(integrity)
            }
        } catch {
            sqlite3_close_v2(handle)
            database = nil
            throw error
        }
    }

    deinit {
        close()
    }

    func close() {
        if let database {
            sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
            sqlite3_close_v2(database)
            self.database = nil
        }
    }

    func withRequestControl<T>(
        cancellation: ToolCallCancellation?,
        busyRetryObserver: (@Sendable () -> Void)? = nil,
        beforeCommitObserver: (@Sendable () throws -> Void)? = nil,
        didCommitObserver: (@Sendable () -> Void)? = nil,
        _ body: () throws -> T
    ) throws -> T {
        if activeControl != nil {
            try cancellation?.checkCancellation()
            return try body()
        }
        let database = try requiredDatabase()
        let control = ControlPlaneSQLiteOperationControl(
            cancellation: cancellation,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds,
            busyRetryObserver: busyRetryObserver,
            beforeCommitObserver: beforeCommitObserver,
            didCommitObserver: didCommitObserver
        )
        try control.checkCancellation()
        activeControl = control
        let context = Unmanaged.passUnretained(control).toOpaque()
        sqlite3_busy_handler(database, controlPlaneSQLiteBusyHandler, context)
        sqlite3_progress_handler(database, 1_000, controlPlaneSQLiteProgressHandler, context)
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            sqlite3_busy_timeout(database, Int32(busyTimeoutMilliseconds))
            activeControl = nil
        }
        do {
            let value = try body()
            if !control.committed {
                try control.checkCancellation()
            }
            return value
        } catch {
            if !control.committed {
                try control.checkCancellation()
            }
            throw error
        }
    }

    func finishRequestCancellationWindow() {
        activeControl?.finishCancellationWindow()
    }

    func transaction<T>(
        cancellation: ToolCallCancellation? = nil,
        busyRetryObserver: (@Sendable () -> Void)? = nil,
        beforeCommitObserver: (@Sendable () throws -> Void)? = nil,
        didCommitObserver: (@Sendable () -> Void)? = nil,
        checkCancellationBeforeCommit: Bool = true,
        fullDurability: Bool = false,
        beforeCommitValidation: (() throws -> Void)? = nil,
        _ body: () throws -> T
    ) throws -> T {
        try withRequestControl(
            cancellation: cancellation,
            busyRetryObserver: busyRetryObserver,
            beforeCommitObserver: beforeCommitObserver,
            didCommitObserver: didCommitObserver
        ) {
            // SQLite forbids changing synchronous inside a transaction. Keep
            // this connection's prior setting for unrelated operations.
            let previousSynchronous: Int?
            if fullDurability {
                guard transactionDepth == 0, sqlite3_get_autocommit(try requiredDatabase()) != 0 else {
                    throw ProjectContextError.integrityFailure("durable acceptance requires its own transaction")
                }
                let previous = try scalarInt("PRAGMA synchronous;")
                guard (0...3).contains(previous) else {
                    throw ProjectContextError.integrityFailure("invalid SQLite synchronous mode")
                }
                previousSynchronous = previous
                try executeStatic("PRAGMA synchronous=FULL;")
            } else { previousSynchronous = nil }
            defer {
                if let previousSynchronous {
                    if let activeControl {
                        try? activeControl.withCancellationSuppressed {
                            try executeStatic("PRAGMA synchronous=\(previousSynchronous);")
                        }
                    } else {
                        try? executeStatic("PRAGMA synchronous=\(previousSynchronous);")
                    }
                }
            }
            try executeStatic("BEGIN IMMEDIATE;")
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            do {
                let value = try body()
                let commit = {
                    try beforeCommitValidation?()
                    try self.executeStatic("COMMIT;")
                }
                if checkCancellationBeforeCommit {
                    if let activeControl {
                        try activeControl.performCommit(committedResult: value) {
                            try commit()
                        }
                    } else {
                        try commit()
                    }
                } else {
                    if let activeControl {
                        try activeControl.performCommitWithoutCancellation(commit)
                    } else {
                        try commit()
                    }
                }
                return value
            } catch {
                try? executeStatic("ROLLBACK;")
                throw error
            }
        }
    }

    @discardableResult
    func execute(
        _ sql: String,
        bindings: [ControlPlaneSQLiteBinding] = []
    ) throws -> Int {
        try withStatement(sql, bindings: bindings) { statement in
            let executeStep = {
                let result = sqlite3_step(statement)
                guard result == SQLITE_DONE else { throw self.mappedError(result) }
            }
            if transactionDepth == 0, let activeControl {
                try activeControl.performCommit(executeStep)
            } else {
                try executeStep()
            }
            return Int(sqlite3_changes(try requiredDatabase()))
        }
    }

    func first<T>(
        _ sql: String,
        bindings: [ControlPlaneSQLiteBinding] = [],
        map: (ControlPlaneSQLiteRow) throws -> T
    ) throws -> T? {
        try withStatement(sql, bindings: bindings) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw mappedError(result) }
            return try map(ControlPlaneSQLiteRow(statement: statement))
        }
    }

    func all<T>(
        _ sql: String,
        bindings: [ControlPlaneSQLiteBinding] = [],
        map: (ControlPlaneSQLiteRow) throws -> T
    ) throws -> [T] {
        try withStatement(sql, bindings: bindings) { statement in
            var values: [T] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return values }
                guard result == SQLITE_ROW else { throw mappedError(result) }
                values.append(try map(ControlPlaneSQLiteRow(statement: statement)))
            }
        }
    }

    func scalarInt(
        _ sql: String,
        bindings: [ControlPlaneSQLiteBinding] = []
    ) throws -> Int {
        try first(sql, bindings: bindings) { Int($0.int64(0)) } ?? 0
    }

    func scalarText(
        _ sql: String,
        bindings: [ControlPlaneSQLiteBinding] = []
    ) throws -> String? {
        try first(sql, bindings: bindings) { $0.text(0) ?? "" }
    }

    private func validatedPriorVersion() throws -> Int {
        let userVersion = try scalarInt("PRAGMA user_version;")
        let hasVersionTable = try scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='control_schema_version'"
        ) == 1
        let storedVersion = hasVersionTable
            ? try scalarInt("SELECT version FROM control_schema_version WHERE singleton=1")
            : 0
        let priorVersion = max(userVersion, storedVersion)
        let schemaObjectCount = try scalarInt(
            "SELECT COUNT(*) FROM sqlite_master"
        )
        if priorVersion == 0 {
            guard schemaObjectCount == 0, !hasVersionTable else {
                throw ProjectContextError.integrityFailure(
                    "nonempty unversioned control-plane database requires explicit recovery"
                )
            }
        } else {
            guard userVersion == ProjectControlPlaneRepository.schemaVersion,
                  hasVersionTable,
                  storedVersion == ProjectControlPlaneRepository.schemaVersion else {
                throw ProjectContextError.unsupportedSchemaVersion(priorVersion)
            }
        }
        guard priorVersion == 0 || priorVersion == ProjectControlPlaneRepository.schemaVersion else {
            throw ProjectContextError.unsupportedSchemaVersion(priorVersion)
        }
        return priorVersion
    }

    private func migrate(timestamp: String, priorVersion: Int, databaseURL: URL) throws {
        let handle = try requiredDatabase()
        let capability = try scalarInt(Self.ingressSchemaCapabilityVersionQuery)
        if capability >= 7 {
            guard try scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('native_task_capabilities','native_task_commands','native_source_requests','native_source_run_offsets')") == 4 else {
                throw ProjectContextError.integrityFailure("incomplete native task capability schema")
            }
        }
        let journalTables = try scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('native_source_conversations','native_source_provider_turns','native_source_provider_calls','native_source_capability_checks','native_source_provider_run_offsets')")
        guard ((8...9).contains(capability) && journalTables == 5) || (capability < 8 && journalTables == 0) else {
            throw ProjectContextError.integrityFailure("incomplete native source journal schema")
        }
        if capability > 0 { try validateSourceDerivedPreflightSchema(hasColumns: capability >= 8) }
        if capability >= 8 { try validateNativeSourcePressureSchema(hasColumns: capability == 9) }
        var manifest = try VerifiedMigrationBackup.reconcileMigrationManifest(sourceURL: databaseURL,
            observedVersion: capability, scope: .continuityIngress)
        // Finish a committed older capability before preparing the next verified
        // lineage. This includes restart after COMMIT but before manifest completion.
        if let previous = manifest, previous.targetVersion == capability {
            manifest = try VerifiedMigrationBackup.requireSQLiteMigrationReceipt(database: handle,
                sourceURL: databaseURL, manifest: previous, scope: .continuityIngress)
            if let prepared = manifest, prepared.state == .prepared {
                try VerifiedMigrationBackup.checkpointSQLiteMigration(database: handle, sourceURL: databaseURL)
                let target = try VerifiedMigrationBackup.logicalSQLiteMetadata(database: handle, sourceURL: databaseURL,
                    expectedVersion: capability, versionQuery: Self.ingressSchemaCapabilityVersionQuery)
                manifest = try VerifiedMigrationBackup.completeMigrationManifest(sourceURL: databaseURL,
                    preparedManifest: prepared, observedVersion: capability, targetMetadata: target, scope: .continuityIngress)
            }
        }
        let upgrading = priorVersion == 2 && (1...8).contains(capability)
        let targetCapability = upgrading ? capability + 1 : 9
        if upgrading { try executeStatic("PRAGMA synchronous=FULL;") }
        defer { if upgrading { try? executeStatic("PRAGMA synchronous=NORMAL;") } }
        try transaction {
            if upgrading {
                let backup = databaseURL.deletingPathExtension().appendingPathExtension("pre-ingress-capability-v\(capability).sqlite3")
                manifest = try VerifiedMigrationBackup.prepareSQLiteMigrationAtWriteBoundary(
                    database: handle, sourceURL: databaseURL, backupURL: backup,
                    sourceVersion: capability, targetVersion: targetCapability,
                    versionQuery: Self.ingressSchemaCapabilityVersionQuery, scope: .continuityIngress)
            }
            if capability == 2 { try rebuildContinuityIngressHoldHistory() }
            if capability == 3 { try addContinuityIngressRecoveryMetadata() }
            if capability == 4 { try addContinuitySourceActivationMetadata() }
            let schema = capability == 1 ? Self.schemaForLegacyIngressMigration
                : (capability == 2 ? Self.schemaForHoldHistoryMigration : (capability == 3 ? Self.schemaForRecoveryMigration : (capability == 4 ? Self.schemaForActivationMigration : (capability == 5 ? Self.schemaForCancellationMigration : (capability == 6 ? Self.schemaForNativeConversationMigration : Self.schemaV2)))))
            try executeStatic(schema)
            if capability == 0 || capability == 7 {
                for column in Self.sourceDerivedPreflightColumns {
                    try executeStatic("ALTER TABLE provider_turns ADD COLUMN " + column + ";")
                }
                try validateSourceDerivedPreflightSchema(hasColumns: true)
            }
            if capability == 0 || capability == 8 {
                for column in NativeSourcePressureSchema.columns {
                    try executeStatic("ALTER TABLE native_source_provider_turns ADD COLUMN " + column + ";")
                }
                try executeStatic(NativeSourcePressureSchema.indexSQL)
                try validateNativeSourcePressureSchema(hasColumns: true)
            }
            if capability == 4 { try populateSourceTaskFencesForMigration(timestamp: timestamp) }
            if capability == 1 { try rebuildAutonomousRunStateConstraint() }
            let quickCheck = try scalarText("PRAGMA quick_check;") ?? "missing"
            guard quickCheck == "ok" else { throw ProjectContextError.integrityFailure(quickCheck) }
            try execute("""
                INSERT INTO control_schema_version(singleton,version,applied_at) VALUES(1,2,?)
                ON CONFLICT(singleton) DO UPDATE SET version=excluded.version,applied_at=excluded.applied_at
                WHERE control_schema_version.version < excluded.version
                """, bindings: [.text(timestamp)])
            try executeStatic("PRAGMA user_version=2;")
            try execute("""
                INSERT OR IGNORE INTO migration_receipts(
                    receipt_id,migration_name,source_version,target_version,integrity_result,
                    details_json,started_at,completed_at
                ) VALUES('control-plane-schema-v2','control-plane-schema',?,'2','ok','{}',?,?)
                """, bindings: [.text(String(priorVersion)), .text(timestamp), .text(timestamp)])
            guard try first("PRAGMA foreign_key_check;", map: { _ in true }) == nil else {
                throw ProjectContextError.integrityFailure("control-plane migration left invalid foreign keys")
            }
            if upgrading, let manifest {
                try VerifiedMigrationBackup.recordSQLiteMigrationReceipt(database: handle, sourceURL: databaseURL, manifest: manifest)
                try VerifiedMigrationBackup.requireSQLiteMainFileUnmoved(database: handle, sourceURL: databaseURL,
                    purpose: "control-plane bootstrap capability migration commit")
            }
        }
        if upgrading, let manifest {
            try VerifiedMigrationBackup.checkpointSQLiteMigration(database: handle, sourceURL: databaseURL)
            let target = try VerifiedMigrationBackup.logicalSQLiteMetadata(database: handle, sourceURL: databaseURL,
                expectedVersion: targetCapability, versionQuery: Self.ingressSchemaCapabilityVersionQuery)
            _ = try VerifiedMigrationBackup.completeMigrationManifest(sourceURL: databaseURL, preparedManifest: manifest,
                observedVersion: targetCapability, targetMetadata: target, scope: .continuityIngress)
        }
        if (1...7).contains(capability) {
            try migrate(timestamp: timestamp, priorVersion: priorVersion, databaseURL: databaseURL)
        }
    }

    private func validateNativeSourcePressureSchema(hasColumns: Bool) throws {
        let valid = try NativeSourcePressureSchema.validate(hasColumns: hasColumns,
            integer: { try self.scalarInt($0) }, text: { sql in
                try self.first(sql, map: { try $0.strictText(0, maximumBytes: 32_768) }) ?? nil
            })
        guard valid else { throw ProjectContextError.integrityFailure("unsupported native source pressure journal extension") }
    }

    private static let sourceDerivedPreflightColumns = [
        "source_preflight_json TEXT CHECK (source_preflight_json IS NULL OR length(CAST(source_preflight_json AS BLOB)) BETWEEN 1 AND 32768)",
        "source_preflight_sha256 TEXT CHECK ((source_preflight_json IS NULL AND source_preflight_sha256 IS NULL) OR (source_preflight_json IS NOT NULL AND source_preflight_sha256 IS NOT NULL AND length(source_preflight_sha256)=64))",
    ]

    private func validateSourceDerivedPreflightSchema(hasColumns: Bool) throws {
        guard let definition = try first("SELECT sql FROM sqlite_master WHERE type='table' AND name='provider_turns'",
            map: { try $0.strictText(0, maximumBytes: 32_768) }) ?? nil,
              let start = Self.schemaV2.range(of: "CREATE TABLE IF NOT EXISTS provider_turns ("),
              let end = Self.schemaV2.range(of: ");", range: start.upperBound..<Self.schemaV2.endIndex) else {
            throw ProjectContextError.integrityFailure("missing source-derived provider ledger schema")
        }
        var normalized = Self.normalizedRunSchemaSQL(definition)
        let base = Self.normalizedRunSchemaSQL(String(Self.schemaV2[start.lowerBound..<end.upperBound]))
        let expected = ["turn_id","run_id","session_id","operation_id","project_id","project_generation",
            "request_kind","idempotency_key","previous_response_id","input_sha256","tool_schema_sha256","state",
            "provider_request_id","provider_response_id","request_artifact_id","result_artifact_id","usage_json",
            "attempt","retry_at","last_error_code","last_error_summary","created_at","updated_at"]
            + (hasColumns ? ["source_preflight_json","source_preflight_sha256"] : [])
        let columns = try all("SELECT name,hidden FROM pragma_table_xinfo('provider_turns') LIMIT 26", map: {
            (try $0.strictText(0, maximumBytes: 128),$0.int64(1))
        })
        if hasColumns {
            for column in Self.sourceDerivedPreflightColumns {
                let exact = "," + Self.normalizedRunSchemaSQL(column)
                guard normalized.components(separatedBy: exact).count == 2 else {
                    throw ProjectContextError.integrityFailure("invalid source-derived preflight column constraint")
                }
                normalized = normalized.replacingOccurrences(of: exact, with: "")
            }
        }
        guard normalized == base, columns.map({ $0.0 ?? "" }) == expected, columns.allSatisfy({ $0.1 == 0 }),
              try scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND tbl_name='provider_turns'") == 0 else {
            throw ProjectContextError.integrityFailure("unsupported source-derived provider ledger extension")
        }
    }

    private func addContinuitySourceActivationMetadata() throws {
        let definition = try first("SELECT sql FROM sqlite_master WHERE type='table' AND name='continuity_ingress_holds'",
            map: { try $0.strictText(0, maximumBytes: 8_192) }) ?? nil
        let columns = try all("SELECT name,hidden FROM pragma_table_xinfo('continuity_ingress_holds') LIMIT 16",
            map: { (try $0.strictText(0, maximumBytes: 128), $0.int64(1)) })
        let expected = ["operation_id","run_id","state","created_at","updated_at","recovery_attempts","recovery_started_at",
            "recovery_deadline","recovery_retry_at","recovery_claim_id","recovery_lease_owner","recovery_lease_epoch",
            "recovery_error_code","recovery_quarantined","recovery_ack_sha256"]
        let objects = try all("SELECT type,name,sql FROM sqlite_master WHERE tbl_name='continuity_ingress_holds' AND type IN ('index','trigger') LIMIT 3",
            map: { (try $0.strictText(0, maximumBytes: 16), try $0.strictText(1, maximumBytes: 128), try $0.strictText(2, maximumBytes: 4_096)) })
        guard let definition, Self.normalizedRunSchemaSQL(definition) == Self.normalizedRunSchemaSQL(Self.ingressRecoverySchema),
              columns.map({ $0.0 ?? "" }) == expected, columns.allSatisfy({ $0.1 == 0 }), objects.count == 2,
              objects.contains(where: { $0.0 == "index" && $0.1 == "sqlite_autoindex_continuity_ingress_holds_1" && $0.2 == nil }),
              objects.contains(where: { $0.0 == "index" && $0.1 == "idx_continuity_ingress_active_hold" && $0.2.map(Self.normalizedRunSchemaSQL)
                  == Self.normalizedRunSchemaSQL("CREATE UNIQUE INDEX idx_continuity_ingress_active_hold ON continuity_ingress_holds(run_id) WHERE state='awaiting_bootstrap'") }),
              try scalarInt("SELECT COUNT(*) FROM continuity_ingress_holds") <= 1_024 else {
            throw ProjectContextError.integrityFailure("unsupported source activation migration")
        }
        for column in Self.ingressActivationColumns { try executeStatic("ALTER TABLE continuity_ingress_holds ADD COLUMN " + column + ";") }
        try executeStatic("""
            UPDATE continuity_ingress_holds SET recovery_claim_phase='bootstrap' WHERE recovery_claim_id IS NOT NULL AND recovery_ack_sha256 IS NULL;
            UPDATE continuity_ingress_holds SET recovery_claim_id=NULL,recovery_lease_owner=NULL,recovery_lease_epoch=NULL,
                recovery_claim_phase=NULL WHERE recovery_ack_sha256 IS NOT NULL;
            """)
    }

    private func populateSourceTaskFencesForMigration(timestamp: String) throws {
        guard try scalarInt("SELECT COUNT(*) FROM continuity_source_task_fences") == 0 else {
            throw ProjectContextError.integrityFailure("unexpected preexisting source transfer fences")
        }
        try execute("""
            INSERT INTO continuity_source_task_fences(source_binding_id,task_id,project_id,project_generation,run_id,
                operation_id,receipt_sha256,state,created_at)
            SELECT t.source_binding_id,t.task_id,a.project_id,a.project_generation,a.run_id,a.operation_id,a.receipt_sha256,'quiescing',?
            FROM continuity_ingress_acceptances a JOIN continuity_ingress_holds h ON h.operation_id=a.operation_id AND h.run_id=a.run_id
              JOIN continuity_task_authorizations t ON t.task_id=a.task_id AND t.run_id=a.run_id
            WHERE h.state='awaiting_bootstrap'
            """, bindings: [.text(timestamp)])
    }

    private func addContinuityIngressRecoveryMetadata() throws {
        let definition = try first("SELECT sql FROM sqlite_master WHERE type='table' AND name='continuity_ingress_holds'",
            map: { try $0.strictText(0, maximumBytes: 4_096) }) ?? nil
        let columns = try all("SELECT name,hidden FROM pragma_table_xinfo('continuity_ingress_holds') LIMIT 6",
            map: { (try $0.strictText(0, maximumBytes: 128), $0.int64(1)) })
        let objects = try all("SELECT type,name,sql FROM sqlite_master WHERE tbl_name='continuity_ingress_holds' AND type IN ('index','trigger') LIMIT 3",
            map: { (try $0.strictText(0, maximumBytes: 16), try $0.strictText(1, maximumBytes: 128), try $0.strictText(2, maximumBytes: 4_096)) })
        let expectedIndex = "CREATE UNIQUE INDEX idx_continuity_ingress_active_hold ON continuity_ingress_holds(run_id) WHERE state='awaiting_bootstrap'"
        guard let definition,
              Self.normalizedRunSchemaSQL(definition) == Self.normalizedRunSchemaSQL(Self.ingressHoldHistorySchema),
              columns.map({ $0.0 ?? "" }) == ["operation_id", "run_id", "state", "created_at", "updated_at"],
              columns.allSatisfy({ $0.1 == 0 }), objects.count == 2,
              objects.contains(where: { $0.0 == "index" && $0.1 == "sqlite_autoindex_continuity_ingress_holds_1" && $0.2 == nil }),
              objects.contains(where: { $0.0 == "index" && $0.1 == "idx_continuity_ingress_active_hold"
                  && $0.2.map(Self.normalizedRunSchemaSQL) == Self.normalizedRunSchemaSQL(expectedIndex) }),
              try scalarInt("SELECT COUNT(*) FROM continuity_ingress_holds") <= 1_024,
              try scalarInt("""
                SELECT COUNT(*) FROM continuity_ingress_holds h LEFT JOIN continuity_ingress_acceptances a
                ON a.operation_id=h.operation_id AND a.run_id=h.run_id WHERE a.operation_id IS NULL
                """) == 0 else {
            throw ProjectContextError.integrityFailure("unsupported continuity ingress recovery metadata migration")
        }
        for column in Self.ingressRecoveryColumns {
            try executeStatic("ALTER TABLE continuity_ingress_holds ADD COLUMN " + column + ";")
        }
    }

    private func rebuildContinuityIngressHoldHistory() throws {
        let definition = try first("SELECT sql FROM sqlite_master WHERE type='table' AND name='continuity_ingress_holds'",
            map: { try $0.strictText(0, maximumBytes: 4_096) }) ?? nil
        let columns = try all("SELECT name,hidden FROM pragma_table_xinfo('continuity_ingress_holds') LIMIT 6",
            map: { (try $0.strictText(0, maximumBytes: 128), $0.int64(1)) })
        let objects = try all("SELECT type,name,sql FROM sqlite_master WHERE tbl_name='continuity_ingress_holds' AND type IN ('index','trigger') LIMIT 3",
            map: { (try $0.strictText(0, maximumBytes: 16), try $0.strictText(1, maximumBytes: 128), try $0.strictText(2, maximumBytes: 4_096)) })
        guard let definition,
              Self.normalizedRunSchemaSQL(definition) == Self.normalizedRunSchemaSQL(Self.legacyIngressHoldSchema),
              columns.map({ $0.0 ?? "" }) == ["run_id", "operation_id", "state", "created_at", "updated_at"],
              columns.allSatisfy({ $0.1 == 0 }), objects.count == 2,
              Set(objects.compactMap({ $0.1 })) == ["sqlite_autoindex_continuity_ingress_holds_1", "sqlite_autoindex_continuity_ingress_holds_2"],
              objects.allSatisfy({ $0.0 == "index" && $0.2 == nil }),
              try scalarInt("SELECT COUNT(*) FROM continuity_ingress_holds") <= 1_024,
              try scalarInt("""
                SELECT COUNT(*) FROM continuity_ingress_holds h LEFT JOIN continuity_ingress_acceptances a
                ON a.operation_id=h.operation_id AND a.run_id=h.run_id WHERE a.operation_id IS NULL
                """) == 0,
              try scalarInt("""
                SELECT COUNT(*) FROM continuity_ingress_acceptances a LEFT JOIN continuity_ingress_holds h
                ON a.operation_id=h.operation_id AND a.run_id=h.run_id WHERE h.operation_id IS NULL
                """) == 0 else {
            throw ProjectContextError.integrityFailure("unsupported continuity ingress hold history migration")
        }
        try executeStatic(Self.ingressHoldHistorySchema.replacingOccurrences(of: "IF NOT EXISTS continuity_ingress_holds",
            with: "continuity_ingress_holds_upgrade"))
        try executeStatic("""
            INSERT INTO continuity_ingress_holds_upgrade(run_id,operation_id,state,created_at,updated_at)
                SELECT run_id,operation_id,state,created_at,updated_at FROM continuity_ingress_holds;
            DROP TABLE continuity_ingress_holds;
            ALTER TABLE continuity_ingress_holds_upgrade RENAME TO continuity_ingress_holds;
            """)
    }

    private func rebuildAutonomousRunStateConstraint() throws {
        let columns = ["run_id", "project_id", "project_generation", "assignment_id", "mission", "state",
            "continuity_mode", "provider_id", "model_key", "active_session_id", "active_operation_id", "current_work_json",
            "completion_request_json", "last_error_code", "last_error_summary", "retry_at", "continuation_pending",
            "revision", "created_at", "updated_at"]
        guard let start = Self.schemaV2.range(of: "CREATE TABLE IF NOT EXISTS autonomous_runs ("),
              let end = Self.schemaV2.range(of: ");", range: start.upperBound..<Self.schemaV2.endIndex) else {
            throw ProjectContextError.integrityFailure("missing autonomous run migration definition")
        }
        let definition = String(Self.schemaV2[start.lowerBound..<end.upperBound])
        let expectedLegacy = definition.replacingOccurrences(of: "'awaiting_bootstrap',", with: "")
        let storedDefinition = try first("SELECT sql FROM sqlite_master WHERE type='table' AND name='autonomous_runs' LIMIT 1",
            map: { try $0.strictText(0, maximumBytes: 16 * 1_024) }) ?? nil
        let storedColumns = try all("SELECT name,hidden FROM pragma_table_xinfo('autonomous_runs') LIMIT 21", map: {
            (try $0.strictText(0, maximumBytes: 128) ?? "", $0.int64(1))
        })
        let objects = try all("SELECT type,name,sql FROM sqlite_master WHERE tbl_name='autonomous_runs' AND type IN ('trigger','index') LIMIT 4",
            map: { (try $0.strictText(0, maximumBytes: 16), try $0.strictText(1, maximumBytes: 256),
                try $0.strictText(2, maximumBytes: 16 * 1_024)) })
        let expectedIndexes = [
            "idx_autonomous_runs_state": "CREATE INDEX idx_autonomous_runs_state ON autonomous_runs(state,retry_at)",
            "idx_autonomous_runs_project": "CREATE INDEX idx_autonomous_runs_project ON autonomous_runs(project_id,project_generation)",
        ]
        guard let storedDefinition,
              Self.normalizedRunSchemaSQL(storedDefinition) == Self.normalizedRunSchemaSQL(expectedLegacy),
              storedColumns.map({ $0.0 }) == columns, storedColumns.allSatisfy({ $0.1 == 0 }),
              objects.count == 3,
              objects.allSatisfy({ entry in
                  let (type, name, sql) = entry
                  guard type == "index", let name else { return false }
                  if name == "sqlite_autoindex_autonomous_runs_1" { return sql == nil }
                  guard let sql, let expected = expectedIndexes[name] else { return false }
                  return Self.normalizedRunSchemaSQL(sql) == Self.normalizedRunSchemaSQL(expected)
              }) else {
            throw ProjectContextError.integrityFailure("unsupported autonomous run schema extension")
        }
        let newTable = definition
            .replacingOccurrences(of: "IF NOT EXISTS autonomous_runs", with: "autonomous_runs_ingress_upgrade")
        try executeStatic(newTable)
        let list = columns.joined(separator: ",")
        try executeStatic("INSERT INTO autonomous_runs_ingress_upgrade(\(list)) SELECT \(list) FROM autonomous_runs;")
        try executeStatic("DROP TABLE autonomous_runs; ALTER TABLE autonomous_runs_ingress_upgrade RENAME TO autonomous_runs;")
        try executeStatic(Self.schemaForLegacyIngressMigration)
    }

    /// Compare only the known schema, allowing formatting and SQLite's table
    /// quoting after RENAME. Preserve literal contents so changed CHECK/default
    /// values cannot be normalized into the approved definition.
    private static func normalizedRunSchemaSQL(_ sql: String) -> String {
        let input = sql.replacingOccurrences(of: "IF NOT EXISTS ", with: "")
            .replacingOccurrences(of: "\"autonomous_runs\"", with: "autonomous_runs")
            .replacingOccurrences(of: "\"continuity_ingress_holds\"", with: "continuity_ingress_holds")
        var result = ""
        var inLiteral = false
        for character in input {
            if character == "'" { inLiteral.toggle() }
            if !inLiteral && (character.isWhitespace || character == ";") { continue }
            result.append(character)
        }
        return result
    }

    private func executeStatic(_ sql: String) throws {
        let database = try requiredDatabase()
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let value = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw mappedError(result, message: value)
        }
    }

    private func withStatement<T>(
        _ sql: String,
        bindings: [ControlPlaneSQLiteBinding],
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        let database = try requiredDatabase()
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw mappedError(result) }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let bindResult: Int32
            switch binding {
            case .text(let value):
                bindResult = value.withCString {
                    sqlite3_bind_text(statement, index, $0, -1, Self.transient)
                }
            case .optionalText(let value):
                if let value {
                    bindResult = value.withCString {
                        sqlite3_bind_text(statement, index, $0, -1, Self.transient)
                    }
                } else {
                    bindResult = sqlite3_bind_null(statement, index)
                }
            case .int64(let value):
                bindResult = sqlite3_bind_int64(statement, index, value)
            case .optionalInt64(let value):
                if let value {
                    bindResult = sqlite3_bind_int64(statement, index, value)
                } else {
                    bindResult = sqlite3_bind_null(statement, index)
                }
            }
            guard bindResult == SQLITE_OK else { throw mappedError(bindResult) }
        }
        return try body(statement)
    }

    private func requiredDatabase() throws -> OpaquePointer {
        guard let database else { throw ProjectContextError.repositoryClosed }
        return database
    }

    private func mappedError(_ code: Int32, message: String? = nil) -> ProjectContextError {
        if code == SQLITE_BUSY || code == SQLITE_LOCKED { return .databaseBusy }
        if code == SQLITE_FULL { return .storageFull }
        let value = message ?? database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(code)"
        return .databaseFailure(value)
    }

    private static let legacyIngressHoldSchema = """
    CREATE TABLE IF NOT EXISTS continuity_ingress_holds (
        run_id TEXT PRIMARY KEY NOT NULL CHECK (length(run_id)=36),
        operation_id TEXT NOT NULL UNIQUE CHECK (length(operation_id)=36),
        state TEXT NOT NULL CHECK (state IN ('awaiting_bootstrap','cancelled')),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    """
    private static let ingressHoldHistorySchema = """
    CREATE TABLE IF NOT EXISTS continuity_ingress_holds (
        operation_id TEXT PRIMARY KEY NOT NULL CHECK (length(operation_id)=36),
        run_id TEXT NOT NULL CHECK (length(run_id)=36),
        state TEXT NOT NULL CHECK (state IN ('awaiting_bootstrap','cancelled','activated')),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    """
    private static let ingressRecoverySchema = """
    CREATE TABLE IF NOT EXISTS continuity_ingress_holds (
        operation_id TEXT PRIMARY KEY NOT NULL CHECK (length(operation_id)=36),
        run_id TEXT NOT NULL CHECK (length(run_id)=36),
        state TEXT NOT NULL CHECK (state IN ('awaiting_bootstrap','cancelled','activated')),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        recovery_attempts INTEGER NOT NULL DEFAULT 0 CHECK (recovery_attempts BETWEEN 0 AND 8),
        recovery_started_at TEXT CHECK (length(CAST(recovery_started_at AS BLOB))<=128),
        recovery_deadline TEXT CHECK (length(CAST(recovery_deadline AS BLOB))<=128),
        recovery_retry_at TEXT CHECK (length(CAST(recovery_retry_at AS BLOB))<=128),
        recovery_claim_id TEXT CHECK (length(recovery_claim_id)=36),
        recovery_lease_owner TEXT CHECK (length(CAST(recovery_lease_owner AS BLOB)) BETWEEN 1 AND 512),
        recovery_lease_epoch INTEGER CHECK (recovery_lease_epoch>=1),
        recovery_error_code TEXT CHECK (length(CAST(recovery_error_code AS BLOB))<=64),
        recovery_quarantined INTEGER NOT NULL DEFAULT 0 CHECK (recovery_quarantined IN (0,1)),
        recovery_ack_sha256 TEXT CHECK (length(recovery_ack_sha256)=64)
    );
    """
    private static let ingressRecoveryColumns = [
        "recovery_attempts INTEGER NOT NULL DEFAULT 0 CHECK (recovery_attempts BETWEEN 0 AND 8)",
        "recovery_started_at TEXT CHECK (length(CAST(recovery_started_at AS BLOB))<=128)",
        "recovery_deadline TEXT CHECK (length(CAST(recovery_deadline AS BLOB))<=128)",
        "recovery_retry_at TEXT CHECK (length(CAST(recovery_retry_at AS BLOB))<=128)",
        "recovery_claim_id TEXT CHECK (length(recovery_claim_id)=36)",
        "recovery_lease_owner TEXT CHECK (length(CAST(recovery_lease_owner AS BLOB)) BETWEEN 1 AND 512)",
        "recovery_lease_epoch INTEGER CHECK (recovery_lease_epoch>=1)",
        "recovery_error_code TEXT CHECK (length(CAST(recovery_error_code AS BLOB))<=64)",
        "recovery_quarantined INTEGER NOT NULL DEFAULT 0 CHECK (recovery_quarantined IN (0,1))",
        "recovery_ack_sha256 TEXT CHECK (length(recovery_ack_sha256)=64)",
    ]
    private static let ingressActivationHoldSchema = """
    CREATE TABLE IF NOT EXISTS continuity_ingress_holds (
        operation_id TEXT PRIMARY KEY NOT NULL CHECK (length(operation_id)=36),
        run_id TEXT NOT NULL CHECK (length(run_id)=36),
        state TEXT NOT NULL CHECK (state IN ('awaiting_bootstrap','cancelled','activated')),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        recovery_attempts INTEGER NOT NULL DEFAULT 0 CHECK (recovery_attempts BETWEEN 0 AND 8),
        recovery_started_at TEXT CHECK (length(CAST(recovery_started_at AS BLOB))<=128),
        recovery_deadline TEXT CHECK (length(CAST(recovery_deadline AS BLOB))<=128),
        recovery_retry_at TEXT CHECK (length(CAST(recovery_retry_at AS BLOB))<=128),
        recovery_claim_id TEXT CHECK (length(recovery_claim_id)=36),
        recovery_lease_owner TEXT CHECK (length(CAST(recovery_lease_owner AS BLOB)) BETWEEN 1 AND 512),
        recovery_lease_epoch INTEGER CHECK (recovery_lease_epoch>=1),
        recovery_error_code TEXT CHECK (length(CAST(recovery_error_code AS BLOB))<=64),
        recovery_quarantined INTEGER NOT NULL DEFAULT 0 CHECK (recovery_quarantined IN (0,1)),
        recovery_ack_sha256 TEXT CHECK (length(recovery_ack_sha256)=64),
        finalization_attempts INTEGER NOT NULL DEFAULT 0 CHECK (finalization_attempts BETWEEN 0 AND 8),
        finalization_started_at TEXT CHECK (length(CAST(finalization_started_at AS BLOB))<=128),
        finalization_deadline TEXT CHECK (length(CAST(finalization_deadline AS BLOB))<=128),
        finalization_retry_at TEXT CHECK (length(CAST(finalization_retry_at AS BLOB))<=128),
        recovery_claim_phase TEXT CHECK (recovery_claim_phase IN ('bootstrap','activation'))
    );
    """
    private static let ingressActivationColumns = [
        "finalization_attempts INTEGER NOT NULL DEFAULT 0 CHECK (finalization_attempts BETWEEN 0 AND 8)",
        "finalization_started_at TEXT CHECK (length(CAST(finalization_started_at AS BLOB))<=128)",
        "finalization_deadline TEXT CHECK (length(CAST(finalization_deadline AS BLOB))<=128)",
        "finalization_retry_at TEXT CHECK (length(CAST(finalization_retry_at AS BLOB))<=128)",
        "recovery_claim_phase TEXT CHECK (recovery_claim_phase IN ('bootstrap','activation'))",
    ]
    private static var schemaForNativeConversationMigration: String {
        schemaV2.replacingOccurrences(of: nativeSourceConversationSchema, with: "")
    }
    private static var schemaForCancellationMigration: String {
        schemaForNativeConversationMigration.replacingOccurrences(of: nativeTaskCapabilitySchema, with: "")
    }
    private static var schemaForActivationMigration: String {
        schemaForCancellationMigration.replacingOccurrences(of: operationCancellationSchema, with: "")
    }
    private static var schemaForRecoveryMigration: String {
        schemaForActivationMigration.replacingOccurrences(of: ingressActivationHoldSchema, with: ingressRecoverySchema)
    }
    private static var schemaForHoldHistoryMigration: String {
        schemaForRecoveryMigration.replacingOccurrences(of: ingressRecoverySchema, with: ingressHoldHistorySchema)
    }
    private static var schemaForLegacyIngressMigration: String {
        schemaForHoldHistoryMigration.replacingOccurrences(of: ingressHoldHistorySchema, with: legacyIngressHoldSchema)
            .replacingOccurrences(of: """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_continuity_ingress_active_hold
                ON continuity_ingress_holds(run_id) WHERE state='awaiting_bootstrap';
            """, with: "")
    }

    private static let operationCancellationSchema = """
    CREATE TABLE IF NOT EXISTS continuity_operation_cancellations (
        operation_id TEXT PRIMARY KEY NOT NULL CHECK (length(operation_id)=36),
        run_id TEXT NOT NULL CHECK (length(run_id)=36),
        task_id TEXT NOT NULL CHECK (length(task_id)=36),
        project_id TEXT NOT NULL CHECK (length(project_id)=36),
        project_generation INTEGER NOT NULL CHECK (project_generation>=1),
        acceptance_receipt_sha256 TEXT NOT NULL CHECK (length(acceptance_receipt_sha256)=64),
        request_json TEXT NOT NULL CHECK (length(CAST(request_json AS BLOB)) BETWEEN 1 AND 4096),
        request_sha256 TEXT NOT NULL CHECK (length(request_sha256)=64),
        requested_at TEXT NOT NULL CHECK (length(CAST(requested_at AS BLOB)) BETWEEN 1 AND 128),
        receipt_json TEXT CHECK (length(CAST(receipt_json AS BLOB)) BETWEEN 1 AND 16384),
        receipt_sha256 TEXT CHECK (length(receipt_sha256)=64),
        completed_at TEXT CHECK (length(CAST(completed_at AS BLOB)) BETWEEN 1 AND 128),
        attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 8),
        retry_at TEXT CHECK (length(CAST(retry_at AS BLOB)) BETWEEN 1 AND 128),
        error_code TEXT CHECK (length(CAST(error_code AS BLOB)) BETWEEN 1 AND 64),
        quarantined INTEGER NOT NULL DEFAULT 0 CHECK (quarantined IN (0,1)),
        claim_owner TEXT CHECK (length(CAST(claim_owner AS BLOB)) BETWEEN 1 AND 512),
        claim_epoch INTEGER CHECK (claim_epoch>=1),
        CHECK ((receipt_json IS NULL)=(receipt_sha256 IS NULL)),
        CHECK ((receipt_json IS NULL)=(completed_at IS NULL)),
        CHECK ((claim_owner IS NULL)=(claim_epoch IS NULL))
    );
    CREATE INDEX IF NOT EXISTS idx_continuity_operation_cancellation_run ON continuity_operation_cancellations(run_id,operation_id);
    """

    private static let nativeSourceConversationSchema = """
    CREATE TABLE IF NOT EXISTS native_source_conversations (
        conversation_id TEXT PRIMARY KEY CHECK(length(conversation_id)=36),
        task_id TEXT NOT NULL UNIQUE REFERENCES continuity_task_authorizations(task_id),
        capability_id TEXT NOT NULL UNIQUE REFERENCES native_task_capabilities(capability_id),
        project_id TEXT NOT NULL,project_generation INTEGER NOT NULL CHECK(project_generation>0),
        body_json TEXT NOT NULL CHECK(length(CAST(body_json AS BLOB))<=65536),body_sha256 TEXT NOT NULL CHECK(length(body_sha256)=64),
        state TEXT NOT NULL CHECK(state IN ('idle','active','stopped','source_fenced','reconciliation_required')),
        revision INTEGER NOT NULL CHECK(revision>0),active_stage_id TEXT,parent_response_id TEXT CHECK(length(CAST(parent_response_id AS BLOB))<=1024),
        cancelled INTEGER NOT NULL DEFAULT 0 CHECK(cancelled IN (0,1)),cancel_request_id TEXT,cancelled_request_id TEXT,cancel_reason_sha256 TEXT,cancelled_at TEXT,
        lease_owner TEXT,lease_epoch INTEGER NOT NULL DEFAULT 0 CHECK(lease_epoch>=0),lease_capability_epoch INTEGER,lease_expires_at TEXT,
        configuration_sha256 TEXT CHECK(length(configuration_sha256)=64),
        ceilings_json TEXT CHECK(length(CAST(ceilings_json AS BLOB))<=8192),ceilings_sha256 TEXT CHECK(length(ceilings_sha256)=64),
        created_at TEXT NOT NULL,updated_at TEXT NOT NULL,
        CHECK((lease_owner IS NULL AND lease_expires_at IS NULL AND lease_capability_epoch IS NULL) OR
              (length(lease_owner)=36 AND length(lease_expires_at)=20 AND lease_capability_epoch>0)),
        CHECK((ceilings_json IS NULL)=(ceilings_sha256 IS NULL))
    );
    \(NativeSourcePressureSchema.baseTableSQL)
    CREATE INDEX IF NOT EXISTS native_source_turn_recovery ON native_source_provider_turns(state,quarantined);
    CREATE TABLE IF NOT EXISTS native_source_provider_calls (
        conversation_id TEXT NOT NULL REFERENCES native_source_conversations(conversation_id),stage_id TEXT NOT NULL REFERENCES native_source_provider_turns(stage_id),
        ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 15),
        call_json TEXT NOT NULL CHECK(length(CAST(call_json AS BLOB))<=8192),call_sha256 TEXT NOT NULL CHECK(length(call_sha256)=64),
        arguments_json TEXT NOT NULL CHECK(length(CAST(arguments_json AS BLOB))<=262144),arguments_sha256 TEXT NOT NULL CHECK(length(arguments_sha256)=64),
        reservation_id TEXT UNIQUE REFERENCES native_source_requests(reservation_id),
        output_json TEXT CHECK(length(CAST(output_json AS BLOB))<=1048576),output_sha256 TEXT CHECK(length(output_sha256)=64),
        payload_sha256 TEXT CHECK(length(payload_sha256)=64),source_receipt_sha256 TEXT CHECK(length(source_receipt_sha256)=64),
        ready_handoff INTEGER NOT NULL DEFAULT 0 CHECK(ready_handoff IN(0,1)),completed_at TEXT,
        PRIMARY KEY(stage_id,ordinal),
        CHECK((output_json IS NULL AND output_sha256 IS NULL AND payload_sha256 IS NULL AND completed_at IS NULL AND source_receipt_sha256 IS NULL)
            OR (output_json IS NOT NULL AND output_sha256 IS NOT NULL AND payload_sha256 IS NOT NULL AND completed_at IS NOT NULL AND source_receipt_sha256 IS NOT NULL AND reservation_id IS NOT NULL))
    );
    CREATE TABLE IF NOT EXISTS native_source_capability_checks (
        check_id TEXT PRIMARY KEY CHECK(length(check_id)=36),conversation_id TEXT NOT NULL REFERENCES native_source_conversations(conversation_id),
        stage_id TEXT NOT NULL REFERENCES native_source_provider_turns(stage_id),request_id TEXT NOT NULL CHECK(length(request_id)=36),
        nonce TEXT NOT NULL CHECK(length(nonce)=36),lease_owner TEXT NOT NULL CHECK(length(lease_owner)=36),lease_epoch INTEGER NOT NULL CHECK(lease_epoch>0),
        preflight_json TEXT NOT NULL CHECK(length(CAST(preflight_json AS BLOB))<=8192),preflight_sha256 TEXT NOT NULL CHECK(length(preflight_sha256)=64),
        state TEXT NOT NULL CHECK(state IN('attempted','completed','unknown')),
        capabilities_json TEXT CHECK(length(CAST(capabilities_json AS BLOB))<=8192),capabilities_sha256 TEXT CHECK(length(capabilities_sha256)=64),
        attempted_at TEXT NOT NULL,completed_at TEXT,
        CHECK((state='completed' AND capabilities_json IS NOT NULL AND capabilities_sha256 IS NOT NULL) OR
              (state!='completed' AND capabilities_json IS NULL AND capabilities_sha256 IS NULL))
    );
    CREATE UNIQUE INDEX IF NOT EXISTS native_source_single_probe ON native_source_capability_checks(conversation_id) WHERE state='attempted';
    CREATE TABLE IF NOT EXISTS native_source_provider_run_offsets (
        run_id TEXT PRIMARY KEY REFERENCES autonomous_runs(run_id),conversation_id TEXT NOT NULL UNIQUE REFERENCES native_source_conversations(conversation_id),
        task_id TEXT NOT NULL UNIQUE REFERENCES continuity_task_authorizations(task_id),operation_id TEXT NOT NULL UNIQUE REFERENCES continuity_ingress_acceptances(operation_id),
        receipt_json TEXT NOT NULL CHECK(length(CAST(receipt_json AS BLOB))<=32768),receipt_sha256 TEXT NOT NULL CHECK(length(receipt_sha256)=64)
    );
    """

    private static let nativeTaskCapabilitySchema = """
    CREATE TABLE IF NOT EXISTS native_task_capabilities (
        capability_id TEXT PRIMARY KEY NOT NULL CHECK(length(capability_id)=36),
        task_id TEXT NOT NULL UNIQUE REFERENCES continuity_task_authorizations(task_id) CHECK(length(task_id)=36),
        project_id TEXT NOT NULL CHECK(length(project_id)=36), project_generation INTEGER NOT NULL CHECK(project_generation>=1),
        epoch INTEGER NOT NULL CHECK(epoch>=1), state TEXT NOT NULL CHECK(state IN ('active','revoked')),
        verifier_sha256 TEXT CHECK(length(verifier_sha256)=64),
        caller_binding_id TEXT NOT NULL CHECK(length(caller_binding_id)=36), source_binding_id TEXT NOT NULL CHECK(length(source_binding_id)=36),
        approval_sha256 TEXT NOT NULL CHECK(length(approval_sha256)=64), scope_sha256 TEXT NOT NULL CHECK(length(scope_sha256)=64),
        authorization_sha256 TEXT NOT NULL CHECK(length(authorization_sha256)=64), document_sha256 TEXT NOT NULL CHECK(length(document_sha256)=64),
        source_limits_json TEXT NOT NULL CHECK(length(CAST(source_limits_json AS BLOB)) BETWEEN 1 AND 512),
        expires_at TEXT NOT NULL CHECK(length(expires_at)=20), issued_at TEXT NOT NULL CHECK(length(issued_at)=20),
        revoked_at TEXT CHECK(length(revoked_at)=20), CHECK((state='revoked')=(revoked_at IS NOT NULL)),
        CHECK((state='active')=(verifier_sha256 IS NOT NULL))
    );
    CREATE TABLE IF NOT EXISTS native_task_commands (
        request_id TEXT PRIMARY KEY NOT NULL CHECK(length(request_id)=36),
        capability_id TEXT NOT NULL REFERENCES native_task_capabilities(capability_id),
        request_sha256 TEXT NOT NULL CHECK(length(request_sha256)=64),
        receipt_json TEXT NOT NULL CHECK(length(CAST(receipt_json AS BLOB)) BETWEEN 1 AND 8192),
        receipt_sha256 TEXT NOT NULL CHECK(length(receipt_sha256)=64)
    );
    CREATE INDEX IF NOT EXISTS idx_native_commands_capability ON native_task_commands(capability_id);
    CREATE TABLE IF NOT EXISTS native_source_requests (
        reservation_id TEXT PRIMARY KEY NOT NULL CHECK(length(reservation_id)=36),
        task_id TEXT NOT NULL REFERENCES continuity_task_authorizations(task_id), capability_id TEXT NOT NULL REFERENCES native_task_capabilities(capability_id),
        epoch INTEGER NOT NULL CHECK(epoch>=1), session_id TEXT NOT NULL CHECK(length(session_id)=36),
        request_id_sha256 TEXT NOT NULL CHECK(length(request_id_sha256)=64),
        method TEXT NOT NULL CHECK(method IN ('fs_read','session_checkpoint','session_handoff')),
        arguments_sha256 TEXT NOT NULL CHECK(length(arguments_sha256)=64), manager_instance_id TEXT NOT NULL CHECK(length(manager_instance_id)=36),
        state TEXT NOT NULL CHECK(state IN ('admitted','executing','completed','cancelled','failed','withheld','pending')),
        admitted_at TEXT NOT NULL CHECK(length(admitted_at)=20), deadline TEXT NOT NULL CHECK(length(deadline)=20),
        charged_calls INTEGER NOT NULL CHECK(charged_calls BETWEEN 0 AND 64),
        policy_json TEXT NOT NULL CHECK(length(CAST(policy_json AS BLOB)) BETWEEN 1 AND 32768),
        prepared_packet_json TEXT CHECK(length(CAST(prepared_packet_json AS BLOB)) BETWEEN 1 AND 262144),
        packet_sha256 TEXT CHECK(length(packet_sha256)=64),
        authorization_json TEXT CHECK(length(CAST(authorization_json AS BLOB)) BETWEEN 1 AND 32768),
        automatic_enabled INTEGER CHECK(automatic_enabled IN (0,1)),
        result_json TEXT CHECK(length(CAST(result_json AS BLOB)) BETWEEN 1 AND 393216),
        result_sha256 TEXT CHECK(length(result_sha256)=64), result_tokens INTEGER CHECK(result_tokens>=0),
        completed_at TEXT CHECK(length(completed_at)=20), result_expires_at TEXT CHECK(length(result_expires_at)=20),
        recovery_attempts INTEGER NOT NULL DEFAULT 0 CHECK(recovery_attempts BETWEEN 0 AND 8),
        retry_at TEXT CHECK(length(retry_at)=20), error_code TEXT CHECK(length(error_code)<=64),
        quarantined INTEGER NOT NULL DEFAULT 0 CHECK(quarantined IN (0,1)),
        UNIQUE(session_id,request_id_sha256),
        CHECK((method='fs_read')=(prepared_packet_json IS NULL)),
        CHECK((method='fs_read')=(packet_sha256 IS NULL)), CHECK((method='fs_read')=(authorization_json IS NULL)),
        CHECK((method='fs_read')=(automatic_enabled IS NULL))
    );
    CREATE INDEX IF NOT EXISTS idx_native_source_task ON native_source_requests(task_id,method,state);
    CREATE TABLE IF NOT EXISTS native_source_run_offsets (
        task_id TEXT PRIMARY KEY NOT NULL REFERENCES continuity_task_authorizations(task_id),
        run_id TEXT NOT NULL UNIQUE REFERENCES autonomous_runs(run_id), source_binding_id TEXT NOT NULL CHECK(length(source_binding_id)=36),
        operation_id TEXT NOT NULL CHECK(length(operation_id)=36), receipt_sha256 TEXT NOT NULL CHECK(length(receipt_sha256)=64),
        charged_calls INTEGER NOT NULL CHECK(charged_calls BETWEEN 0 AND 64), recorded_at TEXT NOT NULL CHECK(length(recorded_at)=20)
    );
    """

    private static let schemaV2 = """
    \(nativeTaskCapabilitySchema)
    \(nativeSourceConversationSchema)
    \(operationCancellationSchema)
    CREATE TABLE IF NOT EXISTS control_schema_version (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        version INTEGER NOT NULL CHECK (version >= 1),
        applied_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS control_projects (
        project_id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        canonical_root TEXT NOT NULL,
        generation INTEGER NOT NULL DEFAULT 1 CHECK (generation >= 1),
        lifecycle_state TEXT NOT NULL DEFAULT 'active'
            CHECK (lifecycle_state IN ('active','maintenance','resetting','archived','quarantined')),
        repository_fingerprint TEXT,
        bookmark_reference TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_control_projects_root
        ON control_projects(canonical_root) WHERE lifecycle_state != 'archived';

    CREATE TABLE IF NOT EXISTS project_transition_authority (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        transition_kind TEXT NOT NULL CHECK (transition_kind IN ('registration','relink')),
        operation_id TEXT NOT NULL CHECK (
            length(operation_id)=64 AND operation_id NOT GLOB '*[^0-9a-f]*'
        ),
        prior_generation INTEGER NOT NULL CHECK (prior_generation >= 1),
        new_generation INTEGER NOT NULL CHECK (new_generation >= prior_generation),
        target_root_sha256 TEXT NOT NULL CHECK (
            length(target_root_sha256)=64 AND target_root_sha256 NOT GLOB '*[^0-9a-f]*'
        ),
        repository_identity_sha256 TEXT NOT NULL CHECK (
            length(repository_identity_sha256)=64
                AND repository_identity_sha256 NOT GLOB '*[^0-9a-f]*'
        ),
        directory_device TEXT NOT NULL CHECK (
            length(directory_device) BETWEEN 1 AND 20
                AND directory_device NOT GLOB '*[^0-9]*'
        ),
        directory_inode TEXT NOT NULL CHECK (
            length(directory_inode) BETWEEN 1 AND 20
                AND directory_inode NOT GLOB '*[^0-9]*'
        ),
        state TEXT NOT NULL CHECK (state IN ('staged','published')),
        authority_sha256 TEXT NOT NULL CHECK (
            length(authority_sha256)=64 AND authority_sha256 NOT GLOB '*[^0-9a-f]*'
        ),
        created_at TEXT NOT NULL,
        published_at TEXT,
        UNIQUE(project_id,transition_kind,operation_id),
        CHECK (
            (state='staged' AND published_at IS NULL)
                OR (state='published' AND published_at IS NOT NULL)
        )
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_project_transition_authority_staged
        ON project_transition_authority(project_id) WHERE state='staged';
    CREATE INDEX IF NOT EXISTS idx_project_transition_authority_retention
        ON project_transition_authority(project_id,state,sequence DESC);

    CREATE TABLE IF NOT EXISTS project_bindings (
        binding_id TEXT PRIMARY KEY,
        owner_kind TEXT NOT NULL
            CHECK (owner_kind IN ('mcp_client','agent_session','provider_session','autonomous_run','runtime_job','gui_selection')),
        owner_id TEXT NOT NULL,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        project_generation INTEGER NOT NULL CHECK (project_generation >= 1),
        run_id TEXT,
        authorization_scope_json TEXT NOT NULL DEFAULT '{}',
        lease_owner TEXT,
        lease_expires_at TEXT,
        active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0,1)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(owner_kind, owner_id)
    );
    CREATE INDEX IF NOT EXISTS idx_project_bindings_project
        ON project_bindings(project_id, project_generation, active);
    CREATE INDEX IF NOT EXISTS idx_project_bindings_run
        ON project_bindings(run_id) WHERE run_id IS NOT NULL;

    -- These bounded authority tombstones deliberately survive removal of a
    -- project or binding. An old task UUID must never regain authority through
    -- generic binding reactivation or recreation of the same project identity.
    CREATE TABLE IF NOT EXISTS continuity_task_authorizations (
        task_id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        project_generation INTEGER NOT NULL CHECK (project_generation >= 1),
        source_binding_id TEXT NOT NULL UNIQUE,
        assignment_id TEXT NOT NULL,
        assignment_sha256 TEXT NOT NULL CHECK (length(assignment_sha256)=64),
        assignment_json TEXT NOT NULL CHECK (length(CAST(assignment_json AS BLOB)) <= 393216),
        assignment_snapshot_sha256 TEXT NOT NULL CHECK (length(assignment_snapshot_sha256)=64),
        authorization_json TEXT NOT NULL CHECK (length(CAST(authorization_json AS BLOB)) <= 32768),
        authorization_sha256 TEXT NOT NULL CHECK (length(authorization_sha256)=64),
        state TEXT NOT NULL CHECK (state IN ('active','revoked')),
        revision INTEGER NOT NULL CHECK (revision >= 1 AND revision < 9223372036854775807),
        run_id TEXT UNIQUE,
        created_at TEXT NOT NULL,
        revoked_at TEXT,
        CHECK ((state='active' AND revoked_at IS NULL) OR (state='revoked' AND revoked_at IS NOT NULL))
    );
    CREATE INDEX IF NOT EXISTS idx_continuity_task_authorizations_project
        ON continuity_task_authorizations(project_id,project_generation,state);

    CREATE TABLE IF NOT EXISTS continuity_ingress_acceptances (
        operation_id TEXT PRIMARY KEY NOT NULL CHECK (length(operation_id)=36),
        key_sha256 TEXT NOT NULL UNIQUE CHECK (length(key_sha256)=64),
        run_id TEXT NOT NULL CHECK (length(run_id)=36),
        task_id TEXT NOT NULL CHECK (length(task_id)=36),
        project_id TEXT NOT NULL CHECK (length(project_id)=36),
        project_generation INTEGER NOT NULL CHECK (project_generation>=1),
        receipt_json TEXT NOT NULL CHECK (length(CAST(receipt_json AS BLOB))<=393216),
        receipt_sha256 TEXT NOT NULL CHECK (length(receipt_sha256)=64),
        accepted_at TEXT NOT NULL CHECK (length(CAST(accepted_at AS BLOB))<=128)
    );
    CREATE INDEX IF NOT EXISTS idx_continuity_ingress_acceptances_run ON continuity_ingress_acceptances(run_id);
    CREATE TABLE IF NOT EXISTS continuity_ingress_holds (
        operation_id TEXT PRIMARY KEY NOT NULL CHECK (length(operation_id)=36),
        run_id TEXT NOT NULL CHECK (length(run_id)=36),
        state TEXT NOT NULL CHECK (state IN ('awaiting_bootstrap','cancelled','activated')),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        recovery_attempts INTEGER NOT NULL DEFAULT 0 CHECK (recovery_attempts BETWEEN 0 AND 8),
        recovery_started_at TEXT CHECK (length(CAST(recovery_started_at AS BLOB))<=128),
        recovery_deadline TEXT CHECK (length(CAST(recovery_deadline AS BLOB))<=128),
        recovery_retry_at TEXT CHECK (length(CAST(recovery_retry_at AS BLOB))<=128),
        recovery_claim_id TEXT CHECK (length(recovery_claim_id)=36),
        recovery_lease_owner TEXT CHECK (length(CAST(recovery_lease_owner AS BLOB)) BETWEEN 1 AND 512),
        recovery_lease_epoch INTEGER CHECK (recovery_lease_epoch>=1),
        recovery_error_code TEXT CHECK (length(CAST(recovery_error_code AS BLOB))<=64),
        recovery_quarantined INTEGER NOT NULL DEFAULT 0 CHECK (recovery_quarantined IN (0,1)),
        recovery_ack_sha256 TEXT CHECK (length(recovery_ack_sha256)=64),
        finalization_attempts INTEGER NOT NULL DEFAULT 0 CHECK (finalization_attempts BETWEEN 0 AND 8),
        finalization_started_at TEXT CHECK (length(CAST(finalization_started_at AS BLOB))<=128),
        finalization_deadline TEXT CHECK (length(CAST(finalization_deadline AS BLOB))<=128),
        finalization_retry_at TEXT CHECK (length(CAST(finalization_retry_at AS BLOB))<=128),
        recovery_claim_phase TEXT CHECK (recovery_claim_phase IN ('bootstrap','activation'))
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_continuity_ingress_active_hold
        ON continuity_ingress_holds(run_id) WHERE state='awaiting_bootstrap';

    CREATE TABLE IF NOT EXISTS continuity_source_dispatch_origins (
        task_id TEXT PRIMARY KEY NOT NULL CHECK (length(task_id)=36),
        caller_binding_id TEXT NOT NULL CHECK (length(caller_binding_id)=36),
        owner_kind TEXT NOT NULL CHECK (length(CAST(owner_kind AS BLOB))<=64),
        owner_id TEXT NOT NULL CHECK (length(CAST(owner_id AS BLOB)) BETWEEN 1 AND 512),
        scope_sha256 TEXT NOT NULL CHECK (length(scope_sha256)=64),
        issued_at TEXT NOT NULL CHECK (length(CAST(issued_at AS BLOB))<=128),
        invalidated INTEGER NOT NULL DEFAULT 0 CHECK (invalidated IN (0,1))
    );
    CREATE TRIGGER IF NOT EXISTS trg_continuity_source_origin_binding_update
    AFTER UPDATE ON project_bindings
    WHEN OLD.binding_id IS NOT NEW.binding_id OR OLD.owner_kind IS NOT NEW.owner_kind OR OLD.owner_id IS NOT NEW.owner_id
      OR OLD.project_id IS NOT NEW.project_id OR OLD.project_generation IS NOT NEW.project_generation
      OR OLD.run_id IS NOT NEW.run_id OR OLD.authorization_scope_json IS NOT NEW.authorization_scope_json OR OLD.active IS NOT NEW.active
    BEGIN
        UPDATE continuity_source_dispatch_origins SET invalidated=1 WHERE caller_binding_id=OLD.binding_id;
    END;
    CREATE TRIGGER IF NOT EXISTS trg_continuity_source_origin_binding_delete
    AFTER DELETE ON project_bindings
    BEGIN
        UPDATE continuity_source_dispatch_origins SET invalidated=1 WHERE caller_binding_id=OLD.binding_id;
    END;
    CREATE TABLE IF NOT EXISTS continuity_source_task_fences (
        source_binding_id TEXT PRIMARY KEY NOT NULL CHECK (length(source_binding_id)=36),
        task_id TEXT NOT NULL UNIQUE CHECK (length(task_id)=36),
        project_id TEXT NOT NULL CHECK (length(project_id)=36),
        project_generation INTEGER NOT NULL CHECK (project_generation>=1),
        run_id TEXT NOT NULL CHECK (length(run_id)=36),
        operation_id TEXT NOT NULL CHECK (length(operation_id)=36),
        receipt_sha256 TEXT NOT NULL CHECK (length(receipt_sha256)=64),
        state TEXT NOT NULL CHECK (state IN ('quiescing','accepted')),
        activation_receipt_sha256 TEXT CHECK (length(activation_receipt_sha256)=64),
        created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS continuity_explicit_start_permits (
        operation_id TEXT PRIMARY KEY NOT NULL CHECK (length(operation_id)=36),
        receipt_sha256 TEXT NOT NULL CHECK (length(receipt_sha256)=64),
        permit_json TEXT NOT NULL CHECK (length(CAST(permit_json AS BLOB))<=8192),
        permit_sha256 TEXT NOT NULL CHECK (length(permit_sha256)=64)
    );
    CREATE TABLE IF NOT EXISTS continuity_explicit_start_requests (
        request_id TEXT PRIMARY KEY NOT NULL CHECK (length(request_id)=36),
        task_id TEXT NOT NULL CHECK (length(task_id)=36),
        continuity_id TEXT NOT NULL CHECK (length(CAST(continuity_id AS BLOB)) BETWEEN 1 AND 256),
        operation_id TEXT NOT NULL CHECK (length(operation_id)=36),
        receipt_sha256 TEXT NOT NULL CHECK (length(receipt_sha256)=64)
    );
    CREATE TABLE IF NOT EXISTS continuity_source_activations (
        operation_id TEXT PRIMARY KEY NOT NULL CHECK (length(operation_id)=36),
        run_id TEXT NOT NULL CHECK (length(run_id)=36),
        project_id TEXT NOT NULL CHECK (length(project_id)=36),
        project_generation INTEGER NOT NULL CHECK (project_generation>=1),
        task_id TEXT NOT NULL CHECK (length(task_id)=36),
        candidate_id TEXT NOT NULL CHECK (length(candidate_id)=36),
        envelope_json TEXT NOT NULL CHECK (length(CAST(envelope_json AS BLOB))<=524288),
        envelope_sha256 TEXT NOT NULL CHECK (length(envelope_sha256)=64),
        receipt_json TEXT NOT NULL CHECK (length(CAST(receipt_json AS BLOB))<=98304),
        receipt_sha256 TEXT NOT NULL CHECK (length(receipt_sha256)=64),
        sealed_checksum TEXT CHECK (length(sealed_checksum)=64),
        resumption_json TEXT CHECK (length(CAST(resumption_json AS BLOB))<=98304),
        resumption_sha256 TEXT CHECK (length(resumption_sha256)=64)
    );
    CREATE INDEX IF NOT EXISTS idx_continuity_source_activations_run ON continuity_source_activations(run_id);

    CREATE TABLE IF NOT EXISTS continuity_bootstrap_grants (
        grant_id TEXT PRIMARY KEY NOT NULL CHECK (length(grant_id)=36),
        candidate_id TEXT NOT NULL UNIQUE CHECK (length(candidate_id)=36),
        operation_id TEXT NOT NULL CHECK (length(operation_id)=36),
        run_id TEXT NOT NULL CHECK (length(run_id)=36),
        grant_json TEXT NOT NULL CHECK (length(CAST(grant_json AS BLOB))<=8192),
        grant_sha256 TEXT NOT NULL CHECK (length(grant_sha256)=64)
    );
    CREATE INDEX IF NOT EXISTS idx_continuity_bootstrap_grants_operation ON continuity_bootstrap_grants(operation_id);
    CREATE TABLE IF NOT EXISTS continuity_bootstrap_provider_results (
        turn_id TEXT PRIMARY KEY NOT NULL CHECK (length(turn_id)=36),
        grant_id TEXT NOT NULL CHECK (length(grant_id)=36),
        result_json TEXT NOT NULL CHECK (length(CAST(result_json AS BLOB))<=131072),
        result_sha256 TEXT NOT NULL CHECK (length(result_sha256)=64)
    );
    CREATE INDEX IF NOT EXISTS idx_continuity_bootstrap_results_grant ON continuity_bootstrap_provider_results(grant_id);
    CREATE TABLE IF NOT EXISTS continuity_bootstrap_retrieval_proofs (
        grant_id TEXT PRIMARY KEY NOT NULL CHECK (length(grant_id)=36),
        invocation_id TEXT NOT NULL UNIQUE CHECK (length(invocation_id)=36),
        proof_json TEXT NOT NULL CHECK (length(CAST(proof_json AS BLOB))<=98304),
        proof_sha256 TEXT NOT NULL CHECK (length(proof_sha256)=64)
    );

    CREATE TABLE IF NOT EXISTS autonomous_runs (
        run_id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        project_generation INTEGER NOT NULL CHECK (project_generation >= 1),
        assignment_id TEXT,
        mission TEXT NOT NULL,
        state TEXT NOT NULL CHECK (state IN (
            'created','awaiting_bootstrap','validating','ready','starting','running','checkpointing','rolling_over',
            'recovering','validating_completion','completed','waiting_provider','waiting_resource',
            'retry_wait','paused','blocked_configuration','failed_recoverable','cancel_requested',
            'cancelled','failed_terminal')),
        continuity_mode TEXT NOT NULL CHECK (continuity_mode IN ('managedAutonomous','externalMCPCompatibility')),
        provider_id TEXT,
        model_key TEXT,
        active_session_id TEXT,
        active_operation_id TEXT,
        current_work_json TEXT NOT NULL DEFAULT '{}',
        completion_request_json TEXT,
        last_error_code TEXT,
        last_error_summary TEXT,
        retry_at TEXT,
        continuation_pending INTEGER NOT NULL DEFAULT 0 CHECK (continuation_pending IN (0,1)),
        revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_autonomous_runs_state ON autonomous_runs(state, retry_at);
    CREATE INDEX IF NOT EXISTS idx_autonomous_runs_project ON autonomous_runs(project_id, project_generation);

    CREATE TABLE IF NOT EXISTS run_leases (
        run_id TEXT PRIMARY KEY REFERENCES autonomous_runs(run_id) ON DELETE CASCADE,
        lease_owner TEXT NOT NULL,
        lease_epoch INTEGER NOT NULL CHECK (lease_epoch >= 1),
        acquired_at TEXT NOT NULL,
        renewed_at TEXT NOT NULL,
        expires_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS provider_sessions (
        session_id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES autonomous_runs(run_id) ON DELETE CASCADE,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        project_generation INTEGER NOT NULL CHECK (project_generation >= 1),
        provider_id TEXT NOT NULL,
        adapter_id TEXT NOT NULL,
        model_key TEXT NOT NULL,
        provider_response_id TEXT,
        predecessor_session_id TEXT,
        handoff_id TEXT,
        operation_id TEXT,
        idempotency_key TEXT NOT NULL,
        bootstrap_nonce_hash TEXT,
        handoff_sha256 TEXT,
        status TEXT NOT NULL CHECK (status IN (
            'candidate','active','fencing','fenced','sealed','quarantined_duplicate',
            'cancelled','failed','legacy_synthetic')),
        accepted INTEGER NOT NULL DEFAULT 0 CHECK (accepted IN (0,1)),
        context_capacity INTEGER CHECK (context_capacity IS NULL OR context_capacity > 0),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(provider_id, provider_response_id),
        UNIQUE(adapter_id, idempotency_key, session_id)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_one_accepted_per_run
        ON provider_sessions(run_id) WHERE accepted = 1 AND status = 'active';
    CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_one_accepted_per_operation
        ON provider_sessions(operation_id) WHERE accepted = 1 AND operation_id IS NOT NULL;
    CREATE INDEX IF NOT EXISTS idx_provider_operation
        ON provider_sessions(operation_id, idempotency_key);

    CREATE TABLE IF NOT EXISTS provider_turns (
        turn_id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES autonomous_runs(run_id) ON DELETE CASCADE,
        session_id TEXT NOT NULL REFERENCES provider_sessions(session_id) ON DELETE CASCADE,
        operation_id TEXT,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        project_generation INTEGER NOT NULL CHECK (project_generation >= 1),
        request_kind TEXT NOT NULL CHECK (request_kind IN (
            'initial_root','normal_continuation','bootstrap','tool_continuation','automatic_continuation')),
        idempotency_key TEXT NOT NULL,
        previous_response_id TEXT,
        input_sha256 TEXT NOT NULL,
        tool_schema_sha256 TEXT,
        state TEXT NOT NULL CHECK (state IN (
            'intent','submitted','streaming','completed','ambiguous','retry_wait','failed','cancelled')),
        provider_request_id TEXT,
        provider_response_id TEXT,
        request_artifact_id TEXT,
        result_artifact_id TEXT,
        usage_json TEXT,
        attempt INTEGER NOT NULL DEFAULT 0 CHECK (attempt >= 0),
        retry_at TEXT,
        last_error_code TEXT,
        last_error_summary TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(session_id, idempotency_key)
    );
    CREATE INDEX IF NOT EXISTS idx_provider_turns_ready
        ON provider_turns(state, retry_at, created_at);
    CREATE INDEX IF NOT EXISTS idx_provider_turns_response
        ON provider_turns(provider_response_id) WHERE provider_response_id IS NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_one_automatic_continuation
        ON provider_turns(operation_id)
        WHERE request_kind = 'automatic_continuation' AND operation_id IS NOT NULL;

    CREATE TABLE IF NOT EXISTS tool_invocations (
        invocation_id TEXT PRIMARY KEY,
        turn_id TEXT NOT NULL REFERENCES provider_turns(turn_id) ON DELETE CASCADE,
        run_id TEXT NOT NULL REFERENCES autonomous_runs(run_id) ON DELETE CASCADE,
        session_id TEXT NOT NULL REFERENCES provider_sessions(session_id) ON DELETE CASCADE,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        project_generation INTEGER NOT NULL CHECK (project_generation >= 1),
        provider_call_id TEXT NOT NULL,
        tool_name TEXT NOT NULL,
        replay_class TEXT NOT NULL CHECK (replay_class IN (
            'read_only','idempotent','reconciled','non_replayable')),
        idempotency_key TEXT,
        arguments_sha256 TEXT NOT NULL,
        arguments_artifact_id TEXT,
        state TEXT NOT NULL CHECK (state IN (
            'intent','executing','completed','ambiguous','failed','cancelled','quarantined_stale')),
        result_sha256 TEXT,
        result_artifact_id TEXT,
        result_summary TEXT,
        last_error_code TEXT,
        last_error_summary TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(session_id, provider_call_id)
    );
    CREATE INDEX IF NOT EXISTS idx_tool_invocations_recovery
        ON tool_invocations(state, run_id, created_at);

    CREATE TABLE IF NOT EXISTS context_budget_observations (
        observation_id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES autonomous_runs(run_id) ON DELETE CASCADE,
        session_id TEXT NOT NULL REFERENCES provider_sessions(session_id) ON DELETE CASCADE,
        provider_response_id TEXT,
        capacity INTEGER NOT NULL CHECK (capacity > 0),
        used INTEGER NOT NULL CHECK (used >= 0),
        output_reserve INTEGER NOT NULL CHECK (output_reserve >= 0),
        schema_reserve INTEGER NOT NULL CHECK (schema_reserve >= 0),
        handoff_reserve INTEGER NOT NULL CHECK (handoff_reserve >= 0),
        recovery_reserve INTEGER NOT NULL CHECK (recovery_reserve >= 0),
        remaining INTEGER NOT NULL,
        projected_next_turn INTEGER NOT NULL CHECK (projected_next_turn >= 0),
        source TEXT NOT NULL CHECK (source IN ('provider_exact','tokenizer_exact','serialized_estimate','provider_overflow')),
        confidence REAL NOT NULL CHECK (confidence >= 0.0 AND confidence <= 1.0),
        estimator_version TEXT NOT NULL,
        action TEXT NOT NULL CHECK (action IN ('normal','checkpoint','rollover','emergency')),
        created_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_budget_run_created
        ON context_budget_observations(run_id, created_at DESC);

    CREATE TABLE IF NOT EXISTS context_budget_observation_details (
        observation_id TEXT PRIMARY KEY REFERENCES context_budget_observations(observation_id) ON DELETE CASCADE,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        project_generation INTEGER NOT NULL CHECK (project_generation >= 1),
        trigger_point TEXT NOT NULL CHECK (trigger_point IN (
            'before_provider_turn','after_provider_turn','after_tool_result','tool_set_changed',
            'system_instructions_changed','provider_configuration_changed','provider_overflow',
            'manager_recovery','after_bootstrap')),
        checkpoint_threshold INTEGER NOT NULL CHECK (checkpoint_threshold >= 0),
        rollover_threshold INTEGER NOT NULL CHECK (rollover_threshold >= 0),
        emergency_floor INTEGER NOT NULL CHECK (emergency_floor >= 0),
        hysteresis INTEGER NOT NULL CHECK (hysteresis >= 0),
        action_epoch INTEGER NOT NULL CHECK (action_epoch >= 0),
        created_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_budget_details_project
        ON context_budget_observation_details(project_id, project_generation, created_at DESC);

    CREATE TABLE IF NOT EXISTS context_budget_observation_metadata (
        observation_id TEXT PRIMARY KEY REFERENCES context_budget_observations(observation_id) ON DELETE CASCADE,
        observation_json TEXT NOT NULL CHECK (length(CAST(observation_json AS BLOB)) <= 65536)
    );

    CREATE TABLE IF NOT EXISTS context_budget_supervisor_state (
        run_id TEXT NOT NULL REFERENCES autonomous_runs(run_id) ON DELETE CASCADE,
        session_id TEXT NOT NULL REFERENCES provider_sessions(session_id) ON DELETE CASCADE,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        project_generation INTEGER NOT NULL CHECK (project_generation >= 1),
        state_json TEXT NOT NULL,
        latest_observation_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK (revision >= 1),
        updated_at TEXT NOT NULL,
        PRIMARY KEY(run_id, session_id)
    );
    CREATE INDEX IF NOT EXISTS idx_budget_state_project
        ON context_budget_supervisor_state(project_id, project_generation, updated_at DESC);

    CREATE TABLE IF NOT EXISTS context_budget_action_requests (
        request_id TEXT PRIMARY KEY,
        continuity_operation_id TEXT NOT NULL UNIQUE,
        run_id TEXT NOT NULL REFERENCES autonomous_runs(run_id) ON DELETE CASCADE,
        session_id TEXT NOT NULL REFERENCES provider_sessions(session_id) ON DELETE CASCADE,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        project_generation INTEGER NOT NULL CHECK (project_generation >= 1),
        observation_id TEXT NOT NULL,
        requested_action TEXT NOT NULL CHECK (requested_action IN ('checkpoint','rollover','emergency')),
        fulfilled_action TEXT CHECK (fulfilled_action IS NULL OR fulfilled_action IN ('checkpoint','rollover','emergency')),
        action_epoch INTEGER NOT NULL CHECK (action_epoch >= 1),
        reason TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK (revision >= 1),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(run_id, session_id)
    );
    CREATE INDEX IF NOT EXISTS idx_budget_actions_pending
        ON context_budget_action_requests(requested_action, fulfilled_action, updated_at);

    CREATE TABLE IF NOT EXISTS continuity_commands (
        command_id TEXT PRIMARY KEY,
        operation_id TEXT NOT NULL UNIQUE,
        run_id TEXT NOT NULL REFERENCES autonomous_runs(run_id) ON DELETE CASCADE,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        project_generation INTEGER NOT NULL CHECK (project_generation >= 1),
        command_type TEXT NOT NULL CHECK (command_type IN ('checkpoint','rollover','emergency_rollover','recover')),
        requested_by TEXT NOT NULL,
        reason TEXT NOT NULL,
        state TEXT NOT NULL CHECK (state IN ('queued','claimed','running','completed','retry_wait','failed','cancelled')),
        idempotency_key TEXT NOT NULL UNIQUE,
        payload_sha256 TEXT NOT NULL,
        attempt INTEGER NOT NULL DEFAULT 0 CHECK (attempt >= 0),
        retry_at TEXT,
        last_error_code TEXT,
        last_error_summary TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_continuity_commands_ready
        ON continuity_commands(state, retry_at, created_at);

    CREATE TABLE IF NOT EXISTS execution_jobs (
        job_id TEXT PRIMARY KEY,
        run_id TEXT REFERENCES autonomous_runs(run_id) ON DELETE SET NULL,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        project_generation INTEGER NOT NULL CHECK (project_generation >= 1),
        runtime_kind TEXT NOT NULL CHECK (runtime_kind IN ('process','shell','bash','python','powershell')),
        execution_profile TEXT NOT NULL CHECK (execution_profile IN (
            'direct_process','zsh_no_profile','bash_no_profile','legacy_bash_login',
            'python_isolated','powershell_no_profile')),
        replay_class TEXT NOT NULL CHECK (replay_class IN ('read_only','idempotent','reconciled','non_replayable')),
        idempotency_key TEXT,
        state TEXT NOT NULL CHECK (state IN ('queued','running','cancelling','completed','failed','timed_out','cancelled','quarantined_stale')),
        canonical_cwd TEXT NOT NULL,
        command_summary TEXT NOT NULL,
        timeout_seconds INTEGER NOT NULL CHECK (timeout_seconds > 0),
        exit_code INTEGER,
        stdout_inline TEXT,
        stderr_inline TEXT,
        output_artifact_id TEXT,
        output_bytes INTEGER NOT NULL DEFAULT 0 CHECK (output_bytes >= 0),
        process_identifier INTEGER,
        process_group_identifier INTEGER,
        created_at TEXT NOT NULL,
        started_at TEXT,
        completed_at TEXT,
        updated_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_jobs_project_state
        ON execution_jobs(project_id, project_generation, state);

    CREATE TABLE IF NOT EXISTS autonomy_events (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        event_id TEXT NOT NULL UNIQUE,
        run_id TEXT REFERENCES autonomous_runs(run_id) ON DELETE SET NULL,
        project_id TEXT REFERENCES control_projects(project_id) ON DELETE SET NULL,
        operation_id TEXT,
        session_id TEXT,
        job_id TEXT,
        event_type TEXT NOT NULL,
        severity TEXT NOT NULL CHECK (severity IN ('debug','info','warning','error','critical')),
        summary TEXT NOT NULL,
        metadata_json TEXT NOT NULL DEFAULT '{}',
        previous_event_sha256 TEXT,
        event_sha256 TEXT NOT NULL,
        created_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_events_run_sequence ON autonomy_events(run_id, sequence DESC);
    CREATE INDEX IF NOT EXISTS idx_events_project_sequence ON autonomy_events(project_id, sequence DESC);

    CREATE TABLE IF NOT EXISTS stale_result_quarantine_events (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        event_id TEXT NOT NULL UNIQUE,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        stale_generation INTEGER NOT NULL CHECK (stale_generation >= 1),
        current_generation INTEGER NOT NULL CHECK (current_generation >= 1),
        run_id TEXT,
        result_kind TEXT NOT NULL,
        result_sha256 TEXT,
        created_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_stale_quarantine_project_sequence
        ON stale_result_quarantine_events(project_id, sequence DESC);

    CREATE TABLE IF NOT EXISTS migration_receipts (
        receipt_id TEXT PRIMARY KEY,
        migration_name TEXT NOT NULL,
        source_version TEXT NOT NULL,
        target_version TEXT NOT NULL,
        source_sha256 TEXT,
        backup_path TEXT,
        backup_sha256 TEXT,
        imported_count INTEGER NOT NULL DEFAULT 0,
        skipped_count INTEGER NOT NULL DEFAULT 0,
        quarantined_count INTEGER NOT NULL DEFAULT 0,
        integrity_result TEXT NOT NULL,
        details_json TEXT NOT NULL DEFAULT '{}',
        started_at TEXT NOT NULL,
        completed_at TEXT NOT NULL
    );
    """
}


/// Exact source journal variants shared by CP and co-resident runtime preflight.
/// No schema mutation is permitted by this validator.
enum NativeSourcePressureSchema {
    static let baseTableSQL = """
    CREATE TABLE IF NOT EXISTS native_source_provider_turns (
        stage_id TEXT PRIMARY KEY CHECK(length(stage_id)=36),conversation_id TEXT NOT NULL REFERENCES native_source_conversations(conversation_id),
        task_id TEXT NOT NULL REFERENCES continuity_task_authorizations(task_id),request_id TEXT NOT NULL CHECK(length(request_id)=36),
        ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 1 AND 8),
        intent_json TEXT NOT NULL CHECK(length(CAST(intent_json AS BLOB))<=1048576),intent_sha256 TEXT NOT NULL CHECK(length(intent_sha256)=64),
        state TEXT NOT NULL CHECK(state IN ('prepared','submitted','accepted','outcome_unknown','cancelled_before_dispatch')),
        post_json TEXT CHECK(length(CAST(post_json AS BLOB))<=32768),post_sha256 TEXT CHECK(length(post_sha256)=64),
        result_json TEXT CHECK(length(CAST(result_json AS BLOB))<=4194304),result_sha256 TEXT CHECK(length(result_sha256)=64),
        dispatch_nonce TEXT,dispatch_owner TEXT,dispatch_epoch INTEGER,
        blocked_code TEXT CHECK(length(CAST(blocked_code AS BLOB))<=64),cancel_request_id TEXT,cancel_reason_sha256 TEXT,cancelled_at TEXT,quarantined INTEGER NOT NULL DEFAULT 0 CHECK(quarantined IN(0,1)),
        reserved_bytes INTEGER NOT NULL CHECK(reserved_bytes BETWEEN 0 AND 10485760),created_at TEXT NOT NULL,updated_at TEXT NOT NULL,
        UNIQUE(conversation_id,request_id,ordinal),
        CHECK((post_json IS NULL)=(post_sha256 IS NULL)),CHECK((result_json IS NULL)=(result_sha256 IS NULL))
    );
    """
    static let columns = [
        "pressure_decision_json TEXT CHECK (pressure_decision_json IS NULL OR (length(CAST(pressure_decision_json AS BLOB)) BETWEEN 1 AND 32768 AND json_valid(pressure_decision_json) AND json_type(pressure_decision_json) = 'object'))",
        "pressure_decision_sha256 TEXT CHECK ((pressure_decision_json IS NULL AND pressure_decision_sha256 IS NULL) OR (pressure_decision_json IS NOT NULL AND pressure_decision_sha256 IS NOT NULL AND length(pressure_decision_sha256) = 64 AND pressure_decision_sha256 NOT GLOB '*[^0-9a-f]*'))",
        "pressure_reservation_id TEXT REFERENCES native_source_requests(reservation_id) CHECK (pressure_reservation_id IS NULL OR (length(pressure_reservation_id) = 36 AND pressure_decision_json IS NOT NULL AND json_extract(pressure_decision_json, '$.metadata.kind') IS 'pressure'))",
    ]
    static let indexSQL = "CREATE UNIQUE INDEX native_source_pressure_reservation ON native_source_provider_turns(pressure_reservation_id) WHERE pressure_reservation_id IS NOT NULL;"
    static let recoveryIndexSQL = "CREATE INDEX native_source_turn_recovery ON native_source_provider_turns(state,quarantined);"
    static let names = ["pressure_decision_json", "pressure_decision_sha256", "pressure_reservation_id"]

    static func validate(hasColumns: Bool, integer: (String) throws -> Int?, text: (String) throws -> String?) throws -> Bool {
        guard let definition = try text("SELECT sql FROM sqlite_master WHERE type='table' AND name='native_source_provider_turns'"),
              definition.utf8.count <= 32_768 else { return false }
        var actual = normalized(definition)
        if hasColumns {
            for column in columns {
                let suffix = "," + normalized(column)
                guard actual.components(separatedBy: suffix).count == 2 else { return false }
                actual = actual.replacingOccurrences(of: suffix, with: "")
            }
        }
        let expected = ["stage_id","conversation_id","task_id","request_id","ordinal","intent_json","intent_sha256","state",
            "post_json","post_sha256","result_json","result_sha256","dispatch_nonce","dispatch_owner","dispatch_epoch",
            "blocked_code","cancel_request_id","cancel_reason_sha256","cancelled_at","quarantined","reserved_bytes","created_at","updated_at"]
            + (hasColumns ? names : [])
        guard actual == normalized(baseTableSQL),
              try integer("SELECT COUNT(*) FROM pragma_table_xinfo('native_source_provider_turns')") == expected.count,
              try integer("SELECT COUNT(*) FROM pragma_table_xinfo('native_source_provider_turns') WHERE hidden<>0") == 0,
              try integer("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND tbl_name='native_source_provider_turns'") == 0,
              try integer("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND tbl_name='native_source_provider_turns'") == (hasColumns ? 4 : 3) else { return false }
        for (index, name) in expected.enumerated() {
            guard try integer("SELECT COUNT(*) FROM pragma_table_xinfo('native_source_provider_turns') WHERE cid=\(index) AND name='\(name)'") == 1 else { return false }
        }
        if hasColumns {
            guard try integer("SELECT COUNT(*) FROM pragma_table_xinfo('native_source_provider_turns') WHERE cid>=23 AND type='TEXT' AND \"notnull\"=0 AND dflt_value IS NULL") == 3,
                  let index = try text("SELECT sql FROM sqlite_master WHERE type='index' AND name='native_source_pressure_reservation'"),
                  normalized(index) == normalized(indexSQL) else { return false }
        }
        guard let recovery = try text("SELECT sql FROM sqlite_master WHERE type='index' AND name='native_source_turn_recovery'"),
              normalized(recovery) == normalized(recoveryIndexSQL),
              try integer("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND tbl_name='native_source_provider_turns' AND name IN ('sqlite_autoindex_native_source_provider_turns_1','sqlite_autoindex_native_source_provider_turns_2') AND sql IS NULL") == 2 else { return false }
        return true
    }
    private static func normalized(_ sql: String) -> String {
        let value = sql.replacingOccurrences(of: "IF NOT EXISTS ", with: "")
            .replacingOccurrences(of: "\"native_source_provider_turns\"", with: "native_source_provider_turns")
        var result = "", inLiteral = false
        for character in value {
            if character == "'" { inLiteral.toggle() }
            if !inLiteral && (character.isWhitespace || character == ";") { continue }
            result.append(character)
        }
        return result
    }
}

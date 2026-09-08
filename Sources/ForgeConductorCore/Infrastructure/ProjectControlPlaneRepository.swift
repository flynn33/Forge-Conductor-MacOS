// ProjectControlPlaneRepository.swift
// Owns durable project bindings and generation fences on one serialized SQLite connection.

import Foundation
import Darwin
import SQLite3

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
        let assignmentData = try approvedAssignment.storedJSON()
        let timestamp = ISO8601.string(from: clock.now())
        return try controlledTransaction(cancellation: cancellation) { connection in
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
            let limit = min(65_536, envelope.authorization.authorizationScope.maximumInlineOutputBytes)
            let packet = try JSONSerialization.jsonObject(with: envelope.acceptance.source.canonicalPacketJSON)
            let result = try ForgeJSONCanonicalizationV1.data(from: ["ok": true, "is_error": false, "payload": [
                "ok": true, "found": true, "packet": packet, "continuity_id": envelope.sourceIdentity.continuityID,
                "revision": envelope.sourceIdentity.revision, "packet_sha256": envelope.sourceIdentity.packetSHA256]])
            guard result.count <= limit, envelope.authorization.authorizationScope.allowedTools.contains("context_get") else {
                throw ContinuityIngressError.capacityExceeded("exact bootstrap result or recovery tool scope")
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
            try requireBootstrapResultLimitsUnlocked(grant: grant, policy: policy.policy.tools)
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
        return try persistToolInvocationIntentScoped(intent, lease: lease, bootstrapGrant: nil, bootstrapPolicy: nil)
    }

    func persistToolInvocationIntent(
        _ intent: ToolInvocationIntent,
        lease: RunLease,
        bootstrapGrant: ContinuityBootstrapGrant,
        bootstrapPolicy: BudgetPolicySelection
    ) throws -> ToolInvocationRecord {
        return try persistToolInvocationIntentScoped(intent, lease: lease, bootstrapGrant: bootstrapGrant, bootstrapPolicy: bootstrapPolicy)
    }

    private func persistToolInvocationIntentScoped(
        _ intent: ToolInvocationIntent,
        lease: RunLease,
        bootstrapGrant: ContinuityBootstrapGrant?,
        bootstrapPolicy: BudgetPolicySelection?
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
                try requireBootstrapResultLimitsUnlocked(grant: bootstrapGrant, policy: bootstrapPolicy.policy.tools)
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
            if let existing = try toolInvocationByProviderCallUnlocked(
                sessionID: intent.sessionID,
                providerCallID: intent.providerCallID,
                connection: connection
            ) {
                guard Self.toolInvocation(existing, matches: intent) else {
                    throw AutonomyError.intentConflict
                }
                return existing
            }
            if let bootstrapGrant, let bootstrapPolicy {
                try requireBootstrapToolQuotaUnlocked(runID: intent.runID, sessionID: intent.sessionID,
                    turnID: intent.turnID, operationID: bootstrapGrant.envelope.operationID,
                    policy: bootstrapPolicy.policy.tools, connection: connection)
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
        return try transitionToolInvocationScoped(invocationID: invocationID, expected: expected, to: next, lease: lease, resultSHA256: resultSHA256, resultSummary: resultSummary, errorCode: errorCode, errorSummary: errorSummary, bootstrapGrant: nil)
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
        return try transitionToolInvocationScoped(invocationID: invocationID, expected: expected, to: next, lease: lease, resultSHA256: resultSHA256, resultSummary: resultSummary, errorCode: errorCode, errorSummary: errorSummary, bootstrapGrant: bootstrapGrant)
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
        bootstrapGrant: ContinuityBootstrapGrant?
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
                                                       policy: BudgetToolPolicy) throws {
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
        let run = runID.description
        let checks: [(String, [ControlPlaneSQLiteBinding], Int)] = [
            ("SELECT COUNT(*) FROM tool_invocations WHERE run_id=?", [.text(run)], policy.callsPerRun),
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
            } catch {
                throw ProjectContextError.integrityFailure("invalid persisted context budget state")
            }
            guard state.identity == identity,
                  state.revision == UInt64(row.int64(3)),
                  state.latestObservation?.observationID.uuidString.lowercased() == row.text(4) else {
                throw ProjectContextError.integrityFailure("context budget state identity is inconsistent")
            }
            _ = try state.validated()
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
                    try commit()
                    activeControl?.recordCommit()
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
        let upgrading = priorVersion == 2 && (1...5).contains(capability)
        let targetCapability = upgrading ? capability + 1 : 6
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
                : (capability == 2 ? Self.schemaForHoldHistoryMigration : (capability == 3 ? Self.schemaForRecoveryMigration : (capability == 4 ? Self.schemaForActivationMigration : Self.schemaV2)))
            try executeStatic(schema)
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
        if (1...4).contains(capability) {
            try migrate(timestamp: timestamp, priorVersion: priorVersion, databaseURL: databaseURL)
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
    private static var schemaForActivationMigration: String {
        schemaV2.replacingOccurrences(of: operationCancellationSchema, with: "")
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

    private static let schemaV2 = """
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

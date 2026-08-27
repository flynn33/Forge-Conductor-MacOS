// ProjectControlPlaneRepository.swift
// Owns durable project bindings and generation fences on one serialized SQLite connection.

import Foundation
import SQLite3

public actor ProjectControlPlaneRepository {
    public static let schemaVersion = 2
    public static let maximumQuarantineEventsPerProject = 128
    public static let maximumContextBudgetObservationsPerSession = 2_048
    public static let maximumContextBudgetActionRequestsPerRead = 256

    public let databaseURL: URL

    private let clock: any Clock
    private var connection: ControlPlaneSQLiteConnection?

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
        self.connection = try ControlPlaneSQLiteConnection(
            databaseURL: databaseURL.standardizedFileURL,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds,
            migrationTimestamp: ISO8601.string(from: clock.now())
        )
    }

    deinit {
        connection?.close()
    }

    public func close() {
        connection?.close()
        connection = nil
    }

    @discardableResult
    public func registerProject(
        projectID: ProjectID,
        displayName: String,
        canonicalRoot: URL,
        repositoryFingerprint: String? = nil,
        bookmarkReference: String? = nil
    ) throws -> ProjectControlRecord {
        let connection = try requiredConnection()
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 512 else {
            throw ProjectContextError.invalidIdentifier("project display name")
        }
        let root = try Self.canonicalRoot(canonicalRoot)
        let fingerprint = try Self.boundedOptional(repositoryFingerprint, maximumBytes: 2_048, field: "repository fingerprint")
        let bookmark = try Self.boundedOptional(bookmarkReference, maximumBytes: 16 * 1_024, field: "bookmark reference")
        let timestamp = ISO8601.string(from: clock.now())

        return try connection.transaction {
            if let current = try projectUnlocked(projectID, connection: connection) {
                guard current.canonicalRoot.path == root.path else {
                    throw ProjectContextError.projectRelinkRequired(projectID)
                }
                if let rootOwner = try projectAtRootUnlocked(root, connection: connection),
                   rootOwner.projectID != projectID {
                    throw ProjectContextError.projectRootAlreadyRegistered(root.path)
                }
                try connection.execute(
                    """
                    UPDATE control_projects SET
                        display_name=?,repository_fingerprint=?,bookmark_reference=?,updated_at=?
                    WHERE project_id=? AND canonical_root=?
                    """,
                    bindings: [
                        .text(name), .optionalText(fingerprint), .optionalText(bookmark),
                        .text(timestamp), .text(projectID.description), .text(root.path),
                    ]
                )
                guard let refreshed = try projectUnlocked(projectID, connection: connection) else {
                    throw ProjectContextError.integrityFailure("updated project could not be read back")
                }
                return refreshed
            }
            if try projectAtRootUnlocked(root, connection: connection) != nil {
                throw ProjectContextError.projectRootAlreadyRegistered(root.path)
            }
            try connection.execute(
                """
                INSERT INTO control_projects(
                    project_id,display_name,canonical_root,generation,lifecycle_state,
                    repository_fingerprint,bookmark_reference,created_at,updated_at
                ) VALUES(?,?,?,1,'active',?,?,?,?)
                """,
                bindings: [
                    .text(projectID.description), .text(name), .text(root.path),
                    .optionalText(fingerprint), .optionalText(bookmark),
                    .text(timestamp), .text(timestamp),
                ]
            )
            guard let inserted = try projectUnlocked(projectID, connection: connection) else {
                throw ProjectContextError.integrityFailure("registered project could not be read back")
            }
            return inserted
        }
    }

    public func project(_ projectID: ProjectID) throws -> ProjectControlRecord? {
        try projectUnlocked(projectID, connection: requiredConnection())
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

    @discardableResult
    public func bind(
        owner: ProjectBindingOwner,
        projectID: ProjectID,
        generation: ProjectGeneration,
        runID: RunID? = nil,
        authorizationScope: ToolAuthorizationScope,
        leaseOwner: String? = nil,
        leaseExpiresAt: String? = nil
    ) throws -> ProjectContextBinding {
        try Self.validate(owner)
        try Self.validate(generation)
        try Self.validate(authorizationScope)
        let connection = try requiredConnection()
        let scopeJSON = try Self.scopeJSON(authorizationScope)
        let boundedLeaseOwner = try Self.boundedOptional(leaseOwner, maximumBytes: 512, field: "lease owner")
        let boundedLeaseExpiry = try Self.boundedOptional(leaseExpiresAt, maximumBytes: 128, field: "lease expiry")
        let timestamp = ISO8601.string(from: clock.now())

        return try connection.transaction {
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
        includeInactive: Bool = false
    ) throws -> ProjectContextBinding? {
        try Self.validate(owner)
        return try bindingUnlocked(
            owner: owner,
            includeInactive: includeInactive,
            connection: requiredConnection()
        )
    }

    public func invocationContext(
        for owner: ProjectBindingOwner,
        clientID: ClientID? = nil
    ) throws -> ToolInvocationContext {
        try Self.validate(owner)
        let connection = try requiredConnection()
        guard let binding = try bindingUnlocked(owner: owner, includeInactive: false, connection: connection) else {
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

    public func validate(
        _ context: ToolInvocationContext,
        for owner: ProjectBindingOwner
    ) throws {
        try Self.validate(owner)
        try Self.validate(context.projectGeneration)
        try Self.validate(context.authorizationScope)
        let connection = try requiredConnection()
        _ = try requiredActiveProjectUnlocked(
            context.projectID,
            generation: context.projectGeneration,
            connection: connection
        )
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
    }

    /// Runs a short synchronous result mutation only while the durable project generation
    /// and owner binding are still current. Actor isolation serializes this check and mutation
    /// against generation resets. Callers must keep the closure bounded and nonblocking.
    public func commitIfCurrent<Value: Sendable>(
        context: ToolInvocationContext,
        owner: ProjectBindingOwner,
        resultKind: String,
        resultSHA256: String? = nil,
        mutation: @Sendable () throws -> Value
    ) throws -> Value {
        try Self.validate(owner)
        try Self.validate(context.projectGeneration)
        try Self.validate(context.authorizationScope)
        let connection = try requiredConnection()
        do {
            return try connection.transaction {
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
                return try mutation()
            }
        } catch DelayedResultFenceError.staleGeneration(let actualGeneration) {
            _ = try quarantineStaleResult(
                context: context,
                resultKind: resultKind,
                resultSHA256: resultSHA256
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
        expectedGeneration: ProjectGeneration
    ) throws -> ProjectControlRecord {
        try Self.validate(expectedGeneration)
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
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
            return project
        }
    }

    @discardableResult
    public func completeReset(
        projectID: ProjectID,
        expectedGeneration: ProjectGeneration
    ) throws -> ProjectGenerationResetReceipt {
        try Self.validate(expectedGeneration)
        guard expectedGeneration.rawValue < UInt64(Int64.max) else {
            throw ProjectContextError.invalidGeneration(expectedGeneration.rawValue)
        }
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
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
        expectedGeneration: ProjectGeneration
    ) throws {
        try Self.validate(expectedGeneration)
        let connection = try requiredConnection()
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
        guard stateData.count <= 64 * 1_024,
              let stateJSON = String(data: stateData, encoding: .utf8) else {
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
        mode: ContinuityMode
    ) throws {
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
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        try connection.transaction {
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
        _ request: ContinuityCommandRequest
    ) throws -> ContinuityCommand {
        try validateContinuityCommandRequest(request)
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
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

    /// Resolves only bounded, durable detail rows needed by the operator projection.
    /// No provider calls, memory reads, or process work occurs here.
    public func operatorContinuityReadModels(
        commands: [ContinuityCommand]
    ) throws -> [ManagerOperatorContinuityReadModel] {
        guard commands.count <= 100 else {
            throw AutonomyError.invalidRequest("operator continuity detail query is outside bounds")
        }
        let connection = try requiredConnection()
        return try commands.map { command in
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
                budgetObservation: observation
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

            try connection.execute(
                """
                INSERT INTO autonomous_runs(
                    run_id,project_id,project_generation,assignment_id,mission,state,
                    continuity_mode,provider_id,model_key,current_work_json,revision,created_at,updated_at
                ) VALUES(?,?,?,?,?,'created',?,?,?, ?,0,?,?)
                """,
                bindings: [
                    .text(request.runID.description), .text(request.projectID.description),
                    .int64(try Self.sqliteGeneration(request.projectGeneration)),
                    .optionalText(request.assignmentID), .text(request.mission),
                    .text(request.continuityMode.rawValue), .text(request.providerID),
                    .text(request.modelKey), .text(specificationJSON),
                    .text(timestamp), .text(timestamp),
                ]
            )
            try upsertAutonomousRunBindingUnlocked(request, timestamp: timestamp, connection: connection)
            try appendAutonomyEventUnlocked(
                runID: request.runID,
                projectID: request.projectID,
                eventType: "autonomous_run_created",
                severity: .info,
                summary: "Autonomous run was durably created",
                metadata: [
                    "continuity_mode": request.continuityMode.rawValue,
                    "project_generation": String(request.projectGeneration.rawValue),
                ],
                connection: connection
            )
            guard let inserted = try autonomousRunUnlocked(request.runID, connection: connection) else {
                throw ProjectContextError.integrityFailure("autonomous run could not be read after insertion")
            }
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
                + " WHERE state NOT IN ('completed','cancelled','failed_terminal') ORDER BY updated_at,run_id LIMIT ?",
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

    @discardableResult
    public func completeAutonomousRun(
        runID: RunID,
        lease: RunLease,
        receipt: CompletionValidationReceipt
    ) throws -> AutonomousRunRecord {
        guard receipt.runID == runID, receipt.passed,
              try Self.validCompletionReceipt(receipt) else {
            throw AutonomyError.completionValidationFailed
        }
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            guard let current = try autonomousRunUnlocked(runID, connection: connection) else {
                throw AutonomyError.runNotFound(runID)
            }
            guard current.state == .validatingCompletion,
                  current.revision == receipt.expectedRevision else {
                throw AutonomyError.transitionConflict
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
        try Self.validate(intent)
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        try connection.transaction {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
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
                guard existing == ProviderSessionIdentity(intent) else {
                    throw AutonomyError.intentConflict
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
        try Self.validate(intent)
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
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
        guard Self.validProviderTurnTransitions[expected]?.contains(next) == true else {
            throw AutonomyError.invalidRequest("invalid provider turn transition \(expected.rawValue) -> \(next.rawValue)")
        }
        let boundedUsage = try Self.boundedOptional(usageJSON, maximumBytes: 64 * 1_024, field: "provider usage JSON")
        let boundedError = try Self.boundedOptional(errorSummary, maximumBytes: 2_048, field: "provider turn error")
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            guard let current = try providerTurnUnlocked(turnID, connection: connection) else {
                throw AutonomyError.providerTurnNotFound(turnID)
            }
            guard current.intent.runID == lease.runID else { throw AutonomyError.staleLease }
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
        try Self.validate(intent)
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
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
            ), session.status == .active, session.accepted else {
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
        guard Self.validToolInvocationTransitions[expected]?.contains(next) == true else {
            throw AutonomyError.invalidRequest("invalid tool invocation transition \(expected.rawValue) -> \(next.rawValue)")
        }
        if let resultSHA256 { try Self.validateSHA256(resultSHA256, field: "tool result SHA-256") }
        let boundedResult = try Self.boundedOptional(resultSummary, maximumBytes: 64 * 1_024, field: "tool result summary")
        let boundedError = try Self.boundedOptional(errorSummary, maximumBytes: 2_048, field: "tool error summary")
        let connection = try requiredConnection()
        let timestamp = ISO8601.string(from: clock.now())
        return try connection.transaction {
            try verifyRunLeaseUnlocked(lease, timestamp: timestamp, connection: connection)
            guard let current = try toolInvocationUnlocked(invocationID, connection: connection) else {
                throw AutonomyError.toolInvocationNotFound(invocationID)
            }
            guard current.runID == lease.runID else { throw AutonomyError.staleLease }
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
        resultSHA256: String? = nil
    ) throws -> String {
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
        let connection = try requiredConnection()
        return try connection.transaction {
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

    public func health() throws -> ControlPlaneDatabaseHealth {
        let connection = try requiredConnection()
        let integrity = try connection.scalarText("PRAGMA integrity_check;") ?? "missing"
        guard integrity == "ok" else {
            throw ProjectContextError.integrityFailure(integrity)
        }
        return ControlPlaneDatabaseHealth(
            schemaVersion: try connection.scalarInt("SELECT version FROM control_schema_version WHERE singleton=1"),
            journalMode: (try connection.scalarText("PRAGMA journal_mode;")) ?? "unknown",
            foreignKeysEnabled: try connection.scalarInt("PRAGMA foreign_keys;") == 1,
            busyTimeoutMilliseconds: try connection.scalarInt("PRAGMA busy_timeout;"),
            integrityResult: integrity
        )
    }

    private func requiredConnection() throws -> ControlPlaneSQLiteConnection {
        guard let connection else { throw ProjectContextError.repositoryClosed }
        return connection
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
           d.rollover_threshold,d.emergency_floor,d.hysteresis,d.action_epoch
    FROM context_budget_observations o
    INNER JOIN context_budget_observation_details d ON d.observation_id=o.observation_id
    """

    private func contextBudgetStateUnlocked(
        identity: ContextBudgetIdentity,
        connection: ControlPlaneSQLiteConnection
    ) throws -> PersistedContextBudgetState? {
        try connection.first(
            """
            SELECT project_id,project_generation,state_json,revision,latest_observation_id
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
            return try state.validated()
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
        return ContextBudgetObservation(
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
        let fixed = try observation.reserves.fixedTotal()
        guard observation.remaining == observation.capacity - fixed - observation.used,
              observation.thresholds.checkpoint >= observation.thresholds.rollover,
              observation.thresholds.rollover >= observation.thresholds.emergency,
              observation.thresholds.hysteresis >= 0 else {
            throw ContextBudgetError.invalidObservation("derived budget values are inconsistent")
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
        .validatingCompletion: [.running, .paused, .failedRecoverable,
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

        init(_ intent: ProviderSessionIntent) {
            sessionID = intent.sessionID
            runID = intent.runID
            projectID = intent.projectID
            projectGeneration = intent.projectGeneration
            providerID = intent.providerID
            adapterID = intent.adapterID
            modelKey = intent.modelKey
            providerResponseID = intent.providerResponseID
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
        guard winner.operationID == acceptance.operationID,
              winner.handoffID == acceptance.handoffID,
              winner.handoffSHA256 == acceptance.handoffSHA256,
              winner.bootstrapNonceSHA256 == acceptance.bootstrapNonceSHA256 else {
            throw AutonomyError.intentConflict
        }
        if let existing = try providerTurnForOperationUnlocked(
            operationID: acceptance.operationID,
            kind: .automaticContinuation,
            connection: connection
        ) {
            guard existing.intent.runID == acceptance.runID,
                  existing.intent.sessionID == winner.sessionID,
                  existing.intent.projectID == acceptance.projectID,
                  existing.intent.projectGeneration == acceptance.projectGeneration,
                  existing.intent.idempotencyKey == acceptance.automaticContinuationIdempotencyKey,
                  existing.intent.previousResponseID == previousResponseID,
                  existing.intent.inputSHA256 == acceptance.automaticContinuationInputSHA256 else {
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
                .text(turnID.uuidString.lowercased()), .text(acceptance.runID.description),
                .text(winner.sessionID), .text(acceptance.operationID.uuidString.lowercased()),
                .text(acceptance.projectID.description),
                .int64(try Self.sqliteGeneration(acceptance.projectGeneration)),
                .text(ProviderTurnKind.automaticContinuation.rawValue),
                .text(acceptance.automaticContinuationIdempotencyKey),
                .text(previousResponseID),
                .text(acceptance.automaticContinuationInputSHA256),
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
        let metadataData = try JSONSerialization.data(
            withJSONObject: metadata.sorted { $0.key < $1.key }.reduce(into: [String: String]()) { $0[$1.key] = $1.value },
            options: [.sortedKeys]
        )
        guard metadataData.count <= 2_048,
              let metadataJSON = String(data: metadataData, encoding: .utf8) else {
            throw ProjectContextError.databaseFailure("event metadata exceeds the bounded payload")
        }
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

    func int64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }
}

private final class ControlPlaneSQLiteConnection {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var database: OpaquePointer?

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
        do {
            guard sqlite3_busy_timeout(handle, Int32(busyTimeoutMilliseconds)) == SQLITE_OK else {
                throw ProjectContextError.databaseFailure("could not configure SQLite busy timeout")
            }
            try executeStatic("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
            try migrate(timestamp: migrationTimestamp)
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

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try executeStatic("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try executeStatic("COMMIT;")
            return value
        } catch {
            try? executeStatic("ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    func execute(
        _ sql: String,
        bindings: [ControlPlaneSQLiteBinding] = []
    ) throws -> Int {
        try withStatement(sql, bindings: bindings) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else { throw mappedError(result) }
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

    private func migrate(timestamp: String) throws {
        let userVersion = try scalarInt("PRAGMA user_version;")
        let hasVersionTable = try scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='control_schema_version'"
        ) == 1
        let storedVersion = hasVersionTable
            ? try scalarInt("SELECT version FROM control_schema_version WHERE singleton=1")
            : 0
        let priorVersion = max(userVersion, storedVersion)
        guard priorVersion <= ProjectControlPlaneRepository.schemaVersion else {
            throw ProjectContextError.unsupportedSchemaVersion(priorVersion)
        }
        try transaction {
            try executeStatic(Self.schemaV2)
            let quickCheck = try scalarText("PRAGMA quick_check;") ?? "missing"
            guard quickCheck == "ok" else {
                throw ProjectContextError.integrityFailure(quickCheck)
            }
            try execute(
                """
                INSERT INTO control_schema_version(singleton,version,applied_at) VALUES(1,2,?)
                ON CONFLICT(singleton) DO UPDATE SET
                    version=excluded.version,applied_at=excluded.applied_at
                WHERE control_schema_version.version < excluded.version
                """,
                bindings: [.text(timestamp)]
            )
            try executeStatic("PRAGMA user_version=2;")
            try execute(
                """
                INSERT OR IGNORE INTO migration_receipts(
                    receipt_id,migration_name,source_version,target_version,integrity_result,
                    details_json,started_at,completed_at
                ) VALUES('control-plane-schema-v2','control-plane-schema',?,'2','ok','{}',?,?)
                """,
                bindings: [.text(String(priorVersion)), .text(timestamp), .text(timestamp)]
            )
        }
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

    private static let schemaV2 = """
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

    CREATE TABLE IF NOT EXISTS autonomous_runs (
        run_id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        project_generation INTEGER NOT NULL CHECK (project_generation >= 1),
        assignment_id TEXT,
        mission TEXT NOT NULL,
        state TEXT NOT NULL CHECK (state IN (
            'created','validating','ready','starting','running','checkpointing','rolling_over',
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

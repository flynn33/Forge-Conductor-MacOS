// RuntimeJobRepository.swift
// Actor-owned SQLite persistence for project-generation-bound execution jobs.

import Foundation
import SQLite3

struct RuntimeArtifactRetentionCandidate: Sendable, Equatable {
    let jobID: UUID
    let projectID: ProjectID
    let stream: RuntimeOutputStream
    let relativePath: String
    let retainedBytes: UInt64
}

public actor RuntimeJobRepository {
    public static let schemaVersion = 5
    public static let maximumListLimit = 100
    public static let maximumTerminalJobsPerProject = 256
    public static let maximumTerminalJobsGlobal = 2_048
    public static let maximumIdempotencyReceiptsPerProject = 512
    public static let maximumIdempotencyReceiptsGlobal = 4_096

    private struct ControlPlaneV2TableSurface: Sendable {
        let name: String
        let columns: [String]
    }

    private static let controlPlaneV2RequiredSurfaces = [
        ControlPlaneV2TableSurface(
            name: "control_schema_version",
            columns: ["singleton", "version", "applied_at"]
        ),
        ControlPlaneV2TableSurface(
            name: "control_projects",
            columns: [
                "project_id", "display_name", "canonical_root", "generation",
                "lifecycle_state", "repository_fingerprint", "bookmark_reference",
                "created_at", "updated_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "project_bindings",
            columns: [
                "binding_id", "owner_kind", "owner_id", "project_id",
                "project_generation", "run_id", "authorization_scope_json",
                "lease_owner", "lease_expires_at", "active", "created_at", "updated_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "autonomous_runs",
            columns: [
                "run_id", "project_id", "project_generation", "assignment_id", "mission",
                "state", "continuity_mode", "provider_id", "model_key", "active_session_id",
                "active_operation_id", "current_work_json", "completion_request_json",
                "last_error_code", "last_error_summary", "retry_at", "continuation_pending",
                "revision", "created_at", "updated_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "run_leases",
            columns: [
                "run_id", "lease_owner", "lease_epoch", "acquired_at", "renewed_at", "expires_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "provider_sessions",
            columns: [
                "session_id", "run_id", "project_id", "project_generation", "provider_id",
                "adapter_id", "model_key", "provider_response_id", "predecessor_session_id",
                "handoff_id", "operation_id", "idempotency_key", "bootstrap_nonce_hash",
                "handoff_sha256", "status", "accepted", "context_capacity", "created_at",
                "updated_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "provider_turns",
            columns: [
                "turn_id", "run_id", "session_id", "operation_id", "project_id",
                "project_generation", "request_kind", "idempotency_key", "previous_response_id",
                "input_sha256", "tool_schema_sha256", "state", "provider_request_id",
                "provider_response_id", "request_artifact_id", "result_artifact_id", "usage_json",
                "attempt", "retry_at", "last_error_code", "last_error_summary", "created_at",
                "updated_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "tool_invocations",
            columns: [
                "invocation_id", "turn_id", "run_id", "session_id", "project_id",
                "project_generation", "provider_call_id", "tool_name", "replay_class",
                "idempotency_key", "arguments_sha256", "arguments_artifact_id", "state",
                "result_sha256", "result_artifact_id", "result_summary", "last_error_code",
                "last_error_summary", "created_at", "updated_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "context_budget_observations",
            columns: [
                "observation_id", "run_id", "session_id", "provider_response_id", "capacity",
                "used", "output_reserve", "schema_reserve", "handoff_reserve", "recovery_reserve",
                "remaining", "projected_next_turn", "source", "confidence", "estimator_version",
                "action", "created_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "context_budget_observation_details",
            columns: [
                "observation_id", "project_id", "project_generation", "trigger_point",
                "checkpoint_threshold", "rollover_threshold", "emergency_floor", "hysteresis",
                "action_epoch", "created_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "context_budget_supervisor_state",
            columns: [
                "run_id", "session_id", "project_id", "project_generation", "state_json",
                "latest_observation_id", "revision", "updated_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "context_budget_action_requests",
            columns: [
                "request_id", "continuity_operation_id", "run_id", "session_id", "project_id",
                "project_generation", "observation_id", "requested_action", "fulfilled_action",
                "action_epoch", "reason", "revision", "created_at", "updated_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "continuity_commands",
            columns: [
                "command_id", "operation_id", "run_id", "project_id", "project_generation",
                "command_type", "requested_by", "reason", "state", "idempotency_key",
                "payload_sha256", "attempt", "retry_at", "last_error_code", "last_error_summary",
                "created_at", "updated_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "execution_jobs",
            columns: [
                "job_id", "run_id", "project_id", "project_generation", "runtime_kind",
                "execution_profile", "replay_class", "idempotency_key", "state", "canonical_cwd",
                "command_summary", "timeout_seconds", "exit_code", "stdout_inline", "stderr_inline",
                "output_artifact_id", "output_bytes", "process_identifier",
                "process_group_identifier", "created_at", "started_at", "completed_at", "updated_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "autonomy_events",
            columns: [
                "sequence", "event_id", "run_id", "project_id", "operation_id", "session_id",
                "job_id", "event_type", "severity", "summary", "metadata_json",
                "previous_event_sha256", "event_sha256", "created_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "stale_result_quarantine_events",
            columns: [
                "sequence", "event_id", "project_id", "stale_generation", "current_generation",
                "run_id", "result_kind", "result_sha256", "created_at",
            ]
        ),
        ControlPlaneV2TableSurface(
            name: "migration_receipts",
            columns: [
                "receipt_id", "migration_name", "source_version", "target_version", "source_sha256",
                "backup_path", "backup_sha256", "imported_count", "skipped_count",
                "quarantined_count", "integrity_result", "details_json", "started_at", "completed_at",
            ]
        ),
    ]

    private static let controlPlaneV2RequiredTableCountSQL =
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ("
        + controlPlaneV2RequiredSurfaces.map { "'\($0.name)'" }.joined(separator: ",")
        + ")"

    public let databaseURL: URL

    private let clock: any Clock
    private var database: OpaquePointer?
    private var openRegistration: SQLiteOpenRegistration?

    public init(
        databaseURL: URL,
        clock: any Clock = SystemClock(),
        busyTimeoutMilliseconds: Int = 5_000
    ) throws {
        guard (1...30_000).contains(busyTimeoutMilliseconds) else {
            throw RuntimeJobError.storageFailure("busy timeout must be between 1 and 30000 milliseconds")
        }
        let standardizedDatabaseURL = databaseURL.standardizedFileURL
        self.databaseURL = standardizedDatabaseURL
        self.clock = clock
        try FileManager.default.createDirectory(
            at: standardizedDatabaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let opened = try Self.openAndMigrate(
            databaseURL: standardizedDatabaseURL,
            busyTimeoutMilliseconds: busyTimeoutMilliseconds,
            timestamp: ISO8601.string(from: clock.now())
        )
        do {
            openRegistration = try VerifiedMigrationBackup.registerOpenDatabase(
                at: standardizedDatabaseURL
            )
            database = opened
        } catch {
            sqlite3_close(opened)
            throw RuntimeJobError.storageFailure(error.localizedDescription)
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
        VerifiedMigrationBackup.unregisterOpenDatabase(openRegistration)
    }

    public func close() {
        guard let database else { return }
        sqlite3_close(database)
        self.database = nil
        VerifiedMigrationBackup.unregisterOpenDatabase(openRegistration)
        openRegistration = nil
    }

    public func health() throws -> (schemaVersion: Int, integrity: String, journalMode: String) {
        let version = try scalarInt("SELECT version FROM runtime_job_schema_version WHERE singleton=1") ?? 0
        let integrity = try scalarText("PRAGMA quick_check") ?? "missing"
        let journal = try scalarText("PRAGMA journal_mode") ?? "missing"
        return (version, integrity, journal.lowercased())
    }

    public func existingJob(
        projectID: ProjectID,
        generation: ProjectGeneration,
        idempotencyKey: String
    ) throws -> RuntimeJobRecord? {
        let key = try Self.boundedIdempotencyKey(idempotencyKey)
        if let record = try queryOne(
            Self.selectRecord +
            " WHERE j.project_id=? AND j.project_generation=? AND j.idempotency_key=? LIMIT 1",
            bindings: [
                .text(projectID.description),
                .int64(try Self.sqliteGeneration(generation)),
                .text(key),
            ],
            decode: Self.decodeRecord
        ) {
            return record
        }
        return try receipt(
            projectID: projectID,
            generation: generation,
            idempotencyKey: key
        )
    }

    @discardableResult
    public func createJob(
        jobID: UUID,
        request: RuntimeJobRequest,
        commandSummary: String,
        timeoutSeconds: Int,
        requestArtifactRelativePath: String?
    ) throws -> RuntimeJobRecord {
        let summary = try Self.bounded(commandSummary, maximumBytes: 2_048, field: "command summary")
        let idempotency = try request.idempotencyKey.map(Self.boundedIdempotencyKey)
        let requestPath = try requestArtifactRelativePath.map {
            try Self.boundedRelativePath($0, field: "request artifact path")
        }
        guard timeoutSeconds > 0, timeoutSeconds <= 24 * 60 * 60 else {
            throw RuntimeJobError.invalidRequest("timeout is outside the supported range")
        }
        let now = ISO8601.string(from: clock.now())

        return try transaction {
            try validateCurrentProject(request.context)
            if let idempotency,
               let existing = try existingJobUnlocked(
                projectID: request.context.projectID,
                generation: request.context.projectGeneration,
                idempotencyKey: idempotency
               ) {
                return existing
            }
            try execute(
                """
                INSERT INTO execution_jobs(
                    job_id,run_id,project_id,project_generation,runtime_kind,execution_profile,
                    replay_class,idempotency_key,state,canonical_cwd,command_summary,timeout_seconds,
                    output_bytes,created_at,updated_at
                ) VALUES(?,?,?,?,?,?,?,?, 'queued',?,?,?,?,?,?)
                """,
                bindings: [
                    .text(Self.uuid(jobID)), .optionalText(request.context.runID?.description),
                    .text(request.context.projectID.description),
                    .int64(try Self.sqliteGeneration(request.context.projectGeneration)),
                    .text(request.kind.rawValue), .text(request.profile.rawValue),
                    .text(request.replayClass.rawValue), .optionalText(idempotency),
                    .text(request.canonicalWorkingDirectory.path), .text(summary),
                    .int64(Int64(timeoutSeconds)), .int64(0), .text(now), .text(now),
                ]
            )
            try execute(
                """
                INSERT INTO runtime_job_details(job_id,request_artifact_relative_path,created_at,updated_at)
                VALUES(?,?,?,?)
                """,
                bindings: [.text(Self.uuid(jobID)), .optionalText(requestPath), .text(now), .text(now)]
            )
            guard let inserted = try jobUnlocked(jobID) else {
                throw RuntimeJobError.storageFailure("created job could not be read back")
            }
            return inserted
        }
    }

    public func job(_ jobID: UUID, context: ToolInvocationContext) throws -> RuntimeJobRecord {
        try validateCurrentProject(context)
        guard let record = try jobUnlocked(jobID) else { throw RuntimeJobError.jobNotFound(jobID) }
        guard record.projectID == context.projectID,
              record.projectGeneration == context.projectGeneration,
              record.runID == context.runID || context.runID == nil else {
            throw RuntimeJobError.jobScopeMismatch(jobID)
        }
        return record
    }

    public func job(_ jobID: UUID) throws -> RuntimeJobRecord? {
        try jobUnlocked(jobID)
    }

    /// Newest-first jobs across projects for the read-only native operator surface.
    /// Unlike the project-scoped tool query this never exposes output bodies or request artifacts.
    public func operatorRecentJobs(limit: Int) throws -> [RuntimeJobRecord] {
        guard (1...Self.maximumListLimit).contains(limit) else {
            throw RuntimeJobError.invalidRequest("operator runtime job limit must be between 1 and 100")
        }
        return try queryAll(
            Self.selectRecord + " ORDER BY j.created_at DESC,j.job_id DESC LIMIT ?",
            bindings: [.int64(Int64(limit))],
            decode: Self.decodeRecord
        )
    }

    func markRunning(
        jobID: UUID,
        processIdentifier: Int32,
        processGroupIdentifier: Int32,
        processStartIdentity: RuntimeProcessStartIdentity?
    ) throws {
        let now = ISO8601.string(from: clock.now())
        let changed = try execute(
            """
            UPDATE execution_jobs SET state='running',process_identifier=?,process_group_identifier=?,
                process_start_seconds=?,process_start_microseconds=?,started_at=?,updated_at=?
            WHERE job_id=? AND state='queued'
            """,
            bindings: [
                .int64(Int64(processIdentifier)), .int64(Int64(processGroupIdentifier)),
                .optionalInt64(processStartIdentity?.seconds),
                .optionalInt64(processStartIdentity?.microseconds),
                .text(now), .text(now), .text(Self.uuid(jobID)),
            ]
        )
        guard changed == 1 else { try throwTransition(jobID: jobID, target: .running) }
    }

    func recoveryProcessIdentity(jobID: UUID) throws -> RuntimePersistedProcessIdentity? {
        try queryOne(
            """
            SELECT process_identifier,process_group_identifier,
                   process_start_seconds,process_start_microseconds
            FROM execution_jobs
            WHERE job_id=? AND state IN ('running','cancelling') LIMIT 1
            """,
            bindings: [.text(Self.uuid(jobID))]
        ) { statement in
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  sqlite3_column_type(statement, 1) != SQLITE_NULL,
                  sqlite3_column_type(statement, 2) != SQLITE_NULL,
                  sqlite3_column_type(statement, 3) != SQLITE_NULL,
                  let processIdentifier = Int32(exactly: sqlite3_column_int64(statement, 0)),
                  let processGroupIdentifier = Int32(exactly: sqlite3_column_int64(statement, 1)),
                  let startIdentity = RuntimeProcessStartIdentity(
                    seconds: sqlite3_column_int64(statement, 2),
                    microseconds: sqlite3_column_int64(statement, 3)
                  ) else { return nil }
            let identity = RuntimePersistedProcessIdentity(
                processIdentifier: processIdentifier,
                processGroupIdentifier: processGroupIdentifier,
                startIdentity: startIdentity
            )
            return identity.isValidProcessGroupLeader ? identity : nil
        } ?? nil
    }

    func terminationRecord(jobID: UUID) throws -> RuntimeTerminationRecord? {
        try queryOne(
            """
            SELECT j.process_identifier,j.process_group_identifier,
                   j.process_start_seconds,j.process_start_microseconds,
                   d.termination_phase,d.termination_probe_deadline,
                   d.termination_error_summary
            FROM execution_jobs j
            JOIN runtime_job_details d ON d.job_id=j.job_id
            WHERE j.job_id=? AND j.state IN ('running','cancelling') LIMIT 1
            """,
            bindings: [.text(Self.uuid(jobID))]
        ) { statement in
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  sqlite3_column_type(statement, 1) != SQLITE_NULL,
                  sqlite3_column_type(statement, 2) != SQLITE_NULL,
                  sqlite3_column_type(statement, 3) != SQLITE_NULL,
                  let processIdentifier = Int32(exactly: sqlite3_column_int64(statement, 0)),
                  let processGroupIdentifier = Int32(exactly: sqlite3_column_int64(statement, 1)),
                  let startIdentity = RuntimeProcessStartIdentity(
                    seconds: sqlite3_column_int64(statement, 2),
                    microseconds: sqlite3_column_int64(statement, 3)
                  ),
                  let phaseText = Self.requiredText(statement, column: 4),
                  let phase = RuntimeTerminationPhase(rawValue: phaseText) else {
                throw RuntimeJobError.storageFailure("invalid persisted runtime termination state")
            }
            let identity = RuntimePersistedProcessIdentity(
                processIdentifier: processIdentifier,
                processGroupIdentifier: processGroupIdentifier,
                startIdentity: startIdentity
            )
            guard identity.isValidProcessGroupLeader else {
                throw RuntimeJobError.storageFailure("invalid persisted runtime termination identity")
            }
            return RuntimeTerminationRecord(
                jobID: jobID,
                identity: identity,
                phase: phase,
                probeDeadline: Self.optionalText(statement, column: 5),
                errorSummary: Self.optionalText(statement, column: 6)
            )
        }
    }

    @discardableResult
    func beginOrResumeTermination(
        jobID: UUID,
        identity: RuntimePersistedProcessIdentity,
        probeDeadline: String
    ) throws -> RuntimeTerminationRecord {
        guard identity.isValidProcessGroupLeader,
              ISO8601.date(from: probeDeadline) != nil else {
            throw RuntimeJobError.invalidRequest("runtime termination identity or deadline is invalid")
        }
        guard try recoveryProcessIdentity(jobID: jobID) == identity else {
            throw RuntimeJobError.storageFailure(
                "runtime termination identity does not match durable process ownership"
            )
        }
        let currentPhaseText: String? = try queryOne(
            "SELECT termination_phase FROM runtime_job_details WHERE job_id=? LIMIT 1",
            bindings: [.text(Self.uuid(jobID))]
        ) { statement in
            Self.optionalText(statement, column: 0)
        } ?? nil
        guard let currentPhase = currentPhaseText.flatMap(RuntimeTerminationPhase.init(rawValue:)) else {
            throw RuntimeJobError.storageFailure("runtime termination phase is missing or invalid")
        }
        let resumedPhase: RuntimeTerminationPhase
        switch currentPhase {
        case .idle, .unconfirmed:
            resumedPhase = .termPending
        case .termPending, .termSent, .killPending, .killSent, .confirmed:
            resumedPhase = currentPhase
        }
        let now = ISO8601.string(from: clock.now())
        try transaction {
            let jobChanged = try execute(
                """
                UPDATE execution_jobs SET updated_at=?
                WHERE job_id=? AND state IN ('running','cancelling')
                """,
                bindings: [.text(now), .text(Self.uuid(jobID))]
            )
            guard jobChanged == 1 else {
                throw RuntimeJobError.invalidTransition(
                    from: (try jobUnlocked(jobID))?.state ?? .failed,
                    to: .cancelling
                )
            }
            let detailChanged = try execute(
                """
                UPDATE runtime_job_details SET termination_phase=?,termination_probe_deadline=?,
                    termination_error_summary=NULL,updated_at=? WHERE job_id=?
                """,
                bindings: [
                    .text(resumedPhase.rawValue), .text(probeDeadline), .text(now),
                    .text(Self.uuid(jobID)),
                ]
            )
            guard detailChanged == 1 else {
                throw RuntimeJobError.storageFailure("runtime termination details are missing")
            }
        }
        guard let record = try terminationRecord(jobID: jobID) else {
            throw RuntimeJobError.storageFailure("runtime termination record could not be read back")
        }
        return record
    }

    func recordTerminationPhase(
        jobID: UUID,
        phase: RuntimeTerminationPhase,
        errorSummary: String? = nil
    ) throws {
        guard phase != .idle else {
            throw RuntimeJobError.invalidRequest("active runtime termination cannot return to idle")
        }
        let boundedError = try errorSummary.map {
            try Self.bounded($0, maximumBytes: 2_048, field: "termination error summary")
        }
        let changed = try execute(
            """
            UPDATE runtime_job_details SET termination_phase=?,termination_error_summary=?,updated_at=?
            WHERE job_id=? AND EXISTS (
                SELECT 1 FROM execution_jobs j
                WHERE j.job_id=runtime_job_details.job_id
                  AND j.state IN ('running','cancelling')
            )
            """,
            bindings: [
                .text(phase.rawValue), .optionalText(boundedError),
                .text(ISO8601.string(from: clock.now())), .text(Self.uuid(jobID)),
            ]
        )
        guard changed == 1 else {
            throw RuntimeJobError.storageFailure("runtime termination phase could not be persisted")
        }
    }

    @discardableResult
    public func requestCancellation(jobID: UUID, context: ToolInvocationContext) throws -> RuntimeJobRecord {
        let current = try job(jobID, context: context)
        if current.state.isTerminal { return current }
        let now = ISO8601.string(from: clock.now())
        switch current.state {
        case .queued:
            _ = try execute(
                """
                UPDATE execution_jobs SET state='cancelled',completed_at=?,updated_at=?
                WHERE job_id=? AND state='queued'
                """,
                bindings: [.text(now), .text(now), .text(Self.uuid(jobID))]
            )
        case .running:
            _ = try execute(
                "UPDATE execution_jobs SET state='cancelling',updated_at=? WHERE job_id=? AND state='running'",
                bindings: [.text(now), .text(Self.uuid(jobID))]
            )
        case .cancelling:
            break
        case .completed, .failed, .timedOut, .cancelled, .quarantinedStale:
            break
        }
        guard let refreshed = try jobUnlocked(jobID) else { throw RuntimeJobError.jobNotFound(jobID) }
        return refreshed
    }

    @discardableResult
    public func complete(
        jobID: UUID,
        terminalState: RuntimeJobState,
        exitCode: Int32?,
        outputs: [RuntimeJobOutputMetadata],
        artifactID: String?,
        errorCode: String? = nil,
        errorSummary: String? = nil,
        expectedContext: ToolInvocationContext? = nil
    ) throws -> RuntimeJobState {
        guard terminalState.isTerminal else {
            throw RuntimeJobError.invalidRequest("completion state must be terminal")
        }
        guard outputs.count <= RuntimeOutputStream.allCases.count else {
            throw RuntimeJobError.invalidRequest("too many output streams")
        }
        guard Set(outputs.map(\.stream)).count == outputs.count,
              outputs.allSatisfy({ $0.jobID == jobID }) else {
            throw RuntimeJobError.invalidRequest("runtime output streams must be unique and match the job")
        }
        let boundedArtifactID = try artifactID.map {
            try Self.bounded($0, maximumBytes: 256, field: "artifact identifier")
        }
        let boundedErrorCode = try errorCode.map {
            try Self.bounded($0, maximumBytes: 128, field: "error code")
        }
        let boundedError = try errorSummary.map {
            try Self.bounded($0, maximumBytes: 2_048, field: "error summary")
        }
        let totalBytes = outputs.reduce(UInt64(0)) { partial, output in
            partial.addingReportingOverflow(output.byteCount).overflow ? UInt64.max : partial + output.byteCount
        }
        let now = ISO8601.string(from: clock.now())

        return try transaction {
            var resolvedState = terminalState
            var resolvedErrorCode = boundedErrorCode
            var resolvedErrorSummary = boundedError
            var staleGeneration: ProjectGeneration?
            var currentGeneration: ProjectGeneration?
            if let expectedContext {
                let project: (Int64, String)? = try queryOne(
                    "SELECT generation,lifecycle_state FROM control_projects WHERE project_id=?",
                    bindings: [.text(expectedContext.projectID.description)]
                ) { statement in
                    (sqlite3_column_int64(statement, 0), String(cString: sqlite3_column_text(statement, 1)))
                }
                guard let project, project.0 > 0 else {
                    throw ProjectContextError.projectNotFound(expectedContext.projectID)
                }
                let actual = ProjectGeneration(UInt64(project.0))
                if actual != expectedContext.projectGeneration {
                    resolvedState = .quarantinedStale
                    resolvedErrorCode = "stale_project_generation"
                    resolvedErrorSummary = "Runtime result was fenced by a newer project generation"
                    staleGeneration = expectedContext.projectGeneration
                    currentGeneration = actual
                } else if project.1 != ProjectLifecycleState.active.rawValue {
                    resolvedState = .quarantinedStale
                    resolvedErrorCode = "project_not_active"
                    resolvedErrorSummary = "Runtime result was fenced while project maintenance was active"
                }
            }
            guard let current = try jobUnlocked(jobID) else { throw RuntimeJobError.jobNotFound(jobID) }
            if let expectedContext {
                guard current.projectID == expectedContext.projectID,
                      current.projectGeneration == expectedContext.projectGeneration,
                      current.runID == expectedContext.runID || expectedContext.runID == nil else {
                    throw RuntimeJobError.jobScopeMismatch(jobID)
                }
            }
            if current.state.isTerminal {
                guard current.state == resolvedState else {
                    throw RuntimeJobError.invalidTransition(from: current.state, to: resolvedState)
                }
                return current.state
            }
            if let processGroupIdentifier = current.processGroupIdentifier {
                let terminationPhase: String? = try queryOne(
                    "SELECT termination_phase FROM runtime_job_details WHERE job_id=? LIMIT 1",
                    bindings: [.text(Self.uuid(jobID))]
                ) { statement in
                    Self.optionalText(statement, column: 0)
                } ?? nil
                guard terminationPhase == RuntimeTerminationPhase.confirmed.rawValue else {
                    throw RuntimeJobError.terminationUnconfirmed(processGroupIdentifier)
                }
            }
            try Self.validateTerminalTransition(from: current.state, to: resolvedState)
            let stdout = outputs.first(where: { $0.stream == .stdout })?.inlineText
            let stderr = outputs.first(where: { $0.stream == .stderr })?.inlineText
            let changed = try execute(
                """
                UPDATE execution_jobs SET state=?,exit_code=?,stdout_inline=?,stderr_inline=?,
                    output_artifact_id=?,output_bytes=?,completed_at=?,updated_at=?
                WHERE job_id=? AND state IN ('queued','running','cancelling')
                """,
                bindings: [
                    .text(resolvedState.rawValue), .optionalInt64(exitCode.map(Int64.init)),
                    .optionalText(stdout), .optionalText(stderr), .optionalText(boundedArtifactID),
                    .int64(Self.sqliteBytes(totalBytes)), .text(now), .text(now),
                    .text(Self.uuid(jobID)),
                ]
            )
            guard changed == 1 else { try throwTransition(jobID: jobID, target: resolvedState) }
            for output in outputs {
                try upsertOutputUnlocked(output)
            }
            try execute(
                """
                UPDATE runtime_job_details SET request_artifact_relative_path=NULL,
                    error_code=?,error_summary=?,updated_at=? WHERE job_id=?
                """,
                bindings: [
                    .optionalText(resolvedErrorCode), .optionalText(resolvedErrorSummary),
                    .text(now), .text(Self.uuid(jobID)),
                ]
            )
            if let expectedContext, let staleGeneration, let currentGeneration {
                try execute(
                    """
                    INSERT INTO stale_result_quarantine_events(
                        event_id,project_id,stale_generation,current_generation,run_id,
                        result_kind,result_sha256,created_at
                    ) VALUES(?,?,?,?,?,'runtime_job_result',?,?)
                    """,
                    bindings: [
                        .text(UUID().uuidString.lowercased()),
                        .text(expectedContext.projectID.description),
                        .int64(try Self.sqliteGeneration(staleGeneration)),
                        .int64(try Self.sqliteGeneration(currentGeneration)),
                        .optionalText(expectedContext.runID?.description),
                        .optionalText(outputs.isEmpty ? nil : JSONSupport.sha256Hex(
                            outputs.sorted { $0.stream.rawValue < $1.stream.rawValue }
                                .map(\.sha256).joined(separator: "|")
                        )),
                        .text(now),
                    ]
                )
                try execute(
                    """
                    DELETE FROM stale_result_quarantine_events
                    WHERE project_id=? AND sequence NOT IN (
                        SELECT sequence FROM stale_result_quarantine_events
                        WHERE project_id=? ORDER BY sequence DESC LIMIT ?
                    )
                    """,
                    bindings: [
                        .text(expectedContext.projectID.description),
                        .text(expectedContext.projectID.description),
                        .int64(Int64(ProjectControlPlaneRepository.maximumQuarantineEventsPerProject)),
                    ]
                )
            }
            return resolvedState
        }
    }

    public func output(
        jobID: UUID,
        stream: RuntimeOutputStream,
        context: ToolInvocationContext
    ) throws -> RuntimeJobOutputMetadata {
        _ = try job(jobID, context: context)
        guard let metadata = try outputUnlocked(jobID: jobID, stream: stream) else {
            throw RuntimeJobError.outputUnavailable(jobID, stream)
        }
        return metadata
    }

    public func list(
        context: ToolInvocationContext,
        states: Set<RuntimeJobState> = [],
        limit: Int = 20,
        beforeCreatedAt: String? = nil
    ) throws -> [RuntimeJobRecord] {
        try validateCurrentProject(context)
        let boundedLimit = min(max(1, limit), Self.maximumListLimit)
        var sql = Self.selectRecord + " WHERE j.project_id=? AND j.project_generation=?"
        var bindings: [SQLiteBinding] = [
            .text(context.projectID.description),
            .int64(try Self.sqliteGeneration(context.projectGeneration)),
        ]
        if context.runID != nil {
            sql += " AND j.run_id=?"
            bindings.append(.text(context.runID!.description))
        }
        if !states.isEmpty {
            sql += " AND j.state IN (" + Array(repeating: "?", count: states.count).joined(separator: ",") + ")"
            for state in states.sorted(by: { $0.rawValue < $1.rawValue }) {
                bindings.append(.text(state.rawValue))
            }
        }
        if let beforeCreatedAt {
            sql += " AND j.created_at<?"
            bindings.append(.text(try Self.bounded(beforeCreatedAt, maximumBytes: 128, field: "list cursor")))
        }
        sql += " ORDER BY j.created_at DESC,j.job_id DESC LIMIT ?"
        bindings.append(.int64(Int64(boundedLimit)))
        return try queryAll(sql, bindings: bindings, decode: Self.decodeRecord)
    }

    public func nonterminalJobs() throws -> [RuntimeJobRecord] {
        try queryAll(
            Self.selectRecord + " WHERE j.state IN ('queued','running','cancelling') ORDER BY j.created_at ASC LIMIT 256",
            bindings: [],
            decode: Self.decodeRecord
        )
    }

    public func markInterrupted(jobID: UUID, summary: String) throws {
        let boundedSummary = try Self.bounded(summary, maximumBytes: 2_048, field: "interruption summary")
        let now = ISO8601.string(from: clock.now())
        try transaction {
            guard let current = try jobUnlocked(jobID) else {
                throw RuntimeJobError.jobNotFound(jobID)
            }
            if let processGroupIdentifier = current.processGroupIdentifier {
                let terminationPhase: String? = try queryOne(
                    "SELECT termination_phase FROM runtime_job_details WHERE job_id=? LIMIT 1",
                    bindings: [.text(Self.uuid(jobID))]
                ) { statement in
                    Self.optionalText(statement, column: 0)
                } ?? nil
                guard terminationPhase == RuntimeTerminationPhase.confirmed.rawValue else {
                    throw RuntimeJobError.terminationUnconfirmed(processGroupIdentifier)
                }
            }
            _ = try execute(
                """
                UPDATE execution_jobs SET state='failed',completed_at=?,updated_at=?
                WHERE job_id=? AND state IN ('queued','running','cancelling')
                """,
                bindings: [.text(now), .text(now), .text(Self.uuid(jobID))]
            )
            _ = try execute(
                """
                UPDATE runtime_job_details SET request_artifact_relative_path=NULL,
                    error_code='runtime_owner_restarted',error_summary=?,updated_at=?
                WHERE job_id=?
                """,
                bindings: [.text(boundedSummary), .text(now), .text(Self.uuid(jobID))]
            )
        }
    }

    public func requestArtifactRelativePath(jobID: UUID) throws -> String? {
        try withStatement("SELECT request_artifact_relative_path FROM runtime_job_details WHERE job_id=?") {
            statement in
            try Self.bind([.text(Self.uuid(jobID))], to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw mappedError(result) }
            return Self.optionalText(statement, column: 0)
        } ?? nil
    }

    func retainedArtifactBytes(projectID: ProjectID? = nil) throws -> UInt64 {
        var sql = """
        SELECT COALESCE(SUM(s.retained_byte_count),0)
        FROM runtime_job_output_streams s
        JOIN execution_jobs j ON j.job_id=s.job_id
        WHERE s.artifact_relative_path IS NOT NULL AND s.artifact_evicted_at IS NULL
          AND j.state IN ('completed','failed','timed_out','cancelled','quarantined_stale')
        """
        var bindings: [SQLiteBinding] = []
        if let projectID {
            sql += " AND j.project_id=?"
            bindings.append(.text(projectID.description))
        }
        let bytes: Int64 = try queryOne(sql, bindings: bindings) { statement in
            sqlite3_column_int64(statement, 0)
        } ?? 0
        guard bytes >= 0 else {
            throw RuntimeJobError.storageFailure("retained runtime artifact bytes are invalid")
        }
        return UInt64(bytes)
    }

    func retainedArtifactJobCount(projectID: ProjectID) throws -> Int {
        let count: Int64 = try queryOne(
            """
            SELECT COUNT(DISTINCT s.job_id)
            FROM runtime_job_output_streams s
            JOIN execution_jobs j ON j.job_id=s.job_id
            WHERE j.project_id=? AND s.artifact_relative_path IS NOT NULL
              AND s.artifact_evicted_at IS NULL
              AND j.state IN ('completed','failed','timed_out','cancelled','quarantined_stale')
            """,
            bindings: [.text(projectID.description)]
        ) { statement in
            sqlite3_column_int64(statement, 0)
        } ?? 0
        guard count >= 0, count <= Int64(Int.max) else {
            throw RuntimeJobError.storageFailure("retained runtime artifact count is invalid")
        }
        return Int(count)
    }

    func oldestArtifactCandidates(
        projectID: ProjectID? = nil,
        limit: Int = 32
    ) throws -> [RuntimeArtifactRetentionCandidate] {
        let boundedLimit = min(max(1, limit), 128)
        var sql = """
        SELECT s.job_id,j.project_id,s.stream,s.artifact_relative_path,s.retained_byte_count
        FROM runtime_job_output_streams s
        JOIN execution_jobs j ON j.job_id=s.job_id
        WHERE s.artifact_relative_path IS NOT NULL AND s.artifact_evicted_at IS NULL
          AND j.state IN ('completed','failed','timed_out','cancelled','quarantined_stale')
        """
        var bindings: [SQLiteBinding] = []
        if let projectID {
            sql += " AND j.project_id=?"
            bindings.append(.text(projectID.description))
        }
        sql += " ORDER BY COALESCE(j.completed_at,j.updated_at) ASC,j.rowid ASC,s.stream ASC LIMIT ?"
        bindings.append(.int64(Int64(boundedLimit)))
        return try queryAll(sql, bindings: bindings) { statement in
            guard let jobText = Self.requiredText(statement, column: 0),
                  let jobID = UUID(uuidString: jobText),
                  let projectText = Self.requiredText(statement, column: 1),
                  let projectUUID = UUID(uuidString: projectText),
                  let streamText = Self.requiredText(statement, column: 2),
                  let stream = RuntimeOutputStream(rawValue: streamText),
                  let relativePath = Self.requiredText(statement, column: 3) else {
                throw RuntimeJobError.storageFailure("invalid runtime artifact retention row")
            }
            let retained = sqlite3_column_int64(statement, 4)
            guard retained >= 0 else {
                throw RuntimeJobError.storageFailure("invalid retained runtime artifact size")
            }
            return RuntimeArtifactRetentionCandidate(
                jobID: jobID,
                projectID: ProjectID(projectUUID),
                stream: stream,
                relativePath: relativePath,
                retainedBytes: UInt64(retained)
            )
        }
    }

    @discardableResult
    func markArtifactEvicted(jobID: UUID, stream: RuntimeOutputStream) throws -> Bool {
        let changed = try execute(
            """
            UPDATE runtime_job_output_streams SET artifact_evicted_at=?
            WHERE job_id=? AND stream=? AND artifact_relative_path IS NOT NULL
              AND artifact_evicted_at IS NULL
            """,
            bindings: [
                .text(ISO8601.string(from: clock.now())),
                .text(Self.uuid(jobID)),
                .text(stream.rawValue),
            ]
        )
        return changed == 1
    }

    /// Compacts terminal audit rows under both project and database-wide caps. Jobs with
    /// retained artifact files are never selected. Idempotency-bearing rows first become
    /// compact receipts in the same transaction so a delayed replay cannot re-run work.
    @discardableResult
    func compactTerminalJobs(
        maximumPerProject: Int = RuntimeJobRepository.maximumTerminalJobsPerProject,
        maximumGlobal: Int = RuntimeJobRepository.maximumTerminalJobsGlobal,
        maximumIdempotencyReceiptsPerProject: Int =
            RuntimeJobRepository.maximumIdempotencyReceiptsPerProject,
        maximumIdempotencyReceiptsGlobal: Int =
            RuntimeJobRepository.maximumIdempotencyReceiptsGlobal
    ) throws -> Int {
        let limits = [
            maximumPerProject,
            maximumGlobal,
            maximumIdempotencyReceiptsPerProject,
            maximumIdempotencyReceiptsGlobal,
        ]
        guard limits.allSatisfy({ (1...100_000).contains($0) }) else {
            throw RuntimeJobError.invalidRequest(
                "runtime terminal retention limits must be between 1 and 100000"
            )
        }
        let now = ISO8601.string(from: clock.now())
        return try transaction {
            try execute(
                """
                WITH ranked AS (
                    SELECT j.job_id,
                           ROW_NUMBER() OVER (
                               PARTITION BY j.project_id
                               ORDER BY COALESCE(j.completed_at,j.updated_at) DESC,j.rowid DESC
                           ) AS project_rank,
                           ROW_NUMBER() OVER (
                               ORDER BY COALESCE(j.completed_at,j.updated_at) DESC,j.rowid DESC
                           ) AS global_rank
                    FROM execution_jobs j
                    WHERE j.state IN (
                        'completed','failed','timed_out','cancelled','quarantined_stale'
                    )
                )
                INSERT INTO runtime_job_idempotency_receipts(
                    job_id,run_id,project_id,project_generation,runtime_kind,execution_profile,
                    replay_class,idempotency_key,state,canonical_cwd,command_summary,
                    timeout_seconds,exit_code,output_bytes,error_code,error_summary,
                    created_at,started_at,completed_at,updated_at,compacted_at
                )
                SELECT j.job_id,j.run_id,j.project_id,j.project_generation,j.runtime_kind,
                       j.execution_profile,j.replay_class,j.idempotency_key,j.state,
                       j.canonical_cwd,j.command_summary,j.timeout_seconds,j.exit_code,j.output_bytes,
                       d.error_code,d.error_summary,j.created_at,j.started_at,
                       COALESCE(j.completed_at,j.updated_at),j.updated_at,?
                FROM execution_jobs j
                JOIN ranked r ON r.job_id=j.job_id
                LEFT JOIN runtime_job_details d ON d.job_id=j.job_id
                WHERE (r.project_rank>? OR r.global_rank>?)
                  AND j.idempotency_key IS NOT NULL
                  AND NOT EXISTS (
                      SELECT 1 FROM runtime_job_output_streams s
                      WHERE s.job_id=j.job_id
                        AND s.artifact_relative_path IS NOT NULL
                        AND s.artifact_evicted_at IS NULL
                  )
                ON CONFLICT(project_id,project_generation,idempotency_key) DO NOTHING
                """,
                bindings: [
                    .text(now),
                    .int64(Int64(maximumPerProject)),
                    .int64(Int64(maximumGlobal)),
                ]
            )
            let deleted = try execute(
                """
                WITH ranked AS (
                    SELECT j.job_id,
                           ROW_NUMBER() OVER (
                               PARTITION BY j.project_id
                               ORDER BY COALESCE(j.completed_at,j.updated_at) DESC,j.rowid DESC
                           ) AS project_rank,
                           ROW_NUMBER() OVER (
                               ORDER BY COALESCE(j.completed_at,j.updated_at) DESC,j.rowid DESC
                           ) AS global_rank
                    FROM execution_jobs j
                    WHERE j.state IN (
                        'completed','failed','timed_out','cancelled','quarantined_stale'
                    )
                )
                DELETE FROM execution_jobs
                WHERE job_id IN (
                    SELECT j.job_id
                    FROM execution_jobs j JOIN ranked r ON r.job_id=j.job_id
                    WHERE (r.project_rank>? OR r.global_rank>?)
                      AND NOT EXISTS (
                          SELECT 1 FROM runtime_job_output_streams s
                          WHERE s.job_id=j.job_id
                            AND s.artifact_relative_path IS NOT NULL
                            AND s.artifact_evicted_at IS NULL
                      )
                )
                """,
                bindings: [
                    .int64(Int64(maximumPerProject)),
                    .int64(Int64(maximumGlobal)),
                ]
            )
            _ = try execute(
                """
                WITH ranked AS (
                    SELECT r.job_id,
                           ROW_NUMBER() OVER (
                               PARTITION BY r.project_id
                               ORDER BY r.completed_at DESC,r.rowid DESC
                           ) AS project_rank,
                           ROW_NUMBER() OVER (
                               ORDER BY r.completed_at DESC,r.rowid DESC
                           ) AS global_rank
                    FROM runtime_job_idempotency_receipts r
                )
                DELETE FROM runtime_job_idempotency_receipts
                WHERE job_id IN (
                    SELECT job_id FROM ranked WHERE project_rank>? OR global_rank>?
                )
                """,
                bindings: [
                    .int64(Int64(maximumIdempotencyReceiptsPerProject)),
                    .int64(Int64(maximumIdempotencyReceiptsGlobal)),
                ]
            )
            return deleted
        }
    }

    // MARK: - Validation and migration

    private func validateCurrentProject(_ context: ToolInvocationContext) throws {
        let row: (Int64, String)? = try queryOne(
            "SELECT generation,lifecycle_state FROM control_projects WHERE project_id=?",
            bindings: [.text(context.projectID.description)]
        ) { statement in
            (sqlite3_column_int64(statement, 0), String(cString: sqlite3_column_text(statement, 1)))
        }
        guard let row else { throw ProjectContextError.projectNotFound(context.projectID) }
        guard row.0 > 0 else { throw RuntimeJobError.storageFailure("stored project generation is invalid") }
        let actual = ProjectGeneration(UInt64(row.0))
        guard actual == context.projectGeneration else {
            throw ProjectContextError.staleProjectGeneration(expected: context.projectGeneration, actual: actual)
        }
        guard row.1 == ProjectLifecycleState.active.rawValue else {
            throw ProjectContextError.projectNotActive(ProjectLifecycleState(rawValue: row.1) ?? .quarantined)
        }
    }

    // MARK: - Row operations

    private func existingJobUnlocked(
        projectID: ProjectID,
        generation: ProjectGeneration,
        idempotencyKey: String
    ) throws -> RuntimeJobRecord? {
        if let record = try queryOne(
            Self.selectRecord +
            " WHERE j.project_id=? AND j.project_generation=? AND j.idempotency_key=? LIMIT 1",
            bindings: [
                .text(projectID.description), .int64(try Self.sqliteGeneration(generation)),
                .text(idempotencyKey),
            ],
            decode: Self.decodeRecord
        ) {
            return record
        }
        return try receipt(
            projectID: projectID,
            generation: generation,
            idempotencyKey: idempotencyKey
        )
    }

    private func jobUnlocked(_ jobID: UUID) throws -> RuntimeJobRecord? {
        if let record = try queryOne(
            Self.selectRecord + " WHERE j.job_id=? LIMIT 1",
            bindings: [.text(Self.uuid(jobID))],
            decode: Self.decodeRecord
        ) {
            return record
        }
        return try queryOne(
            Self.selectReceiptRecord + " WHERE r.job_id=? LIMIT 1",
            bindings: [.text(Self.uuid(jobID))],
            decode: Self.decodeRecord
        )
    }

    private func receipt(
        projectID: ProjectID,
        generation: ProjectGeneration,
        idempotencyKey: String
    ) throws -> RuntimeJobRecord? {
        try queryOne(
            Self.selectReceiptRecord +
            " WHERE r.project_id=? AND r.project_generation=? AND r.idempotency_key=? LIMIT 1",
            bindings: [
                .text(projectID.description),
                .int64(try Self.sqliteGeneration(generation)),
                .text(idempotencyKey),
            ],
            decode: Self.decodeRecord
        )
    }

    private func outputUnlocked(
        jobID: UUID,
        stream: RuntimeOutputStream
    ) throws -> RuntimeJobOutputMetadata? {
        try queryOne(
            """
            SELECT job_id,stream,inline_text,artifact_relative_path,
                   artifact_device_identifier,artifact_file_identifier,
                   byte_count,retained_byte_count,sha256,inline_truncated,
                   artifact_truncated,artifact_evicted_at
            FROM runtime_job_output_streams WHERE job_id=? AND stream=? LIMIT 1
            """,
            bindings: [.text(Self.uuid(jobID)), .text(stream.rawValue)]
        ) { statement in
            try Self.decodeOutput(statement)
        }
    }

    private func upsertOutputUnlocked(_ output: RuntimeJobOutputMetadata) throws {
        let normalizedSHA256 = output.sha256.lowercased()
        guard normalizedSHA256.utf8.count == 64,
              normalizedSHA256.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw RuntimeJobError.invalidRequest("output SHA-256 must contain 64 hexadecimal characters")
        }
        let path = try output.artifactRelativePath.map {
            try Self.boundedRelativePath($0, field: "output artifact path")
        }
        let deviceIdentifier = try output.artifactDeviceIdentifier.map {
            guard let value = Int64(exactly: $0) else {
                throw RuntimeJobError.invalidRequest("output artifact device identifier is invalid")
            }
            return value
        }
        let fileIdentifier = try output.artifactFileIdentifier.map {
            guard let value = Int64(exactly: $0) else {
                throw RuntimeJobError.invalidRequest("output artifact file identifier is invalid")
            }
            return value
        }
        guard (path == nil && deviceIdentifier == nil && fileIdentifier == nil)
                || (path != nil && deviceIdentifier != nil && fileIdentifier != nil) else {
            throw RuntimeJobError.invalidRequest(
                "output artifact path and identity must be committed together"
            )
        }
        try execute(
            """
            INSERT INTO runtime_job_output_streams(
                job_id,stream,inline_text,artifact_relative_path,
                artifact_device_identifier,artifact_file_identifier,
                byte_count,retained_byte_count,sha256,inline_truncated,artifact_truncated
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(job_id,stream) DO UPDATE SET
                inline_text=excluded.inline_text,artifact_relative_path=excluded.artifact_relative_path,
                artifact_device_identifier=excluded.artifact_device_identifier,
                artifact_file_identifier=excluded.artifact_file_identifier,
                byte_count=excluded.byte_count,retained_byte_count=excluded.retained_byte_count,
                sha256=excluded.sha256,inline_truncated=excluded.inline_truncated,
                artifact_truncated=excluded.artifact_truncated,artifact_evicted_at=NULL
            """,
            bindings: [
                .text(Self.uuid(output.jobID)), .text(output.stream.rawValue),
                .text(output.inlineText), .optionalText(path),
                .optionalInt64(deviceIdentifier), .optionalInt64(fileIdentifier),
                .int64(Self.sqliteBytes(output.byteCount)),
                .int64(Self.sqliteBytes(output.retainedByteCount)),
                .text(normalizedSHA256), .int64(output.inlineTruncated ? 1 : 0),
                .int64(output.artifactTruncated ? 1 : 0),
            ]
        )
    }

    private func throwTransition(jobID: UUID, target: RuntimeJobState) throws -> Never {
        guard let record = try jobUnlocked(jobID) else { throw RuntimeJobError.jobNotFound(jobID) }
        throw RuntimeJobError.invalidTransition(from: record.state, to: target)
    }

    // MARK: - SQLite helpers

    @discardableResult
    private func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws -> Int {
        try withStatement(sql) { statement in
            try Self.bind(bindings, to: statement)
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else { throw mappedError(result) }
            return Int(sqlite3_changes(try requiredDatabase()))
        }
    }

    private func scalarInt(_ sql: String) throws -> Int? {
        try queryOne(sql, bindings: []) { statement in Int(sqlite3_column_int64(statement, 0)) }
    }

    private func scalarText(_ sql: String) throws -> String? {
        try withStatement(sql) { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw mappedError(result) }
            return Self.optionalText(statement, column: 0)
        }
    }

    private func queryOne<Value>(
        _ sql: String,
        bindings: [SQLiteBinding],
        decode: (OpaquePointer) throws -> Value
    ) throws -> Value? {
        try withStatement(sql) { statement in
            try Self.bind(bindings, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw mappedError(result) }
            return try decode(statement)
        }
    }

    private func queryAll<Value>(
        _ sql: String,
        bindings: [SQLiteBinding],
        decode: (OpaquePointer) throws -> Value
    ) throws -> [Value] {
        try withStatement(sql) { statement in
            try Self.bind(bindings, to: statement)
            var values: [Value] = []
            values.reserveCapacity(32)
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return values }
                guard result == SQLITE_ROW else { throw mappedError(result) }
                values.append(try decode(statement))
                guard values.count <= 256 else {
                    throw RuntimeJobError.storageFailure("runtime query exceeded its row bound")
                }
            }
        }
    }

    private func withStatement<Value>(
        _ sql: String,
        body: (OpaquePointer) throws -> Value
    ) throws -> Value {
        let database = try requiredDatabase()
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw mappedError(result) }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func transaction<Value>(_ body: () throws -> Value) throws -> Value {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    private func requiredDatabase() throws -> OpaquePointer {
        guard let database else { throw RuntimeJobError.repositoryClosed }
        return database
    }

    private func mappedError(_ code: Int32) -> Error {
        if code == SQLITE_BUSY || code == SQLITE_LOCKED { return ProjectContextError.databaseBusy }
        if code == SQLITE_FULL { return ProjectContextError.storageFull }
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(code)"
        return RuntimeJobError.storageFailure(message)
    }

    private enum SQLiteBinding {
        case text(String)
        case optionalText(String?)
        case int64(Int64)
        case optionalInt64(Int64?)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case .optionalText(let value):
                if let value {
                    result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
                } else {
                    result = sqlite3_bind_null(statement, index)
                }
            case .int64(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .optionalInt64(let value):
                if let value {
                    result = sqlite3_bind_int64(statement, index, value)
                } else {
                    result = sqlite3_bind_null(statement, index)
                }
            }
            guard result == SQLITE_OK else {
                throw RuntimeJobError.storageFailure("could not bind SQLite value")
            }
        }
    }

    private static func openAndMigrate(
        databaseURL: URL,
        busyTimeoutMilliseconds: Int,
        timestamp: String
    ) throws -> OpaquePointer {
        try VerifiedMigrationBackup.withMigrationLock(
            databaseURL: databaseURL,
            timeoutSeconds: 60
        ) {
            do {
                try VerifiedMigrationBackup.withNonMutatingSQLitePreflight(
                    databaseURL: databaseURL
                ) { candidate in
                    guard let candidate else { return }
                    let hasRuntimeVersion = try candidate.integer(
                        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='runtime_job_schema_version'"
                    ) == 1
                    if hasRuntimeVersion {
                        let rowCount = try candidate.integer(
                            "SELECT COUNT(*) FROM runtime_job_schema_version"
                        ) ?? 0
                        let version = try candidate.integer(
                            "SELECT version FROM runtime_job_schema_version WHERE singleton=1"
                        ) ?? 0
                        guard rowCount == 1, (1...schemaVersion).contains(version) else {
                            throw RuntimeJobError.storageFailure(
                                "unsupported runtime job schema version \(version)"
                            )
                        }
                        return
                    }
                    if try isExactCoResidentControlPlaneV2(candidate) {
                        return
                    }
                    try candidate.requireEmptySchemaWhenUnversioned(reportedVersion: 0)
                }
            } catch let error as RuntimeJobError {
                throw error
            } catch {
                throw RuntimeJobError.storageFailure(error.localizedDescription)
            }
            return try openAndMigrateLocked(
                databaseURL: databaseURL,
                busyTimeoutMilliseconds: busyTimeoutMilliseconds,
                timestamp: timestamp
            )
        }
    }

    private static func openAndMigrateLocked(
        databaseURL: URL,
        busyTimeoutMilliseconds: Int,
        timestamp: String
    ) throws -> OpaquePointer {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(databaseURL.path, &connection, flags, nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open error \(result)"
            if let connection { sqlite3_close(connection) }
            throw RuntimeJobError.storageFailure(message)
        }
        do {
            sqlite3_busy_timeout(connection, Int32(busyTimeoutMilliseconds))
            let hasVersionTable = try rawScalarInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='runtime_job_schema_version'",
                database: connection
            ) == 1
            let prior = hasVersionTable
                ? try rawScalarInt(
                    "SELECT version FROM runtime_job_schema_version WHERE singleton=1",
                    database: connection
                ) ?? 0
                : 0
            let isCurrentCoResidentControlPlane: Bool
            if hasVersionTable {
                isCurrentCoResidentControlPlane = false
            } else {
                isCurrentCoResidentControlPlane = try isExactCoResidentControlPlaneV2(connection)
            }
            if !isCurrentCoResidentControlPlane {
                do {
                    try VerifiedMigrationBackup.requireEmptySQLiteSchemaWhenUnversioned(
                        database: connection,
                        reportedVersion: prior
                    )
                } catch {
                    throw RuntimeJobError.storageFailure(error.localizedDescription)
                }
            }
            guard prior <= schemaVersion else {
                throw RuntimeJobError.storageFailure(
                    "unsupported runtime job schema version \(prior)"
                )
            }
            try rawExecute("PRAGMA foreign_keys=ON", database: connection)
            try rawExecute("PRAGMA journal_mode=WAL", database: connection)
            try rawExecute("PRAGMA synchronous=NORMAL", database: connection)
            try rawExecute("PRAGMA busy_timeout=\(busyTimeoutMilliseconds)", database: connection)
            if prior > 0, prior < schemaVersion {
                let stem = databaseURL.deletingPathExtension().lastPathComponent
                let backupURL = databaseURL.deletingLastPathComponent().appendingPathComponent(
                    "\(stem).pre-migration-v\(prior).sqlite3",
                    isDirectory: false
                )
                _ = try VerifiedMigrationBackup.snapshotSQLite(
                    database: connection,
                    to: backupURL,
                    expectedVersion: prior,
                    versionQuery: "SELECT version FROM runtime_job_schema_version WHERE singleton=1"
                )
            }
            try rawExecute("BEGIN IMMEDIATE", database: connection)
            do {
                try rawExecute(schema, database: connection)
                if !rawTableHasColumn(
                    table: "runtime_job_output_streams",
                    column: "artifact_evicted_at",
                    database: connection
                ) {
                    try rawExecute(
                        "ALTER TABLE runtime_job_output_streams ADD COLUMN artifact_evicted_at TEXT",
                        database: connection
                    )
                }
                if !rawTableHasColumn(
                    table: "execution_jobs",
                    column: "process_start_seconds",
                    database: connection
                ) {
                    try rawExecute(
                        "ALTER TABLE execution_jobs ADD COLUMN process_start_seconds INTEGER CHECK(process_start_seconds>0)",
                        database: connection
                    )
                }
                if !rawTableHasColumn(
                    table: "execution_jobs",
                    column: "process_start_microseconds",
                    database: connection
                ) {
                    try rawExecute(
                        """
                        ALTER TABLE execution_jobs ADD COLUMN process_start_microseconds INTEGER
                        CHECK(process_start_microseconds>=0 AND process_start_microseconds<1000000)
                        """,
                        database: connection
                    )
                }
                if !rawTableHasColumn(
                    table: "runtime_job_output_streams",
                    column: "artifact_device_identifier",
                    database: connection
                ) {
                    try rawExecute(
                        """
                        ALTER TABLE runtime_job_output_streams
                        ADD COLUMN artifact_device_identifier INTEGER
                        CHECK(artifact_device_identifier>=0)
                        """,
                        database: connection
                    )
                }
                if !rawTableHasColumn(
                    table: "runtime_job_output_streams",
                    column: "artifact_file_identifier",
                    database: connection
                ) {
                    try rawExecute(
                        """
                        ALTER TABLE runtime_job_output_streams
                        ADD COLUMN artifact_file_identifier INTEGER
                        CHECK(artifact_file_identifier>=0)
                        """,
                        database: connection
                    )
                }
                if !rawTableHasColumn(
                    table: "runtime_job_details",
                    column: "termination_phase",
                    database: connection
                ) {
                    try rawExecute(
                        """
                        ALTER TABLE runtime_job_details ADD COLUMN termination_phase TEXT NOT NULL
                        DEFAULT 'idle' CHECK(termination_phase IN (
                            'idle','term_pending','term_sent','kill_pending','kill_sent',
                            'confirmed','unconfirmed'
                        ))
                        """,
                        database: connection
                    )
                }
                if !rawTableHasColumn(
                    table: "runtime_job_details",
                    column: "termination_probe_deadline",
                    database: connection
                ) {
                    try rawExecute(
                        "ALTER TABLE runtime_job_details ADD COLUMN termination_probe_deadline TEXT",
                        database: connection
                    )
                }
                if !rawTableHasColumn(
                    table: "runtime_job_details",
                    column: "termination_error_summary",
                    database: connection
                ) {
                    try rawExecute(
                        "ALTER TABLE runtime_job_details ADD COLUMN termination_error_summary TEXT",
                        database: connection
                    )
                }
                try rawExecute(idempotencyReceiptSchema, database: connection)
                try rawExecute(
                    """
                    INSERT INTO runtime_job_schema_version(singleton,version,applied_at)
                    VALUES(1,\(schemaVersion),?)
                    ON CONFLICT(singleton) DO UPDATE SET version=excluded.version,applied_at=excluded.applied_at
                    """,
                    database: connection,
                    bindings: [.text(timestamp)]
                )
                let integrity = try rawScalarText("PRAGMA quick_check", database: connection) ?? "missing"
                guard integrity.lowercased() == "ok" else {
                    throw RuntimeJobError.storageFailure("SQLite quick check failed: \(integrity)")
                }
                try rawExecute("COMMIT", database: connection)
            } catch {
                _ = try? rawExecute("ROLLBACK", database: connection)
                throw error
            }
            return connection
        } catch {
            sqlite3_close(connection)
            throw error
        }
    }

    private static func isExactCoResidentControlPlaneV2(
        _ candidate: SQLitePreflightDatabase
    ) throws -> Bool {
        let versionTableCount = try candidate.integer(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='control_schema_version'"
        ) ?? 0
        guard versionTableCount == 1 else { return false }
        let versionRowCount = try candidate.integer(
            "SELECT COUNT(*) FROM control_schema_version"
        ) ?? 0
        let version = try candidate.integer(
            "SELECT version FROM control_schema_version WHERE singleton=1"
        )
        let userVersion = try candidate.integer("PRAGMA user_version;") ?? 0
        let requiredTableCount = try candidate.integer(controlPlaneV2RequiredTableCountSQL) ?? 0
        guard versionRowCount == 1
            && version == ProjectControlPlaneRepository.schemaVersion
            && userVersion == ProjectControlPlaneRepository.schemaVersion
            && requiredTableCount == controlPlaneV2RequiredSurfaces.count else {
            return false
        }
        for surface in controlPlaneV2RequiredSurfaces {
            let columnList = surface.columns.map { "'\($0)'" }.joined(separator: ",")
            let totalCount = try candidate.integer(
                "SELECT COUNT(*) FROM pragma_table_info('\(surface.name)')"
            ) ?? 0
            let matchedCount = try candidate.integer(
                "SELECT COUNT(*) FROM pragma_table_info('\(surface.name)') WHERE name IN (\(columnList))"
            ) ?? 0
            guard totalCount == surface.columns.count,
                  matchedCount == surface.columns.count else {
                return false
            }
        }
        return true
    }

    private static func isExactCoResidentControlPlaneV2(
        _ database: OpaquePointer
    ) throws -> Bool {
        let versionTableCount = try rawScalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='control_schema_version'",
            database: database
        ) ?? 0
        guard versionTableCount == 1 else { return false }
        let versionRowCount = try rawScalarInt(
            "SELECT COUNT(*) FROM control_schema_version",
            database: database
        ) ?? 0
        let version = try rawScalarInt(
            "SELECT version FROM control_schema_version WHERE singleton=1",
            database: database
        )
        let userVersion = try rawScalarInt("PRAGMA user_version", database: database) ?? 0
        let requiredTableCount = try rawScalarInt(
            controlPlaneV2RequiredTableCountSQL,
            database: database
        ) ?? 0
        guard versionRowCount == 1
            && version == ProjectControlPlaneRepository.schemaVersion
            && userVersion == ProjectControlPlaneRepository.schemaVersion
            && requiredTableCount == controlPlaneV2RequiredSurfaces.count else {
            return false
        }
        for surface in controlPlaneV2RequiredSurfaces {
            let columnList = surface.columns.map { "'\($0)'" }.joined(separator: ",")
            let totalCount = try rawScalarInt(
                "SELECT COUNT(*) FROM pragma_table_info('\(surface.name)')",
                database: database
            ) ?? 0
            let matchedCount = try rawScalarInt(
                "SELECT COUNT(*) FROM pragma_table_info('\(surface.name)') WHERE name IN (\(columnList))",
                database: database
            ) ?? 0
            guard totalCount == surface.columns.count,
                  matchedCount == surface.columns.count else {
                return false
            }
        }
        return true
    }

    @discardableResult
    private static func rawExecute(
        _ sql: String,
        database: OpaquePointer,
        bindings: [SQLiteBinding] = []
    ) throws -> Int {
        if bindings.isEmpty {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
            if result != SQLITE_OK {
                let message = errorMessage.map { String(cString: $0) }
                    ?? String(cString: sqlite3_errmsg(database))
                sqlite3_free(errorMessage)
                throw RuntimeJobError.storageFailure(message)
            }
            return Int(sqlite3_changes(database))
        }
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else {
            throw RuntimeJobError.storageFailure(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return Int(sqlite3_changes(database)) }
            if step == SQLITE_ROW { continue }
            throw RuntimeJobError.storageFailure(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func rawScalarInt(_ sql: String, database: OpaquePointer) throws -> Int? {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else {
            throw RuntimeJobError.storageFailure(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw RuntimeJobError.storageFailure(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func rawScalarText(_ sql: String, database: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else {
            throw RuntimeJobError.storageFailure(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw RuntimeJobError.storageFailure(String(cString: sqlite3_errmsg(database)))
        }
        return optionalText(statement, column: 0)
    }

    private static func rawTableHasColumn(
        table: String,
        column: String,
        database: OpaquePointer
    ) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if optionalText(statement, column: 1) == column { return true }
        }
        return false
    }

    private static func decodeRecord(_ statement: OpaquePointer) throws -> RuntimeJobRecord {
        guard let jobText = requiredText(statement, column: 0),
              let jobID = UUID(uuidString: jobText),
              let projectText = requiredText(statement, column: 2),
              let projectUUID = UUID(uuidString: projectText),
              let kindText = requiredText(statement, column: 4),
              let kind = RuntimeKind(rawValue: kindText),
              let profileText = requiredText(statement, column: 5),
              let profile = RuntimeExecutionProfile(rawValue: profileText),
              let replayText = requiredText(statement, column: 6),
              let replay = RuntimeReplayClass(rawValue: replayText),
              let stateText = requiredText(statement, column: 8),
              let state = RuntimeJobState(rawValue: stateText),
              let cwd = requiredText(statement, column: 9),
              let summary = requiredText(statement, column: 10),
              let created = requiredText(statement, column: 17),
              let updated = requiredText(statement, column: 20) else {
            throw RuntimeJobError.storageFailure("invalid execution job row")
        }
        let generation = sqlite3_column_int64(statement, 3)
        guard generation > 0 else { throw RuntimeJobError.storageFailure("invalid job generation") }
        let runID: RunID?
        if let value = optionalText(statement, column: 1) {
            guard let uuid = UUID(uuidString: value) else {
                throw RuntimeJobError.storageFailure("invalid stored run identifier")
            }
            runID = RunID(uuid)
        } else {
            runID = nil
        }
        let exitCode = sqlite3_column_type(statement, 12) == SQLITE_NULL
            ? nil : Int32(exactly: sqlite3_column_int64(statement, 12))
        let pid = sqlite3_column_type(statement, 15) == SQLITE_NULL
            ? nil : Int32(exactly: sqlite3_column_int64(statement, 15))
        let pgid = sqlite3_column_type(statement, 16) == SQLITE_NULL
            ? nil : Int32(exactly: sqlite3_column_int64(statement, 16))
        return RuntimeJobRecord(
            jobID: jobID,
            runID: runID,
            projectID: ProjectID(projectUUID),
            projectGeneration: ProjectGeneration(UInt64(generation)),
            runtimeKind: kind,
            executionProfile: profile,
            replayClass: replay,
            idempotencyKey: optionalText(statement, column: 7),
            state: state,
            canonicalWorkingDirectory: URL(fileURLWithPath: cwd),
            commandSummary: summary,
            timeoutSeconds: Int(sqlite3_column_int64(statement, 11)),
            exitCode: exitCode,
            outputArtifactID: optionalText(statement, column: 13),
            outputBytes: UInt64(max(0, sqlite3_column_int64(statement, 14))),
            processIdentifier: pid,
            processGroupIdentifier: pgid,
            errorCode: optionalText(statement, column: 21),
            errorSummary: optionalText(statement, column: 22),
            createdAt: created,
            startedAt: optionalText(statement, column: 18),
            completedAt: optionalText(statement, column: 19),
            updatedAt: updated
        )
    }

    private static func decodeOutput(_ statement: OpaquePointer) throws -> RuntimeJobOutputMetadata {
        guard let jobText = requiredText(statement, column: 0),
              let jobID = UUID(uuidString: jobText),
              let streamText = requiredText(statement, column: 1),
              let stream = RuntimeOutputStream(rawValue: streamText),
              let inline = requiredText(statement, column: 2),
              let sha256 = requiredText(statement, column: 8) else {
            throw RuntimeJobError.storageFailure("invalid runtime output row")
        }
        let deviceIdentifier = try optionalNonnegativeUInt64(statement, column: 4)
        let fileIdentifier = try optionalNonnegativeUInt64(statement, column: 5)
        let artifactPath = optionalText(statement, column: 3)
        guard (artifactPath == nil && deviceIdentifier == nil && fileIdentifier == nil)
                || (artifactPath != nil && (
                    (deviceIdentifier == nil && fileIdentifier == nil)
                        || (deviceIdentifier != nil && fileIdentifier != nil)
                )) else {
            throw RuntimeJobError.storageFailure("incomplete runtime artifact identity")
        }
        return RuntimeJobOutputMetadata(
            jobID: jobID,
            stream: stream,
            inlineText: inline,
            artifactRelativePath: artifactPath,
            artifactDeviceIdentifier: deviceIdentifier,
            artifactFileIdentifier: fileIdentifier,
            byteCount: UInt64(max(0, sqlite3_column_int64(statement, 6))),
            retainedByteCount: UInt64(max(0, sqlite3_column_int64(statement, 7))),
            sha256: sha256,
            inlineTruncated: sqlite3_column_int(statement, 9) != 0,
            artifactTruncated: sqlite3_column_int(statement, 10) != 0,
            artifactEvicted: sqlite3_column_type(statement, 11) != SQLITE_NULL
        )
    }

    private static func optionalNonnegativeUInt64(
        _ statement: OpaquePointer,
        column: Int32
    ) throws -> UInt64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let value = sqlite3_column_int64(statement, column)
        guard value >= 0 else {
            throw RuntimeJobError.storageFailure("invalid negative runtime artifact identity")
        }
        return UInt64(value)
    }

    private static func requiredText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private static func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        requiredText(statement, column: column)
    }

    private static func validateTerminalTransition(from: RuntimeJobState, to: RuntimeJobState) throws {
        let allowed: Bool
        switch (from, to) {
        case (.running, .completed), (.running, .failed), (.running, .timedOut),
             (.running, .cancelled), (.running, .quarantinedStale),
             (.cancelling, .completed), (.cancelling, .cancelled),
             (.cancelling, .failed), (.cancelling, .timedOut),
             (.cancelling, .quarantinedStale),
             (.queued, .failed), (.queued, .cancelled), (.queued, .quarantinedStale):
            allowed = true
        default:
            allowed = false
        }
        guard allowed else { throw RuntimeJobError.invalidTransition(from: from, to: to) }
    }

    private static func bounded(_ value: String, maximumBytes: Int, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumBytes else {
            throw RuntimeJobError.invalidRequest("\(field) is empty or exceeds its byte limit")
        }
        return trimmed
    }

    private static func boundedIdempotencyKey(_ value: String) throws -> String {
        try bounded(value, maximumBytes: 512, field: "idempotency key")
    }

    private static func boundedRelativePath(_ value: String, field: String) throws -> String {
        let bounded = try bounded(value, maximumBytes: 2_048, field: field)
        let components = bounded.split(separator: "/", omittingEmptySubsequences: false)
        guard !bounded.hasPrefix("/"),
              !components.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
            throw RuntimeJobError.invalidRequest("\(field) must be relative")
        }
        return bounded
    }

    private static func sqliteGeneration(_ generation: ProjectGeneration) throws -> Int64 {
        guard generation.rawValue > 0, generation.rawValue <= UInt64(Int64.max) else {
            throw ProjectContextError.invalidGeneration(generation.rawValue)
        }
        return Int64(generation.rawValue)
    }

    private static func sqliteBytes(_ bytes: UInt64) -> Int64 {
        Int64(min(bytes, UInt64(Int64.max)))
    }

    private static func uuid(_ value: UUID) -> String { value.uuidString.lowercased() }

    private static let selectRecord = """
    SELECT j.job_id,j.run_id,j.project_id,j.project_generation,j.runtime_kind,j.execution_profile,
           j.replay_class,j.idempotency_key,j.state,j.canonical_cwd,j.command_summary,
           j.timeout_seconds,j.exit_code,j.output_artifact_id,j.output_bytes,
           j.process_identifier,j.process_group_identifier,j.created_at,j.started_at,
           j.completed_at,j.updated_at,d.error_code,d.error_summary
    FROM execution_jobs j LEFT JOIN runtime_job_details d ON d.job_id=j.job_id
    """

    private static let selectReceiptRecord = """
    SELECT r.job_id,r.run_id,r.project_id,r.project_generation,r.runtime_kind,r.execution_profile,
           r.replay_class,r.idempotency_key,r.state,r.canonical_cwd,r.command_summary,
           r.timeout_seconds,r.exit_code,NULL,r.output_bytes,NULL,NULL,r.created_at,r.started_at,
           r.completed_at,r.updated_at,r.error_code,r.error_summary
    FROM runtime_job_idempotency_receipts r
    """

    private static let schema = """
    CREATE TABLE IF NOT EXISTS runtime_job_schema_version (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        version INTEGER NOT NULL CHECK(version>=1),
        applied_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS execution_jobs (
        job_id TEXT PRIMARY KEY,
        run_id TEXT REFERENCES autonomous_runs(run_id) ON DELETE SET NULL,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        project_generation INTEGER NOT NULL CHECK(project_generation>=1),
        runtime_kind TEXT NOT NULL CHECK(runtime_kind IN ('process','shell','bash','python','powershell')),
        execution_profile TEXT NOT NULL CHECK(execution_profile IN (
            'direct_process','zsh_no_profile','bash_no_profile','legacy_bash_login',
            'python_isolated','powershell_no_profile')),
        replay_class TEXT NOT NULL CHECK(replay_class IN ('read_only','idempotent','reconciled','non_replayable')),
        idempotency_key TEXT,
        state TEXT NOT NULL CHECK(state IN (
            'queued','running','cancelling','completed','failed','timed_out','cancelled','quarantined_stale')),
        canonical_cwd TEXT NOT NULL,
        command_summary TEXT NOT NULL,
        timeout_seconds INTEGER NOT NULL CHECK(timeout_seconds>0),
        exit_code INTEGER,
        stdout_inline TEXT,
        stderr_inline TEXT,
        output_artifact_id TEXT,
        output_bytes INTEGER NOT NULL DEFAULT 0 CHECK(output_bytes>=0),
        process_identifier INTEGER,
        process_group_identifier INTEGER,
        process_start_seconds INTEGER CHECK(process_start_seconds>0),
        process_start_microseconds INTEGER CHECK(
            process_start_microseconds>=0 AND process_start_microseconds<1000000
        ),
        created_at TEXT NOT NULL,
        started_at TEXT,
        completed_at TEXT,
        updated_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_jobs_project_state
        ON execution_jobs(project_id,project_generation,state);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_project_idempotency
        ON execution_jobs(project_id,project_generation,idempotency_key)
        WHERE idempotency_key IS NOT NULL;

    CREATE TABLE IF NOT EXISTS runtime_job_details (
        job_id TEXT PRIMARY KEY REFERENCES execution_jobs(job_id) ON DELETE CASCADE,
        request_artifact_relative_path TEXT,
        error_code TEXT,
        error_summary TEXT,
        termination_phase TEXT NOT NULL DEFAULT 'idle' CHECK(termination_phase IN (
            'idle','term_pending','term_sent','kill_pending','kill_sent','confirmed','unconfirmed'
        )),
        termination_probe_deadline TEXT,
        termination_error_summary TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS runtime_job_output_streams (
        job_id TEXT NOT NULL REFERENCES execution_jobs(job_id) ON DELETE CASCADE,
        stream TEXT NOT NULL CHECK(stream IN ('stdout','stderr')),
        inline_text TEXT NOT NULL,
        artifact_relative_path TEXT,
        artifact_device_identifier INTEGER CHECK(artifact_device_identifier>=0),
        artifact_file_identifier INTEGER CHECK(artifact_file_identifier>=0),
        byte_count INTEGER NOT NULL CHECK(byte_count>=0),
        retained_byte_count INTEGER NOT NULL CHECK(retained_byte_count>=0),
        sha256 TEXT NOT NULL,
        inline_truncated INTEGER NOT NULL CHECK(inline_truncated IN (0,1)),
        artifact_truncated INTEGER NOT NULL CHECK(artifact_truncated IN (0,1)),
        artifact_evicted_at TEXT,
        PRIMARY KEY(job_id,stream)
    );
    """

    private static let idempotencyReceiptSchema = """
    CREATE TABLE IF NOT EXISTS runtime_job_idempotency_receipts (
        job_id TEXT PRIMARY KEY,
        run_id TEXT REFERENCES autonomous_runs(run_id) ON DELETE SET NULL,
        project_id TEXT NOT NULL REFERENCES control_projects(project_id) ON DELETE CASCADE,
        project_generation INTEGER NOT NULL CHECK(project_generation>=1),
        runtime_kind TEXT NOT NULL CHECK(runtime_kind IN ('process','shell','bash','python','powershell')),
        execution_profile TEXT NOT NULL CHECK(execution_profile IN (
            'direct_process','zsh_no_profile','bash_no_profile','legacy_bash_login',
            'python_isolated','powershell_no_profile')),
        replay_class TEXT NOT NULL CHECK(replay_class IN (
            'read_only','idempotent','reconciled','non_replayable')),
        idempotency_key TEXT NOT NULL,
        state TEXT NOT NULL CHECK(state IN (
            'completed','failed','timed_out','cancelled','quarantined_stale')),
        canonical_cwd TEXT NOT NULL,
        command_summary TEXT NOT NULL,
        timeout_seconds INTEGER NOT NULL CHECK(timeout_seconds>0),
        exit_code INTEGER,
        output_bytes INTEGER NOT NULL CHECK(output_bytes>=0),
        error_code TEXT,
        error_summary TEXT,
        created_at TEXT NOT NULL,
        started_at TEXT,
        completed_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        compacted_at TEXT NOT NULL,
        UNIQUE(project_id,project_generation,idempotency_key)
    );
    CREATE INDEX IF NOT EXISTS idx_runtime_job_receipts_project_completed
        ON runtime_job_idempotency_receipts(project_id,project_generation,completed_at DESC);
    """
}

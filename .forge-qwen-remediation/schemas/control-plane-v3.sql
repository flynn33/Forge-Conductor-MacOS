PRAGMA foreign_keys = ON;

-- Extension blueprint for the current Forge Conductor control plane. Production
-- migrations must preserve existing tables and apply these definitions through
-- the repository's crash-safe migration framework.

CREATE TABLE IF NOT EXISTS remediation_schema_metadata (
    component TEXT PRIMARY KEY,
    schema_version INTEGER NOT NULL CHECK(schema_version >= 1),
    migrated_at TEXT NOT NULL,
    migration_receipt_sha256 TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS gate_definitions (
    gate_id TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK(revision >= 1),
    validator_id TEXT NOT NULL,
    validator_version TEXT NOT NULL,
    project_id TEXT NOT NULL,
    project_generation INTEGER NOT NULL CHECK(project_generation >= 1),
    package_run_id TEXT,
    run_id TEXT,
    parameters_json BLOB NOT NULL,
    parameters_sha256 TEXT NOT NULL,
    timeout_seconds INTEGER NOT NULL CHECK(timeout_seconds BETWEEN 1 AND 86400),
    required_platform TEXT NOT NULL,
    mandatory INTEGER NOT NULL CHECK(mandatory IN (0,1)),
    created_at TEXT NOT NULL,
    PRIMARY KEY(gate_id, revision)
) STRICT;

CREATE TABLE IF NOT EXISTS completion_claims (
    claim_id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    project_generation INTEGER NOT NULL CHECK(project_generation >= 1),
    package_run_id TEXT,
    run_id TEXT NOT NULL,
    expected_run_revision INTEGER NOT NULL CHECK(expected_run_revision >= 1),
    provider_summary TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('requested','validating','blocked_validation','accepted','superseded')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS gate_executions (
    execution_id TEXT PRIMARY KEY,
    gate_id TEXT NOT NULL,
    gate_revision INTEGER NOT NULL CHECK(gate_revision >= 1),
    claim_id TEXT,
    lease_owner TEXT,
    lease_epoch INTEGER NOT NULL DEFAULT 1 CHECK(lease_epoch >= 1),
    state TEXT NOT NULL CHECK(state IN ('pending','running','passed','failed','blocked_environment','cancelled','timed_out','superseded')),
    source_manifest_before TEXT NOT NULL,
    source_manifest_after TEXT,
    started_at TEXT,
    ended_at TEXT,
    expected_run_revision INTEGER,
    result_sha256 TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(gate_id, gate_revision) REFERENCES gate_definitions(gate_id, revision),
    FOREIGN KEY(claim_id) REFERENCES completion_claims(claim_id)
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS one_running_gate_execution
ON gate_executions(gate_id, gate_revision, COALESCE(claim_id, ''))
WHERE state = 'running';

CREATE TABLE IF NOT EXISTS gate_results (
    execution_id TEXT PRIMARY KEY,
    passed INTEGER NOT NULL CHECK(passed IN (0,1)),
    status TEXT NOT NULL,
    summary TEXT NOT NULL,
    exit_code INTEGER,
    receipt_json BLOB NOT NULL,
    receipt_sha256 TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    FOREIGN KEY(execution_id) REFERENCES gate_executions(execution_id) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS gate_artifacts (
    execution_id TEXT NOT NULL,
    role TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
    sha256 TEXT NOT NULL,
    PRIMARY KEY(execution_id, role, relative_path),
    FOREIGN KEY(execution_id) REFERENCES gate_executions(execution_id) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS package_candidates (
    candidate_id TEXT PRIMARY KEY,
    source_display_path TEXT NOT NULL,
    source_identity_json BLOB NOT NULL,
    transaction_id TEXT,
    state TEXT NOT NULL CHECK(state IN ('discovered','staging','structural_validation','content_validation','immutable_commit','cataloged','invalid','quarantined','retry_waiting')),
    reason_code TEXT,
    compressed_bytes INTEGER CHECK(compressed_bytes IS NULL OR compressed_bytes >= 0),
    expanded_bytes INTEGER CHECK(expanded_bytes IS NULL OR expanded_bytes >= 0),
    entry_count INTEGER CHECK(entry_count IS NULL OR entry_count >= 0),
    discovered_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS package_ingestion_transactions (
    transaction_id TEXT PRIMARY KEY,
    candidate_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('intent','copying','validating','synchronizing','publishing','committed','quarantined','failed')),
    staging_relative_path TEXT NOT NULL,
    expected_content_sha256 TEXT,
    committed_content_sha256 TEXT,
    attempt INTEGER NOT NULL DEFAULT 1 CHECK(attempt >= 1),
    receipt_json BLOB,
    receipt_sha256 TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(candidate_id) REFERENCES package_candidates(candidate_id)
) STRICT;

CREATE TABLE IF NOT EXISTS packages (
    package_id TEXT NOT NULL,
    version TEXT NOT NULL,
    content_sha256 TEXT NOT NULL UNIQUE,
    canonical_manifest_json BLOB NOT NULL,
    canonical_manifest_sha256 TEXT NOT NULL,
    store_relative_path TEXT NOT NULL UNIQUE,
    source_format TEXT NOT NULL,
    accepted_at TEXT NOT NULL,
    PRIMARY KEY(package_id, version)
) STRICT;

CREATE TABLE IF NOT EXISTS package_dependencies (
    package_content_sha256 TEXT NOT NULL,
    dependency_package_id TEXT NOT NULL,
    dependency_version_constraint TEXT,
    PRIMARY KEY(package_content_sha256, dependency_package_id),
    FOREIGN KEY(package_content_sha256) REFERENCES packages(content_sha256) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS package_runs (
    package_run_id TEXT PRIMARY KEY,
    package_content_sha256 TEXT NOT NULL,
    project_id TEXT NOT NULL,
    project_generation INTEGER NOT NULL CHECK(project_generation >= 1),
    state TEXT NOT NULL CHECK(state IN ('ready','reserved','running','checkpointing','validating_completion','completed','paused','blocked','retry_waiting','failed','cancelled')),
    priority INTEGER NOT NULL DEFAULT 0,
    effective_priority INTEGER NOT NULL DEFAULT 0,
    attempt INTEGER NOT NULL DEFAULT 1 CHECK(attempt >= 1),
    revision INTEGER NOT NULL DEFAULT 1 CHECK(revision >= 1),
    not_before TEXT,
    mission TEXT NOT NULL,
    assignment_json BLOB,
    terminal_receipt_sha256 TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(package_content_sha256) REFERENCES packages(content_sha256)
) STRICT;

CREATE INDEX IF NOT EXISTS package_runs_schedulable
ON package_runs(state, effective_priority DESC, created_at, package_run_id);

CREATE UNIQUE INDEX IF NOT EXISTS one_nonterminal_attempt_per_package_project
ON package_runs(package_content_sha256, project_id, project_generation)
WHERE state IN ('reserved','running','checkpointing','validating_completion');

CREATE TABLE IF NOT EXISTS queue_leases (
    package_run_id TEXT PRIMARY KEY,
    manager_id TEXT NOT NULL,
    lease_epoch INTEGER NOT NULL CHECK(lease_epoch >= 1),
    acquired_at TEXT NOT NULL,
    heartbeat_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    FOREIGN KEY(package_run_id) REFERENCES package_runs(package_run_id) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS queue_events (
    event_id TEXT PRIMARY KEY,
    package_run_id TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK(revision >= 1),
    event_kind TEXT NOT NULL,
    payload_json BLOB NOT NULL,
    previous_event_sha256 TEXT,
    event_sha256 TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    FOREIGN KEY(package_run_id) REFERENCES package_runs(package_run_id) ON DELETE CASCADE
) STRICT;

CREATE INDEX IF NOT EXISTS queue_events_by_run
ON queue_events(package_run_id, created_at, event_id);

CREATE TABLE IF NOT EXISTS package_progress (
    package_run_id TEXT NOT NULL,
    sequence INTEGER NOT NULL CHECK(sequence >= 1),
    progress_kind TEXT NOT NULL,
    summary TEXT NOT NULL,
    bounded_details_json BLOB,
    created_at TEXT NOT NULL,
    PRIMARY KEY(package_run_id, sequence),
    FOREIGN KEY(package_run_id) REFERENCES package_runs(package_run_id) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS package_artifacts (
    artifact_id TEXT PRIMARY KEY,
    package_run_id TEXT NOT NULL,
    role TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    media_type TEXT,
    byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
    sha256 TEXT NOT NULL,
    producer_operation_id TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY(package_run_id) REFERENCES package_runs(package_run_id) ON DELETE CASCADE
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS package_artifact_identity
ON package_artifacts(package_run_id, role, sha256);

CREATE TABLE IF NOT EXISTS project_maintenance_leases (
    project_id TEXT NOT NULL,
    project_generation INTEGER NOT NULL CHECK(project_generation >= 1),
    lease_owner TEXT NOT NULL,
    lease_epoch INTEGER NOT NULL CHECK(lease_epoch >= 1),
    operation_id TEXT NOT NULL,
    acquired_at TEXT NOT NULL,
    heartbeat_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    PRIMARY KEY(project_id, project_generation)
) STRICT;

CREATE TABLE IF NOT EXISTS project_reset_operations (
    reset_id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    old_generation INTEGER NOT NULL CHECK(old_generation >= 1),
    new_generation INTEGER CHECK(new_generation IS NULL OR new_generation > old_generation),
    mode TEXT NOT NULL CHECK(mode IN ('memory','continuity','memory_and_continuity','run_history')),
    state TEXT NOT NULL CHECK(state IN ('intent','maintenance_acquired','fencing','draining','backing_up','rotating','generation_committed','rebuilding','completed','failed','restoring')),
    expected_project_revision INTEGER NOT NULL CHECK(expected_project_revision >= 1),
    backup_id TEXT,
    intent_json BLOB NOT NULL,
    receipt_json BLOB,
    receipt_sha256 TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS project_reset_backups (
    backup_id TEXT PRIMARY KEY,
    reset_id TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
    sha256 TEXT NOT NULL,
    verified_at TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY(reset_id) REFERENCES project_reset_operations(reset_id) ON DELETE CASCADE
) STRICT;

CREATE TABLE IF NOT EXISTS runtime_xpc_profiles (
    profile_id TEXT PRIMARY KEY,
    revision INTEGER NOT NULL CHECK(revision >= 1),
    isolation_kind TEXT NOT NULL CHECK(isolation_kind IN ('workspace_isolated','hardened_xpc')),
    network_policy TEXT NOT NULL,
    environment_allowlist_json BLOB NOT NULL,
    maximum_output_bytes INTEGER NOT NULL CHECK(maximum_output_bytes > 0),
    maximum_seconds INTEGER NOT NULL CHECK(maximum_seconds > 0),
    created_at TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS security_scoped_bookmarks (
    bookmark_id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    project_generation INTEGER NOT NULL CHECK(project_generation >= 1),
    encrypted_bookmark BLOB NOT NULL,
    stale INTEGER NOT NULL DEFAULT 0 CHECK(stale IN (0,1)),
    created_at TEXT NOT NULL,
    refreshed_at TEXT
) STRICT;

CREATE TABLE IF NOT EXISTS runtime_xpc_receipts (
    job_id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    project_generation INTEGER NOT NULL CHECK(project_generation >= 1),
    profile_id TEXT NOT NULL,
    lease_epoch INTEGER NOT NULL CHECK(lease_epoch >= 1),
    request_sha256 TEXT NOT NULL,
    result_sha256 TEXT,
    state TEXT NOT NULL CHECK(state IN ('accepted','running','completed','failed','cancelled','timed_out','connection_lost','unknown')),
    process_identifier INTEGER,
    started_at TEXT,
    ended_at TEXT,
    receipt_json BLOB,
    FOREIGN KEY(profile_id) REFERENCES runtime_xpc_profiles(profile_id)
) STRICT;

CREATE TABLE IF NOT EXISTS retention_operations (
    operation_id TEXT PRIMARY KEY,
    project_id TEXT,
    table_name TEXT NOT NULL,
    cutoff TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('intent','selecting','archiving','archive_verified','deleting','completed','failed')),
    archive_relative_path TEXT,
    archive_sha256 TEXT,
    rows_archived INTEGER NOT NULL DEFAULT 0 CHECK(rows_archived >= 0),
    rows_deleted INTEGER NOT NULL DEFAULT 0 CHECK(rows_deleted >= 0),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS protected_event_references (
    event_table TEXT NOT NULL,
    event_id TEXT NOT NULL,
    owner_kind TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    PRIMARY KEY(event_table, event_id, owner_kind, owner_id)
) STRICT;

CREATE TABLE IF NOT EXISTS release_attestations (
    attestation_id TEXT PRIMARY KEY,
    source_archive_sha256 TEXT NOT NULL,
    source_manifest_sha256 TEXT NOT NULL,
    git_commit TEXT,
    git_tree TEXT,
    release_candidate_relative_path TEXT NOT NULL,
    release_candidate_sha256 TEXT NOT NULL,
    ready_to_ship INTEGER NOT NULL CHECK(ready_to_ship = 1),
    shipped INTEGER NOT NULL CHECK(shipped = 0),
    document_json BLOB NOT NULL,
    document_sha256 TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL
) STRICT;

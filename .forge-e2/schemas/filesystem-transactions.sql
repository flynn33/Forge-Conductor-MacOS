PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS filesystem_transactions (
    transaction_id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    project_generation INTEGER NOT NULL,
    operation TEXT NOT NULL,
    state TEXT NOT NULL,
    source_root_id TEXT NOT NULL,
    source_relative_path TEXT NOT NULL,
    destination_root_id TEXT,
    destination_relative_path TEXT,
    source_expected_version TEXT,
    captured_relative_path TEXT,
    captured_identity_json TEXT,
    staging_relative_path TEXT,
    staging_identity_json TEXT,
    published_identity_json TEXT,
    result_json TEXT,
    failure_code TEXT,
    recovery_attempts INTEGER NOT NULL DEFAULT 0,
    lease_owner TEXT,
    lease_expires_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    committed_at TEXT,
    FOREIGN KEY(project_id) REFERENCES projects(project_id)
);

CREATE INDEX IF NOT EXISTS idx_fs_transactions_recovery
ON filesystem_transactions(state, lease_expires_at, updated_at);

CREATE INDEX IF NOT EXISTS idx_fs_transactions_project
ON filesystem_transactions(project_id, project_generation, updated_at);

CREATE TABLE IF NOT EXISTS filesystem_quarantine (
    quarantine_id TEXT PRIMARY KEY,
    transaction_id TEXT NOT NULL UNIQUE,
    project_id TEXT NOT NULL,
    project_generation INTEGER NOT NULL,
    root_id TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    identity_json TEXT NOT NULL,
    reason TEXT NOT NULL,
    estimated_bytes INTEGER,
    created_at TEXT NOT NULL,
    last_recovery_at TEXT,
    recovery_attempts INTEGER NOT NULL DEFAULT 0,
    resolved_at TEXT,
    resolution_json TEXT,
    FOREIGN KEY(transaction_id) REFERENCES filesystem_transactions(transaction_id),
    FOREIGN KEY(project_id) REFERENCES projects(project_id)
);

CREATE INDEX IF NOT EXISTS idx_fs_quarantine_project
ON filesystem_quarantine(project_id, resolved_at, created_at);

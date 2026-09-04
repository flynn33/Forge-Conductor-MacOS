# Migration, Rollout, and Compatibility

## Compatibility principle

The security refactor changes internal authority and mutation algorithms. It does not
remove public filesystem tools or alter unrelated capabilities.

Preserve:

```text
fs_read
fs_write
fs_edit
fs_list
fs_glob
fs_mkdir
fs_delete
fs_move
```

Preserve existing accepted argument aliases and established response fields. Additive
fields may include:

```text
transaction_id
linearization
version_token
conflict
restored
quarantined
quarantine_receipt
committed
durability_confirmed
capability_class
```

## Staged rollout

### Stage 1 — characterize and dual-run reads

- add typed root capability acquisition;
- keep production mutations unchanged;
- run descriptor read/list/glob in shadow mode against fixtures;
- compare results and resource usage;
- do not log sensitive contents.

### Stage 2 — secure creates and same-volume moves

- enable descriptor `mkdir` and create-only write;
- enable current-entry same-volume move;
- retain old path only behind a test fixture, never a production fallback.

### Stage 3 — atomic-capture delete and edit/replace

- enable transaction ledger and recovery worker first;
- then enable delete;
- then enable edit/replace by qualified volume class;
- force crash injection in pre-release builds.

### Stage 4 — cross-volume and package ingestion

- replace `/bin/cp` with descriptor copier;
- route package ingestion through immutable managed capture;
- qualify removable and network volumes separately.

### Stage 5 — remove obsolete path mutation

- remove Foundation enumerator/find/cp/realpath authority from production paths;
- run source guard;
- preserve characterization tests proving why old code is forbidden.

## Data migration

- add root identity and generation columns/tables without rewriting project memory;
- create transaction tables in the existing control plane;
- migrate root records lazily with explicit receipts;
- retain security-scoped bookmark storage policy and Keychain/permissions behavior;
- never mark a different object at the same path as the same root;
- project reset rotates generation and reconciles transactions before clearing data.

## Rollback

A binary rollback is allowed only before the new schema/transaction feature is activated
or when the repository's migration policy proves backward compatibility. Once an entry
is captured by the new transaction system, an older binary must not perform cleanup.
Leave a version marker that makes it fail closed and instructs the current manager to
recover.

## Feature-preservation gates

- shell defaults enabled and legacy `/bin/bash -lc` behavior retained;
- all runtime adapters remain available according to their existing configuration;
- memory MCP and project isolation pass;
- managed continuity and real autonomous rollover pass;
- telemetry and UI performance fixes remain;
- queue ingestion, artifacts, diagnostics, manager attachment, and settings pass;
- no public tool disappears from MCP `tools/list`;
- no response-field removal without a versioned compatibility plan.

# MCP Tool and Resource Contracts

## Compatibility

The implementation must first inventory all existing MCP capabilities. Existing names and accepted request forms remain valid. The contracts below are additive unless an existing equivalent is extended compatibly.

All tool calls:

- require or resolve a project identity;
- support cancellation and a deadline;
- enforce input/output bounds;
- return typed protocol errors;
- include server/schema capability versions;
- avoid returning private full bodies unless explicitly requested.

## Project memory tools

### `project_memory.initialize`

Creates or opens the memory scope for a project.

Input:

- project path or existing project ID;
- optional display name;
- optional repository identity;
- idempotency key.

Output:

- stable project ID;
- schema version;
- capabilities;
- effective limits;
- migration status.

### `project_memory.remember`

Stores one compact record.

Input:

- project ID;
- kind;
- title;
- summary;
- optional body;
- tags;
- importance/confidence;
- source reference;
- optional related IDs;
- idempotency key.

Output:

- record ID;
- record version;
- disposition: inserted, deduplicated, or merged;
- content hash.

### `project_memory.remember_batch`

Transactional bounded batch. Rejects requests above the advertised count/byte limits. Returns per-item disposition.

### `project_memory.search`

Input:

- project ID;
- query;
- optional kinds/tags/session/time filters;
- limit;
- cursor;
- include body flag;
- maximum response bytes.

Output:

- ranked result summaries;
- stable IDs and versions;
- next cursor;
- truncation and ranking metadata.

### `project_memory.get`

Fetches records by ID with optional body and link expansion, both bounded.

### `project_memory.update`

Optimistic concurrency through expected record version. Updates mutable fields and index transactionally.

### `project_memory.forget`

Creates a tombstone or performs policy-authorized deletion. Returns disposition. Durable decisions/handoffs are not silently destroyed by maintenance.

### `project_memory.list_recent`

Paged recent records with kind/session filters.

### `project_memory.link`

Creates a typed relation between records, idempotently.

### `project_memory.export`

Creates a checksummed bounded export artifact and returns a reference; it does not return an unbounded database in one MCP payload.

### `project_memory.import`

Validates, previews, and transactionally imports a compatible export. Project identity conflicts require an explicit merge policy supplied by the caller or deterministic default policy.

### `project_memory.status`

Returns database size, WAL size, record counts by kind, cache use, maintenance state, limits, and health without exposing contents.

## Continuity tools

### `continuity.checkpoint`

Persists current compact progress and references. Idempotent by operation ID.

### `continuity.prepare_handoff`

Builds and persists a handoff from current project/session state. Returns handoff ID and readiness.

### `continuity.get_pending_handoff`

Returns the latest unacknowledged handoff for a project or successor session.

### `continuity.acknowledge_handoff`

Compare-and-set acknowledgment by successor session and handoff ID.

### `continuity.resume`

Loads acknowledged handoff references and marks work resumed idempotently.

### `continuity.status`

Returns current state-machine state, budget source/confidence, checkpoint/handoff IDs, adapter capabilities, retry status, and health.

### `continuity.request_rollover`

Requests the continuity coordinator to run the durable rollover state machine. The result distinguishes:

- completed;
- in progress;
- memory-only handoff ready;
- autonomous host capability unavailable;
- retry scheduled;
- failed with typed error.

It must never report an external session as created without adapter confirmation.

## Resources

Recommended URI templates:

```text
forge://projects/{projectID}/memory/recent
forge://projects/{projectID}/memory/{recordID}
forge://projects/{projectID}/continuity/status
forge://projects/{projectID}/handoffs/latest
forge://projects/{projectID}/sessions/current
forge://projects/{projectID}/health
```

Resources return compact, bounded representations and advertise pagination/reference links.

## Prompts

If the existing server supports MCP prompts, add versioned prompts for:

- project resume;
- handoff consumption;
- memory distillation;
- recovery diagnosis.

Prompts are not the only continuity mechanism; the coordinator persists state independently.

## Error model

Use stable machine-readable codes, including:

- invalid_request;
- unsupported_version;
- project_not_found;
- project_scope_mismatch;
- record_not_found;
- conflict;
- payload_too_large;
- deadline_exceeded;
- cancelled;
- database_busy;
- storage_full;
- migration_failed;
- integrity_failure;
- host_capability_unavailable;
- rollover_in_progress;
- adapter_failure;
- redaction_rejected.

Existing error forms receive compatibility adapters.

## Conformance

Create golden initialize, list-tools, tool-schema, success, cancellation, error, and pagination transcripts. Run them against the executable transport, not only service methods.

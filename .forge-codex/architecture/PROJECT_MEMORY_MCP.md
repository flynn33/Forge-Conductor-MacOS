# Project-Scoped Memory MCP

## Product requirement

Forge Conductor must supply autonomous, durable, project-scoped memory through MCP. Memory survives model-session rollover, remains isolated among projects, supports deterministic search and maintenance, and stays resource-bounded on machines with different memory capacities.

## Architectural components

```text
ForgeMemoryMCPServer (Swift executable or existing MCP host extension)
        │
        ▼
ProjectMemoryService actor
        ├── ProjectIdentityResolver
        ├── MemoryPolicy
        ├── MemoryRepository actor
        │     └── SQLite3 database
        ├── SearchIndex
        ├── RedactionService
        └── MaintenanceService
```

Extend the existing MCP server and protocol types when present. Do not replace or rename existing tools.

## Project identity

A project receives a durable UUID stored in a Forge metadata file or registry. Identity is not based solely on an absolute path because projects move.

Resolve using:

1. existing Forge project identifier;
2. repository metadata identifier;
3. an atomic sidecar/registry mapping;
4. canonical path plus volume identity only for initial discovery.

The identity contract includes aliases for prior paths and repository worktrees. A project database cannot be opened under another project identity without an explicit import.

## Storage

Use Apple-shipped SQLite3 through a narrow Swift object-oriented wrapper. Do not add a production interpreted service or remote database requirement.

Recommended layout:

```text
Application Support/Forge Conductor/Projects/<project-uuid>/
    project.json
    memory.sqlite3
    memory.sqlite3-wal
    attachments/
    exports/
```

Use WAL mode, foreign keys, a busy timeout, prepared statements, short transactions, integrity checks, and versioned migrations.

## Core schema

### `memory_records`

- `id` UUID primary key
- `project_id`
- `kind`
- `title`
- `summary`
- `body`
- `importance`
- `confidence`
- `source_kind`
- `source_reference`
- `session_id`
- `created_at`
- `updated_at`
- `last_accessed_at`
- `expires_at`
- `content_hash`
- `is_tombstone`
- `schema_version`

### Related tables

- `memory_tags`
- `memory_record_tags`
- `memory_links`
- `sessions`
- `handoffs`
- `artifacts`
- `project_aliases`
- `maintenance_state`
- `event_journal`
- an FTS5 table/triggers when supported

If FTS5 capability is unavailable, fall back to indexed normalized terms and bounded SQL matching. Capability detection and both paths require tests.

## Memory kinds

At minimum:

- fact;
- constraint;
- decision;
- task;
- issue;
- code_reference;
- artifact_reference;
- test_result;
- user_preference scoped to the project;
- session_summary;
- handoff;
- recovery_checkpoint.

Kinds are versioned strings so additive extensions do not require an enum-breaking migration.

## Write behavior

- validate project scope;
- redact secrets;
- normalize text;
- enforce payload limits;
- deduplicate by project/kind/content hash;
- merge only under an explicit policy;
- write transactionally;
- update FTS/index state in the same transaction;
- emit a compact audit event;
- return stable ID/version.

Automatic capture writes compact decisions, constraints, test evidence, phase state, and handoffs at lifecycle boundaries. It does not store every raw message.

## Search behavior

Search combines:

- exact identifiers;
- tags/kind filters;
- lexical rank;
- recency;
- importance;
- project/session scope;
- optional linked-record expansion.

Results are paged and bounded by count and encoded bytes. Return summaries and references by default; fetch full body explicitly. Never load an entire project corpus into memory for one query.

Embedding search may be added only as an optional provider capability with a bounded local index, migration/versioning, privacy policy, and lexical fallback. It is not required for correctness.

## Cache policy

- statement cache: bounded by count;
- decoded-record cache: bounded by cost;
- search result cache: short TTL and project invalidation;
- no full-database in-memory mirror;
- purge on memory pressure and project close.

Use `plans/resource-budgets.json` and measure actual costs.

## MCP transport and compatibility

Support the repository's existing transport. Stdio JSON-RPC is mandatory when already supported. Network transports must authenticate, bind safely, and obey payload/time limits.

Initialization returns server version, schema version, capabilities, limits, and supported tools. Preserve existing server identity and tools through additive capability negotiation.

## Reliability

- idempotency keys for writes;
- cancellation-aware queries;
- deadline on every request;
- transactional migrations with backup;
- startup integrity check and recovery path;
- database lock tests;
- disk-full tests;
- interrupted write and interrupted migration tests;
- export/import with checksums;
- project deletion/archive semantics.

## Autonomous maintenance

A low-priority maintenance actor:

- compacts duplicate superseded records;
- expires eligible data;
- checkpoints WAL when safe;
- updates statistics;
- enforces disk budgets;
- generates bounded summaries;
- pauses under thermal, power, or active-interaction pressure.

Maintenance is cancellable, resumable, and never blocks MCP requests or the main actor.

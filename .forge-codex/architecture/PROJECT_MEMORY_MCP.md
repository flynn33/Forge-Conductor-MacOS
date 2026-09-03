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

### Registration authority and compatibility

Manager HTTP registration and MCP `project_memory.initialize` share one
manager-owned protocol. They discover the selected target once, canonicalize it,
record its directory device/inode identity, and infer its Git repository identity
without changing the project-memory registry. A supplied
`repository_identity` remains accepted in the JSON schema only as an assertion;
it must exactly match the independently inferred identity.

Before either registry mutation, the coordinator looks up control-plane owners by
both canonical root and inferred repository identity. An identity already
controlled at another root returns `project_relink_required`; callers cannot use
registration as a relink shortcut. An unregistered target receives a
deterministic candidate project identifier. That one captured preparation and
identifier are used for the retained-authority fence, the control-plane insert,
and the identity publication. The coordinator revalidates the captured target
inside the fence. For a controlled project the preparation also captures and
fences its exact live generation; for a demonstrably new project it asserts that
the control row remains absent and uses generation one only for the recovery
authority check. The control-plane transaction independently compares that
captured absence/generation before accepting the row. A new or not-yet-published
registration is inserted as `maintenance`, with a durable
`project_transition_authority` row bound to transition kind, exact operation
identifier, prior/new generation, canonical-root and repository-identity
digests, and directory device/inode. Binding and invocation paths reject that state. The coordinator
then publishes the project descriptor and alias and activates only the exact
matching staged operation in the same transaction that marks its authority row
published. Audit events remain diagnostic and cannot authorize a transition. A crash after control-plane acceptance replays the same
deterministic identifier and operation authority. An already active,
already-published registration remains active and does not enter this
transition.

The old public `ProjectMemoryService.initialize`, `ProjectContextService`
descriptor/canonical-root mutation signatures, and raw
`ProjectControlPlaneRepository` registration/relink methods remain
source-visible in 0.9.0 as deprecated compatibility facades, but now fail closed
with `project_transition_coordinator_required` and perform no mutation. Only
clearly named internal unchecked primitives remain for the already-authorized
coordinator and isolated repository tests. Direct library callers must migrate
to `ManagerNode`, the authenticated manager HTTP API, or the existing
`ToolRouter` MCP entrypoint.
Calling `ProjectMemoryToolPack` directly for initialization returns
`project_registration_coordinator_required`; `ToolRouter` retains the existing
tool name and wire schema while supplying the required coordinator.
This is an intentional security compatibility exception: preserving the former
runtime behavior would preserve the identity-forgery and cross-store bypass.

### Relink authority and recovery

Project relink spans the project-memory registry and the SQLite control plane, so
it is a recoverable two-store transition rather than one atomic transaction:

1. project memory verifies the selected Git identity and writes one bounded,
   non-authoritative intent for the project;
2. the control plane compares the exact project generation, root, repository
   fingerprint, lifecycle, bindings, runs, and captured directory device/inode,
   then atomically advances the generation and canonical root into
   `maintenance`;
3. only after that compare-and-set commits may project memory publish the path
   alias;
4. the control plane revalidates the same target identity and activates only
   the exact staged operation after alias publication. An exact replay completes
   or confirms these commits.

Transition authority is not inferred from `maintenance`, mutable alias
presence, or the append-only audit stream. One dedicated bounded
`project_transition_authority` row binds registration or relink to the exact
operation identifier, prior/new generation, target-root and repository-identity
digests, directory device/inode, and staged/published state. The row and the
control tuple change in the same SQLite transaction. Its canonical authority
hash is revalidated on every read. A malformed, stale, cross-kind, missing, or
mismatched row fails closed with `project_transition_conflict`; deleting or
pruning diagnostic audit events cannot change authority. Registration cannot
activate a relink-pending row, and relink cannot consume registration
maintenance.

Staged authority is never pruned. Published history is capped at the newest 16
rows per project, so one project retains at most 17 rows while a transition is
staged. Replaying a pruned historical operation fails closed. Existing active
schema-v2 stores add the table idempotently. Authority is never synthesized from
legacy audit text; a preexisting maintenance row without an exact authority row
remains fenced for explicit recovery. These checks detect accidental corruption,
but they are not a privilege boundary against another same-UID process that can
rewrite the owner-only SQLite store; that local trust-boundary residual remains
explicit.

A control-plane busy or root-conflict rejection removes only the matching staged
intent. It leaves the canonical root, generation, and aliases byte-for-byte
unchanged. A lost response is retried once by the native client with the same
pre-encoded request body and captured authorization header; the manager returns
a reconciled receipt only for the exact already-committed operation and
generation/root tuple. Registration and relink requests are persisted as bounded
owner-only intents before the first control-plane mutation. Manager snapshots
include a top-level `pending_project_registrations` projection, so a validated
registration intent remains discoverable even when a crash preceded creation of
its first control-plane row; the native Projects view reconstructs the exact
replay after both app and manager restart. The projection returns at most 100
intents and its lazy project-directory scan fails closed after 4,096 entries.
Relink requests are serialized across manager
instances by the existing recovery-ledger fence, and the authoritative tuple is
read again while that fence is held. A distinct process that cannot acquire the
fence within the bounded two-second deadline receives HTTP 503
`database_busy` with `retryable` and `reconciliation_required`; an exact retry
after the winner finishes converges. Identical concurrent requests converge to
one commit plus one reconciled receipt; conflicting requests permit one
compare-and-set winner and reject the loser without publishing its alias.

The raw user path is never resolved a second time during one transition. The
captured target carries its canonical root, inferred repository identity, and
directory device/inode through staging, compare-and-set, publication, and
activation. The SQLite transition validates device/inode inside its write
transaction and again after the transaction's commit observer immediately
before `COMMIT`; activation performs the same pair. A symlink or namespace
replacement observed at either boundary is rejected.

This protocol mitigates but does not eliminate the cross-store crash window. A
crash before the control-plane commit can leave at most one 32 KiB
non-authoritative intent for one project, but it cannot grant alias authority.
That intent remains visible in the bounded top-level operator projection even
when no control row exists. The next authorized request first compares it with the control plane;
only an exact uncommitted intent may be removed before another target is staged.
A crash after the control-plane commit can leave that one project at exactly one
advanced generation and the selected canonical root in `maintenance`, while
its memory alias is either absent or already published. Cross-process binding
and invocation remain rejected in both states. Exact replay after restart
validates the exact staged authority, publishes the alias once when needed,
activates and revalidates the published authority, and only then removes the
intent. A crash after activation but before cleanup therefore retains an exact
replay receipt instead of losing recovery state. Intent cleanup failure remains
visible and replay retries cleanup idempotently. The
maximum durable impact of an ordinary crash is one pending intent and temporary
unavailability of one project/generation transition, never usable authority or
an alias from a rejected compare-and-set. Missing, pruned, or ambiguous
transition authority requires repair rather than inferred activation.
The recovery projection does not authenticate owner storage. A same-UID process
can remove, replace, or coherently rewrite an intent, or inflate the project
directory past the scan bound and make the snapshot fail closed. This remains an
explicit local trust-boundary and availability residual, not transition authority.

The identity checks mitigate but do not eliminate a hostile parent-directory
namespace race, which remains an E2 release blocker. Evaluated public macOS
interfaces include path and descriptor-relative `lstat`, `openat`, `fstat`,
`fstatat`, `renameat`, `renameatx_np`, and `unlinkat`. Descriptor-relative lookup
can pin traversal context, while `renameatx_np` supplies useful atomic namespace
operations such as exclusive rename and the adversarial `RENAME_SWAP`; none
accepts an expected device, inode, vnode generation, or repository identity as
the mutation predicate. None can make the separate SQLite row and
project-memory registry one transaction. A process with authority to rename the
selected path's parent can therefore replace that directory after the final
device/inode check. The maximum possible impact is bounded to the one selected
project's one generation: after activation, its accepted canonical-root string
and one published alias can resolve to the replacement directory until the
operator restores the namespace or performs another authorized transition.
Generation fencing prevents stale-generation use and no other project identity
is published. If the swap is observed before activation, activation fails
closed and leaves one project in `maintenance` awaiting exact recovery after
the expected directory identity is restored. This is mitigation, not
elimination.

Source, Swift fixture, and simulated-client coverage do not qualify the signed
native Projects UI. Native signed UI execution remains a separate open release
gate.

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

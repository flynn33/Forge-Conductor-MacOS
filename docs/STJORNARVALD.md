# Rune Forge Development Policy and Stjornarvald

This document is the current product record for the native **Development
Policy** feature, its **Rune Forge** operator surface, and the manager-owned
**Stjornarvald** policy engine. Typed contracts, durable policy history, and the
all-format source catalog are implemented; unfinished work remains open in the
[roadmap](../ROADMAP.md).

## Governing source

Raven Forge Development is governance and policy authority for this feature:

| Field | Bound value |
| --- | --- |
| Repository | `https://github.com/flynn33/raven-forge-development` |
| Version | `0.6.2` |
| Revision | `ed0028a46bac9c5b92876a6ad6589ca421fd9499` |
| Product baseline reconciled | `8c529924fb770b695b923f11eb5c29b26012db65` |
| Product repository | `https://github.com/flynn33/Forge-Conductor-MacOS` |

The policy repository is an external governance authority, not an application
dependency. No Raven repository, utility, example, test, or Python runtime is
copied, linked, vendored, or shipped. The product implements its own native
Swift realization and retains exact source revision, path, and locator
provenance for each built-in rule.

The Raven repository does not publish a system-realization profile for Raven
Forge Development itself. Consequently no profile-validator pass is claimed.
The issued implementation package instead supplies the pinned policy binding,
source roles, dependency prohibition, product-owned realization map,
non-interference invariants, and acceptance matrix used for this work.

## Settled behavior

- Selecting any file or folder creates an active durable policy-source identity
  before asynchronous interpretation. File type, size, encryption, or parser
  availability is never an acceptance predicate.
- Raven Forge Development remains the built-in governing policy. User-selected
  sources add project context without silently disabling it.
- A detected violation is source-linked, appended to dedicated immutable
  history, shown to the operator, and delivered as bounded additive context to
  the coding agent at a safe future boundary.
- Stjornarvald never authorizes or denies tools, changes canonical tool results,
  controls run admission or completion, stops a queue, cancels work, changes a
  project generation, or edits project source.
- Indexing, evaluation, notice delivery, mirroring, and export are bounded,
  recoverable side channels owned by the Manager. Their faults leave ordinary
  Forge startup and development operational.

## Current product-owned realization map

The package baseline predates newer instruction-artifact, completion-plan,
provider-readiness, and continuity work. The current owners below supersede any
stale patch location while preserving those newer contracts.

| Responsibility | Current owner / intended product-local change |
| --- | --- |
| Typed policy, observation, violation, and event contracts | `Domain/StjornarvaldContracts.swift` (implemented in RF-SJ-01) |
| Dedicated policy database, JSONL mirror, outbox, source store, exports, and staging | `AppPaths`, `Infrastructure/StjornarvaldPolicyLogStore.swift`, and `Infrastructure/StjornarvaldPolicySourceCatalog.swift` (durable log and source catalog implemented in RF-SJ-01/RF-SJ-02; later stores remain open) |
| Native source interpretation | `Infrastructure/StjornarvaldNativePolicyExtractor.swift` (bounded native extraction and metadata-only fallback implemented in RF-SJ-02) |
| Process composition | `ForgeApp`; process clients may be composed here, but the manager remains the only evaluator owner |
| Manager lifecycle and single evaluator | `ManagerNode` plus a dedicated coordinator |
| Authenticated bounded operations | `ManagerRoutes`, typed operator wire models, and `OperatorManagerClient` |
| Managed coding-agent context and observations | `ManagedProjectRunStepExecutor` and post-commit `ToolInvocationBroker` seams |
| Ordinary MCP observations and notices | Post-result `ToolRouter` observation plus `MCPToolResponse` presentation decoration; canonical `ToolResult` stays unchanged |
| Operator navigation and workflow | `AppModel.AppTab`, `ContentView`, `AppSidebarView`, a dedicated view model/view, and Guided Mode |
| Build graph | Existing `ForgeConductorCore`, `ForgeConductorApp`, `ForgeConductorTests`, and app-test targets in `ForgeConductor.xcodeproj` and `Package.swift` |

## Preserved product surfaces

All 13 existing tabs, Guided Mode contexts, project generations, instruction
artifacts and queues, manager-owned autonomy, provider readiness, completion
plans, continuity, runtime jobs, telemetry, project memory, authorization,
replay, and secure-filesystem behavior remain available. Rune Forge is a new
fourteenth tab; it does not repurpose an existing destination.

## Reconciliation evidence

The September 20, 2026 reconciliation used the clean synchronized `main` source
at `8c529924fb770b695b923f11eb5c29b26012db65`, Xcode 27.0, and Apple Swift 6.4.

- `python3 scripts/validate_package.py --deep` passed all package checks: 54
  files, 11 acyclic work packages, 40 traced acceptance rows, schemas, SQLite
  append-only behavior, Swift contract type checking, and manifest integrity.
- `swift build --product forge-conductor` passed.
- `swift build --product forge-conductor-app` passed.
- `swift test --filter GuidedModeAppTests` executed 3 tests with 0 failures.
- `xcodebuild -scheme ForgeConductor -configuration Debug -destination
  'platform=macOS' build` completed with `** BUILD SUCCEEDED **` using the
  ordinary Apple Development signing identity.

That RF-SJ-00 reconciliation changed documentation only. RF-SJ-01 subsequently
added the native contracts and durable policy-log foundation described below.

## RF-SJ-01 durable policy-history evidence

The implementation now provides:

- deterministic violation fingerprints and UUID identities scoped by policy
  revision, rule, project/generation, and subject;
- stable caller event IDs, idempotent replay, immutable SQLite event rows, and
  separate mutable projections;
- correction, dispute, repeat, and reopen transitions that append history;
- a SHA-256-linked canonical JSONL mirror rebuilt atomically from SQLite after
  a partial append, missing mirror, or restart;
- owner-only directories and database, sidecar, mirror, and outbox files;
- direct-tool and subprocess/runtime-sandbox exclusion for the entire
  manager-owned policy namespace, including ancestor move/delete attempts;
- pre-write schema validation, bounded event queries and candidates, a
  10,000-item disk outbox, and a 32-item emergency-memory ceiling; and
- a non-throwing service facade that reports a persisted or deferred result and
  cannot authorize tools, admit runs, control queues/completion, or mutate
  project source.

`swift test --filter StjornarvaldPolicyLogTests` and the canonical workspace
`ForgeConductor` scheme each executed the eight focused store, migration,
reopen, permission/protection, idempotency, outbox, and all-storage-fault cases
with zero failures. The Xcode run compiled the explicitly registered production
and test members and Apple Development-signed the test bundle. An earlier
command using the nonexistent `ForgeConductorTests` scheme exited 65 before
testing and is retained as a non-pass.

This phase does not claim source cataloging or interpretation, live observation
coordination, violation detection, coding-agent notice delivery, manager routes,
Rune Forge UI, export, integrated stress/fault proof, or release acceptance.

## RF-SJ-02 all-format source-catalog evidence

The native catalog now provides:

- immediate, durable acceptance of every selected filesystem entry before any
  parsing, hashing, or traversal begins;
- restart-safe revisions, artifact records, extracted segments, and bounded
  SQLite work queues with resumable 256 KiB regular-file hashing;
- bounded native text, JSON, property-list, rich-text, PDF, image, ZIP inventory,
  Mach-O, binary-string, and metadata-only strategies without executing input;
- directory discovery that resumes from durable queued identities, does not
  follow links, does not open special streams, and does not recursively ingest
  manager-owned state or Git internals;
- source-change detection that preserves the prior revision and schedules an
  explicit successor rather than overwriting provenance;
- native Git origin, branch, and commit capture with URL credentials removed;
  worktree cleanliness remains explicitly unassessed; and
- active partial, deferred, unavailable, and metadata-only states rather than
  type-, size-, encryption-, or parser-based rejection.

`swift test --filter StjornarvaldPolicySourceCatalogTests` executed eight cases
covering all-format acceptance, a sparse 2 GiB file, bounded/restart-safe
hashing, a 150-file tree, a symbolic-link cycle, source replacement, durable
mutation replay, database open-order compatibility, native extraction, and Git
metadata redaction/non-traversal with zero failures. The initial implementation
also produced three retained non-passes: a FIFO-triggered bookmark stall, a
signed-device conversion trap, and a directory-resume stall caused by treating
a `telldir` cookie as portable across reopened streams. The delivered design
uses exact-path metadata for special entries, bit-pattern-safe device identity,
and the durable SQLite discovery queue instead. The canonical workspace
`ForgeConductor` scheme compiled the explicitly registered catalog, extractor,
and test members, Apple Development-signed the products, executed the same
eight cases, and reported `** TEST SUCCEEDED **`.

This phase does not yet claim automatic manager scheduling, Raven rule
projection, live observation/evaluation, coding-agent notices, manager routes,
Rune Forge UI, export, integrated stress/fault proof, or release acceptance.

## Delivery sequence

Implementation proceeds in small tested vertical slices: typed contracts and
durable policy history; universal source catalog; pinned Raven rule adapter;
observation and violation lifecycle; managed and MCP notices; manager API and
recovery; Rune Forge UI and Guided Mode; four export formats; fault, bounds,
privacy, and performance proof; then integrated delivery acceptance.

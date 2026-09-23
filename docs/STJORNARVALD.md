# Rune Forge Development Policy and Stjornarvald

This document is the current product record for the native **Development
Policy** feature, its **Rune Forge** operator surface, and the manager-owned
**Stjornarvald** policy engine. Typed contracts, durable policy history, the
all-format source catalog, the pinned source-linked Raven rule index, the
restart-safe evaluation core, and bounded managed/MCP notice delivery are
implemented. The Manager now composes one restart-safe evaluator with bounded
typed operations, health, durable notice reservations, and process observation
outboxes; unfinished work remains
open in the [roadmap](../ROADMAP.md).

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
| Pinned Raven policy projection | `Application/RavenForgeDevelopmentPolicyAdapter.swift` and `Infrastructure/StjornarvaldPolicyRuleRepository.swift` (implemented in RF-SJ-03) |
| Durable observation intake and single evaluator | `Infrastructure/StjornarvaldObservationRepository.swift`, `Application/StjornarvaldPolicyEvaluator.swift`, and `Application/StjornarvaldProductObservations.swift` (implemented in RF-SJ-04/RF-SJ-09) |
| Coding-agent notice delivery | `Application/StjornarvaldPolicyNotices.swift`, `Infrastructure/StjornarvaldPolicyNoticeRepository.swift`, `ManagedProjectRunStepExecutor`, and `MCPServer`/`MCPToolResponse` (implemented in RF-SJ-05) |
| Process composition | `ForgeApp`, `Application/StjornarvaldObservationClient.swift`, and `Application/StjornarvaldProductObservations.swift` (bounded owner-only FIFO outbox implemented in RF-SJ-06; bounded product hooks implemented in RF-SJ-09) |
| Manager lifecycle and single evaluator | `ManagerNode` and `Application/StjornarvaldManagerCoordinator.swift` (implemented in RF-SJ-06) |
| Authenticated bounded operations | `ManagerRoutes`, typed operator wire models, and `ManagerDashboardClient` (implemented in RF-SJ-06; four-format export implemented in RF-SJ-08) |
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

## RF-SJ-03 pinned Raven rule evidence

The native adapter and durable rule index now provide:

- one exact built-in governing identity for Raven Forge Development 0.6.2 at
  revision `ed0028a46bac9c5b92876a6ad6589ca421fd9499`;
- 15 product-local rules across 13 initial policy areas, each retaining the
  stable source identity, exact revision, policy-relative path, Markdown
  heading locator, native interpretation details, and the non-interference
  boundary;
- deterministic precedence across current owner direction, current
  project-specific decisions, source specificity, normative status, revision,
  purpose alignment, and preservation of working behavior, with equal-rank
  material ties retained as bounded alternatives plus assumptions and
  confidence rather than silently resolved;
- an initial native-stack detector that reports aligned, violation, ambiguous,
  and corrected assessments without controlling tools or development flow;
- immutable, digest-checked rule projections and append-only projection and
  optional-utility observations in the shared schema-versioned Stjornarvald
  database; and
- fail-forward operation when no optional parity utility is present or when
  one fails. The pinned native rules remain active and the utility condition is
  recorded separately.

`swift test --filter StjornarvaldRavenPolicyTests` and the canonical workspace
`ForgeConductor` scheme each executed eight cases with zero failures. The tests
cover exact source identity and locator parity, durable projection and
append-only history, successful and failing utility observations,
policy-log/source-catalog database coexistence in either open order, every
published precedence level and ambiguity retention, all four initial detector
states, and decoding of pre-RF-SJ-03 rule payloads. The Xcode
run compiled the explicitly registered adapter, repository, and test members,
Apple Development-signed the products, and reported `** TEST SUCCEEDED **`.

This phase does not claim automatic manager scheduling, general live
observation/evaluation, coding-agent notices, manager routes, Rune Forge UI,
export, integrated stress/fault proof, or release acceptance.

## RF-SJ-04 observation and violation-lifecycle evidence

The manager-owned core now provides:

- immutable, size- and count-bounded development observations with exact
  project/run/session/client scope, strict payload digest validation,
  idempotency-key and observation-ID conflict checks, and restart-safe ordering;
- an owner-only observation outbox plus bounded emergency memory when the
  shared policy database is unavailable, with idempotent reconciliation after
  recovery;
- one expiring evaluator lease bound to evaluator, process, and boot identity,
  plus a durable cursor that advances exactly one observation only after all
  idempotent violation writes and the append-only evaluation receipt commit;
- a bounded detector registry that isolates and records individual detector
  faults, rejects cross-detector identities, and deduplicates findings without
  returning a development control decision;
- the first observation adapter for the source-linked native-stack rule,
  retaining ambiguity assumptions, alternatives, confidence, and exact pinned
  rule provenance; and
- condition-specific stable fingerprints and deterministic event identities so
  moved evidence groups as a repeat, aligned evidence appends correction,
  reappearance appends reopen, and replay after a log-before-cursor crash does
  not duplicate an event.

`swift test --filter StjornarvaldObservationEvaluatorTests` and the canonical
workspace `ForgeConductor` scheme each executed eleven cases with zero failures.
The fixtures cover submission conflicts and bounds, restart durability, full
process/boot lease contention and expiry, cursor recovery, missing-rule
fail-forward behavior, detector fault isolation, exactly-once evaluation,
repeat/correction/reopen, distinct condition identities, log-before-cursor
replay, outbox recovery, malformed/conflicting submission rejection without
outboxing, owner-only permissions, append-only observation/evaluation history,
and coexistence with every earlier Stjornarvald store.
The RF-SJ-01 policy-log suite passed 8/8 and the RF-SJ-03 Raven-rule suite
passed 8/8 after the shared contract extension. The Xcode run compiled the
explicitly registered production and test members, Apple Development-signed
the products, and reported `** TEST SUCCEEDED **`.

The first focused attempt did not execute tests because an async fixture call
was placed inside a synchronous XCTest autoclosure; awaiting before unwrapping
repaired the fixture. This phase does not yet claim automatic manager lifecycle
scheduling, observation hooks in existing product operations, coding-agent
notice delivery, manager routes, Rune Forge UI, export, integrated stress and
performance proof, or release acceptance.

## RF-SJ-05 coding-agent notice-delivery evidence

The additive reporting path now provides:

- durable, bounded notices keyed to the strongest available managed-run, MCP
  client, or project identity, with stable event deduplication, a repeat quiet
  interval, correction supersession, secret redaction, and restart-safe state;
- deterministic managed delivery snapshots keyed to the provider side effect,
  so retries receive the same context and provider failure records deferral;
- bounded managed context appended only at a safe non-tool-output provider
  boundary, without changing budgets, completion checks, tools, or run outcome;
- an asynchronous process-local MCP notice cache and separate second text
  content item that preserves canonical structured content, first content,
  error status, payload, replay, audit, and authorization behavior; and
- delivery receipts recorded only after provider acceptance or successful MCP
  transport write. Failed writes discard transient presentation state and leave
  the durable notice eligible for a later boundary.

`swift test --filter StjornarvaldPolicyNoticeTests` executed six cases with zero
failures. The canonical workspace `ForgeConductor` scheme executed the same six
cases with zero failures and no skips. Focused regressions passed 11/11 evaluator,
8/8 policy-log, 9/9 managed-step, 20/20 MCP protocol, and 8/8 Raven-rule cases.
The first implementation attempts retained useful non-passes: malformed Swift
test syntax, a NUL-delimited SQLite binding that truncated target identity, and
invalid fixture transitions. The delivered design hashes composite identities
before SQLite binding and uses valid lifecycle fixtures. Xcode also reported a
non-failing priority-inversion runtime warning in the existing
`ProjectContextService` path; it is not treated as a clean performance proof.

This phase does not yet claim continuous manager evaluator scheduling, complete
product observation hooks, manager routes, Rune Forge UI, export, integrated
fault/performance proof, or release acceptance. Presentation proves transport,
not that a model understood or acted on a notice.

## RF-SJ-06 manager lifecycle and typed API evidence

The Manager now owns the Stjornarvald composition boundary:

- one cancellable coordinator task installs the pinned baseline, drains bounded
  source work, acquires the durable evaluator lease, and follows Manager start,
  stop, restart, halt, and deallocation without retaining its owner;
- initialization and loop faults publish bounded typed degraded health and
  retry with capped backoff without failing ordinary Manager bootstrap;
- bounded source add, refresh, and removal; observation submission; scan
  scheduling; snapshot and violation paging; notice reservation/presentation;
  and export-request routes have matching typed client operations;
- mutations require the existing Manager control credential, while bounded
  snapshot, violation, and pending-notice reads remain read-only operations;
- pending notices require a stable delivery identifier and persist the
  reservation before return, making retries stable across Manager restart;
- presentation is atomic and rejects unknown or duplicate delivery identifiers;
  and
- process clients retain up to 10,000 observations in an owner-only FIFO
  outbox and resume sequential submission after Manager outage.

The snapshot read contract accepts `limit` values from 1 through 100. Selecting
`order=newest` returns the newest bounded events and forbids a cursor; supplying
both is rejected. `project_id` and `project_generation` are accepted only as a
pair and only with newest-first ordering; matching is exact across both fields.
The default chronological form preserves its existing cursor behavior for
forward paging. Snapshot event payloads also obey a 1 MiB aggregate serialized
budget, so valid per-event bounds cannot multiply into an oversized five-second
poll.

The schema-version-1 event store additively owns nullable `project_id` and
`project_generation` projection columns. On open, it backfills only scoped rows
whose canonical `scope_json` lacks or disagrees with that projection, restores
the append-only triggers in the same transaction, and uses
`stj_violation_events_project_sequence` for exact newest-first lookups. This
repairs events written by a compatible older version-1 writer without rewriting
legitimately unscoped history on every launch.

`swift test --filter StjornarvaldManagerCoordinatorTests` and the canonical
workspace `ForgeConductor` scheme each executed nine cases with zero failures.
They cover lifecycle restart, evaluator exclusion, degraded bootstrap, owner
release, bounded/idempotent source and snapshot operations, observation/notice
flow, authorization, HTTP body bounds, typed client routes, atomic notice
presentation, and outage-persistent client draining. The notice suite passed
7/7 after adding durable-reservation coverage, and the broader Manager suite
passed 122 tests with two explicit environment skips and zero failures. The
first app-test invocation selected zero tests and is retained as a non-pass;
the corrected Core scheme selected and passed all nine. Xcode reported the
existing non-failing `ProjectContextService.close` priority-inversion warning,
so this phase makes no clean performance claim.

RF-SJ-08 subsequently replaced the provisional unavailable receipt with the
bounded four-format exporter described below, and RF-SJ-09 completed bounded
product hooks plus focused fault, privacy, restart, shutdown, and performance
qualification. Final release acceptance remains open.

## RF-SJ-07 Rune Forge UI and Guided Mode evidence

The native app now exposes a fourteenth primary tab named **Rune Forge**:

- one unrestricted `NSOpenPanel` accepts a single file or folder without a
  content-type allowlist, and a test-only selection hook is enabled only by the
  explicit UI-test launch argument;
- a selected source is inserted into bounded presentation state immediately,
  before the authenticated Manager request completes, and remains visible as
  confirmation-pending if the request fails;
- the sidebar presents at most 100 sources and 100 current violations, while
  the detail column exposes source identity and interpretation, violation
  evidence and suggested correction, notice-delivery state, assumptions,
  alternatives, and the bounded occurrence history supplied by the Manager;
- one cancellable five-second polling owner retains the last confirmed data
  during outage, avoids overlapping refreshes, and stops with the view;
- source refresh, source removal, scan scheduling, and the export request use
  the typed RF-SJ-06 client; and
- the bundled Guided Mode catalog explains the workflow, state vocabulary,
  degraded behavior, and non-interference contract without requiring a live
  Manager or provider.

`RuneForgeAppTests` passed five focused cases through SwiftPM and, together
with `GuidedModeAppTests`, eight app-hosted cases through the canonical Xcode
graph. Native UI automation accepted an opaque source immediately while the
Manager was unavailable, routed the complete Guided Mode catalog across all 14
tabs, presented and canceled the real native open panel, and navigated every
primary sidebar destination using stable accessibility identifiers. Earlier
navigation attempts exposed identifiers
attached above nested split views; identifiers now belong directly to the
visible title and subtitle elements, and the final route test passed. Two
initial native-panel queries used the wrong accessibility roles; the observed
`open-panel` dialog and `CancelButton` identifiers supplied the passing test.

RF-SJ-08 subsequently replaced the provisional export action with a native
four-format save workflow. Integrated fault/privacy/performance proof, product
observation-hook completion and final delivery acceptance were subsequently delivered.

## RF-SJ-08 policy-log export evidence

The Manager now owns one serialized, bounded export service rather than asking
the SwiftUI process to read policy storage. It takes a stable upper event
sequence and streams chronological matching events in pages of 256. Callers may
filter by project, project generation, run, session, client, inclusive date
range, rule, current violation state, policy source, event type, notice state,
and minimum confidence, with a default 10,000-event and absolute 100,000-event
bound. A truncated snapshot records the exact applied limit as a limitation.

All four formats retain the same export identity and evidence boundary:

- JSON is a structured snapshot with sources, current matching projections,
  events, filters, integrity, event range, and limitations;
- JSONL separates export, source, violation, and event records for incremental
  processing;
- Markdown supplies a human-readable source/revision, violation, occurrence,
  integrity, and limitation report; and
- CSV supplies explicit metadata and chronological event rows with JSON cells
  for structured evidence, assumptions, alternatives, filters, and limitations.

The service writes an owner-only manager staging file, synchronizes it, copies
through a bounded 64 KiB buffer into destination-local staging, synchronizes
again, and atomically renames the completed file over the selected destination.
Cancellation before publication or a staging/destination write failure removes
staging and leaves any prior destination intact; no export failure mutates the
append-only policy log. Completed receipts include event count,
byte count, SHA-256, destination, creation time, and request identity. A
manager-owned owner-only receipt record makes an identical request replay return
the original receipt after restart and rejects reuse with changed parameters.
The header records the last included event digest, event range, pending-outbox
state, policy source revisions, and limitations; these hashes detect accidental
truncation or reordering but are not external authorship proof.

Rune Forge presents an `NSSavePanel` from a four-item format menu and passes the
chosen absolute path through the authenticated Manager client. The menu and
each format have stable accessibility identifiers; Guided Mode describes the
portable-history workflow without implying that export controls development.

`StjornarvaldPolicyLogExporterTests` passed four focused cases through SwiftPM
and the canonical app-hosted Xcode graph. They cover every encoding, schema and
JSON/JSONL round trips, chronological sequences, the complete filter surface,
default and invalid bounds, a 1,025-event stress fixture with explicit
1,000-event truncation, digest readback, mode `0600`, cancellation, missing
destination failure, atomic replacement, log immutability, persistent replay,
and conflicting request rejection. `RuneForgeAppTests` passed six cases,
including exact save-panel format configuration. Native UI automation exposed
all four format choices, presented the real save panel, and canceled without
issuing an export. The ordinary Apple Development-signed Debug workspace build
and strict deep signature verification also passed.

The first focused compile attempt retained the removed provisional export API
in two RF-SJ-06 assertions and was a non-pass. The first exporter test run then
exposed a missing CSV `record_type` value and a fixture expectation that did not
account for corrected events using `not_required`; the corrected implementation
and test passed. The first app-hosted exporter invocation selected zero tests
because the new test was not yet a member of that app-hosted target and remains
a non-pass; explicit canonical membership produced the passing 10-test run.

RF-SJ-09 subsequently completed product observation integration and its focused
fault, bounds, privacy, restart, shutdown, and performance qualification.
RF-SJ-10 subsequently closed final implementation acceptance.

## RF-SJ-09 integrated non-interference qualification evidence

Forge now emits observations only after the canonical development boundary:

- ordinary tool calls record after the final result and audit commit, while
  managed calls record only after durable broker completion and do not repeat
  when an already-completed invocation is replayed;
- completion claims record only after the run durably enters deterministic
  validation, and Manager availability records after successful start or
  restart;
- observation content contains bounded identities, status, stable scope, and
  SHA-256 evidence references rather than arguments or result bodies;
- one process-owned emitter admits without throwing or waiting on Manager I/O,
  retains at most 256 observations, reports saturation through a drop counter,
  owns one drain worker, and becomes quiescent when the queue is empty; and
- a dedicated owner-only client outbox is separate from the Manager evaluator
  outbox, survives outage, resolves the current configured endpoint on retry,
  and drains after Manager availability returns.

Fault injection proved that an unavailable Manager leaves the canonical tool
result byte-equivalent, returns promptly, persists one redacted observation,
and delivers it exactly once after a client restart. A 2,000-observation burst
completed admission in under one second, retained no more than 256 pending
items, made drops explicit, drained to idle, and bounded both normal and
non-cooperative shutdown. Stable managed identities and encoded payload scans
proved that tool arguments and result bodies were absent. The managed provider
fixture still reached deterministic completion while recording exactly one
managed-tool observation and one completion claim.

`swift test --filter Stjornarvald` passed 58/58, the complete managed-step suite
passed 9/9, and MCP protocol/diagnostics passed 20/20. The three integration
qualification tests also passed under Thread Sanitizer and in the app-hosted
target; the canonical Core graph executed those three plus the managed
completion case, 4/4. The first app-hosted combined filter selected only the
three tests present in that target and therefore was not accepted as the
intended four-test proof. A priority-inversion warning initially identified the
new shutdown waiter; raising its task priority removed that stack on rerun.
Existing `ProjectContextService` priority-inversion warnings and an existing
managed-test SQLite teardown diagnostic remain visible, so this phase makes no
clean whole-application performance claim.

Static scans found no Stjornarvald pass/readiness or violation-state dependency
in tool authorization, completion validation, or automatic completion-plan
resolution. Owner-only policy-path tests, explicit project membership,
whitespace and attribution scans, the ordinary Apple Development-signed Debug
workspace build, and strict deep signature verification passed. RF-SJ-10 final
integrated delivery acceptance subsequently closed as described below.

## RF-SJ-10 integrated delivery acceptance

Every row in the issued 40-row acceptance matrix now has current evidence or an
explicit limitation. Thirty-nine rows are accepted. AC-032 is limited because
stable accessibility identifiers and labels, non-color textual state, native
controls, keyboard dismissal, and automated accessibility queries passed, but
a human physical VoiceOver listening session was not performed.

The terminal full-suite rerun executed 1,687 tests with 12 explicit skips and
zero failures. Its precursor run exposed two stale expectations in a
protected-path precedence test: whole-home deletion and movement correctly
returned the more specific `manager_policy_path_protected` result rather than
`manager_validation_path_protected`. The exact corrected test passed 1/1, its
class passed 94/94, and the full suite then passed. Canonical app-hosted Rune
Forge and Guided Mode tests passed 9/9. Native UI tests passed 5/5, covering all
destinations, all guide routes, immediate opaque-source acceptance during
Manager outage, the native source picker, and four-format native export.

The current authority is version `0.13.0`, build `5`. No release archive,
installer, notarized artifact, installation replacement, or shipment candidate
was created; those remain separate owner-directed release work. See the
[acceptance record](RUNE-FORGE-STJORNARVALD-ACCEPTANCE.md) and
[implementation handoff](RUNE-FORGE-STJORNARVALD-HANDOFF.md).

## Current Policy Feed presentation

After RF-SJ-10 acceptance, the current native presentation adds a verbose
**Policy Feed** to Rune Forge and includes the newest policy events in the Dashboard's
bounded, coalesced Managed Activity projection. Rune Forge consumes the global
newest bounded Manager snapshot; Dashboard requests the exact active project and
generation. Neither creates a second log or requests unbounded history.
Rows distinguish violations, repeats, evidence updates, corrections,
reopenings, and interpretation observations, with source/rule, confidence,
suggested correction, and delivery state when present. The Dashboard retains at most
100 combined app-local activity rows on its existing five-second view-owned
refresh; exact project/generation rows require an exact generation, so public
operator events lacking that generation cannot be relabeled into the active
generation. These presentation
changes do not alter the RF-SJ non-interference contract, policy evaluation,
notice delivery, or canonical development results.

Rune Forge Development Policy and Stjornarvald are implemented. Every selected
policy source is accepted; Raven Forge Development is continuously applied;
detected violations are reported to the coding agent and retained in the
exportable policy log; and fault-injection evidence shows Stjornarvald does not
interfere with development.

## Delivery sequence

Implementation proceeded in small tested vertical slices: typed contracts and
durable policy history; universal source catalog; pinned Raven rule adapter;
observation and violation lifecycle; managed and MCP notices; manager API and
recovery; Rune Forge UI and Guided Mode; four export formats; fault, bounds,
privacy, and performance proof; then integrated delivery acceptance. RF-SJ-00
through RF-SJ-10 are complete under the cited implementation evidence.

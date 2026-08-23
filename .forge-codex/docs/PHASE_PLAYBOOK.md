# Autonomous Phase Playbook

The machine-readable dependency graph is `plans/phases.json`. Codex may parallelize independent analysis and tests, but source edits with overlapping ownership must remain serialized and reviewable.

## P00 — Bootstrap and preserve state

### Objectives

- establish repository/project shape;
- preserve dirty work and current data;
- initialize the run ledger;
- record environment capabilities;
- create a safe branch/checkpoint;
- verify package integrity.

### Required actions

1. Run environment doctor and package validator.
2. Hash the source archive and installed package.
3. Record Git branch, commit, status, worktrees, submodules, and remotes.
4. Discover Xcode workspace/project, shared schemes, Package.swift products, deployment targets, and existing scripts.
5. Create external evidence directory.
6. Initialize state and event journal atomically.
7. Do not edit product source before P00 evidence exists.

### Fail-forward

If Xcode is unavailable, continue source inventory and portable checks, but mark all macOS runtime gates blocked. If the working tree is dirty, preserve and inventory it rather than resetting.

### Exit

G00 evidence is complete enough to reproduce the baseline.

## P01 — Feature and protocol baseline

### Objectives

- enumerate every current feature;
- characterize untested behavior;
- capture protocol and data fixtures;
- define release-boundary flows.

### Required actions

1. Run static inventory.
2. Launch the existing app where possible and exercise all scenes/actions.
3. Capture existing MCP initialize, capability, tool, prompt, and resource surfaces.
4. Capture settings/default keys, project formats, stores, schemas, and sample old data.
5. Add characterization tests around behavior to be refactored.
6. Assign stable feature IDs and owner modules.
7. Record all existing failures before repair.

### Fail-forward

A feature that cannot run because of an existing defect remains in the baseline as `present_broken`, with source/UI/protocol evidence. It may not be dropped.

### Exit

G01 passes and each next-phase change can name affected feature IDs.

## P02 — Baseline observability and reproducers

### Objectives

- make queue, cadence, ownership, and state transitions measurable;
- establish before measurements.

### Required actions

1. Add narrowly scoped `Logger` categories and signposts.
2. Add diagnostic counters for telemetry queue depth/coalescing, gauge draw/resource creation, cache/history sizes, process readers, memory MCP operations, and continuity transitions.
3. Create deterministic fixtures and interaction scripts.
4. Capture baseline Allocations/Leaks/Time Profiler/SwiftUI/Metal traces on macOS.
5. Capture memgraphs at expected release boundaries.
6. Add tests that reproduce deterministic source defects.

### Guardrails

Instrumentation must be bounded and redact content. Do not use `print` as app telemetry. Remove temporary high-volume logs after proof.

### Exit

G02 passes with reproducible baseline artifacts.

## P03 — Repair telemetry delivery

### Objectives

- eliminate unbounded main-actor task accumulation;
- ensure correct metric mapping and latest-value delivery.

### Required actions

1. Locate all telemetry producer-to-consumer paths identified by the audit.
2. Replace per-update unstructured task delivery with a bounded mailbox.
3. Separate current values from histories and large collections.
4. Add sequence/generation and diagnostic counters.
5. Make start/stop/restart explicit.
6. Audit every metric enum/switch mapping and units against producers and gauges.
7. Batch main-actor observable mutations.
8. Stress with induced main-actor stalls.

### Exit

G03: maximum pending delivery state meets the invariant; stale work and post-stop delivery are absent; feature parity passes.

## P04 — Repair gauge and Metal architecture

### Objectives

- remove per-gauge resource multiplication and independent clocks;
- pause all unnecessary rendering;
- preserve visual and accessibility behavior.

### Required actions

1. Inventory `MTKView`, delegate, device, queue, pipeline, library, sampler, texture, and buffer creation.
2. Prefer a single rig surface; otherwise share the resource service.
3. Move immutable resource construction out of view updates.
4. Reuse bounded buffers.
5. unify scheduling and stop active cadence after convergence.
6. Pause hidden/occluded/detached surfaces.
7. preserve labels, units, interactions, accessibility, resize, appearance, and fallback.
8. Capture Metal System Trace and allocation evidence.

### Exit

G04 passes; hidden/static draws are quiescent, resource counts are bounded, and UI parity remains.

## P05 — Close lifecycle and concurrency risks

### Objectives

- determine effective ownership of every audit E2 item;
- repair confirmed leaks/races/hangs;
- make shutdown deterministic.

### Required actions

1. Generate a resource-owner matrix.
2. Trace stored tasks, timers, observers, subscriptions, processes, pipes, file handles, delegates, file watchers, and native allocations.
3. Add explicit idempotent `start`/`stop` where lifecycle is implicit.
4. Convert self-retaining loops to structured or owner-cancelled tasks.
5. Build process supervision with bounded output and deadlines.
6. remove main-actor blocking and unsafe detached mutation.
7. run release-boundary loops and inspect app-owned retain paths.
8. Run sanitizers separately.

### Exit

G05 passes; every audit risk has evidence-backed disposition.

## P06 — Bound histories, caches, logs, and application state

### Objectives

- enforce memory and work budgets across all long-lived collections;
- respond to visibility, memory, power, and thermal state.

### Required actions

1. Inventory all growing collections and caches.
2. Replace histories with bounded ring buffers.
3. cost-limit caches and add expiration/invalidation.
4. bound process output and log rotation.
5. cap concurrent projects, requests, readers, and model streams where necessary.
6. implement `ResourcePolicy`.
7. add memory-pressure handling and diagnostics.
8. prove project/session close returns to bounded steady state.

### Exit

G06 passes.

## P07 — Implement project-memory MCP

### Objectives

- add durable, isolated, bounded project memory;
- preserve every existing MCP capability.

### Required actions

1. Reuse/extend existing MCP protocol and executable architecture.
2. Implement stable project identity and path aliases.
3. Add SQLite3 repository wrapper and actor ownership.
4. Implement schema and migrations with fixtures.
5. Implement memory service, redaction, dedupe, search, pagination, and maintenance.
6. Add MCP tools/resources and capability negotiation.
7. Create conformance/golden transcript tests.
8. Test restart, project isolation, cancellation, database locks, disk full, corruption, export/import, and resource budgets.
9. Add status/health diagnostics without exposing content.

### Exit

G07 passes.

## P08 — Implement continuity engine

### Objectives

- create durable checkpoints/handoffs;
- resume idempotently after any interruption.

### Required actions

1. Implement structured handoff model/schema.
2. Implement context budget monitor with exact capability data and conservative fallback.
3. Implement the persisted rollover state machine.
4. Integrate checkpoint/handoff records with project memory.
5. Add continuity MCP tools/resources.
6. Implement startup recovery.
7. Inject failures/crashes at every transition.
8. Prove successor acknowledgment and predecessor sealing semantics.

### Exit

G08 passes.

## P09 — Implement host adapter/plugin and full rollover

### Objectives

- provide automatic successor creation without operator intervention;
- preserve external MCP-client compatibility.

### Required actions

1. Detect and record existing host capabilities.
2. Reuse a supported existing adapter if it meets the full contract.
3. Otherwise create `ForgeHostPluginKit` and a compile-time registered `ForgeNativeSessionHostPlugin`.
4. Integrate existing provider configuration and secure credentials.
5. Implement bounded streaming and session creation/bootstrap/acknowledgment.
6. expose capability and continuity health.
7. test fake host, native plugin, external MCP-only mode, cancellation, rate limits, timeout, crash, and concurrent projects.
8. Verify there is no private UI automation.

### Exit

G09 passes with an end-to-end autonomous rollover.

## P10 — Migration, compatibility, and feature parity

### Objectives

- prove all current features survived;
- prove data/protocol migration and additive capabilities.

### Required actions

1. Run the full feature matrix.
2. Compare MCP golden snapshots.
3. migrate every old-format fixture, reopen, validate, and rerun migration.
4. run UI commands/accessibility/navigation tests.
5. run import/export and model/provider compatibility.
6. resolve every `unknown` or `untested` feature state.
7. scan for accidental renames/removals.

### Exit

G10 passes.

## P11 — Release stress and performance validation

### Objectives

- demonstrate bounded behavior and efficiency on representative memory tiers.

### Required actions

1. Build Release with production optimization.
2. run identical before/after stress fixtures.
3. profile telemetry stalls, gauge idle/active/open-close, project switching, process loops, large memory corpus, MCP concurrency, and repeated rollover.
4. capture CPU/GPU/wakeups/memory/database/latency metrics.
5. test low-power, memory pressure, visibility, network interruption, and disk pressure.
6. tune only from measurements.
7. verify diagnostics themselves are bounded.

### Exit

G11 passes.

## P12 — Final verification and delivery

### Objectives

- close findings;
- verify evidence integrity;
- produce a factual completion report.

### Required actions

1. run all builds/tests/gates from a clean checkout;
2. run package, security, secret, and prohibited-authorship scans;
3. verify no unresolved critical/high finding;
4. validate evidence hashes and gate commands;
5. run `verify_completion.py`;
6. generate completion report, migration notes, architecture decisions, performance results, and recovery instructions;
7. create a final durable handoff and release checkpoint.

### Exit

G12 and the completion validator pass. Only then mark run state `complete`.

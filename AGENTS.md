<!-- FORGE-QWEN-REMEDIATION:BEGIN -->
# Shippable remediation contract

Read `.forge-qwen-remediation/AGENTS.md` and use its doctor, selector, deterministic gates, and do-not-ship boundary. Shell access and every current feature must remain available.
<!-- FORGE-QWEN-REMEDIATION:END -->

<!-- FORGE-AUTONOMOUS-CONTINUITY-DESIGN:BEGIN -->
# Autonomous continuity implementation supplement

Before autonomy, continuity, project context, provider, shell, or runtime work, read `.forge-continuity-design/AGENTS.md` and execute `.forge-continuity-design/schemas/work-packages.json`. This supplement requires shell enabled by default, exact project-generation binding, manager-owned context enforcement, a real LM Studio transport in the existing session-host plugin, automatic fresh-root rollover, predecessor fencing, crash recovery, and automatic continuation.
<!-- FORGE-AUTONOMOUS-CONTINUITY-DESIGN:END -->

<!-- FORGE-CONDUCTOR-AUTONOMOUS-CONTRACT:BEGIN -->
# Forge Conductor repository execution contract

## Mission

Deliver a production-quality native macOS Forge Conductor application in which:

- every current user-facing and protocol-facing feature remains available;
- memory leaks and leak-like unbounded retention are removed and proven with repeatable evidence;
- gauges and telemetry are correctly wired, bounded, responsive, and quiescent when not visible;
- project memory is exposed through a reliable project-scoped MCP server;
- continuity checkpoints and handoffs are durable, compact, crash-safe, and automatically consumed;
- the active model session can roll over without operator intervention when the host exposes a supported session API;
- a statically registered host-adapter plugin is built when Forge must own session creation;
- the application remains efficient on supported Macs with differing physical-memory capacities;
- build, test, debug, profiling, migration, compatibility, and recovery evidence is retained.

This file is authoritative for the repair run. Repository-specific instructions that follow this section remain in force unless they conflict with a stricter requirement here.

## Required reading before editing

Read, in order:

1. `.forge-codex/docs/EXECUTION_CONTRACT.md`
2. `.forge-codex/docs/EVIDENCE_RULES.md`
3. `.forge-codex/docs/DECISION_POLICY.md`
4. `.forge-codex/docs/FAIL_FORWARD_POLICY.md`
5. `.forge-codex/docs/FEATURE_PRESERVATION.md`
6. `.forge-codex/docs/AUDIT_TO_REMEDIATION.md`
7. `.forge-codex/docs/PHASE_PLAYBOOK.md`
8. `.forge-codex/architecture/TARGET_ARCHITECTURE.md`
9. `.forge-codex/specifications/COMPLETION_GATES.md`
10. `.forge-codex/plans/phases.json`
11. `.forge-codex/plans/gates.json`

Read the subject-specific architecture and specification documents immediately before implementing that subject.

## Start and resume protocol

At the beginning of every session or process invocation:

```bash
./.forge-codex/scripts/doctor.sh
./.forge-codex/scripts/statectl.py show
./.forge-codex/scripts/select_next_work.py
```

Then:

1. Read `.forge-codex/state/current-handoff.json` when present.
2. Inspect the current Git status and do not overwrite unrelated work.
3. Read the last successful gate and the open issue ledger.
4. Re-run the smallest proof command required to establish the current state.
5. Continue the selected ready phase. Do not restart completed work without contrary evidence.

All state changes must be atomic and recorded in `.forge-codex/state/events.jsonl`.

## Non-negotiable engineering constraints

- Use Swift, SwiftUI, AppKit, Metal, OSLog, Foundation, Network, Security, SQLite3, XCTest, and other Apple-native frameworks appropriate to the existing deployment target.
- Do not introduce Java, an interpreted application runtime, Electron, a browser shell, or a replacement cross-platform UI stack.
- Python and shell are permitted only for build, test, migration verification, evidence collection, or package automation. They are not production application components.
- Preserve existing MCP tool names, JSON field names, settings keys, project formats, command identifiers, accessibility identifiers, and external behavior unless a versioned compatibility layer is supplied and tested.
- Prefer object-oriented protocols, value models, actors, and explicit ownership. Every long-lived resource must have an identifiable owner and shutdown boundary.
- No unbounded queues, arrays, histories, caches, task creation, retries, subprocess output, log retention, or render loops.
- No blocking process waits, synchronous pipe drains, file traversal, database work, or model calls on the main actor.
- No detached mutation of main-actor or observation state.
- No broad cleanup added merely to mask a retaining edge. Remove or weaken the retaining edge and prove release.
- No speculative fixes. State a hypothesis, cite source evidence, create a reproducer or measurement, then patch and compare the same flow.
- No unsupported private UI automation to create host chat sessions.
- No generator credits, automated-author notices, authorship watermarks, or commit attribution trailers.
- Never weaken, skip, delete, or rewrite a failing test solely to make a gate pass.

## Evidence classes

Use these labels in findings and commits:

- **E0 — observed runtime proof:** repeatable trace, memgraph ownership path, test failure, signpost interval, or protocol transcript.
- **E1 — deterministic source proof:** source structure necessarily creates unbounded work, incorrect mapping, blocking, or resource multiplication.
- **E2 — source risk requiring runtime reachability:** retaining edge or cleanup gap exists, but actual lifetime has not yet been demonstrated.
- **E3 — profiling target:** plausible performance site with no defect claim.

A source risk does not become a confirmed leak without E0 ownership or release evidence. A lower aggregate memory number alone is not proof.

## Feature-preservation rule

Before changing behavior:

1. Generate `.forge-codex/state/feature-baseline.json`.
2. Create or update executable parity tests for every detected feature surface.
3. Record baseline screenshots or semantic UI snapshots for critical screens where practical.
4. Record MCP capability and schema snapshots.
5. Record settings/defaults, migrations, commands, project formats, and integrations.
6. Associate each source change with preserved feature identifiers.

A feature may be changed only when necessary to correct a proven defect or implement a requested capability. Its prior contract must remain available or receive a versioned migration and compatibility test.

## Repair order

Execute the phase DAG in `.forge-codex/plans/phases.json`. The default critical path is:

1. reproducible baseline and observability;
2. bounded telemetry delivery;
3. efficient gauge/Metal ownership and cadence;
4. lifecycle and concurrency closure;
5. bounded histories, caches, and subprocess I/O;
6. project-memory MCP;
7. continuity engine and handoffs;
8. supported host adapter/plugin and automatic rollover;
9. integration, migration, stress, profiling, and release gates.

Build and run the smallest relevant tests after each coherent change. Commit checkpoints after passing phase gates.

## Telemetry invariant

The GUI delivery boundary may retain at most:

- one in-flight main-actor delivery; and
- one replaceable latest snapshot.

No producer update may enqueue an independently retained unstructured main-actor task. Sequence numbers must make stale delivery observable. Drop/coalescing counters must be exported. Delivery order and shutdown must be tested.

## Gauge invariant

Hidden or detached gauges consume no recurring rendering work. Visible gauges render at a bounded cadence selected by current value-change and animation state. Metal device, command queue, pipeline, sampler, and immutable geometry resources are shared by a clearly scoped renderer service. Mutable buffers are reused. The number of render surfaces must be justified by the layout and measured.

## Memory MCP invariant

Memory is isolated by stable project identity, durably persisted, migration-safe, deduplicated, bounded at query and cache boundaries, and recoverable after interruption. Search results are paged and byte/token bounded. The MCP server supports capability negotiation and preserves existing tools.

## Continuity invariant

A rollover is not complete until:

1. the checkpoint and handoff are durably committed;
2. the successor session is created through a supported host adapter;
3. the successor has loaded and acknowledged the same handoff identifier;
4. the predecessor is sealed idempotently.

Crash recovery must resume from every transition without duplicate or lost work. When an external host cannot create sessions through a supported API, Forge must provide a native host mode via the plugin contract rather than pretend that MCP alone can force the external UI.

## Fail-forward behavior

- Persist evidence and state before risky work.
- Retry transient operations with bounded exponential backoff and a total deadline.
- Mark a blocked gate with evidence, continue independent ready phases, and revisit it automatically.
- A global hard blocker stops release, not investigation or independent implementation.
- After three no-progress attempts, switch to diagnostic mode, isolate the smallest reproducer, and choose a reversible alternate implementation.
- Never wait indefinitely for a process, pipe, stream, lock, network operation, or model response.
- Never ask the operator to choose among technical options already resolvable by this contract.

## Required build and validation loop

Use the repository's project shape. Prefer the included project-local entrypoint once installed:

```bash
./script/build_and_run.sh --verify
./.forge-codex/scripts/test_all.sh
./.forge-codex/scripts/run_gates.sh --ready
```

On macOS, collect runtime evidence with the commands selected by:

```bash
./.forge-codex/scripts/profile_macos.sh --list
```

Run Address Sanitizer and Thread Sanitizer in separate configurations. Run release-configuration performance tests. Capture before/after flows using the same fixture, machine, build configuration, duration, and interaction script.

## Completion

Completion requires:

```bash
./.forge-codex/scripts/verify_completion.py
```

to exit zero. It must verify all hard gates, feature parity, no unresolved critical/high findings, successful migrations, MCP conformance, continuity crash recovery, resource-budget evidence, and the prohibited-attribution scan. Do not replace evidence files manually or mark gates successful without their commands and artifacts.
<!-- FORGE-CONDUCTOR-AUTONOMOUS-CONTRACT:END -->

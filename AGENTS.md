<!-- FORGE-OWNER-SLICE-WORKFLOW:BEGIN -->
# Current execution workflow (owner-directed, single slice)

The owner supplies the current slice and all working locations. Perform only that slice with the tools actually exposed. Read the necessary source, make one small change, test it, commit locally, push the slice branch, and open a PR targeting main. Then stop for owner review. Historical packages, selectors, phase lists, and old handoffs do not choose work. Do not run automation scripts for this workflow. Preserve existing native engineering, compatibility, authorization, and evidence requirements. Never merge or begin another slice without the owner's next instruction. Missing information, a failed required check, or no new evidence means report the specific blocker and stop.

A fresh slice branch is cut from current `main` only after the prior slice is merged and the owner authorizes the slice. The supplied session contract and the one authorized slice card are the complete working context; do not load old packages, archived transcripts, the full slice sequence, or old resume seeds as dispatch. After each slice: one tested local commit, one PR targeting `main`, and a hard stop.

This section is the single current assignment source for this repository, and the open-PR owner review is the single stop boundary.
<!-- FORGE-OWNER-SLICE-WORKFLOW:END -->

<!-- FORGE-CONDUCTOR-ENGINEERING:BEGIN -->
# Engineering requirements (in force for every slice)

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

These requirements bind every slice. They do not choose which slice runs.

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

1. Identify the affected feature surface and its prior contract.
2. Create or update executable parity tests for every detected feature surface.
3. Record baseline screenshots or semantic UI snapshots for critical screens where practical.
4. Record MCP capability and schema snapshots where the surface includes MCP tools.
5. Record settings/defaults, migrations, commands, project formats, and integrations where affected.
6. Associate each source change with preserved feature identifiers.

A feature may be changed only when necessary to correct a proven defect or implement a requested capability. Its prior contract must remain available or receive a versioned migration and compatibility test.

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

## Shell and data protection

- The native shell tool remains available for owner-authorized direct native commands, with its existing timeout, output, and truncation semantics preserved. A timed-out or truncated result is never treated as a pass.
- Durable project state (memory, continuity, credentials) remains isolated by stable project identity, bounded, and never exposed across projects. Do not weaken trust checks or signing to make a check pass.

## Fail-forward behavior

- Persist evidence and state before risky work.
- Retry transient operations with bounded exponential backoff and a total deadline.
- Mark blocked work with evidence. Do not begin another slice or widen scope; report the specific blocker and stop.
- A global hard blocker stops release, not investigation within the authorized slice.
- Never wait indefinitely for a process, pipe, stream, lock, network operation, or model response.
- Never ask the owner to choose among technical options already resolvable by these requirements.

## Build and validation (direct native commands)

Use the repository's own build definitions with direct native commands, one at a time:

- CLI build: `swift build --product forge-conductor`
- App compilation: `swift build --product forge-conductor-app`
- Focused unit test: `swift test --filter '<observed test class or class/test method>'`
- Ordinary app build: `xcodebuild -scheme ForgeConductor -configuration Debug -destination 'platform=macOS' build`
- Focused app-hosted test: `xcodebuild -scheme ForgeConductorAppTests -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO '-only-testing:ForgeConductorAppTests/<observed class>/<observed method>' test`
- Whitespace check: `git diff --check`

Require a successful terminal result and verify that the intended test actually executed. Zero selected tests, skips, timeouts, and truncated output without a terminal result are not passes. Sanitizer and release-configuration matrices remain available for the slices that specifically require them; they are not default per-slice gates.
<!-- FORGE-CONDUCTOR-ENGINEERING:END -->

<!-- FORGE-SUPERSEDED-AUTOMATION-HISTORY:BEGIN -->
# Superseded dispatch and automation (history — no dispatch authority)

The mechanisms below were active dispatch for earlier runs. They are superseded by the current execution workflow above. They select no work, they carry no "stricter contract wins" authority, and none of their commands or scripts may be executed as part of this workflow. Their full text is retained in the archived package directories (`.forge-codex/`, `.forge-continuity-design/`, `.forge-qwen-remediation/`, `.forge-qwen-shippable-v080/`, `.forge-e2/`, `.alpha-work/`) and in Git history.

Superseded, for reference only:

- **CLU shippable rescue contract:** the owner-machine rescue package location, its START-HERE/CODEX-EXECUTION-PROMPT reading, `phases/work-packages.json` P00–P14 scheduling, the `run-state.json` package selector, and the CLU-CORRECTION-001 reading requirements.
- **Autonomous continuity design supplement:** dispatch to shipping work orders B and D and to `.forge-codex` architecture/specification documents, including automatic fresh-root rollover and automatic continuation.
- **Autonomous repair contract dispatch:** the "this file is authoritative for the repair run… stricter requirement wins" clause, the eleven-document required-reading list, the scripted start/resume protocol (`doctor.sh`, `statectl.py`, `select_next_work.py`, `current-handoff.json`, `events.jsonl` recording), the `phases.json` repair-order DAG, the scripted build/gate loop (`build_and_run.sh --verify`, `test_all.sh`, `run_gates.sh --ready`, `profile_macos.sh --list`), and completion via `verify_completion.py`.

Do not resume any of these as a current assignment from any seed, handoff, or package.
<!-- FORGE-SUPERSEDED-AUTOMATION-HISTORY:END -->

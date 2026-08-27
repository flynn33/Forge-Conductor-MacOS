# Testing Matrix

## Build matrix

At minimum:

- app Debug;
- app Release;
- all Swift package products;
- all test targets;
- Apple Silicon native;
- deployment-target compatibility supported by the project;
- signing-independent local build;
- normal signed build when credentials are already available.

Do not silently change the deployment target or drop an architecture.

## Unit tests

### Telemetry

- latest-value mailbox capacity;
- sequence and generation handling;
- mapping and units;
- ring-buffer limits;
- shutdown/restart;
- coalesce/drop counters.

### Gauges

- ranges, clamping, thresholds;
- animation/scheduler state;
- resource cache;
- visibility/occlusion transitions;
- buffer capacity;
- fallback renderer.

### Lifecycle

- task/timer/observer/subscription stop;
- process/pipe/file-handle closure;
- cache eviction;
- project/session owner release.

### Memory

- identity resolution;
- CRUD, dedupe, links;
- search rank/filter/page;
- response byte limit;
- cache cost;
- redaction;
- schema migrations;
- corruption and disk errors.

### Migration pathname qualification

- exercise the production `SQLITE_FCNTL_HAS_MOVED` guard with a distinct valid
  database left at the pathname of an already open migration database;
- prove entry-boundary substitution fails closed before backup, manifest,
  schema, or receipt side effects and preserves both database payloads;
- prove pre-COMMIT substitution rolls back authoritative schema and receipt
  changes while retaining the prepared backup and manifest needed for recovery;
- record the current VFS result for an A-to-B-to-A restoration cycle and,
  regardless of that result, do not treat sequential checks as qualification
  against hostile same-user namespace substitution or direct file mutation;
- do not broaden the trust claim without a custom VFS that pins the
  main/WAL/journal family and/or an independent privilege boundary.

### Continuity

- context policy;
- checkpoint construction;
- every state transition;
- idempotency;
- crash recovery;
- adapter capability selection;
- handoff validation.

## Integration tests

- app service composition;
- telemetry producer to visible gauge;
- hidden gauge quiescence;
- project open/close and switch loops;
- MCP executable protocol transcripts;
- memory writes visible after server restart;
- concurrent project isolation;
- model-session rollover through fake and native host plugins;
- app restart during rollover;
- old persisted data migration;
- external MCP-only host behavior.

## UI tests

- main windows/scenes;
- project management;
- commands/shortcuts;
- settings;
- gauge screen lifecycle;
- memory/continuity status surfaces;
- error and recovery states;
- accessibility.

Use stable accessibility identifiers. UI tests assert actions and semantic state, not fragile pixel coordinates.

## Stress and soak

Automate:

- telemetry at representative and extreme rates;
- induced main-actor stalls;
- hundreds of gauge navigation cycles;
- repeated project open/close;
- process start/cancel/failure loops;
- large bounded memory corpus;
- concurrent MCP clients;
- rollover repeatedly across sessions/projects;
- database lock, disk-full fixture, and network/provider interruption.

Use deterministic duration/iteration bounds and report slopes/percentiles.

## Sanitizers and diagnostics

Run separately:

- Address Sanitizer;
- Thread Sanitizer;
- strict concurrency diagnostics;
- Main Thread Checker;
- malloc stack logging/leaks where suitable;
- Instruments Allocations/Leaks;
- Time Profiler;
- SwiftUI instrument;
- Metal System Trace/GPU tools;
- Energy Log or equivalent supported template.

A sanitizer configuration is not used as the performance baseline.

## Performance acceptance

Capture before and after on the same machine/fixture:

- resident-size trajectory and post-release level;
- allocation rate;
- main-thread CPU;
- total CPU and wakeups;
- frame cadence/dropped frames;
- Metal command/pipeline/draw counts;
- telemetry queue depth;
- MCP latency p50/p95/p99;
- SQLite size/WAL/cache;
- rollover latency and peak memory.

Hard absolute invariants such as queue capacity and hidden draw count must pass. Comparative targets use baseline and budgets from `plans/resource-budgets.json`.

## Flake handling

A test is a flake only after repeated evidence shows nondeterministic outcomes under identical conditions. Fix synchronization/fixtures. Quarantine does not satisfy a hard gate.

# Autonomous Completion Checklist

This checklist mirrors the hard gates. It is a navigation aid, not a substitute for machine-readable evidence.

## Repository and baseline

- [ ] Package validation passes.
- [ ] Git state and source hash are recorded.
- [ ] Project-specific build/run script works.
- [ ] Every target, product, scene, command, setting, data format, integration, and MCP surface has a stable feature ID.
- [ ] Characterization tests cover behavior-changing areas.
- [ ] Baseline failures and runtime traces are captured.

## Telemetry

- [ ] Producer-to-presentation topology is documented.
- [ ] Delivery retains at most one in-flight update and one replaceable latest snapshot.
- [ ] No per-event unstructured main-actor task remains.
- [ ] Sequence/generation, coalesce/drop, and depth diagnostics pass.
- [ ] Current values are separated from bounded histories.
- [ ] Metric-to-gauge mapping, units, ranges, and freshness pass.
- [ ] Start/stop/restart and release-boundary tests pass.
- [ ] Main-actor stall stress remains bounded.

## Gauges and Metal

- [ ] Device/queue/pipeline/resource creation topology is documented.
- [ ] One rig surface is used, or multiple surfaces are justified and share resources.
- [ ] No high-frequency buffer allocation remains.
- [ ] One scheduler owns cadence.
- [ ] Hidden/static/occluded/detached gauges become quiescent.
- [ ] Open/close cycles release native and scene resources.
- [ ] Visual, command, and accessibility behavior remains.
- [ ] Release Metal/SwiftUI/CPU/GPU evidence meets budgets.

## Lifecycle and concurrency

- [ ] Resource-owner matrix covers every long-lived task, timer, observer, subscription, process, pipe, file handle, watcher, delegate, database, stream, and native allocation.
- [ ] Every audit risk has an evidence-backed disposition.
- [ ] Confirmed retaining edges are removed and re-proven.
- [ ] Child processes and readers stop under deadlines.
- [ ] Main actor performs no blocking process/file/database/model work.
- [ ] Sanitizer and strict concurrency runs pass.
- [ ] Project/session/scene release boundaries reach a bounded steady state.

## Bounded application state

- [ ] Every long-lived collection has a capacity and eviction/expiration policy.
- [ ] Telemetry histories use ring buffers.
- [ ] Logs and subprocess output rotate or ring-buffer.
- [ ] Caches have byte/cost ceilings and pressure response.
- [ ] Concurrent projects/requests/streams have limits.
- [ ] Low-memory, thermal, power, hidden, and idle policies pass.

## Project memory MCP

- [ ] Existing MCP tools and schemas remain compatible.
- [ ] Stable project identity survives path moves.
- [ ] SQLite wrapper and actor ownership are complete.
- [ ] Migrations are transactional, idempotent, recoverable, and fixture-tested.
- [ ] CRUD, dedupe, links, bounded search, paging, cancellation, and deadlines pass.
- [ ] Automatic capture stores compact structured memory, not raw transcripts.
- [ ] Project isolation, restart durability, corruption, disk-full, lock, export/import, and redaction pass.
- [ ] MCP executable conformance and resource budgets pass.

## Continuity

- [ ] Context budget uses provider capability data or a tested conservative fallback.
- [ ] Checkpoint and handoff are durable, compact, redacted, and reference-oriented.
- [ ] Every state transition persists intent before side effects.
- [ ] Idempotency and exact successor acknowledgment pass.
- [ ] Crash injection at every transition recovers.
- [ ] App relaunch and concurrent-project rollover pass.
- [ ] Continuity MCP tools/resources report truthful capability state.

## Host adapter/plugin

- [ ] Existing host capability report is complete.
- [ ] A supported adapter satisfies create/bootstrap/acknowledge/reconcile/cancel/recover, or the native plugin is built.
- [ ] Plugin targets compile and run contract tests.
- [ ] Full autonomous rollover completes without operator action.
- [ ] External MCP-only clients retain memory/handoff compatibility.
- [ ] No private UI automation or undocumented host endpoint is used.

## Compatibility, release, and evidence

- [ ] All feature statuses are preserved, additive, or migrated.
- [ ] Old project/data fixtures migrate and reopen.
- [ ] MCP golden transcripts remain compatible.
- [ ] UI commands, shortcuts, settings, and accessibility pass.
- [ ] Debug, Release, test, sanitizer, stress, and recovery matrices pass.
- [ ] Runtime evidence exists on a capable macOS machine.
- [ ] Critical and High unresolved findings equal zero.
- [ ] Secret and automated-authorship scans pass.
- [ ] Every gate artifact hash validates.
- [ ] `verify_completion.py` exits zero and marks the run complete.

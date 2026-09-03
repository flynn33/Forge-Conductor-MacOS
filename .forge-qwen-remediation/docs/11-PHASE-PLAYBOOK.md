# End-to-end remediation playbook

This playbook translates the machine-readable work packages into an execution order. It is not permission to skip `plans/work-packages.json`, `plans/gates.json`, or the subject-specific architecture and test contracts.

## Operating loop for every work package

1. Run `doctor.py`, display state, and run `select_next_work.py`.
2. Recompute the source manifest and confirm the selected package is ready.
3. Read every finding, source location, architecture document, and test contract referenced by that package.
4. Add or strengthen parity and adversarial tests before changing production behavior.
5. Implement the smallest coherent slice without deleting existing features.
6. Run the smallest relevant tests, then the package-level matrix.
7. Record immutable evidence. A command log is evidence, not a gate pass.
8. Run the registered deterministic gate validator.
9. Accept its receipt through `accept_gate_result.py`; do not set a gate to passed manually.
10. Close mapped findings only after their required gates pass and closure evidence is complete.
11. Complete the work package through `statectl.py`; it refuses completion while required gates are open.
12. Write a handoff before ending the session.

## P00 — authoritative baseline

Preserve the supplied archive hash and source manifest. Inventory SwiftPM/Xcode membership, MCP names and JSON schemas, tabs, accessibility identifiers, settings defaults, migrations, manager routes, shell behavior, runtime tools, and current native prerequisites. Treat unavailable Git lineage as unknown rather than reconstructing it from embedded state. Initialize the no-ship guard and evidence chain.

Exit only when G00 and G01 have immutable receipts bound to the unchanged baseline.

## P01 — completion truth

Remove the production path that converts model-selected generic tool-result hashes into gate evidence. Implement a durable gate registry, gate definitions, validator executions, leases, immutable receipts, and a manager-owned completion-validation transition. The model may request validation and provide a summary; it may not nominate proof or mark a gate passed.

Test unrelated, failed, stale-generation, wrong-project, wrong-run, wrong-gate, wrong-validator-version, expired, reused, and invented evidence. Test crash recovery before, during, and after validator execution.

Exit only when the production composition no longer injects the generic validator and G02 passes.

## P02 — single continuity authority

Introduce an explicit continuity mode. In managed autonomous mode, only project-scoped `ContextBudgetSupervisor`, `ContinuityCoordinator`, and durable manager state may initiate or block rollover. Remove global latest handoff authority and the fixed-count/manual-new-chat blocker from managed routing. Preserve a separately labeled external-host compatibility mode without claiming autonomy.

Test project/generation isolation, no manual-new-chat output in managed mode, exact acknowledgment, predecessor fencing, duplicate successor quarantine, and all durable recovery states.

Exit only when G03 passes. Real-provider proof remains G15.

## P10 — E2 atomic filesystem closure

This package may proceed in parallel after P00. Install and follow `.forge-e2`. Replace destructive pathname verify-then-mutate sequences with atomic namespace capture/publication and post-capture validation. Use a small C interoperability target only for public Darwin APIs that Swift cannot express reliably. Unsupported filesystems and ambiguous states fail closed. Preserve shell tools; internal secure-filesystem code must not depend on shell commands.

Exit only after the supplied atomic-swap attacker, volume capability, crash, cancellation, Unicode/case, hard-link, parent-rebinding, and outside-root sentinel matrix passes and G12 has a reviewed closure argument.

## P03 — immutable package ingestion

Build package ingestion only on the corrected completion and E2 foundations. Never execute from the user-selected source. Validate directories, ZIP, `.forgepackage`, and compatible `.forge-codex` inputs into transaction-scoped quarantine, enforce bounded paths/counts/sizes/depth, reject links and collisions, compute a canonical manifest, and publish accepted content into a hash-addressed immutable store.

Prove source mutation and deletion cannot alter accepted content and that every crash state reconciles to accepted, rejected, or quarantined—never partially executable.

Exit only when G04 passes.

## P04 — durable autonomous Work Queue

Implement durable package records, dependencies, priorities, leases, epochs, heartbeats, queue assignments, attempts, package runs, artifacts, progress, blocked states, validation, retries, pause/resume/cancel, and automatic next-package reservation. The manager is the sole scheduler; the GUI is a projection and command client.

Expose only bounded package tools: `queue.current`, `package.progress`, `package.blocked`, `package.complete_request`, and `package.artifact.register`. Completion requests start registered validators. A model cannot select the next package or pass gates.

Add a native Work Queue tab while preserving all existing tabs. Prove two-package ordered execution, rollover during a package, manager restart, lease expiry, generation fencing, and at most one accepted assignment.

Exit only when G05 passes.

## P05 — selective project reset

Implement memory-only, continuity-only, combined, and advanced run-history reset. Use an exclusive project maintenance lease, pause reservations and writes, fence provider sessions/jobs, close and evict repositories, create an optional hash-verifiable backup, rotate or clear only selected state, increment the generation exactly once, invalidate old bindings, rebuild projections, persist a receipt, and resume safely.

Test every crash boundary and stale result type. Reset must never change global shell policy or another project.

Exit only when G06 passes.

## P06 — complete operator controls

Replace every empty or placeholder action with typed, authenticated manager commands. Finish project relink/reset, queue controls, runtime cancellation, continuity checkpoint/rollover, provider connection test and contract probe, and authoritative provider/runtime projections. Commands use request IDs and idempotency keys, expose progress, and survive reconnects.

Exit only when source scans find no empty action, manager route tests pass, executed XCUITests cover controls, and G07 passes.

## P07 — hardened XPC runtime

Keep `workspaceIsolated` truthfully labeled as application-level isolation. Add a separately signed App Sandbox XPC service for `hardenedXPC`, narrow protocols, security-scoped bookmark leases, bounded scripts/input/output, explicit network profiles, descendant cancellation, audit receipts, and recovery. Do not silently install dependencies or disable shell when the helper is unavailable.

Prove allowed project access, denied home/other-project access, denied-network behavior, descendant confinement, cancellation, stale bookmark recovery, and arm64/x86_64 policy consistency.

Exit only when G08 passes. G14 later proves legacy shell end to end.

## P08 — resource pressure, retention, telemetry, and Metal

Make `ResourcePressureCoordinator` authoritative for queue/run concurrency, provider payload limits, runtime jobs, telemetry histories, event retention, cache budgets, and active gauge FPS. Preserve active evidence and current handoffs before pruning. Replace front-removal arrays with bounded ring/deque structures. Eliminate duplicate host-history insertion and use one host sample as the source of truth.

Keep latest-value telemetry delivery, shared Metal resources, persistent buffers, and on-demand rendering. Correct visibility accounting and prove hidden views have no recurring draw loop. Do not remove gauges or telemetry features.

Exit only after G09 and G10. Native memory/endurance proof remains G17.

## P09 — dashboard hardening

Add an actor-owned connection registry, bounded admission, header/body limits, monotonic idle and total deadlines, centralized stop cancellation, and rejection/expiry diagnostics. Split minimal redacted health from authenticated operational reads. Require constant-time bearer validation for sensitive status, settings, project, run, autonomy, continuity, runtime, provider, and evidence surfaces.

Exit only when adversarial loopback and route authorization tests pass G11.

## P11 — repository, test, and documentation integrity

Restore exact SwiftPM/Xcode source parity, including provider contract fixtures and all new C/XPC/UI targets. Split oversized files at ownership and transaction boundaries where this reduces unchecked concurrency risk. Remove generated build products, local state, credentials, and absolute local paths from release source. Keep a compact hash-addressed evidence bundle and reproducible release-attestation scripts.

Update versioned user and architecture documentation to distinguish managed autonomous mode from external compatibility mode and to describe shell, queue, reset, provider, runtime, continuity, and qualification truth accurately.

Exit only when G13 passes on the final source shape.

## P12 — signed native and real-provider qualification

Run signed local Xcode tests, not build-only substitutes. Prove LaunchAgent installation/restart/reconnect, Keychain paths, Settings-to-manager-to-MCP shell, provider test/probe, real LM Studio forced-threshold rollover with GUI closed, XPC sandbox boundaries, E2 volume behavior, and the full crash matrix. Create an ephemeral local signing identity when necessary; never embed its password or private key.

A synthetic provider cannot pass G15. A compiled XCUITest bundle cannot pass G16. Static shell checks cannot pass G14.

Exit only when G14, G15, G16, and G18 pass.

## P13 — low-memory and integrated endurance

Exercise constrained, standard, and expanded resource profiles with deterministic workloads. Measure RSS after warmup and quiescence, allocation trends, main-thread time, telemetry cadence, hidden/visible Metal frames, database growth, event pruning, provider payloads, queue throughput, and process output bounds. Use Instruments and memgraph ownership evidence where required.

Run at least two instruction packages through real autonomous execution across manager restart and context rollover with no operator action. All validators, artifacts, handoffs, assignments, and receipts must remain project/generation correct.

Exit only when G17 and G19 pass.

## P14 — release candidate and hard stop

Re-run every mandatory validator against the exact final source manifest. Build a local release candidate, hash it, generate the release-readiness attestation, and verify all thirty finding closures, gate receipts, work packages, toolchain records, feature parity snapshots, and no-ship evidence. Do not notarize, upload, publish, tag a release, update a feed, or distribute the artifact.

The terminal state is exactly:

```json
{
  "ready_to_ship": true,
  "shipped": false
}
```

Exit only when G20 and `verify_completion.py` pass.

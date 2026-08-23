# Decision Log

## DEC-0001 — Bound realtime telemetry before the main actor

- Date: 2026-08-23
- Problem: every telemetry update could enqueue additional main-actor work without a finite pending-work ceiling.
- Evidence: `.forge-codex/evidence/P03-bounded-telemetry-before-after.json`
- Constraints: preserve the existing telemetry contract and refresh controls.
- Feature IDs: `TEL-UI-BINDING`, `TEL-REALTIME-ENGINE`
- Selected option: one latest-value mailbox with one in-flight frame and one replaceable buffered frame.
- Ownership/lifetime impact: `AppTelemetryBinding` owns and cancels one consumer task; detach invalidates its generation and releases the application reference.
- Compatibility impact: no public telemetry fields or commands were removed.
- Resource impact: pending delivery is constant-space.
- Tests: `LatestValueMailboxTests`, `RealtimeStreamTests`, UI stress qualification.
- Rollback: restore the prior binding implementation and rerun G03-G05; this would reintroduce the original unbounded-work finding.

## DEC-0002 — Share Metal resources and draw on telemetry demand

- Date: 2026-08-23
- Problem: each gauge surface owned duplicate Metal setup and an independent recurring render cadence.
- Evidence: `.forge-codex/evidence/P04-metal-performance-report.json`, `.forge-codex/evidence/P11-profile-report.json`
- Constraints: preserve all gauge visuals and telemetry parity.
- Feature IDs: `TEL-METAL-GAUGES`, `UI-TAB-RIG`
- Selected option: process-wide device, command queue, and pipeline resources; surface-local capacity-growing vertex buffers; dirty-state drawing.
- Ownership/lifetime impact: renderers borrow shared immutable resources and dismantle their own buffers and delegates.
- Compatibility impact: gauge structure and displayed telemetry remain unchanged.
- Resource impact: no post-release RSS growth in the release stress profile; Metal allocation delta was 32 KiB.
- Tests: `RigParityTests`, release stress, Metal and Allocations traces, 100-cycle UI navigation.
- Rollback: revert the shared-resource renderer and rerun G04 and G11.

## DEC-0003 — Centralize tool authorization at canonical path boundaries

- Date: 2026-08-23
- Problem: filesystem, Git, and shell tools require a consistent confinement and session-mutation policy.
- Evidence: `.forge-codex/architecture/SECURITY_AND_PRIVACY.md`, `.forge-codex/evidence/P07-mcp-process-conformance.json`
- Constraints: preserve read-only inspection while preventing unbound mutation and symlink escapes.
- Feature IDs: `MCP-TOOL-FILESYSTEM`, `MCP-TOOL-GIT`, `MCP-TOOL-SHELL`
- Selected option: route tool calls through `ToolAuthorizationService`, canonicalize the deepest existing ancestor, protect root deletion/moves, and require an active session for shell and Git mutation.
- Ownership/lifetime impact: authorization state is application-owned and session-scoped.
- Compatibility impact: existing authorized tool contracts remain available.
- Resource impact: no additional long-lived worker or process is introduced.
- Tests: `CoreTests`, `ContinuityTests`, `ProcessRunnerTests`, P12 security scan.
- Rollback: revert authorization integration only with an equivalent confinement control and repeat security validation.

## DEC-0004 — Use a supported native logical-session adapter for rollover

- Date: 2026-08-23
- Problem: external chat creation is not available through a documented repository-owned host API.
- Evidence: `.forge-codex/evidence/P09-host-capability-report.json`
- Constraints: do not use private UI automation or claim unsupported external-host behavior.
- Feature IDs: `DATA-CONTEXT-HANDOFFS`
- Selected option: mode B, `forge.native-session-host`, with an injected `NativeSessionTransport`; mode A remains memory-only handoff ready.
- Ownership/lifetime impact: the bounded ledger owns identifiers, acknowledgements, usage, and rollover state but not transcripts or transport secrets.
- Compatibility impact: existing MCP handoffs remain supported; no undocumented external API is added.
- Resource impact: ledger, response chunks, retries, and cancellation records have explicit bounds.
- Tests: `NativeSessionHostPluginTests`, strict full suite, release plugin build.
- Rollback: disable the native adapter and retain memory-only handoffs.

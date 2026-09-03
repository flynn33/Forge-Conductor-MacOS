# Prioritized Remediation and Qualification Gates

## P0 — Completion truth and continuity authority

- Replace generic hash-based gate acceptance with registered deterministic validators.
- Bind every gate result to project ID/generation, run, validator/version, command/test/artifact, result status, and immutable evidence.
- Remove legacy blocking/global fallback from managed mode.
- Add tests proving unrelated, failed, stale-generation, wrong-run, and model-invented evidence cannot pass a gate.

## P1 — Missing product capabilities

- Build immutable package ingestion and quarantine.
- Build queue records, leases, scheduling, recovery, package tools, and Work Queue UI.
- Build ProjectResetService and mode-specific UI.
- Complete provider, relink, cancel-job, checkpoint, and early-rollover manager actions.

## P2 — Efficiency and retention

- Wire ResourcePressureCoordinator across manager/runtime/autonomy/telemetry/gauges.
- Replace telemetry history shifts/copies with ring buffers and single-source sample cadence.
- Profile and batch/virtualize the Rig’s Metal surfaces.
- Add durable retention/archive policies for provider/tool/run/continuity/audit tables.
- Bound dashboard connections and require auth for sensitive reads.

## P3 — Security and platform qualification

- Implement/qualify E2 atomic capture or formally revise the threat model.
- Implement hardened XPC or remove that promise.
- Add missing provider fixture tests to Xcode.
- Run signed XCUITest, LaunchAgent, Keychain, real LM Studio, crash-recovery, shell, low-memory, and Instruments gates.

## Hard release gates

1. No Critical/High source findings open.
2. Deterministic gate bypass tests pass.
3. Package queue completes two queued packages across manager restart and context rollover without operator action.
4. Real threshold-forced LM Studio rollover: exact ack, one successor, predecessor fenced, auto continuation, GUI closed, crash recovery.
5. Project reset clears only selected data, increments generation, rejects stale work, restores optional backup.
6. Shell defaults enabled and works through signed Settings → manager → MCP after all restart/reset flows.
7. E2 adversarial race matrix passes or release threat model explicitly excludes the actor and UI/docs say so.
8. 8 GiB/16 GiB/large-memory profiles stay within declared CPU/RSS/GPU/disk budgets.
9. Xcode and SwiftPM include the same test source set and pass warnings-as-errors.
10. One signed release attestation binds source, commit/tree, toolchain, and evidence.

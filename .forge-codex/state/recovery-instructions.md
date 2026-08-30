# Recovery instructions

The active preparation branch is `security/privileged-filesystem-boundary`,
based on `main` at `8bcc039a2f0d4d17b871d5e968b3b37a663c5ccb` and published through
draft pull request #15. The exact checkpoint HEAD is recorded only after a
commit, push, fetch, and GitHub readback in `environment.json` and
`release-handoff.md`; verify those records against live Git before resuming.
Also verify the dirty state and `.forge-codex/state/run-state.json`; do not infer
readiness from the package directory alone.

The earlier continuity source checkpoint
`52f8aca47463f88fa94276115fb5c2070ca683ef` on
`repair/autonomous-continuity` is historical supporting evidence. P10 is the
selected phase. G09 and P09 remain release-blocking because that direct-adapter
live-provider run does not satisfy the full manager-owned autonomous-continuity
authority scenario recorded in `FC-AUTONOMOUS-CONTINUITY-E2E-001`.

## Runtime recovery

1. Confirm no stale product or test runner is active with a scoped process check for the Forge Conductor executable, `ForgeConductorUITests-Runner`, `swiftpm-xctest-helper`, `swiftpm-testing-helper`, and `xctrace`.
2. Run `script/build_and_run.sh --verify` from the repository root. Terminate only the exact project-local executable when verification finishes.
3. Run `swift test --no-parallel` and the required Xcode matrix before changing a passed gate.
4. Inspect `.forge-codex/state/events.jsonl` and validate the state chain with `.forge-codex/scripts/statectl.py --repo . validate`.
5. Re-run `.forge-codex/scripts/verify_completion.py --repo . --no-finalize` before relying on completion state.

## Rollback boundaries

- Do not broadly reset or clean the repository. Preserve user-owned work and inspect intended paths before staging.
- The current rollback base is `main` at `8bcc039a2f0d4d17b871d5e968b3b37a663c5ccb`; draft pull request #15 carries the active branch. Read the exact publication HEAD back from GitHub before relying on it. The autonomy baseline `b72d6e8dc00681477224fb1b79859f553bc02558` and bounded-continuation checkpoint `52f8aca47463f88fa94276115fb5c2070ca683ef` are historical reference points, not current authority.
- External profile traces are under `/Users/jimdaley/Documents/RavenForge/Forge-Conductor-MacOS/Forge-Conductor-Repair-Evidence/aba90ab1-be80-4cc5-aa0b-23dd54d4a24d`.
- Developer ID signing, notarization, and distribution remain outside this checkpoint. Repository publication is authorized only for verified checkpoints on the current branch.

## Filesystem transaction recovery

- Protocol v5 stores a fixed 32-slot, root-owned ledger at the protected volume namespace `.forge-conductor-filesystem-v1/transactions/slot-NN`. Do not edit, move, delete, or manually restore any protected slot, receipt, or captured leaf. The legacy same-parent `.forge-quarantine-v1-NN` procedure is not valid for this boundary.
- Preserve the exact transaction ID returned by `fs_delete` or the caller recovery ledger. Use only the additive, pathless `fs_delete_recovery` tool with the original requester, project, generation, and authorized-root context to query or resume it. Acknowledge only a terminal response that explicitly requires acknowledgement and only through that tool.
- A `quarantined` result is durable, terminal, recovery-required, and deliberately nonacknowledgeable while the protected leaf exists. No separately authorized restore, release, or purge operation exists. Preserve the slot and escalate; do not mutate it to regain capacity.
- If the transaction ID is unavailable, a terminal receipt contradicts physical protected-leaf state, startup/per-volume recovery has not fenced new mutations, or the tool returns generic unavailable, do not infer success from pathname absence and do not redispatch the delete. Preserve the state for E2 investigation.
- Capacity exhaustion after 32 retained transactions is a fail-closed condition. It is not authority for manual cleanup. After any supported query, resume, or acknowledgement, rerun `doctor.sh`, `statectl.py validate`, and the exact bounded qualification lane before relying on the result.
- These controls mitigate crash and replay ambiguity. They do not eliminate source-parent relocation, final ACL/BSD-metadata races, caller-ledger tampering, or the other open E2 residuals.

## Environment limits

- Address Sanitizer and Thread Sanitizer both built the instrumented test host but were blocked before product test entry by the installed Xcode 26.2/macOS sanitizer runtime behavior. Do not reinterpret those attempts as passing sanitizer tests.
- The constrained 8 GiB resource policy was executed on an expanded 48 GiB host; it is not physical 8 GiB hardware proof.
- Developer Mode is enabled, and the valid Apple Development identity is James Daley on team `9AQ2C2838M`. The Release project configurations require Developer ID Application on team `2Y25RTLZET`, but no usable Developer ID identity is installed. Existing signed Debug/XCUI evidence is partial; Release signing, installed-service lifecycle, production native UI behavior, notarization, staple, and Gatekeeper remain deferred and release-blocking.
- LM Studio was restored after live qualification: no model is loaded, the local server is stopped, and port 1234 is closed.

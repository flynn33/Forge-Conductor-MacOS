# Recovery instructions

The active preparation branch is `repair/filesystem-race-mitigation`, based on
`main` at `6288210d82270b26add5f0e078d150bc4377bd62`. The final publication HEAD
and pull-request number are **pending** until the checkpoint is committed,
pushed, and read back from GitHub; do not replace those values with an
uncommitted-tree assumption. Before resuming, verify the branch, local and
remote commit, dirty state, and `.forge-codex/state/run-state.json`; do not infer
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
- The current rollback base is `main` at `6288210d82270b26add5f0e078d150bc4377bd62`; the publication HEAD and pull request remain pending until read back after push. The autonomy baseline `b72d6e8dc00681477224fb1b79859f553bc02558` and bounded-continuation checkpoint `52f8aca47463f88fa94276115fb5c2070ca683ef` are historical reference points, not current authority.
- External profile traces are under `/Users/jimdaley/Documents/RavenForge/Forge-Conductor-MacOS/Forge-Conductor-Repair-Evidence/aba90ab1-be80-4cc5-aa0b-23dd54d4a24d`.
- Developer ID signing, notarization, and distribution remain outside this checkpoint. Repository publication is authorized only for verified checkpoints on the current branch.

## Filesystem quarantine recovery

- The active Forge home owns a fixed 32-slot ledger at `filesystem-quarantine/slot-NN.json`; each receipt names a deterministic same-parent `.forge-quarantine-v1-NN` entry. Invalid receipts and unavailable or rebound parents intentionally consume their slot.
- Before changing a receipt or quarantine, stop all Forge processes, read the receipt, and independently verify the recorded parent and leaf identities. Restore only by an exclusive same-parent rename when the original basename is vacant. Never overwrite a current occupant.
- A quarantine that still exists represents an interrupted transition and must not be deleted merely to free capacity. When no quarantine exists, reconciliation clears a receipt only if the exact recorded leaf is restored at the original name and the recorded parent identity remains stable. If both names are absent, the original name has a different identity, either identity check fails, or directory synchronization cannot be confirmed, the receipt remains occupied. A later process generation is not proof that the terminal mutation completed safely.
- Capacity exhaustion is a fail-closed condition before the next source mutation. Recover one verified slot at a time, then rerun `doctor.sh`, `statectl.py validate`, and the exact failed filesystem operation.
- These steps recover cooperating-process crashes. They do not eliminate the open E2 same-UID substitution risk or prove that a moved quarantine parent can be found by its recorded pathname.

## Environment limits

- Address Sanitizer and Thread Sanitizer both built the instrumented test host but were blocked before product test entry by the installed Xcode 26.2/macOS sanitizer runtime behavior. Do not reinterpret those attempts as passing sanitizer tests.
- The constrained 8 GiB resource policy was executed on an expanded 48 GiB host; it is not physical 8 GiB hardware proof.
- Developer Mode is disabled, and the available Mac Development identities use team `9AQ2C2838M` while the project requires `2Y25RTLZET`; native XCUITest remains blocked until both host prerequisites are resolved.
- LM Studio was restored after live qualification: no model is loaded, the local server is stopped, and port 1234 is closed.

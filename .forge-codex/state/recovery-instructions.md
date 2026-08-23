# Recovery instructions

This checkpoint is local and unpublished. Before resuming, verify the branch, commit, dirty state, and `.forge-codex/state/run-state.json`; do not infer readiness from the package directory alone.

## Runtime recovery

1. Confirm no stale product or test runner is active with a scoped process check for the Forge Conductor executable, `ForgeConductorUITests-Runner`, `swiftpm-xctest-helper`, `swiftpm-testing-helper`, and `xctrace`.
2. Run `script/build_and_run.sh --verify` from the repository root. Terminate only the exact project-local executable when verification finishes.
3. Run `swift test --no-parallel` and the required Xcode matrix before changing a passed gate.
4. Inspect `.forge-codex/state/events.jsonl` and validate the state chain with `.forge-codex/scripts/statectl.py --repo . validate`.
5. Re-run `.forge-codex/scripts/verify_completion.py --repo . --no-finalize` before relying on completion state.

## Rollback boundaries

- Do not broadly reset or clean the repository. Preserve user-owned work and inspect intended paths before staging.
- The pre-P12 repair checkpoint is `082404ec42bf2adb775385dea85ad3b20d0076f4` on `repair/forge-conductor-runtime`.
- External profile traces are under `/Users/jimdaley/Documents/RavenForge/Forge-Conductor-MacOS/Forge-Conductor-Repair-Evidence/aba90ab1-be80-4cc5-aa0b-23dd54d4a24d`.
- Developer ID signing, notarization, distribution, pushing, and pull-request creation remain outside this checkpoint.

## Environment limits

- Address Sanitizer and Thread Sanitizer both built the instrumented test host but were blocked before product test entry by the installed Xcode 26.2/macOS sanitizer runtime behavior. Do not reinterpret those attempts as passing sanitizer tests.
- The constrained 8 GiB resource policy was executed on an expanded 48 GiB host; it is not physical 8 GiB hardware proof.

# Recovery instructions

The production source checkpoint `52f8aca47463f88fa94276115fb5c2070ca683ef` is published on `repair/autonomous-continuity`. Before resuming, verify the branch, local and remote commit, dirty state, and `.forge-codex/state/run-state.json`; do not infer readiness from the package directory alone. G09 and P09 are passed; P10 is the selected phase.

## Runtime recovery

1. Confirm no stale product or test runner is active with a scoped process check for the Forge Conductor executable, `ForgeConductorUITests-Runner`, `swiftpm-xctest-helper`, `swiftpm-testing-helper`, and `xctrace`.
2. Run `script/build_and_run.sh --verify` from the repository root. Terminate only the exact project-local executable when verification finishes.
3. Run `swift test --no-parallel` and the required Xcode matrix before changing a passed gate.
4. Inspect `.forge-codex/state/events.jsonl` and validate the state chain with `.forge-codex/scripts/statectl.py --repo . validate`.
5. Re-run `.forge-codex/scripts/verify_completion.py --repo . --no-finalize` before relying on completion state.

## Rollback boundaries

- Do not broadly reset or clean the repository. Preserve user-owned work and inspect intended paths before staging.
- The autonomy baseline is `b72d6e8dc00681477224fb1b79859f553bc02558`; the bounded-continuation source checkpoint is `52f8aca47463f88fa94276115fb5c2070ca683ef` on `repair/autonomous-continuity`.
- External profile traces are under `/Users/jimdaley/Documents/RavenForge/Forge-Conductor-MacOS/Forge-Conductor-Repair-Evidence/aba90ab1-be80-4cc5-aa0b-23dd54d4a24d`.
- Developer ID signing, notarization, and distribution remain outside this checkpoint. Repository publication is authorized only for verified checkpoints on the current branch.

## Environment limits

- Address Sanitizer and Thread Sanitizer both built the instrumented test host but were blocked before product test entry by the installed Xcode 26.2/macOS sanitizer runtime behavior. Do not reinterpret those attempts as passing sanitizer tests.
- The constrained 8 GiB resource policy was executed on an expanded 48 GiB host; it is not physical 8 GiB hardware proof.
- Developer Mode is disabled, and the available Mac Development identities use team `9AQ2C2838M` while the project requires `2Y25RTLZET`; native XCUITest remains blocked until both host prerequisites are resolved.
- LM Studio was restored after live qualification: no model is loaded, the local server is stopped, and port 1234 is closed.

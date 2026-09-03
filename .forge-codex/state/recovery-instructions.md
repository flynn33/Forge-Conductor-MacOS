# Recovery instructions

The active preparation branch is `security/e2-harness-controls`, stacked on
`fix/launchagent-readiness` at
`96d5cfa3dba30df3e3137120b47357a4eaa9d4da` and published through open draft
pull request #19. The H0 source checkpoint is
`399e6a84c4760ddf6c13e02319dc120b4b8998c4`; the release base remains `main`
at `cd7e84fed8ed0fe0a8ec90793e83388c8a451f09`. A later state-only commit can
advance the pull-request transport HEAD without changing the H0 source
checkpoint; record and verify both identities independently in
`environment.json` and `release-handoff.md`. Also verify the dirty state and
`.forge-codex/state/run-state.json`; do not infer readiness from the package
directory alone.

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
- The current rollback base is `main` at `cd7e84fed8ed0fe0a8ec90793e83388c8a451f09`; draft pull request #19 carries the active branch and H0 source checkpoint `399e6a84c4760ddf6c13e02319dc120b4b8998c4`, stacked on #18 and #17. Read the exact publication transport HEAD back from GitHub before relying on it. The autonomy baseline `b72d6e8dc00681477224fb1b79859f553bc02558` and bounded-continuation checkpoint `52f8aca47463f88fa94276115fb5c2070ca683ef` are historical reference points, not current authority.
- External profile traces are under `/Users/jimdaley/Documents/RavenForge/Forge-Conductor-MacOS/Forge-Conductor-Repair-Evidence/aba90ab1-be80-4cc5-aa0b-23dd54d4a24d`.
- Developer ID signing, notarization, and distribution remain outside this checkpoint. Repository publication is authorized only for verified checkpoints on the current branch.

## Filesystem transaction recovery

- Protocol v5 stores a fixed 32-slot, root-owned ledger at the protected volume namespace `.forge-conductor-filesystem-v1/transactions/slot-NN`. Do not edit, move, delete, or manually restore any protected slot, receipt, or captured leaf. The legacy same-parent `.forge-quarantine-v1-NN` procedure is not valid for this boundary.
- Preserve the exact transaction ID returned by `fs_delete` or the caller recovery ledger. Use only the additive, pathless `fs_delete_recovery` tool with the original requester, project, generation, and authorized-root context to query or resume it. Acknowledge only a terminal response that explicitly requires acknowledgement and only through that tool.
- A `quarantined` result is durable, terminal, recovery-required, and deliberately nonacknowledgeable while the protected leaf exists. No separately authorized restore, release, or purge operation exists. Preserve the slot and escalate; do not mutate it to regain capacity.
- If the transaction ID is unavailable, a terminal receipt contradicts physical protected-leaf state, startup/per-volume recovery has not fenced new mutations, or the tool returns generic unavailable, do not infer success from pathname absence and do not redispatch the delete. Preserve the state for E2 investigation.
- Capacity exhaustion after 32 retained transactions is a fail-closed condition. It is not authority for manual cleanup. After any supported query, resume, or acknowledgement, rerun `doctor.sh`, `statectl.py validate`, and the exact bounded qualification lane before relying on the result.
- These controls mitigate crash and replay ambiguity. They do not eliminate
  source-parent relocation, final ACL/BSD-metadata races, caller-ledger
  tampering, or the other open E2 residuals. Source-parent authorization and
  capture are not atomic: one winning same-UID relocation can delete one
  eligible outside-root regular file or symlink whose bytes are unbounded, or
  quarantine one ineligible directory whose subtree is unbounded. The final
  ACL/BSD-metadata-check-to-unlinkat race can delete one already captured
  expected regular file or symlink after its authorization metadata changes;
  regular-file bytes are unbounded. Caller-ledger removal, relocation, or
  lock-inode replacement and generation races can strand or allow up to 32
  captured or terminal transactions per protected volume, with unbounded bytes
  in each affected regular file. Writable descriptors and hard links prevent an
  exact immutable-content guarantee.

## Evidence-control recovery boundary

- H0 recorder evidence `EVID-20260831T060522Z-03c32cb838` binds the source
  checkpoint, source manifest, signed distinct harness and adversary identities,
  local-APFS precondition, live CodeDirectory hashes, and the exact four-command
  inventory. It performed no production mutation and cannot satisfy semantic E2
  qualification. All 57 rows remain `not_run`, all 12 formal predicates remain
  false, and every completion claim remains false. Inode/change-time replacement
  detection is mitigation under the recorded local-APFS precondition, not
  elimination of same-UID interference.
- Source checkpoint `2dd504e53a5a09837cd289a99eee48ab7f4547eb`
  adds semantic artifact binding and passed 57 of 57 evidence-control tests.
  This is control evidence only. It does not execute any signed distinct-process
  qualification case or prove a formal predicate.
- The checked-in template deliberately has all 57 rows `not_run`, all 12 formal
  predicates false, zero formal references, and a null qualification-context
  reference. Do not edit those values to recover or advance a gate.
- Qualification assumes a trusted quiescent workspace against same-UID
  transient source-manifest replacement. An arbitrary caller-selected harness
  is not authenticated. Aggregate report and evidence input reads remain
  unbounded fail-closed denial-of-service surfaces. The G10 handler does not yet
  invoke the checker. Post-verification mutation is outside immutable-content
  proof.
- Resume P10 by executing the full signed distinct-process 57-row matrix and
  addressing the remaining filesystem residuals. E2, P10, G10, G12, G09
  continuity, G11 hardware, native signing/UI, shell qualification, and final
  release qualification remain open and release-blocking.

## Environment limits

- Address Sanitizer and Thread Sanitizer both built the instrumented test host but were blocked before product test entry by the installed Xcode 26.2/macOS sanitizer runtime behavior. Do not reinterpret those attempts as passing sanitizer tests.
- The constrained 8 GiB resource policy was executed on an expanded 48 GiB host; it is not physical 8 GiB hardware proof.
- Developer Mode is enabled, and the valid Apple Development identity is James Daley on team `9AQ2C2838M`. The Release project configurations require Developer ID Application on team `2Y25RTLZET`, but no usable Developer ID identity is installed. Existing signed Debug/XCUI evidence is partial; Release signing, installed-service lifecycle, production native UI behavior, notarization, staple, and Gatekeeper remain deferred and release-blocking.
- LM Studio was restored after live qualification: no model is loaded, the local server is stopped, and port 1234 is closed.

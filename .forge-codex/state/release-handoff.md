# Forge Conductor checkpoint and historical release handoff

## Current checkpoint status — not release-qualified

The active repair line is still in P10. No current claim is made that P10, the
filesystem E2 finding, shell compatibility, native UI validation, autonomous
continuity, or final release qualification is complete. Earlier green suites and
the historical G09 result remain exact-revision evidence only; they do not confer
release authority on the current source tree.

Current release blockers are:

- **Filesystem mutation E2 remains open.** Descriptor-relative traversal and
  bounded quarantine-and-verify mitigate final-component substitution but do not
  eliminate the race. The mitigation uses a global 32-slot, owner-only receipt
  ledger with deterministic same-parent quarantine names; corrupt receipts,
  unavailable or rebound parents, failed rollback, and durability-unconfirmed
  transitions retain a slot for recovery. Rollback refuses to restore a
  quarantine occupant whose identity differs from the receipt. A receipt that
  remains live when a committed publication is both namespace-unstable and
  durability-unconfirmed is returned as required ledger recovery; any additional
  retained staging-cleanup receipt is merged into that result. A receipt that
  is already absent after unlink is not falsely reported as a live recovery
  path even when the following ledger-directory sync fails; a stale receipt may
  conservatively reappear and occupy its bounded slot after a crash. A
  same-user writer can still win
  between final verification and the terminal mutation. A winning race can
  affect one entry under the pinned authorized parent; deleting a final hard
  link can lose an unbounded number of bytes, and renaming a directory can
  relocate an unbounded subtree. A recursive request can reuse released slots
  across up to 100,000 planned entries, so 32 bounds simultaneous cooperative
  recovery state rather than cumulative adversarial wrong-object mutations.
  Initial path anchoring, destination hierarchy
  creation, and hard-link ctime ambiguity also remain E2.
- **Shell compatibility remains open.** The selected P10 work preserves
  `shell_exec` as the synchronous `/bin/bash -lc` compatibility surface and adds
  clean-profile `bash.run` as a separate durable runtime tool. Non-native restart
  coverage is limited to manager-service restart and `ForgeApp`
  teardown/rebootstrap. The native Settings test includes app relaunch, but it
  has not executed; source and non-native regressions do not replace required
  native Settings execution.
- **Native UI validation remains deferred and release-blocking.** The Settings
  XCUITest target has build-only evidence. Developer Mode is disabled and the
  available signing identity does not match the configured team, so no native
  execution pass is claimed.
- **Autonomous continuity remains open and release-blocking.** The earlier live
  LM Studio run exercised a directly invoked adapter. It did not prove a
  manager-owned, threshold-forced real-provider rollover with exact successor
  acknowledgment, predecessor fencing and idempotent sealing, automatic
  continuation, GUI-closed operation, and recovery from every durable crash
  state as one scenario. Unit and synthetic-host tests are supporting evidence
  only.

G09 is therefore historical exact-revision evidence rather than current release
authority. G10, G11, and G12 remain nonpassing. A partial security pull request
may be reviewed only with these residual risks and deferred gates visible in its
description, the state ledger, doctor output, and next-work selection.

Current-source evidence on manifest
`bc7b2f66d381d8fa4cd51b9e4da78b8c8486572385e05425c07d94922e8c3106`
includes Debug `EVID-20260828T124332Z-1e2a050c0e` and Release
`EVID-20260828T124624Z-00a3dd27c2`, each with 657 tests, four expected skips,
and zero failures. CLI `EVID-20260828T125021Z-6c31192210`, MCP
`EVID-20260828T125651Z-ad5ebff94c`, and manager HTTP
`EVID-20260828T125046Z-c15d53c9c9` compatibility pass. The Settings target
builds unsigned in `EVID-20260828T124634Z-c6c0c861da`; zero native tests ran.
Final publication controls pass in evidence-controls
`EVID-20260828T130418Z-5574c5b7d8`, state validation
`EVID-20260828T130424Z-8504424e70`, attribution scan
`EVID-20260828T130424Z-7eb8ebf490`, secret scan
`EVID-20260828T130425Z-686a1e57bc`, and package validation
`EVID-20260828T130426Z-9f1dba3882`. Doctor
`EVID-20260828T130522Z-a830cc844e` and next-work selection
`EVID-20260828T130522Z-9f6e40e665` keep all four deferred findings visible,
keep G09-G12 nonpassing, and continue to select P10. The intentionally
nonpassing P10 boundary `EVID-20260828T130522Z-849134968b` and completion
boundary `EVID-20260828T130523Z-73516c6e94` prevent this checkpoint from being
misread as phase or release completion. Current G09 acceptance validation
`EVID-20260828T130426Z-af339f479f` also fails because the historical direct
adapter result is not manager-owned forced-rollover authority.

## Published checkpoint identity

- Active branch: `repair/filesystem-race-mitigation`
- Published source checkpoint HEAD: `f721ce063104817e9f08013350ab855bac708c77`
- Base branch and SHA: `main` at
  `6288210d82270b26add5f0e078d150bc4377bd62`
- Current pull request: #12,
  `https://github.com/flynn33/Forge-Conductor-MacOS/pull/12`
- GitHub readback at publication recorded PR #12 as open from
  `repair/filesystem-race-mitigation@f721ce063104817e9f08013350ab855bac708c77`
  into `main@6288210d82270b26add5f0e078d150bc4377bd62`.
- Pull request #9 (`repair/autonomous-continuity` at
  `6321bd98012e5f60b2779bbb401cc2827f372b16`) was based on
  `ae0ceace702274857afce3097ac7cde18b7a6c63` and closed without merge.
- Pull request #10 (`repair/cancellation-recovery` at
  `4b887fcc423284d0a60f57baed3adab4b943a576`) used the same base, superseded
  #9 with the same resulting tree, and was squash-merged as
  `7808790d9f52f4ec287434d45826bfa0e5586892`.
- Pull request #11 (`repair/filesystem-path-hardening` at
  `92122970c54cf549cdc5002db23044ed0b3552cb`) was based directly on the #10
  merge and was squash-merged as
  `6288210d82270b26add5f0e078d150bc4377bd62`, the current base.
- Pull request #12 is the current partial P10 mitigation checkpoint. It follows
  #11 and does not close P10, E2, shell compatibility, native validation,
  autonomous continuity, or G09-G12.

## Historical 0.9.0 outcome

The autonomous repair phases P00-P12 were merged to `main` by pull request #6. The pre-P12 repair checkpoint is `082404ec42bf2adb775385dea85ad3b20d0076f4`; final P12 evidence and security remediation are included in that merged release checkpoint. Version and release-document alignment for 0.9.0 is prepared on `release/0.9.0-alignment` in pull request #7.

Everything below this point describes that historical checkpoint. It must not be
read as qualification of the current P10 source tree.

## Historical release alignment

- The runtime version and all six Xcode marketing-version settings are `0.9.0`.
- README, changelog, user guide, architecture, telemetry, continuity, and current G1-G10 status documents agree on the release version and behavior.
- A focused G3 acceptance test prevents drift between the runtime, Xcode project, and current release documents.
- The focused test, CLI version check, Xcode project parse, plist validation, package validation, publication-hygiene scan, secret scan, and whitespace check passed.

## Historical qualification

- Pre-remediation matrix: 266 Swift Debug tests, 266 Swift Release tests, 266 Xcode unit/integration tests, and 5 native UI tests passed with two intentional environment skips and no failures. The 100-cycle navigation test passed.
- Post-security matrix: 269 Swift tests, 269 strict-concurrency tests, and 269 Xcode unit tests passed with two intentional environment skips and no failures.
- Xcode Release signing-independent and local ad-hoc builds passed.
- Release stress covered 500 memory records, 100 projects, 100 concurrent MCP calls, 25 process cycles, 25 rollovers, and 100 UI navigation cycles.
- Profile results show zero CPU/Metal hangs or risk flags, zero post-release RSS slope, and a 32 KiB Metal allocation delta.
- The final security scan found two High, three Medium, and one Low issue in the tested checkpoint. Both High issues and two MCP resource issues were remediated and retested. One Medium local-dashboard authentication item and one Low incomplete-connection item remain explicitly tracked; unresolved Critical/High count is zero.

## Historical environment boundaries

- Address and Thread Sanitizer test hosts built but were blocked before product test entry by the installed Xcode 26.2/macOS sanitizer runtime behavior. No sanitizer test pass is claimed.
- The 8 GiB resource policy was exercised on a 48 GiB host; this is constrained-policy evidence, not physical 8 GiB hardware evidence.
- Developer ID signing, notarization, and distribution were not performed.
- Pull request #6 was merged to `main`; pull request #7 is open for the 0.9.0 alignment.
- No Simulator was started. Every launched app, UI runner, profiler, and test host was terminated and checked after use.

## Historical evidence and recovery

These are the repository paths named by the historical handoff. Mutable reports
at those paths may now describe the active run; use the exact-revision,
hash-bound gate artifacts when reconstructing historical authority.

- Completion report: `.forge-codex/state/completion-report.json`
- Evidence index: `.forge-codex/state/evidence-index.json`
- Final validation: `.forge-codex/evidence/P12-final-validation-report.json`
- Security summary: `.forge-codex/evidence/P12-security-scan-summary.json`
- Decisions: `.forge-codex/state/decisions.md`
- Migration: `.forge-codex/evidence/P10-migration-report.json`
- Recovery: `.forge-codex/state/recovery-instructions.md`
- External profiles: `/Users/jimdaley/Documents/RavenForge/Forge-Conductor-MacOS/Forge-Conductor-Repair-Evidence/aba90ab1-be80-4cc5-aa0b-23dd54d4a24d`

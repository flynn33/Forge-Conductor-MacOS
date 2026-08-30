# Forge Conductor checkpoint and historical release handoff

## Current checkpoint status — not release-qualified

The active repair line is `security/privileged-filesystem-boundary`, based on
`main` at `8bcc039a2f0d4d17b871d5e968b3b37a663c5ccb` (the pull request #14
squash merge). This working checkpoint is not yet published and has no pull
request number. No current claim is made that P10, the filesystem E2 finding,
shell compatibility, native UI validation, autonomous continuity, representative
hardware qualification, or final release qualification is complete. Earlier
green suites remain exact-revision evidence only and do not confer release
authority on this source tree.

Current release blockers are:

- **Filesystem mutation E2 remains open.** The canonical finding is
  `FC-FILESYSTEM-PATH-TOCTOU-001`; the approved policy alias is `FCA-007`.
  The selected partial implementation adds a separately signed root
  LaunchDaemon, an enumerated designated-requirement NSXPC connection boundary,
  a root-owned
  mode-0700 same-volume namespace, bounded project bindings and transaction
  slots, descriptor-relative exclusive capture, post-capture identity
  verification, durable phases, and fail-closed production routing with no
  same-UID fallback. Each accepted connection is bound to its non-root effective
  UID; the binding and transaction persist that UID, requester-owned ACL-free
  traversal and an owner-writable final parent are required, and ACL-protected
  or immutable/append/restricted/no-unlink leaves are rejected before and after
  capture. This is mitigation, not elimination. A same-UID attacker
  can still substitute the source immediately before exclusive capture. One
  substituted entry can become temporarily or recovery-required unavailable;
  if it is a directory, that one entry can represent an unbounded subtree.
  Writable descriptors and hard links also prevent an immutable-content
  guarantee. They also leave an authorization-metadata race between the final
  protected-leaf ACL/flag check and root `unlinkat`; at most the one captured
  expected non-directory leaf can be deleted after its permission metadata
  changes, and a regular file can contain unbounded bytes. The current NSXPC implementation checks identity at the connection
  boundary, not against the audit token of every received message. Project
  binding authority is not yet composed with an independently verified manager
  authorization record. Bindings also have no manager-authorized revoke or
  garbage-collection lifecycle; after 256 distinct lifetime project bindings,
  another project is denied until that residual is implemented and qualified.
  Ambiguous submitted calls preserve their original
  transaction ID, but `fs_delete` cannot yet consume that ID to resume after
  pathname loss. Signed hostile-process, crash, volume, lifecycle,
  source-leaf, hard-link, writable-FD, and per-message identity evidence remain
  absent. Directory deletion and move remain disabled in the production route.
  E2, P10, G10, and G12 stay open.
- **Caller-sealed helper identity and non-GUI packaging are open.**
  `FC-PRIVILEGED-CALLER-IDENTITY-001` records two fail-closed availability
  defects and one identity residual. The normal login-manager install currently
  synthesizes an ad-hoc app without the LaunchDaemon plist or helper. A raw
  installed or standalone CLI also evaluates `SMAppService` and `Bundle.main`
  relative to a process that does not contain those artifacts, so it can return
  `not_found` before authenticated XPC. The current SHA-256 handshake hashes
  mutable filesystem paths and is self-reported by the daemon; it is not a
  kernel-attested identity for the mapped root process. An older
  same-team/same-identifier/same-version daemon can therefore remain admissible
  if the user-writable expected helper path is rolled back to matching bytes.
  The maximum possible impact is that older daemon's full bounded root mutation
  authority and any vulnerabilities it contains. The next implementation must
  bind the allowed per-architecture helper CodeDirectory hashes into each main
  caller's signed mapped code or kernel-attested entitlement, compose those
  hashes into the NSXPC peer requirement, package one verified app/helper/plist
  relationship for the app, installed manager, and standalone CLI, and run all
  three as signed processes. Code signing alone has no freshness property;
  preventing rollback of the entire validly signed product still requires a
  monotonic root-owned receipt. This is mitigation, not elimination.
- **Privileged service update lifecycle is still qualifying.**
  `FC-PRIVILEGED-SERVICE-LIFECYCLE-001` tracks the explicit asynchronous
  unregister/re-register replacement flow and the same-connection
  protocol, product-version, daemon-identifier, root-UID, and running-helper
  path-SHA-256 handshake against the current GUI bundle. These changes fail
  closed against an incompatible stale daemon, but they are not exact live-code
  identity and do not yet work from the installed manager or standalone CLI.
  Focused source tests prove lifecycle ordering and fencing, but do not yet drive
  the asynchronous XPC transport state machine itself. Signed Debug and
  notarized Release upgrade, approval, denial, relocation, crash, and restart
  evidence remains absent.
- **Clean-install project-root onboarding is validating.**
  `FC-PROJECT-ROOT-SETTINGS-001` now has native persisted add/remove controls,
  canonicalization, root rejection, accessibility identifiers, 39 focused
  strict source passes, and signed Debug XCUI evidence
  `EVID-20260830T134146Z-a2848e6490`. That record passed all six selected
  Settings/relaunch cases, including bounded add/remove and root rejection. The
  XCUI path used a deterministic test-only folder-selection hook rather than
  automating the system-owned `NSOpenPanel`; production-panel observation and
  the broader native gate remain open. Authorization remains fail closed and
  does not restore implicit Forge-home or filesystem-root authority.
- **Shell compatibility remains open.** The selected P10 work preserves
  `shell_exec` as the synchronous `/bin/bash -lc` compatibility surface and adds
  clean-profile `bash.run` as a separate durable runtime tool. Non-native restart
  coverage is limited to manager-service restart and `ForgeApp`
  teardown/rebootstrap. Signed Debug XCUI
  `EVID-20260830T134146Z-a2848e6490` proves shell Settings visibility, control,
  persistence, and GUI relaunch. It does not prove a successful native
  `shell_exec` after both app restart and an actual manager-process restart as
  one qualification scenario, so shell qualification remains open.
- **Native UI validation remains deferred and release-blocking.** Developer
  Mode is enabled and the valid Apple Development James Daley identity for team
  `9AQ2C2838M` is available. The six bounded signed Debug cases in
  `EVID-20260830T134146Z-a2848e6490` cover root controls, shell controls,
  protected-service control visibility, and GUI relaunch. A separate normal
  signed Debug build and nested-bundle inspection passed as
  `EVID-20260830T134353Z-1b0e67f46b` and
  `EVID-20260830T134413Z-3e92a26ea0`. These records do not cover the production
  panel, successful shell execution across app and manager-process restart,
  actual service approval/update/disable behavior, installed-manager identity,
  exact running-helper identity, Release signing, or notarization.
- **Autonomous continuity remains open and release-blocking.** The earlier live
  LM Studio run exercised a directly invoked adapter. It did not prove a
  manager-owned, threshold-forced real-provider rollover with exact successor
  acknowledgment, predecessor fencing and idempotent sealing, automatic
  continuation, GUI-closed operation, and recovery from every durable crash
  state as one scenario. Unit and synthetic-host tests are supporting evidence
  only.
- **Representative hardware qualification remains owner-deferred and
  release-blocking.** Current-host and synthetic/simulator evidence may be
  collected, but it does not pass G11 or authorize shipment on the representative
  physical hardware matrix.

The checkpoint also resolves the project-bootstrap and Forge control-state
authorization bypasses without broadening default authority. Their focused
denial/permitted tests, independent source review, signed root-control UI
support, and the current-source strict suite passed. Those two issue closures do
not pass P10, E2, shell compatibility, native validation, or any release gate.

G09 is therefore historical exact-revision evidence rather than current release
authority. G09, G10, G11, and G12 remain nonpassing. A partial security pull request
may be reviewed only with these residual risks and deferred gates visible in its
description, the state ledger, doctor output, and next-work selection.

The current source manifest is
`8935956c67e00f63c9ad5f4e35d5f481c27d3a2d4bee97640f16d2550fa2a100`
over 250 source-controlled inputs. Focused privileged/lifecycle evidence
`EVID-20260830T133142Z-14f01b19ff` passed 24 tests. Signed Debug UI evidence
`EVID-20260830T134146Z-a2848e6490` passed six bounded cases; normal signed
Debug build and bundle inspection evidence are
`EVID-20260830T134353Z-1b0e67f46b` and
`EVID-20260830T134413Z-3e92a26ea0`. Full strict evidence
`EVID-20260830T134451Z-b1aa8b64c6` passed 689 tests with two declared
environment skips and no failures. Latest doctor evidence
`EVID-20260830T135159Z-ef01c9a862` remained fail closed. The next-work record
`EVID-20260830T135021Z-2d1453403d` selects P10 and reports
`release_authorized=false`; expected-negative completion evidence
`EVID-20260830T135034Z-b9664b7a9f` exits nonzero because the privileged matrix,
fresh compatibility reports, and native qualification are incomplete. Earlier
P10, CLI, MCP, manager, UI-build, and app-smoke records belong to their recorded
source manifests. They may be used as regression baselines but are not evidence
for the privileged boundary. Doctor and the next-work selector must continue to
emit `release_authorized=false`, all open mandatory findings, and the
nonpassing G09-G12 gates.

## Current branch and pull-request lineage

- Active branch: `security/privileged-filesystem-boundary`.
- Current committed HEAD and base SHA before this unpublished slice:
  `8bcc039a2f0d4d17b871d5e968b3b37a663c5ccb`.
- Base branch: `main`.
- Current pull request: none until the partial-security checkpoint is committed
  and published. The PR description and GitHub readback must record its exact
  final head SHA and current `main` base SHA before review.
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
  `6288210d82270b26add5f0e078d150bc4377bd62`.
- Pull request #14 was squash-merged into `main` as
  `8bcc039a2f0d4d17b871d5e968b3b37a663c5ccb` and is the base of this work.
  It does not close P10, E2, shell compatibility, native validation,
  autonomous continuity, representative hardware qualification, or G09-G12.

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

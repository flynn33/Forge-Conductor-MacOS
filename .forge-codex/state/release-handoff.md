# Forge Conductor checkpoint and historical release handoff

## Current checkpoint status — not release-qualified

The active repair line is `security/privileged-filesystem-boundary`, based on
`main` at `8bcc039a2f0d4d17b871d5e968b3b37a663c5ccb` (the pull request #14
squash merge). The current implementation and evidence checkpoint is
`ad6e21eeced9c18014157800478ef45e75963782`. A later state-only handoff or
doctor commit may advance the pull request transport HEAD without changing that
manifest-bound source checkpoint. It is being published in draft pull request
#15. No current claim is made that P10, the filesystem E2 finding,
shell compatibility, native UI validation, autonomous continuity,
representative hardware qualification, or final release qualification is
complete. Earlier green suites remain exact-revision evidence only and do not
confer release authority on this source tree.

Current release blockers are:

- **Filesystem mutation E2 remains open.** The canonical finding is
  `FC-FILESYSTEM-PATH-TOCTOU-001`; the approved policy alias is `FCA-007`.
  The selected partial implementation adds a separately signed root
  LaunchDaemon, a root-owned mode-0700 same-volume namespace, 32 durable
  transaction slots, bounded project bindings, descriptor-relative exclusive
  capture, post-capture identity verification, durable phases, retained
  rollback recovery, and fail-closed production routing with no same-UID
  fallback. Accepted messages
  must satisfy the NSXPC signing requirement, and each transaction persists the
  non-root requester UID. Requester-owned ACL-free traversal, an owner-writable
  final parent, a supported leaf type, and pre- and post-capture ACL/BSD-flag
  checks are required. This is mitigation, not elimination.

  The macOS filesystem APIs were evaluated explicitly. Descriptor-relative
  `openat` with `O_NOFOLLOW_ANY`/`O_RESOLVE_BENEATH`, `fstat`, `fstatat`,
  `lstat`, and `openat_authenticated_np` can constrain traversal or observe an
  identity, but they do not mutate a namespace. `renameat` and
  `renameatx_np(RENAME_EXCL)` operate relative to pinned parents, and the latter
  atomically refuses destination replacement, but neither requires the source
  to match a previously observed vnode. `renameatx_np(RENAME_SWAP)` is the
  atomic adversarial substitution primitive, not an identity guard. `unlinkat`
  removes the current name relative to a pinned directory and has no
  expected-device/inode/generation predicate. Open descriptors, `fcntl`,
  `fsync`, and `F_FULLFSYNC` support inspection and durability, not selection of
  the identity consumed by the later namespace syscall. Public macOS APIs
  therefore do not provide the required identity-conditional terminal mutation.

  A same-UID attacker can still substitute the source immediately before
  exclusive capture. One substituted entry can become temporarily or
  recovery-required unavailable; if it is a directory, that entry can represent
  an unbounded subtree. A separate authorization-metadata race remains between
  the final ACL/BSD-flag check and root `unlinkat`: at most the one already
  captured expected regular file or symbolic link can be deleted after its
  metadata changes, and a regular file can contain unbounded bytes. Writable
  descriptors and hard links prevent an immutable-content guarantee. The
  daemon does not automatically restore a captured leaf through a recorded or
  reopened parent descriptor because that directory can be relocated after
  validation. It durably retains the captured leaf for recovery instead. This
  prevents the identified root restore outside the authorized root, but the
  maximum availability impact is one retained leaf per affected transaction,
  up to the 32 protected slots per volume. The
  source-level adversarial swap, namespace-instability, durability, retained
  receipt, hard-link, and writable-descriptor regressions are supporting
  evidence. The full signed distinct-process atomic-swap,
  crash-at-every-durable-phase and recovery, volume, wrong-signature,
  hard-link, and writable-descriptor matrices have not run.

  Initial project bindings are not yet composed with an independently verified
  manager authorization record. Bindings also have no manager-authorized revoke
  or garbage-collection lifecycle; after 256 distinct lifetime project
  bindings, another project fails closed. Protocol v4 now preserves the exact
  transaction ID across post-intent and existing-transaction failures, retains
  terminal committed/restored/rejected outcomes until durable exact
  acknowledgement, and adds pathless `fs_delete_recovery` query, resume, and
  acknowledge actions backed by a bounded caller ledger. Interrupted managed
  recovery calls remain conservatively blocked when their prior result cannot
  be reconciled. Broker replay also refuses to infer completion from pathname
  absence after a previously existing protected leaf was dispatched, so an
  unresolved privileged transaction cannot be converted into synthetic success
  or redispatched. No automatic post-broker acknowledgement/discovery pass is
  implemented. The sole caller recovery handle remains below a same-UID-owned
  application directory: another same-UID process can rename or remove it
  without forging daemon authority. Per protected volume, up to 32 such losses
  can strand captured entries or terminal outcomes from normal query/resume/ack
  reachability and then make later protected mutations fail closed on capacity.
  Generation reset now holds the caller-ledger lock while checking before and
  after entering the resetting state and through generation advance. It rejects
  visible old-generation authority, cancels back to active, and surfaces a
  distinct cleanup error if cancellation itself fails. Delete retention
  revalidates current project authority inside that same ledger lock, so a
  normal request delayed behind reset cannot publish its caller record or reach
  XPC with the stale generation. A same-UID process can still remove or relocate
  an already-retained caller record before reset, hide the only handle while its
  daemon transaction remains, and let generation advance while old authority
  can still complete. It can also unlink or replace the ledger lock after a
  retainer validates but before slot publication, allowing reset to acquire a
  replacement lock and advance while the stale retainer later dispatches.
  Without daemon-owned discovery or generation revoke, the
  maximum post-reset impact is up to 32 captured or terminally deleted expected
  leaves per protected volume; each regular file can contain unbounded bytes.
  This mitigation does not eliminate the hostile authorization/recovery race.
  Directory deletion, move, and cross-volume mutation remain disabled in the
  privileged production route. E2, P10, G10, and G12 stay open.
- **Caller-sealed helper identity and packaging remain qualifying.** Protocol v4
  reads the running caller's validated sealed per-architecture daemon
  CodeDirectory hashes, conjoins the exact hash with the daemon designated
  requirement before XPC activation, and repeats protocol version, product
  version, daemon identifier, root effective UID, and running daemon hash on the
  same connection before serialized mutation dispatch. A mismatch, timeout, or
  late reply before submission cannot dispatch; a lost reply after submission
  preserves the original transaction ID. Static bundle checks are valid only
  while the checked object remains unmodified.

  The canonical app build produces one app/embedded-CLI/daemon artifact set;
  the app and CLI seal the same daemon hashes. App-origin manager installation
  validates the exact app main and embedded CLI, stages only the embedded CLI
  plus its adjacent signed framework, and rejects incomplete, symlinked, or
  mismatched payloads before mutation. The implementation and bundle checks do
  not replace signed process evidence. App, installed manager, raw CLI, and
  standalone CLI service execution; hostile caller, stale helper, wrong team,
  wrong identifier, upgrade, and restart cases remain unexecuted.

  Code signing has no freshness property. Whole-product rollback can restore an
  older otherwise allowlisted caller, expectation, and daemon; the maximum
  impact is that older daemon's full bounded root mutation authority and any
  vulnerabilities it contains. A monotonic root-owned receipt is absent. This
  is mitigation, not elimination.
- **Privileged service update lifecycle is still qualifying.**
  `FC-PRIVILEGED-SERVICE-LIFECYCLE-001` tracks the explicit asynchronous
  unregister/re-register replacement flow, generation fencing, exact live-code
  requirement, and protocol-v4 handshake. Source tests cover mismatch, timeout,
  late reply, single dispatch, lost mutation reply, retained transaction
  identity, pathless query/resume/acknowledgement, reinstall ordering, and a
  concurrent Disable superseding reinstall. They do not exercise those paths
  through the real signed asynchronous XPC service. Actual `SMAppService`
  approval, denial, update, disable, unregister/re-register, daemon restart,
  transaction recovery, signed Debug lifecycle, Release signing, and notarized
  Release lifecycle evidence remains absent.
- **Clean-install project-root onboarding is validating.**
  `FC-PROJECT-ROOT-SETTINGS-001` now has native persisted add/remove controls,
  canonicalization, root rejection, accessibility identifiers, strict source
  coverage, and signed Debug XCUI evidence
  `EVID-20260830T153118Z-752f058222`. That record passed all six selected
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
  `EVID-20260830T153118Z-752f058222` proves shell Settings visibility, control,
  persistence, and GUI relaunch. Source regressions additionally prove clean
  default enablement, accidental legacy-disabled migration, preservation of an
  explicit opt-out, MCP `tools/list` registration, successful execution, the
  established synchronous result contract, app rebootstrap, and manager-service
  restart. They do not prove a successful signed native
  `shell_exec` after both app restart and an actual manager-process restart as
  one qualification scenario. A guarded installed-artifact harness now validates
  the ordinary signed app and exact staged identities, refuses pre-existing
  manager state, preserves the established contract, and restores the canonical
  LaunchAgent, disabled-state entry, and command link after a run. Its 14 focused
  regressions pass as `EVID-20260830T185902Z-ce0de2b7cb`. The live run
  `EVID-20260830T185444Z-7878ff2abf` did not qualify shell access: macOS denied
  `launchctl bootstrap` to the current automation-host process tree, the legacy
  `launchctl load` fallback returned without a running manager job, and the
  harness failed closed before any `shell_exec` claim. Cleanup proved the
  canonical manager job and plist absent and restored the prior command link and
  launchd disabled-state entry. A foreground Terminal run outside this host
  restriction is still required, and the install path's false-success fallback
  remains an explicit product residual. Shell qualification stays open and
  release-blocking.
- **Native UI validation remains deferred and release-blocking.** Developer
  Mode is enabled and the valid Apple Development James Daley identity for team
  `9AQ2C2838M` is available. The six bounded signed Debug cases in
  `EVID-20260830T153118Z-752f058222` cover root controls, shell controls,
  protected-service control visibility, and GUI relaunch. A current-source
  normal signed Debug build and paired app/daemon/CLI inspection passed as
  `EVID-20260830T184940Z-e93d7373f7` and
  `EVID-20260830T185004Z-e546c8ccf3`. These records do not cover the production
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
`62361115e3af17e340f56c656b2731bd720e98b3cddceb7d848a040cb6e0a21c`
over 252 inputs. Debug strict evidence
`EVID-20260830T184228Z-1bb02068b2` and Release strict evidence
`EVID-20260830T184522Z-d43b1586b6` each passed 755 tests with two declared
environment skips and no failures. Signed Debug build evidence is
`EVID-20260830T184940Z-e93d7373f7`; the exact paired app/daemon/CLI check is
`EVID-20260830T185004Z-e546c8ccf3`. Signed Debug UI evidence
`EVID-20260830T153118Z-752f058222` passed all six bounded cases.

Post-implementation-push doctor evidence
`EVID-20260830T153545Z-5b607da24f` verifies branch and remote at the
implementation checkpoint, the base, and draft PR #15; it reports the partial
checkpoint reviewable while retaining `merge_authorized=false` and
`release_authorized=false`. The corresponding next-work record
`EVID-20260830T153546Z-2cd9cd91c7` selects P10 with the same policy. State
validation `EVID-20260830T153736Z-e4c023a103`, package validation
`EVID-20260830T154516Z-2aec49083f`, and attribution scan
`EVID-20260830T154511Z-2c25f0686e` pass. The earlier failed strict record
`EVID-20260830T151425Z-09e2526950` is retained as a superseded negative
baseline, not pass evidence. Doctor and the next-work selector must continue to
emit `release_authorized=false`, all open mandatory findings, and the
nonpassing G09-G12 gates.

## Current branch and pull-request lineage

- Active branch: `security/privileged-filesystem-boundary`.
- Implementation and evidence checkpoint:
  `ad6e21eeced9c18014157800478ef45e75963782`.
- A later commit containing only handoff, doctor, selector, or publication
  readback does not change that manifest-bound checkpoint; the pull request
  readback is authoritative for its transport HEAD.
- Base branch and SHA: `main` at
  `8bcc039a2f0d4d17b871d5e968b3b37a663c5ccb`.
- Current pull request: draft #15,
  `https://github.com/flynn33/Forge-Conductor-MacOS/pull/15`.
- The last pre-publication GitHub readback recorded #15 open and draft from
  `security/privileged-filesystem-boundary@3c0b0af0969af8161582285dd53d98a779b2cf5b`
  into `main@8bcc039a2f0d4d17b871d5e968b3b37a663c5ccb`. The pull request is
  reviewable as a partial checkpoint but has neither merge nor release
  authority.
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

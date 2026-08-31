# Forge Conductor checkpoint and historical release handoff

## Current checkpoint status — not release-qualified

The active repair line is `security/e2-harness-controls` in draft pull request
#19, now based directly on `main` at
`3e4fe44b3d96938c30d6b83f7d92d417489a97be`. Pull request #17 was
squash-merged into `main` at that commit from its former head
`dfebd8e4b0fe4aea6c6ff33717b9dfce717617d4`; both commits have the exact tree
`4e693995343b7115790b6beb849cc20b3518b8c4`. Pull request #19's tree-preserving
base-ancestry repair is `57c0366b82b992853ddd967d46d726b56abf233e`.
The H0 source checkpoint remains
`399e6a84c4760ddf6c13e02319dc120b4b8998c4`, and its state-and-evidence
transport checkpoint remains `63630658147c51af1c63a5c57b685bfd3d3c644b`.
A later state-only handoff, doctor, or base-integration commit may advance the
pull-request transport HEAD without changing the source checkpoint. Pull
request #18 was squash-merged into #17 as
`6ae3ca2b6abf4d67ce6b5ceb70bc5980794466a1`. No current claim is made that
P10, the filesystem E2 finding, shell compatibility, native UI validation,
autonomous continuity, representative hardware qualification, or final
release qualification is complete. Earlier green suites remain exact-revision
evidence only and do not confer release authority on this source tree.

The nonshipping H0 readiness run is
`EVID-20260831T060522Z-03c32cb838`. It binds the exact source checkpoint,
source manifest, signed harness and adversary identities, live process
CodeDirectory hashes, and four bounded describe/self-check commands. It
performed no production mutation and received no semantic qualification
context. All 57 E2 rows remain `not_run`, all 12 formal predicates remain false,
and every P10, E2, G10, G12, and release claim remains false. Its tested
inode/change-time replacement detection has a local-APFS precondition and is a
same-UID mitigation, not elimination.

Current release blockers are:

- **Filesystem mutation E2 remains open.** The canonical finding is
  `FC-FILESYSTEM-PATH-TOCTOU-001`; the approved policy alias is `FCA-007`.
  The selected partial implementation adds a separately signed root
  LaunchDaemon, a root-owned mode-0700 same-volume namespace, 32 durable
  transaction slots, bounded project bindings, descriptor-relative exclusive
  capture as the protocol-v5 linearization point, explicit current-entry,
  namespace-exact, and content-exact contracts, canonical request digests,
  post-capture identity verification, durable phases, retained
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
  exclusive capture. Under `currentEntry`, the successful capture defines the
  selected entry and an eligible captured occupant may be deleted; under
  `namespaceVersionExact`, a mismatching captured occupant must be restored
  exclusively or retained without disposal. One captured entry can become
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
  maximum availability impact is one retained entry per affected transaction,
  up to the 32 protected slots per volume, with no byte or descendant bound.
  Quarantine currently has no separately authorized restore, release, or purge
  action and is not acknowledgeable while the protected entry exists. Repeated
  conflicts can therefore exhaust all 32 slots and disable later protected
  deletes. Startup recovery before accepting new mutations is also not yet a
  proved barrier. Protocol-v5 disk records now use an explicit schema-3
  protocol/canonicalization boundary, valid pending capture-identity receipts
  are adopted before cleanup, and deterministic no-mutation capture denials
  become acknowledgeable rejected outcomes. Terminal-outcome receipts still
  lack a qualified repair transition when the physical protected leaf
  contradicts the recorded terminal disposition; that crash/corruption case is
  release-blocking. Source-parent authorization and capture are also not
  atomic: a same-UID relocation can move the validated pinned parent outside
  the authorized root before capture. One winning race can delete one eligible
  outside-root regular file or symlink with unbounded bytes, or quarantine an
  ineligible directory with an unbounded subtree. Outside-root sentinel
  preservation therefore cannot pass. The source-level adversarial swap,
  namespace-instability, durability, retained
  receipt, hard-link, and writable-descriptor regressions are supporting
  evidence. The 57-row qualification report now has an exact schema and an
  explicitly unexecuted template requiring per-case contract coverage, raw
  artifacts, barrier hits, iterations, process/signing identities, fixture
  digests, mount facts, crash points, and observed outcomes. Boolean-only rows
  are rejected. Source checkpoint
  `2dd504e53a5a09837cd289a99eee48ab7f4547eb` adds evidence-control schema v2
  and artifact-binding schema v1, recorder-owned evidence-specific copies,
  exact case/role/iteration and subject/predicate/fact binding,
  qualification-context binding, current-manifest and Git execution identity
  checks, bounded descriptor reads, and pathname replacement/rewrite negative
  tests. The evidence-control suite passed 57 of 57 tests in its final repeated
  validation. The template still has all 57 rows `not_run`, all 12 formal
  predicates false, zero formal references, and a null qualification-context
  reference. These controls do not execute a signed distinct-process case,
  establish any formal claim, provide an identity-conditional macOS mutation,
  or close E2. Qualification still assumes a trusted quiescent workspace
  against same-UID transient source-manifest replacement; an arbitrary
  caller-selected harness is not authenticated; aggregate report and evidence
  input reads remain unbounded fail-closed denial-of-service surfaces; the G10
  handler does not yet invoke this checker; and post-verification mutation
  remains outside immutable-content proof. The full signed distinct-process atomic-swap,
  crash-at-every-durable-phase and recovery, volume, wrong-signature,
  hard-link, and writable-descriptor matrices have not run.

  Initial project bindings are not yet composed with an independently verified
  manager authorization record. Bindings also have no manager-authorized revoke
  or garbage-collection lifecycle; after 256 distinct lifetime project
  bindings, another project fails closed. Protocol v5 now preserves the exact
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
- **Caller-sealed helper identity and packaging remain qualifying.** Protocol v5
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
  requirement, and protocol-v5 handshake. Source tests cover mismatch, timeout,
  late reply, single dispatch, lost mutation reply, retained transaction
  identity, pathless query/resume/acknowledgement, reinstall ordering, and a
  concurrent Disable superseding reinstall. They do not exercise those paths
  through the real signed asynchronous XPC service. Actual `SMAppService`
  approval, denial, update, disable, unregister/re-register, daemon restart,
  transaction recovery, signed Debug lifecycle, Release signing, and notarized
  Release lifecycle evidence remains absent. Shipped Release targets now request
  a Developer ID Application certificate class, but this host has only the valid
  James Daley Apple Development identity. No Developer ID build, archive,
  notarization, staple, or Gatekeeper pass exists, so the native Release gate
  remains deferred and release-blocking.
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
  protected-service control visibility, and GUI relaunch. A prior-manifest
  normal signed Debug build and paired app/daemon/CLI inspection passed as
  `EVID-20260830T211007Z-760c293557` and
  `EVID-20260830T211029Z-ae82e789b1` as supporting evidence only; their bundles
  contain no commit SHA, so neither is current-source qualification. Signing
  inventory `EVID-20260830T211040Z-5f8b21e6d9` confirms that no usable Developer ID
  identity is installed, while `EVID-20260830T211040Z-a8619d99c2` confirms
  that shipped Release configurations request Developer ID Application.
  These records do not cover the production
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
support, and the prior exact-revision strict suite passed. That strict evidence
is stale for source checkpoint `2dd504e53a5a09837cd289a99eee48ab7f4547eb`
and remains supporting evidence only. Those two issue closures do not pass P10,
E2, shell compatibility, native validation, or any release gate.

G09 is therefore historical exact-revision evidence rather than current release
authority. G09, G10, G11, and G12 remain nonpassing. A partial security pull request
may be reviewed only with these residual risks and deferred gates visible in its
description, the state ledger, doctor output, and next-work selection.

Source checkpoint `2dd504e53a5a09837cd289a99eee48ab7f4547eb`
passed all 57 evidence-control tests on the final repeated validation. Its
unexecuted qualification template remains deliberately nonpassing: 57 of 57
rows are `not_run`, all 12 formal predicates are false, there are zero formal
references, and the qualification-context reference is null. Debug strict
evidence `EVID-20260830T220320Z-4cccc31cce` and Release strict evidence
`EVID-20260830T220539Z-eac42f2a8c` each passed 771 tests with two declared
environment skips and no failures; they are supporting source evidence rather
than signed execution of the 57-row qualification matrix. Prior-manifest signed
Debug build evidence is
`EVID-20260830T211007Z-760c293557`; the exact paired app/daemon/CLI check is
`EVID-20260830T211029Z-ae82e789b1`. Signing inventory
`EVID-20260830T211040Z-5f8b21e6d9` confirms that no usable Developer ID identity
is installed, and Release build-settings evidence
`EVID-20260830T211040Z-a8619d99c2` confirms that the shipped configurations
request Developer ID Application. Signed Debug UI evidence
`EVID-20260830T153118Z-752f058222` passed all six bounded cases.

The publication-state transition refreshes doctor, handoff, completion,
evidence-index, package-validation, and selector artifacts after recording the
source checkpoint and pull-request identity. The source checkpoint and a
later state-only transport HEAD must remain distinct. Doctor and the next-work
selector must emit `release_authorized=false`, `merge_authorized=false`, every
open mandatory finding, and nonpassing G09-G12. `check_p10_completion.py` and
`verify_completion.py --no-finalize` are expected to exit nonzero because the
required signed matrix and all other hard gates remain open. The earlier failed
strict record `EVID-20260830T151425Z-09e2526950` remains a superseded negative
baseline, not pass evidence.

## Signed admission-observation control checkpoint

Source checkpoint `9e695f514caa7894903f54a92139c33eb43eb46d`
adds a bounded, non-mutating signed-client admission observation. An authorized
CLI health command holds one private `serviceInfo`/`status` XPC connection
across a wrong-identifier adversary probe. The recorder binds the repository,
source manifest, static and live CodeDirectory hashes, process identifiers,
effective user identifier, exact daemon hash set, daemon signing-requirement
digest, and canonical command output. Only a nonzero-exit explicit pre-reply
`connection_invalidated` event followed by healthy same-session post-health on
the reused connection can receive the label
`candidate_invalidation_observed`.

That label is deliberately nonqualifying. No live signed daemon observation
has run, no production mutation was exercised, zero of 57 matrix rows were
executed, zero of 12 formal predicates were proven, and every E2, P10, G10,
G12, and release claim remains false. Exact-source evidence
`EVID-20260831T132827Z-ce9b22a5e0` passed 820 Swift tests with two declared
environment skips and no failures. Evidence
`EVID-20260831T133202Z-1388f87b63` passed 13 admission-runner tests,
`EVID-20260831T133213Z-d4178c34a2` passed all 57 evidence-control tests,
`EVID-20260831T133355Z-948e5bec13` passed five checkpoint-identity tests, and
`EVID-20260831T133355Z-7f9c698548` passed the prohibited-attribution scan.

The observation tooling retains three explicit residuals. Invalid out-of-range
hold or total-deadline values can fail closed without emitting a structured
blocked report. Focused hung-child, oversized-output, and process-group cleanup
fault injection is inherited from the H0 runner rather than repeated in the
admission runner. The report binds source-manifest context and signed/live
binary identities independently, but does not cryptographically attest that
the signed executable bytes were built from that manifest. These gaps cannot
promote candidate evidence. The full signed 57-row matrix, the documented E2
races and maximum impacts, service lifecycle, native UI and signing, real-
provider autonomous continuity, owner-deferred hardware, and final release
qualification remain open and release-blocking.

## Current branch and pull-request lineage

- Active isolated working branch: `repair/e2-qualification-next`.
- Publication branch: `security/e2-harness-controls`.
- Signed admission-observation source checkpoint:
  `9e695f514caa7894903f54a92139c33eb43eb46d`.
- A later commit containing only handoff, doctor, selector, or publication
  readback does not change that source checkpoint; it is a distinct state-only
  transport HEAD. Pull-request readback is authoritative for the transport HEAD.
- Pull-request base branch and SHA: `main` at
  `3e4fe44b3d96938c30d6b83f7d92d417489a97be`.
- Current pull request: open draft #19,
  `https://github.com/flynn33/Forge-Conductor-MacOS/pull/19`, from publication
  branch `security/e2-harness-controls` into `main`. Before this checkpoint is
  pushed, its remote head is `ac7724b090d67490794b48bfdda72add751e2ec0`;
  post-push readback must match the new state-only transport HEAD. It remains a
  nonshipping readiness checkpoint with neither merge nor release authority.
- Pull request #18 was squash-merged into #17 as
  `6ae3ca2b6abf4d67ce6b5ceb70bc5980794466a1`. Pull request #17 was then
  squash-merged into `main` as
  `3e4fe44b3d96938c30d6b83f7d92d417489a97be`.
- Pull request #16 was merged into `main` as
  `67181bc934216e28e005fe28d90c791bef07f9ff`; it is now in the ancestry of
  both #17 and #19.
- Pull request #9 (`repair/autonomous-continuity` at
  `6321bd98012e5f60b2779bbb401cc2827f372b16`) was based on
  `ae0ceace702274857afce3097ac7cde18b7a6c63` and closed without merge. Its tree is
  `9c3b4fb924a81cce17d78f8356c3cd87af4a3002`.
- Pull request #10 (`repair/cancellation-recovery` at
  `4b887fcc423284d0a60f57baed3adab4b943a576`) used the same base, superseded
  #9 with the same resulting tree
  `9c3b4fb924a81cce17d78f8356c3cd87af4a3002`, and was squash-merged as
  `7808790d9f52f4ec287434d45826bfa0e5586892` with that same tree.
- Pull request #11 (`repair/filesystem-path-hardening` at
  `92122970c54cf549cdc5002db23044ed0b3552cb`) was based directly on the #10
  merge and has tree `b109d2ae6ec64ce5c4ce89c046301c4ac25a4672`.
  It was squash-merged as
  `6288210d82270b26add5f0e078d150bc4377bd62` with that same tree.
- The historical remote head branches for #9, #10, #11, #14, #15, #16, and
  #18 are deleted. No additional cleanup is required for those branches.
- Pull request #14 was squash-merged as
  `8bcc039a2f0d4d17b871d5e968b3b37a663c5ccb`. Pull request #15 was then
  squash-merged as `cd7e84fed8ed0fe0a8ec90793e83388c8a451f09`, and pull
  request #16 was merged as `67181bc934216e28e005fe28d90c791bef07f9ff`.
- Those commits are ancestors of this branch. None of these relationships
  closes P10, E2, shell compatibility, native validation,
  autonomous continuity, representative hardware qualification, or G09-G12.

## Historical 0.9.0 outcome

The autonomous repair phases P00-P12 were merged to `main` by pull request #6. The pre-P12 repair checkpoint is `082404ec42bf2adb775385dea85ad3b20d0076f4`; final P12 evidence and security remediation are included in that merged release checkpoint. Version and release-document alignment for 0.9.0 was merged from pull request #7 as `1f39ee6bdf1d4f907c6e1cb31f6213f2945d3985`.

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
- Pull request #6 was merged to `main`; pull request #7 was merged as `1f39ee6bdf1d4f907c6e1cb31f6213f2945d3985` for the 0.9.0 alignment.
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

# Forge Conductor checkpoint and historical release handoff

## Current checkpoint status — not release-qualified

Live GitHub readback identifies `main` at
`cd7e84fed8ed0fe0a8ec90793e83388c8a451f09`, the squash merge of pull
request #15. The prior PR description captured an earlier draft checkpoint and
is not current transport authority. The public documentation and build-metadata
alignment checkpoint is `docs/release-alignment` at
`b18bd3928127decaaa59cb556476fc7c758c78b3`, based directly on that `main`,
and is published in open pull request #16. A later state-only handoff commit may
advance the pull-request transport HEAD without changing that manifest-bound
documentation/source checkpoint. No current claim is made that P10, the
filesystem E2 finding, shell compatibility, native UI validation, autonomous
continuity, representative hardware qualification, or final release
qualification is complete. Earlier green suites remain exact-revision evidence
only and do not confer release authority on this source tree.

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
  are rejected. The current verifier establishes artifact provenance, hashes,
  ledger membership, schema conformance, and broad structural consistency, but
  it does not yet bind a generic aggregate artifact semantically to every case,
  role, iteration, barrier, mount observation, crash phase, fixture assertion,
  or formal argument. Case-scoped and role-scoped machine-readable harness
  results plus corresponding checker enforcement remain required before any
  passing report is authorized. The full signed distinct-process atomic-swap,
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
  protected-service control visibility, and GUI relaunch. A current-source
  normal signed Debug build and paired app/daemon/CLI inspection passed as
  `EVID-20260830T211007Z-760c293557` and
  `EVID-20260830T211029Z-ae82e789b1`. Signing inventory
  `EVID-20260830T211040Z-5f8b21e6d9` confirms that no usable Developer ID
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
support, and the current-source strict suite passed. Those two issue closures do
not pass P10, E2, shell compatibility, native validation, or any release gate.

G09 is therefore historical exact-revision evidence rather than current release
authority. G09, G10, G11, and G12 remain nonpassing. A partial security pull request
may be reviewed only with these residual risks and deferred gates visible in its
description, the state ledger, doctor output, and next-work selection.

The current source manifest is
`89e94937e86eb617eb7c6b2138f1584d3ecc7b32ce524919734fee39766a63a0`
over 256 inputs. Debug strict evidence
`EVID-20260830T220320Z-4cccc31cce` and Release strict evidence
`EVID-20260830T220539Z-eac42f2a8c` each passed 771 tests with two declared
environment skips and no failures. Prior-manifest signed Debug build evidence is
`EVID-20260830T211007Z-760c293557`; the exact paired app/daemon/CLI check is
`EVID-20260830T211029Z-ae82e789b1`. Signing inventory
`EVID-20260830T211040Z-5f8b21e6d9` confirms that no usable Developer ID identity
is installed, and Release build-settings evidence
`EVID-20260830T211040Z-a8619d99c2` confirms that the shipped configurations
request Developer ID Application. Signed Debug UI evidence
`EVID-20260830T153118Z-752f058222` passed all six bounded cases.

Historical post-push doctor evidence `EVID-20260830T221552Z-23fccf23e2`
verified the then-active PR #15 transport at
`61c3a00f3d0289cf4086182f0e8217567915b763` while retaining
`merge_authorized=false` and `release_authorized=false`. PR #15 was later
merged as `cd7e84fed8ed0fe0a8ec90793e83388c8a451f09`; the historical doctor
record does not describe that later GitHub transition. The corresponding
next-work record `EVID-20260830T221558Z-70e4c016b7` still resumes P10 and
preserves every mandatory blocker. State validation
`EVID-20260830T221613Z-ea0d244fa9`, package validation
`EVID-20260830T221614Z-188ad8b638`, attribution scan
`EVID-20260830T221614Z-a83cfa3e4a`, and secret scan
`EVID-20260830T221615Z-e08156083e` pass. The earlier failed strict record
`EVID-20260830T151425Z-09e2526950` is retained as a superseded negative
baseline, not pass evidence. Doctor and the next-work selector must continue to
emit `release_authorized=false`, all open mandatory findings, and the
nonpassing G09-G12 gates.

## Current branch and pull-request lineage

- Active published documentation checkpoint branch: `docs/release-alignment`.
- Documentation and build-metadata checkpoint:
  `b18bd3928127decaaa59cb556476fc7c758c78b3`.
- A later commit containing only handoff, doctor, selector, or publication
  readback does not change that manifest-bound checkpoint; the pull request
  readback is authoritative for its transport HEAD.
- Base branch and SHA: `main` at
  `cd7e84fed8ed0fe0a8ec90793e83388c8a451f09`.
- Current pull request: open, non-draft #16,
  `https://github.com/flynn33/Forge-Conductor-MacOS/pull/16`.
- Live readback records #16 from
  `docs/release-alignment@b18bd3928127decaaa59cb556476fc7c758c78b3`
  into `main@cd7e84fed8ed0fe0a8ec90793e83388c8a451f09`, one commit ahead and
  zero behind. It is a documentation/build-metadata checkpoint, not a release
  qualification.
- Pull request #9 (`repair/autonomous-continuity` at
  `6321bd98012e5f60b2779bbb401cc2827f372b16`) targeted `main` at
  `ae0ceace702274857afce3097ac7cde18b7a6c63`, but its head retained
  divergent pre-base history. It closed without merge.
- Pull request #10 (`repair/cancellation-recovery` at
  `4b887fcc423284d0a60f57baed3adab4b943a576`) used the same base, superseded
  #9 with the same resulting tree, and was squash-merged as
  `7808790d9f52f4ec287434d45826bfa0e5586892`.
- Pull request #11 (`repair/filesystem-path-hardening` at
  `92122970c54cf549cdc5002db23044ed0b3552cb`) was based directly on the #10
  merge and was squash-merged as
  `6288210d82270b26add5f0e078d150bc4377bd62`.
- The historical remote head branches for #9, #10, #11, #14, and #15 are
  already deleted. No additional cleanup is required for those branches.
- Pull request #14 was squash-merged as
  `8bcc039a2f0d4d17b871d5e968b3b37a663c5ccb`. Pull request #15 then merged
  linearly as `cd7e84fed8ed0fe0a8ec90793e83388c8a451f09`, the base of #16.
  Neither merge closes P10, E2, shell compatibility, native validation,
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

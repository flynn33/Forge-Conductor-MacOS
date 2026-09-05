# Forge Conductor shipping checkpoint

## Decision: BLOCKED checkpoint; not shippable

The latest package at `/Users/jimdaley/Projects/Forge-Conductor/Forge-Conductor-Codex-Shipping-Package` is the active authority. T0 was 2026-09-04 22:33:06 UTC / 17:33:06 America/Chicago. The owner manually ships. Protected merge and public publication are not authorized by this work. No release, archive/export or notarization has occurred.

| Required source and delivery item | Current observation |
|---|---|
| Canonical checkout | `/Users/jimdaley/GitHub/Forge-Conductor-MacOS`, branch `release/0.9.0-shipping`, source HEAD `b1876cf5b05134292ce0ecc6fb14ee67535c156c` before evidence-only delivery |
| Execution checkout | Same path, branch and HEAD as canonical; Git common directory `/Users/jimdaley/GitHub/Forge-Conductor-MacOS/.git` |
| Clean/dirty state | Controlled source clean at candidate freeze; final delivery cleanliness is verified in external `delivery-readback.json` after the evidence-only commit |
| Fetch and push destination | `https://github.com/flynn33/Forge-Conductor-MacOS.git`, remote `origin`; main last read back as `ffcf6bf9a2ea0c76a54788041cfa00c0dc8c7db4`. Final shipping-branch fetch/push readback is retained in external `delivery-readback.json` |
| Source candidate | `b1876cf5b05134292ce0ecc6fb14ee67535c156c` |
| Controlled build-input manifest | `4908eb162f9f8c7164c328d263fb484195145346b927f9f4232b6cbaca05eb14`, 392 files, 13,422,208 bytes; full paths and hashes in external `source-candidate-b1876cf-build-inputs.json` |
| Delivery / merge | The evidence-only commit containing this handoff is identified by external `delivery-readback.json`, produced after commit and push to avoid a self-referential SHA. No merge |
| Original work preserved | Local `release/0.9.0-product-readiness` at `829c06af9365928ead82eedd6fec66f053a56f05`; separate `/Users/jimdaley/GitHub/Forge-Conductor` and diagnostic worktrees untouched |
| Product identity | 0.9.0/build 1 for development qualification. Private distributed-build inventory is required before choosing a new distribution build |
| Xcode | `ForgeConductor.xcworkspace`; schemes `ForgeConductor` and `ForgeConductorAppTests`; explicit membership guard passes for 156 production Swift files |
| Host and support scope | Mac16,7 arm64, 48 GiB; macOS 26.6.2/25G83; Xcode 26.6/17F113, Swift 6.3.3; deployment macOS 26. No other physical-memory tier was qualified |
| Documentation | README, CHANGELOG, USER-GUIDE and XCODE updated; current impact review and named docs/version/membership checks pass |
| Signing | Apple Development team 9AQ2C2838M; Developer ID team 2Y25RTLZET unavailable |
| Archive / export / distribution hashes | None. The retained Apple Development build is not a distributable release |

## Implemented behavior

Native provider controls now save revisioned endpoint/model settings and keep, replace or clear Keychain credentials through authenticated manager routes. Bounded admission rejects overlapping work before queuing credential bodies; unsaved edits must be saved before discovery/probes. Router forwarding survives manager replacement.

Bootstrap, settings, plugin and diagnostics work has explicit background ownership. Pending saves preserve newer edits; operator screens wait for readiness and retain failure/retry controls. Process output drains are nonblocking and bounded through termination. Hidden or detached gauge surfaces stop drawing and resume only the latest value.

Continuity cancellation releases the creating executor/HTTP request. Coalesced callers cannot cancel the owner or turn shared interruption into terminal cancellation. Both result-delivery orders, accepted receipts, explicit cancellation and same-handoff restart recovery have deterministic tests. The configured 600-second provider bound and 660-second uncertainty fence remain unchanged.

Protected-filesystem recovery rejects contradictory terminal receipts and ambiguous replay and blocks new mutations while recovery debt remains. These changes do not close parent-relocation containment or enable the missing mutation capabilities.

Build identity, native test membership, development signing, CI and canonical installed CLI provenance checks are repaired. Historical inventory is preserved; current G01 validation uses the authoritative schema without promoting incomplete runtime assertions.

## Retained qualification

The full Debug/Release suites, 17 app-hosted tests, four native onboarding tests and focused sanitizers bind source `7d3fbb4c4def3ca4b0799e9a611a70ea816f881f`. Candidate `b1876cf` adds only four documentation files, the live test diagnostics and its baseline snapshot. `final-candidate-production-input-comparison.json` verifies all production source and build inputs are unchanged. The six focused diagnostic tests and ordinary signed build/install/CLI chain bind b1876cf directly. These scopes are retained separately.

External output root: `/Users/jimdaley/Projects/Forge-Conductor/shipping-evidence/20260904T223306Z`. The external `qualification-evidence-index.json` and `.md` enumerate the recorder results and artifact checks. Every command record remains in `.forge-codex/evidence`; failed records and source-specific artifact copies are preserved. Earlier-source results are supporting evidence only.

| Qualification | Observed result and evidence |
|---|---|
| Final SwiftPM Debug | `EVID-20260905T012952Z-438ce12991`: 1,043 tests, five skips, zero failures, 181.455 seconds, warnings as errors |
| Final SwiftPM Release | `EVID-20260905T012426Z-683a8dcacb`: 1,043 tests, five skips, zero failures, 168.070 seconds, warnings as errors |
| Declared suite skips | Three opt-in live cases, one external helper-only relink case, unavailable PowerShell; each full suite retains its actual skip count |
| Final native app-hosted | `EVID-20260905T013112Z-d0687b0ed2`: 17 tests, zero skips/failures |
| Final production onboarding | `EVID-20260905T012552Z-150ad6578a`: all four tests passed with zero skips. Real folder picker/cancel/invalid root, offline provider save/rejection/replacement, Settings shell off/on plus fresh MCP, and real provider discovery/connection |
| Actual native Keychain | `EVID-20260904T230820Z-6e5b1140b8`: 14 tests passed, including disposable Keychain operations; earlier-source supporting scope |
| Continuity ASan / TSan | `EVID-20260905T012426Z-5922d79531` / `EVID-20260905T012426Z-b891d547a1`: separate configurations, 29 selected tests each, one opt-in live skip, zero failures and no sanitizer errors |
| Earlier broader native ASan / TSan | `EVID-20260904T234923Z-11af1c99e5`: 23 tests; `EVID-20260904T234923Z-fb7abff122`: 21 tests, both zero failures. ASan shutdown priority warnings remain a performance limit; no whole-app closure claim |
| Native Release gauges | `EVID-20260905T001555Z-8e3d919e17`: four tests passed including 100 cycles. Component draw/buffer/weak-owner assertions passed; closed fixture windows accumulated to 101 |
| Native Release stress | `EVID-20260905T002734Z-868154a9ac`: retained 500 memory records, 100 project cycles, 100 MCP requests, 25 process cycles, 50 logical rollovers, 100 synthetic restarts and five flat post-release RSS samples. Final full Release also passed this workload. Not a soak or physical-hardware matrix |
| Canonical ordinary build | `EVID-20260905T020038Z-e1d79496cc`, passed; seven exact signed product files plus complete controlled input manifest hash-bound |
| Canonical bundle check | `EVID-20260905T020337Z-0bf14736d7`, passed with DevelopmentRelease trust policy |
| Canonical installation | `EVID-20260905T020339Z-bbd5f84078`: overall partial/exit 4; installation, raw CLI, default shell, migration, opt-out and app/manager restart substeps passed. Its own System Events Settings substep is not run; the separate native XCTest Settings case passed |
| Selected CLI production capture | `EVID-20260905T020541Z-44ebbd3215`, passed; independent reader `EVID-20260905T020559Z-b88b6a3a82` accepts exactly two assertions in development-installed-release scope. Full matrix and distribution qualification remain false |
| Signed MCP memory | `EVID-20260904T232726Z-eede5c9223`: 43 postconditions, 68 responses across five processes, all 17 memory tools and 12 cross-project denials; supporting scope only |
| Full MCP compatibility | `EVID-20260904T233148Z-91e3a4f6d2` failed required `fs_move` success; still blocked |
| Source / documentation checks | Attribution `EVID-20260905T020239Z-43b7016ef7`, docs `EVID-20260905T020239Z-0fcbeca4b2`, membership `EVID-20260905T020239Z-4bcd1d3341`, version `EVID-20260905T020337Z-2d9031f446`, passed |
| Final ready gates | `EVID-20260905T020201Z-d60f2fc514`, exit 1: current G00/G01 passed; G02-G09 rejected historical authority/bindings. G10-G12 remained dependency-blocked with older result files |
| Calibrated real managed rollover | EVID-20260905T013918Z-faae358156 failed one test/one failure after 504.049 seconds: missing accepted bootstrap receipt. Two predecessor turns crossed the exact threshold correctly; no recovery pass claimed. Read-only observations bound by EVID-20260905T015036Z-9abc7a3f6f |
| Smaller real fresh-root diagnostic | EVID-20260905T015037Z-7125c5a46e passed one test in 169.805 seconds: actual context 119,552, exact handoff acknowledgment, fresh root and automatic continuation marker validated |
| Final diagnostic tests | `EVID-20260905T020038Z-0fd00c88e8`: six SwiftPM tests, zero skips/failures, warnings as errors, including two new diagnostic privacy/bounds cases and four worker regressions. Native selector `EVID-20260905T020200Z-fdaed4e194` ran zero tests and is not qualifying evidence |
| Final manager diagnostic | `EVID-20260905T020600Z-5ede7bf8cf`: one test, two failures, 485.853 seconds. Child exit 1; recorder 125 because success-only JSON was absent. Sanitized failure artifact retained; no source drift. Ledger quarantined with `acknowledgement_mismatch`, no accepted receipt, intended injected crash not reached |
| Completion verifier | `EVID-20260905T021429Z-0c934cf27f`: exit 1; 64 of 124 checks passed, 60 failed checks. G12 remains blocked/open; not shippable |

Final development app: `/Users/jimdaley/Projects/Forge-Conductor/shipping-evidence/20260904T223306Z/DerivedData-Handoff-Release/Build/Products/Release/Forge Conductor.app`. Actual installed copy retained at `Installed-Handoff-Qualification-Home/Forge Conductor.app` under the output root. Build record lists every nested SHA256. Source GUI executable SHA256 is `5ded71fab710208ec45d2db67ebcef8d4787eefab00eda8f61f7dfee47e145a1`; CLI is `ac3431f713fa2f2295e4912c046c40e40e4157ba3d3640f1be3196e7eeb9399f`. These are development product hashes, not a distribution package hash.

Installation cleanup restored `.local/bin/forge-conductor-swift` to `/Users/jimdaley/.forge-conductor/bin/forge-conductor`, restored the relevant launchd disabled state and left no manager job/plist or recorded residuals. The real test cleaned its temporary manager fixture. The task-owned model was idle with no queued requests and was unloaded to restore the initial model state. `final-host-cleanup.json` retains the readback. No privileged filesystem service was installed.

The final failure summary hash matches the source-defined typed-call validation error: exactly one correctly named call with a JSON-object payload is required. This narrows the failure to call count, name or payload shape; it does not establish an identity/checksum/nonce mismatch. The smaller passing fixture allows 4,096 output tokens while the manager fixture allows 512. This difference is a hypothesis, not a proven defect. The transport already requires completed status. The minimum next diagnostic forwards the actual returned turn unchanged and records only call count, expected-name match, argument shape, output usage/cap and assistant-text bytes/hash or exact predecessor-wait match.

## Failed observations and their disposition

First live attempt `EVID-20260905T003625Z-18c26459bd` naturally failed one test/two failures after 486.098 seconds: the previous accelerated thresholds rolled over after only one predecessor turn, followed by cancellation during bootstrap. Child exit 1; recorder 125 because the success-only report was absent. No signals were sent. A later database diagnostic missed the already-cleaned fixture and remains a failed capture. The test threshold and observation-window repairs preserve ordinary policy, exact context, multi-turn requirements and the uncertainty fence.

The creating request and shared cancellation defects each have retained failing before and passing after tests. `EVID-20260905T012500Z-7d8f1ef32b` binds both forced V2 result-delivery orders: three tests/eight before failures, then three passes and 63 focused regressions with one skip. This supports bounded local ownership and recovery classification, not proof that a remote inference server stops immediately.

`EVID-20260905T012251Z-62f9e1131b` binds five failing native window comparisons. Hosting view and wrapper release; the closed window survives. An XCTest outer autorelease-pool retaining edge was observed, but failed pool comparisons do not establish that it is the sole owner. No production window leak/multiplication is established and no speculative fixture or product repair was committed. Raw memgraph remains outside the repository.

CLI capture `EVID-20260905T013354Z-f05c7c618f` selected zero tests because its supplied build recorder kind was not the reviewed canonical kind. A fresh canonical build/install/capture chain above corrected the invocation; the failed record and prior artifact paths remain unchanged.

## Hard blockers and minimum next actions

| Blocker | Evidence / minimum next action |
|---|---|
| Filesystem containment and missing mutation contracts | The unprivileged Darwin parent-FD relocation reproducer changed the relocated outside-root leaf. `fs_move` and recursive directory deletion remain disabled. Review an allowed identity-bound containment repair, then execute the signed 57-row E2/crash matrix; do not treat recovery mitigations as elimination |
| Privileged caller and service lifecycle | Prove installed caller identity/freshness, approval, update/disable/restart and recovery with the coherent signed stack and required owner-controlled consent |
| Full production-feature matrix | 104 features / 259 assertions; two CLI assertions accepted, 257 still lack concrete production scenarios. Wire and run remaining scenarios through the canonical registry and preserve all compatibility contracts |
| Real managed continuity | Diagnose the typed acknowledgment call rejected by the larger manager bootstrap. Preserve strict validation, classify malformed or missing calls without publishing prompts/credentials, repair only a reproduced cause, then prove same-handoff acceptance, continuation, fencing and crash/replay. The process-kill matrix remains separate |
| Native scene lifetime and resource budgets | Profile actual scenes outside the retaining XCTest fixture, finish before/after Release CPU/GPU/wakeup/database and long-duration memory trajectories, and run representative physical-memory tiers |
| Historical gate authority | G02-G07 include stale source/ledger hashes and some missing historical trace files. G08/G09 criteria have historical authority only. Requalify each actual criterion and missing observation; do not just replace hashes or authority flags |
| Distribution identity and signing | Obtain private distributed-build inventory and available Developer ID identity, choose a non-conflicting build, rebuild/archive/export and prove notarization/stapling/Gatekeeper and clean install/upgrade before owner publication |
| Final completion | Resolve the actual failed criteria and High findings, then rerun the verifier; current command failed 60 checks |

Automatic security review rejected the proposed privileged filesystem worker action as a possible cybersecurity risk. The rejected action was not retried through another lane. The remaining containment work is blocked on an allowed repair workflow.

## Resume and publication boundary

All final recorders completed with unchanged controlled source. Preserve all failed records, exact external artifact paths, original local branch and diagnostic worktrees. No public release or protected merge is permitted by this checkpoint; owner publication remains manual. Evidence-only delivery must compare every controlled input against source candidate b1876cf and verify fetch/push server refs after push. A later evidence commit does not make historical gate authority current.

## Historical product-readiness checkpoint — superseded branch description

The active branch is `release/0.9.0-product-readiness`. Its immutable source
checkpoint is `2cc41ee2d95255761582792ed6c70c00702ff2f6`, based on `main` at
`2e2ad93228c47e1fd16fb034e528d9a70cb61417`. Draft pull request #20 was read
back from GitHub with publication branch `release/0.9.0-product-readiness`,
transport HEAD `ea52c2779dd1f90ad718e93faa07459fc4ead511`, and base `main` at
`2e2ad93228c47e1fd16fb034e528d9a70cb61417`. It is reviewable only as a
partial checkpoint. It is not merge-authorized or release-authorized.

Exact-checkpoint evidence `EVID-20260901T105839Z-6eed3d3434` executed 1,001
Release tests with 5 declared environment skips and 0 failures.
`EVID-20260901T110721Z-924f41ac96` executed 2 of 2 signed app-hosted operator
contracts. `EVID-20260901T111032Z-3e4b6e0d96` built a coherent Apple
Development-signed Release product with the development trust policy, and
`EVID-20260901T111225Z-c749bdbf18` passed its five-artifact bundle check.
`EVID-20260901T111318Z-c887522fd4` passed the bounded installed-app shell,
raw-CLI, app-restart, and manager-restart checks, but remains intentionally
partial because native Settings mutation and post-Settings re-enable did not
run. Its completion claims are all false and cleanup restored scoped host
state. The earlier `EVID-20260901T110805Z-a977abdfeb` is a nonqualifying
fail-closed result from an incoherent evidence build; it is not positive proof.
The zero-test selector record `EVID-20260901T110446Z-c086c18d86` is likewise
not counted; the corrected eight-test filesystem support record is
`EVID-20260901T110510Z-b1be977c99`.

Feature completeness still requires successful production-path behavior. The
P10 registry contains 104 features and 259 required assertions, while the
production-probe registry implements zero scenarios. Unit, package, fixture,
app-hosted, build-only, and synthetic-host evidence cannot promote those
features to exact-current production-qualified. P10/G10, filesystem E2, native
UI and signing, shell Settings qualification, privileged-service lifecycle,
clean-install provider configuration, real-provider forced rollover,
owner-deferred physical hardware, G09-G12, and final release qualification all
remain open and release-blocking. The later historical checkpoint sections are
retained for provenance only and do not override this current status.

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

- Active and publication branch: `release/0.9.0-product-readiness`.
- Source checkpoint: `2cc41ee2d95255761582792ed6c70c00702ff2f6`.
- GitHub-read transport checkpoint:
  `ea52c2779dd1f90ad718e93faa07459fc4ead511`.
- Pull-request base: `main` at
  `2e2ad93228c47e1fd16fb034e528d9a70cb61417`.
- Current pull request: draft #20,
  `https://github.com/flynn33/Forge-Conductor-MacOS/pull/20`. Exact GitHub
  readback verified the branch, transport checkpoint, base, draft state, and
  open state. The pull request is conflict-free but blocked from merge. This
  state-only disclosure commit may move the transport HEAD without changing
  the immutable source checkpoint; live checkpoint identity must be read from
  doctor or the next-work selector before another publication transition.
- Pull request #9, head `repair/autonomous-continuity` at
  `6321bd98012e5f60b2779bbb401cc2827f372b16`, was closed without merge.
- Pull request #10, head `repair/cancellation-recovery` at
  `4b887fcc423284d0a60f57baed3adab4b943a576`, superseded #9 with the same
  resulting tree `9c3b4fb924a81cce17d78f8356c3cd87af4a3002` and was squash-merged as
  `7808790d9f52f4ec287434d45826bfa0e5586892`.
- Pull request #11, head `repair/filesystem-path-hardening` at
  `92122970c54cf549cdc5002db23044ed0b3552cb`, was based on the #10 merge and
  was squash-merged as `6288210d82270b26add5f0e078d150bc4377bd62`.
  The #10 merge is an ancestor of #11, and the #11 merge is an ancestor of the
  current `main` base.
- These relationships close no P10, E2, shell Settings, native validation,
  autonomous continuity, representative hardware, G09-G12, or release gate.

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

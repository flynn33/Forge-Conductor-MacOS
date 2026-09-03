# Privileged filesystem qualification matrix

## Authority

This matrix is the minimum signed-host qualification for
`FC-FILESYSTEM-PATH-TOCTOU-001` / `FCA-007`. It does not pass from Swift unit
tests, mocked transports, an unsigned build, or a synthetic helper identity.
Every applicable case must run against the normally built app bundle with the
daemon installed through `SMAppService`, the daemon observed at effective UID
0, and attacker/client programs signed as separate processes. Raw transcripts,
signing information, process identities, fixture identities, and before/after
sentinel hashes must be preserved by the bounded evidence recorder.

The current implementation checkpoint has not executed this matrix. A row in
this document defines required evidence; it is not a pass result.

Report schema v2 is
`.forge-codex/schemas/p10-privileged-filesystem-qualification-report.schema.json`;
it uses companion artifact-binding schema v1 at
`.forge-codex/schemas/p10-privileged-filesystem-artifact-binding.schema.json`.
Each recorder-preserved, read-only JSON snapshot binds its qualification and
evidence identifiers, current source manifest, case, role, iteration, subject
or formal predicate, and the canonical digest of the exact report fact. A dedicated
`qualification_context` envelope binds the exact capture timestamp, repository
identity, test environment, process identities, and same-UID declarations. A
passed report must identify a nonempty current branch, its 40-hex execution
HEAD, canonical base branch `main`, the exact SHA resolved from required
`refs/remotes/origin/main`, the canonical repository path, macOS build,
hardware model, platform, and architecture. The base must be an ancestor of
the execution HEAD, and the execution HEAD must resolve and remain an ancestor
of the current HEAD. Every intervening commit is inspected; only
`.forge-codex/state/**` and `.forge-codex/evidence/**` paths may occur. Any
other committed path fails even when a later commit restores the original
bytes. Source-manifest targets must also be clean in the worktree. This permits
bounded state-and-evidence transport without accepting product, script, or
other repository changes. The report capture timestamp must fall within the
context evidence record's bounded and ordered ISO-8601 start/end interval.

Before child launch, the recorder captures and supplies the evidence
identifier, source manifest, active branch, execution HEAD, base branch and
exact base SHA, repository path, macOS build, hardware model, platform,
architecture, qualification, and binding version. Semantic envelopes are
accepted only from the recorder's evidence-ID-specific repository copy;
external hash-only artifacts and captured stdout/stderr streams cannot support
a semantic fact. Each evidence record must reproduce that exact context and
contain bounded, nonplaceholder timing and environment provenance.

The semantic-copy loader accepts at most 1 MiB. It requires a canonical
repository-relative recorder source path and an evidence-ID-specific captured
path, then traverses from the repository descriptor without following final or
intermediate symlinks. The opened object must be a regular file owned by the
current effective user, have one link and mode exactly `0444`, and match the
recorded byte count and SHA-256. Device, inode, type/mode, owner, link count,
size, modification time, and change time must stay stable during the bounded
read. A second descriptor-relative lookup must still name that same regular
file after the read. These checks establish a bounded read-only snapshot at
evaluation time; they do not establish filesystem immutability or prevent the
same user from replacing the pathname after the check completes.

The checker rejects cross-case or cross-role reuse, duplicate formal-predicate
support, stale manifests, placeholder claims or scope, fact-digest mismatch,
obsolete or reversed timing, environment mismatch, referenced-byte mutation,
read-time mutation, and pathname replacement before the post-read lookup.

These are evidence controls only. The companion template remains intentionally
`partial` and `ok=false`; all 57 rows remain `not_run`, all 12 formal predicates
remain false, and it contains neither a qualification-context reference nor a
formal artifact reference. No signed
distinct-process row or formal closure has passed. A Boolean matrix is invalid
and cannot close a gate, and no passing qualification report is authorized.
E2, P10, G10, and G12 remain open.
The recorder executes the operator-selected command; these controls do not
authenticate an arbitrary harness or prove that its semantic claim is true.
The signed-host matrix separately requires the real signed processes and
attacker programs described below.
Mode `0444` and current-euid ownership are not authentication. A same-UID
process can author or replace a snapshot or record before evaluation, as well
as replace it afterward. The evidence control therefore assumes a trusted
operator and a quiescent same-UID writer during manifest capture, recording,
and evaluation. The active and template G10 handlers run the semantic P10
checker before acceptance validation with a pinned repository root. The gate
runner removes a stale criteria sidecar before launch, requires a freshly
written exact ordered criterion set with literal Boolean pass values, and binds
the executable gate and state-control chain into the source manifest. Handler
source is capped at 1 MiB and captured with stable descriptor metadata and
bytes. The captured bytes are copied to a temporary file, reopened read-only,
unlinked before execution, and executed through the inherited descriptor. A
pinned `FORGE_GATE_REPOSITORY_ROOT` preserves the established active/template
handler root contract even though `BASH_SOURCE` names `/dev/fd/...`. After the
handler exits, the retained descriptor's complete metadata and bytes must still
match the captured source. A same-UID or ACL-authorized writer can nevertheless
open the briefly named snapshot before unlink and retain a writable descriptor;
the post-execution checks detect an observed change but do not make execution
immutable. This is mitigation, not elimination.

These controls close only the acceptance-record, stale-sidecar, and direct
pathname-execution bypasses in G10. They do not authenticate a harness, execute
a matrix row, prove a formal predicate, provide an identity-conditional
mutation, or authorize release. These limitations are explicit release
nonclaims, not qualified security properties.

## Admission resource bounds and compatibility

P10 admission now applies the following fail-closed bounds to actual bytes
read, not only to a pathname `stat` result:

- each JSON/control file is at most 1 MiB and all such files consumed by one
  P10 evaluation share a 64 MiB aggregate budget;
- duplicate JSON keys, non-finite numbers, and numeric lexemes longer than 128
  characters are rejected;
- repository paths are canonical relative paths, opened component by component
  from the repository descriptor with no symlink following, and must remain the
  same regular-file identity and metadata through a post-read lookup;
- each preserved or stream artifact is at most 64 MiB and parsed stdout is at
  most 16 MiB. One P10 checker process may successfully consume at most 512 MiB
  cumulatively across referenced evidence reads. Each read is charged, so
  reading the same artifact again for semantic decoding or through another
  reference consumes the bytes again; files that exist but are never referenced
  are neither read nor charged;
- a source manifest contains at most 32,768 files discovered within at most
  65,536 traversed entries, at most 64 MiB per file and 512 MiB per logical
  snapshot. Two independently enumerated snapshots whose files are opened
  descriptor-relative must agree, so one successful manifest calculation
  accepts at most 1 GiB across both passes; a rejected overflow may fetch the
  one additional sentinel byte described below;
- gate-handler source and a criteria sidecar are each limited to 1 MiB. A gate
  handler has a configured deadline and a 64 MiB combined stdout/stderr cap.
  Deadline or output overflow terminates the full child process group, reaps
  the direct child, preserves only the captured bytes within the cap, and
  cannot reuse an old criteria sidecar;
- gate selection and ordinary state-control JSON inputs are limited to 1 MiB
  per file and 64 MiB in aggregate. Gate-result JSON serialization is capped at
  1 MiB. The state transaction journal has a separate 4 MiB cap because it
  carries the pending state transition. The append-only event ledger is limited
  to 64 MiB, 100,000 events, and 1 MiB per event.

The cumulative limit counts bytes actually accepted from every referenced
read, not the sum of distinct pathname sizes. A bounded reader may request one
byte beyond the remaining file or cumulative allowance as an overflow
sentinel. Receiving that byte fails the read immediately; it is not admitted as
evidence or included in a successful returned digest. The post-hash metadata
and pathname-identity lookup reads no file content and therefore consumes no
additional evidence bytes. A digest computed before that lookup is returned
only when the lookup still names the verified regular-file identity.

The recorder still permits a hash-only external artifact up to 16 GiB. That is
a preservation contract, not automatic G10 admission. G10 specifically
requires canonical repository-contained acceptance evidence, limits each such
file to 64 MiB, and rejects the invocation after 512 MiB of cumulative
referenced reads. Existing large or external records remain recorded but cannot
by themselves close G10; they need a bounded repository-preserved result that
carries the exact semantic claim and digest references. Other gates retain the
compatible acceptance path for repository or absolute external regular-file
evidence, with a 16 GiB per-file limit and a 16 GiB cumulative read budget per
validation invocation. Repository containment is therefore a G10 admission
rule, not a global rejection of compatible non-G10 external evidence.

These bounds and stability checks mitigate resource exhaustion and
mutable-path ambiguity during each read; they do not eliminate either the
same-UID race or its persistence. A same-UID writer can still replace a report,
sidecar, handler, state file, or artifact before the initial open or after the
final lookup and before a later consumer uses the pathname. One winning
replacement can influence the current bounded evaluation or following state
transition, and a false criteria sidecar, gate result, or ledger state can then
persist and be consumed repeatedly until a trusted operator detects it and
requalifies from trusted inputs. A writer that repeatedly wins the interval can
influence an unbounded number of later invocations over an unbounded duration;
the byte limits bound each invocation, not the number of races or the lifetime
of their result. The maximum harness impact until detection is a sustained
false G10 pass, incorrect ledger state, and erroneous release-admission
decision. It grants no direct product filesystem mutation authority. Detection
of an observed identity or metadata mismatch fails that read closed, but these
checks are mitigation, not authentication or race elimination.
Harness authorization and all signed-host predicates remain open release
requirements.

Gate-result and ledger publication use an operation-paired crash protocol. A
finalized result and fresh canonical UUID-v4 operation identifier are durably
published first; the paired ledger event receives its own fresh UUID-v4
`event_id`. Every fallible gate-result-directory and lock identity check occurs
before `statectl`; a failed last precommit check therefore cannot publish a
matching passed state. The state transaction journal is durable before event
append, the event is durable before state publication, and the marker is
removed only after publication. Recovery distinguishes an absent append, a
partial append, a complete append, and an already-published state, and replays
the identical operation exactly once. Retrying an operation UUID is idempotent
only for the same request and does not append a duplicate event; reuse for a
different request fails closed. If a state transition cannot be confirmed, the
result is rewritten `failed` and `finalized: false`.

The `statectl` commit is the cooperative crash model's success point. Before it,
a crash leaves the result operation different from the prior state operation;
after it, no fallible pathname-identity check remains in the success path. Gate
selection skips work only when state and result are both `passed`, both name the
same gate and nonempty operation UUID, the result is `finalized: true`, and its
Git HEAD and bounded source manifest still match the current source identity.
Missing, oversized, legacy, non-finalized, or mismatched records rerun or fail
closed. This pairing supplies crash consistency and observed source freshness,
not authentication or identity-conditional mutation.

A same-UID or ACL-authorized writer can still replace data after the last
precommit observation and before the state commit, or forge both records before
a later consumer. One winning race can persist as a false G10 result, incorrect
ledger state, and erroneous release decision until trusted requalification;
repeated winning races can sustain that outcome indefinitely. The controls add
no privileged product-filesystem mutation authority. This remaining interval
is mitigation, not elimination.

The final completion validator uses the same strict 1 MiB owner-controlled
JSON inputs and 64 MiB control budget. It accepts only canonical
repository-contained gate-result and acceptance paths, requires the exact
finalized state/result operation pair for every prerequisite gate, and rejects
unresolved Critical or High findings in either findings resolution or the live
run-state issue ledger. Missing or malformed ledgers fail closed. G02 through
G11 require matching acceptance records whose `gate_id` exactly matches the
invoked gate and whose `current_release_authority` is the literal Boolean
`true`; legacy omission, `null`, numeric, string, or historical authority is
not current authority. The shared gate-local acceptance handler enforces the
same rule before it can publish a passed criterion sidecar, so historical G09
adapter evidence cannot become a current real-provider continuity pass.
The gate plan must be exactly the ordered canonical `G00` through `G12`
inventory and definitions. Every gate result must use a canonical UUID-v4
operation identifier and bind exactly the canonical stdout, stderr, and
criteria runner artifacts, in that order. The command hashes must equal the
exact stdout and stderr artifact hashes; the criteria bytes must equal the
exact ordered evaluator criteria with literal Boolean passes; the state
evidence IDs and the one paired `gate_status` event must bind those same hashes
at `state_sequence_before + 1`. These artifact reads are capped at 64 MiB each
and 512 MiB in aggregate across all 13 gates.

Every prerequisite result must bind the same clean current Git HEAD and bounded
source manifest. The completion report's `admission_contract` records the
exact run, repository, HEAD, manifest, pre-G12 sequence, ordered `G00` through
`G11` prerequisites, and for each prerequisite the gate ID, operation UUID,
SHA-256 of the exact result JSON, and byte count. Referenced non-G10 artifacts
retain the compatible
16 GiB per-file and cumulative bound; G10 remains repository-only at 64 MiB per
file and 512 MiB cumulatively. Completion JSON and Markdown reports are each
limited to 1 MiB and published through the locked atomic state-file path. The
validator, its focused regression suite, and the active/template G12 handlers
are source-manifest targets.

G12 runs the validator in non-finalizing mode, binds the exact path, SHA-256,
and byte count of both reports into its criteria sidecar, requires every G12
criterion to cite both report digests, and delegates result/state publication
to the hardened gate runner. The reports must be successful and evaluated
within the G12 runner interval. The outer completion command must then reread
and confirm the canonical finalized G12 operation pair and current source
binding before requesting the idempotent `complete` run-status transition.
Under the state transaction lock, `statectl` rechecks every gate and its exact
three runner artifacts, the typed issue ledger, both report bindings, the G12
file bytes and operation, clean current HEAD/manifest, and the exact
pre-G12-to-post-G12 event-sequence increment. A successful state persists the
exact G12 operation UUID and final status-operation UUID in
`completion_authority`. `statectl show` and `statectl validate` revalidate that
authority and current source whenever complete status is read; stale authority
or source fails closed. Retrying the same final status operation revalidates the
precondition and creates no second event. Any intervening cooperative state
transaction blocks completion, and any later non-idempotent state mutation
demotes the run to `active` and removes its completion authority. A missing,
oversized, linked, legacy,
non-finalized, mismatched, failed, or unconfirmed record cannot finalize the
run. These controls do not turn prior unit, synthetic-host, simulator, or
partial UI evidence into any required real-provider, signed native, or physical
hardware proof.

The release package, attribution, and secret commands traverse at most 65,536
observed entries and 128 directory levels, read at most 64 MiB per file and
512 MiB cumulatively, cap scanner findings at 10,000, and bound package child
commands to 300 seconds and 16 MiB combined output. The package report is
limited to 16 MiB. Streaming enumeration aborts on the first excess entry;
symlink, special-file, hard-link, replacement, timeout, and overflow cases fail
closed.

The final HEAD/manifest, control-file, and G12 rereads are sequential
observations. A same-UID or ACL-authorized writer can still win after the last
observation and before the locked status publication, or can forge a coherent
set before a later consumer. One winning race can persist as one false
`complete` status and an erroneous release decision until trusted revalidation
and requalification; repeated wins can sustain that false release state
indefinitely. The maximum direct product-filesystem authority added by this
admission race is none. These controls are mitigation, not elimination. E2,
P10, G10, G12, native signing/UI, real-provider continuity, and owner-deferred
hardware qualification retain their existing open or blocked conclusions
until the required evidence exists.

The control's ownership and POSIX-mode checks do not enumerate extended ACL
entries on the repository or state directories. The trusted-host assumption
therefore also requires that no other principal has an ACL-based write grant.
A differently identified process with such a grant has the same replacement
ability and maximum harness impact described above. This is an explicit host
and repository trust residual, not evidence that replacement is limited to the
numeric owner UID on every configured filesystem.

## Process and fixture rules

- Record active branch, exact execution HEAD, exact
  `refs/remotes/origin/main` SHA, repository path, app/helper CDHashes,
  designated requirements, provisioning/signing identities, macOS build,
  hardware model, platform, architecture, APFS mount flags, and helper
  effective UID.
- Use distinct authorized app, authorized manager/CLI, unauthorized same-UID,
  differently signed, and malformed-wire processes. Never simulate identity by
  calling daemon code in-process.
- Give the attacker deterministic barriers at each named window. Confirm the
  barrier was reached before performing `renameatx_np(..., RENAME_SWAP)` or the
  metadata mutation; a missed window is inconclusive, not a pass.
- Hash and identify every source, peer, outside-root sentinel, protected entry,
  and receipt before and after each case. Record device, inode, type/mode,
  owner, group, link count, ACL state, BSD flags, and relevant directory fsync
  outcomes.
- Repeat idempotency and recovery cases after app, manager, daemon, and host
  process restart as specified. A timeout or crash without a terminal queryable
  disposition is a failure.
- No case may use the legacy same-UID mutation implementation as a fallback.

## Required cases

| Matrix key | Required action and pass predicate |
| --- | --- |
| `signed_debug_bundle` | Build Debug normally, verify the entire nested seal and exact daemon/client requirements, reject test-injected helper entitlements, install, and observe the root daemon. |
| `signed_release_bundle` | Build and notarize Release, verify nested seal and exact production requirements, install, and observe the root daemon. Build-only or a started notarization is insufficient. |
| `unauthorized_same_uid_client` | A separately signed same-UID program outside both enumerated client identifiers attempts every message. Connection/request is rejected and all fixtures remain byte- and identity-stable. |
| `unauthorized_same_uid_namespace_access` | Same-UID attacker attempts open, enumerate, rename, unlink, replace, link, chmod, chown, and extended-attribute/ACL operations in the protected namespace. Every useful access fails. |
| `unauthorized_same_uid_ledger_mutation` | Same-UID attacker attempts the same operations against bindings, receipts, locks, slots, and pending/phase files. State and hashes remain unchanged. |
| `differently_signed_client` | A substituted identifier and a different-team signature are each rejected before authority is exercised. |
| `authorized_app_and_manager_cli_identities` | Exact app and manager/CLI designated requirements each connect successfully; no other same-team identifier is accepted. |
| `unknown_protocol_and_malformed_messages` | Unknown versions, operations, classes, fields, missing fields, oversized strings/components/counts, invalid descriptors, duplicate fields, and decode failures are rejected without crash or state creation. |
| `outside_root_sentinel_preservation` | Attempt lexical, symlink, alias, descriptor-rebind, `..`, absolute-path, hard-link, and parent-swap escapes toward a hashed outside-root sentinel. Sentinel bytes, identity, ACL, and flags remain unchanged. |
| `wrong_project_id` | Reuse valid root/transaction material with a different project UUID. Reject without binding or transaction mutation. |
| `stale_project_generation` | Submit lower and conflicting generations before and during recovery. Reject and preserve the active generation and fixtures. |
| `negative_project_generation_wire_rejected` | Encode negative signed generations and values above `Int64.max`. Secure decoding/validation rejects them before binding state is written. |
| `project_binding_hash_collision_resolution` | Two distinct valid UUIDs with the same initial binding hash occupy distinct bounded slots and retain independent UID/root/generation authority across restart; a full ledger fails closed. |
| `project_binding_lifecycle_exhaustion_and_revoke` | Fill all 256 binding slots, prove the 257th project fails closed, then exercise an independently manager-authorized revoke/garbage-collection operation. It cannot remove an active transaction binding, cross UID/project authority, or leave a stale slot reusable without durability. This lifecycle is not implemented yet. |
| `case_normalized_transaction_replay` | Replay request, transaction, and project UUIDs with valid upper/lowercase spellings. One logical transaction is recognized; no duplicate capture occurs. |
| `root_descriptor_identity_mismatch` | Replace, rebind, or pass a descriptor whose device/inode/type/owner/mode/root ID differs. Reject before intent/capture. |
| `atomic_swap_source_leaf_before_capture` | Exercise both `currentEntry` and `namespaceVersionExact`. Swap the leaf immediately before capture. `currentEntry` may delete the eligible entry captured at the successful rename linearization point; it must not claim an earlier observed identity. Namespace-exact may dispose only the captured identity matching its token; a mismatch is restored exclusively or durably quarantined without disposal. Also substitute an immutable/no-unlink entry and an unrenameable mountpoint; documented no-mutation `EPERM`/`EBUSY` capture failures become durable rejected outcomes and do not strand a slot after acknowledgement. |
| `atomic_swap_source_leaf_during_capture` | Continuously swap two regular leaves around the capture syscall under both `currentEntry` and `namespaceVersionExact`. Each iteration must report the entry captured at the successful rename linearization point. Namespace-exact disposes only a token match; current-entry disposes only the eligible captured occupant; absent/conflict/inconclusive outcomes are truthful and outside sentinels survive. |
| `atomic_swap_source_leaf_after_capture` | Attempt source-name swaps after capture. The protected captured occupant cannot be opened or substituted and terminal disposition remains bound to its recorded identity. |
| `atomic_swap_parent_before_capture` | Swap or rename an intermediate/final parent before capture. The required result is rejection or operation only beneath the still-authorized root with no outside-tree change. The current pinned-parent capture does not meet this requirement: a same-UID relocation can move that descriptor outside the root before capture, so this row and E2 remain open. |
| `atomic_swap_parent_after_capture` | Move/replace the source parent after capture and before recovery/rollback. Commit, exclusive restore, or retained recovery is truthful; nothing restores into a substituted parent. |
| `parent_relocation_during_rollback` | Relocate the pinned or freshly reopened source parent after capture and during rollback. The privileged daemon must not restore through any relocatable parent descriptor; the captured leaf remains in the protected slot with recovery required, and no outside-root namespace is changed. The current implementation intentionally disables automatic privileged restore and requires this distinct-process signed test before the row can pass. |
| `atomic_swap_rollback_destination_occupied` | Occupy the original name before rollback. `RENAME_EXCL` preserves both occupants and retains the protected entry with a queryable receipt. |
| `atomic_swap_special_leaf_before_descriptor_open` | Swap a FIFO, socket, device, or directory between precheck and descriptor open while supplying crafted expected identities. Only regular files/symlinks are accepted; no special entry is deleted. Record that metadata-only/event descriptors mitigate but do not establish an identity-conditional syscall. |
| `authorization_metadata_change_after_final_check` | From a retained descriptor or hard link, change ACL/BSD flags after the final helper check and before unlink. The observed outcome and maximum impact are recorded; any deletion after newly restrictive ACL metadata keeps E2 open. |
| `crash_at_every_durable_phase` | Kill the daemon before/after intent write+fsync, capture, capture-identity pending-file fsync/publication, source/slot fsync, captured phase, unlink, slot fsync, committed phase, rollback phase, restore, and receipt cleanup. A valid pending capture-identity receipt is adopted rather than replaced by a later metadata observation. Inject terminal receipt/physical-leaf mismatches as well. Each restart reaches commit, exclusive restore, retained recovery, truthful conflict, or an explicit unrepaired release blocker without silent loss. |
| `daemon_restart_and_idempotent_recovery` | Repeatedly restart the daemon and resubmit/query the same transaction. Exactly one mutation occurs and the same terminal result is returned. |
| `manager_restart_and_idempotent_recovery` | Kill/restart manager and app after submission and after reply loss. The original transaction ID remains usable; no duplicate mutation occurs. |
| `query_is_strictly_nonmutating` | For intent, captured, rollback, committed, restored, rejected, acknowledging, malformed, missing, and wrong-authority records, query performs no cleanup, phase transition, receipt rewrite, slot reuse, or leaf mutation. It returns only the exact authorized disposition or the same generic unavailable result used for an unknown transaction. |
| `resume_after_reply_and_pathname_loss` | Lose the original reply, remove or replace the original pathname, restart the app/manager client, and resume using only the retained transaction ID plus the currently authorized exact root descriptor. The daemon reaches one durable terminal disposition without accepting a replacement leaf path or creating a second transaction. |
| `terminal_outcome_retained_until_acknowledged` | Commit, restore, and reject outcomes remain queryable and occupy their fixed slot across repeated daemon and caller restarts. A 33rd transaction fails closed while all 32 slots await acknowledgement; no terminal outcome is recycled by age, process restart, or unrelated activity. |
| `acknowledgement_authority_and_idempotency` | Acknowledge requires the exact requester UID, transaction UUID, project UUID, generation, root ID, root identity, and current authorized root descriptor. A wrong authority receives generic transaction-unavailable and cannot release the slot. Repeating an exact acknowledgement after successful cleanup is idempotent. |
| `acknowledgement_crash_cleanup_matrix` | Kill the daemon before/after acknowledgement-pending creation, acknowledgement publication and fsync, phase removal and fsync, outcome removal and fsync, and final acknowledgement-marker removal and fsync. Retry finishes cleanup without resurrecting a protected leaf, losing an unacknowledged terminal result, or making a slot simultaneously active and reusable. |
| `caller_ledger_precedes_xpc_submission` | Force caller-ledger create, lock, encode, write, rename, and sync failures. No XPC mutation is submitted until the bounded owner-only authority record is durable. A malformed, multiply linked, wrong-owner, permissive-mode, symlinked, or full caller ledger fails closed. |
| `caller_ledger_restart_and_scope_fencing` | Rebootstrap the app and manager with a new client process, recover the retained transaction under the same project generation and exact writable-root identity, then prove that different project, generation, root, requester, missing record, and mismatched daemon response cannot dispatch or remove caller recovery authority. |
| `broker_interruption_requires_transaction_recovery` | Interrupt a real brokered protected delete after daemon intent/capture/terminal mutation but before the broker records its result. Replay of the provider call must never infer completion from pathname absence or dispatch a second delete. It remains durably ambiguous until the original transaction is discovered and reaches a queryable, acknowledged terminal result. |
| `caller_ledger_same_uid_tamper` | A hostile same-UID process renames and removes the caller-ledger directory and slots after retention, after XPC submission, and across app/manager restart. Qualification requires recovery through independently protected daemon-owned discovery or equivalent authority; losing the only transaction handle, stranding any captured entry/outcome, or exhausting the 32 daemon slots is a failure. The current owner-only caller ledger does not pass this row. |
| `caller_ledger_lock_replacement_during_retention` | After a delete acquires and validates the caller-ledger lock and current project generation, unlink or replace that same-UID-owned lock inode before slot publication. Race generation reset on the replacement lock. Qualification requires reset and retention to remain one serialization domain, or requires a final daemon-enforced generation fence before mutation. The current pathname-based ledger can split the locks, publish stale authority, and dispatch after reset; it does not pass this row. |
| `project_generation_reset_with_retained_transaction` | Attempt a project-generation reset while caller authority exists for that generation, then race retention before, between, and after both reset preflights. A visible retained record makes reset fail closed and return the project to active at the original generation; a failed reset cancellation must surface the distinct cleanup failure instead of claiming that active state was restored. Normal retainers share the caller-ledger file lock across both preflights and generation advance, and a delete delayed behind reset must revalidate current project authority inside that same lock before record publication or XPC dispatch. Qualification must also rename or remove already-retained records and the same-UID-owned ledger directory before reset: hiding the only caller handles can let generation advance while daemon transactions remain and then complete under old authority. Until daemon-owned discovery or generation revoke exists, maximum post-reset impact is up to 32 captured or terminally deleted expected leaves per protected volume; each regular file may contain unbounded bytes. The current implementation mitigates but does not eliminate this race. |
| `local_ownership_enforced_apfs` | Qualified local writable APFS with ownership enabled performs the supported operation and confirms namespace/receipt durability. |
| `external_volume_rejected` | External-volume classifications match observed mount/device capabilities; unsupported cases fail before mutation. |
| `removable_volume_rejected` | Removable media that cannot meet namespace, ownership, primitive, or durability requirements fails closed and truthfully. |
| `network_volume_rejected` | Network filesystems fail before transaction creation. |
| `ignore_ownership_volume_rejected` | APFS with ownership disabled/ignored fails before transaction creation. |
| `cross_volume_destination_durable_before_source_destruction` | When cross-volume support is implemented, destination content/metadata and parent durability are verified before source capture is terminally destroyed. Until then the operation is unsupported with source unchanged. |
| `approval_and_denial` | Not registered, awaiting approval, explicit denial, approval, and revoked approval map to exact typed states with no fallback or shell-policy change. |
| `upgrade_unregister_reregister` | Upgrade, unregister, asynchronous reap completion, re-register, daemon replacement, and stale installed-version scenarios retain or recover transactions. The old daemon cannot service a post-upgrade mutation, and same-connection protocol/product/identifier/root-UID mismatch fails before request submission. |
| `same_connection_service_version_handshake` | Protocol, product version, daemon identifier, root effective UID, and exact running helper CodeDirectory hash are checked on the same XPC connection before mutation submission. Field mismatch, identity mismatch, timeout, connection loss, and late reply before submission preserve the source and do not claim recovery; reply loss after submission returns the original transaction ID. The implemented state-machine and unit evidence are supporting evidence only; this row still requires the distinct signed-process XPC execution described above. |
| `caller_sealed_helper_code_identity` | Each main caller executable obtains its expected per-architecture helper CodeDirectory hash set from its own signed mapped code or kernel-attested entitlement. Before connection activation, the daemon designated requirement is conjoined with the exact `cdhash` set. Two same-team/same-identifier/same-version helpers with distinct hashes prove expected-live acceptance and stale-live rejection before `deleteLeaf`. Replacing the helper path after expectation creation cannot authorize the wrong mapped daemon. If whole-product rollback remains possible, its maximum root-daemon impact and required monotonic root-owned receipt remain explicit. |
| `app_manager_cli_helper_packaging` | The signed GUI app, installed login-manager app, installed raw CLI, and standalone CLI all originate from one canonical build artifact set and resolve the same signed expectation/helper relationship without environment/config/argument path authority. The full app contains the daemon, LaunchDaemon plist, embedded raw CLI, and manager framework; app-origin installation stages that CLI and framework and never substitutes the app main executable. The manager is not silently synthesized as an ad-hoc privileged-service owner. Caller-relative `SMAppService.notFound` does not prevent an otherwise authenticated raw client from probing the registered service, and independently built cross-pairs or missing/tampered/symlinked artifacts fail closed. |
| `settings_status_and_control` | Signed native Settings shows actual service state and registration controls; observed changes survive app and manager restart. |
| `tampered_or_wrong_signature` | Tampered nested code, wrong helper identifier/team/certificate, wrong client identity, and broken enclosing seal are rejected. |
| `source_leaf_substitution` | Exercise `currentEntry` and `namespaceVersionExact` across repeated hostile substitutions of regular file, symlink, directory, missing name, metadata change, and identity reuse. Current-entry behavior is bound to the captured occupant; namespace-exact never disposes a mismatch. A captured ineligible directory is retained, can represent an unbounded subtree, and consumes one protected slot. |
| `hard_link_behavior` | Exercise namespace-only and `contentVersionExact` behavior. Preexisting and newly created hard links cannot silently satisfy an exact-content contract. Content-exact fails closed without qualified writer/link exclusivity; namespace-only behavior and surviving aliases are reported explicitly. |
| `writable_file_descriptor_behavior` | Exercise namespace-only and `contentVersionExact` behavior with a writable descriptor retained before capture and mutations at every barrier. Content-exact returns exclusivity unavailable/unprovable; no immutable-content claim is made. The signed case also measures the remaining final metadata-check-to-unlink race. |
| `no_same_uid_fallback` | Disable, kill, deny, mismatch, and corrupt the helper/namespace. Every protected mutation returns its typed error and the legacy same-UID mutation path is never called. |
| `shell_nonregression` | The established synchronous `/bin/bash -lc` `shell_exec` contract remains enabled by default and functional; clean-profile `bash.run` remains additive and nonprivileged through install, denial, helper restart, app restart, and manager restart. |

## macOS filesystem API capability analysis

The implementation uses descriptor-relative operations wherever macOS exposes
them, but none of the evaluated public interfaces combines a terminal namespace
mutation with an expected source device/inode/vnode-generation predicate.
Successful exclusive capture followed by verification inside a root-owned
namespace is the selected equivalent boundary for namespace contracts. That
architecture is still only a mitigation checkpoint until its signed matrix and
formal closure pass; it must not be described as eliminating the underlying API
limitation or the remaining authorization-metadata race.

| API or primitive | What it establishes | Why it does or does not meet the required identity-conditional mutation |
| --- | --- | --- |
| `openat` with `O_NOFOLLOW_ANY` and `O_RESOLVE_BENEATH` | Opens traversal components relative to a pinned directory while rejecting symlink traversal and resolution above that directory. | It pins the object returned by the open; it does not make a later unlink or rename conditional on that object's identity. macOS exposes no supported unlink-by-open-file-descriptor form for this use. |
| `fstat`, `fstatat`, and `lstat` | Observe device, inode, type/mode, owner, group, link count, flags, and related metadata at one instant. `AT_FDONLY` is an observation option for `fstatat`. | Observation and mutation remain separate syscalls. A cooperating or hostile writer can change the final name binding or authorization metadata after observation. |
| `openat_authenticated_np` | Optionally verifies that an opened file resides on the same authenticated volume as an authentication descriptor. | It authenticates volume placement, is an open rather than a namespace mutation, and accepts no expected file identity. It therefore cannot condition `unlinkat` or `renameatx_np` on the previously observed source vnode. |
| `unlinkat` | Removes the current name relative to a pinned directory descriptor. | It accepts a directory descriptor, name, and flags only. It has no expected device/inode/generation argument, so it removes whichever eligible object occupies that name when the syscall executes. |
| `renameat` | Moves the current source name between pinned directory descriptors. | It provides descriptor-relative resolution but neither destination exclusivity nor an expected-source-identity predicate. |
| `renameatx_np(..., RENAME_EXCL)` | Atomically refuses to replace an existing destination; the privileged daemon uses it for capture and protected metadata publication. Automatic privileged rollback is disabled. `RENAME_NOFOLLOW_ANY` and `RENAME_RESOLVE_BENEATH` can constrain resolution where supported. | The exclusivity condition applies to destination existence, not to equality between the current source and a previously observed vnode. With the current pinned-parent capture, it also does not prove that the already-open source parent remains below the authorized root. Root-relative resolution would not atomically reproduce the separately observed requester-permission decision. |
| `renameatx_np(..., RENAME_SWAP)` | Atomically exchanges the two current name bindings and is therefore the correct adversarial test primitive. | It proves that source substitution can be atomic; it does not accept an expected identity and cannot be used as an identity guard. |
| `fcntl`/file descriptors and APFS durability syncs | Keep opened objects stable for inspection and establish ordered durability for directories and receipts. | macOS does not expose a supported descriptor-only unlink/rename that consumes the inspected file descriptor as the source identity. Durability orders an outcome but does not select which source binding a later namespace syscall mutates. |
| `SMAppService` plus authenticated NSXPC | Moves the mutation and receipt ledger behind an approved root process and authenticates the permitted caller and exact running daemon. | This removes same-UID write access to the protected namespace and bounds recovery authority, but lifecycle and peer identity do not add a vnode-identity predicate to the terminal filesystem syscall. |

## Closure rule

Even a fully executed matrix cannot close E2 while an identity-conditional
terminal mutation or equivalent formal boundary is unproved. The qualification
report must distinguish API limitation, mitigated risk, unsupported contract,
and any open release blocker; it must record the remaining race and maximum
possible impact. It may not label mitigation as elimination. While the final
authorization-metadata race, permanent quarantine-slot exhaustion, caller-ledger
tamper/generation race, startup recovery barrier, binding lifecycle, volume
behavior qualification, terminal-receipt/physical-leaf reconciliation, or any
source-parent-containment/authority race, or any required signed row remains
open, the report is
nonpassing and `FC-FILESYSTEM-PATH-TOCTOU-001`, P10, G10, and G12 remain open.

# Privileged filesystem qualification matrix

## Authority

This matrix is the minimum signed-host qualification for
`FC-FILESYSTEM-PATH-TOCTOU-001` / `FCA-007`. It does not pass from Swift unit
tests, mocked transports, an unsigned build, or a synthetic helper identity.
Every applicable case must run against the normally built app bundle with the
daemon installed through `SMAppService`, the daemon observed at effective UID
0, and attacker/client programs signed as separate processes. Raw transcripts,
signing information, process identities, fixture identities, and before/after
sentinel hashes must be preserved by the immutable evidence recorder.

The current implementation checkpoint has not executed this matrix. A row in
this document defines required evidence; it is not a pass result.

The report contract is
`.forge-codex/schemas/p10-privileged-filesystem-qualification-report.schema.json`.
The companion template is intentionally `partial`, `ok=false`, and `not_run`.
Every row records the contracts exercised and raw per-case artifacts; a Boolean
matrix is invalid and cannot close a gate. The formal closure object separately
requires source-parent containment and requester authority to be atomic with
capture; its template value is false because the current implementation does
not meet that predicate.

The current completion checker validates schema, provenance, hashes, ledger
membership, source-manifest freshness, and structural consistency. It does not
yet interpret a generic aggregate transcript well enough to bind every case,
role, iteration, barrier, mount observation, crash phase, fixture assertion,
and formal argument to distinct machine-readable harness facts. Until the
harness emits those bindings and the checker enforces them, this limitation is
an open release requirement and no passing qualification report is authorized.

## Process and fixture rules

- Record active branch, exact HEAD, `origin/main`, app/helper CDHashes,
  designated requirements, provisioning/signing identities, macOS build,
  machine identity, APFS mount flags, and helper effective UID.
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

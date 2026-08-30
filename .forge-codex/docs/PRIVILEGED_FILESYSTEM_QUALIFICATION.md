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
| `atomic_swap_source_leaf_before_capture` | Swap the expected leaf immediately after the last source observation but before capture. At most one current entry is temporarily captured; no substituted entry is terminally deleted, and disposition is truthful. |
| `atomic_swap_source_leaf_during_capture` | Continuously swap two regular leaves around the capture syscall. Each iteration deletes only the identity that satisfies the recorded contract or returns conflict/recovery; outside sentinels survive. |
| `atomic_swap_source_leaf_after_capture` | Attempt source-name swaps after capture. The protected captured occupant cannot be opened or substituted and terminal disposition remains bound to its recorded identity. |
| `atomic_swap_parent_before_capture` | Swap or rename an intermediate/final parent before capture. Descriptor and recorded-parent checks reject or operate only under the pinned authorized parent; no outside tree changes. |
| `atomic_swap_parent_after_capture` | Move/replace the source parent after capture and before recovery/rollback. Commit, exclusive restore, or retained recovery is truthful; nothing restores into a substituted parent. |
| `atomic_swap_rollback_destination_occupied` | Occupy the original name before rollback. `RENAME_EXCL` preserves both occupants and retains the protected entry with a queryable receipt. |
| `atomic_swap_special_leaf_before_descriptor_open` | Swap a FIFO, socket, device, or directory between precheck and descriptor open while supplying crafted expected identities. Only regular files/symlinks are accepted; no special entry is deleted. Record that metadata-only/event descriptors mitigate but do not establish an identity-conditional syscall. |
| `authorization_metadata_change_after_final_check` | From a retained descriptor or hard link, change ACL/BSD flags after the final helper check and before unlink. The observed outcome and maximum impact are recorded; any deletion after newly restrictive ACL metadata keeps E2 open. |
| `crash_at_every_durable_phase` | Kill the daemon before/after intent write+fsync, capture, source/slot fsync, captured phase, unlink, slot fsync, committed phase, rollback phase, restore, and receipt cleanup. Each restart reaches commit, exclusive restore, retained recovery, or truthful conflict without silent loss. |
| `daemon_restart_and_idempotent_recovery` | Repeatedly restart the daemon and resubmit/query the same transaction. Exactly one mutation occurs and the same terminal result is returned. |
| `manager_restart_and_idempotent_recovery` | Kill/restart manager and app after submission and after reply loss. The original transaction ID remains usable; no duplicate mutation occurs. |
| `local_ownership_enforced_apfs` | Qualified local writable APFS with ownership enabled performs the supported operation and confirms namespace/receipt durability. |
| `external_volume_rejected` | External-volume classifications match observed mount/device capabilities; unsupported cases fail before mutation. |
| `removable_volume_rejected` | Removable media that cannot meet namespace, ownership, primitive, or durability requirements fails closed and truthfully. |
| `network_volume_rejected` | Network filesystems fail before transaction creation. |
| `ignore_ownership_volume_rejected` | APFS with ownership disabled/ignored fails before transaction creation. |
| `cross_volume_destination_durable_before_source_destruction` | When cross-volume support is implemented, destination content/metadata and parent durability are verified before source capture is terminally destroyed. Until then the operation is unsupported with source unchanged. |
| `approval_and_denial` | Not registered, awaiting approval, explicit denial, approval, and revoked approval map to exact typed states with no fallback or shell-policy change. |
| `upgrade_unregister_reregister` | Upgrade, unregister, asynchronous reap completion, re-register, daemon replacement, and stale installed-version scenarios retain or recover transactions. The old daemon cannot service a post-upgrade mutation, and same-connection protocol/product/identifier/root-UID mismatch fails before request submission. |
| `same_connection_service_version_handshake` | Protocol, product version, daemon identifier, root effective UID, and helper identity are checked on the same XPC connection before mutation submission. Field mismatch, identity mismatch, and reply loss before submission preserve the source and do not claim recovery; reply loss after submission returns the original transaction ID. The current path-SHA handshake is supporting diagnostics only and cannot pass this row by itself. |
| `caller_sealed_helper_code_identity` | Each main caller executable obtains its expected per-architecture helper CodeDirectory hash set from its own signed mapped code or kernel-attested entitlement. Before connection activation, the daemon designated requirement is conjoined with the exact `cdhash` set. Two same-team/same-identifier/same-version helpers with distinct hashes prove expected-live acceptance and stale-live rejection before `deleteLeaf`. Replacing the helper path after expectation creation cannot authorize the wrong mapped daemon. If whole-product rollback remains possible, its maximum root-daemon impact and required monotonic root-owned receipt remain explicit. |
| `app_manager_cli_helper_packaging` | The signed GUI app, installed login-manager app, installed raw CLI, and standalone CLI all resolve the same signed expectation and helper relationship without environment/config/argument path authority. The full app contains the helper and LaunchDaemon plist; the manager is not silently synthesized as an ad-hoc privileged-service owner. Caller-relative `SMAppService.notFound` does not prevent an otherwise authenticated raw client from probing the registered service, and missing/tampered/symlinked artifacts fail closed. |
| `settings_status_and_control` | Signed native Settings shows actual service state and registration controls; observed changes survive app and manager restart. |
| `tampered_or_wrong_signature` | Tampered nested code, wrong helper identifier/team/certificate, wrong client identity, and broken enclosing seal are rejected. |
| `source_leaf_substitution` | Repeated hostile source substitutions cover regular file, symlink, directory, missing name, metadata change, and identity reuse attempts with truthful bounded outcomes. |
| `hard_link_behavior` | Preexisting hard links and newly created hard links cannot silently satisfy an exact-content contract. Namespace-only behavior and surviving aliases are reported explicitly or rejected. |
| `writable_file_descriptor_behavior` | A writable descriptor retained before capture mutates content/metadata at every barrier. Exact-content requests fail unsupported/conflict; no immutable-content claim is made. |
| `no_same_uid_fallback` | Disable, kill, deny, mismatch, and corrupt the helper/namespace. Every protected mutation returns its typed error and the legacy same-UID mutation path is never called. |
| `shell_nonregression` | The established synchronous `/bin/bash -lc` `shell_exec` contract remains enabled by default and functional; clean-profile `bash.run` remains additive and nonprivileged through install, denial, helper restart, app restart, and manager restart. |

## Closure rule

Even a fully executed matrix cannot close E2 while an identity-conditional
terminal mutation or equivalent formal boundary is unproved. The qualification
report must state whether residual risk is eliminated or merely mitigated and
must give the maximum possible impact. If any residual remains, the report must
remain nonpassing, `FC-FILESYSTEM-PATH-TOCTOU-001` must remain open, and P10,
G10, and G12 must not pass.

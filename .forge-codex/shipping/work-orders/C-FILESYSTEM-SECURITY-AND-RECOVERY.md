# C — Close privileged filesystem safety and feature gaps

**Priority:** release-critical. This work must produce a defensible implementation and signed runtime evidence, not another claim that quarantine eliminates a race.

## Inspect and reproduce first

Read `Sources/ForgeFilesystemDaemon/PrivilegedLeafDeleteEngine.swift`, its daemon entrypoint, `ForgeFilesystemProtocol`, `SecureFilesystemService`, `SecureFilesystemRecoveryLedger`, authorization/binding/reset code, tool routing, and the existing `.forge-e2` qualification requirements. The source map here is an entry point, not a substitute for reading the implementation.

Reproduce the currently documented parent-relocation/outside-root mutation in disposable fixture trees on a supported test volume. Also inspect pre-capture replacement, ACL/BSD-flag changes, hard links, writable descriptors, caller-ledger loss/replacement, generation reset, retained-slot exhaustion, and terminal-receipt/physical-leaf disagreement. Use the existing nonshipping signed qualification harness/adversary and recorder. Do not run adversarial operations against the operator's home, projects, external backups, or live content.

Document the precise authority and operation semantics. Current-entry selection, namespace-version-exact selection, and content-version-exact selection are different contracts. A root daemon must not trust an unverified client-supplied path/descriptor as sufficient authorization for a mutation. Rechecking a mutable path before a later syscall does not establish atomic containment. A recorded identity is not necessarily the identity consumed by a later name-based syscall.

## Repair outcomes required

1. Establish independently verified manager/project/generation authority for bindings and every accepted mutation. Correct parent-relocation containment, not just its diagnostic wording. Evaluate narrower privilege separation and protected transaction ownership where useful, but preserve supported tool contracts. An alternate design is a hypothesis until it passes the same adversarial predicates. Do not claim an atomic identity-conditional syscall exists without verifying it on the actual supported platform.
2. Make startup recovery an admission barrier before new mutations. Repair or conservatively retain terminal receipts whose protected physical leaf contradicts the recorded outcome; never infer completion solely from path absence or blindly redispatch after a lost response.
3. Provide authenticated daemon-owned discovery/revocation and durable recovery reachability so same-UID caller-ledger disappearance cannot silently preserve stale authority through generation reset. Keep lifecycle operations bounded and exact to requester/project/generation/transaction.
4. Complete an explicitly authorized recovery/disposition lifecycle for retained slots and bindings. Do not automatically purge a protected entry to free capacity. Test full capacity, restart, conflicts, cleanup authorization, recovery handles, and exactly acknowledged terminal records. Retained data is not successful deletion.
5. Complete and qualify the previously promised `fs_move` and recursive directory `fs_delete` capabilities through the protected production route, including cross-volume behavior where required by the actual feature contract. Preserve existing names and result semantics with a tested additive protocol migration where necessary. Their existing unavailable result is not an acceptable success-path test.

Do not silently disable shell or other capabilities to simplify containment. Shell authorization and the privileged filesystem contract have different trust properties; do not claim the filesystem tool is safe because the user could separately run a destructive shell command. Do not use a same-UID fallback, ad-hoc signer, broadened roots, bypassed ACL checks, or weakened sentinel assertions.

## Signed qualification

Execute the existing 57-row E2 matrix and its formal predicates, with exact processes, signing identities, fixture digests, volumes, barrier hits, iterations and crash points. Implement missing rows as actual runnable scenarios. Prove invalid callers, wrong identifier/team, stale/mismatched helper, service approval/denial, upgrade/disable/restart and transaction reconciliation with the exact installed artifact. Confirm the final G10/completion path actually consumes the E2 validator rather than trusting a hand-set status. The repository record says that integration was incomplete; inspect current code before modifying it.

Crashes must be injected at every durable phase and during reset/update; restart must reconcile actual disk state before accepting new work. All intended outside-root sentinels must remain unchanged. A controlled denial is valid for a negative case, not proof that a promised supported operation works. Maintain separate evidence for residual risks and qualified behavior.

## Failure policy

By the early feasibility checkpoint, provide a concrete reproducer and a narrow repair design. After three no-progress attempts, change strategy, isolate the boundary, or get a focused independent review; do not endlessly revise evidentiary prose. Continue provider/UI/build work while this gate is blocked. Do not claim it cannot be addressed merely because the primitive/design is difficult, and do not pretend it has been solved without proof.

Any unresolved high/critical containment, privilege, data-loss, recovery, or feature-preservation issue blocks shipment. Scope reduction or threat-model changes need an explicit owner decision and cannot silently convert existing gates to passed.

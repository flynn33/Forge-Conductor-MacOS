# E2 Closure Argument and Claim Boundary

## Finding being closed

`FC-FILESYSTEM-PATH-TOCTOU-001` exists because an attacker can change a final
namespace entry after Forge validates it but before Forge mutates that name. Pinned
ancestor descriptors reduce the surface but do not make two syscalls atomic.

## Safety properties

Codex must prove these properties, not merely show passing happy-path tests.

### S1 — Root confinement

Every model-facing filesystem request is bound to one project ID, one project
generation, one persisted root identity, and root-relative components. Every ancestor
opened for mutation is reached from the pinned root descriptor with beneath/no-follow
resolution. Therefore no component replacement can redirect the operation outside the
selected root.

### S2 — No wrong-object destruction

The authorized source leaf is never inspected and later destructively mutated by name.
For current-entry contracts, one atomic rename captures the current directory entry.
For exact-version contracts, validation occurs after capture, and a mismatch is restored
or quarantined. Therefore a replacement object cannot be mistaken for a previously
validated object and destroyed.

### S3 — No destination overwrite

Every no-overwrite publication uses an exclusive atomic rename to a validated leaf under
a pinned destination parent. A competing destination wins with `EEXIST`; Forge does not
replace it.

### S4 — Captured traversal cannot escape

After root capture, recursive traversal begins from a descriptor to the private
transaction namespace. Entries are opened relative to already-open directories and
symlinks are never traversed. A project-tree rename cannot retarget the traversal.

### S5 — Crash-safe effect accounting

Each irreversible syscall has a persisted intent and a namespace-derived receipt.
Recovery observes actual source/capture/destination state before retrying. Therefore a
crash cannot cause blind republish, wrong cleanup, or a false cancellation report after
commit.

### S6 — Generation isolation

All capabilities and transactions carry project generation. Reset increments the
generation and fences stale operations. Therefore a delayed old request cannot recreate
or mutate state in a reset project.

## Liveness properties

- Bounded retries either commit, restore, quarantine, or return a truthful terminal
  conflict.
- One project's quarantine limit blocks only new destructive work for that project.
- Recovery is paged and lease-controlled; it does not build an unbounded in-memory
  transaction list.
- Cancellation is honored before irreversible boundaries. After a boundary, Forge
  reconciles and reports the committed or preserved result.

## Formal linearization points

| Operation | Linearization point |
|---|---|
| current-entry delete | source-to-transaction atomic rename |
| current-entry same-volume move | source-to-destination atomic rename |
| create-only write | exclusive staged-file publication |
| replace/edit | atomic swap of staged and current entries |
| cross-volume move | exclusive destination publication; source disposal is a later recoverable phase |
| exact-version conflict | capture followed by verified restore or durable quarantine receipt |

## What the closure does not claim

The public macOS APIs do not expose a general conditional
“unlink/rename only if this name still denotes inode X” primitive. The implementation
therefore does not claim:

- kernel compare-and-swap semantics for arbitrary existing entries;
- invisibility of an edit replacement that is swapped and then rolled back after a
  version mismatch;
- OS isolation from another unrestricted process running as the same user;
- immutable content while an external hard link remains writable;
- protection against a malicious shell process outside a sandbox.

Those are different security properties. Forge must label `workspaceIsolated` as
application-level confinement, retain shell functionality, and reserve stronger claims
for a separately signed and qualified sandbox/XPC execution mode.

## Evidence required to close the finding

1. A test reproduces the old compare/mutate interleaving.
2. Source review proves no authorized mutation retains that pattern.
3. API probes pass on every release filesystem class.
4. Atomic-swap adversarial tests leave outside-root sentinels unchanged.
5. Exact-version mismatch tests prove restore or preserved quarantine.
6. Kill/restart tests recover every nonterminal state.
7. Existing feature and tool-contract suites pass.
8. Shell remains enabled and compatible.
9. The final security review accepts S1–S6 and records the nonclaims above.

Only then may the state ledger remove the open finding and record an E2 closure receipt.

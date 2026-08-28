# Security and Privacy Boundaries

## Inputs

Treat MCP requests, project paths, model/provider data, subprocess output, imported memories, and handoff documents as untrusted.

Validate:

- maximum encoded size;
- required schema version;
- string and collection limits;
- allowed project identity;
- path containment;
- identifier format;
- timestamps and numeric ranges;
- transport authentication where applicable.

## Project path safety

Resolve symlinks and standardize paths. Operations must remain inside the authorized project root or Forge application-support directories. Reject traversal and alias confusion.

Session bindings and continuity packets may narrow access to a configured root, but they never create a new authorization root. Project shell tools are enabled by the corrected schema-v2 local policy and expose an explicit native opt-out. `shell_exec` still requires an authorized project root, and a working directory alone is not treated as confinement for a general shell.

## Secrets

- Use the existing secure store or Keychain for credentials.
- Never persist tokens in memory records, handoffs, logs, test fixtures, or crash evidence.
- Redact environment variables, authorization headers, command arguments, and provider errors.
- Memory ingestion performs pattern and source-aware redaction before persistence.
- Tests include representative secret formats.

## MCP transport

- Stdio inherits process trust but still validates messages.
- Local sockets bind to loopback and use authentication tokens/permissions.
- Remote listening is disabled unless an existing explicit product feature requires it.
- Apply request deadlines, cancellation, rate limits, and maximum concurrency.
- Return typed errors without internal file contents or secrets.

## Database/files

Use least-privilege file permissions. Prevent another project from opening a memory store by path substitution. Export is explicit, checksummed, and redacted according to policy.

Migration pathname checks cover stable moved-file substitutions and
cooperating processes. The current macOS VFS also fails closed in the tested
A-to-B-to-A restoration cycle, but sequential observations are not an atomic
security boundary. Hostile same-user namespace substitution and direct
mutation of owner-controlled database files remain excluded unless a custom
SQLite VFS pins the database family and/or an independent privilege boundary
prevents same-owner mutation.

### Identity-conditional filesystem mutation

The filesystem mutation requirement is stronger than path containment: after
Forge verifies that `(parent descriptor, final-component name)` identifies the
expected object, the terminal unlink or rename must apply only if that name
still identifies the same object at the mutation instant. A same-user process
can otherwise exchange directory entries between verification and mutation.
The public macOS interfaces evaluated here do not accept an expected device,
inode, generation, or open file descriptor as a precondition to unlink or
rename a final component.

| API or flag | Guarantee provided | Identity-conditional mutation evaluation |
| --- | --- | --- |
| `openat` with a directory descriptor, `O_SEARCH`, `O_NOFOLLOW_ANY`, and `O_RESOLVE_BENEATH` | Pins a searchable directory and prevents symlink traversal or resolution above that starting directory. | Selected for parent and intermediate-directory anchoring. It does not pin the binding between a final-component name and a leaf for a later mutation. macOS has no `unlinkat(..., AT_EMPTY_PATH)` equivalent that removes the object named by an already-open leaf descriptor. |
| `openat(..., O_UNIQUE)` | Refuses a leaf that has more than one hard link. | Not an identity predicate. A competing single-link object can still replace the name, and rejecting valid hard-linked project content would change established behavior. |
| `fstat`, `fstatat`, and `AT_SYMLINK_NOFOLLOW`, `AT_SYMLINK_NOFOLLOW_ANY`, `AT_RESOLVE_BENEATH`, or `AT_FDONLY` | Observe descriptor or descriptor-relative status and can constrain lookup. | Used for device/inode/type/owner/mode/link-count/timestamp comparisons, but the result is a snapshot. None combines the comparison with a later unlink or rename. |
| `readlinkat` and descriptor-relative content/digest reads | Read a symlink value or content through a pinned parent without depending on the process working directory. | Useful verification evidence only. The verified name can be rebound before the terminal namespace syscall. |
| `unlinkat(parentFD, name, ...)` with `AT_REMOVEDIR`, `AT_SYMLINK_NOFOLLOW_ANY`, or `AT_RESOLVE_BENEATH` | Removes the entry currently named relative to the pinned parent; flags constrain type and traversal. | Selected for the terminal removal of a quarantined entry. It has no expected-identity operand and therefore removes the current occupant of that quarantine name. |
| `unlinkat` with `AT_UNIQUE` or `AT_NODELETEBUSY` | `AT_UNIQUE` rejects multiply linked vnodes; `AT_NODELETEBUSY` rejects a vnode with open descriptors. | Neither compares the current occupant with the object Forge verified. Keeping Forge's expected leaf descriptor open makes the desired `AT_NODELETEBUSY` removal fail; closing it restores the race. Both flags also exclude valid states rather than conditionally mutating the verified identity. |
| `renameat` or `renameatx_np` with pinned source and destination parents | Atomically renames the entries occupying the supplied source and destination names. `RENAME_EXCL` prevents destination overwrite. | Selected with `RENAME_EXCL` for quarantine, rollback, and publication. Exclusivity protects the destination but the source operand still means whichever object occupies the source name when the syscall resolves it. |
| `renameatx_np(..., RENAME_SWAP)` | Atomically exchanges the current occupants of two names; it cannot be combined with `RENAME_EXCL`. | Required for the adversarial tests and not a defense. It demonstrates the exact substitution primitive, but takes no expected source identity and may exchange files with directories. |
| `RENAME_NOFOLLOW_ANY` and `RENAME_RESOLVE_BENEATH` | Reject symlink traversal and resolution outside the starting hierarchy. | Useful confinement controls, but neither supplies an identity precondition for either final component. |
| `RENAME_SECLUDE` | The current SDK exposes the flag, while the installed `rename(2)` manual does not document its user contract. Public XNU describes its internal condition as refusing rename when the selected source is hard-linked, open, or memory mapped. | Not selected. The condition applies to the source object resolved at syscall time, has no expected-identity argument, is not a portable documented contract for supported filesystems, and would reject the evaluated open-leaf-descriptor strategy. Closing that descriptor restores the substitution window. |
| `fsync` on pinned parent descriptors | Makes completed namespace changes durable according to the filesystem contract. | Selected for crash durability. It cannot make the preceding verification and mutation atomic or validate which leaf was mutated. |

The selected mitigation is bounded quarantine-and-verify. Before the initial
rename, Forge durably creates one immutable owner-only receipt in a global
32-slot ledger under the active `AppPaths.home`. After a two-second-bounded
thread/process lock acquisition, it uses a pinned parent and
`renameatx_np(..., RENAME_EXCL)` to move
the current occupant to that slot's deterministic same-parent
`.forge-quarantine-v1-NN` name and synchronizes the parent. Invalid receipts,
unavailable or rebound parents, and retained quarantines consume their slot;
no UUID-named quarantine or receipt temporary is created. Reconciliation runs
before every reservation and best-effort at application startup. These rules
bound Forge-created retained quarantines to 32 per Forge home across
cooperating Forge processes and ordinary process crashes.

After quarantine, direct delete and publication paths reverify the recorded
device, inode, type/mode, owner, and group identity. Cross-volume source
cleanup additionally reverifies its bounded metadata and content fence. A
mismatch triggers an exclusive rollback only when the quarantine occupant still
has the receipt's recorded leaf identity; otherwise Forge refuses to restore a
substituted object and retains the slot for recovery. Terminal unlink,
publication, and rollback execute under the same scoped ledger lock as the last
descriptor-relative quarantine check; affected pinned parent descriptors are
synchronized before the immutable receipt is removed. A failed rollback,
unconfirmed terminal durability, or live-present/unverifiable receipt-cleanup
failure retains a fixed slot and surfaces its receipt or quarantine recovery
path. If a publication commits but the requested namespace is no longer stable
and terminal durability is also unconfirmed, the failure result preserves the
live receipt path and explicitly requires ledger recovery. If receipt unlink
succeeds but the subsequent ledger-directory `fsync`
fails, no live recovery path is claimed: the terminal namespace durability is
reported independently, and a stale receipt may conservatively reappear and
occupy its bounded slot after a crash.

This is mitigation, not elimination. A same-user adversary can alter the
owner-controlled ledger, move a quarantined parent, or discover the quarantine
name and exchange its occupant after the final quarantine
verification but before `unlinkat` or the final `renameatx_np`. Each winning
race can make one terminal syscall mutate one substituted directory entry.
For unlink, that entry may be the substituted file's final link, so the amount
of data lost is not byte-bounded. For rename, the substituted entry may be a
directory, so one entry can relocate a subtree whose bytes and descendant
count are not bounded by the mutation cap. `RENAME_EXCL` prevents overwriting
an existing destination. A recursive request can reuse released slots and expose
as many as 100,000 planned entries to separate winning races; the 32 slots do not
bound cumulative wrong-object mutations. The cross-volume move/reconciliation
path has a 300-second operation deadline, but a terminal namespace syscall or
`fsync` already executing while the ledger lock is held has no independent
wall-time deadline. These limits do not bound the bytes or subtree reachable
through one substituted entry. The 32-slot bound is
an accumulation bound for cooperating Forge processes and crashes, not an
adversarial identity guarantee: a same-UID writer can remove receipts or move
quarantines outside their recorded basenames. Path-based initial anchoring,
destination-hierarchy construction, and the narrow hard-link ctime refresh
interval are additional residuals. `FC-FILESYSTEM-PATH-TOCTOU-001`
therefore remains open as E2 pending an actual identity-conditional terminal
mutation primitive or an independent privilege boundary.

The adversarial regression matrix uses atomic `RENAME_SWAP` at the exact
pre-quarantine verification window for direct recursive deletion, same-volume
move, cross-volume staging publication, and cross-volume source cleanup. Those
tests prove the bounded mitigation fails closed at the exercised windows. A
separate post-quarantine substitution regression proves rollback refuses an
occupant whose identity differs from the receipt. These tests mitigate specific
windows; they do not prove the residual final verifier-to-terminal-syscall
window unreachable. Two additional publication regressions atomically destabilize
the destination after rename while forcing directory synchronization to fail;
they prove that same- and cross-volume results retain their live recovery receipt
under the combined namespace-instability and durability-unconfirmed state. A
cross-volume cleanup-failure variant proves that an additional retained staging
receipt is merged into the same bounded recovery result rather than suppressed.

API interpretation is based on the installed macOS `open(2)`, `stat(2)`,
`readlink(2)`, `unlink(2)`, and `rename(2)` manuals and SDK headers. The
`RENAME_SECLUDE` limitation is cross-checked against Apple's public
[`namei.h`](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/sys/namei.h)
and [`renameatx_np` implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_syscalls.c).

## Managed runtime execution

Managed shell and interpreter jobs execute only through the native runtime launcher. Production app and CLI builds require an exact, signed product identity, enclosing application seal where applicable, and a matching staged-helper code-directory hash. Exact-path, ad-hoc SwiftPM pairings are accepted only for local development products with allowlisted identifiers; they are not distribution authority.

Each job has independently authorized canonical read and write roots. Write roots must be a subset of read authority. Manager-owned stdout and stderr artifacts are outside the child-writable scratch directory. Artifact reads revalidate the regular-file type, owner, link count, device, inode, bounded size, and digest so replacement or mutation fails closed.

The launcher applies bounded CPU, descriptor, output-file, and core-dump limits before execution. Runtime discovery uses semantic, deadline-bounded probes rather than executable presence alone. Jobs run in isolated process groups under a deny-default profile, with bounded descendant census and a configured descendant limit. Termination phase and exact process identity are durable; shutdown and restart recovery continue bounded TERM, KILL, and liveness probing until group death is confirmed. An unconfirmed group remains owned and prevents stores from closing underneath the reaper.

## Plugin boundary

Host plugins receive only capabilities and data required for session creation. They do not gain arbitrary project filesystem access by default. Provider credentials remain behind a secure client abstraction.

## Logging

Use `Logger` with stable subsystem/categories and privacy annotations. Never use raw prompt/document body values in logs. Signposts use IDs and sizes, not content.

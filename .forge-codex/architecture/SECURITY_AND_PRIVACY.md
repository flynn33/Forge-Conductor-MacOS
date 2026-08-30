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

### Privileged filesystem service boundary (qualification in progress)

The approved E2 policy requires a different-identity mutation boundary rather
than a narrower same-UID threat model. The selected architecture is an
app-bundled LaunchDaemon registered explicitly by the user through
`SMAppService.daemon(plistName:)`. The daemon is separately signed, runs as
root, has no shell, process-launch, network, or arbitrary-absolute-path
surface, and receives authorized root directory descriptors plus bounded
relative components. A root-owned mode-0700 transaction namespace on the same
qualified volume becomes the only location from which a terminal unlink may
occur. The manager has no same-UID production fallback: unavailable,
unapproved, identity-mismatched, unqualified-volume, or unavailable-namespace
states return their required typed errors.

Root execution is not authority to exceed the authenticated caller's ordinary
filesystem power. The current daemon binds each accepted NSXPC connection to
its non-root effective UID, persists that UID in both the project binding and
transaction record, and requires an exact match on rebind and recovery. The
authorized root and every traversed directory must be requester-owned,
ACL-free, and owner-searchable; the final parent must also be owner-writable.
The source leaf is descriptor-opened and rejected if it has an extended ACL or
any immutable, append-only, restricted, or no-unlink BSD flag. Those leaf
checks run before intent, immediately before capture, after capture, during
recovery, and immediately before terminal unlink. This deliberately excludes
shared, delegated-ACL, root-owned, and group-authorized trees until an
equivalent caller-permission decision can be proved.

The first implementation scope is non-directory leaf deletion on a local,
writable, ownership-enforced APFS volume. Directory deletion, same-volume move,
cross-volume move, and exact-content guarantees remain disabled until their
own recovery and adversarial matrices pass. This is an additive security
boundary; it does not grant privileges to `shell_exec`, `bash.run`, or any
runtime tool.

| API or facility | What it provides | Why it is or is not sufficient |
| --- | --- | --- |
| `SMAppService.daemon(plistName:)` | Signed app-contained LaunchDaemon registration, admin approval state, launchd lifecycle, and explicit unregister/re-register update behavior. Apple documents that a changed LaunchDaemon plist or executable must be re-registered and recommends unregister-before-register for an executable change; the asynchronous unregister completion is the safe point at which the old process is known to be killed before replacement registration. | Selected for lifecycle only, with an explicit reinstall operation using that completion boundary. It does not authorize a filesystem request or make a namespace mutation identity-conditional. Release use also requires the signed/notarized app and helper upgrade lifecycle to be qualified. |
| `NSXPCConnection(machServiceName:options:.privileged)` and `NSXPCListener(machServiceName:)` | A launchd-managed privileged transport. The current `setCodeSigningRequirement` and `setConnectionCodeSigningRequirement` expressions reject peers outside the enumerated app or manager/CLI client identifiers and daemon identifier, active team, and certificate class. Before sending a mutation on that same connection, the client also checks the reported protocol version, product version, service identifier, root effective UID, and a path-derived helper SHA-256 against the regular non-symlink helper under the current GUI bundle. | Selected as the partial connection boundary, not an exact live-code boundary. The reported digest is computed from mutable paths by both processes and is not kernel-attested mapped-code identity. A same-team, same-identifier, same-version older daemon can remain admissible if the expected user-writable helper path is rolled back to matching bytes. The maximum impact is that daemon's full bounded root mutation authority and vulnerabilities. The installed manager and raw CLI also lack a caller-relative plist/helper in the current package and fail closed before useful XPC. Closure requires caller-sealed per-architecture CodeDirectory hashes composed into the peer requirement, full app/manager/CLI packaging, and signed process evidence. Public `NSXPCConnection` exposes PID, effective UID/GID, and audit-session identifiers, but not the received message's full audit token, so connection checking still does not satisfy per-message audit identity. |
| Low-level XPC `xpc_peer_requirement_match_received_message` and Security.framework `SecCodeCreateWithXPCMessage` | macOS 26 can bind a check to the audit token attached to the particular received XPC dictionary. | Required for final per-message identity qualification through a narrow C interoperability layer. Until this is integrated and tested against differently signed and unauthorized clients, E2 remains open. PID-only lookup is not accepted because PID reuse breaks message identity. |
| Root directory descriptors plus `openat`, `fstatat`, `renameatx_np`, `unlinkat`, directory `fsync`, and `fcntl(F_FULLFSYNC)` | Descriptor-relative confinement, independent root/source identity checks, exclusive capture, protected terminal deletion, and stronger local-media phase flushes. | Selected inside the daemon. Plain `fsync` alone does not promise power-loss ordering on macOS, so each durability boundary also requires `F_FULLFSYNC`; the signed crash and power-loss qualification is still open. None of these calls alone accepts an expected inode as a mutation precondition; the security property comes from exclusive capture into the protected namespace followed by verification there, not from treating any one syscall as identity-conditional. |
| `connection.effectiveUserIdentifier`, descriptor ownership/mode checks, `acl_get_fd_np`, and `st_flags` | Conservatively approximate whether the authenticated user could traverse the source hierarchy and remove the leaf without root assistance. | Selected to prevent privilege amplification. Connection UID is never accepted from request data; root, invalid, and non-account UIDs fail closed. This policy is intentionally narrower than all valid macOS permission arrangements and does not replace the still-required per-message audit-token check. |
| `renameatx_np(..., RENAME_EXCL)` | Atomically captures whichever entry occupies the authorized source name while refusing destination overwrite. | Selected for capture. It is not an expected-identity rename. The daemon must verify the captured entry inside the protected namespace before any terminal unlink and retain or exclusively roll it back on mismatch. |
| `renameatx_np(..., RENAME_SWAP)` | Atomically substitutes namespace entries and drives the hostile-process test matrix. | Test primitive only. It proves the pre-capture substitution remains possible and is not a mitigation. |

The remaining race is between the last observation of the authorized source
name and the exclusive capture syscall. A winning same-UID swap can cause the
daemon to capture one substituted namespace entry. The maximum possible impact
of that race is temporary or recovery-required unavailability of that one
entry; because the substituted entry can be a directory, it can represent an
unbounded subtree. The protected-namespace recheck is intended to prevent that
substituted entry from being unlinked, but that protection is not release
authority until the signed hostile-process and crash matrices pass. A writable
file descriptor or hard link can also change or preserve the captured inode's
content independently of its pathname. Therefore the design can qualify the
captured namespace identity, not immutable content, and exact-content requests
fail closed.

A second authorization-metadata race remains after the final protected-leaf
ACL/BSD-flag observation and before `unlinkat`. The inspection descriptor is
closed before the name-based mutation. Another actor retaining a writable
descriptor, hard link, or independent metadata authority can change the
captured inode's ACL or flags in that interval. A newly added restrictive flag
may make unlink fail, but root execution can bypass a newly added ACL denial.
The maximum terminal impact of that race is deletion of the one already
captured expected regular file or symbolic link even though its permission
metadata changed after Forge's last observation; a regular file can contain
unbounded bytes. The protected namespace prevents that interval from being
used to substitute a different pathname occupant. This is an explicit residual
and must be exercised in the signed attacker matrix; the current checks
mitigate it but do not eliminate it.

The current checkpoint is partial. The exact live-helper identity expectation
must be bound into each main caller's signed mapped code or a kernel-attested
caller entitlement, not inferred only from a replaceable helper path or dynamic
framework. `NSXPCConnection` must then require the expected CodeDirectory hash
set before activation. Static outer-bundle validation is useful supplemental
evidence, but Apple's Security framework documents that static validation is
only valid while the filesystem object remains unmodified. Code signing also
does not establish freshness: preventing rollback of the entire validly signed
caller, expectation, and helper requires a monotonic root-owned version receipt.
The normal login-manager package is currently an ad-hoc minimal app without the
daemon or plist, and raw CLI status lookup is caller-relative, so those clients
fail closed. These availability and identity gaps are tracked by
`FC-PRIVILEGED-CALLER-IDENTITY-001`.

Per-message audit identity, signed
adversarial and crash recovery, full volume behavior, approval/denial,
upgrade/unregister/re-register and stale-helper rejection, signature rejection,
source-leaf/hard-link/writable-FD
behavior, and notarized Release lifecycle evidence are still required. An
ambiguous submitted XPC call now returns its original transaction ID, but the
public filesystem tool does not yet expose a recovery/resume operation that can
consume that ID after the source pathname is absent. Durable recovery therefore
remains an explicit open requirement. The
canonical finding `FC-FILESYSTEM-PATH-TOCTOU-001` (policy alias `FCA-007`), E2,
P10, G10, and G12 remain open. The privileged design mitigates the prior race;
it is not described as eliminating it.

The complete signed-host case inventory and pass predicates are maintained in
[`PRIVILEGED_FILESYSTEM_QUALIFICATION.md`](../docs/PRIVILEGED_FILESYSTEM_QUALIFICATION.md).

## Managed runtime execution

Managed shell and interpreter jobs execute only through the native runtime launcher. Production app and CLI builds require an exact, signed product identity, enclosing application seal where applicable, and a matching staged-helper code-directory hash. Exact-path, ad-hoc SwiftPM pairings are accepted only for local development products with allowlisted identifiers; they are not distribution authority.

Each job has independently authorized canonical read and write roots. Write roots must be a subset of read authority. Manager-owned stdout and stderr artifacts are outside the child-writable scratch directory. Artifact reads revalidate the regular-file type, owner, link count, device, inode, bounded size, and digest so replacement or mutation fails closed.

The launcher applies bounded CPU, descriptor, output-file, and core-dump limits before execution. Runtime discovery uses semantic, deadline-bounded probes rather than executable presence alone. Jobs run in isolated process groups under a deny-default profile, with bounded descendant census and a configured descendant limit. Termination phase and exact process identity are durable; shutdown and restart recovery continue bounded TERM, KILL, and liveness probing until group death is confirmed. An unconfirmed group remains owned and prevents stores from closing underneath the reaper.

## Plugin boundary

Host plugins receive only capabilities and data required for session creation. They do not gain arbitrary project filesystem access by default. Provider credentials remain behind a secure client abstraction.

## Logging

Use `Logger` with stable subsystem/categories and privacy annotations. Never use raw prompt/document body values in logs. Signposts use IDs and sizes, not content.

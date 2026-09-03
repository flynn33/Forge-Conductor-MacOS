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
| `stat.st_gen` | Exposes the filesystem's inode generation value to a superuser on macOS and can strengthen an observed identity tuple when the filesystem supplies a meaningful value. | Evaluated as an additional observation only. It is not an argument to `unlinkat`, `renameat`, or `renameatx_np`; generation reuse semantics remain filesystem-specific, and a matching snapshot can be rebound before a later mutation. |
| `fcntl(F_GETPATH)` and `F_GETPATH_NOFIRMLINK` | Ask the kernel for a pathname associated with an open descriptor. | Useful for diagnostics, not authority. A descriptor may have no usable current path, the returned path is a sequential observation, and neither command mutates nor conditions a later namespace operation on the descriptor's identity. |
| `flock`, POSIX `fcntl(F_SETLK/F_SETLKW)`, and open-file-description `fcntl(F_OFD_SETLK/F_OFD_SETLKW)` locks | Coordinate whole-file or byte-range access among processes that honor the advisory lock protocol. | Used only for bounded cooperating-ledger serialization where applicable. The locks are advisory: a same-UID adversary can rename or unlink without taking them, and the lock has no effect on which occupant a later namespace syscall resolves. |
| `readlinkat` and descriptor-relative content/digest reads | Read a symlink value or content through a pinned parent without depending on the process working directory. | Useful verification evidence only. The verified name can be rebound before the terminal namespace syscall. |
| `unlinkat(parentFD, name, ...)` with `AT_REMOVEDIR`, `AT_SYMLINK_NOFOLLOW_ANY`, or `AT_RESOLVE_BENEATH` | Removes the entry currently named relative to the pinned parent; flags constrain type and traversal. | Selected for the terminal removal of a quarantined entry. It has no expected-identity operand and therefore removes the current occupant of that quarantine name. |
| `unlinkat` with `AT_UNIQUE` or `AT_NODELETEBUSY` | `AT_UNIQUE` rejects multiply linked vnodes; `AT_NODELETEBUSY` rejects a vnode with open descriptors. | Neither compares the current occupant with the object Forge verified. Keeping Forge's expected leaf descriptor open makes the desired `AT_NODELETEBUSY` removal fail; closing it restores the race. Both flags also exclude valid states rather than conditionally mutating the verified identity. |
| `renameat` or `renameatx_np` with pinned source and destination parents | Atomically renames the entries occupying the supplied source and destination names. `RENAME_EXCL` prevents destination overwrite. | Selected with `RENAME_EXCL` for quarantine, rollback, and publication. Exclusivity protects the destination but the source operand still means whichever object occupies the source name when the syscall resolves it. |
| `renameatx_np(..., RENAME_SWAP)` | Atomically exchanges the current occupants of two names; it cannot be combined with `RENAME_EXCL`. | Required for the adversarial tests and not a defense. It demonstrates the exact substitution primitive, but takes no expected source identity and may exchange files with directories. |
| `RENAME_NOFOLLOW_ANY` and `RENAME_RESOLVE_BENEATH` | Reject symlink traversal and resolution outside the starting hierarchy. | Useful confinement controls, but neither supplies an identity precondition for either final component. |
| `RENAME_SECLUDE` | The current SDK exposes the flag, while the installed `rename(2)` manual does not document its user contract. Public XNU describes its internal condition as refusing rename when the selected source is hard-linked, open, or memory mapped. | Not selected. The condition applies to the source object resolved at syscall time, has no expected-identity argument, is not a portable documented contract for supported filesystems, and would reject the evaluated open-leaf-descriptor strategy. Closing that descriptor restores the substitution window. |
| `fsync` on pinned parent descriptors | Makes completed namespace changes durable according to the filesystem contract. | Selected for crash durability. It cannot make the preceding verification and mutation atomic or validate which leaf was mutated. |

The evaluated `renameatx_np` flag set therefore covers `RENAME_EXCL`,
`RENAME_SWAP`, `RENAME_NOFOLLOW_ANY`, `RENAME_RESOLVE_BENEATH`, and
`RENAME_SECLUDE`. The flags provide exclusivity, atomic exchange, traversal
constraints, or source-state exclusions, but none accepts an expected
device/inode/generation tuple or open descriptor as a mutation precondition.

The legacy same-UID filesystem implementation uses bounded quarantine-and-
verify. It remains relevant to nonprivileged compatibility paths and historical
evidence, but it is not the production protocol-v5 protected-delete boundary.
Before the initial
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

For that legacy boundary, this is mitigation, not elimination. A same-user adversary can alter the
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
interval are additional residuals. `FC-FILESYSTEM-PATH-TOCTOU-001` therefore
remains open as E2. The separately privileged boundary described below now
exists in source, but it retains documented authorization, recovery, lifecycle,
and capacity residuals and has not passed its signed distinct-process matrix or
formal closure. Source presence is not qualification.

The adversarial regression matrix uses atomic `RENAME_SWAP` at the exact
pre-quarantine verification window for direct recursive deletion, same-volume
move, cross-volume staging publication, and cross-volume source cleanup. Those
tests prove the bounded mitigation fails closed at the exercised windows. A
separate post-quarantine substitution regression proves rollback refuses an
occupant whose identity differs from the receipt. These tests mitigate specific
windows; they do not prove the residual final verifier-to-terminal-syscall
window unreachable. Deterministic final-window regressions also invoke real
`renameatx_np(..., RENAME_SWAP)` immediately after the ledger's last identity
verifier and before terminal file `unlinkat`, same- and cross-volume destination
publication, source cleanup, and rollback. The exercised outcomes do not report
false success and retain the exact live recovery receipt. That is detection and
recovery-state mitigation, not elimination: the namespace syscall can still
mutate a substituted entry, and a same-UID writer can race the sequential
post-mutation observation as well as the preceding verifier. Directory unlink
has no equivalent link-count observation and remains disabled in the production
secure-client path. One winning unlink race can remove a substituted file's
final link with no byte bound; one winning rename race can relocate a substituted
directory with no bound on subtree bytes or descendants. The deterministic unit
matrix does not substitute for the signed 57-row distinct-process qualification,
so `FC-FILESYSTEM-PATH-TOCTOU-001` remains E2.

Two additional publication regressions atomically destabilize the destination
after rename while forcing directory synchronization to fail; they prove that
same- and cross-volume results retain their live recovery receipt under the
combined namespace-instability and durability-unconfirmed state. A cross-volume
cleanup-failure variant proves that an additional retained staging receipt is
merged into the same bounded recovery result rather than suppressed.

API interpretation is based on the installed macOS `open(2)`, `stat(2)`,
`readlink(2)`, `unlink(2)`, `rename(2)`, `fcntl(2)`, and `flock(2)` manuals
and SDK headers. The
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

ServiceManagement lifecycle changes use a separate durable fail-closed fence.
Forge writes an owner-only, atomically replaced Enable, Disable, or Update
intent before the corresponding registration or unregister side effect. One
descriptor-backed, nonblocking `flock` lease is retained across the complete
synchronous register worker or asynchronous unregister callback, including
after caller timeout or cancellation. Disable and Update use the completion-
handler form of `SMAppService.unregister`; the synchronous form is not used by
the Settings production path because its return does not mean the prior daemon
has been reaped. A timeout or Swift task cancellation does not pretend to cancel
the operating-system request. Lifecycle mutation, approval, and recovery-ledger
Reconcile controls remain disabled, while read-only Refresh remains available.

Every recovery has a fresh attempt identifier under the same durable operation
identifier and is capped at eight attempts. Record transitions require the exact
attempt plus the recorded lock device and inode. Recovery must first acquire the
same lease, so a cooperating Forge process cannot take over while the predecessor
is live. A late successful Update reap advances only to
`registration_pending`; it does not register from the stale callback. The next
lease owner may register from that durable phase. Startup executes at most the
two bounded phases required for Update recovery (reap, then register). An active
attempt whose expected record is missing or mismatched fails closed. Malformed,
non-regular, multiply linked, or unavailable state/lock files also fail closed.
Callback-before-uncertainty ordering uses one single-slot in-memory tombstone
containing at most the exact reconciled attempt identifier; it is cleared when
that attempt's delayed uncertainty write observes it and is never a history.

Pathname replacement remains an E2 same-UID namespace risk. Exact attempt and
lease-inode checks detect a replaced record or lock observed by the current
owner, and one stable descriptor lease limits each cooperating lease owner to
one ServiceManagement side effect at a time. An untampered operation lineage is
capped at eight total attempts, and one automatic bootstrap is capped at the two
durable phases needed to recover Update (reap, then register). Those are local
bounds, not a global adversarial bound. `flock` is advisory, and no evaluated
macOS filesystem API makes replacement of both pathname objects identity-
conditional. A hostile same-UID peer can repeatedly install coherent fresh
record and lock pathnames with fresh operation and attempt identifiers and an
independent lock inode. It can therefore authorize sequential and potentially
concurrent lifecycle requests without limit over time despite the per-lineage
and per-bootstrap caps.

The maximum residual impact is consequently one side effect per cooperating
lease owner, eight side-effect attempts per untampered lineage, and two
automatic recovery phases per bootstrap, but no finite maximum across repeated
hostile coherent namespace replacement. Repeated wins can produce indefinite
service registration/unregistration churn and persistent uncertainty requiring
trusted repair. They add no direct protected-filesystem mutation authority;
that remains confined to the separately authenticated privileged request
boundary. The stable lease mitigates overlapping requests from cooperating
processes, but does not eliminate replacement by a peer that bypasses the
namespace protocol. After process death, deletion of the only record is
indistinguishable from a normally settled state; that crash-window removal is
part of the same open E2 residual.

Startup service health collection is read-only: it calls operational health
with `reconcile: false`. Enable, Disable, Update, lifecycle recovery, and Refresh
also observe recovery debt without releasing it. Only the explicit **Reconcile
recovery** control invokes identity-verifiable fixed-slot debt reconciliation.
Automatic lifecycle recovery is limited to the two durable ServiceManagement
phases and does not alter either filesystem recovery ledger. These controls
mitigate overlapping service lifecycle requests. Native `SMAppService`
registration/unregister/restart behavior, distinct signing, approval UI, and E2
filesystem-boundary evidence remain deferred and release-blocking; component,
stub, and nested-xctest process results do not satisfy those native gates.

The qualification-report checker is not itself boundary proof. Report schema
v2 and artifact-binding schema v1 bind every recorder-preserved read-only JSON
snapshot to its qualification and evidence identifiers, current source
manifest, case, role, iteration, subject or formal predicate, and the canonical
digest of the exact report fact. A dedicated context envelope binds the exact
report timestamp, repository, host, process, and same-UID declarations. Before
child launch, the recorder captures the branch, execution HEAD, canonical base
`main`, exact required `refs/remotes/origin/main` SHA, canonical repository
path, macOS build, hardware model, platform, and architecture. The base must be
an ancestor of the execution HEAD, which must remain an ancestor of current
HEAD. Every intervening commit may touch only `.forge-codex/state/**` or
`.forge-codex/evidence/**`, and source-manifest targets must be clean in the
worktree. Thus state-and-evidence transport is allowed without permitting a
product, script, or arbitrary repository path change, including a change later
reverted to the same bytes.

The checker accepts semantic envelopes only from the recorder's
evidence-ID-specific repository copy, never an external hash-only artifact or
captured process stream. It opens a canonical repository-relative path through
descriptor-relative no-follow traversal, accepts at most 1 MiB, and requires a
regular current-euid-owned, singly linked, mode-`0444` object with the exact
recorded byte count and digest. Descriptor metadata must remain stable during
the read, and a second no-follow lookup must name the same device/inode and
regular-file metadata. This is a bounded read-only snapshot check, not a
filesystem-immutability guarantee; a same-UID process can replace the pathname
after evaluation. Evidence timing must be bounded, ordered ISO-8601, and
contain the report capture time for the context record; the exact recorded
environment and repository cwd must match the report and live evaluator.
The checker rejects cross-case or cross-role reuse, duplicate formal-predicate
support, stale manifests, placeholder claims or scope, identity, timing, and
environment mismatch, fact-digest mismatch,
referenced-byte mutation, mutation during its bounded single-descriptor read,
pathname replacement after descriptor open, and required mount/crash facts
marked inapplicable. These are evidence controls only: all 57 signed-host rows
remain unexecuted, all 12 formal predicates remain false, and E2, P10, G10, and
G12 remain open. The recorder runs an operator-selected command and does not
authenticate an arbitrary harness or prove its claims. Source-manifest capture
and current-euid mode-`0444` snapshots are not authentication: a same-UID
process can author or replace the snapshot or record before evaluation as well
as replace it afterward. The control assumes a trusted operator and a
quiescent same-UID writer during manifest capture, recording, and evaluation.

The harness checks current-euid ownership and POSIX mode bits but does not
enumerate extended ACL entries on repository or state directories. Its
trusted-host assumption therefore also excludes another principal with an
ACL-based write grant. Such a principal has replacement power equivalent to
the owner for this analysis and the same maximum harness impact described
below. This is an explicit trust residual; it is not evidence that all relevant
write authority is confined to the numeric owner UID on every filesystem.

Admission resource use is explicitly bounded. JSON/control inputs are limited
to 1 MiB each and 64 MiB in aggregate; duplicate keys, non-finite values, and
numeric lexemes over 128 characters fail closed. Preserved and stream artifacts
are limited to 64 MiB each and parsed stdout to 16 MiB. One P10 checker process
may successfully consume at most 512 MiB cumulatively across referenced
evidence reads. Re-reading an artifact consumes its bytes again, while an
unreferenced artifact is not read or charged. A reader may fetch one byte beyond
the remaining allowance solely as an overflow sentinel; receiving it fails the
operation, and it is not admitted or included in a successful returned digest.
The post-hash metadata and pathname-identity lookup consumes no file bytes, and
a computed digest is returned only if that lookup succeeds.

A source manifest is limited to 32,768 files within 65,536 traversed entries,
64 MiB per file and 512 MiB per logical snapshot, and two independently
enumerated snapshots whose files are opened descriptor-relative must match.
It includes product source, the complete release-script tree, all active and
template gate handlers, acceptance records, findings resolution, host
capability, and the static baseline controls used for admission.
Gate-handler source and criteria sidecars are each limited to 1 MiB. Handlers
have a deadline and a 64 MiB combined output cap; failure terminates the full
child process group. Ordinary state/control JSON uses the 1 MiB per-file and
64 MiB aggregate policy, gate-result serialization is capped at 1 MiB, and the
state transaction journal has a separate 4 MiB cap. The event ledger is limited
to 64 MiB, 100,000 events, and 1 MiB per event. G10 acceptance
evidence must be canonical repository content, is limited to 64 MiB per file,
and shares a 512 MiB cumulative referenced-read budget. The recorder's existing
16 GiB external-artifact allowance remains a storage contract and cannot bypass
that G10 rule. Non-G10 acceptance remains compatible with bounded repository or
absolute external regular-file evidence, with a 16 GiB per-file and 16 GiB
cumulative read budget per validation invocation. Repository containment is a
G10-specific qualification-policy tightening, not a global ban on compatible
external evidence.

The package, attribution, and secret release commands use a separate stable
descriptor-relative walk limited to 65,536 observed entries and 128 directory
levels. File reads are limited to 64 MiB each and 512 MiB cumulatively per
invocation; attribution and secret findings stop at 10,000. Package child
commands have a 300-second deadline and 16 MiB combined-output cap, and the
package report is capped at 16 MiB. Directory-entry enumeration aborts while
streaming at the first entry beyond the bound, so a single large directory
cannot allocate an unbounded pre-count listing. Symlinks, special files,
multiply linked inputs, and observed directory or file replacement fail closed.

The active and template G10 handlers invoke the semantic P10 checker before
acceptance validation and pin its repository root. The gate runner removes a
stale criteria sidecar before launch and accepts only a freshly written exact
ordered criterion set with literal Boolean pass values. The executable gate,
batch-selector, acceptance, and state-control chain is source-manifest-bound.
The runner executes a bounded source copy through an inherited descriptor after
unlink, pins `FORGE_GATE_REPOSITORY_ROOT`, and verifies the snapshot's complete
metadata and bytes again after execution. The briefly named snapshot still
permits a same-UID or ACL-authorized process to retain a writable descriptor;
observed mutation fails closed, but this is not immutable execution.
The runner also records the exact Git HEAD, bounded source manifest, and
pre-gate state-event sequence. It observes the source manifest again after the
handler and rejects any mismatch. The batch selector skips a matching prior
pass only when its HEAD and manifest still equal the current bounded source
identity.

Gate-result and ledger publication are paired by a fresh canonical UUID-v4
operation identifier. The writer also gives the paired state event a distinct
fresh UUID-v4 `event_id`. The finalized result is durable and all fallible
result-directory and lock identity checks finish before `statectl`; its
crash-recoverable commit is the final success point. The journal is durable
before event append, the event before state publication, and marker removal
occurs last. Retrying the same operation identifier and exact request is
idempotent and cannot append a second event; reuse for another request fails
closed. Missing, oversized, legacy, non-finalized, non-UUID-v4, or mismatched
state/result records do not qualify for the batch skip. A skip requires both
records to be `passed`, the same gate and operation UUID, `finalized: true` in
the result, and exact current HEAD and source-manifest bindings. This is crash
consistency and observed source freshness, not evidence authentication.

These controls prevent acceptance-record-only and stale-sidecar passes; they do
not authenticate the qualification harness or make an incomplete report true.
A same-UID or ACL-authorized replacement before the initial open, after the
final lookup, or between the last precommit observation and state commit can
influence the current bounded evaluation or following state transition. Such a
writer can also forge both records before a later consumer. One winning race
can persist as a false G10 result, incorrect ledger state, and erroneous
release-admission decision until detected and requalified; repeated winning
replacements can sustain that outcome indefinitely. The limits bound each
invocation, not the persistence or repetition of the race. It confers no direct
product filesystem mutation authority. Observed identity and metadata
mismatches fail closed, but these checks mitigate the race; they do not
eliminate it. Harness authorization and this checkpoint therefore remain
non-authoritative for release closure.

Final completion uses the same bounded admission model instead of rereading
arbitrary pathnames. `verify_completion.py`, its regression suite, and the G12
active/template handlers are source-manifest targets. Each owner-controlled
control/result JSON file is capped at 1 MiB with a 64 MiB cumulative budget;
each completion report is capped at 1 MiB. The machine plan must declare
exactly the ordered canonical `G00` through `G12` inventory and definitions.
Required gate state and canonical repository result must carry one exact
finalized passed UUID-v4 operation. Every gate must bind exactly three
canonical runner artifacts in order: stdout, stderr, and criteria. Their exact
bytes are read under a shared 64 MiB-per-artifact and 512 MiB aggregate budget;
their SHA-256 values must match the result, command hashes, state evidence IDs,
and paired `gate_status` event. The criteria artifact must equal the exact
ordered evaluator criteria with literal Boolean passes, and the event must be
at `state_sequence_before + 1`.

Critical or High findings remain blocking from both findings resolution and
the live issue ledger, and malformed or missing ledgers fail closed. G02
through G11 each require a matching acceptance record whose
`current_release_authority` is the literal Boolean `true`; absence and legacy
omission are non-authoritative. Every prerequisite result must match the same
clean current Git HEAD and source manifest before and after evaluation.
Non-G10 artifact compatibility is bounded at 16 GiB per invocation; G10
remains repository-only with its 64 MiB per-file and 512 MiB cumulative limits.

The completion report's `admission_contract` binds the exact run, repository,
HEAD, source manifest, pre-G12 sequence, ordered `G00` through `G11`
prerequisites, and each prerequisite result's gate ID, operation UUID, exact
JSON SHA-256, and byte count. G12 binds the exact path, digest, and byte count
of both bounded completion reports into its criteria artifact, and every G12
criterion cites those report digests. The reports must have been evaluated
inside that G12 runner interval.

G12 uses the hardened gate runner, and the outer validator confirms its
matching operation and source binding before the final idempotent run-status
commit. Under the state transaction lock, `statectl` rechecks all 13 gates,
their three exact artifacts, the typed issue ledger, both completion reports,
the canonical finalized G12 result, current HEAD and manifest, clean relevant
source, and the exact event sequences. A successful state persists
`completion_authority` with the exact G12 UUID and status-operation UUID.
`statectl show` and `statectl validate` revalidate that authority on every read
of a completed run; stale source or admission data fails closed. An exact retry
rechecks the precondition without adding an event, while a different request
using the UUID fails closed. Any later non-idempotent state mutation demotes a
completed run to `active` and removes its authority. This closes the legacy
independent-pass, ignored-state-error, and cooperative interleaving paths; it
does not remove the same-UID/ACL residual above or supply any missing
signed-host evidence.

The final HEAD, manifest, artifact, report, and authority checks remain
sequential observations. A same-UID or ACL-authorized writer can still replace
a pathname after its last observation and before locked status publication, or
forge a coherent set before a later read. One winning race can persist as one
false `complete` status and an erroneous release decision until trusted
revalidation and requalification; repeated wins can sustain that false release
state indefinitely. The maximum direct product-filesystem authority added by
this admission race is none. These controls are mitigation, not elimination.
E2, P10, G10, G12, native signing/UI, real-provider continuity, and
owner-deferred hardware qualification retain their existing open or blocked
conclusions until the required evidence exists.

Protocol v5 binds the request, transaction, project generation, authorized
root, relative components, operation, explicit exactness contract, and expected
identity where applicable into one canonical SHA-256 digest. Successful
`renameatx_np(..., RENAME_EXCL)` capture is the mutation linearization point.
`currentEntry` acts on the eligible occupant captured at that point;
`namespaceVersionExact` disposes only a captured identity matching the request
token; and `contentVersionExact` fails closed without an exclusive-writer proof.
Persisted v5 recovery records use schema 3, persist the request protocol and
digest-canonicalization versions, and must recompute to the accepted digest.
Legacy protocol-v4 records remain recognizable only as schema 2 with nil
protocol, nil canonicalization version, nil contract, nil digest, and a present
expected identity; all mixed shapes fail closed. Recovery publishes a valid
transaction/digest-bound pending capture-identity receipt before general
pending-file cleanup so the first durable post-capture identity is not replaced
by a later mutable-metadata observation.

Root execution is not authority to exceed the authenticated caller's ordinary
filesystem power. The current daemon binds each accepted NSXPC connection to
its non-root effective UID, persists that UID in both the project binding and
transaction record, and requires an exact match on rebind and recovery. The
authorized root and every traversed directory must be requester-owned,
ACL-free, and owner-searchable; the final parent must also be owner-writable.
The production caller's preflight rejects an observed directory only as an
availability check; it is not an identity authority. The daemon deliberately
does not compare an observed source identity before capture. Instead it
descriptor-opens the protected captured entry and rejects terminal disposal if
the captured object is not a regular file or symlink, has an extended ACL, or
has any immutable, append-only, restricted, or no-unlink BSD flag. Those checks
run after capture, during recovery, and immediately before terminal unlink.
This deliberately excludes shared, delegated-ACL, root-owned, and
group-authorized trees until an equivalent caller-permission decision can be
proved. A source substituted with an ineligible directory can therefore be
captured but is quarantined rather than deleted.

The first implementation scope is non-directory leaf deletion on a local,
writable, ownership-enforced APFS volume. Directory deletion, same-volume move,
cross-volume move, and exact-content guarantees remain disabled until their
own recovery and adversarial matrices pass. This is an additive security
boundary; it does not grant privileges to `shell_exec`, `bash.run`, or any
runtime tool.

| API or facility | What it provides | Why it is or is not sufficient |
| --- | --- | --- |
| `SMAppService.daemon(plistName:)` | Signed app-contained LaunchDaemon registration, admin approval state, launchd lifecycle, and explicit unregister/re-register update behavior. Apple documents that a changed LaunchDaemon plist or executable must be re-registered and recommends unregister-before-register for an executable change; the asynchronous unregister completion is the safe point at which the old process is known to be killed before replacement registration. | Selected for lifecycle only, with an explicit reinstall operation using that completion boundary. It does not authorize a filesystem request or make a namespace mutation identity-conditional. Release use also requires the signed/notarized app and helper upgrade lifecycle to be qualified. |
| `NSXPCConnection(machServiceName:options:.privileged)` and `NSXPCListener(machServiceName:)` | A launchd-managed privileged transport. `setCodeSigningRequirement` requires newly received messages to match or invalidates the connection, and `setConnectionCodeSigningRequirement` rejects a nonmatching incoming peer before the listener delegate. The underlying XPC header states that all received messages are checked. The client now reads the allowed per-architecture daemon CodeDirectory hashes from its own validated running `SecCode` and code-signature-secured Info.plist, conjoins those exact `cdhash` values with the daemon identifier, team, and certificate requirement before activation, and verifies the same hash plus protocol, product version, service identifier, and root effective UID in the handshake before dispatch. | Selected for exact running-peer identity. It no longer trusts a helper-path digest. The signed build generates the caller-sealed hash keys from the separately signed daemon; missing or malformed keys fail closed. A raw CLI may bypass caller-relative `SMAppService.notFound` only to attempt this authenticated XPC probe. This source implementation still requires distinct signed app, installed manager/app, raw CLI, stale-helper, wrong-signer, timeout, upgrade, and restart execution evidence before the identity and packaging rows pass. Code signing prevents helper-only substitution against a current caller but does not establish whole-product rollback freshness; an allowlisted daemon retains its full bounded root mutation authority. |
| Low-level XPC `xpc_peer_requirement_match_received_message`, Swift XPC `XPCReceivedMessage.senderSatisfies`, and Security.framework `SecCodeCreateWithXPCMessage` | macOS 26 can explicitly match a requirement or create a live `SecCode` from the audit token attached to a particular received XPC dictionary. | Evaluated but not selected for this NSXPC protocol. NSXPC does not expose its internal dictionary to the exported-object method, while its documented signing-requirement API already applies the requirement to new messages and the underlying XPC implementation checks all received messages. A PID-only reconstruction would be weaker because of PID reuse and is not used. These APIs remain appropriate if the transport later moves to low-level or Swift XPC and needs message-specific inspection beyond the enforced peer requirement. |
| Root directory descriptors plus `openat`, `fstatat`, `renameatx_np`, `unlinkat`, directory `fsync`, and `fcntl(F_FULLFSYNC)` | Descriptor-relative confinement, independent root/source identity checks, exclusive capture, protected terminal deletion, and stronger local-media phase flushes. | Selected inside the daemon. Plain `fsync` alone does not promise power-loss ordering on macOS, so each durability boundary also requires `F_FULLFSYNC`; the signed crash and power-loss qualification is still open. None of these calls alone accepts an expected inode as a mutation precondition; the security property comes from exclusive capture into the protected namespace followed by verification there, not from treating any one syscall as identity-conditional. |
| `connection.effectiveUserIdentifier`, descriptor ownership/mode checks, `acl_get_fd_np`, and `st_flags` | Conservatively approximate whether the authenticated user could traverse the source hierarchy and remove the leaf without root assistance. | Selected to prevent privilege amplification. Connection UID is never accepted from request data; root, invalid, and non-account UIDs fail closed. This policy is intentionally narrower than all valid macOS permission arrangements. Its distinct signed-process and UID-binding evidence remains open even though the NSXPC signing requirement applies to every received message. |
| `renameatx_np(..., RENAME_EXCL)` | Atomically captures whichever entry occupies the source name supplied to the syscall while refusing destination overwrite. | Selected for capture and protected metadata publication. It is not an expected-identity rename, and a pinned source parent can be relocated outside the authorized root. Automatic privileged rollback is disabled; mismatch is retained in protected quarantine. |
| `renameatx_np(..., RENAME_SWAP)` | Atomically substitutes namespace entries and drives the hostile-process test matrix. | Test primitive only. It proves the pre-capture substitution remains possible and is not a mitigation. |

The pre-capture race remains, but its meaning is contract-specific. A winning
same-UID swap can cause the daemon to capture one different namespace entry.
For `currentEntry`, the successful capture defines the requested entry, so an
eligible captured regular file or symlink may be deleted; the daemon must not
claim that it deleted an earlier observation. For `namespaceVersionExact`, a
token mismatch must never be disposed and instead becomes an exclusive restore
or durable protected quarantine. An ineligible captured directory is
quarantined under either contract. The maximum availability impact per winning
race is the one captured entry; a directory can represent an unbounded subtree.
This boundary is not release authority until the signed hostile-process and
crash matrices pass. A writable file descriptor or hard link can also change or
preserve the captured inode's content independently of its pathname. Therefore
the design can qualify captured namespace identity, not immutable content, and
exact-content requests fail closed.

Source-parent containment and requester authority are not yet atomic with
capture. The daemon descriptor-walks and validates a requester-owned,
ACL-free, owner-writable parent, but `renameatx_np` later consumes that pinned
parent descriptor. A same-UID process can relocate the parent outside the
authorized root after validation and before capture. A winning race can make
`currentEntry`, or namespace-exact with a matching token, terminally delete one
eligible regular file or symbolic link outside the configured root. That one
file can contain an unbounded number of bytes. An ineligible captured directory
is retained in quarantine and can contain an unbounded subtree. Descriptor
pinning prevents substitution of the descriptor itself, but it does not prove
that the directory still descends from the authorized root.

Root-relative `RENAME_RESOLVE_BENEATH` was evaluated as a containment control,
but it would not by itself atomically bind the parent selected by the rename to
the separately observed requester-ownership, ACL, and write authorization or
provide the pinned source-parent durability handle. No such replacement is
implemented or qualified. Outside-root sentinel preservation therefore cannot
pass and E2 remains release-blocking.

If exclusive capture fails with a documented error that guarantees neither
namespace argument changed, the transaction can durably reject and later be
acknowledged. The current classification covers permission/flag denial,
unrenameable busy entries, unsupported/read-only filesystems, quota/space
denial, and other deterministic no-mutation argument/type failures. `EEXIST`,
I/O ambiguity, invalid descriptors/pointers, and unknown errors retain recovery
or corruption handling. The signed matrix must exercise at least immutable or
no-unlink denial and a substituted unrenameable mountpoint so 32 repeatable
pre-capture failures cannot strand all protected slots.

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

Durable quarantine is fail closed but not yet operationally reclaimable. A
quarantined leaf is terminal, queryable, durable, and deliberately not
acknowledgeable while the protected entry exists. No separately authorized
restore, release, or purge action is implemented. Each conflict permanently
occupies one of 32 slots until that disposition exists; 32 repeated conflicts
can disable later protected deletion on the volume. The slot count bounds
entries, not bytes or descendants, and a captured directory can hold an
unbounded subtree. This liveness and capacity risk is release-blocking, as are
the missing startup recovery barrier, manager-authoritative binding revoke and
garbage collection, daemon-owned caller discovery/generation revoke, and
behavior-qualified external/removable volume policy. Terminal receipts also
need a qualified physical-state reconciliation rule: committed/restored/
rejected/conflicted with a retained protected leaf, or quarantined with a
missing or identity-mismatched leaf, cannot yet be repaired safely and remains
a release blocker rather than a truthful terminal claim.

The current checkpoint is partial. The source now binds the exact live-helper
identity expectation into each Xcode-built main caller's code-signature-secured
Info.plist. `NSXPCConnection` requires that CodeDirectory hash set before
activation, and the same-connection handshake repeats the exact running hash
check before dispatch. The canonical Xcode app-scheme graph builds one daemon,
builds the CLI from that daemon, and makes the app depend on and embed both
signed products. The app and CLI therefore seal the same per-architecture
daemon hashes, and the app embeds the raw CLI at
`Contents/Helpers/forge-conductor` with `CodeSignOnCopy`. Release packaging must
take the app and standalone CLI from that same build: independently clean app
and CLI builds are not assumed to reproduce a CodeDirectory hash, and the
bundle checker rejects a cross-paired CLI whose seal differs.

The installed login-manager path validates the exact app main executable and
embedded CLI, stages only the embedded CLI rather than extracting the app main,
and transactionally stages the signed runtime launcher and core framework
beside the installed raw CLI. A complete privileged payload requires the
daemon, LaunchDaemon plist, embedded CLI, runtime launcher, and app framework;
missing, symlinked, mismatched, or invalidly signed artifacts fail before
replacement. Each team is bound to one exact Apple certificate class:
`9AQ2C2838M` requires Apple Development and `2Y25RTLZET` requires Developer ID
Application. Security.framework and the outer verifier enforce the exact Apple
anchor, identifier, team, and certificate class for the app, CLI, daemon,
runtime launcher, and core framework across every architecture. A separately
signed raw CLI may probe the app-owned service only with valid caller-sealed
hashes. The Apple Development-signed Release build, five-artifact checker, and
bounded installed-app/manager execution are supporting evidence, not live XPC,
Developer ID, or native lifecycle qualification. Static outer-bundle validation
also remains valid only while the filesystem object is unmodified.
Code signing does not establish freshness: preventing rollback of the entire
validly signed caller, expectation, and helper requires a monotonic root-owned
version receipt. Stale-helper, upgrade, negative-signature, live service,
Developer ID Release, and notarization evidence is still absent, so
`FC-PRIVILEGED-CALLER-IDENTITY-001` remains open.

Distinct-process signing identity, signed adversarial and crash recovery, full
volume behavior, approval/denial,
upgrade/unregister/re-register and stale-helper rejection, signature rejection,
source-leaf/hard-link/writable-FD
behavior, and notarized Release lifecycle evidence are still required. An
ambiguous submitted XPC call now returns its original transaction ID. The
additive, pathless `fs_delete_recovery` tool can consume that ID to query,
resume, or acknowledge the exact transaction under its original requester,
project, generation, and root authority. It does not discover transactions
whose same-UID caller-ledger handle was removed, automatically acknowledge a
broker result, or restore, release, or purge a retained quarantine. Those
durable recovery and disposition boundaries therefore remain explicit open
requirements. The
canonical finding `FC-FILESYSTEM-PATH-TOCTOU-001` (policy alias `FCA-007`), E2,
P10, G10, and G12 remain open. The privileged design mitigates the prior race;
it is not described as eliminating it.

The complete signed-host case inventory and pass predicates are maintained in
[`PRIVILEGED_FILESYSTEM_QUALIFICATION.md`](../docs/PRIVILEGED_FILESYSTEM_QUALIFICATION.md).

## Managed runtime execution

Managed shell and interpreter jobs execute only through the native runtime launcher. Production app and CLI builds require an exact, signed product identity, enclosing application seal where applicable, and a matching staged-helper code-directory hash. A team-signed product must also satisfy its exact Apple anchor and certificate class: Apple Development for `9AQ2C2838M`, or Developer ID Application for `2Y25RTLZET`. Exact-path, ad-hoc SwiftPM pairings are accepted only for local development products with allowlisted identifiers; they are not distribution authority.

Each job has independently authorized canonical read and write roots. Write roots must be a subset of read authority. Manager-owned stdout and stderr artifacts are outside the child-writable scratch directory. Artifact reads revalidate the regular-file type, owner, link count, device, inode, bounded size, and digest so replacement or mutation fails closed.

The launcher applies bounded CPU, descriptor, output-file, and core-dump limits before execution. Runtime discovery uses semantic, deadline-bounded probes rather than executable presence alone. Jobs run in isolated process groups under a deny-default profile, with bounded descendant census and a configured descendant limit. Termination phase and exact process identity are durable; shutdown and restart recovery continue bounded TERM, KILL, and liveness probing until group death is confirmed. An unconfirmed group remains owned and prevents stores from closing underneath the reaper.

## Plugin boundary

Host plugins receive only capabilities and data required for session creation. They do not gain arbitrary project filesystem access by default. Provider credentials remain behind a secure client abstraction.

## Logging

Use `Logger` with stable subsystem/categories and privacy annotations. Never use raw prompt/document body values in logs. Signposts use IDs and sizes, not content.

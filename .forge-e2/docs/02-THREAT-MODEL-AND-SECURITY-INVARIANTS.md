# Threat Model and Security Invariants

## Protected assets

- Files and directories outside each authorized project root.
- Other registered projects.
- Project memory and continuity databases.
- Runtime job working directories.
- Package store and quarantine.
- Source and destination entries not named by the accepted invocation.
- Existing destination entries when the contract is no-overwrite.
- Shell capability and its user-visible configuration.

## Adversary capabilities

Tests must assume an adversarial concurrent writer can:

- replace any unpinned path component;
- atomically swap safe and hostile entries;
- replace a file with a directory, symlink, FIFO, socket, or device;
- create and remove hard links;
- rename parents;
- create destination parents or leaves between checks;
- cancel the request or terminate the manager at every state transition;
- restart the manager with stale transaction records;
- submit Unicode-normalization and control-character names.

The adversary is not assumed to bypass macOS discretionary access controls
or possess the Forge process's memory.

## Invariants

### Authority

`FS-AUTH-001`
: Authority is `{projectID, generation, rootIdentity, rootFD,
relativeComponents, accessMode}`. A URL string is display data.

`FS-AUTH-002`
: Every security-sensitive syscall is relative to an already authorized,
pinned descriptor.

`FS-AUTH-003`
: A project-generation mismatch rejects the operation before mutation.

`FS-AUTH-004`
: A registered root reopened after restart must match its stored volume and
file identity, or the project is fenced.

### Resolution

`FS-RESOLVE-001`
: Mutation path components are lexical relative components only. Reject
empty components, `.`, `..`, NUL, slash-containing components, and absolute
paths.

`FS-RESOLVE-002`
: Existing directories open with
`O_SEARCH|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW_ANY|O_RESOLVE_BENEATH`.

`FS-RESOLVE-003`
: Missing destination directories are created one component at a time with
`mkdirat`; `EEXIST` means reopen and verify, not assume success.

### Mutation

`FS-MUT-001`
: No final leaf is identity-checked and then mutated by a later syscall.

`FS-MUT-002`
: No-overwrite publication uses `RENAME_EXCL`.

`FS-MUT-003`
: Rename operations receive pinned parent descriptors and validated single-component
leaf names. They add `RENAME_NOFOLLOW_ANY` and `RENAME_RESOLVE_BENEATH` when the
qualified runtime behavior preserves final-symlink semantics; otherwise the explicitly
probed leaf-only policy is used with no multi-component path.

`FS-MUT-004`
: Exact preconditions use atomic capture followed by verify and
restore-or-quarantine.

`FS-MUT-005`
: A mismatch never results in deletion of the captured object.

`FS-MUT-006`
: Recursive traversal does not follow symlinks and rejects unsupported
special files unless the explicit tool contract is to manipulate the link
entry itself.

`FS-MUT-007`
: Captured objects live under a manager-reserved, mode-0700, same-volume transaction
namespace excluded from every model-facing root grant. Its descriptor, not its visible
name, is authority. A same-user unrestricted process remains outside this claim.

### Durability and recovery

`FS-REC-001`
: The ledger state preceding an external side effect is durable before the
side effect occurs.

`FS-REC-002`
: Every nonterminal state has a deterministic recovery action.

`FS-REC-003`
: A post-commit cancellation cannot conceal a committed mutation.

`FS-REC-004`
: Quarantine is bounded by count, bytes, and age; eviction never destroys an
unreconciled object.

### Product preservation

`FS-PROD-001`
: `shell_exec` remains enabled by default and retains `/bin/bash -lc`
compatibility.

`FS-PROD-002`
: Project memory and continuity stay project- and generation-bound.

`FS-PROD-003`
: Managed autonomy can continue while the GUI is closed.

`FS-PROD-004`
: New security errors are structured and do not masquerade as success.

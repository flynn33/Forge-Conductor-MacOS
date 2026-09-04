# Secure Filesystem Algorithms

## Common path preparation

1. Select an exact authorized root from durable project context.
2. Convert the requested absolute or relative display path into lexical
   relative components under that root.
3. Reject malformed components.
4. Pin and identity-check the root.
5. Walk to the parent descriptor using strict `openat`.
6. Never re-resolve the display path for authority.

## Rename flag selection

All mutation calls receive validated single-component leaf names and pinned parent
descriptors. `RENAME_EXCL` or `RENAME_SWAP` supplies the required atomic namespace
semantics. Add `RENAME_NOFOLLOW_ANY` and `RENAME_RESOLVE_BENEATH` when the runtime
probe confirms they preserve the operation's required final-symlink behavior. If the
strict flags reject the final symlink entry, use leaf-only descriptor rename with the
required exclusive/swap flag; no ancestor can be resolved because neither name contains
a slash. Record this selection in the volume capability matrix. Never fall back to an
absolute/multi-component path or Foundation mutation.

## `fs_read`

- Open the file relative to the root with `O_RESOLVE_BENEATH`.
- For strict mutation-compatible reads, add `O_NOFOLLOW_ANY`.
- For feature-compatible read-only symlink behavior, following is permitted
  only when `O_RESOLVE_BENEATH` proves the resolution remains below the
  root; document the mode in the result.
- `fstat` the opened descriptor.
- Reject non-regular files.
- Read from the descriptor with bounded chunks and cancellation checks.
- `fstat` again; on metadata drift, return `source_changed`.
- Return an opaque version token derived from project generation, root
  identity, relative path, file identity, size, timestamps, and content
  digest.

## `fs_list` and `fs_glob`

- Open the target directory by descriptor.
- Iterate with `fdopendir(dup(fd))` and `readdir`.
- Use `fstatat(..., AT_SYMLINK_NOFOLLOW)` for type information.
- Never recurse through a symlink.
- Implement glob matching in-process.
- Enforce maximum depth, entries, bytes of names, time, and cancellation.
- Stream large result sets or page them; do not build an unbounded array.

## `fs_mkdir`

For each component:

1. attempt strict `openat`;
2. when missing, call `mkdirat`;
3. if creation races with another creator, reopen and verify directory type;
4. `fsync` the containing directory after a new entry;
5. record each created directory identity for recovery and truthful partial
   results.

## `fs_write`

### Create-only

1. create a random staged file with
   `openat(O_CREAT|O_EXCL|O_WRONLY|O_CLOEXEC|O_NOFOLLOW_ANY)`;
2. write bounded content;
3. `fsync` the file;
4. publish with `renameatx_np` using `RENAME_EXCL` plus the qualified
   operation-compatible resolution flags;
5. `fsync` the parent.

### Replace-current

The contract is to atomically replace the current entry at the authorized
name. Create and synchronize the staged file, then:

- if destination exists, use `RENAME_SWAP` with no-follow/beneath flags;
- the displaced destination becomes the private staged entry;
- verify and dispose it only after the new entry is committed;
- if the caller supplied an exact version and the displaced entry does not
  match, swap back and return conflict; if rollback cannot be proven,
  preserve both objects and return a quarantine receipt.

Never truncate an existing path in place.

## `fs_edit`

1. descriptor-read the current regular file;
2. calculate the edit and enforce the existing size/replacement contract;
3. stage and synchronize the replacement;
4. atomically swap;
5. compare the displaced entry with the version read in step 1;
6. on match, commit and dispose;
7. on mismatch, rollback or quarantine.

This preserves the established edit semantics without a read-then-overwrite
race.

## `fs_delete`

### Current-entry contract

1. create and pin a source-volume transaction directory;
2. persist `prepared`;
3. atomically rename the requested leaf into the transaction directory with
   exclusive, no-follow, and beneath flags;
4. persist `sourceCaptured`;
5. recursively dispose only the captured object through descriptors;
6. persist `committed`;
7. synchronize both transaction and source parents.

No pre-rename identity check is performed.

### Exact-version contract

After capture, compare the captured object with the supplied version:

- match: dispose and commit;
- mismatch: restore exclusively to the source name;
- source occupied: keep the captured object in quarantine and return
  `filesystem_conflict`.

## Same-volume `fs_move`

### Current-entry, no-overwrite

Perform one descriptor-relative:

```text
renameatx_np(
  sourceParentFD, sourceLeaf,
  destinationParentFD, destinationLeaf,
  RENAME_EXCL | qualifiedResolutionFlags
)
```

This syscall is the linearization point. Do not precompare the leaf.

### Exact-version

Capture source first, validate, then publish to destination. Restore or
quarantine on mismatch.

## Cross-volume `fs_move`

1. atomically capture source on the source volume;
2. create destination-volume private staging;
3. descriptor-copy from captured source; for regular files, prefer qualified
   `fcopyfile` on already-open descriptors or bounded read/write plus explicit
   metadata copying;
4. preserve data, POSIX metadata, ACLs, extended attributes, and resource-fork
   behavior according to the existing characterized contract;
5. hash and compare copied content;
6. synchronize files and directories;
7. publish destination exclusively;
8. synchronize destination parent;
9. dispose captured source;
10. synchronize source transaction and original parents;
11. commit.

Do not call `/bin/cp` or `FileManager.moveItem`.

## Tree disposal

A captured tree is already within an authorized transaction namespace.
Deletion still uses descriptor-relative postorder traversal:

- symlink: unlink the link entry;
- regular file: unlink;
- directory: open without following, process children, then
  `unlinkat(..., AT_REMOVEDIR)`;
- special file: reject or unlink only when the explicit contract allows it.

Concurrent additions may make removal fail with `ENOTEMPTY`; re-enumerate
within strict limits or return a truthful quarantined result. Never chase
the new entry outside the tree.

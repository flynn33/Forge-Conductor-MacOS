# Cross-Volume and Hard-Link Semantics

## Cross-volume

`renameatx_np` requires a same-filesystem operation. A cross-volume move
therefore has two transaction namespaces:

- source-volume capture;
- destination-volume staging.

The source is captured before copy. This removes the source-name race and
provides a stable object reference for copy and rollback.

## Descriptor copier

Implement a native descriptor copier:

- regular files: `openat`, bounded read/write loop, SHA-256, mode/ownership
  policy, timestamps, supported xattrs, `fsync`;
- directories: `mkdirat`, bounded traversal, child synchronization, parent
  synchronization;
- symlinks: copy link text only when the tool contract permits links;
- sparse files: preserve or explicitly reject according to a tested policy;
- clones: optional optimization only after correctness;
- ACLs/xattrs: preserve according to the current user-visible move contract,
  with explicit unsupported-result reporting.

## Hard links

`O_UNIQUE` is a useful open-time precondition, not a permanent lock.
Another process can create a hard link later.

Rules:

1. Package archive ingestion of regular files should require unique-link
   input when the volume supports it.
2. Exact-version operations include link count in the version token.
3. Atomic capture occurs before any destructive decision.
4. After capture, enumerate and copy/delete only within the captured
   namespace.
5. Do not infer a concurrent metadata mutation solely from ctime after a
   deliberate unlink.
6. For a tree containing internal hard-link groups, either:
   - preserve the group using a manifest and destination link creation; or
   - reject it with a stable unsupported error if the existing contract
     never promised preservation.
7. An external hard link outside the captured tree must never cause Forge
   to delete or modify the external name.

The PR #11 ctime interval disappears from the security decision because
the operation no longer relies on post-unlink ctime reconciliation to
decide which pathname to remove.

## Regular-file copy primitive

Prefer `fcopyfile` on already-open source and destination descriptors when its
qualified behavior preserves the existing macOS metadata contract. Use
`COPYFILE_ALL`, or a documented subset plus explicit data copying when
cancellation granularity requires it. Never use path-based `copyfile` as
authority. After the copy, `fsync` the destination, re-read metadata, and
verify the content digest/manifest independently.

If `fcopyfile` cannot provide bounded cancellation for a qualified file size,
copy data through bounded `read`/`write` chunks and copy metadata explicitly;
record any unsupported metadata as a fail-closed capability result rather than
silently dropping it. Resource forks, extended attributes, ACLs, permissions,
and timestamps must be covered by characterization tests.

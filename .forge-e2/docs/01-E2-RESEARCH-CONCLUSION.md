# E2 Research Conclusion

## Question

How can Forge Conductor eliminate the descriptor-relative filesystem
race remaining after merged PR #11 when macOS has no public
compare-by-inode unlink or rename operation?

## Answer

Do not compare and then mutate. Make the namespace mutation itself the
linearization point.

The public macOS 26 interfaces required by the design are:

- `openat` relative to a pinned directory descriptor;
- `O_RESOLVE_BENEATH` to reject path resolution that escapes the starting
  descriptor;
- `O_NOFOLLOW_ANY` to reject symlinks in the entire path;
- `O_UNIQUE` to reject a regular file with more than one hard link at open
  time;
- `renameatx_np`;
- `RENAME_EXCL` for no-overwrite publication;
- `RENAME_NOFOLLOW_ANY`;
- `RENAME_RESOLVE_BENEATH`;
- `RENAME_SWAP` for atomic replacement/rollback workflows;
- `mkdirat`, `fstatat`, `readlinkat`, `unlinkat`, `fdopendir`, `readdir`,
  `fsync`, and `fstat`.

Apple's current XNU headers define these flags, and the current XNU man
pages document their semantics. Apple's XNU tests exercise
`O_RESOLVE_BENEATH` against `..`, absolute paths, and escaping symlinks,
and exercise `O_UNIQUE` against multiple hard links.

## Why PR #11 remains vulnerable

The merged source still contains this pattern in multiple paths:

```text
fstatat(parentFD, leaf)
compare expected identity
unlinkat(parentFD, leaf)
```

and:

```text
fstatat(sourceParentFD, sourceLeaf)
compare expected identity
renameatx_np(sourceParentFD, sourceLeaf, ...)
```

A writer can replace the final directory entry between the comparison and
the mutation. Descriptor-relative parents prevent ancestor redirection,
but they do not make the final comparison and mutation one atomic kernel
operation.

The current implementation also still:

- derives pinned directories from a path through `realpath`;
- creates destination hierarchies before obtaining a typed root capability;
- uses Foundation enumeration for tree plans;
- uses `/bin/cp -pR` for cross-volume staging;
- contains an acknowledged hard-link ctime reconciliation interval.

## Closure strategy

### Path-authorized operations

For operations whose contract is “operate on the current entry named by
this authorized path,” perform the atomic rename or unlink semantics
without a pre-mutation identity comparison. The atomic operation is the
linearization point. Because the parent descriptor and relative leaf are
authorized and no symlink is followed, the operation cannot escape the
root.

### Exact-version operations

For operations that must act only on a previously observed version:

1. create and pin a private transaction directory on the source volume;
2. atomically rename the current source entry into that directory;
3. inspect the captured object through the transaction descriptor;
4. compare it with the supplied version token;
5. on match, continue;
6. on mismatch, atomically restore it if the source name is vacant;
7. if restoration cannot be proven, preserve it in bounded quarantine and
   return a conflict receipt.

No mismatched object is destroyed.

### Recursive operations

Atomically capture the requested tree root first. Traverse and dispose of
the captured tree only through descriptors. Race-driven replacements can
cause a bounded conflict or failed cleanup, but they cannot redirect
traversal outside the captured namespace.

### Cross-volume move

Capture the source on its own volume before copying. Copy from the captured
tree through descriptors into a private destination-volume staging tree.
Synchronize and validate it, then publish with exclusive descriptor-relative
rename. Dispose of the captured source only after publication is durable.

## Security claim

This design closes E2 for Forge's stated application threat model:

- untrusted or concurrently changing names inside authorized roots;
- symlink, `..`, absolute-path, parent-rebinding, final-leaf swap,
  hard-link, and destination-creation attacks;
- cancellation and crash at any state boundary;
- no mutation outside an authorized project root.

It is not an operating-system isolation boundary against another
unrestricted process running as the same user. App Sandbox/XPC isolation is
a separate defense layer and must be described separately.

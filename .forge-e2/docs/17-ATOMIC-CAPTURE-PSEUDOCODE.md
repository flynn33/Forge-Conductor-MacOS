# Atomic Capture and Publication Pseudocode

This document is normative. Codex may change type names to fit the current
repository, but it must preserve each linearization point and failure outcome.

## Terms

- **root capability** — project/generation-bound authorized root identity plus an
  active pinned directory descriptor.
- **parent capability** — a descriptor reached from the root without following a
  symlink, plus a validated single-component leaf name.
- **transaction directory** — a randomly named, mode-0700 directory on the same
  filesystem as the object being captured. It is pinned immediately and excluded
  from all model-facing path grants.
- **capture** — one descriptor-relative atomic rename that removes the current
  source name and places that exact directory entry in the transaction directory.
- **publication** — one descriptor-relative exclusive rename or atomic swap that
  makes staged data visible at the requested destination.
- **version token** — project generation, root identity, relative components,
  object identity, relevant metadata, and content/tree digest. It is a conflict
  detector, not pathname authority.

## Root acquisition

```text
acquireRoot(projectID, generation, rootRecord):
    require project generation is current
    resolve security-scoped bookmark with file-ID preference when applicable
    start security-scoped access
    fd = open(rootURL, O_SEARCH|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW_ANY)
    require fd >= 0
    actual = fstat(fd)
    require actual identity == persisted root identity
    return RootCapability(projectID, generation, rootID, fd, lease)
```

On first migration of a legacy root with no identity, persist a migration receipt
before authorizing mutation. Once an identity exists, a different object at the
same display path is never adopted automatically.

## Strict parent walk

```text
walkToParent(rootFD, components):
    require components.count >= 1
    require every component is nonempty, not '.' or '..', contains no slash,
            contains no NUL, and satisfies byte limits
    current = dup(rootFD)
    for component in components.dropLast():
        next = openat(current, component,
                      O_SEARCH|O_DIRECTORY|O_CLOEXEC|
                      O_NOFOLLOW_ANY|O_RESOLVE_BENEATH)
        require next >= 0
        close current
        current = next
    return ParentCapability(current, leaf=components.last)
```

The mutation syscall receives only the single leaf component. It never receives a
multi-component, absolute, canonicalized, or user-derived path.

## Create transaction directory

```text
createTransactionDirectory(volumeTransactionRootFD, transactionID):
    // volumeTransactionRootFD is a manager-reserved, mode-0700 root on the
    // source filesystem and is excluded from model-facing capabilities.
    name = 'txn-' + random128 + '-' + transactionID.prefix
    mkdirat(volumeTransactionRootFD, name, 0700) // retry with a new random name
    txFD = openat(volumeTransactionRootFD, name,
                  O_SEARCH|O_DIRECTORY|O_CLOEXEC|
                  O_NOFOLLOW_ANY|O_RESOLVE_BENEATH)
    require txFD >= 0
    identity = fstat(txFD)
    fsync(volumeTransactionRootFD)
    persist transaction directory name + identity + transaction-root identity
    return TransactionDirectory(txFD, name, identity)
```

The directory may later be renamed by another actor; the descriptor remains the
only authority. Recovery reopens it relative to the recorded transaction-root
descriptor and verifies identity before continuing. If a same-volume private root cannot
be established, mutation fails closed or uses the explicitly documented reserved-root
policy; it never places a predictable writable staging area in the project tree.

## Capture current entry

```text
captureCurrent(sourceParent, sourceLeaf, tx, capturedLeaf):
    persist phase=prepared and intended syscall
    renameatx_np(sourceParent.fd, sourceLeaf,
                 tx.fd, capturedLeaf,
                 RENAME_EXCL [plus only operation-compatible defense flags])
    if EXDEV: return crossVolumeRequired without mutating
    require success
    captured = fstatat(tx.fd, capturedLeaf, AT_SYMLINK_NOFOLLOW)
    persist phase=sourceCaptured + captured identity + syscall receipt
    fsync(tx.fd)
    fsync(sourceParent.fd)
    return captured
```

There is deliberately no identity comparison immediately before the rename. The
atomic rename is the linearization point and captures whichever authorized entry
is current at that instant.

### Rename flag policy

- `RENAME_EXCL` is mandatory for capture/publication names that must not replace
  an existing entry.
- Use `RENAME_RESOLVE_BENEATH` and `RENAME_NOFOLLOW_ANY` when the public-SDK/runtime
  probe confirms they preserve the required final-symlink behavior.
- Because all ancestors are already pinned and both syscall names are validated
  single components, a leaf-only `renameatx_np(..., RENAME_EXCL)` is an acceptable
  operation-specific path for moving the final symlink entry itself when the
  no-follow flag rejects that final component. This is not a string-path fallback:
  no ancestor is resolved by the syscall, and POSIX/Darwin rename acts on the link
  entry rather than its target.
- Record the chosen policy in a tested capability matrix. Never silently downgrade
  to `FileManager`, an absolute path, or a multi-component rename.

## Delete current entry

```text
deleteCurrent(capability):
    tx = createTransactionDirectory(capability.parent)
    captured = captureCurrent(capability.parent, capability.leaf, tx, 'payload')
    persist phase=sourceVerified with contract=currentEntry
    disposeTreeByDescriptor(tx.fd, 'payload')
    persist phase=sourceDisposed
    fsync(tx.fd); fsync(capability.parent.fd)
    remove empty tx directory by verified parent descriptor
    persist phase=committed
```

A concurrent leaf swap before capture determines which current entry is deleted.
A swap after capture cannot redirect disposal because disposal is rooted at `tx.fd`.

## Delete exact version

```text
deleteExact(capability, expectedVersion):
    tx = createTransactionDirectory(capability.parent)
    captured = captureCurrent(...)
    actualVersion = inspectCaptured(tx.fd, 'payload')
    if actualVersion == expectedVersion:
        dispose and commit
    else:
        persist phase=restorePending
        result = renameatx_np(tx.fd, 'payload',
                              capability.parent.fd, capability.leaf,
                              RENAME_EXCL [compatible flags])
        if result == success:
            persist phase=restoredConflict
            return conflict(restored=true)
        if errno == EEXIST:
            persist phase=quarantined
            return conflict(restored=false, quarantineReceipt)
        persist failedRecoverable; retry by recovery worker
```

A mismatched captured object is never destroyed.

## Same-volume move, current-entry no-overwrite

```text
moveCurrent(sourceParent, sourceLeaf, destinationParent, destinationLeaf):
    persist prepared intent and both parent identities
    renameatx_np(sourceParent.fd, sourceLeaf,
                 destinationParent.fd, destinationLeaf,
                 RENAME_EXCL [compatible defense flags])
    require success
    persist destinationPublished receipt
    fsync destinationParent.fd
    if different parent: fsync sourceParent.fd
    persist committed
```

No final-leaf precomparison is allowed. The syscall is the operation's single
linearization point.

## Exact-version move

```text
moveExact(source, destination, expectedVersion):
    capture source into source-volume transaction directory
    inspect captured object
    on mismatch: restore or quarantine
    on match: exclusive rename captured object from txFD to destinationParentFD
    fsync destination and source parents
    commit
```

## Cross-volume move

```text
crossVolumeMove(source, destination):
    capture source into source-volume transaction directory
    inspect and persist source manifest
    create destination-volume transaction directory
    descriptorCopy(sourceTxFD/payload -> destinationTxFD/payload)
    fsync every file bottom-up; fsync every directory bottom-up
    compare destination manifest with source manifest
    persist phase=destinationStaged
    exclusive publish destination payload
    persist phase=destinationPublished; fsync destination parent
    dispose captured source through sourceTxFD
    persist phase=sourceDisposed; fsync source parent and tx parent
    commit
```

A copy failure restores or quarantines the source capture. A crash after publication
never republishes; recovery validates the destination receipt and resumes source
disposal.

## Atomic edit/replace

The existing edit operation derives new content from a version it read. Use an
atomic swap so the destination name remains populated:

```text
stage replacement in same-volume transaction directory; fsync it
persist prepared + expected old version
renameatx_np(txFD, 'replacement', parentFD, leaf,
             RENAME_SWAP [compatible defense flags])
// new content is visible; displaced old entry is now txFD/replacement
persist destinationPublished receipt
inspect displaced old entry
if it matches expected version:
    dispose old; fsync; commit
else:
    persist restorePending
    attempt the inverse RENAME_SWAP
    verify both entries after rollback
    if rollback cannot be proven: preserve both and quarantine
    return structured conflict
```

The public sources do not supply a conditional compare-by-inode rename. Therefore
an exact-version mismatch can be briefly observable before rollback. The product
must document that bounded behavior and must never claim kernel compare-and-swap
semantics. The security guarantee is preservation and containment: no mismatched
object is destroyed and no outside-root object is mutated.

## Crash rule

A syscall is never repeated solely because its post-state write is absent. Recovery
first inspects the source, destination, and transaction namespaces by descriptor and
identity, determines which effect occurred, records the missing receipt, and only
then advances or compensates.

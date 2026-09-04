# Atomic Leaf Swap Harness Blueprint

Create an XCTest helper executable or C test support target.

## Attacker

The attacker owns two entries under the authorized test root:

```text
victim
alternate
```

It loops:

```c
renameatx_np(
    parent_fd, "victim",
    parent_fd, "alternate",
    RENAME_SWAP | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
);
```

Variants swap:

- regular/regular;
- regular/symlink;
- regular/directory;
- safe tree/hostile tree;
- one-link/multi-link regular files.

## Synchronization

Production code exposes test-only hooks at:

- capability pinned;
- parent resolved;
- transaction prepared;
- immediately before atomic capture;
- immediately after capture;
- before publication;
- after publication before ledger receipt;
- before restore;
- before disposal.

Use barriers, not sleeps, for deterministic tests.

## Assertions

- outside sentinel identity and digest unchanged;
- no symlink target outside root opened or mutated;
- mismatched capture preserved;
- no-overwrite destination preserved;
- result agrees with committed namespace;
- late cancellation does not conceal commit;
- recovery reaches the same terminal state after restart.

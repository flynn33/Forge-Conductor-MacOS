# Test and Adversarial Qualification

## Test layers

### Unit

- component parser;
- root selection;
- identity and version tokens;
- state transitions;
- rollback decisions;
- quarantine limits;
- error mapping;
- shell preservation.

### Darwin API contract

Compile and run `scripts/macos_api_probe.c` on the supported macOS 26 host.
It must prove:

- constants are available from public SDK headers;
- beneath resolution rejects `..`, absolute paths, and escaping symlinks;
- no-follow-any rejects every symlink component;
- unique open rejects a multi-link regular file;
- exclusive rename refuses an existing destination;
- rename resolve-beneath rejects escape;
- rename no-follow behavior matches the implementation assumption;
- swap is atomic on the qualification filesystem.

### Deterministic race harness

Add test hooks immediately before each former compare/mutate boundary.
Use `renameatx_np(..., RENAME_SWAP)` in an attacker loop.

Required cases:

1. final regular leaf swap;
2. regular file ↔ symlink;
3. regular file ↔ directory;
4. directory root swap;
5. source parent rename;
6. destination parent rename;
7. destination creation race;
8. ancestor symlink insertion;
9. `..` and absolute path;
10. hard-link creation/removal;
11. internal and external hard-link groups;
12. transaction-directory rename;
13. source-volume unmount or `EXDEV`;
14. cancellation before and after every commit point;
15. manager termination after every ledger state;
16. project reset and generation increment during operation;
17. Unicode normalization collision;
18. case-folding collision;
19. path control characters and maximum lengths;
20. FIFO, socket, device, and mount-trigger entries.

Each test creates an outside-root sentinel with a random digest. The digest,
identity, link count, and contents must be unchanged after every iteration.

### Stress

- minimum 10,000 atomic swaps per leaf case;
- minimum 1,000 tree capture/delete cycles;
- minimum 1,000 same-volume moves;
- minimum 200 cross-volume or forced-cross-volume moves;
- restart recovery from every nonterminal state;
- 30-minute mixed-operation soak;
- no unbounded growth in descriptors, resident memory, quarantine, or
  transaction rows.

### Compatibility

Run all existing tests, including:

- MCP protocol;
- runtime jobs;
- project context;
- project memory;
- managed autonomy;
- continuity coordinator;
- native session host;
- shell;
- migration;
- cancellation/recovery.

## Allowed race outcomes

- success on the entry present at the atomic linearization point;
- structured conflict with successful restore;
- structured conflict with preserved quarantine;
- `ENOENT`, `EEXIST`, `ELOOP`, `ENOTCAPABLE`, `ENOTSUP`, cancellation, or
  deadline before commit;
- truthful committed receipt after a late cancellation.

## Forbidden outcomes

- outside-root sentinel changed;
- another project changed;
- mismatched captured object destroyed;
- destination overwritten under a no-overwrite contract;
- path-based fallback used;
- stale project generation accepted;
- committed mutation reported as cancelled;
- shell disabled or removed.

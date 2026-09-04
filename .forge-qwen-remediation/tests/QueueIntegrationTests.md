# Package ingestion and Work Queue tests

## Ingestion security

- absolute and parent-traversal archive paths;
- NUL/control characters;
- duplicate normalized names;
- Unicode NFC/NFD collision;
- case-fold collision on case-insensitive volume;
- symlink, hard link, FIFO, socket, device node;
- zip bomb size ratio and uncompressed cap;
- file-count and path-length caps;
- source mutation and atomic leaf swap during ingestion;
- crash after private staging, after manifest validation, after fsync, and after immutable publication;
- duplicate digest deduplication;
- quarantine and cleanup bounds.

## Queue behavior

- deterministic ordering by readiness, priority, and age;
- dependency blocked/unblocked transitions;
- one active lease per run;
- stale lease epoch cannot commit progress, artifacts, gate results, or completion;
- manager restart before worker start and during running;
- pause/resume/cancel/retry;
- failed validation leaves package blocked, not completed;
- automatic next-package advancement;
- package A rolls over context and completes; package B starts without operator action;
- project reset fences queued and running old-generation work.

## UI

Execute signed XCUITests for import, ordering, status, gate/artifact inspection, pause/resume/retry/cancel, restart reconnection, and accessibility identifiers.

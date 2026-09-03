# Project reset tests

## Functional matrix

| Mode | Cleared | Preserved |
|---|---|---|
| memory | project memory records/indexes | continuity, package definitions, settings |
| continuity | handoffs/operations/projections | memory, package definitions, settings |
| memoryAndContinuity | both above | project identity, settings, immutable packages |
| runHistory | terminal run/event history selected by policy | active work, memory, continuity |

## Required tests

- expected generation mismatch fails before maintenance lease;
- maintenance lease blocks new stateful writes and queue reservations;
- active jobs/provider sessions/gate executions are fenced or reconciled;
- optional backup hash and restore round trip;
- repository is closed before rotation/deletion;
- generation increments exactly once;
- delayed old-generation tool/job/provider results are rejected;
- crash at every state recovers to completed or safely restored reset;
- resetting one project does not alter another project;
- shell settings remain unchanged;
- UI displays exact mode and receipt.

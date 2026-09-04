# Project reset architecture

## Reset modes

```swift
enum ProjectResetMode {
    case memory
    case continuity
    case memoryAndContinuity
    case runHistory
}
```

## Protocol

1. Validate expected project generation.
2. Acquire exclusive maintenance lease.
3. Stop new queue reservations and stateful writes.
4. Fence or stop active provider sessions, continuity operations, runtime jobs, and gate executions.
5. Drain or reconcile in-flight operations with a bounded deadline.
6. Close and evict project repositories.
7. Optionally create a hash-verifiable backup.
8. Reset selected tables/projections or rotate the selected database.
9. Increment project generation exactly once.
10. Invalidate all old-generation bindings and leases.
11. Reopen clean repositories and rebuild projections.
12. Persist reset receipt and release maintenance lease.

## Receipt

The receipt records reset ID, project, old/new generation, mode, backup ID/checksum, affected record counts, fenced run/job/session IDs, timestamps, source schema versions, result, and recovery state.

## Crash recovery

The reset operation is a durable state machine. Rotation and generation increment cannot be ambiguous: recovery observes the operation record and filesystem/database state, then completes or restores without accepting old-generation work.

## UI

Projects Settings shows explicit modes, selected project ID/generation, backup option, expected effects, and final receipt. No generic `Reset Generation` button remains as the sole action.

# Continuity authority consolidation

## Modes

```swift
enum ContinuityHostMode {
    case managedAutonomous
    case externalMCPCompatibility
}
```

### managedAutonomous

The manager owns provider turn sequencing, context observations, rollover, handoff, successor creation, acknowledgment, fencing, continuation, and recovery. Fixed tool counts may trigger an advisory checkpoint only; they cannot block tools or instruct manual chat creation.

### externalMCPCompatibility

An external chat UI owns the conversation. Forge may persist checkpoints/handoffs and return truthful instructions, but it must label that it cannot create the external host’s successor. This mode cannot contaminate managed run state.

## Removal of global authority

Global `LATEST`, `current-task.md`, `NEXT-CHAT.md`, and global memory keys may remain only as migration/read-only compatibility projections. They cannot be consulted to select a project or handoff for a stateful managed call.

Bootstrap requires exact:

- `project_id`;
- `project_generation`;
- `run_id`;
- `operation_id`;
- `handoff_id`;
- `handoff_sha256`;
- `bootstrap_nonce`.

## Administrative commands

`Checkpoint Now` and `Request Early Rollover` call authenticated manager routes, persist operations, and return operation IDs. The UI streams the same canonical state machine used by automatic rollover.

## Rollover sequence

1. close predecessor admission;
2. classify/reconcile in-flight tool calls;
3. persist compact bounded handoff;
4. persist successor-request intent;
5. create fresh real provider root;
6. expose only acknowledgment capability until exact ack;
7. accept at most one successor;
8. fence predecessor tool authority;
9. issue one automatic continuation;
10. seal operation.

Every transition is recoverable and generation-bound.

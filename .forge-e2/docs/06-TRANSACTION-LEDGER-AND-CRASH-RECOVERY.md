# Transaction Ledger and Crash Recovery

## State machine

```text
prepared
  -> sourceCaptured
  -> sourceVerified
  -> destinationStaged
  -> destinationPublished
  -> sourceDisposed
  -> committed
```

Branches:

```text
prepared            -> cancelled
sourceCaptured      -> restorePending
sourceCaptured      -> quarantined
sourceVerified      -> restorePending
destinationStaged   -> cleanupPending
destinationPublished-> sourceDisposePending
*                   -> failedRecoverable
*                   -> failedTerminal
```

## Persistence rule

Before every irreversible or externally visible syscall, commit the intent
and expected identities. After it returns, commit the observed receipt.
Use SQLite transactions and the repository's established durable commit
boundary.

## Recovery table

| State | Recovery |
|---|---|
| `prepared` | Verify no capture exists; remove empty transaction directory; cancel. |
| `sourceCaptured` | Locate transaction entry by stored relative name and identity. Validate. Continue or restore. |
| `sourceVerified` | Continue the requested operation if generation is current; otherwise restore or quarantine. |
| `destinationStaged` | Validate staging identity and source capture; resume publication or clean staging. |
| `destinationPublished` | Verify destination receipt. Never republish. Dispose source capture or mark conflict. |
| `sourceDisposed` | Synchronize parents and commit. |
| `restorePending` | Restore exclusively if source vacant; otherwise quarantine. |
| `cleanupPending` | Retry bounded cleanup; never delete an unverified entry. |
| `quarantined` | Publish stable receipt and enforce retention policy. |

## Exactly-once effects

Remote or filesystem calls may be retried, but accepted effects are keyed
by `transaction_id` and operation phase. A recovery worker must inspect the
namespace before deciding whether to repeat a syscall.

## Required table

Use `schemas/filesystem-transactions.sql`. Integrate it with the existing
control-plane store rather than opening an unrelated global database.

## Project reset

A project reset:

1. blocks new transactions;
2. waits for or cancels pre-commit work;
3. recovers or quarantines committed/captured work;
4. increments generation;
5. rejects every stale transaction result;
6. retains transaction evidence according to policy.

## Quarantine

Quarantine entries include:

- transaction ID;
- project ID and generation;
- source and requested destination display paths;
- captured identity;
- reason;
- byte estimate;
- creation and last recovery timestamps;
- recovery attempts;
- checksum or tree manifest reference.

Quarantine is bounded, but unreconciled data is never evicted
automatically. When limits are approached, block new destructive
transactions for that project and continue independent work.

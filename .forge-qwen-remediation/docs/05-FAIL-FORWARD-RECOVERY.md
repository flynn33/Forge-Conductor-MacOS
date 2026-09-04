# Fail-forward and recovery policy

## Durable intent rule

Before an external or irreversible side effect, persist intent with project, generation, operation, idempotency key, expected revision, and recovery class.

## Recovery classes

1. **Pure/replayable** — repeat safely.
2. **Idempotent external** — repeat with the same idempotency key.
3. **Discoverable external** — query the external system and accept at most one matching result.
4. **Irreversible local commit** — return the committed receipt despite late cancellation.
5. **Ambiguous mutation** — quarantine or block; never guess.

## Retry policy

- bounded attempts;
- monotonic total deadline;
- exponential backoff with jitter;
- no retry for validation, authorization, stale generation, or unsupported capability failures;
- retry state persisted before sleeping;
- no infinite task loops.

## No-progress policy

After three attempts with no new evidence:

1. stop repeating the same command;
2. create the smallest deterministic reproducer;
3. inspect ownership and transition state;
4. select a reversible alternative;
5. record the decision and residual risk.

## Crash recovery

`plans/crash-recovery-matrix.json` is mandatory. Tests terminate the manager after every durable transition and verify exactly-once accepted effects, truthful receipts, and resumable state.

## Session handoff

The Qwen Code work ledger is separate from product continuity. Before context exhaustion, update state and create `state/current-handoff.json` through `statectl.py`. A successor reads the exact work package, source manifest, latest evidence, open blockers, and next command.

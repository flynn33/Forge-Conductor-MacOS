# Execution contract

## Per-work-package loop

1. Run doctor, state display, and work selector.
2. Read the selected work package, mapped findings, source evidence, architecture, and tests.
3. State the exact failing invariant in the work ledger.
4. Add a test that proves the defect or missing behavior.
5. Implement the smallest coherent production change.
6. Run focused tests.
7. Run the work-package gate validator.
8. Record evidence with source manifest before and after.
9. Update docs and compatibility fixtures.
10. Commit a human-authored checkpoint only after evidence is durable.
11. Continue to the next selected package.

## Parallelism

`P10` may proceed beside `P01` after `P00`. `P08` and `P09` may proceed beside missing-feature work after their baseline. Do not parallelize migrations against the same control-plane tables without a single migration owner.

## Change discipline

- One migration version per coherent schema change.
- Every persistence side effect has an idempotency key or reconciliation rule.
- External provider and process side effects are preceded by durable intent.
- Every UI mutation route returns an operation or receipt identifier.
- Every list or history is paged and bounded.
- Every background loop has cancellation, deadline, jittered retry, and ownership tests.

## No false closure

A phase remains open when its native gate is deferred. A partial mitigation does not close E2. A placeholder UI does not count as a feature. A compiler-only test does not prove runtime behavior. A model statement does not prove completion.

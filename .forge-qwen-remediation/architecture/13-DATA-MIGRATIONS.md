# Data migrations

## New schema areas

- gate registry/executions/results/artifacts;
- package catalog/candidates/ingestion transactions;
- queue packages/runs/leases/events/dependencies;
- project reset operations/backups/receipts;
- filesystem transactions/quarantine;
- retention archives/prune operations;
- runtime XPC bookmark/profile metadata;
- release attestations.

## Migration rules

- one monotonic schema version;
- backup and integrity check before mutation;
- durable migration intent and completion receipt;
- idempotent startup recovery;
- no use of path-only identity for migration backup files;
- migration tests from every supported current fixture;
- rollback by restoring verified backup only before new-version writes are accepted;
- old clients receive a clear upgrade-required response rather than corrupting state.

## Existing data

Legacy continuity projections are imported into exact project/generation records only when provenance is unambiguous. Ambiguous global data is preserved as read-only legacy material and never assigned automatically.

Generic completion evidence is retained for audit display but grants no gate status.

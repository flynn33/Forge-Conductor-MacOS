# Resource pressure and retention

## Coordinator

`ResourcePressureCoordinator` is a manager-owned actor. It combines physical-memory class, current memory-pressure event, thermal state, active run/job counts, database size, provider payload size, and UI visibility into a versioned `EffectiveResourcePolicy`.

Consumers subscribe through a latest-value stream rather than independent polling.

## Consumers

- autonomy concurrency and admission;
- runtime job concurrency/output and artifact budgets;
- provider request/tool-result payload limits;
- telemetry collection and publication cadence;
- gauge frame cadence and animation policy;
- in-memory event windows;
- database archive/prune batch sizes;
- package ingestion concurrency;
- dashboard connection admission.

## Retention

Create policy-aware pruning for provider turns, tool invocations, autonomy events, continuity events, runtime output metadata, dashboard audit, and legacy audit events. Protect:

- active/nonterminal records;
- records referenced by gate/reset/continuity/filesystem receipts;
- latest project health summary;
- legal/user-pinned records if implemented.

Archive in bounded chunks, verify archive checksum, then delete in bounded transactions. Startup resumes incomplete archive operations.

## Observability

Export policy profile, pressure state, effective limits, admission rejections, pruned rows/bytes, protected rows, and last archive status.

# Resource and performance budgets

`plans/resource-budgets.json` defines initial enforceable profiles. Qwen Code may tighten them. It may change a numeric value only with a recorded measurement and decision; it may not remove the budget.

## Pressure signals

- physical memory at startup;
- `DispatchSource` memory pressure;
- thermal state;
- process resident size and compression where available;
- free disk space;
- queue backlog;
- provider payload size;
- active/visible/drawing Metal surfaces.

## Adaptation order

1. reduce UI publication cadence;
2. reduce visible animation FPS within usability bounds;
3. stop hidden drawing;
4. reduce history and event in-memory windows while preserving disk evidence;
5. reduce package/runtime/provider concurrency;
6. defer new jobs;
7. checkpoint active work;
8. reject new work with a retryable resource-pressure receipt.

Never delete active handoffs, gate receipts, reset receipts, queue assignments, or irreversible-operation evidence to meet a memory budget.

## Database retention

Provider, tool, autonomy, continuity, audit, and dashboard histories require per-project row/time/byte caps, archival state, and incremental pruning. Active and referenced rows are protected. Pruning uses bounded batches and is crash-safe.

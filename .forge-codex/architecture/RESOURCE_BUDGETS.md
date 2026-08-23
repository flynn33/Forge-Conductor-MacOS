# Resource Budgets and Adaptive Efficiency

## Principle

Every continuous or retained subsystem has a measurable budget. Limits are conservative defaults and must be validated on the minimum supported machine. Dynamic policy may reduce work under pressure but may not remove features.

The machine-readable values are in `plans/resource-budgets.json`.

## Budget domains

### Telemetry

- bounded mailbox per subscriber;
- bounded metric histories;
- bounded process/sample collections;
- no per-update task creation;
- explicit sample/drop/coalesce counters;
- lower sampling while hidden.

### Gauges

- zero recurring draws while hidden/static;
- shared Metal resource sets;
- bounded active cadence;
- persistent buffers;
- no pipeline compilation after warm-up;
- memory-pressure cleanup.

### Project memory

- bounded query results and response bytes;
- bounded statement/record/search caches;
- paged exports;
- incremental maintenance;
- no full-corpus load;
- per-project disk budget and observability.

### Continuity/model streaming

- bounded chunk channel;
- bounded in-memory message window;
- durable references to older content;
- context reserve before rollover;
- capped retries and deadlines.

### Processes/logs

- bounded stdout/stderr ring buffers;
- rotating files;
- child-process count limits;
- per-operation deadlines;
- process cancellation escalation.

## Memory tiers

Use `ProcessInfo.processInfo.physicalMemory` to select a conservative tier. The tier controls caches and histories, not correctness or feature availability.

- constrained: up to 8 GiB;
- standard: above 8 GiB through 16 GiB;
- expanded: above 16 GiB.

Treat these as initial policy bands. Verify the lowest supported hardware and adjust from measurements. Do not calculate a cache as a large fixed fraction of physical memory; keep absolute ceilings.

## Pressure response

On memory pressure:

1. cancel speculative prefetch;
2. clear search/result caches;
3. reduce histories within minimum functional windows;
4. release hidden renderer surfaces and optional textures;
5. checkpoint and trim SQLite WAL where safe;
6. compact old in-memory model/session content to durable references;
7. preserve active operations and data integrity.

On critical pressure, reject new optional work with a typed recoverable error rather than allowing unbounded growth.

## Measurement

For each representative flow record:

- baseline/steady/peak resident size;
- dirty memory;
- allocation rate;
- object/resource counts;
- queue depths;
- CPU and wakeups;
- GPU/frame cadence;
- database latency and size;
- response latency percentiles.

A budget passes only when the same workload reaches a bounded steady state and returns near its post-warm baseline after the defined release boundary, allowing documented caches.

# Performance Benchmark Specification

## Benchmark harness

Create deterministic XCTest performance tests or a dedicated test harness that can:

- seed representative projects and memory records;
- drive telemetry at controlled rates;
- induce a bounded main-actor stall;
- show/hide/open/close gauge scenes;
- start/cancel subprocess fixtures;
- run MCP requests concurrently;
- trigger continuity rollover against a fake/local provider;
- emit machine-readable measurements.

Use stable random seeds and fixed corpus sizes.

## Required benchmark scenarios

1. cold launch and first project open;
2. warm launch and project reopen;
3. telemetry visible at normal rate;
4. telemetry under burst and main-actor stall;
5. gauges hidden/static/animating;
6. 100 gauge scene cycles;
7. 100 project open/close cycles;
8. process output stress and cancellation;
9. memory corpus write/search/update/export;
10. concurrent MCP clients across projects;
11. repeated continuity rollover and crash recovery;
12. app idle with no active project;
13. memory pressure and low-power policy.

## Measurement window

Separate:

- setup;
- warm-up;
- measurement;
- release/quiescence;
- post-release observation.

Do not blend fixture creation into steady-state metrics unless the scenario is specifically launch/import.

## Results

Write JSON and Markdown containing:

- machine/OS/build/commit;
- scenario and fixture hash;
- iterations/duration;
- p50/p95/p99 latency;
- CPU time;
- wakeups;
- allocation rate;
- resident/dirty memory baseline, peak, post-release, slope;
- gauge draw/resource counts;
- telemetry queue counters;
- database/cache metrics;
- pass/fail against budget;
- raw artifact references.

## Regression logic

Hard invariants must be exact. For continuous metrics, fail when:

- budget ceiling is exceeded;
- after-warm-up memory has a statistically meaningful positive slope in a steady workload;
- performance worsens materially without a documented feature requirement and accepted ADR;
- release/quiescence state does not return within the documented retained-cache allowance.

Run at least five samples for latency distributions unless the scenario is a long soak.

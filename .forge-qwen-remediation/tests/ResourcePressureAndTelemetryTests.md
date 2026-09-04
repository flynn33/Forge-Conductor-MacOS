# Resource pressure, telemetry, and Metal tests

## Deterministic tests

- ring buffer preserves order and capacity through multiple wraps;
- one host sample adds exactly one history point;
- Forge/MCP recomposition adds no host point;
- unchanged state coalesces UI publication;
- pressure policy revisions reach every registered consumer;
- database pruning never removes active/referenced records;
- visible-surface counter follows window/tab/row visibility;
- detached/hidden surface has no recurring draw callbacks.

## Profiling flows

Use identical Debug and Release fixtures where appropriate:

1. idle manager and closed GUI;
2. GUI open on non-Rig tab;
3. Rig visible with maximum bounded devices/processors;
4. 100 navigation cycles;
5. two autonomous runs and runtime jobs;
6. memory-pressure transition;
7. 24-hour or accelerated endurance.

Collect RSS, allocations, retained object paths, CPU, wakeups, GPU, Metal command/buffer counts, database size, event rows, and draw counts. Compare warm steady-state slopes, not only peaks.

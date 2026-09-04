# Performance and Resource Budgets

## Goals

Security hardening must not recreate the project's earlier memory,
telemetry, or rendering failures.

## Budgets

### File descriptors

- base invocation: at most root + traversal depth + 6;
- do not pin the entire tree;
- duplicate a descriptor only for the duration of directory enumeration;
- every descriptor has RAII ownership;
- descriptor count returns to baseline after each operation.

### Memory

- copy/hash buffer: 1 MiB default, 4 MiB maximum;
- name and metadata batches: maximum 1,024 entries;
- large tree manifests stream to SQLite or a bounded temporary record;
- no whole-tree `Data` values;
- no unbounded result arrays;
- preserve current text-file and entry limits unless a stricter security
  limit is required and documented.

### Concurrency

| Profile | Tree mutations | Reads/listing |
|---|---:|---:|
| constrained | 1 | 2 |
| standard | 2 | 4 |
| expanded | 4 | 8 |

Derive profile from the existing resource policy. Do not inspect total
memory on every file operation.

### Transaction storage

- active transaction count bounded per project;
- completed rows compacted after evidence retention;
- quarantine warning at 70%, admission block at 90%;
- unreconciled entries are never silently evicted;
- cleanup uses incremental batches.

### CPU and I/O

- hash while copying, not in a second pass where avoidable;
- avoid subprocess launch for copy/find;
- cancellation check per chunk and directory batch;
- use directory `fsync` only at documented durability boundaries;
- avoid repeated full-root identity resolution during one invocation.

## Qualification

Measure:

- resident memory before/after 1,000 operations;
- open descriptors before/after;
- throughput for 1 KiB, 1 MiB, 100 MiB, and tree workloads;
- cancellation latency;
- recovery duration;
- SQLite row and WAL growth.

No completion claim without numeric evidence and comparison to the PR #11
baseline.

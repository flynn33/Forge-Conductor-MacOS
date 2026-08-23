# Resource-Owner Matrix Procedure

Generate `.forge-codex/state/resource-owner-matrix.json` before resolving lifecycle findings.

For every resource record:

- stable ID;
- concrete type;
- creation file/symbol;
- effective owner;
- intended lifetime;
- start path;
- stop/cancel/close path;
- strong references/callback captures;
- thread/actor domain;
- capacity/budget;
- release-boundary test;
- runtime proof;
- audit finding IDs;
- disposition.

Required resource classes:

- tasks and task groups;
- async streams/continuations;
- timers/display links;
- NotificationCenter observers;
- Combine subscriptions;
- delegates/data sources;
- Process/Pipe/FileHandle;
- dispatch sources/file watchers;
- sockets/listeners;
- database connections/statements/transactions;
- Metal views/delegates/devices/queues/pipelines/buffers/textures;
- caches/histories/queues;
- provider/model streams;
- host adapter operations;
- manual native allocations.

## Dispositions

- `process_lifetime_intentional`;
- `owner_shutdown_proven`;
- `retaining_edge_fixed`;
- `bounded_cache_proven`;
- `framework_owned`;
- `runtime_unreachable`;
- `open`.

Every `open` Critical/High resource blocks completion.

## Proof

Use a release-boundary test and one of:

- weak-reference/deallocation expectation;
- task/process/subscription count returns to baseline;
- memgraph ownership path disappears;
- file descriptor/resource count returns;
- bounded steady-state measurement;
- framework contract with source verification plus runtime behavior.

`deinit` logging alone is insufficient when the code path may never deallocate.

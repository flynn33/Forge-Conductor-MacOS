# FC-CTX-001 decision and change summary

A separate SQLite control plane now owns stable project UUIDs, generations, lifecycle
state, exact owner bindings, authorization snapshots, run identity, reset compare-and-set,
and bounded stale-result quarantine. The connection uses WAL, foreign keys, a bounded busy
timeout, integrity checks, schema versioning, and an idempotent migration receipt.

`ToolRouter` retains its client-ID entry point as a compatibility shim, but project-scoped
tools resolve that client to one exact durable binding or return
`project_context_required`. The explicit invocation-context entry point validates project,
generation, client, run, and authorization scope before authorization or dispatch. Project
memory arguments cannot name a different project, and filesystem/shell authorization uses
only the context's roots.

Project initialization and agent workspace bootstrap create the durable binding without
consulting global continuity state. Short project-memory mutations commit only while the
same generation and binding remain current. Generation reset first enters maintenance,
closes the cached project-memory repository, advances the generation atomically, and
invalidates prior bindings. The manager exposes typed register, status, bind, and
generation-reset commands through its existing loopback control surface.

Two intermediate focused runs exposed test fixtures that reused one client across multiple
projects and compared two path spellings for the same filesystem object. The fixtures were
corrected to use exact per-project owners and filesystem identity; the final 44-test run is
green without weakening the new boundary.

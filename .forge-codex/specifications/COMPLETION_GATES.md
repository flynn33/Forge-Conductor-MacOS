# Completion Gates

The machine-readable gate definitions are in `plans/gates.json`. This document explains their intent.

For completion, `completion_requires` and the gate definitions must declare
exactly the ordered canonical inventory `G00` through `G12`. An omission,
extra gate, duplicate, reorder, empty criterion list, duplicate criterion, or
gate identifier that does not match its position fails closed. `G00` through
`G11` are prerequisite gates; `G12` is the final admission transaction and is
not evidence for a missing prerequisite.

## G00 — environment and reproducibility

- project shape and schemes/products recorded;
- one build/run entrypoint works;
- environment doctor archived;
- Git state preserved;
- baseline command log complete.

## G01 — feature baseline

- feature inventory exists;
- existing MCP schemas/transcripts captured;
- persistence fixtures captured;
- critical UI and commands inventoried;
- no unknown affected feature remains for the next phase.

## G02 — baseline observability

- OSLog categories and signposts cover telemetry delivery, gauge scheduling, memory requests, rollover transitions, process lifecycle, and migrations;
- logs contain no secrets/raw content;
- baseline traces/reproducers captured.

## G03 — bounded telemetry

- queue invariant proven under induced main-actor stall;
- latest value converges;
- stale subscribers receive nothing;
- shutdown releases bridge/tasks;
- mappings and units pass.

## G04 — efficient gauges

- resources shared as designed;
- hidden/static draw count is zero after quiescence;
- no update-path Metal buffer churn;
- repeated open/close releases scene resources;
- performance trace meets budget and preserves visuals/actions.

## G05 — lifecycle and concurrency

- every E2 audit finding has a traced owner and status;
- confirmed retaining edges fixed and re-proven;
- tasks/timers/observers/processes/pipes close;
- sanitizers and concurrency tests pass.

## G06 — bounded application state

- histories/caches/logs/process output have enforced limits;
- memory-pressure behavior passes;
- main actor has no known blocking paths;
- project/session close reaches bounded steady state.

## G07 — project memory MCP

- schema/migrations/integrity pass;
- tool contracts and existing MCP compatibility pass;
- project isolation, restart durability, search bounds, cancellation, and redaction pass;
- stress and resource budgets pass.

## G08 — continuity engine

- durable checkpoint and handoff pass;
- transition/crash matrix passes;
- handoff compactness and integrity pass;
- resume uses exact acknowledged handoff;
- project concurrency passes.

## G09 — host adapter/plugin

- capability detection proves whether existing host is sufficient;
- required native plugin target exists and builds;
- full autonomous rollover passes with no operator action;
- external MCP-only clients retain supported memory/handoff behavior;
- no private UI automation is used.

## G10 — feature parity and migrations

- all baseline features preserved/additive/migrated;
- old data fixtures migrate and reopen;
- MCP compatibility snapshots pass;
- UI commands/settings/accessibility pass.

## G11 — release resource validation

- Release build profiling on minimum supported or lowest available representative Mac;
- telemetry/gauge/memory/rollover stress;
- no unbounded trajectory;
- budgets and degradation policies pass;
- diagnostics and logs are bounded.

## G12 — final quality

- full test matrix passes;
- unresolved critical/high findings are zero;
- package/attribution/security scans pass;
- completion report links every hard gate to evidence;
- `verify_completion.py` exits zero.

## No paper passes

A gate result must include command, environment, exit code, artifacts, hashes, and an evaluator result. Manually editing the gate ledger to `passed` without evidence invalidates completion.

Gate admission and final completion require an exact crash-consistent pair.
For every gate, the canonical repository result, run-state item, and one
`gate_status` event must all be `passed` and carry the same canonical UUID-v4
operation identifier. The event writer emits a separate fresh UUID-v4
`event_id`; the paired event must be at exactly `state_sequence_before + 1`
and contain the exact ordered runner evidence payload. The result must be
`finalized: true`, and the state evaluator must be its canonical result path.
Missing, oversized, legacy, non-finalized, non-UUID-v4, duplicate-operation,
wrong-sequence, or mismatched records rerun or fail closed.

Each successful result binds exactly three canonical runner artifacts, in
order: `Gxx.stdout.txt` as `stdout`, `Gxx.stderr.txt` as `stderr`, and
`Gxx.criteria.json` as `criteria`. The result records the exact SHA-256 for
each; the command hashes must equal the stdout and stderr artifact hashes; the
criteria bytes must decode to the exact ordered evaluator criteria with
literal Boolean passes; state evidence IDs and the event payload must match
those artifact hashes. Each result also records the exact Git HEAD, bounded
source manifest, and pre-gate state-event sequence. The runner rejects source
change during the handler, and the batch selector skips only when the stored
HEAD and manifest still match current source. This pairing prevents
interrupted publication from becoming a paper pass; it is not evidence
authentication or a substitute for current-source, signed-host, native UI,
continuity, or hardware proof.

The completion validator uses strict owner-controlled 1 MiB JSON inputs under
a 64 MiB control budget, bounded artifact hashing, 1 MiB atomic completion
reports, and the source-manifest-bound G12 handler. It rejects unresolved
Critical or High entries from both findings resolution and the live issue
ledger; missing or malformed ledgers fail closed. G02 through G11 require a
matching acceptance record whose `gate_id` exactly matches the invoked gate and
whose `current_release_authority` is the literal Boolean `true`; missing,
`null`, numeric, string, or historical authority fails closed. The shared
gate-local acceptance validator enforces the same condition before a criterion
sidecar can be admitted, so a historical record cannot publish a current gate
pass while merely remaining blocked at final completion.
Every prerequisite result must bind the same clean current HEAD and source
manifest.

The JSON completion report's `admission_contract` binds the schema and run ID,
canonical repository, current Git HEAD and source manifest, pre-G12 state
sequence, exact ordered prerequisite inventory `G00` through `G11`, and for
each prerequisite the gate ID, canonical UUID-v4 operation ID, SHA-256 of the
exact result JSON bytes, and byte count. G12 runs the validator without
finalizing, then its criteria sidecar binds the exact path, SHA-256, and byte
count of both `completion-report.json` and `completion-report.md`; every G12
criterion cites those two report digests. The reports must be successful,
current, and evaluated inside the G12 runner interval.

G12 is published through the normal gate transaction and reread as an exact
finalized operation pair. Under the state lock, finalization rechecks all 13
gates and their exact stdout, stderr, and criteria artifacts; the typed issue
ledger; the G12 report and operation bindings; current clean source identity;
and the exact one-event sequence increment. The committed run state persists
`completion_authority` containing the exact G12 operation UUID and the final
status-operation UUID. The final status event must be the next event, so a
complete state is bound to the G12 snapshot plus exactly one status
transaction.

Completion is revalidated when complete state is read with `statectl show` and
when it is checked with `statectl validate`; a stale HEAD, manifest, artifact,
report, ledger, operation, sequence, or persisted authority fails closed rather
than being trusted as historical status. Retrying the exact final status UUID
and request is idempotent, re-runs the completion precondition, and creates no
second event. Reusing that UUID for a different request fails closed. Any later
non-idempotent state mutation demotes the run to `active` and removes the
persisted completion authority.

Runner artifact admission is bounded at 64 MiB per artifact and 512 MiB in
aggregate across the canonical stdout, stderr, and criteria artifacts for all
13 gates. Package and scan admission independently uses 65,536 observed
entries, 128 directory levels, 64 MiB per file, and 512 MiB aggregate input.
Scanner findings stop at 10,000; package child output is capped at 16 MiB with
a 300-second deadline, and its report is capped at 16 MiB.

These checks are observational. A same-UID or ACL-authorized writer can still
win after the last observation and before status publication, or forge a
coherent set before a later read. One win can persist as one false completion
status and an erroneous release decision until trusted revalidation and
requalification; repeated wins can sustain that false release state
indefinitely. It adds no direct product-filesystem mutation authority. This is
mitigation, not elimination, so E2, P10, G10, G12, native signing/UI,
real-provider continuity, and owner-deferred hardware qualification retain
their existing open or blocked conclusions until their required evidence
exists.

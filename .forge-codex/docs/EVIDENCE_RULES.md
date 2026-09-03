# Evidence Rules

## Purpose

All defect determinations, fixes, and completion claims must be traceable to source, runtime, protocol, or test evidence. This prevents both speculative rewrites and false closure.

## Finding record

Every finding must include:

| Field | Requirement |
|---|---|
| ID | Stable identifier |
| Class | E0, E1, E2, or E3 |
| Severity | Critical, High, Medium, Low |
| Scope | Feature, type, file, symbol, lifecycle |
| Evidence | Exact path/line, trace, transcript, or test |
| Reproducer | Deterministic steps or fixture |
| Expected lifetime/behavior | Explicit contract |
| Actual behavior | Observed or source-proven |
| Root retaining/causal edge | Named when known |
| Fix | Smallest corrective change |
| Feature impact | Baseline feature IDs |
| Validation | Before/after command and artifact |
| Status | Open, patching, validating, resolved, deferred |

## Evidence classes

### E0 — observed runtime proof

Examples:

- a memgraph trace shows an app-owned root retaining an object after the release boundary;
- a stress test shows monotonically increasing bounded-queue depth;
- an MCP transcript violates the schema;
- a UI performance trace shows recurring hidden gauge draws;
- a test deterministically fails.

### E1 — deterministic source proof

Use only when source semantics force the conclusion. Examples:

- every telemetry update launches an independent task that captures the snapshot, with no queue capacity or cancellation;
- each gauge constructor creates a command queue and immutable pipeline;
- a switch maps distinct metrics to one constant value;
- blocking `waitUntilExit()` executes on the main actor.

E1 supports a corrective patch, but memory-leak language still requires E0 if the claim is that an object remains live after its intended boundary.

### E2 — source risk requiring reachability

Examples:

- a NotificationCenter block observer token has no visible owner-local removal;
- a stored Task has no owner-local cancellation;
- a delegate is strongly retained;
- a FileHandle readability handler is assigned without a nearby clear.

Trace the effective owner and shutdown path before promoting.

### E3 — profiling target

Examples:

- broad observation might fan out;
- a view body performs potentially expensive derived work;
- a history may be larger than necessary.

Measure first.

## Reproduction quality

A valid reproducer states:

- commit and build configuration;
- machine and macOS version;
- fixture/project;
- launch state;
- exact actions and durations;
- expected release or quiescence boundary;
- collection commands;
- pass/fail predicate.

Random manual clicking is supplementary, not the only proof.

## Before/after comparison

Hold constant:

- code path except the patch;
- machine;
- configuration;
- fixture;
- sample duration;
- warm-up;
- interaction sequence;
- instrumentation;
- statistical aggregation.

Report medians and upper percentiles where multiple samples exist. Do not infer a leak fix solely from a lower peak.

## Evidence storage

Store the index under `.forge-codex/state/evidence-index.json`, as generated atomically by `.forge-codex/scripts/build_evidence_index.py`. Large traces may live under an external run directory referenced by absolute path and SHA-256. Never commit secrets or raw private project content.

Each evidence record must include the generating command, exit code, start/end time, environment summary, artifact hash, and related gate IDs.

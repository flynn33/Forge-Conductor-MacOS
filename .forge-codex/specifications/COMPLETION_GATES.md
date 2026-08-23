# Completion Gates

The machine-readable gate definitions are in `plans/gates.json`. This document explains their intent.

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

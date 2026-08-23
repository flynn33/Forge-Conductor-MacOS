# Autonomous Operation and Resumption

## Two autonomy layers

This package addresses two separate continuity problems:

1. **Codex repair-run continuity** — repeated Codex invocations resume from `.forge-codex/state`, the current handoff, Git state, and evidence.
2. **Forge Conductor product continuity** — the application persists project memory and creates successor model sessions through a supported host adapter.

Neither layer relies on a model remembering an earlier context after it has ended.

## Repair-run state

The repair ledger records:

- phase and gate status;
- attempts and no-progress signatures;
- issues/findings;
- decisions;
- commits;
- evidence references;
- environment capabilities;
- current work;
- handoffs.

Every invocation begins by validating the hash-chained event journal and selecting ready work. Every invocation ends by persisting a handoff.

## Headless Codex execution

`scripts/run_codex_autonomously.sh` can drive repeated noninteractive Codex CLI invocations when the CLI is installed. It discovers supported CLI flags from `codex exec --help` instead of assuming every version has the same options.

The driver:

- initializes the repository;
- starts bounded invocations;
- checks the persistent run status;
- detects three no-progress invocations;
- records diagnostic mode;
- writes a handoff after each invocation;
- stops only on completion, fatal integrity state, or a bounded invocation ceiling.

The bounded ceiling prevents an infinite paid/compute loop. Reaching it preserves all progress and is not a completion claim.

## Context-window behavior during a repair invocation

Codex should create a handoff before it loses sufficient context to serialize current state. The package does not require access to hidden token counters. It uses:

- host/provider usage when exposed;
- model-declared capacity when exposed;
- conservative serialized-state estimates;
- periodic checkpoint boundaries after material edits and test runs;
- an emergency handoff when context overflow is reported.

The handoff is generated from structured state, not only narrative recollection.

## No-operator resolution

The run never asks for design selection. It may record an environment blocker, but it continues all independent work. The only legitimate terminal blocker is an integrity invariant that makes further mutation unsafe.

Credentials, signing, and unavailable proprietary host APIs are handled as follows:

- use local fakes for deterministic tests;
- use existing configured secure credentials when available;
- do not embed credentials;
- use signing-disabled local validation when signing is unrelated;
- build Forge-native host orchestration when an external host lacks a supported creation API;
- keep the corresponding release gate open until a capable environment verifies it.

## Crash and interruption recovery

The run-state update precedes risky external effects. Temporary files and atomic rename protect JSON state. Events are append-only and hash chained. Git checkpoints and evidence hashes allow reconstruction when the current process is terminated.

The same principles are required in the product continuity coordinator.

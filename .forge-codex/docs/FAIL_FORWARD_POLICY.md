# Fail-Forward Policy

## Goal

Retain verified progress and keep independent work moving when a command, tool, test, host, or implementation path fails. Fail-forward never means bypassing a release gate.

## Persistent state

The canonical ledger is `.forge-codex/state/run-state.json`. Updates must be:

- written to a temporary sibling;
- flushed and atomically renamed;
- accompanied by an append-only event in `events.jsonl`;
- idempotent through operation IDs.

At minimum, state records phases, attempts, gates, issues, decisions, commits, evidence, host capabilities, and the current handoff.

## Failure classes

### Transient

Examples: temporary file lock, child process startup race, model endpoint interruption.

Action:

- retry with exponential backoff and jitter;
- cap attempts and total duration;
- preserve idempotency;
- record each attempt;
- continue when successful.

### Local blocking

Examples: one target fails while independent package tests can proceed.

Action:

- open an issue;
- mark dependent gates blocked;
- continue ready phases outside the dependency cone;
- revisit after related fixes.

### Environment blocking

Examples: Xcode or Metal profiling unavailable in the current environment.

Action:

- run all portable checks;
- generate exact deferred commands and fixtures;
- mark runtime gates `blocked_environment`;
- do not declare completion;
- automatically execute them when the capability appears.

### Design dead end

Action:

- revert only the isolated failed change;
- retain reproducer and evidence;
- choose the next reversible design from the decision policy;
- do not restart the entire effort.

### Fatal invariant

Examples: no recoverable copy exists before a destructive migration, or required compatibility cannot be preserved through any supported API.

Action:

- stop destructive work;
- preserve all state and evidence;
- mark `fatal_invariant`;
- continue only non-mutating diagnosis.

## No-progress detector

A work item is stalled when three consecutive attempts:

- make no source/test/state change;
- reproduce the same failure signature; and
- add no new evidence.

On stall:

1. create the smallest reproducer;
2. enable targeted logging/signposts;
3. inspect ownership/protocol boundaries;
4. choose an alternate implementation;
5. reset the attempt counter only after new evidence or changed behavior.

## Gate semantics

- `hard`: required for completion.
- `hard_runtime`: required on a capable macOS machine.
- `compatibility`: required when the associated legacy surface exists.
- `advisory`: records useful quality but does not independently block.
- `deferred`: temporary state, never equivalent to pass.
- `waived`: prohibited unless the underlying capability is proven absent from the feature baseline and the waiver is itself validated.

## Automatic resumption

At each interruption boundary, write a handoff. The next invocation:

1. validates ledger integrity;
2. reads the latest acknowledged or pending handoff;
3. verifies Git and build state;
4. selects the highest-priority ready phase;
5. resumes without repeating an operator question.

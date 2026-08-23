# Execution Contract

## 1. Objective

Repair and extend Forge Conductor without feature loss, then prove the result under repeatable functional, protocol, lifecycle, concurrency, and resource tests.

The run is autonomous after initialization. Codex makes and records technical decisions, executes commands, edits source, builds, tests, profiles, debugs, and resumes after interruption. It does not request the operator to resolve implementation ambiguity.

## 2. Source of truth hierarchy

When evidence conflicts, apply this order:

1. Current executable behavior and committed data/protocol compatibility.
2. Existing tests that accurately describe supported behavior.
3. Public declarations, settings, command identifiers, MCP schemas, and persisted formats.
4. Audit runtime evidence and deterministic source evidence.
5. Product requirements in this package.
6. Existing documentation.
7. Reversible implementation preference.

A failing existing test is not automatically authoritative. Classify whether it represents the product contract, a regression, a stale expectation, an environment problem, or a flake. Record evidence before changing it.

## 3. Work-unit contract

Every work unit must have:

- a phase and issue identifier;
- an explicit hypothesis or requested capability;
- source or runtime evidence;
- affected feature identifiers;
- intended ownership and lifetime;
- a smallest viable change;
- targeted tests;
- a rollback path;
- before/after evidence;
- a gate result.

Do not combine unrelated lifecycle, UI, persistence, and protocol changes into one unreviewable edit.

## 4. Autonomous decision behavior

Codex must not pause for operator selection. When multiple valid implementations exist:

1. reject any option that violates compatibility or resource invariants;
2. prefer Apple-native frameworks and existing project abstractions;
3. prefer the smallest reversible change;
4. prefer bounded data structures and explicit ownership;
5. prefer compile-time registration over dynamic code loading;
6. prefer an actor or serial executor for mutable service state;
7. benchmark when performance differentiates otherwise valid options;
8. document the chosen option and rejected alternatives in the decision log.

When an external dependency or undocumented API would be required, build an internal adapter or native fallback instead.

## 5. Git safety

- Detect the current branch, remotes, worktrees, submodules, and dirty files.
- Never discard or overwrite unrelated changes.
- Never use `git reset --hard`, destructive checkout, history rewriting, forced push, or blanket file deletion.
- Create an autonomous repair branch when possible.
- Commit at validated phase boundaries using factual messages.
- Do not add automated authorship trailers.
- Store generated traces and large artifacts outside the repository unless the repository already has an evidence convention.
- Record commit hashes in run state and handoffs.

## 6. Build discipline

- Discover `.xcworkspace`, `.xcodeproj`, and `Package.swift`; record ambiguity.
- Use `xcodebuild -list` or `swift package describe` to identify schemes/products.
- Build the narrowest affected target first.
- Build the complete application before phase completion.
- Test Debug and Release configurations where resource behavior matters.
- Disable signing only for local validation when signing is unrelated to the behavior.
- Do not claim a launch or UI state that was not observed.
- Keep one project-local `script/build_and_run.sh` as the reproducible build/launch entrypoint.

## 7. Test discipline

Classify failures as:

- compiler;
- linker;
- signing/entitlement;
- assertion;
- crash/signal;
- hang/deadlock;
- race;
- resource regression;
- migration/data corruption;
- protocol compatibility;
- environment/fixture;
- flake.

Run the smallest failing scope first. Re-run the identical flow after a fix. A test may be quarantined only with an open issue, reproducible flake evidence, and no effect on a hard completion gate.

## 8. Runtime proof discipline

For memory:

- capture the exact create/use/release flow;
- identify the first app-owned retained type;
- inspect ownership paths or grouped leak trees;
- prove expected deallocation or bounded steady state;
- compare identical flows and durations;
- separate retained caches from unreachable leaks.

For performance:

- measure Release builds;
- use signposts around action boundaries;
- compare CPU time, frame pacing, wakeups, allocations, resident-size trajectory, Metal cadence, database latency, and queue depth;
- use distributions, not one anecdotal sample;
- retain raw traces and a summarized result.

For telemetry:

- verify event production, coalescing, delivery, mapping, presentation, and shutdown;
- use sequence IDs and counters;
- demonstrate no stale post-shutdown delivery.

## 9. Compatibility

Maintain:

- macOS deployment target and architecture support unless a required Apple API forces a documented change;
- persisted project formats;
- settings/default keys;
- MCP server identity, existing tools, and response shapes;
- integrations with supported model/host clients;
- accessibility and keyboard command surfaces;
- import/export behavior.

Use additive versioning, migrations, aliases, and deprecation telemetry when change is necessary.

## 10. Security and privacy

- Do not log secrets, tokens, raw prompts, private project contents, or entire memory records.
- Redact credentials before memory ingestion and handoff generation.
- Use least-privilege file permissions and atomic writes.
- Validate project paths and prevent traversal outside authorized roots.
- Bind any local network endpoint to loopback unless the product contract explicitly requires otherwise.
- Authenticate non-stdio transports.
- Treat MCP input as untrusted.
- Use prepared SQLite statements and strict JSON decoding.
- Bound all incoming and outgoing payloads.

## 11. Exit conditions

The run can end only in one of these states:

- `complete`: all hard gates pass and the completion validator exits zero;
- `blocked_environment`: implementation is complete but a required macOS/runtime gate cannot execute in the current machine; no success claim is allowed;
- `fatal_invariant`: continuing would corrupt user data or destroy compatibility and all reversible alternatives are exhausted.

Ordinary build failures, missing optional tools, flaky tests, host outages, and individual design dead ends are not terminal.

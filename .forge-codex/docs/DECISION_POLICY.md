# Autonomous Decision Policy

## Decision hierarchy

Resolve implementation questions in this order:

1. Preserve verified current behavior and data.
2. Satisfy explicit package requirements and hard gates.
3. Follow Apple public APIs and platform conventions.
4. Reuse proven project abstractions when their ownership is sound.
5. Choose the least destructive reversible design.
6. Prefer bounded, testable, observable components.
7. Benchmark materially different performance choices.
8. Record the decision and continue.

Do not ask the operator to choose a technical option covered by this hierarchy.

## Default resolutions

| Situation | Autonomous resolution |
|---|---|
| Multiple project files/schemes | Prefer the workspace and application-producing shared scheme; test all package targets |
| Existing dirty work | Preserve it, inventory it, and layer changes without reset |
| Missing test coverage | Add characterization tests before behavior change |
| Conflicting tests and behavior | Determine the supported contract from public surfaces and fixtures; repair the stale side with evidence |
| Missing documented host session API | Implement Forge-native host orchestration through the plugin contract |
| External host supports memory MCP but not session creation | Preserve MCP compatibility; autonomous rollover is provided in Forge-native host mode |
| Dynamic plugin loading would increase risk | Use compile-time registered plugin targets |
| Third-party package appears convenient | Prefer Apple-native implementation unless the package is already required and passes dependency/security review |
| Migration ambiguity | Preserve old data, version the schema, migrate transactionally, keep a backup and rollback path |
| Performance choice lacks evidence | Implement an isolated benchmark and select from measurements |
| Optional profiler unavailable | Continue source/tests; keep the runtime gate open and retry on a capable macOS environment |
| Transient process/network failure | Bounded retry with jitter and deadline; persist failure; continue independent work |
| No progress after repeated fixes | Reduce to a minimal reproducer and take the reversible alternate path |

## Prohibited defaults

Do not:

- silence errors;
- discard data;
- remove features;
- lower assertions;
- disable telemetry;
- replace a bounded requirement with a larger arbitrary cap;
- introduce infinite retry;
- block the main actor;
- use accessibility or AppleScript to drive an unsupported external chat UI;
- store entire chat transcripts as memory by default;
- use a single global project namespace;
- make caches process-lifetime without a budget and eviction policy.

## Decision log

Record material choices in `.forge-codex/state/decisions.md` using:

- date/time;
- decision ID;
- problem and evidence;
- constraints;
- alternatives;
- selected option;
- resource/lifecycle effects;
- compatibility effects;
- tests and rollback.

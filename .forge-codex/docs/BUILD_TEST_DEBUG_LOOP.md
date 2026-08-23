# Build, Test, Debug, and Repair Loop

## Discovery

Before commands:

1. detect workspace/project/package;
2. list schemes/products/targets;
3. identify app executable and process name;
4. identify test targets and host app requirements;
5. record deployment target and build settings;
6. preserve existing scripts and CI behavior.

Update `script/build_and_run.sh` into a project-specific kill/build/launch entrypoint rather than leaving repeated ad hoc commands.

## Loop

For each work item:

```text
characterize → reproduce → instrument → patch → focused build/test
→ same-flow validation → broader regression → evidence → checkpoint
```

### Characterize

State expected behavior, actual behavior, affected feature IDs, owner/lifetime, and evidence class.

### Reproduce

Use a deterministic fixture and a bounded timeout. Record the command before modifying source.

### Instrument

Add only the minimum counters/logs/signposts needed to distinguish hypotheses. Logs use stable OSLog categories and privacy annotations.

### Patch

Prefer the smallest ownership or scheduling correction. Do not combine unrelated cleanup.

### Focused validation

Build the affected module and run the smallest tests first. Fix compile and test failures locally.

### Same-flow validation

Repeat the exact reproducer and compare the same metrics.

### Broader regression

Run related package, app, MCP, UI, migration, sanitizer, and stress suites according to the phase.

### Evidence and checkpoint

Capture command output/artifact hashes, update the finding and feature baseline, commit a coherent checkpoint, and write a handoff.

## Failure triage

### Compiler/linker

Fix the first causal diagnostic, not every cascade. Check target membership, actor isolation, visibility, generic constraints, and linkage.

### Signing/entitlement

Separate local functional validation from release signing. Do not weaken runtime security capabilities merely to bypass signing.

### Assertion

Determine whether the assertion reflects preserved product behavior or a stale test. Keep a record before changing either.

### Crash

Capture symbolicated backtrace, exception/signal, relevant logs, and the smallest flow. Use sanitizers or memgraph when appropriate.

### Hang

Use bounded timeouts, sample the process, inspect main actor and lock/actor waits, process pipes, and synchronous I/O.

### Race

Reproduce under TSan and deterministic concurrency stress. Repair ownership/isolation rather than suppressing diagnostics.

### Resource regression

Measure Release with a warm-up and steady-state window. Inspect queue/resource counts and retaining paths.

### Migration/protocol

Preserve the original artifact/transcript, add a fixture, make the change additive or versioned, and prove round trip.

### Flake

Repeat identical tests, inspect fixture/state isolation, clock assumptions, and eventual conditions. Do not increase arbitrary sleeps as the primary fix.

## Clean validation

Before final completion:

- fresh checkout/worktree;
- package installation;
- all builds and tests;
- migration fixtures;
- MCP conformance;
- UI/feature parity;
- sanitizer runs;
- Release stress/profiling;
- restart/recovery;
- scanners;
- completion validator.

# Forge E2 Repository Instructions

These instructions apply to all work under `.forge-e2` and to every source
change made to close E2.

## Priority

1. Preserve user data.
2. Preserve project isolation and project generation fencing.
3. Preserve shell access and legacy shell compatibility.
4. Close path-based TOCTOU by construction.
5. Preserve all existing public tool contracts unless an additive field is
   required for versioning, transaction receipts, or conflict reporting.
6. Bound memory, descriptors, subprocesses, output, retries, and recovery.

## Source-of-truth hierarchy

1. Current repository source and tests.
2. Current repository `AGENTS.md` and `.forge-codex` workflow.
3. This package's security invariants and work graph.
4. Primary Apple API sources in `docs/15-RESEARCH-SOURCES.md`.
5. The uploaded autonomy plan in `inputs/Plan Forge Conductor Autonomy.txt`.

When source has advanced beyond the baseline, adapt the implementation;
do not revert later fixes.

## Required coding constraints

- Swift remains the orchestration language.
- Add a small native C interoperability target only for Darwin calls and
  constants that are awkward or unsafe to import directly into Swift.
- Keep C wrappers thin; business state machines remain in Swift.
- Use Swift actors for transaction coordination and bounded mutation
  admission.
- Use RAII descriptor wrappers.
- Mark ownership and cancellation boundaries explicitly.
- Never store an open descriptor in SQLite.
- Persist identities, relative paths, states, and receipts; reopen and
  revalidate after restart.
- Paths may be logged for diagnosis but are never authority.

## Test-first rule

Before replacing an existing behavior, add a characterization test.
Before closing a race, add a deterministic race hook that demonstrates the
old failure or the forbidden interleaving.

## Shell preservation

Any change that causes `shell_exec` to disappear, default off, stop
executing `/bin/bash -lc`, or change its established result fields is a
release blocker. New clean-profile runtime tools remain additive.

## Completion

The only valid completion path is
`docs/13-RELEASE-COMPLETION-CONTRACT.md`.

---
name: forge-conductor-repair
description: Execute the evidence-bound, fail-forward repair program for Forge Conductor while preserving every existing feature.
---

# Forge Conductor Repair

Use this skill for any source edit, test, build, audit, or completion decision in the Forge Conductor repair run.

## Required workflow

1. Read `.forge-codex/state/run-state.json` and the current handoff.
2. Select work with `.forge-codex/scripts/select_next_work.py`.
3. Read the matching phase and architecture documents.
4. Name the issue, evidence class, feature IDs, owner, and release boundary.
5. Add or identify the smallest reproducer.
6. Make a narrow reversible edit.
7. Build the affected target and run focused tests.
8. Re-run the identical reproducer.
9. Record evidence and update the ledger.
10. Create a handoff before ending the invocation.

## Guardrails

- Do not ask the operator to choose an implementation.
- Do not discard dirty work or data.
- Do not remove/rename existing behavior to simplify repair.
- Do not promote an ownership risk to a live leak without runtime proof.
- Do not create unbounded work or retained state.
- Do not mark a gate passed without command-backed artifacts.

## Completion

Only `.forge-codex/scripts/verify_completion.py` may finalize the run.

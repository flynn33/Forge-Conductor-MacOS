# Coherent resume — SLICE-03 verification

**Status:** behavior verified working — no source change required. The incident was inconsistent caller input, not a production defect.
**Evidence class:** E0 (source reading of the save/merge paths + executed focused tests on this checkout).
**Date:** 2026-09-12
**Base:** `main` @ `b6548b7` (PR #40 merge) · branch `qwen-slice-03-coherent-resume`
**Host:** macOS 26.6.2 (25G83) · Apple Swift 6.3.3 (arm64-apple-macosx26.0)

## Case determination

The incident report described a handoff packet whose `narrative` and `resume_seed` selected different assignments. Reading the production save/merge paths (`HandoffPacket`, `ContextContinuityService.buildPacket` / `checkpoint` / `handoff` / `autoPersist` / `budgetAutoCheckpoint`) shows:

- A generated default seed is computed only from the packet's own current fields (`defaultResumeSeed`) and is regenerated on every save that does not supply an explicit seed, so it cannot point at an older assignment.
- A custom (caller-supplied) `resume_seed` is retained verbatim across saves until the caller supplies a different one. This is pinned behavior: `testCheckpointUpdatePreservesExplicitResumeSeed`, `testBudgetHandoffPreservesExplicitAndLegacyCustomResumeSeeds`.
- The runtime paths (`autoPersist`, `budgetAutoCheckpoint`) never re-purpose an assignment: they fill only blank fields and append provenance notes, and they keep a prior custom seed only on a packet whose assignment they did not change.

A stored packet whose narrative and seed select different assignments can therefore only arise from caller-supplied data: the caller reworded the assignment (goal / narrative / next actions) without supplying a `resume_seed` matching the new assignment, and the source correctly retained the earlier explicit seed. The source never generates or merges a direction from another packet.

**Conclusion: inconsistent caller input. No production bug was fixed; no source file changed.**

## Checks and results

| Check | Command | Result |
|-------|---------|--------|
| Focused regression (isolated store) | `swift test --filter 'ContinuityTests/testCoherentResumeKeepsCurrentAssignmentAcrossSaveAndRestore'` | PASS — `Executed 1 test, with 0 failures (0 unexpected)`, exit 0 |
| Closest existing seed / save / restore tests | `swift test --filter 'ContinuityTests/testCheckpointAndContextGetRoundTrip' --filter 'ContinuityTests/testHandoffMarksResumeReadyAndSnapshotsAgents' --filter 'ContinuityTests/testCheckpointUpdateRegeneratesDefaultResumeSeed' --filter 'ContinuityTests/testCheckpointUpdatePreservesExplicitResumeSeed' --filter 'ContinuityTests/testBudgetHandoffPreservesExplicitAndLegacyCustomResumeSeeds'` | PASS — `Executed 5 tests, with 0 failures (0 unexpected)`, exit 0 |

The regression fixture is disposable and isolated (one clearly superseded old task plus one current slice, saved and restored through the real `session_handoff` / `session_checkpoint` / `context_get` tool paths). It asserts field-level agreement of goal, narrative, next action, and resume instruction; that an open-PR pause survives restoration as a pause; and that the superseded record reads back exactly as saved. It does not load the incident packet and does not touch live continuity storage.

## Caller responsibility (verified)

When a continuity tool accepts `goal`, `narrative`, `next_actions`, or `resume_seed`, the caller must populate the supported fields coherently: each must describe the same active slice and the same pause state. Rewording an assignment without a matching `resume_seed` is a caller error — the source retains the earlier explicit seed, which is documented behavior, not a defect. When rewording an assignment, supply a fresh `resume_seed` naming the current slice, stage, next action, and pause.

## Current progress record

On restore, the operator-selected current record (handoff `120ef600-bb81-424c-b77a-ac9df6405eaa`) returns a narrative and resume seed consistent with each other, both selecting the current slice. At the pause for owner review it is re-finalized through the handoff card with all four fields describing the same slice and pause state; no immutable historical revision is rewritten.

## Not claimed

- No production source file was modified, so no production bug is claimed fixed.
- Ordinary app build, app-hosted tests, and native UI paths were not run in this slice (test + documentation change only).

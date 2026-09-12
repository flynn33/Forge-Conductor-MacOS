# Project generation reset isolation — SLICE-06 verification

**Status:** behavior verified working — no source repair required. The service-boundary reset (`ManagerNode.resetProjectGeneration` → `ProjectContextService.beginReset`/`completeReset`) resets only the selected project: it advances that project's generation, invalidates its active work, and fences its client, while a second project's records, bindings, and generation remain untouched and persisted global settings are unchanged. The one uncovered isolation case (cross-project reset isolation at the service boundary) gained a focused regression.
**Evidence class:** E1 (executed focused tests on this checkout against disposable fixtures).
**Date:** 2026-09-12
**Base:** `main` @ `516f1b6` (PR #43 merge) · branch `qwen-slice-06-reset-service`
**Host:** macOS 26.6.2 (25G83) · Apple Swift 6.3.3 (arm64-apple-macosx26.0)

## Deliverable

Verify or repair the existing service operation that resets the selected project's requested memory/continuity stores without affecting another project.

## What was confirmed

- **Selected reset (service boundary).** `ManagerNode.resetProjectGeneration` fences retained filesystem-recovery authority, refuses while a registration is pending, then runs `beginReset` (active → resetting compare-and-set; revokes the current generation's continuity authorizations and their source `agent_session` bindings) → the injected checkpoint → closes the project's open memory store → `completeReset` (invalidates active bindings, generation 1 → 2 compare-and-set back to active, appends `project_generation_reset`, returns the receipt). A checkpoint or completion failure cancels the reset back to active, and a failed cancellation surfaces `resetCancellationFailed`.
- **Selected-project invalidation.** The selected project's active mcpClient binding is invalidated (receipt `invalidated_binding_count: 1`); the project advances to generation 2 with lifecycle `active`; its client's `project_memory.status` is fenced with `project_context_required`; a repeat reset at the prior generation fails with `stale_project_generation`; after the client re-initializes at the new generation, its durable record reads back intact (a reset fences prior-generation work; it does not delete durable records).
- **Other-project isolation.** The second project keeps generation 1, lifecycle `active`, and its still-valid binding: `project_memory.status` still succeeds, its own record is still found by search (count 1), and a search for the selected project's record returns 0. Every invalidation statement in the reset flow is scoped by `project_id` (and `project_generation`), so no path reaches another project.
- **Global provider settings.** The persisted global budget-policy snapshot, read under the configuration file lock, is identical before and after the reset; the reset flow never writes configuration.

## Checks and results

| Check | Command | Result |
|-------|---------|--------|
| Focused project-context integration class (selected-project fencing, stale-generation rejection, other-project preservation, global settings) | `swift test --filter ProjectContextIntegrationTests` | PASS — `Executed 10 tests, with 0 failures (0 unexpected)`, exit 0 |

The focused tests use a fresh isolated temporary home per test, seed only disposable fixture records, and never touch real user data or unrelated project records. No production reset was executed.

## Change made in this slice

- `Tests/ForgeConductorTests/ProjectContextIntegrationTests.swift`: added `testGenerationResetIsIsolatedFromOtherProjectsAndPreservesGlobalSettings` (two-project fixture, selected reset through the manager service, selected-project fencing + stale-generation rejection, other-project preservation, global-settings invariance, durable record survival after re-initialization).
- `docs/PROJECT-RESET.md`: this verification entry.
- No production source file changed.

## Not claimed

- No production bug was fixed; the demonstrated behavior worked, and the added regression pins the cross-project isolation and global-settings contract.
- The reset confirmation dialog (SLICE-07) was not touched and is out of scope for this slice.
- The active-work protection and cancellation paths (retained filesystem-recovery authority) are not re-exercised by the new test; they remain covered by the existing integration tests (`testGenerationResetRejectsRetainedFilesystemRecoveryAuthority`, `testGenerationResetCancelsWhenFilesystemRecoveryAppearsAfterBegin`, `testGenerationResetSurfacesCancellationFailure`).
- Ordinary app build, app-hosted tests, and native UI paths were not run in this slice (package unit tests only).

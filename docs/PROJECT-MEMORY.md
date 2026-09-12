# Project memory isolation — SLICE-05 verification

**Status:** behavior verified working — no source repair required. Project-isolated durable memory works: a record belongs to its selected project, is invisible to other projects (lookup, search, and no default-project fallback), and remains readable after the isolated repository is reopened. The one uncovered exclusion case (cross-project lookup + fallback) gained a focused regression.
**Evidence class:** E1 (executed focused tests on this checkout against disposable fixtures).
**Date:** 2026-09-12
**Base:** `main` @ `52e71da` (PR #42 merge) · branch `qwen-slice-05-project-memory`
**Host:** macOS 26.6.2 (25G83) · Apple Swift 6.3.3 (arm64-apple-macosx26.0)

## Deliverable

Prove a memory record belongs to its selected project and remains readable after the repository is reopened.

## What was confirmed

- **Identity.** Initializing two distinct fixture directories through the normal registration path (`ProjectMemoryService.initializeUnchecked`) yields two distinct project IDs, each bound to its own per-project isolated repository directory under the selected home.
- **Write/read (normal service path).** `remember` returns `disposition: "inserted"` with the record's project ID; a `get` for the same project returns `count: 1` with the record.
- **Cross-project exclusion.** The second project's `get` for the first project's record ID returns `count: 0`, and a `search` for the record's content from the second project returns `count: 0` — each project owns an isolated SQLite store, so a record has no path into another project's reads.
- **No default-project fallback.** Queries (get and search) for a project identity that is not registered in this home fail with `project_not_found` instead of falling back to any default project's store.
- **Reopen persistence.** After `closeAll()`, a new `ProjectMemoryService` on the same home resolves the same project ID and the record reads back intact.

## Checks and results

| Check | Command | Result |
|-------|---------|--------|
| Focused project-memory class (write/read, cross-project exclusion, reopen persistence) | `swift test --filter ProjectMemoryTests` | PASS — `Executed 23 tests, with 0 failures (0 unexpected)`, exit 0 |

The focused tests use a fresh isolated temporary home per test and never touch real user memory or unrelated project records.

## Change made in this slice

- `Tests/ForgeConductorTests/ProjectMemoryTests.swift`: added `testSelectedProjectRecordIsIsolatedFromOtherProjectsAndSurvivesReopen` (two-project identities, write/read, cross-project lookup + search exclusion, no-fallback rejection, close/reopen persistence).
- `docs/PROJECT-MEMORY.md`: this verification entry.
- No production source file changed. No user data or unrelated project records touched.

## Not claimed

- No production bug was fixed; the demonstrated behavior worked, and the added regression pins the exclusion and no-fallback contract.
- Ordinary app build, app-hosted tests, and native UI paths were not run in this slice (package unit tests only).
- No full memory import/export or migration matrix was run for the unchanged path.

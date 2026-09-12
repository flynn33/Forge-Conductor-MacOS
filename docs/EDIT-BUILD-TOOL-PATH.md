# Edit / build tool path — SLICE-04 verification

**Status:** behavior verified working — no source repair required. The existing read, edit, and command path works; the one uncovered result contract (`fs_edit`) gained a focused regression.
**Evidence class:** E1 (executed focused tests on this checkout against disposable fixtures).
**Date:** 2026-09-12
**Base:** `main` @ `76d37b9` (PR #41 merge) · branch `qwen-slice-04-edit-build-tool-path`
**Host:** macOS 26.6.2 (25G83) · Apple Swift 6.3.3 (arm64-apple-macosx26.0)

## Deliverable

Prove the existing tool path can read a useful source block, make an exact edit in a disposable fixture, and return a command result — through the focused tests in this repository.

## What was confirmed

- **Read (`fs_read`).** A windowed read (`offset`/`length`) returns exactly the requested block plus usable continuation metadata: `total_lines`, `start_line`, `end_line`, `has_more=true`, `next_offset`. A terminal read has `has_more=false` and a note that says to stop paginating; an offset past EOF returns empty content, `has_more=false`, and a stop note. An empty file and an unbounded maximum length both resolve to a clearly terminal result.
- **Edit (`fs_edit`).** An exact, uniquely matched `old` string is replaced and the resulting content is verified by re-reading the fixture. The existing contract is preserved: a non-unique `old` replaces every occurrence and reports `replacements`; a non-matching `old` fails with the distinct `no_match` code. This result contract had no focused test before this slice; the regression added in `CoreTests` (`testFSEditAppliesUniqueMatchAndReportsNoMatch`) pins it on disposable temporary fixtures.
- **Command (`shell_exec` path).** `ProcessRunnerTests` returns a normal successful run, a nonzero exit, a signal death, and a timed-out run through one harness; `exitCode`, `timedOut`, `terminationSignal`, and captured/truncated `stdout`/`stderr` fields are mutually distinguishable.
- **Catalog.** `ToolDefinitionCatalogTests` confirms the canonical schema and replay catalog covers the router exactly, with the `fs_*` and `shell_exec` definitions stable on the MCP wire (including the replay classes: `fs_read` read-only, `fs_write` idempotent, `shell_exec` non-replayable).
- **Loop guard.** The router already breaks identical repeated calls (`CoreTests.testIdenticalToolCallLoopSoftHandoffThenHardBlock`), and `fs_read` results carry their own do-not-repeat pagination note. No new loop-detection framework, shell quota, or provider tuning was added.

## Checks and results

| Check | Command | Result |
|-------|---------|--------|
| Read windowing baseline | `swift test --filter CoreTests/testFSWriteRead --filter CoreTests/testFSReadHonorsLineOffsetAndLength --filter CoreTests/testFSReadHandlesEmptyFileAndMaximumLength` | PASS — `Executed 3 tests, with 0 failures (0 unexpected)`, exit 0 |
| Command result + catalog baseline | `swift test --filter ProcessRunnerTests/testNormalAndNonzeroExitStatuses --filter ProcessRunnerTests/testTimeoutTerminatesChildAndReturnsConfirmedStatus --filter ProcessRunnerTests/testOutputIsCapturedConcurrentlyAndTruncatedPerStream --filter ToolDefinitionCatalogTests` | PASS — `Executed 9 tests, with 0 failures (0 unexpected)`, exit 0 |
| Edit regression + read rerun | `swift test --filter CoreTests/testFSWriteRead --filter CoreTests/testFSReadHonorsLineOffsetAndLength --filter CoreTests/testFSReadHandlesEmptyFileAndMaximumLength --filter CoreTests/testFSEditAppliesUniqueMatchAndReportsNoMatch` | PASS — `Executed 4 tests, with 0 failures (0 unexpected)`, exit 0 |

The edit regression uses a fresh isolated temporary home per test and never touches a production file of the running application.

## Change made in this slice

- `Tests/ForgeConductorTests/CoreTests.swift`: added `testFSEditAppliesUniqueMatchAndReportsNoMatch` (unique-match edit, content re-verification, multi-occurrence count, `no_match` failure).
- `docs/EDIT-BUILD-TOOL-PATH.md`: this verification entry.
- No production source file changed. No tool was weakened, disabled, or re-authorized; `shell_exec` remains under its existing explicit authorization rules.

## Not claimed

- No production bug was fixed; the demonstrated behavior worked, and the report's repeated-call loop is remedied by instruction behavior (pagination notes and the existing identical-call guard), which no instruction document can force on every model.
- Ordinary app build, app-hosted tests, and native UI paths were not run in this slice (package unit tests only).

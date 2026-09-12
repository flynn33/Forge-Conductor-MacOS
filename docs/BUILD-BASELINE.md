# Build baseline — SLICE-02 verification

**Status:** baseline verified working — no source change required.
**Evidence class:** E0 (observed runtime proof: repeatable build + executed tests on this checkout).
**Date:** 2026-09-12
**Base:** `main` @ `6313be8` (PR #39 merge) · branch `qwen-slice-02-build-baseline`
**Host:** macOS 26.6.2 (25G83) · Apple Swift 6.3.3 (arm64-apple-macosx26.0) · Xcode 26.6 (17F113)

## Checks and results

| Check | Command | Result |
|-------|---------|--------|
| CLI build | `swift build --product forge-conductor` | PASS — terminal result `Build of product 'forge-conductor' complete! (21.36s)`, exit 0 |
| Focused unit test | `swift test --filter 'OwnerOnlyAtomicFileTests'` | PASS — `Executed 6 tests, with 0 failures (0 unexpected)`, exit 0 |

Both commands were run directly (no repository wrapper, no historical gate runner) from the owner-selected checkout with a clean tracked tree.

## Findings

- The first concrete build blocker was absent: the CLI product compiled and linked on the first attempt, so no repair was made. Existing implementation is preserved unchanged.
- Selected test `ForgeConductorTests.OwnerOnlyAtomicFileTests` is a small, self-contained Core test (owner-only permissions, symlink rejection, atomic replacement, synchronization failure propagation). All of its cases executed and passed.

## Still untested (not claimed by this entry)

- Ordinary app build: `xcodebuild -scheme ForgeConductor -configuration Debug -destination 'platform=macOS' build` — not run in this slice.
- App-hosted tests and native GUI execution — a later, separate check per the card.
- Signing behavior — no signing settings were changed and none were exercised.

A successful CLI build and one focused unit-test run are proof of the package build baseline only; they are not proof that the macOS app launches. This is a documentation validation entry, not an application run.

# Release gates — no substitute for executable evidence

Use the existing `.forge-codex` gate identifiers and records. The labels below are a readable closure checklist, not a replacement state machine. Map each item to the current existing gate and evidence references. Repair a broken validator with regression tests; never bypass it by editing a result to true.

| Closure item | Evidence required | Cannot substitute |
|---|---|---|
| Source identity and preservation | Current baseline, feature inventory, source candidate SHA/build-input manifest; all changed files accounted for. | An old PR description, the audit SHA, or a clean status after destructive reset. |
| Native builds and regression | Compatible Xcode/SDK, Debug and Release SwiftPM suites, native Xcode app/CLI and relevant test targets, no unresolved compiler warnings, exact counts and skip reasons. | Linux package tests, compilation-only CI, zero selected tests, historical 1,001-test result. |
| Provider setup | Supported native clean-install save/test/use/restart path, validated persistence and Keychain/error tests. | Creating `lmstudio-provider.json` by hand in a fixture. |
| Production feature operability | Every required current P10 assertion backed by an implemented, executed product-path scenario. | Empty scenario registry, JSON Boolean statuses, synthetic adapter tests or negative denial for a required success path. |
| Filesystem security and completeness | Repaired containment/authority/recovery; signed 57-row E2 and current formal predicates; promised move/recursive-delete behavior; service lifecycle. | Quarantine described as elimination, repeated pathname checks, disabled features, a passing evidence-validator test. |
| Continuity | Real provider, actual manager ownership, threshold rollover, exact acknowledgment, fencing, automatic GUI-closed continuation and durable crash recovery. | Direct adapter calls, fake receipts, operator-created successor chat, an exactly-once-inference claim. |
| Native UI/shell/service | All documented navigation/actions, real folder picker, native shell off/on including post-Settings execution, actual app/manager restart and privileged approval/update/disable flows. | Process existence, a test-only picker hook, older partial Settings evidence. |
| Resources and hardware | Current Release resource/performance evidence, separate sanitizer runs, existing hardware/soak requirements satisfied or explicitly owner-rescoped with transparent consequences. | One high-memory host used as a proxy for all supported hardware or a silent threshold reduction. |
| Artifact and distribution | Correct version/identity/entitlements/architectures/contents; coherent nested signatures; Developer ID archive/export; accepted notary log, staple and Gatekeeper; clean downloaded install and upgrade. | Ad-hoc or Apple Development signing, unsigned binaries, removing quarantine or disabling Gatekeeper. |
| Documentation and synchronization | Current README/CHANGELOG/USER-GUIDE/XCODE/relevant docs, Xcode membership, live remote read-back, canonical checkout contains delivered source, clean agreed state. | Remote-only edits, stale tracking refs, unmerged changes absent from the canonical checkout. |
| Completion and authority | Existing final verifier passes with valid current evidence; all high/critical blockers resolved; owner approval for protected merge/public release; exact tag/asset read-back after publication. | Deadline expiration, PR merge alone, or guard-script success. |

## Classification

Use `passed`, `failed`, `blocked`, and `not_run` distinctly. Partial means the scenario did not finish every required assertion, not that it passed with a footnote. A declared environment skip in a broad regression suite does not waive a corresponding mandatory production scenario.

A lower-priority cosmetic issue may be documented only when existing release policy permits it and the product remains complete and safe. No authority to waive high/critical issues, feature preservation, or required native/security evidence is granted by this package.

## Final verifier

Inspect current script interfaces, then run the existing ready gates and final completion checker through the existing recorder. The root contract names:

```bash
./.forge-codex/scripts/run_gates.sh --ready
./.forge-codex/scripts/verify_completion.py
```

The current repository is expected to return nonzero until its real blockers are closed. A missing Python executable or a broken selector is an automation defect to resolve honestly, not a reason to stamp a gate passed. Do not replace the completion checker with the included integrity guards; those guards have intentionally narrower scope.

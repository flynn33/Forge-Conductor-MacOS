# Version and qualification status

Product identity: **0.9.0, build 1**, supporting **macOS 26+**. This is a
development snapshot with open release gates. This page summarizes retained
observations; the existing [shipping handoff](../.forge-codex/state/release-handoff.md)
and gate records remain the evidence authority. Documentation updates do not
promote a gate or qualify a later application build.

## Version agreement

The README, changelog, user guide, Xcode guide, current detailed documentation,
and [wiki](https://github.com/flynn33/Forge-Conductor-MacOS/wiki) use the same
product identity. The canonical values are
[`ForgeFilesystemProtocolConstants.productVersion` and `productBuildVersion`](../Sources/ForgeFilesystemProtocol/ForgeFilesystemProtocol.swift).
The CLI and runtime derive their product version from these constants.

Resolved Debug and Release settings for the app, Core framework, CLI, runtime
launcher and filesystem daemon are **0.9.0 (1)**. The app and CLI source plists
use the corresponding Xcode substitutions. Filesystem protocol version `5`,
provider plugin version `2.0.0`, and schema versions describe separate
compatibility contracts. Dated audits and previous changelog releases retain
their original version numbers.

## Tested source revisions

The implementation was delivered as `d5022440a248eac113c3a8e5a94a21e8e91da8ac`
and squash-merged by [PR #23](https://github.com/flynn33/Forge-Conductor-MacOS/pull/23)
into `20958b93c26023ae7632cbeae6e3eff2a93374cf`. Those two commits have identical
complete trees. The final controlled source candidate was `b1876cf`; the later
delivery commit contains evidence and state only.

The full local suites and focused native tests below bind `7d3fbb4`. A retained
input comparison verifies unchanged production source and build inputs at
`b1876cf`, which adds documentation, two diagnostic tests, and a baseline snapshot.
The six focused diagnostic/worker tests and final ordinary build bind `b1876cf`
directly. These are source-specific results, not a claim that all current CI
or release scenarios pass.

| Observation | Result and scope |
|---|---|
| Local SwiftPM Debug | 1,043 tests, five declared skips, zero failures; warnings as errors. [Record](../.forge-codex/evidence/EVID-20260905T012952Z-438ce12991.json) |
| Local SwiftPM Release | 1,043 tests, five declared skips, zero failures; warnings as errors. [Record](../.forge-codex/evidence/EVID-20260905T012426Z-683a8dcacb.json) |
| Native app-hosted tests | 17 tests, zero skips/failures. [Record](../.forge-codex/evidence/EVID-20260905T013112Z-d0687b0ed2.json) |
| Normal production onboarding | Four tests, zero skips/failures: folder authorization, offline provider save/rejection and manager replacement, native Settings shell disable/re-enable with fresh MCP, and live provider discovery/connection. [Record](../.forge-codex/evidence/EVID-20260905T012552Z-150ad6578a.json) |
| Final diagnostic and worker tests | Six tests, zero skips/failures, including privacy/bounds checks for the retained live failure diagnostic. [Record](../.forge-codex/evidence/EVID-20260905T020038Z-0fd00c88e8.json) |
| Ordinary signed development build | Release build passed with the documented Apple Development trust policy. It is not a Developer ID distributable. [Record](../.forge-codex/evidence/EVID-20260905T020038Z-e1d79496cc.json) |
| Installed CLI and shell scenario | Installation, CLI, shell defaults/migration/opt-out and app/manager restart substeps passed; overall result remains partial because its own Settings automation step did not execute. The separate native onboarding row supplies focused Settings evidence. [Record](../.forge-codex/evidence/EVID-20260905T020339Z-bbd5f84078.json) |
| Full manager rollover | Failed before the intended injected crash: bootstrap validation did not receive exactly one correctly named typed acknowledgment call with an object payload. The response was quarantined without an accepted receipt. [Record](../.forge-codex/evidence/EVID-20260905T020600Z-5ede7bf8cf.json) |
| Smaller real-provider fresh-root scenario | Fresh-root acknowledgment and automatic continuation passed; this does not qualify the full manager rollover/crash matrix. [Record](../.forge-codex/evidence/EVID-20260905T015037Z-7125c5a46e.json) |
| Completion verifier | Exit 1: 60 failed checks. Shipment remains blocked. [Record](../.forge-codex/evidence/EVID-20260905T021429Z-0c934cf27f.json) |

Historical 1,001-test SwiftPM and two-test app-hosted results remain valid for
their recorded earlier revisions. They are not the current suite size. Failed
runs, declared skips and zero-test selectors remain distinct from passing tests.

## GitHub CI observation

For delivery commit `d502244`, [run 33938816255](https://github.com/flynn33/Forge-Conductor-MacOS/actions/runs/33938816255)
passed native source integrity and Xcode Debug/Release compilation. Both SwiftPM
lanes compiled, then failed
`RuntimeExecutionJobTests.testAdvertisedPythonProfileExecutesTheRealInterpreterUnderContainment`.
The Xcode Python 3.9 interpreter could not load its framework library under the
sandbox. Each lane reported **1,045 tests, seven skips, and one failed test with
three assertion failures**. These failures are not waived by the local results
above. [Debug log](https://github.com/flynn33/Forge-Conductor-MacOS/actions/runs/33938816255/job/101232081482)
· [Release log](https://github.com/flynn33/Forge-Conductor-MacOS/actions/runs/33938816255/job/101232081493).

## Supported workflows and remaining work

Use [Provider](../USER-GUIDE.md#configure-the-managed-provider) to save the
endpoint/model and keep, replace or clear the Keychain credential. Save works
with an offline endpoint; model refresh and probes use the saved revision.
Provider setup is implemented and has focused native evidence. Full managed
Autonomy acceptance remains open.

Use [the explicit Xcode build and transactional installer](../XCODE.md#install-the-exact-xcode-build)
so the app, embedded CLI, framework, launcher and daemon come from one selected
build. Do not select an arbitrary DerivedData directory or mix companion files.

Filesystem containment and the signed mutation/recovery/service matrices,
full production-feature coverage, complete real-provider continuity and crash
recovery, whole-scene resource budgets, representative physical hardware, and
Developer ID/archive/notarization/Gatekeeper qualification remain required.
The owner manually ships after the required gates pass.

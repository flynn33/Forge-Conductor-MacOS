# E — Make the release path coherent and reproducible

## Correct the observed hazards

Use Xcode's canonical project/workspace for distribution. Keep the SwiftPM convenience bundle clearly a development/smoke path unless it gains equivalent supported packaging and qualification. `script/build_and_run.sh` currently accepts a build-number override that only changes Info.plist and unconditionally passes `--timestamp=none`. Prevent misleading production use: reject inconsistent build overrides; use a distinct production archive/export path with secure timestamps and verified Developer ID trust. Do not solve peer failures by weakening required team/identifier/certificate/CDHash checks.

Replace XCODE.md's wildcard `DerivedData/... | head -1` installation recipe. Build into one explicit directory, identify the exact new product, and use the supported transactional installer. Stage all required companion artifacts, especially the runtime launcher and matching Core framework/CLI. Verify old manager exit, new manager PID/path/identity, rollback on failure, and current app/CLI version. Never copy arbitrary stale Debug products into the live Forge home.

Use the existing `check_privileged_filesystem_bundle.sh` for the full signed Xcode artifact set. It supports `Debug`, `DevelopmentRelease`, and `Release`; do not mislabel a development build. Retain runtime execution tests because a static signature check cannot prove service lifecycle or installed identity. Qualification harness/adversary executables must not be shipped.

## Identity and archive

Inspect real available certificates at the start. The source currently distinguishes Apple Development team `9AQ2C2838M` and Developer ID team `2Y25RTLZET`. Treat these as checked-in requirements, not proof of access to either credential. If the actual authorized production identity is different, reconcile the product-wide trust policy and tests intentionally; never change just one build setting or substitute development signing for distribution.

Finalize product version/build before freezing the source candidate. Inspect resolved build settings, generated Info.plists, nested executable/framework identities, entitlements, runpaths, supported architectures, source resources and artifact contents. Keep `FORGE_DEVELOPMENT_SIGNING` out of production. No stripping quarantine or disabling Gatekeeper to claim successful distribution.

Archive, export, verify signatures, submit with `notarytool`, inspect the accepted status and service log, staple and validate the exported app (or supported container), then run Gatekeeper assessment and clean downloaded-artifact execution. A ZIP itself is not stapled; staple the contained app before creating the final delivery ZIP. Hash the final deliverable after all authorized packaging changes. Keep sign/notarize credentials in approved local Keychain/CI secrets, never in the package or commit.

## Native CI

The only checked-in audit-time workflow is the Ubuntu attribution workflow. Keep it. Do not restore the separately deleted attribution-check workflow. Add native CI appropriate to the repository without broad secret permissions: compatible pinned/verified macOS runner and Xcode selection, checkout of the actual commit, version and Xcode membership checks, Debug/Release Swift tests with warnings as errors, Xcode build coverage, and stored test results. Verify current runner/toolchain availability; do not assume `macos-latest` has the necessary SDK or physical hardware.

Unsigned build CI is acceptable for compilation-only lanes, but never counted as signed native, privileged, or distribution proof. Signing and protected-service tests need a controlled Mac/approval context; untrusted PR code must not receive signing secrets or privileged self-hosted execution. Configure timeouts and concurrency so separate jobs do not replace the same live manager. A red integrity/build test must fail the workflow. If a workflow is repaired, test the failure path too.

Include the package's `shipping_guard.py` tests and applicable guards in CI after reviewing/copying them. Its passing result is only its named check, not overall ship authority. Use existing gate verification as the final product readiness authority, with the native/security evidence gaps actually closed.

## Acceptance

A clean canonical checkout can build the documented app/CLI, open the same Xcode workspace, produce the exact recorded version, and reproduce required tests. All nested artifacts match the intended signing policy and the tested source. The exported distributable is notarized, stapled and Gatekeeper-approved, and its actual clean install/upgrade/service behavior passes. Required docs and live remote/canonical source synchronization are complete. Public publication remains a separate authorized operation.

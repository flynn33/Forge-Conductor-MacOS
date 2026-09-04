# Native validation runbook

Run on the development Mac, not in this package's Linux preparation environment. Commands below are starting points for the audited project. Inspect live source and each existing recorder/qualifier's help before selecting options. Capture commands with the repository's existing evidence recorder; the examples do not by themselves populate its gate records.

## Safety and output locations

Use the discovered absolute repository path and an absolute evidence directory outside it. Prefer a unique candidate directory; xcodebuild result bundles must not overwrite earlier evidence. Never use a wildcard DerivedData selection. Do not set a fresh Forge home and then assume a globally named LaunchAgent, privileged service, or LM Studio configuration is isolated: preserve/check those separately. Any actual install/restart must be scoped, reversible and authorized.

```bash
export REPO='/absolute/path/discovered/by/Codex/Forge-Conductor-MacOS'
export KIT='/absolute/path/to/Forge-Conductor-Codex-Shipping-Package'
export OUT='/absolute/path/to/new/candidate-evidence-directory'
mkdir -p "$OUT"
cd "$REPO"
export DEST="platform=macOS,arch=$(uname -m)"
bash "$KIT/scripts/preflight-macos.sh" "$REPO"
python3 "$KIT/scripts/shipping_guard.py" versions --repo "$REPO"
python3 "$KIT/scripts/shipping_guard.py" xcode --repo "$REPO"
xcodebuild -list -project ForgeConductor.xcodeproj
```

The example paths deliberately require discovery; do not use them literally. All tools must return meaningful evidence, and every source change after a candidate run must be accounted for. Use `set -o pipefail` if piping to tee so a failed build cannot be hidden by a successful logger.

## Broad regression and native build

```bash
swift test --configuration debug -Xswiftc -warnings-as-errors
swift test --configuration release -Xswiftc -warnings-as-errors

xcodebuild -project ForgeConductor.xcodeproj -scheme ForgeConductor \
  -configuration Debug -destination "$DEST" \
  -derivedDataPath "$OUT/DerivedData-Debug" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES build

xcodebuild -project ForgeConductor.xcodeproj -scheme forge-conductor \
  -configuration Debug -destination "$DEST" \
  -derivedDataPath "$OUT/DerivedData-CLI" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES build

xcodebuild -project ForgeConductor.xcodeproj -scheme ForgeConductor \
  -configuration Debug -destination "$DEST" \
  -derivedDataPath "$OUT/DerivedData-Debug" \
  -resultBundlePath "$OUT/Unit-Debug.xcresult" \
  -only-testing:ForgeConductorTests test

xcodebuild -project ForgeConductor.xcodeproj -scheme ForgeConductorAppTests \
  -configuration Debug -destination "$DEST" \
  -derivedDataPath "$OUT/DerivedData-AppHosted" \
  -resultBundlePath "$OUT/AppHosted-Debug.xcresult" \
  -only-testing:ForgeConductorAppTests test
```

Read executed counts and every skip. Address warnings in source/configuration rather than globally suppressing them. A build tool metadata warning needs a precise disposition; do not hide real compiler warnings. Add a separate test invocation for `ForgeFilesystemQualificationSupportTests` and any newly introduced target according to its actual shared scheme/SwiftPM mapping.

Run relevant Address Sanitizer and Thread Sanitizer test configurations separately, with isolated data paths and no sanitizer instrumentation in the shipped Release. Select only supported test targets and verify they actually ran. Use `profile_macos.sh --list` to select existing Release resource/profile flows; do not invent flags.

## Native UI and installed service scenarios

```bash
xcodebuild -project ForgeConductor.xcodeproj -scheme ForgeConductor \
  -configuration Debug -destination "$DEST" \
  -derivedDataPath "$OUT/DerivedData-UI" \
  -resultBundlePath "$OUT/UI-Debug.xcresult" \
  -only-testing:ForgeConductorUITests test
```

The user session/screen must be available and the native runner authorized. This does not grant permission to change macOS privacy databases. Extend the actual UI suite for missing production controls and postconditions. Use the supported production picker, not only a test hook. Run the full installed shell/manager qualifier and P10 production scenarios with the ordinary signed artifact; inspect `qualify_signed_shell_manager.py --help` and `qualify_p10_features.py --help` for their current arguments.

For a development-signed optimized supporting build, all three overrides belong together, as the repository documents:

```bash
xcodebuild -project ForgeConductor.xcodeproj -scheme ForgeConductor \
  -configuration Release -destination "$DEST" \
  -derivedDataPath "$OUT/DerivedData-DevelopmentRelease" \
  DEVELOPMENT_TEAM=9AQ2C2838M CODE_SIGN_IDENTITY='Apple Development' \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=FORGE_DEVELOPMENT_SIGNING build

./.forge-codex/scripts/check_privileged_filesystem_bundle.sh \
  "$OUT/DerivedData-DevelopmentRelease/Build/Products/Release/Forge Conductor.app" \
  DevelopmentRelease
```

This is NOT a distributable release. The machine must actually have that authorized identity. An unavailable identity remains blocked; don't forge it or change the trust policy opportunistically.

## Resolved versions and candidate archive

Before the final source freeze, inspect both resolved configurations and validate all version-bearing product targets. The `versions` guard accepts the JSON files below; retain them as build-setting evidence, not as proof of a successful build.

```bash
xcodebuild -project ForgeConductor.xcodeproj -scheme ForgeConductor \
  -configuration Debug -showBuildSettings -json > "$OUT/BuildSettings-Debug.json"
xcodebuild -project ForgeConductor.xcodeproj -scheme ForgeConductor \
  -configuration Release -showBuildSettings -json > "$OUT/BuildSettings-Release.json"
python3 "$KIT/scripts/shipping_guard.py" versions --repo "$REPO" \
  --settings "$OUT/BuildSettings-Debug.json" \
  --settings "$OUT/BuildSettings-Release.json"
```

Inspect runtime launcher/daemon/CLI settings through their actual target schemes too; the app scheme's dependency list must not be assumed complete without inspection. Finalize build/version and source candidate before archiving. Use current verified production credentials; do not carry development overrides into these commands.

```bash
xcodebuild -project ForgeConductor.xcodeproj -scheme ForgeConductor \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$OUT/DerivedData-Production" \
  -archivePath "$OUT/ForgeConductor.xcarchive" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES archive
```

Inspect supported architectures and declared platform scope. The audited Release project sets ONLY_ACTIVE_ARCH=YES; do not advertise a universal build without explicitly building and verifying the required slices and peer seals. Export with the actual Xcode version's supported Developer ID options. Generate and inspect an `ExportOptions.plist` appropriate to the installed `xcodebuild -help`; this package does not invent a signing profile or export identity.

```bash
xcodebuild -exportArchive -archivePath "$OUT/ForgeConductor.xcarchive" \
  -exportPath "$OUT/Export" -exportOptionsPlist "$OUT/ExportOptions.plist"
export APP="$OUT/Export/Forge Conductor.app"
./.forge-codex/scripts/check_privileged_filesystem_bundle.sh "$APP" Release
python3 "$KIT/scripts/shipping_guard.py" versions --repo "$REPO" --app "$APP"
codesign --verify --deep --strict --all-architectures --verbose=4 "$APP"
codesign -dvvv "$APP"
```

Inspect every nested shipped code object for valid intended Developer ID signatures, secure timestamps and entitlements, not just the outer app. Inspect the matching caller-sealed daemon hashes, compiled trust policy, runtime launcher, framework runpaths and CLI metadata with the existing checker. Do not use `codesign --deep` to indiscriminately repair/sign nested code; sign in the intended dependency order. Do not change metadata after signing.

## Notarization and distribution

Use a preconfigured approved Keychain notary profile. `NOTARY_PROFILE` below is a profile name, not a password/token. If unavailable, record the owner-controlled prerequisite; do not print secret material or invent success.

```bash
export NOTARY_PROFILE='approved-existing-profile-name'
ditto -c -k --keepParent "$APP" "$OUT/NotarySubmission.zip"
xcrun notarytool submit "$OUT/NotarySubmission.zip" \
  --keychain-profile "$NOTARY_PROFILE" --wait --output-format json \
  > "$OUT/notary-result.json"
```

Read the result and require Accepted; retain the submission ID and fetch its log using `notarytool log` with that exact ID. A command exit alone is not the acceptance decision. Use a bounded wait/timeout according to the installed tool's supported options and existing recorder. Only after accepted notarization:

```bash
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
ditto -c -k --keepParent "$APP" "$OUT/Forge-Conductor-final.zip"
shasum -a 256 "$OUT/Forge-Conductor-final.zip"
```

Hash the final packaged bytes, not the pre-staple submission ZIP. Verify a genuinely downloaded/quarantined copy through normal Gatekeeper execution on a clean test account/Mac. Do not remove quarantine to produce a pass. Exercise first-use, upgrade and real service registration/approval/update/disable with that exact exported artifact, preserving unrelated settings and restoring only scoped test changes. Re-run the existing completion gates and assemble the release report.

## Final synchronization

Run the guard tests and appropriate source guards, then the existing final verifier. Commit the reviewed docs/evidence, push the authorized branch, and read back the live ref. After an authorized merge, safely reconcile the canonical checkout, verify its Xcode project and version, and record the final SHA/build relationship. A dirty canonical checkout is not silently overwritten. The final report must retain any incomplete native, security, approval, distribution, or synchronization gate.

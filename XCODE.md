# Forge Conductor — Xcode

Product identity: marketing version **0.9.0**, build **1**. Xcode resolves those
values from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`; the Swift runtime
uses the matching constants in `ForgeFilesystemProtocolConstants`.

## Open

```bash
cd /path/to/Forge-Conductor-MacOS
open ForgeConductor.xcworkspace
```

The workspace intentionally contains the single canonical Xcode project. Using
it keeps the entry point stable if additional native modules are added later.

## Schemes (pick the right one)

| Scheme | What it is | How to run |
|--------|------------|------------|
| **ForgeConductor** | Native SwiftUI + Metal **app** | ⌘R — opens the GUI |
| **forge-conductor** | CLI tool | ⌘R with args (`help`, `doctor`, `serve`) |

## Fix that was required

`ForgeConductorCore.framework` is **embedded** in the app (`Contents/Frameworks/`).  
The CLI uses `@executable_path` so the framework must sit next to the binary when installed.
The Xcode app embeds the manager CLI at
`Contents/Helpers/forge-conductor`. The SwiftPM staging script also builds,
stages, signs, and strictly verifies that CLI alongside the runtime launcher and
filesystem daemon; it does not synthesize the Xcode framework layout.

## Build / Test

```bash
cd /path/to/Forge-Conductor-MacOS

xcodebuild -project ForgeConductor.xcodeproj \
  -scheme ForgeConductor \
  -destination 'platform=macOS,arch=arm64' \
  build

xcodebuild -project ForgeConductor.xcodeproj \
  -scheme ForgeConductor \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ForgeConductorTests \
  test

xcodebuild -project ForgeConductor.xcodeproj \
  -scheme ForgeConductorAppTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ForgeConductorAppTests \
  test
```

Both commands above are headless. `ForgeConductorAppTests` is a dedicated,
nonparallel app-hosted scheme with an isolated Forge home; it validates app/core
contracts without changing the main scheme. The `ForgeConductorUITests` target launches and
foregrounds the real app, so run it only when the Mac's screen is available:

```bash
xcodebuild -project ForgeConductor.xcodeproj \
  -scheme ForgeConductor \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ForgeConductorUITests \
  test
```

The app and `ForgeConductorCore` enable **Hardened Runtime**
(`ENABLE_HARDENED_RUNTIME = YES`). Debug app, CLI, runtime-launcher, filesystem-
daemon, and UI-test targets use the valid **Apple Development: James Daley**
identity on team `9AQ2C2838M`. Release configurations request **Developer ID
Application** on team `2Y25RTLZET`; this host currently has no valid Developer
ID identity. Entitlements live at
`Sources/ForgeConductorApp/Resources/ForgeConductor.entitlements`.

For a local optimized build signed with James Daley's Apple Development
certificate, select the signing identity and compiled peer-trust policy
together:

```bash
xcodebuild -project ForgeConductor.xcodeproj \
  -scheme ForgeConductor \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  DEVELOPMENT_TEAM=9AQ2C2838M \
  CODE_SIGN_IDENTITY='Apple Development' \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=FORGE_DEVELOPMENT_SIGNING \
  build

./.forge-codex/scripts/check_privileged_filesystem_bundle.sh \
  '/path/to/Build/Products/Release/Forge Conductor.app' \
  DevelopmentRelease
```

Omitting `FORGE_DEVELOPMENT_SIGNING` from an Apple Development-signed Release
build intentionally fails the exact installer or peer-identity checks. The
ordinary Release configuration remains pinned to Developer ID team
`2Y25RTLZET`; this local override is qualification support, not distribution
authority.

Do not set `CODE_SIGN_IDENTITY[sdk=macosx*] = -` on the app target: that forces
ad-hoc signing and Notary/App Store reject the archive as missing Hardened Runtime.

An earlier exact-revision focused signed Debug navigation qualification completed
100 Rig/MCP round trips. That is useful supporting native UI evidence, but the
final current-source rerun remains open and it is not a Developer ID Release,
archive, notarization, staple, Gatekeeper, protected-service lifecycle, or full
native UI matrix pass. Those release checks remain open.

Package P10/G10, filesystem E2, production move/recursive-directory deletion,
native managed-provider onboarding, production Settings shell qualification,
manager-owned real-provider forced rollover,
representative physical hardware, and final G09-G12 completion evidence also
remain open. The initial September 4 SwiftPM baseline executed 1,001 tests in
both configurations with five skips and no failures. Current expanded suite
counts, source identities and native result bundles are in the
[shipping handoff](.forge-codex/state/release-handoff.md).
A bounded Apple Development-signed Release installed-app run passes clean shell
defaults and migration, explicit opt-out and denial, `tools/list`, established
`shell_exec` through app and raw CLI, app relaunch, and installed-manager PID
replacement. Its raw CLI also passes `version`, `status`, and `doctor` with the
adjacent signed launcher. The run deliberately does not invoke System Events;
Settings control and post-Settings re-enable require the Xcode XCUI lane. These
results do not satisfy the still-open Developer ID Release, native UI, or P10
boundaries. A successful Xcode build or focused test does not mark those items
complete.

The SwiftPM convenience bundle is a development smoke path. It rejects a
`FORGE_BUILD_NUMBER` that differs from the compiled canonical build and rejects
Developer ID signing. A signed optimized smoke build requires the explicit
development mode:

```bash
FORGE_BUILD_CONFIGURATION=release \
FORGE_DEVELOPMENT_SIGNING=1 \
FORGE_CODE_SIGN_IDENTITY='Apple Development' \
./script/build_and_run.sh --build-only
```

That bundle is statically linked and remains suitable for app and CLI smoke
tests; it does not replace the Xcode framework layout required by the
privileged Login Item and filesystem-service qualification.

## Install the exact Xcode build

Choose one explicit output directory and validate its complete signed bundle.
The following is a local development installation; it does not qualify a
distribution artifact. Close the running GUI before replacing its installation.

```bash
cd /path/to/Forge-Conductor-MacOS
DERIVED_DATA="$PWD/.build/Xcode-Debug"
xcodebuild -workspace ForgeConductor.xcworkspace -scheme ForgeConductor \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" build
APP="$DERIVED_DATA/Build/Products/Debug/Forge Conductor.app"
./.forge-codex/scripts/check_privileged_filesystem_bundle.sh "$APP" Debug

# The embedded CLI stages its matching app, CLI, launcher and Core framework
# transactionally, then replaces the registered manager. Preserve other agents.
"$APP/Contents/Helpers/forge-conductor" manager install-login --keep-stale
"$HOME/.forge-conductor/bin/forge-conductor" version
"$HOME/.forge-conductor/bin/forge-conductor" manager status
open "$HOME/.forge-conductor/Forge Conductor.app"
```

Use the installer result and manager PID/path/version to confirm replacement.
An error or rollback remains a failed installation; copying individual binaries
from another output directory cannot repair a coherent signed installation.
For GUI development without installation, run the **ForgeConductor** scheme
from this workspace (⌘R).

## Continuous validation and distribution

The native workflow checks utility regressions, source versions and Xcode
membership on a verified macOS 26 / Xcode 26.6 runner. It runs Debug/Release
SwiftPM tests with warnings as errors and compiles the native app and CLI in
both configurations. Unsigned CI builds are compilation evidence; signed
app-hosted, UI, installed-service and distribution qualification run separately
on an authorized Mac.

Use the canonical Release archive/export path for distribution, with matching
Developer ID team policy and secure timestamps. The shipping
[validation runbook](.forge-codex/shipping/MACOS-VALIDATION-RUNBOOK.md) describes
artifact checks, notarization and installation proof. The owner performs
shipping manually after the hard gates pass.

### Provider and onboarding test membership

The Core target includes the provider configuration contract and native LM Studio
configuration service. Service/store tests run in `ForgeConductorTests`; native
HTTP-client and manager-route tests run in `ForgeConductorAppTests`.
`ProductionOnboardingUITests` is in the native UI target and uses the actual
folder panel and normal app bootstrap. Run it serially with UI Automation enabled:

```bash
xcodebuild -workspace ForgeConductor.xcworkspace -scheme ForgeConductor   -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO   -only-testing:ForgeConductorUITests/ProductionOnboardingUITests test
```

For xcodebuild, pass `TEST_RUNNER_FORGE_SHIPPING_PROVIDER_ENDPOINT` and
`TEST_RUNNER_FORGE_SHIPPING_PROVIDER_MODEL` in the process environment. Xcode
forwards them as `FORGE_SHIPPING_PROVIDER_ENDPOINT` and
`FORGE_SHIPPING_PROVIDER_MODEL` to the test runner; without them it
records an explicit skip. Keep the result bundle, selected/executed counts and
attachments. Build success and fixture UI tests do not qualify production
onboarding. The qualification-support SwiftPM tests remain in their dedicated
package target; Xcode builds the support library and native harness separately.

The unhosted Core unit-test bundle also uses Apple Development team `9AQ2C2838M`
to match its adjacent runtime launcher. Ad-hoc test signing is rejected by the
existing development-test trust check. Optimized native tests must build their
product dependencies with the documented development Release overrides.

The live manager-owned rollover test verifies the exact context reported by
LM Studio through `FORGE_LIVE_LMSTUDIO_EXPECTED_CONTEXT_LENGTH`. Some MLX runtime
versions override a requested load context. For a deliberately accelerated
qualification, `FORGE_LIVE_LMSTUDIO_ACCELERATED_THRESHOLD=yes` selects a validated
checkpoint/rollover policy of 0.78/0.75 while keeping the emergency fraction at
0.05. The test records this override, the full policy, real provider usage,
capacity and reserves. Ordinary application construction keeps the default
policy. This control never shortens the 660-second uncertainty fence.
The bootstrap observation allows the configured 600-second provider request
plus 30 seconds for state settlement, without changing the provider's deadline.

Use separate DerivedData directories for ordinary installable builds and native
test runs. Xcode can inject test-only entitlements into dependency executables
while preparing tests; the full bundle checker rejects those artifacts for
installation. Rebuild the ordinary product into a fresh explicit directory and
check its entire signed bundle before installing it.

`NativeGaugeLifecycleTests` belongs only to `ForgeConductorAppTests`. Run that
class serially to observe the production SwiftUI/Metal surfaces, hidden/static
draw counters, repeated dismantling, and actual buffer/object release. Its
attachments describe component evidence; full-application profiling, sanitizer
runs and representative physical hardware remain separate requirements.

### Native startup, gauges and process ownership

`AppBootstrapAppTests.swift` belongs to the app-hosted target and includes both
`AppBootstrapAppTests`, `OperatorStartupContentAppTests` and
`AppBackgroundOperationAppTests`. These test main-actor
responsiveness, bounded admission, cancellation, retry, owner release and actual
disposable diagnostics export. `NativeGaugeLifecycleTests` uses real AppKit
windows and Metal draws, including hide/show and release postconditions. Set
`TEST_RUNNER_FORGE_GAUGE_LIFECYCLE_CYCLES=100` for the repeated Release flow;
the test validates this bounded count. Optimized app-hosted test invocations
also require `ENABLE_TESTABILITY=YES` so their `@testable` imports can resolve
the app module. Keep this override on the test invocation and retain Release
optimization; ordinary installable builds use their default visibility. Run
GUI and app-hosted tests serially.

Address Sanitizer and Thread Sanitizer use separate DerivedData and result
bundles. Process-runner regressions exercise large output on both streams,
continuous output with timeout, termination-handler output, cancellation and
process-group reaping. A sanitizer pass is not a clean performance profile;
retained Thread Performance Checker diagnostics still need their own assessment.

The UI test runner explicitly sets `com.apple.security.app-sandbox` to false,
matching the ordinary product. Removing the key alone does not work: Xcode
merges a true default from its XCTRunner RunnerEntitlements.plist. The explicit
false preserves all other injected automation permissions. This is a test-target entitlement choice: it lets native Settings tests
launch the signed MCP executable, whose shell policy creates its own sandbox.
A sandboxed runner prevented that nested sandbox with `sandbox_apply` exit 71,
so it could not measure the ordinary product path. Production entitlements and
shell authorization remain unchanged; disabled-policy denial and post-Settings
reenablement both retain their full executable assertions.

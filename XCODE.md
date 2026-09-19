# Forge Conductor — Xcode

Product identity: marketing version **0.10.0**, build **2**. `VERSION` and
`BUILD_NUMBER` are the repository authorities. Xcode resolves matching values
from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`; the Swift runtime uses
the matching constants in `ForgeFilesystemProtocolConstants`.

The current [functional development build](docs/FUNCTIONAL-DEVELOPMENT-BUILD.md)
uses optimized Release configuration with the documented Apple Development
identity and matching `FORGE_DEVELOPMENT_SIGNING` peer policy. The ordinary
Release configuration requests Developer ID Application for James Daley's team
`9AQ2C2838M`. Notarization, stapling, and public distribution require their
own completed checks and owner release decision.

## Open

```bash
cd /path/to/Forge-Conductor-MacOS
open ForgeConductor.xcworkspace
```

The workspace intentionally contains the single canonical Xcode project. Using
it keeps the entry point stable if additional native modules are added later.
Archive the **ForgeConductor** scheme from this workspace. The similarly named
**Forge Conductor** scheme and the bundle identifier
`Raven-Forge-Software.Forge-Conductor` belong to a different product. An archive
with that scheme and identifier contains neither this project's `AppIcon.icns`
nor its bundled manager, launcher and filesystem helper.

## Schemes (pick the right one)

| Scheme | What it is | How to run |
| --- | --- | --- |
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

xcodebuild -workspace ForgeConductor.xcworkspace \
  -scheme ForgeConductor \
  -destination 'platform=macOS,arch=arm64' \
  build

xcodebuild -workspace ForgeConductor.xcworkspace \
  -scheme ForgeConductor \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ForgeConductorTests \
  test

xcodebuild -workspace ForgeConductor.xcworkspace \
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
xcodebuild -workspace ForgeConductor.xcworkspace \
  -scheme ForgeConductor \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ForgeConductorUITests \
  test
```

The app and `ForgeConductorCore` enable **Hardened Runtime**
(`ENABLE_HARDENED_RUNTIME = YES`). Debug app, CLI, runtime-launcher, filesystem-
daemon, and UI-test targets use the valid **Apple Development: James Daley**
identity on team `9AQ2C2838M`. Release configurations request **Developer ID
Application** on that same team. Xcode's account has already cloud-signed an
earlier, different product as `Developer ID Application: James Daley
(9AQ2C2838M)`. The archive host subsequently had usable local Developer ID
Application and Installer identities for the same team in its login keychain.
The owner has now installed those identities on this macOS 27/Xcode 27 build
host. The former ordinary current-source Release build stopped with Xcode exit
65 while all five shipping targets lacked a matching Developer ID Application
private key. A new ordinary archive from the current local patch over `main`
and its manual `developer-id` export both succeeded; the earlier archive still
qualifies only its original source.
The explicit arm64 Apple Development Release override built the current source
successfully on this host. The `DevelopmentRelease` nested-bundle checker,
embedded CLI `version` and `status`, and a bounded isolated GUI/manager launch
on scratch port 7789 passed without replacing the working installation.
After that launch, macOS Background Items indexed the temporary app under the
same bundle identifier as the installed product. The local development
candidate was preserved in an integrity-checked ZIP (SHA-256
`65eb184ae46333288fe526d96db876783d88873bfaccb4822d61845b5c2756df`),
and the original `.app` directory was renamed to a retained non-app bundle.
Background Items still caches the former URL; this is not a root-service pass.
The earlier `2Y25RTLZET` Developer ID team remains in the product trust policy
for previously signed products. Entitlements live at
`Sources/ForgeConductorApp/Resources/ForgeConductor.entitlements`.

The September 14, 2026 prerequisite recheck observed macOS 26.6.2 on an arm64
Mac16,7 with 48 GiB physical memory, Xcode 26.6 build 17F113, and Apple Swift
6.3.3. At that baseline, Release settings resolved version 0.9.0, build 1,
Developer ID Application, and team `2Y25RTLZET`. The keychain exposed a usable
Apple Development identity but no local Developer ID Application identity, and
no approved notarization profile was identified. This is historical host inventory
only; it is not a signed build or hardware-matrix result.

For a local optimized build signed with James Daley's Apple Development
certificate, select the signing identity and compiled peer-trust policy
together:

```bash
xcodebuild -workspace ForgeConductor.xcworkspace \
  -scheme ForgeConductor \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  DEVELOPMENT_TEAM=9AQ2C2838M \
  CODE_SIGN_IDENTITY='Apple Development' \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) FORGE_DEVELOPMENT_SIGNING' \
  build

./.forge-codex/scripts/check_privileged_filesystem_bundle.sh \
  '/path/to/Build/Products/Release/Forge Conductor.app' \
  DevelopmentRelease
```

The ordinary workspace Release settings now resolve Developer ID Application
and team `9AQ2C2838M` for all five shipping targets. This explicit development
invocation resolves Apple Development and team `9AQ2C2838M` for the app and its
dependencies. A previously present SDK-specific identity override made the
ordinary Release setting resolve to Apple Development despite the displayed
Developer ID value; that mismatch has been removed.

For a distribution candidate, choose **Product → Archive** with the
**ForgeConductor** scheme and inspect the resulting archive before choosing
**Distribute App**. The archive's `Info.plist` must identify scheme
`ForgeConductor` and application `com.forge-conductor.app`. Its app bundle must
contain `Contents/Resources/AppIcon.icns` and `Contents/Resources/Assets.car`,
and its generated `CFBundleIconFile` and `CFBundleIconName` must both be
`AppIcon`. The embedded CLI has `SKIP_INSTALL = YES` for Release, so it stays in
`Contents/Helpers` without becoming a separate top-level archive product. The
archive `Info.plist` must include `ApplicationProperties`; a generic archive
cannot use the Developer ID export method. Verify the app and embedded products
with the existing `check_privileged_filesystem_bundle.sh` checker in `Release`
mode. The five shipping Release targets use manual signing because Xcode rejects
automatic development signing paired with an explicit Developer ID identity.
Before those local identities were installed, the ordinary archive reported no
Developer ID Application certificate for James Daley's team with a private key.
The cloud-managed certificate used for another product did not supply that
build-time private key. The explicit development-signed archive is local qualification evidence;
its compiled peer policy requires Apple Development and cannot be treated as a
Developer ID product merely by re-signing it at export. Notarization, stapling,
and Gatekeeper acceptance are distinct checks after an exact Developer ID
archive and export.

On September 15, the ordinary Release configuration produced a universal
`0.9.0 (1)` Developer ID app archive with one installable app product. A
`developer-id` export succeeded with manual signing for team `9AQ2C2838M`.
The archive and exported app passed strict deep all-architectures signature
verification and the Release privileged-bundle checker, including the embedded
CLI, runtime launcher, Core framework, filesystem daemon, and caller-sealed
daemon hashes. All five exported code objects carry James Daley's Developer ID
Application identity and secure timestamps. A local installer package made
from that exported app is signed with his Developer ID Installer identity and a
trusted timestamp. The local review receipt under
`/Users/jimdaley/Projects/Forge-Conductor/Release-Prep-2026-09-15/DeveloperID-0.9.0-1`
records the exact artifact hashes. Notarization and public acceptance remain
separate release steps.

On this build host, the current local patch over `main` produced
`/private/tmp/forge-current-source-developerid-20260915.xcarchive` with the
canonical scheme, one universal `com.forge-conductor.app` application product,
version `0.9.0 (1)`, icon metadata/resources, and Developer ID Application team
`9AQ2C2838M`. The archive passed strict deep signature verification and the
`Release` privileged-bundle checker. Manual `developer-id` export to
`/private/tmp/forge-current-source-developerid-export-20260915` succeeded; the
exported app and the expanded package payload independently passed the same
checker, including nested code and daemon hash seals. The exported CLI returned
`0.9.0` for `version` and a stopped manager from an isolated scratch home.
The local app ZIP passed integrity testing (SHA-256
`5a23be1a0937b9af643ee20b159b8a4fc6be8e47afaaeda75eb86167a8aab85d`).
The local installer package is signed with Developer ID Installer and a trusted
timestamp (SHA-256
`5b7296ef3bdeaaf8565e8784287861d82eb40767363dc0c2365f635b2c3855f0`).
`spctl --assess` rejected both app execution and package installation with
`source=Unnotarized Developer ID` before notarization; no `notarytool` keychain
profile was identified on this host. Xcode Organizer's **Direct Distribution**
flow authenticated with its existing Apple account and reported notarization
success for this exact archive. Organizer records submission identifier
`52F2FB87-5E36-45E8-AA11-9CE7A3019168` as **Ready to distribute** and its
status log names the app, CLI, launcher, daemon, and Core framework as notarized.
The local exported app at
`/private/tmp/forge-current-source-notarized-export-20260915/Forge Conductor.app`
passed strict all-architecture nested signatures, the `Release` checker,
`stapler validate`, and Gatekeeper execution assessment (`accepted`,
`source=Notarized Developer ID`). Its ZIP at
`/private/tmp/forge-current-source-notarized-app-20260915.zip` passed integrity
testing (SHA-256
`a309b3a138d5ee986a0791bb425ffd736b6ea295e6d80f4fda541289e0489d2b`).
After extraction, the app again passed stapler, Gatekeeper, and the bundle
checker. The separately signed installer package remains unnotarized and is
rejected for installation. Neither artifact was installed or shipped. This
archive remains tied to the current uncommitted local patch until an identical-
source direct `main` publication is verified.

The later policy-import source produced another universal Developer ID archive
at `/private/tmp/forge-policy-import-developerid-20260915.xcarchive` with one
canonical app product. Archive, manual export, strict nested signing, and
Release privileged-bundle checks passed. Xcode Organizer Direct Distribution
notarized it as `F591014A-45A3-4BB2-AA3F-25A26CEB0932`. The stapled app ZIP
at `/private/tmp/forge-policy-import-notarized-app-20260915.zip` passed full
integrity (SHA-256
`9d99e311b8471b2de46d1043cb2dbe03c1486f105fd9a1c4a9df720cdec3c4ed`);
its extracted app passed stapler, strict bundle/signature checks, and local
Gatekeeper execution assessment. A bounded direct packaged run on isolated
port 7792 registered a project, reached live LM Studio, and completed after
the exact signed native XCTest case passed; terminal `tests` state survived a
full process restart. The archive predates only the native UI-test target's
Core-framework link and later test/docs edits; rebuild from exact published
`main` before calling an artifact source-bound. The installer and public
download remain separate distribution checks.

A final universal Developer ID Release archive from the current local workspace
and updated Xcode test-target graph passed at
`/private/tmp/forge-final-local-developerid-20260916.xcarchive`. The exported
app's five app/Core/CLI/launcher/daemon code-directory hashes match the
notarized archive above, and the existing ticket stapled to this exact-code
export. The final local app ZIP at
`/private/tmp/forge-final-local-notarized-app-20260916.zip` passed integrity
(SHA-256 `f77f63c19807be2522d245c9a6e827d0713c99a04cf76d6f14baaaaebe470b19`),
extracted stapler validation, strict all-architecture signing and Release
bundle checks, and local Gatekeeper execution as `Notarized Developer ID`.
The initial `productsign` path waited during private-key authorization, but the
Installer key's existing ACL already admitted Apple's `productbuild` tool.
`productbuild --package --sign` produced the matching trusted-timestamp package
at `/private/tmp/forge-final-local-productbuild-signed-installer-20260916.pkg`
(SHA-256 `1cfc438cf5e2b5d9dda8fafcb019c905abad1b0289f48c5f9f233796c3f03f79`).
`pkgutil --check-signature` validates its Developer ID Installer chain and
timestamp. The expanded app retains its ticket and passes strict nested signing,
the Release bundle checker, stapler validation, and app Gatekeeper execution.
The outer package is not notarized and fails Gatekeeper's install assessment as
`source=Unnotarized Developer ID`; the host has no `notarytool` keychain profile
or App Store Connect API key in its standard locations, and the repository has
no Actions secrets available for a private CI submission. This archive remains
tied to its recorded pre-publication workspace and remains historical evidence.

The exact owner-authored published tree at
`f02abeb8c940c8d998f822fd4f1cad5c20c7765e`, tree
`c6475126b54c8ff8de1465940e3ecc3c702a00eb`, then produced a fresh universal
Developer ID archive at
`/private/tmp/forge-published-main-developerid-20260917.xcarchive` and manual
export. The archive, export, ZIP extraction, and expanded Installer payload pass
strict nested signing and the Release privileged-bundle checker. The app ZIP at
`/private/tmp/forge-published-main-developerid-app-20260917.zip` is 22,112,426
bytes with SHA-256
`a171d88409c2ef36816b5ccbc4bb304a3855b5fc7f3972492259adcd143ec338`.
The matching trusted-timestamp Installer at
`/private/tmp/forge-published-main-signed-installer-20260917.pkg` is 22,099,582
bytes with SHA-256
`21a0dc3d68dfbd410408c38cb8e3ce1ee9a395269a30bbeba89d94ab13a16d28`.
Gatekeeper rejects both as `source=Unnotarized Developer ID`; they have not
been installed or shipped.

When an existing Notary profile is supplied, submit and qualify this exact
package without rebuilding or creating another credential:

```bash
PKG=/private/tmp/forge-published-main-signed-installer-20260917.pkg
PROFILE='<existing notarytool profile>'
xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait \
  --output-format json
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
spctl --assess --type install --verbose=4 "$PKG"
shasum -a 256 "$PKG"
```

Retain the terminal submission identifier and result before stapling. A timeout,
an `Invalid` response, a missing terminal response, a failed staple, or a failed
Gatekeeper install assessment remains a nonpass.
The final local direct `swift test` suite subsequently executed 1,554 XCTest
cases with 12 explicit skips and zero failures; the terminal transcript is
`/private/tmp/forge-final-local-swift-test-20260916.log`. The production
source and code-directory hashes did not change after the archive.

A bounded direct launch from that extracted notarized ZIP used a fresh
`FORGE_CONDUCTOR_HOME` and loopback port 7790. The GUI and dashboard reported
`0.9.0`, Manager Start returned **Service started**, the native folder picker
saved a disposable authorized root, and Projects registration committed its
manager-owned identity/generation. The computer-use connection dropped during
the registration click, but the app process and listener remained healthy and
the manager snapshot confirmed the committed project. The candidate was then
terminated, port 7790 closed, and only its launched `.app` path was renamed to a
retained non-app bundle. The installed application's signature remained valid;
the owner installation was not replaced. The installed root service still has
a category-3 launch constraint and is not qualified by this smoke.

Omitting `FORGE_DEVELOPMENT_SIGNING` from an Apple Development-signed Release
build intentionally fails the exact installer or peer-identity checks. The
ordinary Release configuration remains pinned to Developer ID team
`9AQ2C2838M`; this local override is qualification support, not distribution
authority.

Do not set `CODE_SIGN_IDENTITY[sdk=macosx*] = -` on the app target: that forces
ad-hoc signing and Notary/App Store reject the archive as missing Hardened Runtime.

An earlier exact-revision focused signed Debug navigation qualification completed
100 Rig/MCP round trips. The functional-development candidate also completed a
bounded direct launch from its isolated Release product. A current app-hosted
gauge attempt could not activate a display link because the test environment
reported zero valid displays; that result is unexecuted, not a product pass or
failure. At that historical development-delivery checkpoint, Developer ID
Release, archive, notarization, staple, Gatekeeper, privileged root-service E2,
and the broader native UI/hardware matrix were not recorded as passes. The
current patch-bound Developer ID app archive, notarization, staple, and local
Gatekeeper checks are recorded above; the other gates remain open.

The functional-development candidate now includes production move/recursive-
directory deletion, one manager-owned real-provider forced rollover, the complete
1,578-test Swift regression, and a coherent development-signed workspace Release.
Filesystem root-service E2, exact existing-desktop attachment, representative
physical hardware and public-distribution qualification remain outside the proven
scope. All four native production
onboarding scenarios passed, including folder authorization, provider save and
discovery, manager replacement and Settings shell disable/re-enable with fresh
MCP processes. The initial September 4 SwiftPM baseline executed 1,001 tests in
both configurations with five skips and no failures. Current expanded suite
counts, source identities and native result bundles are in the
[shipping handoff](.forge-codex/state/release-handoff.md).
A bounded Apple Development-signed Release installed-app run passes clean shell
defaults and migration, explicit opt-out and denial, `tools/list`, established
`shell_exec` through app and raw CLI, app relaunch, and installed-manager PID
replacement. Its raw CLI also passes `version`, `status`, and `doctor` with the
adjacent signed launcher. That installed-app run deliberately omits System
Events and remains partial; the separate Xcode onboarding run covers native
Settings control and post-Settings re-enable. These results support the functional
development build; they do not claim Developer ID, notarization, universal
installation, privileged root-service E2, or public shipment.

The SwiftPM convenience bundle includes the Core resource bundle under
`Contents/Resources`, shared by the app and embedded CLI. Agent and telemetry
folders retain their layout, so the staged product does not require resources
from a checkout or DerivedData. Test this with a fresh home and denied access
to the source/build directories; seeded home resources can conceal omissions.

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

## Archive identity-sealing inputs

During Archive, Xcode exposes the filesystem daemon in `BUILT_PRODUCTS_DIR`
through a symlink. The app and CLI identity-sealing phases use
`FORGE_FILESYSTEM_DAEMON_PRODUCT` to declare and read the actual daemon under
`UNINSTALLED_PRODUCTS_DIR` for deployment builds. Ordinary builds use the
regular file in `BUILT_PRODUCTS_DIR`. Both phases retain script sandboxing,
strict signature verification, and rejection of symlink inputs.

If an older checkout reports `filesystem daemon is missing or linked` from
**Seal Filesystem Daemon Identity**, update its Xcode project. Removing the
script's checks or disabling its sandbox is unnecessary.

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

The graph guard checks tracked production resources against actual resource
and copy phases, including asset-catalog descendants. A visible file reference
or membership in a different target does not satisfy the check. Info templates
and entitlements are reported separately for native metadata validation;
resource contents and final copy destinations still require bundle inspection.
Release app-hosted tests require `ENABLE_TESTABILITY=YES` for that test
invocation. Keep their instrumented products separate from clean candidate
builds and archives, as detailed in the native validation runbook.

The initial September 5 shipping snapshot failed the Python interpreter
containment test in CI. That repair and the later external-lock startup repair
passed the follow-up CI runs. Local P01 completion-authority changes require
fresh regression and native evidence at their own source binding. See the
[qualification summary](docs/QUALIFICATION-STATUS.md) for the revision boundaries
and [native completion policy](docs/NATIVE-COMPLETION.md) for trusted job setup.
Native gate validation uses prebuilt, signed test products and semantic result
records; unsigned app compilation does not provide that qualification.

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
folder panel and normal app bootstrap. The UI target now links the existing
Core framework only to calculate the approved package manifest in its positive
policy-picker fixture; source and resource memberships stay unchanged. Its
Developer ID Release combined case opened/canceled the picker, selected an
exact run-bound manifest fixture, and read back the owner-only policy at mode
`0600`. The separate Core signed-package fixture verifies actual gate
adjudication. Run UI cases serially with UI Automation enabled:

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
On the current Xcode 27 host, a direct `FORGE_SHIPPING_PROVIDER_*` shell prefix
selected one live Provider case but skipped it because those variables were
absent in the runner. The passing current-source live Provider and combined
Autonomy cases used `build-for-testing`, an inspected copied `.xctestrun` plan
with the two variables in `ForgeConductorUITests.EnvironmentVariables`, and
`test-without-building` with one exact selector each. The result bundles report
one passed, zero skipped, zero failed. The Manager authorized-folder crash was
reproduced in its exact native UI case before the redundant accessibility-label
repair; the same case and combined Autonomy start case passed afterward.
One broader seven-case onboarding run had six passes and one live Provider
`unreachable` result before its combined Autonomy case reached run start. After
failure-time probe diagnostics were added, the full class executed seven cases
with no skip or failure, and two further exact combined-case repeats passed.
Retain both `.xcresult` bundles; the first result is not a pass and does not
establish a deterministic product defect without the provider error detail.

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

## SwiftPM runtime and result paths

The SwiftPM CI lanes use the test worker runner with one worker so XCTest
produces the requested xUnit file while cases remain sequential. Both XCTest
and Swift Testing stay enabled, and warnings remain errors. Runtime Python
admission and the process sandbox resolve the existing system runtime roots
to physical paths, including versioned Xcode app aliases. This does not grant
read access to sibling applications or user data.

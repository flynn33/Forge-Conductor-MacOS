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
clean-install managed-provider setup, production Settings shell qualification,
manager-owned real-provider forced rollover,
representative physical hardware, and final G09-G12 completion evidence also
remain open. The current-source SwiftPM Release suite executes
1,001 tests with 5 declared environment skips and 0 failures under
warnings-as-errors. The dedicated Apple Development-signed app-hosted Xcode
contract suite executes 2 tests with 0 failures from fresh DerivedData.
A bounded Apple Development-signed Release installed-app run passes clean shell
defaults and migration, explicit opt-out and denial, `tools/list`, established
`shell_exec` through app and raw CLI, app relaunch, and installed-manager PID
replacement. Its raw CLI also passes `version`, `status`, and `doctor` with the
adjacent signed launcher. The run deliberately does not invoke System Events;
Settings control and post-Settings re-enable require the Xcode XCUI lane. These
results do not satisfy the still-open Developer ID Release, native UI, or P10
boundaries. A successful Xcode build or focused test does not mark those items
complete.

The SwiftPM convenience bundle supports the same explicit local signing mode:

```bash
FORGE_BUILD_CONFIGURATION=release \
FORGE_DEVELOPMENT_SIGNING=1 \
FORGE_CODE_SIGN_IDENTITY='Apple Development' \
./script/build_and_run.sh --build-only
```

That bundle is statically linked and remains suitable for app and CLI smoke
tests; it does not replace the Xcode framework layout required by the
privileged Login Item and filesystem-service qualification.

## After building from Xcode

Products land in DerivedData. To install for daily use:

```bash
PROD=$(ls -d ~/Library/Developer/Xcode/DerivedData/ForgeConductor-*/Build/Products/Debug | head -1)
cp -f "$PROD/forge-conductor" ~/.forge-conductor/bin/
cp -R "$PROD/ForgeConductorCore.framework" ~/.forge-conductor/bin/
cp -R "$PROD/Forge Conductor.app" ~/.forge-conductor/
open ~/.forge-conductor/Forge\ Conductor.app
```

Or just **Run** the **ForgeConductor** scheme from Xcode (⌘R).

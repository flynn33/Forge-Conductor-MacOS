# Forge Conductor — Xcode

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
```

The command above is headless. The `ForgeConductorUITests` target launches and
foregrounds the real app, so run it only when the Mac's screen is available:

```bash
xcodebuild -project ForgeConductor.xcodeproj \
  -scheme ForgeConductor \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ForgeConductorUITests \
  test
```

The app and `ForgeConductorCore` enable **Hardened Runtime** (`ENABLE_HARDENED_RUNTIME = YES`)
and sign with **Apple Development** / team `2Y25RTLZET`. That is required for Archive
and distribution. Entitlements live at
`Sources/ForgeConductorApp/Resources/ForgeConductor.entitlements`.

Do not set `CODE_SIGN_IDENTITY[sdk=macosx*] = -` on the app target: that forces
ad-hoc signing and Notary/App Store reject the archive as missing Hardened Runtime.

One unit test (`testProductionSignatureValidatorPreservesValidTeamSignedAppWhenAvailable`)
skips when no team-signed app is present. That is expected on this machine.

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

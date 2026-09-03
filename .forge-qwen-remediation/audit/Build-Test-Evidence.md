# Build and Test Evidence

## Independent audit environment

- Host: Linux x86_64.
- Swift: 6.2.1 for Linux.
- `xcodebuild`: unavailable.
- The package targets macOS 26 and imports Darwin.

| Command | Exit | Timed out | Seconds |
|---|---:|---|---:|
| `uname -a` | 0 | False | 0.001 |
| `swift --version` | 0 | False | 0.157 |
| `swift package describe --type json` | 0 | False | 0.509 |
| `swift test --disable-sandbox` | 1 | False | 0.702 |

`swift package describe --type json` succeeds. `swift test --disable-sandbox` fails at compilation because `ForgeRuntimeLauncher/main.swift` imports Darwin. This is an audit-host limitation, not evidence of a macOS product regression. Full output is under `evidence/`.

## Embedded current-manifest evidence

| Evidence ID | Command | Exit | Source changed |
|---|---|---:|---|
| `EVID-20260828T124332Z-1e2a050c0e` | `swift test -Xswiftc -warnings-as-errors --no-parallel` | 0 | False |
| `EVID-20260828T124624Z-00a3dd27c2` | `swift test -c release -Xswiftc -warnings-as-errors --no-parallel` | 0 | False |
| `EVID-20260828T124634Z-c6c0c861da` | `xcodebuild -project ForgeConductor.xcodeproj -scheme ForgeConductor -configuration Debug -destination platform=macOS -derivedDataPath /tmp/forge-ui-shell-evidence-final -only-testing:ForgeConductorUITests/ForgeConductorUITests/testManagerSettingsControlsAndPersistsProjectShellPolicy CODE_SIGNING_ALLOWED=NO build-for-testing` | 0 | False |
| `EVID-20260828T131739Z-66596e8e37` | `./script/build_and_run.sh --verify` | 0 | False |

The embedded strict Debug and Release SwiftPM runs report **657 tests, 4 skips, 0 failures**. The four documented skips are environment-dependent: no LM Studio Projects folder, no valid team-signed app fixture, live LM Studio disabled without a model variable, and PowerShell unavailable.

The XCUITest evidence is **build-for-testing only** and executes zero UI tests. The later ad-hoc app smoke proves launch/process existence only. Neither is signed native UI authority.

## Xcode membership parity

Missing source files: none

Missing test files:

- `Tests/ForgeConductorTests/LMStudioContractFixtureTests.swift`
- `Tests/ForgeConductorTests/LMStudioContractFixtureServer.swift`

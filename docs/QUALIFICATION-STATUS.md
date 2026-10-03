# Version and qualification status

## October 3 installed bootstrap and export repair — 0.16.5 (26)

The corrected Xcode project identifies the candidate as `0.16.5 (26)`. The
installed `/Applications/Forge Conductor.app` remains `0.16.4 (25)`. Its GUI
and embedded CLI failed bootstrap with runtime launch-gate status `-67050`
while strict deep signature verification passed. The installed-framework
probe required Apple Development certificate extension
`1.2.840.113635.100.6.1.12` for all four product roles, although the exported
installation was Developer ID signed. The original Apple Development archive
and installed/exported daemon also had different CDHashes; the installed app
and CLI retained the archive hashes (`installed-signing-policy-probe.log` and
`archive-export-daemon-seal-evidence.json`). The stale seals are a separate
identity defect; the observed bootstrap failure occurred at the earlier
product-signing check.

The mechanisms and corrections are:

- `ForgeConductor.xcodeproj/project.pbxproj` restores manual Developer ID
  signing for the five shipping Release targets and removes the global Release
  `FORGE_DEVELOPMENT_SIGNING` flag. Debug retains automatic Apple Development
  signing. `ForgeFilesystemProtocolConstants.requiredProductCodeSigningRequirement`
  in `Sources/ForgeFilesystemProtocol/ForgeFilesystemProtocol.swift` selects
  the build's exact certificate class; `RuntimeLaunchGate.codeIdentity`
  in `Sources/ForgeConductorCore/Infrastructure/RuntimeProcessSupervisor.swift`
  enforces it. `script/seal_filesystem_daemon_identity.sh` seals the signed
  daemon hashes, checked by
  `SecurityManagerPrivilegedApplicationIdentityValidator.validateSealedDaemonHashes`
  in `Sources/ForgeConductorCore/Manager/ManagerInstaller.swift`.
- Both export controls previously required a completed `AppModel.app` graph.
  `AppBootstrapOperation.start`, `AppModel.bootstrap`, and
  `AppModel.beginDiagnosticsExport` in
  `Sources/ForgeConductorApp/AppModel.swift` now prepare diagnostics off the
  main actor before graph construction and retain the sanitized startup error.
  `ForgeApp.bootstrap(home:clock:diagnostics:)` and `shutdown` in
  `Sources/ForgeConductorCore/Application/ForgeApp.swift` borrow that same
  logger; graph shutdown flushes it, and AppModel owns its off-main close.
  `DiagnosticLog.export` in
  `Sources/ForgeConductorCore/Infrastructure/DiagnosticLog.swift` permits an
  explicit failed-startup export of the bounded live ring when persisted
  history is unavailable, disclosing that omission in JSON and Markdown.
  Existing bootstrap calls and the two-argument `DiagnosticRecording.export`
  source contract remain available; exact identifier, team, certificate, and
  daemon-hash protections remain enforced.

For the commands below, `E` is
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-03-bootstrap-export`;
commands run from `/Users/flynn/GitHub/Forge-Conductor-MacOS`. The named receipts
contain full argument arrays and terminal results.

| Exercise | Command or retained execution receipt | Actual result |
| --- | --- | --- |
| Native Debug build | `xcodebuild -workspace ForgeConductor.xcworkspace -scheme ForgeConductor -configuration Debug -destination 'platform=macOS' -derivedDataPath "$E/DebugBuild" build` | Exit 0, `BUILD SUCCEEDED`; `native-debug-build-final-result.json` and `.log`. |
| App-hosted bootstrap tests | `xcodebuild -workspace ForgeConductor.xcworkspace -scheme ForgeConductorAppTests -configuration Debug -destination 'platform=macOS' -derivedDataPath "$E/AppTestBuild" -resultBundlePath "$E/AppTests.xcresult" -parallel-testing-enabled NO '-only-testing:ForgeConductorAppTests/AppBootstrapAppTests' test` | Exit 0; 8 executed, 0 failures; `native-app-hosted-result.json` and `.log`. |
| Universal Release archive | `xcodebuild -workspace ForgeConductor.xcworkspace -scheme ForgeConductor -configuration Release -destination 'platform=macOS' -derivedDataPath "$E/ReleaseBuild" -archivePath "$E/Validation.xcarchive" ONLY_ACTIVE_ARCH=NO archive` | Exit 0, `ARCHIVE SUCCEEDED`; `native-release-archive-result.json` and `.log`. |
| Developer ID export | `xcodebuild -exportArchive -archivePath "$E/Validation.xcarchive" -exportPath "$E/Export" -exportOptionsPlist "$E/ExportOptions.plist"` | Exit 0, `EXPORT SUCCEEDED`; `native-release-export-result.json` and `.log`. Manual Developer ID export uses existing owner team `9AQ2C2838M`. |
| Compiled export signing policy and artifact identities | `"$E/exported-signing-policy-probe"`; `/usr/bin/python3 "$E/verify_distribution_identity.py"` | Probe exit 0: app, launcher, CLI, and daemon require Developer ID extension `1.2.840.113635.100.6.1.13` and each satisfies it. Artifact verification: 215 checks, 0 failures (`exported-policy-probe.log`, `distribution-identity-verification.json`). Both architectures' daemon seals match before and after export. Bytes outside `LC_CODE_SIGNATURE` are identical for all five compared binaries; whole-file SHA-256 values differ. |
| Exported CLI bootstrap | `"$E/Export/Forge Conductor.app/Contents/Helpers/forge-conductor" status --home "$E/exported-cli-fixture"` | Exit 0; `exported-cli-bootstrap-result.json` and `.log`. |
| Native GUI bootstrap and folder-picker export | Direct CUA exercise of `"$E/Export/Forge Conductor.app/Contents/MacOS/Forge Conductor"`; `native-gui-fixture/failure-launch.json` and `healthy-launch.json` | Failed home PID 13256 and healthy home PID 13459 both exported actual paired JSON/Markdown through the native folder picker. Failure export has 3 records with startup error and unavailable-history disclosure; healthy export has 8 records. `native-gui-fixture/export-verification.json`: 23 assertions passed; `healthy-manager-status.json`: version 0.16.5, HTTP listening on isolated loopback port 49844. Files are retained under `failure-exports/` and `healthy-exports/`. |
| Native UI XCTest attempt | `xcodebuild` selecting the two `ProductionOnboardingUITests` folder-export methods; full command in `native-export-ui-result.json` | Exit 65: timed out enabling automation mode during runner initialization; **0 tests executed**. No automation permission changes. The separate CUA exercise above is observed native evidence, not an XCTest pass. |
| Focused source regressions | `swift test --filter` selection recorded in `focused-swift-final-result.json` | Exit 0; 61 executed, 0 failures, before the final callback `@Sendable` annotation and version-literal correction below. |
| Final source regression | `swift test` | Exit 0 (`full-swift-regression-final-result.json` and `.log`): qualification-support selected 30, skipped 0, failed 0; Core selected 1,961, skipped 12, failed 0. Across both targets: 1,991 selected, 1,979 passed, 12 skipped. Skips are unperformed checks. The earlier full run exited 1 on the stale H0 version literals; the corrected `H0IsolationTests` selection passed 7/7 before this final full rerun. |
| SwiftPM products | `swift build --product forge-conductor`; `swift build --product forge-conductor-app` | Both exit 0 on final inputs; `cli-build-final-result.json`, `app-product-build-final-result.json`, and matching logs. These are compilation receipts, separate from the native archive above. |

The full rerun emitted a sanitized missing-log-file diagnostic while
`RigParityTests/testManagerNodeStartStopInProcess` was executing; that test passed.
The redacted stderr line does not establish the writer or fixture path, and no
production cause is assigned. The 12 skipped checks cover live provider work,
disposable Keychain use, prepared signed-peer/job fixtures, child-only harness
cases, and the runtime PowerShell capability check; their exact reasons remain
in the full log. The run does not qualify those paths.

`xcode-membership.json` compares the canonical workspace/project with baseline
`3a00c9e4f08a3951d7db3aa6814b6eb8bef61044`: all non-build-configuration graph
objects, workspace references, shared schemes, resources, and embedding are
unchanged. Only 17 configuration objects changed for signing/version settings;
the 10 inspected native source/test files have their existing membership.
`H0IsolationTests.swift` remains in the existing SwiftPM-only
`ForgeFilesystemQualificationSupportTests` target; it has no Xcode file reference
or test target, and this edit does not add one.
The final H0 change is test-only and does not change the archived application
inputs.

The original installation was restored and reopened with its existing
0.16.4 failure. Its executable SHA-256 and strict signature remain preserved;
`~/.lmstudio/mcp.json` remains
`7663a4f6ae3bee266eb7cefe7edc18056ff1f34c72d72ae8265dbb4e1398b7a3`
(`native-gui-fixture/export-verification.json`). These checks qualify the
corrected source project and the isolated native candidate paths described
above. They do not qualify installation, notarization, distribution, or a full
LM Studio workflow. The owner retains those shipping steps.

## Prior 0.16.4 diagnostic source correction — historical test boundary

The prior repository source identity was `0.16.4 (25)`. The October 2 alpha
archive exposed six evidence gaps. Current
source changes preserve sanitized error identity, distinguish returned tool
failures from exceptions, classify `fs_read` errors by observed cause, retain
shell job and continuity attempt identity, and disclose Markdown timeline
omissions. The [A–H capture contract](DIAGNOSTIC-CAPTURE-CONTRACT.md) names the
source writers and regression tests. On the final `0.16.4 (25)` source tree,
`swift test` selected 1,955 tests, skipped 13 and failed 0; the canonical
Debug workspace build succeeded, and the complete app-hosted target passed
127 tests with no failures. The exact commands and terminal lines are in the
[roadmap](../ROADMAP.md).
At that earlier source-test boundary the installed app was still 0.16.3.
The later owner-installed 0.16.4 exposed the signing and startup-export failures
recorded above; those prior tests did not qualify that installed path. Discarded historical
exceptions cannot be recovered from that archive.

## 0.16.3 CLI staging and LM Studio deploy receipt — October 1, 2026

A fresh universal Developer ID archive was created at 2026-10-01 11:49:05 UTC
while Git HEAD was `b8a2c5dee546dff8d914405c2169a075bd0187e2` (verified
by the archive `Info.plist` creation time and Git reflog). That tree retains
product code `a54100b453ba8b1c1489ff09ac64dd6193fc1597` and `0.16.3
(24)` identity. The archive app was strictly deep-signature verified and its
embedded helper reported `0.16.3`. The candidate's own
`Contents/Helpers/forge-conductor install` copied the CLI binary and app
under `~/.forge-conductor`; it did **not** install into `/Applications`, and
its output correctly said LM Studio is not changed by that command. Running
that staged helper's `forge-conductor
install-lmstudio-plugin` then completed deployment revision
`7a3b0b17-0e39-4cce-b4cd-20df1c6ee9db`, reported at least 71 primary and
fallback tools and all four CLU controls, and wrote primary, fallback, and CLU
entries to `~/.lmstudio/mcp.json`. No manual edit followed the installer.

Source boundary: `ManagerInstaller.installedBinaryURL` is
`paths.home/bin/forge-conductor`; `stageInstalledArtifacts` executes
`artifactCopier.copyItem(at: binarySource, to: binaryStage)` and commits that
staged copy to the home target. The default copier delegates to
`FileManager.default.copyItem`. Separately,
`LMStudioMCPPluginInstaller.install` builds
`mergedMCPRegistrationData(binaryURL: binary, deploymentID: deploymentID)`
and commits it with `mergedMCPConfig.write(to: configURL, options: .atomic)`.
Neither function installs a `.pkg` into `/Applications`. GUI Deploy uses
`Bundle.main.executableURL` through `AppModel.deployToLMStudio`, not the CLI
helper used in this receipt.

Each entry has command `/Users/flynn/.forge-conductor/bin/forge-conductor`,
argument `serve`, the same deployment ID, its respective role, and no `cwd`.
The archive-embedded helper, staged support helper, support app's embedded
helper, and manually copied `/Applications` app's embedded helper all
have SHA-256
`49e81bc5522aff13d77c0b710417add067467d38e05fec651062be2f5480a289`.
The `0.16.2 (23)` `/Applications` app and its desktop-provider helper were
stopped; the app was backed up and the signed `0.16.3 (24)` candidate was
manually copied over it for a cold-start observation. This was not a package
installation. Forge and LM Studio then
cold-started. `mcp.json` remained SHA-256
`7663a4f6ae3bee266eb7cefe7edc18056ff1f34c72d72ae8265dbb4e1398b7a3`
before and after both launches, so neither launch reverted the registration.

In the ordinary LM Studio Jamf-Technician chat, hosted fallback PID `38508`
returned `get_forge_status` v0.16.3, client
`lm-studio:faf23139c06a39f92a71bf3bcdb267154717cd7e623e4d326188093f6f96d54a`,
and `project_context.attached: true`. After that PID exited, hosted fallback PID
`38964` returned the identical client ID and attached project/generation. Its
subsequent `fs_list`, `git_status`, `instruction_catalog`, and
`continuity.status` results each had `ok: true`, without another manual bind
or `project_context_required`. A separate paged catalog call with `limit: 1`
also returned `ok: true`. The transcript is
`~/.lmstudio/conversations/Jamf-Technician/1790852478591.conversation.json`;
the first post-install model turn claimed five calls but recorded only four,
so Continuity was explicitly called and verified in the next turn. The later
replacement-PID sequence recorded all four gated calls.

The signed package `ForgeConductor-0.16.3-24.pkg` was produced and its
Developer ID Installer signature and timestamp verified, but `installer`
returned `Must be run as root to install this package`; `sudo -n` was not
available. This is **not** a package-install pass. The CLI staging/deploy,
copied GUI candidate launch, and hosted MCP path were exercised. GUI **Deploy
to LM Studio** was not exercised: `AppModel.deployToLMStudio` passes the
running app executable, while the CLI run passed its staged helper. Its
registration behavior is therefore not qualified by this receipt.
Notarization, stapling,
Gatekeeper acceptance, Apple upload, public shipment, and other roadmap gates
remain open. No product code, version, build number, or Xcode graph was
changed, and no Continuity clear, reset, or delete was invoked. The existing installer test class
`LMStudioConnectorReliabilityTests` executed 9/9 without failures.

## 0.16.3 MCP reconnect and Dashboard binding correction

At that historical checkpoint, source identity was **0.16.3, build 24**. Installed `0.16.2 (23)`
diagnostics reproduced an LM Studio fallback helper restart that changed PID and
random MCP client UUID, after which project-scoped tools returned
`project_context_required`. A second live transcript showed that even
`get_forge_status(project_id)` on the replacement client returned success
without establishing the binding required by `fs_list`, `instruction_catalog`,
or `shell_exec`.

The correction gives ordinary LM Studio primary, fallback, and CLU helpers one
bounded deployment-scoped client identity across process restart, and makes
`forge_status` / `get_forge_status` idempotently attach an unseen deployment to
an explicit project or the sole active project. Instruction catalog/read now
accept the resulting project-generation context without requiring a Managed
Run. Existing inactive bindings from a generation reset are not reactivated,
and ambiguous multi-project selection still requires `project_id`.

Implementation revision `a54100b453ba8b1c1489ff09ac64dd6193fc1597`
contains the completed correction and exact replays:

- `testStatusBootstrapUnblocksAllReportedProjectScopedToolsOnSameClient`
  asserts `fs_list`, `instruction_catalog`, `shell_exec`, and
  `continuity.status` each fail with `project_context_required`, then asserts
  `get_forge_status(project_id)` returns `project_context.attached == true`,
  and finally asserts the same four calls succeed on client
  `A800AC6E-8B31-4E64-A0CE-9B9DA192CADA`.
- `testDeploymentScopedMCPReconnectUsesExistingBindingWithoutSecondStatusCall`
  creates primary and fallback `MCPServer` objects with different random process
  identities and one deployment ID, calls status only through the primary, and
  asserts all four gated tools succeed through the fallback.
- `testEmptyDeploymentMCPStatusAttachesFreshRandomClient`,
  `testForgeStatusKeepsPolicyLocationWhenProjectSelectionIsAmbiguous`, and
  `testGetForgeStatusDoesNotReactivateBindingInvalidatedByGenerationReset`
  cover the empty deployment, explicit two-project selection, readable status,
  and reset fence.
- App-hosted
  `testRegisteredProjectBecomesTrackableOnlyAfterStatusBindingSurvivesReconnect`
  asserts `.unbound` before status and the exact durable project/generation
  after reconnect with a different process identity.

The complete Core selection passed 55/55, project-context integration passed
10/10, MCP protocol and diagnostics passed 20/20, both SwiftPM products built,
the canonical Debug workspace build succeeded, and the focused Dashboard case
passed in `ForgeConductorAppTests`.

On October 1, the reloaded LM Studio primary, fallback, and CLU entries all
named `/Users/flynn/.forge-conductor/bin/forge-conductor serve`, supplied
deployment revision `6b6aa0b4-c3bd-454b-96e4-1273abf390f1`, and supplied no
`cwd`. The helper reported `0.16.3`, and SHA-256
`41a0a94fe247a2ea4718f43b1dd32a19bc7414e4d202f37d8c32e09312046387`
matched the source-`a54100b` build-24 candidate helper.

Forge and LM Studio were both terminated and relaunched. A new ordinary LM
Studio chat then used the fallback registration and hosted PID `33715`. Its
first `get_forge_status(project_id)` attached project
`d2610542-b616-7e8f-ee36-ef902d6060e1` generation 7 to stable client
`lm-studio:12ec4eaf781d85b33f4dde7e180dbbd44367c93155660ec486c1b4cb2d21a6fc`.
The next `fs_list`, `git_status`, `instruction_catalog`, and
`continuity.status` calls all succeeded without another bind or initialization
call. The registration record, status root, and Git top level all identify
`/Users/flynn/GitHub/Jamf-Technician`; the Documents-path variant is absent.
This was the earlier hand-deployed-helper evidence; it did not at that time
qualify the separate GUI installation or distribution.

The universal Developer ID app and archive are at `/Users/flynn/Desktop/Forge
Conductor 0.16.3 (24)-a54100b-DeveloperID`. Both report `0.16.3 (24)` and the
app is `x86_64 arm64`; strict Release validation passed for the app, Core
framework, embedded CLI, runtime launcher, and filesystem daemon. At the time
of that receipt, `/Applications/Forge Conductor.app` remained `0.16.2 (23)`
with executable SHA-256
`fc29b8006af141cfc7c5c99f219eb22faca593b430b6adadd6a8581e3243e542`.
The earlier wiki receipt was `e615c2405a094b43f9ebb4794ba0676c86ae38bd`.
The later CLI staging/deploy receipt and its package-install limitation are
recorded above.

## 0.16.2 owner-notarization artifact set (historical)

The shippable universal Developer ID build `0.16.2 (23)` from product source
revision `22e7443d13496b3cc08b6e98366bb6d2332e3fd4` is ready for owner
notarization and Apple upload. The retained Desktop directory contains the
canonical `ForgeConductor` archive, manual `developer-id` export, app ZIP,
Developer ID Installer package, hashes, and command-only owner notarization
file. The archive and all five shipping objects pass strict signing, hardened
runtime, secure timestamp, exact team and role identity, universal-architecture,
no-App-Sandbox, and Release privileged-filesystem-bundle checks. Extracted ZIP
and PKG payloads passed the same Release checks.

No notarization, stapling, installation, Apple upload, shipment, or release was
performed. Gatekeeper correctly reports `source=Unnotarized Developer ID` for
the pre-notarization app and package. `/Applications/Forge Conductor.app`, live
LM Studio registration, and Continuity packets were not changed.

## 0.16.2 Development Policy bootstrap

The retained Desktop candidate identity is **0.16.2, build 23**.
`get_forge_status` in that source
returns the pinned governing Development Policy identity, every active Rune
Forge policy source path in durable priority order, the supported filesystem
read tools, and a required action directing the LM Studio model to read and
follow all applicable policy requirements before development changes. The
additive contract preserves all prior project, instruction, continuity, and
resume fields. It also returns the bound project's durable instruction-package
execution order with IDs, names, positions, source paths, and snapshot hashes;
policy location and the required action remain present when project selection
is ambiguous. Focused SwiftPM regressions for the ordered project response,
ambiguous-project response, and MCP tool description each executed with zero
failures. Both SwiftPM products and the canonical Debug workspace build passed.

Implementation revision `22e7443d13496b3cc08b6e98366bb6d2332e3fd4`
produced the universal Developer ID archive and export under `~/Desktop/Forge
Conductor 0.16.2 (23)-22e7443-DeveloperID`. Strict deep signature verification
passes. The app and embedded MCP helper report Developer ID Application James
Daley, team `9AQ2C2838M`; the app reports `0.16.2 (23)` and the helper reports
`0.16.2`.

LM Studio primary, fallback, and CLU registration revision
`32b3c0a3-c621-4e1e-bfe2-75838c5ea86d` points to that exact candidate helper.
After an LM Studio quit/relaunch, the existing Jamf-Technician chat called
`get_forge_status(project_id: d2610542-b616-7e8f-ee36-ef902d6060e1,
resume: true)` through `mcp/forge-conductor-fallback`. Its persisted raw tool
result reports final repeated PID `12436`, version `0.16.2`, the priority-1 policy source and
read/follow requirement, package `Jamf-Technician-Continuation-Package-R1` at
position 0, project/instruction/continuity locations, and resume data. Primary
PID `12434` and CLU PID `12435` use the same candidate and deployment revision.
The working `/Applications/Forge Conductor.app` was not replaced. Notarization,
stapling, Gatekeeper acceptance, and shipment remain open.

## 0.16.1 native host access and Dashboard project tracking (historical)

Source identity **0.16.1, build 22** changed the native filesystem,
search, PDF, Git, shell, and runtime paths no longer enter Forge's per-command
Seatbelt profile or reject absolute paths merely because they are outside a
selected project folder. Project binding and generation remain mandatory for
attribution and durable isolation. macOS evaluates TCC access for the
responsible signed code objects in the actual launch chain; a live protected-
path probe establishes protected-path access only for that exact launch chain.
Tool grants, shell enablement, canonicalization, deadlines, output bounds, durable
result fencing, and destructive-root protection remain in force. Native jobs
use a default 16-descendant budget and a 1,024-identity hard cap; overflow is a
typed failure, and unconfirmed termination becomes bounded identity-fenced
cleanup debt. Local outside-project delete and move independently rebuild the
protected-root set and descriptor-recheck source identity immediately before
namespace mutation.

Dashboard now identifies the tracked project from live MCP presence and the
matching active `mcp_client` binding. It orders multiple live clients by recent
activity with heartbeat fallback, uses an exact nonterminal run only when no
live binding resolves, and never treats registration alone as active work.

The complete focused `CoreTests` selection executed 49 tests with zero
failures. The all-available-runtime profile case exercised an external working
directory, `/bin/ps`, and inherited environment state. The complete runtime-job
suite executed 103 tests with zero failures, including bounded cleanup of an
observed `setsid(2)` child, and the secure-filesystem suite executed 100 tests
with zero failures. Dashboard operational-snapshot tests executed 23 tests with
zero failures in both SwiftPM and the app-hosted Xcode target, including
live-binding preference and the registered-only negative case. The final
integrated SwiftPM run executed 1,933 tests with 12 explicit environment-
dependent skips and zero failures. Both SwiftPM products and the canonical
Debug workspace build passed.

Exact implementation revision
`91ad90ee7a1e51b7289f4c531ddae4dbbc6812ec`, tree
`08e021b375fb8a998f06d9e81a10e3fffddd21f0`, produced the universal Developer
ID archive and export under `~/Desktop/Forge Conductor 0.16.1
(22)-91ad90e-DeveloperID`. Strict validation passes for the app, CLI, runtime
launcher, Core framework, and filesystem daemon. All five carry James Daley's
Developer ID Application identity on team `9AQ2C2838M`, hardened runtime,
secure timestamps, and no App Sandbox entitlement.

The exported candidate's MCP helper passed an isolated end-to-end probe. Its
project context reports
`filesystem_access_scope=host_native_inherited_unconfined_by_forge`,
`filesystem_sandbox_mode=none`, and
`filesystem_path_confinement=false`. It read one byte from a protected Mail
path without returning content, ran `/bin/ps`, resolved Apple Git from inherited
`PATH`, completed filesystem read/write/search and Git commit operations outside
the selected project, completed a native runtime job, and returned the exact
bound project from `get_forge_status`. Gatekeeper assessment exits 3 with
`source=Unnotarized Developer ID`; this is an explicit non-pass. Notarization,
stapling, Gatekeeper acceptance, a live native multi-project Dashboard UI
observation, and shipment remain open. The working installation was not
replaced. Protected-path access through the installed Forge application and
the LM Studio-hosted launch chain remains to be exercised with this candidate.

## 0.16.0 foreground successor and packet management (historical)

Source identity **0.16.0, build 21** added Continuity lists of the
actual durable checkpoint/handoff packets under each project ID and enabled
deletion of only the exact single or multi-selection after confirmation. Reset
and Clear Cache remain on Continuity; instruction-package controls are confined
to Projects. Focused packet store/wire and native UI tests execute with zero
failures.

Same-host LM Studio configuration no longer exposes or accepts an operator
credential. The build-19 correction removes the obsolete local Forge Keychain
reference on this host; the persisted local configuration reports no reference
and the credential journal is a tombstone.

The optimized Release packet decoder now passes its strict scalar/container
test and the repaired Release helper reads the live durable packet inventory;
build 17 had returned an empty list for the same valid rows. The build-18
candidate exposed one additional defect: it hid registered packet projects when
automatic continuity reported `unavailable`. Build 19 keeps those projects
visible for packet management.

Candidate revision `a540670b54e78aeff1793848a9cc16e0be6fe438`
produced `/Users/flynn/Desktop/Forge Conductor 0.16.0 (21)-a540670.app` and the
matching `.xcarchive`. The GUI is universal arm64/x86_64; strict deep signature
verification reports Developer ID Application team `9AQ2C2838M`.

**Prior build-19 E0 retained by build 21:** the ordinary owner-surface UI case executed one
test with zero failures and found the Continuity project/packet frames plus
Copy Project ID, Delete, Reset, and Clear Cache. The real-provider UI case
executed one test with zero failures, discovered loaded model
`qwen/qwen3.8-27b`, clicked Connect and Check and Run Advanced Probe before and
after relaunch, and read back ready/contract-valid with
`credentialConfigured=false`. It also asserted that the loopback screen has no
token field or credential action.

The live Continuity inventory began with 75 packets. Two exact-candidate UI
runs selected, confirmed, and deleted only disposable packet IDs
`708cbe57-06b4-4cf3-85f8-75c458966b81` and
`60f7f1be-636c-443d-9cae-2c1fd5a6fc85`. The final inventory contains the 73
pre-existing IDs, with zero unexpected removals and zero additions. A separate
focused multi-selection case issued one delete request for exactly two selected
IDs and retained the third packet. Exported screenshots and accessibility
dumps are beside the candidate in `Forge Conductor 0.16.0 (19)-868645e
Evidence`.

The tracked repository, candidate, and Forge support directory contain no local
LM Studio token variable, secret prefix, or token-bearing authorization value.
The rejected Forge Keychain item is absent, and the local provider JSON contains
no credential reference.

A fresh foreground LM Studio GUI chat called `get_forge_status` through the
candidate's registered fallback MCP process, then called `context_get`,
`memory_list`, `memory_search`, and `fs_read`. Its visible answer returned Forge
home `/Users/flynn/.forge-conductor`, project `Jamf-Technician`, project root
`/Users/flynn/GitHub/Jamf-Technician`, project ID
`d2610542-b616-7e8f-ee36-ef902d6060e1`, and resume-ready handoff prefix
`fdb9130a`. The chat was the foreground LM Studio tab.

**E0 on the build-21 Desktop candidate:** disposable handoff
`79474019-000f-4395-a593-cc74a6da2372` committed at
`2026-09-28T10:01:08Z`. Manager exposed the due time
`2026-09-28T10:01:38Z` and was observed at 25 seconds remaining. At expiry the
candidate used LM Studio's public macOS Accessibility controls to open and
select foreground tab `Forge Rollover Successor Proof`, then entered `get_forge_status`,
`resume=true`, the exact handoff ID, and rollover nonce
`517cbb4f-f1bd-cc69-e1df-f14ffc7f5f9c`. The visible chat called
`get_forge_status mcp/forge-conductor-fallback`. Its owner-only receipt records
the same handoff and nonce, `resume: true`, and acknowledgement time
`2026-09-28T10:06:48Z`.

The native ledger has exactly one record for that handoff: logical successor
`51a4567d-36f9-4d44-8a54-925f6e14a0f5`, provider identity
`lmstudio-gui-877df47abf1e5782aea37f27`, status `acknowledged`. Only after that
receipt did Manager append the exact handoff once to
`interactive-continuity-sealed.json`; the operator snapshot then reported
`completed`. A delayed watchdog check retained one successor record. The driver
contains no `/api/v1/chat` call or integrations array and stores no same-host LM
Studio credential. CLU live delivery and owner acceptance remain open. This is
not shipment acceptance, and `/Applications/Forge Conductor.app` has not been
replaced.

The live chat's fallback MCP child used the compatible build-20 registration
that was active when the chat started; build 21's app process supplied the
corrected foreground GUI driver. After the receipt and seal were captured, the
supported installer synchronized primary, fallback, and CLU commands in
`~/.lmstudio/mcp.json` to the exact build-21 candidate. The resulting
registration contains no token, Authorization, or credential field.

The prior build-16 candidate at revision `f2cc6ca` remains historical evidence
only. Its Continuity package control and project-wide delete do not satisfy the
current packet contract.

## 0.15.0 Continuity history retention controls

Product correction `849b87953b4420f07a629fdcd29ecf0d58216756`
extends the accepted `0.15.0 (14)` identity with cleanup for every old item the
Continuity view presents. The exact control-plane predicate is
`commandIsTerminal || run == nil || run?.state.isTerminal == true`. The
project-memory removal predicate is
`stored.state == ContinuityState.predecessorSealed.rawValue || stored.quarantined`.
For an old list row whose project operation remains nonterminal, the Manager
first retires that stale operation, then removes its visible command root,
schema-2 operation, handoff, transition and repair payloads, and rebuildable
JSON/current/latest projections. A payload-free tombstone prevents stale replay.
A genuinely live owner remains visible with its exact run/command state and an
**Open Run Details** action. Ordinary project memory records, tasks, runs,
credentials, project files, and unrelated project data remain unchanged.

**E0 on the exact Desktop app:** `/Users/flynn/Desktop/Forge Conductor 0.15.0
(14)-849b879.app` reported bundle identity `0.15.0 (14)`. Its live Continuity
view began with 24 stored IDs. **Clear Selected** removed
`c36460fe-05ae-b00c-8aae-100209600137`, leaving 23 after Refresh. **Clear All
Old** removed the remaining 23; the IDs were still empty after Refresh and
after termination and exact-path relaunch. The matching archive is
`/Users/flynn/Desktop/Forge Conductor 0.15.0 (14)-849b879.xcarchive`. Neither
artifact was installed. The candidate is Apple Development signed, universal
arm64/x86_64, and passed strict deep signature validation. Its executable
SHA-256 is
`f2b89c2e38a3b25119258989b9987a5aee595f0a18b7e90861c035ed1e579ce0`.

The post-correction complete Swift suite executed **1,890 tests with 12
explicit environment/live skips and zero failures**. The complete app-hosted
suite executed **111 tests with zero failures**. The separately gated exact-app
live Continuity case executed one test with zero skips and zero failures. Both
SwiftPM products built. The owner will perform final acceptance, distribution,
and shipment separately; `/Applications/Forge Conductor.app` was not replaced.

## 0.14.7 Projects instruction controls — Desktop candidate

Candidate source `74ead97e0b4d2116e80e8482d5736afc94e16372` closes the
remaining deterministic control-identity gap after the nested `List` and
in-flight poll wipe were removed. The plain package `VStack` still had one
container accessibility identifier; SwiftUI propagated it over every package
child and replaced the exact earlier/later/Remove identifiers. The candidate
removes only that parent override. Stop remains in the action bar above the
rows, and the bordered child buttons retain their individual identities.

**E0 on this Mac:** the Apple Development-signed native minimum-window case
clicked **Stop Active Work**, Move later, and Remove, then observed the saved
order and absence after later two-second queue polls. The signed real-Manager
case imported two packages, persisted reorder, removed one, and passed. A new
runtime integration test started an active run-owned `sleep 30` job, stopped
its queue, verified job and run cancellation, observed the package terminal and
unlocked, and removed it. The instruction-queue suite passed 37/37 and the
Projects view-model suite passed 18/18, including the in-flight refresh case.
Both SwiftPM products built. A universal Debug app and `.xcarchive` were built
outside `/Applications`; strict deep signature verification passes and the
built Info.plist reports `0.14.7 (13)`.

**E0 live candidate acceptance:** a signed native test attached to PID `15318`
only after asserting its bundle URL was
`/Users/flynn/Desktop/Forge Conductor 0.14.7 (13)-74ead97.app`. At normal size,
Projects started ordered package `d275cbbf-3c54-43af-858f-bd43fec39d4b` as
LM Studio run `450f1a7f-8f49-4d78-bd7d-1e97c94f6273`; the run was observed
`running` with model `qwen/qwen3-coder-30b` and a non-null managed session.
Clicking **Stop Active Work** produced terminal run/package state `cancelled`,
queue `running=false`, and an enabled Remove control. Move earlier persisted
the exact two-package order after Refresh, and removing the other package
persisted after Refresh. At the 1100×788 minimum window, package
`2c1c98e3-bf1c-4eca-a481-03b1fe5448e6` started as live LM Studio run
`850f0576-225f-4b04-a4ff-a5d43471494d`; Stop was hittable and produced the
same terminal/unlocked state. Move later and Remove were both hittable, and
their resulting order/absence persisted after Refresh. Post-test Manager
readback retained both runs as `cancelled`, the queue as stopped, and LM Studio
reported the pinned model `IDLE`. The focused `.xcresult` executed 1 test with
zero skips and zero failures.

The working installation was not replaced. Developer ID signing, notarization,
Gatekeeper distribution acceptance, owner final testing, and shipment remain
open. The live evidence closes only the reported Projects Stop/reorder/remove
acceptance gap and is not a shippable-build declaration.

## 0.14.7 Projects instruction controls — prior incomplete baseline

Product source `b4bf571de822cc463dc69c30f4a10c12033919cd` addressed the
manager cancellation and first layout defects but did not close the reported
inability to stop, reorder, or remove project instruction packages. Its
package-container identifier still replaced the child Move/Remove identities;
the current Desktop-candidate section above records the correcting evidence.
**Stop Active Work** now fences queue advancement, quiesces and durably cancels
the exact active run, and only then reconciles the package to a removable
terminal state. A stopped queue with a still-running package retains a
retryable cancellation path. Reordering has explicit native earlier/later
controls in addition to drag behavior, and package/remove plus queue actions
use leading rows that remain hittable in the constrained Projects layout.
Revision-monotonic queue acceptance prevents a two-second background poll from
replacing a newer mutation response.

**E0:** a production-composition, Apple Development-signed UI test imported two
real files through the authenticated Manager API, found the native move and
remove controls, persisted the reversed package order, removed one package, and
verified the remaining durable identity. The first reproductions recorded the
original action controls as present but non-hittable beyond the visible window;
the identical final flow passed after the layout repair. Focused queue,
Projects view-model, and Manager-route tests passed, including stopped-queue
cancellation retry and stale-revision rejection. Complete regression and build
counts are recorded in the current roadmap row.

The working installation was not replaced. Developer ID signing, notarization,
Gatekeeper distribution acceptance, and owner shipment remain separate from
this source-candidate repair. The publication receipt is documentation-only and
does not change the tested source inputs or canonical Xcode graph.

## 0.14.6 Provider and ordered-run repair — installed development build verified

Product repairs `675d267fdd2f45cd412e5398a04a2321bfe51def`,
`f39c79ad0e60259d7a02ba0361825e5b6940c136`, and
`101c3d44f80c689c428e255f4578d88c54f40c16` add the missing
live LM Studio readiness boundary to ordered-work admission, ignore stale
project generations during provider-repair resume, expand the bounded managed-
provider receipt window so a maximum-round run retains its first turn, preserve
continuity identity through budget escalation, and release project-local
continuity authority when its owning run is cancelled.
The existing Provider repair prevents deactivating the sole selected provider,
lets LM Studio activation supersede a replaceable background snapshot load,
preserves no-resume preparation through the manager-client router, and keeps
Guided Setup closed until explicitly opened.

**E0, installed build:** the owner-state pin `qwen/qwen3-coder-30b` was installed
but unloaded when the original queue rejection was recorded. Loading that exact
pin and running **Connect and Check** produced a current `contract_valid`
readiness receipt. The installed `/Applications/Forge Conductor.app` then
returned HTTP 200 for the same project/package **Start Ordered Work** request.
The final live run `6573026b-35f1-47b8-a0c6-6b4df226eed7` completed 50 LM Studio
turns, 41 tools, and 18 automatic rollovers. It then paused at the separate
package completion gate because project-build and project-tests evidence was
absent. It did not reproduce the LM Studio configuration, receipt-reconciliation,
continuity identity-drift, or stranded-operation failures. The prior terminal
run's exact operation is retained as `run_cancelled` quarantine history. The
provider ledger still selected `lmstudio`, reported it configured/selectable,
and had no current operation. Exact native UI passed launch without an automatic
setup sheet and the Provider selection/LM Studio transaction.

The complete SwiftPM regression passed 1,879 tests with 12 explicit skips and
zero failures. Both SwiftPM products and the canonical Apple Development-signed
Debug workspace app built; strict deep signing, repository hygiene, and Xcode
membership checks passed. Gatekeeper rejects this development-signed app as a
distribution artifact. Developer ID signing/notarization and shipment remain
open; this section does not call the build publicly shippable.

## 0.14.5 project-workflow repair — qualification incomplete

Version `0.14.5 (11)` fixes mixed-folder instruction admission, keeps package
addition and pending-order changes available during active ordered work,
consolidates direct-task and run controls under Projects, and separates native
content from the macOS title/toolbar chrome. The complete SwiftPM regression
executed 1,872 tests with 13 explicit environment/helper skips and zero
failures. All 36 instruction-queue tests, all 15 operator-project contract
tests, and three signed native UI cases passed. Both SwiftPM products and the
canonical Apple Development-signed Debug app built; exact `0.14.5 (11)`
bundle/CLI identity and strict deep-signature checks passed. Live LM Studio and
Codex execution has not yet been repeated for this identity, so its shipment
verdict remains inconclusive and it is not called shippable.

Current operator board:

- Autonomy removal — PASS
- Telemetry frame — ACCEPTED
- Mixed-folder packages — PENDING operator review
- Projects/LM Studio ordered work — PENDING operator review
- Automated Continuity handoff — PENDING operator review

The three pending items are implemented pending owner live review. Their source
and deterministic evidence are recorded, but they are not implemented-and-
qualified, accepted, or shippable claims.

## 0.14.4 local LM Studio and Codex shippability

The owner's acceptance boundary for this build is local: Forge Conductor must
build and run on this Mac, and its complete project workflow must work with the
two providers the owner uses, LM Studio and Codex. Version `0.14.4 (10)` closes
the observed setup failures within that boundary.

**E0:** the signed Debug app discovered and prepared loaded
`qwen/qwen3-coder-30b`, selected LM Studio, registered the repository, admitted
an immutable instruction artifact, and created a managed task. Repeated MCP
deployment and app restart left the model loaded. A fresh Codex
`0.155.0-alpha.16.4` task loaded the installed Forge package through Codex's
normal trust review, attached to the exact project run, successfully called
`forge_status`, and completed all three compiled automatic obligations with a
durable `desktop-hook` evidence reference. All seven configured Codex hooks and
the Forge MCP server were visible to the host.

The final full regression executed 1,851 tests with 13 explicit
environment/helper skips and zero failures. Both SwiftPM products and the
canonical Apple Development-signed Debug workspace app built; strict deep
signature verification and `0.14.4 (10)` bundle/CLI identity checks passed.
Repository checks passed. Product source
`cdc539ec35d0f19493d6169ddd827e130870b02f`, tree
`e1291f80f2a2dd87b7cb7df112358706cf89ae61`, and wiki revision
`96199f79899e02e133652771a022dd6c7ae84599`, tree
`aa6dfa40949b424821b89f1694c0811e6ab182e8`, are published. Exact local/remote
parity is verified after the documentation closeout. Notarization, public download, second-hardware
qualification, Claude, Grok, and a physical VoiceOver listening session are
outside this owner-defined local LM Studio/Codex acceptance scope.

## 0.14.3 project-setup transaction repair

The downloaded `0.14.2 (8)` build reproduced a real setup race: **Connect and
Check** resumed two retained LM Studio runs and then its integration deployment
restarted the provider while both requests were processing. Both streams ended
without a completed response. Three new-task attempts also imported immutable
instruction artifacts before provider preparation rejected the missing model,
leaving artifacts without durable runs. Version `0.14.3 (9)` orders these
boundaries so provider readiness precedes artifact admission, retained runs
remain quiescent across integration deployment, and only a successful
post-deployment probe resumes them. Current-source qualification evidence is
recorded below: both SwiftPM products built; the terminal full suite executed
1,848 tests with 12 explicit environment/helper skips and zero failures; the
live provider preparation and live fresh-root/continuation cases each passed in
separate zero-skip runs against loaded `qwen/qwen3-coder-30b`; two focused
app-hosted tests passed; and the canonical signed Debug app built without
compiler warning/error lines and passed strict deep-signature plus `0.14.3 (9)`
bundle-identity checks. Two signed production-onboarding UI tests passed direct
path and native-picker project registration, allowed-root persistence, Manager
readback, and relaunch. The 12 aggregate skips are not passes and retain their
separate environment-specific qualification boundaries. This remains a
development identity, not a shipment claim.

## 0.14.2 reported-run repair

The focused Core pass executed 125 cases: 123 passed, two explicit native-job
environment skips, zero failures (`/tmp/forge-0.14.2-core.log`). Five distinct
native UI cases passed before the version-only update: checkbox interaction,
Dashboard geometry, minimum/normal containment of every primary view, and
populated policy evaluation rows. Live completion of the reported owner run,
universal policy enforcement, and distribution qualification remain open.

Current source identity: **0.16.5, build 26**, supporting **macOS 26+**. The earlier
0.16.3 Developer ID app and archive are recorded in the opening build-24 section;
that workflow staged the CLI under `~/.forge-conductor` and manually copied the
app to `/Applications`. It did not exercise a `.pkg` installation, notarization,
or shipment. Earlier `0.9.0 (1)` receipts remain historical evidence only. This
page is a concise status index;
the detailed, source-bound receipts are in the
[functional-build record](FUNCTIONAL-DEVELOPMENT-BUILD.md) and
[roadmap](../ROADMAP.md).

## Version and build agreement

The Swift runtime, CLI, Xcode Debug and Release configurations, and current
documentation use version **0.16.5, build 26**. The root [`VERSION`](../VERSION)
and [`BUILD_NUMBER`](../BUILD_NUMBER) files are canonical; compiled constants
and Xcode build settings must match them. The consistency check runs locally and
in CI. Filesystem protocol, provider-plugin, and database schema versions are
separate compatibility contracts.

The canonical native project is `ForgeConductor.xcworkspace`, using the
`ForgeConductor` scheme. Its archive contains one installable app product with
the Core framework, manager CLI, runtime launcher, filesystem daemon, resources,
and icon. A standalone SwiftPM CLI is not a substitute for that signed bundle.

## Historical source and functional evidence

These records retain their named source revisions and checkpoint boundaries.
They do not qualify the current `0.16.5 (26)` candidate. Its October 3 evidence
and unperformed shipping paths are recorded in the opening section.

The September 20 adversarial pre-release audit corrected scoped dashboard
mutation authorization, a misclassified state-changing Stjornarvald route, an
unbounded port-owner subprocess path, Release entitlement/testability settings,
and browser DOM/error handling. Both SwiftPM products, the canonical Debug
workspace build, and Xcode static analysis passed. The terminal full suite
executed **1,691 XCTest cases with 12 explicit skips and zero failures**. See
the [audit record](AUDIT-2026-09-20.md). The exact audited implementation is
signed revision `839e45035c30d12efcebfbe29f31387972eaa95b`. The audit did not
create or qualify a release artifact.

The September 21 `0.11.0 (3)` source change passed both SwiftPM product builds,
the canonical Apple Development-signed Debug workspace build, repository
hygiene, and the complete SwiftPM regression: **1,700 XCTest cases with 13
explicit environment/live skips and zero failures**. The full Xcode test graph
compiled and signed. A focused native UI execution timed out while macOS enabled
automation before the selected test began, so the click-through is retained as
a host-automation non-pass rather than product evidence. The working
installation was not replaced.

The September 23 `0.12.0 (4)` identity alignment is published at revision
`bd33fda1b683070dcf56c16bb4c8ac778623ae31`, tree
`46ebbe041732f8fdd22331c031e73b7d8f7ae10f`. Both SwiftPM products, the two
focused version-contract tests, repository hygiene, and the complete SwiftPM
regression passed; the terminal regression executed **1,720 XCTest cases with
13 explicit environment/live skips and zero failures**. The canonical Xcode
Debug app built and signed, and the project-local signed smoke bundle reported
`0.12.0` and build `4` from both its app metadata and CLI. Push, fetch, exact
local/remote revision readback, and zero divergence passed. The working
installation was not replaced, and no shipment artifact was created.

The September 23 `0.14.0 (6)` provider-integration source is revision
`65af43e31aa2b818ccd2f915aa7f89c34b7c821d`, tree
`945cdb9d6adaf17c85845fe846910ece527288fd`. It passed both SwiftPM product
builds and the complete SwiftPM regression: **1,849 XCTest cases with
13 explicit environment/live skips and zero failures**. The canonical Apple
Development-signed Debug workspace build succeeded. Focused canonical Xcode
execution then passed **83 Core tests**, **40 app-hosted tests**, and **six
native UI tests**, all with zero failures or skips. The UI pass covered every
primary view at minimum and normal widths, the compact equal-height
Storage/Managed Activity row, the eight-step Dashboard setup wizard,
Continuity title-bar clearance with no unused split, and LM Studio
**Connect and Check**. Existing Thread Performance Checker diagnostics in
`ProjectContextService` wait/shutdown paths were observed again, so this is not
a clean whole-application performance claim for that historical source. The
later `0.15.0 (14)` source repaired those product paths and passed 111/111
app-hosted cases with no structured runtime warnings. The owner installation
was not replaced. Claude Code Desktop and Codex Desktop were not exercised as live
external hosts; Grok remains non-selectable.

The follow-up Swift 6 warning repair is revision
`117aa95f982bccb4c1ef0d0acc8b92666127be70`, tree
`00344bd6a1ce72f278e1a832a1d6e9f3a27f2d9f`. It constructs the
desktop-attachment descriptor on demand and makes the Provider activation
callback explicitly main-actor `Sendable`. Both SwiftPM products, a fresh
canonical Apple Development-signed Debug workspace build, and focused
`DesktopProviderMCPAttachmentTests` (**3/3**) and
`ProviderConfigurationAppTests` (**20/20**) passed; neither reported source
diagnostic appeared. The exact Downloads workspace named by the Xcode
diagnostics also built successfully after receiving the same two source edits.
Both files were already target members, so the graph and version/build remain
unchanged. This is source-build and focused-test evidence, not installed-build
or shipment qualification.

Published source `8ca3f24d9a81adce56e1a5232a6181edd08cf00b`, tree
`9bc840d7fdfe47bd552c4b8e095091502fecc3b6`, is the `0.14.1 (7)` operability
correction. It restores
the complete Continuity detail/history/manual-action surface in a toolbar-safe
adaptive layout; places the persistent eight-step Guided Setup entry point in
the Dashboard title bar; keeps Managed Activity compact beside Storage; makes
the built-in Autonomy completion checkboxes selectable; and limits configured
completion choices to those built-ins while preserving additional requirements
only from the exact instruction package. It also hardens LM Studio CLI
discovery/start/readiness polling, unifies selectable-provider **Connect and
Check**, and corrects Codex/Grok desktop package details and strict activation
outcome handling. Focused deterministic suites for those surfaces pass in the
shared tree, including Provider configuration with one explicit
Keychain-environment skip. The exact `0.14.1 (7)` tree passed the full SwiftPM suite
with **1,844 tests, 13 explicit skips, and zero failures**; both SwiftPM products
and a fresh canonical arm64 Apple Development-signed Debug workspace build also
passed. The workspace build reported no compiler warnings, including neither of
the two previously reported Swift 6 diagnostics. Native UI verification passed
the complete eight-step wizard, Provider Connect and Check plus protected
contract failure, Autonomy automatic recovery, complete Continuity detail and
title-bar clearance, compact Storage/Managed Activity geometry, and all-primary-
view containment/alignment at minimum and normal widths. The UI runner still
emits its known nonfailing main-thread runtime diagnostic; this is not presented
as a compiler warning. Live loaded-model LM Studio, live Claude/Codex hosts,
installed-build evidence and shipment remain separate. The wiki was published
at `54c714a71f872152f4af6869428c63018cd44a09`; a checksum comparison found no
tracked-file difference between canonical `main` and
`/Users/flynn/Downloads/Forge-Conductor-MacOS-main`, whose clean workspace build
also completed with no warning or error lines.

The earlier September 17 distribution-evidence source is owner-authored revision
`b756b243d24d7dd06098dbbafcdfaa77ab7c97e0`, tree
`6c03f40e2b04ae6dfd689c9347a84014f7ebe496`; its final GitHub workflow passed
native source integrity plus Swift and Xcode Debug/Release lanes. Local and
remote `main` were then synchronized at documentation closeout revision
`f02abeb8c940c8d998f822fd4f1cad5c20c7765e`, tree
`c6475126b54c8ff8de1465940e3ecc3c702a00eb`. That closeout changes
documentation only and leaves that historical native graph unchanged. These
revisions remain distribution evidence for the source they name. They did not
establish the then-current `0.14.4 (10)` source result and do not qualify the
current `0.16.5 (26)` candidate.

| Surface | Recorded checkpoint result | Boundary |
|---|---|---|
| 0.14.1 operability correction | Published source `8ca3f24d9a81adce56e1a5232a6181edd08cf00b`, tree `9bc840d7fdfe47bd552c4b8e095091502fecc3b6`, passed **1,844 tests with 13 explicit skips and zero failures**. Both SwiftPM products and a clean canonical arm64 Apple Development-signed Debug workspace build passed with no warning or error lines. Native UI coverage passed the eight-step Guided Setup, Autonomy recovery, complete Continuity detail/title-bar geometry, Provider Connect and Check plus contract-failure presentation, compact Dashboard Storage/Managed Activity geometry, and every primary view at minimum and normal window sizes. The checkpoint version/build constants and all Xcode configurations were aligned to `0.14.1 (7)`. | One Provider configuration case is an explicit Keychain-environment skip, and the UI runner retains a nonfailing main-thread runtime diagnostic. No fresh live loaded-model LM Studio or live Claude/Codex host result is claimed; installed-build and distribution-artifact evidence remain separate. |
| Historical Swift/Core provider baseline | The `0.14.0 (6)` provider baseline `65af43e31aa2b818ccd2f915aa7f89c34b7c821d`, tree `945cdb9d6adaf17c85845fe846910ece527288fd`, passed both SwiftPM product builds and a direct full-suite terminal run with **1,849 XCTest cases**, **13 explicit environment/live skips, and zero failures**. The warning-repair source `117aa95f982bccb4c1ef0d0acc8b92666127be70`, tree `00344bd6a1ce72f278e1a832a1d6e9f3a27f2d9f`, separately passed both SwiftPM product builds, a fresh canonical Apple Development-signed Debug workspace build, and the focused **3/3** MCP attachment plus **20/20** Provider configuration cases without either reported Swift diagnostic. | The 1,849-case regression remains bound to its exact baseline revision and is not claimed for the current `0.16.5 (26)` candidate. Declared skips remain distinct from passes. Live desktop-host, installed-build, distribution-artifact, and shipment qualification remain separate. |
| Projects and Manager | The published-tree Xcode **My Mac** product registered picker-selected and absolute-path projects, authorized and saved canonical roots, rejected filesystem root, and retained state across relaunch. | That project-registration flow did not qualify the installed protected filesystem service as a distinct process. |
| Provider integrations | The 0.14.0 source implements mutually exclusive LM Studio, Claude Code Desktop, and Codex Desktop selection; transactional Forge-owned desktop package installation, rollback, repair, and removal; a bounded durable operation ledger; revision-bound run admission; authenticated loopback hooks; and selected-provider readiness on Dashboard and Guided Setup. Desktop sessions receive a provider-specific MCP launch command and a five-minute, single-use capability bound to provider, session, run, project generation, selection revision, deployment, and frozen authorization scope. Project tools stay unavailable until `desktop_run_attach` atomically consumes that capability. Deterministic focused coverage passed **100/100**; canonical Xcode passed **83/83 Core**, **40/40 app-hosted**, and **6/6 native UI** cases; the full SwiftPM regression passed **1,849 cases with 13 explicit skips and zero failures**. Grok Build remains visible but non-selectable for owned-artifact cleanup and forward compatibility. | Deterministic tests and an installation receipt do not prove that a selectable desktop host is open, has reloaded the package, has accepted hook trust, or has completed a live session. Claude and Codex require separate live acceptance; neither qualifies the other. Grok's documented startup/prompt hook outputs do not deliver Forge's initial assignment context, so no ready, run, or live-support claim is made for Grok in 0.14.0. The Thread Performance Checker limitation belongs to that historical source; `0.15.0 (14)` repaired the product paths and passed 111/111 app-hosted cases with no structured runtime warnings. |
| LM Studio Provider | The published-tree native UI saved the loopback endpoint and loaded `qwen/qwen3.8-27b` model, refreshed inventory, passed the connection probe, replaced the manager, retained configuration, and passed again. Checkpoint deterministic recovery coverage verifies bounded discovery across system, per-user, Homebrew, and `PATH` CLI locations; wrapped status JSON and string ports; server start; delayed readiness; reported-port fallback; cancellation; and fail-closed malformed, timed-out, or truncated results. | A downloaded or listed model is not treated as loaded; the exact loaded variant remains required. The host had no loaded model during that checkpoint qualification, so the record claims no fresh live contract-probe pass. |
| Revision-3 Provider preparation | Published source `01c874e17c9a26c8f3111981748ed1bd3bdc1f81` passed seven deterministic preparation cases with one explicit live-only skip plus a separately enabled 1/1 live LM Studio `openai/gpt-oss-20b` case. The live operation preserved the pin, verified the contract, wrote the revision-bound readiness receipt, and reused that exact receipt idempotently. Provider configuration passed 14/14 with one explicit disposable-Keychain skip; app provider contracts passed 11/11, operator contracts 10/10, and dashboard security 7/7. | External service start and model load remain typed operator actions when the provider offers no supported authenticated lifecycle API. A focused native UI run timed out while enabling automation before test execution and is a non-pass. |
| Revision-3 runtime readiness | Published source `01c874e17c9a26c8f3111981748ed1bd3bdc1f81` passed focused checks proving an unavailable optional Python runtime does not disable the shell, an explicitly required Python runtime produces exactly one recovery action, nil-path legacy state remains `unknown`, and application-wide shell denial is reported at its true policy scope. Both SwiftPM products, the signed canonical Debug app build, and the universal Xcode Core test target build passed with the new resolver and test in their canonical targets. | Runtime necessity is derived only from explicit structured evidence; task prose is intentionally not interpreted as authority. A zero-selected app-test filter was a non-pass and is not test evidence. |
| Managed Autonomy | The checkpoint source exposes selectable built-in completion checks and preserves additional requirements only from the exact bound instruction package. Package requirements are read-only in the prepared and running task; unknown configuration-owned identifiers are rejected. Durable Manager evidence, retained completion requests, provider wait/resume, and state-derived recovery guidance have focused deterministic coverage. The embedded watchdog, settled-task deletion, pause/bounded-retry/terminal-stop behavior, and custom model instructions remain available. | Completion remains fail closed without exact durable evidence. That checkpoint has deterministic focused evidence; it is not an installed-build claim. |
| Dashboard operability | Published implementation `2319db359f28fba9cf350694ff8f66a7ecc70491` shortens Load Trace and pairs it with bounded status/load cards for headless LM Studio, Autonomy, Continuity, and Rune Forge plus project progress. Directly below, Managed Activity combines the current package, inferred current step, durable delivered count, and run work with bounded operator-redacted assistant/model-error/tool summaries, orchestration events, and exact project/generation policy events. Exact run lookup survives the public recent-100 boundary and returns continuity for that same project/generation/run. Durable storage is capped at 2 KiB per summary and 128 assistant plus 128 tool rows per run; rows are independently content-hashed outside the append-only non-activity audit lineage. Both clients enforce a streamed 4 MiB response ceiling. The view-owned five-second refresh exists only while Dashboard is visible; presentation retains at most 100 app-local rows and caps each displayed activity message at 8 KiB. The retained native UI evidence covers all-primary-view containment/alignment, populated compact equal-height Storage/Managed Activity geometry/content, the Dashboard Guided Setup button, and the populated Rune Forge Policy Feed. | This is a bounded, coalesced latest-state monitor, not token streaming or persisted full-transcript evidence. Rune Forge remains an additive observer and does not control task outcomes. The working installation was not replaced; installed-build qualification remains separate. |
| Continuity | The r3 deterministic crash matrix recovers every managed transition with one accepted successor and one continuation. A source-bound live LM Studio `openai/gpt-oss-20b` run at an observed 65,536-token context triggered on exact provider usage, fenced predecessor tools, survived a post-bootstrap-response manager restart, accepted and consumed one fresh-root successor, performed the successor-only read, then preserved the same receipt/session/turn/tool set across another restart. Retained UI coverage preserves manual actions, exact operation identity, budget, handoff/successor detail, and history while keeping the title/Refresh control below the toolbar and eliminating the unused empty frame. | The live run injects one in-process post-commit crash boundary; the other transitions are covered deterministically rather than by real SIGKILL. At that checkpoint, LM Studio exposed no supported authenticated API for replacing an existing desktop GUI chat; the recorded automatic path used Forge-managed native host mode. Those runs did not qualify the installed build. |
| Resource policy | Focused Debug and final-source, Xcode-compiled signed Release Core stress each passed on the recorded **128 GiB Apple M5 Max** host while also executing the injected **8 GiB constrained policy**. The final Release report refuses to write `passed` after a recorded XCTest failure. | That checkpoint did not record a second physical-memory-capacity execution. |
| Native GUI | The published-tree production-onboarding surface passed all seven cases: five in the class run and the two live LM Studio cases in an exact zero-skip rerun after correcting Xcode environment inheritance. | The initial two explicit skips, earlier runner timeouts, and one retained transient live Provider failure remain nonpasses, not hidden passes. |
| Rune Forge and Stjornarvald | RF-SJ-00 through RF-SJ-10 are implemented. The full SwiftPM rerun passed 1,687 tests with 12 explicit skips; app-hosted Rune Forge/Guided Mode passed 9/9; native UI passed 5/5; prior focused non-interference, fault, restart, privacy, Thread Sanitizer, Xcode membership, signed Debug build, and strict signature evidence remains bound to the RF-SJ checkpoint. All 40 acceptance rows are individually recorded. | Thirty-nine rows are accepted. AC-032 remains limited because automated accessibility semantics and keyboard behavior passed but a human physical VoiceOver listening session was not performed. This is RF-SJ implementation acceptance; it does not qualify the current candidate for Developer ID distribution, notarization, installation, or shipment. |

## Historical 0.9.0 (1) distribution evidence — September 17

This receipt retains the September 17 artifacts and assessment results. It is
separate from the October 3 `0.16.5 (26)` archive/export evidence above.

The exact owner-authored published tree at `f02abeb8`, including the tested
production source and documentation-only closeout, produced a universal
Developer ID Release archive and manual export. The archive has one canonical
`com.forge-conductor.app` product, version `0.9.0` build `1`, both `x86_64` and
`arm64` architectures, the required icon assets, and all four nested products.
Strict deep signing and the Release privileged-bundle checker passed on the
archive, export, ZIP extraction, and expanded Installer payload.

The unshipped source-bound app ZIP is:

- `/private/tmp/forge-published-main-developerid-app-20260917.zip`
- 22,112,426 bytes
- SHA-256 `a171d88409c2ef36816b5ccbc4bb304a3855b5fc7f3972492259adcd143ec338`

The matching Installer was signed through Apple's `productbuild` path with
James Daley's Developer ID Installer identity and a trusted timestamp. Its
expanded payload retained the exact exported signatures and bundle contents.

The unshipped source-bound Installer is:

- `/private/tmp/forge-published-main-signed-installer-20260917.pkg`
- 22,099,582 bytes
- SHA-256 `21a0dc3d68dfbd410408c38cb8e3ce1ee9a395269a30bbeba89d94ab13a16d28`

Neither exact published-tree artifact was notarized at this checkpoint.
Gatekeeper rejected the app and Installer as `source=Unnotarized Developer ID`.
Earlier notarized app receipts belong to their recorded source and do not
replace notarization of these exact artifacts.

## Historical distribution follow-up — September 17

This checklist records the unperformed distribution work for the `0.9.0 (1)`
artifacts above. It does not redefine the current assignment: deliver a buildable
Xcode project that allows the owner to build, sign, notarize, and distribute.
The October 3 checks qualify the corrected project and the isolated candidate
paths in the opening section; the owner retains installation, notarization,
distribution, and final shipping qualification.

1. Install the final candidate under a controlled owner-approved transition,
   then enable and qualify its Developer ID protected filesystem service as a
   distinct process, including successful authorized mutation and recovery
   behavior. At that checkpoint, System Settings readback showed Forge background
   activity off and Manager reported **Approval required**; read-only hashes
   identified an older daemon in the registered installation.
2. Notarize the exact published-tree archive/app and signed outer Installer,
   staple both artifacts, then pass local Gatekeeper execution and installation
   assessments. Existing Notary credentials are required; none are created by
   this workflow. No local `notarytool` profile/API key or repository Actions
   secret was available for command-line submission at that checkpoint; this
   historical receipt is not a current credential inventory.
3. Record the resource/stress case on another representative physical-memory
   capacity. The injected constrained policy is valuable coverage but is not a
   second physical host. The published revision's macOS CI Release lane passed
   and retained the guarded stress JSON and its host capacity; that hosted
   observation does not replace the physical-host check.
4. Pass public-download acceptance on the notarized artifacts. Shipment remains
   the owner's separate action after qualification.

The owner installation was not replaced at that checkpoint, and neither the
app ZIP nor the Installer was shipped or publicly published by that workflow.

## Setup entry points

Use [the User Guide](../USER-GUIDE.md) for Manager, Projects, Provider, and
Autonomy setup. Use [the Xcode Guide](../XCODE.md) to build or archive the exact
workspace product. LM Studio desktop MCP deployment and Forge-managed Provider
sessions are separate workflows, documented in
[LM Studio connection](LM-STUDIO-CONNECTION.md). Provider selection and desktop
host integration are documented in
[Provider integrations](PROVIDER-INTEGRATIONS.md). Built-in completion evidence
and instruction-package requirement ownership are documented in
[Completion evidence](NATIVE-COMPLETION.md).

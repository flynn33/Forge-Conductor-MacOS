# Functional development build acceptance

This document retains the earlier Apple Development-signed candidate scope and
its exact evidence. On September 15, 2026, the owner changed the active target
to a fully functional, feature-complete, shippable build, authorized direct
GitHub `main` updates under the owner's account, and reserved shipment for the
owner. The Developer ID, notarization, Gatekeeper, physical-hardware, and
privileged root-service gates deferred below are now open for that active
target. See [ROADMAP.md](../ROADMAP.md) and [the delivery workflow](DELIVERY-WORKFLOW.md).

The earlier owner-authorized target was `functional_development_build`: a usable,
fully functional native macOS application built in optimized Release
configuration and signed with the available legitimate Apple Development
identity. This scope changes delivery qualification, not required product
features.

## Historical development acceptance scope

| Gate | Functional development build requirement |
|---|---|
| SG01 — Source and delivery identity | Record the exact completion-branch source, remote branch and PR head. After an authorized merge, synchronize local and remote `main` and record the merge receipt. A usable pre-merge candidate keeps its branch source identity. |
| SG02 — Native build and version identity | Build the canonical `ForgeConductor.xcworkspace` Release app, CLI/manager, framework, launcher and filesystem helper coherently with the documented Apple Development team, identity and `FORGE_DEVELOPMENT_SIGNING` policy. Verify version/build and bundle membership. |
| SG03 — Installed native workflows | Exercise the development-signed application in an available compatible macOS environment without replacing the owner's working installation unless separately authorized. |
| SG04 — Project data and reset | Preserve immutable confirmation identity, matching receipts, required clearing modes, recovery and unrelated project/settings data. |
| SG05 — Autonomous managed continuity | Preserve real context-pressure handoff, exact restore/acknowledgment/sealing, ordinary work, output consumption and recovery requirements. Deterministic fixtures remain accurately labeled. |
| SG06 — Integration and authority scope | Preserve task-scoped writable work and authenticated host-mode boundaries. Do not promote API-only evidence to an existing-desktop result. |
| SG07 — Production filesystem and recovery | Preserve the required production helper operations, containment, recovery and truthful receipts. |
| SG08 — Regression and lifecycle quality | Use compatible macOS execution, CI, automated native tests and accurately labeled simulated resource/provider conditions. The broader physical-hardware/RAM-tier matrix is owner-deferred and non-blocking for this delivery. |
| SG09 — Development artifact | Deliver the coherent development-signed `.app` package, hashes, source revision, version/build, symbols where produced and practical launch/install instructions. Developer ID signing, notarization, stapling and public-download acceptance are owner-deferred and non-blocking. |
| SG10 — Documentation, roadmap and attribution | Keep current documentation, roadmap, identity, evidence limits and contribution policy accurate. |

The original public-distribution release validator and records remain historical
and valid for their original scope. Do not falsify their Developer ID or
notarization fields for this development artifact, and do not treat their
expected rejection of a development-signed package as a product failure. No new
validation framework is introduced by this scoped contract.

## Authority retained by the owner for that historical scope

At the time, protected merges, public publication, new credential creation and
replacement of the working installation required separate authorization.
Development could continue across independent completion phases while one of
those actions or CI was pending. Branch, PR, merge and artifact states were
kept distinct. The current owner direction instead uses direct GitHub `main`
updates with no pull requests; shipment remains reserved for the owner.

Git commit signing is separate from application code signing. Subsequent pushed
commits require an existing authorized SSH or GPG signing setup; published
history must not be rewritten to retrofit signatures.

When all functional gates above pass, the handoff label is:

> FUNCTIONAL DEVELOPMENT BUILD READY — development signed; public notarization
> and physical-hardware matrix owner-deferred.

## September 14, 2026 candidate record

- The development candidate was built from merged `main` commit
  `d05e56a1d517dbfbcd971105cf2917cb1f186f34` plus the completion-branch
  worktree patch identified in the external artifact manifest. Those source
  inputs were committed as owner-signed tested source `c417887d5f388cefcb58d01d46ef63134ebe8f6f`
  and pushed in [PR #48](https://github.com/flynn33/Forge-Conductor-MacOS/pull/48).
  The documentation-only link follow-up does not replace that tested-source
  identity or constitute owner merge acceptance.
- The complete Swift package suite executed 1,578 tests with 11 explicit
  environment/fixture skips and zero failures.
- A September 15 publication readback of the same source inputs passed the
  workspace Debug build and 1,578 Swift tests with 12 explicit skips and zero
  failures; five project-clearing and seven H0 isolation tests also passed.
- The canonical workspace produced one optimized arm64 Release app. The app,
  Core framework, manager/CLI, runtime launcher and filesystem daemon passed the
  `DevelopmentRelease` checker and strict Apple Development signature validation
  for team `9AQ2C2838M`.
- The exact embedded CLI passed `version`, `status` and `doctor` against a fresh
  isolated Forge home. The exact GUI executable remained live during a bounded
  isolated launch and was then terminated without replacing the owner install.
- One production-adapter LM Studio rollover completed end to end. The deterministic
  suite covers two sequential rollovers; a second live attempt exceeded the
  provider deadline and later returned a conflict, so it is not a second pass.
- Privileged root-service E2 and native display-link execution are unmeasured on
  this host. Developer ID signing, notarization, stapling, public-download
  acceptance and the broader physical-hardware matrix are owner-deferred.

## September 15, 2026 operator-onboarding candidate

- Completion branch `fix/native-operator-onboarding` starts at synchronized
  `main` source `c55509a60d6694ba460b9dbbf92f0ce6f899f0f1`; its tested
  patch repairs native picker registration and first-run Provider/Autonomy
  guidance. The current Xcode source/test membership is unchanged.
- The picker and direct-path native registration UI tests each passed against
  a fresh isolated home and relaunch. Offline Provider durability/error and
  live loopback LM Studio model discovery/connection/relaunch tests each passed,
  along with two focused Autonomy start-state tests. The live owner manager
  accepted and then cancelled one bounded read-only managed run; cancellation
  is not a mission-completion claim.
- The canonical workspace built an optimized arm64 `0.9.0 (1)` app with Apple
  Development team `9AQ2C2838M` and the matching
  `FORGE_DEVELOPMENT_SIGNING` policy. Strict `DevelopmentRelease` inspection
  verified the app, embedded CLI, Core framework, runtime launcher and
  filesystem daemon. A bounded isolated launch reached the ordinary manager
  status route and closed its listener on GUI shutdown. The working
  installation was not replaced.
- The first native UI attempt hit the already registered privileged daemon's
  host launch constraint and is retained as a non-pass. Later focused native
  UI tests ran and passed on the same host. Production root-service execution
  and mission completion remain distinct qualification gates.

## September 15, 2026 onboarding archive receipt

- The selected product inputs were reviewed in the now-closed [PR #50](https://github.com/flynn33/Forge-Conductor-MacOS/pull/50). The tested product source is `7fb299945c5bfc9ae50340ceb078acee94ff4a32`; later branch commits changed documentation only. The archive at `/Users/flynn/Downloads/Forge-Conductor-Onboarding-0.9.0-dev.zip` contains the optimized arm64 Apple Development-signed `0.9.0 (1)` app. Its SHA-256 is `6168306b8905c491c0f26dac7acec3e7f2615397679f18fae7f27a4da36c9af8`; the local `/Users/flynn/Downloads/Forge-Conductor-Onboarding-0.9.0-dev-manifest.json` records the review source and validation. No `.dSYM` product was emitted in this Release build's product directory.
- The archive extracted with `ditto`. The extracted app and nested CLI, Core framework, runtime launcher and filesystem daemon passed the `DevelopmentRelease` signature/bundle checker. A fresh isolated Forge home and unused loopback port then launched the exact extracted GUI/Manager, returned version `0.9.0` from `/api/manager/status`, and closed the listener after GUI shutdown. The owner installation was not replaced.
- To rebuild, open `ForgeConductor.xcworkspace` and use the explicit Apple Development Release invocation in [XCODE.md](../XCODE.md). To inspect the archived candidate separately, extract it into a new directory with `ditto -x -k`. For a live evaluation alongside the existing installation, use a fresh `FORGE_CONDUCTOR_HOME` and configure that home's `config.json` dashboard host `127.0.0.1` on an unused port before launching the extracted app executable. The smoke test used the canonical schema-v2 configuration with a distinct port. Launch with `env FORGE_CONDUCTOR_HOME=/path/to/fresh-home "/path/to/extracted/Forge Conductor.app/Contents/MacOS/Forge Conductor"` after writing that isolated configuration; do not reuse the working `~/.forge-conductor` home for this test.
- PR #50's native source integrity, Swift Debug/Release, Xcode Debug/Release,
  and attribution checks passed at review head `e8aeca49d6d394047b74c05a9536fa4fce031ec1`.
  A documentation-only follow-up does not change the tested build inputs.
- **E0 — installed privileged-service failure:** the running 0.9.0 app reported
  its filesystem daemon registered but not responding. `launchctl` and unified
  logs repeatedly showed launchd failing to resolve
  `Contents/MacOS/forge-filesystem-daemon`; the Developer ID-signed binary
  existed and passed strict bundle verification. An unused 0.8.1 app with the
  same bundle identifier was moved reversibly to
  `/Users/flynn/Downloads/Forge Conductor 0.8.1 Archived.app`. The next launch
  resolved the 0.9.0 binary, but macOS then rejected it under a category-3
  launch constraint while the binary was category 6. Forge's supported
  Update/Reinstall action unregistered the service and its immediate register
  returned “Operation not permitted”; its separate Enable action restored the
  prior registered, not-responding state. The manager remained healthy.
  The pre/post launchd records are in
  `/Users/flynn/Downloads/Forge-Daemon-Registration-PreRepair.txt` and
  `/Users/flynn/Downloads/Forge-Daemon-Registration-AfterDuplicateMove.txt`.
- macOS Login Items required Touch ID or the account password to refresh its
  background-item switch. The initial sheet was canceled. After the owner
  supplied Touch ID, the switch was turned off and back on, and its final
  state was verified on. Forge's Update/Reinstall still returned “Operation
  not permitted”; Enable restored registration, but `launchctl` still showed
  a category-3 constraint against the Developer ID binary. No production root
  mutation executed. Apple's
  [ServiceManagement bundle contract](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
  confirms that the plist's relative `BundleProgram` form is correct, so this
  trace does not justify weakening the plist or code-signing requirements.
  SG07 root-service execution remains blocked, and exact existing-desktop
  attachment remains open. Developer ID public distribution, notarization and
  the broader physical-hardware matrix remain owner-deferred. The functional
  handoff label is not asserted while SG07 is unresolved.

## September 15, 2026 merged PR #51 archive receipt

- [PR #51](https://github.com/flynn33/Forge-Conductor-MacOS/pull/51) merged as
  `bea6b5a5ab6cbc387207f7830805fe82288f13cf`; local `main` was safely
  fast-forwarded and verified equal to `origin/main`. Its eight onboarding
  product/document files matched the locally combined tree byte for byte at
  review head `bd9c22c41b2f08df0d20cf9209ba8d00d0b00fde`. The canonical
  workspace already includes every affected Swift source and selected UI test;
  PR #51 did not change its source, resource, or test graph.
- The combined tree passed both direct SwiftPM product builds, the workspace
  Debug build, three focused signing/project tests, and one selected native
  direct-path registration UI test. Its xcresult reports one passed, zero
  skipped, and zero failed. An optimized arm64 Apple Development Release build
  completed with the compiled `FORGE_DEVELOPMENT_SIGNING` policy. Strict deep
  code-signing validation and `DevelopmentRelease` inspection passed for the
  app and all nested products. The app reports `0.9.0 (1)`; no `.dSYM` appeared
  in the Release product directory.
- The combined-main archive is
  `/Users/flynn/Downloads/Forge-Conductor-PR51-Onboarding-0.9.0-dev.zip`.
  SHA-256: `a58a7be4e484ca7ec86cc290e6aa3ed817895fc36817b7736f504757c418895f`.
  `ditto` extraction and the same nested-signature checker passed on the exact
  extracted app. Its GUI launched against a fresh isolated Forge home and
  loopback port; `/api/manager/status` returned the matching home, port, and
  version `0.9.0`. The listener closed after GUI termination. The working
  installation was not replaced. The earlier PR #50 archive remains an exact
  historical source receipt.
- PR #51 merge-head macOS CI was still queued or running when this receipt was
  written. The live root-service E2 matrix and exact external-desktop
  attachment remain open. The installed Developer ID daemon E0 failure above
  remained after the Touch ID-authorized Login Items refresh; this
  development-signed archive is not a production-service pass and does not
  assert the functional handoff label.
- **E0 — host registration constraint:** read-only `launchctl print` still
  reports `needs LWCR update` and a `validation-category` 3 requirement for
  `com.forge-conductor.filesystem-daemon`, while the installed daemon is signed
  as Developer ID category 6 with the exact service identifier and team.
  [Apple's launch-constraint reference](https://developer.apple.com/documentation/security/defining-launch-environment-and-library-constraints)
  maps category 3 to development signing and 6 to Developer ID; an
  [Apple ServiceManagement example](https://developer.apple.com/forums/thread/802443)
  describes `SMAppServiceErrorDomain` code 1 as a missing daemon approval. The
  registered background switch was restored to on, yet Forge's supported
  re-registration returned that same denial. This evidence locates the current
  failure in the host's registered requirement and approval transition. It
  does not prove that a clean installation would pass, and it does not justify
  weakening the daemon signature, trust policy, or launch plist.

## September 15, 2026 current-source completion qualification

The current source passed both direct SwiftPM product builds, the canonical
workspace Debug build, and the full macOS 27/Xcode 27 Swift suite: 1,553 tests,
12 explicit skips, zero failures. An isolated arm64 Apple Development-signed
Release candidate passed strict nested-bundle inspection and a bounded GUI and
manager launch without replacing the installed app. A disposable read-only run
against the loaded LM Studio `qwen/qwen3.8-27b` model first proved the missing
owner-policy denial. A second run with a private policy and preflighted signed
XCTest package reached `completed` revision 10 after one exact native case
passed with no skip, failure, timeout, or truncated output; `tests` remained
passed after manager restart. See [native completion](NATIVE-COMPLETION.md) for
the policy, result path, and scope. The scratch manager was stopped and its
disposable control credential removed; the native result was retained.

Focused current-source signed GUI checks executed one exact native case each:
project registration by folder picker passed; live LM Studio Provider save,
model discovery, connection, and relaunch passed after the runner received its
explicit test-plan environment. The first selected Provider case skipped when
shell variables were not forwarded and is not counted. Manager folder
authorization initially crashed during a macOS accessibility query after the
panel closed. The same failure reproduced in its narrower test. Removing a
redundant explicit label from the authorized-path text preserved the path and
identifier while the identical authorization/cancel/invalid-root/save/relaunch
test passed. A combined authorized-project/live-Provider/Autonomy start test
then passed and verified the manager's exact persisted read-only assignment.
The first broader signed production-onboarding class executed seven cases:
six passed, none skipped, and the combined case failed after its saved Provider
probe reported `unreachable`, before Autonomy run start. That result remains a
non-pass at `/private/tmp/forge-current-full-onboarding-ui.xcresult`. The
same class rebuilt with retained probe controls and manager state passed all
seven native cases with no skips or failures at
`/private/tmp/forge-current-full-onboarding-ui-diagnostics.xcresult`.
Two further exact combined-case repeats passed at
`/private/tmp/forge-current-autonomy-probe-repeat-{1,2}.xcresult`. The
original failure lacks the provider's full error detail, so current source
records it as intermittent E0 rather than changing the production probe
without a same-flow diagnosis. The added UI diagnostics preserve that detail
if the result recurs.
The new operator policy importer separately passed a focused Core test: wrong
run binding and changed package bytes left the protected policy absent, and an
exact prepared policy was installed byte-for-byte at mode `0600`. The existing
native-gate fixture now imports its policy through that service and executes
three signed XCTest jobs for incorrect, stale, and corrected effects; one focused
case passed with no skip or failure. A Developer ID Release native UI test
registered an authorized project, reached the loaded LM Studio Provider,
started a read-only run, opened the policy picker, canceled it, and verified the
control re-enabled with the run retained. The final selected case passed once
with no skips or failures at
`/private/tmp/forge-policy-import-native-release-final.xcresult`. An extended
Release case then selected a run-bound manifest fixture through NSOpenPanel
and read back byte-identical protected content at mode `0600`: one selected
case, zero skips/failures at
`/private/tmp/forge-policy-import-native-positive-20260915.xcresult`. The
fixture is not a signed executable package and the GUI run did not finish.
Package-preparation UX, ordinary
installed-stack terminal completion, root-service E2, and distribution gates
remain open.
After the native UI repair, a fresh isolated arm64 Apple Development-signed
Release workspace build passed the `DevelopmentRelease` nested-bundle checker.
Its embedded CLI returned `0.9.0` for `version` and a clean stopped-manager
status from a separate scratch home. The local, unshipped candidate is
`/private/tmp/forge-current-source-ui-devrelease-candidate.zip` (13,484,337
bytes; SHA-256
`56cb77e5802843dbb55b51da4c38d2b532685f6789358e0db18baa48c7d27c10`);
the ZIP passed full integrity testing. Its exact source is the current
uncommitted local `main` patch over `808efaae06dc616aa8dbb29765433e7b8ae227e2`.
The GUI bundle was not launched or installed, avoiding another same-identifier
Background Items registration. After a direct `main` update, rebuild from the
published source and record a new revision-bound archive receipt.

This isolated candidate remains a development-signing artifact. After the owner
installed valid team `9AQ2C2838M` Developer ID identities on this host, the
ordinary current patch-bound source produced a universal Release archive, a
manual `developer-id` export, and a locally signed installer. The exported app
and package passed strict signature, bundle, and payload checks; Gatekeeper
rejected both as unnotarized. The unshipped local app ZIP is
`/private/tmp/forge-current-source-developerid-app-20260915.zip` (SHA-256
`5a23be1a0937b9af643ee20b159b8a4fc6be8e47afaaeda75eb86167a8aab85d`),
and the signed installer is
`/private/tmp/forge-current-source-developerid-20260915.pkg` (SHA-256
`5b7296ef3bdeaaf8565e8784287861d82eb40767363dc0c2365f635b2c3855f0`).
Xcode Organizer subsequently notarized that exact archive through Direct
Distribution. The locally exported app is stapled; `stapler validate`, strict
nested signatures, the `Release` bundle checker, and Gatekeeper execution
assessment pass. The notarized app ZIP at
`/private/tmp/forge-current-source-notarized-app-20260915.zip` has SHA-256
`a309b3a138d5ee986a0791bb425ffd736b6ea295e6d80f4fda541289e0489d2b`.
After extraction, its stapled ticket, bundle checker, and Gatekeeper assessment
again passed. The separately signed installer package is still unnotarized and
Gatekeeper rejects installation. Neither artifact was installed or shipped.
A bounded direct launch from the extracted notarized ZIP served a fresh Forge
home on port 7790. Its native Manager Start control reported success, the
folder picker and Save settings authorized only the disposable
`/tmp/forge-current-notarized-demo-project`, and the Projects picker committed
that project with identity `2d58ea78-32f0-0943-0e3a-61ed7985a3cb` and
generation 1. The computer-use transport closed during the click; the app
process/listener stayed healthy, and the manager operator snapshot confirmed
the commit. The candidate was stopped, the listener closed, and its launched
`.app` path renamed to a retained non-app bundle. The working installed app
files remained signed and were not replaced. Provider setup and Autonomy run
start were not repeated from this candidate; the signed native seven-case
onboarding suite remains the relevant current-source evidence.
At that earlier candidate checkpoint, GUI policy enrollment, installed
root-service E2, installer qualification, public-download acceptance, and
physical-hardware qualification remained open. The policy-import UI and the
newer packaged completion path are recorded below. Rebuild from exact
published `main` after publication.

## September 16, 2026 packaged native completion receipt

The local policy-import source produced a new universal Developer ID archive at
`/private/tmp/forge-policy-import-developerid-20260915.xcarchive` and a manual
export. Strict all-architecture nested code-signing and the `Release`
privileged-bundle checker passed. Xcode Organizer Direct Distribution notarized
this archive as submission `F591014A-45A3-4BB2-AA3F-25A26CEB0932`; its exported
app was stapled, and both the export and ZIP extraction passed `stapler validate`,
the checker, and local Gatekeeper execution as `Notarized Developer ID`. The
unshipped ZIP is `/private/tmp/forge-policy-import-notarized-app-20260915.zip`
(22,088,388 bytes; SHA-256
`9d99e311b8471b2de46d1043cb2dbe03c1486f105fd9a1c4a9df720cdec3c4ed`).
This archive predates only the Xcode UI-test target's Core-framework link and
later test/documentation edits; the production app/Core files are unchanged.
The final current-local-workspace universal Developer ID archive at
`/private/tmp/forge-final-local-developerid-20260916.xcarchive` then passed the
ordinary Release archive, strict all-architecture nested-signature check, and
privileged-bundle checker with the updated Xcode test-target graph. Its manual
`developer-id` export at
`/private/tmp/forge-final-local-developerid-export-20260916/Forge Conductor.app`
has identical code-directory hashes to the notarized app above for the app,
Core framework, embedded CLI, runtime launcher, and filesystem daemon. Apple's
existing ticket stapled successfully to this exact-code export. The final
unshipped local ZIP is
`/private/tmp/forge-final-local-notarized-app-20260916.zip` (22,088,716 bytes;
SHA-256 `f77f63c19807be2522d245c9a6e827d0713c99a04cf76d6f14baaaaebe470b19`).
ZIP integrity, extracted-bundle stapler validation, strict nested signing,
Release privileged-bundle checks, and local Gatekeeper execution assessment
(`source=Notarized Developer ID`) all passed. Its unsigned installer payload
expanded and passed the same app checks. The final component package was
wrapped and signed through Apple's `productbuild --package --sign` path at
`/private/tmp/forge-final-local-productbuild-signed-installer-20260916.pkg`
(SHA-256 `1cfc438cf5e2b5d9dda8fafcb019c905abad1b0289f48c5f9f233796c3f03f79`).
`pkgutil --check-signature` reported the valid Developer ID Installer chain and
trusted timestamp. Its expanded app payload retained valid strict nested
signatures, the app's staple ticket, and `source=Notarized Developer ID` app
Gatekeeper acceptance. The outer installer remains unnotarized:
`spctl --type install` rejected it as `source=Unnotarized Developer ID`.

**E0 signing diagnosis:** a second bounded `productsign --timestamp=none`
attempt reached the same 4.2 KiB partial package and waited inside
`SecKeyCreateSignature` → `SecurityServer::generateSignature` → `mach_msg` in a
three-second process sample. Disabling the trusted timestamp did not remove
the wait. Read-only Keychain Access inspection found the Installer private
key's Confirm-before-allowing policy already permits Xcode, `codesign`, and
`productbuild`, but not `productsign`. No key ACL was changed. Both terminated
`productsign` partial outputs were renamed `.pkg.partial-not-signed` and are not
distribution artifacts. A no-timestamp signature would not qualify the final
installer in any case; the allowed `productbuild` path supplied a trusted one.

**E0 resource-tier limit:** the focused deterministic stress test executed on
this 128 GiB Apple M5 Max/macOS 27 host with the high-capacity policy and an
injected 8 GiB constrained policy. It passed one Debug XCTest case and wrote
`/private/tmp/forge-final-hardware-stress-debug-20260916.json`; the test report's
previous hard-coded `release` label was corrected to the actual compilation
configuration. An optimized SwiftPM Release repeat compiled but failed before
the workload because its linker-signed test bundle was invalid on disk
(`SecStaticCodeCheckValidity` status `-67056`); the adjacent runtime launcher
itself verified. The canonical workspace compiled the exact selected Core test
in Release, but the full scheme stalled while signing its unrelated UI test
bundle. Its already-built optimized Core test bundle was then signed locally
with the host's existing Apple Development identity, without changing the
Developer ID runtime launcher or any product trust rule. `codesign --verify
--strict --all-architectures` passed for that test bundle and launcher;
direct `xcrun xctest -XCTest
ReleaseStressTests/testDeterministicReleaseStressAndResourceBudgets` executed
the same case with one pass, zero failures/skips and exit 0. A subsequent
target-only Xcode Release rebuild compiled the final source, including a guard
that refuses to write a `passed` report after a recorded XCTest failure. The
re-signed optimized test bundle passed strict nested validation; the selected
case again passed once with zero failures/skips, exit 0, and no truncated output
in 5.052 seconds. Its final Release report is
`/private/tmp/forge-final-hardware-xcode-release-guarded-20260916.json`
(SHA-256 `4430cfbe48a37517841daa74d92d7a45fb2a090d526e6c400c43ef5eccc4bc04`).
It records 100 manager restarts, 100 project cycles, 500 memory records, 100
MCP requests, 25 process cycles, 50 rollovers, a 158,564,352-byte resident
peak, flat five-sample post-release RSS, at most two telemetry delivery slots,
zero post-shutdown coordinator owners, and p99 under the asserted 2-second
latency ceilings. This host and an injected lower-tier policy still do not
prove execution on a second physical-memory capacity.
The existing macOS CI Release Swift lane retains the same guarded JSON report
plus architecture, hardware-model, physical-memory, OS, and Xcode inventory.
The final workflow for published revision
`b756b243d24d7dd06098dbbafcdfaa77ab7c97e0` completed successfully in all five
lanes: native source integrity, Swift Debug, Swift Release, Xcode Debug, and
Xcode Release. A hosted-runner observation does not replace the remaining
second physical-host qualification.

A direct bounded launch of that extracted ZIP used a fresh Forge home on port
7792. Manager's native folder panel and Save settings authorized only
`/tmp/forge-policy-import-packaged-live-project-20260915`; the Projects
absolute-path sheet committed its identity
`75f477bd-1009-b855-5de4-5f46cb811c5d` at generation 1. The computer-use
pipe closed during the registration click, but the manager snapshot showed the
committed project while the app and listener remained healthy. The same
packaged manager saved `qwen/qwen3.8-27b` on LM Studio's loopback server and its
live native-host contract probe returned `contract_valid`, tool capability, and
the loaded 262144-token instance. A separately prepared signed arm64 XCTest
package and schema-1 policy were imported into this isolated protected home
with exact run/project/generation/source/package binding. The manager admitted
read-only run `6e895323-f3d3-401c-be8d-002c7f11a297`, created a real native
model session, consumed `fs_read`, accepted its completion request, and reached
`completed` at revision 8 with `tests` passed. The retained child result at
`/private/tmp/forge-policy-import-packaged-live-home-20260915/native-validation/results/6e895323-f3d3-401c-be8d-002c7f11a297/tests/fd53053a-40e2-4d58-8e36-9bd2e0d976c3/result.xcresult`
has one exact `ProcessRunnerTests/testNativeGateEffectFixture()` pass, zero
failures/skips, exit 0, and no timeout/output truncation. After a full app and
manager process restart, the new PID returned the same terminal run revision
and passed gate. The candidate was stopped again, port 7792 closed, and its
launched duplicate app path retained as a non-app bundle. The owner installation
stayed running and unchanged. The installed signed root service, package
notarization, public-download acceptance, hardware matrix, and published-source
rebuild remain open. Three later attempts to run the signed-package combined
XCUI test stopped before executing a selected case because macOS `testmanagerd`
did not grant automation mode within 60 seconds; those are retained as
non-passes, not product-result passes.

A September 16 read-only System Settings check showed **Forge Conductor
Autonomous** Background App Activity **off** while the installed Manager
reported **Approval required**. The existing system daemon registration also
retains development-signing validation category `3`; the packaged Developer
ID daemon is category `6`. Enabling the owner installation's background
activity and safely re-registering its daemon are separate OS transitions.
No distinct-process root-service pass is inferred from the notarized candidate
or an app-local status read. This observation did not change the installation.
The current read-only comparison also confirms that the registered installation
is not the final candidate: its daemon SHA-256 is
`5d0b6e715bb71a96fb692715948f062f46d622bd2e829791a48478468513e73b`, while
the final Developer ID export's daemon SHA-256 is
`7036c62dc866d39369ca646a4a6972c6432f29eccaf3f7ee23fb4c88c5e8b6c4`.
Both use the exact service identifier and team and pass strict signature
validation, but `launchctl` reports 2,599 failed launches, exit 78, and
`needs LWCR update` for the existing registration. Turning on the existing
background item alone would exercise the older installed daemon. Final-source
root qualification therefore requires a controlled candidate installation and
ServiceManagement registration; the working owner installation remains
unchanged until that separately authorized transition.

The final local source also completed the direct `swift test` suite on this
host on September 16: the XCTest `All tests` terminal summary executed
**1,554 tests**, with **12 explicit skips** and **zero failures** in 298.717
seconds. The successful process exit and full transcript are retained at
`/private/tmp/forge-final-local-swift-test-20260916.log`. The later Swift
Testing runner lines selected zero tests in their separate libraries; they do
not replace or inflate the executed XCTest result. This suite validates the
current local source and focused package/policy regressions, not the signed
root service, installer, public download, or an exact published revision.

## September 17, 2026 published-main Xcode My Mac receipt

The owner published the repaired source directly to `main`. Local `HEAD` and
`origin/main` read back as
`b756b243d24d7dd06098dbbafcdfaa77ab7c97e0`, with exact tree
`6c03f40e2b04ae6dfd689c9347a84014f7ebe496` and no worktree difference. The
source/test/resource graph is unchanged: every affected Swift file was already
in its canonical target and this closeout changes documentation only.

The canonical workspace then built and ran its native production-onboarding
tests on the **My Mac** arm64 destination. The isolated Debug app has identifier
`com.forge-conductor.app`, Apple Development authority James Daley, team
`9AQ2C2838M`, hardened runtime, and passes strict deep code-signature
verification. The first result bundle at
`/private/tmp/forge-published-main-ui-20260917.xcresult` executed seven cases:
five passed and the two live LM Studio cases skipped because Xcode did not
inherit shell-only provider variables. Those skips are retained as a non-pass.

The loopback endpoint and already loaded `qwen/qwen3.8-27b` model were then
supplied through the user launch environment, the inheritance boundary used by
the Xcode UI runner. The exact two previously skipped cases executed in
`/private/tmp/forge-published-main-live-ui-20260917.xcresult` with two passes,
zero failures, and zero skips. The live Provider case saved configuration,
reconciled the selected model as loaded, refreshed native inventory, passed the
connection probe, replaced the manager process, retained configuration, and
passed the probe again. The live Autonomy case authorized and registered an
isolated project, passed the same Provider probe, admitted the exact read-only
run, retained its project/generation/model/gate assignment, canceled and
reopened the policy picker, and imported the run-bound manifest at mode `0600`.
The other five cases verified folder and direct-path registration, relaunch
persistence, invalid-root rejection, offline and invalid Provider handling,
and shell opt-out/re-enable in fresh MCP processes. The temporary launch
variables were removed afterward. No candidate was installed and the owner
installation was not changed.

This receipt binds the repaired onboarding and managed-run admission paths to
published source. It is development-signed native execution, not a rebuilt
Developer ID distribution artifact. Distinct-process root-service execution,
installer notarization, public-download acceptance, a second physical-memory
capacity, and final published-source archive attestation remain open.

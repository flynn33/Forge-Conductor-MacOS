# Functional development build acceptance

The current owner-authorized target is `functional_development_build`: a usable,
fully functional native macOS application built in optimized Release
configuration and signed with the available legitimate Apple Development
identity. This scope changes delivery qualification, not required product
features.

## Active acceptance scope

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

## Authority retained by the owner

Protected merges, public publication, new credential creation and replacement
of the working installation require separate authorization. Development may
continue across independent completion phases while one of those actions or CI
is pending. Branch, PR, merge and artifact states must remain distinct.

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

- The selected product inputs are reviewed in [PR #50](https://github.com/flynn33/Forge-Conductor-MacOS/pull/50). The tested product source is `7fb299945c5bfc9ae50340ceb078acee94ff4a32`; later branch commits changed documentation only. The archive at `/Users/flynn/Downloads/Forge-Conductor-Onboarding-0.9.0-dev.zip` contains the optimized arm64 Apple Development-signed `0.9.0 (1)` app. Its SHA-256 is `6168306b8905c491c0f26dac7acec3e7f2615397679f18fae7f27a4da36c9af8`; the local `/Users/flynn/Downloads/Forge-Conductor-Onboarding-0.9.0-dev-manifest.json` records the review source and validation. No `.dSYM` product was emitted in this Release build's product directory.
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

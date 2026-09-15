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

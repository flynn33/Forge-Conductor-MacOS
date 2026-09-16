# Version and qualification status

Product identity: **0.9.0, build 1**, supporting **macOS 26+**. The owner is
preparing a shippable build and will perform shipment separately. This page is
a concise status index; the detailed, source-bound receipts are in the
[functional-build record](FUNCTIONAL-DEVELOPMENT-BUILD.md) and
[roadmap](../ROADMAP.md).

## Version and build agreement

The Swift runtime, CLI, Xcode Debug and Release configurations, built app, and
current documentation use version **0.9.0, build 1**. The canonical values are
[`ForgeFilesystemProtocolConstants.productVersion` and `productBuildVersion`](../Sources/ForgeFilesystemProtocol/ForgeFilesystemProtocol.swift).
Filesystem protocol, provider-plugin, and database schema versions are separate
compatibility contracts.

The canonical native project is `ForgeConductor.xcworkspace`, using the
`ForgeConductor` scheme. Its archive contains one installable app product with
the Core framework, manager CLI, runtime launcher, filesystem daemon, resources,
and icon. A standalone SwiftPM CLI is not a substitute for that signed bundle.

## Current source and functional evidence

The current local candidate starts from published `main`
`808efaae06dc616aa8dbb29765433e7b8ae227e2` plus the exact modified files listed
by the current worktree. Direct owner publication and remote readback remain
pending, so no later commit identifier is claimed yet.

| Surface | Current result | Boundary |
|---|---|---|
| Swift/Core suite | The final direct `swift test` terminal run executed **1,554 XCTest cases**, with **12 explicit skips and zero failures**. | Declared skips remain distinct from passes; the transcript is identified in the functional-build record. |
| Projects and Manager | Signed native flows registered a picker-selected project and an absolute-path project, authorized and saved its canonical root, survived relaunch, and exercised Manager start/stop behavior. | The installed protected filesystem service still requires distinct-process qualification. |
| LM Studio Provider | The packaged candidate saved the loopback endpoint and loaded `qwen/qwen3.8-27b` model, refreshed inventory, and passed the tool-capability contract probe. Offline save/error and relaunch durability also passed native tests. | A downloaded or listed model is not treated as loaded; the exact loaded variant remains required. |
| Managed Autonomy | A packaged isolated-home run used LM Studio, consumed a real `fs_read` tool call, recognized a trailing structured completion request, executed one required signed native XCTest case, reached `completed`, and retained the passed `tests` gate after app/manager restart. | Completion remains fail closed without an exact owner-installed native-validation policy and approved signed package. |
| Native policy import | Core and Developer ID Release UI evidence covers run/project/gate/source/package binding, picker cancellation, exact import, mode `0600`, changed-package rejection, and protected readback. | The app does not silently approve model text or a hand-edited result as native evidence. |
| Continuity | Deterministic recovery and repeated rollover coverage passes; one live real-provider threshold rollover created, acknowledged, and consumed the successor before sealing the predecessor. | LM Studio does not expose a supported authenticated API for attaching to or replacing an existing desktop GUI chat. Forge-managed native host mode is the supported automatic rollover path. |
| Resource policy | Focused Debug and final-source, Xcode-compiled signed Release Core stress each passed on this **128 GiB Apple M5 Max** host while also executing the injected **8 GiB constrained policy**. The final Release report refuses to write `passed` after a recorded XCTest failure. | A second physical-memory-capacity execution is not yet recorded. |
| Native GUI | The signed production-onboarding class passed seven cases; focused Provider-to-Autonomy repeats, policy-picker behavior, and the authorization crash regression also passed. | Earlier runner timeouts and the one retained transient live Provider failure remain nonpasses, not hidden passes. |

## Current distribution evidence

The final local universal Developer ID archive and export contain the current
production code. Xcode Organizer notarized the matching production code, and
the final exported app retained those exact code-directory hashes. The stapled
app passed strict nested signing, the Release bundle checker, ZIP integrity,
stapler validation, and local Gatekeeper execution before and after extraction.

The unshipped app ZIP is:

- `/private/tmp/forge-final-local-notarized-app-20260916.zip`
- 22,088,716 bytes
- SHA-256 `f77f63c19807be2522d245c9a6e827d0713c99a04cf76d6f14baaaaebe470b19`

The matching local Installer was signed through Apple's `productbuild` path
with the team's Developer ID Installer identity and a trusted timestamp. Its
expanded app payload retains the notarized app ticket and passes strict nested
signing and app Gatekeeper checks.

The unshipped signed Installer is:

- `/private/tmp/forge-final-local-productbuild-signed-installer-20260916.pkg`
- SHA-256 `1cfc438cf5e2b5d9dda8fafcb019c905abad1b0289f48c5f9f233796c3f03f79`

The **outer Installer package is not notarized**. Gatekeeper correctly rejects
its installation as `source=Unnotarized Developer ID`. This package is retained
as local evidence and is not a shippable installer yet.

## Remaining gates

The following results are still required before declaring the owner target
complete:

1. Publish the exact current worktree to owner `main`, read it back, and bind a
   fresh source revision to the final build receipt.
2. Install the final candidate under a controlled owner-approved transition,
   then enable and qualify its Developer ID protected filesystem service as a
   distinct process, including successful authorized mutation and recovery
   behavior. The current System Settings readback shows Forge background
   activity off and Manager reports **Approval required**; read-only hashes
   prove that registered installation contains an older daemon.
3. Notarize and staple the signed outer Installer, then pass local Gatekeeper's
   install assessment. Existing Notary credentials are required; none are
   created by this workflow. No local `notarytool` profile/API key or repository
   Actions secret is currently available for that submission.
4. Record the resource/stress case on another representative physical-memory
   capacity. The injected constrained policy is valuable coverage but is not a
   second physical host. The existing macOS CI Release lane is configured to
   retain the guarded stress JSON and its host capacity after publication; that
   future run is not yet evidence and does not replace the physical-host gate.
5. Rebuild or attest the final artifact from the exact published revision.
   Public download and shipment remain owner actions after qualification.

The owner installation has not been replaced, and neither the app ZIP nor the
Installer has been shipped or publicly published.

## Setup entry points

Use [the User Guide](../USER-GUIDE.md) for Manager, Projects, Provider, and
Autonomy setup. Use [the Xcode Guide](../XCODE.md) to build or archive the exact
workspace product. LM Studio desktop MCP deployment and Forge-managed Provider
sessions are separate workflows, documented in
[LM Studio connection](LM-STUDIO-CONNECTION.md). Native completion policy and
its trusted execution boundary are documented in
[Native completion](NATIVE-COMPLETION.md).

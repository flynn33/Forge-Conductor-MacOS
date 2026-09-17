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

The current local source and owner-authored remote `main` are synchronized at
`b756b243d24d7dd06098dbbafcdfaa77ab7c97e0`, tree
`6c03f40e2b04ae6dfd689c9347a84014f7ebe496`. The final GitHub workflow passed
native source integrity plus Swift and Xcode Debug/Release lanes.

| Surface | Current result | Boundary |
|---|---|---|
| Swift/Core suite | The final direct `swift test` terminal run executed **1,554 XCTest cases**, with **12 explicit skips and zero failures**. | Declared skips remain distinct from passes; the transcript is identified in the functional-build record. |
| Projects and Manager | The published-tree Xcode **My Mac** product registered picker-selected and absolute-path projects, authorized and saved canonical roots, rejected filesystem root, and retained state across relaunch. | The installed protected filesystem service still requires distinct-process qualification. |
| LM Studio Provider | The published-tree native UI saved the loopback endpoint and loaded `qwen/qwen3.8-27b` model, refreshed inventory, passed the connection probe, replaced the manager, retained configuration, and passed again. Offline save/error and invalid endpoint handling also passed. | A downloaded or listed model is not treated as loaded; the exact loaded variant remains required. |
| Managed Autonomy | The published-tree native UI authorized and registered an isolated project, connected to LM Studio, admitted the exact read-only assignment, and imported its run-bound policy. A separate current-source live run consumed `fs_read`, retried repaired completion validation without provider/tool replay, executed one signed XCTest case, reached `completed`, and retained `tests`. | Completion remains fail closed without an exact owner-installed native-validation policy and approved signed package. |
| Native policy import | Core and Developer ID Release UI evidence covers run/project/gate/source/package binding, picker cancellation, exact import, mode `0600`, changed-package rejection, and protected readback. | The app does not silently approve model text or a hand-edited result as native evidence. |
| Continuity | Deterministic recovery and repeated rollover coverage passes; one live real-provider threshold rollover created, acknowledged, and consumed the successor before sealing the predecessor. | LM Studio does not expose a supported authenticated API for attaching to or replacing an existing desktop GUI chat. Forge-managed native host mode is the supported automatic rollover path. |
| Resource policy | Focused Debug and final-source, Xcode-compiled signed Release Core stress each passed on this **128 GiB Apple M5 Max** host while also executing the injected **8 GiB constrained policy**. The final Release report refuses to write `passed` after a recorded XCTest failure. | A second physical-memory-capacity execution is not yet recorded. |
| Native GUI | The published-tree production-onboarding surface passed all seven cases: five in the class run and the two live LM Studio cases in an exact zero-skip rerun after correcting Xcode environment inheritance. | The initial two explicit skips, earlier runner timeouts, and one retained transient live Provider failure remain nonpasses, not hidden passes. |

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

1. Install the final candidate under a controlled owner-approved transition,
   then enable and qualify its Developer ID protected filesystem service as a
   distinct process, including successful authorized mutation and recovery
   behavior. The current System Settings readback shows Forge background
   activity off and Manager reports **Approval required**; read-only hashes
   prove that registered installation contains an older daemon.
2. Notarize and staple the signed outer Installer, then pass local Gatekeeper's
   install assessment. Existing Notary credentials are required; none are
   created by this workflow. No local `notarytool` profile/API key or repository
   Actions secret is currently available for that submission.
3. Record the resource/stress case on another representative physical-memory
   capacity. The injected constrained policy is valuable coverage but is not a
   second physical host. The published revision's macOS CI Release lane passed
   and retained the guarded stress JSON and its host capacity; that hosted
   observation does not replace the physical-host gate.
4. Rebuild or attest the final artifact from the exact published revision.
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

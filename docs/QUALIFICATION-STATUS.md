# Version and qualification status

Product identity: **0.10.0, build 2**, supporting **macOS 26+**. The owner is
preparing a shippable build and will perform shipment separately. The version
advance and repository changes require fresh product qualification; earlier
`0.9.0 (1)` receipts remain historical evidence only. This page is a concise
status index; the detailed, source-bound receipts are in the
[functional-build record](FUNCTIONAL-DEVELOPMENT-BUILD.md) and
[roadmap](../ROADMAP.md).

## Version and build agreement

The Swift runtime, CLI, Xcode Debug and Release configurations, and current
documentation use version **0.10.0, build 2**. The root [`VERSION`](../VERSION)
and [`BUILD_NUMBER`](../BUILD_NUMBER) files are canonical; compiled constants
and Xcode build settings must match them. The consistency check runs locally and
in CI. Filesystem protocol, provider-plugin, and database schema versions are
separate compatibility contracts.

The canonical native project is `ForgeConductor.xcworkspace`, using the
`ForgeConductor` scheme. Its archive contains one installable app product with
the Core framework, manager CLI, runtime launcher, filesystem daemon, resources,
and icon. A standalone SwiftPM CLI is not a substitute for that signed bundle.

## Current source and functional evidence

The tested production source is owner-authored revision
`b756b243d24d7dd06098dbbafcdfaa77ab7c97e0`, tree
`6c03f40e2b04ae6dfd689c9347a84014f7ebe496`; its final GitHub workflow passed
native source integrity plus Swift and Xcode Debug/Release lanes. Local and
remote `main` were then synchronized at documentation closeout revision
`f02abeb8c940c8d998f822fd4f1cad5c20c7765e`, tree
`c6475126b54c8ff8de1465940e3ecc3c702a00eb`. That closeout changes
documentation only and leaves the tested native graph unchanged.

| Surface | Current result | Boundary |
|---|---|---|
| Swift/Core suite | The final direct `swift test` terminal run executed **1,554 XCTest cases**, with **12 explicit skips and zero failures**. | Declared skips remain distinct from passes; the transcript is identified in the functional-build record. |
| Projects and Manager | The published-tree Xcode **My Mac** product registered picker-selected and absolute-path projects, authorized and saved canonical roots, rejected filesystem root, and retained state across relaunch. | The installed protected filesystem service still requires distinct-process qualification. |
| LM Studio Provider | The published-tree native UI saved the loopback endpoint and loaded `qwen/qwen3.8-27b` model, refreshed inventory, passed the connection probe, replaced the manager, retained configuration, and passed again. Offline save/error and invalid endpoint handling also passed. | A downloaded or listed model is not treated as loaded; the exact loaded variant remains required. |
| Revision-3 Provider preparation | The current Phase 5 source passed seven deterministic preparation cases with one explicit live-only skip plus a separately enabled 1/1 live LM Studio `openai/gpt-oss-20b` case. The live operation preserved the pin, verified the contract, wrote the revision-bound readiness receipt, and reused that exact receipt idempotently. Provider configuration passed 14/14 with one explicit disposable-Keychain skip; app provider contracts passed 11/11, operator contracts 10/10, and dashboard security 7/7. | External service start and model load remain typed operator actions when the provider offers no supported authenticated lifecycle API. A focused native UI run timed out while enabling automation before test execution and is a non-pass. Signed source publication is recorded separately after final gates. |
| Revision-3 runtime readiness | The current Phase 5 source passed focused checks proving an unavailable optional Python runtime does not disable the shell, an explicitly required Python runtime produces exactly one recovery action, nil-path legacy state remains `unknown`, and application-wide shell denial is reported at its true policy scope. Both SwiftPM products, the signed canonical Debug app build, and the universal Xcode Core test target build passed with the new resolver and test in their canonical targets. | Runtime necessity is derived only from explicit structured evidence; task prose is intentionally not interpreted as authority. A zero-selected app-test filter was a non-pass and is not test evidence. |
| Managed Autonomy | The published-tree native UI authorized and registered an isolated project, connected to LM Studio, admitted the exact read-only assignment, and imported its run-bound policy. A separate current-source live run consumed `fs_read`, retried repaired completion validation without provider/tool replay, executed one signed XCTest case, reached `completed`, and retained `tests`. | Completion remains fail closed without an exact owner-installed native-validation policy and approved signed package. |
| Native policy import | Core and Developer ID Release UI evidence covers run/project/gate/source/package binding, picker cancellation, exact import, mode `0600`, changed-package rejection, and protected readback. | The app does not silently approve model text or a hand-edited result as native evidence. |
| Continuity | The r3 deterministic crash matrix recovers every managed transition with one accepted successor and one continuation. A current-source live LM Studio `openai/gpt-oss-20b` run at an observed 65,536-token context triggered on exact provider usage, fenced predecessor tools, survived a post-bootstrap-response manager restart, accepted and consumed one fresh-root successor, performed the successor-only read, then preserved the same receipt/session/turn/tool set across another restart. The handoff retained exact instruction-delivery coverage, artifact, grant, completion-plan, evidence, open-work, and provider-revision bindings. | The live run injects one in-process post-commit crash boundary; the other transitions are covered deterministically rather than by real SIGKILL. LM Studio still exposes no supported authenticated API for replacing an existing desktop GUI chat, so Forge-managed native host mode is the supported automatic path. |
| Resource policy | Focused Debug and final-source, Xcode-compiled signed Release Core stress each passed on this **128 GiB Apple M5 Max** host while also executing the injected **8 GiB constrained policy**. The final Release report refuses to write `passed` after a recorded XCTest failure. | A second physical-memory-capacity execution is not yet recorded. |
| Native GUI | The published-tree production-onboarding surface passed all seven cases: five in the class run and the two live LM Studio cases in an exact zero-skip rerun after correcting Xcode environment inheritance. | The initial two explicit skips, earlier runner timeouts, and one retained transient live Provider failure remain nonpasses, not hidden passes. |

## Current distribution evidence

The exact owner-authored published tree at `f02abeb8`, including the tested
production source and documentation-only closeout, produced a universal
Developer ID Release archive and manual export. The archive has one canonical
`com.forge-conductor.app` product, version `0.9.0` build `1`, both `x86_64` and
`arm64` architectures, the required icon assets, and all four nested products.
Strict deep signing and the Release privileged-bundle checker pass on the
archive, export, ZIP extraction, and expanded Installer payload.

The unshipped source-bound app ZIP is:

- `/private/tmp/forge-published-main-developerid-app-20260917.zip`
- 22,112,426 bytes
- SHA-256 `a171d88409c2ef36816b5ccbc4bb304a3855b5fc7f3972492259adcd143ec338`

The matching Installer was signed through Apple's `productbuild` path with
James Daley's Developer ID Installer identity and a trusted timestamp. Its
expanded payload retains the exact exported signatures and bundle contents.

The unshipped source-bound Installer is:

- `/private/tmp/forge-published-main-signed-installer-20260917.pkg`
- 22,099,582 bytes
- SHA-256 `21a0dc3d68dfbd410408c38cb8e3ce1ee9a395269a30bbeba89d94ab13a16d28`

Neither exact published-tree artifact is notarized. Gatekeeper correctly
rejects the app and Installer as `source=Unnotarized Developer ID`. Earlier
notarized app receipts remain valid for their recorded source, but they do not
replace notarization of these exact artifacts.

## Remaining gates

The following results are still required before declaring the owner target
complete:

1. Install the final candidate under a controlled owner-approved transition,
   then enable and qualify its Developer ID protected filesystem service as a
   distinct process, including successful authorized mutation and recovery
   behavior. The current System Settings readback shows Forge background
   activity off and Manager reports **Approval required**; read-only hashes
   prove that registered installation contains an older daemon.
2. Notarize the exact published-tree archive/app and signed outer Installer,
   staple both artifacts, then pass local Gatekeeper execution and installation
   assessments. Existing Notary credentials are required; none are created by
   this workflow. No local `notarytool` profile/API key or repository Actions
   secret is currently available for a command-line submission.
3. Record the resource/stress case on another representative physical-memory
   capacity. The injected constrained policy is valuable coverage but is not a
   second physical host. The published revision's macOS CI Release lane passed
   and retained the guarded stress JSON and its host capacity; that hosted
   observation does not replace the physical-host gate.
4. Pass public-download acceptance on the notarized artifacts. Shipment remains
   the owner's separate action after qualification.

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

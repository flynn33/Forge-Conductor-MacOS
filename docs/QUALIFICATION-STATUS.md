# Version and qualification status

Product identity: **0.13.0, build 5**, supporting **macOS 26+**. The owner is
preparing a shippable build and will perform shipment separately. The version
advance and repository changes require fresh product qualification; earlier
`0.9.0 (1)` receipts remain historical evidence only. This page is a concise
status index; the detailed, source-bound receipts are in the
[functional-build record](FUNCTIONAL-DEVELOPMENT-BUILD.md) and
[roadmap](../ROADMAP.md).

## Version and build agreement

The Swift runtime, CLI, Xcode Debug and Release configurations, and current
documentation use version **0.13.0, build 5**. The root [`VERSION`](../VERSION)
and [`BUILD_NUMBER`](../BUILD_NUMBER) files are canonical; compiled constants
and Xcode build settings must match them. The consistency check runs locally and
in CI. Filesystem protocol, provider-plugin, and database schema versions are
separate compatibility contracts.

The canonical native project is `ForgeConductor.xcworkspace`, using the
`ForgeConductor` scheme. Its archive contains one installable app product with
the Core framework, manager CLI, runtime launcher, filesystem daemon, resources,
and icon. A standalone SwiftPM CLI is not a substitute for that signed bundle.

## Current source and functional evidence

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
| Swift/Core suite | Published feature implementation `2319db359f28fba9cf350694ff8f66a7ecc70491`, tree `ff12dde3fe7ab27f741dd114143bd31afd20ed98`, and published `0.12.0 (4)` alignment `bd33fda1b683070dcf56c16bb4c8ac778623ae31`, tree `46ebbe041732f8fdd22331c031e73b7d8f7ae10f`, each passed a direct `swift test` terminal run with **1,720 XCTest cases**, **13 explicit environment/live skips, and zero failures**. Both push/fetch readbacks showed exact local/remote equality and zero divergence. | Declared skips remain distinct from passes; installed-build qualification remains separate. |
| Projects and Manager | The published-tree Xcode **My Mac** product registered picker-selected and absolute-path projects, authorized and saved canonical roots, rejected filesystem root, and retained state across relaunch. | The installed protected filesystem service still requires distinct-process qualification. |
| LM Studio Provider | The published-tree native UI saved the loopback endpoint and loaded `qwen/qwen3.8-27b` model, refreshed inventory, passed the connection probe, replaced the manager, retained configuration, and passed again. Offline save/error and invalid endpoint handling also passed. | A downloaded or listed model is not treated as loaded; the exact loaded variant remains required. |
| Revision-3 Provider preparation | Published source `01c874e17c9a26c8f3111981748ed1bd3bdc1f81` passed seven deterministic preparation cases with one explicit live-only skip plus a separately enabled 1/1 live LM Studio `openai/gpt-oss-20b` case. The live operation preserved the pin, verified the contract, wrote the revision-bound readiness receipt, and reused that exact receipt idempotently. Provider configuration passed 14/14 with one explicit disposable-Keychain skip; app provider contracts passed 11/11, operator contracts 10/10, and dashboard security 7/7. | External service start and model load remain typed operator actions when the provider offers no supported authenticated lifecycle API. A focused native UI run timed out while enabling automation before test execution and is a non-pass. |
| Revision-3 runtime readiness | Published source `01c874e17c9a26c8f3111981748ed1bd3bdc1f81` passed focused checks proving an unavailable optional Python runtime does not disable the shell, an explicitly required Python runtime produces exactly one recovery action, nil-path legacy state remains `unknown`, and application-wide shell denial is reported at its true policy scope. Both SwiftPM products, the signed canonical Debug app build, and the universal Xcode Core test target build passed with the new resolver and test in their canonical targets. | Runtime necessity is derived only from explicit structured evidence; task prose is intentionally not interpreted as authority. A zero-selected app-test filter was a non-pass and is not test evidence. |
| Managed Autonomy | The published-tree native UI authorized and registered an isolated project, connected to LM Studio, admitted the exact read-only assignment, and imported its run-bound policy. A separate current-source live run consumed `fs_read`, retried repaired completion validation without provider/tool replay, executed one signed XCTest case, reached `completed`, and retained `tests`. Current source also starts the embedded watchdog from the GUI; permits exact confirmed deletion of one terminal task; exposes selectable typed completion presets; and persists pause, bounded retry, or terminal-stop behavior plus custom model instructions. | Completion remains fail closed without exact durable evidence. Signed custom policies remain a separate advanced capability. The new source has deterministic focused evidence; it is not an installed-build claim. |
| Forge Rig operability | Published implementation `2319db359f28fba9cf350694ff8f66a7ecc70491` shortens Load Trace and pairs it with bounded status/load cards for headless LM Studio, Autonomy, Continuity, and Rune Forge plus project progress. Directly below, Managed Activity combines the current package, inferred current step, durable delivered count, and run work with bounded operator-redacted assistant/model-error/tool summaries, orchestration events, and exact project/generation policy events. Exact run lookup survives the public recent-100 boundary and returns continuity for that same project/generation/run. Durable storage is capped at 2 KiB per summary and 128 assistant plus 128 tool rows per run; rows are independently content-hashed outside the append-only non-activity audit lineage. Both clients enforce a streamed 4 MiB response ceiling. The view-owned five-second refresh exists only while Rig is visible; presentation retains at most 100 app-local rows and caps each displayed activity message at 8 KiB. The final SwiftPM regression passed 1,720 tests with 13 explicit skips; app-hosted Rig/Rune Forge passed 17/17; and fresh native UI passed 3/3 with zero skips across all-14-view minimum-window containment/alignment, populated compact equal-height Storage/Managed Activity geometry/content, and the populated Rune Forge Policy Feed. Both SwiftPM products, the Apple Development-signed Debug app build, and the signed project-local smoke bundle passed. | This is a bounded, coalesced latest-state monitor, not token streaming or persisted full-transcript evidence. Rune Forge remains an additive observer and does not control task outcomes. The working installation was not replaced; installed-build qualification remains separate. |
| Native policy import | Core and Developer ID Release UI evidence covers run/project/gate/source/package binding, picker cancellation, exact import, mode `0600`, changed-package rejection, and protected readback. | The app does not silently approve model text or a hand-edited result as native evidence. |
| Continuity | The r3 deterministic crash matrix recovers every managed transition with one accepted successor and one continuation. A current-source live LM Studio `openai/gpt-oss-20b` run at an observed 65,536-token context triggered on exact provider usage, fenced predecessor tools, survived a post-bootstrap-response manager restart, accepted and consumed one fresh-root successor, performed the successor-only read, then preserved the same receipt/session/turn/tool set across another restart. The handoff retained exact instruction-delivery coverage, artifact, grant, completion-plan, evidence, open-work, and provider-revision bindings. | The live run injects one in-process post-commit crash boundary; the other transitions are covered deterministically rather than by real SIGKILL. LM Studio still exposes no supported authenticated API for replacing an existing desktop GUI chat, so Forge-managed native host mode is the supported automatic path. |
| Resource policy | Focused Debug and final-source, Xcode-compiled signed Release Core stress each passed on this **128 GiB Apple M5 Max** host while also executing the injected **8 GiB constrained policy**. The final Release report refuses to write `passed` after a recorded XCTest failure. | A second physical-memory-capacity execution is not yet recorded. |
| Native GUI | The published-tree production-onboarding surface passed all seven cases: five in the class run and the two live LM Studio cases in an exact zero-skip rerun after correcting Xcode environment inheritance. | The initial two explicit skips, earlier runner timeouts, and one retained transient live Provider failure remain nonpasses, not hidden passes. |
| Rune Forge and Stjornarvald | RF-SJ-00 through RF-SJ-10 are implemented. The full SwiftPM rerun passed 1,687 tests with 12 explicit skips; app-hosted Rune Forge/Guided Mode passed 9/9; native UI passed 5/5; prior focused non-interference, fault, restart, privacy, Thread Sanitizer, Xcode membership, signed Debug build, and strict signature evidence remains current. All 40 acceptance rows are individually recorded. | Thirty-nine rows are accepted. AC-032 remains limited because automated accessibility semantics and keyboard behavior passed but a human physical VoiceOver listening session was not performed. This is implementation acceptance, not current-source Developer ID, notarization, installation, or shipment acceptance. |

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

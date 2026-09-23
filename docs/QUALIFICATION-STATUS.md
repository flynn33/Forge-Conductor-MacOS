# Version and qualification status

Product identity: **0.14.1, build 7**, supporting **macOS 26+**. The owner is
preparing a shippable build and will perform shipment separately. The version
advance and repository changes require fresh product qualification; earlier
`0.9.0 (1)` receipts remain historical evidence only. This page is a concise
status index; the detailed, source-bound receipts are in the
[functional-build record](FUNCTIONAL-DEVELOPMENT-BUILD.md) and
[roadmap](../ROADMAP.md).

## Version and build agreement

The Swift runtime, CLI, Xcode Debug and Release configurations, and current
documentation use version **0.14.1, build 7**. The root [`VERSION`](../VERSION)
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
a clean whole-application performance claim. The owner installation was not
replaced. Claude Code Desktop and Codex Desktop were not exercised as live
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
Keychain-environment skip. The exact current tree passed the full SwiftPM suite
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
revisions remain distribution evidence for the source they name; they are not
the current `0.14.1 (7)` source result.

| Surface | Current result | Boundary |
|---|---|---|
| 0.14.1 operability correction | Published source `8ca3f24d9a81adce56e1a5232a6181edd08cf00b`, tree `9bc840d7fdfe47bd552c4b8e095091502fecc3b6`, passed **1,844 tests with 13 explicit skips and zero failures**. Both SwiftPM products and a clean canonical arm64 Apple Development-signed Debug workspace build passed with no warning or error lines. Native UI coverage passed the eight-step Guided Setup, Autonomy recovery, complete Continuity detail/title-bar geometry, Provider Connect and Check plus contract-failure presentation, compact Dashboard Storage/Managed Activity geometry, and every primary view at minimum and normal window sizes. Version/build constants and all Xcode configurations are aligned to `0.14.1 (7)`. | One Provider configuration case is an explicit Keychain-environment skip, and the UI runner retains a nonfailing main-thread runtime diagnostic. No fresh live loaded-model LM Studio or live Claude/Codex host result is claimed; installed-build and distribution-artifact evidence remain separate. |
| Historical Swift/Core provider baseline | The `0.14.0 (6)` provider baseline `65af43e31aa2b818ccd2f915aa7f89c34b7c821d`, tree `945cdb9d6adaf17c85845fe846910ece527288fd`, passed both SwiftPM product builds and a direct full-suite terminal run with **1,849 XCTest cases**, **13 explicit environment/live skips, and zero failures**. The warning-repair source `117aa95f982bccb4c1ef0d0acc8b92666127be70`, tree `00344bd6a1ce72f278e1a832a1d6e9f3a27f2d9f`, separately passed both SwiftPM product builds, a fresh canonical Apple Development-signed Debug workspace build, and the focused **3/3** MCP attachment plus **20/20** Provider configuration cases without either reported Swift diagnostic. | The 1,849-case regression remains bound to its exact baseline revision and is not claimed for the current patch. Declared skips remain distinct from passes. Live desktop-host, installed-build, distribution-artifact, and shipment qualification remain separate. |
| Projects and Manager | The published-tree Xcode **My Mac** product registered picker-selected and absolute-path projects, authorized and saved canonical roots, rejected filesystem root, and retained state across relaunch. | The installed protected filesystem service still requires distinct-process qualification. |
| Provider integrations | The 0.14.0 source implements mutually exclusive LM Studio, Claude Code Desktop, and Codex Desktop selection; transactional Forge-owned desktop package installation, rollback, repair, and removal; a bounded durable operation ledger; revision-bound run admission; authenticated loopback hooks; and selected-provider readiness on Dashboard and Guided Setup. Desktop sessions receive a provider-specific MCP launch command and a five-minute, single-use capability bound to provider, session, run, project generation, selection revision, deployment, and frozen authorization scope. Project tools stay unavailable until `desktop_run_attach` atomically consumes that capability. Deterministic focused coverage passed **100/100**; canonical Xcode passed **83/83 Core**, **40/40 app-hosted**, and **6/6 native UI** cases; the full SwiftPM regression passed **1,849 cases with 13 explicit skips and zero failures**. Grok Build remains visible but non-selectable for owned-artifact cleanup and forward compatibility. | Deterministic tests and an installation receipt do not prove that a selectable desktop host is open, has reloaded the package, has accepted hook trust, or has completed a live session. Claude and Codex require separate live acceptance; neither qualifies the other. Grok's documented startup/prompt hook outputs do not deliver Forge's initial assignment context, so no ready, run, or live-support claim is made for Grok in 0.14.0. Existing Thread Performance Checker diagnostics also remain, so no clean whole-application performance claim is made. |
| LM Studio Provider | The published-tree native UI saved the loopback endpoint and loaded `qwen/qwen3.8-27b` model, refreshed inventory, passed the connection probe, replaced the manager, retained configuration, and passed again. Current deterministic recovery coverage verifies bounded discovery across system, per-user, Homebrew, and `PATH` CLI locations; wrapped status JSON and string ports; server start; delayed readiness; reported-port fallback; cancellation; and fail-closed malformed, timed-out, or truncated results. | A downloaded or listed model is not treated as loaded; the exact loaded variant remains required. The current host had no loaded model during this patch's qualification, so no fresh live contract-probe pass is claimed. |
| Revision-3 Provider preparation | Published source `01c874e17c9a26c8f3111981748ed1bd3bdc1f81` passed seven deterministic preparation cases with one explicit live-only skip plus a separately enabled 1/1 live LM Studio `openai/gpt-oss-20b` case. The live operation preserved the pin, verified the contract, wrote the revision-bound readiness receipt, and reused that exact receipt idempotently. Provider configuration passed 14/14 with one explicit disposable-Keychain skip; app provider contracts passed 11/11, operator contracts 10/10, and dashboard security 7/7. | External service start and model load remain typed operator actions when the provider offers no supported authenticated lifecycle API. A focused native UI run timed out while enabling automation before test execution and is a non-pass. |
| Revision-3 runtime readiness | Published source `01c874e17c9a26c8f3111981748ed1bd3bdc1f81` passed focused checks proving an unavailable optional Python runtime does not disable the shell, an explicitly required Python runtime produces exactly one recovery action, nil-path legacy state remains `unknown`, and application-wide shell denial is reported at its true policy scope. Both SwiftPM products, the signed canonical Debug app build, and the universal Xcode Core test target build passed with the new resolver and test in their canonical targets. | Runtime necessity is derived only from explicit structured evidence; task prose is intentionally not interpreted as authority. A zero-selected app-test filter was a non-pass and is not test evidence. |
| Managed Autonomy | Current source exposes selectable built-in completion checks and preserves additional requirements only from the exact bound instruction package. Package requirements are read-only in the prepared and running task; unknown configuration-owned identifiers are rejected. Durable Manager evidence, retained completion requests, provider wait/resume, and state-derived recovery guidance have focused deterministic coverage. The embedded watchdog, settled-task deletion, pause/bounded-retry/terminal-stop behavior, and custom model instructions remain available. | Completion remains fail closed without exact durable evidence. The current source has deterministic focused evidence; it is not an installed-build claim. |
| Dashboard operability | Published implementation `2319db359f28fba9cf350694ff8f66a7ecc70491` shortens Load Trace and pairs it with bounded status/load cards for headless LM Studio, Autonomy, Continuity, and Rune Forge plus project progress. Directly below, Managed Activity combines the current package, inferred current step, durable delivered count, and run work with bounded operator-redacted assistant/model-error/tool summaries, orchestration events, and exact project/generation policy events. Exact run lookup survives the public recent-100 boundary and returns continuity for that same project/generation/run. Durable storage is capped at 2 KiB per summary and 128 assistant plus 128 tool rows per run; rows are independently content-hashed outside the append-only non-activity audit lineage. Both clients enforce a streamed 4 MiB response ceiling. The view-owned five-second refresh exists only while Dashboard is visible; presentation retains at most 100 app-local rows and caps each displayed activity message at 8 KiB. The retained native UI evidence covers all-primary-view containment/alignment, populated compact equal-height Storage/Managed Activity geometry/content, the Dashboard Guided Setup button, and the populated Rune Forge Policy Feed. | This is a bounded, coalesced latest-state monitor, not token streaming or persisted full-transcript evidence. Rune Forge remains an additive observer and does not control task outcomes. The working installation was not replaced; installed-build qualification remains separate. |
| Continuity | The r3 deterministic crash matrix recovers every managed transition with one accepted successor and one continuation. A source-bound live LM Studio `openai/gpt-oss-20b` run at an observed 65,536-token context triggered on exact provider usage, fenced predecessor tools, survived a post-bootstrap-response manager restart, accepted and consumed one fresh-root successor, performed the successor-only read, then preserved the same receipt/session/turn/tool set across another restart. Current UI coverage preserves manual actions, exact operation identity, budget, handoff/successor detail, and history while keeping the title/Refresh control below the toolbar and eliminating the unused empty frame. | The live run injects one in-process post-commit crash boundary; the other transitions are covered deterministically rather than by real SIGKILL. LM Studio still exposes no supported authenticated API for replacing an existing desktop GUI chat, so Forge-managed native host mode is the supported automatic path. Current installed-build qualification remains separate. |
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

## Remaining release checks

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
   observation does not replace the physical-host check.
4. Pass public-download acceptance on the notarized artifacts. Shipment remains
   the owner's separate action after qualification.

The owner installation has not been replaced, and neither the app ZIP nor the
Installer has been shipped or publicly published.

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

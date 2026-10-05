# Compute Cores checkpoint history

This file preserves earlier failed, passing and pending checkpoints. The
current authoritative [Compute record](COMPUTE-CORES.md) records verified UI
implementation and QA for **0.17.0 (27)**, source manifest 28548a73…, 116 distinct
production tests and a separate native matrix of 21 methods, 22 invocations and
463 reviewed images. Four matching signed ordinary workflows passed. Exact
owner publication/readback/synchronization refs are retained externally.
Historical **OPEN**, **Not Run**, **STALE** and “current” statements below apply
only to their recorded inputs; they are not current phase status. No historical
result is rewritten or promoted to a new execution.

## Historical draft checkpoint — October 4, 2026

**At this checkpoint: delivery OPEN; source 0.17.0 (27).**
This record tracks the owner-authorized revision 2 Compute Cores / application
color scope. The Dashboard integration and focused supporting checks are
present; all 32 full acceptance gates remain open. Executed metadata,
projection, native Metal/lifecycle, palette and Settings checks are separated
from unqualified whole-chip fixtures and pending current-palette route QA.
No complete chip, FX or palette acceptance is claimed.

The last ordinary candidate at
`build/graphite-app/Build/Products/Debug/Forge Conductor.app` is **STALE**
for the new source edits. Its retained checkpoint identity is CDHash
`ad6014ae8aa90528937939618ba008c3efd4c627`, with bundle-manifest SHA-256
`55ce38c37e1ef5215fa26c2cb53c7185471cde64615577c9a9affacede109ca8`.
These identities remain historical receipts in
[Graphite Workbench](GRAPHITE-WORKBENCH.md); they do not identify a candidate
containing the new chip/FX/palette inputs. Final source/resource/test membership,
compiled shader packaging, candidate identity and publication remain open.
This draft changes no version authority or working installation.

## Authority and preservation

The current package is
`/Users/flynn/Downloads/Forge-Conductor-Compute-Cores-Metal-Palette-Instructions`.
Its `REVISION-2.md`, `verification/ACCEPTANCE.md`,
`instructions/07-application-color-alignment.md` and
`contracts/application-palette.json` define this scope.

The approved Compute Cores image owns the detailed package/die/contact/trace
appearance inside the existing frame. Revision2 requires Metal + MetalKit for
normal chip illumination and moving trace FX, using build-time-compiled
shaders. A genuine resource/capability failure may use a truthful static native
fallback; fallback alone does not pass Metal FX acceptance.

The approved Graphite Workbench board owns application colors only. Outside
Compute Cores, current layout, spacing, typography sizes, navigation, commands,
controls, data and other renderer clocks must remain intact. Its obsolete
routes/sample controls have no dispatch or implementation authority. Existing
credentials, signing, isolation, time/output bounds and compatibility remain
required. Installation, notarization and shipment are separate owner work.

## Source-present implementation draft

Paths in this inventory are beneath `Sources/ForgeConductorApp`, except the
host metadata owners in `Sources/ForgeConductorCore/Telemetry`.
`RigDashboardView.computeCoresPanel` now projects current host CPU/GPU samples
and Metal device identities into `ComputeCoresContentView`, retaining its
existing frame and `rig-compute-cores-panel` identifier. This source readback
establishes integration; the full Dashboard native fidelity and interaction
matrix remains open. Focused execution is recorded separately below.

| Surface | Current source read | Status |
|---|---|---|
| Host metadata | `CPUCollector.collect`, `GPUCollector.collect`, `GPUCounterAssociation.sharedRegistryID`, `CPUMetrics` / `GPUMetrics` | Fresh 35-case Core scope passed, including eight provenance cases; not chip pixel acceptance. |
| Projection | `Metal/ComputeChipProjection.swift`: `ComputeChipSnapshot.project`, `ComputeChipChannel` | Ten-case pure Compute checkpoint passed; current twelve-case suite awaits fresh execution. Whole-view fixture acceptance remains open. |
| Package geometry | `Metal/ComputeChipLayout.swift`: `ComputeChipLayout.make` | Initial bounded/stable/narrow geometry case passed; native reference fidelity remains open. |
| Animation | `Metal/ComputeChipAnimation.swift`: `advance`, `pulseInstances`, `ComputeTraceRoute.point` | Initial deterministic envelope/route cases passed; native motion recording remains open. |
| Metal ownership | `Metal/ComputeChipRenderer.swift`: `ComputeChipResources`, `ComputeChipFramePool`, `ComputeChipRenderer`, `ComputeChipMetalView` | Fresh five-case native suite passed compiled commands, reuse/release, hidden/minimize/occlusion/reopen, pause/Reduce Motion and bounded readback. Whole-view fixture acceptance remains open. |
| Shader functions | `Metal/ComputeChipShaders.metal`: `compute_chip_vertex`, `compute_chip_fragment` | Initial native host asserted actual compiled function names, nonempty library origin and completed commands. Ordinary candidate packaging/load identity remains open. |
| Native labels/fallback | `Views/Rig/ComputeCoresContentView.swift`: `ComputeCoresContentView`, `ComputeChipSurface`, `ComputeChipStaticFallback` | Source present; integration and native capture acceptance Not Run. |
| Shared colors | `Views/GraphiteWorkbench.swift`: `GraphitePalette`, `linearRGBA`; existing view bindings | Eleven Graphite cases passed including contrast and single sRGB conversion. Settings minimum pixels were reviewed; full route/state/appearance matrix remains open. |

`ComputeChipSnapshot.project` consumes the host CPU brand/logical count and
matches GPU samples to Metal registry identities. It carries source quality
and each channel's own observation timestamp. Source describes up to 256 CPU
display regions (grouping higher logical counts) and 16 **illustrative** GPU
regions driven by one valid aggregate sample. It does not infer P/E grouping
from sample order. Initial pure identity/topology/projection cases passed;
native identity and complete pixel acceptance remain open.

`ComputeChipAnimation` declares at most 64 routes and 192 pulse instances,
keeps renderer-local phases/envelopes, and evaluates pause/freshness/Reduce
Motion. `ComputeChipFramePool` has three activity/pulse slots released from
command completion. The renderer has eligibility checks and local counters
for submissions, completion, clocks, surfaces, buffers and in-flight slots.
Fresh native tests observed bounded buffer reuse and release, offscreen,
ordered-out, minimized and occluded quiescence/resume, twelve reopens with
release, and static pause/Reduce Motion. Actual GPU readbacks retain one
in-flight command and one replaceable latest request. Whole-chip motion and
final steady-state cost/reference review remain open.

`ComputeChipResources` requests a packaged `ComputeChipShaders.metallib`
or a compiled default library and looks up `compute_chip_vertex` /
`compute_chip_fragment`. No runtime-source compilation call is present in
that new loader. Initial native commands completed with the named compiled
functions; this is distinct from final ordinary-candidate packaging and pixel
fidelity. The native label layer and static fallback are present in source;
whole-view fallback failure captures remain unqualified.

`GraphitePalette` remains the semantic owner. Source now has graphite
surfaces, steel boundaries, blue selection, mint actions with dark ink,
readable cool text and distinct warning/error/unavailable roles.
`linearRGBA` is the new chip's explicit sRGB-to-linear input helper.
The initial eleven Graphite cases include numerical contrast and a single
sRGB transfer boundary. Whole-application compositing and current native
appearance remain pending.

## Executed supporting evidence

The result bundle exists at
`build/graphite-results/compute-metadata-settings-minimum.xcresult`.
The recorded command selected `ComputeTelemetryProvenanceTests` and
`ForgeConductorUITests/testGraphiteNativeSettingsCapturesEverySectionAtMinimumSize`
through the canonical `ForgeConductor.xcworkspace` / `ForgeConductor`
scheme, Debug, serial My Mac destination.

| Scope | Observed result | Evidence boundary |
|---|---|---|
| E0 — `ComputeTelemetryProvenanceTests` | **8 executed, 0 failed**, 0.038 seconds (0.040 wall-clock suite interval). All eight named cases passed in `/tmp/forge-compute-metadata-settings-minimum.log`. | Core/host metadata support; not the new chip projection, renderer, shader or animation. |
| Native Settings minimum | **1 executed, 1 failed** in 22.428 seconds. The assertion required 760 × 560 content plus the measured 32-point title bar. | This selected case failed; no complete minimum-Settings capture pass. |
| Overall invocation | **TEST FAILED**, recorded terminal exit 65. | Eight metadata passes do not make the mixed invocation pass. |

The eight metadata cases cover equal measured samples after warmup, distinct
host fallback, unavailable numerical compatibility, topology-baseline reset,
legacy initializer/dictionary-key compatibility, rejection of mixed/unmatched
registry association, retained GPU observation time on realtime composition,
and observed registry identity matching a native Metal device **when an
association is available**. The last case's conditional assertion does not
prove an association exists on every host.

Older Graphite builds, selected test scopes, native captures, accessibility
checks, failures, hashes and ordinary-candidate workflows retain their exact
recorded limits in [Graphite Workbench](GRAPHITE-WORKBENCH.md).
They are not new Compute/FX/palette evidence and are not added to these eight
metadata cases.

## Fresh selected supporting receipts

These later receipts supersede earlier Not Run descriptions only for their
named scopes. The failed metadata/Settings invocation above remains a failed
checkpoint; its eight metadata tests overlap the fresh Core scope below.

| Scope | Observed result and receipt | Evidence boundary |
|---|---|---|
| Core host/provenance/contracts | Terminal exit 0; **35 executed, 0 failures, 0 skips**, **2.567 seconds**. Provenance 8, Mach host metrics 9, Rig parity 16, telemetry contracts 2; `/tmp/forge-compute-core-regressions.log`. | Source/collector compatibility; not full chip pixels. An unrelated support target selected zero tests and adds no coverage. |
| Initial chip/Graphite app-hosted checks | Terminal exit 0, `TEST SUCCEEDED`; **23 executed, 0 failures, 0 skips**, **4.242 seconds**. Pure chip 9, native chip lifecycle 3, Graphite 11; `compute-first-native-components.xcresult`, `/tmp/forge-compute-first-native-components.log`. | Native chip cases asserted completed commands, `compute_chip_vertex` / `compute_chip_fragment`, nonempty compiled-library origin, buffer bounds/reuse/release, offscreen/order-out resume and static pause/Reduce Motion. The selected legacy gauge names executed **zero** cases here. This does not prove full pixel/reference fidelity or the later expanded source. |
| Legacy settled gauges after resize | Terminal exit 0, `TEST EXECUTE SUCCEEDED`; **3 executed, 0 failures, 0 skips**, **10.253 seconds**. `compute-legacy-gauges-settled-resize.xcresult`, `/tmp/forge-compute-legacy-gauges-settled-resize.log`. | Actual native settled bar/ring/core viewport resize without a value change; separate from the initial 23 cases and new chip acceptance. |
| Native Settings minimum | Terminal exit 0, `TEST SUCCEEDED`; **1 executed, 0 failures, 0 skips**, **134.245 seconds**. `compute-settings-coalesced-configuration.xcresult`, `/tmp/forge-compute-settings-coalesced-configuration.log`. | All nine sections and lower scroll states at measured 760×592 outer / 760×560 content, 2× scale. Fourteen original PNGs were opened for pixel review in `/tmp/forge-compute-settings-coalesced-pixel-review.md`; no clipping/overlap observed. This closes that Settings minimum gate for these inputs, not whole-app palette or chip acceptance. A retained main-thread diagnostic is not erased by the pass. |
| SwiftPM CLI | Terminal exit 0; `Build complete!` in **13.64 seconds**, `/tmp/forge-compute-cli-build.log`. | CLI compilation only; no ordinary app candidate or new shader/render acceptance. |
| Expanded app-hosted regressions | Terminal exit 0, `TEST EXECUTE SUCCEEDED`; **76 executed, 0 failures, 0 skips**, **39.506 seconds**. Pure Compute 10, native Compute 5, Graphite 11, Guided Mode 3, review 7, legacy gauges 7, Provider 33; `compute-app-regressions.xcresult`, `/tmp/forge-compute-app-regressions.log`. | Fresh native five-case scope includes actual GPU readbacks returning first/latest values `[1, 3]` with maximum one in flight, visibility/minimize/occlusion and twelve reopen/release cycles. Named phases observe 1.5-second intervals. The intended 19-case Projects class was not selected and remains a separate gate; whole-chip presentation fixtures are not in this pass. Earlier overlapping app-hosted counts are not added to this total. |
| Aggregate GPU production Metal pixels | Terminal exit 0, `TEST SUCCEEDED`; **1 executed, 0 failures, 0 skips**, **1.022 seconds**. `compute-gpu-pixel-ax-pilot-4.xcresult`, `/tmp/forge-compute-gpu-pixel-ax-pilot-4.log`. | Actual production drawable readbacks at 0/12/82% show strictly increasing luminance in all 16 illustrative regions; CPU stays idle. All three 1856×1088-pixel images were opened, with review/hashes in `build/graphite-results/compute-pilot-4-metal-pixel-review.json`. Native semantic Text roles and the actual canvas AX image were asserted using its exact owning content scope, excluding standard window chrome. Drawable-only pixels omit separately composed native labels; whole-component composition, real-host normal/minimum and moving-trace appearance remain open. |

Whole-chip presentation attempts stopped at native accessibility observer/state
prerequisites before their required pixel comparisons. The failed/interrupted
`compute-native-pixels-resize` receipts remain failures; a named lifecycle
suite pass inside an interrupted invocation does not qualify its whole-view
fixtures. The expanded pure/native gate subsequently passed as recorded
above. The corrected aggregate GPU fixture subsequently passed its named
readback/AX case; the other three whole-presentation cases remain open.
Blank-name identity handling has two additional pure tests in source, bringing
that suite to twelve; their new current-source gate awaits fresh execution.
The app/window appearance correction and contrast-only, transparency-only and
combined native capability fixtures also await fresh results, without system
preference writes. Full chip capture acceptance remains open.

The expanded hardware-name baseline failed: terminal exit 65, `TEST FAILED`,
**12 executed, 3 assertion failures, 0 skips**, **0.068 seconds** in
`/tmp/forge-compute-hardware-name-baseline.log`. Blank/whitespace GPU names
failed the identity-unavailable expectation; a whitespace-padded nonempty
variant failed name normalization. The narrow source correction requires
the same fresh twelve-case rerun. This failing baseline is not a pass.

The existing Settings sizing bridge also received a narrow actor-isolation
source correction after native compiler diagnostics: its notification observer
already uses `queue: .main`; the callback now enters `MainActor.assumeIsolated`,
and its deinitializer is isolated. No new task or unchecked-state workaround
was added; size bounds and coalescing remain unchanged. Fresh compiler and
minimum-Settings execution are required for this later edit. The prior
134.245-second pass remains tied to its earlier source inputs.

## Source-derived palette coverage inventory

`AppModel.AppTab.primaryNavigationTabs` exposes the following 13 current
routes. The retained internal `autonomy` compatibility route resolves to
Projects and is not restored as primary navigation by the palette board.
This inventory identifies source owners; it does not claim every route passed
current-color native review.

| Current route | Existing source owner | Palette / verification |
|---|---|---|
| Dashboard | `Views/Rig/RigDashboardView.swift; ComputeCoresContentView` | GraphitePalette / integrated chip source; current native route capture Not Run. |
| LM Studio MCP | `Views/MCPServersView.swift` | GraphitePalette / shared treatment; current native capture Not Run. |
| Agents | `Views/AgentsView.swift` | GraphitePalette / shared treatment; current native capture Not Run. |
| Tools | `Views/ToolsView.swift` | GraphitePalette / shared treatment; current native capture Not Run. |
| Live Feed | `Views/LiveFeedView.swift` | GraphitePalette / shared treatment; current native capture Not Run. |
| Projects | `OperatorConsole/Views/ProjectsOperatorView.swift` | GraphitePalette / shared treatment; current native capture Not Run. |
| Rune Forge | `OperatorConsole/Views/RuneForgeOperatorView.swift` | GraphitePalette / shared treatment; current native capture Not Run. |
| Continuity | `OperatorConsole/Views/ContinuityOperatorView.swift` | GraphitePalette / shared treatment; current native capture Not Run. |
| Runtimes | `OperatorConsole/Views/RuntimesOperatorView.swift` | GraphitePalette / shared treatment; current native capture Not Run. |
| Provider | `OperatorConsole/Views/ProviderOperatorView.swift` | GraphitePalette / shared treatment; current native capture Not Run. |
| Events & Evidence | `OperatorConsole/Views/EvidenceOperatorView.swift` | GraphitePalette / shared treatment; current native capture Not Run. |
| Diagnostics | `Views/DiagnosticsView.swift` | GraphitePalette / shared treatment; current native capture Not Run. |
| Manager | `Views/ManagerSettingsView.swift` | GraphitePalette / shared treatment; current native capture Not Run. |

| App-owned supporting presentation | Existing source owner / boundary | Current-color acceptance |
|---|---|---|
| Main window/sidebar, native window treatment and menus | `ForgeConductorApp.swift`, `AppSidebarView.swift`, `GraphiteWorkbench.swift` | Not Run |
| Native Settings / all nine Manager sections | `ManagerSettingsView`; same shared palette owner | Fresh minimum case passed; 14 PNGs reviewed. Other palette/state/appearance checks remain open. |
| Eight-step Guided Setup | `ContentView.swift / GuidedSetupWizardView` | Not Run |
| Contextual help, Advanced/related guides, inline help and unavailable guide | `GuidedHelpSheet`, `GuidedInlineHelp`, root/context sheet presenters | Not Run |
| Project registration sheet and existing project/package/cache confirmations | `ProjectsOperatorView` | Not Run |
| Packet deletion, history reset and disposable-cache confirmations | `ContinuityOperatorView` | Not Run |
| Provider Advanced, policy/source/violation details, runtime jobs, errors/loading/empty states | Existing operator route views and `OperatorConsoleComponents` | Not Run |
| Native capability checkboxes and unknown/metadata captions | `ToolPermissionEditor`, shared operator components | Not Run |
| Native open/save panels and standard menu internals | OS-controlled native surfaces; app appearance propagates through public APIs | Behavior retained; exact OS-owned pixels are not custom palette targets; current native readback Not Run |

The reviewed secondary binding delta uses existing text/success/tint roles in
`AutonomyOperatorView`, `ToolPermissionEditor`,
`OperatorConsoleComponents`, `GuidedHelpSheet` and
`GuidedInlineHelp`. Their conditions, text, icons and control actions remain
unchanged in that local delta. Whole-phase structure/behavior comparison and
native coverage are still required.

## Historical initial acceptance matrix — 32 then-open criteria

All 23 CC, 3 FX and 6 PAL full acceptance gates remain **Open** while the
whole-fixture, native visual and final candidate evidence is incomplete.
Named supporting checks have passed above; pending capture comparisons remain
**Not Run**. Neither source presence nor those focused passes alone closes a
full row. The requirements retain the revision 2 package contract.

| ID | Acceptance requirement | Full status | Supporting evidence / remaining check |
|---|---|---|---|
| CC-01 | New layout/FX are confined to Compute Cores and direct support. Outside it, only authorized palette values/bindings change; navigation, services, layout and behavior remain intact. | **Open** | Final chip/color/support diff and matched structure captures pending. |
| CC-02 | Approved detailed top-down package/die/contact/trace appearance is recognizable at normal size. | **Open** | Layout and fragment source present; native reference crop comparison pending. |
| CC-03 | The removed lower metric-card grid is absent. | **Open** | New chip content has no metric-card grid; integrated native captures pending. |
| CC-04 | CPU name is the actual GUI-host identity, including variant; never a baked M3/M4 label. | **Open** | Initial pure projection preserves host names; native observed identity/variant readback remains pending. |
| CC-05 | GPU name and sampled activity refer to the same verified device or clearly show unavailable association. | **Open** | Eight provenance cases and the initial exact-registry/unmatched projection case passed; complete single/multiple-device native fixture readback remains pending. |
| CC-06 | Unknown/model-ID/long names render honestly and without truncating away meaningful variant information. | **Open** | Name-preserving projection and native labels present; long/model-ID/unknown capture fixtures pending. |
| CC-07 | A single busy logical CPU changes its stable local region, not unrelated CPU regions. | **Open** | Initial single-logical-processor envelope case passed; whole-view frame comparisons stopped at AX prerequisites and remain unqualified. |
| CC-08 | Equal valid CPU samples are not mistaken for fallback; fallback samples are not called per-core measurements. | **Open** | Eight provenance and initial equal-measured/fallback/warming/unknown projection cases passed; the expanded ten-case pure suite also passed; whole-fixture confirmation remains open. |
| CC-09 | CPU topology is runtime-derived; P/E mapping is not inferred from array order or model strings. | **Open** | Initial bounded layout and oversized logical-topology cases passed without inferred P/E mapping; final source/host capture acceptance remains open. |
| CC-10 | GPU regional illumination follows the valid aggregate envelope; individual lit blocks are not reported as measured core activity. | **Open** | The 1.022-second native aggregate fixture passed 0/12/82% strict luminance increase for all 16 illustrative regions; three drawable PNGs were reviewed. Whole-component labels/composition and missing-source fixtures remain open. |
| CC-11 | Trace heads visibly travel through turns on fixed routes with fading tails. | **Open** | Initial deterministic polyline-corner/phase/pulse-bound case passed; actual native moving-trace recording remains pending. |
| CC-12 | Idle, warming up, stale, paused and unavailable remain distinct. No missing source is shown as healthy zero. | **Open** | Quality/freshness/pause labels present; new native state matrix pending. |
| CC-13 | CPU and GPU source timestamps are handled independently; old GPU data does not become fresh on every CPU frame. | **Open** | Core timestamp retention and initial independent CPU/GPU stale-channel cases passed; fresh whole-view staleness captures remain pending. |
| CC-14 | No recurring animation submissions when scrolled offscreen, minimized, fully hidden/occluded or detached. | **Open** | Initial native offscreen/order-out no-submission and detach/release checks passed; fresh five-case native suite also passed minimize/occlusion/reopen; final candidate/whole-view confirmation remains open. |
| CC-15 | Reentering/reopening resumes once from current state without duplicate timers, views or listeners. | **Open** | Initial native resume-once/resource-release checks passed; the fresh five-case native suite also passed twelve reopens with zero retained surfaces/clocks/buffers after release; final candidate/whole-view confirmation remains open. |
| CC-16 | Reduce Motion disables moving pulses while keeping detailed chips and valid static activity shading. | **Open** | Initial native pause/Reduce Motion no-recurring-clock checks passed; detailed whole-view static shading and motion comparison remain pending. |
| CC-17 | No pointer interception or per-frame accessibility announcements; existing semantic IDs remain. | **Open** | Native label IDs and hit-testing source present; complete existing-ID/pointer/accessibility parity pending. |
| CC-18 | Small/large windows, 1x/2x where available, long text and topology changes do not clip/overlap. | **Open** | Responsive layout and wrapping label source present; size/backing-scale/long-name matrix pending. |
| CC-19 | Rendering uses bounded geometry/pulses/buffers with no in-flight buffer overwrite or main-thread GPU wait. | **Open** | Initial bounded geometry/pulse and native seven-buffer/three-slot reuse/release assertions passed; final source and steady-state cost review remain pending. |
| CC-20 | No production demo samples, hardcoded core counts or remote-provider hardware substitution. | **Open** | Host-origin collectors and projection source present; final fixture-isolation audit and native host proof pending. |
| CC-21 | Genuine Metal/pipeline/resource failure has a static native nonblank fallback with truthful status; no CPU animation substitute or false completion. | **Open** | Static native fallback source present; injected failure and nonblank capture pending. |
| CC-22 | Shader/resources are compiled and packaged in the canonical native candidate; relevant builds/tests pass. | **Open** | Initial native test host completed compiled chip commands with named functions and nonempty library origin; final ordinary build/library packaging and candidate identity remain pending. |
| CC-23 | Version/docs/membership follow current policy without reviving old packages or modifying the working installation. | **Open** | Draft docs retain 0.17.0 (27); final hygiene/membership/candidate identity/publication pending. |
| FX-01 | Independent chip illumination, glow and trace travel execute through Metal + MetalKit in the normal candidate. | **Open** | Initial native completed command/function evidence passed; final normal-candidate identity and actual traveling-trace recording remain pending. |
| FX-02 | New shader source is compiled at build time and the produced library/functions load in the delivered app; no new runtime source compiler. | **Open** | Initial compiled-library/function-load assertions passed in the native test host; final ordinary build/package/load receipt remains pending. Static fallback alone does not pass. |
| FX-03 | SwiftUI/AppKit remain the labels/control layer; no per-core Metal views or competing CPU/SwiftUI particle engine; clocks elsewhere unchanged. | **Open** | One canvas/native label source present; final ownership/lifecycle/unchanged external-clock review pending. |
| PAL-01 | Every current primary route and app-owned secondary presentation uses the shared Graphite Workbench palette. | **Open** | Source route/presentation inventory below; current-palette native coverage pending. |
| PAL-02 | Outside Compute Cores, layouts, sizes, typography sizes, controls, data, navigation and workflows remain unchanged. | **Open** | Binding-only secondary delta reviewed; final whole-scope structure and interaction comparison pending. |
| PAL-03 | Blue selection, mint action, cool readable text, graphite fields/panels and steel boundaries match the approved color reference. | **Open** | Shared semantic sRGB targets present; approved-board native comparison pending. |
| PAL-04 | Warning, destructive, denial/error, busy, disabled and unavailable states retain meaning and readable contrast. | **Open** | Initial eleven Graphite cases include numerical contrast; representative current warning/error/disabled/busy/unavailable/destructive native states remain pending. |
| PAL-05 | Native app/scene appearance is consistent across windows and sheets; Increase Contrast/Reduce Transparency work without system-setting writes. | **Open** | All nine minimum Settings sections passed and fourteen PNGs were reviewed; full current access-setting/secondary-window appearance matrix remains pending. |
| PAL-06 | Palette is implemented through the current shared owner or a minimal native owner if none exists; no duplicate theme framework or new picker. | **Open** | Existing GraphitePalette owner reused; final complete consumer/diff verification pending. |


## Historical initial native capture matrix

The revision 2 `verification/capture-plan.json` specifies 18 capture gates.
The aggregate GPU drawable readbacks provide partial CAP-04 evidence; its
whole-component composition remains open. Other full chip/FX/current-palette
capture gates remain **Not Run**. Fourteen Settings minimum images are bounded
supporting palette coverage, not the complete supporting-presentation matrix.
Earlier captures in other result bundles do not fill the current matrix.

| ID | Capture | Status |
|---|---|---|
| CAP-01 | normal | Not Run |
| CAP-02 | idle | Not Run |
| CAP-03 | cpu-single-region | Not Run |
| CAP-04 | gpu-aggregate | Partial — actual 0/12/82% production drawable readbacks and three-image review passed; whole-component capture open |
| CAP-05 | missing-gpu | Not Run |
| CAP-06 | cpu-fallback | Not Run |
| CAP-07 | reduced-motion | Not Run |
| CAP-08 | narrow-window | Not Run |
| CAP-09 | long-names | Not Run |
| CAP-10 | scroll-hidden | Not Run |
| CAP-11 | restore | Not Run |
| CAP-12 | movie | Not Run |
| CAP-13 | metal-execution | Not Run |
| CAP-14 | palette-all-current-routes | Not Run |
| CAP-15 | palette-secondary-presentations | Not Run |
| CAP-16 | palette-interaction-states | Not Run |
| CAP-17 | palette-accessibility | Not Run |
| CAP-18 | palette-native-appearance | Not Run |

## Historical initial delivery gate — OPEN at that checkpoint

Pending closure includes final canonical source/shader/resource membership;
relevant product and native builds; actual compiled library/function loading;
new projection/identity/animation/lifecycle/resource tests; native package
fidelity, localized activity and traveling-trace recordings; zero recurring
hidden/detached animation and stable reopen ownership; responsive/long-name/
backing-scale checks; fallback failure injection; complete current-palette
routes, secondary/state/appearance/accessibility captures; and final matched
source/candidate identities, required documentation and authorized publication.
The earlier Settings minimum failure remains explicit; the later one-case
pass and fourteen-image review close that size gate for its inputs. Other
Graphite and current Compute/palette gates remain open. No installation, signing-policy change, notarization or
distribution is authorized by this documentation draft.


## Rejected material and exact-reference transition

These are prior-source checkpoints, not qualification of the current exact
reference replacement. The two 1254×1254 approximate unlit materials were
rejected by the owner; archived originals remain under
`/tmp/forge-compute-material-checkpoints/source-assets`. `ComputeCPUUnlit.png`
had SHA-256 `5839cf101553bf3f05315a5fdf931a6e8ab6863e091487aeb4220f7038b0f3e0`;
`ComputeGPUUnlit.png` had
`f5c9ea8573efed0dbfd35aaff10f5c05ddc2d79ef24ab2aae6d241fc12801940`.
The pre-shadow 435-input manifest was
`65e2f621493652360abe80ef16cb5d560b308b12d5af6cbdaf72bde1a517466c`,
audit `d9cf06204446f541ace5631cd0bfccd288539326209f2b23bfbf0b21c94d9f0e`.
The post-shadow/pre-fallback 435-input manifest was
`4c7021f28d9de82da31daf0ea5ab7ffdde5722f4654530012d23b756166c4b4a`,
audit `3f1e5d40be182bfc4651dc87c32594220376f3bfaa998b6aa6d1f362a9052f3f`;
both used project `93da182a32427f8308ce746da8aa595366c1bfa88ca6ac58d5e2d1b1837333ce`.
Their immutable receipt copies remain in `build/graphite-results` with the
`compute-material-post-shadow-` prefix. Neither is the current audit.

After the shadow/CGImage/text corrections and before the artwork rejection,
these separate selections passed:

| Selection | Actual result | Scope and boundary |
|---|---|---|
| `final-text-fit-compute/events.jsonl` | Public direct-XCTest; terminal 0, **26 executed**, 0 failures/skips, **23.970 seconds**, matching observers, 0 issues | Pure Compute 13, native lifecycle 6, presentation 7. Rejected-art input only. |
| `final-text-fit-apphost-regressions/events.jsonl` | Public direct-XCTest; terminal 0, **68 executed**, 0 failures/skips, **25.603 seconds**, matching observers, 0 issues | Graphite 11, Guided Mode 3, review 7, legacy gauge 7, project contract 16, Provider 24. |
| Canonical `ProviderConfigurationAppTests` | Native My Mac `xcodebuild` app-hosted test; terminal 0 / `TEST SUCCEEDED`, **33 executed**, 0 failures/skips, **4.879 seconds** | Exact original app-host path; 24 Provider cases overlap the preceding 68. |

The two public selections are under `/tmp/forge-direct-xctest-host`.
The canonical Provider log, `ProviderConfiguration.xcresult`, process receipt
and test summary are under
`build/graphite-results/provider-canonical-checkpoint-20261004-181430`.
The union is **103 distinct cases, 127 executions**, including **24 repeated
Provider cases**. This is deduplicated selected checkpoint coverage, not one
103-case invocation, a full-suite result or current artwork acceptance.

The earlier `regressions-material-shadow` public host invocation failed:
**77 executed, 9 unexpected failures, 0 skips**, terminal 1. A separate
`/tmp/forge-direct-provider-xctest-host/final-text-fit-cli-provider/events.jsonl`
attempt also failed all **9 executed** CLI-dependent cases, terminal 1.
The noncanonical AppTests identity did not meet the existing development host
exception; no product identity/trust rule was changed. The proper canonical
Provider path then passed all 33. Failed attempts remain failed and are not
added to the passing checkpoint total. Signature-only comparison retained
identical bytes outside `LC_CODE_SIGNATURE` during the canonical rebuild.

Independent exact-reference comparison still found the rejected GPU frame
cutouts, near-uniform pale-violet lights and repetitive dim fanouts unlike the
owner target. `build/graphite-results/compute-exact-reference-current-fidelity-secondary-review.json`
and `compute-material-secondary-pixel-review.json` retain exact image/source
hashes and findings. The first and refined exact-reference one-case pilots,
new 434-input audit and outstanding fidelity/candidate gates belong in the
[active record](COMPUTE-CORES.md#exact-reference-native-pilots--retained-checkpoint).


## Exact-reference pilot history

These actual earlier outcomes remain attached to their exact inputs; a later
pass does not convert a failed pilot into a pass. Events/receipts are under
`/tmp/forge-direct-xctest-host` with each selection name below.

| Selection | Actual result | Observed outcome / boundary |
|---|---|---|
| `exact-reference-material-pilot` | 1 executed, 0 failures/skips; terminal 0; 3.126 seconds; matched observer 0 issues | First exact-crop material pass; dim light, leader remnant and cyan plate artifact still observed. First-process Debug lookup 2.065456s. |
| `exact-reference-refinement-material-pilot` | 1 executed, 0 failures/skips; terminal 0; 1.461 seconds; matched observer 0 issues | Native CGPath/mask/plate refinement; first-process lookup 0.409334s. Asymmetric contact coverage and weak local illumination remained observed. Earlier inventory 434 source 846f5508ef5093003f9707d282ac297ca307c3dde5ea33563418792cbc866348 / audit a0610f6216b14782b4ecdb76bad3013d01ad9488a815b7147000566e61b954df is a checkpoint. |
| `exact-reference-illumination3-material-pilot` | 1 executed, 3 assertion failures, 0 skips; terminal 1; 1.422 seconds | Three violet mean-red>mean-green assertions failed; GPU banks 1/5 visually used mint unlike the reference blue/cyan. Asymmetric mask repair was separately exercised. This pilot did not pass. |
| `exact-reference-illumination4-material-pilot` | 1 executed, 5 assertion failures, 0 skips; terminal 1; 1.467 seconds | Five raw-reference versus NSColor-converted RGB expectations failed. Reference color-domain boundary was investigated; the next check compares the same explicit raw domain at unchanged 0.01 tolerance and retains converted plus raw preservation assertions. No production color-space policy change. |

The immutable first/refined audit copies retain the
`compute-exact-reference-{membership,source-input}-checkpoint.json` names.
The third/fourth fidelity and fourth occupancy JSON receipts remain in
`build/graphite-results`; their exact findings and input identities remain
historical. The fifth pilot and fresh current 26/68 selections are recorded in
the [active record](COMPUTE-CORES.md#fresh-corrected-source-selected-checks).
Complete composed views, current candidate/workflows and delivery are separate.


## Earlier material, candidate and manual checkpoints

The retained snapshot below predates the current corrected exact-reference
26/68/canonical-33 selections. Its pending statements describe that checkpoint,
not the latest results. The active [Compute record](COMPUTE-CORES.md) owns current
source, native fixture, layer-review and open composed/candidate gates.

## Material fixture checkpoint — shadow and fallback artwork OPEN

Separate public direct-XCTest material selections each ended with terminal
exit **0**, zero failures/skips and matching observer counts with zero issues:
pure Compute **13** (0.016 seconds), native lifecycle **6** (11.239 seconds),
and presentation **7** (13.986 seconds). These are **26 distinct selected
cases**, before the shadow/fallback corrections, not an XCUITest, ordinary
candidate or full application composition pass. Exact events are
`/tmp/forge-direct-xctest-host/{pure,native,presentation}-material/events.jsonl`.
The earlier 25-case reduced selection is separate and is not added to this one.

Independent review actually opened all **64 PNGs** in
`/tmp/forge-direct-xctest-host/presentation-material-attachments`: eleven whole
state Metal/native-cache pairs, three GPU intensities, two CPU localization
images, eight capability images, five material/hue/resize/reopen images,
twenty genuine motion frames plus reference/cache, and two fallback caches.
Detailed upright steel/machining, contacts and passives are visible in Metal.
GPU activity changes blue to mint to violet while increasing brightness; a
single CPU region changes locally. Motion heads/tails change while artwork
stays fixed. Full wrapped identities, state/provenance, engine row, legend and
footer remain readable in the separate native caches. These layers are not
compositor screenshots. `build/graphite-results/compute-material-secondary-pixel-review.json`
retains each opened path/hash, source/resource boundaries and findings.

The first Metal images showed rectangular black poster shadows; both genuine
fallback caches contained labels/cells/traces without detailed steel artwork.
The alpha-silhouette and explicit CGImage corrections received later selected
checks, but the owner then rejected the approximate art for its cutout GPU
frame, weak uniform lighting and trace appearance. The first 26 passing cases
did not assert fallback detail. Exact rejected-source results and the later
103-distinct-case checkpoint are preserved in
[transition history](COMPUTE-CORES-CHECKPOINTS.md#rejected-material-and-exact-reference-transition).
None qualifies the exact-reference replacement or closes final composition,
all-view, ordinary workflow or publication gates.

## Current ordinary candidate

**Checkpoint before the artwork/telemetry-color correction; requalification open.**

The canonical My Mac Debug build finished with terminal exit **0** /
`BUILD SUCCEEDED`, recorded in `/tmp/forge-compute-current-ordinary-build.log`.
This ordinary app is fresh for the recorded 433 frozen inputs, including the
High activity semantic-violet label correction. Root verified its strict deep Apple
Development signature for team `9AQ2C2838M`, version **0.17.0 (27)** and
compiled chip functions. `build/graphite-results/ordinary-candidate-identity.json`
records:

| Identity | Observed value |
|---|---|
| App | `build/graphite-app/Build/Products/Debug/Forge Conductor.app` |
| Frozen source | 433 inputs; `ce8b3a03c45692cad4148809e1eb697c88093ebe411a22ba59048d8228922868` |
| Membership | 14/14 checks; canonical project SHA-256 `4e764048c6431d59832903dbee8c83a0590fc769b8b7caa5f3eb09fa5391984a` |
| CDHash | `bf495e68ab1bbc9e509efe1de863af931b7e32f4` |
| Bundle manifest | `febb576a4c0d365f5fd0b7ac7b02fa9dda98b9e648c2902c08fc4eceb361e15a` |
| Compiled library | `Contents/Resources/default.metallib`, 16,904 bytes; `b884642df3cadd6ef16b874b32e2a63c2741dcefac376f9b9f2bbde0c1ba3ff5` |
| Compiled functions present | `compute_chip_vertex`, `compute_chip_fragment` |

These are build/signature/packaging results. The actual current library load,
full native QA and four ordinary onboarding/export workflows remain separate
open gates. No test-host result qualifies the ordinary candidate by identity
alone. Previous candidate hashes remain in the linked checkpoint records.

## Ordinary native export checkpoint

Against exact `bf495e68…`, root exercised actual native Diagnostics → Export
JSON + Markdown → NSOpenPanel → focused exact private folder → Export Here.
The bootstrap-failure case, PID 23495, completed **3 records**; the healthy
real-Manager case, PID 23617, completed **8 records**. Both paired exports passed
content/scope/redaction verification, and independent receipt/hash audit matches
all four recorded artifact hashes. Both used 1440×932 outer / 1440×900 content
geometry. Failure footer title/version/error owners were each unique; raw AX
reported zero errors. Healthy Manager served HTTP 200 from the exact isolated
home/port and original Compute accessibility owners were each unique.

Receipts are `/tmp/forge-production-manual-{failure,healthy}-current-v2/`;
`build/graphite-results/ordinary-manual-export-current-checkpoint.json` records
the exact pairs, hashes and evidence boundaries. Cua screenshots were actually
viewed inline; durable compositor image files are unavailable. This is manual
native interaction/public-AX/export verification, not XCUITest. The failed-home
process quit and seven registration bytes remained unchanged. Its disposable
defaults domains read back as empty persistent dictionaries with no keys, not
absent domains. Root confirmed normal Quit ended healthy PID 23617; its seven
registration artifacts remained byte-identical and three owned isolated
persistent defaults domains had zero keys. Folder/shell workflows and the
corrected-geometry candidate repeat remain pending.

## Reduced geometry checkpoint — fidelity OPEN

Before the new image/lighting inputs, separate public direct-XCTest selections
passed pure Compute **13** (0.011 seconds), native lifecycle **6** (10.137 seconds)
and presentation **6** (11.961 seconds): 25 distinct selected cases with zero
failures/skips and terminal exit 0 in each selection. Their exact events are
`/tmp/forge-direct-xctest-host/{pure,native,presentation}-reduced/events.jsonl`.
These support the earlier 40% source checkpoint, not the new material inputs.
The presentation selection passed **6 executed, 0 failed, 0 skipped**;
observer counts matched with zero issues. Its selected scopes were bounded
20-frame genuine Metal trace motion, single-CPU localization, sixteen-region
GPU illumination, eleven whole-component states, genuine static fallback and
separate/combined accessibility capabilities. This is native fixture evidence,
not XCUITest or ordinary-candidate qualification.
`/tmp/forge-direct-xctest-host/presentation-reduced/events.jsonl` retains exact
original dylib/test/shader identities. Overlapping checkpoint cases are not
summed, and earlier failed acquisitions/measurements remain recorded.

Independent review opened that checkpoint’s equal-measured Metal drawable and
long-name native structure cache. Compact dimensions, grouped four-side pins
and the eight-center/eight-violet-flank GPU arrangement are present; complete
native identities/state/engine/footer text is readable. At that checkpoint, reference fidelity remained insufficient: sparse long
surrounding routes and uniform nested metal bands lacked the required PCB
detail and local machining/shadows. The
two captures contain separate Metal/native layers, so composed-image quality
is not inferred. `build/graphite-results/compute-compact-source-and-reduced-pixel-review.json`
retains exact source snapshots, image hashes, findings and this passing support
checkpoint. Further material/geometry changes require affected fresh checks;
all final acceptance/delivery gates remain open.

The exact twenty production Metal drawable PNGs were also encoded into
`/tmp/forge-compute-motion-qa/compute-reduced-production-motion-verified.mov`:
Apple ProRes 4444, 20 samples, 6.375 seconds, SHA-256
`a9cce31501db3899046484198cc0455506c24caa7574a782b15cc6ab815434b9`.
Its JSON receipt retains original PNG hashes/completion timestamps and records
no generated/interpolated frames. This is a prior genuine drawable sequence,
not a whole-window recording or proof of the latest image/color inputs.

## Previous ordinary-build checkpoint

The earlier `/tmp/forge-compute-ordinary-final-build.log` ordinary build qualified
433 inputs, manifest `701ad80e46ee1f728c58f4f90706d677edfd0b93daf204d5dcbab2ab8533674a`,
CDHash `fc506017c1a6a51f2e944b787cd4496f80c24c35` and bundle-manifest SHA-256
`a2ea83cc818be31701b89c5a299b7d7086e025c14264c2943abf240b11e94006`.
It predates the High activity semantic-label correction. It passed build,
signature and shader packaging only; no current ordinary runtime workflow is
inferred from that prior candidate. The compiled shader hash is unchanged.

## Latest execution and manual boundaries

The latest app-hosted invocation (`compute-components-current.xcresult`,
`/tmp/forge-compute-components-current.log`) exited **65**: **100 cases,
97 passed, 3 failed, 0 skipped**. Selected passing scopes were pure Compute 12,
native Compute lifecycle 6, Graphite 11, Guided Mode 3, read-only review 7,
legacy gauges 7, OperatorProjectContractTests 16 and Provider 33. Of five
presentation cases, CPU/GPU Metal pixels passed; one semantic-capability
observation failed and two screenshot acquisitions were unauthorized. The
final restarted 77-case log summary is not the overall invocation. Later
material/fallback inputs and the final full view gates are not qualified by
that failed checkpoint. The public direct-XCTest pilot below now has one passing GPU fixture; it does
not turn that earlier failed batch into a pass.

Root reported manual normal-size screenshots of Dashboard Compute, MCP,
Agents, Tools and Live Feed, plus Tools `shell` **3/71**, nonexistent **0/71**
and clear-filter behavior. Detailed normal chip plates/glow/changed trace
frames and complete footer were reviewed. This is **manual native QA, not an
XCTest pass**; exact capture/geometry/launch fields and the remaining matrix
are in the [native QA checklist](GRAPHITE-NATIVE-QA.md). All other current
routes, minimum sizes, Settings/wizard and conditional states are pending.
Two newer XCUI runners executed zero cases due to automation authentication;
Cua's own AX parser crashed while Forge remained alive. The earlier observed
Projects route/raw AX receipt is separate from the latest stale-index attempt:
fresh AX for that attempt showed Dashboard, so it does not establish a Projects
parser cause. No OS/service policy weakening is used to close a gate.

Historical Core 35, initial chip/Graphite 23, expanded app-hosted 76, legacy
resize, minimum Settings, aggregate GPU pilot and failed baseline receipts
retain their exact inputs/results in
[Compute checkpoints](COMPUTE-CORES-CHECKPOINTS.md) and
[Graphite checkpoints](GRAPHITE-WORKBENCH-CHECKPOINTS.md). Overlapping runs are
not added together. The earlier 19-case ProjectsViewModelResetTests and current
16-case OperatorProjectContractTests are different classes.

## Public direct-XCTest native GPU pilot

The supported native fixture loader executed
`ComputeChipPresentationAppTests/testAggregateGPUProductionMetalIlluminationIncreasesWithoutMeasuredCoreClaims`:
**1 executed, 0 failed, 0 skipped**, terminal exit 0, **0.771 seconds**.
Observer start/finish counts matched with zero issues. This is **public direct-XCTest
native-fixture evidence**, not an `xcodebuild`/testmanager or XCUITest pass.
`/tmp/forge-direct-xctest-host/gpu-pilot-4/events.jsonl` records the original
production dylib SHA-256
`03bb6a8ca2f4e55c3aa616e65c03a76347d7609c67acdbc695b42dcb30f3a7bf`,
shader SHA-256 `b884642df3cadd6ef16b874b32e2a63c2741dcefac376f9b9f2bbde0c1ba3ff5`
and test binary SHA-256
`fae4cd7c0c4e8c24d9b5b4774d599f975a613fcab5bf4f01f651ded906116b24`.
The three genuine production drawable PNGs at 0/12/82% passed sixteen-region
strict illumination comparisons; root reviewed all three. Attachments are in
`/tmp/forge-direct-xctest-host/gpu-pilot-4-attachments`.
The separate `presentation-current/events.jsonl` batch exited **1**: **4 executed,
3 passed, 1 failed, 0 skipped**, 4.664 seconds. Single-CPU localization, eleven
whole-component quality/name/freshness states and controlled accessibility
capabilities passed. Genuine-Metal-failure fallback failed with 18 versus 16
regions and then an empty inset region. `ComputeChipLayout.make` emits sixteen
GPU die cells plus two 4-point decorative banks sharing IDs 256/257; the test's
broad kind/ID filter included those banks. The measurement correction and fresh
fallback rerun remain pending; this failed batch is retained.

The separate `native-current/events.jsonl` batch exited **0**: **6 executed,
0 failed, 0 skipped**, 10.165 seconds, with matching observer counts and zero
issues. It exercised compiled commands/buffer reuse, offscreen/order-out clocks,
one in-flight/latest-only readback, pause/Reduce Motion, minimize/occlusion/reopen
release and main-actor power notification ownership. Phase JSON records paused
1.535 seconds with zero submissions/clocks and 0.271% one-core process CPU;
visible 1.500 seconds with 45 submissions/completions, one clock and 1.818%;
scrolled hidden 1.542 seconds with zero submissions/clocks and 0.493%.
Last visible GPU duration was 0.656 milliseconds. CPU scope includes other
application-host work; these are not renderer-only CPU measurements or a
long-duration steady-state qualification.

`legacy-current/events.jsonl` separately exited **0**: **7 executed, 0 failed,
0 skipped**, 23.367 seconds, matching observer counts and zero issues. These
public direct-XCTest native fixtures retain their original binary
identity. Drawable-only evidence does not establish separately composed native
labels, moving-trace recordings, full palette QA or ordinary candidate workflows.

Root also reviewed actual NSView-cache images from the presentation selection:
`070-compute-native-fixture-long-names-native-view-cache.png` retained full CPU
identity on three lines and GPU identity on two, with active/engine/footer/legend
contained; `040-compute-native-capability-combined-native-view-cache.png` showed opaque canvas, readable
fields, blue focus/selection, mint/pink/disabled controls and no overlap. These
are native structure cache pixels, with genuine Metal blits retained separately;
they are not compositor screenshots or a full-route appearance pass.



## Corrected reference checkpoint before equal project actions

The corrected-art source manifest was
`453b2d2e35e03f7854f27ce41c9f7b6ad43b9678efddf00b5ad037d0add69575`,
audit `015ab9122f060549ab8973f2c3b5e5faabe1690e485f0aeeb670f454430126ef`:
15 checks, 434 inputs, 30 resources, unchanged canonical project. Immutable
`compute-corrected-reference-{membership,source-input}-checkpoint.json` copies
retain that boundary. Compute 26 (23.371s), regression 68 (25.697s) and proper
canonical Provider 33 (4.881s, command7.879s) passed separately:103 distinct
cases in 127 successful executions,24 Provider repeats. The combined receipt
is `build/graphite-results/exact-reference-final-provider-canonical/combined-current-qualification.json`,
SHA-256 `72866d7118f2567129f1a548467800c1921d0d5fb8629d1817a4ee7d546be608`.
This is selected coverage, not one full-suite or ordinary workflow pass.

The subsequent 113-image native view checkpoint identified unequal Projects
action sizes and setup step 3 copy naming a control differently from its actual
visible label. It did not close final all-view acceptance. Two local view repairs
standardized the seven primary Projects actions to 220×32 and changed the step 3
instruction to **Add Project Folders…**. Current requalification and unchanged
Compute review/movie reuse are in the [active record](COMPUTE-CORES.md#fresh-corrected-source-selected-checks).

The first current `G1G10AcceptanceTests/testG3_VersionAndReleaseDocumentsAreAligned`
attempt executed one case and failed one assertion because XCODE.md lacked its
exact current-authority marker. `equal-project-actions-final/g1-version.log`
retains the failure. The document marker was restored without changing the test
or product identity. The subsequent unchanged focused test passed one actual
case with zero failures/skips (0.010s; command 1.980s), terminal 0, in
`equal-project-actions-final/swift-g1-version-marker-rerun.json`. The original
failed log remains retained.


## Equal project actions checkpoint before lifecycle transitions

The following active record is retained exactly for source c4de77… before the
fallback/trace and empty-Projects follow-up. Its pending text records that
checkpoint, not current dispatch or current acceptance.

## Current material source audit

The latest completed exact-reference audit passed **15/15** checks over
**434 inputs**, source manifest SHA-256
`c4de77cca979890a4367c7eaa4820fd3c9295849af5589b260b35e15f6d44867`. Independent readback matched
all 434 listed file hashes. Canonical project SHA-256 is
`a5ecf9dc66845891929ac5de31820a22a355dabb38668dd93ce3849f9f069b1d`; audit SHA-256 is
`dcd5948af5ac519dd01588cd50d87f714e62454fb723769d15273a6aeb2dae21`. Immutable checkpoint copies are
`build/graphite-results/compute-equal-project-actions-{membership,source-input}-checkpoint.json`.
This records source/resource inputs, not final visual or runtime acceptance.

There are **30 resource inputs**: all original 29 memberships remain, 28 original
byte sets are unchanged, the requested Guide catalog copy retains its schema,
and exactly one app/native/SwiftPM PNG is added. All 26 signing/deployment
configurations retain their settings. The earlier 435-input/two-material
audits remain linked [checkpoints](COMPUTE-CORES-CHECKPOINTS.md#rejected-material-and-exact-reference-transition).
The corrected-source selected checks and matching ordinary build/signature
are recorded below. Ordinary runtime workflows and full native-window QA
remain pending.

## Exact-reference native pilots — fidelity OPEN

The fifth public direct-XCTest material pilot passed **1 executed, 0 failures,
0 skips**, terminal exit 0, **1.422 seconds**, with matched observers and zero
issues. Its separate first-process native resource lookup measured **0.374332
seconds on the main actor in Debug**. This is one cold lookup, not steady-state,
release-configuration or renderer-only CPU proof.

The current native assertions compare reference and observed samples in the
same raw RGB domain, retaining the 0.01 mean tolerance, prior converted-material
checks and new raw-byte preservation/asymmetric-contact sentinels. ImageIO's
native sRGB context preserves the untagged reference bytes; an NSColor
conversion reports different components. No production color-space policy was
changed. The third and fourth failed pilots remain failed in
[exact-reference history](COMPUTE-CORES-CHECKPOINTS.md#exact-reference-pilot-history).

The independent fifth-frame review opened the reference and actual 12/50/82%
Metal drawables. Continuous rectangular photographic GPU frame, fine grain,
asymmetric gold contacts, clean plate/leader areas, blue/cyan central and violet
flank fields, localized white highlights and increasing activity response were
observed. It found no remaining blocking material defect in those inspected
frames. `build/graphite-results/compute-exact-reference-illumination5-fidelity-review.json`,
SHA-256 `eb78b31754e936bdd95b1774a8fc81c2b4b4093e25e31d62787dfae1622dd37a`,
retains exact image hashes, color domains and remaining-verification limits.
This selected review does not establish full component composition or arbitrary
host/hardware acceptance.

## Fresh corrected-source selected checks

After the Projects action-size and Guided Setup copy repairs, each selection
ended with terminal exit 0 and zero failures/skips. Both public direct-XCTest
selections had matching observers and zero issues; the proper canonical
Provider selection ended with `TEST SUCCEEDED`.

| Selection | Actual result | Named classes / evidence class |
|---|---|---|
| `equal-project-actions-final-compute` | **26 executed**, **23.485 seconds** | Public direct-XCTest: pure Compute 13, native lifecycle 6, presentation 7 |
| `equal-project-actions-final-apphost-regressions` | **68 executed**, **25.613 seconds** | Public direct-XCTest: Graphite 11, Guided Mode 3, review 7, legacy gauges 7, project contract 16, Provider 24 |
| Canonical `ProviderConfigurationAppTests` | **33 executed**, **4.877 seconds** suite elapsed | My Mac native `xcodebuild` app-hosted; command 7.969s, actual cases 4.871s |

The union remains **103 distinct selected cases in 127 successful executions**,
with 24 repeated Provider cases counted once. These are separate evidence
classes/selections, not one full-suite invocation.
`build/graphite-results/equal-project-actions-final/combined-current-qualification.json`
(SHA-256 `711dfc3461d34824482c6c3c79562328c2ca3831c2732d8fcec7bd2ceb65d121`)
retains the current source/counts and direct receipts. Direct events/attachments
are under `/tmp/forge-direct-xctest-host/{selection-name}{,-attachments}`;
canonical log/summary/result bundle are under
`build/graphite-results/equal-project-actions-final-provider-canonical`.

Separately, current SwiftPM CLI/app commands ended with exit 0 in 3.926/3.688s.
Core provenance actually executed **8 cases, 0 failures** (0.035s suite elapsed);
the H0 version contract actually executed **1 case, 0 failures** (0.016s).
The initial G1 document-version case executed **1 case, 1 failure** for a missing
XCODE.md marker. After restoring the exact marker without changing the test,
the focused rerun passed **1 actual case, 0 failures/skips**, terminal exit 0,
0.010s case time (1.980s command). The adjacent
`swift-g1-version-marker-rerun.json`/log retain the result; the original failure
remains in checkpoint history.
`equal-project-actions-final/swift-current-command-receipts.json` and its exact
logs record these outcomes. Zero-selected auxiliary bundles are not passes;
these separate checks are not added to the 103-case union.

Projects source now gives the seven primary actions the same 220×32 source-body
presentation. Actual native AX bounds for all seven are 221×33; the temporary
fixture assertion was corrected to preserve equality, visibility and tolerance
against those observed bounds, with its initial failed attempt retained. Guided Setup step 3 says **Add Project Folders…**, matching its
visible control. Actions, identifiers and eligibility predicates remain.
The preceding 113-image view checkpoint exposed both defects; renewed current
primary/secondary/size/state review remains pending. Compute sources, resources,
tests, Core and build inputs are identical to the accepted 453b… checkpoint:
`equal-project-actions-final/compute-input-reuse-proof.json` records the exact
two changed paths. The 65-layer review and drawable movie below are reused only
for that unchanged Compute scope, not the two repaired views.

## Current Compute layer review and motion

Independent review opened all **65 Compute checkpoint PNGs**, reused by the exact unchanged-input proof above: 27 production Metal
drawables, 16 actual native-structure caches without Metal, 20 genuine Metal
motion frames and 2 native static fallback caches. No blocking visual defect
was found in their covered layers. Exact opened paths/hashes and observations
are in `build/graphite-results/compute-exact-reference-final-pixel-qa-review.json`,
SHA-256 `f298cb8dbc44f3757f49936e7faa92386ca736031bdac8af933700173f68734a`.
Wrapped identities, eleven quality/freshness states, local CPU isolation,
aggregate GPU hue/brightness, detailed fallback, separate/combined capability
states and resize/reopen imagery retain their specific reviewed boundaries.

The native pause/Reduce Motion receipt reports **0 active clocks**, **0 animation
frames** and **2 completed static frames**; no dedicated paused PNG is claimed.
Native NSView caches omit Metal and are not compositor screenshots; paired
readbacks do not establish a composed window. Controlled capability fixtures
are not actual SettingsScene or system-preference acceptance.

The 20 production drawable frames were also encoded by native AVAssetWriter
into `/tmp/forge-direct-xctest-host/exact-reference-final-compute-production-motion.mov`:
**23,894,585 bytes**, SHA-256
`3b53d22b5ab6b44bff104de672aa03ac10de5c136b47d37640fcaf382c5c881d`.
Encoding ended with terminal exit 0. The paired `.mov.json` records all 20
original PNGs, presentation times and decoded RGB/orientation samples; no
generated/interpolated frames are used. This is typed-fixture drawable motion,
not a whole-window or measured-host-workload recording. Full route/size/state
QA, SettingsScene, composed-window fidelity, matched ordinary workflows and
publication remain open.

## Current view-fixture checkpoint — full QA OPEN

Six current public direct-XCTest production-view cases ended with exit 0, one
actual case each, zero failures/skips and matching observers/no issues. Two
independent receipts record all **157 PNGs actually opened**: 155 native view
caches without Metal and 2 separate production drawables, no compositor frame.

| Current native fixture method | Case seconds | Reviewed PNGs |
|---|---|---|
| `testCaptureAllThirteenCurrentRoutesAtNormalAndMinimumSizes` |22.721|26|
| `testCaptureDashboardLowerPanelsAndSeparateProductionMetal` |13.839|19|
| `testCaptureActualEightStepContentViewWizardAtMinimumSize` |15.437|32|
| `testCaptureActualEightStepContentViewWizardAtNormalSize` |18.109|32|
| `testCaptureAllNineManagerSectionsAndSettingsComponent` |11.223|23|
| `testCaptureReadOnlyConditionalDetailsAtBothSizes` |20.742|25|

The outputs are under
`build/graphite-captures/native-workbench-current-final-20261005T011730Z-f2b4d25e`.
`native-workbench-current-routes-dashboard-visual-review.json` (SHA-256
`915530b1499b2f099d0a31138ab41726860a879ef27cd9b3dee701bc6a2e5de7`)
and `native-workbench-current-conditional-manager-wizard-visual-review.json`
(SHA-256 `6873719a15c83189fc575e46ca10530355126a82111c2bde8ae7d7be6b42819b`)
are in `build/graphite-results`. All thirteen routes and lower Dashboard panels
are readable at both sizes. All seven Projects action labels fit equally; the
minimum workflow forms one column. Manager's nine sections/fields/staged footer
and all eight Wizard steps/lower actions fit. Wizard step 3 copy matches
**Add Project Folders…**. Covered conditional cards/details show no blocking
visual defect. Provider Advanced middle controls still need an intermediate
viewport capture; this is a coverage gap, not an observed product defect.

The initial conditional case remains failed (one case, 2.682s). Its temporary
220×32 AX literal contradicted the observed equal 221×33 bounds for all seven
buttons. The helper-only correction preserved unique owners/equality/full
visibility/tolerance; the current 20.742s rerun passed and its 25 PNGs were
reviewed. A centered-stroke explanation remains inferred, not proven.
`projects-ax-contract-correction.json` retains the failed attempt/helper hashes.
Registration/contextual Guide has a separate reported failing/partial case;
its 11 partial PNGs are excluded from the 157-image passed-case review.

Remaining secondary/Guide/control-state cases, Provider middle coverage, real
SettingsScene/menus/preferences and composed ordinary app execution remain open.
These are public direct-XCTest native view fixtures, not XCUITest or actual
ordinary SettingsScene/composed-window proof. Parent/sheet caches are separate,
not simultaneous modal-placement evidence; wizard sheets are 1560×1360 pixels
at both parent sizes. Unavailable 1× backing scale remains unexercised.

## Current ordinary candidate — runtime OPEN

The canonical Debug **My Mac** build ended with exit 0/`BUILD SUCCEEDED` in
**5.022 seconds**, matching current 434-input source c4de77…. Root verified
strict deep Apple Development signing for team `9AQ2C2838M`, version 0.17.0 (27),
compiled function names and the exact reference resource. The identity receipt
is `build/graphite-results/equal-project-actions-final/ordinary-candidate-identity.json`;
the adjacent `ordinary-build-receipt.json` records the command/log.

| Identity | Observed current value |
|---|---|
| App | `build/graphite-app/Build/Products/Debug/Forge Conductor.app` |
| Source | 434 inputs; `c4de77cca979890a4367c7eaa4820fd3c9295849af5589b260b35e15f6d44867` |
| CDHash | `562b57450c11ac9a9a6c9fc332fad61a3049a0f7` |
| Debug dylib | `b4baf1427c8393ce7f7909f9d23bda40398b51d6a4884e3156744f6543beba03` |
| Bundle manifest | 36 files; `97004fbce0f4f854f734e4cd9564d5b565d2cc128b8e6a9d5f8c7a0c07c4b8ea` |
| Compiled library | `default.metallib`, 19,564 bytes; `211de42e05e00cff244381eb0371b11efe97f5e20517ac7cd94ccc364562c4ab` |
| Functions present | `compute_chip_vertex`, `compute_chip_fragment` |
| Exact PNG packaged | 1,682,363 bytes; `7184bbb39a6b014b32283869557edb6166acecd1bc8f201401ceda02169975f1` |

These are build/signature/package results, not current ordinary runtime or
composed-window acceptance. Actual failure/healthy exports, native folder
authorization/cancellation/invalid-root handling, shell opt-out/reenable,
real SettingsScene and composed QA remain open. The prior bf495e68… candidate's
3/8-record exports retain their exact old inputs in
[candidate/manual history](COMPUTE-CORES-CHECKPOINTS.md#earlier-material-candidate-and-manual-checkpoints).
Rejected art, earlier candidates, failed pilots/native host attempts and
selected passes retain identities in [checkpoints](COMPUTE-CORES-CHECKPOINTS.md).
Installation, notarization, App Store Connect upload and shipment were not performed.

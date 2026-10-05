# Graphite Workbench checkpoint history

This is the preserved pre-consolidation phase record from October 4, 2026.
Statements described as current below refer to their recorded checkpoint
inputs, not the subsequently frozen source or ordinary candidate. Passing,
failed, skipped and pending boundaries remain intact. The active record is
[GRAPHITE-WORKBENCH.md](GRAPHITE-WORKBENCH.md). These records select no work and claim no new execution.


Current source identity: **0.17.0, build 27**.

The owner’s later revision 2 Compute Cores requirement adds detailed native
chip presentation and Metal illumination/trace FX within the existing frame,
plus application-wide color alignment through the existing shared palette.
Outside that frame, current layout, typography sizes, controls, navigation,
data and other renderer clocks remain the preservation boundary. Current
evidence and all 32 open acceptance gates are tracked in
[Compute Cores](COMPUTE-CORES.md). Earlier Graphite captures/hashes below remain
checkpoints; they do not qualify the changed chip and palette inputs.

Fresh supporting receipts passed 35 Core cases, 23 initial chip/Graphite
app-hosted cases (9 pure, 3 native, 11 palette) and three separate legacy settled
gauge resize cases. Native minimum Settings passed one case in 134.245 seconds;
all fourteen captures were reviewed. The later expanded app-hosted gate passed
76 cases in 39.506 seconds: pure Compute 10, native Compute 5, Graphite 11,
Guided Mode 3, review 7, legacy gauges 7 and Provider 33. The 19-case Projects
class was not selected and remains a separate gate. Earlier whole-chip
fixtures stopped at AX prerequisites. The corrected aggregate GPU case then
passed in 1.022 seconds, with strict 0/12/82% production drawable comparisons
and all three images reviewed. The other three whole-view fixtures, a new
twelve-case pure gate and appearance checks, final palette every-view QA, ordinary
candidate and publication remain open. The last ordinary candidate is stale for these new source inputs.

## Compute Cores revision 2 draft — delivery open

The subsequent owner package adds detailed CPU/GPU chip rendering, Metal +
MetalKit illumination/trace FX and color-only application-wide Graphite
alignment. Outside-Compute structure, typography sizes, controls, navigation,
data and other clocks remain the preservation contract. New source is present
and integration is being authored; all 23 CC, 3 FX and 6 PAL full criteria and
all 18 new captures are **Not Run** in [Compute Cores](COMPUTE-CORES.md).

`ComputeTelemetryProvenanceTests` passed **8 cases, 0 failures** in
**0.038 seconds**. The same invocation failed
`testGraphiteNativeSettingsCapturesEverySectionAtMinimumSize` in
**22.428 seconds**, with terminal exit **65** / `TEST FAILED`.
Evidence: `build/graphite-results/compute-metadata-settings-minimum.xcresult`
and `/tmp/forge-compute-metadata-settings-minimum.log`. This is metadata
support only, not the new chip/FX renderer.

The last ordinary candidate is **STALE** after these edits. Its retained
CDHash `ad6014ae8aa90528937939618ba008c3efd4c627` and manifest SHA-256
`55ce38c37e1ef5215fa26c2cb53c7185471cde64615577c9a9affacede109ca8`
remain historical receipts below. Native build/package/FX/capture, final
source/candidate identity, documentation completion and publication stay
**OPEN**. Source remains `0.17.0 (27)`; this draft changes no version.
Earlier passing/failed/skipped counts, hashes and limits remain intact and
are not promoted to revision 2 acceptance.

The owner added a later requirement to remove persistent main-window top-bar
controls, move their actions/options into Settings or show them only when
explicitly enabled in Settings, and improve text layout using the supplied
macOS design guidance. This reopens the Graphite UI phase. Earlier passing
build, native test and pixel-review receipts are checkpoints for their exact
inputs; they do not qualify the new preferences/layout changes. Fresh tests,
every-view QA, final source/candidate identity and publication remain open.

## Additional visual scope and observed checks

The owner added two requirements during native review. Telemetry must match the
selected Dashboard reference more closely through CPU, RAM, GPU and disk
sparklines, restrained luminous strokes, shaded fills and static material depth.
Current numeric values, units, missing-sample gaps, bounded retained history and
the combined Compute Cores frame remain required. Shared Metal ownership,
buffer reuse and demand drawing must survive; material adds no decorative
render clock. The supplied color/texture research informs selective depth and
readable surfaces, not a replacement platform or an additional workflow.

The later owner requirement removes the persistent main-window control bar.
The default workspace shows the selected content directly below native window
chrome. Native Settings opens at Workbench, where navigation visibility,
telemetry updates and guidance are available. Six independent local preferences
can enable Navigation, Auto-refresh, Guided Mode, Guide, Refresh or Guided Setup
above the selected view. Each is off by default, and only enabled controls are
shown. Existing action identifiers and the Guided Setup compatibility container
remain on those optional controls. Navigation and Telemetry menu actions and
shortcuts remain; a Guide menu supplies View Guide, Guided Setup and Guided Mode.
Only standard macOS traffic-light window chrome and the app title remain in
the title bar; persistent application shortcut controls are removed.

One shared preferences owner and one shared guide coordinator serve main window,
Settings and menus. Workbench preferences apply immediately, separately from
Manager configuration. The six optional-control visibility preferences and
existing Guided Mode preference persist; navigation visibility and Auto-refresh
retain their existing session behavior. Opening Settings or Manager does not
reload an already-loaded configuration draft. Explicit Reload and initial
bootstrap loading remain. The bundled Dashboard guide now points to Settings,
menus and optional controls; its schema and old anchors remain, with three
added Settings anchors.

The requested text-layout work groups each form label with its field, aligns
Manager value columns, gives short numeric inputs a proportionate width and
omits grouping separators in their display. Essential explanations use callout
text and bounded reading widths. Paths and tool/agent/MCP identities wrap;
row labels and numeric columns align on text baselines. Actions, bindings and
service predicates remain. Fresh native interaction and secondary-view pixels
passed their named scopes below; final smaller-screen checks, frozen candidate
workflows and publication remain open.

The changed trace geometry passed seven focused Graphite cases, and the changed
production surfaces passed all four native lifecycle cases. The earlier
persistent header's geometry and actions passed in 33.194 seconds; that layout
is superseded by the Settings-first requirement.
Actual Light desktop with Increase Contrast, Reduce Transparency and Reduce
Motion enabled passed the native preference check in 53.944 seconds; all eight
captures were opened for pixel review. The earlier every-view,
supporting-presentation and conditional captures were reviewed, including the
corrected wizard introductions and full Dashboard minimum-MCP identities.
Those successful captures remain evidence for their earlier inputs.

## Presentation and current-source adaptations

Shared compiled sRGB tokens supply graphite window/sidebar/canvas surfaces,
readable text, blue selection, mint primary actions, restrained destructive
controls and semantic status accents. SwiftUI, bridged AppKit surfaces and
Metal telemetry use the same presentation values. Native controls, existing
models and the canonical Xcode workspace remain the implementation boundary.

The main sidebar keeps current destinations. Provider uses a source list and
selected detail; inspection state is independent of the active-provider
binding. Manager and native Settings have nine sections: Workbench, Authorized
Folders, Service, Runtime, Settings, Project Shell, Protected Filesystem,
Maintenance and Doctor. Native Settings initially selects Workbench; the main
Manager entry retains Authorized Folders. Workbench uses immediate shared
interface preferences without a Save/Reload footer. Changing sections preserves
staged model bindings; Save settings and Reload from disk remain explicit
configuration actions.

Guided Setup now owns a read-only registered-project review selection for its
project, instruction and input-review steps. It reads project status, the
generation-matched instruction queue and current provider revision without
activating a project or requiring a live MCP chat binding. The saved reviewed
project choice is independent of Dashboard's active-project projection.
Seven pre-chat review app-hosted regressions passed. The native review,
confirmation and persistence case passed; the all-step scroll/progress
regression and fresh wizard captures also passed review.

Dashboard retains published metrics and the combined Compute Cores panel.
Projects retains registration, instruction order/catalog, running-package
rules and scoped maintenance. Current Continuity remains a project/packet
workspace with its existing Copy, Delete, Reset and Clear Cache behavior.
The reference's historical manual rollover layout does not restore retired
workflow controls. Rune Forge, Runtimes, Agents, Tools, Live Feed, Events &
Evidence, Diagnostics, Guided Setup and offline help receive the same native
treatment. Existing live sheets and export workflows retain their current
callers. The retained `AutonomyOperatorView` component receives shared styling,
but the current source has no live root or Projects caller for Run Details;
this phase does not restore that retired route.

The live Continuity route has no manual context-budget editor, managed-run
picker or manual rollover controls. Existing budget/readiness data remains in
its current owning models and Dashboard projections; this phase does not create
a replacement workflow. Provider preserves the current distinction between
private local LM Studio loopback, which has no operator token, and linked
providers, which retain Keychain credential Keep/Replace/Clear and conditional
secure token entry. The credential controls are not presented for local mode.

Unsaved Advanced edits disable the Provider toolbar's connection and probe
actions. The generic provider card retains its current action-eligibility
predicate; an available LM Studio action uses the model's save-or-discard guard
before preparation. This phase does not change that predicate.

The reference imagery supplies presentation guidance. It does not add sample
MCP rows, tool names, outcome data, permissions, model workers, command editors
or retired primary destinations. Catalogs and statuses consume current models.
Configured MCP roles remain distinct from live connections; error, denial,
warning, loading and unavailable evidence retain truthful labels.

## Feature preservation

This phase retains current model calls, staged settings, service operations,
protected-filesystem eligibility, signing/trust policy, shell capability and
migration information, stable identifiers, tool contracts and project formats.
Presentation does not grant permissions, activate providers, deploy an
integration or start a session merely because a row is inspected.

The Settings scene uses the same Manager model and native invocation. Its
declared ideal size is 900×700 with a 760×560 content minimum; sections scroll.
The first preferences batch actually observed a 900×592 outer window with
560-point content height, so declared ideals are not an observed initial size.
The main-window minimum is not raised to accommodate this scene.
Reduced Motion and increased-contrast presentation use the native environment.

## Confirmed earlier checkpoints

The phase began from synchronized `main` / `origin/main` at
`df0b66c958b161b82bbfad7813c70a4ca8b6d812`. These checkpoints describe the
earlier tested inputs, not the later Settings-first/layout changes, a published
commit or an installed product.

| Executed check | Observed result and retained receipt |
| --- | --- |
| `swift build --product forge-conductor-app` | Final current-input rerun: terminal exit 0, `Build complete!` in 2.71 seconds; `/tmp/forge-graphite-swift-app-final-5.log`. Earlier `/tmp/forge-graphite-swift-app.log` remains its own checkpoint. |
| `swift build --product forge-conductor` | Final current-input rerun: terminal exit 0, `Build complete!` in 0.18 seconds; `/tmp/forge-graphite-swift-cli-final-2.log`. |
| Canonical ordinary Debug build | `xcodebuild -workspace ForgeConductor.xcworkspace -scheme ForgeConductor -configuration Debug -destination 'platform=macOS,name=My Mac' -derivedDataPath build/graphite-app build`: terminal exit 0, `BUILD SUCCEEDED`; `/tmp/forge-graphite-native-final-3.log`. |
| Ordinary candidate identity | `build/graphite-app/Build/Products/Debug/Forge Conductor.app` reports 0.17.0 (27), uses Apple Development signing for team `9AQ2C2838M`, and passed strict deep signature verification. Fresh candidate receipt: `build/graphite-results/ordinary-candidate-identity.json`. CDHash `f6e88005074322d513bd25b1329dd53d58cf13a8`; debug dylib SHA-256 `2037ce8cc2b282e1012cd598ba7dd11a510ce6412fff53c85c39ae4b27c6a441`; launcher SHA-256 `148838089b822453d792643c8d46ba659554f42796c71b41659ff9702354af24`; 34-file bundle manifest SHA-256 `108607f95f2eda76921e024d39a1f8174256009ed753b55b9d0dfb9ee3f94f02`. Runtime/bootstrap acceptance remains separate from signature verification. |
| App-hosted focused suites | `GraphiteWorkbenchAppTests` 2, `GuidedModeAppTests` 3, `ProjectsViewModelResetTests` 19 and `ProviderConfigurationAppTests` 33: **57 executed, 0 failed**; `/tmp/forge-graphite-components-final.log`, `build/graphite-results/components-final.xcresult`. |
| Guided Setup pre-chat review | Final `GuidedSetupReviewAppTests`: **7 executed, 0 failed, 0 skipped**, terminal exit 0; `/tmp/forge-graphite-setup-review-final.log`, `build/graphite-results/setup-review-final.xcresult`. Read-only preparation without MCP bindings, generation validation, exact provider-revision review, cancellation, stale selection and stale same-project refresh passed. Earlier `setup-review-2.xcresult` executed six review cases plus five repeated Graphite/Guided Mode cases; those reruns are not additional unique regressions. |
| Native Guided Setup review | `testGuidedSetupReviewConfirmationAdvancesToStartAndPersists` passed in 25.282 seconds; `build/graphite-results/native-interactions-4.xcresult`. That bundle failed its other two cases; only this named case is a pass. The later native17 captures qualify the viewport correction. |
| Native runtime cancellation | `testRuntimeCancelUsesProtectedTypedRequestAndReconcilesSuccessAndRejection` passed in 43.870 seconds, covering published wire states, control eligibility, cancellation authorization and reconciliation; `/tmp/forge-graphite-workbench-6.log`, `build/graphite-results/workbench-6.xcresult`. The bundle failed three capture cases, so it is not a passing batch. |
| Isolated native pending lifecycle | `testGraphiteFilesystemPendingLifecycleFenceIsReadOnly` passed in 68.407 seconds within `workbench-8.xcresult`; `/tmp/forge-graphite-workbench-8.log`. An exclusive peer lease kept the isolated pending record unresolved through app termination. Native controls remained fenced, the recovery action was inspected without invocation, and record/lock bytes and lease identity remained unchanged. The overall batch executed nine cases: six passed, three failed, none skipped. This named case does not qualify an actual ServiceManagement registration or recovery. |
| Isolated native debt and Doctor | `testGraphiteFilesystemRecoveryDebtAndNativeDoctorReport` passed in 67.771 seconds within `workbench-9.xcresult`; `/tmp/forge-graphite-workbench-9.log`. Read-only Refresh displayed 32/32 retained local quarantine slots and the exhaustion warning, then Run doctor generated the actual local report with `state=attention` and the isolated missing-helper check. No registration, recovery, installation or deployment action was invoked; ledger bytes and inventory remained unchanged. |
| Native every-view capture and Advanced help | `testGraphiteWorkbenchCapturesEveryCurrentView` passed in 204.180 seconds and `testGraphiteGuidedHelpAdvancedDisclosureOpensAndCloses` passed in 25.546 seconds within `workbench-9.xcresult`. The batch executed five cases with two failures; these named passes do not qualify that entire batch. Later native16 and actual-preference receipts close the corresponding current UI checks. |
| Changed trace geometry/material | `GraphiteWorkbenchAppTests`: **7 executed, 0 failed, 0 skipped**, `TEST SUCCEEDED`; `/tmp/forge-graphite-instruments-components.log`, `build/graphite-results/instruments-components.xcresult`. The cases cover opaque palette/contrast, distinct series, latest-300 retention/vertex bounds, finite clamping/invalid scale, missing-sample fill/halo/core gaps, empty/unavailable and isolated samples, and stroke width in points. The two earlier Graphite cases are repeated here, not additional unique coverage. |
| Changed native gauge lifecycle | `NativeGaugeLifecycleTests`: **4 executed, 0 failed, 0 skipped** in 12.876 seconds, `TEST SUCCEEDED`; `/tmp/forge-graphite-instruments-lifecycle.log`, `build/graphite-results/instruments-lifecycle.xcresult`. Production hidden/ordered-out quiescence, shared-resource reuse, buffer release and SwiftUI dismantle ownership passed with the optional trace/fraction and 200-unit disk path. This reruns the four earlier `gauges-repaired.xcresult` cases against the changed presentation. |
| Header, navigation, Provider and keyboard checks | Within `workbench-14.xcresult`, header geometry/actions passed in 33.194 seconds, Provider inspection/request absence in 29.996, readiness fallback/reported endpoint in 22.649, Guided Mode persistence/Escape in 13.291, collapsed navigation restore in 5.901, and fixture contrast/focus in 22.040. `/tmp/forge-graphite-workbench-14.log` records **8 executed, 6 passed, 2 failed, 0 skipped**; every-view and conditional capture cases required repair and final recapture, so the batch is not a pass. |
| Actual native accessibility preferences | `testGraphiteWorkbenchUnderNativeAccessibilityPreferences`: **1 executed, 0 failed, 0 skipped** in 53.944 seconds, `TEST SUCCEEDED`; `/tmp/forge-graphite-native-accessibility-2.log`, `build/graphite-results/native-accessibility-2.xcresult`. Its retained public-API attachment reports Light desktop, all three native accessibility flags enabled, and fixture variant `0`. The first attempt skipped because its opt-in environment did not reach the test runner; it is not a pass. The rerun used `TEST_RUNNER_FORGE_GRAPHITE_NATIVE_ACCESSIBILITY_QA=1`. Original Dark/all-three-off preferences were restored and independently read back. |
| SwiftPM version/isolation | `G1G10AcceptanceTests/testG3_VersionAndReleaseDocumentsAreAligned` and `H0IsolationTests`: **1 executed each, 0 failed**; `/tmp/forge-graphite-version-test.log`, `/tmp/forge-graphite-h0-test.log`. Zero-test reports for the other unselected target do not count as additional tests. |
| SwiftPM current queue/telemetry parity | `swift test --filter 'ProjectInstructionQueueTests\|RigParityTests\|TelemetryContractTests'`: terminal exit 0; **ProjectInstructionQueueTests 37 + RigParityTests 16 + TelemetryContractTests 2 = 55 executed, 0 failed, 0 skipped**, `/tmp/forge-graphite-parity-final.log`. The earlier narrow queue selection executed three queue cases plus the same 18 Rig/telemetry cases; that earlier 21-case receipt is not additional unique coverage. |
| Canonical source membership | The final read-only comparison against the synchronized starting revision passed all **12 checks**. Inventory: **371 repository Swift inputs, 368 unique native members, 370 Sources-phase occurrences across 12 targets; 38 changed Swift inputs, 37 native**. The existing H0 support test remains SwiftPM-only. All **29 resources** and their membership, **10 workspace/scheme/entitlement/Info inputs**, signing settings and all **26 macOS 26.0 deployment configurations** remain unchanged. Only product version/build values change in 16 configurations. The external `checkpoints/before-workbench-preferences/final-membership-audit.json` and `final-source-input-manifest.json` under the evidence root retain this earlier graph and 423 non-document source inputs; the build-directory receipts are refreshed for later inputs. Checkpoint manifest SHA-256: `2504733d049728a18d43b7e051bf0de845c08d16a10180e85960bc34085e9223`; project SHA-256: `e4d7ceececb725f89c98a81a7541906e2ddc8aa3fa2d75d0b98db17a4d8024cc`. The source audit identifies inputs separately from candidate identity. That audit includes the earlier minimum-MCP header and footer accessibility repairs; the new Settings-first/layout work requires a refreshed manifest. |
| Secondary-view recapture review | Actual `workbench-5/named` captures were opened for normal/minimum Manager, Agents, Tools, Live Feed, Diagnostics and MCP plus all eight Manager sections: **20 PNGs reviewed**. Empty Live Feed header alignment is corrected in both sizes and the stale fixture Manager version warning is absent. No new overlap, clipped action label or unreadable primary text was observed in these captured idle/empty/configured states. This does not close the entire screen matrix or dynamic-action gates. |
| Manager, Settings and conditional-state pixel review | **29 PNGs opened**: `workbench-9/named` Manager normal/minimum, all eight sections, debt warning and Doctor issues/report captures; `workbench-8/named` native Settings all eight sections, pending-fence and cross-section attention normal/minimum plus Settings pending. No new overlap, clipped action label or unreadable active text was observed. Debt/pending action rows wrap at minimum size; Doctor long paths wrap and report continuation extends below that viewport. This pixel review does not qualify protected service actions or the remaining Provider/accessibility captures. |
| Current every-view, conditional and gauge navigation | `workbench-16.xcresult`: **3 executed, 0 failed, 0 skipped**, terminal exit 0, `TEST SUCCEEDED`. `testGraphiteWorkbenchCapturesConditionalDetailsAndCancelledDestructiveActions` passed in **104.678 seconds**, `testGraphiteWorkbenchCapturesEveryCurrentView` in **321.046 seconds**, and `testHundredGaugeNavigationCyclesQuiesce` in **345.557 seconds**; `/tmp/forge-graphite-workbench-16.log`. Export retained **57 PNGs** with accessibility and actual-window geometry attachments under `build/graphite-captures/workbench-16/named`. |
| Current secondary-view pixel review | **20 PNGs opened** from `workbench-16/named`: normal/minimum Manager, Diagnostics, MCP, Agents, Tools and Live Feed, plus all eight Manager sections. No new overlapping controls, clipped action labels or unreadable active text was observed. Live Feed is top anchored; MCP uses literal yes/no; the staged footer and Manager runtime health remain apparent. Catalogs and logs retain scroll continuation at the lower viewport. This review covers those exact captured states and invokes no protected service action. A subsequent lower minimum-MCP inspection found truncated server-identity headers; its separate repair/recapture passed as recorded below. |
| Lower Dashboard and wizard scroll regression | `workbench-17.xcresult`: **2 executed, 0 failed, 0 skipped**, terminal exit 0, `TEST SUCCEEDED`. `testGraphiteDashboardLowerPanelsRemainVisibleAtBothWindowSizes` passed in **76.846 seconds** and `testGuidedSetupStepTransitionsResetScrollAndPreserveProgress` in **85.306 seconds**; `/tmp/forge-graphite-workbench-17.log`. Export retained **17 PNGs** under `build/graphite-captures/workbench-17/named`; all **17 PNGs were opened**: 11 wizard/top-transition captures and six lower-Dashboard captures. Introductions restart at the top across the eight steps, progress remains preserved, and lower panels/labels fit at both sizes. The same minimum review identified truncated MCP server-card identity headers, which passed the separate repair/recapture below. |
| Minimum MCP identity-header repair | `testGraphiteDashboardLowerPanelsRemainVisibleAtBothWindowSizes` passed with the strengthened MCP identity checks in **82.887 seconds**; `workbench-18.xcresult`, `/tmp/forge-graphite-workbench-18.log`: **1 executed, 0 failed, 0 skipped**, terminal exit 0, `TEST SUCCEEDED`. All **6 PNGs** from `workbench-18/named` were opened: full identities for all three retained MCP cards fit at normal/minimum sizes, with lower Dashboard rows retained. Header wrapping changes presentation without changing connection actions or ownership. |
| Ordinary-candidate onboarding/export first attempt | `/tmp/forge-graphite-ordinary-bootstrap-final.log`: terminal exit 65. Native folder-authorization cancellation/invalid-root preservation passed in **53.565 seconds**, and Settings shell opt-out/re-enable into fresh MCP processes passed in **68.773 seconds**. Failure-path export stopped at the missing `app-error` lookup; healthy export stopped at the label-only completion query. Both retained failures, so this is not a passing four-case batch. Footer accessibility containment and label/value completion matching require the fresh-candidate rerun while retaining artifact and redaction assertions. |
| Fresh ordinary-candidate onboarding/export | `ordinary-bootstrap-final-2.xcresult`: **4 executed, 0 failed, 0 skipped**, terminal exit 0, `TEST SUCCEEDED`; `/tmp/forge-graphite-ordinary-bootstrap-final-2.log`. Failure-path export passed in **21.314 seconds**, healthy export in **23.183**, folder-authorization cancellation/invalid-root preservation in **53.131**, and Settings shell opt-out/re-enable into fresh MCP processes in **68.924**. Actual paired JSON/Markdown files, record counts, redaction, native folder picker and unique footer IDs were asserted. The retained launch path/PIDs identify the ordinary candidate. Its complete bundle identity and strict deep signature remained unchanged after the run. |
| Current supporting presentations | `testGraphiteWorkbenchCapturesSupportingPresentations` passed in **227.611 seconds** within `workbench-15.xcresult`; `/tmp/forge-graphite-workbench-15.log`. It covered Provider descriptors/Advanced, runtime capabilities/limits, Rune feed, registration validation, help/Advanced, all eight setup steps with lower action checks and all eight native Settings sections. The batch executed three cases with two failures; every-view and conditional cases stopped at a Rune lookup and were subsequently rerun successfully in native16. This named supporting pass does not qualify the entire batch. |
| Current Settings/setup/help pixel review | **28 PNGs opened** from `workbench-15/named`: all eight native Settings sections; all eight Guided Setup steps plus five lower-action captures; contextual help, Advanced and nested instruction help; normal MCP, Agents, Tools and Live Feed. No new overlap, clipped active action text in the lower captures or unreadable active text was observed. Runtime paths wrap, the staged footer remains coherent, and wizard project identity/generation is visible in steps 3/5. Some wizard captures retain a scrolled viewport; lower captures show their complete action labels. Main Manager/Diagnostics and minimum-route captures are absent from this partial batch, so that earlier partial batch alone does not establish every-view coverage. Native16 and the later targeted captures complete that review. |

| Actual native preference pixel review | **8 PNGs opened** from `native-accessibility-2/named`: MCP normal/minimum, main field focus and Tab successor, Settings field focus, contextual help/Advanced and Provider Advanced. Opaque graphite remains under the Light desktop; the blue focus ring moves from host to port; literal MCP yes/no stays independent of color. No new overlap, clipped active action label or unreadable primary text was observed in these states. Minimum MCP and Provider have scroll continuation beyond the captured viewport. This is bounded evidence, not blanket accessibility certification. |

## Settings-first follow-up through native3

The first new preferences batch executed four native cases with one failure:
`testWorkbenchControlsAreHiddenByDefaultAndSettingsPersistOnlyOptedInActions`
failed in **53.851 seconds** at the navigation checkbox state assertion;
`/tmp/forge-graphite-controls-native-1.log` retains the failed case and batch.
The three named passes were Advanced help **27.185 seconds**, Manager draft
parity **38.629** and opted-in header actions **34.949**. These do not make the
four-case batch a pass.
The custom Manager fact-row style had been inherited by native checkbox labels,
separating their indicator from the tested click area. The style is now scoped
only to explicit read-only facts; native settings/shell/maintenance toggles
retain automatic layout. The next native run successfully toggled Navigation;
the original failed batch remains a failed checkpoint.

The second batch, `controls-native-2.xcresult`, terminated with exit **65**:
**5 executed, 2 passed, 3 failed, 0 skipped** in **373.803 seconds**;
`/tmp/forge-graphite-controls-native-2.log`. Lower Dashboard panels passed in
**73.835 seconds** and all eight wizard transitions in **91.212**. Conditional
captures failed in **57.854** and every-view capture in **94.581** on Provider
layout assertions; investigation of the oversized Provider content remains
open. Preferences failed in **56.321** at the missing Show Navigation menu
item, after the corrected checkbox actually changed state. Fresh menu and
Provider same-flow tests are required; this batch is not a pass.

Export retained **40 PNGs** under
`build/graphite-captures/controls-native-2/named`. **Six were opened** for this
secondary review: normal MCP, Agents, Tools and Live Feed; native Workbench
Settings defaults; and the default clean Dashboard. Full standalone MCP
identities and literal bits fit; Agent descriptions/tools wrap; Tools filter
label and explanatory paragraphs fit; empty Feed is centered within its
top-anchored panel. All nine Manager section labels and six native Workbench
checkbox options fit, with indicators adjacent to their labels and no staged
Save/Reload footer. No overlapping controls or clipped active action labels
were observed in these exact states. Tools had measured header-to-row offsets:
Tool/pack began at x499 versus the first identity at x493; State and Health
values were five points right of their headings. The header's 14-point inset
differed from the native List's implicit row insets. Adding explicit row insets
did not close that defect: fresh native3 pixels/AX showed the first tool eight
points right and the State/Health/Activity columns nine points left. The local
repair now uses a native ScrollView and LazyVStack with the same 14-point row
and header padding, and zero horizontal scroll-content margins. Filtering,
help, badges, metadata, fallback rows and lazy realization remain; no selection,
editing or context-menu action existed on this List. That checkpoint still required focused two-size geometry and pixel proof;
the named geometry pass is recorded in the current follow-up below. This batch contains no
main Manager, Diagnostics, Manager section matrix or secondary minimum-route
images. Earlier captures cannot close fresh QA for those changed inputs.

Opening a loaded Manager view previously dispatched a settings read. That read
could replace a pre-existing unchanged draft when its saved snapshot returned:
`AppModel.loadSettingsFromConfig` compares against the draft captured at read
start, then applies the snapshot. Manager entry now performs this read only
before initial settings load. Explicit Reload and bootstrap loading retain
their existing owners; protected-filesystem status still refreshes on entry.
Fresh native proof must retain a staged host through Workbench entry and menu
actions without a save request.

The third batch, `controls-native-3.xcresult`, terminated with exit **0**:
**5 executed, 0 failures, 0 skips**, **951.878 seconds**;
`/tmp/forge-graphite-controls-native-3.log`. The named passes were conditional
captures **122.072 seconds**, every current view **258.413**, supporting
presentations **234.027**, Settings/preferences/menu/individual opt-ins and
persistence **217.684**, and opt-out/relaunch persistence **119.683**. These
results close the prior Provider and Navigation-menu same-flow failures for
those inputs; failed native1/native2 receipts remain unchanged.

Export retained **103 PNGs** under
`build/graphite-captures/controls-native-3/named`. The secondary review opened
**29 exact PNGs**: `graphite-{normal,minimum}-{manager,diagnostics,mcp,agents,tools,feed}.png`
(12), `graphite-manager-{folders,service,runtime,settings,shell,filesystem,maintenance,doctor,workbench}.png`
(9), and `graphite-settings-{folders,service,runtime,settings,shell,filesystem,maintenance,doctor}.png`
(8). No additional overlap, clipped active action or unreadable active text was
observed. Native Settings paths and essential prose wrap, checkboxes retain
adjacent indicators, Manager facts align, and filesystem action rows wrap.
Tools retains the measured column offset described above. Exact filenames and
measured coordinates are in `build/graphite-results/secondary-controls-native-3-pixel-review.md`.

Fresh current-input SwiftPM builds completed successfully: app **2.99 seconds**
(`/tmp/forge-graphite-controls-swift-app-final.log`) and CLI **0.19 seconds**
(`/tmp/forge-graphite-controls-swift-cli-final.log`). The app-hosted
`controls-components-final` batch terminated with exit **0**, **76 executed,
0 failures, 0 skips** in **18.944 seconds**;
`/tmp/forge-graphite-controls-components-final.log`. Its distinct suite counts
are Graphite **10**, Guided Mode **3**, Guided Setup review **7**, Projects
**19**, Provider **33**, and native gauge lifecycle **4**. Earlier overlapping
receipts are not added to this total.

A native warning investigation also retained direct runtime evidence. The
conditional test passed in **129.837 seconds** while still reporting
“Publishing changes from within view updates” in
`/tmp/forge-graphite-controls-warning-trace.log`; that passing assertion result
does not establish warning removal. LLDB attached to isolated app PID **6575**
and stopped in `ContinuityViewModel.selectedPacketIDs.setter`; the stack in
`/tmp/forge-graphite-selection-stack.log` runs through Binding's setter,
`OutlineListCoordinator.outlineViewSelectionDidChange` and
`UpdateGroup.ensure`. The current source binds the native packet List to local
`@State` selection and synchronizes it with the retained model selection through
guarded `onChange` handlers. The same-flow follow-up is recorded separately below; this trace alone
does not establish warning removal. Packet actions and model ownership remain
unchanged.

Three additive GPU engine accessibility containers support frozen-frame pixel
readback; rendering and measurement mapping are unchanged. Bundled Manager
guide control copy now names the actual native runtime, telemetry,
protected-filesystem/maintenance and Doctor surfaces, alongside Workbench.
The same guide resource also retains the requested Dashboard Settings/menu
workflow correction and three new Settings anchors. Guide schema and all
29 resource memberships remain; only this one resource's requested copy changes,
with the other 28 resource contents unchanged.

Following native3, the remaining gates were focused Tools column proof, final
smaller-screen/native pixels, a fresh ordinary candidate and its production
onboarding/export cases, complete frozen-input source manifest and source/wiki
publication. The current follow-up below records subsequent progress and failures. The graph
audit passed all 12 checks for the prior native3 inputs: 423 manifest files,
SHA-256 `49f7799b7e37ab467a0928d6810ec7489da8e2ddaee59a366daf4cdb3d01dbc5`.
It retains all 29 resource memberships and records the one intentional
`GuidedHelpCatalog.json` copy correction plus 28 unchanged resource contents.
Later Tools/test edits require a refreshed manifest; this hash is a checkpoint.

## Current native follow-up — failed batch and pending recaptures

`/tmp/forge-graphite-controls-native-final.log` retains an eleven-case batch
that terminated with exit **65**: **9 passed, 2 failed, 0 skipped** in
**922.117 seconds**. The nine named passes were exact multiple packet selection/deletion
**28.256 seconds**, single confirmed packet deletion **12.171**, Tools column
alignment at both sizes **46.673**, accessibility variants/focus **21.887**,
conditional details/cancelled actions **120.855**, empty/unavailable states
**24.347**, every current view **258.873**, Settings/preferences/individual
opt-ins and persistence **197.555**, and opt-out/relaunch persistence **120.789**.
The Tools case asserts name,
State and Health leading coordinates plus Activity trailing coordinates within
**2 points**, scroll/detail/window containment and absence of manager mutations.
The exact-selection and conditional follow-up emitted no selection-time
publishing warning. Other main-thread/QoS diagnostics remain in this batch;
there is no blanket warning-free claim.

Two cases failed and remain open. Native minimum Settings capture failed in
**28.104 seconds** before section captures at the 760×560-content/32-point-title
window-size assertion. Paused GPU readback failed in **62.606 seconds** at the
minimum scroll helper after two normal-size settled readbacks passed; the
minimum pixels were not captured. A successful named case does not qualify the
entire failed batch. Settings minimum sizing, minimum GPU readback and upcoming
wizard-copy validation remain open at this earlier checkpoint. The later
coalesced native Settings configuration run passed its minimum-size case in
134.245 seconds; all fourteen section/lower-state images were reviewed.
That later pass closes the Settings minimum gate for its inputs, while the
revision 2 Compute/palette scope above still requires fresh whole-view proof.

Export retained **88 PNGs** under
`build/graphite-captures/controls-native-final/named`. This secondary review
opened **26 exact PNGs**: normal/minimum Manager, Diagnostics, MCP, Agents,
Tools and Live Feed (12); all nine Manager sections (9); focused two-size Tools
alignment (2); and main/native-Settings field and keyboard focus (3).
No new overlap, clipped active action label or unreadable primary text was
observed. The four Tools header/first-row coordinates match exactly at both
sizes: name/State/Health leading edges and Activity trailing edge have
**0-point deltas**. Native focus rings are visible, with Tab moving from the
host field to the port field. Exact filenames, image hashes, observed scope
and geometry are retained in
`build/graphite-results/secondary-controls-native-final-pixel-review.md`.
These captures do not include native Settings minimum or minimum GPU proof.

The fresh ordinary Debug build succeeded in
`/tmp/forge-graphite-controls-native-build-final.log`. Its observed
`ordinary-candidate-identity.json` reports **0.17.0 (27)**, Apple Development,
team **9AQ2C2838M**, a valid strict deep signature, **34 bundle files**,
CDHash `ad6014ae8aa90528937939618ba008c3efd4c627` and bundle-manifest SHA-256
`55ce38c37e1ef5215fa26c2cb53c7185471cde64615577c9a9affacede109ca8`.
Debug dylib SHA-256 is
`9304fc876cea2bf13bfa85604b3f5b212664aa973d5748e81f56ace212ecd75e`;
launcher SHA-256 is
`7c75d9617696d8e37f4d64f3fbccbdf15edfcb5fbb187da49686a1da0012c8d5`.
These are build/signature checkpoint identities, before upcoming source changes;
the four ordinary candidate onboarding/export cases have not yet run for this
candidate.

The matching read-only audit passed all **12 checks**, with **423 manifest
inputs**, **371 repository Swift files**, **368 unique native members**,
**370 Sources-phase occurrences** and **39 changed Swift inputs, 38 native**.
Source-manifest SHA-256:
`e75ed36ab97c7a8fab082cb670cc8b174ee58ca7d4268e4ef9b7d0a48b8cdb35`;
audit SHA-256:
`fb491857a6388fb3c59397083c5534da1d2d6f2d127998b5da69670aa94936cc`.
Project SHA-256 remains
`e4d7ceececb725f89c98a81a7541906e2ddc8aa3fa2d75d0b98db17a4d8024cc`.
The retained graph preserves signing, macOS 26.0 deployment, schemes, entitlements
and all 29 resource memberships. Only the requested guide copy changes; the
other 28 resource contents are unchanged. These identities become checkpoints
when the upcoming product/test corrections land and must be refreshed before
final publication.

The fixture-backed cancellation test first reproduced publication of
`packet-stale-999` after a replacement Continuity packet request. The correction
adds cancellation checking before publication in `ContinuityViewModel.loadPackets`.
The paired regression and ordinary replacement cases passed afterward within
the Provider suite. This changes stale-response handling, not packet deletion,
project reset or cache-clear semantics.

Workbench 15 showed a Guided Setup viewport defect: after a lower section was
scrolled, changing steps could leave the next introduction above the viewport.
`GuidedSetupWizardView` in `ContentView.swift` now gives its detail `ScrollView`
the current step identity with `.id(index)`. The selected-step binding,
`GuidedSetupReviewViewModel` owner, saved project choice and review fingerprint
remain outside that replaced detail subtree. The new native
`testGuidedSetupStepTransitionsResetScrollAndPreserveProgress` checks all eight
introductions after lower scrolling, along with saved progress and request
non-mutation. It passed in 85.306 seconds in the two-case successful native17
batch, and all 11 wizard/top-transition PNGs were opened with the introductions
at the top. Earlier supporting captures do
not qualify this later source edit.

## Acceptance mapping

This original 30-criterion Graphite mapping retains earlier named proof and
later Settings-first follow-ups. The new revision 2 chip/palette gates are
tracked separately in Compute Cores; earlier GPU-engine captures do not
qualify its replacement chip presentation. Native Settings minimum later
passed its selected case and fourteen-image review. Final chip/palette pixels,
candidate workflows and publication remain open. This mapping records
the native presentation and retained workflows exercised by the named tests;
it does not relabel fixture evidence as
live provider deployment or complete the broader shipping roadmap. Historical
instruction-board controls do not override subsequent source changes.

| ID | Current-source mapping and observed evidence |
| --- | --- |
| AC01 | The synchronized starting revision and current 12-check graph receipt identify 423 inputs. e75ed36… and the ad6014… ordinary candidate are build/signature checkpoints before upcoming source edits; final frozen identities remain open. |
| AC02 | Current 13 destinations and legacy Autonomy→Projects compatibility remain. Earlier normal/minimum navigation pixels passed review. The current every-view case passed in 258.873 seconds; its final exported pixel review remains open. |
| AC03 | Scope inventory is complete. Current-source controls govern the implementation; no sample-only Start Task, Ask policy, pairing/chat/graph/terminal or permission-editor workflow was introduced. |
| AC04 | Layered graphite, blue selection, mint actions, separators and native typography are implemented. Earlier reference/current-source main, supporting, conditional and actual-accessibility pixels were reviewed. Fresh native3 review opened 29 secondary/Manager/Settings PNGs; final follow-up pixels remain open. |
| AC05 | Grouped fields, proportionate numeric inputs, aligned Manager facts and wrapped secondary identities retain title/body/metadata hierarchy. Fresh native3 review found Tools inset offsets; its shared native lazy-row repair passed four-column alignment within 2 points at both sizes in 46.673 seconds. All 26 assigned final secondary/Manager/Tools/focus PNGs were opened; the four Tools columns now have exact 0-point header/first-row deltas at both sizes, with no new defect observed in that matrix. |
| AC06 | Earlier normal top-right header geometry/actions passed in 33.194 seconds. The later owner instruction supersedes persistent header placement: global actions/options move into Settings or appear only after explicit enablement. Native3 default absence, individual opt-ins, Settings/menu parity, shared guidance and opt-out/relaunch cases passed; current preferences/persistence and opt-out/relaunch passed in 197.555/120.789 seconds. Final smaller-screen and candidate checks remain open. Current actions/IDs remain. |
| AC07 | Earlier actual Light desktop proof showed opaque graphite in main, Settings and help; all eight preference captures were reviewed and original desktop preferences restored. Native3 ordinary-dark supporting captures were reviewed. Current fixture accessibility/focus passed in 21.887 seconds, and all three fresh focus captures were opened. Remaining smaller-screen gates are distinct. |
| AC08 | The current 76-case batch passed Graphite 10, Guided Mode 3, review 7, Projects 19, Provider 33 and native lifecycle 4, with 0 failures/skips. Palette/geometry, transactional/model and ownership scopes remain distinct. Current native fixture accessibility/focus passed in 21.887 seconds; its three focus captures were opened. |
| AC09 | Sixteen Rig parity cases retain measurement, frequency, storage/IOPS/volumes, status and activity. Compact traces retain bounded real history and honest unavailable samples. Changed-geometry checkpoints passed; the fresh four-case native lifecycle scope passed within the 76-case batch. Earlier top/lower pixels remain checkpoint evidence. |
| AC10 | Combined Compute Cores and honest GPU topology/aggregate labels remain. Earlier frame/lower-row pixels passed review. Current paused GPU readback passed two normal-size settled captures but failed at the minimum scroll helper before pixels; full current meter/readback acceptance remains open. |
| AC11 | Queue predicates and artifact ownership remain. All 37 Core queue cases and the relevant cases in the 19-case Projects suite passed; native minimum-window reorder/removal checked exact requests and refreshed identity. Current queue captures were reviewed. |
| AC12 | Catalog detail, Converted/Retained/Unresolved states, attachment metadata and retry remain. The 37-case queue/import suite and native catalog transport-error/retry case (17.975 seconds) passed. Expanded catalog and nested instruction-help captures were reviewed without queue mutation. |
| AC13 | Current-source adaptation verified: Run Details has no live root or Projects caller. The retained AutonomyOperatorView is themed without restoring its retired route or claiming a live sheet interaction. |
| AC14 | Provider inspection/request absence passed in 29.996 seconds; 33 Provider cases passed transactional/model contracts; exact busy-operation poll/cancel passed in 18.064. Final Provider normal/minimum, busy and supporting captures were reviewed. |
| AC15 | Single Connect and Check and its existing predicates remain. Local loopback has no token; linked mode retains Keep/Replace/Clear and conditional secure input. Native redacted save/reopen, local-token absence and the 63.766-second selection/connection case passed; credential/unsaved-guard captures were reviewed. |
| AC16 | Existing descriptors/records remain: Grok is nonselectable, Forge Link is not exposed as completed remote functionality, and no CLU row is invented. Provider tests and native selection/inspection passed. Full real MCP identities fit after the targeted repair, with all six fresh captures reviewed. |
| AC17 | The ninth Workbench section applies preferences immediately, preserves loaded Manager drafts and has no staged footer. Native1 draft preservation passed in 38.629 seconds; native3 Settings/menu parity passed in 217.684 and all nine Manager sections/eight configuration Settings captures were reviewed. The earlier minimum Settings resize failed in 28.104 before section captures; its later one-case coalesced-configuration rerun passed in 134.245 seconds with all fourteen images reviewed. Earlier shell/protected-refresh/isolated debt/pending proofs retain their exact scope. |
| AC18 | The 19-case Projects suite passed exact identity, generation, request and cancellation rules. Current native exact multi-packet selection/deletion passed in 28.256 seconds, single confirmed deletion in 12.171 and conditional/cancelled actions in 120.855. Final follow-up pixels remain open; no live project reset or host mutation is inferred from fixtures. |
| AC19 | Current project/packet Continuity preserves its source scope without manual budget/rollover controls or invented successor completion. Stale cancelled publication was reproduced and repaired with paired tests. A native List selection setter stack motivated a local-state bridge; fresh exact-selection and conditional cases passed without the publishing warning. Other observed native diagnostics remain distinct. |
| AC20 | Rune Forge retains sources, interpretation/feed, cached history/export and continuing-work semantics. Native opaque-source acceptance, picker cancellation and four-format export picker passed named cases. Current policy/detail/export presentation captures were reviewed; picker evidence remains distinct from production deployment. |
| AC21 | Catalogs/feed/evidence keep their current scope and bounded models. Evidence pagination/error/retry passed in 26.025 seconds while preserving the page. Final empty/configured/populated/conditional capture states were reviewed. |
| AC22 | Native file selection/cancellation and four-format export picker checkpoints passed. The earlier ordinary candidate produced actual paired JSON/Markdown with counts/redaction asserted. The new current candidate has only build/signature evidence so far; its four ordinary onboarding/export cases remain pending. |
| AC23 | Existing action identifiers remain available through Settings/menus or explicitly enabled controls; additive Tools leaf IDs support exact geometry checks. Native3 individual opt-in, shared guidance, Settings/menu parity and opt-out/relaunch passed. Current preferences/persistence and opt-out/relaunch passed in 197.555/120.789 seconds. Fixture accessibility/focus and two-size Tools geometry passed; all three focus and two focused Tools images were reviewed. Native Settings minimum subsequently passed in 134.245 seconds with fourteen reviewed images; revision 2 full palette coverage remains open. |
| AC24 | Earlier opaque token/series cases and literal MCP yes/no/pending supplement color. Actual Light with Increase Contrast, Reduce Transparency and Reduce Motion passed without a fixture variant, with all eight captures reviewed and original preferences restored. Current Graphite 10-case and fixture accessibility/focus proofs are distinct from that actual-OS checkpoint; no blanket accessibility certification is claimed. |
| AC25 | Changed geometry and fresh four-case production lifecycle proof retain bounded vertices, gaps, demand drawing, hidden/ordered-out quiescence, resource/buffer reuse and dismantle ownership. Earlier 100-cycle native navigation and two telemetry contract cases passed. Three GPU engine accessibility containers change no rendering/metric mapping; minimum pixel readback remains open. |
| AC26 | Named navigation, draft preservation, request absence and cancellation checkpoints passed. Current read-only review 7 retains Dashboard project ownership; earlier native confirmation and all-eight-step scroll/progress passed with 11 fresh wizard-top pixels reviewed. Upcoming wizard-copy correction and its final current-input validation remain open. |
| AC27 | Current SwiftPM app/CLI builds passed in 2.99/0.19 seconds; the ordinary My Mac Debug build succeeded and matching 12-check graph audit passed. Current 76 app-hosted cases passed. The latest eleven-case native batch terminated with exit 65: 9 passed, 2 failed, 0 skipped in 922.117 seconds. Final corrections, ordinary candidate four workflows, frozen-input hygiene and remaining pixel review stay open. |
| AC28 | Permanent xcresult attachments retain earlier complete matrices and the native3 103-PNG follow-up; 29 assigned secondary/Manager/Settings images were opened. Current every-view passed in 258.873 seconds; the mixed-result final batch exported 88 PNGs. All 26 assigned final secondary/Manager/Tools/focus PNGs were opened with no new defect observed. Later minimum Settings passed with fourteen reviewed images; remaining chip/palette scopes retain their separate gates. |
| AC29 | Current authorities align to 0.17.0 (27). The e75ed36… source manifest and ad6014… signed ordinary candidate identify a tested build checkpoint before upcoming edits. Earlier candidate/bootstrap receipts retain their identities; new ordinary four workflows, final manifest/candidate and document closure remain open. |
| AC30 | Owner-directed source/wiki publication is pending the later Settings-first/layout validation. Exact published refs, local/remote divergence and clean-tree verification will be recorded externally under /Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-04-graphite-workbench to avoid self-referential commits. Installation, notarization, App Store Connect upload and distribution were not performed. |

## Reopened phase closeout

The earlier UI checkpoint passed build, interaction, visual, parity and
lifecycle checks. The owner’s later control-placement and typography scope
requires fresh current-input tests, every-view QA, identities and publication. Complete result bundles and
source/candidate identities are retained separately from the source tree under
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-04-graphite-workbench`.
Publication records exact source/wiki refs and synchronization there rather
than editing a commit to describe its own identity.

The earlier failed debt/Doctor lookup, pending-fence compilation attempt,
partial capture batches and first ordinary onboarding/export attempt remain
recorded above. They are not counted as passing batches. Their corrected
selected cases subsequently executed successfully. A skip or zero selected
tests is not a pass. Neither fixtures nor successful source builds qualify live
ServiceManagement registration, provider installation/deployment or shipment.

The earlier verified scope rests on the retained source identity, terminal results,
selected case counts, failures and actual capture review recorded in
[ROADMAP.md](../ROADMAP.md). Historical qualification receipts keep their tested
version. Installation, notarization, App Store Connect upload and distribution
are outside this phase; the owner performs shipment separately.

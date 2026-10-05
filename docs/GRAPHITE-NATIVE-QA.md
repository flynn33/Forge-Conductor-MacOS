# Graphite native QA

<!-- FORGE-DASHBOARD-COLUMNS-FOLLOWUP:BEGIN -->
## Current Dashboard columns — implementation and QA complete

Version/build remains **0.17.0 (27)**. The Dashboard lower panels use two
independent, equal-width stacks: MCP Servers above MCP Tools at left,
Sub-agents above Hot Processes at right. Their outer top/bottom bounds align;
internal splits follow content. Hot Processes starts below Sub-agents and
fills the remaining right-column height. Approved Compute chips/effects,
panel content, actions and accessibility identifiers are retained.

The fresh public direct-XCTest native selection passed **13 unique methods in
13 invocations**, zero failures/skips, with matched observer counts; execution
time was **239.089 seconds**. All **358 PNGs** were individually opened and
rehashed: **354 NSView caches and four separate genuine Metal drawable
readbacks**. The final review union records zero blocking visual findings and
no missing reviews/hash mismatches. It covers all 13 routes at 1440×900 and
1100×720 content sizes, nine Manager sections/Settings component, eight setup
steps, registration/nested Help, full reachable root/secondary/route Guides,
and populated/bootstrap-empty Dashboard geometry.

| Dashboard state | MCP Servers | MCP Tools | Sub-agents | Hot Processes |
| --- | ---: | ---: | ---: | ---: |
| Populated, normal | 936 pt | 424 pt | 510 pt | 850 pt |
| Populated, minimum | 1324 pt | 636 pt | 624 pt | 1336 pt |
| Bootstrap-empty, both sizes | 201 pt | 201 pt | 201 pt | 201 pt |

These are painted native AX heights. Both sizes have zero outer top/bottom
delta and column widths equal within one point; internal row boundaries are
not required to align. Source gaps are 14 points horizontally and 12 points
vertically, with painted gaps of 13 and 11 points. The empty case uses its
explicit bootstrap-failure seam; it does not prove successful empty telemetry.

The current **434-input** source manifest is
`81a91a81d29ce6a22a51acaeced820b1d6b5163b3d330a2fdf6266cec6774ae8`.
Comparison against the preceding `2463aa06…` inventory changes only
`RigDashboardView.swift` and `ForgeConductorUITests.swift`: the other 432
inputs, canonical project and all 30 resources are byte-identical. The
project SHA-256 remains
`a5ecf9dc66845891929ac5de31820a22a355dabb38668dd93ce3849f9f069b1d`.
Approved Compute geometry/art/shader/renderer/projection inputs are unchanged.

The ordinary canonical My Mac Debug build passed with strict deep signature
verification, version **0.17.0**, build **27**, Apple Development team
`9AQ2C2838M`, CDHash `7ddf205eb1ce98e5bc83c891cd880053f2bc5311`.
Candidate: `build/dashboard-columns-app-final/Build/Products/Debug/Forge Conductor.app`.
The canonical UI target also passed build-for-testing, including compilation
of the changed parity test; this is compile-only proof, with no canonical
testmanager execution claim. Retained unrelated test compiler warnings are
not called warning-free.

| Current authority | SHA-256 |
| --- | --- |
| `build/graphite-results/dashboard-columns-current-native-execution-summary.json` | `0dbaf44dc7e4ebd221a5ddac06b080164c37641a67ddb29d79a46c40a418527f` |
| `build/graphite-results/dashboard-columns-final-qa-summary.json` | `f82101afeecb0d1bce5246b8043401b43404597c97a062f0e2471462f2e30a75` |
| `build/graphite-results/dashboard-columns-ordinary-candidate-identity.json` | `7621aad5e7bb2cd0894976734497edc20e2772750f6929b40bc6398facc02ce9` |
| `build/graphite-results/dashboard-columns-canonical-ui-compile.json` | `fb8c9e8f212ec3a760d044fc5c292472a4fc5a42318529633e668b7ccb66073b` |
| `build/graphite-results/dashboard-columns-evidence-retention.json` | `eb07bec1a2a05a906bbd228e5016f05844f95c28ade6c168c2d8890c468baa27` |

Execution/build/visual inputs are retained at
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-04-graphite-workbench/dashboard-columns-20261005T101913Z`.
The initial archive index SHA-256 is
`a8b2bde12134a1dfdcaa3961a88dbea3e8755ee5851b767f0cf6c0b9f7bf4a87`;
final documentation and owner publication/readback/synchronization identities
are appended externally, avoiding self-referential commit records.

These fixtures execute production ContentView/AppModel through public
AppKit/XCTest with private home/defaults and a read-only HTTP fixture. Bitmap
caches omit Metal and ordinary compositor/chrome; drawable blits include Metal
alone. They do not establish new whole-window composition, ordinary Settings
Scene, installed-product or 2× display proof. Preceding Compute checks, motion,
ordinary workflows and broader matrix retain their exact inputs and evidence
limits. They are not added to this 13-method count or relabeled as fresh runs.
The `2463aa06…`/357-image frame refinement and `28548a73…`/116-test/463-image
qualification below remain preceding checkpoints. No installation, notarization,
App Store upload or distribution was performed.
<!-- FORGE-DASHBOARD-COLUMNS-FOLLOWUP:END -->

<!-- FORGE-COMPUTE-FRAME-FOLLOWUP:BEGIN -->
## Preceding frame refinement — source 2463aa06…

Version/build remains **0.17.0 (27)** for this Unreleased iteration. Compute
frames are smaller and darker; duplicate visible hardware names and activity
badges are removed while exact accessibility identities and states remain.
The approved chips and telemetry effects are preserved. Dashboard omits its
inline Guided Mode banner and guide button; other routes retain guidance.
Workbench Settings labels its existing action **Open Guide**. Sub-agents and
Hot Processes fill the same grid row, retaining its 200-point minimum.

The current scoped source manifest `2463aa06…` covers 434 inputs with unchanged
canonical build graph and all 30 resource files. Thirteen native view methods
passed and all 357 successful PNGs were reviewed; the one failed fixture
invocation is retained separately. The matching My Mac Debug build and strict
signature verification passed (candidate CDHash `3b5399f0…`). Separate Compute
checks, their overlapping SwiftPM repeat and exact evidence limits are recorded
in [the Compute phase record](COMPUTE-CORES.md). The `28548a73…` source, 116-test/140-execution and 463-image
receipts below remain the preceding checkpoint, not fresh proof of changed
inputs. Exact owner publication and synchronization refs are recorded externally.
<!-- FORGE-COMPUTE-FRAME-FOLLOWUP:END -->

## Preceding frame-refinement native QA

| Follow-up scope | Actual completed evidence |
| --- | --- |
| Smaller, darker Compute frames | Normal/minimum Dashboard geometry/layout reviewed; separate 68-PNG Compute checkpoint preserves approved chip details/effects and records current 1× raster limits |
| Duplicate visible identity/status removal | Exact hardware-name/activity-state AX identifiers and values retained in native assertions; duplicate visible labels/badges absent in reviewed captures |
| Dashboard guidance and Settings Open Guide | Guided Mode enabled with Dashboard banner absent, Manager guidance retained; actual Settings component Open Guide opens the exact Manager guide AXHeading and Close dismisses it at both sizes |
| Sub-agents/Hot Processes sibling-row fill | Native painted edges have zero top/bottom delta at both sizes; populated heights 510/624 points and bootstrap-empty heights 201 points, preserving the source's 200-point minimum |
| Changed inputs and ordinary build | Current 434-input manifest 2463aa06… preserves graph/all 30 resources; My Mac Debug build and strict Apple Development signature passed, candidate CDHash 3b5399f0… |

The current public native fixture selection has **13 successful invocations
across 13 unique methods** and **357 individually reviewed successful PNGs**.
Fourteen total invocations include one preserved failed new Guide assertion:
the fixture expected AXStaticText although its actual observation recorded
Manager guide as AXHeading. The immutable second fixture corrects only that
bounded exact-title lookup; the successful rerun is counted once, and the two
failed-attempt PNGs are excluded. All successful invocations executed one case,
with zero failures/skips and matched observer counts.

The fresh selection covers all 13 routes at 1440×900 and 1100×720 content sizes,
all nine Manager sections/Settings component, eight setup steps, registration,
nested Help and reachable root/secondary/route Guide bodies at both sizes.
Authority: `build/graphite-results/compute-frame-refinement-final-qa-summary.json`,
SHA-256 `633d46de48a1f760d51dca9d63c577544b2d3639660ad810dab7a30bd2e7828d`.
This is actual production ContentView/AppModel under isolated public
AppKit/XCTest hosting. Native bitmap caches and separate genuine Metal blits
are separate evidence layers; no ordinary compositor, Settings Scene chrome
or canonical testmanager execution is claimed. The canonical UI target compiled
only. The earlier 30-case Compute selection predates the final Rig row change;
its 16-case SwiftPM repeat overlaps, its original full product dependency is
no longer replayable, and the preserved Compute input comparison bounds reuse.
See [Compute qualification](COMPUTE-CORES.md) for exact source/build identities.

The preceding broader matrix, runtime workflows, actual Settings Scene and
Cancel/state cases below retain their original identity. They are not fresh
executions of this changed source. Distribution and unobserved compositor/
display classes remain outside this narrow completed UI refinement.

## Preceding qualified checkpoint — 0.17.0 (27), source 28548a73…

**Preceding UI implementation and QA complete.**
0.17.0 (27) source manifest 28548a73… passed **116 distinct production tests in 140
successful executions**, with zero failures/skips. The separate native view
matrix passed **21 unique methods in 22 invocations**; all **463 selected PNGs**
were individually opened and reviewed. The 15-check/434-input audit, matching
signed Debug build and four scoped ordinary workflows passed. Historical
failures and superseded inputs remain separate. Native caches, genuine Metal
readbacks and ordinary observations retain their explicit limits; no
installation, notarization, App Store upload or distribution was performed.
Exact owner publication/readback/synchronization refs are retained externally.

## Preceding selected native matrix

The source 28548a73… selected matrix passed 22 invocations across 21 unique methods,
zero failures/skips. All 463 selectedPNG files were individually opened and
rehashed against their actual review receipts:281 parent caches,166 sheet caches,
14 NSAlert caches and 2 separate production Metal readbacks. The rich/unavailable
secondary-Help profiles share one method. Final linked credential and minimum
error/recovery lower frames are complete. Two superseded successful framing
checkpoints and 12 failedattempts remain excluded from the selected union.

Authority: `build/graphite-results/native-workbench-final-matrix-28548a73-qualification.json`,
SHA-256 `c90e3448f07409c27ec6520cfd0e7983a40ec7f41b11b7e605bfefb4a21cdf30`.
The selected invocation inventory is SHA-256
`cb38950fbcd9dbe0b427c0fa57955fe9502e436ceada9414441051ddc5dcff8e`.
This is bounded public direct-XCTest native fixture execution, not an
xcodebuild/testmanager/XCUITest UI result. No unavailable runner invocation,
timeout, skip or zero-selected result is counted as a pass.

| Current scope | Exercised/reviewed available native evidence |
|---|---|
|13 primary routes | Normal 1440×900 and minimum 1100×720 content fixtures, including emptyProjects; current shared palette and default absence of persistent optional controls |
| Dashboard | Top/lower MCP/tool/subagent/process/stream/storage information at both sizes, with 2 separate genuine chip Metal readbacks |
| Manager/Settings | All 9 sections and Settings component at both sizes, immediate versus staged fields, optionalcontrol/draft preservation |
| Guided Setup | All 8 actual steps at both sizes, paired top/tails, read-only project review and truthful prerequisite states |
| Guides | Registration/nestedGuide; full root/secondary/route Advanced tails; related/unavailable contexts; no invented openers for 3 retainedcatalog contexts |
| Details/states | Provider Advanced middle/tail/inspection; Runtime/Rune/packet details; nativeDoctor; populated/empty/busy/linked unsaved guard/error/retry/search |
| Actions | Six independentopt-ins and retained staged drafts;14 actualCancel dismissals (7 confirmations×2 sizes), with no recorded mutations |

## Preceding production and ordinary proof

Current production qualification is 116 distinct tests/140 successful executions,
with zero failures/skips. It comprises native 29+68+proper canonical 33 with 24
Provider repeats counted once, plus freshCore 8/H0 (1)/G1 (1). CLI/App and canonical
ordinaryDebug builds passed separately. The native view matrix is not added to
that production total.

Four matching signed ordinary workflows passed: healthy 16/failure 3 paired
Diagnostics exports through real NSOpenPanel with scope/redaction; folderSelect/
Cancel/root rejection/save/relaunch; shellOFF/relaunch/ON plus real MCP denial/
exact execution. Actual ordinary Settings 900×560 content/900×592 outer had all 9
sections reviewed, unsavedhost draft retained whileHTTPstayed saved, explicit
Reload restored savedvalue, all 6 opt-ins observed, Setup-only persistence on
same suite relaunch, and all preferences restored. About/version/icon and native
Navigation/Telemetry/Guide menus were observed. Dashboard 1440×900@2× top/full
Compute/lower/bottom and Pause/Resume were composed Cua observations; no durable
compositorPNG is claimed. Allowned cases ended through native Quit; seven live
registration byte sets per case unchanged and twelve private suite key sets empty.

## Exact limits

Parent/sheet caches do not prove native chrome/modal dimming/placement or
full-windowMetal composition; Settings-component caches are not Settings scene
chrome. All 14 NSAlertcaches omit the Cancel caption and contain transparent/
background/destructive-label artifacts. Titles/messages and successful native
Cancel ownership/actions are supported, but ordinary alert-button contrast is
unqualified by those caches. NativeOSchrome is not a custompalette target.

68 currentCompute layers and 20 genuine MOVframes are separately reviewed and not
included among 463. Paused/hidden/lifecycle clock/submit measurements are runtime
phase receipts, not fabricated dedicated PNGs or continuouswhole-windowmovies.
Typedfixture activity is not measuredCPU/GPUtraffic. CPU/GPU unknown/fallback/
zero/stale/paused and illustrativeaggregate semantics remain distinct.

Physical 1×, ordinary minimum and Sky sheet-compositor pixels/Close were unavailable
or not exercised. Faithful current native normal/minimum fixtures plus matching
signedordinaryruntime workflows satisfy the authorized UIQA without introducing
new proof classes as perpetual gates. Cua service crashes remain its observed
failure history; no unproven Projects causality is asserted. Installedapp,
credentials, remoteproviderhealth, privilegeddeployment, distribution and
notarization are not qualified by isolatedfixtures.

## Repeatable navigation reference

## Efficient route and size pass

Use the unchanged native HTTP fixture only in its isolated test home. Record
candidate path/hash, fixture mode, screen/scale and original window geometry
before interaction. Start with the control bar absent. Keep all fixture
mutation counters or exact request records for actions that should only inspect
state. Preserve the working installation, live project data and registrations.

Normal target: **1440×900 content**. Main minimum: **1100×720 content**.
Settings minimum: **760×560 content**; prior native outer measurement was
760×592, but remeasure the current window. Record actual dimensions rather
than inferring them from a screenshot label. Restore starting geometry and all
local preference changes at the end.

For each size, visit the sidebar once in this order; capture the whole window,
then scroll to any lower content. Menu shortcuts avoid repeated sidebar trips:
Projects **Shift-Command-1**, Continuity **Shift-Command-3**, Runtimes
**Shift-Command-4**, Provider **Shift-Command-5**, Evidence **Shift-Command-6**.
Use **Control-Command-S** to restore a hidden sidebar and **Command-R** to
refresh. Native Settings is **Command-,**; close its window with **Command-W**.
Open Guide/Guided Setup from the **Guide** menu and dismiss sheets with Escape.



## Records and owner delivery

[Graphite](GRAPHITE-WORKBENCH.md) records 30 adapted criteria;
[Compute](COMPUTE-CORES.md) records 32 criteria/18 capture scopes and exact source/
artifact/runtime evidence. [Checkpoint history](COMPUTE-CORES-CHECKPOINTS.md)
retains all earlierpasses/failures/timeouts/unavailable runner states.
Implementation/required QA/docs are complete; exact owner source/wiki publication,
readback/safe synchronization/zero divergence/clean-tree proof is recorded
externally after publication. No installation/notarization/App Store Connect
upload or distribution was performed.

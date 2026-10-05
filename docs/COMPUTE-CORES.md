# Compute Cores Metal FX and application palette

<!-- FORGE-DASHBOARD-COLUMNS-FOLLOWUP:BEGIN -->
## Current Dashboard columns — implementation and QA complete

**0.17.0 (27)** uses two independent, equal-width column stacks: MCP Servers
above MCP Tools on the left, Sub-agents above Hot Processes on the right.
Their outer top/bottom bounds align; internal splits follow content. Hot
Processes fills the remaining right-column height. Approved Compute chips,
effects, panel content and accessibility identifiers are retained.

Thirteen public native view methods passed with zero failures/skips, and all
358 PNGs were individually reviewed. The matching My Mac Debug build and
strict signature verification passed; the canonical UI target compiled only.
[Native QA](GRAPHITE-NATIVE-QA.md) records exact source/build identities, separate cache/Metal
layers and retained evidence. The frame and broader qualification records
below remain preceding checkpoints; their executions are not relabeled.
Exact owner publication and synchronization refs are recorded externally.
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

`ComputeChipLayout` retains `packageScale = 0.46` and the approved chip, bank,
nameplate and trace construction. Panel height decreases by 86 points,
horizontal inset is bounded at 36 points, and the kind-9 panel fill is
`0x020817`. Completed artwork/routes translate without rescaling. Exact full
hardware names belong to `compute-cpu-hardware-name` and
`compute-gpu-hardware-name` on the native nameplates; visually clear native
state elements retain both `compute-*-activity-state` identifiers. Current
native assertions and normal/minimum review verify those retained semantics
and compact-frame clearance. All 30 resource files, the canonical Xcode graph,
shader, renderer, animation and projection match the preceding inputs.

## Preceding frame-refinement qualification

| Check | Actual result | Input and evidence boundary |
| --- | --- | --- |
| Public direct-XCTest Compute selection | 30 selected/executed, zero failures/skips, terminal 0; 22.824 seconds | 16 pure, 6 lifecycle and 8 presentation cases; predates the final Rig sibling-row addition. Exact Compute production/test inputs remain unchanged; it is not one identical final App snapshot |
| SwiftPM `ComputeChipAppTests` | 16 executed, zero failures/skips, terminal 0; 0.043 seconds | Repeats the 16 pure Compute cases above; the zero-case qualification-support bundle is excluded, so these are not 46 distinct tests |
| Current native view matrix | 13 successful methods/invocations, zero failures/skips within that successful selection; 357 successful PNGs individually reviewed | 14 total invocations include one preserved failed new Guide-role fixture assertion; the corrected immutable fixture uses the actual AXHeading. Actual production ContentView/AppModel in isolated public AppKit/XCTest hosting, not canonical testmanager or ordinary runtime execution |
| Compute visual checkpoint | All 68 PNGs opened; no blocking defect in captured layers | 27 genuine static Metal readbacks, 20 genuine drawable motion frames and 21 NSView caches. Separate layers, current 1× backing scale; no compositor or current 2× raster claim |
| Sub-agents/Hot Processes layout | Normal/minimum populated and bootstrap-empty panel edges match, zero top/bottom delta | Painted native AX heights 510/624 points populated, 201 points bootstrap-empty; the source minimum remains 200 points. No host-process mutation or successful-bootstrap claim for the explicitly failing-bootstrap seam |
| Dashboard and Settings guide action | Passed at normal/minimum size | Guided Mode enabled with Dashboard banner absent, Manager inline guide retained, actual settings-show-guide Open Guide action opens exact Manager guide AXHeading and Close dismisses it |
| Ordinary My Mac Debug candidate | BUILD SUCCEEDED and strict signature verification terminal 0 | Version 0.17.0, build 27; Apple Development team 9AQ2C2838M, CDHash 3b5399f06cb3494d0c63a34efb3b8c210b31abf1. Build/signature only; preceding ordinary workflows are not relabeled |
| AppTests/canonical UI target and external fixture compilation | Successful compilation, separately recorded | Compile-only proof does not count as UI execution. Retained test/helper warnings are not called warning-free |

Current view authority:
`build/graphite-results/compute-frame-refinement-final-qa-summary.json`, SHA-256
`633d46de48a1f760d51dca9d63c577544b2d3639660ad810dab7a30bd2e7828d`.
The actual successful selection covers all 13 routes at normal 1440×900 and
minimum 1100×720 content sizes, nine Manager sections and the Settings component,
eight setup steps at both sizes, registration/nested Help, full reachable root
and secondary Guide bodies, plus the new guide-placement and row-fill cases.
The failed initial Guide invocation expected AXStaticText for a title recorded
as AXHeading; its assertion and thrown wrapper generated two issues. Only the
fixture's bounded exact-title lookup was corrected, with production bytes
unchanged. Its two PNGs are excluded from the 357 successful-image union.

Current source inventory: **434 inputs**, SHA-256
`2463aa065e049627d8c6af3d9188f2258da060fa2d04c4a1e8b0770e4ee777e9`.
The scoped membership/preservation review is
`/tmp/forge-frame-refinement-delivery-membership-review.json`, SHA-256
`986f6ebcedf629e0b838df81383a0842a6968b762345daa35ef9c2e6c093734a`;
all recorded checks passed, original graph/resource memberships and bytes remain
unchanged, and changed Swift files retain existing native target membership.
The project SHA-256 remains
`a5ecf9dc66845891929ac5de31820a22a355dabb38668dd93ce3849f9f069b1d`.
The candidate identity receipt is
`build/graphite-results/compute-frame-refinement-ordinary-candidate-identity.json`,
SHA-256 `6c6758064db1177cd39088c89448bf43cdc21a3459afc74adaa2c55fd0ce4dc4`.

The earlier 30-case native execution remains an executed checkpoint with its
recorded module/resource hashes, events and 68 reviewed PNGs. Its original
AppTests executable was subsequently overwritten and is unavailable; the app
dylib at that former path now differs from the recorded execution identity.
That initial full product dependency cannot be replayed from the current path.
The preserved Compute input comparison supports the bounded reuse above;
the final native view product and replay inputs are retained separately.
No missing dependency is treated as a fresh execution or byte-identical bundle.

Additional authorities: `compute-frame-refinement-68-pixel-review.json`
(SHA-256 `102896fe8f78d3b2434d341497e7f16615629df54dce6d11ae1d85fcfe63a73a`),
the earlier native `compute-current-receipt.json`/events,
`/tmp/forge-frame-refinement-swift-test.log`,
`/tmp/forge-frame-refinement-app-final-build.log` and
`/tmp/forge-frame-refinement-apphost-final-build.log`.
Delivery evidence location:
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-04-graphite-workbench/compute-frame-refinement-20261005T093248Z`.
Exact owner publication/synchronization refs are recorded externally.
No installation, notarization, App Store Connect upload or distribution is claimed.

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

Preceding source: **0.17.0 (27)**, `28548a73…`. **Revision 2 implementation and required QA: verified for those inputs.**
Detailed CPU/GPU chip presentation is integrated in the retained Dashboard
frame. The approved application colors use the existing shared palette;
the Compute increment compares against the already-authorized Graphite UI
checkpoint: outside Compute Cores, its layouts, typography sizes, controls,
data, navigation and other renderer clocks remain the preservation contract.
The full original-main-to-current phase also includes the requested Manager
nine-section navigation, Provider split layout, Projects action/text alignment
and Settings-first optional controls; those are authorized Graphite changes.
All 32 criteria and 18 capture scopes below are fulfilled in their named current
source/native/ordinary bounds. Exact owner publication/readback/synchronization
refs are retained externally.

**Exact-reference correction — current covered layers and native matrix verified:** the owner rejected the
approximate chip artwork. Current source bundles only `ComputeChipReference.png`,
byte-identical to `/Users/flynn/Downloads/Compute Cores Dashboard.png`:
1448×1086, 1,682,363 bytes, SHA-256
`7184bbb39a6b014b32283869557edb6166acecd1bc8f201401ceda02169975f1`. The earlier two 1254×1254
unlit materials are removed from current resource inputs and retained as rejected
checkpoints outside the checkout under `/tmp/forge-compute-material-checkpoints/source-assets`.

`ComputeChipResources` derives one 440×440 CPU and one 464×464 GPU crop from
the exact reference. Bounded processing replaces photographed activity, sample
model text and annotation leaders; the photographic package/frame/grain detail
is reference-derived. These processed rasters are not claimed byte-identical to
the original crops or a lossless recovery of unlit artwork. Two cached CGImages
also serve genuine static fallback; normal Metal uses two immutable textures,
nine mip levels each and one sampler. No per-frame image decode/upload is added.
The latest explicit resize allowance retains `.46` preceding dimensions
(179.4-point maximum); even at 2× the package does not exceed either crop's
native source resolution. The earlier `.4`/60% reduction remains historical.

Metal lights must brighten and change color with valid telemetry. Runtime
identity, CPU logical topology, illustrative aggregate GPU regions, independent
freshness, zero versus missing, pause and Reduce Motion retain their contracts.
The corrected fifth-pilot material review found no remaining blocking defect
in its selected 12/50/82% frames. The current selected native matrix passed; Exact owner publication/readback/synchronization refs are retained externally. Matching ordinary normal
Dashboard/Pause/Resume, Settings and four scoped runtime workflows were
observed; ordinary minimum/1×/Sky compositor limits remain explicit.

## Current material source audit

The latest completed audit passed **15/15** checks over **434 inputs**, source
manifest SHA-256
`28548a73db312130f02e3c86344725f2aa1efca575901fa0ae3dc223b69eb3d1`.
Independent readback matched all 434 listed file hashes at reconciliation.
Canonical project SHA-256 remains
`a5ecf9dc66845891929ac5de31820a22a355dabb38668dd93ce3849f9f069b1d`;
audit SHA-256 is
`4febeade69469f3930404930cf83132c0bf1f95e40226e8453eed597f8a9e914`.
Exact copies are under `build/graphite-results/final-lifecycle-repairs`.
This records the tested current UI scope; exact owner publication/readback/synchronization refs are retained externally.

There are **30 resource inputs**: all original 29 memberships remain, 28 original
byte sets are unchanged, the requested Guide catalog copy retains its schema,
and exactly one app/native/SwiftPM PNG is added. All 26 signing/deployment
configurations retain their settings. The preceding 435-input/two-material
and c4de77… inventories remain [checkpoints](COMPUTE-CORES-CHECKPOINTS.md).

## Exact-reference native pilots — retained checkpoint

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

Current combined receipt:
`build/graphite-results/final-285-current-swift/combined-current-qualification.json`,
SHA-256 `f0e1cc95edb04129006337140b38084752218e0ac8a4904f0aa4cfce0bb0413d`.
It verifies **116 distinct selected production tests / 140 successful
executions**, zero failures/skips. The ten focused SwiftPM cases are disjoint
from the106-case native union. Historical repeats and the native view matrix
are excluded from this production total.

| Current scope | Actual result | Evidence class |
|---|---|---|
| Compute 29 |29 passed,24.254s | Public direct-XCTest:15pure,6native lifecycle,8presentation, including current invalid/idle/fallback transitions |
| App regression 68 |68 passed,25.739s | Public direct-XCTest: Graphite 11, Guided3, Review7, Legacy7, Projects16, Provider24 |
| Canonical Provider 33 |33 passed,4.907s summed case time | Proper My Mac xcodebuild app-hosted tests;24Provider cases overlap the regression scope |
| Core provenance8 |8 actual starts/passes, zero failures/skips | Fresh focused SwiftPM,7.892s command |
| H0 version1 |1 actual qualification-support case passed; unrelated app bundle0 excluded | Fresh focused SwiftPM,1.482s command |
| G1 version/document1 |1 actual case passed | Fresh focused SwiftPM,1.306s command; initial marker failure remains historical |
| CLI/App builds |terminal0,0.956s/4.684s | Compilation only; source434 hashes verified before/after each command |

The native-only receipt remains
`final-lifecycle-repairs/combined-current-qualification.json`, SHA-256
`bfdce3ddc4ef2afa5e6eefe60e55297183db86596273359688a4cbee20584462`:
106 distinct tests in 130 successful executions, with 24 repeated Provider cases. None of these
selected results is described as a single full-suite invocation. All earlier
failed/skipped/zero-selected/time-out checkpoints remain in the
[history](COMPUTE-CORES-CHECKPOINTS.md), including third/fourth reference-pilot
failures, CLI-development-identity fixture mistakes and the initial G1 marker.

## Current Compute layer review and motion

Independent review separately opened all **68 current Compute PNG layers**:
27 production Metal still drawables, 16 native text/layout caches without
Metal, 20 genuine Metal motion drawables and 5 static fallback caches. It found
no observed blocking visual defect in these layers; no old c4de77… images were
counted as current. Exact paths/hashes and findings are in
`build/graphite-results/compute-final-lifecycle-repairs-pixel-qa-review.json`,
SHA-256 `04f561cb6e347062e3f5c9b9ea5570a6842bf41a63893f1dccbf02c7a79b01e4`.

The same-mounted fallback transitions show current Idle/measured zero,
Activity unavailable/missing and Paused labels without an old Active badge.
The detailed static chip remains visible. GPU zero/12/82 illumination rises
independently; the single logical CPU changes only its mapped bank. Material
frame/grain, asymmetric contacts, clean plates and native long/blank hardware
identities remain readable. Separate/combined capability fixtures retain native
control states. Twenty raw motion frames show moving bounded heads/tails;
this is native drawable evidence, not a whole-window or measured host movie.

Native fixture assertions after Metal resources are removed verify no owned
Metal surfaces, buffers, in-flight slots or recurring clocks, and unchanged
submissions across fallback state changes. Attached hidden surfaces remain
quiescent with their seven reusable buffers; that is separate from detached
zero ownership. No current paused-only PNG is claimed.

NSView caches omit Metal. Paired production readbacks are separate layers,
not compositor screenshots or ordinary-window integration proof. Image-viewer
resizing is also distinct from retained original dimensions/hashes. The earlier
65-layer review, cold Debug lookup and measured process-CPU phases retain their
precise checkpoint boundaries in
[history](COMPUTE-CORES-CHECKPOINTS.md#equal-project-actions-checkpoint-before-lifecycle-transitions).

Current source manifest 28548a73… also has a verified **20-frame genuine drawable MOV**:
`/tmp/forge-direct-xctest-host/final-lifecycle-repairs-compute-production-motion.mov`,
23,893,625 bytes, SHA-256
`5d1ceb4f75bf6a12b8791d7bc35b5eb64a085cd6a466940a81ae20220e3e4085`.
The receipt `build/graphite-results/compute-final-lifecycle-repairs-motion-evidence.json`
(SHA-256 `ceb43fd96056f1fc2fa9777b658e0fae0858e5403cebfada927c5fa9efea7bed`)
records 20distinctsourcePNGs,20encodedmedia samples, recorded completion-time
PTS and RGB/orientation checks. The 1856×1088 ProRes4444 viewing derivative is
6.440s; exact original PNGs remain authoritative. No interpolation, whole-window
movie, measured workload, real-time smoothness or lossless post-codec equality
is claimed. Ordinary normal composed Dashboard has separate inline observations;
the current normal/minimum native matrix is complete, as recorded in
[native QA](GRAPHITE-NATIVE-QA.md).

## Prior c4de77… view-fixture checkpoint — superseded

The six prior successful cases and157 reviewed images retain their exact older
inputs. They found the Projects action geometry and Wizard copy defects that
were corrected before the current28548a73… qualification. Earlier failures,
conditional-size assertion repair and subsequent successful framing checkpoints
remain factual history; they are excluded from the final current image union.
See [checkpoint history](COMPUTE-CORES-CHECKPOINTS.md).

## Current registration and contextual Guide fixture — verified

Current registration/nested Guide and all reachable root/secondary/route Guide
Advanced tails are included in the selected final matrix below. The catalog
retains23contexts;20have current visible openers. `projectReset`,
`continuitySaveProgress` and `continuityFreshSession` remain retained/unclaimed;
no invented visible route or action qualifies them. RunDetails remains a
styled, retained component without a current caller.

## Current native view and Guide review — verified

`build/graphite-results/native-workbench-final-matrix-28548a73-qualification.json`,
SHA-256 `c90e3448f07409c27ec6520cfd0e7983a40ec7f41b11b7e605bfefb4a21cdf30`,
records **22 successful invocations /21 unique methods**, zero failures/skips,
and **463 unique selected PNGs actually opened**. The original434 source
inputs stayed unchanged. Every selected file has matching review/hash evidence;
there are zero missing reviews and zero hash mismatches.

| Selected layer | Actually opened |
|---|---|
| Native parent NSView caches |281|
| Native sheet NSView caches |166|
| Native NSAlert caches |14|
| Separate production Metal drawable readbacks |2|

The matrix covers13 routes at normal/minimum sizes; Dashboard lower panels;
all 9 Manager sections and Settings component; all 8 Wizard steps with top/tails;
registration/nested Guide and full root/secondary/route Advanced bodies;
Provider Advanced middle/tail; read-only Runtime/Rune/packet details; empty
Projects/Continuity/Evidence; error/retry/search; busy preparation; linked
unsaved credential guards; six opt-ins/unsaved drafts; and all 14 actual Cancel
dismissals (seven confirmations at two sizes), with no recorded mutations.
The rich and unavailable secondary-Help profiles share one method, explaining
22 invocations versus21 methods. Native view fixtures are separate from the
116 distinct production-test union and four ordinary workflows.

Two earlier successful framing checkpoints (16 PNGs) and12 failed attempts
remain explicitly excluded. Final linked8/error12 snapshots expose full content,
including minimum lower recovery text. The [native QA record](GRAPHITE-NATIVE-QA.md)
records exact geometry/semantics, scene evidence and limitations.

All cache layers are separate native surfaces, not ordinary compositor
screenshots. NSView caches omit Metal. All14 NSAlert caches omit the Cancel
caption and show transparent/background/destructive-label artifacts: alert
message/layout and exact Cancel ownership/actions are supported, while ordinary
alert-button contrast is unqualified by these caches. Genuine Compute68 layers/
20-frame MOV are separate, not counted among463. Ordinary normal Settings/
Dashboard/runtime proof below complements native normal/minimum fixtures;
unavailable ordinary minimum/physical1×/Sky sheet compositor remain explicit
limits without inventing new acceptance gates.

## Current ordinary candidate — four manual workflows completed

The canonical Debug **My Mac** build ended with exit 0/`BUILD SUCCEEDED` in
**4.965 seconds** for the 434-input 28548a73… checkpoint. Root verified strict
deep Apple Development signing for team `9AQ2C2838M`, version 0.17.0 (27),
compiled function names and the exact reference resource. The identity receipt
is `build/graphite-results/final-lifecycle-repairs/ordinary-candidate-identity.json`;
the adjacent `ordinary-build.json` records the command/log. The separate
build-for-testing also passed in 5.460s; compilation is not runtime proof.

| Identity | Observed checkpoint value |
|---|---|
| App | `build/graphite-app/Build/Products/Debug/Forge Conductor.app` |
| Source | 434 inputs; `28548a73db312130f02e3c86344725f2aa1efca575901fa0ae3dc223b69eb3d1` |
| CDHash | `1a36aa4d3562781a1bd8f5b277848aecfa91b711` |
| Debug dylib | `54477bde293358352a52be2b9095475b5c27790720adfe9ad379d47935d44532` |
| Bundle manifest | 36 files; `495c4a4b2a4eec87521fdede1bd8863f3d538f09679b92a8b083ba4accda98db` |
| Compiled library | `default.metallib`, 19,564 bytes; `211de42e05e00cff244381eb0371b11efe97f5e20517ac7cd94ccc364562c4ab` |
| Functions present | `compute_chip_vertex`, `compute_chip_fragment` |
| Exact PNG packaged | 1,682,363 bytes; `7184bbb39a6b014b32283869557edb6166acecd1bc8f201401ceda02169975f1` |

Four matching **manual ordinary candidate** workflows completed. They are
actual Cua/native-panel interactions plus public AX/HTTP/MCP and file verifiers,
not XCUITest passes. The aggregate receipt is
`build/graphite-results/ordinary-current-candidate-workflows.json`, SHA-256
`5ec1cfcec237928f0dc996e85a79c0340f0ae1ebd4b92e4c41129e44bc393a97`;
its four `manual-native-workflow-receipt.json` paths retain exact PIDs,
transcripts, hashes and failure history.

| Ordinary workflow | Observed result |
|---|---|
| Healthy export | Real Diagnostics/NSOpenPanel **Export Here** wrote 16 paired JSON/Markdown records, zero omissions; persisted-history scope/redaction verifier exited 0. JSON `37c99fd20f3f3b8d8505a616c4604b338e3b5d6eb6c4b578d456fe679c34ec61`; Markdown `1e97bc57e5f669fe989483bae111805ba9fd48af8f73b767211b5239e0d96f8b`. Controlled earlier launches remain recorded; this is not a single-bootstrap claim. |
| Failure export | PID53885 used the real panel to export 3 paired records, zero omissions, truthful `live_ring_only`/unavailable-history scope and exactly one bootstrap-failure record. Redaction and three unique footer owners passed. JSON `fb60f36005747692dd6703165bee39f61eba7715735422fc43d7c79884db956e`; Markdown `f060c22a2056de24289f3484480295d3662704c733c38f948888ab599c7beba0`. |
| Authorized folder | PIDs53960→54461 exercised native Select/Cancel/root rejection/save/relaunch. Full settings were unchanged by cancel/rejection and matched saved settings after relaunch. Foundation's canonical `/tmp` path matched the expected inode; the initial external-helper alias mismatch remains recorded, with no product change. |
| Shell policy | PIDs54503→54550 exercised native Settings OFF/save/relaunch/OFF/ON/save. Fresh real MCP54540 was denied and MCP54624 executed in the same project, exact stdout `native-shell-restored`, exit0, empty stderr, no timeout/truncation and EOF0. Full re-enabled configuration matched the original. The earlier verifier-only `/private/tmp` versus `/tmp` mismatch remains retained. |

The healthy case reviewed all nine actual Settings sections at **900×560
content /900×592 outer**, including Workbench's lower controls and Doctor's
tail. Doctor truthfully reports a separately built candidate, not an installed
or deployed product; no deployment was attempted. An unsaved host draft
survived Settings → Workbench → Settings while HTTP stayed saved; explicit
Reload restored the saved value. All six optional controls were independently
observed, Setup alone persisted on same-home/suites relaunch, and all six were
then restored OFF. Native About showed 0.17.0 (27); Navigation/Telemetry/Guide
menus and their shared state were observed.

Actual composed Dashboard top, complete Compute frame, lower panels and bottom
were reviewed at **1440×900 content, physical2×**. Native Telemetry Pause/Resume
was exercised and restored ON. Final native Command-Q ended the exact owned
PID in every case. Each case retained unchanged bytes for all seven LM Studio
registrations; all **twelve isolated defaults suite key sets were empty** after
cleanup. An empty persistent dictionary is recorded distinctly from an absent
domain.

The actual ordinary Setup action opened an AXSheet with all eight-step IDs;
public AX reported244nodes/0errors. The earlier helper omitted the sheet, and
Sky state capture crashed with `Array.remove(at:)` while it was present.
Ordinary Setup pixels/Close, Projects compositor capture, ordinary minimum
resize and unavailable physical1× are **not claimed**. Manual screenshots are
inline tool evidence, not retained compositor PNGs. The final QA adaptation
combines these signed ordinary workflows/Settings/Dashboard observations with
current bounded native fixture normal/minimum view and sheet captures. It does
not require an unavailable proof class or weaken OS/service policy. The required current native matrix and current-source build/version refresh
passed. Exact owner publication/readback/synchronization refs are retained
externally.

Earlier ordinary identities and 3/8-record exports retain their exact old
inputs in [checkpoint history](COMPUTE-CORES-CHECKPOINTS.md). Installation,
notarization, App Store Connect upload and shipment were not performed.

## Authority and preservation


The current package is
`/Users/flynn/Downloads/Forge-Conductor-Compute-Cores-Metal-Palette-Instructions`.
Its `REVISION-2.md`, `verification/ACCEPTANCE.md`,
`instructions/07-application-color-alignment.md` and
`contracts/application-palette.json` define this scope.

The approved Compute Cores image owns the detailed package/die/contact/trace
appearance inside the existing frame. The latest owner clarification allows
slight resizing for exact artwork fidelity and requires telemetry-driven
brightness and color. Source now uses `.46` preceding dimensions, superseding
the earlier `.4` assertion while preserving the rest of the frame and product
contracts. Revision2 requires Metal + MetalKit for
normal chip illumination and moving trace FX, using build-time-compiled
shaders. A genuine resource/capability failure may use a truthful static native
fallback; fallback alone does not pass Metal FX acceptance.

The approved Graphite Workbench board owns colors in the later Compute
increment. Its outside-Compute preservation baseline is the already-authorized
Graphite checkpoint, not original main `df0b66c9…`. The broader phase includes
the owner-requested Manager/Provider/Projects/control and text/layout changes.
Against that authorized UI baseline, the Compute increment retains layout,
spacing, typography sizes, navigation, commands, controls, data and other clocks. Its obsolete
routes/sample controls have no dispatch or implementation authority. Existing
credentials, signing, isolation, time/output bounds and compatibility remain
required. Installation, notarization and shipment are separate owner work.

## Source and ownership

Dashboard projects GUI-host CPU/GPU samples and verified Metal identities into
`ComputeCoresContentView`. CPU source quality and GPU association/timestamps
remain separate; logical processor regions use current topology and GPU
regions illustrate aggregate activity. Trace travel is simulated, not measured
signal traffic. The source uses one native label/control layer and one Metal
surface, bounded layout/routes/pulses, reused frame slots and explicit renderer
eligibility/release. Current source partitions runtime CPU logical regions
across ten artwork banks (bounded at 256), maps sixteen illustrative GPU regions
across eight central/eight flank reference banks. Source-pixel masks/contacts
anchor bounded geometry and auxiliary lighting; at most 128 static routes per
package and 32 animated routes each remain. Artwork colors do not assert P/E
classification or measured GPU-core topology. Two cached CGImages, two shared
immutable mipmapped textures and one sampler retain explicit resource ownership.
Current selected Compute fixtures and their material/fallback/lifecycle layer
review passed. Hidden, detached, paused and reduced-motion observations retain
zero recurring clocks/submissions in the named native cases. Earlier exact
paused/visible/hidden process-CPU phases and the separate cold Debug lookup are
preserved in checkpoint history; they are not recast as current renderer-only,
long-duration or universal performance measurements. Current normal ordinary
Dashboard/Settings and the four runtime workflows have separate observations.
The current native minimum/control matrix passed with the cache/compositor
limits recorded above.

Read-only resource comparison retains all 29 original resource inputs; 28
original byte sets remain unchanged and only requested Guide catalog copy
changed. Exactly one reference PNG is additive in native resources and SwiftPM
copies. The latest complete audit above covers 434 inputs. The matching current
ordinary build/package and four scoped runtime workflows are recorded above;
final current native view/control QA passed; exact owner refs are retained externally.

`ComputeChipResources` loads compiled `ComputeChipShaders.metallib` or a
compiled default library and named functions. The current ordinary candidate packages
`default.metallib` as recorded above. No new runtime source compiler or theme
framework is introduced. Genuine Metal/resource failure has a truthful static
native fallback; that fallback alone does not qualify normal Metal FX.

## Source-derived palette coverage inventory


`AppModel.AppTab.primaryNavigationTabs` exposes the following 13 current
routes. The retained internal `autonomy` compatibility route resolves to
Projects and is not restored as primary navigation by the palette board.
This inventory identifies source owners. Current normal/minimum route cache
review is recorded above; it does not claim compositor or action execution.

| Current route | Existing source owner | Palette / verification |
|---|---|---|
| Dashboard | `Views/Rig/RigDashboardView.swift; ComputeCoresContentView` | Current 28548a73… normal/minimum native-cache route review passed; exact pixels/actions and layer limits are recorded above. All named current profiles passed; cache/compositor limits remain explicit. |
| LM Studio MCP | `Views/MCPServersView.swift` | Current 28548a73… normal/minimum native-cache route review passed; exact pixels/actions and layer limits are recorded above. All named current profiles passed; cache/compositor limits remain explicit. |
| Agents | `Views/AgentsView.swift` | Current 28548a73… normal/minimum native-cache route review passed; exact pixels/actions and layer limits are recorded above. All named current profiles passed; cache/compositor limits remain explicit. |
| Tools | `Views/ToolsView.swift` | Current 28548a73… normal/minimum native-cache route review passed; exact pixels/actions and layer limits are recorded above. All named current profiles passed; cache/compositor limits remain explicit. |
| Live Feed | `Views/LiveFeedView.swift` | Current 28548a73… normal/minimum native-cache route review passed; exact pixels/actions and layer limits are recorded above. All named current profiles passed; cache/compositor limits remain explicit. |
| Projects | `OperatorConsole/Views/ProjectsOperatorView.swift` | Current 28548a73… normal/minimum native-cache route review passed; exact pixels/actions and layer limits are recorded above. All named current profiles passed; cache/compositor limits remain explicit. |
| Rune Forge | `OperatorConsole/Views/RuneForgeOperatorView.swift` | Current 28548a73… normal/minimum native-cache route review passed; exact pixels/actions and layer limits are recorded above. All named current profiles passed; cache/compositor limits remain explicit. |
| Continuity | `OperatorConsole/Views/ContinuityOperatorView.swift` | Current 28548a73… normal/minimum native-cache route review passed; exact pixels/actions and layer limits are recorded above. All named current profiles passed; cache/compositor limits remain explicit. |
| Runtimes | `OperatorConsole/Views/RuntimesOperatorView.swift` | Current 28548a73… normal/minimum native-cache route review passed; exact pixels/actions and layer limits are recorded above. All named current profiles passed; cache/compositor limits remain explicit. |
| Provider | `OperatorConsole/Views/ProviderOperatorView.swift` | Current 28548a73… normal/minimum native-cache route review passed; exact pixels/actions and layer limits are recorded above. All named current profiles passed; cache/compositor limits remain explicit. |
| Events & Evidence | `OperatorConsole/Views/EvidenceOperatorView.swift` | Current 28548a73… normal/minimum native-cache route review passed; exact pixels/actions and layer limits are recorded above. All named current profiles passed; cache/compositor limits remain explicit. |
| Diagnostics | `Views/DiagnosticsView.swift` | Current 28548a73… normal/minimum native-cache route review passed; exact pixels/actions and layer limits are recorded above. All named current profiles passed; cache/compositor limits remain explicit. |
| Manager | `Views/ManagerSettingsView.swift` | Current 28548a73… normal/minimum native-cache route review passed; exact pixels/actions and layer limits are recorded above. All named current profiles passed; cache/compositor limits remain explicit. |

| App-owned supporting presentation | Existing source owner / boundary | Current-color acceptance |
|---|---|---|
| Main window/sidebar, native window treatment and menus | `ForgeConductorApp.swift`, `AppSidebarView.swift`, `GraphiteWorkbench.swift` | Current normal/minimum route and six optional-control/draft caches were reviewed; actual ordinary Navigation/Telemetry/Guide menus, About, restoration and native Quit were observed. Current profile/Cancel fixtures passed; cache/compositor limits remain explicit. |
| Native Settings / all nine Manager sections | `ManagerSettingsView`; same shared palette owner | Current nine-section/Settings-component normal/minimum native caches were reviewed. Actual ordinary SettingsScene at 900×560 content, all nine sections, draft/Reload, opt-ins/relaunch, restoration and native Quit have separate manual proof. Ordinary minimum and sheet compositor pixels/Close remain unclaimed limits. |
| Eight-step Guided Setup | `ContentView.swift / GuidedSetupWizardView` | Current eight-step top/lower normal/minimum native caches were reviewed. Ordinary Setup AXSheet and eight-step IDs were observed separately; unavailable ordinary sheet compositor/Close proof is not fabricated. |
| Contextual help, Advanced/related guides, inline help and unavailable guide | `GuidedHelpSheet`, `GuidedInlineHelp`, root/context sheet presenters | Current registration46, six full root Advanced bodies, rich secondary36 and remaining route Guide120 caches were reviewed. Three catalog contexts without a current visible opener remain retained/unclaimed; current conditional profiles passed; limits remain explicit. |
| Project registration sheet and existing project/package/cache confirmations | `ProjectsOperatorView` | Current registration/nested Help reviewed at both sizes; all 14 actual Cancel dismissals/no-mutation assertions passed. Actual ordinary folder/save/relaunch workflow passed separately. |
| Packet deletion, history reset and disposable-cache confirmations | `ContinuityOperatorView` | Current selected-packet/read-only details reviewed at both sizes; all 14 actual Cancel dismissals/no-mutation assertions passed. No real-home destructive mutation is claimed. |
| Provider Advanced, policy/source/violation details, runtime jobs, errors/loading/empty states | Existing operator route views and `OperatorConsoleComponents` | Current Provider Advanced middle/tail, inspection cards, Runtime limits, Rune evidence and selected packet were reviewed at both sizes. Current empty/error/retry/search/busy/linked-guard profiles and additional details passed with all selected pixels reviewed. |
| Native capability checkboxes and unknown/metadata captions | `ToolPermissionEditor`, shared operator components | Current controlled separate/combined capability fixtures and reviewed layers retain semantic controls. Six opt-ins/draft native and ordinary outcomes are separately recorded; the current named profiles passed. |
| Native open/save panels and standard menu internals | OS-controlled native surfaces; app appearance propagates through public APIs | Actual current healthy/failure Diagnostics exports and folder Select/Cancel/root rejection used real native panels; paired16/3records, saved folders/relaunch and native menus passed their scoped checks. Native OS pixels are not custom palette targets. |

The reviewed secondary binding delta uses existing text/success/tint roles in
`AutonomyOperatorView`, `ToolPermissionEditor`,
`OperatorConsoleComponents`, `GuidedHelpSheet` and
`GuidedInlineHelp`. Their conditions, text, icons and control actions remain
unchanged in that local delta. Current source/contract review and faithful native matrix qualify the authorized
Graphite baseline; ordinary/runtime and capture limitations remain explicit.

## Full acceptance matrix — 32 criteria

The rows below retain the preceding `28548a73…` qualification. The completed
frame, label and Dashboard guidance follow-up is qualified separately above;
no earlier result is relabeled as a pass for changed source.

All32criteria are fulfilled in their named current source/native/ordinary scope.
This table records faithful native equivalents and explicit unavailable proof
classes. Exact owner publication/readback/synchronization refs are retained externally; it does not erase completed QA or
authorize claiming installation/distribution.

| ID | Acceptance | Status | Evidence and remaining gate |
|---|---|---|---|
| CC-01 | New layout/FX are confined to Compute Cores and direct support. Outside it, only authorized palette values/bindings change; navigation, services, layout and behavior remain intact. | **Verified — scope/parity** | Incremental Compute preservation compares with the already-authorized Graphite UI checkpoint. The complete df0b66c9… phase includes requested Manager/Provider/Projects/text/control changes. Current source/contract and 21-method native view matrix preserve the authorized feature surface. |
| CC-02 | Approved detailed top-down package/die/contact/trace appearance is recognizable at normal size. | **Verified — covered native pixels** | Exact supplied 1448 x 1086 reference crops retain package/frame/grain/contact details, with telemetry-replaced activity. All 68 Compute layers and current normal/minimum Dashboard integration layers were reviewed; genuine 12/50/82 Metal hues/materials have no observed blocking defect in covered layers. |
| CC-03 | The removed lower metric-card grid is absent. | **Verified — source/native views** | The removed lower metric-card grid is absent from current chip content and current normal/minimum Dashboard native captures; existing lower Dashboard information remains. |
| CC-04 | CPU name is the actual GUI-host identity, including variant; never a baked M3/M4 label. | **Verified — host/fixtures** | Current Core 8/projection/whole-state fixtures preserve actual host/model/variant identity; long names wrap. Actual ordinary host Dashboard reports its ownCPU, not a baked artwork label. |
| CC-05 | GPU name and sampled activity refer to the same verified device or clearly show unavailable association. | **Verified — provenance fixtures** | Current Core 8/Compute 29 exact-registry association and multiple/unmatched-device tests passed. GPU name/activity share verified registry provenance or show unavailable; this is not arbitrary hardware certification. |
| CC-06 | Unknown/model-ID/long names render honestly and without truncating away meaningful variant information. | **Verified — native labels** | Current blank/model-ID/unknown/long-name cases and actual native labels preserve meaningful full identities. Normal/minimum view layers were reviewed without variant-erasing truncation. |
| CC-07 | A single busy logical CPU changes its stable local region, not unrelated CPU regions. | **Verified — genuine Metal pixels** | Deterministic locality and genuine production before/after readbacks change only the mapped busy logical CPU region; both frames were independently reviewed. |
| CC-08 | Equal valid CPU samples are not mistaken for fallback; fallback samples are not called per-core measurements. | **Verified — typed/native fixtures** | Equal-measured, fallback, warming and unknown contracts passed. Reviewednative quality labels distinguish host-average fallback from measured per-logical activity. |
| CC-09 | CPU topology is runtime-derived; P/E mapping is not inferred from array order or model strings. | **Verified — topology contracts** | Bounded runtime topology and oversized grouping retain every logical CPU without inferring P/E classification from array order or model names. |
| CC-10 | GPU regional illumination follows the valid aggregate envelope; individual lit blocks are not reported as measured core activity. | **Verified — genuine Metal pixels** | Zero/mid/high/missing GPU aggregate fixtures and hue/brightness readbacks passed. GPU 16 regions are illustrative aggregate response, never measuredGPU core activity; reviewed 12/50/82% frames retain this meaning. |
| CC-11 | Trace heads visibly travel through turns on fixed routes with fading tails. | **Verified — genuine native motion** | Turned-polyline/phase tests,20 genuine drawable sourceframes and currentMOV `5d1ceb4f75bf6a12b8791d7bc35b5eb64a085cd6a466940a81ae20220e3e4085` / receipt `ceb43fd96056f1fc2fa9777b658e0fae0858e5403cebfada927c5fa9efea7bed` passed exact PTS/RGB/orientation checks. Motion is illustrative trace travel, not measured signal traffic or a whole-window movie. |
| CC-12 | Idle, warming up, stale, paused and unavailable remain distinct. No missing source is shown as healthy zero. | **Verified — current transition scope** | Compute 29 includes active-to-invalid immediate stop, independent channel freshness, valid-idle bounded hold and mountedMetal-to-staticFallback status changes. Actual ordinary normalPause/Resume is separate integration proof; paused 0-clock receipt has no dedicated PNG. |
| CC-13 | CPU and GPU source timestamps are handled independently; old GPU data does not become fresh on every CPU frame. | **Verified — provenance/freshness** | Fresh Core 8 and Compute independent timestamp/stale-channel cases passed. Old GPU observations do not become fresh with each CPU sample. |
| CC-14 | No recurring animation submissions when scrolled offscreen, minimized, fully hidden/occluded or detached. | **Verified — native lifecycle** | Current 6 native lifecycle cases verify zero recurring submissions/clocks during scrolled-hidden, minimized, occluded, ordered-out and detached phases. Measurements are process-scoped, not universal renderer-exclusiveCPU claims. |
| CC-15 | Reentering/reopening resumes once from current state without duplicate timers, views or listeners. | **Verified — native ownership** | Native reopen/resume/release tests passed with one resumed clock, bounded buffers/surfaces and release at shutdown; corresponding layers were reviewed. |
| CC-16 | Reduce Motion disables moving pulses while keeping detailed chips and valid static activity shading. | **Verified — native static/motion scope** | Pause/Reduce Motion retain detailed staticactivity shading while native lifecycle checks verify 0 recurring clocks and 2 completed staticframes. Controlled capability layers were reviewed; no fabricated pausedPNG or per-host setting writes. |
| CC-17 | No pointer interception or per-frame accessibility announcements; existing semantic IDs remain. | **Verified — source/native actions** | Decorative Metal remains noninteractive with native semantic labels/control IDs. Sourceownership and current Guide/opt-in/14 Cancel/read-only flows preserve pointer/AX access; decorative per-frame work does not introduce per-frame announcements. |
| CC-18 | Small/large windows, 1×/2× where available, long text and topology changes do not clip/overlap. | **Verified — available sizes/scale** | Current normal 1440×900/minimum 1100×720 native fixtures, chip resize/long names/topology and 2×readbacks passed. Physical 1× and ordinary minimum were unavailable/unexercised and remain explicit limits; no simulated scale is claimed. |
| CC-19 | Rendering uses bounded geometry/pulses/buffers with no in-flight buffer overwrite or main-thread GPU wait. | **Verified — native bounded resources** | Geometry/routes/pulses/buffers are bounded, with oneinflight command and one replaceable pending readback. Current native reuse/resize/readback/release cases passed; no main-threadGPU wait or universal performance claim. |
| CC-20 | No production demo samples, hardcoded core counts or remote-provider hardware substitution. | **Verified — host/data boundary** | Host collectors/runtime topology and exactGPU association own production data. Typed samples remain isolated fixtures; no production demo values, hardcoded host counts or remote-provider hardware substitution. |
| CC-21 | Genuine Metal/pipeline/resource failure has a static native nonblank fallback with truthful status; no CPU animation substitute or false completion. | **Verified — native fallback/transition** | Actual injectedMetal failure yields detailed nonblankstatic native fallback; reviewed steel/contact/label layers and current mounted fallback transition passed. Status derives from current activity/pause, with no CPU particle substitute. |
| CC-22 | Shader/resources are compiled and packaged in the canonical native candidate; relevant builds/tests pass. | **Verified — canonical artifact/checks** | Current ordinary Debug My Mac and SwiftPMCLI/App builds passed; candidatepackages 19564 Bcompiled default.metallib with both functions and exact reference PNG. Source 434/graph/resource parity and strict signing passed. |
| CC-23 | Version/docs/membership follow current policy without reviving old packages or modifying the working installation. | **Verified — inputs and documentation policy** | Version 0.17.0 (27),15/434 audit,30 resources,unchanged signing/deployment and current docs align. Historicalpackages/failedreceipts retain their identities; owner refs/readback/synchronization are recorded externally, with no workinginstallation mutation. |
| FX-01 | Independent chip illumination, glow and trace travel execute through Metal + MetalKit in the normal candidate. | **Verified — native Metal/integration** | OneMetal canvas executes independent chip illumination and bounded traveling traces. Current genuinepixel/MOV/native commandreceipts and actual ordinary normalCompute/Pause/Resume complement eachother; no whole-windowMOV claim. |
| FX-02 | New shader source is compiled at build time and the produced library/functions load in the delivered app; no new runtime source compiler. | **Verified — compiled artifact** | Xcode/SwiftPM compile shader resource at build time. Matchingordinarydefault.metallib/exactfunctions and genuinecompleted native commands/readbacks passed; no production runtime source compiler added. |
| FX-03 | SwiftUI/AppKit remain the labels/control layer; no per-core Metal views or competing CPU/SwiftUI particle engine; clocks elsewhere unchanged. | **Verified — native owners/lifecycle** | SwiftUI/AppKit own labels/control; one canvas/shared resources andbounded clock ownFX. No per-coreMetal views or competing CPU/SwiftUI particle engine; current native 6/legacy 7 ownership/lifecycle scopes passed. |
| PAL-01 | Every current primary route and app-owned secondary presentation uses the shared Graphite Workbench palette. | **Verified — current reachable native matrix** | All 13 currentroutes,9 Managersections,8 Wizardsteps,registration,Guide Advanced/related/route contexts,errors/busy/empty/credential/14 Cancel/6 opt-in states passed selected 21 unique/22 nativeinvocations; all 463 selectedPNGs were reviewed. Retainedunrouted/no opener contexts remain unclaimed. |
| PAL-02 | Relative to the authorized Graphite UI checkpoint, outside Compute Cores layouts, sizes, typography sizes, controls, data, navigation and workflows remain unchanged. | **Verified — authorized comparison baseline** | Source/contract review andcurrent matrix preserve the authorizedGraphite UI baseline across incrementalCompute changes. Wholephase intentionally includes owner-requestedlayout/text/Settings-firstcontrol changes beyondoriginaldf0 main. |
| PAL-03 | Blue selection, mint action, cool readable text, graphite fields/panels and steel boundaries match the approved color reference. | **Verified — native reviewed palette** | Current sharedroles use blue selection,mint action,cool text/graphite panels/fields andsteel borders. Numerical 11 Graphitecases plus current normal/minimum route/secondary/state layers and ordinary normalSettings/Dashboard were reviewed. |
| PAL-04 | Warning, destructive, denial/error, busy, disabled and unavailable states retain meaning and readable contrast. | **Verified — named interaction states** | Current error/retry/search, busy preparation, linked unsaved credential guard,disabled/destructive/unknown/unavailable and 14 Cancelpresentations were reviewed; status meaning andreadability remain. |
| PAL-05 | Native app/scene appearance is consistent across windows and sheets; Increase Contrast/Reduce Transparency work without system-setting writes. | **Verified — native/ordinary scope** | Dark Aqua/shared palette applies to main/Settings/sheets. Current separate/combined controlled capability fixtures and current normal/minimum view matrix passed; actual ordinaryall 9 Settings/Pause/menus wereobserved. Ordinaryminimum/1×/Skycompositor are explicitlimits, notextra gates. |
| PAL-06 | Palette is implemented through the current shared owner or a minimal native owner if none exists; no duplicate theme framework or new picker. | **Verified — existing shared owner** | GraphitePalette andexistingnativecomponents own application colors; no duplicate framework ornew theme picker. Currentrole/source consumer review andviewpixels passed. |

## Native capture matrix

All18package ID/name pairs are fulfilled in the named available-native scopes
below. Exact files/state/size/scale, semantic assertions and motion evidence
are retained in current receipts. Separate caches/readbacks are not compositor
screenshots; unavailable ordinary minimum/physical1× remain explicit limits.
Older matrices remain historical.

| ID | Capture | Status |
|---|---|---|
| CAP-01 | normal | Verified named scope — current normal native layers/separateMetal plus actual ordinary 1440×900@2×Dashboard; caches/readbacks are not composed screenshots. |
| CAP-02 | idle | Verified native fixture — current idle labels/material/lifecycle layers; no ordinary measured workload claim. |
| CAP-03 | cpu-single-region | Verified genuine drawable — locality before/afterproduction Metal comparison and bothreviewedframes. |
| CAP-04 | gpu-aggregate | Verified genuine drawable — zero/mid/highaggregatehue/brightness fixtures and reviewed 12/50/82% frames;16 illustrative regions. |
| CAP-05 | missing-gpu | Verified fixture/layers — unavailableGPU/unknownassociation remains distinct fromzero; independentnative labels reviewed. |
| CAP-06 | cpu-fallback | Verified fixture/layers — CPU fallback quality remains explicit alongside equal-measured/warming/unknown states. |
| CAP-07 | reduced-motion | Verified native static scope — Reduce Motion/pausezero recurringclocks and 2 static completed frames; no dedicatedpausedPNG claimed. |
| CAP-08 | narrow-window | Verified available native sizes — currentmainnormal/minimum andchip resize/material fixtures; physical 1×/ordinary minimum unclaimed. |
| CAP-09 | long-names | Verified native cache labels — full long/raw/blank hardware identities and bounded topology; Metal pairedseparately. |
| CAP-10 | scroll-hidden | Verified native phase receipts — hidden 0 submissions/0 clocks anddetachedrelease; notcontinuouswhole-windowvideo. |
| CAP-11 | restore | Verified native lifecycle — restore/reopen resumesonce withboundedresources; currentreviewedmateriallayers. |
| CAP-12 | movie | Verified genuine 20 frameMOV `5d1ceb4f75bf6a12b8791d7bc35b5eb64a085cd6a466940a81ae20220e3e4085` / receipt `ceb43fd96056f1fc2fa9777b658e0fae0858e5403cebfada927c5fa9efea7bed` — exact PTS/RGB/orientation; typed fixture drawable, notwhole-window/measured workloadmovie. |
| CAP-13 | metal-execution | Verified compiled/native execution — matchingordinarylibrary/functions/exactPNG,completedcommands/readbacks andordinary normalCompute/Pause/Resume. |
| CAP-14 | palette-all-current-routes | Verified current 13-route normal/minimum nativefixture caches;selectedmatrix 463 reviewunion keepsMetal/compositor layers explicit. |
| CAP-15 | palette-secondary-presentations | Verified reachablecurrentsecondary — registration,nestedGuide,all 8 Wizardsteps,9 Managersections,root/secondary/route Guides/full Advancedtails andread-only details atboth sizes;retained 3 no openers/unroutedRun Details unclaimed. |
| CAP-16 | palette-interaction-states | Verified current named states — error/retry/search,busy,linked unsaved guard,populated/empty/unavailable,6 opt-ins and 14 Cancel/no mutation;failedframing attempts retained. |
| CAP-17 | palette-accessibility | Verified controlled separate/combined accesscapabilities plusnative AX/actionparity/semantic labels;physical 1×/unsupportedcompositorunclaimed. |
| CAP-18 | palette-native-appearance | Verified nativeappearance scope — current normal/minimum fixtures plus actual ordinarySettings 9 sections/draft/Reload/opt-ins/persistence/restoration/Quit,About/menus andnormal Dashboard/Pause/Resume. |

## Owner delivery — tested inputs and external refs

The UI implementation, all 62combined acceptance mappings and18 capture scopes,
current production/native checks,463view-image review,68 Compute layers,
20-frame MOV and four matching signed ordinary workflows are complete in their
recorded scopes. README, Unreleased changelog, roadmap and current docs/wiki
align0.17.0 (27). The owner publishes these tested product inputs and final
documents, then records exact remote refs/readback/safe local synchronization,
zero divergence and clean intended trees externally under
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-04-graphite-workbench`.

All owned ordinary cases ended; all seven registration byte sets per case
were unchanged and all twelve private defaults suite key sets were empty.
No installation, deployment, notarization, App Store Connect upload or
distribution was performed. Historical broader provider/privileged-service/
shipping requirements retain their own qualification boundaries.

# Changelog

User-visible Forge Conductor changes are recorded here. Detailed test, signing,
artifact, and qualification receipts belong in the
[roadmap](ROADMAP.md), [qualification status](docs/QUALIFICATION-STATUS.md), and
[functional-build record](docs/FUNCTIONAL-DEVELOPMENT-BUILD.md).

The version format is documented in [versioning policy](docs/VERSIONING.md).
Product versions do not by themselves claim shipment.

## [Unreleased]

### `0.44.4 (64)`

Run doctor uses one background health check, disables duplicate actions while it runs and discards cancelled results. The existing report text and synchronous Core/CLI/HTTP contract remain. Focused verification is recorded in the qualification status.

Four Doctor ownership/lifecycle cases and the real native button/report check pass. The preserved Doctor layout regression, 19-case area cohort/G3, CLI/app builds, ordinary Debug build and strict signature also pass. Earlier failures remain recorded; desktop/full UI and installed/shipment gates stay open, and other implementations remain deferred. [Qualification](docs/QUALIFICATION-STATUS.md).

### `0.44.3 (63)`

- Clear previous repository success feedback before validating a new Save or Clear. Invalid input or a changed project now shows only the current error, preserving the saved link and refusing an extra write. The same failing unit/native regression now passes; all 22 Projects view-model tests and the existing native draft case pass. Other implementations remain deferred. [Qualification](docs/QUALIFICATION-STATUS.md).

- Record V199’s failed Rune Zoom diagnostic before/during/after production Rename cancellation. The pre-sheet two-node traversal succeeds; third-node AXIdentifier/fresh Role −25211 persists during and after owned Escape with trust=false throughout. Saved layouts and bytes are unchanged, Save is not requested, and the different terminal error plus one QoS warning establish no cause or repair. Naming and desktop/full UI gates remain open. [Qualification](docs/QUALIFICATION-STATUS.md).

- Verify real isolated Projects repository Save/rejection/reopen/Clear through two app/backend epochs and a fresh custom view (V200), preserving identity and layout and leaving rejected durable files unchanged. The real-backend method and unchanged default-fixture queued move/resize method (V201) each pass with no failures/skips/runtime warnings. Resize is API-prepared; ordinary process/desktop/installed gates remain open. No production or version change follows. [Qualification](docs/QUALIFICATION-STATUS.md).

- Verify initialized ContentView Projects→Diagnostics→Projects navigation with real isolated Manager state and the prepared custom layout (V203), plus the unchanged move/resize case (V204), each PASS without failures/skips/runtime warnings. Preserve V202 as a failed/stopped UUID-snapshot attempt; fresh observations establish test snapshot timing, without a product repair. Production/version/graph are unchanged; ordinary window-controller/desktop/full13/gesture/installed gates remain open and other implementations remain deferred. [Qualification](docs/QUALIFICATION-STATUS.md).

### `0.44.2 (62)`

- Route discrete horizontal wheels over vertical custom-panel bodies to their canvas. Preserve vertical wheels, nested horizontal content, saved layouts and window ownership; remove the local monitor on detach/dismantle/deinit. Gesture and momentum events retain AppKit dispatch. The final 0.44.2 native selection passes four scrolling/lifecycle cases; CLI/app, ordinary Debug and strict signature checks pass. Broader UI and gesture gates remain open. [Qualification](docs/QUALIFICATION-STATUS.md).
- Verify two current-source Manager/Projects edited-draft flows using owned native input and literal editors. Preserve the unexplained QoS warning and open whole-window/full UI gates. Synthetic gesture comparisons remain NONPASS, including their direct AppKit control; no production gesture correction follows. [Qualification](docs/QUALIFICATION-STATUS.md).
- Verify Projects repository-draft retention through queued panel move/resize and persisted geometry restoration (V193). Record V194's desktop-control connection failure and V195's UI-runner initialization timeout separately; zero sidebar checks executed. Product/version and deferred scope are unchanged. [Qualification](docs/QUALIFICATION-STATUS.md).

### `0.44.1 (61)`

- Prefix saved layout menu entries with `Layout: ` to distinguish them from built-in commands while preserving names, IDs and schema. The reproduced collision regression passes; two fresh Rune failures and full UI qualification remain open.
- Verify the unchanged all-panel queued move/resize case in foreground Xcode v162: all 126 placements across 21 mounted namespaces, 756 events, one PASS/zero failures/skips, with storage/fresh-restoration and owner guards retained. Foreground v163 still fails both unchanged fresh Rune tests before Save at AXIdentifier −25211. Prior failures, API-prepared fixture limits and full UI/desktop/installed/lifetime gates remain; no production or version/build change.
- Verify all remaining Rune detail panels through an additive native test in v165: 14 placements/three namespaces/84 queued events, one PASS/zero failures/skips, with existing public routes and unchanged gesture/storage/owner guards. Together with the separate v162 pass, all 140 catalog placements in 24 namespaces have queued move/resize and persistence coverage (840 events). Fixtures prepare layouts and scrolling through APIs; v163 fresh naming failures and full UI/desktop/installed/lifetime gates remain open. Production/version/build are unchanged; other implementations remain deferred.
- Add bounded failure-only parent membership observations to fresh Rune naming tests and a separate plain AppKit sheet/Zoom control. V167 retains both pre-Save AXIdentifier −25211 failures despite exact own-PID/CFEqual recopy membership; v168 passes six control phases across both window styles. V169’s opt-in active/exact-sheet-key preparation still fails before Save. All 33 prior test bodies remain unchanged. These are test diagnostics, with no production repair, causal conclusion or full UI acceptance; earlier all-140 placement evidence and implementation deferrals remain.
- Record an isolated 0.44.1 (61) candidate Dashboard observation in v171. Projects navigation remains unknown after the computer-use pipe failure; exact-owned SIGTERM ends the process at −15 without ordinary GUI quit. This retains prior native placement passes and adds no general desktop/full UI acceptance or implementation scope.
- Verify native shared controls across all 13 main views in v173: 145 actual menu actions, 184 complete persistence checks, one PASS/zero failures/skips; the preserved Tools route also passes. Existing tests, production and graph remain unchanged. Desktop/full UI gates and deferred capability scope remain open.
- Verify native Rename and Save As on all 13 main views in v175: 26 actual naming/Save flows and 39 full persistence checks pass, preserving identities, copy geometry and independent view layouts. Correct and rerun the initial v174 fixture UUID-marker premise; prior tests and product/version/graph remain unchanged. Desktop/full UI remains open; other implementations stay deferred.

### `0.44.0 (60)` custom layouts within each view

- Verify existing Tools Default menu selection and saved-layout reselection in v153/v154. Add the broader 126-placement/21-namespace queued-geometry check without changing prior tests; its pre-input presentation failures remain unresolved. V152 selected zero tests and is NONPASS. No production repair or complete UI acceptance is claimed.

- Correct the Rune native-menu test driver to use and record public `NSMenu.cancelTrackingWithoutAnimation()`, retaining every assertion, owner/item/storage guard and existing deadline. V148 passes repeated Rename/Save As; v149 passes it plus both fresh naming regressions. V145/v147 original-dismissal failures remain historical. No production repair or wider UI qualification is claimed.

- Fix Customize Layout name generation to use the validator’s Unicode case folding with en_US_POSIX. A saved `Cuſtom` now produces `Custom 2`, retaining all prior layouts and fresh stored restoration; the native regression passed twice, with 18 preferences and two normal Rune naming cases also passing in each invocation. Wheel host aborts keep both aggregate runs NONPASS. Fresh v123 ordinary Debug/strict signature pass (25.642/0.282 s), Info 0.44.0 (60); unchanged graph/verified source membership, candidate-only.

- Add native Hide/focus verification: the real close button releases the focused move handle, and API re-show restores the same handle for persistent arrow movement. V125/v128 isolated checks and V129's 11 selected layout methods pass with storage/owners/local state preserved. V127's four pre-input window/owner failures remain unexplained; the added observations change no guards or waits and establish no repeatability repair. No production focus repair was needed; scrolling reset and full UI qualification remain open.

- Record v130/v131 wheel diagnostics as NONPASS: reset-wait/layout/dismantle observations establish no allocator-abort cause, and removing the test-forced layout call still aborts. Original test source is restored; scrolling and full UI remain open.

- Correct three test receipt fields to serialize mutation sets as sorted JSON arrays, preserving field names and all input/assertion guards. Standalone v135 and the original native wheel/reset case v136 pass; formal-scroller/advertisement siblings remain NONPASS in v137. No production repair or full UI claim.

- Add separate owned Projects AXValue verification and correct advertisement receipt accounting to avoid repeated full JSON serialization without changing byte/time limits. V143 passes value input, read-only advertisements and unchanged queued wheel together; storage, Reset and cleanup are retained. Original parent-increment failure and full UI/desktop/installed gates remain; production is unchanged.

- Add native movable/resizable panel frames, show/hide controls, saved named layouts, rename/delete and Restore Default to all 13 main views. Manager sections and Rune Forge detail modes retain independent layouts within their existing views. [Workspace guide](docs/NATIVE-WORKSPACES.md).
- Keep page-owned settings and project drafts outside rearranged panels. Cancel a drag with Escape. Pause Provider setup observation when all its panels are hidden and resume the durable operation without reloading unsaved LM Studio settings.
- Keep accepted Rune Forge policy commands running when all panels are hidden; pause background observation separately. The mounted regression and all 16 owning native Rune cases passed.
- Fix Compute viewport resume after outer scrolling and moving a shown panel. Use bounded shared ancestor frame and clip bounds observations and restore their original notification flags on final detach; both focused native cases passed. All 27 Compute owning native methods also passed. Complete UI qualification remains open.
- Fix stale naming submission: a held Rename dialog must not rename a newly selected layout. Capture its originating view/layout and request identity; dismiss changed-context submission without changing saved layouts.
- Pass the scoped v17 23-method native selection on its recorded inputs: 18 preference cases, separate normal Rename/Save As, same-view selection/source-refresh isolation and native move/resize/Hide restoration through fresh owners. Post-naming ordinary Debug, strict signature and candidate input/artifact readback passed. Full UI/drafts/desktop and original combined naming/exported-AX/Save-button checks remain open; new capabilities remain deferred. Exact source/wiki delivery outcomes are retained in external receipts.

- Verify a separate queued native pointer case: exact owned-window hit testing routes move/resize events through the app queue, preserves transient stored state and persists completed geometry with the same hosts. Cleanup cancels an unfinished test gesture. V18 draft/Save and v21 Save checks remain NONPASS; full UI and desktop/compositor qualification stay open.

- Verify a separate v22 Rune cancellation case: actual Rename/editor input, selected-source removal and app-queued Escape dismiss the originating sheet, preserve all saved layouts and stored bytes, and retain overview panels. This adds scoped test evidence; original draft/Save and complete UI gates remain open.

- Verify the unchanged native Doctor v23 case: actual section/Run doctor actions retain the unavailable result and heading across default/custom/restored layouts. Healthy/live Doctor reports and full UI remain unqualified; prior failures retain their recorded inputs.

- Record v25/v26 complete-draft diagnostics: both native methods remain NONPASS in each selection. Test-only boundary retention rethrows the original accessibility error and shows a different raw terminal associated-error domain naming Gestures `InvalidTransition`; causal ordering remains unknown. Original actions/assertions and all broader qualification gates remain unchanged.

- Record the separate v27 post-failure diagnostic: after one requested 20 ms wait and one fresh child copy from the held parent, both held/fresh child accessibility reads still return −25211. Both complete-draft methods remain NONPASS; original assertions and fatal errors are preserved, with no cause or production repair established.

- Record the separate v28 trust-state observation: both complete-draft methods remain NONPASS, with false reported by the test client at each diagnostic start. Root/parent role reads still succeed while held/fresh child reads remain −25211. This context observation establishes no particular-child cause or production repair; all original assertions and open UI gates remain.

- Record the separate synthetic export comparison: v29 failed compilation with no method executed, v30 failed its added direct NSButton-role assumption, and v31 passed one actual bounded AppKit/SwiftUI comparison after fixture-only corrections. Both fixtures exported one exact identified AXButton with client trust false. Original Manager/Projects actions and all 23 assertions remain unchanged/NONPASS on v28; no permission cause, product repair, control action or full UI qualification follows.

- Add separate native draft checks and bounded exported ancestry diagnostics. V32–v35 remain NONPASS; the removed v33 metadata experiment and v36/v37 scope-guard failures are retained. V38 passed both explicit application-content cases after the new guard was corrected from observed standard-control metadata, preserving all copied draft assertions/actions. Layout transitions use the preferences API; a fresh v39 original whole-window rerun failed both methods, and ordinary-native gates stay unchanged/NONPASS. No backend Save success, production repair or full UI pass follows. [Qualification](docs/QUALIFICATION-STATUS.md).

- Record separate Rune native-menu/exported-Save results: v41 Rename and isolated v42 Save As pass exact identity/copy, collection and restored-preference guards; combined v40 and mixed v41 remain NONPASS. The three existing Return/Escape regressions pass in v43. These test-only checks preserve original ordinary-native Save failures and establish no product repair, failure cause, repeated-menu or full UI qualification. [Qualification](docs/QUALIFICATION-STATUS.md).

- Fix Hide during unfinished move/resize: cancel the hidden host’s gesture and check current visibility before the existing layout-identity frame callback. Both unchanged methods pass in v50 after failing in v49; v51 passes 15 related methods including those two. App compilation, ordinary Debug, strict signature and candidate identity readback pass; final source/document checks pass. Exact source/wiki delivery is tracked separately in external receipts; full UI remains open.

- Fix mixed pointer/keyboard edits: withhold pending-arrow saves, preserve arrow displacement in subsequent pointer events and retain the original Escape rollback frame. Seven unchanged cases pass after the v57/v58/v60 failures; all 22 related native methods pass, including those seven. Option resize/max-bound continuation and complete collection/byte guards are exercised. App/Debug/signature/v8 readback pass; final checks and delivery remain separate, with full UI open. Qwen review is advisory. [Qualification](docs/QUALIFICATION-STATUS.md).

- Add bounded Rune cached-path, native menu-state and failure-only standard-control reference diagnostics without relaxing original errors. V44–v46 remain mixed/combined NONPASS; v46 maps the held first-edge ancestor to the exact window Zoom reference. V47 again captures no second menu root. Unreadable-child and menu-failure causes remain unknown. [Qualification](docs/QUALIFICATION-STATUS.md).

- Record the bounded test-only Rune tracking diagnostic: v67 fails and v68 passes Fresh Rename while Fresh Save As and combined naming fail before Save activation. All four menus lack an exact didEnd receipt before capture stop, including the pass; this is no failure discriminator, unwind/release proof or cause. Original gates remain open. [Qualification](docs/QUALIFICATION-STATUS.md).

- Add bounded test-only required-call trust/mode and same-held-child Role diagnostics without changing original fatal checks. V71/v72 and combined v74 fail before Save; isolated Save As v73 passes. Trust=false/event-tracking boundaries occur in both outcomes, and the failed child’s role remains unknown after its Role read also fails. No cause or naming repair follows; original gates stay open. [Qualification](docs/QUALIFICATION-STATUS.md).

- Record the separate Tools shared-controls v77 NONPASS: native Customize identifier lookup fails before button/menu actions after exact default-state readback. Cause remains unknown; no product repair or UI gate closure. [Qualification](docs/QUALIFICATION-STATUS.md).

- Record Tools discovery v79–v81 NONPASS before Customize actions and the separate attached-sheet Rune v82 NONPASS. V82 completes the scoped Rename subflow with actual Save AXPress status 0 and restored saved state, then fails the second whole-window opener before Save As. Later bridge observations and fixture styling establish no product cause or repair; original gates stay open. [Qualification](docs/QUALIFICATION-STATUS.md).
- Record partial Tools control reachability through the separate exported route: v87 completes Customize Layout and first Panels Hide with exact saved-state/identity readback, then fails before Show. V84/v85 and unchanged pre-admission v86 remain NONPASS; the separate exported route and its menu-role/action correction are test-only. Fresh original ordinary v88 still fails before Customize; remaining control actions and full UI gates stay open. [Qualification](docs/QUALIFICATION-STATUS.md).

- Qualify the controlled exported Tools fixture in v91 and unchanged v92, two executions of one method: complete Customize/Hide/show/recovery/Restore Default/saved selection/Delete with eight exact menu-end receipts and eleven saved-state/restoration stages per run. The exported test driver waits for each exact captured menu end within the existing deadline; production and ordinary routes are unchanged. V90’s failed baseline, original ordinary v88 and broader UI/naming gates remain open; no unwind or product-cause claim. [Qualification](docs/QUALIFICATION-STATUS.md).

- Record synthetic comparison v94 PASS and Projects repository-panel queued move/resize v98 PASS, including draft retention, fresh preferences and Feed isolation without backend writes. Rune v95/v96 remain NONPASS despite completed Rename subflows; v97 reverses the unsuccessful exact-end experiment while retaining evidence. These are scoped tests, with no production repair or original UI-gate closure. [Qualification](docs/QUALIFICATION-STATUS.md).

- Verify queued move/resize across 21 representative real namespaces in v101, one method/126 events with saved-state and host guards. Retain v100’s compile failure and local test-only correction; menu, original naming/ordinary and broader UI gates stay open.

- Verify scoped combined Rune Rename/Save As in v103 through exact attached-sheet Save AXPress and fresh saved-state restoration. V104 retains both unchanged owned-editor/Return regressions. Original whole-window/ordinary combined and broader UI gates remain open; no production repair.

- Verify shared queued geometry for 21 real page/Manager namespaces in v106 and actual Source/Violation/Feed selection plus three Rune detail-panel gestures in v108. Across separate inputs this covers 24 representative namespaces, with exact saved-state/restoration and host guards; every panel, original naming/ordinary and broader UI gates remain open. No production repair.
- Add a separate validated application-content semantic check: v110 passes all 104 page/size/layout pairs, with all 104 native caches visually reviewed; the unchanged whole-window v111 gate fails during AXRole discovery. Cropping, transient differences, content beyond the captured viewport and scrolling actions remain limits. Test-only; no production, version or full UI closure.

- Record v113’s separate outcomes: original whole-window and formal horizontal scroller FAIL, scoped 104-phase PASS; retain cached copied-lineage equality without identity/cause inference and complete visual coverage with 90 exact prior reuses/14 original inspections. Current ordinary v8 candidate input/artifact/signature readback passes; older v6 current-source mismatch remains preserved. Test-only; scrolling and broader UI gates stay open, with capabilities deferred.

- Record v114’s four-method result: three FAIL/one scoped 104-phase PASS. Typed Zoom/FullScreen equality identifies only a copied ancestor; formal horizontal increment returns false, and the read-only advertisement probe fails its existing receipt-byte bound with zero actions. Preserve v113 and all original errors/bounds; no production repair or broader UI closure. The compact v115 native rerun still fails the unchanged half-second observation deadline with zero actions.
- Retain v117–v122 wheel probes as NONPASS: conversion prerequisites fail before posting, or the host aborts after a retained cache without a final wheel receipt/cleanup proof. Restore the exact v119 test after the unsuccessful v122 isolation experiment; no scrolling defect, cause or repair is claimed.

#### Earlier UI checks before the naming repair

- Verify the post-Compute ordinary Debug candidate, strict signature and CLI/app product links. Candidate Dashboard startup was observed. The later whole native Canvas selection passed 11 of 13 methods; both draft cases, Projects desktop navigation and Rune naming qualification remain open. The installed 0.18.0 (28) app was not replaced.
- Full-view/draft-retention and final native build/delivery checks are in progress. Remaining new capability implementations are deferred at the owner's request. [Qualification](docs/QUALIFICATION-STATUS.md).

- Record the later two-draft failures, forced Rune naming timeout and separate candidate-owner cleanup without a complete UI claim. Source/native version-document checks each passed one method and hygiene passed; final documentation readback and exact source/wiki delivery remain open.

- Exercise actual native Rename menu dispatch and sheet presentation. Native Save discovery remains NONPASS before the namespace-change flow; the observations do not establish a product naming defect or close UI qualification.

- Record the separate native Return check as NONPASS at owned name-field discovery before any submission or namespace change. Naming qualification remains open.

### `0.43.0 (59)` AAC-LC M4A format extension

- Extend supplied-PCM audio_write with exact m4a and a matching .m4a path; retain WAV default, explicit WAV/FLAC, existing response keys, own grant/context/replay, pinned publication and writer versus managed JSON bounds. Native AudioToolbox AAC-LC runs in a bounded signed owned worker; decoded samples are lossy, encoded bytes may vary, and supplied valid-frame count is retained. [Contract](docs/NATIVE-AUDIO-WRITING.md).
- Matching source/native owning selections passed 139 methods each on the same 475 inputs, zero failures/skips, with warnings retained. CLI/app compilation and ordinary Debug/strict signature passed. Candidate C1 readback passed with seven artifacts/Info, 475 inputs and 80 preceding guards exact; six App/CLI cohorts passed 24 real M4A outputs/whole readback, observed-child cancellation with destination preservation and separate native valid-frame/true EOF checks for all 24 files. Qwen v3 six-Low/five-result whole-readback/metadata ACK and exact-artifact native decoding passed; the earlier test-only artifact-cap NONPASS is retained. Failed/unresolved native-owner paths and general shutdown remain unqualified. Initial G3/hygiene and first owner source publication/synchronization passed; scoped AAC result-document/wiki checks and source/wiki delivery are complete; prior standalone and .42 results do not qualify AAC integration. Raw ADTS .aac and broader installed/Release/shipment gates remain unqualified. [Qualification](docs/QUALIFICATION-STATUS.md).

### `0.42.0 (58)` complete rendered-snapshot paging

- Add opt-in `paged: true` to existing web.render with immutable snapshot ID/whole SHA, scalar-safe byte cursor and explicit EOF. Retain one ≤1 MiB/65,536-node body for at most 120 seconds with one expiry owner; overflow/stale continuation fail explicitly. Default v1 prefix, existing authorization and final actual-ID/notice/LF budgets remain. [Contract](docs/NATIVE-WEB-RENDERING.md).
- Matching .42/58 source/native 150, separate initial G3 one each, ordinary Debug/signature and signed App/CLI functional/limits checks passed. Limits v2 returned 241 pages/246 responses per route; the original App limits v1 continuity-200 NONPASS remains retained. [Qualification](docs/QUALIFICATION-STATUS.md).
- Qwen v6 passed six completed responses, five later-consumed native results/both empty EOFs, whole 6,144/35,371-byte reconstruction, exact four-scalar ACK and all six strict actual Low LF associations. Earlier v2–v5 NONPASS attempts remain retained; v5 outer closure and prior pipe-loss cause remain unknown. Applied-v2 final source/native G3, hygiene/local links and unchanged final candidate v3 readback passed; first owner source/wiki publication, exact readback and clean synchronization passed; no full-web/all-model/installed/Release/shipment claim.

### `0.41.0 (57)` FLAC format extension

- Extend existing audio_write with exact optional wav/flac and matching .wav/.flac paths; omission remains WAV. Preserve supplied signed PCM16LE/rates/channels, 1 MiB raw and bounded canonical base64, own grant/context/replay, pinned publication and separate 65,536-byte managed JSON admission. FLAC is lossless verbatim with native-swift-flac / flac-pcm16le-verbatim-v1 metadata; no conversion, playback or source-file import is added. [Contract](docs/NATIVE-AUDIO-WRITING.md).
- Pre-version source checks passed 59 distinct methods, including all 11 new methods and complete WAV/85-neighbor preservation; focused 8 adds no coverage. Matching .41/57 canonical native 59 and ordinary build/signature gates passed; App/CLI each passed 40 responses/38 frames with refusals, immediate cancel and complete WAV parity; Qwen completed three Low responses, consumed two actual results and acknowledged four exact scalars. Selected-identity source 59 and all three App/CLI/Qwen native whole PCM consumers also passed. Separate source/native G3 checks passed one actual method each, giving 60 distinct methods per route with the prior 59-method selections; these are separate invocations. Initial hygiene/whitespace passed; first owner source/wiki publication, exact readback and clean synchronization passed. Final C2 reread unchanged C1 binaries and source/protected inputs without a rebuild. Standalone bitstream/native whole PCM and 42 test-hook controls retain separate provenance. [Qualification](docs/QUALIFICATION-STATUS.md).

### `0.40.0 (56)` supplied-entry TAR/GZIP writing

- Extend archive_write with exact optional zip/default, tar and tar.gz and matching explicit paths. Preserve virtual NFC names/order/bytes, canonical base64, 32 members, 1 MiB raw/2 MiB output, own grant/context/pinned writer and separate 65,536-byte managed JSON bound. Standalone GZIP/source-file members/extraction are not added. [Contract](docs/NATIVE-ARCHIVE-WRITING.md).
- Matching source/native 25 distinct methods, .40/56 ordinary Debug/signature and separate six-recipe mechanism, independent 55-control/twelve-artifact and thirty BSD stdout checks passed; original compiler/generator NONPASSs remain. App/CLI full-byte wire and Qwen TAR/tar.gz consumption/ACK passed on unchanged inputs. All fifteen product BSD listing/payload/gzip commands passed; raw NFD listings and unknown cause remain recorded. Separate G3 source/native checks passed once each, giving 26 distinct methods per route with the prior 25; hygiene/whitespace passed. The initial zero-selection native attempt remains NONPASS. Final C2 passed as a reread of unchanged C1 binaries with only two G3 assertions changed in the source map; initial owner source/wiki publication, readback and clean synchronization passed; exact revisions are retained in the external delivery receipt. No installed/full-lifetime/general-interoperability/shipment claim.

### `0.39.0 (55)` supplied PCM16 WAV writing

- Add `audio_write(path, content, sample_rate, channels)` with shared deadline_ms: explicit case-insensitive .wav, canonical padded-base64 signed PCM16LE, rates 8000/44100/48000, mono/stereo, nonempty complete frames and 1 MiB raw maximum. Output is one 44-byte PCM RIFF header plus unchanged supplied bytes. [Contract](docs/NATIVE-AUDIO-WRITING.md).
- Use the own grant, project context, ordinary defaults, idempotent broker classification and existing pinned writer. Managed canonical JSON remains bounded to 65,536 bytes; existing archive/image/document tools remain available.
- Retain the original absent-definition NONPASS. Source 48 owning plus 24 separate preservation methods match 72 passed canonical native methods; CLI/app/ordinary Debug/strict signature passed. App/CLI each passed 33 responses/31 frames/three exact WAVs, 11 refusals and immediate cancellation with target preservation; Qwen completed three observed Low turns/two consumed actual results with strict six-field ACK. Seven small product WAVs passed both public native URL consumers with exact PCM/EOF and successful handle closure; initial G3 and final prose hygiene/whitespace passed; the original .39 source/wiki delivery completed. [Qualification](docs/QUALIFICATION-STATUS.md); no codec/playback/install/shipment claim.
- Separate prior .38/54 typed Projects candidate flow passed canonical Save/reopen, invalid-host preservation and Clear across six phases/five durable checkpoints/two ordinary exit-0 lifetimes in 11.452 s. Earlier driver NONPASSs remain; pixels/browser/Tools/installed GUI/full-web/all-model scopes stay unqualified.

- Verify one actual Qwen LM Studio GUI public-page workflow through the separate .39/55 candidate: search, fetch and two bounded JavaScript snapshots, six correlated calls and three completed assistant turns. Restore the original global MCP configuration and chat afterward. [Scope and limits](docs/PROJECT-WEB-QWEN.md#qwen-in-lm-studio-gui-public-page-workflow); this does not enable the installed product or qualify all models.

### `0.38.0 (54)` supplied-entry stored ZIP writing

- Add `archive_write` with explicit .zip path and 0–32 virtual name/base64 entries. Preserve exact NFC names, supplied order/bytes, stored method 0, CRC32 and fixed timestamps; reject unsafe/conflicting names/noncanonical base64 before saving.
- Add own grant/context, ordinary defaults, idempotent replay, Docs guidance and document telemetry. Preserve custom denials, imported explicit capabilities and pinned publication.
- Matching 62 owning source/native methods plus one separate initial G3 give 63 distinct methods per route. Ordinary candidate build/signature and Swift CLI/app compilation passed. App/CLI each passed 25 responses/23 frames/four ZIPs, six refusals and one immediate cancellation; Qwen completed three observed Low turns and consumed two actual results with strict metadata ACK. Four actual App ZIPs passed BSDtar canonical-name lookup/36 exact payload files. Original failures and GUI/full-web/all-model/install/shipment limits remain; exact document/delivery outcomes are external. [Archive contract](docs/NATIVE-ARCHIVE-WRITING.md).

- Later isolated Projects v3 registration passed with matching ID/root and generation 1, but the whole flow remains NONPASS at the Save-stage 8,192 AX call cap after one field set/Save press. Its 303-byte metadata stayed unchanged with no repository URL; ordinary exit 0/no force does not qualify Save/reopen/reject/clear/Tools. Cause unknown; prior failures and the sheet diagnostic PASS remain retained.


### `0.37.0 (53)` additive standard-size ICO pixel writing

- `image_write` accepts exact lowercase `ico` with an explicit case-insensitive `.ico` path. Square 16/32/48/256 produces one bounded 32-bit bottom-up BI_RGB DIB/AND image, preserving encoded alpha 0…255 and hidden RGB; native premultiplied rendering is separate. Engine is `swift-ico-dib32`, output contract `ico-dib32-rgba8-srgb-v1`; no embedded ICC or Windows interoperability guarantee.
- PNG default, all six preceding formats, own grant/context, input keys, pinned writer/modes/audit, schema strictness and replay remain. Source/native missing-feature failures are retained. Matching raster 56 plus five separate neighbors passed, for 61 distinct methods per route; focused source eight is duplicate coverage.
- CLI/app/ordinary Debug/strict signature/native version checks passed on unchanged 464 inputs with actual .37.0/53 seven-artifact candidate. App/CLI wire each passed 23 groups, 46 responses, 44 tool frames and 11 artifacts, including 17 negatives and two immediate cancellations. Qwen completed three observed Low turns and consumed two intact results; seven ICO/PNG native pairs passed with 14 measured provider teardown witnesses. Final document checks and exact source/wiki delivery outcomes are retained externally. No new GUI/full-web/all-model/installed/shipment acceptance or in-work/late-cancel proof is claimed; prior native-pipe blocker and original NONPASSs remain recorded.

- Current candidate identity is the separately preserved ordinary Debug **f477a0b0…**. After the native G3 test action re-signed the prior main, the restored App passed a fresh **0.849 s** run with all **11 artifacts byte-identical** to the original App outputs; the six other compiled artifacts remain exact. Earlier CLI/Qwen and native-consumer results are reused only on the unchanged CLI/core and generated artifact inputs, with no new model or native-consumer invocation. Original candidate/signing evidence remains historical; the current transition is detailed in [the image guide](docs/NATIVE-IMAGE-WRITING.md). Final document recheck and source/wiki delivery outcomes remain in external root receipts.

### `0.36.3 (52)` decoded UTF-8 web cursor correction

- Correct `web.fetch` text/source continuation when supported text expands while
  decoding to UTF-8. Decoded content/cursors are bounded to 3 MiB; HTTP receive
  and original-byte base64 cursor bounds remain 1 MiB. The descriptor states
  both units; use returned cursor/whole-content SHA for continuation.
- Preserve existing decoders, tool names, grants, deadlines/cancellation, final
  notice/ID/LF sizing and all 25 previous web methods. Matching 28 source/native
  methods passed in 13.866/24.896 s; focused source three passed in 14.031 s and
  adds no distinct coverage. Both original one-method cursor failures remain
  NONPASS. [Exact encoding/window scope](docs/WEB-RESPONSE-BUDGET.md) does not
  claim complete Windows/UTF-16 body reconstruction.
- Four separate source/native neighbor methods passed in 2.185/2.507 s, giving
  32 distinct methods per route. CLI/app passed in 0.991/0.903 s; ordinary Debug
  and strict signature passed in 24.888/0.130 s. Signed App/CLI public web checks
  passed in 5.246/4.821 s. Qwen consumed three complete results over four observed
  Low turns; its original fenced-JSON final response remained overall NONPASS.
  A separate raw-JSON correction reused those results without web/native replay.
  Initial G3 passed one method each in 2.743/2.639 s, giving 33 distinct methods
  per route. GUI v3/v4 remain NONPASS: the whole deadline/native CUA pipe
  blocked Projects and filtered Tools checks, with no project mutation observed.
  Final document check results are recorded in external root receipts; exact delivery identities remain external. GitHub-linking GUI, full web, all models, installed,
  other requested formats and shipment remain open.

### `0.36.2 (51)` status build identity correction

- Add string `build` beside `version` in fresh successful `forge_status` and
  `get_forge_status` payloads, including MCP first text/structured content.
- Preserve existing inputs/tool names, resume bootstrap and completed historical
  replay; old recorded responses may omit build. All prior test bodies remain.
- Retain the original one-method/four-assertion missing-build NONPASS. Matching
  six-method source/native checks passed in 13.976/38.620 s, zero failures/skips,
  normal exit 0/unforced. CLI/app compilation passed in 0.986/0.862 s.
  Ordinary Debug/strict signature passed in 24.908/0.133 s; native CLI version
  passed in 0.626 s, normal exit 0/unforced. Signed candidate App/CLI status
  checks passed in 0.654/0.634 s; Qwen passed three observed Low-mode responses
  and two consumed status results in 18.467 s, with exact version/build ACK.
  Initial G3 source/native one each passed in 1.541/2.624 s, giving seven
  distinct methods per route; initial hygiene/whitespace passed in 0.661/0.138 s.
  Exact document rechecks and source/wiki delivery identities belong in external
  closeout receipts; GUI/full-web/all-model/installed/shipment gates remain open.

### `0.36.1 (50)` instruction-package count correction

- Count every retained document, including a ZIP container or manifest, within
  the existing 4,096-document bound. Reject over-limit imports at `makePackage`
  before content identity, immutable publication or queue mutation.
- Preserve ZIP 4,095-members-plus-container, manifest 4,095-entries-plus-manifest
  and ordinary folder 4,096-file acceptance, exact originals, project scope,
  read/reopen behavior and all 40 prior queue tests.
- Retain the original two-test/ten-assertion NONPASS. Matching source/native
  queue selections passed 45 each; the earlier focused five add no distinct
  coverage. CLI/app, ordinary Debug/strict candidate and native CLI version
  checks passed. Initial-document G3 source/native each passed one separate
  method; the 45 owning methods plus one G3 method give 46 distinct methods per route. Initial
  hygiene/whitespace passed; exact source/wiki delivery remains pending.

### `0.36.0 (49)` additive native BMP pixel writing

- Add exact lowercase `format: "bmp"` with an explicit case-insensitive `.bmp`
  destination to existing `image_write`; preserve absent-format PNG and explicit
  TIFF/JPEG/GIF/WebP, common limits, own grant and existing write/context/audit.
- Reuse bounded call-local Apple ImageIO ownership. One 32-bit top-down
  V5/BITFIELDS image retains supplied straight RGBA channels, including all
  alpha values/hidden RGB. Native premultiplied rendering is separate. BMP has
  an sRGB marker, no embedded ICC or Windows interoperability promise, engine
  `apple-imageio`, retained input pixel contract and no new output_contract key.
- Expected missing-feature baseline remains NONPASS. Eight new BMP methods and
  existing catalog one passed in 13.457 s; matching owning source/native 233 passed in
  77.769/76.830 s. Focused repeats add no distinct coverage. CLI/app compilation
  passed in 0.894/0.894 s; ordinary Debug/strict signature passed in 26.025/0.140 s.
  Signed App/CLI wire passed in 1.264/0.799 s, 34 responses/32 frames/10 artifacts
  each; Qwen passed in 32.566 s, three observed Low-mode responses/two selected
  results consumed, 8 responses/6 frames/2 artifacts and strict metadata ACK.
  Separate external native consumer passed seven BMP/PNG pairs/fourteen native
  images, profile/render/provider checks in 0.364 s after 1.969 s compile.
  Initial-document G3 passed once in source/native (1.439/1.767 s); exact
  owning 233-plus-one unions match at 234 distinct methods per route, not one
  234-test invocation. Initial hygiene/whitespace passed (0.679/0.136 s),
  normal exit 0/unforced. Final-document G3 source/native one each passed
  (1.535/1.748 s); hygiene/whitespace passed (0.672/0.132 s), normal exit
  0/unforced, on the same 464-input map. These repeated G3 checks add no
  distinct methods. Later document rechecks and exact source/wiki
  publication, readback and synchronization require separate external receipts;
  no unrun result is claimed.
- Preserve all forty old raster methods/assertions; five unsupported `bmp` fixtures
  become still-unsupported `avif` only with the implementation. No graph member,
  dependency, settings, project-format, grant or signing change is introduced.
- Nine native ICO encode failures and separate nine whole-PNG-wrapper decode
  failures and third DIB+AND ten-case/nine-failure probe remain NONPASS; its two
  public type-hint controls did not change the 1×1 failure/256×256 pass.
  Native-call preemption/common-writer late-cancel E2,
  installed GUI/managed adapter/full web/all models/ICO/audio/archive/SQLite/
  other formats/Release/shipment remain open. [BMP contract](docs/NATIVE-IMAGE-WRITING.md).

### `0.35.0 (48)` additive native lossless WebP pixel writing

- Add explicit lowercase `format: "webp"` with case-insensitive `.webp` to
  existing `image_write`, preserving absent-format PNG and explicit TIFF/JPEG/GIF.
- Encode one lossless VP8L image in call-local bounded Swift. Exact decoded file
  RGBA includes hidden transparent RGB; native premultiplied rendering is a
  separate PNG-reference check. Accept all alpha values; no raw ICC or animation
  promise. WebP engine is `swift-webp-vp8l`, output contract
  `webp-lossless-rgba8-srgb-v1`; retained input contract is `rgba8-straight-srgb-v1`.
- Keep common dimensions/input/output bounds, own grant, replay/context/pinned
  writer, audit and previous format contracts. Complete output is preflighted
  before its bounded Data allocation; canonical graph/signing remain unchanged.
- Actual matching owning source/canonical native 225, CLI/app/ordinary Debug and
  strict signature passed. Signed App/CLI each passed fifteen groups/full EOF,
  nine artifacts and actual cancellation. Actual Qwen completed three normal Low responses/two consumed tool results;
  metadata acknowledgement matched 194 bytes/2×2. Seven production native
  WebP/PNG comparisons passed. Separate initial-document G3 one each passed in
  source/native, establishing matching 226-method unions with the earlier 225.
  Final-document G3 source/native one each passed (1.438/1.867 s), adding no
  distinct methods; hygiene/whitespace passed (0.673/0.133 s), exit 0/unforced.
  Exact source/wiki publication, readback and synchronization outcomes are retained in external closeout receipts.
  Focused seven and external mechanism/parser controls retain separate scopes.
- Middle-loop cancellation and common-writer late-cancel/revocation E2 remain open.
  Installed GUI, production managed-adapter, full web, all models, other formats,
  Release and shipment remain open. [WebP contract](docs/NATIVE-IMAGE-WRITING.md).

### `0.34.0 (47)` additive native single-image GIF pixel writing

- Add explicit `format: "gif"` and case-insensitive `.gif` to existing
  `image_write`, preserving absent-format PNG and explicit TIFF/JPEG.
- GIF accepts alpha 0/255; alpha 1...254 returns `invalid_image_alpha` before
  writing. Palette RGB can change even with at most 256 colors; hidden RGB is
  unpromised. GIF-only output contract is `gif-binary-alpha-palettized-srgb-v1`;
  retained `rgba8-straight-srgb-v1` describes supplied input.
- Interpret sRGB without an embedded ICC promise; one image only. Normalize
  the finalized GIF87a signature to GIF89a without changing subsequent bytes;
  source/native header-equivalence and native consumer pixel checks passed.
- Source 218 plus separate G3 one and canonical native 219 distinct methods
  passed; CLI/app/ordinary Debug and strict candidate passed. Signed App/CLI
  negative/cancellation controls, seven independent production GIF checks and
  actual Qwen write/read consumption passed. Qwen acknowledged metadata only.
  External 35 native mechanism encodes/five controls and 105 parser/synthetic
  owner controls retain separate scopes; earlier focused passes are subsets.
- Final-document G3 and exact source/wiki publication, readback and synchronization are tracked in external closeout receipts.
  Native-call preemption and common-writer late-cancel/revocation E2 remain open.
  Installed GUI, production managed-adapter, full web, all models, other formats, Release and shipment remain open.
  [GIF contract and receipts](docs/NATIVE-IMAGE-WRITING.md).

### `0.33.0 (46)` additive native opaque JPEG pixel writing

- Extend existing `image_write` with explicit `format: "jpeg"` and case-insensitive
  `.jpg`/`.jpeg` destinations. Preserve absent-format PNG and explicit TIFF.
- Encode supplied opaque RGBA8/sRGB through ImageIO at fixed quality 1.0 without
  a thumbnail; JPEG remains lossy. Reject nonopaque input with
  `invalid_image_alpha` before writing. JPEG alone returns
  `output_contract: "jpeg-opaque-lossy-srgb-v1"`; `pixel_contract` describes input.
  Bounds, worker/cancellation, grant/context, pinned-write mode, audit and replay remain.
- Native mechanism and matching 210-method source/native selections passed;
  CLI/app compilation and ordinary Debug passed. Strict candidate, signed App/CLI controls, independent raw JPEG inspection and Qwen API consumption passed.
  Final-document G3 passed in source and native. Source/wiki publication, readback and synchronization are tracked in external closeout receipts.
  Native-call preemption and late-cancel-before-rename/revocation common-writer
  behavior remain unexercised. Installed GUI, production managed-adapter, full web, all models, other formats, Release and shipment remain open.
  [Contract and gates](docs/NATIVE-IMAGE-WRITING.md).

### `0.32.0 (45)` additive native TIFF pixel writing

- Extend `image_write` with explicit `format: "tiff"` and `.tif`/`.tiff` paths,
  preserving absent-format PNG behavior, existing tool/JSON field names and grants.
- Add a bounded native Swift classic TIFF writer for uncompressed straight RGBA8,
  top-left chunky strips and native sRGB ICC data. Keep the PNG ImageIO engine,
  dimension/input/output bounds and existing pinned-write/replay/audit ownership.
- The missing-feature baseline remains NONPASS. Matching owning source/native
  selections passed 203 distinct methods each; direct builds, strict candidate,
  scoped App/CLI, independent TIFF artifacts and Qwen API consumption passed.
  Final document G3 passed in source and native. Exact source/wiki publication/
  readback/synchronization identities will be retained in external closeout
  receipts. Earlier checkpoints and .31 PNG receipts keep their original identities; installed-GUI and broader gates stay open.
  [Contract and gates](docs/NATIVE-IMAGE-WRITING.md).

### `0.31.0 (44)` bounded native PNG pixel writing

- Add `image_write(path, width, height, content)` for an explicit `.png` destination
  and canonical base64 RGBA8/sRGB pixels with straight alpha. Bound dimensions,
  raw bytes and encoded PNG output; validate MCP dimensions from raw number tokens.
- Reuse existing worker, grant, context, audit and pinned-write ownership. Preserve
  filesystem windows, tool deadlines and existing document/web tools.
- External opaque/partial-alpha 2×2 mechanism probes passed independent PNG byte
  checks. Source/native selections passed 198 distinct methods each, including G3;
  CLI/app compilation, ordinary Debug and strict candidate checks passed. App/CLI
  each passed eight controls; seven exact PNG artifacts and three-response Qwen
  API consumption passed. Final document G3 passed in source and native; publication/synchronization receipts will be retained externally. Other
  formats and installed-GUI acceptance stay open.
  [Contract and gates](docs/NATIVE-IMAGE-WRITING.md).

### `0.30.0 (43)` native text-cell ODS writing and import

- Add bounded `ods_write(path, rows)` for one text-only ODF 1.3 worksheet and an
  explicit `.ods` destination. Normalize CRLF/CR to LF; preserve literal text.
- New ODS imports read sheet-labeled cell values instead of package XML. Retain
  originals; blank/unsupported input stays unresolved. Existing packages require
  reimport, with no migration. Reject unsupported direct text blocks, including
  valid lists, before paragraphs or cached values can omit them.
- Preserve grants, custom denials, host-wide OS access and pinned writes. Final
  source/native 199 each, build/signing, App/CLI 16 wire controls, seven independent
  artifacts, two public Core cases and Qwen passed. Original failures and R1 map
  receipts remain; broader gates stay open. [Contract](docs/NATIVE-ODS-WRITING.md).

### `0.29.0 (42)` web verification and qualification-test follow-up

- Correct a stale qualification assertion to use `VERSION` and `BUILD_NUMBER`,
  retaining the exact twelve marketing-version and sixteen build-number checks.
  The owning seven-test class and separate 41-test Xcode CLI class passed; the
  original 900-second full-suite timeout remains NONPASS.
- Verify Qwen consuming public search, fetch and JavaScript-render results through
  the isolated candidate. The installed LM Studio registration still targets 0.18
  (28); no installation or registration was replaced. Product and canonical graph
  inputs are unchanged. [Scope and evidence](docs/PROJECT-WEB-QWEN.md#october-8-web-and-qualification-follow-up).

### `0.29.0 (42)` native text-slide PPTX writing and import

- Add `pptx_write(path, slides)` for bounded plain-text slides and an explicit
  `.pptx` destination. Normalize CRLF/CR to LF; preserve literal text and soft
  breaks. Reject excessive slide XML complexity before publication.
- Import slide-owned text in declared order, retaining original decks. Blank and
  malformed decks remain unresolved without runnable package XML. Reject conflicting
  XML encodings and duplicate expanded attributes; redact document arrays in new audit calls.
- Preserve existing tools, grants, OS-authorized host-wide access and durable formats.
  Source/native 166 each, canonical build/signing, App/CLI 16 wire controls,
  seven reference artifacts, both original Core cases and Qwen consumption passed.
  Original failed receipts remain; installed/GUI, full Office/full web and shipment
  are separate. [Contract and evidence](docs/NATIVE-PPTX-WRITING.md).

### `0.28.0 (41)` native text-cell XLSX writing and import

- Add `xlsx_write(path, rows)` for one text-only worksheet and an explicit `.xlsx`
  destination. Bound rows, columns, cells, UTF-8 input and encoded output; preserve
  literal escape-like text and CR without line normalization.
- Import bounded worksheet cell values with sheet labels and cell references;
  retain original workbooks. Blank/unreadable workbooks remain unresolved, without
  runnable package XML. Actual DTD/entity declarations are rejected; valid CDATA
  containing declaration-like text is data. Formulas are not evaluated.
- Preserve existing tools, grants, owner host-wide OS access and durable formats.
  Owning source/native 124 each, CLI/app, ordinary Debug and strict candidate
  checks passed, plus App/CLI 16 wire controls, both retained Core cases and
  three-response Qwen API consumption. Initial compile and wrong-confinement
  assertion failures remain; GUI/full Office/full web and shipment are separate.
  [Contract and limits](docs/NATIVE-XLSX-WRITING.md).

### `0.27.1 (40)` repeated runtime-subsystem shutdown

- Retain the first completed report on the existing repository actor before close.
  Repeated subsystem shutdown returns that report; incomplete reports remain
  retryable, with plain-close and direct-service inspection behavior preserved.
- Add six parity cases without changing Managed startup, tools or durable formats.
  Owning 211 plus separate G3 one passed 212 distinct methods each in source/native.
- Record four bounded audit fixture measurements. Original native 11/12 NONPASS and
  current three QoS warning blocks remain; no production QoS fix is claimed.
- CLI/app, ordinary Debug and strict candidate checks passed; existing memberships
  remain and PBX changes only version/build settings. Current source/native G3 agreement passed.
  Installation, Release and shipment stay separate. Exact delivery identities are
  retained externally after remote verification.

### `0.27.0 (39)` native plain-text DOCX writing

- Add `docx_write(path, content)` with strict string arguments, an explicit
  `.docx` destination, 65,536 UTF-8 input bytes and 1,048,576 encoded bytes.
  Reject XML 1.0-disallowed scalars and normalize CRLF/CR/U+2029 to LF.
  Native paragraph terminators can add a final LF on text import; no byte-exact
  UTF-8, styled layout, image or Office-suite claim is made.
- Serialize on a worker in a fixed exact-self native child before normal app
  bootstrap. Retain the bounded duplex ownership/termination boundary and the
  existing pinned atomic destination writer. An unresolved child keeps its slot;
  durability failure after rename is reported with inspection guidance.
- Add the exact name only to the builtin Docs agent and ordinary project-default tool sets, replay/progress and
  existing telemetry groups. Preserve custom/imported grants, denials, PDF
  schemas/defaults, shell/binary access and durable formats.
- Preliminary CLI/catalog/ordinary Debug results retain their first input maps.
  Twenty-one new methods are present: sixteen DOCX writer/exporter cases, two
  fixed entry/transport-boundary cases and three catalog cases. The first
  sixteen-method run failed twelve assertions (seven unexpected) across four
  methods. The product operation deadline now samples the clock before reading
  remaining time; corrected fixture paths retain their cases and intended
  assertions. The two boundary methods and same four corrected regressions
  passed separately. Current owning source 154 plus actual G3 passed 155 distinct
  methods; the same native 155 passed, zero failures/skips on unchanged 450 inputs.
  CLI/app and ordinary Debug compilation, strict seven-binary candidate checks,
  exact Docs resource bytes and all 23 existing file memberships passed. Native
  logs retain two audit-queue QoS warnings, seven NECP lines and fourteen PDF
  tagging diagnostics. App/CLI each passed nine wire cases and16/16 consumed
  requests; six documents passed independent OOXML/binary readback. Eight actual
  files passed exact expected native text import. Six production Core cases
  passed, preserving empty originals without inventing usable instructions.
  Qwen R2 consumed two actual tool results across three normal responses, with
  actual Low 3/3 and normal native/observer/collector EOF. First Qwen combined
  NONPASS 2/3 remains; the API result is not installed-GUI acceptance.
  Both standalone native raw-UTF8 gates remain NONPASS.
  [Contract and gates](docs/NATIVE-DOCX-WRITING.md).


### `0.26.2 (38)` MCP notice-receipt hotfix

- Mark a policy notice presented only after its complete JSON+LF packet is
  written. Discard pending presentation state for EOF-skipped, partial or
  failed writes; retain the durable notice's later eligibility.
- Preserve the authoritative tool result, request admission, response-write
  deadline, EOF/cancellation behavior and existing error precedence. No tool,
  argument, public API, grant or storage/schema change is added.
- Retain both one-test/one-failure EOF baselines. The 92 distinct source cases
  and same 92 native cases passed without failures/skips on their original
  450-input map, including the three new EOF/EPIPE cases and existing complete
  packet integration. A later test-only priority correction separately passed
  the same one source and native case. CLI/app, version/graph, final ordinary
  Debug build and strict signing passed. Runtime diagnostics remain.
  Serialization does not prove host acknowledgement.
  [Contract and current gates](docs/WEB-RESPONSE-BUDGET.md#notice-receipt-truth-follow-up).

### `0.26.1 (37)` web response-budget hotfix

- Size successful `web.fetch` and `web.search` stdio responses using the actual
  request ID, duplicated payload, required policy notice and terminating LF.
  Capture the allowance from the exact validated context used to dispatch.
- Reduce UTF-8 or decoded base64 pages while preserving the whole-content SHA,
  offset and returned cursor; keep whole ordered search entries. Preserve
  existing failure codes and router handoff fields. An impossible success
  envelope returns `web_output_budget_too_small` without a delivered body or
  advanced cursor; an impossible error envelope can exceed the allowance.
- Retain the signed .26 escaped-ID baseline: 2,477 text / 2,481 base64 bytes
  against 2,048, normal parent exit and complete EOF. The final 139 distinct
  source cases and the same 139 native cases passed without failures/skips.
  Ordinary Debug build/strict signing and all four repeated native wire cases
  passed; escaped first pages are now 2,047 text / 2,041 base64. Native runtime
  diagnostics are retained, and Qwen completion remains OPEN/NONPASS.
  [Contract and scope](docs/WEB-RESPONSE-BUDGET.md).

### `0.26.0 (36)` ordinary runtime job continuation and owner recovery

- Add native submission references for ordinary project-bound `process.run`,
  `shell.run`, `bash.run`, `python.run` and `powershell.run` handoffs. The bound
  is 32 native submission attempts per logical epoch and 16 KiB of encoded
  extension; keyed retries may reference one job more than once.
- Persist the actual chosen new/reused job UUID in Source before CP COMMIT,
  behind same-connection client/project/generation/full-scope validation and a
  one-use Source epoch fence. Both early and transactional idempotency paths
  use the seam; public managed/provider submission compatibility remains.
  Budget handoffs reuse only unsealed eligible origins; a fresh ID otherwise
  clones authored fields while retaining the predecessor reference origin.
- Add current-authorized exact-packet `runtime_continuation_status` to resume
  before scoped epoch reset. Unavailable rows remain unresolved with replay
  forbidden; no command replay, job scan, database migration or journal is added.
- Preserve authored goals/custom seeds and same-ID sealed authored edits while
  retaining the native origin/reference set. The installed .18 lost-reference
  case and manual output recovery, plus the original one-test/one-failure
  baseline, remain recorded. First CLI/app compiles and the repaired original
  regression passed on their first snapshots. The later focused 24 new source
  tests passed without warnings/errors. The first owning-area NONPASS remains:
  307 tests, 41 assertion failures in two pending-output fixtures. A later
  budget reuse baseline failed 14 assertions; the corrected guard and genuine
  non-owning unavailable-reader fixtures then passed all three selected methods
  without skips/warnings, preserving original assertions and available empty
  snapshots. The earlier owning-area selection passed 307 methods (154
  Continuity + 153 Runtime); a separate exact Manager + version selection passed
  two methods, giving 309 distinct source passes, zero skips/warnings/failures.
  Both incremental SwiftPM products and ordinary canonical native Debug build
  passed. The full native selection passed 309 methods with three QoS
  diagnostics. Two test-only dispatch priorities were corrected, then four
  source and four native methods passed without warnings; the ordinary Debug
  build was confirmed on the later map. The existing DiagnosticLog warning
  remains a profiling target. Strict Debug artifact/build binding passed for
  seven binary files on that earlier 450-input map. Two isolated native MCP cases passed
  with 33 accepted jobs and 56 complete LF responses; the largest measured
  status response was 42,833 bytes within the configured 65,536-byte budget.
  No additive notice was exercised. The first Qwen run remains NONPASS because
  fenced final JSON failed the strict parser. A fresh run with only two external
  prompt strings made explicit passed three rounds/four consumed tool calls,
  exact job/output/authored-task checks and normal stop, without replay.
  A subsequent isolated shared-home/deployment baseline supplies E0: fallback
  job.status interrupted the primary's still-live `/bin/sleep 30` job after 0.713 s,
  producing runtime_owner_restarted and unavailable output while the exact
  primary parent remained alive. Evidence collection succeeded; the feature
  contract failed; that receipt remains NONPASS.
- Protect queued admission and active work with a private kernel runtime lifetime
  lease shared by cooperating native helpers. Startup recovery and artifact/debt
  cleanup skip verified live owners. Durable cancellation reaches the owner
  through its existing monitor; unavailable ownership fails closed.
- Recover abandoned work on authorized warm status/output/cancel reads and the
  bounded selected list page, with claimed ownership and a current scoped requery.
  Exact persisted process identity, termination/debt policy and no-replay behavior
  remain. Cancelled cleanup now awaits its native probe delay instead of spinning;
  the saturated 4,096-probe baseline remains NONPASS and the same four cases passed.
  The final source selection passed 321 methods, zero failures/skips/compiler
  warnings; separate ordinary Debug compilation passed in 24.992 seconds.
  The same 321 native methods passed with one existing DiagnosticLog:64 runtime
  QoS warning. Strict Debug verification of seven binaries, signed live-owner/warm-crash and two continuation
  cases passed on the final map. Fresh Qwen also passed three actual Low/API
  rounds and four verified calls, normal stop/full native EOF without replay.
  Exact direct publication/synchronization revisions are retained in the external
  delivery receipt named in [the contract](docs/ORDINARY-RUNTIME-CONTINUATION.md).
  The 54 capability themes, PDFKit, full-web, installed and shipment gates remain open.

### `0.25.0 (35)` native PDF text and layout

- Native CoreText glyph layout and metric wrapping replace the manual Helvetica
  stream writer behind `pdf_write` and `pdf_from_file`. Existing names, schemas,
  defaults, Markdown subset, 4 MiB content/source limits and
  `engine: "swift-pdf-writer"` remain. PDF bytes and page breaks change; a new
  64 MiB retained-output cap precedes the existing atomic destination write.
- Complete supported tagged PDFs use native logical text in instruction imports
  and policy-source indexing. Incomplete, unsupported or over-budget input falls
  back as a whole to the existing PDFKit path. Empty or whitespace-only semantic
  text also retains that fallback; stored records are not automatically reconverted.
- The corrected owning-area selection passed 101 source cases and the compiled
  native selection passed 102 tests without failures/skips on the original PDF
  product snapshot. Signed Debug and Release each generated eight control PDFs; Qwen used both tools, consumed their metadata
  and stopped normally in a separate two-document API exchange. Both unchanged
  control PDFKit validators passed seven of eight controls, retaining whole
  mixed-script order NONPASS; Qwen's written whole sentinel also remains NONPASS.
  Each profile's ten pages had no measured bounds outside MediaBox; native review
  covered five Debug, ten Release and two Qwen PNG pages. Independent r6 semantic
  validation passed 82 controls (the unchanged original 80 plus exact 32,768/32,769
  operand boundaries) and all eight Debug, eight Release and two Qwen artifacts.
  Its operand ceiling changed from 4,096 to 32,768 after the retained r5 Debug/
  Release three-page quota failures; no original expected outcome was changed.
  Earlier failures remain NONPASS. Both PDFKit compatibility gates remain open
  in [the PDF record](docs/NATIVE-PDF-WRITING.md). The PDF source/wiki checkpoint
  was published and synchronized.
- A later test-only repair captures an immutable fixture URL and uses stateless
  helpers for detached work. The focused UTF-8 regression freshly compiled without
  the original warning, and all 19 writer methods passed with zero failures/skips.
  All 96 existing assertion lines remain, with one new fixture unwrap. The other
  449 source/configuration/graph inputs and product 0.25.0 (35) remain unchanged;
  the earlier candidate receipts keep their original test hash. This test/document
  update was delivered and synchronized at source
  `5ff5559ad02192a90a4887154f48e38c81fa54fe` and wiki
  `3dc576814d2bafdaa2ff303e5011072026e0a378`, both clean with 0/0 divergence;
  `native-pdf-capture-publication-and-synchronization-025.json` retains the exact receipt.

### `0.24.0 (34)` bounded directory continuation

- Added opt-in `fs_list` pagination with project/client/generation/path-bound
  continuation and raw filename byte ordering. Path-only calls preserve the
  legacy response. Signed Debug and Release each passed 35 listing checks;
  Qwen consumed three real one-entry pages and stopped normally.
- Corrected `web.render` final stdio sizing to include its terminating LF after
  an exact-boundary regression reproduced a one-byte overflow. All 17 affected
  renderer service source cases passed. Debug and Release each passed 35 CLI
  and ten app-executable MCP cases with LF-inclusive measurements.
- Strict paged-list input checks preserve the original path type and JSON
  integer tokens before normalization can coerce or round them. All 173 affected
  source cases and the same 173 compiled native cases passed without skips.
- [Listing contract and evidence](docs/FILESYSTEM-LIST-PAGING.md) records the
  baseline, bounds, directory fences and remaining checks.

### `0.23.0 (33)` native JavaScript web snapshots

- Added project-authorized `web.render` for native JavaScript DOM snapshots on
  macOS 27+, using a fresh nonpersistent Lockdown store and one owned fixed-mode
  signed child. Existing text/source/base64 fetch and search remain available.
- Bounded extraction, final encoded successful MCP responses and process/pipe
  ownership have explicit limits and error dispositions. Whole network bytes,
  DOM size and JavaScript heap are reported as unenforced.
- Propagated request deadlines through budget, policy-notice and deadline-error
  response lookups after two actual contention regressions reproduced delayed
  failures. Every response route requires its existing request token.
- Redirect admission now denies repeated provisional URLs before follow, while
  preserving ordinary documents, reloads, frames and hash navigation. Finite
  same-URI cookie/state redirects are an explicit compatibility restriction.
- Debug passed 130 compiled tests and 35 actual MCP cases; Qwen consumed the live
  JavaScript snapshot and finished normally. Release compilation, signing and
  the same 35-case MCP matrix passed; signed Debug/Release app executables each
  passed ten core cases. [Evidence](docs/NATIVE-WEB-RENDERING.md). Installed
  acceptance and broader browser workflows remain open.

### `0.22.0 (32)` binary web fetching

- Added optional `format: "base64"` to `web.fetch`, preserving original response
  bytes for any MIME type. Paged offsets, counts and SHA256 refer to decoded
  bytes; text remains the default and existing network, size and deadline
  bounds remain in force.
- Corrected stale current-version document markers and the version regression
  expectations, retaining every existing assertion and historical receipt.
- Qwen authored and inspected bounded PNG, WAV and DOCX examples through the
  signed 0.21.0 candidate. Exact scopes, retained failures and binary-web
  qualification are recorded in [the current record](docs/BINARY-WEB-AND-QWEN-FILES.md).

### 0.21.0 (31) runtime capability inventory

- Added a bounded, service-startup filesystem inventory for optional executables
  and selected Python framework package assets to `runtime.capabilities`.
- Inventory distinguishes observed presence, missing entries within the searched
  locations and unknown results. Workflow and import verification remain explicit.
- Preserved existing execution gates and job limits; the inventory is omitted
  when it cannot fit the inline result allowance. Source/native regressions and
  actual Qwen consumption passed; qualification boundaries are recorded in
  [the inventory record](docs/RUNTIME-INVENTORY.md).

### 0.20.0 (30) Qwen feedback follow-up

- Added optional bounded HTML page title and first-heading fields to `web.fetch`,
  with body-only paging retained when the inline budget cannot fit metadata.
- Enforced valid memory expiry in normal get/search/recent reads, with explicit
  expired-record inspection, retained exports and expiry-safe page continuation.
- Added an explicit versioned import mode for malformed legacy expiry metadata,
  preserving old export recovery under the existing authorization and bounds.
- Added bounded output snapshots for queued/running/cancelling jobs, with
  provisional hashes and producer completion distinct from the current page end.
- Projects validation errors use a project-request heading rather than implying
  that the Manager is unavailable.
- Source and signed-native before/after checks passed; actual Qwen and Projects
  UI qualification boundaries are tracked in [the follow-up record](docs/QWEN-FOLLOWUP.md).

### 0.19.0 (29) project repository and model tools

- Added project-linked GitHub repository entry in Projects, including normalization,
  Save, Clear, and Open on GitHub. Status and memory descriptors expose the saved URL.
- Added native `web.fetch` and `web.search` for ordinary project-bound MCP chats.
- Added optional base64 binary file reads/writes while preserving UTF-8 defaults.
- Added context lines and filename filters to `search_text`, and a file pathspec
  to `git_diff` with explicit stdout/stderr truncation flags.
- Verification and the separate host PowerShell repair are recorded in
  [the current feature record](docs/PROJECT-WEB-QWEN.md). Candidate and installed
  acceptance remain separate.


**Published owner checkpoint — 0.18.0 (28).** The source and wiki were
published under the owner identity and both local checkouts were synchronized.
The owner subsequently reported installation and authorized the next feature work. The actual managed policy mission remains
**unverified** after a harness preparation failure before model activation.
Installed and all-feature acceptance remain open. [Published references and limits](docs/LMSTUDIO-RUNTIME-REPAIR.md#owner-publication-and-installation-checkpoint).

Managed policy feedback and source replay now pass **93 affected source cases**
(two disjoint selections: 65 + 28, zero failures/skips) on `5af17b77…`, including
the original notice-bearing replay failure. Prior baseline, compiler and
61-pass/one-failure receipts remain NONPASS. Fresh Debug13 reached native build
success but retained a cleanup NONPASS; a separate incremental confirmation
passed unforced. Both targeted native XCTest regressions, post-test five-role Debug
identity and settings now pass. The actual managed notice/correction mission
remains unverified. [Evidence and limits](docs/LMSTUDIO-RUNTIME-REPAIR.md#managed-policy-feedback-and-source-replay--source-checkpoint).

The separate **Forge-owned saved-count rollover mission passed** on retained
`e3762543…`/v11b inputs: five accepted provider turns, four successful reads,
automatic rollover at count 3, same-handoff V2 acknowledgement and predecessor
seal, one successor marker read and completed feedback. Native validation reached
completed revision 16; after a 10.072-second stable window, ordinary APIs restored
count 200 and output limit 4,096, then Manager exited zero with full EOF and no
forced cleanup. Earlier NONPASS receipts remain unchanged. This does not qualify
ordinary GUI rollover, policy comprehension, crash, installed or all-feature
acceptance. [Evidence and limits](docs/LMSTUDIO-RUNTIME-REPAIR.md#forge-owned-saved-count-rollover-mission--pass).

The third **typed Simulator fixture passed** on retained `80f542fa…` inputs:
two actual iOS tests, zero failures/skips, 20 native-zero jobs and 40 complete
producer/page EOF streams. Cleanup removed its owned device and preserved all
32 original devices. The actual LM Studio build/one-XCTest/xcresult chain also
reconciles positively with production completion validation; its original
whole-message-parser receipt stays **NONPASS**, with later provider/policy checks
unperformed. [Exact scopes and evidence](docs/LMSTUDIO-RUNTIME-REPAIR.md#typed-simulator-and-managed-xcode-workflows--scoped-evidence).

Four newer policy/diagnostics/Debug-signing corrections now pass the same **six
source controls** on `e3762543…`: zero failures/skips, native command exit zero,
full EOF and unforced cleanup. The four affected source classes also report
**115 passed, four explicitly skipped, zero failures** (119 started). Earlier
failed attempts and fixture corrections remain recorded.
Fresh `e3762543…` native evidence now includes a passing Release build,
a separate passing **incremental Debug confirmation**, four settings queries and
30 five-role signature controls. The first Debug capture stays **NONPASS** after
owned-helper SIGINT cleanup; the confirmation is not a fresh-compilation claim.
Debug CLI `get-task-allow` is true; all five Release roles remain false with
existing distribution signing. Native Core **6/6 controls** and two separate signed-candidate controls passed;
the area's four historical skips remain. Scoped actual-model signed-CLI LLDB/
production completion independently reconciles positively; original LLDB probe receipts remain **NONPASS**. After-provider/target-after evidence is absent;
remote quiescence and broader feature acceptance are not claimed.
Retained v10 runtime passes qualify their earlier inputs. GUI rollover, broader debugging, crash, installed and all-feature gates stay
open. Count/output controls and detector coverage are retained; [the repair
record](docs/LMSTUDIO-RUNTIME-REPAIR.md#applied-policy-diagnostics-and-debug-signing-corrections--source-and-native-scopes)
records the change and its limits.

Later attempts on `80f542fa…` remain **NONPASS**: the CLI-Manager GUI again
saved/reloaded count 3 but did not complete Provider, relaunch, restoration or
ordinary Quit checks; the second 8,192-token run missed the assigned successor
marker and retained an ambiguous `lmstudio_conflict` turn; actual-model
`xcode.debug` reached LLDB, where macOS denied attachment to the signed CLI.
The [latest repair evidence](docs/LMSTUDIO-RUNTIME-REPAIR.md#latest-gui-second-8192-token-and-model-lldb-attempts--nonpass)
keeps these partial observations and open gates separate from prior passes.

The first current **8,192-token actual-model attempt remains NONPASS**. It
reached the saved-three-call trigger, same-handoff acknowledgement and predecessor
seal, one successor marker read and its completed feedback. The protected-process
count guard then rejected the paused-stability check; cleanup sent one owned
SIGTERM. Stability, ordinary shutdown, restoration and final inventory/coherence
gates did not complete. Later ten-process parity does not requalify that run or
identify the initiating cause.

The current ordinary GUI attempt also remains **NONPASS**. Root's retained CUA
summary records default 200, stepper 4→3, Save 3 and unsaved 7→Reload 3; API/disk
captures agree. Provider output Save/Refresh, restart persistence, restoration and
ordinary Quit remain unverified after SkyComputerUseService failures. Three crash
reports name that service/SIGTRAP; its triggering mechanism and any Forge
accessibility role are unknown. The summary is not raw AX export. Prior source,
native and negative receipts retain their scopes; exact evidence is in the repair
record. Neither partial result qualifies ordinary GUI rollover, actual-model
Xcode/LLDB, Simulator XCTest, crash recovery or the installed product.

The current **private native Stjornarvald v10 replay passed** in 10.182 seconds
on the same `80f542fa…` inputs. It detected the declared production Python fixture,
presented its notice over MCP and recorded correction after membership removal;
resource-only JavaScript stayed advisory, alias roles raised the native finding,
and an unavailable graph preserved history. Manager and both MCP processes
returned zero with full captured EOF and unforced cleanup; 439 inputs, five
candidate binaries, ten protected identities and registration remained unchanged.
Automatic coverage is still **one of 15 indexed rules**, with 14 guidance-only
rules. This private detector/correction/transport fixture establishes no model
comprehension, policy GUI, installed or full-policy compliance; historical job
page EOF receives no native producer-EOF credit. Exact evidence is in the repair
record.

### LM Studio runtime repair — in progress

Current source identity: `0.18.0 (28)`. Adds a saved rollover tool-call setting
(default 200; range 1–10,000) for ordinary MCP chats and managed runs, plus five
native Xcode CLI tools. Repairs durable
continuity tracking, same-scope policy notices and on-demand MCP telemetry.

The current `80f542fa…` checkpoint now has both source and signed native
validation. Full source v14 executed **2,310 cases: 2,297 passed, 13 explicitly
skipped, zero failed**; both Swift products built. Canonical native v10 Debug
and Release builds returned zero with full EOF and unforced cleanup. The Debug
selection passed **49 Core plus two app-hosted cases**, with no failures/skips;
all four build/test captures retained the same 439 inputs. Both configurations'
five roles passed all **30 signature/metadata/entitlement controls**, and all
four effective-settings queries passed. These results close current source,
selected native test, build and platform-identity scopes. Fixture/loopback and
view-model controls do not qualify actual-model Xcode/LLDB, a larger-output
LM Studio mission, onscreen GUI/ordinary rollover, Simulator XCTest, crash or
installed acceptance. Those gates remain open; the 13 source skips receive no
pass credit. Earlier checkpoints and all negative receipts retain their scopes.
Exact current receipts and binary identities are in the repair record.

A subsequent settings/compatibility checkpoint at source `80f542fa…` passed all
**14 focused cases**, native zero, no failures/skips, full **7,073-byte** EOF.
It covers output defaults/omission/persistence and CAS, malformed/authenticated
loopback updates, view-model Save/Reload and unsaved-action gating, immutable
REST-fixture 8,192-token probe/root/continuation bodies and accepted-receipt replay,
and budget headroom/inherited-ceiling checks. The six ordinary source classes
then selected **168 cases**: **166 passed**, **two explicitly skipped**, none
failed; native zero, full **52,355-byte** EOF. Both retained all 439 inputs and
finished unforced with no owned survivor. The two opt-in skips are the live
LM Studio fresh-root/continuation and disposable real-Keychain tests; neither
receives pass credit. This adds deterministic source settings/HTTP/view-model
coverage to the earlier pending checkpoint below. It does not qualify an actual
onscreen GUI, larger-output LM Studio run, refreshed full suite/native candidate,
Xcode/Simulator workflow or installed product. The empty-response cause and full
mission remain open; exact methods, receipts and scope are in the repair record.

A later source slice adds a saved **Maximum output tokens** field to the Provider
form: default **4,096**, range **1–65,536**, including reasoning and the answer.
Legacy configurations without this field use 4,096; explicit saved limits are
preserved. An omitted update preserves the saved value. The existing revision check and busy guard remain in place. This field is
an immutable requested transport limit, not a measured model/service ceiling.
The source repair carries it through capabilities so ordinary budget hooks retain
the same output reserve after provider/tool observations and evaluator restart.
Two REST-fixture regressions passed after their baseline failures; the broader
selection passed **33 REST cases plus one configuration-boundary case**, with zero
failures/skips, native zero, complete **11,351-byte** EOF, stable 439 inputs and
unforced cleanup. These are source checks at `31dcfd8b…`. Settings API/CAS/busy and
UI parity checks, a refreshed full suite/native candidate, and actual LM Studio
use of a larger output allowance remain pending. The v13/v9 results below predate
this slice; they qualify their retained `c1805d1a…` inputs. The empty-continuation
cause and full mission remain unresolved. Exact receipts are in the repair record.

The latest full source v13 run returned zero in **715.678 seconds**: **2,297**
actual cases executed, **2,284 passed**, **13 explicitly skipped** and none failed.
Exact case identities/statuses, class and bundle counts matched the retained
2,286-case v12 baseline plus 11 added QoS, provider-metadata and catalog cases.
The complete **688,301-byte** output reached EOF, all 439 inputs remained stable
and cleanup was unforced with no owned process remaining. Both v13 Swift product
builds also returned zero with full EOF and unforced cleanup. This is source
compilation/test evidence; the 13 skips receive no pass credit.

Canonical native v9 Debug compilation passed in **54.946 seconds**, native
zero with one build-success marker and complete **512,938-byte** EOF. Its selected
native XCTest capture passed **37 of 37** cases, with no skips/failures, native
zero and complete **718,240-byte** EOF. Both retained all 439 inputs unchanged
and finished without forced cleanup or owned survivors. All five Debug roles
passed strict signature, metadata and entitlement controls, and both Debug
effective-settings queries passed. These results are scoped to source
`c1805d1a…`; fixture-driven XCTests do not qualify actual Apple CLI workflows.

One owned actual-model saved-count diagnostic with threshold 3 reached the same handoff acknowledgement
and predecessor seal, then measured the first observed accepted empty successor
`automatic_continuation`. The completed response had provider transport EOF,
one reasoning item, **4,095 reasoning/output tokens**, and zero text/tool calls
under the unchanged **4,096-token** output setting and **262,144-token** context.
The receipt has `diagnostic_complete: true`, `qualified: false`, and
`failure: null`: the full mission marker/feedback proof was not reached. Manager
shutdown returned zero with both streams at full EOF; settings were restored to
200 and all 439 source inputs, ten protected processes and registration were preserved.
The cause remains unknown; no remote-provider quiescence or zero-extra-generation
claim is made. Current actual-model typed Xcode/LLDB, simulator XCTest, ordinary
GUI rollover, crash recovery and installed/artifact acceptance remain open.
Exact receipts are in the repair record.

Earlier canonical native v8 Release compilation passed in **151.458 seconds**, native
zero with one build-success marker, full **538,533-byte** EOF, stable 439 inputs
and unforced cleanup. Debug xcodebuild also returned zero with one build-success
marker and full **512,934-byte** EOF in **57.345 seconds**, but its capture remains
**NONPASS**: cleanup sent SIGINT to tracked PID 52101. Its first ancestry and
executable path are unknown; this does not establish a Forge leak or hang.
At that v8 checkpoint, native37 and refreshed identity/settings had not run.
The later v9 observations above retain the v8 NONPASS receipt; they establish no
cause for its tracked process and add no process exemption or product repair.
Current model workflow, simulator XCTest, ordinary GUI/crash and installed
acceptance remain separate. Earlier checkpoints below retain their own source
and artifact scope.

The refreshed full v10 source run returned zero in 708.278 seconds: 2,264
actual cases selected, 2,251 passed, 13 explicitly skipped and none failed.
All 32 added repair cases passed; complete 678,541-byte EOF, all 439 stable
inputs and unforced cleanup were independently reconciled. Receipt:
`613906ead4407edafc1d17ca9389214acc54bc22499c36850629823485ea6623`.
Fresh canonical native v6 Debug and Release builds returned zero in 57.907
and 152.060 seconds, with full output and all 439 inputs unchanged. All five
roles passed strict signature, metadata and effective-settings checks in each
configuration. The focused native Core selection executed 32 cases: all passed,
none skipped or failed, with full EOF and unforced cleanup. The hosted bootstrap cancellation case and five Rune reorder cases also passed.
The native rollover UI case passed text edits and increment/decrement actions
at both range boundaries. The current signed Stjornarvald control also passed deliberate violation,
ordinary MCP notice delivery, correction and unavailable-graph history checks.
Automatic detection covers one of 15 indexed Raven rules; the other 14 remain
guidance. The current signed candidate’s `xcode.debug` control passed breakpoint,
main backtrace, continuation and target-zero-exit checks for the unchanged signed
owned C fixture. An actual LM Studio model also built for testing, ran one exact
XCTest, read its passing xcresult and reached a completed managed run. That run’s
receipt remains NONPASS because build-for-testing changed two test-host binary
hashes. Six separate read-only post-build signature, metadata and entitlement
controls passed against the current products. This preserves the original
nonpass and does not establish native producer pipe EOF for that historical run.
These scoped results do not qualify the installed app or shipment.

The subsequent producer-output source repair passed all 16 selected controls
without failures or skips. Managed saved-count source testing reproduced four
invocations and no pending request at limit 3, then passed the same control after
repair. The corrected 14-case selection passed without failures/skips, including
three ordinary file-reopen recovery cases, both source-history replay controls,
successor-session isolation and corrupted-result rejection. The earlier 13-case
selection remains NONPASS at its active-session fixture. These changes postdate
the retained v10/v6 checkpoints. Normal v11 remains NONPASS: 2,286 actual
cases selected, 2,270 passed, 13 explicitly skipped and three migration cases
failed on four stale runtime-version assertions. The corrected lineage selection
passed all four cases. Final full v12 returned zero: 2,286 actual cases selected,
2,273 passed, 13 explicitly skipped and none failed, with all 439 inputs unchanged,
full output and unforced cleanup. Earlier failed receipts remain retained.

Subsequent canonical native v7 Debug/Release builds and five-role signing/settings
checks passed against those inputs. All 26 selected native cases passed without
skips, but the retained log reports a priority inversion in the synchronous
Runtime/Xcode bridge. The actual saved-3 model attempt requested and fulfilled
rollover after three completed predecessor reads, acknowledged the same handoff
and sealed the predecessor. Its overall receipt remains NONPASS because the
successor marker read/feedback did not occur before the deadline; canonical
handoff/replay qualification was not reached. The empty normalized responses do
not establish a provider termination cause.

The bridge now snapshots the caller's effective task priority before starting
its detached worker. Both baseline priority controls failed; all eight repaired
priority/deadline/cancellation/committed-receipt controls passed. Normal Runtime
validation passed 122 of 123 cases with one explicit absent-PowerShell skip;
all 41 Xcode cases passed. Complete output, stable 439 inputs and unforced cleanup
were verified. Full v12 and native v7 predate these two changed source/test inputs.
Fresh native priority validation and current model/artifact acceptance remain
open; exact receipts are in the repair record.

The later provider terminal-metadata source checkpoint passed seven focused
controls and all 31 contract-fixture cases without failures/skips. Accepted
receipts now retain bounded optional response metadata; successful provider
transport completion remains separate from native producer EOF and artifact
paging. The cause of the earlier empty continuation remains unknown.

A retained-app policy catalog shutdown control then reproduced three database
descriptors remaining open after completed shutdown and a still-readable catalog.
After the explicit owner close, both focused closure/reopen cases and all 11
catalog cases passed without failures/skips. The initial path-observer failure,
the Darwin.stat compiler failure and the valid two-assertion baseline failure
remain retained. These are source checks with full output, stable 439 inputs and
unforced cleanup. Full source/CLI/app v13 subsequently passed; canonical v8
Release compilation passed and Debug remains NONPASS at forced cleanup.
Native37, identity/settings and runtime qualification remain pending. Current-source actual provider continuation, typed Xcode
build/test, ordinary GUI rollover, crash recovery and installed acceptance
remain open.

A separate direct owned iOS 26.5/iPhone 17 Pro startup completed bootstatus at
17 seconds; AddressBook migration logged success. All 13 native commands
returned zero with complete output, unforced cleanup and all 32 original devices
preserved. Its diagnostic receipt remains NONPASS because the stall/sampling
window was not reached. No XCTest ran; the earlier stall cause and simulator
XCTest qualification remain open. Exact scopes and receipts are in the repair record.

Retained source v9 returned terminal one with 2,247 passes, 13 explicit skips and one
failed bootstrap cancellation case. All 29 new repair cases passed. The focused
failure was `diagnosticHomeMismatch` before cancellation. A bounded repeat
captured equal paths with different directory flags. Bootstrap now normalizes
that hint locally while retaining different-home and file-authority rejection.
All 16 affected source cases and 30 repeated cancellation/retry flows passed,
with complete output and no forced cleanup. CLI/app v10 compilation passed;
full v10 and the scoped native v6 checks passed. After the previously observed SecurityAgent process disappeared, one
unchanged signed C LLDB control passed all breakpoint/backtrace/continue/zero-exit
checks in 0.714 seconds without forced cleanup or authorization changes. Current
typed debugger control passed for the signed C fixture. Ordinary candidate
rollover Settings Save, Reload and same-home GUI relaunch preserved 3, then saved
200; disk/API readback and all owned native exits matched. A subsequent exact
forced-reader reproducer failed two incomplete-output assertions, without a
reader timeout or live child. The subsequent source repair passed 16 controls
without failures/skips, preserving the failed receipt. Current native/model
producer proof, simulator XCTest, automatic successor and complete artifact
acceptance remain open.
The Responses transport now reserves lifecycle capacity within a private finite
5,120-event SSE budget, while preserving the public decoder's 4,096-event default
and initializer contract. The valid 4,104-frame regression and exact 5,120/5,121
boundary controls passed; byte, text, argument, output-token, timeout and exact
acknowledgement protections remain. The original native v3 provider failure is
retained; its raw stream validity is unknown. Full source v8 selected 2,232 cases:
2,219 passed, 13 explicitly skipped and none failed, with all 439 inputs unchanged.
Refreshed canonical native v5 Debug/Release builds and five-role identity checks
passed. The signed Debug CLI executed exactly five SSE controls, all passed,
without skips/failures and with native/serve exits zero and lossless EOF.
Ordinary GUI rollover, SIGKILL recovery and shipment remain separate gates.
The isolated native v5 Manager attempt completed its initial provider turn and
reached automatic provider-usage rollover, then failed the probe's handoff-digest
comparison before any SIGKILL. Native Foundation verified a probe encoding
defect; Forge's canonical digest matches the retained packet. The corrected
v6 probe verified its digest but missed the accepted receipt within its
60-second window. A later 600-second observation durably accepted and acknowledged
one successor and sealed the predecessor, but missed the crash-test boundary.
The automatic continuation remained an intent without tool execution. These
crash-test attempts remain non-passes; no SIGKILL was sent. The
same-home ordinary restart subsequently completed the exact automatic turn,
but its one model-selected read returned `not_found` for
`/home/project/successor-only.txt`. The exact-one-marker check failed; replay
did not execute, and the controller paused before tool-error feedback.
The later separate ordinary resume recovered the original feedback turn and
one successful absolute-path read of the exact owned marker; independent
reconciliation preserved the failed read and H/ACK/seal. Its relative-only
diagnostic remains a non-pass and stopped before settled replay. Final
comprehension, SIGKILL and ordinary GUI acceptance remain unverified. A separate
12.636-second two-launch paused replay passed with both Manager exits zero,
complete streams, unchanged handoff/ACK/seal, two tool results and a 10-second
stable interval. It preserves the earlier non-passes.
One actual model-driven native Rune XCTest passed; the model consumed four
complete test/result streams and reported the actual one-pass xcresult counts.
The managed run nevertheless timed out: the unperformed project build and
unrecognized typed Xcode test evidence left completion obligations unsatisfied.
Typed Xcode completion now binds persisted intent to the actual run-owned native
job, command fingerprint and complete output. It rejects command collisions,
stale summaries, same-timestamp ambiguity, failed/truncated jobs and invalid
xcresult counts. Build and test obligations remain separate; no requirement was
bypassed. Two descriptor regressions failed before repair and passed afterward.
The affected Xcode/Queue source run passed all 78 cases without skips/failures,
with terminal zero, complete EOF and all 439 inputs unchanged. Current signed
native and actual-model completion checks remain pending.
Managed continuity now persists the actual tool outcome, leaves failed ordered
actions open, and excludes failed invocations from handoff completed work.
Three negative cases failed before repair while three success/compatibility
controls passed. After repair, all 14 added cases and all 33 affected source
cases passed without skips. Successful/legacy behavior, bounded metadata,
broker replay, and queued native submission semantics remain available.
These four updated inputs postdate the full v8/native v5 checkpoint; refreshed
native validation remains pending.
Manager settings reads now refresh saved rollover limits before returning both
typed and HTTP settings. The existing bounded configuration refresh preserves
unsaved patches and cached recovery diagnostics. Two stale-read cases failed
before repair; all three focused controls passed afterward. The broader
Manager/continuity selection passed 288 of 290 cases, with two explicit skips
and zero failures; native validation remains pending.
An actual LM Studio model separately completed and consumed a typed native
Xcode version job: five provider turns, four tool calls, exact complete stdout/
stderr, native/Manager exits zero and no forced cleanup. The version-only proof
adds no XCTest, simulator, debugger or ordinary GUI rollover acceptance. The early
Simulator migration sample timed out without a stack, before cleanup; readiness
again timed out at 300 seconds.
Exact owned cleanup preserved all 32 baseline devices; no simulator XCTest ran.
Scoped packet reads preserve project/root/generation boundaries and sole-active
read recovery. Successor receipt admission and consumption preserve deployment
ownership, exact handoff identity, and legacy compatibility. Retained canonical
Debug/Release v2 builds and five-role strict identity checks passed against all
439 frozen inputs; their executed boundaries are recorded below.
Pending rollover requests are sticky while a checkpoint is prepared and are
consumed with the actual packet/counts in one transaction, without rewriting
the active preparation claim. Projection-file failure no longer conceals the
committed SQL handoff. Reusing an acknowledged handoff ID with changed content
is refused; a fresh handoff ID remains supported.
Xcode receipt ceilings include the complete durable wrapper before admission,
preserving native failure exit 65 and same-intent replay. `job.list` keeps
complete rows within the result byte budget and supplies optional paired
`next_cursor.before_created_at`/`before_job_id` fields. Equal-timestamp rows
remain traversable; legacy timestamp-only cursors stay exclusive. Existing
byte-paged output and base64 recovery are preserved.
The completed full Swift v3 source checkpoint selected 2,181 Core cases:
2,168 passed, 13 explicitly skipped, zero failed; filesystem qualification
passed 30 cases without skips. Later paired-cursor/byte-offset/base64 playbook
guidance passed all 14 catalog cases after a fresh scratch rebuild and strict
deep XCTest verification. The original stale resource-seal failure remains
recorded; no trust alias, test assertion or signing-policy change was required.
Both Swift products built before the subsequent status/storage changes.
Saved rollover limits now appear immediately in both status views without
resetting counters or saving pending edits. Missing or malformed configuration
keeps cached recovery readable and adds failure-only `configuration_refresh`
with `state: failed`, `using_cached_settings: true` and bounded error information;
healthy responses omit it. Audit mirrors and Queue initialization now create storage
without recreating default configuration, preserving cached shell opt-out,
durable SQLite/JSONL, cancellation/deadline and snapshot behavior. Directory
layout/0700 permissions and full bootstrap defaults remain unchanged.
Six focused and 300 affected source cases passed without skips/failures. Full
Swift v4 then returned terminal zero: 2,187 Core cases selected, 2,174 passed,
13 explicitly skipped, zero failed; filesystem qualification passed 30 cases
without skips. All 439 frozen product/test/graph inputs remained unchanged.
At the v7 test freeze after this dated checkpoint, only the live test fixture
changed; production and the other 438 frozen inputs stayed unchanged. The built-in
gate correction passed the ownership control. Live v3–v5 each failed one case
without skips;
v5 retained a serialized-estimate rollover before any provider turn because the
26,450-token initial input plus reserve exceeded the old 10,240-token cutoff.
The opt-in fixture now uses 27,648/28,672-token cutoffs, bounded stage/numeric
diagnostics and added initial-normal checks, preserving original usage/ACK/crash/
recovery/marker/GUI/MCP assertions. Live v6 then failed one actual case without
skips in 670.805 seconds. Its initial estimate was normal; the completed initial
provider turn produced actual `provider_exact` / `after_provider_turn` rollover,
used 10,093 tokens and output 511 tokens. Successor bootstrap's sole attempt was
`blocked_failure`; the run was `failed_recoverable` with
`lmstudio_response_truncated`, without ACK/crash/recovery proof. The underlying
incomplete reason is unknown; the code does not prove output-cap exhaustion.
All 14 original process identities/MCP registration were preserved, with no
owned survivors. The v7 fixture's opt-in output cap is 4096; the legacy default
remains 512, with strict failure diagnostics/assertions and
a complete bounded-observation guard. The normal class then compiled and returned
terminal zero: five selected cases, three passes, two disabled live skips, zero
failures in 0.323 seconds. Separately, live v7 passed one actual case without
skips/failures in 487.293 seconds, terminal zero. The isolated owned Manager/API
fixture exercised exact V2 ACK, an injected in-process post-commit error at
`providerBootstrapResponse`, one active successor after recovery, predecessor sealing,
automatic continuation and one marker `fs_read`, then stable paused replay
without an extra effect. The three phases ran in one SwiftPM XCTest process;
the SIGKILL matrix was not executed. All 14 original identities/MCP registration
were preserved, with no owned survivors. Prior failures and their unknown
cancellation/v6 incomplete attribution remain retained. Ordinary LM Studio GUI
rollover, compiled native v2 runtime, LLDB and simulator XCTest are separate
gates; the v7 checkpoint contains no product/lifecycle patch.
After v7, four actual semantic-classifier regressions failed with 39 assertions
and no skips. A narrow JSON failure-field repair then passed the same four cases
without skips/failures in 0.020 seconds, terminal zero. It preserves plaintext
fallback, typed status/retry delay, the 64 KiB boundary and incomplete-response
rejection without ACK/trust changes. Normal affected classes then selected 52
cases: 51 actual passes, one explicit live skip, zero failures, terminal zero.
Native v2 and live v7 predate this repair. The absent v6 bootstrap body prevents
attributing that failure to the classifier defect or output exhaustion.
Later full Swift v5 failed: 2,191 Core cases selected, 2,177 passed, 13 explicitly
skipped and one failed; filesystem qualification passed all 30 cases. The sole
failure used a shell PID log as a descendant-count witness. A controlled test
passed with three kernel child identities and two shell entries; the original
failing interleaving remains unrecovered. The fixture-only correction keeps the
limit-two threshold, state/error and every shell-PID cleanup assertion, adding
exact-identity cleanup and close-on-error. The normal Runtime class selected 113
cases: 112 passed, one PowerShell skip, zero failures.
On October 6, full v6 returned terminal zero: 2,192 Core cases selected,
2,179 passed, 13 explicitly skipped and none failed, plus 30 filesystem passes
without skips/failures. All 439 frozen inputs remained unchanged during the run:
five full-v4 paths changed, 434 unchanged. Skips remain unqualified capabilities.
Canonical native v3 Debug/Release builds passed in 60.309/153.358 seconds, with
439 inputs unchanged and all five roles' strict signature/metadata/settings
checks passed, including 15 native identity controls per configuration. Release
recorded one owned post-build SIGINT. Four classifier XCTests passed through the
signed v3 Debug CLI without skips/failures; native/serve exits were zero and
output was lossless. Typed readback verified exactly four passed cases, no extras,
skips or failures, with both result jobs and serve exit zero. Those builds
precede the later Runtime/Queue test fixtures and Rune reorder repair. Ordinary
GUI rollover, SIGKILL, Compute, LLDB, simulator XCTest and owner-signing acceptance
remain open.
The current 439-input native Compute v3 diagnostic executed one test but failed
two startup activation assertions in 4.135 seconds, with no skips, native exit
65, serve exit zero and complete streams. No cover variant ran. Preserved the
failed preflight and corrected the root's wrong-path SecurityAgent absence
claim; its actual `.bundle` process was foreground. Authorization outcome and
activation cause remain unknown; no production predicate was weakened.
After full v6, corrected the mixed-format Queue test's actor ownership with
`@MainActor` after five native AppKit warnings. The focused case and normal 38-case
Queue class passed without skips/failures; fresh isolated native execution passed
one case in 0.321 seconds, with native/serve exits zero. Three older-late Rune
reorder controls first failed four assertions. Per-command UUID ownership now
prevents older success/cancellation/error from replacing newer order, while current
request rollback remains available. Five focused and 15 normal Rune cases passed
without skips/failures. Refreshed canonical native v4 Debug/Release builds then
passed in 60.369906/158.787937 seconds with lossless EOF, native exits zero and all
439 inputs unchanged. Debug required no cleanup signals; Release recorded two
exact owned post-build SIGINT signals, with no owned survivors. All five roles'
strict identity/metadata/settings controls passed in both configurations; the
independent retained-evidence audit passed all 579 checks. Typed Queue build,
summary and inventory readback confirmed exactly one actual Passed case, zero
failures/skips, three native result-job exits zero and serve exit zero, preserving
configuration bytes. Native Rune v4 used the wrong test bundle and executed zero
tests despite two `Executed 0 tests` lines, `TEST SUCCEEDED` and helper success
flags; it remains a non-pass. Corrected native Rune v5 used the existing
ForgeConductorAppTests scheme/bundle and executed exactly five cases: five passed,
zero skips/failures, in 0.246 (0.248) seconds. Native and serve exits were zero;
581,183 stdout / 590 stderr bytes were reconstructed losslessly with EOF.
Full Swift v7 returned terminal zero in 706.244 seconds: 2,197 Core cases
selected, 2,184 passed, 13 explicitly skipped and none failed, plus all 30
filesystem cases passed. Exact reconciliation verified 2,227 actual selected
cases, 2,214 passes, the 13 skips and complete raw EOF; all 439 inputs remained
unchanged. Skips remain unqualified capabilities. SIGKILL recovery remains
pending; the first candidate attempt failed preparation before any Manager
launch. No installed, full-runtime or shipment acceptance is claimed.
The later direct simulator startup control also timed out at 300 seconds while
reporting the same migration wait, outside Forge with inherited unlimited
CPU/file-size limits. No XCTest ran; exact owned cleanup preserved all 32
baseline devices. This shows Forge launch/limits are not necessary for that
wait, without establishing its cause.
The subsequent owned iOS 26.5 namespace diagnostic also timed out at 300 seconds,
exit -15, before XCTest. Actual 60/120/240-second namespace snapshots and complete
exact-PID log queries retained AddressBook migration duration updates and wrapper
events. A simulator AddressBook TCC allow record establishes no host debugger
authorization, and two reported pending XPC transactions establish no cause.
Truncated query attempts and a timed-out sample remain non-passes. Exact owned
shutdown/delete exited zero and all 32 baseline device bytes were unchanged.
Canonical Debug/Release v1 builds and all
five roles' strict signature/metadata checks passed before these status/storage
fixes, with matching preserved binary/metadata identities. Retained v2 builds
and five-role strict identity checks passed in both configurations. Both compiled
CLI/native Xcode version jobs completed with lossless output and clean serve
exits. The exact Rune coverage/unknown-state app-hosted test and v2
Debug/Release candidate identity/version-drift test each passed one actual case
without skips or failures; these are scoped native proofs.
The earlier October 5 source checkpoint passed 19 focused tests without skips, then
505 affected cases were selected: 499 passed, six explicitly skipped, zero
failed. A subsequent adapter protocol checkpoint selected 34 cases: 33 passed,
one live-provider case was skipped, zero failed. Bounded per-instance bootstrap
ownership rejects concurrent same-session intent replacement; post-await scope,
handoff/digest and cancellation fences prevent late ACK resurrection. Cold
interruption/restart retry passed. Ledger, schema and public fields remain
unchanged; the V2 cancellation contracts retain their controls. Foreground GUI
rollover, live GUI overlap, GUI threshold and debugger acceptance remain open.
The earlier complete Swift checkpoint selected 2,135 Core cases, seven
explicit skips and zero failures, plus 30 filesystem qualification cases with
zero failures/skips. These source snapshots do not establish full qualification.
Optional declared-path roles now distinguish resource-only JS/MJS uncertainty:
the 0.45 advisory finding remains a violation with unchanged identity and
immutable prior history. It grants no exemption or correction. Python and
source/copy/synchronized or legacy script membership retain conservative
positive findings; invalid or incomplete evidence cannot establish compliance.
Native policy v4 remains unqualified after its second-project fixture reused
the first client's durable scope; its Manager/serve both exited zero. Native v5
then passed with separate deployment clients: Python 0.99 violation/notice and 0.98 correction,
resource-only JS 0.45 still-violation/history, source-alias 0.99 and genuine
removal corrections. Manager and both serve processes exited zero. Model-notice
v6 completed one authentic retained notice interpretation in 26.944 seconds,
preserving 0.45 review, compliance unproven, advisory/non-blocking and no
verified correction; the earlier v5 timeout remains retained. The actual
retained-v9 new→old→new fixture passed with three clean CLI exits and a preserved
synthetic seal across a same-ID edit; this is not a real acknowledgement, v8
recovery or installed-build proof. Simulator v3 and alternate iOS 26.5 v4
build/boot commands succeeded, but both 300-second boot-readiness controls
timed out before XCTest; exact owned cleanup preserved all 32 baseline devices
and serve exited zero. Ordinary GUI rollover, general model behavior, LLDB, Compute
and simulator XCTest remain unqualified.
[The repair record](docs/LMSTUDIO-RUNTIME-REPAIR.md) separates original native
reproducers, attempted tests and remaining candidate/live acceptance. Earlier
UI receipts retain their 0.17.0 (27) input identities.

<!-- FORGE-COMPUTE-PCB-FOLLOWUP:BEGIN -->
### Compute PCB refinement — verified native scope

**0.17.0 (27)** tightens each Compute board frame to the trace endpoints,
with eight points of pulse clearance. Headings and engine readings sit outside
the board frames. The entire PCB and surrounding Compute panel are much darker
midnight blue, with subdued silver/gold components, trace highlights and
shadowed metal detail. Approved chip sizes/artwork, banks and core effects
remain. Traveling signals have stronger colored bloom and bright centers;
existing route shapes, signal counts, cadence and pause/hidden/stale bounds remain.

The canonical My Mac AppTests selection passed **45 tests**, with zero
failures/skips; **31 SwiftPM tests** repeat cases from that selection. All
**68 PNGs** were individually reviewed and rehashed: **47 genuine Metal
readbacks and 21 separate NSView caches**, with zero blocking findings,
missing reviews or hash mismatches. The matching ordinary Debug build and
strict signature verification passed.

Separate native cache/Metal layers retain their capture limits; no installation
or distribution was performed. [Compute](docs/COMPUTE-CORES.md) and
[native QA](docs/GRAPHITE-NATIVE-QA.md) retain exact identities and prior failures.
<!-- FORGE-COMPUTE-PCB-FOLLOWUP:END -->

### Preceding Dashboard columns — source 81a91a81…

Version/build remains **0.17.0 (27)**. The lower Dashboard uses equal-width,
independent stacks: MCP Servers above MCP Tools at left, Sub-agents above Hot
Processes at right. Outer edges align while internal splits follow content;
Hot Processes fills the remaining right-column height. Approved Compute
artwork/effects and existing panel content/accessibility identifiers remain.

Thirteen public native view methods passed with zero failures/skips; all 358
PNGs were individually reviewed. The matching My Mac Debug build and strict
signature passed, and the canonical UI target compiled only. [Native
QA](docs/GRAPHITE-NATIVE-QA.md) retains exact current identities, separate
cache/Metal layers and preceding checkpoint limits.

### Preceding frame refinement — source 2463aa06…

Version/build remains **0.17.0 (27)**. Compute frames are smaller and darker,
with duplicate visible hardware names and activity badges removed while exact
accessibility identities/states remain. Approved chip artwork, shader,
renderer, animation and projection are preserved. Dashboard's inline Guided
Mode banner and guide button are removed; other route guidance is retained.
Workbench Settings labels its existing action **Open Guide**. Both Sub-agents
and Hot Processes fill their existing grid row with its 200-point minimum.

The 434-input source manifest `2463aa06…` preserves the canonical Xcode graph
and all 30 resources. Thirteen native view methods passed; all 357 successful
PNGs were individually reviewed. One failed new Guide assertion, corrected
from AXStaticText to the observed AXHeading in the fixture only, remains a
failed checkpoint outside those successful captures. The matching My Mac
Debug candidate passed build and strict signature verification. Separate
30-case Compute and overlapping 16-case SwiftPM results retain their scopes
in [Compute](docs/COMPUTE-CORES.md) and [native QA](docs/GRAPHITE-NATIVE-QA.md);
preceding runtime/distribution limits are preserved.

### Preceding qualified UI checkpoint — source 28548a73…

Preceding checkpoint identity: `0.17.0 (27)`, source `28548a73…`. **Graphite/Compute UI implementation
and required QA are complete.** The native workspace
uses Settings-first optional controls, aligned text and one exact-reference
chip resource with bounded telemetry-driven Metal lighting and static fallback.
Seven Projects actions share 220×32 source bodies; setup step 3 names **Add Project
Folders…**. Fallback labels use current activity/pause; invalid channels stop
their own trace immediately and measured idle keeps bounded hysteresis. Empty
Projects retains its populated list/actions through a native placeholder.

That checkpoint qualification passed 116 distinct production tests in 140 successful
executions, zero failures/skips; the separate 21-method/22-invocation native
view matrix passed and all 463 selectedPNG files were individually reviewed. The
15-check/434-inputaudit, SwiftPMCLI/App, focusedCore 8/H0 (1)/G1 (1) and matching signed
Debug build passed. Four scoped ordinary workflows passed, including healthy/
failure native exports, folder persistence and shellpolicy denial/execution.
Actual Settings/draft/Reload/opt-ins/persistence/restoration and normal Dashboard/
Pause/Resume were observed; all owned cases ended and private state was restored.

[Graphite](docs/GRAPHITE-WORKBENCH.md), [Compute](docs/COMPUTE-CORES.md),
[native QA](docs/GRAPHITE-NATIVE-QA.md) and linked histories retain all 62 criteria/
18 capture scopes,68 currentCompute layers/20 frameMOV, exact candidate identity,
failed checkpoints and unavailableordinary minimum/1×/Skycompositor limits.
Corrected stale pending wording in the current phase records to reflect the
completed native matrix and owner source/wiki publication. Exact publication,
readback and synchronization refs are retained externally.
No installation, notarization, App Store Connect upload or distribution was performed.

### Added

Added behaviors below preserve their earlier checkpoint receipts; the preceding
complete UI qualification and exact input boundaries are recorded above.

- Added a shared native Graphite Workbench palette and reusable panel, field and
  button treatment across the app, Settings, help and Metal telemetry. The
  presentation retains the live destinations and current source controls.
- Added Manager section navigation for Workbench, folders, service, runtime,
  staged settings, shell, protected filesystem, maintenance and doctor. Native
  Settings opens at Workbench; the main Manager entry retains Authorized
  Folders as its initial section. Interface preferences apply immediately;
  configuration Save/Reload remains explicit. Opening preferences preserves
  pre-existing staged Manager edits. Settings has a larger scrollable workspace.
- Added compact CPU/RAM/GPU/disk traces using bounded real history, missing
  sample gaps, restrained luminous strokes, shaded fills and static material.
  The native render lifecycle retains shared resources and hidden-view
  quiescence; focused geometry and production lifecycle cases passed.
- Removed the persistent main-window control bar. Workbench Settings provides
  navigation, telemetry and guidance options, with six independent opt-in
  shortcuts above the current view. Existing Navigation and Telemetry menu
  actions and shortcuts remain; the Guide menu opens contextual help or Guided
  Setup and controls the shared Guided Mode preference. Existing optional
  action identifiers remain. Native settings/menu, individual visibility,
  relaunch persistence and opt-out cases passed.
- Improved Manager form grouping and aligned value columns; bounded short
  numeric fields, ungrouped port/timeout display, wrapping paths and catalog
  identities, clearer essential prose and row baselines. Models, actions and
  eligibility remain unchanged. Fresh normal/minimum and section captures
  passed; the Tools lazy-row/header repair passed strict four-column geometry
  at both sizes, and fresh secondary/Manager/Tools/focus pixels were reviewed.
  Current normal/minimum native review and matching signed-candidate workflows passed; historical retries remain recorded.
- Added local Provider inspection separate from activation. Selecting a
  provider row inspects its information; the existing explicit activation
  toggle remains the transaction boundary.
- Corrected Guided Setup retaining a previous step's lower scroll position.
  Detail viewport identity now follows the selected step while review ownership
  remains outside it; the native scroll/progress regression passed across all
  eight steps, including saved progress and request non-mutation.
- Added read-only registered-project selection in Guided Setup's project,
  instruction and review steps. Preparation can be reviewed before an LM Studio
  chat exists, without binding or activating that project; changed project,
  queue or provider revision invalidates the prior review. The seven read-only model cases, native confirmation/persistence and final
  all-step scroll/progress captures passed.
- Restyled Tools, Live Feed, Agents, Diagnostics and MCP status with clearer
  rows, semantic outcomes, readable metadata and responsive action groups.
  Current filtering, pruning, export and deployment commands are preserved.
- Kept Continuity packet selection local to its native List, synchronizing
  guarded changes with the existing model after a traced selection-time
  publishing warning. Paired native multi-packet and single-packet selection/
  deletion tests passed; the current normal/minimum matrix also passed its
  selected-packet and cancellation parity checks.
- Corrected bundled Dashboard/Manager guide copy to the actual Settings/menu,
  runtime, telemetry, protected-filesystem and Doctor controls. Guide schema
  and resource membership remain unchanged.
- Corrected stale cancelled Continuity packet responses overwriting a newer
  project packet result, with a reproduced failure and passing paired
  regression. Aligned the empty Live Feed header with the other page headers;
  normal and minimum-size native recaptures show the corrected alignment.

- Added stable diagnostic record and process-instance IDs, request correlation,
  sanitized error type/domain/code and failure-stage details, and explicit JSON
  and Markdown export counts, history scope, and timeline omission notices.
  Failed search and shell diagnostics now retain returned execution or durable
  job outcomes; continuity and Dashboard failures retain available operation
  and connection identities. Checkpoint, ingress-drain, and interactive-successor
  paths each retain their own attempt or pass ID, actual stage, handoff identity
  when created, and successor-request state. The
  [capture contract](docs/DIAGNOSTIC-CAPTURE-CONTRACT.md) maps report sections
  A–H to exact writers and regression tests. The earlier source tests did not exercise the later installed signing path.
- Produced the `0.16.3 (24)` universal Developer ID app and `.xcarchive` under
  `~/Desktop/Forge Conductor 0.16.3 (24)-a54100b-DeveloperID`. The app,
  framework, CLI, runtime launcher, and filesystem daemon pass the strict
  Release privileged-bundle inspection. On October 1 a fresh candidate from
  synchronized `main` was installed by its own `forge-conductor install` and
  `install-lmstudio-plugin` commands. The former copied the helper and app to
  `~/.forge-conductor`, not `/Applications`; the latter wrote LM Studio's
  registration. The stopped `/Applications` `0.16.2 (23)` copy was backed up
  and manually replaced with a copy of the signed `0.16.3 (24)` candidate for
  the cold-start check. The CLI-deployed primary, fallback, and CLU
  entries all name the helper that matches the candidate's embedded helper at
  SHA-256 `49e81bc5522aff13d77c0b710417add067467d38e05fec651062be2f5480a289`.
- Prepared the retained `22e7443d13496b3cc08b6e98366bb6d2332e3fd4`
  universal Developer ID Release archive and export as the shippable
  `0.16.2 (23)` owner-notarization set. The Desktop set now includes the app,
  `.xcarchive`, notary-submission ZIP, Developer ID Installer package,
  `HASHES.txt`, and command-only `OWNER-NOTARIZE.txt`. All five shipping code
  objects passed strict signing, hardened-runtime, secure-timestamp,
  architecture, entitlement, and Release privileged-bundle checks. The set is
  ready for owner notarization and Apple upload; it is not notarized, stapled,
  installed, shipped, or released.
- Replaced automatic LM Studio REST successor creation with a visible
  foreground-chat driver. After the existing 30-second countdown, Forge uses
  LM Studio's public macOS Accessibility controls to open **New**, fill
  **Chat input** with `get_forge_status`, `resume=true`, the exact handoff ID,
  and a deterministic nonce, then press **Send**. The installed GUI MCP tool
  must write the exact nonce-bound receipt before the predecessor is sealed.
- Added first-class Continuity packet inventory grouped by project ID. Packet
  rows expose the durable checkpoint/handoff ID, type, source, and timestamp,
  and support exact single or multi-selection deletion after one confirmation.
- Kept **Copy Project ID**, **Reset**, and **Clear Cache** directly on
  Continuity. Reset now clears only project-scoped settled continuity history;
  it no longer delegates to the Projects generation reset. Instruction-package
  selection and deletion remain on Projects.

### Fixed

- Aligned active repository guides and wiki pages with `0.16.5 (26)`, including
  the October 3 bootstrap/export qualification and Developer ID archive workflow.
  Historical versions, artifacts, and test receipts retain their tested identity.
  The existing Xcode project already has the corrected signing and matching
  version/build settings; this documentation update preserves its graph.
  Installed-app references are dated snapshots: the later publication readback
  found the prior app absent and retained the unchanged LM Studio registration
  hash. No installation change was performed by this documentation update.

- Corrected Release archiving to use Developer ID signing and distribution peer
  policy throughout the app, framework, CLI, runtime launcher, and filesystem
  daemon. Re-signing the prior development archive changed daemon hashes while
  preserving its development-only policy and pre-export seals, causing the
  observed bootstrap rejection and stale seals incompatible with the filesystem
  identity validator.
- Added independently owned startup diagnostics and export after bootstrap
  failure. A writable selected folder can receive sanitized live records when
  Forge home is inaccessible; JSON and Markdown disclose unavailable history.

- Corrected `fs_read` so only an observed missing-file POSIX error returns
  `not_found`; permission, nonregular-file, invalid-text, and unclassified
  failures retain distinct codes and their original error identity.
- Corrected the diagnostic export that declared all selected records while
  silently rendering only the last 2,000 Markdown rows. Earlier rows are now
  counted and disclosed, and existing redaction markers survive reload.
- Fixed LM Studio project tools becoming unusable after an MCP helper restart.
  `forge_status` and `get_forge_status` now idempotently attach an unseen MCP
  deployment to an explicit `project_id`, or to the sole active project when
  selection is unambiguous, and report the result in `project_context`.
  Primary, fallback, and CLU helpers share a bounded deployment-scoped client
  identity instead of minting an unbounded UUID per process, so filesystem,
  instruction, shell, Git, runtime, memory, and continuity tools retain their
  durable binding across reconnects. Deliberately invalidated generation-reset
  bindings remain fenced and multi-project selection remains explicit. The
  Dashboard tracker consumes the same restored binding. Instruction catalog
  and read access now accept that project-generation binding directly instead
  of incorrectly requiring an unrelated Managed Run. At that historical checkpoint, LM Studio
  primary, fallback, and CLU registrations targeted the staged v0.16.3
  helper under revision `6b6aa0b4-c3bd-454b-96e4-1273abf390f1`. After a cold
  Forge and LM Studio restart, a new LM Studio chat launched hosted fallback
  PID `33715`; its first `get_forge_status(project_id)` reported v0.16.3 and
  `project_context.attached == true` for deployment-scoped client
  `lm-studio:12ec4eaf…`. Its next four calls—`fs_list`, `git_status`,
  `instruction_catalog`, and `continuity.status`—all succeeded without a
  second bind or `project_context_required` response. The registered project
  alias and Git both resolve Jamf-Technician to
  `/Users/flynn/GitHub/Jamf-Technician`.
  A subsequent CLI staging/deploy run, not a `.pkg` installation, produced revision
  `7a3b0b17-0e39-4cce-b4cd-20df1c6ee9db`. After the copied candidate app
  and LM Studio cold-started, hosted fallback PIDs `38508` and `38964`
  reported the same client `lm-studio:faf23139…` with an attached project.
  The replacement process's filesystem, Git, instruction, and Continuity calls
  each returned `ok: true` without a manual rebind. The registration file was
  unchanged by either GUI launch. GUI Deploy was not exercised and its source
  prefers the running app executable; the signed `.pkg` was not installed.
  Neither path is qualified by the CLI receipt, and no notarization or
  public-release acceptance is implied.
- Corrected ordinary LM Studio bootstrap so `get_forge_status` returns the
  pinned Development Policy identity, every active Rune Forge source path in
  durable priority order, the supported read tools, and an explicit required
  action to read and follow all applicable policy requirements before making
  development changes. The additive response preserves existing project,
  instruction, continuity, and resume fields. The status now also returns the
  bound project's durable instruction-package execution order with package
  IDs, display names, source paths, positions, and immutable snapshot hashes.
  Policy location and the mandatory action remain visible when project
  selection is ambiguous. The live Jamf-Technician LM Studio chat consumed the
  Developer ID build-23 candidate through final repeated fallback PID `12436` and returned
  the complete contract. That retained candidate identity is `0.16.2 (23)`.
- Restored native host access for filesystem, search, PDF, Git, shell, and
  runtime tools by removing Forge's per-command Seatbelt wrapper and
  project-root path confinement. Selected project folders now provide durable
  identity, generation, and the default working directory. macOS evaluates
  TCC, POSIX, and SIP access for the responsible signed code objects in the
  actual launch chain; an exact signed-candidate protected-path probe is the
  required Full Disk Access proof. Tool grants, the shell enable switch, canonicalization, deadlines,
  output bounds, durable result fencing, and destructive-root protections
  remain enforced.
- Added a bounded, start-identity-fenced descendant tracker for native runtime
  jobs. It observes and terminates children that leave the launch process group
  with `setsid(2)` or `setpgid(2)`, while retaining the existing launch gate,
  process-group cleanup, deadline, and output limits. The ordinary per-job
  descendant budget is 16 and retained identities have an absolute 1,024-entry
  cap; either budget overflow becomes a typed terminal failure. Capacity
  overflow remains explicit evidence but cannot keep a job artificially live
  after every retained identity exits. An unconfirmed termination persists a
  bounded cleanup debt with one identity-fenced startup retry, and PID reuse is
  never treated as authority to signal the replacement process. Public macOS
  process snapshots are not atomic, so adversarial same-user code that forks,
  reparents, and exits entirely between observations remains part of the
  explicit native shell trust boundary rather than a claimed sandbox guarantee.
- Hardened native local `fs_delete` and `fs_move` root protection against same-user
  rename races. The execution boundary independently rebuilds the protected
  filesystem, mounted-volume, user-home, Manager-home, and workspace-root set,
  pins the source by descriptor identity, and rechecks that identity against
  every protected root and ancestor immediately before namespace mutation.
  Blank operands, case aliases, changed parents, and inspection failure all
  fail closed without turning ordinary outside-project paths into a sandbox.
- Corrected Dashboard project tracking to resolve live MCP presence through its
  active durable `mcp_client` binding. Recent live activity wins when more than
  one client is connected, a matching nonterminal run is only a fallback, and
  a merely registered project is no longer presented as active.
- Aligned the root version authorities, compiled protocol constants, all Xcode
  configurations, and current user/developer documentation at `0.16.1 (22)`.
  Historical evidence retains the version and build it actually tested.
- Advanced the candidate identity to `0.16.0 (21)`. Durable GUI dispatch state
  records `intent` before any host effect and `submitted` after Send, so retry
  and Manager restart reuse one logical successor instead of opening a stack.
  Electron accessibility-name mapping accepts the observed New button through
  title, description, or value.
- Advanced the candidate identity to `0.16.0 (19)`. Same-host LM Studio now
  rejects new Forge credential values, automatically removes any legacy local
  Keychain reference, and hides credential controls for the local endpoint.
  Linked HTTPS provider credentials remain supported.
- Corrected packet JSON encoding so `project_id` is a UUID string at the
  Manager boundary instead of a synthesized nested value.
- Corrected optimized Release packet decoding so the signed app and its
  embedded LM Studio MCP helper list the same durable checkpoint/handoff rows
  that Debug builds expose. Packet IDs retain their strict bounded ASCII
  alphabet and malformed JSON scalar/container types remain rejected.
- Kept registered projects visible on Continuity when automatic continuity is
  idle or unavailable, because durable packets remain operator-manageable after
  the automation state that created them is no longer active.
- Preserved the operator's existing Forge-owned LM Studio `mcp.json`, manifest,
  and bridge-definition inputs around live-provider UI tests so a disposable
  test home cannot remain registered after success or assertion failure.

### Verification

- The Development Policy bootstrap selection executed 86 Forge tests plus one
  filesystem version-contract test with zero failures. The canonical Xcode
  Core target executed the exact status regression 1/1; both SwiftPM products
  and the ordinary signed Debug app build passed. A direct build-23 Debug
  candidate-helper probe against the live Jamf Technician binding returned the
  active priority-1 policy path
  `/Users/flynn/Projects/raven-forge-development-main`, governing revision,
  supported read tools, and required read/follow instruction. A prior
  app-hosted filter selected zero tests and is not counted. Fresh LM Studio
  model acceptance with the published build-23 helper remains open.
- The complete focused `CoreTests` selection executed 49 tests with zero
  failures. Dashboard operational-snapshot tests executed 23 tests with zero
  failures, including live-binding preference and the registered-only negative
  case. The 103-test runtime-job suite exercised every available runtime profile
  with an external working directory, `/bin/ps`, inherited environment state,
  and cleanup of an observed `setsid(2)` child. The 100-test secure-filesystem
  suite also passed, including blank destructive-path rejection and native
  outside-project delete/move behavior. The final integrated SwiftPM suite
  executed 1,933 tests with 12 explicit environment-dependent skips and zero
  failures; both SwiftPM products, the app-hosted 23-test Dashboard selection,
  and the canonical Debug workspace build also passed.
- Exact implementation revision `91ad90ee7a1e51b7289f4c531ddae4dbbc6812ec`
  produced the retained universal Developer ID candidate `Forge Conductor
  0.16.1 (22)-91ad90e-DeveloperID`. Strict nested signature validation passed
  for the app, CLI, runtime launcher, Core framework, and filesystem daemon;
  every code object carries team `9AQ2C2838M`, hardened runtime, a secure
  timestamp, and no App Sandbox entitlement. The candidate MCP helper reported
  `filesystem_sandbox_mode=none` and
  `filesystem_path_confinement=false`, read a protected Mail path without
  disclosing its content, executed `/bin/ps`, Git, outside-project filesystem
  operations, and a runtime job, and returned the exact bound project from
  `get_forge_status`. Gatekeeper assessment exited 3 with
  `source=Unnotarized Developer ID`; notarization, stapling, Gatekeeper
  acceptance, and shipment therefore remain open. The working installation
  was not replaced.
- Developer ID-signed Desktop candidate `Forge Conductor 0.16.0
  (21)-a540670.app` completed one live disposable rollover. Handoff
  `79474019-000f-4395-a593-cc74a6da2372` showed the 30-second countdown, opened
  selected foreground tab `Forge Rollover Successor Proof`, submitted the exact bootstrap, and
  visibly called `get_forge_status mcp/forge-conductor-fallback`. Exact receipt
  nonce `517cbb4f-f1bd-cc69-e1df-f14ffc7f5f9c` acknowledged at
  `2026-09-28T10:06:48Z`; logical successor
  `51a4567d-36f9-4d44-8a54-925f6e14a0f5` reached `acknowledged`, and the seal
  ledger then recorded the handoff once. A delayed watchdog check retained one
  successor record. No `/api/v1/chat` integrations request participated.
  The live chat's already-running fallback MCP child came from the compatible
  build-20 registration; after the proof, the supported installer synchronized
  primary, fallback, and CLU registrations to the exact build-21 candidate.
- Focused tests execute the packet store's list and exact batch-delete behavior,
  packet wire format, populated native packet rows, and confirmed packet-only
  deletion. Provider configuration tests execute local credential migration and
  rejection. The universal Apple Development-signed build-19 Desktop candidate
  passed its exact-path owner-surface test and real-provider test: same-host
  Connect and Check plus Run Advanced Probe succeeded before and after relaunch
  with `credentialConfigured=false`, with no loopback token field or credential
  action. Two exact-candidate UI runs deleted only two disposable packets from
  the live 75-packet inventory and retained all 73 pre-existing packet IDs. A
  focused multi-selection case deleted exactly two selected IDs in one request
  and retained the unselected row. Automatic LM Studio rollover acceptance
  remains required before shipment. A fresh foreground LM Studio GUI chat did
  successfully call `get_forge_status`, `context_get`, and memory tools through
  the candidate registration without a Forge-held LM Studio credential and
  returned the live project and continuity locations.

## [0.16.0] — 2026-09-27 (build 15 owner-workflow correction)

### Added

- Replaced the primary Managed Run workflow with ordinary LM Studio chat use:
  `get_forge_status` now accepts `project_id`, lists registered projects without
  a run binding, and returns project-file, instruction-store, continuity-store,
  and query-tool locations.
- Added automatic ordinary-chat continuity. A resume-ready handoff publishes a
  visible 30-second Dashboard countdown, then creates one stored LM Studio chat
  through `/api/v1/chat`, enables `mcp/forge-conductor`, submits
  `get_forge_status` with `resume=true`, verifies the exact handoff ID, and
  reuses the durable host-adapter ledger across retries.
- Added multi-folder project selection, multi-source instruction import,
  drag-and-drop package ordering, explicit **Delete Package**, project reset,
  and disposable **Clear Cache** controls.
- Added multi-file/folder Development Policy selection and durable drag-priority
  ordering in Rune Forge, plus per-project policy-log export. CLU notices now
  identify the violated policy and include its bounded redacted policy content.

- Advanced the product identity to `0.16.0 (15)` across repository authorities,
  runtime constants, tests, and every Xcode build configuration.

### Fixed

- Kept Projects folder/package/reset/cache actions, the Continuity project-ID
  list/copy/delete actions, and Provider Advanced/connection/probe actions in
  persistent visible regions. Continuity retains its controls in the empty
  state, and the staged application bundle now includes both SwiftPM resource
  bundles and must remain alive for three seconds before smoke verification
  succeeds.

- Unified LM Studio selection, **Connect and Check**, the Advanced connection
  check, and provider probe on the same actionable Manager preparation path so
  they no longer fall through the obsolete run-resumption path and report a
  misleading `manager unavailable` result.
- Replaced the Continuity operator UI with a scrollable registered project-ID
  list plus **Copy Project ID** and project-scoped **Delete**. Manual checkpoint,
  rollover, run selection, timelines, and old-item cleanup controls are no
  longer part of that view.
- Removed Managed Run launch instructions and labels from current Guided Setup,
  Dashboard, Projects, Provider, Rune Forge, and Continuity guidance. Retained
  low-level run services remain compatibility-only.

- Removed the documented app-hosted Thread Performance Checker inversions by
  matching diagnostic delivery, shutdown, and project-context waiter QoS to
  their bounded callers. Authenticated operator credential file work also now
  leaves the main actor before request construction.
- Restored usable Projects instruction-package controls in constrained window
  geometry. Explicit earlier/later and **Delete Package** buttons remain
  distinct controls, and stale background snapshots cannot roll back a newer
  persisted package order.
- Limited provider-repair auto-resume to the active project generation, so a
  durable historical run cannot abort recovery of current-generation work.
- Retained 1,024 bounded managed-provider receipts—two complete windows for the
  maximum 16 concurrent runs and 32 tool rounds—so a current run can reconcile
  its first turn after a durable yield without unbounded storage.
- Preserved the original checkpoint observation when a context-budget request
  escalates to rollover or emergency, while still applying the request's newer
  severity. A valid escalation no longer appears as V2 identity drift.
- Quarantined the exact project-local continuity operation when its owning run
  is cancelled. Recovery also removes a legacy stranded operation only after
  proving that its owning control-plane run is terminal.

### Verification

- An ordinary Apple Development-signed app launch passed
  `testOwnerWorkflowSurfacesRemainVisibleFromOrdinarySignedLaunch`, retaining a
  screenshot and accessibility hierarchy for Projects, Continuity, Rune Forge,
  and Provider. The versioned source also passed
  `testRealProviderModelDiscoveryAndConnectionFromSavedNativeConfiguration`
  against loaded model `qwen/qwen3.8-27b`; **Connect and Check** succeeded before
  and after relaunch without `operator-unavailable`. Final Desktop-candidate
  archive, exact-binary UI rerun, Advanced-probe rerun, and ordinary LM Studio
  chat acceptance remain open, so this is not a shipment claim.

- The September 27 owner-workflow correction passed the complete 1,902-test
  Swift suite with 12 explicit environment-dependent skips and zero failures;
  both SwiftPM products and the canonical Apple Development-signed Debug app
  built. Two current-source production Manager routes passed against loaded LM
  Studio model `qwen/qwen3.8-27b`: live **Connect and Check** readiness reuse
  and the live provider probe. Five focused native UI tests passed for the
  project-ID-only Continuity surface, ID copy, project-scoped deletion, and
  minimum-window instruction package reorder/deletion. Current native-candidate
  Provider-button, CLU-delivery, and full automatic rollover acceptance remain
  open; these results do not claim shipment.
- Product source `849b87953b4420f07a629fdcd29ecf0d58216756`
  passed the complete 1,890-test Swift suite with 12 explicit skips and zero
  failures and the complete 111-test app-hosted suite with zero failures. The
  exact Desktop app at `/Users/flynn/Desktop/Forge Conductor 0.15.0
  (14)-849b879.app` reported `0.15.0 (14)`. Against the Mac's stored Continuity
  data, **Clear Selected** removed
  `c36460fe-05ae-b00c-8aae-100209600137` from 24 visible IDs; **Clear All Old**
  then reduced the remaining 23 IDs to none, and none returned after Refresh or
  exact-app relaunch. The matching `.xcarchive` remains beside the app and the
  working installation was not replaced. Developer ID distribution,
  notarization, owner acceptance, and shipment remain separate.
- Candidate source `74ead97e0b4d2116e80e8482d5736afc94e16372`
  passed all 37 instruction-queue tests and all 18 Projects view-model tests.
  A new integration case started a real run-owned `sleep 30` runtime job,
  stopped its queue, verified job/run cancellation and terminal package state,
  then removed the unlocked package.
- The Apple Development-signed native minimum-window UI case clicked **Stop
  Active Work**, Move later, and **Remove**, observed persisted state through a
  later two-second poll, and passed. The separate signed real-Manager UI case
  imported two packages, persisted reorder, removed one, and passed. Both
  SwiftPM products built, and a strict-signature-verified universal Debug app
  plus `.xcarchive` were created outside `/Applications`.
- A signed owner-machine acceptance test attached to Desktop candidate
  `/Users/flynn/Desktop/Forge Conductor 0.14.7 (13)-74ead97.app`. At normal
  size it started LM Studio run `450f1a7f-8f49-4d78-bd7d-1e97c94f6273`,
  clicked **Stop Active Work**, observed the run/package `cancelled` and Remove
  enabled, persisted an earlier move through Refresh, and persisted removal.
  At the 1100×788 minimum window it repeated the live flow with run
  `850f0576-225f-4b04-a4ff-a5d43471494d`, clicked the hittable Stop, Move
  later, and Remove controls, and verified reorder/removal after Refresh. The
  pinned `qwen/qwen3-coder-30b` model was `IDLE` after Stop. The retained
  `.xcresult` executed 1 test with zero skips and zero failures. No shipment
  claim is made.
- Published ordered-readiness/receipt repair
  `675d267fdd2f45cd412e5398a04a2321bfe51def`, budget-escalation repair
  `f39c79ad0e60259d7a02ba0361825e5b6940c136`, and cancellation-authority
  repair `101c3d44f80c689c428e255f4578d88c54f40c16`. The final complete
  SwiftPM regression passed 1,879 tests with 12 explicit skips and zero
  failures; both SwiftPM products and the canonical Debug workspace app built.
  Focused regressions cover unloaded-pin admission before mutation,
  current-generation-only resume, 33-turn restart replay, 1,024-record
  compaction, checkpoint escalation, and cancellation quarantine.
- Installed the repaired Apple Development-signed app at
  `/Applications/Forge Conductor.app`. Its exact native UI passed two cases:
  launch without automatic Guided Setup and selectable Provider cards with the
  LM Studio no-resume/repair/resume transaction. The installed manager returned
  HTTP 200 for the owner's same project/package **Start Ordered Work** request.
  Final live run `6573026b-35f1-47b8-a0c6-6b4df226eed7` completed 50 LM Studio
  turns, 41 tools, and 18 automatic rollovers without the LM Studio
  configuration, receipt-reconciliation, identity-drift, or stranded-operation
  failures found during repair. It then paused at its separate package
  completion gate because project-build and project-tests evidence was absent.
- Strict deep signing passes for the installed development build. Gatekeeper
  distribution assessment rejects it because it is not a notarized Developer
  ID artifact; no public-distribution or shipment claim is made.

## [0.15.0] — 2026-09-27 (build 14 continuity retention controls)

### Added

- Added confirmed Continuity cleanup controls for deleting one selected old
  item or every old item across registered project generations. Old means a
  terminal command or a missing/terminal owning run. Cleanup retires stale
  nonterminal project state and removes Continuity operation, handoff,
  transition, repair, and rebuildable projection data plus its visible list
  root. A genuinely live item remains visible with its exact blocker and
  recovery action. Ordinary project memory, tasks, runs, credentials, project
  files, and unrelated project data remain unchanged.

### Changed

- Advanced the development product identity to `0.15.0 (14)` across repository
  authorities, runtime constants, tests, and every Xcode build configuration.
  This identity change makes no shipment claim.

### Fixed

- Removed app-hosted priority inversions in diagnostic delivery, shutdown, and
  project-context waiting, and moved authenticated operator credential I/O off
  the main actor before constructing loopback requests.

### Verification

- Product source `849b87953b4420f07a629fdcd29ecf0d58216756`
  passed the complete 1,890-test Swift suite with 12 explicit skips and zero
  failures and the complete 111-test app-hosted suite with zero failures. The
  exact Desktop `0.15.0 (14)` app cleared one of 24 live stored Continuity IDs,
  cleared the remaining 23, and retained an empty list across Refresh and
  relaunch. Its matching archive is staged beside it outside `/Applications`.
  Distribution, notarization, owner acceptance, and shipment remain owner
  actions.

## [0.14.7] — 2026-09-26 (build 13 identity correction)

### Changed

- Corrected the product version and build identity for the product commits that
  landed after `0.14.6 (12)`. This identity change makes no shipment claim.

## [0.14.6] — 2026-09-26 (build 12 development repair candidate)

### Fixed

- Kept exactly one execution provider active in the native Provider UI. Clicking
  the active selector no longer submits a second deactivation that can leave
  ordered-run admission without a provider; selecting another provider performs
  the existing readiness-fenced switch.
- Made LM Studio activation supersede a replaceable background Provider snapshot
  load. An enabled LM Studio selector can no longer silently ignore the user's
  **Connect and Check** action during view startup.
- Preserved the no-resume preparation request through the app's manager-client
  router. Retained provider-wait runs now stay quiescent until integration
  repair completes and the required post-repair preparation succeeds.
- Stopped presenting Guided Setup automatically when Forge Conductor launches.
  The wizard remains available from Dashboard and the title bar and retains its
  saved step between explicit uses.

### Verification

- The complete SwiftPM regression passed 1,875 tests with 12 explicit
  environment/helper skips and zero failures. The focused Provider suite passed
  27/27 and Guided Setup progress passed 4/4.
- Four exact app-hosted Xcode regressions passed. Signed native UI passed the
  launch-without-wizard case and the Provider selection/LM Studio transaction,
  including the exact no-resume/repair/resume request order.
- Both SwiftPM products and the canonical Apple Development-signed Debug
  workspace app built. Repository hygiene and exact `0.14.6 (12)` identity
  checks passed. Prior live-provider, installed-build, and distribution evidence
  is not inherited.

## [0.14.5] — 2026-09-26 (build 11 development repair candidate)

### Added

- Added the first Forge Link foundation for a future remote LM Studio endpoint:
  a versioned local-or-linked provider mode, strict transport-neutral discovery,
  pairing, health, capability, control, and role contracts, plus an owner-only
  revision-checked paired-node registry. Existing provider data migrates to
  local mode. This slice does not expose discovery, pairing, a network listener,
  or a remote endpoint in the UI and does not claim live GB10 qualification.

### Fixed

- Made a folder package runnable whenever it contains at least one readable
  instruction document. Every source is still retained and catalogued, but an
  unsupported attachment such as `.DS_Store` or an opaque binary no longer
  blocks the readable instructions beside it.
- Kept package intake and ordering available while ordered work is running;
  adding or rearranging pending packages does not replace the active run.
- Consolidated instruction selection, ordered execution, direct task creation,
  and run controls under **Projects**. The redundant top-level Autonomy tab is
  removed; **Run Details…** opens the retained run inspector and controls.
- Moved the macOS toolbar into dedicated AppKit chrome so project headings and
  controls remain below the title bar at minimum window size.
- Combined CPU logical-core and GPU core/engine presentation in one
  **COMPUTE CORES** telemetry frame. The operator has accepted this frame.
- Kept Continuity's managed-run contract directed at automatic session handoff:
  durable save, fresh successor creation, exact acknowledgment, predecessor
  fencing, and automatic continuation remain one recoverable flow.
- Preserved an already loaded LM Studio model while deploying an unchanged,
  synchronized Forge MCP configuration. Routine setup no longer relaunches LM
  Studio merely because its MCP child processes are waiting for lazy chat
  activation.
- Restored a current provider-readiness projection from the durable exact-model
  receipt after app and Manager relaunch, so setup status does not regress to an
  unverified placeholder before the next explicit probe.
- Made the Codex package executable from the installed desktop host by including
  the bounded signed runtime closure, retaining the host-compatible manifest,
  and registering the MCP command through the app's signed helper path.
- Made successful trusted Codex `PostToolUse` events durable, bounded completion
  evidence. Read-only automatic tasks can now satisfy their compiled completion
  plan after a successful allowed Forge tool call and an exact completion marker.
- Updated the production onboarding fixture for immutable artifact bootstrap and
  canonical completion gates without weakening production validation.

### Verification

- Passed the complete SwiftPM regression: 1,872 tests executed, 13 explicit
  environment/helper skips, and zero failures. The skips are not counted as
  passes.
- Passed all 36 instruction-queue tests, all 15 operator-project contract tests,
  and three signed native UI cases covering primary navigation,
  Projects-to-Run-Details task entry, and minimum-window toolbar clearance.
- Built both SwiftPM products and the canonical Apple Development-signed Debug
  workspace app. Strict deep-signature verification and exact bundle/CLI
  identity checks passed for `0.14.5 (11)`.
- Live LM Studio and Codex execution has not yet been repeated for this exact
  identity. The live receipts recorded under `0.14.4 (10)` remain historical and
  are not used to call `0.14.5 (11)` shippable.
- Autonomy removal passed operator review. Mixed-folder package import,
  Projects-owned ordered LM Studio execution, and automatic Continuity handoff
  are implemented pending owner live review; no acceptance or shipment claim is
  made for those three items.

## [0.14.3] — 2026-09-25 (development)

### Fixed

- Made project setup transactional around LM Studio integration deployment.
  **Connect and Check** now keeps retained provider waits quiescent until the
  integration operation finishes, then re-probes the provider and resumes the
  exact retained runs. A bounded Manager fallback performs the same recovery if
  the Provider view closes before observing the terminal operation.
- Moved provider readiness ahead of instruction-artifact import during
  **Start Task**, so a missing model or unavailable provider no longer leaves
  an orphan immutable setup artifact. Deterministic non-retryable Manager
  conflicts now surface as configuration errors instead of triggering an
  inapplicable lost-response reconciliation.
- Corrected release-contract tests that still asserted `0.14.1 (7)` after the
  prior version advance, and advanced this backward-compatible repair to
  `0.14.3 (9)`.

### Verification

- Built both SwiftPM products and the signed canonical Debug app; the full
  SwiftPM suite completed 1,848 tests with 12 explicit environment/helper skips
  and zero failures. Separate zero-skip live LM Studio checks passed provider
  preparation plus fresh-root acknowledgement and automatic continuation.
- Passed signed native UI registration through both an absolute path and the
  macOS folder picker, including Manager readback, allowed-root persistence,
  and relaunch. The onboarding harness now isolates completed Guided Setup
  state so the intentional first-run sheet cannot mask unrelated controls.

### 0.14.2 (8) operability repair

- Managed model task prompts now identify instruction snapshots and explicitly
  direct catalog/document paging before execution. Unread instruction packages
  retain their known progress totals instead of reporting zero documents.
- Repeated completion requests with identical validation evidence now obey the
  saved failure/retry policy. The no-progress count survives activation/restart;
  exhausted retries preserve the run in a paused state instead of looping.
- Autonomy opens new-task completion checkboxes expanded and links to that
  setup from the existing task's read-only evidence record. This does not permit
  manually marking unproven evidence as passed or changing an active contract.
- Rune Forge shows bounded durable policy evaluation activity separately from
  violation events and states the current detector coverage limitation.
- GPU Cores is below CPU Cores. Compact Storage and Orchestration frames leave
  additional horizontal space for Managed Activity.

### Prior development line

- Version `0.14.3 (9)` was the preceding unreleased development identity. Its
  guided setup, Autonomy, Continuity, provider-recovery, desktop-integration,
  native UI, and qualification changes are recorded in the development section
  below; no distribution or shipment is claimed.

## [0.14.1] — 2026-09-23 (development)

### Added

- Added the persistent eight-step **Guided Setup** wizard to the Dashboard title
  bar. It walks through Manager readiness, provider readiness, project
  registration, instruction packages, Autonomy choices, review/start
  confirmation, monitoring, and issue recovery while preserving the current
  step.
- Added universal **Connect and Check** actions to selectable provider cards.
  An inactive card performs the complete manager-owned provision, inspection,
  readiness, and selection flow; an active desktop card verifies or repairs its
  installed integration.

### Changed

- Made completion ownership explicit: Forge configuration exposes only its
  built-in evidence checkboxes, while an instruction package remains the sole
  owner of any additional completion requirement. Package requirements are
  displayed read-only and evaluated by the Manager from durable run evidence.
  Unknown configuration-owned completion identifiers are rejected.
- Restored Continuity's complete operation/history/detail behavior in an
  adaptive layout that stays below the toolbar and removes the unused middle
  frame when no operation is selected. Protection and recovery states now name
  the retained condition and, when operator intervention is required, the
  owning action; automatic recovery is stated directly when no action is needed.
- Removed the remaining instruction-queue path that converted a transient
  pre-run creation failure into a configuration block. Forge now retains the
  exact durable run identity and retries it automatically through the existing
  Manager watchdog; paused runs keep their package linkage without creating a
  separate queue blocker.
- Kept **Managed Activity** compact beside Storage at normal Dashboard widths;
  the rolling response, tool, orchestration, and project-policy feed remains
  bounded and expands only where the available width requires it.
- Updated Settings Doctor guidance to report the running version/build and all
  current LM Studio roles, including CLU, and to offer current-build deployment
  for stale or missing owned registrations.
- Advanced the development identity from `0.14.0 (6)` to `0.14.1 (7)` for this
  backward-compatible operability correction. This is not a shipment claim.

### Fixed

- Fixed Swift 6 strict-concurrency diagnostics in desktop MCP tool-description
  construction and the Provider activation binding without changing the MCP
  schema, provider-selection behavior, or Xcode target membership.
- Fixed Xcode 27's no-AppIntents metadata phase so it produces its intended
  empty output without emitting missing-framework warnings or adding an
  AppIntents dependency.
- Fixed LM Studio discovery on a second Mac by checking the supported system,
  per-user, symlink, Homebrew, and `PATH` CLI locations; accepting bounded
  status wrappers and string ports; starting the local server when needed; and
  polling readiness before the normal authenticated inventory and contract probe.
- Fixed Autonomy so completion checkboxes are selectable and retained run states
  show a specific recovery explanation based on the owning project, provider,
  or package requirement. Legacy configuration states recover automatically
  without additional Forge configuration or an environment reset.
- Fixed desktop provider activation so nonzero CLI results are accepted only for
  narrowly recognized already-installed outcomes followed by live inventory
  verification. Codex packages now carry the portable MCP schema, and Grok
  packaging follows its documented passive event set without making Grok
  selectable.
- Fixed Continuity title, refresh, selected-operation, and empty-state geometry
  so content no longer runs beneath the top bar and no supported detail surface
  is removed.
- Verified the final source with 1,844 SwiftPM tests (13 explicit skips, zero
  failures), both SwiftPM products, a warning-free arm64 Xcode Debug build, and
  native UI coverage for the full eight-step wizard, provider controls,
  Autonomy recovery, Continuity detail/title-bar clearance, Dashboard panel
  geometry, and every primary view at minimum and normal window sizes.

## [0.14.0] — 2026-09-23 (development)

### Added

- Added mutually exclusive Provider activation for LM Studio, Claude Code
  Desktop, and Codex Desktop. LM Studio retains Forge-managed model turns;
  selectable desktop providers retain their host-selected model and session.
- Added a visible, non-selectable Grok Build compatibility card. Forge can
  inspect or remove its own staged artifacts, but does not advertise Grok as
  ready or admit Grok runs because the documented Grok startup/prompt hook
  outputs cannot deliver Forge's initial assignment context to the model.
- Added transactional Forge-owned desktop plugin, hook, skill, and MCP
  provisioning with ownership verification, compatible settings merges,
  supported-CLI JSON activation verification, rollback, repair, selective
  removal, restart reconciliation, cancellation, and a bounded redacted
  operation ledger. Generated hooks and MCP registrations share the same
  explicit Forge home.
- Made desktop removal fail closed at the host-registration boundary. When
  supported CLI/live inventory cannot verify unregister, Forge preserves its
  owned files and receipt, reports **Awaiting User Action**, and settles an
  idempotent retry only after host removal is verifiable.
- Added authenticated loopback Manager endpoints for provider snapshots,
  selection, operations, repair, removal, and bounded desktop hook events, plus
  the internal `provider-hook <provider-id> <event> --home <path>` bridge.
- Added provider-fenced desktop MCP launches and the `desktop_run_attach`
  bootstrap. Hook assignment context carries a five-minute, single-use
  capability bound to the exact provider, session, run, project generation,
  selection revision, and deployment; all other Forge tools fail closed until
  attachment, and session/run termination revokes the binding.

### Changed

- Bound Autonomy preparation and admission to the exact durable provider
  selection and verified deployment revision. Desktop runs record
  `desktop_plugin_pull` and `host-selected`; they do not activate LM Studio's
  managed-provider-push runtime or claim to own a private desktop conversation.
- Serialized provider mutations against run admission and reject selecting,
  deselecting, repairing, or removing a desktop provider until its nonterminal
  tasks are finished or cancelled, so its host hook path cannot be stranded.
- Reworked Provider into activation and operation cards while retaining LM
  Studio endpoint, model, credential, inventory, and contract-probe controls
  under **LM Studio Advanced**. Turning on LM Studio runs **Connect and Check**
  first and changes selection only after current readiness is verified.
- Made Dashboard and Guided Setup project the selected provider's readiness.
  Claude or Codex can report **HOST READY** independently of LM Studio health
  only when ready preparation, the current selection revision, and its verified
  receipt agree; stale, missing, or non-selectable evidence fails closed.
- Advanced the development identity from `0.13.0 (5)` to `0.14.0 (6)` for this
  backward-compatible provider-integration feature release. This is not a
  shipment claim, and live desktop-host acceptance remains separate.

## [0.13.0] — 2026-09-23 (development)

### Added

- Added an eight-step, state-aware **Guided Setup** wizard launched from the
  Dashboard title bar. It gives the setup order, current readiness, success
  criteria, launch choices, monitoring map, and issue-specific recovery routes
  for Manager, Provider, Projects, Autonomy, Continuity, Rune Forge, and
  Events & Evidence.
- Added bounded local LM Studio recovery to **Connect and Check**. For saved
  loopback configurations, Forge uses LM Studio's supported `lms` CLI to read
  or start the server, validates only the CLI-reported port through the normal
  authenticated inventory path, preserves explicit model and credential
  choices, and then runs the existing contract probe.
- Added current-build Doctor reporting for version/build and each LM Studio
  primary, fallback, and CLU plugin role. Stale plugin files remain visible as
  installed artifacts while Doctor offers **Deploy current build** to repair
  their executable binding.

### Changed

- Renamed the visible **Forge Rig** navigation and title surface to
  **Dashboard**, preserving its existing internal tab and accessibility
  identifiers for compatibility.
- Made Autonomy completion checks inline, selectable checkboxes. Built-in and
  preset checks now run through the manager's compiled automatic completion
  plan; the bound instruction package exclusively supplies any additional
  completion requirements.
- Preserved instruction-package tools and `completion_gates` schema values
  through single,
  imported, and ordered composite run artifacts, while merging only explicitly
  selected manager-owned automatic checks for direct runs.
- Reworked Autonomy failure guidance and Continuity protection states to show
  the exact retained condition and route recovery to Provider or Autonomy.
- Removed Continuity's nested navigation container so its heading and refresh
  control stay below the toolbar and the empty operation state no longer leaves
  an unused middle frame.
- Advanced the development identity from `0.12.0 (4)` to `0.13.0 (5)` for this
  backward-compatible setup and operability feature release. This is not a
  shipment claim.

## [0.12.0] — 2026-09-23 (development)

### Added

- Added a bounded, redacted, coalesced **Managed Activity** projection directly
  below the Rig's Load Trace and Orchestration Status. It identifies the active
  project and instruction package, current inferred step and durable delivered
  count, current phase/work/next action, durable managed-model responses and
  tool transitions, orchestration events, and the newest exact
  project/generation-scoped Rune Forge policy events. Detailed activity text
  comes from an authenticated endpoint fenced by exact run, project, and
  generation. The public operator snapshot preserves bounded, redacted mission
  and work-item text plus non-sensitive state, identity, and event metadata,
  but omits current phase/next action, assistant/model-error/tool summaries,
  and managed activity rows.
  Durable activity summaries are capped at 2 KiB and retained per run as at
  most 128 assistant plus 128 tool rows. Each rolling row is independently
  content-hashed and excluded from the append-only non-activity audit lineage,
  so retention cannot create an audit-chain gap. Both native clients stream
  responses through a strict 4 MiB ceiling. The existing view-owned five-second
  refresh keeps at most 100 app-local rolling rows with an 8 KiB presentation
  cap; this surface is not token streaming and does not create a second full
  conversation transcript.
- Added a verbose **Policy Feed** to Rune Forge so operators can follow the
  newest bounded violation, repeat, evidence-update, correction, reopen, and
  interpretation events without opening each violation. Policy reporting
  remains additive and does not authorize, pause, or alter development work.
- Rebalanced the Rig so CPU/GPU and Storage/Managed Activity occupy aligned,
  equalized two-column rows at normal widths, with a compact 130-point rolling
  activity region and a vertical fallback at constrained widths. MCP,
  agent/process, Manager, Autonomy, Continuity, and Rune Forge controls now use
  adaptive layouts to avoid clipping and make better use of available space.

### Changed

- Advanced the development product identity from `0.11.0 (3)` to `0.12.0 (4)`
  for the backward-compatible Managed Activity, Policy Feed, and responsive
  primary-view layout feature release. This is not a shipment claim.

## [0.11.0] — 2026-09-21 (development)

### Added

- Added a compact Rig orchestration-status cluster beside a shortened Load
  Trace. Color and load indicators now distinguish headless LM Studio Provider
  reachability, Autonomy service activity, automatic Continuity state/context
  pressure, and selected/indexed Rune Forge policy observation. The bounded
  Manager refresh runs only while Rig is visible and Rune Forge remains
  explicitly non-interfering.
- Added confirmed deletion of one settled Autonomy task. Completed, cancelled,
  and terminally failed runs can be removed from run history through an exact
  authenticated run/project/generation request; nonterminal or unsettled work
  fails closed and project files remain unchanged.
- Added a selectable native Completion Checks catalog for buildable project,
  build errors, build warnings, tests, complete instruction delivery, and
  unresolved operations. Preset identifiers compile into typed native
  obligations; they are not treated as external executable policies.
- Added per-task failure handling for pause-for-review, bounded automatic retry,
  or terminal stop, plus bounded custom failure instructions delivered to the
  managed model. Retry exhaustion pauses for review instead of looping.
- Added a Rig project-progress indicator based on durable instruction-document
  delivery and completed instruction packages, with running, queued, complete,
  and attention states.
- Completed RF-SJ-10 integrated delivery acceptance and handoff for Rune Forge
  Development Policy and Stjornarvald. All 40 issued acceptance rows now have
  current evidence or an explicit limit; 39 are accepted, while a human
  physical VoiceOver listening session remains unperformed. Full SwiftPM,
  app-hosted, native UI, canonical Xcode build, signing, membership,
  documentation, privacy, non-interference, and repository checks are retained
  without claiming release or shipment.
- Added bounded product-event integration and RF-SJ-09 non-interference
  qualification for Stjornarvald. Ordinary tool completions, managed tool
  completions, deterministic completion claims, and Manager availability now
  emit redacted post-commit observations through one capped asynchronous queue
  and a distinct owner-only restart-safe client outbox. Manager outages,
  saturation, shutdown deadlines, and observation faults remain outside
  authorization, completion, canonical tool results, and managed run outcomes.
- Added four-format Stjornarvald policy-log export. Rune Forge now presents a
  native save panel for JSON Lines, JSON snapshots, Markdown reports, and CSV;
  exports support bounded project, generation, run, session, client, date,
  rule, state, source, event, notice, and confidence filters. Files are staged,
  synchronized, atomically installed with owner-only permissions, and paired
  with durable retry-stable receipts and explicit integrity and limitation
  metadata. Cancellation and export failure do not mutate policy history.
- Added the native Rune Forge operator workflow and Guided Mode coverage.
  Operators can select any local file or folder without a content-type
  allowlist, see the source immediately while Manager confirmation is pending,
  inspect bounded source, violation, occurrence, and notice-delivery details,
  refresh or remove sources, schedule a scan, and retain cached information
  during Manager outages. The export menu now opens the RF-SJ-08 native
  four-format save workflow.
- Added the manager-owned Stjornarvald lifecycle and typed bounded API. One
  restart-safe coordinator indexes policy sources and evaluates observations,
  while authenticated mutations, read-only snapshots and violation paging,
  durable notice reservations, process-local observation outboxes, typed
  health, and explicit degraded state keep policy faults outside ordinary
  Forge bootstrap and development control.
- Added bounded, source-linked Stjornarvald notices for managed provider turns
  and ordinary MCP tool responses. Durable delivery snapshots and receipts make
  retries stable, corrections supersede stale pending guidance, and delivery
  faults leave canonical tool results, run outcomes, and authorization unchanged.
- Added the manager-owned Stjornarvald observation and evaluation core:
  bounded idempotent observations, durable fail-forward intake, an expiring
  process/boot evaluator lease and cursor, isolated detector faults,
  condition-stable violation grouping, and automatic repeat, correction, and
  reopen history that never controls development execution.
- Added the pinned Raven Forge Development rule projection: 15 native,
  source-linked rules retain exact repository revision, policy path, and heading
  provenance; deterministic precedence records material ties as explicit
  ambiguity; the initial native-stack detector reports aligned, violation,
  ambiguous, and corrected states; and optional parity-utility failure is
  durably observed without suspending the built-in policy.
- Added the native all-format Development Policy source catalog. Every selected
  file, folder, bundle, package, archive, executable, link, zero-byte file, or
  special filesystem entry receives a durable active identity before bounded,
  restart-safe interpretation; unsupported, encrypted, partial, and
  metadata-only inputs remain cataloged instead of being rejected.
- Added the native Stjornarvald contract and persistence foundation: typed
  policy/observation/violation identities, deterministic violation grouping,
  immutable SQLite events, a digest-chained recoverable JSONL mirror,
  owner-only storage, and bounded outbox/in-memory fallback that never controls
  ordinary Forge development.
- Established the pinned Raven Forge Development 0.6.2 policy binding and
  current-source realization record for the in-progress Rune Forge Development
  Policy and Stjornarvald feature. The record fixes native ownership,
  all-format source acceptance, additive violation reporting, dedicated policy
  history, and strict non-interference boundaries without claiming runtime
  implementation.
- Added manager-owned automatic completion plans bound to the exact project
  generation and immutable instruction source. Direct and queued runs now
  persist typed, reasoned obligations for available builds/tests, read-only
  reports, artifact registration, and unresolved work; instruction packages
  exclusively supply any additional completion requirements.
- Added direct Start Task selection of existing project instruction packages,
  including ordered multi-package composition that remains usable after the
  original import paths are removed.
- Added persistent contextual Guided Mode with complete offline help for all 13
  application tabs and typed guides for Start Task, task capabilities,
  completion checks, project registration/import/queue/relink/reset/clear,
  continuity actions, runtime jobs, and provider credentials.
- Added state-aware Autonomy, Continuity, Provider, and Runtimes guidance plus
  optional inline help that remains non-blocking and non-mutating.

### Changed

- Advanced the development product identity from `0.10.0 (2)` to `0.11.0 (3)`
  for the backward-compatible Rig operability and Autonomy lifecycle features.
- Preserved model-explicit starts for statically registered provider adapters
  that do not expose the saved Provider-settings surface, while ordinary
  minimal-input starts still require the manager-owned saved configuration and
  its revision fencing.
- Renamed the former mission-size limit as a compact bootstrap-summary budget;
  32,767-, 32,768-, 32,769-byte, multi-megabyte, and multi-document instruction
  sources remain artifact-backed rather than rejected or truncated.
- Made `instruction_read` page size responsive to the provider-reported
  remaining context and durable inline-result envelope while retaining 64 KiB
  only as an upper transport bound. Accepted catalog/read coverage continues
  through restart and managed rollover.
- Added stable-revision paging for large instruction queues and client-side page
  reconciliation, complementing the existing paged document catalog and
  completion-evidence history.
- Added explicit `unrepresented_visual_structural` accounting, page-mapped PDF
  text, native Vision OCR fallback for supported images and scanned PDFs, and
  distinct malformed-versus-encrypted conversion reports. Unsupported content
  remains preserved and prevents false ready state.
- Made bounded ZIP extraction observe task cancellation while retaining path,
  link/device, duplicate, compression, expansion-ratio, total-byte, deadline,
  staging-cleanup, and extracted-inventory protections.
- Replaced the Provider setup sequence with one cancellable, manager-owned
  **Connect and check** workflow shared by ordinary task preparation and the
  Provider view. It preserves explicit model pins, selects only a sole loaded
  compatible model automatically, performs the contract probe, persists a
  bounded revision-matched readiness receipt, and returns one typed recovery
  action when external work is required.
- Redesigned Provider to lead with model-connection readiness and moved endpoint,
  exact model, credential, inventory, and probe internals under **Advanced
  connection settings**.
- Added task-oriented runtime requirements with explicit required, optional, and
  not-needed reasons. Runtime availability now distinguishes available, not
  installed, disabled by the application-wide policy, unauthorized, failed
  probe, and unknown; job purpose and result precede technical identifiers.
- Corrected the runtime shell-policy label from project-scoped to
  application-wide, matching the persisted Manager setting it actually changes.
- Redesigned Continuity around automatic task protection. The primary view now
  shows the task, plain-language protection state, relative last-save time,
  working-context availability, and next automatic action; technical operation,
  budget, session, and handoff identities remain collapsed.
- Moved manual continuity requests under **Optional manual actions** and renamed
  them **Save progress now** and **Start a fresh session and continue** while
  preserving the existing typed manager commands and eligibility checks.
- Added a bounded project/run-scoped manager readiness projection covering
  monitoring, progress save, rollover, restore, continuation, provider wait,
  recovery, external-host limitation, and blocked states.
- Added bounded instruction-delivery state to managed continuity handoffs,
  including immutable artifact hashes, catalog coverage, byte cursors, compact
  completed-document coverage, the exact grant and completion plan, evidence,
  open work, and provider configuration revisions.
- Completed the managed successor lifecycle with strict fresh-root
  acknowledgement reconciliation, one accepted successor, predecessor fencing,
  automatic continuation, provider-exact tool fencing at rollover, and durable
  restart replay without duplicate successor effects.
- Replaced the built-in instruction-run perfect-history completion rule with
  outcome-aware obligation evidence. Corrected build/test passes supersede older
  failures, later regressions invalidate earlier passes, unrelated reads cannot
  satisfy repair work, and unresolved effects remain fail-closed.
- Paged durable completion evidence in 128-record keyset windows with a bounded
  65,536-record validation ceiling, removing the former 256-record task-failure
  limit without retaining an unbounded run history.
- Showed automatic obligation titles and reasons in Start Task and run detail,
  and moved signed custom completion-policy import behind collapsed
  **Advanced controls** so routine tasks require no policy package.
- Changed every quick-text task input, including short paste, to publish through
  the same immutable run-artifact pipeline as files, folders, ZIPs, and selected
  project packages before preparation or Start.
- Changed the persistent question-mark toolbar action from the generic setup
  slideshow to the current tab or active sheet guide while retaining the
  first-use setup guide as onboarding.
- Restored the Start Task mission field's stable accessibility identity by
  separating it from the file/folder/ZIP drop-target annotation.
- Refined Start Task into a compact project-and-instructions flow with plain
  summaries for the saved model, checkbox-selected tools, automatic completion
  checks, and automatic continuity. Raw provider, adapter, model-string,
  capability-ID, and completion-gate editors are no longer ordinary controls;
  an optional task label, typed saved-model picker, and network toggle live
  under **Customize**.
- Extracted the registered tool checkbox catalog into one reusable native
  permission editor and moved run/provider/session identifiers behind
  **Technical details** so active work, progress, continuity, completion, and
  recovery lead the run view.

- Simplified configured Autonomy start to Project and Instructions by applying
  manager-owned saved-model, registered-tool, completion-check, and continuity
  defaults; typed task-label, saved-model, and network choices remain available
  under **Customize**.
- Preserved selected run defaults across refresh and completed-run reset instead
  of requiring repeated raw tool and completion-gate entry.
- Unified direct and queued technical preparation in the Manager. Configured
  starts now omit unchanged provider/model/tool/gate/network fields, while
  explicit typed choices remain exact and fail closed when invalid.
- Made prepared-run revisions cover the deterministic automatic completion plan
  and persist its ID/revision in durable run metadata. Older run and preparation
  records without the new optional plan fields remain decodable.
- Added provider-configuration and canonical tool-catalog revision fencing to
  run preparation. Stale previews create no durable run and refresh automatic
  values without erasing explicit typed choices.
- Added a versioned project-bound prepared-run descriptor for direct and queued
  starts. Its revision covers the source snapshot and document references,
  provider/model configuration, exact grants, completion checks, automatic
  continuity, and project-scoped resource budget; Start revalidates it before
  durable creation and preserves exact-identity replay after a lost response.
- Added project-bound `ready`, `automatically_preparing`, `needs_choice`,
  `needs_authorization`, `waiting_dependency`, and `failed` preparation
  results with typed recovery actions. Ordinary Start now needs only Project
  and Instructions even when setup is incomplete; non-ready results submit no
  run and route recovery to the relevant native surface.
- Combined Projects registration with durable authorization of the exact
  selected canonical folder. Existing roots are preserved, parent authority is
  not widened, and legacy registration-only API requests keep their behavior.
- Replaced routine raw capability entry with a searchable registered-catalog
  editor containing native individual/category checkboxes, mixed-state **Allow
  all tools**, Select none, Restore recommended, counts, technical identifiers,
  higher-impact labels, and explicit unavailable reasons. Network authority
  remains a separate **Customize** control.
- Added owner-only saved project capability defaults with revision-checked
  updates. Explicit denials survive catalog expansion, removed or disabled tools
  are explained without being granted, Allow all follows the eligible catalog
  only for future preparations, and every run freezes its exact resolved grant.
- Replaced concatenated instruction missions with schema-2 immutable source and
  canonical-text catalogs plus bounded `instruction_catalog` and
  `instruction_read` delivery. Imports now accept content-aware UTF-8/UTF-16
  text regardless of suffix, inventory hidden files, and use native PDFKit and
  AppKit adapters for PDF, DOCX, RTF, and HTML while retaining every original.
- Raised the old 32 KiB/1 MiB/8 MiB/64-item authoring boundaries into separate
  bounded bootstrap, delivery, and import resource budgets. Opaque, malformed,
  or encrypted content remains preserved with an actionable unresolved state
  that prevents execution; legacy queue metadata migrates without losing
  package identity, ordering, or snapshots.
- Added bounded ZIP instruction import. Forge inventories the central directory,
  rejects traversal, links, encryption, unsupported compression, excessive
  expansion, and mismatched extraction results before accepting content, and
  retains nested archives without recursively expanding them.
- Unified large paste, file selection, drag/drop, and ordered-queue instruction
  admission on the immutable artifact importer. Direct artifacts are bound to
  the exact project generation and run; prepare and Start receive only a compact
  bootstrap and digest, and protected instruction reads remain run-scoped.

### Fixed

- Started the durable Autonomy watchdog when the Manager is hosted by the
  native GUI. The GUI previously recovered and reported the service started but
  omitted the watchdog that rediscovers yielded durable work.
- Hardened the loopback control plane after an adversarial pre-release audit.
  Session prune/close and visible Manager controls now require a per-server
  256-bit browser capability, while native clients retain the owner-only bearer
  path and the durable bearer never enters page content.
- Reclassified pending Stjornarvald notice reservation as an authenticated
  mutation because it durably changes delivery state.
- Removed an unbounded `lsof` wait/pipe-drain ordering hazard from dashboard
  port inspection and replaced it with the shared deadline- and output-bounded
  process runner.
- Hardened shipped Release targets against injected base entitlements and
  removed Release testability from the Core framework, with an Xcode graph
  regression covering every shipped Release target.
- Escaped dynamic dashboard status text, removed session identifiers from
  inline JavaScript, and made all non-2xx control responses visible as errors.
- Corrected integrated rollover acceptance so the sealed predecessor cannot
  issue a new tool request under rollover pressure; the acknowledged successor
  now reissues the exact pending read, records its result, and completes on the
  following provider turn.
- Updated runtime-discovery acceptance to retain an immutable configured
  executable candidate when its probe fails, reporting `probe_failed` and
  unavailable instead of erasing its path.

### Pending qualification

- Rebuild and qualify the `0.10.0 (2)` native product set.
- Complete the remaining privileged-service, notarization, Gatekeeper,
  public-download, and hardware gates recorded in the roadmap.

## [0.10.0] — 2026-09-19 (development)

### Added

- Added a visible **Remove Selected Project…** action below the Projects list.
- Added project-row context-menu removal with the same destructive confirmation.
- Added a native UI regression that registers, removes, relaunches, and confirms
  that the registration remains absent.
- Added root `VERSION` and `BUILD_NUMBER` authorities.
- Added a documented `<release>.<feature release>.<patch or hotfix>` policy.
- Added repository hygiene and version-alignment checks to local tooling and CI.
- Added a curated documentation index separating current guides from retained
  historical evidence.

### Changed

- Advanced the development product identity from `0.9.0 (1)` to `0.10.0 (2)`.
- Reworked the README into a concise product overview, setup path, project
  lifecycle, architecture map, and verification boundary.
- Reduced the changelog to user-visible changes and links to detailed evidence.
- Made the root version files drive the standalone app build script and reject
  drift from compiled or Xcode product identity.
- Kept the runtime-launch signing gate compatible with the current and legacy
  SwiftPM XCTest product identifiers without widening accepted products.
- Updated isolated build-entrypoint fixtures to exercise the root version and
  build-number authorities and reject missing or drifting values.

### Preserved behavior

- Project removal still fences the selected generation and preserves durable
  memory and historical evidence for later re-registration.
- Removal still requires an exact selected project and generation plus explicit
  operator confirmation.
- Existing project registration, relink, reset, content clearing, memory,
  continuity, and instruction-package contracts remain available.

## [0.9.0] — 2026-08-23

### Added

- Durable project-scoped memory with bounded search and migration support.
- Continuity checkpoints, handoffs, successor acknowledgement, and recovery.
- Native manager-owned autonomy, provider configuration, and runtime jobs.
- Privileged filesystem protocol and signed-helper qualification surfaces.
- Metal-backed gauges and bounded telemetry delivery.

### Changed

- Consolidated the native app, CLI, runtime launcher, Core framework, and
  filesystem daemon into one coordinated product identity.
- Expanded project generation, binding, reset, relink, and content-clear
  contracts.
- Added native completion policy and signed XCTest gate support.

### Qualification boundary

- Historical `0.9.0 (1)` build, test, signing, archive, and notarization evidence
  remains in the repository's evidence documents.
- Those receipts apply only to the exact source and artifact identities named in
  each record; they do not qualify `0.10.0 (2)`.

## [0.8.0] — 2026-08-14

### Added

- Managed runtime ownership and native host-adapter foundations.
- Project-aware filesystem, shell, memory, and continuity controls.
- Recovery-oriented diagnostics and evidence retention.

## [0.7.0] — 2026-08-01

### Added

- Native dashboard, telemetry, gauges, and manager console expansion.
- LM Studio primary and fallback MCP registration.
- Bounded process execution and audit logging improvements.

## [0.6.0] — 2026-07-31

### Added

- Durable storage, agent sessions, and continuity packet foundations.
- Native application and CLI integration.

## [0.5.3] — 2026-07

### Added

- Initial native MCP server, project tools, and LM Studio deployment path.

## Maintenance rules

- Keep one `Unreleased` section at the top.
- Record user-visible behavior, compatibility changes, migrations, and release
  boundaries; do not paste terminal transcripts into this file.
- Move detailed evidence to the roadmap or a focused document and link it here.
- Update `VERSION`, `BUILD_NUMBER`, runtime constants, Xcode settings, README,
  and active guides in the same change.
- Never rewrite a historical receipt to imply it tested a newer version.

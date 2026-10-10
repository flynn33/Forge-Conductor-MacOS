# Forge Conductor macOS — project roadmap

## Custom layouts within existing views

Current target **0.44.0 (60)** implements the owner's movable, resizable, show/hide frames and saved named layouts within each existing view. The owner defers remaining new file-format and other capability implementations and prioritizes fixing bugs and completing this UI phase.

| Milestone | Actual evidence | Remaining gate |
| --- | --- | --- |
| Source and preservation | Native workspace storage/canvas/catalog are integrated into all 13 main views, with 24 view-local namespaces. Existing default composition and page state owners remain. | Final full-view and editable draft-retention checks are in progress. |
| Native mechanisms and bugs | Preferences 18/Provider 37 and separate bootstrap eight passed; 63 distinct methods across two native selections. Canvas 10/12 passed with two later observation failures. Escape and Provider regressions passed. Rune hidden-command cancellation was reproduced, then the same native case, all 16 owning native cases and 15 source cases passed with observation-only pause. The same two native Compute viewport/shared-lease cases passed after ancestor-frame observation repaired panel-move resume (11.335 parent/3.082 test s, exit 0/unforced). The complete Compute owning native selection subsequently passed all 27 methods (29.848 parent/26.021 test s, exit 0/unforced). Unchanged Doctor v23 passed one actual method (5.307 parent/0.728 test s, zero failures/skips, normal exit 0/unforced, 3,293 inputs stable), retaining the unavailable result/heading through default/custom/restore. V25/v26 each failed both complete-draft methods (13.531/13.260 parent, 1.554/1.537 test s, normal exit 65/unforced, separate 3,293-input maps stable). Test-only outer catches retain/rethrow the original AX −25211 error; its boundary NSError domain differs from the raw terminal associated-error domain naming Gestures InvalidTransition. Cause/internal throw sequence remain unknown. V27 again failed both methods (13.420 parent/1.497 test s, normal exit 65/unforced, 3,293 inputs stable): one requested 20 ms wait and one same-parent fresh child copy retained AXIdentifier/Role −25211; the original error remains fatal. V28 again failed both methods (13.613 parent/1.547 test s, normal exit 65/unforced, 3,293 inputs stable). Both failure diagnostics record the test client’s trust state as false in PID 67015; original/boundary errors still match and held/fresh child reads remain −25211. Client context is observed; the particular-child cause remains unknown. Separate synthetic v31 passed one actual export-comparison method (7.315 parent/0.217 test s, zero failures/skips, normal exit 0/unforced, 3,293 inputs stable): AppKit/SwiftUI each export one identified AXButton with client trust false. V29 executed no method after a new report compile error; v30 failed a new direct-role assumption. Fixture-only corrections preserve the original two methods/all 23 assertions; their v28 failure and particular-child cause remain unresolved. Separate v32 ordinary-native selection failed both cases; v33 Projects failed before editing and its eight-line experiment was removed with tested source retained. Separate v34/v35 exported-identity/native-event selections each failed both cases after literal edits and partial layout retention. V35 observed the held group's AXParent CFEqual to the exact window AXZoomButton reference; error cause/native ownership remain unknown. V36/v37 each failed both cases at the new scope guard; v37 observed AXButton/AXFullScreenButton, contradicting its added Zoom-only subrole expectation. V38 passed both separate application-content cases (14.661 parent/1.841 test s, normal exit 0/unforced, 3,293 inputs stable), retaining all 23 copied inline and four initial/restored identity assertions. Manager reaches section/Save-refusal/Reload; Projects reaches all layouts with one snapshot/zero mutations/one bootstrap. Fresh original whole-window v39 again failed both methods (9.990 parent/1.465 test s, normal exit 65/unforced, same 3,293 inputs). Production, version/build and seven graph inputs are unchanged. Separate Rune exported-Save checks preserve v40 combined NONPASS and v41 mixed Rename PASS/Save As FAIL; unchanged standalone Save As v42 passed, followed by all three existing Return/Escape regressions in v43. Exact counts and limits are in the qualification record. The pending-Hide defect was reproduced in v48/v49; two unchanged methods passed after the visibility/cancellation repair in v50 (6.114 parent/0.507 test s), and v51 passed 15 related methods including those two (8.700/5.083 s), normal exit 0/unforced with 3,293 inputs stable. Rune v44–v47 remain NONPASS: v46 establishes the exact window Zoom relationship and v47 again captures no second menu root; causes remain unknown. App compilation v52, ordinary Debug v53, strict signature v54 and v7 candidate identity readback passed. V55 source G3 passed one actual method (6.647 parent/0.012 test s); hygiene/whitespace passed in 0.813/0.277 s, normal exit 0/unforced with 3,293 inputs stable.  Mixed baselines v57/v58/v60 fail 2/2/3 methods with 8/28/22 assertions. The separate rollback/pointer-anchor repair then passes all seven unchanged mixed methods in v61 (8.699 parent/0.695 selected test s) and 22 related methods in v62 (9.287/5.620 s), including those seven, zero failures/skips, normal exit 0/unforced with the same 3,293-input map. App compilation v63, ordinary Debug v64, strict signature v65 and v8 candidate readback pass. V67 exact-menu diagnostic fails one method (13.844 parent/1.131 test s); v68 passes Fresh Rename and fails Fresh Save As/combined naming (11.543/3.020 s), normal exit 65/unforced with 3,293 inputs stable. All four menus lack an exact didEnd receipt before capture stop, including the pass; this is no failure discriminator. Fatal required-Save AXIdentifier −25211 stops activation and the combined second command; original naming/UI gates stay open. V71 fails three naming methods (15.141 parent/3.098 test s); isolated Rename v72 fails (9.659/1.042 s), both normal exit 65/unforced. Isolated Save As v73 passes (13.136/1.113 s, exit 0); combined v74 fails before first Save (9.596/1.069 s, exit 65), both unforced with the same 3,293 inputs. Trust=false/event-tracking boundaries occur in PASS/FAIL, so neither alone distinguishes them. Same-held-child Role also returns −25211; cached AXGroup is the parent and the child’s role/cause remain unknown. V77 separate mounted Tools shared-controls test fails one method (18.998 parent/3.257 test s, exit 65/unforced, 3,293 inputs stable) at ordinary native Customize identifier discovery after exact default-state readback, before any button/menu action. Cause remains unknown; control absence/product defect is not established. V79/v80/v81 each fail one Tools method before Customize actions (17.381/23.864/16.933 parent and 3.247/3.251/3.225 test s, normal exit 65/unforced, 3,293 inputs stable). Latest trees have 3/3/2 nil-ID nodes; later paired bridge reads and v81 fixture-root styling establish no cause or product repair. Separate attached-sheet v82 fails one method overall (13.489 parent/1.168 test s, exit 65/unforced): Rename completes actual menu/editor, six-node fresh Save AXPress 0 and identity/collection/restoration guards; the second unchanged whole-window opener fails AXIdentifier −25211 before Save As. Original gates remain open. V84/v85 and unchanged pre-admission v86 each fail one separate exported Tools method before menu actions (14.116/14.093/8.921 parent and 0.225/0.230/0.232 test s, normal exit 65/unforced, 3,293 inputs stable). V85 identifies the exact enabled Panels AXMenuButton rejected by the new test-only role guard. Actual corrected-helper v87 remains NONPASS (17.429/3.396 s): Customize and first Panels Hide pass complete collection/sorted-byte/fresh-owner and retained-host checks; the second Panels attempt times out after 149 ticks before Show readback. Fresh original ordinary v88 remains NONPASS (11.774/3.211 s, normal exit 65/unforced): Customize lookup ends at 131 attempts/two nil-ID nodes after exact default readback, before actions. No product repair or enclosing menu-loop unwind is established. V90 first-menu observation remains NONPASS (19.622 parent/3.367 test s, normal exit 65/unforced): the second opener precedes the exact first-menu end while before/after owner snapshots remain valid. After an exported-only per-capture exact-end gate within the original 3 s/45 s deadlines, v91 and unchanged v92 each pass the same complete Tools method (11.694/2.621 and 6.280/2.605 s, normal exit 0/unforced), with eight native menu-end/removal receipts and eleven collection/bytes/fresh-owner stages. This is a test-driver timing change, not production repair or enclosing-loop-unwind proof.  V94 synthetic comparison passes one method (9.592 parent/0.145 test s); AppKit ordinary/exported matches are 1/1 and plain SwiftUI 0/1. Projects v98 passes native queued move 20×20/resize 40×30 (10.184/0.662 s), retaining the draft/live hosts, fresh preferences and Feed with zero backend writes. Rune v95/v96 remain one failed method each; v96’s exact first-menu end does not prevent the second fatal lookup. V97 restores pre-experiment Rune bytes and retains evidence. These scoped test results do not close original naming/ordinary/full UI gates or deferred implementations.  V100 test compilation fails before execution at six private-conversion references; local equivalent conversion changes only the new helper. V101 passes one method/21 representative namespaces/126 queued events (13.644 parent/6.763 test s), move20×20/resize40×30 and full saved-state/host guards. API preparation does not qualify menu actions, all panels/24 namespaces, healthy/live/desktop/installed/lifetime/full UI; original naming/ordinary gates and deferrals remain. | The controlled exported Tools complete-control flow passes in v91/v92; original ordinary discovery (v88), Rune combined naming and all-view/full UI gates remain open. Final checkpoint checks and exact delivery are tracked in external receipts. Unchanged Manager/Projects complete-draft v24 failed both methods; complete draft retention, healthy/live Doctor reports and full-view semantic checks remain open. V25–v28 also remain NONPASS. Original whole-window and ordinary-native flows remain NONPASS; v38 qualifies only the explicit application-content route. Unexercised layout-menu actions, backend Save success, desktop/installed/full UI and lifetime gates remain open. Separate exported Rename/standalone Save As successes do not close the original ordinary-native Save or Rune repeated-menu gates. [Current bounds](docs/QUALIFICATION-STATUS.md). Post-repair source/document checks passed on the admitted v2 inputs; exact source/wiki delivery is tracked separately in external receipts. This UI phase stays open.  Final mixed-checkpoint source/document checks follow admission; exact source/wiki delivery stays in external receipts. Qwen is advisory; broad UI gates remain open. |
| Layout naming and reopen | A held A Rename sheet reproduced renaming newly selected B. The origin/request identity guard then passed the scoped v17 native selection on its recorded inputs: 23 actual methods, zero failures/skips, 17.084 parent/4.810 test s, normal exit 0/unforced. These comprise preferences 18, separate normal Rename/Save As, stale same-view selection, source-refresh Return and native move/resize/Hide fresh-owner restoration. Separate v20 queued native move/resize passed one actual case (7.329 parent/0.246 test s, normal exit 0/unforced, 3,293 inputs stable), retaining the same hosts and persisting completed geometry. Separate v22 passed one queued-Escape cancellation method (13.273 parent/1.211 test s, normal exit 0/unforced, 3,293 inputs stable): the exact held sheet dismissed after source removal, with full saved collection/bytes unchanged and overview panels retained. | V18 failed all three original draft/native Save cases; v21 again failed native Save. Root/parent-edge and nil default-button measurements identify no cause. Original combined naming, exported-AX and native Save-button routes remain NONPASS. Complete UI/draft/desktop checks remain open. |
| Full application | Earlier UI automation, strict identifier and physical presentation attempts remain NONPASS. Later one-method Manager runs each passed 36 caches; the 13-page physical fixture passed 104 PNG/104 JSON captures at normal/minimum sizes after a fixture-only full-size frame correction. Caches are diagnostic-only, with cancelled bootstrap and empty semantics. A separate owned-window two-ID public AX probe passed. The later own-window Page selection remained NONPASS: eight executed, three passed and five failed at presentation/observation boundaries. Separate minimum-size native scroll geometry passed all 396 control centers across 22 fixtures; full-page semantic parity is still unresolved. | Complete interactions, editable drafts, Doctor results and ordinary desktop routing/compositor remain open. Initial custom viewport clipping remains a review limit; the separate native control-center scroll check does not exercise panel-body actions or wheel input. No system-notification contents or cause are inferred. |
| Documents and delivery | The post-naming v6 ordinary Debug build/strict signature passed in 25.602/0.270 s; seven-artifact/Info 0.44.0 (60) and 320 selected product/build-input/membership readback passed in 0.385 s, all normal exit 0/unforced with 3,293 inputs stable. Earlier candidate and document receipts are retained below. Source checkpoint publication and clean synchronization passed before the separate v22 test. Evidence stays in Codex Working Folders. | Candidate launch/desktop and complete UI qualification remain open; this UI phase is not complete. Final affected check, document readback and exact owner source/wiki delivery outcomes are retained in external receipts. |

[Workspace guide](docs/NATIVE-WORKSPACES.md). This UI phase remains open until its required checks and delivery are complete. Earlier feature receipts retain their tested scope.

### Earlier UI checkpoints before the naming repair

The original failures below remain retained at their recorded inputs; the latest scoped naming result is in the table above.

Earlier documents/candidate checkpoint: Current results, user instructions, architecture, telemetry, compatibility and deferral are documented. The pre-Rune candidate readback remains a separate preceding result. The updated ordinary Debug build and strict signature passed in 25.226/0.272 s; its seven-artifact/Info and 320 product/build-input readback passed. Separate G3 one-method checks passed on source/native routes, and hygiene passed. New evidence uses Codex Working Folders; the old external directory was removed by cleanup.

Later checkpoints: CLI/app product links passed after the Rune correction. Read-only semantics completed 15 normal-size phases before an AX API-disabled failure; two collector/geometry controls passed in the same three-method selection. Both editable draft cases remain NONPASS, with a normally terminated v6 run preserving all assertions after the preceding stalled XCTest interruption. Projects' native backing field matches the exported field exactly, but editor-to-binding propagation is not yet qualified. The isolated ordinary candidate's Dashboard opened; computer-use communication then closed, leaving Projects navigation and complete desktop interaction unverified. The installed 0.18.0 (28) app remains separate and unchanged.

Subsequent Page v4 observation completed 19 normal-size phases before Feed restoration and a fresh diagnostic scope both failed AXRole API-disabled; no partial snapshot supplied assertions. Projects v9/v10 used real AppKit editor input and retained the draft through custom layout and hide/show, but later AXIdentifier API-disabled left the complete case NONPASS with the actual field still containing the draft and creation/snapshot counts one, writes/mutations zero. Draft loss is not established. Compute's v2 movement-resume failure and earlier scroll failure remain retained; v3 passed the same two focused cases. This scoped repair does not close the full UI, semantic/draft or delivery gates.

The post-Compute v5 candidate passed ordinary Debug/strict signature in 25.960/0.307 s, seven-artifact/Info and 320 selected product/build-input readback, and separate CLI/app compilation in 1.247/4.889 s; all terminal receipts are normal exit 0/unforced. Exact-path computer use observed Dashboard 0.44.0, 13 tabs and 86 tools, then Projects click/getAX/screenshot communication closed. Navigation outcome and cause remain unknown. Owned candidate PID 25818 was stopped with SIGTERM and confirmed absent; installed 0.18.0 (28), PID 16472, was unchanged at cleanup. This is no ordinary GUI-quit or installed-product qualification.

Projects v11/v12 each remained NONPASS with the native draft retained in their reports. V11 retained the later AXIdentifier API-disabled error; v12 still reported framework InvalidTransition without an original later error. The v13 four-method diagnostic selection retained original AXValue API-disabled errors for Manager's Authorized Folders title lookup and Projects' canonical-root lookup, while its two Page collector/geometry controls passed. The subsequent whole Canvas v14 selection executed 13 methods, 11 passed/two draft failures in 16.789 parent/5.332 test s, normal exit 65/unforced with 3,293 inputs stable. Identifier-specific observation still failed AXIdentifier and same-node ID/role with API-disabled; extra unrelated AXValue reads did not explain the failure. Complete draft retention and the cause remain open. Rune naming v1 was forcibly bounded before a terminal test result; v2/v3 failed normally before Rename/sheet/Save, with the original shown-menu relationship unqualified. No production naming fix or namespace-mutation claim follows; the source risk remains open.

The v15 wrong-selector invocation executed zero methods despite exit 0 and is NONPASS. Corrected v16 executed both actual draft methods; both failed normally in 10.036 parent/1.538 test s, exit 65/unforced with 3,293 inputs stable. Both identifier walks stopped at an unnamed non-window descendant (visit 5/depth 3), before the requested target or a named ancestor was observed. Projects still retained its native draft with one bootstrap/snapshot and zero writes/mutations; the denied element and cause remain unknown.

Rune advertised-focus v5 reached the 100.227 s outer deadline, forced exit -15, with the method started but no completed method or attachment. Its own-process sample shows the nested native menu-tracking loop; focus and naming behavior remain unqualified. A fresh isolated candidate from the same v5 ordinary build showed Dashboard 0.44.0, then Projects click/getAX communication closed. Verified candidate PID 29810 was SIGTERM-cleaned and confirmed absent, with installed PID 16472 unchanged; no ordinary GUI-quit or full desktop pass follows.

Before this documentation addition, separate source/native G3 checks each passed one actual method (12.168/2.262 parent s, 0.012 test s each), and hygiene passed in 0.772 s; all exited 0 normally/unforced with 3,293 inputs stable. The selected Qwen HTTP response supplied three explicitly Proposed workspace edge tests with no tool calls; it supplies no live Forge qualification. Final affected UI checks, document readback and exact owner source/wiki delivery remain open.

The separate native-menu naming method v6 failed compilation with zero methods executed. After mechanical Swift API corrections, v7/v8 each executed and failed one method normally (15.161/14.636 parent s, 4.091/4.101 test s, exit 65/unforced, 3,293 inputs stable). Both captured one actual six-item menu with the fixture's exact UUID layout entry, dispatched native Rename and presented its production sheet. Complete native Save-identifier discovery expired before controlled source refresh or submission. The later advertised same-object identifier read did not resolve the lookup. Namespace-change behavior remains unqualified; no production naming fix follows.

The separate native Return v9 method executed once and failed normally in 14.833 parent/4.029 test s, exit 65/unforced with 3,293 inputs stable. Actual native Rename again presented its production sheet. Complete owned physical name-field discovery stopped at its deadline/depth guard before controlled source refresh or Return; retained actualSubmit attempted/returned/dismissed flags are all false. The saved-layout collections remained equal. No keyboard submission, native Save-button, namespace isolation or product naming cause was established. The exact previous methods and assertions remain present; all naming gates stay open.

## Preceding 0.43.0 (59) qualification

## Supplied PCM16 AAC-LC M4A format extension

Current target **0.43.0 (59)** extends existing audio_write with exact optional m4a and matching .m4a; omission remains WAV. This row records work, not dispatch. Product source and the scoped source/native/build/App/CLI/Qwen/consumer/documentation/delivery gates passed; this AAC phase is complete.

| Milestone | Actual evidence or preparation | Remaining gate |
| --- | --- | --- |
| Source and preservation | Applied native owned-worker integration and explicit format/path contract. Matching source/native 139 passed in 76.318/108.450 s on the same 475 inputs, zero failures/skips; WAV/FLAC, grant/context/replay and 85-neighbor source preservation are included. Warnings retained. | Durable broker replay and shared late-cancel/revocation-before-rename runtime reachability remain separate. |
| Native candidate and protocol | Signed current-self worker and measured valid-frame accounting are implemented in source. CLI/app builds (1.013/1.006 s), ordinary Debug (24.067 s) and strict signature (0.134 s) passed, normal exit 0/unforced. C1 readback passed with seven artifacts/Info, 475 inputs and 80 preceding guards exact. Six App/CLI rate cohorts passed 24 real M4A files, 112 pages/364 responses, four explicit EOF reads per cohort and observed-child cancellation/destination preservation. All 24 files passed separate native valid-frame/true+extra EOF decode (12,583,488 bytes). | Failed/unresolved native-owner reachability, general shutdown and quality/lossless/installed claims remain unqualified. |
| Qwen | V3 passed six actual Low turns, five native results consumed later, three contiguous pages plus empty EOF, whole 57,482-byte M4A readback and exact four-scalar ACK. The sole model-created file separately passed native decoding to 16 valid frames/32 PCM bytes, true plus extra EOF and known success-owner closure. V2 test-only 32,768-byte artifact-cap NONPASS retained. | Selected qwen/qwen3.8-27b API flow only; no understanding, listening-quality/all-model/GUI/installed claim. |
| Documents and delivery | Initial source/native G3 each passed one method in 2.279/2.855 s; the 139 owning methods plus a separate G3 give a 140-method union per route. Hygiene passed in 0.671 s. First owner 35-path source publication/readback/synchronization passed at ba5a4ad1e78988efe19a922a5b0297676ac2eca6; the graph and 475 compiled inputs unchanged. | Final source G3 (one method, 1.332 s), hygiene (0.656 s), wiki local targets (688) and owner source/wiki publication/readback/synchronization PASS, both clean 0:0. Scoped AAC phase complete; broader gates remain open and .42 histories remain separate. |

[Audio contract](docs/NATIVE-AUDIO-WRITING.md). Raw ADTS .aac, remaining formats, full web/all models, installed operation, general lifetime, Release and shipment remain unqualified.

<a id="complete-rendered-snapshot-paging"></a>

## Preceding 0.42.0 (58) complete rendered-snapshot paging

Current target **0.42.0 (58)** adds opt-in paging to existing web.render; this row records work, not dispatch. The bounded App/CLI/Qwen paging gates passed; the scoped paging phase closed with first owner source/wiki publication, exact readback and clean synchronization; broader qualification remains separate.

| Milestone | Actual evidence | Remaining gate |
| --- | --- | --- |
| Baseline | Retained App/CLI each returned 4,096/6,144 single-node and 8,192/35,371 multi-node UTF-8 bytes at a 65,536-byte inline budget. Four truthful truncated results collected normally; whole reconstruction remained NONPASS. | Baseline retained; new native complete-paging results are separate. |
| Source and preservation | Six protocol plus ten paging additions are included in 150 distinct methods. Matching .42/58 source/native 150 passed in 43.375/71.458 s; separate initial G3 one each passed in 1.391/2.753 s. Default v1 framing/prefix and existing owners remain. | Applied-v2 final G3 one each passed in 5.658/5.560 s; hygiene passed. No general lifetime claim. |
| Contract and native runtime | One Data body ≤1 MiB/65,536 nodes, one expiry owner/120-second lifetime. Signed App/CLI functional v1 and limits v2 passed whole reconstruction, explicit EOF, final budgets and scoped refusals. Limits v2: 241 pages/246 responses each, 6.070/6.638 s. Original App limits v1 continuity-200 NONPASS retained. | Full web/every page, GUI/installed and general lifetime remain unqualified. |
| Qwen | V6 passed six completed responses, five native results consumed in later turns/both empty EOFs, whole 6,144/35,371-byte reconstruction, four-scalar ACK and six strict actual Low LF associations; owned outer closure was normal in 143.233 s. V2–v5 NONPASS attempts remain retained; v5 outer closure and prior CLI pipe-loss cause remain unknown. | Selected loopback/model flow only; full web/all models/GUI/installed remain unqualified. |
| Identity/documents/delivery | Final .42/58 signed Debug candidate v3 readback retained seven artifacts/Info, 73 historical identities and the 473-input `180a2c83…` map without rebuilding; graph/signing membership unchanged. Applied-v2 final G3/hygiene and 668 local link targets passed; preceding histories remain exact. | First owner source/wiki publication, exact readback and clean synchronization passed; broader gates remain separate. |

[Renderer contract](docs/NATIVE-WEB-RENDERING.md). Remaining formats, Release and shipment remain separate.

## Preceding 0.41.0 (57) qualification

## Supplied PCM16 FLAC format extension

Current target **0.41.0 (57)** extends existing audio_write; this row records work, not dispatch.

| Milestone | Actual evidence or preparation | Remaining gate |
| --- | --- | --- |
| Standalone mechanism | Boundary and six 1 MiB rate/channel streams passed independent CRC/MD5/whole PCM/EOF and Apple whole PCM consumers; the separate 42 controls measured named test-hook cancellation/refusal and four test-owned releases. | Separate from integrated product and general lifetime/late-publication cancellation. |
| Source and preservation | The pre-version 0.40/56 area passed 59 distinct methods in 35.339 s (8 FLAC, 9 WAV, 38 catalog, 4 broker), normal exit 0/unforced/zero failures or skips on 473 unchanged inputs. Earlier focused 8 is a subset. Eleven new methods are included; complete default/explicit WAV and 85 neighbors are preserved. Matching .41/57 canonical native 59 passed in 69.268 s; CLI/app compilation 5.646/2.323 s and ordinary Debug/signature 25.586/0.136 s passed on current 473 inputs. The selected-identity source rerun passed the identical 59 methods in 40.694 s. | Scoped source/native preservation and first owner delivery passed. |
| Product wire/model/native PCM | App/CLI each passed 40 responses/38 tool frames, eight binary pages, 18 refusals, immediate cancel and complete WAV parity in 1.800/1.292 s. Qwen passed three observed Low responses/two consumed results/9 native responses/7 frames/exact four-scalar ACK in 41.703 s. Apple afconvert decoded all three actual App/CLI/Qwen FLAC outputs to whole supplied PCM/RIFF/EOF, normal exit 0/unforced. | Scoped wire/model/native PCM and first owner delivery passed. |
| Identity/documents/delivery | Root selected .41.0/57 under compatible-feature policy; two writer/test memberships are separate from authority updates. Full .40/.39 histories remain. Separate source/native G3 passed one actual method each, giving 60-method unions with the prior 59; initial hygiene/whitespace passed. Final C2 reread the same seven C1 artifacts, 473 source inputs and 66 prior/protected identities without a rebuild. | First owner source/wiki publication, exact readback and clean synchronization passed; later prose-publication identities remain external. |

[Audio contract](docs/NATIVE-AUDIO-WRITING.md). Installed, playback, general lifetime/interoperability, other codecs, full web/all models, Release and shipment remain separate.

## Preceding 0.40.0 (56) qualification

## Supplied-entry TAR/GZIP formats

Current target **0.40.0 (56)** extends existing archive_write; this affected row records work, not dispatch.

| Milestone | Actual evidence | Remaining gate |
| --- | --- | --- |
| Contract/source | Default ZIP byte contract retained; optional exact tar/tar.gz, virtual names/base64 and writer/broker/grant bounds. Source 11 owning + 14 preservation = 25 distinct methods across eight invocations before identity advance; matching current 25 native methods and ordinary Debug/signature passed. Compile correction/NONPASS retained. | Product in-work/late-rename cancellation remains separate. |
| Product wire/model | App and CLI each 32 responses/30 frames/seven pages/five full EOF readbacks/ten refusals plus immediate cancellation and 22-byte ZIP parity. Qwen each TAR/tar.gz nine native responses/seven frames/three observed Low inputs/two consumed results/four-scalar ACK after whole EOF. Catalog 86/other 85 exact; source 471/candidate 7/prior 59 unchanged. | No installed/GUI/all-model claim. |
| Product BSD | Fifteen normal-zero/unforced stdout-only commands: six logical listings, six exact whole 256-byte payloads and three gzip integrity checks, both EOFs and owned-group absence. Source 471/current 7/prior 59 and packet/native/interpreter guards unchanged. | All six raw listings are NFD against archive NFC; cause unknown, no filesystem extraction/physical spelling claim. |
| Mechanism/container/BSD | Six recipes/twelve files/31 mechanism controls, independent ten-positive/45-negative/full-twelve gate and thirty normal BSD stdout commands passed. | Raw NFD mixed listings/cause unknown retained; no physical extraction/spelling/general compatibility claim. |
| Identity/documents | Root selected .40.0/56; current docs retain full .39/history. G3 source/native one actual method each passed in 7.174/14.946 s, giving 26 distinct methods per route with the prior 25; initial native zero-selection remains NONPASS. Hygiene/whitespace passed in 0.668/0.140 s. Only two G3 assertions differ from C1; all other 470 inputs and seven binaries remain exact. | Final C2 reread the same C1 binaries without rebuilding and passed; initial owner source/wiki publication, readback and clean synchronization passed; exact revisions are retained in the external delivery receipt. |
| Whole goal | Prior Projects and one .39 LM Studio GUI public-page proof retain their exact scopes. | Product in-work/late-rename, installed/all-model/host-adapter/general-lifetime/Release/shipment remain separate. |

[Archive contract](docs/NATIVE-ARCHIVE-WRITING.md).

## Preceding 0.39.0 (55) qualification

## Supplied PCM16 WAV writing

Current target **0.39.0 (55)** adds `audio_write`; its scoped source/wiki delivery is complete, while broader completion gates remain open.

| Milestone | Observed evidence | Remaining gate |
| --- | --- | --- |
| Baseline and contract | Original absent-definition one-method NONPASS remains. Source 48 owning and 24 separate preservation methods passed in 31.228/13.654 s; matching 72 canonical native methods passed in 67.506 s, normal exit 0/unforced, on the same 468 inputs. | Full-suite, general lifetime and other format gates remain separate. |
| Membership and identity | Canonical native tests/build exercised both memberships. Actual .39/55 Swift CLI/app passed in 1.106/1.276 s; separate ordinary Debug/strict signature passed in 24.825/0.139 s. Candidate seven and historical 52 guards stayed exact. | Installed/Release/shipment gates are separate. |
| Product transport and consumers | App/CLI passed in 1.558/1.098 s, each 33 responses/31 complete frames/three WAVs, 11 refusals, own-grant/read-only denial and immediate cancellation with target preservation; all 85 prior descriptors and ZIP/PNG/Docs parity stayed exact. Qwen passed three observed Low turns/two consumed results/strict six-field ACK in 38.544 s (9 responses/7 frames). Seven small App/CLI/Qwen WAVs passed exact whole-header/PCM checks, AudioFile (7 Close/84 properties) and ExtAudioFile (7 Dispose/whole PCM/zero-frame EOF) in 0.260 s; 14 wrappers released. | Playback, large product native consumption and in-work/late-rename cancellation remain unqualified. |
| Documents and delivery | Current contract is [native audio writing](docs/NATIVE-AUDIO-WRITING.md); previous phase bodies are retained. Initial G3 passed one source/native method in 1.650/2.712 s, giving equal 73-method unions (48+24+1 source; 72+1 native). Hygiene/whitespace passed in 0.667/0.140 s on unchanged 468 source/graph inputs. | Final prose hygiene/whitespace passed; the original .39 source/wiki publication and clean synchronization completed at `2d12624a…` / `9e19f999…`, recorded in [qualification](docs/QUALIFICATION-STATUS.md). |
| LM Studio GUI public web | LM Studio 0.4.25+1 and Qwen used the signed .39/55 candidate for six correlated calls across three assistant turns/eight EOS generations, with 86 unchanged tool schemas. Search/fetch and two renders supplied a newly consumed URLSession body fact. Original MCP bytes/entries/permissions and original chat were restored; 468 source inputs and 59 guards stayed exact. [Scope](docs/PROJECT-WEB-QWEN.md#qwen-in-lm-studio-gui-public-page-workflow). | One isolated public-page workflow only; installed/all-model/authenticated-browser/Forge Tools GUI/Release/shipment gates remain separate. Both snapshots were truncated; normal child exit codes/cause are unknown. |
| Prior Projects user acceptance | .38/54 typed candidate flow passed six semantic phases/five durable checkpoints/two ordinary exit-0 lifetimes in 11.452 s, including canonical Save/reopen, rejection without mutation and Clear. | Pixels/browser/Tools/installed GUI/full-web/all-model/lifetime/shipment gates stay separate. Earlier driver NONPASSs remain retained. |

## Preceding 0.38.0 (54) qualification

## Supplied-entry stored ZIP writing

Current target **0.38.0 (54)** adds `archive_write`. Scoped tests, candidate, archive transports and App native extraction passed; broader GUI/install/web/shipment gates remain open.

| Milestone | Observed evidence | Remaining gate |
| --- | --- | --- |
| Baseline/contract | One missing-registration failure; bounded Swift stored ZIP with virtual names/base64. | No compression, source-file traversal or extraction feature. |
| Source/native/graph | Matching 62 owning methods plus separate initial G3 one each give 63 distinct methods per route; native selection 62.594 s, G3 7.367/2.603 s; no failures/skips. Writer/Core and tests/ForgeConductorTests memberships compiled. | Focused area; full-suite/general lifetime remain open. |
| Authorities/candidate | .38/54 aligned; ordinary build 24.455 s, strict signature 0.140 s; CLI/app compilation 6.188/2.194 s. | Separate from installation/shipment. |
| App/CLI/Qwen | Signed App/CLI 2.820/2.856 s each passed 25 responses/23 frames/four ZIPs, six refusals and one immediate cancellation; PNG default/84 prior definitions preserved. Qwen 51.538 s: three observed Low turns/two consumed results/strict metadata ACK, six responses/four frames. | No installed-chat/member-understanding/full-web/all-model claim; in-work/late-cancel boundaries remain open. |
| Container/consumers | Product local ZIP container/CRC/payload verification passed. Separate App BSDtar four actual ZIPs passed 36 files/1,048,999 exact payload bytes; mechanism evidence stays separate. | Original ditto/BSDtar failures retained; no CLI/Qwen extraction, physical spelling/general ZIP/Windows/installation guarantee. |
| Documents/delivery | Thirteen current guides/contract retain history; initial G3 one each and hygiene 0.670 s passed. | Final document checks and exact source/wiki delivery are recorded separately; they add no runtime coverage. |
| Original user acceptance | Prior .37 flow NONPASS retained. Later .38 sheet Cancel observed; immediate post-Cancel count−25204 retained whole NONPASS despite ordinary exit 0/no force. Separate v2 sheet diagnostic 5.669 s passed settled copies/final absence and ordinary cleanup while retaining immediate copy−25204; no Register/Save. Later v3 registered one isolated folder with matching ID/root and generation 1; Save then reached the 8,192 AX call cap after one field set/press. The 303-byte metadata stayed byte-exact without a repository URL; ordinary exit 0/no force and unchanged guards/preferences do not qualify Save. | Projects GitHub save/reopen/reject/clear/Tools, full web/all models, rollover, lifetime, Release/shipment remain open; cause unknown. |

[Archive contract](docs/NATIVE-ARCHIVE-WRITING.md). Complete preceding phases follow.

## Preceding 0.37.0 (53) qualification

## Additive standard-size ICO pixel writing

Current target **0.37.0 (53)** adds ICO to the existing supplied-pixel tool while preserving all six preceding formats.

| Milestone | Observed evidence | Remaining gate |
| --- | --- | --- |
| Baseline and local contract | One source/native missing-feature method failed in 6.822/43.672 s, normal 1/65/unforced, before production edits; both remain NONPASS. The new Swift DIB/AND branch accepts square 16/32/48/256 and preserves exact encoded alpha/hidden RGB. | No generalized dimension/length cause, embedded ICC or Windows interoperability claim. |
| Source/native parity | Matching full raster 56 passed in 13.550/24.569 s, preserving all 48 old methods byte-for-byte. Five separate schema/wire neighbors passed in 2.201/2.504 s, giving 61 distinct methods per route on the same 464-input 3d6f16dd… map. Focused source 8 passed in 13.931 s and adds no distinct methods. | Focused area qualification only; no full-suite or leak-freedom result. |
| Authorities and candidate | Existing memberships/workspace/signing preserved; only root-selected version/build authorities advance. CLI/app 0.890/0.902 s, ordinary Debug 1.953 s, strict signature 0.135 s and native CLI version 0.614 s passed, normal 0/unforced. Candidate 78bfcd19… binds seven artifacts/actual .37.0/53. | Signed Debug/CLI proof remains separate from installation and shipment. |
| App/CLI/Qwen and native consumers | App/CLI passed in 0.893/0.822 s, each 23 groups/46 responses/44 frames/11 artifacts with 17 negatives and two immediate cancellations. Actual Qwen passed in 96.856 s: three observed Low completions/two intact consumed results. Seven ICO/PNG pairs/14 native decodes matched profiles, supplied alpha and premultiplied renders; 14 provider release/deinit/weak witnesses passed. | Metadata acknowledgement does not prove image understanding; in-work/late-cancel reachability, general lifecycle/Windows acceptance remain unexercised. |
| Preserved candidate and fresh App | Source/native G3 one each passed in 1.423/2.276 s, followed by hygiene/whitespace 0.664/0.139 s. That test action re-signed the prior main; ordinary rebuilding produced current main 97014c73… and separately preserved candidate f477a0b0… . Fresh App 0.849 s passed the same 23 groups/46 responses/44 frames; all 11 artifacts are byte-identical to original App outputs. The other six compiled artifacts stayed exact. | Original signing/guard event remains retained; prior CLI/Qwen/native consumers are reused only on exact unchanged inputs, with no new model/consumer invocation. Separate final document recheck and publication outcomes remain external. |
| Documents and delivery | Thirteen current document surfaces explain ICO and retain complete preceding histories, including unchanged web response budgets. | Actual final G3/hygiene/whitespace and exact owner source/wiki publication/readback/synchronization outcomes are retained in external root receipts; no future identity or pass is guessed. |
| Original user-facing acceptance | Existing GitHub linkage and web contracts are retained. Preceding native GUI Doctor/Dashboard observations remain scoped; no Projects mutation or Save/reopen acceptance occurred. | CUA native-pipe blocker retains Projects Save/reopen/stable linked identity and filtered Tools web-row gates open; installed/full-web/all-model/managed-adapter/other-format/Release/shipment remain open. |

[ICO contract and exact current scope](docs/NATIVE-IMAGE-WRITING.md). Complete preceding phases follow unchanged.

## Decoded UTF-8 web continuation correction

Current target **0.36.3 (52)** corrects `web.fetch` cursors for decoded text,
retaining 1 MiB receive/base64 bounds and allowing at most 3 MiB UTF-8 content.

| Milestone | Observed evidence | Remaining gate |
| --- | --- | --- |
| Baseline and correction | One Latin1 method failed in source/native in 7.152/14.688 s, normal exits 1/65/unforced: an advertised 1,049,794 cursor exceeded the old 1,048,576 validation limit. Source now validates cursors by format and checks decoded content at 3 MiB. | Both original baselines remain NONPASS; no new decoder or tool is added. |
| Contract and parity | Three new source methods passed in 14.031 s. Matching full-class source/native 28 passed in 13.866/24.896 s, zero failures/skips, normal 0/unforced, on the same 464-input 768064e9… maps; all 25 previous methods remain unchanged. Latin1 selected suffix reaches EOF; Windows-1252/UTF-16 use crossing windows plus tail/EOF controls. Four separate source/native neighbors passed in 2.185/2.507 s, giving 32 distinct methods per route. | Three focused cases add no distinct coverage; Windows/UTF-16 complete-body unions are not claimed. |
| Authorities and candidate | Existing memberships/workspace/signing are preserved; only existing version/build authorities, twelve marketing/sixteen build values and two G3 literals advance. CLI/app passed in 0.991/0.903 s; ordinary Debug/strict signature passed in 24.888/0.130 s and native CLI version in 0.514 s, normal 0/unforced. Candidate f0800991… binds seven artifacts/actual .36.3/52 on the same 464 map; reference 49b64d97… binds 38 guards. | Scoped consumer outcomes follow; GUI remains blocked, with no installed or Release result. |
| Native/model and GUI | Signed App/CLI passed in 5.246/4.821 s: each 13 responses/11 frames, four controlled GETs, exact selected 8,208-byte suffix/EOF, and three actual public search/fetch/render results. Qwen consumed three complete results over four observed Low turns in 75.012 s; native/model/observer ended normally with full EOF, but the original fenced-JSON final response made the overall attempt NONPASS. A separate 20.616 s raw-JSON correction acknowledged five actual metadata fields and two root-grounded facts using the consumed partial render; no native/web replay or additional observed Low template. | GUI v3/v4 remain NONPASS after a whole deadline and CUA native-pipe failure, with no project mutation observed. V4 Doctor showed .36.3/52 and the owned isolated home; Dashboard showed catalog84, not filtered Tools web rows. Projects GitHub Save/reopen/stable linked identity and web GUI gates remain blocked. Original web v1/v2/v3 NONPASSs remain retained; full web/all-model/installed acceptance is open. |
| Documents and delivery | Initial G3 source/native passed exactly one method each in 2.743/2.639 s on the same source map; 32-plus-one unions give 33 distinct methods per route, not one 33-test invocation. Thirteen current documents retain complete historical bodies. | Final G3/hygiene/whitespace results are recorded in external root receipts; exact source/wiki publication/readback/synchronization identities remain external. Repeated G3 adds no distinct coverage. Installed/full-web/all-model/managed-adapter/other-format/Release/shipment gates stay open. |

[Web contract and exact coverage](docs/WEB-RESPONSE-BUDGET.md).
The preceding status-build correction and complete prior evidence follow.

## Status build identity correction

Current target **0.36.2 (51)** adds missing string build identity beside version
in fresh successful status responses; historical completed replay is preserved.

| Milestone | Observed evidence | Remaining gate |
| --- | --- | --- |
| Baseline and local correction | One source method failed with four missing-build assertions in 7.590 s, normal exit 1/unforced. One shared payload field now uses the existing compiled build authority for both aliases. | Original baseline remains NONPASS. External strict-output consumers are unverified. |
| Contract and parity | Matching six source/canonical native methods passed in 13.976/38.620 s, zero failures/skips, normal exit 0/unforced, on unchanged 464-input 08250288… maps. Both direct/MCP aliases, resumed bootstrap, text/structured parity, canonical catalog and unchanged historical completed replay are covered. All old Core/Autonomy bodies remain byte-identical. | Focused status scope only; no full-suite result. Native DVTAssertions warning is retained. |
| Authorities, builds and delivery | Existing memberships/workspace/signing remain; patch identity advances five existing authority/G3 paths, twelve marketing/sixteen build settings and two G3 literals. CLI/app compilation passed in 0.986/0.862 s; ordinary Debug/strict signature in 24.908/0.133 s and native CLI version in 0.626 s, normal exit 0/unforced. The .36.2/51 seven-artifact candidate binds the same 464 map. | Exact final document and source/wiki publication/readback/synchronization identities belong in external closeout receipts. Installed GUI/full web/all models/managed-adapter/other formats/Release/shipment remain open. |
| Status protocol and model | Signed App/CLI v5 passed in 0.654/0.634 s; each produced four correlated responses/two tool frames, exact string 0.36.2/51 aliases, unchanged complete config and the exact 84-definition native catalog. Qwen qwen/qwen3.8-27b passed in 18.467 s: three actual Low responses, two selected status results fully written/correlated/verified/delivered/consumed, and a strict two-string version/build ACK. All native/outer exits were normal 0/unforced with complete EOF; source464 and 31 root guards matched. | Qwen was supplied only the two status definitions; native catalog parity is separate. Metadata consumption is not full web/all-model/GUI acceptance. Original v2 rejected preparation and v3/v4 overall NONPASSs remain preserved. |
| Documentation and closeout | Initial G3 source/native each passed one method in 1.541/2.624 s; six status methods plus separately run G3 give seven distinct methods per route. Initial hygiene/whitespace passed in 0.661/0.138 s on the same source map. Current twelve-document status heads retain full preceding histories. | Repeated G3 adds no distinct coverage; final recheck/publication/readback/synchronization identities are external. No full-suite or broader completion claim. |

The .36.1 candidate GUI attempt remains NONPASS after CUA transport failure;
Projects GitHub persistence/reopen and Tools web execution are still unqualified.
[Status qualification](docs/QUALIFICATION-STATUS.md). Complete prior phases follow.

## Instruction-package retained-document count correction

Current target **0.36.1 (50)** enforces the existing 4,096-document catalog bound
before immutable publication and queue linkage, including container/manifest.

| Milestone | Observed evidence | Remaining gate |
| --- | --- | --- |
| Baseline and correction | Two actual rejection methods failed, exit 1/unforced, in 12.245 s with ten assertions; both 4,097-document imports mutated queue/store/reopen. A five-line common-owner guard now rejects them. | Original baseline stays NONPASS; persisted oversized snapshots are not migrated. |
| Boundary and parity | Earlier focused five passed in 24.404 s on their own map. Current source/native each passed the exact same 45 methods, zero failures/skips, in 31.726/34.385 s on matching 464-input 47479210… maps; all 40 original methods remain unchanged. ZIP4095+container, manifest4095+manifest and directory4096 read/reopen checks passed. | Focused five adds no distinct coverage. CoreGraphics malformed-PDF and eight native linkd diagnostics are retained. No installed/model/HTTP-latency/extractor-shutdown claim. |
| Graph/build and closeout | Existing membership/workspace/signing remain; version/build/G3 expectations advance under patch policy. CLI/app passed in 0.990/0.886 s; ordinary Debug/strict signature in 25.736/0.138 s, normal exit 0/unforced. Seven-binary .36.1/50 candidate cbb9f95c… binds the same 464 map; native CLI version passed in 0.614 s. Prior .36/.35 seven-binary candidates and protected three inputs remained unchanged. Initial-document G3 source/native passed one each in 1.587/1.907 s; the 45 owning methods plus one G3 method give 46 distinct methods per route. Initial hygiene/whitespace passed in 0.654/0.135 s, normal exit 0/unforced. Native G3 destination/DVTAssertions warnings remain. | Exact source/wiki publication/synchronization remains pending. Generic archive/SQLite and broader completion requirements remain open. |

[Instruction-package budgets](docs/INSTRUCTION-PACKAGES.md#resource-budgets).
The preceding BMP milestone and complete historical receipts follow.

## Additive native BMP pixel writing

Current target **0.36.0 (49)** adds bounded BMP to `image_write`, preserving
PNG/TIFF/JPEG/GIF/WebP. Exact encoded straight RGBA and native premultiplied
rendering have separate checks. This checkpoint claims no unrun document or delivery result.

| Milestone | Observed evidence or implementation | Remaining gate |
| --- | --- | --- |
| Mechanism | External collection completed 31 encodes; all ten BMPs and eleven PNG references matched independent source pixels; seven positive/twenty-four negative parser controls passed separately. | Overall BMP/ICO collection stays NONPASS: nine native ICO encode failures, separate nine PNG-wrapper decode failures and third DIB+AND ten-case/nine-failure probe remain; its two public type-hint controls did not change the 1×1 failure/256×256 pass. Mechanism owner observations do not establish product leak freedom or Windows acceptance. |
| Tool and parity | Minimal BMP branch reuses ImageIO/output ownership; focused eight BMP plus catalog one passed in 13.457 s. Owning source/native 233 exact matching methods passed in 77.769/76.830 s, zero failures/skips; raster 48 preserves prior 40 and adds eight. Separate initial-document G3 passed once in source/native (1.439/1.767 s), giving exact matching 233-plus-one unions of 234 distinct methods per route, not one 234-test invocation. | Focused nine and repeated G3 checks add no distinct coverage. Pre-cancel and common-writer late-cancel/revocation E2 remain open. |
| Graph and builds | Existing memberships/signing preserved; only twelve marketing/sixteen build values and two G3 expectations advance. Owning routes bind 464 map 0f204bd3…. CLI/app compilation passed in 0.894/0.894 s; ordinary Debug/strict signature passed in 26.025/0.140 s, normal exit 0/unforced. Debug candidate de889ca4… binds seven current binaries/three protected/prior .35 seven. | Native eight linkd NSCocoa4097 diagnostics are retained. No full-suite/GUI/performance/lifetime claim; later document/delivery results require separate external receipts. Native G3 DVTAssertionsWarning IDELaunchSession.m:395 is retained. |
| Native consumers and Qwen | Signed App/CLI passed in 1.264/0.799 s: sixteen groups, 34 responses/32 frames/10 artifacts each, three BMP/PNG pairs, five preserved formats in bounded parity scope, nine negative calls/five groups and explicit cancel -32800 with target preserved. Qwen passed in 32.566 s: three observed Low-mode responses, two actual selected results consumed, 8 native responses/6 frames/2 artifacts and strict 154-byte 2×2 metadata ACK. Independent encoded-channel/reference checks passed. Separate external native consumer compiled/ran in 1.969/0.364 s, normal exit 0/unforced: seven BMP/PNG pairs/fourteen images, count/type/dimensions, 3144-byte sRGB profile, premultiplied rendering, opaque equality, all fourteen provider release callbacks one/no first error/saturation. Its 44 reads/433776 bytes/sixteen output files and all current 464/candidate/protected/prior .35 guards passed. | External callback release is not owner deinit or product leak proof; native rendering does not claim hidden RGB/raw ICC/Windows. Actual BMP metadata ACK does not prove image understanding, full web, all models or installed/managed-adapter acceptance. Complete .35 histories retain their own evidence. |
| Documentation and delivery | Initial 13-document update was applied under existing Unreleased, with full .35/prior bodies and original NONPASS receipts preserved. Initial G3 source/native one each passed (1.439/1.767 s), with exact matching 234 unions; initial hygiene/whitespace passed (0.679/0.136 s), normal exit 0/unforced. Final-document G3 source/native one each passed (1.535/1.748 s); hygiene/whitespace passed (0.672/0.132 s), normal exit 0/unforced, on the same 464-input map. These repeated G3 checks add no distinct methods. | Later document G3/hygiene/whitespace rechecks and exact source/wiki publication/readback/synchronization require separate external receipts; no unrun result is claimed. Installed GUI/managed adapter/full web/all models/ICO/audio/archive/SQLite/other formats/Release/shipment remain open. |

[BMP contract and gates](docs/NATIVE-IMAGE-WRITING.md).

<a id="additive-native-webp-pixel-writing"></a>

## Preceding additive native WebP pixel writing

Current target **0.35.0 (48)** extends `image_write` with bounded lossless WebP,
preserving PNG/TIFF/JPEG/GIF. Explicit lowercase `webp` accepts all RGBA alpha
bytes; exact decoded file pixels and native premultiplied rendering are separate.

| Milestone | Observed evidence or implementation | Remaining gate |
| --- | --- | --- |
| Mechanism | External v3 seven fixtures/fourteen native-synthetic controls and independent twenty-one parser controls passed; exact file RGBA/native PNG-reference interpretation are separate. | Not product XCTest or App/CLI/Qwen coverage; v2 initializer-label NONPASS retained; no raw ICC/performance/leak claim. |
| Tool and parity | Matching owning source/canonical native 225 passed, zero failures/skips (75.739/75.173 s); raster 40 includes seven WebP methods and retained 33. Separate initial-document G3 one each passed (5.514/5.334 s); exact 225+G3 union sets match at 226 distinct methods per route, not one 226-test invocation. Baseline one failed before feature and now passed. Applied G3 two-literal test-only map 6dcfd15c… follows immutable owning/build/wire/consumer map ce81874f…; all other 463 inputs/production/resources/graph remained unchanged. | Focused seven/repeats add no distinct coverage. Middle-loop cancellation and common-writer late-cancel/revocation E2 remain open. |
| Graph and builds | Same 464 map ce81874f…; memberships/signing unchanged, only 12 marketing/16 build values. Source 75.739 s, CLI/app 0.900/0.893 s, ordinary Debug 26.412 s and strict signature 0.143 s passed; .35/48 Debug candidate 750371a3… binds seven current binaries/three protected inputs/prior .34 candidate. | Debug/signature and isolated App/CLI qualification establish no installed GUI, performance or lifetime acceptance. After App/CLI, 464 source/seven candidate/three protected/seventy-five harness/seven preceding candidate inputs remained unchanged; Qwen after-guards also passed; its harness map contained 76 entries. Native DVTAssertionsWarning IDELaunchSession.m:395 and linkd NSCocoaErrorDomain4097 are retained; no diagnostic-free claim. |
| Native consumers | Actual App/CLI controls passed in 1.334/0.778 s, normal exit 0/full EOF/unforced. Three WebPs per mode independently decoded to exact supplied RGBA, including examined hidden alpha-zero RGB. Signed App/CLI each passed fifteen groups/thirty-two correlated responses/thirty tool frames, nine actual negative calls across five groups and actual 32×64 explicit cancellation. Each produced three WebPs, three PNG references and TIFF/JPEG/GIF parity artifacts; independent file inspection passed. Actual Qwen completed three normal Low responses, consumed two actual write/read results and acknowledged exact 194-byte/2×2 metadata. Seven actual production WebP/PNG native comparisons passed, with sRGB profiles and matching premultiplied renders. | Metadata acknowledgement does not qualify image understanding, full web or all models. Immediate cancellation leaves middle-bit-loop and common-writer late-cancel/revocation boundaries unqualified. |
| Delivery | README, existing Unreleased and thirteen affected current documents record bounded scope, actual checks and complete GIF/JPEG/TIFF/PNG histories/NONPASS receipts. Initial-document G3 and hygiene/whitespace passed; final-document G3 source/native one each passed (1.438/1.867 s), adding no distinct methods, and hygiene/whitespace passed (0.673/0.133 s), exit 0/unforced. Initial source publication, 479 exact remote blobs/readback and synchronization passed; graph/production/resource inputs remained unchanged. | Exact source/wiki publication, readback and synchronization outcomes are retained in external closeout receipts. Installed GUI/managed adapter/full web/all models/other formats/Release/shipment remain open. |

[WebP contract and gates](docs/NATIVE-IMAGE-WRITING.md).

<a id="additive-native-gif-pixel-writing"></a>

## Preceding additive native GIF pixel writing

Current target **0.34.0 (47)** extends `image_write` with bounded single-image
GIF, preserving PNG/TIFF/JPEG. Binary alpha is accepted; partial alpha is rejected.
Palette RGB and hidden transparent RGB carry no exact-output promise.

| Milestone | Observed evidence or implementation | Remaining gate |
| --- | --- | --- |
| Mechanism | 35 external native encodes: 26 GIF plus three PNG, three JPEG and three TIFF; five controls and independent structure/LZW/native comparisons passed. Binary alpha preserved in examined cases; palette loss observed. | Mechanism is separate from product/runtime/leak qualification; no embedded ICC or general exact-RGB promise. |
| Tool and parity | Matching source 218 plus separate G3 one and canonical native 219 distinct methods passed, zero failures/skips; raster 33 includes nine GIF methods. Header/body equivalence, native consumer pixels, alpha rejection, dimensions/noise/bounds, metadata/readback/mode, grants/context and retained PNG/TIFF/JPEG passed. | Earlier focused 32/header-one are subsets on earlier inputs. Selected methods are not full-suite/installed/leak acceptance. Native-call preemption and common-writer late-cancel/revocation E2 remain unexercised. |
| Graph and builds | Existing memberships/signing preserved; only twelve marketing/sixteen build values changed. Source 72.701 s plus G3 1.526 s; native 72.081 s; CLI/app 0.899/0.895 s; ordinary Debug 27.360 s; strict signature 0.129 s passed, exit 0/unforced, same 464 inputs/current seven candidate/protected three/prior .33 seven. | Destination/DVT, NECP and linkd diagnostics retained; no diagnostic-free, GUI, performance or lifetime claim. |
| Native consumers | Signed App/CLI each ten groups/twenty responses/eighteen tool frames, nine actual negative calls and actual 32×64 cancellation passed. Seven GIFs passed independent GIF89a/LZW/full-EOF/exact-binary-alpha checks. Actual Qwen completed three normal Low responses, consumed write/read results and acknowledged 62-byte/2×2 metadata. | Zero opaque RGB difference is scoped to examined fixtures. Qwen acknowledgement is metadata only; installed GUI, production managed-adapter, full web/all models and image understanding remain open. External 105 parser/synthetic-owner controls are not owning/runtime counts. |
| Delivery | README, existing Unreleased and current documents record bounded GIF and preserve full JPEG/TIFF/PNG/ODS histories and original NONPASS receipts. | Final-document G3 and exact source/wiki publication, readback and synchronization are tracked in external closeout receipts. Installed GUI, production managed-adapter, full web, all models, other formats, Release and shipment remain open. |

Native-call preemption and late-cancel-before-rename/revocation remain unexercised
(the latter common-writer source E2). [GIF contract and receipts](docs/NATIVE-IMAGE-WRITING.md).

<a id="additive-native-jpeg-pixel-writing"></a>

## Preceding additive native JPEG pixel writing

Current target **0.33.0 (46)** extends `image_write` with bounded opaque JPEG
while preserving PNG/TIFF. Native mechanism, source/native and direct builds
passed. Strict candidate, signed App/CLI controls, independent raw JPEG inspection and Qwen API consumption passed. Final-document G3 passed in source and native. Source/wiki publication, readback and synchronization are tracked in external closeout receipts.

| Milestone | Observed evidence or implementation | Remaining gate |
| --- | --- | --- |
| Mechanism | Fourteen native JPEG/PNG outputs decoded, eleven JPEG raw Exif sRGB/dimension checks, three exact PNG controls and five first-error/cancellation controls matched. JPEG quality 1.0 remains lossy; decoded sRGB ICC equality is not raw embedding proof. | Mechanism controls remain separate from product/runtime/leak qualification; no ICC embedding promise. |
| Tool and parity | Matching source/native passed 210 distinct methods each, including 24 raster, 44 MCP, 35 catalog, forty queue, retained ODS/PDF/audit and G3. JPEG aliases, metadata/readback/mode, alpha rejection, strict bounds, grants/context and retained PNG/TIFF passed. | Focused 24 is a subset; selected methods are not full-suite/installed/leak acceptance. Native-call preemption and late-cancel-before-rename/revocation common-writer behavior UNEXERCISED (latter source E2 only). |
| Graph and builds | Ten affected memberships remain in existing targets; only twelve marketing/sixteen build declarations change. Source/native 71.764/71.688 s, CLI/app 0.898/0.901 s and ordinary Debug 26.165 s passed, exit 0/unforced, unchanged 464-input map. | Strict candidate, signed App/CLI controls, independent raw JPEG inspection and Qwen API consumption passed. Retained diagnostics establish no GUI/performance/lifetime claim. |
| Native consumers | Strict candidate, signed App/CLI controls, independent raw JPEG inspection and Qwen API consumption passed. | Lossy output does not promise exact decoded RGBA; metadata acknowledgement does not establish image understanding, installed GUI, production managed-adapter, full web or all models. |
| Delivery | README, existing Unreleased and affected documents record bounded JPEG and preserve complete .32/.31/.30 historical records. | Final-document G3 passed in source and native. Source/wiki publication, readback and synchronization are tracked in external closeout receipts. Installed GUI, production managed-adapter, full web, all models, other formats, Release and shipment remain open. |

[Image contract and gates](docs/NATIVE-IMAGE-WRITING.md).

<a id="additive-native-tiff-pixel-writing"></a>

## Preceding additive native TIFF pixel writing

Current target **0.32.0 (45)** extends `image_write` with bounded TIFF while
preserving PNG defaults. Matching source/native, direct builds, strict candidate
and scoped App/CLI/artifact/Qwen checks passed. Final document G3 passed in source
and native. Exact source/wiki publication/readback/synchronization identities
will be retained in external closeout receipts; broader product and shipment
gates stay open.

| Milestone | Observed evidence or implementation | Remaining gate |
| --- | --- | --- |
| Mechanism | The preceding ImageIO TIFF control failed straight-alpha acceptance; the fixed 2×2 AppKit reference passed that pixel control only. Production uses the bounded native Swift writer. | Mechanism controls remain separate from current Forge proof and establish no other-format acceptance. |
| Tool and parity | Matching source/canonical native selections passed 203 distinct methods each, including seventeen writer, 44 MCP, 35 catalog, forty queue, retained ODS/PDF/audit and G3. Exact TIFF pixels/native ICC/strip bounds, .tif/.tiff aliases, metadata/readback/mode, strict bounds, grants, failed-write cleanup and preserved PNG cases passed. | Earlier focused 21 is a method subset on its own checkpoint map. Selections are not full-suite, installed-GUI or leak acceptance. |
| Graph and builds | Ten affected source/resource/test memberships remain in their existing targets; the project changes only twelve marketing and sixteen build settings. Source/native 68.835/69.751 s, CLI/app 0.994/1.002 s and ordinary Debug 24.764 s passed, exit 0/unforced, on the same 464-input map. Strict signature/seven-binary/resource checks passed. | Destination/framework diagnostics are retained; no GUI/performance/lifetime/leak qualification follows. |
| Native consumers | Signed App/CLI controls, independent TIFF artifact inspection and actual Qwen TIFF write/read consumption passed. Exact wire/consumer identities are retained in the image contract. | Qwen acknowledgement is metadata only; isolated candidate/API proof does not qualify installed GUI, production managed-adapter, synthesis, full web or all models. |
| Delivery | README, existing Unreleased and affected documents record current bounded TIFF results and preserve .31 PNG/.30 ODS receipts. | Final document G3 passed source/native without increasing the 203 distinct method count. Exact source/wiki publication/readback/synchronization identities will be retained in external closeout receipts. Other formats, installed/GUI, full web, all models, Release and shipment stay open. |

[Image contract and gates](docs/NATIVE-IMAGE-WRITING.md).

<a id="bounded-native-png-pixel-writing"></a>

## Preceding bounded native PNG pixel writing

Preceding target **0.31.0 (44)** adds `image_write` for supplied RGBA8 pixels.
Owning source/native tests, direct builds, strict candidate checks and scoped
App/CLI/artifact/Qwen checks passed. Final document G3 passed in source and native; publication/synchronization receipts will be retained externally.

| Milestone | Observed evidence or proposed implementation | Remaining gate |
| --- | --- | --- |
| Mechanism | External native opaque and partial-alpha 2×2 PNG encodes passed independent signature/CRC/bounded-zlib/filter checks, preserving all sixteen straight RGBA bytes. The host destination inventory did not list WebP. | Mechanism evidence does not qualify a Forge tool, model, other image format or installed application. |
| Tool and parity | Matching source/canonical native selections each passed 198 distinct methods, including twelve writer cases, four raw-dimension MCP cases, four image catalog cases and G3 once. Exact alpha/row-order pixels, maximum 1 MiB input, bounds, failed-write cleanup, grants/context/audit and existing ODS/PDF/queue/transport parity passed. | Focused 21 is a subset of 198. The selected cases are not full-suite, all-feature, installed-GUI or leak acceptance. |
| Graph and builds | Existing canonical Core/test targets gained only writer/test membership and version settings. Source/native 58.841/82.947 s, CLI/app 1.015/1.204 s and ordinary Debug 25.252 s passed, exit 0/unforced, on unchanged matching 464-input maps. Package/workspace bytes are unchanged. | Strict signature/seven-binary/resource checks passed. Destination/framework diagnostics are retained; no GUI, performance or leak qualification follows. |
| Native consumers | Signed App/CLI each passed eight controls, fifteen correlated responses, thirteen tool frames, three exact PNGs/full binary EOF, strict negatives and actual -32800 cancellation with unchanged destination. Seven produced PNGs passed independent CRC/zlib/straight-RGBA checks. Qwen consumed write/read results across three normal API responses, Low 3/3, and acknowledged exact 175-byte/2×2 metadata. | Qwen acknowledgement is metadata only. Isolated candidate/API evidence does not qualify installed GUI, production managed-adapter, photographic synthesis or other formats. |
| Delivery | README, existing Unreleased and affected documents record the tested bounded phase and retained diagnostics. | Final document G3 passed in source and native. Source/wiki publication/readback/synchronization is recorded in external phase-closeout receipts. Installed/GUI, full web, all models, Release and shipment remain open. |

[PNG contract and gates](docs/NATIVE-IMAGE-WRITING.md).

<a id="native-text-cell-ods-writing-and-import"></a>

## Preceding native text-cell ODS writing and import

Preceding target **0.30.0 (43)** adds bounded `ods_write` and semantic ODS import.
Final scoped source/native, build/signing, wire/artifact/Core and Qwen checks
passed. Preceding-map passes and original failed receipts remain separate.

| Milestone | Observed evidence or implementation | Remaining gate |
| --- | --- | --- |
| Import baseline and repair | The original source/native method each failed 13 assertions on .29 inputs: four documents per workbook and 965 blank-workbook XML instruction bytes. A later valid-list regression failed three assertions. Both repaired methods passed in final source/native; unsupported direct text blocks reject before paragraph/cached-value selection. | Original baseline failures remain NONPASS. Existing saved packages are not rewritten; reimport is required for cell conversion. |
| Reader/writer and parity | Bounded ODF 1.3 text writing, native cell extraction, grants, authorization and audit parity passed within final 199 distinct source and matching native methods each, including G3 once. Three list fixtures independently passed official RelaxNG. | First reader compilation failed on two missing `try` annotations with no executed methods; retain that NONPASS. Full Office and unsupported content remain outside the text subset. |
| Runtime consumers | Final App/CLI each passed eight controls and 15 correlated responses. All seven actual artifacts passed official content/manifest RelaxNG and text reconstruction. Public Core passed two new owned App artifacts; Qwen consumed actual write/full-base64-read results across three normal API responses, Low 3/3, with exact final metadata. | Populated Core queue start was not exercised. Qwen's final acknowledgement is metadata only. Candidate/API evidence does not qualify installed GUI, production managed-adapter or Office GUI behavior. |
| Version/graph/build | Final matching 462-input maps; source/native 50.120/51.392 s, 199 passed each. Final CLI/app, ordinary Debug (25.328 s), strict signature and seven-binary/resource checks passed on .30.0/build 43. Focused 33 and R1 198 are not added to 199. | Native linkd/CG thumbnail diagnostics remain; no cause or general GUI/performance claim. R1 runtime receipts keep their superseded original map/candidate. |
| Delivery | README, existing Unreleased and affected operating documents record the bounded phase and retained failures. | Exact source/wiki publication and synchronization identities belong in the external closeout after verification. Installed/GUI, full Office/full web, all models, Release and shipment remain open. |

[ODS contract and retained failures](docs/NATIVE-ODS-WRITING.md).

## Preceding 0.29 web and qualification follow-up

### October 8 web and qualification follow-up

The preceding product target remains **0.29.0 (42)**. This follow-up changes one existing
SwiftPM qualification assertion and records fresh public-web evidence.

| Milestone | Actual evidence | Remaining gate |
| --- | --- | --- |
| Full source regression | The 900-second run completed 2,648 method terminals: 2,635 passed, one H0 method failed and twelve explicitly skipped. One Xcode CLI method started without a complete terminal before forced timeout. | Original run remains NONPASS; no full-suite completion or test-hang cause is claimed. |
| Qualification repair | H0 reads current `VERSION`/`BUILD_NUMBER`, keeping exact 12/16 assignment counts. Its seven-test class passed; the separate Xcode CLI class passed all 41 methods. | Xcode CLI tests exercise argument builders and fixtures, not actual native Xcode workflows. Focused results do not turn the interrupted full run into a pass. |
| Qwen public web | Four normal API responses, actual Low 4/4; three actual search/fetch/render results consumed. Native seven correlated requests exited normally with both EOF. Root review confirmed two Apple URLSession facts and their source link. | Render was truncated; Qwen's additional claim that the whole Overview was captured is unverified. Candidate/API scope does not qualify all sites, all models, authenticated actions or installed GUI. |
| Installed integration | The active Qwen chat reported no web tools; actual installed executable and all three LM Studio registrations target 0.18 (28), separately from the 0.29 candidate. | Installation/registration replacement was not performed. A runtime-capabilities response is not a complete tools/list snapshot. |
| Graph and delivery | Existing SwiftPM H0 target membership is retained; app/native sources, canonical project/workspace, version/build and candidate binaries are unchanged. README, existing Unreleased and affected web document record this scope. | Exact source/wiki publication and synchronization identities are retained externally after readback. ODS, broader feature acceptance, Release and shipment remain open. |

[Detailed scope and receipts](docs/PROJECT-WEB-QWEN.md#october-8-web-and-qualification-follow-up).

<a id="native-text-slide-pptx-writing-and-import"></a>

## Preceding native text-slide PPTX writing and import

Preceding target **0.29.0 (42)**. Bounded implementation and runtime gates passed;
source/wiki delivery is the phase closeout. Broader acceptance remains open.

| Milestone | Actual evidence or implementation | Remaining gate |
| --- | --- | --- |
| Baseline | Public native .28 Core collected both reference-library decks normally, exit 0 in 25.064 s. Each produced 39 documents and 31 exact XML-member instruction documents; populated 81,783 instruction bytes, blank 81,328, both import-ready true/unresolved 2. Originals exact/0400. | Collection succeeded; semantic feature contract failed. Queue start was not exercised. |
| Reader/writer | Native bounded slide-text conversion and additive `pptx_write`, explicit grants and pinned publication. Source/native 166 each passed, including 35 PPTX methods and three audit methods. Writer/reader XML limits agree; conflicting encodings and duplicate expanded attributes reject. | First compile (zero methods), structural 1, parser 2 and audit 1 original receipts remain NONPASS. Full Office fidelity is outside the text-slide contract. |
| Wire/reference/Core | App/CLI passed eight controls each; six artifacts passed exact stored-ZIP/XML/binary readback. All seven artifacts including Qwen passed python-pptx1.0.2 consumption. Same original reference decks now produce one document each: populated 64 instruction bytes/four UTF-8 pages; blank 0/unresolved 1/notready/read+reference+start denied. Originals exact/0400, raw XML 0 and wrong-project denials. | Populated queue start and existing-package reconversion were not exercised. Keynote visual review stopped at its first-run license prompt without accepting it. |
| Qwen | Three normal API responses, actual Low 3/3; two selected/written/correlated/delivered/consumed tool results. Exact SHA/11,384 bytes/one slide; native 6/6 responses, normal worker/observer/collector/native exit+EOF, no forced cleanup. | Isolated candidate/API exchange; installed active GUI, production managed adapter, all models and full web remain open. |
| Version/graph/build | Source/native 166 each include G3. CLI/app, ordinary Debug and strict seven-binary candidate passed on the same 458 inputs. Four Swift memberships added to existing targets; workspace, signing and deployment preserved. | Ordinary Debug 24.519 s; 166 native tests in 70.202 s, zero failures/skips/compiler warnings/QoS blocks. Release and shipment remain open. |
| Delivery | Started from synchronized main `7ae11ba3de42386fba7772af55cde565024baa1d`. README, existing Unreleased and affected current docs record the tested scope. | Exact source/wiki revisions and readback/synchronization identities are retained externally after verification; installed/GUI and shipment remain separate. |

[Contract and retained evidence](docs/NATIVE-PPTX-WRITING.md).

## Preceding XLSX phase

## Native text-cell XLSX writing and import

Preceding target **0.28.0 (41)** adds bounded `xlsx_write` and repairs XLSX import.
The bounded source/native, build/signing, wire/artifact, retained Core-consumer
and Qwen API gates passed; broader product and shipment gates remain separate.

| Milestone | Observed evidence or current implementation | Remaining gate |
| --- | --- | --- |
| Import baseline | R5 observed six catalog documents and five raw package-XML instruction documents for each workbook: one-cell 1,746 instruction bytes; blank 1,608. Both original workbooks were preserved. | Baseline collection succeeded, but the feature contract failed. Earlier setup/temporary-directory guard failures remain separate historical collector failures. |
| Writer | Explicit `.xlsx`, string rows only, one worksheet, finite input/output bounds and literal-text semantics. | Source/native writer controls passed, including grants, stale-context and host-wide OS-authorized write parity. App/CLI each passed eight controls and 15 correlated frames; six artifacts passed binary/text-cell checks. This is not Excel/Numbers/GUI acceptance. |
| Importer | Bounded native XML cell extraction with sheet labels/references; original retained; blank/unreadable input unresolved without package-XML instructions. Actual declarations are rejected while valid CDATA remains data. | Source/native reader/importer controls passed. The same two retained R5 native Core cases passed: one-cell 65 UTF-8 bytes; blank unresolved 1/zero instructions; rawXML instruction documents 0 for both. UTF-8 parts and cached values only; no formula evaluation or full Office fidelity. |
| Qwen XLSX workflow | Three normal API responses, actual Low 3/3; `xlsx_write` then `fs_read`, two actual results consumed; final exact SHA/2525 bytes/four literal cells. Native 6/6 correlated frames and worker/observer/collector exits/EOF passed normally, unforced. | Separate API exchange and isolated candidate, not active installed GUI, production managed adapter, all models or full Office. |
| Provider diagnostics | Earlier H4 stopped normally with six keys, omitting `pages_consumed`; H5 stopped normally with seven keys but changed exact text. Both original final-text gates remain NONPASS. | Provider-only, no native dispatch; cause unknown. The later scoped XLSX pass does not relabel them or qualify full web/all models. |
| Version/graph/build | Current owning source 124 and matching canonical native 124 passed, zero failures/skips/compiler warnings/QoS blocks; G3 included once. CLI/app, ordinary Debug and strict seven-binary candidate checks passed on 454 inputs. | Focused source 26 is a subset, not added to 124. Initial compile failure and R2 wrong outside-confinement assertion remain NONPASS. Runtime framework diagnostics remain separate. |
| Delivery | Earlier .27.1 source/native 212 and clean source/wiki delivery remain labeled below. | Exact source/wiki publication and synchronization identities are retained in the external closeout after verification; installed/GUI, all-feature, Release and shipment gates remain open. |

[Writer/import contract and current gates](docs/NATIVE-XLSX-WRITING.md).

<a id="repeated-runtime-subsystem-shutdown"></a>

## Preceding repeated runtime-subsystem shutdown

The preceding target **0.27.1 (40)** repairs repeated shutdown without adding a tool,
service, task, schema or storage migration. The bounded plain-text DOCX capability
remains available; its preceding qualification keeps its own inputs below.

| Milestone | Actual evidence | Remaining boundary |
| --- | --- | --- |
| Original failure | The exact isolated subsystem parity assertion executed once and failed before the repair, then passed after it. The earlier whole native DiagnosticBoundaryTests run remains NONPASS: 11/12 passed; the existing second application shutdown assertion failed before the four new measurement cells. | Original failed receipts are retained, not relabeled. |
| Existing-owner repair | RuntimeJobSubsystem asks its existing repository actor for a completed certificate; final actor reconciliation stores only an actual completed service report before close. Incomplete reports remain retryable, plain close creates no certificate, and direct service re-inspection remains. | No Managed startup/restart, process termination, durable job format or recovery-bound change. |
| Parity | Owning source 211 and the same exact native 211 passed, zero failures/skips: RuntimeExecutionJobTests 171, ManagedAutonomyRuntimeTests 28 and DiagnosticBoundaryTests 12, including all six new runtime cases and four measurement cells. | Separate source/native G3 passed one each, totaling 212 distinct methods each; focused repeats are not added. Native retains three QoS warning blocks and three XCTest mirrors. |
| Bounded audit measurements | Four original native attachments exported normally and passed the strict 27-field reader; 4,151 payload bytes. Held 50 ms drains returned false in about 52 ms; released flush and final shutdown completed off the main thread. | Requested QoS labels are not effective OS QoS; no production QoS fix, ordinary GUI inversion or leak claim. Whole original native class remains NONPASS. |
| Provider diagnostics | H1 scalar metadata passed one normal Low response. H2 representation and H3 streaming did not complete the original exact-text task within its unchanged 90 s budget; H3 retained 1,496 reasoning deltas/4859 bytes and zero answer/STOP/DONE/bodyEOF before forced worker termination. | Provider cause unknown; no production adapter, installed-GUI, full-web or all-model acceptance. |
| Provider exact-text follow-up | Fresh .27.1 H1 text remained NONPASS: one request/actual Low 1, zero completed responses/answer, confirmed worker KILL -9/full captured EOF, observer exit 0/full EOF; outer exit 1 in 89.605 s with cleanup flag retained. Current 450/candidate guards stayed exact; no native dispatch. | Original R4/H2/H3 NONPASS and earlier H1 scalar PASS remain; cause unknown. |
| XLSX collector setup | Both external utilities exited 2 before import; Foundation retained the actual user temporary directory after successful setenv and the owned-scratch guard was false. | A separate launch-environment probe also failed requested TMPDIR routing: Foundation retained the canonical OS user temp directory, UID 501/mode 0700. No Core import, XLSX runtime classification, writer acceptance, Foundation-cache cause or product diagnosis. |
| Graph/build/candidate | Current version/build authorities advance together; existing memberships remain, PBX only twelve marketing/sixteen build settings. CLI/app and ordinary Debug passed; strict Debug verification passed seven binaries and existing resource contracts. Fifteen prior manifests/99 files and three named protected files stayed exact. | Current source/native G3 passed; the three-file guard does not attest all host data. Release, installation and shipment remain separate. |
| Delivery | Runtime evidence binds the current 450-input map and isolated Debug candidate. | Exact source/wiki delivery identities are retained in the external closeout receipt after remote verification. Runtime checks alone do not demonstrate publication. |

[Shutdown contract](docs/ORDINARY-RUNTIME-CONTINUATION.md#repeated-subsystem-shutdown),
[measurement scope](docs/DIAGNOSTIC-CAPTURE-CONTRACT.md#bounded-audit-drain-measurements)
and [provider diagnostics](docs/PROJECT-WEB-QWEN.md#provider-only-diagnostics).

## Native plain-text DOCX writing

The preceding target **0.27.0 (39)** adds bounded native plain-text DOCX writing.
The following results retain that phase's original inputs and receipts.
Its selected source/native, signed wire, independent artifact/import, production
Core consumer and fresh Qwen API workflow gates passed within the scope below.

| Milestone | Actual evidence | Remaining boundary |
| --- | --- | --- |
| Standalone native controls | Sixteen retained worker controls; both original raw-UTF8 gates remain NONPASS. Independent reconciliation observed fifteen valid XML documents and one invalid document, retaining 67 input hashes. | These are standalone controls. The new explicit paragraph contract does not turn their original byte-exact gates into passes. |
| Additive tool/admission | Exact `docx_write(path, content)`, distinct grants, strict raw path validation, 64 KiB input/1 MiB output caps, XML scalar rejection and paragraph semantics. Builtin Docs and ordinary project-default tools receive the name; custom/imported grants and PDF contracts remain. | Source 154 plus G3 passed 155 distinct methods; native 155 passed the same scope, including all 21 new cases. This is not full Office functionality. |
| Native execution/write ownership | Fixed exact-self child, worker serialization and pinned write passed actual App and CLI wire flows: each9 cases/16 consumed requests/normal exit 0/full EOF, with five exact-code no-write negatives and a producer-only PDF neighbor control. | Security/AppKit calls remain synchronously uncancellable; no universal CPU/peak-heap or PDF semantic claim. QoS2/NECP7/PDF-tagging14 diagnostics are retained. |
| Regression and canonical identity | First 16 source NONPASS 12 assertions/7 unexpected/4 methods and zero-selected first G3 remain. Corrected source 154 + G3 and native 155 passed; CLI/app/ordinary Debug/strict seven-binary verification passed. All 23 changed memberships and all 14 selected class files remain; PBX edits only 12 marketing/16 build values. | Repeats are not added to 155. Historical first maps/failures remain separate. |
| Artifacts and current consumers | Six App/CLI DOCX artifacts passed independent bounded OOXML checks and full binary reconstruction. All 8 actual files, including both Qwen artifacts, passed exact expected native UTF-8 import. Production Core passed 6 cases: 4 exact nonempty conversions,2 empty originals retained with no canonical instructions. | Exact expected paragraph semantics, not universal input-byte or importer/render fidelity. Empty files remain unresolved rather than fabricated text. |
| Qwen workflow | Fresh R2 passed 3 normal responses, 2 actual tool results consumed, actual Low 3/3, scalar STOP and normal native/observer/collector EOF. The 3579-byte artifact independently imported 102 exact expected bytes. First combined NONPASS 2/3 and outer cleanup classification are retained. | Separate API chat and isolated signed candidate; not active installed GUI, general observer readiness or all models. |
| Delivery | Runtime rollup `native-docx-root-final-runtime-reconciliation-0270.json` binds unchanged 450 inputs, 7 current binaries, 3 protected files and 14 prior manifests/92 named binaries. | Exact source/wiki publication and synchronization identities belong in the separate external closeout receipt after remote byte readback. Runtime receipts alone do not demonstrate delivery. |

[Contract and exact evidence](docs/NATIVE-DOCX-WRITING.md). The 54 capability
themes, full-web, installed/GUI, PDFKit, Release/notarization and shipment remain
separate; historical failures do not become passes.

## Preceding MCP notice-receipt hotfix

This preceding target **0.26.2 (38)** corrects receipt truth without adding a tool,
argument, grant or schema. The delivered .26.1 source/wiki remain historical.

| Milestone | Actual evidence | Remaining gate |
| --- | --- | --- |
| EOF baselines | Two separate one-test/one-failure runs completed normally: a wholly skipped packet and a real incomplete JSON prefix without LF each still called `didPresent` once. | Original baseline failures retained. |
| Narrow repair | Private transport completion Bools gate both existing receipt commits; skipped/failed writes discard. Owning source and matching native selections each passed 92 distinct methods, zero failures/skips, on identical 450-input maps. The three new EOF/EPIPE methods and existing complete-packet integration are included. | Synchronous pre-dispatch deadline receipt not directly forced; original failed baselines retained. |
| Test priority qualification | The original native 92 retains five QoS blocks/four source warning lines. Only the private EOF serve controller priority changed afterward; the same one source and native case passed without QoS/source warnings on the final test map. All 449 other inputs remained exact. | Other notice/DiagnosticLog warnings and SQLite/NECP diagnostics remain separate open investigations; no ordinary GUI defect inferred. |
| Current graph and build | CLI/app compilation and the version method passed. The 49-input canonical inventory keeps 48 exact inputs plus PBX changes only in twelve marketing/sixteen build assignments; all four changed Swift files retain their existing Sources memberships. Final ordinary Debug confirmation passed in 1.552 s; strict deep signing passed for seven final binary identities. Thirteen preceding-phase manifests/85 binaries and three protected file identities stayed exact. | The initial .26.2 candidate was superseded after four signatures/identities changed; its failed unchanged-candidate guard is retained. Candidate qualification is separate from installation and shipment. |

[Contract and current evidence](docs/WEB-RESPONSE-BUDGET.md#notice-receipt-truth-follow-up).
Default notice-cache lifetime, prior runtime diagnostics, .26.1 Qwen final
completion, installed/full-web/all-feature and shipment gates remain separate.

## Preceding .26.1 web response-budget hotfix

This preceding identity **0.26.1 (37)** corrects an existing output contract;
it adds no tool, argument or capability. The delivered .26 source is
`4a9441ba1c2cc8b66d208bfd9d8d0d3ec9c968b6`; its receipts remain historical.

| Milestone | Actual evidence | Remaining gate |
| --- | --- | --- |
| Signed wire baseline | Ordinary-ID pages fit 2,048 bytes; escaped-ID first text/base64 frames measured 2,477/2,481 bytes including LF. Exact prefixes, whole SHA and cursors were valid. One parent exited normally at zero with both EOF; eight owned GETs and every source/candidate/protected guard were unchanged. | Original receipt remains NONPASS; it exercised zero policy notices and only two-page prefixes. |
| Final response sizing | The 88 owning-area methods plus 51 real shared-parity methods passed: 139 distinct source cases. The same 139 compiled native methods passed without failures/skips on identical 450 inputs. Internal non-escaping context capture couples budget to dispatch; whole digests/cursors, search order and error/handoff fields are preserved. | Native retained 116 SQLite vnode-unlink, 116 invalidated-fd and 20 unconnected-network diagnostics, plus three QoS blocks/two source warning lines; the separate diagnostic repair remains open. Unmatched source filter names get no credit. |
| Canonical build and graph | Incremental CLI/app passed; ordinary Debug build passed in 25.389 s, strict deep signing at exit0 for seven binaries. All seven changed Swift inputs keep existing memberships. Of 49 graph/resource/fixture inputs, 48 are exact; PBX changes only twelve marketing/sixteen build assignments. Twelve preceding candidate manifests/78 binaries and three protected identities remain unchanged. | Debug candidate scope; Release, installation and shipment are separate. |
| Repeated complete wire | All four native cases passed: eight positive pages/twelve LF responses, normal zero/full EOF and unchanged guards. Escaped first pages measured 2,047 text / 2,041 base64 versus original 2,477/2,481; ordinary-ID sizes are unchanged. | Two-page prefixes and zero actual notices; not full-body or live notice-delivery qualification. Qwen completion remains OPEN/NONPASS; retain the original zero-model harness failure and R2–R4 final-API deadline negatives. No final report was consumed. |

[Contract and retained evidence](docs/WEB-RESPONSE-BUDGET.md). Full-web,
installed/all-feature and shipment gates remain open.

## October 7 ordinary runtime job continuation

This preceding checkpoint's source identity is **0.26.0 (36)**, starting from delivered, clean,
synchronized .25 source `5ff5559ad02192a90a4887154f48e38c81fa54fe` and wiki
`3dc576814d2bafdaa2ff303e5011072026e0a378`. Implementation and draft documentation
are present. First CLI/app compiles and one repaired regression passed on their
first snapshots; the later focused 24 new source tests passed without warnings/errors.
The first owning-area **NONPASS** remains: 307 tests, 41 assertion failures
in two existing pending-output fixtures. A later budget reuse baseline failed
14 assertions, then the guard correction and two genuine unavailable-reader
fixtures passed three selected source methods, no skips/warnings. Earlier
owning-area 307 plus separate exact Manager/version two-method checks passed
**309 distinct source tests**, zero skips/warnings/failures. Incremental CLI/app
and ordinary canonical native Debug build passed. Native 309 passed with three
QoS diagnostics; two test dispatch priority corrections then passed four source
and four native methods without warnings, with ordinary Debug confirmed on the
later map. Strict Debug artifact/build binding and both isolated native MCP
scenarios passed. The first Qwen final-parser NONPASS is retained; its fresh
raw-JSON run passed three rounds/four consumed tool calls. A later isolated
two-helper E0 baseline failed the live-owner feature contract: fallback status
interrupted the primary's still-live sleep job. Collection succeeded; owner
repair is now applied. The final source selection passed **321 methods** without
failures/skips/compiler warnings, and the separate ordinary Debug build passed
in 24.992 seconds on its unchanged 450-input map. The same native 321 methods
passed, retaining one existing DiagnosticLog:64 runtime QoS warning. Strict
Debug verification of seven binaries and signed live-owner/warm-crash/native continuation cases passed.
Fresh Qwen passed three actual Low/API rounds/four verified calls with exact
job/output/task recovery and no replay. Exact direct publication and synchronization revisions are retained in the
external delivery receipt named in the contract after the update.
[Contract and exact original evidence](docs/ORDINARY-RUNTIME-CONTINUATION.md)
retain every failed baseline, earlier native 309 map and current scope.

| Milestone | Actual evidence | Remaining gate |
| --- | --- | --- |
| Original installed failure | Installed .18 Qwen submitted a read-only repository lookup; queued result supplied a UUID, then job.status was blocked by context_budget_exceeded. The actual successor loaded the exact old authored task without that UUID. Manual delivery recovered completed/exit0, 160-byte stdout and empty stderr with EOF, without command replay. | Missing reference continuity is observed; exact installed trigger inputs/newest GUI instruction capture remain unknown. Current source repair passed its affected checks; active-GUI acceptance remains PENDING. |
| Failing baseline | The isolated exact-job/old-authored-task regression executed one test/one failure at the missing UUID assertion. Exit0, full output EOF, authored task/custom seed and pointer assertions passed; the original log remains NONPASS. | The unchanged assertion passed in the first repaired one-test run, zero skips/terminal0 (log e9a5cc26…). Its two new fixture compiler warnings were then corrected. The later 24 new cases passed without warnings/errors on their final map. The first owning-area run returned terminal1 with 41 assertion failures; the later 309-method selection included this original regression; the final current selection passed 321. |
| Native admission and persistence | Source inspection: actual new/reused UUID is persisted before CP COMMIT through same-connection ordinary-client/project/generation/full-grant validation and a one-use Source epoch callback. Both keyed paths and compacted receipts use the seam. Extension bound is 32 native attempts/16 KiB; the 32nd requests rollover. Reference admission adds no schema migration, Source/CP admission journal or lease, job scan or command replay. The separate runtime owner repair uses a private kernel lifetime lease. | First CLI/app integration compiles passed on their 450-input snapshots. All 24 new source cases passed (14 Continuity + 10 Runtime), zero skips/failures, terminal0/no compiler warnings on their final 450-input map (log 21889087…). The first owning-area NONPASS remains historical. The earlier owning-area 307 and separate Manager/version 2 passed, giving 309 distinct source passes on that map; final321 passed after owner repair. Crash/late-commit qualification remains PENDING. Missing CP rows must remain unresolved. |
| Full owning-area regression | `ContinuityTests` + `RuntimeExecutionJobTests` + the selected existing sealed-same-ID `ManagerTests` method executed 307 tests, terminal1, with 41 assertion failures in two existing pending-output Continuity methods. Runtime tests passed 153/0 and the selected Manager method passed 1/0. Running-job output was an empty successful snapshot (`eof:true`, `producer_eof:false`) where the tests expected `runtime_output_unavailable`; progress counter assertions also differed. Log 296a5553…, unchanged 450 inputs. | Retained NONPASS. Owning live empty snapshots remain available. Both fixtures now use a separate reader without the publisher's spool; their original assertions passed in the later three-method run. The earlier rerun passed 307 (Continuity 154+Runtime 153); its unmatched Manager selector adds no Manager evidence. Separate actual Manager+G3 passed 2, yielding 309 distinct source passes, zero skips/warnings/failures. Native 309 passed with zero failures/skips and three QoS diagnostics; later test-only priority fixes passed four source/four native methods without warnings, retaining the prior full map. |
| Budget reuse and unavailable-reader repair | First new fixture compile failed at a non-Equatable record assertion (no executed test); four field comparisons corrected the fixture. The next original reuse baseline executed one test/14 assertion failures, terminal1, log a0ba9cc8…. `canReusePrior` now requires an unsealed packet with absent or current scope/origin extension; a fresh ID otherwise clones authored content/custom seed. The new case and both genuine pending-output reader fixtures passed three methods, zero skips/warnings, terminal0, log ffe6266d…. All old error/counter/loop/handoff/block/running/cancel assertions remain. | The three-method receipt predates the comment-only ToolRouter correction; the earlier 307 owning-area and separate 2 source checks passed afterward on their declared map. The later native selections and isolated Qwen case passed within their recorded scopes. Earlier baseline and 307/41 NONPASS are retained; installed GUI acceptance remains open. |
| Native selection and test priority correction | Actual native 309 passed (Continuity 154+Runtime 153+ Manager 1+ G3 one), zero skips/failures, terminal0; log d7801706…, 173.733 s / 768,226 B. It emitted two new fixture Utility-wait QoS diagnostics, one existing DiagnosticLog:64 warning, and seven deliberate SQLite rename-negative logs. Only two Continuity test dispatch sites changed to explicit userInteractive/enforceQoS; focused source 4 (9bd6a036…) and native 4 (b5746686…) passed without warnings/skips/failures. | Prior full 309 retains its earlier test hash; the subsequent priority-only map differed at those two test lines, product inputs unchanged at that checkpoint. The later runtime owner repair has its own final map. The existing DiagnosticLog warning remains E3 profiling scope. Ordinary Debug later confirmation passed 1.870 s / 21,596 B on the new 450 map. Strict Debug artifact binding and isolated native MCP/Qwen cases later passed on that earlier map. Owner repair passed final source 321/native 321, strict Debug verification of seven binaries and signed owner/continuation repetitions. Fresh Qwen also passed on the final candidate; exact direct publication/synchronization revisions use the external delivery receipt after the update. Earlier receipts retain their earlier map. |
| Earlier signed Debug and native protocol | Strict verification and build binding of the seven Debug binaries passed on that earlier 450 map; nine preceding manifests/57 binaries and three protected identities were unchanged. Two isolated native scenarios passed, 33 accepted jobs, 52 correlated tool frames/56 total LF responses, both parents normal zero/full EOF. Largest actual status frame was 42,833 B within 65,536 B; zero notices were exercised. | This is an ordinary-build Debug candidate, not an installed or Release qualification. Arbitrary IDs, additive notices and exhaustive grants are not covered. |
| Earlier Qwen exact-packet consumption | First case remains NONPASS at fenced final JSON after three rounds/four verified tool calls, log 20c48e76…. Fresh r3 changes only two external prompt strings, keeps the exact parser/assertions, and passed three actual Low rounds/four calls with exact handoff/job IDs, authored goal/custom seed, completed exit0, real stdout/stderr EOF and no replay, log be71aba0…. Native parent consumed 12/12 LF responses with normal zero/full EOF. | Scoped LM Studio API consumption passed; installed GUI successor creation, ACK, seal and all-feature acceptance remain open. The first failure is retained. |
| Multi-helper live-owner recovery | E0 isolated candidate baseline: two roles share one owned home/deployment. Fallback's first job.status entered startup recovery while primary owned a live `/bin/sleep 30` job. After 0.713 s the child was gone and the row failed runtime_owner_restarted; the exact primary parent was still alive and both streams were unavailable. Summary 38619e70…, terminal receipt b0613411…. Both helpers exited zero/full EOF with 23/23 LF responses; the 450/candidate/protected/harness maps were unchanged. | Collection succeeded, terminal0 in 1.394 s; the feature contract failed and remains NONPASS. The private runtime lifetime lease repair is now applied and covered by the final source 321 selection. The same signed two-helper fixture passed on the final map, with both statuses running, the exact child identity unchanged and honest non-owning pending output. No installed-topology failure or qualification is claimed. |
| Warm helper crash recovery | Original owned crash injection killed only the exact primary helper. Its warm fallback still reported running while the same child was reparented and alive; a fresh primary recovered failed/runtime_owner_restarted and removed that child. Four new warm-reader methods failed 23 assertions before repair. | Current authorized status/output/cancel and bounded page reads claim ownership, requery scope and reuse the existing exact-identity recovery without replay. The final source 321 selection includes all four regressions. The signed repeated crash flow passed: warm status recovered failed/runtime_owner_restarted and proved exact child absence. The declared primary SIGKILL/exit-9 remains distinct from normal fallback/fresh-primary completion; no installed qualification is claimed. |
| Ownership guards and cancelled cleanup | Four-case baseline: unsafe directory/coordinator, exact 4,096-file capacity and symlink-lock guards passed; cancelled warm cleanup saturated its bounded 4,096 counter and failed the <=12 cadence assertion. The native awaited delay repair passed the same four cases without failures/skips/compiler warnings (log 3a598a05…). Same-opened-inode lease release and honest exhausted cleanup debt remain asserted. | Source proof and executed fixture evidence are separate from whole-app leak/latency qualification. Dispatch scheduling and native/controller/database work are not preempted by the probe deadline. |
| Final owner-repair source/build map | Actual combined selection passed 321 methods: Continuity 154 + Runtime 165 + exact Manager 1 + G3 one, zero failures/skips/compiler warnings; log 6c7ec648…. Separate ordinary Debug compilation passed 24.992 s / 480,011 B, log 82d8a479…, unchanged 450 inputs. | Native 321 passed with one existing DiagnosticLog64 warning; strict Debug verification of seven binaries and signed owner/continuation repetitions passed. Fresh Qwen passed on the final candidate; exact direct publication/synchronization revisions use the external delivery receipt after the update. Earlier 309/native/57-binary receipts retain their exact prior maps. |
| Earlier exact resume and parity | Source inspection: currently authorized job.status sidecar derives only from the exact persisted native packet before epoch reset. Model references cannot confer admission. Authored goals/custom seeds and same-ID sealed authored edits remain, with native origin/reference preservation. | Two isolated native MCP cases and one fresh Qwen API case passed exact-packet consumption with current status. Largest actual native status frame was 42,833 B within 65,536 B; zero notices were exercised. These cases do not exhaust grant or notice combinations. Installed .18 remains separate; no newest-GUI-task or GUI successor/ACK/seal claim. |
| Canonical identity and delivery | VERSION/BUILD_NUMBER, protocol constants, twelve marketing and sixteen build settings target .26/36. The graph receipt verifies all sixteen changed Swift inputs in their existing targets; source/resource/test memberships and workspace are retained, with only twelve marketing/sixteen build settings changed. Current documents record the tested behavior and its qualification scope. The prior .25 test-only source/wiki closeout is delivered at the refs above, clean 0/0. | Actual source G3 and Manager parity passed separately; source 309 and native 309 passed on their declared 450-input maps. Ordinary Debug was confirmed on the later two-priority-line fixture map. The earlier native 309 had three QoS diagnostics; both source/native focused 4 passed after the fixture correction. Strict Debug signing/build binding and scoped Qwen consumption passed. Owner repair and final source 321/ordinary Debug compilation passed on the later map. Final native 321 passed with one existing DiagnosticLog64 warning; strict Debug verification of seven binaries and signed owner/continuation cases passed. Fresh Qwen passed on the final candidate; exact direct publication/synchronization revisions use the external delivery receipt after the update. All 54 capability themes, PDFKit, full-web, installed/all-feature, notarization and shipment remain open. |

## October 7 native PDF text and measured wrapping

This preceding checkpoint's source identity is **0.25.0 (35)**, starting from synchronized published
source `8ecb186b591195e662cc84ba578b9f40be0db345` and wiki
`ded02011e397b3f71c6be6bdee0db8a04706b142`. The integrated boundary is 450 inputs
with three new Swift files and twelve additive canonical project entries. The PDF
source/wiki checkpoint was then published and synchronized; its exact references
are retained externally. A later test-only capture correction changes one test
hash within the same 450-input map, with the other 449 inputs unchanged. Product
identity remains 0.25.0 (35) at that checkpoint; its test/documentation closeout
was delivered and synchronized at source `5ff5559ad02192a90a4887154f48e38c81fa54fe`
and wiki `3dc576814d2bafdaa2ff303e5011072026e0a378`, both clean with 0/0 divergence.
`native-pdf-capture-publication-and-synchronization-025.json` retains the exact receipt.
[PDF contract and evidence](docs/NATIVE-PDF-WRITING.md) retain the original
failures and separate logical-text, glyph and geometry verification.

| Milestone | Actual evidence | Remaining gate |
| --- | --- | --- |
| Original PDF defects | Signed 0.24 generated eight owned artifacts. Independent pure-PDFKit checks failed bullets, Unicode body/title and explicit UTF-8 source; wide text had two rectangles outside MediaBox. Native PNG review showed corrupted glyphs and clipping. Original source and mixed-order failures remain NONPASS. | Preserve the original artifacts/oracles; generation metadata alone is not text, glyph or geometry proof. |
| Native text and layout | CoreText glyph layout and metric wrapping replace the manual writer. Nineteen writer cases passed in the corrected 101-method source and 102-test compiled selections on the original PDF product snapshot. Signed Debug and Release each generated eight controls plus two source negatives, consuming fourteen LF-inclusive responses with normal exits/full EOF. Each unchanged control PDFKit validator passed seven of eight controls; each profile's ten pages had zero measured bounds outside MediaBox. Native PNG review covered five Debug, ten Release and two Qwen PNG pages. | The whole mixed-script PDFKit order gate remains OPEN. Broader fonts/scripts and arbitrary glyph correctness are not qualified. |
| Complete logical text | Fourteen reader methods cover 53 bounded raw cases. Both durable instruction/policy regressions passed. The corrected source selection passed 101 methods and the compiled native selection passed 102 tests without failures/skips on the original 450-input PDF snapshot. Independent r6 validation passed 82 controls (fourteen admissions, sixty-eight whole fallbacks) and all eight Debug, eight Release and two Qwen artifacts with original scalar markers/page targets. | This is a narrow complete tagged-text subset, not standards-complete tagging or glyph truth. Original PDFKit compatibility failures remain OPEN. |
| Independent validator quota | The retained r5 Debug/Release owners each passed seven of eight artifacts; only the three-page fixture exceeded their 4,096 operand quota. R5 Qwen passed two of two. Fresh r6 raises the external quota to 32,768, retains all original 80 bytes/expectations and adds exact 32,768/32,769 controls; all 82 and current artifact owners passed. The actual three-page artifact used 7,545 independent operands. | This external validator correction does not change the candidate or prove exact production counter parity; production also charges structure/reverse arrays. R5 failures remain NONPASS. |
| Reverse-field admission | Limits baseline failed one assertion; the first enumeration-only patch still failed the same case in a 101-method run (100 passes). A required typed Limits value when its name is present passed the same negative method, then the full corrected 101-method selection. Kids correctly declined throughout. | The observed unresolved optional root-field ambiguity remains explicit; arbitrary malformed PDFs and broader tagging are not qualified. |
| Compatibility and ownership | Tool fields/defaults/source caps/engine metadata retained. New 64 MiB output cap, per-call resource ownership, whole-document fallback and existing durable records preserved. Three new files have twelve entries in existing targets; workspace unchanged. Earlier 35/84 passes and pre-final builds retain their own snapshots. Current CLI/app, canonical Debug/Release, marker regression and strict signing/build binding passed; seven Debug and five Release identities bind 450 inputs. | PDF product checkpoint delivery is complete; its prior warning remains historical E2 evidence, without an observed runtime race or production reachability. The later test/documentation closeout was also delivered and synchronized, with clean 0/0 source/wiki divergence; its exact external receipt is recorded above. |
| Model and publication | Qwen used pdf_write and pdf_from_file in two API rounds with two observed Low templates, consumed both actual results and stopped normally. All six LF-inclusive native responses were consumed with normal zero exit/full EOF. Independent r6 validation passed both documents with original scalar markers. Its separate unchanged PDFKit validator passed conversion but failed the written whole sentinel after a layout line break. Signed 0.24 and every failed repair attempt remain immutable. | The Qwen PDFKit marker gate remains OPEN. PDF source/wiki publication and synchronization are recorded externally; API candidate evidence does not qualify the active installed GUI, installation or shipment. |
| Test-only immutable capture | The freshly compiled UTF-8 regression passed one native test in 5.978 seconds without compiler warnings/errors; the later normal writer selection passed all 19 methods in 3.074 seconds, zero failures/skips. The focused case is included in the 19, not an additional method. All 19 identifiers and 96 existing assertion lines remain, with one new fixture unwrap. Only PDFWriterTests.swift changes; the other 449 inputs, existing graph and product/configuration remain unchanged. Twelve prior Debug/Release binary identities and three protected inputs remain unchanged. | This scoped test correction does not establish a prior runtime race, general concurrency acceptance or a new product candidate. Original 101/102, artifact and failed compatibility receipts retain their old test hash. Test/documentation delivery is complete at the exact refs above; no installed or .26 qualification is implied. |

## October 7 bounded filesystem listing continuation

This checkpoint's source identity is **0.24.0 (34)**, starting from synchronized owner-authored
`574aa99ccd5ba38966f79f4cce0f3c855ea4b7fc`; source and wiki were clean and matched
remote before product edits. [Listing evidence](docs/FILESYSTEM-LIST-PAGING.md)
records this slice. The candidate gates below passed; installed acceptance and
the remaining capability work stay open.

| Milestone | Actual evidence | Remaining gate |
| --- | --- | --- |
| Directory continuation | Signed .23 baseline reproduced the 1,000-name cutoff without continuation. New opt-in paging preserves path-only responses, orders raw filename bytes and fences client/project/generation/path/directory metadata. All 173 affected source cases and the same 173 compiled native cases passed without skips. Signed Debug and Release each passed 35 listing checks, 52 correlated responses across two normally exited parents, the exact 1,001-name union in eight pages and budget-shrunk continuation without gaps. | Metadata fences are not an atomic snapshot or a first-open vnode identity guarantee. Privileged metadata restoration, hostile mounts and installed acceptance were not exercised. Actual additive-policy-notice runtime was not exercised; deterministic final-envelope tests cover the notice and ID. |
| Original input boundaries | Actual tests reproduced numeric path coercion and near-integer JSON rounding. Paged validation now checks original path types and original count tokens; invalid maximum_bytes receives its own argument error. Literal native inputs reject both near-integer counts, and the same stream answers a subsequent ping. Original failed receipts remain NONPASS. | Other tools' numeric parsing is unchanged and is not qualified by these cases. Legacy path-only behavior remains covered. |
| Complete-wire renderer sizing | Exact source regression reproduced 3,730 wire bytes against a 3,729-byte budget. Minimal final-fit correction includes LF; all 17 service cases passed. Signed Debug and Release each passed 35 CLI and ten app-executable MCP cases, consuming 39 and 14 responses respectively with LF-inclusive accounting, normal zero exits, full EOF and closed fixtures. Earlier .23 JSON-only receipts remain preserved. | This qualifies the candidate stdio route; HTTP/native-task framing, whole DOM/network/heap bounds, other Macs and installed/browser workflows remain separate. |
| Qwen consumer | Qwen used the advertised listing descriptor for three real pages, passing the prior returned cursor on each continuation. It reported alpha.txt, middle.txt and zulu.txt once each, then stopped normally. Four nonce-scoped model requests each had observed Low templates; seven native responses were consumed with normal zero exit/full EOF. | Supported LM Studio API evidence; active GUI chat, installed new tools, other models and Release-model repetition were not exercised. |
| Canonical build and ownership | CLI/app compilation and canonical Debug/Release builds passed on the same 447 source inputs. Both ordinary candidates passed strict signing; seven Debug and five Release identities retained. New helper/test membership and all twelve changed Swift inputs were checked in existing targets, workspace unchanged. Five preceding candidates and three installed/registration protections remained unchanged. | Five native-test audit-drain QoS warnings are retained; no ordinary GUI inversion was established. No installation, packaging, notarization or shipment was performed. |

## October 7 native JavaScript web snapshots

This checkpoint’s source identity is **0.23.0 (33)**, starting from synchronized owner-signed
`c391285b00fa4af03eb5210f42f67c3f57e0ffde`. The current implementation and retained
failures are recorded in [native web rendering](docs/NATIVE-WEB-RENDERING.md).
The corrected candidate gates below passed; installed and broader feature
acceptance remain open.

| Milestone | Actual evidence | Remaining gate |
| --- | --- | --- |
| Native JavaScript snapshots | One owned fixed-mode child with role/audit-token/CDHash admission and bounded pipes. Final affected source selection: 199 selected, 198 passed, one existing native-fixture skip. The actual current-version source case passed separately: 200 distinct selected, 199 passed, one skipped. Final descriptor and service reruns passed 15 and 16 cases. Canonical Debug and Release builds/signing passed. All 130 selected compiled cases passed without skips; warning correction retained every assertion and all 16 service cases passed again without warnings. Canonical memberships, native bsm linking and copied research resource verified. | macOS 26 rendering is explicitly unsupported; Intel, installed/all-model/site acceptance, universal prompt denial and whole network/DOM/heap bounds remain open. Two original test audit-drain QoS warnings remain disclosed; no live UI inversion was established. |
| Redirect boundary | Original seven-request full matrix and action-only hypothesis remain NONPASS. Revised external fixture passed 11 baselines and all 11 policy cases. Final Debug and Release CLI matrices each passed all 35 actual MCP cases with exact post-shutdown origin totals, 39 responses consumed, normal zero exit and both EOFs. Signed Debug and Release app executables each passed ten core cases with 14 responses consumed and normal zero exit/EOF. | New provisional policy deliberately rejects finite same-URI cookie/state redirects; ordinary document return, reload, frame and hash cases passed. This is not a whole-network cap or universal HTTP redirect discriminator. |
| MCP response deadlines | Two contention regressions reproduced near-two-second responses for 0.1-second/already-expired requests. First prelookup-only fix still failed; all response routes now require the caller token. Final 35 MCP/deadline cases passed, including both corrections again in the compiled 130-case selection. | Real additive-notice runtime was not exercised in these isolated probes; exact-ID/notice serialization has deterministic coverage. Existing notice targeting and committed-result semantics remain covered. |
| Qwen consumer | Actual descriptor selected; one native render call returned JavaScript marker/title/fragment, Lockdown/readiness and explicit unenforced-resource limits. Qwen consumed those exact fields and stopped normally. Both real requests had observed Low templates; all five native responses consumed, parent zero exit/EOF and joined observer. Source, candidate and three installed/registration protections unchanged. | This is LM Studio API proof; original active GUI chat, installed new tools, other models and authenticated browser workflows remain distinct/open. |
| Attached capability disposition | Read-only external table covers 54 requests/themes. Existing bounded Python-job PNG/WAV/minimal DOCX acceptance retains its exact scope. Source confirms old fs_list cutoff/no cursor; scoped backward-compatible paging plan and unexecuted native baseline driver prepared. | Other rich formats and first-class conveniences remain open. Historical attachment policy text has no dispatch authority. Continue native listing baseline and the next tested local slice after synchronization. |

## October 7 binary web fetching and Qwen file workflows

This checkpoint's source identity is **0.22.0 (32)**, starting from synchronized owner-signed
`3b2b0caa4eab1eaab7d73a1c20d48863d745edbc`. This milestone addresses the
native-reproduced binary HTTP gap and stale current-version markers.
[The current record](docs/BINARY-WEB-AND-QWEN-FILES.md) preserves exact scopes.

| Milestone | Actual evidence | Remaining gate |
| --- | --- | --- |
| Binary HTTP paging | Signed 0.21.0 rejected binary content/default and base64 format. Additive 0.22.0 preserves raw bytes with decoded-byte cursors and whole-body SHA. All sixteen source web cases, nine deadline cases and fourteen catalog cases passed. CLI/app and canonical Debug build and strict signing passed. The same 38,144-byte HTTP body reconstructed exactly in 41 signed-native pages; changed-digest guard, old default error, credential/cookie exclusion, normal zero exit and both EOFs passed. | All sixteen native web tests passed. Actual Qwen used the real base64 descriptor and two correct continued pages, then stopped normally. Its original one-byte prose arithmetic error is retained; a separate read-only correction finished normally without tool/native replay. Installation remains separate. |
| Current-version alignment | Existing 0.21.0 regression reproduced eight failed assertions. Expected current identity and current documentation markers corrected with every assertion retained; twelve marketing and sixteen build settings updated. All four changed Swift inputs remain in their intended canonical targets; graph changes are version settings only. | Focused source and signed-native version regressions each passed once with every assertion retained. Historical receipts retain tested identities. |
| Qwen file examples | Signed 0.21.0 PNG/WAV author and consumer loops completed normally; native pixel/PCM validation and full base64 copy/hash passed. Minimal DOCX ZIP/XML/native text import passed in r3; its consumer guard failure remains NONPASS. Separate read-only r4 completed pending reads and final model stop using the same artifact/job without replay. Protected source/candidate/installed/registration inputs unchanged. | Photographic generation, vision, STT/TTS/music, Word rendering and other rich-format families remain open. |
| Original active chat feedback | Existing Qwen GUI chat identified no current blocked web task or specific failing URL/JS/login/form/download flow. Normal UI completion; empty composer and installed 0.18.0 inputs preserved. | This feedback does not qualify newer candidate tools or prove complete web access. |

## October 7 optional runtime inventory and native web investigation

This checkpoint's source identity is **0.21.0 (31)**, starting from synchronized owner-signed
`52152bd56213372793d98d6e2800ac4c638eba15`. This milestone addresses Qwen's
capability-discovery feedback while preserving existing execution admission.

| Milestone | Actual evidence | Remaining gate |
| --- | --- | --- |
| Optional runtime inventory | Fixed filesystem-only snapshot implemented; existing gates, limits and old Codable records preserved. All twelve source and signed-native regressions passed. Normal selection: 201 selected, 198 passed, three fixture skips, zero failures; live-provider readiness subsequently passed separately. CLI/app and canonical ordinary Debug builds and strict signing passed. Actual Qwen consumed the cached inventory and finished normally; source/candidate/protected inputs unchanged. Correct target memberships verified, graph version-only; [contract and evidence](docs/RUNTIME-INVENTORY.md). | Two current-version native identity fixtures remain unprepared. No optional workflow/import or installed acceptance claim. |
| JavaScript renderer | External native fixture executed page JavaScript. Refusing-proxy localhost bypass disproved universal interception. Fourth fixture completed nineteen bounded native cases with normal exit/EOF, including infinite-script deadline/cancel and TLS. Later external macOS 27 controls exercised visible-window file-picker denial, Lockdown API restrictions and four inline geolocation denials. Owned-child audit-token/signature admission primitive passed separately. All original failures and lifetime/attribution limitations remain. | Production rendering/IPC, minimal-environment startup and macOS 26 support remain unqualified. Broader OS-prompt, whole heap/DOM/network bounds and mapped-Core identity remain unknown. No authenticated-browser claim. |

## October 7 Qwen feedback follow-up

This checkpoint's source identity is **0.20.0 (30)**. Work continues from safely synchronized
owner-signed `a14a63de92d26cfd16fd196601033570e682ba7a` on the native-reproduced
expiry and running-output gaps and Qwen's page-title request.
[The follow-up record](docs/QWEN-FOLLOWUP.md) retains before/after evidence.

| Milestone | Current evidence | Remaining gate |
| --- | --- | --- |
| Memory expiration | Seventeen regressions and the full 49-case memory class passed; all seventeen signed-native cases passed. Final-candidate Qwen reads confirm normal versus explicit expired visibility. The untouched signed 0.19.0 schema-3 export recovered four inserted records into a fresh project through explicit versioned legacy import, with malformed/NUL expiry preserved, strict rejection with unchanged memory-domain rows, separate-project/path guards and durable reopen. Three owned native sessions exited zero with full EOF. | Installed/all-feature acceptance remains open. Per-ID expired/missing explanation is a recorded Qwen usability proposal. |
| Running job-output reads | Eight new regressions and the full 131-case runtime class passed; eight signed-native cases passed. All five production MCP cases passed. Final-candidate Qwen consumed both provisional running streams and exact final continuation, correctly distinguishing producer EOF and terminal exit zero. | Installed/all-feature acceptance remains open; no push-streaming or interactive PTY claim. Additional page-EOF annotation is a recorded Qwen usability proposal. |
| Web page metadata | All eleven web cases passed in source and signed native, including small budgets, adversarial HTML and continued text/source pages. Qwen consumed title/heading availability and both real web tools through LM Studio API, finishing normally. | Installed build remains 0.18.0 (28); JavaScript/authenticated browser access remains open. |
| Projects native controls | The final signed 0.20.0 candidate passed six public Accessibility GUI flows and all five native window captures were reviewed: registration, exact Open URL in Safari, normalized SSH Save, ordinary Quit/relaunch persistence, invalid-host rejection with the correct heading, and Clear. Two app-hosted editor tests also passed. | Installed deployment remains separate. The earlier zero-executed XCTest UI runner remains a retained nonpass; the ordinary controls have independent runtime proof. |

## October 7 project repository and Qwen collaboration

Published checkpoint identity is **0.19.0 (29)**; installed 0.18.0 (28) is preserved.
The owner requested project-linked GitHub entry, model web access, and work with
the active Qwen chat on its reported failures and requested functionality.
[The feature record](docs/PROJECT-WEB-QWEN.md) distinguishes implemented changes,
executed checks, host repairs and still-open additions.

| Milestone | Current evidence | Remaining gate |
| --- | --- | --- |
| Projects GitHub linkage | Stable-project metadata, generation-fenced update, native editor and model projection implemented. Four registry tests and the authenticated route passed in signed native Core; two app-hosted tests passed. Published owner-signed as `a14a63de…`; local/remote main matched, clean. Later 0.20.0 ordinary native GUI verification passed six flows with reviewed captures; see follow-up above. | The initial UI runner timed out enabling automation mode with zero cases; retained as nonpass. Installed deployment remains separate from candidate UI acceptance. |
| Web and file tools for LM Studio | 402 affected source cases passed (two documented skips; live-provider skip subsequently executed and passed), affected final edits rerun. Signed native Core passed 24 cases across two exact selections, app-hosted passed two. Production signed MCP passed five web and six file/search/Git cases; actual Qwen consumed both web tools and finished normally. Published in `a14a63de…`. | Installed build remains 0.18.0 (28). Browser JavaScript/authenticated sessions and broad wishlist are separate open additions. |
| Qwen reported runtime failures | Cache A/B reproduced PowerShell exit 134; archived reversible cache repair passed three direct probes. Active Qwen installed-Forge PowerShell job `91dcf79a…` completed exit zero with version 7.6.6 and full untruncated streams. The subsequent 0.20.0 candidate repairs the separately reproduced expiry and running-output gaps; see follow-up rows above. | CLU/task/context require supported host identity; ordinary GUI rollover and all-feature acceptance remain open. |


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

The separate retained `e3762543…`/v11b **Forge-owned saved-count full mission
passed**: automatic count-3 rollover, same-handoff V2 ACK/seal, one successor
marker and feedback, native validated completion, stable 10.072 seconds and
ordinary restoration to count 200/output 4,096 before native-zero/full-EOF,
unforced shutdown. Earlier NONPASS attempts and publication OPEN remain;
ordinary GUI, policy comprehension, crash, installed and all-feature gates stay
open. [Evidence and limits](docs/LMSTUDIO-RUNTIME-REPAIR.md#forge-owned-saved-count-rollover-mission--pass).

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

## Owner-defined shippable workflow — September 27, 2026

This is the complete current roadmap and acceptance authority. The existing
build is **not shippable**. Earlier roadmaps and Managed Run plans are history,
not product requirements, dispatch instructions, or acceptance evidence for
this workflow.

## Required user workflow

1. The user selects one or more project folders.
2. The user selects one or more instruction packages. The application presents
   the packages in an ordered frame and supports direct click-and-drag
   reordering and organization.
3. The user sets Development Policy in **Rune Forge** with an application
   control that accepts files or folders. Selected policy sources appear in an
   ordered frame and support direct click-and-drag priority reordering.
4. The user starts and conducts the model conversation in the **LM Studio chat
   interface**. Forge Conductor does not start the project through Managed Run.
5. In LM Studio the user asks for `get_forge_status`, then gives the model the
   task instructions. The model can query Forge for the selected instruction,
   project-file, and continuity locations.
6. **CLU** is the governance-enforcement agent. It monitors the model against
   the ordered Development Policy, retains a separate bounded log for each
   project, allows the user to export those logs, and notifies the model of a
   violation with the violated policy and the applicable policy content.
7. Continuity is automatic and is not initiated from the Continuity view. When
   the model saves a resume-ready handoff at context pressure, Forge starts a
   visible 30-second countdown. At expiry Forge uses a supported LM Studio host
   boundary to create a fresh chat, submits `get_forge_status` with
   `resume=true`, verifies that the successor consumed the exact handoff, and
   only then seals the predecessor. Crash recovery is idempotent.
8. The Continuity view is an operator data-management surface only. It always
   shows project IDs in a scrollable frame and supports selecting and copying
   IDs. Under the selected project it lists every actual continuity packet—the
   durable handoff/checkpoint rows consumed by continuity and `context_get`—with
   packet ID, type, and timestamp. **Delete** removes only the selected packet
   or multi-selection after one confirmation. **Reset** and **Clear Cache** stay
   on Continuity: Reset clears settled automatic continuity history without
   advancing the project generation, and Clear Cache removes only Forge's
   bounded disposable cache namespace. Neither deletes unrelated project files. It does
   not expose instruction-package controls, manual checkpoint, rollover, run
   selection, or operation-timeline controls.
9. Instruction-package selection, ordering, and **Delete Package** belong to
   Projects. Project reset and disposable-cache clearing may also remain there,
   but Projects is not a substitute for the required Continuity packet surface.
10. Same-host LM Studio connection, Advanced probe, MCP chat use, and automatic
    successor creation require no Forge-held LM Studio token, operator login, or
    local credential field. Authentication of Forge's own Manager remains a
    separate internal control boundary. Linked HTTPS providers may retain their
    separate credential path.

## October 5 runtime repair — in progress

Current source is 0.18.0 (28). [The repair record](docs/LMSTUDIO-RUNTIME-REPAIR.md)
contains the observed continuity, Stjornarvald, Xcode and idle-helper defects,
retained baseline/control evidence, additive feature surfaces and open gates.
This section updates the affected milestones; historical rows retain their
original tested revisions. No full-feature or installed-build pass is claimed.

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

The completed full Swift v3 source checkpoint selected 2,181 Core cases:
2,168 passed, 13 explicitly skipped, zero failed; filesystem qualification
passed 30 cases without skips. A fresh guidance scratch rebuild passed all
14 catalog cases and strict deep XCTest verification. Later status/storage
repairs passed six focused and 300 affected cases without skips/failures.
Full Swift v4 returned terminal zero: 2,187 Core cases selected, 2,174 passed,
13 explicitly skipped, zero failed; filesystem qualification passed 30 cases
without skips. All 439 frozen product/test/graph inputs remained unchanged.
Post-guidance Debug/Release v1 builds and five-role strict signature/metadata
checks passed, with matching preserved binary/metadata identities; they predate
the status/storage fixes. Retained Debug/Release v2 builds and all five roles'
strict identity checks passed against all 439 frozen inputs. Both compiled
CLI/native Xcode version jobs completed with lossless output and clean serve
exits. The exact Rune app-hosted coverage test and v2 candidate
identity/version-drift test each passed one actual case without skips/failures.
The earlier October 5 source checkpoint passed 19 focused tests without skips, then
selected 505 affected cases: 499 passed, six were explicitly skipped, zero
failed; both commands returned terminal zero. A later adapter protocol checkpoint
selected 34 cases: 33 passed, one live-provider case was skipped, zero failed;
terminal exit was zero. The earlier 2,135-case full Swift
checkpoint retains its dated inputs and seven explicit skips. Native v5 policy
controls passed with separate deployment clients and Manager/both serve exits
zero. Model-notice v6 completed one authentic historical notice interpretation;
retained-v9 compatibility v3 passed new→old→new with three CLI exits zero and a
stopped-owned synthetic seal, not a real successor acknowledgement.
At the v7 test freeze after full v4, only the live test fixture changed; production
and the other 438 frozen inputs stayed unchanged. Its gate correction passed the
ownership control.
Live v3–v5 failed; v5 proved a pre-provider rollover because the fixture's old
cutoff was below the observed 26,450-token initial input plus reserve. The opt-in
fixture now uses 27,648/28,672-token cutoffs, bounded diagnostics and added
initial-normal checks; original assertions remain. Live v6 failed one actual case
without skips in 670.805 seconds after normal initial admission and a real
provider-exact rollover. Successor bootstrap's one attempt was blocked, with
`lmstudio_response_truncated` and no ACK/crash/recovery proof; its incomplete
reason is unknown. All 14 original process identities/MCP registration were
preserved, with no owned survivors. The v7 fixture compiled; its normal class
selected five cases, with three passes, two disabled live skips and zero failures
in 0.323 seconds, terminal zero. The separate live v7 owned Manager/API fixture
passed one actual case without skips/failures in 487.293 seconds, terminal zero:
exact V2 ACK, injected in-process post-commit error/recovery, predecessor seal,
automatic continuation/one marker read and stable replay passed. Three phases
ran in one SwiftPM XCTest process, with all 14 original identities/MCP registration
preserved and no owned survivors. This establishes that scoped API path, not
ordinary LM Studio GUI rollover, SIGKILL recovery or compiled native v2 execution.
Earlier cancellation/v6 incomplete attribution and remaining GUI/debugger gates
remain open.
The subsequent semantic-classifier baseline failed four cases/39 assertions,
with no skips. The narrow repair passed the same four cases without skips/failures
in 0.020 seconds, terminal zero. Normal affected classes selected 52 cases:
51 passed, one explicit live skip, zero failures, terminal zero. Retained native
v2/live v7 predate this repair; the unretained v6 bootstrap body does not establish
its cause. Later full Swift v5 failed: 2,191 Core selected, 2,177 passed, 13 skipped,
one failed; filesystem qualification passed 30 cases. A controlled descendant
test proved three kernel child identities with only two shell PID entries. The
fixture-only correction keeps the >2 threshold and all original cleanup checks,
adding exact-identity cleanup; the normal Runtime class passed 112 of 113 cases,
with one PowerShell skip and zero failures. The original failing interleaving
remains unrecovered.
On October 6, full v6 returned terminal zero: 2,192 Core cases selected,
2,179 passed, 13 explicitly skipped and none failed; filesystem qualification
passed all 30 cases without skips/failures. All 439 frozen inputs remained
unchanged during the run: five full-v4 paths changed, 434 unchanged. Skipped
capabilities remain unqualified.
Canonical native v3 Debug/Release builds returned zero in 60.309/153.358 seconds,
with all 439 inputs unchanged and five-role strict signature/metadata/settings
checks passed, including 15 native identity controls per configuration. Release
required one owned post-build SIGINT. Four classifier XCTests passed via the
signed v3 Debug CLI without skips/failures, native/serve exits zero and lossless
output. Typed readback verified exactly four passed cases without extras/skips/
failures, both result jobs and serve exit zero. These builds predate the later
Runtime/Queue test fixtures and Rune reorder repair. Remaining ordinary GUI, SIGKILL, Compute, LLDB,
simulator XCTest and owner-signing gates remain open.
After full v6, the mixed-format Queue test received a test-only `@MainActor`
annotation after five native actor-isolation warnings. Focused one, normal 38 and
fresh isolated native one-case execution passed without skips/failures; the native
case passed in 0.321 seconds with job/serve exits zero. Rune's three controlled
late-completion cases failed four assertions before a command UUID fence; five
focused and all 15 normal Rune cases then passed, including current-request
rollback. Refreshed canonical native v4 Debug/Release builds passed in
60.369906/158.787937 seconds, with lossless EOF, native exits zero and all 439
inputs unchanged. Debug required no cleanup signals; Release required two exact
owned post-build SIGINT signals, with no owned survivors. All five roles'
strict identity/metadata/settings controls passed in both configurations, and
all 579 independent audit checks passed. Typed Queue build/summary/inventory
readback confirmed exactly one actual Passed case, zero failures/skips, all
three native result jobs and serve exited zero, and configuration bytes were
unchanged. Rune v4 used the wrong native test bundle and executed zero tests
despite `TEST SUCCEEDED` and helper success flags; it remains a non-pass.
Corrected native Rune v5 used the existing app-hosted scheme/bundle and executed
exactly five cases: five passed, zero failures/skips, in 0.246 (0.248) seconds,
with native/serve exits zero and lossless output. Full Swift v7 returned terminal
zero: 2,197 Core selected, 2,184 passed, 13 explicitly skipped and none failed,
plus all 30 filesystem cases passed. Exact reconciliation verified 2,227 actual
selected cases and 2,214 passes, complete raw EOF and all 439 inputs unchanged.
Skipped capabilities remain unqualified. The first candidate SIGKILL attempt
failed preparation before any Manager launch; SIGKILL recovery remains pending.
Installed, full-runtime, ordinary GUI and shipment acceptance remain open.
Documentation-only updates preserve the canonical graph.
The latest SSE checkpoint preserves the public 4,096-event decoder and uses a
private finite 5,120-event Responses budget, retaining independent byte/time
protections. The valid 4,104-frame regression and exact boundary controls passed.
Full source v8 selected 2,232 actual cases: 2,219 passed, 13 explicitly skipped,
zero failed; all 439 inputs were unchanged. Native v5 Debug/Release builds and
five-role identity checks passed; the signed Debug CLI executed exactly five
SSE controls with no skips/failures and native/serve exits zero. The original
native v3 provider failure retains unknown raw-stream validity. The new direct
Manager v5 attempt reached automatic provider-usage rollover, then failed the
probe's handoff-digest comparison before SIGKILL. Native Foundation verified
the probe encoding defect against the exact retained packet. Corrected v6
verified its digest but missed an accepted receipt during its 60-second window
(1,007 samples); Manager cleanup returned zero with full EOF. No SIGKILL was
sent and no crash-recovery or ordinary GUI pass is recorded.
The later 600-second native v7 observation captured one accepted, acknowledged
successor and a sealed predecessor, with durable fencing sequence 20 before
acceptance 22. It missed the planned crash boundary; no SIGKILL was sent, and
the automatic continuation remained an intent without a provider response or
tool execution. Ordinary restart/replay and crash recovery remain unqualified.

| Milestone | Current evidence | Remaining gate |
| --- | --- | --- |
| Owner publication and installation checkpoint | Version **0.18.0 (28)**, tested source `5af17b77…`: **93 affected source cases** and **two native regressions** passed; post-test Debug identity/settings passed. Source `65d14432` and wiki `2a23d68` were published under Jim Daley / flynn33 and synchronized with clean local trees, 0/0 divergence and exact input/page readback. Canonical graph `534e6476…` is unchanged by this documentation update. | Owner handles build, notarization and installation. Further product repair waits for the installation report. Policy attempt `69e4…` remains NONPASS before model activation; actual model policy correction, ordinary GUI rollover, crash recovery, installed and all-feature acceptance remain open. [Published references and limits](docs/LMSTUDIO-RUNTIME-REPAIR.md#owner-publication-and-installation-checkpoint). |
| Managed policy feedback and source replay | On5af17b77, exact original replay case passed1; disjoint affected65 + adjacent28 passed93/0FAIL/0SKIP/fullEOF/unchanged439/unforced. Immediate-feedback PASS1 on21260 and prior baseline/compiler/61PASS1FAIL negatives retained. Fresh Debug13 native0/build-success but cleanup NONPASS at owned ibtoold SIGINT; separate incremental confirmation PASS/ac58c592, no fresh-compilation credit. Subsequent exact policy/source native cases eachPASS1/0FAIL/0SKIP/unchanged439/fullEOF/unforced (af9070ee/c796e108); post-test Debug five-role15controls and both settings queries PASS (0ce835ef/0ba0fbcc/74c05bbd). | Native XCTest/post-test identity subsequently passed; actual managed notice/correction mission unverified. One detector/14 guidance and GUI/crash/installed/all-feature gates remain open. Publication was OPEN at this test checkpoint; the owner checkpoint above records the later verified publication. [Evidence](docs/LMSTUDIO-RUNTIME-REPAIR.md#managed-policy-feedback-and-source-replay--source-checkpoint). |
| Forge-owned saved-count full mission | Retained e376/v11b actual-model PASS:5 accepted completed turns/4 successful reads; count3 automatic request, one operation/two sessions/same-H V2 ACK/seal, one successor marker+completed feedback; native completedrev16/validated15/one passed gate/events60→61; stable10.072s, ordinary200+4096 restoration, Manager+handoff helper native0/fullEOF/unforced. Receipt884972a7…; closed-file reconciliation64587b55…. All earlier NONPASS scopes remain. | Ordinary GUI rollover, model policy comprehension, crash, installed/all-feature acceptance and owner publication remain OPEN. Raw wire bodies, independent completion-hash/event-preimage reconstruction and remote quiescence are not claimed. See the current repair record. |
| Continuity automation and controls | The latest saved3 ordinary Manager/actual-model attempt on source38f9 observed exactly three completed predecessor fs_read calls, requested+fulfilled count rollover, same-H V2 acknowledgement, predecessorSealed and one issued continuation. Its overall receipt166382e3556ce120fe50b4f7d8d60774227aa668a22a191e6ed2c51ba2107418 remains NONPASS: no successor marker read/feedback before the bounded deadline, and the canonical/replay/paused oracle was not reached. Capacity262144 and the default budget/provider contract were unchanged; no ordinary GUI or crash proof. These v7 artifacts predate the later two-input priority repair; current model/artifact acceptance stays open. Managed saved-count source baseline failed one case/three assertions at saved3: four calls executed and no count request. The same case passed after production wiring (c379bb8e78de6b5a0ac7eb61aa96b559dde8c787d915bd0fbc3717aa6178b29a). The corrected selected14 passed14/0FAIL/0SKIP, terminal0/full6570B/stable439/unforced (receipt65733d6454957f2f8a6076df66c137315a64226c12f16243ff8b9fb29d104741): three ordinary reopen recovery, original/limit1 historical replay, legitimate candidate replacement, exact current-call integrity and corruption controls. Earlier13 passed12 but its illegal second active-session fixture failed UNIQUE(run_id); receipt246adb280f103a494b32a27c4ff637288bcf3e7193bcf85669b2d1ca5a4a7373 remains NONPASS. Exact current call/hash, causal journal prefix, retained-tail catchup and sticky pending request are preserved. Final full v12 passed 2,273/2,286 with 13 explicit skips and zero failures after lineage4 passed; failed v11/first lineage receipts remain retained. Current CLI/app/native/model gates remain pending; exact receipts are in the repair record. All these captures retained full output/stable439/unforced cleanup. Ordinary native candidate Settings Save3, unsaved7→Reload3, native Quit/same-home GUI relaunch3 and restored200 passed. All five API/disk phases matched; Manager14970 and GUI14983/15077 exited0 and were reaped without forced cleanup, with all ten protected processes/registration preserved (root semantic record e8dfde5f3ac3abdd72f56b764e219bcff4b65a3db45b30daca8fbeab03097fa4). This proves candidate settings controls/persistence only; automatic count→successor remains a separate gate. Manager settings reload repair adds the existing validated refresh to typed/HTTP reads. Two baseline negative cases reproduced stale 200 after an external save of 3; all three focused controls passed after repair. The broader Manager/continuity selection ran 290 cases: 288 passes, two explicit skips, zero failures, terminal zero/full EOF and unchanged 439 inputs (receipt 8612b2fce5664ac538c657bdb4bc2c9ae2b2ba4564e20e513f06fc8346963007). Staged opt-out and malformed/missing cached recovery remain tested; native validation of the two newer inputs is pending. Failed-tool progress repair: three baseline negative cases failed/four assertions while three success/legacy controls passed. After preserving actual outcomes and open ordered actions, all 14 added and all 33 affected source cases passed without skips/failures, terminal zero and full EOF (class receipt c5f4f89d1a8728a0532dea102bc5558b5e695773d99e2dbb20c62a52627da4d5). Four source/test inputs postdate v8/native v5; the canonical graph is unchanged and refreshed native validation remains pending. A separate native two-launch paused replay passed in 12.636 seconds with both Manager exits zero/full EOF. Root independent audit 40e6afc5ab268b2f11eba9d99a83d65a32b6af0b7d465976f01135c976b8812a verified unchanged exact H/ACK/seal, two tool rows, four turn identities and provider/native ledgers for 10.134 seconds after the second launch. The fourth feedback turn remained ambiguous without a new accepted response; this adds owned paused restart proof while preserving the original non-passes. The later separate ordinary resume completed the original failed-result feedback turn with identical input/previous response, then read the exact owned marker once successfully by absolute path. Independent audit 02b0636202ae859e2ed10d3978294e2835d3ea2b791c36298227c1eb2dca1d96 preserved the original failure and exact H/ACK/seal. The relative-only diagnostic remained a non-pass and stopped before settled replay; later feedback is ambiguous, with no final comprehension, SIGKILL or ordinary GUI proof. The earlier same-home ordinary restart completed the exact automatic turn, but its one model-selected fs_read returned not_found for /home/project/successor-only.txt instead of the handoff’s relative successor-only.txt. The exact-one-marker check failed, stable replay did not run, and the controller paused before tool-error feedback. This establishes no product cause or successful task completion. Native v7 previously acknowledged one successor and sealed its predecessor, but missed the crash boundary without SIGKILL; its automatic continuation was still an intent at that cut. Crash recovery and ordinary GUI acceptance remain unqualified. Earlier direct v6 missed its 60-second accepted-receipt window. The latest full v8 source suite passed all 138 continuity cases without skips/failures. The SSE repair preserves exact acknowledgement/response-completion guards; the original native v3 initial-provider failure remains retained with raw-stream validity unknown. The affected source selection passed all 135 continuity cases without skips. Sticky rollover requests are consumed with the actual packet/counts in the same transaction, preserving the active claim, rollback/restart recovery and epoch fences; projection-file failure reports committed SQL truth. Same-ID changed-content acknowledgement reuse is refused; unchanged retry and fresh-ID controls passed. The earlier aggregate source checkpoint selected 505 cases, with 499 actual passes, six explicit skips and zero failures. A later adapter protocol checkpoint passed 33 of 34 selected cases, with one live-provider skip: bounded live-bootstrap ownership and post-await intent/cancellation fences passed with cold restart retry; V2 contracts, ledger/schema/public fields are preserved. The latest completed full source result is recorded above. The later six-focused/300-affected source selection verifies saved-limit status refresh, cached malformed/missing recovery and storage-only Audit/Queue initialization without changing bootstrap defaults. Earlier signed wire, native GUI settings-persistence and managed API proofs retain their tested input identities. Retained-v9 compatibility v3 passed exact owned startup/packet/progress checks and new→old→new native readback with three CLI exits zero; same-ID write sequence advanced 2→3 while historical synthetic seal 2 remained. Canonical membership remains 413 inputs with five additions and no removals.  Subsequent fullsourcev13 executed2297:2284PASS/13explicitSKIP/0FAIL, native0/full688301BEOF/stable439/unforced; exact prior2286+11 identities/statuses/classes/bundles reconciled (receipt e67bed14e5897c0c577ffee5abf5342f70cde91c62cf30bd90d91dca90596c77). Both Swift products compiled. These source checks do not supply current automatic-successor/model/crash acceptance. Subsequent source c1805d1a native v9 Debug/native37 and five-role Debug settings/signatures passed. The owned saved3 metadata diagnostic observed three completed predecessor reads, same-H V2 ACK/seal, then the first observed accepted empty automatic_continuation: raw completed/provider EOF/metadataComplete, one reasoning item, 4095 output tokens, all reported as reasoning and zero text/tools under4096 with context262144 stable. Receipt85c5103472c7ed10977750357f3944fff87c023fbd9e3941623e1f8010870873 has diagnostic_complete true/qualified false/failure null; Manager0/full bothEOF/unforced/restored200/source439/protected10/current registration preserved. Current80f fullsourcev14 executed2310/2297PASS/13sameexplicitSKIP/0FAIL; both Swift products and canonical v10 Debug/Release builds passed. Exact49Core+2hosted native tests passed51/0SKIP/0FAIL with same439/fullEOF/unforced; both five-role identities and four settings queries passed. Output-setting fixture/loopback controls retain the full source/native scope; all prior negatives remain. Later current80f first8192 actual run reached saved3 request/same-H ACK/predecessorSealed/one successor marker/completed feedback, but overall NONPASS protected-count rejection during10s stability/ownedSIGTERM (receiptc7a6dc12…). Current GUIv10 partial CUA Save3/stepper4→3/unsaved7 Reload3 has matching API/disk; root reconciliation8e88f70e… records SkyComputerUseService SIGTRAP and overallNONPASS.| Ordinary GUI successor creation/consumption and external predecessor sealing remain separate; ordinary candidate threshold controls/persistence passed above. Owned live v3–v5 attempts failed; v5 proved the invalid test cutoff. Live v6 admitted a real provider-exact rollover, then failed at successor bootstrap with lmstudio_response_truncated: one failed case, no ACK/crash/recovery proof, incomplete reason unknown. All 14 original process identities/MCP registration were preserved with no owned survivors. The v7 fixture compiled, then one owned Manager/API case passed without skips/failures with exact V2 ACK, in-process post-commit error/recovery, predecessor seal, automatic continuation/one marker read and stable replay in one XCTest process. This predates the later semantic classifier repair, whose normal classes selected 52 cases: 51 passed, one explicit live skip, zero failures. Later native v3 build/classifier controls passed; full v5 failed one descendant fixture assertion, its normal 113-case correction passed with one PowerShell skip, and full v6 passed 2,179/2,192 Core cases with 13 explicit skips and all 30 filesystem cases. Full Swift v7 later returned terminal zero: 2,197 Core selected, 2,184 passed, 13 explicit skips and zero failures, plus all 30 filesystem cases passed; exact raw-case reconciliation verified 2,227 actual selected cases and 2,214 passes, full EOF and all 439 inputs unchanged. The first candidate SIGKILL attempt failed preparation at a guard expecting 14 identities against a fresh count of 13 before any Manager launch; the recovery gate remains pending. Ordinary GUI rollover and earlier failure attribution stay open. The adapter protocol fixtures establish E0 for those races; actual GUI overlap remains E2. Skipped live/fixture capabilities remain unqualified; the v9 compatibility fixture uses a synthetic stopped-owned seal and establishes no real acknowledgement, v8/live recovery or installation. Retained pre-classifier native v2 build/identity controls passed, while final feature acceptance remains open. The 13 full v4 skips are not passes.  At the subsequent v13/v8 checkpoint, native37/identity/settings/current model and ordinary-GUI/crash/installed acceptance remain open. V9 observation measurement is closed preparation with no outcome or process exemption. This diagnostic does not qualify successor marker/feedback or the full mission. Empty-response cause, actual-model typed Xcode, ordinary GUI rollover, crash and installed gates remain open; no remote-provider quiescence or zero-extra-generation claim. Previous NONPASS receipts and13 full-source skips remain unchanged. Later source-only output-reserve coherence: two REST regression cases changed from failures to passes, and all33 REST plus1 output-boundary case passed/native0/full11351B/EOF/stable439/unforced (receipt0f3b639e503db922feabda2696d9e8366259fcd2e32c4cafdc96fab337f02f30). Provider maximumOutputTokens defaults4096/range1–65536 and stays an immutable requested transport limit through ordinary observations/restart. It is not a service ceiling. Priorc180/v13/v9 and accepted-empty diagnostic scopes remain retained; new settings API/UI/fullsource/native/larger-output host acceptance and full successor mission remain open. Later source80f settings/compatibility controls passed14/0SKIP/0FAIL (receipt53eecb35222a563873308c15b4306bee46544a180ec4f706b8572422529f6604), then selected168 with166PASS2explicitopt-inSKIP0FAIL (receipt126106439f23b35a53cf0c884571cde542f33e5fd914ce2ce6c71f860f6e5eca). Exact source API/auth/CAS/omission/view-model and fixture8192 body/preflight/replay/headroom controls ran; all439stable/fullEOF/unforced/no survivors. The live LM Studio fresh-root/continuation and disposable real-Keychain cases were skipped, not passed. Refreshed full/native/onscreen GUI/larger-output host/full successor/installed acceptance remain open; all earlier negatives/scopes preserved.  Current source/build/selected-native/platform-identity scopes are verified; actual8192 model mission, ordinary onscreen successor/rollover/crash and installed acceptance remain open.13 source skips receive no pass credit. First8192 stability/ordinary shutdown/threshold200 restore/final model inventory and output coherence were not completed; later10-original parity does not requalify or explain initiating mismatch. GUI Provider output Save/Refresh/restart/restore/ordinaryQuit remain unverified. CUA summary is not rawAX export; Forge accessibility causal roleunknown. All earlier negatives/scopes/skips and actual-model Apple workflow/GUI rollover/crash/installed gates remain open.|
| Native Xcode CLI access | Canonical nativev7 Debug/Release and five-role signing/settings checks passed on source38f9; all26 native selected cases passed without skips/failures, retaining a RuntimeJobSubsystem.wait QoS warning. Two direct priority baseline cases failed (caller.high/worker.medium). Explicit caller-priority snapshot then passed focused8, normalRuntime122/123 with one absent-PowerShell skip, and all41 Xcode cases; fullEOF/stable439/unforced cleanup. Current source/test inputs7559/41001 postdate fullv12/v7, so fresh native priority/model/artifact gates remain open. A later exact forced-reader baseline selected1 case and failed2 assertions: both forced-closed streams incorrectly retained artifactTruncated=false. The child exited0/reaped and bounded reader-close assertion passed; no hang or leak is inferred. Direct Swift1/full2443BEOF/stable439/unforced (receipt1081234a8abe7ee519cafd352807066cdc4b0412ce9ff777628c4f1c8a492344). Runtime-output schema6 now persists nullable producer EOF/read-error/forced-close and errno; legacy state stays unknown. Typed Xcode completion requires true producer EOF for both streams. The exact source16 selection passed16/0FAIL/0SKIP, native0/full6119B/stable439/unforced (receipt4c817323ee7f41411566e3c887fa4c4e6c3332b7536be3abc234e279d1391f1d). Original baseline/first repair attempt remain NONPASS. Corrected lineage4 passed, preserving populated v5 unknown-producer output/backups and independent runtime0→6/ingress9→10 ownership. Final full v12 passed 2,273/2,286 with 13 explicit skips and zero failures; failed v11/first lineage receipts remain retained. Current CLI/app/native/model producer proof remains pending; exact receipts are in the repair record. Six separate post-model signing controls passed against changed test-host products (83ae97d72495a589ca5619dbea57bf96f8744acf044165ff4ae0f217bad20f0b), preserving original model NONPASS and unknown historical producer EOF. Current typed LLDB fixture passed native/MCP zero with full streams; receipt `d2af451593db4eb02d423821b4465cd9316e3adfa90ea115a1284dd6a084150f`. Actual model completed build, one XCTest and xcresult with three native-zero jobs; retained NONPASS `b08733dabf04f53681cf9f26c97b83157470b9d6ed9936a5b1e79b982a5fcea1` rejected changed test-host products before post-build signatures. Full artifact/GUI/simulator/recovery gates remain open. Refreshed full source v10 passed: 2,251 passes, 13 explicit skips and zero failures across 2,264 actual cases in 708.278 seconds; all 32 added repair cases passed, native zero, full 678,541-byte EOF, all 439 stable inputs and unforced cleanup (receipt 613906ead4407edafc1d17ca9389214acc54bc22499c36850629823485ea6623). Fresh native v6 Debug/Release builds and all five roles’ strict identity/settings checks passed against the same 439 inputs. Core32 executed 32 native cases, all passed with no skips/failures, full EOF and unforced cleanup (receipt c2d656ff391454c3e4136fb21173b517a26a2e05a7178a1bdde85d42ec71b1ec). Hosted bootstrap1, Rune5 and rollover UI1 also passed with exact native selected counts, no skips/failures, complete EOF and all 439 stable inputs. The rollover field/stepper and both boundaries were exercised; current automatic successor, complete producer output/artifact qualification remain pending. Retained full source v9 is a non-pass: 2,247 passes, 13 explicit skips, one failed bootstrap cancellation case/four assertions, terminal one/full EOF/all 439 stable/unforced cleanup (receipt 6d6076055983824c27c26beebcb87a1863e7fe9060036c68c058392e63a00206). All 29 new repair cases passed. The bounded30 original flow reproduced two equal-path directory-flag mismatches (receipt aa7ddeb09d1775fd72f702d6967d181e77661a2bb7ec92173c9dc1f02e045ae0). Guard-local directory-hint normalization then passed all16 affected source cases, including different-home and authority rejection (receipt 0635aa833cd1b2f94ab6f22bf8fe121e5b5b7ab0d4585a00d752dc57ea657ba4), and the same30 cancellation/retry flows (receipt c454287d5857353b2d2fa939ab91335caa684a95f8961be1a147fd9f2b90f3a8). All had complete EOF/stable439/unforced cleanup; temporary instrumentation was removed. CLI/app v10 compilation passed; full v10 passed; current native gates remain pending. After the prior SecurityAgent process disappeared, one unchanged signed C LLDB control passed in 0.714 seconds with breakpoint/main backtrace/continue/target-zero, native zero/full EOF/all 439 stable/unforced cleanup (receipt d7f08063b15514e6af30714f2b013f0bf80702fb212082745c0b3fc2efef28d0). Host-change cause remains unknown; refreshed Forge typed debugger/native/model completion gates remain pending. The actual model ran one selected Rune XCTest (0.170 seconds), consumed all four complete test/xcresult streams and returned exact native job IDs/counts: one pass, zero failures/skips. Both jobs exited zero. Independent reconciliation 00567a29a443ae159ae4be038bde86e53dac2557cfadfab663aea1bebbc4fec6 verifies this scoped result. The whole managed-run diagnostic timed out at 900 seconds: its unperformed project-build and unrecognized typed-Xcode project-tests obligations remained unmet. Typed completion integration is now implemented in source with exact command/job/output and test-producer fences. Both descriptor regressions failed before repair and passed afterward; all 40 Xcode and 38 Queue cases passed without skips/failures, terminal zero/full EOF, unchanged 439 inputs and unforced cleanup (receipt 24528682ddff85cc25e933fb0a73b265dbf744dfb7591d12c7fae959bd65340b). The two initial new-fixture lifecycle failures remain retained. Build obligations are not bypassed; refreshed native and actual-model completed-mission validation remains pending. The actual owned LM Studio model-to-native Xcode version flow passed in 66.462 seconds: five completed provider turns, four model tool calls, one native exit-zero job, complete 33-byte stdout and empty stderr consumed, exact final output summary and Manager zero without forced signals. Independent audit 58019c3e815a0739bc980700447c34d8e9fe97233e4d8f7201e8ea45ae74e410 verified unchanged 439 source inputs, five binaries, 13 original processes and registration. This version-only proof adds no model-driven build/XCTest/debug/simulator or GUI acceptance. The latest early migration diagnostic again timed out at 300 seconds; its 30-second sample ended before cleanup without a stack. All 24 commands had complete streams, exact owned cleanup preserved all 32 baseline devices, and no simulator XCTest ran. The refreshed native v5 Debug/Release builds and five-role identity checks passed against all 439 unchanged inputs. Through the signed Debug CLI, exactly five SSE XCTest controls passed without skips/failures; native/serve exits were zero and output was lossless. The recorded source checkpoint passed all 28 Xcode and 14 catalog cases. Full-wrapper receipt ceilings reject oversized receipts before job admission while preserving native exit 65 and same-intent replay. Job lists retain complete byte-bounded rows and optional paired timestamp/UUID cursors; equal-timestamp traversal and legacy time-only semantics passed. Existing byte-paged output/base64 proof remains separate. The completed full v3 source result is recorded above; later guidance passed a fresh 14-case catalog rebuild and strict deep XCTest verification. Both Swift products compiled before the later status/storage fixes. Post-guidance canonical Debug/Release v1 builds passed five-role strict signature/metadata checks and retain matching preserved binary/metadata identities; they predate those fixes. Retained v2 Debug/Release builds and five-role strict identity checks passed against 439 unchanged inputs; both compiled CLI/native version jobs completed with lossless output and serve exit zero. The v2 Debug/Release candidate identity/version-drift fixture passed one actual case without skips/failures. Later canonical native v3 Debug/Release builds and five-role strict signature/metadata/settings checks passed against 439 unchanged inputs; Release needed one owned post-build SIGINT. Four classifier XCTests passed through the signed v3 Debug CLI, native/serve exits zero with lossless output. These builds predate the later Runtime/Queue test fixtures and Rune reorder repair. Typed readback verified exactly the same four passed cases, no extras/skips/failures, with both result jobs and serve exit zero. A later test-only @MainActor annotation followed five native AppKit warnings; focused one, normal 38 and fresh isolated native one-case Queue execution passed without skips/failures, with native/serve exits zero. Typed build/summary/inventory readback confirmed exactly one Passed Queue case, no failures/skips, three native result jobs and serve exit zero, and unchanged configuration bytes. Refreshed canonical native v4 Debug/Release builds passed in 60.369906/158.787937 seconds with lossless EOF and all 439 inputs unchanged; all five roles passed strict identity/metadata/settings controls in both configurations and all 579 independent audit checks passed. Debug required no cleanup signals; Release required two exact owned post-build SIGINT signals, with no owned survivors. Earlier installed CAS/32 GiB controls, two native XCTest cases, 35 product-path cases and signed Debug/Release identity/version-job proofs retain their recorded inputs and signing policies. Later provider metadata source7/class31 passed without skips/failures with complete output/stable439/unforced cleanup. Current eight changed inputs versus v7 include priority, metadata and catalog closure repairs; canonical v8/full-source and CLI/app v13 outcomes remain pending.  Subsequent fullsource/CLI/appv13 passed on sourcec1805d1a:2297executed/2284PASS/13explicitSKIP/0FAIL/full688301BEOF/stable439/unforced (receipt e67bed14e5897c0c577ffee5abf5342f70cde91c62cf30bd90d91dca90596c77). Canonical nativev8 Release compilation passed151.458s/native0/full538533BEOF/unforced (receipt fbf5a91c6208747eb4e3923c7de3cbc7f7c6729045828b5a1404feef981a4ef7). Debug xcodebuild returned0/oneSUCCESS/full512934BEOF/57.345s/stable439, but the outer capture remains NONPASS after SIGINT to trackedPID52101 (receipt18d8bbab3907fbbac85f643b7a468d4519a0a51830deaba77b1b6f6446903cbc); first ancestry/path unknown, no Forge leak/hang inference. Subsequent canonical native v9 Debug passed54.946346666s/native0/oneBUILDsuccess/full512938BEOF/stable439/unforced (receipt65311014256f5a946a9c47fb9fd4025ef7c423c73e23700473e6cf7b000a41b5). Exact native37 passed37/0skip/0fail/native0/full718240BEOF/stable439/unforced (receipt908b2a1e65526f1bb8a15847d3dae35577c10a532f488c06e6c5911f7b89a766). Five Debug roles each passed3 signature/metadata/entitlement controls; both Debug settings queries passed (identity0853c98027f2b46f4ca6d91c8d9ca5d4a78bc53a302dd1c80d07dfff23d9bec7). Selected fixture-driven tests add no actual Apple workflow claim. Current80f fullsourcev14/CLI/app passed2310actual/2297PASS/13sameexplicitSKIP/0FAIL. Canonical v10 Debug57.098856250s/full514181B and Release153.281052125s/full540072B builds passed exit0/oneSUCCESS/EOF/unforced/same439 (receipts245b21c584aee02875b2544cd589ae1f355e908fd9b9fd8e208947a6349fe9ad/6c3060ee4d5d322ab9b133bb0f354c65a8c8f2984761d2c558574ea64b2479f9). SelectedCore49+Hosted2 passed51/0SKIP/0FAIL/fullEOF/unforced. Both configurations passed15 signature controls and2settings queries each (identities82e8f738a266e0f2e5dfab1b75f0cfb6d42cc2d8ce869bc16c6b5adc406963b1/bbf6bf363de53adbfbe99ae6e261e7ee5608506be86aea1430dc00e222efe018).| Full v4 source regression and the scoped retained native v2 controls passed as recorded above. The initial stale XCTest resource-seal failure is retained in the repair record; the fresh catalog rerun passed without a trust or test patch. Earlier raw build-for-testing, simulator inventory and descendant-limit controls retain their dated inputs. Current simulator v3 build/boot completed exit zero, but bootstatus timed out after 300 seconds with exit 143 while reporting Apple AddressBook migration; no XCTest executed. Exact owned-device cleanup exited zero, all 32 baseline device states were unchanged and serve exited zero. Alternate iOS 26.5/iPhone 17 Pro v4 also completed build/boot exit zero, then bootstatus timed out at 300 seconds with exit 143 while reporting the same AddressBookLegacy migration wait; no XCTest executed. Exact owned cleanup exited zero, all 32 baseline rows were unchanged and serve exited zero. Both attempts remain unqualified; the underlying wait cause is unknown. LLDB waits at task_for_pid; SecurityAgent prompt contents/authorization outcome remain unknown. Foreground native UI and debugger acceptance remain open. A later direct simulator startup control outside Forge reproduced the same migration wait under inherited unlimited CPU/file-size limits, then bootstatus timed out at 300 seconds with exit -15 and complete output. No XCTest ran; exact owned cleanup preserved all 32 baseline rows. Forge launch/limits are not necessary for this observed wait; its cause remains unknown. The subsequent owned iOS 26.5 namespace diagnostic also reached its 300-second readiness timeout, exit -15, before XCTest. Actual 60/120/240-second namespace snapshots retained the same two migration PIDs; complete exact-PID queries retained AddressBook duration updates and wrapper events. Simulator AddressBook TCC approval and two pending XPC transactions establish no host authorization or migration cause. Truncated queries and a timed-out sample remain non-passes; exact owned shutdown/delete exited zero, with all 32 baseline device bytes unchanged. Native Rune v4 used the wrong bundle and executed zero tests despite TEST SUCCEEDED; it remains a non-pass. Corrected native Rune v5 used the existing ForgeConductorAppTests scheme/bundle and executed exactly five cases: five passed, zero failures/skips, in 0.246 (0.248) seconds, native/serve exits zero and lossless 581,183 stdout/590 stderr bytes. Full Swift v7 passed 2,184 of 2,197 Core cases with 13 explicit skips and no failures, plus all 30 filesystem cases passed; exact reconciliation verified 2,227 actual selected cases and 2,214 passes, full EOF and all 439 inputs unchanged. SIGKILL recovery remains pending after the first attempt failed preparation before any Manager launch. Refreshed v4 platform identity proof establishes no installed, full-runtime or shipment acceptance. Full v5's fixture failure remains retained; corrected normal Runtime validation passed 112/113 with one PowerShell skip, and full v6 passed 2,179/2,192 Core cases with 13 explicit skips and all 30 filesystem cases. A later direct owned iOS26.5/iPhone17Pro bootstatus completed at17s; AddressBook migration logged success, all13 native commands exited0/full producer EOF/unforced, and exact owned-device deletion preserved32 originals. Targeted diagnostic remains NONPASS because no stall/sample was reached; no runtime PID or XCTest was observed, and earlier stall cause is unknown (receipt a02e7f4483f0630ff5647a9c07e140f3a6d725f0bf7f6bbf8564586c6217de49). Current-source actual provider/typed-Xcode/model artifact, simulator XCTest, ordinary GUI rollover, crash and installed gates remain open.  Current native37/five-role identity/settings/actual-provider typed-Xcode/simulator XCTest/ordinary GUI/crash/installed gates remain open. V9 measurement remains closed preparation without a process exemption, production repair or executed outcome. Prior v8 Debug SIGINT receipt remains NONPASS; first ancestry/path/cause remain unknown. V9 observation uses no process exemption or production repair. Actual-model typed Xcode/LLDB, Simulator XCTest, ordinary GUI rollover, crash and installed/artifact gates remain open; the separate accepted-empty successor measurement is diagnostic-only, not a full-mission pass. Full source v13 remains2297 executed/2284PASS/13explicitSKIP/0FAIL. The later ten-production-input output-setting/reserve slice postdates sourcec180/v13/v9. Its selected34 REST/output-boundary source cases passed with no skips/failures and unchangedgraph; this adds no new actual Xcode/LLDB/Simulator workflow, refreshed native candidate or installed qualification. Settings/API/UI and larger-output provider acceptance remain open; all prior native and NONPASS receipts retain their original scope. Later output-setting source14 and ordinary168/166PASS2explicitSKIP0FAIL add deterministic compatibility/settings/fixture-body evidence at80f with unchangedgraph. They establish no new actual Xcode/LLDB/Simulator, larger-output LM Studio, onscreen GUI, refreshed native or installed qualification; earlierc180/v13/v9 scopes and all NONPASS receipts are retained.  Current native build/selected-XCTest/platform identity/settings are verified. Fixture/loopback controls supply no actual-model Apple workflow, onscreen GUI, Simulator XCTest, crash or installed acceptance; prior NONPASS receipts and13 source skips retain their scope.|
| Rune Forge / Stjornarvald / CLU | Current signed native policy v6 passed in 10.707 seconds: intentional Python 0.99 violation/MCP notice/0.98 correction; distinct project/deployment JS 0.45 review, source/copy 0.99 and genuine removal correction; unreadable graph zero findings/faults with open violation/history/event count preserved. Manager and both serve exits zero/full EOF/unforced; all 439 inputs/candidate hashes unchanged and all nine original identities/registration preserved (receipt 5943ddbaa91f73ed99be553c3146a860957dce065e8d3c61c8f878f443286b18). Automatic detector remains RFD-NATIVE-001; fourteen other rules are guidance. The October 6 installed 0.17.0 UI check showed Observing, one policy source and zero current violations, with native-stack detector limits explicit; it adds no candidate or all-rule compliance proof. Full v8 source selected and passed all 15 Rune cases without skips/failures; the refreshed v5 build/identity and SSE checks add no new policy or model acceptance. The live read-only 710 evaluations lacked the sole detector input. The earlier 505-case source checkpoint includes all 23 integration and nine notice cases without skips, covering optional declared-path roles, resource-only JS/MJS still-violations at 0.45 confidence, immutable history/advisory notices and conservative positives. The dated full source results and retained failed full-v5 and completed full-v6 source checkpoint are recorded above; the normal Runtime fixture correction and later native-v3 classifier/signature checks add no policy/model qualification. Earlier signed native v3 Python violation/notice/correction retains its identity. Native v4 first-project controls completed, but its second-project fixture reused the first durable client scope and failed; Manager/serve exited zero, and the run remains unqualified. Native v5 passed Python 0.99 violation/notice and 0.98 correction, resource-only JS 0.45 still-violation/history, source-alias 0.99 and genuine removal corrections with separate deployments; Manager and both serve processes exited zero. The exact v2 Rune coverage/unknown-state app-hosted test passed one case without skips/failures. Model-notice v6 completed one authentic retained .45 notice interpretation in 26.944 seconds, matching review/compliance-unproven/non-blocking/no-correction fields and exact revision/violation ID at actual Qwen context 262144 before and after. The model-v5 timeout remains retained. Actual earlier UI coverage/unavailable-state evidence is retained. After three controlled late-reorder cases failed four assertions, a command UUID fence preserved the newer order through older success/cancellation/error; five focused and all 15 normal Rune cases passed without skips/failures, including current-command rollback. Refreshed native v4 Debug/Release builds passed with 439 inputs unchanged and all five roles' strict identity/metadata/settings controls passed in both configurations; all 579 independent audit checks passed. Native Rune v4 selected the wrong test bundle and executed zero tests despite TEST SUCCEEDED/helper flags; it is a non-pass. Corrected native Rune v5 used the existing ForgeConductorAppTests scheme/bundle and executed exactly five cases: five passed, zero failures/skips, in 0.246 (0.248) seconds, with native/serve exits zero and lossless output. Full Swift v7 returned terminal zero: 2,197 Core selected, 2,184 passed, 13 explicit skips and no failures, plus all 30 filesystem cases passed; exact reconciliation verified 2,227 actual selected cases and 2,214 passes, full EOF and all 439 inputs unchanged. SIGKILL recovery remains pending after the first attempt failed preparation before any Manager launch. Build/signature and scoped Queue result-reader proof add no rule/model qualification, installed or full-runtime proof, or shipment acceptance. Fourteen of fifteen rules remain guidance. Later retained-app catalog source baseline failed1 case/two assertions after completed shutdown: the same3 DB/WAL/SHM physical descriptor identities survived and a catalog read succeeded. Explicit serialized SQLite close plus ForgeApp owner shutdown passed focused2 and ordinary catalog11, with closed-API/idempotence/durable-reopen parity, no skips/failures/fullEOF/stable439/unforced (receipts63da0d383263db1613d82e616a2744af4e32c6e1f1bbcd46dac8fdc2eb6e7d58/e6340f5a47616ddc8227dda3de0bbc340ce44bb310b9b8671490ee4c8b4d62d3). Initial path observer and Darwin.stat compiler negatives remain retained.  The subsequent fullsourcev13 passed2297executed/2284PASS/13explicitSKIP/0FAIL, including both catalog controls; full688301BEOF/stable439/unforced (receipt e67bed14e5897c0c577ffee5abf5342f70cde91c62cf30bd90d91dca90596c77). Swift CLI/app compiled and nativev8 Release compilation passed; Debug capture remains NONPASS at forced cleanup. Source regression does not expand detector scope or qualify current policy runtime. The subsequent v9 native37 run passed both current catalog lifecycle controls, including descriptor release and closed-API/idempotence/durable-reopen assertions; Debug build/five-role strict platform identity/settings also passed on source c1805d1a with stable439/fullEOF/unforced (native receipt908b2a1e65526f1bb8a15847d3dae35577c10a532f488c06e6c5911f7b89a766). Current80f fullsourcev14 executed2310/2297PASS/13sameexplicitSKIP/0FAIL and both Swift products built. Canonical v10 Debug/Release and all51 selected native cases passed same439/fullEOF/unforced; both catalog lifecycle controls remain passing. Both five-role platform identities/settings passed. This adds current lifecycle/regression/build evidence without expanding the one-of15 automatic detector scope. Later current80f native private Stj v10 replay PASS10.182s: Python.99/MCPpresented/removalcorrected.98/resource-onlyJSreview.45/samefilealias.99/unavailablegraphhistoryunchanged/removalcorrected. Manager+MCPa+b each0/fullcapturedEOF/unforced; same439/fivebinaries/protected10/registration/owned3absent (summary57092a8d…/root6a9f1ba2…).| General future model behavior and full policy applicability remain open; the v6 historical interpretation is not GUI rollover or correction proof. Resource-only review grants no exemption or correction. Browser-resource policy applicability remains unresolved, with no feature removal. This later source lifecycle repair does not expand detector coverage or policy authority. Fresh canonical v8/native37/current-model and installed qualification remain pending.  At this later checkpoint native37/identity/settings/current-model/installed qualification remains open; v9 observation preparation supplies no outcome or process exemption. Native catalog lifecycle evidence does not expand the one-of15 automatic detector scope, policy authority or general model/installed qualification. The current accepted-empty successor measurement remains diagnostic-only/qualified false; prior negatives remain retained. Current private native policy/model-notice/onscreen GUI/installed acceptance remains open and separate from build/identity/lifecycle proofs. All detector limits, historical scopes/skips and negative receipts are retained. Current private detector/correction/MCPtransport fixture only: one automatic detector among15indexedrules,14guidance. No modelcomprehension/GUI/ordinarychat/installed/fullpolicy or fullfeature acceptance; legacyjobpageEOF grants no native producerEOF. Browser-resource applicability remains unresolved and all earlier negatives/scopes retained.|
| Latest runtime followups — NONPASS | CLI-Manager GUI captured count 200→Save3→Reload3; Provider/relaunch/restore/ordinary Quit remain open after two further SkyComputerUseService crashes. The second 8,192-token run missed the assigned successor marker and retained an ambiguous `lmstudio_conflict` turn. Actual-model `xcode.debug` reached LLDB but macOS denied attachment; native1/full921B producerEOF. | Full GUI persistence, successor mission, breakpoint/backtrace/continue/inferior0, Simulator, crash and installed gates stay open. The [repair record](docs/LMSTUDIO-RUNTIME-REPAIR.md#latest-gui-second-8192-token-and-model-lldb-attempts--nonpass) retains exact receipts; prior passes and negatives keep their scopes. |
| Typed Simulator and actual-model Xcode workflows | Retained80f third typed Simulator PASS:2 actual iOS tests/0FAIL/0SKIP,20native0jobs/40complete producerEOF streams; owned device removed/32originals preserved. Actual-model build/one-XCTest/xcresult/production completion independently reconciles positively with strict original native/output/typed-summary predicates. Originalb49c overall NONPASS and unperformed later provider/policy checks remain. [Evidence](docs/LMSTUDIO-RUNTIME-REPAIR.md#typed-simulator-and-managed-xcode-workflows--scoped-evidence). | Model-driven Simulator, broader debugging, GUI rollover, crash, installed and all-feature gates stay open. Earlier2Simulator NONPASS attempts are preserved. |
| Applied policy, diagnostics and Debug signing corrections | Sourcee3762543…: same6 source controls PASS/0FAIL/0SKIP, full4077B EOF/native0/unforced. Managed policy ownership/retention identity, first activation/transition error retention, optional local-intent origin and Debug CLI base-entitlement injection are applied. All prior negative receipts and fixture setup corrections remain; old modes and detector/cache assertions are preserved. | Four affected source classes:119started/115PASS/4explicitSKIP/0FAIL, full38250B EOF/native0/unforced; skips require prepared native-job packages or signed candidates/older peers. FreshRelease and separate incrementalDebugconfirmation PASS; originalDebug cleanupNONPASS retained. Foursettings/30five-role signature controlsPASS; DebugCLIget-task-allowtrue/Release5false. NativeCore6+separatecandidate2PASS/0FAIL/0SKIP; historical4areaSkipsretained. LLDBv2NONPASS retained; correctedv3native+productioncompletion independentlypositive/rev8, originalLLDBprobeNONPASS and afterprovider/targetafterNULL retained; freshmanaged-policy model runtime pending; no freshcompile credit forconfirmation. No new count/UI feature or detector coverage claim. [Impact](docs/LMSTUDIO-RUNTIME-REPAIR.md#applied-policy-diagnostics-and-debug-signing-corrections--source-and-native-scopes). |
| Idle telemetry and continuity readiness | On-demand MCP sampling and current-generation readiness passed their affected selection, including all 10 telemetry cases. Signed primary/fallback/CLU idle helpers showed no measurable CPU in three 12-second samples, versus baseline 25–30%; the native gauge lifecycle case passed. Canonical membership audit preserves existing inputs and settings with five additive files. | Complete native UI regression remains open. A separate v4 ordering XCTest passed1 case in12.396s/native0; the retained attachment contains10 actual WindowServer snapshots and all3 terminal occluded+stillVisible outcomes, with exposed startup/recovery. Its harness remains NONPASS for an owned SIGINT cleanup, and attachment export native0/outerNONPASS recorded result-directory mutation (new database.sqlite3 observed; other changes unknown). Independent retained attachment audit54370e58dec08ce59193583acbf1567a43f5f6237bee84a95ba5163a6e742601 adds scoped native observations without a causal fix, blanket Compute or clock-based occlusion claim. The preceding 439-input Compute v3 ordering test executed one case and failed two startup activation assertions in 4.135 seconds, no skips, native exit 65/serve zero with complete streams. No cover variant ran. Snapshot foreground PID 55952 is the live SecurityAgent.bundle process; the root's initial wrong-path absence claim is preserved and corrected. Authorization outcome and inactive/keyless cause remain unknown. The earlier active-host occlusion failure remains separate and unresolved. |
| Candidate/live data isolation | A computer-use snapshot after Quit relaunched the candidate without its isolated environment and completed live store migration 8→9. Actual installed-helper compatibility passed on owned copies. Guarded live repair restored only the version marker to 8 with unchanged application-row hashes, inode, manifests and backup; independent integrity/process verification passed. | Prevent candidate relaunch into the live home; derived pre-incident projection bytes remain unknown. Compatibility recovery does not qualify installed or release behavior. |

## Required repair and acceptance state

<!-- FORGE-COMPUTE-PCB-FOLLOWUP:BEGIN -->
## Compute PCB refinement — verified native scope

The **0.17.0 (27)** PCB/trace refinement is verified in its native scope:
tighter board frames, external headings/readings, darker complete substrate
and surrounding Compute panel, and brighter bounded traveling signals.
The canonical My Mac selection passed 45 tests; 31 overlapping SwiftPM cases
passed. All 68 PNGs were individually reviewed/rehashed, and the matching
ordinary Debug build/strict signature passed. Exact inputs, retained failures
and separate-layer limits are in [Compute](docs/COMPUTE-CORES.md) and
[native QA](docs/GRAPHITE-NATIVE-QA.md); external receipts own delivery refs.
<!-- FORGE-COMPUTE-PCB-FOLLOWUP:END -->

| Area | Current state | Required acceptance |
|---|---|---|
| Graphite Workbench UI/UX and Compute Cores | **0.17.0 (27): PCB/trace refinement implemented and scoped native QA complete.** | Tighter trace-bound frames preserve eight-point pulse clearance, with headings/readings outside; the entire PCB and surrounding Compute panel are darker and traveling signals glow more strongly within preserved route/count/cadence/state bounds. Final 435-input/31-resource manifest 8aeafde6… preserves 422 original inputs and all original 30 resource files; the graph adds only two PCB objects/two list entries. Canonical My Mac tests passed 45/45 with zero failures/skips; SwiftPM repeats passed 31/31. All 68 PNGs (47 Metal/21 separate caches) were reviewed/rehashed, including 20 motion frames, with zero blocking findings/missing/hash mismatches. The matching ordinary Debug candidate CDHash da4039dc… passed build/strict signature. [Compute](docs/COMPUTE-CORES.md) and [native QA](docs/GRAPHITE-NATIVE-QA.md) retain exact source/artifact identities, the initial focus failure of unknown cause and successful retry/preceding runs, separate-layer/XCTest limits and retained evidence. Publication/synchronization refs are external; installation and distribution remain separate. |
| Installed 0.16.4 bootstrap, startup export, and Xcode distribution path | **0.16.5 (26) corrected project and isolated native paths verified.** E0: installed GUI/CLI signing rejection `-67050`, compiled development policy on Developer ID products, and stale archive daemon seals were reproduced/read. Release now signs all five products with Developer ID before sealing; Debug retains automatic Apple Development. Startup diagnostics survive failed/cancelled graph construction and export to a writable folder with unavailable-history disclosure. Canonical Debug build, 8 app-hosted bootstrap tests, universal Release archive and Developer ID export passed. The exported compiled policy passes; 215 identity checks confirm both-architecture app/CLI daemon seals before/after export. Exact exported GUI failure/healthy paths produced native-picker JSON/Markdown exports (23 file assertions); CLI bootstrap passed. Final `swift test` exited 0: qualification 30/30, Core 1,961 selected with 12 skipped and 0 failed. Both SwiftPM products compile. Ten native source/test memberships, resources, embedding, schemes, and non-configuration graph objects are unchanged; H0 remains SwiftPM-only. | Corrected project delivery is complete for the verified paths. UI XCTest initialization timed out before any test ran; direct CUA exercise is separate native evidence. Installation, notarization, distribution, skipped qualification paths, and full LM Studio workflow remain unperformed. The earlier native qualification preserved the installed 0.16.4 app and LM Studio registration; the later publication readback found the app absent, with the registration hash unchanged. Commands, artifact identities, initial failures, and limits are in `docs/QUALIFICATION-STATUS.md` and `/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-03-bootstrap-export`. Local/remote main publication uses the tested inputs; exact revision is retained in the delivery receipt without a self-referential source edit. |
| October 3 documentation and wiki alignment | **Historical 0.16.5 (26) identity alignment recorded.** At the October 3 checkpoint, active guides, README, Unreleased changelog, wiki and qualification summaries used that authoritative source identity. Historical receipts retain their observed versions and limits. The publication host readback is separately dated; it does not replace prior native evidence or attribute the absent app to a known cause. That documentation-only publication preserved the corrected canonical Xcode project and source/resource/test inputs from the tested `354c695842a4dde00d79f4ee946f35152de9d8df` implementation. | Documentation-only checks cover repository hygiene, focused version assertions, active-reference and wiki-link audits, unchanged product-input hashes, and clean local/remote synchronization. Exact repository/wiki revisions are recorded outside the source tree in `/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-03-docs-wiki-sync`. Installation, notarization, distribution, and full LM Studio qualification remain separate. |
| Diagnostic capture and six installed-alpha findings | **Historical 0.16.4 (25) source correction tested; installed-alpha outcome unverified.** The October 2 archive has 11,653 JSON records and a 2,000-row Markdown timeline without an omission notice (E0). Source inspection confirms pre-persistence/reload error redaction, `fs_read`'s unclassified `not_found` mapping, and returned search/shell detail loss (E1). Current source adds stable record and request identities, sanitized error and failure-stage fields, result and job outcomes, connection identity, and explicit export boundaries. The A–H writer/test map is in `docs/DIAGNOSTIC-CAPTURE-CONTRACT.md`; final-tree source and app-hosted results are recorded below. At that historical boundary, Xcode target memberships were unchanged and version/build settings were 0.16.4/25; current authorities are 0.18.0/28. | Verify the patched diagnostic stream and the original user-visible failure sequences on an installed candidate in a later owner-controlled run. The original exceptions for R11618/R11636, R11458's exact cause, R11579's exit, R11640's terminal state, and any Dashboard request association remain unknowable from the old archive. No package, deployment, or live fix is claimed for this source slice. |
| Downloadable alpha Xcode project | **The prior automatic-development Archive correction is superseded by the reproduced owner distribution failure above.** Debug keeps automatic Apple Development; Release uses Developer ID and the distribution peer policy before daemon sealing. The canonical workspace Debug build, universal Release archive, and manual Developer ID export all completed on this host; exported native startup and folder-picker export were exercised separately. | The corrected Xcode project and documented workflow are validated to archive/export and the isolated native paths above. Owner notarization, installation, and distribution remain separate. The prior project tests did not qualify those paths. |
| LM Studio provider | **Exact build-19 Desktop-candidate connection and ordinary-chat acceptance passed without a local credential; build-21 automatic successor acceptance uses the same GUI-hosted MCP channel.** The signed candidate discovered loaded model `qwen/qwen3.8-27b`; Connect and Check and Run Advanced Probe passed before and after exact-path relaunch. Manager readback was ready/contract-valid with `credential_configured=false`, and the UI exposed neither a token field nor a credential action for the loopback endpoint. A fresh foreground LM Studio GUI chat called the candidate's `get_forge_status`, `context_get`, and memory tools and returned the live Forge home, project root, project ID, and handoff ID. | Linked HTTPS provider credentials remain separate; the same-host path retains no operator-facing or Forge-held LM Studio credential. |
| Project selection | **0.16.3 CLI staging/deploy reconnect observed (E0); package-install acceptance open.** Archive creation time and Git reflog identify build-tree HEAD `b8a2c5dee546dff8d914405c2169a075bd0187e2`, whose product code matches `a54100b453ba8b1c1489ff09ac64dd6193fc1597`. The archive helper's `forge-conductor install` copied artifacts into `~/.forge-conductor`, not `/Applications` or LM Studio. The staged helper's `install-lmstudio-plugin` wrote revision `7a3b0b17-0e39-4cce-b4cd-20df1c6ee9db` to primary, fallback, and CLU `mcp.json` entries. The support, archive, and separately copied `/Applications` helpers match at SHA-256 `49e81bc5522aff13d77c0b710417add067467d38e05fec651062be2f5480a289`. The old v0.16.2 app was stopped; the candidate was manually copied over `/Applications` for cold-start observation, not installed by the `.pkg`. LM Studio fallback PIDs `38508` and `38964` returned the same deployment client and attached Jamf-Technician generation 7. Filesystem, Git, Continuity, and catalog calls returned `ok: true`; the pasted compact catalog receipt was a later `limit: 1` page, while the full catalog response remains in the saved chat. The registration file was unchanged across GUI launches. GUI Deploy was **not** exercised; `AppModel.deployToLMStudio` supplies the running app executable, so CLI deployment does not qualify it. The Xcode graph is unchanged. | The observed CLI staging/deploy and hosted binding are accepted only for those paths. `.pkg` installation failed for lack of root; GUI Deploy, package installation, notarization, Gatekeeper, shipment, and other roadmap gates remain open. |
| Native tool access | **Build-22 source correction and exact exported-helper probes passed.** Filesystem, search, PDF, Git, shell, and runtime paths are canonicalized but no longer confined to selected project roots or wrapped in Forge's per-command Seatbelt profile. The directly launched signed MCP helper passed `/bin/ps`, a protected Mail-path read without content disclosure, inherited Git, outside-project filesystem/Git operations, and one native runtime job. macOS evaluates access for the responsible signed code objects in the actual launch chain; this does not establish the installed Forge or LM Studio-hosted chain. Runtime jobs retain a default 16-descendant budget, a 1,024-identity hard cap, typed overflow, and bounded cleanup debt. Local outside-project delete/move independently reconstructs protected roots and descriptor-rechecks the source identity at the mutation boundary. Tool grants, shell enablement, project binding/generation, time and output bounds, and durable result fencing remain. | The intended Forge/LM Studio launch chain must prove protected-data access, every runtime profile, descendant cleanup, and destructive-root refusal with the exact candidate. |
| Dashboard active project | **0.16.3 reconnect correction app-hosted tested.** `testRegisteredProjectBecomesTrackableOnlyAfterStatusBindingSurvivesReconnect` asserts a registered-only project is unbound, attaches through status on a primary server, changes the random process identity and role, and resolves the same durable project through the reconnect identity. | Accepted for the automated Dashboard boundary; registration alone remains insufficient evidence. |
| Instruction packages | **Build-23 live query accepted.** Multiple packages can be selected, displayed, drag-reordered, and removed with **Delete Package**. `get_forge_status` now returns the selected project's durable execution order with package IDs, names, positions, source paths, and snapshot hashes. The exact build-23 LM Studio fallback returned `Jamf-Technician-Continuation-Package-R1` at position 0 for the bound project. | Complete selection, reorder, deletion, and persistence remain covered by focused tests; the live query contract is accepted for the retained build-23 candidate. |
| Rune Forge policy | **Build-23 exact-candidate LM Studio acceptance passed.** Files and folders can be selected, persisted, and drag-reordered. `get_forge_status` returns the pinned governing identity, every active source path in durable priority order, supported read tools, and an explicit required action to read and follow all applicable policy before development changes. Policy remains visible when project selection is ambiguous. Revision `22e7443d13496b3cc08b6e98366bb6d2332e3fd4` produced the universal Developer ID candidate; the existing Jamf-Technician chat's final repeated call used fallback PID `12436` from that exact helper and returned `/Users/flynn/Projects/raven-forge-development-main` at priority 1 plus the required instruction, ordered package, prior locations, continuity, and resume data. Focused regressions, both SwiftPM products, and the canonical Debug workspace build passed. | The bootstrap contract is accepted for the retained candidate. CLU live-session violation-notice acceptance, notarization, Gatekeeper acceptance, and shipment remain separate open work. |
| CLU governance | **Deterministic contract implemented; live-session acceptance open.** Notices carry the violated policy identity and full applicable policy statement; logs are project-isolated, bounded, and exportable. | CLU monitors model activity, preserves a separate log per project, exports it, and sends the active model a notice containing the exact violated policy and policy content. |
| Continuity automation | **Build-21 foreground-GUI implementation and live signed-candidate rollover passed.** The successor no longer calls `POST /api/v1/chat` or supplies an integrations array. After the 30-second boundary, the native host adapter activates LM Studio through its public macOS Accessibility surface, presses New, fills Chat input with `get_forge_status`, `resume=true`, the exact handoff ID, and a deterministic nonce, then presses Send. Disposable handoff `79474019-000f-4395-a593-cc74a6da2372` opened selected foreground tab `Forge Rollover Successor Proof`, visibly called `get_forge_status mcp/forge-conductor-fallback`, wrote the exact nonce-bound receipt, acknowledged logical successor `51a4567d-36f9-4d44-8a54-925f6e14a0f5`, and then sealed the predecessor. A delayed watchdog check retained exactly one successor record. Build 21 also accepts Electron's New accessibility name from title, description, or value after build 20 proved that the live control did not populate `AXTitle`; that failed dispatch remained at `intent` and opened no chat. | Owner inspection and shipment remain separate. Crash/restart recovery is deterministic-tested; the live host check proved repeated watchdog idempotency after submission and completion. |
| Continuity view | **Exact build-19 Desktop-candidate packet acceptance passed.** The signed candidate showed project `d2610542-b616-7e8f-ee36-ef902d6060e1` even with automation unavailable and rendered its real checkpoint/handoff rows with ID, type, source, and timestamp. Two disposable packets were selected and deleted through the native UI; all 73 pre-existing packet IDs remained unchanged. The exact-candidate surface test also found Copy, Delete, Reset, and Clear Cache visible and no instruction-package control. | Owner visual acceptance remains separate. Batch selection is deterministic-tested at the exact request boundary; no additional live packets are to be deleted merely to repeat that proof. |
| Reset / packet deletion / cache clearing | **Focused scope tests and live exact-packet deletion passed.** Exact packet deletion cannot reach project-wide clearing, task-owned ingress, instruction packages, or project files. Continuity Reset uses only project-scoped settled continuity-history clearing and does not advance the project generation; Clear Cache remains bounded to Forge's disposable cache directory. | Owner-machine Reset and Clear Cache mutation acceptance remains open because those controls were intentionally not run against live owner data. |
| Managed Run removal | **Removed from primary navigation and the current workflow.** Compatibility internals remain only where required to preserve stored data or reusable low-level services. | No current action, guide, status text, or continuity dependency directs the user to start project work through Managed Run. |
| Distribution artifact | **Product code `a54100b453ba8b1c1489ff09ac64dd6193fc1597` is retained in the `0.16.3 (24)` archive built at HEAD `b8a2c5dee546dff8d914405c2169a075bd0187e2`.** Archive version/build, universal architectures, and strict deep signing passed; a signed `.pkg` was also built. At that historical checkpoint, `/Applications/Forge Conductor.app` was a manually copied candidate, not a package-installed app. `installer` returned `Must be run as root to install this package.` | Package installation, notarization, stapling, Gatekeeper acceptance, Apple upload, and shipment remain open. No package-install or public-release pass is claimed. |

## October 3 diagnostic correction evidence

The attached `forge-diagnostics-20261002-130456.json` has 11,653 records.
R11458, R11579, R11617/R11618, R11636, and R11639/R11640 match the reported
event types and missing fields. The archive cannot identify their discarded
exceptions or establish an outage, job reuse, search exit, or specific
Dashboard request. This is E0 evidence of lost capture and E1 source evidence
for the exporter, redaction, and `fs_read` mapping. No historical cause was
reconstructed.

On the final `0.16.4 (25)` source and test tree, `swift test` completed:
`Executed 1955 tests, with 13 tests skipped and 0 failures (0 unexpected)`.
The skipped cases retain their separate live-provider and environment-specific
qualification boundaries. The canonical Debug workspace command
`xcodebuild -workspace ForgeConductor.xcworkspace -scheme ForgeConductor
-configuration Debug -destination 'platform=macOS' -derivedDataPath
/tmp/forge-0164-debug-build build` ended `** BUILD SUCCEEDED **`.
The complete app-hosted target ran with a separate derived-data path and
`-only-testing:ForgeConductorAppTests`: `Executed 127 tests, with 0 failures
(0 unexpected)` and `** TEST SUCCEEDED **`. The source suite emitted a
nonfatal temporary diagnostic export-directory error; the app-hosted target
emitted a SQLite vnode-unlinked warning from a temporary Stjornarvald fixture.
Neither warning is assigned a production cause here. Repository hygiene and
`git diff --check` passed. Every edited Swift source and test remains in its
existing Xcode target; the project update changes version/build settings.

At the earlier source-test boundary, `/Applications` still held the 0.16.3
alpha. The later owner-installed 0.16.4 failure is recorded above. That source
correction was not then installed or deployed into LM
Studio, packaged, or exercised against the owner's original live failure
sequence. Source and app-hosted tests do not close that acceptance gate.

## Release boundary

Historical `0.16.3 (24)` source has a universal Developer ID app and `.xcarchive`
under `~/Desktop/Forge Conductor 0.16.3 (24)-a54100b-DeveloperID`. A fresh
signed candidate was copied into `/Applications` for the CLI-deploy cold-host
check above, but its signed `.pkg` was not installed. No artifact is claimed notarized,
stapled, publicly shipped, or released. A passing
legacy Managed Run test is not acceptance evidence for this roadmap.

## Current correction evidence

The installed `0.16.2 (23)` fallback diagnostics provide **E0** evidence for
the reconnect defect: fallback PID `5210`, client `7A3301C0…`, exited; the same
deployment restarted as PID `6489`, client `E066BA6A…`. On that replacement
client, `get_forge_status` completed successfully, but the immediately following
`fs_list`, `instruction_catalog`, `bash.run`, `process.run`,
`continuity.status`, and `fs_read` calls all failed with
`project_context_required`. A later LM Studio reproduction observed PID
`8943` → `9656` and client `026B5AD2…` → `A800AC6E…`; even explicit
`get_forge_status(project_id)` did not attach the stable replacement client.
The 0.16.3 source correction makes status attachment idempotent, derives one
client ID per deployment across primary/fallback/CLU restarts, refuses to
reactivate reset-fenced rows, and exposes attachment state. Implementation
revision `a54100b453ba8b1c1489ff09ac64dd6193fc1597` contains the completed correction and
its exact sequence tests. The complete Core
selection passed 55/55, including the focused status and reconnect cases;
ten project-context integration cases, twenty MCP protocol and diagnostics
cases, the replay catalog case, two version-alignment cases, and the Dashboard
resolver case also passed. The same Dashboard case executed and
passed in the signed app-hosted Xcode test target. Both SwiftPM products and the
canonical Debug workspace app build succeeded; repository hygiene and
whitespace checks passed. The source produced a universal Developer ID app and
archive whose exact version/build and five shipped code-object signatures pass
the Release privileged-bundle inspection. The cold hosted-session receipt and
path reconciliation are published in the wiki at
`e615c2405a094b43f9ebb4794ba0676c86ae38bd`.

Build-22 source removes the internal Seatbelt wrapper that denied native
commands such as `/bin/ps` even when macOS Full Disk Access was granted. The
complete focused `CoreTests` selection passed 49/49; the focused all-available-
runtime profile case passed with an external working directory, `/bin/ps`, and
inherited environment state. The complete runtime-job suite passed 103/103,
including an observed `setsid(2)` child, and secure-filesystem coverage passed
100/100. Dashboard operational-snapshot tests passed 23/23 in both SwiftPM and
the app-hosted Xcode target,
including live MCP binding preference and the requirement that registration
alone is not active-project evidence. One exact signed-candidate native runtime
job passed; signed-candidate all-profile and descendant-cleanup runtime
acceptance plus live multi-project Dashboard UI acceptance remain open and are
not inferred from the source tests.

Native runtime ownership is finite rather than open-ended: the normal
descendant budget is 16, retained start identities are capped at 1,024, and an
overflow produces a typed failed job. Sticky capacity evidence does not create
immortal liveness after all retained identities exit. Persistent termination
failure becomes bounded cleanup debt with one identity-fenced startup retry.
Local outside-project delete/move reconstructs the protected-root set independently at
execution and compares descriptor-pinned source identity against each protected
root and ancestor again immediately before mutation, closing the authorization-
to-dispatch rename window without reintroducing project-path confinement.

Focused deterministic tests cover provider preparation convergence,
`get_forge_status`, registered-project and location discovery, multi-folder and
multi-package selection, drag ordering, package deletion, project reset,
disposable-cache clearing, ordered Development Policy sources, CLU notice
content, per-project log export, the Continuity project-ID and packet-management
surface, exact packet batch deletion, and the 30-second LM Studio successor state
machine. The complete Swift suite passed 1,933 tests with zero failures and 12
explicit environment-dependent skips. The current source also passed a native
LM Studio connection test before and after app relaunch against
`qwen/qwen3.8-27b` without `operator-unavailable`. A new ordinary-launch native
UI test retained screenshots and accessibility hierarchies for Projects,
Continuity, Rune Forge, and Provider, while five earlier focused tests proved
the Continuity list/copy/delete/reset/package/cache controls, project-ID
copy/deletion, and minimum-window instruction package reorder/deletion controls.
Both SwiftPM products and the canonical Apple Development-signed Debug app
build compile.

A fresh foreground LM Studio GUI chat then called `get_forge_status` through
`mcp/forge-conductor-fallback`, followed by `context_get`, `memory_list`,
`memory_search`, and `fs_read`. Its visible response identified project
`Jamf-Technician`, root `/Users/flynn/GitHub/Jamf-Technician`, project ID
`d2610542-b616-7e8f-ee36-ef902d6060e1`, Forge home
`/Users/flynn/.forge-conductor`, and resume-ready handoff prefix `fdb9130a`.
The live Provider UI test now captures and restores the operator's Forge-owned
LM Studio registration inputs; the exact `mcp.json` and six
manifest/bridge-definition checksums were unchanged after the rerun.

These results prove only their tested boundaries. The roadmap remains open
until the current native candidate passes every Provider entry point and the
complete owner-machine LM Studio workflow proves CLU delivery and the automatic
handoff/countdown/successor/acknowledgement/sealing/recovery sequence.
Historical evidence remains available in Git history and dedicated evidence
documents; it is not part of this roadmap.

Build-19 correction evidence on the current source inputs: the packet store and
wire-contract test, populated Continuity packet-row UI test, confirmed exact
packet-delete UI test, and local-credential migration/rejection test each
executed with zero failures. A signed build-17 candidate exposed an additional
Release-only packet decoder defect: its embedded helper wrote valid packets but
returned an empty inventory. The focused optimized decoder test now passes and
the repaired Release helper reads all durable packets from the live store.
`swift build --product forge-conductor-app` and the canonical signed Debug
workspace build passed. Candidate revision `868645e85ce44b50b159136f3b56758a4f489c12`
produced the universal Apple Development-signed Desktop app and archive
`Forge Conductor 0.16.0 (19)-868645e`. Strict deep signature verification and
the privileged-filesystem bundle check passed. The exact candidate passed the
ordinary owner-surface UI case, including all required Continuity identifiers,
and the real-provider connection/probe case with `credentialConfigured=false`.
Two live disposable packet deletes reduced the inventory from 75 to 73; the
removed IDs were exactly `708cbe57-06b4-4cf3-85f8-75c458966b81` and
`60f7f1be-636c-443d-9cae-2c1fd5a6fc85`, with no additions or unexpected
removals. The focused multi-selection case issued one request for two selected
IDs and retained the unselected packet. The later build-21 automatic successor
acceptance is recorded independently rather than inferred from packet UI tests.

Build-21 source replaces the rejected LM Studio REST integrations successor in
`LMStudioRESTClient.createInteractiveSuccessor` / `LMStudioInteractiveSessionTransport`
with `LMStudioGUIChatDriver.submitSuccessor`. The replacement uses the running
LM Studio app's exposed macOS Accessibility controls and accepts only an exact
`get_forge_status(resume=true)` receipt bound to the handoff ID and rollover
nonce. The signed build-20 host attempt proved the 30-second countdown but also
proved LM Studio exposes its `New` button name outside `AXTitle`; build 21
matches the public accessible name across title, description, and value. Its
focused Swift selection executed 35 tests with one explicit live-provider skip
and zero failures. The signed build-21 candidate then completed handoff
`79474019-000f-4395-a593-cc74a6da2372` in selected foreground LM Studio tab
`Forge Rollover Successor Proof` through `get_forge_status mcp/forge-conductor-fallback`, exact
nonce receipt, logical successor `51a4567d-36f9-4d44-8a54-925f6e14a0f5`, and
predecessor sealing. No shipment claim is made.

Build-22 publication inputs: `VERSION`, `BUILD_NUMBER`, the compiled filesystem
protocol constants, all Xcode build configurations, current README/user/Xcode
and supporting documentation, and the focused version-contract assertion are
aligned at `0.16.1 (22)`. Implementation revision
`91ad90ee7a1e51b7289f4c531ddae4dbbc6812ec`, tree
`08e021b375fb8a998f06d9e81a10e3fffddd21f0`, is published on `main`. Its
universal Developer ID archive and export are retained under
`~/Desktop/Forge Conductor 0.16.1 (22)-91ad90e-DeveloperID`. Strict signing
passes for all five shipped code objects. The exported MCP helper passed the
protected-path, `/bin/ps`, inherited Git, outside-project filesystem, exact
project-binding, and runtime-job probes without Forge sandboxing or path
confinement. Gatekeeper exits 3 with `source=Unnotarized Developer ID`, so
notarization, stapling, Gatekeeper acceptance, live multi-project Dashboard UI
observation, and shipment remain open. The wiki is published at revision
`a8359d47623e7cf23ef58db762c6262e056b4ade`. Historical evidence remains bound
to the version it actually exercised.

Historical build-16 candidate evidence remains available for comparison. Source revision
`f2cc6ca1dd70c5837f318cfb86381d5fcb8785dd` produced the universal Apple
Development-signed Desktop app and `.xcarchive` named `Forge Conductor 0.16.0
(16)-f2cc6ca`. Strict deep signature validation passed and the app reports
`0.16.0 (16)`. With `FORGE_DESKTOP_CANDIDATE_PATH` set to that exact app,
`testOwnerWorkflowSurfacesRemainVisibleFromOrdinarySignedLaunch` executed one
test with zero failures and retained a Continuity screenshot plus accessibility
hierarchy showing the then-current controls. It is superseded for packet and
local-credential acceptance by build 17 and cannot close the current gate.

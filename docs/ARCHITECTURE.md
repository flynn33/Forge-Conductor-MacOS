# Forge Conductor architecture

Version: `0.42.0`; build: `58`. The existing renderer selects a bounded v2 child profile only for `paged: true`; default v1 frames and prefix behavior remain. WebRendererService owns one immutable Data body of at most 1 MiB, bounded metadata and one weak-capturing expiry task. Successful complete capture replaces the body; failed/overflow/cancelled capture preserves it. Continuation binds the snapshot ID/digest, exact requested URL and resolved project/client authorization, validates UTF-8 scalar offsets and never refetches or refreshes expiry. Shutdown cancels/joins the expiry owner and clears the body. Matching source/native 150 and signed App/CLI complete-paging checks passed. Qwen v6 also passed the bounded whole-paging/strict actual Low flow. These scoped checks do not establish general lifetime. Applied-v2 final source/native G3, hygiene and local link checks passed; final candidate v3 readback preserved source/artifact identities. Exact source/wiki publication and synchronization remain pending. [Contract](NATIVE-WEB-RENDERING.md).

## Preceding 0.41.0 (57) qualification

Version: `0.41.0`; build: `57`. NativePCM16FLACWriter reuses NativePCM16WAVWriter.EncodedAudio and the existing admission error. It emits one STREAMINFO and independent verbatim PCM16 channel subframes, nominal 4,608-frame blocks with an unpadded final block, whole PCM MD5, CRC8 headers and CRC16 frames. DocsToolPack.audioWrite dispatches exact wav/flac while retaining before/after context checks and the pinned Data publication owner. No AudioFile encoder, codec process, service or dependency is added. The 59-method source area passed before the identity advance and the matching canonical native selection passed on .41/57 inputs. App/CLI and the bounded Qwen API workflow passed; three actual product outputs passed Apple whole PCM consumers. These tests do not establish general lifetime or interoperability. [Audio contract](NATIVE-AUDIO-WRITING.md).

## Preceding 0.40.0 (56) qualification

Version: `0.40.0`; build: `56`. NativePAXTARWriter preflights complete per-file PAX/USTAR extents before payload/output allocation. NativeGZIPArchiveWriter wraps that bounded TAR in one system-zlib member with pinned call-local storage, bounded allocation and row/chunk/native-call cancellation checks. Existing ZIP/Office bytes, Docs context-before/after checks and the pinned publication owner stay intact. Native mechanism cleanup witnesses do not qualify product in-work or shared late-cancel/revocation-before-rename paths. [Contract](NATIVE-ARCHIVE-WRITING.md).

Separate G3 source/native checks passed once each, giving 26 distinct methods per route with the prior 25; hygiene/whitespace passed. The initial zero-selection native attempt remains NONPASS. Final C2 passed as a reread of unchanged C1 binaries with only two G3 assertions changed in the source map; initial owner source/wiki publication, readback and clean synchronization passed; exact revisions are retained in the external delivery receipt.

## Preceding 0.39.0 (55) qualification

Version: `0.39.0`; build: `55`. NativePCM16WAVWriter preflights strict scalars, canonical base64, complete PCM16LE frames and the exact 44+raw output extent. A call-local worker appends explicit RIFF/WAVE bytes and bounded PCM chunks with existing cancellation checks. DocsToolPack.audioWrite validates project context before/after encoding and publishes through the existing pinned Data writer. Own grants, mutation/context, replay, defaults and document telemetry remain in their existing owners; no AudioFile handle, codec service or dependency is added. [Audio contract](NATIVE-AUDIO-WRITING.md).

The original absent-definition NONPASS remains. Actual source 48 owning plus 24 separate preservation methods match 72 passed canonical native methods; build/signature, App/CLI wire and Qwen write/read consumption also passed. Both public native URL consumers passed seven small product WAVs with exact PCM/EOF and successful handle closure. Initial G3 and final prose hygiene/whitespace passed; source/wiki delivery remains pending. [Qualification](QUALIFICATION-STATUS.md).

## Preceding 0.38.0 (54) qualification

Version: `0.38.0`; build: `54`. NativeStoredZIPWriter preflights names/base64 and complete ZIP extents before allocating output. A call-local worker computes CRC32 and appends stored local/central/EOCD records under fixed caps/cancellation checks. DocsToolPack validates context before/after encoding and publishes through the existing pinned Data writer. Grants, mutation/context, replay, defaults and document telemetry use their existing owners. No dependency or service was added.

Exactly two graph memberships add the writer and its tests. [Archive contract and evidence](NATIVE-ARCHIVE-WRITING.md).

Focused source/native evidence comprises 62 owning methods plus a separate initial G3, giving 63 distinct methods per route. Signed App/CLI archive transcripts, Qwen actual result consumption and separate App BSDtar payload extraction passed within their isolated scopes. Final document checks and exact source/wiki delivery are recorded separately; they add no runtime coverage. Broader GUI/full-web/all-model/lifetime/shipment acceptance remains open.

Later .38 Projects v3 registered one isolated folder with matching project ID/root and generation 1, then remained NONPASS when the Save phase reached the 8,192 AX call cap after one field set and one Save press. The 303-byte metadata stayed byte-exact with no repository URL. The App quit ordinarily with exit 0 and no forced cleanup; guards and shared preferences were unchanged. Save/reopen/reject/clear and Tools remain unqualified; cause unknown.

## Preceding 0.37.0 (53) qualification

Version: `0.37.0`; build: `53`. `NativeRasterWriter.encodeICO` adds a bounded call-local Swift branch for square 16/32/48/256 images after the existing global dimension/pixel and canonical base64 admission. A 22-byte ICONDIR/entry precedes a 40-byte BI_RGB DIB, bottom-up straight BGRA XOR rows and DWORD-padded alpha-zero AND rows. Exact total output is preflighted before row/mask allocation; the existing Output owner checks cancellation/sticky errors on append and snapshot.

The branch preserves all encoded RGBA bytes; native premultiplied rendering and wire inspection are separate. DocsToolPack retains its own grant, project context, pinned writer, modes and redacted audit; only the existing format enum/path/description and ICO engine/output contract expand. No new tool, input key, framework, dependency, graph member, service, signing policy or production interpreter is added. Matching full raster source/native selections passed **56 methods** in **13.550/24.569 s**; five separate neighbors passed in **2.201/2.504 s**, giving **61 distinct methods per route**. Focused source eight is a subset and adds no distinct methods.
The common-writer late-cancel/revocation-before-rename E2 boundary remains unexercised, and no native call preemption is claimed. Candidate App/CLI/Qwen wire and seven native ICO/PNG consumer pairs passed in isolated contexts. Two immediate canceled calls were exercised per App/CLI route; cancellation after work has started and the common writer’s late-cancel/revocation-before-rename boundary remain unexercised. Final G3/hygiene/whitespace and exact owner source/wiki delivery outcomes are retained in external root receipts. Projects GitHub Save/reopen/stable identity and filtered Tools web rows remain blocked by the retained CUA native-pipe failure; installed/full-web/all-model/managed-adapter/other-format/Release/shipment gates remain open.

Current candidate identity is the separately preserved ordinary Debug **f477a0b0…**. After the native G3 test action re-signed the prior main, the restored App passed a fresh **0.849 s** run with all **11 artifacts byte-identical** to the original App outputs; the six other compiled artifacts remain exact. Earlier CLI/Qwen and native-consumer results are reused only on the unchanged CLI/core and generated artifact inputs, with no new model or native-consumer invocation. Original candidate/signing evidence remains historical; the current transition is detailed in [the image guide](NATIVE-IMAGE-WRITING.md). Final document recheck and source/wiki delivery outcomes remain in external root receipts.

## Preceding 0.36.3 (52) decoded UTF-8 web qualification

Version: `0.36.3`; build: `52`. `WebToolPack.maximumUTF8ContentBytes` bounds
text/source content and cursor validation at three times the existing 1 MiB
receive limit. Base64 cursor validation retains the raw 1 MiB limit. The
`web.fetch` descriptor advertises the decoded upper bound and describes both
units. After text conversion, the existing owner checks UTF-8 content size before
digest and paging; in-content UTF-8 boundaries still apply.
The observed Latin1 failure advertised a decoded cursor above the old raw-byte
input cap, then rejected the continuation. Matching 28 source/native web methods
passed; no new tool, decoder, cache or grant is introduced. Continued pages
retain existing request ownership, including their refetch.
Final MCP sizing, SHA/cursor semantics, deadlines/cancellation, context and notice
contracts remain. [Contract and evidence](WEB-RESPONSE-BUDGET.md) retain exact
window scope. Four source/native neighbor methods and candidate builds/signature
also passed. App/CLI exercised the corrected cursor and all three public web tools;
Qwen consumed their complete results. Its original final-format NONPASS and
separate raw-JSON correction remain separate. Initial G3 adds one method to the
32-method union. GUI attempts remain NONPASS after deadline/CUA pipe failure,
with Projects and filtered Tools checks blocked. Final document check results are recorded in external root receipts, with delivery identities external.

## Preceding 0.36.2 (51) status-build qualification

Version: `0.36.2`; build: `51`. `AgentToolPack.forgeStatus` adds the string
`build` field beside `version` from `ForgeApp.buildVersion`. Both status aliases
route through that common success payload. `MCPToolResponse` serializes the same
payload into first text and `structuredContent`; input schemas and tool names stay
unchanged.
`ToolInvocationBroker` returns completed durable results unchanged, so historical
replays may omit `build`. No repository/session/storage migration is introduced.
Matching six-method source/native and signed App/CLI/Qwen status checks passed.
Native text and structured payloads matched; Qwen consumed the two actual alias
results. Initial G3 gives seven distinct methods per route. Exact document and
publication identities belong in external closeout receipts;
[qualification status](QUALIFICATION-STATUS.md) retains open gates.

## Preceding 0.36.1 (50) instruction-count qualification

Version: `0.36.1`; build: `50`. The common instruction-package `makePackage`
boundary rejects more than 4,096 retained documents before hashing, publication
or queue linkage. ZIP containers and manifests count toward that existing
catalog bound. Single-file, folder and composite-run callers retain their
contracts; queue/catalog schemas, project scope, grants and storage ownership
are unchanged. Existing oversized persisted snapshots are not migrated.

## Preceding 0.36.0 (49) BMP qualification

Version: `0.36.0`; build: `49`. BMP selects native `UTType.bmp` in the
existing call-local raster path, reusing sRGB/straight-alpha input, one image,
retained-consumer rollback/release and the bounded first-error output owner.
Docs routing adds explicit `.bmp`; no default, common writer, grant, replay,
schema field, settings, project format, dependency or graph owner changes.
Encoded V5/BITFIELDS channel fidelity is separate from native premultiplied
rendering, and an sRGB marker does not promise embedded ICC.

The missing-feature baseline executed one BMP method and failed normally in
**5.746 s** with `invalidFormat`; that original failure remains **NONPASS**.
The eight new BMP methods and one existing catalog method then passed in
**13.457 s**, normal exit 0/unforced, zero failures/skips. Focused nine is a
subset of the owning selection and adds no distinct coverage.
Owning source **233 distinct methods** passed in **77.769 s**; canonical native
passed the exact same **233** in **76.830 s**, zero failures/skips, normal exit
0/unforced. Both exclude G3 and bind the same **464-input 0f204bd3… map**.
CLI/app compilation passed in **0.894/0.894 s**. Ordinary Debug and strict
candidate signature passed in **26.025/0.140 s**, normal exit 0/unforced, on
the same source map. Signed App/CLI wire controls passed in **1.264/0.799 s**,
normal exit 0/unforced: **34 native responses/32 tool frames/10 artifacts**
per route. Qwen passed in **32.566 s**, normal exit 0/unforced: three actual
Low-mode API responses consumed two selected native write/read results,
**8 native responses/6 tool frames/2 artifacts**, with a strict four-scalar
metadata ACK. The separate external native candidate-artifact consumer compiled
in **1.969 s** and passed in **0.364 s**, normal exit 0/unforced: **seven
BMP/PNG pairs/fourteen native images**, matching sRGB profiles/premultiplied
renders and one release callback per provider.
Initial-document G3 passed once in source/native (**1.439/1.767 s**), normal
exit 0/unforced, zero failures/skips, on the same **464-input 0f204bd3… map**.
The exact owning 233-plus-one G3 unions match at **234 distinct methods per
route**; this was not one 234-test invocation. Initial hygiene/whitespace
passed (**0.679/0.136 s**), normal exit 0/unforced. Repeated focused/G3
checks add no distinct coverage.
The native owning run retains eight linkd NSCocoaErrorDomain4097 diagnostics;
the native G3 run retains DVTAssertionsWarning IDELaunchSession.m:395.
Final-document G3 source/native one each passed (**1.535/1.748 s**);
hygiene/whitespace passed (**0.672/0.132 s**), normal exit 0/unforced, on the
same 464-input map. These repeated G3 checks add no distinct methods.
No diagnostic-free claim follows. Later document rechecks and exact source/wiki
publication, readback and synchronization require separate external receipts;
this checkpoint claims no unrun result.

The original ImageIO BMP/ICO collection remains NONPASS because nine ICO
encodes failed. A separate whole-PNG ICO-wrapper native collection also remains
NONPASS because nine decodes returned no detected ICO type/count zero; only the
examined 256×256 case passed. These are separate attempts, not a diagnosed
dimension rule. A third DIB+AND native probe also remains NONPASS: nine of ten
DIB cases failed, only opaque 256×256 passed, and two public type-hint controls
preserved the 1×1 failure/256×256 pass; no dimension/length cause is established.
ICO, audio, archive/SQLite and other requested formats remain
open. Pre-cancel tests do not prove native-call preemption; common-writer
late-cancel-before-rename/revocation remains unexercised source E2.
The installed .18.0/build-28 application and registrations remain unchanged.
Installed GUI, production managed-adapter, full web, all models, Windows
interoperability, Release and shipment remain open.

[BMP contract and gates](NATIVE-IMAGE-WRITING.md).

## Preceding 0.35.0 (48) WebP qualification

Version: `0.35.0`; build: `48`. The call-local Swift VP8L literal writer owns
one bounded output `Data` and a partial byte. Complete size is preflighted
before allocation; alpha scanning, pixel/output work and completion check
cooperative cancellation. Exact decoded file RGBA includes hidden transparent
RGB; native premultiplied rendering is a separate PNG-reference comparison.
No dependency, graph member, new tool/grant, signing change or embedded ICC is added.
PNG/TIFF/JPEG/GIF and common pinned-write ownership remain.
Owning source **225 distinct methods** passed in **75.739 s**; canonical native
passed the exact same **225** in **75.173 s**, zero failures/skips; those owning selections exclude G3.
CLI/app compilation **0.900/0.893 s**, ordinary Debug **26.412 s** and strict
candidate signature **0.143 s** passed on the receipted **464-input ce81874f… map**. G3 expectation alignment produced test-only map 6dcfd15c…; these receipts retain
their immutable ce81874f… inputs.
Signed App/CLI each passed **15 groups/32 responses/30 tool frames**, full EOF.
Actual Qwen completed three normal Low API responses and consumed two write/read
results; its strict final acknowledgement matched 194-byte/2×2 artifact metadata.
Seven production WebP/PNG native comparisons passed; decoded sRGB profiles and
premultiplied renders matched the references. Initial-document G3 passed once
in source/native (**5.514/5.334 s**), establishing matching **226 distinct methods**
per route with the earlier 225; this was not one 226-test invocation. Focused
seven and repeated checks add no distinct coverage.
Installed GUI, production managed-adapter, full web, all models, other formats,
Release and shipment remain open.
Middle-of-bit-loop cancellation is not deterministically exercised. Common-writer
late-cancel-before-rename/revocation remains unexercised source E2; this is no
performance or product leak claim. Final-document G3 source/native one each passed (**1.438/1.867 s**), adding no
distinct methods; hygiene/whitespace passed (**0.673/0.133 s**), normal exit 0/unforced.
Exact source/wiki publication, readback and synchronization outcomes are retained in external closeout receipts.
[WebP contract and gates](NATIVE-IMAGE-WRITING.md).

## Preceding 0.34.0 (47) GIF qualification

Version: `0.34.0`; build: `47`. GIF extends the call-local ImageIO path,
rejecting alpha 1...254 before encoding/writing and normalizing only a finalized
GIF87a signature to GIF89a. The source/native header method verified identical
subsequent bytes and native consumer pixels. Palette RGB and hidden transparent
RGB have no exact-output promise; sRGB interpretation has no embedded ICC promise.
Existing bounded output, worker, context and pinned-write owners remain, with
PNG/TIFF/JPEG and graph membership preserved.
Source **218 methods plus one separate G3** and canonical native **219 distinct methods** passed with matching method sets and zero failures/skips. Direct builds, strict candidate, signed App/CLI controls and actual Qwen consumption passed within the bounded GIF scope.
Native-call preemption and late-cancel-before-rename/revocation remain unexercised;
the latter remains common-writer source E2.
Final-document G3 and exact source/wiki publication, readback and synchronization are tracked in external closeout receipts.
Installed GUI, production managed-adapter, full web, all models, other formats, Release and shipment remain open.
[Contract](NATIVE-IMAGE-WRITING.md).

## Preceding 0.33.0 (46) JPEG qualification

Version: `0.33.0`; build: `46`. JPEG extends the call-local ImageIO path
with fixed quality 1.0 and no thumbnail, remaining lossy. The worker validates
canonical straight RGBA8/sRGB and rejects any alpha byte below 255 before native
encoding or destination writing. The existing bounded first-error output owner,
project revalidation and pinned writer remain; PNG/Swift TIFF paths are preserved.
No new service, runtime, dependency or graph membership is introduced.
Matching owning source/canonical native selections passed **210 distinct methods** each, zero failures/skips; CLI/app compilation and ordinary Debug passed.
Strict candidate, signed App/CLI controls, independent raw JPEG inspection and Qwen API consumption passed.
Final-document G3 passed in source and native. Source/wiki publication, readback and synchronization are tracked in external closeout receipts. [Contract](NATIVE-IMAGE-WRITING.md).
Native-call preemption and late-cancel-before-rename/revocation common-writer
behavior remain unexercised; the latter is a source E2 boundary, not a runtime
failure or completion claim.

## Preceding 0.32.0 (45) TIFF qualification

Version: `0.32.0`; build: `45`. TIFF uses a call-local native Swift classic
writer with uncompressed straight RGBA8, top-left chunky strips, unassociated
alpha and native CoreGraphics sRGB ICC data. Total output is preflighted; the
bounded first-error output owner checks cancellable 8,192-byte pixel chunks.
PNG retains its ImageIO path. Existing worker, project-revalidation and pinned-write
owners remain; no new service, runtime or dependency is introduced. Source/native
203 each, direct builds, strict candidate and scoped App/CLI/artifact/Qwen checks
passed. Final document G3 passed source/native. Exact source/wiki publication/
readback/synchronization identities will be retained in external closeout receipts. [Contract](NATIVE-IMAGE-WRITING.md).

## Preceding 0.31.0 (44) PNG qualification

Preceding version: `0.31.0`; build: `44`. PNG creation uses a call-local CoreGraphics
image, ImageIO destination and bounded native data consumer on the existing
worker path, then the existing project-revalidated pinned writer. No new service,
application runtime or dependency is introduced. Source/native selections each
passed 198 distinct methods; CLI/app compilation and ordinary Debug build passed.
Strict candidate and scoped App/CLI/artifact/Qwen API checks passed. [Contract](NATIVE-IMAGE-WRITING.md).

## Preceding 0.30.0 (43) ODS qualification

Preceding version: `0.30.0`; build: `43`. ODS uses bounded call-local Swift encoding and
native XML cell extraction under existing tool and pinned-write owners. Scoped
checks passed; saved packages require reimport. [Contract](NATIVE-ODS-WRITING.md).

## Preceding 0.29.0 (42) PPTX qualification

Preceding version: `0.29.0`; build: `42`. PPTX uses a call-local native encoder and
bounded slide-text reader with existing tool and pinned-write owners. The writer
shares the reader's 32,768-element slide limit. Conflicting XML encodings and
duplicate expanded attributes are rejected; new document arrays are audit-redacted.
No new service, runtime, dependency or storage format. Source/native 166 each and
scoped runtime consumers passed. [Contract](NATIVE-PPTX-WRITING.md).

## Preceding 0.28.0 (41) XLSX qualification

Preceding version: `0.28.0`; build: `41`.

XLSX encoding uses a bounded call-local Swift writer on the existing worker path
and pinned destination writer. Import uses bounded Foundation XMLParser cell
extraction. Source/native 124, build/signing and scoped wire/Core/Qwen flows passed;
[contract and remaining gates](NATIVE-XLSX-WRITING.md).

## Preceding 0.27.1 shutdown ownership

Repeated subsystem shutdown retains its completed result on the existing repository
actor while incomplete shutdown remains retryable.
[Ownership and evidence](ORDINARY-RUNTIME-CONTINUATION.md#repeated-subsystem-shutdown).

The following DOCX architecture/evidence retains its preceding .27.0/39 inputs.

The app owns one queue-free native DOCX exporter. The exact fixed child mode
runs before ordinary configuration/UI bootstrap, preserves compiled CLI/App
role and named Core admission, and serializes through AppKit on a worker.
The parent admits only complete bounded output with confirmed termination and
both EOFs before the existing pinned writer can touch the destination.
Unconfirmed termination retains the slot; shutdown uses the original operation
deadline. Security validation and synchronous AppKit serialization are not
individually cancellable, and the encoded cap is checked after AppKit allocates
the output. This is not a hard CPU/heap/preemption guarantee.
The operation end uses a monotonic entry sample before reading remaining time;
the retained first sixteen-method run observed a 375 ns overshoot with the
previous ordering. Two boundary methods and the same four corrected regressions
passed separately. Current source 154 plus G3 and the same compiled native 155
passed, including all 21 new cases, zero failures/skips on unchanged 450 inputs.
CLI/app, ordinary Debug, strict seven-binary candidate and existing memberships
passed. Actual App/CLI wire, independent artifact/native import, production Core
consumer and fresh Qwen R2 gates passed on the same inputs. These bounded flows
do not establish framework preemption, peak allocation or full Office fidelity.
[Contract](NATIVE-DOCX-WRITING.md).

The following notice-receipt evidence retains its preceding .26.2/38 map.

The stdio writer returns completion only after its encoded JSON plus LF has
been written. Closed-delivery guards return false; existing write errors still
throw. Both notice receipt sites commit only complete output and discard
skipped/error output. The handler result remains authoritative; reader-error,
shutdown-timeout and worker-error precedence is unchanged. The 92 owning source
and same 92 native methods passed on their original 450-input map, including
EOF/EPIPE failures, complete-packet presentation and durable-ledger parity.
A later test-only priority correction passed the same one source/native case;
original runtime diagnostics remain. CLI/app, version/graph, final ordinary
Debug build and strict signing passed. The final candidate has its own manifest;
the first .26.2 candidate was superseded after signature replacement.
[Contract](WEB-RESPONSE-BUDGET.md#notice-receipt-truth-follow-up).

The following web-budget evidence retains its preceding .26.1/37 map.

For `web.fetch`/`web.search`, an internal non-escaping router callback captures
the exact context after deadline configuration and binding validation, before
dispatch. MCP final sizing uses that scope's allowance and the actual ID, policy
notice, duplicated payload and terminating LF. Only successful content/results
are reduced; fetch whole-content digests and byte cursors, search order and
existing failure/control fields remain. No grant, network, HTTP-task or public
API expansion is added. The 139 source and same 139 compiled native cases,
ordinary Debug build/strict signing and four native wire cases passed. Native
runtime diagnostics remain; Qwen completion is OPEN/NONPASS. [Contract](WEB-RESPONSE-BUDGET.md).

The following ordinary-runtime evidence retains its preceding .26/36 maps.

Ordinary MCP runtime submissions now persist the selected job UUID through a
separate Source callback inside the CP submission transaction, before COMMIT.
Same-connection full binding validation and a one-use Source epoch fence apply
on both new-job and idempotency paths; callbacks are absent from reconstructed
pending execution. Native references are limited to 32 attempts/16 KiB per epoch
and merged into packet saves under the existing Source lock. No schema or journal
migration is added. Resume derives current-authorized status from the exact native
packet before epoch reset; unavailable rows remain unresolved without replay.
Same-ID sealed authored edits preserve their native origin/reference extension.
[Contract and original failure](ORDINARY-RUNTIME-CONTINUATION.md) separate source
implementation, first compile/regression passes and 24 later focused source
passes from the retained first owning-area NONPASS and later three-method
budget/unavailable-reader repair pass. Earlier source 309 distinct methods,
including actual separate Manager/version checks, and ordinary native Debug
build passed. Native 309 also passed with three QoS diagnostics; only two test
dispatch priorities changed, followed by warning-free source 4/native 4 and an
ordinary Debug confirmation. Full 309 retains its earlier fixture map; the
existing DiagnosticLog warning remains a profiling target. Strict Debug artifact
binding, two isolated native MCP scenarios and a fresh Qwen API case passed.
The first fenced-JSON Qwen NONPASS remains. A later isolated two-helper E0
baseline shows fallback status entering startup recovery while the primary owns
live work: its `/bin/sleep 30` child was gone and the row failed runtime_owner_restarted
after 0.713 s while the exact primary parent stayed alive. Collection succeeded;
the feature contract failed; that original receipt remains NONPASS.
The repair owns a private kernel runtime lifetime lease before artifact reservation/spool creation/CP
queued COMMIT. Startup recovery, artifact sweeps and cleanup debt take the
same lease and skip verified foreign owners. Authorized warm status/output/cancel
and selected list-page reads reserve one recovery operation, claim ownership,
requery current scope and use the existing persisted-identity reaper without
replaying requests. List filters/cursor are rerun after recovery. Native cleanup
awaits one bounded utility probe callback per iteration, including after caller
cancellation; it adds no recurring producer or retention history.
The runtime owner repair is now applied. The final source selection passed
**321 methods** without failures, skips or compiler warnings on its unchanged
450-input map. The separate ordinary canonical Debug build passed in 24.992
seconds. The same **321 native methods** passed without failures/skips, retaining
one existing DiagnosticLog:64 runtime QoS warning. Strict Debug verification of seven binaries
and build binding, plus repeated signed live-owner, warm-crash and two
continuation cases passed on the final map. Fresh Qwen consumption passed three
actual Low/API rounds and four verified calls with exact job/output/task recovery
and no replay. Earlier passes retain their earlier maps. Exact direct publication and synchronization revisions are retained separately
in `runtime-continuation-publication-and-synchronization-026.json` after the update.
Budget reuse requires an unsealed eligible origin; otherwise a fresh ID clones
authored content while prior same-ID native origins remain preserved. Installed .18 and the 54 capability/full-web/PDFKit/all-feature gates remain separate.

The preceding 0.25 PDF repair keeps the existing document tools and atomic destination write,
using CoreText glyph/metric layout and a per-call CoreGraphics output consumer
with a new 64 MiB retained-output cap. The shared `NativePDFTextReader` owns its
native parser/scanner resources per invocation, admits a complete flat tagged-text
subset and applies cumulative decode/operator/array quotas. It adds no cache,
timer or service. Instruction imports and policy-source indexing retain existing
PDFKit fallback and durable records; accepted logical text has new converter
provenance. The corrected owning-area selection passed 101 source methods and the
compiled native selection passed 102 tests on the original 450-input PDF snapshot.
Strict Debug/Release signing/build binding and separate Qwen PDF-tool consumption passed.
Independent r6 validation passed 82 controls (fourteen admissions and sixty-eight
whole-document fallbacks) and all eight Debug, eight Release and two Qwen artifacts.
The original 80 expectations and scalar markers remain unchanged. The external
operand ceiling increased from 4,096 to 32,768 with two new exact boundary controls;
its counter population differs from the production reader. It does not qualify
glyphs or PDF tagging conformance. Native PNG review covered ten Release and two Qwen
PNG pages. PDFKit compatibility remains open. The PDF source/wiki checkpoint was
published and synchronized. A later test-only immutable fixture capture correction
passed the freshly compiled UTF-8 regression and all 19 writer methods without the
original warning. It changes no production ownership, resource boundary, graph or
product identity; original candidate receipts retain their original test hash. This
test/documentation closeout was delivered and synchronized with clean 0/0
source/wiki divergence; [exact preceding refs](ORDINARY-RUNTIME-CONTINUATION.md#preceding-pdf-delivery)
retain that receipt. The scope, unresolved optional
root-field ambiguity and retained PDFKit order failure are in [native PDF writing](NATIVE-PDF-WRITING.md).

## Preceding 0.24.0 listing boundary

The preceding listing work adds opt-in, per-call `fs_list` continuation and a
paged-list-only final stdio budget check. The helper scans direct names with a
bounded raw-byte selector, has an explicit per-call directory owner with
idempotent close/deinit fallback, and revalidates observed directory metadata
and project context before delivery.
It adds no persistent cursor index, watcher, cache or child process. Existing
path-only listing, owner read access and tool grants remain separate preserved
surfaces. Original paged arguments are checked before path normalization, and
the MCP reader checks original paged count tokens across its three framing
branches. Final checks passed 173 source cases and the same 173 compiled Core
cases. The close regression observes one successful `closedir` on four paths;
it is not a whole-process leak qualification. Signed Debug/Release listing and
renderer matrices passed, and Qwen consumed actual continuation pages. The
retained failed attempts, runtime scope limits and open installed/notice gates are in
[filesystem list paging](FILESYSTEM-LIST-PAGING.md).

## Preceding 0.23.0 renderer boundary

The preceding 0.23.0 slice adds `ForgeApp`-owned JavaScript rendering through a
bounded fixed-mode signed native child and preserves request deadlines through MCP
response-context lookups. Its ownership, protocol and verification scopes are
recorded in [native web rendering](NATIVE-WEB-RENDERING.md). Earlier receipts
retain their tested identities and scopes.

Forge Conductor is a native macOS control plane and MCP server for work carried
out in externally owned model conversations. The current LM Studio workflow
begins in the normal LM Studio chat interface. Forge supplies project-scoped
files, instructions, memory, Development Policy governance, tools, and
automatic continuity.

## Design rules

1. `ForgeConductorCore` owns reusable domain, persistence, application, MCP,
   provider, Manager, and telemetry services.
2. `ForgeConductorApp` owns native SwiftUI/AppKit presentation and bounded Metal
   gauges.
3. Dependencies point inward through Swift protocols; host and filesystem
   effects are injected ports.
4. Project authority is bound to stable project identity and generation.
5. Queues, caches, histories, logs, retries, output, and recurring work have
   explicit limits and shutdown owners.
6. Manager mutations use authenticated loopback routes; model tools use stdio
   MCP and cannot obtain Manager credentials.
7. Provider readiness, stored configuration, and live host behavior are
   separate evidence boundaries.

## Product composition

| Component | Responsibility |
|---|---|
| `ForgeConductorCore` | Domain models, SQLite and file persistence, project services, tools, provider preparation, continuity, CLU, Manager, telemetry |
| `ForgeConductorApp` | Native operator interface and lifecycle binding |
| `ForgeConductorCLI` | Install, doctor, status, Manager, and stdio MCP entry points |
| `ForgeNativeSessionHostPlugin` | Statically registered supported host boundary for automatic successor creation |
| Runtime launcher | Bounded signed native process execution for retained low-level services |
| Filesystem daemon | Versioned privileged filesystem boundary |

The canonical native graph is `ForgeConductor.xcworkspace` and its existing
Xcode project. SwiftPM compilation is useful evidence but is not a substitute
for the signed app build.

## Manager ownership

`ManagerNode` is the single owner of the authenticated loopback control surface
and its watchdogs. The GUI either attaches to the existing current Manager or
starts a local one. Provider configuration, project mutation, policy catalog
changes, exports, cache maintenance, and operator snapshots use bounded typed
Manager routes.

The Manager owns the interactive-continuity schedule and invokes the statically
registered native session host adapter. That adapter uses
`LMStudioGUIChatDriver` and public macOS Accessibility controls to create a
foreground LM Studio successor. Provider operations also use CLI, REST, and MCP
boundaries. Source support and historical host receipts remain separate from
current live-host qualification; see the
[runtime repair record](LMSTUDIO-RUNTIME-REPAIR.md).

## Project and instruction ownership

Project registration canonicalizes a selected folder, establishes stable
identity and a default working directory, and advances a generation on reset.
Multiple projects may be active, but their memory, instruction artifacts,
policy logs, continuity, and durable activity remain isolated by identity and
generation. Registration does not create a filesystem access boundary.

`ProjectInstructionQueueStore` imports files, folders, archives, and supported
documents into immutable content-addressed snapshots. The durable order shown
in Projects is authoritative. Drag reordering is revision-checked so stale UI
snapshots cannot overwrite newer state. The model queries bounded catalog and
content pages after calling `get_forge_status`; package selection does not
start a model conversation, and artifact reads require the attached project and
generation rather than a Managed Run.

## MCP and tool authorization

LM Studio starts Forge's versioned stdio MCP registration. `get_forge_status`
is available without a Managed Run and returns registered project identities,
query tools, the selected project's file, instruction, and continuity
locations, and the ordered active Development Policy source paths. Its required
bootstrap action directs the model to read those sources in priority order and
follow their applicable requirements before development changes. `resume=true`
requests the latest resume-ready handoff.

Filesystem, Git, shell, memory, instruction, policy, and continuity tools pass
through the same authorization layer. Project-bound calls require a valid
project identity and generation, and tool grants and the shell enable switch
still gate dispatch. For native filesystem, Git, shell, PDF, search, and
runtime calls, an absolute path may be outside the selected project folder.
Forge canonicalizes the path but does not wrap the command in a Seatbelt
profile. macOS attributes TCC access to the responsible signed host and
executable in the actual launch chain; Forge does not infer Full Disk Access
from a parent UI grant. The exact signed candidate must pass a live protected-
path read after relaunch, without exposing file contents. Ordinary POSIX and SIP
constraints remain in force.
Selected project roots supply registration identity and the default base for
relative paths, not access confinement.

Runtime jobs retain the signed launch gate, process-group ownership, deadlines,
output and environment bounds, cancellation, and durable result fencing. A
bounded libproc tracker records start identities and cleans up observed children
that leave the process group with `setsid(2)` or `setpgid(2)`. The normal
per-job descendant budget is 16, with an absolute 1,024 retained-identity cap.
Crossing either boundary produces a typed terminal failure; sticky capacity
evidence does not prevent terminalization after every retained identity exits.
If termination cannot be confirmed, the job releases live ownership as a
bounded cleanup debt with a retry deadline and one identity-fenced startup
retry. A reused PID is never signaled. Public macOS process snapshots are not
atomic and the out-of-group tracker is not durable across a Manager crash;
unrestricted same-user code that escapes entirely between observations remains
an explicit native-shell trust boundary.
Xcode job receipt ceilings include the complete canonical durable wrapper before
admission. `job.list` returns complete rows within that byte budget and an
optional paired timestamp/UUID cursor (`before_created_at`, `before_job_id`),
ordered by timestamp then ID. Timestamp ties remain traversable; legacy
exclusive timestamp-only cursors are unchanged. Byte-paged output and base64
recovery retain their existing contracts.

Filesystem delete and move retain explicit protection against `/`, user and
Manager homes, mounted-volume roots, active workspace roots, and any ancestor
whose removal would contain one of those roots. Authorization performs the
first check; local execution independently reconstructs that set, pins the
source by descriptor identity, and compares it against every protected root and
ancestor again immediately before delete or move. Changed parents, case aliases,
blank operands, and an uninspectable protected identity fail closed. In-project
delete and move may use the signed generation-fenced filesystem helper; paths
outside a declared project root use the bounded local implementation. Memory,
instruction, policy, and continuity APIs remain project/generation scoped, but
an owner-authorized unrestricted shell is not a physical secrecy boundary for
same-user files backing those services.

## Provider ownership

The Responses REST transport owns a private finite 5,120-event SSE work budget
for content and lifecycle frames. The public decoder retains its 4,096-event
default and initializer contract. Independent line/event/response/text/argument,
output-token and timeout guards remain at their existing owners. The event cap
is a numeric work bound rather than a token-to-frame guarantee; response
completion and exact acknowledgement remain required.

Provider selection, LM Studio **Connect and Check**, the Advanced connection
check, and probe converge on one Manager preparation path. That path validates
Manager authentication, the saved endpoint, optional credential, supported CLI
recovery, loaded inventory, exact model selection, and tool contract. It does
not start or resume model work.

Claude Code Desktop and Codex Desktop retain ownership of their conversations,
model selection, permission prompts, and reload requirements. Forge modifies
only supported Forge-owned plugin, hook, and MCP artifacts. Grok Build remains
non-selectable.

## Automatic continuity

The status tool refreshes persisted configuration before reading continuity
policy, preserving staged patches. A refresh failure returns explicitly marked
cached settings and a bounded diagnostic so recovery remains available. Audit
and queue storage initialization preserves directory and permission contracts
without creating default configuration; app/config initialization owns defaults.

The ordinary LM Studio model writes compact checkpoints and a resume-ready
handoff at context pressure. The authoritative handoff commit precedes any host
effect. A request arriving during checkpoint preparation stays sticky without
rewriting the live claim. SQLite consumes it with the actual packet, counts,
progress pointers and hard block in one transaction; rollback retains it for
restart recovery. Projection failure reports committed SQL truth. Manager then
exposes a 30-second Dashboard countdown.

At expiry, the statically registered LM Studio host adapter:

1. resolves or creates one successor identity from a stable idempotency key;
2. activates LM Studio and presses its public Accessibility **New** control;
3. fills the visible Chat input with `get_forge_status`, `resume=true`, the
   exact handoff ID, and a deterministic nonce, then presses Send;
4. observes the installed GUI MCP tool's exact nonce-bound receipt;
5. validates the exact handoff identifier in that receipt;
6. durably records acknowledgement and predecessor sealing; and
7. reuses the same identity after retry or Manager restart.

The V1 native adapter has bounded per-instance live-bootstrap ownership. It
rejects duplicate same-session intent replacement and revalidates current owner,
status, exact handoff ID/digest and cancellation after the transport await before
persisting acknowledgement. Same-ID changed-content receipt reuse is refused;
cold interruption/restart retry remains available. Existing V2 cancellation
contracts and the ledger/schema/public fields are unchanged. These source and
protocol controls do not establish current ordinary GUI rollover or GUI overlap.

The adapter ledger and GUI intent/submitted records are bounded and owner-only.
A host failure retains the same handoff and publishes a bounded redacted
diagnostic. The adapter uses no REST integrations array and does not store a
same-host LM Studio credential.

The Continuity UI does not drive this state machine. It is limited to a
scrollable project-ID list, Copy, and confirmed project-scoped Delete.

## Rune Forge and CLU

Rune Forge admits user-selected policy files and folders immediately, then
catalogs them through bounded durable work. The user-selected order is persisted
and defines priority.

CLU observes model and tool activity without entering the canonical
authorization/result path. It evaluates ordered policy, appends immutable
project-scoped violation history, reserves retry-stable notices, and adds a
notice to the active model response containing the exact policy identity and
bounded applicable policy content. Export takes a stable upper event sequence
and atomically writes JSONL, JSON, Markdown, or CSV.

Policy failure is visible and fail-forward: it cannot silently authorize a
tool, mutate a canonical result, or take over task execution.

## Telemetry and gauges

Telemetry producers use one bounded delivery boundary: at most one in-flight
main-actor delivery and one replaceable latest snapshot. Sequence numbers and
coalescing counters expose stale or dropped delivery.

Dashboard resolves its tracked project from current live MCP presence and the
matching active durable `mcp_client` binding. Recent activity orders multiple
live clients; heartbeat order is the deterministic fallback. An exact
nonterminal run is used only when no live binding resolves, and registration
alone is never presented as an active project.

Hidden or detached gauges perform no recurring render work. Visible gauges use
a bounded cadence and shared immutable Metal resources. Mutable buffers are
reused and shutdown cancels all recurring work.

## Persistence and recovery

SQLite is authoritative for project memory, control-plane state, policy logs,
and continuity. Owner-only JSON and Markdown files are either configuration,
bounded ledgers, or rebuildable projections. Mutations use transactions or
atomic file replacement. Recovery resumes durable transition state rather than
inventing completion.

The disposable cache is a separate real directory beneath the application
home. Clearing it validates that boundary and recreates only the required cache
subdirectories; it does not delete projects, instructions, policy, memory,
credentials, continuity, or diagnostics.

## Compatibility boundary

Low-level managed-runtime and run-record types remain for stored-data
compatibility, native validation, and reusable bounded execution services.
They are not the current user launch workflow, are absent from primary
navigation, and cannot serve as acceptance evidence for the roadmap.

## Trust boundaries

- Loopback HTTP binds only to local addresses and requires the owner credential
  for mutation.
- Stdio MCP tools never receive that credential.
- Credentials remain in Keychain or owner-only stores and are redacted from
  snapshots, logs, and exports.
- Provider and desktop-host installation changes are revision-fenced and
  limited to Forge-owned artifacts.
- Privileged filesystem operations use the versioned signed helper contract.
- Native model tools deliberately inherit host access; project selection is not
  represented as a security sandbox.
- No private desktop UI automation is used.

## Qualification boundary

Compilation, deterministic tests, current-candidate native UI behavior, live LM
Studio behavior, signing, notarization, Gatekeeper, privileged-service health,
hardware coverage, and owner acceptance are distinct gates. The current release
state and exact owner-defined workflow are recorded only in
[ROADMAP.md](../ROADMAP.md).

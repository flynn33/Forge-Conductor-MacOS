# Forge Conductor user guide

Version **0.43.0**, build **59** adds `format: "m4a"` with an explicit case-insensitive .m4a destination to supplied-sample `audio_write`. Provide the existing required path, canonical padded-base64 PCM16LE content, sample_rate and channels; omit format for WAV or select exact wav/flac with a matching path. M4A uses lossy AAC-LC: decoded samples need not equal input PCM, encoded bytes may vary, and no listening/quality guarantee is made. The 1 MiB raw ceiling does not expand managed 65,536-byte JSON admission. Matching source/native owning checks and six App/CLI rate cohorts passed. All 24 actual M4A outputs passed separate native decoding to the supplied valid-frame count and true EOF; decoded PCM remains lossy. Scoped Qwen result consumption/metadata ACK and exact-artifact native valid-frame/EOF checks passed. Initial document checks and first source publication/synchronization passed; final result-document/wiki checks and delivery closeout remain pending. [Contract and gates](docs/NATIVE-AUDIO-WRITING.md).

## Preceding 0.42.0 (58) qualification

Version **0.42.0**, build **58** adds opt-in complete captured-text pages to `web.render` on macOS 27+. Start with `web.render(url="https://example.com", paged=true)`. While `has_more` is true, repeat the same URL with `paged=true`, `snapshot_id`, returned `next_byte_offset` as `byte_offset`, and `snapshot_sha256` as `if_snapshot_sha256`. The last page has `has_more: false` and `next_byte_offset: null`. The one retained snapshot expires after at most 120 seconds or is replaced by the next successful complete capture; stale continuation requires a fresh capture. The 1 MiB/65,536-node capture bound does not expand the inline response budget. Signed candidate App/CLI and Qwen v6 complete paging passed their bounded native/model matrices, including all six strict actual Low events. Earlier observer NONPASS attempts remain retained. Applied-v2 final source/native G3, hygiene and local link checks passed; final candidate v3 readback preserved source/artifact identities. First owner source/wiki publication, exact readback and clean synchronization passed. [Contract and evidence](docs/NATIVE-WEB-RENDERING.md).

## Preceding 0.41.0 (57) qualification

Version **0.41.0**, build **57** adds an optional FLAC format to supplied-sample audio_write. Use `audio_write(path="<project>/silence.FLAC", content="AAA=", sample_rate=8000, channels=1, format="flac")` for one zero mono frame. Omit format for the existing WAV behavior, or select exact `"wav"` with a matching .wav path. An extension does not select a format. The tool preserves supplied PCM; it does not synthesize or play sound. The 1 MiB raw writer ceiling does not expand managed 65,536-byte JSON admission. [Contract and scoped qualification](docs/NATIVE-AUDIO-WRITING.md).

## Preceding 0.40.0 (56) qualification

Version **0.40.0**, build **56** extends archive_write with optional exact tar/tar.gz while keeping absent/default ZIP. Use `archive_write(path="<project>/supplied.TAR", entries=[{"name":"notes.txt","content":"SGVsbG8K"}], format="tar")`, or a matching .tar.gz path with `format="tar.gz"`. These preserve supplied bytes and the own grant/context; the 1 MiB raw/2 MiB writer ceilings do not expand managed 64 KiB JSON admission. [Contract and scoped qualification](docs/NATIVE-ARCHIVE-WRITING.md).

Separate G3 source/native checks passed once each, giving 26 distinct methods per route with the prior 25; hygiene/whitespace passed. The initial zero-selection native attempt remains NONPASS. Final C2 passed as a reread of unchanged C1 binaries with only two G3 assertions changed in the source map; initial owner source/wiki publication, readback and clean synchronization passed; exact revisions are retained in the external delivery receipt.

## Preceding 0.39.0 (55) qualification

Version **0.39.0**, build **55** adds `audio_write` for supplied PCM16 WAV. `audio_write` wraps supplied canonical padded-base64 signed PCM16 little-endian bytes in WAV. An explicit case-insensitive .wav path, integer sample_rate of 8000/44100/48000 and integer channels of 1/2 are required. Nonempty PCM must contain complete interleaved frames and fit 1 MiB; complete output is 44 bytes plus PCM. Managed broker calls retain their separate 65,536-byte canonical JSON bound and require the exact audio_write grant. Use `audio_write(path="<project>/tone.WAV", content="AAA=", sample_rate=8000, channels=1)` for one zero mono frame. The tool packages supplied samples; it does not synthesize sound. [WAV limits and evidence](docs/NATIVE-AUDIO-WRITING.md).

The original absent-definition NONPASS remains. Actual source 48 owning plus 24 separate preservation methods match 72 passed canonical native methods; build/signature, App/CLI wire and Qwen write/read consumption also passed. Both public native URL consumers passed seven small product WAVs with exact PCM/EOF and successful handle closure. Initial G3 and final prose hygiene/whitespace passed; source/wiki delivery remains pending. [Qualification](docs/QUALIFICATION-STATUS.md).

The separately preserved .38/54 candidate passed the typed Projects GitHub flow: registration, canonical Save, ordinary quit/reopen, invalid-host rejection preserving the saved bytes, Clear and a second ordinary quit. Six semantic phases and five durable checkpoints passed in 11.452 s; both Apps exited 0 without forced cleanup. Project identity/generation, 52 guards and shared preferences stayed unchanged. The saved 377-byte metadata reopened byte-exact; Clear left 309 bytes without a repository URL. Earlier driver NONPASSs remain retained. This proves the isolated candidate semantic flow; pixels, external browser opening, Tools, installed GUI, full web and all models remain unqualified.

## Preceding 0.38.0 (54) qualification

Version **0.38.0**, build **54** adds `archive_write`. Supply an explicit .zip path and entries containing only `name` and canonical padded-base64 `content`. Names are virtual members; the tool reads no host files as members. Empty entries create a 22-byte empty ZIP. [Example, limits and qualification](docs/NATIVE-ARCHIVE-WRITING.md).

Signed App/CLI archive checks passed with 25 native responses/23 tool frames/four ZIPs per route, preserving six refusal gates, immediate cancellation, PNG default and the 84 prior tool definitions. Qwen completed three observed Low turns and consumed two complete actual results with a strict metadata ACK. Four actual App ZIPs passed separate BSDtar canonical-name/payload checks; CLI/Qwen extraction and broader GUI/web/install/shipment acceptance are unqualified. Exact counts, retained failures and limits are in the archive guide. Final document checks and exact source/wiki delivery are recorded separately; they add no runtime coverage.

Later .38 Projects v3 registered one isolated folder with matching project ID/root and generation 1, then remained NONPASS when the Save phase reached the 8,192 AX call cap after one field set and one Save press. The 303-byte metadata stayed byte-exact with no repository URL. The App quit ordinarily with exit 0 and no forced cleanup; guards and shared preferences were unchanged. Save/reopen/reject/clear and Tools remain unqualified; cause unknown.

## Preceding 0.37.0 (53) qualification

Version **0.37.0**, build **53** adds standard-size ICO pixel artifacts. Use `image_write(path="<project>/ICON.ico", width=16, height=16, content="<canonical padded base64 of 1024 RGBA8 bytes>", format="ico")` with its own image grant. Exact lowercase `format: "ico"` requires an explicit case-insensitive `.ico` destination and equal width/height of **16, 32, 48 or 256**. The call-local Swift writer preserves all supplied alpha and hidden RGB in one bottom-up 32-bit BI_RGB DIB with a padded AND mask. Native premultiplied rendering is separate; no embedded ICC or Windows interoperability is promised.

Input remains tightly packed top-to-bottom straight RGBA8/sRGB, with the absent-format PNG default. ICO returns `engine: "swift-ico-dib32"` and `output_contract: "ico-dib32-rgba8-srgb-v1"`; `rgba8-straight-srgb-v1` describes supplied pixels. Matching full raster source/native selections passed **56 methods** in **13.550/24.569 s**; five separate neighbors passed in **2.201/2.504 s**, giving **61 distinct methods per route**. Focused source eight is a subset and adds no distinct methods.
Source/native, signed candidate build, App/CLI/Qwen wire and separate native consumer checks passed within the image scope. Candidate App/CLI/Qwen wire and seven native ICO/PNG consumer pairs passed in isolated contexts. Two immediate canceled calls were exercised per App/CLI route; cancellation after work has started and the common writer’s late-cancel/revocation-before-rename boundary remain unexercised. Final G3/hygiene/whitespace and exact owner source/wiki delivery outcomes are retained in external root receipts. Projects GitHub Save/reopen/stable identity and filtered Tools web rows remain blocked by the retained CUA native-pipe failure; installed/full-web/all-model/managed-adapter/other-format/Release/shipment gates remain open.

Current candidate identity is the separately preserved ordinary Debug **f477a0b0…**. After the native G3 test action re-signed the prior main, the restored App passed a fresh **0.849 s** run with all **11 artifacts byte-identical** to the original App outputs; the six other compiled artifacts remain exact. Earlier CLI/Qwen and native-consumer results are reused only on the unchanged CLI/core and generated artifact inputs, with no new model or native-consumer invocation. Original candidate/signing evidence remains historical; the current transition is detailed in [the image guide](docs/NATIVE-IMAGE-WRITING.md). Final document recheck and source/wiki delivery outcomes remain in external root receipts.

## Preceding 0.36.3 (52) decoded UTF-8 web qualification

Version **0.36.3**, build **52** corrects `web.fetch` continuation after
non-UTF-8 text expands during decoding. A request still receives at most **1 MiB**.
For `text`/`source`, offsets and counts address decoded UTF-8 content up to
**3 MiB**; for `base64`, they address the original response bytes up to **1 MiB**.
Use the returned cursor and whole-content SHA, rather than advancing by a
requested page size. [Contract and current qualification](docs/WEB-RESPONSE-BUDGET.md)
record passing source/native, candidate build and App/CLI public web checks.
Qwen consumed all three results; its original strict final-format NONPASS and
separate raw-JSON correction are retained. CUA transport blocked the Projects
and filtered Tools checks; GUI attempts remain NONPASS. Final document check results are recorded in external root receipts.
The existing `web.search`, `web.fetch` and `web.render` capabilities retain their
separate contracts. Project GitHub Save/reopen and stable linked-project identity
remain a required GUI gate; full web and all-model acceptance are open.

## Preceding 0.36.2 (51) status-build qualification

Version **0.36.2**, build **51** adds build identity to fresh successful status
responses. `forge_status` and `get_forge_status` expose string `version` and
`build` together; the returned identity belongs to the process serving the call.
A stored completed response replay retains its original payload and may omit
`build`. Do not infer the running GUI identity from a replay or a tool-count claim.
[Focused checks and remaining gates](docs/QUALIFICATION-STATUS.md) are separate
from installed acceptance. Signed candidate App/CLI and actual Qwen checks
confirmed both fresh aliases and their matching text/structured payloads;
Qwen acknowledged only the two string identity values, not GUI or web behavior.

## Preceding 0.36.1 (50) instruction-count qualification

Version **0.36.1**, build **50** corrects the retained-document import limit.
Each package can retain at most 4,096 documents, including its ZIP container or
manifest: select up to 4,095 regular ZIP members or listed manifest documents,
or 4,096 files in an ordinary folder. The existing ZIP-entry and byte budgets
also apply. Over-limit imports leave the accepted store and queue unchanged.
See [instruction-package resource budgets](docs/INSTRUCTION-PACKAGES.md#resource-budgets).

## Preceding 0.36.0 (49) BMP qualification

Version **0.36.0**, build **49** is the current source target. For supplied
pixels, use `image_write(path="<project>/IMAGE.bmp", width=1, height=1,
content="/wAA/w==", format="bmp")`. The input remains canonical padded base64
straight RGBA8/sRGB, with common dimensions and byte limits. BMP accepts all
alpha values and preserves encoded masked channels; native rendering is separate.
Absent format remains PNG; explicit TIFF/JPEG/GIF/WebP and the tool's own grant
retain their contracts. The tool encodes supplied pixels.

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

[BMP contract and gates](docs/NATIVE-IMAGE-WRITING.md).

## Preceding 0.35.0 (48) WebP qualification

Version **0.35.0**, build **48** is the current source target. `image_write`
accepts explicit lowercase `webp` with a case-insensitive `.webp` destination.
All alpha values are accepted. Decoded WebP file pixels preserve supplied RGBA;
native premultiplied rendering is compared separately against PNG. PNG default
and explicit TIFF/JPEG/GIF retain their contracts and the tool's own grant.
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
Final-document G3 source/native one each passed (**1.438/1.867 s**), adding no
distinct methods; hygiene/whitespace passed (**0.673/0.133 s**), normal exit 0/unforced.
Exact source/wiki publication, readback and synchronization outcomes are retained in external closeout receipts.
[WebP contract and gates](docs/NATIVE-IMAGE-WRITING.md).

## Preceding 0.34.0 (47) GIF qualification

Version **0.34.0**, build **47** is the current source target. `image_write`
accepts explicit `gif` with a case-insensitive `.gif` destination and alpha
0/255; partial alpha returns `invalid_image_alpha` before writing. Palette RGB
can change even with at most 256 colors; hidden transparent RGB is unpromised.
Source **218 methods plus one separate G3** and canonical native **219 distinct methods** passed with matching method sets and zero failures/skips. Direct builds, strict candidate, signed App/CLI controls and actual Qwen consumption passed within the bounded GIF scope.
Final-document G3 and exact source/wiki publication, readback and synchronization are tracked in external closeout receipts.
Installed GUI, production managed-adapter, full web, all models, other formats, Release and shipment remain open.
[GIF contract and limits](docs/NATIVE-IMAGE-WRITING.md).

## Preceding 0.33.0 (46) JPEG qualification

Current source targets **0.33.0 (46)** for opaque JPEG from supplied
RGBA8/sRGB pixels. Use `image_write` with its own grant, explicit
`format: "jpeg"` and a case-insensitive `.jpg`/`.jpeg` destination. Every alpha
byte must be 255; transparency returns `invalid_image_alpha` before writing.
Quality is fixed at 1.0 and output is lossy. Absent format still selects PNG;
explicit TIFF retains transparency and exact straight-RGBA contracts.
Matching owning source/canonical native selections passed **210 distinct methods** each, zero failures/skips; CLI/app compilation and ordinary Debug passed.
Strict candidate, signed App/CLI controls, independent raw JPEG inspection and Qwen API consumption passed.
Final-document G3 passed in source and native. Source/wiki publication, readback and synchronization are tracked in external closeout receipts. [Contract and limits](docs/NATIVE-IMAGE-WRITING.md).
Installed GUI, production managed-adapter, full web, all models, other formats, Release and shipment remain open.

## Preceding 0.32.0 (45) TIFF qualification

Current source targets **0.32.0 (45)** for bounded TIFF creation from supplied
pixels. Use `image_write` with its own grant, explicit `format: "tiff"` and a
`.tif` or `.tiff` destination. An absent format still selects PNG and requires
`.png`; canonical straight RGBA8/sRGB and existing input/output bounds remain.
Source/native selections passed 203 methods each; build/signing and scoped
App/CLI/artifact/Qwen API checks passed. Final document G3 passed source/native.
Exact source/wiki publication/readback/synchronization identities will be
retained in external closeout receipts. [Contract and limits](docs/NATIVE-IMAGE-WRITING.md).
Installed-GUI acceptance remains open.

## Preceding 0.31.0 (44) PNG qualification

The preceding source targets **0.31.0 (44)** for bounded PNG creation from supplied
pixels. `image_write` requires its own grant, an explicit `.png` destination,
width/height and canonical base64 RGBA8/sRGB content with straight alpha.
Source/native selections each passed 198 distinct methods; CLI/app compilation
and ordinary Debug/strict candidate checks passed. App/CLI controls, exact PNG
inspection and Qwen API consumption passed. Installed-GUI acceptance remains open.
[Contract and limits](docs/NATIVE-IMAGE-WRITING.md).

## Preceding 0.30.0 (43) ODS qualification

The preceding source targets **0.30.0 (43)** for bounded text-only ODS writing and
cell-value import. Use a separate ODS grant and an explicit `.ods` destination;
reimport existing saved packages to gain conversion. Scoped checks passed.
[Contract and limits](docs/NATIVE-ODS-WRITING.md).

## Preceding 0.29.0 (42) PPTX qualification

The preceding source targets **0.29.0 (42)** for bounded `pptx_write` and slide-text
import. Source/native 166 each, App/CLI wire, reference/Core consumers and Qwen
consumption passed on the same candidate inputs. Existing tools and grants remain.
[Contract and limits](docs/NATIVE-PPTX-WRITING.md).
Installed/GUI, full Office/full web, all models and shipment remain open.

## Preceding 0.28.0 (41) XLSX qualification

The preceding source targets **0.28.0 (41)**. Authorized models can create a bounded
text-only worksheet with `xlsx_write`; XLSX package import reads cell values with
sheet labels. Scoped source/native, signed tool, retained-workbook Core and Qwen API
checks passed. [Limits and remaining gates](docs/NATIVE-XLSX-WRITING.md).

## Preceding shutdown behavior — 0.27.1 (40)

The preceding source targets **0.27.1 (40)**. Repeating shutdown after success now
returns the completed result; incomplete shutdowns can still be retried.
[Shutdown contract and qualification](docs/ORDINARY-RUNTIME-CONTINUATION.md#repeated-subsystem-shutdown).

The preceding source targets **0.27.0 (39)**. Use `docx_write` with a `path` ending in
`.docx` and plain-text `content`. It has its own tool grant, a 65,536-byte UTF-8
input limit and a 1,048,576-byte encoded limit. CRLF, CR and U+2029 normalize to LF;
native text import can add a final paragraph LF. Invalid XML 1.0 scalars are rejected.
Builtin Docs and ordinary project-default tools include the name; custom/imported
grants and explicit denials retain their existing scope.

The signed candidate's App/CLI creation/readback, native import, production Core
consumer and fresh Qwen API workflow passed. Source/native 155 passed each.
These checks qualify bounded plain-text DOCX, with no installed-GUI, styled
Office-suite or universal importer-fidelity claim.
[Contract and retained evidence](docs/NATIVE-DOCX-WRITING.md).

The preceding source targets **0.26.2 (38)**, an MCP notice-receipt hotfix.
The notice-receipt hotfix records presentation only after the complete
notice-bearing JSON+LF packet is written. EOF-skipped or partial packets do not
commit a presentation receipt. The 92 distinct source methods and the same 92
compiled native methods passed without failures/skips on their original
450-input map. A later test-only priority correction separately passed the same
one source and native method; the 92-case receipts keep their original inputs.
CLI/app compilation, current version/graph checks, final ordinary Debug build
and strict signing passed. Runtime diagnostics remain.
This records transport serialization, not host acknowledgement or understanding.
[Contract and current gates](docs/WEB-RESPONSE-BUDGET.md#notice-receipt-truth-follow-up).

The preceding source targets **0.26.1 (37)**. The web response-budget hotfix preserves
fetch/search tools and page continuation while accounting for the complete
stdio frame. The 139 affected source cases and same 139 compiled native cases
passed; all four signed native wire cases fit. Native diagnostics remain recorded,
and Qwen completion remains OPEN/NONPASS. Installation is separate.
[Contract and scope](docs/WEB-RESPONSE-BUDGET.md).

The preceding source checkpoint targets 0.26.0 (36). First CLI/app compiles and one repaired
regression passed on their first snapshots; 24 later new source tests passed.
The first broader NONPASS remains historical. The later checkpoint guard
correction and two genuine unavailable-reader fixtures passed three source
methods; available live empty snapshots remain supported. Earlier source
checks passed 309 distinct methods, including separate Manager/version checks;
incremental CLI/app and ordinary native Debug build passed. Native 309 passed
with three QoS diagnostics; two test priority corrections passed four source
and four native methods without warnings, and ordinary Debug was confirmed.
Strict Debug artifact binding, two isolated native MCP cases and a fresh Qwen
API case passed exact job/output recovery without replay. The first Qwen
fenced-JSON NONPASS remains recorded. An isolated two-helper E0 baseline then
interrupted a still-live primary job; collection succeeded, but the feature
contract failed; that historical receipt remains NONPASS.
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
The installed .18 deployment stays separate.
[Ordinary runtime continuation](docs/ORDINARY-RUNTIME-CONTINUATION.md) records the
original missing-job-reference failure and manual recovery; it does not close
the 54 capability themes, full-web, PDFKit or installed/all-feature gates.

The current native hosted rollover-control test passed numeric edits and public
accessibility stepper actions, including the 1 and 10,000 boundaries and default
200. This verifies the rendered control and staged settings binding; ordinary
current Manager save and LM Studio GUI rollover remain separate acceptance.

Manager → Settings now includes **Rollover after tool calls** (1–10,000;
default 200). Use **Save settings** to persist it. Running MCP helpers refresh
saved limits at status and eligible work boundaries; successful and failed
eligible work calls both count. Status reads preserve counters and pending
editor values. If the stored configuration is missing or malformed, status
remains readable using cached settings and reports `configuration_refresh`
with `state: failed` and `using_cached_settings: true`; healthy responses omit it.
The new native Xcode tools and policy coverage limits are described in
[the runtime repair record](docs/LMSTUDIO-RUNTIME-REPAIR.md). The latest repair
accepts bounded Responses lifecycle frames within a finite event budget while
preserving byte, output and timeout protections. Full source v8 and five signed
native SSE controls passed. The original live failure's raw-stream validity is
unknown; ordinary GUI rollover and SIGKILL recovery remain pending.
Current validation
is in progress. The completed full Swift v3 source checkpoint selected 2,181
Core cases: 2,168 passed, 13 explicitly skipped, zero failed; filesystem
qualification passed 30 cases without skips. Later playbook guidance passed
14 catalog cases with strict deep XCTest verification. The status/storage
repairs passed six focused and 300 affected source cases without skips/failures;
full Swift v4 then passed 2,174 of 2,187 Core cases, with 13 explicit skips and
zero failures, plus 30 filesystem qualification cases without skips. These
source results do not qualify the remaining native/live gates.
At the v7 test freeze after that checkpoint, only the live test fixture changed;
production and the other 438 frozen inputs stayed unchanged. Its gate correction
passed the ownership control. Live v3–v5 failed; v5 showed the fixture's old cutoff was below
the actual initial input plus reserve, requesting rollover before a provider
turn. The opt-in fixture cutoff/diagnostics were corrected with original
assertions preserved and initial-normal checks added. Live v6 then failed one
case without skips after normal initial admission and actual provider-exact
rollover: successor bootstrap failed with `lmstudio_response_truncated`, without
ACK/crash/recovery proof. Its incomplete reason is unknown. All 14 original
process identities/MCP registration were preserved, with no owned survivors.
The v7 fixture compiled; the normal class selected five cases, with three passes,
two disabled live skips and zero failures. Separately, live v7 passed one actual
owned Manager/API case without skips in 487.293 seconds: exact ACK, injected
in-process error/recovery, predecessor sealing, automatic continuation/marker
read and stable replay. All three phases used one SwiftPM XCTest process and
preserved original processes/MCP registration. This does not qualify ordinary
LM Studio GUI rollover, a SIGKILL matrix or compiled native v2 execution; those
remaining gates and earlier unexplained failure causes stay open.
After v7, the semantic classifier repair passed its four regressions without
skips/failures after their 39 original assertion failures. It preserves status
fallback and incomplete-response rejection. Normal affected classes selected 52
cases: 51 passed, one explicit live skip, zero failed. Native v2/live v7 predate
this repair. Later full v5 failed one descendant-count fixture assertion:
2,191 Core selected, 2,177 passed, 13 skipped, one failed; filesystem qualification
passed 30 cases. A controlled test confirmed kernel identities can precede shell
PID records. The fixture correction preserves the limit and cleanup checks;
normal Runtime validation passed 112 of 113 cases with one PowerShell skip and
no failures.
On October 6, full v6 returned terminal zero: 2,192 Core cases selected,
2,179 passed, 13 explicitly skipped and none failed; filesystem qualification
passed all 30 cases without skips/failures. All 439 frozen inputs remained
unchanged during the run: five full-v4 paths changed, 434 unchanged. Skipped
capabilities remain unqualified.
Later native v3 Debug/Release builds and all five roles' strict signature/
metadata/settings checks passed against 439 unchanged inputs. Release required
one owned post-build SIGINT. Four classifier XCTests passed through the signed
v3 Debug CLI, with native/serve exits zero and lossless output. Typed readback
verified exactly four passed cases, no extras/skips/failures, and clean exits
from both result jobs and serve. Those builds predate the later Runtime/Queue test
fixtures and Rune reorder repair. Ordinary GUI, SIGKILL, Compute, LLDB, simulator
XCTest and owner-signing gates remain open.
A later Rune reorder repair keeps the newer command's order when an older request
finishes late; current cancellation/failure still restores its prior order. The
three original controlled cases failed four assertions, then five focused and all
15 normal Rune cases passed without skips/failures. Separately, a Queue test-only
actor annotation followed five AppKit warnings: focused one, normal 38 and one
fresh native case passed, with clean native/serve exits. Typed build/summary/
inventory readback then confirmed exactly that one actual Passed Queue case,
zero failures/skips, all three native result jobs and serve exited zero, and
configuration bytes were unchanged. Refreshed native v4 Debug/Release builds
passed with lossless EOF and all 439 inputs unchanged; all five roles' strict
identity/metadata/settings controls passed in both configurations and all 579
independent audit checks passed. Debug required no cleanup signals; Release
recorded two exact owned post-build SIGINT signals, with no owned survivors.
Rune v4 executed zero tests because its selection used the wrong native test
bundle; `TEST SUCCEEDED` and helper success flags do not qualify those tests.
The corrected Rune v5 app-hosted selection executed exactly five cases: five
passed, zero failures/skips, in 0.246 (0.248) seconds, with native/serve exits
zero and lossless output. Full Swift v7 returned terminal zero: 2,197 Core cases
selected, 2,184 passed, 13 explicitly skipped and none failed; all 30 filesystem
cases passed. Exact case reconciliation and complete raw EOF verified 2,227
actual selected cases and 2,214 passes, with all 439 inputs unchanged. Skipped
capabilities remain unqualified. SIGKILL recovery remains pending; the first
candidate attempt failed preparation before any Manager launch. These checks
do not qualify ordinary GUI rollover, installed or full-runtime behavior, or
shipment.
The earlier October 5 source checkpoint passed 19 focused tests and
499 of 505 selected affected cases, with six explicit skips and zero failures.
A later adapter protocol checkpoint passed 33 of 34 selected cases, with one
live-provider skip and zero failures; it does not qualify ordinary GUI overlap.
Debug/Release v1 builds and signature checks passed before the status/storage
fixes. Retained v2 Debug/Release builds and all five roles' strict identity checks
passed against 439 frozen inputs; both compiled CLI/native Xcode version jobs
completed with lossless output and clean serve exits. One exact Rune app-hosted
coverage test and one v2 candidate identity/version-drift test passed
without skips. Native v5 exercised policy notices/history/corrections through
separate owned clients with clean Manager/serve exits. Earlier UI receipts
retain their tested versions. A separate bounded v6 model probe completed one
interpretation of the authentic retained review notice; it did not prove
compliance, correction or general future behavior. The retained-v9 new→old→new
CLI fixture passed in a fresh owned home with a synthetic historical seal, not
a real successor acknowledgement or installed-build test. Both simulator v3 and
alternate iOS 26.5 v4 completed build/boot, but boot readiness timed out before
XCTest. Exact owned cleanup preserved all 32 baseline devices. Ordinary GUI
rollover, LLDB, Compute and simulator
XCTest remain unqualified.
The later direct simulator startup control outside Forge reproduced the same
migration wait and timed out at 300 seconds before XCTest. Exact owned cleanup
preserved all 32 baseline devices; the underlying cause remains unknown.
The subsequent owned iOS 26.5 namespace diagnostic also reached the 300-second
readiness timeout before XCTest. Exact-PID logs retained recurring AddressBook
migration duration updates, while namespace snapshots preserved the same two
migration PIDs. Simulator AddressBook TCC approval and a log of two pending XPC
transactions establish no host debugger authorization or migration cause.
Exact owned shutdown/delete exited zero and all 32 baseline device bytes were
unchanged; simulator XCTest remains unqualified.

<!-- FORGE-COMPUTE-PCB-FOLLOWUP:BEGIN -->
## Compute PCB refinement — verified native scope

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

These captures are separate native cache/Metal layers, including a 20-frame
motion sequence. They do not qualify desktop composition, XCUITest,
installation or distribution. Earlier receipts retain their exact inputs.

Detailed source/candidate identities, retained failures and evidence limits
are in [Compute Cores](docs/COMPUTE-CORES.md) and [native QA](docs/GRAPHITE-NATIVE-QA.md).
Exact owner publication/synchronization refs belong to external delivery receipts.
<!-- FORGE-COMPUTE-PCB-FOLLOWUP:END -->

## Preceding Dashboard columns — source 81a91a81…

The **0.17.0 (27)** Dashboard uses two equal-width independent columns.
The left stacks **MCP Servers** above **MCP Tools**; the right stacks
**Sub-agents** above **Hot Processes**. Outer top/bottom edges align while the
internal splits follow their content. Hot Processes starts directly beneath
Sub-agents and fills the remaining right-column height.

Thirteen current public native view methods passed with zero failures/skips;
all 358 native-cache/Metal images were individually reviewed. The matching
My Mac Debug build and strict signature verification passed. See [native
QA](docs/GRAPHITE-NATIVE-QA.md) for exact identities and evidence limits.

## Preceding frame-refinement checkpoint — source 2463aa06…

The **0.17.0 (27)** frame refinement was implemented and tested. Smaller,
darker Compute frames omit duplicate visible hardware names and activity
badges while full identities and states remain accessible. The approved chips
and telemetry effects are preserved. Dashboard omits its inline guidance
banner; other routes retain guidance. **Open Guide** in Workbench Settings and
**View Guide** in the Guide menu retain the guide action. Sub-agents and Hot
Processes fill the same grid row with its existing 200-point minimum.

Fresh native fixtures covered all 13 routes at normal/minimum size, all nine
Manager sections, all eight setup steps and reachable registration/Guide
presentations. Thirteen methods passed and all 357 successful PNGs were reviewed;
the failed initial Guide-role assertion is preserved separately. The current
ordinary My Mac Debug candidate passed build and strict signature verification.
These fixture caches and separate Metal readbacks are not compositor screenshots.

The preceding `28548a73…` Graphite/Compute implementation and required QA were
complete for those recorded inputs. The matching ordinary Debug candidate passed build, signature and
packaging checks and four scoped native workflows. That checkpoint native view and
control matrix and final checks passed; actual Settings and normal Dashboard
observations retain their recorded scope. Exact owner publication, remote
readback and synchronization references are retained externally. See the
[phase record](docs/GRAPHITE-WORKBENCH.md) for evidence and capture limits.

Version **0.35.0**, build **48** (current source target; owning source/native 225 plus separate G3 one each establish matching 226-method unions; direct builds/strict Debug signature and scoped App/CLI/Qwen/native consumers passed; installed acceptance remains pending).

Preceding .34 identity record (retained):

Version **0.34.0**, build **47** (current source target; bounded GIF source/candidate/API checks passed; installed acceptance remains open).

Preceding JPEG identity record (retained):

Version **0.33.0**, build **46** (current source target; bounded JPEG source/native and direct builds passed; final-document/delivery and installed acceptance remain separate).

Preceding .32 version record (retained):

Version **0.32.0**, build **45** (current source target; bounded TIFF candidate checks passed, with installed-GUI acceptance still open).

This guide describes the current LM Studio-driven workflow. The user works in a
normal LM Studio chat; Forge Conductor supplies project context, tools, policy
governance, memory, and automatic continuity.

## Graphite Workbench navigation

The main sidebar retains the current Forge destinations. Graphite panels,
fields, catalog rows and status accents provide a consistent native reading
surface; operational error, denial, warning and unavailable evidence retain
their independent labels.

The main workspace opens without a global control bar. Open **Forge Conductor
→ Settings…** or **⌘,** to enter **Workbench**. Navigation visibility,
Auto-refresh telemetry and contextual Guided Mode apply immediately. **Refresh
Now** updates telemetry; **Open Guide** and **Guided Setup** open the shared
guide/setup presentation in the main window.

**Optional view controls** has six separate preferences: Navigation,
Auto-refresh, Guided Mode, Guide, Refresh and Guided Setup. Enable only the
shortcuts you want above the selected view; all six are off by default. The
**Navigation** menu and **Control-Command-S** show or hide navigation. The
**Telemetry** menu retains Auto-refresh and **Command-R** for Refresh Now.
The **Guide** menu provides View Guide, Guided Setup and Guided Mode.
The six optional-control preferences and Guided Mode persist across relaunches.
Navigation visibility and Auto-refresh retain their existing session behavior.

**Manager** has nine sections: Workbench, Authorized Folders, Service, Runtime,
Settings, Project Shell, Protected Filesystem, Maintenance and Doctor. The
main Manager entry initially selects Authorized Folders; native Settings
initially selects Workbench. Interface preferences have no Save/Reload footer.
Opening either entry or switching sections preserves staged configuration.
Folder selection, host/port/refresh/watchdog/session settings and shell settings
remain staged until **Save settings**; **Reload from disk** explicitly replaces
the draft. Each section scrolls when content exceeds the available height.

**Provider** has a provider list and detail workspace. Clicking a row only
inspects that provider. Its explicit activation toggle changes the active
provider; **Connect and Check** remains the LM Studio connection action.
Save or discard LM Studio Advanced edits before reconnecting. The toolbar
disables its connection and probe actions while edits are staged; an available
provider-card connection action reports the same save-first notice.
The [Graphite Workbench record](docs/GRAPHITE-WORKBENCH.md) separates
implemented behavior, manual native observations and tested checkpoints.
Current native palette/size QA passed in its named scopes. Installation and
distribution remain separate owner actions.

**Guided Setup** opens from Workbench Settings, the Guide menu, or its explicitly
enabled optional view control. Step3 opens Projects and names **Add Project
Folders…**, matching the visible registration control. Its project, instruction and review
steps let you choose a registered **Project to review** before starting an
LM Studio chat. Review reads that project's generation, queue and provider
revision without activating it or creating a model session. Use **Confirm
Review and Continue** once the displayed inputs are ready; the subsequent
LM Studio chat establishes its normal MCP binding.

## Compute Cores update — verified UI scope

The chips use this Mac's CPU/GPU identity. CPU illumination represents
logical-processor activity when measured; host-average fallback is labeled
separately. GPU regions illustrate measuredaggregate activity; trace travel
is simulated flow. Idle/warming/stale/paused/unavailable states remain distinct;
the compact view retains their accessibility labels.
Reduce Motion keeps a staticactivity presentation. Current materials derive
from the exact supplied reference, with bounded native crops and Metal lights
that brighten/changecolor with valid telemetry. Artistic bank colors do not
assert P/E topology or measuredGPU-core activity.

At the preceding qualified `28548a73…` checkpoint, normal/minimum native views,
all 9 Manager sections, all 8 setup steps, reachable Guide bodies/state
presentations and signed ordinary workflows passed
their recorded checks/reviews. ActualnormalSettings/Dashboard were observed;
unavailable ordinaryminimum/physical1×/Skycompositor and NSAlertcache-button
limits remain explicit. Exact owner publication/readback/synchronization refs are retained externally; distribution is separate.
See [Compute Cores](docs/COMPUTE-CORES.md) and [native QA](docs/GRAPHITE-NATIVE-QA.md)
for exact evidence and historical failed attempts.

## 1. Start Forge Conductor

Open Forge Conductor and confirm that **Manager** is running. Manager owns the
authenticated local control boundary, project registry, provider preparation,
policy services, and automatic continuity watchdog.

If a Provider action reports a Manager transport or authentication failure,
use the Manager surface to start or repair the current-build Manager, then
repeat the Provider action. Forge reports that condition separately from an LM
Studio connection or model error.

## 2. Connect LM Studio

1. Open LM Studio and load the model you intend to use.
2. In Forge Conductor, open **Provider**.
3. Select **LM Studio**.
4. Choose **Connect and Check**.

Provider selection, **Connect and Check**, the Advanced connection check, and
the probe use the same preparation path. For same-host LM Studio, the check
authenticates only to Forge Manager and uses LM Studio's private loopback server
without an operator login or token. It performs bounded supported-CLI recovery,
discovers loaded models, resolves the configured model, validates the tool
contract, and saves a readiness receipt.

Forge does not load a model on the user's behalf and does not scan arbitrary
ports. Local Advanced settings expose endpoint and model but no token field.
Linked HTTPS providers retain an optional credential control. Saving is allowed
while LM Studio is offline; live readiness still requires **Connect and Check**.

## 3. Select projects

Open **Projects** and use the folder picker to select one or more project
folders. Each registered folder receives a stable project ID and generation.
Memory, instructions, policy observations, continuity, and durable activity
remain isolated by that identity. The selected folder also supplies the default
working directory; it is not a filesystem sandbox. Native filesystem, Git, and
shell tools use only the access macOS attributes to the responsible signed host
and executable in the actual launch chain. Full Disk Access is not a Forge
entitlement. After changing a grant or candidate, quit and relaunch the affected
hosts and verify that exact signed candidate with a live protected-path read
that emits no file contents. POSIX permissions, SIP, tool grants,
project-generation fencing, timeouts, output limits, and destructive-root
protections still apply.

Native runtime jobs have a finite descendant budget and fail explicitly on
overflow. Local outside-project delete and move recheck the source's filesystem
identity against the filesystem, mounted-volume, home, Manager, and active-
workspace roots at the actual mutation boundary; a changed or uninspectable
identity fails closed.

Select a project and enter its repository in **GitHub repository**. Acceptable
locations include `https://github.com/owner/repository`,
`git@github.com:owner/repository.git` and `ssh://git@github.com/owner/repository.git`.
Choose **Save Repository** to persist the canonical HTTPS URL, **Open on GitHub**
to visit it, or **Clear Repository** to remove the link. This metadata stays with
the stable project ID and does not change the project's registration identity or
Git credentials. Models receive it as `github_repository_url` in project status.
The link also appears in `get_forge_status` and `project_memory.status` project
metadata. See [project memory](docs/PROJECT-MEMORY.md) for persistence and
compatibility details.

Available maintenance actions include:

- relink a moved project folder;
- remove a project registration;
- reset the selected project's generation;
- clear selected project content; and
- **Clear Cache…**, which removes only disposable Forge cache data.

Destructive actions require confirmation. Cache clearing preserves projects,
instructions, policy, memory, credentials, and continuity.

## 4. Add and order instruction packages

Use **Add Instructions…** to select one or more files, folders, ZIP archives, or
supported packages. Selected packages appear in an ordered frame.

- Drag package rows to change their priority.
- Use **Move earlier** or **Move later** for keyboard-accessible ordering.
- Choose **Delete Package** to remove the selected package.

The displayed order is durable and authoritative. The model observes the
latest committed order on its next instruction-catalog query. Adding or
ordering packages does not start a model session.

See [instruction packages](docs/INSTRUCTION-PACKAGES.md) for accepted formats
and storage limits.

## 5. Add Development Policy in Rune Forge

Open **Rune Forge** and choose **Add Development Policy…**. Select one or more
files or folders. The selected sources appear in an ordered frame.

- Drag sources to set their order of importance.
- Use explicit earlier/later controls when needed.
- Remove only the selected source with its delete action.

CLU is the governance-enforcement agent. It monitors model observations against
the ordered policy, records a separate bounded log for each project, and sends
the model a structured notice containing the exact violated policy identity and
applicable policy content. CLU does not take over task execution.

Automatic detection currently covers **1 of 15 indexed Raven rules**:
`RFD-NATIVE-001` evaluates declared Xcode production membership. The other
fourteen remain policy guidance without executable detectors; importing policy
text does not create a detector, and zero violations does not prove compliance.
Resource-only JS/MJS declarations retain an advisory violation at 0.45 confidence
pending review, with unchanged identity and prior history. This grants no
exemption or correction. Policy notices do not deny tools or stop development.

Use Rune Forge export controls to write the selected project's log as JSONL,
JSON, Markdown, or CSV.

## 6. Start work in LM Studio

Open a normal chat in LM Studio. Ask the model to call:

```text
get_forge_status
```

The result lists registered project IDs and the query tools and locations for
project files, ordered instructions, Development Policy, and continuity. With
one active project, this call attaches the MCP deployment to it. With multiple
active projects, repeat `get_forge_status` with the applicable `project_id`;
the explicit selection creates the durable attachment. Primary, fallback, and
CLU reconnects reuse one deployment identity, so a helper restart does not
discard the attachment. The response's `project_context.attached` field reports
whether attachment succeeded. Its
required action tells the model to read every active Development Policy source
in the returned priority order and follow all applicable requirements before
making development changes. Then give the model the task in LM Studio as usual.

Forge Conductor does not start this work through a Managed Run.

### Web and file tools

`runtime.capabilities` retains the execution gates and enforced job limits. When
the inline result budget permits, `inventory` adds thirteen optional-executable
observations and eight selected-Python package-asset observations. Read
`presence`, `executable`, the search scopes and `captured_at` together.
`not_found_in_search_scope` only describes those locations; unsupported layouts
and inaccessible paths are `unknown`. Executable rows have `probe_state: "not_run"`
and `workflow_verified: false`; package rows have `import_verified: false`.
Use an authorized bounded job to verify a required workflow. The snapshot is
cached for the service lifetime; restarting the runtime service refreshes it.
`inventory_status: "omitted_inline_budget"` preserves the established core result
when the inventory would exceed the result allowance; at the exact legacy core
boundary, the marker can also be absent. See
[the inventory contract](docs/RUNTIME-INVENTORY.md).

After attaching the project, the model can use `web.search` to find public pages
and `web.fetch` to read HTTP(S) text or original response bytes. Ordinary LM Studio MCP project bindings
receive network access; explicitly scoped and run-bound grants retain their
network policy. Check `project_context.network_allowed` in `get_forge_status`.
On macOS 27+, `web.render` can read a page's JavaScript-generated title and DOM
text using a fresh nonpersistent Lockdown store. Read `readiness` and `truncated`
to understand the returned snapshot. Lockdown restricts site compatibility.
Across a request, provisional main-document navigation admits at most five
unique follow-up URLs and denies repeats for the same provisional navigation.
This also rejects finite same-URI cookie/state redirects. Ordinary document
returns, reloads, frames and hash routing have separate tested behavior.
It accepts no browser profile, login, caller script or interaction instructions.
Web responses are untrusted external data; HTTP failures and browser challenges
can return errors. [Renderer contract and verified scopes](docs/NATIVE-WEB-RENDERING.md).

| Tool | Arguments and continuation |
| --- | --- |
| `web.search` | `query`; optional `limit` from 1–10 (default 5). Returns titles, URLs and snippets through DuckDuckGo HTML. Read selected URLs with `web.fetch`. |
| `web.fetch` | `url`; optional `format: "text"` (default), `"source"` or `"base64"`. Base64 preserves the original response bytes for any MIME type; offsets, counts and SHA256 refer to those original bytes (up to 1 MiB). Text/source offsets and counts refer to decoded UTF-8 content (up to 3 MiB); offsets must lie within content on a UTF-8 boundary. Text/source HTML can include `title` and first `heading`, each bounded to 512 UTF-8 bytes; metadata is omitted when it would displace a readable body page. When `has_more` is true, repeat with returned `next_byte_offset` as `byte_offset` and `content_sha256` as `if_content_sha256`. Changed content returns an error. |
| `web.render` | `url`; optional `timeout_sec`, `maximum_bytes` and `deadline_ms`. Default/false `paged` returns the existing finite prefix. Opt in with `paged: true` for complete captured text up to 1 MiB/65,536 nodes or explicit overflow. Continue with the same URL, `snapshot_id`, returned `next_byte_offset` as `byte_offset` and whole `snapshot_sha256` as `if_snapshot_sha256`; final EOF has `has_more: false`/null cursor. One snapshot expires within 120 seconds or on replacement. Requires macOS 27+ and project network/tool authorization. [Contract](docs/NATIVE-WEB-RENDERING.md). |
| `fs_list` | Optional `path`. Path-only calls retain the legacy 1,000-entry cap. Supply `limit` (1–1,000; default 100), `cursor` or `maximum_bytes` to select paged mode. Paged arguments are validated before path normalization; count tokens must have an exact integral value. Continue using the returned `next_cursor` until `has_more` is false; `deadline_ms` alone retains legacy mode. Directory changes require restarting. [Contract and verified scopes](docs/FILESYSTEM-LIST-PAGING.md). |
| `fs_read` | Default `encoding: "utf8"` uses 1-based line `offset` and `length`/`limit`. For arbitrary bytes, use `encoding: "base64"`, zero-based `byte_offset` and optional `maximum_bytes`; continue at returned `next_byte_offset` while `has_more` is true. |
| `fs_write` | `path`, `content`; optional `encoding: "base64"` requires canonical padded base64 without whitespace and accepts at most 2 MiB decoded bytes. The default writes UTF-8 text. |
| `pdf_write` | `path`, `content`; optional `title`. A missing PDF extension is appended; the default title is the destination filename without its extension. Writes the supported text/Markdown subset through native layout. |
| `pdf_from_file` | `source_path`; optional `dest_path`, `title`. Reads a bounded regular UTF-8 source. The default destination replaces the source extension with `.pdf`; the default title is the source filename without its extension. |
| `docx_write` | `path`, `content` strings; explicit `.docx` destination. Plain text up to 65536 UTF-8 bytes, encoded output up to 1048576 bytes. CRLF/CR/U+2029 normalize to LF; native paragraph terminators can add a final LF when imported. Requires its own DOCX tool grant. |
| `xlsx_write` | `path`, `rows` arrays of strings; explicit `.xlsx` destination. One text-only worksheet: at most 256 rows, 64 columns per row, 4096 cells, 4096 UTF-8 bytes per cell and 65536 total text bytes; encoded output up to 1048576 bytes. Requires its own XLSX tool grant. |
| `pptx_write` | `path`, `slides` with string `title` and string-array `paragraphs`; explicit `.pptx` destination. At most 32 slides, 1024 total paragraphs including nonempty titles, 4096 UTF-8 bytes per string, 65536 total input bytes, 32768 XML elements per slide and 1048576 encoded bytes. Requires its own PPTX tool grant. |
| `ods_write` | `path`, `rows` arrays of strings; explicit `.ods` destination. One ODF 1.3 worksheet: at most 256 rows, 64 columns per row, 4096 input cells, 4096 UTF-8 bytes per cell, 65536 total input bytes, 32768 content XML elements and 1048576 encoded bytes. Requires its own ODS grant. |
| `image_write` | Explicit `path`; integer `width`/`height`; canonical padded base64 `content` of straight RGBA8/sRGB top-to-bottom pixels; optional `pixel_format: "rgba8"`. Decoded content is exactly width×height×4 bytes. Absent/default png requires .png; explicit lowercase tiff/jpeg/gif/webp/bmp/ico require case-insensitive .tif/.tiff, .jpg/.jpeg, .gif, .webp, .bmp or .ico. ICO is square 16/32/48/256: one BI_RGB32 DIB/AND image retaining encoded alpha and hidden RGB; engine swift-ico-dib32/output_contract ico-dib32-rgba8-srgb-v1. Native premultiplied rendering is separate; no embedded ICC/Windows interoperability promise. Other formats retain 1…1024/262144 pixels; global decoded/base64/output caps 1048576/1398104/2097152. JPEG alpha 255/quality 1.0 remains lossy; GIF alpha 0/255/palette limitations and exact lossless WebP/TIFF/PNG/BMP contracts remain. Own image grant/context/pinned writer required. Source/native 56 raster+five neighbors=61 distinct passed; candidate build/signature/version passed. Current App/CLI/Qwen wire and seven-pair native consumers passed; two immediate cancellations per App/CLI route were exercised. In-work/late cancellation and installed GUI remain open; final document/delivery outcomes are retained externally. [Detailed image contracts/history](docs/NATIVE-IMAGE-WRITING.md). |
| `archive_write` | Explicit matching .zip/.tar/.tar.gz path; optional exact format zip/default, tar or tar.gz. 0–32 virtual files with exact NFC relative names/canonical padded-base64 content; own grant/context, 1 MiB decoded/2 MiB writer ceilings and separate managed 64 KiB JSON cap. Stored ZIP, deterministic PAX TAR or one GZIP-wrapped TAR; no host member-source paths/extraction/standalone .gz. App/CLI/Qwen full-byte and fifteen BSD consumer checks passed; document/delivery gates remain pending. [Contract](docs/NATIVE-ARCHIVE-WRITING.md). |
| `search_text` | `pattern`; optional `path`, integer `context_lines` from 0–20, and `include`/`exclude` filename-glob arrays. Each array accepts at most 32 nonempty globs of 256 UTF-8 bytes each. `.git` and `node_modules` remain excluded. |
| `git_diff` | Optional `cwd`, `staged` and `file` (repository-relative pathspec). For example, `file: "Sources/App.swift"` limits the diff to that file. Read `stdout_truncated`, `stderr_truncated` and `timed_out` before treating output as complete. |

The ODS tool writes text cells, normalizing CRLF/CR to LF while preserving
spaces, tabs, line breaks and literal `_x0041_` text. Empty rows use structural
blank padding; result counts describe the original input. ODS import retains the
original and extracts meaningful cell text with sheet labels/references. It does
not evaluate formulas or make package XML runnable. Existing grants and
OS-authorized host-wide access apply. [Contract and pending gates](docs/NATIVE-ODS-WRITING.md).

The PPTX tool writes plain-text slides with CRLF/CR normalized to LF. Embedded
LF creates soft breaks; tabs, whitespace and literal `_x0041_` text remain.
It rejects excessive XML complexity before saving, preserves existing grants
and OS-authorized host-wide access, and promises neither visual fit nor images.
PPTX import retains the original and extracts slide-owned text in declared order;
blank or malformed decks remain unresolved without runnable package XML.
New audit arguments redact slide and worksheet content arrays.
[Contract and remaining gates](docs/NATIVE-PPTX-WRITING.md).

The XLSX tool preserves literal cell text, including CR, `_xHHHH_`-like text and
formula-like strings; it does not create formulas, types, styles or images.
Project roots select context/default paths; tool grants and OS permissions govern
host-wide access, and the pinned write boundary remains. XLSX instruction import
retains the original and extracts meaningful cell values.
Blank or unreadable workbooks stay unresolved; package XML is not runnable text.
[Contract and remaining gates](docs/NATIVE-XLSX-WRITING.md).

The DOCX tool writes plain text through native Word-document serialization.
It does not interpret Markdown, add images or promise styled-page/Office-suite
fidelity. The builtin Docs agent and ordinary project-default tool sets receive
the exact name; custom/imported tool grants and explicit denials are not widened.
A destination durability error can follow a successful rename; inspect that
destination before retrying. [Contract and remaining checks](docs/NATIVE-DOCX-WRITING.md).

The PDF tools retain their existing authorization, title/destination defaults,
Markdown subset and 4 MiB content/source limits. Native layout now limits retained
PDF output to 64 MiB before atomic writing. A successful response reports
generation metadata; intended glyphs and layout require document review.
For accepted complete tagged PDFs, instruction imports and policy-source indexing
use logical ActualText with explicit converter provenance. Unsupported, incomplete,
over-budget or whitespace-only semantic input retains the existing PDFKit path;
previously stored records are not automatically reconverted.
[PDF contract and current qualification](docs/NATIVE-PDF-WRITING.md) separate
logical-text, rendered-glyph and geometry checks. Signed Debug and Release each
generated eight control documents, and Qwen used both PDF tools in a separate
two-document API exchange. Both control PDFKit validators still fail the whole
mixed-script phrase order; Qwen's written whole sentinel fails across a layout
newline. Independent r6 semantic validation passed all eight Debug, eight Release
and two Qwen artifacts with the original scalar markers. Its 82 controls retain
the original 80 expectations and add exact 32,768/32,769 operand boundaries. Native PNG
review covered ten Release and two Qwen PNG pages. PDFKit compatibility remains
open. A later test-only fixture capture correction passed the focused native
regression and all 19 writer methods; the PDF tool contract is unchanged. Its
0.25 test/documentation closeout was delivered and synchronized with clean 0/0
source/wiki divergence ([exact refs](docs/ORDINARY-RUNTIME-CONTINUATION.md#preceding-pdf-delivery)). These
results do not qualify the installed active chat, full Markdown or Office export.

Web tools accept integer `timeout_sec` from 1–30 (default 20), and
`maximum_bytes` from 1–65,536 (default 16,384) for the encoded inline response;
the project budget can reduce that allowance. Successful `web.fetch` and
`web.search` stdio frames count the actual ID, duplicated payload, required notice
and LF. A reduced fetch page retains the whole-content SHA and advances only by
returned UTF-8 or decoded base64 bytes; always use its returned cursor. Search
removes trailing whole entries rather than inventing an empty result. Existing
errors keep their codes and handoff fields; an impossible error envelope may
exceed the allowance. [Contract and qualification](docs/WEB-RESPONSE-BUDGET.md).
Successful `web.render` stdio
responses include the actual request ID, required policy notice and terminating
line feed in that allowance. The post-publication LF boundary correction has
[source and new Debug/Release native coverage](docs/FILESYSTEM-LIST-PAGING.md#renderer-line-feed-boundary-after-023-publication);
the original 0.23.0 JSON-only receipts retain their own measurement scope.
An impossible envelope returns an explicit budget error. Default v1 renderer
extraction visits at most 4,096 nodes and returns at most 8,192 UTF-8 text bytes.
Opt-in complete capture is bounded to 65,536 nodes/1 MiB text, then paged within
the encoded allowance; whole network bytes, DOM size and JavaScript heap are not capped.
Each HTTP fetch receives at most 1 MiB
and follows at most five redirects. Text/source decoding can expand those bytes
to at most 3 MiB of UTF-8 content; base64 keeps the original-byte 1 MiB limit. Each continued web page fetches the URL
again; `if_content_sha256` detects a changed body. Decode each base64 page
separately and append its bytes, then use the returned byte cursor. Binary file reads request 16 KiB by default,
up to 32 KiB raw bytes per page; the returned page can be smaller to fit the
encoded MCP and project budgets. Always use the returned cursor rather than
advancing by the requested size. Binary transport lets tools preserve exact file
bytes; format-specific authoring and image understanding have separate capabilities.

Paged listing uses raw filename-byte order, not locale
order. Its cursor is bound to the same client, project generation and canonical
path and grants no new access. Keep it unchanged when requesting the next page.
A page can return fewer than `limit` entries to fit the output budget; use the returned
cursor, rather than counting names. A complete successful paged stdio response
includes its actual ID, required notice and line feed within `maximum_bytes`
(default 16 KiB, maximum 64 KiB), reduced by the project allowance. An impossible
envelope returns an explicit error and advances no cursor. Each page processes
at most 100,000 direct names within a 15-second scan bound and the request deadline;
metadata fences are not an atomic snapshot or a guarantee of filesystem syscall
latency. Calls on the main thread fail with `listing_worker_required` before
scanning. The final source and compiled Core checks passed the same 173 cases.
Signed Debug and Release each recovered all 1,001 owned names in eight pages,
and Qwen consumed three real one-entry pages, using the previous returned cursor
on each of two continuations, then stopped normally. These are candidate/API
checks; installed and active GUI-chat qualification remain separate. Source
tests cover required notices in final
frames, but no policy notice was present in the native listing/renderer runs.
The linked record retains all failed attempts and exact limits.

When inspecting jobs, `job.list` may return fewer complete rows to fit the
response byte budget. If `has_more` is true, pass the returned `next_cursor`'s
paired `before_created_at` and `before_job_id` fields as arguments to the next
`job.list` call. This preserves jobs with equal timestamps. Existing
timestamp-only cursors retain their exclusive-time behavior. Xcode receipt
budgets are checked before job admission; submission still does not establish
native success, and native exit 65 remains a failure. Byte-paged
`job.read_output` and base64 recovery remain available. Queued, running and
cancelling jobs can return an owned output snapshot. `is_snapshot: true` and
`sha256_is_provisional: true` mean the hash and byte counts describe that moment;
more bytes can arrive. Continue or poll at `next_offset` even when `eof: true`,
which means the end of the currently retained bytes. `producer_eof` reports the
producer separately. A complete result requires a terminal job, a final page
(`is_snapshot: false`), producer EOF without a read error, and no artifact
truncation for both streams. If ownership is not yet readable, the existing
`runtime_output_unavailable` code has `retryable: true`; retry the same offset.

Project-memory `get`, `search` and `list_recent` hide records whose valid
`expires_at` has passed. Use `include_expired: true` to inspect them. Expiry
filters queries; it does not delete records or remove them from export or
status counts. New expiry values require an RFC 3339 calendar timestamp with an
explicit timezone and seconds 00–59. Existing invalid timestamps remain visible
and non-expiring. To recover a legacy export with those values, use
`project_memory.import` with `expiry_policy: "preserve_legacy_v1"`; the default
`"strict"` rejects malformed expiry. Preview and commit apply the same checksum,
project, type and batch bounds. Preserved expiry bytes count toward the 1 MiB
batch limit; this mode does not authorize malformed new remember writes.
Use returned memory cursors as opaque values with the same query and visibility
mode. Current cursors avoid skipping later live rows when earlier rows expire.

## 7. Automatic continuity

The 0.26 source adds native runtime job references to an ordinary project's
handoff, alongside the authored goal and custom resume seed. Resume with
`get_forge_status(resume=true)` and the exact handoff ID. When currently authorized,
`runtime_continuation_status` reports those jobs before the epoch is cleared.
Cooperating helpers preserve a live job owned by another helper. If its owner
has exited, an authorized status/output read attempts bounded recovery using the
stored process identity; it does not rerun the command. Read the returned job
state and both output streams before treating the work as complete.
Use each returned UUID with `job.status`, then `job.read_output` for stdout and
stderr. A queued acknowledgement may already refer to a completed job. If the
row is unavailable or unauthorized, it is unresolved and must not be replayed.
The bound is 32 native submission attempts per logical epoch and a 16 KiB
extension; this does not capture the latest GUI instruction. A budget handoff
uses a fresh ID when the predecessor is sealed or its native origin belongs to
an earlier epoch, while preserving authored content. Automatic finalized packets
use the existing default `handoff_ready` status; the original authored checkpoint
can remain completed. Signed candidate continuation and scoped Qwen API
consumption passed; installed GUI continuation remains separate in
[the contract](docs/ORDINARY-RUNTIME-CONTINUATION.md).

The model can save compact checkpoints while it works. At context pressure it
saves a resume-ready handoff. Continuity then proceeds without an operator
action in the Continuity view:

1. Forge durably commits the exact handoff.
2. Dashboard shows a 30-second countdown.
3. At expiry Manager activates LM Studio and creates exactly one foreground
   successor through the app's public macOS Accessibility controls.
4. Forge submits:

   ```text
   get_forge_status
   resume=true
   ```

5. The successor must acknowledge the exact handoff identifier.
6. Forge records the predecessor as sealed only after that acknowledgement.

If the rollover limit is crossed while a checkpoint is being prepared, the
current source retains that request until the handoff and actual counts commit
together. A projection-file warning does not hide the committed SQL handoff.
The source rejects acknowledgement reuse after contents change under the same
handoff ID; the changed work requires a fresh handoff ID. Adapter protocol
fixtures also verify that concurrent bootstrap cannot replace an active intent,
a late acknowledgement cannot revive explicit cancellation, and an interrupted
intent can retry after restart.

The installed .18 observed case created and acknowledged a successor but omitted
the newly submitted job UUID; manual delivery recovered its completed output.
Current .26 GUI continuation/threshold acceptance and debugger execution remain
unverified; broad live GUI overlap remains unqualified.
The separately tested managed API handoff and automatic continuation do not
qualify the GUI trigger, successor consumption, or predecessor sealing; see the
[current repair record](docs/LMSTUDIO-RUNTIME-REPAIR.md).

The operation is idempotent across watchdog ticks and Manager restart. When a
failure reaches diagnostics, the current source records the selected handoff,
last processing stage, and the error details available at that stage. An error
before packet selection is identified as such; an underlying cause that was
already discarded cannot be reconstructed. Forge records durable intent before the
GUI action and submitted state after Send, so retry does not open another chat.
The signed Forge Conductor app requires macOS Accessibility access for this host
action; no Forge-held LM Studio token or integrations API request is used.

## 8. Manage continuity data

The **Continuity** view contains:

- a scrollable list of project IDs that have continuity data;
- project selection;
- **Copy Project ID**;
- a packet list under the selected project showing each checkpoint/handoff ID,
  type, source, and timestamp;
- one confirmed **Delete** action that removes only the selected packet or
  multi-selection;
- **Reset** for the selected project's settled automatic continuity history;
- **Clear Cache** for disposable Forge cache data.

There are no checkpoint, rollover, run-selection, timeline, or recovery
controls on this screen. The maintenance controls are directly usable on
Continuity without opening Projects. Packet deletion does not remove other
packets, ordinary project files, instruction packages, policy, credentials, or
project memory. Reset does not advance the project generation, and durable
packets remain until explicitly selected and deleted. Instruction-package
deletion remains on Projects.

## 9. Read Dashboard and evidence

Dashboard presents bounded system telemetry, Forge service health, policy
state, and the automatic continuity countdown. Hidden gauges stop recurring
render work. Its Project status follows the project bound to the active MCP
client, preferring the client with the newest activity when several are live.
A matching nonterminal run is a fallback; a project is not shown as active just
because it is registered. Events & Evidence provides bounded diagnostics and
exports; it does not replace live provider or rollover acceptance.

In the current source, each new diagnostic record has an ID, process-instance
ID, version, and build identity. A tool request and its result share an
invocation ID; failed search results retain their exit code, timeout, and
sanitized stderr, while shell job records retain the durable job ID and
terminal state without changing the tool response. JSON exports contain the
selected records. Markdown renders at most the latest 2,000 and states the
included range and omitted count. The export reads the current master log and
live ring, not rotated files. Startup failures are captured before the application graph exists. **Diagnostics**
can export JSON and Markdown even after a bootstrap failure. If Forge home or
persisted history is unavailable, select a writable export folder; the export
contains bounded live records and explicitly states that persisted history is
omitted. The default-folder action reports its actual write failure and can be
retried with the folder picker. Candidate tests and the installed build are
tracked separately in the qualification record.

## 10. Verification boundary

A green source build proves compilation. A focused unit or UI test proves only
its selected behavior. Release acceptance separately requires the current
signed candidate to pass the complete owner workflow against the owner's
running LM Studio configuration, plus signing, notarization, Gatekeeper,
privileged-service, hardware, and owner acceptance gates recorded in
[ROADMAP.md](ROADMAP.md).

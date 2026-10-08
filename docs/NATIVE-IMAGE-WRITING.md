# Native image pixel writing

## Additive WebP phase — 0.35.0 (48), bounded source/candidate qualification

Current source target is **0.35.0 (48)**. Owning source and direct builds/strict
Debug signature and the exact matching 225-method canonical native run passed.
Actual Qwen write/read consumption and independent production file checks passed.
Seven production native WebP/PNG comparisons passed. Separate initial-document
G3 one each establishes matching 226-method unions with the earlier 225. Complete
GIF/JPEG/TIFF/PNG sections retain
their original evidence, boundaries and NONPASS records.

### WebP tool contract

Existing `image_write` keeps required `path`, `width`, `height`, `content`, optional
`pixel_format: "rgba8"`, its own grant, replay behavior and absent-format default PNG.
Explicit exactly lowercase `format: "webp"` requires a case-insensitive `.webp`
destination; append none. Uppercase format tokens remain invalid. No new input
field, dependency, tool, service, graph member, production runtime or signing
change is introduced. PNG/TIFF/JPEG/GIF contracts remain available.

Input remains canonical padded base64 of tightly packed top-to-bottom straight
RGBA8/sRGB with `pixel_contract: "rgba8-straight-srgb-v1"`. WebP accepts all alpha
bytes 0...255. The simple RIFF container contains one lossless VP8L image;
independent file decoding preserves exact supplied RGBA bytes, including hidden
RGB under alpha zero. Native premultiplied rendering is compared separately
against a PNG reference; it does not promise preservation of rendered hidden RGB.
sRGB interpretation has no raw embedded ICC promise. Animation, photographic
synthesis, image interpretation and a general WebP decoder are not added.

WebP returns `engine: "swift-webp-vp8l"` and WebP-only
`output_contract: "webp-lossless-rgba8-srgb-v1"`. The existing pixel contract
describes supplied input. PNG/TIFF receive no output_contract key; JPEG/GIF
retain their existing contracts and alpha restrictions.

Dimensions remain 1...1024, at most 262144 pixels, exactly width×height×4 decoded
bytes (at most 1048576), canonical base64 at most 1398104 UTF-8 bytes and encoded
output at most 2097152 bytes. The literal encoder preflights complete size before
allocating its single output Data: 178 + raw byte count, maximum **1048754 bytes**.
A partial byte is call-local; no per-pixel Data/array, output lock or retained
callback owner is introduced. Cooperative checks cover alpha scanning, every
2048 pixels, bounded output work and completion. Worker/context/pinned-write/mode/audit
and grant interfaces remain the existing owners.

Pre-cancel/deadline tests do not deterministically exercise cancellation in the
middle of the bit loop. Common-writer late-cancel-before-rename/revocation remains
unexercised source E2. Existing ImageIO native-call preemption remains unqualified
for preceding formats. No product leak, performance or cross-OS claim follows.

### Mechanism and source checkpoints

The external v3 mechanism passed **seven fixtures** and **fourteen native/synthetic
controls**. The independent review additionally passed **twenty-one parser controls**;
its independent file/native fixture checks distinguish exact decoded file RGBA from native
premultiplied rendering against PNG. Native sRGB profile equality is consumer
interpretation, not raw ICC embedding. Independent review
`webp-independent-artifact-review-0350-v3.json`, SHA
`0872978bdcded91d22fa9513c635c78504518e2d74877ebdce735dd923b5e8b6`,
binds 59 reads/5913474 bytes. These controls are not product XCTest methods or
App/CLI/Qwen runs. The v2 initializer-label compilation NONPASS remains retained.

The missing-feature baseline executed one owning method and failed normally
in **5.407 s** with `format must be png, tiff, jpeg or gif`; its original log SHA
`f0f33302e9d31706353dc39ce221dff32a00ed620466077130af39d9144078d1`
remains NONPASS. The same method then passed within the seven-method focused
WebP checkpoint (**14.241 s**, zero failures/skips; log SHA
`056926216fae398fcdc6b326e9a4e545f96807c2b4e9c1452acccd7b55965592`).
Initial support-bundle zero-selected output supplies no coverage. Focused
methods are subsets; repeated executions add no distinct owning methods.

### Current source, graph, build and candidate evidence

Owning source passed **225 distinct methods** in **75.739 s**, normal exit 0,
zero failures/skips. These owning selections exclude G3. Actual declared/
started/passed sets matched; exact readback
`native-webp-owning-source-readback-0350.json`, SHA
`c2814e2db9acea67d51f0c7c6fc71c63ec5a8ea3c9ea14454b762fa586abe3d6`.

| Owning class | Matching source/native distinct methods |
| --- | ---: |
| NativeRasterWriterTests | 40 (12 PNG, five TIFF, seven JPEG, nine GIF, seven WebP) |
| MCPProtocolAndDiagnosticsTests | 44 |
| ToolDefinitionCatalogTests | 35 |
| ProjectInstructionQueueTests | 40 |
| NativeODSReaderTests / NativeODSWriterTests | 13 / 15 |
| PDFWriterTests | 35 |
| Core tool audit | 3 |
| Document-dependent G3 | 1 per route in separate initial-document runs; excluded from owning 225 |

The seven WebP methods cover native-readable one-pixel output, independent
restricted file RGBA inspection and PNG-reference rendering, all alpha values/
dimension edges/maximum noise, worker/strict input/output preflight, malformed
containers, tool metadata/full readback/mode/protections and stale context/own grant.
Retained PNG/TIFF/JPEG/GIF tests passed in both selections. Canonical native
**225** passed in **75.173 s**, normal exit 0, zero failures/skips and the exact
same source method set. Readback `native-webp-owning-native-readback-0350.json`,
SHA `328fbace0917148f8b36de4dca5bd290ff14f14a9e9800e8d037b30429ff3280`;
log SHA `ffe4a06d36b5bf43878cabc07e7f248907c4ab5869653eb648ec0e03e32cd541`.
G3 is excluded from both 225 sets. Separate initial-document G3 passed once in
source/native; exact union comparison establishes matching 226 distinct methods
per route, not one 226-test invocation. Repeated focused/G3 runs add no coverage.

CLI compilation **0.900 s**, app compilation **0.893 s**, ordinary canonical
Debug build **26.412 s** and strict signature **0.143 s** passed, normal exit 0,
unforced and same **464 source inputs**. Source map SHA
`ce81874fa889044ad12a96c7a6ca470a2b71af2c5a92df691b0b5bbae8872ccb`.
Source log SHA `5d679d1bb82bc7720c0b84d018cf34220b7352dc7c1ff8d6acda45fb74aec96c`;
ordinary Debug log SHA
`1510998c43dee44891bee72aae1b2cd64910f7cf655dc56684fa3b5c7bb733b4`;
strict signature log SHA
`7e163472f4ffe58ef869d6ada6e26d51d875dc3b0e3777d9913327ab77fc3227`.
Existing canonical memberships/signing remain; project changes only twelve
marketing and sixteen build-version values. Source/native selected methods
establish no full-suite, GUI, performance or lifetime pass. Native diagnostics
retain DVTAssertionsWarning in IDELaunchSession.m:395 and linkd NSCocoaErrorDomain
4097; no diagnostic-free claim follows.

Strict Debug candidate `native-webp-native-candidate-0350.json`, SHA
`750371a30b90fea43d66a8b40bc4021a0afe60a6df1404d0979bf8e7da554ade`,
binds .35/48, the seven current binaries, packaged source/version inputs,
three protected installed/registration inputs and unchanged prior .34 candidate.
Signature/build identity is separate from actual compiled peer, tool and model
qualification. After App/CLI, 464 source/seven candidate/three protected/seventy-five harness/seven preceding candidate inputs remained unchanged; Qwen after-guards also passed; its harness map contained 76 entries.

### Signed App/CLI, Qwen and native consumers

Signed App and packaged CLI each passed **fifteen logical groups**, **thirty-two
correlated native responses** and **thirty tool frames**, with normal exit 0/
full stdout/stderr EOF, no forced cleanup or unconsumed tail. Outer durations
were **1.334 s** (App) and **0.778 s** (CLI). Nine actual negative calls across
five groups cover typed path, extension/default-format pairing, format type/token
(including uppercase format rejection), dimensions and canonical base64.
Actual **32×64 explicit cancellation** returned cancelled `-32800` and preserved
the existing destination. This immediate cancellation does not close middle-bit-loop
or late-cancel-before-rename/revocation gates.

Each mode produced **nine artifacts**: three WebPs, three candidate PNG references,
plus retained TIFF/JPEG/GIF parity outputs. The WebPs were opaque 2×2 (**194 bytes**),
transparent-hidden-RGB 1×1 (**182 bytes**) and partial-alpha 2×2 (**194 bytes**).
All nine independent file inspections passed, with exact supplied RGBA for the
three WebPs/PNG references/TIFF. JPEG remains lossy and GIF palettized; their
structural checks do not promise exact RGB. Native WebP/PNG comparison is
qualified separately below.

App/CLI actual text and structured tool payloads agreed; complete `fs_read`
base64, metadata and artifact hashes were bound. Guards preserved 464 source,
seven candidate, three protected, seventy-five harness and seven preceding
candidate inputs. Root App readback SHA
`07a696cfb634dea85421e3736acc00b4449c03a5c528fe1de5e4c774dac455d3`;
CLI readback SHA
`d0b7416886c41512f669fdaa14d246ee59e781dc7486785b57fa2a0e09e2ffe9`.

Actual `qwen/qwen3.8-27b` completed **three normal public API responses** in
**34.163 s**, with **three observed Low template events**. Two selected, fully
written/correlated/delivered `image_write`/`fs_read` results were consumed by
completed successor turns. Actual MCP text, structured payload and model
follow-up tool content agreed; strict final acknowledgement matched **194 bytes**,
**2×2**, SHA `fa3a326b5efd57a18eaff8cf16276f3c9d463cc272d11a9b0fdd1da88ea0ce65`.
The native session consumed **eight responses/six tool frames**, including two
preflight PNG calls, normal exit 0/full EOF/unforced. It produced a WebP and a
candidate PNG reference, each passing independent file inspection. This is
artifact metadata acknowledgement; image understanding is unqualified.

Across App/CLI/Qwen, **seven WebPs** and **seven PNG references** passed the
independent exact-file RGBA checks. App/CLI additionally produced six retained
TIFF/JPEG/GIF parity artifacts (twenty actual files total); lossy/palette RGB
limits remain. Guards preserved the 464 source/seven current candidate/three protected/
seven prior candidate inputs; harness maps contained 75 entries for App/CLI
and 76 for Qwen. Qwen readback `native-webp-qwen-root-readback-0350.json`, SHA
`20d0a511d1fa01b4c9564477344b82873b99b487071e218a60ef0b2dddb31385`.

Native ImageIO consumer qualification then passed **seven production WebP/PNG
pairs**: App three, CLI three and Qwen one (**fourteen artifacts**). Each WebP
native premultiplied render matched its PNG reference. Both decoded profiles
were **3144 bytes**, equal to native sRGB SHA
`2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e`.
The two opaque cases also rendered exact raw RGBA. Hidden alpha-zero RGB remains
an independent file-byte claim, not a native-rendering promise; decoded profile
equality establishes no raw ICC embedding.

Compilation passed in **1.979 s**; the native run passed in **0.391 s**, normal
exit 0/unforced. Fourteen success-provider records each observed one admitted
callback/one release/no first error; these bounded external observations
establish no product lifetime or leak closure. The native consumer accounted
**44 input reads/433188 bytes**; root read back **sixteen output files** and
unchanged 464 source/eighty-one harness/seven candidate/three protected/seven
prior candidate guards. Native summary SHA
`62fce7f798bfe2f43c55a2dbbaa0c2833a177f2199c60124d467a1375e70131b`;
root consumer readback SHA
`c6d23a59bc00723c36bca9be663ea638878fba743b36020f513f64be4bb98449`.

### G3 test-only transition and pending delivery

The 225-method selections, builds, candidate, wire and native consumer receipts
remain bound to their immutable **ce81874f…** source map. The applied G3 alignment
changed only two expected literals in existing
`Tests/ForgeConductorTests/G1G10AcceptanceTests.swift`: **0.34.0/47 → 0.35.0/48**.
Every assertion, document marker, selector and 12/16 project-count assertion
remains. Production/resource inputs and graph membership do not change.
The applied test SHA is
`b43be406e874658ed6566c3b1eeb4f5f3c3ebcd49044dd331def4f42e619e3b5`
from before SHA
`d106fa4b55e540a4fdf5eb98e5e34386359b350f9263e6e61440bba37f9fe821`.
Root recorded actual test-only 464-input map
`6dcfd15c3d2b681762e534c0307d7cf4b6b9f3943e61ecc0f4edd66f15348923`;
all other 463 inputs, production/resources/authorities and graph remained unchanged.
Applied receipt SHA `ed1dcf0180d78ce0aadae3e306abba2fad470b39279d860ab4f9125a955dc539`.
The candidate retains its earlier test source. Separate initial-document G3
actually passed once in source (**5.514 s**) and canonical native (**5.334 s**),
normal exit 0/unforced, zero failures/skips. The exact earlier 225 sets plus this
one method establish matching **226 distinct methods** per route; there was no
one 226-test invocation. Source log SHA
`d18f9156030ee180350a8a4fb36b4323224896fcb63b411ae5467ac8bcef77ad`;
native log SHA
`b9212df947747279df4d4fecb041807bbfd3d5d331a3538d71961cae256083af`.
Corrected root readback `native-webp-initial-document-g3-root-readback-0350-v2.json`,
SHA `312560f88f2e252fe19966796bb5ed435d516af4ecbcd8673cad34a2220e2cef`,
retains the exact native `DVTAssertions: Warning` spelling at IDELaunchSession.m:395.
The original v1 filter-miss receipt remains retained; only diagnostic attribution
was corrected. No linkd warning was observed in this G3 run; the earlier native
225 warning remains historical evidence. Initial support-bundle zero-selected
output supplies no coverage. Repeated G3 adds no distinct method.

Initial hygiene and whitespace passed in **0.663/0.140 s**, normal exit 0/unforced;
hygiene log SHA `0a1da2bcff56d3813da8f2f640de03bd77f41016f39fe9175dc06708c1cc9aac`,
whitespace output was empty. Final narrow-document G3/hygiene/link rechecks and
exact owner source/wiki publication, readback and synchronization remain pending.
Their actual outcomes use external closeout receipts.
Published commit identities stay in external closeout receipts; do not insert
self-referential identities into these documents.

The retained installed status/catalog diagnostic is **0.18.0**, with build **28**
independently read from installed Info.plist and **76 advertised tools**;
`web_search`, `web_fetch`, `web_render` were absent. Qwen's reported 66 count was
incorrect; its mechanism is unknown. That read-only observation dispatched no web
request and qualifies no new installation. Installed GUI, production managed-adapter,
full web, all models, other formats, Release and shipment remain open.

## Additive GIF phase — 0.34.0 (47), bounded source/candidate qualification

Current source target is **0.34.0 (47)**. Bounded GIF source/native, direct builds,
strict candidate, signed App/CLI controls, seven independent production artifacts
and actual Qwen write/read consumption passed. Final-document checks and delivery
use external closeout receipts; they do not widen the runtime scope. Complete
JPEG/TIFF/PNG sections below retain their original evidence and NONPASS records.

### Tested GIF contract

Existing `image_write` keeps required `path`, `width`, `height`, `content`, optional
`pixel_format: "rgba8"`, own grant, replay behavior and absent-format default PNG.
Explicit `format: "gif"` requires a case-insensitive `.gif` extension; append none.
TIFF/JPEG contracts remain. No new input field, tool, service, dependency,
production runtime, graph membership or signing protection is introduced.

Input remains canonical padded base64 of tightly packed top-to-bottom straight
RGBA8/sRGB with `pixel_contract: "rgba8-straight-srgb-v1"`. GIF accepts alpha
**0 or 255**. Alpha **1...254** returns `invalid_image_alpha` with exact message
`GIF requires every RGBA8 alpha byte to be 0 or 255; use png or tiff for partial transparency`
before ImageIO encoding or destination writing. Partial alpha is not flattened.

GIF returns `output_contract: "gif-binary-alpha-palettized-srgb-v1"` and
`engine: "apple-imageio"`. ImageIO palette RGB can change even with at most
256 colors; exact decoded RGB and hidden RGB under alpha zero are unpromised.
sRGB interpretation carries no raw embedded ICC promise. Output contains one
image, without animation. The observed ImageIO encoder emitted GIF87a with a
graphic control extension (GCE249). Production normalizes only the finalized
signature to GIF89a. The owning source/native header method compared every
subsequent byte and native provider pixels before/after normalization; all seven
production runtime artifacts independently inspected as GIF89a/full EOF.

Dimensions remain 1...1024, at most 262144 pixels, exactly width×height×4 decoded
bytes (at most 1048576), canonical base64 at most 1398104 UTF-8 bytes and encoded
output at most 2097152 bytes. Worker enforcement, bounded first-error output,
cooperative cancellation, project-context revalidation, pinned write, mode
preservation, audit redaction and grant isolation passed in the selected scope.
Native-call preemption remains unexercised. Late-cancel-before-rename/revocation
also remains unexercised, common-writer source E2 only; this phase does not close it.

### Observed mechanism and source checkpoints

The revised external native mechanism and independent review passed **35**
encodes (**26 GIF plus three PNG, three JPEG and three TIFF**) and **five
controls**, including independent GIF
structure/LZW and native pixel comparisons. Examined binary-alpha cases preserved
alpha; palette color loss was observed. Same-run repeat equality is not cross-OS
determinism; probe release callbacks are not product leak proof. Decoded native
sRGB profile equality does not prove raw ICC embedding. Mechanism signatures
remain the observed GIF87a/GCE combination; normalization was not executed there.

Root review `native-gif-root-mechanism-review-0340-v2.json`, SHA
`9f8a95935a8d87ea2467dbba5cc8738f96dbab55073b555ba70b18efb85c6d96`;
independent review `native-gif-independent-review-0340-v2.json`, SHA
`f6ffd6950fa199db10b513f21a0520d9fc0a29e8eb67468f3b59736e44d7ed25`.
The absent-feature source baseline executed one method and failed with
`format must be png, tiff or jpeg`; retain that NONPASS on its original inputs.
The first focused raster source checkpoint passed **32 methods** in **16.716 s**
(exit 0, unforced; log SHA
`92d57669c644b78c8ca2c4b959dc20aa9c4ef6e60f2b472fea1cdda413c6402d`).
It preceded the ninth GIF header-audit addition. That one source method passed
in **8.667 s** before version advancement (log SHA
`cf3831d30989b55a76aa9e08ec12609c555e1a9132db692d4f7ff4b91ff7db79`).
Neither checkpoint substitutes for current owning source/native selections;
focused methods are subsets and repeated methods add no distinct coverage.

### Current owning source/native and build evidence

The current source selection passed **218 methods** in **72.701 s**, excluding
document-dependent G3. The separate initial-document G3 passed **one method**
in **1.526 s**. Their union is **219 distinct methods**, matching the canonical
native selection, which passed **219** in **72.081 s**. All had zero failures/skips,
exit 0, unforced completion and unchanged matching **464 source inputs**. This
is a selected owning scope, not a full-suite or installed-product pass. Repeating
G3/focused methods does not increase the 219 distinct count.

| Owning class | Distinct methods |
| --- | ---: |
| NativeRasterWriterTests | 33 (12 PNG, five TIFF, seven JPEG, nine GIF) |
| MCPProtocolAndDiagnosticsTests | 44 |
| ToolDefinitionCatalogTests | 35 |
| ProjectInstructionQueueTests | 40 |
| NativeODSReaderTests / NativeODSWriterTests | 13 / 15 |
| PDFWriterTests | 35 |
| Core audit / G3 | 3 / 1 |

The nine GIF methods cover one-pixel/native-readable GIF89a, header/body and
native-provider equivalence, palette/binary-alpha row order, dimensions and
maximum noisy input, first/middle/last partial-alpha rejection, worker/cancel/
bounds, metadata/full readback/mode/protections, stale context/own grant and
malformed-container inspection. Retained PNG/TIFF/JPEG methods passed separately.

Source log SHA `c7a1ac97187289c2d0ef643794d356af2b01c66a5d2b21156faef57ef87fe1e8`;
initial G3 log SHA `c78b12e044daf01f75c623eec7d255804a317f6975b0890d27ac6d71366a1663`;
native log SHA `d8ffc642897bc980aa36f165306ef889926686493ade3c573a29099eacb141d0`.

CLI compilation **0.899 s**, app compilation **0.895 s**, ordinary canonical
Debug build **27.360 s** and strict signature **0.129 s** passed, exit 0,
unforced and same 464-input map. Existing canonical source/resource/test
memberships and signing protections remain; the project changes only twelve
marketing/sixteen build-version values. Source-map SHA is
`6a55d5bc1c82c705be2113057ce732e15e5754ce4f979c1b43575ad5d44ec9c8`.
Destination/DVT launch diagnostics, `nw_path_necp` 22 and linkd `NSCocoaErrorDomain`
4097 remain in native logs. No compiler warning/error was observed in ordinary
Debug; this is not diagnostic-free, performance or lifetime qualification.

Strict candidate `native-gif-native-candidate-0340.json`, SHA
`f8ed4def7fde8b575aac5b70780c3e76c91c8d272c678eee0a743cf645c2f5b4`, binds the
current seven binaries, packaged source/version inputs and three protected
installed/registration inputs. Current seven/protected three and prior .33
candidate seven remained unchanged across exercised App/CLI/Qwen modes.

### Signed App/CLI, production artifact and actual Qwen evidence

Revision-two signed App and packaged CLI each passed **ten logical groups**:
three positive fixtures, six negative groups (**nine actual calls**) and one
actual **32×64 cancellation**. Each consumed **twenty correlated responses**
and **eighteen tool frames**, with normal exit 0 and full stdout/stderr EOF.
Negative cases cover typed path, extension/default-format pairing, format type/
token, dimensions, base64 and partial alpha. Cancellation returned the actual
cancelled result and preserved the destination. Outer durations were **1.192 s**
(App) and **0.866 s** (CLI), without deadline, output cap or forced cleanup.

All **seven actual production GIFs** (three App, three CLI, one Qwen) passed the
independent bounded GIF89a structure, single-image/trailer/full EOF, LZW,
palette and exact binary-alpha oracle. Opaque, all-transparent and mixed-alpha
App/CLI outputs were 62/49/62 bytes. Opaque RGB maximum difference was zero only
for these examined fixtures; the external mechanism observed palette loss.
No general exact-RGB, hidden transparent RGB or raw embedded ICC promise follows.
Runtime artifact inspection is separate from source/native ImageIO decode tests.

Actual `qwen/qwen3.8-27b` completed **three normal API responses** in **33.875 s**;
Low was observed in all three template events. Two actual `image_write`/`fs_read`
results were selected, attempted, fully written, correlated, verified, delivered
and consumed by later completed turns. Actual MCP text, structured result and
follow-up API tool content agreed. Native transport consumed **six responses**
and **four tool frames**, exit 0/full EOF. Final acknowledgement matched the
strict four scalar fields: **62 bytes**, **2×2**, SHA
`dabdcab74e352ac7c76018c363f4f6819607ca39abf7d1a4f6e9bb79a4581f17`.
This is metadata acknowledgement, not image understanding or photographic synthesis.
All source/current candidate/protected/harness/owned-artifact guards remained true.

Root qualification `native-gif-root-qualification-0340.json`, SHA
`a46adb4acd70ad28d78fd654ae49b2314fa67038c9657c7c5a6f990340677c98`, binds actual
method sets, terminal receipts, candidate and revision-two runtime summaries.

The separate **105 external parser/LZW and synthetic failed-native owner controls**
passed: `native-gif-parser-owner-controls-0340.json`, SHA
`e63abb38a3a619e5f6ce2b0f4e117ca2f844983831550c2dc78e601bc7da589c`.
They exercise the frozen independent parser and synthetic gate fixtures; they
are not product XCTest methods, 35 mechanism encodes or additional real runtime
runs. Original absent-feature NONPASS and earlier checkpoints retain their scope.

### Delivery and retained host boundary

Final-document G3 and exact source/wiki publication, readback and synchronization are tracked in external closeout receipts.
No source/wiki commit identity is inserted into its own documents. These scoped
source/candidate/API results do not qualify an installation or shipment.

The retained fresh installed status/catalog diagnostic is **0.18.0**, with build
**28** independently read from installed Info.plist and **76 actual tools**;
`web_search`, `web_fetch`, `web_render` were absent. Qwen's count of 66 was wrong.
That status observation qualifies no installation or web request.
Installed GUI, production managed-adapter, full web, all models, other formats, Release and shipment remain open.
Pixels are supplied by the caller; palette conversion and model metadata
acknowledgement establish no photographic synthesis or image understanding.

## Additive JPEG phase — 0.33.0 (46)

Current source target is **0.33.0 (46)**. Bounded opaque JPEG and preserved
PNG/TIFF passed matching 210-method source/native selections, CLI/app compilation
and ordinary Debug. Strict candidate, signed App/CLI controls, independent raw JPEG inspection and Qwen API consumption passed.
Final-document G3 passed in source and native. Source/wiki publication, readback and synchronization are tracked in external closeout receipts.
The complete .32 TIFF/.31 PNG sections below retain their tested identities.

### JPEG tool contract

`image_write` retains required `path`, `width`, `height`, `content` and its own
grant. The existing `format` enum adds `jpeg`; JPEG requires explicit
`format: "jpeg"` and `.jpg`/`.jpeg`, accepting extension case-insensitively and
appending none. Absent format still selects PNG with `.png`; explicit TIFF and
`.tif`/`.tiff` retain their contracts. No new schema input/tool, dependency,
service, application runtime or source/resource/test membership is introduced.

All branches take canonical padded base64 of tightly packed, top-to-bottom
straight RGBA8/sRGB pixels with optional `pixel_format: "rgba8"`. JPEG requires
every alpha byte to be 255. Otherwise it returns `invalid_image_alpha` with
`JPEG requires every RGBA8 alpha byte to be 255; use png or tiff for transparency`
before ImageIO encoding or destination writing; it does not flatten transparency.

JPEG uses the call-local named-sRGB CoreGraphics/ImageIO path, fixed quality
**1.0**, no thumbnail and `engine: "apple-imageio"`; output remains **lossy**.
`pixel_contract: "rgba8-straight-srgb-v1"` describes supplied input, not exact
decoded JPEG pixels. JPEG alone adds
`output_contract: "jpeg-opaque-lossy-srgb-v1"`; PNG/TIFF output fields remain.
Observed raw JPEG tagging is Exif sRGB (`ColorSpace=1`) and matching dimensions;
no APP2 ICC profile is promised. Native-decoded sRGB profile equality is a
separate consumer observation, not evidence of raw file embedding. Native
decoding supplements bounded independent marker/Exif inspection; it is not an
independently implemented entropy decoder or general JPEG acceptance.

Each dimension remains 1–1,024, total pixels at most 262,144, decoded bytes
exactly width × height × 4 and at most 1,048,576; base64 UTF-8 at most 1,398,104;
encoded output at most 2,097,152. Existing transport/managed-run argument caps
remain, including durable broker complete arguments at the smaller of the
project allowance and 65,536 bytes. Worker ownership, bounded first-error output,
cancellation/deadlines, project revalidation, pinned-write mode/durability, audit
redaction, idempotent replay and PNG/TIFF defaults remain under their existing
owners. Alpha scanning checks cancellation every 8,192 bytes; surrounding checks
do not establish preemption of an ImageIO call in progress.

The common `FilesystemToolPack.writePinnedText` checks cancellation before its
`fsync`/rename sequence. Late cancellation or revocation in the interval before
rename has **not been exercised** in this phase; this remains a source **E2**
boundary, not observed runtime failure, proven atomic revocation or completed
coverage. Preserved-destination cancellation controls do not close that boundary.

### JPEG mechanism and source/native evidence

Root-owned external mechanism compilation/run returned 0/unforced in
0.682/0.678 s. All fourteen JPEG/PNG outputs decoded; eleven raw JPEGs had one
8-bit three-component SOF0/C0 image, Exif `ColorSpace` tag `0xA001` SHORT count1/value1
and matching `0xA002`/`0xA003` LONG count1 dimensions, with no APP2 segment. Three PNG
controls preserved exact orientation/pixels. Five bounded output-limit,
pre-cancel, expired, callback-cancel and limit-before-cancel controls matched
expected first-error/ownership observations. Flat/quadrant JPEG interiors
observed at most one RGB level of error; noisy and alpha diagnostics do not
promise exact recovery or authorize nonopaque production JPEG. Call-local
release observations are not product leak proof. Root review:
`native-jpeg-root-mechanism-review-0330.json`, SHA
`cc283292f6f90ea02d36d35e41ac5e22ecca9d9cedddefe9886923580fbb912d`.

The absent-feature baseline executed one method and failed with
`format must be png or tiff`; retain its NONPASS receipt
`native-jpeg-absent-feature-baseline-source-0330-terminal.json`. The later
focused raster selection passed 24 methods, 9.970 s, exit 0/unforced; it is a
subset of the owning selection, not additional distinct coverage.

Owning source and canonical native passed the same **210 distinct methods**,
zero failures/skips: 24 raster, 44 MCP, 35 catalog, thirteen ODS reader, fifteen
ODS writer, 35 PDF, forty queue, three audit and one G3. New JPEG cases verify
lossy low-frequency interior tolerance (two RGB levels), native opaque decoding,
raw Exif/structure, dimensions/max noisy input, first/middle/last alpha rejection,
strict bounds/worker/cancel/deadline, aliases/metadata/full binary readback/mode,
failed-write/symlink cleanup, grants/context/audit and malformed inspector
fixtures. Existing twelve PNG/five TIFF cases retain exact-pixel contracts.
The maximum 1 MiB direct-encoder test is separate from inline MCP argument limits.

| Executed .33 check | Terminal result and retained receipt |
| --- | --- |
| Owning source | 210 passed, exit 0/unforced, 71.764 s; `native-jpeg-owning-source-0330-terminal.json` |
| Canonical native | Same 210 under existing `ForgeConductorTests` workspace/scheme, exit 0/unforced, 71.688 s; `native-jpeg-owning-native-0330-terminal.json`, `native-jpeg-native-0330.xcresult` |
| CLI/app compilation | Exit 0/unforced, 0.898/0.901 s; `native-jpeg-{cli-build,app-compilation}-0330-terminal.json` |
| Ordinary Debug | Exit 0/unforced, 26.165 s; `native-jpeg-ordinary-debug-0330-terminal.json` |

All owning/build checks retained the same unchanged **464-input** map, SHA
`9e692840ed751d4d1c1b1a278e7ea6cf00c31ec985ff75afb8b4f3f90c3ff18f`.
Method-set SHA is
`8baec427a0ef792a9b8c6a5ba555d2f633aaec64f8a6b2c58b7b50cad862567e`;
accounting receipt SHA
`29febfbb989daf42081315f213c382dba1217ce885a389b97336c4c92074bcd6`.
Source/native logs:
`47af487bdcbd58e1b1f2ac72b569ff3333b181b11bca33235c48e2b1b53007df` /
`86d027eab9f469bfb96052a4f26494bb0de738b4fe66753d93e5aca8309533e1`.
Ten affected memberships remain in existing targets; the canonical project
changes only twelve marketing/sixteen build declarations. Package/workspace
bytes are unchanged. Authority/graph review is
`native-jpeg-authority-graph-and-inputs-0330.json`.

Owning-native and ordinary Debug logs retained matching-destination warnings;
the owning-native log also retained a DVT `setRunnablePIDWithDiagnostics`
launch warning. No compiler warning or QoS marker was found in those reviewed
logs. These selected log observations do not establish diagnostic-free, GUI,
performance/lifetime or leak qualification.

### Candidate identity and delivery boundary

The ordinary Debug candidate passed strict deep signature verification,
0.129 s, exit 0/unforced; log SHA
`403879d502c464cdc520ee331b182bd59b844ea0a32f26cbac580f2d7adb04f2`.
Exact seven-binary/resource binding and three protected installed-app/LM Studio
registration hashes stayed unchanged, as did the preceding .32 candidate.
Candidate manifest SHA is
`32c7a7c855cff5981fa6c3d79c7053bd5887c1c6ba2bfbcdeeef0b05fa536edf`;
packaged docs source SHA is
`e89c818fba57dafb36cb26116cd7d48cee0d09ae3a09e17030d9a00456c44809`.
Candidate path is `native-debug-jpeg-0330/Build/Products/Debug/Forge Conductor.app`
under the retained evidence directory; it was not installed.

Actual signed .32/.33 App `tools/list` catalogs each contained 84 unchanged
names; the sole changed descriptor was `image_write`'s JPEG enum/path/description.
Receipt: `native-jpeg-actual-catalog-parity-0330.json`, SHA
`8301f2fe14f45bbfd85269410ceca128584b6229fc293d6fb1eaa10af108e055`.
This candidate catalog is separate from the installed .18 76-tool observation below.

### Signed JPEG tool and Qwen scope

Signed App and embedded CLI each passed ten logical groups: three positive
JPEG writes, six negative groups with nine actual calls and one actual
cancellation. Each consumed twenty correlated native responses/eighteen tool
frames and then exited normally with full stdout/stderr EOF. Each produced a
2×2 opaque `.jpg` (987 bytes), 1×1 `.jpeg` (775 bytes) and 32×32 flat `.JPEG`
(821 bytes), with full base64 `fs_read` matching the file. Number paths,
wrong-extension/missing-format pairs, boolean/unsupported format, invalid
dimensions/base64 and nonopaque alpha preserved destinations. Actual bounded
32×64 cancellation returned `-32800`, preserved its destination and left no
residual file; it does not establish interruption at a particular encoding point
or late-cancel-before-rename/revocation acceptance.

All seven actual JPEGs (three App, three CLI, one Qwen) passed independent
bounded baseline marker/scan/Exif inspection with complete EOI/file EOF,
`ColorSpace=1`, matching dimensions and no APP2 ICC. The runtime oracle inspects
raw structure/tagging; these seven artifacts were not separately native-decoded
or checked for fidelity. Production native decoding and low-frequency tolerance
are separate source/canonical-native writer cases. Six malformed parser controls
rejected missing EOI, truncated/oversized segment ranges, a second image,
trailing bytes and wrong Exif color. Root App/CLI artifact review is
`native-jpeg-app-cli-root-artifact-review-0330.json`, SHA
`c02e7be9d530349c488f94e27996e6b56af896d083d52b17297d488ebc55f132`.

Qwen `qwen/qwen3.8-27b` selected JPEG `image_write` then `fs_read` through the
supported isolated API workflow. Two actual results were attempted, fully
written, correlated, verified, delivered and consumed across three normal API
responses, actual Low 3/3. Actual MCP text, structured payload and completed
follow-up request input matched; full readback equaled the produced file.
Native transport consumed six correlated responses/four tool frames and exited
normally with full EOF. The final acknowledgement contained exactly `sha256`,
`bytes_written`, `width` and `height`, matching 987 bytes/2×2 and SHA
`ec63a6671870e40790b6812ef2abd2d2c3e3aac332f340bb0b16da73a15eb01b`.
This is metadata acknowledgement, not image understanding or photographic synthesis.

Root consumer review is `native-jpeg-root-consumer-review-0330.json`, SHA
`081636d2d4c43e326c23b4b43013d9b77db07f7708f7fc237ef44c1e9fd3acc5`.
App/CLI/Qwen outer terminal times were 1.141/0.666/34.576 s, exit 0/unforced,
full EOF, no deadline/output-cap hit. Current source 464, candidate seven,
protected three, harness and owned artifacts remained unchanged in all modes.
These checks do not establish general JPEG decoding, exact lossy RGB, installed
GUI, production managed-adapter, full web, all models, Release or shipment.

Final-document G3 passed in source and native. Source/wiki publication, readback and synchronization are tracked in external closeout receipts. Repeated document G3 does not increase the 210 distinct method count.

Final-document source G3 executed one method and passed in 1.407 s; corrected
canonical native G3 executed the same one method and passed in 2.071 s. Both
exited 0, unforced, with the 464 source inputs unchanged. Retained receipts:
`native-jpeg-final-document-g3-source-0330-terminal.json` and
`native-jpeg-final-document-g3-native-retry-0330-terminal.json`. The first native
invocation selected `ForgeConductorAppTests` outside the chosen scheme; it exited
70 without running tests and remains a NONPASS. The corrected selector was
`ForgeConductorTests/G1G10AcceptanceTests/testG3_VersionAndReleaseDocumentsAreAligned`.
The native matching-destination and DVT launch warnings remain in the log.

Installed GUI, production managed-adapter, full web, all models, other formats, Release and shipment remain open.

### Separate installed status/catalog observation

A fresh October 8 installed LM Studio GUI status diagnostic used
`qwen/qwen3.8-27b`. The returned status and both actual model-generation
catalogs contained **76 tools**, with `web_search`, `web_fetch` and `web_render`
absent. Qwen's final count of 66 is a counting error; its absence-of-web statement
is supported. The returned version was `0.18.0`; build `28` was independently
read from the unchanged installed Info.plist, not returned by `get_forge_status`.
No web request was dispatched. This is a scoped status/catalog observation,
not new-candidate, full-web, all-model or installation acceptance. Receipt:
`installed-web-catalog-fresh-status-readonly-0320.json`, SHA
`c863cab657c0cd33bbc278a7f6719ddef54472022e439117aaf8bec3d90e89db`.

Performance/lifetime/leak, automatic rollover and photographic synthesis remain
separate gates. The following TIFF/PNG records retain their historical scope.

## Additive TIFF phase — 0.32.0 (45)

Current source target is **0.32.0 (45)**. Bounded native Swift TIFF writing and
preserved PNG defaults passed matching 203-method source/native selections,
direct builds and strict candidate checks. Scoped App/CLI controls, independent
TIFF artifact inspection and actual Qwen API consumption passed. Final
document G3 passed source/native. Exact source/wiki publication/readback/
synchronization identities will be retained in external closeout receipts.
The .31 PNG results below retain their tested identities.

### TIFF tool contract

`image_write` retains its name and required `path`, `width`, `height`, `content`
fields, own grant, strict original MCP dimension-token validation and
`rgba8-straight-srgb-v1` pixel contract. TIFF requires explicit `format: "tiff"`
and a `.tif` or `.tiff` destination; no extension is appended. An absent `format`
continues to select PNG with an explicit `.png` destination. The format enum
adds `tiff`; the JSON field names and PNG defaults remain available.

Both branches take canonical padded base64 of tightly packed, top-to-bottom
straight RGBA8/sRGB pixels. Each dimension remains 1–1,024; total pixels at most
262,144, decoded bytes exactly width × height × 4 and at most 1,048,576, base64
UTF-8 bytes at most 1,398,104 and encoded output at most 2,097,152. Existing
transport/managed-run argument caps still apply, including the durable broker's
complete-argument cap at the smaller of the project allowance and 65,536 bytes.

TIFF uses classic little-endian TIFF, one sorted IFD, no compression, top-left
orientation, chunky RGBA8 and `ExtraSamples=2` (unassociated alpha). It embeds
the native `CGColorSpace.sRGB` ICC data. Strips contain whole rows, at most
65,536 bytes each and at most seventeen strips within the dimension/pixel bounds.
The writer preflights total layout/output before emission and reuses the bounded
first-error output owner. Pixel output is copied in cancellable 8,192-byte chunks.
PNG retains its CoreGraphics/ImageIO engine and surrounding cancellation checks;
those checks do not preempt an ImageIO call already in progress.

The TIFF tool branch returns `engine: "swift-tiff-rgba8"`; PNG keeps
`engine: "apple-imageio"`. Existing project revalidation, pinned destination
write, mode/durability behavior, audit redaction, idempotent replay and docs/tool
classification remain the contracts to exercise. No new service, cache,
recurring work, dependency, runtime, tool name or durable idempotency argument is
introduced. Encoding supplied pixels does not establish photographic synthesis.

### TIFF evidence and remaining gates

The missing-feature baseline executed one writer method and failed with
`format must be png`; it remains NONPASS. The first local Swift writer checkpoint then
executed and passed **fourteen source methods**, zero failures/skips: the twelve
existing PNG/guard/tool cases plus `testTIFFAlphaAndDimensionEdgesPreserveStraightRGBA`
and `testMaximumNoisyPixelInputProducesOneBoundedExactTIFF`. The new cases inspect
raw TIFF strips, exact RGBA including RGB under zero alpha, native sRGB ICC bytes,
1×1, tall/wide and seventeen-strip edges, and maximum 1 MiB noisy input. This
checkpoint does not establish TIFF tool integration or current native acceptance.

`swift test --filter NativeRasterWriterTests` returned exit 0/unforced in
13.109 s, full terminal output, no deadline/output-cap hit, with its 464 checkpoint
inputs unchanged. Receipt: `native-tiff-writer-focused-source-0320-terminal.json`;
log SHA `4ca894aae69c7f488be1880ae0505f6fca1bc12459afcb83fc71561a9f159fb9`.
The original failed baseline is retained in
`native-tiff-absent-feature-baseline-source-0320-terminal.json`.

The preceding-map ImageIO TIFF mechanism control encoded a TIFF but independent
inspection found associated alpha and failed the straight RGBA contract. The
AppKit reference preserved the fixed 2×2 control only; its allocated representation
is not the bounded production writer. Those probes are retained in
`native-raster-tiff-mechanism-root-review-0310.json`; neither is a Forge invocation,
maximum-input, native-workspace, signed-runtime or model pass.

The later integrated source checkpoint passed **21 methods** (seventeen raster
writer plus four catalog), zero failures/skips, outer 15.438 s; log SHA is
`b590745af4126b65882eee64ee5665bb0eada757829b6f7c27d7085361f30762`.
Both focused checkpoints retain their own input maps. Their methods are subsets
of the later owning selection, not additional distinct coverage.

Owning source and matching canonical native each passed **203 distinct methods**,
zero failures/skips: seventeen raster, 44 MCP, 35 catalog, thirteen ODS reader,
fifteen ODS writer, 35 PDF, forty queue, three audit and one G3 method. The added
integration cases verify native ImageIO TIFF consumption with exact straight
pixels/native sRGB ICC; worker/already-cancelled/expired/strict-output/input bounds;
and TIFF aliases, metadata/base64 readback/mode, mismatch preservation,
symlink/rename cleanup, denied grants and audit redaction. Existing PNG cases
and neighboring document/protocol/queue contracts remain in the owning selection.

| Executed .32 check | Terminal result and retained receipt |
| --- | --- |
| Owning source | 203 passed, exit 0/unforced, 68.835 s; `native-tiff-owning-source-0320-terminal.json` |
| Canonical native | Same 203 under `ForgeConductorTests`, existing workspace/scheme, exit 0/unforced, 69.751 s; `native-tiff-owning-native-0320-terminal.json` and `native-tiff-native-0320.xcresult` |
| CLI / app compilation | Exit 0/unforced, 0.994/1.002 s; `native-tiff-{cli-build,app-compilation}-0320-terminal.json` |
| Ordinary Debug / strict signature | Exit 0/unforced, 24.764/0.131 s; `native-tiff-{ordinary-debug,candidate-strict-signature}-0320-terminal.json` |

All owning/build checks retained the same unchanged **464-input** map, SHA
`b951deb3f7d50dfc1d76e1cf061c54127c37b3559c32e020deda9a315fde419e`.
Exact method-set SHA is
`6f0dca03a9ab81283b7f097db495c603de8b00ba451c993a955bcc7caf6d53bf`.
Source/native log SHAs are
`d8ac19ea18a36dc15f3eb7e6328191e3f62675dd5dd3f7d4a0205eee3b77d6d0` and
`d862399009dd91629675dc633a5f6720536b973dd619f7823daabe4cf1fe93a9`.
Ten affected source/resource/test memberships remain in their existing targets;
the canonical project changes only twelve marketing and sixteen build settings.
Package/workspace bytes remain unchanged.

Native diagnostics remain: one matching-destination warning, fourteen NECP,
five unconnected-network, fifteen PDF structure-tree, one PDF logged-error,
eight linkd and two thumbnail lines. Two PNG consumer/finalize errors occurred
inside its passing output-limit negative case. No compiler warning or QoS block
was found in selected logs. The diagnostic review is
`native-tiff-native-diagnostic-review-0320.json`; it is not diagnostic-free,
GUI, performance, lifetime or leak qualification.

### Signed TIFF tool and Qwen scope

The ordinary Debug candidate passed strict signature and exact seven-binary/
resource binding, preserving the three installed-app/LM Studio registration
hashes and the preceding .31 candidate. Candidate manifest SHA is
`e692a9b802e737ad64db617830252b8bdb04b85f420da17b8470297f9808c754`;
packaged docs source SHA is
`c4d6a71bc23a6a667e9abe9272ccc05ae8bf46259d8373f495c46c86459f58c7`.
The candidate is `native-debug-tiff-0320/Build/Products/Debug/Forge Conductor.app`
under the retained evidence directory; it was not installed.

App and embedded CLI each passed eight logical groups: three positive TIFF
writes, four negative groups with five actual calls, and one actual cancellation.
Each consumed sixteen correlated responses and fourteen tool frames, then exited
normally with full stdout/stderr EOF. Each wrote an exact 2×2 opaque TIFF
(3,390 bytes), 2×2 partial/zero-alpha TIFF (3,390 bytes) and 1×1 opaque TIFF
(3,378 bytes), then consumed full base64 `fs_read` results. Number paths,
wrong-extension/missing-format pairings, invalid dimensions and invalid base64
preserved their destinations. Actual cancellation for bounded 32×64 input
returned `-32800`, preserved the destination and left no residual file; it does
not establish interruption at a particular encoding point.

Independent classic TIFF header/IFD/tag/strip and raw RGBA inspection passed
all seven produced TIFFs, preserving every supplied straight RGBA byte including
nonzero RGB under zero alpha. Each embedded the exact root-bound native sRGB ICC:
3,144 bytes, SHA `2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e`.
The alpha artifact SHA is
`fbc0545645b4b5400ff276b958e4779ad3982f9060cca4be3496c2e50b185b4b`.
These fixed runtime artifacts are separate from the maximum-input and
seventeen-strip source/native cases. Current runtime artifacts are TIFF;
PNG runtime receipts below retain their .31 candidate scope.

Qwen `qwen/qwen3.8-27b` selected TIFF `image_write` then `fs_read` in an isolated
supported API workflow, consumed both actual verified tool results and finished
across three normal responses with actual Low 3/3. Native transport consumed six
correlated responses and exited normally with full EOF. The strict final JSON
contained exactly `sha256`, `bytes_written`, `width` and `height`, matching the
3,390-byte/2×2 alpha artifact. This is metadata acknowledgement, not image
understanding or photographic synthesis.

Root consumer review is `native-tiff-root-consumer-review-0320.json`, SHA
`66cf6c92b17660c97ca205bab021b8ecc28e98754d91b22ae6f46d2bf8e5e480`. App/CLI/Qwen outer terminal times were
1.214/0.650/35.734 s, exit 0/unforced,
full producer EOF, no deadline/output-cap hit. Source 464, candidate seven,
protected three and harness inputs remained unchanged. These are scoped
candidate/API checks; other formats and photographic synthesis remain separate.

The final document check executed and passed one G3 method each in source
(1.583 s) and canonical native (1.859 s), exit 0/unforced, no deadline/output-cap
hit and the same unchanged 464-input map. Receipts are
`native-tiff-final-document-{source,native}-g3-0320-terminal.json`; native result
is `native-tiff-final-document-g3-0320.xcresult`. Source/native log SHAs are
`0c30c223fcd277f35c89c53231a7f3ce457ca92c9a2043d6804efa8c5cc91df2` and
`965863f0a409b9c1eded5a828b04b389ecd81f5b4dd2f6352bb6e7a8b5696b40`.
The native document check retained a matching-destination warning and a DVT
`setRunnablePIDWithDiagnostics` warning; no compiler warning or QoS block was
found in that selected log. This repeated G3 method does not add to the **203
distinct methods**. Exact source/wiki publication/readback/synchronization
identities will be retained in external closeout receipts. Installed GUI,
production managed-adapter, full web, all models, other formats, Release and
shipment remain open.

<a id="native-png-pixel-writing"></a>

## Preceding 0.31.0 (44) PNG qualification

The preceding source target is **0.31.0 (44)**. Bounded `image_write` passed matching
198-method source/native selections, direct builds and strict candidate checks.
Scoped App/CLI controls, independent artifact inspection and Qwen API consumption
passed. Final document G3 passed in source and native; publication/synchronization receipts will be retained externally.
The installed application and LM Studio registrations remain separate.

## Observed mechanism

On this host, native ImageIO created an opaque 2×2 PNG and a second 2×2 PNG
with partial and zero alpha. Independent PNG signature, chunk CRC, bounded zlib
and scanline-filter decoding recovered all sixteen input RGBA bytes exactly,
including nonzero RGB beneath zero alpha, in their original row order.
The native premultiplied bitmap readback changes those transparent color bytes;
it is a separate representation, not an exact straight-alpha comparison.

The native destination inventory lists PNG, JPEG, GIF, TIFF, BMP and ICO, but
does not list WebP. Those mechanism probes encoded PNG only; other listed
formats were not exercised. The retained
`native-raster-imageio-{probe,alpha-probe}-output-0300` receipts describe external
mechanism probes on the preceding source map, not a Forge tool or model test.

## Tool contract

`image_write(path, width, height, content)` requires a nonblank string path
without NUL and an explicit `.png` extension. `content` is canonical padded
base64 for tightly packed, top-to-bottom row-major RGBA8 pixels in sRGB, with
straight alpha. Optional `pixel_format` is `rgba8`; optional `format` is `png`.
Other formats and JSON types are rejected rather than coerced. MCP dimensions
are validated from original JSON number tokens before Foundation can round them.

| Boundary | Limit |
| --- | --- |
| Width / height | Each 1 through 1,024 |
| Total pixels | 262,144 |
| Raw RGBA bytes | Exactly width × height × 4, at most 1,048,576 |
| Base64 UTF-8 bytes | At most 1,398,104 |
| Encoded PNG | 2,097,152 bytes |

Transport and managed-run argument bounds still apply. The durable broker caps
the complete arguments at the smaller of the project allowance and 65,536 bytes;
it does not grant the full pixel-input limit to every invocation path.

The call-local CoreGraphics image and ImageIO destination run on the existing
worker path. The native data consumer checks its byte cap before appending and
retains the first cancellation, deadline or output error. Checks surround native
encoding; they do not claim to interrupt an ImageIO call already in progress.
There is no new service, recurring task, cache, dependency or application runtime.

The existing pinned writer publishes the complete encoded bytes after project
revalidation. It preserves regular-file mode and uses no-follow parent descriptors,
bounded writes, file fsync, rename and directory fsync. A durability failure after
rename requires destination inspection before retrying. Success returns path,
format, engine, dimensions, pixel format/color space, encoded byte count and SHA,
raw pixel byte count and `rgba8-straight-srgb-v1` contract.

`image_write` requires its own grant. Builtin Docs and ordinary project defaults
enroll it; custom denials and imported explicit narrow grants retain their scope.
It is classified as an idempotent document mutation, without a durable idempotency
argument. Existing audit redaction covers `content`.

This tool encodes supplied pixels. Photographic synthesis, drawing primitives,
other image formats, animation, full browser access, all models, installed GUI,
Release and shipment remain separate requirements.

## Verification and remaining gates

The two external native mechanism probes and independent pixel inspections passed.
The owning source and matching canonical native selections then each passed
**198 distinct methods**, zero failures/skips. Their identical method set contains
twelve raster, 44 MCP, 35 catalog, thirteen ODS reader, fifteen ODS writer,
35 PDF, forty queue, three audit and one G3 case. The focused 21-method pass is
a subset of 198, not additional coverage or a full-suite result.

The twelve raster cases verify exact straight-alpha/row-order pixels, nonzero RGB
under zero alpha, 1,024×256 noisy input at the 1 MiB limit, single-pixel and tall/wide
edges, strict base64/types/options, main-thread refusal, already-cancelled/expired
requests, authoritative consumer-cap errors, pinned-write mode/readback/audit,
symlink/rename cleanup, stale contexts, exact grants and owner-authorized host-wide
access. Four MCP cases exercise original number tokens under NDJSON,
Content-Length and EOF framing, plus in-process rejection/correlation/ping and
destination preservation. They do not establish external App/CLI wire acceptance
or cancellation during an in-flight ImageIO call.

| Executed check | Terminal result and retained receipt |
| --- | --- |
| Focused source | 21 passed; exit 0/unforced, 31.720 s; `native-raster-focused-source-0310-terminal.json` |
| Owning source | 198 passed; exit 0/unforced, 58.841 s; `native-raster-owning-source-0310-terminal.json` |
| Canonical native | Same 198 passed under `ForgeConductorTests`, existing `ForgeConductor` scheme/workspace; exit 0/unforced, 82.947 s; `native-raster-owning-native-0310-terminal.json` and `native-raster-native-0310.xcresult` |
| CLI compilation | Exit 0/unforced, 1.015 s; `native-raster-cli-build-0310-terminal.json` |
| App compilation | Exit 0/unforced, 1.204 s; `native-raster-app-compilation-0310-terminal.json` |
| Ordinary Debug build | Canonical workspace/scheme, macOS; exit 0/unforced, 25.252 s; `native-raster-ordinary-debug-0310-terminal.json` |

All checks retained unchanged, matching **464-input** maps, SHA-256
`dbd3310feca851d7519e43f9cc9daddbc8de74f6289fa2207b0215ef6558794e`.
The exact 198-method set SHA is
`4a9546ce5ff0928da9203cdc914ce007147daef6af371ce31d2f7973c685a6b5`.
Source/native log SHAs are
`029180055147e9c2ac5bde1e80231062b1fe8d180d4f85dbcb3c1942ca5253f4` and
`b220c65ce7d21740c2794b63f0e8150872a070c2a8b0119ed6c0d81c2af7f8fd`;
ordinary Debug log SHA is
`066e7f807bbfa7a4834ffe8356b02c1afc558f1a6ee3c907aafe44ad34778269`.
Receipts are retained under
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-07-project-web-qwen`.

The canonical graph adds only writer/test membership plus current version settings;
existing targets, Package and workspace are retained. No compiler warning or
QoS block was found in these selected logs. Native tests and ordinary build each
reported a first-matching-destination warning. Native framework diagnostics remain:
fifteen PDF structure-tree, nine NECP, eight linkd, two CG-thumbnail and ten
unconnected-network lines. Two ImageIO consumer/finalize errors occurred inside
the passing consumer-output-limit negative case. These observations are not a
general GUI, performance, lifetime or leak qualification.

## Signed tool, artifact and Qwen scope

The ordinary Debug candidate passed strict signature and seven-binary/resource
checks, preserving the three installed-app/LM Studio registration hashes. Candidate
manifest SHA is `b9ee433e248c2b21b1a3e3d00fa8d68ceacf6b0c55bf1095f88a666d88e03871`.
The candidate is `native-debug-raster-0310/Build/Products/Debug/Forge Conductor.app`
under the retained evidence directory; it was not installed.

App and embedded CLI each passed eight controls, fifteen correlated responses
and thirteen tool frames, with normal exit/full stdout and stderr EOF. Each wrote
an exact 2×2 opaque PNG (171 bytes), 2×2 partial/zero-alpha PNG (175 bytes) and
1×1 opaque PNG (163 bytes), then consumed full base64 `fs_read` results. Number
paths, wrong extensions, invalid dimensions and invalid base64 preserved their
destinations. An actual cancellation notification for bounded 32×64 input returned
`-32800` and preserved the destination with no residual file. That case does not
prove preemption of an ImageIO call already in progress.

Qwen `qwen/qwen3.8-27b` selected `image_write` then `fs_read` in an isolated API
workflow, consumed both actual tool results, and finished across three normal
responses with actual Low 3/3. Native transport consumed six correlated responses
and exited normally with full EOF. The 175-byte 2×2 PNG independently preserved
all sixteen supplied straight RGBA bytes, including RGB beneath zero alpha.
The final strict four-field JSON acknowledged SHA, bytes, width and height only;
it is metadata acknowledgement, not image understanding or photographic synthesis.

Independent signature/IHDR/chunk-CRC/bounded-zlib/scanline-filter inspection passed
all seven produced PNGs. The alpha artifact SHA is
`f5755a989ceea1d57653d13cbbe866f0d8d93b9fe63564d7ffce26cf949ecd26`.
Root consumer review is `native-raster-root-consumer-review-0310.json`, SHA
`ee5c6557e688e4ac88a3b61d2d06ce93af27b11e295b6a0d9a4fa5c89e6851f9`;
App/CLI/Qwen outer terminal times were 1.345/0.637/30.588 s, exit 0/unforced,
without deadline or output-cap hits. Source 464, candidate seven, protected three
and harness inputs were unchanged. Original ODS and web receipts retain their
tested source and candidate identities.

The changed documents passed one G3 method each in source (3.475 s) and native
(4.941 s), exit 0/unforced, on the same 464-input map. Receipts are
`native-raster-final-documents-G3-{source,native}-0310-terminal.json`; source log
SHA is `ad45923b2115fca72e53d2d27286f26b743873169838e899a1b25e83cfe9d308`,
native log SHA is `e9510b4dd1b42dddb929225a940a871ea3e71bce38d13c0c9d19939eedde4979`.
Exact source/wiki publication/readback/synchronization identities will be retained
in external phase-closeout receipts. The repeated G3 method does not increase
the 198 distinct source/native method counts. Other formats, installed GUI,
production managed-adapter, full web, all models, Release and shipment remain open.

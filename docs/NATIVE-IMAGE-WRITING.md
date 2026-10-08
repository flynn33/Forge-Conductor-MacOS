# Native image pixel writing

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

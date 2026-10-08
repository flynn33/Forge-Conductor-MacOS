# Native PNG pixel writing

Current source target is **0.31.0 (44)**. Bounded `image_write` passed matching
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

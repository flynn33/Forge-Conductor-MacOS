# Native text-slide PPTX writing and import

Current source target is **0.29.0 (42)**. Bounded source/native, build/signing,
wire/artifact, reference/Core consumer and Qwen API gates passed. Installed/GUI,
full Office/full web, all models, Release and shipment remain separate.

## Observed baseline

The public native .28 Core imported two one-slide decks generated and reopened by
the bundled `python-pptx` 1.0.2 reference library. Template and thumbnail parts were
retained. The populated deck contained `PPTX baseline café 日本語 🙂 & <literal> _x0041_`;
the blank deck contained no user text.

Both imports produced 39 catalog documents and 31 canonical documents that matched
XML members exactly. Populated/blank instruction totals were 81,783/81,328 bytes;
both reported import-ready true and unresolved 2. Original bytes were exact and
mode `0400`. Queue start was not exercised. Collector exit 0 in 25.064 seconds
means successful collection; this classification feature failed.
The retained record is `native-pptx-core-baseline-output-0280/summary.json`.

`ProjectInstructionQueueStore.ingest` previously treated `.pptx` as generic ZIP.
`archivePackage` passed members to `ingestDocument`, where ordinary XML could
become UTF-8 instructions. The repair routes explicit PPTX sources and nested
PPTX documents through a dedicated slide-text adapter, preserving generic ZIP
inventory and nested `.zip` retention.

## Writer contract

`pptx_write(path, slides)` requires a nonblank string path without NUL and an
explicit `.pptx` extension. Each slide requires a string `title` and an array of
string `paragraphs`; extra slide keys and other JSON types are rejected.

| Boundary | Limit |
| --- | --- |
| Slides / total paragraphs including nonempty titles | 1–32 / 1,024 |
| UTF-8 bytes per title or paragraph / total input | 4,096 / 65,536 |
| Encoded PPTX | 1,048,576 bytes |
| XML elements per slide | 32,768 |

The call-local Swift writer emits stored ZIP package parts, with slide, layout,
master, theme and relationship declarations. CRLF and CR normalize to LF;
embedded LF becomes a soft line break. Tabs, whitespace and literal `_x0041_`
text are preserved. Invalid XML 1.0 scalars are rejected. The contract is
`pptx-text-slides-v1`; visual fit, images and full Office fidelity are outside it.
Existing project validation, exact tool grants and pinned atomic writes remain.
The writer rejects XML complexity beyond the reader's existing element limit
with `pptx_structure_too_large` before publishing a destination. The retained
pre-repair structural test executed one method and failed on the reader's
`XML element or depth limit exceeded`; reader limits were not increased.
Workspace roots select project identity/default paths; owner OS-authorized
host-wide access remains. After a write/durability failure, inspect the destination
before retrying.

## Import contract

The native reader follows internal package relationships and declared slide
order. It extracts slide paragraphs, rich runs and explicit soft breaks with
`[Slide N]` labels, excluding master/layout/package XML. Literal `_x0041_` is
DrawingML string data, not a SpreadsheetML escape. No external relationship is
followed. Original decks remain source-linked; existing canonical line-ending
normalization applies. Non-UTF-8 XML declarations and duplicate namespace-expanded
attributes are rejected; both malformed cases reproduced acceptance before repair.
Blank input is unrepresented; malformed/unsupported
conversion is unresolved. Neither receives package XML as canonical instructions.
Previously stored packages are not automatically reconverted.
New audit arguments redact the entire `slides` and `rows` document-content arrays,
preserving paths and execution metadata. Existing audit records are not rewritten.

| Boundary | Limit |
| --- | --- |
| Container / expanded bytes | 16 MiB / 8 MiB |
| Parts / bytes per part | 256 / 2 MiB |
| Slides / paragraphs | 32 / 1,024 |
| Paragraph / canonical UTF-8 bytes | 4,096 / 128 KiB |
| XML elements / depth per part | 32,768 / 32 |

## Verification and retained evidence

All paths below are under the external
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-07-project-web-qwen`
evidence directory. Successful checks used the same 458 source/resource/test/build
inputs. The paired source-map file SHA is
`f8f82532d23b8bfafced7c72c16161a75889aa7da35e9b5e749dfadae813e803`.

| Check | Actual result |
| --- | --- |
| Source | `swift test --filter` selected PPTX, XLSX, instruction queue, tool catalog, PDF, G3 and three audit methods: 166 distinct methods, zero failures/skips, normal exit in 45.775 s. `native-pptx-source-owning-final-0290-terminal.json`; log SHA `97b43e4dd44f0b8f9397d845bbd7d15b340753ba367c0b485a02e2b9245f7104`. Focused repeats are subsets, not added to 166. |
| Canonical native | Workspace/scheme ForgeConductor, Debug, macOS, parallel NO, same exact selections: 166 methods, zero failures/skips/compiler warnings/QoS warning blocks, normal terminal success in 70.202 s. `native-pptx-native-owning-0290-terminal.json`; log SHA `4d0dfe75beebd7cfbad8495426a94f9c7a8a515cb1e970a065aac7a951055190`. Runtime framework diagnostics remain separate. |
| Build/signing | CLI and App package compilation passed; ordinary canonical Debug build passed in 24.519 s. Strict deep disk signature verification passed; seven current binaries and three protected identities remained exact, plus all 113 binary identities from 17 preceding candidate manifests. `native-pptx-native-candidate-0290.json`, SHA `819c20f0022936a3d2fdc25a90aa345782498a85235932ca1ae3b9b75d33ea8d`. This is not universal compiled peer-policy qualification. |
| App/CLI wire | Eight controls each: three written artifacts/readback, four invalid-input no-write controls and actual MCP cancellation/no publication. Six artifacts, 16 total controls; normal zero exit, complete EOF and unchanged source/candidate/protected guards. `native-pptx-app-final-0290/summary.json` and `native-pptx-cli-final-0290/summary.json`. |
| Independent reference | Bundled python-pptx1.0.2 consumed all seven actual App/CLI/Qwen decks. Exact title/body order, literal Unicode/escapes/normalized breaks, blank shapes and supporting layout/master links passed. `native-pptx-reference-consumption-0290.json`, SHA `8e32a23e5c0afd74a2075e936d904636fd4decd019784b121135f255d499c378`. This is text/package consumption, not visual rendering. |
| Original public Core cases | Both unchanged reference decks passed with the actual signed candidate Core `86834fccb961797e24196d9d66de568b9f22df3d47e8a81334c57048a6562834`. Populated: one document, 64 canonical UTF-8 bytes, four pages at most 17 bytes, exact whole hash/EOF, ready true/unresolved 0. Blank: one document, zero instructions/unresolved 1/notready; read/reference/start denied. RawXML instruction count 0 for both, original bytes exact/mode 0400, wrong-project catalog/read denied. `native-pptx-core-consumer-output-0290/summary.json`, SHA `d132b2cb9e52ecd1f4c9f12cd2ff8633c51522a5c29f05853ef3eeb030aa7a14`. Populated queue start was not exercised. |
| Qwen | Model `qwen/qwen3.8-27b`, three normal API responses, actual Low 3/3, two actual selected/written/correlated/verified/delivered/consumed results: `pptx_write`, then full `fs_read` base64 EOF. Normal final JSON exactly matched SHA `92a8148ebd781c27c359e46f706569eece456dc3a16fe8bbd719761707b9d798`, 11,384 bytes and one slide. Native 6/6 correlated responses, normal worker/observer/collector/native exit and EOF, no forced cleanup; outer 51.222 s. `native-pptx-qwen-final-0290/summary.json`, SHA `3639c7808a7676483f9aa19a8fed3c8a32b7988874206b0a43b3f5c969b89a1c`. Separate isolated candidate/API exchange, not the installed active GUI or production managed adapter. |

The first focused command failed compilation on two missing test `try`
annotations and executed zero methods. The structural reproducer executed one
method and failed before the writer node guard. Two parser methods failed before
encoding/attribute rejection. The audit reproducer executed one method with four
failed assertions before document-array redaction. Their original receipts remain
NONPASS; corrected tests are included in the 166-method results.

The four new Swift files have one file/build/group/target-Sources membership each
in the existing canonical Core/test targets. Removing only those graph entries
and normalizing the version settings reproduces the preceding project exactly.
The workspace identity is unchanged; no target, signing or deployment settings
were changed. No installation, registration, package or notarization action ran.

Keynote Creator Studio opened a first-run dialog explicitly saying Continue
accepts its software license. No acceptance was performed; native client visual
rendering remains unverified. Full Office/full web, all models, installed active
GUI, Release and shipment remain open. Previously stored packages are not
reconverted automatically. Exact source/wiki delivery revisions belong in the
external closeout after publication and readback.

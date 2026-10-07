# Native PDF writing and logical text

Current source is **0.25.0 (35)**. The existing `pdf_write` and `pdf_from_file`
tools now use native CoreText glyph layout and measured wrapping with CoreGraphics
output. A shared bounded reader supplies logical text for a complete supported
tagged subset in instruction imports and policy-source indexing. The corrected
owning-area source selection passed 101 methods and the compiled native selection
passed 102 tests on the original 450-input PDF product snapshot. Signed Debug/
Release generation and Qwen's separate two-document API exchange passed. The unchanged PDFKit validators
retain whole mixed-script order and wrapped-sentinel failures. Independent r6
semantic validation passed 82 controls and all eight Debug, eight Release and two
Qwen artifacts with original scalar markers/page targets. The original 80
expectations remain unchanged; two exact operand-boundary controls qualify the
external validator's revised limit. Native PNG review covered ten Release and two Qwen
PNG pages. PDFKit compatibility remains open. The PDF source/wiki checkpoint was
published and synchronized. A later test-only fixture capture correction passed
the freshly compiled UTF-8 regression and all 19 writer methods without the
original warning; product identity remains 0.25.0 (35). This later test/documentation
publication is pending.

The signed 0.24 baseline and every unsuccessful repair attempt retain their own
inputs. Generation metadata, logical text, PDFKit extraction, geometry and visible
glyphs are separate evidence. No installed, full-Office, arbitrary-font/script,
all-model, accessibility-conformance or shipment qualification is claimed here.

## Preserved tools and changed output

| Tool or boundary | Contract |
| --- | --- |
| `pdf_write` | Required `path` and `content`; optional `title`. A missing PDF extension is appended. Default title is the destination filename without its extension. |
| `pdf_from_file` | Required `source_path`; optional `dest_path` and `title`. Default destination replaces the source extension with `.pdf`; default title is the source filename without its extension. Source reads remain regular-file, no-follow, bounded UTF-8 reads. |
| Shared controls | Existing tool names, argument fields, grants/path authorization and `deadline_ms` integer 1–60,000 remain. Inline content and file sources remain limited to 4 MiB, with existing over-limit error codes. |
| Success metadata | Existing `ok`, `path`, `bytes_written`, `pages`, `title` and `engine: "swift-pdf-writer"` remain; conversion also returns `source_path`. |
| Markdown subset | Existing headings, Unicode bullet transformation, fenced-code/tab handling and non-code removal of `*`, `_` and backticks remain. This is not a full Markdown converter. |
| Native layout | CoreText glyph fallback and metric line/cluster breaking replace the manual Helvetica/UTF-8 stream writer and character-count wrapping. PDF bytes and page breaks change. Title layout collapses display whitespace within the existing first/repeated title prefixes; returned title metadata remains full. |
| Output ownership | A new 64 MiB retained-output ceiling is enforced by the per-call CoreGraphics consumer before the existing atomic destination write. Limit/cancellation failures precede successful publication and preserve an existing destination in the regression controls. Framework-internal allocations and synchronous-call preemption are not qualified by this cap. |

Each nonempty rendered line is tagged with its exact logical UTF-16 source slice
after the existing Markdown transformation. Wrapped slices concatenate without
an injected separator; only the logical paragraph's final slice gets a newline.
Repeating page titles remain part of document text. Empty draw lines remain
untagged, and unused trailing pages are not emitted. Blank-page and title/body
geometry controls retain their assertions.

Sources:
[document tool pack](../Sources/ForgeConductorCore/Application/Tools/DocsToolPack.swift),
[writer](../Sources/ForgeConductorCore/Infrastructure/PDFWriter.swift), and
[tool catalog](../Sources/ForgeConductorCore/Application/ToolDefinitionCatalog.swift).
The internal 512-byte output-limit seam tests the real native consumer failure
path; it is not a public tool option or the production output limit.

## Complete tagged-text subset

`NativePDFTextReader` admits an exact flat `StructTreeRoot` → `Document` → array
of `Span` shape. Each unique span identifies an actual document page and one
nonnegative integer MCID. Pages are monotonic in the structure array, parents
must match exact owning dictionaries, and duplicate identities/page-MCID pairs
decline. Structure strings are decoded only after whole-document shape and
registered content coverage pass.

Scanning checks balanced text objects and marked scopes, typed finite operands
for `Tj`, `TJ`, apostrophe and double-quote text shows, and complete ownership of
every registered nonempty text show. Each admitted MCID must occur in exactly one
marked sequence and own nonempty text. Unknown owners, orphan/repeated/missing
MCIDs, partial later pages and nested MCIDs decline the entire semantic result.
A bounded ActualText-only child inside an owner is validated but suppressed under
the outer structure replacement. Named properties, XObjects, inline images,
compatibility sections, unsupported structures, nonempty annotations and forms
are outside this first subset.

The observed CoreGraphics producer can have unresolved/null optional root entries
and no page StructParents. That narrow forward-linked shape is admitted without
claiming standards-complete tagging. A supported resolved reverse map is validated
against exact owning spans; a supplied Limits name requires a resolved, valid
two-entry range. Public enumeration cannot name every unresolved root entry, so
the root's optional-field ambiguity remains explicit. Complete downstream
page/MCID/text-show checks still apply. ActualText declares logical metadata;
admission does not prove arbitrary metadata truthful or rendered glyphs correct.

| Reader boundary | Production value |
| --- | --- |
| Already-owned input Data | 64 MiB |
| Pages / flat elements | 256 / 16,384 |
| Encoded / decoded string | 128 KiB / 64 KiB |
| Cumulative decoded strings, including suppressed replacements | 8 MiB |
| Registered standard-operator callbacks | 1,000,000 total |
| Cumulative array/operand entries | 32,768 total |
| Nested marked-content scopes | 8 |
| Catalog/page dictionary field observations | At most 64 per dictionary |

UTF-16BE strings require even length and valid surrogate pairing; empty decoded
strings decline. Unsupported input or any quota failure returns no partial pages.
Callback cancellation errors propagate. Native provider/document/scanner/content
resources are owned per call, with explicit scanner/content/table release and
no cache, timer or subprocess. The semantic reader declines on the main thread.
CoreGraphics has no wildcard operator callback in the inspected public API;
coverage concerns the registered standard callbacks and successful native scan.
Native parsing/decompression, heap use and synchronous-call latency are not
globally bounded or preempted by these source quotas.

[Reader source](../Sources/ForgeConductorCore/Infrastructure/NativePDFTextReader.swift)
contains the exact acceptance and fallback boundary.

## Consumer provenance and durable compatibility

| Consumer | Accepted logical-text provenance | Preserved fallback |
| --- | --- | --- |
| Instruction-package import/read | `cgpdf-actualtext-v1`, existing `[PDF page N]` labels; original PDF bytes/hash remain linked | `pdfkit-text-v1` and existing OCR/unresolved/retained behavior |
| Policy-source indexing | `cgpdf-actualtext`, extraction version `1`, existing `[page N]` labels and bounded persisted segments/hashes | `pdfkit-text`, version `1`, and existing encrypted/metadata/partial behavior |

Both consumers choose the semantic result only when it contains usable
non-whitespace text. Incomplete, unsupported, over-budget, empty or whitespace-only
semantic input retains the existing whole-document PDFKit path. The consumers
do not supply a new cancellation callback, and this change does not qualify the
unchanged PDFKit fallback as main-thread safe.

Old durable documents/revisions remain readable and are not automatically
reconverted. Queue canonical-text changes can create new content snapshots under
existing deduplication; earlier snapshots retain their identities. Policy refresh
uses existing revision behavior. No database schema migration is added. The two
owning regressions verify exact mixed-script fragments through actual durable
read/segments, original-byte hashes, provenance and equal results after reopening.

Sources:
[instruction queue](../Sources/ForgeConductorCore/Application/ProjectInstructionQueue.swift)
and [policy extractor](../Sources/ForgeConductorCore/Infrastructure/StjornarvaldNativePolicyExtractor.swift).

## Retained baseline and oracle decision

The signed 0.24 producer generated eight owned PDF artifacts plus two source-limit
negative controls, consuming all fourteen responses and exiting normally. The
independent pure-PDFKit validator failed four of eight text/structure controls:
bullets, Unicode body, Unicode title and explicit UTF-8 source. Wide text measured
two rectangles outside MediaBox; its geometry was measurement-only in that
original validator and must not be disguised as an all-artifact pass. Native PNG
review showed corrupted glyphs and cropped wide lines.

The original source baseline executed twelve methods with thirteen failed
assertions across five methods. Later twelve- and sixteen-method repair selections
still failed the whole mixed-script phrase. Two native AppKit reference export
controls produced the same Arabic-first PDFKit concatenation. Independent
CoreGraphics inspection then found exact serialized ActualText and complete
page/MCID ownership on the actual PDF, including the nested child replacement.
Those observations justified a native logical-text consumer; they did not show
that PDFKit changed or establish universal glyph correctness.

The original full marker and scalar order remain unchanged. The current
`testUTF8SourceExplicitDestinationPreservesUnicode` applies that assertion to the
actual complete tagged-reader bytes and still checks ordinary title, heading and
sentinel text through PDFKit. Mixed words/paragraphs and unbroken wrapping have
additional exact reader controls. Historical pure-PDFKit validation stays frozen
and NONPASS for its original whole-order oracle. Glyph appearance and geometry
keep separate oracles; tags, generation success or model prose cannot replace them.

## Actual repair receipts and pending qualification

Receipts are retained externally under
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-07-project-web-qwen`.

| Gate | Actual result and scope |
| --- | --- |
| Initial semantic selection | `native-pdf-semantic-source-baseline-025`: 34 methods, two assertions failed (BOM-only and dangling StructParents), terminal one, 18.551 seconds, 450 unchanged inputs. Log `5b75bd33cae77a4d7cd099d5ce3bcfc39ce9e617d97dc004c3b916e2b5b4d850`. |
| Annotation/form admission baseline | `native-pdf-semantic-admission-baseline-r2-025`: one method, two failed assertions, terminal one, 11.147 seconds, 450 unchanged inputs. Log `8136fb2c0cd8c333b4974076ec5e5fb000c7e99758a53413124f32002154c347`. |
| Earlier focused checkpoint | `native-pdf-semantic-source-final-025`: 35 methods passed, zero failures/skips, terminal zero, 10.148 seconds, 450 unchanged inputs. Log `d683bb9853133ef21581e039c4258eec114e28ff44ec68ff9e6939663b93bca1`. Predates the reverse-field additions. |
| Earlier owning-area checkpoint | `native-pdf-area-source-025`: 84 methods passed, zero failures/skips, terminal zero, 15.279 seconds, 450 unchanged inputs. Log `7acc7ac55cbafdc4f7009b68b052d0f1879903f227c429690eb005fe87c45232`. Contains the focused cases; do not add the counts. |
| Pre-final-input compilation | Both Swift products compiled in 1.121/1.015 seconds; ordinary canonical Debug build returned zero in 24.066 seconds on 450 unchanged inputs, log `d4b8b1553db465e0d224fe22513911a330fdf901b62b4a12c43b85ab17590004`. These builds predate the final reverse-field/current-version changes. |
| Reverse-field baseline | `native-pdf-reverse-field-baseline-025`: one method, one failed Limits assertion, terminal one, 5.598 seconds, 450 unchanged inputs. Kids correctly declined. Log `626a8841cd394d5c938edb3cdadb54e26f35b5294e8d1e3f242da10ccfde7320`. |
| Contradicted enumeration-only patch | `native-pdf-area-source-final-025`: 101 methods, 100 passes and one Limits failure, zero skips, terminal one, 21.525 seconds, 450 unchanged inputs. Log `c68c5922d0287770babf456120954bb301ddaa063e96239a42550eb36dde61e5`. This attempt did not fix the original case; it remains NONPASS. |
| Presence-aware Limits validation | `native-pdf-reverse-field-corrected-025`: the same negative method passed, terminal zero, 9.410 seconds, 450 unchanged inputs. Log `3457d9aac08c440fd4bd7490a69fde3346a96c3070d0a5223e7f4c68da46e7e8`. A present name now requires its typed range object instead of treating a nil lookup as absence. |
| Corrected owning-area source | `native-pdf-area-source-corrected-025`: all 101 methods passed, zero failures/skips, terminal zero, 12.787 seconds, 450 unchanged inputs. Log `4342a5d1c0ca83487eb66b53703de4d077be93d474c3bf61d5eb0a6cdb73238c`. Reader 14/53 raw cases, writer 19, queue 39, policy catalog 12, tool catalog 16 and existing Core PDF 1. |
| Final compilation | CLI/app products passed in 0.893/0.892 seconds on 450 unchanged inputs; logs `3b5a8da9af1f62147ab8793e786e783d70fbc2969490bd4f7559886d4ee26e91` and `21254f729f3092a428bafa9b3968dee99483bd9ae1a89ee32098b7593883dc9c`. Ordinary canonical Debug compilation passed in 5.261 seconds on the same 450 inputs; log `29f828b884dad8e604ac2f2bb48cab958426df43f674dfd4bc561a21afaff748`. Release compilation passed in 149.056 seconds, log `040b6986c2ac58e8692ba5f8e40ff5ef0c24961fe1e3a2793423db8b64cb0b07`. |
| Current markers and compiled native | `native-pdf-version-source-025`: one current-marker method passed, terminal zero, 1.323 seconds, log `0275d7dc89f86a502102305492beaa3b6e8631c031b794270cde09aae7b3fe23`. `native-pdf-core-tests-025`: 102 tests passed, zero failures/skips, terminal zero, 44.409 seconds, log `8d8564d62fb3bf137e003a319d541c7eb2aff2510cfde951a36a2403723c53fd`; includes the marker method. All 450 source inputs unchanged. Three new Swift files have twelve additive entries in existing targets; workspace unchanged. |
| Signed candidates | `native-pdf-debug-signing-025`: strict Debug signing/build binding passed in 0.565 seconds, log `b83f8d5470c3fc917271d7547f6de0fe94610a55ce87b6fa4ce6affb6da5a928`; seven identities in `native-pdf-native-candidate-025.json`. `native-pdf-release-signing-025`: strict Release verification passed in 0.568 seconds, log `3f2067d288b5bf32cfdef192d4910c868fe972aa8c9f435bb890d61dde026e14`; five identities in `native-pdf-release-candidate-025.json`. Both bind actual successful 450-input builds. Seven preceding manifests' 45 binary identities and three installation/registration protections remain unchanged. |
| Native producer | `native-pdf-signed-producer-025` and `native-pdf-release-producer-025`: each generated eight controls and passed two source negatives, consumed all fourteen correlated LF-inclusive responses, native zero exit/full EOF/no forced cleanup. Source/candidate/protected/harness inputs unchanged. Their 16 KiB request fixture does not qualify the full 4 MiB inline-content allowance. Separate artifact validation is required. |
| Unchanged control PDFKit validators | `native-pdf-independent-pdfkit-025` and `native-pdf-release-independent-pdfkit-025`: each passed seven of eight controls and returned terminal one with normal validator lifecycle. Only `utf8_source_explicit` fails its unchanged whole mixed-script marker: extraction places Arabic before the Latin/Greek/Cyrillic/CJK phrase. This compatibility gate remains OPEN; a glyph failure is not inferred from that order result. Each profile's ten pages are 612×792 with zero measured character bounds outside MediaBox (half-point tolerance). Geometry remains measurement evidence. Release wrapper took 0.450 seconds, log `691493cb9028a522a1faf044ee6ae12d704cb364c319ce63fa5ffc87a482f5ca`. |
| Native PNG review | Native PNG review covered five current Debug control PNGs: bullets, Unicode body/title, explicit mixed source and wide text. All ten Release pages and both Qwen pages were also opened and reviewed, recorded in `native-pdf-release-visual-review-025.json` and `native-pdf-qwen-visual-review-025.json`. Visible bullets and the inspected accented Latin, Greek, Cyrillic, CJK and Arabic were present; prior mojibake and cropped wide lines were absent in these controls. This bounded review is separate from extraction/semantic proof and does not qualify arbitrary fonts/scripts. |
| Original independent semantic controls | `native-pdf-semantic-controls-025`: eighty controls passed, thirteen admissions and sixty-seven whole-document fallbacks, all native zero/one exits and full EOF. The r5 standalone validator does not import the production reader or qualify glyphs, geometry, PDFKit or tagging conformance. Outer terminal zero, 0.879 seconds, log `0534e5e743a3527f67f4b43bfe8b2dac2d11a4b5455787ed1113354452118de4`. The configured per-case process budget is 30 seconds; the 90-second owner check excludes its final receipt write and is not an unconditional hard process-lifetime guarantee. |
| Actual Qwen and lifecycle | `native-pdf-qwen-author-025`: two actual API rounds and two tool calls (`pdf_write`, `pdf_from_file`), two nonce-observed Low templates, complete native results fed back, exact final generation metadata and normal model stop. All six LF-inclusive native responses consumed, native zero exit/full EOF/no forced cleanup, all input guards unchanged. Outer terminal zero, 59.334 seconds, log `b7dd3525db344e6c1d514fc775b44b16e59c68f2f96b3198dd317e4bf312229a`. Model final explicitly says format/glyph validation was not performed. This is API candidate evidence, not the active GUI or installed deployment. |
| Unchanged Qwen PDFKit validator | `native-pdf-qwen-independent-pdfkit-025`: conversion passed; written document failed only the unchanged whole `QWEN-NATIVE-PDF-SENTINEL-024` marker. Extraction breaks it after `QWEN-NATIVE-PDF-` at a layout newline. Terminal one, normal lifecycle/full EOF, 0.354 seconds, log `69e8badfb473115c9f8682b6b880af170f326fd31982cefe3ebbf5a68157986d`. This compatibility gate remains OPEN. The written PNG was also reviewed; model metadata success does not erase this result. |
| Retained r5 artifact validation | `native-pdf-debug-semantic-025` and `native-pdf-release-semantic-025` each passed seven of eight artifacts and remain NONPASS. Only `multiple_pages` exceeded the independent 4,096-item cumulative array/operand quota; its native validator returned one with full EOF and no forced cleanup. This is a validator quota result, not evidence of missing product text. `native-pdf-qwen-semantic-025` passed both documents separately. Original marker/page-target oracles remain immutable. |
| Fresh independent r6 controls | `native-pdf-semantic-controls-r6-025` passed all 82 controls: fourteen admissions and sixty-eight whole fallbacks. The original 80 PDF bytes, order and expectations match the retained manifest exactly; two new controls exercise 32,768 operands admitted and the 32,769th rejected with empty pages. All native zero/one exits and full EOF, outer terminal zero, 0.855 seconds; log `c46bedcd9f58fe007122f72a52dec320c55cb15c8b39cb3ad295e02c5b44426b`. The original 80 outcomes were not weakened. |
| R6 Debug semantic artifacts | `native-pdf-debug-semantic-r6-025`: all eight passed with original scalar markers/page targets, normal zero exits/full EOF and no forced cleanup. Outer zero, 0.343 seconds; log `97c69d6da8faae766b4c8621c3c8919f32e994d8f2b918ba73028f6d80adb191`. The three-page artifact admits 133 spans and 7,545 cumulative independent operands. |
| R6 Release semantic artifacts | `native-pdf-release-semantic-r6-025`: all eight passed with original scalar markers/page targets, normal zero exits/full EOF and no forced cleanup. Outer zero, 0.341 seconds; log `712da4e2f848508007c8f49c193460465800e0774f2c96fd8a8bf325cfc9fede`. |
| R6 Qwen semantic artifacts | `native-pdf-qwen-semantic-r6-025`: both passed with original scalar markers/page targets, normal zero exits/full EOF and no forced cleanup. Outer zero, 0.341 seconds; log `0b989029494ae09790d75edf5e16dbd75f007f64eb733fe5d68b17e0f8fb85d8`. This separate logical-text proof does not reclassify the unchanged Qwen PDFKit NONPASS. |
| Original native test warning | Historical E2 source evidence: the original native compiler warned at `PDFWriterTests.swift:85` that detached work captured XCTest `self`, including mutable fixture state. The method awaited `.value`; no runtime race or production/UI reachability was observed. The original 102-test receipt and warning log remain immutable; the later test-only correction has separate receipts below. |
| PDF product publication | `native-pdf-publication-and-synchronization-025.json` records owner source `812f4ead367fc95f39b666fd1a814606b837b853` and wiki `07a4fb8f0a12b68c22650cc4121fa84fae1dce50`, clean and zero divergence. The 26 published source paths and all 450 tested inputs match; 45 remote wiki files match, with 34 pages and 284 checked local links/zero errors. Product candidate receipts retain this original test snapshot. |
| Later test/documentation publication, installation and shipment | The test-only immutable capture change and this documentation closeout await their own owner publication/readback/synchronization. Installation and shipment remain separate. |

R6 is a fresh independent validator revision, not a product-source change. Its
cumulative generic-operand/TJ-member ceiling increased from 4,096 to 32,768 after
the actual r5 quota result. The same numerical production limit additionally
charges structure/reverse-array entries, so exact counter-population parity is
not claimed. Other input, structure, string, operator, scope, complete-document,
marker, page-target, hash and lifecycle assertions remain. The source SHA is
`766af7eaf1705b31522ae5e1cf0054eaf0e9ab116cf9bc0c20a4dd049fdfc249`;
the selected native validator SHA is
`5557ae44b953e9ffa8e14aa3545c31a1f5d55474fbb6159501de311c57752730`.
All three artifact owners preserve the 450 source inputs, seven Debug or five
Release identities, three protected installation/registration inputs, artifacts
and harnesses. Expected markers remain solely in the owner; the native validator
receives only input/output paths and imports no production reader. R5 receipts
remain retained, and the original PDFKit compatibility gates remain OPEN.

Each named source/build terminal receipt above records no deadline hit, output-cap
hit or forced cleanup. Source success does not supply signed-candidate or installed
proof. Earlier preparations with planned 448 inputs retain their original hashes;
fresh final preparations must bind the actual 450-input candidate map and identity.

## Later test-only immutable fixture capture

The original warning concerns a test closure, not the production writer or reader.
The correction unwraps the root URL before detached work, captures that value and
uses static helpers whose state is passed as arguments or owned locally. Awaited
completion and deferred app shutdown remain. All 19 method identifiers and 96
existing XCTest assertion/unwrap/fail lines remain, with one new boundary unwrap.
No concurrency checking, scalar, geometry, cancellation, source/output-limit,
default or durable-provenance oracle was relaxed.

Only `Tests/ForgeConductorTests/PDFWriterTests.swift` changes among the original
450 source/configuration/graph inputs: from
`d24d5d25e5451b5333a1a2f757d92e2149748dbb780da159d0651c2774137a90` to
`55d34730f0a1acfc4f077572d1544d5c764853f43fdd507cd5912712f55e0033`.
The other 449 inputs and all four existing PDFWriterTests PBX membership entries
remain unchanged. Product/configuration/graph and identity remain 0.25.0 (35);
this test-only correction does not create or distribute a new product candidate.

| Gate | Actual result and scope |
| --- | --- |
| Freshly compiled warning site | `native-pdf-immutable-capture-focused-025`: the exact UTF-8 source regression passed one native test, zero failures/skips, terminal zero, 5.978 seconds, full 58,724-byte EOF and unforced cleanup. Log `8a282286a6753594779f640a14521a041a218fd2faad1d3f85b370bb97cb8efa` shows PDFWriterTests.swift freshly compiled at lines 108–114; no compiler warning/error lines remain in the current native logs. New 450-input snapshot unchanged during the command. |
| Normal writer selection | `native-pdf-immutable-capture-writer-tests-025`: all 19 writer methods passed, zero failures/skips, terminal zero, 3.074 seconds, full 20,932-byte EOF and unforced cleanup. Log `796b00b2f191caf597d90f494fd62d8d688c45e41b58c268f3145db41663ba90`; new 450-input snapshot unchanged. The focused case is included in these 19, not a twentieth method. |
| Static parity and preserved artifacts | `native-pdf-immutable-capture-qualification-025.json` records all 19 identifiers/96 existing assertion lines and the single boundary unwrap, with 449 other inputs unchanged. `native-pdf-immutable-capture-artifact-preservation-025.json` verifies all twelve prior Debug/Release binary identities and three protected inputs unchanged. |

The original 101-source/102-native and signed Debug/Release, PDFKit, r5/r6 and Qwen
receipts keep their original input map and test hash. The later 19-method run does
not rerun all 102 tests or supply new candidate signing/build-binding qualification.
No runtime race or general concurrency acceptance is claimed. Both unchanged
PDFKit compatibility gates remain OPEN; this test-only change does not alter
generation, glyph, logical-text, layout or installed behavior. Its source/document
publication is pending separately from the completed PDF product checkpoint.

The PDF record closes neither the attachment's other rich-format requests nor the
broader completion target. Earlier PNG/WAV/minimal-DOCX examples were Qwen-authored
Python job workflows; this repair is a native product PDF path. Their scopes remain
separate in [binary web and Qwen files](BINARY-WEB-AND-QWEN-FILES.md).

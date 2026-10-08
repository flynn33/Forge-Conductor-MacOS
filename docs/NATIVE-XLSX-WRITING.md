# Native text-cell XLSX writing and import

Current source targets **0.28.0 (41)**. `xlsx_write` adds bounded text-only
worksheet creation. XLSX instruction import extracts cell values instead of
promoting the workbook's package XML to instructions. Selected source/native and
build/signing, signed wire/artifact, retained native Core and Qwen API gates passed
within the scope below. Broader product/shipment gates remain separate.
The observed baseline and earlier failed collectors remain separate.

## Writer contract

`xlsx_write(path, rows)` requires a nonblank string path without NUL and an
explicit `.xlsx` extension; none is appended. `rows` is an array of arrays of
strings. Empty rows, empty cells and an empty worksheet are accepted. Other JSON
types are rejected rather than converted to strings.

| Boundary | Limit |
| --- | --- |
| Rows / columns per row | 256 / 64 |
| Total cells | 4,096 |
| UTF-8 bytes per cell / total cell text | 4,096 / 65,536 |
| Encoded XLSX bytes | 1,048,576 |

The call-local Swift encoder runs on the existing worker path. It emits one
worksheet named `Sheet1` with inline string cells in five fixed, stored ZIP parts:
`[Content_Types].xml`, `_rels/.rels`, `xl/workbook.xml`,
`xl/_rels/workbook.xml.rels` and `xl/worksheets/sheet1.xml`.
XML 1.0-disallowed scalars are rejected. Literal `_xHHHH_`-like text is escaped
for preservation; CR is encoded explicitly. The writer does not normalize line
endings. Formula-like strings remain text; it creates no formulas, numeric/date
cell types, styles, images or full Office document fidelity.

The exact name joins the builtin Docs agent and ordinary project-default tool
sets. It needs its own tool grant; custom/imported grants and explicit denials
remain. Workspace roots select project identity/default paths, not a path
allowlist. Owner host-wide access remains available under OS permissions, with
project identity revalidation and the existing pinned atomic writer. Existing
PDF, DOCX, binary and shell contracts remain available. Cancellation/deadlines
propagate; a write/durability error can
follow rename, so inspect the destination before retrying.

A successful response reports `path`, `format: "xlsx"`,
`engine: "swift-ooxml-stored-zip"`, `bytes_written`, `sha256`, `input_text_bytes`,
`rows`, `cells` and `text_contract: "xlsx-text-cells-v1"`.
Named failures include `invalid_path`, `invalid_rows`, `content_too_large`,
`invalid_text`, `xlsx_worker_required`, `xlsx_output_too_large`,
`xlsx_encode_failed` and `xlsx_write_failed`. Normal authorization and deadline
errors retain their existing boundary.

## Instruction import contract

An `.xlsx` source, including uppercase extensions, is treated as a workbook
before generic ZIP inventory. The native reader uses bounded SafeZIP inspection
and extraction, package relationships and Foundation `XMLParser`. It extracts
meaningful non-whitespace cell values with sheet labels and cell references,
for example `[Sheet Sheet1]` followed by `A1: value`. Inline/shared strings,
rich-text runs and cached scalar values are supported; phonetic annotation text
is excluded. Booleans become `TRUE`/`FALSE`. Cached numbers, dates and errors are
unformatted values, not rendered spreadsheet text.

| Boundary | Limit |
| --- | --- |
| Container / expanded bytes | 16 MiB / 8 MiB |
| Package parts / bytes per part | 256 / 2 MiB |
| Sheets / cells | 16 / 4,096 |
| UTF-8 cell bytes / extracted text bytes | 4,096 / 128 KiB |
| XML elements / depth per part | 32,768 / 32 |

Parsed XML parts must currently be UTF-8. Actual DTD/entity declarations are
rejected; declaration-like text inside a valid comment, CDATA section or
processing instruction is not itself a declaration. External entities are
disabled and external relationships are never followed. Formulas are never
evaluated; a formula without a supported cached value is unresolved. Unsupported
types, incompatible value elements, nested cell text, nonnumeric `n` caches,
malformed relationships/references, XML or exceeded bounds fail conversion.
This is bounded value extraction, not complete OOXML schema validation.

The original workbook remains source-linked with its hash and read-only mode
`0400`. Conversion provenance is `native-xlsx-cells-v1`. The existing package
text normalization still applies to canonical instructions; the writer's literal
cell contract is not a byte-exact instruction-import promise. A meaningful
conversion produces one canonical instruction document. Blank workbooks produce
one unresolved `unrepresented_visual_structural` document; unreadable workbooks
produce one `unresolved_conversion` document. Both retain the original with zero
canonical instruction bytes and no runnable instructions or raw package XML.
Existing stored packages are not automatically reconverted.

## Observed baseline and current gates

The pre-edit R5 production Core collection observed six catalog documents for
each workbook, including five package-XML instruction documents: the one-cell
workbook exposed 1,746 instruction bytes and the blank workbook 1,608. Both
originals were preserved. Collection succeeded while the classification feature
contract failed. The record is `native-xlsx-import-baseline-r5-0271/summary.json`.

Earlier collectors stopped before Core import because their temporary-directory
representation guard failed. Those setup failures remain historical collector
evidence, not the importer defect or a Foundation-cache diagnosis.

The first focused compile failed on test fixture/access/throwing issues and
retains its source warning diagnostics. R2 executed 25 methods with two assertions
failing in one test that incorrectly expected a project-root write confinement.
`ToolAuthorizationService` explicitly preserves host-wide native tool access;
corrected denial/stale-context controls and a separate host-wide write parity
case preserve that contract. Neither earlier receipt becomes a pass.

| Current gate | Actual result |
| --- | --- |
| Focused source | Reader 12 + writer 14 = 26 passed, zero failures/skips/warnings. These methods are a subset of the owning selection. |
| Owning source / canonical native | Same exact 124 distinct methods each: reader 12 + writer 14 + instruction-queue 39 + catalog 23 + PDF 35 + G3 one. Zero failures/skips/compiler warnings/QoS blocks; normal exit 0, unforced and untruncated, 24.287/58.173 s. Retained native framework diagnostics are not a clean-runtime claim. |
| Build and candidate | CLI/app 1.108/1.213 s and ordinary canonical Debug 24.684 s passed. Strict Debug verification passed seven binaries and exact Docs resource bytes; `native-xlsx-native-candidate-0280.json` SHA `609460e666b34a19aecfceb2f65780999a44f3b643fd0cb370b99ae22a5e0b36`. |
| Input and preservation binding | All 454 product inputs remained exact, map `f8ea1f7c8abf6ef7187b53ee42927aec983eeed76cdf62f66501971b380c11f7`. Sixteen preceding manifests/106 binary files and three named installed app/helper/registration files stayed exact; this does not attest all host data. |

Receipts are `native-xlsx-source-focused-0280-terminal.json`,
`native-xlsx-source-focused-r2-0280-terminal.json`,
`native-xlsx-source-focused-r3-0280-terminal.json`,
`native-xlsx-source-owning-0280-terminal.json` and
`native-xlsx-native-owning-0280-terminal.json`. Focused repeats add no methods to
124; the source/native G3 method is included once.

App and CLI each passed eight controls: literal/ragged/blank worksheets, four
negative preservation cases and explicit cancellation (`-32800`) with original
preserved and no staging file left. Each consumed 15 correlated frames with no
response tail; normal exit 0/full EOF, unforced. Their three artifacts had matching hashes
and exact literal text-cell/binary readback. The summaries are
`native-xlsx-app-final-0280/summary.json` and
`native-xlsx-cli-final-0280/summary.json`.

The same two frozen R5 workbooks passed the current public native Core consumer.
Each now has one catalog document and zero package-XML instruction documents.
The one-cell case produced exactly 65 UTF-8 bytes,
`[Sheet Sheet1]\nA1: XLSX baseline café 日本語 🙂 & <literal>`, SHA
`26487b7b7cf2e1d4a427dd537c2a7d2c0cfa9dea45da84179d46d1c1abb7bfb2`,
reconstructed from four pages of at most 17 bytes. The blank case retained zero
instructions/unresolved 1, denying document reads, references and start. Both
originals remained exact/0400, and wrong-project catalog/read access was denied.
`native-xlsx-core-consumer-output-0280/summary.json` records 2/2 passing cases.
This is production Core consumption, not Excel/Numbers or GUI acceptance.

Qwen completed three normal API responses with actual Low 3/3, selected
`xlsx_write` then `fs_read`, and consumed both actual correlated results. Its
final normal STOP matched SHA
`f49aa66d1779acf3fff59d727a64e5bdaaa48a9c7d32d5988c4dc20f03d35553`,
2525 bytes and four literal cells. Native 6/6 correlated frames, provider workers
and observer all terminated normally with full EOF/no truncation or forced kill;
the collector exited 0, unforced, in 35.393 s. Source 454/candidate 7/protected 3 and
owned artifact guards stayed exact. `native-xlsx-qwen-final-0280/summary.json`
and `native-docx-xlsx-qwen-final-0280-terminal.json` retain the scoped result.
The public observer banner is not general subscription-readiness proof. This
separate API exchange does not qualify the active installed GUI or production
managed adapter. No installed behavior is inferred from the candidate.

Provider-only H4 stopped normally with six keys, omitting `pages_consumed`; H5
stopped normally with seven keys but changed exact text. Both final-text gates
remain NONPASS, with no native dispatch or established cause.
[Provider diagnostics](PROJECT-WEB-QWEN.md#provider-only-diagnostics) retain the
earlier H1/H2/H3 failures and scalar-only pass.

The preceding .27.1 shutdown qualification retains its 212 distinct source and
212 native methods on its original inputs. Full Office/full web, all models,
installed/GUI, all-feature, PDFKit, Release and shipment remain open.

## Source owners

`NativeXLSXWriter` owns bounded encoding; `DocsToolPack.xlsxWrite` owns argument,
project/write and result boundaries; `NativeXLSXReader` owns cell extraction;
`ProjectInstructionQueueStore.decodedRichDocument` owns import classification
and original retention. Existing authorization, catalog, continuity progress
and telemetry classification keep the added exact tool name within their owners.

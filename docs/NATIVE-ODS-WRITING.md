# Native text-cell ODS writing and import

Preceding source target is **0.30.0 (43)**. Final source and matching canonical
native selections passed 199 distinct methods each, including G3 once and
valid-list rejection. Final build/signing, App/CLI wire, seven independent
artifacts, two public Core import cases and Qwen API consumption passed.
Original failures and preceding-map passes remain separate. Installed/GUI,
full Office/full web, all models, Release and shipment remain open.

## Observed baseline and retained failures

On .29 inputs, the same source and canonical native
`ProjectInstructionQueueTests/testODSImportKeepsPackageXMLOutOfInstructionsAndRetainsBlankSourceUnresolved`
method each failed 13 assertions. Each workbook became four source/catalog
documents rather than one; ODF package XML became instructions. The blank workbook
exposed 965 instruction bytes, unresolved 0 and import-ready true. These original
baselines remain NONPASS, retained in `native-ods-source-import-baseline-0290-terminal.json`
and `native-ods-canonical-import-baseline-0290-terminal.json` with their full logs.

The first ODS reader selection failed compilation on two missing `try` annotations
at throwing task-value accesses and executed no methods. Its original
`native-ods-reader-focused-0300-terminal.json` remains NONPASS. The prior PPTX
compile/structural/parser/audit failures and the 900-second full-source NONPASS
also retain their original scopes; see [preceding PPTX evidence](NATIVE-PPTX-WRITING.md)
and [web/qualification follow-up](PROJECT-WEB-QWEN.md#october-8-web-and-qualification-follow-up).

A later source regression,
`NativeODSReaderTests/testUnsupportedCellTextBlocksRejectInsteadOfReturningPartialInstructions`,
failed three assertions for supported paragraph plus list, list alone and cached
string plus list. All three content fixtures passed official ODF RelaxNG; this
was valid unsupported text, not malformed XML. `NativeODSReader.cellValue` now
rejects unsupported direct text-namespace blocks before paragraph filtering or
cached-value selection, declining the whole document instead of omitting text.
The original `native-ods-unsupported-block-source-baseline-0300-terminal.json`
and `native-ods-unsupported-list-official-fixtures-0300.json` retain their exact
failure/schema scopes. The repaired method passed in both final owning selections.

## Writer contract

`ods_write(path, rows)` requires a nonblank string path without NUL and an explicit
`.ods` extension; none is appended. Rows are arrays of strings, with empty rows,
cells and input accepted. Other JSON types are rejected rather than coerced.

| Boundary | Limit |
| --- | --- |
| Input rows / columns per row / input cells | 256 / 64 / 4,096 |
| UTF-8 bytes per cell / total input text | 4,096 / 65,536 |
| Encoded output | 1,048,576 bytes |
| Content XML elements | 32,768 |

The call-local native Swift writer creates one ODF 1.3 worksheet named `Sheet1`
with three stored ZIP parts: first `mimetype`, `content.xml` and
`META-INF/manifest.xml`. The MIME entry has no extra field. Empty worksheets and
rows receive structural blank padding; success row/cell/input-byte counts describe
the original caller input, excluding padding. CRLF and CR normalize to LF.
Explicit ODF space, tab and line-break markers preserve whitespace; Unicode,
U+2029, literal `_x0041_` and formula-like strings remain text. XML 1.0-disallowed
scalars reject. Excessive content complexity returns `ods_structure_too_large`
before destination publication. The text contract is `ods-text-cells-v1`.
No formulas, styled layout, images or full Office fidelity are promised.

Success metadata includes `path`, `format: "ods"`, `engine: "swift-odf-stored-zip"`,
`bytes_written`, `sha256`, `input_text_bytes`, `rows`, `cells` and `text_contract`.
Existing project validation, exact tool grants, explicit custom denials,
OS-authorized host-wide access and the pinned atomic destination writer remain.
Workspace roots select identity/default paths; they do not confine owner writes.
Inspect the destination after a write/durability error before retrying.
New audit arguments already redact the entire `rows` content array, retaining
path/execution metadata; prior audit records are not rewritten.

## Import contract

ODS sources and nested ODS documents use the bounded native cell-text adapter,
with converter `native-ods-cells-v1`. It requires a first stored spreadsheet MIME
entry and ODF 1.3 manifest/content declarations. It extracts non-whitespace cell
values in sheet/row/cell order, with `[Sheet name]` labels and cell references.
Rich spans, explicit spaces/tabs/line breaks and bounded repeats are handled;
ordinary ODF whitespace collapses according to the text reader. Formula cached
values can be read, but formulas are never evaluated. No external relationship
or data is followed; package XML, styles and annotations are not instructions.

| Boundary | Limit |
| --- | --- |
| Container / expanded bytes | 16 MiB / 8 MiB |
| Parts / bytes per part | 256 / 2 MiB |
| Sheets | 16 |
| Expanded physical cells / emitted non-whitespace value cells | 4,352 / 4,096 |
| Cell UTF-8 bytes / canonical text | 4,096 / 128 KiB |
| XML elements / depth per part | 32,768 / 32 |

The physical-cell allowance includes bounded blank structural padding; it does
not raise the 4,096 value-cell limit or change XLSX limits. Merged/nested cell
content, unsupported direct text blocks (including lists), unsupported value types,
invalid repeats, absent recoverable formula values and malformed package/XML are
unresolved. Only UTF-8 XML parts are accepted; actual
DTD/entity declarations and duplicate namespace-expanded attributes are rejected.
Valid declaration-like text in comments/CDATA is data. The Foundation parser
never resolves external entities. This is a supported text subset, not full ODF
schema or Office validation.

Original bytes remain source-linked. Blank input yields no instructions and one
unresolved document; malformed/unsupported conversion likewise has no runnable
package XML. These sources remain not ready for queue work. Existing canonical
line-ending rules still apply. The adapter applies to new imports only: existing
saved packages, including their prior XML instructions, are not silently rewritten
or migrated. Reimport the original ODS source to obtain cell-text conversion.

## Final R2 qualification and limits

After the final documentation edits, G3 executed one method and passed in each
source/native selection (1.441/1.873 seconds). These repeats are subsets of the
199 methods. The first native follow-up selected `ForgeConductorAppTests` under
the `ForgeConductor` scheme; Xcode rejected that target before executing tests
(exit 70). Its `native-ods-final-documents-G3-native-0300` receipt remains
NONPASS. The corrected selector uses the observed `ForgeConductorTests` target;
`native-ods-final-documents-G3-native-corrected-0300` passed. No product inputs
changed for this correction.

| Gate | Observed result |
| --- | --- |
| Owning source/canonical native | Each passed 199 distinct methods, including G3 once, the original import baseline repair and new valid-list regression, zero failures/skips/compiler warnings/QoS blocks. Final source/native terminal times were 50.120/51.392 s, exit 0/unforced, on identical 462-input maps. Focused 33 and preceding R1 198 are not additional methods. |
| Final builds/candidate | CLI/app compilation, ordinary signed Debug (25.328 s), strict deep signature and seven-binary/resource checks passed on .30.0 (43). |
| App/CLI wire | Each passed eight controls: literals, empty row, blank, four no-write negatives and explicit cancellation. Each consumed 15 correlated responses, including 13 tool frames, and exited 0/both EOF with no response tail or forced cleanup. Each produced three independently checked files. |
| Independent artifacts | All seven actual containers, comprising literal/ragged/blank patterns, passed official ODF 1.3 content/manifest RelaxNG and exact expected text reconstruction with lxml 6.1.1/libxml2 2.14.6. Full base64 readback matched through EOF. This is schema/text consumption, not Office GUI or full fidelity. |
| Public Core import | Two new owned App artifacts each became one source/catalog document, originals exact at mode 0400, wrong-project catalog/read denied and raw XML instruction count zero. Populated output was 153 UTF-8 bytes across ten windows of at most 17 bytes through EOF. Blank output was zero bytes, unresolved one/not ready, with reference/read/start denied. Populated queue start was not exercised. |
| Actual Qwen consumption | Three normal API responses, Low 3/3, selected `ods_write` then full-base64 `fs_read` and consumed both delivered actual results. Strict final metadata matched SHA/2,145 bytes/two rows; acknowledgement is metadata only. Native six correlated responses and model workers/observer completed normally with both EOF, no forced cleanup. This is separate API proof, not installed GUI or production managed-adapter acceptance. |
| Source/wiki delivery | Exact publication and synchronization identities belong in the external closeout after remote verification. |

The final source map is
`c0a72cf9e29bc4ec3bbccacad43746db45c7755c68c604035f65b7e35e7516ed`;
the strict candidate manifest is
`90a0835b451cb6c669937e9a57a813578592c35c2b94be73b26645732efe8119`.
Source/candidate, three protected-file, harness and owned-artifact guards stayed
unchanged. These scoped guards do not assert that all host data was unchanged.
Final native tests retain framework linkd code 4097 and CG thumbnail errors.
No cause, general GUI failure or performance repair is inferred.

Qwen's independently checked 2,145-byte/two-row file has SHA-256
`e4da20e3598962cadd135251fb797a8ef91a49f5a9f0372dc9a374787305a46f`.
Core populated canonical text has SHA-256
`6f31147ee8f74857b0b039a67382bef701ba91cf0dc39684398d5c2aa967ad77`.
Final public Core cases use newly written owned App artifacts, not the original
pre-repair baseline fixtures. The independent artifact bytes match the prior
expected literal/ragged/blank patterns; runtime receipts bind the new candidate.

Final receipts:

- `native-ods-source-owning-final-0300-terminal.json` and
  `native-ods-native-owning-final-0300-terminal.json`, with exact logs/maps.
- `native-ods-ordinary-debug-final-0300-terminal.json`,
  `native-ods-candidate-strict-signature-final-0300-terminal.json` and
  `native-ods-native-candidate-final-0300.json`.
- `native-ods-{app,cli,qwen}-current-0300/summary.json` and the corresponding
  outer terminal receipts (1.316/0.827/35.994 s, exit 0/unforced/EOF).
- `native-ods-core-consumer-output-current-0300/summary.json` and
  `native-ods-root-consumer-review-final-0300.json`.

## Preceding R1 map and consumers

Before the valid-list repair, source and matching native selections each passed
198 methods on map
`d596b283ca8e910780542b543a24e02e7e2276f2b6ad09442022ee0669b2880d`.
CLI/app, ordinary Debug (25.632 s), strict signature and seven-binary/resource
checks passed; candidate manifest was
`680ddfb8a6cc119d39cb64686c0f5b7ed6d73183b10e8c2cd469c0e3e1d99a5a`.
These successful receipts remain bound to that superseded original map/candidate.

App/CLI each passed eight controls and consumed 15 correlated responses, normal
exit 0/both EOF/no forced cleanup. All seven actual ODS files, including Qwen's,
passed official ODF 1.3 content/manifest RelaxNG and expected text reconstruction
with lxml 6.1.1/libxml2 2.14.6. Public Core consumed two newly written owned App
artifacts: populated text was 153 UTF-8 bytes across ten windows of at most 17
bytes; blank was zero bytes/unresolved one/not ready with read/reference/start
denied. Each became one source/catalog document, originals stayed exact at mode
0400, wrong-project reads/catalog were denied and raw XML instruction count was
zero. Populated queue start was not exercised; these are not original pre-repair
baseline fixtures or Office GUI consumption.

Qwen completed three normal API responses, actual Low 3/3, selected `ods_write`
then `fs_read` and consumed both actual results. Exact final metadata matched
SHA-256 `e4da20e3598962cadd135251fb797a8ef91a49f5a9f0372dc9a374787305a46f`,
2,145 bytes and two rows; native six correlated responses exited normally with
both EOF. All source/candidate, three protected-file, harness and owned-artifact
guards stayed unchanged. This is a separate API workflow, not installed GUI,
production managed-adapter or an assertion about all host data.

R1 receipts include `native-ods-{source,native}-owning-0300-terminal.json`,
`native-ods-native-candidate-0300.json`,
`native-ods-{app,cli,qwen}-final-0300/summary.json`, the outer
`native-docx-ods-{app,cli,qwen}-final-0300-terminal.json` receipts and
`native-ods-core-consumer-output-0300/summary.json`.
All receipts live under
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-07-project-web-qwen`.
The installed app and primary live LM Studio registration remain .18.0 (28),
separately from isolated candidates. No installation/deployment, universal
web/model access, Office GUI, Release or shipment is claimed by this phase.

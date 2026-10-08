# Native plain-text DOCX writing

Current source targets **0.27.0 (39)**. `docx_write` adds bounded plain-text
Word documents. Owning source 154 plus the actual G3 document/version method
passed 155 distinct methods in total; the same compiled native 155 passed.
CLI/app, ordinary Debug, strict seven-binary candidate and canonical membership
checks passed on the same 450-input map. Actual App/CLI wire, independent bounded
OOXML/readback, eight native text imports, six production Core consumer cases
and the fresh Qwen R2 API workflow passed. These gates qualify this bounded
plain-text workflow; full Office/all-feature and installed-GUI acceptance remain
separate.

Earlier CLI/catalog/build and focused2/4 results keep their declared input maps.
The initial sixteen-method NONPASS and immutable raw-UTF8 control failures remain
below. Focused repeats are not added to 155.

## Tool contract

| Surface | Contract |
| --- | --- |
| Name and arguments | Exact additive `docx_write`; required `path` and `content` JSON strings, plus shared optional `deadline_ms`. An explicit `.docx` destination is required. |
| Input | At most 65,536 UTF-8 bytes before normalization. Reject XML 1.0-disallowed scalars: C0 controls except TAB/LF/CR, and U+FFFE/U+FFFF. Swift scalar values cannot contain surrogate code points. |
| Paragraph semantics | `docx-paragraphs-v1`: CRLF, CR and U+2029 normalize to LF. Existing LF paragraph boundaries, including repeated/trailing LF, use native paragraph semantics. Native text import can add a final LF. No byte-exact UTF-8 or universal importer-fidelity claim is made. |
| Output | At most 1,048,576 encoded bytes; metadata includes destination, format, engine, bytes, SHA256, original input byte count and text-contract identity. Output cap is checked after AppKit's synchronous output allocation. |
| Grants | Distinct exact tool grant. Add the exact name to the builtin Docs agent and ordinary project-default tool sets; custom/imported grants, explicit denials and the independent `fs_write` grant remain. |
| Existing tools | PDF schemas, defaults, Markdown subset and byte caps, shell access and binary transport remain. DOCX input is plain text, without Markdown styling, images, page-layout or Office-suite functionality. |

The authorizer rejects a missing, nonstring, blank or NUL-containing raw path
before ordinary normalization. Existing authorized path handling then applies;
the pack checks the explicit suffix. No new broad filesystem authorization is
introduced. The destination uses the existing descriptor-pinned Data writer.
An atomic rename can succeed before directory fsync fails: `docx_write_failed`
therefore says the destination may have changed and must be inspected before
retrying. Success metadata alone is not an independent format/text/render proof.

## Native ownership

The fixed `--internal-docx-export-v1` mode runs before ordinary app/configuration
bootstrap in both existing App and CLI entries. Compiled native role and exact
current-self/named Core admission remain inherited from the existing public
Security path. No interpreted production runtime, dependency install, caller
script or new credentials are introduced.

AppKit serialization runs on a worker in an owned native child. The parent
requires complete bounded duplex input/output, confirmed termination, zero exit
and both EOFs before writing a destination. One app-owned exporter admits one
operation with no queue; unresolved child termination keeps the slot. App
shutdown cancels and recovers against the original operation deadline.
Security verification is synchronous and uncancellable; AppKit serialization
has no public cancellation callback. Native child/parent lifetime bounds do not
prove preemption of framework parsing, CPU or allocation, and the encoded byte
limit is enforced after AppKit allocates its result. A successful small output
does not establish a peak-memory or leak bound.

## Immutable standalone controls

These controls were run before the product feature and remain separate:

| Evidence | Observation | Qualification boundary |
| --- | --- | --- |
| First eight controls | Three raw UTF-8 equal; five changed, including native paragraph-final LF and CR/CRLF normalization. Both export/import ran on the observed nonmain physical worker. | Original strict raw-UTF8 gate exited one/NONPASS; not rewritten or relaxed. |
| Supplemental eight controls | XML punctuation and repeated LF controls were exact. Native export removed NUL/C0/VT, changed FF to a page break and U+2029 to LF; U+2028 remained a soft line break. Nonending-LF Unicode gained LF. The forbidden FFFE/FFFF case produced invalid XML and native import error Cocoa259. | Original raw-UTF8 gate remains NONPASS. These observations support explicit normalization/rejection, not general format acceptance. |
| Independent bounded OOXML reconciliation | Sixteen retained artifacts, fifteen valid `word/document.xml` parses and one invalid control; 67 input hashes retained. Receipt `native-docx-control-independent-xml-reconciliation-0270.json`, SHA `29dec517c71b743bf29d748de0405bd89eca015730a0171985d247ffc1f6bab2`. | Standalone AppKit controls only; no Forge tool/model/Office rendering qualification. |

Input scalar admission follows the [XML 1.0 `Char` production](https://www.w3.org/TR/xml/#charsets),
which excludes the surrogate blocks and U+FFFE/U+FFFF while admitting TAB/LF/CR.
The selected new contract rejects the invalid/control cases instead of silently
claiming byte preservation. The immutable original raw-byte oracles remain
NONPASS; explicit new paragraph semantics receive separate tests.

## Observed first source regression and narrow correction

`native-docx-new-regressions-first-source-0270` executed sixteen methods and
failed twelve assertions (seven unexpected) across four methods. It exited one
normally in 11.8 seconds with unchanged450 inputs; log
`9a658047d71ecb0fce975ef747fe3b2bd0841569a212efcc537f53039f532806`.
That original receipt remains NONPASS.

`testDOCXCompleteAdmittedTransportReturnsExactBinaryAndOriginalInput` observed
`10000000375 > 10000000000`: a 375 ns operation-deadline overshoot. The exporter
had read remaining time before taking its later monotonic base. It now takes
`entered` before reading `remainingTimeInterval`, matching the existing
ProcessRunner pattern. This source correction does not claim framework
preemption or peak-memory bounds.

Three fixture corrections retain their cases and intended assertions: expected
cancellation/deadline throws are checked outside an `XCTUnwrap` which treated
those throws as unexpected; binary readback requests the existing 32768-byte
maximum instead of 65536; grant denial uses a fresh owner, and changed-binding
coverage uses actual `beginReset`/`completeReset` rather than forbidden duplicate
binding. No existing authorization or read-window protection is lowered.

`native-docx-fixed-boundaries-source-0270` passed its two actual entry/transport
methods at normal terminal0/11.710 s, zero failures/skips, unchanged450 inputs;
log `6e9374cd0502a27dc2e1118a276cfd835f237c350ea6def3a692c7f2a4e8f2e1`.
It has its own earlier source map. `native-docx-four-regressions-corrected-source-0270`
then passed the same four previously failing methods at normal terminal0/
10.313 s, zero failures/skips, unchanged450 inputs; log
`01cd24ec9e705b7ddbf9743fd8c77f5f3f909ccc1d5aefaf3c702c84e05ad736`.
The four are a subset of the sixteen, not four new cases or a complete owning
suite. Neither source command qualifies signed child execution, a final
candidate, actual MCP output or model consumption.

## Current owning source selection

`native-docx-owning-source-first-0270` passed 154 distinct methods, normal
terminal0/39.321 s, zero failures/skips and no warning/error patterns, on its
unchanged450-input map. Log
`72c0991b2cb2d13ec29d978e783f033828bb59e927616e2a36160aca6eb4f2c2`.
The method reconciliation records all21 new DOCX cases and class counts:
Continuity2, filesystem3, entry9, telemetry4, admission17, owned-duplex12,
PDFWriter35, instruction1, secure-parent1, catalog19, router deadlines9,
renderer17 and web25. Focused2/4 repeats are not added to 154.

This source selection includes native API fixture controls and mocked transport
ownership. The initial wrong G3 selector, `testG3_VersionAndBuildAgreement`,
executed zero tests at terminal0 and remains NONPASS:
`native-docx-version-docs-source-0270`, log
`cbea9f79f2536c66f309527fe755456c95538da9a36d1c1a0500fbfa6e8af613`.
The corrected actual `testG3_VersionAndReleaseDocumentsAreAligned` executed one
method/zero failures/skips at terminal0/1.332 s on the same 450 map; log
`560cb7aa94212c7169c8d51f7a03ee761a02304edbad1da6ee56ff752e4167f1`.
Source 154 plus G3 is155 unique methods; no focused repeat is added.

## Current compiled native, build and signing gates

`native-docx-owning-native-first-0270` passed the same 155 actual methods at
normal terminal 0/80.913 s, zero failures/skips, on the unchanged 450-input map
`0b87c1ecc7442f1f414d7b09621756a7accd2ef2e72564765b176e850aebb201`.
The full log SHA is
`cc6219f2941bf834b854e9fbd47bc4f46463408991223503691fa747de97175d`;
exact started/passed reconciliation SHA
`ceb89ac55f0a38f98dd38eba2a589bb84d9e709a9c76308e61b1726665629957`.

The log retains two Thread Performance Checker blocks in passed router deadline
methods, seven NECP lines and fourteen PDF tagging diagnostics, plus the build
destination warning. The two QoS stacks lead to the Utility audit-attempt queue:
an explicit post-return test flush and fixture `ForgeApp.shutdown`. They do not
prove a live GUI inversion, a leak or a DOCX-induced defect. The native result
is not described as diagnostic-free.

Current CLI/app compilation passed at 1.0/1.104 s on unchanged 450 inputs; logs
`0a89238982527477d165bfb112414ded740cc3be0ee36b860ed7253cd5652756`
and `9bf37d757b954f543dcb3fcc0a503843eb72f11b92e1a129b23c400cc7b4cb2b`.
The ordinary Debug build passed at 7.29 s. The strict candidate manifest is
`native-docx-native-candidate-first-0270.json`, SHA
`68763f02a40d4e25f31a5c45524d96d30c00c6929b55c3e123ae73d192d417bd`.
It binds .27/39, Debug, seven binary files, the successful build and exact 450
source map. The local implementation/test baseline was synchronized main
`b3abec1160de1a0ea109f44721c1b7800ee45af8`; the 450-input map above identifies
the updated tested bytes, not a future publication revision. Fourteen prior manifests/ninety-two files and all three protected
files remain unchanged; bundled Docs resource bytes exactly match the source
resource and include `docx_write`. No candidate was installed.

Final graph review binds 23 changed source/resource/test files to their existing
single reference/build/phase/target, and all 14 selected test class files to Core
tests. No new source files or memberships were added. PBX differs only in twelve
marketing and sixteen build assignments. The canonical workspace/Package paths
and resource ownership remain. Applied current docs are outside the 450 inputs.
The native selection uses the ForgeConductor scheme and exact Core selectors in
separate test DerivedData. Source/native tests and strict signatures do not by
themselves qualify actual tool wire, independent DOCX contents or Qwen use;
the separate observed flows below provide those specific checks.

## Actual native wire and artifact checks

App and CLI each passed 9 actual wire cases: Unicode/literal text, blank paragraphs,
empty text, five exact-code/no-write negatives, and a PDF neighbor producer
control. Each parent consumed 16/16 correlated requests, exited normal exit 0 with both
EOFs and no forced termination, truncation or unconsumed tail. All three DOCX
files per role passed bounded independent OOXML checks and full binary
reconstruction/hash comparison. The PDF neighbor checks producer metadata only,
not PDF semantic or glyph qualification. Wire summary SHAs are
`cd71b651e602b09d55226b30f3fe61776449df9298a39a6b22d62b4d9b1561cd`
(App) and `3169c59d0ee98bb1f00e0c2005c5d760ffd0dc59930040d954d04690714301be`
(CLI).

A separate native AppKit importer read the 6 wire documents on a nonmain physical
worker and matched exact expected paragraph UTF-8: 110/14/1 bytes for Unicode,
blank paragraphs and empty text per role. Separate imports matched the first
Qwen artifact's 132 expected bytes and R2's 102 bytes. All 8 actual files were
rechecked in the final runtime reconciliation. These are exact fixture-oracle
results after the stated normalization/native paragraph contract, not a general
promise that original input bytes survive every importer.

The current production Core instruction consumer passed 6 cases on a nonmain
physical worker using the pinned candidate's actual Core framework. Four
nonempty documents produced exact canonical 110/14-byte UTF-8, hashes and cursor
readback. Both empty originals were preserved at 0400 with no canonical text,
zero instruction bytes, one unresolved document and a typed read rejection;
they remained `unrepresented_visual_structural`. Empty documents did not become
fabricated instructions. Summary SHA
`39aa35046f4b0be283587c9475e48f6e36c225916d72184441b189e5c667386b`.
The first standalone consumer compile lacked Swift modules in the bundled
framework; the corrected compile used the existing Debug framework Modules
include path. That evidence utility change did not alter the product graph or
source.

## Actual Qwen workflow and retained first failure

The first exchange completed 3 model responses and consumed both actual tool
results with normal final STOP; its native parent exited 0 with full EOF. Its
independent artifact import passed 132 exact expected bytes. The combined gate
remains NONPASS because only 2/3 attributed input events were observed, so its
actual-Low gate was incomplete. The outer collector exited 1 and recorded
`forced_cleanup:true`; group cleanup attempts returned EPERM1 and delivered no
signals. Do not describe that outer receipt as unforced. The immutable first
summary SHA is
`cf587d4980c94263484200609357370a33ee768171da91a212f4bce85243a650`.
A missing first mapping is observed; its cause remains unproved.

Fresh R2 used the same bounded semantic oracles and retained the strict actual
Low 3/3 requirement. Three attempted/completed model responses selected two
actual calls, whose full correlated results were verified, delivered and
CONSUMED; the final metadata was a normal scalar STOP. The observer and native
parent exited normal exit 0 with both EOFs, no forced kill, truncation, cap or errors.
The native parent sent and consumed 6/6 requests with zero response tail.
The outer collector exited 0 at 80.649 s, both EOFs, unforced. Summary SHA
`83a256cdcab6a036eafd0d8e8b36df8e90254b944fd76a82d8b6495aa0013cbc`;
outer log SHA
`ad132f0fe10b31d1a89740e2e7d12bd2b3ca6664ab6e64af1cddae7365bf0422`.
The actual 3579-byte DOCX SHA is
`1f942001c86d23377e3dbdfb1a8ae4ecdad2f51817511ad48f3dcffa409daad0`.
Separate native import matched 102 expected bytes/SHA
`f9db1afeb613021d5a1b50936012f5246f90f10953e8301d95a3fa407c4a94b4`.

R2 observed the public observer startup banner and all 3 nonce-attributed Low
events. The banner precedes subscription and is not a subscription ACK or a
universal readiness guarantee; this pass does not prove the first miss's cause.
The exchange is a separate LM Studio API chat with an isolated signed candidate,
not active installed-GUI acceptance, general model behavior or host rollover.

<a id="pending-feature-gates"></a>

## Current gates and preserved boundaries

| Gate | Current evidence | Status |
| --- | --- | --- |
| Source admission/catalog | Owning154 plus actual G3 passed 155 unique methods, including all 21 new cases; native 155 passed the same methods, zero failures/skips on unchanged 450 inputs. First 16 and wrong-selector G3 NONPASS are retained. | Source/native PASS within the selected scope; not actual wire/model acceptance. |
| CLI/app and canonical build | Current CLI/app and ordinary Debug compile passed; all 23 changed memberships and all 14 selected test class files retain existing ownership. Version/doc agreement passed G3. | PASS on the recorded450 map; Release and broader matrices are separate. |
| Signed candidate | Strict Debug manifest68763f02… verifies seven binary files, exact Docs resource bytes, complete source/build binding, fourteen prior manifests/ninety-two files and three protected files unchanged. | PASS for this candidate; no installation or notarization claim. |
| Actual native tool/artifacts | App/CLI each passed 9 wire cases/16 consumed requests, normal exit 0/full EOF; six DOCX artifacts passed independent OOXML/full binary reconstruction; all 8 actual files passed exact expected native import. | PASS for the explicit paragraph contract and bounded fixtures, not full Office/render/importer fidelity. PDF neighbor remains producer-only. |
| Existing consumers | Current production Core passed 6 cases: 4 exact canonical nonempty documents, 2 empty originals retained/no canonical/one unresolved/typed read rejection. | PASS for current instruction-consumer parity; no invented text for empty artifacts. |
| Qwen | Fresh R2 passed 3 responses, 2 actual tool results consumed, actual Low 3/3 and scalar STOP; native/observer/outer normal exit 0/full EOF. Artifact independently imported 102 exact expected bytes. | PASS for this API/candidate run. First combined NONPASS 2/3/outer forced-cleanup classification remains; no installed-GUI or general observer claim. |
| Delivery | Final runtime reconciliation `native-docx-root-final-runtime-reconciliation-0270.json`, SHA227ee6c7…, binds unchanged source450/candidate7/protected3 and 14 prior manifests/92 named binaries. | Runtime receipts do not demonstrate publication. Exact source/wiki delivery identities are recorded separately in the external closeout receipt after remote byte readback and safe synchronization. |

The current protected paths remain the working app executable, working CLI
helper and LM Studio registration (`/Applications/Forge Conductor.app/Contents/MacOS/Forge Conductor`,
`/Applications/Forge Conductor.app/Contents/Helpers/forge-conductor`,
`/Users/flynn/.lmstudio/mcp.json`). They are guarded read-only; this feature
installs no candidate or registration change. Exact candidate/installed scopes
remain separate.

[The native PDF record](NATIVE-PDF-WRITING.md) retains pure-PDFKit and mixed-order
NONPASS gates. [Web budgets](WEB-RESPONSE-BUDGET.md) retain .26.1 Qwen final-request
timeouts and .26.2 diagnostics/receipt scopes. The 54 capability themes,
full-web/authenticated interaction, installed-GUI acceptance, broader Office
features, Release/notarization and shipment remain open. This new tool closes
none of those gates by implication. Follow [delivery workflow](DELIVERY-WORKFLOW.md)
and [versioning](VERSIONING.md). The separate external closeout receipt records
exact source/wiki delivery identities after remote verification; runtime receipts
do not prove publication, and source edits do not guess their own future refs.

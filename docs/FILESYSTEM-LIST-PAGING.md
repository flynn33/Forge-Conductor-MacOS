# Bounded filesystem list continuation

Current source is **0.24.0 (34)**, based on synchronized owner-authored source
`574aa99ccd5ba38966f79f4cce0f3c855ea4b7fc` and wiki
`45aec34b14512ac3b1dec5db2a7c6121cd49a925`. The final affected selection passed
173 source tests and the same 173 compiled native Core tests. Signed Debug and
Release listing/renderer matrices and actual Qwen continuation passed within
the scopes below. Failed attempts remain **NONPASS**. The published
[0.23.0 renderer record](https://github.com/flynn33/Forge-Conductor-MacOS/blob/574aa99ccd5ba38966f79f4cce0f3c855ea4b7fc/docs/NATIVE-WEB-RENDERING.md)
retains its exact receipts. Installed application and LM Studio registration
remain separate protected inputs.

## Observed 0.23.0 baseline

The unchanged signed Debug helper served an isolated project with fresh owned
files. Its actual `fs_list` descriptor advertised optional `path` and the shared
`deadline_ms`, with no paging fields. The three-case baseline observed:

| Call | Actual result |
| --- | --- |
| Three files, path-only | Three entries; `truncated: false`; no continuation |
| The same files, undeclared `limit: 1` | Three entries; the undeclared limit was ignored |
| 1,001 files, path-only | 1,000 entries; `truncated: true`; no continuation |

All seven correlated native responses were consumed. The native parent exited
zero with both actual EOFs, no tail/truncation or forced termination. All 445
source inputs, seven candidate inputs, three protected installed/registration
inputs and harness inputs were unchanged. The successful baseline proves the
missing continuation capability; it does not qualify its repair. It does not
establish which filename a different filesystem enumeration will omit.

The first harness attempt executed zero listing cases because its schema oracle
omitted the globally advertised `deadline_ms`. It consumed its four setup
responses and shut down normally but remains **NONPASS**. The corrected oracle
required exactly `path` plus shared integer `deadline_ms` (1–60,000); no product
change or listing assertion was relaxed.

## Observed input boundaries and retained failed checks

Two deterministic source regressions reproduced input loss before the listing
handler. The raw-wire test executed one case and failed because the fractional
JSON token `1.0000000000000000000000000000000000000000001` did not produce the
required rejection. The routed numeric-path test executed one case and failed
three assertions: it returned the owned `sentinel` entry instead of
`listing_invalid_argument`. Both commands exited 1 without timeout, output-cap
or forced-cleanup flags; their receipts remain **NONPASS**.

`MCPStreamReader.decodeMessage`, in `MCPServer.swift`, now checks the original
JSON tokens for paged `fs_list` `limit` and `maximum_bytes`. Its NDJSON,
Content-Length and final-EOF branches share that decoder. Exact integral
notations such as `1.0` and `1e2` remain accepted; a fractional value that
Foundation would round to an integer is rejected. The rejection preserves the
request correlation and reaches the ordinary invalid-argument result rather
than ending the server. `ToolAuthorizationService.authorize` also validates
the original paged arguments before existing path normalization can turn a
numeric path into a string. These changes are limited to opt-in paged listing.

The corrected interim selection executed **34 source tests**, with **four
failures, one unexpected**, and exited 1 without timeout, output-cap or forced
cleanup. All four selected MCP checks and the routed numeric-path regression
passed, including raw-token checks across the three framing branches and
correlated rejection followed by a successful ping. The overall selection
remains **NONPASS**. Its failures include active-binding fixture
setup, canonical `/private` path expectations and final-context/error
expectations. A subsequent 35-case selection passed all five selected MCP
checks but still failed the canonical path expectation and exited 1. It also
remains **NONPASS**. The fixture corrections retain the active-binding guard,
use the supported Manager generation-reset/reactivation path and ordinary
web-scope migration, and compare the physical existing path for the alias
oracle. No required assertion was removed or weakened.

A further one-case source baseline rejected fractional `maximum_bytes` with
the wrong `listing_output_budget` code. The reader initially invalidated
`limit` regardless of which count token failed, leaving the rounded byte
allowance active. It now invalidates the specific failed field, preserving
`listing_invalid_argument` and subsequent server liveness. Both targeted
corrected cases passed; they are included in the final 173-case selection,
not added to that distinct count.

The earlier corrected Swift CLI build exited zero, but preceded these input
boundary changes. It does not qualify the current changed-source CLI or app
products. The final CLI and app builds below use the corrected frozen inputs.
The initial focused source attempt stopped at two test compiler errors before
any cases executed and remains **NONPASS**.

## Additive contract

The tool name remains `fs_list`. Supplying any of `limit`, `cursor` or
`maximum_bytes` selects paged mode. Path-only calls, including calls with only
`deadline_ms` added, retain the legacy 1,000-entry count cap and result fields.
Existing project binding, read-only classification, canonical/default path and
tool grants remain the authorization boundary. A cursor grants no access.

| Input | Paged contract |
| --- | --- |
| `path` | Optional string, validated before existing authorized canonical/default-path normalization in paged mode |
| `limit` | Strict integer 1–1,000; default 100 |
| `cursor` | Returned opaque canonical version-1 token; maximum 8,192 encoded bytes and 6,144 decoded bytes |
| `maximum_bytes` | Strict integer 1–65,536; default 16,384; reduced by the captured project inline allowance |
| `deadline_ms` | Existing shared total tool deadline, integer 1–60,000; does not itself enable paging |

The source contract rejects boolean, fractional, out-of-range and malformed
paged inputs before directory enumeration. The final source and native receipts
below cover explicit boundary rejection; native responses alone do not prove
that no filesystem syscall occurred.
Continuation preserves `path`, `entries`, `truncated` and
`maximum_entries: 1000`, and adds `returned_entries`, `effective_limit`,
`has_more`, `next_cursor` and `ordering: "raw_filename_bytes_v1"`.
`truncated` mirrors `has_more` in paged mode. A page can return fewer than its
requested limit to fit the budget. Continue from the last actually emitted name
using `next_cursor`; do not manufacture a cursor from the requested count.
At real page exhaustion, `has_more` is false and `next_cursor` is null. An empty
directory can return an empty terminal page. No total-directory count is claimed.

The cursor binds client identity, stable project ID/generation, canonical path,
ordering version, observed directory metadata and the raw last-returned filename
bytes. It is a consistency token, not authentication. The source checks each
call's current authorization context and rejects another
client/project/generation/path. The compiled tests exercise actual project
switch and generation reset through supported APIs. The signed MCP matrix
exercises cross-path and cross-client rejection, not a runtime project-reset
matrix. Limit and output allowance can vary between pages. Changed
directory metadata requires restarting without the old cursor.

## Ownership, work and snapshot limits

The source gives each call ownership of a native direct-directory stream. It
copies each raw name before the next `readdir`, retains a bounded selector of
at most `limit + 1` names, and sorts only that selection by raw filename bytes.
It never recurses into a listed child or opens that child's content. The owner
calls idempotent `closedir` from
an explicit `defer`, with a `deinit` fallback. No cross-call handle store, cursor
cache, persistent index, watcher or background task is introduced. The focused
SwiftPM and compiled Core regression observes `closedir == 0` exactly once on
success, cancellation, quota and stale-context paths. This is scoped lifecycle
proof, not a whole-process descriptor inventory or broad leak qualification.

Each successful page scans to directory EOF, processing at most 100,000 direct
names within a 15-second scan bound intersected with request control. An extra
name read can detect quota overflow and returns an error rather than a page.
The limits bound algorithm work and retention; they do not promise bounded
latency for synchronous filesystem syscalls. Every continuation scans the
directory again. A filename selected for output that cannot be represented as
UTF-8 yields `listing_name_encoding_unsupported`; arbitrary non-UTF-8 filename
transport remains unsupported. The strict selected-name decoder has source
coverage; actual invalid-byte filename reachability on APFS is not claimed.

The helper observes directory device/inode/mode and mtime/ctime nanoseconds at
first open, compares a continuation's metadata fingerprint, checks the same
open stream after scanning, reopens the path for an identity/version fence, and
revalidates captured project context before return. Descriptor-relative
no-new-link traversal is the source rejection boundary for newly substituted
symlink paths. Compiled tests exercise in-scan replacement/substitution; the
signed MCP matrix exercises additions and replacement between pages. These
fences cannot detect a real-directory replacement between authorization and the first
open. They are not an atomic directory snapshot, content digest, or universal
protection against restored metadata. Concurrent mutation, stale context,
hostile mounts and syscall latency require their own qualified checks.

## Complete stdio response budget

The source pack selects a fitting prefix using bounded serialized output and
builds its cursor from the last emitted raw name. The paged-list-only MCP boundary
then checks the actual response ID, duplicated text/structured payload, required
policy notice and terminating LF against the allowance. If this complete frame
does not fit, it returns `listing_output_budget` without trimming the page or
advancing its cursor. Retry with a smaller page after an explicit budget failure;
never treat a failed response as progress. Maximal budget utilization is not
promised. An impossible ID/notice allowance cannot hold even its correlated
error envelope; IDs and mandatory notices remain preserved. Source tests cover
actual ID plus required notice. Debug and Release MCP frames were measured
with their real IDs and LF, but no policy notice was present or fabricated;
notice-bearing runtime qualification remains open.

Legacy path-only listing and other tools retain their separate output contracts.
The renderer's LF correction below is independently scoped. No native-task HTTP
profile, new filesystem authority, storage schema or settings migration is added.

## Explicit failures

| Code | Meaning |
| --- | --- |
| `listing_invalid_argument` / `listing_invalid_cursor` | Invalid paged input or noncanonical version-1 token |
| `listing_cursor_scope_mismatch` | Cursor belongs to another client/project/generation/path |
| `directory_changed` | Observed directory metadata changed; retryable restart |
| `listing_scan_limit` / `listing_scan_deadline` | Finite scan quota or scan end exceeded; no terminal page fabricated |
| `listing_name_encoding_unsupported` | Selected filename cannot be returned as UTF-8 |
| `listing_output_budget` | Complete response cannot fit; no cursor advance |
| `listing_read_failed` | Native directory read failed |
| `listing_worker_required` | Paged listing was invoked on the main thread; no directory scan begins |
| `project_context_required` / `project_context_stale` | Current project context absent or changed |

Existing cancellation and tool-deadline classifications remain separate.

## Renderer line-feed boundary after 0.23 publication

The published renderer document remains immutable. A later deterministic source
regression, `WebRendererServiceTests/testFinalMCPBudgetIncludesTerminatingLineFeedAtExactJSONBoundary`,
observed a 3,730-byte complete stdio frame against a 3,729-byte JSON-only budget.
The test failed one assertion and exited 1, without timeout, output truncation or
forced cleanup. `WebRenderToolPack.finalMCPResponse` had sized JSON bytes before
the transport appended its LF. The minimal correction measures
`MCPStdioTransport.encode(MCPToolResponse.object(...))` in the final fit check.

All 17 `WebRendererServiceTests` then passed, including the unchanged required
ID/notice, digest, UTF-8, ownership and completion assertions. The source command
exited zero in 9.93 seconds without deadline/capture-cap/forced-cleanup flags.
This is deterministic source-test proof, not a new signed artifact, actual MCP
runtime or Qwen pass. The later 0.24.0 Debug and Release MCP matrices below
measure actual LF-inclusive bytes. The earlier 0.23.0 runtime receipts retain
their original JSON-only measurement scope and are not relabeled as LF proof.

## Source and build graph impact

The current descriptor splits `fs_list` from the unchanged `fs_delete` and
`fs_mkdir` path schemas. `MCPServer` captures a separate paged-list budget and
passes it through the existing deadline/notice response route. The helper's
stateless cursor, selector and descriptor owner are new Core code; filesystem
handler integration and focused tests now pass their final affected selection.
The pre-normalization argument gate and targeted raw-token decoder are additional
boundaries in existing authorization and MCP source, with unchanged legacy mode.

The existing canonical project registers one new Core file,
`Application/Tools/FilesystemListingPage.swift`, and one Core test file,
`FilesystemListingTests.swift`. The new files compiled and executed through the
canonical workspace in the final affected native selection. The resolved graph
audit verified all 12 affected Swift file/group/target memberships, four added
PBX objects (two file references and two build entries), two group insertions
and two Sources insertions. Existing memberships, dependencies, signing and
native `libbsm` settings remain unchanged; the workspace is unchanged. The
earlier basename-only graph oracle failed before its checks and was corrected
to resolve actual group paths. That retained harness failure establishes no
product failure. No project regeneration or signing change is part of this slice.

## Final source, native and model receipts

The frozen **447-input** selection passed **173 distinct source cases**, zero
failures/skips, in 74.493 seconds. The canonical Debug Core test lane executed
the **same 173 cases**, zero failures/skips, in 112.614 seconds. These are two
executions of the same case set, not 346 distinct tests; the earlier 17-case
renderer and two-case raw-boundary passes are not added to the final count.

| Selected class or method | Actual cases |
| --- | ---: |
| `CoreTests` | 60 |
| `FilesystemCancellationTests/testBinary…` | 9 |
| `FilesystemListingTests` | 30 |
| `G1G10AcceptanceTests/testG3_VersionAndReleaseDocumentsAreAligned` | 1 |
| `MCPProtocolAndDiagnosticsTests` | 31 |
| `ToolDefinitionCatalogTests` | 16 |
| `ToolRouterDeadlineTests` | 9 |
| `WebRendererServiceTests` | 17 |

Final Swift CLI/app builds exited zero in 0.898/0.880 seconds. Canonical Debug
and Release builds exited zero in 24.011/147.188 seconds and passed strict deep
signature checks. Their manifests record seven Debug and five Release candidate
inputs, with all five preceding candidates and three protected installed/app
registration inputs unchanged. Each gate retained all 447 frozen source inputs,
with no deadline, capture-cap or forced-cleanup flags.

Debug and Release listing each passed **35 actual MCP cases**, consuming all
**52/52 responses** across two native parents. Each parent exited zero with
both real EOFs, no response tail, truncation, unconsumed response or forced
termination. Both runs recovered all **1,001 unique names in eight pages**.
The escaped 24-name fixture returned five names first, then recovered the other
19 from the exact returned cursor. Its first complete frame was **3,785 bytes
(3,784 JSON + 1 LF)** in Debug and **3,801 bytes (3,800 + 1 LF)** in Release;
the different evidence paths change serialized byte counts. Both recovered
the exact 24-name union. The matrix also observed actual raw near-integer
`limit`/`maximum_bytes` and numeric/boolean/null-path rejections, followed by a
correlated ping on the same server. It retained the original 29 stable oracles.
The Release harness only adds an explicit Debug-seven/Release-five manifest
profile; all 35 case oracles remain identical.

The LF-aware renderer matrix passed **35 CLI cases/39 responses** and **10 app
cases/14 responses**, separately in Debug and Release. These new receipts count
actual terminating LF bytes, retain default text fetch parity, and finish with
native zero/both EOFs, closed fixture servers and unchanged source/artifact/
protected inputs. They do not qualify notice-bearing runtime envelopes,
macOS 26 rendering, universal prompt suppression or whole renderer heap, DOM
or network limits.

Actual LM Studio API model `qwen/qwen3.8-27b` made **four requests**, three
`tool_calls` followed by normal `stop`. It consumed three one-entry signed MCP
pages: the initial page and two continuations, using the previous returned
cursor unchanged on each continuation. It reported `alpha.txt`,
`middle.txt` and `zulu.txt` exactly once with `has_more: false`. The nonce-scoped
template observer observed Low in **4/4** actual input events. All **7/7**
native responses were consumed, with native zero/both EOFs and unchanged source,
candidate, protected and harness inputs. This is actual API consumption of the
Debug candidate, not an active GUI chat or installed-deployment pass; no Release
model replay is claimed.

The compiled native tests emitted five Thread Performance Checker QoS warnings
at `DiagnosticLog.flush`/shutdown drain lines 64/75: three existing Core tests
and two existing router-deadline tests. All five tests passed. No ordinary GUI
priority inversion is established by those test-host warnings.

## Qualification and open limits

| Gate | Current state |
| --- | --- |
| Unchanged 0.23.0 native baseline | Three actual listing cases observed; normal parent/EOF/hash guards passed |
| Renderer LF source regression | Failing exact boundary retained; corrected 17-case source selection passed |
| New paging source and affected parity | Final 173 source cases and same 173 compiled Core cases passed; initial compiler/34/35-case failures retained |
| Paged input boundaries | Original fractional/path and wrong-error baselines retained; corrected exact-field rejection and liveness passed in source/native |
| Final graph/identity and current-version checks | New graph members compiled; current-version method passed in both selections |
| Swift CLI and app products | Final corrected-input builds passed |
| Canonical signed native builds and strict signatures | Debug and Release passed |
| Native complete 1,001-name continuation, budgets and negatives | Debug 35 cases/52 responses; Release 35 cases/52 responses passed |
| Native renderer LF boundary qualification | Debug and Release CLI 35/app 10 matrices passed with actual LF-inclusive counts |
| Qwen continuation consumer | Debug candidate three pages/four requests/normal stop passed |
| Policy-notice-bearing runtime frame | **OPEN**; source final-frame tests cover required notice and actual ID, native runs had no notice |
| Installed/deployed/UI, hostile mount and broad filesystem acceptance | **PENDING** |

Exact logs, hashes, descriptors, protocol transcripts and terminal receipts are
retained under the owner's external
`Forge-Conductor-Evidence/2026-10-07-project-web-qwen` directory, including
`native-fs-list-baseline-023-r2/summary.json`, the retained first attempt,
`filesystem-list-{input-boundary-baseline,path-boundary-baseline,source-corrected,source-initial,cli-corrected}-024`
logs and terminal receipts, `filesystem-list-raw-budget-error-{baseline,corrected}-024`,
`filesystem-list-affected-source-final-024-r2`, `filesystem-list-native-core-tests-024`,
`filesystem-list-graph-final-024.json`,
`filesystem-list-{native,release}-candidate-024.json`,
`native-fs-list-paging-024-r2/summary.json`,
`native-fs-list-paging-release-024-r3/summary.json`,
`qwen-fs-list-continuation-024-r2/summary.json`,
`native-render-wire-{debug,release}-{cli,app}-024/summary.json`, and the retained
`native-render-lf-boundary-{baseline,corrected}-024` source receipts. Receipt
names do not change their source-versus-native evidence class. The attachment is
feedback, not dispatch or authority to remove existing limits or protection.

The final affected source log SHA256 is
`c2dd9c4e4381ac75e8321148beca7367f5439c8df6a2547ac080e1f8a89070ca`;
the compiled Core log is
`45433dce381845a1732107aa34f00ee90cf1390a130012ffc309cb17938a2b18`.
The Debug build log is
`aed51236d140518f715d056eb7ccc09c1b24d857d2a21bce577e56eadafb77dd`;
the Release build log is
`0f1cabc34d938938b9bbca2a558954008466064038cfa3ee6f094c3182a92697`.
Full executable/Core hashes and strict signature receipts are retained in the
two candidate manifests above; these are candidate identities, not the working
installation's identity.

# Web response budgets

<a id="notice-receipt-truth-follow-up"></a>

## Notice receipt truth follow-up

The current **0.26.2 (38)** target corrects when the existing stdio path records
an additive notice as presented. Private transport completion is true only
after all encoded JSON bytes and the terminating LF are written. Both existing
receipt sites commit only true; skipped/partial output discards pending
presentation state, and thrown write errors discard while preserving the
same error path. The canonical tool response remains authoritative. Existing
response sizing, grants, schemas, request/write deadlines, EOF cancellation and
reader-error/shutdown-timeout/worker-error precedence remain unchanged.

The corrected skipped and partial EOF baselines each ran one method with one
failure: `didPresent` was called once after zero notice bytes or an incomplete
real JSON prefix without LF. Both completed normally without cap/deadline or
forced cleanup; original failures and earlier fixture attempts are retained.
The focused two-case repair passed; the existing complete-packet/durable-notice
integration and the new EPIPE/server-reuse parity method also passed separately.
These repeats are included in the owning selection, not added to its count.

The owning selection passed **92 distinct source methods** (41.535 s, 28,060
captured bytes, log `972ba7dc…`) and the **same 92 compiled native methods**
(81.689 s, 761,519 bytes, log `97ee779a…`), zero failures/skips on identical
450-input maps. It contains 40 MCP, 25 web, nine router-deadline and 16 notice
methods, the exact complete-packet integration, and the current version method.
Three DesktopAttachment methods in the MCP test file were not selected.
The native run retains 117 vnode-unlink and 117 invalidated-fd diagnostics,
three NECP network lines, and five QoS blocks/four source warning lines.

Only the private EOF fixture serve-controller priority changed afterward:
`.utility` to `.userInitiated` with enforced QoS. All 449 other source inputs,
including the product and graph, stayed exact. The same one source method passed
in 5.590 s (1,716 bytes, log `c926a8c9…`) and one compiled native method passed
in 5.567 s (60,457 bytes, log `ef4892e0…`) without QoS/source warnings; the
native destination warning remains. The original 92-case receipts retain their
original test hash and diagnostics; 92 is not claimed on the later test map.
The other Stjornarvald notice and DiagnosticLog warnings remain separate open
investigations. An ordinary GUI priority inversion is not established.

Incremental CLI/app compilation passed (5.291/2.302 s). Current version and
canonical graph checks passed: all four changed Swift files retain their
existing Sources memberships. The 49-item graph/resource/fixture inventory
keeps 48 exact inputs; PBX changes only twelve marketing-version and sixteen
build-number assignments. Ordinary Debug first passed in 25.161 s; final build
confirmation passed in 1.552 s (22,812 bytes, log `531aad8a…`) on the final
450-input priority map, and strict deep signing passed for seven final identities.
Four signatures were replaced, changing four of the initial .26.2 candidate's
seven binary SHA identities. Its unchanged-candidate guard failed and remains
retained; that first candidate is superseded by the final manifest. Thirteen
preceding-phase manifests/85 binaries and three named protected file identities
remained exact. Synchronous pre-dispatch deadline receipt is not directly forced.

Presented means complete serialization to the transport, not host read,
acknowledgement, understanding or compliance. Default notice-cache owner
lifetime remains a separate E2 risk; no lifecycle repair is claimed. The
preceding .26.1 Qwen final completion remains OPEN/NONPASS. Full-web, installed,
all-feature and shipment gates remain open.

Exact current receipts under the evidence root below are the skipped/partial
baseline terminals, `mcp-notice-receipt-owning-source-final-0262-terminal.json`,
`mcp-notice-receipt-owning-native-final-0262-terminal.json`,
`mcp-notice-receipt-source-native-reconciliation-0262.json`, and
`mcp-notice-skipped-write-priority-source-0262-terminal.json` /
`mcp-notice-skipped-write-priority-native-0262-terminal.json`,
`mcp-notice-skipped-write-priority-reconciliation-0262.json`,
`mcp-notice-receipt-native-debug-final-build-0262-terminal.json`,
`mcp-notice-receipt-native-candidate-final-0262.json` and
`mcp-notice-receipt-final-candidate-root-reconciliation-0262.json`. The following
.26.1 response-budget contract and proof retain their original version and identities.

The **0.26.1 (37)** hotfix corrects the existing `web.fetch` and `web.search`
stdio response allowance. It adds no tool, argument or capability. Final source,
compiled native, ordinary Debug build/signing and four native wire cases passed;
Qwen completion remains OPEN/NONPASS and native diagnostics remain recorded.

## Contract

`maximum_bytes` remains 1–65,536 (default 16,384), also limited by the project
scope's `maximumInlineOutputBytes`. A successful stdio response fits that minimum
including the actual request ID, text and structured payload copies, required
policy notice and exactly one terminating LF. IDs and required notices are not
removed to fit.

The router configures the request deadline and validates the invocation context
before an internal non-escaping callback captures its scope. Dispatch uses that
same context. Failed resolution keeps the existing router error/audit path;
there is no second invocation lookup to derive the web allowance. Policy notice
selection and delivery retain their existing behavior, and final sizing includes
the notice actually returned by that path.

For fetch, final sizing can reduce the already-produced page to a positive
UTF-8 prefix or canonical base64 of a decoded-byte prefix. The original
`byte_offset`, `total_content_bytes` and whole `content_sha256` remain. The final
`returned_content_bytes` counts UTF-8 or decoded bytes; `next_byte_offset`
advances by that count when `has_more` is true. At true content end the cursor
is null. Optional HTML title/heading metadata is omitted if it would displace
a readable positive page. Each continuation still fetches the URL again; use
`if_content_sha256` to reject changed content and decode each base64 page
separately before appending its bytes.

For search, reduction removes only trailing whole result entries, retaining
order and setting `count`/`truncated` consistently. A nonempty provider result
cannot become a successful invented zero-result response just to fit. A genuine
provider no-results response remains available when its envelope fits.

Existing failures retain their complete payload, codes and router handoff fields.
Nonempty content must yield a positive page; empty content/EOF remains available
when its metadata fits. If a success cannot fit required metadata or that positive
page, the final response is `web_output_budget_too_small`; its body/results
and advanced cursor are removed while unrelated authorization and handoff
fields remain. An impossible error envelope may exceed the allowance. The contract is a bound on successful
responses, not a promise that an arbitrary ID/notice/error fits one byte.

The 1 MiB receive limit, five redirects, request deadlines/cancellation, TLS,
network/tool grants and project isolation remain. Fetch/search execute no
JavaScript. `web.render`, task HTTP transport, browser profiles/authentication,
whole-network/DOM/heap bounds and installed acceptance retain separate contracts.
This formatter adds no receive cache or network request.

## Observed baseline and final candidate evidence

`web-fetch-wire-baseline-026/summary.json` retains the signed ordinary-build .26
Debug MCP failure. Ordinary-ID text pages measured 1,938/1,941 bytes and base64
pages 1,942/1,942, within 2,048. Escaped-ID first pages measured 2,477 text and
2,481 base64 bytes, including LF, despite exact valid content prefixes, whole
SHA and byte cursors. The baseline remains NONPASS.

The parent exited normally at zero with stdout/stderr EOF, no truncation or
forced cleanup. It consumed twelve complete LF responses and eight owned GETs;
the fixture closed and all declared source/candidate/protected/harness guards
were unchanged. This proved two-page prefixes, not complete body unions, and
exercised zero additive policy notices. Candidate evidence does not qualify the
installed application, active GUI chat or a model consumer.

| Gate | Actual final evidence and scope |
| --- | --- |
| Source and version | 139 distinct methods, zero failures/skips: owning 88 (Web 25, Router 9, MCP 37, Notice 16, G3 one), plus real shared parity 51 (Listing 30, ProjectContextIntegration 10, WebRenderProtocol 11). Logs `2ba6b1d0…` / `3790ac8e…`, 37.972 / 17.236 s. Unmatched ProjectContextTests/WebRenderToolTests names receive no credit. Earlier focused runs are not added. |
| Compiled native | The identical 139 methods passed, zero failures/skips, 91.566 s / 753,609 captured bytes, log `646ac64f…`. The reconciliation matches exact methods and all final source maps to the same 450-input candidate map. |
| Build/signing | Incremental CLI/app: 0.881/0.872 s, 53 bytes each, logs `3b5a8da9…` / `21254f72…`. Ordinary canonical Debug: 25.389 s / 467,591 bytes, log `1bff22df…`, zero compiler warnings and retained destination warning. Strict deep signing: exit0/full EOF, seven binaries, log `9e4c654d…`. |
| Canonical graph/identities | Seven changed Swift files retain their existing build-phase memberships. Of 49 graph/resource/fixture inputs, 48 are byte-identical; only twelve marketing/sixteen build assignments change. Twelve preceding candidate manifests/78 binaries and three named installed/registration identities remain unchanged. |
| Signed native complete wire | All four cases passed: eight positive pages/twelve LF responses, helper 67634 normal0/full EOF, closed fixture and unchanged guards. Escaped first text/base64 frames are 2,047/2,041 bytes versus baseline 2,477/2,481; ordinary pages remain 1,938/1,941 and 1,942/1,942. SHA/prefix/cursor oracles passed. Two-page prefixes and zero notices retain their scope. |
| Actual model consumption | OPEN/NONPASS. The ordered content-block external R4 repeat attempted three turns/completed two, selected/sent/correlated/consumed/verified two real pages at 2,047/1,968 LF bytes, then killed final API worker 69583 at its 90 s deadline without a consumed final normal stop/report. Low was observed on all three input events. Native helper 69495 and observer 69504 exited normally/full EOF, with six native LF responses, two credential-free GETs and unchanged source450/candidate7/protected3/harness maps. The two pages do not make the model case PASS; installed GUI parity and a proven timeout cause are not claimed. |
| Installed/full-web/all-feature/shipment | OPEN and separate; no Release hotfix or installed qualification is claimed. |

The native 139 run emitted 116 SQLite vnode-unlink and 116 invalidated-fd
diagnostics, 20 unconnected-network lines and three QoS blocks with two source
warning lines. Their separate repair is open. These are actual test-runtime
diagnostics, not a warning-free pass or a demonstrated installed/GUI failure.
The scoped MCP tests exercised LF-inclusive escaped/numeric IDs and an injected
stateless required notice; the four-case signed loop exercised zero notices.
This does not qualify persisted live policy-notice delivery on that candidate.

R2 offsets/counts were 0/57 and 57/255, next cursor 312; its final-request
failure is retained in `web-fetch-qwen-repair-r2-final-027/summary.json` and
log `bf794c95…`. Provider completion after cancellation contained empty output;
that disposition is not a consumed model report. The zero-model harness receipt
is `web-fetch-qwen-repair-final-027/summary.json`. R3 retains the same two page
offsets/counts and its own final-API deadline NONPASS in
`web-fetch-qwen-repair-r3-final-027/summary.json` (summary SHA `d10e8457…`).
Its native helper 68177 and observer exited normally/full EOF; final API
worker 68211 was killed at 90 s without a consumed final report. All three
negative receipts keep their identities. The ordered content-block R4 repeat
also remains NONPASS in `web-fetch-qwen-repair-r4-final-027/summary.json`
(SHA `0a2af355…`). The reconciliation confirms that its immutable model
requests preserved every actual ordered content-block value. Its own scoped
provider completion after disconnect produced no API final output; this is
not a consumed model stop. No further repeat is pending for this hotfix.

Exact receipts are `web-final-frame-source-native-reconciliation-027.json`,
`web-final-frame-native-candidate-027.json`,
`mcp-web-wire-canonical-review-027/review.json` and
`web-fetch-wire-baseline-and-repair-root-comparison-027.json`. Final R4 scope
is retained in `web-fetch-qwen-r4-root-reconciliation-027.json` and
`web-fetch-qwen-r4-provider-disposition-027.json`; final current byte identities
are recorded in `web-final-frame-current-root-identities-027.json`.
Candidate manifest SHA256:
`58f7587e85b7477d1216d0a51c78023edc7ff705bc94d68a0dfac0558d7ae556`.
The canonical source-map receipt has SHA256
`c18314e19c4699895509dc2e25ae446ab275736d01f9c23e90af3ef64395b3de`.

The evidence root is
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-07-project-web-qwen`.
The preceding .26 continuation delivery and its receipts keep their original
identities in [the continuation contract](ORDINARY-RUNTIME-CONTINUATION.md).

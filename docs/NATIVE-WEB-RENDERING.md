# Native JavaScript web snapshots

## Current 0.42.0 (58) complete captured-text paging

`web.render` adds four optional arguments: `paged` (Boolean, default false), `snapshot_id` (UUID), `byte_offset` (integer 0–1,048,576) and `if_snapshot_sha256` (64 hexadecimal characters). Start with `paged: true` and the existing URL/timeout/inline budget arguments. A continuation requires all three identity/offset fields together with `paged: true`, the same requested URL and the same resolved project/client authorization. Omitted/false `paged` retains the v1 8,192-byte/4,096-node prefix and existing frames.

The complete v2 capture visits at most 65,536 nodes and captures at most 1,048,576 UTF-8 text bytes. Exceeding either limit returns `web_render_snapshot_overflow`; a partial extraction is never published as complete. Title remains bounded separately. `snapshot_complete: true` describes the captured text, not completion of all page work; finite readiness, Lockdown and the unenforced whole-network/DOM/JavaScript-heap limits remain.

Paged results add `snapshot_id`, whole `snapshot_sha256`, `snapshot_complete`, `total_content_bytes`, `byte_offset`, `has_more` and `next_byte_offset`. Existing `content_sha256` and `returned_content_bytes` describe the returned page. Append each page once and continue from the returned cursor; do not advance by the requested size. Offsets must lie on UTF-8 scalar boundaries. At explicit EOF, `has_more` is false and `next_byte_offset` is null; an offset equal to the total permits an empty EOF page. Final encoded fitting counts the actual JSON-RPC ID, both payload copies, required notice and LF, and updates the page cursor/count/digest after trimming. An impossible envelope fails explicitly without a false progress cursor.

WebRendererService retains one immutable Data body of at most 1 MiB plus bounded metadata and one weak-capturing expiry task. The next successful complete capture replaces it; failed, overflowed or cancelled captures do not. The entry expires at its original deadline, at most 120 seconds after publication; continuation does not refresh it or refetch. Foreign/mismatched, replaced or expired identities return `web_render_snapshot_stale`; changed project authorization is rejected at invocation validation. Shutdown cancels/joins the expiry owner and clears the body. The separately corrected invocation-context budget path retains a distinct runtime gate.

The isolated .41 App/CLI baseline observed four truthful truncated missing-suffix results. Matching .42/58 source/native 150 and separate initial G3 one each passed; the weak-owner method is a subset, not general lifetime proof. Ordinary Debug/signature and signed App/CLI functional/limits checks passed complete selected captures through empty EOF under final 65,536-byte frames. Limits v2 passed 241 pages/246 responses per route; the original App limits v1 continuity-200 NONPASS remains retained. The one-body/expiry contract above has scoped source/native coverage, not general page/lifetime qualification. [Receipts and limits](QUALIFICATION-STATUS.md).

Qwen `qwen/qwen3.8-27b` v6 passed the bounded owned-loopback paging flow: six completed responses consumed five actual native results in later turns, including both empty EOFs, reconstructed the 6,144/35,371-byte snapshots and returned the exact four-scalar byte/SHA ACK. All six actual Low input events were complete LF records, ordered and associated by prompt, nonce and tool-result hash. Earlier v2–v5 NONPASS attempts remain retained; v5 outer closure is unknown and the prior CLI pipe-loss mechanism remains unknown. This proves selected result delivery and metadata acknowledgment, not model understanding or new GUI/public-page/all-model/installed operation.

Applied-v2 final source/native G3, hygiene and local link checks passed; final candidate v3 readback preserved source/artifact identities. First owner source/wiki publication, exact readback and clean synchronization passed.

Full web, every model/page, GUI/installed operation, authenticated browsing, Release and shipment remain unqualified. The preceding .39 GUI and .23/.24 contract/ownership records below retain their original scope.

## .39 candidate LM Studio GUI follow-up

In one actual LM Studio 0.4.25+1 GUI chat, Qwen used the existing search/fetch/render tools through a temporary ordinary signed .39/55 candidate integration. A 16,384-byte response budget returned 7,219 bytes of the public URLSession page, and the completed answer used a body statement absent from the earlier search/fetch/8,192-budget snapshot. Both snapshots were truncated and reported JavaScript execution, Lockdown and `boundedStability`; whole-network, DOM and JavaScript-heap limits remained unenforced. The original MCP configuration and chat were restored. [Exact host scope and cleanup](PROJECT-WEB-QWEN.md#qwen-in-lm-studio-gui-public-page-workflow).

This verifies one candidate public-page workflow. Installed operation, all models, authenticated browsing and Forge Tools GUI remain unqualified. The original .23/.24 checkpoint and ownership/runtime records follow unchanged.

## Preceding .23/.24 checkpoint

This checkpoint's source identity is **0.23.0 (33)**, based on synchronized owner-signed
`c391285b00fa4af03eb5210f42f67c3f57e0ffde`. Debug native and Qwen acceptance
passed; Release compilation, signing and the same runtime matrix passed.
The installed application and LM Studio registration remain
separate from these candidates.

## 0.24.0 complete-wire follow-up

After this checkpoint, an exact boundary test reproduced 3,730 stdio bytes
against a 3,729-byte budget. The 0.23.0 final-fit code and recorded protocol
measurements counted the JSON before the terminating LF. Those original
receipts remain unchanged. In **0.24.0 (34)**, final fit uses the actual stdio
encoder, including LF, the real ID, both payload copies and any required notice.
All seventeen renderer service cases passed, including the original boundary.

New signed Debug and Release CLI matrices each passed all 35 cases with 39
correlated responses; both signed app executables passed ten core cases with
14 responses. Measurements include LF. All four parents exited zero with both
EOFs, no forced cleanup, unconsumed replies or response tails. Source, candidate
and installed/registration identities stayed unchanged. The CLI origin totals
matched exactly after fixture shutdown. Actual additive-policy-notice runtime
was not exercised; its exact final-frame behavior has deterministic coverage.
[The listing and wire-budget record](FILESYSTEM-LIST-PAGING.md) retains the
failure, corrected receipts and remaining qualification boundaries.

## Tool contract

`web.render` reads a public HTTP(S) page after native WebKit executes its page
JavaScript. It accepts `url`, optional integer `timeout_sec` (1–30, default 20),
`maximum_bytes` (1–65,536, default 16,384), and the existing `deadline_ms`.
The project must grant the tool and network access. macOS 27+ is required for
this capability; the application's macOS 26 deployment target remains unchanged.
Unsupported hosts receive an explicit error.

Each request uses a fresh nonpersistent Lockdown website store. Its snapshot
contains title, extracted text, final/requested URL, project ID/generation,
returned UTF-8 byte count and SHA256, truncation flags, visited-node count and
readiness. Stability means two equal samples after at least half a second;
continuously changing content can return the finite two-second settle snapshot.
This is not a promise that every page operation finished.

Extraction visits at most 4,096 nodes and returns at most 8,192 UTF-8 text bytes
and 512 title bytes. Successful stdio responses fit the final encoded allowance,
including the terminating LF, actual JSON-RPC ID, duplicated text/structured payload and required
policy notice. Content reduction updates its digest and count. An impossible
envelope produces an explicit error; even that correlated error cannot fit an
allowance smaller than the ID/envelope itself. Other tools' output contracts
are preserved.

`web.fetch` remains the text/source/base64 HTTP tool, and `web.search` remains
public search. Rendering accepts no browser profile, credentials, cookies,
caller-supplied script, permission grants, or interaction instructions. It is
not an authenticated browser or download/action tool. Lockdown restricts site
compatibility. Across one request, provisional main-document admission allows
at most five unique follow-up URLs and rejects a repeated full URI for the same
public navigation identity. This deliberately rejects finite same-URI redirects
that depend on updated cookie/state; repeated URI does not prove an infinite
server loop. Committed hash actions, new documents and ordinary subframes remain
separate. Whole-network request counts are not capped. Remote text remains
untrusted external data.

## Ownership and native process boundary

`ForgeApp` owns one renderer service and closes it during shutdown. The service
admits one active operation and rejects a second as busy; it has no waiting
render queue or persistent browser pool. It launches the current signed CLI or
app in one fixed internal mode before ordinary bootstrap, with empty environment
and private stdin/stdout/stderr pipes. Callers select neither executable,
arguments nor environment.

Parent admission validates its live compiled role and selected CDHash, the named
associated Core artifact, and the unreaped child's exact live identity selected
through a mandatory public audit token. Payload begins only after admission.
The child repeats its own role/Core check before accepting the bounded frame.
The protocol binds request ID, nonce, project and generation; noncanonical,
oversized, trailing and mismatched frames are rejected.

One process owner serializes `waitpid` and signals. A watchdog requests TERM/KILL
within the original deadline; it never signals a reaped or wait-error identity.
Reads distinguish actual EOF, read failure, forced close and truncation. A
successful snapshot requires admitted identity, complete input, normal native
exit, both actual EOFs and an exact valid response. Unconfirmed termination
retains the sole occupied slot until separately confirmed recovery; shutdown
does not create a new grace deadline.

Apple Security validation has no cancellable deadline API. A watchdog request
does not prove a stalled Security call returned or the kernel reaped a child.
Named on-disk Core validation does not attest mapped Core bytes or concurrent
artifact replacement. Whole-network bytes, total DOM size and JavaScript heap
are not capped; the output explicitly reports these limits as unenforced.

## Observed checks and retained failures

The initial affected source selection passed 134 of 135 cases, with one existing
native-fixture skip; the separate MCP/queue selection passed all 62. Both Swift
products built. The canonical Debug workspace build and strict deep signature
verification passed. The initial signed Core selection passed all 78 cases.
These receipts precede the subsequent deadline/redirect corrections and do not
qualify their final candidate.

The initial signed CLI core probe passed ten actual MCP cases: preserved default
fetch, JavaScript text/title and fragment, changing DOM, infinite-script timeout
and subsequent reuse, UTF-8/escaped-ID frame budgets, impossible-envelope error
and two fresh-cookie stores. Its parent exited zero with both EOFs, no output
tail, truncation or forced cleanup. The optional policy-notice path was not
observed in that isolated runtime; the actual-ID/notice serializer has separate
deterministic coverage.

The first probe failed before launching Forge: process-inventory output was
96,133 bytes against a 65,536-byte capture cap. The public `ps -c` executable-name
format produced 34,560 bytes with normal exit and both EOFs, preserving the same
cap and truncation failure. The original failure remains NONPASS.

The initial full matrix returned an explicit redirect-limit error after seven
owned-origin requests, exceeding the intended initial-plus-five bound. Its
ordinary redirect case passed; the whole matrix remains NONPASS.
A separate public native trace preserved the five-redirect chain and blocked
the sixth unique-URL redirect through action policy, but the same-URL loop
still issued seven requests because only two action callbacks occurred. The
action-only hypothesis is disproved for that loop. Upstream
[WebKit policy source](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/loader/PolicyChecker.cpp)
contains an equal-request policy bypass; that source supports an explanation,
not an attestation of this host’s WebKit binary. Repeated-URL policy and ordinary
document/fragment navigation required their own acceptance. The revised external
fixture executed 11 notification baselines and 11 conservative-policy cases.
Both baseline and policy gates passed: the five-redirect chain rendered, the
sixth unique redirect stopped before follow, and one-, two-, and three-URI
cycles stopped before the repeat. Document returns, reloads, ordinary frames
and fragment routing rendered. The finite same-URI cookie redirect rendered
under baseline and was deliberately rejected under the new policy. All 22
fixture processes exited zero with both EOFs; weak view/store release was
observed in each fixture. These are external native controls, not production
MCP or general leak-freedom proof.

Two project-contention regressions reproduced responses near two seconds for
0.1-second and already-expired requests. The new budget lookup and existing
notice/deadline-response lookups created independent wait controls. The first
token-only correction still failed because the later notice lookup waited.
Request control is now required through every tool and deadline response route.
The final MCP/deadline selection executed all 35 tests with no skips or failures;
the native MCP class and deadline cases also passed in the 130-case compiled
selection. A compiler failure caught
the additional desktop-attachment deadline branch before any tests ran; its
missing control argument was corrected without weakening the required signature.

Exact logs, source/artifact hashes, protocol transcripts and terminal receipts
are retained in the owner's external
`Forge-Conductor-Evidence/2026-10-07-project-web-qwen` directory. Earlier
[binary-web](BINARY-WEB-AND-QWEN-FILES.md),
[inventory](RUNTIME-INVENTORY.md), and
[project/web](PROJECT-WEB-QWEN.md) records retain their tested identities.

## Corrected candidate acceptance

The final affected source selection executed 199 cases: 198 passed and one
existing native-fixture case skipped. It selected no current-version case because
that appended method name was incorrect; that is not version evidence. The
actual current-version method passed in the separate compiled selection and a
fresh one-case source run. Across those source selections, 200 distinct cases
were selected, 199 passed and one existing native fixture skipped. The
final descriptor's 15 catalog cases and the corrected 16 service cases passed
separately; repeated cases are not added to the distinct total.

The corrected canonical Debug build and strict deep signature passed. The
compiled selection executed all 130 requested cases with no skips or failures,
including both contention regressions and the actual current-version method.
Its four compiler-warning lines concerned two new service-test tasks capturing
XCTest self. Constructing their value requests before the tasks preserved every
assertion; all 16 service cases then passed in source and fresh compiled runs
without warnings. Two original audit-drain QoS warnings remain in the 130-case
receipt: one follows the timed response assertion during an audit-flush check,
and the other occurs in test teardown. Inspected GUI drain callers detach work;
these traces do not demonstrate a live UI inversion. Manager worker-drain timing
remains a measurement target.

The final signed CLI MCP matrix passed all 35 cases. It includes five permitted
unique redirects, rejection of the sixth and first repeated URI, the explicit
finite-cookie limitation, document/reload/frame/fragment parity, download/dialog/
popup/file controls, fresh-cookie and authentication exclusions, busy/cancel/
reuse, public system TLS and a rejected owned self-signed handshake. Origin totals
were rechecked after confirmed shutdown. All 39 responses were consumed; the
parent exited zero with both actual EOFs, no pending/tail/truncation or forced
cleanup. The signed app executable independently passed the ten core cases,
with all 14 responses consumed and the same normal shutdown requirements.

Qwen 3.8 selected the actual native descriptor, executed one renderer call,
consumed `FORGE_JS_OK hash=#forge-ready`, its title, final fragment, Lockdown mode,
readiness and explicit unenforced-resource booleans, then stopped normally.
Both real model requests had the observed Low template. Its native parent exited
zero with both EOFs and all five responses consumed; the owned log observer
joined normally. This is LM Studio API consumption, separate from the original
GUI chat and installed product.

Release compilation passed without compiler warnings. Strict deep signing and
the helper's existing Developer ID/hardened-runtime identity passed. Release
runtime also passed all 35 MCP cases with all 39 responses consumed, normal
zero exit/both EOFs and exact post-shutdown origin totals. Its app executable
passed the same ten core cases with 14 responses consumed and normal zero exit/EOF.
Debug's seven artifact inputs and Release's
five native binaries have separate SHA256 manifests. Test-only fixture edits
followed the Debug build; its production inputs and binary identities did not
change. Installed executables, LM Studio registration and earlier candidates
remained unchanged throughout the recorded gates. Signed Debug/Release CLI and app
executables also rejected malformed fixed-mode extra arguments with expected
exit 2 and both EOFs in all four cases. Both Swift products built successfully
against the final inputs.

## Open acceptance boundaries

Debug/Release runtime and Debug Qwen acceptance passed. Intel, macOS 26 JavaScript, installed/MCP deployment, `.pkg`, notarization,
shipment, all-model/site acceptance and authenticated browser workflows are not
qualified by the preceding checks. Broader OS-prompt denial, process attribution
and leak freedom require their own runtime proof. The attached historical
capability audit is feedback, not dispatch or a replacement for owner instructions.

# Binary web fetching and Qwen file workflows

Current source is **0.22.0 (32)**, starting from synchronized owner-signed
`3b2b0caa4eab1eaab7d73a1c20d48863d745edbc`. The working installation remains
**0.18.0 (28)**. Candidate, source and installed evidence retain separate scopes.

## Binary web contract

The signed 0.21.0 candidate reproduced the missing capability with a local HTTP
fixture serving 38,144 bytes, containing every byte value. Default `web.fetch`
returned `web_unsupported_content`; requesting `format: "base64"` returned
`web_invalid_argument` before a second request reached the origin. Its owned
native process exited zero with both EOFs and no forced cleanup. This is an
observed unsupported path, not an assertion that text fetching was broken.

`WebToolPack` now accepts optional `format: "base64"` for original response bytes
of any MIME type. Each returned `content` page is independently padded base64.
Decode each page separately and append its bytes. `byte_offset`,
`returned_content_bytes`, `total_content_bytes` and `next_byte_offset` describe
decoded bytes; `content_sha256` hashes the entire response body. A continued
request fetches the URL again and rejects changed content when supplied with
`if_content_sha256`. Arbitrary byte offsets are valid in binary mode.

Text remains the default. Existing text/source UTF-8 boundary checks, HTML
metadata, search parsing and HTTP failure behavior remain. Network/tool grants,
ephemeral native sessions, credential/cookie exclusion, the 1 MiB receive cap,
five-redirect cap and 1–30 second request timeout remain in force. Binary mode
uses the existing encoded MCP/project result budget, with positive cursor
progress or an explicit small-budget error. This adds binary transport; it does
not execute JavaScript or provide an authenticated browser session.

## Current-version repair

The existing `G1G10AcceptanceTests/testG3_VersionAndReleaseDocumentsAreAligned`
executed once against 0.21.0 and failed eight assertions: expected version/build
still named 0.18.0/28, and six document markers were stale or absent. The failing
receipt is retained. The repair updates expected current identity, current
document markers and all version authorities together. Every assertion remains;
historical qualification records keep their actual tested versions.

## Qwen-authored file examples — signed 0.21.0 scope

Qwen used actual Forge descriptors through LM Studio's supported API, in isolated
projects/homes. It wrote inspected, bounded standard-library Python source and
ran one native job per artifact. Evidence utilities independently read the entire
artifact through base64 pages, copied it byte-for-byte and verified the digest.
Qwen then consumed actual terminal status, both output streams and bounded binary
windows. These are example workflows through native jobs, not new Python product
components or claims about every rich file format.

| Example | Observed native/transport proof | Model completion |
| --- | --- | --- |
| PNG | 128×96 RGB synthetic gradient; 37,028 bytes. PNG chunks/CRCs and every decoded pixel matched; native `sips` dimensions/BMP decode passed. Two file pages reconstructed the exact body. | Author and consumer each ended `tool_calls` → `stop` in PNG r5. |
| WAV | One second, 8 kHz mono, signed 16-bit PCM 440 Hz tone; 16,044 bytes. All 8,000 samples matched; `afinfo`/`afconvert` passed and converted PCM matched exactly. | Author and consumer each ended `tool_calls` → `stop` in WAV r4. |
| DOCX | 1,675-byte minimal ZIP containing content types, relationships and document XML; bold title and two-column/two-row table verified. ZIP/XML checks and native `textutil` text import passed. | Original r3 consumer ended in a harness rejection of a legitimate extra read. Separate read-only r4 completed the pending reads and ended `stop`, using the existing file/job without author replay. |

All completed native sessions exited zero with both EOFs, no output truncation
and no forced termination. Candidate/source inputs and protected installed files
and registration remained unchanged. The original DOCX r3 receipt stays NONPASS;
its native author/format proof and the separate model completion are not merged
into a fabricated single successful run. Earlier socket timeout, parent-directed
cancel, final-token exhaustion and source/window harness rejections are retained.

Per-request Low reasoning was admitted by installed LM Studio 0.4.25+1 and
observed in its actual input templates. This is request-scoped evidence, not a
persistent setting change or a guarantee about other models. The official
[0.4.8 changelog](https://lmstudio.ai/changelog/lmstudio/lmstudio-v0.4.8)
documents the added OpenAI-compatible reasoning control.

The PNG proves synthetic raster authoring, not photographic generation or vision.
The WAV proves PCM tone authoring, not speech recognition, TTS or music synthesis.
The DOCX proves minimal structure and native text import, not Word layout/rendering
or complete Office support. Other requested format families remain open.

## Original active LM Studio chat

The existing `get_forge_status Th` chat, using Qwen 3.8, returned bounded feedback
through public native Accessibility. Its response identified no current blocked
web task, exact failing URL, JavaScript/login/form/download failure or new
observed defect. Its prior handoff reference was labelled a proposal. The UI
reported `EOS Token Found`; no new tools were called for this feedback. The
empty composer was preserved, no new chat/settings were created, and installed
0.18.0 binaries and `mcp.json` hashes matched before/after. This feedback does not
qualify tools that exist only in the newer signed candidates.

## Verification and identities

| Check | Actual result |
| --- | --- |
| Source web | All sixteen cases passed; the separate initial narrow run also passed sixteen. |
| Other affected source | Nine deadline and fourteen catalog cases, the exact version regression and CLI help/version/status contract each passed. Total distinct affected coverage: 41, zero failures/skips. An initially mistyped catalog selector selected only web/deadline (25); the actual catalog class then executed fourteen separately. |
| Signed-native XCTest | Canonical workspace/scheme executed all sixteen web cases and the exact version regression: 17 passed, zero failures/skips, terminal zero. |
| Products/candidate | Both Swift products built; fresh canonical ordinary Debug reached `BUILD SUCCEEDED` and terminal zero. Strict deep signature verification passed; candidate Info.plist and actual helper `--version` report 0.22.0/32. |
| Native HTTP before/after | The identical 38,144-byte fixture reconstructed exactly in 41 pages. SHA256 `0f8efa79aacb021e8229c9ba4d370a0a354e8b056b0d60d581dbe55118015afe`, changed-digest rejection and retained default binary error passed. Origin observed 43 requests without credentials/cookies. Native exit zero/both EOFs/no truncation or forced cleanup. |
| Qwen binary web | Actual descriptors produced `tool_calls` → `tool_calls` → `stop`: offset 0 returned 933 decoded bytes, offset 933 returned 924, next cursor 1,857. Both windows independently matched the fixture and whole-body digest. Only two pages were exposed to the model; native networking received the complete body on each of the two requests. Its original paragraph's approximate remaining-byte count was one byte high, retained as a prose error rather than attributed to transport. |
| Identity/graph | All 436 source inputs stayed unchanged across each executed source/build/native check. Four changed Swift inputs retain their correct target memberships; PBX changes are twelve marketing and sixteen build settings only. Seven candidate files and protected installed app/helper/registration hashes matched through the model run. |
| Hygiene | Repository hygiene and whitespace checks passed. |

A separately labelled read-only Qwen correction ended with `stop` and corrected
the remainder to 36,287 bytes. It explicitly distinguished the model's 1,857-byte
page consumption from native full-body reception. No tools, native session, author
job or source operation was replayed; the original paragraph remains unchanged.

The current Debug log retains the pre-existing
`ExecutionJobService.swift:222` non-Sendable-function conversion warning; the
0.21.0 build has the same warning. A successful build does not erase it or prove
runtime races. No new source changes were made during candidate/model checks.
The full application suite, Release/Intel matrix, current GUI controls,
installation and shipment were not exercised in this binary-web slice.

Final candidate helper SHA256 is
`5eea21e236a0dc663725916befa80605cc74b45a583ae0c7e46c6916309349a4`;
Core SHA256 is
`2f3ccea0f709cb1874b9c81a6b4ba9a8c0ddfbf4a149a22dd845c68676cbfec7`.
The preceding seven-file 0.21.0 candidate manifest remained unchanged.

The external evidence directory is
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-07-project-web-qwen`.
Relevant retained receipts include `native-web-binary-021-baseline/summary.json`,
`version-alignment-021-baseline-terminal.json`, `native-web-binary-022/summary.json`,
`qwen-binary-web-022-r1/summary.json`, its separate `r1-correction/summary.json`,
`binary-web-native-candidate-022.json`,
the `binary-web-*` command logs/terminal/input receipts, `rich-file-final-receipt.json`,
`rich-file-disposition.md`, `qwen-active-web-feedback-receipt.json` and the named
PNG/WAV/DOCX case directories. Source/wiki publication identities are recorded
externally after remote readback, avoiding self-referential commit edits.

## Remaining web gates

Production JavaScript rendering and bounded parent/child IPC remain open. External
macOS 27 fixtures separately verified visible-window file-picker cancellation,
Lockdown-mode API restrictions and inline geolocation denial; those fixtures are
not production tool acceptance. macOS 26 permission behavior, whole WebKit
heap/DOM/network byte limits and authenticated browsing remain unqualified.
The renderer investigation retains detailed failures and scope in
[runtime inventory](RUNTIME-INVENTORY.md). Installation, shipment and all-feature
acceptance remain separate owner gates.

Later **0.23.0 (33)** adds a separate native JavaScript snapshot tool. Its
[renderer record](NATIVE-WEB-RENDERING.md) retains the new contract and runtime
proof; the 0.22.0 receipts below keep their original binary-HTTP scope.

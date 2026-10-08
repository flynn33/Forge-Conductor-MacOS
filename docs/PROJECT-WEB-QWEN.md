# Project repository, web access and Qwen verification

The **0.26.2 (38)** notice-receipt follow-up preserves project, web and model
features. EOF-skipped or incomplete notice packets are not marked presented.
The 92 source and same 92 native methods passed on their original 450-input map;
a later test-only priority correction passed the same one source/native case.
CLI/app, version/graph, final ordinary Debug build and strict signing passed.
Native diagnostics remain. This does not close
the preceding .26.1 Qwen final-report NONPASS, installed acceptance
or full-web gates. [Current receipt contract](WEB-RESPONSE-BUDGET.md#notice-receipt-truth-follow-up).

The **0.26.1 (37)** response-budget follow-up preserves these tools and the
historical qualification below. Its signed .26 baseline observed escaped-ID
frames exceeding 2,048 bytes. The final 139 source and same 139 compiled native
cases passed, followed by ordinary Debug build/strict signing and four repeated
signed wire cases within the allowance. Native diagnostics remain; hotfix Qwen
completion is OPEN/NONPASS. Older qualification below keeps its identity.
[Current fetch/search budget contract](WEB-RESPONSE-BUDGET.md).

The October 7 owner request authorizes project-linked GitHub entry, web access
through Forge, and collaboration with Qwen on real failures and additions.
This checkpoint's source is **0.19.0 (29)**, based on synchronized
`37f0a800d6c5f6ad870decbb8d62025128166e91`. The installed app is **0.18.0 (28)**.
Candidate and installed/runtime qualification remain separate.

The 43 intended source/document paths were published as owner-authored,
GitHub-signed commit `a14a63de92d26cfd16fd196601033570e682ba7a`. Remote blobs
matched the intended hashes; local `main` was safely synchronized with zero
divergence and a clean tree. Installed GUI/CLI and LM Studio MCP registration
SHA256 identities matched the pre-work baseline. Later changes have their own
[follow-up record](QWEN-FOLLOWUP.md); these receipts keep their tested identity.
The matching wiki was published on its canonical `master` as
`0cbb6742c6948a001e5b3cb0395d4a03e80ddcee`; local/tracking/remote refs matched,
divergence was zero and the tree clean. Its whitespace and 207 internal
link/anchor checks passed. No source graph changed during wiki publication.

## Observed baseline

The active LM Studio chat uses `qwen/qwen3.8-27b` and the installed Forge integration.
Qwen's shell curl read of `https://example.com` returned HTTP 200, exit zero and
no timeout. Its direct PowerShell process job returned exit 134 with complete
stdout/stderr pages and `System.IO.FileLoadException`. A direct host launch
reproduced that exception. Empty isolated PowerShell startup-cache directories
succeeded; copying the original cache into that isolation reproduced the crash.
This identifies the cache-triggered startup failure, not an installed DLL failure.

The supplied `forge-capabilities-and-file-limits.md` is a capability audit. Its
policy statements are observations from its Jamf-Technician session, not new
instructions for this repository. Size/concurrency/project isolation boundaries
remain required. A missing convenience tool is not proof its shell-accessible
operation is unavailable.

## Implemented contract

- Projects saves an optional canonical `github_repository_url` on the stable
  project. GitHub HTTPS and SSH clone forms normalize to HTTPS; embedded
  credentials, foreign hosts, query/fragment and malformed repository paths are
  refused. Save/Clear use the existing authenticated Manager and expected project
  generation. Inferred Git identity and project isolation are unchanged.
- `web.fetch` reads HTTP(S) text/source with native ephemeral networking;
  `web.search` returns public DuckDuckGo HTML titles/URLs/snippets. Network grants,
  receive/output limits, timeout, redirect and cancellation fences apply. Remote
  content is data. Browser challenges, HTTP errors and oversized responses are
  explicit errors; JavaScript and authenticated browser sessions are not provided.
  Fetch pages use `next_byte_offset` and `if_content_sha256`; content changes
  produce `web_content_changed`. Ordinary unrestricted MCP bindings migrate their
  network grant; leased, run-bound and explicitly restricted grants retain their
  existing policy.
- `fs_read`/`fs_write` accept optional `encoding: base64`; the UTF-8 default and
  existing pinned mutation boundary remain. Binary reads use zero-based
  `byte_offset` and `maximum_bytes` (default 16 KiB, maximum 32 KiB), including
  `next_byte_offset`/`has_more`. Writes require canonical padded base64 and at most
  2 MiB decoded bytes. This transports arbitrary bytes; it does not itself
  synthesize photographic images, Office documents, audio, video or fonts.
- `search_text` accepts `context_lines` (0–20), `include` and `exclude` filename
  glob arrays (at most 32, 256 bytes each). Existing `.git`/`node_modules`
  exclusions remain. `git_diff` accepts `file` as a pathspec separated from Git
  options and now reports stdout/stderr truncation.

## Verification and retained evidence

Logs, candidate paths, source/binary identities and host-repair evidence are retained under
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-07-project-web-qwen`.
The canonical workspace keeps its existing project and adds only WebToolPack and
its test source memberships; existing project/file/search/UI-test memberships remain.

| Evidence | Executed result and scope |
| --- | --- |
| Focused source regressions | Initial 25 feature tests passed. Subsequent final web selection passed 8, binary/version selection passed 15, and the last base64 type-rejection edit passed its exact 1 test. Logs are `root-tool-tests.log`, `feature-focused-tests.log`, `web-final-source-tests.log`, `binary-version-final-tests.log` and `base64-type-final-test.log`. |
| Affected source classes | 404 selected: 402 passed, zero failures, two explicit skips. The external-lock-holder case is a helper selected by its parent tests. The live-provider case was then executed separately with `FORGE_LIVE_LMSTUDIO_MODEL=qwen/qwen3.8-27b`: 1 pass, zero skips. Final web/binary edits received the affected reruns above. |
| Builds and signing | Both declared Swift products built successfully. Ordinary canonical workspace Debug build succeeded with the configured Apple Development identity. `codesign --verify --deep --strict` passed. Test output is in a separate `native-tests` directory. No Release/archive/notarization or installation claim. |
| App-hosted Projects | `ForgeConductorAppTests/ProjectsViewModelResetTests` executed both new repository methods: 2 passes, zero failures/skips; `projects-app-tests.xcresult`. Captured-selection, refresh persistence, clear, invalid URL and stale-generation behavior are exercised. |
| Signed native Core | `native-feature-tests.xcresult` executed 18 cases with zero failures/skips. The first selector did not execute the four registry methods or two binary-budget methods; the corrected exact selection executed 6 more passes with zero failures/skips in `native-registry-budget-tests.xcresult`. A zero-selected suite receives no pass credit. |
| Production HTTP transport | Signed candidate stdio passed 5/5 cases: successful redirect, cycle stopped after six requests, credential redirect target never fetched, receive limit, stable paging and changed-content rejection. `native-web-fixtures/summary.json` records clean exit zero, both EOFs, no forced cleanup/truncation, unchanged inputs and binary. |
| Signed file/search/Git transport | 6/6 cases passed, including an 8,217-byte arbitrary-byte roundtrip and complete 3 MiB reconstruction over 135 bounded pages with matching SHA256. Default text errors, numeric base64 rejection, context/filter exclusions and dash-prefixed Git path filtering passed. `native-file-search-git/summary.json` records clean native shutdown and identities. |
| Actual Qwen web use | `qwen-native-web/summary.json`: `qwen/qwen3.8-27b` emitted both canonical tool calls through LM Studio's supported API, consumed successful signed-candidate responses, and finished with `stop`. It reported “Example Domain” and Apple's URLSession documentation URL. Candidate CLI SHA256 is `68fc5436647df0dd244188103d9462eb39b4c8217e057b10ce2da1d061c64c18`; source/binary unchanged and native shutdown clean. This API-owned model exchange is separate from the active desktop chat. |

At this 0.19.0 checkpoint, native Projects click-through remained **unverified**. CUA first read the exact
0.19.0 candidate's Dashboard, then twice returned `Sky Computer Use native pipe
closed before response`. The candidate remained alive and its owned process was
stopped with SIGTERM. The new ordinary-bootstrap UI test compiled, but Xcode
exited 65 because its runner timed out enabling automation mode; **zero UI tests
executed** (`projects-ui-tests.xcresult`). Save/relaunch/invalid/clear native
screenshots and ordinary GUI shutdown therefore had no pass credit. The test
and protections remain intact.

The later signed 0.20.0 candidate passed six ordinary Projects flows through
public Accessibility, including exact repository Open in Safari and reviewed
native screenshots. Both launches ended through ordinary Quit with exit zero.
That acceptance is recorded in [the Qwen follow-up](QWEN-FOLLOWUP.md); it does
not change the failed 0.19.0 runner receipt or claim installed deployment.

The installed PowerShell repair is **E0 observed runtime proof**. Only the corrupt
startup-cache file was archived and moved to a recoverable same-directory backup;
PowerShell binaries and credentials were unchanged. Three direct default-cache
launches passed. In the active desktop Qwen chat, installed Forge
`runtime.capabilities` reported PowerShell available and `powershell.run` returned
`7.6.6`, exit zero, complete untruncated stdout/stderr with producer EOF. The exact
job is `91dcf79a-3c23-4cb7-94a8-5be02b630c27`, retained in
`powershell-cache/qwen-powershell-job.json`. Cache regeneration passed; a permanent
upstream prevention fix is not claimed.

## Requested work that remains open

Qwen's broad wishlist remains work to investigate: GitHub API operations,
vision/image understanding, semantic navigation, multi-project sessions, parallel
model agents, persistent terminals, containers/database convenience tools,
browser automation, CI, file watching, secret/notification/scheduling tools,
audio/media generation, undo/pipeline/memory enhancements and richer format
writers. Binary transport alone does not close these requests. Existing shell
and durable jobs may supply some operations; each needs capability and runtime
proof before being labeled absent or complete.

CLU native-task identity and external context usage require supported host
boundaries. Shared MCP cannot invent a task or model context usage. Unqualified
CLU receipts are not independent crash/failure proofs. Ordinary GUI rollover,
crash recovery, all-feature acceptance and shipment remain separate gates.

The read-only wishlist audit is retained as `qwen-wishlist-disposition.md`. Two
next repairs have native reproducers in `native-expiry-output-r2`: expired memory
is still returned and malformed expiry strings are accepted; running stdout and
stderr spools contain bytes while `job.read_output` reports
`runtime_output_unavailable`. Terminal output remains complete. These are open
findings, not repairs in this checkpoint. Qwen's structured page title/heading
suggestion is also recorded for a later tested change.

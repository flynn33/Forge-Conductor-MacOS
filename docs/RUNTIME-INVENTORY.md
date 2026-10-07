# Optional runtime inventory and native web investigation

Current source is **0.21.0 (31)**, beginning from safely synchronized,
owner-signed `52152bd56213372793d98d6e2800ac4c638eba15`. The working installation
remains **0.18.0 (28)**. The preceding [Qwen follow-up](QWEN-FOLLOWUP.md)
retains its own tested source, candidate and model receipts.

## Capability contract

The supplied capability audit describes the old installed tool set. It is
feedback, not dispatch authority. Its unavailable-PowerShell claim was disproved
after the reversible startup-cache repair; its text-only writer limitation was
addressed by the preceding base64 transport. Rich-format authoring still requires
its own executable workflow evidence. An executable or package file existing
does not prove that workflow works.

`RuntimeCapabilityDiscoverer` adds a fixed filesystem snapshot to the cached
`RuntimeCapabilities` value. It introduces no child probes, imports, hooks,
refresh timers or recursive walks. The existing direct-process, zsh, bash,
Python and PowerShell gates and `RuntimeRequirementResolver` remain authoritative
for execution. Manager runtime projection preserves its established fields.

The inventory searches at most 32 whole absolute PATH components from a bounded
16 KiB prefix, then six fixed standard locations. Candidate/canonical paths are
bounded by the native path limit; invalid or inaccessible observations are
unknown rather than missing. It contains thirteen fixed executable IDs: git,
gh, brew, node, npm, sqlite3, docker, podman, dot, mmdc, sips, afconvert and ffmpeg.
Rows report scoped `presence`, canonical `executable_path`, executable permission,
`probe_state: "not_run"` and `workflow_verified: false`.

Eight Python rows inspect exact package assets only within the successfully
selected supported Python framework layout: sqlite3, pip, Pillow, python-docx,
openpyxl, python-pptx, numpy and matplotlib. Filesystem asset observations have
`import_verified: false`. Unsupported layouts, unavailable parent runtimes and
access errors retain unknown results. No package import is performed.

`version: 1`, `captured_at`, search scopes, completeness and
`refresh_policy: "service_restart"` describe the evidence. Legacy Codable
capability records decode with no inventory. Existing initializers and core
MCP fields remain available. The complete duplicated text/structured result is
sized against the project allowance, capped by the existing 64 KiB result bound.
Inventory omission preserves the core result; if only the exact legacy core
fits, its omission marker is also absent. An oversized core returns an explicit
error. Caller correlation IDs are transport metadata outside that
informational result bound. An additive policy-notice content block is also
outside this no-notice result sizing. Legacy stdio admission accepts IDs within
its larger request envelope; this work does not change ID admission or claim a
universal 64 KiB transport frame bound. Strict HTTP admission has its separate
ID limits. These finite filesystem observations run in the existing background
startup worker; hostile network mounts and filesystem wall-clock deadlines have
not been qualified.

## Verification

| Check | Actual result |
| --- | --- |
| Focused inventory regressions | Twelve selected, twelve passed, zero skips/failures. The first run's oversized-path fixture failed; it used a path beyond this Mac's native 1,023-byte bound. The corrected fixture retains the omission assertion and the failed receipt. |
| Normal affected source selection | `RuntimeExecutionJobTests`, `ProviderRuntimePreparationTests`, `ToolDefinitionCatalogTests` and `ProductPathReliabilityTests`: 201 selected, 198 passed, three explicit skips, zero failures; terminal exit zero. All 143 runtime cases passed. |
| Live-provider readiness | The skipped exact LM Studio preparation method subsequently executed and passed with `qwen/qwen3.8-27b`; one selected, no skips/failures, terminal zero. The normal run's original count remains unchanged. |
| Declared CLI and app | Both direct `swift build --product` commands exited zero. |
| Canonical ordinary Debug | Workspace `xcodebuild` reached BUILD SUCCEEDED and terminal zero. Strict deep code-signature verification passed. Version 0.21.0 (31). |
| Signed native regressions | The same twelve inventory methods executed and passed; no skips/failures, terminal zero, TEST SUCCEEDED. Ordinary candidate and test products use separate directories. |
| Actual Qwen inventory | `qwen/qwen3.8-27b` called the canonical tool, consumed all thirteen executable and eight package rows, reported scoped presence and unverified workflows, and finished `tool_calls`, then `stop`. Repeated native reads were identical; native exit zero/full EOF, no forced cleanup or truncation. |

All five affected source/test files were verified in the correct canonical target
Sources phases. Normalized PBX content matches the preceding graph exactly;
only twelve marketing settings and sixteen build settings change. Source/resource/
test snapshots contain 436 inputs and remained unchanged through every recorded
root build/test command. `inventory-membership.json` and
`inventory-native-candidate.json` retain graph and artifact identities.

The first model harness rejected the valid
optional `deadline_ms: 30000` argument; the actual descriptor permits 1–60,000.
The second reached the real inventory but ended with `finish_reason: "length"`
under its 900-token allowance. Both remain NONPASS. Neither changed product
inputs; each native process exited zero with full EOF and no forced cleanup.
The corrected third exchange completed under a bounded 3,000-token allowance.
Its source/helper/Core and protected installed/registration identities remained
unchanged. The model's rich-format paragraph is not evidence that no rich-format
workflow is possible; filesystem rows establish neither general ability nor
general inability.

Final candidate helper SHA-256 is
`fbebd0f0bc7a273f803d61599bc81194ca76936dc39a93e810d0b974d1870335`;
Core SHA-256 is
`59e69f7a57d8549f07fa6a6f7cdec8b88b66b695439c1be0439ebceeb2c216f0`.
Root command logs/terminal receipts use `inventory-affected-source-tests`,
`inventory-live-provider-test`, `inventory-cli-build`, `inventory-app-build`,
`inventory-native-debug-build`, `inventory-native-signing` and
`inventory-native-tests.{log,xcresult}`. The accepted model receipt is
`qwen-native-inventory-021-r3`; earlier two retain their failure dispositions.
Repository hygiene and whitespace checks passed. No installation or LM Studio
registration change was performed.

The two remaining normal-run skips require prepared same-version and Debug/Release
native-bundle identity fixtures for this new version. Earlier 0.20.0 peer results
retain their actual inputs. Installed acceptance, general optional workflows,
package imports and hostile-mount timing remain unverified.

## Native JavaScript investigation — E0, external fixture only

The published text/source fetch deliberately reports `javascript_executed: false`.
A separate native AppKit/WebKit fixture rendered the same page's own script in
a fresh nonpersistent store. The current MCP entry thread blocks while reading
stdin; direct MainActor WebKit integration there has no established event loop.
A separate owned native mode is being investigated before product integration.

The proxy experiment disproved universal interception on this host: with a
refusing per-store HTTP CONNECT proxy and failover disabled, the localhost page
loaded directly, the origin observed one request and the proxy observed zero
connections. Public HTTPS attempted the proxy and failed. Configured and readback
exclusions differed in explicit-match cases; the internal cause is unknown.
CONNECT also cannot count encrypted logical HTTPS body/request bytes. No system
proxy, browser profile, TLS protection, installed application or LM Studio
registration changed.

The first extended fixture produced the asynchronous DOM marker with normal
process/pipe completion, but failed view/store-release acceptance. Public metadata
then identified a hidden framework window that was not attached to the render
view. Explicit autorelease pools corrected the view lifetime in the same flow;
the fixture did not close hidden windows to mask ownership. Failed receipts remain.

The fourth fixture completed nineteen cases with one response each, terminal
zero and full untruncated EOF: asynchronous and continuously changing DOM,
infinite JavaScript deadline/cancellation, slow resources, redirect bounds,
three dialog callbacks, popup prevention, download denial, native file-navigation
denial, oversized UTF-8 text, repeated requests and valid/invalid system TLS.
All nineteen view weak references released; seventeen stores released. Two
infinite-script stores remained alive through about 1.09 seconds of cleanup
observation, then their helpers exited normally. Newly observed WebKit PIDs were
absent after helper exit; global process listings do not establish every ownership
edge or a general leak proof.

Permission and file-picker attempts never reached their denial callbacks and
remain inconclusive. Public geolocation denial is macOS 27+, while the product
targets 26. Extraction bounds do not cap the complete DOM, JavaScript heap,
decoded bodies or all network traffic. Signed IPC and product integration remain
under investigation. No production JavaScript tool or authenticated session is
claimed.

Evidence is retained outside the repository under
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-07-project-web-qwen`:
`native-webkit-proxy-020`, retained failed render attempts,
`native-webkit-render-020-r4`, and
`proxy-contract-sdk27-audit`. The broader requested capability families,
installed acceptance and ordinary external-chat continuity remain open.

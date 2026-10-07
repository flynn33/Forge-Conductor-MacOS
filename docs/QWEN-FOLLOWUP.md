# Qwen feedback: expiry, running output and page metadata

This checkpoint's source is **0.20.0 (30)**. This local-first change starts from synchronized
owner-signed `a14a63de92d26cfd16fd196601033570e682ba7a`. The working installation is
still **0.18.0 (28)**. The [preceding feature checkpoint](PROJECT-WEB-QWEN.md)
retains its own tested inputs, model exchange and PowerShell host repair.
The subsequent [runtime inventory work](RUNTIME-INVENTORY.md) has its own
identity and qualification record; these receipts retain their original inputs.

## Observed starting behavior — E0

The signed 0.19.0 candidate accepted expired and malformed `expires_at` values;
get, recent and search returned the expired record. A separate real shell job
had 13 captured bytes in each spool while running, yet both `job.read_output`
calls returned `runtime_output_unavailable`. After completion both full streams
were available. These are missing query/read capabilities, not observed data
loss. Exact schemas, synthetic records, byte/hash receipts and clean exit/EOF
are retained in `native-expiry-output-r2` under the October 7 evidence directory.

Qwen used the real web tools through LM Studio's supported API and requested a
structured HTML title/heading after consuming a concatenated page body. Its
original successful exchange remains in `qwen-native-web`.

## Change and compatibility

`ProjectMemoryRepository.get/recent/search` now filter valid expired timestamps
in SQLite before page selection, using one captured clock per query. New writes,
batches and default strict imports validate and normalize bounded RFC 3339 timestamps. Explicit
`include_expired: true` preserves historical inspection; exports and status counts
include retained expired rows. Existing malformed timestamps remain visible and
non-expiring and are exported unchanged. Import-only
`expiry_policy: "preserve_legacy_v1"` preserves malformed legacy expiry strings,
including empty and embedded-NUL values. Valid timestamps still normalize;
checksum, project scope, types, transactions and cancellation checks remain.
Preserved expiry bytes count toward the existing 1 MiB batch bound. Strict
remember writes remain strict. The expiry-specific SQLite reader/binder uses
explicit byte counts so an embedded NUL is preserved rather than truncated.
Deduplication does not renew expiry. No deletion, schema migration or recurring
cleanup is added. See [project-memory contracts](PROJECT-MEMORY.md).

Current memory cursors use scoped ordered coordinates: timestamp/ID for recent
and rank/timestamp/ID for search. Expiration of preceding rows between pages no
longer shifts continuation past live records. Legacy v1 offset cursors remain
accepted with their prior semantics. Full page-payload sizing includes the new
cursor and query metadata and rejects a single row that cannot fit.

`ExecutionJobService.readOutput` can read an exact owned queued, running or
cancelling job through `RuntimeOutputSpool.snapshot`. A snapshot verifies the
retained artifact identity and digest under the existing producer lock, uses
positioned reads and does not finalize the writer or its incremental hash.
`is_snapshot`, `sha256_is_provisional`, `job_state` and `producer_eof` are additive.
`eof` still means the end of retained byte pages; snapshots can receive later
bytes. Pending ownership uses the existing unavailable code with `retryable: true`.
Terminal artifact verification, exact context authorization and byte/base64
paging remain in place.

`WebToolPack` adds optional HTML `title` and first `heading` fields, each at most
512 UTF-8 bytes. Exact tag names, quote-aware scalar delimiters and raw-text
exclusion prevent fake metadata from attributes, scripts and lookalike tags.
Metadata is omitted when it would displace a readable body page. Existing body
content and hashes, text/source formats and continuation fields remain unchanged.
These fields do not execute JavaScript or create an authenticated browser session.

The ordinary Projects UI exposed a misleading error heading: invalid repository
input displayed "Manager state unavailable" while Manager was healthy. Projects
now uses "Project request failed" for that banner; the shared banner retains its
existing default for other callers and its accessibility identifier.

All modified sources/tests retain their existing canonical workspace memberships.
The Xcode project diff changes version settings only; signing and target graph
are preserved. Runtime constants, `VERSION`, `BUILD_NUMBER`, 12 marketing settings
and 16 build settings agree at 0.20.0 (30). Ordinary candidate and test products
use separate output directories.

## Executed verification

Evidence root:
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-07-project-web-qwen`.

| Check | Actual result |
| --- | --- |
| Focused new cases | Running-output eight, expiry seventeen and web eleven passed. Earlier fixture/preparation failures remain NONPASS. Final affected and native runs include the import compatibility and final HTML changes. |
| `swift test --filter 'ProjectMemoryTests\|RuntimeExecutionJobTests\|WebToolPackTests\|ProductPathReliabilityTests'` | Final exit zero: 226 selected, 224 passed, two skipped, zero failures; 82.577 seconds. Memory 49, runtime 131 and web 11 all passed. The two prepared-native identity cases were skipped in this normal run. |
| Prepared same-version native peer | Subsequently executed one exact skipped method with the original and final signed 0.20.0 candidates; it passed with zero skips/failures. The separate Debug/Release bundle matrix fixture remains unprepared and unverified. |
| Declared CLI/app products | Both direct `swift build --product` commands exited zero. |
| Canonical workspace ordinary Debug | Direct `xcodebuild` exited zero, BUILD SUCCEEDED, version 0.20.0 (30). Strict deep code-signature verification passed. |
| Signed native Core | Thirty-six intended tests executed: expiry seventeen, running-output eight, web eleven; zero failures/skips, terminal exit zero, TEST SUCCEEDED. |
| App-hosted Projects cases | Two intended repository-editor cases executed and passed; terminal exit zero. This is view-model evidence, separate from click-through UI acceptance. |
| Native expiry before/after | Original past/future/no-expiry fixture now returns two normal records and three with explicit expired inspection across get/search/recent. Malformed expiry is rejected; lowercase/zone/fraction normalization, export/status retention and clean shutdown passed. |
| Native running output | All five cases passed: original running stdout/stderr read, empty/split-Unicode/later bytes, cancellation, timeout and same-bytes/different-inode substitution rejection. Final exact streams/hashes and producer EOF were checked. |
| Native legacy recovery | The untouched checksum-valid schema-3 export produced by the actual signed 0.19.0 helper imported four inserted rows into a new empty destination through explicit legacy mode. Strict/default preview and commit rejected malformed expiry with no memory-domain mutations. Preview, exact malformed get/export, expired inspection, separate invocation/project/path isolation and durable reopen passed. A separate checksummed NUL-expiry import preserved the complete raw string. All three owned native sessions exited zero with full EOF and no force/truncation. |
| Native NUL-expiry before/after | The identical raw SQLite fixture remains visible and get/export preserve the complete embedded-NUL suffix. The earlier signed candidate truncated it through C-string decoding. Final helper/Core/source identities remained unchanged; native exit zero, full EOF and no force/truncation. |
| Ordinary Projects native GUI | Final signed candidate passed six public Accessibility flows: registration, exact safe Open URL in Safari, normalized SSH Save, ordinary Quit/relaunch persistence, invalid-host rejection with correct heading, and Clear. All five owned native window captures were reviewed. Both GUI launches exited normally with code zero; source, candidate, installed app and LM Studio registration remained unchanged. |
| Actual Qwen web metadata | LM Studio `qwen/qwen3.8-27b` consumed both canonical web tools and finished with `stop`. It reported the separate title, correctly absent heading and a real Apple search URL. |
| Actual Qwen expiry queries | All six get/search/recent calls passed: default counts two without the expired fixture, explicit inspection counts three including it. Qwen's final prose correctly reports those observations; `tool_calls`, then `stop`. |
| Actual Qwen running output | Qwen consumed running status and both 17-byte stream snapshots, then terminal exit-zero status and both later 17-byte pages at the actual offset 17. Exact bytes/whole hashes were independently checked. Its final prose correctly distinguishes provisional page EOF from final producer EOF; `tool_calls`, `tool_calls`, `stop`. |

Final logs and xcresults are `followup-affected-source-tests-r2.log`,
`followup-cli-build-r2.log`, `followup-app-build-r2.log`,
`followup-native-debug-build-r2.log`, `followup-native-signing-r2.log`,
`followup-native-tests-r2.{log,xcresult}`,
`followup-projects-app-tests-r2.{log,xcresult}` and
`followup-same-version-peer-test.log`. Earlier native receipts are
`native-expiry-feature-020`, `native-running-output-020` and
`qwen-native-web-metadata-r2`, `qwen-native-expiry-020` and
`qwen-native-running-output-020`. These retain their pre-compatibility candidate
identities. Final-candidate receipts are `qwen-native-web-metadata-final`,
`qwen-native-expiry-final`, `native-legacy-expiry-recovery-020-r2-attempt3`
and `native-projects-public-ax-final-020`. The exact NUL before/after rerun is
`native-expiry-nul-fixed-020-r2`.

`qwen-native-running-output-final` repeats the actual-model running/final exchange
on the final candidate. All three final Qwen exchanges used
`qwen/qwen3.8-27b` through the supported LM Studio API and verified unchanged
source/helper/Core hashes and clean native exit/EOF. Qwen suggested a per-ID
filtered-expired explanation and an additional page-EOF annotation. Those are
recorded usability proposals; existing IDs/EOF fields are preserved and no new
behavior is claimed for them.

The additional recovery check is E0: the actual signed 0.19.0 helper exported
four retained baseline records with the original checksum and schema 3. One
record has `expires_at: "not-a-date"`. The signed 0.20.0 importer rejected both
preview and commit of that untouched artifact with `invalid_request`. The four
existing rows remained intact. `native-legacy-expiry-import-baseline-r2` records
both processes' clean shutdown. The explicit versioned compatibility path and
fresh-destination recovery above correct this regression; the original failed
imports remain diagnostic evidence, not acceptance passes. Two initial recovery
helper attempts used a wrong journal table name and attempted a different root
within an already-bound invocation. Their failed receipts remain retained; the
successful probe uses the actual table and separate invocation sessions.

The first metadata model probe remains NONPASS: its harness incorrectly assumed
Example Domain had an h1. The captured live HTML has a title and no h1; the
candidate correctly omitted `heading`. The corrected probe checked the complete
live source before asking Qwen to report actual fields. Qwen's final prose
suggested the body no longer included its title; the actual retained body contract
still includes that text. The accepted evidence is consumption of separate
metadata, not that unsupported inference.

The final signed candidate helper SHA-256 is
`96dce751706c295eddfda3ca1ea7b82b94e895c762795c9d2762948af30ee3ec`;
Core framework SHA-256 is
`18ff439e6ab6eaa359d6b10f7484f827d74e58d62b65406f9136cd5768ab588b`.
`followup-native-candidate-r2.json` records all owned artifact identities. Native/model
receipts verify unchanged source and candidate inputs and clean stdio shutdown
without forced termination or truncated output. They use isolated project/home
stores and do not modify the installed application or LM Studio registration.

## Remaining gates

The earlier Xcode UI runner executed zero cases after an automation-mode
authorization timeout; CUA's native pipe also failed. Those attempts remain
NONPASS. The ordinary native controls have separate public Accessibility and
reviewed-pixel acceptance above; the failed XCTest method was not rerun or
reported as passed.

The Debug/Release native bundle fixture, installation, ordinary external-desktop
continuity/session identity, JavaScript/authenticated browser interaction and the
broader requested capability families remain open. Candidate API exchanges are
separate API-owned model conversations, not a claim that the active desktop chat
was upgraded or that every model/provider/format is qualified.

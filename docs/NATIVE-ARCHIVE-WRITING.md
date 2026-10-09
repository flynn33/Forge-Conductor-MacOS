# Native supplied-entry ZIP writing

Current source target: **0.38.0 (54)**.

`archive_write` creates a single stored ZIP from caller-supplied virtual file names and bytes. It is a new Docs tool with its own grant. It does not read member data from host paths. An explicit destination with a case-insensitive `.zip` extension is required; no extension is appended.

## Input

Only `path`, `entries` and the existing shared `deadline_ms` are accepted. Each entry has exactly string `name` and string `content` fields; entry order is output order. Use canonical padded base64 for content, including an empty string for an empty file.

```json
{
  "path": "<project>/supplied.zip",
  "entries": [
    {"name": "notes/readme.txt", "content": "SGVsbG8K"},
    {"name": "empty.bin", "content": ""}
  ]
}
```

The example supplies `Hello` followed by LF (six bytes) to the first member and zero bytes to the second. `notes/` is a virtual path prefix; no explicit directory member or host directory read is requested. An empty entries array produces an empty 22-byte EOCD archive, not a placeholder member.

Names must already be NFC relative UTF-8 file paths, with at most 1,024 bytes per complete name and 255 bytes per component. Empty names/components, absolute paths, a colon anywhere in the first component, backslashes, controls, `.` and `..` reject. No normalization silently changes supplied name bytes. Duplicate names, Foundation POSIX case-insensitive folding collisions and ancestor-file conflicts reject. This conservative admission policy is not a portable filesystem collision guarantee.

## Bounds and output

| Boundary | Limit |
| --- | --- |
| Supplied files | 0–32 |
| Complete name / component | 1,024 / 255 UTF-8 bytes |
| One canonical base64 string | 1,398,104 UTF-8 bytes |
| Aggregate decoded member bytes | 1,048,576 bytes |
| Complete ZIP output including all headers/directory/EOCD | 2,097,152 bytes |
| Managed broker canonical JSON arguments | 65,536 bytes, or less under a narrower authorization context |

The writer ceiling is not universal provider admission: path, names, base64 and JSON framing also occupy managed argument bytes. A 1 MiB encoder fixture does not establish that any model/provider can submit it through the managed broker. Instruction-package import limits and scoped read-delivery windows are separate contracts.

Output uses method 0, exact supplied member order and bytes, UTF-8 flag bit 11, matching local/central records, CRC32 and fixed DOS 1980-01-01 timestamps. No compression, encryption, ZIP64, descriptors, extra fields, comments or explicit directory entries are generated. The complete extent is preflighted before the call-local output is allocated; the encoder runs on a worker and checks cooperative cancellation under fixed bounds.

A successful result reports `path`, `format: "zip"`, `engine: "swift-stored-zip"`, `bytes_written`, whole-output `sha256`, `entry_count`, aggregate `input_bytes` and `output_contract: "zip-stored-supplied-files-v1"`. Inspect actual result metadata and complete byte transport rather than inferring acceptance from a filename alone.

## Authorization, persistence and replay

Destination authorization uses the existing raw-path owner before normalization. Project roots provide context/default paths; own tool grants and OS permissions govern destination access. Virtual member names and base64 remain member data and are not interpreted as host source paths. Ordinary default enrollment adds only the new exact tool; custom denials and imported explicit capabilities retain their existing rules.

Context is checked before and after encoding. Publication uses the existing pinned Data writer with its modes and durable-write behavior. Managed replay class is idempotent, with existing idempotency-key/result authority. Continuity progress and document telemetry enrollment do not change checkpoint/successor/ACK/seal or gauge/queue ownership.

Malformed paths/entry shapes, unsafe/non-NFC/conflicting names, noncanonical base64 and limits reject before destination publication. Encoding failures and `archive_write_failed` remain distinct. A destination write or durability-confirmation error can occur after the destination changes; inspect it before retrying. Precancellation and deadline checks are distinct from cancellation after work begins and the common writer's late-cancel/revocation-before-rename boundary.

## Qualification and retained evidence

The source missing-registration baseline executed one failing method, normal exit 1 in 6.850 s; its NONPASS remains retained.

The same 62 distinct methods passed in source and native checks, with no failures or skips. Native checks on 0.38.0/build 54 finished in 62.594 s; only five version authorities changed since the source checks. The ordinary Debug candidate built in 24.455 s and passed strict deep signature verification in 0.140 s. Swift CLI/app compilation passed in 6.188/2.194 s. Source 49/13 passed in 24.901/9.435 s. Actual native compilation proves the writer/Core and test/ForgeConductorTests memberships.

Signed App/CLI archive checks passed in 2.820/2.856 s, each with 25 correlated native responses, 23 tool frames and four ZIPs. Six refusals, an immediate cancellation preserving the existing 609-byte ZIP, PNG default and all 84 prior catalog definitions passed per route. Small ZIP reads were complete; the maximum archive used two bounded read windows plus exact whole local container/CRC/payload verification.

Qwen completed three observed Low API turns in 51.538 s and consumed two complete actual archive_write/fs_read results, with six native responses/four tool frames and a strict four-scalar metadata acknowledgement. This does not prove member-content understanding, installed chat behavior, full web or all models.

A separate native BSDtar consumer passed four actual App ZIPs: 36 exact payload files/1,048,999 bytes under canonical filesystem-name lookup, with normal exits/full EOF/no forced cleanup. CLI/Qwen extraction, exact physical filename spelling, general ZIP/Windows interoperability and installation are unqualified.

Final document checks and exact source/wiki delivery are recorded separately; they add no runtime coverage.

Original App v1 exercised 15 native responses/12 recorded tool frames/four ZIPs, but its first refusal failed a harness assertion looking for error instead of ToolResult.code; the attempt remains NONPASS. The v2 driver corrected only the refusal field gate/fresh labels, preserving code/message/ok/retryable/isError and text=structuredContent checks. Qwen v1 success is an independent unchanged attempt; it was not rerun for that driver correction.

Four mechanism fixtures and forty controls passed; separate Python ZIP wire/CRC/payload checks passed. Four product-generated ZIPs per App/CLI route passed independent bounded container/CRC/member-byte verification; complete local file proof is separate from bounded MCP read windows. Mechanism proof is separate from product acceptance.

All four mechanism fixtures passed BSDtar extraction under canonical-name lookup and exact full payload equality. The actual App product consumer later passed four ZIPs with 36 exact payload files/1,048,999 bytes in 0.139 s, normal zero/full EOF/no forced cleanup; CLI/Qwen native extraction was not invoked. Original ditto empty-ZIP and BSDtar physical-name-byte NONPASSs remain retained. Physical filename bytes are not qualified.

The 62 owning methods plus one separate initial G3 method give 63 distinct methods per source/native route, with equal unique selector sets; this is not a single 63-method invocation. Initial G3 passed in 7.367/2.603 s and hygiene in 0.670 s; repeats add no coverage. The native G3 IDELaunchSession.m:395 warning remains retained. Final document checks and exact source/wiki delivery are recorded separately; they add no runtime coverage.

Compare unique owning selector sets before reporting source/native agreement or unions. Focused repeats add no distinct coverage. New writer/tool tests, schema/replay/default-import neighbors and a selected G3 method have separate actual invocation records. Native owners use ForgeConductorTests under the canonical ForgeConductor workspace/scheme; ordinary candidate and test output directories remain separate.

Mechanism proof is separate from product acceptance. Retain original ditto empty-archive and BSDtar physical-byte-name NONPASSs beside any later canonical-name/payload consumer result. Exact NFC member names can become physical NFD filesystem spellings on a consumer; those observations do not alter the archive's supplied bytes or establish universal application interoperability. SafeZIP.inspect is not a CRC oracle.

Before the later v3 flow, Projects GitHub registration/save/reopen/reject/clear was unqualified. The retained .37 flow failed before registration. In the later .38 public-AX sheet diagnostic, the unique source-identified Cancel was pressed; post-open settled copies succeeded, but the immediate post-Cancel AXWindows count returned -25204, so the whole diagnostic remained NONPASS. The App quit normally with no forced cleanup and unchanged shared preferences; no Register/Save occurred. Product cause is unknown. A separate v2 sheet diagnostic passed in 5.669 s: the immediate post-Cancel copy still returned -25204, both settled copies succeeded and the final complete semantic scan confirmed registration controls absent. It qualified only open/Cancel/ordinary cleanup, with no Register/GitHub Save/reopen/reject/clear or Tools acceptance. Installed full web/all-model, host rollover, general lifetime, Release and shipment qualification remain separate.

Exact owner source/wiki publication, readback and synchronization outcomes are retained in external closeout receipts. This archive capability alone supplies no installed/full-web/all-model/host-adapter/general-lifetime/Release/shipment acceptance.

Later .38 Projects v3 registered one isolated folder with matching project ID/root and generation 1, then remained NONPASS when the Save phase reached the 8,192 AX call cap after one field set and one Save press. The 303-byte metadata stayed byte-exact with no repository URL. The App quit ordinarily with exit 0 and no forced cleanup; guards and shared preferences were unchanged. Save/reopen/reject/clear and Tools remain unqualified; cause unknown. The inner/outer attempt took 6.647/6.683 s; the registration worker used 3,956 AX calls. This later registration observation does not replace the earlier sheet diagnostic PASS or any retained NONPASS, and it adds no archive/runtime test methods.

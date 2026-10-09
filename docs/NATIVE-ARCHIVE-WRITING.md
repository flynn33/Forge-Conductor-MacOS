# Native supplied-entry archive writing

Current source target: **0.40.0 (56)**. `archive_write` now accepts optional exact `format: "zip"`, `"tar"` or `"tar.gz"`; omitted format remains stored ZIP. Explicit case-insensitive .zip/.tar/.tar.gz paths must match the selected format. Supplied virtual NFC names, canonical padded-base64 content, entry order/bytes, 0–32 entries, 1 MiB aggregate raw and 2 MiB complete output remain bounded. The separate managed canonical JSON argument limit remains 65,536 bytes. Standalone raw-file GZIP, host member sources and extraction are not added.

| format | Explicit destination | engine | output_contract |
| --- | --- | --- | --- |
| absent or zip | .zip | swift-stored-zip | zip-stored-supplied-files-v1 |
| tar | .tar | swift-pax-tar | tar-pax-supplied-files-v1 |
| tar.gz | .tar.gz | system-zlib-gzip-pax-tar | tar-gzip-pax-supplied-files-v1 |

Shared name/base64/grant/context/overwrite/replay/pinned publication rules remain those in the retained ZIP contract below. Format is optional; unknown/null/non-string/uppercase/alias values refuse as invalid_archive_format, and mismatched extensions refuse as invalid_path. Returned success keys are unchanged. One UTF-8 length-counted PAX path record precedes each regular USTAR member; metadata is fixed mode 0644/uid 0/gid 0/mtime 0, with deterministic internal names, zero record padding and exactly 1,024 zero EOF bytes. Empty TAR is those 1,024 bytes. tar.gz is one GZIP member with time 0/OS 255/no optional fields containing the complete TAR; same-runtime byte determinism is distinct from universal compressor identity. No links, sparse members, append/update or directory entries are generated.

Source checks passed 11 owning and 14 preservation methods across eight invocations; the matching .40/56 canonical native selection passed the same 25 distinct methods in 22.035 s. CLI/app compilation passed in 5.849/2.297 s; ordinary Debug/strict signature passed in 25.674/0.138 s on 471 inputs. The first test-helper type-checking NONPASS and its explicit UInt32 CRC correction remain recorded.

Direct candidate App and CLI MCP checks each passed 32 responses, 30 tool frames, seven base64 pages and five complete EOF readbacks, ten refusals, immediate cancellation with target preservation, deterministic TAR repeat and 22-byte default/explicit ZIP parity. The catalog retained 86 definitions with all 85 neighboring descriptors exact.

Qwen TAR and tar.gz each passed nine native responses/seven tool frames, three observed Low inputs, two actual archive_write/fs_read results consumed by completed turns 1/2 and an exact four-scalar ACK (`sha256`, `bytes_written`, `entry_count`, `input_bytes`) after whole-file EOF readback. All routes closed normally without forced cleanup; the 471 source inputs, seven candidate artifacts, 59 prior guarded paths and fixture configurations remained unchanged.

| Product format | Complete bytes | SHA-256, identical across App, CLI and Qwen |
| --- | --- | --- |
| TAR | 4,608 | `3f1d702d295391714cb6713495d23b341caaae5fb1e5269a220c196fb363d3db` |
| tar.gz | 482 | `320d403c37025369150b175d581555cd23dd06d3e6c1b56b9e3c92201d61d787` |

Each archive contains ordered `données/日本語.bin` with exact bytes 00…ff and `empty.bin`; independent whole-container readback retained both member lengths and hashes. The product wire/model closure is `native-tar-gzip-app-cli-qwen-wire-root-readback-0400-v1.json`, SHA-256 `8d25de90e8953c94f544886eba4a07dbc39fe2e495f0b2b78037409ec8beac3d`.

Product BSD checks passed fifteen stdout-only commands over the six App/CLI/Qwen TAR/tar.gz archives: six ordered logical-name listings, six complete 256-byte payloads (00…ff) and three gzip integrity checks. Every command exited normally at zero with both EOFs, owned-group absence and no forced cleanup. All six retained raw listings are 34 bytes, SHA-256 `8b374d7ecb2c69168794aa1449acaa23a27b91737d8861329f41fe6692d73c5a`, with NFD spelling against archive NFC names; the cause remains unknown. The source 471/current 7/prior 59, packet, native consumer and interpreter guards were unchanged. No filesystem extraction or physical-spelling guarantee is established.

The product BSD closure is `native-tar-gzip-product-bsd-runtime-root-readback-0400-v1.json` (182,738 bytes), SHA-256 `22a6afc3605d32709fa2c0b9fc1f4c99c740deac101fc2f78176125bacbe1e7b`. Separate source/native G3 checks passed one actual method each in 7.174/14.946 s, giving 26 distinct methods per route with the prior 25-method selections; these are separate invocations. The initial native AppTests zero-selection attempt remains NONPASS. Hygiene/whitespace passed in 0.668/0.140 s, normal exit 0/unforced. The final C2 passed a reread of the same seven immutable C1 binaries, with no rebuild: the current 471-input map differs only in two G3 identity assertions; all other 470 inputs, including production, resources, authorities and graph, remain exact. Initial owner source/wiki delivery passed at source `0a7b23a62c83848b9fe3d9d4602c5f6d1c3ea267` and wiki `8df4664b39729e367e2dbd9dcf08e7adb7b2540d`, with exact readback and clean synchronization recorded separately.

Separate mechanism proof passed six recipes/twelve archives and 31 controls. Corrected independent v2 passed ten positive/45 negative controls and all twelve archives; thirty BSD stdout checks passed twelve canonical NFC listings, twelve complete payloads and six gzip integrity commands. The two mixed listings had raw NFD spellings, retained with cause unknown; no filesystem extraction or physical-spelling guarantee follows. Original generator NONPASS remains retained. The mechanism instrumentation observed tracked allocation/free/End/deinit/weak-owner release and cancellation after returned deflate on selected test-only paths; unchanged product copies were checked separately. Product pre-cancel/deadline checks do not establish in-work or late-write cancellation. These are scoped source/native/Debug, product wire/model and mechanism results; installed operation, general interoperability/lifetime, product in-work/late-rename cancellation, standalone GZIP, every page/model, Release and shipment remain separate.

## Preceding stored ZIP contract and qualification — .38.0 (54)

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

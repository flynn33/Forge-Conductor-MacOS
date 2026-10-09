# Version and qualification status

Current source target **0.43.0, build 59** adds exact optional `format: "m4a"` and a matching .m4a destination to existing audio_write; omitted/explicit WAV and FLAC remain. Applied source uses a fixed signed owned AudioToolbox AAC-LC worker and the common pinned publisher. Supplied PCM remains bounded to 1 MiB with rates 8000/44100/48000 and mono/stereo; the separate managed canonical JSON bound stays 65,536 bytes. Encoded bytes can vary and decoded samples are lossy; measured container accounting retains the supplied valid-frame count. [Contract](NATIVE-AUDIO-WRITING.md).

Matching selected-identity source/native owning selections each started and passed the same 139 distinct methods once in 76.318/108.450 s, normal exit 0/unforced, zero failures/skips on the same 475 source inputs. The separate 23.913-second framing method is a subset, adding no coverage. Weak-var compiler warnings and the preceding TAR unnecessary-try warning are retained; no warning-free claim is made. Source receipt: `audio-aac-m4a-owning-source-tests-root-readback-0430-v1.json`, SHA256 `37cecee15aeaa0b900f81db4eff4ff5cd3bca117d533c9d5854ef295e70a12dc`; canonical native receipt: `audio-aac-m4a-owning-native-tests-root-readback-0430-v1.json`, SHA256 `6479358b58e8e0d9eaf5e680a1e096473688d4c947bfef9e44431e54c7a14c97`. Native unit execution does not prove actual AAC codec/product consumption; test transport sentinels are not M4A codec evidence. Standalone mechanism receipts qualify their own fixed fixtures only.

| Gate | Current state |
| --- | --- |
| Owning source/native tests and preservation | PASS: matching 139-method selections include modeled AAC limits/refusals/ownership, WAV/FLAC behavior, grants/context/replay and all 85 neighboring descriptors. Actual codec/cancellation/consumer scopes below remain separate from modeled replay/shutdown. |
| Products and signed candidate | CLI/app compilation PASS in 1.013/1.006 s, ordinary Debug PASS in 24.067 s and strict signature PASS in 0.134 s; normal exit 0/unforced on unchanged 475 inputs. Candidate C1 readback PASS: seven artifacts/Info .43/59, 475 compiled inputs and 80 preceding guards exact. Six actual App/CLI rate cohorts passed real M4A encoding; the signed candidate identities stayed exact. |
| App/CLI wire and native consumers | PASS: six rate cohorts/24 real M4A outputs, 112 pages/364 responses and four explicit EOF reads per cohort; catalog/WAV/FLAC/grants/refusals preserved. All 24 files passed separate readonly native supplied-frame decode through true+extra EOF. |
| Cancellation and shutdown | Six observed-child cancellations returned -32800, preserved destinations and ended with the child absent. Outer/native parents closed normally with both EOFs. Failed/unresolved native-owner reachability and general shutdown remain unqualified. |
| Qwen | PENDING: actual completed later-turn write/read consumption, observed Low inputs and scoped metadata acknowledgment. |
| Documentation and delivery | PENDING: source/native G3, hygiene, current source/wiki parity, publication and synchronization. |

Candidate C1 readback receipt: `audio-aac-m4a-current-candidate-root-readback-0430-v1.json`, SHA256 `27d22c2cef7d16ec6dabeca7187f1b61ba8287aecc7e3ce52a537eaa981340ce`. This binds the signed candidate identities; subsequent product/consumer scopes are recorded below, with Qwen still pending.

Six signed App/CLI rate cohorts (8000/44100/48000 for each route) passed 24 actual mono/stereo short/maximum M4A files, 112 complete binary pages and 364 exactly framed responses, with four explicit EOF reads per cohort. Each cohort passed the 18 argument/path refusal cases plus project-context/own-grant refusals, exact WAV/FLAC parity and all 85 neighboring catalog descriptors. A child was observed before cancellation; -32800 preserved destinations and the child was absent afterward. Normal exit/full streams apply to outer/native parents, not a claimed normal canceled-child exit or native Close cause. Receipt: `audio-aac-m4a-native-wire-root-readback-0430-v1.json`, SHA256 `10dbd025cb178d1c699f73bcae668121841f5a8f69ae00dce2e50fa993fe41ad`.

The separate readonly native consumer passed all 24 actual files across rates/channels and short/maximum extents: 12,583,488 decoded bytes, exact supplied valid-frame counts, true EOF plus an extra EOF read and 5,220 successful public native calls. Known wrapper Dispose-before-file-Close occurred once per file, with one callback-owner deinit and a gone weak owner; failed/unresolved native-owner reachability and general shutdown are unqualified. Consumer compilation passed in 1.127 s with a retained weak-var warning. Afterward, 475 source inputs, seven candidate artifacts/Info and 82 preceding guards remained exact. Lossy source-PCM equality, listening quality and independent AAC bitstream validation are not qualified. Receipt: `audio-aac-m4a-native-consumer-root-readback-0430-v1.json`, SHA256 `4c6f30ef672e53ac9d7a8ba55f5a14492b749fe1d686de4b373f4d46c6df992d`.

The completed .42 source/wiki delivery is retained in `web-render-complete-source-wiki-final-delivery-closeout-0420-v2.json`, SHA256 `93d4eec8c44faa0e2824465e48a098ca18a9097527d2430287c63392ea539c4c`; it adds no AAC coverage. Raw ADTS .aac, remaining formats, installed operation, full web/all models, general lifetime, Release and shipment remain unqualified.

## Preceding 0.42.0 (58) qualification

Current source target **0.42.0, build 58** adds opt-in complete captured-text paging to existing `web.render`, retaining the default v1 prefix. One immutable UTF-8 Data body is bounded to 1,048,576 bytes/65,536 visited nodes and retained for at most 120 seconds with one expiry owner. Explicit overflow and stale continuation errors preserve the scope boundary; complete capture does not mean completion of all page work.

The retained App/CLI baseline collected normally on the preceding .41 candidate and observed four missing-suffix results: each route returned 4,096 of 6,144 single-node bytes and 8,192 of 35,371 multi-node bytes at a 65,536-byte inline budget, with truthful `truncated: true`. Whole-snapshot reconstruction remained NONPASS. Receipt: `web-render-complete-snapshot-baseline-app-cli-root-readback-future-v1.json`, SHA256 `a340869bd9c6143c5815a3496b7acc544d695f9e2efb11f4c8ab8e6237f4e3dc`. This is an isolated baseline, not public-network/model/GUI/installed or new paging proof.

Six new protocol and ten new paging methods are included in the 150 distinct owning source methods (134 preceding plus 16 additions), passed in 37.304 s, normal exit 0/unforced, zero failures/skips/compiler warnings on 473 inputs. The separate weak-service method passed in 5.247 s and is a subset, adding no coverage. Receipt: `web-render-complete-owning-source-tests-root-readback-future-v1.json`, SHA256 `02d269740e202168b07e1d8ebcb0ed1e4e1f1315e9f48075dfda93b0915a27a2`; source map `86212deac8ebb90d4d61b7b922d30a1b6b2a53770e915f51ce36f1356247ee25`. The complete owning log SHA256 is `7496517afa2ee0c13376cd41ea751e1e94cae594273f1229eb730f98006616c1`. Earlier focused selections and the corrected test-only warning remain separate; these tests preceded version selection.

Root selected .42/58 in five authority paths; the 473-input source map is `180a2c8348e4f4d767d22a67185a75aa84437a8d67a6513872989023f7f7e853`, with graph membership/signing unchanged. Matching selected-identity source/native 150 passed in 43.375/71.458 s, zero failures/skips; source had no compiler warnings and native retained the preceding TAR unnecessary-try warning. Separate initial G3 passed one actual method per route in 1.391/2.753 s, giving 151 distinct methods per route across separate selections. CLI/app compilation passed in 5.105/1.985 s and ordinary Debug/strict signature passed. The current signed Debug candidate v2 binds seven artifacts and Info.plist without a later rebuild. Exact identities are in `web-render-complete-current-candidate-root-readback-0420-future-v2.json`.

Signed App/CLI functional v1 passed in 14.221/13.456 s with 88 responses/86 tool frames per route: complete selected bodies up to 1 MiB, exact 65,536-node capture, scalar-safe paging, explicit empty EOF, overflow, wrong-digest/replaced-snapshot and mid-scalar refusals, plus legacy prefix parity. Original App limits v1 remains NONPASS at the existing continuity threshold of 200 tool calls (205 responses); it is preserved separately. Limits v2 passed in 6.070/6.638 s, each with 241 control-text pages, 246 responses/244 tool frames and exact whole 1 MiB reconstruction plus empty EOF. Root independently checked actual structured/text equality and final actual-ID/notice/LF fitting under 65,536 bytes. Owned native parents exited normally with both EOFs, no response tails or forced cleanup; source/current seven/history 73/old Info guards stayed exact. Internal render child PIDs were not independently observed. Receipts: `web-render-complete-paging-initial-three-runtime-root-readback-future-v1.json`; `web-render-complete-paging-app-cli-limits-runtime-root-readback-future-v2.json`, SHA256 `afca3c433ad78e443672967bc5cbc60eb15cb5d3cf76c10856490d18ba8aab42`.

Qwen `qwen/qwen3.8-27b` v6 passed the bounded owned-loopback paging flow: six completed responses consumed five actual native results in later turns, including both empty EOFs, reconstructed the 6,144/35,371-byte snapshots and returned the exact four-scalar byte/SHA ACK. All six actual Low input events were complete LF records, ordered and associated by prompt, nonce and tool-result hash. Earlier v2–v5 NONPASS attempts remain retained; v5 outer closure is unknown and the prior CLI pipe-loss mechanism remains unknown. This proves selected result delivery and metadata acknowledgment, not model understanding or new GUI/public-page/all-model/installed operation.

Qwen v6 closed normally in 143.233 s with status 0, both outer EOFs/group absence and no forced cleanup, cap, deadline or error. The installed public CLI regular-file observer was intentionally stopped only after all six complete associated Low LF events; it exited 0 with PID absence, zero EOF tail, two stable terminal fstat/zero-read witnesses and an independently hashed whole 225,938-byte raw file (SHA256 `af5a86e21b3d9976d0804f00609d89685a9315a142cf38ca023d1df7e645d9a6`). Five native results included both empty EOFs; six completed model responses consumed them in later turns and produced the exact whole byte/SHA ACK for 6,144/35,371 bytes. Two owned GETs, nine native responses/ten inputs including notification and seven tool frames were verified. Source 473/current seven/history 73/harness 198 and the existing daemon route remained exact. Receipt: `web-render-complete-paging-qwen-runtime-root-readback-future-v6.json`, SHA256 `9d92b66a60d3962d474640eef003ce465807e42c22e75485fed2eb6deccf0703`.

The Qwen v2 attempt exited normally with status 1 in 156.944 s, both EOFs/groups absent/unforced. Four complete Low events map requests 0–3; request 4's retained 65,536-byte fragment is invalid UTF-8/JSON, and request 5's actual Low event is unknown. The first-subscription-loss hypothesis is disproven for this run; upstream partial-framing cause remains unknown. Receipt: `web-render-complete-paging-qwen-runtime-root-readback-future-v2.json`, SHA256 `ebe7fc79ffebe5c7a4fe90962ad0f4e92660c71c63ead56153eaccb42e3d2122`. The frozen original observer packet and NONPASS remain retained.

Subsequent SDK observer v3/v4 attempts remained NONPASS with zero callbacks despite six completed model responses, five native results consumed and whole ACK; their native/model functional evidence does not qualify actual Low observation. Receipts: `web-render-complete-paging-qwen-runtime-root-readback-future-v3.json`, SHA256 `2d3db780a2705cfe4a0d148d556030b55049bf3b68d8121bbc397f58642a2e06`; `web-render-complete-paging-qwen-runtime-root-readback-future-v4.json`, SHA256 `9f65e546def0dae5bec03dee12fe06a28864d560d89192bcdb462e27454ca876`. CLI pipe v5 retained five valid complete Low LF events (including a 69,587-byte fifth record) and a sixth 69,632-byte invalid JSON EOF tail. Native/model traversal and ACK passed, strict logger qualification remained NONPASS, and interrupted outer collection left terminal/reap/EOF closure unknown. Receipt: `web-render-complete-paging-qwen-runtime-partial-root-readback-future-v5.json`, SHA256 `6e6c32998c6ecc65d078822d977529a8d365aec6b0fd95d8e6cd5e54f21a3d74`. Prior CLI framing/write/flush loss remains unexplained; the v6 regular-file evidence sink does not infer a Forge or LM Studio production fix.

Final checks of the applied v2 documents passed: source/native G3 each executed the same single method in 5.658/5.560 s, normal exit 0/unforced, without adding distinct coverage; hygiene passed in 0.659 s. Root checked all 43 wiki pages/11 images and 668 local targets with zero errors, retaining old fragments and exact current source/wiki mirrors. Receipt: `web-render-complete-final-source-wiki-documents-links-root-readback-0420-future-v2.json`, SHA256 `664da5eccabf7e5fd3506c2c4f3e6d27916dde4edd3754c67c176acc16560e4a`.

Final candidate v3 readback retained the unchanged 473-input `180a2c83…` map, seven artifacts/Info and 73 historical identities, binding the scoped source/native, App/CLI paging and Qwen six-Low passes without rebuilding. Receipt: `web-render-complete-current-candidate-root-readback-0420-final-v3.json`, SHA256 `6bfa328086f7e9af1cd79cdec667783720704cf7163045aa3788afe4f9a982ea`. First owner source/wiki publication, exact readback and clean synchronization passed at source `3bb72e2a430c81af6f8d1e3c850c52a856c014b0` and wiki `97f17228e455a5d568d7ca784d24cee597880758`, each local/remote branch clean with 0:0 divergence. Receipt: `web-render-complete-first-source-wiki-delivery-root-readback-0420-v1.json`, SHA256 `6899fd7be5c78bd56012d0ae348b207d3ea8a4ec865550095ca784343029f8d7`. These are the first feature/document delivery revisions. Closing publication/synchronization identities belong in the external delivery receipt; they add no runtime coverage. Source 473, candidate/artifacts, native tests and G3 scopes remain unchanged. The E2 context-budget correction retains a separate runtime reachability gate. Full web/every model/page, installed operation, general lifetime, remaining formats, Release and shipment remain unqualified. [Contract](NATIVE-WEB-RENDERING.md).

## Preceding 0.41.0 (57) qualification

Current source target **0.41.0, build 57** extends supplied PCM16 audio_write to optional FLAC while retaining omitted/explicit WAV. The actual pre-version source area passed 59 distinct methods (8 FLAC, 9 WAV, 38 catalog and 4 audio broker) in 35.339 s, normal exit 0/unforced, with zero failures/skips on unchanged 473 inputs. The earlier focused 8 passed in 37.562 s and is a subset, adding no distinct methods. These tests ran with 0.40.0/56 authorities before the selected 0.41.0/57 identity advance.

The eleven new methods are eight FLAC writer/tool, one schema/85-neighbor preservation and two broker methods, all included in 59. The complete same-path default/explicit WAV payload and bytes, strict format/path/scalars, CRC/MD5/full PCM/EOF, six 1 MiB combinations, grants/context/modes/audit and broker refusal/replay were exercised in that source selection. The one old format=wav unknown-key fixture now uses unknown=wav because format is authorized; its refusal assertions remain, with explicit WAV parity added. The source compile retains an unrelated NativeTARArchiveWriterTests unnecessary-try warning. Zero-selected support bundles contribute no tests.

The source closure is `native-audio-flac-product-source-before-version-root-readback-future-v1.json`, SHA256 `a18555e810815df9290c6d87137d9623113e406cf4d36ce79de0567ea61d20f0`, with 473-input map `d35a6f3cfd9937a6dd1f61965332fb0b4fec31e8788ad3453c44ff024885808b`. It keeps its pre-version identity; the selected-identity native/candidate evidence has its separate 473-input map `5a35bfad6197caaa8bdc1481a8c119b5d12e703906b721d43d96e01cb4ac85e7`.

The selected .41/57 canonical native run passed the same 59 methods in 69.268 s. CLI/app compilation passed in 5.646/2.323 s; ordinary Debug/strict signature passed in 25.586/0.136 s on unchanged 473 inputs. The ordinary candidate receipt is `native-audio-flac-ordinary-candidate-0410-v1.json`, SHA256 `795a949a3f595c9a374c37b9c196b7de147c55a8d06a8e89f1bce34381c86aa5`; it binds seven artifacts and 66 unchanged historical/protected identities. The unrelated TAR unnecessary-try warning is retained in the native log too.

The ordinary candidate App/CLI routes each passed 40 responses/38 tool frames, eight binary readback pages (seven FLAC plus one WAV), 18 refusals, immediate-cancel destination preservation and complete WAV parity in 1.800/1.292 s. Catalog 86/85-neighbor preservation and native normal exit 0/both EOF/unforced were checked. Qwen qwen/qwen3.8-27b passed in 41.703 s: three observed Low inputs, two selected audio_write/fs_read results consumed by completed turns 1/2, nine native responses/seven frames, complete 85-byte mono44100/16-frame FLAC EOF and exact four-scalar metadata ACK. This is the bounded API workflow, not GUI, installed or all-model qualification.

The selected .41/57 source rerun passed the same 59 distinct methods in 40.694 s (tests 33.227 s), matching the canonical native and pre-version method sets on unchanged 473 inputs. The source closure is `native-audio-flac-product-source-normal-area-root-readback-0410-v1.json`, SHA256 `a9883fc56461209ad6e7351316f74c18ea45a028ff1c0ed1cc7faea30da11f90`; the tested source map remains `5a35bfad6197caaa8bdc1481a8c119b5d12e703906b721d43d96e01cb4ac85e7`.

Three actual App/CLI/Qwen FLAC outputs passed Apple afconvert whole RIFF/PCM checks in 0.024/0.018/0.017 s, each normal exit 0/unforced with both EOF and the owned group absent. Both App/CLI stereo48000/9,217-frame outputs decoded to the exact 36,868 supplied PCM bytes; Qwen mono44100/16-frame decoded to the exact 32 supplied bytes. Complete RIFF extents, PCM format and EOF were checked. This qualifies these three product outputs only. The native consumer closure is `native-audio-flac-product-afconvert-whole-pcm-root-readback-0410-v1.json`, SHA256 `18bf4e77dbc1dbe30df06982e2d017e0cb79285ed74f37d3c2499c1626536d33`. The earlier wire-only receipt retains its native-consumer-pending state at that tested point.

Separate G3 source/native checks each passed the intended G1G10AcceptanceTests/testG3_VersionAndReleaseDocumentsAreAligned method in 1.389/2.869 s, normal exit 0/unforced with zero failures/skips. The selected-identity source 59 plus source G3 and native 59 plus native G3 give matching 60-method unions; no single 60-method run is claimed. The source support bundle selected zero methods and contributes no coverage. Native destination and DVTAssertions warnings remain in the retained log. Hygiene/whitespace passed in 0.657/0.139 s on the applied initial thirteen documents and unchanged 473 source inputs.

Final C2 reread the same seven immutable .41/57 C1 artifacts and Info identity without a rebuild. The complete 473-input map and all 66 historical/protected identities remained exact; fresh strict signature passed in 0.134 s. The C2 receipt is `native-audio-flac-final-candidate-root-readback-0410-v1.json`, SHA256 `38c6a5612bc8c7e0a9d84306d9983a5c26fe9fbad80df6ec2eba9ede356a62b6`. Final prose hygiene/whitespace passed in 0.678/0.133 s, normal exit 0/unforced. First owner source/wiki publication, exact readback and clean synchronization passed; the external delivery receipt is `native-audio-flac-first-source-wiki-publication-root-readback-0410-v2.json`, SHA256 `711c8fc4ff7bf9bc8a4bc16f0ba30e1877c56e599df9fff8867cfef2b1333ce9`. Exact revisions and later prose-publication results remain external. Standalone mechanism receipts do not replace integrated product consumers.

## Preceding 0.40.0 (56) qualification

Current source target **0.40.0, build 56** extends archive_write with exact optional tar/tar.gz and retained default ZIP. Source checks passed 11 owning and 14 preservation methods across eight invocations; the matching .40/56 canonical native selection passed the same 25 distinct methods in 22.035 s. CLI/app compilation passed in 5.849/2.297 s; ordinary Debug/strict signature passed in 25.674/0.138 s on 471 inputs. The first test-helper type-checking NONPASS and its explicit UInt32 CRC correction remain recorded.

Direct candidate App and CLI MCP checks each passed 32 responses, 30 tool frames, seven base64 pages and five complete EOF readbacks, ten refusals, immediate cancellation with target preservation, deterministic TAR repeat and 22-byte default/explicit ZIP parity. The catalog retained 86 definitions with all 85 neighboring descriptors exact.

Qwen TAR and tar.gz each passed nine native responses/seven tool frames, three observed Low inputs, two actual archive_write/fs_read results consumed by completed turns 1/2 and an exact four-scalar ACK (`sha256`, `bytes_written`, `entry_count`, `input_bytes`) after whole-file EOF readback. All routes closed normally without forced cleanup; the 471 source inputs, seven candidate artifacts, 59 prior guarded paths and fixture configurations remained unchanged.

| Product format | Complete bytes | SHA-256, identical across App, CLI and Qwen |
| --- | --- | --- |
| TAR | 4,608 | `3f1d702d295391714cb6713495d23b341caaae5fb1e5269a220c196fb363d3db` |
| tar.gz | 482 | `320d403c37025369150b175d581555cd23dd06d3e6c1b56b9e3c92201d61d787` |

The exact product wire/model closure is `native-tar-gzip-app-cli-qwen-wire-root-readback-0400-v1.json` (236,528 bytes), SHA-256 `8d25de90e8953c94f544886eba4a07dbc39fe2e495f0b2b78037409ec8beac3d`.

Product BSD checks passed fifteen stdout-only commands over the six App/CLI/Qwen TAR/tar.gz archives: six ordered logical-name listings, six complete 256-byte payloads (00…ff) and three gzip integrity checks. Every command exited normally at zero with both EOFs, owned-group absence and no forced cleanup. All six retained raw listings are 34 bytes, SHA-256 `8b374d7ecb2c69168794aa1449acaa23a27b91737d8861329f41fe6692d73c5a`, with NFD spelling against archive NFC names; the cause remains unknown. The source 471/current 7/prior 59, packet, native consumer and interpreter guards were unchanged. No filesystem extraction or physical-spelling guarantee is established.

The product BSD closure is `native-tar-gzip-product-bsd-runtime-root-readback-0400-v1.json` (182,738 bytes), SHA-256 `22a6afc3605d32709fa2c0b9fc1f4c99c740deac101fc2f78176125bacbe1e7b`. Separate source/native G3 checks passed one actual method each in 7.174/14.946 s, giving 26 distinct methods per route with the prior 25-method selections; these are separate invocations. The initial native AppTests zero-selection attempt remains NONPASS. Hygiene/whitespace passed in 0.668/0.140 s, normal exit 0/unforced. The final C2 passed a reread of the same seven immutable C1 binaries, with no rebuild: the current 471-input map differs only in two G3 identity assertions; all other 470 inputs, including production, resources, authorities and graph, remain exact. Initial owner source/wiki publication, readback and clean synchronization passed; exact revisions are retained in the external delivery receipt.

Separate mechanism proof passed six recipes/twelve archives and 31 controls. Corrected independent v2 passed ten positive/45 negative controls and all twelve archives; thirty BSD stdout checks passed twelve canonical NFC listings, twelve complete payloads and six gzip integrity commands. The two mixed listings had raw NFD spellings, retained with cause unknown; no filesystem extraction or physical-spelling guarantee follows. Original generator NONPASS remains retained. Mechanism test-only cleanup/cancellation witnesses do not prove actual product in-work cancellation or the shared pinned-write late boundary. These are scoped source/native/Debug, product wire/model and mechanism results; installed operation, general interoperability/lifetime, product in-work/late-rename cancellation, standalone GZIP, every page/model, Release and shipment remain separate.

## Preceding 0.39.0 (55) qualification

Current source target **0.39.0, build 55** adds supplied PCM16 WAV writing. The missing-feature catalog method failed at the absent audio_write definition in 7.325 s (one failure, normal exit 1). After integration, that same single method passed in 19.268 s (normal exit 0); this is a subset, not the owning selection. Actual source selections passed 48 owning methods (9 writer, 37 catalog, 2 audio broker) in 31.228 s and 24 separate preservation methods in 13.654 s; the matching 72 canonical native methods passed in 67.506 s. All three selections exited 0 without forced cleanup or failed/skipped tests on the same 468 inputs. Swift CLI/app compilation passed in 1.106/1.276 s; ordinary Debug/strict signature passed in 24.825/0.139 s, normal exit 0/unforced, for the separate .39/55 seven-artifact candidate.

Candidate App/CLI wire checks passed in 1.558/1.098 s: 33 correlated responses/31 complete tool frames, three exact 46/52/60-byte WAVs, 11 refusals and immediate -32800 cancellation with the original target preserved per route. All 85 prior descriptors, packaged Docs bytes, ZIP/PNG parity, config, 468 inputs, candidate seven and historical 52 guards stayed exact. A Docs session exercised the own grant; a separate read-only session denied audio_write.

Qwen qwen/qwen3.8-27b passed in 38.544 s: three normal completed responses with three observed Low templates, two actual audio_write/fs_read results consumed by completed turns 1/2, nine native responses/seven tool frames, and a strict six-scalar ACK of the exact 52-byte stereo WAV. Native/model/observer/outer groups were absent afterward; current inputs and guards stayed exact. Seven small product WAVs passed exact whole-header/PCM checks and both public native URL read routes in 0.260 s, normal exit 0/full EOF/unforced: seven AudioFile Close calls with 84 strict property values, seven ExtAudioFile Dispose calls with whole PCM and explicit zero-frame EOF, and 14 wrapper deinit/weak-gone observations. The 468 source inputs, seven candidate artifacts and historical 52 guards stayed exact. Initial document G3 passed one actual method per source/native route in 1.650/2.712 s, normal exit 0/unforced. Source 48 + 24 + G3 and native 72 + G3 give 73 distinct methods per route; these are separate selections. Hygiene/whitespace passed in 0.667/0.140 s, normal exit 0/unforced, on the unchanged 468 source/graph inputs. Final prose hygiene/whitespace passed. The original .39 source/wiki delivery completed at source `2d12624abb1f4455e9e4139d0acdb9e58842e629` and wiki `9e19f999f858413dff5788900dacff76333a305c`; broader completion gates remain open. The external delivery receipt is `native-audio-write-owner-delivery-closeout-0390.json`, SHA256 **ccab66ee4f9724096c73aaabfd8a1625c5dc8d2ddf7d8aa7c996d1c7e8d51204**; it adds no runtime coverage. This scoped consumer does not qualify playback, large product output, framework-wide leak freedom or installed operation.

The new 12 acceptance methods cover scalar/base64/frame/size admission, deterministic RIFF bytes, six full-1-MiB rate/channel cases, path/mode/context/grants/defaults/audit, completed small broker replay and refusal before dispatch at the unchanged JSON bound. All twelve ran within the actual 48-method owning selection; the separate 24-method preservation selection adds distinct coverage. Separate mechanisms and their historical callback NONPASSs do not qualify this product tool. [Audio contract](NATIVE-AUDIO-WRITING.md).

The separately preserved .38/54 candidate passed the typed Projects GitHub flow: registration, canonical Save, ordinary quit/reopen, invalid-host rejection preserving the saved bytes, Clear and a second ordinary quit. Six semantic phases and five durable checkpoints passed in 11.452 s; both Apps exited 0 without forced cleanup. Project identity/generation, 52 guards and shared preferences stayed unchanged. The saved 377-byte metadata reopened byte-exact; Clear left 309 bytes without a repository URL. Earlier driver NONPASSs remain retained. This proves the isolated candidate semantic flow; pixels, external browser opening, Tools, installed GUI, full web and all models remain unqualified.

Separately, the signed .39/55 candidate passed one actual Qwen public-page workflow in LM Studio 0.4.25+1 GUI: six correlated calls/approvals/successes, three completed assistant turns/eight EOS generations, and 86 unchanged advertised schemas. Search/fetch and two JavaScript renders produced a newly consumed URLSession body fact. The original MCP bytes/entries/permissions and original chat were restored; 468 source inputs and 59 guards stayed exact. Both renders remained truncated and normal child exit codes/cause remain unknown. [Result and closeout](PROJECT-WEB-QWEN.md#qwen-in-lm-studio-gui-public-page-workflow). Installed/all-model/authenticated-browser/Forge Tools GUI/Release/shipment qualification remains separate; source/native method counts are unchanged.

## Preceding 0.38.0 (54) qualification

Current source target **0.38.0, build 54** adds `archive_write`. The missing-registration baseline ran one failing catalog method, normal exit 1 in 6.850 s; it remains recorded.

The same 62 distinct methods passed in source and native checks, with no failures or skips. Native checks on 0.38.0/build 54 finished in 62.594 s; only five version authorities changed since the source checks. The ordinary Debug candidate built in 24.455 s and passed strict deep signature verification in 0.140 s. Swift CLI/app compilation passed in 6.188/2.194 s. The 62 owning methods plus one separate initial G3 method give 63 distinct methods per source/native route, with equal unique selector sets; this is not a single 63-method invocation. Initial G3 passed in 7.367/2.603 s and hygiene in 0.670 s; repeats add no coverage. The 62-method owning selection is 11 writer, 36 catalog, 4 broker/status, 2 audit, 2 ODS, 2 PPTX and 5 ZIP-import methods. Source 49/13 finished in 24.901/9.435 s; native owning membership is Core/ForgeConductorTests.

Signed App/CLI archive checks passed in 2.820/2.856 s, each with 25 correlated native responses, 23 tool frames and four ZIPs. Six refusals, an immediate cancellation preserving the existing 609-byte ZIP, PNG default and all 84 prior catalog definitions passed per route. Small ZIP reads were complete; the maximum archive used two bounded read windows plus exact whole local container/CRC/payload verification.

Qwen completed three observed Low API turns in 51.538 s and consumed two complete actual archive_write/fs_read results, with six native responses/four tool frames and a strict four-scalar metadata acknowledgement. This does not prove member-content understanding, installed chat behavior, full web or all models.

A separate native BSDtar consumer passed four actual App ZIPs: 36 exact payload files/1,048,999 bytes under canonical filesystem-name lookup, with normal exits/full EOF/no forced cleanup. CLI/Qwen extraction, exact physical filename spelling, general ZIP/Windows interoperability and installation are unqualified.

Final document checks and exact source/wiki delivery are recorded separately; they add no runtime coverage.

Before the later v3 flow, Projects GitHub registration/save/reopen/reject/clear was unqualified. The retained .37 flow failed before registration. In the later .38 public-AX sheet diagnostic, the unique source-identified Cancel was pressed; post-open settled copies succeeded, but the immediate post-Cancel AXWindows count returned -25204, so the whole diagnostic remained NONPASS. The App quit normally with no forced cleanup and unchanged shared preferences; no Register/Save occurred. Product cause is unknown. A separate v2 sheet diagnostic passed in 5.669 s: the immediate post-Cancel copy still returned -25204, both settled copies succeeded and the final complete semantic scan confirmed registration controls absent. It qualified only open/Cancel/ordinary cleanup, with no Register/GitHub Save/reopen/reject/clear or Tools acceptance. Installed full web/all-model, host rollover, general lifetime, Release and shipment qualification remain separate.

Mechanism-only ZIP wire/CRC and four BSDtar canonical-name/payload consumers passed separately. Original ditto empty-ZIP and BSDtar physical-name-byte failures remain retained; mechanism outputs are not product acceptance. [Archive evidence](NATIVE-ARCHIVE-WRITING.md).

Later .38 Projects v3 registered one isolated folder with matching project ID/root and generation 1, then remained NONPASS when the Save phase reached the 8,192 AX call cap after one field set and one Save press. The 303-byte metadata stayed byte-exact with no repository URL. The App quit ordinarily with exit 0 and no forced cleanup; guards and shared preferences were unchanged. Save/reopen/reject/clear and Tools remain unqualified; cause unknown. The inner/outer attempt took 6.647/6.683 s; the registration worker used 3,956 AX calls. This later registration observation does not replace the earlier sheet diagnostic PASS or any retained NONPASS, and it adds no archive/runtime test methods.

## Preceding 0.37.0 (53) qualification

Current source target **0.37.0, build 53** adds standard-size ICO to `image_write`. Exact lowercase `format: "ico"` requires an explicit case-insensitive `.ico` destination and equal width/height of **16, 32, 48 or 256**. The call-local Swift writer preserves all supplied alpha and hidden RGB in one bottom-up 32-bit BI_RGB DIB with a padded AND mask. Native premultiplied rendering is separate; no embedded ICC or Windows interoperability is promised.

Missing-feature baselines executed exactly one failed method per source/native route in **6.822/43.672 s**, normal exits **1/65**, unforced/full EOF, before production edits; both remain **NONPASS**. After admission, focused source eight passed in **13.931 s**. Matching full raster source/native selections passed **56 methods** in **13.550/24.569 s**; five separate neighbors passed in **2.201/2.504 s**, giving **61 distinct methods per route**. Focused source eight is a subset and adds no distinct methods.
All passing post-change runs had zero failures/skips, normal 0/unforced/full EOF and unchanged 464 inputs; the 56-method selection preserves the complete prior 48 methods byte-for-byte. Five neighbors cover catalog/schema/replay and exact integral/fractional/type/range image wire admission. This is 61-method focused qualification, not a full-suite result or one 61-test invocation.

CLI/app compilation passed in **0.890/0.902 s**; ordinary Debug/strict signature in **1.953/0.135 s**, and native CLI version in **0.614 s**, normal 0/unforced/full EOF. Candidate **78bfcd19…** binds seven artifacts, actual **0.37.0/53** and the unchanged **464-input 3d6f16dd… map**.
Prior current/prior/protected artifacts stayed unchanged; workspace/memberships/signing are retained. Actual signed App/CLI wire runs passed in **0.893/0.822 s**; each exercised **23 groups, 46 responses, 44 tool frames, 17 negatives, two immediate cancellations and 11 artifacts**. Qwen completed three observed Low turns and consumed two intact actual tool results in **96.856 s**. The separate native consumer passed seven ICO/PNG pairs with 14 measured provider teardown witnesses.
[Native image writing](NATIVE-IMAGE-WRITING.md) carries full receipt hashes and exact ICO contract/bounds.

Candidate App/CLI/Qwen wire and seven native ICO/PNG consumer pairs passed in isolated contexts. Two immediate canceled calls were exercised per App/CLI route; cancellation after work has started and the common writer’s late-cancel/revocation-before-rename boundary remain unexercised. Final G3/hygiene/whitespace and exact owner source/wiki delivery outcomes are retained in external root receipts. Projects GitHub Save/reopen/stable identity and filtered Tools web rows remain blocked by the retained CUA native-pipe failure; installed/full-web/all-model/managed-adapter/other-format/Release/shipment gates remain open.
No additional GUI pass follows the preceding .36.3 Doctor/Dashboard-only observation. Original native ICO encoder/PNG-wrapper/small-DIB NONPASSs and the separate .36.3 web/Qwen evidence remain retained. Current wire/model/native-consumer results have their own root receipts; final document/publication identities remain external and are not substituted with earlier-format results.

Current candidate identity is the separately preserved ordinary Debug **f477a0b0…**. After the native G3 test action re-signed the prior main, the restored App passed a fresh **0.849 s** run with all **11 artifacts byte-identical** to the original App outputs; the six other compiled artifacts remain exact. Earlier CLI/Qwen and native-consumer results are reused only on the unchanged CLI/core and generated artifact inputs, with no new model or native-consumer invocation. Original candidate/signing evidence remains historical; the current transition is detailed in [the image guide](NATIVE-IMAGE-WRITING.md). Final document recheck and source/wiki delivery outcomes remain in external root receipts.

## Preceding 0.36.3 (52) decoded UTF-8 web qualification

Current source target **0.36.3, build 52** corrects `web.fetch` continuation
for text that expands when decoded to UTF-8. HTTP receive/base64 cursor bounds
remain **1,048,576 bytes**; decoded text/source content and cursors are bounded to
**3,145,728 UTF-8 bytes**. Within-content UTF-8 boundaries and whole-content SHA
checks remain; only the fetch descriptor's cursor bound/description is widened.

The exact Latin1 regression executed one method/one failure in source/native in
**7.152/14.688 s**, normal exits **1/65**, unforced and complete: the returned
cursor **1,049,794** exceeded the old **1,048,576** input limit. Both original
baselines remain **NONPASS**. After root's source admission, the three new source
methods passed in **14.031 s**; the same full **28** web methods passed in
source/canonical native in **13.866/24.896 s**, zero failures/skips, normal
exit 0/unforced, on unchanged **464-input 768064e9… maps**. Existing 25 methods
remain byte-identical. The new three native methods are included in the full
28 run, not a separate repeat; focused source three adds no distinct coverage.

Coverage is ISO-8859-1 selected suffix through EOF, Windows-1252 maximum 3×
UTF-8 expansion and UTF-16 independent scalar bytes. Both text/source formats
exercise exact framed data/SHA/cursors, escaped IDs, required notice and LF;
Windows/UTF-16 use two crossing windows plus six-byte tail/exact EOF controls,
not complete expanded-body reassembly. Raw/base64 EOF and format-specific
above-limit rejection retain their exact bounds. [Detailed contract](WEB-RESPONSE-BUDGET.md).

Four separate source/native neighbor methods passed in **2.185/2.507 s**,
zero failures/skips, normal 0/unforced, on the same map. They cover canonical
catalog/schema parity, renderer grant/context admission and escaped-ID/notice
final-frame sizing. The exact 28-plus-four unions give **32 distinct methods
per route**, not one 32-test invocation. CLI/app compilation passed in
**0.991/0.903 s**; ordinary Debug/strict signature in **24.888/0.130 s** and
native CLI version in **0.514 s**, normal 0/unforced/full EOF. Candidate
**f0800991…** binds seven artifacts and actual bundle **0.36.3/52** on the
same 464 map; protected reference **49b64d97…** binds **38** current/prior/protected
guards. Signed App/CLI public web checks passed in **5.246/4.821 s**, normal
0/unforced/full EOF: each **13 responses/11 frames**, four controlled GETs,
advertised cursor **1,049,858** and exact selected **8,208-byte suffix/EOF**.
Both preserve the complete 84-definition catalog and 83 unrelated descriptors,
full configuration and all four before/after source/candidate/protected/harness
guard sets. Public search returned three actual results; selected URLSession fetch
returned **42 UTF-8 text bytes** without JavaScript; render returned **7,219 bytes**,
JavaScript/Lockdown, truncated true, SHA **82c7e7a5…5893b**.

Qwen **qwen/qwen3.8-27b** completed four actual Low turns and consumed three
selected, fully written, correlated, verified and delivered complete public MCP
results in **75.012 s**. Native responses/frames and controlled paging match the
App/CLI counts; native/model/observer exited normally with full EOF. The original
fenced-JSON final response failed strict raw-JSON parsing: overall **NONPASS** and
the outer forced flag remain retained. A separate read-only **20.616 s** format
correction returned strict raw JSON with five exact actual metadata fields and
two root-grounded facts from the consumed partial render. It reused all three
results with **zero native/web requests**. Extra Low was requested but **not
observed**; this is not a replacement PASS for the original attempt.
The root runtime readback is `web-decoded-utf8-runtime-root-readback-0363-v3.json`,
SHA **acee9aa9d35c645c274f005732872dcb38e02ba2af879df2ffd7181c8bdd4f6c**.
Root rehashed current source464 and protected38 unchanged after correction.

V1's optional-Config inventory failure occurred before native/model requests
(**e6094b78…**, NONPASS). V2 separately passed controlled paging but returned zero
actual public search results (**10184c18…**, NONPASS). Its newer curl challenge
capture is a separate request; the historical native body remains unknown.

Initial G3 source/native each passed exactly one method in **2.743/2.639 s**,
normal 0/unforced/full EOF, on the same source map. Exact 32-plus-one unions give
**33 distinct methods per route**, not one 33-test invocation; repeated G3 adds
no distinct methods. Native G3 retains its DVTAssertions launch warning.
GUI v3 expired at the whole deadline in **240.446 s**; v4 was stopped after
**Sky Computer Use native pipe closed before response**, in **93.763 s**. Both
remain **NONPASS**, with empty case collections, forced owned exit **-15** and
final owned groups gone. Source464, all 24 runtime artifact guards/eight shared
files and shared typed defaults stayed exact. V4 Doctor showed **0.36.3/52**,
the owned isolated home and current executable OK; expected isolated-home
installation/live-plugin mismatches remain, with no Deploy action. Dashboard
showed **84** tools; filtered Tools web rows, Projects GitHub Save/reopen and
stable linked identity remain unexercised, with no project mutation observed.
The GUI root readback is `native-candidate-gui-root-runtime-readback-0363-v4.json`,
SHA **b68a877878f6b88a43f46bb3b18c7c1dbb0ac5f36deadc963346c3a800957c1d**.
These native GUI gates remain blocked until the CUA capability changes.
Final G3/hygiene/whitespace results are recorded in external root receipts.
Exact source/wiki publication/readback/synchronization identities remain in
external closeout receipts. Prior .36.2 status source/wiki closeout
is retained separately in receipt **5e92bfe9…**. This phase claims no full suite,
whole-body Windows/UTF-16 reconstruction, installed acceptance or diagnostic-free run.
Projects GitHub Save/reopen/stable linked-project identity, full web, all models,
managed-adapter, other requested formats, Release and shipment remain open.

## Preceding 0.36.2 (51) status-build qualification

Current source target **0.36.2, build 51** corrects build identity in fresh
successful `forge_status`/`get_forge_status` responses. Both use the existing
string `ForgeApp.buildVersion`; their inputs/tool names and historical completed
replay remain unchanged. No installation or registration is changed.

The missing-build baseline executed one method with four assertion failures in
7.590 s, normal exit 1/unforced: both aliases omitted build in direct and MCP
payloads. This original baseline remains **NONPASS**. After the one-field change,
source/native passed the exact same six distinct methods in **13.976/38.620 s**,
zero failures/skips, normal exit 0/unforced, on unchanged **464-input 08250288…
maps**. The tests cover both direct/MCP aliases, resumed bootstrap, canonical
catalog/schema parity and unchanged completed historical replay with zero
executor dispatches. Every prior Core/Autonomy method/helper remains unchanged.
Canonical native membership is **ForgeConductorTests**, scheme **ForgeConductor**.
CLI/app compilation passed in **0.986/0.862 s**; ordinary Debug/strict signature
in **24.908/0.133 s** and native CLI version in **0.626 s**, normal exit 0/unforced.
Candidate f62ae18f… binds seven artifacts, actual bundle 0.36.2/51 and the same
464-input source map. Native IDELaunchSession.m:395 DVTAssertions warning
remains; no diagnostic-free claim follows.

Signed candidate v5 App/CLI status checks passed in **0.654/0.634 s**.
Each mode had **four correlated native responses/two tool frames**, exact
string version/build in both aliases and matching first-text/structured values,
complete config equality and exact **84-definition native catalog** parity.
Actual **qwen/qwen3.8-27b** passed in **18.467 s**: three normal public-API
responses with **three actual Low templates**, two selected status results
fully written/correlated/verified/delivered/consumed by completed turns 1/2,
and a strict two-string final ACK (`0.36.2`, `51`). Only the two status tool
definitions were supplied to the model; native catalog parity is separate.
Every native/outer mode exited normally 0/unforced with full EOF. The public
observer was intentionally stopped, joined with EOF and exit 0, without forced
kill. The root runtime readback **634b154c…** binds unchanged current **464**
source inputs and **31** candidate/prior/protected guards.

Initial-document G3 source/native each passed **one method in 1.541/2.624 s**;
six status methods plus separately run G3 give **seven distinct methods per
route**, not one seven-test invocation. Initial hygiene/whitespace passed in
**0.661/0.138 s** (b3de07c0…); repeated G3 checks add no distinct coverage.
Final document recheck and exact source/wiki publication/readback/synchronization
identities belong in external closeout receipts; no future pass or commit
identifier is asserted here. No full-suite result is claimed.

Rejected v2 preparation retains its interpreter admission E1 (18,058,560-byte binary
versus 1 MiB text cap) and was never executed. Actual v3 failed preflight on a
stale prior-profile literal; actual v4 status/native results were correct but
the overall run remained NONPASS because the fixture omitted default budget
state and strict config equality failed. The fresh v5 fixture includes the
observed default state while preserving full equality. These preparation/fixture
failures are retained separately and are not product status failures.

The earlier .36.1 candidate GUI attempt remains **NONPASS**: Doctor version/build
and isolated home were observed, then CUA lost its native pipe; Projects
persistence/reopen and Tools web execution were not qualified. Owned cleanup
required TERM; protected/shared guards matched and owned suites were absent.
Installed .18.0/build 28 and registrations retain their identities. Its actual
76-tool/no-web observation is not replaced by the model's contradicted 66 count.
Installed GUI, full web, all models, managed-adapter, other requested formats,
Release and shipment remain open. Prior .36.1 source/wiki closeout is retained
in its external c402bf05… receipt, separately from this correction.

## Preceding 0.36.1 (50) instruction-count qualification

Current source target **0.36.1, build 50** corrects the instruction-package
retained-document count at the common owner before publication/queue mutation.
The original two rejection tests failed normally in **12.245 s**, exit 1/unforced,
with ten assertions: both imports accepted 4,097 documents and changed the queue,
durable store and reopened state. That baseline remains **NONPASS**.
After the guard, the earlier five focused source methods passed in **24.404 s**
on their own pre-version-advance inputs. They are a subset, not extra coverage.
Current source/canonical native each passed the same **45 distinct queue methods**
in **31.726/34.385 s**, normal exit 0/unforced, zero failures/skips, on matching
**464-input 47479210… maps**. All 40 original methods remain byte-identical.
The native run retains eight linkd NSCocoa4097 diagnostics and the malformed-PDF
fixture's CoreGraphics error line; no diagnostic-free claim follows.
CLI/app compilation passed in **0.990/0.886 s**; ordinary Debug/strict signature
in **25.736/0.138 s**, normal exit 0/unforced. The .36.1/50 candidate cbb9f95c…
binds seven binaries and the same 464-input map; its native CLI reported 0.36.1
in **0.614 s**. Previous .36/.35 seven-binary candidates and protected three
inputs remained unchanged. Initial-document G3 source/native each passed one
separate method in **1.587/1.907 s**, normal exit 0/unforced, on that same map.
The 45 owning methods plus one G3 method yield **46 distinct methods per route**, not one 46-test run;
the earlier focused five adds no distinct methods. Native G3 retains destination
and DVTAssertions warnings. Initial hygiene/whitespace passed in **0.654/0.135 s**,
normal exit 0/unforced. Exact source/wiki delivery remains pending for this phase.
No generic archive/SQLite writer, installed GUI, public-import latency, model,
full-web, all-model, native-extractor shutdown or shipment acceptance follows.

## Preceding 0.36.0 (49) BMP qualification

Current source target **0.36.0, build 49** adds bounded BMP, preserving
PNG/TIFF/JPEG/GIF/WebP. This current section records BMP evidence separately
from preceding .35 source/candidate/model receipts and their immutable inputs.

The missing-feature baseline executed one BMP method and failed normally in
**5.746 s** with `invalidFormat`; that original failure remains **NONPASS**.
The eight new BMP methods and one existing catalog method then passed in
**13.457 s**, normal exit 0/unforced, zero failures/skips. Focused nine is a
subset of the owning selection and adds no distinct coverage.
Owning source **233 distinct methods** passed in **77.769 s**; canonical native
passed the exact same **233** in **76.830 s**, zero failures/skips, normal exit
0/unforced. Both exclude G3 and bind the same **464-input 0f204bd3… map**.
CLI/app compilation passed in **0.894/0.894 s**. Ordinary Debug and strict
candidate signature passed in **26.025/0.140 s**, normal exit 0/unforced, on
the same source map. Signed App/CLI wire controls passed in **1.264/0.799 s**,
normal exit 0/unforced: **34 native responses/32 tool frames/10 artifacts**
per route. Qwen passed in **32.566 s**, normal exit 0/unforced: three actual
Low-mode API responses consumed two selected native write/read results,
**8 native responses/6 tool frames/2 artifacts**, with a strict four-scalar
metadata ACK. The separate external native candidate-artifact consumer compiled
in **1.969 s** and passed in **0.364 s**, normal exit 0/unforced: **seven
BMP/PNG pairs/fourteen native images**, matching sRGB profiles/premultiplied
renders and one release callback per provider.
Initial-document G3 passed once in source/native (**1.439/1.767 s**), normal
exit 0/unforced, zero failures/skips, on the same **464-input 0f204bd3… map**.
The exact owning 233-plus-one G3 unions match at **234 distinct methods per
route**; this was not one 234-test invocation. Initial hygiene/whitespace
passed (**0.679/0.136 s**), normal exit 0/unforced. Repeated focused/G3
checks add no distinct coverage.
The native owning run retains eight linkd NSCocoaErrorDomain4097 diagnostics;
the native G3 run retains DVTAssertionsWarning IDELaunchSession.m:395.
Final-document G3 source/native one each passed (**1.535/1.748 s**);
hygiene/whitespace passed (**0.672/0.132 s**), normal exit 0/unforced, on the
same 464-input map. These repeated G3 checks add no distinct methods.
No diagnostic-free claim follows. Later document rechecks and exact source/wiki
publication, readback and synchronization require separate external receipts;
this checkpoint claims no unrun result.

The original ImageIO BMP/ICO collection remains NONPASS because nine ICO
encodes failed. A separate whole-PNG ICO-wrapper native collection also remains
NONPASS because nine decodes returned no detected ICO type/count zero; only the
examined 256×256 case passed. These are separate attempts, not a diagnosed
dimension rule. A third DIB+AND native probe also remains NONPASS: nine of ten
DIB cases failed, only opaque 256×256 passed, and two public type-hint controls
preserved the 1×1 failure/256×256 pass; no dimension/length cause is established.
ICO, audio, archive/SQLite and other requested formats remain
open. Pre-cancel tests do not prove native-call preemption; common-writer
late-cancel-before-rename/revocation remains unexercised source E2.
The installed .18.0/build-28 application and registrations remain unchanged.
Installed GUI, production managed-adapter, full web, all models, Windows
interoperability, Release and shipment remain open.

[BMP contract and gates](NATIVE-IMAGE-WRITING.md).

## Preceding 0.35.0 (48) WebP qualification

Current source target **0.35.0, build 48** adds bounded lossless WebP, preserving
PNG/TIFF/JPEG/GIF. Owning source **225 methods** passed in **75.739 s**, zero
failures/skips; raster 40 includes seven WebP methods. The same seven focused
methods are subsets, not additional coverage. Owning selections exclude G3;
separate initial-document G3 passed once in source/native (5.514/5.334 s).
CLI/app **0.900/0.893 s**, ordinary Debug **26.412 s** and strict signature
**0.143 s** passed on the receipted **464-input ce81874f…** map, before the applied G3 test-only transition to 6dcfd15c….
Strict candidate `native-webp-native-candidate-0350.json`, SHA
`750371a30b90fea43d66a8b40bc4021a0afe60a6df1404d0979bf8e7da554ade`,
binds .35/48 Debug, seven current binaries, three protected inputs and the
unchanged preceding .34 candidate. It qualifies no installation.
Canonical native **225** passed in **75.173 s**, matching the exact source set.
Signed App/CLI each passed **15 groups/32 responses/30 tool frames**, full EOF;
three WebPs/three PNG references/TIFF/JPEG/GIF each passed independent file inspection.
Actual Qwen completed three normal Low responses/two consumed write/read results,
acknowledging exact 194-byte/2×2 metadata. Seven production native WebP/PNG
comparisons passed. Actual 225+G3 set comparison establishes matching **226
distinct methods** per route, not one 226-test invocation or added repeat coverage.
External seven fixtures/fourteen native-synthetic/twenty-one parser controls
retain separate mechanism scopes; the original missing-feature failure remains NONPASS.
Middle-loop cancellation and common-writer late-cancel/revocation E2 are open.
Final-document G3 source/native one each passed (**1.438/1.867 s**), adding no
distinct methods; hygiene/whitespace passed (**0.673/0.133 s**), normal exit 0/unforced.
Exact source/wiki publication, readback and synchronization outcomes are retained in external closeout receipts.
Installed GUI, production managed-adapter, full web, all models, other formats,
Release and shipment remain open.
[WebP contract and gates](NATIVE-IMAGE-WRITING.md).

The 225/build/candidate/wire receipts retain ce81874f…; root applied only two
expected G3 literals, producing separate test-only map 6dcfd15c…. All other 463
inputs, production/resources and graph are unchanged. The candidate retains its
earlier test source. Separate initial-document G3 passed once in each route on
6dcfd15c…; no earlier candidate or owning-test receipt is rebound.

## Preceding 0.34.0 (47) GIF qualification

Current source target **0.34.0, build 47** adds bounded binary-alpha single-image
GIF, preserving PNG/TIFF/JPEG. Source 218 (72.701 s) plus separate initial-document
G3 one (1.526 s) and canonical native 219 (72.081 s) passed with matching **219
distinct methods**, zero failures/skips. Raster 33 contains nine GIF methods;
focused 32/header-one checkpoints are earlier subsets, not additional coverage.
CLI/app 0.899/0.895 s, ordinary Debug 27.360 s and strict signature 0.129 s passed.
Signed App/CLI each passed ten groups, twenty responses/eighteen tool frames,
including nine negative calls and actual 32×64 cancellation. All seven production
GIFs passed independent GIF89a/LZW/full-EOF/exact-binary-alpha checks. Zero opaque
RGB difference applies only to the examined fixtures; general palette loss and
hidden RGB limits remain. Qwen completed three normal Low responses, consumed two
actual write/read results and acknowledged exact 62-byte/2×2 metadata.
The 105 external parser/synthetic-owner controls are separate from the 219 methods
and 35 external mechanism encodes. The same 464 source inputs, seven current
candidate binaries, three protected inputs and preceding .33 candidate seven
remained unchanged. Destination/DVT, NECP and linkd diagnostics are retained;
no diagnostic-free, performance or lifetime claim follows.
Root qualification `native-gif-root-qualification-0340.json`, SHA
`a46adb4acd70ad28d78fd654ae49b2314fa67038c9657c7c5a6f990340677c98`.
Final-document G3 and exact source/wiki publication, readback and synchronization are tracked in external closeout receipts.
Native-call preemption and common-writer late-cancel/revocation E2 remain open.
Installed GUI, production managed-adapter, full web, all models, other formats, Release and shipment remain open.
[GIF contract and receipts](NATIVE-IMAGE-WRITING.md).

## Preceding 0.33.0 (46) JPEG qualification

Current source target **0.33.0, build 46** adds opaque lossy JPEG to
`image_write`, preserving PNG/TIFF. Native mechanism controls, matching owning
source/canonical native 210-method selections and direct CLI/app/ordinary Debug
builds passed on the same 464-input map. The one-method absent-feature baseline
remains NONPASS; focused 24 is a subset of 210, not additional distinct coverage.
Strict candidate, signed App/CLI controls, independent raw JPEG inspection and Qwen API consumption passed.
Actual signed .32/.33 App catalogs each preserve 84 tool names; only the
`image_write` JPEG descriptor changed. This is separate from installed .18/76 below.
Final-document G3 passed in source and native. Source/wiki publication, readback and synchronization are tracked in external closeout receipts.
Native-call preemption and late-cancel-before-rename/revocation common-writer
behavior remain unexercised (the latter source E2 only). Installed GUI, production managed-adapter, full web, all models, other formats, Release and shipment remain open.
[Contract](NATIVE-IMAGE-WRITING.md).

A fresh October 8 installed LM Studio GUI status diagnostic used
`qwen/qwen3.8-27b`. The returned status and both actual model-generation
catalogs contained **76 tools**, with `web_search`, `web_fetch` and `web_render`
absent. Qwen's final count of 66 is a counting error; its absence-of-web statement
is supported. The returned version was `0.18.0`; build `28` was independently
read from the unchanged installed Info.plist, not returned by `get_forge_status`.
No web request was dispatched. This is a scoped status/catalog observation,
not new-candidate, full-web, all-model or installation acceptance. Receipt:
`installed-web-catalog-fresh-status-readonly-0320.json`, SHA
`c863cab657c0cd33bbc278a7f6719ddef54472022e439117aaf8bec3d90e89db`.

## Preceding 0.32.0 (45) TIFF qualification

Current source target **0.32.0, build 45** adds bounded TIFF to `image_write`
while preserving PNG defaults. Matching owning source/canonical native selections
passed 203 distinct methods each, zero failures/skips; direct builds and strict
candidate checks passed. Scoped App/CLI controls, independent TIFF artifact
inspection and Qwen API consumption passed. The missing-feature baseline stays
NONPASS; earlier fourteen- and 21-method checkpoints retain their tested maps.
Final document G3 passed in source and native. Exact source/wiki publication/
readback/synchronization identities will be retained in external closeout receipts. Installed/GUI, production managed-adapter, full web, all models, other
formats, Release and shipment stay open. [Contract](NATIVE-IMAGE-WRITING.md).

## Preceding 0.31.0 (44) PNG qualification

The preceding source target **0.31.0, build 44** adds bounded PNG writing from supplied
pixels. External opaque/partial-alpha 2×2 probes and independent PNG byte checks
passed. Matching source/canonical native selections passed 198 distinct methods
each, including G3; CLI/app compilation, ordinary Debug and strict candidate
checks passed. App/CLI controls, seven exact PNGs and Qwen API consumption passed.
Final document G3 passed in source and native; publication/synchronization receipts will be retained externally. Other formats,
installed/GUI, full web, all models,
Release and shipment remain open. [Contract](NATIVE-IMAGE-WRITING.md).

## Preceding 0.30.0 (43) ODS qualification

The preceding source target **0.30.0, build 43** adds bounded ODS writing and semantic
cell import. Final source/native 199 each, canonical build/signing and scoped
wire/artifact/Core/Qwen checks passed. Original failures and preceding-map passes
remain separate; broader gates stay open. [Contract](NATIVE-ODS-WRITING.md).

## Preceding 0.29.0 (42) PPTX qualification

The preceding source target **0.29.0, build 42** adds bounded text-slide PPTX writing
and semantic instruction import. Source/native 166 each, canonical build/signing,
App/CLI wire, seven reference artifacts, both retained Core cases and Qwen
consumption passed. Original failed compilation/structural/parser/audit receipts
remain NONPASS. Installed/GUI, full Office/full web, all models and shipment are
separate. [Contract and evidence](NATIVE-PPTX-WRITING.md).

## Preceding 0.28.0 (41) XLSX qualification

The preceding source target **0.28.0, build 41** adds text-cell XLSX writing and repairs
XLSX cell-value import. Owning source/native 124 and CLI/app/ordinary Debug/strict
candidate gates passed, plus 16 App/CLI controls, both retained native Core cases
and three-response Qwen API consumption. Broader product/shipment gates remain open.
[Contract and gates](NATIVE-XLSX-WRITING.md).

## Preceding 0.27.1 (40) shutdown qualification

The preceding source target **0.27.1, build 40** repairs repeated shutdown and preserves retry.
[The shutdown contract](ORDINARY-RUNTIME-CONTINUATION.md#repeated-subsystem-shutdown) records qualified scope and open gates;
separate source/native G3 passed one each, for 212 distinct methods each.

The preceding source target **0.27.0, build 39** adds bounded native plain-text DOCX.
Owning source 154 plus actual G3 passed 155 distinct methods; compiled native 155
passed the same scope, zero failures/skips on unchanged 450 inputs. Current
CLI/app, ordinary Debug, strict seven-binary candidate and canonical graph gates
passed. App/CLI each passed 9 wire cases/16 consumed requests with normal exit 0/full
EOF. Six DOCX artifacts passed independent bounded OOXML/readback; all 8 actual
files passed exact expected native text import. Production Core passed 6 cases:
4 exact nonempty conversions and2 empty originals honestly left unresolved.

Fresh Qwen R2 passed 3 normal responses, 2 actual tool results consumed, actual
Low 3/3, scalar STOP, native6/6 requests and normal observer/collector EOF. Its
3579-byte artifact independently imported 102 exact expected UTF-8 bytes. First
combined Qwen NONPASS 2/3 remains, with its distinct outer cleanup classification.
This is separate API/candidate evidence, not installed-GUI qualification.

The final runtime rollup SHA
`227ee6c77f3e0949a3f538f8342d795aa780814c33aeb6596a110a0e3493daed`
binds source450/candidate7/protected3 and 14 prior manifests/92 named binaries,
all unchanged. Runtime receipts do not demonstrate source/wiki delivery; exact
publication/readback/synchronization identities belong in the external closeout.
Native QoS2/NECP7/PDF-tagging14 diagnostics, first 16 source NONPASS, zero-selected
first G3 and immutable raw-UTF8 control failures remain. Full Office, full web,
all-feature, PDFKit, installed/GUI, Release and shipment gates remain separate.
[Contract, exact receipts and preserved failures](NATIVE-DOCX-WRITING.md).

Preceding source target **0.26.2, build 38** repairs MCP notice-receipt truth.
The skipped and partial EOF baselines each executed one method with one callback
failure. Owning source passed 92 distinct methods (41.535 s, log `972ba7dc…`)
and the same 92 compiled native methods passed (81.689 s, log `97ee779a…`),
zero failures/skips on identical 450-input maps. Their included methods cover
three new EOF/EPIPE cases, complete-packet/durable-ledger parity, web response
budgets, router deadlines, notices and current version agreement. Earlier focused
repeats are not added to 92; three DesktopAttachment methods were not selected.
The native run retains 117 vnode-unlink and 117 invalidated-fd diagnostics,
three NECP network lines and five QoS blocks/four source warning lines.
Only a private test controller priority line changed afterward. The same one
source/native method passed (5.590/5.567 s, logs `c926a8c9…`/`ef4892e0…`)
without QoS/source warnings on the final test map; all 449 other inputs stayed
exact. The original 92-case receipts keep their original test hash. Other
Stjornarvald notice and DiagnosticLog warnings remain open; no ordinary GUI
inversion is established. CLI/app and current version/graph checks passed. Final
ordinary Debug confirmation passed (1.552 s, log `531aad8a…`) with strict deep
signing for seven final identities. The initial .26.2 candidate was superseded:
four signatures/identities changed and its failed unchanged-candidate guard is
retained. Thirteen preceding-phase manifests/85 binaries and three named
protected file identities remained exact. Synchronous pre-dispatch deadline
receipt is not directly forced. No installed acceptance,
host acknowledgement, cache-lifetime or warning-free runtime claim is made.
[Contract and gates](WEB-RESPONSE-BUDGET.md#notice-receipt-truth-follow-up).

The preceding source target **0.26.1, build 37** repairs web response-budget accounting.
The signed .26 baseline measured escaped-ID text/base64 frames of 2,477/2,481
bytes against 2,048, with valid page prefixes/SHA/cursors and normal zero exit/
full EOF. The final 139 distinct source methods (88 owning + 51 real shared
parity) and the same 139 compiled native methods passed without failures/skips
on the same 450 inputs. Unmatched ProjectContextTests/WebRenderToolTests filter
names get no credit; actual ProjectContextIntegrationTests/WebRenderProtocolTests
were exercised. Ordinary Debug build/strict signing and all four native wire
cases passed: escaped first pages measured 2,047 text / 2,041 base64, ordinary
sizes unchanged, helper normal0/full EOF. The native run retains 116 SQLite
vnode-unlink and 116 invalidated-fd diagnostics, 20 unconnected-network lines
and three QoS blocks with two source warning lines. Their separate repair is
open; this is not warning-free runtime qualification or an installed-failure
claim. Model completion remains OPEN/NONPASS. The ordered content-block R4
repeat verified two actual pages, but its final API worker hit the 90 s deadline
without a consumed final report. Original/R2/R3/R4 NONPASS receipts are retained.
[Contract, exact receipts and scope](WEB-RESPONSE-BUDGET.md).

The preceding source **0.26.0, build 36** implements ordinary runtime job reference
continuation. Earlier affected source checks passed **309 distinct methods**:
154 Continuity + 153 Runtime in the owning-area command, then the exact Manager
parity and version method in a separate command. Both incremental SwiftPM
products and the ordinary canonical native Debug build passed on unchanged
450-input maps. Native 309 passed, zero skips/failures, with three QoS
diagnostics. Only two test dispatch priority lines changed afterward; source 4
and native 4 passed without warnings and ordinary Debug was confirmed on the
later map. Strict Debug signing/build binding passed for seven binary files on that
earlier 450 map. Two isolated native MCP scenarios passed, with 33 accepted jobs
and 56 complete LF responses. The first Qwen fenced-JSON NONPASS is retained;
a fresh Qwen API case passed three rounds/four consumed tool calls, exact
job/output/authored-task checks and normal stop. These scopes do not qualify
installed GUI successor creation, ACK or seal. A later isolated two-helper E0
baseline failed the live-owner contract: fallback status interrupted the
primary's still-live `/bin/sleep 30` job after 0.713 s, with runtime_owner_restarted,
the exact primary parent alive and both streams unavailable. Collection
succeeded; that receipt remains NONPASS and supplies no installed-topology failure claim.
The runtime owner repair is now applied. The final source selection passed
**321 methods** without failures, skips or compiler warnings on its unchanged
450-input map. The separate ordinary canonical Debug build passed in 24.992
seconds. The same **321 native methods** passed without failures/skips, retaining
one existing DiagnosticLog:64 runtime QoS warning. Strict Debug verification of seven binaries
and build binding, plus repeated signed live-owner, warm-crash and two
continuation cases passed on the final map. Fresh Qwen consumption passed three
actual Low/API rounds and four verified calls with exact job/output/task recovery
and no replay. Earlier passes retain their earlier maps. Exact direct publication and synchronization revisions are retained separately
in `runtime-continuation-publication-and-synchronization-026.json` after the update.
The final source 321 count is Continuity 154 + Runtime 165 + actual Manager 1 + G3
one; focused invocations are included rather than added to it.

The installed .18 case created/acknowledged a successor but omitted the submitted
UUID. Manual ID delivery recovered completed/exit0 and full retained stdout/stderr
EOF without replay. The original isolated regression executed one test/one failure
at its UUID assertion; the first repair passed one method. Its two new fixture
warnings were corrected; the later focused 24 methods passed without warnings.
The first owning-area NONPASS remains **307 tests/41 assertion failures** in two
pending-output fixtures, including historical Manager 1 and Runtime 153 passes.
A new old-checkpoint fixture then failed compilation at a non-Equatable assertion;
after four field comparisons, its old-reuse baseline executed one test with
14 assertion failures. These failed receipts keep their original maps.

The budget guard correction and two genuine unavailable-reader fixtures passed
all three selected source methods, no skips/warnings. A separate reader starts
before any publisher job; one shared durable binding and a real publisher process
exercise output unavailability without the reader owning the spool. All original
error/counter/loop/handoff/block/running/cancel assertions remain, while available
live empty snapshots stay supported. The following comment-only ToolRouter edit
is included in the later current source map. The repaired owning-area command's
unmatched Manager selector selected no Manager tests; the separate actual
Manager+G3 command passed both, completing the **309 distinct source passes**.
Exact counts, commands and hashes are in [the continuation record](ORDINARY-RUNTIME-CONTINUATION.md).

Source references are bounded to 32 native attempts/16 KiB per logical epoch,
with actual chosen UUID admission before CP COMMIT, one-use epoch/full-grant
fencing and exact-packet authorized status before reset. Missing rows remain
unresolved without replay. Fresh/current unsealed saves merge current references;
sealed or earlier-origin same-ID edits retain prior references. Budget reuse
requires an unsealed eligible origin; otherwise a fresh ID clones authored fields.
Automatic finalized status uses the existing `handoff_ready` default; the original
completed authored checkpoint remains unchanged. No schema/journal/job scan or
GUI-instruction inference is added. The graph receipt verifies sixteen changed
Swift inputs in existing targets, retaining membership/workspace with only the
canonical twelve marketing/sixteen build settings changed.

Existing .25 receipts retain their identities. Installed .18, all 54 capability
themes, PDFKit, full-web, all-feature resource acceptance and shipment remain open.

The preceding **0.25.0, build 35** repairs native PDF text/layout and adds a bounded
complete tagged-text path to instruction imports and policy-source indexing.
On the original PDF product snapshot, the corrected owning-area selection passed
101 source methods with no failures or skips on 450 unchanged inputs. This
includes nineteen writer methods, fourteen reader methods with 53 finite raw cases, both durable consumers and
existing queue/catalog/tool/PDF coverage. The earlier 35/84 source successes and
CLI/app/ordinary Debug build predate final reverse-field/current-version changes.
The first enumeration-only Limits patch remained NONPASS (101 methods, 100 passes,
one failure); presence-aware validation then passed the original negative method
and the corrected full selection. Kids correctly declined. All earlier pure-PDFKit,
BOM/dangling-key, annotation/form and mixed-order failures remain preserved.
Final CLI/app builds passed in 0.893/0.892 seconds and ordinary canonical Debug
compilation in 5.261 seconds on 450 unchanged inputs. The marker regression passed
one source method; the compiled native selection passed 102 tests without
failures/skips in 44.409 seconds. Strict Debug signing/build binding passed for
seven identities. Release compilation passed in 149.056 seconds and strict
verification passed for five identities. Both candidates generated eight controls
plus two source negatives, each consuming fourteen LF-inclusive responses with
normal zero exit/full EOF.

Both unchanged control PDFKit validators passed seven of eight controls but retain
the whole mixed-script order NONPASS. Each profile's ten pages had zero measured
bounds outside MediaBox; native PNG review covered five Debug, ten Release and two Qwen
PNG pages. Qwen used
both PDF tools in two API rounds with two observed Low templates and normal stop. Its separate
PDFKit validator passed conversion but failed the written whole sentinel across
a layout line break. Both compatibility gates remain OPEN. Independent r6 semantic
validation passed all 82 controls (fourteen admissions, sixty-eight whole fallbacks)
and all eight Debug, eight Release and two Qwen artifacts with original scalar
markers/page targets. Its external operand ceiling increased from 4,096 to 32,768
after the retained r5 Debug/Release three-page quota failures; r5 Qwen passed two
of two. The original 80 PDF bytes/expectations remain unchanged, and two new exact
boundary controls qualify the revised independent limit. Production also charges
structure/reverse arrays, so identical numerical caps do not prove counter parity.
The PDF source/wiki checkpoint was published and synchronized; all original
PDFKit and r5 failures remain retained.

The original native compiler warning at `PDFWriterTests.swift:85` remains
historical E2 XCTest self/mutable-fixture evidence. A later test-only correction
captures an immutable root URL and uses stateless helpers. Its freshly compiled
UTF-8 regression passed one native test in 5.978 seconds with no compiler
warning/error; the normal writer selection passed all 19 methods in 3.074 seconds,
zero failures/skips, normal terminal zero/full EOF/unforced. The focused case is
included in the 19, not an additional method. All 19 identifiers and 96 existing
assertion lines remain, with one new fixture unwrap. Only PDFWriterTests.swift
changes within the 450-input map; the other 449 source/configuration/graph inputs
and product 0.25.0 (35) remain unchanged. Twelve prior Debug/Release binary
identities and three protected inputs remain unchanged; original 101/102 and
artifact receipts keep their original test hash. No runtime race, production/UI
reachability or new product-candidate qualification is claimed. This later
test/documentation closeout was delivered and synchronized at source
`5ff5559ad02192a90a4887154f48e38c81fa54fe` and wiki
`3dc576814d2bafdaa2ff303e5011072026e0a378`, both clean with 0/0 divergence.
`native-pdf-capture-publication-and-synchronization-025.json` retains the exact receipt.
API candidate evidence is separate
from the active GUI and installed deployment.
Accepted ActualText is not glyph proof, standards-complete tagging or arbitrary
metadata truth; the native root's unresolved optional-field ambiguity is explicit.
[Native PDF contract and evidence](NATIVE-PDF-WRITING.md) records exact receipts,
limits, converter provenance and unchanged fallback/durable compatibility.

## Preceding 0.24.0 (34) listing receipts

The preceding source **0.24.0, build 34** adds opt-in `fs_list` continuation while
preserving path-only listing. The unchanged signed 0.23.0 candidate reproduced
three owned-file cases: path-only returned three, undeclared `limit: 1` still
returned three, and 1,001 names returned 1,000 with truncation and no cursor.
All seven native responses were consumed, with normal zero exit/both EOFs and
unchanged 445 source, seven candidate and three protected inputs. This is
baseline evidence of the missing capability, not qualification of the new paging.
Two source input baselines also failed: one raw fractional token survived
integer rounding, and one numeric path returned the owned sentinel after path
normalization. The corrected interim source selection executed 34 tests with
four failures (one unexpected), terminal 1; all four selected MCP checks and the
routed numeric-path check passed. That selection, a later 35-case alias failure,
the initial compiler failures and the fractional-maximum-bytes wrong-error
baseline remain NONPASS. The final frozen 447-input selection passed 173 source
tests and the same 173 compiled Core tests, zero failures/skips, with final
CLI/app builds and signed Debug/Release builds passing.

Debug and Release listing each passed 35 cases/52 responses across two normally
exiting native parents, including exact recovery of 1,001 names in eight pages
and LF-inclusive escaped-name budgets. Each profile also passed renderer CLI
35 cases/39 responses and app ten cases/14 responses. Qwen used the Debug
candidate for the initial one-entry page and two continuations using the previous
returned cursor, then stopped normally after four model requests; the scoped
observer saw Low in 4/4 events.
All frozen source/artifact/protected guards passed. Required policy notices
were covered by source final-frame tests but absent from the native matrices.
Five compiled test-host QoS warnings at diagnostic drains are separate evidence,
not an established ordinary GUI warning defect. Installed, notice-bearing runtime
and broad filesystem gates remain open in [the listing record](FILESYSTEM-LIST-PAGING.md).

The separate renderer LF boundary regression failed 3,730 > 3,729 bytes. Its
minimal final-fit correction passed all 17 source `WebRendererServiceTests`,
terminal zero without timeout/truncation/forced cleanup. New Debug/Release
renderer MCP matrices measure actual LF-inclusive bytes. Published 0.23.0
JSON-only receipts remain unchanged and are not reclassified.

## Preceding 0.23.0 (33) native renderer receipts

Published preceding source **0.23.0, build 33** adds native JavaScript snapshots and MCP
response deadline propagation. Debug passed 130 compiled cases and 35 actual
MCP cases; the signed app executable passed ten core cases. Qwen consumed the
real renderer result and stopped normally with observed Low in both requests.
Release compilation/signing and the same 35-case MCP matrix passed; its app
executable also passed ten core cases. Installed acceptance remains open in
[the renderer record](NATIVE-WEB-RENDERING.md). The preceding
0.22.0 binary-web checkpoint passed 41 distinct affected source cases and 17
signed-native cases in [its record](BINARY-WEB-AND-QWEN-FILES.md).
The preceding [0.21.0 inventory](RUNTIME-INVENTORY.md),
[0.20.0 Qwen follow-up](QWEN-FOLLOWUP.md) and
[0.19.0 project/web feature](PROJECT-WEB-QWEN.md) records retain their exact
tested inputs. The repair and UI receipts below retain their older source,
candidate and installation scopes; they do not qualify this new slice.

## Preceding 0.18.0 (28) repair receipts

**Published owner checkpoint — 0.18.0 (28).** The source and wiki were
published under the owner identity and both local checkouts were synchronized.
The recorded follow-up at that checkpoint was the owner's build, notarization,
installation and installation report. The actual managed policy mission remains
**unverified** after a harness preparation failure before model activation.
Installed and all-feature acceptance remain open. [Published references and limits](LMSTUDIO-RUNTIME-REPAIR.md#owner-publication-and-installation-checkpoint).

Managed policy feedback and source replay now pass **93 affected source cases**
(two disjoint selections: 65 + 28, zero failures/skips) on `5af17b77…`, including
the original notice-bearing replay failure. Prior baseline, compiler and
61-pass/one-failure receipts remain NONPASS. Fresh Debug13 reached native build
success but retained a cleanup NONPASS; a separate incremental confirmation
passed unforced. Both targeted native XCTest regressions, post-test five-role Debug
identity and settings now pass. The actual managed notice/correction mission
remains unverified. [Evidence and limits](LMSTUDIO-RUNTIME-REPAIR.md#managed-policy-feedback-and-source-replay--source-checkpoint).

The separate **Forge-owned saved-count rollover mission passed** on retained
`e3762543…`/v11b inputs: five accepted provider turns, four successful reads,
automatic rollover at count 3, same-handoff V2 acknowledgement and predecessor
seal, one successor marker read and completed feedback. Native validation reached
completed revision 16; after a 10.072-second stable window, ordinary APIs restored
count 200 and output limit 4,096, then Manager exited zero with full EOF and no
forced cleanup. Earlier NONPASS receipts remain unchanged. This does not qualify
ordinary GUI rollover, policy comprehension, crash, installed or all-feature
acceptance. [Evidence and limits](LMSTUDIO-RUNTIME-REPAIR.md#forge-owned-saved-count-rollover-mission--pass).

Retained `80f542fa…` workflows include a typed Simulator fixture pass (two
actual iOS tests, owned-device cleanup) and independently reconciled actual
LM Studio build/one-XCTest/xcresult/production completion proof. The original
model harness stays **NONPASS**; later provider/policy checks were not reached.
Four subsequent corrections pass the same **six source controls** on
`e3762543…`, zero failures/skips. Earlier negative receipts remain retained;
the four affected source classes report **115 passed/four explicitly skipped/
zero failures** (119 started). Skipped native package/candidate/older-peer controls
are not passes.
Fresh `e3762543…` native evidence now includes a passing Release build,
a separate passing **incremental Debug confirmation**, four settings queries and
30 five-role signature controls. The first Debug capture stays **NONPASS** after
owned-helper SIGINT cleanup; the confirmation is not a fresh-compilation claim.
Debug CLI `get-task-allow` is true; all five Release roles remain false with
existing distribution signing. Native Core **6/6 controls** and two separate signed-candidate controls passed;
the area's four historical skips remain. Scoped actual-model signed-CLI LLDB/
production completion independently reconciles positively; original LLDB probe receipts remain **NONPASS**. After-provider/target-after evidence is absent;
remote quiescence and broader feature acceptance are not claimed.
Broader policy/debug, GUI, ordinary rollover, crash and installed/all-feature
acceptance remain open. [Exact scopes and evidence](LMSTUDIO-RUNTIME-REPAIR.md#typed-simulator-and-managed-xcode-workflows--scoped-evidence).

The later CLI-Manager GUI, second 8,192-token mission and actual-model LLDB
attempts remain **NONPASS**; partial count Save/Reload and debugger dispatch do
not close their remaining gates. See [the latest repair evidence](LMSTUDIO-RUNTIME-REPAIR.md#latest-gui-second-8192-token-and-model-lldb-attempts--nonpass).

The preceding checkpoint's first **8,192-token actual-model attempt remains NONPASS**. It
reached the saved-three-call trigger, same-handoff acknowledgement and predecessor
seal, one successor marker read and its completed feedback. The protected-process
count guard then rejected the paused-stability check; cleanup sent one owned
SIGTERM. Stability, ordinary shutdown, restoration and final inventory/coherence
gates did not complete. Later ten-process parity does not requalify that run or
identify the initiating cause.

The preceding ordinary GUI attempt also remains **NONPASS**. Root's retained CUA
summary records default 200, stepper 4→3, Save 3 and unsaved 7→Reload 3; API/disk
captures agree. Provider output Save/Refresh, restart persistence, restoration and
ordinary Quit remain unverified after SkyComputerUseService failures. Three crash
reports name that service/SIGTRAP; its triggering mechanism and any Forge
accessibility role are unknown. The summary is not raw AX export. Prior source,
native and negative receipts retain their scopes; exact evidence is in the repair
record. Neither partial result qualifies ordinary GUI rollover, actual-model
Xcode/LLDB, Simulator XCTest, crash recovery or the installed product.

The preceding **private native Stjornarvald v10 replay passed** in 10.182 seconds
on the same `80f542fa…` inputs. It detected the declared production Python fixture,
presented its notice over MCP and recorded correction after membership removal;
resource-only JavaScript stayed advisory, alias roles raised the native finding,
and an unavailable graph preserved history. Manager and both MCP processes
returned zero with full captured EOF and unforced cleanup; 439 inputs, five
candidate binaries, ten protected identities and registration remained unchanged.
Automatic coverage is still **one of 15 indexed rules**, with 14 guidance-only
rules. This private detector/correction/transport fixture establishes no model
comprehension, policy GUI, installed or full-policy compliance; historical job
page EOF receives no native producer-EOF credit. Exact evidence is in the repair
record.

The preceding `80f542fa…` checkpoint has both source and signed native
validation. Full source v14 executed **2,310 cases: 2,297 passed, 13 explicitly
skipped, zero failed**; both Swift products built. Canonical native v10 Debug
and Release builds returned zero with full EOF and unforced cleanup. The Debug
selection passed **49 Core plus two app-hosted cases**, with no failures/skips;
all four build/test captures retained the same 439 inputs. Both configurations'
five roles passed all **30 signature/metadata/entitlement controls**, and all
four effective-settings queries passed. These results close that checkpoint's
source, selected native test, build and platform-identity scopes. Fixture/loopback and
view-model controls do not qualify actual-model Xcode/LLDB, a larger-output
LM Studio mission, onscreen GUI/ordinary rollover, Simulator XCTest, crash or
installed acceptance. Those gates remain open; the 13 source skips receive no
pass credit. Earlier checkpoints and all negative receipts retain their scopes.
Exact receipts and binary identities for that checkpoint are in the repair record.

A subsequent settings/compatibility checkpoint at source `80f542fa…` passed all
**14 focused cases**, native zero, no failures/skips, full **7,073-byte** EOF.
It covers output defaults/omission/persistence and CAS, malformed/authenticated
loopback updates, view-model Save/Reload and unsaved-action gating, immutable
REST-fixture 8,192-token probe/root/continuation bodies and accepted-receipt replay,
and budget headroom/inherited-ceiling checks. The six ordinary source classes
then selected **168 cases**: **166 passed**, **two explicitly skipped**, none
failed; native zero, full **52,355-byte** EOF. Both retained all 439 inputs and
finished unforced with no owned survivor. The two opt-in skips are the live
LM Studio fresh-root/continuation and disposable real-Keychain tests; neither
receives pass credit. This adds deterministic source settings/HTTP/view-model
coverage to the earlier pending checkpoint below. It does not qualify an actual
onscreen GUI, larger-output LM Studio run, refreshed full suite/native candidate,
Xcode/Simulator workflow or installed product. The empty-response cause and full
mission remain open; exact methods, receipts and scope are in the repair record.

A later source slice adds a saved **Maximum output tokens** field to the Provider
form: default **4,096**, range **1–65,536**, including reasoning and the answer.
Legacy configurations without this field use 4,096; explicit saved limits are
preserved. An omitted update preserves the saved value. The existing revision check and busy guard remain in place. This field is
an immutable requested transport limit, not a measured model/service ceiling.
The source repair carries it through capabilities so ordinary budget hooks retain
the same output reserve after provider/tool observations and evaluator restart.
Two REST-fixture regressions passed after their baseline failures; the broader
selection passed **33 REST cases plus one configuration-boundary case**, with zero
failures/skips, native zero, complete **11,351-byte** EOF, stable 439 inputs and
unforced cleanup. These are source checks at `31dcfd8b…`. Settings API/CAS/busy and
UI parity checks, a refreshed full suite/native candidate, and actual LM Studio
use of a larger output allowance remain pending. The v13/v9 results below predate
this slice; they qualify their retained `c1805d1a…` inputs. The empty-continuation
cause and full mission remain unresolved. Exact receipts are in the repair record.

The latest full source v13 run returned zero in **715.678 seconds**: **2,297**
actual cases executed, **2,284 passed**, **13 explicitly skipped** and none failed.
Exact case identities/statuses, class and bundle counts matched the retained
2,286-case v12 baseline plus 11 added QoS, provider-metadata and catalog cases.
The complete **688,301-byte** output reached EOF, all 439 inputs remained stable
and cleanup was unforced with no owned process remaining. Both v13 Swift product
builds also returned zero with full EOF and unforced cleanup. This is source
compilation/test evidence; the 13 skips receive no pass credit.

Canonical native v9 Debug compilation passed in **54.946 seconds**, native
zero with one build-success marker and complete **512,938-byte** EOF. Its selected
native XCTest capture passed **37 of 37** cases, with no skips/failures, native
zero and complete **718,240-byte** EOF. Both retained all 439 inputs unchanged
and finished without forced cleanup or owned survivors. All five Debug roles
passed strict signature, metadata and entitlement controls, and both Debug
effective-settings queries passed. These results are scoped to source
`c1805d1a…`; fixture-driven XCTests do not qualify actual Apple CLI workflows.

One owned actual-model saved-count diagnostic with threshold 3 reached the same handoff acknowledgement
and predecessor seal, then measured the first observed accepted empty successor
`automatic_continuation`. The completed response had provider transport EOF,
one reasoning item, **4,095 reasoning/output tokens**, and zero text/tool calls
under the unchanged **4,096-token** output setting and **262,144-token** context.
The receipt has `diagnostic_complete: true`, `qualified: false`, and
`failure: null`: the full mission marker/feedback proof was not reached. Manager
shutdown returned zero with both streams at full EOF; settings were restored to
200 and all 439 source inputs, ten protected processes and registration were preserved.
The cause remains unknown; no remote-provider quiescence or zero-extra-generation
claim is made. Current actual-model typed Xcode/LLDB, simulator XCTest, ordinary
GUI rollover, crash recovery and installed/artifact acceptance remain open.
Exact receipts are in the repair record.

Earlier canonical native v8 Release compilation passed in **151.458 seconds**, native
zero with one build-success marker, full **538,533-byte** EOF, stable 439 inputs
and unforced cleanup. Debug xcodebuild also returned zero with one build-success
marker and full **512,934-byte** EOF in **57.345 seconds**, but its capture remains
**NONPASS**: cleanup sent SIGINT to tracked PID 52101. Its first ancestry and
executable path are unknown; this does not establish a Forge leak or hang.
At that v8 checkpoint, native37 and refreshed identity/settings had not run.
The later v9 observations above retain the v8 NONPASS receipt; they establish no
cause for its tracked process and add no process exemption or product repair.
Current model workflow, simulator XCTest, ordinary GUI/crash and installed
acceptance remain separate. Earlier checkpoints below retain their own source
and artifact scope.

The refreshed full v10 source run returned zero in 708.278 seconds: 2,264
actual cases selected, 2,251 passed, 13 explicitly skipped and none failed.
All 32 added repair cases passed; complete 678,541-byte EOF, all 439 stable
inputs and unforced cleanup were independently reconciled. Receipt:
`613906ead4407edafc1d17ca9389214acc54bc22499c36850629823485ea6623`.
Fresh canonical native v6 Debug and Release builds returned zero in 57.907
and 152.060 seconds, with full output and all 439 inputs unchanged. All five
roles passed strict signature, metadata and effective-settings checks in each
configuration. The focused native Core selection executed 32 cases: all passed,
none skipped or failed, with full EOF and unforced cleanup. The hosted bootstrap cancellation case and five Rune reorder cases also passed.
The native rollover UI case passed text edits and increment/decrement actions
at both range boundaries. The current signed Stjornarvald control also passed deliberate violation,
ordinary MCP notice delivery, correction and unavailable-graph history checks.
Automatic detection covers one of 15 indexed Raven rules; the other 14 remain
guidance. The current signed candidate’s `xcode.debug` control passed breakpoint,
main backtrace, continuation and target-zero-exit checks for the unchanged signed
owned C fixture. An actual LM Studio model also built for testing, ran one exact
XCTest, read its passing xcresult and reached a completed managed run. That run’s
receipt remains NONPASS because build-for-testing changed two test-host binary
hashes. Six separate read-only post-build signature, metadata and entitlement
controls passed against the current products. This preserves the original
nonpass and does not establish native producer pipe EOF for that historical run.
These scoped results do not qualify the installed app or shipment.

The subsequent producer-output source repair passed all 16 selected controls
without failures or skips. Managed saved-count source testing reproduced four
invocations and no pending request at limit 3, then passed the same control after
repair. The corrected 14-case selection passed without failures/skips, including
three ordinary file-reopen recovery cases, both source-history replay controls,
successor-session isolation and corrupted-result rejection. The earlier 13-case
selection remains NONPASS at its active-session fixture. These changes postdate
the retained v10/v6 checkpoints. Normal v11 remains NONPASS: 2,286 actual
cases selected, 2,270 passed, 13 explicitly skipped and three migration cases
failed on four stale runtime-version assertions. The corrected lineage selection
passed all four cases. Final full v12 returned zero: 2,286 actual cases selected,
2,273 passed, 13 explicitly skipped and none failed, with all 439 inputs unchanged,
full output and unforced cleanup. Earlier failed receipts remain retained.

Subsequent canonical native v7 Debug/Release builds and five-role signing/settings
checks passed against those inputs. All 26 selected native cases passed without
skips, but the retained log reports a priority inversion in the synchronous
Runtime/Xcode bridge. The actual saved-3 model attempt requested and fulfilled
rollover after three completed predecessor reads, acknowledged the same handoff
and sealed the predecessor. Its overall receipt remains NONPASS because the
successor marker read/feedback did not occur before the deadline; canonical
handoff/replay qualification was not reached. The empty normalized responses do
not establish a provider termination cause.

The bridge now snapshots the caller's effective task priority before starting
its detached worker. Both baseline priority controls failed; all eight repaired
priority/deadline/cancellation/committed-receipt controls passed. Normal Runtime
validation passed 122 of 123 cases with one explicit absent-PowerShell skip;
all 41 Xcode cases passed. Complete output, stable 439 inputs and unforced cleanup
were verified. Full v12 and native v7 predate these two changed source/test inputs.
Fresh native priority validation and current model/artifact acceptance remain
open; exact receipts are in the repair record.

The later provider terminal-metadata source checkpoint passed seven focused
controls and all 31 contract-fixture cases without failures/skips. Accepted
receipts now retain bounded optional response metadata; successful provider
transport completion remains separate from native producer EOF and artifact
paging. The cause of the earlier empty continuation remains unknown.

A retained-app policy catalog shutdown control then reproduced three database
descriptors remaining open after completed shutdown and a still-readable catalog.
After the explicit owner close, both focused closure/reopen cases and all 11
catalog cases passed without failures/skips. The initial path-observer failure,
the Darwin.stat compiler failure and the valid two-assertion baseline failure
remain retained. These are source checks with full output, stable 439 inputs and
unforced cleanup. Full source/CLI/app v13 subsequently passed; canonical v8
Release compilation passed and Debug remains NONPASS at forced cleanup.
Native37, identity/settings and runtime qualification remain pending. Current-source actual provider continuation, typed Xcode
build/test, ordinary GUI rollover, crash recovery and installed acceptance
remain open.

A separate direct owned iOS 26.5/iPhone 17 Pro startup completed bootstatus at
17 seconds; AddressBook migration logged success. All 13 native commands
returned zero with complete output, unforced cleanup and all 32 original devices
preserved. Its diagnostic receipt remains NONPASS because the stall/sampling
window was not reached. No XCTest ran; the earlier stall cause and simulator
XCTest qualification remain open. Exact scopes and receipts are in the repair record.

The retained full v9 source run returned terminal one in 695.156 seconds:
2,261 cases selected, 2,247 passed, 13 explicitly skipped and one failed case
(four assertions). All 29 new repair cases passed. Its failure is the existing
shared-diagnostic bootstrap cancellation test; a focused diagnostic reproduces
`diagnosticHomeMismatch` at `application_graph` before cancellation. Full EOF,
all 439 stable inputs and unforced cleanup were verified. Receipt:
`6d6076055983824c27c26beebcb87a1863e7fe9060036c68c058392e63a00206`.
The subsequent bounded30 original-flow diagnostic observed two same-path
directory-flag mismatches. A local directory-hint normalization in the bootstrap
guard passed all 16 affected source cases and the same30 cancellation/retry flows,
with native zero, complete EOF, stable inputs and unforced cleanup. Receipts:
`0635aa833cd1b2f94ab6f22bf8fe121e5b5b7ab0d4585a00d752dc57ea657ba4` and
`c454287d5857353b2d2fa939ab91335caa684a95f8961be1a147fd9f2b90f3a8`.
Different-home and authority rejection remain exercised. Temporary measurement
code was removed; CLI/app v10, full v10 and scoped native v6 checks passed.
Ordinary candidate rollover Settings Save/Reload/relaunch persistence also passed.
A later forced-reader reproducer failed two incomplete-output assertions; the
subsequent source repair passed all 16 controls. Current native/model producer
proof, simulator XCTest, automatic successor and full artifact qualification
remain open. The failed v9 and earlier fixture attempts are retained.
Separately, one signed owned C LLDB control passed in 0.714 seconds, with native
zero, complete 1,551-byte output, breakpoint/main backtrace/continue/target-zero
observations, unchanged fixture and all 439 inputs, and no forced cleanup.
No signing or authorization was changed. Receipt:
`d7f08063b15514e6af30714f2b013f0bf80702fb212082745c0b3fc2efef28d0`.
This follows observed disappearance of the earlier SecurityAgent process;
the change's cause remains unknown. Refreshed Forge typed debugger/native
validation remains pending, and the earlier failures remain retained.
The later owned paused restart check passed with two normal Manager exits zero,
complete streams and the same handoff/ACK/seal, two tool rows and four turn
identities across a 10.134-second interval. Separately, the actual LM Studio
model ran one Rune XCTest successfully, read both test and xcresult streams,
and returned the correct one-pass summary. Both native jobs exited zero. The
managed run still reached its 900-second limit because project-build and
project-tests completion obligations remained unsatisfied; typed Xcode test
evidence was not recognized. The subsequent typed completion repair passed all
78 Xcode/Queue source cases without failures/skips, terminal zero and full EOF;
all 439 inputs were unchanged. Exact run/job/command/output ownership, cached
summary provenance and same-timestamp ambiguity controls remain enforced.
Build and test obligations stay separate. Current signed native and actual-model
completion checks remain pending. The original 900-second non-pass is retained;
these checks do not qualify crash/GUI recovery.
The latest managed failed-tool repair changes four source/test inputs after the
v8/native v5 freeze. Before repair, three negative cases failed and three
success/legacy controls passed. After repair, all 14 added and all 33 affected
source cases passed with zero skips/failures, terminal zero, complete raw EOF
and unchanged inputs during each capture. Native validation of these latest
inputs remains pending; the earlier artifacts keep their dated identities.
The subsequent Manager settings refresh changes two more existing inputs and
leaves the canonical graph unchanged. Two negative cases reproduced stale 200
settings after a separate owner saved 3; cached recovery passed. After repair,
all three focused cases passed, followed by 288 passes, two explicit skips and
zero failures across 290 Manager/continuity cases. Native exit zero, complete EOF,
unchanged 439 inputs and unforced cleanup were verified. The class receipt is
`8612b2fce5664ac538c657bdb4bc2c9ae2b2ba4564e20e513f06fc8346963007`.
The latest completed SSE checkpoint preserves the public 4,096-event decoder
and applies a private finite 5,120-event Responses budget with independent byte,
output-token and timeout guards. The valid 4,104-frame regression and exact
boundary controls passed. Full source v8 returned zero: 2,202 Core cases selected,
2,189 passed, 13 explicitly skipped and none failed; all 30 filesystem cases
passed. All 439 inputs were unchanged, with full EOF and no cleanup signals.
Canonical native v5 Debug/Release builds and five-role identity checks passed.
The signed Debug CLI executed exactly five SSE tests, all passed, no skips or
failures, native/serve exits zero, with lossless output. The native v3 live
failure's raw-stream validity remains unknown; GUI rollover and SIGKILL recovery
remain separate pending gates. Details are in the repair record.
The isolated native v5 attempt reached automatic provider-usage rollover, then
failed the probe's handoff-digest comparison before SIGKILL. Native Foundation
verified the probe encoding defect; the exact retained packet matches Forge's
canonical digest. Corrected v6 verified its digest but missed the accepted
receipt within the 60-second window. No SIGKILL was sent; both attempts remain
non-passes and crash recovery remains unqualified. The later 600-second
observation captured one accepted, acknowledged successor and a sealed
predecessor, but missed the crash-test boundary. Its automatic continuation
remained an intent without a provider response or tool execution; ordinary
restart/replay and crash recovery were not exercised. The later early migration
sample timed out without a stack, before cleanup; Simulator readiness again
timed out at 300 seconds. Exact owned cleanup preserved all 32 baseline device
rows; Simulator XCTest remains unqualified.
The subsequent same-home ordinary restart completed the exact pending automatic
turn, but its one model-selected `fs_read` returned `not_found` for
`/home/project/successor-only.txt`. The exact-one-marker check failed; stable
replay did not execute. The controller paused before tool-error feedback.
Separately, the actual LM Studio model-to-native Xcode version check passed in
66.462 seconds: five completed provider turns, four actual tool calls, one
native job exit zero, complete 33-byte stdout and empty stderr consumed by the
model, exact final output summary, Manager exit zero and no forced signals.
All 439 inputs, five candidate binaries, 13 original processes and registration
were unchanged. This qualifies only that owned version/output flow.
The later separate ordinary resume completed the original error-feedback turn
and one successful absolute-path read of the exact owned marker. Independent
reconciliation preserved the earlier failed read and H/ACK/seal. Its additional
relative-path assertion failed; settled replay and final comprehension remain
unverified, and both original diagnostics remain non-passes.
The preceding native Compute v3 diagnostic executed one test and failed two
activation assertions in 4.135 seconds, with no skips, native exit 65 and serve
exit zero. Complete output and the startup attachment retain inactive/keyless
state with SecurityAgent PID 55952 foreground; cover variants did not execute.
The initial root absence claim used the wrong `.app` path and is corrected by
the actual `.bundle` process identity. Host authorization outcome and failure
cause remain unknown; Compute acceptance remains open.
The earlier full Swift checkpoint returned exit zero: 2,135 Core cases selected,
seven explicit skips, zero failures, and 30 filesystem qualification cases with
zero failures/skips. The later October 5 source checkpoint passed 19 focused
cases, then selected 505 affected cases: 499 passed, six explicitly skipped,
zero failed. A subsequent adapter protocol checkpoint selected 34 cases:
33 passed, one live-provider skip, zero failed. These are distinct tested input
snapshots. The preceding full Swift run selected 2,181 Core cases: 2,168 passed,
13 were explicitly skipped, and none failed; all 30 filesystem qualification
cases passed without skips. Four playbook guidance bodies changed afterward.
Their fresh scratch-build catalog rerun passed 14 actual cases with no skips,
and its XCTest bundle passed strict signing verification. The initial
incremental rerun failed at a stale outer resource seal; no trust check or test
was changed. Both SwiftPM products build. None of these source checks is native
runtime acceptance.
The later status/storage checkpoint passed six focused cases without skips or
failures. Before the storage fix, three new cases produced 11 assertion failures:
audit and queue initialization recreated defaults, including enabled shell
settings. The repaired cases cover persisted threshold refresh, explicit cached
recovery for malformed/missing configuration, durable SQLite/JSONL audit parity,
queue snapshots, directory permissions and shell opt-out preservation. The
normal seven-class selection passed all 300 cases without skips or failures.
Full v4 then returned terminal zero: 2,187 Core cases selected, 2,174 passed,
13 explicitly skipped, zero failed; 30 filesystem qualification cases passed
without skips. All 439 frozen product/test/graph inputs remained unchanged.
The later live v7 checkpoint changed only the opt-in fixture; its other 438
inputs matched at that checkpoint.
One ownership control passed after correcting its configuration-owned custom
gate to the built-in gate. Failed live v3–v5 attempts retained a reported
coordinator cancellation whose attribution remains unknown. The bounded v5
receipt instead establishes a fixture cutoff error: estimated input 5970 plus
fixed reserve 20480 exceeded its 10240 admitted-total rollover cutoff before
any provider turn. Corrected test-only totals 27648/28672 preserve reserves,
production settings and all original acknowledgement/recovery assertions,
adding an initial-normal control. Live v6 failed its one selected case after
670.805 seconds, without skips: normal preflight and provider-exact rollover
were followed by successor-bootstrap truncation without an acknowledgement or
completed recovery. All 14 protected process identities and the MCP registration
were preserved, with no surviving owned processes. The actual incomplete reason
was not retained. Live v7 passed its one selected case without skips or failures
in 487.293 seconds. Actual provider usage triggered rollover; exact V2
acknowledgement, recovery after the in-process post-commit bootstrap error,
predecessor sealing, one successor tool effect and stable replay passed.
The three Manager phases shared one SwiftPM XCTest process. This establishes
neither a SIGKILL matrix nor ordinary LM Studio GUI rollover. All 14 protected
identities and the MCP registration remained unchanged, with no owned survivors.
The fixture alone uses 4096 output tokens and accelerated thresholds; the
original fixture retains its 512-token default and exact recovery checks.
Later, four semantic classifier regressions produced 39 assertion failures:
ordinary JSON configuration/quoted content overrode typed errors. The local
failure-field repair passed all four cases. The normal transport/adapter
selection passed 51 of 52 cases, with one disabled live skip and no failures.
These later edits changed the plugin and two existing fixture files; the native
v3 freeze differed from full v4 in four inputs, with 435 unchanged.
Full source v5 selected 2,191 Core cases: 2,177 passed, 13 skipped and one failed;
all 30 filesystem cases passed. The failed fixture counted two shell-recorded
PIDs. A separate controlled timing case passed with three identity-validated
children and two recorded PIDs before SIGTERM. The fixture now counts the
observed identities, retains the >2 threshold and original shell-PID cleanup,
and adds cleanup checks for captured identities. Production process control
is unchanged. The corrected focused case passed; its normal class selected
113 cases, with 112 passes, one absent-PowerShell skip and no failures. The
original failed interleaving was not captured. Later full v6 returned zero:
2,192 Core cases selected, 2,179 passed, 13 skipped and none failed, plus all
30 filesystem cases passed. All 439 inputs were unchanged, complete output
was retained and owned-process cleanup required no signals. The 13 skips
remain unperformed checks.
Fresh canonical Debug/Release v3 builds returned terminal zero in 60.309/153.358
seconds with all 439 inputs unchanged during each build. Both configurations
passed five-role strict signatures, metadata, entitlements and effective
settings checks. Release recorded one owned post-build cleanup SIGINT and no
survivors. These candidates predate the later runtime/AppKit test-fixture
changes and Rune reorder ownership repair. The v3 Debug CLI's typed `xcode.run`
executed four actual classifier XCTest cases: four passed, none skipped or
failed, with complete byte output and native/serve exits zero. Typed `xcode.result`
summary and inventory jobs both returned zero, with complete byte output and
normal serve exit. Independent readback verified exactly the same four named
cases, all Passed, with no extras, skips or failures. These checks establish no installation or ordinary GUI
rollover acceptance.
Additional typed build-results and insights queries returned native zero with
lossless output. Build results reported five AppKit actor warnings in the
mixed-format package test. Its `@MainActor` annotation retained every assertion;
the focused case and normal 38-case class passed, then a fresh isolated typed
native run executed and passed that case in 0.321 seconds. Those five Swift
warnings were absent from the complete output; Xcode destination and
diagnostic-setup messages remain separate. Typed build-results, summary and
inventory readback returned zero with complete output and normal serve exit.
The inventory verified exactly this one Passed case, no skips/failures/extras;
the isolated configuration was unchanged.
Three controlled Rune reorder cases failed four assertions when an older
cancelled command returned after a newer successful reorder. A command UUID
fence now rejects the older response and preserves current-command rollback.
All five focused cases and the normal 15-case Rune class passed. Fresh native
v4 Debug/Release builds returned zero in 60.370/158.788 seconds with complete
output and all 439 inputs unchanged. Five-role strict signatures, metadata,
entitlements and settings passed in both configurations; Release cleanup
signalled two exact owned post-build processes and left no survivors. The first
typed Rune selection returned native/serve zero but executed zero tests: it
selected the Core bundle instead of the existing app-hosted bundle. That run is
a nonpass. The corrected v5 selection used the existing
`ForgeConductorAppTests/RuneForgeAppTests` bundle and executed exactly the five
intended cases: five passed, none skipped or failed, in 0.246 (0.248) seconds.
Native and serve exits were zero, with all 581,183 stdout bytes and 590 stderr
bytes retained. Independent raw-output reconciliation verified all five case
starts and passes, no extras, and unchanged 439 inputs.
Full source v7 then returned terminal zero: 2,197 Core cases selected, 2,184
passed, 13 explicitly skipped and none failed; all 30 filesystem cases passed
without skips or failures. Across both targets, 2,227 cases were selected and
2,214 passed. Complete raw output retained 667,794 bytes; independent inventory
reconciliation matched every case and explicit skip. All 439 inputs remained
unchanged, with no owned survivors or cleanup signals. These skips remain
unperformed checks. Full v6 predates these edits.
Removing unreachable fixture setup and stale comments
changed no Continuity assertions; its focused case and normal 138-case class
returned zero, with the final normal summary recording zero failures.
Before those later fixture edits, fresh canonical Debug and Release v2 builds
returned terminal zero with
all 439 frozen inputs matched. All five roles retained the configured signing
and passed strict verification. Each compiled CLI completed typed native Xcode
version discovery with native exit zero, lossless byte output and normal serve
exit zero. The exact app-hosted Rune coverage/unknown-state case passed once
without skips or failures; typed xcresult inspection reported Passed and one
actual test. A separate current Debug/Release identity/version-drift fixture
case passed once without skips or failures. These are scoped runtime receipts.
The preceding native policy v5 qualified real detection, delivered notices, separate
project scopes, resource-review classification and immutable correction
history, with Manager and both MCP helper exits zero. Its separate model notice
v5 interpretation returned a timeout without a completed response. The bounded
v6 request completed in 26.944 seconds with the exact 0.45-confidence review
notice fields and no compliance, blocking or correction claim. The loaded
Qwen instance remained at 262144 tokens before and after. This establishes one
historical notice interpretation, not general model comprehension.
The retained-v9 native round trip passed all three CLI stages with strict
signatures, unchanged startup state, same-ID edit/readback and preserved
synthetic seal metadata. That stopped fixture establishes neither real
successor acknowledgement nor crash recovery. Ordinary GUI rollover/overlap,
LLDB and native occlusion remain open. Simulator v3 build and
boot commands passed, but bootstatus timed out/143 after 300 seconds during
Apple AddressBook migration. No XCTest executed; cleanup removed the owned
device and preserved all 32 baseline devices. The alternate iOS 26.5/iPhone 17
Pro v4 run also built and booted, then timed out/143 at the same migration stage
before XCTest. Its cleanup passed and preserved all 32 baseline devices. The
underlying wait remains unknown. Prior failed attempts remain nonpasses.
The later direct startup control outside Forge reproduced the same migration
wait with inherited unlimited CPU/file-size limits, then timed out at 300 seconds
with exit -15 and complete output. No XCTest ran; exact owned cleanup preserved
all 32 baseline devices. Forge launch/limits are not necessary for this observed
wait; its cause remains unknown. `log help show` returned its documented usage
exit 64 and retained all 2,246 usage bytes; no scoped unified-log query ran at
that checkpoint.
A later owned-device namespace diagnostic again timed out at 300 seconds with
exit -15, complete output and no XCTest execution. Three namespace snapshots
retained the same migration-process identities. Successful narrow log queries
using documented `processIdentifier`/`composedMessage` predicates retained 213
AddressBook migration events, five wrapper AddressBook events and 127 wrapper
default-level events, each scoped to the exact observed PID. The wrapper's
simulator AddressBook authorization was Allowed/Entitled; its later log reported
two remaining XPC transactions. These observations establish no cause for the
unfinished migration and no host-debugger authorization. Earlier truncated
queries remain nonpasses. A bounded sample timed out across owned-device
shutdown and produced no stack. Exact shutdown/delete cleanup returned zero;
all 32 baseline device rows and bytes were unchanged.



<!-- FORGE-COMPUTE-PCB-FOLLOWUP:BEGIN -->
## Compute PCB refinement — verified native scope

**0.17.0 (27)** tightens each Compute board frame to the trace endpoints,
with eight points of pulse clearance. Headings and engine readings sit outside
the board frames. The entire PCB and surrounding Compute panel are much darker
midnight blue, with subdued silver/gold components, trace highlights and
shadowed metal detail. Approved chip sizes/artwork, banks and core effects
remain. Traveling signals have stronger colored bloom and bright centers;
existing route shapes, signal counts, cadence and pause/hidden/stale bounds remain.

The canonical My Mac AppTests selection passed **45 tests**, with zero
failures/skips; **31 SwiftPM tests** repeat cases from that selection. All
**68 PNGs** were individually reviewed and rehashed: **47 genuine Metal
readbacks and 21 separate NSView caches**, with zero blocking findings,
missing reviews or hash mismatches. The matching ordinary Debug build and
strict signature verification passed.

These captures are separate native cache/Metal layers, including a 20-frame
motion sequence. They do not qualify desktop composition, XCUITest,
installation or distribution. Earlier receipts retain their exact inputs.

Detailed source/candidate identities, retained failures and evidence limits
are in [Compute Cores](COMPUTE-CORES.md) and [native QA](GRAPHITE-NATIVE-QA.md).
Exact owner publication/synchronization refs belong to external delivery receipts.
<!-- FORGE-COMPUTE-PCB-FOLLOWUP:END -->

<!-- FORGE-DASHBOARD-COLUMNS-FOLLOWUP:BEGIN -->
## Preceding Dashboard columns — source 81a91a81…

**0.17.0 (27)** uses two independent, equal-width column stacks: MCP Servers
above MCP Tools on the left, Sub-agents above Hot Processes on the right.
Their outer top/bottom bounds align; internal splits follow content. Hot
Processes fills the remaining right-column height. Approved Compute chips,
effects, panel content and accessibility identifiers are retained.

Thirteen public native view methods passed with zero failures/skips, and all
358 PNGs were individually reviewed. The matching My Mac Debug build and
strict signature verification passed; the canonical UI target compiled only.
[Native QA](GRAPHITE-NATIVE-QA.md) records exact source/build identities, separate cache/Metal
layers and retained evidence. The frame and broader qualification records
below remain preceding checkpoints; their executions are not relabeled.
Exact owner publication and synchronization refs are recorded externally.
<!-- FORGE-DASHBOARD-COLUMNS-FOLLOWUP:END -->

<!-- FORGE-COMPUTE-FRAME-FOLLOWUP:BEGIN -->
## Preceding frame refinement — source 2463aa06…

Version/build remains **0.17.0 (27)** for this Unreleased iteration. Compute
frames are smaller and darker; duplicate visible hardware names and activity
badges are removed while exact accessibility identities and states remain.
The approved chips and telemetry effects are preserved. Dashboard omits its
inline Guided Mode banner and guide button; other routes retain guidance.
Workbench Settings labels its existing action **Open Guide**. Sub-agents and
Hot Processes fill the same grid row, retaining its 200-point minimum.

The preceding scoped source manifest `2463aa06…` covers 434 inputs with unchanged
canonical build graph and all 30 resource files. Thirteen native view methods
passed and all 357 successful PNGs were reviewed; the one failed fixture
invocation is retained separately. The matching My Mac Debug build and strict
signature verification passed (candidate CDHash `3b5399f0…`). Separate Compute
checks, their overlapping SwiftPM repeat and exact evidence limits are recorded
in [the Compute phase record](COMPUTE-CORES.md). The `28548a73…` source, 116-test/140-execution and 463-image
receipts below remain the preceding checkpoint, not fresh proof of changed
inputs. Exact owner publication and synchronization refs are recorded externally.
<!-- FORGE-COMPUTE-FRAME-FOLLOWUP:END -->

## Preceding frame-refinement artifact and evidence

The 434-input scoped source manifest is SHA-256
`2463aa065e049627d8c6af3d9188f2258da060fa2d04c4a1e8b0770e4ee777e9`;
current membership/preservation receipt SHA-256 is
`986f6ebcedf629e0b838df81383a0842a6968b762345daa35ef9c2e6c093734a`.
The canonical graph, schemes, package inputs, signing/deployment settings and
all 30 resource files are unchanged. The ordinary My Mac Debug candidate is
version **0.17.0**, build **27**, Apple Development team **9AQ2C2838M**, CDHash
`3b5399f06cb3494d0c63a34efb3b8c210b31abf1`; strict signature verification passed.
Its 33-file identity receipt SHA-256 is
`6c6758064db1177cd39088c89448bf43cdc21a3459afc74adaa2c55fd0ce4dc4`.
This establishes build/signature identity, not a new ordinary runtime workflow.

Fresh public native fixtures passed 13 view methods; all 357 successful PNGs
were opened. One failed fixture invocation remains outside that successful
selection, giving 14 total invocations. The final QA summary SHA-256 is
`633d46de48a1f760d51dca9d63c577544b2d3639660ad810dab7a30bd2e7828d`.
The separate earlier Compute selection executed 30 cases with zero failures/
skips; its 16-case SwiftPM repeat overlaps. Its recorded product dependency was
later overwritten, so source-preservation evidence bounds reuse rather than
claiming a replayable earlier full bundle or one final App snapshot. Exact
boundaries, failed Guide assertion and tested frame/row/guide behavior are in
[Compute](COMPUTE-CORES.md) and [native QA](GRAPHITE-NATIVE-QA.md).

## Preceding qualified checkpoint — 0.17.0 (27), source 28548a73…

**Preceding UI implementation and QA complete.** Source
**0.17.0 (27)**,28548a73… passed 116 distinct production tests in 140 successful
executions, zero failures/skips. The separate native view matrix passed 21 unique
methods in 22 invocations; all 463 selectedPNGs were individually opened and
reviewed. The 15-check/434-inputaudit, matching signed Debug build and four
scoped ordinary workflows passed. Historical failures and unavailable proof
classes retain their exact boundaries. Owner exact publication/readback/
synchronization refs are recorded externally; no installation, notarization,
App Store Connect upload or distribution was performed.

## Preceding Graphite/Compute source and ordinary candidate — 0.17.0 (27)

Preceding 0.17.0 production qualification is **116 distinct tests /140 successful
executions**, zero failures/skips: Compute 29, regression 68 and proper canonical
Provider 33 (24 Provider repeats counted once), plus fresh Core 8/H0(1)/G1(1).
CLI/App SwiftPM compilation and the canonical ordinaryDebug build passed
separately. The view matrix is **21 unique methods /22 successful invocations**
with **463 selected PNGs actually opened**:281 parent caches,166 sheet caches,
14 NSAlert caches and 2 separate production Metal readbacks. All 68 currentCompute
layers and the genuine 20-frame MOV are separate reviewed evidence.

The signed candidate 1a36aa4d…/source 28548a73… passed four manual ordinary
workflows: healthy 16/failure 3 paired exports with privacy/scope; native folder
Select/Cancel/root rejection/save/relaunch; shellOFF/relaunch/ON with real MCP
denial/exact execution. Actual ordinary Settings 900×560 content, all 9 sections,
draft/Reload, six opt-ins/Setup-only persistence/restoration, menus/About and
normal 1440×900@2×Dashboard/Pause/Resume were observed. Ownedcases ended; seven
registration byte sets per case were unchanged and twelve private suite key sets
were empty. This is scoped runtime proof, not installed/remote/shipping proof.

NSViewcaches omitMetal and parent/sheet caches are separate surfaces. All 14
NSAlertcaches omit Cancel captions and have background/destructive-label
artifacts; actual 14 Cancel dismissals/no-mutation assertions passed, while
ordinary alert-button contrast is unqualified by those caches. Physical 1×,
ordinary minimum and Sky sheet-compositor pixels/Close remain explicitlimits,
not extra acceptance gates. Historical failed/zero-selected runner attempts
remain excluded. Required UI implementation/QA is complete; exact owner publication/readback/safe synchronization refs are retained externally.

The [Graphite 30 mappings](GRAPHITE-WORKBENCH.md),
[Compute 32 criteria/18 capture scopes](COMPUTE-CORES.md) and
[native QA](GRAPHITE-NATIVE-QA.md) retain the UI authorities and receipts for that
checkpoint. Its source hash is
`28548a73db312130f02e3c86344725f2aa1efca575901fa0ae3dc223b69eb3d1`.
Exact source/graph/signed candidate identities, production 116/140 receipt and
native 463-image union are retained in those records. Historical rejected art,
failed third/fourth pilots, mixed/native host failures, version-marker failure,
12 current matrix failed attempts and two superseded successful framing
checkpoints remain history; none is counted as current success.

All UI implementation/required QA/documentation mappings are complete in their
named scopes. Exact owner publication/readback/safe synchronization refs are retained externally,
with no self-referential commit edit. Historical
live providers, installation, privileged service and shipment below retain
their separate qualifications.

## October 3 installed bootstrap and export repair — 0.16.5 (26)

The corrected Xcode project identifies the candidate as `0.16.5 (26)`. The
installed `/Applications/Forge Conductor.app` was `0.16.4 (25)` during the
earlier October 3 qualification. Its GUI and embedded CLI failed bootstrap with runtime launch-gate status `-67050`
while strict deep signature verification passed. The installed-framework
probe required Apple Development certificate extension
`1.2.840.113635.100.6.1.12` for all four product roles, although the exported
installation was Developer ID signed. The original Apple Development archive
and installed/exported daemon also had different CDHashes; the installed app
and CLI retained the archive hashes (`installed-signing-policy-probe.log` and
`archive-export-daemon-seal-evidence.json`). The stale seals are a separate
identity defect; the observed bootstrap failure occurred at the earlier
product-signing check.

The mechanisms and corrections are:

- `ForgeConductor.xcodeproj/project.pbxproj` restores manual Developer ID
  signing for the five shipping Release targets and removes the global Release
  `FORGE_DEVELOPMENT_SIGNING` flag. Debug retains automatic Apple Development
  signing. `ForgeFilesystemProtocolConstants.requiredProductCodeSigningRequirement`
  in `Sources/ForgeFilesystemProtocol/ForgeFilesystemProtocol.swift` selects
  the build's exact certificate class; `RuntimeLaunchGate.codeIdentity`
  in `Sources/ForgeConductorCore/Infrastructure/RuntimeProcessSupervisor.swift`
  enforces it. `script/seal_filesystem_daemon_identity.sh` seals the signed
  daemon hashes, checked by
  `SecurityManagerPrivilegedApplicationIdentityValidator.validateSealedDaemonHashes`
  in `Sources/ForgeConductorCore/Manager/ManagerInstaller.swift`.
- Both export controls previously required a completed `AppModel.app` graph.
  `AppBootstrapOperation.start`, `AppModel.bootstrap`, and
  `AppModel.beginDiagnosticsExport` in
  `Sources/ForgeConductorApp/AppModel.swift` now prepare diagnostics off the
  main actor before graph construction and retain the sanitized startup error.
  `ForgeApp.bootstrap(home:clock:diagnostics:)` and `shutdown` in
  `Sources/ForgeConductorCore/Application/ForgeApp.swift` borrow that same
  logger; graph shutdown flushes it, and AppModel owns its off-main close.
  `DiagnosticLog.export` in
  `Sources/ForgeConductorCore/Infrastructure/DiagnosticLog.swift` permits an
  explicit failed-startup export of the bounded live ring when persisted
  history is unavailable, disclosing that omission in JSON and Markdown.
  Existing bootstrap calls and the two-argument `DiagnosticRecording.export`
  source contract remain available; exact identifier, team, certificate, and
  daemon-hash protections remain enforced.

For the commands below, `E` is
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-03-bootstrap-export`;
commands run from `/Users/flynn/GitHub/Forge-Conductor-MacOS`. The named receipts
contain full argument arrays and terminal results.

| Exercise | Command or retained execution receipt | Actual result |
| --- | --- | --- |
| Native Debug build | `xcodebuild -workspace ForgeConductor.xcworkspace -scheme ForgeConductor -configuration Debug -destination 'platform=macOS' -derivedDataPath "$E/DebugBuild" build` | Exit 0, `BUILD SUCCEEDED`; `native-debug-build-final-result.json` and `.log`. |
| App-hosted bootstrap tests | `xcodebuild -workspace ForgeConductor.xcworkspace -scheme ForgeConductorAppTests -configuration Debug -destination 'platform=macOS' -derivedDataPath "$E/AppTestBuild" -resultBundlePath "$E/AppTests.xcresult" -parallel-testing-enabled NO '-only-testing:ForgeConductorAppTests/AppBootstrapAppTests' test` | Exit 0; 8 executed, 0 failures; `native-app-hosted-result.json` and `.log`. |
| Universal Release archive | `xcodebuild -workspace ForgeConductor.xcworkspace -scheme ForgeConductor -configuration Release -destination 'platform=macOS' -derivedDataPath "$E/ReleaseBuild" -archivePath "$E/Validation.xcarchive" ONLY_ACTIVE_ARCH=NO archive` | Exit 0, `ARCHIVE SUCCEEDED`; `native-release-archive-result.json` and `.log`. |
| Developer ID export | `xcodebuild -exportArchive -archivePath "$E/Validation.xcarchive" -exportPath "$E/Export" -exportOptionsPlist "$E/ExportOptions.plist"` | Exit 0, `EXPORT SUCCEEDED`; `native-release-export-result.json` and `.log`. Manual Developer ID export uses existing owner team `9AQ2C2838M`. |
| Compiled export signing policy and artifact identities | `"$E/exported-signing-policy-probe"`; `/usr/bin/python3 "$E/verify_distribution_identity.py"` | Probe exit 0: app, launcher, CLI, and daemon require Developer ID extension `1.2.840.113635.100.6.1.13` and each satisfies it. Artifact verification: 215 checks, 0 failures (`exported-policy-probe.log`, `distribution-identity-verification.json`). Both architectures' daemon seals match before and after export. Bytes outside `LC_CODE_SIGNATURE` are identical for all five compared binaries; whole-file SHA-256 values differ. |
| Exported CLI bootstrap | `"$E/Export/Forge Conductor.app/Contents/Helpers/forge-conductor" status --home "$E/exported-cli-fixture"` | Exit 0; `exported-cli-bootstrap-result.json` and `.log`. |
| Native GUI bootstrap and folder-picker export | Direct CUA exercise of `"$E/Export/Forge Conductor.app/Contents/MacOS/Forge Conductor"`; `native-gui-fixture/failure-launch.json` and `healthy-launch.json` | Failed home PID 13256 and healthy home PID 13459 both exported actual paired JSON/Markdown through the native folder picker. Failure export has 3 records with startup error and unavailable-history disclosure; healthy export has 8 records. `native-gui-fixture/export-verification.json`: 23 assertions passed; `healthy-manager-status.json`: version 0.16.5, HTTP listening on isolated loopback port 49844. Files are retained under `failure-exports/` and `healthy-exports/`. |
| Native UI XCTest attempt | `xcodebuild` selecting the two `ProductionOnboardingUITests` folder-export methods; full command in `native-export-ui-result.json` | Exit 65: timed out enabling automation mode during runner initialization; **0 tests executed**. No automation permission changes. The separate CUA exercise above is observed native evidence, not an XCTest pass. |
| Focused source regressions | `swift test --filter` selection recorded in `focused-swift-final-result.json` | Exit 0; 61 executed, 0 failures, before the final callback `@Sendable` annotation and version-literal correction below. |
| Final source regression | `swift test` | Exit 0 (`full-swift-regression-final-result.json` and `.log`): qualification-support selected 30, skipped 0, failed 0; Core selected 1,961, skipped 12, failed 0. Across both targets: 1,991 selected, 1,979 passed, 12 skipped. Skips are unperformed checks. The earlier full run exited 1 on the stale H0 version literals; the corrected `H0IsolationTests` selection passed 7/7 before this final full rerun. |
| SwiftPM products | `swift build --product forge-conductor`; `swift build --product forge-conductor-app` | Both exit 0 on final inputs; `cli-build-final-result.json`, `app-product-build-final-result.json`, and matching logs. These are compilation receipts, separate from the native archive above. |

The full rerun emitted a sanitized missing-log-file diagnostic while
`RigParityTests/testManagerNodeStartStopInProcess` was executing; that test passed.
The redacted stderr line does not establish the writer or fixture path, and no
production cause is assigned. The 12 skipped checks cover live provider work,
disposable Keychain use, prepared signed-peer/job fixtures, child-only harness
cases, and the runtime PowerShell capability check; their exact reasons remain
in the full log. The run does not qualify those paths.

`xcode-membership.json` compares the canonical workspace/project with baseline
`3a00c9e4f08a3951d7db3aa6814b6eb8bef61044`: all non-build-configuration graph
objects, workspace references, shared schemes, resources, and embedding are
unchanged. Only 17 configuration objects changed for signing/version settings;
the 10 inspected native source/test files have their existing membership.
`H0IsolationTests.swift` remains in the existing SwiftPM-only
`ForgeFilesystemQualificationSupportTests` target; it has no Xcode file reference
or test target, and this edit does not add one.
The final H0 change is test-only and does not change the archived application
inputs.

The original installation was restored and reopened with its existing
0.16.4 failure at that qualification boundary. Its executable SHA-256 and strict
signature were preserved; `~/.lmstudio/mcp.json` was
`7663a4f6ae3bee266eb7cefe7edc18056ff1f34c72d72ae8265dbb4e1398b7a3`
(`native-gui-fixture/export-verification.json`). These checks qualify the
corrected source project and the isolated native candidate paths described
above. They do not qualify installation, notarization, distribution, or a full
LM Studio workflow. The owner retains those shipping steps.

## October 3 publication host readback

The later documentation-publication check found no
`/Applications/Forge Conductor.app` and no process matching Forge Conductor or
LM Studio. The LM Studio registration SHA-256 still matches the earlier receipt.
This documentation update did not install, remove, replace, or launch either
application. The cause of the host-state change is unknown; the earlier
qualification snapshot is not a claim that the installed app is still present.
`/Users/flynn/Projects/Forge-Conductor-Evidence/2026-10-03-docs-wiki-sync/publication-host-readback.json`
records the path, process command and registration hash. At that publication
checkpoint, source identity remained `0.16.5 (26)`; owner installation and
shipping qualification remained open.

## Prior 0.16.4 diagnostic source correction — historical test boundary

The prior repository source identity was `0.16.4 (25)`. The October 2 alpha
archive exposed six evidence gaps. Current
source changes preserve sanitized error identity, distinguish returned tool
failures from exceptions, classify `fs_read` errors by observed cause, retain
shell job and continuity attempt identity, and disclose Markdown timeline
omissions. The [A–H capture contract](DIAGNOSTIC-CAPTURE-CONTRACT.md) names the
source writers and regression tests. On the final `0.16.4 (25)` source tree,
`swift test` selected 1,955 tests, skipped 13 and failed 0; the canonical
Debug workspace build succeeded, and the complete app-hosted target passed
127 tests with no failures. The exact commands and terminal lines are in the
[roadmap](../ROADMAP.md).
At that earlier source-test boundary the installed app was still 0.16.3.
The later owner-installed 0.16.4 exposed the signing and startup-export failures
recorded above; those prior tests did not qualify that installed path. Discarded historical
exceptions cannot be recovered from that archive.

## 0.16.3 CLI staging and LM Studio deploy receipt — October 1, 2026

A fresh universal Developer ID archive was created at 2026-10-01 11:49:05 UTC
while Git HEAD was `b8a2c5dee546dff8d914405c2169a075bd0187e2` (verified
by the archive `Info.plist` creation time and Git reflog). That tree retains
product code `a54100b453ba8b1c1489ff09ac64dd6193fc1597` and `0.16.3
(24)` identity. The archive app was strictly deep-signature verified and its
embedded helper reported `0.16.3`. The candidate's own
`Contents/Helpers/forge-conductor install` copied the CLI binary and app
under `~/.forge-conductor`; it did **not** install into `/Applications`, and
its output correctly said LM Studio is not changed by that command. Running
that staged helper's `forge-conductor
install-lmstudio-plugin` then completed deployment revision
`7a3b0b17-0e39-4cce-b4cd-20df1c6ee9db`, reported at least 71 primary and
fallback tools and all four CLU controls, and wrote primary, fallback, and CLU
entries to `~/.lmstudio/mcp.json`. No manual edit followed the installer.

Source boundary: `ManagerInstaller.installedBinaryURL` is
`paths.home/bin/forge-conductor`; `stageInstalledArtifacts` executes
`artifactCopier.copyItem(at: binarySource, to: binaryStage)` and commits that
staged copy to the home target. The default copier delegates to
`FileManager.default.copyItem`. Separately,
`LMStudioMCPPluginInstaller.install` builds
`mergedMCPRegistrationData(binaryURL: binary, deploymentID: deploymentID)`
and commits it with `mergedMCPConfig.write(to: configURL, options: .atomic)`.
Neither function installs a `.pkg` into `/Applications`. GUI Deploy uses
`Bundle.main.executableURL` through `AppModel.deployToLMStudio`, not the CLI
helper used in this receipt.

Each entry has command `/Users/flynn/.forge-conductor/bin/forge-conductor`,
argument `serve`, the same deployment ID, its respective role, and no `cwd`.
The archive-embedded helper, staged support helper, support app's embedded
helper, and manually copied `/Applications` app's embedded helper all
have SHA-256
`49e81bc5522aff13d77c0b710417add067467d38e05fec651062be2f5480a289`.
The `0.16.2 (23)` `/Applications` app and its desktop-provider helper were
stopped; the app was backed up and the signed `0.16.3 (24)` candidate was
manually copied over it for a cold-start observation. This was not a package
installation. Forge and LM Studio then
cold-started. `mcp.json` remained SHA-256
`7663a4f6ae3bee266eb7cefe7edc18056ff1f34c72d72ae8265dbb4e1398b7a3`
before and after both launches, so neither launch reverted the registration.

In the ordinary LM Studio Jamf-Technician chat, hosted fallback PID `38508`
returned `get_forge_status` v0.16.3, client
`lm-studio:faf23139c06a39f92a71bf3bcdb267154717cd7e623e4d326188093f6f96d54a`,
and `project_context.attached: true`. After that PID exited, hosted fallback PID
`38964` returned the identical client ID and attached project/generation. Its
subsequent `fs_list`, `git_status`, `instruction_catalog`, and
`continuity.status` results each had `ok: true`, without another manual bind
or `project_context_required`. A separate paged catalog call with `limit: 1`
also returned `ok: true`. The transcript is
`~/.lmstudio/conversations/Jamf-Technician/1790852478591.conversation.json`;
the first post-install model turn claimed five calls but recorded only four,
so Continuity was explicitly called and verified in the next turn. The later
replacement-PID sequence recorded all four gated calls.

The signed package `ForgeConductor-0.16.3-24.pkg` was produced and its
Developer ID Installer signature and timestamp verified, but `installer`
returned `Must be run as root to install this package`; `sudo -n` was not
available. This is **not** a package-install pass. The CLI staging/deploy,
copied GUI candidate launch, and hosted MCP path were exercised. GUI **Deploy
to LM Studio** was not exercised: `AppModel.deployToLMStudio` passes the
running app executable, while the CLI run passed its staged helper. Its
registration behavior is therefore not qualified by this receipt.
Notarization, stapling,
Gatekeeper acceptance, Apple upload, public shipment, and other roadmap gates
remain open. No product code, version, build number, or Xcode graph was
changed, and no Continuity clear, reset, or delete was invoked. The existing installer test class
`LMStudioConnectorReliabilityTests` executed 9/9 without failures.

## 0.16.3 MCP reconnect and Dashboard binding correction

At that historical checkpoint, source identity was **0.16.3, build 24**. Installed `0.16.2 (23)`
diagnostics reproduced an LM Studio fallback helper restart that changed PID and
random MCP client UUID, after which project-scoped tools returned
`project_context_required`. A second live transcript showed that even
`get_forge_status(project_id)` on the replacement client returned success
without establishing the binding required by `fs_list`, `instruction_catalog`,
or `shell_exec`.

The correction gives ordinary LM Studio primary, fallback, and CLU helpers one
bounded deployment-scoped client identity across process restart, and makes
`forge_status` / `get_forge_status` idempotently attach an unseen deployment to
an explicit project or the sole active project. Instruction catalog/read now
accept the resulting project-generation context without requiring a Managed
Run. Existing inactive bindings from a generation reset are not reactivated,
and ambiguous multi-project selection still requires `project_id`.

Implementation revision `a54100b453ba8b1c1489ff09ac64dd6193fc1597`
contains the completed correction and exact replays:

- `testStatusBootstrapUnblocksAllReportedProjectScopedToolsOnSameClient`
  asserts `fs_list`, `instruction_catalog`, `shell_exec`, and
  `continuity.status` each fail with `project_context_required`, then asserts
  `get_forge_status(project_id)` returns `project_context.attached == true`,
  and finally asserts the same four calls succeed on client
  `A800AC6E-8B31-4E64-A0CE-9B9DA192CADA`.
- `testDeploymentScopedMCPReconnectUsesExistingBindingWithoutSecondStatusCall`
  creates primary and fallback `MCPServer` objects with different random process
  identities and one deployment ID, calls status only through the primary, and
  asserts all four gated tools succeed through the fallback.
- `testEmptyDeploymentMCPStatusAttachesFreshRandomClient`,
  `testForgeStatusKeepsPolicyLocationWhenProjectSelectionIsAmbiguous`, and
  `testGetForgeStatusDoesNotReactivateBindingInvalidatedByGenerationReset`
  cover the empty deployment, explicit two-project selection, readable status,
  and reset fence.
- App-hosted
  `testRegisteredProjectBecomesTrackableOnlyAfterStatusBindingSurvivesReconnect`
  asserts `.unbound` before status and the exact durable project/generation
  after reconnect with a different process identity.

The complete Core selection passed 55/55, project-context integration passed
10/10, MCP protocol and diagnostics passed 20/20, both SwiftPM products built,
the canonical Debug workspace build succeeded, and the focused Dashboard case
passed in `ForgeConductorAppTests`.

On October 1, the reloaded LM Studio primary, fallback, and CLU entries all
named `/Users/flynn/.forge-conductor/bin/forge-conductor serve`, supplied
deployment revision `6b6aa0b4-c3bd-454b-96e4-1273abf390f1`, and supplied no
`cwd`. The helper reported `0.16.3`, and SHA-256
`41a0a94fe247a2ea4718f43b1dd32a19bc7414e4d202f37d8c32e09312046387`
matched the source-`a54100b` build-24 candidate helper.

Forge and LM Studio were both terminated and relaunched. A new ordinary LM
Studio chat then used the fallback registration and hosted PID `33715`. Its
first `get_forge_status(project_id)` attached project
`d2610542-b616-7e8f-ee36-ef902d6060e1` generation 7 to stable client
`lm-studio:12ec4eaf781d85b33f4dde7e180dbbd44367c93155660ec486c1b4cb2d21a6fc`.
The next `fs_list`, `git_status`, `instruction_catalog`, and
`continuity.status` calls all succeeded without another bind or initialization
call. The registration record, status root, and Git top level all identify
`/Users/flynn/GitHub/Jamf-Technician`; the Documents-path variant is absent.
This was the earlier hand-deployed-helper evidence; it did not at that time
qualify the separate GUI installation or distribution.

The universal Developer ID app and archive are at `/Users/flynn/Desktop/Forge
Conductor 0.16.3 (24)-a54100b-DeveloperID`. Both report `0.16.3 (24)` and the
app is `x86_64 arm64`; strict Release validation passed for the app, Core
framework, embedded CLI, runtime launcher, and filesystem daemon. At the time
of that receipt, `/Applications/Forge Conductor.app` remained `0.16.2 (23)`
with executable SHA-256
`fc29b8006af141cfc7c5c99f219eb22faca593b430b6adadd6a8581e3243e542`.
The earlier wiki receipt was `e615c2405a094b43f9ebb4794ba0676c86ae38bd`.
The later CLI staging/deploy receipt and its package-install limitation are
recorded above.

## 0.16.2 owner-notarization artifact set (historical)

The shippable universal Developer ID build `0.16.2 (23)` from product source
revision `22e7443d13496b3cc08b6e98366bb6d2332e3fd4` is ready for owner
notarization and Apple upload. The retained Desktop directory contains the
canonical `ForgeConductor` archive, manual `developer-id` export, app ZIP,
Developer ID Installer package, hashes, and command-only owner notarization
file. The archive and all five shipping objects pass strict signing, hardened
runtime, secure timestamp, exact team and role identity, universal-architecture,
no-App-Sandbox, and Release privileged-filesystem-bundle checks. Extracted ZIP
and PKG payloads passed the same Release checks.

No notarization, stapling, installation, Apple upload, shipment, or release was
performed. Gatekeeper correctly reports `source=Unnotarized Developer ID` for
the pre-notarization app and package. `/Applications/Forge Conductor.app`, live
LM Studio registration, and Continuity packets were not changed.

## 0.16.2 Development Policy bootstrap

The retained Desktop candidate identity is **0.16.2, build 23**.
`get_forge_status` in that source
returns the pinned governing Development Policy identity, every active Rune
Forge policy source path in durable priority order, the supported filesystem
read tools, and a required action directing the LM Studio model to read and
follow all applicable policy requirements before development changes. The
additive contract preserves all prior project, instruction, continuity, and
resume fields. It also returns the bound project's durable instruction-package
execution order with IDs, names, positions, source paths, and snapshot hashes;
policy location and the required action remain present when project selection
is ambiguous. Focused SwiftPM regressions for the ordered project response,
ambiguous-project response, and MCP tool description each executed with zero
failures. Both SwiftPM products and the canonical Debug workspace build passed.

Implementation revision `22e7443d13496b3cc08b6e98366bb6d2332e3fd4`
produced the universal Developer ID archive and export under `~/Desktop/Forge
Conductor 0.16.2 (23)-22e7443-DeveloperID`. Strict deep signature verification
passes. The app and embedded MCP helper report Developer ID Application James
Daley, team `9AQ2C2838M`; the app reports `0.16.2 (23)` and the helper reports
`0.16.2`.

LM Studio primary, fallback, and CLU registration revision
`32b3c0a3-c621-4e1e-bfe2-75838c5ea86d` points to that exact candidate helper.
After an LM Studio quit/relaunch, the existing Jamf-Technician chat called
`get_forge_status(project_id: d2610542-b616-7e8f-ee36-ef902d6060e1,
resume: true)` through `mcp/forge-conductor-fallback`. Its persisted raw tool
result reports final repeated PID `12436`, version `0.16.2`, the priority-1 policy source and
read/follow requirement, package `Jamf-Technician-Continuation-Package-R1` at
position 0, project/instruction/continuity locations, and resume data. Primary
PID `12434` and CLU PID `12435` use the same candidate and deployment revision.
The working `/Applications/Forge Conductor.app` was not replaced. Notarization,
stapling, Gatekeeper acceptance, and shipment remain open.

## 0.16.1 native host access and Dashboard project tracking (historical)

Source identity **0.16.1, build 22** changed the native filesystem,
search, PDF, Git, shell, and runtime paths no longer enter Forge's per-command
Seatbelt profile or reject absolute paths merely because they are outside a
selected project folder. Project binding and generation remain mandatory for
attribution and durable isolation. macOS evaluates TCC access for the
responsible signed code objects in the actual launch chain; a live protected-
path probe establishes protected-path access only for that exact launch chain.
Tool grants, shell enablement, canonicalization, deadlines, output bounds, durable
result fencing, and destructive-root protection remain in force. Native jobs
use a default 16-descendant budget and a 1,024-identity hard cap; overflow is a
typed failure, and unconfirmed termination becomes bounded identity-fenced
cleanup debt. Local outside-project delete and move independently rebuild the
protected-root set and descriptor-recheck source identity immediately before
namespace mutation.

Dashboard now identifies the tracked project from live MCP presence and the
matching active `mcp_client` binding. It orders multiple live clients by recent
activity with heartbeat fallback, uses an exact nonterminal run only when no
live binding resolves, and never treats registration alone as active work.

The complete focused `CoreTests` selection executed 49 tests with zero
failures. The all-available-runtime profile case exercised an external working
directory, `/bin/ps`, and inherited environment state. The complete runtime-job
suite executed 103 tests with zero failures, including bounded cleanup of an
observed `setsid(2)` child, and the secure-filesystem suite executed 100 tests
with zero failures. Dashboard operational-snapshot tests executed 23 tests with
zero failures in both SwiftPM and the app-hosted Xcode target, including
live-binding preference and the registered-only negative case. The final
integrated SwiftPM run executed 1,933 tests with 12 explicit environment-
dependent skips and zero failures. Both SwiftPM products and the canonical
Debug workspace build passed.

Exact implementation revision
`91ad90ee7a1e51b7289f4c531ddae4dbbc6812ec`, tree
`08e021b375fb8a998f06d9e81a10e3fffddd21f0`, produced the universal Developer
ID archive and export under `~/Desktop/Forge Conductor 0.16.1
(22)-91ad90e-DeveloperID`. Strict validation passes for the app, CLI, runtime
launcher, Core framework, and filesystem daemon. All five carry James Daley's
Developer ID Application identity on team `9AQ2C2838M`, hardened runtime,
secure timestamps, and no App Sandbox entitlement.

The exported candidate's MCP helper passed an isolated end-to-end probe. Its
project context reports
`filesystem_access_scope=host_native_inherited_unconfined_by_forge`,
`filesystem_sandbox_mode=none`, and
`filesystem_path_confinement=false`. It read one byte from a protected Mail
path without returning content, ran `/bin/ps`, resolved Apple Git from inherited
`PATH`, completed filesystem read/write/search and Git commit operations outside
the selected project, completed a native runtime job, and returned the exact
bound project from `get_forge_status`. Gatekeeper assessment exits 3 with
`source=Unnotarized Developer ID`; this is an explicit non-pass. Notarization,
stapling, Gatekeeper acceptance, a live native multi-project Dashboard UI
observation, and shipment remain open. The working installation was not
replaced. Protected-path access through the installed Forge application and
the LM Studio-hosted launch chain remains to be exercised with this candidate.

## 0.16.0 foreground successor and packet management (historical)

Source identity **0.16.0, build 21** added Continuity lists of the
actual durable checkpoint/handoff packets under each project ID and enabled
deletion of only the exact single or multi-selection after confirmation. Reset
and Clear Cache remain on Continuity; instruction-package controls are confined
to Projects. Focused packet store/wire and native UI tests execute with zero
failures.

Same-host LM Studio configuration no longer exposes or accepts an operator
credential. The build-19 correction removes the obsolete local Forge Keychain
reference on this host; the persisted local configuration reports no reference
and the credential journal is a tombstone.

The optimized Release packet decoder now passes its strict scalar/container
test and the repaired Release helper reads the live durable packet inventory;
build 17 had returned an empty list for the same valid rows. The build-18
candidate exposed one additional defect: it hid registered packet projects when
automatic continuity reported `unavailable`. Build 19 keeps those projects
visible for packet management.

Candidate revision `a540670b54e78aeff1793848a9cc16e0be6fe438`
produced `/Users/flynn/Desktop/Forge Conductor 0.16.0 (21)-a540670.app` and the
matching `.xcarchive`. The GUI is universal arm64/x86_64; strict deep signature
verification reports Developer ID Application team `9AQ2C2838M`.

**Prior build-19 E0 retained by build 21:** the ordinary owner-surface UI case executed one
test with zero failures and found the Continuity project/packet frames plus
Copy Project ID, Delete, Reset, and Clear Cache. The real-provider UI case
executed one test with zero failures, discovered loaded model
`qwen/qwen3.8-27b`, clicked Connect and Check and Run Advanced Probe before and
after relaunch, and read back ready/contract-valid with
`credentialConfigured=false`. It also asserted that the loopback screen has no
token field or credential action.

The live Continuity inventory began with 75 packets. Two exact-candidate UI
runs selected, confirmed, and deleted only disposable packet IDs
`708cbe57-06b4-4cf3-85f8-75c458966b81` and
`60f7f1be-636c-443d-9cae-2c1fd5a6fc85`. The final inventory contains the 73
pre-existing IDs, with zero unexpected removals and zero additions. A separate
focused multi-selection case issued one delete request for exactly two selected
IDs and retained the third packet. Exported screenshots and accessibility
dumps are beside the candidate in `Forge Conductor 0.16.0 (19)-868645e
Evidence`.

The tracked repository, candidate, and Forge support directory contain no local
LM Studio token variable, secret prefix, or token-bearing authorization value.
The rejected Forge Keychain item is absent, and the local provider JSON contains
no credential reference.

A fresh foreground LM Studio GUI chat called `get_forge_status` through the
candidate's registered fallback MCP process, then called `context_get`,
`memory_list`, `memory_search`, and `fs_read`. Its visible answer returned Forge
home `/Users/flynn/.forge-conductor`, project `Jamf-Technician`, project root
`/Users/flynn/GitHub/Jamf-Technician`, project ID
`d2610542-b616-7e8f-ee36-ef902d6060e1`, and resume-ready handoff prefix
`fdb9130a`. The chat was the foreground LM Studio tab.

**E0 on the build-21 Desktop candidate:** disposable handoff
`79474019-000f-4395-a593-cc74a6da2372` committed at
`2026-09-28T10:01:08Z`. Manager exposed the due time
`2026-09-28T10:01:38Z` and was observed at 25 seconds remaining. At expiry the
candidate used LM Studio's public macOS Accessibility controls to open and
select foreground tab `Forge Rollover Successor Proof`, then entered `get_forge_status`,
`resume=true`, the exact handoff ID, and rollover nonce
`517cbb4f-f1bd-cc69-e1df-f14ffc7f5f9c`. The visible chat called
`get_forge_status mcp/forge-conductor-fallback`. Its owner-only receipt records
the same handoff and nonce, `resume: true`, and acknowledgement time
`2026-09-28T10:06:48Z`.

The native ledger has exactly one record for that handoff: logical successor
`51a4567d-36f9-4d44-8a54-925f6e14a0f5`, provider identity
`lmstudio-gui-877df47abf1e5782aea37f27`, status `acknowledged`. Only after that
receipt did Manager append the exact handoff once to
`interactive-continuity-sealed.json`; the operator snapshot then reported
`completed`. A delayed watchdog check retained one successor record. The driver
contains no `/api/v1/chat` call or integrations array and stores no same-host LM
Studio credential. CLU live delivery and owner acceptance remain open. This is
not shipment acceptance, and `/Applications/Forge Conductor.app` has not been
replaced.

The live chat's fallback MCP child used the compatible build-20 registration
that was active when the chat started; build 21's app process supplied the
corrected foreground GUI driver. After the receipt and seal were captured, the
supported installer synchronized primary, fallback, and CLU commands in
`~/.lmstudio/mcp.json` to the exact build-21 candidate. The resulting
registration contains no token, Authorization, or credential field.

The prior build-16 candidate at revision `f2cc6ca` remains historical evidence
only. Its Continuity package control and project-wide delete do not satisfy the
current packet contract.

## 0.15.0 Continuity history retention controls

Product correction `849b87953b4420f07a629fdcd29ecf0d58216756`
extends the accepted `0.15.0 (14)` identity with cleanup for every old item the
Continuity view presents. The exact control-plane predicate is
`commandIsTerminal || run == nil || run?.state.isTerminal == true`. The
project-memory removal predicate is
`stored.state == ContinuityState.predecessorSealed.rawValue || stored.quarantined`.
For an old list row whose project operation remains nonterminal, the Manager
first retires that stale operation, then removes its visible command root,
schema-2 operation, handoff, transition and repair payloads, and rebuildable
JSON/current/latest projections. A payload-free tombstone prevents stale replay.
A genuinely live owner remains visible with its exact run/command state and an
**Open Run Details** action. Ordinary project memory records, tasks, runs,
credentials, project files, and unrelated project data remain unchanged.

**E0 on the exact Desktop app:** `/Users/flynn/Desktop/Forge Conductor 0.15.0
(14)-849b879.app` reported bundle identity `0.15.0 (14)`. Its live Continuity
view began with 24 stored IDs. **Clear Selected** removed
`c36460fe-05ae-b00c-8aae-100209600137`, leaving 23 after Refresh. **Clear All
Old** removed the remaining 23; the IDs were still empty after Refresh and
after termination and exact-path relaunch. The matching archive is
`/Users/flynn/Desktop/Forge Conductor 0.15.0 (14)-849b879.xcarchive`. Neither
artifact was installed. The candidate is Apple Development signed, universal
arm64/x86_64, and passed strict deep signature validation. Its executable
SHA-256 is
`f2b89c2e38a3b25119258989b9987a5aee595f0a18b7e90861c035ed1e579ce0`.

The post-correction complete Swift suite executed **1,890 tests with 12
explicit environment/live skips and zero failures**. The complete app-hosted
suite executed **111 tests with zero failures**. The separately gated exact-app
live Continuity case executed one test with zero skips and zero failures. Both
SwiftPM products built. The owner will perform final acceptance, distribution,
and shipment separately; `/Applications/Forge Conductor.app` was not replaced.

## 0.14.7 Projects instruction controls — Desktop candidate

Candidate source `74ead97e0b4d2116e80e8482d5736afc94e16372` closes the
remaining deterministic control-identity gap after the nested `List` and
in-flight poll wipe were removed. The plain package `VStack` still had one
container accessibility identifier; SwiftUI propagated it over every package
child and replaced the exact earlier/later/Remove identifiers. The candidate
removes only that parent override. Stop remains in the action bar above the
rows, and the bordered child buttons retain their individual identities.

**E0 on this Mac:** the Apple Development-signed native minimum-window case
clicked **Stop Active Work**, Move later, and Remove, then observed the saved
order and absence after later two-second queue polls. The signed real-Manager
case imported two packages, persisted reorder, removed one, and passed. A new
runtime integration test started an active run-owned `sleep 30` job, stopped
its queue, verified job and run cancellation, observed the package terminal and
unlocked, and removed it. The instruction-queue suite passed 37/37 and the
Projects view-model suite passed 18/18, including the in-flight refresh case.
Both SwiftPM products built. A universal Debug app and `.xcarchive` were built
outside `/Applications`; strict deep signature verification passes and the
built Info.plist reports `0.14.7 (13)`.

**E0 live candidate acceptance:** a signed native test attached to PID `15318`
only after asserting its bundle URL was
`/Users/flynn/Desktop/Forge Conductor 0.14.7 (13)-74ead97.app`. At normal size,
Projects started ordered package `d275cbbf-3c54-43af-858f-bd43fec39d4b` as
LM Studio run `450f1a7f-8f49-4d78-bd7d-1e97c94f6273`; the run was observed
`running` with model `qwen/qwen3-coder-30b` and a non-null managed session.
Clicking **Stop Active Work** produced terminal run/package state `cancelled`,
queue `running=false`, and an enabled Remove control. Move earlier persisted
the exact two-package order after Refresh, and removing the other package
persisted after Refresh. At the 1100×788 minimum window, package
`2c1c98e3-bf1c-4eca-a481-03b1fe5448e6` started as live LM Studio run
`850f0576-225f-4b04-a4ff-a5d43471494d`; Stop was hittable and produced the
same terminal/unlocked state. Move later and Remove were both hittable, and
their resulting order/absence persisted after Refresh. Post-test Manager
readback retained both runs as `cancelled`, the queue as stopped, and LM Studio
reported the pinned model `IDLE`. The focused `.xcresult` executed 1 test with
zero skips and zero failures.

The working installation was not replaced. Developer ID signing, notarization,
Gatekeeper distribution acceptance, owner final testing, and shipment remain
open. The live evidence closes only the reported Projects Stop/reorder/remove
acceptance gap and is not a shippable-build declaration.

## 0.14.7 Projects instruction controls — prior incomplete baseline

Product source `b4bf571de822cc463dc69c30f4a10c12033919cd` addressed the
manager cancellation and first layout defects but did not close the reported
inability to stop, reorder, or remove project instruction packages. Its
package-container identifier still replaced the child Move/Remove identities;
the current Desktop-candidate section above records the correcting evidence.
**Stop Active Work** now fences queue advancement, quiesces and durably cancels
the exact active run, and only then reconciles the package to a removable
terminal state. A stopped queue with a still-running package retains a
retryable cancellation path. Reordering has explicit native earlier/later
controls in addition to drag behavior, and package/remove plus queue actions
use leading rows that remain hittable in the constrained Projects layout.
Revision-monotonic queue acceptance prevents a two-second background poll from
replacing a newer mutation response.

**E0:** a production-composition, Apple Development-signed UI test imported two
real files through the authenticated Manager API, found the native move and
remove controls, persisted the reversed package order, removed one package, and
verified the remaining durable identity. The first reproductions recorded the
original action controls as present but non-hittable beyond the visible window;
the identical final flow passed after the layout repair. Focused queue,
Projects view-model, and Manager-route tests passed, including stopped-queue
cancellation retry and stale-revision rejection. Complete regression and build
counts are recorded in the current roadmap row.

The working installation was not replaced. Developer ID signing, notarization,
Gatekeeper distribution acceptance, and owner shipment remain separate from
this source-candidate repair. The publication receipt is documentation-only and
does not change the tested source inputs or canonical Xcode graph.

## 0.14.6 Provider and ordered-run repair — installed development build verified

Product repairs `675d267fdd2f45cd412e5398a04a2321bfe51def`,
`f39c79ad0e60259d7a02ba0361825e5b6940c136`, and
`101c3d44f80c689c428e255f4578d88c54f40c16` add the missing
live LM Studio readiness boundary to ordered-work admission, ignore stale
project generations during provider-repair resume, expand the bounded managed-
provider receipt window so a maximum-round run retains its first turn, preserve
continuity identity through budget escalation, and release project-local
continuity authority when its owning run is cancelled.
The existing Provider repair prevents deactivating the sole selected provider,
lets LM Studio activation supersede a replaceable background snapshot load,
preserves no-resume preparation through the manager-client router, and keeps
Guided Setup closed until explicitly opened.

**E0, installed build:** the owner-state pin `qwen/qwen3-coder-30b` was installed
but unloaded when the original queue rejection was recorded. Loading that exact
pin and running **Connect and Check** produced a current `contract_valid`
readiness receipt. The installed `/Applications/Forge Conductor.app` then
returned HTTP 200 for the same project/package **Start Ordered Work** request.
The final live run `6573026b-35f1-47b8-a0c6-6b4df226eed7` completed 50 LM Studio
turns, 41 tools, and 18 automatic rollovers. It then paused at the separate
package completion gate because project-build and project-tests evidence was
absent. It did not reproduce the LM Studio configuration, receipt-reconciliation,
continuity identity-drift, or stranded-operation failures. The prior terminal
run's exact operation is retained as `run_cancelled` quarantine history. The
provider ledger still selected `lmstudio`, reported it configured/selectable,
and had no current operation. Exact native UI passed launch without an automatic
setup sheet and the Provider selection/LM Studio transaction.

The complete SwiftPM regression passed 1,879 tests with 12 explicit skips and
zero failures. Both SwiftPM products and the canonical Apple Development-signed
Debug workspace app built; strict deep signing, repository hygiene, and Xcode
membership checks passed. Gatekeeper rejects this development-signed app as a
distribution artifact. Developer ID signing/notarization and shipment remain
open; this section does not call the build publicly shippable.

## 0.14.5 project-workflow repair — qualification incomplete

Version `0.14.5 (11)` fixes mixed-folder instruction admission, keeps package
addition and pending-order changes available during active ordered work,
consolidates direct-task and run controls under Projects, and separates native
content from the macOS title/toolbar chrome. The complete SwiftPM regression
executed 1,872 tests with 13 explicit environment/helper skips and zero
failures. All 36 instruction-queue tests, all 15 operator-project contract
tests, and three signed native UI cases passed. Both SwiftPM products and the
canonical Apple Development-signed Debug app built; exact `0.14.5 (11)`
bundle/CLI identity and strict deep-signature checks passed. Live LM Studio and
Codex execution has not yet been repeated for this identity, so its shipment
verdict remains inconclusive and it is not called shippable.

Recorded operator board:

- Autonomy removal — PASS
- Telemetry frame — ACCEPTED
- Mixed-folder packages — PENDING operator review
- Projects/LM Studio ordered work — PENDING operator review
- Automated Continuity handoff — PENDING operator review

The three pending items are implemented pending owner live review. Their source
and deterministic evidence are recorded, but they are not implemented-and-
qualified, accepted, or shippable claims.

## 0.14.4 local LM Studio and Codex shippability

The owner's acceptance boundary for this build is local: Forge Conductor must
build and run on this Mac, and its complete project workflow must work with the
two providers the owner uses, LM Studio and Codex. Version `0.14.4 (10)` closes
the observed setup failures within that boundary.

**E0:** the signed Debug app discovered and prepared loaded
`qwen/qwen3-coder-30b`, selected LM Studio, registered the repository, admitted
an immutable instruction artifact, and created a managed task. Repeated MCP
deployment and app restart left the model loaded. A fresh Codex
`0.155.0-alpha.16.4` task loaded the installed Forge package through Codex's
normal trust review, attached to the exact project run, successfully called
`forge_status`, and completed all three compiled automatic obligations with a
durable `desktop-hook` evidence reference. All seven configured Codex hooks and
the Forge MCP server were visible to the host.

The final full regression executed 1,851 tests with 13 explicit
environment/helper skips and zero failures. Both SwiftPM products and the
canonical Apple Development-signed Debug workspace app built; strict deep
signature verification and `0.14.4 (10)` bundle/CLI identity checks passed.
Repository checks passed. Product source
`cdc539ec35d0f19493d6169ddd827e130870b02f`, tree
`e1291f80f2a2dd87b7cb7df112358706cf89ae61`, and wiki revision
`96199f79899e02e133652771a022dd6c7ae84599`, tree
`aa6dfa40949b424821b89f1694c0811e6ab182e8`, are published. Exact local/remote
parity is verified after the documentation closeout. Notarization, public download, second-hardware
qualification, Claude, Grok, and a physical VoiceOver listening session are
outside this owner-defined local LM Studio/Codex acceptance scope.

## 0.14.3 project-setup transaction repair

The downloaded `0.14.2 (8)` build reproduced a real setup race: **Connect and
Check** resumed two retained LM Studio runs and then its integration deployment
restarted the provider while both requests were processing. Both streams ended
without a completed response. Three new-task attempts also imported immutable
instruction artifacts before provider preparation rejected the missing model,
leaving artifacts without durable runs. Version `0.14.3 (9)` orders these
boundaries so provider readiness precedes artifact admission, retained runs
remain quiescent across integration deployment, and only a successful
post-deployment probe resumes them. Current-source qualification evidence is
recorded below: both SwiftPM products built; the terminal full suite executed
1,848 tests with 12 explicit environment/helper skips and zero failures; the
live provider preparation and live fresh-root/continuation cases each passed in
separate zero-skip runs against loaded `qwen/qwen3-coder-30b`; two focused
app-hosted tests passed; and the canonical signed Debug app built without
compiler warning/error lines and passed strict deep-signature plus `0.14.3 (9)`
bundle-identity checks. Two signed production-onboarding UI tests passed direct
path and native-picker project registration, allowed-root persistence, Manager
readback, and relaunch. The 12 aggregate skips are not passes and retain their
separate environment-specific qualification boundaries. This remains a
development identity, not a shipment claim.

## 0.14.2 reported-run repair

The focused Core pass executed 125 cases: 123 passed, two explicit native-job
environment skips, zero failures (`/tmp/forge-0.14.2-core.log`). Five distinct
native UI cases passed before the version-only update: checkbox interaction,
Dashboard geometry, minimum/normal containment of every primary view, and
populated policy evaluation rows. Live completion of the reported owner run,
universal policy enforcement, and distribution qualification remain open.

Current source target: **0.40.0, build 56**, supporting **macOS 26+**; scoped source/native/build/App/CLI/Qwen evidence and remaining consumer/document/delivery gates are above.

Preceding .38 identity record (retained):

Current source target: **0.38.0, build 54**, supporting **macOS 26+**; current archive evidence is above.

Preceding .37 identity record (retained):

Current source target: **0.37.0, build 53**, supporting **macOS 26+**; matching 56 raster plus five neighbor methods passed and remaining gates are recorded above.

Preceding .36.2 identity record (retained):

Current source target: **0.36.2, build 51**, supporting **macOS 26+**; focused status/replay methods passed and remaining gates are recorded above.

Preceding .36.1 status sentence (retained):

Current source target: **0.36.1, build 50**, supporting **macOS 26+**; instruction-count gates are recorded above and BMP retains its preceding scoped results.

Preceding .35 status sentence (retained):

Current source target: **0.35.0, build 48**, supporting **macOS 26+**; bounded WebP
owning source/native 225 plus separate G3 one each establish matching 226-method
unions; direct builds/strict signature and scoped App/CLI/Qwen/native consumers
passed. Final-document G3 source/native one each and hygiene/whitespace passed,
adding no distinct methods. Exact source/wiki publication, readback and synchronization outcomes are retained in external closeout receipts.
Preceding .34 receipts retain their identity.

Preceding .34 status sentence (retained):

Current source target: **0.34.0, build 47**, supporting **macOS 26+**; bounded GIF
source/native/candidate/App/CLI/Qwen checks passed as recorded above. Exact delivery
identities are retained externally; preceding .33 tested inputs retain their identity.

Preceding .33 status sentence (retained):

Current source target: **0.33.0, build 46**, supporting **macOS 26+**; scoped JPEG qualification and remaining document/delivery/installed gates are recorded above. The preceding published source is .32.0/build 45. The earlier
0.16.3 Developer ID app and archive are recorded in the historical build-24 section;
that workflow staged the CLI under `~/.forge-conductor` and manually copied the
app to `/Applications`. It did not exercise a `.pkg` installation, notarization,
or shipment. Earlier `0.9.0 (1)` receipts remain historical evidence only. This
page is a concise status index;
the detailed, source-bound receipts are in the
[functional-build record](FUNCTIONAL-DEVELOPMENT-BUILD.md) and
[roadmap](../ROADMAP.md).

## Version and build agreement

The current target is **0.40.0, build 56** for TAR/GZIP archive formats. Matching source/native 25-method, ordinary Debug/signature, App/CLI full-byte wire, Qwen TAR/tar.gz consumption/ACK and separate mechanism/container/BSD gates passed; fifteen product BSD commands also passed. G3/document/hygiene, final C2 and source/wiki delivery remain pending. Prior scoped evidence remains historical.

Preceding .37 identity record (retained):

The current target is **0.37.0, build 53** for standard-size ICO. Matching 56 raster plus five separate neighbors give 61 distinct source/native methods per route; focused eight adds no distinct coverage. Candidate build/signature/version, App/CLI/Qwen wire and separate seven-pair native consumer checks passed. Document G3 is a separately executed method, counted only in actual external union receipts. Final check/delivery outcomes remain external. GUI v3/v4 remain NONPASS with Projects/filtered Tools gates blocked; preceding web/Qwen outcomes remain separate and unchanged.

Preceding .36.2 identity record (retained):

The current target is **0.36.2, build 51** for the status-build correction. Matching six source/native methods and CLI/app compilation passed; candidate/runtime, document and delivery gates are pending actual receipts.

Preceding .36.1 agreement and qualification record (retained):

The current target is **0.36.1, build 50** for the instruction-count correction. Current source/native queue tests and builds passed; initial-document G3 source/native one each and initial hygiene/whitespace passed. Exact source/wiki delivery remains pending.

Preceding .36 agreement and qualification record (retained):

The current target is **0.36.0, build 49** for bounded BMP; product authorities advance, and initial-document G3 passed once in source/native (1.439/1.767 s); later document/delivery results require separate external receipts.

Preceding .35 agreement and qualification record (retained):

The current target is **0.35.0, build 48** for bounded WebP. Product authorities
and graph/build inputs agree; owning source/native 225 plus separate initial-document
G3 one each establish matching 226-method unions. Direct builds/strict signature
passed. Final-document G3 source/native one each and hygiene/whitespace passed,
adding no distinct methods. Exact source/wiki publication, readback and synchronization outcomes are retained in external closeout receipts.
[WebP scope](NATIVE-IMAGE-WRITING.md).

Preceding .34 agreement and qualification record (retained):

The current target is **0.34.0, build 47** for bounded GIF. Authority agreement
and matching 219 distinct source/native methods passed, including G3 once.
Final-document G3 and exact source/wiki publication, readback and synchronization are tracked in external closeout receipts.
[GIF scope](NATIVE-IMAGE-WRITING.md).

Preceding .33 agreement and qualification record (retained):

The current target is **0.33.0, build 46** for opaque lossy JPEG. Authority/G3
and matching 210-method source/native selections, CLI/app/ordinary Debug passed.
Strict candidate, signed App/CLI controls, independent raw JPEG inspection and Qwen API consumption passed.
Final-document G3 passed in source and native. Source/wiki publication, readback and synchronization are tracked in external closeout receipts. [Current image scope](NATIVE-IMAGE-WRITING.md).

Preceding .32 agreement and qualification record (retained):

The current target is **0.32.0, build 45**. Authority agreement and G3 passed
within matching 203-method source/native selections. Direct builds, strict
candidate and scoped TIFF runtime/model checks passed. Final document G3
passed source/native. Exact source/wiki publication/readback/synchronization
identities will be retained in external closeout receipts.
[Current image scope](NATIVE-IMAGE-WRITING.md).

The preceding .31 source/native selections passed 198 distinct methods each;
build/signing, scoped PNG runtime/model and final document G3 passed on the
original .31 inputs. That evidence is retained without qualifying TIFF.

The preceding .30 source/native G3 passed within matching 199-method selections;
canonical build/signing and scoped ODS runtime checks passed. [Scope](NATIVE-ODS-WRITING.md).

The preceding .29 source/native G3 passed within matching 166-method selections
on 458 inputs; canonical build/signing and scoped PPTX runtime gates passed.
[Preceding PPTX gate status](NATIVE-PPTX-WRITING.md).

Preceding .28 source/native G3 passed within matching 124-method selections; its
canonical graph/build/signing gate passed on its original 454 inputs.
[Preceding XLSX gate status](NATIVE-XLSX-WRITING.md).

The preceding .27.1 root/compiled/PBX authorities agreed; separate source/native
G3 passed one each within 212 distinct methods each.
[Retained evidence](ORDINARY-RUNTIME-CONTINUATION.md#repeated-subsystem-shutdown).

The preceding DOCX Swift runtime, CLI, Xcode Debug and Release configurations
and documentation targeted version **0.27.0, build 39**. The root [`VERSION`](../VERSION)
and [`BUILD_NUMBER`](../BUILD_NUMBER) files are canonical; compiled constants
and Xcode build settings match them. Actual G3 passed current DOCX version/document
agreement; the compiled native 155 includes that method. Graph review preserves
all 23 existing memberships and the version-only PBX edits. The preceding .26.2
version method passed within
the 92 source and same 92 native selections on their historical map; graph review retained existing
memberships and version-only PBX edits. The preceding .26.1 hotfix version
method passed within the
final 139 source and same 139 compiled native cases.
The following receipts retain their preceding .26/36 maps. The actual .26 source version method
and exact Manager parity passed separately after the earlier owning-area 307
methods passed. Both incremental products and ordinary native Debug build passed;
native 309 and focused native 4 passed on their distinct fixture maps, with
three full-run QoS diagnostics retained. Strict Debug artifact binding and
isolated native MCP/Qwen cases passed; the first Qwen final-parser NONPASS
remains. Owner repair is applied; final source 321 and separate ordinary Debug
compilation passed on the later map. Final native 321 passed with the existing
DiagnosticLog64 warning; strict Debug verification of seven binaries and signed owner/continuation repetitions
passed. Fresh Qwen passed on the final candidate; exact direct publication/synchronization revisions use the external delivery
receipt after the update. First NONPASS and
later three-method repair receipts retain their distinct maps. The graph receipt
verifies sixteen changed Swift inputs with retained membership/workspace and
only twelve marketing/sixteen build settings changed. First CLI/app
integration compiles passed on their recorded 450-input snapshots. At the preceding .25 PDF
checkpoint, its marker regression passed one source method and was included in
the 102-test compiled native pass; strict Debug/Release verification bound those
historical builds to their 450 inputs. Its later test-only closeout was delivered
and synchronized at the exact source/wiki refs above. The final scoped .26 native/API gates above passed; exact direct publication/synchronization revisions use the external delivery
receipt after the update. The
consistency check runs locally and in CI. Filesystem protocol, provider-plugin,
and database schema versions are
separate compatibility contracts.

The canonical native project is `ForgeConductor.xcworkspace`, using the
`ForgeConductor` scheme. Its archive contains one installable app product with
the Core framework, manager CLI, runtime launcher, filesystem daemon, resources,
and icon. A standalone SwiftPM CLI is not a substitute for that signed bundle.

## Historical source and functional evidence

These records retain their named source revisions and checkpoint boundaries.
They do not qualify the current `0.17.0 (27)` UI source. Its completed, scoped
UI acceptance is recorded in the opening Graphite section; the October 3 `0.16.5 (26)`
candidate retains its separate evidence and unperformed shipping paths.

The September 20 adversarial pre-release audit corrected scoped dashboard
mutation authorization, a misclassified state-changing Stjornarvald route, an
unbounded port-owner subprocess path, Release entitlement/testability settings,
and browser DOM/error handling. Both SwiftPM products, the canonical Debug
workspace build, and Xcode static analysis passed. The terminal full suite
executed **1,691 XCTest cases with 12 explicit skips and zero failures**. See
the [audit record](AUDIT-2026-09-20.md). The exact audited implementation is
signed revision `839e45035c30d12efcebfbe29f31387972eaa95b`. The audit did not
create or qualify a release artifact.

The September 21 `0.11.0 (3)` source change passed both SwiftPM product builds,
the canonical Apple Development-signed Debug workspace build, repository
hygiene, and the complete SwiftPM regression: **1,700 XCTest cases with 13
explicit environment/live skips and zero failures**. The full Xcode test graph
compiled and signed. A focused native UI execution timed out while macOS enabled
automation before the selected test began, so the click-through is retained as
a host-automation non-pass rather than product evidence. The working
installation was not replaced.

The September 23 `0.12.0 (4)` identity alignment is published at revision
`bd33fda1b683070dcf56c16bb4c8ac778623ae31`, tree
`46ebbe041732f8fdd22331c031e73b7d8f7ae10f`. Both SwiftPM products, the two
focused version-contract tests, repository hygiene, and the complete SwiftPM
regression passed; the terminal regression executed **1,720 XCTest cases with
13 explicit environment/live skips and zero failures**. The canonical Xcode
Debug app built and signed, and the project-local signed smoke bundle reported
`0.12.0` and build `4` from both its app metadata and CLI. Push, fetch, exact
local/remote revision readback, and zero divergence passed. The working
installation was not replaced, and no shipment artifact was created.

The September 23 `0.14.0 (6)` provider-integration source is revision
`65af43e31aa2b818ccd2f915aa7f89c34b7c821d`, tree
`945cdb9d6adaf17c85845fe846910ece527288fd`. It passed both SwiftPM product
builds and the complete SwiftPM regression: **1,849 XCTest cases with
13 explicit environment/live skips and zero failures**. The canonical Apple
Development-signed Debug workspace build succeeded. Focused canonical Xcode
execution then passed **83 Core tests**, **40 app-hosted tests**, and **six
native UI tests**, all with zero failures or skips. The UI pass covered every
primary view at minimum and normal widths, the compact equal-height
Storage/Managed Activity row, the eight-step Dashboard setup wizard,
Continuity title-bar clearance with no unused split, and LM Studio
**Connect and Check**. Existing Thread Performance Checker diagnostics in
`ProjectContextService` wait/shutdown paths were observed again, so this is not
a clean whole-application performance claim for that historical source. The
later `0.15.0 (14)` source repaired those product paths and passed 111/111
app-hosted cases with no structured runtime warnings. The owner installation
was not replaced. Claude Code Desktop and Codex Desktop were not exercised as live
external hosts; Grok remains non-selectable.

The follow-up Swift 6 warning repair is revision
`117aa95f982bccb4c1ef0d0acc8b92666127be70`, tree
`00344bd6a1ce72f278e1a832a1d6e9f3a27f2d9f`. It constructs the
desktop-attachment descriptor on demand and makes the Provider activation
callback explicitly main-actor `Sendable`. Both SwiftPM products, a fresh
canonical Apple Development-signed Debug workspace build, and focused
`DesktopProviderMCPAttachmentTests` (**3/3**) and
`ProviderConfigurationAppTests` (**20/20**) passed; neither reported source
diagnostic appeared. The exact Downloads workspace named by the Xcode
diagnostics also built successfully after receiving the same two source edits.
Both files were already target members, so the graph and version/build remain
unchanged. This is source-build and focused-test evidence, not installed-build
or shipment qualification.

Published source `8ca3f24d9a81adce56e1a5232a6181edd08cf00b`, tree
`9bc840d7fdfe47bd552c4b8e095091502fecc3b6`, is the `0.14.1 (7)` operability
correction. It restores
the complete Continuity detail/history/manual-action surface in a toolbar-safe
adaptive layout; places the persistent eight-step Guided Setup entry point in
the Dashboard title bar; keeps Managed Activity compact beside Storage; makes
the built-in Autonomy completion checkboxes selectable; and limits configured
completion choices to those built-ins while preserving additional requirements
only from the exact instruction package. It also hardens LM Studio CLI
discovery/start/readiness polling, unifies selectable-provider **Connect and
Check**, and corrects Codex/Grok desktop package details and strict activation
outcome handling. Focused deterministic suites for those surfaces pass in the
shared tree, including Provider configuration with one explicit
Keychain-environment skip. The exact `0.14.1 (7)` tree passed the full SwiftPM suite
with **1,844 tests, 13 explicit skips, and zero failures**; both SwiftPM products
and a fresh canonical arm64 Apple Development-signed Debug workspace build also
passed. The workspace build reported no compiler warnings, including neither of
the two previously reported Swift 6 diagnostics. Native UI verification passed
the complete eight-step wizard, Provider Connect and Check plus protected
contract failure, Autonomy automatic recovery, complete Continuity detail and
title-bar clearance, compact Storage/Managed Activity geometry, and all-primary-
view containment/alignment at minimum and normal widths. The UI runner still
emits its known nonfailing main-thread runtime diagnostic; this is not presented
as a compiler warning. Live loaded-model LM Studio, live Claude/Codex hosts,
installed-build evidence and shipment remain separate. The wiki was published
at `54c714a71f872152f4af6869428c63018cd44a09`; a checksum comparison found no
tracked-file difference between canonical `main` and
`/Users/flynn/Downloads/Forge-Conductor-MacOS-main`, whose clean workspace build
also completed with no warning or error lines.

The earlier September 17 distribution-evidence source is owner-authored revision
`b756b243d24d7dd06098dbbafcdfaa77ab7c97e0`, tree
`6c03f40e2b04ae6dfd689c9347a84014f7ebe496`; its final GitHub workflow passed
native source integrity plus Swift and Xcode Debug/Release lanes. Local and
remote `main` were then synchronized at documentation closeout revision
`f02abeb8c940c8d998f822fd4f1cad5c20c7765e`, tree
`c6475126b54c8ff8de1465940e3ecc3c702a00eb`. That closeout changes
documentation only and leaves that historical native graph unchanged. These
revisions remain distribution evidence for the source they name. They did not
establish the then-current `0.14.4 (10)` source result and do not qualify the
current `0.17.0 (27)` source.

| Surface | Recorded checkpoint result | Boundary |
|---|---|---|
| 0.14.1 operability correction | Published source `8ca3f24d9a81adce56e1a5232a6181edd08cf00b`, tree `9bc840d7fdfe47bd552c4b8e095091502fecc3b6`, passed **1,844 tests with 13 explicit skips and zero failures**. Both SwiftPM products and a clean canonical arm64 Apple Development-signed Debug workspace build passed with no warning or error lines. Native UI coverage passed the eight-step Guided Setup, Autonomy recovery, complete Continuity detail/title-bar geometry, Provider Connect and Check plus contract-failure presentation, compact Dashboard Storage/Managed Activity geometry, and every primary view at minimum and normal window sizes. The checkpoint version/build constants and all Xcode configurations were aligned to `0.14.1 (7)`. | One Provider configuration case is an explicit Keychain-environment skip, and the UI runner retains a nonfailing main-thread runtime diagnostic. No fresh live loaded-model LM Studio or live Claude/Codex host result is claimed; installed-build and distribution-artifact evidence remain separate. |
| Historical Swift/Core provider baseline | The `0.14.0 (6)` provider baseline `65af43e31aa2b818ccd2f915aa7f89c34b7c821d`, tree `945cdb9d6adaf17c85845fe846910ece527288fd`, passed both SwiftPM product builds and a direct full-suite terminal run with **1,849 XCTest cases**, **13 explicit environment/live skips, and zero failures**. The warning-repair source `117aa95f982bccb4c1ef0d0acc8b92666127be70`, tree `00344bd6a1ce72f278e1a832a1d6e9f3a27f2d9f`, separately passed both SwiftPM product builds, a fresh canonical Apple Development-signed Debug workspace build, and the focused **3/3** MCP attachment plus **20/20** Provider configuration cases without either reported Swift diagnostic. | The 1,849-case regression remains bound to its exact baseline revision and is not claimed for the current `0.18.0 (28)` source. Declared skips remain distinct from passes. Live desktop-host, installed-build, distribution-artifact, and shipment qualification remain separate. |
| Projects and Manager | The published-tree Xcode **My Mac** product registered picker-selected and absolute-path projects, authorized and saved canonical roots, rejected filesystem root, and retained state across relaunch. | That project-registration flow did not qualify the installed protected filesystem service as a distinct process. |
| Provider integrations | The 0.14.0 source implements mutually exclusive LM Studio, Claude Code Desktop, and Codex Desktop selection; transactional Forge-owned desktop package installation, rollback, repair, and removal; a bounded durable operation ledger; revision-bound run admission; authenticated loopback hooks; and selected-provider readiness on Dashboard and Guided Setup. Desktop sessions receive a provider-specific MCP launch command and a five-minute, single-use capability bound to provider, session, run, project generation, selection revision, deployment, and frozen authorization scope. Project tools stay unavailable until `desktop_run_attach` atomically consumes that capability. Deterministic focused coverage passed **100/100**; canonical Xcode passed **83/83 Core**, **40/40 app-hosted**, and **6/6 native UI** cases; the full SwiftPM regression passed **1,849 cases with 13 explicit skips and zero failures**. Grok Build remains visible but non-selectable for owned-artifact cleanup and forward compatibility. | Deterministic tests and an installation receipt do not prove that a selectable desktop host is open, has reloaded the package, has accepted hook trust, or has completed a live session. Claude and Codex require separate live acceptance; neither qualifies the other. Grok's documented startup/prompt hook outputs do not deliver Forge's initial assignment context, so no ready, run, or live-support claim is made for Grok in 0.14.0. The Thread Performance Checker limitation belongs to that historical source; `0.15.0 (14)` repaired the product paths and passed 111/111 app-hosted cases with no structured runtime warnings. |
| LM Studio Provider | The published-tree native UI saved the loopback endpoint and loaded `qwen/qwen3.8-27b` model, refreshed inventory, passed the connection probe, replaced the manager, retained configuration, and passed again. Checkpoint deterministic recovery coverage verifies bounded discovery across system, per-user, Homebrew, and `PATH` CLI locations; wrapped status JSON and string ports; server start; delayed readiness; reported-port fallback; cancellation; and fail-closed malformed, timed-out, or truncated results. | A downloaded or listed model is not treated as loaded; the exact loaded variant remains required. The host had no loaded model during that checkpoint qualification, so the record claims no fresh live contract-probe pass. |
| Revision-3 Provider preparation | Published source `01c874e17c9a26c8f3111981748ed1bd3bdc1f81` passed seven deterministic preparation cases with one explicit live-only skip plus a separately enabled 1/1 live LM Studio `openai/gpt-oss-20b` case. The live operation preserved the pin, verified the contract, wrote the revision-bound readiness receipt, and reused that exact receipt idempotently. Provider configuration passed 14/14 with one explicit disposable-Keychain skip; app provider contracts passed 11/11, operator contracts 10/10, and dashboard security 7/7. | External service start and model load remain typed operator actions when the provider offers no supported authenticated lifecycle API. A focused native UI run timed out while enabling automation before test execution and is a non-pass. |
| Revision-3 runtime readiness | Published source `01c874e17c9a26c8f3111981748ed1bd3bdc1f81` passed focused checks proving an unavailable optional Python runtime does not disable the shell, an explicitly required Python runtime produces exactly one recovery action, nil-path legacy state remains `unknown`, and application-wide shell denial is reported at its true policy scope. Both SwiftPM products, the signed canonical Debug app build, and the universal Xcode Core test target build passed with the new resolver and test in their canonical targets. | Runtime necessity is derived only from explicit structured evidence; task prose is intentionally not interpreted as authority. A zero-selected app-test filter was a non-pass and is not test evidence. |
| Managed Autonomy | The checkpoint source exposes selectable built-in completion checks and preserves additional requirements only from the exact bound instruction package. Package requirements are read-only in the prepared and running task; unknown configuration-owned identifiers are rejected. Durable Manager evidence, retained completion requests, provider wait/resume, and state-derived recovery guidance have focused deterministic coverage. The embedded watchdog, settled-task deletion, pause/bounded-retry/terminal-stop behavior, and custom model instructions remain available. | Completion remains fail closed without exact durable evidence. That checkpoint has deterministic focused evidence; it is not an installed-build claim. |
| Dashboard operability | Published implementation `2319db359f28fba9cf350694ff8f66a7ecc70491` shortens Load Trace and pairs it with bounded status/load cards for headless LM Studio, Autonomy, Continuity, and Rune Forge plus project progress. Directly below, Managed Activity combines the current package, inferred current step, durable delivered count, and run work with bounded operator-redacted assistant/model-error/tool summaries, orchestration events, and exact project/generation policy events. Exact run lookup survives the public recent-100 boundary and returns continuity for that same project/generation/run. Durable storage is capped at 2 KiB per summary and 128 assistant plus 128 tool rows per run; rows are independently content-hashed outside the append-only non-activity audit lineage. Both clients enforce a streamed 4 MiB response ceiling. The view-owned five-second refresh exists only while Dashboard is visible; presentation retains at most 100 app-local rows and caps each displayed activity message at 8 KiB. The retained native UI evidence covers all-primary-view containment/alignment, populated compact equal-height Storage/Managed Activity geometry/content, the Dashboard Guided Setup button, and the populated Rune Forge Policy Feed. | This is a bounded, coalesced latest-state monitor, not token streaming or persisted full-transcript evidence. Rune Forge remains an additive observer and does not control task outcomes. The working installation was not replaced; installed-build qualification remains separate. |
| Continuity | The r3 deterministic crash matrix recovers every managed transition with one accepted successor and one continuation. A source-bound live LM Studio `openai/gpt-oss-20b` run at an observed 65,536-token context triggered on exact provider usage, fenced predecessor tools, survived a post-bootstrap-response manager restart, accepted and consumed one fresh-root successor, performed the successor-only read, then preserved the same receipt/session/turn/tool set across another restart. Retained UI coverage preserves manual actions, exact operation identity, budget, handoff/successor detail, and history while keeping the title/Refresh control below the toolbar and eliminating the unused empty frame. | The live run injects one in-process post-commit crash boundary; the other transitions are covered deterministically rather than by real SIGKILL. At that checkpoint, LM Studio exposed no supported authenticated API for replacing an existing desktop GUI chat; the recorded automatic path used Forge-managed native host mode. Those runs did not qualify the installed build. |
| Resource policy | Focused Debug and final-source, Xcode-compiled signed Release Core stress each passed on the recorded **128 GiB Apple M5 Max** host while also executing the injected **8 GiB constrained policy**. The final Release report refuses to write `passed` after a recorded XCTest failure. | That checkpoint did not record a second physical-memory-capacity execution. |
| Native GUI | The published-tree production-onboarding surface passed all seven cases: five in the class run and the two live LM Studio cases in an exact zero-skip rerun after correcting Xcode environment inheritance. | The initial two explicit skips, earlier runner timeouts, and one retained transient live Provider failure remain nonpasses, not hidden passes. |
| Rune Forge and Stjornarvald | RF-SJ-00 through RF-SJ-10 are implemented. The full SwiftPM rerun passed 1,687 tests with 12 explicit skips; app-hosted Rune Forge/Guided Mode passed 9/9; native UI passed 5/5; prior focused non-interference, fault, restart, privacy, Thread Sanitizer, Xcode membership, signed Debug build, and strict signature evidence remains bound to the RF-SJ checkpoint. All 40 acceptance rows are individually recorded. | Thirty-nine rows are accepted. AC-032 remains limited because automated accessibility semantics and keyboard behavior passed but a human physical VoiceOver listening session was not performed. This is RF-SJ implementation acceptance; it does not qualify the current candidate for Developer ID distribution, notarization, installation, or shipment. |

## Historical 0.9.0 (1) distribution evidence — September 17

This receipt retains the September 17 artifacts and assessment results. It is
separate from the October 3 `0.16.5 (26)` archive/export evidence above.

The exact owner-authored published tree at `f02abeb8`, including the tested
production source and documentation-only closeout, produced a universal
Developer ID Release archive and manual export. The archive has one canonical
`com.forge-conductor.app` product, version `0.9.0` build `1`, both `x86_64` and
`arm64` architectures, the required icon assets, and all four nested products.
Strict deep signing and the Release privileged-bundle checker passed on the
archive, export, ZIP extraction, and expanded Installer payload.

The unshipped source-bound app ZIP is:

- `/private/tmp/forge-published-main-developerid-app-20260917.zip`
- 22,112,426 bytes
- SHA-256 `a171d88409c2ef36816b5ccbc4bb304a3855b5fc7f3972492259adcd143ec338`

The matching Installer was signed through Apple's `productbuild` path with
James Daley's Developer ID Installer identity and a trusted timestamp. Its
expanded payload retained the exact exported signatures and bundle contents.

The unshipped source-bound Installer is:

- `/private/tmp/forge-published-main-signed-installer-20260917.pkg`
- 22,099,582 bytes
- SHA-256 `21a0dc3d68dfbd410408c38cb8e3ce1ee9a395269a30bbeba89d94ab13a16d28`

Neither exact published-tree artifact was notarized at this checkpoint.
Gatekeeper rejected the app and Installer as `source=Unnotarized Developer ID`.
Earlier notarized app receipts belong to their recorded source and do not
replace notarization of these exact artifacts.

## Historical distribution follow-up — September 17

This checklist records the unperformed distribution work for the `0.9.0 (1)`
artifacts above. It does not redefine the current assignment: deliver a buildable
Xcode project that allows the owner to build, sign, notarize, and distribute.
The October 3 checks qualify the corrected project and the isolated candidate
paths in the opening section; the owner retains installation, notarization,
distribution, and final shipping qualification.

1. Install the final candidate under a controlled owner-approved transition,
   then enable and qualify its Developer ID protected filesystem service as a
   distinct process, including successful authorized mutation and recovery
   behavior. At that checkpoint, System Settings readback showed Forge background
   activity off and Manager reported **Approval required**; read-only hashes
   identified an older daemon in the registered installation.
2. Notarize the exact published-tree archive/app and signed outer Installer,
   staple both artifacts, then pass local Gatekeeper execution and installation
   assessments. Existing Notary credentials are required; none are created by
   this workflow. No local `notarytool` profile/API key or repository Actions
   secret was available for command-line submission at that checkpoint; this
   historical receipt is not a current credential inventory.
3. Record the resource/stress case on another representative physical-memory
   capacity. The injected constrained policy is valuable coverage but is not a
   second physical host. The published revision's macOS CI Release lane passed
   and retained the guarded stress JSON and its host capacity; that hosted
   observation does not replace the physical-host check.
4. Pass public-download acceptance on the notarized artifacts. Shipment remains
   the owner's separate action after qualification.

The owner installation was not replaced at that checkpoint, and neither the
app ZIP nor the Installer was shipped or publicly published by that workflow.

## Setup entry points

Use [the User Guide](../USER-GUIDE.md) for Manager, Projects, Provider, and
Autonomy setup. Use [the Xcode Guide](../XCODE.md) to build or archive the exact
workspace product. LM Studio desktop MCP deployment and Forge-managed Provider
sessions are separate workflows, documented in
[LM Studio connection](LM-STUDIO-CONNECTION.md). Provider selection and desktop
host integration are documented in
[Provider integrations](PROVIDER-INTEGRATIONS.md). Built-in completion evidence
and instruction-package requirement ownership are documented in
[Completion evidence](NATIVE-COMPLETION.md).

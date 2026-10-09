# Native PCM16 WAV and FLAC writing

<a id="native-pcm16-wav-writing"></a>

Current source target **0.41.0 (57)** extends existing audio_write with exact optional wav/flac; omission remains WAV. Source qualification passed before the identity advance; matching selected-identity native 59, ordinary build/signature, App/CLI protocol and bounded Qwen API result-consumption checks passed. The selected-identity source 59 and all three product native PCM consumers passed. Separate source/native G3 and initial hygiene/whitespace checks passed; owner source/wiki delivery remains pending.

## Current input and output contract

Required path/content/sample_rate/channels and optional shared deadline_ms remain; optional format accepts exactly `"wav"` or `"flac"`. Malformed/other tokens return invalid_audio_arguments. Explicit case-insensitive .wav/.flac paths must match; no extension selects the format. Signed PCM16LE is nonempty, frame-major/interleaved, with rate exactly 8000/44100/48000 and channels 1/2. Booleans/fractions/strings, partial frames and noncanonical padded base64 are rejected.

```text
audio_write(path="<project>/silence.FLAC", content="AAA=", sample_rate=8000, channels=1, format="flac")
```

| Bound or identity | WAV | FLAC |
| --- | --- | --- |
| Supplied raw/base64 UTF-8 | 1,048,576/1,398,104 bytes | Same |
| Complete output | 44 + raw, at most 1,048,620 bytes | 42 + raw + blockCount * (10 + channels), at most 2,097,152 bytes |
| Engine | swift-pcm16-riff | native-swift-flac |
| Output contract | wav-pcm16le-interleaved-v1 | flac-pcm16le-verbatim-v1 |
| Input contract | pcm16le-interleaved-v1 | Same |
| Managed canonical arguments/results | Separate 65,536-byte bound | Same |

FLAC contains one STREAMINFO with rate, channels, 16-bit depth, total frame count and whole PCM MD5. Fixed blocks have nominal 4,608 frames and an unpadded final 1..4,608, independent verbatim channel subframes, CRC8 headers/CRC16 frames and exact EOF. Maximum 1 MiB raw has 114 mono or 57 stereo blocks. Verbatim coding promises exact supplied PCM, not compression efficiency. Successful ToolResult payloads keep eleven writer fields plus existing ok=true, twelve actual keys. No synthesis/playback/source-file codec conversion is added.

## Current owners and preservation

NativePCM16FLACWriter reuses the WAV EncodedAudio value and existing admission errors; its qualified serializer body has no testhook. DocsToolPack retains project context before/after encoding and the common pinned atomic writer, mode preservation and failure behavior. Own audio_write grant, ordinary enrollment/custom denial/imported capabilities, content redaction, idempotent completed replay and binary fs_read paging remain. WAV-specific worker/output/internal descriptions are mapped locally only on exact FLAC; codes and other messages remain. The bundled WAV heading/example and both original when_to_use hints remain, with additive FLAC guidance. All 85 neighboring full descriptors and omitted/explicit WAV complete same-path payload/bytes passed source preservation checks.

## Current evidence and remaining gates

The actual pre-version source area passed 59 distinct methods (8 FLAC, 9 WAV, 38 catalog and 4 audio broker) in 35.339 s, normal exit 0/unforced, with zero failures/skips on unchanged 473 inputs. The earlier focused 8 passed in 37.562 s and is a subset, adding no distinct methods. These tests ran with 0.40.0/56 authorities before the selected 0.41.0/57 identity advance.

The 59 methods include 11 new methods. Tests cover original short/block-boundary streams, independent restricted CRC/MD5/whole PCM/EOF inspection, six 1 MiB rate/channel combinations, malformed syntax/scalars/paths, complete bounds, own grants/stale context/modes/publication failures, explicit/default WAV parity and durable broker replay/refusal. The reader rejects unsupported syntax; its MD5 primitive shares CryptoKit with the writer, while whole decoded PCM and actual maximum golden stream hashes are separate checks. The source compile retains an unrelated TAR-test unnecessary-try warning; support zero-selection contributes no methods.

Separate standalone boundary and six 1 MiB rate-channel bitstreams and Apple whole PCM consumers passed. The 42-control refusal/cancellation mechanism used a test-only hook after an emitted block and measured four test-owned weak/deinit witnesses. These qualify only their standalone scopes. Historical framework callback, constructor and short-input NONPASSs remain retained; no framework-cause claim follows. Pre-cancel/source/test-hook checks do not establish actual product mid-loop or common late-cancel/revocation-before-rename behavior, heap leak freedom or general interoperability.

The selected .41/57 canonical native run passed the same 59 methods in 69.268 s. CLI/app compilation passed in 5.646/2.323 s; ordinary Debug/strict signature passed in 25.586/0.136 s on unchanged 473 inputs.

The ordinary candidate App/CLI routes each passed 40 responses/38 tool frames, eight binary readback pages (seven FLAC plus one WAV), 18 refusals, immediate-cancel destination preservation and complete WAV parity in 1.800/1.292 s. Each App/CLI result includes one FLAC and one WAV artifact, exact whole binary EOF, 86 catalog definitions with all 85 neighbors preserved, and normal native exit/both EOF/unforced. Qwen qwen/qwen3.8-27b passed in 41.703 s: three observed Low inputs, two selected audio_write/fs_read results consumed by completed turns 1/2, nine native responses/seven frames, complete 85-byte mono44100/16-frame FLAC EOF and exact four-scalar metadata ACK. This is the bounded API workflow, not GUI, installed or all-model qualification.

The selected .41/57 source rerun passed the same 59 distinct methods in 40.694 s (tests 33.227 s), matching the canonical native and pre-version method sets on unchanged 473 inputs.

Three actual App/CLI/Qwen FLAC outputs passed Apple afconvert whole RIFF/PCM checks in 0.024/0.018/0.017 s, each normal exit 0/unforced with both EOF and the owned group absent. Both App/CLI stereo48000/9,217-frame outputs decoded to the exact 36,868 supplied PCM bytes; Qwen mono44100/16-frame decoded to the exact 32 supplied bytes. Complete RIFF extents, PCM format and EOF were checked. This qualifies these three product outputs only.

Separate G3 source/native checks each passed the intended G1G10AcceptanceTests/testG3_VersionAndReleaseDocumentsAreAligned method in 1.389/2.869 s, normal exit 0/unforced with zero failures/skips. The selected-identity source 59 plus source G3 and native 59 plus native G3 give matching 60-method unions; no single 60-method run is claimed. The source support bundle selected zero methods and contributes no coverage. Native destination and DVTAssertions warnings remain in the retained log. Hygiene/whitespace passed in 0.657/0.139 s on the applied initial thirteen documents and unchanged 473 source inputs.

Final C2 reread the same seven immutable .41/57 C1 artifacts and Info identity without a rebuild. The complete 473-input map and all 66 historical/protected identities remained exact; fresh strict signature passed in 0.134 s. The C2 receipt is `native-audio-flac-final-candidate-root-readback-0410-v1.json`, SHA256 `38c6a5612bc8c7e0a9d84306d9983a5c26fe9fbad80df6ec2eba9ede356a62b6`. Owner source/wiki publication, readback and clean synchronization remain pending; final prose checks are recorded separately before publication. Standalone mechanism receipts do not replace integrated product consumers.

MP3, AAC, OGG/Opus and MIDI authoring, playback, installed operation, general lifetime/full web/all models/Release/shipment remain separate. The entire preceding .39 WAV body, including its unsupported-FLAC and pending statements at that tested time, follows as retained historical evidence.

## Preceding 0.39.0 (55) WAV qualification

Current source target **0.39.0 (55)** adds `audio_write` for supplied samples. Product qualification is open.

## Input and output contract

Required fields are `path`, `content`, `sample_rate` and `channels`; the shared `deadline_ms` field is optional. Additional keys are rejected. Use an explicit case-insensitive `.wav` path and canonical padded-base64 `content` containing signed PCM16 little-endian samples. Sample rate is exactly integer **8000, 44100 or 48000**; channels is exactly integer **1 or 2**. Stereo samples are frame-major and interleaved. Booleans, fractional/string scalars, empty PCM, partial frames and noncanonical base64 are rejected.

```text
audio_write(path="<project>/silence.WAV", content="AAA=", sample_rate=8000, channels=1)
```

This supplies one zero mono frame. The tool packages the supplied samples; it does not synthesize or play sound.

| Bound | Contract |
| --- | --- |
| Raw PCM | Nonempty complete frames, at most 1,048,576 bytes |
| Base64 UTF-8 | At most 1,398,104 bytes; strict canonical padding and pad bits |
| Output | Exactly 44 + raw bytes, at most 1,048,620 bytes |
| Rates/channels | 8000/44100/48000; mono/stereo |
| Managed broker arguments/results | Separate 65,536-byte canonical JSON bound remains |

The writer preflights the exact output size before allocation. Duration is derived from frames/sample_rate and the raw bound; there is no duration or codec argument. Output is a little-endian RIFF/WAVE container containing exactly a 16-byte PCM fmt chunk and a data chunk, with a 44-byte header and unchanged supplied PCM bytes. Engine is `swift-pcm16-riff`; input contract `pcm16le-interleaved-v1`, output contract `wav-pcm16le-interleaved-v1`.

Successful metadata reports path, format, engine, bytes_written, sha256, pcm_bytes, sample_rate, channels, frames and both contracts. Direct `fs_read` base64 pages retain their existing cursor/EOF semantics. A maximum writer input does not imply a maximum managed/model call: the complete encoded argument must fit the broker's independent JSON bound.

## Owners and preserved behavior

`NativePCM16WAVWriter` is a call-local Foundation worker with bounded cancellation checkpoints and no AudioFile handle, codec process or new dependency. `DocsToolPack.audioWrite` validates project context before/after encoding and uses `FilesystemToolPack.writePinnedText` for publication. Existing path pinning, modes, atomic write and cancellation semantics remain in that shared owner. The tool requires its own `audio_write` grant; neighboring document grants do not imply it. Ordinary defaults add the tool, while custom denials and imported explicit grants remain narrow. Completed small calls are classified idempotent; broker replay and the JSON refusal bound have their own tests. Content remains audit-redacted.

The canonical project adds exactly the new writer to ForgeConductorCore and the new test file to ForgeConductorTests. Package target discovery, workspace layout, existing image/ZIP writers and prior formats are preserved. Canonical native tests and the ordinary Debug build exercised both new memberships; their receipts remain separate from source tests. MP3, AAC, OGG/Opus, FLAC, MIDI, AIFF and CAF authoring are outside this tool; the historical attachment is a capability request/data source, not dispatch instructions or evidence of current codec support.

## Evidence and remaining gates

The missing-feature catalog method failed at the absent definition in 7.325 s, normal exit 1, and remains NONPASS. After integration, the same one method passed in 19.268 s, normal exit 0. The same method is included in later owning coverage; both original executions retain their input identities. Zero-selected support targets add no tests.

Twelve new acceptance methods are defined: nine writer/tool methods, one catalog method and two broker methods. The actual affected source selection passed nine writer, 37 catalog and two audio broker methods (48) in 31.228 s. A separate 24-method preservation selection passed in 13.654 s; the exact matching 72 canonical native methods passed in 67.506 s. Tests define seven small fixed fixtures, six full-1-MiB rate/channel combinations, RIFF mutation/EOF controls, strict admission, modes/context/grants/defaults/audit, completed replay and over-bound refusal before dispatch. The owning logs exercised these cases; source/native selections remain distinct from runtime product consumers.

All owning/preservation selections passed normal exit 0/unforced without failed/skipped tests on the same 468 inputs. Swift CLI/app compilation passed in 1.106/1.276 s; ordinary Debug/strict signature passed in 24.825/0.139 s, normal exit 0/unforced, for the separate .39/55 seven-artifact candidate.

Candidate App/CLI wire checks passed in 1.558/1.098 s: 33 correlated responses/31 complete tool frames, three exact 46/52/60-byte WAVs, 11 refusals and immediate -32800 cancellation with the original target preserved per route. All 85 prior descriptors, packaged Docs bytes, ZIP/PNG parity, config, 468 inputs, candidate seven and historical 52 guards stayed exact. A Docs session exercised the own grant; a separate read-only session denied audio_write.

Qwen qwen/qwen3.8-27b passed in 38.544 s: three normal completed responses with three observed Low templates, two actual audio_write/fs_read results consumed by completed turns 1/2, nine native responses/seven tool frames, and a strict six-scalar ACK of the exact 52-byte stereo WAV. Native/model/observer/outer groups were absent afterward; current inputs and guards stayed exact. Its exact 8-byte supplied PCM is 0100030002000400; whole WAV SHA is ad213d8442fbf371662e1a93325138c0e404ce4e4e7f78ab0c2d3692caccb64d. Seven small product WAVs passed exact whole-header/PCM checks and both public native URL read routes in 0.260 s, normal exit 0/full EOF/unforced: seven AudioFile Close calls with 84 strict property values, seven ExtAudioFile Dispose calls with whole PCM and explicit zero-frame EOF, and 14 wrapper deinit/weak-gone observations. The 468 source inputs, seven candidate artifacts and historical 52 guards stayed exact. Initial document G3 passed one actual method per source/native route in 1.650/2.712 s, normal exit 0/unforced. Source 48 + 24 + G3 and native 72 + G3 give 73 distinct methods per route; these are separate selections. Hygiene/whitespace passed in 0.667/0.140 s, normal exit 0/unforced, on the unchanged 468 source/graph inputs. Final prose hygiene/whitespace passed; exact source/wiki delivery remains pending; the phase stays open. This scoped consumer does not qualify playback, large product output, framework-wide leak freedom or installed operation. Earlier standalone serializer/parser/URL gates retain their selected fixture identities; the new product consumer qualifies only its seven small outputs. The independent full negative RIFF product-output gate remains separate. Two weak-variable compiler warnings were retained for the external consumer; wrapper observations do not prove framework-wide leak freedom. Earlier native callback packet-count NONPASSs remain retained; no framework-cause or codec claim follows from them.

Pre-cancellation and expired-deadline tests do not prove cancellation after encoding has started. Passed App/CLI immediate wire cancellation has the same limit. The common writer's late-cancel/revocation-before-rename boundary remains open. Playback quality, installed product behavior, general lifetime/leak freedom, full web/all models, Release and shipment are separate gates.

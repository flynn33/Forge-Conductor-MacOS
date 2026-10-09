# Native PCM16 WAV writing

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

import Foundation
import Darwin
import CryptoKit
import XCTest
@testable import ForgeConductorCore

final class NativePCM16FLACWriterTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("forge-pcm16-flac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        temporaryRoot = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporaryRoot) }

    func testShortFinalAndAllBlockBoundariesPreserveWholePCMCRCAndMD5() async throws {
        try await Task.detached(priority: .utility) {
            let cases: [(Int, Int, Int)] = [(8000, 1, 1), (44100, 1, 1), (44100, 1, 15), (44100, 1, 16),
                (48000, 2, 4096), (48000, 2, 4607), (48000, 2, 4608), (48000, 2, 4609), (48000, 2, 9216), (48000, 2, 9217)]
            for (rate, channels, frames) in cases {
                let raw = rate == 8000 ? Data([0, 0]) : Self.boundaryPCM(frames: frames, channels: channels)
                let encoded = try NativePCM16FLACWriter.encode(content: raw.base64EncodedString(), sampleRate: rate, channels: channels)
                XCTAssertEqual(encoded.sampleRate, rate); XCTAssertEqual(encoded.channels, channels)
                XCTAssertEqual(encoded.frames, frames); XCTAssertEqual(encoded.pcmBytes, raw.count)
                let inspected = try Self.inspectFLAC(encoded.data, rate: rate, channels: channels)
                XCTAssertEqual(inspected.pcm, raw); XCTAssertEqual(inspected.frames, frames)
                XCTAssertEqual(inspected.blocks, (frames + 4607) / 4608)
                XCTAssertEqual(encoded.data.count, 42 + raw.count + inspected.blocks * (10 + channels))
                XCTAssertEqual(try NativePCM16FLACWriter.encode(content: raw.base64EncodedString(), sampleRate: rate, channels: channels).data, encoded.data)
            }
        }.value
    }

    func testAllSixOneMiBInputsExactOutputCapsAndRawCeiling() async throws {
        try await Task.detached(priority: .utility) {
            let raw = Self.noise(samples: 524_288), content = raw.base64EncodedString()
            XCTAssertEqual(raw.count, 1_048_576)
            XCTAssertEqual(JSONSupport.sha256Hex(raw), "58426fea4953cd52e9851ec149228a14e8685fd8eaa9bd9a2802b50f75a7a74c")
            let hashes: [Int: [String]] = [
                8000: ["9469dbf7b9b524478737a3252a4c6223a1eaefb0037b86453365a1d86d7bf320", "a12af39d29319a5aaef91b8c91ff74150c21910d64fb05dc2d57ad8407a429f7"],
                44100: ["42e6186a43e2c6cde98ab5e6c5dfacb5281f19dba62368d1e027d6eb0ebd82d8", "71693c01b84106ff2f1c1ab3aa56d89adf29a4668c72a0cedd1ed9ff31406eee"],
                48000: ["9dc9b6c812c3c705a1a61af9b915fca666349a66681805278942df47f5a7bf9f", "eaa13239a828544081f364c8c867d6164c9335adfd244ecb2730225fa1da518e"]]
            for rate in [8000, 44100, 48000] {
                for channels in [1, 2] {
                    let result = try NativePCM16FLACWriter.encode(content: content, sampleRate: rate, channels: channels)
                    XCTAssertEqual(result.data.count, channels == 1 ? 1_049_872 : 1_049_302)
                    XCTAssertEqual(JSONSupport.sha256Hex(result.data), try XCTUnwrap(hashes[rate])[channels - 1])
                    XCTAssertEqual(result.frames, 1_048_576 / (channels * 2))
                    let inspected = try Self.inspectFLAC(result.data, rate: rate, channels: channels)
                    XCTAssertEqual(inspected.pcm, raw); XCTAssertEqual(inspected.blocks, channels == 1 ? 114 : 57)
                    XCTAssertEqual(try NativePCM16FLACWriter.encode(content: content, sampleRate: rate, channels: channels, outputByteLimit: result.data.count).data, result.data)
                    XCTAssertThrowsError(try NativePCM16FLACWriter.encode(content: content, sampleRate: rate, channels: channels, outputByteLimit: result.data.count - 1)) {
                        XCTAssertEqual($0 as? NativePCM16WAVError, .outputLimit)
                    }
                }
            }
            for limit in [-1, 0, 54, NativePCM16FLACWriter.maximumOutputBytes + 1] {
                XCTAssertThrowsError(try NativePCM16FLACWriter.encode(content: "AAA=", sampleRate: 8000, channels: 1, outputByteLimit: limit)) {
                    XCTAssertEqual($0 as? NativePCM16WAVError, .outputLimit)
                }
            }
            XCTAssertThrowsError(try NativePCM16FLACWriter.encode(content: (raw + Data([0, 0])).base64EncodedString(), sampleRate: 8000, channels: 1)) {
                XCTAssertEqual($0 as? NativePCM16WAVError, .inputLimit)
            }
            XCTAssertThrowsError(try NativePCM16FLACWriter.encode(content: String(repeating: "A", count: 1_398_104), sampleRate: 8000, channels: 1)) {
                XCTAssertEqual($0 as? NativePCM16WAVError, .inputLimit)
            }
            XCTAssertThrowsError(try NativePCM16FLACWriter.encode(content: String(repeating: "A", count: 1_398_108), sampleRate: 8000, channels: 1)) {
                XCTAssertEqual($0 as? NativePCM16WAVError, .inputLimit)
            }
        }.value
    }

    func testIndependentRestrictedReaderPinnedPositiveAndMalformedWholeStreamRefusals() throws {
        // Pinned original 55-byte mono zero stream; this positive does not call the encoder.
        let valid = try Self.hex("664c6143800000221200120000000d00000d01f400f000000001c4103f122d27677c9db144cae1394a66fff87408000000950200006fea")
        let decoded = try Self.inspectFLAC(valid, rate: 8000, channels: 1)
        XCTAssertEqual(decoded.pcm, Data([0, 0])); XCTAssertEqual(decoded.frames, 1); XCTAssertEqual(decoded.blocks, 1)
        for offset in [0, 4, 7, 8, 11, 12, 17, 18, 21, 25, 26, 42, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54] {
            var changed = valid; changed[offset] ^= 1
            XCTAssertThrowsError(try Self.inspectFLAC(changed, rate: 8000, channels: 1), "offset \(offset)")
        }
        for offset in [45, 50] {
            var changed = Array(valid)
            changed[offset] ^= 1
            changed[49] = UInt8(Self.polynomialCRC(changed[42..<49], width: 8, polynomial: 0x07))
            let crc = Self.polynomialCRC(changed[42..<53], width: 16, polynomial: 0x8005)
            changed[53] = UInt8(truncatingIfNeeded: crc >> 8); changed[54] = UInt8(truncatingIfNeeded: crc)
            XCTAssertThrowsError(try Self.inspectFLAC(Data(changed), rate: 8000, channels: 1), "valid CRCs must not admit unsupported header/subframe")
        }
        XCTAssertThrowsError(try Self.inspectFLAC(Data(valid.dropLast()), rate: 8000, channels: 1))
        XCTAssertThrowsError(try Self.inspectFLAC(valid + Data([0]), rate: 8000, channels: 1))
        XCTAssertThrowsError(try Self.inspectFLAC(valid, rate: 44100, channels: 1))
        XCTAssertThrowsError(try Self.inspectFLAC(valid, rate: 8000, channels: 2))
    }

    func testStrictScalarsCanonicalBase64AndCompleteFrameRefusalsKeepExistingErrorCodes() async throws {
        try await Task.detached(priority: .utility) {
            for value in [NSNull(), true, "8000", 8000.5, Double.infinity, 0, -1, 96000, Int.max] as [Any] {
                XCTAssertThrowsError(try NativePCM16FLACWriter.sampleRate(value)) { XCTAssertEqual($0 as? NativePCM16WAVError, .invalidSampleRate) }
            }
            for value in [NSNull(), true, "1", 1.5, 0, -1, 3, Int.max] as [Any] {
                XCTAssertThrowsError(try NativePCM16FLACWriter.channels(value)) { XCTAssertEqual($0 as? NativePCM16WAVError, .invalidChannels) }
            }
            for text in ["", "AA", "AAA", "AAA=\n", " AAA=", "AA-=", "AA_=", "A===", "AB==", "AAB=", "日本語"] {
                XCTAssertThrowsError(try NativePCM16FLACWriter.encode(content: text, sampleRate: 8000, channels: 1)) {
                    XCTAssertEqual($0 as? NativePCM16WAVError, .invalidContent, text)
                }
            }
            for (text, channels) in [("AA==", 1), ("AAAA", 1), ("AAA=", 2), ("AAAAAAA=", 2)] {
                XCTAssertThrowsError(try NativePCM16FLACWriter.encode(content: text, sampleRate: 8000, channels: channels)) {
                    XCTAssertEqual($0 as? NativePCM16WAVError, .incompleteFrames)
                }
            }
            XCTAssertThrowsError(try NativePCM16FLACWriter.encode(content: "AAA=", sampleRate: 96000, channels: 1)) { XCTAssertEqual($0 as? NativePCM16WAVError, .invalidSampleRate) }
            XCTAssertThrowsError(try NativePCM16FLACWriter.encode(content: "AAA=", sampleRate: 8000, channels: 3)) { XCTAssertEqual($0 as? NativePCM16WAVError, .invalidChannels) }
        }.value
    }

    func testWorkerPreCancellationDeadlineAndFormatSpecificWorkerMessages() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await MainActor.run {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertThrowsError(try NativePCM16FLACWriter.encode(content: "AAA=", sampleRate: 8000, channels: 1)) { XCTAssertEqual($0 as? NativePCM16WAVError, .workerRequired) }
            try Self.withToolApp(root: root) { app, client, project in
                for format in ["wav", "flac"] {
                    let destination = project.appendingPathComponent("worker.\(format)")
                    let result = try XCTUnwrap(try DocsToolPack().handle(name: "audio_write", arguments: Self.arguments(destination, raw: Data([0, 0]), rate: 8000, channels: 1, format: format), context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, "audio_worker_required")
                    XCTAssertEqual(result.payload["message"] as? String, format == "flac" ? "FLAC encoding requires a worker thread" : "WAV encoding requires a worker thread")
                    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                }
            }
        }
        try await Task.detached(priority: .utility) {
            let token = ToolCallCancellation(timeoutSeconds: 5); token.cancel()
            XCTAssertThrowsError(try NativePCM16FLACWriter.encode(content: "AAA=", sampleRate: 8000, channels: 1, cancellation: token)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try NativePCM16FLACWriter.encode(content: "AAA=", sampleRate: 8000, channels: 1, cancellation: ToolCallCancellation(timeoutSeconds: 0))) { XCTAssertTrue($0 is ToolCallDeadlineExceeded) }
        }.value
    }

    func testToolFLACReplacementMetadataBinaryEOFAndExplicitWAVDefaultParity() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) {
            try Self.withToolApp(root: root) { app, client, project in
                let raw = Self.boundaryPCM(frames: 9217, channels: 2)
                let existing = project.appendingPathComponent("replace.FLAC")
                try Data("prior".utf8).write(to: existing); XCTAssertEqual(Darwin.chmod(existing.path, 0o600), 0)
                for destination in [existing, root.appendingPathComponent("owner-authorized.flac")] {
                    let result = try app.tools.call(name: "audio_write", arguments: Self.arguments(destination, raw: raw, rate: 48000, channels: 2, format: "flac"), clientID: client)
                    XCTAssertTrue(result.ok, "\(result.payload)")
                    XCTAssertEqual(Set(result.payload.keys), ["ok", "path", "format", "engine", "bytes_written", "sha256", "pcm_bytes", "sample_rate", "channels", "frames", "input_contract", "output_contract"])
                    let data = try Data(contentsOf: destination)
                    XCTAssertEqual(result.payload["path"] as? String, destination.path)
                    XCTAssertEqual(result.payload["format"] as? String, "flac"); XCTAssertEqual(result.payload["engine"] as? String, "native-swift-flac")
                    XCTAssertEqual(result.payload["input_contract"] as? String, "pcm16le-interleaved-v1"); XCTAssertEqual(result.payload["output_contract"] as? String, "flac-pcm16le-verbatim-v1")
                    XCTAssertEqual(result.payload["sample_rate"] as? Int, 48000); XCTAssertEqual(result.payload["channels"] as? Int, 2)
                    XCTAssertEqual(result.payload["frames"] as? Int, 9217); XCTAssertEqual(result.payload["pcm_bytes"] as? Int, raw.count)
                    XCTAssertEqual(result.payload["bytes_written"] as? Int, data.count); XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(data))
                    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue, destination == existing ? 0o600 : 0o644)
                    var readback = Data(), offset = 0, sawEOF = false
                    for _ in 0..<4 {
                        let read = try app.tools.call(name: "fs_read", arguments: ["path": destination.path, "encoding": "base64", "byte_offset": offset, "maximum_bytes": 32768], clientID: client)
                        XCTAssertTrue(read.ok, "\(read.payload)")
                        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(read.payload["content"] as? String)))
                        readback.append(bytes)
                        let next = try XCTUnwrap(read.payload["next_byte_offset"] as? Int)
                        XCTAssertEqual(next, offset + bytes.count); offset = next
                        if read.payload["has_more"] as? Bool == false { sawEOF = true; break }
                        XCTAssertFalse(bytes.isEmpty)
                    }
                    XCTAssertTrue(sawEOF); XCTAssertEqual(offset, data.count); XCTAssertEqual(readback, data)
                    XCTAssertEqual(try Self.inspectFLAC(data, rate: 48000, channels: 2).pcm, raw)
                }
                var wavBytes: [Data] = [], wavPayloads: [String] = []
                let path = project.appendingPathComponent("parity.WAV")
                for format in [nil, "wav"] {
                    let result = try app.tools.call(name: "audio_write", arguments: Self.arguments(path, raw: raw, rate: 48000, channels: 2, format: format), clientID: client)
                    XCTAssertTrue(result.ok); XCTAssertEqual(result.payload["format"] as? String, "wav")
                    XCTAssertEqual(result.payload["engine"] as? String, "swift-pcm16-riff")
                    XCTAssertEqual(result.payload["output_contract"] as? String, "wav-pcm16le-interleaved-v1")
                    wavBytes.append(try Data(contentsOf: path))
                    wavPayloads.append(try JSONSupport.canonicalJSON(result.payload))
                }
                XCTAssertEqual(wavBytes[0], wavBytes[1]); XCTAssertEqual(wavPayloads[0], wavPayloads[1])
                XCTAssertEqual(wavBytes[0], try NativePCM16WAVWriter.encode(content: raw.base64EncodedString(), sampleRate: 48000, channels: 2).data)
            }
        }.value
    }

    func testToolStrictFormatsPathsRefusalsAndPinnedFailuresPreserveDestination() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) {
            try Self.withToolApp(root: root) { app, client, project in
                let destination = project.appendingPathComponent("strict.flac"), prior = Data("preserve".utf8)
                try prior.write(to: destination)
                let valid = Self.arguments(destination, raw: Data([0, 0]), rate: 8000, channels: 1, format: "flac")
                let bad: [(String, Any, String)] = [("format", NSNull(), "invalid_audio_arguments"), ("format", 1, "invalid_audio_arguments"),
                    ("format", true, "invalid_audio_arguments"), ("format", "FLAC", "invalid_audio_arguments"), ("format", "mp3", "invalid_audio_arguments"),
                    ("format", "", "invalid_audio_arguments"), ("unknown", "flac", "invalid_audio_arguments"),
                    ("path", 1, "invalid_path"), ("path", true, "invalid_path"), ("path", " \n", "invalid_path"), ("path", "nul\u{0}.flac", "invalid_path"),
                    ("path", "absent-extension", "invalid_path"), ("path", destination.deletingPathExtension().appendingPathExtension("wav").path, "invalid_path"),
                    ("content", false, "invalid_audio_content"), ("content", "AAB=", "invalid_audio_content"), ("content", "AA==", "invalid_audio_frames"),
                    ("sample_rate", true, "invalid_audio_sample_rate"), ("sample_rate", 96000, "invalid_audio_sample_rate"), ("channels", "1", "invalid_audio_channels")]
                for (key, value, code) in bad {
                    var args = valid; args[key] = value
                    let result = try XCTUnwrap(try DocsToolPack().handle(name: "audio_write", arguments: args, context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, code)
                    XCTAssertEqual(try Data(contentsOf: destination), prior)
                }
                var absentFormat = valid; absentFormat.removeValue(forKey: "format")
                let mismatch = try XCTUnwrap(try DocsToolPack().handle(name: "audio_write", arguments: absentFormat, context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(mismatch.ok); XCTAssertEqual(mismatch.payload["code"] as? String, "invalid_path")
                for key in ["content", "sample_rate", "channels"] {
                    var missing = valid; missing.removeValue(forKey: key)
                    XCTAssertFalse(try XCTUnwrap(try DocsToolPack().handle(name: "audio_write", arguments: missing, context: nil, clientID: client, app: app, cancellation: nil)).ok)
                }
                for cancellation in [ToolCallCancellation(timeoutSeconds: 5), ToolCallCancellation(timeoutSeconds: 0)] {
                    if !cancellation.isDeadlineExceeded { cancellation.cancel() }
                    XCTAssertThrowsError(try DocsToolPack().handle(name: "audio_write", arguments: valid, context: nil, clientID: client, app: app, cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError || $0 is ToolCallDeadlineExceeded) }
                }
                let outside = root.appendingPathComponent("outside", isDirectory: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true); try prior.write(to: outside.appendingPathComponent("keep.flac"))
                let link = project.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                let directory = project.appendingPathComponent("directory.flac", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try prior.write(to: directory.appendingPathComponent("keep"))
                for path in [link.appendingPathComponent("keep.flac"), directory] {
                    let result = try XCTUnwrap(try DocsToolPack().handle(name: "audio_write", arguments: Self.arguments(path, raw: Data([0, 0]), rate: 8000, channels: 1, format: "flac"), context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, "audio_write_failed")
                }
                XCTAssertEqual(try Data(contentsOf: destination), prior); XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("keep.flac")), prior)
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path).sorted(), ["directory.flac", "link", "strict.flac"])
            }
        }.value
    }

    func testFLACOwnGrantRawPathCustomDenialStaleContextAndBothDocsConsumers() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) {
            try Self.withToolApp(root: root) { app, client, project in
                let context = try app.projectContexts.invocationContext(for: client)
                let destination = project.appendingPathComponent("denied.flac")
                let args = Self.arguments(destination, raw: Data([0, 0]), rate: 8000, channels: 1, format: "flac")
                let authorization = ToolAuthorizationService(paths: app.paths, config: app.config)
                for raw in [NSNull(), 1, true, ["bad.flac"], ["path": "bad.flac"], "", " \n", "nul\u{0}.flac"] as [Any] {
                    var bad = args; bad["path"] = raw
                    guard case .denied(let code, let message) = try authorization.authorize(tool: "audio_write", arguments: bad, context: context, clientID: client, binding: nil, cancellation: nil) else { XCTFail("Do not coerce raw FLAC paths"); continue }
                    XCTAssertEqual(code, "invalid_path"); XCTAssertEqual(message, "FLAC path must be a nonblank string without NUL bytes")
                }
                var wavBad = args; wavBad["path"] = false; wavBad.removeValue(forKey: "format")
                guard case .denied(let wavCode, let wavMessage) = try authorization.authorize(tool: "audio_write", arguments: wavBad, context: context, clientID: client, binding: nil, cancellation: nil) else { return XCTFail("Preserve WAV raw path refusal") }
                XCTAssertEqual(wavCode, "invalid_path"); XCTAssertEqual(wavMessage, "WAV path must be a nonblank string without NUL bytes")
                let deniedClient = ClientID("flac-denied")
                _ = try app.projectContexts.bind(owner: ProjectBindingOwner(kind: .mcpClient, id: deniedClient.rawValue), projectID: context.projectID,
                    generation: context.projectGeneration, authorizationScope: ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots,
                        allowedTools: ["fs_write", "image_write", "archive_write"], networkAllowed: false, maximumInlineOutputBytes: 65536))
                let denied = try app.tools.call(name: "audio_write", arguments: args, clientID: deniedClient)
                XCTAssertFalse(denied.ok); XCTAssertEqual(denied.payload["code"] as? String, "tool_not_granted")
                for specs in [app.catalog.all(), AgentCatalog.builtinDefaults()] {
                    let docs = try XCTUnwrap(specs.first { $0.id == "docs" })
                    XCTAssertEqual(docs.tools.filter { $0 == "audio_write" }.count, 1)
                    for needle in ["flac", "2097152", "65536-byte", "canonical JSON"] { XCTAssertTrue(docs.body.contains(needle), needle) }
                    for spec in specs where spec.id != "docs" { XCTAssertFalse(spec.tools.contains("audio_write")) }
                }
                let custom = "---\nid: docs\ndisplay_name: Owner docs\ntools:\n  - fs_write\ntools_forbidden:\n  - audio_write\n---\nOwner grants.\n"
                try custom.write(to: app.paths.agentsDir.appendingPathComponent("docs.md"), atomically: true, encoding: .utf8); app.catalog.reload()
                let spec = try XCTUnwrap(app.catalog.get("docs"))
                let binding = ActiveBinding(sessionID: SessionID("flac-custom"), agentID: spec.id, toolsPrimary: spec.tools, toolsForbidden: spec.toolsForbidden, cwd: project.path)
                guard case .denied(let customCode, _) = try authorization.authorize(tool: "audio_write", arguments: args, context: context, clientID: client, binding: binding, cancellation: nil) else { return XCTFail("Custom FLAC grant denial must remain") }
                XCTAssertEqual(customCode, "tool_forbidden")
                let sanitized = ToolAuditSanitizer.sanitize(args)
                XCTAssertEqual(sanitized["content"] as? String, "<redacted:4 bytes>"); XCTAssertEqual(sanitized["format"] as? String, "flac")
                _ = try app.projectContexts.beginReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                _ = try app.projectContexts.completeReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                let stale = try XCTUnwrap(try DocsToolPack().handle(name: "audio_write", arguments: args, context: context, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(stale.ok); XCTAssertEqual(stale.payload["code"] as? String, "audio_encode_failed")
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
        }.value
    }

    private static func boundaryPCM(frames: Int, channels: Int) -> Data {
        let mono: [Int16] = [-32768, 32767, -1, 1, -12000, 23456, -2345]
        let stereo: [(Int16, Int16)] = [(-32768, 32767), (-12000, 3000), (0, -1), (23456, -2345), (32767, -32768)]
        var data = Data(capacity: frames * channels * 2)
        for frame in 0..<frames {
            let values = channels == 1 ? [mono[frame % mono.count]] : [stereo[frame % stereo.count].0, stereo[frame % stereo.count].1]
            for value in values { let bits = UInt16(bitPattern: value); data.append(UInt8(truncatingIfNeeded: bits)); data.append(UInt8(truncatingIfNeeded: bits >> 8)) }
        }
        return data
    }
    private static func noise(samples: Int) -> Data {
        var state: UInt32 = 0x13579BDF, data = Data(capacity: samples * 2)
        for _ in 0..<samples { state = state &* 1_664_525 &+ 1_013_904_223; data.append(UInt8(truncatingIfNeeded: state)); data.append(UInt8(truncatingIfNeeded: state >> 8)) }
        return data
    }
    private static func arguments(_ url: URL, raw: Data, rate: Int, channels: Int, format: String?) -> [String: Any] {
        var result: [String: Any] = ["path": url.path, "content": raw.base64EncodedString(), "sample_rate": rate, "channels": channels]
        if let format { result["format"] = format }; return result
    }
    private static func withToolApp(root: URL, _ operation: (ForgeApp, ClientID, URL) throws -> Void) throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home", isDirectory: true), startTelemetry: false)
        defer { XCTAssertTrue(app.shutdown().completed) }
        _ = try app.config.update(["allowed_roots": [project.path]], save: false)
        let client = ClientID("flac-writer-tests")
        let initialized = try app.tools.call(name: "project_memory.initialize", arguments: ["project_path": project.path], clientID: client)
        XCTAssertTrue(initialized.ok, "\(initialized.payload)"); try operation(app, client, project)
    }

    private enum WireError: Error { case malformed }
    private struct Inspected { let pcm: Data; let frames: Int; let blocks: Int }

    /// Polynomial long division of the complete message followed by degree zero bits.
    /// This differs from the writer's byte-XOR CRC recurrence.
    private static func polynomialCRC(_ bytes: ArraySlice<UInt8>, width: Int, polynomial: UInt32) -> UInt32 {
        let high: UInt32 = 1 << width, divisor = high | polynomial
        var remainder: UInt32 = 0
        for byte in bytes {
            for bit in stride(from: 7, through: 0, by: -1) {
                remainder = (remainder << 1) | UInt32((byte >> bit) & 1)
                if remainder & high != 0 { remainder ^= divisor }
            }
        }
        for _ in 0..<width { remainder <<= 1; if remainder & high != 0 { remainder ^= divisor } }
        return remainder
    }

    /// Restricted one-STREAMINFO, fixed-block PCM16 verbatim contract; rejects unsupported syntax.
    private static func inspectFLAC(_ data: Data, rate: Int, channels: Int) throws -> Inspected {
        let bytes = Array(data)
        guard bytes.count >= 55, bytes.count <= 2_097_152, [8000, 44100, 48000].contains(rate), channels == 1 || channels == 2 else { throw WireError.malformed }
        func big(_ offset: Int, _ count: Int) -> UInt64 { bytes[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) } }
        guard Array(bytes[0..<8]) == [0x66, 0x4c, 0x61, 0x43, 0x80, 0, 0, 34], big(8, 2) == 4608, big(10, 2) == 4608 else { throw WireError.malformed }
        let fields = big(18, 8), frames64 = fields & 0x0f_ffff_ffff
        guard fields >> 44 == UInt64(rate), ((fields >> 41) & 7) + 1 == UInt64(channels), (fields >> 36) & 31 == 15,
              frames64 > 0, frames64 <= UInt64(1_048_576 / (channels * 2)) else { throw WireError.malformed }
        let frames = Int(frames64), rawBytes = frames * channels * 2
        var pcm = [UInt8](repeating: 0, count: rawBytes), offset = 42, consumed = 0, blocks = 0
        var smallest = Int.max, largest = 0
        while consumed < frames {
            guard blocks < 114, offset <= bytes.count - 8 else { throw WireError.malformed }
            let start = offset, rateCode: UInt8 = rate == 8000 ? 4 : rate == 44100 ? 9 : 10
            guard bytes[offset] == 0xff, bytes[offset + 1] == 0xf8, bytes[offset + 2] == (0x70 | rateCode),
                  bytes[offset + 3] == (UInt8((channels - 1) << 4) | 8), bytes[offset + 4] == UInt8(blocks),
                  polynomialCRC(bytes[offset..<(offset + 7)], width: 8, polynomial: 7) == UInt32(bytes[offset + 7]) else { throw WireError.malformed }
            let count = Int(big(offset + 5, 2)) + 1
            guard count == min(4608, frames - consumed) else { throw WireError.malformed }
            offset += 8
            for channel in 0..<channels {
                guard offset < bytes.count, bytes[offset] == 2 else { throw WireError.malformed }; offset += 1
                guard count * 2 <= bytes.count - offset else { throw WireError.malformed }
                for sample in 0..<count {
                    let target = ((consumed + sample) * channels + channel) * 2
                    pcm[target] = bytes[offset + sample * 2 + 1]; pcm[target + 1] = bytes[offset + sample * 2]
                }
                offset += count * 2
            }
            guard offset <= bytes.count - 2, polynomialCRC(bytes[start..<offset], width: 16, polynomial: 0x8005) == UInt32(big(offset, 2)) else { throw WireError.malformed }
            offset += 2; smallest = min(smallest, offset - start); largest = max(largest, offset - start)
            consumed += count; blocks += 1
        }
        let raw = Data(pcm)
        guard offset == bytes.count, consumed == frames, big(12, 3) == UInt64(smallest), big(15, 3) == UInt64(largest),
              Data(bytes[26..<42]) == Data(Insecure.MD5.hash(data: raw)) else { throw WireError.malformed }
        return Inspected(pcm: raw, frames: frames, blocks: blocks)
    }
    private static func hex(_ text: String) throws -> Data {
        let bytes = Array(text.utf8); guard bytes.count % 2 == 0 else { throw WireError.malformed }
        var result = Data()
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            guard let value = UInt8(String(decoding: bytes[offset..<(offset + 2)], as: UTF8.self), radix: 16) else { throw WireError.malformed }
            result.append(value)
        }
        return result
    }
}

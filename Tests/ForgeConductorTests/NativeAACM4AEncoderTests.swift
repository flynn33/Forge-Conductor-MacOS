import Foundation
import Darwin
import Synchronization
import XCTest
@testable import ForgeConductorCore

/// Modelled child transport exercises host ownership and framing, not an AAC codec.
/// Native codec, arbitrary input lengths and lossy quality require separate execution.
final class NativeAACM4AEncoderTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-aac-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath().standardizedFileURL
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testVersionedPCMFrameRoundTripsRatesChannelsAndExactInputBoundary() throws {
        for rate in [8000, 44100, 48000] { for channels in [1, 2] {
            let pcm = Data([0, 128, 255, 127].prefix(channels * 2))
            let input = try AACM4AProtocol.prepare(content: pcm.base64EncodedString(), rate: rate, channels: channels, cancellation: nil)
            let bytes = try AACM4AProtocol.request(input), decoded = try AACM4AProtocol.decodeRequest(bytes)
            XCTAssertEqual(decoded.pcm, pcm); XCTAssertEqual(decoded.rate, rate); XCTAssertEqual(decoded.channels, channels)
            XCTAssertEqual(decoded.frames, 1); XCTAssertEqual(decoded.digest, JSONSupport.sha256Hex(pcm))
            XCTAssertEqual(try AACM4AProtocol.request(decoded), bytes)
        } }
        let pcm = Data(repeating: 0xff, count: 1_048_576)
        let input = try AACM4AProtocol.prepare(content: pcm.base64EncodedString(), rate: 48000, channels: 2, cancellation: nil)
        let frame = try AACM4AProtocol.request(input)
        XCTAssertLessThanOrEqual(frame.count, 1_049_604)
        XCTAssertEqual(try AACM4AProtocol.decodeRequest(frame).pcm, pcm)
        XCTAssertEqual(AACM4AProtocol.maximumReplyBytes, 2_101_252)
        XCTAssertEqual(AACM4AProtocol.maximumRequestBytes, 1_049_604)
    }

    func testStrictRequestMetadataCanonicalTypesDigestAndTrueBodyExtent() throws {
        let input = AACM4AProtocol.Input(pcm: Data([0, 0]), rate: 8000, channels: 1)
        let good = try AACM4AProtocol.request(input), (metadata, body) = try Self.parts(good)
        for (key, value) in [("version", true), ("sample_rate", 8000.5), ("channels", NSNull()),
                             ("frames", 2), ("pcm_bytes", 1), ("pcm_sha256", String(repeating: "0", count: 64)),
                             ("unknown", 0)] as [(String, Any)] {
            var changed = metadata; changed[key] = value
            XCTAssertThrowsError(try AACM4AProtocol.decodeRequest(Self.frame(changed, body)), key)
        }
        for malformed in [Data(), Data([0, 0, 0, 0]), Data([0xff, 0xff, 0xff, 0xff]),
                          Data(good.dropLast()), good + Data([0]), Data(repeating: 0, count: 1_049_605)] {
            XCTAssertThrowsError(try AACM4AProtocol.decodeRequest(malformed))
        }
        let duplicate = Data("{\"channels\":1,\"channels\":1,\"frames\":1,\"pcm_bytes\":2,\"pcm_sha256\":\"\(input.digest)\",\"sample_rate\":8000,\"version\":1}".utf8)
        XCTAssertThrowsError(try AACM4AProtocol.decodeRequest(Self.rawFrame(duplicate, body)))
        XCTAssertThrowsError(try AACM4AProtocol.decodeRequest(Self.rawFrame(Data(" {\"version\":1}".utf8), body)))
        var missing = metadata; missing.removeValue(forKey: "frames")
        XCTAssertThrowsError(try AACM4AProtocol.decodeRequest(Self.frame(missing, body)))
    }

    func testStrictReplyEchoDurationContainerDigestAndCompleteExtent() throws {
        let input = AACM4AProtocol.Input(pcm: Data([1, 0]), rate: 44100, channels: 1)
        let good = try AACFixtureTransport.reply(input)
        XCTAssertEqual(try AACM4AProtocol.decodeReply(good, input: input), AACFixtureTransport.modelContainer)
        for invalid in [AACM4AProtocol.Input(pcm: Data([0, 0]), rate: 44100, channels: 0),
                        .init(pcm: Data(), rate: 44100, channels: 1), .init(pcm: Data([0]), rate: 44100, channels: 1),
                        .init(pcm: Data([0, 0]), rate: 96000, channels: 1)] {
            XCTAssertThrowsError(try AACM4AProtocol.decodeReply(good, input: invalid))
        }
        let (metadata, body) = try Self.parts(good)
        for (key, value) in [("version", 2), ("sample_rate", 8000), ("channels", true), ("frames", 2),
            ("pcm_bytes", 3), ("pcm_sha256", "bad"), ("encoded_bytes", 13), ("encoded_sha256", "bad"),
            ("codec", "he-aac"), ("container", "adts"), ("priming_frames", -1), ("remainder_frames", 16_385),
            ("packet_frame_sum", 99), ("unknown", 0)] as [(String, Any)] {
            var m = metadata; m[key] = value
            XCTAssertThrowsError(try AACM4AProtocol.decodeReply(Self.frame(m, body), input: input), key)
        }
        for data in [Data(), Data(good.dropLast()), good + Data([0]), Data(repeating: 0, count: 2_101_253)] {
            XCTAssertThrowsError(try AACM4AProtocol.decodeReply(data, input: input))
        }
        for data in [Data([0, 0, 0, 12, 98, 97, 100, 33, 0, 0, 0, 0]), Data([0, 0, 0, 13, 102, 116, 121, 112, 0, 0, 0, 0])] {
            XCTAssertThrowsError(try AACM4AProtocol.reply(input: input, encoded: data,
                duration: .init(leading: 2, trailing: 1, packetFrames: 4)))
        }
        XCTAssertThrowsError(try AACM4AProtocol.decodeReply(good, input: .init(pcm: Data([2, 0]), rate: 44100, channels: 1)))
    }

    func testQueriedPacketDurationDeterminesFiniteCeilingWithoutFixedPrimingAssumption() throws {
        XCTAssertEqual(try AACM4AProtocol.packetCeiling(frames: 524_288, queriedFramesPerPacket: 1024), 544)
        XCTAssertEqual(try AACM4AProtocol.packetCeiling(frames: 524_288, queriedFramesPerPacket: 2048), 272)
        XCTAssertEqual(try AACM4AProtocol.packetCeiling(frames: 1, queriedFramesPerPacket: 8192), 5)
        for (frames, packet) in [(0, UInt32(1024)), (524_289, 1024), (1, 0), (1, 8193), (524_288, 256)] {
            XCTAssertThrowsError(try AACM4AProtocol.packetCeiling(frames: frames, queriedFramesPerPacket: packet))
        }
        for valid in [AACM4AProtocol.Duration(leading: 0, trailing: 0, packetFrames: 1),
                      .init(leading: 7, trailing: 9, packetFrames: 17), .init(leading: 16_384, trailing: 16_384, packetFrames: 32_769)] {
            XCTAssertNoThrow(try valid.validate(1))
        }
    }

    func testWorkerCanonicalPCMRefusalsCancellationAndDeadlinePreventTransport() async throws {
        let fixture = AACFixtureTransport(), encoder = fixture.encoder()
        defer { XCTAssertTrue(encoder.shutdown()) }
        try await MainActor.run {
            XCTAssertThrowsError(try encoder.encode(content: "AAA=", sampleRate: 8000, channels: 1, cancellation: nil)) {
                XCTAssertEqual($0 as? NativePCM16WAVError, .workerRequired)
            }
        }
        try await Task.detached {
            for text in ["", "AA", "AAA=\n", "AB==", "AAB=", "AA-=", "日本語"] {
                XCTAssertThrowsError(try encoder.encode(content: text, sampleRate: 8000, channels: 1, cancellation: nil)) {
                    XCTAssertEqual($0 as? NativePCM16WAVError, .invalidContent)
                }
            }
            for (text, channels) in [("AA==", 1), ("AAA=", 2)] {
                XCTAssertThrowsError(try encoder.encode(content: text, sampleRate: 8000, channels: channels, cancellation: nil)) {
                    XCTAssertEqual($0 as? NativePCM16WAVError, .incompleteFrames)
                }
            }
            XCTAssertThrowsError(try encoder.encode(content: "AAA=", sampleRate: 96000, channels: 1, cancellation: nil)) { XCTAssertEqual($0 as? NativePCM16WAVError, .invalidSampleRate) }
            XCTAssertThrowsError(try encoder.encode(content: "AAA=", sampleRate: 8000, channels: 3, cancellation: nil)) { XCTAssertEqual($0 as? NativePCM16WAVError, .invalidChannels) }
            XCTAssertThrowsError(try encoder.encode(content: Data(repeating: 0, count: 1_048_578).base64EncodedString(), sampleRate: 8000, channels: 1, cancellation: nil)) { XCTAssertEqual($0 as? NativePCM16WAVError, .inputLimit) }
            let cancelled = ToolCallCancellation(timeoutSeconds: 10); cancelled.cancel()
            XCTAssertThrowsError(try encoder.encode(content: "AAA=", sampleRate: 8000, channels: 1, cancellation: cancelled)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try encoder.encode(content: "AAA=", sampleRate: 8000, channels: 1, cancellation: ToolCallCancellation(timeoutSeconds: 1))) { XCTAssertTrue($0 is ToolCallDeadlineExceeded) }
        }.value
        XCTAssertEqual(fixture.runCount, 0); XCTAssertEqual(fixture.recoveryCount, 0)
    }

    func testFailedPreflightReleasesSlotAndStoppedOwnerDoesNotDecodeAgain() async throws {
        try await Task.detached {
            let fixture = AACFixtureTransport(), encoder = fixture.encoder()
            XCTAssertThrowsError(try encoder.encode(content: "AB==", sampleRate: 8000, channels: 1, cancellation: nil)) { XCTAssertEqual($0 as? NativePCM16WAVError, .invalidContent) }
            XCTAssertEqual(fixture.runCount, 0)
            XCTAssertEqual(try encoder.encode(content: "AAA=", sampleRate: 8000, channels: 1, cancellation: nil).data, AACFixtureTransport.modelContainer)
            XCTAssertTrue(encoder.shutdown())
            XCTAssertThrowsError(try encoder.encode(content: String(repeating: "!", count: 1_398_104), sampleRate: 8000, channels: 1, cancellation: nil)) { XCTAssertEqual($0 as? NativeAACM4AError, .stopped) }
            XCTAssertEqual(fixture.runCount, 1)
        }.value
    }

    func testEveryTransportAdmissionEOFExitCapAndInputFailureRejectsSuccess() async throws {
        try await Task.detached {
            for mode in AACFixtureTransport.refusals {
                let fixture = AACFixtureTransport(mode: mode), encoder = fixture.encoder()
                XCTAssertThrowsError(try encoder.encode(content: "AAA=", sampleRate: 8000, channels: 1, cancellation: nil), "\(mode)")
                XCTAssertEqual(fixture.runCount, 1); XCTAssertTrue(encoder.shutdown()); XCTAssertEqual(fixture.recoveryCount, 0)
            }
        }.value
    }

    func testSingleSlotHasNoQueueAndConfirmedCompletionReleasesOwnership() async throws {
        let fixture = AACFixtureTransport(mode: .hold), encoder = fixture.encoder()
        defer { fixture.release(); XCTAssertTrue(encoder.shutdown()) }
        let first = Task.detached { try encoder.encode(content: "AAA=", sampleRate: 8000, channels: 1, cancellation: nil) }
        try await Self.wait(fixture)
        try await Task.detached {
            for content in ["AAA=", String(repeating: "!", count: 1_398_104)] {
                XCTAssertThrowsError(try encoder.encode(content: content, sampleRate: 8000, channels: 1, cancellation: nil)) { XCTAssertEqual($0 as? NativeAACM4AError, .busy) }
            }
        }.value
        XCTAssertEqual(fixture.runCount, 1); fixture.setMode(.normal); fixture.release()
        let firstValue = try await first.value
        XCTAssertEqual(firstValue.data, AACFixtureTransport.modelContainer)
        let next = try await Task.detached { try encoder.encode(content: "AAA=", sampleRate: 8000, channels: 1, cancellation: nil) }.value
        XCTAssertEqual(next.data, AACFixtureTransport.modelContainer); XCTAssertEqual(fixture.runCount, 2)
    }

    func testUnconfirmedChildRetainsBusyAndRecoveryUsesOriginalDeadline() async throws {
        try await Task.detached {
            for mode in [AACFixtureTransport.Mode.throwUnconfirmed, .rawUnconfirmed] {
                let fixture = AACFixtureTransport(mode: mode), encoder = fixture.encoder()
                XCTAssertThrowsError(try encoder.encode(content: "AAA=", sampleRate: 8000, channels: 1, cancellation: nil))
                XCTAssertThrowsError(try encoder.encode(content: "AAA=", sampleRate: 8000, channels: 1, cancellation: nil)) { XCTAssertEqual($0 as? NativeAACM4AError, .busy) }
                XCTAssertFalse(encoder.shutdown()); XCTAssertEqual(fixture.recoveryDeadline, fixture.runDeadline)
                fixture.setRecovery(true); XCTAssertTrue(encoder.shutdown())
                XCTAssertEqual(fixture.runCount, 1); XCTAssertEqual(fixture.recoveryCount, 2)
                for content in ["AAA=", String(repeating: "!", count: 1_398_104)] {
                    XCTAssertThrowsError(try encoder.encode(content: content, sampleRate: 8000, channels: 1, cancellation: nil)) { XCTAssertEqual($0 as? NativeAACM4AError, .stopped) }
                }
            }
        }.value
    }

    func testShutdownCancelsOnlyOwnedInFlightOperationAndWaitsForConfirmedCompletion() async throws {
        let fixture = AACFixtureTransport(mode: .untilCancelled), encoder = fixture.encoder()
        let work = Task.detached { try encoder.encode(content: "AAA=", sampleRate: 8000, channels: 1, cancellation: nil) }
        try await Self.wait(fixture)
        let stopped = await Task.detached { encoder.shutdown() }.value
        XCTAssertTrue(stopped); XCTAssertTrue(fixture.observedCancellation); XCTAssertEqual(fixture.recoveryCount, 0)
        do { _ = try await work.value; XCTFail("Cancelled operation must not succeed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.runCount, 1)
    }

    func testToolModelledAACReplacementMetadataBinaryEOFAndWAVFLACParity() async throws {
        let root = try XCTUnwrap(root)
        try await Task.detached {
            try Self.withApp(root) { app, client, project in
                let fixture = AACFixtureTransport(), encoder = fixture.encoder()
                defer { XCTAssertTrue(encoder.shutdown()) }
                let router = ToolRouter(app: app, packs: [DocsToolPack(aacEncoder: encoder)])
                let target = project.appendingPathComponent("replace.M4A")
                try Data("prior".utf8).write(to: target); XCTAssertEqual(Darwin.chmod(target.path, 0o600), 0)
                for file in [target, project.appendingPathComponent("new.m4a")] {
                    let result = try router.call(name: "audio_write", arguments: Self.arguments(file, format: "m4a"), clientID: client)
                    XCTAssertTrue(result.ok, "\(result.payload)")
                    XCTAssertEqual(Set(result.payload.keys), ["ok", "path", "format", "engine", "bytes_written", "sha256", "pcm_bytes", "sample_rate", "channels", "frames", "input_contract", "output_contract"])
                    XCTAssertEqual(result.payload["format"] as? String, "m4a"); XCTAssertEqual(result.payload["engine"] as? String, "native-audiotoolbox-aac-lc")
                    XCTAssertEqual(result.payload["output_contract"] as? String, "m4a-aac-lc-from-pcm16le-v1")
                    XCTAssertEqual(result.payload["input_contract"] as? String, NativePCM16WAVWriter.inputContract)
                    XCTAssertEqual(result.payload["sample_rate"] as? Int, 8000); XCTAssertEqual(result.payload["channels"] as? Int, 1)
                    XCTAssertEqual(result.payload["frames"] as? Int, 1); XCTAssertEqual(result.payload["pcm_bytes"] as? Int, 2)
                    XCTAssertEqual(result.payload["bytes_written"] as? Int, 12); XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(AACFixtureTransport.modelContainer))
                    XCTAssertEqual(try Data(contentsOf: file), AACFixtureTransport.modelContainer)
                    XCTAssertEqual(try Self.mode(file), file == target ? 0o600 : 0o644)
                    let read = try app.tools.call(name: "fs_read", arguments: ["path": file.path, "encoding": "base64", "maximum_bytes": 32_768], clientID: client)
                    XCTAssertTrue(read.ok); XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(read.payload["content"] as? String)), AACFixtureTransport.modelContainer)
                    XCTAssertEqual(read.payload["has_more"] as? Bool, false)
                }
                let wav = project.appendingPathComponent("parity.WAV")
                let absent = try router.call(name: "audio_write", arguments: Self.arguments(wav, format: nil), clientID: client)
                let before = try Data(contentsOf: wav)
                let explicit = try router.call(name: "audio_write", arguments: Self.arguments(wav, format: "wav"), clientID: client)
                XCTAssertTrue(absent.ok); XCTAssertTrue(explicit.ok)
                XCTAssertEqual(try JSONSupport.canonicalJSON(absent.payload), try JSONSupport.canonicalJSON(explicit.payload)); XCTAssertEqual(try Data(contentsOf: wav), before)
                XCTAssertEqual(before, try NativePCM16WAVWriter.encode(content: "AAA=", sampleRate: 8000, channels: 1).data)
                let flac = project.appendingPathComponent("retained.flac")
                let result = try router.call(name: "audio_write", arguments: Self.arguments(flac, format: "flac"), clientID: client)
                XCTAssertTrue(result.ok); XCTAssertEqual(try Data(contentsOf: flac), try NativePCM16FLACWriter.encode(content: "AAA=", sampleRate: 8000, channels: 1).data)
                XCTAssertEqual(result.payload["engine"] as? String, "native-swift-flac"); XCTAssertEqual(fixture.runCount, 2)
            }
        }.value
    }

    func testToolMalformedFormatsScalarsPathsAndOwnGrantRejectBeforeTransport() async throws {
        let root = try XCTUnwrap(root)
        try await Task.detached {
            try Self.withApp(root) { app, client, project in
                let fixture = AACFixtureTransport(), encoder = fixture.encoder(); defer { XCTAssertTrue(encoder.shutdown()) }
                let router = ToolRouter(app: app, packs: [DocsToolPack(aacEncoder: encoder)])
                let target = project.appendingPathComponent("absent.m4a"), good = Self.arguments(target, format: "m4a")
                for (key, value) in [("format", "aac"), ("format", "M4A"), ("format", true), ("format", NSNull()),
                    ("sample_rate", true), ("sample_rate", 8000.5), ("channels", true), ("channels", 3),
                    ("content", "AB=="), ("content", "AA=="), ("content", 42), ("unknown", 0)] as [(String, Any)] {
                    var args = good; args[key] = value
                    let result = try router.call(name: "audio_write", arguments: args, clientID: client)
                    XCTAssertFalse(result.ok, "\(key): \(value)")
                }
                var bad = good; bad["path"] = project.appendingPathComponent("wrong.aac").path
                XCTAssertFalse(try router.call(name: "audio_write", arguments: bad, clientID: client).ok)
                let context = try app.projectContexts.invocationContext(for: client)
                let auth = ToolAuthorizationService(paths: app.paths, config: app.config)
                for value in [false, NSNull(), "", " \n", "nul\u{0}.m4a"] as [Any] {
                    var args = good; args["path"] = value
                    guard case .denied(let code, let message) = try auth.authorize(tool: "audio_write", arguments: args, context: context, clientID: client, binding: nil, cancellation: nil) else { XCTFail("Raw path must be rejected"); continue }
                    XCTAssertEqual(code, "invalid_path"); XCTAssertEqual(message, "M4A path must be a nonblank string without NUL bytes")
                }
                let deniedClient = ClientID("aac-own-grant")
                _ = try app.projectContexts.bind(owner: .init(kind: .mcpClient, id: deniedClient.rawValue), projectID: context.projectID, generation: context.projectGeneration,
                    authorizationScope: .init(canonicalRoots: [project], allowedTools: ["fs_write", "image_write", "archive_write"], networkAllowed: false, maximumInlineOutputBytes: 65_536))
                let denied = try router.call(name: "audio_write", arguments: good, clientID: deniedClient)
                XCTAssertFalse(denied.ok); XCTAssertEqual(denied.payload["code"] as? String, "tool_not_granted")
                XCTAssertEqual(fixture.runCount, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            }
        }.value
    }

    func testCancellationAfterCompleteReplyPreservesExistingDestination() async throws {
        let root = try XCTUnwrap(root)
        try await Task.detached {
            try Self.withApp(root) { app, client, project in
                let target = project.appendingPathComponent("cancel.m4a"), prior = Data("cancel sentinel".utf8)
                try prior.write(to: target)
                let control = ToolCallCancellation(timeoutSeconds: 10)
                let encoder = NativeAACM4AEncoder(run: { request, _, received in
                    XCTAssertTrue(received === control); received.cancel()
                    return AACFixtureTransport.complete(request: request, output: try AACFixtureTransport.reply(AACM4AProtocol.decodeRequest(request)))
                }, recover: { _ in XCTFail("Confirmed child does not require recovery"); return false })
                defer { XCTAssertTrue(encoder.shutdown()) }
                XCTAssertThrowsError(try DocsToolPack(aacEncoder: encoder).handle(name: "audio_write", arguments: Self.arguments(target, format: "m4a"), context: nil, clientID: client, app: app, cancellation: control)) { XCTAssertTrue($0 is CancellationError) }
                XCTAssertEqual(try Data(contentsOf: target), prior); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), ["cancel.m4a"])
            }
        }.value
    }

    func testFixedEncoderEndRefusesConfirmedReplyWhileCallerTokenRemainsLive() async throws {
        let root = try XCTUnwrap(root)
        try await Task.detached {
            try Self.withApp(root) { app, client, project in
                let target = project.appendingPathComponent("expired.m4a"), prior = Data("deadline sentinel".utf8)
                try prior.write(to: target)
                let transport = AACFixtureTransport(mode: .delayedConfirmed), encoder = transport.encoder()
                defer { XCTAssertTrue(encoder.shutdown()) }
                // Deliberately outlive the encoder's fixed 30-second end without
                // expiring the caller token. No injected clock or shortened cap.
                let control = ToolCallCancellation(timeoutSeconds: 60)
                XCTAssertThrowsError(try DocsToolPack(aacEncoder: encoder).handle(name: "audio_write", arguments: Self.arguments(target, format: "m4a"), context: nil, clientID: client, app: app, cancellation: control)) { XCTAssertTrue($0 is ToolCallDeadlineExceeded) }
                XCTAssertGreaterThan(control.remainingTimeInterval ?? 0, 20)
                XCTAssertNoThrow(try control.checkCancellation())
                XCTAssertGreaterThanOrEqual(DispatchTime.now().uptimeNanoseconds, try XCTUnwrap(transport.runDeadline))
                XCTAssertEqual(transport.runCount, 1); XCTAssertEqual(transport.recoveryCount, 0)
                XCTAssertEqual(try Data(contentsOf: target), prior)
            }
        }.value
    }

    func testGenerationChangedAfterReplyPreventsPublication() async throws {
        let root = try XCTUnwrap(root)
        try await Task.detached {
            try Self.withApp(root) { app, client, project in
                let context = try app.projectContexts.invocationContext(for: client)
                let target = project.appendingPathComponent("stale.m4a")
                let encoder = NativeAACM4AEncoder(run: { request, _, _ in
                    _ = try app.projectContexts.beginReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                    _ = try app.projectContexts.completeReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                    return AACFixtureTransport.complete(request: request, output: try AACFixtureTransport.reply(AACM4AProtocol.decodeRequest(request)))
                }, recover: { _ in false })
                defer { XCTAssertTrue(encoder.shutdown()) }
                let result = try XCTUnwrap(try DocsToolPack(aacEncoder: encoder).handle(name: "audio_write", arguments: Self.arguments(target, format: "m4a"), context: context, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, "audio_encode_failed"); XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            }
        }.value
    }

    func testPinnedParentSwapAndFailedRenamePreserveTargetsAndRemoveStage() async throws {
        let root = try XCTUnwrap(root)
        try await Task.detached {
            try Self.withApp(root) { app, client, project in
                let parent = project.appendingPathComponent("branch", isDirectory: true), moved = project.appendingPathComponent("original", isDirectory: true)
                let outside = root.appendingPathComponent("outside", isDirectory: true)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let prior = Data("inside".utf8), protected = Data("outside".utf8)
                try prior.write(to: parent.appendingPathComponent("target.m4a")); try protected.write(to: outside.appendingPathComponent("target.m4a"))
                let encoder = NativeAACM4AEncoder(run: { request, _, _ in
                    try FileManager.default.moveItem(at: parent, to: moved); try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
                    return AACFixtureTransport.complete(request: request, output: try AACFixtureTransport.reply(AACM4AProtocol.decodeRequest(request)))
                }, recover: { _ in false })
                defer { XCTAssertTrue(encoder.shutdown()) }
                let result = try ToolRouter(app: app, packs: [DocsToolPack(aacEncoder: encoder)]).call(name: "audio_write", arguments: Self.arguments(parent.appendingPathComponent("target.m4a"), format: "m4a"), clientID: client)
                XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, "audio_write_failed")
                XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("target.m4a")), prior); XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("target.m4a")), protected)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), ["target.m4a"])
                let directory = project.appendingPathComponent("directory.m4a", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try prior.write(to: directory.appendingPathComponent("keep"))
                let fixture = AACFixtureTransport(), other = fixture.encoder(); defer { XCTAssertTrue(other.shutdown()) }
                let failed = try XCTUnwrap(try DocsToolPack(aacEncoder: other).handle(name: "audio_write", arguments: Self.arguments(directory, format: "m4a"), context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(failed.ok); XCTAssertEqual(failed.payload["code"] as? String, "audio_write_failed")
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), prior)
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: project.path).contains { $0.hasPrefix(".forge-text-") })
            }
        }.value
    }

    private static func arguments(_ url: URL, format: String?) -> [String: Any] {
        var a: [String: Any] = ["path": url.path, "content": "AAA=", "sample_rate": 8000, "channels": 1]
        if let format { a["format"] = format }; return a
    }
    private static func withApp(_ root: URL, _ action: (ForgeApp, ClientID, URL) throws -> Void) throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home", isDirectory: true), startTelemetry: false)
        defer { XCTAssertTrue(app.shutdown().completed) }
        _ = try app.config.update(["allowed_roots": [project.path]], save: false)
        let client = ClientID("aac-writer-tests")
        XCTAssertTrue(try app.tools.call(name: "project_memory.initialize", arguments: ["project_path": project.path], clientID: client).ok)
        try action(app, client, project)
    }
    private static func mode(_ url: URL) throws -> Int { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue }
    private static func parts(_ frame: Data) throws -> ([String: Any], Data) {
        let length = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        return (try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.dropFirst(4).prefix(length))) as? [String: Any]), Data(frame.dropFirst(4 + length)))
    }
    private static func frame(_ m: [String: Any], _ body: Data) throws -> Data { try rawFrame(JSONSerialization.data(withJSONObject: m, options: [.sortedKeys, .withoutEscapingSlashes]), body) }
    private static func rawFrame(_ bytes: Data, _ body: Data) -> Data {
        let n = UInt32(bytes.count); var d = Data([UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
        d.append(bytes); d.append(body); return d
    }
    private static func wait(_ fixture: AACFixtureTransport) async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while fixture.runCount == 0, DispatchTime.now().uptimeNanoseconds < end { try await Task.sleep(nanoseconds: 1_000_000) }
        guard fixture.runCount == 1 else { throw AACFixtureError.waitExpired }
    }
}

private enum AACFixtureError: Error { case waitExpired }
/// Shared only with broker tests. The 12-byte ftyp frame is a transport sentinel,
/// deliberately not evidence that an AudioToolbox encoder produced an AAC stream.
final class AACFixtureTransport: Sendable {
    enum Mode: Sendable, Equatable { case normal, hold, untilCancelled, throwUnconfirmed, rawUnconfirmed, delayedConfirmed
        case roleRejected, auditUnavailable, identityMismatch, childInvalid, notAdmitted, childExited
        case exitFailure, signalled, stdoutReadError, stderrReadError, stdoutForcedClose, stderrForcedClose
        case stdoutTruncated, stderrTruncated, stdinPartial, stdinOpen, termRequested, killRequested
        case emptyOutput, badOutput, oversizedOutput, cancelled, timedOut }
    static let refusals: [Mode] = [.roleRejected, .auditUnavailable, .identityMismatch, .childInvalid, .notAdmitted, .childExited,
        .exitFailure, .signalled, .stdoutReadError, .stderrReadError, .stdoutForcedClose, .stderrForcedClose,
        .stdoutTruncated, .stderrTruncated, .stdinPartial, .stdinOpen, .termRequested, .killRequested,
        .emptyOutput, .badOutput, .oversizedOutput, .cancelled, .timedOut]
    private struct State: Sendable { var mode: Mode; var runCount = 0, recoveryCount = 0; var runDeadline: UInt64?, recoveryDeadline: UInt64?; var confirmed = false, observedCancellation = false }
    private let state: Mutex<State>, gate = DispatchSemaphore(value: 0)
    // Hand-packed only to pass the restricted transport envelope check.
    static let modelContainer = Data([0, 0, 0, 12, 102, 116, 121, 112, 77, 52, 65, 32])
    init(mode: Mode = .normal) { state = Mutex(State(mode: mode)) }
    var runCount: Int { state.withLock { $0.runCount } }
    var recoveryCount: Int { state.withLock { $0.recoveryCount } }
    var runDeadline: UInt64? { state.withLock { $0.runDeadline } }
    var recoveryDeadline: UInt64? { state.withLock { $0.recoveryDeadline } }
    var observedCancellation: Bool { state.withLock { $0.observedCancellation } }
    func setMode(_ mode: Mode) { state.withLock { $0.mode = mode } }
    func setRecovery(_ confirmed: Bool) { state.withLock { $0.confirmed = confirmed } }
    func release() { gate.signal() }
    func encoder() -> NativeAACM4AEncoder { NativeAACM4AEncoder(run: { [self] in try run($0, $1, $2) }, recover: { [self] in recover($0) }) }
    static func reply(_ input: AACM4AProtocol.Input) throws -> Data { try AACM4AProtocol.reply(input: input, encoded: modelContainer, duration: .init(leading: 2, trailing: 1, packetFrames: input.frames + 3)) }
    static func complete(request: Data, output: Data) -> OwnedDuplexResult {
        .init(exitCode: 0, terminationSignal: nil, stdout: .init(data: output, end: .eof, truncated: false), stderr: .init(data: Data(), end: .eof, truncated: false),
              stdinBytesWritten: request.count, stdinClosed: true, admission: .admitted, timedOut: false, cancelled: false, termRequested: false, killRequested: false, terminationConfirmed: true)
    }
    private func run(_ request: Data, _ end: UInt64, _ control: ToolCallCancellation) throws -> OwnedDuplexResult {
        let mode = state.withLock { v in v.runCount += 1; v.runDeadline = end; return v.mode }
        if mode == .hold, gate.wait(timeout: .now() + 3) != .success { throw AACFixtureError.waitExpired }
        if mode == .untilCancelled {
            let stop = min(end, DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
            while !control.isCancelled, DispatchTime.now().uptimeNanoseconds < stop { Thread.sleep(forTimeInterval: 0.001) }
            state.withLock { $0.observedCancellation = control.isCancelled }
        }
        if mode == .delayedConfirmed {
            while DispatchTime.now().uptimeNanoseconds <= end { Thread.sleep(forTimeInterval: 0.001) }
        }
        if mode == .throwUnconfirmed { throw OwnedNativeTerminationUnconfirmed(processIdentifier: 123, signalError: nil, waitError: nil, killRequested: true) }
        let admission: OwnedAdmissionDisposition
        switch mode { case .roleRejected: admission = .roleRejected; case .auditUnavailable: admission = .auditTokenUnavailable
        case .identityMismatch: admission = .exactIdentityMismatch; case .childInvalid: admission = .childInvalid
        case .notAdmitted: admission = .notAttempted; case .childExited: admission = .ownedChildExited; default: admission = .admitted }
        let output: Data
        switch mode { case .emptyOutput: output = Data(); case .badOutput: output = Data([0, 0, 0, 0]); case .oversizedOutput: output = Data(repeating: 0, count: 2_101_253)
        default: output = try Self.reply(AACM4AProtocol.decodeRequest(request)) }
        return .init(exitCode: mode == .exitFailure ? 1 : 0, terminationSignal: mode == .signalled ? 9 : nil,
            stdout: .init(data: output, end: mode == .stdoutReadError ? .readError(5) : mode == .stdoutForcedClose ? .forcedClose : .eof, truncated: mode == .stdoutTruncated),
            stderr: .init(data: Data(), end: mode == .stderrReadError ? .readError(5) : mode == .stderrForcedClose ? .forcedClose : .eof, truncated: mode == .stderrTruncated),
            stdinBytesWritten: mode == .stdinPartial ? request.count - 1 : request.count, stdinClosed: mode != .stdinOpen, admission: admission,
            timedOut: mode == .timedOut, cancelled: mode == .cancelled || (mode == .untilCancelled && control.isCancelled),
            termRequested: mode == .termRequested, killRequested: mode == .killRequested, terminationConfirmed: mode != .rawUnconfirmed)
    }
    private func recover(_ end: UInt64) -> Bool { state.withLock { v in v.recoveryCount += 1; v.recoveryDeadline = end; return v.confirmed } }
}

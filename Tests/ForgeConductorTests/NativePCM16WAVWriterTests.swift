import Foundation
import Darwin
import XCTest
@testable import ForgeConductorCore

final class NativePCM16WAVWriterTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("forge-pcm16-wav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        temporaryRoot = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporaryRoot) }

    func testSevenStartingFixturesPreserveExactQualifiedRIFFAndPCMBytes() async throws {
        try await Task.detached(priority: .utility) {
            let noise = Self.noise(samples: 8192)
            let cases: [(Int, Int, Data, String)] = [
                (8000, 1, Self.pcm([0]), "4aebda3a657a0d8f532d11ceacb1679081d7bdf7d7d301a53f1096af3580be91"),
                (44100, 1, Self.pcm([-32768, -12345, -1, 0, 1, 12345, 32767, 42]), "bf1753f18d3819c3d377573f5dde3d05791ee684d39027615e7dd817f8cbaea0"),
                (48000, 2, Self.pcm([-32768, 32767, -12000, 3000, 0, -1, 23456, -2345, 32767, -32768]), "40dd76e100032d2c391e5ead6ae7b42dc1bedf89337d1571c3724264777196a5"),
                (48000, 2, noise, "a274b3d617988f662e88b62419ab852b8b5479790e5695ce0d458cdd21941614"),
                (48000, 1, Self.pcm([0]), "c00744703f8b1cc40f0178e56ba45d9f6e6f64d5491303b7a2ffd8e58c346401"),
                (8000, 2, Self.pcm([32767, -32768]), "5fe7e74be6887c202fa61ed8a619026c4e5169449ad0ba56a31218cdb6b47930"),
                (44100, 2, Self.pcm([32767, -32768]), "c712d46f21d5858e044405005216a4e3331dcff364695e2603a5b5f547ef6bda"),
            ]
            for (rate, channels, raw, hash) in cases {
                let encoded = try NativePCM16WAVWriter.encode(content: raw.base64EncodedString(), sampleRate: rate, channels: channels)
                XCTAssertEqual(encoded.sampleRate, rate); XCTAssertEqual(encoded.channels, channels)
                XCTAssertEqual(encoded.frames, raw.count / (channels * 2)); XCTAssertEqual(encoded.pcmBytes, raw.count)
                XCTAssertEqual(JSONSupport.sha256Hex(encoded.data), hash)
                XCTAssertEqual(try Self.inspectWAV(encoded.data, rate: rate, channels: channels), raw)
                XCTAssertEqual(try NativePCM16WAVWriter.encode(content: raw.base64EncodedString(), sampleRate: rate, channels: channels).data, encoded.data)
            }
        }.value
    }

    func testOneMiBPCMAllSixRateChannelCombinationsAndExactOutputCaps() async throws {
        try await Task.detached(priority: .utility) {
            let raw = Self.noise(samples: 524_288)
            XCTAssertEqual(raw.count, 1_048_576)
            let content = raw.base64EncodedString()
            for rate in [8000, 44100, 48000] {
                for channels in [1, 2] {
                    let encoded = try NativePCM16WAVWriter.encode(content: content, sampleRate: rate, channels: channels)
                    XCTAssertEqual(encoded.data.count, 1_048_620); XCTAssertEqual(encoded.pcmBytes, 1_048_576)
                    XCTAssertEqual(encoded.frames, 1_048_576 / (channels * 2))
                    XCTAssertEqual(try Self.inspectWAV(encoded.data, rate: rate, channels: channels), raw)
                    XCTAssertEqual(try NativePCM16WAVWriter.encode(content: content, sampleRate: rate, channels: channels, outputByteLimit: encoded.data.count).data, encoded.data)
                    XCTAssertThrowsError(try NativePCM16WAVWriter.encode(content: content, sampleRate: rate, channels: channels, outputByteLimit: encoded.data.count - 1)) {
                        XCTAssertEqual($0 as? NativePCM16WAVError, .outputLimit)
                    }
                }
            }
            for limit in [0, NativePCM16WAVWriter.maximumOutputBytes + 1] {
                XCTAssertThrowsError(try NativePCM16WAVWriter.encode(content: "AAA=", sampleRate: 8000, channels: 1, outputByteLimit: limit)) {
                    XCTAssertEqual($0 as? NativePCM16WAVError, .outputLimit)
                }
            }
            let over = (raw + Data([0, 0])).base64EncodedString()
            XCTAssertThrowsError(try NativePCM16WAVWriter.encode(content: over, sampleRate: 8000, channels: 1)) {
                XCTAssertEqual($0 as? NativePCM16WAVError, .inputLimit)
            }
        }.value
    }

    func testIndependentRIFFOracleRejectsMalformedHeadersAndTrailingBytes() async throws {
        try await Task.detached(priority: .utility) {
            let valid = try NativePCM16WAVWriter.encode(content: "AAA=", sampleRate: 8000, channels: 1).data
            XCTAssertEqual(try Self.inspectWAV(valid, rate: 8000, channels: 1), Data([0, 0]))
            for (offset, value) in [(0, 0), (4, 0), (8, 0), (12, 0), (16, 18), (20, 3), (22, 2), (24, 0),
                                    (28, 0), (32, 4), (34, 8), (36, 0), (40, 1)] {
                var changed = valid; changed[offset] = UInt8(value)
                XCTAssertThrowsError(try Self.inspectWAV(changed, rate: 8000, channels: 1))
            }
            XCTAssertThrowsError(try Self.inspectWAV(Data(valid.dropLast()), rate: 8000, channels: 1))
            XCTAssertThrowsError(try Self.inspectWAV(valid + Data([0]), rate: 8000, channels: 1))
        }.value
    }

    func testStrictScalarsCanonicalBase64AndCompleteFrameAdmission() async throws {
        try await Task.detached(priority: .utility) {
            for value in [NSNull(), true, "8000", 8000.5, 0, -1, 96000, Int.max] as [Any] {
                XCTAssertThrowsError(try NativePCM16WAVWriter.sampleRate(value)) { XCTAssertEqual($0 as? NativePCM16WAVError, .invalidSampleRate) }
            }
            for value in [NSNull(), true, "1", 1.5, 0, -1, 3, Int.max] as [Any] {
                XCTAssertThrowsError(try NativePCM16WAVWriter.channels(value)) { XCTAssertEqual($0 as? NativePCM16WAVError, .invalidChannels) }
            }
            for text in ["", "AA", "AAA", "AAA=\n", " AAA=", "AA-=", "AA_=", "A===", "AB==", "AAB=", "日本語"] {
                XCTAssertThrowsError(try NativePCM16WAVWriter.encode(content: text, sampleRate: 8000, channels: 1)) {
                    XCTAssertEqual($0 as? NativePCM16WAVError, .invalidContent, text)
                }
            }
            for (content, channels) in [("AA==", 1), ("AAAA", 1), ("AAA=", 2), ("AAAAAAA=", 2)] {
                XCTAssertThrowsError(try NativePCM16WAVWriter.encode(content: content, sampleRate: 8000, channels: channels)) {
                    XCTAssertEqual($0 as? NativePCM16WAVError, .incompleteFrames)
                }
            }
            XCTAssertThrowsError(try NativePCM16WAVWriter.encode(content: "AAA=", sampleRate: 96000, channels: 1)) { XCTAssertEqual($0 as? NativePCM16WAVError, .invalidSampleRate) }
            XCTAssertThrowsError(try NativePCM16WAVWriter.encode(content: "AAA=", sampleRate: 8000, channels: 3)) { XCTAssertEqual($0 as? NativePCM16WAVError, .invalidChannels) }
        }.value
    }

    func testWorkerPreCancellationAndExpiredDeadlineRefuseEncoding() async throws {
        try await MainActor.run {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertThrowsError(try NativePCM16WAVWriter.encode(content: "AAA=", sampleRate: 8000, channels: 1)) { XCTAssertEqual($0 as? NativePCM16WAVError, .workerRequired) }
        }
        try await Task.detached(priority: .utility) {
            let cancelled = ToolCallCancellation(timeoutSeconds: 5); cancelled.cancel()
            XCTAssertThrowsError(try NativePCM16WAVWriter.encode(content: "AAA=", sampleRate: 8000, channels: 1, cancellation: cancelled)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try NativePCM16WAVWriter.encode(content: "AAA=", sampleRate: 8000, channels: 1, cancellation: ToolCallCancellation(timeoutSeconds: 0))) { XCTAssertTrue($0 is ToolCallDeadlineExceeded) }
        }.value
    }

    func testToolReplacementMetadataFullBinaryPagesAndHostAuthorizedWrite() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let raw = Self.noise(samples: 20_000)
                let existing = project.appendingPathComponent("replace.WAV")
                try Data("prior".utf8).write(to: existing); XCTAssertEqual(Darwin.chmod(existing.path, 0o600), 0)
                for destination in [existing, root.appendingPathComponent("owner-authorized.wav")] {
                    let result = try app.tools.call(name: "audio_write", arguments: Self.arguments(destination, raw: raw, rate: 44100, channels: 2), clientID: client)
                    XCTAssertTrue(result.ok, "\(result.payload)")
                    let data = try Data(contentsOf: destination)
                    XCTAssertEqual(result.payload["format"] as? String, "wav"); XCTAssertEqual(result.payload["engine"] as? String, "swift-pcm16-riff")
                    XCTAssertEqual(result.payload["input_contract"] as? String, "pcm16le-interleaved-v1")
                    XCTAssertEqual(result.payload["output_contract"] as? String, "wav-pcm16le-interleaved-v1")
                    XCTAssertEqual(result.payload["sample_rate"] as? Int, 44100); XCTAssertEqual(result.payload["channels"] as? Int, 2)
                    XCTAssertEqual(result.payload["frames"] as? Int, 10_000); XCTAssertEqual(result.payload["pcm_bytes"] as? Int, 40_000)
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
                    XCTAssertTrue(sawEOF); XCTAssertEqual(readback, data); XCTAssertEqual(offset, data.count)
                    XCTAssertEqual(try Self.inspectWAV(data, rate: 44100, channels: 2), raw)
                }
            }
        }.value
    }

    func testMalformedToolArgumentsCancellationAndPinnedFailurePreserveDestination() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let destination = project.appendingPathComponent("strict.wav"), prior = Data("preserve".utf8)
                try prior.write(to: destination)
                let valid = Self.arguments(destination, raw: Data([0, 0]), rate: 8000, channels: 1)
                let bad: [(String, Any, String)] = [("path", 1, "invalid_path"), ("path", true, "invalid_path"), ("path", " \n", "invalid_path"), ("path", "nul\u{0}.wav", "invalid_path"),
                    ("path", "no-extension", "invalid_path"), ("content", false, "invalid_audio_content"), ("content", "AAB=", "invalid_audio_content"),
                    ("sample_rate", true, "invalid_audio_sample_rate"), ("sample_rate", 96000, "invalid_audio_sample_rate"), ("channels", "1", "invalid_audio_channels"),
                    ("format", "wav", "invalid_audio_arguments")]
                for (key, value, code) in bad {
                    var args = valid; args[key] = value
                    let result = try XCTUnwrap(try DocsToolPack().handle(name: "audio_write", arguments: args, context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, code)
                    XCTAssertEqual(try Data(contentsOf: destination), prior)
                }
                for key in ["content", "sample_rate", "channels"] {
                    var args = valid; args.removeValue(forKey: key)
                    XCTAssertFalse(try XCTUnwrap(try DocsToolPack().handle(name: "audio_write", arguments: args, context: nil, clientID: client, app: app, cancellation: nil)).ok)
                }
                for cancellation in [ToolCallCancellation(timeoutSeconds: 5), ToolCallCancellation(timeoutSeconds: 0)] {
                    if !cancellation.isDeadlineExceeded { cancellation.cancel() }
                    XCTAssertThrowsError(try DocsToolPack().handle(name: "audio_write", arguments: valid, context: nil, clientID: client, app: app, cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError || $0 is ToolCallDeadlineExceeded) }
                }
                let outside = root.appendingPathComponent("outside", isDirectory: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true); try prior.write(to: outside.appendingPathComponent("keep.wav"))
                let link = project.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                let directory = project.appendingPathComponent("directory.wav", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try prior.write(to: directory.appendingPathComponent("keep"))
                for failed in [link.appendingPathComponent("keep.wav"), directory] {
                    let result = try XCTUnwrap(try DocsToolPack().handle(name: "audio_write", arguments: Self.arguments(failed, raw: Data([0, 0]), rate: 8000, channels: 1), context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, "audio_write_failed")
                }
                XCTAssertEqual(try Data(contentsOf: destination), prior); XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("keep.wav")), prior)
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path).sorted(), ["directory.wav", "link", "strict.wav"])
            }
        }.value
    }

    func testRawPathAdmissionOwnGrantAndStaleContextPreservePCMAndWrites() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let context = try app.projectContexts.invocationContext(for: client)
                let destination = project.appendingPathComponent("denied.wav")
                let args = Self.arguments(destination, raw: Self.pcm([32767, -32768]), rate: 8000, channels: 2)
                let authorization = ToolAuthorizationService(paths: app.paths, config: app.config)
                for raw in [NSNull(), 1, true, ["bad.wav"], ["path": "bad.wav"], "", " \n", "nul\u{0}.wav"] as [Any] {
                    var bad = args; bad["path"] = raw
                    guard case .denied(let code, _) = try authorization.authorize(tool: "audio_write", arguments: bad, context: context, clientID: client, binding: nil, cancellation: nil) else { XCTFail("Do not coerce raw paths"); continue }
                    XCTAssertEqual(code, "invalid_path")
                }
                for path in ["relative.wav", root.appendingPathComponent("host-wide.wav").path] {
                    var supplied = args; supplied["path"] = path
                    guard case .allowed(let normalized) = try authorization.authorize(tool: "audio_write", arguments: supplied, context: context, clientID: client, binding: nil, cancellation: nil) else { return XCTFail("Preserve owner-authorized host writes") }
                    XCTAssertEqual(normalized["content"] as? String, args["content"] as? String)
                    XCTAssertEqual(normalized["sample_rate"] as? Int, 8000); XCTAssertEqual(normalized["channels"] as? Int, 2)
                }
                let deniedClient = ClientID("audio-denied")
                _ = try app.projectContexts.bind(owner: ProjectBindingOwner(kind: .mcpClient, id: deniedClient.rawValue), projectID: context.projectID,
                    generation: context.projectGeneration, authorizationScope: ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots,
                        allowedTools: ["fs_write", "image_write", "archive_write"], networkAllowed: false, maximumInlineOutputBytes: 65536))
                let denied = try app.tools.call(name: "audio_write", arguments: args, clientID: deniedClient)
                XCTAssertFalse(denied.ok); XCTAssertEqual(denied.payload["code"] as? String, "tool_not_granted")
                _ = try app.projectContexts.beginReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                _ = try app.projectContexts.completeReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                let stale = try XCTUnwrap(try DocsToolPack().handle(name: "audio_write", arguments: args, context: context, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(stale.ok); XCTAssertEqual(stale.payload["code"] as? String, "audio_encode_failed")
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
        }.value
    }

    func testDefaultsCustomDenialsImportedCapabilitiesAndContentAuditStayNarrow() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                XCTAssertEqual(ProjectInstructionQueueStore.ordinaryDefaultAllowedTools.filter { $0 == "audio_write" }.count, 1)
                XCTAssertTrue(ContinuityAutomation.progressTools.contains("audio_write"))
                let catalog = try ToolDefinitionCatalog.production(toolNames: app.tools.toolNames)
                for specs in [app.catalog.all(), AgentCatalog.builtinDefaults()] {
                    let docs = try XCTUnwrap(specs.first { $0.id == "docs" })
                    XCTAssertEqual(docs.tools.filter { $0 == "audio_write" }.count, 1)
                    XCTAssertTrue(docs.body.contains("65536-byte")); XCTAssertTrue(docs.body.contains("canonical JSON"))
                    for spec in specs where spec.id != "docs" { XCTAssertFalse(spec.tools.contains("audio_write")) }
                }
                for old in ["fs_write", "pdf_write", "pdf_from_file", "docx_write", "xlsx_write", "pptx_write", "ods_write", "image_write", "archive_write"] {
                    XCTAssertFalse(ToolGrantSemantics.grants(tool: "audio_write", from: [old])); XCTAssertFalse(ToolGrantSemantics.grants(tool: old, from: ["audio_write"]))
                    XCTAssertEqual(try catalog.definitions(allowedToolNames: [old]).map(\.name), [old])
                }
                let staticData = try XCTUnwrap(app.telemetry.loadStatic("tools-catalog.js"))
                let staticText = try XCTUnwrap(String(data: staticData.0, encoding: .utf8))
                XCTAssertEqual(staticText.components(separatedBy: "\"audio_write\"").count - 1, 1)
                let cards = ForgeCollector(paths: app.paths, store: app.store, catalog: app.catalog, toolNames: { app.tools.toolNames }).collect().mcpTools
                XCTAssertEqual(cards.filter { $0.name == "audio_write" }.count, 1)
                XCTAssertEqual(try XCTUnwrap(cards.first { $0.name == "audio_write" }).pack, "docs")
                let custom = "---\nid: docs\ndisplay_name: Owner docs\ntools:\n  - fs_write\n  - archive_write\ntools_forbidden:\n  - audio_write\n---\nOwner grants.\n"
                try custom.write(to: app.paths.agentsDir.appendingPathComponent("docs.md"), atomically: true, encoding: .utf8); app.catalog.reload()
                let spec = try XCTUnwrap(app.catalog.get("docs"))
                XCTAssertEqual(spec.source, "custom"); XCTAssertEqual(spec.tools, ["fs_write", "archive_write"]); XCTAssertEqual(spec.toolsForbidden, ["audio_write"])
                let context = ToolInvocationContext(projectID: ProjectID(), projectGeneration: .initial, clientID: client,
                    authorizationScope: ToolAuthorizationScope(canonicalRoots: [project], allowedTools: ["*"], networkAllowed: false, maximumInlineOutputBytes: 65536))
                let binding = ActiveBinding(sessionID: SessionID("audio-custom"), agentID: spec.id, toolsPrimary: spec.tools, toolsForbidden: spec.toolsForbidden, cwd: project.path)
                let args = Self.arguments(project.appendingPathComponent("denied.wav"), raw: Data([0, 0]), rate: 8000, channels: 1)
                guard case .denied(let code, _) = try ToolAuthorizationService(paths: app.paths, config: app.config).authorize(tool: "audio_write", arguments: args, context: context, clientID: client, binding: binding, cancellation: nil) else { return XCTFail("Custom denial must override wildcard") }
                XCTAssertEqual(code, "tool_forbidden")
                let source = root.appendingPathComponent("explicit-package", isDirectory: true)
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                try "Keep explicit grants.".write(to: source.appendingPathComponent("instructions.md"), atomically: true, encoding: .utf8)
                let projectID = ProjectID(), requested = ["fs_read", "archive_write"]
                let manifest: [String: Any] = ["schema_version": 1, "package_id": "audio-explicit", "version": "1", "mission": "Keep explicit grants.", "project_id": projectID.description,
                    "entry_documents": ["instructions.md"], "requested_capabilities": requested, "completion_gates": [ProjectInstructionQueueStore.builtInCompletionGate], "resource_policy": ["profile": "project-default"]]
                try JSONSupport.data(from: manifest).write(to: source.appendingPathComponent("forge-package.json"))
                let store = try ProjectInstructionQueueStore(paths: app.paths), imported = try store.importPackage(sourceURL: source, projectID: projectID, generation: .initial)
                let package = try XCTUnwrap(imported.packages.first), published = app.paths.instructionPackageStoreDir.appendingPathComponent(package.contentSHA256)
                defer { XCTAssertNoThrow(try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: published.path)) }
                let expected = Array(Set(requested).union(["instruction_catalog", "instruction_read"])).sorted()
                XCTAssertEqual(package.allowedTools, expected); XCTAssertEqual(try XCTUnwrap(store.snapshot(projectID: projectID, generation: .initial).packages.first).allowedTools, expected)
                XCTAssertFalse(expected.contains("audio_write"))
                let importedContext = ToolInvocationContext(projectID: projectID, projectGeneration: .initial, clientID: client,
                    authorizationScope: ToolAuthorizationScope(canonicalRoots: [source], allowedTools: Set(expected), networkAllowed: false, maximumInlineOutputBytes: 65536))
                guard case .denied(let importedCode, _) = try ToolAuthorizationService(paths: app.paths, config: app.config).authorize(tool: "audio_write", arguments: args, context: importedContext, clientID: client, binding: nil, cancellation: nil) else { return XCTFail("Imported explicit grants stay narrow") }
                XCTAssertEqual(importedCode, "tool_not_granted"); XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("denied.wav").path))
                let before = try JSONSupport.data(from: args), sanitized = ToolAuditSanitizer.sanitize(args)
                XCTAssertEqual(sanitized["content"] as? String, "<redacted:4 bytes>")
                XCTAssertEqual(sanitized["sample_rate"] as? Int, 8000); XCTAssertEqual(sanitized["channels"] as? Int, 1)
                XCTAssertEqual(try JSONSupport.data(from: args), before)
            }
        }.value
    }

    private static func pcm(_ values: [Int16]) -> Data {
        var data = Data()
        for value in values { let bits = UInt16(bitPattern: value); data.append(UInt8(truncatingIfNeeded: bits)); data.append(UInt8(truncatingIfNeeded: bits >> 8)) }
        return data
    }

    private static func noise(samples: Int) -> Data {
        var state: UInt32 = 0x13579BDF
        var data = Data(capacity: samples * 2)
        for _ in 0..<samples { state = state &* 1_664_525 &+ 1_013_904_223; data.append(UInt8(truncatingIfNeeded: state)); data.append(UInt8(truncatingIfNeeded: state >> 8)) }
        return data
    }

    private static func arguments(_ url: URL, raw: Data, rate: Int, channels: Int) -> [String: Any] {
        ["path": url.path, "content": raw.base64EncodedString(), "sample_rate": rate, "channels": channels]
    }

    private static func withToolApp(root: URL, _ operation: (ForgeApp, ClientID, URL) throws -> Void) throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home", isDirectory: true), startTelemetry: false)
        defer { XCTAssertTrue(app.shutdown().completed) }
        _ = try app.config.update(["allowed_roots": [project.path]], save: false)
        let client = ClientID("audio-writer-tests")
        let result = try app.tools.call(name: "project_memory.initialize", arguments: ["project_path": project.path], clientID: client)
        XCTAssertTrue(result.ok, "\(result.payload)")
        try operation(app, client, project)
    }

    private enum WireError: Error { case malformed }

    /// Fixed two-chunk PCM wire contract: independent scalar reads, extent and EOF.
    private static func inspectWAV(_ data: Data, rate: Int, channels: Int) throws -> Data {
        let bytes = Array(data)
        guard bytes.count >= 46, bytes.count <= 1_048_620 else { throw WireError.malformed }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) }
        func u32(_ offset: Int) -> Int { Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) | (Int(bytes[offset + 2]) << 16) | (Int(bytes[offset + 3]) << 24) }
        guard Array(bytes[0..<4]) == [82, 73, 70, 70], u32(4) == bytes.count - 8,
              Array(bytes[8..<12]) == [87, 65, 86, 69], Array(bytes[12..<16]) == [102, 109, 116, 32], u32(16) == 16,
              u16(20) == 1, u16(22) == channels, u32(24) == rate, u32(28) == rate * channels * 2,
              u16(32) == channels * 2, u16(34) == 16, Array(bytes[36..<40]) == [100, 97, 116, 97],
              u32(40) == bytes.count - 44, u32(40) > 0, u32(40) % (channels * 2) == 0 else { throw WireError.malformed }
        return Data(bytes[44...])
    }
}

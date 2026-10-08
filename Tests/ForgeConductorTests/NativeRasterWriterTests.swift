import Foundation
import Darwin
import CoreGraphics
import ImageIO
import XCTest
@testable import ForgeConductorCore

final class NativeRasterWriterTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-raster-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        temporaryRoot = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryRoot)
    }

    func testTransparentAndPartialAlphaPixelsPreserveStraightRGBAAndTopToBottomRows() async throws {
        try await Task.detached(priority: .utility) {
            let pixels = Self.controlPixels
            let png = try NativeRasterWriter.encode(width: 2, height: 2, content: pixels.base64EncodedString())
            try Self.inspectPNG(png, width: 2, height: 2)
            XCTAssertEqual(try Self.decodedStraightPixels(png, width: 2, height: 2), pixels)
        }.value
    }

    func testDimensionTypesAndPixelProductAreStrict() async throws {
        let invalid: [Any?] = [nil, NSNull(), true, false, "1", 0, -1, 1025, 1.5,
            NSNumber(value: Double.nan), NSNumber(value: Double.infinity),
            NSDecimalNumber(string: "1.00000000000000001")]
        for value in invalid {
            XCTAssertThrowsError(try NativeRasterWriter.integerDimension(value)) {
                XCTAssertEqual($0 as? NativeRasterError, .invalidDimensions)
            }
        }
        XCTAssertEqual(try NativeRasterWriter.integerDimension(1), 1)
        XCTAssertEqual(try NativeRasterWriter.integerDimension(1024), 1024)
        try await Task.detached(priority: .utility) {
            for dimensions in [(0, 1), (1, 0), (-1, 1), (1025, 1), (1, 1025), (512, 513), (1024, 1024), (Int.max, Int.max)] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: dimensions.0, height: dimensions.1, content: "")) {
                    XCTAssertEqual($0 as? NativeRasterError, .invalidDimensions)
                }
            }
        }.value
    }

    func testCanonicalPaddingAndExactDecodedPixelLengthAreRequired() async throws {
        try await Task.detached(priority: .utility) {
            let canonical = Data([0, 0, 0, 0]).base64EncodedString()
            XCTAssertEqual(canonical, "AAAAAA==")
            XCTAssertEqual(Data(base64Encoded: "AAAAAB=="), Data([0, 0, 0, 0]))
            let invalid = ["", "AAAAAA", "AAAAAA=", "AAAAAB==", "AAAAAA==\n", "AAAA AA==", "!!!!AA==",
                Data([0, 0, 0]).base64EncodedString(), Data([0, 0, 0, 0, 0]).base64EncodedString(),
                String(repeating: "A", count: NativeRasterWriter.maximumBase64Bytes + 1)]
            for content in invalid {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 1, height: 1, content: content)) {
                    XCTAssertEqual($0 as? NativeRasterError, .invalidContent)
                }
            }
            let png = try NativeRasterWriter.encode(width: 1, height: 1, content: canonical)
            XCTAssertEqual(try Self.decodedStraightPixels(png, width: 1, height: 1), Data([0, 0, 0, 0]))
        }.value
    }

    func testOnePixelAndTallWideDimensionEdgesRemainAvailable() async throws {
        try await Task.detached(priority: .utility) {
            for (width, height) in [(1, 1), (1024, 1), (1, 1024)] {
                let pixels = Data((0..<(width * height)).flatMap { index in
                    [UInt8(index % 251), UInt8((index * 3) % 251), UInt8((index * 7) % 251), UInt8(255)]
                })
                let png = try NativeRasterWriter.encode(width: width, height: height, content: pixels.base64EncodedString())
                try Self.inspectPNG(png, width: width, height: height)
                XCTAssertEqual(try Self.decodedStraightPixels(png, width: width, height: height), pixels)
            }
        }.value
    }

    func testMaximumNoisyPixelInputProducesOneBoundedExactPNG() async throws {
        try await Task.detached(priority: .utility) {
            var state: UInt32 = 0x76543210
            var pixels = Data(capacity: NativeRasterWriter.maximumInputBytes)
            for _ in 0..<NativeRasterWriter.maximumPixels {
                for _ in 0..<3 {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    pixels.append(UInt8(truncatingIfNeeded: state >> 24))
                }
                pixels.append(255)
            }
            XCTAssertEqual(pixels.count, 1_048_576)
            let content = pixels.base64EncodedString()
            XCTAssertEqual(content.utf8.count, NativeRasterWriter.maximumBase64Bytes)
            let png = try NativeRasterWriter.encode(width: 1024, height: 256, content: content)
            XCTAssertLessThanOrEqual(png.count, 2_097_152)
            try Self.inspectPNG(png, width: 1024, height: 256)
            XCTAssertEqual(try Self.decodedStraightPixels(png, width: 1024, height: 256), pixels)
        }.value
    }

    func testMainThreadCancelledAndExpiredRequestsCannotEncode() async throws {
        let content = Self.controlPixels.base64EncodedString()
        try await MainActor.run {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content)) {
                XCTAssertEqual($0 as? NativeRasterError, .workerRequired)
            }
        }
        try await Task.detached(priority: .utility) {
            let cancelled = ToolCallCancellation(timeoutSeconds: 10)
            cancelled.cancel()
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, cancellation: cancelled)) {
                XCTAssertTrue($0 is CancellationError)
            }
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                cancellation: ToolCallCancellation(timeoutSeconds: 0))) { XCTAssertTrue($0 is ToolCallDeadlineExceeded) }
        }.value
    }

    func testConsumerOutputLimitErrorRemainsAuthoritative() async throws {
        try await Task.detached(priority: .utility) {
            let content = Self.controlPixels.base64EncodedString()
            for limit in [0, 1, NativeRasterWriter.maximumOutputBytes + 1] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, outputByteLimit: limit)) {
                    XCTAssertEqual($0 as? NativeRasterError, .outputTooLarge)
                }
            }
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, pixelFormat: "bgra8")) {
                XCTAssertEqual($0 as? NativeRasterError, .invalidPixelFormat)
            }
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, format: "jpeg")) {
                XCTAssertEqual($0 as? NativeRasterError, .invalidFormat)
            }
        }.value
    }

    func testToolStrictArgumentsAndCancellationPreserveDestination() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let destination = project.appendingPathComponent("strict.png")
                let prior = Data("preserve destination".utf8)
                try prior.write(to: destination)
                let valid = Self.arguments(path: destination.path)
                var cases: [([String: Any], String)] = []
                for path in [7, true, " \n", "nul\u{0}.png", project.appendingPathComponent("no-extension").path] as [Any] {
                    var value = valid; value["path"] = path; cases.append((value, "invalid_path"))
                }
                var missingPath = valid; missingPath.removeValue(forKey: "path"); cases.append((missingPath, "invalid_path"))
                for (key, values, code) in [
                    ("width", [true, "2", 0, 1025, 2.5] as [Any], "invalid_image_dimensions"),
                    ("height", [false, NSNull(), -1, 1025, 1.5] as [Any], "invalid_image_dimensions"),
                    ("content", [7, false, NSNull(), "", "AAAAAB=="] as [Any], "invalid_content"),
                    ("pixel_format", [7, NSNull(), "bgra8", "RGBA8"] as [Any], "invalid_pixel_format"),
                    ("format", [true, NSNull(), "jpeg", "PNG"] as [Any], "invalid_image_format")
                ] {
                    for replacement in values { var value = valid; value[key] = replacement; cases.append((value, code)) }
                }
                var missingContent = valid; missingContent.removeValue(forKey: "content"); cases.append((missingContent, "invalid_content"))
                for key in ["width", "height"] {
                    var missing = valid; missing.removeValue(forKey: key); cases.append((missing, "invalid_image_dimensions"))
                }
                for (arguments, code) in cases {
                    let result = try XCTUnwrap(try DocsToolPack().handle(name: "image_write", arguments: arguments,
                        context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(result.ok, "\(arguments)")
                    XCTAssertEqual(result.payload["code"] as? String, code)
                    XCTAssertEqual(try Data(contentsOf: destination), prior)
                }
                for control in [ToolCallCancellation(timeoutSeconds: 10), ToolCallCancellation(timeoutSeconds: 0)] {
                    if !control.isDeadlineExceeded { control.cancel() }
                    XCTAssertThrowsError(try DocsToolPack().handle(name: "image_write", arguments: valid,
                        context: nil, clientID: client, app: app, cancellation: control)) {
                        XCTAssertTrue($0 is CancellationError || $0 is ToolCallDeadlineExceeded)
                    }
                }
                XCTAssertEqual(try Data(contentsOf: destination), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), ["strict.png"])
            }
        }.value
    }

    func testToolReplacementModeBinaryMetadataAndReadback() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let existing = project.appendingPathComponent("replace.png")
                try Data("prior".utf8).write(to: existing)
                XCTAssertEqual(Darwin.chmod(existing.path, 0o600), 0)
                for file in [existing, project.appendingPathComponent("fresh.PNG")] {
                    var arguments = Self.arguments(path: file.path)
                    if file != existing { arguments["pixel_format"] = "rgba8"; arguments["format"] = "png" }
                    let result = try app.tools.call(name: "image_write", arguments: arguments, clientID: client)
                    XCTAssertTrue(result.ok, "\(result.payload)")
                    let bytes = try Data(contentsOf: file)
                    XCTAssertEqual(result.payload["path"] as? String, file.path)
                    XCTAssertEqual(result.payload["format"] as? String, "png")
                    XCTAssertEqual(result.payload["engine"] as? String, "apple-imageio")
                    XCTAssertEqual(result.payload["width"] as? Int, 2)
                    XCTAssertEqual(result.payload["height"] as? Int, 2)
                    XCTAssertEqual(result.payload["pixel_format"] as? String, "rgba8")
                    XCTAssertEqual(result.payload["color_space"] as? String, "srgb")
                    XCTAssertEqual(result.payload["pixel_bytes"] as? Int, 16)
                    XCTAssertEqual(result.payload["pixel_contract"] as? String, "rgba8-straight-srgb-v1")
                    XCTAssertEqual(result.payload["bytes_written"] as? Int, bytes.count)
                    XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                    XCTAssertNil(result.payload["content"])
                    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue,
                        file == existing ? 0o600 : 0o644)
                    XCTAssertEqual(try Self.decodedStraightPixels(bytes, width: 2, height: 2), Self.controlPixels)
                    let read = try app.tools.call(name: "fs_read", arguments: ["path": file.path, "encoding": "base64", "maximum_bytes": 32768], clientID: client)
                    XCTAssertTrue(read.ok, "\(read.payload)")
                    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(read.payload["content"] as? String)), bytes)
                }
                XCTAssertTrue(app.audit.flushAttempts(timeout: 2))
                let event = try XCTUnwrap(app.audit.recent(limit: 8).first(where: { $0.tool == "image_write" }))
                XCTAssertFalse(event.argsJSON?.contains(Self.controlPixels.base64EncodedString()) == true)
                XCTAssertTrue(event.argsJSON?.contains("redacted") == true)
            }
        }.value
    }

    func testPinnedWriteRejectsSymlinkParentAndCleansFailedRename() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let outside = root.appendingPathComponent("outside", isDirectory: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let prior = Data("outside protected".utf8)
                try prior.write(to: outside.appendingPathComponent("target.png"))
                let link = project.appendingPathComponent("link", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                let blocked = try XCTUnwrap(try DocsToolPack().handle(name: "image_write",
                    arguments: Self.arguments(path: link.appendingPathComponent("target.png").path),
                    context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(blocked.ok)
                XCTAssertEqual(blocked.payload["code"] as? String, "image_write_failed")
                XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("target.png")), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["target.png"])
                let directory = project.appendingPathComponent("directory.png", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try prior.write(to: directory.appendingPathComponent("keep"))
                let rename = try XCTUnwrap(try DocsToolPack().handle(name: "image_write", arguments: Self.arguments(path: directory.path),
                    context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(rename.ok)
                XCTAssertEqual(rename.payload["code"] as? String, "image_write_failed")
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path).sorted(), ["directory.png", "link"])
            }
        }.value
    }

    func testStaleProjectContextAndExplicitGrantPreventWrites() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let outside = root.appendingPathComponent("outside.png")
                let prior = Data("outside sentinel".utf8)
                try prior.write(to: outside)
                let context = try app.projectContexts.invocationContext(for: client)
                let deniedClient = ClientID("raster-denied-client")
                _ = try app.projectContexts.bind(owner: ProjectBindingOwner(kind: .mcpClient, id: deniedClient.rawValue), projectID: context.projectID,
                    generation: context.projectGeneration, authorizationScope: ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots,
                        allowedTools: ["fs_read"], networkAllowed: context.authorizationScope.networkAllowed,
                        maximumInlineOutputBytes: context.authorizationScope.maximumInlineOutputBytes))
                let denied = try app.tools.call(name: "image_write", arguments: Self.arguments(path: outside.path), clientID: deniedClient)
                XCTAssertFalse(denied.ok)
                XCTAssertEqual(denied.payload["code"] as? String, "tool_not_granted")
                XCTAssertEqual(try Data(contentsOf: outside), prior)
                _ = try app.projectContexts.beginReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                _ = try app.projectContexts.completeReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                let file = project.appendingPathComponent("stale.png")
                let stale = try XCTUnwrap(try DocsToolPack().handle(name: "image_write", arguments: Self.arguments(path: file.path),
                    context: context, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(stale.ok)
                XCTAssertEqual(stale.payload["code"] as? String, "image_encode_failed")
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            }
        }.value
    }

    func testOwnerAuthorizedHostWideWriteAndODSNeighborRemainAvailable() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let outside = root.appendingPathComponent("owner-authorized.png")
                XCTAssertFalse(outside.path.hasPrefix(project.path + "/"))
                let result = try app.tools.call(name: "image_write", arguments: Self.arguments(path: outside.path), clientID: client)
                XCTAssertTrue(result.ok, "\(result.payload)")
                let bytes = try Data(contentsOf: outside)
                XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                XCTAssertEqual(try Self.decodedStraightPixels(bytes, width: 2, height: 2), Self.controlPixels)
                let ods = project.appendingPathComponent("neighbor.ods")
                let neighbor = try app.tools.call(name: "ods_write", arguments: ["path": ods.path, "rows": [["prior CR\rtext"]]], clientID: client)
                XCTAssertTrue(neighbor.ok, "\(neighbor.payload)")
                XCTAssertEqual(neighbor.payload["text_contract"] as? String, "ods-text-cells-v1")
                XCTAssertEqual(try NativeODSReader.text(in: Data(contentsOf: ods)), "[Sheet Sheet1]\nA1: prior CR\ntext")
            }
        }.value
    }

    private static var controlPixels: Data {
        Data([255, 0, 0, 255, 17, 34, 51, 128, 10, 20, 30, 0, 60, 120, 180, 64])
    }

    private static func arguments(path: String) -> [String: Any] {
        ["path": path, "width": 2, "height": 2, "content": controlPixels.base64EncodedString()]
    }

    private static func withToolApp(root: URL, _ operation: (ForgeApp, ClientID, URL) throws -> Void) throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home", isDirectory: true))
        defer { app.shutdown() }
        _ = try app.config.update(["allowed_roots": [project.path]], save: false)
        let client = ClientID("raster-writer-tests")
        let result = try app.tools.call(name: "project_memory.initialize", arguments: ["project_path": project.path], clientID: client)
        XCTAssertTrue(result.ok, "\(result.payload)")
        try operation(app, client, project)
    }

    private static func decodedStraightPixels(_ png: Data, width: Int, height: Int) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width); XCTAssertEqual(image.height, height)
        XCTAssertEqual(image.bitsPerComponent, 8); XCTAssertEqual(image.bitsPerPixel, 32)
        XCTAssertEqual(image.alphaInfo, .last)
        XCTAssertEqual(image.colorSpace?.model, .rgb)
        guard image.width == width, image.height == height, image.bitsPerPixel == 32,
              image.alphaInfo == .last, image.bytesPerRow >= width * 4 else { throw FixtureError.malformed }
        let provider = try XCTUnwrap(image.dataProvider)
        let data = try XCTUnwrap(provider.data) as Data
        guard data.count >= image.bytesPerRow * height else { throw FixtureError.malformed }
        var pixels = Data(capacity: width * height * 4)
        for row in 0..<height {
            let start = row * image.bytesPerRow
            pixels.append(data.subdata(in: start..<(start + width * 4)))
        }
        return pixels
    }

    private static func inspectPNG(_ data: Data, width: Int, height: Int) throws {
        guard data.count >= 57, data.count <= NativeRasterWriter.maximumOutputBytes,
              data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { throw FixtureError.malformed }
        func word(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw FixtureError.malformed }
            return (0..<4).reduce(0) { ($0 << 8) | UInt32(data[offset + $1]) }
        }
        var offset = 8, chunks = 0, sawData = false, sawEnd = false
        while offset < data.count {
            guard chunks < 1024, offset <= data.count - 12 else { throw FixtureError.malformed }
            let count = Int(try word(offset))
            guard count <= data.count - offset - 12 else { throw FixtureError.malformed }
            let typeData = data.subdata(in: (offset + 4)..<(offset + 8))
            let type = try XCTUnwrap(String(data: typeData, encoding: .ascii))
            let payload = data.subdata(in: (offset + 8)..<(offset + 8 + count))
            XCTAssertEqual(try word(offset + 8 + count), crc32(typeData + payload))
            XCTAssertNotEqual(type, "acTL")
            if chunks == 0 {
                XCTAssertEqual(type, "IHDR"); XCTAssertEqual(count, 13)
                guard count == 13 else { throw FixtureError.malformed }
                XCTAssertEqual(try word(offset + 8), UInt32(width)); XCTAssertEqual(try word(offset + 12), UInt32(height))
                XCTAssertEqual(Array(payload.suffix(5)), [8, 6, 0, 0, 0])
            }
            if type == "IDAT" { sawData = true }
            offset += count + 12; chunks += 1
            if type == "IEND" { XCTAssertEqual(count, 0); sawEnd = true; break }
        }
        XCTAssertTrue(sawData); XCTAssertTrue(sawEnd); XCTAssertEqual(offset, data.count)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 0 ? 0 : 0xEDB8_8320) }
        }
        return value ^ 0xFFFF_FFFF
    }

    private enum FixtureError: Error { case malformed }
}

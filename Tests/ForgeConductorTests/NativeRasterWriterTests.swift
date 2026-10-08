import Foundation
import Darwin
import CoreGraphics
import ImageIO
import AppKit
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

    func testBMPOnePixelProducesOneNativeReadableSRGBImage() async throws {
        try await Task.detached(priority: .utility) {
            let pixels = Data([17, 83, 191, 255])
            let encoded = try NativeRasterWriter.encode(width: 1, height: 1,
                content: pixels.base64EncodedString(), format: "bmp")
            XCTAssertEqual(try Self.decodedBMPWire(encoded, width: 1, height: 1), pixels)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.microsoft.bmp")
            XCTAssertEqual(CGImageSourceGetCount(source), 1)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 1); XCTAssertEqual(image.height, 1)
            // A native sRGB interpretation is separate from ICC embedding in the file.
            XCTAssertEqual(try XCTUnwrap(image.colorSpace?.copyICCData()) as Data,
                try XCTUnwrap(NSColorSpace.sRGB.iccProfileData))
            XCTAssertLessThanOrEqual(encoded.count, NativeRasterWriter.maximumOutputBytes)
        }.value
    }

    func testBMPWireChannelsAlphaAndNativeRenderingMatchPNGReference() async throws {
        try await Task.detached(priority: .utility) {
            var allAlpha = Data(capacity: 256 * 4)
            for alpha in 0...255 { allAlpha.append(contentsOf: [17, 83, 191, UInt8(alpha)]) }
            let fixtures: [(Int, Int, Data)] = [
                (1, 1, Data([0, 0, 0, 0])), (1, 1, Data([17, 83, 191, 0])),
                (1, 1, Data([211, 37, 109, 128])), (2, 2, Self.binaryPixels),
                (3, 2, Data([255, 0, 0, 255, 17, 34, 51, 0, 7, 83, 191, 1,
                             31, 157, 63, 64, 211, 37, 109, 128, 19, 71, 233, 254])),
                (256, 1, allAlpha)]
            for (width, height, pixels) in fixtures {
                let encoded = try NativeRasterWriter.encode(width: width, height: height,
                    content: pixels.base64EncodedString(), format: "bmp")
                // Raw masked channels establish straight alpha/hidden RGB independently
                // of native premultiplied rendering. This contract requires both checks.
                XCTAssertEqual(try Self.decodedBMPWire(encoded, width: width, height: height), pixels)
                let png = try NativeRasterWriter.encode(width: width, height: height,
                    content: pixels.base64EncodedString())
                XCTAssertEqual(try Self.renderedRaster(encoded, width: width, height: height, type: "com.microsoft.bmp"),
                    try Self.renderedRaster(png, width: width, height: height, type: "public.png"))
            }
        }.value
    }

    func testBMPDimensionEdgesAndMaximumNoisyWirePixels() async throws {
        try await Task.detached(priority: .utility) {
            for (width, height) in [(1, 1), (1024, 1), (1, 1024), (17, 33), (1024, 256), (256, 1024)] {
                var state: UInt32 = 0x2468ACE0
                var pixels = Data(capacity: width * height * 4)
                for index in 0..<(width * height) {
                    for _ in 0..<3 {
                        state = state &* 1_664_525 &+ 1_013_904_223
                        pixels.append(UInt8(truncatingIfNeeded: state >> 24))
                    }
                    pixels.append(UInt8(truncatingIfNeeded: index))
                }
                let content = pixels.base64EncodedString()
                if width * height == NativeRasterWriter.maximumPixels {
                    XCTAssertEqual(pixels.count, NativeRasterWriter.maximumInputBytes)
                    XCTAssertEqual(content.utf8.count, NativeRasterWriter.maximumBase64Bytes)
                }
                let encoded = try NativeRasterWriter.encode(width: width, height: height,
                    content: content, format: "bmp")
                XCTAssertEqual(try Self.decodedBMPWire(encoded, width: width, height: height), pixels)
                XCTAssertLessThanOrEqual(encoded.count, NativeRasterWriter.maximumOutputBytes)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
                XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.microsoft.bmp")
                XCTAssertEqual(CGImageSourceGetCount(source), 1)
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, width); XCTAssertEqual(image.height, height)
            }
        }.value
    }

    func testBMPWorkerCancellationStrictInputsAndOutputLimitRemainEnforced() async throws {
        let content = Self.controlPixels.base64EncodedString()
        try await MainActor.run {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, format: "bmp")) {
                XCTAssertEqual($0 as? NativeRasterError, .workerRequired)
            }
        }
        try await Task.detached(priority: .utility) {
            let cancelled = ToolCallCancellation(timeoutSeconds: 10); cancelled.cancel()
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                format: "bmp", cancellation: cancelled)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                format: "bmp", cancellation: ToolCallCancellation(timeoutSeconds: 0))) {
                XCTAssertTrue($0 is ToolCallDeadlineExceeded)
            }
            let encoded = try NativeRasterWriter.encode(width: 2, height: 2, content: content, format: "bmp")
            let exactLimit = try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                format: "bmp", outputByteLimit: encoded.count)
            XCTAssertEqual(exactLimit.count, encoded.count)
            XCTAssertEqual(try Self.decodedBMPWire(exactLimit, width: 2, height: 2), Self.controlPixels)
            for limit in [0, 1, encoded.count - 1, NativeRasterWriter.maximumOutputBytes + 1] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                    format: "bmp", outputByteLimit: limit)) { XCTAssertEqual($0 as? NativeRasterError, .outputTooLarge) }
            }
            for (width, height) in [(0, 1), (1, 0), (-1, 1), (1025, 1), (1, 1025),
                                    (512, 513), (1024, 1024), (Int.max, Int.max)] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: width, height: height, content: "", format: "bmp")) {
                    XCTAssertEqual($0 as? NativeRasterError, .invalidDimensions)
                }
            }
            let invalid = ["", "AAAAAA", "AAAAAA=", "AAAAAB==", "AAAAAA==\n", "AAAA AA==", "!!!!AA==",
                Data([0, 0, 0]).base64EncodedString(), Data([0, 0, 0, 0, 0]).base64EncodedString(),
                String(repeating: "A", count: NativeRasterWriter.maximumBase64Bytes + 1)]
            for value in invalid {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 1, height: 1, content: value, format: "bmp")) {
                    XCTAssertEqual($0 as? NativeRasterError, .invalidContent)
                }
            }
            for pixelFormat in ["bgra8", "RGBA8"] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                    pixelFormat: pixelFormat, format: "bmp")) { XCTAssertEqual($0 as? NativeRasterError, .invalidPixelFormat) }
            }
            for format in ["BMP", "avif"] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, format: format)) {
                    XCTAssertEqual($0 as? NativeRasterError, .invalidFormat)
                }
            }
        }.value
    }

    func testBMPSubsetInspectorRejectsMalformedHeadersAndPixels() async throws {
        try await Task.detached(priority: .utility) {
            let encoded = try NativeRasterWriter.encode(width: 2, height: 2,
                content: Self.controlPixels.base64EncodedString(), format: "bmp")
            XCTAssertEqual(try Self.decodedBMPWire(encoded, width: 2, height: 2), Self.controlPixels)
            var invalid = [Data(encoded.dropLast()), encoded + Data([0]), Data(encoded.prefix(50))]
            for (offset, value) in [(2, UInt32(encoded.count - 1)), (10, 139), (14, 40), (18, 3), (22, 2),
                                    (30, 0), (34, 15), (54, 0), (58, 0), (62, 0), (66, 0),
                                    (70, 0), (126, 138), (130, 1), (134, 1)] {
                var changed = encoded
                for shift in 0..<4 { changed[offset + shift] = UInt8(truncatingIfNeeded: value >> (shift * 8)) }
                invalid.append(changed)
            }
            for (offset, value) in [(0, UInt8(0)), (6, 1), (26, 2), (28, 24)] {
                var changed = encoded; changed[offset] = value; invalid.append(changed)
            }
            for bytes in invalid { XCTAssertThrowsError(try Self.decodedBMPWire(bytes, width: 2, height: 2)) }
            for (width, height) in [(1, 2), (2, 1), (0, 2), (Int.max, Int.max)] {
                XCTAssertThrowsError(try Self.decodedBMPWire(encoded, width: width, height: height))
            }
            var changed = encoded; changed[138] ^= 1
            var expected = Self.controlPixels; expected[2] ^= 1
            XCTAssertEqual(try Self.decodedBMPWire(changed, width: 2, height: 2), expected)
            XCTAssertNotEqual(expected, Self.controlPixels)
        }.value
    }

    func testBMPToolMetadataReadbackAndWriteProtections() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let prior = Data("BMP destination sentinel".utf8)
                let existing = project.appendingPathComponent("replace.bmp")
                try prior.write(to: existing); XCTAssertEqual(Darwin.chmod(existing.path, 0o600), 0)
                func arguments(_ file: URL) -> [String: Any] {
                    ["path": file.path, "width": 2, "height": 2, "content": Self.controlPixels.base64EncodedString(), "format": "bmp"]
                }
                for file in [existing, project.appendingPathComponent("fresh.bmp"), project.appendingPathComponent("uppercase.BMP")] {
                    let result = try app.tools.call(name: "image_write", arguments: arguments(file), clientID: client)
                    XCTAssertTrue(result.ok, "\(result.payload)")
                    let bytes = try Data(contentsOf: file)
                    XCTAssertEqual(try Self.decodedBMPWire(bytes, width: 2, height: 2), Self.controlPixels)
                    XCTAssertEqual(result.payload["format"] as? String, "bmp")
                    XCTAssertEqual(result.payload["engine"] as? String, "apple-imageio")
                    XCTAssertEqual(result.payload["path"] as? String, file.path)
                    XCTAssertEqual(result.payload["width"] as? Int, 2); XCTAssertEqual(result.payload["height"] as? Int, 2)
                    XCTAssertEqual(result.payload["pixel_format"] as? String, "rgba8")
                    XCTAssertEqual(result.payload["color_space"] as? String, "srgb")
                    XCTAssertEqual(result.payload["pixel_bytes"] as? Int, 16)
                    XCTAssertEqual(result.payload["pixel_contract"] as? String, NativeRasterWriter.pixelContract)
                    XCTAssertNil(result.payload["output_contract"])
                    XCTAssertEqual(result.payload["bytes_written"] as? Int, bytes.count)
                    XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                    XCTAssertNil(result.payload["content"])
                    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue,
                        file == existing ? 0o600 : 0o644)
                    let read = try app.tools.call(name: "fs_read", arguments: ["path": file.path, "encoding": "base64", "maximum_bytes": 32768], clientID: client)
                    XCTAssertTrue(read.ok, "\(read.payload)")
                    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(read.payload["content"] as? String)), bytes)
                }
                for (name, format) in [("protected.png", "bmp"), ("protected.tiff", "bmp"), ("protected.jpg", "bmp"),
                                       ("protected.gif", "bmp"), ("protected.webp", "bmp"), ("protected.bmp", "png"),
                                       ("protected.bmp", "absent"), ("no-extension", "bmp")] {
                    let file = project.appendingPathComponent(name); try prior.write(to: file)
                    var value = arguments(file)
                    if format == "absent" { value.removeValue(forKey: "format") } else { value["format"] = format }
                    let result = try app.tools.call(name: "image_write", arguments: value, clientID: client)
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, "invalid_path")
                    XCTAssertEqual(try Data(contentsOf: file), prior)
                }
                let outside = root.appendingPathComponent("bmp-outside", isDirectory: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let outsideFile = outside.appendingPathComponent("target.bmp"); try prior.write(to: outsideFile)
                let link = project.appendingPathComponent("alias", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                let symlink = try XCTUnwrap(try DocsToolPack().handle(name: "image_write",
                    arguments: arguments(link.appendingPathComponent("target.bmp")), context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(symlink.ok); XCTAssertEqual(symlink.payload["code"] as? String, "image_write_failed")
                XCTAssertEqual(try Data(contentsOf: outsideFile), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["target.bmp"])
                let directory = project.appendingPathComponent("directory.bmp", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try prior.write(to: directory.appendingPathComponent("keep"))
                let rename = try XCTUnwrap(try DocsToolPack().handle(name: "image_write", arguments: arguments(directory),
                    context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(rename.ok); XCTAssertEqual(rename.payload["code"] as? String, "image_write_failed")
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), prior)
                XCTAssertTrue(app.audit.flushAttempts(timeout: 2))
                let event = try XCTUnwrap(app.audit.recent(limit: 32).first(where: { $0.tool == "image_write" && $0.status == "ok" }))
                XCTAssertFalse(event.argsJSON?.contains(Self.controlPixels.base64EncodedString()) == true)
                XCTAssertTrue(event.argsJSON?.contains("redacted") == true)
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: project.path).contains { $0.hasPrefix(".forge-") })
            }
        }.value
    }

    func testBMPToolStrictArgumentsPreserveDestination() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let destination = project.appendingPathComponent("strict.bmp")
                let prior = Data("preserve BMP destination".utf8); try prior.write(to: destination)
                var valid = Self.arguments(path: destination.path); valid["format"] = "bmp"
                var cases: [([String: Any], String)] = []
                for path in [7, true, NSNull(), " \n", "nul\u{0}.bmp", project.appendingPathComponent("no-extension").path] as [Any] {
                    var value = valid; value["path"] = path; cases.append((value, "invalid_path"))
                }
                var missingPath = valid; missingPath.removeValue(forKey: "path"); cases.append((missingPath, "invalid_path"))
                for (key, values, code) in [
                    ("width", [true, "2", 0, 1025, 2.5] as [Any], "invalid_image_dimensions"),
                    ("height", [false, NSNull(), -1, 1025, 1.5] as [Any], "invalid_image_dimensions"),
                    ("content", [7, false, NSNull(), "", "AAAAAB=="] as [Any], "invalid_content"),
                    ("pixel_format", [7, NSNull(), "bgra8", "RGBA8"] as [Any], "invalid_pixel_format")
                ] {
                    for replacement in values { var value = valid; value[key] = replacement; cases.append((value, code)) }
                }
                var missingContent = valid; missingContent.removeValue(forKey: "content"); cases.append((missingContent, "invalid_content"))
                for key in ["width", "height"] {
                    var missing = valid; missing.removeValue(forKey: key); cases.append((missing, "invalid_image_dimensions"))
                }
                for format in [true, NSNull(), "BMP", "avif"] as [Any] {
                    // Preserve extension-before-format validation: invalid tokens
                    // fall back to PNG path routing before the format type check.
                    var png = valid; png["path"] = project.appendingPathComponent("strict.png").path
                    png["format"] = format; cases.append((png, "invalid_image_format"))
                    var bmp = valid; bmp["format"] = format; cases.append((bmp, "invalid_path"))
                }
                for (arguments, code) in cases {
                    let result = try XCTUnwrap(try DocsToolPack().handle(name: "image_write", arguments: arguments,
                        context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(result.ok, "\(arguments)"); XCTAssertEqual(result.payload["code"] as? String, code)
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
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), ["strict.bmp"])
            }
        }.value
    }

    func testBMPStaleProjectContextAndOwnGrantPreventWrites() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let prior = Data("protected BMP".utf8)
                let outside = root.appendingPathComponent("owner-authorized.bmp")
                XCTAssertFalse(outside.path.hasPrefix(project.path + "/"))
                let value: [String: Any] = ["path": outside.path, "width": 2, "height": 2,
                    "content": Self.controlPixels.base64EncodedString(), "format": "bmp"]
                let owner = try app.tools.call(name: "image_write", arguments: value, clientID: client)
                XCTAssertTrue(owner.ok, "\(owner.payload)")
                XCTAssertEqual(try Self.decodedBMPWire(Data(contentsOf: outside), width: 2, height: 2), Self.controlPixels)
                try prior.write(to: outside)
                let context = try app.projectContexts.invocationContext(for: client)
                let deniedClient = ClientID("bmp-denied-client")
                _ = try app.projectContexts.bind(owner: ProjectBindingOwner(kind: .mcpClient, id: deniedClient.rawValue),
                    projectID: context.projectID, generation: context.projectGeneration,
                    authorizationScope: ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots,
                        allowedTools: ["fs_read", "fs_write"], networkAllowed: context.authorizationScope.networkAllowed,
                        maximumInlineOutputBytes: context.authorizationScope.maximumInlineOutputBytes))
                let denied = try app.tools.call(name: "image_write", arguments: value, clientID: deniedClient)
                XCTAssertFalse(denied.ok); XCTAssertEqual(denied.payload["code"] as? String, "tool_not_granted")
                XCTAssertEqual(try Data(contentsOf: outside), prior)
                _ = try app.projectContexts.beginReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                _ = try app.projectContexts.completeReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                let stale = try XCTUnwrap(try DocsToolPack().handle(name: "image_write", arguments: value,
                    context: context, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(stale.ok); XCTAssertEqual(stale.payload["code"] as? String, "image_encode_failed")
                XCTAssertEqual(try Data(contentsOf: outside), prior)
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
            }
        }.value
    }

    // Test-only observed top-down 32-bit V5/BITFIELDS subset. No ImageIO decoder.
    // Microsoft BITMAPFILEHEADER / BITMAPV5HEADER references define little-endian
    // fields, masks and sRGB/profile distinction; linked profiles are not followed:
    // https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-bitmapv5header
    private static func decodedBMPWire(_ data: Data, width: Int, height: Int) throws -> Data {
        guard (1...NativeRasterWriter.maximumDimension).contains(width),
              (1...NativeRasterWriter.maximumDimension).contains(height) else { throw FixtureError.malformed }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= NativeRasterWriter.maximumPixels else { throw FixtureError.malformed }
        let rawBytes = pixels * 4
        guard data.count >= 138, data.count <= NativeRasterWriter.maximumOutputBytes,
              data.count == 138 + rawBytes else { throw FixtureError.malformed }
        func short(_ at: Int) throws -> UInt16 {
            guard at >= 0, at <= data.count - 2 else { throw FixtureError.malformed }
            return UInt16(data[at]) | UInt16(data[at + 1]) << 8
        }
        func word(_ at: Int) throws -> UInt32 {
            guard at >= 0, at <= data.count - 4 else { throw FixtureError.malformed }
            var value: UInt32 = 0
            for shift in 0..<4 { value |= UInt32(data[at + shift]) << (shift * 8) }
            return value
        }
        guard data.prefix(2) == Data("BM".utf8), try word(2) == UInt32(data.count),
              try short(6) == 0, try short(8) == 0, try word(10) == 138, try word(14) == 124,
              try word(18) == UInt32(width), try word(22) == UInt32(bitPattern: -Int32(height)),
              try short(26) == 1, try short(28) == 32, try word(30) == 3,
              try word(34) == UInt32(rawBytes), try word(46) == 0, try word(50) == 0,
              try word(54) == 0x00ff0000, try word(58) == 0x0000ff00,
              try word(62) == 0x000000ff, try word(66) == 0xff000000,
              try word(70) == 0x73524742,
              try word(126) == 0, try word(130) == 0, try word(134) == 0 else { throw FixtureError.malformed }
        // DWORD-aligned rows are width*4 for this depth, and negative height
        // stores the first input row first. The strict masks choose RGBA bytes.
        var rgba = Data(capacity: rawBytes)
        for index in 0..<pixels {
            let pixel = try word(138 + index * 4)
            for shift in [16, 8, 0, 24] { rgba.append(UInt8(truncatingIfNeeded: pixel >> shift)) }
        }
        return rgba
    }

    func testWebPOnePixelProducesOneNativeReadableSRGBImage() async throws {
        try await Task.detached(priority: .utility) {
            let encoded = try NativeRasterWriter.encode(width: 1, height: 1,
                content: "/wAA/w==", format: "webp")
            guard encoded.count >= 20 else { throw FixtureError.malformed }
            XCTAssertEqual(encoded.prefix(4), Data("RIFF".utf8))
            XCTAssertEqual(encoded.subdata(in: 8..<12), Data("WEBP".utf8))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "org.webmproject.webp")
            XCTAssertEqual(CGImageSourceGetCount(source), 1)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 1); XCTAssertEqual(image.height, 1)
            XCTAssertEqual(try XCTUnwrap(image.colorSpace?.copyICCData()) as Data,
                try XCTUnwrap(NSColorSpace.sRGB.iccProfileData))
            XCTAssertLessThanOrEqual(encoded.count, NativeRasterWriter.maximumOutputBytes)
        }.value
    }

    func testWebPExactWireRGBAAndNativeRenderingMatchPNGReference() async throws {
        try await Task.detached(priority: .utility) {
            let fixtures: [(Int, Int, Data)] = [
                (1, 1, Data([255, 0, 0, 255])), (1, 1, Data([17, 83, 191, 0])),
                (1, 1, Data([211, 37, 109, 128])),
                (3, 2, Data([255, 0, 0, 255, 17, 34, 51, 0, 7, 83, 191, 1,
                             31, 157, 63, 64, 211, 37, 109, 128, 19, 71, 233, 254]))]
            for (width, height, pixels) in fixtures {
                let encoded = try NativeRasterWriter.encode(width: width, height: height,
                    content: pixels.base64EncodedString(), format: "webp")
                XCTAssertEqual(try Self.decodedWebPWire(encoded, width: width, height: height), pixels)
                let reference = try NativeRasterWriter.encode(width: width, height: height,
                    content: pixels.base64EncodedString())
                // Native premultiplied rendering is compared to the PNG consumer,
                // separately from wire-exact hidden RGB and straight-alpha checks.
                XCTAssertEqual(try Self.renderedRaster(encoded, width: width, height: height, type: "org.webmproject.webp"),
                    try Self.renderedRaster(reference, width: width, height: height, type: "public.png"))
            }
        }.value
    }

    func testWebPAllAlphaValuesDimensionEdgesAndMaximumNoisyWirePixels() async throws {
        try await Task.detached(priority: .utility) {
            for (width, height) in [(256, 1), (1024, 1), (1, 1024), (17, 33), (1024, 256)] {
                var state: UInt32 = 0x13579BDF
                var pixels = Data(capacity: width * height * 4)
                for index in 0..<(width * height) {
                    for _ in 0..<3 {
                        state = state &* 1_664_525 &+ 1_013_904_223
                        pixels.append(UInt8(truncatingIfNeeded: state >> 24))
                    }
                    pixels.append(UInt8(truncatingIfNeeded: index))
                }
                let encoded = try NativeRasterWriter.encode(width: width, height: height,
                    content: pixels.base64EncodedString(), format: "webp")
                XCTAssertEqual(try Self.decodedWebPWire(encoded, width: width, height: height), pixels)
                XCTAssertLessThanOrEqual(encoded.count, NativeRasterWriter.maximumOutputBytes)
                if width * height == NativeRasterWriter.maximumPixels {
                    XCTAssertEqual(pixels.count, NativeRasterWriter.maximumInputBytes)
                    XCTAssertEqual(pixels.base64EncodedString().utf8.count, NativeRasterWriter.maximumBase64Bytes)
                }
            }
        }.value
    }

    func testWebPWorkerCancellationStrictInputsAndExactOutputPreflight() async throws {
        let content = Self.controlPixels.base64EncodedString()
        try await MainActor.run {
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, format: "webp")) {
                XCTAssertEqual($0 as? NativeRasterError, .workerRequired)
            }
        }
        try await Task.detached(priority: .utility) {
            let cancelled = ToolCallCancellation(timeoutSeconds: 10); cancelled.cancel()
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                format: "webp", cancellation: cancelled)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                format: "webp", cancellation: ToolCallCancellation(timeoutSeconds: 0))) { XCTAssertTrue($0 is ToolCallDeadlineExceeded) }
            let encoded = try NativeRasterWriter.encode(width: 2, height: 2, content: content, format: "webp")
            XCTAssertEqual(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                format: "webp", outputByteLimit: encoded.count), encoded)
            for limit in [0, 1, encoded.count - 1, NativeRasterWriter.maximumOutputBytes + 1] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                    format: "webp", outputByteLimit: limit)) { XCTAssertEqual($0 as? NativeRasterError, .outputTooLarge) }
            }
            for (width, height) in [(0, 1), (1, 1025), (512, 513), (Int.max, Int.max)] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: width, height: height, content: "", format: "webp")) {
                    XCTAssertEqual($0 as? NativeRasterError, .invalidDimensions)
                }
            }
            for invalid in ["AAAAAB==", "/wAA/w==\n", "", "!!!!AA=="] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 1, height: 1, content: invalid, format: "webp")) {
                    XCTAssertEqual($0 as? NativeRasterError, .invalidContent)
                }
            }
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                pixelFormat: "bgra8", format: "webp")) { XCTAssertEqual($0 as? NativeRasterError, .invalidPixelFormat) }
            for invalid in ["WEBP", "avif"] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, format: invalid)) {
                    XCTAssertEqual($0 as? NativeRasterError, .invalidFormat)
                }
            }
        }.value
    }

    func testWebPSubsetInspectorRejectsMalformedContainersAndWrongDimensions() async throws {
        try await Task.detached(priority: .utility) {
            let encoded = try NativeRasterWriter.encode(width: 2, height: 2,
                content: Self.controlPixels.base64EncodedString(), format: "webp")
            var invalid = [Data(encoded.dropLast()), encoded + Data([0])]
            for (offset, mask) in [(0, UInt8(1)), (4, 1), (20, 1), (24, 0x80), (25, 1), (encoded.count - 1, 0x80)] {
                var changed = encoded; changed[offset] ^= mask; invalid.append(changed)
            }
            for bytes in invalid { XCTAssertThrowsError(try Self.decodedWebPWire(bytes, width: 2, height: 2)) }
            XCTAssertThrowsError(try Self.decodedWebPWire(encoded, width: 1, height: 2))
        }.value
    }

    func testWebPToolMetadataReadbackAndWriteProtections() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let prior = Data("WebP destination sentinel".utf8)
                let existing = project.appendingPathComponent("replace.webp")
                try prior.write(to: existing); XCTAssertEqual(Darwin.chmod(existing.path, 0o600), 0)
                func arguments(_ file: URL) -> [String: Any] {
                    ["path": file.path, "width": 2, "height": 2, "content": Self.controlPixels.base64EncodedString(), "format": "webp"]
                }
                for file in [existing, project.appendingPathComponent("fresh.webp"), project.appendingPathComponent("uppercase.WEBP")] {
                    let result = try app.tools.call(name: "image_write", arguments: arguments(file), clientID: client)
                    XCTAssertTrue(result.ok, "\(result.payload)")
                    let bytes = try Data(contentsOf: file)
                    XCTAssertEqual(try Self.decodedWebPWire(bytes, width: 2, height: 2), Self.controlPixels)
                    XCTAssertEqual(result.payload["format"] as? String, "webp")
                    XCTAssertEqual(result.payload["engine"] as? String, "swift-webp-vp8l")
                    XCTAssertEqual(result.payload["path"] as? String, file.path)
                    XCTAssertEqual(result.payload["width"] as? Int, 2); XCTAssertEqual(result.payload["height"] as? Int, 2)
                    XCTAssertEqual(result.payload["pixel_format"] as? String, "rgba8")
                    XCTAssertEqual(result.payload["color_space"] as? String, "srgb")
                    XCTAssertEqual(result.payload["pixel_bytes"] as? Int, 16)
                    XCTAssertEqual(result.payload["pixel_contract"] as? String, NativeRasterWriter.pixelContract)
                    XCTAssertEqual(result.payload["output_contract"] as? String, "webp-lossless-rgba8-srgb-v1")
                    XCTAssertEqual(result.payload["bytes_written"] as? Int, bytes.count)
                    XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                    XCTAssertNil(result.payload["content"])
                    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue,
                        file == existing ? 0o600 : 0o644)
                    let read = try app.tools.call(name: "fs_read", arguments: ["path": file.path, "encoding": "base64", "maximum_bytes": 32768], clientID: client)
                    XCTAssertTrue(read.ok, "\(read.payload)")
                    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(read.payload["content"] as? String)), bytes)
                }
                for (name, format) in [("protected.png", "tiff"), ("protected.tiff", "webp"), ("protected.gif", "webp"), ("protected.jpg", "webp"), ("protected.webp", "png"),
                                       ("protected.webp", "absent"), ("no-extension", "webp")] {
                    let file = project.appendingPathComponent(name); try prior.write(to: file)
                    var value = arguments(file)
                    if format == "absent" { value.removeValue(forKey: "format") } else { value["format"] = format }
                    let result = try app.tools.call(name: "image_write", arguments: value, clientID: client)
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, "invalid_path")
                    XCTAssertEqual(try Data(contentsOf: file), prior)
                }
                let sentinel = project.appendingPathComponent("cancel.webp"); try prior.write(to: sentinel)
                for control in [ToolCallCancellation(timeoutSeconds: 10), ToolCallCancellation(timeoutSeconds: 0)] {
                    if !control.isDeadlineExceeded { control.cancel() }
                    XCTAssertThrowsError(try DocsToolPack().handle(name: "image_write", arguments: arguments(sentinel),
                        context: nil, clientID: client, app: app, cancellation: control)) {
                        XCTAssertTrue($0 is CancellationError || $0 is ToolCallDeadlineExceeded)
                    }
                }
                XCTAssertEqual(try Data(contentsOf: sentinel), prior)
                let outside = root.appendingPathComponent("webp-outside", isDirectory: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let outsideFile = outside.appendingPathComponent("target.webp"); try prior.write(to: outsideFile)
                let link = project.appendingPathComponent("alias", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                let symlink = try XCTUnwrap(try DocsToolPack().handle(name: "image_write",
                    arguments: arguments(link.appendingPathComponent("target.webp")), context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(symlink.ok); XCTAssertEqual(symlink.payload["code"] as? String, "image_write_failed")
                XCTAssertEqual(try Data(contentsOf: outsideFile), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["target.webp"])
                let directory = project.appendingPathComponent("directory.webp", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try prior.write(to: directory.appendingPathComponent("keep"))
                let rename = try XCTUnwrap(try DocsToolPack().handle(name: "image_write", arguments: arguments(directory),
                    context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(rename.ok); XCTAssertEqual(rename.payload["code"] as? String, "image_write_failed")
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), prior)
                XCTAssertTrue(app.audit.flushAttempts(timeout: 2))
                let event = try XCTUnwrap(app.audit.recent(limit: 32).first(where: { $0.tool == "image_write" && $0.status == "ok" }))
                XCTAssertFalse(event.argsJSON?.contains(Self.controlPixels.base64EncodedString()) == true)
                XCTAssertTrue(event.argsJSON?.contains("redacted") == true)
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: project.path).contains { $0.hasPrefix(".forge-") })
            }
        }.value
    }

    func testWebPStaleProjectContextAndOwnGrantPreventWrites() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let file = project.appendingPathComponent("protected.webp")
                let prior = Data("protected WebP".utf8); try prior.write(to: file)
                let value: [String: Any] = ["path": file.path, "width": 2, "height": 2,
                    "content": Self.controlPixels.base64EncodedString(), "format": "webp"]
                let context = try app.projectContexts.invocationContext(for: client)
                let deniedClient = ClientID("webp-denied-client")
                _ = try app.projectContexts.bind(owner: ProjectBindingOwner(kind: .mcpClient, id: deniedClient.rawValue),
                    projectID: context.projectID, generation: context.projectGeneration,
                    authorizationScope: ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots,
                        allowedTools: ["fs_read"], networkAllowed: context.authorizationScope.networkAllowed,
                        maximumInlineOutputBytes: context.authorizationScope.maximumInlineOutputBytes))
                let denied = try app.tools.call(name: "image_write", arguments: value, clientID: deniedClient)
                XCTAssertFalse(denied.ok); XCTAssertEqual(denied.payload["code"] as? String, "tool_not_granted")
                _ = try app.projectContexts.beginReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                _ = try app.projectContexts.completeReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                let stale = try XCTUnwrap(try DocsToolPack().handle(name: "image_write", arguments: value,
                    context: context, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(stale.ok); XCTAssertEqual(stale.payload["code"] as? String, "image_encode_failed")
                XCTAssertEqual(try Data(contentsOf: file), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), ["protected.webp"])
            }
        }.value
    }


    func testGIFOnePixelProducesOneNativeReadableGIF89aImage() async throws {
        try await Task.detached(priority: .utility) {
            let encoded = try NativeRasterWriter.encode(width: 1, height: 1,
                content: "/wAA/w==", format: "gif")
            try Self.inspectGIF(encoded, width: 1, height: 1)
            XCTAssertEqual(encoded.prefix(6), Data("GIF89a".utf8))
            XCTAssertLessThanOrEqual(encoded.count, NativeRasterWriter.maximumOutputBytes)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.compuserve.gif")
            XCTAssertEqual(CGImageSourceGetCount(source), 1)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 1); XCTAssertEqual(image.height, 1)
        }.value
    }

    func testGIFHeaderNormalizationPreservesNativeBodyAndConsumerPixels() async throws {
        try await Task.detached(priority: .utility) {
            let pixels = Self.binaryPixels
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
            let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 8, space: space,
                bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            // A separately owned native CFData destination supplies the body oracle.
            let buffer = try XCTUnwrap(CFDataCreateMutable(nil, 0))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(buffer, "com.compuserve.gif" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let original = buffer as Data
            XCTAssertTrue([Data("GIF87a".utf8), Data("GIF89a".utf8)].contains(Data(original.prefix(6))))
            let encoded = try NativeRasterWriter.encode(width: 2, height: 2,
                content: pixels.base64EncodedString(), format: "gif")
            XCTAssertEqual(encoded.prefix(6), Data("GIF89a".utf8))
            XCTAssertEqual(encoded.count, original.count)
            XCTAssertEqual(encoded.dropFirst(6), original.dropFirst(6))
            let originalSource = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
            XCTAssertEqual(CGImageSourceGetCount(originalSource), 1)
            let originalImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(originalSource, 0, nil))
            let normalizedSource = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
            let normalizedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(normalizedSource, 0, nil))
            XCTAssertEqual(originalImage.width, normalizedImage.width)
            XCTAssertEqual(originalImage.height, normalizedImage.height)
            XCTAssertEqual(try XCTUnwrap(originalImage.dataProvider?.data) as Data,
                try XCTUnwrap(normalizedImage.dataProvider?.data) as Data)
            _ = try Self.decodedGIF(encoded, width: 2, height: 2)
        }.value
    }

    func testGIFNativePaletteAndBinaryAlphaPreserveRowsAndTransparency() async throws {
        try await Task.detached(priority: .utility) {
            var fixtures: [(Int, Int, Data, Bool)] = [
                (2, 2, Self.opaquePixels, true), (2, 2, Self.binaryPixels, true),
                (1, 1, Data([29, 61, 127, 0]), true),
                (2, 1, Data([83, 137, 19, 0, 83, 137, 19, 255]), true),
                (16, 16, Data(repeating: 0, count: 16 * 16 * 4), true)]
            for count in [255, 256] {
                var pixels = Data()
                for i in 0..<count { pixels.append(contentsOf: [UInt8(i), 0, UInt8(truncatingIfNeeded: i * 67), 255]) }
                pixels.append(contentsOf: [29, 61, 127, 0])
                fixtures.append((count + 1, 1, pixels, false))
            }
            for (width, height, pixels, exactVisibleRGB) in fixtures {
                let encoded = try NativeRasterWriter.encode(width: width, height: height,
                    content: pixels.base64EncodedString(), format: "gif")
                let decoded = try Self.decodedGIF(encoded, width: width, height: height)
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    XCTAssertEqual(decoded[offset + 3], pixels[offset + 3])
                    if pixels[offset + 3] == 0 {
                        XCTAssertEqual(decoded.subdata(in: offset..<(offset + 4)), Data(repeating: 0, count: 4))
                    } else if exactVisibleRGB {
                        XCTAssertEqual(decoded.subdata(in: offset..<(offset + 4)), pixels.subdata(in: offset..<(offset + 4)))
                    }
                }
            }
        }.value
    }

    func testGIFDimensionEdgesAndMaximumNoisyInputProduceOneBoundedImage() async throws {
        try await Task.detached(priority: .utility) {
            for (width, height) in [(1024, 1), (1, 1024), (17, 33), (1024, 256)] {
                var state: UInt32 = 0x13579BDF
                var pixels = Data(capacity: width * height * 4)
                for _ in 0..<(width * height) {
                    for _ in 0..<3 {
                        state = state &* 1_664_525 &+ 1_013_904_223
                        pixels.append(UInt8(truncatingIfNeeded: state >> 24))
                    }
                    pixels.append(255)
                }
                let encoded = try NativeRasterWriter.encode(width: width, height: height,
                    content: pixels.base64EncodedString(), format: "gif")
                let decoded = try Self.decodedGIF(encoded, width: width, height: height)
                XCTAssertEqual(decoded.count, pixels.count)
                XCTAssertTrue(stride(from: 3, to: decoded.count, by: 4).allSatisfy { decoded[$0] == 255 })
                XCTAssertLessThanOrEqual(encoded.count, NativeRasterWriter.maximumOutputBytes)
                if width * height == NativeRasterWriter.maximumPixels {
                    XCTAssertEqual(pixels.count, NativeRasterWriter.maximumInputBytes)
                    XCTAssertEqual(pixels.base64EncodedString().utf8.count, NativeRasterWriter.maximumBase64Bytes)
                }
            }
        }.value
    }

    func testGIFRejectsPartialAlphaAtFirstMiddleAndLastPixels() async throws {
        try await Task.detached(priority: .utility) {
            for alpha in [UInt8(1), 127, 254] {
                for offset in [3, 7, 15] {
                    var pixels = Self.binaryPixels; pixels[offset] = alpha
                    XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2,
                        content: pixels.base64EncodedString(), format: "gif")) {
                        XCTAssertEqual($0 as? NativeRasterError, .invalidGIFAlpha)
                        XCTAssertEqual(($0 as? NativeRasterError)?.code, "invalid_image_alpha")
                        XCTAssertEqual($0.localizedDescription,
                            "GIF requires every RGBA8 alpha byte to be 0 or 255; use png or tiff for partial transparency")
                    }
                }
            }
            var maximum = Data(repeating: 255, count: NativeRasterWriter.maximumInputBytes)
            maximum[maximum.count - 1] = 254
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 1024, height: 256,
                content: maximum.base64EncodedString(), format: "gif")) {
                XCTAssertEqual($0 as? NativeRasterError, .invalidGIFAlpha)
            }
        }.value
    }

    func testGIFWorkerCancellationAndStrictBoundsRemainEnforced() async throws {
        let content = Self.binaryPixels.base64EncodedString()
        try await MainActor.run {
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, format: "gif")) {
                XCTAssertEqual($0 as? NativeRasterError, .workerRequired)
            }
        }
        try await Task.detached(priority: .utility) {
            let cancelled = ToolCallCancellation(timeoutSeconds: 10); cancelled.cancel()
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                format: "gif", cancellation: cancelled)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                format: "gif", cancellation: ToolCallCancellation(timeoutSeconds: 0))) {
                XCTAssertTrue($0 is ToolCallDeadlineExceeded)
            }
            for limit in [0, 1, NativeRasterWriter.maximumOutputBytes + 1] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                    format: "gif", outputByteLimit: limit)) { XCTAssertEqual($0 as? NativeRasterError, .outputTooLarge) }
            }
            for (width, height) in [(0, 1), (1, 1025), (512, 513), (Int.max, Int.max)] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: width, height: height, content: "", format: "gif")) {
                    XCTAssertEqual($0 as? NativeRasterError, .invalidDimensions)
                }
            }
            for invalid in ["AAAAAB==", "/wAA/w==\n", "", "!!!!AA=="] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 1, height: 1, content: invalid, format: "gif")) {
                    XCTAssertEqual($0 as? NativeRasterError, .invalidContent)
                }
            }
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                pixelFormat: "bgra8", format: "gif")) { XCTAssertEqual($0 as? NativeRasterError, .invalidPixelFormat) }
            for invalid in ["GIF", "avif"] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, format: invalid)) {
                    XCTAssertEqual($0 as? NativeRasterError, .invalidFormat)
                }
            }
        }.value
    }

    func testGIFToolMetadataReadbackAndWriteProtections() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let prior = Data("GIF destination sentinel".utf8)
                let existing = project.appendingPathComponent("replace.gif")
                try prior.write(to: existing); XCTAssertEqual(Darwin.chmod(existing.path, 0o600), 0)
                func arguments(_ file: URL) -> [String: Any] {
                    ["path": file.path, "width": 2, "height": 2, "content": Self.binaryPixels.base64EncodedString(), "format": "gif"]
                }
                for file in [existing, project.appendingPathComponent("fresh.gif"), project.appendingPathComponent("uppercase.GIF")] {
                    let result = try app.tools.call(name: "image_write", arguments: arguments(file), clientID: client)
                    XCTAssertTrue(result.ok, "\(result.payload)")
                    let bytes = try Data(contentsOf: file)
                    _ = try Self.inspectGIF(bytes, width: 2, height: 2)
                    _ = try Self.decodedGIF(bytes, width: 2, height: 2)
                    XCTAssertEqual(result.payload["format"] as? String, "gif")
                    XCTAssertEqual(result.payload["engine"] as? String, "apple-imageio")
                    XCTAssertEqual(result.payload["path"] as? String, file.path)
                    XCTAssertEqual(result.payload["width"] as? Int, 2); XCTAssertEqual(result.payload["height"] as? Int, 2)
                    XCTAssertEqual(result.payload["pixel_format"] as? String, "rgba8")
                    XCTAssertEqual(result.payload["color_space"] as? String, "srgb")
                    XCTAssertEqual(result.payload["pixel_bytes"] as? Int, 16)
                    XCTAssertEqual(result.payload["pixel_contract"] as? String, NativeRasterWriter.pixelContract)
                    XCTAssertEqual(result.payload["output_contract"] as? String, "gif-binary-alpha-palettized-srgb-v1")
                    XCTAssertEqual(result.payload["bytes_written"] as? Int, bytes.count)
                    XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                    XCTAssertNil(result.payload["content"])
                    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue,
                        file == existing ? 0o600 : 0o644)
                    let read = try app.tools.call(name: "fs_read", arguments: ["path": file.path, "encoding": "base64", "maximum_bytes": 32768], clientID: client)
                    XCTAssertTrue(read.ok, "\(read.payload)")
                    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(read.payload["content"] as? String)), bytes)
                }
                for (name, format) in [("protected.png", "tiff"), ("protected.tiff", "gif"), ("protected.gif", "png"),
                                       ("protected.gif", "absent"), ("no-extension", "gif")] {
                    let file = project.appendingPathComponent(name); try prior.write(to: file)
                    var value = arguments(file)
                    if format == "absent" { value.removeValue(forKey: "format") } else { value["format"] = format }
                    let result = try app.tools.call(name: "image_write", arguments: value, clientID: client)
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, "invalid_path")
                    XCTAssertEqual(try Data(contentsOf: file), prior)
                }
                let sentinel = project.appendingPathComponent("alpha.gif"); try prior.write(to: sentinel)
                var value = arguments(sentinel); value["content"] = Self.controlPixels.base64EncodedString()
                let alpha = try app.tools.call(name: "image_write", arguments: value, clientID: client)
                XCTAssertFalse(alpha.ok); XCTAssertEqual(alpha.payload["code"] as? String, "invalid_image_alpha")
                XCTAssertEqual(try Data(contentsOf: sentinel), prior)
                for control in [ToolCallCancellation(timeoutSeconds: 10), ToolCallCancellation(timeoutSeconds: 0)] {
                    if !control.isDeadlineExceeded { control.cancel() }
                    XCTAssertThrowsError(try DocsToolPack().handle(name: "image_write", arguments: arguments(sentinel),
                        context: nil, clientID: client, app: app, cancellation: control)) {
                        XCTAssertTrue($0 is CancellationError || $0 is ToolCallDeadlineExceeded)
                    }
                }
                XCTAssertEqual(try Data(contentsOf: sentinel), prior)
                let outside = root.appendingPathComponent("gif-outside", isDirectory: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let outsideFile = outside.appendingPathComponent("target.gif"); try prior.write(to: outsideFile)
                let link = project.appendingPathComponent("alias", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                let symlink = try XCTUnwrap(try DocsToolPack().handle(name: "image_write",
                    arguments: arguments(link.appendingPathComponent("target.gif")), context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(symlink.ok); XCTAssertEqual(symlink.payload["code"] as? String, "image_write_failed")
                XCTAssertEqual(try Data(contentsOf: outsideFile), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["target.gif"])
                let directory = project.appendingPathComponent("directory.gif", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try prior.write(to: directory.appendingPathComponent("keep"))
                let rename = try XCTUnwrap(try DocsToolPack().handle(name: "image_write", arguments: arguments(directory),
                    context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(rename.ok); XCTAssertEqual(rename.payload["code"] as? String, "image_write_failed")
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), prior)
                XCTAssertTrue(app.audit.flushAttempts(timeout: 2))
                let event = try XCTUnwrap(app.audit.recent(limit: 32).first(where: { $0.tool == "image_write" && $0.status == "ok" }))
                XCTAssertFalse(event.argsJSON?.contains(Self.binaryPixels.base64EncodedString()) == true)
                XCTAssertTrue(event.argsJSON?.contains("redacted") == true)
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: project.path).contains { $0.hasPrefix(".forge-") })
            }
        }.value
    }

    func testGIFStaleProjectContextAndOwnGrantPreventWrites() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let file = project.appendingPathComponent("protected.gif")
                let prior = Data("protected GIF".utf8); try prior.write(to: file)
                let value: [String: Any] = ["path": file.path, "width": 2, "height": 2,
                    "content": Self.binaryPixels.base64EncodedString(), "format": "gif"]
                let context = try app.projectContexts.invocationContext(for: client)
                let deniedClient = ClientID("gif-denied-client")
                _ = try app.projectContexts.bind(owner: ProjectBindingOwner(kind: .mcpClient, id: deniedClient.rawValue),
                    projectID: context.projectID, generation: context.projectGeneration,
                    authorizationScope: ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots,
                        allowedTools: ["fs_read"], networkAllowed: context.authorizationScope.networkAllowed,
                        maximumInlineOutputBytes: context.authorizationScope.maximumInlineOutputBytes))
                let denied = try app.tools.call(name: "image_write", arguments: value, clientID: deniedClient)
                XCTAssertFalse(denied.ok); XCTAssertEqual(denied.payload["code"] as? String, "tool_not_granted")
                _ = try app.projectContexts.beginReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                _ = try app.projectContexts.completeReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                let stale = try XCTUnwrap(try DocsToolPack().handle(name: "image_write", arguments: value,
                    context: context, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(stale.ok); XCTAssertEqual(stale.payload["code"] as? String, "image_encode_failed")
                XCTAssertEqual(try Data(contentsOf: file), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), ["protected.gif"])
            }
        }.value
    }

    func testJPEGOpaquePixelsPreserveNativeSRGBColorAndRowOrder() async throws {
        try await Task.detached(priority: .utility) {
            let colors: [[UInt8]] = [[245, 37, 11, 255], [19, 213, 71, 255],
                                    [23, 61, 237, 255], [191, 113, 43, 255]]
            var pixels = Data(capacity: 128 * 128 * 4)
            for y in 0..<128 { for x in 0..<128 {
                pixels.append(contentsOf: colors[(y < 64 ? 0 : 2) + (x < 64 ? 0 : 1)])
            } }
            let encoded = try NativeRasterWriter.encode(width: 128, height: 128,
                content: pixels.base64EncodedString(), format: "jpeg")
            let decoded = try Self.decodedJPEG(encoded, width: 128, height: 128)
            // The pre-edit native probe measured at most one level of error in
            // these flat interiors. Two levels still detect row/channel swaps.
            for y in (16..<48).map({ $0 }) + (80..<112).map({ $0 }) {
                for x in (16..<48).map({ $0 }) + (80..<112).map({ $0 }) {
                    let offset = (y * 128 + x) * 4
                    for channel in 0..<3 {
                        XCTAssertLessThanOrEqual(abs(Int(decoded[offset + channel]) - Int(pixels[offset + channel])), 2)
                    }
                    XCTAssertEqual(decoded[offset + 3], 255)
                }
            }
        }.value
    }

    func testJPEGDimensionEdgesAndMaximumNoisyInputProduceOneBoundedImage() async throws {
        try await Task.detached(priority: .utility) {
            for (width, height) in [(1, 1), (1024, 1), (1, 1024), (1024, 256)] {
                var state: UInt32 = 0x76543210
                var pixels = Data(capacity: width * height * 4)
                for _ in 0..<(width * height) {
                    for _ in 0..<3 {
                        state = state &* 1_664_525 &+ 1_013_904_223
                        pixels.append(UInt8(truncatingIfNeeded: state >> 24))
                    }
                    pixels.append(255)
                }
                let encoded = try NativeRasterWriter.encode(width: width, height: height,
                    content: pixels.base64EncodedString(), format: "jpeg")
                _ = try Self.inspectJPEG(encoded, width: width, height: height)
                let decoded = try Self.decodedJPEG(encoded, width: width, height: height)
                XCTAssertEqual(decoded.count, pixels.count)
                XCTAssertTrue(stride(from: 3, to: decoded.count, by: 4).allSatisfy { decoded[$0] == 255 })
                if width * height == NativeRasterWriter.maximumPixels {
                    XCTAssertEqual(pixels.count, NativeRasterWriter.maximumInputBytes)
                    XCTAssertEqual(pixels.base64EncodedString().utf8.count, NativeRasterWriter.maximumBase64Bytes)
                }
            }
        }.value
    }

    func testJPEGRejectsNonopaqueAlphaAtFirstMiddleAndLastPixels() async throws {
        try await Task.detached(priority: .utility) {
            for alpha in [UInt8(0), 1, 254] {
                for offset in [3, 7, 15] {
                    var pixels = Self.opaquePixels; pixels[offset] = alpha
                    XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2,
                        content: pixels.base64EncodedString(), format: "jpeg")) {
                        XCTAssertEqual($0 as? NativeRasterError, .invalidAlpha)
                        XCTAssertEqual(($0 as? NativeRasterError)?.code, "invalid_image_alpha")
                    }
                }
            }
            var maximum = Data(repeating: 255, count: NativeRasterWriter.maximumInputBytes)
            maximum[maximum.count - 1] = 254
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 1024, height: 256,
                content: maximum.base64EncodedString(), format: "jpeg")) {
                XCTAssertEqual($0 as? NativeRasterError, .invalidAlpha)
            }
        }.value
    }

    func testJPEGWorkerCancellationAndStrictBoundsRemainEnforced() async throws {
        let content = Self.opaquePixels.base64EncodedString()
        try await MainActor.run {
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, format: "jpeg")) {
                XCTAssertEqual($0 as? NativeRasterError, .workerRequired)
            }
        }
        try await Task.detached(priority: .utility) {
            let cancelled = ToolCallCancellation(timeoutSeconds: 10); cancelled.cancel()
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                format: "jpeg", cancellation: cancelled)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                format: "jpeg", cancellation: ToolCallCancellation(timeoutSeconds: 0))) {
                XCTAssertTrue($0 is ToolCallDeadlineExceeded)
            }
            for limit in [0, 1, NativeRasterWriter.maximumOutputBytes + 1] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                    format: "jpeg", outputByteLimit: limit)) { XCTAssertEqual($0 as? NativeRasterError, .outputTooLarge) }
            }
            for (width, height) in [(0, 1), (1, 1025), (512, 513), (Int.max, Int.max)] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: width, height: height, content: "", format: "jpeg")) {
                    XCTAssertEqual($0 as? NativeRasterError, .invalidDimensions)
                }
            }
            for invalid in ["AAAAAB==", "/wAA/w==\n", "", "!!!!AA=="] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 1, height: 1, content: invalid, format: "jpeg")) {
                    XCTAssertEqual($0 as? NativeRasterError, .invalidContent)
                }
            }
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                pixelFormat: "bgra8", format: "jpeg")) { XCTAssertEqual($0 as? NativeRasterError, .invalidPixelFormat) }
            for invalid in ["jpg", "JPEG", "avif"] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, format: invalid)) {
                    XCTAssertEqual($0 as? NativeRasterError, .invalidFormat)
                }
            }
        }.value
    }

    func testJPEGToolAliasesMetadataReadbackAndWriteProtections() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let prior = Data("JPEG destination sentinel".utf8)
                let existing = project.appendingPathComponent("replace.jpeg")
                try prior.write(to: existing); XCTAssertEqual(Darwin.chmod(existing.path, 0o600), 0)
                func arguments(_ file: URL) -> [String: Any] {
                    ["path": file.path, "width": 2, "height": 2, "content": Self.opaquePixels.base64EncodedString(), "format": "jpeg"]
                }
                for file in [existing, project.appendingPathComponent("fresh.jpg"), project.appendingPathComponent("uppercase.JPEG")] {
                    let result = try app.tools.call(name: "image_write", arguments: arguments(file), clientID: client)
                    XCTAssertTrue(result.ok, "\(result.payload)")
                    let bytes = try Data(contentsOf: file)
                    _ = try Self.inspectJPEG(bytes, width: 2, height: 2)
                    _ = try Self.decodedJPEG(bytes, width: 2, height: 2)
                    XCTAssertEqual(result.payload["format"] as? String, "jpeg")
                    XCTAssertEqual(result.payload["engine"] as? String, "apple-imageio")
                    XCTAssertEqual(result.payload["path"] as? String, file.path)
                    XCTAssertEqual(result.payload["width"] as? Int, 2); XCTAssertEqual(result.payload["height"] as? Int, 2)
                    XCTAssertEqual(result.payload["pixel_format"] as? String, "rgba8")
                    XCTAssertEqual(result.payload["color_space"] as? String, "srgb")
                    XCTAssertEqual(result.payload["pixel_bytes"] as? Int, 16)
                    XCTAssertEqual(result.payload["pixel_contract"] as? String, NativeRasterWriter.pixelContract)
                    XCTAssertEqual(result.payload["output_contract"] as? String, "jpeg-opaque-lossy-srgb-v1")
                    XCTAssertEqual(result.payload["bytes_written"] as? Int, bytes.count)
                    XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                    XCTAssertNil(result.payload["content"])
                    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue,
                        file == existing ? 0o600 : 0o644)
                    let read = try app.tools.call(name: "fs_read", arguments: ["path": file.path, "encoding": "base64", "maximum_bytes": 32768], clientID: client)
                    XCTAssertTrue(read.ok, "\(read.payload)")
                    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(read.payload["content"] as? String)), bytes)
                }
                for (name, format) in [("protected.png", "tiff"), ("protected.tiff", "jpeg"), ("protected.jpeg", "png"),
                                       ("protected.jpg", "absent"), ("no-extension", "jpeg")] {
                    let file = project.appendingPathComponent(name); try prior.write(to: file)
                    var value = arguments(file)
                    if format == "absent" { value.removeValue(forKey: "format") } else { value["format"] = format }
                    let result = try app.tools.call(name: "image_write", arguments: value, clientID: client)
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, "invalid_path")
                    XCTAssertEqual(try Data(contentsOf: file), prior)
                }
                let sentinel = project.appendingPathComponent("alpha.jpg"); try prior.write(to: sentinel)
                var value = arguments(sentinel); value["content"] = Self.controlPixels.base64EncodedString()
                let alpha = try app.tools.call(name: "image_write", arguments: value, clientID: client)
                XCTAssertFalse(alpha.ok); XCTAssertEqual(alpha.payload["code"] as? String, "invalid_image_alpha")
                XCTAssertEqual(try Data(contentsOf: sentinel), prior)
                for control in [ToolCallCancellation(timeoutSeconds: 10), ToolCallCancellation(timeoutSeconds: 0)] {
                    if !control.isDeadlineExceeded { control.cancel() }
                    XCTAssertThrowsError(try DocsToolPack().handle(name: "image_write", arguments: arguments(sentinel),
                        context: nil, clientID: client, app: app, cancellation: control)) {
                        XCTAssertTrue($0 is CancellationError || $0 is ToolCallDeadlineExceeded)
                    }
                }
                XCTAssertEqual(try Data(contentsOf: sentinel), prior)
                let outside = root.appendingPathComponent("jpeg-outside", isDirectory: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let outsideFile = outside.appendingPathComponent("target.jpg"); try prior.write(to: outsideFile)
                let link = project.appendingPathComponent("alias", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                let symlink = try XCTUnwrap(try DocsToolPack().handle(name: "image_write",
                    arguments: arguments(link.appendingPathComponent("target.jpg")), context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(symlink.ok); XCTAssertEqual(symlink.payload["code"] as? String, "image_write_failed")
                XCTAssertEqual(try Data(contentsOf: outsideFile), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["target.jpg"])
                let directory = project.appendingPathComponent("directory.jpeg", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try prior.write(to: directory.appendingPathComponent("keep"))
                let rename = try XCTUnwrap(try DocsToolPack().handle(name: "image_write", arguments: arguments(directory),
                    context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(rename.ok); XCTAssertEqual(rename.payload["code"] as? String, "image_write_failed")
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), prior)
                XCTAssertTrue(app.audit.flushAttempts(timeout: 2))
                let event = try XCTUnwrap(app.audit.recent(limit: 32).first(where: { $0.tool == "image_write" && $0.status == "ok" }))
                XCTAssertFalse(event.argsJSON?.contains(Self.opaquePixels.base64EncodedString()) == true)
                XCTAssertTrue(event.argsJSON?.contains("redacted") == true)
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: project.path).contains { $0.hasPrefix(".forge-") })
            }
        }.value
    }

    func testJPEGStaleProjectContextAndOwnGrantPreventWrites() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let file = project.appendingPathComponent("protected.jpg")
                let prior = Data("protected JPEG".utf8); try prior.write(to: file)
                let value: [String: Any] = ["path": file.path, "width": 2, "height": 2,
                    "content": Self.opaquePixels.base64EncodedString(), "format": "jpeg"]
                let context = try app.projectContexts.invocationContext(for: client)
                let deniedClient = ClientID("jpeg-denied-client")
                _ = try app.projectContexts.bind(owner: ProjectBindingOwner(kind: .mcpClient, id: deniedClient.rawValue),
                    projectID: context.projectID, generation: context.projectGeneration,
                    authorizationScope: ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots,
                        allowedTools: ["fs_read"], networkAllowed: context.authorizationScope.networkAllowed,
                        maximumInlineOutputBytes: context.authorizationScope.maximumInlineOutputBytes))
                let denied = try app.tools.call(name: "image_write", arguments: value, clientID: deniedClient)
                XCTAssertFalse(denied.ok); XCTAssertEqual(denied.payload["code"] as? String, "tool_not_granted")
                _ = try app.projectContexts.beginReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                _ = try app.projectContexts.completeReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                let stale = try XCTUnwrap(try DocsToolPack().handle(name: "image_write", arguments: value,
                    context: context, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(stale.ok); XCTAssertEqual(stale.payload["code"] as? String, "image_encode_failed")
                XCTAssertEqual(try Data(contentsOf: file), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), ["protected.jpg"])
            }
        }.value
    }

    func testJPEGInspectorRejectsTruncationTrailingImagesAndWrongColorMetadata() async throws {
        try await Task.detached(priority: .utility) {
            let encoded = try NativeRasterWriter.encode(width: 2, height: 2,
                content: Self.opaquePixels.base64EncodedString(), format: "jpeg")
            let locations = try Self.inspectJPEG(encoded, width: 2, height: 2)
            var wrongColor = encoded; wrongColor[locations.color] = 0xFF; wrongColor[locations.color + 1] = 0xFF
            var wrongWidth = encoded; wrongWidth[locations.width] = 0; wrongWidth[locations.width + 1] = 3
            var wrongLength = encoded; wrongLength[4] = 0xFF; wrongLength[5] = 0xFF
            for invalid in [Data(encoded.dropLast(2)), Data(encoded.prefix(30)), encoded + encoded,
                            encoded + Data([0]), wrongColor, wrongWidth, wrongLength] {
                XCTAssertThrowsError(try Self.inspectJPEG(invalid, width: 2, height: 2))
            }
        }.value
    }

    func testTIFFAlphaAndDimensionEdgesPreserveStraightRGBA() async throws {
        try await Task.detached(priority: .utility) {
            let control = Self.controlPixels
            let tiff = try NativeRasterWriter.encode(width: 2, height: 2,
                content: control.base64EncodedString(), format: "tiff")
            XCTAssertEqual(try Self.decodedTIFFPixels(tiff, width: 2, height: 2), control)
            for (width, height) in [(1, 1), (1024, 1), (1, 1024), (257, 1020)] {
                let pixels = width == 1 && height == 1 ? Data([29, 61, 127, 0]) :
                    Data((0..<(width * height)).flatMap { index in
                        [UInt8(index % 251), UInt8((index * 3) % 251),
                         UInt8((index * 7) % 251), UInt8(index % 256)]
                    })
                let encoded = try NativeRasterWriter.encode(width: width, height: height,
                    content: pixels.base64EncodedString(), format: "tiff")
                XCTAssertEqual(try Self.decodedTIFFPixels(encoded, width: width, height: height), pixels)
            }
        }.value
    }

    func testMaximumNoisyPixelInputProducesOneBoundedExactTIFF() async throws {
        try await Task.detached(priority: .utility) {
            var state: UInt32 = 0x76543210
            var pixels = Data(capacity: NativeRasterWriter.maximumInputBytes)
            for _ in 0..<NativeRasterWriter.maximumPixels {
                for _ in 0..<4 {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    pixels.append(UInt8(truncatingIfNeeded: state >> 24))
                }
            }
            XCTAssertEqual(pixels.count, 1_048_576)
            let content = pixels.base64EncodedString()
            XCTAssertEqual(content.utf8.count, NativeRasterWriter.maximumBase64Bytes)
            let tiff = try NativeRasterWriter.encode(width: 1024, height: 256, content: content, format: "tiff")
            XCTAssertLessThanOrEqual(tiff.count, NativeRasterWriter.maximumOutputBytes)
            XCTAssertEqual(try Self.decodedTIFFPixels(tiff, width: 1024, height: 256), pixels)
        }.value
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
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, format: "avif")) {
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
                    ("format", [true, NSNull(), "avif", "PNG"] as [Any], "invalid_image_format")
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
                    XCTAssertNil(result.payload["output_contract"])
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

    func testTIFFNativeImageIOConsumerPreservesPixelsAndSRGBProfile() async throws {
        try await Task.detached(priority: .utility) {
            for (width, height) in [(2, 2), (257, 1020)] {
                let pixels = width == 2 ? Self.controlPixels : Data((0..<(width * height)).flatMap { index in
                    [UInt8(index % 251), UInt8((index * 3) % 251), UInt8((index * 7) % 251), UInt8(index % 256)]
                })
                let encoded = try NativeRasterWriter.encode(width: width, height: height,
                    content: pixels.base64EncodedString(), format: "tiff")
                let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
                XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.tiff")
                XCTAssertEqual(CGImageSourceGetCount(source), 1)
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, width); XCTAssertEqual(image.height, height)
                XCTAssertEqual(image.bitsPerComponent, 8); XCTAssertEqual(image.bitsPerPixel, 32)
                XCTAssertEqual(image.alphaInfo, .last)
                let space = try XCTUnwrap(image.colorSpace)
                let profile = try XCTUnwrap(space.copyICCData()) as Data
                XCTAssertEqual(profile, try XCTUnwrap(NSColorSpace.sRGB.iccProfileData))
                guard image.width == width, image.height == height, image.bitsPerPixel == 32,
                      image.alphaInfo == .last, image.bytesPerRow >= width * 4 else { throw FixtureError.malformed }
                let data = try XCTUnwrap(try XCTUnwrap(image.dataProvider).data) as Data
                guard data.count >= image.bytesPerRow * height else { throw FixtureError.malformed }
                var decoded = Data(capacity: pixels.count)
                for row in 0..<height {
                    let start = row * image.bytesPerRow
                    decoded.append(data.subdata(in: start..<(start + width * 4)))
                }
                XCTAssertEqual(decoded, pixels)
            }
        }.value
    }

    func testTIFFWorkerCancellationAndStrictBoundsRemainEnforced() async throws {
        let content = Self.controlPixels.base64EncodedString()
        try await MainActor.run {
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, format: "tiff")) {
                XCTAssertEqual($0 as? NativeRasterError, .workerRequired)
            }
        }
        try await Task.detached(priority: .utility) {
            let cancelled = ToolCallCancellation(timeoutSeconds: 10); cancelled.cancel()
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                format: "tiff", cancellation: cancelled)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                format: "tiff", cancellation: ToolCallCancellation(timeoutSeconds: 0))) {
                XCTAssertTrue($0 is ToolCallDeadlineExceeded)
            }
            for limit in [0, 1, NativeRasterWriter.maximumOutputBytes + 1] {
                XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content,
                    format: "tiff", outputByteLimit: limit)) { XCTAssertEqual($0 as? NativeRasterError, .outputTooLarge) }
            }
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 512, height: 513, content: "", format: "tiff")) {
                XCTAssertEqual($0 as? NativeRasterError, .invalidDimensions)
            }
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 1, height: 1, content: "AAAAAB==", format: "tiff")) {
                XCTAssertEqual($0 as? NativeRasterError, .invalidContent)
            }
            XCTAssertThrowsError(try NativeRasterWriter.encode(width: 2, height: 2, content: content, format: "TIFF")) {
                XCTAssertEqual($0 as? NativeRasterError, .invalidFormat)
            }
        }.value
    }

    func testTIFFToolAliasesMetadataReadbackAndWriteProtections() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let prior = Data("TIFF destination sentinel".utf8)
                let existing = project.appendingPathComponent("replace.tiff")
                try prior.write(to: existing); XCTAssertEqual(Darwin.chmod(existing.path, 0o600), 0)
                for file in [existing, project.appendingPathComponent("fresh.tif"), project.appendingPathComponent("uppercase.TIFF")] {
                    var arguments = Self.arguments(path: file.path); arguments["format"] = "tiff"
                    let result = try app.tools.call(name: "image_write", arguments: arguments, clientID: client)
                    XCTAssertTrue(result.ok, "\(result.payload)")
                    let bytes = try Data(contentsOf: file)
                    XCTAssertEqual(result.payload["format"] as? String, "tiff")
                    XCTAssertEqual(result.payload["engine"] as? String, "swift-tiff-rgba8")
                    XCTAssertNil(result.payload["output_contract"])
                    XCTAssertEqual(result.payload["path"] as? String, file.path)
                    XCTAssertEqual(result.payload["pixel_contract"] as? String, NativeRasterWriter.pixelContract)
                    XCTAssertEqual(result.payload["bytes_written"] as? Int, bytes.count)
                    XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                    XCTAssertNil(result.payload["content"])
                    XCTAssertEqual(try Self.decodedTIFFPixels(bytes, width: 2, height: 2), Self.controlPixels)
                    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue,
                        file == existing ? 0o600 : 0o644)
                    let read = try app.tools.call(name: "fs_read", arguments: ["path": file.path, "encoding": "base64", "maximum_bytes": 32768], clientID: client)
                    XCTAssertTrue(read.ok, "\(read.payload)")
                    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(read.payload["content"] as? String)), bytes)
                }
                let protectedPNG = project.appendingPathComponent("protected.png")
                let protectedTIFF = project.appendingPathComponent("protected.tiff")
                try prior.write(to: protectedPNG); try prior.write(to: protectedTIFF)
                for (file, format) in [(protectedPNG, "tiff"), (protectedTIFF, "png"), (protectedTIFF, "absent")] {
                    var arguments = Self.arguments(path: file.path)
                    if format != "absent" { arguments["format"] = format }
                    let result = try app.tools.call(name: "image_write", arguments: arguments, clientID: client)
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, "invalid_path")
                    XCTAssertEqual(try Data(contentsOf: file), prior)
                }
                let outside = root.appendingPathComponent("tiff-outside", isDirectory: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let outsideFile = outside.appendingPathComponent("target.tiff")
                try prior.write(to: outsideFile)
                let link = project.appendingPathComponent("alias", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                var arguments = Self.arguments(path: link.appendingPathComponent("target.tiff").path); arguments["format"] = "tiff"
                let symlink = try XCTUnwrap(try DocsToolPack().handle(name: "image_write", arguments: arguments,
                    context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(symlink.ok); XCTAssertEqual(symlink.payload["code"] as? String, "image_write_failed")
                XCTAssertEqual(try Data(contentsOf: outsideFile), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["target.tiff"])
                let directory = project.appendingPathComponent("directory.tiff", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try prior.write(to: directory.appendingPathComponent("keep"))
                arguments["path"] = directory.path
                let rename = try XCTUnwrap(try DocsToolPack().handle(name: "image_write", arguments: arguments,
                    context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(rename.ok); XCTAssertEqual(rename.payload["code"] as? String, "image_write_failed")
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), prior)
                let context = try app.projectContexts.invocationContext(for: client)
                let deniedClient = ClientID("tiff-denied-client")
                _ = try app.projectContexts.bind(owner: ProjectBindingOwner(kind: .mcpClient, id: deniedClient.rawValue), projectID: context.projectID,
                    generation: context.projectGeneration, authorizationScope: ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots,
                        allowedTools: ["fs_read"], networkAllowed: context.authorizationScope.networkAllowed,
                        maximumInlineOutputBytes: context.authorizationScope.maximumInlineOutputBytes))
                arguments["path"] = protectedTIFF.path
                let denied = try app.tools.call(name: "image_write", arguments: arguments, clientID: deniedClient)
                XCTAssertFalse(denied.ok); XCTAssertEqual(denied.payload["code"] as? String, "tool_not_granted")
                XCTAssertEqual(try Data(contentsOf: protectedTIFF), prior)
                XCTAssertTrue(app.audit.flushAttempts(timeout: 2))
                let event = try XCTUnwrap(app.audit.recent(limit: 32).first(where: { $0.tool == "image_write" && $0.status == "ok" }))
                XCTAssertFalse(event.argsJSON?.contains(Self.controlPixels.base64EncodedString()) == true)
                XCTAssertTrue(event.argsJSON?.contains("redacted") == true)
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: project.path).contains { $0.hasPrefix(".forge-") })
            }
        }.value
    }

    func testGIFInspectorRejectsTruncationTrailingImagesAndInvalidDescriptors() async throws {
        try await Task.detached(priority: .utility) {
            let encoded = try NativeRasterWriter.encode(width: 2, height: 2,
                content: Self.binaryPixels.base64EncodedString(), format: "gif")
            try Self.inspectGIF(encoded, width: 2, height: 2)
            for size in 0..<encoded.count {
                XCTAssertThrowsError(try Self.inspectGIF(Data(encoded.prefix(size)), width: 2, height: 2))
            }
            for bytes in [encoded + Data([0]), encoded + encoded] {
                XCTAssertThrowsError(try Self.inspectGIF(bytes, width: 2, height: 2))
            }
            var wrongVersion = encoded; wrongVersion.replaceSubrange(3..<6, with: "87a".utf8)
            XCTAssertThrowsError(try Self.inspectGIF(wrongVersion, width: 2, height: 2))
            var wrongDimensions = encoded; wrongDimensions[6] = 3
            XCTAssertThrowsError(try Self.inspectGIF(wrongDimensions, width: 2, height: 2))
            // The fixture has a global table followed by one eight-byte GCE.
            let tableBytes = 3 * (1 << (Int(encoded[10] & 7) + 1))
            let graphicControl = 13 + tableBytes
            XCTAssertEqual(encoded[graphicControl], 0x21)
            XCTAssertEqual(encoded[graphicControl + 1], 0xF9)
            var badControl = encoded; badControl[graphicControl + 2] = 3
            XCTAssertThrowsError(try Self.inspectGIF(badControl, width: 2, height: 2))
            let image = graphicControl + 8
            XCTAssertEqual(encoded[image], 0x2C)
            var outside = encoded; outside[image + 1] = 1
            XCTAssertThrowsError(try Self.inspectGIF(outside, width: 2, height: 2))
        }.value
    }

    // Independent bounded canonical-tree reader for the emitted no-transform,
    // no-cache, literal VP8L subset; not a general WebP decoder.
    // Adapted from the actually exercised v3 reader, separate from writer bits.
    private struct WebPBitsIn {
        let data: Data
        var position = 0
        mutating func integer(_ count: Int) throws -> Int {
            guard count >= 0, count <= 24, count <= data.count * 8 - position else { throw FixtureError.malformed }
            var value = 0
            for index in 0..<count {
                value |= Int((data[position / 8] >> (position % 8)) & 1) << index
                position += 1
            }
            return value
        }
        mutating func zeroTail() throws {
            guard data.count * 8 - position <= 7 else { throw FixtureError.malformed }
            while position < data.count * 8 { guard try integer(1) == 0 else { throw FixtureError.malformed } }
        }
    }
    private struct WebPPrefixTree {
        private let entries: [Int: Int]
        private let single: Int?
        init(_ lengths: [Int]) throws {
            guard !lengths.isEmpty, lengths.count <= 280,
                  lengths.allSatisfy({ (0...15).contains($0) }) else { throw FixtureError.malformed }
            let active = lengths.indices.filter { lengths[$0] > 0 }
            guard !active.isEmpty else { throw FixtureError.malformed }
            if active.count == 1 {
                guard lengths[active[0]] == 1 else { throw FixtureError.malformed }
                single = active[0]; entries = [:]; return
            }
            guard lengths.reduce(0, { $0 + ($1 == 0 ? 0 : (1 << (15 - $1))) }) == 1 << 15 else { throw FixtureError.malformed }
            single = nil
            var counts = [Int](repeating: 0, count: 16), next = counts
            for length in lengths where length > 0 { counts[length] += 1 }
            var code = 0
            for width in 1...15 { code = (code + counts[width - 1]) << 1; next[width] = code }
            var table: [Int: Int] = [:]
            for symbol in lengths.indices where lengths[symbol] > 0 {
                let width = lengths[symbol], value = next[width]; next[width] += 1
                guard table.updateValue(symbol, forKey: (width << 16) | value) == nil else { throw FixtureError.malformed }
            }
            entries = table
        }
        func symbol(_ bits: inout WebPBitsIn) throws -> Int {
            if let single { return single }
            var value = 0
            for width in 1...15 {
                value = (value << 1) | (try bits.integer(1))
                if let symbol = entries[(width << 16) | value] { return symbol }
            }
            throw FixtureError.malformed
        }
    }
    private static func readWebPTree(_ bits: inout WebPBitsIn, alphabet: Int) throws -> WebPPrefixTree {
        guard (1...280).contains(alphabet) else { throw FixtureError.malformed }
        var lengths = [Int](repeating: 0, count: alphabet)
        if try bits.integer(1) == 1 {
            let count = try bits.integer(1) + 1
            let firstWidth = try bits.integer(1) == 1 ? 8 : 1
            let first = try bits.integer(firstWidth)
            guard first < alphabet else { throw FixtureError.malformed }; lengths[first] = 1
            if count == 2 {
                let second = try bits.integer(8)
                guard second < alphabet, second != first else { throw FixtureError.malformed }; lengths[second] = 1
            }
        } else {
            let count = try bits.integer(4) + 4
            let order = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
            var metaLengths = [Int](repeating: 0, count: 19)
            for index in 0..<count { metaLengths[order[index]] = try bits.integer(3) }
            let meta = try WebPPrefixTree(metaLengths)
            var symbols = alphabet
            if try bits.integer(1) != 0 {
                let width = try bits.integer(3) * 2 + 2
                symbols = try bits.integer(width) + 2
                guard symbols <= alphabet else { throw FixtureError.malformed }
            }
            // Restricted oracle admits literal code lengths, not repeat codes.
            for index in 0..<symbols {
                let value = try meta.symbol(&bits); guard value <= 15 else { throw FixtureError.malformed }
                lengths[index] = value
            }
        }
        return try WebPPrefixTree(lengths)
    }
    private struct WebPWireImage { let width: Int; let height: Int; let raw: Data; let alphaHint: Int }
    private static func inspectWebPWire(_ file: Data) throws -> WebPWireImage {
        guard file.count >= 25, file.count <= NativeRasterWriter.maximumOutputBytes else { throw FixtureError.malformed }
        func word(_ at: Int) throws -> Int {
            guard at >= 0, at <= file.count - 4 else { throw FixtureError.malformed }
            return (0..<4).reduce(0) { $0 | (Int(file[at + $1]) << ($1 * 8)) }
        }
        guard file.prefix(4) == Data("RIFF".utf8), try word(4) == file.count - 8,
              file.subdata(in: 8..<12) == Data("WEBP".utf8) else { throw FixtureError.malformed }
        var at = 12, payload: Data?
        while at < file.count {
            guard file.count - at >= 8, file.subdata(in: at..<(at + 4)) == Data("VP8L".utf8), payload == nil else { throw FixtureError.malformed }
            let size = try word(at + 4); at += 8
            guard size >= 5, size <= file.count - at else { throw FixtureError.malformed }
            payload = file.subdata(in: at..<(at + size)); at += size
            if size % 2 != 0 { guard at < file.count, file[at] == 0 else { throw FixtureError.malformed }; at += 1 }
        }
        guard at == file.count, let payload else { throw FixtureError.malformed }
        var bits = WebPBitsIn(data: payload)
        guard try bits.integer(8) == 0x2f else { throw FixtureError.malformed }
        let width = try bits.integer(14) + 1, height = try bits.integer(14) + 1
        guard (1...1024).contains(width), (1...1024).contains(height), width * height <= 262_144 else { throw FixtureError.malformed }
        let pixels = width * height, alphaHint = try bits.integer(1)
        guard try bits.integer(3) == 0, try bits.integer(1) == 0,
              try bits.integer(1) == 0, try bits.integer(1) == 0 else { throw FixtureError.malformed }
        let green = try readWebPTree(&bits, alphabet: 280), red = try readWebPTree(&bits, alphabet: 256)
        let blue = try readWebPTree(&bits, alphabet: 256), alpha = try readWebPTree(&bits, alphabet: 256)
        _ = try readWebPTree(&bits, alphabet: 40)
        var raw = Data(capacity: pixels * 4), nonopaque = false
        for _ in 0..<pixels {
            let g = try green.symbol(&bits); guard g < 256 else { throw FixtureError.malformed }
            let r = try red.symbol(&bits), b = try blue.symbol(&bits), a = try alpha.symbol(&bits)
            guard r < 256, b < 256, a < 256 else { throw FixtureError.malformed }
            raw.append(contentsOf: [UInt8(r), UInt8(g), UInt8(b), UInt8(a)]); nonopaque = nonopaque || a != 255
        }
        try bits.zeroTail()
        guard alphaHint == (nonopaque ? 1 : 0) else { throw FixtureError.malformed }
        return WebPWireImage(width: width, height: height, raw: raw, alphaHint: alphaHint)
    }

    private static func decodedWebPWire(_ data: Data, width: Int, height: Int) throws -> Data {
        let image = try inspectWebPWire(data)
        guard image.width == width, image.height == height else { throw FixtureError.malformed }
        return image.raw
    }

    private static func renderedRaster(_ data: Data, width: Int, height: Int, type: String) throws -> Data {
        guard (1...1024).contains(width), (1...1024).contains(height), width * height <= 262_144,
              data.count <= NativeRasterWriter.maximumOutputBytes else { throw FixtureError.malformed }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, type)
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        guard image.width == width, image.height == height, image.bitsPerComponent == 8,
              image.colorSpace?.model == .rgb else { throw FixtureError.malformed }
        XCTAssertEqual(try XCTUnwrap(image.colorSpace?.copyICCData()) as Data,
            try XCTUnwrap(NSColorSpace.sRGB.iccProfileData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = Data(repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none; context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    private static var binaryPixels: Data {
        Data([245, 37, 11, 255, 19, 213, 71, 0, 23, 61, 237, 0, 191, 113, 43, 255])
    }

    private static var controlPixels: Data {
        Data([255, 0, 0, 255, 17, 34, 51, 128, 10, 20, 30, 0, 60, 120, 180, 64])
    }

    private static var opaquePixels: Data {
        Data([245, 37, 11, 255, 19, 213, 71, 255, 23, 61, 237, 255, 191, 113, 43, 255])
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

    // Independent raw-strip inspection: TIFF 6.0 pp13-16/29-32/36-40/64/80,
    // https://image-js.github.io/tiff/media/TIFF6.pdf; ICC v3.2 Annex B.3:
    // https://www.color.org/icc32.pdf#page=82. No native image decoder is used.
    private static func decodedTIFFPixels(_ data: Data, width: Int, height: Int) throws -> Data {
        func require(_ condition: Bool, _ reason: String) throws {
            guard condition else { throw TIFFInspectionError.malformed(reason) }
        }
        try require((1...NativeRasterWriter.maximumDimension).contains(width) &&
            (1...NativeRasterWriter.maximumDimension).contains(height), "expected dimension bounds")
        try require(width * height <= NativeRasterWriter.maximumPixels, "expected pixel bound")
        let expectedBytes = width * height * 4
        try require(data.count >= 8 && data.count <= NativeRasterWriter.maximumOutputBytes, "TIFF byte bound")
        let order = Array(data.prefix(2))
        try require(order == [0x49, 0x49] || order == [0x4D, 0x4D], "TIFF byte order")
        let littleEndian = order == [0x49, 0x49]
        func integer(_ offset: Int, bytes: Int) throws -> Int {
            try require(offset >= 0 && bytes > 0 && offset <= data.count - bytes, "integer range")
            var value: UInt32 = 0
            for index in 0..<bytes {
                let position = littleEndian ? offset + bytes - 1 - index : offset + index
                value = (value << 8) | UInt32(data[position])
            }
            return Int(value)
        }
        try require(try integer(2, bytes: 2) == 42, "classic TIFF magic")
        let first = try integer(4, bytes: 4)
        try require(first >= 8 && first % 2 == 0, "first IFD alignment")
        let entryCount = try integer(first, bytes: 2)
        try require((1...128).contains(entryCount), "IFD entry bound")
        let end = first + 2 + entryCount * 12 + 4
        try require(end <= data.count, "complete IFD")
        try require(try integer(end - 4, bytes: 4) == 0, "single IFD")
        var occupied = [0..<8, first..<end]
        func claim(_ offset: Int, _ count: Int, _ label: String) throws {
            try require(count > 0 && offset >= 8 && offset <= data.count - count, label + " range")
            let range = offset..<(offset + count)
            try require(!occupied.contains(where: { $0.overlaps(range) }), label + " overlap")
            occupied.append(range)
        }
        let typeBytes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8]
        var fields: [Int: (type: Int, count: Int, offset: Int, length: Int)] = [:]
        var previousTag = -1
        var totalFieldBytes = 0
        for index in 0..<entryCount {
            let entry = first + 2 + index * 12
            let tag = try integer(entry, bytes: 2)
            let type = try integer(entry + 2, bytes: 2)
            let count = try integer(entry + 4, bytes: 4)
            try require(tag > previousTag, "ascending unique tags")
            guard let unit = typeBytes[type] else { throw TIFFInspectionError.malformed("unsupported field type") }
            try require(count > 0 && count <= data.count / unit, "field count bound")
            let length = count * unit
            try require(length <= data.count - totalFieldBytes, "cumulative field byte bound")
            totalFieldBytes += length
            let position: Int
            if length <= 4 { position = entry + 8 }
            else { position = try integer(entry + 8, bytes: 4) }
            if length > 4 {
                try require(position % 2 == 0, "out-of-line field alignment")
                try claim(position, length, "field")
            }
            fields[tag] = (type, count, position, length)
            previousTag = tag
        }
        func values(_ tag: Int, types: Set<Int>, count: Int, fallback: [Int]? = nil) throws -> [Int] {
            guard let field = fields[tag] else {
                guard let fallback else { throw TIFFInspectionError.malformed("missing tag \(tag)") }
                return fallback
            }
            try require(types.contains(field.type) && field.count == count, "tag \(tag) type/count")
            try require(count > 0 && count <= max(height, 4), "decoded value count bound")
            let bytes = field.type == 3 ? 2 : 4
            return try (0..<count).map { try integer(field.offset + $0 * bytes, bytes: bytes) }
        }
        try require(Set(fields.keys).intersection([322, 323, 324, 325, 330]).isEmpty, "tiles/SubIFDs unsupported")
        try require(try values(256, types: [3, 4], count: 1) == [width], "image width")
        try require(try values(257, types: [3, 4], count: 1) == [height], "image height")
        try require(try values(258, types: [3], count: 4) == [8, 8, 8, 8], "eight-bit samples")
        try require(try values(259, types: [3], count: 1, fallback: [1]) == [1], "uncompressed samples")
        try require(try values(262, types: [3], count: 1) == [2], "RGB photometric interpretation")
        try require(try values(274, types: [3], count: 1, fallback: [1]) == [1], "top-left row orientation")
        try require(try values(277, types: [3], count: 1) == [4], "RGBA sample count")
        try require(try values(284, types: [3], count: 1, fallback: [1]) == [1], "chunky samples")
        try require(try values(338, types: [3], count: 1) == [2], "unassociated straight alpha")
        try require(try values(339, types: [3], count: 4, fallback: [1, 1, 1, 1]) == [1, 1, 1, 1], "unsigned integer samples")
        try require(try values(266, types: [3], count: 1, fallback: [1]) == [1], "normal FillOrder")
        try require(try values(317, types: [3], count: 1, fallback: [1]) == [1], "no Predictor")
        let rows = try values(278, types: [3, 4], count: 1, fallback: [Int(UInt32.max)])[0]
        try require(rows >= 1, "positive RowsPerStrip")
        let stripCount = (height + rows - 1) / rows
        try require((1...height).contains(stripCount), "strip count bound")
        let offsets = try values(273, types: [3, 4], count: stripCount)
        let lengths = try values(279, types: [3, 4], count: stripCount)
        var pixels = Data(capacity: expectedBytes)
        for index in 0..<stripCount {
            let actualRows = min(rows, height - index * rows)
            let length = lengths[index]
            try require(length == width * actualRows * 4 && length <= expectedBytes - pixels.count, "exact strip length")
            try claim(offsets[index], length, "strip")
            pixels.append(data.subdata(in: offsets[index]..<(offsets[index] + length)))
        }
        try require(pixels.count == expectedBytes, "exact reconstructed byte count")
        guard let profile = fields[34675], profile.type == 7,
              let expectedProfile = NSColorSpace.sRGB.iccProfileData else {
            throw TIFFInspectionError.malformed("embedded/native sRGB ICC profile missing")
        }
        try require(!expectedProfile.isEmpty && expectedProfile.count <= NativeRasterWriter.maximumOutputBytes,
            "native ICC profile byte bound")
        let embeddedProfile = data.subdata(in: profile.offset..<(profile.offset + profile.length))
        try require(embeddedProfile == expectedProfile,
            "ICC SHA256 \(JSONSupport.sha256Hex(embeddedProfile)) differs from native sRGB \(JSONSupport.sha256Hex(expectedProfile))")
        return pixels
    }

    private enum TIFFInspectionError: Error { case malformed(String) }
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

    // Bounded inspection of this writer's JPEG container, not an entropy decoder
    // or general Exif conformance test. T.81 Annex B describes markers/scans:
    // https://www.w3.org/Graphics/JPEG/itu-t81.pdf. CIPA Exif ColorSpace A001
    // is SHORT/count 1; value 1 declares sRGB. Decoded ICC is checked separately.
    private static func inspectJPEG(_ data: Data, width: Int, height: Int) throws -> (width: Int, color: Int) {
        func require(_ condition: Bool) throws { guard condition else { throw FixtureError.malformed } }
        try require((1...1024).contains(width) && (1...1024).contains(height) && width * height <= 262_144)
        try require(data.count >= 4 && data.count <= NativeRasterWriter.maximumOutputBytes)
        try require(data.prefix(2) == Data([0xFF, 0xD8]))
        func word(_ offset: Int) throws -> Int {
            try require(offset >= 0 && offset <= data.count - 2)
            return Int(data[offset]) * 256 + Int(data[offset + 1])
        }
        var offset = 2, markers = 0, scans = 0
        var frameWidth: Int?, colorPosition: Int?
        while offset < data.count {
            try require(markers < 1024 && data[offset] == 0xFF)
            while offset < data.count && data[offset] == 0xFF { offset += 1 }
            try require(offset < data.count)
            let marker = data[offset]; offset += 1; markers += 1
            if marker == 0xD9 {
                try require(offset == data.count && scans > 0)
                guard let frameWidth, let colorPosition else { throw FixtureError.malformed }
                return (frameWidth, colorPosition)
            }
            try require(marker != 0 && marker != 0xD8 && marker != 1 && !(0xD0...0xD7).contains(marker))
            let length = try word(offset)
            try require(length >= 2 && length <= data.count - offset)
            let start = offset + 2, end = offset + length
            if [UInt8(0xC0), 0xC1, 0xC2].contains(marker) {
                try require(frameWidth == nil && scans == 0 && length == 17)
                try require(data[start] == 8 && (try word(start + 1)) == height &&
                    (try word(start + 3)) == width && data[start + 5] == 3)
                frameWidth = start + 3
            }
            if marker == 0xE1 && end - start >= 6 && data.subdata(in: start..<(start + 6)) == Data("Exif\0\0".utf8) {
                try require(colorPosition == nil)
                let base = start + 6, count = end - base
                try require(count >= 8)
                let order = data.subdata(in: base..<(base + 2))
                try require(order == Data([73, 73]) || order == Data([77, 77]))
                let little = order == Data([73, 73])
                func integer(_ relative: Int, bytes: Int) throws -> Int {
                    try require(relative >= 0 && relative <= count - bytes)
                    var value: UInt32 = 0
                    for index in 0..<bytes {
                        let position = little ? relative + bytes - 1 - index : relative + index
                        value = (value << 8) | UInt32(data[base + position])
                    }
                    return Int(value)
                }
                func fields(_ position: Int) throws -> [Int: (type: Int, count: Int, value: Int)] {
                    try require(position >= 8)
                    let entries = try integer(position, bytes: 2)
                    try require((1...128).contains(entries) && position <= count - 2 - entries * 12 - 4)
                    try require(try integer(position + 2 + entries * 12, bytes: 4) == 0)
                    var result: [Int: (type: Int, count: Int, value: Int)] = [:]
                    for index in 0..<entries {
                        let entry = position + 2 + index * 12
                        let tag = try integer(entry, bytes: 2)
                        try require(result[tag] == nil)
                        result[tag] = (try integer(entry + 2, bytes: 2), try integer(entry + 4, bytes: 4), entry + 8)
                    }
                    return result
                }
                try require(try integer(2, bytes: 2) == 42)
                let root = try fields(integer(4, bytes: 4))
                guard let pointer = root[0x8769], pointer.type == 4, pointer.count == 1 else { throw FixtureError.malformed }
                let exif = try fields(integer(pointer.value, bytes: 4))
                for (tag, expected) in [(0xA001, 1), (0xA002, width), (0xA003, height)] {
                    guard let field = exif[tag], field.count == 1,
                          (tag == 0xA001 ? field.type == 3 : [3, 4].contains(field.type)) else { throw FixtureError.malformed }
                    try require(try integer(field.value, bytes: field.type == 3 ? 2 : 4) == expected)
                    if tag == 0xA001 { colorPosition = base + field.value }
                }
            }
            offset = end
            if marker == 0xDA {
                scans += 1
                try require(frameWidth != nil && scans <= 32 && length >= 6)
                let components = Int(data[start])
                try require((1...3).contains(components) && length == 6 + components * 2)
                while offset < data.count {
                    if data[offset] != 0xFF { offset += 1; continue }
                    let markerStart = offset
                    while offset < data.count && data[offset] == 0xFF { offset += 1 }
                    try require(offset < data.count)
                    if data[offset] == 0 || (0xD0...0xD7).contains(data[offset]) { offset += 1; continue }
                    offset = markerStart; break
                }
            }
        }
        throw FixtureError.malformed
    }

    // Bounded GIF89a container inspection, separate from ImageIO decoding and
    // the external raw LZW oracle. This does not decode compressed indices.
    private static func inspectGIF(_ data: Data, width: Int, height: Int) throws {
        guard data.count >= 14, data.count <= NativeRasterWriter.maximumOutputBytes,
              (1...1024).contains(width), (1...1024).contains(height), width * height <= 262_144,
              data.prefix(6) == Data("GIF89a".utf8) else { throw FixtureError.malformed }
        var offset = 6, blocks = 0, subblocks = 0, imageCount = 0
        var pendingTransparency: Int?
        var pendingControl = false
        func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else { throw FixtureError.malformed }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        func byte() throws -> Int { Int(try take(1)[0]) }
        func word() throws -> Int { let bytes = try take(2); return Int(bytes[0]) | Int(bytes[1]) << 8 }
        func skipSubblocks() throws -> Int {
            var total = 0
            while true {
                subblocks += 1
                guard subblocks <= 16_384 else { throw FixtureError.malformed }
                let count = try byte()
                if count == 0 { return total }
                _ = try take(count); total += count
            }
        }
        guard try word() == width, try word() == height else { throw FixtureError.malformed }
        let screenFlags = try byte(), background = try byte(); _ = try byte()
        let globalEntries = screenFlags & 128 == 0 ? 0 : 1 << ((screenFlags & 7) + 1)
        guard globalEntries == 0 ? background == 0 : background < globalEntries else { throw FixtureError.malformed }
        _ = try take(globalEntries * 3)
        while offset < data.count {
            blocks += 1; guard blocks <= 4096 else { throw FixtureError.malformed }
            switch try byte() {
            case 0x3B:
                guard imageCount == 1, !pendingControl, offset == data.count else { throw FixtureError.malformed }
                return
            case 0x21:
                switch try byte() {
                case 0xF9:
                    guard !pendingControl, try byte() == 4 else { throw FixtureError.malformed }
                    let flags = try byte(); _ = try word(); let index = try byte()
                    guard flags & 0xE0 == 0, ((flags >> 2) & 7) <= 3, try byte() == 0 else { throw FixtureError.malformed }
                    pendingControl = true; pendingTransparency = flags & 1 == 0 ? nil : index
                case 0xFF:
                    guard try byte() == 11 else { throw FixtureError.malformed }
                    _ = try take(11); _ = try skipSubblocks()
                case 0xFE: _ = try skipSubblocks()
                default: throw FixtureError.malformed
                }
            case 0x2C:
                guard imageCount == 0, try word() == 0, try word() == 0,
                      try word() == width, try word() == height else { throw FixtureError.malformed }
                let flags = try byte()
                guard flags & 0x18 == 0 else { throw FixtureError.malformed }
                let localEntries = flags & 128 == 0 ? 0 : 1 << ((flags & 7) + 1)
                _ = try take(localEntries * 3)
                let entries = localEntries == 0 ? globalEntries : localEntries
                guard entries > 0, pendingTransparency.map({ $0 < entries }) ?? true,
                      (2...8).contains(try byte()), try skipSubblocks() > 0 else { throw FixtureError.malformed }
                imageCount += 1; pendingControl = false; pendingTransparency = nil
            default: throw FixtureError.malformed
            }
        }
        throw FixtureError.malformed
    }

    private static func decodedGIF(_ data: Data, width: Int, height: Int) throws -> Data {
        try inspectGIF(data, width: width, height: height)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.compuserve.gif")
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        guard image.width == width, image.height == height, image.bitsPerComponent == 8,
              image.colorSpace?.model == .rgb else { throw FixtureError.malformed }
        XCTAssertEqual(try XCTUnwrap(image.colorSpace?.copyICCData()) as Data,
            try XCTUnwrap(NSColorSpace.sRGB.iccProfileData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = Data(repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none; context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    private static func decodedJPEG(_ data: Data, width: Int, height: Int) throws -> Data {
        guard (1...1024).contains(width), (1...1024).contains(height), width * height <= 262_144,
              data.count <= NativeRasterWriter.maximumOutputBytes else { throw FixtureError.malformed }
        _ = try inspectJPEG(data, width: width, height: height)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        guard image.width == width, image.height == height, image.bitsPerComponent == 8,
              image.colorSpace?.model == .rgb else { throw FixtureError.malformed }
        XCTAssertEqual(try XCTUnwrap(image.colorSpace?.copyICCData()) as Data,
            try XCTUnwrap(NSColorSpace.sRGB.iccProfileData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = Data(repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none; context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}

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
}

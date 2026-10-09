import Foundation
import Darwin
import zlib
import XCTest
@testable import ForgeConductorCore

final class NativeTARArchiveWriterTests: XCTestCase {
    func testTARPAXPreservesBinaryUnicodeNamesOrderLongNamesAndEmptyArchive() async throws {
        try await Task.detached(priority: .utility) {
            let empty = try NativePAXTARWriter.encode(entries: [])
            XCTAssertEqual(empty.data, Data(repeating: 0, count: 1_024))
            XCTAssertEqual(empty.entryCount, 0); XCTAssertEqual(empty.inputBytes, 0)
            let long = [String(repeating: "a", count: 255), String(repeating: "b", count: 255),
                String(repeating: "c", count: 255), String(repeating: "d", count: 253), "ee"].joined(separator: "/")
            let supplied = Self.mixed + [(long, Data([0])), ("space and=equals", Data([1, 2]))]
            let tar = try NativePAXTARWriter.encode(entries: Self.entries(supplied))
            let parsed = try Self.readTAR(tar.data)
            XCTAssertEqual(parsed.map(\.0), supplied.map(\.0)); XCTAssertEqual(parsed.map(\.1), supplied.map(\.1))
            XCTAssertEqual(tar.entryCount, supplied.count)
            XCTAssertEqual(tar.inputBytes, supplied.reduce(0) { $0 + $1.1.count })
            XCTAssertEqual(try NativePAXTARWriter.encode(entries: Self.entries(supplied)).data, tar.data)
        }.value
    }

    func testTARPaddingThirtyTwoMembersMaximumRawAndExactOutputBounds() async throws {
        try await Task.detached(priority: .utility) {
            let edges = [511, 512, 513].map { ("edge-\($0)", Data((0..<$0).map { UInt8(truncatingIfNeeded: $0) })) }
            let tar = try NativePAXTARWriter.encode(entries: Self.entries(edges))
            XCTAssertEqual(try Self.readTAR(tar.data).map(\.1), edges.map(\.1))
            XCTAssertEqual(try NativePAXTARWriter.encode(entries: Self.entries(edges), outputByteLimit: tar.data.count).data, tar.data)
            for limit in [0, tar.data.count - 1, 2_097_153] {
                XCTAssertThrowsError(try NativePAXTARWriter.encode(entries: Self.entries(edges), outputByteLimit: limit)) {
                    XCTAssertEqual(($0 as? NativePAXTARError)?.code, "archive_output_too_large")
                }
            }
            let members = (0..<32).map { (String(format: "member-%02d.bin", $0), Data([UInt8($0), UInt8(255 - $0), 0, 255, UInt8(truncatingIfNeeded: $0 * 17)])) }
            XCTAssertEqual(try Self.readTAR(NativePAXTARWriter.encode(entries: Self.entries(members)).data).map(\.1), members.map(\.1))
            let noise = Self.noise()
            let maximum = try NativePAXTARWriter.encode(entries: Self.entries([("noise.bin", noise)]))
            XCTAssertEqual(maximum.inputBytes, 1_048_576)
            XCTAssertEqual(try Self.readTAR(maximum.data).map(\.1), [noise])
        }.value
    }

    func testTARAndGZIPAdmissionRefusalsMatchZIPWithoutRelaxingNamesOrBase64() async throws {
        try await Task.detached(priority: .utility) {
            var values: [Any?] = [nil, NSNull(), "entries", ["entry"],
                Array(repeating: ["name": "a", "content": ""], count: 33),
                [["name": 1, "content": ""]], [["name": "a", "content": false]],
                [["name": "a"]], [["name": "a", "content": "", "extra": 0]]]
            for name in ["", "/a", "C:a", "C:/a", "a\\b", "a\u{0}b", "a\n", ".", "..", "a/./b", "a/../b", "a//b", "a/",
                "cafe\u{0301}.txt", String(repeating: "a", count: 1_025), String(repeating: "é", count: 128)] {
                values.append([["name": name, "content": ""]])
            }
            for names in [["a", "a"], ["File.TXT", "file.txt"], ["a", "A/b"], ["A/b", "a"]] {
                values.append(names.map { ["name": $0, "content": ""] })
            }
            for content in ["!!!!", "AA==\n", "AA", "=AAA", "AB==", "AAB=", "====", String(repeating: "A", count: 1_398_105)] {
                values.append([["name": "a", "content": content]])
            }
            values.append(Self.entries([("a", Data(repeating: 0, count: 1_048_577))]))
            values.append(Self.entries([("a", Data(repeating: 0, count: 524_289)), ("b", Data(repeating: 0, count: 524_289))]))
            for value in values {
                let expected = Self.refusal { try NativeStoredZIPWriter.encode(entries: value) }
                XCTAssertEqual(Self.refusal { try NativePAXTARWriter.encode(entries: value) }, expected)
                XCTAssertEqual(Self.refusal { try NativeGZIPArchiveWriter.encode(entries: value) }, expected)
            }
        }.value
    }

    func testGZIPFixedMetadataWholeTARCRCSizeExactCapAndReleasedState() async throws {
        try await Task.detached(priority: .utility) {
            for supplied in [[], Self.mixed, [("noise.bin", Self.noise())]] as [[(String, Data)]] {
                let tar = try NativePAXTARWriter.encode(entries: Self.entries(supplied))
                let gzip = try NativeGZIPArchiveWriter.compress(tar.data)
                XCTAssertEqual(try Self.readGZIP(gzip.data), tar.data)
                XCTAssertEqual(try Self.readTAR(Self.readGZIP(gzip.data)).map(\.1), supplied.map(\.1))
                XCTAssertEqual(gzip.allocationCount, gzip.freeCount); XCTAssertGreaterThan(gzip.allocationCount, 0)
                XCTAssertGreaterThan(gzip.peakStateBytes, 0); XCTAssertLessThanOrEqual(gzip.peakStateBytes, 1_048_576)
                XCTAssertEqual(gzip.endStatus, Z_OK)
                XCTAssertEqual(try NativeGZIPArchiveWriter.compress(tar.data).data, gzip.data)
                XCTAssertEqual(try NativeGZIPArchiveWriter.compress(tar.data, outputByteLimit: gzip.data.count).data, gzip.data)
                XCTAssertThrowsError(try NativeGZIPArchiveWriter.compress(tar.data, outputByteLimit: gzip.data.count - 1)) {
                    XCTAssertEqual(($0 as? NativePAXTARError)?.code, "archive_output_too_large")
                }
            }
            let tar = try NativePAXTARWriter.encode(entries: [])
            XCTAssertThrowsError(try NativeGZIPArchiveWriter.compress(tar.data, stateByteLimit: 1)) {
                XCTAssertEqual($0 as? NativeGZIPArchiveError, .allocationFailure)
            }
        }.value
    }

    func testTARAndGZIPTestConsumersRejectCorruptHeadersExtentsChecksumsAndEOF() async throws {
        try await Task.detached(priority: .utility) {
            let tar = try NativePAXTARWriter.encode(entries: Self.entries(Self.mixed)).data
            let gzip = try NativeGZIPArchiveWriter.compress(tar).data
            var checksum = tar; checksum[148] ^= 1
            var type = tar; type[156] = 53
            var pax = tar; pax[512] = 48
            var tail = tar; tail[tail.count - 1] = 1
            for malformed in [checksum, type, pax, tail, Data(tar.dropLast()), tar + Data([0])] {
                XCTAssertThrowsError(try Self.readTAR(malformed))
            }
            var crc = gzip; crc[crc.count - 8] ^= 1
            var size = gzip; size[size.count - 4] ^= 1
            var metadata = gzip; metadata[9] = 3
            for malformed in [crc, size, metadata, Data(gzip.dropLast()), gzip + Data([0]), gzip + gzip] {
                XCTAssertThrowsError(try Self.readGZIP(malformed))
            }
        }.value
    }

    func testArchiveNewWritersRefuseMainThreadPreCancellationAndExpiredDeadline() async throws {
        await MainActor.run {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(Self.refusal { try NativePAXTARWriter.encode(entries: []) }, "archive_worker_required")
            XCTAssertEqual(Self.refusal { try NativeGZIPArchiveWriter.encode(entries: []) }, "archive_worker_required")
        }
        try await Task.detached(priority: .utility) {
            for format in ["tar", "tar.gz"] {
                let cancelled = ToolCallCancellation(timeoutSeconds: 5); cancelled.cancel()
                for token in [cancelled, ToolCallCancellation(timeoutSeconds: 0)] {
                    XCTAssertThrowsError(try Self.encode(format, entries: [], cancellation: token)) {
                        XCTAssertTrue($0 is CancellationError || $0 is ToolCallDeadlineExceeded)
                    }
                }
            }
        }.value
    }

    func testArchiveFormatsKeepZIPDefaultBytesAndPinnedModesWithCompletePagedReads() async throws {
        try await Task.detached(priority: .utility) {
            try Self.withApp { app, client, project in
                let rows = Self.entries([("note.txt", Data(repeating: 42, count: 40_000))])
                let zip = project.appendingPathComponent("default.ZIP")
                let old = try app.tools.call(name: "archive_write", arguments: ["path": zip.path, "entries": rows], clientID: client)
                let original = try Data(contentsOf: zip)
                let explicit = try app.tools.call(name: "archive_write", arguments: ["path": zip.path, "entries": rows, "format": "zip"], clientID: client)
                XCTAssertTrue(old.ok); XCTAssertEqual(try JSONSupport.canonicalJSON(old.payload), try JSONSupport.canonicalJSON(explicit.payload))
                XCTAssertEqual(try Data(contentsOf: zip), original)
                for format in ["tar", "tar.gz"] {
                    let destination = project.appendingPathComponent("new.\(format.uppercased())")
                    let arguments: [String: Any] = ["path": destination.path, "entries": rows, "format": format]
                    let written = try app.tools.call(name: "archive_write", arguments: arguments, clientID: client)
                    XCTAssertTrue(written.ok, "\(written.payload)")
                    let bytes = try Data(contentsOf: destination)
                    XCTAssertEqual(written.payload["format"] as? String, format)
                    XCTAssertEqual(written.payload["entry_count"] as? Int, 1); XCTAssertEqual(written.payload["input_bytes"] as? Int, 40_000)
                    XCTAssertEqual(written.payload["bytes_written"] as? Int, bytes.count)
                    XCTAssertEqual(written.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                    XCTAssertEqual(written.payload["engine"] as? String, format == "tar" ? "swift-pax-tar" : "system-zlib-gzip-pax-tar")
                    XCTAssertEqual(written.payload["output_contract"] as? String, format == "tar" ? "tar-pax-supplied-files-v1" : "tar-gzip-pax-supplied-files-v1")
                    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue, 0o644)
                    let tar = format == "tar" ? bytes : try Self.readGZIP(bytes)
                    XCTAssertEqual(try Self.readTAR(tar).map(\.1), [Data(repeating: 42, count: 40_000)])
                    var readBack = Data(), offset = 0, sawEOF = false
                    for _ in 0..<8 {
                        let read = try app.tools.call(name: "fs_read", arguments: ["path": destination.path, "encoding": "base64", "byte_offset": offset, "maximum_bytes": 8_192], clientID: client)
                        XCTAssertTrue(read.ok)
                        let part = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(read.payload["content"] as? String)))
                        readBack.append(part); let next = try XCTUnwrap(read.payload["next_byte_offset"] as? Int)
                        XCTAssertEqual(next, offset + part.count); offset = next
                        if read.payload["has_more"] as? Bool == false { sawEOF = true; break }
                        XCTAssertFalse(part.isEmpty)
                    }
                    XCTAssertTrue(sawEOF); XCTAssertEqual(readBack, bytes)
                    XCTAssertEqual(chmod(destination.path, 0o600), 0)
                    XCTAssertTrue(try app.tools.call(name: "archive_write", arguments: arguments, clientID: client).ok)
                    XCTAssertEqual(try Data(contentsOf: destination), bytes)
                    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
                }
            }
        }.value
    }

    func testFormatExtensionGrantStaleContextAndPinnedRefusalsPreserveFiles() async throws {
        try await Task.detached(priority: .utility) {
            try Self.withApp { app, client, project in
                let context = try app.projectContexts.invocationContext(for: client)
                let deniedClient = ClientID("tar-denied")
                _ = try app.projectContexts.bind(owner: ProjectBindingOwner(kind: .mcpClient, id: deniedClient.rawValue),
                    projectID: context.projectID, generation: context.projectGeneration,
                    authorizationScope: ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots,
                        allowedTools: ["fs_write", "audio_write"], networkAllowed: false, maximumInlineOutputBytes: 65_536))
                let destination = project.appendingPathComponent("keep.tar"), prior = Data("keep".utf8)
                try prior.write(to: destination)
                for value in [NSNull(), true, 1, "TAR", "gzip", "gz", "tgz", ""] as [Any] {
                    let result = try XCTUnwrap(try DocsToolPack().handle(name: "archive_write", arguments: ["path": destination.path, "entries": [], "format": value], context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, "invalid_archive_format")
                }
                for (format, path) in [("tar", "bad.zip"), ("tar.gz", "bad.gz"), ("tar.gz", "bad.tgz"), ("zip", "bad.tar"), ("tar", "bad.tar.gz")] {
                    let result = try XCTUnwrap(try DocsToolPack().handle(name: "archive_write", arguments: ["path": project.appendingPathComponent(path).path, "entries": [], "format": format], context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, "invalid_path")
                }
                let outside = project.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let link = project.appendingPathComponent("link")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                for format in ["tar", "tar.gz"] {
                    let neighbor = outside.appendingPathComponent("keep.\(format)")
                    try prior.write(to: neighbor)
                    let linked = try XCTUnwrap(try DocsToolPack().handle(name: "archive_write", arguments: ["path": link.appendingPathComponent("keep.\(format)").path, "entries": [], "format": format], context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(linked.ok); XCTAssertEqual(linked.payload["code"] as? String, "archive_write_failed")
                    XCTAssertEqual(try Data(contentsOf: neighbor), prior)
                    let path = project.appendingPathComponent("denied.\(format)")
                    let result = try app.tools.call(name: "archive_write", arguments: ["path": path.path, "entries": [], "format": format], clientID: deniedClient)
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, "tool_not_granted")
                    XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
                    let directory = project.appendingPathComponent("directory.\(format)", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let failed = try XCTUnwrap(try DocsToolPack().handle(name: "archive_write", arguments: ["path": directory.path, "entries": [], "format": format], context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(failed.ok); XCTAssertEqual(failed.payload["code"] as? String, "archive_write_failed")
                }
                _ = try app.projectContexts.beginReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                _ = try app.projectContexts.completeReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                for format in ["tar", "tar.gz"] {
                    let result = try XCTUnwrap(try DocsToolPack().handle(name: "archive_write", arguments: ["path": destination.path + (format == "tar.gz" ? ".gz" : ""), "entries": [], "format": format], context: context, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, "archive_encode_failed")
                }
                XCTAssertEqual(try Data(contentsOf: destination), prior)
            }
        }.value
    }

    private static var mixed: [(String, Data)] { [("empty.bin", Data()), ("bytes/all-256.bin", Data((0...255).map { UInt8($0) })), ("données/日本語.txt", Data([0, 195, 169, 255, 10, 0, 13]))] }
    private static func entries(_ values: [(String, Data)]) -> [[String: Any]] { values.map { ["name": $0.0, "content": $0.1.base64EncodedString()] } }
    private static func encode(_ format: String, entries: Any?, cancellation: ToolCallCancellation?) throws -> NativeStoredZIPWriter.EncodedArchive {
        if format == "tar" { return try NativePAXTARWriter.encode(entries: entries, cancellation: cancellation) }
        return try NativeGZIPArchiveWriter.encode(entries: entries, cancellation: cancellation)
    }
    private static func refusal(_ operation: () throws -> NativeStoredZIPWriter.EncodedArchive) -> String? {
        do { _ = try operation(); XCTFail("Expected refusal"); return nil }
        catch let error as NativeStoredZIPError { return error.code }
        catch let error as NativePAXTARError { return error.code }
        catch { XCTFail("Unexpected refusal type: \(error)"); return nil }
    }
    private static func noise() -> Data {
        var state: UInt32 = 0x13579BDF, bytes = Data(capacity: 1_048_576)
        for _ in 0..<1_048_576 { state = state &* 1_664_525 &+ 1_013_904_223; bytes.append(UInt8(truncatingIfNeeded: state >> 24)) }
        return bytes
    }
    private static func withApp(_ operation: (ForgeApp, ClientID, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-tar-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home"), startTelemetry: false)
        defer { XCTAssertTrue(app.shutdown().completed); try? FileManager.default.removeItem(at: root) }
        _ = try app.config.update(["allowed_roots": [project.path]], save: false)
        let client = ClientID("tar-tools")
        XCTAssertTrue(try app.tools.call(name: "project_memory.initialize", arguments: ["project_path": project.path], clientID: client).ok)
        try operation(app, client, project)
    }

    private enum WireError: Error { case malformed }
    /// Header/PAX/payload oracle independent of the writer's fixed-point and header builders.
    private static func readTAR(_ data: Data) throws -> [(String, Data)] {
        guard data.count >= 1_024, data.count <= 2_097_152, data.count % 512 == 0 else { throw WireError.malformed }
        func octal(_ bytes: Data) throws -> Int {
            guard bytes.last == 0, bytes.dropLast().allSatisfy({ (48...55).contains($0) }),
                  let text = String(data: bytes.dropLast(), encoding: .ascii), let value = Int(text, radix: 8) else { throw WireError.malformed }
            return value
        }
        func record(_ cursor: Int, index: Int, type: UInt8) throws -> (Data, Int) {
            guard cursor <= data.count - 512 else { throw WireError.malformed }
            let h = Data(data[cursor..<(cursor + 512)])
            guard h[156] == type, Data(h[257..<265]) == Data([117,115,116,97,114,0,48,48]),
                  try octal(Data(h[100..<108])) == 0o644, try octal(Data(h[108..<116])) == 0,
                  try octal(Data(h[116..<124])) == 0, try octal(Data(h[136..<148])) == 0,
                  h[154] == 0, h[155] == 32, h[157..<257].allSatisfy({ $0 == 0 }), h[265..<512].allSatisfy({ $0 == 0 }) else { throw WireError.malformed }
            let expected = Data(String(format: "%@/%08d", type == 120 ? "PaxHeaders" : "ForgeFiles", index).utf8)
            guard Data(h.prefix(expected.count)) == expected, h[expected.count..<100].allSatisfy({ $0 == 0 }) else { throw WireError.malformed }
            var sum = 0
            for position in 0..<512 { sum += (148..<156).contains(position) ? 32 : Int(h[position]) }
            guard let digits = String(data: h[148..<154], encoding: .ascii), Int(digits, radix: 8) == sum else { throw WireError.malformed }
            let size = try octal(Data(h[124..<136])), start = cursor + 512
            guard size <= data.count - start else { throw WireError.malformed }
            let end = start + ((size + 511) / 512) * 512
            guard end <= data.count, data[(start + size)..<end].allSatisfy({ $0 == 0 }) else { throw WireError.malformed }
            return (Data(data[start..<(start + size)]), end)
        }
        var cursor = 0, result: [(String, Data)] = []
        while cursor < data.count - 1_024 {
            guard result.count < 32 else { throw WireError.malformed }
            let (pax, next) = try record(cursor, index: result.count, type: 120)
            guard pax.count <= 1_035, pax.last == 10, let space = pax.firstIndex(of: 32),
                  let digits = String(data: pax[..<space], encoding: .ascii), Int(digits) == pax.count,
                  Data(pax[(space + 1)..<min(pax.count, space + 6)]) == Data("path=".utf8) else { throw WireError.malformed }
            let nameBytes = Data(pax[(space + 6)..<(pax.count - 1)])
            guard let name = String(data: nameBytes, encoding: .utf8), !name.isEmpty, nameBytes.count <= 1_024,
                  Data(name.utf8) == nameBytes else { throw WireError.malformed }
            let (raw, end) = try record(next, index: result.count, type: 48)
            result.append((name, raw)); cursor = end
        }
        guard cursor == data.count - 1_024, data[cursor...].allSatisfy({ $0 == 0 }) else { throw WireError.malformed }
        return result
    }

    /// Public zlib decoding is a separate test consumer; independent evidence parser remains a later gate.
    private static func readGZIP(_ bytes: Data) throws -> Data {
        guard (18...2_097_152).contains(bytes.count), Data(bytes.prefix(10)) == Data([31,139,8,0,0,0,0,0,0,255]) else { throw WireError.malformed }
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1); stream.initialize(to: z_stream())
        defer { stream.deinitialize(count: 1); stream.deallocate() }
        guard inflateInit2_(stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw WireError.malformed }
        defer { XCTAssertEqual(inflateEnd(stream), Z_OK) }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65_536); defer { buffer.deallocate() }
        var result = Data()
        try bytes.withUnsafeBytes { raw in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: raw.baseAddress!.assumingMemoryBound(to: UInt8.self)); stream.pointee.avail_in = uInt(bytes.count)
            defer { stream.pointee.next_in = nil; stream.pointee.next_out = nil }
            var complete = false
            for _ in 0..<4_096 {
                stream.pointee.next_out = buffer; stream.pointee.avail_out = 65_536
                let before = stream.pointee.total_in, status = inflate(stream, Z_NO_FLUSH)
                guard stream.pointee.avail_out <= 65_536 else { throw WireError.malformed }
                let count = 65_536 - Int(stream.pointee.avail_out)
                guard count <= 2_097_152 - result.count else { throw WireError.malformed }
                result.append(buffer, count: count)
                if status == Z_STREAM_END { guard stream.pointee.avail_in == 0 else { throw WireError.malformed }; complete = true; break }
                guard status == Z_OK, count > 0 || stream.pointee.total_in > before else { throw WireError.malformed }
            }
            guard complete else { throw WireError.malformed }
        }
        func le(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) } }
        let table: [UInt32] = (0..<256).map { index in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value >> 1) ^ ((value & 1) == 1 ? UInt32(0xEDB88320) : 0)
            }
            return value
        }
        let crc = result.reduce(UInt32.max) { table[Int(($0 ^ UInt32($1)) & 255)] ^ ($0 >> 8) } ^ UInt32.max
        guard le(bytes.count - 8) == crc, le(bytes.count - 4) == UInt32(result.count) else { throw WireError.malformed }
        return result
    }
}

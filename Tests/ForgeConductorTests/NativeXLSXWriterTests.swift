import Foundation
import Darwin
import XCTest
@testable import ForgeConductorCore

final class NativeXLSXWriterTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-xlsx-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        temporaryRoot = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryRoot)
    }

    func testStoredZIPRecordsCRCAndFivePartWorkbookRelationships() async throws {
        try await Task.detached(priority: .utility) {
            let bytes = try NativeXLSXWriter.encode(rows: [["XLSX marker"]])
            let parts = try Self.inspectZIP(bytes)
            XCTAssertEqual(Set(parts.keys), ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml",
                "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml"])
            XCTAssertEqual(try SafeZIPArchive.inspect(bytes).map(\.path).sorted(), parts.keys.sorted())
            XCTAssertEqual(Self.crc32(Data("123456789".utf8)), 0xCBF43926)
            let types = try Self.parseXML(try XCTUnwrap(parts["[Content_Types].xml"]))
            XCTAssertEqual(types.elements.first?.0, "Types")
            XCTAssertEqual(types.elements.first?.1["xmlns"], "http://schemas.openxmlformats.org/package/2006/content-types")
            XCTAssertEqual(types.elements.filter { $0.0 == "Override" }.map { $0.1["PartName"]! },
                ["/xl/workbook.xml", "/xl/worksheets/sheet1.xml"])
            XCTAssertEqual(types.elements.filter { $0.0 == "Override" }.map { $0.1["ContentType"]! },
                ["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
                 "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"])
            let root = try Self.parseXML(try XCTUnwrap(parts["_rels/.rels"]))
            let rootRelationship = try XCTUnwrap(root.elements.first { $0.0 == "Relationship" }?.1)
            XCTAssertEqual(rootRelationship["Target"], "xl/workbook.xml")
            XCTAssertEqual(rootRelationship["Type"], "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument")
            let workbook = try Self.parseXML(try XCTUnwrap(parts["xl/workbook.xml"]))
            let sheet = try XCTUnwrap(workbook.elements.first { $0.0 == "sheet" }?.1)
            XCTAssertEqual(sheet, ["name": "Sheet1", "sheetId": "1", "r:id": "rId1"])
            let relations = try Self.parseXML(try XCTUnwrap(parts["xl/_rels/workbook.xml.rels"]))
            let relation = try XCTUnwrap(relations.elements.first { $0.0 == "Relationship" }?.1)
            XCTAssertEqual(relation["Id"], sheet["r:id"])
            XCTAssertEqual(relation["Target"], "worksheets/sheet1.xml")
            XCTAssertEqual(relation["Type"], "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet")
            let worksheet = try Self.parseXML(try XCTUnwrap(parts["xl/worksheets/sheet1.xml"]))
            XCTAssertEqual(worksheet.cells, ["A1": "XLSX marker"])
            XCTAssertEqual(worksheet.cellTypes, ["A1": "inlineStr"])
        }.value
    }

    func testUnicodeXMLAndOOXMLLiteralsPreserveExactCellValues() async throws {
        try await Task.detached(priority: .utility) {
            let values = ["café Ελληνικά Русский 日本語 العربية 🙂", "&<>\"'", "  leading\ttrailing  ",
                "line\r\nCR\rLF\nparagraph\u{2029}", "_x0041_ _x005F_ _x00aD_ _X0041_ _xZZZZ_",
                "=SUM(A1:A2)", "+123", "-123", "@literal", "00123", ""]
            let parts = try Self.inspectZIP(NativeXLSXWriter.encode(rows: [values]))
            let data = try XCTUnwrap(parts["xl/worksheets/sheet1.xml"])
            let xml = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(xml.contains("&amp;&lt;&gt;\"'"))
            XCTAssertTrue(xml.contains("line_x000D_\nCR_x000D_LF\nparagraph\u{2029}"))
            XCTAssertTrue(xml.contains("_x005F_x0041_ _x005F_x005F_ _x005F_x00aD_ _x005F_X0041_ _xZZZZ_"))
            XCTAssertFalse(xml.contains("<f>"))
            let parsed = try Self.parseXML(data)
            for (index, expected) in values.enumerated() {
                let address = "\(String(UnicodeScalar(65 + index)!))1"
                XCTAssertEqual(try Self.decodedOOXML(try XCTUnwrap(parsed.cells[address])), expected)
                XCTAssertEqual(parsed.cellTypes[address], "inlineStr")
            }
            XCTAssertEqual(parsed.preservedTextElements, values.count)
        }.value
    }

    func testBlankRaggedRowsAndColumnAddressesRetainPositions() async throws {
        try await Task.detached(priority: .utility) {
            let blank = try Self.inspectZIP(NativeXLSXWriter.encode(rows: []))
            XCTAssertTrue(try Self.parseXML(XCTUnwrap(blank["xl/worksheets/sheet1.xml"])).cells.isEmpty)
            let rows = [[], ["", "second"], [], (0..<64).map { "column-\($0 + 1)" }]
            let parts = try Self.inspectZIP(NativeXLSXWriter.encode(rows: rows))
            let parsed = try Self.parseXML(XCTUnwrap(parts["xl/worksheets/sheet1.xml"]))
            XCTAssertEqual(parsed.rowAddresses, ["1", "2", "3", "4"])
            XCTAssertEqual(parsed.cells["A2"], "")
            XCTAssertEqual(parsed.cells["B2"], "second")
            XCTAssertEqual(parsed.cells["Z4"], "column-26")
            XCTAssertEqual(parsed.cells["AA4"], "column-27")
            XCTAssertEqual(parsed.cells["BL4"], "column-64")
            XCTAssertEqual(parsed.cells.count, 66)
        }.value
    }

    func testWriterOutputFeedsNativeCellReaderWithoutPackageXMLInstructions() async throws {
        try await Task.detached(priority: .utility) {
            let values = ["café 日本語 🙂", "_x0041_ _X0041_", "CR\rLF\nTAB\t", "=SUM(A1:A2)"]
            let bytes = try NativeXLSXWriter.encode(rows: [values])
            XCTAssertEqual(try NativeXLSXReader.text(in: bytes),
                "[Sheet Sheet1]\nA1: café 日本語 🙂\nB1: _x0041_ _X0041_\nC1: CR\rLF\nTAB\t\nD1: =SUM(A1:A2)")
            XCTAssertEqual(try NativeXLSXReader.text(in: NativeXLSXWriter.encode(rows: [])), "")
        }.value
    }

    func testExactTextCellRowAndColumnLimitsRemainAdmitted() async throws {
        try await Task.detached(priority: .utility) {
            for rows in [Array(repeating: [], count: 256),
                         Array(repeating: Array(repeating: "", count: 64), count: 64),
                         [Array(repeating: String(repeating: "x", count: 4096), count: 16)],
                         [[String(repeating: "é", count: 2048)]]] {
                let bytes = try NativeXLSXWriter.encode(rows: rows)
                XCTAssertLessThanOrEqual(bytes.count, NativeXLSXWriter.maximumOutputBytes)
                _ = try Self.inspectZIP(bytes)
            }
        }.value
    }

    func testOversizeAndIllegalXMLTextRejectBeforeSerialization() async throws {
        try await Task.detached(priority: .utility) {
            let excessive: [[[String]]] = [Array(repeating: [], count: 257),
                [Array(repeating: "", count: 65)],
                Array(repeating: Array(repeating: "", count: 64), count: 64) + [[""]],
                [[String(repeating: "x", count: 4097)]], [[String(repeating: "é", count: 2048) + "x"]],
                [Array(repeating: String(repeating: "x", count: 4096), count: 16) + ["x"]]]
            for rows in excessive {
                XCTAssertThrowsError(try NativeXLSXWriter.encode(rows: rows)) {
                    XCTAssertEqual($0 as? NativeXLSXError, .contentTooLarge)
                }
            }
            for scalar in [0, 1, 11, 31, 0xFFFE, 0xFFFF] as [UInt32] {
                XCTAssertThrowsError(try NativeXLSXWriter.encode(rows: [["invalid" + String(UnicodeScalar(scalar)!)]])) {
                    XCTAssertEqual($0 as? NativeXLSXError, .invalidText)
                }
            }
        }.value
    }

    func testStrictRowsDoNotCoerceNumbersBooleansOrNulls() throws {
        for value in [NSNull(), "rows", 7, true, ["flat"], [[7]], [[false]], [[NSNull()]], [["ok"], "bad"]] as [Any] {
            XCTAssertThrowsError(try NativeXLSXWriter.rows(from: value)) {
                XCTAssertEqual($0 as? NativeXLSXError, .invalidRows)
            }
        }
        XCTAssertThrowsError(try NativeXLSXWriter.rows(from: nil))
        XCTAssertEqual(try NativeXLSXWriter.rows(from: [[], ["", "literal"]]), [[], ["", "literal"]])
    }

    func testOutputCapChecksCompletePackageAndWorstCaseEscaping() async throws {
        try await Task.detached(priority: .utility) {
            let rows = [Array(repeating: String(repeating: "\r", count: 4096), count: 16)]
            let bytes = try NativeXLSXWriter.encode(rows: rows)
            XCTAssertLessThanOrEqual(bytes.count, NativeXLSXWriter.maximumOutputBytes)
            XCTAssertEqual(try NativeXLSXWriter.encode(rows: rows, outputByteLimit: bytes.count), bytes)
            for limit in [0, 512, bytes.count - 1, NativeXLSXWriter.maximumOutputBytes + 1] {
                XCTAssertThrowsError(try NativeXLSXWriter.encode(rows: rows, outputByteLimit: limit)) {
                    XCTAssertEqual($0 as? NativeXLSXError, .outputTooLarge)
                }
            }
        }.value
    }

    func testMainThreadAndCancelledOrExpiredRequestsCannotEncode() async throws {
        try await MainActor.run {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertThrowsError(try NativeXLSXWriter.encode(rows: [["main"]])) {
                XCTAssertEqual($0 as? NativeXLSXError, .workerRequired)
            }
        }
        try await Task.detached(priority: .utility) {
            let cancelled = ToolCallCancellation(timeoutSeconds: 10)
            cancelled.cancel()
            XCTAssertThrowsError(try NativeXLSXWriter.encode(rows: [["cancel"]], cancellation: cancelled)) {
                XCTAssertTrue($0 is CancellationError)
            }
            XCTAssertThrowsError(try NativeXLSXWriter.encode(rows: [["expired"]],
                cancellation: ToolCallCancellation(timeoutSeconds: 0))) {
                XCTAssertTrue($0 is ToolCallDeadlineExceeded)
            }
        }.value
    }

    func testToolStrictArgumentsAndCancellationPreserveDestination() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let destination = project.appendingPathComponent("strict.xlsx")
                let prior = Data("preserve destination".utf8)
                try prior.write(to: destination)
                let cases: [([String: Any], String)] = [
                    (["path": 7, "rows": [["text"]]], "invalid_path"),
                    (["path": true, "rows": [["text"]]], "invalid_path"),
                    (["path": " \n", "rows": [["text"]]], "invalid_path"),
                    (["path": "nul\u{0}.xlsx", "rows": [["text"]]], "invalid_path"),
                    (["path": project.appendingPathComponent("no-extension").path, "rows": [["text"]]], "invalid_path"),
                    (["path": destination.path, "rows": [[7]]], "invalid_rows"),
                    (["path": destination.path, "rows": [[false]]], "invalid_rows"),
                    (["path": destination.path, "rows": NSNull()], "invalid_rows"),
                    (["path": destination.path, "rows": [["invalid\u{1}"]]], "invalid_text"),
                    (["path": destination.path, "rows": [[String(repeating: "x", count: 4097)]]], "content_too_large"),
                ]
                for (arguments, code) in cases {
                    let result = try XCTUnwrap(try DocsToolPack().handle(name: "xlsx_write", arguments: arguments,
                        context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(result.ok)
                    XCTAssertEqual(result.payload["code"] as? String, code)
                    XCTAssertEqual(try Data(contentsOf: destination), prior)
                }
                for control in [ToolCallCancellation(timeoutSeconds: 10), ToolCallCancellation(timeoutSeconds: 0)] {
                    if !control.isDeadlineExceeded { control.cancel() }
                    XCTAssertThrowsError(try DocsToolPack().handle(name: "xlsx_write",
                        arguments: ["path": destination.path, "rows": [["cancel"]]], context: nil,
                        clientID: client, app: app, cancellation: control)) {
                        XCTAssertTrue($0 is CancellationError || $0 is ToolCallDeadlineExceeded)
                    }
                }
                XCTAssertEqual(try Data(contentsOf: destination), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), ["strict.xlsx"])
            }
        }.value
    }

    func testToolReplacementPreservesModeMetadataAndBinaryReadback() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let rows = [["literal café 日本語 🙂", "=SUM(A1:A2)"]]
                let existing = project.appendingPathComponent("replace.xlsx")
                try Data("prior".utf8).write(to: existing)
                XCTAssertEqual(Darwin.chmod(existing.path, 0o600), 0)
                for file in [existing, project.appendingPathComponent("fresh.xlsx")] {
                    let result = try app.tools.call(name: "xlsx_write", arguments: ["path": file.path, "rows": rows], clientID: client)
                    XCTAssertTrue(result.ok, "\(result.payload)")
                    let bytes = try Data(contentsOf: file)
                    XCTAssertEqual(result.payload["path"] as? String, file.path)
                    XCTAssertEqual(result.payload["format"] as? String, "xlsx")
                    XCTAssertEqual(result.payload["engine"] as? String, "swift-ooxml-stored-zip")
                    XCTAssertEqual(result.payload["bytes_written"] as? Int, bytes.count)
                    XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                    XCTAssertEqual(result.payload["input_text_bytes"] as? Int, rows[0].reduce(0) { $0 + $1.utf8.count })
                    XCTAssertEqual(result.payload["rows"] as? Int, 1)
                    XCTAssertEqual(result.payload["cells"] as? Int, 2)
                    XCTAssertEqual(result.payload["text_contract"] as? String, "xlsx-text-cells-v1")
                    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue,
                                   file == existing ? 0o600 : 0o644)
                    _ = try Self.inspectZIP(bytes)
                    let read = try app.tools.call(name: "fs_read", arguments: ["path": file.path, "encoding": "base64", "maximum_bytes": 32768], clientID: client)
                    XCTAssertTrue(read.ok, "\(read.payload)")
                    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(read.payload["content"] as? String)), bytes)
                }
            }
        }.value
    }

    func testPinnedWriteRejectsSymlinkParentAndCleansFailedRename() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let outside = root.appendingPathComponent("outside", isDirectory: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let protected = Data("outside protected".utf8)
                try protected.write(to: outside.appendingPathComponent("target.xlsx"))
                let link = project.appendingPathComponent("link", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                let linkResult = try XCTUnwrap(try DocsToolPack().handle(name: "xlsx_write",
                    arguments: ["path": link.appendingPathComponent("target.xlsx").path, "rows": [["blocked"]]],
                    context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(linkResult.ok)
                XCTAssertEqual(linkResult.payload["code"] as? String, "xlsx_write_failed")
                XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("target.xlsx")), protected)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["target.xlsx"])
                let directory = project.appendingPathComponent("directory.xlsx", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try protected.write(to: directory.appendingPathComponent("keep"))
                let rename = try XCTUnwrap(try DocsToolPack().handle(name: "xlsx_write",
                    arguments: ["path": directory.path, "rows": [["blocked"]]], context: nil,
                    clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(rename.ok)
                XCTAssertEqual(rename.payload["code"] as? String, "xlsx_write_failed")
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), protected)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path).sorted(), ["directory.xlsx", "link"])
            }
        }.value
    }

    func testStaleProjectContextAndExplicitGrantPreventWrites() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let outside = root.appendingPathComponent("outside.xlsx")
                let prior = Data("outside sentinel".utf8)
                try prior.write(to: outside)
                let context = try app.projectContexts.invocationContext(for: client)
                let deniedClient = ClientID("xlsx-denied-client")
                _ = try app.projectContexts.bind(owner: ProjectBindingOwner(kind: .mcpClient, id: deniedClient.rawValue),
                    projectID: context.projectID, generation: context.projectGeneration,
                    authorizationScope: ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots,
                        allowedTools: ["fs_read"], networkAllowed: context.authorizationScope.networkAllowed,
                        maximumInlineOutputBytes: context.authorizationScope.maximumInlineOutputBytes))
                let denied = try app.tools.call(name: "xlsx_write", arguments: ["path": outside.path, "rows": [["deny"]]], clientID: deniedClient)
                XCTAssertFalse(denied.ok)
                XCTAssertEqual(denied.payload["code"] as? String, "tool_not_granted")
                XCTAssertEqual(try Data(contentsOf: outside), prior)
                _ = try app.projectContexts.beginReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                _ = try app.projectContexts.completeReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                let file = project.appendingPathComponent("stale.xlsx")
                let stale = try XCTUnwrap(try DocsToolPack().handle(name: "xlsx_write",
                    arguments: ["path": file.path, "rows": [["stale"]]], context: context,
                    clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(stale.ok)
                XCTAssertEqual(stale.payload["code"] as? String, "xlsx_encode_failed")
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            }
        }.value
    }

    func testOwnerAuthorizedHostWideWriteRemainsAvailable() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let outside = root.appendingPathComponent("owner-authorized.xlsx")
                XCTAssertFalse(outside.path.hasPrefix(project.path + "/"))
                let result = try app.tools.call(name: "xlsx_write", arguments: ["path": outside.path, "rows": [["owner text"]]], clientID: client)
                XCTAssertTrue(result.ok, "\(result.payload)")
                let bytes = try Data(contentsOf: outside)
                XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                XCTAssertEqual(try NativeXLSXReader.text(in: bytes), "[Sheet Sheet1]\nA1: owner text")
            }
        }.value
    }

    private static func withToolApp(root: URL, _ operation: (ForgeApp, ClientID, URL) throws -> Void) throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home", isDirectory: true))
        defer { app.shutdown() }
        _ = try app.config.update(["allowed_roots": [project.path]], save: false)
        let client = ClientID("xlsx-writer-tests")
        let result = try app.tools.call(name: "project_memory.initialize", arguments: ["project_path": project.path], clientID: client)
        XCTAssertTrue(result.ok, "\(result.payload)")
        try operation(app, client, project)
    }

    private static func inspectZIP(_ data: Data) throws -> [String: Data] {
        guard data.count >= 22, data.count <= 1_048_576 else { throw FixtureError.malformed }
        func word(_ offset: Int, _ length: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - length else { throw FixtureError.malformed }
            return (0..<length).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        let end = data.count - 22
        XCTAssertEqual(try word(end, 4), 0x06054b50)
        XCTAssertEqual(try word(end + 4, 2), 0); XCTAssertEqual(try word(end + 6, 2), 0)
        XCTAssertEqual(try word(end + 8, 2), 5); XCTAssertEqual(try word(end + 10, 2), 5)
        XCTAssertEqual(try word(end + 20, 2), 0)
        let start = Int(try word(end + 16, 4))
        XCTAssertEqual(start + Int(try word(end + 12, 4)), end)
        var cursor = start, parts: [String: Data] = [:], localEnd = 0
        for _ in 0..<5 {
            XCTAssertEqual(try word(cursor, 4), 0x02014b50)
            XCTAssertEqual(try word(cursor + 6, 2), 20)
            XCTAssertEqual(try word(cursor + 8, 2), 0x0800)
            XCTAssertEqual(try word(cursor + 10, 2), 0)
            let checksum = try word(cursor + 16, 4), size = Int(try word(cursor + 20, 4))
            XCTAssertEqual(try word(cursor + 24, 4), UInt32(size))
            let nameLength = Int(try word(cursor + 28, 2))
            for offset in [30, 32, 34, 36] { XCTAssertEqual(try word(cursor + offset, 2), 0) }
            let local = Int(try word(cursor + 42, 4))
            guard cursor <= end - 46 - nameLength else { throw FixtureError.malformed }
            let nameBytes = data[(cursor + 46)..<(cursor + 46 + nameLength)]
            let name = try XCTUnwrap(String(data: nameBytes, encoding: .utf8))
            XCTAssertEqual(local, localEnd)
            XCTAssertEqual(try word(local, 4), 0x04034b50)
            XCTAssertEqual(try word(local + 6, 2), 0x0800); XCTAssertEqual(try word(local + 8, 2), 0)
            XCTAssertEqual(try word(local + 14, 4), checksum)
            XCTAssertEqual(try word(local + 18, 4), UInt32(size)); XCTAssertEqual(try word(local + 22, 4), UInt32(size))
            XCTAssertEqual(try word(local + 26, 2), UInt32(nameLength)); XCTAssertEqual(try word(local + 28, 2), 0)
            let body = local + 30 + nameLength
            guard body <= start - size else { throw FixtureError.malformed }
            XCTAssertEqual(data[(local + 30)..<body], nameBytes)
            let bytes = Data(data[body..<(body + size)])
            XCTAssertEqual(crc32(bytes), checksum, name)
            XCTAssertNil(parts.updateValue(bytes, forKey: name))
            localEnd = body + size
            cursor += 46 + nameLength
        }
        XCTAssertEqual(localEnd, start); XCTAssertEqual(cursor, end)
        return parts
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFFFFFF
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 0 ? 0 : 0xEDB88320) }
        }
        return ~value
    }

    private static func parseXML(_ data: Data) throws -> CellXML {
        let delegate = CellXML()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? FixtureError.malformed }
        return delegate
    }

    private static func decodedOOXML(_ value: String) throws -> String {
        let expression = try NSRegularExpression(pattern: "_x([0-9A-Fa-f]{4})_")
        let result = NSMutableString(string: value)
        for match in expression.matches(in: value, range: NSRange(location: 0, length: (value as NSString).length)).reversed() {
            let hex = (value as NSString).substring(with: match.range(at: 1))
            let scalar = try XCTUnwrap(UnicodeScalar(try XCTUnwrap(UInt32(hex, radix: 16))))
            result.replaceCharacters(in: match.range, with: String(scalar))
        }
        return result as String
    }

    private enum FixtureError: Error { case malformed }
}

private final class CellXML: NSObject, XMLParserDelegate {
    var elements: [(String, [String: String])] = []
    var rowAddresses: [String] = []
    var cells: [String: String] = [:]
    var cellTypes: [String: String] = [:]
    var preservedTextElements = 0
    private var address: String?
    private var inText = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        elements.append((elementName, attributeDict))
        if elementName == "row", let row = attributeDict["r"] { rowAddresses.append(row) }
        if elementName == "c", let cell = attributeDict["r"] {
            address = cell; cells[cell] = ""; cellTypes[cell] = attributeDict["t"]
        }
        if elementName == "t" {
            inText = true
            if attributeDict["xml:space"] == "preserve" { preservedTextElements += 1 }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText, let address { cells[address, default: ""] += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" { inText = false }
        if elementName == "c" { address = nil }
    }
}

import Foundation
import Darwin
import XCTest
@testable import ForgeConductorCore

final class NativeODSWriterTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-ods-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        temporaryRoot = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryRoot)
    }

    func testStoredZIPCRCFirstMimetypeAndManifestDescribeOneODFWorksheet() async throws {
        try await Task.detached(priority: .utility) {
            let bytes = try NativeODSWriter.encode(rows: [["ODS marker"]])
            let parts = try Self.inspectZIP(bytes)
            XCTAssertEqual(Set(parts.keys), ["mimetype", "content.xml", "META-INF/manifest.xml"])
            XCTAssertEqual(try SafeZIPArchive.inspect(bytes).map(\.path).sorted(), parts.keys.sorted())
            XCTAssertEqual(Self.crc32(Data("123456789".utf8)), 0xCBF43926)
            XCTAssertEqual(parts["mimetype"], Data("application/vnd.oasis.opendocument.spreadsheet".utf8))
            let manifest = try Self.parseXML(XCTUnwrap(parts["META-INF/manifest.xml"]))
            XCTAssertEqual(manifest.elements.first?.0, "manifest:manifest")
            XCTAssertEqual(manifest.elements.first?.1["xmlns:manifest"], "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0")
            XCTAssertEqual(manifest.elements.first?.1["manifest:version"], "1.3")
            XCTAssertEqual(manifest.elements.filter { $0.0 == "manifest:file-entry" }.map { $0.1 }, [
                ["manifest:full-path": "/", "manifest:media-type": "application/vnd.oasis.opendocument.spreadsheet", "manifest:version": "1.3"],
                ["manifest:full-path": "content.xml", "manifest:media-type": "text/xml"],
            ])
            let sheet = try Self.parseXML(XCTUnwrap(parts["content.xml"]))
            XCTAssertEqual(sheet.elements.first?.0, "office:document-content")
            XCTAssertEqual(sheet.elements.first?.1["office:version"], "1.3")
            XCTAssertEqual(sheet.elements.first?.1["xmlns:office"], "urn:oasis:names:tc:opendocument:xmlns:office:1.0")
            XCTAssertEqual(sheet.elements.first?.1["xmlns:table"], "urn:oasis:names:tc:opendocument:xmlns:table:1.0")
            XCTAssertEqual(sheet.elements.first?.1["xmlns:text"], "urn:oasis:names:tc:opendocument:xmlns:text:1.0")
            XCTAssertEqual(sheet.elements.prefix(5).map(\.0), ["office:document-content", "office:body", "office:spreadsheet", "table:table", "table:table-column"])
            XCTAssertEqual(sheet.elements.first { $0.0 == "table:table" }?.1, ["table:name": "Sheet1"])
            XCTAssertEqual(sheet.cells, ["A1": "ODS marker"])
            XCTAssertEqual(sheet.cellTypes, ["A1": "string"])
        }.value
    }

    func testUnicodeXMLWhitespaceAndEscapeLookingLiteralsRetainTextContract() async throws {
        try await Task.detached(priority: .utility) {
            let values = ["café Ελληνικά Русский 日本語 العربية 🙂", "&<>\"'", "  leading\ttrailing  ",
                "line\r\nCR\rLF\nparagraph\u{2029}", "_x0041_ _x005F_ _x00aD_ _X0041_ _xZZZZ_",
                "=SUM(A1:A2)", "+123", "-123", "@literal", "00123", "", " \t\n "]
            let parts = try Self.inspectZIP(NativeODSWriter.encode(rows: [values]))
            let data = try XCTUnwrap(parts["content.xml"])
            let xml = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(xml.contains("&amp;&lt;&gt;\"'"))
            XCTAssertTrue(xml.contains("<text:s text:c=\"2\"/>leading<text:tab/>trailing<text:s text:c=\"2\"/>"))
            XCTAssertTrue(xml.contains("line<text:line-break/>CR<text:line-break/>LF<text:line-break/>paragraph\u{2029}"))
            XCTAssertTrue(xml.contains("_x0041_<text:s text:c=\"1\"/>_x005F_"))
            XCTAssertFalse(xml.contains("table:formula"))
            XCTAssertFalse(xml.contains("office:value=\""))
            let parsed = try Self.parseXML(data)
            for (index, expected) in values.enumerated() {
                let address = "\(Self.column(index + 1))1"
                XCTAssertEqual(parsed.cells[address], expected.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
                XCTAssertEqual(parsed.cellTypes[address], "string")
            }
            XCTAssertEqual(parsed.paragraphs, values.count)
        }.value
    }

    func testBlankAndRaggedRowsUseOnlyRequiredPaddingAndPreserveCoordinates() async throws {
        try await Task.detached(priority: .utility) {
            let blank = try Self.inspectZIP(NativeODSWriter.encode(rows: []))
            let empty = try Self.parseXML(XCTUnwrap(blank["content.xml"]))
            XCTAssertEqual(empty.rows, 1)
            XCTAssertEqual(empty.cells, ["A1": ""])
            XCTAssertEqual(empty.paragraphs, 1)
            let rows = [[], ["", "second"], [], (0..<64).map { "column-\($0 + 1)" }]
            let parts = try Self.inspectZIP(NativeODSWriter.encode(rows: rows))
            let parsed = try Self.parseXML(XCTUnwrap(parts["content.xml"]))
            XCTAssertEqual(parsed.rows, 4)
            XCTAssertEqual(parsed.cells["A1"], "")
            XCTAssertEqual(parsed.cells["A2"], "")
            XCTAssertEqual(parsed.cells["B2"], "second")
            XCTAssertEqual(parsed.cells["A3"], "")
            XCTAssertEqual(parsed.cells["Z4"], "column-26")
            XCTAssertEqual(parsed.cells["AA4"], "column-27")
            XCTAssertEqual(parsed.cells["BL4"], "column-64")
            XCTAssertEqual(parsed.cells.count, 68)
            XCTAssertEqual(parsed.elements.first { $0.0 == "table:table-column" }?.1, ["table:number-columns-repeated": "64"])
        }.value
    }

    func testWriterOutputFeedsNativeReaderWithoutPackageXMLInstructions() async throws {
        try await Task.detached(priority: .utility) {
            let values = ["café 日本語 🙂", "_x0041_ _X0041_", "CR\rLF\nTAB\t", "=SUM(A1:A2)"]
            let bytes = try NativeODSWriter.encode(rows: [values])
            XCTAssertEqual(try NativeODSReader.text(in: bytes),
                "[Sheet Sheet1]\nA1: café 日本語 🙂\nB1: _x0041_ _X0041_\nC1: CR\nLF\nTAB\t\nD1: =SUM(A1:A2)")
            XCTAssertEqual(try NativeODSReader.text(in: NativeODSWriter.encode(rows: [])), "")
            XCTAssertEqual(try NativeODSReader.text(in: NativeODSWriter.encode(rows: [[], ["", "second"]])), "[Sheet Sheet1]\nB2: second")
        }.value
    }

    func testExactTextCellRowAndColumnBoundsIncludeRequiredBlankPadding() async throws {
        try await Task.detached(priority: .utility) {
            let fullCells = Array(repeating: Array(repeating: "", count: 64), count: 64)
            for rows in [Array(repeating: [], count: 256), fullCells,
                         fullCells + Array(repeating: [], count: 192),
                         [Array(repeating: String(repeating: "x", count: 4096), count: 16)],
                         [[String(repeating: "é", count: 2048)]]] {
                let bytes = try NativeODSWriter.encode(rows: rows)
                XCTAssertLessThanOrEqual(bytes.count, NativeODSWriter.maximumOutputBytes)
                _ = try Self.inspectZIP(bytes)
                _ = try NativeODSReader.text(in: bytes)
            }
            let padded = try Self.inspectZIP(NativeODSWriter.encode(rows: fullCells + Array(repeating: [], count: 192)))
            XCTAssertEqual(try Self.parseXML(XCTUnwrap(padded["content.xml"])).cells.count, 4288)
        }.value
    }

    func testExcessiveDimensionsUTF8AndIllegalXMLScalarsAreRejected() async throws {
        try await Task.detached(priority: .utility) {
            let excessive: [[[String]]] = [Array(repeating: [], count: 257), [Array(repeating: "", count: 65)],
                Array(repeating: Array(repeating: "", count: 64), count: 64) + [[""]],
                [[String(repeating: "x", count: 4097)]], [[String(repeating: "é", count: 2048) + "x"]],
                [Array(repeating: String(repeating: "x", count: 4096), count: 16) + ["x"]]]
            for rows in excessive {
                XCTAssertThrowsError(try NativeODSWriter.encode(rows: rows)) { XCTAssertEqual($0 as? NativeODSError, .contentTooLarge) }
            }
            for scalar in [0, 1, 11, 31, 0xFFFE, 0xFFFF] as [UInt32] {
                XCTAssertThrowsError(try NativeODSWriter.encode(rows: [["invalid" + String(UnicodeScalar(scalar)!)]])) {
                    XCTAssertEqual($0 as? NativeODSError, .invalidText)
                }
            }
        }.value
    }

    func testStrictRowsRejectNumbersBooleansNullsAndFlatArrays() throws {
        for value in [NSNull(), "rows", 7, true, ["flat"], [[7]], [[false]], [[NSNull()]], [["ok"], "bad"]] as [Any] {
            XCTAssertThrowsError(try NativeODSWriter.rows(from: value)) { XCTAssertEqual($0 as? NativeODSError, .invalidRows) }
        }
        XCTAssertThrowsError(try NativeODSWriter.rows(from: nil))
        XCTAssertEqual(try NativeODSWriter.rows(from: [[], ["", "literal"]]), [[], ["", "literal"]])
    }

    func testCompletePackageOutputCapIncludesWorstCaseEscaping() async throws {
        try await Task.detached(priority: .utility) {
            let rows = [Array(repeating: String(repeating: "&", count: 4096), count: 16)]
            let bytes = try NativeODSWriter.encode(rows: rows)
            XCTAssertLessThanOrEqual(bytes.count, NativeODSWriter.maximumOutputBytes)
            XCTAssertEqual(try NativeODSWriter.encode(rows: rows, outputByteLimit: bytes.count), bytes)
            for limit in [0, 512, bytes.count - 1, NativeODSWriter.maximumOutputBytes + 1] {
                XCTAssertThrowsError(try NativeODSWriter.encode(rows: rows, outputByteLimit: limit)) { XCTAssertEqual($0 as? NativeODSError, .outputTooLarge) }
            }
        }.value
    }

    func testXMLNodeExactBoundaryAndOneAdditionalBreak() async throws {
        try await Task.detached(priority: .utility) {
            var row = Array(repeating: String(repeating: "\n", count: 4096), count: 7)
            row.append(String(repeating: "\n", count: 4074))
            let bytes = try NativeODSWriter.encode(rows: [row])
            let parts = try Self.inspectZIP(bytes)
            XCTAssertEqual(try Self.parseXML(XCTUnwrap(parts["content.xml"])).elements.count, 32768)
            XCTAssertEqual(try NativeODSReader.text(in: bytes), "")
            row[7] += "\n"
            XCTAssertThrowsError(try NativeODSWriter.encode(rows: [row])) { XCTAssertEqual($0 as? NativeODSError, .structureTooLarge) }
        }.value
    }

    func testMainThreadCancelledAndExpiredRequestsCannotEncode() async throws {
        try await MainActor.run {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertThrowsError(try NativeODSWriter.encode(rows: [["main"]])) { XCTAssertEqual($0 as? NativeODSError, .workerRequired) }
        }
        try await Task.detached(priority: .utility) {
            let cancelled = ToolCallCancellation(timeoutSeconds: 10)
            cancelled.cancel()
            XCTAssertThrowsError(try NativeODSWriter.encode(rows: [["cancel"]], cancellation: cancelled)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try NativeODSWriter.encode(rows: [["expired"]], cancellation: ToolCallCancellation(timeoutSeconds: 0))) {
                XCTAssertTrue($0 is ToolCallDeadlineExceeded)
            }
        }.value
    }

    func testToolStrictArgumentsStructureAndCancellationPreserveDestination() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let destination = project.appendingPathComponent("strict.ods")
                let prior = Data("preserve destination".utf8)
                try prior.write(to: destination)
                let cases: [([String: Any], String)] = [
                    (["path": 7, "rows": [["text"]]], "invalid_path"), (["path": true, "rows": [["text"]]], "invalid_path"),
                    (["path": " \n", "rows": [["text"]]], "invalid_path"), (["path": "nul\u{0}.ods", "rows": [["text"]]], "invalid_path"),
                    (["path": project.appendingPathComponent("no-extension").path, "rows": [["text"]]], "invalid_path"),
                    (["path": destination.path, "rows": [[7]]], "invalid_rows"), (["path": destination.path, "rows": [[false]]], "invalid_rows"),
                    (["path": destination.path, "rows": NSNull()], "invalid_rows"), (["path": destination.path, "rows": [["invalid\u{1}"]]], "invalid_text"),
                    (["path": destination.path, "rows": [[String(repeating: "x", count: 4097)]]], "content_too_large"),
                    (["path": destination.path, "rows": [Array(repeating: String(repeating: "\n", count: 4096), count: 9)]], "ods_structure_too_large"),
                ]
                for (arguments, code) in cases {
                    let result = try XCTUnwrap(try DocsToolPack().handle(name: "ods_write", arguments: arguments,
                        context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(result.ok)
                    XCTAssertEqual(result.payload["code"] as? String, code)
                    XCTAssertEqual(try Data(contentsOf: destination), prior)
                }
                for control in [ToolCallCancellation(timeoutSeconds: 10), ToolCallCancellation(timeoutSeconds: 0)] {
                    if !control.isDeadlineExceeded { control.cancel() }
                    XCTAssertThrowsError(try DocsToolPack().handle(name: "ods_write", arguments: ["path": destination.path, "rows": [["cancel"]]],
                        context: nil, clientID: client, app: app, cancellation: control)) { XCTAssertTrue($0 is CancellationError || $0 is ToolCallDeadlineExceeded) }
                }
                XCTAssertEqual(try Data(contentsOf: destination), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), ["strict.ods"])
            }
        }.value
    }

    func testToolReplacementModeMetadataBinaryReadbackAndBlankInputCounts() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let rows = [["literal café 日本語 🙂", "=SUM(A1:A2)\r\nnext"]]
                let existing = project.appendingPathComponent("replace.ods")
                try Data("prior".utf8).write(to: existing)
                XCTAssertEqual(Darwin.chmod(existing.path, 0o600), 0)
                for file in [existing, project.appendingPathComponent("fresh.ODS")] {
                    let result = try app.tools.call(name: "ods_write", arguments: ["path": file.path, "rows": rows], clientID: client)
                    XCTAssertTrue(result.ok, "\(result.payload)")
                    let bytes = try Data(contentsOf: file)
                    XCTAssertEqual(result.payload["path"] as? String, file.path)
                    XCTAssertEqual(result.payload["format"] as? String, "ods")
                    XCTAssertEqual(result.payload["engine"] as? String, "swift-odf-stored-zip")
                    XCTAssertEqual(result.payload["bytes_written"] as? Int, bytes.count)
                    XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                    XCTAssertEqual(result.payload["input_text_bytes"] as? Int, rows[0].reduce(0) { $0 + $1.utf8.count })
                    XCTAssertEqual(result.payload["rows"] as? Int, 1)
                    XCTAssertEqual(result.payload["cells"] as? Int, 2)
                    XCTAssertEqual(result.payload["text_contract"] as? String, "ods-text-cells-v1")
                    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, file == existing ? 0o600 : 0o644)
                    let read = try app.tools.call(name: "fs_read", arguments: ["path": file.path, "encoding": "base64", "maximum_bytes": 32768], clientID: client)
                    XCTAssertTrue(read.ok, "\(read.payload)")
                    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(read.payload["content"] as? String)), bytes)
                    XCTAssertEqual(try Self.parseXML(XCTUnwrap(Self.inspectZIP(bytes)["content.xml"])).cells["B1"], "=SUM(A1:A2)\nnext")
                }
                let blank = project.appendingPathComponent("blank.ods")
                let result = try app.tools.call(name: "ods_write", arguments: ["path": blank.path, "rows": []], clientID: client)
                XCTAssertTrue(result.ok, "\(result.payload)")
                XCTAssertEqual(result.payload["rows"] as? Int, 0)
                XCTAssertEqual(result.payload["cells"] as? Int, 0)
                XCTAssertEqual(result.payload["input_text_bytes"] as? Int, 0)
                XCTAssertEqual(try NativeODSReader.text(in: Data(contentsOf: blank)), "")
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
                try protected.write(to: outside.appendingPathComponent("target.ods"))
                let link = project.appendingPathComponent("link", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                let linkResult = try XCTUnwrap(try DocsToolPack().handle(name: "ods_write", arguments: ["path": link.appendingPathComponent("target.ods").path, "rows": [["blocked"]]],
                    context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(linkResult.ok)
                XCTAssertEqual(linkResult.payload["code"] as? String, "ods_write_failed")
                XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("target.ods")), protected)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["target.ods"])
                let directory = project.appendingPathComponent("directory.ods", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try protected.write(to: directory.appendingPathComponent("keep"))
                let rename = try XCTUnwrap(try DocsToolPack().handle(name: "ods_write", arguments: ["path": directory.path, "rows": [["blocked"]]], context: nil,
                    clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(rename.ok)
                XCTAssertEqual(rename.payload["code"] as? String, "ods_write_failed")
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), protected)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path).sorted(), ["directory.ods", "link"])
            }
        }.value
    }

    func testStaleProjectContextAndExplicitGrantPreventWrites() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let outside = root.appendingPathComponent("outside.ods")
                let prior = Data("outside sentinel".utf8)
                try prior.write(to: outside)
                let context = try app.projectContexts.invocationContext(for: client)
                let deniedClient = ClientID("ods-denied-client")
                _ = try app.projectContexts.bind(owner: ProjectBindingOwner(kind: .mcpClient, id: deniedClient.rawValue), projectID: context.projectID,
                    generation: context.projectGeneration, authorizationScope: ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots,
                        allowedTools: ["fs_read"], networkAllowed: context.authorizationScope.networkAllowed,
                        maximumInlineOutputBytes: context.authorizationScope.maximumInlineOutputBytes))
                let denied = try app.tools.call(name: "ods_write", arguments: ["path": outside.path, "rows": [["deny"]]], clientID: deniedClient)
                XCTAssertFalse(denied.ok)
                XCTAssertEqual(denied.payload["code"] as? String, "tool_not_granted")
                XCTAssertEqual(try Data(contentsOf: outside), prior)
                _ = try app.projectContexts.beginReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                _ = try app.projectContexts.completeReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                let file = project.appendingPathComponent("stale.ods")
                let stale = try XCTUnwrap(try DocsToolPack().handle(name: "ods_write", arguments: ["path": file.path, "rows": [["stale"]]],
                    context: context, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(stale.ok)
                XCTAssertEqual(stale.payload["code"] as? String, "ods_encode_failed")
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            }
        }.value
    }

    func testOwnerAuthorizedHostWideWriteAndXLSXNeighborRemainAvailable() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let outside = root.appendingPathComponent("owner-authorized.ods")
                XCTAssertFalse(outside.path.hasPrefix(project.path + "/"))
                let result = try app.tools.call(name: "ods_write", arguments: ["path": outside.path, "rows": [["owner text"]]], clientID: client)
                XCTAssertTrue(result.ok, "\(result.payload)")
                let bytes = try Data(contentsOf: outside)
                XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                XCTAssertEqual(try NativeODSReader.text(in: bytes), "[Sheet Sheet1]\nA1: owner text")
                let xlsx = project.appendingPathComponent("neighbor.xlsx")
                let neighbor = try app.tools.call(name: "xlsx_write", arguments: ["path": xlsx.path, "rows": [["prior CR\rtext"]]], clientID: client)
                XCTAssertTrue(neighbor.ok, "\(neighbor.payload)")
                XCTAssertEqual(neighbor.payload["text_contract"] as? String, "xlsx-text-cells-v1")
                XCTAssertEqual(try NativeXLSXReader.text(in: Data(contentsOf: xlsx)), "[Sheet Sheet1]\nA1: prior CR\rtext")
            }
        }.value
    }

    private static func withToolApp(root: URL, _ operation: (ForgeApp, ClientID, URL) throws -> Void) throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home", isDirectory: true))
        defer { app.shutdown() }
        _ = try app.config.update(["allowed_roots": [project.path]], save: false)
        let client = ClientID("ods-writer-tests")
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
        let names = ["mimetype", "content.xml", "META-INF/manifest.xml"]
        let end = data.count - 22
        XCTAssertEqual(try word(end, 4), 0x06054b50)
        for offset in [4, 6, 20] { XCTAssertEqual(try word(end + offset, 2), 0) }
        XCTAssertEqual(try word(end + 8, 2), 3); XCTAssertEqual(try word(end + 10, 2), 3)
        let start = Int(try word(end + 16, 4))
        XCTAssertEqual(start + Int(try word(end + 12, 4)), end)
        var cursor = start, parts: [String: Data] = [:], localEnd = 0
        for expectedName in names {
            XCTAssertEqual(try word(cursor, 4), 0x02014b50)
            XCTAssertEqual(try word(cursor + 6, 2), 20)
            XCTAssertEqual(try word(cursor + 8, 2), 0x0800); XCTAssertEqual(try word(cursor + 10, 2), 0)
            let checksum = try word(cursor + 16, 4), size = Int(try word(cursor + 20, 4))
            XCTAssertEqual(try word(cursor + 24, 4), UInt32(size))
            let nameLength = Int(try word(cursor + 28, 2))
            for offset in [30, 32, 34, 36] { XCTAssertEqual(try word(cursor + offset, 2), 0) }
            let local = Int(try word(cursor + 42, 4))
            guard cursor <= end - 46 - nameLength else { throw FixtureError.malformed }
            let nameBytes = data[(cursor + 46)..<(cursor + 46 + nameLength)]
            let name = try XCTUnwrap(String(data: nameBytes, encoding: .utf8))
            XCTAssertEqual(name, expectedName)
            XCTAssertEqual(local, localEnd)
            XCTAssertEqual(try word(local, 4), 0x04034b50)
            XCTAssertEqual(try word(local + 6, 2), 0x0800); XCTAssertEqual(try word(local + 8, 2), 0)
            XCTAssertEqual(try word(local + 14, 4), checksum)
            XCTAssertEqual(try word(local + 18, 4), UInt32(size)); XCTAssertEqual(try word(local + 22, 4), UInt32(size))
            XCTAssertEqual(try word(local + 26, 2), UInt32(nameLength)); XCTAssertEqual(try word(local + 28, 2), 0)
            let body = local + 30 + nameLength
            guard body <= start - size else { throw FixtureError.malformed }
            XCTAssertEqual(data[(local + 30)..<body], nameBytes)
            if name == "mimetype" { XCTAssertEqual(body, 38) }
            let bytes = Data(data[body..<(body + size)])
            XCTAssertEqual(crc32(bytes), checksum, name)
            XCTAssertNil(parts.updateValue(bytes, forKey: name))
            localEnd = body + size; cursor += 46 + nameLength
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

    fileprivate static func column(_ oneBased: Int) -> String {
        var value = oneBased, text = ""
        while value > 0 { value -= 1; text = String(UnicodeScalar(65 + value % 26)!) + text; value /= 26 }
        return text
    }

    private static func parseXML(_ data: Data) throws -> ODSCellXML {
        let delegate = ODSCellXML()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? FixtureError.malformed }
        return delegate
    }

    private enum FixtureError: Error { case malformed }
}

private final class ODSCellXML: NSObject, XMLParserDelegate {
    var elements: [(String, [String: String])] = []
    var rows = 0, paragraphs = 0
    var cells: [String: String] = [:], cellTypes: [String: String] = [:]
    private var nextColumn = 0
    private var address: String?
    private var inParagraph = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        elements.append((elementName, attributeDict))
        if elementName == "table:table-row" { rows += 1; nextColumn = 0 }
        if elementName == "table:table-cell" {
            nextColumn += 1
            let cell = "\(NativeODSWriterTests.column(nextColumn))\(rows)"
            address = cell; cells[cell] = ""; cellTypes[cell] = attributeDict["office:value-type"]
        }
        if elementName == "text:p" { inParagraph = true; paragraphs += 1 }
        if inParagraph, let address {
            switch elementName {
            case "text:s":
                if let count = Int(attributeDict["text:c"] ?? "1"), count > 0, count <= 4096 {
                    cells[address, default: ""] += String(repeating: " ", count: count)
                } else { parser.abortParsing() }
            case "text:tab": cells[address, default: ""] += "\t"
            case "text:line-break": cells[address, default: ""] += "\n"
            default: break
            }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inParagraph, let address { cells[address, default: ""] += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "text:p" { inParagraph = false }
        if elementName == "table:table-cell" { address = nil }
    }
}

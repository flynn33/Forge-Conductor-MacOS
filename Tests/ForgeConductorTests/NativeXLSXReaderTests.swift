import XCTest
@testable import ForgeConductorCore

final class NativeXLSXReaderTests: XCTestCase {
    private static let namespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    func testInlineCellValuesExcludePackageXMLAndDecodeExactUnicode() async throws {
        let parts = Self.parts(cells: "<c r=\"A1\" t=\"inlineStr\"><is><t xml:space=\"preserve\"> café 日本語 🙂 &amp; &lt;literal&gt; _x005F_x0041_ _x000D_ </t></is></c>")
        let text = try await Self.read(parts)
        XCTAssertEqual(text, "[Sheet Sheet1]\nA1:  café 日本語 🙂 & <literal> _x0041_ \r ")
        XCTAssertFalse(text.contains("<worksheet"))
        XCTAssertFalse(text.contains("Relationships"))
    }

    func testSharedRichStringsExcludePhoneticAnnotationsAndKeepSheetOrder() async throws {
        var parts = Self.parts(cells: "<c r=\"B9\" t=\"s\"><v>0</v></c><c r=\"C9\" t=\"b\"><v>1</v></c><c r=\"D9\"><f>1+1</f><v>2</v></c>")
        parts["xl/sharedStrings.xml"] = "<sst xmlns=\"\(Self.namespace)\"><si><r><t>café </t></r><rPh sb=\"0\" eb=\"1\"><t>PHONETIC</t></rPh><r><t>日本語 🙂</t></r></si></sst>"
        parts["xl/_rels/workbook.xml.rels"] = Self.rels("<Relationship Id=\"sheet\" Type=\"\(Self.relationships)/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"strings\" Type=\"\(Self.relationships)/sharedStrings\" Target=\"sharedStrings.xml\"/>")
        let text = try await Self.read(parts)
        XCTAssertEqual(text, "[Sheet Sheet1]\nB9: café 日本語 🙂\nC9: TRUE\nD9: 2")
    }

    func testRelationshipsResolveAlternatePartPathsAndNamespacePrefixes() async throws {
        var parts = Self.parts(cells: "")
        parts.removeValue(forKey: "xl/workbook.xml")
        parts.removeValue(forKey: "xl/_rels/workbook.xml.rels")
        parts.removeValue(forKey: "xl/worksheets/sheet1.xml")
        parts["_rels/.rels"] = Self.rels("<Relationship Id=\"book\" Type=\"\(Self.relationships)/officeDocument\" Target=\"books/book.xml\"/>")
        parts["books/book.xml"] = "<s:workbook xmlns:s=\"\(Self.namespace)\" xmlns:link=\"\(Self.relationships)\"><s:sheets><s:sheet name=\"Different\" sheetId=\"1\" link:id=\"sheet\"/></s:sheets></s:workbook>"
        parts["books/_rels/book.xml.rels"] = Self.rels("<Relationship Id=\"sheet\" Type=\"\(Self.relationships)/worksheet\" Target=\"../values/page.xml\"/>")
        parts["values/page.xml"] = "<s:worksheet xmlns:s=\"\(Self.namespace)\"><s:sheetData><s:row r=\"1\"><s:c r=\"A1\" t=\"inlineStr\"><s:is><s:t>mapped</s:t></s:is></s:c></s:row></s:sheetData></s:worksheet>"
        let text = try await Self.read(parts)
        XCTAssertEqual(text, "[Sheet Different]\nA1: mapped")
    }

    func testBlankAndWhitespaceCellsProduceNoInstructionText() async throws {
        let blank = try await Self.read(Self.parts(cells: ""))
        let whitespace = try await Self.read(Self.parts(cells: "<c r=\"A1\" t=\"inlineStr\"><is><t> \n\t </t></is></c>"))
        XCTAssertEqual(blank, "")
        XCTAssertEqual(whitespace, "")
    }

    func testEscapeDecodingUsesEachRichTextNodeAndCDATADeclarationsRemainLiteral() async throws {
        let cells = "<c r=\"A1\" t=\"inlineStr\"><is><r><t>_x00</t></r><r><t>41_</t></r></is></c><c r=\"B1\" t=\"inlineStr\"><is><t><![CDATA[<!DOCTYPE html> <!ENTITY literal>]]></t></is></c>"
        var parts = Self.parts(cells: cells)
        parts["xl/worksheets/sheet1.xml"] = "<?test literal <!DOCTYPE?>" + parts["xl/worksheets/sheet1.xml"]! + "<!-- <!ENTITY comment> -->"
        let text = try await Self.read(parts)
        XCTAssertEqual(text, "[Sheet Sheet1]\nA1: _x0041_\nB1: <!DOCTYPE html> <!ENTITY literal>")
    }

    func testExternalTraversalAndMissingRelationshipsAreRejected() async throws {
        for target in ["../../outside.xml", "https://example.invalid/sheet.xml", "worksheets/missing.xml"] {
            var parts = Self.parts(cells: "")
            parts["xl/_rels/workbook.xml.rels"] = Self.rels("<Relationship Id=\"sheet\" Type=\"\(Self.relationships)/worksheet\" Target=\"\(target)\"/>")
            await Self.assertRejected(parts)
        }
        var parts = Self.parts(cells: "")
        parts["xl/_rels/workbook.xml.rels"] = Self.rels("<Relationship Id=\"sheet\" Type=\"\(Self.relationships)/worksheet\" Target=\"worksheets/sheet1.xml\" TargetMode=\"External\"/>")
        await Self.assertRejected(parts)
    }

    func testDTDMalformedXMLAndNamespaceSpoofingAreRejected() async throws {
        for xml in [
            "<!DOCTYPE worksheet [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><worksheet xmlns=\"\(Self.namespace)\"><sheetData>&secret;</sheetData></worksheet>",
            "<worksheet xmlns=\"\(Self.namespace)\"><sheetData>",
            "<worksheet xmlns=\"urn:unrelated\"><sheetData/></worksheet>",
        ] {
            var parts = Self.parts(cells: "")
            parts["xl/worksheets/sheet1.xml"] = xml
            await Self.assertRejected(parts)
        }
    }

    func testBadCellReferencesSharedIndexesAndUncachedFormulasAreRejected() async throws {
        for cells in [
            "<c r=\"A0\"><v>1</v></c>", "<c r=\"XFE1\"><v>1</v></c>",
            "<c r=\"A1\"><v>1</v></c><c r=\"A1\"><v>2</v></c>",
            "<c r=\"A1\" t=\"s\"><v>0</v></c>",
            "<c r=\"A1\"><f>WEBSERVICE(\"https://example.invalid\")</f></c>",
            "<c r=\"A1\" t=\"b\"><v>true</v></c>",
            "<c r=\"A1\" t=\"n\"><is><t>IMPORTANT</t></is></c>",
            "<c r=\"A1\"><v><child>lost</child></v></c>",
            "<c r=\"A1\"><v>not a number</v></c>",
            "<c r=\"A1\" t=\"inlineStr\"><is><t><child>lost</child></t></is></c>",
        ] { await Self.assertRejected(Self.parts(cells: cells)) }
    }

    func testCellDepthAndExpandedByteLimitsAreRejected() async throws {
        await Self.assertRejected(Self.parts(cells: "<c r=\"A1\" t=\"inlineStr\"><is><t>\(String(repeating: "a", count: 4_097))</t></is></c>"))
        var deep = Self.parts(cells: "")
        deep["xl/worksheets/sheet1.xml"] = "<worksheet xmlns=\"\(Self.namespace)\">" + String(repeating: "<nested>", count: 33) + String(repeating: "</nested>", count: 33) + "</worksheet>"
        await Self.assertRejected(deep)
        var large = Self.parts(cells: "")
        large["xl/unused.xml"] = String(repeating: "a", count: NativeXLSXReader.maximumPartBytes + 1)
        await Self.assertRejected(large)
    }

    func testEscapeDecodingRejectsUnpairedSurrogatesAndPreservesLiteralEscapes() throws {
        XCTAssertEqual(try NativeXLSXReader.decodeEscapes("_xD83D__xDE42_ _x005F_x0041_"), "🙂 _x0041_")
        XCTAssertThrowsError(try NativeXLSXReader.decodeEscapes("_xD800_"))
        XCTAssertThrowsError(try NativeXLSXReader.decodeEscapes("_xDC00_"))
    }

    func testImporterPublishesSingleCellDocumentRetainsOriginalAndPagesExactText() async throws {
        try await Task.detached(priority: .utility) {
            let root = try Self.root()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("instructions.XLSX")
            let original = try Self.archive(Self.parts(cells: "<c r=\"A1\" t=\"inlineStr\"><is><t>café 日本語 🙂 &amp; &lt;literal&gt;</t></is></c>"), root: root)
            try original.write(to: source)
            let paths = AppPaths(home: root.appendingPathComponent("home"))
            let store = try ProjectInstructionQueueStore(paths: paths)
            let project = ProjectID()
            let snapshot = try store.importPackage(sourceURL: source, projectID: project, generation: .initial)
            let package = try XCTUnwrap(snapshot.packages.first)
            XCTAssertEqual(package.documentCount, 1)
            XCTAssertEqual(package.unresolvedDocumentCount, 0)
            let catalog = try store.catalogPage(contentSHA256: package.contentSHA256, projectID: project, generation: .initial, runID: nil, cursor: 0, limit: 10)
            let document = try XCTUnwrap(catalog.documents.first)
            XCTAssertEqual(document["source_path"], "instructions.XLSX")
            XCTAssertEqual(document["status"], "converted_instruction")
            XCTAssertEqual(document["converter"], "native-xlsx-cells-v1")
            XCTAssertEqual(document["original_sha256"], JSONSupport.sha256Hex(original))
            let retained = paths.instructionPackageStoreDir.appendingPathComponent(package.contentSHA256).appendingPathComponent("originals/instructions.XLSX")
            XCTAssertEqual(try Data(contentsOf: retained), original)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: retained.path)[.posixPermissions] as? NSNumber)?.intValue, 0o400)
            var text = "", offset = 0
            for _ in 0..<16 {
                let page = try store.readDocument(contentSHA256: package.contentSHA256, documentID: try XCTUnwrap(document["id"]), projectID: project, generation: .initial, runID: nil, byteOffset: offset, maximumBytes: 17)
                text += page.content
                if let next = page.nextByteOffset { XCTAssertGreaterThan(next, offset); offset = next } else { break }
            }
            XCTAssertEqual(text, "[Sheet Sheet1]\nA1: café 日本語 🙂 & <literal>")
            XCTAssertEqual(package.instructionByteCount, text.utf8.count)
            XCTAssertEqual(document["canonical_sha256"], JSONSupport.sha256Hex(Data(text.utf8)))
            XCTAssertThrowsError(try store.readDocument(contentSHA256: package.contentSHA256, documentID: try XCTUnwrap(document["id"]), projectID: ProjectID(), generation: .initial, runID: nil, byteOffset: 0, maximumBytes: 17))
        }.value
    }

    func testImporterRetainsBlankAndMalformedWorkbooksAsUnresolvedWithoutRawXMLInstructions() async throws {
        try await Task.detached(priority: .utility) {
            for malformed in [false, true] {
                let root = try Self.root()
                defer { try? FileManager.default.removeItem(at: root) }
                let source = root.appendingPathComponent("blank.xlsx")
                let original = malformed ? Data("<xml>must not become instructions</xml>".utf8) : try Self.archive(Self.parts(cells: ""), root: root)
                try original.write(to: source)
                let paths = AppPaths(home: root.appendingPathComponent("home"))
                let store = try ProjectInstructionQueueStore(paths: paths)
                let project = ProjectID()
                let package = try XCTUnwrap(store.importPackage(sourceURL: source, projectID: project, generation: .initial).packages.first)
                XCTAssertEqual(package.documentCount, 1)
                XCTAssertEqual(package.instructionByteCount, 0)
                XCTAssertEqual(package.unresolvedDocumentCount, 1)
                XCTAssertEqual(package.asDictionary()["import_ready"] as? Bool, false)
                XCTAssertThrowsError(try store.start(projectID: project, generation: .initial))
                let catalog = try store.catalogPage(contentSHA256: package.contentSHA256, projectID: project, generation: .initial, runID: nil, cursor: 0, limit: 10)
                let document = try XCTUnwrap(catalog.documents.first)
                XCTAssertEqual(document["status"], malformed ? "unresolved_conversion" : "unrepresented_visual_structural")
                XCTAssertEqual(document["canonical_bytes"], "0")
                XCTAssertThrowsError(try store.documentReferences(contentSHA256: package.contentSHA256))
                XCTAssertEqual(try Data(contentsOf: paths.instructionPackageStoreDir.appendingPathComponent(package.contentSHA256).appendingPathComponent("originals/blank.xlsx")), original)
            }
        }.value
    }

    private static func parts(cells: String) -> [String: String] {
        [
            "[Content_Types].xml": "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>",
            "_rels/.rels": rels("<Relationship Id=\"book\" Type=\"\(relationships)/officeDocument\" Target=\"xl/workbook.xml\"/>"),
            "xl/workbook.xml": "<workbook xmlns=\"\(namespace)\" xmlns:r=\"\(relationships)\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"sheet\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": rels("<Relationship Id=\"sheet\" Type=\"\(relationships)/worksheet\" Target=\"worksheets/sheet1.xml\"/>"),
            "xl/worksheets/sheet1.xml": "<worksheet xmlns=\"\(namespace)\"><sheetData><row r=\"1\">\(cells)</row></sheetData></worksheet>",
        ]
    }
    private static func rels(_ contents: String) -> String {
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(contents)</Relationships>"
    }
    private static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-xlsx-reader-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private static func archive(_ parts: [String: String], root: URL) throws -> Data {
        let folder = root.appendingPathComponent("parts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for (name, value) in parts {
            let file = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: file)
        }
        let destination = root.appendingPathComponent("fixture.zip")
        let process = Process()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", folder.path, destination.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 10) != .success {
            process.terminate(); _ = finished.wait(timeout: .now() + 5)
            throw NativeXLSXReader.Failure.invalid("test fixture archiver exceeded deadline")
        }
        guard process.terminationStatus == 0 else { throw NativeXLSXReader.Failure.invalid("test fixture archiver failed") }
        return try Data(contentsOf: destination)
    }
    private static func read(_ parts: [String: String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            return try NativeXLSXReader.text(in: archive(parts, root: root))
        }.value
    }
    private static func assertRejected(_ parts: [String: String], file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await read(parts); XCTFail("Expected workbook rejection", file: file, line: line) }
        catch { XCTAssertFalse(error is CancellationError, file: file, line: line) }
    }
}

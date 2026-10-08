import XCTest
@testable import ForgeConductorCore

final class NativeODSReaderTests: XCTestCase {
    private static let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    private static let table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    private static let text = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    private static let manifest = "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"

    func testExactUnicodeStringCellExcludesPackageXMLAndKeepsLiteralEscapes() async throws {
        let value = try await Self.read(Self.parts(rows: Self.row(Self.cell("café 日本語 🙂 &amp; &lt;literal&gt; _x0041_"))))
        XCTAssertEqual(value, "[Sheet Sheet1]\nA1: café 日本語 🙂 & <literal> _x0041_")
        XCTAssertFalse(value.contains("office:document-content"))
        XCTAssertFalse(value.contains("manifest:file-entry"))
    }

    func testMixedRunsAndExplicitWhitespaceKeepSourceOrderAndParagraphBoundaries() async throws {
        let paragraphs = "<text:p>  before<text:span>inside</text:span>after  <text:s text:c=\"2\"/><text:tab/><text:line-break/>tail  </text:p><text:p/><text:p>last</text:p>"
        let value = try await Self.read(Self.parts(rows: Self.row("<table:table-cell office:value-type=\"string\">\(paragraphs)</table:table-cell>")))
        XCTAssertEqual(value, "[Sheet Sheet1]\nA1: beforeinsideafter   \t\ntail\n\nlast")
        let leading = try await Self.read(Self.parts(rows: Self.row(Self.cell("<text:s text:c=\"2\"/>a<text:s text:c=\"3\"/>"))))
        XCTAssertEqual(leading, "[Sheet Sheet1]\nA1:   a   ")
    }

    func testParagraphRawWhitespaceCollapsesAcrossRunsWhileExplicitMarkersStayLiteral() async throws {
        let value = try await Self.read(Self.parts(rows: Self.row(Self.cell(" \t before <text:span> \n inside </text:span> after\r\n "))))
        XCTAssertEqual(value, "[Sheet Sheet1]\nA1: before inside after")
        let literal = try await Self.read(Self.parts(rows: Self.row(Self.cell("<![CDATA[<!DOCTYPE literal> _x0041_]]>"))))
        XCTAssertEqual(literal, "[Sheet Sheet1]\nA1: <!DOCTYPE literal> _x0041_")
    }

    func testCachedScalarsAndCachedFormulaTextAreReadWithoutEvaluation() async throws {
        let cells = """
        <table:table-cell office:value-type="float" office:value="2" table:formula="of:=1+1"/>
        <table:table-cell office:value-type="boolean" office:boolean-value="true"/>
        <table:table-cell office:value-type="date" office:date-value="2026-10-08"/>
        <table:table-cell office:value-type="time" office:time-value="PT1H"/>
        <table:table-cell office:value-type="currency" office:value="12.50"/>
        <table:table-cell office:value-type="string" office:string-value="cached _x0041_"/>
        <table:table-cell office:value-type="float" office:value="2"><text:p>two</text:p></table:table-cell>
        """
        let value = try await Self.read(Self.parts(rows: Self.row(cells)))
        XCTAssertEqual(value, "[Sheet Sheet1]\nA1: 2\nB1: TRUE\nC1: 2026-10-08\nD1: PT1H\nE1: 12.50\nF1: cached _x0041_\nG1: two")
    }

    func testRepeatedRowsAndCellsPreserveCoordinatesWithinSharedBudgets() async throws {
        let rows = "<table:table-row table:number-rows-repeated=\"2\"><table:table-cell table:number-columns-repeated=\"2\"/>\(Self.cell("value", attributes: "table:number-columns-repeated=\"2\""))</table:table-row>"
            + "<table:table-row-group><table:table-row><table:table-cell/>\(Self.cell("last"))</table:table-row></table:table-row-group>"
        let value = try await Self.read(Self.parts(rows: rows))
        XCTAssertEqual(value, "[Sheet Sheet1]\nC1: value\nD1: value\nC2: value\nD2: value\nB3: last")
    }

    func testBlankCellsAndRepeatedWhitespaceProduceNoInstructions() async throws {
        let rows = "<table:table-row table:number-rows-repeated=\"2\"><table:table-cell table:number-columns-repeated=\"2\"/></table:table-row>"
        let blank = try await Self.read(Self.parts(rows: rows))
        let rawWhitespace = try await Self.read(Self.parts(rows: Self.row(Self.cell(" \t\n "))))
        let explicitWhitespace = try await Self.read(Self.parts(rows: Self.row(Self.cell("<text:s/><text:tab/><text:line-break/>"))))
        XCTAssertEqual(blank, "")
        XCTAssertEqual(rawWhitespace, "")
        XCTAssertEqual(explicitWhitespace, "")
    }

    func testExpandedPhysicalPaddingAndValueCellBoundsAreDistinctAndExact() async throws {
        let exactPhysical = Self.row("<table:table-cell table:number-columns-repeated=\"\(NativeODSReader.maximumPhysicalCells)\"/>")
        let blank = try await Self.read(Self.parts(rows: exactPhysical))
        XCTAssertEqual(blank, "")
        await Self.assertRejected(Self.parts(rows: Self.row("<table:table-cell table:number-columns-repeated=\"\(NativeODSReader.maximumPhysicalCells + 1)\"/>")))
        let multiplied = "<table:table-row table:number-rows-repeated=\"2\"><table:table-cell table:number-columns-repeated=\"\(NativeODSReader.maximumPhysicalCells / 2 + 1)\"/></table:table-row>"
        await Self.assertRejected(Self.parts(rows: multiplied))
        let exactValues = Self.row(Self.cell("x", attributes: "table:number-columns-repeated=\"\(NativeODSReader.maximumValueCells)\""))
        let extracted = try await Self.read(Self.parts(rows: exactValues))
        XCTAssertEqual(extracted.split(separator: "\n").count, NativeODSReader.maximumValueCells + 1)
        await Self.assertRejected(Self.parts(rows: Self.row(Self.cell("x", attributes: "table:number-columns-repeated=\"\(NativeODSReader.maximumValueCells + 1)\""))))
        let padded = Self.row(Self.cell("x", attributes: "table:number-columns-repeated=\"4096\"")) + String(repeating: Self.row("<table:table-cell/>"), count: 256)
        let paddedValue = try await Self.read(Self.parts(rows: padded))
        XCTAssertEqual(paddedValue, extracted)
    }

    func testBadRepeatsUncachedFormulasMergesAndUnsupportedTextDeclineWholeDocument() async {
        for cell in [
            Self.cell("later", attributes: "table:number-columns-repeated=\"0\""),
            Self.cell("later", attributes: "table:number-columns-repeated=\"1.5\""),
            "<table:table-cell office:value-type=\"float\" table:formula=\"of:=1+1\"/>",
            "<table:table-cell office:value-type=\"float\" office:value=\"NaN\"/>",
            "<table:table-cell office:value-type=\"boolean\" office:boolean-value=\"maybe\"/>",
            Self.cell("later", attributes: "table:number-columns-spanned=\"2\""),
            Self.cell("<text:unsupported>must not disappear</text:unsupported>"),
            "<table:covered-table-cell><text:p>must not disappear</text:p></table:covered-table-cell>",
            "<table:covered-table-cell office:value-type=\"boolean\" office:boolean-value=\"true\"/>",
            "<table:covered-table-cell office:string-value=\"phantom\"/>",
            "<table:covered-table-cell table:formula=\"of:=1+1\"/>",
        ] { await Self.assertRejected(Self.parts(rows: Self.row(Self.cell("first") + cell))) }
        await Self.assertRejected(Self.parts(rows: "<table:table-row table:number-rows-repeated=\"0\">\(Self.cell("first"))</table:table-row>"))
    }

    func testUnsupportedCellTextBlocksRejectInsteadOfReturningPartialInstructions() async {
        let list = "<text:list><text:list-item><text:p>must not disappear</text:p></text:list-item></text:list>"
        for cell in [
            "<table:table-cell office:value-type=\"string\"><text:p>visible</text:p>\(list)</table:table-cell>",
            "<table:table-cell office:value-type=\"string\">\(list)</table:table-cell>",
            "<table:table-cell office:value-type=\"string\" office:string-value=\"cached\">\(list)</table:table-cell>",
        ] {
            await Self.assertRejected(Self.parts(rows: Self.row(Self.cell("first") + cell)))
        }
    }

    func testPackageMIMEVersionManifestAndEncryptionFailuresAreExplicit() async {
        var missing = Self.parts(rows: Self.row(Self.cell("first")))
        missing.removeAll { $0.0 == "META-INF/manifest.xml" }
        await Self.assertRejected(missing)
        for replacement in [
            "<manifest:manifest xmlns:manifest=\"\(Self.manifest)\" manifest:version=\"1.3\"/>",
            Self.manifestXML.replacingOccurrences(of: "text/xml", with: "application/octet-stream"),
            Self.manifestXML.replacingOccurrences(of: "/>", with: "><manifest:encryption-data/></manifest:file-entry>"),
        ] { await Self.assertRejected(Self.replacing(Self.parts(rows: Self.row(Self.cell("first"))), part: "META-INF/manifest.xml", with: replacement)) }
        var badMIME = Self.parts(rows: Self.row(Self.cell("first")))
        badMIME[0].1 = Data("application/vnd.oasis.opendocument.text".utf8)
        await Self.assertRejected(badMIME)
        let version = Self.document(Self.row(Self.cell("first"))).replacingOccurrences(of: "office:version=\"1.3\"", with: "office:version=\"1.2\"")
        await Self.assertRejected(Self.replacing(Self.parts(rows: ""), part: "content.xml", with: version))
    }

    func testNamespaceEncodingDTDAndExpandedAttributeConflictsAreRejected() async {
        let good = Self.document(Self.row(Self.cell("first")))
        for xml in [
            good.replacingOccurrences(of: Self.table, with: "urn:spoof"),
            "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>" + good,
            "<!DOCTYPE office:document-content [<!ENTITY leak SYSTEM 'file:///etc/passwd'>]>" + good,
            good.replacingOccurrences(of: "table:name=\"Sheet1\"", with: "xmlns:alias=\"\(Self.table)\" table:name=\"Sheet1\" alias:name=\"different\""),
            "<office:document-content xmlns:office=\"\(Self.office)\">",
        ] { await Self.assertRejected(Self.replacing(Self.parts(rows: ""), part: "content.xml", with: xml)) }
        var invalidUTF8 = Self.parts(rows: Self.row(Self.cell("first")))
        invalidUTF8[1].1 = Data([0xFF, 0xFE, 0x00])
        await Self.assertRejected(invalidUTF8)
    }

    func testCellOutputPartNodeDepthAndContainerBudgetsRejectBeforePartialReturn() async throws {
        await Self.assertRejected(Self.parts(rows: Self.row(Self.cell(String(repeating: "a", count: NativeODSReader.maximumCellBytes + 1)))))
        await Self.assertRejected(Self.parts(rows: Self.row(Self.cell("<text:s text:c=\"4096\"/><text:s/>"))))
        await Self.assertRejected(Self.parts(rows: Self.row(Self.cell(String(repeating: "y", count: 4096), attributes: "table:number-columns-repeated=\"32\""))))
        var oversized = Self.parts(rows: Self.row(Self.cell("first")))
        oversized.append(("unused.xml", Data(repeating: 0x61, count: NativeODSReader.maximumPartBytes + 1)))
        await Self.assertRejected(oversized)
        let deep = String(repeating: "<text:span>", count: NativeODSReader.maximumXMLDepth) + "value" + String(repeating: "</text:span>", count: NativeODSReader.maximumXMLDepth)
        await Self.assertRejected(Self.parts(rows: Self.row(Self.cell(deep))))
        let many = String(repeating: "<text:s/>", count: NativeODSReader.maximumXMLNodes)
        await Self.assertRejected(Self.parts(rows: Self.row(Self.cell(many))))
        try await Task.detached(priority: .utility) {
            XCTAssertThrowsError(try NativeODSReader.text(in: Data(repeating: 0, count: NativeODSReader.maximumContainerBytes + 1)))
        }.value
    }

    func testCancelledWorkerDeclinesWithoutConverting() async throws {
        let data = Self.archive(Self.parts(rows: Self.row(Self.cell("never converted"))))
        try await Task.detached(priority: .utility) {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try NativeODSReader.text(in: data)) { XCTAssertTrue($0 is CancellationError) }
        }.value
    }

    private static func cell(_ value: String, attributes: String = "") -> String {
        "<table:table-cell office:value-type=\"string\" \(attributes)><text:p>\(value)</text:p></table:table-cell>"
    }
    private static func row(_ cells: String) -> String { "<table:table-row>\(cells)</table:table-row>" }
    private static func document(_ rows: String) -> String {
        "<office:document-content xmlns:office=\"\(office)\" xmlns:table=\"\(table)\" xmlns:text=\"\(text)\" office:version=\"1.3\"><office:automatic-styles/><office:body><office:spreadsheet><table:table table:name=\"Sheet1\"><table:table-column/>\(rows)</table:table></office:spreadsheet></office:body></office:document-content>"
    }
    private static var manifestXML: String {
        "<manifest:manifest xmlns:manifest=\"\(manifest)\" manifest:version=\"1.3\"><manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.3\" manifest:media-type=\"application/vnd.oasis.opendocument.spreadsheet\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>"
    }
    private static func parts(rows: String) -> [(String, Data)] {
        [("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8)), ("content.xml", Data(document(rows).utf8)), ("META-INF/manifest.xml", Data(manifestXML.utf8))]
    }
    private static func replacing(_ parts: [(String, Data)], part: String, with value: String) -> [(String, Data)] {
        parts.map { $0.0 == part ? ($0.0, Data(value.utf8)) : $0 }
    }
    private static func read(_ parts: [(String, Data)]) async throws -> String {
        let data = archive(parts)
        return try await Task.detached(priority: .utility) { try NativeODSReader.text(in: data) }.value
    }
    private static func assertRejected(_ parts: [(String, Data)], file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await read(parts); XCTFail("Expected ODS rejection", file: file, line: line) }
        catch { XCTAssertFalse(error is CancellationError, file: file, line: line) }
    }
    /// Independent fixture ZIP, with the required MIME member first/stored/no extras.
    private static func archive(_ parts: [(String, Data)]) -> Data {
        var local = Data(), central = Data()
        func little(_ value: UInt32, bytes: Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        func crc(_ data: Data) -> UInt32 {
            var value: UInt32 = 0xFFFF_FFFF
            for byte in data { value ^= UInt32(byte); for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xEDB8_8320) } }
            return value ^ 0xFFFF_FFFF
        }
        for (name, data) in parts {
            let encoded = Data(name.utf8), checksum = crc(data), offset = local.count
            local += little(0x0403_4B50, bytes: 4)
            for value in [UInt32(20), 0, 0, 0, 0] { local += little(value, bytes: 2) }
            for value in [checksum, UInt32(data.count), UInt32(data.count)] { local += little(value, bytes: 4) }
            local += little(UInt32(encoded.count), bytes: 2); local += little(0, bytes: 2); local += encoded; local += data
            central += little(0x0201_4B50, bytes: 4)
            for value in [UInt32(0x0314), 20, 0, 0, 0, 0] { central += little(value, bytes: 2) }
            for value in [checksum, UInt32(data.count), UInt32(data.count)] { central += little(value, bytes: 4) }
            for value in [UInt32(encoded.count), 0, 0, 0, 0] { central += little(value, bytes: 2) }
            central += little(UInt32(0o100600) << 16, bytes: 4); central += little(UInt32(offset), bytes: 4); central += encoded
        }
        let offset = local.count
        local += central; local += little(0x0605_4B50, bytes: 4)
        for value in [UInt32(0), 0, UInt32(parts.count), UInt32(parts.count)] { local += little(value, bytes: 2) }
        local += little(UInt32(central.count), bytes: 4); local += little(UInt32(offset), bytes: 4); local += little(0, bytes: 2)
        return local
    }
}

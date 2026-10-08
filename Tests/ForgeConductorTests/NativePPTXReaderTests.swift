import XCTest
@testable import ForgeConductorCore

final class NativePPTXReaderTests: XCTestCase {
    private static let presentation = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let drawing = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    func testLiteralUnicodeRichRunsAndEscapedXMLExcludePackageAndMasterText() async throws {
        var parts = Self.parts(shapes: [Self.shape("<a:p>" + Self.run(" café 日本語 🙂 &amp; &lt;literal&gt; _x0041_ ") + Self.run("_x00") + Self.run("41_") + "</a:p>")])
        parts["ppt/slideMasters/master.xml"] = "<p:sldMaster xmlns:p=\"\(Self.presentation)\" xmlns:a=\"\(Self.drawing)\">" + Self.shape("<a:p>" + Self.run("MASTER-MUST-NOT-BECOME-INSTRUCTIONS") + "</a:p>") + "</p:sldMaster>"
        parts["ppt/notesSlides/notes.xml"] = "<notes>NOTES-MUST-NOT-BECOME-INSTRUCTIONS</notes>"
        let text = try await Self.read(parts)
        XCTAssertEqual(text, "[Slide 1]\n café 日本語 🙂 & <literal> _x0041_ _x0041_")
        XCTAssertFalse(text.contains("<p:sld"))
        XCTAssertFalse(text.contains("Relationships"))
        XCTAssertFalse(text.contains("MASTER-MUST"))
        XCTAssertFalse(text.contains("NOTES-MUST"))
    }

    func testPresentationRelationshipOrderPreservesBlankSlidePositions() async throws {
        var parts = Self.parts(shapes: [Self.textShape("first"), "", Self.textShape("third")])
        parts["ppt/presentation.xml"] = Self.presentationXML([3, 2, 1])
        let text = try await Self.read(parts)
        XCTAssertEqual(text, "[Slide 1]\nthird\n\n[Slide 3]\nfirst")
    }

    func testParagraphsExplicitLineBreakFieldsAndSeparateTextBodiesKeepOrder() async throws {
        let paragraphs = "<a:p><a:pPr/>" + Self.run("left") + "<a:br><a:rPr/></a:br><a:fld id=\"field\" type=\"slidenum\"><a:rPr/>" + "<a:t>right</a:t></a:fld><a:endParaRPr/></a:p><a:p/><a:p>" + Self.run("last") + "</a:p>"
        let text = try await Self.read(Self.parts(shapes: [Self.shape(paragraphs) + Self.textShape("next shape")]))
        XCTAssertEqual(text, "[Slide 1]\nleft\nright\n\nlast\nnext shape")
    }

    func testGroupsAndTableCellsUseOnlySlideOwnedDrawingMLText() async throws {
        let table = "<p:graphicFrame><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl><a:tr><a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p>" + Self.run("cell one") + "</a:p></a:txBody></a:tc><a:tc><a:txBody><a:p>" + Self.run("cell two") + "</a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
        let shapes = "<p:grpSp>" + Self.textShape("group") + "</p:grpSp>" + table + "<p:pic><p:unused>PICTURE-METADATA</p:unused></p:pic>"
        let text = try await Self.read(Self.parts(shapes: [shapes]))
        XCTAssertEqual(text, "[Slide 1]\ngroup\ncell one\ncell two")
    }

    func testStrictNamespacesPrefixesAndAlternateInternalPartPaths() async throws {
        let p = "http://purl.oclc.org/ooxml/presentationml/main"
        let a = "http://purl.oclc.org/ooxml/drawingml/main"
        let r = "http://purl.oclc.org/ooxml/officeDocument/relationships"
        let parts = [
            "_rels/.rels": Self.rels("<Relationship Id=\"deck\" Type=\"\(r)/officeDocument\" Target=\"decks/main.xml\"/>"),
            "decks/main.xml": "<v:presentation xmlns:v=\"\(p)\" xmlns:link=\"\(r)\"><v:sldIdLst><v:sldId id=\"256\" link:id=\"slide\"/></v:sldIdLst></v:presentation>",
            "decks/_rels/main.xml.rels": Self.rels("<Relationship Id=\"slide\" Type=\"\(r)/slide\" Target=\"../pages/first.xml\"/>"),
            "pages/first.xml": "<v:sld xmlns:v=\"\(p)\" xmlns:d=\"\(a)\"><v:cSld><v:spTree><v:sp><v:txBody><d:p><d:r><d:t>alternate</d:t></d:r></d:p></v:txBody></v:sp></v:spTree></v:cSld></v:sld>",
        ]
        let text = try await Self.read(parts)
        XCTAssertEqual(text, "[Slide 1]\nalternate")
    }

    func testBlankWhitespaceAndZeroSlideDecksProduceNoCanonicalText() async throws {
        for shapes in [[], [""], [Self.textShape(" \n\t ")]] {
            let text = try await Self.read(Self.parts(shapes: shapes))
            XCTAssertEqual(text, "")
        }
    }

    func testExternalTraversalURIMissingAndWrongSlideRelationshipsAreRejected() async {
        for target in ["../../outside.xml", "https://example.invalid/slide.xml", "slides/missing.xml", "slides/slide1.xml#fragment", "slides/%73lide1.xml", "slides\\slide1.xml"] {
            var parts = Self.parts(shapes: [Self.textShape("must not be partially returned")])
            parts["ppt/_rels/presentation.xml.rels"] = Self.rels("<Relationship Id=\"slide1\" Type=\"\(Self.relationships)/slide\" Target=\"\(target)\"/>")
            await Self.assertRejected(parts)
        }
        for attributes in ["Type=\"\(Self.relationships)/slide\" Target=\"slides/slide1.xml\" TargetMode=\"External\"", "Type=\"\(Self.relationships)/slideLayout\" Target=\"slides/slide1.xml\"", "Type=\"\(Self.relationships)/slide\" Target=\"slides/slide1.xml\" TargetMode=\"invalid\""] {
            var parts = Self.parts(shapes: [Self.textShape("must not be partially returned")])
            parts["ppt/_rels/presentation.xml.rels"] = Self.rels("<Relationship Id=\"slide1\" \(attributes)/>")
            await Self.assertRejected(parts)
        }
    }

    func testDuplicateNumericIdentitiesReferencesAndTargetsAreRejected() async {
        var duplicate = Self.parts(shapes: [Self.textShape("one"), Self.textShape("two")])
        duplicate["ppt/presentation.xml"] = "<p:presentation xmlns:p=\"\(Self.presentation)\" xmlns:r=\"\(Self.relationships)\"><p:sldIdLst><p:sldId id=\"256\" r:id=\"slide1\"/><p:sldId id=\"0256\" r:id=\"slide2\"/></p:sldIdLst></p:presentation>"
        await Self.assertRejected(duplicate)
        duplicate["ppt/presentation.xml"] = Self.presentationXML([1, 1])
        await Self.assertRejected(duplicate)
        duplicate["ppt/presentation.xml"] = Self.presentationXML([1, 2])
        duplicate["ppt/_rels/presentation.xml.rels"] = Self.rels("<Relationship Id=\"slide1\" Type=\"\(Self.relationships)/slide\" Target=\"slides/slide1.xml\"/><Relationship Id=\"slide2\" Type=\"\(Self.relationships)/slide\" Target=\"slides/slide1.xml\"/>")
        await Self.assertRejected(duplicate)
        duplicate["ppt/_rels/presentation.xml.rels"] = Self.rels("<Relationship Id=\"slide1\" Type=\"\(Self.relationships)/slide\" Target=\"slides/slide1.xml\"/><Relationship Id=\"slide1\" Type=\"\(Self.relationships)/slide\" Target=\"slides/slide2.xml\"/>")
        await Self.assertRejected(duplicate)
    }

    func testMalformedXMLDTDNamespaceSpoofAndMalformedRunsRejectWholeDeck() async {
        for xml in [
            "<!DOCTYPE sld [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]>" + Self.slide(Self.textShape("&secret;")),
            "<p:sld xmlns:p=\"\(Self.presentation)\"><p:cSld>",
            "<sld xmlns=\"urn:unrelated\"><cSld><spTree/></cSld></sld>",
            Self.slide(Self.shape("<a:p><a:r><a:t>first</a:t><a:t>second</a:t></a:r></a:p>")),
            Self.slide(Self.shape("<a:p><a:r><a:t><a:child>lost</a:child></a:t></a:r></a:p>")),
            Self.slide(Self.shape("<a:p>UNOWNED<a:r><a:t>run</a:t></a:r></a:p>")),
            Self.slide(Self.shape("<a:p><foreign:t xmlns:foreign=\"urn:unrelated\">lost</foreign:t></a:p>")),
        ] {
            var parts = Self.parts(shapes: [Self.textShape("first good slide"), ""])
            parts["ppt/slides/slide2.xml"] = xml
            await Self.assertRejected(parts)
        }
    }

    func testCommentsCDATAAndProcessingInstructionsDoNotBecomeDeclarations() async throws {
        var parts = Self.parts(shapes: [Self.shape("<a:p><a:r><a:t><![CDATA[<!DOCTYPE literal> <!ENTITY literal>]]></a:t></a:r></a:p>")])
        parts["ppt/slides/slide1.xml"] = "<?test literal <!DOCTYPE?>" + parts["ppt/slides/slide1.xml"]! + "<!-- <!ENTITY comment> -->"
        let text = try await Self.read(parts)
        XCTAssertEqual(text, "[Slide 1]\n<!DOCTYPE literal> <!ENTITY literal>")
    }

    func testConflictingXMLByteEncodingDeclarationRejectsWholeDeck() async throws {
        var parts = Self.parts(shapes: [Self.textShape("café")])
        let baseline = try await Self.read(parts)
        XCTAssertEqual(baseline, "[Slide 1]\ncafé")
        let slide = parts["ppt/slides/slide1.xml"]!
        for declaration in ["<?xml version=\"1.0\" encoding=\"utf-8\"?>",
                            "\u{FEFF}<?xml version='1.0' encoding = 'UTF-8'?>", "<?xml version=\"1.0\"?>"] {
            parts["ppt/slides/slide1.xml"] = declaration + slide
            let text = try await Self.read(parts)
            XCTAssertEqual(text, baseline)
        }
        parts["ppt/slides/slide1.xml"] = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>" + slide
        await Self.assertRejected(parts)
    }

    func testDuplicateExpandedRelationshipAttributeRejectsWholeDeck() async throws {
        var parts = Self.parts(shapes: [Self.textShape("owned slide text")])
        let baseline = try await Self.read(parts)
        XCTAssertEqual(baseline, "[Slide 1]\nowned slide text")
        parts["ppt/presentation.xml"] = "<p:presentation xmlns:p=\"\(Self.presentation)\" xmlns:r=\"\(Self.relationships)\" xmlns:alias=\"\(Self.relationships)\"><p:sldIdLst><p:sldId id=\"256\" r:id=\"slide1\" alias:id=\"slide1\"/></p:sldIdLst></p:presentation>"
        await Self.assertRejected(parts)
    }

    func testExactParagraphSlideAndCanonicalByteBounds() async throws {
        let paragraphs = String(repeating: "<a:p/>", count: NativePPTXReader.maximumParagraphs)
        let emptyParagraphs = try await Self.read(Self.parts(shapes: [Self.shape(paragraphs)]))
        XCTAssertEqual(emptyParagraphs, "")
        await Self.assertRejected(Self.parts(shapes: [Self.shape(paragraphs + "<a:p/>")]))
        let slides = Array(repeating: "", count: NativePPTXReader.maximumSlides)
        let emptySlides = try await Self.read(Self.parts(shapes: slides))
        XCTAssertEqual(emptySlides, "")
        await Self.assertRejected(Self.parts(shapes: slides + [""]))
        let full = String(repeating: "a", count: NativePPTXReader.maximumParagraphBytes)
        let lastSize = NativePPTXReader.maximumTextBytes - "[Slide 1]\n".utf8.count - 31 - 31 * full.utf8.count
        let content = String(repeating: "<a:p>" + Self.run(full) + "</a:p>", count: 31)
        let atLimit = try await Self.read(Self.parts(shapes: [Self.shape(content + "<a:p>" + Self.run(String(repeating: "b", count: lastSize)) + "</a:p>")]))
        XCTAssertEqual(atLimit.utf8.count, NativePPTXReader.maximumTextBytes)
        await Self.assertRejected(Self.parts(shapes: [Self.shape(content + "<a:p>" + Self.run(String(repeating: "b", count: lastSize + 1)) + "</a:p>")]))
        await Self.assertRejected(Self.parts(shapes: [Self.textShape(full + "b")]))
    }

    func testXMLDepthNodePartInventoryExpandedAndContainerBounds() async throws {
        var deep = Self.parts(shapes: [""])
        deep["ppt/slides/slide1.xml"] = "<p:sld xmlns:p=\"\(Self.presentation)\">" + String(repeating: "<p:unknown>", count: 33) + String(repeating: "</p:unknown>", count: 33) + "</p:sld>"
        await Self.assertRejected(deep)
        await Self.assertRejected(Self.parts(shapes: [Self.shape("<a:p><a:pPr>" + String(repeating: "<a:unknown/>", count: NativePPTXReader.maximumXMLNodes) + "</a:pPr></a:p>")]))
        var many = Self.parts(shapes: [""])
        for i in 0..<NativePPTXReader.maximumParts { many["unused/\(i).xml"] = "" }
        await Self.assertRejected(many)
        var oversized = Self.parts(shapes: [""])
        oversized["unused/oversized.xml"] = String(repeating: "a", count: NativePPTXReader.maximumPartBytes + 1)
        await Self.assertRejected(oversized)
        var expanded = Self.parts(shapes: [""])
        for i in 0..<4 { expanded["unused/\(i).xml"] = String(repeating: "a", count: NativePPTXReader.maximumPartBytes) }
        await Self.assertRejected(expanded)
        try await Task.detached(priority: .utility) {
            XCTAssertThrowsError(try NativePPTXReader.text(in: Data(repeating: 0, count: NativePPTXReader.maximumContainerBytes + 1)))
        }.value
    }

    func testCancelledWorkerDeclinesBeforeZIPExtraction() async throws {
        let data = Self.archive(Self.parts(shapes: [Self.textShape("never extracted")]))
        try await Task.detached(priority: .utility) {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try NativePPTXReader.text(in: data)) { error in
                XCTAssertTrue(error is CancellationError)
            }
        }.value
    }

    func testImporterPublishesOneSlideDocumentRetainsOriginalAndPagesExactText() async throws {
        try await Task.detached(priority: .utility) {
            let fixture = try Self.importFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let original = Self.archive(Self.parts(shapes: [Self.textShape("café 日本語 🙂 &amp; &lt;literal&gt; _x0041_")]))
            let source = fixture.root.appendingPathComponent("instructions.PPTX")
            try original.write(to: source)
            let package = try XCTUnwrap(fixture.store.importPackage(sourceURL: source, projectID: fixture.project, generation: .initial).packages.first)
            XCTAssertEqual(package.documentCount, 1)
            XCTAssertEqual(package.unresolvedDocumentCount, 0)
            XCTAssertEqual(package.asDictionary()["import_ready"] as? Bool, true)
            let catalog = try fixture.catalog(package)
            let document = try XCTUnwrap(catalog.first)
            XCTAssertEqual(document["source_path"], "instructions.PPTX")
            XCTAssertEqual(document["status"], "converted_instruction")
            XCTAssertEqual(document["converter"], "native-pptx-slides-v1")
            XCTAssertEqual(document["original_sha256"], JSONSupport.sha256Hex(original))
            let retained = fixture.original(package, "instructions.PPTX")
            XCTAssertEqual(try Data(contentsOf: retained), original)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: retained.path)[.posixPermissions] as? NSNumber)?.intValue, 0o400)
            var text = "", offset = 0, reachedEnd = false
            for _ in 0..<32 {
                let page = try fixture.store.readDocument(contentSHA256: package.contentSHA256, documentID: try XCTUnwrap(document["id"]), projectID: fixture.project, generation: .initial, runID: nil, byteOffset: offset, maximumBytes: 17)
                text += page.content
                if let next = page.nextByteOffset { XCTAssertGreaterThan(next, offset); offset = next }
                else { reachedEnd = true; break }
            }
            XCTAssertTrue(reachedEnd)
            XCTAssertEqual(text, "[Slide 1]\ncafé 日本語 🙂 & <literal> _x0041_")
            XCTAssertEqual(package.instructionByteCount, text.utf8.count)
            XCTAssertEqual(document["canonical_sha256"], JSONSupport.sha256Hex(Data(text.utf8)))
            XCTAssertThrowsError(try fixture.store.readDocument(contentSHA256: package.contentSHA256, documentID: try XCTUnwrap(document["id"]), projectID: ProjectID(), generation: .initial, runID: nil, byteOffset: 0, maximumBytes: 17))
        }.value
    }

    func testImporterRetainsBlankAndMalformedDecksWithoutXMLInstructionsOrStartReadiness() async throws {
        try await Task.detached(priority: .utility) {
            for malformed in [false, true] {
                let fixture = try Self.importFixture()
                defer { try? FileManager.default.removeItem(at: fixture.root) }
                let original = malformed ? Data("<xml>must not be promoted</xml>".utf8) : Self.archive(Self.parts(shapes: [""]))
                let source = fixture.root.appendingPathComponent("blank.pptx")
                try original.write(to: source)
                let package = try XCTUnwrap(fixture.store.importPackage(sourceURL: source, projectID: fixture.project, generation: .initial).packages.first)
                XCTAssertEqual(package.documentCount, 1)
                XCTAssertEqual(package.instructionByteCount, 0)
                XCTAssertEqual(package.unresolvedDocumentCount, 1)
                XCTAssertEqual(package.asDictionary()["import_ready"] as? Bool, false)
                XCTAssertThrowsError(try fixture.store.start(projectID: fixture.project, generation: .initial))
                let document = try XCTUnwrap(fixture.catalog(package).first)
                XCTAssertEqual(document["status"], malformed ? "unresolved_conversion" : "unrepresented_visual_structural")
                XCTAssertEqual(document["canonical_bytes"], "0")
                XCTAssertEqual(document["converter"], "native-pptx-slides-v1")
                XCTAssertThrowsError(try fixture.store.documentReferences(contentSHA256: package.contentSHA256))
                XCTAssertEqual(try Data(contentsOf: fixture.original(package, "blank.pptx")), original)
            }
        }.value
    }

    func testDirectoryAndOrdinaryZIPKeepPPTXAtomicAndNestedZIPUnexpanded() async throws {
        try await Task.detached(priority: .utility) {
            for zip in [false, true] {
                let fixture = try Self.importFixture()
                defer { try? FileManager.default.removeItem(at: fixture.root) }
                let deck = Self.archive(Self.parts(shapes: [Self.textShape("slide instruction")]))
                let inner = Self.archive(["hidden.md": Data("nested text must remain unexpanded".utf8)])
                let files = ["guide.md": Data("ordinary instruction".utf8), "deck.pptx": deck, "inner.zip": inner]
                let source: URL
                if zip {
                    source = fixture.root.appendingPathComponent("outer.zip")
                    try Self.archive(files).write(to: source)
                } else {
                    source = fixture.root.appendingPathComponent("directory", isDirectory: true)
                    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
                    for (name, data) in files { try data.write(to: source.appendingPathComponent(name)) }
                }
                let package = try XCTUnwrap(fixture.store.importPackage(sourceURL: source, projectID: fixture.project, generation: .initial).packages.first)
                let documents = try fixture.catalog(package)
                let decks = documents.filter { $0["source_path"]?.hasSuffix("deck.pptx") == true }
                XCTAssertEqual(decks.count, 1)
                XCTAssertEqual(decks.first?["converter"], "native-pptx-slides-v1")
                XCTAssertEqual(decks.first?["status"], "converted_instruction")
                XCTAssertFalse(documents.contains { $0["source_path"]?.contains("ppt/slides") == true })
                XCTAssertFalse(documents.contains { $0["source_path"]?.hasSuffix("hidden.md") == true })
                let nested = try XCTUnwrap(documents.first { $0["source_path"]?.hasSuffix("inner.zip") == true })
                XCTAssertEqual(nested["status"], "retained_attachment")
                XCTAssertEqual(nested["converter"], "nested-zip-retention-v1")
                XCTAssertEqual(try Data(contentsOf: fixture.original(package, try XCTUnwrap(decks.first?["source_path"]))), deck)
                XCTAssertEqual(try Data(contentsOf: fixture.original(package, try XCTUnwrap(nested["source_path"]))), inner)
                XCTAssertEqual(package.instructionByteCount, "ordinary instruction".utf8.count + "[Slide 1]\nslide instruction".utf8.count)
                if zip {
                    XCTAssertEqual(documents.first { $0["source_path"] == "outer.zip" }?["converter"], "native-zip-inventory-v1")
                }
            }
        }.value
    }

    private static func presentationXML(_ order: [Int]) -> String {
        let ids = order.enumerated().map { "<p:sldId id=\"\(256 + $0.offset)\" r:id=\"slide\($0.element)\"/>" }.joined()
        return "<p:presentation xmlns:p=\"\(presentation)\" xmlns:r=\"\(relationships)\"><p:sldIdLst>\(ids)</p:sldIdLst></p:presentation>"
    }
    private static func parts(shapes: [String]) -> [String: String] {
        var parts = [
            "[Content_Types].xml": "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/></Types>",
            "_rels/.rels": rels("<Relationship Id=\"deck\" Type=\"\(relationships)/officeDocument\" Target=\"ppt/presentation.xml\"/>"),
            "ppt/presentation.xml": presentationXML(shapes.indices.map { $0 + 1 }),
            "ppt/_rels/presentation.xml.rels": rels(shapes.indices.map { "<Relationship Id=\"slide\($0 + 1)\" Type=\"\(relationships)/slide\" Target=\"slides/slide\($0 + 1).xml\"/>" }.joined()),
        ]
        for (index, shape) in shapes.enumerated() { parts["ppt/slides/slide\(index + 1).xml"] = slide(shape) }
        return parts
    }
    private static func slide(_ shapes: String) -> String {
        "<p:sld xmlns:p=\"\(presentation)\" xmlns:a=\"\(drawing)\" xmlns:r=\"\(relationships)\"><p:cSld><p:spTree>\(shapes)</p:spTree></p:cSld></p:sld>"
    }
    private static func shape(_ paragraphs: String) -> String {
        "<p:sp><p:txBody><a:bodyPr/><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>"
    }
    private static func textShape(_ xmlText: String) -> String { shape("<a:p>" + run(xmlText) + "</a:p>") }
    private static func run(_ xmlText: String) -> String { "<a:r><a:rPr/><a:t xml:space=\"preserve\">\(xmlText)</a:t></a:r>" }
    private static func rels(_ body: String) -> String { "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(body)</Relationships>" }
    private static func read(_ parts: [String: String]) async throws -> String {
        let data = archive(parts)
        return try await Task.detached(priority: .utility) { try NativePPTXReader.text(in: data) }.value
    }
    private static func assertRejected(_ parts: [String: String], file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await read(parts); XCTFail("Expected presentation rejection", file: file, line: line) }
        catch { XCTAssertFalse(error is CancellationError, file: file, line: line) }
    }

    /// Independent stored-ZIP fixture, without invoking the production writer.
    private static func archive(_ parts: [String: String]) -> Data { archive(parts.mapValues { Data($0.utf8) }) }
    private static func archive(_ parts: [String: Data]) -> Data {
        var local = Data(), central = Data()
        func little(_ value: UInt32, bytes: Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        func crc(_ data: Data) -> UInt32 {
            var value: UInt32 = 0xFFFF_FFFF
            for byte in data {
                value ^= UInt32(byte)
                for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xEDB8_8320) }
            }
            return value ^ 0xFFFF_FFFF
        }
        for (name, data) in parts.sorted(by: { $0.key < $1.key }) {
            let encoded = Data(name.utf8), checksum = crc(data), offset = local.count
            local += little(0x0403_4B50, bytes: 4)
            for value in [UInt32(20), 0, 0, 0, 0] { local += little(value, bytes: 2) }
            for value in [checksum, UInt32(data.count), UInt32(data.count)] { local += little(value, bytes: 4) }
            local += little(UInt32(encoded.count), bytes: 2); local += little(0, bytes: 2)
            local += encoded; local += data
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

    private struct ImportFixture {
        let root: URL
        let paths: AppPaths
        let store: ProjectInstructionQueueStore
        let project: ProjectID
        func catalog(_ package: ProjectInstructionPackage) throws -> [[String: String]] {
            try store.catalogPage(contentSHA256: package.contentSHA256, projectID: project, generation: .initial, runID: nil, cursor: 0, limit: 128).documents
        }
        func original(_ package: ProjectInstructionPackage, _ name: String) -> URL {
            paths.instructionPackageStoreDir.appendingPathComponent(package.contentSHA256).appendingPathComponent("originals").appendingPathComponent(name)
        }
    }
    private static func importFixture() throws -> ImportFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("forge-pptx-reader-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let paths = AppPaths(home: root.appendingPathComponent("home"))
        return ImportFixture(root: root, paths: paths, store: try ProjectInstructionQueueStore(paths: paths), project: ProjectID())
    }
}

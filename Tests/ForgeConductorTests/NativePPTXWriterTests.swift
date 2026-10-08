import Foundation
import Darwin
import XCTest
@testable import ForgeConductorCore

final class NativePPTXWriterTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("forge-pptx-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        temporaryRoot = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporaryRoot) }

    func testStoredZIPCRCXMLPartsAndAllInternalRelationshipTargets() async throws {
        try await Task.detached(priority: .utility) {
            let bytes = try NativePPTXWriter.encode(slides: [.init(title: "One", paragraphs: ["First"]), .init(title: "Two", paragraphs: ["Second"])])
            let parts = try Self.inspectZIP(bytes)
            let fixed = ["[Content_Types].xml", "_rels/.rels", "ppt/presentation.xml", "ppt/_rels/presentation.xml.rels", "ppt/presProps.xml",
                "ppt/slideLayouts/slideLayout1.xml", "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
                "ppt/slideMasters/slideMaster1.xml", "ppt/slideMasters/_rels/slideMaster1.xml.rels", "ppt/theme/theme1.xml"]
            XCTAssertEqual(Set(parts.keys), Set(fixed + ["ppt/slides/slide1.xml", "ppt/slides/_rels/slide1.xml.rels", "ppt/slides/slide2.xml", "ppt/slides/_rels/slide2.xml.rels"]))
            XCTAssertEqual(try SafeZIPArchive.inspect(bytes).map(\.path).sorted(), parts.keys.sorted())
            XCTAssertEqual(Self.crc32(Data("123456789".utf8)), 0xCBF43926)
            for (name, part) in parts {
                let parsed = try Self.parseXML(part)
                XCTAssertFalse(parsed.elements.isEmpty, name)
                if name.hasSuffix(".rels") {
                    XCTAssertEqual(parsed.elements.first?.0, "Relationships")
                    XCTAssertEqual(parsed.elements.first?.1["xmlns"], "http://schemas.openxmlformats.org/package/2006/relationships")
                    let relations = parsed.elements.filter { $0.0 == "Relationship" }.map(\.1)
                    XCTAssertEqual(Set(relations.compactMap { $0["Id"] }).count, relations.count)
                    for relationship in relations {
                        XCTAssertNil(relationship["TargetMode"])
                        let target = try XCTUnwrap(relationship["Target"])
                        XCTAssertNotNil(parts[Self.target(target, from: name)], "\(name) -> \(target)")
                        XCTAssertTrue(try XCTUnwrap(relationship["Type"]).hasPrefix("http://schemas.openxmlformats.org/officeDocument/2006/relationships/"))
                    }
                }
            }
            let types = try Self.parseXML(XCTUnwrap(parts["[Content_Types].xml"]))
            XCTAssertEqual(types.elements.first?.1["xmlns"], "http://schemas.openxmlformats.org/package/2006/content-types")
            let declarations = types.elements.filter { $0.0 == "Override" }.map(\.1)
            XCTAssertEqual(Set(declarations.compactMap { $0["PartName"] }), Set(parts.keys.filter { $0.hasSuffix(".xml") && $0 != "[Content_Types].xml" }.map { "/" + $0 }))
            XCTAssertEqual(declarations.first { $0["PartName"] == "/ppt/presentation.xml" }?["ContentType"], "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml")
            XCTAssertEqual(declarations.first { $0["PartName"] == "/ppt/presProps.xml" }?["ContentType"], "application/vnd.openxmlformats-officedocument.presentationml.presProps+xml")
            let theme = try Self.parseXML(XCTUnwrap(parts["ppt/theme/theme1.xml"]))
            XCTAssertEqual(theme.elements.first?.0, "a:theme")
            XCTAssertEqual(theme.elements.first?.1["xmlns:a"], "http://schemas.openxmlformats.org/drawingml/2006/main")
            XCTAssertEqual(theme.elements.filter { $0.0 == "a:effectStyle" }.count, 3)
            XCTAssertFalse(parts.keys.contains { $0.contains("thumbnail") || $0.contains("vbaProject") || $0.contains("notes") })
        }.value
    }

    func testDeclaredSlideOrderMasterLayoutAndTextShapeGeometry() async throws {
        try await Task.detached(priority: .utility) {
            let slides: [NativePPTXWriter.Slide] = [.init(title: "First title", paragraphs: ["A", "B"]), .init(title: "", paragraphs: ["C"])]
            let parts = try Self.inspectZIP(NativePPTXWriter.encode(slides: slides))
            let presentation = try Self.parseXML(XCTUnwrap(parts["ppt/presentation.xml"]))
            let ids = presentation.elements.filter { $0.0 == "p:sldId" }.map(\.1)
            XCTAssertEqual(ids, [["id": "256", "r:id": "rId4"], ["id": "257", "r:id": "rId5"]])
            XCTAssertEqual(presentation.elements.first { $0.0 == "p:sldMasterId" }?.1, ["id": "2147483648", "r:id": "rId1"])
            XCTAssertEqual(presentation.elements.first { $0.0 == "p:sldSz" }?.1, ["cx": "9144000", "cy": "6858000", "type": "screen4x3"])
            let relations = try Self.parseXML(XCTUnwrap(parts["ppt/_rels/presentation.xml.rels"])).elements.filter { $0.0 == "Relationship" }.map(\.1)
            XCTAssertEqual(relations.first { $0["Id"] == "rId4" }?["Target"], "slides/slide1.xml")
            XCTAssertEqual(relations.first { $0["Id"] == "rId5" }?["Target"], "slides/slide2.xml")
            let master = try Self.parseXML(XCTUnwrap(parts["ppt/slideMasters/slideMaster1.xml"]))
            XCTAssertEqual(master.elements.first { $0.0 == "p:sldLayoutId" }?.1, ["id": "2147483649", "r:id": "rId1"])
            let layout = try Self.parseXML(XCTUnwrap(parts["ppt/slideLayouts/slideLayout1.xml"]))
            XCTAssertEqual(layout.elements.first?.1["type"], "blank")
            XCTAssertTrue(layout.paragraphs.isEmpty)
            let first = try Self.parseXML(XCTUnwrap(parts["ppt/slides/slide1.xml"]))
            XCTAssertEqual(first.paragraphs, ["First title", "A", "B"])
            XCTAssertEqual(first.elements.filter { $0.0 == "p:cNvPr" }.map { $0.1["id"]! }, ["1", "2", "3"])
            XCTAssertEqual(first.elements.filter { $0.0 == "p:cNvPr" }.map { $0.1["name"]! }, ["", "Title", "Body"])
            XCTAssertEqual(first.elements.filter { $0.0 == "a:off" }.map(\.1), [["x": "0", "y": "0"], ["x": "457200", "y": "274320"], ["x": "457200", "y": "1371600"]])
            XCTAssertEqual(try Self.parseXML(XCTUnwrap(parts["ppt/slides/slide2.xml"])).paragraphs, ["C"])
        }.value
    }

    func testUnicodeWhitespaceLiteralEscapesAndExplicitSoftBreaks() async throws {
        try await Task.detached(priority: .utility) {
            let title = "café Ελληνικά Русский 日本語 العربية 🙂"
            let values = ["&<>\"'", "  leading\ttrailing  ", "CRLF\r\nCR\rLF\nend\n", "\n\n", "", "_x0041_ _x005F_ _X0041_ _xZZZZ_", "=SUM(A1:A2)"]
            let parts = try Self.inspectZIP(NativePPTXWriter.encode(slides: [.init(title: title, paragraphs: values)]))
            let data = try XCTUnwrap(parts["ppt/slides/slide1.xml"])
            let parsed = try Self.parseXML(data)
            XCTAssertEqual(parsed.paragraphs, [title] + values.map(Self.normalized))
            XCTAssertEqual(parsed.breakCount, 6)
            XCTAssertEqual(parsed.preservedTextElements, parsed.textElements)
            let xml = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(xml.contains("&amp;&lt;&gt;\"'"))
            XCTAssertTrue(xml.contains("_x0041_ _x005F_ _X0041_ _xZZZZ_"))
            XCTAssertFalse(xml.contains("_x005F_x0041_"))
            XCTAssertFalse(xml.contains("\r"))
        }.value
    }

    func testBlankSlidesAndEmptyParagraphPositionsRemainExplicit() async throws {
        try await Task.detached(priority: .utility) {
            let parts = try Self.inspectZIP(NativePPTXWriter.encode(slides: [.init(title: "", paragraphs: []), .init(title: "", paragraphs: ["", "", "value", ""])]))
            let blank = try Self.parseXML(XCTUnwrap(parts["ppt/slides/slide1.xml"]))
            XCTAssertTrue(blank.paragraphs.isEmpty)
            XCTAssertEqual(blank.elements.filter { $0.0 == "p:sp" }.count, 0)
            XCTAssertEqual(try Self.parseXML(XCTUnwrap(parts["ppt/slides/slide2.xml"])).paragraphs, ["", "", "value", ""])
        }.value
    }

    func testWriterFeedsNativeReaderWithSlideLabelsAndNoPackageXML() async throws {
        try await Task.detached(priority: .utility) {
            let bytes = try NativePPTXWriter.encode(slides: [.init(title: "First café", paragraphs: ["literal _x0041_", "line\r\nnext"]), .init(title: "", paragraphs: []), .init(title: "Last", paragraphs: ["日本語 🙂"])])
            XCTAssertEqual(try NativePPTXReader.text(in: bytes), "[Slide 1]\nFirst café\nliteral _x0041_\nline\nnext\n\n[Slide 3]\nLast\n日本語 🙂")
            XCTAssertEqual(try NativePPTXReader.text(in: NativePPTXWriter.encode(slides: [.init(title: "", paragraphs: [])])), "")
        }.value
    }

    func testExactSlideParagraphAndUTF8LimitsRemainAdmitted() async throws {
        try await Task.detached(priority: .utility) {
            let cases: [[NativePPTXWriter.Slide]] = [Array(repeating: .init(title: "", paragraphs: []), count: 32),
                [.init(title: "title", paragraphs: Array(repeating: "", count: 1023))],
                [.init(title: "", paragraphs: Array(repeating: String(repeating: "x", count: 4096), count: 16))],
                [.init(title: String(repeating: "é", count: 2048), paragraphs: [])]]
            for slides in cases {
                let bytes = try NativePPTXWriter.encode(slides: slides)
                XCTAssertLessThanOrEqual(bytes.count, NativePPTXWriter.maximumOutputBytes)
                XCTAssertEqual(try Self.inspectZIP(bytes).count, 10 + slides.count * 2)
            }
        }.value
    }

    func testLineBreakHeavyOutputIsReadableOrExplicitlyDeclinesStructuralComplexity() async throws {
        try await Task.detached(priority: .utility) {
            let cases = [Array(repeating: "x" + String(repeating: "\n", count: 4095), count: 2),
                         Array(repeating: String(repeating: "x\n", count: 2048), count: 4)]
            for paragraphs in cases {
                do {
                    let bytes = try NativePPTXWriter.encode(slides: [.init(title: "", paragraphs: paragraphs)])
                    XCTAssertLessThanOrEqual(bytes.count, NativePPTXWriter.maximumOutputBytes)
                    let actual = try NativePPTXReader.text(in: bytes)
                    XCTAssertEqual(actual, "[Slide 1]\n" + paragraphs.joined(separator: "\n"))
                } catch let error as NativePPTXError {
                    XCTAssertEqual(error.code, "pptx_structure_too_large")
                }
            }
        }.value
    }

    func testExactXMLNodeBoundaryImportsAndNextBreakRejects() async throws {
        try await Task.detached(priority: .utility) {
            let paragraphs = ["x" + String(repeating: "\n", count: 4095),
                              "x" + String(repeating: "\n", count: 4080), "", "", ""]
            let bytes = try NativePPTXWriter.encode(slides: [.init(title: "", paragraphs: paragraphs)])
            let parts = try Self.inspectZIP(bytes)
            XCTAssertEqual(try Self.parseXML(XCTUnwrap(parts["ppt/slides/slide1.xml"])).elements.count, 32768)
            XCTAssertEqual(NativePPTXWriter.maximumSlideXMLNodes, 32768)
            XCTAssertEqual(try NativePPTXReader.text(in: bytes), "[Slide 1]\n" + paragraphs.joined(separator: "\n"))
            var excess = paragraphs; excess[1] += "\n"
            XCTAssertThrowsError(try NativePPTXWriter.encode(slides: [.init(title: "", paragraphs: excess)])) {
                XCTAssertEqual($0 as? NativePPTXError, .structureTooLarge)
            }
        }.value
    }

    func testStrictSlideObjectsDoNotCoerceOrIgnoreFields() throws {
        let invalid: [Any] = [NSNull(), "slides", 7, false, [], ["flat"], [["title": "missing"]],
            [["title": 7, "paragraphs": []]], [["title": false, "paragraphs": []]], [["title": NSNull(), "paragraphs": []]],
            [["title": "ok", "paragraphs": "flat"]], [["title": "ok", "paragraphs": [7]]],
            [["title": "ok", "paragraphs": [false]]], [["title": "ok", "paragraphs": [NSNull()]]],
            [["title": "ok", "paragraphs": [], "script": "ignored?"]]]
        for value in invalid {
            XCTAssertThrowsError(try NativePPTXWriter.slides(from: value)) { XCTAssertEqual($0 as? NativePPTXError, .invalidSlides) }
        }
        XCTAssertThrowsError(try NativePPTXWriter.slides(from: nil))
        XCTAssertEqual(try NativePPTXWriter.slides(from: [["title": "", "paragraphs": []], ["title": "Title", "paragraphs": ["", "body"]]]),
            [.init(title: "", paragraphs: []), .init(title: "Title", paragraphs: ["", "body"])])
        XCTAssertThrowsError(try NativePPTXWriter.slides(from: Array(repeating: ["title": "", "paragraphs": []] as [String: Any], count: 33))) {
            XCTAssertEqual($0 as? NativePPTXError, .contentTooLarge)
        }
        XCTAssertThrowsError(try NativePPTXWriter.slides(from: [["title": "title", "paragraphs": Array(repeating: "", count: 1024)]])) {
            XCTAssertEqual($0 as? NativePPTXError, .contentTooLarge)
        }
    }

    func testOversizeAndIllegalXMLTextRejectWithoutProducingBytes() async throws {
        try await Task.detached(priority: .utility) {
            XCTAssertThrowsError(try NativePPTXWriter.encode(slides: [])) { XCTAssertEqual($0 as? NativePPTXError, .invalidSlides) }
            let invalid: [[NativePPTXWriter.Slide]] = [Array(repeating: .init(title: "", paragraphs: []), count: 33),
                [.init(title: "title", paragraphs: Array(repeating: "", count: 1024))],
                [.init(title: "", paragraphs: Array(repeating: "", count: 1025))],
                [.init(title: String(repeating: "x", count: 4097), paragraphs: [])],
                [.init(title: "", paragraphs: [String(repeating: "é", count: 2048) + "x"])],
                [.init(title: "", paragraphs: Array(repeating: String(repeating: "x", count: 4096), count: 16) + ["x"])]]
            for slides in invalid { XCTAssertThrowsError(try NativePPTXWriter.encode(slides: slides)) { XCTAssertEqual($0 as? NativePPTXError, .contentTooLarge) } }
            for scalar in [0, 1, 11, 31, 0xFFFE, 0xFFFF] as [UInt32] {
                let text = "invalid" + String(UnicodeScalar(scalar)!)
                for slide in [NativePPTXWriter.Slide(title: text, paragraphs: []), .init(title: "", paragraphs: [text])] {
                    XCTAssertThrowsError(try NativePPTXWriter.encode(slides: [slide])) { XCTAssertEqual($0 as? NativePPTXError, .invalidText) }
                }
            }
        }.value
    }

    func testOutputLimitIncludesZIPDirectoryAndBreakExpansion() async throws {
        try await Task.detached(priority: .utility) {
            let slides: [NativePPTXWriter.Slide] = [.init(title: "", paragraphs: Array(repeating: String(repeating: "&", count: 4096), count: 16))]
            let bytes = try NativePPTXWriter.encode(slides: slides)
            XCTAssertEqual(try NativePPTXWriter.encode(slides: slides, outputByteLimit: bytes.count), bytes)
            for limit in [0, 512, bytes.count - 1, NativePPTXWriter.maximumOutputBytes + 1] {
                XCTAssertThrowsError(try NativePPTXWriter.encode(slides: slides, outputByteLimit: limit)) { XCTAssertEqual($0 as? NativePPTXError, .outputTooLarge) }
            }
            XCTAssertThrowsError(try NativePPTXWriter.encode(slides: [.init(title: "", paragraphs: Array(repeating: String(repeating: "\n", count: 4096), count: 16))])) {
                XCTAssertEqual($0 as? NativePPTXError, .structureTooLarge)
            }
        }.value
    }

    func testMainThreadCancellationAndDeadlineRejectEncoding() async throws {
        try await MainActor.run {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertThrowsError(try NativePPTXWriter.encode(slides: [.init(title: "main", paragraphs: [])])) { XCTAssertEqual($0 as? NativePPTXError, .workerRequired) }
        }
        try await Task.detached(priority: .utility) {
            let cancelled = ToolCallCancellation(timeoutSeconds: 10); cancelled.cancel()
            XCTAssertThrowsError(try NativePPTXWriter.encode(slides: [.init(title: "cancel", paragraphs: [])], cancellation: cancelled)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try NativePPTXWriter.encode(slides: [.init(title: "expired", paragraphs: [])], cancellation: ToolCallCancellation(timeoutSeconds: 0))) {
                XCTAssertTrue($0 is ToolCallDeadlineExceeded)
            }
        }.value
    }

    func testToolInvalidArgumentsAndCancellationPreserveDestination() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let file = project.appendingPathComponent("strict.pptx"), prior = Data("preserve destination".utf8)
                try prior.write(to: file)
                let slides: [[String: Any]] = [["title": "Title", "paragraphs": ["body"]]]
                let cases: [([String: Any], String)] = [(["path": 7, "slides": slides], "invalid_path"),
                    (["path": true, "slides": slides], "invalid_path"), (["path": " \n", "slides": slides], "invalid_path"),
                    (["path": "nul\u{0}.pptx", "slides": slides], "invalid_path"),
                    (["path": project.appendingPathComponent("extensionless").path, "slides": slides], "invalid_path"),
                    (["path": file.path, "slides": []], "invalid_slides"),
                    (["path": file.path, "slides": [["title": 7, "paragraphs": []]]], "invalid_slides"),
                    (["path": file.path, "slides": [["title": "", "paragraphs": [false]]]], "invalid_slides"),
                    (["path": file.path, "slides": NSNull()], "invalid_slides"),
                    (["path": file.path, "slides": [["title": "invalid\u{1}", "paragraphs": []]]], "invalid_text"),
                    (["path": file.path, "slides": [["title": "", "paragraphs": [String(repeating: "x", count: 4097)]]]], "content_too_large"),
                    (["path": file.path, "slides": [["title": "", "paragraphs": Array(repeating: String(repeating: "\n", count: 4096), count: 16)]]], "pptx_structure_too_large")]
                for (arguments, code) in cases {
                    let result = try XCTUnwrap(try DocsToolPack().handle(name: "pptx_write", arguments: arguments, context: nil, clientID: client, app: app, cancellation: nil))
                    XCTAssertFalse(result.ok); XCTAssertEqual(result.payload["code"] as? String, code)
                    XCTAssertEqual(try Data(contentsOf: file), prior)
                }
                for control in [ToolCallCancellation(timeoutSeconds: 10), ToolCallCancellation(timeoutSeconds: 0)] {
                    if !control.isDeadlineExceeded { control.cancel() }
                    XCTAssertThrowsError(try DocsToolPack().handle(name: "pptx_write", arguments: ["path": file.path, "slides": slides], context: nil, clientID: client, app: app, cancellation: control)) {
                        XCTAssertTrue($0 is CancellationError || $0 is ToolCallDeadlineExceeded)
                    }
                }
                XCTAssertEqual(try Data(contentsOf: file), prior)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), ["strict.pptx"])
            }
        }.value
    }

    func testRouterReplacementModeMetadataAndBinaryReadback() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let title = "Title café", body = ["日本語 🙂", "literal _x0041_\r\nnext"]
                let slides: [[String: Any]] = [["title": title, "paragraphs": body]]
                let existing = project.appendingPathComponent("replace.pptx")
                try Data("prior".utf8).write(to: existing); XCTAssertEqual(Darwin.chmod(existing.path, 0o600), 0)
                for file in [existing, project.appendingPathComponent("fresh.PPTX")] {
                    let result = try app.tools.call(name: "pptx_write", arguments: ["path": file.path, "slides": slides], clientID: client)
                    XCTAssertTrue(result.ok, "\(result.payload)"); let bytes = try Data(contentsOf: file)
                    XCTAssertEqual(result.payload["path"] as? String, file.path); XCTAssertEqual(result.payload["format"] as? String, "pptx")
                    XCTAssertEqual(result.payload["engine"] as? String, "swift-ooxml-stored-zip")
                    XCTAssertEqual(result.payload["bytes_written"] as? Int, bytes.count); XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                    XCTAssertEqual(result.payload["input_text_bytes"] as? Int, title.utf8.count + body.reduce(0) { $0 + $1.utf8.count })
                    XCTAssertEqual(result.payload["slides"] as? Int, 1); XCTAssertEqual(result.payload["paragraphs"] as? Int, 3)
                    XCTAssertEqual(result.payload["text_contract"] as? String, "pptx-text-slides-v1")
                    let audit = try XCTUnwrap(app.audit.recent(limit: 5).first(where: { $0.tool == "pptx_write" }))
                    let arguments = try XCTUnwrap(audit.argsJSON)
                    XCTAssertFalse(arguments.contains(title))
                    XCTAssertFalse(arguments.contains("literal _x0041_"))
                    XCTAssertTrue(arguments.contains("redacted"))
                    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, file == existing ? 0o600 : 0o644)
                    let parts = try Self.inspectZIP(bytes); XCTAssertEqual(try Self.parseXML(XCTUnwrap(parts["ppt/slides/slide1.xml"])).paragraphs, [title] + body.map(Self.normalized))
                    var reconstructed = Data(), complete = false
                    for _ in 0..<16 {
                        let offset = reconstructed.count
                        let read = try app.tools.call(name: "fs_read", arguments: ["path": file.path, "encoding": "base64", "byte_offset": offset, "maximum_bytes": 32768], clientID: client)
                        XCTAssertTrue(read.ok, "\(read.payload)")
                        let chunk = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(read.payload["content"] as? String)))
                        XCTAssertEqual(read.payload["byte_offset"] as? Int, offset); XCTAssertEqual(read.payload["total_bytes"] as? Int, bytes.count)
                        XCTAssertEqual(read.payload["bytes_read"] as? Int, chunk.count); reconstructed.append(chunk)
                        XCTAssertEqual(read.payload["next_byte_offset"] as? Int, reconstructed.count)
                        XCTAssertTrue(bytes.starts(with: reconstructed))
                        if read.payload["has_more"] as? Bool == false { complete = true; break }
                        XCTAssertGreaterThan(chunk.count, 0)
                    }
                    XCTAssertTrue(complete); XCTAssertEqual(reconstructed, bytes)
                }
            }
        }.value
    }

    func testPinnedWriteRejectsSymlinkParentAndFailedRenameKeepsNeighbors() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let outside = root.appendingPathComponent("outside", isDirectory: true), protected = Data("outside protected".utf8)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                try protected.write(to: outside.appendingPathComponent("target.pptx"))
                let link = project.appendingPathComponent("link", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                let slides: [[String: Any]] = [["title": "blocked", "paragraphs": []]]
                let denied = try XCTUnwrap(try DocsToolPack().handle(name: "pptx_write", arguments: ["path": link.appendingPathComponent("target.pptx").path, "slides": slides], context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(denied.ok); XCTAssertEqual(denied.payload["code"] as? String, "pptx_write_failed")
                XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("target.pptx")), protected)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["target.pptx"])
                let directory = project.appendingPathComponent("directory.pptx", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try protected.write(to: directory.appendingPathComponent("keep"))
                let failed = try XCTUnwrap(try DocsToolPack().handle(name: "pptx_write", arguments: ["path": directory.path, "slides": slides], context: nil, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(failed.ok); XCTAssertEqual(failed.payload["code"] as? String, "pptx_write_failed")
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep")), protected)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path).sorted(), ["directory.pptx", "link"])
            }
        }.value
    }

    func testExplicitGrantAndStaleContextPreventPPTXWrites() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let outside = root.appendingPathComponent("outside.pptx"), prior = Data("outside sentinel".utf8)
                try prior.write(to: outside); let context = try app.projectContexts.invocationContext(for: client)
                let deniedClient = ClientID("pptx-denied-client")
                _ = try app.projectContexts.bind(owner: ProjectBindingOwner(kind: .mcpClient, id: deniedClient.rawValue), projectID: context.projectID, generation: context.projectGeneration,
                    authorizationScope: ToolAuthorizationScope(canonicalRoots: context.authorizationScope.canonicalRoots, allowedTools: ["fs_read"], networkAllowed: context.authorizationScope.networkAllowed, maximumInlineOutputBytes: context.authorizationScope.maximumInlineOutputBytes))
                let slides: [[String: Any]] = [["title": "deny", "paragraphs": []]]
                let denied = try app.tools.call(name: "pptx_write", arguments: ["path": outside.path, "slides": slides], clientID: deniedClient)
                XCTAssertFalse(denied.ok); XCTAssertEqual(denied.payload["code"] as? String, "tool_not_granted"); XCTAssertEqual(try Data(contentsOf: outside), prior)
                _ = try app.projectContexts.beginReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                _ = try app.projectContexts.completeReset(projectID: context.projectID, expectedGeneration: context.projectGeneration)
                let file = project.appendingPathComponent("stale.pptx")
                let stale = try XCTUnwrap(try DocsToolPack().handle(name: "pptx_write", arguments: ["path": file.path, "slides": slides], context: context, clientID: client, app: app, cancellation: nil))
                XCTAssertFalse(stale.ok); XCTAssertEqual(stale.payload["code"] as? String, "pptx_encode_failed")
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            }
        }.value
    }

    func testOwnerAuthorizedHostWideWriteRemainsAvailable() async throws {
        let root = try XCTUnwrap(temporaryRoot)
        try await Task.detached(priority: .utility) { [root] in
            try Self.withToolApp(root: root) { app, client, project in
                let file = root.appendingPathComponent("owner-authorized.pptx")
                XCTAssertFalse(file.path.hasPrefix(project.path + "/"))
                let result = try app.tools.call(name: "pptx_write", arguments: ["path": file.path, "slides": [["title": "Owner", "paragraphs": ["host text"]]]], clientID: client)
                XCTAssertTrue(result.ok, "\(result.payload)"); let bytes = try Data(contentsOf: file)
                XCTAssertEqual(result.payload["sha256"] as? String, JSONSupport.sha256Hex(bytes))
                XCTAssertEqual(try Self.parseXML(XCTUnwrap(Self.inspectZIP(bytes)["ppt/slides/slide1.xml"])).paragraphs, ["Owner", "host text"])
            }
        }.value
    }

    private static func withToolApp(root: URL, _ operation: (ForgeApp, ClientID, URL) throws -> Void) throws {
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: root.appendingPathComponent("home", isDirectory: true)); defer { app.shutdown() }
        _ = try app.config.update(["allowed_roots": [project.path]], save: false)
        let client = ClientID("pptx-writer-tests")
        let result = try app.tools.call(name: "project_memory.initialize", arguments: ["project_path": project.path], clientID: client)
        XCTAssertTrue(result.ok, "\(result.payload)"); try operation(app, client, project)
    }

    private static func target(_ target: String, from relation: String) -> String {
        let directory = relation == "_rels/.rels" ? "" : String(relation.prefix(through: relation.range(of: "/_rels/")!.lowerBound))
        return String(URL(fileURLWithPath: "/" + directory, isDirectory: true).appendingPathComponent(target).standardizedFileURL.path.dropFirst())
    }

    private static func normalized(_ text: String) -> String { text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }

    private static func inspectZIP(_ data: Data) throws -> [String: Data] {
        guard (22...1_048_576).contains(data.count) else { throw FixtureError.malformed }
        func word(_ offset: Int, _ length: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - length else { throw FixtureError.malformed }
            return (0..<length).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        let end = data.count - 22, count = Int(try word(data.count - 12, 2))
        guard (12...74).contains(count) else { throw FixtureError.malformed }
        XCTAssertEqual(try word(end, 4), 0x06054b50); XCTAssertEqual(try word(end + 4, 2), 0); XCTAssertEqual(try word(end + 6, 2), 0)
        XCTAssertEqual(try word(end + 8, 2), UInt32(count)); XCTAssertEqual(try word(end + 20, 2), 0)
        let start = Int(try word(end + 16, 4)); XCTAssertEqual(start + Int(try word(end + 12, 4)), end)
        var cursor = start, parts: [String: Data] = [:], localEnd = 0
        for _ in 0..<count {
            XCTAssertEqual(try word(cursor, 4), 0x02014b50); XCTAssertEqual(try word(cursor + 6, 2), 20)
            XCTAssertEqual(try word(cursor + 8, 2), 0x0800); XCTAssertEqual(try word(cursor + 10, 2), 0)
            let checksum = try word(cursor + 16, 4), size = Int(try word(cursor + 20, 4)), nameLength = Int(try word(cursor + 28, 2)), local = Int(try word(cursor + 42, 4))
            XCTAssertEqual(try word(cursor + 24, 4), UInt32(size)); for field in [30, 32, 34, 36] { XCTAssertEqual(try word(cursor + field, 2), 0) }
            guard cursor <= end - 46 - nameLength else { throw FixtureError.malformed }
            let nameBytes = data[(cursor + 46)..<(cursor + 46 + nameLength)], name = try XCTUnwrap(String(data: data[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8))
            XCTAssertEqual(local, localEnd); XCTAssertEqual(try word(local, 4), 0x04034b50); XCTAssertEqual(try word(local + 4, 2), 20)
            XCTAssertEqual(try word(local + 6, 2), 0x0800); XCTAssertEqual(try word(local + 8, 2), 0)
            XCTAssertEqual(try word(local + 14, 4), checksum); XCTAssertEqual(try word(local + 18, 4), UInt32(size)); XCTAssertEqual(try word(local + 22, 4), UInt32(size))
            XCTAssertEqual(try word(local + 26, 2), UInt32(nameLength)); XCTAssertEqual(try word(local + 28, 2), 0)
            let body = local + 30 + nameLength; guard body <= start - size else { throw FixtureError.malformed }
            XCTAssertEqual(data[(local + 30)..<body], nameBytes)
            let bytes = Data(data[body..<(body + size)]); XCTAssertEqual(crc32(bytes), checksum, name)
            XCTAssertNil(parts.updateValue(bytes, forKey: name)); localEnd = body + size; cursor += 46 + nameLength
        }
        XCTAssertEqual(localEnd, start); XCTAssertEqual(cursor, end); return parts
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var result: UInt32 = 0xFFFFFFFF
        for byte in data { result ^= UInt32(byte); for _ in 0..<8 { result = (result >> 1) ^ ((result & 1) == 0 ? 0 : 0xEDB88320) } }
        return ~result
    }

    private static func parseXML(_ data: Data) throws -> PPTXWriterXML {
        let delegate = PPTXWriterXML(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.externalEntityResolvingPolicy = .never; parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? FixtureError.malformed }; return delegate
    }

    private enum FixtureError: Error { case malformed }
}

private final class PPTXWriterXML: NSObject, XMLParserDelegate {
    var elements: [(String, [String: String])] = []
    var paragraphs: [String] = []
    var breakCount = 0, textElements = 0, preservedTextElements = 0
    private var textBody = false, inText = false, paragraph: Int?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        elements.append((name, attributes))
        if name == "p:txBody" { textBody = true }
        if textBody, name == "a:p" { paragraph = paragraphs.count; paragraphs.append("") }
        if textBody, name == "a:t" { inText = true; textElements += 1; if attributes["xml:space"] == "preserve" { preservedTextElements += 1 } }
        if textBody, name == "a:br", let paragraph { breakCount += 1; paragraphs[paragraph] += "\n" }
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) { if inText, let paragraph { paragraphs[paragraph] += text } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if name == "a:t" { inText = false }; if name == "a:p" { paragraph = nil }; if name == "p:txBody" { textBody = false }
    }
}

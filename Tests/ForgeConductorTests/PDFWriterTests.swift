import Foundation
import PDFKit
import XCTest
@testable import ForgeConductorCore

final class PDFWriterTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-pdf-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        temporaryRoot = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryRoot)
    }

    func testMarkdownASCIIAndLiteralEscapingRemainReadable() throws {
        let content = """
        # ascii control

        ## Section
        ### Detail
        **strong** _emphasis_ `inline`
        Literal parentheses (left right) and backslash \\ marker.
        ```
        let_value = (left)\\right
        ```
        ASCII-SENTINEL-025
        """
        let (document, metadata) = try writeAndOpen(
            "ascii.pdf", content: content, title: "ASCII native PDF"
        )
        let text = try extractedText(document)
        for fragment in [
            "ASCII CONTROL", "Section", "Detail", "strong emphasis inline",
            "Literal parentheses (left right) and backslash \\ marker.",
            "let_value = (left)\\right", "ASCII-SENTINEL-025", "ASCII native PDF",
        ] {
            assertContainsScalars(text, fragment: fragment)
        }
        XCTAssertEqual(metadata["engine"] as? String, "swift-pdf-writer")
        XCTAssertEqual(metadata["title"] as? String, "ASCII native PDF")
    }

    func testMarkdownBulletsExtractAsUnicodeBullet() throws {
        let (document, _) = try writeAndOpen(
            "bullets.pdf",
            content: "- first item\n* second item\nBULLET-SENTINEL-025",
            title: "Bullet control"
        )
        let text = try extractedText(document)
        assertContainsScalars(text, fragment: "• first item")
        assertContainsScalars(text, fragment: "• second item")
        assertContainsScalars(text, fragment: "BULLET-SENTINEL-025")
    }

    func testUnicodeBodyExtractsExactScalars() throws {
        let fragments = ["Latin café déjà vu", "Ελληνικά", "Русский", "日本語", "العربية"]
        let (document, _) = try writeAndOpen(
            "unicode-body.pdf",
            content: fragments.joined(separator: "\n") + "\nUNICODE-BODY-SENTINEL-025",
            title: "Unicode body control"
        )
        let text = try extractedText(document)
        for fragment in fragments + ["UNICODE-BODY-SENTINEL-025"] {
            assertContainsScalars(text, fragment: fragment)
        }
    }

    func testUnicodeTitleExtractsExactScalars() throws {
        let title = "Title café 日本語"
        let (document, metadata) = try writeAndOpen(
            "unicode-title.pdf", content: "UNICODE-TITLE-SENTINEL-025", title: title
        )
        let text = try extractedText(document)
        assertContainsScalars(text, fragment: title)
        assertContainsScalars(text, fragment: "UNICODE-TITLE-SENTINEL-025")
        XCTAssertEqual(metadata["title"] as? String, title)
    }

    func testUTF8SourceExplicitDestinationPreservesUnicode() async throws {
        try await Task.detached(priority: .utility) { [self] in
            try withToolApp { app, client, project in
                let source = project.appendingPathComponent("utf8-source.md")
                let destination = project.appendingPathComponent("explicit-output.pdf")
                let marker = "café Ελληνικά Русский 日本語 العربية"
                try Data("# UTF8 source\n\(marker)\nUTF8-SOURCE-SENTINEL-025\n".utf8).write(to: source)
                let result = try app.tools.call(
                    name: "pdf_from_file",
                    arguments: [
                        "source_path": source.path,
                        "dest_path": destination.path,
                        "title": "Explicit UTF8 source",
                    ],
                    clientID: client
                )
                XCTAssertTrue(result.ok, "\(result.payload)")
                XCTAssertEqual(result.payload["source_path"] as? String, source.path)
                let document = try openPDF(destination, metadata: result.payload)
                let visualText = try extractedText(document)
                for fragment in ["UTF8 SOURCE", "UTF8-SOURCE-SENTINEL-025", "Explicit UTF8 source"] {
                    assertContainsScalars(visualText, fragment: fragment)
                }
                let pages = try XCTUnwrap(try NativePDFTextReader.pages(in: Data(contentsOf: destination)))
                let text = pages.joined()
                for fragment in ["UTF8 SOURCE", marker, "UTF8-SOURCE-SENTINEL-025", "Explicit UTF8 source"] {
                    assertContainsScalars(text, fragment: fragment)
                }
            }
        }.value
    }

    func testWrappedTaggedTextPreservesMixedScriptsAndUnbrokenWordsAcrossPages() async throws {
        let destination = temporaryRoot.appendingPathComponent("logical-wrapped.pdf")
        let paragraphs = [
            String(repeating: "wideword", count: 1_000),
            "Latin العربية. 123 (45), source.",
            "abcאבג 6789; MIXED-ID-025.",
            "café Ελληνικά Русский 日本語 العربية",
        ]
        let content = paragraphs.joined(separator: "\n")
        let pages = try await Task.detached(priority: .utility) {
            _ = try PDFWriter.write(path: destination, content: content)
            return try XCTUnwrap(try NativePDFTextReader.pages(in: Data(contentsOf: destination)))
        }.value
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertLessThanOrEqual(pages.count, 8)
        XCTAssertEqual(whitespaceNormalizedScalars(pages.joined()), whitespaceNormalizedScalars(content))
    }

    func testDefaultToolTitlesAndDestinationsRemainAvailable() throws {
        try withToolApp { app, client, project in
            let extensionless = project.appendingPathComponent("default-write")
            let written = try app.tools.call(
                name: "pdf_write",
                arguments: ["path": extensionless.path, "content": "DEFAULT-WRITE-SENTINEL-025"],
                clientID: client
            )
            XCTAssertTrue(written.ok, "\(written.payload)")
            XCTAssertEqual(written.payload["title"] as? String, "default-write")
            let writtenDocument = try openPDF(
                extensionless.appendingPathExtension("pdf"), metadata: written.payload
            )
            let writtenText = try extractedText(writtenDocument)
            assertContainsScalars(writtenText, fragment: "default-write")
            assertContainsScalars(writtenText, fragment: "DEFAULT-WRITE-SENTINEL-025")

            let source = project.appendingPathComponent("default-source.md")
            try Data("DEFAULT-SOURCE-SENTINEL-025\n".utf8).write(to: source)
            let converted = try app.tools.call(
                name: "pdf_from_file", arguments: ["source_path": source.path], clientID: client
            )
            XCTAssertTrue(converted.ok, "\(converted.payload)")
            XCTAssertEqual(converted.payload["source_path"] as? String, source.path)
            XCTAssertEqual(converted.payload["title"] as? String, "default-source")
            let convertedDocument = try openPDF(
                project.appendingPathComponent("default-source.pdf"), metadata: converted.payload
            )
            let convertedText = try extractedText(convertedDocument)
            assertContainsScalars(convertedText, fragment: "default-source")
            assertContainsScalars(convertedText, fragment: "DEFAULT-SOURCE-SENTINEL-025")
        }
    }

    func testMultiplePagesRetainFirstAndLastParagraphs() throws {
        let content = (0..<130).map {
            String(format: "Paragraph %03d MULTIPAGE-SENTINEL-025", $0)
        }.joined(separator: "\n")
        let (document, _) = try writeAndOpen("multiple-pages.pdf", content: content, title: "Multiple pages")
        XCTAssertGreaterThan(document.pageCount, 1)
        let first = try XCTUnwrap(document.page(at: 0)?.string)
        let last = try XCTUnwrap(document.page(at: document.pageCount - 1)?.string)
        assertContainsScalars(first, fragment: "Paragraph 000 MULTIPAGE-SENTINEL-025")
        assertContainsScalars(last, fragment: "Paragraph 129 MULTIPAGE-SENTINEL-025")
        let text = try extractedText(document)
        for index in 0..<130 {
            assertContainsScalars(text, fragment: String(format: "Paragraph %03d MULTIPAGE-SENTINEL-025", index))
        }
    }

    func testEmptyDocumentRemainsReadable() throws {
        let (document, metadata) = try writeAndOpen("empty.pdf", content: "")
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(metadata["title"] as? String, "")
        XCTAssertNotNil(document.page(at: 0))
    }

    func testBlankOnlyEOFDoesNotAddUnusedPage() throws {
        let (document, metadata) = try writeAndOpen(
            "blank-only.pdf", content: String(repeating: "\n", count: 98)
        )
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(metadata["pages"] as? Int, 1)
        XCTAssertEqual(metadata["title"] as? String, "")
    }

    func testCompletedBlankPagesRemainAvailableWithoutUnusedEOFPage() throws {
        let (document, metadata) = try writeAndOpen(
            "two-blank-pages.pdf", content: String(repeating: "\n", count: 197)
        )
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(metadata["pages"] as? Int, 2)
        XCTAssertEqual(metadata["title"] as? String, "")
    }

    func testTrailingBlankEOFDoesNotAddUnusedPageAfterBody() throws {
        let marker = "BODY-BLANK-SENTINEL-025"
        let (document, metadata) = try writeAndOpen(
            "trailing-blanks.pdf", content: marker + String(repeating: "\n", count: 98)
        )
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(metadata["pages"] as? Int, 1)
        assertContainsScalars(try extractedText(document), fragment: marker)
    }

    func testMultilineContinuationTitlePreservesBodyAndPageGeometry() throws {
        let title = String(repeating: "\n", count: 79) + "X"
        let paragraphs = (0..<130).map {
            String(format: "Title paragraph %03d TITLE-PAGING-SENTINEL-025", $0)
        }
        let destination = temporaryRoot.appendingPathComponent("multiline-title.pdf")
        let metadata = try PDFWriter.write(
            path: destination, content: paragraphs.joined(separator: "\n"), title: title
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let size = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        _ = try XCTUnwrap((101...(8 * 1_024 * 1_024)).contains(size) ? destination : nil)
        let bytes = try Data(contentsOf: destination)
        let document = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertFalse(document.isEncrypted)
        XCTAssertFalse(document.isLocked)
        XCTAssertEqual(metadata["bytes_written"] as? Int, bytes.count)
        XCTAssertEqual(metadata["pages"] as? Int, document.pageCount)
        XCTAssertEqual(metadata["title"] as? String, title)
        XCTAssertGreaterThan(document.pageCount, 1)
        XCTAssertLessThanOrEqual(document.pageCount, 8)
        // Inspect the defective expansion too, within an independent hard cap.
        // A geometry failure must not be hidden by the expected healthy count.
        _ = try XCTUnwrap((1...256).contains(document.pageCount) ? document : nil)
        var text = ""
        for pageIndex in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: pageIndex))
            let pageText = page.string ?? ""
            _ = try XCTUnwrap(text.utf8.count + pageText.utf8.count + 1 <= 128 * 1_024 ? page : nil)
            text += pageText + "\n"
            try assertTitleStressPageGeometry(page, pageIndex: pageIndex)
        }
        assertContainsScalars(text, fragment: "X")
        for paragraph in paragraphs {
            assertContainsScalars(text, fragment: paragraph)
        }
    }

    func testWideAndUnbrokenTextStaysWithinMediaBox() throws {
        let wide = String(repeating: "W", count: 86)
        let unbroken = String(repeating: "longword", count: 24)
        let (document, _) = try writeAndOpen(
            "wide-text.pdf", content: "GEOMETRY-SENTINEL-025\n\(wide)\n\(unbroken)",
            title: "Wide text geometry"
        )
        let text = try extractedText(document)
        assertContainsScalars(text, fragment: "GEOMETRY-SENTINEL-025")
        let compact = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }))
        assertContainsScalars(compact, fragment: wide)
        assertContainsScalars(compact, fragment: unbroken)

        for pageIndex in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: pageIndex))
            let media = page.bounds(for: .mediaBox)
            XCTAssertEqual(media, CGRect(x: 0, y: 0, width: 612, height: 792))
            XCTAssertLessThanOrEqual(page.numberOfCharacters, 20_000)
            guard page.numberOfCharacters <= 20_000 else { continue }
            let tolerance = media.insetBy(dx: -0.5, dy: -0.5)
            for character in 0..<page.numberOfCharacters {
                let bounds = page.characterBounds(at: character)
                XCTAssertTrue(
                    bounds.origin.x.isFinite && bounds.origin.y.isFinite
                        && bounds.width.isFinite && bounds.height.isFinite,
                    "Non-finite bounds on page \(pageIndex), character \(character): \(bounds)"
                )
                if !bounds.isEmpty && !bounds.isNull {
                    XCTAssertTrue(
                        tolerance.contains(bounds),
                        "Text outside MediaBox on page \(pageIndex), character \(character): \(bounds)"
                    )
                }
            }
        }
    }

    func testCancellationBeforeLayoutDoesNotCreateParent() throws {
        let parent = temporaryRoot.appendingPathComponent("not-created", isDirectory: true)
        let destination = parent.appendingPathComponent("cancelled.pdf")
        XCTAssertThrowsError(try PDFWriter.write(
            path: destination, content: "CANCELLED-SENTINEL-025",
            cancellationCheck: { throw CancellationError() }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    func testCancellationDuringLayoutPreservesExistingDestination() throws {
        let destination = temporaryRoot.appendingPathComponent("existing.pdf")
        let original = Data("Existing destination must survive cancellation".utf8)
        try original.write(to: destination)
        let content = (0..<130).map { "Cancellation paragraph \($0)" }.joined(separator: "\n")
        var checks = 0
        XCTAssertThrowsError(try PDFWriter.write(
            path: destination, content: content, cancellationCheck: {
                checks += 1
                if checks == 8 { throw CancellationError() }
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checks, 8)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path), ["existing.pdf"])
    }

    func testDocumentToolSourceByteLimitsRejectBeforeOutput() throws {
        try withToolApp { app, client, project in
            let tooLarge = String(repeating: "x", count: 4 * 1_024 * 1_024 + 1)
            let inlineDestination = project.appendingPathComponent("inline-too-large.pdf")
            let inline = try app.tools.call(
                name: "pdf_write",
                arguments: ["path": inlineDestination.path, "content": tooLarge], clientID: client
            )
            XCTAssertFalse(inline.ok)
            XCTAssertEqual(inline.payload["code"] as? String, "content_too_large")
            XCTAssertEqual(inline.payload["retryable"] as? Bool, false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: inlineDestination.path))

            let source = project.appendingPathComponent("source-too-large.md")
            try Data(tooLarge.utf8).write(to: source)
            let sourceDestination = project.appendingPathComponent("source-too-large.pdf")
            let converted = try app.tools.call(
                name: "pdf_from_file",
                arguments: ["source_path": source.path, "dest_path": sourceDestination.path],
                clientID: client
            )
            XCTAssertFalse(converted.ok)
            XCTAssertEqual(converted.payload["code"] as? String, "source_too_large")
            XCTAssertEqual(converted.payload["retryable"] as? Bool, false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceDestination.path))
        }
    }

    func testNativeOutputBudgetFailureDoesNotCreateParent() throws {
        let parent = temporaryRoot.appendingPathComponent("output-budget-parent", isDirectory: true)
        let destination = parent.appendingPathComponent("limited.pdf")
        XCTAssertThrowsError(try PDFWriter.write(
            path: destination, content: "café Ελληνικά Русский 日本語 العربية",
            outputByteLimit: 512
        )) { error in
            XCTAssertEqual(error.localizedDescription, "PDF output is limited to 512 bytes.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    func testNativeOutputBudgetFailurePreservesExistingDestination() throws {
        let destination = temporaryRoot.appendingPathComponent("limited-existing.pdf")
        let original = Data("Existing bytes before native consumer failure".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try PDFWriter.write(
            path: destination, content: "Native budget failure Ελληνικά 日本語", outputByteLimit: 512
        )) { error in
            XCTAssertEqual(error.localizedDescription, "PDF output is limited to 512 bytes.")
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path),
                       ["limited-existing.pdf"])
    }

    private func writeAndOpen(
        _ filename: String, content: String, title: String = ""
    ) throws -> (PDFDocument, [String: Any]) {
        let destination = temporaryRoot.appendingPathComponent(filename)
        let metadata = try PDFWriter.write(path: destination, content: content, title: title)
        return (try openPDF(destination, metadata: metadata), metadata)
    }

    private func assertTitleStressPageGeometry(_ page: PDFPage, pageIndex: Int) throws {
        let media = page.bounds(for: .mediaBox)
        XCTAssertEqual(media, CGRect(x: 0, y: 0, width: 612, height: 792))
        XCTAssertLessThanOrEqual(page.numberOfCharacters, 20_000)
        _ = try XCTUnwrap(page.numberOfCharacters <= 20_000 ? page : nil)
        let tolerance = media.insetBy(dx: -0.5, dy: -0.5)
        for character in 0..<page.numberOfCharacters {
            let bounds = page.characterBounds(at: character)
            XCTAssertTrue(
                bounds.origin.x.isFinite && bounds.origin.y.isFinite
                    && bounds.width.isFinite && bounds.height.isFinite,
                "Non-finite title/body bounds on page \(pageIndex), character \(character): \(bounds)"
            )
            if !bounds.isEmpty && !bounds.isNull {
                XCTAssertTrue(
                    tolerance.contains(bounds),
                    "Title/body text outside MediaBox on page \(pageIndex), character \(character): \(bounds)"
                )
            }
        }
    }

    private func openPDF(_ url: URL, metadata: [String: Any]) throws -> PDFDocument {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        XCTAssertGreaterThan(size, 100)
        XCTAssertLessThanOrEqual(size, 8 * 1_024 * 1_024)
        _ = try XCTUnwrap((101...(8 * 1_024 * 1_024)).contains(size) ? url : nil)
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(metadata["ok"] as? Bool, true)
        XCTAssertEqual(metadata["path"] as? String, url.path)
        XCTAssertEqual(metadata["bytes_written"] as? Int, bytes.count)
        XCTAssertGreaterThan(bytes.count, 100)
        XCTAssertLessThanOrEqual(bytes.count, 8 * 1_024 * 1_024)
        let document = try XCTUnwrap(PDFDocument(data: bytes), "PDFKit could not open \(url.lastPathComponent)")
        XCTAssertFalse(document.isEncrypted)
        XCTAssertFalse(document.isLocked)
        XCTAssertGreaterThan(document.pageCount, 0)
        XCTAssertLessThanOrEqual(document.pageCount, 8)
        XCTAssertEqual(metadata["pages"] as? Int, document.pageCount)
        return try XCTUnwrap((1...8).contains(document.pageCount) ? document : nil)
    }

    private func extractedText(_ document: PDFDocument) throws -> String {
        guard document.pageCount <= 8 else {
            XCTFail("Fixture exceeded the page inspection bound")
            return ""
        }
        var text = ""
        for pageIndex in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: pageIndex))
            let pageText = page.string ?? ""
            guard text.utf8.count + pageText.utf8.count + 1 <= 128 * 1_024 else {
                XCTFail("Fixture exceeded the extraction byte bound")
                return text
            }
            text += pageText + "\n"
        }
        return text
    }

    private func assertContainsScalars(
        _ text: String, fragment: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        // PDFKit may insert layout whitespace. Keep every non-whitespace scalar exact.
        let haystack = whitespaceNormalizedScalars(text)
        let needle = whitespaceNormalizedScalars(fragment)
        let found = !needle.isEmpty && haystack.count >= needle.count
            && (0...(haystack.count - needle.count)).contains { start in
                haystack[start..<(start + needle.count)].elementsEqual(needle)
            }
        XCTAssertTrue(found, "Missing scalar-exact fragment: \(fragment)", file: file, line: line)
    }

    private func whitespaceNormalizedScalars(_ text: String) -> [UInt32] {
        var result: [UInt32] = []
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(0x20) }
                result.append(scalar.value)
                pendingSpace = false
            }
        }
        return result
    }

    private func withToolApp(_ operation: (ForgeApp, ClientID, URL) throws -> Void) throws {
        let home = temporaryRoot.appendingPathComponent("home", isDirectory: true)
        let project = temporaryRoot.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try ForgeApp.bootstrap(home: home)
        defer { app.shutdown() }
        _ = try app.config.update(
            ["allowed_roots": [project.resolvingSymlinksInPath().standardizedFileURL.path]], save: false
        )
        let client = ClientID("pdf-writer-tests")
        let initialized = try app.tools.call(
            name: "project_memory.initialize", arguments: ["project_path": project.path], clientID: client
        )
        XCTAssertTrue(initialized.ok, "\(initialized.payload)")
        try operation(app, client, project)
    }
}
